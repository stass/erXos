# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require_relative 'asn1_specifications'
require_relative 'dependencies'
require_relative 'domain_image_apps'
require_relative 'erlang_apps'
require_relative 'error'
require_relative 'generated'
require_relative 'hosted_sources'
require_relative 'oracle'
require_relative 'output_directory'
require_relative 'runner'

module Erx
  # `tools/erx build runtime`: the one way into OTP's inherited configure and
  # make. OTP builds inside its source tree, and otp/ is read only to a build, so
  # everything happens in a private copy under build/runtime. Erlang code is
  # compiled by the stock oracle's erlc of the same release, which is also where
  # OTP's cross build finds yielding_c_fun.
  class Runtime
    TARGET = 'aarch64-hosted-erxos'
    XCOMP_FILE = "xcomp/erl-xcomp-#{TARGET}.conf".freeze
    # The host OTP on PATH. Host tests hold an exclusive lock on the `jit` oracle
    # while they run, and this build only reads, so it stays off that one.
    HOST_OTP_FLAVOUR = 'emu'
    # The emulator flavour OTP's make builds: the interpreter, unless a subclass says otherwise.
    FLAVOR = 'emu'
    # The function API's test has a main of its own, so the entry and what only it calls join here,
    # with the lanes, the funnel and the ETF reader ERTS's lane port driver calls, the pipe core
    # and runner its pipe NIF calls, and what the
    # domain service's NIF module links where no domain library is built: the library's refusing
    # entries, the crash dump reader and hosted's refusals of the calls only a library makes.
    LIBERX_SOURCES = [*HostedSources::ALL.reject { |source| source.start_with?(HostedSources::GUEST) },
                      'liberx/backend/core/boot_info.c', 'liberx/backend/core/boot_manifest.c',
                      'liberx/backend/hosted/start.c', 'liberx/erx_lane.c', 'liberx/erx_funnel.c',
                      'liberx/erx_etf.c', 'liberx/erx_pipe_check.c', 'liberx/erx_pipe_core.c', 'liberx/erx_pipe_run.c',
                      'liberx/backend/core/dom_lib_none.c', 'liberx/system/dom_dump.c',
                      'liberx/backend/hosted/refused.c'].freeze
    # The tracked trees the hosted archive and the release's manifest are compiled from, for
    # the build record; their generated C is in the generated tree, which SOURCE_TREES adds.
    LIBERX_TREES = %w[config/manifest include kernel/core kernel/crypto/blake3 liberx].freeze
    # Every tree a runtime is built from, whose digest marks a build stale: the
    # generated tree among them, so a change to a generator's input does too.
    SOURCE_TREES = ['otp', 'littlefs', ErlangApps::SOURCE, ErlangApps::TEST_SOURCE, *LIBERX_TREES, Generated::OUTPUT].freeze
    # What the build copies over the OTP copy from the generated tree: the files the
    # generators write beneath otp/, such as erts/preloaded/src/erx_9p_grammar.erl, which
    # the emulator embeds compiled with the other preloaded modules (build_emulator).
    GENERATED_OTP = File.join(Generated::OUTPUT, 'otp')
    LIBERX_FLAGS = %w[-std=c17 -D_DARWIN_C_SOURCE -D_GNU_SOURCE -Wall -Wextra -Werror -pedantic -O2 -g -pthread
                      -I build/gen -I build/gen/include -I include -I build/gen/kernel/generated -I kernel/core -I kernel/crypto -I .].freeze
    # OTP's applications the releases ship, each built by both runtimes: what a shell needs,
    # and compiler and runtime_tools, which docs/design-runtime.md keeps and the release
    # loads without starting (ReleaseFiles::LOAD_ONLY). OTP's `libs` and `start_scripts`
    # targets are not usable: lib/tools's crashdump.erl includes public_key.hrl and
    # erts/start_scripts needs lib/os_mon/vsn.mk, and the import excludes both. The
    # applications only a domain's runtime image runs (DomainImageApps) come last and ship
    # in the domain releases that ask for them (ReleaseFiles::RELEASE_SCRIPTS), never in
    # the system release (docs/design-crypto.md, "OTP's applications").
    APPLICATIONS = [*%w[kernel stdlib compiler runtime_tools], *DomainImageApps::APPLICATIONS].freeze
    # What an application's make is given beyond the build's own variables. asn1 ships
    # its run-time module, asn1rt_nif, alone: with CT_MODULES empty its make builds that
    # module and the .app, which lists only it, and neither the ASN.1 compiler nor the
    # templates it is generated from (docs/design-crypto.md, "OTP's applications").
    # public_key's asn1 make runs the ASN.1 compiler, the stock oracle's erlc, on the
    # host, writing the Erlang it generates from public_key's specifications into its
    # src; ERL_DETERMINISTIC=yes passes +deterministic, which keeps the directories it
    # ran in out of every generated module, so another checkout generates the same bytes.
    MAKE_VARIABLES = { 'asn1' => %w[CT_MODULES=].freeze, 'public_key' => %w[ERL_DETERMINISTIC=yes].freeze }.freeze
    # Where an application's make runs, in order: its src, and for public_key first its
    # asn1, whose make generates the Erlang of public_key's ASN.1 modules and compiles it
    # into the same ebin, in the order of OTP's own lib/public_key/Makefile.
    MAKE_DIRECTORIES = { 'public_key' => %w[asn1 src].freeze }.freeze
    # Where OTP keeps beams and boot scripts built from its sources: the build's own make
    # writes erts/ebin and each application's ebin, and the others held prebuilt copies.
    # otp/ORIGIN.md excludes each, so make check refuses a file there, and the copy takes
    # nothing from them, so a stray file, such as the output of a make run inside otp/,
    # is neither kept by make over a newer source nor embedded nor shipped.
    BUILD_OUTPUTS = ['bootstrap', 'erts/ebin', 'erts/preloaded/ebin',
                     *APPLICATIONS.map { |application| "lib/#{application}/ebin" }].freeze
    # What configure reads from otp/ besides the cross file: the templates it turns into
    # the makefiles and headers make reads, its scripts, the release's version, which
    # it writes into the makefiles, and otp_build, which runs it.
    CONFIGURE_INPUTS = %w[**/*.in **/configure **/config.sub **/config.guess OTP_VERSION otp_build].freeze
    # The one file time every configure input has in the copy. OTP's makefiles ask for
    # configure again when a template is newer than what configure made from it, and the
    # copy would carry otp/'s times, which a checkout moves without changing a byte. The
    # stamp, over the inputs' bytes, alone decides when to configure again; this time,
    # older than anything configure writes, keeps make's own rule from deciding too.
    CONFIGURE_INPUT_TIME = Time.utc(2000, 1, 1)
    # Deadlines in seconds, each many times what a clean build took on an idle host.
    DEADLINES = { compile: 120, copy: 300, configure: 1_800, emulator: 1_800, libs: 1_800 }.freeze
    # What the build leaves for the hosted smoke test and the seam check.
    Output = Data.define(:root, :beam, :objects, :liberx, :archive)

    def self.output(root:)
      otp = File.join(root, 'build/runtime/hosted/otp')
      Output.new(root: otp, beam: File.join(otp, 'bin', TARGET, 'beam.emu'),
                 objects: File.join(otp, 'erts/emulator/obj', TARGET, 'opt/emu'),
                 liberx: File.join(root, 'build/runtime/hosted/liberx/liberx_hosted.a'),
                 archive: File.join(root, 'build/runtime/hosted/release/system.pack'))
    end

    # Whether what is built is what the tree holds: a check that read an older
    # build, or the remains of a failed one, would report on code that is gone.
    def self.check_current(root:, generated: Generated)
      record = record_path(output(root: root))
      raise Error, 'hosted runtime not built: run tools/erx build runtime' unless File.file?(record)
      return if File.read(record) == source_digest(root: root, generated: generated)

      raise Error, "hosted runtime is stale, a file under #{SOURCE_TREES.join(', ')} changed: run tools/erx build runtime"
    end

    def self.record_path(output) = File.join(output.root, '.erx-build-record')

    # Brings the generated tree up to date first (generated is Erx::Generated or a
    # stand-in), so an edit to a generator's input changes the digest as an edit to
    # otp/ does, and whoever digests reads the tree the build reads. The tree's stamp
    # is left out: it names the generators' code too, and a change there that writes
    # the same files changes no build.
    def self.source_digest(root:, generated: Generated)
      generated.ensure(root: root)
      stamp = File.join(Generated::OUTPUT, Generated::STAMP)
      digests = SOURCE_TREES.flat_map do |tree|
        Dir.glob(File.join(tree, '**/*'), File::FNM_DOTMATCH, base: root).sort.filter_map do |path|
          next if path == stamp
          absolute = File.join(root, path)
          "#{path} #{Digest::SHA256.file(absolute).hexdigest}" if File.file?(absolute)
        end
      end
      Digest::SHA256.hexdigest(digests.join("\n"))
    end

    # Configure's inputs, as paths relative to otp/.
    def self.configure_inputs(otp:) = [*Dir.glob(CONFIGURE_INPUTS, base: otp), self::XCOMP_FILE].uniq.sort

    def self.configure_stamp(otp:, inputs:, sdk_root:)
      lines = inputs.map { |path| "#{path} #{Digest::SHA256.file(File.join(otp, path)).hexdigest}" }
      Digest::SHA256.hexdigest([sdk_root, *lines].join("\n"))
    end

    def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                   oracle: Oracle.new(root: root, runner: runner), sdk_root: nil, generated: Generated)
      @root = File.expand_path(root)
      @runner = runner
      @oracle = oracle
      @generated = generated
      @sdk_root = sdk_root
      @output = self.class.output(root: @root)
      OutputDirectory.check(root: @root, path: File.join(@root, 'build/runtime/hosted'))
    end

    # The hosted runtime and the hosted backend under it build only on macOS.
    HOST_RULE = 'the hosted runtime and its backend build only on macOS'
    def self.host_supported?(platform: RUBY_PLATFORM) = platform.include?('darwin')

    # The host test files that test only the hosted runtime or backend, so every
    # test in them skips on another host. There the check leaves them out and
    # reports each as not run, where running them would end in a file that ran
    # no tests. On macOS they run, and a file skipping every test still fails.
    HOSTED_ONLY_TESTS = %w[
      test/host/hosted_executor_test.rb
      test/host/hosted_function_api_test.rb
      test/host/runtime_build_test.rb
    ].freeze

    # The browser tests run Playwright's Chromium, which deps.lock pins for one host.
    BROWSER_RULE = "deps.lock pins Playwright's Chromium for macOS on arm64 only"
    BROWSER_TESTS = %w[test/host/web_browser_test.rb].freeze

    # Test files only some hosts run: the files, why another host leaves them out,
    # and whether a host of platform (a RUBY_PLATFORM) runs them.
    HostOnly = Data.define(:paths, :reason, :runs_on)
    HOST_ONLY = [
      HostOnly.new(paths: HOSTED_ONLY_TESTS, reason: HOST_RULE, runs_on: ->(platform) { host_supported?(platform: platform) }),
      HostOnly.new(paths: BROWSER_TESTS, reason: BROWSER_RULE,
                   runs_on: ->(platform) { DependencySchema::HOSTS.fetch('darwin-arm64').match?(platform) }),
    ].freeze

    # The host test files to run on this host, and each one left out with why.
    HostTestPlan = Data.define(:run, :not_run)
    NotRun = Data.define(:path, :reason)

    # Splits paths, each root joined with a path relative to the tree, by
    # HOST_ONLY.
    # A listed file that does not exist raises, so a renamed file cannot drop
    # out of the list and start failing, or the list keep a stale name.
    def self.host_test_plan(paths, root:, platform: RUBY_PLATFORM)
      rules = HOST_ONLY.map { |rule| [rule, rule.paths.map { |path| File.join(root, path) }] }
      missing = rules.flat_map(&:last).reject { |path| File.file?(path) }
      raise Error, "a host-only test list names missing files: #{missing.join(' ')}" unless missing.empty?

      not_run = rules.reject { |rule, _listed| rule.runs_on.call(platform) }.flat_map do |rule, listed|
        (paths & listed).map { |path| NotRun.new(path: path, reason: rule.reason) }
      end
      HostTestPlan.new(run: paths - not_run.map(&:path), not_run: not_run)
    end

    def build(jobs: 4)
      raise Error, HOST_RULE unless self.class.host_supported?

      @oracle.verify(HOST_OTP_FLAVOUR)
      FileUtils.rm_f(self.class.record_path(@output))
      # Also brings build/gen up to date, which the steps below read.
      digest = self.class.source_digest(root: @root, generated: @generated)
      build_liberx
      copy_sources
      configure unless File.file?(in_copy('.erx-configured'))
      build_emulator(jobs: jobs)
      APPLICATIONS.each { |application| build_application(application, jobs: jobs) }
      build_erlang_apps
      File.write(self.class.record_path(@output), digest)
      @output
    end

    private

    # make removes nothing, so a beam it built for a module whose source has since left
    # otp/lib, or moved to erlang/apps, would stay in the copy's ebin and reach the release.
    # Each one goes before make runs. A module's source is its Erlang, the parser or lexer
    # definition yecc or leex generates it from, or the ASN.1 specification public_key's
    # asn1 make generates it from (modules_with_generated_erlang).
    def remove_orphan_beams(otp)
      APPLICATIONS.each do |application|
        sources = Dir.glob('**/*.{erl,yrl,xrl}', base: File.join(otp, 'lib', application))
        modules = [*sources.map { |path| File.basename(path, '.*') }, *modules_with_generated_erlang(otp, application)]
        ebin = in_copy(File.join('lib', application, 'ebin'))
        Dir.glob('*.beam', base: ebin).reject { |beam| modules.include?(File.basename(beam, '.beam')) }
           .each { |beam| FileUtils.rm_f(File.join(ebin, beam)) }
      end
    end

    # The modules generated from an application's ASN.1 specifications (Asn1Specifications)
    # whose generated Erlang the copy holds. A beam of one whose Erlang is gone goes too:
    # make takes that Erlang for an intermediate file, which it does not generate again
    # for a beam it finds newer than the specification, and the src make would then miss
    # the headers generated beside it.
    def modules_with_generated_erlang(otp, application)
      Asn1Specifications.modules(File.join(otp, 'lib', application, 'asn1'))
                        .select { |name| File.file?(in_copy(File.join('lib', application, 'src', "#{name}.erl"))) }
    end

    def build_liberx
      directory = File.dirname(@output.liberx)
      FileUtils.mkdir_p(directory)
      objects = LIBERX_SOURCES.each_with_index.map do |source, index|
        object = File.join(directory, "#{index}_#{File.basename(source)}.o")
        @runner.run(['clang', *LIBERX_FLAGS, '-c', source, '-o', object], name: 'runtime-liberx',
                    deadline: DEADLINES.fetch(:compile), chdir: @root)
        object
      end
      FileUtils.rm_f(@output.liberx)
      @runner.run(['ar', 'rcs', @output.liberx, *objects], name: 'runtime-liberx-archive',
                  deadline: DEADLINES.fetch(:compile), chdir: @root)
    end

    # OTP's build holds no record of what its tree held. A change to what configure
    # reads starts again from an empty copy, and a file that left otp/ or the generated
    # tree's otp/ leaves the copy. These records live in the copy, so removing the copy
    # forgets them too. otp/ and the generated tree share no path (Generated.ensure
    # refuses a file of the tree at a generated file's path), and a generated tree
    # without otp/ is refused rather than copied as if it held nothing.
    def copy_sources
      otp = File.join(@root, 'otp')
      generated = File.join(@root, GENERATED_OTP)
      inputs = self.class.configure_inputs(otp: otp)
      stamp = self.class.configure_stamp(otp: otp, inputs: inputs, sdk_root: sdk_root)
      raise Error, "the generated tree has no otp/ (#{GENERATED_OTP}); regenerate it" unless File.directory?(generated)

      FileUtils.rm_rf(@output.root) unless stored(in_copy('.erx-configure-stamp')) == stamp
      FileUtils.mkdir_p(@output.root)
      @runner.run(['rsync', '-a', *BUILD_OUTPUTS.map { |path| "--exclude=/#{path}/" }, "#{otp}/", "#{@output.root}/"],
                  name: 'runtime-copy', deadline: DEADLINES.fetch(:copy))
      @runner.run(['rsync', '-a', "#{generated}/", "#{@output.root}/"], name: 'runtime-copy-generated',
                                                                          deadline: DEADLINES.fetch(:copy))
      paths = [otp, generated].flat_map { |tree| Dir.glob('**/*', File::FNM_DOTMATCH, base: tree) }.uniq.sort
      (stored(in_copy('.erx-paths')).to_s.lines(chomp: true) - paths).each { |path| FileUtils.rm_f(in_copy(path)) }
      File.write(in_copy('.erx-paths'), paths.join("\n"))
      remove_orphan_beams(otp)
      pin_configure_inputs(inputs)
      File.write(in_copy('.erx-configure-stamp'), stamp)
    end

    # lutime sets a link's own time, not its target's, so no file outside the copy is
    # touched. The stamp was taken over the same list, so a missing input is otp/
    # changing under the build.
    def pin_configure_inputs(inputs)
      inputs.each { |path| File.lutime(CONFIGURE_INPUT_TIME, CONFIGURE_INPUT_TIME, in_copy(path)) }
    rescue SystemCallError => e
      raise Error, "cannot set the time of configure's input in #{@output.root}: #{e.message}; otp/ changed during the build"
    end

    def stored(path) = File.file?(path) ? File.read(path) : nil
    def in_copy(path) = File.join(@output.root, path)

    def configure
      @runner.run(['./otp_build', 'configure', "--xcomp-conf=#{in_copy(self.class::XCOMP_FILE)}"],
                  name: 'runtime-configure', deadline: DEADLINES.fetch(:configure), chdir: @output.root,
                  env: build_environment)
      FileUtils.touch(in_copy('.erx-configured'))
    end

    # erts/emulator alone, not OTP's `emulator` target: that one also builds
    # erts/etc, whose programs (erlexec, erlc, heart, inet_gethost) all include ei.h
    # from lib/erl_interface, which the import excludes. The runtime is started
    # without them. The emulator's makefile runs erts/lib_src's make, whose archives
    # it links, on every build.
    #
    # The emulator embeds the preloaded modules, so they are compiled first, by
    # erts/preloaded/src's own opt target, into erts/ebin, where the emulator's
    # PRELOAD_BEAM names them and make_preload strips each one as it embeds it. The copy
    # takes nothing from erts/ebin (BUILD_OUTPUTS).
    #
    # Every build empties erts/ebin first, so what is embedded is compiled by this build
    # from the copy's sources, the generated grammar among them, and from the generated
    # headers they include. make's rule for a beam names only its .erl, so a kept beam
    # would survive a change to such a header, to the preloaded Makefile's flags or to
    # the module list.
    #
    # One consequence: preload.c is made again on every build, and each of the emulator's
    # dependency files has it as a prerequisite (erts/emulator/Makefile.in), so make
    # computes them again before it judges any object, and they name every header a
    # source includes at that build, generated ones among them.
    def build_emulator(jobs:)
      FileUtils.rm_rf(in_copy('erts/ebin'))
      @runner.run(['gmake', "-j#{jobs}", '-C', 'erts/preloaded/src', 'opt', "TARGET=#{self.class::TARGET}"],
                  name: 'runtime-preloaded', deadline: DEADLINES.fetch(:libs), chdir: @output.root,
                  env: build_environment)
      # The archive comes in through LIBS, which is no make dependency, so each build
      # links again. Both executables go: beam.smp is copied from beam.emu, and the
      # makefile's empty .SECONDARY makes a missing beam.emu no reason to link while
      # beam.smp exists.
      FileUtils.rm_f([@output.beam, File.join(File.dirname(@output.beam), 'beam.smp')])
      @runner.run(['gmake', "-j#{jobs}", '-C', 'erts/emulator', 'opt', "FLAVOR=#{self.class::FLAVOR}", "TARGET=#{self.class::TARGET}"],
                  name: 'runtime-emulator', deadline: DEADLINES.fetch(:emulator), chdir: @output.root,
                  env: build_environment)
      raise Error, "the emulator's build left no #{@output.beam}" unless File.file?(@output.beam)
    end

    # An application's Erlang alone: runtime_tools's c_src holds the trace port drivers
    # and the dyntrace NIF, which docs/design-runtime.md does not ship, and public_key's
    # holds the reader of the system's certificate store, a NIF only on Windows. The
    # application's make writes into ../ebin without creating it, and otp/ tracks no ebin,
    # so the build makes the directory.
    def build_application(application, jobs:)
      FileUtils.mkdir_p(in_copy(File.join('lib', application, 'ebin')))
      MAKE_DIRECTORIES.fetch(application, %w[src]).each do |directory|
        @runner.run(['gmake', "-j#{jobs}", '-C', "lib/#{application}/#{directory}", 'opt', "TARGET=#{self.class::TARGET}",
                     *MAKE_VARIABLES.fetch(application, [])],
                    name: "runtime-#{application}-#{directory}", deadline: DEADLINES.fetch(:libs), chdir: @output.root,
                    env: build_environment)
      end
    end

    # erXos's own applications, into the copy's lib/ beside OTP's, by the same erlc.
    def build_erlang_apps
      erlc = File.join(File.dirname(@oracle.erl_path(HOST_OTP_FLAVOUR)), 'erlc')
      ErlangApps.new(root: @root, runner: @runner, erlc: erlc).build(otp: @output.root)
    end

    def build_environment
      Oracle::CLEAN_ERLANG_ENV.merge(
        'ERL_TOP' => @output.root,
        # No host path in a beam, so another checkout builds the same bytes.
        'ERL_COMPILE_FLAGS' => '+deterministic',
        # The stock oracle's erl, erlc and escript run every Erlang step of the build.
        'PATH' => [File.dirname(@oracle.erl_path(HOST_OTP_FLAVOUR)), ENV.fetch('PATH')].join(File::PATH_SEPARATOR),
        'ERX_HOSTED_LIBERX' => @output.liberx,
        'ERX_SDKROOT' => sdk_root,
        'ERX_TREE' => @root,
        'ERX_GEN' => File.join(@root, Generated::OUTPUT),
        # The hosted runtime links no static NIF of DomainImageApps and never makes
        # erx_crypto_tab, whose recipe refuses this empty list.
        'ERX_CRYPTO_NIF_LIBS' => ''
      ).freeze
    end

    def sdk_root
      @sdk_root ||= begin
        output, status = Open3.capture2('gtimeout', '-k', '10', '60', 'xcrun', '--show-sdk-path', in: File::NULL)
        raise Error, 'xcrun does not name a macOS SDK' unless status.success?

        output.strip
      end
    end
  end
end
