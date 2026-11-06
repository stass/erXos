# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# CRC-32C: a starting value and a cut, then inputs of every length around the
# table's nibble steps, from the first value and from the last.
starts = { 'zero' => [0, 0, 0, 0], 'ones' => [255, 255, 255, 255], 'check' => [0x83, 0x92, 0x06, 0xe3] }
Erx::PackFuzz.declare_target(
  sources: ['otp/erts/emulator/nifs/erxos/erx_crc32c.c'],
  includes: %w[otp/erts/emulator/nifs/erxos],
  seeds: starts.flat_map do |name, value|
    [0, 1, 2, 3, 8, 9, 63, 64, 65, 200].map do |length|
      ["#{name}-#{length}", (value + [length / 2] + Array.new(length) { |index| (index * 7) % 251 }).pack('C*')]
    end
  end.to_h
)
