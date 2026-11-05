# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_manifest_fixture'

# Additional independent wire fixtures. These deliberately spell physical
# offsets from the format contract and do not use the production encoder.
module AbiErlangFixture
  module_function

  def devices(owners:, devices:)
    original = AbiManifestFixture.valid
    strings = original.byteslice(672..-1).dup
    units_offset = 672
    devices_offset = units_offset + owners * 24
    strings_offset = devices_offset + devices * 64
    body = original.byteslice(0, 672) + "\0".b * (strings_offset - 672)
    AbiManifestFixture.span(body, 248, units_offset, owners)
    AbiManifestFixture.span(body, 256, devices_offset, devices)
    (264..352).step(8) { |offset| AbiManifestFixture.span(body, offset, strings_offset, 0) }
    owners.times do |index|
      offset = units_offset + index * 24
      name = "unit#{index}".b
      AbiManifestFixture.span(body, offset, strings.bytesize, name.bytesize)
      strings << name
      AbiManifestFixture.integer(body, offset + 8, 0xffffffff)
      AbiManifestFixture.span(body, offset + 12, devices_offset + index * 64, 1)
    end
    devices.times do |index|
      offset = devices_offset + index * 64
      AbiManifestFixture.integer(body, offset, 1)
      AbiManifestFixture.integer(body, offset + 4, 2)
      path = "/uart@#{index}".b
      AbiManifestFixture.span(body, offset + 8, strings.bytesize, path.bytesize)
      strings << path
      AbiManifestFixture.span(body, offset + 16, 0, 0)
      compatible = 'arm,pl011'.b
      AbiManifestFixture.span(body, offset + 24, strings.bytesize, compatible.bytesize)
      strings << compatible
      key = "uart#{index}".b
      AbiManifestFixture.span(body, offset + 56, strings.bytesize, key.bytesize)
      strings << key
    end
    AbiManifestFixture.span(body, 360, strings_offset, strings.bytesize)
    body << strings
    AbiManifestFixture.integer(body, 8, body.bytesize)
    body
  end

  def parameter(kind:, scalar: 0, index: 0, text: ''.b)
    original = AbiManifestFixture.valid
    strings = original.byteslice(672..-1) + 'clientserviceaccess'.b + text
    body = original.byteslice(0, 456) + "\0".b * 64 +
           original.byteslice(456, 216) + "\0".b * 136
    AbiManifestFixture.integer(body, 6, 1, width: 2)
    AbiManifestFixture.span(body, 216, 456, 1)
    AbiManifestFixture.span(body, 224, 520, 1)
    AbiManifestFixture.span(body, 232, 680, 1)
    (240..264).step(8) { |offset| AbiManifestFixture.span(body, offset, 736, 0) }
    AbiManifestFixture.span(body, 272, 736, 1)
    AbiManifestFixture.span(body, 280, 760, 1)
    AbiManifestFixture.span(body, 288, 840, 0)
    AbiManifestFixture.span(body, 296, 840, 1)
    (304..352).step(8) { |offset| AbiManifestFixture.span(body, offset, 872, 0) }
    AbiManifestFixture.span(body, 360, 872, strings.bytesize)

    AbiManifestFixture.span(body, 456, 34, 6)
    AbiManifestFixture.integer(body, 468, 1)
    AbiManifestFixture.integer(body, 476, 2)
    AbiManifestFixture.integer(body, 480, 2)
    AbiManifestFixture.integer(body, 484, 1)
    AbiManifestFixture.span(body, 504, 40, 0)
    AbiManifestFixture.span(body, 512, 40, 0)
    AbiManifestFixture.span(body, 736, 40, 7)
    AbiManifestFixture.integer(body, 748, 1)
    AbiManifestFixture.span(body, 760, 47, 6)
    AbiManifestFixture.span(body, 776, 840, 0)
    AbiManifestFixture.span(body, 784, 840, 1)
    AbiManifestFixture.integer(body, 792, 4096)
    AbiManifestFixture.integer(body, 796, 1)
    AbiManifestFixture.integer(body, 800, 1000, width: 8)
    AbiManifestFixture.integer(body, 808, 1_000_000, width: 8)
    AbiManifestFixture.integer(body, 816, 65_536, width: 8)
    AbiManifestFixture.integer(body, 824, 4096, width: 8)
    AbiManifestFixture.integer(body, 840, 1)
    AbiManifestFixture.integer(body, 844, kind)
    AbiManifestFixture.integer(body, 848, scalar, width: 8)
    AbiManifestFixture.span(body, 856, 53, text.bytesize) if [4, 5, 9].include?(kind)
    AbiManifestFixture.integer(body, 864, index)
    body << strings
    AbiManifestFixture.integer(body, 8, body.bytesize)
    body
  end
end
