# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsBudgetTest < Minitest::Test
  include ChokepointsHelper

  # The budget core's records reach only the core, its header and its
  # driver: the tree's own spellings pass, and a near name, a forward
  # declaration, a typedef, a pointer, a reference or a sizeof only refers
  # to the record. Every other use of its tag is refused.
  def test_budget_records_are_private_to_the_budget_core
    budget = [rule('budget-records-private')]
    allowed = {
      Rules::BUDGET_IMPL => "struct erx_budget {\n\tint used;\n};\nstruct erx_reserve\n{\n};\n",
      'kernel/core/budget.c' => "#include \"budget_impl.h\"\n",
      Rules::BUDGET_DRIVER => "#include \"budget_impl.h\"\n",
      'include/erx/budget.h' => "typedef struct erx_budget erx_budget_t;\nstruct erx_reserve;\n" \
                                "struct erx_budget_counters {\n\tint used;\n};\n",
      'kernel/core/kalloc.c' => "void f(const struct erx_budget *b, struct erx_reserve *r);\n" \
                                "size_t g(void) { return sizeof(struct erx_budget); }\n",
      'fiasco/kernel/src/erx/budget.cpp' => "void f(erx_reserve &r, erx_budget *, int);\n"
    }
    assert_empty evaluate(budget, allowed)
    found = evaluate(budget, { 'kernel/core/kalloc.c' => "#include \"erx/x.h\"\n  #  include \"budget_impl.h\"\n" })
    assert_equal ['budget-records-private: kernel/core/kalloc.c:2'], found.map { |v| "#{v.rule}: #{v.path}:#{v.line}" }
    # A definition with its brace on a later line is reported where its
    # tag ends the line.
    found = evaluate(budget, { 'fiasco/kernel/src/kern/split.h' => "struct erx_reserve\n{\n\tlong charged;\n};\n" })
    assert_equal [1], found.map(&:line)
    # The inherited tree outside the stopgap kernel is not read.
    assert_empty evaluate(budget, { 'fiasco/l4re-core/x.c' => "#include \"budget_impl.h\"\n" },
                          imported: ['fiasco/l4re-core/x.c'])
    refute_empty evaluate(budget, { 'fiasco/kernel/src/kern/x.cpp' => "#include \"budget_impl.h\"\n" },
                          imported: ['fiasco/kernel/src/kern/x.cpp'])
  end
end
