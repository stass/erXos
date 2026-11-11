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
    assert_equal ['blk: transport version 2', 'blk: capacity 16 sectors'], lines.first(2)
    assert_equal 'blk: read sector 0 ok', lines[2]
    assert_equal 'blk: read sector 15 ok', lines[17]
    assert_equal 'blk: read sector 16 refused', lines[18]
    assert_equal ['blk: wrote sector 3', 'blk: wrote sector 7'], lines[19, 2]
    assert_equal ['blk: control restart block ok', 'blk: control restart flux refused', 'blk: read sector 0 again ok',
                  'blk: done'], lines.last(4)
    assert_equal 25, lines.size
  end

  def test_a_good_log_has_no_difference_and_other_lines_are_ignored
    assert_nil Device.line_difference(good_log)
    assert_nil Device.line_difference(good_log.sub("Hello\r\n", "Hello\nblock: not ours\n"))
    assert_nil Device.line_difference(good_log.delete("\r"))
  end

  def test_lines_after_done_are_not_judged
    assert_nil Device.line_difference(good_log([*Device.expected_lines, 'blk: stray']))
  end

  def test_a_wrong_transport_version_or_no_driver_is_a_difference
    old = Device.expected_lines.map { |line| line.sub('transport version 2', 'transport version 1') }
    assert_equal 'driver line 1: expected "blk: transport version 2", got "blk: transport version 1"',
                 Device.line_difference(good_log(old))
    assert_match(/line 1: .*got "blk: no driver"/, Device.line_difference(good_log(['blk: no driver', 'blk: done'])))
  end

  # The test module reaches the guest only in a test image: the boot checks the banner's
  # test-image line, and the kernel command line starts the module from its directory.
  def test_the_boot_is_a_test_image_that_runs_the_test_module
    names = Device.checkpoints.map { |point| point.fetch(:name) }
    assert_includes names, Erx::Qemu::TEST_IMAGE_BANNER.fetch(:name)
    assert_equal 'erx.arg=-pa erx.arg=/test/blk erx.arg=-run erx.arg=erx_blk_check erx.arg=main', Device.command_line('hvf')
    assert_equal "#{Erx::ProductionImage::Run::COMMAND_LINES.fetch('tcg')} erx.arg=-pa", Device.command_line('tcg')[/\A\S+ \S+/]
    assert File.file?(File.expand_path("../../#{Device::GUEST_SOURCE}", __dir__))
  end

  def test_a_missing_line_names_the_first_difference
    missing = Device.expected_lines - ['blk: read sector 5 ok']
    assert_equal 'driver line 8: expected "blk: read sector 5 ok", got "blk: read sector 6 ok"', Device.line_difference(good_log(missing))
    assert_match(/line 25: expected "blk: done", got no line/, Device.line_difference(good_log(Device.expected_lines[0...-1])))
    assert_match(/line 1: expected .*, got no line/, Device.line_difference('nothing'))
  end

  def test_a_failure_line_an_extra_line_and_a_reordering_are_differences
    failed = Device.expected_lines.map { |line| line == 'blk: wrote sector 7' ? 'blk: wrote sector 7 failed' : line }
    assert_match(/line 21: .*got "blk: wrote sector 7 failed"/, Device.line_difference(good_log(failed)))
    swapped = Device.expected_lines.dup.tap { |lines| lines[3], lines[4] = lines[4], lines[3] }
    assert_match(/line 4: /, Device.line_difference(good_log(swapped)))
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

  # The command shell's prompt ends no line, so the driver's next line can follow it.
  def test_a_command_shell_prompt_may_open_a_driver_line
    assert_match Device.checkpoints.last.fetch(:pattern), "% blk: done\r\n"
    prompted = good_log.sub("blk: done\r\n", "% blk: done\r\n").sub('blk: read sector 4 ok', '% blk: read sector 4 ok')
    refute_equal good_log, prompted
    assert_nil Device.line_difference(prompted)
    failed = prompted.sub('% blk: read sector 4 ok', '% blk: read sector 4 failed')
    assert_match(/line 7: .*got "blk: read sector 4 failed"/, Device.line_difference(failed))
    refute_match Device.checkpoints.last.fetch(:pattern), "%% blk: done\r\n"
  end

  def test_the_power_cut_lines_are_the_documented_sequence
    assert_equal ['blk: data unsynced written', 'blk: data synced 10000 bytes', 'blk: done'], Device.write_expected_lines
    synced, unsynced, done = Device.read_expected_lines
    # The digest the guest's erlang:md5/1 printed for its own content.
    assert_equal 'blk: data synced 10000 bytes md5 bbf1c77538f97ceeb1e03126edaa3594', synced
    assert_kind_of Regexp, unsynced
    assert_equal 'blk: done', done
    assert_equal 'erx.arg=-pa erx.arg=/test/blk erx.arg=-run erx.arg=erx_blk_check erx.arg=data_write',
                 Device.command_line('hvf', arguments: Device::WRITE_ARGUMENTS)
    assert_equal 'erx.arg=-pa erx.arg=/test/blk erx.arg=-run erx.arg=erx_blk_check erx.arg=data_read',
                 Device.command_line('hvf', arguments: Device::READ_ARGUMENTS)
  end

  def test_the_power_cut_content_is_the_guests
    content = Device.data_content(1)
    assert_equal 10_000, content.bytesize
    assert_equal [1, 2, 250, 0, 1], content.bytes.values_at(0, 1, 249, 250, 251)
  end

  # An unsynced file absent or cut short passes, and the outcome is read back for the
  # run's notes; bytes nobody wrote, a failure to read it, or a synced file that
  # differs do not pass.
  def test_any_unsynced_outcome_passes_and_is_reported
    synced = Device.read_expected_lines.first
    ['absent', '0 bytes prefix', '4096 bytes prefix'].each do |outcome|
      log = good_log([synced, "blk: data unsynced #{outcome}", 'blk: done'])
      assert_nil Device.line_difference(log, expected: Device.read_expected_lines), outcome
      assert_equal outcome, Device.unsynced_outcome(log)
    end
    other = good_log([synced, 'blk: data unsynced 10000 bytes other', 'blk: done'])
    assert_match(/line 2: .*got "blk: data unsynced 10000 bytes other"/, Device.line_difference(other, expected: Device.read_expected_lines))
    failed = good_log([synced, 'blk: data unsynced failed', 'blk: done'])
    assert_match(/line 2: expected a line matching .*, got "blk: data unsynced failed"/,
                 Device.line_difference(failed, expected: Device.read_expected_lines))
    assert_nil Device.unsynced_outcome(failed)
    lost = good_log(['blk: data synced 10000 bytes md5 00000000000000000000000000000000', 'blk: data unsynced absent', 'blk: done'])
    assert_match(/line 1: expected "blk: data synced 10000 bytes md5 bbf1/, Device.line_difference(lost, expected: Device.read_expected_lines))
    assert_match(/line 1: .*got "blk: data synced failed"/,
                 Device.line_difference(good_log(['blk: data synced failed', 'blk: data unsynced absent', 'blk: done']),
                                        expected: Device.read_expected_lines))
  end

  def test_a_first_boot_that_did_not_sync_is_a_difference
    log = good_log(['blk: data unsynced written', 'blk: data synced failed', 'blk: done'])
    assert_match(/line 2: .*got "blk: data synced failed"/, Device.line_difference(log, expected: Device.write_expected_lines))
    assert_nil Device.line_difference(good_log(Device.write_expected_lines), expected: Device.write_expected_lines)
  end

  def test_a_missing_unsynced_line_is_a_difference
    log = good_log([Device.read_expected_lines.first, 'blk: done'])
    assert_match(/line 2: expected a line matching .*, got "blk: done"/, Device.line_difference(log, expected: Device.read_expected_lines))
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
