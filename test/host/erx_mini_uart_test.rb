# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_mini_uart_tests.erl, the EUnit cases of the mini UART driver's
# receive decisions, and each seeded fault of docs/design-live.md against its case, with erx_mini_uart compiled from source with the rest of its
# application on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). The
# driver's register and interrupt calls reach the stand-ins of erx_device and erx_irq_line,
# through which the order case plays the device.
class ErxMiniUartTest < Minitest::Test
  APPLICATIONS = %w[erx_uart].freeze
  TESTS = %w[test/erlang/stand_in/erx_device.erl test/erlang/stand_in/erx_irq_line.erl
             test/erlang/erx_mini_uart_tests.erl].freeze
  DRIVER = 'erlang/apps/erx_uart/src/erx_mini_uart.erl'
  STORE = 'erlang/apps/erx_uart/src/erx_uart_input.erl'

  Seed = Data.define(:fault, :file, :anchor, :replacement, :catching_case)

  # The faults docs/design-live.md's verification table seeds for the driver, each with the
  # case that must fail on it.
  SEEDS = [
    Seed.new(fault: 'the loss placed after eight bytes, as if no byte had been read since the previous LSR',
             file: DRIVER, anchor: 'Count = ?FIFO_BYTES - Read,', replacement: 'Count = ?FIFO_BYTES + 0 * Read,',
             catching_case: 'overrun_after_a_data_read_is_placed_one_byte_sooner_test'),
    Seed.new(fault: "the loss placed after seven bytes when a send's poll shows the overrun",
             file: DRIVER, anchor: 'Count = ?FIFO_BYTES - Read,', replacement: 'Count = ?FIFO_BYTES - 1 + 0 * Read,',
             catching_case: 'overrun_seen_by_a_send_is_marked_test'),
    Seed.new(fault: 'the drain reading past four FIFO depths',
             file: DRIVER, anchor: 'drain(S, Units, ?DRAIN_MAX) ->', replacement: 'drain(S, Units, 64) ->',
             catching_case: 'wedged_receive_is_drained_a_bounded_amount_test'),
    Seed.new(fault: 'the driver sending a message per drain without waiting for its answer',
             file: STORE, anchor: "next(I = #input{waiting = true}) ->\n    {none, I};\n", replacement: '',
             catching_case: 'a_stalled_console_holds_one_message_and_one_drain_test')
  ].freeze

  def test_receive_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.file))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.file => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      # A warning the driver logs can come between the case name and its verdict.
      assert_match(/#{Regexp.escape(seed.catching_case)}\.\.\.(?:(?!\n  erx_mini_uart_tests:).)*\*failed\*/m, output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    Dir.mktmpdir('erx-mini-uart-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_mini_uart_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
