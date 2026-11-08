# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The domain library's planning entries, fed requests, manifest rows, ids
# and row indexes a requester's admission or a corrupted row could choose.
# The first byte picks the entry (0 a request, 1 a configured domain, 2 a
# partial-boot program, 3 a connection, 4 a disconnect, a retire, a stop, a
# record at the fault gate, a device's give and a principal's check, over
# records, rows and a device catalogue the input patches); the rest are
# patches over valid starting values:
# a little-endian u16 offset, a length byte, and that many bytes.
patch = ->(offset, bytes) { [offset, bytes.bytesize].pack('S<C') + bytes }
Erx::PackFuzz.declare_target(
  sources: ['liberx/system/dom_core.c', 'liberx/system/dom_life.c', 'liberx/erx_lane.c', 'build/gen/liberx/generated/abi_reader.c'],
  seeds: Erx::PackFuzz.indexed_seeds(
    ["\x00", "\x01", "\x02", "\x03", "\x04",
     # A request whose id is the system domain's, then one whose lane is past the maximum.
     "\x00#{patch.(4, [4].pack('L<'))}", "\x00#{patch.(216, [0x2000000].pack('L<'))}",
     # A configured row index past the table, then the secret flag on a request.
     "\x01#{patch.(2360, [1].pack('L<'))}", "\x00#{patch.(20, [1].pack('L<'))}"]
  )
)
