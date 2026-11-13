# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require_relative 'bounded_file'
require_relative 'runner'

module Erx
  # BLAKE3 digests of byte runs of a file, from the host program pack-hash
  # (tools/host/pack_hash.c, built by PackTools from BLAKE3's C), since Ruby's
  # standard library has no BLAKE3. It knows nothing of the archive's format.
  class PackHasher
    DIGEST = /\A[0-9a-f]{64}\z/

    def initialize(helper:, runner:)
      unless helper.respond_to?(:run) && (!helper.respond_to?(:tool) || helper.tool == 'hasher')
        raise Error, 'pack hashing requires the hasher helper'
      end
      @helper = helper
      @runner = runner
    end

    # runs: [offset, length] pairs inside the file at path. Returns one
    # 32-byte digest per run, in order.
    def digests(path, runs)
      raise Error, 'pack hashing needs at least one run' if runs.empty?
      Dir.mktmpdir('erx-pack-hash-') do |directory|
        list = File.join(directory, 'runs')
        File.binwrite(list, runs.map { |offset, length| "#{Integer(offset)} #{Integer(length)}\n" }.join)
        record = @helper.run([path, list], runner: @runner, name: 'pack-hash', deadline: 300)
        lines = BoundedFile.read(record.fetch('log'), maximum: 65 * (runs.size + 1)).lines(chomp: true)
        unless lines.size == runs.size && lines.all? { |line| DIGEST.match?(line) }
          raise Error, "pack-hash gave #{lines.size} digests for #{runs.size} runs"
        end
        lines.map { |line| [line].pack('H*') }
      end
    end
  end

  # Canonical wire serialization has no admission or publication authority.
  # Pack.build owns production admission and atomic publication. Test tooling
  # can serialize a structural fixture without manufacturing an Admitted value.
  #
  # The archive (ERXPACK version 2, design-kernel.md, The boot image) is its
  # index run, the header, entries and strings to the first page boundary,
  # then each file's run, its data and zeros to the next page boundary.
  # The writer streams every run with the hash fields zero, then fills them
  # in from the bytes on disk: each entry's file hash, then the build
  # identifier, the first bytes of the index run's hash with both identity
  # fields zero, then the index hash, with its own field zero.
  class PackWire
    # Each file of an archive as [path, entry], in the index's order. A strings area or
    # a path outside the archive is refused, never read short.
    def self.entries_of(bytes, codec)
      header = codec.decode_layout('erx_pack_header', bytes)
      within = ->(offset, length, size) { offset + length <= size }
      raise Error, 'the archive\'s strings lie outside it' unless
        within.call(header.fetch('strings_off'), header.fetch('strings_size'), bytes.bytesize)

      strings = bytes.byteslice(header.fetch('strings_off'), header.fetch('strings_size'))
      Array.new(header.fetch('nentries')) do |index|
        at = header.fetch('entries_off') + index * header.fetch('entry_size')
        entry = codec.decode_layout('erx_pack_entry', bytes.byteslice(at, header.fetch('entry_size')))
        raise Error, "the archive's entry #{index} names a path outside its strings" unless
          within.call(entry.fetch('path_off'), entry.fetch('path_len'), strings.bytesize)

        [strings.byteslice(entry.fetch('path_off'), entry.fetch('path_len')), entry]
      end
    end

    ZERO_CHUNK = ("\0".b * 65_536).freeze
    Layout = Data.define(:header, :entries, :strings, :index_end, :total)
    private_constant :Layout

    def initialize(codec:, hasher: nil)
      @codec = codec
      @hasher = hasher
    end

    def image_manifest(plan)
      names = %w[flags span fixed_base entry phdr_offset phnum base_alignment]
      plan.select { |key, _| names.include?(key) }.merge(
        'magic' => @codec.constant('image_magic'), 'version' => @codec.constant('image_version'),
        'abi_version' => plan.fetch('abi_version'),
        'segments' => plan.fetch('loads').map { |load| load.reject { |key, _| key == 'source_offset' }.freeze }.freeze
      ).freeze
    end

    # test_code marks a test image (ProductionImage's test entry point), which only a
    # development build may be; the kernel refuses the mark on any other.
    def write(rows:, root_entry:, build_kind:, output:, budget:, test_code: false)
      raise Error, 'canonical pack output must start at offset zero' unless output.pos.zero?
      raise Error, 'canonical pack writing needs a hasher' unless @hasher.respond_to?(:digests)
      raise Error, 'canonical pack output must be a file' unless output.respond_to?(:path)
      output.seek(0)
      layout = plan(rows, root_entry: root_entry, build_kind: build_kind, budget: budget, test_code: test_code)
      stream(layout, rows, output)
      fill_hashes(layout, output)
      output.seek(layout.total)
      layout.total
    rescue Errno::ESPIPE => error
      raise Error, "canonical pack output must be seekable: #{error.message}"
    end

    private

    # Every offset of the archive, with all three hash fields zero, decided
    # before the first byte is written. A refusal leaves the output untouched.
    def plan(rows, root_entry:, build_kind:, budget:, test_code:)
      check_request(rows, root_entry: root_entry, build_kind: build_kind, budget: budget)
      raise Error, 'invalid pack test-code mark' unless [true, false].include?(test_code)
      raise Error, 'only a development build carries test code' if test_code && build_kind != 'development'
      strings = rows.map { |row| row.fetch('path').b }.join
      raise Error, 'pack strings exceed their bound' if strings.bytesize > @codec.constant('pack_strings_max')
      header_size = @codec.layout_size('erx_pack_header')
      entry_size = @codec.layout_size('erx_pack_entry')
      zero_hash = "\0".b * @codec.constant('pack_hash_size')
      strings_off = header_size + rows.size * entry_size
      index_end = round_page(strings_off + strings.bytesize)
      cursor = index_end
      string_cursor = 0
      entries = rows.map do |row|
        entry = { 'path_off' => string_cursor, 'path_len' => row.fetch('path').bytesize,
                  'kind' => row.fetch('kind'), 'flags' => row.fetch('flags'),
                  'data_off' => cursor, 'data_size' => row.fetch('size'), 'manifest_off' => 0,
                  'file_hash' => zero_hash }.freeze
        string_cursor += row.fetch('path').bytesize
        cursor += round_page(row.fetch('size'))
        entry
      end.freeze
      raise Error, 'complete pack exceeds host budget' if cursor > budget
      flags = (build_kind == 'development' ? @codec.member('pack_flags', 'development') : 0) |
              (test_code ? @codec.member('pack_flags', 'test_code') : 0)
      header = { 'version' => @codec.constant('pack_version'), 'flags' => flags,
                 'total_size' => cursor, 'nentries' => rows.size, 'entry_size' => entry_size,
                 'entries_off' => header_size, 'strings_off' => strings_off,
                 'strings_size' => strings.bytesize, 'root_entry' => root_entry,
                 'build_id' => "\0".b * identity_size, 'index_hash' => zero_hash }.freeze
      Layout.new(header: header, entries: entries, strings: strings.freeze, index_end: index_end, total: cursor)
    end

    def check_request(rows, root_entry:, build_kind:, budget:)
      unless rows.is_a?(Array) && rows.size.between?(1, @codec.constant('pack_entries_max')) &&
             %w[development release].include?(build_kind) &&
             root_entry.is_a?(Integer) && root_entry.between?(0, rows.size - 1) &&
             budget.is_a?(Integer) && budget.between?(1, 512 * 1024 * 1024)
        raise Error, 'invalid canonical pack serialization request'
      end
      rows.each do |row|
        unless row.is_a?(Hash) && row['path'].is_a?(String) &&
               row.fetch('path').bytesize.between?(1, @codec.constant('pack_path_max')) &&
               row['size'].is_a?(Integer) && row.fetch('size').between?(0, budget)
          raise Error, 'invalid canonical pack row'
        end
        if row['kind'] == @codec.member('entry_kind', 'directory') && !row.fetch('size').zero?
          raise Error, 'an empty directory has no contents'
        end
      end
    end

    def stream(layout, rows, output)
      write_all(output, @codec.encode_layout('erx_pack_header', layout.header))
      write_entries(output, layout.entries)
      write_all(output, layout.strings)
      zero(output, layout.index_end - output.pos)
      rows.each do |row|
        if row.fetch('kind') == @codec.member('entry_kind', 'directory')
          next # an empty directory's run is empty
        elsif row.key?('plan')
          write_image(row, output)
        else
          File.open(row.fetch('snapshot'), 'rb') do |input|
            copied = IO.copy_stream(input, output, row.fetch('size'))
            raise Error, 'truncated immutable pack snapshot' unless copied == row.fetch('size')
          end
        end
        zero(output, round_page(output.pos) - output.pos)
      end
      raise Error, 'pack writer disagrees with its storage plan' unless output.pos == layout.total
    end

    # Each hash covers what the one before it wrote, so the order is the
    # format's: the file hashes go into the entries; the build identifier
    # hashes the index run with both identity fields still zero; the index
    # hash covers that identifier, with its own field still zero.
    def fill_hashes(layout, output)
      output.flush
      runs = layout.entries.map { |entry| [entry.fetch('data_off'), round_page(entry.fetch('data_size'))] }
      entries = layout.entries.zip(@hasher.digests(output.path, runs))
                      .map { |entry, digest| entry.merge('file_hash' => digest) }
      output.seek(layout.header.fetch('entries_off'))
      write_entries(output, entries)
      identity = index_digest(output, layout).byteslice(0, identity_size)
      identified = layout.header.merge('build_id' => identity)
      rewrite_header(output, identified)
      rewrite_header(output, identified.merge('index_hash' => index_digest(output, layout)))
    end

    def index_digest(output, layout)
      output.flush
      @hasher.digests(output.path, [[0, layout.index_end]]).first
    end

    def identity_size
      @codec.schema.types.fetch('erx_pack_header').fields.find { |field| field.name == 'build_id' }.size
    end

    def rewrite_header(output, header)
      output.seek(0)
      write_all(output, @codec.encode_layout('erx_pack_header', header))
    end

    def write_entries(output, entries)
      entries.each { |entry| write_all(output, @codec.encode_layout('erx_pack_entry', entry)) }
    end

    def write_all(output, bytes)
      raise Error, 'canonical pack output wrote a short block' unless output.write(bytes) == bytes.bytesize
    end

    def write_image(row, output)
      first = output.pos
      manifest = @codec.encode_layout('erx_image_manifest', row.fetch('image'))
      write_all(output, manifest)
      zero(output, @codec.constant('page_size') - manifest.bytesize)
      File.open(row.fetch('snapshot'), 'rb') do |input|
        row.fetch('plan').fetch('loads').each do |load|
          raise Error, 'image writer disagrees with its segment offset' unless output.pos - first == load.fetch('file_offset')
          input.seek(load.fetch('source_offset'))
          copied = IO.copy_stream(input, output, load.fetch('file_size'))
          raise Error, 'truncated immutable executable snapshot' unless copied == load.fetch('file_size')
          stored = load.fetch('prot') == @codec.member('prot', 'rw') ? load.fetch('file_size') : load.fetch('mem_size')
          zero(output, round_page(stored) - copied)
        end
      end
      raise Error, 'image writer disagrees with its output size' unless output.pos - first == row.fetch('size')
    end

    def round_page(value)
      page = @codec.constant('page_size')
      ((value + page - 1) / page) * page
    end

    def zero(output, count)
      raise Error, 'negative pack padding' if count.negative?
      while count.positive?
        amount = [count, ZERO_CHUNK.bytesize].min
        write_all(output, ZERO_CHUNK.byteslice(0, amount))
        count -= amount
      end
    end
  end
end
