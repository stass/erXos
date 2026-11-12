# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The consumer's check of a pipe's ring, in tools/fuzz/pipe_ring_fuzz.c's
# format: a size selector (16 << n bytes), rpos and wpos, then the data
# area, whose bytes at rpos are the record header (len, kind, stamp). Seeds:
# an empty ring, a data record of 1 and of PIPE_BUF bytes, a control record,
# a frame record, a record past wpos, wpos past the area, and an unaligned
# rpos, on the next and the first ring's sizes, past the area, and with a
# payload that wraps to the area's start.
ring_seed = lambda do |selector, rpos, wpos, len, kind, area_offset: 0|
  [selector, rpos, wpos].pack('CQ<Q<') + ("\x00".b * area_offset) + [len, kind, 7].pack('VVQ<')
end
Erx::PackFuzz.declare_target(
  sources: ['liberx/erx_pipe_check.c'],
  seeds: {
    'empty' => ring_seed.call(10, 64, 64, 0, 0, area_offset: 64),
    'data' => ring_seed.call(10, 0, 32, 1, 2),
    'buf' => ring_seed.call(12, 0, 4112, 4096, 2),
    'control' => ring_seed.call(10, 32, 176, 128, 3, area_offset: 32),
    'frame' => ring_seed.call(10, 0, 32, 8, 1),
    'unpublished' => ring_seed.call(10, 0, 32, 17, 2),
    'ahead' => ring_seed.call(10, 0, 16_400, 1, 2),
    'unaligned' => ring_seed.call(10, 8, 48, 1, 2, area_offset: 8),
    'past-area' => ring_seed.call(10, 16_384 * 3 + 64, 16_384 * 3 + 96, 9, 2, area_offset: 64),
    # A header in the area's last grain, whose payload continues at offset 0.
    'wrapped' => ring_seed.call(10, 16_384 * 4 - 16, 16_384 * 4 + 32, 20, 2, area_offset: 16_384 - 16)
  }
)
