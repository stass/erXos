# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The scheduler core and the hand-written header of its records.
    SCHED_CORE = 'kernel/sched/sched.c'
    SCHED_IMPL = 'kernel/sched/sched_impl.h'
    SCHED_IMPL_INCLUDE = include_of(SCHED_IMPL)
    SCHED_RECORD_USE = record_use('erx_sched_group', 'erx_sched_thread', 'erx_sched_cpu')

    declare_group(
      private_headers: [SCHED_IMPL],
      private_header_tests: host_tests(SCHED_CORE),
      rules: [
        # A group's grant, the group a thread is charged to and the links of
        # the ready queues are written only in kernel/sched/sched.c (S5, S6):
        # the records are defined only in the core's private header, which only
        # the core and its host tests include, and every other file names a
        # record's tag only to refer to it. It reads the stopgap kernel's tree,
        # glue and inherited sources alike.
        Chokepoints::Forbidden.new(
          name: 'sched-records-private',
          rule: "only #{SCHED_CORE} and its host tests include #{SCHED_IMPL}, and no other file names " \
                'struct erx_sched_group, erx_sched_thread or erx_sched_cpu but to refer to it',
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: Regexp.union(SCHED_IMPL_INCLUDE, SCHED_RECORD_USE),
          sites: [Chokepoints::Site.new(glob: SCHED_CORE, permits: SCHED_IMPL_INCLUDE),
                  *host_tests(SCHED_CORE).map { |test| Chokepoints::Site.new(glob: test, permits: SCHED_IMPL_INCLUDE) },
                  Chokepoints::Site.new(glob: SCHED_IMPL, permits: SCHED_RECORD_USE)],
          seed: { 'kernel/sched/switch.c' => "#include \"erx/x.h\"\n  #  include \"sched_impl.h\"\n",
                  'fiasco/kernel/src/erx/group.cpp' => "#include <kernel/sched/sched_impl.h>\n",
                  'fiasco/kernel/src/erx/erx_sched.h' => "struct erx_sched_group { long ceiling; };\n",
                  'kernel/core/watchdog.c' => "union erx_sched_thread {\n\tint base;\n};\n",
                  'kernel/sched/aligned.c' => "struct __attribute__((aligned(8))) erx_sched_cpu { int ready; };\n" }
        )
      ]
    )
  end
end
