# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../tools/fuzz/bench_line'

# The CLOCK line validator (docs/design-bench.md, "A benchmark"): a guest's calibration,
# one line per boot, becomes the record's clock group only when every field has its type
# and bound; a refusal names the field and never quotes the line.
class BenchClockLineTest < Minitest::Test
  Fuzz = Erx::BenchLineFuzz

  def refusal(text)
    Erx::BenchMeasurement.clock(text)
    flunk 'accepted'
  rescue Erx::Error => e
    e.message
  end

  def test_a_guests_calibration_is_the_clock_group
    clock = Erx::BenchMeasurement.clock(Fuzz.clock_line)
    assert_equal 24_000_000, clock.fetch('frequency_hz')
    assert_equal [[0, 1]], clock.fetch('pairs').map { |pair| pair.fetch('cpus') }
    assert clock.frozen?
    assert clock.fetch('pairs').first.fetch('before').frozen?
  end

  def test_cycles_per_tick_is_a_number_or_unknown
    assert_equal ['unknown', 27.778],
                 ['unknown', 27.778].map { |cycles| Erx::BenchMeasurement.clock(Fuzz.clock_line(cycles_per_tick: cycles)).fetch('cycles_per_tick') }
    assert_match(/\ACLOCK line /, refusal(Fuzz.clock_line(cycles_per_tick: 0)))
  end

  def test_a_contradicted_interval_is_null_and_kept
    pairs = [{ 'cpus' => [0, 1], 'before' => nil, 'after' => [-3, 4] }]
    assert_nil Erx::BenchMeasurement.clock(Fuzz.clock_line(pairs: pairs)).fetch('pairs').first.fetch('before')
  end

  def test_fields_out_of_type_or_bound_are_refused
    {
      { clock: 'host' } => /clock is not a guest clock/,
      { frequency_hz: 0 } => /frequency_hz is not a frequency/,
      { increment: 0 } => /increment is not a positive tick count/,
      { read_cost: -1 } => /read_cost is not a tick count/,
      { wait_rounding: 1.5 } => /wait_rounding is not a tick count/,
      { pairs: [{ 'cpus' => [1, 1], 'before' => [0, 1], 'after' => [0, 1] }] } => /not two CPUs, lower first/,
      { pairs: [{ 'cpus' => [0, 1], 'before' => [2, 1], 'after' => [0, 1] }] } => /lowest and highest offset/,
      { pairs: [{ 'cpus' => [0, 1], 'before' => [0, 1 << 63], 'after' => [0, 1] }] } => /lowest and highest offset/,
      { pairs: [{ 'cpus' => [0, 1], 'before' => [0, 1] }] } => /cpus, before and after/,
      { pairs: [{ 'cpus' => [0, 1], 'before' => [0, 1], 'after' => [0, 1] }] * 2 } => /one pair twice/,
      { extra: 1 } => /unknown field/,
      { pairs: [{ 'cpus' => [1, 0], 'before' => [0, 1], 'after' => [0, 1] }] } => /lower first/,
      { cycles_per_tick: 0 } => /cycles_per_tick is not a positive number or unknown/,
      { cycles_per_tick: 'many' } => /cycles_per_tick is not a positive number or unknown/,
      { cycles_per_tick: 1001 } => /cycles_per_tick is not a positive number or unknown/
    }.each do |override, reason|
      assert_match(reason, refusal(Fuzz.clock_line(**override)), override.inspect)
    end
  end

  def test_a_line_that_is_not_a_clock_line_is_refused_without_quoting_it
    assert_match(/does not begin with CLOCK/, refusal(Fuzz.line('wake-same-cpu')))
    assert_match(/backslash/, refusal('CLOCK {"clock":"\u001b[31m"}'))
    refute_includes refusal(Fuzz.clock_line(clock: 'zz-secret')), 'zz-secret'
  end

  # docs/design-bench.md, "The one clock": a POSIX guest's CLOCK_MONOTONIC ticks in
  # nanoseconds, so its CLOCK line says so or is refused.
  def test_a_monotonic_clock_ticks_in_nanoseconds
    line = Fuzz.clock_line(clock: 'monotonic', frequency_hz: 1_000_000_000)
    assert_equal 'monotonic', Erx::BenchMeasurement.clock(line).fetch('clock')
    assert_match(/frequency_hz/, refusal(Fuzz.clock_line(clock: 'monotonic')))
    assert_match(/guest clock/, refusal(Fuzz.clock_line(clock: 'cycles')))
  end
end
