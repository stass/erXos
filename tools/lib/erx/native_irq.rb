# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'boot_image'
require_relative 'error'
require_relative 'fiasco'
require_relative 'native_root'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # Interrupts through the readiness interface on QEMU (docs/design-stopgap.md,
  # "Interrupts and readiness", "Verification"): test/guest/native_irq sets up a device
  # line and software objects, parks an executor, and asks for each character the
  # harness types, whose label and byte come back on the same serial line.
  module NativeIrq
    MEMORY_MIB = 512
    SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, 'test/guest/native_irq/guest.c'].freeze
    LABEL_UART = 0x55a0
    # What the harness types, one character per prompt.
    FIRST = 'a'
    SECOND = 'b'
    FAILED_LINE = /^erx: irq: .* FAILED/n

    module_function

    def uart_line(byte)
      /\Aerx: irq: uart label byte 0x#{format('%016x', LABEL_UART)} 0x#{format('%016x', byte.ord)}\r?\n/n
    end

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       point('irq-time-page', /\Aerx: irq: the time page agrees/n, 30),
       point('irq-uart-registers', /\Aerx: irq: sigma0 gave the UART/n, 30),
       point('irq-line-free', /\Aerx: irq: the UART's receive line is free/n, 30),
       point('irq-parked-wake', /\Aerx: irq: a parked executor woke/n, 30),
       point('irq-before-park', /\Aerx: irq: a trigger before the park returned/n, 30),
       point('irq-once-and-order', /\Aerx: irq: each label once, oldest first/n, 30),
       point('irq-timed-park', /\Aerx: irq: a timed park ended/n, 30),
       point('irq-rounds', /\Aerx: irq: rounds of ring and park/n, 120),
       point('irq-prompt-first', /\Aerx: irq: type a character/n, 30, type: FIRST),
       point('irq-first-character', uart_line(FIRST), 60),
       point('irq-prompt-second', /\Aerx: irq: type another/n, 30, type: SECOND),
       point('irq-second-character', uart_line(SECOND), 60),
       point('irq-done', /\Aerx: irq: done/n, 30)].freeze
    end

    def point(name, pattern, seconds, **rest) = { name: name, pattern: pattern, seconds: seconds, **rest }.freeze

    # Raises on a failure the guest named, which a transcript's timeout would only imply.
    def judge(serial)
      failed = FAILED_LINE.match(serial)
      raise Error, "the guest says #{failed[0]}" if failed
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
        @build = File.join(@root, 'build/native-irq')
      end

      # Boots the image under each accelerator at each CPU count, with the kernel
      # as last built unless asked to rebuild. Any disagreement raises.
      def call(accels:, cpus: [1, 4], jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco)
        accels.product(cpus).to_h do |accel, count|
          ["#{accel}-#{count}cpu", boot(built, accel, count).freeze]
        end
      end

      private

      def boot(built, accel, count)
        report = Qemu.new(root: @root, runner: @runner).run(accel: accel, cpus: count, image: built.single, memory_mib: MEMORY_MIB,
                                                            checkpoints: NativeIrq.checkpoints, machine_end: true)
      rescue Error => e
        serial = Dir[File.join(@root, 'build/qemu/*/serial.log')].max_by { |path| File.mtime(path) }
        NativeIrq.judge(File.binread(serial)) if serial
        raise e
      else
        serial = report.fetch('serial_log')
        NativeIrq.judge(File.binread(serial))
        { serial: serial, seconds: report.fetch('elapsed_seconds') }
      end

      def image(fiasco)
        root_task = NativeRoot.new(root: @root, source: @source, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                              .build(name: 'irq-root', sources: SOURCES, directory: File.join(@build, 'root'), flags: ['-DERX_FIASCO_TEST_HOOKS'])
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(@build, 'image'), stand_in_root: root_task)
      end
    end
  end
end
