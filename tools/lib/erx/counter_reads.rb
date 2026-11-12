# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The one read of the timer's counter in a linked erXos program for the
  # Fiasco backend (docs/design-arch-aarch64.md, "Timer"). A read of the
  # counter is ordered against the code around it only by an ISB on each
  # side, and the pipe's write order (docs/design-pipes.md, PI6) depends on
  # both, so a read without either one is a bug no test reliably shows. The
  # check reads the program's disassembly and refuses every instruction that
  # names a counter register, under any of its names, outside
  # erx_fiasco_counter, and every one in it whose neighbours in the same
  # function are not both an ISB. A read before the first symbol is refused
  # as outside the function, and an empty listing, or one that disassembles
  # no section, is refused whole, so a disassembler that printed nothing
  # never passes. What the disassembler prints as data (a `.word` in
  # hand-written assembly) is not seen; the one-erx-trap chokepoint keeps
  # raw instruction words out of erXos's C.
  module CounterReads
    FUNCTION = 'erx_fiasco_counter'
    # The physical and virtual counters and their self-synchronised views
    # (FEAT_ECV), by name and as the generic S3_3_C14_C0_<op2> encoding.
    COUNTER = /\b(?:cnt[pv]ct(?:ss)?_el0|s3_3_c14_c0_[1256])\b/i
    SECTION = /\ADisassembly of section /
    SYMBOL = /\A\h+ <(?<name>.+)>:\s*\z/
    INSTRUCTION = /\A\s*(?<address>\h+):\s+(?<mnemonic>\S+)\s*(?<operands>.*?)\s*\z/
    NO_SECTION = 'the listing disassembles no section'
    MAX_FINDINGS = 64
    MAX_LISTING_BYTES = 1 << 30

    Instruction = Data.define(:symbol, :address, :mnemonic, :operands)

    module_function

    # The violations in lines, the output of `llvm-objdump -d
    # --no-show-raw-insn`: the file and section headers, then a symbol line
    # `ADDRESS <NAME>:` before each function's instructions, one
    # `ADDRESS: MNEMONIC OPERANDS` per instruction. Each run of lines from
    # one symbol line to the next is one function; the first run, before any
    # symbol line, holds the section header and no function. Lines are read
    # as bytes, so text that is not UTF-8 is matched, not raised on. Lazy, so
    # a listing of tens of megabytes is read once and never held whole. At
    # most MAX_FINDINGS are returned.
    def violations(lines)
      lines.lazy.map(&:b).slice_before(SYMBOL).with_index.flat_map do |run, index|
        headerless = index.zero? && run.none? { |line| SECTION.match?(line) }
        [*(headerless ? [NO_SECTION] : []), *refusals(function(run))]
      end.first(MAX_FINDINGS)
    end

    # The effect: disassembles program with llvm-objdump into a listing
    # beside it and refuses it on any violation. The listing stays only when
    # the check fails, for the diagnosis.
    def check(program:, objdump:, runner:)
      listing = "#{program}.counter-reads.txt"
      runner.run([objdump, '-d', '--no-show-raw-insn', program], name: "counter-reads-#{File.basename(program)}",
                                                                   deadline: 120, stdout: listing,
                                                                   output_limit: MAX_LISTING_BYTES)
      refused = File.open(listing, 'rb') { |file| violations(file.each_line) }
      refused = [NO_SECTION] if File.zero?(listing)
      unless refused.empty?
        shown = refused.size == MAX_FINDINGS ? " (the first #{MAX_FINDINGS})" : ''
        raise Error, "counter reads in #{program}#{shown} (listing: #{listing}):\n#{refused.join("\n")}"
      end

      File.delete(listing)
    end

    # One run of lines: its symbol, from its first line when that is a
    # symbol line, and its instructions.
    def function(run)
      symbol = SYMBOL.match(run.first)&.[](:name)
      run.filter_map do |line|
        found = INSTRUCTION.match(line)
        found && Instruction.new(symbol: symbol, address: found[:address], mnemonic: found[:mnemonic].downcase,
                                 operands: found[:operands])
      end
    end

    # Each instruction of one function seen with its neighbours, the
    # function's ends standing as nil.
    def refusals(body) = [nil, *body, nil].each_cons(3).filter_map { |window| refusal(*window) }

    def refusal(before, instruction, after)
      return nil unless COUNTER.match?(instruction.operands)

      where = "#{instruction.address} <#{instruction.symbol || '?'}>: #{instruction.mnemonic} #{instruction.operands}"
      return "#{where}: reads the counter outside #{FUNCTION}" unless instruction.symbol == FUNCTION
      return "#{where}: no ISB right before the read" unless isb?(before)
      return "#{where}: no ISB right after the read" unless isb?(after)

      nil
    end

    def isb?(instruction) = !instruction.nil? && instruction.mnemonic == 'isb'

    private_class_method :function, :refusals, :refusal, :isb?
  end
end
