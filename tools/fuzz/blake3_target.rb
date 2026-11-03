# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# BLAKE3: a cut seed byte, then messages ending at and around the block and
# chunk boundaries, up to a little over four chunks.
Erx::PackFuzz.declare_target(
  sources: ['kernel/crypto/blake3/blake3.c', 'kernel/crypto/blake3/blake3_portable.c'],
  seeds: [0, 1, 63, 64, 65, 1023, 1024, 1025, 2048, 4097].to_h do |length|
    ["length-#{length}", ([length % 251].pack('C') + Array.new(length) { |index| index % 251 }.pack('C*')).b]
  end
)
