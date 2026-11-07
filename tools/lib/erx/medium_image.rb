# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require_relative 'generated_abi'
require_relative 'block_image'
require_relative 'error'

module Erx
  # A disk image laid out by the boot medium's layout of the ABI file (abi/medium.txt,
  # docs/design-storage.md, "The boot medium's table"): the master boot record and the
  # two extended boot records at the sectors the layout fixes, each entry encoded through
  # the ABI codec's erx_mbr_entry, and the pieces its caller places inside the windows.
  # Every other sector is a hole in a sparse file, which reads as zeros, so a medium of
  # the layout's full size costs only the blocks its pieces fill.
  #
  # Two kinds of medium use the one writer, create: the block device suite's, whose
  # pieces (probes) are the host's pattern (BlockImage.pattern, which names its sector's
  # index) in the first and last sector of every window, and the release medium
  # (ReleaseMedium), whose pieces are slot A's bootable file and EROFS images.
  #
  # This writer and the driver's parser, erx_blk_table, share the layout and nothing
  # else, so the tests check one against the other.
  module MediumImage
    CODEC = ABI::Generated::CODEC
    SECTOR_BYTES = BlockImage::SECTOR_BYTES
    # The data partition's length in the suite's medium: the layout's minimum and one
    # MiB more, so the length the medium chooses is not the minimum.
    DATA_SECTORS = CODEC.constant('medium_data_sectors_min') + 2048
    # A bound on what the suite's checker reads: the layout and 4 GiB of data partition.
    MAX_SECTORS = CODEC.constant('medium_data_start') + (1 << 23)
    ROLES = %i[record slot_a slot_b vault data].freeze

    # One window: its role, its first sector on the medium and its length.
    Window = Data.define(:role, :start, :sectors) do
      def last = start + sectors - 1
    end
    # A piece of a medium taken from the regular host file at path, whose length its
    # caller measured once; the writer copies exactly that many bytes and refuses a file
    # that has changed length since.
    FilePiece = Data.define(:path, :length)

    module_function

    def constant(name) = CODEC.constant("medium_#{name}")

    # The windows of a medium whose data partition has data_sectors sectors, in the
    # order erx_blk_table admits them.
    def windows(data_sectors: DATA_SECTORS)
      [Window.new(role: :record, start: constant('record_start'), sectors: constant('record_sectors')),
       Window.new(role: :slot_a, start: constant('slot_a_start'), sectors: constant('slot_sectors')),
       Window.new(role: :slot_b, start: constant('slot_b_start'), sectors: constant('slot_sectors')),
       Window.new(role: :vault, start: constant('vault_start'), sectors: constant('vault_sectors')),
       Window.new(role: :data, start: constant('data_start'), sectors: data_sectors)].freeze
    end

    # The medium's length in sectors: through the end of the data partition.
    def sectors(data_sectors: DATA_SECTORS) = constant('data_start') + data_sectors

    # The three records, by sector. An extended boot record's first entry starts
    # relative to its own sector; the vault record's link to the data record starts
    # relative to the extended partition and spans the data record and its partition.
    def records(data_sectors: DATA_SECTORS)
      data_end = sectors(data_sectors: data_sectors)
      extended = constant('extended_start')
      data_ebr = constant('data_ebr')
      { 0 => record([entry('record_type', constant('record_start'), constant('record_sectors')),
                     entry('slot_type', constant('slot_a_start'), constant('slot_sectors')),
                     entry('slot_type', constant('slot_b_start'), constant('slot_sectors')),
                     entry('extended_type', extended, data_end - extended)]),
        extended => record([entry('vault_type', constant('vault_start') - extended, constant('vault_sectors')),
                            entry('link_type', data_ebr - extended, data_end - data_ebr)]),
        data_ebr => record([entry('data_type', constant('data_start') - data_ebr, data_sectors)]) }.freeze
    end

    # Writes the medium as name in directory, which the caller made with OutputDirectory
    # and owns; an existing name or a link is refused. pieces maps a sector to the bytes
    # written from it, a string or a FilePiece; each must lie inside one window and
    # overlap no other. The medium is written under a private name beside it and linked
    # to name whole, so a failed write leaves nothing at name. Returns its path.
    def create(directory:, name:, pieces:, data_sectors: DATA_SECTORS)
      raise Error, 'a disk image name is a plain file name' unless name.is_a?(String) && BlockImage::NAME.match?(name)
      raise Error, 'the disk image directory is not a directory' unless directory.is_a?(String) && File.directory?(directory)

      lengths = piece_lengths(pieces, data_sectors: data_sectors)
      path = File.join(File.realpath(directory), name)
      Dir.mktmpdir('.erx-medium-', File.dirname(path)) do |workspace|
        temporary = File.join(workspace, name)
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |output|
          output.binmode
          records(data_sectors: data_sectors).each { |index, bytes| output.pwrite(bytes, index * SECTOR_BYTES) }
          pieces.sort_by(&:first).each { |index, piece| put(output, index, piece, length: lengths.fetch(index)) }
          output.truncate(sectors(data_sectors: data_sectors) * SECTOR_BYTES)
        end
        File.link(temporary, path)
      end
      path
    rescue SystemCallError, IOError => error
      raise Error, "cannot create disk image: #{error.message}"
    end

    # The block device suite's pieces: the host's pattern in each window's first and last
    # sector.
    def probes(data_sectors)
      windows(data_sectors: data_sectors).flat_map { |window| [window.start, window.last] }
                                         .to_h { |index| [index, BlockImage.pattern(index, tag: BlockImage::HOST_TAG)] }
    end

    # Each piece's length in bytes, by sector, once every piece is found to lie inside
    # one window and to overlap no other piece. Pure: a file piece carries its length.
    def piece_lengths(pieces, data_sectors:)
      lengths = pieces.to_h { |index, piece| [index, piece.is_a?(FilePiece) ? piece.length : piece.bytesize] }
      areas = windows(data_sectors: data_sectors)
      lengths.sort.each_cons(2) do |(first, length), (second, _)|
        raise Error, "the pieces at sectors #{first} and #{second} overlap" if first + sectors_of(length) > second
      end
      lengths.each do |index, length|
        last = index + sectors_of(length) - 1
        unless length.is_a?(Integer) && length.positive? && areas.any? { |window| index >= window.start && last <= window.last }
          raise Error, "the piece at sector #{index} does not lie inside one window"
        end
      end
      lengths
    end

    def put(output, index, piece, length:)
      return output.pwrite(piece, index * SECTOR_BYTES) unless piece.is_a?(FilePiece)

      File.open(piece.path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
        raise Error, "#{piece.path} is not a regular file of #{length} bytes" unless input.stat.file? && input.stat.size == length

        output.seek(index * SECTOR_BYTES)
        copied = IO.copy_stream(input, output, length)
        raise Error, "the file #{piece.path} changed while it was written" unless copied == length && input.eof?
      end
    end

    def sectors_of(bytes) = (bytes + SECTOR_BYTES - 1) / SECTOR_BYTES

    def entry(type, start, count)
      CODEC.encode_layout('erx_mbr_entry', 'status' => CODEC.constant('mbr_status_inactive'), 'chs_first' => [0, 0, 0],
                                           'type' => constant(type), 'chs_last' => [0, 0, 0], 'lba_start' => start,
                                           'lba_sectors' => count)
    end

    # A record: zeros, the entries from the entries' offset, unused entries zero, and the
    # signature.
    def record(entries)
      bytes = "\0".b * CODEC.constant('mbr_sector_size')
      bytes[CODEC.constant('mbr_entries_offset'), entries.sum(&:bytesize)] = entries.join
      bytes[CODEC.constant('mbr_signature_offset'), 2] = [CODEC.constant('mbr_signature')].pack('v')
      bytes.freeze
    end
    private_class_method :entry, :record, :piece_lengths, :put, :sectors_of
  end
end
