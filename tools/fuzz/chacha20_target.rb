# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# ChaCha20: a key, a nonce and a little-endian counter, then data, from
# counter 0 and from the counter's last block, with data across block
# boundaries.
headers = { 'start' => ("\x01" * 44 + "\x00\x00\x00\x00").b, 'last' => ("\x02" * 44 + "\xff\xff\xff\xff").b }
Erx::PackFuzz.declare_target(
  sources: ['kernel/crypto/chacha20/chacha.c'],
  seeds: headers.flat_map do |name, header|
    [0, 1, 55, 56, 63, 64, 65, 200].map { |length| ["#{name}-#{length}", header + ("\x5a" * length).b] }
  end.to_h
)
