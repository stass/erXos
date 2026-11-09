# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The reader of a domain's crash area (liberx/system/dom_dump.c), which the
# domain wrote. A seed is a complete dump in a 512-byte area, the same dump
# filling the area exactly, then one corruption for each header rule, so
# mutations start on both sides of every check.
HEADER = 256
AREA = 512
header = lambda do |magic: 0x44585245, version: 1, flags: 0, pad: 0, length: 9, slogan: 'boom'|
  [magic, version, flags, pad, length].pack('L<L<L<L<Q<') + slogan.b.ljust(232, "\0")
end
area = ->(**fields) { (header.(**fields) + "=erl_crash_dump:0.5\n").ljust(AREA, "\0") }
Erx::PackFuzz.declare_target(
  sources: ['liberx/system/dom_dump.c'],
  seeds: Erx::PackFuzz.indexed_seeds(
    [area.(), area.(length: AREA - HEADER, flags: 1), area.(length: AREA - HEADER + 1), area.(magic: 0),
     area.(version: 2), area.(flags: 2), area.(pad: 1), area.(slogan: 'x' * 232), header.()[0, HEADER - 1]]
  )
)
