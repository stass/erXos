# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/fuzz/bench_line'
require_relative '../../tools/lib/erx/board_files'
require_relative '../../tools/lib/erx/board_log'

# The board log's reader (docs/design-bench.md, "Importing a log", and its row of
# "Verification"): each line goes to the boot whose naming lines bracket it, or to none,
# and a boot whose end was not seen is timed out only when a deadline someone saw says
# so. The logs are erXos's own, built in the guest's line format (Erx::BenchLineFuzz).
class BoardLogTest < Minitest::Test
  Fuzz = Erx::BenchLineFuzz
  FIRST, SECOND, THIRD = Fuzz::BOARD_NAMES

  def read(lines = Fuzz.board_lines, walk: nil, queue: Fuzz.board_queue)
    Erx::BoardLog.read(Fuzz.board_log(lines), queue: queue, asked: Fuzz.board_asked, walk: walk)
  end

  def statuses(boot) = boot.cells.map { |cell| [cell.operation, cell.status, cell.reason] }

  def measured = Fuzz::BOARD_OPERATIONS.map { |operation| [operation, 'measured', nil] }

  # Entry 3's lines up to and including its first BENCH line and the naming line after it.
  def cut_inside_third
    lines = Fuzz.board_lines
    first_bench = lines.each_index.find { |index| index > lines.index("erx: bench: boot #{THIRD}") && lines[index].start_with?('BENCH ') }
    lines.first(first_bench + 2)
  end

  def walk(outcomes, ending:, returned: 'not_seen')
    Erx::BoardFiles::Walk.new(outcomes: outcomes, ending: ending, restored: true,
                              returned: Erx::BoardFiles::Returned.new(status: returned))
  end

  def test_three_entries_with_the_firmware_between_them_give_three_boots_with_their_cells
    log = Fuzz.board_log
    read = read()
    assert_equal [measured] * 3, read.boots.map { |boot| statuses(boot) }
    assert_equal %w[done done done], read.boots.map(&:ended)
    assert_equal log.b, read.boots.map(&:log).join
    # Each boot's log runs from the end of the one before to its own erx: end line, so
    # the firmware's lines stay with the boot that follows them, and the return ends the last.
    assert read.boots[1].log.start_with?("#{Fuzz::FIRMWARE_LINES.first}\r\n")
    assert read.boots[0].log.end_with?("erx: bench: boot #{FIRST} done\r\nerx: end reset\r\n")
    assert read.boots[2].log.end_with?("erXos\r\n")
    assert_equal 'booted', read.returned.status
  end

  def test_a_dropout_over_one_entrys_end_and_the_next_ones_start_loses_only_the_cell_it_brackets
    lines = Fuzz.board_lines
    from = lines.index("erx: bench: boot #{FIRST} done")
    to = lines.index("erx: bench: boot #{SECOND}")
    read = read(lines[0...from] + lines[(to + 1)..])
    assert_equal measured, statuses(read.boots[0])
    assert_equal [['wake-same-cpu', 'not_run', 'the guest printed no line for it'], *measured.drop(1)], statuses(read.boots[1])
    assert_equal measured, statuses(read.boots[2])
  end

  def test_a_log_cut_inside_an_entry_is_not_timed_out_without_the_walk_that_saw_its_deadline
    read = read(cut_inside_third)
    cells = statuses(read.boots[2])
    assert_equal 'rejected', cells.first[1], 'a boot without its CLOCK line has no calibration'
    assert_equal [['not_run', 'the log ends before its boot did']] * 2, cells.drop(1).map { |cell| cell.drop(1) }
    assert_nil read.boots[2].ended
    assert_equal 'not_seen', read.returned.status

    timed = read(cut_inside_third, walk: walk(%w[ended ended stopped], ending: 'end_deadline'))
    assert_equal [['timed_out', 'the boot timed out before its line']] * 2, statuses(timed.boots[2]).drop(1).map { |cell| cell.drop(1) }

    closed = read(cut_inside_third, walk: walk(%w[ended ended stopped], ending: 'console_closed'))
    assert_equal [['not_run', 'the walk ended: the console closed']] * 2, statuses(closed.boots[2]).drop(1).map { |cell| cell.drop(1) }
  end

  def test_an_entry_whose_end_line_was_lost_before_the_next_boot_is_unseen_not_cut
    lines = Fuzz.board_lines.dup
    lines.delete_at(lines.index("erx: bench: boot #{FIRST} done"))
    lines.delete_at(lines.index { |text| text.include?('"operation":"park-deadline"') })
    read = read(lines)
    assert_nil read.boots[0].ended
    assert_equal [*measured.first(2), ['park-deadline', 'not_run', 'the end of its boot was not seen']], statuses(read.boots[0])
    assert_equal measured, statuses(read.boots[1])
  end

  def test_an_entry_booted_twice_has_every_cell_rejected
    lines = Fuzz.board_lines
    third = lines.index("erx: bench: boot #{THIRD}")
    read = read(lines[0...third] + Fuzz.entry_lines(FIRST) + lines[third..])
    assert_equal [['rejected', 'its entry booted twice']] * 3, statuses(read.boots[0]).map { |cell| cell.drop(1) }
    assert_equal measured, statuses(read.boots[1])
  end

  # A WINDOW line placed in entry 2 joins its next BENCH line, which a non-sustained
  # cell then refuses; one in the firmware's lines between two boots belongs to none.
  def test_a_window_line_between_one_entrys_names_is_that_entrys
    window = Fuzz.window_line
    lines = Fuzz.board_lines.dup
    lines.insert(lines.index("erx: bench: boot #{SECOND}") + 2, window)
    lines.insert(lines.index("erx: bench: boot #{THIRD}") - 3, window)
    read = read(lines)
    assert_equal 'rejected', statuses(read.boots[1]).first[1]
    assert_equal measured, statuses(read.boots[2])
    assert_equal measured, statuses(read.boots[0])
  end

  # A restarted server boots an entry again; a banner between its naming lines ends
  # the bracket, so the two boots' lines are never judged as one.
  def test_an_entry_booted_twice_in_a_row_has_every_cell_rejected
    lines = Fuzz.board_lines
    second = lines.index("erx: bench: boot #{SECOND}")
    read = read(lines[0...second] + Fuzz.entry_lines(FIRST) + lines[second..])
    assert_equal [['rejected', 'its entry booted twice']] * 3, statuses(read.boots[0]).map { |cell| cell.drop(1) }
    assert_equal measured, statuses(read.boots[1])
  end

  def test_the_return_is_the_first_banner_after_the_last_entry
    lines = Fuzz.board_lines
    other = Fuzz.banner(build: 'feedfacefeedface', index: '01' * 32)
    read = read(lines[0...-2] + [other, 'erXos'])
    assert_equal 'unexpected', read.returned.status
    assert_equal 'feedfacefeedface', read.returned.identity.build
    unknown = Erx::BoardFiles::Queue.new(**Fuzz.board_queue.to_h, return_identity: nil)
    assert_equal 'unknown', read(queue: unknown).returned.status
  end

  def test_a_log_larger_than_its_queue_allows_is_refused
    queue = Fuzz.board_queue
    big = Object.new
    big.define_singleton_method(:bytesize) { Erx::BoardLog.max_bytes(queue) + 1 }
    error = assert_raises(Erx::Error) { Erx::BoardLog.read(big, queue: queue, asked: Fuzz.board_asked) }
    assert_match(/larger than its queue allows/, error.message)
  end

  def test_the_queue_and_walk_files_read_back_and_a_foreign_field_is_refused
    Dir.mktmpdir do |directory|
      queue = Fuzz.board_queue
      walked = walk(%w[ended ended_unseen not_run], ending: 'boot_deadline')
      File.write(File.join(directory, Erx::BoardFiles::QUEUE), Erx::BoardFiles.queue_json(queue))
      File.write(File.join(directory, Erx::BoardFiles::WALK), Erx::BoardFiles.walk_json(walked))
      assert_equal queue, Erx::BoardFiles.read_queue(File.join(directory, Erx::BoardFiles::QUEUE))
      assert_equal walked, Erx::BoardFiles.read_walk(File.join(directory, Erx::BoardFiles::WALK))

      odd = File.join(directory, 'odd.json')
      File.write(odd, Erx::BoardFiles.queue_json(queue).sub('"benchmark"', '"path": "/etc", "benchmark"'))
      assert_match(/is not a queue file/, assert_raises(Erx::Error) { Erx::BoardFiles.read_queue(odd) }.message)
    end
  end

  def test_a_stopped_entry_needs_an_ending_that_stops_one
    error = assert_raises(Erx::Error) { walk(%w[ended stopped not_run], ending: 'boot_deadline') }
    assert_match(/stopped entry/, error.message)
  end
end
