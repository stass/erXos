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
  # The stop of the machine on Fiasco (docs/design-debugger.md, "The stop"). A test
  # kernel built with one more define panics on CPU 2 of four, three seconds into
  # the boot, when every CPU has been admitted and the system runs. Its crash record
  # must name CPU 2 as the leader of a census over four CPUs, and each of the other
  # three as stopped: it took the debug interrupt, published the registers that
  # interrupt found, and parked. The machine then ends by a reset. A kernel without
  # the stop prints its panic and records no CPU entries, or none at all.
  module NativeMachineStop
    MEMORY_MIB = 512
    CPUS = 4
    LEADER = 2
    DEFINES = ['-DERX_TEST_MACHINE_STOP'].freeze

    module_function

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'machine-stop-seed', pattern: /^erx: machine stop seed\r?\n/n, seconds: 30 }.freeze].freeze
    end

    # The states the record must give each CPU, by number.
    def expected_states
      (0...CPUS).map { |cpu| cpu == LEADER ? 'leader' : 'stopped' }.freeze
    end

    # Holds one run's serial log to the stop. Raises on the first disagreement.
    def judge(serial)
      result = CrashFrame.read(serial)
      raise Error, "machine stop: #{CrashFrame.report(result).join(' / ')}" unless result.status == :valid

      record = result.record
      cpus = record.fetch('cpus', [])
      states = cpus.map { |entry| CrashFrame::STATES.fetch(entry.fetch('state')).to_s }
      problems = []
      problems << "cause #{record.fetch('cause')}" unless record.fetch('cause') == CrashFrame::CODEC.constant('crash_cause_panic')
      problems << "cpu #{record.fetch('cpu')}" unless record.fetch('cpu') == LEADER
      problems << "ncpus #{record.fetch('ncpus', 0)}" unless record.fetch('ncpus', 0) == CPUS
      problems << "states #{states.join(',')}" unless states == expected_states
      problems << 'no reset' unless CrashFrame::RESET_LINE.match?(serial)
      raise Error, "machine stop: the record's #{problems.join('; ')} disagree" unless problems.empty?

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
        @build = File.join(@root, 'build/native-machine-stop')
      end

      # Boots the image under accel on four CPUs, on the test kernel built from the
      # tree's sources, judges its serial log and returns the record. The real
      # kernel's build must have run, or does when build is true.
      def call(accel:, jobs: 4, build: true, remote: nil)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        kernel = fiasco.build_test_kernel(name: 'machine-stop', defines: DEFINES, jobs: jobs)
        image = BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, kernel: kernel)
                         .build(directory: File.join(@build, 'image'))
        report = Qemu.new(root: @root, runner: @runner)
                     .run(platform: @platform, accel: accel, cpus: CPUS, remote: remote, image: image.single,
                          memory_mib: MEMORY_MIB, checkpoints: NativeMachineStop.checkpoints, machine_end: true)
        NativeMachineStop.judge(File.binread(File.expand_path(report.fetch('serial_log'), @root)))
      end
    end
  end
end
