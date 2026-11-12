# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/platform'
require_relative '../../tools/lib/erx/production_image'
require_relative '../../tools/lib/erx/qemu'

# The platform record as every tool that builds or boots an image takes it (Erx::Platform):
# its RAM numbers, the refusal of a record that lacks one, and what is derived from them.
class PlatformTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  VIRT = Erx::Platform.development(ROOT)
  # A tree with QEMU virt's memory node, as dtc prints it.
  MEMORY_TREE = <<~DTS
    /dts-v1/;

    / {
    \tmemory@40000000 {
    \t\treg = <0x00 0x40000000 0x00 0x10000000>;
    \t\tdevice_type = "memory";
    \t};
    };
  DTS

  def record(**changes) = VIRT.record.merge(changes.transform_keys(&:to_s))

  def test_the_development_record_states_virts_ram
    assert_equal 'qemu-virt', VIRT.name
    assert_equal 0x4000_0000, VIRT.ram_first
    assert_equal [256, 16], [VIRT.memory_mib, VIRT.fiasco_reserve_mib]
    assert_equal 'config/manifest/qemu-virt-development.txt', VIRT.manifest_path
    assert File.file?(File.join(ROOT, VIRT.manifest_path))
    assert File.file?(File.join(ROOT, VIRT.site_manifest_path))
  end

  def test_a_record_without_a_ram_number_is_refused_by_name
    %w[ram_first ram_bytes fiasco_reserve].each do |field|
      without = VIRT.record.reject { |key, _value| key == field }
      error = assert_raises(Erx::Error) { Erx::Platform.new(name: 'qemu-virt', record: without) }
      assert_equal "config/platforms/qemu-virt.json: no #{field}", error.message
    end
  end

  def test_a_ram_number_that_is_not_whole_mib_is_refused
    [{ ram_first: 0x4000_1000 }, { ram_first: -(1 << 20) }, { ram_first: '1073741824' }, { ram_bytes: 0 },
     { fiasco_reserve: 4096 }, { fiasco_reserve: 256 << 20 }].each do |change|
      assert_raises(Erx::Error, change.inspect) { Erx::Platform.new(name: 'qemu-virt', record: record(**change)) }
    end
  end

  def test_a_record_of_another_name_or_without_units_is_refused
    assert_raises(Erx::Error) { Erx::Platform.new(name: 'qemu-virt', record: record(name: 'raspi4b')) }
    assert_raises(Erx::Error) { Erx::Platform.new(name: 'qemu-virt', record: record(units: {})) }
    assert_raises(Erx::Error) { Erx::Platform.load(root: ROOT, name: '../platforms/qemu-virt') }
    Dir.mktmpdir { |root| assert_match(/no platform record/, assert_raises(Erx::Error) { Erx::Platform.load(root: root, name: 'qemu-virt') }.message) }
  end

  # The root's place counts from the record's ram_first: a board with RAM at 0, as the
  # Raspberry Pi 4's, places the development root 64 MiB from 0.
  def test_the_roots_place_counts_from_the_records_ram
    assert_equal 0x4000_0000 + (64 << 20), Erx::ProductionImage::Machine.development(VIRT).root_address
    low = Erx::Platform.new(name: 'qemu-virt', record: record(ram_first: 0))
    assert_equal 64 << 20, Erx::ProductionImage::Machine.development(low).root_address
    assert_equal Erx::NativeRoot.development_place(low), Erx::ProductionImage::Machine.development(low).root_address
  end

  def test_a_machine_is_on_a_platform
    assert_raises(Erx::Error) { Erx::ProductionImage::Machine.development(VIRT).with(platform: VIRT.record) }
  end

  def test_qemu_takes_the_machine_line_from_the_platform
    assert_equal 'virt-11.1,gic-version=3', Erx::QemuPlan.machine_line(VIRT, accel: 'hvf', deterministic: false)
    assert_equal 'virt-11.1,gic-version=3,msi=gicv2m,dtb-randomness=off',
                 Erx::QemuPlan.machine_line(VIRT, accel: 'tcg', deterministic: true)
    other = Data.define(:name).new(name: 'qemu-virt')
    assert_raises(Erx::Error) { Erx::QemuPlan.machine_line(other, accel: 'tcg', deterministic: false) }
  end

  def test_a_board_qemu_has_no_machine_for_is_refused
    board = Erx::Platform.new(name: 'no-such-board', record: record(name: 'no-such-board'))
    assert_match(/no machine for platform no-such-board/,
                 assert_raises(Erx::Error) { Erx::QemuPlan.machine_line(board, accel: 'tcg', deterministic: false) }.message)
  end

  # The seeded fault the device tree check exists for: a record whose RAM base is not the
  # tree's is refused, as is a tree with no memory node to hold it to.
  def test_a_ram_base_the_tree_does_not_give_is_named
    assert_empty Erx::ProductionImage.device_path_problems(record(units: []), MEMORY_TREE)
    assert_equal ["ram_first 0 differs from the tree's RAM base 0x40000000"],
                 Erx::ProductionImage.device_path_problems(record(ram_first: 0, units: []), MEMORY_TREE)
    assert_equal ['the device tree has no memory node with a readable reg'],
                 Erx::ProductionImage.device_path_problems(record(units: []), MEMORY_TREE.sub('memory@40000000', 'ram@40000000'))
  end
end
