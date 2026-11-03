# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'runner'

module Erx
  # Canonical wire serialization has no admission or publication authority.
  # Pack.build owns production admission and atomic publication. Test tooling
  # can serialize a structural fixture without manufacturing an Admitted value.
  class PackWire
    ZERO_CHUNK = ("\0".b * 65_536).freeze

    # IO.copy_stream uses #write on this adapter, so payloads, padding and
    # metadata all reach the same identity calculation without a readback.
    class DigestOutput
      def initialize(output, digest)
        @output = output
        @digest = digest
      end

      def write(bytes)
        count = @output.write(bytes)
        raise Error, 'canonical pack output wrote a short block' unless count == bytes.bytesize
        @digest.update(bytes)
        count
      end

      def pos
        @output.pos
      end
    end
    private_constant :DigestOutput

    def initialize(codec:)
      @codec = codec
    end

    def image_manifest(plan)
      names = %w[flags span fixed_base entry phdr_offset phnum base_alignment]
      plan.select { |key, _| names.include?(key) }.merge(
        'magic' => @codec.constant('image_magic'), 'version' => @codec.constant('image_version'),
        'abi_version' => plan.fetch('abi_version'),
        'segments' => plan.fetch('loads').map { |load| load.reject { |key, _| key == 'source_offset' }.freeze }.freeze
      ).freeze
    end

    def write(rows:, root_entry:, build_kind:, output:, budget:)
      raise Error, 'canonical pack output must start at offset zero' unless output.pos.zero?
      output.seek(0)
      unless rows.is_a?(Array) && rows.size.between?(1, @codec.constant('pack_entries_max')) &&
             %w[development release].include?(build_kind) &&
             root_entry.is_a?(Integer) && root_entry.between?(0, rows.size - 1) &&
             budget.is_a?(Integer) && budget.between?(1, 512 * 1024 * 1024)
        raise Error, 'invalid canonical pack serialization request'
      end
      string_size = rows.sum do |row|
        unless row.is_a?(Hash) && row['path'].is_a?(String) &&
               row.fetch('path').bytesize.between?(1, @codec.constant('pack_path_max')) &&
               row['size'].is_a?(Integer) && row.fetch('size').between?(0, budget)
          raise Error, 'invalid canonical pack row'
        end
        row.fetch('path').bytesize
      end
      raise Error, 'pack strings exceed their bound' if string_size > @codec.constant('pack_strings_max')
      header_size = @codec.layout_size('erx_pack_header')
      entry_size = @codec.layout_size('erx_pack_entry')
      strings = rows.map { |row| row.fetch('path') }.join.b
      strings_off = header_size + rows.size * entry_size
      cursor = round_page(strings_off + strings.bytesize)
      string_cursor = 0
      entries = rows.map do |row|
        entry = { 'path_off' => string_cursor, 'path_len' => row.fetch('path').bytesize,
                  'kind' => row.fetch('kind'), 'flags' => row.fetch('flags'),
                  'data_off' => cursor, 'data_size' => row.fetch('size'), 'manifest_off' => 0 }
        string_cursor += row.fetch('path').bytesize
        cursor += round_page(row.fetch('size'))
        @codec.encode_layout('erx_pack_entry', entry)
      end
      raise Error, 'complete pack exceeds host budget' if cursor > budget
      identity_size = @codec.schema.types.fetch('erx_pack_header').fields.find { |field| field.name == 'build_id' }.size
      flags = build_kind == 'development' ? @codec.member('pack_flags', 'development') : 0
      header = { 'version' => @codec.constant('pack_version'), 'flags' => flags,
                 'total_size' => cursor, 'nentries' => rows.size, 'entry_size' => entry_size,
                 'entries_off' => header_size, 'strings_off' => strings_off,
                 'strings_size' => strings.bytesize, 'root_entry' => root_entry,
                 'build_id' => "\0".b * identity_size }
      digest = Digest::SHA256.new
      stream = DigestOutput.new(output, digest)
      stream.write(@codec.encode_layout('erx_pack_header', header))
      entries.each { |entry| stream.write(entry) }
      stream.write(strings)
      zero(stream, round_page(stream.pos) - stream.pos)
      rows.each do |row|
        if row.key?('plan')
          write_image(row, stream)
        else
          File.open(row.fetch('snapshot'), 'rb') do |input|
            copied = IO.copy_stream(input, stream, row.fetch('size'))
            raise Error, 'truncated immutable pack snapshot' unless copied == row.fetch('size')
          end
        end
        zero(stream, round_page(stream.pos) - stream.pos)
      end
      raise Error, 'pack writer disagrees with its storage plan' unless output.pos == cursor
      # The identity covers the complete canonical wire bytes with its own
      # field zero. Rewrite the entire source-encoded header, then restore EOF.
      output.seek(0)
      header['build_id'] = digest.digest.byteslice(0, identity_size)
      final_header = @codec.encode_layout('erx_pack_header', header)
      raise Error, 'canonical pack header wrote a short block' unless output.write(final_header) == final_header.bytesize
      output.seek(cursor)
      cursor
    rescue Errno::ESPIPE => error
      raise Error, "canonical pack output must be seekable: #{error.message}"
    end

    private

    def write_image(row, output)
      first = output.pos
      manifest = @codec.encode_layout('erx_image_manifest', row.fetch('image'))
      output.write(manifest)
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
        output.write(ZERO_CHUNK.byteslice(0, amount))
        count -= amount
      end
    end
  end
end
