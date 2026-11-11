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
etf = ProgProfileFrames::Etf
pairs = ->(map) { map.map { |key, value| [etf.atom(key.to_s), value] } }
reader = ->(rix, cap) { etf.tuple(etf.small(rix), etf.small(cap)) }
write_end = etf.map(pairs.call(wend: etf.small(1), ring: etf.small(101), rpage: etf.small(102),
                               size: etf.int(16_384), readers: etf.list([reader.call(0, 103)])))
writer = etf.tuple(etf.small(1), etf.small(105), etf.small(106), etf.int(65_536), etf.small(107), etf.atom('open'))
read_end = etf.map(pairs.call(rix: etf.small(0), lock: etf.small(104), wends: etf.small(1),
                              writers: etf.list([writer]), readers: etf.list([])))
pipes = etf.list([
  etf.tuple(etf.small(0), etf.tuple(etf.atom('pipe'), etf.atom('write'), etf.tuple(etf.small(1), etf.small(2)), write_end)),
  etf.tuple(etf.small(1), etf.tuple(etf.atom('pipe'), etf.atom('read'), etf.tuple(etf.small(2), etf.small(3)), read_end))
])
fixtures = frames::ALL.select { |fixture| fixture.bytes.bytesize < 32_768 }
Erx::PackFuzz.declare_target(
  sources: %w[liberx/erx_profile.c liberx/erx_etf.c kernel/crypto/blake3/blake3.c
              kernel/crypto/blake3/blake3_portable.c build/gen/liberx/generated/prog_profile.c],
  seeds: fixtures.to_h { |fixture| [fixture.name.to_s.tr('_', '-'), "\x00".b + fixture.bytes] }.merge(
    'pipes' => "\x00".b + frames.start(frames::BASE_PAIRS.merge(fds: pipes)),
    'request' => "\x01".b + etf.frame(etf.tuple(etf.atom('erx_prog'), etf.small(1), etf.small(0), etf.atom('ok')))
  )
)
