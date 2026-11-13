# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'boot_image'
require_relative 'compiler_rt'
require_relative 'error'
require_relative 'fiasco'
require_relative 'musl'
require_relative 'native_root'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'runner'

module Erx
  # A C program linked against erXos's musl, run as the root on native Fiasco:
  # test/guest/native_musl reports each case through stdio, and exit() ends the machine.
  module NativeMusl
    MEMORY_MIB = 512
    BACKEND = NativeRoot::BACKEND
    # musl supplies memcpy, bcopy and the rest of what root_mem.c gives a freestanding root.
    SOURCES = [*(NativeRoot::RUNTIME - ["#{BACKEND}/root_mem.c"]), *NativeRoot::VM, *NativeRoot::SERVICE,
               "#{BACKEND}/libc_start.c", "#{BACKEND}/libc_root_start.c", "#{BACKEND}/libc_root_write.c", "#{BACKEND}/libc_root.c"].freeze
    GUEST = 'test/guest/native_musl/guest.c'
    GUEST_FLAGS = %w[--target=aarch64-none-elf -std=c17 -Wall -Wextra -Werror -O2 -nostdinc -fno-stack-protector
                     -mno-outline-atomics].freeze
    CASES = %w[
      constructor main_stack printf_float mmap_flags tls join_churn detached_loop cond_broadcast timed_waits nanosleep_not_early mutex_contended
      malloc_threads realloc_grows mmap_mprotect mprotect_same_runs mprotect_hole cancel refusals
    ].freeze
    CASE_SECONDS = 300
    # Each thread's deletion waits for a grace period, far longer across CPUs under TCG.
    LONG_CASES = { 'join_churn' => 900, 'detached_loop' => 900 }.freeze

    module_function

    # The program counts the CPUs it can pin to, and every pinned case rests on that count.
    def checkpoints(cpus:)
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'musl-main', pattern: /\Aerx: musl: main runs, 1 argument/n, seconds: 30 }.freeze,
       { name: 'musl-cpus', pattern: /\Aerx: musl: cpus #{cpus}\r?\n/n, seconds: 30 }.freeze,
       *CASES.map { |name| case_point(name) },
       { name: 'musl-atexit', pattern: /\Aerx: musl: atexit ran/n, seconds: 30 }.freeze,
       { name: 'musl-done', pattern: /\Aerx: musl: done/n, seconds: 30 }.freeze].freeze
    end

    def case_point(name)
      { name: "musl-#{name}", pattern: /\Aerx: musl: #{name} /n, seconds: LONG_CASES.fetch(name, CASE_SECONDS),
        verify: ->(text) { raise Error, "the musl case reports #{text.inspect}" unless text.match?(/ ok\r?\n\z/n) } }.freeze
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), platform: Platform.development(root))
        @root = File.expand_path(root)
        @platform = platform
        @runner = runner
        @compiler = compiler
        @linker = linker
        @build = File.join(@root, 'build/native-musl')
      end

      # Boots the image under each accelerator at each CPU count, with the kernel
      # as last built unless asked to rebuild. Any disagreement raises.
      def call(accels:, cpus: [1, 4], jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco, jobs: jobs)
        placement.each(accels: accels, cpus: cpus) do |accel, count, remote|
          report = Qemu.new(root: @root, runner: @runner).run(platform: @platform, accel: accel, cpus: count, remote: remote, image: built.single, memory_mib: MEMORY_MIB,
                                                              checkpoints: NativeMusl.checkpoints(cpus: count), machine_end: true)
          ["#{accel}-#{count}cpu", { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds') }.freeze]
        end
      end

      private

      def image(fiasco, jobs:)
        musl = Musl.new(root: @root, runner: @runner, compiler: @compiler)
        directory = File.join(@build, 'musl')
        libc = musl.build(directory: directory, jobs: jobs)
        guest = compile_guest(musl.include_directories(directory: directory))
        root_task = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @platform, fiasco: fiasco)
                              .build(name: 'musl-root', sources: SOURCES, directory: File.join(@build, 'root'),
                                     archives: [guest, libc, CompilerRt.archive(root: @root, runner: @runner, compiler: @compiler)])
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(@build, 'image'), stand_in_root: root_task)
      end

      def compile_guest(include_directories)
        object = File.join(@build, 'root/guest.o')
        FileUtils.mkdir_p(File.dirname(object))
        headers = include_directories.flat_map { |path| ['-isystem', path] }
        @runner.run([@compiler, *GUEST_FLAGS, *headers, '-c', GUEST, '-o', object],
                    name: 'native-musl-guest', deadline: 60, chdir: @root)
        object
      end
    end
  end
end
