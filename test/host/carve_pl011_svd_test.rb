# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rexml/document'
require_relative '../../tools/carve_pl011_svd'

# The carve reads one pinned upstream file; any other bytes are refused before a
# register is read. The carved result is checked by hardware_test.rb through the
# generator, and the upstream file itself is not in the tree.
class CarvePl011SvdTest < Minitest::Test
  def test_other_bytes_are_refused
    ['', '<device/>', "<device>#{'x' * 100}</device>"].each do |bytes|
      error = assert_raises(Erx::Error) { Erx::CarvePl011.call(bytes) }
      assert_match(/not the pinned pico-sdk 1.5.1 file/, error.message)
    end
  end

  # A register of the upstream file, in the form it has there: access on the
  # fields only, with one-to-clear fields where the Pico SDK declares them.
  def upstream_register(name, offset, fields)
    field_xml = fields.map do |field, bits, access, clear|
      "<field><name>#{field}</name><description>d</description><bitRange>#{bits}</bitRange>" \
        "<access>#{access}</access>#{clear ? '<modifiedWriteValues>oneToClear</modifiedWriteValues>' : ''}</field>"
    end
    REXML::Document.new("<register><name>#{name}</name><description>d</description>" \
                        "<addressOffset>#{offset}</addressOffset><fields>#{field_xml.join}</fields></register>").root
  end

  # Any write to RSR clears all four errors (Arm DDI 0183G, 3-7), so the carve
  # makes its fields read-only whatever the upstream says, and keeps the register
  # read-write for the ECR that shares its offset.
  def test_rsr_fields_are_read_only_and_not_one_to_clear
    rsr = Erx::CarvePl011.register(upstream_register('UARTRSR', '0x4', [['FE', '[0:0]', 'read-write', true],
      ['PE', '[1:1]', 'read-write', true], ['BE', '[2:2]', 'read-write', true], ['OE', '[3:3]', 'read-write', true]]))
    assert_equal 'RSR', rsr.name
    assert_equal 'read-write', rsr.access
    assert_equal %w[read-only] * 4, rsr.fields.map(&:access)
    assert_equal [false] * 4, rsr.fields.map(&:clear)
    refute_includes Erx::CarvePl011.render(rsr), 'modifiedWriteValues'
  end

  # ICR is written and never read; its one-to-clear fields stay what they are.
  def test_icr_is_write_only
    icr = Erx::CarvePl011.register(upstream_register('UARTICR', '0x44', [['RTIC', '[6:6]', 'read-write', true],
      ['FEIC', '[7:7]', 'read-write', true]]))
    assert_equal 'write-only', icr.access
    assert_equal %w[write-only] * 2, icr.fields.map(&:access)
    assert_equal [true, true], icr.fields.map(&:clear)
  end

  # A read of DR pops the receive FIFO, and its fields are the upstream's.
  def test_dr_read_modifies
    dr = Erx::CarvePl011.register(upstream_register('UARTDR', '0x0', [['DATA', '[7:0]', 'read-write', false],
      ['OE', '[11:11]', 'read-only', false]]))
    assert_equal 'modify', dr.read_action
    assert_equal 'read-write', dr.access
    assert_equal %w[read-write read-only], dr.fields.map(&:access)
    assert_includes Erx::CarvePl011.render(dr), '<readAction>modify</readAction>'
  end

  def test_register_names_lose_the_prefix
    assert_equal 'LCR_H', Erx::CarvePl011.strip_prefix('UARTLCR_H')
    assert_equal 'PERIPHID0', Erx::CarvePl011.strip_prefix('UARTPERIPHID0')
  end
end
