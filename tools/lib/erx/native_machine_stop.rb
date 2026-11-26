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
  # must name CPU 2 as the leader of a census over four CPUs. In the `stopped` run
  # each of the other three is stopped: it took the debug interrupt, published the
  # registers that interrupt found, and parked. In the `lock-held` run CPU 3 takes
  # the console's printf lock just before the panic and spins with interrupts masked
  # without letting go: it never answers, the leader's bounded take of the lock fails,
  # and the report must still be printed, its first line naming CPU 3 and the lock
  # not taken. A CPU that waits for the lock meanwhile does not answer either. The
  # machine then ends by a reset. A kernel without the stop prints its panic and
  # records no CPU entries, or none at all; one whose stop waits for the lock prints
  # nothing.
  module NativeMachineStop
    MEMORY_MIB = 512
    CPUS = 4
    LEADER = 2
    # The seeded panic's message (fiasco/kernel/src/kern/app_cpu_thread.cpp).
    REASON = 'machine stop seed on CPU 2'

    # One test kernel: its defines, the state each CPU must have, by number, or nil
    # where either `stopped` or `unanswered` is right, and the census line the
    # report must begin with, if any.
    Variant = Data.define(:name, :defines, :states, :census_line)

    VARIANTS = [
      Variant.new(name: 'stopped', defines: ['-DERX_TEST_MACHINE_STOP'].freeze,
                  states: %w[stopped stopped leader stopped].freeze, census_line: nil),
      Variant.new(name: 'lock-held',
                  defines: ['-DERX_TEST_MACHINE_STOP', '-DERX_TEST_MACHINE_STOP_LOCK_HELD'].freeze,
                  states: [nil, nil, 'leader', 'unanswered'].freeze,
                  census_line: /^erx: kernel stop: census incomplete: unanswered( \d)* 3\b[^\n]*; console lock not taken\r?$/n)
    ].freeze

    module_function

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'machine-stop-seed', pattern: /^erx: machine stop seed\r?\n/n, seconds: 30 }.freeze].freeze
    end

    # The report's first part, the text before the crash frame (docs/design-debugger.md,
    # "The stop", step 6): the census line where the variant has one, the panic's
    # message in every form, then one line for each CPU with its state.
    def text_problems(serial, variant, states)
      lines = ["erx: kernel stop: #{REASON}",
               *states.each_with_index.map { |state, cpu| "erx: kernel stop: cpu #{cpu} #{state}" }]
      problems = lines.reject { |line| serial.match?(/^#{Regexp.escape(line)}\b/n) }.map { |line| "text #{line.inspect} missing" }
      if variant.census_line
        problems << 'census line missing' unless variant.census_line.match?(serial)
      elsif serial.match?(/^erx: kernel stop: census /n)
        problems << 'a census line after a complete census'
      end
      problems
    end

    def state_problems(states, variant)
      return ["ncpus #{states.size}"] unless states.size == CPUS

      states.each_with_index.filter_map do |state, cpu|
        wanted = variant.states.fetch(cpu)
        allowed = wanted ? [wanted] : %w[stopped unanswered]
        "cpu #{cpu} #{state}" unless allowed.include?(state)
      end
    end

    # Holds one run's serial log to the stop. Raises on the first disagreement.
    def judge(serial, variant: VARIANTS.first)
      result = CrashFrame.read(serial)
      raise Error, "machine stop #{variant.name}: #{CrashFrame.report(result).join(' / ')}" unless result.status == :valid

      record = result.record
      states = record.fetch('cpus', []).map { |entry| CrashFrame::STATES.fetch(entry.fetch('state')).to_s }
      problems = []
      problems << "cause #{record.fetch('cause')}" unless record.fetch('cause') == CrashFrame::CODEC.constant('crash_cause_panic')
      problems << "cpu #{record.fetch('cpu')}" unless record.fetch('cpu') == LEADER
      problems << "ncpus #{record.fetch('ncpus', 0)}" unless record.fetch('ncpus', 0) == CPUS
      problems.concat(state_problems(states, variant))
      problems << 'no reset' unless CrashFrame::RESET_LINE.match?(serial)
      problems.concat(text_problems(serial, variant, states))
      raise Error, "machine stop #{variant.name}: the record's #{problems.join('; ')} disagree" unless problems.empty?

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

      # Boots each variant's image under accel on four CPUs, on its test kernel built
      # from the tree's sources, judges its serial log and returns the records by
      # variant name. The real kernel's build must have run, or does when build is true.
      def call(accel:, jobs: 4, build: true, remote: nil, variants: VARIANTS)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        variants.to_h { |variant| [variant.name, run_variant(fiasco, variant, accel: accel, jobs: jobs, remote: remote)] }
      end

      private

      def run_variant(fiasco, variant, accel:, jobs:, remote:)
        kernel = fiasco.build_test_kernel(name: "machine-stop-#{variant.name}", defines: variant.defines, jobs: jobs)
        image = BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, kernel: kernel)
                         .build(directory: File.join(@build, variant.name, 'image'))
        report = Qemu.new(root: @root, runner: @runner)
                     .run(platform: @platform, accel: accel, cpus: CPUS, remote: remote, image: image.single,
                          memory_mib: MEMORY_MIB, checkpoints: NativeMachineStop.checkpoints, machine_end: true)
        NativeMachineStop.judge(File.binread(File.expand_path(report.fetch('serial_log'), @root)), variant: variant)
      end
    end
  end
end
