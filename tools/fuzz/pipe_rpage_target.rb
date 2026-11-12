# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The producer's check of a pipe lane's reader page, in
# tools/fuzz/pipe_rpage_fuzz.c's format: a size selector (bit 0: the first
# ring), the write end's wpos, then the reader page (rpos, wake, sleepers).
# Seeds: an empty, a part-full and a full ring, and an rpos past wpos,
# behind the ring and unaligned.
rpage_seed = lambda do |selector, wpos, rpos|
  [selector, wpos, rpos, wpos, 0b101].pack('CQ<Q<Q<Q<')
end
Erx::PackFuzz.declare_target(
  sources: ['liberx/erx_pipe_check.c'],
  seeds: {
    'empty' => rpage_seed.call(0, 49_152, 49_152),
    'part' => rpage_seed.call(1, 65_536 * 2, 65_536 * 2 - 48),
    'full' => rpage_seed.call(0, 49_152, 32_768),
    'past' => rpage_seed.call(0, 49_152, 49_168),
    'behind' => rpage_seed.call(0, 49_152, 16_368),
    'unaligned' => rpage_seed.call(1, 4096, 4088)
  }
)
