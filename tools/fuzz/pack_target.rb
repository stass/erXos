# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/pack_fixture'

# The boot-path parser of the ERXPACK boot image's index and file checks.
# The first input byte chooses the fix-ups: 3 recomputes the file hashes and
# the index hash before the check, so mutations reach past them; 0 leaves
# them as written. The seeds are a valid archive in mode 3 with its
# prefixes, and the same archive left unfixed.
valid = "\x03".b + PackFixture.valid
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/pack.c', 'kernel/crypto/blake3/blake3.c', 'kernel/crypto/blake3/blake3_portable.c'],
  seeds: Erx::PackFuzz.prefix_seeds(valid).merge('valid-unfixed' => "\x00".b + valid.byteslice(1..))
)
