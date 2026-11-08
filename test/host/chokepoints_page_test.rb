# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

# The grace tracker's and the page funnel's chokepoints (the grace and page
# groups), and the budget group's one exception for the funnel.
class ChokepointsPageTest < Minitest::Test
  include ChokepointsHelper

  # The tracker's record reaches only the tracker, its header and its host
  # tests; the funnel's records only the funnel and its host tests.
  def test_the_tracker_and_funnel_records_are_private
    grace = [rule('grace-records-private')]
    page = [rule('page-records-private')]
    allowed = {
      Rules::GRACE_IMPL => "struct erx_grace {\n\tint current;\n};\n",
      Rules::GRACE_CORE => "#include \"grace_impl.h\"\n",
      'test/fixtures/grace_driver.c' => "#include \"grace_impl.h\"\n",
      'include/erx/grace.h' => "typedef struct erx_grace erx_grace_t;\n",
      Rules::PAGE_IMPL => "struct erx_page {\n\tvoid *next;\n};\nstruct erx_released {\n};\n",
      Rules::PAGE_CORE => "#include \"page_impl.h\"\n",
      'test/fixtures/page_driver.c' => "#include \"page_impl.h\"\n",
      'tools/fuzz/page_fuzz.c' => "#include \"page_impl.h\"\n",
      'kernel/core/budget_impl.h' => "void f(struct erx_page *p, const struct erx_released *r);\n"
    }
    assert_empty evaluate(grace + page, allowed)
    found = evaluate(grace + page, { 'kernel/core/page.c' => "#include \"grace_impl.h\"\n",
                                     'kernel/core/reaper.c' => "#include \"page_impl.h\"\n",
                                     'test/fixtures/page_driver.c' => "#include \"grace_impl.h\"\n" })
    assert_equal ['grace-records-private: kernel/core/page.c:1', 'grace-records-private: test/fixtures/page_driver.c:1',
                  'page-records-private: kernel/core/reaper.c:1'],
                 found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }.sort
  end

  # Only the tracker names its lock's effects, and only its exported calls
  # take the lock.
  def test_only_the_tracker_takes_its_lock
    named = [rule('grace-tracker-lock')]
    allowed = { Rules::GRACE_CORE => "erx_effect_grace_lock(t);\nerx_effect_grace_unlock(t);\n",
                'include/erx/grace.h' => "void erx_effect_grace_lock(erx_grace_t *);\n",
                'kernel/core/page.c' => "erx_effect_grace_locked(t);\n" }
    assert_empty evaluate(named, allowed)
    found = evaluate(named, { 'kernel/core/page.c' => "x();\nerx_effect_grace_lock(t);\n" })
    assert_equal ['kernel/core/page.c:2'], found.map { |v| "#{v.path}:#{v.line}" }
    callers = rule('grace-lock-callers')
    allowed = Chokepoints.seeded_graph({ 'erx_grace_report' => 'call' }, callee: 'erx_effect_grace_lock')
    assert_empty callers.violations_in_graph(allowed)
    refused = Chokepoints.seeded_graph({ 'erx_page_release' => 'call' }, callee: 'erx_effect_grace_lock')
    assert_equal ['grace-lock-callers'], callers.violations_in_graph(refused).map(&:rule)
  end

  # Only the funnel reaches the allocator's take and put.
  def test_only_the_funnel_reaches_the_allocator
    sites = [rule('page-allocator-sites')]
    allowed = { Rules::PAGE_CORE => "erx_effect_page_alloc(n, &hand);\nerx_effect_page_free(&mature);\n",
                'include/erx/page.h' => "void erx_effect_page_free(erx_plist_t *);\n",
                'tools/fuzz/page_fuzz.c' => "erx_effect_page_alloc(erx_npages_t n, erx_plist_t *out)\n",
                'kernel/core/reaper.c' => "erx_effect_page_freed();\n" }
    assert_empty evaluate(sites, allowed)
    found = evaluate(sites, { 'kernel/core/reaper.c' => "x();\nerx_effect_page_free(&pages);\n" })
    assert_equal ['kernel/core/reaper.c:2'], found.map { |v| "#{v.path}:#{v.line}" }
  end

  # Each reserve step has one funnel entry as its caller.
  def test_each_reserve_step_has_its_one_funnel_caller
    Rules::PAGE_STEP_CALLERS.each do |step, callers|
      check = rule("page-#{step.delete_prefix('erx_reserve_')}-callers")
      allowed = Chokepoints.seeded_graph({ callers.first => 'call' }, callee: step)
      assert_empty check.violations_in_graph(allowed), step
      refused = Chokepoints.seeded_graph({ 'erx_space_unmap' => 'tail_jump' }, callee: step)
      assert_equal [check.name], check.violations_in_graph(refused).map(&:rule), step
    end
  end

  # The funnel may include the budget core's private header, to move a
  # reserve's pool chain; no other core may.
  def test_the_funnel_alone_shares_the_budget_records
    records = [rule('budget-records-private')]
    assert_empty evaluate(records, { 'kernel/core/page.c' => "#include \"budget_impl.h\"\n" })
    refute_empty evaluate(records, { 'kernel/core/grace.c' => "#include \"budget_impl.h\"\n" })
  end
end
