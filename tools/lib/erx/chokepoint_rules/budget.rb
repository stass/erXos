# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The budget core's private header, which only the core and this host
    # driver include.
    BUDGET_IMPL = 'kernel/core/budget_impl.h'
    BUDGET_DRIVER = 'test/fixtures/budget_driver.c'
    BUDGET_IMPL_INCLUDE = include_of(BUDGET_IMPL)
    BUDGET_RECORD_USE = record_use('erx_budget', 'erx_reserve')

    declare_group(
      private_headers: [BUDGET_IMPL],
      private_header_tests: [BUDGET_DRIVER],
      rules: [
        # The budget core's counters are written only in kernel/core/budget.c
        # (K3, K32): its records are defined only in its private header, which
        # only the core and its host driver include, and every other file
        # names a record's tag only to refer to it. This text rule stands in
        # for the syntax-tree check of the counters' writes, budget-counters
        # below. It reads the stopgap kernel's tree, glue and inherited
        # sources alike.
        Chokepoints::Forbidden.new(
          name: 'budget-records-private',
          rule: "only kernel/core/budget.c, its host driver and kernel/core/page.c, which moves a reserve's " \
                "pool chain, include #{BUDGET_IMPL}, and no other file " \
                'names struct erx_budget or struct erx_reserve but to refer to it',
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: Regexp.union(BUDGET_IMPL_INCLUDE, BUDGET_RECORD_USE),
          sites: [Chokepoints::Site.new(glob: 'kernel/core/budget.c', permits: BUDGET_IMPL_INCLUDE),
                  Chokepoints::Site.new(glob: 'kernel/core/page.c', permits: BUDGET_IMPL_INCLUDE),
                  Chokepoints::Site.new(glob: BUDGET_DRIVER, permits: BUDGET_IMPL_INCLUDE),
                  Chokepoints::Site.new(glob: BUDGET_IMPL, permits: BUDGET_RECORD_USE)],
          seed: { 'kernel/core/kalloc.c' => "#include \"erx/x.h\"\n  #  include \"budget_impl.h\"\nb->used++;\n",
                  'kernel/core/budget_view.c' => "#include \"Budget_Impl.h\"\n",
                  'fiasco/kernel/src/erx/budget.cpp' => "#include <kernel/core/budget_impl.h>\n",
                  'fiasco/kernel/src/erx/erx_budget.h' => "struct erx_reserve { long charged; };\n",
                  'fiasco/kernel/src/kern/erx_split.h' => "struct erx_reserve\n{\n\tlong charged;\n};\n",
                  'kernel/core/watchdog.c' => "union erx_budget {\n\tint used;\n};\n",
                  'kernel/core/budget.c' => "class erx_budget : base {};\n",
                  'kernel/core/aligned.c' => "struct __attribute__((aligned(8))) erx_budget { int used; };\n",
                  'kernel/core/split.c' => "struct\nerx_budget { int used; };\n",
                  'kernel/core/after.c' => "struct erx_budget __attribute__((packed)) { int used; };\n",
                  'kernel/core/macro.c' => "#define B erx_budget\nstruct B { int used; };\n",
                  'fiasco/kernel/src/erx/qualified.cpp' => "struct alignas(8) ::erx_reserve { long charged; };\n",
                  'fiasco/kernel/src/erx/final.cpp' => "struct erx_reserve final { long charged; };\n" }
        ),
        # The core's own files are exempt: budget-records-private keeps their
        # records out of every other file until the syntax trees are read.
        Chokepoints::Pending.new(
          name: 'budget-counters', rule: "only erx_budget_adjust changes a budget's counters, and kernel memory " \
                                         'is allocated only through the budget-charging funnel (K3, K32)',
          design: "#{KERNEL}#chokepoint-checks",
          awaits: ['kernel/core/budget*', 'include/erx/core/budget*'],
          existing: ['kernel/core/budget.c', BUDGET_IMPL],
          reason: "reads clang's syntax trees and the cores' relocations"
        )
      ]
    )
  end
end
