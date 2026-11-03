# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/a64_branch'
require_relative '../../tools/lib/erx/runner'

# Pins the decoder's classification of hand-picked words, then checks it
# against llvm-objdump, the independent reading, over random words of the
# branch group and of the whole encoding space: every control-flow kind the
# decoder reports must be the instruction objdump prints, with the same
# target, and no word the decoder calls :plain may be one objdump reads as
# control flow.
class A64BranchTest < Minitest::Test
  SEED = Integer(ENV.fetch('ERX_A64_BRANCH_SEED', '20261102'))
  # Every mnemonic of the A64 branch, exception-generation and
  # transactional-memory classes that can move the program counter.
  CONTROL_FLOW = /\A(?:b|bl|bc?\.[a-z]{2}|cbn?z|cbb?h?[a-z]{2}|tbn?z|br(?:a[ab]z?)?|blr(?:a[ab]z?)?|
                    ret(?:a[ab][a-z]*)?|eret(?:a[ab])?|svc|hvc|smc|brk|hlt|dcps[123]|drps|tstart)\z/x
  RELATIVE = %i[jump call conditional].freeze

  def decode(word) = Erx::A64Branch.decode(word)

  def test_hand_picked_words
    {
      0x1400_0001 => [:jump, 4], 0x17ff_ffff => [:jump, -4], 0x9400_0000 => [:call, 0],
      0x97ff_fff1 => [:call, -60], 0x5400_0ae1 => [:conditional, 348], 0x5400_0010 => [:conditional, 0],
      0x3500_00a8 => [:conditional, 20], 0xb4ff_ffe0 => [:conditional, -4], 0x3600_0040 => [:conditional, 8],
      0xb7ff_ffe0 => [:conditional, -4]
    }.each do |word, (kind, delta)|
      assert_equal [kind, delta], [decode(word).kind, decode(word).delta], format('%08x', word)
    end
    assert_equal [:indirect_jump, 2], [decode(0xd61f_0040).kind, decode(0xd61f_0040).register]
    assert_equal [:indirect_call, 8], [decode(0xd63f_0100).kind, decode(0xd63f_0100).register]
    assert_equal :return, decode(0xd65f_03c0).kind
    assert_equal :trap, decode(0xd420_0020).kind
    { nop: 0xd503_201f, paciasp: 0xd503_233f, dsb: 0xd503_3f9f, msr_daifset: 0xd503_43df,
      mrs: 0xd538_1000, tlbi: 0xd508_871f, sub: 0xd100_43ff, ldr: 0xf940_0000 }.each do |name, word|
      assert_equal :plain, decode(word).kind, name.to_s
    end
    { eret: 0xd69f_03e0, retaa: 0xd65f_0bff, braa: 0xd71f_0820, svc: 0xd400_0001, hvc: 0xd400_0002,
      udf: 0x0000_0000, tstart: 0xd523_3060, tcommit: 0xd503_307f, unallocated: 0x0200_0000,
      ret_x1: 0xd65f_0020 }.each do |name, word|
      assert_equal :unknown, decode(word).kind, name.to_s
    end
  end

  def test_mnemonics_must_agree_with_the_decoded_kind
    assert Erx::A64Branch.mnemonic_agrees?(decode(0x9400_0000), 'bl')
    refute Erx::A64Branch.mnemonic_agrees?(decode(0x9400_0000), 'b')
    assert Erx::A64Branch.mnemonic_agrees?(decode(0xd100_43ff), 'sub')
    refute Erx::A64Branch.mnemonic_agrees?(decode(0xd100_43ff), 'bl')
    refute Erx::A64Branch.mnemonic_agrees?(decode(0xd100_43ff), '<unknown>')
    refute Erx::A64Branch.mnemonic_agrees?(decode(0xd100_43ff), '.word')
    refute Erx::A64Branch.mnemonic_agrees?(decode(0xd69f_03e0), 'eret')
  end

  def test_words_outside_32_bits_are_rejected
    assert_raises(ArgumentError) { decode(1 << 32) }
    assert_raises(ArgumentError) { decode(-1) }
  end

  def test_decoder_agrees_with_objdump
    compiler = ENV.fetch('ERX_CLANG', '')
    skip 'ERX_CLANG is not set: the comparison needs the LLVM 23 clang and llvm-objdump' if compiler.empty?

    rng = Random.new(SEED)
    branch_group = Array.new(8192) { (rng.rand(1 << 32) & ~0x1c00_0000) | 0x1400_0000 }
    words = branch_group + Array.new(8192) { rng.rand(1 << 32) }
    listing = disassemble(words, compiler: compiler)
    assert_equal words.length, listing.length
    disagreements = words.zip(listing).each_with_index.filter_map do |(word, (mnemonic, operands)), index|
      problem = disagreement(word, mnemonic, operands, address: index * 4)
      format('%08x %s %s: %s', word, mnemonic, operands, problem) if problem
    end
    assert_empty disagreements.first(10)
    assert_operator words.count { |word| RELATIVE.include?(decode(word).kind) }, :>, 1000
  end

  private

  def disagreement(word, mnemonic, operands, address:)
    decoded = decode(word)
    case decoded.kind
    when :unknown then nil
    when :plain then 'decoded as plain' if CONTROL_FLOW.match?(mnemonic)
    else
      return "decoded as #{decoded.kind}" unless Erx::A64Branch.mnemonic_agrees?(decoded, mnemonic)
      return nil unless RELATIVE.include?(decoded.kind)

      target = operands[/(0x[0-9a-f]+) <[^>]*>\z/, 1]
      expected = (address + decoded.delta) & ((1 << 64) - 1)
      "target #{target}, decoded 0x#{expected.to_s(16)}" unless target && Integer(target, 16) == expected
    end
  end

  # The mnemonic and operands objdump prints for each word, in order.
  def disassemble(words, compiler:)
    Dir.mktmpdir('erx-a64-branch-') do |directory|
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
      source = File.join(directory, 'words.s')
      object = File.join(directory, 'words.o')
      File.write(source, ".text\n.globl words\nwords:\n" + words.map { |word| format(".inst 0x%08x\n", word) }.join)
      runner.run([compiler, '--target=aarch64-none-elf', '-c', source, '-o', object],
                 name: 'assemble-words', deadline: 60)
      objdump = File.join(File.dirname(File.realpath(compiler)), 'llvm-objdump')
      record = runner.run([objdump, '-d', '-z', '--no-show-raw-insn', object], name: 'disassemble-words', deadline: 60)
      File.read(record.fetch('log')).lines.filter_map do |line|
        match = /\A *[0-9a-f]+: +\t(\S+)(?:\t(.*?))?(?: +\/\/.*)?\n\z/.match(line)
        [match[1], match[2].to_s] if match
      end
    end
  end
end
