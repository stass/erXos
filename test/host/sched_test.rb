# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/sched_model'
require_relative '../../tools/lib/erx/runner'

# Judges the scheduler core (kernel/sched/sched.c) against SchedModel. The
# driver runs command scripts through the core and prints each decision and
# the whole state; the model predicts each line, and the tests below also pin
# the design's rules as literal values. Bounds: random machines of at most 12
# groups on paths up to ERX_GROUP_DEPTH_MAX deep and 10 threads over 4 CPUs,
# 120 scripts of 90 commands each; and every sequence of up to four of
# EXHAUSTIVE_STEPS from one small machine (2 groups, 3 threads, 2 CPUs).
class SchedTest < Minitest::Test
  SEED = Integer(ENV.fetch('ERX_SCHED_SEED', '20261103'))
  M = SchedModel
  ALL = M::FLAGS_DEFINED
  BLOCKED = M::BLOCKED
  SLICE_END = M::SLICE_END
  YIELD = M::YIELD
  PREEMPTED = M::PREEMPTED
  STATUS_FLAG = M::CODEC.constant('group_status')

  EXHAUSTIVE_SETUP = ['machine 0', "root #{M.grant(cpuset: 3)}", "group 0 #{M.grant(ceiling: 10, base: 10)}",
                      'thread 1', 'thread 1', 'thread 0'].freeze
  EXHAUSTIVE_STEPS = ['wake 0 0', 'wake 0 1', 'wake 1 2', 'wake 0 2', "pick 0 #{BLOCKED} 100",
                      "pick 0 #{SLICE_END} 0", "pick 0 #{YIELD} 2000", "pick 0 #{PREEMPTED} 6000", "pick 1 #{BLOCKED} 50",
                      'remove 0 0', 'refresh 0 0', 'refresh 0 1', 'refresh 1 2',
                      "configure 1 #{M.grant(ceiling: 2, cpuset: 2, slice: 1000)}", 'urgency 1 20',
                      'affinity 0 2'].freeze

  # Edge values of each grant field, so normalization's every side is reached.
  QUOTAS = [M::QUOTA_NONE, 0, 1, 999_999, 5_000_000, 1 << 40, M::QUOTA_NONE - 1].freeze
  PERIODS = [0, 1, 1_000_000, 10_000_000, 1_000_000_000, 1_000_000_001, (1 << 64) - 1].freeze
  CPUSETS = [0, 1, 2, 3, 5, 8, 12, 15, 0xf0, (1 << 64) - 1].freeze
  SLICES = [0, 499, 500, 5000, 50_000, 50_001, (1 << 32) - 1].freeze
  GRACES = [0, 4, 5, 50, 1000, 1001].freeze
  URGENCIES = [0, 1, 15, 16, 31, 62, 63].freeze

  # One-line edits of the core, each a failure the design says tests catch.
  MUTANTS = {
    'ceiling reads its own group alone' => ["level = level->parent) {\n\t\tceiling = min_u8",
                                            "level = NULL) {\n\t\tceiling = min_u8"],
    'resolve forgets the ceiling' => ['urgency.raw = min_u8(base, path_ceiling(thread->group));',
                                      'urgency.raw = base;'],
    'an empty intersection stays empty' => ["if (narrowed != 0)\n\t\t\teffective = narrowed;",
                                            'effective = narrowed;'],
    'a child widens its parent' => ['narrowed = effective & cpusets[--n];', 'narrowed = cpusets[--n];'],
    'affinity has no fallback' => ['return (allowed != 0 ? allowed : effective);',
                                   'return (allowed != 0 ? allowed : 1);'],
    'flags escape the cap' => ['grant.flags &= cap;', '(void)cap;'],
    'an undefined flag passes' => ['(grant.flags & (erx_group_flags_t)~GROUP_FLAGS_DEFINED) != 0', '0'],
    'padding passes' => ['if (grant.padding_0[i] != 0)', 'if (0)'],
    'an urgency above the maximum passes' => ['if (grant.base.raw > ERX_URGENCY_MAX ||', 'if ('],
    'base stays above the ceiling' => ['grant.base.raw = min_u8(grant.base.raw, grant.ceiling.raw);', ''],
    'period stays unclamped' => ["grant.period_ns = clamp_u64(grant.period_ns, ERX_PERIOD_MIN,\n\t    ERX_PERIOD_MAX);",
                                 'grant.period_ns |= 1;'],
    'slice stays unclamped' => ["grant.slice_us = clamp_u32(grant.slice_us, ERX_SLICE_MIN_US,\n\t    ERX_SLICE_MAX_US);",
                                ''],
    'grace stays unclamped' => ["grant.grace_us = clamp_u32(grant.grace_us, ERX_GRACE_MIN_US,\n\t    ERX_GRACE_MAX_US);",
                                ''],
    'root misses the machine at creation' => ["if ((grant.cpuset & machine) == 0)\n\t\treturn (ERX_EINVAL);\n\troot->parent", 'root->parent'],
    'root configured off the machine' => ['if (group->parent == NULL && (grant.cpuset & group->machine) == 0)', 'if (0)'],
    'the machine does not bound the root' => ['effective = level->machine & cpusets[--n];', 'effective = cpusets[--n];'],
    'a leaving slice end keeps the old slice' => ["if (why == ERX_PICK_SLICE_END)\n\t\tthread->slice_left_ns = 0;\n\tcpu->running = NULL;",
                                                  "if (why == ERX_PICK_SLICE_END && may_run_here(cpu, thread))\n\t\tthread->slice_left_ns = 0;\n\tcpu->running = NULL;"],
    'depth allows one level too many' => ['parent->depth + 1 >= ERX_GROUP_DEPTH_MAX', 'parent->depth + 1 > ERX_GROUP_DEPTH_MAX'],
    'a wake preempts an equal urgency' => ['urgency > cpu->running->urgency', 'urgency >= cpu->running->urgency'],
    'a wake joins a thread twice' => ["SCHED_WHERE_OFF)\n\t\treturn (false);\n\tthread->urgency",
                                      "SCHED_WHERE_OFF) {}\n\tthread->urgency"],
    'a wake stores nothing' => ["thread->urgency = erx_sched_resolve(thread).raw;\n\tthread_set_here(thread, cpu, SCHED_THREAD_READY);\n\tfifo_append", "thread_set_here(thread, cpu, SCHED_THREAD_READY);\n\tfifo_append"],
    'a rejoining thread keeps its old urgency' => ["thread->urgency = erx_sched_resolve(thread).raw;\n\tthread_set_here(thread, cpu, SCHED_THREAD_READY);\n\t/*", "thread_set_here(thread, cpu, SCHED_THREAD_READY);\n\t/*"],
    'a refresh leaves a ready thread on its old level' => ['if (thread->urgency != old) {', 'if (0) {'],
    'an unchanged urgency loses its place' => ['if (thread->urgency != old) {', 'if (1) {'],
    'a refreshed thread takes the head of its level' => ["fifo_unlink(cpu, thread, old);\n\t\tfifo_append(cpu, thread);", "fifo_unlink(cpu, thread, old);\n\t\tfifo_prepend(cpu, thread);"],
    'a refresh of a running thread ignores the cpu' => ['if (where == sched_where(SCHED_THREAD_RUNNING, cpu->index)) {', 'if (sched_where_state(where) == SCHED_THREAD_RUNNING) {'],
    'a refresh of a running thread stores nothing' => ["{\n\t\tthread->urgency = erx_sched_resolve(thread).raw;\n\t\treturn (ready_outranks", "{\n\t\treturn (ready_outranks"],
    'a running thread a ready one outranks stays' => ['return (ready_outranks(cpu, thread->urgency));', 'return (false);'],
    'an equal ready level preempts a refreshed thread' => ['highest_level(cpu) > urgency', 'highest_level(cpu) >= urgency'],
    'a raised ready thread does not preempt' => ["}\n\treturn (must_pick(cpu, thread->urgency));\n}\n\nbool\nerx_sched_remove", "}\n\treturn (false);\n}\n\nbool\nerx_sched_remove"],
    'a refresh acts on another cpu' => ["if (where != sched_where(SCHED_THREAD_READY, cpu->index))\n\t\treturn (false);", "if (sched_where_state(where) != SCHED_THREAD_READY)\n\t\treturn (false);"],
    'a refresh of a sleeper stores' => ["if (where != sched_where(SCHED_THREAD_READY, cpu->index))\n\t\treturn (false);", "if (where != sched_where(SCHED_THREAD_READY, cpu->index)) {\n\t\tthread->urgency = erx_sched_resolve(thread).raw;\n\t\treturn (false);\n\t}"],
    'a finite quota stays uncapped' => ["grant.quota_ns = min_u64(grant.quota_ns,\n\t\t    grant.period_ns * cpuset_size(machine));", ';'],
    'no quota caps too' => ['if (grant.quota_ns != ERX_QUOTA_NONE)', 'if (1)'],
    'a group caps its quota by no machine' => ['for (level = group; level->parent != NULL; level = level->parent)', 'for (level = group; 0; level = level->parent)'],
    'a preempted thread joins the tail' => ['fifo_prepend(cpu, thread);', 'fifo_append(cpu, thread);'],
    'a slice end rejoins the head' => ['if (why == ERX_PICK_PREEMPTED && thread->slice_left_ns != 0)',
                                       'if (thread->slice_left_ns != 0)'],
    'a slice end keeps the old slice' => ["if (why == ERX_PICK_SLICE_END)\n\t\tthread->slice_left_ns = 0;\n", ''],
    'a preempted thread at no slice takes the head' => ['if (why == ERX_PICK_PREEMPTED && thread->slice_left_ns != 0)',
                                                        'if (why == ERX_PICK_PREEMPTED)'],
    'the rest of a slice outlives a smaller grant' => ['thread->slice_left_ns != 0 && thread->slice_left_ns < slice_ns',
                                                       'thread->slice_left_ns != 0'],
    'no time is taken from the slice' => ['thread->slice_left_ns - ran_ns : 0;', 'thread->slice_left_ns : 0;'],
    'a pick has no bound' => ['if (moves == ERX_PICK_MOVES) {', 'if (moves == 1000) {'],
    'a thread that left stays eligible here' => ['if (may_run_here(cpu, thread)) {', 'if (1) {'],
    'a running thread that left stays' => ["if (!may_run_here(cpu, thread)) {\n\t\tdecision_add_leaving(decision, thread);\n\t\treturn;\n\t}\n", ''],
    'place prefers the lowest over the last' => ["if (cpuset_has(allowed_idle, last))\n\t\treturn (last);", ''],
    'place ignores idleness' => ['allowed_idle = allowed & idle;', 'allowed_idle = allowed & idle & 0;'],
    'capacity ignores the cpuset' => ['limit = cpus * MCPU_PER_CPU;', 'limit = UINT64_MAX;'],
    'capacity ignores the quota' => ['if (quota_ns != ERX_QUOTA_NONE)', 'if (0)'],
    'first position not wrapped' => ["memory_order_relaxed) % cpus;", 'memory_order_relaxed);']
  }.freeze

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-sched-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported sched-test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    @sanitizer_flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def driver
    @driver ||= build_driver(File.join(@root, 'kernel/sched/sched.c'), name: 'sched', flags: @sanitizer_flags)
  end

  def test_random_operations_agree_with_the_model
    $stdout.puts("sched_test: random operations from seed #{SEED} (set ERX_SCHED_SEED to change it)")
    lines = assert_agrees(random_scripts(count: 120, length: 90, rng: Random.new(SEED)))
    assert_reaches_every_case(lines)
  end

  def test_every_short_sequence_from_a_small_machine_agrees
    scripts = EXHAUSTIVE_STEPS.repeated_permutation(4).map do |steps|
      EXHAUSTIVE_SETUP + steps + ['state']
    end
    assert_equal EXHAUSTIVE_STEPS.size**4, scripts.size
    assert_agrees(scripts)
  end

  def test_a_grant_is_refused_only_for_what_it_cannot_mean
    assert_equal M::EINVAL, status(result(["normalize #{M.grant(base: 64)}"]))
    assert_equal M::EINVAL, status(result(["normalize #{M.grant(ceiling: 64)}"]))
    assert_equal M::EINVAL, status(result(["normalize #{M.grant(base: 255, ceiling: 255)}"]))
    assert_equal M::EINVAL, status(result(["normalize #{M.grant(flags: 0x10)}"]))
    assert_equal M::EINVAL, status(result(["normalize #{M.grant(flags: 0x8000)}"]))
    assert_equal M::EINVAL, status(result(["normalize #{M.grant(padding: 1 << 24)}"]))
    assert_equal 0, status(result(["normalize #{M.grant(quota: 0, cpuset: 0, mcpu: 0, base: 63, ceiling: 63)}"]))
  end

  def test_every_limit_a_grant_sets_alone_is_clamped
    line = result(["normalize #{M.grant(period: 0, slice: 0, grace: 0, base: 40, ceiling: 30)}"])
    assert_equal '= 0 18446744073709551615,1000000,15,4000,0,500,5,30,30,0', line
    line = result(["normalize #{M.grant(period: 1 << 40, slice: 1 << 31, grace: 1 << 31, base: 1, ceiling: 2)}"])
    assert_equal '= 0 18446744073709551615,1000000000,15,4000,0,50000,1000,1,2,0', line
  end

  def test_normalizing_a_normalized_grant_changes_nothing
    raw = PERIODS.product(SLICES, GRACES).map do |period, slice, grace|
      "normalize #{M.grant(period: period, slice: slice, grace: grace, base: 50)}"
    end
    once = drive(raw)
    twice = drive(once.map do |line|
      quota, period, cpuset, mcpu, first, slice, grace, base, ceiling, flags =
        line.delete_prefix('= 0 ').split(',').map { |field| Integer(field) }
      grant = M.grant(quota: quota, period: period, cpuset: cpuset, mcpu: mcpu, first: first, slice: slice,
                      grace: grace, base: base, ceiling: ceiling, flags: flags)
      "normalize #{grant}"
    end)
    assert_equal once, twice
  end

  def test_c0_caps_every_flag_and_a_wider_cap_keeps_what_it_allows
    (0..ALL).each do |flags|
      line = result(['machine 0', "normalize #{M.grant(flags: flags)}"])
      assert_match(/,0\z/, line, "C0 clears flags #{flags}")
      kept = result(["machine #{STATUS_FLAG}", "normalize #{M.grant(flags: flags)}"])
      assert_equal flags & STATUS_FLAG, Integer(kept[/,(\d+)\z/, 1]), 'the cap selects, the group chooses'
    end
    assert_includes state_of(['machine 0', "root #{M.grant(flags: ALL)}"]), 'g0:31,16,15,5000000,4000,0/'
    assert_match(%r{/[^ ]*,16,31,0(?: |\z)}, state_of(['machine 0', "root #{M.grant(flags: ALL)}"]))
  end

  # S5: every limit on a path binds, and the deepest allowed path walks whole.
  def test_urgency_is_clamped_to_the_least_ceiling_on_the_path
    script = ['machine 0', "root #{M.grant(ceiling: 40)}", "group 0 #{M.grant(ceiling: 50)}",
              "group 1 #{M.grant(ceiling: 20)}", "group 2 #{M.grant(ceiling: 63, base: 60)}", 'thread 3', 'thread 1',
              'urgency 1 63']
    state = state_of(script)
    assert_includes state, 't0:20,', 'the group base beneath the middle ceiling'
    assert_includes state, 't1:40,', 'an own base beneath the root ceiling'
    assert_includes state, 'g3:20,20,', 'the group limits, derived'
  end

  def test_an_own_base_outranks_the_group_base_and_cannot_be_raised_past_the_maximum
    assert_includes state_of(base_machine + ['urgency 0 5']), 't0:5,'
    assert_equal M::EINVAL, status(drive(base_machine + ['urgency 0 64']).grep(/\A= /).last)
    assert_includes state_of(base_machine + ['urgency 0 5', 'urgency 0 64']), 't0:5,', 'a refusal changes nothing'
  end

  # S5: an ancestor's change reaches each descendant by its refresh, ready or
  # running, and a pick moves nothing for its urgency.
  def test_an_ancestor_change_reaches_a_thread_by_its_refresh
    script = base_machine + ['thread 1', 'thread 1', 'wake 0 0', 'wake 0 1', 'wake 0 2', "pick 0 #{BLOCKED} 0",
      "configure 0 #{M.grant(ceiling: 3, base: 1)}"]
    assert_includes state_of(script), 't0:3,', 'resolving reads the grants as they are'
    assert_includes state_of(script), 'c0:0,10000;16=1+2', 'the queues wait for the refresh'
    lines = drive(script + ['refresh 0 1', 'refresh 0 2', 'refresh 0 0', 'state', "pick 0 #{SLICE_END} 0"])
    assert_equal ['= 0', '= 0', '= 0'], lines[-5, 3]
    assert_includes lines[-2], 'c0:0,8;3=1+2', 'moved to their new level in refresh order'
    assert_match(/run=1 urgency=3 /, lines[-1])
  end

  # A raised urgency is not left behind a more urgent thread: the pick examines
  # only the head of the highest level, so the refresh has to move it.
  def test_a_raised_urgency_is_seen_behind_a_more_urgent_thread
    script = ['machine 0', "root #{M.grant(ceiling: 63)}", 'thread 0', 'thread 0', 'urgency 1 30', 'wake 0 0', 'wake 0 1',
      'urgency 0 40', 'refresh 0 0']
    assert_equal '= 1', result(script), 'an idle CPU must pick'
    assert_includes state_of(script), 'c0:-,10040000000;30=1;40=0'
    assert_match(/run=0 urgency=40 /, result(script + ["pick 0 #{BLOCKED} 0"]))
    assert_includes state_of(script + ['urgency 1 40', 'refresh 0 1']), ';40=0+1', 'a refreshed thread joins the tail'
  end

  def test_a_raised_ceiling_reaches_a_ready_thread_by_its_refresh
    script = ['machine 0', "root #{M.grant(ceiling: 5, base: 5)}", 'thread 0', 'urgency 0 30', 'wake 0 0']
    assert_includes state_of(script), 't0:5,'
    assert_includes state_of(script), 'c0:-,20;5=0'
    lines = drive(script + ["configure 0 #{M.grant(ceiling: 40, base: 5)}", 'refresh 0 0', "pick 0 #{BLOCKED} 0"])
    assert_match(/run=0 urgency=30 /, lines.last)
  end

  # What a refresh tells the caller: a ready thread that outranks what runs, or
  # a running thread that a ready one now outranks, but not an equal.
  def test_a_refresh_says_when_the_cpu_must_pick
    script = ['machine 0', "root #{M.grant(ceiling: 63)}", 'thread 0', 'thread 0', 'urgency 0 30', 'urgency 1 20',
      'wake 0 0', "pick 0 #{BLOCKED} 0", 'wake 0 1']
    assert_equal '= 0', result(script + ['refresh 0 1']), 'it does not outrank what runs'
    assert_equal '= 0', result(script + ['urgency 1 30', 'refresh 0 1']), 'an equal does not preempt'
    assert_equal '= 1', result(script + ['urgency 1 31', 'refresh 0 1']), 'it outranks what runs'
    assert_equal '= 0', result(script + ['urgency 0 20', 'refresh 0 0']), 'an equal ready level does not preempt'
    assert_equal '= 1', result(script + ['urgency 0 19', 'refresh 0 0']), 'a ready thread outranks what runs'
    assert_match(/run=1 urgency=20 /, result(script + ['urgency 0 19', 'refresh 0 0', "pick 0 #{PREEMPTED} 0"]))
  end

  # A refresh acts only on the CPU that holds the thread; a sleeper resolves at
  # its wake, and a refresh on another CPU changes nothing.
  def test_a_refresh_changes_nothing_but_on_the_cpu_that_holds_the_thread
    script = base_machine + ['wake 0 0']
    assert_equal '= 0', result(script + ["configure 1 #{M.grant(base: 5, ceiling: 5)}", 'refresh 1 0'])
    assert_includes state_of(script + ["configure 1 #{M.grant(base: 5, ceiling: 5)}", 'refresh 1 0']), ';16=0'
    sleeping = base_machine + ["configure 1 #{M.grant(base: 5, ceiling: 5)}", 'refresh 0 0']
    assert_equal '= 0', result(sleeping)
    assert_includes state_of(sleeping + ['wake 0 0']), ';5=0', 'its wake resolves it'
  end

  # A pick never moves a thread for its urgency, whatever the grants say now.
  def test_a_pick_takes_the_head_of_the_highest_level_as_it_stands
    threads = (1..11).map { 'thread 1' }
    wakes = (0..11).map { |thread| "wake 0 #{thread}" }
    lines = drive(base_machine + threads + wakes + ["configure 1 #{M.grant(base: 5, ceiling: 5)}", "pick 0 #{BLOCKED} 0", 'state'])
    assert_match(/\A= run=0 urgency=16 slice=5000000 again=0 leaving=\z/, lines[-2])
    assert_includes lines[-1], ';16=1+2+3+4+5+6+7+8+9+10+11'
  end

  # A finite quota is capped at what the machine's CPUs can spend in a period,
  # so it fits a pool's int64_t; no quota stays none, and a smaller one as it is.
  def test_a_finite_quota_is_capped_at_the_machine_per_period
    quota = ->(**grant) { Integer(result(["normalize #{M.grant(**grant)}"])[/\A= 0 (\d+),/, 1]) }
    assert_equal 4_000_000, quota.call(quota: 1 << 62, period: 1_000_000)
    assert_equal 4_000_000_000, quota.call(quota: M::QUOTA_NONE - 1, period: 1 << 40), 'of the clamped period'
    assert_equal 4_000_000, quota.call(quota: 4_000_000, period: 1_000_000)
    assert_equal 3_999_999, quota.call(quota: 3_999_999, period: 1_000_000)
    assert_equal M::QUOTA_NONE, quota.call(quota: M::QUOTA_NONE, period: 1_000_000)
    assert_equal 0, quota.call(quota: 0)
    child = base_machine + ["configure 1 #{M.grant(quota: 1 << 62, period: 1_000_000)}", 'state']
    assert_includes drive(child).last, "/4000000,1000000,", 'on a group below the root too'
  end

  # S7: each level is a FIFO, a slice end goes to the tail with a fresh slice,
  # and a preempted thread keeps its turn and the rest of its slice.
  def test_round_robin_within_a_level
    script = base_machine + ['thread 1', 'thread 1', 'wake 0 0', 'wake 0 1', 'wake 0 2', "pick 0 #{BLOCKED} 0"]
    ran = (0...7).map do |turn|
      Integer(drive(script + (["pick 0 #{SLICE_END} 5000000"] * turn)).last[/run=(\d+)/, 1])
    end
    assert_equal [0, 1, 2, 0, 1, 2, 0], ran
  end

  def test_a_preempted_thread_keeps_its_turn_and_the_rest_of_its_slice
    script = base_machine + ['thread 1', 'wake 0 0', 'wake 0 1', "pick 0 #{BLOCKED} 0", 'thread 0', 'urgency 2 30']
    woken = drive(script + ['wake 0 2']).last
    assert_equal '= 1', woken, 'more urgent than the running thread: the CPU must pick'
    lines = drive(script + ['wake 0 2', "pick 0 #{PREEMPTED} 1000000", 'state', "pick 0 #{BLOCKED} 0"])
    assert_match(/run=2 urgency=30 /, lines[-3])
    assert_includes lines[-2], 't0:16,15,r,4000000,0', 'the rest of its slice'
    assert_includes lines[-2], ';16=0+1', 'the head of its level'
    assert_match(/run=0 urgency=16 slice=4000000 /, lines[-1])
  end

  def test_a_preempted_thread_with_no_slice_left_has_come_to_its_slice_end
    script = base_machine + ['thread 1', 'wake 0 0', 'wake 0 1', "pick 0 #{BLOCKED} 0", 'thread 0', 'urgency 2 30',
                             'wake 0 2', "pick 0 #{PREEMPTED} 5000000", "pick 0 #{BLOCKED} 0"]
    assert_match(/run=1 urgency=16 slice=5000000 /, drive(script).last)
  end

  def test_an_equal_or_lower_wake_never_preempts
    script = base_machine + ['thread 1', 'thread 0', 'urgency 2 2', 'wake 0 0', "pick 0 #{BLOCKED} 0"]
    assert_equal '= 0', drive(script + ['wake 0 1']).last
    assert_equal '= 0', drive(script + ['wake 0 2']).last
    assert_equal '= 1', drive(base_machine + ['wake 0 0']).last, 'an idle CPU picks for any wake'
  end

  def test_a_wake_of_a_ready_or_running_thread_joins_nothing
    running = base_machine + ['wake 0 0', "pick 0 #{BLOCKED} 0", 'wake 1 0']
    assert_equal '= 0', drive(running).last
    assert_includes state_of(running), 'c1:-,0', 'no queue took it'
    ready = base_machine + ['wake 0 0', 'wake 1 0']
    assert_includes state_of(ready), 'c0:-,10000;16=0'
    assert_includes state_of(ready), 'c1:-,0'
  end

  def test_remove_takes_only_a_thread_ready_here
    script = base_machine + ['wake 0 0']
    assert_equal '= 0', drive(script + ['remove 1 0']).last
    assert_equal '= 1', drive(script + ['remove 0 0']).last
    assert_equal '= 0', drive(script + ['remove 0 0', 'remove 0 0']).last
    assert_equal '= 0', drive(script + ["pick 0 #{BLOCKED} 0", 'remove 0 0']).last
    assert_includes state_of(script + ['remove 0 0']), 'c0:-,0'
  end

  def test_a_yield_with_nothing_else_ready_keeps_the_cpu_and_its_slice
    script = base_machine + ['thread 0', 'urgency 1 1', 'wake 0 0', "pick 0 #{BLOCKED} 0", 'wake 0 1',
                             "pick 0 #{YIELD} 2000000"]
    assert_match(/run=0 urgency=16 slice=3000000 /, drive(script).last, 'a lower level does not take its turn')
    with_peer = base_machine + ['thread 1', 'wake 0 0', 'wake 0 1', "pick 0 #{BLOCKED} 0", "pick 0 #{YIELD} 2000000"]
    assert_match(/run=1 /, drive(with_peer).last)
    assert_includes state_of(with_peer), 't0:16,15,r,3000000,0'
    assert_includes state_of(with_peer), 'c0:1,10000;16=0'
  end

  # A slice is the group's, bounded at each dispatch by the group's grant now.
  def test_slices_stay_within_bounds_and_within_the_grant_now
    assert_match(/slice=500000 /, drive(slice_script(0)).last)
    assert_match(/slice=500000 /, drive(slice_script(499)).last)
    assert_match(/slice=5000000 /, drive(slice_script(5000)).last)
    assert_match(/slice=50000000 /, drive(slice_script(50_000)).last)
    assert_match(/slice=50000000 /, drive(slice_script((1 << 32) - 1)).last)
    blocked = base_machine + ['wake 0 0', "pick 0 #{BLOCKED} 0", "pick 0 #{BLOCKED} 1000000"]
    assert_match(/slice=4000000 /, drive(blocked + ['wake 0 0', "pick 0 #{BLOCKED} 0"]).last,
                 'a blocked thread wakes with the rest of its slice')
    assert_match(/slice=2000000 /, drive(blocked + ["configure 1 #{M.grant(slice: 2000)}", 'wake 0 0',
                                                  "pick 0 #{BLOCKED} 0"]).last, 'cut to a smaller grant')
    assert_match(/slice=4000000 /, drive(blocked + ["configure 1 #{M.grant(slice: 9000)}", 'wake 0 0',
                                                  "pick 0 #{BLOCKED} 0"]).last, 'not grown by a larger one')
  end

  # S5, and the fallback a child cpuset gets when it misses its parent's.
  def test_a_cpuset_narrows_down_the_path_and_falls_back_when_empty
    script = ['machine 0', "root #{M.grant(cpuset: 0b111)}", "group 0 #{M.grant(cpuset: 0b011)}",
              "group 1 #{M.grant(cpuset: 0b100)}", "group 2 #{M.grant(cpuset: 0b001)}", "group 0 #{M.grant(cpuset: 0)}"]
    state = state_of(script)
    assert_includes state, 'g1:31,16,3,'
    assert_includes state, 'g2:31,16,3,', 'no meeting: the parent\'s'
    assert_includes state, 'g3:31,16,1,', 'narrowed by the fallback\'s result, not the raw one'
    assert_includes state, 'g4:31,16,7,', 'empty: the parent\'s'
  end

  def test_the_root_cpuset_can_never_be_empty
    assert_equal M::EINVAL, status(result(['machine 0', "root #{M.grant(cpuset: 0)}"]))
    assert_equal M::EINVAL, status(result(['machine 0', "root #{M.grant}", "configure 0 #{M.grant(cpuset: 0)}"]))
    assert_equal 0, status(result(['machine 0', "root #{M.grant}", "group 0 #{M.grant}",
                                   "configure 1 #{M.grant(cpuset: 0)}"]))
  end

  # Every effective cpuset is within the machine, so no decision names a
  # CPU that does not exist, whatever a grant says of the root.
  def test_the_machine_bounds_every_cpuset
    assert_equal M::EINVAL, status(result(['machine 0', "root #{M.grant(cpuset: 1 << 63)}"]))
    assert_equal M::EINVAL, status(result(['machine 0', "root #{M.grant}", "configure 0 #{M.grant(cpuset: 0xf0)}"]))
    script = ['machine 0', "root #{M.grant(cpuset: 0x1f)}", 'thread 0', 'affinity 0 16']
    assert_includes state_of(script), 'g0:31,16,15,', 'a CPU the machine lacks is no CPU'
    assert_includes state_of(script), 't0:16,15,', 'an affinity to it falls back'
    assert_equal '= 0', drive(script + ['place 0 16']).last
    refused = ['machine 0', "root #{M.grant}", 'thread 0', "configure 0 #{M.grant(cpuset: 0xf0)}", 'wake 0 0',
               "pick 0 #{BLOCKED} 0"]
    assert_match(/run=0 .*leaving=\z/, drive(refused).last, 'a refused grant strands nothing')
  end

  def test_a_slice_end_that_leaves_comes_back_with_a_fresh_slice
    script = base_machine + ['wake 0 0', "pick 0 #{BLOCKED} 0", 'affinity 0 2', "pick 0 #{SLICE_END} 1000", 'wake 1 0',
                             "pick 1 #{BLOCKED} 0"]
    assert_match(/run=0 urgency=16 slice=5000000 /, drive(script).last)
  end

  def test_home_names_the_cpu_that_holds_the_thread
    script = base_machine
    assert_includes state_of(script), 't0:16,15,o,0,64,64,'
    assert_includes state_of(script + ['wake 2 0']), 't0:16,15,r,0,64,2,'
    assert_includes state_of(script + ['wake 2 0', "pick 2 #{BLOCKED} 0"]), 't0:16,15,R,5000000,2,2,'
    assert_includes state_of(script + ['wake 2 0', "pick 2 #{BLOCKED} 0", "pick 2 #{BLOCKED} 0"]),
                    't0:16,15,o,5000000,2,64,'
  end

  def test_affinity_narrows_within_the_cpuset_and_falls_back_when_it_misses
    script = ['machine 0', "root #{M.grant(cpuset: 0b0111)}", "group 0 #{M.grant(cpuset: 0b0011)}", 'thread 1',
              'thread 1', 'thread 1', 'affinity 0 1', 'affinity 1 8', 'affinity 2 0']
    state = state_of(script)
    assert_includes state, 't0:16,1,', 'the mask within the group'
    assert_includes state, 't1:16,3,', 'no meeting: the group\'s'
    assert_includes state, 't2:16,3,', 'an empty mask: the group\'s'
  end

  # A pinned thread stays pinned inside a group whose own cpuset fell back
  # (the run ERTS pins its schedulers to is the effective cpuset's).
  def test_affinity_keeps_its_pin_inside_a_fallen_back_cpuset
    script = ['machine 0', "root #{M.grant(cpuset: 0b111)}", "group 0 #{M.grant(cpuset: 0b011)}",
              "group 1 #{M.grant(cpuset: 0b100)}", 'thread 2', 'affinity 0 1']
    assert_includes state_of(script), 't0:16,1,'
  end

  def test_a_thread_whose_cpu_left_its_set_moves_at_its_next_decision
    script = base_machine + ['thread 1', 'wake 0 0', 'wake 0 1', "pick 0 #{BLOCKED} 0", 'affinity 0 2']
    assert_includes state_of(script), 'c0:0,', 'running on until a decision'
    lines = drive(script + ["pick 0 #{SLICE_END} 0", 'state'])
    assert_match(/run=1 .* leaving=0\z/, lines[-2])
    assert_includes lines[-1], 't0:16,2,o,', 'on no queue, for the caller to place'
    queued = base_machine + ['thread 1', 'wake 0 0', 'wake 0 1', 'affinity 0 2', "pick 0 #{BLOCKED} 0"]
    assert_match(/run=1 .* leaving=0\z/, drive(queued).last)
    grant = base_machine + ['wake 0 0', "configure 1 #{M.grant(cpuset: 2)}", "pick 0 #{BLOCKED} 0"]
    assert_match(/run=- .* leaving=0\z/, drive(grant).last)
  end

  def test_a_blocked_thread_never_leaves
    script = base_machine + ['wake 0 0', "pick 0 #{BLOCKED} 0", 'affinity 0 2', "pick 0 #{BLOCKED} 0"]
    assert_match(/run=- .* leaving=\z/, drive(script).last)
  end

  def test_placement_follows_its_three_rules
    never_ran = base_machine + ['affinity 0 12']
    assert_equal '= 2', drive(never_ran + ['place 0 15']).last, 'the lowest allowed idle'
    assert_equal '= 3', drive(never_ran + ['place 0 9']).last
    assert_equal '= 2', drive(never_ran + ['place 0 0']).last, 'nothing idle, never ran: the lowest allowed'
    ran_on_three = base_machine + ['wake 3 0', "pick 3 #{BLOCKED} 0"]
    assert_equal '= 3', drive(ran_on_three + ['place 0 15']).last, 'the last CPU, idle'
    assert_equal '= 0', drive(ran_on_three + ['place 0 7']).last, 'the last CPU busy: the lowest idle'
    assert_equal '= 3', drive(ran_on_three + ['place 0 0']).last, 'nothing idle: the last CPU'
    moved = ran_on_three + ['affinity 0 6']
    assert_equal '= 1', drive(moved + ['place 0 15']).last, 'the last CPU left its set'
    assert_equal '= 1', drive(moved + ['place 0 0']).last, 'nothing idle and the last CPU left: the lowest'
  end

  # K13: however many threads may no longer run here, a pick moves at most
  # ERX_PICK_MOVES of them, and the next pick goes on from there.
  def test_a_pick_bound_stops_threads_leaving
    threads = (1..9).map { 'thread 1' }
    affinities = (0..9).map { |thread| "affinity #{thread} 2" }
    wakes = (0..9).map { |thread| "wake 0 #{thread}" }
    lines = drive(base_machine + threads + wakes + affinities + ["pick 0 #{BLOCKED} 0"])
    assert_equal '= run=- urgency=0 slice=0 again=1 leaving=0+1+2+3+4+5+6+7', lines.last
    lines = drive(base_machine + ['wake 0 0', "pick 0 #{BLOCKED} 0"] + threads + (1..9).map { |thread| "wake 0 #{thread}" } +
                (0..9).map { |thread| "affinity #{thread} 2" } + ["pick 0 #{SLICE_END} 0"])
    assert_equal '= run=- urgency=0 slice=0 again=1 leaving=0+1+2+3+4+5+6+7', lines.last, 'the outgoing counts'
  end

  # A thread that wakes on another CPU resolves the limits as they are then.
  def test_a_wake_resolves_the_limits_as_they_are
    assert_match(/run=0 urgency=5 /, drive(rewake_script).last)
  end

  def test_a_tree_is_refused_below_its_depth_limit
    script = ['machine 0', "root #{M.grant}"]
    script += (0...(M::DEPTH_MAX - 1)).map { |parent| "group #{parent} #{M.grant}" }
    assert_equal ['= 0'] * M::DEPTH_MAX, drive(script).last(M::DEPTH_MAX)
    assert_equal "= #{M::ELIMIT}", result(script + ["group #{M::DEPTH_MAX - 1} #{M.grant}"])
    assert_equal "= #{M::EINVAL}", result(script + ["group #{M::DEPTH_MAX - 1} #{M.grant(base: 64)}"]), 'grant first'
    assert_includes state_of(script + ['thread 7']), 't0:16,15,o,'
  end

  def test_a_refused_replacement_leaves_the_grant_whole
    before = state_of(base_machine)
    assert_equal before, state_of(base_machine + ["configure 1 #{M.grant(ceiling: 1, flags: 0x10)}"])
    assert_equal before, state_of(base_machine + ["configure 1 #{M.grant(ceiling: 1, padding: 1)}"])
  end

  # The capacity to publish: clamped to the effective cpuset, to the quota per
  # period (no quota overflows), and the first position wrapped.
  def test_capacity_is_clamped_and_its_first_position_wrapped
    assert_includes capacity_state(mcpu: 9000), ',4000,0/'
    assert_includes capacity_state(mcpu: 1500), ',1500,0/'
    assert_includes capacity_state(mcpu: 9000, quota: 5_000_000), ',500,0/'
    assert_includes capacity_state(mcpu: 9000, quota: 0), ',0,0/'
    assert_includes capacity_state(mcpu: 9000, quota: 1), ',0,0/', 'rounds down'
    assert_includes capacity_state(mcpu: 9000, quota: M::QUOTA_NONE - 1, period: 1_000_000), ',4000,0/', 'no overflow'
    assert_includes capacity_state(mcpu: 9000, quota: (1 << 62), period: 1_000_000_000), ',4000,0/', 'no overflow'
    assert_includes capacity_state(mcpu: 9000, first: 5), ',4000,1/', '5 mod 4'
    assert_includes capacity_state(mcpu: 9000, first: (1 << 32) - 1, cpuset: 0b110), ',2000,1/', 'of the effective set'
  end

  def test_seeded_failures_are_caught
    scripts = random_scripts(count: 60, length: 90, rng: Random.new(SEED + 7)) + seeded_scripts
    expected = scripts.flat_map { |script| predict(script) }
    MUTANTS.each do |name, (original, replacement)|
      mutant = build_driver(mutant_source(name, original, replacement), name: "mutant-#{name.tr(' ', '-')}",
                                                                       flags: %w[-Wno-unused-function -Wno-unused-parameter])
      caught = begin
        run_lines(mutant, scripts.flatten) != expected
      rescue Erx::Error
        true
      end
      assert caught, "seeded failure not caught: #{name}"
    end
  end

  # Grants, the root's among them, bases and affinities replaced while two CPUs
  # wake and pick on their own threads, under ThreadSanitizer: each field a
  # decision reads without a lock is atomic, no decision escapes the machine's
  # CPUs or the root's ceiling of 31, and afterwards no thread is held twice.
  def test_concurrent_replacements_race_with_no_decision
    tsan = build_driver(File.join(@root, 'kernel/sched/sched.c'), name: 'sched-tsan',
                                                                 flags: %w[-fsanitize=thread -fno-omit-frame-pointer])
    script = ['machine 0', "root #{M.grant}", "group 0 #{M.grant}", "group 1 #{M.grant}", "group 2 #{M.grant}",
              'thread 1', 'thread 2', 'thread 3', 'thread 3', 'thread 2', 'thread 1']
    state = run_lines(tsan, script + ["race #{SEED} 20000", 'state']).last
    held = state.scan(/ c\d+:(\d+|-),\h+((?:;\d+=[\d+]+)*)/).flat_map do |running, levels|
      [running, *levels.scan(/=([\d+]+)/).flatten.flat_map { |ids| ids.split('+') }]
    end
    held.delete('-')
    assert_equal held.uniq, held, "a thread held twice: #{state}"
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  # root, one child group with a thread on all four CPUs: base 16, ceiling 31.
  def base_machine = ['machine 0', "root #{M.grant}", "group 0 #{M.grant}", 'thread 1']

  def slice_script(slice)
    ['machine 0', "root #{M.grant(slice: slice)}", 'thread 0', 'wake 0 0', "pick 0 #{BLOCKED} 0"]
  end

  def capacity_state(**grant)
    state_of(['machine 0', "root #{M.grant(**grant)}"])
  end

  # Thread 0 sleeps after running on CPU 1, its ceiling changes, and it wakes on
  # CPU 0.
  def rewake_script
    base_machine + ["pick 0 #{BLOCKED} 0", 'wake 1 0', "pick 1 #{BLOCKED} 0", "pick 1 #{BLOCKED} 0",
      "configure 1 #{M.grant(base: 5, ceiling: 5)}", 'wake 0 0', "pick 0 #{BLOCKED} 0"]
  end

  def seeded_scripts
    [base_machine + ['thread 1', 'wake 0 0', 'wake 0 1', "pick 0 #{BLOCKED} 0", 'thread 0', 'urgency 2 30', 'wake 0 2',
                     "pick 0 #{PREEMPTED} 1000000", 'state', "pick 0 #{BLOCKED} 0", 'state'],
     base_machine + ['thread 1', 'wake 0 0', 'wake 0 1', "pick 0 #{BLOCKED} 0", 'thread 0', 'urgency 2 30', 'wake 0 2',
                     "pick 0 #{PREEMPTED} 5000000", "pick 0 #{BLOCKED} 0", 'state'],
     rewake_script + ['state'],
     ['machine 0', "root #{M.grant(ceiling: 63)}", 'thread 0', 'thread 0', 'thread 0', 'urgency 0 30', 'urgency 1 30',
      'urgency 2 20', 'wake 0 0', 'wake 0 1', 'wake 0 2', 'urgency 2 30', 'refresh 0 2', 'state'],
     ['machine 0', "root #{M.grant(ceiling: 63)}", 'thread 0', 'thread 0', 'urgency 0 30', 'urgency 1 20', 'wake 0 0',
      "pick 0 #{BLOCKED} 0", 'wake 0 1', 'state', 'urgency 1 31', 'refresh 0 1', 'state', 'urgency 1 30', 'refresh 0 1',
      'urgency 0 30', 'refresh 0 0', 'urgency 0 29', 'refresh 0 0', 'state', "pick 0 #{PREEMPTED} 0", 'state',
      'refresh 1 0', 'refresh 1 1', 'state', 'wake 1 0', 'state'],
     base_machine + ["configure 1 #{M.grant(quota: 1 << 62, period: 1_000_000)}", 'state',
                     "normalize #{M.grant(quota: 1 << 62, period: 1 << 40)}", "normalize #{M.grant}"],
     base_machine + ['wake 0 0', "pick 0 #{BLOCKED} 0", 'affinity 0 2', "pick 0 #{SLICE_END} 1000", 'wake 1 0',
                     "pick 1 #{BLOCKED} 0", 'state'],
     base_machine + ['wake 0 0', "pick 0 #{BLOCKED} 1000000", "configure 1 #{M.grant(slice: 500)}", 'wake 0 0',
                     "pick 0 #{BLOCKED} 0", 'state'],
     base_machine + (1..11).map { 'thread 1' } + (0..11).map { |thread| "wake 0 #{thread}" } +
       (0..11).map { |thread| "affinity #{thread} 2" } + ["pick 0 #{BLOCKED} 0", 'state'],
     ['machine 0', "root #{M.grant(mcpu: 9000, quota: M::QUOTA_NONE - 1, period: 1_000_000, first: 5)}", 'state'],
     ['machine 0', "root #{M.grant(cpuset: 0)}", "root #{M.grant}", "configure 0 #{M.grant(cpuset: 0)}", 'state']]
  end

  # The driver includes the core's private header by its plain name, as the
  # include-form chokepoint requires, from the core's directory; a mutant core
  # finds its own copy of the header beside it first.
  def build_driver(core, name:, flags:)
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-pthread', *flags,
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/sched'), core,
                 File.join(@root, 'test/fixtures/sched_driver.c'), '-o', output],
                name: "compile-#{name}", deadline: 120)
    output
  end

  def mutant_source(name, original, replacement)
    source = File.read(File.join(@root, 'kernel/sched/sched.c'))
    assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the core"
    directory = File.join(@directory, "source-mutant-#{name.tr(' ', '-')}")
    FileUtils.mkdir_p(directory)
    FileUtils.cp(File.join(@root, 'kernel/sched/sched_impl.h'), directory)
    path = File.join(directory, 'sched.c')
    File.write(path, source.sub(original) { replacement })
    path
  end

  def run_lines(program, script)
    input = File.join(@directory, "script-#{script.hash.abs}.txt")
    File.write(input, script.map { |line| "#{line}\n" }.join)
    record = @runner.run([program, input], name: 'sched-driver', deadline: 300)
    File.read(record.fetch('log')).lines.map(&:chomp).grep(/\A[=S] ?/)
  end

  def drive(script) = run_lines(driver, script)
  def result(script) = drive(script).last
  def state_of(script) = drive(script + ['state']).last
  def status(line) = Integer(line[/\A= (-?\d+)/, 1])

  def predict(script)
    model = SchedModel.new
    script.flat_map { |line| model.call(line) }
  end

  # Runs every script in one driver process (each starts with machine) and
  # compares each line with the model's; returns the driver's lines.
  def assert_agrees(scripts)
    expected = scripts.flat_map { |script| predict(script) }
    actual = drive(scripts.flatten)
    mismatch = expected.each_index.find { |index| expected[index] != actual[index] }
    assert_nil mismatch, mismatch && "line #{mismatch}:\n  model:  #{expected[mismatch]}\n  driver: #{actual[mismatch]}"
    assert_equal expected.size, actual.size
    actual
  end

  def assert_reaches_every_case(lines)
    { 'a refused grant' => /\A= #{M::EINVAL}\z/, 'a refused depth' => /\A= #{M::ELIMIT}\z/, 'a dispatch' => /\A= run=\d/,
      'an idle pick' => /\A= run=- .*again=0/, 'a thread leaving' => /run=\d+ .*leaving=\d/,
      'a level holding two' => /;\d+=\d+\+\d/, 'a wake that must pick' => /\A= 1\z/ }.each do |name, pattern|
      assert lines.any? { |line| line.match?(pattern) }, "the random scripts never reached #{name}"
    end
  end

  # A random machine: a tree of edge-valued grants, threads in it, then a
  # stream of everything that can change or decide, with the state after each.
  def random_scripts(count:, length:, rng:)
    Array.new(count) { random_script(length, rng) }
  end

  def random_script(length, rng)
    model = SchedModel.new
    script = []
    add = lambda do |line|
      script << line
      model.call(line)
    end
    add.call("machine #{rng.rand(3).zero? ? rng.rand(ALL + 1) : 0}")
    root = M.grant(**random_grant(rng), cpuset: 1 + rng.rand(15), base: URGENCIES.sample(random: rng),
                   ceiling: URGENCIES.sample(random: rng), flags: rng.rand(ALL + 1), padding: 0)
    add.call("root #{root}")
    groups = 1
    rng.rand(12).times do
      # Mostly a chain, so that paths reach the depth limit.
      parent = rng.rand(4).zero? ? rng.rand(groups) : groups - 1
      groups += 1 if add.call("group #{parent} #{M.grant(**random_grant(rng))}") == ['= 0']
    end
    threads = 1 + rng.rand(10)
    threads.times { add.call("thread #{rng.rand(groups)}") }
    script << 'state'
    length.times do
      script << random_command(groups, threads, rng)
      script << 'state'
    end
    script
  end

  def random_grant(rng)
    { quota: QUOTAS.sample(random: rng), period: PERIODS.sample(random: rng), cpuset: CPUSETS.sample(random: rng),
      mcpu: [0, 1, 1500, 4000, 9000].sample(random: rng), first: [0, 1, 5, 1 << 31].sample(random: rng),
      slice: SLICES.sample(random: rng), grace: GRACES.sample(random: rng),
      base: random_urgency(rng), ceiling: random_urgency(rng), flags: random_flags(rng),
      padding: rng.rand(40).zero? ? 1 : 0 }
  end

  def random_urgency(rng) = rng.rand(40).zero? ? 64 + rng.rand(192) : URGENCIES.sample(random: rng)
  def random_flags(rng) = rng.rand(40).zero? ? 1 << (4 + rng.rand(12)) : rng.rand(ALL + 1)

  def random_command(groups, threads, rng)
    thread = rng.rand(threads)
    cpu = rng.rand(M::CPUS)
    case rng.rand(18)
    when 0..4 then "wake #{cpu} #{thread}"
    when 15, 16 then "refresh #{cpu} #{thread}"
    when 5..9 then "pick #{cpu} #{rng.rand(4)} #{[0, 1, 1_000_000, 5_000_000, 1 << 40].sample(random: rng)}"
    when 10 then "remove #{cpu} #{thread}"
    when 11 then "urgency #{thread} #{random_urgency(rng)}"
    when 12 then "affinity #{thread} #{CPUSETS.sample(random: rng)}"
    when 13 then "place #{thread} #{rng.rand(16)}"
    when 14 then "configure #{rng.rand(groups)} #{M.grant(**random_grant(rng))}"
    else "normalize #{M.grant(**random_grant(rng))}"
    end
  end
end
