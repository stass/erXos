# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../tools/fuzz/bench_line'
require_relative '../../tools/lib/erx/bench_suite'

# The BENCH line validator (docs/design-bench.md, "A benchmark", "Verification"): a
# guest's line is accepted whole or refused whole, with a reason that never quotes it.
class BenchLineTest < Minitest::Test
  Fuzz = Erx::BenchLineFuzz

  def cell(text) = Erx::BenchMeasurement.cell(text, benchmark: 'wake', profiles: Fuzz::PROFILES)

  # A landing cell of the wake benchmark the boot asked for.
  def declared(operation, load: 'idle', placement: 'same-cpu', parameters: {})
    Erx::BenchSuite::LandingCell.new(operation: operation, load: load, placement: placement, parameters: parameters)
  end

  # The guest's lines judged as one boot that asked for cells, read on clock, whose
  # two-CPU cells span pairs.
  def boot(lines, cells: [declared('wake-same-cpu')], clock: 'counter', pairs: [[0, 1]])
    asked = Erx::BenchMeasurement::Asked.new(benchmark: Erx::BenchSuite.benchmark('wake'), cells: cells,
                                             profiles: Fuzz::PROFILES, clock: clock, pairs: pairs)
    Erx::BenchMeasurement.boot(lines, asked)
  end

  # Conditions of a line under load at placement.
  def on(load, placement: 'same-cpu', clock: 'counter', batch: 1, parameters: {})
    { 'load' => load, 'placement' => placement, 'parameters' => parameters, 'clock' => clock, 'batch' => batch }
  end

  def refusal(text)
    assert_raises(Erx::Error) { cell(text) }.message
  end

  def test_each_profiles_line_is_accepted_with_its_derived_summary
    Fuzz::PROFILES.each do |operation, profile|
      accepted = cell(Fuzz.line(operation))
      assert_equal [operation, 'measured', profile.samples],
                   [accepted.operation, accepted.status, accepted.summary.fetch('samples')]
      assert_equal 'wake/' + operation + '.json', accepted.file
    end
  end

  def test_the_lines_names_never_reach_a_file_name
    assert_match(/operation is not one the benchmark declares/, refusal(Fuzz.line('wake-same-cpu',
                                                                                  operation: 'erlang-timer')))
    assert_match(/benchmark is not the benchmark run/, refusal(Fuzz.line('wake-same-cpu', benchmark: 'sched')))
  end

  def test_a_refusal_never_quotes_the_line
    hostile = "\e]8;;x\a"
    [Fuzz.line('wake-same-cpu', reason: hostile, status: 'partial'),
     Fuzz.line('wake-same-cpu', hostile => 1),
     "BENCH {\"#{hostile}\": 1}"].each do |text|
      message = refusal(text)
      refute_includes message, "\e"
      refute_includes message, ']8;;'
    end
  end

  def test_a_histogram_past_its_samples_is_refused
    assert_match(/histogram is not ascending/, refusal(Fuzz.repeat_bucket(Fuzz.line('wake-same-cpu'), 2)))
    assert_match(/histogram does not hold every sample/,
                 refusal(Fuzz.line('wake-same-cpu', histogram: [[1000, 1000, 41]], min: 1000, max: 1000)))
  end

  def test_fields_that_disagree_are_refused
    largest = JSON.parse(Fuzz.line('wake-same-cpu').delete_prefix('BENCH ')).fetch('largest')
    {
      { 'samples' => 39 } => /histogram does not hold every sample/,
      { 'samples' => 41 } => /samples is not a count/,
      { 'samples' => 40.0 } => /samples is not a count/,
      { 'max' => 5000 } => /lie in the histogram buckets/,
      { 'largest' => largest.reverse } => /descending order from the maximum/,
      { 'largest' => [largest.first] * 16 } => /names one sample twice/,
      { 'status' => 'timed_out', 'reason' => 'x' } => /status is not one a guest reports/,
      { 'status' => 'measured', 'reason' => 'x' } => /needs its reason/,
      { 'raw' => [1] } => /field of another profile/,
      { 'counts' => { 'lost' => 0, 'early' => 0 } } => /lost, early and missed/,
      { 'frequency_hz' => 0 } => /frequency/
    }.each do |override, reason|
      assert_match(reason, refusal(Fuzz.line('wake-same-cpu', **override.transform_keys(&:to_sym))), override.inspect)
    end
  end

  def without(text, field)
    fields = JSON.parse(text.delete_prefix('BENCH '))
    fields.delete(field)
    "BENCH #{JSON.generate(fields)}"
  end

  # A cell reports its sixteen largest samples, or every sample when it has fewer, and
  # an expensive cell every sample.
  def test_the_largest_and_the_raw_samples_are_complete
    largest = JSON.parse(Fuzz.line('wake-same-cpu').delete_prefix('BENCH ')).fetch('largest')
    assert_match(/largest is not the sixteen largest/, refusal(Fuzz.line('wake-same-cpu', largest: largest.first(15))))
    assert_match(/raw/, refusal(without(Fuzz.line('trigger-take'), 'raw')))
  end

  # Every refusal of a BENCH line says so, the cell's own checks included.
  def test_a_refusal_names_the_bench_line
    assert_match(/\ABENCH line .*uncertainty/, refusal(Fuzz.line('wake-same-cpu', uncertainty: 1000)))
    assert_match(/\ABENCH line /, refusal(Fuzz.line('wake-same-cpu', min: 1150)))
  end

  def test_a_boots_cells_need_its_one_valid_clock_line
    lines = [Fuzz.line('wake-same-cpu')]
    measured = boot(lines + [Fuzz.clock_line])
    assert_equal [['measured', nil]], measured.fetch(:cells).map { |cell| [cell.status, cell.reason] }
    assert_equal 24_000_000, measured.fetch(:clock).fetch('frequency_hz')
    # A refused line costs only its own cell, and its reason never quotes it.
    kept = boot(lines + ['BENCH zz-secret', nil, Fuzz.clock_line])
    assert_equal ['measured'], kept.fetch(:cells).map(&:status)
    assert_equal 2, kept.fetch(:refused).size
    refute kept.fetch(:refused).any? { |reason| reason.include?('zz-secret') }
    [lines, lines + [Fuzz.clock_line(increment: 0)], lines + [Fuzz.clock_line] * 2].each do |printed|
      answer = boot(printed)
      assert_equal [['rejected', 'no valid CLOCK line in the boot', 0]],
                   answer.fetch(:cells).map { |cell| [cell.status, cell.reason, cell.detail.size] }
      assert_nil answer.fetch(:clock)
    end
    other = boot(lines + [Fuzz.clock_line(frequency_hz: 62_500_000)])
    assert_equal [['rejected', 'frequency differs from the CLOCK line']],
                 other.fetch(:cells).map { |cell| [cell.status, cell.reason] }
  end

  # A wrong result does not depend on the clock, and an early return is judged by it:
  # without a calibration the measured and unsupported cells, and a cell failed only by
  # early returns, are rejected, but a lost wake or a wrong status stays failed with only
  # its status, reason and counts, no tick statistics.
  def test_a_failed_cell_stays_failed_without_a_calibration_only_when_the_clock_did_not_judge_it
    lost = { 'lost' => 1, 'early' => 0, 'missed' => 0 }
    early = { 'lost' => 0, 'early' => 2, 'missed' => 0 }
    unsupported = Fuzz.line('trigger-take', status: 'unsupported', reason: 'one CPU', samples: 0, histogram: [],
                                             largest: [], raw: [])
    lines = [Fuzz.line('wake-same-cpu'), without(without(unsupported, 'min'), 'max'),
             Fuzz.line('wake-same-cpu', status: 'failed', reason: 'lost wake', counts: lost, conditions: on('spin')),
             Fuzz.line('trigger-take', status: 'failed', reason: 'wrong status', conditions: on('spin')),
             Fuzz.line('wake-same-cpu', status: 'failed', reason: 'early return', counts: early,
                                        conditions: on('spin-two'))]
    asked = [declared('wake-same-cpu'), declared('trigger-take'), declared('wake-same-cpu', load: 'spin'),
             declared('trigger-take', load: 'spin'), declared('wake-same-cpu', load: 'spin-two')]
    [lines, lines + [Fuzz.clock_line(frequency_hz: 62_500_000)]].each do |printed|
      answer = boot(printed, cells: asked)
      assert_equal [], answer.fetch(:refused).grep(/BENCH/)
      cells = answer.fetch(:cells)
      assert_equal %w[rejected rejected failed failed rejected], cells.map(&:status)
      assert_equal ['lost wake', 'wrong status'], cells[2, 2].map(&:reason)
      assert_equal [lost, { 'lost' => 0, 'early' => 0, 'missed' => 0 }], cells[2, 2].map(&:counts)
      assert(cells.all? { |kept| kept.detail.empty? })
    end
    calibrated = boot(lines + [Fuzz.clock_line], cells: asked)
    assert_equal %w[measured unsupported failed failed failed], calibrated.fetch(:cells).map(&:status)
    refute_empty calibrated.fetch(:cells)[2].detail
  end

  # A line reports a cell the boot asked for, on the environment's clock, once; a cell
  # the guest never reported is not_run, or rejected where one of its lines was refused.
  def test_a_line_is_held_to_the_cell_its_boot_asked_for
    others = { 'a load cell it did not ask for' => on('spin'),
               'a placement it did not ask for' => on('idle', placement: 'cross-cpu'),
               'parameters it did not ask for' => on('idle', parameters: { 'size' => 4 }),
               'another clock' => on('idle', clock: 'virtual') }
    others.each do |what, conditions|
      answer = boot([Fuzz.line('wake-same-cpu', conditions: conditions), Fuzz.clock_line])
      assert_equal [['rejected', 'a line of the boot was refused']],
                   answer.fetch(:cells).map { |cell| [cell.status, cell.reason] }, what
      assert_equal 1, answer.fetch(:refused).size, what
      assert_match(/\ABENCH line /, answer.fetch(:refused).first, what)
    end
    # A cell reported twice is rejected whatever either line said, its batch changed or not.
    lost = Fuzz.line('wake-same-cpu', status: 'failed', reason: 'lost wake', counts: { 'lost' => 1, 'early' => 0, 'missed' => 0 })
    [[Fuzz.line('wake-same-cpu'), lost],
     [Fuzz.line('park-deadline'), Fuzz.line('park-deadline', conditions: on('idle', batch: 2))]].each do |pair|
      twice = boot(pair + [Fuzz.clock_line], cells: [declared(Fuzz::MEASUREMENT.cell(pair.first, benchmark: 'wake', profiles: Fuzz::PROFILES).operation)])
      assert_equal [['rejected', 'the guest reported it more than once']],
                   twice.fetch(:cells).map { |cell| [cell.status, cell.reason] }
      assert_empty twice.fetch(:refused)
    end
    missing = boot([Fuzz.line('wake-same-cpu'), Fuzz.clock_line],
                   cells: [declared('wake-same-cpu'), declared('trigger-take')])
    assert_equal [%w[wake-same-cpu measured], %w[trigger-take not_run]],
                 missing.fetch(:cells).map { |cell| [cell.operation, cell.status] }
    assert_equal 'counter', missing.fetch(:cells).last.conditions.clock
  end

  # A handshake cannot be batched (docs/design-bench.md, "The one clock"): its line
  # reports batch 1, and its cell carries the CLOCK line's read cost and increment.
  def test_a_handshake_reports_batch_one_and_carries_the_clocks_quantization
    refused = boot([Fuzz.line('wake-same-cpu', conditions: on('idle', batch: 2)), Fuzz.clock_line])
    assert_match(/batch/, refused.fetch(:refused).first)
    handshake = boot([Fuzz.line('wake-same-cpu'), Fuzz.line('park-deadline'), Fuzz.clock_line(read_cost: 3, increment: 2)],
                     cells: [declared('wake-same-cpu'), declared('park-deadline')])
    shook, parked = handshake.fetch(:cells)
    assert_equal [3, 2], shook.detail.values_at('read_cost', 'increment')
    refute parked.detail.key?('read_cost')
  end

  # The CLOCK line reads the environment's clock and calibrates exactly the pairs the
  # boot's two-CPU cells span; a two-CPU cell with samples needs a calibrated pair.
  def test_the_clock_line_calibrates_the_pairs_the_boot_asked_for
    lines = [Fuzz.line('wake-same-cpu')]
    [boot(lines + [Fuzz.clock_line], pairs: [[0, 3]]), boot(lines + [Fuzz.clock_line(clock: 'virtual')]),
     boot(lines + [Fuzz.clock_line(pairs: [])])].each do |answer|
      assert_equal [['rejected', 'no valid CLOCK line in the boot']],
                   answer.fetch(:cells).map { |cell| [cell.status, cell.reason] }
      assert_match(/\ACLOCK line /, answer.fetch(:refused).last)
    end
    cross = declared('wake-same-cpu', placement: 'cross-cpu')
    one_cpu = boot([Fuzz.line('wake-same-cpu', conditions: on('idle', placement: 'cross-cpu')),
                    Fuzz.clock_line(pairs: [])], cells: [cross], pairs: [])
    assert_equal ['rejected'], one_cpu.fetch(:cells).map(&:status)
    assert_match(/two CPUs/, one_cpu.fetch(:refused).first)
  end

  def test_a_wrong_answer_is_failed_and_a_partial_cell_says_so
    assert_raises(Erx::Error) { cell(Fuzz.line('wake-same-cpu', counts: { 'lost' => 1, 'early' => 0, 'missed' => 0 })) }
    failed = cell(Fuzz.line('wake-same-cpu', status: 'failed', reason: 'lost wake',
                                             counts: { 'lost' => 1, 'early' => 0, 'missed' => 0 }))
    assert_equal 'failed', failed.status
    assert failed.summary.fetch('partial')
  end

  def test_a_line_that_is_not_one_bounded_json_object_is_refused
    [['BENCH ', /not one JSON object/], ['BENCH []', /not a JSON object/], ['BENCH {"a":1,"a":1}', /not one JSON/],
     ["BENCH #{'[' * 5}1#{']' * 5}", /nested at most four/], ["BENCH {\"benchmark\":\"wake\"}\n", /printable/],
     ["BENCH {#{' ' * (64 << 10)}}", /longer than 65536 bytes/], ['bench {}', /does not begin with BENCH/],
     [Fuzz.line('wake-same-cpu', status: 'partial', reason: 'x').sub('"x"', '"\udfff"'), /backslash/],
     ['BENCH {/* */}', /slash/]].each do |text, reason|
      assert_match(reason, refusal(text))
    end
  end

  def test_the_fuzzer_runs_clean_over_its_seeds
    assert_operator Fuzz.run(seconds: 1, seed: 7), :>, 100
  end
end
