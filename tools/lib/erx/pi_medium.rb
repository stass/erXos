# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require_relative 'bounded_file'
require_relative 'data_volume'
require_relative 'error'
require_relative 'fat_short_names'
require_relative 'fat_volume'
require_relative 'medium_image'
require_relative 'record_volume'
require_relative 'release_medium'

module Erx
  # The Raspberry Pi's card, the medium of abi/medium.txt as the firmware boots it
  # (docs/design-fiasco.md, "The Raspberry Pi 4"; docs/design-platforms.md, "Slots and
  # the boot-selection record"), written through MediumImage:
  #
  # * the record partition: the record volume (RecordVolume), as on QEMU's release
  #   medium, whose autoboot.txt the firmware reads;
  # * boot A: a FAT32 of the whole partition holding the boot files, with kernel8.img
  #   placed by fsimg at medium_slot_boot_start, so the QEMU harness and the slot writer
  #   find it without parsing FAT;
  # * system A: the release's EROFS image and its tree, as ReleaseMedium places them;
  # * boot B, system B and the vault's partition empty, and the data partition a fresh littlefs
  #   volume (DataVolume) of the layout's minimum length (MediumImage::PACKED_DATA_SECTORS).
  #
  # The medium ends where the data partition ends, so writing the card copies only what its
  # partitions hold; QEMU's SD model alone wants a longer image, and the harness pads its own
  # copy (QemuPlan.card_copy). Every byte no piece holds is zero. After fsimg writes each
  # volume, it is read back through FatVolume, which shares no code with fsimg: the
  # record volume by RecordVolume.check, and slot A's by check_slot: kernel8.img's
  # directory entry and whole cluster chain, its placed bytes, and each boot file's
  # short name.
  module PiMedium
    SECTOR_BYTES = MediumImage::SECTOR_BYTES
    BOOT_FILE = 'kernel8.img'
    # Slot A's FAT fills its boot partition.
    SLOT_FAT_BYTES = MediumImage.constant('boot_sectors') * SECTOR_BYTES
    BOOT_PLACE = MediumImage.constant('slot_boot_start') * SECTOR_BYTES
    # Slot A's fsimg arguments: its format, then its one placed file, as the record
    # volume's (RecordVolume::ARGUMENTS). 1 KiB clusters make 188 MiB of data area some
    # 192,000 clusters, a FAT32 by count as the boot partition's type (medium_boot_type,
    # 0x0c) says, as 2 KiB would, and with less slack per file; 4 KiB would make it a
    # FAT16. It is labelled for its slot, so a host shows it apart from the record volume (docs/design-ssh.md, "Where the file lies").
    #
    # fat_format is that format for a FAT32 of bytes labelled label, which netboot's HTTP
    # form uses for its boot.img (NetbootEntry); PLACE places kernel8.img at the slot's boot
    # start, so check_slot reads either volume back.
    def self.fat_format(bytes:, label:) = ['-F', 'fat32', *FatVolume::FSIMG_EPOCH, '-s', bytes.to_s, '-L', label,
                                           '-o', 'cluster=1024'].freeze
    SLOT_FORMAT = fat_format(bytes: SLOT_FAT_BYTES, label: 'ERXSLOTA')
    PLACE = ['-o', "place=/#{BOOT_FILE}@#{BOOT_PLACE}"].freeze
    SLOT_VOLUME = [*SLOT_FORMAT, *PLACE].freeze
    VOLUME_DEADLINE = 300

    module_function

    # The volumes' arguments as the card's build record names them: each format and its
    # placed file's name and offset, which spell the place setting without the leading
    # slash a published record refuses as a host path (BootPartition.check_record).
    def arguments
      { 'record' => { 'format' => RecordVolume::FORMAT, 'place' => { RecordVolume::FILE => RecordVolume::PLACE } },
        'slot' => { 'format' => SLOT_FORMAT, 'place' => { BOOT_FILE => BOOT_PLACE } } }
    end

    # Writes the card as name in directory, a work directory the caller owns: the record
    # volume (RecordVolume.write); slot A's FAT of the files staged in files, whose root
    # names are names; the release's EROFS image at erofs, or none when erofs is nil; the
    # data partition's fresh volume, a MediumImage::FilePiece formatted for
    # MediumImage::PACKED_DATA_SECTORS (DataVolume.format). Returns the card's path.
    def write(directory:, name:, files:, names:, erofs:, volume:, runner:, fsimg:)
      Dir.mktmpdir('.pi-medium-', directory) do |work|
        record = RecordVolume.write(directory: work, runner: runner, fsimg: fsimg)
        slot = File.join(work, 'slot.fat')
        runner.run([fsimg, 'cW', '-f', slot, *SLOT_VOLUME, '-C', files, '.'], name: 'fsimg-slot-volume',
                                                                          deadline: VOLUME_DEADLINE)
        check_slot(slot, boot: BoundedFile.read(File.join(files, BOOT_FILE), maximum: SLOT_FAT_BYTES), names: names)
        MediumImage.create(directory: directory, name: name, data_sectors: MediumImage::PACKED_DATA_SECTORS,
                           pieces: pieces(record: record, slot: slot, erofs: erofs, volume: volume))
      end
    end

    # Refuses the slot volume unless it is a FAT32 whose data area starts with boot placed
    # at the slot's boot start and that holds each of names under its own short name.
    def check_slot(slot, boot:, names:)
      FatVolume.open(slot) do |volume|
        FatVolume.check_placed(volume, kind: :fat32, short: FatShortNames.short_form(BOOT_FILE).name, offset: BOOT_PLACE,
                                       contents: boot)
        volume.refuse('the data area does not start at the bootable file') unless volume.layout.data_offset == BOOT_PLACE
      end
      FatShortNames.check(slot, names: names)
    end

    # The card's pieces by sector: the record volume filling its partition, slot A's
    # volume filling boot A, the system partition of the EROFS image, if any, in system A
    # as ReleaseMedium places it (ReleaseMedium.system_pieces), and the data volume's
    # leading blocks.
    def pieces(record:, slot:, erofs:, volume:)
      system = erofs ? ReleaseMedium.system_pieces(erofs, start: MediumImage.constant('system_a_start')) : {}
      { **RecordVolume.pieces(record),
        MediumImage.constant('boot_a_start') => piece(slot),
        **system,
        **DataVolume.pieces(volume) }
    end

    def piece(path) = MediumImage::FilePiece.new(path: path, length: File.size(path))
    private_class_method :piece
  end
end
