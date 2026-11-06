# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/boot_record'
require_relative '../../tools/lib/erx/medium_image'

# The boot-selection record's two encodings and the harness's slot parser
# (tools/lib/erx/boot_record.rb), on bytes and on media written by MediumImage.
class BootRecordTest < Minitest::Test
  Record = Erx::BootRecord
  CODEC = Record::CODEC
  SECTOR = Record::SECTOR_BYTES

  # A bootable file of length bytes whose boot header records its length.
  def boot_file(length, image_size: length, magic: true)
    header = CODEC.encode_layout(Record::HEADER, 'code0' => 0, 'code1' => 0, 'text_offset' => 0, 'image_size' => image_size,
                                                 'flags' => 0xa, 'res2' => 0, 'res3' => 0, 'res4' => 0, 'res5' => 0).b
    header[header.index(Record::MAGIC), Record::MAGIC.bytesize] = 'XXXX' unless magic
    header + Random.new(length).bytes(length - header.bytesize)
  end

  def header_of(bytes) = bytes.byteslice(0, Record::HEADER_BYTES)

  def test_each_encoding_is_the_autoboot_text_naming_its_slot_first_then_zeros
    # The encodings are hex in the ABI file: each must name the partitions its constants give.
    a, b = Record::SLOTS.values_at(:a, :b).map(&:partition)
    { a: [a, b], b: [b, a] }.each do |slot, (committed, spare)|
      text = "[all]\ntryboot_a_b=1\nboot_partition=#{committed}\n[tryboot]\nboot_partition=#{spare}\n"
      assert_equal text + ("\0" * (SECTOR - text.bytesize)), Record.sector(slot)
    end
    assert_equal [2, 3], [a, b], 'slot A and slot B are the second and third entries of the master boot record'
  end

  def test_only_the_two_encodings_byte_for_byte_are_a_record
    assert_equal %i[a b], %i[a b].map { |slot| Record.committed(Record.sector(slot)) }
    changed = Record.sector(:a).dup.tap { |bytes| bytes.setbyte(SECTOR - 1, 1) }
    crlf = Record.sector(:a).sub("\n", "\r\n").byteslice(0, SECTOR)
    [changed, crlf, Record.sector(:a).byteslice(0, SECTOR - 1), '', "\0".b * SECTOR, nil].each do |bytes|
      error = assert_raises(Erx::Error) { Record.committed(bytes) }
      assert_match(/unreadable/, error.message)
    end
  end

  def test_the_parser_finds_the_committed_slots_file_from_its_header
    file = boot_file(5000)
    { a: 'medium_slot_a_start', b: 'medium_slot_b_start' }.each do |slot, start|
      choice = Record.choose(record: Record.sector(slot), header: header_of(file))
      offset = (CODEC.constant(start) + CODEC.constant('medium_slot_boot_start')) * SECTOR
      assert_equal Record::Choice.new(slot: slot, offset: offset, length: 5000), choice
    end
  end

  def test_a_header_without_magic_too_short_or_with_a_length_outside_the_slot_is_refused
    room = (CODEC.constant('medium_slot_sectors') - CODEC.constant('medium_slot_boot_start')) * SECTOR
    assert_equal room, Record.choose(record: Record.sector(:a), header: header_of(boot_file(100, image_size: room))).length
    { 'no magic' => [header_of(boot_file(100, magic: false)), /no magic/],
      'short' => [header_of(boot_file(100)).byteslice(0, 63), /boot header is not 64 bytes/],
      'below the header' => [header_of(boot_file(100, image_size: 63)), /claims 63 bytes/],
      'past the slot' => [header_of(boot_file(100, image_size: room + 1)), /claims #{room + 1} bytes/],
      'huge' => [header_of(boot_file(100, image_size: (1 << 64) - 1)), /claims/] }.each do |name, (header, message)|
      error = assert_raises(Erx::Error, name) { Record.choose(record: Record.sector(:a), header: header) }
      assert_match message, error.message, name
    end
    assert_raises(Erx::Error) { Record.choose(record: "\0".b * SECTOR, header: header_of(boot_file(100))) }
  end

  def test_the_bootable_file_comes_out_of_the_slot_the_medium_commits
    Dir.mktmpdir('erx-boot-record-') do |directory|
      file = boot_file(3 * SECTOR + 17)
      other = boot_file(SECTOR + 1)
      boot = CODEC.constant('medium_slot_boot_start')
      pieces = { Record::RECORD_OFFSET / SECTOR => Record.sector(:b),
                 CODEC.constant('medium_slot_a_start') + boot => other, CODEC.constant('medium_slot_b_start') + boot => file }
      medium = Erx::MediumImage.create(directory: directory, name: 'medium.img', pieces: pieces)
      choice = Record.read(medium)
      assert_equal [:b, file.bytesize], [choice.slot, choice.length]
      output = Record.extract(medium, choice, output: File.join(directory, 'image.boot'))
      assert_equal file, File.binread(output)
      assert_raises(Erx::Error) { Record.extract(medium, choice, output: output) }
    end
  end

  def test_a_medium_cut_short_or_without_a_record_is_refused
    Dir.mktmpdir('erx-boot-record-') do |directory|
      short = File.join(directory, 'short.img')
      File.binwrite(short, "\0".b * SECTOR)
      assert_raises(Erx::Error) { Record.read(short) }
      blank = Erx::MediumImage.create(directory: directory, name: 'blank.img', pieces: {})
      assert_match(/unreadable/, assert_raises(Erx::Error) { Record.read(blank) }.message)
      cut = File.join(directory, 'cut.img')
      boot = Record::RECORD_OFFSET + SECTOR
      File.binwrite(cut, Record.sector(:a).rjust(boot, "\0".b))
      File.open(cut, 'r+b') { |io| io.pwrite(header_of(boot_file(4096)), (CODEC.constant('medium_slot_a_start') + CODEC.constant('medium_slot_boot_start')) * SECTOR) }
      assert_match(/ends inside/, assert_raises(Erx::Error) { Record.read(cut) }.message)
    end
  end
end
