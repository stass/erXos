# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/bench_suite'
require_relative '../../tools/lib/erx/qemu_gate'

# The bench suite's cells and the table from a benchmark cell's status to its suite cell
# (docs/design-bench.md, "The gates", "Cells and suite cells").
class BenchSuiteTest < Minitest::Test
  Suite = Erx::BenchSuite

  def test_each_status_maps_to_its_suite_cell
    expected = { 'measured' => 'passed', 'unsupported' => 'partial', 'partial' => 'partial', 'rejected' => 'partial',
                 'timed_out' => 'timed_out', 'not_run' => 'not_run', 'failed' => 'failed' }
    assert_equal Erx::BenchRecord::STATUSES.sort, expected.keys.sort
    expected.each do |status, cell|
      assert_equal cell, Suite.suite_cell([[status, false]]), status
    end
  end

  def test_an_expected_unsupported_cell_passes
    assert_equal 'passed', Suite.suite_cell([['measured', false], ['unsupported', true]])
    assert_equal 'partial', Suite.suite_cell([['measured', false], ['unsupported', false]])
  end

  def test_a_suite_cell_takes_its_worst_status
    assert_equal 'failed', Suite.suite_cell([['measured', false], ['failed', false], ['timed_out', false]])
    assert_equal 'timed_out', Suite.suite_cell([['not_run', false], ['timed_out', false]])
    assert_equal 'not_run', Suite.suite_cell([['partial', false], ['not_run', false]])
    assert_equal 'not_run', Suite.suite_cell([])
  end

  def test_unsupported_is_expected_only_where_the_environment_lacks_the_cpus
    four = Erx::BenchRecord::Environment.new(kind: 'qemu-hvf', model: 'Mac16,10', cpus: 4, system: nil, details: {})
    deterministic = Erx::BenchRecord::Environment.new(kind: 'qemu-det', model: nil, cpus: 1, system: nil, details: {})
    cell = ->(placement) { Suite::LandingCell.new(operation: 'wake-same-cpu', load: 'idle', placement: placement, parameters: {}) }
    refute Suite.expected_unsupported?(cell.call('cross-cpu'), four)
    assert Suite.expected_unsupported?(cell.call('cross-cpu'), deterministic)
    assert Suite.expected_unsupported?(cell.call('other-cpu'), deterministic)
    refute Suite.expected_unsupported?(cell.call('same-cpu'), deterministic)
  end

  def test_the_suite_cells_are_each_boots_benchmarks
    assert_equal %w[hvf-4cpu-native-nullcall hvf-4cpu-native-sched hvf-4cpu-native-wake hvf-4cpu-xdomain-wake
                    hvf-4cpu-xdomain-xdomain], Suite.suite_cells.sort
    declared = Erx::QemuGate.suites.find { |suite| suite.name == 'bench' }
    assert_equal Suite.suite_cells, declared.cells
    refute declared.offload
  end

  def test_the_wake_landing_cells_follow_the_matrix
    landing = Suite.benchmarks.fetch('wake').landing
    assert_equal %w[park-deadline trigger-take wake-cross-cpu wake-same-cpu], landing.fetch('native').map(&:operation).sort
    assert_equal %w[erlang-timer], landing.fetch('xdomain').map(&:operation)
  end

  def test_an_undeclared_benchmark_or_operation_is_refused
    assert_raises(Erx::Error) { Suite.benchmark('nonesuch') }
    assert_raises(Erx::Error) do
      Suite::Benchmark.new(name: 'wake', operations: {}, landing: { 'native' => [Suite::LandingCell.new(
        operation: 'park-deadline', load: 'idle', placement: 'service-cpu', parameters: {}
      )] })
    end
  end
  # A boot's suite cell is its cells' worst, each judged in the record's environment,
  # and failed when its seeded run's fault went uncaught.
  def test_a_boots_suite_cell_comes_from_its_record_and_its_seeded_run
    assert_equal 'passed', Suite.boot_cell(wake_record(1, 'cross-cpu', 'unsupported'), seed_caught: true, refused: [])
    # A refused line may have been a failure, so the boot is at best partial.
    assert_equal 'partial', Suite.boot_cell(wake_record(1, 'cross-cpu', 'unsupported'), seed_caught: true,
                                                                                     refused: ['BENCH line is long'])
    assert_equal 'partial', Suite.boot_cell(wake_record(4, 'cross-cpu', 'unsupported'), seed_caught: true, refused: [])
    assert_equal 'not_run', Suite.boot_cell(wake_record(4, 'cross-cpu', 'not_run'), seed_caught: true, refused: [])
    assert_equal 'failed', Suite.boot_cell(wake_record(1, 'cross-cpu', 'unsupported'), seed_caught: false, refused: [])
  end

  # A benchmark whose landing raises is a failed cell with its message as a note, and the
  # others' cells stand.
  def test_a_failing_benchmark_fails_only_its_own_cell
    record = wake_record(4, 'cross-cpu', 'not_run')
    landing = lambda do |declared, **|
      raise Erx::Error, "the guest says \"erx: bench: no task FAILED\"\e[2J" if declared.name == 'nullcall'

      { record: record, written: nil, refused: [], seeds_missed: [] }
    end
    xdomain = ->(*, **) { { record: record, written: nil, refused: [] } }
    answer = Suite.run(Struct.new(:root).new('/nonexistent'), history: '/nonexistent', native: landing, xdomain: xdomain)
    assert_equal 'failed', answer.fetch(:cells).fetch('hvf-4cpu-native-nullcall')
    assert_equal 'not_run', answer.fetch(:cells).fetch('hvf-4cpu-native-wake')
    assert_equal 'pending', answer.fetch(:cells).fetch('hvf-4cpu-xdomain-wake')
    failure = answer.fetch(:notes).grep(/nullcall: failed: /).first
    assert_match(/no task FAILED/, failure)
    refute_includes failure, "\e"
  end

  private

  # A record of wake-cross-cpu alone, booted at cpus CPUs.
  def wake_record(cpus, placement, status)
    conditions = Erx::BenchRecord::Conditions.new(load: 'idle', placement: placement, parameters: {}, clock: 'counter',
                                                  batch: 1)
    cell = Erx::BenchRecord::Cell.new(benchmark: 'wake', operation: 'wake-cross-cpu', conditions: conditions,
                                      profile: Erx::BenchRecord::Profile.new(name: 'fast', warmup: 1, samples: 1, runs: 1),
                                      status: status, reason: 'the machine has one CPU',
                                      counts: { 'lost' => 0, 'early' => 0, 'missed' => 0 }, detail: {})
    Erx::BenchRecord::Record.new(
      environment: Erx::BenchRecord::Environment.new(kind: 'qemu-hvf', model: 'Mac16,10', cpus: cpus, system: nil, details: {}),
      subject: Erx::BenchRecord::Subject.new(revision: '0' * 40, dirty: false, details: {}),
      run: Erx::BenchRecord::Run.new(date: Time.at(0).utc, started_by: 'landing', load: nil, host_cpus: nil, reused_from: nil),
      clock: {}, cells: [cell]
    )
  end
end
