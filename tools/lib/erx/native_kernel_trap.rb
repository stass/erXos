# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'boot_image'
require_relative 'build_kind'
require_relative 'crash_frame'
require_relative 'fiasco'
require_relative 'platform'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # A kernel trap on a release kernel ends the machine (docs/design-fiasco.md, "The
  # kernel"). A kernel built from the release configuration with one more define loads
  # from an unmapped address in kernel mode once boot is done; its run under QEMU
  # with -no-reboot must enter the machine stop, print its report and record, and end
  # through PSCI's system reset, which makes QEMU exit. A kernel that only kills the faulting thread and
  # returns to the load traps again and again until the deadline. No other image
  # boots that kernel, and its build is why make check-native-seeds runs this rather
  # than the QEMU gate.
  module NativeKernelTrap
    MEMORY_MIB = 512
    DEFINES = ['-DERX_TEST_KERNEL_TRAP'].freeze

    module_function

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'kernel-trap-seed', pattern: /\Aerx: kernel trap seed\r?\n/n, seconds: 30 }.freeze,
       { name: 'kernel-trap-stop', pattern: /\Aerx: kernel stop: kernel trap: exception class 0x25\r?\n/n,
         seconds: 30 }.freeze].freeze
    end

    # The seed's load is a data abort from kernel mode, exception class 0x25, at address 8.
    DATA_ABORT_KERNEL = 0x25
    SEED_ADDRESS = 8

    # Holds the run's serial log to the stop of a kernel trap (docs/design-debugger.md,
    # "Causes"): a valid record of cause panic whose fault field names the exception's
    # class, the seed's address and a program counter; the development image's full
    # report, whose leader's pc is the trap's, not the stop's call site; nothing printed
    # of the trap before the stop's report; and the reset. Raises on the first
    # disagreement.
    def judge(serial)
      result = CrashFrame.read(serial)
      raise Error, "kernel trap: #{CrashFrame.report(result).join(' / ')}" unless result.status == :valid

      record = result.record
      fault = record.fetch('fault')
      problems = []
      problems << "cause #{record.fetch('cause')}" unless record.fetch('cause') == CrashFrame::CAUSE.fetch(:panic)
      problems << "form #{record.fetch('form')}" unless record.fetch('form') == CrashFrame::FORMS.fetch('full')
      problems << format('exception class 0x%x', (fault.fetch('cause') >> 26) & 0x3f) unless ((fault.fetch('cause') >> 26) & 0x3f) == DATA_ABORT_KERNEL
      problems << "fault address #{fault.fetch('addr')}" unless fault.fetch('addr') == SEED_ADDRESS
      problems << 'no fault pc' if fault.fetch('pc').zero?
      problems << 'the leader\'s pc is not the trap\'s' unless serial.include?(format(' pc 0x%016x state ', fault.fetch('pc')))
      problems << 'a trap dump before the stop' if serial.include?('EXCEPTION:')
      problems << 'no reset' unless CrashFrame::RESET_LINE.match?(serial)
      raise Error, "kernel trap: the record's #{problems.join('; ')} disagree" unless problems.empty?

      record
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), platform: Platform.development(root))
        @root = File.expand_path(root)
        @platform = platform
        @runner = runner
        @compiler = compiler
        @linker = linker
        @build = File.join(@root, 'build/native-kernel-trap')
      end

      # Boots the image under accel on one CPU, on the release test kernel built from
      # the tree's sources, and returns the serial log's path. The real kernel's build must
      # have run, or does when build is true. A run that does not end the machine
      # after the panic raises.
      def call(accel:, jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        kernel = fiasco.build_test_kernel(name: 'kernel-trap', defines: DEFINES, kind: BuildKind::RELEASE, jobs: jobs)
        image = BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, kernel: kernel)
                         .build(directory: File.join(@build, 'image'))
        Qemu.new(root: @root, runner: @runner)
            .run(platform: @platform, accel: accel, cpus: 1, image: image.single, memory_mib: MEMORY_MIB,
                 checkpoints: NativeKernelTrap.checkpoints, machine_end: true)
            .fetch('serial_log')
      end
    end
  end
end
