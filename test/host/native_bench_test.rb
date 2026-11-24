# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/native_bench'
require_relative '../../tools/lib/erx/bench_suite'
require_relative '../../tools/fuzz/bench_line'

# What the native bench runner takes from a boot's serial log (docs/design-bench.md,
# "1. `wake`: how late a waiting thread runs"): only the guest's BENCH and CLOCK lines reach BenchMeasurement.boot, whole
# and without their line ends, and each operation is judged at its profile's landing form.
class NativeBenchTest < Minitest::Test
  def test_only_the_guests_lines_reach_the_judge_without_their_line_ends
    bench = Erx::BenchLineFuzz.line('wake-same-cpu')
    clock = Erx::BenchLineFuzz.clock_line
    serial = "Fiasco says BENCH {}\r\nerx: bench: timing\r\n#{bench}\r\n #{clock}\n#{clock}\nBENCHMARK x\n"
    assert_equal [bench, clock], Erx::NativeBench.guest_lines(serial)
  end

  def test_each_native_operation_is_judged_at_its_landing_profile
    profiles = Erx::NativeBench.profiles(Erx::BenchSuite.benchmark('wake'))
    assert_equal [10_000, 10_000, 10_000, 2000],
                 %w[wake-same-cpu wake-cross-cpu trigger-take park-deadline].map { |name| profiles.fetch(name).samples }
  end
  # The native image's root runs on CPU 0 and times wake-cross-cpu against the last CPU,
  # so a boot of n CPUs calibrates that one pair, and a boot of one CPU none.
  def test_the_boot_asks_for_the_native_cells_on_the_counter_and_the_last_cpus_pair
    wake = Erx::BenchSuite.benchmark('wake')
    asked = Erx::NativeBench.asked(wake, cpus: 4)
    assert_equal wake.landing.fetch('native'), asked.cells.map(&:last)
    assert_equal ['counter', [[0, 3]]], [asked.clock, asked.pairs]
    assert_equal [], Erx::NativeBench.asked(wake, cpus: 1).pairs
  end

  def cell(benchmark, operation, status, lost: 0, reason: 'lost wake')
    Erx::BenchRecord::Cell.new(
      benchmark: benchmark, operation: operation, profile: Erx::NativeBench::LANDING_PROFILES.fetch('fast'),
      conditions: Erx::BenchRecord::Conditions.new(load: 'idle', placement: 'same-cpu', parameters: {}, clock: 'counter', batch: 1),
      status: status, reason: status == 'failed' ? reason : 'the guest printed no line for it',
      counts: { 'lost' => lost, 'early' => 0, 'missed' => 0 }, detail: {}
    )
  end

  def seed(benchmark, name) = Erx::NativeBench.guest(benchmark).seeds.find { |declared| declared.name == name }

  # The seeded build skips one wake of wake-same-cpu: only that cell failed with a lost
  # wake shows the run caught it.
  def test_the_seeded_boot_is_caught_only_by_a_lost_wake_of_wake_same_cpu
    caught = seed('wake', 'lost wake').caught
    assert caught.call([cell('wake', 'wake-same-cpu', 'failed', lost: 1), cell('wake', 'trigger-take', 'not_run')])
    refute caught.call([cell('wake', 'wake-same-cpu', 'not_run')])
    refute caught.call([cell('wake', 'wake-cross-cpu', 'failed', lost: 1)])
    refute caught.call([])
  end

  # Each nullcall seed sends one caller's requests to the empty slot: only that caller's
  # cells failing by their count of refusals shows it, not a wrong result.
  def test_each_nullcall_seed_is_caught_only_by_its_callers_failed_cells
    root = seed('nullcall', 'root refusal to the empty slot')
    task = seed('nullcall', 'task refusal to the empty slot')
    assert_equal [[Erx::NativeBench::SEED_EMPTY_SLOT], []], [root.root_flags, root.task_flags]
    assert_equal [[], [Erx::NativeBench::SEED_EMPTY_SLOT]], [task.root_flags, task.task_flags]
    uncounted = ->(operation) { cell('nullcall', operation, 'failed', reason: Erx::NativeBench::NULLCALL_UNCOUNTED) }
    assert root.caught.call([uncounted.call('root-same-space')])
    refute root.caught.call([cell('nullcall', 'root-same-space', 'not_run'), uncounted.call('root-cross-space')])
    refute root.caught.call([cell('nullcall', 'root-same-space', 'failed', reason: 'wrong result')])
    assert task.caught.call([uncounted.call('root-cross-space')])
    refute task.caught.call([cell('nullcall', 'root-cross-space', 'not_run'), uncounted.call('root-same-space')])
    refute task.caught.call([cell('nullcall', 'root-cross-space', 'failed', reason: 'wrong result')])
  end

  # The vm seed makes the task's protects answer ERX_OK without calling the service: only
  # protect failing because its disposable task's write went through shows it, not a
  # failed untimed check or another cell.
  def test_the_vm_seed_is_caught_only_by_an_unfaulted_protect
    ignored = seed('vm', 'protect ignored')
    assert_equal [[], [Erx::NativeBench::SEED_PROTECT_IGNORED]], [ignored.root_flags, ignored.task_flags]
    unfaulted = ->(operation) { cell('vm', operation, 'failed', reason: Erx::NativeBench::VM_UNFAULTED) }
    assert ignored.caught.call([cell('vm', 'commit', 'not_run'), unfaulted.call('protect')])
    refute ignored.caught.call([cell('vm', 'protect', 'failed', reason: 'the untimed check failed')])
    refute ignored.caught.call([unfaulted.call('commit')])
    refute ignored.caught.call([cell('vm', 'protect', 'not_run')])
  end

  # Every benchmark with native landing cells has a guest, and only those do.
  def test_each_native_benchmark_has_a_guest
    native = Erx::BenchSuite.benchmarks.values.select { |declared| declared.landing.key?('native') }.map(&:name)
    assert_equal native.sort, Erx::NativeBench::GUESTS.keys.sort
  end

  # The guest's sample counts are the landing profiles' (one source): the root is built
  # with them, and a seeded build adds only its fault.
  def test_the_root_is_built_with_the_landing_profiles_sizes
    fast, periodic, sustained = Erx::NativeBench::LANDING_PROFILES.values_at('fast', 'periodic', 'sustained')
    sizes = ["-DERX_BENCH_FAST_WARMUP=#{fast.warmup}u", "-DERX_BENCH_FAST_SAMPLES=#{fast.samples}u",
             "-DERX_BENCH_PERIODIC_SAMPLES=#{periodic.samples}u", "-DERX_BENCH_SUSTAINED_SAMPLES=#{sustained.samples}u",
             "-DERX_BENCH_SUSTAINED_WARMUP_MS=#{sustained.warmup}u"]
    plain = Erx::NativeBench.flags
    assert_equal sizes, plain.grep(/SAMPLES|WARMUP/)
    assert_equal plain + ['-DERX_BENCH_SEED_LOST_WAKE'], Erx::NativeBench.flags(seeded: seed('wake', 'lost wake').root_flags)
  end
end
