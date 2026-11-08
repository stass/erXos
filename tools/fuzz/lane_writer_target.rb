# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The lane writer over a hostile consumer's reader page. Lane scripts in
# tools/fuzz/lane_writer_fuzz.c's format: records put whole and in parts as
# the consumer frees room, armed puts that wait and re-arm, a reserve, a
# record longer than the area, each rpos refusal, and another body for an
# open record.
put = ->(len, cut, reserve, armed: false) { [armed ? 4 : 3, len, cut, reserve].pack('CvCv') }
Erx::PackFuzz.declare_target(
  sources: ['liberx/erx_lane.c'],
  seeds: {
    'records' => "\x00".b + put.call(40, 7, 0) + put.call(0, 0, 0) + [2, 1].pack('CQ<') + put.call(100, 50, 0),
    'parts' => "\x01".b + put.call(9000, 3, 0) + [1, 200].pack('Cv') + put.call(9000, 3, 0, armed: true) +
               [1, 400].pack('Cv') + put.call(9000, 3, 0),
    'top' => "\x02".b + put.call(16, 1, 0) + put.call(5000, 9, 0, armed: true),
    'reserve' => "\x00".b + put.call(3000, 0, 1000) + put.call(3000, 0, 1000, armed: true) + [1, 100].pack('Cv') +
                 put.call(3000, 0, 1000, armed: true) + put.call(0, 0, 4080),
    'unaligned' => "\x00".b + [0, 8].pack('CQ<') + put.call(16, 0, 0) + put.call(16, 0, 0),
    'ahead' => "\x00".b + put.call(16, 0, 0) + [0, 4096].pack('CQ<') + put.call(16, 0, 0),
    'behind' => "\x00".b + put.call(32, 0, 0) + [1, 2].pack('Cv') + put.call(0, 0, 0) + [0, 16].pack('CQ<') +
                put.call(0, 0, 0),
    'other' => "\x00".b + put.call(6000, 0, 0) + put.call(10, 0, 0) + put.call(6000, 0, 0)
  }
)
