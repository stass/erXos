# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The boot handoff record's reader. An input is one byte, whose low bit moves the
# record off its alignment, then the record in the layout of abi/kernel.txt. The seeds
# are a good record, a test image's (development and test code) and the test mark
# alone, which it refuses, the highest image range it accepts, its refusals one field at a
# time, stdout paths good, longest, too long and with a byte no node name has, a record
# off its alignment and a short one.
handoff = lambda do |version: 3, flags: 1, start: 0x4020_0000, size: 0x10_0000, bootargs: 7, stdout: '/pl011@9000000', stdout_length: stdout.bytesize|
  [version, flags, 'B' * 8, 'H' * 32, start, size, 0x1000_0000, 0x10_0000, 1, bootargs].pack('VVa8a32Q<Q<Q<Q<VV')
    .ljust(2136, "\0".b) + [stdout_length].pack('V') + stdout.b.ljust(260, "\0".b)
end
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/boot_handoff.c'],
  seeds: Erx::PackFuzz.indexed_seeds(
    [handoff.call,
     handoff.call(stdout: ''),
     handoff.call(stdout: "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
     handoff.call(stdout: '', stdout_length: 257),
     handoff.call(stdout: "/pl011\e[2J"),
     handoff.call(start: 0xFFFF_FFFF_FFE0_0000),
     handoff.call(start: 0xFFFF_FFFF_FFF0_0000),
     handoff.call(start: 0xFFFF_FFFF_FFF0_0000, size: 0x20_0000),
     handoff.call(start: 0x4020_0001),
     handoff.call(size: 0),
     handoff.call(version: 1),
     handoff.call(flags: 5),
     handoff.call(flags: 4),
     handoff.call(flags: 0x8000_0000),
     handoff.call(bootargs: 0xFFFF_FFFF)].map { |record| "\x00".b + record } +
    ["\x01".b + handoff.call, "\x00".b + handoff.call.byteslice(0, 88)]
  )
)
