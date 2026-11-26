# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/l4re_board'

# L4Re on the board (docs/design-bench.md, "L4Re on the board"): the run's decisions
# from the board's console lines, and the import of its log as a record of environment
# pi4-4gb-l4re set beside erXos's board record.
class L4ReBoardTest < Minitest::Test
  Board = Erx::L4ReBoard
  Walk = Erx::BoardWalk

  def self.tagged(tag, text) = "#{Erx::Ipcbench::FIELDS.key(tag)}#{text}"

  LOG = ['Fiasco', 'CPU0: ID_PFR[01]:  00000131 00000011 ID_[DA]FR0: 10305106 00000000',
         tagged('sc:single', 'CPU  0 done 10000 syscalls in 1234567 cpu-cycles, 123 cpu-cycles/syscall'),
         tagged('ipc:1AS', 'CPU  0 done 20000 IPCs in 4200000 cpu-cycles, 210 cpu-cycles/IPC'),
         'Benchmarks done.'].freeze

  def setup
    @scratch = Dir.mktmpdir('l4re-board-')
  end

  def teardown = FileUtils.rm_rf(@scratch)

  def line(text, at) = Walk::Line.new(kept: Board.classify(text, 0), bytes: text.bytesize + 1, at: at)

  def test_benchmarks_done_asks_for_the_debuggers_reboot_and_a_banner_ends_the_run
    state = Board.start(at: 0)
    state, action = Board.step(state, line('Benchmarks done.', 10))
    assert_equal [:returning, true, :reboot], [state.phase, state.done, action]
    state, action = Board.step(state, line('erx: boot image build 0123456789abcdef index ' + ('a' * 64) + ' x', 40))
    assert_equal ['returned', nil], [state.ending, action]
  end

  def test_the_run_deadline_still_types_the_reboot_and_no_banner_by_the_return_deadline_is_no_return
    state, action = Board.step(Board.start(at: 0), Walk::Quiet.new(at: Board::DONE_SECONDS))
    assert_equal [:returning, false, :reboot], [state.phase, state.done, action]
    state, action = Board.step(state, Walk::Quiet.new(at: Board::DONE_SECONDS + Board::RETURN_SECONDS))
    assert_equal ['not_returned', nil], [state.ending, action]
  end

  def test_erxos_banner_before_benchmarks_done_ends_the_run_typing_nothing
    state, action = Board.step(Board.start(at: 0), line('erx: boot image build 0123456789abcdef index ' + ('a' * 64) + ' x', 40))
    assert_equal ['no_l4re', false, nil], [state.ending, state.done, action]
  end

  def test_a_closed_console_ends_the_run_where_it_is
    state, = Board.step(Board.start(at: 0), Walk::Stop.new(ending: 'console_closed', at: 5))
    assert_equal ['console_closed', false], [state.ending, state.done]
  end

  def test_only_cpus_fiasco_names_as_started_are_counted
    assert_equal [0], Board.started_cpus(LOG)
    assert_equal [0, 1], Board.started_cpus([*LOG, 'CPU1 booted (same IDs as CPU0).'])
  end

  def subject_file
    path = File.join(@scratch, 'build-record.json')
    File.write(path, JSON.generate('bootable' => 'bootstrap.raw', 'bootstrap_sha256' => 'b' * 64))
    path
  end

  def git_init(path)
    FileUtils.mkdir_p(path)
    _, error, status = Open3.capture3('git', '-C', path, 'init', '-q', stdin_data: '')
    raise "git init failed: #{error}" unless status.success?
  end

  SET_RECORD = { 'arm_clock_hz' => 1_500_000_000, 'total_mem_mib' => 1024 }.freeze

  def imported(lines, set_record: SET_RECORD)
    log = File.join(@scratch, 'console.log')
    File.write(File.join(@scratch, Erx::BootPartition::SET_RECORD), JSON.generate(set_record)) if set_record
    File.binwrite(log, "#{lines.join("\r\n")}\r\n")
    erxos, history = File.join(@scratch, 'erxos'), File.join(@scratch, 'history')
    [erxos, history].each { |path| git_init(path) }
    Board.import('nullcall', subject: subject_file, log: log, root: erxos, history: history,
                             revision: Erx::SourceRevision::Revision.new(count: 1, hash: 'c' * 12, commit: 'c' * 40,
                                                                               dirty: false, committed_at: nil))
  end

  def test_a_log_is_imported_as_a_one_cpu_l4re_record_of_the_board
    run, record = imported(LOG)
    assert_equal ['pi4-4gb-l4re', 'l4re', 1], [record.environment.name, record.environment.system, record.environment.cpus]
    assert_equal 'b' * 64, record.subject.details.fetch('bootstrap_sha256')
    assert_equal 1_500_000_000, record.run.details.fetch('arm_clock_hz')
    assert_equal({ 'memory_mib' => 1024 }, record.environment.details)
    assert_equal Digest::SHA256.file(File.join(@scratch, Erx::BootPartition::SET_RECORD)).hexdigest,
                 record.run.details.fetch('set_record_sha256')
    kernel = record.boot.cells.find { |cell| cell.operation == 'kernel' }
    assert_equal ['measured', 123], [kernel.status, kernel.detail.fetch('total') / kernel.detail.fetch('count')]
    assert File.file?(File.join(run, 'run.json'))
  end

  # The run's log runs on to erXos's return boot, which starts every CPU of its own.
  def test_cpus_started_after_benchmarks_done_are_erxos_return_and_not_counted
    returned = ['erx: boot image build 0123456789abcdef index ' + ('a' * 64) + ' x', LOG[1],
                *(1..3).map { |cpu| "CPU#{cpu} booted (same IDs as CPU0)." }]
    _, record = imported([*LOG, *returned], set_record: nil)
    assert_nil record.run.details.fetch('arm_clock_hz')
    assert_equal [1, {}], [record.environment.cpus, record.environment.details]
  end

  def test_a_set_record_that_is_no_object_or_states_a_broken_clock_is_refused
    [[1], { 'arm_clock_hz' => '1500' }, { 'arm_clock_hz' => 1_500_500_000 }, { 'total_mem_mib' => -1 }].each do |broken|
      assert_raises(Erx::Error) { imported(LOG, set_record: broken) }
    end
  end

  def test_a_log_showing_more_than_one_cpu_is_not_imported
    error = assert_raises(Erx::Error) { imported([*LOG[0..1], 'CPU1 booted (same IDs as CPU0).', *LOG[2..]]) }
    assert_match(/CPUs 0, 1/, error.message)
  end
  # A console standing in for the board's: each read answers the next scripted event;
  # what the run types is kept, and type answers typable.
  class Console
    attr_reader :typed

    def initialize(events, typable: true)
      @events = events
      @typable = typable
      @typed = []
    end

    def read(_until) = [@events.shift || Walk::Stop.new(ending: 'console_closed', at: 9)]

    def type(bytes)
      @typed << bytes
      @typable
    end

    def close = nil
  end

  Shell = Struct.new(:asked) do
    def reboot = asked
  end

  # The served link at a found target, a run over it with console, and what the run left:
  # [Ran or the error raised, what the link names afterwards, the queues left beside it].
  def ran(console, shell: Shell.new(false))
    found = File.join(@scratch, 'found')
    Dir.mkdir(found)
    link = File.join(@scratch, 'www')
    File.symlink('found', link)
    prepare = ->(root:, **) { File.join(File.dirname(root), 'queue').tap { |queue| Dir.mkdir(queue) } }
    run = Board::Run.new(root: @scratch, www: link, shell: shell, prepare: prepare, console: console,
                         clock: -> { 0 }, out: ->(_line) {}, pause: ->(_seconds) {})
    outcome = begin
      run.call(set: board_set, key: nil)
    rescue Erx::Error => e
      e
    end
    [outcome, File.readlink(link), Dir.children(@scratch).grep(/\Aqueue/)]
  end

  # A set as lay_out answers it: its partition's directory, with its build record beside it.
  def board_set
    directory = File.join(@scratch, 'set', 'boot')
    FileUtils.mkdir_p(directory)
    File.write(File.join(@scratch, 'set', Erx::BootPartition::SET_RECORD), JSON.generate(SET_RECORD))
    Erx::BoardFiles::BootSet.new(directory: directory, record_sha256: '0' * 64, root_flags: [])
  end

  # The run leaves the set's build record beside its log, where the import reads the card.
  def test_the_run_types_only_reboot_and_the_debuggers_keys_and_points_the_link_back
    console = Console.new([line('Benchmarks done.', 1), line("erx: boot image build #{'0' * 16} index #{'a' * 64} rest", 2)])
    outcome, target, queues = ran(->(**) { console })
    assert_equal [true, 'returned', ["reboot\r", "\e", '^', "\r"], 'found', []],
                 [outcome.done, outcome.ending, console.typed, target, queues]
    assert_equal SET_RECORD, JSON.parse(File.read(File.join(outcome.directory, Erx::BootPartition::SET_RECORD)))
  end

  def test_a_console_that_cannot_be_written_ends_the_run_with_the_link_on_the_found_target
    console = Console.new([line('Benchmarks done.', 1)], typable: false)
    outcome, target, queues = ran(->(**) { console }, shell: Shell.new(true))
    assert_equal [true, 'console_closed', ["\e"], 'found', []], [outcome.done, outcome.ending, console.typed, target, queues]
  end

  def test_a_console_that_cannot_be_opened_leaves_the_link_on_the_found_target
    outcome, target, queues = ran(->(**) { raise Erx::Error, 'no console' })
    assert_equal ['no console', 'found', []], [outcome.message, target, queues]
  end
end
