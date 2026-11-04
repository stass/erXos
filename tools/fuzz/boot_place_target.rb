# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/pack_fixture'

# The boot path's placement and the ELF reader's kernel profile. The first byte
# picks the target: 0 for the reader over raw bytes; otherwise the plan over a
# first stage and archive, with the hashes fixed up and memory that many 2 MiB
# units. The seeds are a kernel with its views, and an archive holding it.
def boot_place_elf(entry, headers)
  bytes = "\xAB".b * 0x3000
  bytes[0, 64] = ["\x7FELF\x02\x01\x01".b.ljust(16, "\0"), 2, 183, 1, entry, 64, 0, 0, 64, 56, headers.size, 64, 0, 0]
                 .pack('a16vvVQ<Q<Q<VvvvvvV').byteslice(0, 64)
  headers.each_with_index do |(type, offset, address, file_size, memory_size, alignment), index|
    bytes[64 + index * 56, 56] = [type, 7, offset, address, address, file_size, memory_size, alignment].pack('VVQ<6')
  end
  bytes
end
kernel = boot_place_elf(0x1000, [[1, 0x1000, 0x1000, 0x2000, 0x3000, 0x1000], [2, 0x1000, 0x1000, 16, 16, 8],
                                 [0x10, 0x1000, 0x1000, 0x1000, 0x1000, 8], [0x11, 0x2000, 0x2000, 0x100, 0x100, 8]])
sigma0 = boot_place_elf(0x1800, [[1, 0x1000, 0x1000, 0x1000, 0x2000, 0x10000], [2, 0x1000, 0x1000, 16, 16, 8]])
root = boot_place_elf(0x4400_1000, [[1, 0x1000, 0x4400_1000, 0x1000, 0x2000, 0x1000]])
archive = PackFixture.valid(paths: %w[boot/kernel boot/sigma0 boot/stopgap-root system/root],
                            files: { 'boot/kernel'.b => kernel, 'boot/sigma0'.b => sigma0, 'boot/stopgap-root'.b => root })
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/boot_place.c', 'kernel/core/pack.c', 'liberx/elf_plan.c', 'liberx/generated/abi_reader.c',
            'kernel/crypto/blake3/blake3.c', 'kernel/crypto/blake3/blake3_portable.c'],
  seeds: { 'kernel' => "\x00".b + kernel, 'sigma0' => "\x00".b + sigma0,
           'plan' => "\xFF".b + archive, 'plan-tight' => "\x03".b + archive,
           'plan-wide' => "\x80".b + archive }
)
