# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The capability core, fed the values, masks and counts a domain controls,
# with the object store it counts capabilities on and the budget core its
# lookup reads; host handles index the test store the harness builds.
# Installs, then a lookup, a clear, a reservation and a pass of what was
# installed, so mutations start inside the tables; the last seed moves a
# slot to its last generation, then installs, copies, looks up and clears,
# so the slot retires and the object is released.
install = "\x00\x00\x09\xff\xff\xff\xff\x05"
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/cap.c', 'kernel/core/attach.c', 'kernel/core/object.c', 'kernel/core/budget.c'],
  defines: ['ERX_HOST'],
  seeds: Erx::PackFuzz.indexed_seeds(
    ["\x00\x00\x07\xff\xff\xff\xff\x01\x00",
     "\x00\x00\x07\xff\xff\xff\xff\x01\x00\x00\x02\x01\x00\x00\x00\x00\x00\x00",
     "\x00\x00\x0b\xff\xff\xff\xff\x05\x00\x01\x03\x02\x00\x05\x00\x01\x01\x01\x01\x02\xff\xff\xff\xff\x00\x00",
     "\x00\x00\x06\xff\xff\xff\xff\x09\x00\x00\x01\x01\x01\x00\x07",
     "\x00\x09\x01\x80#{install}\x00\x07\x00\x01\x01\x01\xff\xff\xff\xff" \
     "\x00\x08\x01\x01\x00\x00\x00\x00\x00\x00\x01\x01\x01\x01\x00\x01\x02\x01\x01"]
  )
)
