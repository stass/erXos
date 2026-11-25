# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/bench_side_by_side'

# The side-by-side tables of a comparison session (docs/design-bench.md, "A comparison
# session", "Verification"): a row per erXos cell, a column per system, nanoseconds only
# from a run's own frequency, cycles left as cycles, and a ratio only between two cells
# of clocks with a frequency.
class BenchSideBySideTest < Minitest::Test
  Record = Erx::BenchRecord
  Suite = Erx::BenchSuite
  Tables = Erx::BenchSideBySide

  # One cell erXos, L4Re and Linux all run on one CPU, and one across CPUs only Linux runs.
  BENCHMARK = Suite::Benchmark.new(
    name: 'probe',
    operations: {
      'same' => Suite::Operation.new(name: 'same', profile: 'fast', result: 'ok',
                                     counterparts: { 'l4re' => 'ipcbench: two threads of one task',
                                                     'linux' => 'a pipe round trip between two threads' }),
      'cross' => Suite::Operation.new(name: 'cross', profile: 'fast', result: 'ok',
                                      counterparts: { 'linux' => 'a condition wait woken from another CPU' })
    },
    landing: { 'native' => [Suite::LandingCell.new(operation: 'same', load: 'idle', placement: 'same-cpu', parameters: {}),
                            Suite::LandingCell.new(operation: 'cross', load: 'idle', placement: 'cross-cpu', parameters: {})] }
  )
  PROFILE = Record::Profile.new(name: 'fast', warmup: 0, samples: 20, runs: 1)
  # erXos's boot measured cycles per tick, which describes only that boot.
  ERXOS_CLOCK = { 'clock' => 'counter', 'frequency_hz' => 24_000_000, 'cycles_per_tick' => 100 }.freeze
  LINUX_CLOCK = { 'clock' => 'monotonic', 'frequency_hz' => 1_000_000_000, 'cycles_per_tick' => 'unknown' }.freeze

  def conditions(operation, clock) =
    Record::Conditions.new(load: 'idle', placement: operation == 'same' ? 'same-cpu' : 'cross-cpu', parameters: {},
                           clock: clock, batch: 1)

  def histogram(operation, clock, median)
    Record::Cell.new(benchmark: 'probe', operation: operation, conditions: conditions(operation, clock), profile: PROFILE,
                     status: 'measured', reason: nil, counts: { 'lost' => 0, 'early' => 0, 'missed' => 0 },
                     detail: { 'histogram' => [[median, median, 20]], 'min' => median, 'max' => median })
  end

  def unsupported(operation)
    Record::Cell.new(benchmark: 'probe', operation: operation, conditions: conditions(operation, 'counter'),
                     profile: PROFILE, status: 'unsupported', reason: 'the machine has one CPU',
                     counts: { 'lost' => 0, 'early' => 0, 'missed' => 0 }, detail: {})
  end

  def mean(operation, total: 4_213_000, printed: 421.3)
    Record::Cell.new(benchmark: 'probe', operation: operation, form: 'mean', conditions: conditions(operation, 'cycles'),
                     profile: nil, status: 'measured', reason: nil, counts: nil,
                     detail: { 'count' => 10_000, 'total' => total, 'mean' => printed })
  end

  def boot(system, cpus, cells, clock:, round: 0)
    record = Record::Record.new(
      environment: Record::Environment.new(kind: 'qemu-hvf', model: 'Mac16,10', cpus: cpus, system: system, details: {}),
      subject: Record::Subject.new(revision: 'a' * 40, dirty: false, details: {}),
      run: Record::Run.new(date: Time.utc(2026, 11, 24), started_by: 'manual', load: [0.5, 0.5], host_cpus: 12,
                           reused_from: nil, details: {}),
      boots: [Record::Boot.new(position: 1, clock: clock, cells: cells, details: {})]
    )
    Tables::Run.new(round: round, record: record)
  end

  # 24 ticks of erXos's 24 MHz counter are 1,000 ns; Linux's monotonic ticks are ns.
  def runs
    [boot('erxos', 1, [histogram('same', 'counter', 24), unsupported('cross')], clock: ERXOS_CLOCK),
     boot('erxos', 4, [histogram('same', 'counter', 30), histogram('cross', 'counter', 48)], clock: ERXOS_CLOCK),
     boot('l4re', 1, [mean('same')], clock: nil),
     boot('linux', 1, [histogram('same', 'monotonic', 1500)], clock: LINUX_CLOCK),
     boot('linux', 4, [histogram('cross', 'monotonic', 3000)], clock: LINUX_CLOCK),
     boot('linux', 1, [histogram('same', 'monotonic', 2000)], clock: LINUX_CLOCK, round: 1)]
  end

  def table = Tables.tables(BENCHMARK, runs, systems: %w[erxos l4re linux]).first
  def column(row, system) = row.columns.find { |entry| entry.system == system }
  def ns(amount) = Tables::Quantity.new(amount: amount, unit: 'ns')

  # The design's "a system's environment" case: an erXos and a Linux record of one model
  # and CPU count are two environments, and the table sets them beside each other.
  def test_the_table_sets_two_systems_beside_each_other
    same, cross = table.rows
    assert_equal ['C', 1, 4], [table.layer, same.cpus, cross.cpus]
    erxos, linux = column(same, 'erxos'), column(same, 'linux')
    assert_equal [ns(1000)], erxos.entries.map { |entry| entry.values.fetch('p50') }
    assert_equal [ns(1500), ns(2000)], linux.entries.map { |entry| entry.values.fetch('p50') }
    assert_equal 'a pipe round trip between two threads', linux.counterpart
    # A ratio pairs a run with erXos's run of the same round; round two has none.
    assert_equal [3 / 2r, nil], linux.entries.map(&:ratio)
  end

  def test_a_cross_cpu_cell_is_read_from_the_four_cpu_form
    cross = table.rows.last
    assert_equal [['measured', ns(2000)]], column(cross, 'erxos').entries.map { |entry| [entry.status, entry.values['p50']] }
    assert_equal [3 / 2r], column(cross, 'linux').entries.map(&:ratio)
    assert_equal ['none', []], [column(cross, 'l4re').counterpart, column(cross, 'l4re').entries]
  end

  # The design's "cycles stays cycles" case: L4Re's mean stays in cycles and takes no
  # ratio, whatever erXos's boot measured of its cycles per tick.
  def test_cycles_stay_cycles
    l4re = column(table.rows.first, 'l4re')
    entry = l4re.entries.first
    assert_equal ['mean', 'cycles', nil], [entry.form, entry.clock, entry.ratio]
    # A mean in nanoseconds beside erXos's median still takes no ratio.
    timed = boot('linux', 1, [histogram('cross', 'monotonic', 3000), mean('same').with(conditions: conditions('same', 'monotonic'))],
                 clock: LINUX_CLOCK)
    mixed = Tables.tables(BENCHMARK, [runs.first, timed], systems: %w[erxos linux]).first
    assert_equal [[Tables::Quantity.new(amount: 421.3, unit: 'ns'), nil]],
                 column(mixed.rows.first, 'linux').entries.map { |linux| [linux.values['mean'], linux.ratio] }
    assert_equal({ 'count' => Tables::Quantity.new(amount: 10_000, unit: 'operations'),
                   'mean' => Tables::Quantity.new(amount: 421.3, unit: 'cycles') }, entry.values)
    line = Tables.render([table]).find { |text| text.include?('421.3') }
    assert_match(/mean 421\.3 cycles/, line)
    refute_match(/\bns\b|\bratio\b/, line)
  end

# ipcbench prints an IPC mean over two IPCs per call, half a round trip; the table
# shows the total over the calls, one round trip, beside erXos's round trips.
def test_a_mean_is_shown_as_its_total_over_its_count
  halved = boot('l4re', 1, [mean('same', total: 4_200_000, printed: 210)], clock: nil)
  l4re = column(Tables.tables(BENCHMARK, [runs.first, halved], systems: %w[erxos l4re]).first.rows.first, 'l4re')
  assert_equal Tables::Quantity.new(amount: 420.0, unit: 'cycles'), l4re.entries.first.values.fetch('mean')
end

  def test_the_rendered_table_names_its_layer_and_each_counterpart
    lines = Tables.render([table])
    assert_equal 'The C table of probe, side by side; no verdict', lines.first
    assert_includes lines, '  l4re: none'
    assert(lines.any? { |text| text.include?('p50 1500.0 ns') && text.include?('ratio 1.50') })
    # The same cell of erXos's four-CPU boot is not its one-CPU row's number.
    refute(lines.any? { |text| text.include?('1250.0 ns') })
  end
end
