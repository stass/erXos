# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The page funnel's private header, which only the funnel and its host
    # tests include.
    PAGE_CORE = 'kernel/core/page.c'
    PAGE_IMPL = 'kernel/core/page_impl.h'
    PAGE_IMPL_INCLUDE = include_of(PAGE_IMPL)
    PAGE_RECORD_USE = record_use('erx_page', 'erx_released')
    # The page allocator's take and put, by their whole names.
    PAGE_ALLOCATOR = /\berx_effect_page_(?:alloc|free)\b/

    # Each reserve step and the one funnel entry that calls it (K6, K32):
    # the step counts what the entry moves, under the same owner's lock.
    PAGE_STEP_CALLERS = {
      'erx_reserve_admit' => %w[erx_reserve_charge],
      'erx_reserve_fill' => %w[erx_backing_step],
      'erx_reserve_cancel' => %w[erx_backing_step],
      'erx_reserve_use' => %w[erx_reserve_take],
      'erx_reserve_refund' => %w[erx_page_release]
    }.freeze

    declare_group(
      private_headers: [PAGE_IMPL],
      private_header_tests: host_tests(PAGE_CORE),
      rules: [
        # A page's link and stamp and the released list are written only in
        # kernel/core/page.c (K6, K9): their records are defined only in its
        # private header, which only the funnel and its host tests include,
        # so the list's append is only the release's and its unlink only
        # erx_released_take's.
        Chokepoints::Forbidden.new(
          name: 'page-records-private',
          rule: "only #{PAGE_CORE} and its host tests include #{PAGE_IMPL}, and no other file " \
                'names struct erx_page or struct erx_released but to refer to it',
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: Regexp.union(PAGE_IMPL_INCLUDE, PAGE_RECORD_USE),
          sites: [PAGE_CORE, *host_tests(PAGE_CORE)].map { |glob| Chokepoints::Site.new(glob: glob, permits: PAGE_IMPL_INCLUDE) } +
                 [Chokepoints::Site.new(glob: PAGE_IMPL, permits: PAGE_RECORD_USE)],
          seed: { 'kernel/core/reaper.c' => "#include \"page_impl.h\"\n",
                  'kernel/core/space.c' => "#include <core/Page_Impl.h>\n",
                  'fiasco/kernel/src/erx/page.cpp' => "#include <kernel/core/page_impl.h>\n",
                  'kernel/core/split.c' => "struct\nerx_page { void *next; };\n",
                  'include/erx/page.h' => "union erx_released { int list; };\n" }
        ),
        # The allocator's own take and put are reached only from the funnel
        # (K6): the backing takes free pages and the free step puts mature ones
        # back, each under the released list's lock, so no page is ever between
        # the list and the free lists.
        Chokepoints::Forbidden.new(
          name: 'page-allocator-sites',
          rule: "only #{PAGE_CORE}, include/erx/page.h and the funnel's host tests name " \
                'erx_effect_page_alloc and erx_effect_page_free',
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: PAGE_ALLOCATOR,
          sites: [PAGE_CORE, 'include/erx/page.h', *host_tests(PAGE_CORE)].map { |glob| Chokepoints::Site.new(glob: glob) },
          seed: { 'kernel/core/reaper.c' => "erx_effect_page_free(&mature);\n",
                  'kernel/core/space.c' => "n = erx_effect_page_alloc(1, &hand);\n",
                  'include/erx/budget.h' => "void erx_effect_page_free(erx_plist_t *);\n" }
        ),
        # A reserve's counts move only with its pages: each step is called
        # only by the funnel entry that moves the pages it counts.
        *PAGE_STEP_CALLERS.map do |step, callers|
          Chokepoints::Callers.new(
            name: "page-#{step.delete_prefix('erx_reserve_')}-callers",
            rule: "only #{callers.join(' and ')} calls #{step}",
            design: "#{KERNEL}#chokepoint-checks",
            callee: step,
            callers: callers,
            seed: { 'erx_space_unmap' => 'call', 'erx_budget_destroy' => 'tail_jump', 'page.o:select_part' => 'call' }
          )
        end
      ]
    )
  end
end
