# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/counter_reads'

# The check that every read of the timer's counter in a linked program is
# erx_fiasco_counter's, between two ISBs, fed llvm-objdump listings in the
# form `llvm-objdump -d --no-show-raw-insn` prints, with the seeded faults
# it exists for: a dropped ISB on either side, and a read elsewhere.
class CounterReadsTest < Minitest::Test
  M = Erx::CounterReads

  HEADER = <<~TEXT

    stopgap-root:\tfile format elf64-littleaarch64

    Disassembly of section .text:

  TEXT

  def listing(*functions) = (HEADER + functions.join("\n")).lines

  def function(name, *instructions, at: 0x4c0d28a0)
    lines = instructions.each_with_index.map { |text, index| format("%<address>x:      \t%<text>s\n", address: at + (4 * index), text: text) }
    format("%<address>016x <%<name>s>:\n", address: at, name: name) + lines.join
  end

  # erx_fiasco_counter as the fixed clock.c compiles, and its caller.
  COUNTER = ["isb", "mrs\tx0, CNTVCT_EL0", "isb", 'ret'].freeze
  CALLER = ["stp\tx29, x30, [sp, #-0x10]!", "mrs\tx8, CNTFRQ_EL0", "bl\t0x4c0d28a0 <erx_fiasco_counter>", 'ret'].freeze

  def test_the_one_read_between_two_isbs_passes
    assert_empty M.violations(listing(function('erx_fiasco_counter', *COUNTER), function('erx_fiasco_clock_ns', *CALLER, at: 0x4c0d28b0)))
  end

  def test_a_program_without_a_read_passes
    assert_empty M.violations(listing(function('main', "mov\tw0, #0x0", 'ret')))
  end

  def test_a_dropped_trailing_isb_is_refused
    refused = M.violations(listing(function('erx_fiasco_counter', 'isb', "mrs\tx0, CNTVCT_EL0", 'ret')))
    assert_equal ['4c0d28a4 <erx_fiasco_counter>: mrs x0, CNTVCT_EL0: no ISB right after the read'], refused
  end

  def test_a_dropped_leading_isb_is_refused
    refused = M.violations(listing(function('erx_fiasco_counter', "mrs\tx0, CNTVCT_EL0", 'isb', 'ret')))
    assert_equal ['4c0d28a0 <erx_fiasco_counter>: mrs x0, CNTVCT_EL0: no ISB right before the read'], refused
  end

  # A read last in its function has no ISB after it, whatever the next
  # function begins with.
  def test_an_isb_in_the_next_function_does_not_count
    refused = M.violations(listing(function('erx_fiasco_counter', 'isb', "mrs\tx0, CNTVCT_EL0"),
                                   function('next', 'isb', 'ret', at: 0x4c0d28a8)))
    assert_equal ['4c0d28a4 <erx_fiasco_counter>: mrs x0, CNTVCT_EL0: no ISB right after the read'], refused
  end

  # The inlined read the check exists to keep out: a caller with its own
  # copy, even between ISBs.
  def test_a_read_outside_the_clock_function_is_refused
    refused = M.violations(listing(function('erx_fiasco_clock_ns', "mrs\tx8, CNTFRQ_EL0", 'isb', "mrs\tx9, CNTVCT_EL0", 'isb')))
    assert_equal ['4c0d28a8 <erx_fiasco_clock_ns>: mrs x9, CNTVCT_EL0: reads the counter outside erx_fiasco_counter'], refused
  end

  def test_every_name_of_a_counter_is_a_read
    ["mrs\tx1, CNTPCT_EL0", "mrs\tx1, cntvctss_el0", "mrs\tx1, CNTPCTSS_EL0", "mrs\tx1, S3_3_C14_C0_2", "mrs\tx1, s3_3_c14_c0_6"].each do |read|
      refused = M.violations(listing(function('elsewhere', read, 'ret')))
      assert_equal 1, refused.size, read
    end
  end

  def test_the_frequency_and_the_timer_registers_are_not_reads
    assert_empty M.violations(listing(function('f', "mrs\tx0, CNTFRQ_EL0", "mrs\tx1, S3_3_C14_C0_0", "mrs\tx2, CNTV_CTL_EL0", 'ret')))
  end

  # Lines in the shapes llvm-objdump prints besides instructions: a run of
  # zeros elided, data with its raw bytes kept, and a section's own symbol.
  def test_the_other_line_shapes_of_a_real_listing_pass
    lines = listing(function('erx_fiasco_counter', *COUNTER), "\t\t...\n",
                    "0000000000000008 <.text>:\n       8: 40 e0 3b d5  \t.word\t0xd53be040\n")
    assert_empty M.violations(lines)
  end

  def test_a_listing_without_a_section_is_refused
    assert_equal ['the listing disassembles no section'], M.violations(["stopgap-root:\tfile format elf64-littleaarch64\n"])
  end

  def test_bytes_that_are_not_utf8_are_read_not_raised_on
    lines = listing(function("f\xff", "mrs\tx0, CNTVCT_EL0".b))
    assert_equal 1, M.violations(lines.map(&:b)).size
  end

  # The effect, with a runner that writes the listing objdump would.
  class Runner
    def initialize(text) = @text = text

    def run(argv, stdout:, **)
      File.binwrite(stdout, @text)
      { 'argv' => argv }
    end
  end

  def checked(text)
    Dir.mktmpdir do |directory|
      program = File.join(directory, 'stopgap-root')
      error = begin
        M.check(program: program, objdump: 'llvm-objdump', runner: Runner.new(text))
        nil
      rescue Erx::Error => e
        e
      end
      yield error, File.exist?("#{program}.counter-reads.txt")
    end
  end

  def test_check_passes_and_deletes_the_listing
    checked(listing(function('erx_fiasco_counter', *COUNTER)).join) do |error, kept|
      assert_nil error
      refute kept
    end
  end

  def test_check_refuses_and_keeps_the_listing
    checked(listing(function('erx_fiasco_counter', 'isb', "mrs\tx0, CNTVCT_EL0", 'ret')).join) do |error, kept|
      assert_match(/no ISB right after the read/, error.message)
      assert kept
    end
  end

  def test_check_refuses_an_empty_listing
    checked('') { |error, _| assert_match(/disassembles no section/, error.message) }
  end

  def test_a_read_before_any_symbol_is_refused
    refused = M.violations((HEADER + "4c0d28a0:      \tmrs\tx0, CNTVCT_EL0\n").lines)
    assert_equal ['4c0d28a0 <?>: mrs x0, CNTVCT_EL0: reads the counter outside erx_fiasco_counter'], refused
  end
end
