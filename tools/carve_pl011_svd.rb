#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Carves hw/svd/pl011/pl011.svd out of the Raspberry Pi Pico SDK's rp2040.svd.
#
#   ruby tools/carve_pl011_svd.rb RP2040_SVD OUTPUT_SVD
#
# RP2040_SVD is pico-sdk 1.5.1's src/rp2040/hardware_regs/rp2040.svd; the
# script refuses any other bytes. Only the UART0 peripheral is read, and the
# edits listed in hw/svd/pl011/ORIGIN.md are the ones made below;
# the deliberate departures from the Arm manual are the constants at the top.

require 'digest'
require 'rexml/document'
require_relative 'lib/erx/error'

module Erx
  module CarvePl011
    SOURCE_SHA256 = '5a046202808f07c660ade1a4b38ad31d10309ec1abbafea4a0342fc538f626c8'

    # The only deliberate departures from the Pico SDK's description of UART0, all
    # from Arm DDI 0183G: a read of DR pops the receive FIFO; ICR is written and
    # never read; and any write to RSR clears all four of its errors, so they are
    # not one-to-clear bits and RSR itself stays read-write (it shares an offset
    # with the write-only ECR, which the profile cannot express).
    READ_ACTIONS = { 'UARTDR' => 'modify' }.freeze
    WRITE_ONLY = %w[UARTICR].freeze
    READ_ONLY_FIELDS = %w[UARTRSR].freeze

    HEAD = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!-- Copyright (c) 2020 Raspberry Pi (Trading) Ltd.

           SPDX-License-Identifier: BSD-3-Clause

           The UART0 peripheral of the Raspberry Pi Pico SDK 1.5.1 rp2040.svd,
           carved out and adapted by erXos as ORIGIN.md beside it lists. The RP2040
           carries an Arm PrimeCell UART PL011, so the layout is the PL011's; it was
           also compared with Arm DDI 0183G (PrimeCell UART PL011 r1p5 Technical
           Reference Manual), sections 3.2 and 3.3. The manual is not redistributable
           and is not in the tree. -->
      <device schemaVersion="1.3">
        <name>PL011</name><version>1</version>
        <description>PrimeCell UART register interface</description>
        <addressUnitBits>8</addressUnitBits><width>32</width>
        <peripherals>
          <peripheral>
            <name>PL011</name><baseAddress>0</baseAddress>
            <addressBlock><offset>0</offset><size>0x1000</size><usage>registers</usage></addressBlock>
            <registers>
    XML
    TAIL = <<~XML
            </registers>
          </peripheral>
        </peripherals>
      </device>
    XML

    Field = Data.define(:name, :description, :offset, :width, :access, :clear)
    Register = Data.define(:name, :description, :offset, :access, :read_action, :fields)

    module_function

    def call(source_bytes)
      unless Digest::SHA256.hexdigest(source_bytes) == SOURCE_SHA256
        raise Error, 'rp2040.svd is not the pinned pico-sdk 1.5.1 file'
      end

      HEAD + uart0(source_bytes).map { |register| render(register) }.join + TAIL
    end

    def uart0(source_bytes)
      root = REXML::Document.new(source_bytes).root
      peripherals = root.get_elements('peripherals/peripheral').select { |node| node.elements['name'].text == 'UART0' }
      raise Error, 'rp2040.svd has no single UART0' unless peripherals.size == 1

      peripherals.first.get_elements('registers/register').map { |node| register(node) }
    end

    def register(node)
      name = node.elements['name'].text
      fields = node.get_elements('fields/field').map { |field| field(field, name) }
      Register.new(name: strip_prefix(name), description: text(node, 'description'),
                   offset: node.elements['addressOffset'].text.then { |value| Integer(value, 16) },
                   access: register_access(name, fields), read_action: READ_ACTIONS[name], fields: fields)
    end

    # The Pico SDK states access on fields only; the profile wants it on the
    # register too, so it is the weakest access that admits every field.
    def register_access(name, fields)
      return 'write-only' if WRITE_ONLY.include?(name)
      return 'read-write' if READ_ONLY_FIELDS.include?(name)

      fields.all? { |field| field.access == 'read-only' } ? 'read-only' : 'read-write'
    end

    # The register name loses the Pico SDK's `UART` prefix. A field keeps its name.
    def strip_prefix(name) = name.delete_prefix('UART')

    # The Pico SDK writes `[hi:lo]`; the profile wants an offset and a width.
    def field(node, register_name)
      high, low = node.elements['bitRange'].text.match(/\A\[(\d+):(\d+)\]\z/).captures.map { |bit| Integer(bit) }
      access = field_access(node, register_name)
      Field.new(name: node.elements['name'].text, description: text(node, 'description'), offset: low,
                width: high - low + 1, access: access,
                clear: !READ_ONLY_FIELDS.include?(register_name) && node.elements['modifiedWriteValues']&.text == 'oneToClear')
    end

    def field_access(node, register_name)
      return 'write-only' if WRITE_ONLY.include?(register_name)
      return 'read-only' if READ_ONLY_FIELDS.include?(register_name)

      node.elements['access'].text
    end

    def text(node, name) = node.elements[name].text.to_s.gsub(/\s+/, ' ').strip

    def render(register)
      read_action = register.read_action ? "<readAction>#{register.read_action}</readAction>" : ''
      lines = ['<register>',
               "  <name>#{register.name}</name><holdsDeviceAddress>false</holdsDeviceAddress>",
               "  <description>#{escape(register.description)}</description>",
               "  <addressOffset>0x#{register.offset.to_s(16)}</addressOffset><access>#{register.access}</access>#{read_action}",
               '  <fields>',
               *register.fields.sort_by(&:offset).map { |field| "    #{render_field(field)}" },
               '  </fields>',
               '</register>']
      lines.map { |line| "        #{line}\n" }.join
    end

    def render_field(field)
      clear = field.clear ? '<modifiedWriteValues>oneToClear</modifiedWriteValues>' : ''
      "<field><name>#{field.name}</name><description>#{escape(field.description)}</description>" \
        "<bitOffset>#{field.offset}</bitOffset><bitWidth>#{field.width}</bitWidth>" \
        "<access>#{field.access}</access>#{clear}</field>"
    end

    def escape(value) = value.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
  end
end

if $PROGRAM_NAME == __FILE__
  source, output = ARGV
  abort 'usage: carve_pl011_svd.rb RP2040_SVD OUTPUT_SVD' unless source && output
  File.binwrite(output, Erx::CarvePl011.call(File.binread(source, 64 * 1024 * 1024)))
end
