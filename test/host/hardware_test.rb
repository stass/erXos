# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/hardware'

class HardwareTest < Minitest::Test
  def setup
    @repository = File.expand_path('../..', __dir__)
    @source = File.binread(File.join(@repository, 'hw/svd/pl011.svd'))
    @root = Dir.mktmpdir('erx-hardware-')
    FileUtils.mkdir_p(File.join(@root, 'hw/svd'))
    File.binwrite(File.join(@root, 'hw/svd/pl011.svd'), @source)
  end

  def teardown
    FileUtils.remove_entry(@root) if passed?
  end

  def test_register_facts_and_side_effects
    device = Erx::Hardware.parse_svd(@source)
    assert_equal [0, 0x18, 0x44], device.registers.map(&:offset)
    assert_equal [32, 32, 32], device.registers.map(&:width)
    assert_equal 'modify', device.registers.first.read_action
    assert device.registers.last.fields.first.clear
    output = Erx::Hardware.device_header(device)
    assert_includes output, 'erx_pl011_icr_irqs_clear'
    refute_includes output, 'erx_pl011_icr_read'
    refute_includes output, 'erx_pl011_icr_irqs_set'
    refute_includes output, 'erx_pl011_dr_modify'
  end

  def test_xml_and_semantic_rejections
    malformed = [@source + '<device/>', @source.sub('<device schemaVersion="1.3">',
                 '<!DOCTYPE device [<!ENTITY x "boom">]><device schemaVersion="1.3">'),
                 @source.sub('<width>32</width>', '<width>16</width>'),
                 @source.sub('<addressOffset>0x18</addressOffset>', '<addressOffset>2</addressOffset>'),
                 @source.sub('<bitWidth>11</bitWidth>', '<bitWidth>33</bitWidth>'),
                 @source.sub('<name>PL011</name>', '<name derivedFrom="other">PL011</name>'),
                 @source.sub('<name>PL011</name>', '<name>PL011<hidden/></name>'),
                 @source.sub('oneToClear', 'zeroToToggle'), "\xff".b]
    malformed.each { |bytes| assert_raises(Erx::Error) { Erx::Hardware.parse_svd(bytes) } }
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
    File.binwrite(File.join(@root, 'hw/svd/pl011.svd'), source)
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
      \tassert(erx_pl011_icr_irqs_clear(device, UINT32_C(0x40)));
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
