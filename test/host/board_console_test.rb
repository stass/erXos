# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require_relative '../../tools/lib/erx/board_console'

# The board's console for a walk (docs/design-bench.md, "The walk"): every byte to the log,
# each line of at most its limit to the walk, a longer one only as bytes, and the device
# held by one run at a time.
class BoardConsoleTest < Minitest::Test
  NAME = '0123456789abcdef0123456789abcdef'

  def setup
    @reader, @writer = IO.pipe
    @log = StringIO.new(+''.b)
    @now = 0.0
    @console = Erx::BoardConsole.new(@reader, log: @log, clock: -> { @now += 0.001 }, line_bytes: 16)
  end

  def teardown
    [@reader, @writer].each { |io| io.close unless io.closed? }
  end

  # Every event until the pipe has nothing more for a moment.
  def drained
    events = []
    loop do
      read = @console.read(@now + 0.2)
      break if read.first.is_a?(Erx::BoardWalk::Quiet) || read.first.is_a?(Erx::BoardWalk::Stop)

      events.concat(read)
    end
    events
  end

  def test_lines_split_across_reads_reach_the_walk_whole_and_the_log_holds_every_byte
    @writer.write("erx: end re")
    @writer.flush
    first = drained
    @writer.write("set\r\nBENCH x\n")
    @writer.flush
    events = first + drained
    assert_equal [[:end, 'reset', 16], [:guest, nil, 8]], events.map { |event| [event.kept.kind, event.kept.form, event.bytes] }
    assert_equal "erx: end reset\r\nBENCH x\n", @log.string
  end

  def test_a_line_over_its_limit_is_cut_and_reaches_the_walk_only_as_bytes
    long = "BENCH #{'y' * 40}\n"
    @writer.write(long)
    @writer.write("erx: end off\n")
    @writer.flush
    events = drained
    cut, rest = events.partition { |event| event.is_a?(Erx::BoardWalk::Bytes) }
    assert_equal long.bytesize, cut.sum(&:bytes)
    assert_equal [[:end, 'off']], rest.map { |event| [event.kept.kind, event.kept.form] }
    assert_equal long + "erx: end off\n", @log.string
  end

  def test_a_console_printing_without_a_newline_is_counted_as_it_comes_not_held
    @writer.write('z' * 40)
    @writer.flush
    assert_equal [40], [drained.select { |event| event.is_a?(Erx::BoardWalk::Bytes) }.sum(&:bytes)]
    @writer.write("zz\nBENCH x\n")
    @writer.flush
    assert_equal [[Erx::BoardWalk::Bytes, 3], [Erx::BoardWalk::Line, 8]], drained.map { |event| [event.class, event.bytes] }
  end

  def test_a_line_at_its_limit_reaches_the_walk
    @writer.write("erx: bench: boot\n")
    @writer.flush
    assert_equal [Erx::BoardWalk::Line], drained.map(&:class)
  end

  def test_nothing_read_by_the_deadline_is_quiet_and_a_closed_console_stops_the_walk
    assert_instance_of Erx::BoardWalk::Quiet, @console.read(@now + 0.05).first
    @writer.close
    assert_equal 'console_closed', @console.read(@now + 1).first.ending
  end

  def test_a_device_another_run_holds_or_none_at_all_is_refused
    Dir.mktmpdir do |directory|
      device = File.join(directory, 'cu.board')
      File.write(device, '')
      opened = Erx::BoardConsole.open(device, log: File.join(directory, 'one.log'), clock: -> { 0 }, line: ->(_io) {})
      error = assert_raises(Erx::Error) do
        Erx::BoardConsole.open(device, log: File.join(directory, 'two.log'), clock: -> { 0 }, line: ->(_io) {})
      end
      assert_match(/another run holds the console/, error.message)
      opened.close
      missing = assert_raises(Erx::Error) { Erx::BoardConsole.open(File.join(directory, 'none'), log: File.join(directory, 'x.log'), clock: -> { 0 }) }
      assert_match(/cannot be opened: ENOENT/, missing.message)
    end
  end
end
