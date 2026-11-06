# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/block_image'

class BlockImageTest < Minitest::Test
  Image = Erx::BlockImage

  def with_directory(&block) = Dir.mktmpdir('erx-block-image-', &block)

  def test_a_sector_pattern_names_its_tag_and_index
    sector = Image.pattern(3, tag: Image::HOST_TAG)
    assert_equal 512, sector.bytesize
    assert_equal "ERXHOST!\x03\0\0\0\0\0\0\0".b, sector.byteslice(0, 16)
    assert_equal sector.byteslice(0, 16) * 32, sector
    refute_equal sector, Image.pattern(4, tag: Image::HOST_TAG)
    refute_equal sector, Image.pattern(3, tag: Image::GUEST_TAG)
  end

  def test_a_pattern_refuses_a_bad_index_or_tag
    [-1, 2**64, '1', nil].each { |index| assert_raises(Erx::Error) { Image.pattern(index, tag: Image::HOST_TAG) } }
    ['short', "ERXHOS\u00e9\u00e9", nil].each { |tag| assert_raises(Erx::Error) { Image.pattern(0, tag: tag) } }
  end

  def test_create_writes_every_sector_with_the_host_pattern
    with_directory do |directory|
      path = Image.create(directory: directory, name: 'disk.img', sectors: 4)
      assert_equal File.join(File.realpath(directory), 'disk.img'), path
      assert_equal 4 * 512, File.size(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal (0...4).map { |index| Image.pattern(index, tag: Image::HOST_TAG) }.join, File.binread(path)
    end
  end

  def test_create_refuses_an_existing_file_a_link_a_bad_name_and_a_bad_size
    with_directory do |directory|
      Image.create(directory: directory, name: 'disk.img', sectors: 1)
      assert_raises(Erx::Error) { Image.create(directory: directory, name: 'disk.img', sectors: 1) }
      File.symlink(File.join(directory, 'elsewhere'), File.join(directory, 'link.img'))
      assert_raises(Erx::Error) { Image.create(directory: directory, name: 'link.img', sectors: 1) }
      refute File.exist?(File.join(directory, 'elsewhere'))
      ['../x', 'a/b', '', '.hidden', 'A.img', nil].each do |name|
        assert_raises(Erx::Error, name.inspect) { Image.create(directory: directory, name: name, sectors: 1) }
      end
      [0, -1, Image::MAX_SECTORS + 1, '1', nil].each do |sectors|
        assert_raises(Erx::Error, sectors.inspect) { Image.create(directory: directory, name: 'big.img', sectors: sectors) }
      end
      assert_raises(Erx::Error) { Image.create(directory: File.join(directory, 'missing'), name: 'x.img', sectors: 1) }
    end
  end

  def test_an_untouched_image_matches_the_host_pattern_everywhere
    with_directory do |directory|
      path = Image.create(directory: directory, name: 'disk.img', sectors: 4)
      expected = (0...4).to_h { |index| [index, Image::HOST_TAG] }
      results = Image.check(path: path, sectors: 4, expected: expected)
      assert_equal [0, 1, 2, 3], results.map(&:index)
      assert_equal [:match], results.map(&:status).uniq
    end
  end

  def test_check_reports_a_written_sector_a_damaged_one_and_a_foreign_one
    with_directory do |directory|
      path = Image.create(directory: directory, name: 'disk.img', sectors: 4)
      File.open(path, 'r+b') do |file|
        file.pwrite(Image.pattern(1, tag: Image::GUEST_TAG), 512)
        file.pwrite(Image.pattern(2, tag: Image::HOST_TAG).sub('!', '?'), 1024)
        file.pwrite(Image.pattern(0, tag: Image::HOST_TAG), 1536) # sector 0's content in sector 3
      end
      expected = { 0 => Image::HOST_TAG, 1 => Image::GUEST_TAG, 2 => Image::HOST_TAG, 3 => Image::HOST_TAG }
      results = Image.check(path: path, sectors: 4, expected: expected)
      assert_equal [0, 1], Image.indexes(results, :match)
      assert_equal [2, 3], Image.indexes(results, :differ)
      assert_empty Image.indexes(results, :out_of_range)
      # The guest's sector is not the host's.
      wrong = Image.check(path: path, sectors: 4, expected: { 1 => Image::HOST_TAG })
      assert_equal [1], Image.indexes(wrong, :differ)
    end
  end

  def test_a_sector_beyond_the_image_or_the_file_is_out_of_range
    with_directory do |directory|
      path = Image.create(directory: directory, name: 'disk.img', sectors: 4)
      File.truncate(path, 2 * 512 + 100)
      expected = { -1 => Image::HOST_TAG, 0 => Image::HOST_TAG, 1 => Image::HOST_TAG, 2 => Image::HOST_TAG, 4 => Image::HOST_TAG }
      results = Image.check(path: path, sectors: 4, expected: expected)
      assert_equal [-1, 0, 1, 2, 4], results.map(&:index)
      assert_equal %i[out_of_range match match out_of_range out_of_range], results.map(&:status)
    end
  end

  def test_check_refuses_a_path_that_is_not_a_bounded_regular_file
    with_directory do |directory|
      real = Image.create(directory: directory, name: 'disk.img', sectors: 1)
      link = File.join(directory, 'link.img')
      File.symlink(real, link)
      huge = File.join(directory, 'huge.img')
      File.open(huge, 'wb') { |file| file.truncate((Image::MAX_SECTORS * 512) + 1) }
      [link, huge, directory, File.join(directory, 'missing'), 'relative', "/a\0b", nil].each do |path|
        assert_raises(Erx::Error, path.inspect) { Image.check(path: path, sectors: 1, expected: { 0 => Image::HOST_TAG }) }
      end
      assert_raises(Erx::Error) { Image.check(path: real, sectors: 1, expected: { 0 => 'x' }) }
      assert_raises(Erx::Error) { Image.check(path: real, sectors: 1, expected: [0]) }
      assert_raises(Erx::Error) { Image.check(path: real, sectors: 0, expected: {}) }
      too_many = (0..Image::MAX_SECTORS).to_h { |index| [index, Image::HOST_TAG] }
      assert_raises(Erx::Error) { Image.check(path: real, sectors: 1, expected: too_many) }
    end
  end
end
