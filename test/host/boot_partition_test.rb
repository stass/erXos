# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/boot_partition'

# The Raspberry Pi 4's boot partition (Erx::BootPartition): config.txt from the platform
# record, the layout's names, and a writer that puts files only in its output directory.
class BootPartitionTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PI = Erx::Platform.load(root: ROOT, name: 'raspi4b')

  def test_config_txt_comes_from_the_record
    config = Erx::BootPartition.config_txt(PI, overlays: ['uart3'])
    lines = config.lines(chomp: true).reject { |line| line.start_with?('#') }
    assert_equal %w[arm_64bit=1 kernel=kernel8.img armstub=bl31.bin enable_uart=1 init_uart_clock=48000000 dtoverlay=uart3],
                 lines
  end

  def test_the_pl011s_need_one_clock
    pl011 = { 'compatible' => 'arm,pl011', 'clock' => 48_000_000 }
    units = [{ 'devices' => [pl011] }, { 'devices' => [pl011.merge('clock' => 24_000_000)] }]
    assert_raises(Erx::Error) { Erx::BootPartition.pl011_clock(record(units: units)) }
    assert_raises(Erx::Error) { Erx::BootPartition.pl011_clock(record(units: [])) }
  end

  def test_writes_the_layout_into_its_output_alone
    Dir.mktmpdir do |root|
      output = File.join(root, 'out/boot')
      Erx::BootPartition.write(root: root, output: output, plan: plan(root))
      files = Dir.glob('**/*', base: output).reject { |name| File.directory?(File.join(output, name)) }.sort
      assert_equal %w[LICENCE.broadcom LICENCE.tf-a bcm2711-rpi-4-b.dtb bcm2711-rpi-4-b.dts bl31.bin config.txt fixup4.dat
                      kernel8.img overlays/uart3.dtbo start4.elf], files
      assert_equal 'kernel', File.read(File.join(output, 'kernel8.img'))
      assert_equal %w[boot], Dir.children(File.join(root, 'out')), 'nothing is left beside the output'

      # A layout it wrote is replaced whole.
      File.write(File.join(output, 'stale'), 'x')
      Erx::BootPartition.write(root: root, output: output, plan: plan(root))
      refute File.exist?(File.join(output, 'stale'))
    end
  end

  def test_refuses_to_write_outside_its_output
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |elsewhere|
        assert_raises(Erx::Error) { Erx::BootPartition.write(root: root, output: File.join(elsewhere, 'boot'), plan: plan(root)) }
        assert_empty Dir.children(elsewhere)
      end
      ['../escape', 'overlays/../../escape', '/tmp/escape', 'a/b', 'overlays/'].each do |name|
        assert_raises(Erx::Error, name) do
          Erx::BootPartition.write(root: root, output: File.join(root, 'boot'), plan: { name => Erx::BootPartition::Text.new('') })
        end
      end
      refute File.exist?(File.join(root, 'escape'))
    end
  end

  def test_refuses_to_replace_what_it_did_not_write
    Dir.mktmpdir do |root|
      other = File.join(root, 'other')
      Dir.mkdir(other)
      File.write(File.join(other, 'keep'), 'x')
      assert_raises(Erx::Error) { Erx::BootPartition.write(root: root, output: other, plan: plan(root)) }
      assert File.file?(File.join(other, 'keep'))

      File.symlink(other, File.join(root, 'link'))
      assert_raises(Erx::Error) { Erx::BootPartition.write(root: root, output: File.join(root, 'link'), plan: plan(root)) }
      assert File.file?(File.join(other, 'keep'))
    end
  end

  def test_refuses_a_firmware_file_that_would_replace_one_of_its_own
    Dir.mktmpdir do |root|
      sources = plan(root)
      tree = Erx::BoardTree::Built.new(board: sources.fetch('bcm2711-rpi-4-b.dtb'), source: sources.fetch('bcm2711-rpi-4-b.dts'),
                                       model: '', overlays: {})
      assert_raises(Erx::Error) do
        Erx::BootPartition.plan(platform: PI, bootable: 'k', bl31: 'b', bl31_licence: 'l', tree: tree,
                                firmware: { 'kernel8.img' => 'x' })
      end
    end
  end

  private

  def record(**fields) = Erx::Platform.new(name: 'raspi4b', record: PI.record.merge(fields.transform_keys(&:to_s)))

  # A plan over stand-in files in root/in.
  def plan(root)
    sources = File.join(root, 'in')
    FileUtils.mkdir_p(sources)
    stand_in = lambda do |name, text = name|
      File.join(sources, name).tap { |path| File.write(path, text) }
    end
    tree = Erx::BoardTree::Built.new(board: stand_in.('tree.dtb'), source: stand_in.('tree.dts'), model: stand_in.('model.dtb'),
                                     overlays: { 'uart3' => stand_in.('uart3.dtbo') })
    firmware = %w[start4.elf fixup4.dat LICENCE.broadcom].to_h { |name| [name, stand_in.(name)] }
    Erx::BootPartition.plan(platform: PI, bootable: stand_in.('kernel8', 'kernel'), bl31: stand_in.('bl31'),
                            bl31_licence: stand_in.('licence'),
                            tree: tree, firmware: firmware)
  end
end
