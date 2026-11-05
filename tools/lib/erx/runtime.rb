# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require_relative 'error'
require_relative 'function_api'
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
    LIBERX_SOURCES = [*FunctionApi::HOSTED_SOURCES.reject { |source| source.start_with?(FunctionApi::GUEST) },
                      'liberx/backend/core/boot_info.c', 'liberx/backend/core/boot_manifest.c',
                      'liberx/backend/hosted/start.c'].freeze
    # What the hosted archive is compiled from and the release's manifest, for the build record.
    LIBERX_TREES = %w[config/manifest include kernel/core kernel/crypto/blake3 kernel/generated liberx].freeze
    LIBERX_FLAGS = %w[-std=c17 -D_DARWIN_C_SOURCE -D_GNU_SOURCE -Wall -Wextra -Werror -pedantic -O2 -g -pthread
                      -I include -I kernel/generated -I kernel/core -I kernel/crypto -I .].freeze
    # What a shell needs; it boots from the tracked bootstrap/bin/start.boot. OTP's
    # `libs` and `start_scripts` targets are not usable: lib/tools's crashdump.erl
    # includes public_key.hrl and erts/start_scripts needs lib/os_mon/vsn.mk, and
    # the import excludes both.
    APPLICATIONS = %w[kernel stdlib compiler].freeze
    # otp/ tracks prebuilt beams with their sources' file times, so make could keep one
    # older than a source edit. These never enter the copy, and make compiles them.
    BUILT_BEAMS = %w[kernel stdlib].map { |application| "--exclude=/lib/#{application}/ebin/*.beam" }.freeze
    # The templates configure turns into the makefiles and headers make reads.
    CONFIGURE_INPUTS = %w[**/*.in **/configure **/config.sub **/config.guess].freeze
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
    def self.check_current(root:)
      record = record_path(output(root: root))
      raise Error, 'hosted runtime not built: run tools/erx build runtime' unless File.file?(record)
      return if File.read(record) == source_digest(root: root)

      raise Error, 'hosted runtime is stale, otp/ or liberx changed: run tools/erx build runtime'
    end

    def self.record_path(output) = File.join(output.root, '.erx-build-record')

    def self.source_digest(root:)
      digests = ['otp', *LIBERX_TREES].flat_map do |tree|
        Dir.glob(File.join(tree, '**/*'), File::FNM_DOTMATCH, base: root).sort.filter_map do |path|
          absolute = File.join(root, path)
          "#{path} #{Digest::SHA256.file(absolute).hexdigest}" if File.file?(absolute)
        end
      end
      Digest::SHA256.hexdigest(digests.join("\n"))
    end

    def self.configure_stamp(otp:, sdk_root:)
      paths = [*Dir.glob(CONFIGURE_INPUTS, base: otp), XCOMP_FILE].uniq.sort
      lines = paths.map { |path| "#{path} #{Digest::SHA256.file(File.join(otp, path)).hexdigest}" }
      Digest::SHA256.hexdigest([sdk_root, *lines].join("\n"))
    end

    def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                   oracle: Oracle.new(root: root, runner: runner), sdk_root: nil)
      @root = File.expand_path(root)
      @runner = runner
      @oracle = oracle
      @sdk_root = sdk_root
      @output = self.class.output(root: @root)
      OutputDirectory.check(root: @root, path: File.join(@root, 'build/runtime/hosted'))
    end

    def build(jobs: 4)
      raise Error, 'the hosted runtime builds only on macOS' unless RUBY_PLATFORM.include?('darwin')

      @oracle.verify(HOST_OTP_FLAVOUR)
      FileUtils.rm_f(self.class.record_path(@output))
      digest = self.class.source_digest(root: @root)
      build_liberx
      copy_sources
      configure unless File.file?(in_copy('.erx-configured'))
      build_emulator(jobs: jobs)
      APPLICATIONS.each { |application| build_application(application, jobs: jobs) }
      File.write(self.class.record_path(@output), digest)
      @output
    end

    private

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
    # reads starts again from an empty copy, and a file that left otp/ leaves the copy.
    # These records live in the copy, so removing the copy forgets them too.
    def copy_sources
      otp = File.join(@root, 'otp')
      stamp = self.class.configure_stamp(otp: otp, sdk_root: sdk_root)
      FileUtils.rm_rf(@output.root) unless stored(in_copy('.erx-configure-stamp')) == stamp
      FileUtils.mkdir_p(@output.root)
      @runner.run(['rsync', '-a', *BUILT_BEAMS, "#{otp}/", "#{@output.root}/"], name: 'runtime-copy', deadline: DEADLINES.fetch(:copy))
      paths = Dir.glob('**/*', File::FNM_DOTMATCH, base: otp).sort
      (stored(in_copy('.erx-paths')).to_s.lines(chomp: true) - paths).each { |path| FileUtils.rm_f(in_copy(path)) }
      File.write(in_copy('.erx-paths'), paths.join("\n"))
      File.write(in_copy('.erx-configure-stamp'), stamp)
    end

    def stored(path) = File.file?(path) ? File.read(path) : nil
    def in_copy(path) = File.join(@output.root, path)

    def configure
      @runner.run(['./otp_build', 'configure', "--xcomp-conf=#{in_copy(XCOMP_FILE)}"],
                  name: 'runtime-configure', deadline: DEADLINES.fetch(:configure), chdir: @output.root,
                  env: build_environment)
      FileUtils.touch(in_copy('.erx-configured'))
    end

    # erts/emulator alone, not OTP's `emulator` target: that one also builds
    # erts/etc, whose programs (erlexec, erlc, heart, inet_gethost) all include ei.h
    # from lib/erl_interface, which the import excludes. The runtime is started
    # without them.
    def build_emulator(jobs:)
      # The archive comes in through LIBS, which is no make dependency, so each build
      # links again. Both executables go: beam.smp is copied from beam.emu, and the
      # makefile's empty .SECONDARY makes a missing beam.emu no reason to link while
      # beam.smp exists.
      FileUtils.rm_f([@output.beam, File.join(File.dirname(@output.beam), 'beam.smp')])
      @runner.run(['gmake', "-j#{jobs}", '-C', 'erts/emulator', 'opt', 'FLAVOR=emu', "TARGET=#{TARGET}"],
                  name: 'runtime-emulator', deadline: DEADLINES.fetch(:emulator), chdir: @output.root,
                  env: build_environment)
      raise Error, "the emulator's build left no #{@output.beam}" unless File.file?(@output.beam)
    end

    def build_application(application, jobs:)
      @runner.run(['gmake', "-j#{jobs}", '-C', "lib/#{application}", 'opt', "TARGET=#{TARGET}"],
                  name: "runtime-#{application}", deadline: DEADLINES.fetch(:libs), chdir: @output.root,
                  env: build_environment)
    end

    def build_environment
      Oracle::CLEAN_ERLANG_ENV.merge(
        'ERL_TOP' => @output.root,
        # No host path in a beam, so another checkout builds the same bytes.
        'ERL_COMPILE_FLAGS' => '+deterministic',
        'PATH' => [File.dirname(@oracle.erl_path(HOST_OTP_FLAVOUR)), ENV.fetch('PATH')].join(File::PATH_SEPARATOR),
        'ERX_HOSTED_LIBERX' => @output.liberx,
        'ERX_SDKROOT' => sdk_root,
        'ERX_SOURCE_ROOT' => @root,
        'ERX_TREE' => @root
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
