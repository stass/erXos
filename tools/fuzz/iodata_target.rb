# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The iodata walk of erx_bytes's per-byte primitives (tools/fuzz/iodata_fuzz.c gives the
# input's ops): flat lists of bytes and binaries, copied binaries, a binary tail, an improper
# tail, nesting deeper than the walk's local stack with every growth allowed and with none, and
# shared subterms that double a walk to the byte limit exactly, and past it and the cell limit.
ALL_GROWTHS = 0xff
byte = ->(value) { [1, value] }
binary = ->(bytes, copied: false) { [copied ? 3 : 2, bytes.size, *bytes] }
cell = ->(head_back, tail_back) { [4, head_back, tail_back] }
wrap = [7]
seeds = {
  'flat' => [ALL_GROWTHS, *binary.call([1, 2, 3]), *byte.call(4), *cell.call(1, 2), *cell.call(1, 0)],
  'copied' => [ALL_GROWTHS, *binary.call((0..40).to_a, copied: true), *byte.call(9), *cell.call(0, 1)],
  'binary-tail' => [ALL_GROWTHS, *binary.call([5, 6]), *byte.call(7), *cell.call(0, 1)],
  'improper' => [ALL_GROWTHS, *byte.call(1), *byte.call(2), *cell.call(0, 1)],
  'other-element' => [ALL_GROWTHS, 6, *cell.call(0, 1)],
  'deep' => [ALL_GROWTHS, *byte.call(1), *(wrap * 300)],
  'deep-no-heap' => [0, *byte.call(1), *(wrap * 300)],
  'deep-one-growth' => [1, *binary.call([1, 2]), *(wrap * 100)],
  'doubled-bytes' => [ALL_GROWTHS, *binary.call(Array.new(200) { |index| index }), *wrap,
                      *(cell.call(0, 0) * 12)],
  'exactly-the-limit' => [ALL_GROWTHS, *binary.call(Array.new(128) { |index| index }), *wrap, *(cell.call(0, 0) * 9)],
  'doubled-cells' => [ALL_GROWTHS, 0, *wrap, *(cell.call(0, 0) * 18)],
  'runs' => [ALL_GROWTHS, *(byte.call(0xa5) + cell.call(0, 1)) * 70]
}
Erx::PackFuzz.declare_target(
  sources: ['erlang/apps/erx_net/c_src/erx_iodata.c'],
  includes: %w[erlang/apps/erx_net/c_src],
  seeds: seeds.transform_values { |bytes| bytes.pack('C*') }
)
