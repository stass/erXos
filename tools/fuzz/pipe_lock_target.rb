# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The lock page's checks, in tools/fuzz/pipe_lock_fuzz.c's format: what the
# reader found (bit 0: it holds cur's lane, bit 1: a sound record at rpos),
# that lane's rpos and the record's length, then the lock page (owner,
# wends, waiters, cur, cur_off, cur_pos). Seeds: one for each row of the
# settle table, a fresh page, and owners at the last read end and past it.
lock_seed = lambda do |found, rpos, len, owner, cur, cur_off, cur_pos|
  [found, rpos, len, owner, 3, 0b11, cur, cur_off, cur_pos].pack('CQ<Q<VVQ<VVQ<')
end
Erx::PackFuzz.declare_target(
  sources: ['liberx/erx_pipe_check.c'],
  seeds: {
    'continue' => lock_seed.call(3, 64, 10, 1, 2, 4, 64),
    'retire' => lock_seed.call(3, 64, 10, 2, 2, 10, 64),
    'finished' => lock_seed.call(1, 96, 0, 3, 2, 4, 64),
    'none' => lock_seed.call(0, 64, 10, 0, 2, 4, 64),
    'fresh' => lock_seed.call(3, 0, 10, 0, 0, 0, 0),
    'last-owner' => lock_seed.call(3, 64, 10, 64, 2, 4, 64),
    'past-owner' => lock_seed.call(3, 64, 10, 65, 2, 4, 64)
  }
)
