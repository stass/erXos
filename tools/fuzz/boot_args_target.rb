# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The kernel command line's words. Each kind of word good and malformed, so mutations
# start on both sides of every check.
Erx::PackFuzz.declare_target(
  sources: ['liberx/backend/fiasco/boot_args.c', 'kernel/core/watchdog.c'],
  includes: [*Erx::PackFuzz::INCLUDES, '.'],
  seeds: Erx::PackFuzz.indexed_seeds(['', 'quiet console=x', 'erx.det=1', 'erx.det=0', 'erx.group_report=1', 'erx.group_report=0',
                                      'erx.hostlink=1', 'erx.hostlink=0', 'erx.hostlink=1 erx.det=1',
                                      'erx.watchdog=1,5,60', 'erx.watchdog=1,5', 'erx.arg=-S erx.arg=2:2', 'erx.arg=', "erx.arg=a\0b", 'erx.other=1', 'erx.'])
)
