# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Raw-byte ELF oracle, independent of the production declaration codec.
module ElfFixture
  module_function

  def program(type:, flags: 4, offset:, address:, file_size:, memory_size: file_size, alignment: 4)
    [type, flags, offset, address, address, file_size, memory_size, alignment].pack('V2Q<6')
  end

  def valid(extra: [], dynamic: false, origin: 0x10000, source_offset: 0, alignment: 4096)
    note_offset = source_offset + 512
    programs = [program(type: 1, flags: 5, offset: source_offset, address: origin,
                        file_size: 4096, alignment: alignment),
                program(type: 4, offset: note_offset, address: origin + 512,
                        file_size: 24)] + extra
    phoff = source_offset + 64
    bytes = "\0".b * (source_offset + 4096)
    identity = "\x7fELF\x02\x01\x01".b.ljust(16, "\0")
    bytes[0, 64] = [identity, dynamic ? 3 : 2, 183, 1, origin + 1024,
                    phoff, 0, 0, 64, 56, programs.size, 0, 0, 0].pack('a16vvVQ<3Vv6')
    programs.each_with_index { |record, index| bytes[phoff + index * 56, 56] = record }
    bytes[note_offset, 24] = [6, 4, 1].pack('V3') + "erXos\0\0\0".b + [1].pack('V')
    bytes
  end

  def integer(bytes, offset, value, width: 8)
    format = { 1 => 'C', 2 => 'v', 4 => 'V', 8 => 'Q<' }.fetch(width)
    bytes[offset, width] = [value].pack(format)
  end
end
