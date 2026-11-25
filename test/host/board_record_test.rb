# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../../tools/fuzz/bench_line'
require_relative '../../tools/lib/erx/board_record'

# The record of a board run (docs/design-bench.md, "The record of a board run" and
# "Importing a log"): one record per set the walk booted, holding that set's boots at
# their queue positions, its environment and subject read from the set's build record.
# The logs are erXos's own, built in the guest's line format (Erx::BenchLineFuzz).
class BoardRecordTest < Minitest::Test
  Fuzz = Erx::BenchLineFuzz
  FIRST, SECOND, THIRD = Fuzz::BOARD_NAMES
  COMMIT = 'ab' * 20
  COMPILER = 'Homebrew clang version 21.1.0'

  def setup
    @scratch = File.realpath(Dir.mktmpdir('erx-board-record-'))
  end

  def teardown
    FileUtils.remove_entry(@scratch)
  end

  # A set's directory holding its build record as BootPartition writes one: the
  # partition's files with their SHA-256, the source, the inputs the record reads and
  # what the card's config.txt set; linux, when given, is Linux's facts as LinuxBoard's
  # set records them.
  def set_directory(name, kernel:, clock: 1_500_000_000, linux: nil)
    directory = File.join(@scratch, name)
    FileUtils.mkdir_p(directory)
    files = { 'kernel8.img' => kernel, 'start4.elf' => '22' * 32, 'fixup4.dat' => '33' * 32 }
    receipt = { 'version' => 1, 'kind' => 'assembled',
                'components' => files.map { |file, sha256| { 'path' => "boot/#{file}", 'sha256' => sha256 } },
                'source' => { 'commit' => COMMIT, 'dirty' => false },
                'inputs' => { 'platform' => 'raspi4b',
                              'firmware' => [{ 'id' => 'rpi-firmware-start4', 'filename' => 'start4.elf' },
                                             { 'id' => 'rpi-firmware-fixup4', 'filename' => 'fixup4.dat' }],
                              'bl31' => { 'compiler' => COMPILER }, 'linux' => linux }.compact }
    receipt['arm_clock_hz'] = clock if clock
    receipt['total_mem_mib'] = 1024
    path = File.join(directory, 'boot.receipt.json')
    File.write(path, JSON.generate(receipt))
    Erx::BoardFiles::BootSet.new(directory: directory, record_sha256: Digest::SHA256.file(path).hexdigest,
                                 root_flags: ['-DERX_BENCH_DEADLINE_S=60u'])
  end

  def queue(sets, set_of)
    Erx::BoardFiles::Queue.new(
      benchmark: 'wake', date: '2026-11-25T00:15:00Z', sets: sets,
      entries: Fuzz::BOARD_NAMES.zip(set_of).each.with_index(1).map do |(name, set), position|
        Erx::BoardFiles::Entry.new(position: position, name: name, set: set, image_sha256: format('%064x', position))
      end,
      return_identity: Erx::BoardFiles::Identity.new(**Fuzz::FOUND)
    )
  end

  def walk(outcomes = %w[ended ended ended])
    Erx::BoardFiles::Walk.new(outcomes: outcomes, ending: 'returned', restored: true,
                              returned: Erx::BoardFiles::Returned.new(status: 'booted'))
  end

  def recorded(queue, walk: walk(), log: Fuzz.board_log, readings: { 'before' => "cpu_temp 41.2\n", 'after' => nil })
    read = Erx::BoardLog.read(log, queue: queue, asked: Fuzz.board_asked * queue.sets.size, walk: walk)
    sets = queue.sets.map { |set| Erx::BoardRecord.set(set, benchmark: queue.benchmark) }
    Erx::BoardRecord.records(read, sets: sets,
                                   run: Erx::BoardRecord.run(queue: queue, walk: walk, read: read, readings: readings,
                                                             started_by: 'manual', arm_clock_hz: Erx::BoardRecord.clock(sets)))
  end

  def test_a_walk_of_three_entries_of_one_set_is_one_record_of_three_boots
    one = set_directory('wake', kernel: '11' * 32)
    made = recorded(queue([one], [0, 0, 0]))
    assert_equal 1, made.size
    record = made.first.record
    assert_equal [1, 2, 3], record.boots.map(&:position), 'every boot of the set is in its record'
    assert_equal Fuzz::BOARD_NAMES, record.boots.map { |boot| boot.details.fetch('name') }
    assert_equal [format('%064x', 1)], [record.boots.first.details.fetch('image_sha256')]
    assert_equal [%w[ended done]] * 3, record.boots.map { |boot| boot.details.values_at('outcome', 'ended') }
    assert(record.boots.all? { |boot| boot.cells.all? { |cell| cell.status == 'measured' } })
    assert_equal 'pi4-4gb-erxos', record.environment.name
    assert_equal({ 'memory_mib' => 1024, 'firmware' => { 'start4.elf' => '22' * 32, 'fixup4.dat' => '33' * 32 } },
                 record.environment.details)
    assert_equal COMMIT, record.subject.revision
    assert_equal({ 'kernel8_sha256' => '11' * 32, 'record_sha256' => one.record_sha256,
                   'root_flags' => ['-DERX_BENCH_DEADLINE_S=60u'], 'compiler' => COMPILER }, record.subject.details)
    assert_equal Time.utc(2026, 11, 25, 0, 15, 0), record.run.date
    assert_equal({ 'before' => ['cpu_temp 41.2'], 'after' => nil }, record.run.details.fetch('sensors'))
    assert_equal ['returned', true, { 'status' => 'booted', 'identity' => nil }],
                 record.run.details.values_at('ending', 'restored', 'returned')
    # Each boot's log is its slice of the console, and the slices are the whole log.
    assert_equal Fuzz.board_log.b, made.first.logs.map { |logs| logs.fetch(:serial) }.join
  end

  def test_a_paired_walk_is_one_record_per_set_each_at_its_entries_positions
    made = recorded(queue([set_directory('a', kernel: '11' * 32), set_directory('b', kernel: '44' * 32)], [0, 1, 0]))
    assert_equal [[1, 3], [2]], made.map { |recorded| recorded.record.boots.map(&:position) }
    assert_equal [['11' * 32], ['44' * 32]], made.map { |recorded| [recorded.record.subject.details.fetch('kernel8_sha256')] }
    refute_equal made[0].record.name, made[1].record.name
  end

  def test_an_entry_booted_twice_stays_a_boot_of_its_record_with_its_cells_rejected
    lines = Fuzz.board_lines.dup
    lines.insert(lines.index("erx: bench: boot #{SECOND}"), "erx: bench: boot #{FIRST}")
    record = recorded(queue([set_directory('wake', kernel: '11' * 32)], [0, 0, 0]), log: Fuzz.board_log(lines)).first.record
    assert_equal [1, 2, 3], record.boots.map(&:position)
    assert(record.boots.first.cells.all? { |cell| cell.status == 'rejected' })
  end

  def test_an_import_without_the_walk_records_its_run_facts_as_unknown
    record = recorded(queue([set_directory('wake', kernel: '11' * 32)], [0, 0, 0]), walk: nil,
                                                                                   readings: { 'before' => nil, 'after' => nil }).first.record
    assert_equal [nil, nil, { 'status' => 'booted', 'identity' => nil }], record.run.details.values_at('ending', 'restored', 'returned')
    assert_equal 1_500_000_000, record.run.details.fetch('arm_clock_hz')
    assert_equal [nil, nil, nil], record.boots.map { |boot| boot.details.fetch('outcome') }
  end

  # The run keeps the ARM clock its sets' build records state, and none when they differ.
  def test_the_run_keeps_the_clock_its_sets_state
    mixed = queue([set_directory('wake', kernel: '11' * 32), set_directory('unheld', kernel: '44' * 32, clock: nil)], [0, 1, 1])
    assert_nil recorded(mixed).first.record.run.details.fetch('arm_clock_hz')
  end

  def test_a_sensor_reading_is_kept_escaped
    readings = { 'before' => "fan \e]0;x\a\xff\n", 'after' => nil }
    record = recorded(queue([set_directory('wake', kernel: '11' * 32)], [0, 0, 0]), readings: readings).first.record
    kept = record.run.details.fetch('sensors').fetch('before')
    assert(kept.all? { |line| line.ascii_only? && !line.match?(/[[:cntrl:]]/) }, kept.inspect)
  end

  def test_a_set_whose_build_record_changed_since_the_walk_is_refused
    one = set_directory('wake', kernel: '11' * 32)
    File.write(File.join(one.directory, 'boot.receipt.json'), ' ', mode: 'a')
    error = assert_raises(Erx::Error) { Erx::BoardRecord.set(one, benchmark: 'wake') }
    assert_match(/not the one the walk's entries were made from/, error.message)
  end

  LINUX = { 'kernel' => { 'id' => 'rpi-kernel8', 'version' => '6.18.50', 'sha256' => '44' * 32 }, 'init_sha256' => '55' * 32 }.freeze

  # A set whose build record names Linux (LinuxBoard) is Linux's: the record's
  # environment is pi4-4gb-linux, its subject holds Linux's facts, and its boots ask
  # erx_peer_bench's counterparts rather than erXos's native cells.
  def test_a_set_whose_build_record_names_linux_is_recorded_as_linuxs
    set = Erx::BoardRecord.set(set_directory('linux', kernel: '11' * 32, linux: LINUX), benchmark: 'wake')
    assert_equal 'pi4-4gb-linux', set.environment.name
    assert_equal '55' * 32, set.subject.details.fetch('linux').fetch('init_sha256')
    assert_equal COMPILER, set.subject.details.fetch('compiler')
    assert_equal '11' * 32, set.subject.details.fetch('kernel8_sha256')
    assert_equal Erx::PeerBench.asked('wake', cpus: 4, clock: 'counter'), set.asked
    erxos = Erx::BoardRecord.set(set_directory('erxos', kernel: '11' * 32), benchmark: 'wake')
    assert_equal 'pi4-4gb-erxos', erxos.environment.name
    assert_equal Erx::NativeBench.asked(Erx::BenchSuite.benchmark('wake'), cpus: 4), erxos.asked
  end

  def test_an_import_of_a_queue_of_another_environment_is_refused
    directory = File.join(@scratch, 'walk')
    FileUtils.mkdir_p(directory)
    Erx::BoardFiles.write_queue(directory, queue([set_directory('linux', kernel: '11' * 32, linux: LINUX)], [0, 0, 0]))
    log = File.join(directory, 'console.log')
    File.write(log, Fuzz.board_log)
    error = assert_raises(Erx::Error) do
      Erx::BoardRecord.import('wake', environment: 'pi4-4gb-erxos', queue: File.join(directory, 'queue.json'), log: log, root: @scratch, history: @scratch)
    end
    assert_match(/holds a set of pi4-4gb-linux, not of pi4-4gb-erxos/, error.message)
  end

  def test_an_import_of_a_log_that_names_no_boot_is_refused
    one = set_directory('wake', kernel: '11' * 32)
    directory = File.join(@scratch, 'walk')
    FileUtils.mkdir_p(directory)
    Erx::BoardFiles.write_queue(directory, queue([one], [0, 0, 0]))
    log = File.join(directory, 'console.log')
    File.write(log, Fuzz.board_log([*Fuzz::FIRMWARE_LINES, Fuzz.banner(**Fuzz::FOUND), 'erXos']))
    error = assert_raises(Erx::Error) do
      Erx::BoardRecord.import('wake', environment: 'pi4-4gb-erxos', queue: File.join(directory, 'queue.json'), log: log, root: @scratch, history: @scratch)
    end
    assert_match(/names no boot/, error.message)
    other = assert_raises(Erx::Error) do
      Erx::BoardRecord.import('vm', environment: 'pi4-4gb-erxos', queue: File.join(directory, 'queue.json'), log: log, root: @scratch, history: @scratch)
    end
    assert_match(/is a walk of wake/, other.message)
  end

  # A walk of ten runs, the design's count for a build, is read whole: its log's bound
  # stays within what one bounded read takes.
  def test_a_walk_of_ten_entries_is_read_whole
    one = set_directory('wake', kernel: '11' * 32)
    entries = (1..10).map { |position| Erx::BoardFiles::Entry.new(position: position, name: format('%032x', position), set: 0, image_sha256: format('%064x', position)) }
    walked = Erx::BoardFiles::Queue.new(benchmark: 'wake', date: '2026-11-25T00:15:00Z', sets: [one], entries: entries, return_identity: nil)
    directory = File.join(@scratch, 'walk')
    FileUtils.mkdir_p(directory)
    Erx::BoardFiles.write_queue(directory, walked)
    log = File.join(directory, 'console.log')
    File.write(log, Fuzz.board_log(Fuzz::FIRMWARE_LINES))
    error = assert_raises(Erx::Error) do
      Erx::BoardRecord.import('wake', environment: 'pi4-4gb-erxos', queue: File.join(directory, 'queue.json'), log: log, root: @scratch, history: @scratch)
    end
    assert_match(/names no boot/, error.message)
  end

  def test_a_queue_with_a_date_that_is_no_time_is_refused
    assert_raises(Erx::Error) do
      Erx::BoardFiles::Queue.new(benchmark: 'wake', date: '2026-13-45T99:99:99Z', sets: queue([set_directory('w', kernel: '11' * 32)], [0, 0, 0]).sets,
                                 entries: queue([set_directory('v', kernel: '11' * 32)], [0, 0, 0]).entries, return_identity: nil)
    end
  end

  # The live run's record and an import's are one function of the log: both write
  # through BenchRecord.write, each boot's slice as its serial log.
  def test_the_records_are_written_with_each_boots_slice_as_its_serial_log
    erxos = File.join(@scratch, 'erxos')
    history = File.join(@scratch, 'history')
    [erxos, history].each { |path| git_init(path) }
    made = recorded(queue([set_directory('wake', kernel: '11' * 32)], [0, 0, 0]))
    runs = Erx::BoardRecord.write(made, history: history, root: erxos)
    assert_equal 1, runs.size
    assert_equal %w[boot-1.serial.log boot-2.serial.log boot-3.serial.log], Dir.children(runs.first).grep(/\.log\z/).sort
    assert_equal made.first.logs[1].fetch(:serial), File.binread(File.join(runs.first, 'boot-2.serial.log'))
    assert_equal [1, 2, 3], Erx::BenchRecord.read(runs.first).boots.map(&:position)
  end

  def git_init(path)
    FileUtils.mkdir_p(path)
    _, error, status = Open3.capture3('git', '-C', path, 'init', '-q', stdin_data: '')
    raise "git init failed: #{error}" unless status.success?
  end
end
