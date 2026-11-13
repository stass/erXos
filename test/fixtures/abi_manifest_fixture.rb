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
    bytes = "\0".b * (696 + text.bytesize)
    integer(bytes, 0, 0x4d585245)
    integer(bytes, 4, 1, width: 2)
    integer(bytes, 6, 3, width: 2)
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 12, 400)
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
    span(bytes, 208, 400, 1)
    span(bytes, 216, 480, 0)
    span(bytes, 224, 480, 1)
    span(bytes, 232, 640, 1)
    (240..352).step(8) { |offset| span(bytes, offset, 696, 0) }
    span(bytes, 360, 696, text.bytesize)
    span(bytes, 376, 480, 0)
    span(bytes, 384, 696, 0)
    span(bytes, 392, 696, 0)
    span(bytes, 400, 18, 4)
    integer(bytes, 408, 268_435_456, width: 8)
    share(bytes, 416, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 464, 4)
    integer(bytes, 468, 4)
    span(bytes, 480, 22, 6)
    integer(bytes, 488, 16_777_216, width: 8)
    integer(bytes, 496, 1_048_576, width: 8)
    share(bytes, 504, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 600, 4096)
    integer(bytes, 624, 4096, width: 8)
    integer(bytes, 632, 4096, width: 8)
    span(bytes, 640, 28, 6)
    integer(bytes, 648, 4096)
    integer(bytes, 652, 8192)
    integer(bytes, 656, 64)
    integer(bytes, 660, 64)
    integer(bytes, 680, 1024)
    integer(bytes, 684, 64)
    bytes[696, text.bytesize] = text
    bytes
  end

  # Byte offsets of erx_mf_session's fields in abi/manifest.txt.
  SESSION_FIELDS = { principal: 0, limits: 4, runtime: 8, release: 12, release_files: 16, reserved: 20 }.freeze

  # erx_mf_device's size in abi/manifest.txt.
  DEVICE_ROW = 88

  def unit_partition(overlap: false, orphan: false)
    original = valid
    units = orphan ? 1 : 2
    device_offset = 696 + units * 24
    strings_offset = device_offset + 2 * DEVICE_ROW
    text = original.byteslice(696..-1) + (orphan ? 'unit0' : 'unit0unit1')
    bytes = original.byteslice(0, 696) + "\0".b * (strings_offset - 696) + text
    integer(bytes, 8, bytes.bytesize)
    span(bytes, 248, 696, units)
    span(bytes, 256, device_offset, 2)
    [*(264..352).step(8), 384, 392].each { |offset| span(bytes, offset, strings_offset, 0) }
    span(bytes, 360, strings_offset, text.bytesize)
    units.times do |index|
      base = 696 + index * 24
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
    # Header400, principal80, domain64, limits160, runtime-limits56,
    # service24, facet80, parameter32, then strings.
    span(facet, 16, 864, 0)
    span(facet, 24, 864, 1)
    parameter = "\0".b * 32
    integer(parameter, 4, kind)
    integer(parameter, 8, scalar, width: 8)
    span(parameter, 16, 34, text.bytesize) unless text.empty?
    integer(parameter, 24, index)
    strings = original.byteslice(696..-1) + text
    bytes = original.byteslice(0, 480) + domain + original.byteslice(480, 216) + service + facet + parameter + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, 1, width: 2)
    span(bytes, 216, 480, 1)
    span(bytes, 224, 544, 1)
    span(bytes, 232, 704, 1)
    (240..264).step(8) { |offset| span(bytes, offset, 760, 0) }
    span(bytes, 272, 760, 1)
    span(bytes, 280, 784, 1)
    span(bytes, 288, 864, 0)
    span(bytes, 296, 864, 1)
    (304..352).step(8) { |offset| span(bytes, offset, 896, 0) }
    span(bytes, 360, 896, strings.bytesize)
    span(bytes, 376, 544, 0)
    span(bytes, 384, 896, 0)
    span(bytes, 392, 896, 0)
    bytes
  end

  # The valid fixture plus one session record; every field index is 0 and
  # args and env are empty. Header400, principal80, sessions40, limits160,
  # runtime-limits56, then strings.
  def session_template(**fields)
    original = valid
    session = "\0".b * 40
    fields.each { |name, value| integer(session, SESSION_FIELDS.fetch(name), value) }
    strings = original.byteslice(696..-1)
    bytes = original.byteslice(0, 480) + session + original.byteslice(480, 216) + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, 1, width: 2)
    span(bytes, 224, 520, 1)
    span(bytes, 232, 680, 1)
    (240..352).step(8) { |offset| span(bytes, offset, 736, 0) }
    span(bytes, 360, 736, strings.bytesize)
    span(bytes, 376, 480, 1)
    span(bytes, 384, 736, 0)
    span(bytes, 392, 736, 0)
    bytes
  end

  # Byte offsets of erx_mf_start's fields in abi/manifest.txt, and its size.
  START_FIELDS = { principal: 0, flags: 4, display: 8, restarts: 12, restart_period_s: 16, reserved: 20 }.freeze
  START_ROW = 24

  # The valid fixture as a development manifest plus count start rows, each
  # enabled, of principal 0, with no display and 5 restarts in 600 s, and fields
  # overriding the first row. Header400, principal80, limits160,
  # runtime-limits56, the start rows, then strings.
  def start_rows(count: 1, partial: false, **fields)
    original = valid
    rows = Array.new(count) do |index|
      row = "\0".b * START_ROW
      { flags: 1, display: 0xffffffff, restarts: 5, restart_period_s: 600 }
        .merge(index.zero? ? fields : {})
        .each { |name, value| integer(row, START_FIELDS.fetch(name), value) }
      row
    end.join
    strings_offset = 696 + rows.bytesize
    strings = original.byteslice(696..-1)
    bytes = original.byteslice(0, 696) + rows + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, partial ? 3 : 1, width: 2)
    span(bytes, 360, strings_offset, strings.bytesize)
    span(bytes, 384, 696, count)
    span(bytes, 392, strings_offset, 0)
    bytes
  end
end
