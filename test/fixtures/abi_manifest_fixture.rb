# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Independent byte oracle: offsets and encodings come from the published
# format, not the generator's model or encoder. The fixture is structurally
# complete; these bytes make no claim that its resource policy is admitted.
module AbiManifestFixture
  module_function

  def integer(bytes, offset, value, width: 4)
    format = { 2 => 'v', 4 => 'V', 8 => 'Q<' }.fetch(width)
    bytes[offset, width] = [value].pack(format)
  end

  def span(bytes, offset, first, count)
    bytes[offset, 8] = [first, count].pack('V2')
  end

  def share(bytes, offset, quota:, capacity:, base:, ceiling:)
    bytes[offset, 48] = [quota, 10_000_000, 1, capacity, 0,
                        1000, 5, base, ceiling, 0, 0].pack('Q<3V4CCvV')
  end

  def valid
    text = 'node/uart@0fixturerootnativenative'.b
    bytes = "\0".b * (664 + text.bytesize)
    integer(bytes, 0, 0x4d585245)
    integer(bytes, 4, 1, width: 2)
    integer(bytes, 6, 3, width: 2)
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 12, 368)
    span(bytes, 16, 0, 4)
    span(bytes, 24, 4, 7)
    span(bytes, 32, 11, 0)
    span(bytes, 40, 11, 7)
    integer(bytes, 48, 1_073_741_824, width: 8)
    integer(bytes, 56, 67_108_864, width: 8)
    share(bytes, 72, quota: 2_000_000, capacity: 200, base: 24, ceiling: 47)
    share(bytes, 120, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 172, 4)
    integer(bytes, 176, 4)
    integer(bytes, 180, 4096)
    integer(bytes, 184, 16384)
    integer(bytes, 188, 4096)
    integer(bytes, 192, 250)
    span(bytes, 208, 368, 1)
    span(bytes, 216, 448, 0)
    span(bytes, 224, 448, 1)
    span(bytes, 232, 608, 1)
    (240..352).step(8) { |offset| span(bytes, offset, 664, 0) }
    span(bytes, 360, 664, text.bytesize)
    span(bytes, 368, 18, 4)
    integer(bytes, 376, 268_435_456, width: 8)
    share(bytes, 384, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 432, 4)
    integer(bytes, 436, 4)
    span(bytes, 448, 22, 6)
    integer(bytes, 456, 16_777_216, width: 8)
    integer(bytes, 464, 1_048_576, width: 8)
    share(bytes, 472, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 568, 4096)
    integer(bytes, 592, 4096, width: 8)
    integer(bytes, 600, 4096, width: 8)
    span(bytes, 608, 28, 6)
    integer(bytes, 616, 4096)
    integer(bytes, 620, 8192)
    integer(bytes, 624, 64)
    integer(bytes, 628, 64)
    integer(bytes, 648, 1024)
    integer(bytes, 652, 64)
    integer(bytes, 656, 64)
    bytes[664, text.bytesize] = text
    bytes
  end

  def unit_partition(overlap: false, orphan: false)
    original = valid
    units = orphan ? 1 : 2
    device_offset = 664 + units * 24
    strings_offset = device_offset + 2 * 64
    text = original.byteslice(664..-1) + (orphan ? 'unit0' : 'unit0unit1')
    bytes = original.byteslice(0, 664) + "\0".b * (strings_offset - 664) + text
    integer(bytes, 8, bytes.bytesize)
    span(bytes, 248, 664, units)
    span(bytes, 256, device_offset, 2)
    (264..352).step(8) { |offset| span(bytes, offset, strings_offset, 0) }
    span(bytes, 360, strings_offset, text.bytesize)
    units.times do |index|
      base = 664 + index * 24
      span(bytes, base, 34 + index * 5, 5)
      integer(bytes, base + 8, 0xffffffff)
      first = overlap ? device_offset : device_offset + index * 64
      span(bytes, base + 12, first, 1)
    end
    2.times do |index|
      base = device_offset + index * 64
      integer(bytes, base, 1)
      integer(bytes, base + 4, 2)
      span(bytes, base + 8, 4, 7)
      span(bytes, base + 16, 0, 0)
      span(bytes, base + 24, 11, 7)
      span(bytes, base + 56, 0, 4)
    end
    bytes
  end

  def facet_parameter(kind: 3, scalar: 1, index: 0, text: '')
    original = valid
    domain = "\0".b * 64
    span(domain, 0, 18, 4)
    integer(domain, 12, 2)
    service = "\0".b * 24
    span(service, 0, 18, 4)
    integer(service, 8, 0xffffffff)
    facet = "\0".b * 80
    span(facet, 0, 18, 4)
    # Header368, principal80, domain64, limits160, runtime-limits56,
    # service24, facet80, parameter32, then strings.
    span(facet, 16, 832, 0)
    span(facet, 24, 832, 1)
    parameter = "\0".b * 32
    integer(parameter, 4, kind)
    integer(parameter, 8, scalar, width: 8)
    span(parameter, 16, 34, text.bytesize) unless text.empty?
    integer(parameter, 24, index)
    strings = original.byteslice(664..-1) + text
    bytes = original.byteslice(0, 448) + domain + original.byteslice(448, 216) + service + facet + parameter + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, 1, width: 2)
    span(bytes, 216, 448, 1)
    span(bytes, 224, 512, 1)
    span(bytes, 232, 672, 1)
    (240..264).step(8) { |offset| span(bytes, offset, 728, 0) }
    span(bytes, 272, 728, 1)
    span(bytes, 280, 752, 1)
    span(bytes, 288, 832, 0)
    span(bytes, 296, 832, 1)
    (304..352).step(8) { |offset| span(bytes, offset, 864, 0) }
    span(bytes, 360, 864, strings.bytesize)
    bytes
  end
end
