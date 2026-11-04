# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The kernel log's escaper, window reader and operations. The first byte
# picks the target; tools/fuzz/log_fuzz.c gives the operations' framing. The
# escaper: controls, a CSI, a bidirectional override and invalid UTF-8, with
# room to cut a token and room to spare. The window reader: a good record
# and refused ones. The operations: lines past the rate, lines the clock
# lets through until the ring wraps, a kernel line that is cut, reads behind
# the ring, at it and past it.
record = [3, 9, 3, 0, 0, 5].pack('Q<Q<L<L<L<L<') + "ok\tok\0\0\0".b
line = "\x00\xF8\x01\x03abc".b
second = "\x03\x60".b
stale_read = "\x02\xFF\x7F\x00\x08".b
newest_read = "\x02\x08\x00\x00\x08".b
future_read = "\x02\x00\x00\x00\x08".b

Erx::PackFuzz.declare_target(
  sources: ['kernel/core/log.c'],
  seeds: {
    'escape-room' => "\x00\x00\x10a\e[2J\n\tz\xE2\x80\xAE\xC0\x80".b,
    'escape-tight' => "\x00\x06\x00\e\e\e\e".b,
    'window' => "\x01".b + record + record,
    'window-cut' => "\x01".b + record.byteslice(0, 36),
    'window-control' => "\x01".b + [0, 0, 3, 0, 0, 1].pack('Q<Q<L<L<L<L<') + "\e\0\0\0\0\0\0\0".b,
    'rate' => "\x02".b + (line * 12) + stale_read,
    'wrap' => "\x02".b + ((line * 6 + second) * 8) + stale_read + newest_read + future_read,
    'format-cut' => "\x02\x01\x03\xFF".b + ("\e".b * 255) + stale_read + "\x01\x00\x00\x01\x09\x00".b
  }
)
