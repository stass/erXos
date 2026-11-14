# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/pack_fixture'

# The boot path's placement and the ELF reader's kernel profile. The first byte
# picks the target: 0 for the reader over raw bytes; otherwise the plan over a
# first stage and archive, with the hashes fixed up and memory that many 2 MiB
# units, laid out by the second byte and with the reservation the third places
# (boot_place_fuzz.c, struct layout). The seeds are a kernel with its views, an
# archive holding it, one whose root lands where the loader leaves the archive, so
# the plan moves the archive, on one range or three with a reservation and with
# the device tree behind the file, one whose move crosses 4 GiB, and one on memory from 0
# with a 1 MiB tree.
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
# A root linked where the loader leaves the archive, so the plan moves the archive behind it.
landing = boot_place_elf(0x4020_6000, [[1, 0x1000, 0x4020_6000, 0x1000, 0x2000, 0x1000]])
moved = PackFixture.valid(paths: %w[boot/kernel boot/sigma0 boot/stopgap-root system/root],
                          files: { 'boot/kernel'.b => kernel, 'boot/sigma0'.b => sigma0, 'boot/stopgap-root'.b => landing })
# Memory from 0xf0000000: the root lands on the archive and sigma0 stays just below 4 GiB, so the
# archive moves across it.
high_root = boot_place_elf(0xf020_6000, [[1, 0x1000, 0xf020_6000, 0x1000, 0x2000, 0x1000]])
high_sigma0 = boot_place_elf(0xffff_b000, [[1, 0x1000, 0xffff_b000, 0x1000, 0x2000, 0x1000]])
high = PackFixture.valid(paths: %w[boot/kernel boot/sigma0 boot/stopgap-root system/root],
                         files: { 'boot/kernel'.b => kernel, 'boot/sigma0'.b => high_sigma0,
                                  'boot/stopgap-root'.b => high_root })
# No root of its own to run at a link address, so it boots on memory from 0.
plain = PackFixture.valid(paths: %w[boot/kernel boot/sigma0 system/root],
                          files: { 'boot/kernel'.b => kernel, 'boot/sigma0'.b => sigma0 })
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/boot_place.c', 'kernel/core/pack.c', 'liberx/elf_plan.c', 'liberx/image_plan.c',
            'kernel/crypto/blake3/blake3.c', 'kernel/crypto/blake3/blake3_portable.c'],
  seeds: { 'kernel' => "\x00".b + kernel, 'sigma0' => "\x00".b + sigma0,
           'plan' => "\xFF\x00\x00".b + archive, 'plan-tight' => "\x03\x00\x00".b + archive,
           'plan-wide' => "\x80\x00\x00".b + archive, 'plan-moved' => "\xFF\x00\x00".b + moved,
           'plan-moved-virt' => "\xFF\x20\x00".b + moved, 'plan-moved-split' => "\xFF\x0C\x20".b + moved,
           'plan-moved-high' => "\xFF\x01\x00".b + high, 'plan-zero-virt-tree' => "\xFF\xC0\x00".b + plain }
)
