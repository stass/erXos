# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'io/console'
require 'minitest/autorun'
require 'pty'
require 'socket'
require 'stringio'
require 'tmpdir'
require_relative '../../tools/lib/erx/board_console'

# The board's console for a walk (docs/design-bench.md, "The walk"): every byte to the log,
# each line of at most its limit to the walk, a longer one only as bytes, and the device
# held by one run at a time, or a TCP port read directly.
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
  # count 4 KiB lines, as a board's wide BENCH lines come.
  def wide(count) = Array.new(count) { |index| "BENCH #{(index % 10).to_s * 4090}\n" }.join.b

  # The events of console read slowly: the reader waits until everything has been sent
  # before its first read, then reads until the console is quiet, and closes it.
  def slowly_read(console, log:)
    sleep 0.3
    events = []
    loop do
      read = console.read(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5)
      break if read.first.is_a?(Erx::BoardWalk::Quiet) || read.first.is_a?(Erx::BoardWalk::Stop)

      events.concat(read)
    end
    console.close
    [events.map { |event| [event.class, event.bytes] }, File.binread(log)]
  end

  def whole?(read, sent)
    read == [Array.new(sent.bytesize / 4097) { [Erx::BoardWalk::Line, 4097] }, sent]
  end

  def test_a_console_served_as_a_tcp_port_is_read_directly_and_every_byte_arrives_whole
    server = TCPServer.new('127.0.0.1', 0)
    board = Thread.new do
      server.accept.tap { |client| client.write(wide(3)) }
    rescue IOError
      nil
    end
    Dir.mktmpdir do |directory|
      log = File.join(directory, 'tcp.log')
      console = Erx::BoardConsole.open("tcp:127.0.0.1:#{server.addr[1]}", log: log,
                                                                          clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      assert whole?(slowly_read(console, log: log), wide(3))
    end
  ensure
    server&.close
    board&.value&.close
  end

  # The seeded fault: a relay that copies the port's bytes into a pty and drops what a
  # write to its master does not take, the out-of-tree relay's bug, fails the same check.
  # 128 KiB is more than any host's pty queue takes in one write: about 1 KiB on macOS.
  def test_a_relay_that_drops_what_a_pty_does_not_take_cuts_the_lines
    PTY.open do |master, slave|
      slave.raw!
      master.write_nonblock(wide(32), exception: false)
      Dir.mktmpdir do |directory|
        log = File.join(directory, 'pty.log')
        console = Erx::BoardConsole.new(slave, log: File.open(log, 'wb'), clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        refute whole?(slowly_read(console, log: log), wide(32))
      end
    end
  end

  def test_a_malformed_or_unreachable_tcp_console_is_refused
    Dir.mktmpdir do |directory|
      malformed = assert_raises(Erx::Error) { Erx::BoardConsole.open('tcp:localhost', log: File.join(directory, 'a.log'), clock: -> { 0 }) }
      assert_match(/tcp:HOST:PORT/, malformed.message)
      closed = TCPServer.new('127.0.0.1', 0).then { |server| server.addr[1].tap { server.close } }
      refused = assert_raises(Erx::Error) { Erx::BoardConsole.open("tcp:127.0.0.1:#{closed}", log: File.join(directory, 'b.log'), clock: -> { 0 }) }
      assert_match(/cannot be reached: ECONNREFUSED/, refused.message)
      refute File.exist?(File.join(directory, 'b.log'))
    end
  end
end
