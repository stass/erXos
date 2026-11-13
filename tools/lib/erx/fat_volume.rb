# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # A reader of a bare FAT16 or FAT32 volume, a volume image with no partition table,
  # and the packer's check of a file fsimg placed in one (`-o place=PATH@OFFSET`). The
  # Raspberry Pi medium (PiMedium) has fsimg write the record partition's FAT16 with
  # autoboot.txt placed at the record's sector and slot A's FAT32 with kernel8.img
  # placed at the slot's boot start; the firmware finds each through FAT, and the QEMU
  # harness and the slot writer read the raw sectors, so the two views must agree. This
  # reader shares no code with fsimg, the volumes' writer.
  #
  # The reader parses a volume the build just wrote, but fsimg is third-party, so it
  # bounds every offset, count and cluster chain all the same and refuses a malformed
  # volume with an Erx::Error. tools/fuzz/fat_volume.rb is its fuzz target. Layouts:
  # Microsoft, "FAT32 File System Specification", version 1.03, sections 3 (boot sector,
  # BPB and the FAT type by cluster count, 3.5), 4 (the FAT) and 6 (directory entries).
  module FatVolume
    ENTRY = 32
    LONG_NAME = 0x0f
    LONG_NAME_MASK = 0x3f
    VOLUME_ID = 0x08
    DIRECTORY = 0x10
    DELETED = 0xe5
    # The FAT type follows from the cluster count alone (section 3.5): fewer than
    # FAT16_MIN is FAT12, which this reader refuses, and FAT32_MIN or more is FAT32; a
    # FAT32 volume with more than FAT32_MAX would number the bad-cluster mark.
    FAT16_MIN = 4085
    FAT32_MIN = 65_525
    FAT32_MAX = 0x0ffffff5
    # Per type: the bytes of one FAT entry, the mask of its cluster number and the
    # smallest end-of-chain mark.
    Kind = Data.define(:name, :entry_bytes, :mask, :end_of_chain)
    KINDS = { fat16: Kind.new(name: :fat16, entry_bytes: 2, mask: 0xffff, end_of_chain: 0xfff8),
              fat32: Kind.new(name: :fat32, entry_bytes: 4, mask: 0x0fffffff, end_of_chain: 0x0ffffff8) }.freeze

    # Where the volume's parts lie, in bytes from its start; the reserved area is the
    # bytes before fat_offset. Data clusters are numbered 2
    # to cluster_count + 1, as FAT entries 0 and 1 are reserved. A FAT16 root directory
    # is the fixed region at root_offset of root_bytes; a FAT32 one is the chain from
    # root_cluster.
    Layout = Data.define(:kind, :fat_offset, :root_offset, :root_bytes, :data_offset, :cluster_bytes,
                         :cluster_count, :root_cluster) do
      def cluster?(number) = number.between?(2, cluster_count + 1)
      def cluster_offset(number) = data_offset + ((number - 2) * cluster_bytes)
      def fat_entry_offset(number) = fat_offset + (number * kind.entry_bytes)
    end
    # A short entry of the root directory: its 11 name bytes, its byte 12 (the case
    # flags), its attributes, its first cluster and length, and its offset in the volume.
    Entry = Data.define(:name, :flags, :attributes, :first_cluster, :size, :offset)

    # A volume held in a string, for tests and the fuzz target: what reads it needs of a
    # file, pread and its size.
    Bytes = Data.define(:bytes) do
      def pread(length, offset) = bytes.byteslice(offset, length) || ''.b
      def size = bytes.bytesize
    end

    module_function

    # Opens the regular file at path read-only and yields its Volume.
    def open(path)
      File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |file|
        file.binmode
        raise Error, "#{path} is not a regular file" unless file.stat.file?

        yield Volume.new(file, size: file.stat.size, label: path)
      end
    rescue SystemCallError, EOFError => e
      raise Error, "#{path}: #{e.message}"
    end

    # Refuses volume unless it is of kind (:fat16 or :fat32) and its root directory holds
    # the file whose short entry is named short (11 bytes) as one run from offset bytes
    # into the volume, the placement fsimg was asked for: the entry is a file of exactly
    # contents' length, its first cluster is the one at offset, its chain in the first
    # FAT is consecutive for as many clusters as the length needs and ends there, and the
    # raw bytes at offset are contents. The chain is walked no further than the length
    # needs, so a looping or overlong chain is found at its first wrong link.
    def check_placed(volume, kind:, short:, offset:, contents:)
      layout = volume.layout
      volume.refuse("is #{layout.kind.name}, not #{kind}") unless layout.kind.name == kind
      entry = volume.root_entries.find { |candidate| candidate.name == short } ||
              volume.refuse("has no root entry #{short.dump}")
      placed_run(volume, layout, entry, offset: offset, length: contents.bytesize)
      volume.refuse("does not hold #{short.dump}'s contents at byte #{offset}") unless
        volume.read(offset, contents.bytesize) == contents.b
      entry
    end

    # The checks of check_placed on entry's directory fields and chain.
    def placed_run(volume, layout, entry, offset:, length:)
      name = entry.name.dump
      volume.refuse("#{name} is not a file") unless entry.attributes.nobits?(DIRECTORY | VOLUME_ID)
      volume.refuse("#{name} is #{entry.size} bytes, not #{length}") unless entry.size == length && length.positive?
      unless layout.cluster?(entry.first_cluster) && layout.cluster_offset(entry.first_cluster) == offset
        volume.refuse("#{name} starts at cluster #{entry.first_cluster}, not at byte #{offset}")
      end
      clusters = (length + layout.cluster_bytes - 1) / layout.cluster_bytes
      volume.refuse("#{name} leaves the volume") unless layout.cluster?(entry.first_cluster + clusters - 1)
      last = entry.first_cluster + clusters - 1
      (entry.first_cluster..last).each do |cluster|
        following = volume.fat_entry(cluster)
        ended = following >= layout.kind.end_of_chain
        if cluster == last
          volume.refuse("#{name}'s chain runs on past its last cluster, #{cluster}") unless ended
        elsif ended
          volume.refuse("#{name}'s chain ends early, at cluster #{cluster}")
        elsif following != cluster + 1
          volume.refuse("#{name}'s chain is not consecutive at cluster #{cluster}")
        end
      end
    end
    private_class_method :placed_run

    # A FAT16 or FAT32 volume read at bounded offsets of source, which answers pread and
    # whose length is size; label names it in errors.
    class Volume
      attr_reader :layout

      def initialize(source, size:, label:)
        @source = source
        @size = size
        @label = label
        @layout = read_layout
      end

      # The root directory's short entries up to its end mark, an entry whose first byte
      # is zero, without deleted entries, long-name records and the volume label.
      def root_entries
        entries = []
        root_regions.each do |offset, length|
          read(offset, length).bytes.each_slice(ENTRY).with_index do |entry, index|
            return entries if entry[0].zero?

            entries << entry_of(entry, offset: offset + (index * ENTRY)) if short?(entry)
          end
        end
        entries
      end

      # Cluster number's entry in the first FAT, masked to its cluster number.
      def fat_entry(number)
        kind = @layout.kind
        bytes = read(@layout.fat_entry_offset(number), kind.entry_bytes)
        bytes.unpack1(kind.entry_bytes == 2 ? 'v' : 'V') & kind.mask
      end

      def read(offset, length)
        refuse("is too short for #{length} bytes at #{offset}") if offset.negative? || offset + length > @size
        @source.pread(length, offset).tap { |bytes| refuse("read short at #{offset}") unless bytes.bytesize == length }
      end

      def refuse(reason) = raise(Error, "#{@label}: #{reason}")

      private

      # The Layout the boot sector's BPB gives, which counts in its own sectors. The FAT
      # type follows from the cluster count; a FAT16 has a fixed root and 16-bit FAT
      # size, a FAT32 neither.
      def read_layout
        sector = read(0, 512)
        refuse('the boot sector has no signature') unless sector.byteslice(510, 2) == "\x55\xAA".b
        bytes_per_sector, per_cluster, reserved, fats, root_entries, total16, fat16 = sector.byteslice(11, 13).unpack('vCvCvvx1v')
        total32, fat32, root_cluster = sector.byteslice(32, 16).unpack('VVx4V')
        unless [512, 1024, 2048, 4096].include?(bytes_per_sector) && per_cluster.positive? &&
               (per_cluster & (per_cluster - 1)).zero? && reserved.positive? && fats.positive?
          refuse('has an invalid BPB')
        end
        fat_sectors = fat16.positive? ? fat16 : fat32
        total = total16.positive? ? total16 : total32
        root_sectors = ((root_entries * ENTRY) + bytes_per_sector - 1) / bytes_per_sector
        first_data = reserved + (fats * fat_sectors) + root_sectors
        refuse('the volume is larger than its image') unless total * bytes_per_sector <= @size
        refuse('has no data area') unless fat_sectors.positive? && first_data < total

        count = (total - first_data) / per_cluster
        kind = kind_of(count, root_entries: root_entries, fat16: fat16)
        refuse("has #{count} clusters, more than its FAT holds") if
          count + 2 > fat_sectors * bytes_per_sector / kind.entry_bytes
        layout = Layout.new(kind: kind, fat_offset: reserved * bytes_per_sector,
                            root_offset: (first_data - root_sectors) * bytes_per_sector,
                            root_bytes: root_entries * ENTRY, data_offset: first_data * bytes_per_sector,
                            cluster_bytes: bytes_per_sector * per_cluster, cluster_count: count, root_cluster: root_cluster)
        refuse("the root cluster #{root_cluster} is out of range") if kind.name == :fat32 && !layout.cluster?(root_cluster)
        layout
      end

      def kind_of(count, root_entries:, fat16:)
        if count < FAT16_MIN
          refuse("has #{count} clusters, which is FAT12")
        elsif count < FAT32_MIN
          refuse('is FAT16 by its cluster count but has no fixed root or 16-bit FAT size') unless
            root_entries.positive? && fat16.positive?
          KINDS.fetch(:fat16)
        else
          refuse("has #{count} clusters, more than FAT32 numbers") if count > FAT32_MAX
          refuse('is FAT32 by its cluster count but its BPB has FAT16 fields') unless root_entries.zero? && fat16.zero?
          KINDS.fetch(:fat32)
        end
      end

      # The root directory as [offset, length] regions: the fixed region of a FAT16, or
      # each cluster of a FAT32's chain, at most every cluster of the volume once.
      def root_regions
        return [[@layout.root_offset, @layout.root_bytes]] if @layout.kind.name == :fat16

        clusters = [@layout.root_cluster]
        loop do
          following = fat_entry(clusters.last)
          break if following >= @layout.kind.end_of_chain

          refuse("the root directory's chain reaches cluster #{following}") unless @layout.cluster?(following)
          refuse("the root directory's chain loops") if clusters.size >= @layout.cluster_count
          clusters << following
        end
        clusters.map { |cluster| [@layout.cluster_offset(cluster), @layout.cluster_bytes] }
      end

      def short?(entry)
        entry[0] != DELETED && (entry[11] & LONG_NAME_MASK) != LONG_NAME && entry[11].nobits?(VOLUME_ID)
      end

      # A FAT16 entry's high cluster word is zero by the specification; a FAT32's is the
      # cluster number's high half.
      def entry_of(entry, offset:)
        bytes = entry.pack('C*')
        high, low, size = bytes.byteslice(20, 12).unpack('vx4vV')
        high = 0 if @layout.kind.name == :fat16
        Entry.new(name: bytes.byteslice(0, 11), flags: entry[12], attributes: entry[11],
                  first_cluster: (high << 16) | low, size: size, offset: offset)
      end
    end
  end
end
