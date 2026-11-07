# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
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
    # The function API's test has a main of its own, so the entry and what only it calls join here.
    LIBERX_SOURCES = [*HostedSources::ALL.reject { |source| source.start_with?(HostedSources::GUEST) },
                      'liberx/backend/core/boot_info.c', 'liberx/backend/core/boot_manifest.c',
                      'liberx/backend/hosted/start.c'].freeze
    # The tracked trees the hosted archive and the release's manifest are compiled from, for
    # the build record; their generated C is in the generated tree, which SOURCE_TREES adds.
    LIBERX_TREES = %w[config/manifest include kernel/core kernel/crypto/blake3 liberx].freeze
    # Every tree a runtime is built from, whose digest marks a build stale: the
    # generated tree among them, so a change to a generator's input does too.
    SOURCE_TREES = ['otp', 'littlefs', ErlangApps::SOURCE, *LIBERX_TREES, Generated::OUTPUT].freeze
    # What the build copies over the OTP copy from the generated tree: the files the
    # generators write beneath otp/, such as erts/preloaded/src/erx_9p_grammar.erl. The
    # emulator still embeds the checked-in beams of otp/erts/preloaded/ebin (TODO.md).
    GENERATED_OTP = File.join(Generated::OUTPUT, 'otp')
    LIBERX_FLAGS = %w[-std=c17 -D_DARWIN_C_SOURCE -D_GNU_SOURCE -Wall -Wextra -Werror -pedantic -O2 -g -pthread
                      -I build/gen -I build/gen/include -I include -I build/gen/kernel/generated -I kernel/core -I kernel/crypto -I .].freeze
    # OTP's applications in the release, each built by both runtimes: what a shell needs,
    # and compiler and runtime_tools, which docs/design-runtime.md keeps and the release
    # loads without starting (ReleaseFiles::LOAD_ONLY). The build itself boots from the
    # tracked bootstrap/bin/start.boot. OTP's `libs` and `start_scripts` targets
    # are not usable: lib/tools's crashdump.erl includes public_key.hrl and
    # erts/start_scripts needs lib/os_mon/vsn.mk, and the import excludes both.
    APPLICATIONS = %w[kernel stdlib compiler runtime_tools].freeze
    # otp/ tracks prebuilt beams with their sources' file times, so make could keep one
    # older than a source edit. These never enter the copy, and make compiles them.
    BUILT_BEAMS = APPLICATIONS.map { |application| "--exclude=/lib/#{application}/ebin/*.beam" }.freeze
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

    def build(jobs: 4)
      raise Error, 'the hosted runtime builds only on macOS' unless RUBY_PLATFORM.include?('darwin')

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
    # Each one goes before make runs.
    def remove_orphan_beams(otp)
      APPLICATIONS.each do |application|
        modules = Dir.glob('**/*.{erl,yrl,xrl}', base: File.join(otp, 'lib', application)).map { |path| File.basename(path, '.*') }
        ebin = in_copy(File.join('lib', application, 'ebin'))
        Dir.glob('*.beam', base: ebin).reject { |beam| modules.include?(File.basename(beam, '.beam')) }
           .each { |beam| FileUtils.rm_f(File.join(ebin, beam)) }
      end
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
    # forgets them too. A file of otp/ at a generated file's path is refused, so
    # neither silently stands in for the other in the copy.
    def copy_sources
      otp = File.join(@root, 'otp')
      generated = File.join(@root, GENERATED_OTP)
      inputs = self.class.configure_inputs(otp: otp)
      stamp = self.class.configure_stamp(otp: otp, inputs: inputs, sdk_root: sdk_root)
      shadowing = Dir.glob('**/*', base: generated).select do |relative|
        File.file?(File.join(generated, relative)) && File.exist?(File.join(otp, relative))
      end
      unless shadowing.empty?
        raise Error, "otp/#{shadowing.first} is at the path of the generated #{GENERATED_OTP}/#{shadowing.first}; remove it"
      end

      FileUtils.rm_rf(@output.root) unless stored(in_copy('.erx-configure-stamp')) == stamp
      FileUtils.mkdir_p(@output.root)
      @runner.run(['rsync', '-a', *BUILT_BEAMS, "#{otp}/", "#{@output.root}/"], name: 'runtime-copy', deadline: DEADLINES.fetch(:copy))
      if File.directory?(generated)
        @runner.run(['rsync', '-a', "#{generated}/", "#{@output.root}/"], name: 'runtime-copy-generated',
                                                                            deadline: DEADLINES.fetch(:copy))
      end
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
    def build_emulator(jobs:)
      # The archive comes in through LIBS, which is no make dependency, so each build
      # links again. Both executables go: beam.smp is copied from beam.emu, and the
      # makefile's empty .SECONDARY makes a missing beam.emu no reason to link while
      # beam.smp exists.
      FileUtils.rm_f([@output.beam, File.join(File.dirname(@output.beam), 'beam.smp')])
      @runner.run(['gmake', "-j#{jobs}", '-C', 'erts/emulator', 'opt', 'FLAVOR=emu', "TARGET=#{self.class::TARGET}"],
                  name: 'runtime-emulator', deadline: DEADLINES.fetch(:emulator), chdir: @output.root,
                  env: build_environment)
      raise Error, "the emulator's build left no #{@output.beam}" unless File.file?(@output.beam)
    end

    # An application's Erlang alone: runtime_tools's c_src holds the trace port drivers
    # and the dyntrace NIF, which docs/design-runtime.md does not ship.
    def build_application(application, jobs:)
      @runner.run(['gmake', "-j#{jobs}", '-C', "lib/#{application}/src", 'opt', "TARGET=#{self.class::TARGET}"],
                  name: "runtime-#{application}", deadline: DEADLINES.fetch(:libs), chdir: @output.root,
                  env: build_environment)
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
        'PATH' => [File.dirname(@oracle.erl_path(HOST_OTP_FLAVOUR)), ENV.fetch('PATH')].join(File::PATH_SEPARATOR),
        'ERX_HOSTED_LIBERX' => @output.liberx,
        'ERX_SDKROOT' => sdk_root,
        'ERX_TREE' => @root,
        'ERX_GEN' => File.join(@root, Generated::OUTPUT)
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
