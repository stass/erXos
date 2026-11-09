# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# SipHash-2-4: a key and a cut, then inputs of every length around the 8-byte word, and past
# 128 and 256 bytes, where only the length's low byte enters the hash.
keys = { 'counting' => (0..15).to_a, 'ones' => Array.new(16, 255) }
Erx::PackFuzz.declare_target(
  sources: ['erlang/apps/erx_net/c_src/erx_siphash.c'],
  includes: %w[erlang/apps/erx_net/c_src],
  seeds: keys.flat_map do |name, key|
    [0, 1, 7, 8, 9, 15, 16, 63, 64, 130, 200, 257].map do |length|
      ["#{name}-#{length}", (key + [length / 2] + Array.new(length) { |index| (index * 13) % 256 }).pack('C*')]
    end
  end.to_h
)
