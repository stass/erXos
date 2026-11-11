# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'rbconfig'
require_relative 'error'
require_relative 'host_os'
require_relative 'runner'
require_relative 'dependencies'
require_relative 'fsimg'
require_relative 'rc_oracle'
require_relative 'web_build'

module Erx
  # Prepares a fresh checkout or worktree so `make check` can run: the sources
  # the gates build from, the stock OTP oracle, the native runtime and the
  # command shell's rc oracle, which its corpus test runs. A step
  # whose output is already present and valid is skipped.
  #
  # The decision of what to run (Setup.plan) is a pure function of what exists;
  # Setup#call gathers that and performs the steps in order.
  class Setup
    # Setup fetches every source deps.lock pins except these, which only a
    # gate or tool of their own uses; each says which. A tar, git or file source
    # deps.lock gains is fetched by setup without an edit here; setup cannot
    # obtain an OCI image offline, so one must be named here.
    SKIPPED_SOURCES = {
      'arm-registers' => 'only `tools/erx sysreg refresh` reads it',
      'tla-tools' => 'only `make check-tla` runs TLC',
      'herdtools7' => 'only `make check-litmus` builds herd7 from it',
      'oracle-toolchain' => 'the OCI oracle image, which the native oracle does not use'
    }.freeze

    Step = Data.define(:name, :kind, :argv, :deadline)

    # `oracle build`'s own default deadline (tools/erx, the oracle command), which a
    # setup step must not cut short: a killed build restarts from nothing.
    ORACLE_BUILD_DEADLINE = 14_400

    # The web client's packages, fetched into their store (WebBuild.fetch).
    WEB_STORE = Step.new(name: 'web-store', kind: :web_store, argv: [], deadline: WebBuild::DEADLINE)

    COMMAND_STEPS = [
      Step.new(name: 'oracle-jit', kind: :command, deadline: ORACLE_BUILD_DEADLINE,
               argv: %w[oracle build --backend native --flavour jit]),
      Step.new(name: 'oracle-emu', kind: :command, deadline: ORACLE_BUILD_DEADLINE,
               argv: %w[oracle build --backend native --flavour emu]),
      # fsimg writes the EROFS image the runtime build packs the hosted release with.
      Step.new(name: 'fsimg', kind: :command, deadline: ORACLE_BUILD_DEADLINE,
               argv: %w[build fsimg]),
      Step.new(name: 'runtime', kind: :command, deadline: ORACLE_BUILD_DEADLINE,
               argv: %w[build runtime]),
      Step.new(name: 'rc-oracle', kind: :command, deadline: ORACLE_BUILD_DEADLINE,
               argv: %w[build rc-oracle])
    ].freeze

    # Every step for deps.lock's sources: each source setup fetches, in
    # deps.lock's order, then the builds that read them. The hosted runtime
    # builds only on macOS (Runtime#build), so elsewhere its step is left
    # out and the tests that need it skip, saying so.
    def self.steps(sources, hosted_runtime: HostOs::MACOS)
      fetched = sources.map { |source| source.fetch('id') }.reject { |id| SKIPPED_SOURCES.key?(id) }
      builds = COMMAND_STEPS.reject { |step| step.name == 'runtime' && !hosted_runtime }
      fetched.map { |id| Step.new(name: "source-#{id}", kind: :source, argv: [id], deadline: 300) } +
        [WEB_STORE] + builds
    end

    # present: a hash of step name => true when the step's output is valid.
    # Returns the steps still to run, in their order.
    def self.plan(present, steps:)
      steps.reject { |step| present.fetch(step.name, false) }
    end

    # Where Homebrew installs the LLVM tools under prefix: /opt/homebrew on
    # Apple Silicon, /usr/local on Intel macOS. clang comes from the
    # keg-only llvm formula, ld.lld from lld, which Homebrew links.
    def self.toolchain_defaults(prefix)
      { 'ERX_CLANG' => File.join(prefix, 'opt/llvm/bin/clang'), 'ERX_LLD' => File.join(prefix, 'bin/ld.lld') }
    end

    TOOLCHAIN_VARIABLES = toolchain_defaults('').keys.freeze

    # FreeBSD's ports install each LLVM release as prefix/llvmNN; the newest
    # one with both clang and ld.lld, or nil when there is none.
    def self.ports_toolchain(prefix)
      return nil unless File.directory?(prefix)

      ports = Dir.children(prefix).select { |name| /\Allvm[0-9]+\z/.match?(name) }
      ports.sort_by { |name| -Integer(name.delete_prefix('llvm'), 10) }
           .map { |name| toolchain_files(File.join(prefix, name, 'bin')) }
           .find { |tools| tools.values.all? { |path| tool?(path) } }
    end

    def self.toolchain_files(bin) = { 'ERX_CLANG' => File.join(bin, 'clang'), 'ERX_LLD' => File.join(bin, 'ld.lld') }
    # Whether path is an executable file, not a directory or something absent.
    def self.tool?(path) = File.file?(path) && File.executable?(path)
    private_class_method :toolchain_files

    # Where another checkout keeps verified archives, derived from a cache
    # directory such as <checkout>/build/third_party.
    def self.archive_directory(cache)
      File.join(File.dirname(File.expand_path(cache)), 'downloads')
    end

    # ports_prefix is where FreeBSD's ports install (LOCALBASE).
    def initialize(root:, runner: nil, cache: ENV.fetch('ERX_SOURCE_CACHE', nil), jobs: 4, env: ENV.to_h,
                   ports_prefix: '/usr/local')
      @root = File.expand_path(root)
      @runner = runner || Runner.new(owner_root: @root, log_dir: File.join(@root, 'build/logs'))
      @cache = cache.to_s.empty? ? nil : cache
      @jobs = jobs
      @env = env
      @ports_prefix = ports_prefix
      @dependencies = Dependencies.new(root: @root, runner: @runner)
      @steps = self.class.steps(@dependencies.sources)
    end

    def call
      steps = plan
      return [] if steps.empty?

      # Only the builds need a compiler, so a plan of sources alone runs
      # without one; a plan with a build stops here, before anything runs,
      # when the compiler cannot be found.
      toolchain = steps.any? { |step| step.kind == :command } ? toolchain_env : {}
      steps.each { |step| perform(step, toolchain) }
      steps.map(&:name)
    end

    def plan = self.class.plan(present, steps: @steps)

    def present
      @steps.to_h { |step| [step.name, valid?(step)] }
    end

    private

    def valid?(step)
      case step.name
      when /\Asource-(.*)/ then source_valid?(Regexp.last_match(1))
      when 'oracle-jit' then File.file?(File.join(@root, 'build/oracle/jit/build.json'))
      when 'oracle-emu' then File.file?(File.join(@root, 'build/oracle/emu/build.json'))
      when 'runtime' then File.file?(File.join(@root, 'build/runtime/hosted/release/system.pack'))
      when 'rc-oracle' then rc_oracle_valid?
      when 'fsimg' then fsimg_valid?
      when 'web-store' then WebBuild.fetched?(root: @root)
      end
    end

    # Built from the pinned plan9port by the current recipe, as the corpus test
    # requires. Any refusal only means the step runs: `build rc-oracle` ends
    # with the same RcOracle.locate, so an error that persists fails the step.
    def rc_oracle_valid?
      RcOracle.locate(root: @root)
      true
    rescue Error
      false
    end

    # Built from the pinned fsimg by the current recipe, which every EROFS image
    # needs; a refusal only means the step runs, as for rc_oracle_valid?.
    def fsimg_valid?
      Fsimg.locate(root: @root)
      true
    rescue Error
      false
    end

    def source_valid?(id) = @dependencies.fetched?(id)

    def perform(step, toolchain)
      Terminal.puts("setup: #{step.name}")
      case step.kind
      when :source
        obtain_source(step.argv.first)
      when :web_store
        WebBuild.fetch(root: @root, runner: @runner)
      else
        @runner.run([RbConfig.ruby, File.join(@root, 'tools/erx'), *step.argv, *leftovers(step), '--jobs', @jobs.to_s],
                    name: "setup-#{step.name}", deadline: step.deadline, chdir: @root, env: toolchain)
      end
    end

    # An oracle directory without its build record is what an interrupted
    # build leaves; the build refuses to reuse it, so it is re-created.
    def leftovers(step)
      flavour = step.argv[step.argv.index('--flavour').to_i + 1] if step.argv.include?('--flavour')
      directory = File.join(@root, 'build/oracle', flavour.to_s)
      flavour && File.exist?(directory) && !File.file?(File.join(directory, 'build.json')) ? ['--clean'] : []
    end

    # Never touches the network: the archive comes from a checkout's
    # verified downloads, or is already here from `make fetch`.
    # The archive's own failures say how to get it; a stale tree's say what to remove.
    def obtain_source(id)
      begin
        local_archive(id)
      rescue Error => e
        raise Error, "#{e.message}; run `make fetch` or set ERX_SOURCE_CACHE to another checkout's build/third_party"
      end
      @dependencies.fetch(source_id: id)
    end

    # Dependencies#fetch would download a missing archive; setup must not.
    def local_archive(id)
      archive = @dependencies.archive_path_of(id)
      if @cache && !File.file?(archive)
        origin = File.join(self.class.archive_directory(@cache), File.basename(archive))
        raise Error, "source not found in ERX_SOURCE_CACHE: #{origin}" unless File.file?(origin)

        @dependencies.adopt(id, from: origin)
      end
      raise Error, "source #{id} is not downloaded" unless File.file?(archive)
    end

    # The LLVM tools the native builds need, for each of ERX_CLANG and ERX_LLD
    # the caller left unset, from the first of these installations that has
    # both: Homebrew's, under the prefix HOMEBREW_PREFIX or `brew --prefix`
    # names; the newest FreeBSD port under the ports prefix
    # (ports_toolchain); or, off macOS, clang and ld.lld on PATH. macOS's own
    # clang is Apple's, which will not do (README.md). A tool that cannot be
    # found this way is an error here, before any step runs.
    def toolchain_env
      unset = TOOLCHAIN_VARIABLES.select { |name| @env.fetch(name, '').empty? }
      return {} if unset.empty?

      prefix = homebrew_prefix
      candidates = [prefix && self.class.toolchain_defaults(prefix), self.class.ports_toolchain(@ports_prefix),
                    (path_toolchain unless HostOs::MACOS)]
      found = candidates.compact.find { |tools| tools.slice(*unset).values.all? { |path| self.class.tool?(path) } }
      return found.slice(*unset) if found

      homebrew = prefix ? "not installed at #{self.class.toolchain_defaults(prefix).values.join(', ')}" :
                          'no Homebrew prefix in HOMEBREW_PREFIX or from `brew --prefix`'
      raise Error, "set #{unset.join(' and ')} to the installed LLVM clang and ld.lld (see README.md): " \
                   "#{homebrew}; no FreeBSD llvm port under #{@ports_prefix}#{HostOs::MACOS ? '' : '; none on PATH'}"
    end

    # clang and ld.lld from the first absolute directory of PATH that has both, so the two
    # come from one installation; nil when none does. A relative entry would name another
    # directory once a build changes into its own, so it is passed over.
    def path_toolchain
      @env.fetch('PATH', '').split(File::PATH_SEPARATOR).select { |directory| File.absolute_path?(directory) }
          .map { |directory| self.class.send(:toolchain_files, directory) }
          .find { |tools| tools.values.all? { |path| self.class.tool?(path) } }
    end

    # HOMEBREW_PREFIX when set, else what `brew --prefix` prints; nil when
    # brew is not installed or fails. Either answer must be one existing
    # directory's absolute path, or it is an error naming where it came from.
    def homebrew_prefix
      named = @env.fetch('HOMEBREW_PREFIX', '')
      return checked_prefix(named, source: 'HOMEBREW_PREFIX') unless named.empty?

      begin
        result = @runner.run(%w[brew --prefix], name: 'setup-brew-prefix', deadline: 60)
      rescue CommandError
        return nil
      end
      checked_prefix(File.read(result.fetch('log'), 4096).to_s.chomp, source: '`brew --prefix`')
    end

    def checked_prefix(prefix, source:)
      return prefix if prefix.match?(%r{\A/[^[:cntrl:]]*\z}) && File.directory?(prefix)

      raise Error, "#{source} does not name a Homebrew prefix directory; see #{File.join(@root, 'build/logs')}"
    end
  end
end
