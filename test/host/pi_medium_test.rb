# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/fsimg'
require_relative '../../tools/lib/erx/pi_medium'

# The Raspberry Pi card's volumes (Erx::PiMedium) as fsimg writes them with the card's
# own arguments, and the packer's check of each placed file (Erx::FatVolume.check_placed):
# it accepts what fsimg wrote, and refuses each way a placement can go wrong, seeded
# into the volume: a kernel8.img whose chain jumps once, ends early or runs on, an entry
# that starts elsewhere or records another length, other bytes at the placement, a
# record sector that is not medium_record_a, and a reset count sector that is not zero.
class PiMediumTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  FSIMG = Erx::Fsimg.locate(root: ROOT)
  PI = Erx::PiMedium
  # A kernel8.img of several clusters whose last is partly filled.
  KERNEL = Random.new(7).bytes((5 * 1024) + 100)

  # The card is a power of two long and holds the layout's minimum data partition.
  def test_the_card_is_a_power_of_two
    sectors = Erx::MediumImage.sectors(data_sectors: PI.data_sectors)
    assert_equal 1 << 31, sectors * Erx::MediumImage::SECTOR_BYTES
    assert_operator PI.data_sectors, :>=, Erx::MediumImage.constant('data_sectors_min')
    assert_equal 0, PI.data_sectors % 2048, 'the data partition ends on a MiB'
  end

  def test_accepts_the_volumes_fsimg_writes
    volumes do |record, slot|
      PI.check_volumes(record: record, slot: slot, boot: KERNEL, names: [PI::BOOT_FILE, 'config.txt'])
      Erx::FatVolume.open(record) { |volume| assert_equal :fat16, volume.layout.kind.name }
      Erx::FatVolume.open(slot) { |volume| assert_equal :fat32, volume.layout.kind.name }
      assert_equal KERNEL, File.binread(slot, KERNEL.bytesize, PI::BOOT_PLACE)
      assert_equal Erx::BootRecord.sector(:a), File.binread(record, 512, PI::RECORD_PLACE)
    end
  end

  # Seeded faults in the slot volume's kernel8.img: each is refused with its reason.
  def test_refuses_a_misplaced_kernel
    volumes do |record, slot|
      fat, entry = kernel_entry(slot)
      first = entry.first_cluster
      {
        'a fragmented chain' => [fat + ((first + 1) * 4), [first + 3].pack('V'), /not consecutive at cluster #{first + 1}/],
        'a chain that ends early' => [fat + (first * 4), [0x0fffffff].pack('V'), /ends early, at cluster #{first}\z/],
        'a chain that runs on' => [fat + ((first + 5) * 4), [first + 6].pack('V'), /runs on past its last cluster/],
        'an entry that starts elsewhere' => [entry.offset + 26, [first + 1].pack('v'), /starts at cluster #{first + 1}/],
        'an entry of another length' => [entry.offset + 28, [KERNEL.bytesize - 1].pack('V'), /bytes, not #{KERNEL.bytesize}/],
        'other bytes at the placement' => [PI::BOOT_PLACE + 4097, "\x00".b, /does not hold .* contents/]
      }.each do |fault, (offset, bytes, reason)|
        patched(slot, offset, bytes) do
          error = assert_raises(Erx::Error, fault) do
            PI.check_volumes(record: record, slot: slot, boot: KERNEL, names: [PI::BOOT_FILE])
          end
          assert_match reason, error.message, fault
        end
      end
    end
  end

  # Seeded faults in the record volume.
  def test_refuses_a_bad_record_volume
    volumes do |record, slot|
      check = -> { PI.check_volumes(record: record, slot: slot, boot: KERNEL, names: [PI::BOOT_FILE]) }
      patched(record, PI::RECORD_PLACE + 100, "x") do
        assert_match(/record's sector is not medium_record_a/, assert_raises(Erx::Error, &check).message)
      end
      patched(record, PI::RECORD_PLACE + 20, "3") do
        assert_match(/does not hold .* contents/, assert_raises(Erx::Error, &check).message)
      end
      patched(record, PI::COUNT_OFFSET, "\x01") do
        assert_match(/reset count's sector is not zero/, assert_raises(Erx::Error, &check).message)
      end
    end
  end

  # A volume of the wrong kind, a truncated one and one with no placed file are refused.
  def test_refuses_the_wrong_volume
    volumes do |record, slot|
      error = assert_raises(Erx::Error) { PI.check_volumes(record: slot, slot: record, boot: KERNEL, names: []) }
      assert_match(/is fat32, not fat16/, error.message)
      Erx::FatVolume.open(record) do |volume|
        error = assert_raises(Erx::Error) do
          Erx::FatVolume.check_placed(volume, kind: :fat16, short: 'KERNEL8 IMG'.b, offset: PI::RECORD_PLACE, contents: 'x')
        end
        assert_match(/has no root entry/, error.message)
      end
      File.truncate(slot, 64 * 1024 * 1024)
      assert_raises(Erx::Error) { Erx::FatVolume.open(slot, &:root_entries) }
    end
  end

  private

  # Writes the record and slot volumes with the card's arguments into a fresh directory
  # and yields their paths.
  def volumes
    Dir.mktmpdir do |root|
      record_files = File.join(root, 'record-files')
      slot_files = File.join(root, 'slot-files')
      [record_files, slot_files].each { |path| Dir.mkdir(path) }
      File.binwrite(File.join(record_files, PI::RECORD_FILE), Erx::BootRecord::SLOTS.fetch(:a).text)
      File.binwrite(File.join(slot_files, PI::BOOT_FILE), KERNEL)
      File.write(File.join(slot_files, 'config.txt'), "arm_64bit=1\n")
      record = File.join(root, 'record.fat')
      slot = File.join(root, 'slot.fat')
      fsimg('cW', '-f', record, *PI::RECORD_VOLUME, '-C', record_files, '.')
      fsimg('cW', '-f', slot, *PI::SLOT_VOLUME, '-C', slot_files, '.')
      yield record, slot
    end
  end

  # The first FAT's offset in the slot volume and kernel8.img's root entry.
  def kernel_entry(slot)
    Erx::FatVolume.open(slot) do |volume|
      [volume.layout.fat_offset, volume.root_entries.find { |entry| entry.name == 'KERNEL8 IMG'.b }]
    end
  end

  # Runs the block with bytes written at offset of path, then puts the old bytes back.
  def patched(path, offset, bytes)
    old = File.binread(path, bytes.bytesize, offset)
    File.open(path, 'r+b') { |file| file.pwrite(bytes, offset) }
    yield
  ensure
    File.open(path, 'r+b') { |file| file.pwrite(old, offset) } if old
  end

  def fsimg(*arguments)
    output, status = Open3.capture2e(FSIMG, *arguments, stdin_data: '')
    assert status.success?, "fsimg #{arguments.join(' ')} failed: #{output}"
  end
end
