# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# liberx's frame assembly over hostile records. Inputs in
# tools/fuzz/erx_funnel_asm_fuzz.c's format: max_frame / 64, a grow-refusal
# mask and a part-size seed, then a record body: a frame kept whole, one
# whose payload is past max_frame, one whose header disagrees with its
# length, one longer than the first buffer with a grow refused, and a bare
# header.
frame = ->(ctl, payload) { [ctl.bytesize, payload.bytesize].pack('VV') + ctl + payload }
ctl = "\x83\x68\x02\x61\x16\x61\x01".b
small = frame.call(ctl, "\x83\x6a".b)
large = frame.call(ctl, "\x83\x6d".b + [9000].pack('N') + ("\x07".b * 9000))
Erx::PackFuzz.declare_target(
  sources: %w[liberx/erx_funnel.c liberx/erx_etf.c kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c],
  seeds: {
    'kept' => "\x04\x00\x07".b + small,
    'past-max-frame' => "\x01\x00\x09".b + large,
    'grown' => "\xff\x00\x2a".b + large,
    'grow-refused' => "\xff\x02\x2a".b + large,
    'header-lies' => "\xff\x00\x03".b + [7, 100].pack('VV') + ctl + "\x83\x6a".b,
    'bare-header' => "\x01\x00\x01".b + [0, 0].pack('VV')
  }
)
