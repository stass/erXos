# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The boot locator: the single file at QEMU's load address with its archive
# after the first stage, and a two-file boot with the archive as the initrd.
# The single-file seeds sit at each of the locator's bounds and one past it,
# so mutations start on both sides of every check. The off-by-one test in
# test/host/boot_file_test.rb runs these same seeds.
memory = [1, 0, 0x4000_0000, 0x1000_0000]
located = lambda do |off:, size:, linked_end: 0x2100, declared: 0x6000|
  (['ERXBOOT', 1, 0, off, size].pack('a8VVQ<Q<') +
   [0x4020_0000, linked_end, declared, 0, 0, 0, 0x4800_0000, 0x1_0000, *memory].pack('Q<*')).b
end
initrd = ['ERXBOOT', 1, 0, 0, 0].pack('a8VVQ<Q<') +
         [0x4020_0000, 0x2100, 0x3000, 1, 0x4800_0000, 0x3000, 0x4800_3000, 0x1_0000, *memory].pack('Q<*')

Erx::PackFuzz.declare_target(
  sources: ['kernel/core/pack.c', 'liberx/image_plan.c', 'kernel/crypto/blake3/blake3.c', 'kernel/crypto/blake3/blake3_portable.c'],
  seeds: { 'single' => located.call(off: 0x3000, size: 0x3000), 'initrd' => initrd.b,
           'at-linked-end' => located.call(off: 0x3000, size: 0x3000, linked_end: 0x3000),
           'past-linked-end' => located.call(off: 0x3000, size: 0x3000, linked_end: 0x3001),
           'past-declared' => located.call(off: 0x3000, size: 0x3001),
           'wrapping' => located.call(off: 0xffff_ffff_ffff_f000, size: 0x2000) }
)
