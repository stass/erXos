# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/fuzz/bench_line'
require_relative '../../tools/lib/erx/git_environment'
require_relative '../../tools/lib/erx/board_run'
require_relative '../fixtures/first_stage_fixture'
require_relative '../fixtures/pack_fixture'

# A board run's walk around its effects (docs/design-bench.md, "The walk"), with the
# queue's maker, the console and ssh replaced: the queue's and walk's files beside the
# log, the link pointed back however the walk ends, a found target that is an earlier
# run's queue refused, and the board's bytes shown only escaped.
class BoardRunTest < Minitest::Test
  Fuzz = Erx::BenchLineFuzz
  BENCH = Erx::BoardFiles::Identity.new(**Fuzz::BENCH_BUILD)
  SENSORS = "soc_temp 47.2\n\e]0;title\a\n".b
  ROOT = File.expand_path('../..', __dir__)
  CODEC = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: ROOT).schema)

  # Prints each entry's lines and then the banner of the build the board returns to, found,
  # a few lines a read; raises interrupt at the read numbered by it, when given.
  class Console
    def initialize(names, clock:, found:, interrupt_at: nil)
      lines = [*names.flat_map { |name| Fuzz.entry_lines(name) }, Fuzz.banner(**found)]
      @reads = lines.each_slice(5).to_a
      @clock = clock
      @interrupt_at = interrupt_at
      @count = 0
    end

    def read(_until_at)
      @count += 1
      raise Interrupt if @count == @interrupt_at

      (@reads.shift || []).map do |text|
        Erx::BoardWalk::Line.new(kept: Erx::BoardLog.classify(text, 0), bytes: text.bytesize + 2, at: @clock.call)
      end
    end

    def close = nil

    # What the walk typed, and whether the console takes it.
    def typed = (@typed ||= [])
    attr_writer :takes

    def type(bytes) = (typed << bytes) && @takes != false
  end

  Shell = Struct.new(:calls, :fails) do
    def reboot = (calls << :reboot) && !fails
    def sensors = (calls << :sensors) && SENSORS
  end

  def setup
    @directory = Dir.mktmpdir
    @root = File.join(@directory, 'erxos')
    Dir.mkdir(@root)
    @link = File.join(@directory, 'erxos-http')
    @found = "#{@link}.00112233445566aa"
    FileUtils.mkdir_p(File.join(@found, '1'))
    File.symlink(File.basename(@found), @link)
    @record = File.join(@directory, 'set', Erx::BootPartition::SET_RECORD)
    FileUtils.mkdir_p(File.dirname(@record))
    File.write(@record, '{}')
    @now = 0
    @out = []
    @ran = []
    @prepared = []
    @shell = Shell.new([])
  end

  def teardown = FileUtils.remove_entry(@directory)

  def subject
    Erx::BoardRun::Subject.new(set: Erx::Netboot::BootSet.new(directory: File.dirname(@record), digests: {}, source: {}),
                               record: @record, identity: BENCH, deadline_seconds: 540, root_flags: [])
  end

  # Makes the queue as Netboot.prepare lays it out: one numbered entry a name and the way back.
  def prepare(root:, sets:, names:, key:, found:)
    @prepared << { names: names, key: key, found: found.target, sets: sets.size }
    queue = "#{root}.ffeeddccbbaa9988"
    (1..(names.size + 1)).each do |number|
      FileUtils.mkdir_p(File.join(queue, number.to_s))
      File.write(File.join(queue, number.to_s, Erx::NetbootEntry::IMAGE), "image #{number}")
    end
    queue
  end

  def walk_board(interrupt_at: nil, runs: 2, found: Fuzz::FOUND, takes: true)
    clock = -> { @now += 1 }
    board = Erx::BoardRun.new(
      root: @root, www: @link, shell: @shell, prepare: method(:prepare),
      console: ->(log:) { File.write(log, ''); @console = Console.new(@prepared.last.fetch(:names), clock: clock, found: found, interrupt_at: interrupt_at).tap { |console| console.takes = takes } },
      clock: clock, out: ->(line) { @out << line }, record: ->(ran) { @ran << ran }, codec: CODEC, pause: ->(_seconds) {}
    )
    board.call(benchmark: 'wake', subjects: [subject], runs: runs, key: '/keys/signing.pem')
  end

  def run_directory = Dir[File.join(@root, 'build/bench-board/wake-walk-*')].fetch(0)

  # The found target's one pair, which its way back serves.
  def stage_pair
    File.write(File.join(@found, '1', Erx::NetbootEntry::SIGNATURE), "signature\n")
    File.write(File.join(@found, '1', Erx::NetbootEntry::IMAGE), 'image')
  end

  # The found target's sets/1/kernel8.img as a stage writes it: the single bootable file of
  # the fixture's first stage and archive. Returns the identity the archive's header names.
  def stage_kernel
    File.binwrite(stage = File.join(@directory, 'first-stage'), FirstStageFixture.bytes)
    File.binwrite(archive = File.join(@directory, 'archive'), PackFixture.valid)
    kernel = File.join(@found, Erx::Netboot::SETS, '1', Erx::BootPartition::KERNEL)
    FileUtils.mkdir_p(File.dirname(kernel))
    Erx::BootFile.write(codec: CODEC, first_stage: stage, archive: archive, output: kernel, output_root: @directory)
    header = CODEC.decode_layout('erx_pack_header', File.binread(archive, CODEC.layout_size('erx_pack_header')))
    { build: header.fetch('build_id').unpack1('H*'), index: header.fetch('index_hash').unpack1('H*') }
  end

  def test_the_return_to_the_build_a_found_stage_boots_is_booted
    stage_pair
    found = stage_kernel
    walk = walk_board(found: found)
    assert_equal ['returned', 'booted'], [walk.ending, walk.returned.status]
    queue = Erx::BoardFiles.read_queue(File.join(run_directory, Erx::BoardFiles::QUEUE))
    assert_equal Erx::BoardFiles::Identity.new(**found), queue.return_identity
  end

  def test_the_return_is_unknown_when_the_found_stage_holds_no_bootable_file
    stage_pair
    FileUtils.mkdir_p(File.join(@found, Erx::Netboot::SETS, '1'))
    kernel = File.join(@found, Erx::Netboot::SETS, '1', Erx::BootPartition::KERNEL)
    [-> { File.write(kernel, "\e[2Jnot a boot file") }, -> { stage_kernel && File.chmod(0o000, kernel) }].each do |make|
      make.call
      @out.clear
      walk = walk_board
      assert_equal ['returned', 'unknown', nil], [walk.ending, walk.returned.status, walk.returned.identity]
      said = @out.grep(/names no build/)
      assert_equal 1, said.size, @out.inspect
      refute_match(/\e/, said.first)
    end
  end

  def test_the_return_is_unknown_when_the_found_stage_holds_no_whole_pair
    stage_kernel
    assert_equal 'unknown', walk_board.returned.status
    assert_empty @out.grep(/names no build/)
  end

  def test_the_return_is_unknown_when_the_found_target_is_no_stage
    assert_equal 'unknown', walk_board.returned.status
  end

  def test_a_walk_writes_its_queue_and_walk_beside_the_log_and_points_the_link_back
    walk = walk_board
    assert_equal ['returned', %w[ended ended], true], [walk.ending, walk.outcomes, walk.restored]
    queue = Erx::BoardFiles.read_queue(File.join(run_directory, Erx::BoardFiles::QUEUE))
    assert_equal [@prepared.last.fetch(:names), [1, 2], [0, 0]], [queue.entries.map(&:name), queue.entries.map(&:position), queue.entries.map(&:set)]
    assert_equal Digest::SHA256.hexdigest('image 2'), queue.entries.last.image_sha256
    assert_equal walk, Erx::BoardFiles.read_walk(File.join(run_directory, Erx::BoardFiles::WALK))
    assert_equal [File.basename(@found), false], [File.readlink(@link), Dir.exist?("#{@link}.ffeeddccbbaa9988")]
    assert_equal [File.realpath(@found), "/keys/signing.pem"], [@prepared.last.fetch(:found), @prepared.last.fetch(:key)]
    assert_equal %i[sensors reboot sensors], @shell.calls
    assert_equal [%w[before after], walk], [@ran.last.then { |ran| [ran.before.taken, ran.after.taken] }, @ran.last.walk]
  end

  def test_a_reboot_ssh_cannot_ask_for_is_typed_on_the_console_and_only_then
    walk_board
    assert_equal [], @console.typed
    @shell = Shell.new([], true)
    assert_equal 'returned', walk_board.ending
    assert_equal ["reboot\r"], @console.typed
    assert_includes @out, 'bench: ssh could not ask the board to reboot; the walk typed reboot on its console; ' \
                          'if the board does not restart, reset it by hand within the boot deadline'
  end

  def test_a_console_that_cannot_be_written_when_ssh_cannot_ask_for_the_reboot_ends_the_walk
    @shell = Shell.new([], true)
    assert_equal 'console_closed', walk_board(takes: false).ending
    assert_includes @out, 'bench: ssh could not ask the board to reboot, and the console could not be written; the walk ends with its console closed'
  end

  def test_the_boards_bytes_reach_the_output_only_escaped
    walk_board
    assert(@out.none? { |line| line.match?(/[\x00-\x08\x0b-\x1f\x7f]/) }, @out.inspect)
    assert(@out.any? { |line| line.include?('soc_temp 47.2') })
  end

  def test_a_found_target_that_is_a_queue_of_more_than_one_entry_is_refused_and_nothing_is_prepared
    FileUtils.mkdir_p(File.join(@found, '2'))
    error = assert_raises(Erx::Error) { walk_board }
    assert_equal "bench: #{Erx::BoardRun::QUEUE_LEFT}", error.message
    assert_equal [[], File.basename(@found), []], [@prepared, File.readlink(@link), @shell.calls]
  end

  def test_an_interrupted_walk_points_the_link_back_and_writes_its_walk
    assert_raises(Interrupt) { walk_board(interrupt_at: 3) }
    walk = Erx::BoardFiles.read_walk(File.join(run_directory, Erx::BoardFiles::WALK))
    assert_equal ['interrupted', %w[stopped not_run]], [walk.ending, walk.outcomes]
    assert_equal File.basename(@found), File.readlink(@link)
  end

  def test_a_run_directory_whose_path_crosses_a_link_is_refused_and_the_queue_removed
    elsewhere = File.join(@directory, 'elsewhere')
    Dir.mkdir(elsewhere)
    File.symlink(elsewhere, File.join(@root, 'build'))
    error = assert_raises(Erx::Error) { walk_board }
    assert_match(/symbolic link/, error.message)
    assert_equal [[], File.basename(@found), false], [Dir.children(elsewhere), File.readlink(@link), Dir.exist?("#{@link}.ffeeddccbbaa9988")]
  end

  def test_runs_below_one_are_refused
    assert_raises(Erx::Error) { walk_board(runs: 0) }
  end

  # The board command takes --profile landing, the form its sets are built in, on to the
  # signing key it reads once the history destination is accepted, and refuses full by
  # name before either, even with no history root.
  def test_the_board_command_takes_the_landing_profile_and_refuses_full_by_name
    Dir.mktmpdir('erx-board-command-') do |scratch|
      landing, landing_status = board_command(scratch, profile: 'landing', history: separate_history(scratch))
      full, full_status = board_command(scratch, profile: 'full', history: File.join(scratch, 'absent'))
      assert_match(/cannot open the signing key/, landing)
      refute_match(/--profile/, landing)
      assert_match(/--profile full: the board sets are built only in the landing form/, full)
      refute_match(/signing key|history/, full)
      refute(landing_status.success? || full_status.success?)
    end
  end

  # A history root that does not exist is refused before anything runs: before the
  # signing key is read (docs/design-bench.md, "The record").
  def test_the_board_command_refuses_an_absent_history_before_it_reads_the_key
    Dir.mktmpdir('erx-board-command-') do |scratch|
      output, status = board_command(scratch, profile: 'landing', history: File.join(scratch, 'absent'))
      assert_match(/history root does not exist/, output)
      refute_match(/signing key/, output)
      refute status.success?
    end
  end

  # The bench command on the board with history as ERX_BENCH_HISTORY and a signing key
  # that does not exist, and none of the caller's GIT_ variables, so the real history
  # repository is never touched: its output and status.
  def board_command(scratch, profile:, history:)
    Open3.capture2e(Erx::GitEnvironment.isolated.merge('ERX_BENCH_HISTORY' => history),
                    'ruby', File.join(ROOT, 'tools/erx'), 'bench', 'nullcall', '--env', 'pi4-4gb-erxos',
                    '--console', '/dev/null', '--ssh', 'board', '--key', File.join(scratch, 'absent-key'),
                    '--profile', profile, stdin_data: '')
  end

  # A new, empty git repository under scratch, the separate repository a history is.
  def separate_history(scratch)
    history = File.join(scratch, 'history')
    _, status = Open3.capture2e(Erx::GitEnvironment.isolated, 'git', 'init', '-q', history, stdin_data: '')
    assert status.success?
    history
  end

  def test_ssh_runs_an_argument_vector_in_batch_mode_and_refuses_a_destination_it_could_take_as_an_option
    ssh = Erx::BoardRun::Ssh.new('root@board')
    assert_equal [%w[ssh -o BatchMode=yes -T -- root@board reboot],
                  %w[ssh -o BatchMode=yes -T -- root@board cat /proc/sensors/status]],
                 [ssh.reboot_argv, ssh.sensors_argv]
    assert_raises(Erx::Error) { Erx::BoardRun::Ssh.new('-oProxyCommand=sh') }
  end

  def test_a_sensors_answer_larger_than_a_reading_is_no_reading
    reply = ->(bytes) { ->(*_argv, &block) { Open3.popen3('ruby', '-e', "print 'x' * #{bytes}", &block) } }
    assert_equal 'x' * 100, Erx::BoardRun::Ssh.new('root@board', spawn: reply.call(100)).sensors
    assert_nil Erx::BoardRun::Ssh.new('root@board', spawn: reply.call(5000)).sensors
  end
end
