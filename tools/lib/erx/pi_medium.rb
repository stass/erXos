# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require_relative 'boot_record'
require_relative 'bounded_file'
require_relative 'data_volume'
require_relative 'error'
require_relative 'fat_short_names'
require_relative 'fat_volume'
require_relative 'medium_image'
require_relative 'release_medium'

module Erx
  # The Raspberry Pi's card, the medium of abi/medium.txt as the firmware boots it
  # (docs/design-stopgap.md, "The Raspberry Pi 4"; docs/design-platforms.md, "Slots and
  # the boot-selection record"), written through MediumImage:
  #
  # * the record partition: an 8 MiB FAT16 whose one file, autoboot.txt, is the record
  #   committing slot A (medium_record_a), placed by fsimg at the record's sector
  #   (medium_record_select_start), the data area's first cluster; the reset count's
  #   sector (medium_record_count_start) lies in the reserved area, which fsimg leaves
  #   zero, and is not written, since abi/medium.txt defines no encoding of the count;
  # * slot A: a FAT32 of the slot's first 128 MiB holding the boot files, with
  #   kernel8.img placed by fsimg at medium_slot_boot_start, so the QEMU harness and the
  #   slot writer find it without parsing FAT, and after it the release's EROFS image at
  #   ReleaseMedium::SLOT_IMAGES_START;
  # * slot B and the vault's partition empty, and the data partition a fresh littlefs
  #   volume (DataVolume) running to the medium's end.
  #
  # The medium's length is a power of two, the smallest that holds the layout's minimum
  # data partition, and every byte no piece holds is zero. After fsimg writes each
  # volume, check_volumes reads it back through FatVolume, which shares no code with
  # fsimg: each placed file's directory entry and whole cluster chain, the placed bytes,
  # the record's sector byte for byte, and each boot file's short name.
  module PiMedium
    SECTOR_BYTES = MediumImage::SECTOR_BYTES
    MIB = 1 << 20
    BOOT_FILE = 'kernel8.img'
    RECORD_FILE = 'autoboot.txt'
    RECORD_BYTES = MediumImage.constant('record_sectors') * SECTOR_BYTES
    # Byte offsets inside the record volume: the record and the reset count.
    RECORD_PLACE = MediumImage.constant('record_select_start') * SECTOR_BYTES
    COUNT_OFFSET = MediumImage.constant('record_count_start') * SECTOR_BYTES
    # Slot A's FAT ends where the slot's EROFS images start.
    SLOT_FAT_BYTES = ReleaseMedium::SLOT_IMAGES_START
    BOOT_PLACE = MediumImage.constant('slot_boot_start') * SECTOR_BYTES
    # Every time in either volume is 1980-01-01, FAT's first representable date, so the
    # bytes are reproducible.
    EPOCH = %w[-R -e 315532800].freeze
    # Each volume's fsimg arguments: its format, then its one placed file, which fsimg
    # names by its absolute path in the volume and places at a byte offset of it.
    # * The record volume: 512-byte clusters make its 5 MiB data area 10,240 clusters, a
    #   FAT16 by count, and the record one cluster of its own.
    # * Slot A's volume: 1 KiB clusters make 124 MiB of data area some 127,000 clusters,
    #   a FAT32 by count as the slot's partition type (0x0c) says; 2 KiB would make it a
    #   FAT16.
    RECORD_FORMAT = ['-F', 'fat16', *EPOCH, '-s', RECORD_BYTES.to_s, '-L', 'ERXREC', '-o', 'cluster=512'].freeze
    SLOT_FORMAT = ['-F', 'fat32', *EPOCH, '-s', SLOT_FAT_BYTES.to_s, '-L', 'ERXOS', '-o', 'cluster=1024'].freeze
    RECORD_VOLUME = [*RECORD_FORMAT, '-o', "place=/#{RECORD_FILE}@#{RECORD_PLACE}"].freeze
    SLOT_VOLUME = [*SLOT_FORMAT, '-o', "place=/#{BOOT_FILE}@#{BOOT_PLACE}"].freeze
    VOLUME_DEADLINE = 300

    module_function

    # The volumes' arguments as the card's build record names them: each format and its
    # placed file's name and offset, which spell the place setting without the leading
    # slash a published record refuses as a host path (BootPartition.check_record).
    def arguments
      { 'record' => { 'format' => RECORD_FORMAT, 'place' => { RECORD_FILE => RECORD_PLACE } },
        'slot' => { 'format' => SLOT_FORMAT, 'place' => { BOOT_FILE => BOOT_PLACE } } }
    end

    # The data partition's length in sectors: what takes the medium from the data
    # partition's start to the smallest power of two that holds the layout's minimum.
    # Pure.
    def data_sectors
      start = MediumImage.constant('data_start')
      least = start + MediumImage.constant('data_sectors_min')
      (1 << (least - 1).bit_length) - start
    end

    # Writes the card as name in directory, a work directory the caller owns: slot A's
    # FAT of the files staged in files, whose root names are names; the release's EROFS
    # image at erofs; the data partition's fresh volume, a MediumImage::FilePiece
    # formatted for data_sectors (DataVolume.format). Returns the card's path.
    def write(directory:, name:, files:, names:, erofs:, volume:, runner:, fsimg:)
      Dir.mktmpdir('.pi-medium-', directory) do |work|
        record = File.join(work, 'record.fat')
        slot = File.join(work, 'slot.fat')
        record_files = File.join(work, 'record')
        Dir.mkdir(record_files)
        File.binwrite(File.join(record_files, RECORD_FILE), BootRecord::SLOTS.fetch(:a).text)
        runner.run([fsimg, 'cW', '-f', record, *RECORD_VOLUME, '-C', record_files, '.'], name: 'fsimg-record-volume',
                                                                                     deadline: VOLUME_DEADLINE)
        runner.run([fsimg, 'cW', '-f', slot, *SLOT_VOLUME, '-C', files, '.'], name: 'fsimg-slot-volume',
                                                                          deadline: VOLUME_DEADLINE)
        boot = BoundedFile.read(File.join(files, BOOT_FILE), maximum: SLOT_FAT_BYTES)
        check_volumes(record: record, slot: slot, boot: boot, names: names)
        MediumImage.create(directory: directory, name: name, data_sectors: data_sectors,
                           pieces: pieces(record: record, slot: slot, erofs: erofs, volume: volume))
      end
    end

    # Refuses the volumes unless the record volume is a FAT16 whose data area starts with
    # autoboot.txt placed at its record sector, which reads as medium_record_a and zeros
    # to the sector's end, and whose FATs start after the reset count's MiB, so the count's
    # sector, which is zero, is reserved and alone in its erase unit; and the slot volume
    # is a FAT32 whose data area starts with boot placed at the slot's boot start and that
    # holds each of names under its own short name.
    def check_volumes(record:, slot:, boot:, names:)
      FatVolume.open(record) do |volume|
        FatVolume.check_placed(volume, kind: :fat16, short: FatShortNames.short_form(RECORD_FILE).name, offset: RECORD_PLACE,
                                       contents: BootRecord::SLOTS.fetch(:a).text)
        volume.refuse("the record's sector is not medium_record_a") unless
          volume.read(RECORD_PLACE, SECTOR_BYTES) == BootRecord.sector(:a)
        volume.refuse('the data area does not start at the record') unless volume.layout.data_offset == RECORD_PLACE
        volume.refuse("the FATs do not start after the reset count's MiB") unless volume.layout.fat_offset >= COUNT_OFFSET + MIB
        volume.refuse("the reset count's sector is not zero") unless volume.read(COUNT_OFFSET, SECTOR_BYTES).count("\0") == SECTOR_BYTES
      end
      FatVolume.open(slot) do |volume|
        FatVolume.check_placed(volume, kind: :fat32, short: FatShortNames.short_form(BOOT_FILE).name, offset: BOOT_PLACE,
                                       contents: boot)
        volume.refuse('the data area does not start at the bootable file') unless volume.layout.data_offset == BOOT_PLACE
      end
      FatShortNames.check(slot, names: names)
    end

    # The card's pieces by sector: the record volume filling its partition, slot A's
    # volume from the slot's start, the EROFS image where ReleaseMedium places a slot's
    # one image, and the data volume's leading blocks.
    def pieces(record:, slot:, erofs:, volume:)
      slot_start = MediumImage.constant('slot_a_start')
      image = ReleaseMedium.image_extent(erofs)
      { MediumImage.constant('record_start') => piece(record),
        slot_start => piece(slot),
        slot_start + (image.slot_offset / SECTOR_BYTES) => piece(erofs),
        **DataVolume.pieces(volume) }
    end

    def piece(path) = MediumImage::FilePiece.new(path: path, length: File.size(path))
    private_class_method :piece
  end
end
