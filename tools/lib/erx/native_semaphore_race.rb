# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'boot_image'
require_relative 'error'
require_relative 'fiasco'
require_relative 'native_root'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'runner'

module Erx
  # An up across CPUs racing a down's timeout, made certain rather than probable
  # (docs/design-stopgap.md, "Verification"). test/guest/native_semaphore_race runs on a
  # kernel built with one more define, whose up pauses between dequeuing its waiter and
  # activating it, until the waiter is queued again or the hold runs out. No other image boots that kernel,
  # and its build is why make check-native-seeds runs this rather than the QEMU gate.
  module NativeSemaphoreRace
    MEMORY_MIB = 512
    SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, 'test/guest/native_semaphore_race/guest.c'].freeze
    HOLD_US = 500_000
    # The guest is built with the same define, and holds its timings to it.
    DEFINES = ["-DERX_TEST_SEMAPHORE_WAKE_HOLD_US=#{HOLD_US}"].freeze
    CASES = %w[ipc_wait_undisturbed second_down_waits].freeze
    CASE_SECONDS = 120

    module_function

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'semaphore-race-service-up', pattern: /\Aerx: semaphore-race: service up/n, seconds: 30 }.freeze,
       *CASES.map { |name| case_point(name) },
       { name: 'semaphore-race-done', pattern: /\Aerx: semaphore-race: done/n, seconds: 30 }.freeze].freeze
    end

    def case_point(name)
      { name: "semaphore-race-#{name}", pattern: /\Aerx: semaphore-race: #{name} /n, seconds: CASE_SECONDS,
        verify: ->(text) { raise Error, "the semaphore race reports #{text.inspect}" unless text.match?(/ ok\r?\n\z/n) } }.freeze
    end

    class Run
      # source is the tree the root's C comes from, which a test may seed with a fault.
      def initialize(root:, source: root, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @root = File.expand_path(root)
        @source = File.expand_path(source)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @build = File.join(@root, 'build/native-semaphore-race')
      end

      # Boots the image under each accelerator at each CPU count, on the test kernel
      # built from the tree's sources. The real kernel's build must have run, or does
      # when build is true. Any disagreement raises.
      def call(accels:, cpus: [4], jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco, fiasco.build_test_kernel(name: 'semaphore-race', defines: DEFINES, jobs: jobs))
        placement.each(accels: accels, cpus: cpus) do |accel, count, remote|
          report = Qemu.new(root: @root, runner: @runner).run(accel: accel, cpus: count, remote: remote, image: built.single, memory_mib: MEMORY_MIB,
                                                              checkpoints: NativeSemaphoreRace.checkpoints, machine_end: true)
          ["#{accel}-#{count}cpu", { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds') }.freeze]
        end
      end

      private

      def image(fiasco, kernel)
        root_task = NativeRoot.new(root: @root, source: @source, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                              .build(name: 'semaphore-race-root', sources: SOURCES, directory: File.join(@build, 'root'),
                                     flags: ['-DERX_FIASCO_TEST_HOOKS', *DEFINES])
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, kernel: kernel)
                 .build(directory: File.join(@build, 'image'), stand_in_root: root_task)
      end
    end
  end
end
