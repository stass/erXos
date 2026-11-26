# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # Words of erXos's kernel command line that the host tools choose for a boot
  # (kernel/core/boot_args.c reads them; where a word comes twice, the last one counts).
  module KernelWords
    # The word that turns the kernel's trace rings off for the boot
    # (docs/design-fiasco.md, "The kernel's trace rings", "On and off").
    TRACE_OFF = 'erx.trace=0'
    # The words every erXos benchmark boot carries, under QEMU and on a board
    # (docs/design-bench.md, "The kernel's trace rings"): the rings off, since on they
    # cost every IPC and switch a record (docs/design-fiasco.md, "Cost"), which a
    # benchmark would measure as the system's own cost.
    BENCH = [TRACE_OFF].freeze
    # A word as a line holds it: printable ASCII with no space, since the line splits on
    # spaces alone and a board's cmdline.txt must stay one line.
    WORD = /\A[!-~]+\z/

    module_function

    # A benchmark boot's words: BENCH, then the caller's words (bench --kernel-words),
    # each of which replaces the BENCH word of the same option, so erx.trace=1 measures
    # the rings' own cost and the line states it once. A word that is not WORD is refused.
    def bench(words = [])
      odd = words.reject { |word| WORD.match?(word) }
      raise Error, "bench: --kernel-words: #{odd.first.inspect} is not one word of a kernel command line" unless odd.empty?

      named = words.map { |word| option(word) }
      [*BENCH.reject { |word| named.include?(option(word)) }, *words].freeze
    end

    # A benchmark boot's kernel command line: base, the line the boot takes without them
    # (nil or empty for none), then bench's words for words.
    def bench_line(base = nil, words = []) = [base, *bench(words)].compact.reject(&:empty?).join(' ').freeze

    # Raises unless every space-separated word of line is WORD: a line read back from a
    # board set's cmdline.txt (BoardRecord) holds kernel words and nothing else.
    def check_line(line, label:)
      raise Error, "#{label}: #{line.inspect} is not a line of kernel words" unless line.split(/ /).all? { |word| WORD.match?(word) }

      line
    end

    # The option a word sets: the text before its first '='.
    def option(word) = word.partition('=').first
  end
end
