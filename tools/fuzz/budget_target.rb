# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The budget core on its own, with the object store, the list insert and
# the deletion core's budget-death walk, fed scripts of carves, charges,
# refunds, resizes, pins, destroys and tombstone puts whose operands reach
# the edges of the checked arithmetic, and judged against the counters'
# definitions as test/fixtures/budget_model.rb states them. The seeds carve
# a child, charge and destroy it; build a chain that borrows through every
# level, pin it, shrink a level below its spending and destroy it from the
# top; carve and charge at INT64_MAX and UINT64_MAX; and destroy a wall
# whose tree is doomed while it still holds charges; carve INT64_MAX under
# an elastic child of unbounded cap, a change no level can express; and
# charge a budget directly, destroy it, refund it dead and close it again.
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/budget.c', 'kernel/core/object.c', 'kernel/core/attach.c', 'kernel/core/delete.c',
            'kernel/core/cap.c'],
  defines: ['ERX_HOST'],
  seeds: Erx::PackFuzz.indexed_seeds(
    ["\x00\x02\x14\x1e\x09\x02\x28\x0e\x07",
     "\x00\x02\x00\x3c\x08\x02\x00\x3c\x10\x02\x00\x3c\x19\x02\x30\x02\x30\x1d\x01\x14\x00\x00\x0e\x07\x07",
     "\x00\x01\xfd\x00\x00\x01\xff\x00\x01\x02\xff\x02\xfb\x02\x01\x03\x05",
     "\x00\x01\x28\x00\x08\x02\x0a\x14\x10\x02\x00\x1e\x11\x19\x02\x05\x0a\x19\x0e\x07\x07\x07",
     "\x00\x02\x00\xfd\x08\x02\xff\xff", "\x00\x02\x05\x0a\x0b\x81\x0e\x0b\xc1\x0e\x07"]
  )
)
