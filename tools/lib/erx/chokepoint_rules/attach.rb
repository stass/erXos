# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(
      rules: [
        # Only the slot list's insert links a slot on an object's list and
        # only erx_cap_slot_clear unlinks one (K21, K26): the store's setter
        # of the list's head is called only by those two, so nothing links a
        # capability to an object without the insert's state check.
        Chokepoints::Callers.new(
          name: 'attach-slot-list-writers',
          rule: 'only erx_attach_object_slots and erx_cap_slot_clear call erx_object_set_slots',
          design: "#{KERNEL}#chokepoint-checks",
          callee: 'erx_object_set_slots',
          callers: %w[erx_attach_object_slots erx_cap_slot_clear],
          seed: { 'erx_cap_install_kind' => 'call', 'cap.o:cap_list_insert' => 'call',
                  'erx_delete_step' => 'tail_jump' }
        ),
        # Every attachment field of an object record has its one insert in
        # kernel/core/attach.c, which reads the object's state first, and its
        # walk in the deletion core's teardown, field by field (K26).
        Chokepoints::Elsewhere.new(
          name: 'attachment-fields',
          rule: 'every att_ member of an object record has an insert erx_attach_STEM_NAME in kernel/core/attach.c ' \
                'whose first call is erx_object_state, and its reader called in kernel/core/delete.c',
          design: "#{KERNEL}#chokepoint-checks", check: 'AttachFields, in Checks',
          test: 'test/host/attach_fields_test.rb'
        )
      ]
    )
  end
end
