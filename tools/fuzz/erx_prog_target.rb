# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/prog_profile_frames'

# liberx's erx_prog check over hostile frames. Inputs in tools/fuzz/erx_prog_fuzz.c's
# format: a byte choosing the frame (0 start, 1 request), then the frame. Seeds: the
# hand-encoded start frames of test/fixtures/prog_profile_frames.rb that fit the fuzz
# bound (every encoding, a capability past 2^63 - 1, wrappers past the depth, lists in
# segments), a start frame with a pipe's two ends, and a request frame.
frames = ProgProfileFrames
fixtures = frames::ALL.select { |fixture| fixture.bytes.bytesize < 32_768 }
choice = { 'start' => "\x00".b, 'request' => "\x01".b }.freeze
Erx::PackFuzz.declare_target(
  sources: %w[liberx/erx_profile.c liberx/erx_etf.c kernel/crypto/blake3/blake3.c
              kernel/crypto/blake3/blake3_portable.c build/gen/liberx/generated/prog_profile.c],
  seeds: fixtures.to_h { |fixture| [fixture.name.to_s.tr('_', '-'), choice.fetch('start') + fixture.bytes] }.merge(
    frames::SEEDS.to_h { |seed| [seed.name, choice.fetch(seed.frame) + seed.bytes] }
  )
)
