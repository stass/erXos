# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/bench_compare'

# Comparability and the verdict (docs/design-bench.md, "Comparison", "Verification").
class BenchCompareTest < Minitest::Test
  Record = Erx::BenchRecord
  Compare = Erx::BenchCompare

  def environment(kind, system: 'erxos') = Record::Environment.new(kind: kind, model: 'Mac16,10', cpus: 4, system: system, details: {})

  def cell(median: 100, bucket: 2, batch: 1, status: 'measured')
    Record::Cell.new(
      benchmark: 'wake', operation: 'wake-same-cpu',
      conditions: Record::Conditions.new(load: 'idle', placement: 'same-cpu', parameters: {}, clock: 'counter',
                                         batch: batch),
      profile: Record::Profile.new(name: 'fast', warmup: 1000, samples: 20, runs: 1),
      status: status, reason: status == 'measured' ? nil : 'test',
      counts: { 'lost' => 0, 'early' => 0, 'missed' => 0 },
      detail: status == 'measured' ? { 'histogram' => [[median - bucket + 1, median, 20]], 'min' => median - bucket + 1, 'max' => median } : {}
    )
  end

  def side(kind: 'qemu-hvf', system: 'erxos', load: [0.5, 0.5], reused_from: nil, cell: nil, **cell_options)
    record = Record::Record.new(
      environment: environment(kind, system: system),
      subject: Record::Subject.new(revision: 'a' * 40, dirty: false, details: {}),
      run: Record::Run.new(date: Time.utc(2026, 11, 23), started_by: 'manual', load: load, host_cpus: 12,
                           reused_from: reused_from),
      clock: cell ? nil : {}, cells: [cell || cell(**cell_options)]
    )
    Compare::Side.new(record: record, cell: record.cells.first)
  end

  # docs/design-bench.md, "Comparison": two systems' records differ in their environment,
  # so a comparison of them is refused naming the system; only the side-by-side table
  # sets them beside each other.
  def test_two_systems_are_never_compared
    error = assert_raises(Erx::Error) { Compare.comparable!(side(system: 'linux'), side) }
    assert_match(/system/, error.message)
    assert_match(/linux against erxos/, error.message)
    assert_raises(Erx::Error) { verdict([side, side, side], [side(system: 'linux')]) }
  end

  def test_a_mean_has_no_distribution_to_compare
    mean = Record::Cell.new(
      benchmark: 'wake', operation: 'wake-same-cpu', form: 'mean',
      conditions: Record::Conditions.new(load: 'idle', placement: 'same-cpu', parameters: {}, clock: 'counter', batch: 1),
      profile: nil, status: 'measured', reason: nil, counts: nil,
      detail: { 'count' => 20, 'total' => 2000, 'mean' => 100 }
    )
    [[side(cell: mean), side], [side, side(cell: mean)], [side(cell: mean), side(cell: mean)]].each do |a, b|
      assert_equal 'a mean has no distribution to compare', assert_raises(Erx::Error) { Compare.comparable!(a, b) }.message
    end
  end

  def verdict(baseline, candidate) =
    Compare.verdict(statistic: 'p50', baseline: baseline, candidate: candidate, threshold: 1 / 10r).verdict

  def test_tcg_is_never_compared_with_hvf
    error = assert_raises(Erx::Error) { Compare.comparable!(side(kind: 'qemu-tcg'), side) }
    assert_equal 'TCG numbers are not compared with HVF or native numbers', error.message
    assert_raises(Erx::Error) { Compare.comparable!(side(kind: 'qemu-det'), side(kind: 'pi4')) }
  end

  def test_cells_differing_only_in_batch_size_are_refused
    error = assert_raises(Erx::Error) { Compare.comparable!(side(batch: 2), side) }
    assert_match(/batch/, error.message)
    Compare.comparable!(side, side)
  end

  BASELINE_MEDIANS = [100, 102, 101].freeze

  def baseline = BASELINE_MEDIANS.map { |median| side(median: median) }

  def test_within_the_band_is_same
    assert_equal 'same', verdict(baseline, [99, 103, 104].map { |median| side(median: median) })
  end

  def test_two_of_three_above_by_more_than_the_threshold_is_slower
    assert_equal 'slower', verdict(baseline, [120, 125, 101].map { |median| side(median: median) })
    assert_equal 'faster', verdict(baseline, [80, 85, 101].map { |median| side(median: median) })
  end

  def test_one_of_three_above_is_inconclusive
    assert_equal 'inconclusive', verdict(baseline, [130, 101, 101].map { |median| side(median: median) })
    # A wide band: the candidates' median clears the threshold, but only one run is above.
    wide = [100, 102, 130].map { |median| side(median: median) }
    assert_equal 'inconclusive', verdict(wide, [140, 120, 120].map { |median| side(median: median) })
  end

  def test_one_candidate_says_only_same_or_outside_the_band
    assert_equal 'same', verdict(baseline, [side(median: 101)])
    assert_equal 'outside the band', verdict(baseline, [side(median: 150)])
  end

  def test_a_short_or_unmeasured_or_loaded_comparison_is_inconclusive
    assert_equal 'inconclusive', verdict(baseline.take(2), [side(median: 101)])
    assert_equal 'inconclusive', verdict([], [side(median: 101)])
    assert_equal 'inconclusive', verdict(baseline, [side(status: 'partial')])
    assert_equal 'inconclusive', verdict(baseline, [side(median: 101, load: [7.0, 0.5])])
    assert_equal 'inconclusive', verdict(baseline, [side(median: 101, load: nil)])
  end

  def test_a_replayed_log_is_not_a_baseline_run
    replayed = [*baseline.take(2), side(median: 101, reused_from: 'bench/qemu-hvf-Mac16,10-4cpu/20261122T000000Z-aaaaaaaaaaaa')]
    error = assert_raises(Erx::Error) { verdict(replayed, [side(median: 101)]) }
    assert_equal 'a replayed log is not a new run', error.message
  end

  def test_a_sustained_rate_reverses_the_direction
    rates = [100, 102, 101].map { |rate| side(median: rate) }
    result = Compare.verdict(statistic: 'p50', baseline: rates, candidate: [80, 85, 101].map { |rate| side(median: rate) },
                             threshold: 1 / 10r, rate: true)
    assert_equal 'slower', result.verdict
  end
end
