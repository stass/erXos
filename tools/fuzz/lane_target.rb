# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The lane reader over a hostile producer's side. Lane scripts in
# tools/fuzz/lane_fuzz.c's format: a record of 40 bytes published whole and
# in parts, read with small and large buffers and an armed take, on each
# area size and start position; one longer than the area; one refusal
# of each wpos check; and a stop that cuts a record, the producer then
# publishing the rest past it.
record = [3, 40].pack('CV') + [1, 2].pack('Cv') + [5, 5].pack('Cv') + [1, 4].pack('Cv') +
         [5, 1000].pack('Cv') + [6, 1000].pack('Cv')
Erx::PackFuzz.declare_target(
  sources: ['liberx/erx_lane.c'],
  seeds: {
    'record' => "\x00".b + record, 'large' => "\x01".b + record, 'top' => "\x02".b + record,
    'long' => "\x00".b + [3, 5000].pack('CV') + ([1, 256].pack('Cv') + [5, 4096].pack('Cv')) * 3,
    'unaligned' => "\x00".b + [0, 8].pack('CQ<') + [5, 16].pack('Cv'),
    'ahead' => "\x00".b + [0, 8192].pack('CQ<') + [5, 16].pack('Cv'),
    'words' => "\x00".b + [2, 2, 40].pack('CvQ<') + [4, 32].pack('CQ<') + [3, 64].pack('CV') + [1, 6].pack('Cv') +
               [5, 100].pack('Cv'),
    'stop' => "\x00".b + [3, 40].pack('CV') + [1, 2].pack('Cv') + [7].pack('C') + [1, 4].pack('Cv') +
              [5, 1000].pack('Cv') + [5, 1000].pack('Cv'),
    # The control table: a record written and taken, then rewritten twice and taken, then a len past the slot.
    'table' => "\x04".b + [1, 0, 0, 0x0000000800000005].pack('CCCQ<') + [0, 0, 1, 24, 0].pack('CCQ<VV') + [2, 0].pack('CC') +
               [0, 0, 3, 16, 0].pack('CCQ<VV') + [2, 0].pack('CC') + [0, 1, 1, 897, 0].pack('CCQ<VV') + [2, 1, 2, 3].pack('CCCC'),
    'too-long' => "\x00".b + [3, 0x1000001].pack('CV') + [1, 1].pack('Cv') + [5, 16].pack('Cv')
  }
)
