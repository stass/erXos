# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The space core, fed the creation arguments and stops a domain controls,
# which links the capability core for its rights, and the cores it calls. A creation under the first
# space and one under it, a close and a stop of the child, its walk to the end
# and its deletion, and then the release of both records, the parent's first,
# and two rounds of the reaper, so mutations start inside a tree of spaces and
# its frees.
tree = "\x00\x00\x00\xff\x00\x03\x05\x00\x00\x00\x00\x04\x00\x00\x00\x08\x00\x00\x00\x00" \
       "\x00\x00\x00\x01\x00\x03\x06\x00\x00\x00\x00\x04\x00\x00\x00\x08\x00\x00\x00\x00" \
       "\x07\x01\x02\x01\x01\x01\x00\x03\x01\x01\x04\x01\x04\x01\x04\x01\x04\x01\x04\x01\x04\x01\x04\x01" \
       "\x05\x01\x01\x06\x01\x06\x01\x06\x01"
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/space.c', 'kernel/core/cap.c', 'kernel/core/attach.c', 'kernel/core/object.c',
            'kernel/core/budget.c'],
  defines: ['ERX_HOST'],
  seeds: Erx::PackFuzz.indexed_seeds(
    ["\x00\x00\x00\xff\x00\x03\x05\x00\x00\x00\x00\x04\x00\x00\x00\x08\x00\x00\x00\x00",
     tree, "#{tree}\x09\x01\x09\x02\x0b\x00\x0b\x00",
     # A post of each record before the deletion and of one after it.
     "#{tree}\x0a\x01\x0a\x02"]
  )
)
