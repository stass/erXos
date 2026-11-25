# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'bench_measurement'
require_relative 'bench_system'
require_relative 'compiler_rt'
require_relative 'error'
require_relative 'native_bench'
require_relative 'newc_archive'
require_relative 'output_directory'
require_relative 'peer_bench'
require_relative 'platform'
require_relative 'qemu'
require_relative 'side_lock'

module Erx
  # Linux's guest in the comparison under HVF (docs/design-bench.md, "Linux's guest"):
  # Alpine's stock virt kernel, unmodified, with an initramfs whose /init is
  # erx_peer_bench, built static on the host by erXos's clang and ld.lld against
  # Alpine's musl-dev. Its pins are Linux's own lock (SideLock), bench/linux/deps.lock,
  # fetched on demand (`tools/erx fetch --linux`) into build/linux-sources. Nothing of
  # Alpine runs on the host: musl-dev's headers, start files and libc.a, the members its
  # pin names, are inputs to the compiler and linker, and the kernel runs only in QEMU,
  # whose guest has no network device and no disk.
  module LinuxGuest
    LOCK = 'bench/linux/deps.lock'
    WORKSPACE = 'build/linux-sources'
    OUTPUT = 'build/linux-guest'
    KERNEL = 'alpine-vmlinuz-virt'
    MUSL_DEV = 'alpine-musl-dev'
    TARGET = 'aarch64-linux-musl'
    # The kernel's own defaults, plus its console and an immediate end on a panic.
    COMMAND_LINE = 'console=ttyAMA0 panic=-1'

    module_function

    # The lock's sources over their own workspace.
    def lock(root:, runner:)
      SideLock.dependencies(root: root, runner: runner, lock: LOCK, workspace: WORKSPACE)
    end

    # Fetches every source the lock pins, from cache (another checkout's
    # build/linux-sources/build/downloads) when given. Answers what was done.
    def fetch(root:, runner:, cache: nil)
      SideLock.fetch(lock(root: root, runner: runner), root: root, label: 'linux', cache: cache)
    end

    # The initramfs: /init, and the directories and console the kernel and /init need.
    def initramfs(init)
      NewcArchive.write([NewcArchive::Entry.directory('dev'), NewcArchive::Entry.directory('dev/shm'),
                         NewcArchive::Entry.character('dev/console', major: 5, minor: 1),
                         NewcArchive::Entry.directory('proc'), NewcArchive::Entry.file('init', init, mode: 0o755)])
    end

    # Builds the guest's kernel path, initramfs and their facts under build/linux-guest.
    # Answers the files and the subject facts a record keeps.
    def build(root:, runner:)
      dependencies = lock(root: root, runner: runner)
      output = OutputDirectory.prepare(root: root, path: File.join(root, OUTPUT))
      peer = compile_peer(root: root, usr: dependencies.fetched_tree(MUSL_DEV), output: output, runner: runner)
      initrd = File.join(output, 'initramfs.cpio')
      File.binwrite(initrd, initramfs(File.binread(peer)))
      kernel = dependencies.fetched_file(KERNEL)
      { kernel: kernel, initrd: initrd,
        subject: { 'kernel' => pin_of(dependencies, KERNEL), 'c_library' => pin_of(dependencies, MUSL_DEV),
                   'command_line' => COMMAND_LINE, 'initramfs_sha256' => Digest::SHA256.file(initrd).hexdigest,
                   'peer_sha256' => Digest::SHA256.file(peer).hexdigest, 'compiler' => compiler_version(runner),
                   'flags' => peer_flags('MUSL_DEV').join(' ') } }
    end

    # One boot of the guest for benchmark at cpus CPUs, its serial log in directory.
    def boot(root:, runner:, built:, benchmark:, cpus:, accel: 'hvf', directory:, deadline_seconds: 300)
      checkpoints = [{ name: 'bench-timing', pattern: /\Aerx: bench: timing/n, seconds: 60 },
                     { name: 'bench-done', pattern: /\Aerx: bench: done/n, seconds: deadline_seconds }]
      Qemu.new(root: root, runner: runner).run(
        platform: Platform.development(root), accel: accel, cpus: cpus, memory_mib: NativeBench::MEMORY_MIB,
        image: built.fetch(:kernel), initrd: built.fetch(:initrd), hostlink: QemuPlan::NO_HOSTLINK,
        command_line: "#{COMMAND_LINE} -- #{benchmark}", checkpoints: checkpoints, machine_end: true, directory: directory
      )
    end

    def pin_of(dependencies, id)
      dependencies.sources.find { |source| source.fetch('id') == id }.slice('id', 'version', 'sha256')
    end

    # The compiler's flags; usr is musl-dev's usr tree.
    def peer_flags(usr)
      ["--target=#{TARGET}", '-std=c17', '-O2', '-pthread', '-mno-outline-atomics', '-nostdinc',
       '-isystem', File.join(usr, 'include'), *PeerBench.flags]
    end

    # erx_peer_bench compiled by ERX_CLANG and linked static by ERX_LLD against the
    # start files and libc.a of musl-dev's usr tree, and erXos's compiler-rt builtins archive, whose
    # binary128 helpers musl's long double printf reaches.
    def compile_peer(root:, usr:, output:, runner:)
      clang = compiler
      lld = ENV.fetch('ERX_LLD') { raise Error, 'linux guest: set ERX_LLD to ld.lld' }
      resource = File.join(File.binread(runner.run([clang, '-print-resource-dir'], name: 'linux-guest-resource-dir',
                                                                                   deadline: 30).fetch('log')).strip, 'include')
      object = File.join(output, 'erx_peer_bench.o')
      peer = File.join(output, 'erx_peer_bench')
      runner.run([clang, *peer_flags(usr), '-isystem', resource, '-I', root, '-c',
                  File.join(root, 'bench/peer/erx_peer_bench.c'), '-o', object], name: 'linux-guest-cc', deadline: 300)
      lib = File.join(usr, 'lib')
      runner.run([lld, '-static', '-o', peer, *%w[crt1.o crti.o].map { |name| File.join(lib, name) }, object,
                  File.join(lib, 'libc.a'), CompilerRt.archive(root: root, runner: runner, compiler: clang),
                  File.join(lib, 'crtn.o')], name: 'linux-guest-ld', deadline: 120)
      peer
    end

    def compiler = ENV.fetch('ERX_CLANG') { raise Error, 'linux guest: set ERX_CLANG to the LLVM clang' }

    # The first line of the compiler's own report of its version.
    def compiler_version(runner)
      log = runner.run([compiler, '--version'], name: 'linux-guest-cc-version', deadline: 30).fetch('log')
      File.binread(log, 4096).lines.first.to_s.strip
    end
    private_class_method :pin_of, :peer_flags, :compile_peer, :compiler, :compiler_version

    # Linux's guest for the native boot (BenchSystem): one boot of the kernel and its
    # initramfs, whose erx_peer_bench prints a BENCH line for every cell of the boot, a
    # counterpart's timing or unsupported with its reason, and one CLOCK line, judged by
    # BenchMeasurement.boot as erXos's are (PeerBench.asked). It boots in one CPU and in
    # the landing boot's count, and is built with the landing profiles only, as erXos's
    # guest it is set beside; it is built once per session, at its first boot. Since the
    # program reports every cell of the boot, the cells a session asks only decide that it
    # boots, and the record keeps each line the guest printed.
    class Guest
      def initialize(root:, runner:)
        @root = File.expand_path(root)
        @runner = runner
      end

      def system = 'linux'
      def boot = 'native'
      def forms(cpus) = [1, cpus].uniq

      def refusal(profile)
        return "linux's guest is built with the landing profiles only" unless profile == 'landing'

        dependencies = LinuxGuest.lock(root: @root, runner: @runner)
        missing = dependencies.sources.map { |source| source.fetch('id') }.reject { |id| dependencies.fetched?(id) }
        "linux's guest needs #{missing.join(', ')}: run `tools/erx fetch --linux`" unless missing.empty?
      end

      def call(benchmark, cells:, cpus:, accel:)
        @built ||= LinuxGuest.build(root: @root, runner: @runner)
        directory = File.join(@root, 'build/qemu', "linux-bench-#{accel}-#{cpus}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
        report = LinuxGuest.boot(root: @root, runner: @runner, built: @built, benchmark: benchmark.name, cpus: cpus,
                                 accel: accel, directory: directory)
        serial = report.fetch('serial_log')
        lines = NativeBench.guest_lines(File.binread(serial))
        answer = BenchMeasurement.boot(lines, PeerBench.asked(benchmark.name, cpus: cpus, clock: 'counter'))
        BenchSystem::Booted.new(
          clock: answer.fetch(:clock) || {}, cells: answer.fetch(:cells), refused: answer.fetch(:refused),
          environment: { 'memory_mib' => NativeBench::MEMORY_MIB, 'machine' => 'virt',
                         'qemu' => report['qemu_version'] }.compact,
          subject: @built.fetch(:subject), logs: [{ serial: serial }], reused_from: report['reused_from']
        )
      end
    end
  end
end
