# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'socket'
require 'tmpdir'
require_relative 'erx_net_eunit'

# The tap helper erx_net_tap (docs/design-network-stack.md, "The tap helper") on a host
# without a tap device. The helper's device is /dev/fd/3, one end of a Unix datagram
# socket pair the test holds the other end of: like a tap, each read of it is one frame
# and each write one frame. Its standard input and output are pipes, so the framing is
# checked with the short reads and the ends of file a port can produce. The pipe's `port`
# end over the helper is test/erlang/erx_net_pipe_port_tests.erl, run here too.
class ErxNetTapTest < Minitest::Test
  include ErxNetEunit

  SOURCE = File.join(ROOT, 'erlang/apps/erx_net/c_src/erx_net_tap.c')
  DEVICE = '/dev/fd/3'
  # Room for the longest frame the 2-byte length carries, and one longer.
  SOCKET_BUFFER = 140_000
  DEADLINE = 10
  # The seeded fault: a helper that writes only the low byte of the length.
  HIGH_BYTE = 'erx_tap_out[0] = (uint8_t)(len >> 8);'

  Run = Data.define(:tap, :input, :output, :error, :pid)

  def test_frames_cross_both_ways_unchanged
    with_helper do |run|
      [60, 1514, 9014].each do |size|
        frame = frame(size)
        run.tap.send(frame, 0)
        assert_equal frame, read_framed(run.output), "#{size} bytes from the tap"
        run.input.write([size].pack('n') + frame)
        assert_equal frame, receive(run.tap), "#{size} bytes to the tap"
      end
      run.input.close
      assert_equal [0, ''], finish(run)
    end
  end

  # Two frames in one write of the port, and one frame in pieces, its length a byte at a
  # time, as a pipe may deliver them.
  def test_short_reads_and_joined_writes_keep_frames_whole
    with_helper do |run|
      first = frame(60)
      second = frame(1514)
      run.input.write([60].pack('n') + first + [1514].pack('n') + second)
      assert_equal first, receive(run.tap)
      assert_equal second, receive(run.tap)
      length = [1514].pack('n')
      [length[0], length[1], second[0, 500], second[500, 500], second[1000..]].each do |piece|
        run.input.write(piece)
        sleep 0.02
      end
      assert_equal second, receive(run.tap)
      run.input.close
      assert_equal 0, finish(run).first
    end
  end

  def test_end_of_file_inside_the_length_fails
    with_helper do |run|
      run.input.write("\x05")
      run.input.close
      assert_failure run, /end of file inside a frame's length/
    end
  end

  def test_end_of_file_inside_a_frame_fails
    with_helper do |run|
      run.input.write([1514].pack('n') + frame(100))
      run.input.close
      assert_failure run, /end of file inside a frame$/
    end
  end

  def test_end_of_file_on_the_tap_fails
    with_helper do |run|
      run.tap.close
      assert_failure run, /read of the tap|end of file on the tap/
    end
  end

  def test_a_frame_the_length_cannot_carry_fails
    with_helper do |run|
      run.tap.send(frame(65_536), 0)
      assert_failure run, /frame longer than 65535 bytes/
    end
  end

  # The helper's end of the pair cannot send a datagram past its send buffer.
  def test_a_failed_write_of_the_tap_fails
    with_helper(helper_send_buffer: 2048) do |run|
      run.input.write([9014].pack('n') + frame(9014))
      assert_failure run, /write of the tap: /
    end
  end

  def test_a_device_that_does_not_open_fails
    output, error, status = Open3.capture3(helper, '/nonexistent/tap', stdin_data: '')
    assert_equal [1, ''], [status.exitstatus, output]
    assert_match %r{\Aerx_net_tap: /nonexistent/tap: open: No such file or directory\n\z}, error
  end

  def test_a_regular_file_is_refused
    Dir.mktmpdir('erx-net-tap-file') do |dir|
      path = File.join(dir, 'not-a-tap')
      File.write(path, frame(60))
      _output, error, status = Open3.capture3(helper, path, stdin_data: '')
      assert_equal 1, status.exitstatus
      assert_match(/a regular file, not a device\n\z/, error)
    end
  end

  # A port that closes while the helper writes a frame to it is the port closing, not a
  # failure: status 0 and nothing on standard error.
  def test_the_port_closing_under_a_frame_ends_quietly
    with_helper do |run|
      run.output.close
      run.tap.send(frame(60), 0)
      assert_equal [0, ''], finish(run)
    end
  end

  def test_seeded_fault_low_length_byte_only_fails_the_1514_case
    source = File.read(SOURCE)
    assert_includes source, HIGH_BYTE
    with_helper(source: source.sub(HIGH_BYTE, 'erx_tap_out[0] = 0;')) do |run|
      run.tap.send(frame(60), 0)
      assert_equal frame(60), read_framed(run.output)
      run.tap.send(frame(1514), 0)
      refute_equal frame(1514), read_framed(run.output)
    end
  end

  def test_the_pipe_port_end_over_the_helper
    assert_erx_net_eunit(:erx_net_pipe_port_tests, tap: true)
  end

  private

  def frame(size) = Array.new(size) { |index| (index * 7 + size) % 256 }.pack('C*')

  # Each source's helper, built once into a directory removed after the run.
  BUILDS = Dir.mktmpdir('erx-net-tap')
  Minitest.after_run { FileUtils.remove_entry(BUILDS) }

  def helper(source: nil)
    @helpers ||= {}
    @helpers[source] ||= build(source)
  end

  def build(source)
    dir = Dir.mktmpdir('helper', BUILDS)
    path = File.join(dir, 'erx_net_tap.c')
    File.write(path, source || File.read(SOURCE))
    output, status = Open3.capture2e('cc', '-std=c17', '-O2', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
                                     '-o', File.join(dir, 'erx_net_tap'), path, stdin_data: '')
    assert status.success?, output
    File.join(dir, 'erx_net_tap')
  end

  def with_helper(source: nil, helper_send_buffer: SOCKET_BUFFER)
    tap, theirs = UNIXSocket.pair(:DGRAM)
    [[tap, SOCKET_BUFFER], [theirs, helper_send_buffer]].each do |socket, send_buffer|
      socket.setsockopt(:SOCKET, :SNDBUF, send_buffer)
      socket.setsockopt(:SOCKET, :RCVBUF, SOCKET_BUFFER)
    end
    input_read, input = IO.pipe
    output, output_write = IO.pipe
    error, error_write = IO.pipe
    input.sync = true
    pid = Process.spawn(helper(source: source), DEVICE, in: input_read, out: output_write, err: error_write,
                                                        3 => theirs)
    [input_read, output_write, error_write, theirs].each(&:close)
    yield Run.new(tap: tap, input: input, output: output, error: error, pid: pid)
  ensure
    # An unreaped child is ours even after it exits; a reaped pid may name another process.
    if pid && !reaped?(pid)
      Process.kill('KILL', pid)
      Process.wait(pid)
    end
    [tap, theirs, input, output, error].compact.reject(&:closed?).each(&:close)
  end

  # Waits for the helper to exit and returns its status and standard error.
  def finish(run)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DEADLINE
    until (done = Process.wait2(run.pid, Process::WNOHANG))
      flunk 'the helper did not exit' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
    (@reaped ||= []) << run.pid
    [done.last.exitstatus, run.error.read]
  end

  # A failing helper closes its output first and waits for the port to close its input,
  # so that no frame the port writes meets a closed pipe; only then does it exit.
  def reaped?(pid) = (@reaped || []).include?(pid)

  def assert_failure(run, diagnostic)
    assert_nil readable(run.output).read_nonblock(1, exception: false), 'the helper kept its output open'
    unless run.input.closed?
      assert_nil Process.wait2(run.pid, Process::WNOHANG), 'the helper exited before its input closed'
      run.input.close
    end
    status, error = finish(run)
    assert_equal 1, status
    assert_equal 1, error.lines.size, error
    assert_match diagnostic, error
  end

  def read_framed(output)
    length = readable(output).read(2).unpack1('n')
    readable(output).read(length)
  end

  def receive(tap) = readable(tap).recv(SOCKET_BUFFER)

  def readable(io)
    flunk 'the helper sent nothing' unless io.wait_readable(DEADLINE)
    io
  end
end
