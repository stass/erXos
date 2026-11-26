# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'build_kind'
require_relative 'compiler_rt'
require_relative 'fiasco'
require_relative 'generated'
require_relative 'medium_boot'
require_relative 'native_root'
require_relative 'native_runtime'
require_relative 'platform'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'runner'
require_relative 'session_domain'

module Erx
  # The kernel's lines reach the log, not the UART, once the console's driver has the
  # UART (docs/design-fiasco.md, Verification, "Kernel lines"). The case boots the
  # production medium on a release test kernel built with ERX_TEST_KERNEL_WARN, its
  # test medium adding the program console_warn, and runs that program twice from root's
  # session shell. Its first marked receive makes the kernel print one warning, which
  # the root's take must log as a kernel record of level warning, its text escaped, and
  # which must show nowhere else, while a line typed in the meantime runs whole. Its
  # second prints more than three rings of warnings and traps in kernel mode, and the stop's
  # close must write the loss line, then the trap dump and the panic raw, before the
  # release kernel ends the machine. The session's shell, not the system domain's console
  # shell before it, because only a session runs a command server, so the system's shell
  # finds no program (erx_shell_program:find/1). No other image boots
  # that kernel or carries that program, which is why make check-native-seeds runs this
  # rather than the QEMU gate.
  module NativeConsoleRing
    # The marked receive's label (docs/design-fiasco.md, "Test kernels' seeds"), held
    # here alone and handed to the test kernel's build and the program's. Not 0, which
    # an ordinary yield carries; the kernel's seed refuses 0 at build time.
    LABEL = 0x4552
    DEFINE = "-DERX_TEST_KERNEL_WARN=#{LABEL}".freeze
    PROGRAM = 'console_warn'
    SOURCE = 'liberx/backend/fiasco/console_warn.c'
    # The seed's first warning, as Fiasco's WARN prints it and the log escapes it.
    WARNING = 'erx: console ring warning'
    RECORD = /\A#[0-9]+ [0-9]+\.[0-9]{6} warning fiasco: \\x1B\[31mKERNEL\\x1B\[m: Warning: #{WARNING}\r?\n\z/n
    # The line typed right behind the program, while its warning is printed, and the
    # one typed once the record is in, which the shell runs after it; the settled point
    # then types the program again, whose second receive overflows the ring and traps.
    WHOLE = 'ring-whole-line'
    SETTLED = 'ring-settled'
    # The close's own loss line, raw: anchored, so a record of the take's loss does not
    # stand in for it.
    LOST = /\Afiasco: [1-9][0-9]* kernel lines lost\r?\n\z/n
    # The machine stop's message for the trap, raw, which it prints only after its
    # close lets the ring out (docs/design-debugger.md, "Causes").
    STOP = /\Aerx: kernel stop: kernel trap: exception class 0x/n
    # How long the root's take may take to log the warning, and the stop to come.
    RECORD_SECONDS = 60
    STOP_SECONDS = 60

    module_function

    # The points from root's session shell on, over the serial log at serial.
    def points(serial:)
      [SessionDomain.session_shell('root_1-shell', "#{PROGRAM}\recho #{WHOLE}\r"),
       { name: 'console-ring-record', pattern: RECORD, type: "echo #{SETTLED}\r", seconds: RECORD_SECONDS }.freeze,
       { name: 'console-ring-settled', pattern: SessionDomain.line(SETTLED), type: "#{PROGRAM}\r", seconds: RECORD_SECONDS,
         verify: ->(_line) { check_settled(File.binread(serial)) } }.freeze,
       { name: 'console-ring-lost', pattern: LOST, seconds: STOP_SECONDS }.freeze,
       { name: 'console-ring-stop', pattern: STOP, seconds: STOP_SECONDS }.freeze].freeze
    end

    # Refuses a transcript, up to the shell's run of the line typed after the record,
    # in which the warning's text shows anywhere but its one record, or the line typed
    # behind the program did not run whole.
    def check_settled(text)
      shown = text.scan(WARNING).size
      raise Error, "the warning's text shows #{shown} times, not once in its record" unless shown == 1
      raise Error, "the line typed while the warning was printed did not run whole" unless
        text.match?(/^#{WHOLE}\r*\n/n)
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64',
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @machine = ProductionImage::Machine.development(platform)
        @manifest = platform.manifest_source(@root)
        @build = File.join(@root, 'build/native-console-ring')
      end

      # Builds the release test kernel and the medium, boots it at one CPU under HVF and
      # returns the serial log's path. The real kernel's build must have run, or does
      # when build is true. A run whose transcript is short of the panic, or whose
      # machine does not end after it, raises.
      def call(jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        kernel = fiasco.build_test_kernel(name: 'console-ring', defines: [DEFINE], kind: BuildKind::RELEASE, jobs: jobs)
        booted = Fiasco.new(root: @root, runner: @runner, compiler: @compiler, kernel: kernel)
        work = ProductionImage.clear_directory(root: @root, path: @build)
        directory = OutputDirectory.prepare(root: @root, mode: 0o700, path: File.join(work, 'hvf-1cpu'))
        kind = ProductionImage::MediumKind.test(test_programs: program(booted))
        built, written = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker,
                                             machine: @machine, fiasco: booted)
                                        .build_medium(directory: File.join(directory, 'image'), manifest_source: @manifest,
                                                      kind: kind)
        boot(built, written, directory)
      end

      private

      # PROGRAM over musl's libc.a, with DEFINE, as a test program of the medium, as the
      # kiosk suite's front cell adds its own (Kiosk::Run#front_program).
      def program(fiasco)
        Generated.ensure(root: @root)
        libc = NativeRuntime.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco,
                                 platform: @machine.platform).build.libc
        native = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @machine.platform,
                                fiasco: fiasco)
        built = native.build_task_receipted(name: PROGRAM, sources: [*NativeRoot::PROGRAM, SOURCE], flags: [DEFINE],
                                            directory: File.join(@build, PROGRAM),
                                            archives: [libc, CompilerRt.archive(root: @root, runner: @runner, compiler: @compiler)])
        codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
        ProductionImage::Added.new(entries: [ProductionImage.program_entry(PROGRAM, built, codec: codec)].freeze,
                                   inputs: built.fetch(:inputs), imports: {}.freeze)
      end

      def boot(built, written, directory)
        medium = written.fresh(directory: directory)
        choice = BootRecord.read(medium)
        image = BootRecord.extract(medium, choice, output: File.join(directory, 'slot.boot'))
        disks = [QemuPlan::Disk.new(path: medium)]
        tree = MediumBoot.firmware_tree(runner: @runner, qemu: @qemu, machine: @machine, image: image, disks: disks,
                                        choice: choice, cpus: 1, directory: directory)
        boot_directory = File.join(directory, 'boot')
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: 'hvf', cpus: 1, image: image, memory_mib: @machine.memory_mib,
                 directory: boot_directory, dtb: tree, disks: disks, machine_end: true,
                 checkpoints: checkpoints(built, choice, serial: File.join(boot_directory, 'serial.log')))
            .fetch('serial_log')
      end

      # The production checkpoints of the test image, with the boot value's after the
      # image's identity, as the kiosk suite's (Kiosk::Run#checkpoints), and this case's
      # points from root's session shell on.
      def checkpoints(built, choice, serial:)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: 1,
                                                  manifest_source: @manifest, memory_mib: @machine.memory_mib,
                                                  test_image: built.test_code)
        at = points.index { |point| point.fetch(:name) == 'image-identity' }
        raise Error, 'the production checkpoints name no image-identity' unless at
        raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

        [*points[0..at], MediumBoot.boot_value_checkpoint(choice), *points[(at + 1)..],
         *NativeConsoleRing.points(serial: serial)]
      end
    end
  end
end
