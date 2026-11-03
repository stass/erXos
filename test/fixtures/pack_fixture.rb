# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_manifest_fixture'

# Independent format oracle. Literal offsets encode the published archive
# contract rather than consulting the production generator or pack encoder.
module PackFixture
  module_function

  def integer(bytes, offset, value, width: 4)
    directive = { 1 => 'C', 2 => 'v', 4 => 'V', 8 => 'Q<' }.fetch(width)
    bytes[offset, width] = [value].pack(directive)
  end

  def image
    bytes = "\0".b * 8192
    bytes[0, 56] = [0x49585245, 1, 1, 1, 0, 4096, 0, 64, 0, 1, 4096].pack('VvvVVQ<4VV')
    bytes[56, 40] = [4096, 0, 128, 128, 5, 0].pack('Q<4V2')
    bytes[4096, 128] = 'x'.b * 128
    bytes
  end

  def valid(paths: ['system/root'], image_bytes: image,
            manifest_bytes: AbiManifestFixture.valid)
    names = paths.map(&:b)
    raise 'fixture root is required' unless names.include?('system/root'.b)
    unless names.include?('system/manifest'.b)
      names.insert(names.index('system/root'.b), 'system/manifest'.b)
    end
    strings = names.join.b
    index_end = 64 + 32 * names.size + strings.bytesize
    cursor = (index_end + 4095) & ~4095
    entries = ''.b
    payloads = []
    path_offset = 0
    names.each do |name|
      root = name == 'system/root'.b
      manifest = name == 'system/manifest'.b
      data = root ? image_bytes : (manifest ? manifest_bytes : 'f'.b)
      entries << [path_offset, name.bytesize, root ? 2 : 1, (root || manifest) ? 1 : 0,
                  cursor, data.bytesize, 0].pack('VvCCQ<3')
      payloads << [cursor, data]
      path_offset += name.bytesize
      cursor = (cursor + data.bytesize + 4095) & ~4095
    end
    bytes = "\0".b * cursor
    bytes[0, 64] = ["ERXPACK\0".b, 1, 1, cursor,
                    names.size, 32, 64, 64 + entries.bytesize,
                    strings.bytesize, names.index('system/root'.b), "\0" * 8].pack('a8VVQ<VVQ<Q<VVa8')
    bytes[64, entries.bytesize] = entries
    bytes[64 + entries.bytesize, strings.bytesize] = strings
    payloads.each { |offset, data| bytes[offset, data.bytesize] = data }
    bytes
  end

  def root_offset(bytes)
    index = bytes.byteslice(52, 4).unpack1('V')
    bytes.byteslice(64 + index * 32 + 8, 8).unpack1('Q<')
  end
end
