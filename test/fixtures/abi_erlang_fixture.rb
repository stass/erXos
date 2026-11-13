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
    strings = original.byteslice(696..-1).dup
    units_offset = 696
    devices_offset = units_offset + owners * 24
    strings_offset = devices_offset + devices * AbiManifestFixture::DEVICE_ROW
    body = original.byteslice(0, 696) + "\0".b * (strings_offset - 696)
    AbiManifestFixture.span(body, 248, units_offset, owners)
    AbiManifestFixture.span(body, 256, devices_offset, devices)
    [*(264..352).step(8), 384, 392].each { |offset| AbiManifestFixture.span(body, offset, strings_offset, 0) }
    owners.times do |index|
      offset = units_offset + index * 24
      name = "unit#{index}".b
      AbiManifestFixture.span(body, offset, strings.bytesize, name.bytesize)
      strings << name
      AbiManifestFixture.integer(body, offset + 8, 0xffffffff)
      AbiManifestFixture.span(body, offset + 12, devices_offset + index * AbiManifestFixture::DEVICE_ROW, 1)
    end
    devices.times do |index|
      offset = devices_offset + index * AbiManifestFixture::DEVICE_ROW
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
    strings = original.byteslice(696..-1) + 'clientserviceaccess'.b + text
    body = original.byteslice(0, 480) + "\0".b * 64 +
           original.byteslice(480, 216) + "\0".b * 136
    AbiManifestFixture.integer(body, 6, 1, width: 2)
    AbiManifestFixture.span(body, 216, 480, 1)
    AbiManifestFixture.span(body, 224, 544, 1)
    AbiManifestFixture.span(body, 232, 704, 1)
    (240..264).step(8) { |offset| AbiManifestFixture.span(body, offset, 760, 0) }
    AbiManifestFixture.span(body, 272, 760, 1)
    AbiManifestFixture.span(body, 280, 784, 1)
    AbiManifestFixture.span(body, 288, 864, 0)
    AbiManifestFixture.span(body, 296, 864, 1)
    (304..352).step(8) { |offset| AbiManifestFixture.span(body, offset, 896, 0) }
    AbiManifestFixture.span(body, 360, 896, strings.bytesize)
    AbiManifestFixture.span(body, 376, 544, 0)
    AbiManifestFixture.span(body, 384, 896, 0)
    AbiManifestFixture.span(body, 392, 896, 0)

    AbiManifestFixture.span(body, 480, 34, 6)
    AbiManifestFixture.integer(body, 492, 1)
    AbiManifestFixture.integer(body, 500, 2)
    AbiManifestFixture.integer(body, 504, 2)
    AbiManifestFixture.integer(body, 508, 1)
    AbiManifestFixture.integer(body, 524, 10) # the row's boot_timeout_s, from 1
    AbiManifestFixture.span(body, 528, 40, 0)
    AbiManifestFixture.span(body, 536, 40, 0)
    AbiManifestFixture.span(body, 760, 40, 7)
    AbiManifestFixture.integer(body, 772, 1)
    AbiManifestFixture.span(body, 784, 47, 6)
    AbiManifestFixture.span(body, 800, 864, 0)
    AbiManifestFixture.span(body, 808, 864, 1)
    AbiManifestFixture.integer(body, 816, 4096)
    AbiManifestFixture.integer(body, 820, 1)
    AbiManifestFixture.integer(body, 824, 1000, width: 8)
    AbiManifestFixture.integer(body, 832, 1_000_000, width: 8)
    AbiManifestFixture.integer(body, 840, 65_536, width: 8)
    AbiManifestFixture.integer(body, 848, 4096, width: 8)
    AbiManifestFixture.integer(body, 864, 1)
    AbiManifestFixture.integer(body, 868, kind)
    AbiManifestFixture.integer(body, 872, scalar, width: 8)
    AbiManifestFixture.span(body, 880, 53, text.bytesize) if [4, 5, 9].include?(kind)
    AbiManifestFixture.integer(body, 888, index)
    body << strings
    AbiManifestFixture.integer(body, 8, body.bytesize)
    body
  end
end
