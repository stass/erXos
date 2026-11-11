# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # A slow wire for gate GW's measurement (docs/plan.md, "Gate GW"): relays a host link
  # between the host's end and the target's at most bytes_per_second each way, as a
  # serial line would, so a guest whose host link is QEMU's UNIX socket is measured as if
  # its link were a UART. 11,520 bytes a second stands in for a 115,200-baud UART, whose
  # 8N1 framing spends ten bits on each byte. Only `tools/erx bench web` uses it.
  #
  # Each direction is a FIFO drained at the rate: a slice reaches the other side once the
  # line has carried everything before it and the slice itself (line_free, a pure
  # function of when the line came free and whether the slice was waiting). The two
  # directions run in threads of their own, so one waits on the other no more than a
  # UART's do. An end that closes closes the other side's writing, and the relay counts
  # every byte it carried each way, each slice before the other side can read it.
  class HostlinkPacer
    # The most a direction reads at once: at 11,520 bytes a second, about 6 ms of line.
    SLICE = 64

    # When the line is free again after carrying a slice of bytes at rate, given when it
    # was free before (free) and the time now. A slice that was already queued when the
    # line came free starts when the line did, so a sleep's lateness is not added to every
    # slice of a burst; but never more than one slice's time before now, so a far side
    # that stalled the line earns no burst of credit. A slice the relay waited for starts
    # when it came. Pure.
    def self.line_free(free:, now:, queued:, bytes:, rate:)
      start = queued ? [free, now - SLICE.fdiv(rate)].max : [free, now].max
      start + bytes.fdiv(rate)
    end

    def initialize(bytes_per_second:)
      raise ArgumentError, "a pace of #{bytes_per_second.inspect} bytes a second" unless
        bytes_per_second.is_a?(Integer) && bytes_per_second.positive?

      @rate = bytes_per_second
      @to_target = 0
      @to_host = 0
      @ios = []
      @threads = []
    end

    # Relays between host, the host's end, and target, the link's; the pacer owns both
    # from then on. Returns self.
    def relay(host:, target:)
      @ios = [host, target]
      @threads = [Thread.new { carry(host, target) { |bytes| @to_target += bytes } },
                  Thread.new { carry(target, host) { |bytes| @to_host += bytes } }]
      self
    end

    # The bytes carried so far each way.
    def counts = { to_target: @to_target, to_host: @to_host }

    # Ends the relay and closes both ends.
    def close
      @ios.each { |io| io.close unless io.closed? }
      @threads.each(&:join)
    end

    private

    def carry(from, to)
      free = now
      loop do
        queued = from.wait_readable(0)
        bytes = from.readpartial(SLICE)
        free = HostlinkPacer.line_free(free: free, now: now, queued: queued, bytes: bytes.bytesize, rate: @rate)
        wait_until(free)
        yield bytes.bytesize
        to.write(bytes)
      end
    rescue IOError, SystemCallError
      begin
        to.close_write unless to.closed?
      rescue IOError, SystemCallError
        nil
      end
    end

    def wait_until(time)
      while (left = time - now).positive?
        sleep(left)
      end
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
