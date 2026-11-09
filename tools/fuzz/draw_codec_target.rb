# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The draw codec's C twin, generated from abi/formats/draw.txt
# (docs/design-display.md, "Draw messages"), with the framing of compressed
# pixels in test/fixtures/erx_draw_cload.c. Each seed starts with the depths
# of ids 0 to 7. Seeds: an alloc, a load and a compressed load with a
# back-reference, a polygon of both coded forms, a string with a background
# and a flush; a load of an id with no depth; and a load cut short.
le32 = ->(*values) { values.pack('l<*') }
depths = [8, 8, 32, 0, 1, 24, 16, 4].pack('C*')
rect = le32.call(0, 0, 4, 2)
alloc = 'b'.b + [1, 0, 0, 0x68081828, 0].pack('VVCVC') + rect + rect + [0xff].pack('V')
load = 'y'.b + [1].pack('V') + rect + ("\x11".b * 8)
cload = 'Y'.b + [1].pack('V') + rect + [131, 1, 2, 3, 4, 0x00, 0x04, 128, 9].pack('C*')
poly = 'p'.b + [1, 1, 0, 0, 0, 2].pack('VvVVVV') + le32.call(0, 0) + [5, 0x7b, 0xff, 0xff, 0x7f, 0x01].pack('C*')
string_bg = 'x'.b + [0, 1, 2].pack('VVV') + le32.call(1, 2) + le32.call(0, 0, 9, 9) + le32.call(0, 0) +
            [2, 3].pack('vV') + le32.call(4, 5) + [7, 65_535].pack('vv')

Erx::PackFuzz.declare_target(
  sources: ['build/gen/display/generated/erx_draw_codec.c', 'test/fixtures/erx_draw_cload.c'],
  seeds: {
    'messages' => depths + alloc + load + cload + poly + string_bg + 'v'.b,
    'no-depth' => depths + 'y'.b + [3].pack('V') + rect + ("\0".b * 8),
    'load-cut' => depths + load[0, load.bytesize - 1]
  }
)
