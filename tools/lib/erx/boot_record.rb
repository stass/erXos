# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'generated_abi'
require_relative 'error'

module Erx
  # The boot-selection record and the QEMU harness's slot parser
  # (docs/design-platforms.md, "Slots and the boot-selection record"), both laid out
  # by the medium layout of the ABI file (abi/medium.txt), its one source.
  #
  # The record is one sector with exactly two encodings, one per committed slot: the
  # text medium_record_a or medium_record_b, then zeros. The packer writes it with
  # sector; the harness, which plays the firmware, reads it back with committed and
  # boots the slot it names.
  #
  # The slot parser, choose, takes the record's sector and the first bytes of the
  # chosen slot's bootable file, both of which a guest may have written, and answers
  # where on the medium the bootable file lies: from the slot's medium_slot_boot_start
  # for the length its boot header's image_size records. It refuses an unreadable
  # record, a header without its magic, and a length shorter than the header or
  # reaching past the slot's end. read applies it to a medium file and extract copies
  # the file it names. tools/fuzz/boot_record.rb is its fuzz target.
  module BootRecord
    CODEC = ABI::Generated::CODEC
    SECTOR_BYTES = CODEC.constant('mbr_sector_size')
    HEADER = 'erx_arch_boot_header'
    HEADER_BYTES = CODEC.layout_size(HEADER)
    MAGIC = CODEC.fixed_bytes('arch_boot_magic')

    # Each slot: the text of the record that commits it, its partition's number as
    # firmware names it in /chosen/bootloader/partition, and its first sector.
    Slot = Data.define(:name, :text, :partition, :start)
    SLOTS = %w[a b].to_h do |name|
      [name.to_sym, Slot.new(name: name.to_sym, text: CODEC.fixed_bytes("medium_record_#{name}").b.freeze,
                             partition: CODEC.constant("medium_slot_#{name}_partition"),
                             start: CODEC.constant("medium_slot_#{name}_start"))]
    end.freeze
    SLOT_SECTORS = CODEC.constant('medium_slot_sectors')
    # The record's and the bootable file's places on the medium, in bytes.
    RECORD_OFFSET = (CODEC.constant('medium_record_start') + CODEC.constant('medium_record_select_start')) * SECTOR_BYTES
    BOOT_START = CODEC.constant('medium_slot_boot_start')

    # Where the chosen slot's bootable file lies: the slot, the medium's offset of its
    # first byte and its length, both in bytes.
    Choice = Data.define(:slot, :offset, :length)

    module_function

    # The record's sector while slot is committed: its text, then zeros.
    def sector(slot)
      text = SLOTS.fetch(slot) { raise Error, "no slot #{slot.inspect}" }.text
      (text + ("\0".b * (SECTOR_BYTES - text.bytesize))).freeze
    end

    # The slot a record's sector commits, :a or :b; anything but one of the two
    # encodings, byte for byte, is an unreadable record.
    def committed(bytes)
      found = SLOTS.each_key.find { |slot| bytes.is_a?(String) && bytes.b == sector(slot) }
      raise Error, 'the boot-selection record is unreadable: it is neither of its two encodings' unless found

      found
    end

    # The slot parser: from the record's sector and the first HEADER_BYTES bytes of the
    # committed slot's bootable file, where that file lies on the medium.
    def choose(record:, header:)
      slot = SLOTS.fetch(committed(record))
      unless header.is_a?(String) && header.bytesize == HEADER_BYTES
        raise Error, "slot #{slot.name}'s boot header is not #{HEADER_BYTES} bytes"
      end

      fields = CODEC.decode_layout(HEADER, header.b)
      raise Error, "slot #{slot.name} holds no bootable file: its boot header has no magic" unless fields.fetch('magic').b == MAGIC

      Choice.new(slot: slot.name, offset: boot_offset(slot), length: checked_length(slot, fields.fetch('image_size')))
    rescue ABI::DecodeError => error
      raise Error, "slot #{slot.name}'s boot header does not decode: #{error.reason}"
    end

    # The slot parser over the medium file at path, which must hold the whole file it
    # names.
    def read(path)
      open_medium(path) do |medium|
        record = medium.pread(SECTOR_BYTES, RECORD_OFFSET)
        slot = SLOTS.fetch(committed(record))
        choice = choose(record: record, header: medium.pread(HEADER_BYTES, boot_offset(slot)))
        raise Error, "the medium ends inside slot #{slot.name}'s bootable file" if choice.offset + choice.length > medium.size

        choice
      end
    rescue EOFError
      raise Error, 'the medium ends before the boot-selection record or the bootable file'
    rescue SystemCallError, IOError => error
      raise Error, "cannot read the medium: #{error.message}"
    end

    # Copies the bootable file choice names out of the medium at path into output, a
    # new file; returns output.
    def extract(path, choice, output:)
      open_medium(path) do |medium|
        File.open(output, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
          copied = IO.copy_stream(medium, file, choice.length, choice.offset)
          raise Error, "the medium ends inside slot #{choice.slot}'s bootable file" unless copied == choice.length
        end
      end
      output
    rescue SystemCallError, IOError => error
      raise Error, "cannot extract the bootable file: #{error.message}"
    end

    # The medium at path, which must be a regular file, never a link, a FIFO or a device.
    def open_medium(path, &)
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |medium|
        raise Error, "the medium #{path} is not a regular file" unless medium.stat.file?

        yield medium
      end
    end

    def boot_offset(slot) = (slot.start + BOOT_START) * SECTOR_BYTES

    # The header's image_size, which in the single file is the file's exact length,
    # when it covers the header and stays inside the slot.
    def checked_length(slot, length)
      room = (SLOT_SECTORS - BOOT_START) * SECTOR_BYTES
      return length if length.is_a?(Integer) && length.between?(HEADER_BYTES, room)

      raise Error, "slot #{slot.name}'s bootable file claims #{length} bytes, not #{HEADER_BYTES} to #{room}"
    end
    private_class_method :open_medium, :boot_offset, :checked_length
  end
end
