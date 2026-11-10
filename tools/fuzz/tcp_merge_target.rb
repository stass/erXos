# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The merge of received TCP segments (tools/fuzz/tcp_merge_fuzz.c gives the input's
# descriptors): bulk data of one connection with its sums and without, two connections that
# differ only in their ports interleaved in one sequence space, jumbo payloads past a unit's
# length, pure ACKs, flags and spoiled checksums, padded frames, raw bytes, and both limits.
frame = lambda do |conn: 0, length: 181, skip: 0, ack: 0, flags: 0, spoil: 0, sum: 3, raw: nil, pad: false, tos: false|
  first = conn | (tos ? 4 : 0) | (raw ? 8 : 0) | (sum << 4) | (pad ? 0x40 : 0)
  [first, raw ? raw.size : length, skip, ack, flags, spoil, *(raw || [])]
end
bulk = Array.new(40) { |index| frame.call(sum: index % 4) }
seeds = {
  'bulk' => [0, *bulk.flatten],
  'bulk-ipv6' => [0, *Array.new(40) { frame.call(conn: 3) }.flatten],
  'ports' => [0, *Array.new(30) { |index| frame.call(conn: index % 2) }.flatten],
  'three-connections' => [0, *Array.new(30) { |index| frame.call(conn: index % 3) }.flatten],
  'jumbo' => [0, *Array.new(8) { frame.call(length: 255) }.flatten],
  'pure-acks' => [0, *Array.new(20) { |index| frame.call(length: index.even? ? 0 : 10, ack: index % 3, pad: true) }.flatten],
  'breaks' => [0, *[frame.call, frame.call(skip: 9), frame.call(ack: 0xf0), frame.call(flags: 0x3f),
                    frame.call(flags: 45), frame.call(spoil: 1), frame.call(spoil: 2), frame.call(spoil: 4),
                    frame.call(tos: true), frame.call(sum: 1), frame.call(sum: 0), frame.call].flatten],
  'type-of-service' => [0, *[frame.call, frame.call(tos: true), frame.call].flatten],
  'raw' => [0, *frame.call(raw: [2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 2, 8, 0, 0x45, 0, 0, 40, 0, 0, 0, 0, 64, 6]),
            *frame.call, *frame.call(raw: Array.new(80) { |index| index }), *frame.call],
  # A normal frame opens a unit; then an IPv4 TCP frame that ends at its header, before the ports.
  'header-only' => [0, *frame.call, *frame.call(raw: [2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 2, 8, 0,
                                                      0x45, 0, 0, 20, 0, 0, 0x40, 0, 64, 6, 0, 0,
                                                      10, 0, 0, 1, 10, 0, 0, 2])],
  'frames-past-the-limit' => [1],
  'bytes-past-the-limit' => [2]
}
Erx::PackFuzz.declare_target(
  sources: ['erlang/apps/erx_net/c_src/erx_tcp_merge.c', 'erlang/apps/erx_net/c_src/erx_inet_csum.c'],
  includes: %w[erlang/apps/erx_net/c_src],
  seeds: seeds.transform_values { |bytes| bytes.pack('C*') }
)
