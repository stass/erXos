# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require_relative 'abi_manifest_fixture'

# Independent format oracle. Literal offsets encode the published archive
# contract (ERXPACK version 2: a 96-byte header, 64-byte entries) rather
# than consulting the production generator or pack encoder, and its hashes
# come from b3sum, BLAKE3's Rust implementation, not from erXos's C.
module PackFixture
  HEADER = 96
  ENTRY = 64
  PAGE = 4096
  INDEX_HASH = 64
  FILE_HASH = 32
  module_function

  def integer(bytes, offset, value, width: 4)
    directive = { 1 => 'C', 2 => 'v', 4 => 'V', 8 => 'Q<' }.fetch(width)
    bytes[offset, width] = [value].pack(directive)
  end

  def field(bytes, offset, width)
    directive = { 1 => 'C', 2 => 'v', 4 => 'V', 8 => 'Q<' }.fetch(width)
    bytes.byteslice(offset, width).unpack1(directive)
  end

  def image
    bytes = "\0".b * 8192
    bytes[0, 56] = [0x49585245, 1, 1, 1, 0, 4096, 0, 64, 0, 1, 4096].pack('VvvVVQ<4VV')
    bytes[56, 40] = [4096, 0, 128, 128, 5, 0].pack('Q<4V2')
    bytes[4096, 128] = 'x'.b * 128
    bytes
  end

  def valid(paths: ['system/root'], image_bytes: image,
            manifest_bytes: AbiManifestFixture.valid, file_bytes: 'f'.b)
    names = paths.map(&:b)
    raise 'fixture root is required' unless names.include?('system/root'.b)
    unless names.include?('system/manifest'.b)
      names.insert(names.index('system/root'.b), 'system/manifest'.b)
    end
    strings = names.join.b
    index_end = HEADER + ENTRY * names.size + strings.bytesize
    cursor = round_page(index_end)
    entries = ''.b
    payloads = []
    path_offset = 0
    names.each do |name|
      root = name == 'system/root'.b
      manifest = name == 'system/manifest'.b
      data = root ? image_bytes : (manifest ? manifest_bytes : file_bytes)
      entries << [path_offset, name.bytesize, root ? 2 : 1, (root || manifest) ? 1 : 0,
                  cursor, data.bytesize, 0, "\0" * 32].pack('VvCCQ<3a32')
      payloads << [cursor, data]
      path_offset += name.bytesize
      cursor = round_page(cursor + data.bytesize)
    end
    bytes = "\0".b * cursor
    bytes[0, HEADER] = ["ERXPACK\0".b, 2, 1, cursor,
                        names.size, ENTRY, HEADER, HEADER + entries.bytesize,
                        strings.bytesize, names.index('system/root'.b), "\0" * 8,
                        "\0" * 32].pack('a8VVQ<VVQ<Q<VVa8a32')
    bytes[HEADER, entries.bytesize] = entries
    bytes[HEADER + entries.bytesize, strings.bytesize] = strings
    payloads.each { |offset, data| bytes[offset, data.bytesize] = data }
    rehash(bytes)
  end

  # Recomputes every file hash whose run lies inside the archive, then the
  # index hash, so a fixture mutated on purpose reaches the check after the
  # hashes. Fields are read as stored; nothing is validated here.
  def rehash(bytes, files: true)
    count = field(bytes, 24, 4)
    strings_end = field(bytes, 40, 8) + field(bytes, 48, 4)
    index_end = [round_page(strings_end), bytes.bytesize].min
    if files
      entries = (0...count).map { |index| HEADER + index * ENTRY }
                           .select { |offset| offset + ENTRY <= index_end }
      runs = entries.map do |offset|
        start = field(bytes, offset + 8, 8)
        [offset, start, [round_page(start + field(bytes, offset + 16, 8)), bytes.bytesize].min]
      end.select { |_offset, start, finish| start <= finish }
      digests = b3sum(runs.map { |_offset, start, finish| bytes.byteslice(start, finish - start) })
      runs.zip(digests) { |(offset, _start, _finish), digest| bytes[offset + FILE_HASH, 32] = digest }
    end
    bytes[INDEX_HASH, 32] = "\0".b * 32
    bytes[INDEX_HASH, 32] = b3sum([bytes.byteslice(0, index_end)]).first
    bytes
  end

  def root_offset(bytes)
    index = field(bytes, 52, 4)
    field(bytes, HEADER + index * ENTRY + 8, 8)
  end

  def entry_offset(index) = HEADER + index * ENTRY

  def round_page(value) = (value + PAGE - 1) / PAGE * PAGE

  # BLAKE3's Rust implementation, as the b3sum tool installs it, one 32-byte
  # digest per message.
  def b3sum(messages)
    return [] if messages.empty?

    tool = ENV.fetch('ERX_B3SUM') do
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |entry| File.join(entry, 'b3sum') }
         .find { |path| File.executable?(path) }
    end
    raise 'b3sum is the pack fixture oracle and is not installed (brew install b3sum)' if tool.nil?

    Dir.mktmpdir('erx-pack-fixture-') do |directory|
      paths = messages.each_with_index.map do |message, index|
        File.join(directory, "run-#{index}").tap { |path| File.binwrite(path, message) }
      end
      output, status = Open3.capture2(tool, '--no-names', *paths, stdin_data: '')
      digests = output.lines(chomp: true)
      raise "b3sum failed or gave #{digests.size} digests" unless status.success? && digests.size == paths.size

      digests.map { |digest| [digest].pack('H*') }
    end
  end
end
