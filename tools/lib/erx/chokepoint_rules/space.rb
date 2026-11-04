# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The space core's record, defined only in its source.
    SPACE_CORE = 'kernel/core/space.c'
    SPACE_RECORD_USE = record_use('erx_space')

    declare_group(
      rules: [
        # A space's tree and run state are changed only in kernel/core/space.c
        # (K27): struct erx_space is defined there and nowhere else, and every
        # other file names its tag only to refer to it, so no caller can link a
        # child, reorder a list or move a run state back. It reads the stopgap
        # kernel's tree, glue and inherited sources alike.
        Chokepoints::Forbidden.new(
          name: 'space-records-private',
          rule: "only #{SPACE_CORE} defines struct erx_space, and no other file names it but to refer to it",
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: SPACE_RECORD_USE,
          sites: [Chokepoints::Site.new(glob: SPACE_CORE)],
          seed: { 'kernel/core/stop.c' => "struct erx_space {\n\tuint32_t run;\n};\n",
                  'kernel/core/split.c' => "struct\nerx_space { int run; };\n",
                  'kernel/core/macro.c' => "#define S erx_space\nstruct S { int run; };\n",
                  'test/fixtures/space_driver.c' => "union erx_space { int run; };\n",
                  'fiasco/kernel/src/erx/space.cpp' => "struct erx_space final { int run; };\n",
                  'fiasco/kernel/src/kern/task.cpp' => "struct alignas(8) ::erx_space { int run; };\n" }
        ),
        # A parent pointer is read and never counted (K27): a space's last
        # reference may have gone with its free waiting only for its children,
        # so a reference taken through the pointer would not keep the record.
        # The walks' callers find a parent's lock through the pointer when they
        # are built; each new call site is listed here and reviewed for that, and
        # the object core's trap on a reference rising from zero is the net.
        Chokepoints::Forbidden.new(
          name: 'space-parent-callers',
          rule: "only #{SPACE_CORE} and the space fuzz target call erx_space_parent",
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: /\berx_space_parent\b/,
          sites: [Chokepoints::Site.new(glob: SPACE_CORE), Chokepoints::Site.new(glob: 'include/erx/space.h'),
                  Chokepoints::Site.new(glob: 'tools/fuzz/space_fuzz.c')],
          seed: { 'kernel/core/stop.c' => "erx_object_ref(erx_space_parent(s));\n",
                  'fiasco/kernel/src/kern/task.cpp' => "auto *p = erx_space_parent(s);\n" }
        ),
        # A space's count of holds moves with other parties' references and
        # counts children they pay for, so inspection does not report it, and only
        # the host tests read it.
        Chokepoints::Forbidden.new(
          name: 'space-holds-callers',
          rule: "only #{SPACE_CORE}, the space driver and the space fuzz target call erx_space_holds",
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: /\berx_space_holds\b/,
          sites: [Chokepoints::Site.new(glob: SPACE_CORE), Chokepoints::Site.new(glob: 'include/erx/space.h'),
                  Chokepoints::Site.new(glob: 'test/fixtures/space_driver.c'),
                  Chokepoints::Site.new(glob: 'tools/fuzz/space_fuzz.c')],
          seed: { 'kernel/core/inspect.c' => "facts->holds = erx_space_holds(s);\n",
                  'fiasco/kernel/src/kern/task.cpp' => "auto n = erx_space_holds(s);\n" }
        )
      ]
    )
  end
end
