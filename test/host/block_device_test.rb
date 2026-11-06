# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/block_device'

# The block driver's suite judges serial text and a disk image. These tests feed it
# fixture logs and images and boot nothing.
class BlockDeviceTest < Minitest::Test
  Device = Erx::BlockDevice
  Image = Erx::BlockImage

  def good_log(lines = Device.expected_lines)
    "Hello\r\nerXos\r\n#{lines.map { |line| "#{line}\r\n" }.join}shell>\r\n"
  end

  def test_the_expected_lines_are_the_documented_sequence
    lines = Device.expected_lines
    assert_equal 'blk: capacity 16 sectors', lines.first
    assert_equal 'blk: read sector 0 ok', lines[1]
    assert_equal 'blk: read sector 15 ok', lines[16]
    assert_equal 'blk: read sector 16 refused', lines[17]
    assert_equal ['blk: wrote sector 3', 'blk: wrote sector 7', 'blk: done'], lines.last(3)
    assert_equal 21, lines.size
  end

  def test_a_good_log_has_no_difference_and_other_lines_are_ignored
    assert_nil Device.line_difference(good_log)
    assert_nil Device.line_difference(good_log.sub("Hello\r\n", "Hello\nblock: not ours\n"))
    assert_nil Device.line_difference(good_log.delete("\r"))
  end

  def test_lines_after_done_are_not_judged
    assert_nil Device.line_difference(good_log([*Device.expected_lines, 'blk: stray']))
  end

  def test_the_driver_is_not_landed_so_the_suite_is_pending
    refute Device::DRIVER_LANDED
  end

  def test_a_missing_line_names_the_first_difference
    missing = Device.expected_lines - ['blk: read sector 5 ok']
    assert_equal 'driver line 7: expected "blk: read sector 5 ok", got "blk: read sector 6 ok"', Device.line_difference(good_log(missing))
    assert_match(/line 21: expected "blk: done", got no line/, Device.line_difference(good_log(Device.expected_lines[0...-1])))
    assert_match(/line 1: expected .*, got no line/, Device.line_difference('nothing'))
  end

  def test_a_failure_line_an_extra_line_and_a_reordering_are_differences
    failed = Device.expected_lines.map { |line| line == 'blk: wrote sector 7' ? 'blk: wrote sector 7 failed' : line }
    assert_match(/line 20: .*got "blk: wrote sector 7 failed"/, Device.line_difference(good_log(failed)))
    swapped = Device.expected_lines.dup.tap { |lines| lines[2], lines[3] = lines[3], lines[2] }
    assert_match(/line 3: /, Device.line_difference(good_log(swapped)))
  end

  def test_guest_text_in_a_report_is_escaped_and_cut_short
    hostile = "blk: \e]0;owned\a\xff#{'x' * 500}"
    message = Device.line_difference(good_log([hostile]))
    assert_match(/\A[ -~]+\z/, message)
    refute_includes message, "\e"
    assert_includes message, '\\u{1b}'
    assert_operator message.bytesize, :<, 400
  end

  def test_the_checkpoints_end_on_the_last_driver_line
    last = Device.checkpoints.last
    assert_equal 'block-done', last.fetch(:name)
    assert_match last.fetch(:pattern), "blk: done\r\n"
    refute_match last.fetch(:pattern), "blk: wrote sector 7\r\n"
  end

  def finished_image(directory, write: Device::WRITE_SECTORS)
    path = Image.create(directory: directory, name: 'disk.img', sectors: Device::SECTORS)
    File.open(path, 'r+b') { |file| write.each { |index| file.pwrite(Image.pattern(index, tag: Image::GUEST_TAG), index * 512) } }
    path
  end

  def test_an_image_with_exactly_the_guest_writes_is_as_expected
    Dir.mktmpdir('erx-block-device-') { |directory| assert_nil Device.image_difference(finished_image(directory)) }
  end

  def test_an_image_the_guest_did_not_write_or_wrote_too_much_is_reported
    Dir.mktmpdir('erx-block-device-') do |directory|
      assert_equal 'disk sectors not as expected: 7 differ', Device.image_difference(finished_image(directory, write: [3]))
    end
    Dir.mktmpdir('erx-block-device-') do |directory|
      assert_equal 'disk sectors not as expected: 5 differ', Device.image_difference(finished_image(directory, write: [3, 5, 7]))
    end
    Dir.mktmpdir('erx-block-device-') do |directory|
      path = finished_image(directory)
      File.truncate(path, 8 * 512)
      assert_equal 'disk sectors not as expected: 8 out_of_range, 9 out_of_range, 10 out_of_range, 11 out_of_range, ' \
                   '12 out_of_range, 13 out_of_range, 14 out_of_range, 15 out_of_range', Device.image_difference(path)
    end
  end
end
