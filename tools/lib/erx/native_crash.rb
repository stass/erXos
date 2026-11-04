# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'boot_image'
require_relative 'crash_frame'
require_relative 'error'
require_relative 'fiasco'
require_relative 'native_root'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # A root thread's fault on QEMU (docs/design-stopgap.md, "Faults, and the fault of
  # the root task", "The end path"): test/guest/native_crash touches what it must
  # not, one case per image. A run that ended the machine proves little alone, so
  # the crash frame in its log is read back and held to what the guest said it would
  # touch: a read of a decommitted page, a write to a read-only page, a read from
  # another thread than the first, and a trap. A page with too many rights makes the touch
  # succeed, and then the guest's next line fails the run.
  module NativeCrash
    MEMORY_MIB = 512
    SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, 'test/guest/native_crash/guest.c'].freeze
    IMAGE_FIRST = 0x44000000
    THREAD_UNKNOWN = (1 << 64) - 1
    ROOT_TASK = 0
    # The fault word's low bits: bit 1 says the access was a write.
    WRITE_BIT = 2
    FAULT = CrashFrame::CODEC.member('crash_cause', 'fault')
    MEMORY = CrashFrame::CODEC.member('fault_kind', 'memory')
    UNDEFINED = CrashFrame::CODEC.member('fault_kind', 'undefined')
    Case = Data.define(:name, :number, :kind, :write)
    CASES = [
      Case.new(name: 'decommitted', number: 1, kind: MEMORY, write: false),
      Case.new(name: 'read_only_write', number: 2, kind: MEMORY, write: true),
      Case.new(name: 'other_thread', number: 3, kind: MEMORY, write: false),
      Case.new(name: 'trap', number: 4, kind: UNDEFINED, write: false)
    ].freeze
    ADDRESS_LINE = /^erx: crash: address (?<address>[0-9a-f]{16})\r?$/n
    UNCAUGHT_LINE = /^erx: crash: (UNCAUGHT|[a-z -]+ FAILED)/n

    module_function

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'crash-address', pattern: /\Aerx: crash: address /n, seconds: 30 }.freeze].freeze
    end

    # Holds one run's log to its case. Raises on the first disagreement.
    def judge(serial, kase)
      uncaught = UNCAUGHT_LINE.match(serial)
      raise Error, "#{kase.name}: the guest says #{uncaught[0]}" if uncaught

      said = ADDRESS_LINE.match(serial) || raise(Error, "#{kase.name}: no address line")
      result = CrashFrame.read(serial)
      raise Error, "#{kase.name}: #{CrashFrame.report(result).join(' / ')}" unless result.status == :valid

      record = result.record
      fault = record.fetch('fault')
      expected = said[:address].to_i(16)
      disagreements = {
        'cause' => record.fetch('cause') == FAULT,
        'kind' => fault.fetch('kind') == kase.kind,
        'address' => kase.kind != MEMORY || fault.fetch('addr') == expected,
        'access' => kase.kind != MEMORY || (fault.fetch('cause') & WRITE_BIT != 0) == kase.write,
        'pc' => fault.fetch('pc') >= IMAGE_FIRST,
        'thread' => fault.fetch('thread') == THREAD_UNKNOWN,
        'space' => fault.fetch('space') == ROOT_TASK
      }.reject { |_name, agrees| agrees }.keys
      raise Error, "#{kase.name}: the record's #{disagreements.join(', ')} disagree: #{record}" unless disagreements.empty?

      fault
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
        @build = File.join(@root, 'build/native-crash')
      end

      # Boots each case under each accelerator at each CPU count, with the kernel as
      # last built unless asked to rebuild. Any disagreement raises.
      def call(accels:, cpus: [1, 4], jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        images = CASES.to_h { |kase| [kase, image(fiasco, kase)] }
        accels.product(cpus).to_h do |accel, count|
          faults = CASES.to_h { |kase| [kase.name, one(accel, count, kase, images.fetch(kase))] }
          ["#{accel}-#{count}cpu", faults.freeze]
        end
      end

      private

      def one(accel, count, kase, built)
        report = Qemu.new(root: @root, runner: @runner).run(accel: accel, cpus: count, image: built.single, memory_mib: MEMORY_MIB,
                                                            checkpoints: NativeCrash.checkpoints, machine_end: true)
        NativeCrash.judge(File.binread(File.expand_path(report.fetch('serial_log'), @root)), kase)
      end

      def image(fiasco, kase)
        directory = File.join(@build, kase.name)
        root_task = NativeRoot.new(root: @root, source: @source, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                              .build(name: 'crash-root', sources: SOURCES, directory: File.join(directory, 'root'),
                                     flags: ["-DERX_CRASH_CASE=#{kase.number}"])
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(directory, 'image'), stand_in_root: root_task)
      end
    end
  end
end
