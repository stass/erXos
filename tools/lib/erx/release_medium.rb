# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'boot_record'
require_relative 'erofs_image'
require_relative 'error'
require_relative 'medium_image'

module Erx
  # The packer's disk image for QEMU (docs/plan.md, M6): a medium laid out by the ABI
  # file's medium layout (MediumImage) whose slot A holds a production image's bootable
  # file and, after it, the release's EROFS image, which fsimg writes from the system
  # release's files at the paths the boot image's archive gives them
  # (ProductionImage::Built#release). The boot-selection record commits slot A
  # (BootRecord.sector), and the rest of its partition, slot B, the vault's partition
  # and the data partition hold zeros; /data's littlefs formats its volume over the
  # zeros at its first mount (erx_lfs).
  module ReleaseMedium
    NAME = 'medium.img'
    EROFS = 'release.erofs'
    IMAGE = 'release'
    SECTOR_BYTES = MediumImage::SECTOR_BYTES
    # Where a slot's EROFS images start, in bytes from the slot's start, and the boundary
    # each starts on (docs/design-storage.md, System updates). The bootable file must end
    # before the start. A fixed start makes every image's extent a function of the images
    # alone, so the boot image can record the extents before it is packed.
    SLOT_IMAGES_START = 128 << 20
    SLOT_IMAGE_ALIGNMENT = 1 << 20

    # A host file a slot holds: its name in the slot's plan, its path and its length,
    # measured once.
    SlotFile = Data.define(:name, :path, :length)
    # Where a slot file lies: bytes from the slot's start, in the shape of the manifest's
    # erx_mf_extent.
    Extent = Data.define(:file, :slot_offset)
    # A slot's contents: the bootable file's extent and each EROFS image's, in order.
    SlotPlan = Data.define(:boot, :images)
    # The medium as written: its path, the EROFS image's path beside it, its data
    # partition's length and slot A's plan.
    Written = Data.define(:path, :erofs, :data_sectors, :slot)

    module_function

    # Where a slot holds the bootable file boot and the EROFS images, each a SlotFile: the
    # bootable file at the sector the layout fixes (medium_slot_boot_start) and the images
    # where image_extents places them. A bootable file that reaches the images' start is
    # refused.
    def slot_plan(boot:, images:)
      boot_offset = MediumImage.constant('slot_boot_start') * SECTOR_BYTES
      unless boot.length.is_a?(Integer) && boot.length.positive? && boot_offset + boot.length <= SLOT_IMAGES_START
        raise Error, "the bootable file must be at most #{SLOT_IMAGES_START - boot_offset} bytes"
      end

      SlotPlan.new(boot: Extent.new(file: boot, slot_offset: boot_offset), images: image_extents(images))
    end

    # Where a slot holds the EROFS images, each a SlotFile: from SLOT_IMAGES_START, each at
    # the next SLOT_IMAGE_ALIGNMENT boundary after the one before, so the places depend on
    # the images alone. An image that is not whole sectors or that leaves the slot, and a
    # repeated name, are refused.
    def image_extents(images)
      raise Error, 'a slot names each image once' unless images.map(&:name).uniq.size == images.size

      slot_bytes = MediumImage.constant('slot_sectors') * SECTOR_BYTES
      images.each_with_object([]) do |image, placed|
        start = placed.empty? ? SLOT_IMAGES_START : align(placed.last.slot_offset + placed.last.file.length)
        unless image.length.is_a?(Integer) && image.length.positive? && (image.length % SECTOR_BYTES).zero?
          raise Error, "the image #{image.name} is not a positive whole number of sectors"
        end
        raise Error, "the image #{image.name} leaves its slot" if start + image.length > slot_bytes

        placed << Extent.new(file: image, slot_offset: start)
      end.freeze
    end

    # Writes the system release's EROFS image, EROFS in directory, from entries, the
    # release's entries (ProductionImage::Built#release). Returns its path and the artifacts
    # the packer hands the manifest check: the image under the name the manifest's input
    # names, with its one extent in the slot.
    def image(entries:, directory:, runner:)
      path = ErofsImage.new(runner: runner).write(files: files(entries), name: IMAGE, output: File.join(directory, EROFS))
      extents = image_extents([slot_file(IMAGE, path)]).map do |extent|
        { 'slot_offset' => extent.slot_offset, 'length' => extent.file.length }
      end
      [path, { IMAGE => { 'kind' => 'erofs_image', 'extents' => extents } }]
    end

    # The EROFS image's files: each release entry's archive path, mapped to its built file.
    def files(entries)
      paths = entries.map { |entry| entry.fetch('path') }
      raise Error, 'the release names a path twice' unless paths.uniq.size == paths.size

      entries.to_h { |entry| [entry.fetch('path'), entry.fetch('artifact')] }
    end

    # Writes the medium into directory, which holds the build of built, whose EROFS image
    # the build wrote (ProductionImage::Built#erofs).
    def write(built:, directory:, data_sectors: MediumImage.constant('data_sectors_min'))
      plan = slot_plan(boot: slot_file('boot', built.single), images: [slot_file(IMAGE, built.erofs)])
      Written.new(path: medium(plan, directory: directory, data_sectors: data_sectors), erofs: built.erofs,
                  data_sectors: data_sectors, slot: plan)
    end

    # Writes the medium, NAME in directory, whose slot A holds plan's files and whose
    # boot-selection record commits slot A; returns its path. A boot that may write
    # its medium takes a fresh one from the plan of the release medium written once.
    def medium(plan, directory:, data_sectors:)
      slot = MediumImage.constant('slot_a_start')
      pieces = [plan.boot, *plan.images].to_h do |extent|
        [slot + (extent.slot_offset / SECTOR_BYTES), MediumImage::FilePiece.new(path: extent.file.path, length: extent.file.length)]
      end
      pieces[BootRecord::RECORD_OFFSET / SECTOR_BYTES] = BootRecord.sector(:a)
      MediumImage.create(directory: directory, name: NAME, data_sectors: data_sectors, pieces: pieces)
    end

    def slot_file(name, path) = SlotFile.new(name: name, path: path, length: File.size(path))

    def align(offset) = (offset + SLOT_IMAGE_ALIGNMENT - 1) / SLOT_IMAGE_ALIGNMENT * SLOT_IMAGE_ALIGNMENT
    private_class_method :slot_file, :align
  end
end
