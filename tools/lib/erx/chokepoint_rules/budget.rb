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
    # A budget's counters (docs/design-kernel.md, "Chokepoint checks", K3)
    # and the core's functions that write them.
    BUDGET_COUNTERS = %w[guarantee cap used carved lent pinned dead threshold].freeze
    BUDGET_COUNTER_WRITERS = %w[level_apply erx_budget_init_root erx_budget_carve erx_budget_resize
                                erx_budget_close erx_budget_watch erx_budget_watch_detach].freeze

    declare_group(
      private_headers: [BUDGET_IMPL],
      private_header_tests: [BUDGET_DRIVER],
      rules: [
        # The budget core's counters are written only in kernel/core/budget.c
        # (K3, K32): its records are defined only in its private header, which
        # only the core and its host driver include, and every other file
        # names a record's tag only to refer to it; budget-counters below
        # reads which functions of the core write them. It reads the stopgap
        # kernel's tree, glue and inherited sources alike.
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
        # A budget's counters are written only by the budget core's own steps
        # (K3, K32), read from the cores' syntax trees: the chain plan's
        # apply behind erx_budget_adjust (the charges, releases, reserve
        # steps and pins), the root's set-up, the carve, the resize, the
        # close and the watch. No other function of the core, and no other
        # core, assigns a counter, takes its address but to load it
        # atomically, rebuilds or copies a whole record, or casts a record's
        # pointer, whatever macros spell it.
        Chokepoints::Writers.new(
          name: 'budget-counters',
          rule: "only the budget core's chain plan, root set-up, carve, resize, close and watch, in " \
                "kernel/core/budget.c, write a budget's counters",
          design: "#{KERNEL}#chokepoint-checks",
          record: 'erx_budget',
          members: BUDGET_COUNTERS,
          sites: [Chokepoints::WriterSite.new(glob: 'kernel/core/budget.c', functions: BUDGET_COUNTER_WRITERS),
                  # The step drops const through an integer for the apply
                  # that writes; the walk hands a budget to erx_object_of.
                  Chokepoints::WriterSite.new(glob: 'kernel/core/budget.c', functions: %w[budget_step], hows: %i[cast]),
                  Chokepoints::WriterSite.new(glob: 'kernel/core/delete.c', functions: %w[erx_delete_budget_walk_next],
                                              hows: %i[cast])],
          seed: { 'kernel/core/budget.c' => "struct erx_budget { unsigned long used; };\n" \
                                            "void erx_reserve_charge(struct erx_budget *b, unsigned long n) { b->used += n; }\n",
                  'kernel/core/page.c' => "typedef struct erx_budget { unsigned long used; } erx_budget_t;\n" \
                                          "void f(erx_budget_t *b) { b->used++; }\n",
                  'kernel/core/sched.c' => "struct erx_budget { unsigned long used; };\n#define FIELD(x) u ## x\n" \
                                           "void f(struct erx_budget *b) { b->FIELD(sed) = 0; }\n",
                  'kernel/core/space.c' => "void *memset(void *, int, unsigned long);\n" \
                                           "struct erx_budget { unsigned long used; };\n" \
                                           "void f(struct erx_budget *b) { memset(b, 0, sizeof *b); }\n" }
        )
      ]
    )
  end
end
