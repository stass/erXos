# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The function that turns a listed slot into its table and value, by its
    # whole name.
    CAP_SLOT_NAME = /\berx_cap_slot_name\b/

    declare_group(
      rules: [
        # Only a destroy's teardown names a slot by its place on an object's
        # list (K25, K26): every other caller reaches a slot through a value
        # its holder presented, so no other path walks an object's slots.
        Chokepoints::Forbidden.new(
          name: 'cap-slot-name-users',
          rule: 'only kernel/core/cap.c, include/erx/cap.h, kernel/core/delete.c and their host tests name ' \
                'erx_cap_slot_name',
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: CAP_SLOT_NAME,
          sites: ['kernel/core/cap.c', 'include/erx/cap.h', 'kernel/core/delete.c', *host_tests('kernel/core/cap.c'),
                  *host_tests('kernel/core/delete.c')].map { |glob| Chokepoints::Site.new(glob: glob) },
          seed: { 'kernel/core/attach.c' => "erx_cap_slot_name(slot, &table, &cap);\n",
                  'kernel/core/space.c' => "(void)erx_cap_slot_name;\n",
                  'include/erx/delete.h' => "void erx_cap_slot_name(const erx_cap_slot_t *);\n" }
        )
      ]
    )
  end
end
