# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The mapping-record core's record, defined only in its source.
    MAP_CORE = 'kernel/core/map.c'
    MAP_RECORD_USE = record_use('erx_mapping')
    MAP_CORE_MEMBERS = /\bcore_(?:root|generation|low|high|stage|tree|window_start|window_end|pop_front|pop_back|nsegs|segs)\b/

    declare_group(
      rules: [
        # A mapping's protection moves only beneath a ceiling fixed when it was
        # made (K4), and no mapping is writable with executable: struct
        # erx_mapping is defined in kernel/core/map.c and nowhere else, and every
        # other file names its tag only to refer to it, so only the core's plans
        # write a record. It reads the stopgap kernel's tree, glue and inherited
        # sources alike.
        Chokepoints::Forbidden.new(
          name: 'map-records-private',
          rule: "only #{MAP_CORE} defines struct erx_mapping, and no other file names it but to refer to it",
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: MAP_RECORD_USE,
          sites: [Chokepoints::Site.new(glob: MAP_CORE)],
          seed: { 'kernel/core/fault.c' => "struct erx_mapping {\n\tuint8_t ceiling;\n};\n",
                  'kernel/core/split.c' => "struct\nerx_mapping { int ceiling; };\n",
                  'kernel/core/macro.c' => "#define S erx_mapping\nstruct S { int ceiling; };\n",
                  'test/fixtures/map_driver.c' => "union erx_mapping { int ceiling; };\n",
                  'fiasco/kernel/src/erx/map.cpp' => "struct erx_mapping final { int ceiling; };\n",
                  'fiasco/kernel/src/kern/task.cpp' => "struct alignas(8) ::erx_mapping { int ceiling; };\n" }
        ),
        # A record is written only from a plan the core made (K4): a plan's segments
        # and a tree's root are in structs a caller must be able to hold, so their
        # members are named core_, and nothing else names those members. A caller that
        # edited a segment's ceiling before the apply would install it.
        Chokepoints::Forbidden.new(
          name: 'map-core-members',
          rule: "only #{MAP_CORE} and include/erx/map.h name the core_ members of a mapping plan or tree",
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: MAP_CORE_MEMBERS,
          sites: [Chokepoints::Site.new(glob: MAP_CORE), Chokepoints::Site.new(glob: 'include/erx/map.h')],
          seed: { 'kernel/core/fault.c' => "plan.core_segs[0].attrs.ceiling = 7;\n",
                  'test/fixtures/map_driver.c' => "tree.core_root = NULL;\n",
                  'fiasco/kernel/src/erx/map.cpp' => "plan->core_generation = tree->core_generation;\n" }
        )
      ]
    )
  end
end
