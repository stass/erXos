# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'zlib'
require_relative 'log_model'

# The ring console's contract, written from docs/design-fiasco.md, "The
# kernel's lines", rather than from kernel/core/console_ring.c. It keeps the
# ring as two strings, the whole lines and the line still open, so the
# core's positions, wrap and segment checks have nothing to agree with but
# the outcome. Each call returns the line test/fixtures/console_ring_driver.c
# prints for it.
#
# From the design:
# * The route starts at uart. A take moves uart to ring; a close moves any
#   route to closed, which is final.
# * Under uart and closed a write goes to the UART whole; under ring it joins
#   the ring.
# * A write that would overfill the ring, or make the open line longer than
#   LINE_MAX, takes the open line back, counts one lost line and drops what
#   follows in the ring through the next newline. A take that finds a line
#   open on the UART does the same. A close that finds a line open in the
#   ring takes it back and counts it, and ends any drop.
# * A take hands out the lines lost since the last one and as many whole
#   lines as fit REPLY_BYTES, and nothing after the close, which leaves the
#   loss count for the drain; the close writes the loss line and then every
#   line as LABEL, the line without its carriage return and newline escaped,
#   and a carriage return and newline. The close and the root's reader skip
#   empty lines.
class ConsoleRingModel
  BYTES = 4096
  REPLY_BYTES = 61 * 8
  LINE_MAX = REPLY_BYTES
  LABEL = 'fiasco: '

  attr_reader :route, :dropping, :uart_open, :whole, :open, :lost

  def initialize
    @route = :uart
    @dropping = false
    @uart_open = false
    @whole = +''.b
    @open = +''.b
    @lost = 0
  end

  def initialize_copy(other)
    super
    @whole = other.whole.dup
    @open = other.open.dup
  end

  # The driver prints bytes as hex in verbose mode, else as length and CRC.
  def self.bytes(text, verbose:)
    return (text.empty? ? '-' : text.unpack1('H*')) if verbose

    format('%<length>d %<crc>08x', length: text.bytesize, crc: Zlib.crc32(text))
  end

  def self.body(line) = line.delete_suffix("\n").delete_suffix("\r")

  # The root reader's lines of a reply's bytes.
  def self.reply_lines(bytes) = bytes.b.split(/(?<=\n)/).map { |line| body(line) }.reject(&:empty?)

  def self.loss_text(lost) = "#{lost} kernel lines lost"

  def write(text)
    if @route != :ring
      @uart_open = !text.end_with?("\n") unless text.empty?
      return 'write uart'
    end

    at = drop(text, 0)
    while at < text.bytesize
      segment = text.byteslice(at..)[/\A[^\n]*\n?/]
      if @whole.bytesize + @open.bytesize + segment.bytesize > BYTES || @open.bytesize + segment.bytesize > LINE_MAX
        lose
        at = drop(text, at)
        next
      end
      @open << segment
      at += segment.bytesize
      if segment.end_with?("\n")
        @whole << @open
        @open = +''.b
      end
    end
    'write ring'
  end

  def take(verbose:)
    return "take 0 #{self.class.bytes(''.b, verbose: verbose)}" if @route == :closed

    if @route == :uart
      @route = :ring
      lose if @uart_open
      @uart_open = false
    end
    out = @whole.split(/(?<=\n)/).each_with_object(+''.b) do |line, taken|
      break taken if taken.bytesize + line.bytesize > REPLY_BYTES

      taken << line
    end
    @whole = @whole.byteslice(out.bytesize..)
    lost = @lost
    @lost = 0
    "take #{lost} #{self.class.bytes(out, verbose: verbose)}"
  end

  def close
    return 'close 0' if @route == :closed

    lose if @route == :ring && !@open.empty?
    @dropping = false
    @route = :closed
    'close 1'
  end

  def drain(verbose:)
    out = +''.b
    if @route == :closed
      out << "#{LABEL}#{self.class.loss_text(@lost)}\r\n" if @lost.positive?
      @whole.split(/(?<=\n)/).map { |line| self.class.body(line) }.reject(&:empty?).each do |body|
        out << LABEL << LogModel.escape_whole(body) << "\r\n"
      end
      @whole = +''.b
      @lost = 0
    end
    "drain #{self.class.bytes(out, verbose: verbose)}"
  end

  def state(verbose:)
    "state #{@route} #{@dropping ? 1 : 0} #{@uart_open ? 1 : 0} #{@open.bytesize} #{@lost} " \
      "#{self.class.bytes(@whole + @open, verbose: verbose)}"
  end

  private

  def lose
    @open = +''.b
    @lost += 1
    @dropping = true
  end

  # Where text resumes after the rest of a dropped line, from at.
  def drop(text, at)
    return at unless @dropping

    newline = text.index("\n", at)
    return text.bytesize unless newline

    @dropping = false
    newline + 1
  end
end
