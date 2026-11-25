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

  # Every image packs test/guest/native_task's program, which the root's cycle probe
  # launches before the cells (docs/design-bench.md, "The cycle counter"), beside the
  # guest's own timing task where it has one.
  def test_every_image_packs_the_cycle_probes_program
    native = Class.new do
      def build_task(name:, **) = "#{name}.elf"
    end.new
    run = Erx::NativeBench::Run.allocate
    packed = Erx::NativeBench::GUESTS.transform_values { |guest| run.send(:programs, native, guest, '/build', nil) }
    packed.each do |name, programs|
      assert_equal 'native-task.elf', programs[Erx::NativeTask::PROGRAM_PATH], name
      own = Erx::NativeBench::GUESTS.fetch(name).task.empty? ? [] : [Erx::NativeBench::TASK_PATH]
      assert_equal [Erx::NativeTask::PROGRAM_PATH, *own].sort, programs.keys.sort, name
    end
  end

  # The guest's sample counts are the landing profiles' (one source): the root is built
  # with them, and a seeded build adds only its fault.
  def test_the_root_is_built_with_the_landing_profiles_sizes
    fast, expensive, periodic, sustained = Erx::NativeBench::LANDING_PROFILES.values_at('fast', 'expensive', 'periodic',
                                                                                        'sustained')
    sizes = ["-DERX_BENCH_FAST_WARMUP=#{fast.warmup}u", "-DERX_BENCH_FAST_SAMPLES=#{fast.samples}u",
             "-DERX_BENCH_EXPENSIVE_WARMUP=#{expensive.warmup}u", "-DERX_BENCH_EXPENSIVE_SAMPLES=#{expensive.samples}u",
             "-DERX_BENCH_PERIODIC_SAMPLES=#{periodic.samples}u", "-DERX_BENCH_SUSTAINED_SAMPLES=#{sustained.samples}u",
             "-DERX_BENCH_SUSTAINED_WARMUP_MS=#{sustained.warmup}u"]
    plain = Erx::NativeBench.flags
    assert_equal sizes, plain.grep(/SAMPLES|WARMUP/)
    assert_equal plain + ['-DERX_BENCH_SEED_LOST_WAKE'], Erx::NativeBench.flags(seeded: seed('wake', 'lost wake').root_flags)
  end
  # The guest ends its own boot at the landing form's deadline, and QEMU's deadline for the
  # boot is that number and a margin more, so a hung cell is ended by the guest first
  # (docs/design-bench.md, "The bench image's boot set"). A seed may build its root with a
  # deadline of its own, which its QEMU deadline then follows.
  def test_the_guests_deadline_is_compiled_in_and_qemus_follows_it
    deadline = Erx::NativeBench::LANDING_DEADLINE_SECONDS
    assert_equal ["-DERX_BENCH_DEADLINE_S=#{deadline}u"], Erx::NativeBench.flags.grep(/DEADLINE/)
    assert_equal ['-DERX_BENCH_DEADLINE_S=7u'], Erx::NativeBench.flags(deadline_seconds: 7).grep(/DEADLINE/)
    done = Erx::NativeBench.checkpoints(deadline_seconds: deadline).find { |point| point.fetch(:name) == 'bench-done' }
    assert_equal deadline + Erx::NativeBench::DEADLINE_MARGIN_SECONDS, done.fetch(:seconds)
    hang = seed('nullcall', 'hang after the first cell')
    assert_operator hang.deadline_seconds, :<, deadline
    assert_nil seed('wake', 'lost wake').deadline_seconds
  end

  # bench-done takes the root's two end forms of its naming line, done and deadline, and no
  # other line (docs/design-bench.md, "The boot name").
  def test_bench_done_takes_the_two_naming_end_forms
    done = Erx::NativeBench.checkpoints(deadline_seconds: 1).find { |point| point.fetch(:name) == 'bench-done' }.fetch(:pattern)
    name = Erx::NativeBench::QEMU_BOOT_NAME
    # Each line as Qemu's transcript gives it to a checkpoint, with its line end.
    assert_match done, "erx: bench: boot #{name} done\n"
    assert_match done, "erx: bench: boot #{name} deadline\r\n"
    ["erx: bench: boot #{name}\n", "erx: bench: done\n", "erx: bench: boot #{name[1..]} done\n",
     "erx: bench: boot #{name} donee\n", "x erx: bench: boot #{name} done\n"].each { |line| refute_match done, line }
  end

  # A seeded boot's cells are judged as the landing boot's are: those a boot the guest
  # ended at its deadline did not report are timed_out, not not_run.
  def test_a_runs_unreported_cells_are_timed_out_only_when_the_guests_deadline_ended_it
    asked = Erx::NativeBench.asked(Erx::BenchSuite.benchmark('nullcall'), cpus: 4)
    ended = ->(timed_out) { Erx::NativeBench.cells({ lines: [], timed_out: timed_out }, asked).map(&:status).uniq }
    assert_equal ['timed_out'], ended.call("the guest's deadline ended the boot")
    assert_equal ['not_run'], ended.call(nil)
  end

  # Under QEMU every boot is named with thirty-two zeros on its command line, and a boot
  # the guest ended at its deadline is timed out, so its unreported cells are timed_out.
  def test_a_boot_ended_at_the_guests_deadline_is_timed_out
    name = Erx::NativeBench::QEMU_BOOT_NAME
    assert_equal "erx.arg=#{'0' * 32}", Erx::NativeBench::QEMU_COMMAND_LINE
    assert_match(/deadline/, Erx::NativeBench.timed_out("erx: bench: boot #{name}\nerx: bench: boot #{name} deadline\r\n"))
    assert_nil Erx::NativeBench.timed_out("erx: bench: boot #{name}\nerx: bench: boot #{name} done\r\n")
  end

  # The hang seed spins after the root reports nullcall's first cell: the boot ends at the
  # guest's deadline with that cell rejected, since no CLOCK line followed it, and every
  # later cell timed_out.
  def test_the_hang_seed_is_caught_only_by_the_first_cell_rejected_and_the_rest_timed_out
    caught = seed('nullcall', 'hang after the first cell').caught
    assert caught.call([cell('nullcall', 'root-same-space', 'rejected'), cell('nullcall', 'root-cross-space', 'timed_out')])
    refute caught.call([cell('nullcall', 'root-same-space', 'timed_out'), cell('nullcall', 'root-cross-space', 'timed_out')])
    refute caught.call([cell('nullcall', 'root-same-space', 'rejected'), cell('nullcall', 'root-cross-space', 'rejected')])
    refute caught.call([cell('nullcall', 'root-same-space', 'failed'), cell('nullcall', 'root-cross-space', 'timed_out')])
  end

  # Every end of the bench root is a reset; one that ends off has halted a board, and a
  # boot whose serial log holds no end did not end the machine.
  def test_only_a_boot_that_ends_with_a_reset_passes_its_end
    assert_nil Erx::NativeBench.check_end("erx: bench: boot #{NAME} done\r\nerx: end reset\r\n")
    error = assert_raises(Erx::Error) { Erx::NativeBench.check_end("erx: bench: boot #{NAME} done\r\nerx: end off\r\n") }
    assert_match(/end off.*power needs cycling/, error.message)
    assert_raises(Erx::Error) { Erx::NativeBench.check_end("erx: bench: boot #{NAME} done\r\n") }
    assert_raises(Erx::Error) { Erx::NativeBench.check_end("erx: end reset\r\nerx: end off\r\n") }
  end

  # Each BENCH and CLOCK line falls between two naming lines, and every naming line
  # carries the boot's name.
  def test_a_cells_line_outside_the_naming_lines_or_another_name_breaks_the_naming
    named = "erx: bench: boot #{NAME}\r\n"
    good = "banner\n#{named}erx: bench: timing\nBENCH {}\n#{named}CLOCK {}\r\nerx: bench: boot #{NAME} done\r\nerx: end reset\n"
    assert_empty Erx::NativeBench.misnamed_lines(good, name: NAME)
    assert_equal ['BENCH {}'], Erx::NativeBench.misnamed_lines("BENCH {}\n#{named}#{named}", name: NAME)
    assert_equal ['CLOCK {}'], Erx::NativeBench.misnamed_lines("#{named}CLOCK {}\n", name: NAME)
    other = "erx: bench: boot #{'f' * 32} done"
    assert_equal [other], Erx::NativeBench.misnamed_lines("#{named}BENCH {}\n#{other}\n", name: NAME)
    assert_equal ['BENCH {}'], Erx::NativeBench.misnamed_lines("BENCH {}\n", name: NAME)
    broken = "erx: bench: boot #{NAME} donefoo"
    assert_equal [broken], Erx::NativeBench.misnamed_lines("#{named}BENCH {}\n#{named}#{broken}\n", name: NAME)
  end

  # An entry's cmdline.txt is its set's line and the name's word, or the word alone.
  def test_an_entrys_command_line_follows_its_sets_line_with_the_name
    assert_equal "erx.hostlink=1 erx.arg=#{NAME}", Erx::NativeBench.entry_command_line('erx.hostlink=1', NAME)
    assert_equal "erx.arg=#{NAME}", Erx::NativeBench.entry_command_line(nil, NAME)
    assert_equal "erx.arg=#{NAME}", Erx::NativeBench.entry_command_line('', NAME)
    assert_raises(Erx::Error) { Erx::NativeBench.entry_command_line(nil, NAME.upcase) }
    assert_raises(Erx::Error) { Erx::NativeBench.entry_command_line(nil, "#{NAME} erx.hostlink=0") }
  end

  # Only a board whose medium is a boot partition has a set.
  def test_qemu_virt_has_no_board_set
    root = File.expand_path('../..', __dir__)
    assert_raises(Erx::Error) { Erx::NativeBench::BoardSets.new(root: root, platform: Erx::Platform.development(root)) }
  end

  NAME = '0123456789abcdef' * 2
end
