# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'boot_image'
require_relative 'crash_frame'
require_relative 'error'
require_relative 'fiasco'
require_relative 'native_root'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'runner'

module Erx
  # The watchdog on QEMU (docs/design-stopgap.md, "The watchdog", "Verification"):
  # test/guest/native_watchdog pets past its deadlines and then spins, and the record
  # the watchdog thread writes is read back: its cause, and a time since the last pet
  # no shorter than the deadline the guest asked for.
  module NativeWatchdog
    MEMORY_MIB = 512
    SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, 'test/guest/native_watchdog/guest.c'].freeze
    WATCHDOG = CrashFrame::CODEC.member('crash_cause', 'watchdog')
    DEADLINE_NS = 2_000_000_000
    UNCAUGHT_LINE = /^erx: watchdog: (UNCAUGHT|.* FAILED)/n

    module_function

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'watchdog-armed', pattern: /\Aerx: watchdog: armed/n, seconds: 30 }.freeze,
       { name: 'watchdog-pets', pattern: /\Aerx: watchdog: pets kept it up/n, seconds: 60 }.freeze].freeze
    end

    # Holds one run's log to the record it must end with. Raises on the first disagreement.
    def judge(serial)
      uncaught = UNCAUGHT_LINE.match(serial)
      raise Error, "the guest says #{uncaught[0]}" if uncaught

      result = CrashFrame.read(serial)
      raise Error, CrashFrame.report(result).join(' / ') unless result.status == :valid

      record = result.record
      raise Error, "the record's cause disagrees: #{record}" unless record.fetch('cause') == WATCHDOG
      raise Error, "the record's time since the pet disagrees: #{record}" unless record.fetch('since_pet_ns') >= DEADLINE_NS

      record
    end

    class Run
      # source is the tree the root's C comes from, which a test may seed with a fault.
      def initialize(root:, source: root, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), platform: Platform.development(root))
        @root = File.expand_path(root)
        @platform = platform
        @source = File.expand_path(source)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @build = File.join(@root, 'build/native-watchdog')
      end

      # Boots the image under each accelerator at each CPU count, with the kernel
      # as last built unless asked to rebuild. Any disagreement raises.
      def call(accels:, cpus: [1, 4], jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco)
        placement.each(accels: accels, cpus: cpus) do |accel, count, remote|
          report = Qemu.new(root: @root, runner: @runner).run(platform: @platform, accel: accel, cpus: count, remote: remote, image: built.single, memory_mib: MEMORY_MIB,
                                                              checkpoints: NativeWatchdog.checkpoints, machine_end: true)
          serial = report.fetch('serial_log')
          NativeWatchdog.judge(File.binread(serial))
          ["#{accel}-#{count}cpu", { serial: serial, seconds: report.fetch('elapsed_seconds') }.freeze]
        end
      end

      private

      def image(fiasco)
        root_task = NativeRoot.new(root: @root, source: @source, runner: @runner, compiler: @compiler, linker: @linker, platform: @platform,
                                   fiasco: fiasco)
                              .build(name: 'watchdog-root', sources: SOURCES, directory: File.join(@build, 'root'))
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(@build, 'image'), stand_in_root: root_task)
      end
    end
  end
end
