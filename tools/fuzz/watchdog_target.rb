# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The erx.watchdog= boot argument's parser. Accepted values at the bounds
# and one of each refusal, so mutations start on both sides of every check.
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/watchdog.c'],
  seeds: Erx::PackFuzz.indexed_seeds(%w[1,5,60 60,120,600 1,2,2 0,5,60 1,1,60 1,5,4 1,5 1,5,60,
                                        4294967296,5,60 1,,60 off])
)
