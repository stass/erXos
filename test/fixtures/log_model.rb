# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The kernel log's contract, written from the design's statements and the
# core's documented choices rather than from kernel/core/log.c. It keeps a
# plain list of records and recomputes what the ring must hold from it, so
# it shares neither the ring's positions nor its walks with the core.
#
# From the design (docs/design-kernel.md, "Console, log and panic"):
# * Every byte other than printable ASCII and tab becomes \xNN.
# * A record has a sequence number, a timestamp, a level and its text, and
#   the ring holds 64 KiB of them, the oldest giving way.
# * A debug line opens with the caller's space, and a space writes 16 KiB per
#   second; beyond that lines are dropped and counted.
# * A reader that fell behind is told how many it lost, never shown part of
#   a record.
class LogModel
  OK = 0
  EINVAL = -1
  ELIMIT = -7
  NS_PER_S = 1_000_000_000
  HEADER = 32
  RING = 65_536
  RATE = 16_384
  TEXT_MAX = 2112
  UTCB_BYTES = 504
  LEVELS = { 1 => 'error', 2 => 'warning', 3 => 'info', 4 => 'debug' }.freeze
  LEVEL_INFO = 3
  LEVEL_DEBUG = 4
  TRUNCATED = 1
  SEQ_LAST = 2**64 - 1
  BAD_FORMAT = '<bad format>'

  Record = Data.define(:seq, :time_ns, :level, :flags, :text) do
    def bytes = LogModel.record_bytes(text.bytesize)
  end

  Rate = Struct.new(:start, :bytes, :dropped)

  def self.record_bytes(length) = HEADER + (length + 7) / 8 * 8
  def self.safe?(byte) = byte == 9 || byte.between?(0x20, 0x7e)
  def self.token(byte) = format('\\x%02X', byte)

  def self.escape_whole(bytes)
    bytes.bytes.map { |byte| safe?(byte) ? byte.chr : token(byte) }.join
  end

  # What erx_log_escape must do with capacity bytes of room: every whole
  # byte's form that fits, in order, stopping at the first that does not.
  def self.escape(bytes, capacity)
    output = +''
    consumed = 0
    bytes.each_byte do |byte|
      form = safe?(byte) ? byte.chr : token(byte)
      break if output.bytesize + form.bytesize > capacity

      output << form
      consumed += 1
    end
    [consumed, output]
  end

  # One rate state, so a sequence of its answers can be predicted. A window
  # lasts one second from the line that opened it.
  def self.rate_step(state, now, cost)
    state = state.dup
    if now >= state.start && now - state.start >= NS_PER_S
      state.start = now
      state.bytes = 0
    end
    admit = state.bytes + cost <= RATE
    if admit
      state.bytes += cost
      state.dropped = 0
    else
      state.dropped += 1
    end
    [admit, state]
  end

  def self.render(record)
    seconds, nanoseconds = record.time_ns.divmod(NS_PER_S)
    format("#%d %d.%06d %s %s%s\n", record.seq, seconds, nanoseconds / 1000, LEVELS.fetch(record.level),
           record.text, record.flags.anybits?(TRUNCATED) ? ' [truncated]' : '')
  end

  attr_reader :records, :next_seq

  def initialize
    @records = []
    @next_seq = 0
    @head = 0
    @tail = 0
    @rate = Rate.new(0, 0, 0)
  end

  def state = [@next_seq, @records.empty? ? @next_seq : @records.first.seq, @head, @tail]

  def cursor(seq)
    raise 'the model moves its cursor only over an empty ring' unless @records.empty?

    @next_seq = seq
  end

  def debug(space, now, length, bytes)
    return EINVAL if length > UTCB_BYTES
    return ELIMIT if @next_seq == SEQ_LAST

    prefix = "space #{space}#{@rate.dropped.zero? ? '' : " dropped #{@rate.dropped}"}: "
    text = prefix + self.class.escape_whole(bytes.byteslice(0, length))
    admit, @rate = self.class.rate_step(@rate, now, self.class.record_bytes(text.bytesize))
    append(LEVEL_DEBUG, now, text, 0) if admit
    OK
  end

  # The line erx_log_format writes for "s=%s".
  def format_string(level, now, string)
    return EINVAL unless LEVELS.key?(level)
    return ELIMIT if @next_seq == SEQ_LAST

    whole = "s=#{string.split("\0", 2).first}".b
    consumed, text = self.class.escape(whole, TEXT_MAX)
    append(level, now, text, consumed < whole.bytesize ? TRUNCATED : 0)
    OK
  end

  # [status, next cursor, lost, bytes, records]
  def read(cursor, window)
    return [[EINVAL, cursor, 0, 0, 0], []] if window < HEADER + TEXT_MAX || cursor > @next_seq

    oldest = state[1]
    start = [cursor, oldest].max
    written = 0
    taken = @records.select { |record| record.seq >= start }.take_while do |record|
      written += record.bytes
      written <= window
    end
    bytes = taken.sum(&:bytes)
    [[OK, start + taken.size, start - cursor, bytes, taken.size], taken]
  end

  private

  def append(level, now, text, flags)
    record = Record.new(seq: @next_seq, time_ns: now, level: level, flags: flags, text: text)
    @records << record
    @head += record.bytes
    @next_seq += 1
    while @head - @tail > RING
      @tail += @records.shift.bytes
    end
  end
end
