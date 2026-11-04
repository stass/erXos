# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The entropy generator, built on BLAKE3 and ChaCha20. Generator programs
# (op 0 read, 1 mix, 2 clear, 3 init, each read's and each digest's length two
# bytes, little-endian): reads before any init, at and past the bound, mixes,
# a clear with what follows, and an init at and past the digest's bound.
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/rng.c', 'kernel/crypto/chacha20/chacha.c', 'kernel/crypto/blake3/blake3.c',
            'kernel/crypto/blake3/blake3_portable.c'],
  seeds: { 'unseeded' => "\x00\x20\x00\x01\x01\x00z", 'read-bound' => "\x03\x01\x00s\x00\x00\x01",
           'read-past' => "\x03\x01\x00s\x00\x01\x01", 'read-empty' => "\x03\x00\x00\x00\x00\x00",
           'mix' => "\x03\x00\x00\x01\x05\x00abcde\x00\x20\x00",
           'reset' => "\x03\x01\x00x\x02\x00\x08\x00\x01\x01\x00y\x03\x00\x00\x00\x08\x00",
           'digest-bound' => "\x03\x00\x04#{'a' * 1024}\x00\x20\x00",
           'digest-past' => "\x03\x01\x04#{'a' * 1025}\x00\x20\x00" }.transform_values(&:b)
)
