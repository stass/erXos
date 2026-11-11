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
    bytes = "\0".b * (680 + text.bytesize)
    integer(bytes, 0, 0x4d585245)
    integer(bytes, 4, 1, width: 2)
    integer(bytes, 6, 3, width: 2)
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 12, 384)
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
    span(bytes, 208, 384, 1)
    span(bytes, 216, 464, 0)
    span(bytes, 224, 464, 1)
    span(bytes, 232, 624, 1)
    (240..352).step(8) { |offset| span(bytes, offset, 680, 0) }
    span(bytes, 360, 680, text.bytesize)
    span(bytes, 376, 464, 0)
    span(bytes, 384, 18, 4)
    integer(bytes, 392, 268_435_456, width: 8)
    share(bytes, 400, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 448, 4)
    integer(bytes, 452, 4)
    span(bytes, 464, 22, 6)
    integer(bytes, 472, 16_777_216, width: 8)
    integer(bytes, 480, 1_048_576, width: 8)
    share(bytes, 488, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 584, 4096)
    integer(bytes, 608, 4096, width: 8)
    integer(bytes, 616, 4096, width: 8)
    span(bytes, 624, 28, 6)
    integer(bytes, 632, 4096)
    integer(bytes, 636, 8192)
    integer(bytes, 640, 64)
    integer(bytes, 644, 64)
    integer(bytes, 664, 1024)
    integer(bytes, 668, 64)
    integer(bytes, 680, 64)
    bytes[680, text.bytesize] = text
    bytes
  end

  # Byte offsets of erx_mf_session's fields in abi/manifest.txt.
  SESSION_FIELDS = { principal: 0, limits: 4, runtime: 8, release: 12, release_files: 16, reserved: 20 }.freeze

  # erx_mf_device's size in abi/manifest.txt.
  DEVICE_ROW = 80

  def unit_partition(overlap: false, orphan: false)
    original = valid
    units = orphan ? 1 : 2
    device_offset = 680 + units * 24
    strings_offset = device_offset + 2 * DEVICE_ROW
    text = original.byteslice(680..-1) + (orphan ? 'unit0' : 'unit0unit1')
    bytes = original.byteslice(0, 680) + "\0".b * (strings_offset - 680) + text
    integer(bytes, 8, bytes.bytesize)
    span(bytes, 248, 680, units)
    span(bytes, 256, device_offset, 2)
    (264..352).step(8) { |offset| span(bytes, offset, strings_offset, 0) }
    span(bytes, 360, strings_offset, text.bytesize)
    units.times do |index|
      base = 680 + index * 24
      span(bytes, base, 34 + index * 5, 5)
      integer(bytes, base + 8, 0xffffffff)
      first = overlap ? device_offset : device_offset + index * DEVICE_ROW
      span(bytes, base + 12, first, 1)
    end
    2.times do |index|
      base = device_offset + index * DEVICE_ROW
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
    integer(domain, 44, 10) # boot_timeout_s, which the reader takes from 1
    service = "\0".b * 24
    span(service, 0, 18, 4)
    integer(service, 8, 0xffffffff)
    facet = "\0".b * 80
    span(facet, 0, 18, 4)
    # Header384, principal80, domain64, limits160, runtime-limits56,
    # service24, facet80, parameter32, then strings.
    span(facet, 16, 848, 0)
    span(facet, 24, 848, 1)
    parameter = "\0".b * 32
    integer(parameter, 4, kind)
    integer(parameter, 8, scalar, width: 8)
    span(parameter, 16, 34, text.bytesize) unless text.empty?
    integer(parameter, 24, index)
    strings = original.byteslice(680..-1) + text
    bytes = original.byteslice(0, 464) + domain + original.byteslice(464, 216) + service + facet + parameter + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, 1, width: 2)
    span(bytes, 216, 464, 1)
    span(bytes, 224, 528, 1)
    span(bytes, 232, 688, 1)
    (240..264).step(8) { |offset| span(bytes, offset, 744, 0) }
    span(bytes, 272, 744, 1)
    span(bytes, 280, 768, 1)
    span(bytes, 288, 848, 0)
    span(bytes, 296, 848, 1)
    (304..352).step(8) { |offset| span(bytes, offset, 880, 0) }
    span(bytes, 360, 880, strings.bytesize)
    span(bytes, 376, 528, 0)
    bytes
  end

  # The valid fixture plus one session record; every field index is 0 and
  # args and env are empty. Header384, principal80, sessions40, limits160,
  # runtime-limits56, then strings.
  def session_template(**fields)
    original = valid
    session = "\0".b * 40
    fields.each { |name, value| integer(session, SESSION_FIELDS.fetch(name), value) }
    strings = original.byteslice(680..-1)
    bytes = original.byteslice(0, 464) + session + original.byteslice(464, 216) + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, 1, width: 2)
    span(bytes, 224, 504, 1)
    span(bytes, 232, 664, 1)
    (240..352).step(8) { |offset| span(bytes, offset, 720, 0) }
    span(bytes, 360, 720, strings.bytesize)
    span(bytes, 376, 464, 1)
    bytes
  end
end
