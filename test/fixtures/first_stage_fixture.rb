# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# A first stage as built, from literal offsets: the 64-byte boot protocol
# header, the 32-byte locator with both archive fields zero, then code. It
# never runs; it stands in for the kernel and bootstrap, which bootstrap's
# integration replaces. Offsets 16 and 56 are the declared size and magic.
module FirstStageFixture
  LOCATOR = 64
  SIZE = 0x2100
  LINKED_END = 0x3080
  module_function

  def bytes(size: SIZE, linked_end: LINKED_END)
    image = 'c'.b * size
    image[0, 64] = ("\0".b * 64)
    image[16, 8] = [linked_end].pack('Q<')
    image[24, 8] = [0xa].pack('Q<')
    image[56, 4] = 'ARMd'.b
    image[LOCATOR, 32] = locator
    image
  end

  def locator(magic: "ERXBOOT\0".b, version: 1, zero: 0, off: 0, size: 0)
    [magic, version, zero, off, size].pack('a8VVQ<Q<')
  end
end
