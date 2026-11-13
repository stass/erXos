# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi'
require_relative 'boot_image'
require_relative 'erlang_apps'
require_relative 'error'
require_relative 'fiasco'
require_relative 'native_jit_runtime'
require_relative 'native_root'
require_relative 'native_runtime'
require_relative 'oracle'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'release_files'
require_relative 'runner'

module Erx
  # The domain library's apply phase on native Fiasco: the root
  # test/guest/native_domain/guest.c links liberx/system and creates domains whose
  # tasks run program.c beside it, and takes their ends at its fault gate; one domain
  # runs the domain runtime image (NativeRoot::DOMAIN_RUNTIME) on a domain release of
  # ReleaseFiles::DOMAIN_BASE to init, and BeamAsm domains run the BeamAsm image
  # (NativeRoot#build_jit_runtime_receipted) on the same release with the JIT test
  # modules beside it (JIT_MODULES). Each case says one line, and the transcript must show each
  # passed, in order.
  module NativeDomain
    MEMORY_MIB = 512
    PROGRAM_PATH = 'boot/native-domain'
    # The domains' release: one file, which program.c reads through its slice.
    RELEASE_PATH = 'domains/native/release'
    RELEASE_SOURCE = 'test/guest/native_domain/release.txt'
    # ERTS's image and the domain release, with its one boot script bin/erts.boot, at the
    # paths guest.c finds them by. Both runtimes are image entries, as a domain runtime is
    # in a system image, so their read-only segments are shared by every domain that runs
    # them.
    ERTS_PATH = 'runtimes/emu'
    ERTS_RELEASE = ReleaseFiles.domain([ReleaseFiles.domain_boot('erts', applications: ReleaseFiles::DOMAIN_BASE)])
    JIT_PATH = 'runtimes/jit'
    # The modules a BeamAsm domain loads from /test/ (jit_reload.erl): the driver,
    # and jit_probe compiled once for each of the three versions it reloads.
    JIT_DRIVER = 'test/guest/native_domain/jit_reload.erl'
    JIT_PROBE = 'test/guest/native_domain/jit_probe.erl'
    JIT_TEST_PREFIX = "#{ERTS_RELEASE.prefix}test/"
    ERLC_DEADLINE = 120
    SYSTEM = %w[liberx/system/dom_core.c liberx/system/dom_life.c liberx/system/dom_apply.c liberx/system/dom_boot.c liberx/system/dom_boot_view.c liberx/system/dom_install.c
                liberx/system/dom_dump.c
                liberx/backend/core/boot_info.c liberx/backend/core/boot_manifest.c liberx/erx_lane.c liberx/erx_etf.c].freeze
    ROOT_SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, *NativeRoot::LAUNCH,
                    'liberx/backend/core/refused.c', *SYSTEM, 'test/guest/native_domain/string.c',
                    'test/guest/native_domain/guest.c'].freeze
    ROOT_FLAGS = %w[-DERX_DOM_TEST_HOOKS].freeze
    PROGRAM_SOURCES = [*NativeRoot::TASK, 'test/guest/native_domain/program.c'].freeze
    CASES = %w[library warm halt fault stop lanes erts logger erts_refused crash jit_reload jit_write_rx jit_run_rw connection
                 exports refs origins link_warm link link_area link_undo link_end undo
                 given_undo given given_kept].freeze
    RECORD = NativeRoot::DOMAIN_RECORD
    # What a case's domain prints before its case line, each a record of its space and in
    # order: init ran the ERTS domain's release; the logger case's two log records, which
    # the logger proxy wrote into the kernel log, each whole with its tab, escape and
    # newline shown as the log's tokens, the first formatted on one line by erx_log_h and
    # the second of the domain's own making; the connection's system connection ended
    # with the party's flood unread; the exports case's filler filled the export table; the
    # refs case's system connection ended on the party's malformed reference, after its steps;
    # and the spoiled page's runtime ended with the reader's reason.
    CONSOLE = { 'erts' => /\A#{RECORD}init_started/n,
                'logger' => [/\A#{RECORD}error: tab\\x09here esc\\x1B\[31mred nl, end\r?\n/n,
                             /\A#{RECORD}warning: raw\\x09t\\x1B\[0m\\x0Ax\r?\n/n,
                             /\A#{RECORD}logger_done/n],
                'connection' => /\A#{RECORD}\{erx_dist,system_connection,erx_lane_answers_unread\}/n,
                'exports' => /\A#{RECORD}\{exports_filled,1\d{4}\}/n,
                'refs' => /\A#{RECORD}\{erx_dist,system_connection,erx_lane_malformed\}/n,
                'erts_refused' => /\A#{RECORD}erx: the boot information page: the page is of another version/n,
                'jit_reload' => /\A#{RECORD}\{jit_reload_passed,jit,[1-9]\d*\}/n,
                'jit_write_rx' => /\A#{RECORD}jit_alias_runs/n, 'jit_run_rw' => /\A#{RECORD}jit_alias_runs/n }.freeze
    CASE_LINE = /\Aerx: domain: (?<name>[a-z_]+) (?<result>ok|FAILED)/n

    module_function

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       *CASES.flat_map { |name| [*console_point(name), case_point(name, seconds: name == 'library' ? 180 : 60)] },
       { name: 'domain-done', pattern: /\Aerx: domain: done/n, seconds: 30 }.freeze].freeze
    end

    def case_point(name, seconds:)
      { name: "domain-#{name}", pattern: /\Aerx: domain: #{name} /n, seconds: seconds,
        verify: ->(text) { raise Error, "the domain case reports #{text.inspect}" unless case_passed?(text, name) } }.freeze
    end

    def console_point(name)
      Array(CONSOLE[name]).each_with_index.map do |pattern, index|
        { name: "domain-#{name}-console#{index.zero? ? '' : "-#{index}"}", pattern: pattern, seconds: 120 }.freeze
      end
    end

    def case_passed?(text, name)
      match = CASE_LINE.match(text)
      !match.nil? && match[:name] == name && match[:result] == 'ok'
    end

    # Builds the image and boots it at each accelerator and CPU count.
    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), platform: Platform.development(root))
        @root = File.expand_path(root)
        @platform = platform
        @runner = runner
        @compiler = compiler
        @linker = linker
        @build = File.join(@root, 'build/native-domain')
      end

      def call(accels:, cpus: [1, 4], jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco)
        placement.each(accels: accels, cpus: cpus) do |accel, count, remote|
          report = Qemu.new(root: @root, runner: @runner).run(platform: @platform, accel: accel, cpus: count, remote: remote, image: built.single, memory_mib: MEMORY_MIB,
                                                              checkpoints: NativeDomain.checkpoints, machine_end: true)
          ["#{accel}-#{count}cpu", { serial: File.expand_path(report.fetch('serial_log'), @root),
                                     seconds: report.fetch('elapsed_seconds') }.freeze]
        end
      end

      private

      def image(fiasco)
        native = NativeRoot.new(root: @root, source: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @platform,
                                fiasco: fiasco)
        program = native.build_task(name: 'native-domain', sources: PROGRAM_SOURCES, directory: File.join(@build, 'program'), flags: [])
        erts = NativeRuntime.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @platform, fiasco: fiasco).build
        runtime = native.build_domain_runtime_receipted(directory: File.join(@build, 'erts'),
                                                        archives: [*erts.otp_archives, erts.libc, fiasco.user_library('libgcc.a')])
        root_task = native.build(name: 'domain-root', sources: ROOT_SOURCES, directory: File.join(@build, 'root'), flags: ROOT_FLAGS)
        programs = { PROGRAM_PATH => program, RELEASE_PATH => File.join(@root, RELEASE_SOURCE),
                     **release(erts), **jit_modules }
        images = { ERTS_PATH => runtime.fetch(:program), JIT_PATH => jit_runtime(native, fiasco, erts) }
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(@build, 'image'), stand_in_root: root_task, programs: programs, images: images,
                        jit: [JIT_PATH])
      end

      # The BeamAsm image, over the interpreter build's musl and release.
      def jit_runtime(native, fiasco, erts)
        jit = NativeJitRuntime.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @platform, fiasco: fiasco)
                              .build(interpreter: erts)
        native.build_jit_runtime_receipted(directory: File.join(@build, 'erts-jit'),
                                           archives: jit.link_archives(libgcc: fiasco.user_library('libgcc.a')))
              .fetch(:program)
      end

      # The JIT test modules, compiled by the stock oracle's erlc, at their paths under the release.
      def jit_modules
        directory = File.join(@build, 'jit-modules')
        FileUtils.mkdir_p(directory)
        { 'jit_reload' => erlc(JIT_DRIVER, directory, []),
          'jit_probe_1' => erlc(JIT_PROBE, File.join(directory, '1'), ['-DVERSION=1']),
          'jit_probe_2' => erlc(JIT_PROBE, File.join(directory, '2'), ['-DVERSION=2']),
          'jit_probe_3' => erlc(JIT_PROBE, File.join(directory, '3'), ['-DVERSION=3']) }
          .to_h { |name, beam| ["#{JIT_TEST_PREFIX}#{name}.beam", beam] }
      end

      def erlc(source, directory, defines)
        FileUtils.mkdir_p(directory)
        erlc = File.join(File.dirname(Oracle.new(root: @root, runner: @runner).erl_path(Runtime::HOST_OTP_FLAVOUR)), 'erlc')
        @runner.run([erlc, *ErlangApps::FLAGS, *defines, '-o', directory, File.join(@root, source)],
                    name: 'erlc-native-domain', deadline: ERLC_DEADLINE, chdir: @root, env: Oracle::CLEAN_ERLANG_ENV)
        File.join(directory, "#{File.basename(source, '.erl')}.beam")
      end

      def release(erts)
        codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
        ReleaseFiles.new(root: @root, otp: erts.otp, directory: File.join(@build, 'release'), runner: @runner, codec: codec,
                         release: ERTS_RELEASE).entries.to_h { |entry| [entry.fetch('path'), entry.fetch('artifact')] }
      end
    end
  end
end
