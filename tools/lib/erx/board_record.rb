# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'time'
require_relative 'bench_record'
require_relative 'bench_suite'
require_relative 'bench_system'
require_relative 'card_settings'
require_relative 'board_files'
require_relative 'board_log'
require_relative 'boot_partition'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'json_input'
require_relative 'line_escape'
require_relative 'native_bench'
require_relative 'peer_bench'

module Erx
  # The record of a board run (docs/design-bench.md, "The record of a board run"): one
  # BenchRecord::Record per set the walk booted, holding that set's boots (BoardLog::Boot,
  # each at its entry's queue position) with the set's environment and subject, read from
  # its build record, and the run's facts. The live walk's record (BoardRun's seam) and
  # `tools/erx bench import`'s are the same function (recorded) of the console's log, the
  # queue and the walk's outcomes when there are any, and both are written by
  # BenchRecord.write. Only the import refuses a log that names no boot: the live walk
  # saw its own boots not begin, and records them not_run.
  #
  # The board's bytes reach a record only as BoardLog judged them, as each boot's slice of
  # the log, kept as its serial log, and as sensor readings, kept line by line through
  # LineEscape, so nothing of them reaches a terminal or the record's JSON raw.
  module BoardRecord
    # The board every walk runs on (docs/design-bench.md, "Running on the Raspberry Pi 4").
    CPUS = 4

    # What a set's record holds of the set: its environment, its subject, what its boots
    # ask (BenchMeasurement::Asked), and the ARM clock its config.txt set (CardSettings),
    # nil when its build record states none.
    SetFacts = Data.define(:environment, :subject, :asked, :arm_clock_hz)

    module_function

    # The set of the queue boot_set as its records name it, from its build record, which
    # must still be the one the walk's entries were made from: the firmware files' SHA-256
    # as the record lists them, its source revision, its kernel8.img's SHA-256 and the
    # compiler that built it (BL31's, the set's one compiler). The walk names every set
    # by its absolute directory, so the record reads the set the walk booted wherever the
    # import runs. A set whose record names Linux among its inputs is Linux's
    # (LinuxBoard): its environment's system is linux, its subject holds Linux's facts,
    # and its boots ask erx_peer_bench's counterparts of benchmark rather than erXos's
    # native cells.
    def set(boot_set, benchmark:)
      raise Error, "board record: the set #{boot_set.directory} is not named by an absolute directory" unless
        File.absolute_path?(boot_set.directory)

      path = File.join(boot_set.directory, BootPartition::SET_RECORD)
      bytes = BoundedFile.read(path, maximum: BootPartition::RECORD_BYTES)
      raise Error, "board record: #{path} is not the one the walk's entries were made from" unless
        Digest::SHA256.hexdigest(bytes) == boot_set.record_sha256

      receipt = JsonInput.parse(bytes, max_bytes: BootPartition::RECORD_BYTES, label: path)
      files = BootPartition.listed_files(receipt)
      receipt.fetch('source').fetch_values('commit', 'dirty') => [String => commit, dirty]
      receipt.fetch('inputs').fetch('firmware') => Array => firmware
      receipt.fetch('inputs').fetch('linux', nil) => Hash | nil => linux
      card = CardSettings.read(receipt, label: path)
      SetFacts.new(
        environment: BenchRecord::Environment.new(
          kind: 'pi4', model: nil, cpus: CPUS, system: linux ? 'linux' : 'erxos',
          details: { 'memory_mib' => card.memory_mib,
                     'firmware' => firmware.to_h { |source| [source.fetch('filename'), files.fetch(source.fetch('filename'))] } }
            .compact
        ),
        subject: BenchRecord::Subject.new(
          revision: commit, dirty: dirty,
          details: { 'kernel8_sha256' => files.fetch(BootPartition::KERNEL), 'record_sha256' => boot_set.record_sha256,
                     'root_flags' => boot_set.root_flags, 'compiler' => receipt.dig('inputs', 'bl31', 'compiler') }
                     .merge(linux || {}).compact
        ),
        asked: linux ? PeerBench.asked(benchmark, cpus: CPUS, clock: 'counter') : NativeBench.asked(BenchSuite.benchmark(benchmark), cpus: CPUS),
        arm_clock_hz: card.arm_clock_hz
      )
    rescue NoMatchingPatternError, KeyError, TypeError, NoMethodError
      raise Error, "board record: #{path} does not name the set's source, firmware and kernel"
    end

    # The run's facts: the queue's date; the ARM clock its sets' config.txt set (CardSettings),
    # nil unless every set states the same one; the sensor readings, each named for when it was
    # read and nil when none was; how the walk ended and whether the link was restored,
    # nil without the walk; and what the board returned to (BoardLog's read).
    def run(queue:, walk:, read:, readings:, started_by:, arm_clock_hz:)
      returned = read.returned
      BenchRecord::Run.new(
        date: Time.iso8601(queue.date).utc, started_by: started_by, load: nil, host_cpus: nil, reused_from: nil,
        details: { CardSettings::CLOCK_KEY => arm_clock_hz,
                   'sensors' => readings.transform_values { |text| text&.each_line&.map { |line| LineEscape.escape(line.chomp) } },
                   'ending' => walk&.ending, 'restored' => walk&.restored,
                   'returned' => { 'status' => returned.status, 'identity' => returned.identity&.to_h&.transform_keys(&:to_s) } }
      )
    end

    # One record per set of the queue, in the queue's order of sets: the set's boots of
    # read in position order, each with its slice of the log as its serial log, and what
    # its lines refused.
    def records(read, sets:, run:)
      read.boots.group_by { |boot| boot.entry.set }.sort.map do |index, boots|
        set = sets.fetch(index)
        BenchSystem::Recorded.new(
          record: BenchRecord::Record.new(environment: set.environment, subject: set.subject, run: run,
                                          boots: boots.map(&:record_boot)),
          refused: boots.flat_map(&:refused), logs: boots.map { |boot| { serial: boot.log } }
        )
      end
    end

    # The records of the walk whose console log is log, of queue, with the walk's
    # outcomes (or nil) and the sensor readings; read is BoardLog's read of it, against
    # what each set's boots ask of the queue's benchmark at the landing profile.
    def recorded(log, queue:, walk:, readings:, started_by:)
      sets = queue.sets.map { |boot_set| set(boot_set, benchmark: queue.benchmark) }
      read = BoardLog.read(log, queue: queue, asked: sets.map(&:asked), walk: walk)
      yield read if block_given?
      records(read, sets: sets, run: run(queue: queue, walk: walk, read: read, readings: readings, started_by: started_by,
                                         arm_clock_hz: clock(sets)))
    end

    # The ARM clock every one of sets states, or nil when they state none or differ.
    def clock(sets) = sets.map(&:arm_clock_hz).uniq.then { |clocks| clocks.size == 1 ? clocks.first : nil }

    # Writes each record under history; returns the run directories.
    def write(made, history:, root:)
      made.map { |recorded| BenchRecord.write(recorded.record, history: history, erxos_root: root, logs: recorded.logs) }
    end

    # `tools/erx bench import NAME --queue FILE LOG` (docs/design-bench.md, "Importing a
    # log"): the records of the walk of NAME whose queue file is queue and whose console
    # log is log, with walk.json beside the queue when the walk wrote it, written under
    # history. A log no line of which names a boot is refused, and so is a queue with a set
    # of an environment other than environment, the one the command line names.
    def import(name, environment:, queue:, log:, root:, history:)
      walked = BoardFiles.read_queue(queue)
      raise Error, "board record: #{queue} is a walk of #{walked.benchmark}, not of #{name}" unless walked.benchmark == name

      walk_path = File.join(File.dirname(queue), BoardFiles::WALK)
      walk = File.file?(walk_path) ? BoardFiles.read_walk(walk_path) : nil
      bytes = BoundedFile.read(log, maximum: BoardLog.max_bytes(walked))
      made = recorded(bytes, queue: walked, walk: walk, readings: { 'before' => nil, 'after' => nil },
                             started_by: 'manual') do |read|
        raise Error, "board record: #{log} names no boot of the queue, so no line of it is tied to a boot" if
          read.boots.all? { |boot| boot.cells.all? { |cell| cell.reason == BoardLog::UNNAMED } }
      end
      others = made.map { |recorded| recorded.record.environment.name }.uniq - [environment]
      raise Error, "board record: #{queue} holds a set of #{others.join(', ')}, not of #{environment}" unless others.empty?

      write(made, history: history, root: root)
    end
  end
end
