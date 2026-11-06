# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/bench_g3'
require_relative '../../tools/lib/erx/bench_guest'

class BenchGuestTest < Minitest::Test
  PLAN = Erx::BenchGuest::PLANS.fetch('tcg')
  BEAM = (0..999).map { |value| value % 256 }.pack('C*')

  def test_the_transcript_is_one_the_harness_accepts_and_types_in_order
    points = Erx::BenchGuest.checkpoints(beam: BEAM, plan: PLAN)
    Erx::Transcript.new(checkpoints: points)
    typed = points.filter_map { |point| point[:type] }
    assert_equal Erx::BenchGuest::FOOTPRINT_EXPRESSION + "\r", typed.first
    assert_equal 4, typed.count { |line| line.include?('erx_otp_bench:run(') }
    assert_equal 'workload-switch', points.last.fetch(:name)
    refute points.last.key?(:type)
  end

  def test_the_beam_travels_in_bounded_lines_that_join_back_to_it
    lines = Erx::BenchGuest.load_lines(BEAM)
    assert_equal 4, lines.size - 1
    assert(lines.all? { |line| line.bytesize < Erx::BenchGuest::CHUNK_BYTES * 4 + 100 })
    joined = lines[0...-1].flat_map { |line| line[/<<(.*)>>/, 1].split(',').map(&:to_i) }
    assert_equal BEAM.bytes, joined
    assert_includes lines.last, 'code:load_binary'
  end

  def test_the_ring_gets_more_iterations_than_the_others
    assert_equal 10_000, Erx::BenchGuest.iterations_for('ring', PLAN)
    assert_equal 1_000, Erx::BenchGuest.iterations_for('spawn', PLAN)
  end

  def test_a_log_missing_a_measurement_is_an_error
    observed = Erx::BenchGuest::BOOT_POINTS.map { |name| { 'name' => name, 'elapsed_seconds' => 1.0 } }
    assert_raises(Erx::Error) { Erx::BenchGuest.read_log("G3FOOT {\"a\":1}\n", observed) }
  end

  def test_a_complete_log_reads
    observed = Erx::BenchGuest::BOOT_POINTS.map.with_index { |name, i| { 'name' => name, 'elapsed_seconds' => i + 1.0 } }
    text = +"G3FOOT {\"processes\":3}\r\n"
    Erx::BenchGuest::WORKLOADS.each { |name| text << "G3 {\"workload\":\"#{name}\"}\r\nok\r\n" }
    result = Erx::BenchGuest.read_log(text, observed)
    assert_equal 3, result.fetch('footprint').fetch('processes')
    assert_equal 3.0, result.fetch('boot_seconds').fetch('release-shell')
  end

  def test_comparison_is_guest_over_stock_by_median
    guest = { 'ns_per_operation' => [30.0, 10.0, 20.0] }
    stock = { 'ns_per_operation' => [5.0, 15.0] }
    result = Erx::BenchG3.compare(guest, stock)
    assert_equal 20.0, result.fetch('guest_ns')
    assert_equal 10.0, result.fetch('stock_ns')
    assert_equal 2.0, result.fetch('guest_over_stock')
  end
end
