# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The capability core, fed the values, masks and counts a domain controls.
# Installs, then a lookup, a clear, a reservation and a pass of what was
# installed, so mutations start inside the tables.
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/cap.c'],
  seeds: Erx::PackFuzz.indexed_seeds(
    ["\x00\x00\x07\xff\xff\xff\xff\x01\x00",
     "\x00\x00\x07\xff\xff\xff\xff\x01\x00\x00\x02\x01\x00\x00\x00\x00\x00\x00",
     "\x00\x00\x0b\xff\xff\xff\xff\x05\x00\x01\x03\x02\x00\x05\x00\x01\x01\x01\x01\x02\xff\xff\xff\xff\x00\x00",
     "\x00\x00\x06\xff\xff\xff\xff\x09\x00\x00\x01\x01\x01\x00\x07"]
  )
)
