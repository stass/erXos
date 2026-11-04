# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The entropy generator, built on BLAKE3 and ChaCha20. Generator programs
# (op 0 read, 1 mix, 2 clear, 3 init): reads before any init, at and past
# the bound, mixes, and a clear with what follows.
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/rng.c', 'kernel/crypto/chacha20/chacha.c', 'kernel/crypto/blake3/blake3.c',
            'kernel/crypto/blake3/blake3_portable.c'],
  seeds: { 'unseeded' => "\x00\x20\x00\x01\x01z", 'read-bound' => "\x03\x01s\x00\x00\x01",
           'read-past' => "\x03\x01s\x00\x01\x01", 'read-empty' => "\x03\x00\x00\x00\x00",
           'mix' => "\x03\x00\x01\x05abcde\x00\x20\x00",
           'reset' => "\x03\x01x\x02\x00\x08\x00\x01\x01y\x03\x00\x00\x08\x00" }.transform_values(&:b)
)
