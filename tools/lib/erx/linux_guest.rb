# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require_relative 'compiler_rt'
require_relative 'dependencies'
require_relative 'error'
require_relative 'native_bench'
require_relative 'newc_archive'
require_relative 'output_directory'
require_relative 'peer_bench'
require_relative 'platform'
require_relative 'qemu'

module Erx
  # Linux's guest in the comparison under HVF (docs/design-bench.md, "Linux's guest"):
  # Alpine's stock virt kernel, unmodified, with an initramfs whose /init is
  # erx_peer_bench, built static on the host by erXos's clang and ld.lld against
  # Alpine's musl-dev. Its pins are Linux's own lock, bench/linux/deps.lock, fetched on
  # demand (`tools/erx fetch --linux`) into build/linux-sources and by nothing else, so
  # neither a default fetch nor a --cache fetch needs them. Nothing of Alpine runs on
  # the host: musl-dev's headers and libc.a are inputs to the compiler and linker, its
  # package is unpacked by tar into a directory of its own, and the kernel runs only in
  # QEMU, whose guest has no network device and no disk.
  module LinuxGuest
    LOCK = 'bench/linux/deps.lock'
    WORKSPACE = 'build/linux-sources'
    OUTPUT = 'build/linux-guest'
    KERNEL = 'alpine-vmlinuz-virt'
    MUSL_DEV = 'alpine-musl-dev'
    # What of musl-dev the build reads: the headers, the start files and the archive.
    SYSROOT_MEMBERS = %w[usr/include usr/lib/crt1.o usr/lib/crti.o usr/lib/crtn.o usr/lib/libc.a].freeze
    TARGET = 'aarch64-linux-musl'
    # The kernel's own defaults, plus its console and an immediate end on a panic.
    COMMAND_LINE = 'console=ttyAMA0 panic=-1'

    module_function

    # The lock's sources over their own workspace.
    def lock(root:, runner:)
      Dependencies.new(root: OutputDirectory.prepare(root: root, path: File.join(root, WORKSPACE)),
                       runner: runner, lock_path: File.join(root, LOCK))
    end

    # Fetches every source the lock pins, from cache (another checkout's
    # build/linux-sources/build/downloads) when given. Answers what was done.
    def fetch(root:, runner:, cache: nil)
      dependencies = lock(root: root, runner: runner)
      dependencies.fetch(cache: cache)
      dependencies.sources.map { |source| "linux: #{source.fetch('id')} #{source.fetch('version')} fetched" }
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
      sysroot = unpack_sysroot(dependencies.fetched_file(MUSL_DEV), output: output, runner: runner)
      peer = compile_peer(root: root, sysroot: sysroot, output: output, runner: runner)
      initrd = File.join(output, 'initramfs.cpio')
      File.binwrite(initrd, initramfs(File.binread(peer)))
      kernel = dependencies.fetched_file(KERNEL)
      { kernel: kernel, initrd: initrd,
        subject: { 'kernel' => pin_of(dependencies, KERNEL), 'c_library' => pin_of(dependencies, MUSL_DEV),
                   'command_line' => COMMAND_LINE, 'initramfs_sha256' => Digest::SHA256.file(initrd).hexdigest,
                   'peer_sha256' => Digest::SHA256.file(peer).hexdigest, 'flags' => peer_flags('SYSROOT').join(' ') } }
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

    # musl-dev's members the build reads, unpacked by tar (an argument vector, no shell)
    # into a fresh directory of their own.
    def unpack_sysroot(package, output:, runner:)
      sysroot = File.join(output, 'sysroot')
      FileUtils.rm_rf(sysroot)
      FileUtils.mkdir_p(sysroot)
      runner.run(['tar', '-xzf', package, '-C', sysroot, *SYSROOT_MEMBERS], name: 'linux-guest-sysroot', deadline: 60)
      sysroot
    end

    def peer_flags(sysroot)
      ["--target=#{TARGET}", '-std=c17', '-O2', '-pthread', '-mno-outline-atomics', '-nostdinc',
       '-isystem', File.join(sysroot, 'usr/include'), *PeerBench.flags]
    end

    # erx_peer_bench compiled by ERX_CLANG and linked static by ERX_LLD against the
    # sysroot's start files and libc.a, and erXos's compiler-rt builtins archive, whose
    # binary128 helpers musl's long double printf reaches.
    def compile_peer(root:, sysroot:, output:, runner:)
      clang = ENV.fetch('ERX_CLANG') { raise Error, 'linux guest: set ERX_CLANG to the LLVM clang' }
      lld = ENV.fetch('ERX_LLD') { raise Error, 'linux guest: set ERX_LLD to ld.lld' }
      resource = File.join(File.binread(runner.run([clang, '-print-resource-dir'], name: 'linux-guest-resource-dir',
                                                                                   deadline: 30).fetch('log')).strip, 'include')
      object = File.join(output, 'erx_peer_bench.o')
      peer = File.join(output, 'erx_peer_bench')
      runner.run([clang, *peer_flags(sysroot), '-isystem', resource, '-I', root, '-c',
                  File.join(root, 'bench/peer/erx_peer_bench.c'), '-o', object], name: 'linux-guest-cc', deadline: 300)
      lib = File.join(sysroot, 'usr/lib')
      runner.run([lld, '-static', '-o', peer, *%w[crt1.o crti.o].map { |name| File.join(lib, name) }, object,
                  File.join(lib, 'libc.a'), CompilerRt.archive(root: root, runner: runner, compiler: clang),
                  File.join(lib, 'crtn.o')], name: 'linux-guest-ld', deadline: 120)
      peer
    end
    private_class_method :pin_of, :unpack_sysroot, :peer_flags, :compile_peer
  end
end
