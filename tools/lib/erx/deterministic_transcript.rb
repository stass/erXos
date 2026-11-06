# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # Two deterministic-mode boots of one image must write the same serial transcript, byte
  # for byte (docs/design-stopgap.md, "Deterministic mode"). The compared span starts at the
  # first line of erXos's banner and ends with the shell's "Eshell V" line: what comes before
  # the banner is bootstrap's, and the harness ends the guest on a poll some time after the
  # shell's line, so what follows it is cut wherever the poll fell.
  module DeterministicTranscript
    # The first line of the kernel's banner art (fiasco/kernel/src/kern/banner.cpp).
    BANNER = "             __  __\n"
    SHELL = /\AEshell V/n
    # The kernel's report of its timer, with the counter it read then: a span without it
    # would compare equal whether or not the guest's clock counts instructions.
    CLOCK = /\bcnt=[0-9]+\b/n
    # How much of each differing line a diagnostic quotes.
    QUOTED_BYTES = 200

    module_function

    # The compared span of a transcript, as its lines with their line endings. A transcript
    # without the banner, a clock reading after it, or the shell's line after it has no
    # span, and raises.
    def span(transcript)
      lines = transcript.b.lines
      first = lines.index { |line| line.delete("\r") == BANNER.b }
      raise Error, 'the deterministic transcript has no banner' unless first

      last = (first...lines.size).find { |index| SHELL.match?(lines.fetch(index)) }
      raise Error, 'the deterministic transcript has no shell line after its banner' unless last

      span = lines[first..last].freeze
      raise Error, 'the deterministic transcript has no clock reading to compare' unless span.any? { |line| CLOCK.match?(line) }

      span
    end

    # The number of lines in the two spans, when they are equal byte for byte. Otherwise
    # raises with the first line that differs, numbered from the banner's line as 1. Each
    # span ends at its first shell line, so neither is a prefix of the other, and the two
    # differ at a line both have.
    def compare(first, second)
      ours = span(first)
      theirs = span(second)
      return ours.size if ours == theirs

      index = ours.each_index.find { |at| ours.fetch(at) != theirs.fetch(at) }
      raise Error, "deterministic boots differ at line #{index + 1} of the compared span: " \
                   "#{quoted(ours.fetch(index))} against #{quoted(theirs.fetch(index))}"
    end

    # A line as a diagnostic shows it: escaped, and cut to QUOTED_BYTES.
    def quoted(line) = line.byteslice(0, QUOTED_BYTES).inspect + (line.bytesize > QUOTED_BYTES ? '...' : '')
    private_class_method :quoted
  end
end
