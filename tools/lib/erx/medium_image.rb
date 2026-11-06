# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../generated/abi'
require_relative 'block_image'
require_relative 'error'

module Erx
  # A disk image laid out by the boot medium's layout of the ABI file (abi/medium.txt,
  # docs/design-storage.md, "The boot medium's table"), for the block device suite: the
  # master boot record and the two extended boot records at the sectors the layout
  # fixes, each entry encoded through the ABI codec's erx_mbr_entry, and the host's
  # pattern (BlockImage.pattern, which names its sector's index) in the first and last
  # sector of every partition. Every other sector is a hole in a sparse file, which
  # reads as zeros, so a medium of the layout's full size costs a few blocks of the host.
  #
  # This writer and the driver's parser, erx_blk_table, share the layout and nothing
  # else, so the suite checks one against the other.
  module MediumImage
    CODEC = ABI::Generated::CODEC
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

    # Writes the medium as name in directory, which the caller made with
    # OutputDirectory and owns; an existing name or a link is refused. Returns its path.
    def create(directory:, name:, data_sectors: DATA_SECTORS)
      raise Error, 'a disk image name is a plain file name' unless name.is_a?(String) && BlockImage::NAME.match?(name)
      raise Error, 'the disk image directory is not a directory' unless directory.is_a?(String) && File.directory?(directory)

      path = File.join(File.realpath(directory), name)
      flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
      File.open(path, flags, 0o600) do |output|
        output.binmode
        contents(data_sectors: data_sectors).each { |index, bytes| output.pwrite(bytes, index * BlockImage::SECTOR_BYTES) }
        output.truncate(sectors(data_sectors: data_sectors) * BlockImage::SECTOR_BYTES)
      end
      path
    rescue SystemCallError, IOError => error
      raise Error, "cannot create disk image: #{error.message}"
    end

    # Every sector the image holds data in: the records and the host's pattern in each
    # window's first and last sector.
    def contents(data_sectors:)
      probes = windows(data_sectors: data_sectors).flat_map { |window| [window.start, window.last] }
      probes.to_h { |index| [index, BlockImage.pattern(index, tag: BlockImage::HOST_TAG)] }.merge(records(data_sectors: data_sectors))
    end

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
    private_class_method :entry, :record, :contents
  end
end
