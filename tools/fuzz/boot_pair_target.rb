# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The boot pair from /chosen/bootloader. An input is a shape byte, the partition's
# length in its low three bits and the tryboot's in the next three, bit 6 leaving the
# partition out and bit 7 the tryboot, then their bytes. The seeds are both slots, a
# normal and a trial boot, a partition that is no slot, a tryboot of 2, a cell
# little-endian, cells of 3 and 5 bytes, and each property left out.
boot_pair = lambda do |partition, tryboot, shape: 0x24|
  [shape].pack('C') + partition.b + tryboot.b
end
cell = ->(number) { [number].pack('N') }
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/boot_place.c', 'kernel/core/pack.c', 'liberx/elf_plan.c',
            'kernel/crypto/blake3/blake3.c', 'kernel/crypto/blake3/blake3_portable.c'],
  seeds: Erx::PackFuzz.indexed_seeds(
    [boot_pair.call(cell.call(2), cell.call(0)),
     boot_pair.call(cell.call(3), cell.call(1)),
     boot_pair.call(cell.call(4), cell.call(0)),
     boot_pair.call(cell.call(2), cell.call(2)),
     boot_pair.call([2].pack('V'), cell.call(0)),
     boot_pair.call("\0\0\2", cell.call(0), shape: 0x23),
     boot_pair.call(cell.call(2) + "\0", cell.call(0), shape: 0x25),
     boot_pair.call('', cell.call(0), shape: 0x60),
     boot_pair.call(cell.call(2), '', shape: 0x84)]
  )
)
