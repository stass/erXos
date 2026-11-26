# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/native_machine_stop'

# The native_machine_stop judge's hold on the record's trace tail (docs/design-debugger.md,
# "The record's trace tail"): each written ring gives the newest of its records up to an
# equal share, so a CPU's count follows from what its ring held, not from a fixed number.
# Each seeded tail below is what a broken writer gives, and the judge must name its CPU.
class NativeMachineStopTest < Minitest::Test
  M = Erx::NativeMachineStop
  STOPPED = %w[stopped stopped leader stopped].freeze
  UPTIME = 3_000_000_000

  # A record holding, for each CPU, the ring indices given, oldest first.
  def record(indices, time_ns: 1000)
    trace = indices.flat_map do |cpu, list|
      list.map { |index| { 'cpu' => cpu, 'seq' => 2 * index + 2, 'time_ns' => time_ns } }
    end
    { 'trace' => trace, 'uptime_ns' => UPTIME }
  end

  def test_short_and_empty_rings_give_what_they_held
    assert_empty M.trace_problems(record({ 0 => [0, 1] }), STOPPED)
    assert_empty M.trace_problems(record({ 0 => [0, 1, 2], 2 => (40..55).to_a }), STOPPED)
  end

  def test_four_full_rings_give_a_share_of_eight_each
    assert_empty M.trace_problems(record((0..3).to_h { |cpu| [cpu, (100..107).to_a] }), STOPPED)
  end

  def test_a_cpu_that_did_not_answer_may_have_lost_records
    states = %w[stopped stopped leader unanswered]
    assert_empty M.trace_problems(record({ 0 => (10..25).to_a, 3 => [12, 14] }), states)
  end

  # name => [the tail a broken writer gives, the CPU the judge must name]
  SEEDS = {
    'a share one short of a full ring' => [{ 0 => (101..107).to_a, **(1..3).to_h { |cpu| [cpu, (100..107).to_a] } }, 0],
    'a record skipped from a quiet ring' => [{ 0 => [0, 1, 3] }, 0],
    'more than a share' => [{ 0 => (0..8).to_a, 1 => (0..23).to_a }, 1]
  }.freeze

  SEEDS.each do |name, (indices, cpu)|
    define_method("test_seed_#{name.tr(' ', '_')}") do
      problems = M.trace_problems(record(indices), STOPPED)
      assert(problems.any? { |line| line.start_with?("trace of cpu #{cpu} ") }, "#{name}: #{problems}")
    end
  end

  def test_a_tail_the_writer_skipped_is_named
    assert_equal ['trace empty'], M.trace_problems(record({}), STOPPED)
  end

  def test_a_record_newer_than_the_stop_is_named
    assert_includes M.trace_problems(record({ 0 => [0] }, time_ns: UPTIME + 1), STOPPED), '1 trace records newer than the stop'
  end
end
