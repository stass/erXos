# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The cut of a run into its frames (tools/fuzz/tcp_cut_fuzz.c gives the input's layout): runs
# over IPv4 and IPv6, with the timestamps and without, in pieces and in one, full and short
# last frames, a pure ACK, a run of exactly IP_MAXPACKET and one byte over it, the sequence
# number across its wrap, every flag; and the refusals: spoiled, short and long templates,
# timestamps that differ from the template's, link headers, a zero segment size and each
# field out of range.
run = lambda do |d0: 2, d1: 0, d2: 0, d3: 0, seq: 0xfffff000, ack: 77, flags: 0x018, win: 512,
                 seg: 1448, total: 10_000, pieces: 5, cuts: [3000, 2, 2, 9000], raw: []|
  head = [d0, d1, d2, d3, seq, ack, flags, win, 0x01020304, 0x05060708, seg, total, pieces, 0x2a, 64, 9]
  (head.pack('C4NNnnNNnnCCCC') + raw.pack('C*') + cuts.pack('n*')).bytes
end
ipv4_template = [0x45, 0, 0, 0, 0, 0, 0x40, 0, 64, 6, 0, 0, 10, 0, 0, 1, 10, 0, 0, 2,
                 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0x50, 0, 0, 0, 0, 0, 0, 0]
seeds = {
  'ipv4-timestamps' => run.call,
  'ipv4-bare' => run.call(d0: 0, seg: 1460, total: 1460 * 3),
  'ipv6-timestamps' => run.call(d0: 3, seg: 1428, total: 9000, pieces: 2, cuts: [4001]),
  'ipv6-bare-small-segments' => run.call(d0: 1, seg: 7, total: 1000, pieces: 64,
                                         cuts: Array.new(63) { |index| (index * 61) % 1001 }),
  'pure-ack' => run.call(pieces: 0, total: 0, flags: 0x010),
  'bare-fin' => run.call(d0: 0, pieces: 1, total: 0, flags: 0x011, cuts: []),
  'exact-multiple' => run.call(seg: 1000, total: 4000, pieces: 1, cuts: []),
  'packet-max' => run.call(seg: 9000, total: 65_535 - 52, pieces: 3, cuts: [1, 65_000]),
  'packet-max-plus-one' => run.call(seg: 9000, total: 65_535 - 52 + 1, pieces: 1, cuts: []),
  'every-flag' => run.call(flags: 0xfff, seq: 0xffffffff),
  'one-byte-segments' => run.call(d0: 1, seg: 1, total: 300, pieces: 4, cuts: [0, 0, 150]),
  'raw-template' => run.call(d0: 8, d1: ipv4_template.size, raw: ipv4_template, seg: 500, total: 1201),
  'raw-junk' => run.call(d0: 8, d1: 44, raw: Array.new(44) { |index| index * 5 }),
  'timestamps-differ' => run.call(d0: 2 | 4),
  'template-byte-spoiled' => run.call(d0: 0x12, d1: 9),
  'template-version-spoiled' => run.call(d0: 0x13, d1: 0, d2: 0x30),
  'template-short' => run.call(d0: 0x22, d1: 0),
  'template-long' => run.call(d0: 0x32, d1: 0),
  'ipv6-template-short' => run.call(d0: 0x21, d1: 5),
  'no-link-header' => run.call(d0: 0x42, d2: 0),
  'long-link-header' => run.call(d0: 0x42, d2: 33),
  'zero-segment' => run.call(seg: 0),
  'flags-too-wide' => run.call(d0: 0x82, d3: 0),
  'window-too-wide' => run.call(d0: 0x82, d3: 1),
  'null-piece' => run.call(d0: 0x82, d3: 2),
  'null-link' => run.call(d0: 0x82, d3: 3),
  'too-many-pieces' => run.call(d0: 0x82, d3: 4)
}
Erx::PackFuzz.declare_target(
  sources: ['erlang/apps/erx_net/c_src/erx_tcp_cut.c', 'erlang/apps/erx_net/c_src/erx_inet_csum.c'],
  includes: %w[erlang/apps/erx_net/c_src],
  seeds: seeds.transform_values { |bytes| bytes.pack('C*') }
)
