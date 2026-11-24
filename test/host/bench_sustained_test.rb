# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../tools/fuzz/bench_line'
require_relative '../../tools/lib/erx/bench_compare'
require_relative '../../tools/lib/erx/bench_suite'

# A sustained cell (docs/design-bench.md, "A sustained cell", "Comparison",
# "Verification"): a spinner task's WINDOW lines, each within its bound, held to the cell
# the root's BENCH line names after them; the cell's summary derived from its windows; and
# a comparison judging the longest gap over all windows.
class BenchSustainedTest < Minitest::Test
  Fuzz = Erx::BenchLineFuzz
  Measurement = Erx::BenchMeasurement
  Record = Erx::BenchRecord
  PROFILE = Record::Profile.new(name: 'sustained', warmup: 2000, samples: 3, runs: 1)
  PARAMETERS = { 'threads' => 4, 'window-ms' => 1000 }.freeze
  HZ = 24_000_000

  # Thread t's window w: a quarter of the window's ticks, and its longest gap longest[w][t].
  def window_lines(longest: Array.new(3) { [72_000, 72_000, 72_000, 72_000] }, iterations:)
    (0...3).flat_map do |window|
      (0...4).map do |thread|
        Fuzz.window_line(window: window, thread: thread, iterations: iterations.call(window, thread),
                         longest: longest[window][thread], lost: 250, waited: HZ * 3 / 4)
      end
    end
  end

  def bench_line(**overrides)
    fields = { 'benchmark' => 'sched', 'operation' => 'share-equal',
               'conditions' => { 'load' => 'idle', 'placement' => 'other-cpu', 'parameters' => PARAMETERS,
                                 'clock' => 'counter', 'batch' => 1 },
               'frequency_hz' => HZ, 'status' => 'measured', 'samples' => 3,
               'counts' => { 'lost' => 0, 'early' => 0, 'missed' => 0 } }
    "BENCH #{JSON.generate(fields.merge(overrides.transform_keys(&:to_s)))}"
  end

  def boot(lines)
    declared = Erx::BenchSuite::LandingCell.new(operation: 'share-equal', load: 'idle', placement: 'other-cpu',
                                                parameters: PARAMETERS)
    wanted = Measurement::Wanted.new(benchmark: Erx::BenchSuite.benchmark('sched'), cells: [declared],
                                     profiles: { 'share-equal' => PROFILE })
    asked = Measurement::Asked.new(benchmarks: [wanted], clock: 'counter', pairs: [[0, 1]])
    Measurement.boot([*lines, Fuzz.clock_line], asked)
  end

  def every_pass = ->(_window, _thread) { 1000 }

  def test_a_window_line_is_held_to_its_bound
    text = Fuzz.window_line
    padded = ->(bytes) { text.sub('{', "{#{' ' * (bytes - text.bytesize)}") }
    assert_equal 160, padded.call(160).bytesize
    assert_equal 98_765, Measurement.window(padded.call(160)).fetch('longest')
    error = assert_raises(Erx::Error) { Measurement.window(padded.call(161)) }
    assert_equal 'WINDOW line is longer than 160 bytes', error.message
  end

  def test_twelve_windows_and_their_bench_line_are_a_measured_cell
    longest = [[72_000, 72_000, 72_000, 72_000], [72_000, 96_000, 72_000, 72_000], [72_000, 72_000, 72_000, 48_000]]
    answer = boot([*window_lines(longest: longest, iterations: every_pass), bench_line])
    assert_empty answer.fetch(:refused)
    cell = answer.fetch(:cells).first
    assert_equal ['measured', 3], [cell.status, cell.summary.fetch('samples')]
    assert_equal [0.25] * 4, cell.summary.fetch('windows').first.fetch('shares')
    assert_equal 1.0, cell.summary.fetch('windows').first.fetch('ratio')
    assert_equal [72_000, 96_000, 72_000, 72_000], cell.summary.fetch('windows')[1].fetch('longest')
    assert_equal({ 'value' => 96_000 }, cell.summary.fetch('longest'))
  end

  def test_a_missing_or_misplaced_window_line_rejects_the_cell
    lines = window_lines(iterations: every_pass)
    [lines.drop(1), [lines[1], lines[0], *lines.drop(2)], [*lines, lines.last]].each do |windows|
      answer = boot([*windows, bench_line])
      assert_equal 'rejected', answer.fetch(:cells).first.status
      assert_match(/\AWINDOW line (?:for window 0, thread 0 is (?:missing|misplaced)|past the last window and thread)/,
                   answer.fetch(:refused).first)
    end
  end

  def test_a_thread_with_no_pass_in_a_window_fails_the_cell
    idle = ->(window, thread) { [window, thread] == [1, 2] ? 0 : 1000 }
    cell = boot([*window_lines(iterations: idle), bench_line]).fetch(:cells).first
    assert_equal ['failed', 'thread 2 made no pass in window 1'], [cell.status, cell.reason]
  end

  def test_window_lines_no_sustained_bench_line_follows_are_refused
    assert_equal 'WINDOW lines are followed by no BENCH line',
                 boot(window_lines(iterations: every_pass)).fetch(:refused).last
    error = assert_raises(Erx::Error) do
      Measurement.cell(Fuzz.line('wake-same-cpu'), Fuzz::ASKED, windows: [Fuzz.window_line])
    end
    assert_equal 'BENCH line follows WINDOW lines but is not a sustained cell', error.message
  end

  def test_a_sustained_line_with_a_tick_statistic_is_refused
    refused = boot([*window_lines(iterations: every_pass), bench_line('min' => 1)]).fetch(:refused).first
    assert_equal 'BENCH line holds a tick statistic, which a sustained cell has none of', refused
  end

  # Three baseline runs whose longest gap over all windows is 96,000 ticks, in window 1, and
  # three candidates whose window 2 holds a gap of 150,000: the comparison sees the tail.
  def test_the_comparison_judges_the_longest_gap_over_all_windows
    run = ->(late) do
      longest = [[72_000] * 4, [72_000, 96_000, 72_000, 72_000], [72_000, 72_000, 72_000, late]]
      cell = boot([*window_lines(longest: longest, iterations: every_pass), bench_line]).fetch(:cells).first
      record = Record::Record.new(
        environment: Record::Environment.new(kind: 'qemu-hvf', model: 'Mac16,10', cpus: 4, system: nil, details: {}),
        subject: Record::Subject.new(revision: 'a' * 40, dirty: false, details: {}),
        run: Record::Run.new(date: Time.utc(2026, 11, 23), started_by: 'manual', load: [0.5, 0.5], host_cpus: 12,
                             reused_from: nil),
        clock: {}, cells: [cell]
      )
      Erx::BenchCompare::Side.new(record: record, cell: cell)
    end
    environment = run.call(72_000).record.environment
    threshold = Erx::BenchCompare.threshold(environment, 'longest')
    assert_equal Erx::BenchCompare.threshold(environment, 'p99'), threshold
    verdict = Erx::BenchCompare.verdict(statistic: 'longest', baseline: Array.new(3) { run.call(72_000) },
                                        candidate: Array.new(3) { run.call(150_000) }, threshold: threshold)
    assert_equal ['slower', [96_000, 96_000]], [verdict.verdict, verdict.band]
  end

  def test_the_share_case_holds_its_lines_to_its_sizes
    lines = window_lines(iterations: every_pass)
    assert_equal 3, Measurement.windows(lines, windows: 3, threads: 4).size
    assert_raises(Erx::Error) { Measurement.windows(lines.take(11), windows: 3, threads: 4) }
    assert_equal [1, 2], Measurement.idle(Measurement.windows(window_lines(iterations: lambda { |window, thread|
      [window, thread] == [1, 2] ? 0 : 1
    }), windows: 3, threads: 4))
  end
end
