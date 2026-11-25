# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require_relative 'boot_record'
require_relative 'error'
require_relative 'fat_short_names'
require_relative 'fat_volume'
require_relative 'medium_image'

module Erx
  # The record partition's volume, which both medium writers lay out, the Raspberry Pi's
  # card (PiMedium) and QEMU's release medium (ReleaseMedium), so the record lies at the
  # same place on both (docs/design-platforms.md, "Slots and the boot-selection record";
  # docs/design-ssh.md, "Where the file lies"): an 8 MiB FAT16 labelled ERXOS whose one
  # file, autoboot.txt, is the record committing slot A (medium_record_a), placed by
  # fsimg at the record's sector (medium_record_select_start), the data area's first
  # cluster. The reset count's sector (medium_record_count_start) lies in the reserved
  # area, which fsimg leaves zero, and is not written, since abi/medium.txt defines no
  # encoding of the count. The volume holds no other file: whoever writes a medium adds
  # authorized_keys to it afterwards, so a medium as written carries no login key.
  module RecordVolume
    SECTOR_BYTES = MediumImage::SECTOR_BYTES
    MIB = 1 << 20
    FILE = 'autoboot.txt'
    BYTES = MediumImage.constant('record_sectors') * SECTOR_BYTES
    # Byte offsets inside the volume: the record and the reset count.
    PLACE = MediumImage.constant('record_select_start') * SECTOR_BYTES
    COUNT_OFFSET = MediumImage.constant('record_count_start') * SECTOR_BYTES
    # The volume's fsimg arguments: its format, then its one placed file, which fsimg
    # names by its absolute path in the volume and places at a byte offset of it.
    # 512-byte clusters make its 5 MiB data area 10,240 clusters, a FAT16 by count, and
    # the record one cluster of its own. ERXOS is the label users are told to copy
    # authorized_keys to.
    FORMAT = ['-F', 'fat16', *FatVolume::FSIMG_EPOCH, '-s', BYTES.to_s, '-L', 'ERXOS', '-o', 'cluster=512'].freeze
    ARGUMENTS = [*FORMAT, '-o', "place=/#{FILE}@#{PLACE}"].freeze
    DEADLINE = 300

    module_function

    # Writes the volume as record.fat in directory, which the caller owns and holds no
    # record.fat, and returns it as a MediumImage::FilePiece once check has read it back,
    # its length fixed, so a medium refuses a file changed since.
    def write(directory:, runner:, fsimg:)
      path = File.join(directory, 'record.fat')
      Dir.mktmpdir('.record-volume-', directory) do |files|
        File.binwrite(File.join(files, FILE), BootRecord::SLOTS.fetch(:a).text)
        runner.run([fsimg, 'cW', '-f', path, *ARGUMENTS, '-C', files, '.'], name: 'fsimg-record-volume', deadline: DEADLINE)
      end
      check(path)
      MediumImage::FilePiece.new(path: path, length: File.size(path))
    end

    # The pieces of a medium's record partition by sector from the medium's start: volume,
    # a FilePiece RecordVolume.write returned, filling the partition. Both medium writers
    # place the volume through this function.
    def pieces(volume) = { MediumImage.constant('record_start') => volume }

    # Refuses the volume at path unless it is a FAT16 whose data area starts with
    # autoboot.txt placed at its record sector, which reads as medium_record_a and zeros
    # to the sector's end, whose root holds no other file, and whose FATs start after the
    # reset count's MiB, so the count's sector, which is zero, is reserved and alone in
    # its erase unit. FatVolume, which shares no code with fsimg, reads it.
    def check(path)
      FatVolume.open(path) do |volume|
        short = FatShortNames.short_form(FILE).name
        FatVolume.check_placed(volume, kind: :fat16, short: short, offset: PLACE, contents: BootRecord::SLOTS.fetch(:a).text)
        volume.refuse("the record's sector is not medium_record_a") unless volume.read(PLACE, SECTOR_BYTES) == BootRecord.sector(:a)
        volume.refuse('the root holds a file beside the record') unless volume.root_entries.map(&:name) == [short]
        volume.refuse('the data area does not start at the record') unless volume.layout.data_offset == PLACE
        volume.refuse("the FATs do not start after the reset count's MiB") unless volume.layout.fat_offset >= COUNT_OFFSET + MIB
        volume.refuse("the reset count's sector is not zero") unless volume.read(COUNT_OFFSET, SECTOR_BYTES).count("\0") == SECTOR_BYTES
      end
    end
  end
end
