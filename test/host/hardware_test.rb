# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/hardware'

class HardwareTest < Minitest::Test
  def setup
    @repository = File.expand_path('../..', __dir__)
    @source = File.binread(File.join(@repository, 'hw/svd/pl011/pl011.svd'))
    @root = Dir.mktmpdir('erx-hardware-')
    FileUtils.mkdir_p(File.join(@root, 'hw/svd/pl011'))
    File.binwrite(File.join(@root, 'hw/svd/pl011/pl011.svd'), @source)
  end

  def teardown
    FileUtils.remove_entry(@root) if passed?
  end

  def test_register_facts_and_side_effects
    device = Erx::Hardware.parse_svd(@source)
    assert_equal [0, 4, 0x18, 0x20, 0x24, 0x28, 0x2c, 0x30, 0x34, 0x38, 0x3c, 0x40, 0x44, 0x48,
                  0xfe0, 0xfe4, 0xfe8, 0xfec, 0xff0, 0xff4, 0xff8, 0xffc], device.registers.map(&:offset)
    assert_equal [32], device.registers.map(&:width).uniq
    assert_equal 'modify', device.registers.first.read_action
    icr = device.registers.find { |register| register.name == 'ICR' }
    assert_equal 'write-only', icr.access
    assert icr.fields.all?(&:clear)
    output = Erx::Hardware.device_header(device)
    assert_includes output, 'erx_pl011_icr_rtic_clear'
    refute_includes output, 'erx_pl011_icr_read'
    refute_includes output, 'erx_pl011_icr_rtic_set'
    refute_includes output, 'erx_pl011_dr_modify'
  end

  def test_rsr_is_written_whole_and_its_errors_are_not_one_to_clear
    rsr = Erx::Hardware.parse_svd(@source).registers.find { |register| register.name == 'RSR' }
    assert_equal 'read-write', rsr.access
    assert_equal %w[FE PE BE OE], rsr.fields.map(&:name)
    assert rsr.fields.none?(&:clear)
    assert rsr.fields.all? { |field| field.access == 'read-only' }
    assert_equal 0, Erx::Hardware.writable_mask(rsr)
    refute Erx::Hardware.plain_update?(rsr)
    assert_match(/\.name = "rsr", .*\.plain_update = false/, Erx::Hardware.device_table_header([Erx::Hardware.parse_svd(@source)]))
  end

  def test_xml_and_semantic_rejections
    malformed = [@source + '<device/>', @source.sub('<device schemaVersion="1.3">',
                 '<!DOCTYPE device [<!ENTITY x "boom">]><device schemaVersion="1.3">'),
                 @source.sub('<width>32</width>', '<width>16</width>'),
                 @source.sub('<addressOffset>0x18</addressOffset>', '<addressOffset>2</addressOffset>'),
                 @source.sub('<bitWidth>8</bitWidth>', '<bitWidth>33</bitWidth>'),
                 @source.sub('<name>PL011</name>', '<name derivedFrom="other">PL011</name>'),
                 @source.sub('<name>PL011</name>', '<name>PL011<hidden/></name>'),
                 @source.sub('oneToClear', 'zeroToToggle'), "\xff".b]
    malformed.each { |bytes| assert_raises(Erx::Error) { Erx::Hardware.parse_svd(bytes) } }
  end

  def test_a_register_without_its_owned_mark_is_refused
    missing = @source.sub('<ownedByNif>false</ownedByNif>', '')
    error = assert_raises(Erx::Error) { Erx::Hardware.parse_svd(missing) }
    assert_match(/ownedByNif/, error.message)
    assert_raises(Erx::Error) { Erx::Hardware.parse_svd(@source.sub('<ownedByNif>false<', '<ownedByNif>maybe<')) }
    refute(Erx::Hardware.parse_svd(@source).registers.any?(&:owned_by_nif))
    marked = @source.sub('<ownedByNif>false<', '<ownedByNif>true<')
    assert_includes Erx::Hardware.device_table_header([Erx::Hardware.parse_svd(marked)]), '.owned_by_nif = true'
  end

  def test_a_register_array_is_checked_whole
    array = lambda do |dim, stride, name: 'FR[%s]'|
      @source.sub('<name>FR</name>', "<name>#{name}</name><dim>#{dim}</dim><dimIncrement>#{stride}</dimIncrement>")
    end
    fr = Erx::Hardware.parse_svd(array.call(2, 4)).registers.find { |register| register.name == 'FR' }
    assert_equal [2, 4], [fr.count, fr.stride]
    assert_includes Erx::Hardware.device_header(Erx::Hardware.parse_svd(array.call(2, 4))), 'erx_pl011_fr_read(erx_mmio_t device, uint32_t index,'
    # No wider than its stride, no element past its neighbour or the block, and a name that says it is an array.
    [array.call(2, 2), array.call(4, 4), array.call(2, 4, name: 'FR'), array.call(0, 4), array.call(1, 4), array.call(1000, 4),
     array.call(2, 0x1000), @source.sub('<name>FR</name>', '<name>FR</name><dimIncrement>4</dimIncrement>')].each { |bytes| assert_raises(Erx::Error) { Erx::Hardware.parse_svd(bytes) } }
  end

  def test_the_device_table_says_what_a_register_allows
    table = Erx::Hardware.device_table_header([Erx::Hardware.parse_svd(@source)])
    assert_match(/\.name = "imsc", \.writable = UINT32_C\(0x7ff\), \.offset = 56,.*\.plain_update = true/, table)
    assert_match(/\.name = "dr", \.writable = UINT32_C\(0xff\),.*\.plain_update = false/, table)
    assert_match(/\.name = "icr", .*\.access = ERX_DEVICE_WRITE_ONLY,.*\.plain_update = false/, table)
    assert_match(/\.name = "rtic", \.mask = UINT32_C\(0x40\), \.shift = 6, .*\.clear = true/, table)
    assert table.ascii_only?
  end

  def test_a_peripheral_cannot_take_a_device_table_header_name
    File.binwrite(File.join(@root, 'hw/svd/pl011/pl011.svd'), @source.gsub('PL011', 'DEVICE_TABLE'))
    assert_raises(Erx::Error) { Erx::Hardware.output_plan(root: @root) }
  end

  def test_foreign_or_malformed_xml_encodings_are_typed_rejections
    ['{TF-8', 'ISO-8859-1', 'UTF-16'].each do |encoding|
      assert_raises(Erx::Error) { Erx::Hardware.parse_svd(@source.sub('UTF-8', encoding)) }
    end
  end

  def test_drift_missing_modified_and_orphaned_outputs
    plan = Erx::Hardware.output_plan(root: @root)
    assert_raises(Erx::Error) { Erx::Hardware.check_outputs(plan, root: @root) }
    Erx::Hardware.publish_outputs(plan, root: @root)
    assert Erx::Hardware.check_outputs(plan, root: @root)
    File.binwrite(File.join(@root, 'include/erx/hw/orphan.h'), 'orphan')
    assert_raises(Erx::Error) { Erx::Hardware.check_outputs(plan, root: @root) }
    Erx::Hardware.publish_outputs(plan, root: @root)
    assert Erx::Hardware.check_outputs(plan, root: @root)
    File.binwrite(File.join(@root, 'include/erx/mmio.h'), 'modified')
    assert_raises(Erx::Error) { Erx::Hardware.check_outputs(plan, root: @root) }
  end

  def test_unpublishable_name_is_rejected_before_any_output
    source = @source.sub('<name>PL011</name><baseAddress>', "<name>#{'A' * 256}</name><baseAddress>")
    File.binwrite(File.join(@root, 'hw/svd/pl011/pl011.svd'), source)
    assert_raises(Erx::Error) { Erx::Hardware.output_plan(root: @root) }
    refute File.exist?(File.join(@root, 'include/erx/mmio.h'))
  end

  def test_combined_device_namespace_cannot_collide
    [['A_B', 'C'], ['A', 'B_C']].each_with_index do |(device, register), index|
      source = @source.sub('<name>PL011</name><baseAddress>', "<name>#{device}</name><baseAddress>")
                      .sub('<name>DR</name>', "<name>#{register}</name>")
      File.binwrite(File.join(@root, "hw/svd/device-#{index}.svd"), source)
    end
    assert_raises(Erx::Error) { Erx::Hardware.output_plan(root: @root) }
  end

  def test_invalid_output_inventory_is_rejected_before_publication
    plan = Erx::Hardware.output_plan(root: @root)
    FileUtils.mkdir_p(File.join(@root, 'include/erx/hw/unexpected'))
    target = File.join(@root, 'include/erx/mmio.h')
    File.binwrite(target, 'original output')
    assert_raises(Erx::Error) { Erx::Hardware.publish_outputs(plan, root: @root) }
    assert_equal 'original output', File.binread(target)
    refute File.exist?(File.join(@root, 'include/erx/hw/pl011.h'))
  end

  def test_generated_accessors_compile_and_preserve_neighbor_bits
    plan = Erx::Hardware.output_plan(root: @root)
    Erx::Hardware.publish_outputs(plan, root: @root)
    source = File.join(@root, 'accessors.c')
    File.binwrite(source, <<~C)
      #include "erx/hw/pl011.h"
      #include <assert.h>
      int main(void)
      {
      \t_Alignas(8) uint32_t registers[1024] = {0};
      \terx_mmio_t device = {(volatile uint8_t *)registers, sizeof(registers)};
      \tuint32_t value = 0;
      \tassert(erx_pl011_dr_data_set(UINT32_C(0xab00), UINT32_C(0x55), &value));
      \tassert(value == UINT32_C(0xab55));
      \tassert(!erx_pl011_dr_data_set(0, UINT32_C(0x100), &value));
      \tassert(erx_pl011_dr_write(device, UINT32_C(0x42)));
      \tassert(registers[0] == UINT32_C(0x42));
      \tassert(!erx_pl011_dr_write(device, UINT32_C(0x100)));
      \tregisters[6] = UINT32_C(0x90);
      \tassert(erx_pl011_fr_read(device, &value));
      \tassert(erx_pl011_fr_rxfe_get(value) == 1);
      \tassert(erx_pl011_fr_txfe_get(value) == 1);
      \tassert(erx_pl011_icr_rtic_clear(device, UINT32_C(1)));
      \tassert(registers[17] == UINT32_C(0x40));
      \tdevice.length = 4;
      \tassert(!erx_pl011_fr_read(device, &value));
      \tdevice.base += 1;
      \tassert(!erx_pl011_dr_read(device, &value));
      \treturn (0);
      }
    C
    runner = Erx::Runner.new(owner_root: @root, log_dir: File.join(@root, 'logs'))
    program = File.join(@root, 'accessors')
    runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                '-fsanitize=address,undefined', '-I', File.join(@root, 'include'), source,
                '-o', program], name: 'compile-hardware', deadline: 60)
    result = runner.run([program], name: 'hardware-accessors', deadline: 30)
    assert_equal 'succeeded', result.fetch('state')
  end
end
