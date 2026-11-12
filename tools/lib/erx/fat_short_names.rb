# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The short (8.3) names in the root directory of a card image: an MBR whose first
  # partition is FAT32. The Raspberry Pi's boot ROM reads only short names, so a file it
  # loads (start4.elf, fixup4.dat) must be stored under its own name in 8.3 form, not under
  # a numbered alias (F0000009) with a long name beside it. BootPartition checks every card
  # it writes with this reader, which shares no code with fsimg, the card's writer.
  #
  # The reader parses an image the build just wrote, but bounds every offset, count and
  # cluster chain all the same, and refuses a malformed image with an Erx::Error.
  # Layouts: Microsoft, "FAT32 File System Specification", version 1.03, sections 3
  # (boot sector and BPB), 4 (the FAT) and 6 (directory entries); the case flags in byte
  # 12 of an entry are Windows NT's (0x08 base, 0x10 extension in lowercase).
  module FatShortNames
    # The MBR's sectors, which its partition entries count in, are always 512 bytes.
    MBR_SECTOR = 512
    ENTRY = 32
    LONG_NAME = 0x0f
    LONG_NAME_MASK = 0x3f
    VOLUME_ID = 0x08
    END_OF_CHAIN = 0x0ffffff8
    # A volume with fewer clusters is FAT12 or FAT16 (section 3.5); one with more would
    # number a cluster 0x0ffffff7, the bad-cluster mark.
    MIN_CLUSTERS = 65_525
    MAX_CLUSTERS = 0x0ffffff5
    # The MBR partition types of FAT32 (CHS and LBA).
    FAT32_TYPES = [0x0b, 0x0c].freeze
    # A part of a short name, written in one case: fsimg's rule (fsimg_fat_write_short_name)
    # restricted to the characters BootPartition::NAME allows.
    LOWER_PART = /\A[a-z0-9_-]+\z/
    UPPER_PART = /\A[A-Z0-9_-]+\z/

    # A short entry of the root directory: its 11 name bytes, its byte 12 (the case
    # flags), and the byte offset of the entry in the image.
    Entry = Data.define(:name, :flags, :offset)
    # The short form a name takes: its 11 name bytes and the case flags that restore it.
    Short = Data.define(:name, :flags)
    # Where a FAT32 volume's parts lie in the image, in bytes, and its clusters: data
    # clusters are numbered 2 to cluster_count + 1, as FAT entries 0 and 1 are reserved.
    Layout = Data.define(:fat_offset, :data_offset, :cluster_bytes, :cluster_count, :root_cluster) do
      def cluster?(number) = number.between?(2, cluster_count + 1)
      def cluster_offset(number) = data_offset + ((number - 2) * cluster_bytes)
      def fat_entry_offset(number) = fat_offset + (number * 4)
    end

    module_function

    # The short form of name when it fits 8.3 with its base and extension each in a single
    # case, or nil when it needs a long name. Pure.
    def short_form(name)
      base, extension, extra = name.split('.', -1)
      return nil if extra || !part?(base, maximum: 8) || (extension && !part?(extension, maximum: 3))

      flags = (/[a-z]/.match?(base) ? 0x08 : 0) | (/[a-z]/.match?(extension.to_s) ? 0x10 : 0)
      Short.new(name: (base.upcase.ljust(8) + extension.to_s.upcase.ljust(3)).b, flags: flags)
    end

    # Whether part is a base or extension of at most maximum characters in one case. Pure.
    def part?(part, maximum:) = part.size.between?(1, maximum) && (LOWER_PART.match?(part) || UPPER_PART.match?(part))

    # Refuses the image at path unless each of names (root directory names) that fits 8.3
    # is a short entry of the root directory under that name with its case flags, and no
    # two short entries share a name.
    def check(path, names:)
      entries = root_entries(path)
      repeated = entries.map(&:name).tally.select { |_, count| count > 1 }.keys
      raise Error, "#{path}: the root directory repeats the short names #{repeated.map(&:inspect).join(', ')}" unless repeated.empty?

      flags = entries.to_h { |entry| [entry.name, entry.flags] }
      missing = names.filter_map do |name|
        short = short_form(name)
        name if short && flags[short.name] != short.flags
      end
      return if missing.empty?

      raise Error, "#{path}: the boot ROM reads only 8.3 names, and these are not stored as their own " \
                   "short names with their case flags: #{missing.join(', ')}"
    end

    # The short entries of the root directory of the image's first partition, in order,
    # without deleted entries, long-name records and the volume label.
    def root_entries(path)
      File.open(path, File::RDONLY | File::NONBLOCK) do |image|
        image.binmode
        raise Error, "#{path} is not a regular file" unless image.stat.file?

        Volume.new(image, path).root_entries
      end
    rescue SystemCallError, EOFError => e
      raise Error, "#{path}: #{e.message}"
    end

    # A FAT32 volume inside an open image, read at bounded offsets.
    class Volume
      def initialize(image, path)
        @image = image
        @path = path
        @size = image.stat.size
        @layout = layout
      end

      # The directory's short entries up to its end mark, an entry whose first byte is zero.
      def root_entries
        entries = []
        chain(@layout.root_cluster).each do |cluster|
          offset = @layout.cluster_offset(cluster)
          read(offset, @layout.cluster_bytes).bytes.each_slice(ENTRY).with_index do |entry, index|
            return entries if entry[0].zero?

            entries << Entry.new(name: entry[0, 11].pack('C*'), flags: entry[12], offset: offset + (index * ENTRY)) if short?(entry)
          end
        end
        entries
      end

      private

      # The volume's Layout, from the MBR's first partition entry and the volume's boot
      # sector, refused unless it is a FAT32 volume that lies inside its partition.
      def layout
        mbr = read(0, MBR_SECTOR)
        refuse('has no MBR signature') unless mbr.byteslice(510, 2) == "\x55\xAA".b
        type, first_sector, partition_sectors = mbr.byteslice(446 + 4, 12).unpack('Cx3VV')
        refuse("partition 1 is type 0x#{type.to_s(16)}, not FAT32") unless FAT32_TYPES.include?(type)
        partition_offset = first_sector * MBR_SECTOR
        partition_bytes = partition_sectors * MBR_SECTOR
        refuse('partition 1 lies past the end of the image') unless first_sector.positive? && partition_offset + partition_bytes <= @size

        volume(read(partition_offset, MBR_SECTOR), partition_offset: partition_offset, partition_bytes: partition_bytes)
      end

      # The Layout the boot sector's BPB gives a volume at partition_offset. The BPB counts
      # in its own sectors, of bytes_per_sector bytes.
      def volume(sector, partition_offset:, partition_bytes:)
        refuse('the boot sector has no signature') unless sector.byteslice(510, 2) == "\x55\xAA".b
        bytes_per_sector, per_cluster, reserved_sectors, fats, root_entries, total16, fat_size16 =
          sector.byteslice(11, 13).unpack('vCvCvvx1v')
        total_sectors, fat_sectors, root_cluster = sector.byteslice(32, 16).unpack('VVx4V')
        unless [512, 1024, 2048, 4096].include?(bytes_per_sector) && per_cluster.positive? &&
               (per_cluster & (per_cluster - 1)).zero? && reserved_sectors.positive? && fats.positive? && fat_sectors.positive?
          refuse('has an invalid BPB')
        end
        refuse('is not FAT32: its BPB has FAT12/16 fields') unless root_entries.zero? && total16.zero? && fat_size16.zero?

        first_data_sector = reserved_sectors + (fats * fat_sectors)
        unless first_data_sector < total_sectors && total_sectors * bytes_per_sector <= partition_bytes
          refuse('the volume is larger than its partition')
        end
        # Each FAT entry is 4 bytes, and the FAT must hold one for every cluster.
        cluster_count = [(total_sectors - first_data_sector) / per_cluster, (fat_sectors * bytes_per_sector / 4) - 2].min
        refuse("has #{cluster_count} clusters, which is not FAT32") unless cluster_count.between?(MIN_CLUSTERS, MAX_CLUSTERS)

        Layout.new(fat_offset: partition_offset + (reserved_sectors * bytes_per_sector),
                   data_offset: partition_offset + (first_data_sector * bytes_per_sector),
                   cluster_bytes: bytes_per_sector * per_cluster, cluster_count: cluster_count, root_cluster: root_cluster)
          .tap { |layout| refuse("the root cluster #{root_cluster} is out of range") unless layout.cluster?(root_cluster) }
      end

      # Whether entry (its bytes) is a short entry: not deleted, not a long-name record,
      # not the volume label.
      def short?(entry)
        attributes = entry[11]
        entry[0] != 0xe5 && (attributes & LONG_NAME_MASK) != LONG_NAME && attributes.nobits?(VOLUME_ID)
      end

      # The clusters of the chain from first, at most every cluster of the volume once.
      def chain(first)
        clusters = [first]
        loop do
          following = read(@layout.fat_entry_offset(clusters.last), 4).unpack1('V') & 0x0fffffff
          return clusters if following >= END_OF_CHAIN

          refuse("the root directory's chain reaches cluster #{following}") unless @layout.cluster?(following)
          refuse("the root directory's chain loops") if clusters.size >= @layout.cluster_count
          clusters << following
        end
      end

      def read(offset, length)
        refuse("is too short for #{length} bytes at #{offset}") if offset + length > @size
        @image.pread(length, offset).tap { |bytes| refuse("read short at #{offset}") unless bytes.bytesize == length }
      end

      def refuse(reason) = raise(Error, "#{@path}: #{reason}")
    end
    private_constant :Volume
  end
end
