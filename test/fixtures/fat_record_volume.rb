# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'generated_tree'
require_relative '../../tools/lib/erx/generated_abi'

# FAT16 volumes laid out as the boot medium's record partition (abi/medium.txt), for
# the tests and the fuzz target of erx_fat_read (docs/design-storage.md, "The record
# volume's one reader"). They are written here, from Microsoft's "FAT32 File System
# Specification", version 1.03, sections 3 (the BPB), 4 (the FAT) and 6 and 7
# (directory entries and long names), because the cases are volumes no FAT writer
# makes: chains that loop or leave the data area, long names whose checksum does not
# match. Every value of the layout is derived from the
# generated medium constants, so the volumes move with abi/medium.txt.
#
# CASES names each volume the EUnit suite reads; FILES holds the bytes the reader must
# answer for each volume that holds a readable authorized_keys. write_cases writes
# both into a directory as NAME.img, a sparse image of the whole partition, and
# NAME.file.
module FatRecordVolume
  CODEC = Erx::ABI::Generated::CODEC
  SECTOR = 512
  ENTRY = 32
  TOTAL = CODEC.constant('medium_record_sectors')
  DATA_START = CODEC.constant('medium_record_select_start')
  ERASE = CODEC.constant('medium_erase_sectors')
  FATS = 2
  ROOT_ENTRIES = 512
  ROOT_SECTORS = ROOT_ENTRIES * ENTRY / SECTOR
  CLUSTERS = TOTAL - DATA_START
  FAT_SECTORS = ((CLUSTERS + 2) * 2 + SECTOR - 1) / SECTOR
  RESERVED = DATA_START - FATS * FAT_SECTORS - ROOT_SECTORS
  ROOT_START = RESERVED + FATS * FAT_SECTORS
  # One-sector clusters numbered from 2 at DATA_START, so a sector's cluster is its
  # distance from DATA_START plus 2.
  def self.cluster(sector) = sector - DATA_START + 2
  # The record's region: the erase unit, counted from the partition's start, that
  # holds the record's sector.
  REGION_START = DATA_START / ERASE * ERASE
  REGION = (cluster(REGION_START)..cluster(REGION_START + ERASE - 1)).freeze
  FREE = REGION.last + 1
  LAST = CLUSTERS + 1
  END_OF_CHAIN = 0xffff
  LONG_NAME = 0x0f
  ARCHIVE = 0x20
  DIRECTORY = 0x10
  VOLUME_ID = 0x08
  DELETED = 0xe5
  BPB = { bytes_per_sector: SECTOR, sectors_per_cluster: 1, reserved: RESERVED, fats: FATS,
          root_entries: ROOT_ENTRIES, total: TOTAL, fat_sectors: FAT_SECTORS, type: 'FAT16   ' }.freeze

  # One root-directory file: its directory entries, its FAT links and its clusters'
  # bytes.
  Placed = Data.define(:entries, :links, :data)

  module_function

  # deleted: :all marks every entry deleted, as a host deletes a file; :short marks the
  # short entry alone, with the long name's checksum taken over the marked name, so
  # only the marker tells the entry is gone.
  def file(long:, contents:, clusters:, size: contents.bytesize, attr: ARCHIVE, short: 'AUTHOR~1   ',
           links: {}, checksum_delta: 0, deleted: nil)
    stored = deleted == :short ? [DELETED].pack('C') + short.byteslice(1..) : short
    entries = [*long_entries(long, (checksum(stored) + checksum_delta) & 0xff), short_entry(stored, attr, clusters.first || 0, size)]
    entries = entries.map { |entry| [DELETED].pack('C') + entry.byteslice(1..) } if deleted == :all
    chain = clusters.each_cons(2).to_h.merge(clusters.empty? ? {} : { clusters.last => END_OF_CHAIN })
    data = clusters.zip(contents.b.scan(/.{1,#{SECTOR}}/mo)).to_h.compact
    Placed.new(entries: entries, links: chain.merge(links), data: data)
  end

  # The partition's sectors that are not zero, as { index => bytes }.
  def volume(files:, bpb: {})
    fat = files.map(&:links).reduce({ 0 => 0xfff8, 1 => END_OF_CHAIN }, :merge)
    table = (0...FAT_SECTORS * SECTOR / 2).map { |index| fat.fetch(index, 0) }.pack('v*')
    root = files.flat_map(&:entries).join.ljust(ROOT_SECTORS * SECTOR, "\0")
    [[0, boot_sector(BPB.merge(bpb))],
     *(0...FATS).flat_map { |copy| sectors(RESERVED + copy * FAT_SECTORS, table) },
     *sectors(ROOT_START, root),
     *files.flat_map { |placed| placed.data.map { |c, bytes| [DATA_START + c - 2, bytes.ljust(SECTOR, "\0")] } }]
      .reject { |_, bytes| bytes.count("\0") == SECTOR }.to_h
  end

  def write(sectors, path)
    File.open(path, 'wb') do |image|
      image.truncate(TOTAL * SECTOR)
      sectors.each do |index, bytes|
        image.seek(index * SECTOR)
        image.write(bytes)
      end
    end
  end

  def write_cases(directory)
    CASES.each { |name, sectors| write(sectors, File.join(directory, "#{name}.img")) }
    FILES.each { |name, bytes| File.binwrite(File.join(directory, "#{name}.file"), bytes) }
  end

  def boot_sector(bpb)
    total16, total32 = bpb.fetch(:total) < 0x10000 ? [bpb.fetch(:total), 0] : [0, bpb.fetch(:total)]
    head = ["\xeb\x3c\x90".b, 'ERXTEST ', bpb.fetch(:bytes_per_sector), bpb.fetch(:sectors_per_cluster),
            bpb.fetch(:reserved), bpb.fetch(:fats), bpb.fetch(:root_entries), total16, 0xf8,
            bpb.fetch(:fat_sectors), 63, 255, 0, total32, 0x80, 0, 0x29, 0x12345678, 'NO NAME    ',
            bpb.fetch(:type)].pack('a3a8vCvCvvCvvvVVCCCVa11a8')
    head.ljust(510, "\0") + "\x55\xaa".b
  end

  def sectors(first, bytes) = bytes.b.scan(/.{#{SECTOR}}/mo).each_with_index.map { |s, i| [first + i, s] }

  # Section 7.2: the sum, rotated right one bit before each byte is added.
  def checksum(short) = short.bytes.reduce(0) { |sum, byte| (((sum & 1) << 7) + (sum >> 1) + byte) & 0xff }

  def short_entry(short, attr, first, size) =
    [short, attr, 0, 0, 0, 0, 0, 0, 0, 0, first, size].pack('a11CCCvvvvvvvV')

  # Section 7: 13 UTF-16 code units per entry, the last entry first, ended by a zero
  # unit and padded with 0xffff.
  def long_entries(long, sum)
    return [] if long.nil?

    units = long.encode('UTF-16LE').unpack('v*')
    count = (units.size + 12) / 13
    ended = (units.size % 13).zero? ? units : [*units, 0]
    padded = ended + [0xffff] * (count * 13 - ended.size)
    count.downto(1).map do |ord|
      part = padded[(ord - 1) * 13, 13]
      [ord | (ord == count ? 0x40 : 0), *part[0, 5], LONG_NAME, 0, sum, *part[5, 6], 0, *part[11, 2]]
        .pack('Cv5CCCv6vv2')
    end
  end

  def key_line(seed, comment = 'root@host')
    blob = ["ssh-ed25519".bytesize, 'ssh-ed25519', 32, [seed].pack('C') * 32].pack('Na*Na*')
    "ssh-ed25519 #{[blob].pack('m0')} #{comment}\n"
  end

  KEYS = (key_line(1) + "# a comment line\n" * 60 + key_line(2)).freeze
  SLACK = "#{'#' * 99}\n".freeze
  FULL = ("#{'#' * 511}\n" * 32).freeze

  SEVENTEEN = (1..17).map { |seed| key_line(seed) }.join.freeze
  SKIPPED = (key_line(1) + "ssh-rsa AAAAB3NzaC1yc2E root@host\n" + key_line(2)).freeze

  def keys(**options) = file(long: 'authorized_keys', contents: KEYS, clusters: [FREE + 5, FREE + 1, FREE + 9], **options)

  def one(clusters, **options) = volume(files: [keys(clusters: clusters, **options)])

  # Fifteen files of short names alone before authorized_keys, so its long name's two
  # entries end the root directory's first sector and start its second.
  SHORT_ONLY = (1..15).map { |n| file(long: nil, short: format('F%02d     TXT', n), contents: '', clusters: []) }.freeze

  # authorized_keys with its long name's entries in the wrong order.
  def out_of_order = keys.then { |placed| placed.with(entries: placed.entries.values_at(1, 0, 2)) }

  CASES = {
    'found' => volume(files: [file(long: 'notes.txt', short: 'NOTES   TXT', contents: "x\n", clusters: [FREE]), keys]),
    'upper' => volume(files: [file(long: 'AUTHORIZED_KEYS', contents: KEYS, clusters: [FREE, FREE + 1, FREE + 2])]),
    'slack' => volume(files: [file(long: 'authorized_keys', contents: SLACK + key_line(3), size: SLACK.bytesize,
                                   clusters: [FREE])]),
    'full' => volume(files: [file(long: 'authorized_keys', contents: FULL, clusters: (FREE...FREE + 32).to_a)]),
    'too_long' => volume(files: [file(long: 'authorized_keys', contents: FULL, size: FULL.bytesize + 1,
                                      clusters: (FREE...FREE + 33).to_a)]),
    'empty' => volume(files: [file(long: 'authorized_keys', contents: '', clusters: [])]),
    'absent' => volume(files: [file(long: 'notes.txt', short: 'NOTES   TXT', contents: "x\n", clusters: [FREE])]),
    'deleted' => volume(files: [keys(deleted: :all)]),
    'deleted_short' => volume(files: [keys(deleted: :short)]),
    'pub' => volume(files: [file(long: 'authorized_keys.pub', contents: KEYS, clusters: [FREE, FREE + 1, FREE + 2])]),
    'directory' => volume(files: [keys(attr: DIRECTORY)]),
    'label' => volume(files: [keys(attr: VOLUME_ID)]),
    'checksum' => volume(files: [keys(checksum_delta: 1)]),
    'beside_the_record' => one([REGION.first + 1, FREE + 1, REGION.last]),
    'first_free' => one([FREE, FREE + 1, FREE + 2]),
    'link_past_the_data_area' => one([FREE, FREE + 1], links: { FREE + 1 => LAST + 1 }),
    'link_free' => one([FREE, FREE + 1], links: { FREE + 1 => 0 }),
    'first_cluster_zero' => one([]),
    'last_cluster' => one([FREE, FREE + 1, LAST]),
    'loop' => one([FREE, FREE + 1], links: { FREE + 1 => FREE }),
    'seen_twice' => one([FREE, FREE + 1], links: { FREE + 1 => FREE + 1 }),
    'short_chain' => one([FREE, FREE + 1], links: { FREE + 1 => END_OF_CHAIN }),
    'reserved_before_the_count' => volume(files: [keys], bpb: { reserved: CODEC.constant('medium_record_count_start'),
                                                               fat_sectors: (DATA_START - ROOT_SECTORS -
                                                                 CODEC.constant('medium_record_count_start')) / FATS }),
    'data_not_at_the_record' => volume(files: [keys], bpb: { reserved: RESERVED + 1 }),
    'two_sector_clusters' => volume(files: [keys], bpb: { sectors_per_cluster: 2 }),
    'large_sectors' => volume(files: [keys], bpb: { bytes_per_sector: 1024 }),
    'past_the_partition' => volume(files: [keys], bpb: { total: TOTAL + 1 }),
    'untyped' => volume(files: [keys], bpb: { type: 'MSWIN   ' }),
    'straddle' => volume(files: [*SHORT_ONLY, keys]),
    'out_of_order' => volume(files: [out_of_order]),
    'small_fat' => volume(files: [keys], bpb: { fat_sectors: FAT_SECTORS - 1, reserved: RESERVED + FATS }),
    'too_many_keys' => volume(files: [file(long: 'authorized_keys', contents: SEVENTEEN, clusters: (FREE...FREE + 4).to_a)]),
    'skipped_line' => volume(files: [file(long: 'authorized_keys', contents: SKIPPED, clusters: [FREE])]),
    'blank' => {}
  }.freeze

  FILES = { 'found' => KEYS, 'upper' => KEYS, 'slack' => SLACK, 'full' => FULL, 'empty' => '',
            'first_free' => KEYS, 'straddle' => KEYS, 'last_cluster' => KEYS,
            'beside_the_record' => KEYS }.freeze
end
