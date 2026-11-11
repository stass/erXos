# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'socket'
require_relative '../../tools/lib/erx/hostlink_pacer'

# The host link pacer of gate GW's measurement (tools/lib/erx/hostlink_pacer.rb): at
# 11,520 bytes a second each way, a 115,200-baud UART's rate, 23,040 bytes take at least
# two seconds in each direction, both directions run at once, and every byte arrives in
# order and is counted.
class HostlinkPacerTest < Minitest::Test
  RATE = 11_520
  BYTES = RATE * 2

  def test_each_direction_carries_its_rate_and_no_more_at_once
    host, host_inner = UNIXSocket.pair
    target, target_inner = UNIXSocket.pair
    pacer = Erx::HostlinkPacer.new(bytes_per_second: RATE).relay(host: host_inner, target: target_inner)
    to_target = Random.bytes(BYTES)
    to_host = Random.bytes(BYTES)
    started = now
    writers = [Thread.new { host.write(to_target) }, Thread.new { target.write(to_host) }]
    readers = [Thread.new { [target.read(BYTES), now - started] }, Thread.new { [host.read(BYTES), now - started] }]
    (got_target, target_seconds), (got_host, host_seconds) = readers.map(&:value)
    writers.each(&:join)

    assert_equal to_target, got_target
    assert_equal to_host, got_host
    assert_operator target_seconds, :>=, 2.0
    assert_operator host_seconds, :>=, 2.0
    # Within a tenth of the rate, and the two directions overlap: one after the other
    # would take four seconds.
    assert_operator [target_seconds, host_seconds].max, :<, 2.2
    assert_equal({ to_target: BYTES, to_host: BYTES }, pacer.counts)
  ensure
    pacer&.close
    [host, target].each { |io| io&.close }
  end

  def test_a_closed_end_closes_the_other_side
    host, host_inner = UNIXSocket.pair
    target, target_inner = UNIXSocket.pair
    pacer = Erx::HostlinkPacer.new(bytes_per_second: RATE).relay(host: host_inner, target: target_inner)
    host.write('bye')
    host.close
    assert_equal 'bye', target.read
  ensure
    pacer&.close
    target&.close
  end

  # The line's timing, on a fake clock: a slice that waited for a late sleep starts when
  # the line came free; one that came after an idle line starts when it came; after the
  # far side stalled the line, a queued slice earns at most one slice's time of credit.
  def test_line_free_keeps_the_rate_through_lateness_idleness_and_stalls
    slice = Erx::HostlinkPacer::SLICE.fdiv(RATE)
    late = Erx::HostlinkPacer.line_free(free: 10.0, now: 10.001, queued: true, bytes: 64, rate: RATE)
    idle = Erx::HostlinkPacer.line_free(free: 10.0, now: 12.0, queued: false, bytes: 64, rate: RATE)
    stalled = Erx::HostlinkPacer.line_free(free: 10.0, now: 12.0, queued: true, bytes: 64, rate: RATE)

    assert_in_delta 10.0 + slice, late, 1e-9
    assert_in_delta 12.0 + slice, idle, 1e-9
    assert_in_delta 12.0, stalled, 1e-9
  end

  def test_refuses_a_rate_that_is_not_a_positive_integer
    [0, -1, 1.5, nil].each do |rate|
      assert_raises(ArgumentError) { Erx::HostlinkPacer.new(bytes_per_second: rate) }
    end
  end

  private

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
