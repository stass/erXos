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
    strings = original.byteslice(680..-1).dup
    units_offset = 680
    devices_offset = units_offset + owners * 24
    strings_offset = devices_offset + devices * AbiManifestFixture::DEVICE_ROW
    body = original.byteslice(0, 680) + "\0".b * (strings_offset - 680)
    AbiManifestFixture.span(body, 248, units_offset, owners)
    AbiManifestFixture.span(body, 256, devices_offset, devices)
    (264..352).step(8) { |offset| AbiManifestFixture.span(body, offset, strings_offset, 0) }
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
    strings = original.byteslice(680..-1) + 'clientserviceaccess'.b + text
    body = original.byteslice(0, 464) + "\0".b * 64 +
           original.byteslice(464, 216) + "\0".b * 136
    AbiManifestFixture.integer(body, 6, 1, width: 2)
    AbiManifestFixture.span(body, 216, 464, 1)
    AbiManifestFixture.span(body, 224, 528, 1)
    AbiManifestFixture.span(body, 232, 688, 1)
    (240..264).step(8) { |offset| AbiManifestFixture.span(body, offset, 744, 0) }
    AbiManifestFixture.span(body, 272, 744, 1)
    AbiManifestFixture.span(body, 280, 768, 1)
    AbiManifestFixture.span(body, 288, 848, 0)
    AbiManifestFixture.span(body, 296, 848, 1)
    (304..352).step(8) { |offset| AbiManifestFixture.span(body, offset, 880, 0) }
    AbiManifestFixture.span(body, 360, 880, strings.bytesize)
    AbiManifestFixture.span(body, 376, 528, 0)

    AbiManifestFixture.span(body, 464, 34, 6)
    AbiManifestFixture.integer(body, 476, 1)
    AbiManifestFixture.integer(body, 484, 2)
    AbiManifestFixture.integer(body, 488, 2)
    AbiManifestFixture.integer(body, 492, 1)
    AbiManifestFixture.integer(body, 508, 10) # the row's boot_timeout_s, from 1
    AbiManifestFixture.span(body, 512, 40, 0)
    AbiManifestFixture.span(body, 520, 40, 0)
    AbiManifestFixture.span(body, 744, 40, 7)
    AbiManifestFixture.integer(body, 756, 1)
    AbiManifestFixture.span(body, 768, 47, 6)
    AbiManifestFixture.span(body, 784, 848, 0)
    AbiManifestFixture.span(body, 792, 848, 1)
    AbiManifestFixture.integer(body, 800, 4096)
    AbiManifestFixture.integer(body, 804, 1)
    AbiManifestFixture.integer(body, 808, 1000, width: 8)
    AbiManifestFixture.integer(body, 816, 1_000_000, width: 8)
    AbiManifestFixture.integer(body, 824, 65_536, width: 8)
    AbiManifestFixture.integer(body, 832, 4096, width: 8)
    AbiManifestFixture.integer(body, 848, 1)
    AbiManifestFixture.integer(body, 852, kind)
    AbiManifestFixture.integer(body, 856, scalar, width: 8)
    AbiManifestFixture.span(body, 864, 53, text.bytesize) if [4, 5, 9].include?(kind)
    AbiManifestFixture.integer(body, 872, index)
    body << strings
    AbiManifestFixture.integer(body, 8, body.bytesize)
    body
  end
end
