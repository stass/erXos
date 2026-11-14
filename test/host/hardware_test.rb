# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require_relative '../../tools/lib/erx/hardware'
require_relative '../fixtures/sanitizer_environment'

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
    assert_equal [0, 4, 0x18, 0x20, 0x24, 0x28, 0x2c, 0x30, 0x34, 0x38, 0x3c, 0x40, 0x44, 0x48], device.registers.map(&:offset)
    assert_equal 0x200, device.size
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
                 @source.sub('<width>32</width>', '<width>24</width>'),
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

  # CMDTM's fields as the SD Host Controller Specification lays them out (HC 2.2.6,
  # p.45-47), written here rather than read from the SVD, so a field the source moves
  # fails the check. check/0 answers ok, or each fact with what the header gave instead.
  CMDTM_CHECK = <<~ERLANG
    -module(cmdtm_check).
    -export([check/0]).
    -include("generated/erx_hw_sdhci.hrl").

    check() ->
        Facts = [{shift, 24, ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_SHIFT},
                 {width, 6, ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_WIDTH},
                 {mask, 16#3f000000, ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_MASK},
                 {put, 16#11000000, index(17)},
                 {get, 17, ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_GET(16#d1000000)},
                 {response, 16#20000, ?ERX_HW_SDHCI_CMDTM_CMD_RESP_PUT(?ERX_HW_SDHCI_CMDTM_CMD_RESP_BITS48)},
                 {busy, 3, ?ERX_HW_SDHCI_CMDTM_CMD_RESP_BITS48_BUSY},
                 {data, 16#200000, ?ERX_HW_SDHCI_CMDTM_CMD_DATA_MASK},
                 {too_large, 64, refused(64)}, {negative, -1, refused(-1)}, {atom, one, refused(one)},
                 {fits, [true, false, false], [fits(63), fits(64), fits(-1)]}],
        case [Fact || {_, Expected, Actual} = Fact <- Facts, Expected =/= Actual] of
            [] -> ok;
            Wrong -> {wrong, Wrong}
        end.

    index(Value) -> ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_PUT(Value).

    refused(Value) ->
        try index(Value) of
            _ -> accepted
        catch
            error:{badfield, {sdhci, cmdtm, cmd_index}, Refused} -> Refused
        end.

    fits(Value) when ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_FITS(Value) -> true;
    fits(_) -> false.
  ERLANG

  def test_erlang_fields_match_the_specification
    assert_equal 'ok', cmdtm_check(File.binread(File.join(@repository, 'hw/svd/sdhci/sdhci.svd')))
  end

  # The seeded fault: CMD_INDEX one bit higher in the source, which the generator accepts
  # (bits 30 and 31 are free) and the check must refuse.
  def test_erlang_field_check_catches_a_field_shifted_by_one
    source = File.binread(File.join(@repository, 'hw/svd/sdhci/sdhci.svd'))
    shifted = source.sub(%r{(<name>CMD_INDEX</name>.*?<bitOffset>)24(</bitOffset>)}, '\125\2')
    refute_equal source, shifted
    assert_includes cmdtm_check(shifted), '{shift,24,25}'
  end

  # An enumerated value named for one of a field's macros would define that macro twice.
  def test_erlang_names_cannot_collide
    collide = @source.sub(%r{(<name>DATA</name>.*?</bitWidth>)},
                          '\1<enumeratedValues><enumeratedValue><name>MASK</name><value>1</value>' \
                          '</enumeratedValue></enumeratedValues>')
    refute_equal @source, collide
    assert_raises(Erx::Error) { Erx::Hardware.parse_svd(collide) }
  end

  # A transport, as one cluster, and a kind that copies it and adds its own narrow registers:
  # the shape of hw/svd/virtio_mmio/virtio_mmio.svd, small enough to break one rule at a time.
  KINDS = <<~SVD
    <?xml version="1.0" encoding="UTF-8"?>
    <device schemaVersion="1.3">
      <name>T</name><version>1</version><description>t</description>
      <addressUnitBits>8</addressUnitBits><width>32</width>
      <peripherals>
        <peripheral>
          <name>BASE</name><baseAddress>0</baseAddress>
          <addressBlock><offset>0</offset><size>0x20</size><usage>registers</usage></addressBlock>
          <registers>
            <cluster><name>TRANSPORT</name><description>shared</description><addressOffset>0</addressOffset>
              <register><name>MAGIC</name><ownedByNif>false</ownedByNif><addressOffset>0</addressOffset><access>read-only</access>
                <fields><field><name>VALUE</name><bitOffset>0</bitOffset><bitWidth>32</bitWidth></field></fields></register>
              <register><name>STATUS</name><ownedByNif>true</ownedByNif><addressOffset>4</addressOffset><access>read-write</access>
                <fields><field><name>VALUE</name><bitOffset>0</bitOffset><bitWidth>32</bitWidth></field></fields></register>
            </cluster>
          </registers>
        </peripheral>
        <peripheral>
          <name>KIND</name><baseAddress>0</baseAddress>
          <addressBlock><offset>0</offset><size>0x20</size><usage>registers</usage></addressBlock>
          <registers>
            <cluster derivedFrom="BASE.TRANSPORT"><name>TRANSPORT</name><description>shared</description><addressOffset>0</addressOffset></cluster>
            <register><name>SELECT</name><ownedByNif>false</ownedByNif><size>8</size><addressOffset>0x10</addressOffset><access>read-write</access>
              <fields><field><name>VALUE</name><bitOffset>0</bitOffset><bitWidth>8</bitWidth></field></fields></register>
            <register><name>SIZE</name><ownedByNif>false</ownedByNif><size>8</size><addressOffset>0x11</addressOffset><access>read-only</access>
              <fields><field><name>VALUE</name><bitOffset>0</bitOffset><bitWidth>8</bitWidth></field></fields></register>
            <register><name>STEP</name><ownedByNif>false</ownedByNif><size>16</size><addressOffset>0x12</addressOffset><access>read-write</access>
              <fields><field><name>VALUE</name><bitOffset>0</bitOffset><bitWidth>16</bitWidth></field></fields></register>
            <register><name>LIMIT</name><ownedByNif>false</ownedByNif><addressOffset>0x14</addressOffset><access>read-only</access>
              <fields><field><name>VALUE</name><bitOffset>0</bitOffset><bitWidth>32</bitWidth></field></fields></register>
          </registers>
        </peripheral>
      </peripherals>
    </device>
  SVD

  def test_a_kind_copies_the_transport_cluster_and_adds_registers_of_their_own_width
    base, kind = Erx::Hardware.parse_peripherals(KINDS)
    assert_equal %w[MAGIC STATUS], base.registers.map(&:name)
    assert_nil base.derived_from
    assert_equal %w[MAGIC STATUS SELECT SIZE STEP LIMIT], kind.registers.map(&:name)
    assert_equal base.registers, kind.registers.first(2)
    assert_equal [32, 32, 8, 8, 16, 32], kind.registers.map(&:width)
    assert_equal 'BASE', kind.derived_from
    table = Erx::Hardware.device_table_header([base, kind])
    assert_match(/\.name = "select", \.writable = UINT8_C\(0xff\), \.offset = 16,.*\.width = 8,/, table)
    assert_match(/\.name = "kind", .*\.derived_from = "base"/, table)
    assert_match(/\.name = "base", .*\.derived_from = NULL/, table)
    access = Erx::Hardware.device_access_header
    %w[load8 store8 load16 store16 load32 load64].each { |name| assert_includes access, "erx_device_access_#{name}(" }
    assert_raises(Erx::Error) { Erx::Hardware.parse_svd(KINDS) }
  end

  # Each rule of the profile's derivation and widths, broken once.
  def test_a_derivation_or_a_narrow_register_outside_the_profile_is_refused
    derived = '<cluster derivedFrom="BASE.TRANSPORT"><name>TRANSPORT</name><description>shared</description>' \
              '<addressOffset>0</addressOffset></cluster>'
    select = '<size>8</size><addressOffset>0x10</addressOffset>'
    # The last match: KIND's element, where the first would be BASE's.
    last = ->(text, old, new) { text.sub(/\A(.*)#{Regexp.escape(old)}/m) { "#{Regexp.last_match(1)}#{new}" } }
    # KIND with nothing but its copy of the cluster, in a block too small for the copy.
    copy_only = last.call(KINDS.sub(%r{\s*<register><name>SELECT.*</register>}m, ''), '<size>0x20</size>', '<size>0x4</size>')
    extra = '<register><name>EXTRA</name><ownedByNif>true</ownedByNif><addressOffset>8</addressOffset>' \
            '<access>read-write</access><fields><field><name>VALUE</name><bitOffset>0</bitOffset>' \
            '<bitWidth>32</bitWidth></field></fields></register>'
    {
      KINDS.sub('derivedFrom="BASE.TRANSPORT"', 'derivedFrom="NONE.TRANSPORT"') => /no earlier peripheral/,
      KINDS.sub('derivedFrom="BASE.TRANSPORT"', 'derivedFrom="BASE.OTHER"') => /no leading cluster/,
      KINDS.sub('derivedFrom="BASE.TRANSPORT"', 'derivedFrom="TRANSPORT"') => /no earlier peripheral/,
      KINDS.sub('derivedFrom="BASE.TRANSPORT"', 'derivedFrom="KIND.TRANSPORT"') => /no earlier peripheral/,
      last.call(KINDS.sub("#{derived}\n", ''), '</registers>', "#{derived}</registers>") => /first element/,
      KINDS.sub('<addressOffset>0</addressOffset></cluster>', '<addressOffset>8</addressOffset></cluster>') => /no leading cluster/,
      KINDS.sub('</addressOffset></cluster>', '</addressOffset><register/></cluster>') => /unsupported SVD element/,
      KINDS.sub(%r{</cluster>(\s*</registers>)}) { "</cluster>#{extra}#{Regexp.last_match(1)}" } => /whole table/,
      copy_only => /outside its aligned block/,
      KINDS.sub(select, '<size>8</size><addressOffset>0x4</addressOffset>') => /overlap/,
      KINDS.sub('<size>16</size><addressOffset>0x12</addressOffset>', '<size>16</size><addressOffset>0x13</addressOffset>') => /aligned block/,
      KINDS.sub(select, '<size>24</size><addressOffset>0x10</addressOffset>') => /8, 16, 32 or 64/,
      KINDS.sub('<bitWidth>8</bitWidth>', '<bitWidth>9</bitWidth>') => /exceeds its width/
    }.each_with_index do |(bytes, reason), index|
      refute_equal KINDS, bytes, "case #{index} changed nothing"
      error = assert_raises(Erx::Error, "case #{index}") { Erx::Hardware.parse_peripherals(bytes) }
      assert_match reason, error.message, "case #{index}"
    end
  end

  def test_narrow_accessors_compile_and_touch_only_their_bytes
    FileUtils.mkdir_p(File.join(@root, 'hw/svd/kinds'))
    File.binwrite(File.join(@root, 'hw/svd/kinds/kinds.svd'), KINDS)
    Erx::Hardware.output_plan(root: @root).each do |relative, bytes|
      FileUtils.mkdir_p(File.dirname(File.join(@root, relative)))
      File.binwrite(File.join(@root, relative), bytes)
    end
    source = File.join(@root, 'narrow.c')
    File.binwrite(source, <<~C)
      #include "erx/hw/kind.h"
      #include "erx/hw/device_access.h"
      #include <assert.h>
      int main(void)
      {
      \t_Alignas(8) uint8_t registers[0x20] = {0};
      \terx_mmio_t device = {registers, sizeof(registers)};
      \tuint8_t size = 0;
      \tuint16_t step = 0;
      \tregisters[0x11] = 0x14;
      \tassert(erx_kind_select_write(device, UINT8_C(0x12)));
      \tassert(registers[0x10] == 0x12 && registers[0x11] == 0x14 && registers[0x0f] == 0);
      \tassert(erx_kind_size_read(device, &size) && size == 0x14);
      \tassert(erx_kind_step_write(device, UINT16_C(0xbeef)));
      \tassert(erx_kind_step_read(device, &step) && step == 0xbeef && registers[0x11] == 0x14);
      \terx_device_access_store8(registers, 0x13, 0x7f);
      \tassert(erx_device_access_load8(registers, 0x13) == 0x7f && erx_device_access_load8(registers, 0x12) == 0xef);
      \terx_device_access_store16(registers, 0x12, 0x1234);
      \tassert(erx_device_access_load16(registers, 0x12) == 0x1234 && registers[0x11] == 0x14);
      \tdevice.length = 0x11;
      \tassert(!erx_kind_size_read(device, &size));
      \treturn (0);
      }
    C
    runner = Erx::Runner.new(owner_root: @root, log_dir: File.join(@root, 'logs'))
    program = File.join(@root, 'narrow')
    runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                '-fsanitize=address,undefined', '-I', File.join(@root, 'include'), source,
                '-o', program], name: 'compile-narrow', deadline: 60)
    assert_equal 'succeeded', runner.run([program], name: 'narrow-accessors', deadline: 30).fetch('state')
  end

  def test_generated_accessors_compile_and_preserve_neighbor_bits
    Erx::Hardware.output_plan(root: @root).each do |relative, bytes|
      FileUtils.mkdir_p(File.dirname(File.join(@root, relative)))
      File.binwrite(File.join(@root, relative), bytes)
    end
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

  private

  # What CMDTM_CHECK returns against the Erlang header generated from svd, compiled with
  # warnings as errors on stock's emulator (ERX_ERLC and ERX_ERL, which make check
  # supplies): 'ok', or the error it failed with.
  def cmdtm_check(svd)
    FileUtils.mkdir_p(File.join(@root, 'hw/svd/sdhci'))
    File.binwrite(File.join(@root, 'hw/svd/sdhci/sdhci.svd'), svd)
    include_dir = File.join(@root, 'erlang/apps/erx/include')
    Erx::Hardware.output_plan(root: @root).each do |relative, bytes|
      FileUtils.mkdir_p(File.dirname(File.join(@root, relative)))
      File.binwrite(File.join(@root, relative), bytes)
    end
    File.binwrite(File.join(@root, 'cmdtm_check.erl'), CMDTM_CHECK)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', include_dir, '-o', @root,
                                     File.join(@root, 'cmdtm_check.erl'), stdin_data: '')
    assert status.success?, output
    output, status = Open3.capture2e(ENV.fetch('ERX_ERL'), '-noshell', '-pa', @root, '-eval',
                                     'io:format("~p", [cmdtm_check:check()]), halt().',
                                     chdir: @root, stdin_data: '')
    assert status.success?, output
    output
  end
end
