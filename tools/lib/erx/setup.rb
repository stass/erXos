# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'rbconfig'
require_relative 'error'
require_relative 'runner'
require_relative 'dependencies'
require_relative 'json_input'
require_relative 'rc_oracle'
require_relative 'bounded_file'

module Erx
  # Prepares a fresh checkout or worktree so `make check` can run: the sources
  # the gates build from, the stock OTP oracle, and the native runtime. A step
  # whose output is already present and valid is skipped.
  #
  # The decision of what to run (Setup.plan) is a pure function of what exists;
  # Setup#call gathers that and performs the steps in order.
  class Setup
    # Sources the gates need (libc-test is for the native libc canary suite, plan9port for the command shell's rc
    # oracle, which `make check` compares the shell against). tla-tools is left out on purpose: only
    # `make check-tla` uses it, and its pin is a separate matter. The OCI
    # oracle image is left out because the native oracle does not use it.
    SOURCE_IDS = %w[otp musl arm-registers libc-test plan9port].freeze

    Step = Data.define(:name, :kind, :argv, :deadline)

    # `oracle build`'s own default deadline (tools/erx, the oracle command), which a
    # setup step must not cut short: a killed build restarts from nothing.
    ORACLE_BUILD_DEADLINE = 14_400

    COMMAND_STEPS = [
      Step.new(name: 'oracle-jit', kind: :command, deadline: ORACLE_BUILD_DEADLINE,
               argv: %w[oracle build --backend native --flavour jit]),
      Step.new(name: 'oracle-emu', kind: :command, deadline: ORACLE_BUILD_DEADLINE,
               argv: %w[oracle build --backend native --flavour emu]),
      Step.new(name: 'runtime', kind: :command, deadline: ORACLE_BUILD_DEADLINE,
               argv: %w[build runtime]),
      Step.new(name: 'rc-oracle', kind: :command, deadline: ORACLE_BUILD_DEADLINE,
               argv: %w[build rc-oracle])
    ].freeze

    ALL_STEPS = (SOURCE_IDS.map do |id|
      Step.new(name: "source-#{id}", kind: :source, argv: [id], deadline: 300)
    end + COMMAND_STEPS).freeze

    # present: a hash of step name => true when the step's output is valid.
    # Returns the steps still to run, in dependency order.
    def self.plan(present)
      ALL_STEPS.reject { |step| present.fetch(step.name, false) }
    end

    # Where another checkout keeps verified archives, derived from a cache
    # directory such as <checkout>/build/third_party.
    def self.archive_directory(cache)
      File.join(File.dirname(File.expand_path(cache)), 'downloads')
    end

    def initialize(root:, runner: nil, cache: ENV.fetch('ERX_SOURCE_CACHE', nil), jobs: 4, env: ENV.to_h)
      @root = File.expand_path(root)
      @runner = runner || Runner.new(owner_root: @root, log_dir: File.join(@root, 'build/logs'))
      @cache = cache.to_s.empty? ? nil : cache
      @jobs = jobs
      @env = env
      @dependencies = Dependencies.new(root: @root, runner: @runner)
    end

    def call
      steps = self.class.plan(present)
      return [] if steps.empty?

      toolchain = toolchain_env
      steps.each { |step| perform(step, toolchain) }
      steps.map(&:name)
    end

    def present
      ALL_STEPS.to_h { |step| [step.name, valid?(step)] }
    end

    private

    def valid?(step)
      case step.name
      when /\Asource-(.*)/ then source_valid?(Regexp.last_match(1))
      when 'oracle-jit' then File.file?(File.join(@root, 'build/oracle/jit/build.json'))
      when 'oracle-emu' then File.file?(File.join(@root, 'build/oracle/emu/build.json'))
      when 'runtime' then File.file?(File.join(@root, 'build/runtime/hosted/release/system.pack'))
      when 'rc-oracle' then File.file?(File.join(@root, RcOracle::OUTPUT, 'rc'))
      end
    end

    def source_valid?(id)
      marker = File.join(@root, 'build/third_party', id, '.source.json')
      return false if File.symlink?(marker) || !File.file?(marker)

      JsonInput.parse(BoundedFile.read(marker, maximum: 65_536), max_bytes: 65_536,
                      label: 'source download record') == @dependencies.sources.find { |source| source['id'] == id }
    rescue Error
      false
    end

    def perform(step, toolchain)
      Terminal.puts("setup: #{step.name}")
      if step.kind == :source
        obtain_source(step.argv.first)
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
    def obtain_source(id)
      if @cache
        origin = File.join(self.class.archive_directory(@cache), archive_name(id))
        raise Error, "source not found in ERX_SOURCE_CACHE: #{origin}" unless File.file?(origin)

        @dependencies.adopt(id, from: origin)
      end
      require_local_archive(id)
      @dependencies.fetch(source_id: id)
    rescue Error => e
      raise Error, "#{e.message}; run `make fetch` or set ERX_SOURCE_CACHE to another checkout's build/third_party"
    end

    # Dependencies#fetch would download a missing archive; setup must not.
    def require_local_archive(id)
      return if File.file?(File.join(@root, 'build/downloads', archive_name(id)))

      raise Error, "source #{id} is not downloaded"
    end

    def archive_name(id)
      @dependencies.sources.find { |source| source['id'] == id }.then do |source|
        "#{id}-#{source.fetch('sha256')}.tar.gz"
      end
    end

    # The LLVM tools the native builds need, when the caller has not chosen.
    def toolchain_env
      { 'ERX_CLANG' => '/opt/homebrew/opt/llvm/bin/clang', 'ERX_LLD' => '/opt/homebrew/bin/ld.lld' }
        .reject { |name, path| @env.fetch(name, '') != '' || !File.executable?(path) }
    end
  end
end
