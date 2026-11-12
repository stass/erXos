# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/prog_profile_frames'

# liberx's erx_prog check, and the start-up plan over it (liberx/program/startup.c), over
# hostile frames. Inputs in tools/fuzz/erx_prog_fuzz.c's format: a byte whose bit 0 chooses
# the frame (0 start, 1 request) and whose bits 1-3 offset the scratch, then the frame. Seeds: the
# hand-encoded start frames of test/fixtures/prog_profile_frames.rb that fit the fuzz
# bound (every encoding, a capability past 2^63 - 1, wrappers past the depth, lists in
# segments), a start frame with a pipe's two ends, a request frame, and a start frame
# with no descriptor and a cwd of prog_path_max bytes, which the plan copies whole.
frames = ProgProfileFrames
fixtures = frames::ALL.select { |fixture| fixture.bytes.bytesize < 32_768 }
etf = frames::Etf
cwd_at_max = frames.start(frames::BASE_PAIRS.merge(fds: etf::NIL, cwd: etf.binary('/' + ('c' * 4095))))
choice = { 'start' => "\x00".b, 'request' => "\x01".b }.freeze
Erx::PackFuzz.declare_target(
  sources: %w[liberx/program/startup.c liberx/erx_profile.c liberx/erx_etf.c kernel/crypto/blake3/blake3.c
              kernel/crypto/blake3/blake3_portable.c build/gen/liberx/generated/prog_profile.c],
  includes: [*Erx::PackFuzz::INCLUDES, '.'],
  seeds: fixtures.to_h { |fixture| [fixture.name.to_s.tr('_', '-'), choice.fetch('start') + fixture.bytes] }.merge(
    frames::SEEDS.to_h { |seed| [seed.name, choice.fetch(seed.frame) + seed.bytes] }
  ).merge('cwd-at-max' => choice.fetch('start') + cwd_at_max)
)
