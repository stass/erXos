# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The Internet checksum: a starting sum, a cut, an update span and its new bytes, then inputs
# of odd and even lengths, from a zero start and from ffff; some all ff, whose 64-bit total
# needs more than one fold, and some all zero, where an update meets the other zero.
starts = { 'zero' => [0, 0], 'ones' => [255, 255] }
fills = {
  'mixed' => ->(index) { (index * 37) % 251 },
  'ff' => ->(_index) { 255 },
  'zero' => ->(_index) { 0 }
}
Erx::PackFuzz.declare_target(
  sources: ['erlang/apps/erx_net/c_src/erx_inet_csum.c'],
  includes: %w[erlang/apps/erx_net/c_src],
  seeds: starts.to_a.product(fills.to_a).flat_map do |(start_name, start), (fill_name, fill)|
    [0, 1, 2, 3, 20, 21, 64, 1001, 9000].map do |length|
      replacement = fill_name == 'zero' ? Array.new(8, 0) : [1, 2, 3, 4, 0xfe, 0xff, 0x80, 0x7f]
      header = start + [length / 3, length % 256, length % 5] + replacement
      ["#{start_name}-#{fill_name}-#{length}", (header + Array.new(length) { |index| fill.call(index) }).pack('C*')]
    end
  end.to_h
)
