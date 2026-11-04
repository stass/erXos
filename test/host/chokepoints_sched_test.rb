# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsSchedTest < Minitest::Test
  include ChokepointsHelper

  # The scheduler core's records reach only the core, its host driver and
  # its fuzzer: the tree's own spellings pass, and the public typedefs and
  # pointers only refer to a record.
  def test_sched_records_are_private_to_the_scheduler_core
    sched = [rule('sched-records-private')]
    allowed = {
      Rules::SCHED_IMPL => "struct erx_sched_group {\n\tint base;\n};\nstruct erx_sched_cpu\n{\n};\n",
      Rules::SCHED_CORE => "#include \"sched_impl.h\"\n",
      'test/fixtures/sched_driver.c' => "#include \"sched_impl.h\"\n",
      'tools/fuzz/sched_fuzz.c' => "#include \"sched_impl.h\"\n",
      'include/erx/sched.h' => "typedef struct erx_sched_thread erx_sched_thread_t;\n" \
                               "typedef struct erx_sched_decision {\n\tint urgency;\n} erx_sched_decision_t;\n",
      'fiasco/kernel/src/erx/group.cpp' => "void f(erx_sched_thread &t, const erx_sched_cpu *c);\n"
    }
    assert_empty evaluate(sched, allowed)
    assert_empty evaluate([rule('core-records-private')],
                          allowed.slice(Rules::SCHED_CORE, 'test/fixtures/sched_driver.c', 'tools/fuzz/sched_fuzz.c'))
    found = evaluate(sched, { 'kernel/sched/switch.c' => "#include \"erx/x.h\"\n  #  include \"sched_impl.h\"\n" })
    assert_equal ['sched-records-private: kernel/sched/switch.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
    refute_empty evaluate([rule('core-records-private')], { 'test/fixtures/sched_driver.c' => "#include \"cap_impl.h\"\n" })
    refute_empty evaluate([rule('core-records-private')], { Rules::SCHED_CORE => "#include \"cap_impl.h\"\n" }),
                 'a core outside kernel/core includes only its own private headers'
  end

  # The core's own stores of a thread's resolve pass, read from the tree, and
  # every other write, in the core or out of it, fails on that line; reads and
  # a decision's own urgency are not writes.
  def test_a_stored_urgency_is_only_ever_the_threads_own_resolve
    store = [rule('sched-urgency-store')]
    core = File.read(File.expand_path("../../#{Rules::SCHED_CORE}", __dir__))
    assert_empty evaluate(store, { Rules::SCHED_CORE => core })
    assert_empty evaluate(store, { 'tools/fuzz/sched_fuzz.c' => "\tif (t->urgency != level || run->urgency == 1)\n",
                                   Rules::SCHED_CORE => "\tdecision->urgency.raw = thread->urgency;\n" })
    ["other->urgency = erx_sched_resolve(thread).raw;", 'thread->urgency = 63;', 'threads[i].urgency = 1;',
     '(*thread).urgency += 1;', 'thread->urgency++;', '--thread->urgency;', 'uint8_t *p = &thread->urgency;'].each do |line|
      found = evaluate(store, { Rules::SCHED_CORE => "\t#{line}\n" })
      assert_equal ["sched-urgency-store: #{Rules::SCHED_CORE}:1"], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }, line
    end
    refute_empty evaluate(store, { 'kernel/sched/switch.c' => "\tthread->urgency = erx_sched_resolve(thread).raw;\n" })
  end
end
