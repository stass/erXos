# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_pl011_tests.erl, the EUnit cases of the console_uart parse and of
# program/1's register steps, against erx_pl011 compiled from source with the rest of its
# application on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies), as it
# is and with each seeded fault of docs/design-bluetooth.md's program/1 row, where the
# named case must fail. The module's calls into erx_device and erx_irq_line reach their
# stand-ins, so it needs no hosted build.
class ErxPl011Test < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application, compiled whole (ErlangBuild), the stand-ins for the device NIF the
  # receive cases script or play (test/erlang/stand_in/erx_device.erl) and for the
  # interrupt line the played driver attaches, and the suite.
  APPLICATIONS = %w[erx_uart].freeze
  TESTS = %w[test/erlang/stand_in/erx_device.erl test/erlang/stand_in/erx_irq_line.erl
             test/erlang/erx_pl011_tests.erl].freeze
  PL011 = 'erlang/apps/erx_uart/src/erx_pl011.erl'
  # A fresh start's divisor writes and the LCR_H write that latches them.
  DIVISORS = "     {write, ibrd, ?ERX_HW_PL011_IBRD_BAUD_DIVINT_PUT(Integer)},\n" \
             "     {write, fbrd, ?ERX_HW_PL011_FBRD_BAUD_DIVFRAC_PUT(Fraction)},\n"
  LCR_H = "     {write, lcr_h, ?ERX_HW_PL011_LCR_H_WLEN_PUT(?WLEN_8) bor ?ERX_HW_PL011_LCR_H_FEN_PUT(1)},\n"

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'LCR_H written before the divisors, so the rate never latches',
             anchor: DIVISORS + LCR_H,
             replacement: LCR_H + DIVISORS,
             catching_case: 'fresh_without_flow_test'),
    Seed.new(fault: "a fresh start keeping the boot's divisors",
             anchor: DIVISORS,
             replacement: "     {default_divisors, Integer, Fraction},\n",
             catching_case: 'fresh_without_flow_test'),
    Seed.new(fault: 'RTS set under flow none, so the controller powers up in download mode',
             anchor: "flow_enables(none) ->\n    0;\n",
             replacement: "flow_enables(none) ->\n    ?ERX_HW_PL011_CR_RTS_PUT(1);\n",
             catching_case: 'fresh_without_flow_test'),
    Seed.new(fault: 'the loss sent after the byte whose word has OE set',
             anchor: '{mark, 1} -> [lost, Byte];',
             replacement: '{mark, 1} -> [Byte, lost];',
             catching_case: 'overrun_is_placed_before_the_byte_after_the_loss_test'),
    Seed.new(fault: 'the drain reading past two FIFO depths',
             anchor: 'drain(Dev, OnOverrun, ?DRAIN_WORDS, []).',
             replacement: 'drain(Dev, OnOverrun, 2 * ?DRAIN_WORDS, []).',
             catching_case: 'a_wedged_receive_is_drained_a_bounded_amount_test'),
    Seed.new(fault: 'a drain stopped at its bound left for an interrupt that never comes',
             anchor: "        true -> 0;\n",
             replacement: "        true -> infinity;\n",
             catching_case: 'a_drain_stopped_at_its_bound_is_continued_without_an_interrupt_test'),
    Seed.new(fault: 'a continued drain acknowledging the line, which delivered nothing',
             anchor: "        true -> deliver_input(S);\n",
             replacement: "        true -> take_input(S);\n",
             catching_case: 'a_drain_stopped_at_its_bound_is_continued_without_an_interrupt_test'),
    Seed.new(fault: "the console's stopped drain continued into a store without room",
             anchor: 'continues(#driver{rx = stopped, input = Input}) -> erx_uart_input:room(Input) >= ?DRAIN_WORDS;',
             replacement: 'continues(#driver{rx = stopped}) -> true;',
             catching_case: 'a_console_s_stopped_drain_waits_for_room_test')
  ].freeze

  def test_console_uart_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, PL011))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ PL011 => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    Dir.mktmpdir('erx-pl011-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_pl011_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
