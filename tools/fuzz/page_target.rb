# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The grace tracker and the page funnel, with the budget core, fed every
# sequence of calls their contracts allow. The seeds back a charge from
# free pages, release it, back another from the released list across a
# grace period, close a backing between its parts, and walk the active CPUs
# while items wait.
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/grace.c', 'kernel/core/page.c', 'kernel/core/budget.c'],
  defines: ['ERX_HOST'],
  seeds: Erx::PackFuzz.indexed_seeds(
    ["\x03\x20\x04\x05\x05\x06\x22\x0b\x10\x0c\x02\x0a\x0c\x0e\x05",
     "\x03\x30\x04\x06\x0f\x0b\x30\x14\x02\x0a\x14\x0c\x07\x3f",
     "\x01\x00\x0f\x01\x02\x0a\x12\x1a\x01\x00\x01\x0a\x02",
     "\x03\x2a\x04\x06\x0f\x06\x0f\x0b\x28\x0c\x1c\x02\x0a\x1c\x0d\x0e\x55\x07"]
  )
)
