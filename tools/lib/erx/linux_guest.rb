# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'tmpdir'
require_relative 'bench_measurement'
require_relative 'bench_system'
require_relative 'compiler_rt'
require_relative 'error'
require_relative 'native_bench'
require_relative 'newc_archive'
require_relative 'output_directory'
require_relative 'peer_bench'
require_relative 'platform'
require_relative 'posix_bench'
require_relative 'qemu'
require_relative 'side_lock'

module Erx
  # Linux's guest in the comparison under HVF (docs/design-bench.md, "Linux's guest"):
  # Alpine's stock virt kernel, unmodified, with an initramfs whose /init
  # (bench/linux/init.c) runs erx_peer_bench, both built static on the host by erXos's
  # clang and ld.lld against Alpine's musl-dev. Its pins are Linux's own lock (SideLock),
  # bench/linux/deps.lock, fetched on demand (`tools/erx fetch --linux`) into
  # build/linux-sources. Nothing of Alpine runs on the host: musl-dev's headers, start
  # files and libc.a, the members its pin names, are inputs to the compiler and linker, and
  # the kernel runs only in QEMU, whose guest has no network device and no disk.
  module LinuxGuest
    LABEL = 'linux'
    LOCK = 'bench/linux/deps.lock'
    WORKSPACE = 'build/linux-sources'
    OUTPUT = 'build/linux-guest'
    KERNEL = 'alpine-vmlinuz-virt'
    MUSL_DEV = 'alpine-musl-dev'
    TARGET = 'aarch64-linux-musl'
    # The kernel's own defaults, plus its console and an immediate end on a panic.
    COMMAND_LINE = 'console=ttyAMA0 panic=-1'
    PEER = PeerBench::SOURCE
    INIT = 'bench/linux/init.c'
    # The code-generation flags, erXos's programs' own without their target, so the program
    # Linux runs is generated as erXos's is (docs/design-bench.md, "Fairness").
    CODE_FLAGS = NativeRoot::CODE_FLAGS.grep_v(/\A--target=/).freeze
    # The boots the guest runs the program for: the native set's counterparts, and posix.
    BOOTS = %w[native posix].freeze

    module_function

    # The guest's deadline under accel: /init kills the program this long after starting
    # it, later than the program's own deadline under accel, so the kill is only the
    # backstop for a program its alarm did not end. QEMU's deadline for the program's end
    # is NativeBench::DEADLINE_MARGIN_SECONDS more, so /init powers the machine off first.
    def deadline_seconds(accel) = PeerBench.run_deadline(accel) + 10

    # The lock's sources over their own workspace.
    def lock(root:, runner:)
      SideLock.dependencies(root: root, runner: runner, lock: LOCK, workspace: WORKSPACE, label: LABEL)
    end

    # Fetches every source the lock pins, from cache (another checkout's
    # build/linux-sources/build/downloads) when given. Answers what was done.
    def fetch(root:, runner:, cache: nil)
      SideLock.fetch(lock(root: root, runner: runner), root: root, label: LABEL, cache: cache)
    end

    # The initramfs: /init, the program it runs, and the directories and console the
    # kernel and both need; /tmp holds a posix run's files.
    def initramfs(init:, peer:)
      NewcArchive.write([NewcArchive::Entry.directory('dev'), NewcArchive::Entry.directory('dev/shm'),
                         NewcArchive::Entry.character('dev/console', major: 5, minor: 1),
                         NewcArchive::Entry.directory('proc'), NewcArchive::Entry.directory('tmp'),
                         NewcArchive::Entry.file('init', init, mode: 0o755),
                         NewcArchive::Entry.file('erx_peer_bench', peer, mode: 0o755)])
    end

    # Builds the guest's initramfs in a directory of its own under build/linux-guest, so
    # no other build replaces what a session boots. Answers the kernel's path, the
    # initramfs and the subject facts a record keeps. seeded are a seeded fault's flags
    # (NativeBench::Seed#root_flags), which the program takes as the native bench root does.
    # accel is the accelerator the guest boots under, 'native' on a board, whose run deadline
    # the program and /init are built with; board builds /init for the Raspberry Pi 4
    # (bench/linux/init.c, ERX_INIT_BOARD).
    def build(root:, runner:, accel:, seeded: [], board: false)
      dependencies = lock(root: root, runner: runner)
      parent = OutputDirectory.prepare(root: root, path: File.join(root, OUTPUT))
      output = Dir.mktmpdir("build-#{Process.pid}-", parent)
      usr = dependencies.fetched_tree(MUSL_DEV)
      peer_flags = [*PeerBench.flags(accel: accel), *seeded]
      peer = compile(root: root, usr: usr, output: output, runner: runner, source: PEER, flags: peer_flags)
      init = compile(root: root, usr: usr, output: output, runner: runner, source: INIT,
                     flags: ["-DERX_INIT_DEADLINE_S=#{deadline_seconds(accel)}u", *(board ? ['-DERX_INIT_BOARD'] : [])])
      initrd = File.join(output, 'initramfs.cpio')
      File.binwrite(initrd, initramfs(init: File.binread(init), peer: File.binread(peer)))
      kernel = dependencies.fetched_file(KERNEL)
      { kernel: kernel, initrd: initrd,
        subject: { 'kernel' => pin_of(dependencies, KERNEL), 'c_library' => pin_of(dependencies, MUSL_DEV),
                   'command_line' => COMMAND_LINE, 'initramfs_sha256' => Digest::SHA256.file(initrd).hexdigest,
                   'peer_sha256' => Digest::SHA256.file(peer).hexdigest,
                   'init_sha256' => Digest::SHA256.file(init).hexdigest,
                   'compiler' => PeerBench.compiler_version(runner, compiler),
                   'peer_flags' => c_flags('MUSL_DEV', peer_flags).join(' ') } }
    end

    # What QEMU boots a run of benchmark on cpus CPUs of platform with: the program's
    # arguments after the kernel's, which /init hands on, and the memory of the erXos
    # machine the run is set beside: a posix run's erXos's posix image's
    # (PosixBench.machine), whose /tmp a posix run's files fill as they fill Linux's, and
    # any other run the native bench guest's.
    def machine(benchmark, cpus:, platform:)
      posix = PeerBench::BOOTS.fetch(benchmark) == 'posix'
      { command_line: [COMMAND_LINE, '--', *PeerBench.arguments(benchmark, cpus: cpus)].join(' '),
        memory_mib: posix ? PosixBench.machine(platform).memory_mib : NativeBench::MEMORY_MIB }
    end

    # One boot of the guest for benchmark at cpus CPUs of platform, its serial log in
    # directory.
    def boot(root:, runner:, built:, benchmark:, cpus:, platform:, accel: 'hvf', directory:)
      checkpoints = [{ name: 'bench-timing', pattern: /\Aerx: bench: timing/n, seconds: 60 },
                     { name: 'bench-done', pattern: /\Aerx: bench: done/n,
                       seconds: deadline_seconds(accel) + NativeBench::DEADLINE_MARGIN_SECONDS }]
      machine = machine(benchmark, cpus: cpus, platform: platform)
      Qemu.new(root: root, runner: runner).run(
        platform: platform, accel: accel, cpus: cpus, memory_mib: machine.fetch(:memory_mib),
        image: built.fetch(:kernel), initrd: built.fetch(:initrd), hostlink: QemuPlan::NO_HOSTLINK,
        command_line: machine.fetch(:command_line), checkpoints: checkpoints, machine_end: true, directory: directory
      )
    end

    def pin_of(dependencies, id)
      dependencies.sources.find { |source| source.fetch('id') == id }.slice('id', 'version', 'sha256')
    end

    # The compiler's flags for a program of the guest; usr is musl-dev's usr tree.
    def c_flags(usr, flags)
      ["--target=#{TARGET}", *CODE_FLAGS, '-pthread', '-nostdinc',
       '-isystem', File.join(usr, 'include'), *flags]
    end

    # source, a C file of the tree, compiled by ERX_CLANG with flags and linked static by
    # ERX_LLD against the start files and libc.a of musl-dev's usr tree and erXos's
    # compiler-rt builtins archive, whose binary128 helpers musl's long double printf
    # reaches. Answers the program's path in output, named as source is.
    def compile(root:, usr:, output:, runner:, source:, flags:)
      clang = compiler
      lld = ENV.fetch('ERX_LLD') { raise Error, 'linux guest: set ERX_LLD to ld.lld' }
      resource = File.join(File.binread(runner.run([clang, '-print-resource-dir'], name: 'linux-guest-resource-dir',
                                                                                   deadline: 30).fetch('log')).strip, 'include')
      name = File.basename(source, '.c')
      object = File.join(output, "#{name}.o")
      program = File.join(output, name)
      runner.run([clang, *c_flags(usr, flags), '-isystem', resource, '-I', root, '-c', File.join(root, source),
                  '-o', object], name: "linux-guest-cc-#{name}", deadline: 300)
      lib = File.join(usr, 'lib')
      runner.run([lld, '-static', '-o', program, *%w[crt1.o crti.o].map { |crt| File.join(lib, crt) }, object,
                  File.join(lib, 'libc.a'), CompilerRt.archive(root: root, runner: runner, compiler: clang),
                  File.join(lib, 'crtn.o')], name: "linux-guest-ld-#{name}", deadline: 120)
      program
    end

    def compiler = ENV.fetch('ERX_CLANG') { raise Error, 'linux guest: set ERX_CLANG to the LLVM clang' }

    private_class_method :c_flags, :compiler

    # Linux's guest for one boot (BenchSystem), native or posix: one boot of the kernel and its
    # initramfs, whose erx_peer_bench prints a BENCH line for every cell of the boot, a
    # counterpart's timing or unsupported with its reason, and one CLOCK line, judged by
    # BenchMeasurement.boot as erXos's are (PeerBench.asked). It boots in one CPU and in
    # the landing boot's count, and is built with the landing profiles only, as erXos's
    # guest it is set beside; it is built once per session, at its first boot. Since the
    # program reports every cell of the boot, the cells a session asks only decide that it
    # boots, and the record keeps each line the guest printed.
    class Guest
      def initialize(root:, runner:, boot: 'native', platform: Platform.development(root))
        raise Error, "linux guest: no #{boot} boot" unless BOOTS.include?(boot)

        @root = File.expand_path(root)
        @runner = runner
        @boot = boot
        @platform = platform
      end

      attr_reader :boot

      def system = 'linux'
      def accelerators = %w[hvf]
      def forms(cpus) = [1, cpus].uniq

      def refusal(profile)
        return "linux's guest is built with the landing profiles only" unless profile == 'landing'

        dependencies = LinuxGuest.lock(root: @root, runner: @runner)
        missing = dependencies.sources.map { |source| source.fetch('id') }.reject { |id| dependencies.fetched?(id) }
        "linux's guest needs #{missing.join(', ')}: run `#{SideLock.fetch_command(LABEL)}`" unless missing.empty?
      end

      def call(benchmark, cells:, cpus:, accel:)
        # Each build is a directory of its own, so a boot under any accelerator runs the
        # guest built for it.
        built = (@built ||= {})[accel] ||= LinuxGuest.build(root: @root, runner: @runner, accel: accel)
        directory = File.join(@root, 'build/qemu', "linux-bench-#{accel}-#{cpus}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
        report = LinuxGuest.boot(root: @root, runner: @runner, built: built, benchmark: benchmark.name, cpus: cpus,
                                 platform: @platform, accel: accel, directory: directory)
        # The kernel QEMU booted is the pinned one, as the record says.
        unless report.fetch('image_sha256') == built.fetch(:subject).fetch('kernel').fetch('sha256')
          raise Error, "#{built.fetch(:kernel)} is not the kernel Linux's lock pins: run `#{SideLock.fetch_command(LABEL)}`"
        end
        serial = report.fetch('serial_log')
        lines = NativeBench.guest_lines(File.binread(serial))
        answer = BenchMeasurement.boot(lines, PeerBench.asked(benchmark.name, cpus: cpus, clock: 'counter'))
        BenchSystem::Booted.new(
          clock: answer.fetch(:clock) || {}, cells: answer.fetch(:cells), refused: answer.fetch(:refused),
          environment: { 'memory_mib' => LinuxGuest.machine(benchmark.name, cpus: cpus, platform: @platform)
                                                    .fetch(:memory_mib),
                         'machine' => 'virt',
                         'qemu' => report['qemu_version'] }.compact,
          subject: built.fetch(:subject), logs: [{ serial: BenchRecord.boot_log(serial) }], reused_from: report['reused_from'],
          pinned: PeerBench.pins?(benchmark.name)
        )
      end
    end
  end
end
