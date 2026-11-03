# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# SHA-256: messages across block and padding boundaries, each after a cut
# seed byte.
Erx::PackFuzz.declare_target(
  sources: ['kernel/crypto/sha2/sha256c.c'],
  seeds: [0, 1, 55, 56, 63, 64, 65, 200].to_h do |length|
    ["length-#{length}", ([length % 7].pack('C') + 'a' * length).b]
  end
)
