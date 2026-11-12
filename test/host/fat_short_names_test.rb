# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/boot_partition'
require_relative '../../tools/lib/erx/fat_short_names'

# The card's short names (Erx::FatShortNames): which names fit 8.3, and a reader of the
# root directory of a card fsimg writes that refuses one whose boot files the Pi's boot
# ROM, which reads only short names, would not find.
class FatShortNamesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  FSIMG = Erx::Fsimg.locate(root: ROOT)
  BOOT_FILES = %w[start4.elf fixup4.dat config.txt kernel8.img bl31.bin].freeze

  def test_a_single_case_name_that_fits_8_3_is_its_short_form
    assert_equal Erx::FatShortNames::Short.new(name: 'START4  ELF'.b, flags: 0x18), Erx::FatShortNames.short_form('start4.elf')
    assert_equal Erx::FatShortNames::Short.new(name: 'README     '.b, flags: 0), Erx::FatShortNames.short_form('README')
    assert_equal Erx::FatShortNames::Short.new(name: 'OVERLAYS   '.b, flags: 0x08), Erx::FatShortNames.short_form('overlays')
    assert_equal Erx::FatShortNames::Short.new(name: 'KERNEL8 IMG'.b, flags: 0x10), Erx::FatShortNames.short_form('KERNEL8.img')
  end

  def test_a_name_that_needs_a_long_name_has_no_short_form
    %w[LICENCE.broadcom bcm2711-rpi-4-b.dtb Start4.elf start4.Elf a.b.c longername.txt name. .dtb a+b.txt].each do |name|
      assert_nil Erx::FatShortNames.short_form(name), name
    end
  end

  # A card fsimg writes stores each boot file under its own short name with the case
  # flags that restore it; the same card with start4.elf under a numbered alias, as an
  # fsimg that gave every lowercase name one wrote it, is refused.
  def test_refuses_a_card_whose_boot_file_has_an_alias
    Dir.mktmpdir do |root|
      image = card(root)
      names = [*BOOT_FILES, 'LICENCE.broadcom', 'overlays']
      Erx::FatShortNames.check(image, names: names)
      entries = Erx::FatShortNames.root_entries(image).to_h { |entry| [entry.name, entry] }
      BOOT_FILES.each do |name|
        short = Erx::FatShortNames.short_form(name)
        assert_equal short.flags, entries.fetch(short.name).flags, name
      end

      File.open(image, 'r+b') { |file| file.pwrite('F0000009   ', entries.fetch('START4  ELF'.b).offset) }
      error = assert_raises(Erx::Error) { Erx::FatShortNames.check(image, names: names) }
      assert_match(/not stored as their own short names with their case flags: start4\.elf\z/, error.message)
    end
  end

  # start4.elf under its own short name but without its case flags, or a second entry of
  # the same short name, is refused too.
  def test_refuses_lost_case_flags_and_a_repeated_short_name
    Dir.mktmpdir do |root|
      image = card(root)
      entries = Erx::FatShortNames.root_entries(image).to_h { |entry| [entry.name, entry] }
      File.open(image, 'r+b') { |file| file.pwrite("assert_match(/not stored as their own short names: start4\.elf\z/, error.message)
    end
  end
", entries.fetch('START4  ELF'.b).offset + 12) }
      assert_raises(Erx::Error) { Erx::FatShortNames.check(image, names: ['start4.elf']) }

      File.open(image, 'r+b') { |file| file.pwrite('START4  ELF', entries.fetch('FIXUP4  DAT'.b).offset) }
      error = assert_raises(Erx::Error) { Erx::FatShortNames.check(image, names: []) }
      assert_match(/repeats the short names/, error.message)
    end
  end

  # A root directory whose cluster chain leads back to its first cluster is refused, not
  # walked forever.
  def test_refuses_a_looping_root_directory
    Dir.mktmpdir do |root|
      image = card(root)
      partition = File.binread(image, 4, 446 + 8).unpack1('V') * 512
      bytes_per_sector, reserved = File.binread(image, 5, partition + 11).unpack('vxv')
      root_cluster = File.binread(image, 4, partition + 44).unpack1('V')
      File.open(image, 'r+b') { |file| file.pwrite([root_cluster].pack('V'), partition + (reserved * bytes_per_sector) + (root_cluster * 4)) }
      error = assert_raises(Erx::Error) { Erx::FatShortNames.root_entries(image) }
      assert_match(/chain loops/, error.message)
    end
  end

  def test_refuses_a_truncated_card
    Dir.mktmpdir do |root|
      image = card(root)
      File.truncate(image, 2 * 1024 * 1024)
      assert_raises(Erx::Error) { Erx::FatShortNames.root_entries(image) }
    end
  end

  private

  # A card written as BootPartition writes one, of stand-in boot files and an overlay.
  def card(root)
    files = File.join(root, 'files')
    FileUtils.mkdir_p(File.join(files, 'overlays'))
    [*BOOT_FILES, 'LICENCE.broadcom', 'overlays/uart3.dtbo'].each { |name| File.write(File.join(files, name), name) }
    image = File.join(root, 'sdcard.img')
    _, status = Open3.capture2e(FSIMG, 'cW', '-f', image, *Erx::BootPartition::CARD, '-C', files, '.', stdin_data: '')
    assert status.success?, 'fsimg writes the card'
    image
  end
end
