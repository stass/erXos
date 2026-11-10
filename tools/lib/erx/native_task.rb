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
  # A second task on QEMU (docs/design-stopgap.md, "The root service", "Task exit",
  # "Shared objects and the JIT alias"): test/guest/native_task loads a program from the
  # boot image and runs a task per case. Each case's line says whether its status, its
  # capabilities and the pool's count came back as they should. A fault's crash frame is
  # read back and held to the address the root said, and the lines after it show the
  # machine went on.
  module NativeTask
    MEMORY_MIB = 512
    PROGRAM_PATH = 'boot/native-task'
    ROOT_SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, *NativeRoot::LAUNCH,
                    'test/guest/native_task/guest.c'].freeze
    PROGRAM_SOURCES = [*NativeRoot::TASK, 'test/guest/native_task/program.c'].freeze
    # The race's boots of a task take the time, under TCG above all.
    RACE_SECONDS = 400
    # The yield case's 1000 hand-overs on one CPU: a yield that keeps the CPU to the end of
    # its time slice takes about 20 s, one that hands it over takes milliseconds.
    YIELD_SECONDS = 5
    CASE_LINE = /\Aerx: task: (?<name>[a-z_]+) (?<result>ok|FAILED)/n
    STATUS_FAULT = -1
    WRITE_BIT = 2
    Fault = Data.define(:name, :write)
    FAULTS = [Fault.new(name: 'write_rx', write: true), Fault.new(name: 'run_rw', write: false)].freeze
    FAULT_KIND = CrashFrame::CODEC.member('fault_kind', 'memory')
    ADDRESS_LINE = /^erx: task: address (?<address>[0-9a-f]{16})\r?$/n
    FORGED_LINE = 'erx: task: forged ok'
    # The log case's record: the service's opening, then the text with each control byte a token.
    LOG_RECORD = /\A#[0-9]+ [0-9]+\.[0-9]+ [a-z]+ space [1-9][0-9]*: \\x0A#{FORGED_LINE}\\x0A\\x1B\[2J\r?\n\z/n
    # What test/guest/native_task/modes.h says the write case writes.
    WRITE_BYTES = ("write case:\t\n\e[2J\xFF\n".b + Array.new(1103) { |index| index & 0xff }.pack('C*') + "\n").freeze

    module_function

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB), case_point('program_found', seconds: 30),
       { name: 'task-cpus', pattern: /\Aerx: task: cpus [1-9]/n, seconds: 30 }.freeze,
       case_point('yield', seconds: YIELD_SECONDS), case_point('service', seconds: 30), case_point('write_rx', seconds: 30), case_point('run_rw', seconds: 30),
       case_point('no_jit', seconds: 30), case_point('irq_refused', seconds: 30),
       case_point('device_refused', seconds: 30), case_point('log', seconds: 30),
       case_point('write', seconds: 30), case_point('spin_stop', seconds: 60), case_point('root_stops', seconds: 30),
       case_point('request_against_exit', seconds: RACE_SECONDS),
       { name: 'task-done', pattern: /\Aerx: task: done/n, seconds: 30 }.freeze].freeze
    end

    def case_point(name, seconds:)
      { name: "task-#{name}", pattern: /\Aerx: task: #{name} /n, seconds: seconds,
        verify: ->(text) { raise Error, "the task case reports #{text.inspect}" unless case_passed?(text, name) } }.freeze
    end

    def case_passed?(text, name)
      match = CASE_LINE.match(text)
      !match.nil? && match[:name] == name && match[:result] == 'ok'
    end

    # Holds each fault's crash frame to its line. Each frame lies after the address
    # line the root said for it, and it is not the machine's last word: the suite's
    # later lines are what the transcript checks.
    def judge(serial)
      judge_log(serial)
      judge_write(serial)
      statuses = serial.b.scan(ADDRESS_LINE).flatten
      raise Error, "#{statuses.size} address lines, not #{FAULTS.size}" unless statuses.size == FAULTS.size

      offsets = serial.b.to_enum(:scan, ADDRESS_LINE).map { Regexp.last_match.end(0) }
      FAULTS.zip(statuses, offsets).to_h do |fault, address, offset|
        [fault.name, judge_fault(serial.b.byteslice(offset..), fault, address.to_i(16))]
      end
    end

    # A task's forged line reaches the serial log inside its record, with its newlines
    # and its escape shown, and never at the start of a line.
    def judge_log(serial)
      lines = serial.b.lines
      raise Error, "a task's text started a line" if lines.any? { |line| line.start_with?(FORGED_LINE) }

      forged = lines.grep(LOG_RECORD)
      raise Error, "#{forged.size} forged records, not 1" unless forged.size == 1
    end

    # A task's write reaches the serial log as the program wrote it. Fiasco's console
    # puts a carriage return ahead of every newline, whoever writes it, and that is the
    # one difference (docs/design-stopgap.md, "The console").
    def judge_write(serial)
      raise Error, "the task's write is not in the serial log byte for byte" unless serial.b.include?(WRITE_BYTES.gsub("\n", "\r\n"))
    end

    def judge_fault(rest, fault, address)
      result = CrashFrame.read(rest)
      raise Error, "#{fault.name}: #{CrashFrame.report(result).join(' / ')}" unless result.status == :valid

      record = result.record
      said = record.fetch('fault')
      disagreements = {
        'kind' => said.fetch('kind') == FAULT_KIND,
        'address' => said.fetch('addr') == address,
        'access' => (said.fetch('cause') & WRITE_BIT != 0) == fault.write,
        'space' => said.fetch('space') != 0
      }.reject { |_name, agrees| agrees }.keys
      raise Error, "#{fault.name}: the record's #{disagreements.join(', ')} disagree: #{record}" unless disagreements.empty?

      said
    end

    class Run
      # source is the tree the C comes from, which a test may seed with a fault.
      def initialize(root:, source: root, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @root = File.expand_path(root)
        @source = File.expand_path(source)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @build = File.join(@root, 'build/native-task')
      end

      # Boots the image under each accelerator at each CPU count, with the kernel
      # as last built unless asked to rebuild. Any disagreement raises.
      def call(accels:, cpus: [1, 4], jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco)
        placement.each(accels: accels, cpus: cpus) do |accel, count, remote|
          report = Qemu.new(root: @root, runner: @runner).run(accel: accel, cpus: count, remote: remote, image: built.single, memory_mib: MEMORY_MIB,
                                                              checkpoints: NativeTask.checkpoints, machine_end: true)
          serial = File.expand_path(report.fetch('serial_log'), @root)
          NativeTask.judge(File.binread(serial))
          ["#{accel}-#{count}cpu", { serial: serial, seconds: report.fetch('elapsed_seconds') }.freeze]
        end
      end

      private

      def image(fiasco)
        flags = ['-DERX_FIASCO_TEST_HOOKS']
        native = NativeRoot.new(root: @root, source: @source, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
        program = native.build_task(name: 'native-task', sources: PROGRAM_SOURCES, directory: File.join(@build, 'program'), flags: flags)
        root_task = native.build(name: 'task-root', sources: ROOT_SOURCES, directory: File.join(@build, 'root'), flags: flags)
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(@build, 'image'), stand_in_root: root_task, programs: { PROGRAM_PATH => program })
      end
    end
  end
end
