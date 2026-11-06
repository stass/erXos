# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/block_device'

# The medium the block device suite's second boot attaches, and how the suite judges that
# boot. These tests write media into a temporary directory and boot nothing.
class MediumImageTest < Minitest::Test
  Device = Erx::BlockDevice
  Medium = Erx::MediumImage
  Image = Erx::BlockImage
  CODEC = Erx::ABI::Generated::CODEC

  def entries(path, sector)
    bytes = File.open(path, 'rb') { |file| file.pread(512, sector * 512) }
    assert_equal "\x55\xaa".b, bytes.byteslice(510, 2)
    (0...4).map do |index|
      entry = CODEC.decode_layout('erx_mbr_entry', bytes.byteslice(446 + (16 * index), 16))
      [entry.fetch('type'), entry.fetch('lba_start'), entry.fetch('lba_sectors')]
    end
  end

  def test_the_medium_is_sparse_and_holds_the_layouts_table
    Dir.mktmpdir('erx-medium-') do |directory|
      path = Medium.create(directory: directory, name: 'medium.img')
      assert_equal Medium.sectors * 512, File.size(path)
      windows = Medium.windows.to_h { |window| [window.role, window] }
      data_end = windows[:data].start + windows[:data].sectors
      extended = CODEC.constant('medium_extended_start')
      data_ebr = CODEC.constant('medium_data_ebr')
      assert_equal [[0x0e, windows[:record].start, windows[:record].sectors],
                    [0x0c, windows[:slot_a].start, windows[:slot_a].sectors],
                    [0x0c, windows[:slot_b].start, windows[:slot_b].sectors],
                    [0x0f, extended, data_end - extended]], entries(path, 0)
      assert_equal [[0x83, windows[:vault].start - extended, windows[:vault].sectors],
                    [0x05, data_ebr - extended, data_end - data_ebr], [0, 0, 0], [0, 0, 0]], entries(path, extended)
      assert_equal [[0x83, windows[:data].start - data_ebr, windows[:data].sectors], [0, 0, 0], [0, 0, 0], [0, 0, 0]],
                   entries(path, data_ebr)
      assert_operator Medium::DATA_SECTORS, :>, CODEC.constant('medium_data_sectors_min')
    end
  end

  def test_a_medium_is_never_written_over_a_file_or_through_a_link
    Dir.mktmpdir('erx-medium-') do |directory|
      Medium.create(directory: directory, name: 'medium.img')
      assert_raises(Erx::Error) { Medium.create(directory: directory, name: 'medium.img') }
      File.symlink(File.join(directory, 'elsewhere'), File.join(directory, 'link.img'))
      assert_raises(Erx::Error) { Medium.create(directory: directory, name: 'link.img') }
      assert_raises(Erx::Error) { Medium.create(directory: directory, name: '../medium.img') }
    end
  end

  def test_the_expected_lines_name_every_window_in_role_order
    lines = Device.medium_expected_lines
    assert_equal "blk: capacity #{Medium.sectors} sectors", lines.first
    assert_equal 'blk: done', lines.last
    assert_equal Medium::ROLES.map { |role| "blk: window #{role} sectors" },
                 lines.grep(/sectors \d+\z/).map { |line| line.sub(/ \d+\z/, '') }
    vault = Medium.windows.find { |window| window.role == :vault }
    assert_includes lines, "blk: window vault sector #{vault.sectors - 1} holds host #{vault.last}"
    assert_nil Device.line_difference("#{lines.map { |line| "#{line}\r\n" }.join}", expected: lines)
    assert_match(/driver line 2:/, Device.line_difference("#{lines.first}\nblk: done\n", expected: lines))
  end

  def test_the_medium_after_a_good_run_is_as_expected_and_a_missed_write_is_reported
    data = Medium.windows.find { |window| window.role == :data }
    Dir.mktmpdir('erx-medium-') do |directory|
      path = Medium.create(directory: directory, name: 'medium.img')
      assert_equal "medium sectors not as expected: #{data.last} differ", Device.medium_image_difference(path)
      File.open(path, 'r+b') { |file| file.pwrite(Image.pattern(data.last, tag: Image::GUEST_TAG), data.last * 512) }
      assert_nil Device.medium_image_difference(path)
      data_ebr = CODEC.constant(%q(medium_data_ebr))
      File.open(path, %q(r+b)) { |file| file.pwrite(Image.pattern(0, tag: Image::GUEST_TAG), data_ebr * 512) }
      assert_equal %Q(medium sectors not as expected: #{data_ebr} record), Device.medium_image_difference(path)
    end
  end
end
