# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # Classifies one A64 instruction word by whether and how it moves the
  # program counter, for the stack proof's call graph
  # (docs/design-arch-aarch64.md#stack-proof). Only the encoding group
  # "branches, exception generation and system instructions" changes the
  # program counter; every word of that group is either one of the forms
  # named below or :unknown, so a new control-flow instruction can never
  # pass as ordinary code. Words of the reserved and unallocated top-level
  # groups are :unknown too. Every other group (data processing, loads and
  # stores, SIMD and floating point, SVE) cannot write the program counter
  # and is :plain.
  #
  # Kinds:
  #   :plain          falls through to the next instruction
  #   :jump           B: delta is the byte offset of the target
  #   :call           BL: delta as for :jump
  #   :conditional    B.cond, BC.cond, CBZ, CBNZ, TBZ, TBNZ: delta as for :jump
  #   :indirect_jump  BR: register is the target register
  #   :indirect_call  BLR: register as for :indirect_jump
  #   :return         RET
  #   :trap           BRK, which ends the path in a debug exception
  #   :unknown        anything the proof cannot account for
  module A64Branch
    Decoded = Data.define(:kind, :delta, :register)

    # The mnemonics llvm-objdump prints for each kind, so the disassembler's
    # reading and this decoder's must agree before a word is classified.
    MNEMONICS = {
      jump: /\Ab\z/, call: /\Abl\z/,
      conditional: /\A(?:bc?\.[a-z]{2}|cbn?z|tbn?z)\z/,
      indirect_jump: /\Abr\z/, indirect_call: /\Ablr\z/, return: /\Aret\z/, trap: /\Abrk\z/
    }.freeze

    module_function

    def decode(word)
      raise ArgumentError, 'instruction word must be a 32-bit integer' unless word.is_a?(Integer) && word.between?(0, 0xffff_ffff)

      case (word >> 25) & 0xf
      when 0b0000, 0b0001, 0b0011 then unknown
      when 0b1010, 0b1011 then branch_group(word)
      else plain
      end
    end

    # The mnemonic objdump printed is consistent with the decoded kind: the
    # kind's own mnemonic for a control-flow kind, and an instruction
    # mnemonic that names no control flow for a :plain word, so objdump's
    # "<unknown>" and data directives such as ".word" never pass.
    def mnemonic_agrees?(decoded, mnemonic)
      case decoded.kind
      when :plain
        /\A[a-z][a-z0-9.]*\z/.match?(mnemonic) && MNEMONICS.each_value.none? { |pattern| pattern.match?(mnemonic) }
      when :unknown then false
      else MNEMONICS.fetch(decoded.kind).match?(mnemonic)
      end
    end

    # The immediate branches, each with its field layout from the Arm ARM's
    # "Branches, Exception Generating and System instructions" class.
    def branch_group(word)
      # B and BL: bits 30:26 = 00101, bit 31 = link, imm26 at 25:0.
      if (word & 0x7c00_0000) == 0x1400_0000
        relative(word[31] == 1 ? :call : :jump, word & 0x03ff_ffff, bits: 26)
      # B.cond and BC.cond: bits 31:24 = 01010100, imm19 at 23:5, bit 4
      # chooses BC, cond at 3:0.
      elsif (word & 0xff00_0000) == 0x5400_0000
        relative(:conditional, (word >> 5) & 0x7_ffff, bits: 19)
      # CBZ and CBNZ: bits 30:25 = 011010, bit 24 = NZ, imm19 at 23:5; the
      # immediate sits where B.cond's does.
      elsif (word & 0x7e00_0000) == 0x3400_0000
        relative(:conditional, (word >> 5) & 0x7_ffff, bits: 19)
      # TBZ and TBNZ: bits 30:25 = 011011, bit number at 31 and 23:19,
      # imm14 at 18:5.
      elsif (word & 0x7e00_0000) == 0x3600_0000
        relative(:conditional, (word >> 5) & 0x3fff, bits: 14)
      else
        register_or_system(word)
      end
    end

    # BR, BLR and RET without pointer authentication: bits 31:25 = 1101011,
    # opc at 24:21, op2 = 11111, op3 = 000000, Rn at 9:5, op4 = 00000. A RET
    # through any register but x30 is a computed jump the graph cannot
    # follow as a return, so it is :unknown.
    def register_or_system(word)
      register = (word >> 5) & 0x1f
      case word & 0xffff_fc1f
      when 0xd61f_0000 then Decoded.new(kind: :indirect_jump, delta: nil, register: register)
      when 0xd63f_0000 then Decoded.new(kind: :indirect_call, delta: nil, register: register)
      when 0xd65f_0000 then register == 30 ? Decoded.new(kind: :return, delta: nil, register: 30) : unknown
      else
        if (word & 0xffe0_001f) == 0xd420_0000
          Decoded.new(kind: :trap, delta: nil, register: nil)
        elsif system?(word)
          plain
        else
          unknown
        end
      end
    end

    # Hints (NOP, BTI, the pointer-authentication hints), barriers, MSR with
    # an immediate, MSR and MRS of a system register, and SYS and SYSL (cache
    # and TLB maintenance) all fall through. The rest of the system class,
    # transactional memory among it (TCOMMIT shares the barriers' encoding
    # space and is excluded by its exact word), is :unknown.
    TCOMMIT = 0xd503_307f

    def system?(word)
      (word & 0xffff_f01f) == 0xd503_201f ||
        ((word & 0xffff_f01f) == 0xd503_301f && word != TCOMMIT) ||
        (word & 0xfff8_f01f) == 0xd500_401f ||
        (word & 0xffd0_0000) == 0xd510_0000 ||
        (word & 0xffd8_0000) == 0xd508_0000
    end

    def relative(kind, field, bits:)
      offset = field[bits - 1] == 1 ? field - (1 << bits) : field
      Decoded.new(kind: kind, delta: offset * 4, register: nil)
    end

    def plain = Decoded.new(kind: :plain, delta: nil, register: nil)
    def unknown = Decoded.new(kind: :unknown, delta: nil, register: nil)

    private_class_method :branch_group, :register_or_system, :system?, :relative, :plain, :unknown
  end
end
