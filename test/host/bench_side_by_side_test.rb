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
    assert_equal ['kernel', 1, 4], [table.layer, same.cpus, cross.cpus]
    erxos, linux = column(same, 'erxos'), column(same, 'linux')
    assert_equal [ns(1000)], erxos.entries.map { |entry| entry.values.fetch('p50') }
    assert_equal [ns(1500), ns(2000)], linux.entries.map { |entry| entry.values.fetch('p50') }
    assert_equal 'a pipe round trip between two threads', linux.counterpart
    # A ratio pairs a run with erXos's run of the same round; round two has none.
    assert_equal [3 / 2r, nil], linux.entries.map(&:ratio)
  end

  # On the board each system boots in its own form, erXos on four CPUs and L4Re on one,
  # so the board table sets every run beside each cell and names no CPU form.
  def test_the_board_table_sets_each_systems_own_form_on_one_row
    board = [boot("erxos", 4, [histogram("same", "counter", 30)], clock: ERXOS_CLOCK), boot("l4re", 1, [mean("same")], clock: nil)]
    same, = Tables.tables(BENCHMARK, board, systems: %w[erxos l4re], forms: false).first.rows
    assert_nil same.cpus
    assert_equal [1, 1], %w[erxos l4re].map { |system| column(same, system).entries.size }
    assert_includes Tables.render(Tables.tables(BENCHMARK, board, systems: %w[erxos l4re], forms: false)),
                    "probe.same idle same-cpu, on the board"
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

  # On the board the cards hold one ARM clock, which the run records: L4Re's cycles are
  # shown in nanoseconds at that clock, the row says so, and a mean still takes no ratio.
  def test_cycles_of_a_run_that_recorded_its_arm_clock_are_shown_in_ns
    held = boot('l4re', 1, [mean('same')], clock: nil)
    held = held.with(record: held.record.with(run: held.record.run.with(details: { 'arm_clock_hz' => 1_500_000_000 })))
    board = Tables.tables(BENCHMARK, [runs.first, held], systems: %w[erxos l4re], forms: false).first
    entry = column(board.rows.first, 'l4re').entries.first
    assert_equal [ns(Rational(4_213_000 * 1000, 10_000 * 1500)), 1_500_000_000, nil],
                 [entry.values.fetch('mean'), entry.converted_hz, entry.ratio]
    line = Tables.render([board]).find { |text| text.include?('280.9 ns') }
    assert_match(/cycles, shown in ns at the 1500 MHz ARM clock its config\.txt held, mean/, line)
  end

  # ipcbench prints an IPC mean over two IPCs per call, half a round trip; the table
  # shows the total over the calls, one round trip, beside erXos's round trips.
  def test_a_mean_is_shown_as_its_total_over_its_count
    halved = boot('l4re', 1, [mean('same', total: 4_200_000, printed: 210)], clock: nil)
    l4re = column(Tables.tables(BENCHMARK, [runs.first, halved], systems: %w[erxos l4re]).first.rows.first, 'l4re')
    assert_equal Tables::Quantity.new(amount: 420.0, unit: 'cycles'), l4re.entries.first.values.fetch('mean')
  end

  # A batched erXos cell that keeps its total shows its mean per call beside its median:
  # 20 batches of 32 calls spanned 3,000 ticks of the 24 MHz counter, 640 calls of
  # 4.6875 ticks, 195.3125 ns each, though every sample rounds down to 4 or 5 ticks.
  def test_a_batched_cells_total_gives_its_mean_per_call
    batched = Record::Cell.new(
      benchmark: 'probe', operation: 'same', conditions: conditions('same', 'counter').with(batch: 32),
      profile: PROFILE, status: 'measured', reason: nil, counts: { 'lost' => 0, 'early' => 0, 'missed' => 0 },
      detail: { 'histogram' => [[4, 4, 15], [5, 5, 5]], 'min' => 4, 'max' => 5, 'total' => 3000 }
    )
    erxos = column(Tables.tables(BENCHMARK, [boot('erxos', 1, [batched, unsupported('cross')], clock: ERXOS_CLOCK)],
                                 systems: %w[erxos]).first.rows.first, 'erxos')
    values = erxos.entries.first.values
    assert_equal [Tables::Quantity.new(amount: 640, unit: 'operations'), ns(3125 / 16r), ns(Rational(4_000, 24))],
                 values.values_at('count', 'mean', 'p50')
    assert(Tables.render([Tables.tables(BENCHMARK, [boot('erxos', 1, [batched], clock: ERXOS_CLOCK)],
                                        systems: %w[erxos]).first]).any? { |text| text.include?('mean 195.3 ns') })
  end

  def test_the_rendered_table_names_its_layer_and_each_counterpart
    lines = Tables.render([table])
    assert_equal 'The kernel table of probe, side by side; no verdict', lines.first
    assert_includes lines, '  l4re: none'
    assert(lines.any? { |text| text.include?('p50 1500.0 ns') && text.include?('ratio 1.50') })
    # The same cell of erXos's four-CPU boot is not its one-CPU row's number.
    refute(lines.any? { |text| text.include?('1250.0 ns') })
  end

# A program operation says whether both systems do the same work for the call; the
# program table prints that line on every row (docs/design-bench.md, "Fairness").
PROGRAM = Suite::Benchmark.new(
  name: 'posix',
  operations: {
    'getpid' => Suite::Operation.new(name: 'getpid', profile: 'fast', result: 'ok', counterparts: { 'linux' => 'getpid' },
                                     act: 'nearest counterpart: erXos answers in user mode'),
    'read' => Suite::Operation.new(name: 'read', profile: 'fast', result: 'ok', counterparts: { 'linux' => 'pread' },
                                   act: 'same act')
  },
  landing: { 'posix' => [Suite::LandingCell.new(operation: 'getpid', load: 'idle', placement: 'same-cpu', parameters: {}),
                         Suite::LandingCell.new(operation: 'read', load: 'idle', placement: 'same-cpu',
                                                parameters: { 'bytes' => 4096 })] }
)

def program_cell(operation, clock, total:, parameters: {})
  Record::Cell.new(
    benchmark: 'posix', operation: operation,
    conditions: Record::Conditions.new(load: 'idle', placement: 'same-cpu', parameters: parameters, clock: clock, batch: 8),
    profile: PROFILE, status: 'measured', reason: nil, counts: { 'lost' => 0, 'early' => 0, 'missed' => 0 },
    detail: { 'histogram' => [[total / 160, total / 160, 20]], 'min' => total / 160, 'max' => total / 160, 'total' => total }
  )
end

# An erXos and a Linux boot of posix: one row per cell, both columns, the act line, and
# each batched cell's mean its total over its 160 calls.
def test_the_program_table_sets_each_cell_beside_linux_with_its_act
  runs = [boot('erxos', 1, [program_cell('getpid', 'counter', total: 3840),
                            program_cell('read', 'counter', total: 384_000, parameters: { 'bytes' => 4096 })],
               clock: ERXOS_CLOCK),
          boot('linux', 1, [program_cell('getpid', 'monotonic', total: 32_000),
                            program_cell('read', 'monotonic', total: 160_000, parameters: { 'bytes' => 4096 })],
               clock: LINUX_CLOCK)]
  program = Tables.tables(PROGRAM, runs, systems: %w[erxos linux]).first
  assert_equal ['program', %w[getpid read]], [program.layer, program.rows.map { |row| row.cell.operation }]
  assert_equal ['nearest counterpart: erXos answers in user mode', 'same act'], program.rows.map(&:act)
  getpid = program.rows.first
  assert_equal [ns(1000), ns(200)],
               %w[erxos linux].map { |system| column(getpid, system).entries.first.values.fetch('mean') }
  lines = Tables.render([program])
  assert_equal 'The program table of posix, side by side; no verdict', lines.first
  assert_includes lines, '  act: same act'
  assert_includes lines, '  linux: pread'
end
end
