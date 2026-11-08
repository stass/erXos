# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The grace tracker's private header, which only the tracker and its
    # host tests include.
    GRACE_CORE = 'kernel/core/grace.c'
    GRACE_IMPL = 'kernel/core/grace_impl.h'
    GRACE_IMPL_INCLUDE = include_of(GRACE_IMPL)
    GRACE_RECORD_USE = record_use('erx_grace')
    # The tracker's lock effects, by their whole names.
    GRACE_LOCK = /\berx_effect_grace_(?:lock|unlock)\b/

    declare_group(
      private_headers: [GRACE_IMPL],
      private_header_tests: host_tests(GRACE_CORE),
      rules: [
        # The tracker's counts are written only in kernel/core/grace.c (K9):
        # its record is defined only in its private header, which only the
        # tracker and its host tests include, so every stamp comes from its
        # retire and no other code advances a period.
        Chokepoints::Forbidden.new(
          name: 'grace-records-private',
          rule: "only #{GRACE_CORE} and its host tests include #{GRACE_IMPL}, and no other file " \
                'names struct erx_grace but to refer to it',
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: Regexp.union(GRACE_IMPL_INCLUDE, GRACE_RECORD_USE),
          sites: [GRACE_CORE, *host_tests(GRACE_CORE)].map { |glob| Chokepoints::Site.new(glob: glob, permits: GRACE_IMPL_INCLUDE) } +
                 [Chokepoints::Site.new(glob: GRACE_IMPL, permits: GRACE_RECORD_USE)],
          seed: { 'kernel/core/page.c' => "#include \"grace_impl.h\"\n",
                  'kernel/core/reaper.c' => "#include <core/Grace_Impl.h>\n",
                  'fiasco/kernel/src/erx/grace.cpp' => "#include <kernel/core/grace_impl.h>\n",
                  'kernel/core/split.c' => "struct\nerx_grace { unsigned long current; };\n",
                  'include/erx/grace.h' => "union erx_grace { unsigned long current; };\n" }
        ),
        # Only the tracker takes the tracker's lock (K13): the effect is named
        # only by the tracker, its header and the host tests that provide it
        # (the tracker's and the page funnel's, which build the tracker), and
        # the call graph shows only the tracker's exported calls reaching it.
        Chokepoints::Forbidden.new(
          name: 'grace-tracker-lock',
          rule: "only the grace tracker takes the tracker's lock (K13): only #{GRACE_CORE}, " \
                'include/erx/grace.h and the tracker\'s and the page funnel\'s host tests name ' \
                'erx_effect_grace_lock and its unlock',
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: GRACE_LOCK,
          sites: [GRACE_CORE, 'include/erx/grace.h', *host_tests(GRACE_CORE), *host_tests('kernel/core/page.c')]
            .map { |glob| Chokepoints::Site.new(glob: glob) },
          seed: { 'kernel/core/page.c' => "erx_effect_grace_lock(released->tracker);\n",
                  'kernel/core/reaper.c' => "erx_effect_grace_unlock(t);\n",
                  'include/erx/page.h' => "void erx_effect_grace_lock(erx_grace_t *);\n" }
        ),
        Chokepoints::Callers.new(
          name: 'grace-lock-callers',
          rule: "only the tracker's join, leave, retire, report and read take the tracker's lock",
          design: "#{KERNEL}#chokepoint-checks",
          callee: 'erx_effect_grace_lock',
          callers: %w[erx_grace_cpu_join erx_grace_cpu_leave erx_grace_retire erx_grace_report erx_grace_read],
          seed: { 'erx_page_release' => 'call', 'erx_released_take' => 'tail_jump', 'grace.o:start_period' => 'call' }
        )
      ]
    )
  end
end
