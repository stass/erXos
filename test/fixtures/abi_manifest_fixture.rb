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
    bytes = "\0".b * (688 + text.bytesize)
    integer(bytes, 0, 0x4d585245)
    integer(bytes, 4, 1, width: 2)
    integer(bytes, 6, 3, width: 2)
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 12, 392)
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
    span(bytes, 208, 392, 1)
    span(bytes, 216, 472, 0)
    span(bytes, 224, 472, 1)
    span(bytes, 232, 632, 1)
    (240..352).step(8) { |offset| span(bytes, offset, 688, 0) }
    span(bytes, 360, 688, text.bytesize)
    span(bytes, 376, 472, 0)
    span(bytes, 384, 688, 0)
    span(bytes, 392, 18, 4)
    integer(bytes, 400, 268_435_456, width: 8)
    share(bytes, 408, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 456, 4)
    integer(bytes, 460, 4)
    span(bytes, 472, 22, 6)
    integer(bytes, 480, 16_777_216, width: 8)
    integer(bytes, 488, 1_048_576, width: 8)
    share(bytes, 496, quota: 8_000_000, capacity: 800, base: 16, ceiling: 31)
    integer(bytes, 592, 4096)
    integer(bytes, 616, 4096, width: 8)
    integer(bytes, 624, 4096, width: 8)
    span(bytes, 632, 28, 6)
    integer(bytes, 640, 4096)
    integer(bytes, 644, 8192)
    integer(bytes, 648, 64)
    integer(bytes, 652, 64)
    integer(bytes, 672, 1024)
    integer(bytes, 676, 64)
    bytes[688, text.bytesize] = text
    bytes
  end

  # Byte offsets of erx_mf_session's fields in abi/manifest.txt.
  SESSION_FIELDS = { principal: 0, limits: 4, runtime: 8, release: 12, release_files: 16, reserved: 20 }.freeze

  # erx_mf_device's size in abi/manifest.txt.
  DEVICE_ROW = 88

  def unit_partition(overlap: false, orphan: false)
    original = valid
    units = orphan ? 1 : 2
    device_offset = 688 + units * 24
    strings_offset = device_offset + 2 * DEVICE_ROW
    text = original.byteslice(688..-1) + (orphan ? 'unit0' : 'unit0unit1')
    bytes = original.byteslice(0, 688) + "\0".b * (strings_offset - 688) + text
    integer(bytes, 8, bytes.bytesize)
    span(bytes, 248, 688, units)
    span(bytes, 256, device_offset, 2)
    [*(264..352).step(8), 384].each { |offset| span(bytes, offset, strings_offset, 0) }
    span(bytes, 360, strings_offset, text.bytesize)
    units.times do |index|
      base = 688 + index * 24
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
    # Header392, principal80, domain64, limits160, runtime-limits56,
    # service24, facet80, parameter32, then strings.
    span(facet, 16, 856, 0)
    span(facet, 24, 856, 1)
    parameter = "\0".b * 32
    integer(parameter, 4, kind)
    integer(parameter, 8, scalar, width: 8)
    span(parameter, 16, 34, text.bytesize) unless text.empty?
    integer(parameter, 24, index)
    strings = original.byteslice(688..-1) + text
    bytes = original.byteslice(0, 472) + domain + original.byteslice(472, 216) + service + facet + parameter + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, 1, width: 2)
    span(bytes, 216, 472, 1)
    span(bytes, 224, 536, 1)
    span(bytes, 232, 696, 1)
    (240..264).step(8) { |offset| span(bytes, offset, 752, 0) }
    span(bytes, 272, 752, 1)
    span(bytes, 280, 776, 1)
    span(bytes, 288, 856, 0)
    span(bytes, 296, 856, 1)
    (304..352).step(8) { |offset| span(bytes, offset, 888, 0) }
    span(bytes, 360, 888, strings.bytesize)
    span(bytes, 376, 536, 0)
    span(bytes, 384, 888, 0)
    bytes
  end

  # The valid fixture plus one session record; every field index is 0 and
  # args and env are empty. Header392, principal80, sessions40, limits160,
  # runtime-limits56, then strings.
  def session_template(**fields)
    original = valid
    session = "\0".b * 40
    fields.each { |name, value| integer(session, SESSION_FIELDS.fetch(name), value) }
    strings = original.byteslice(688..-1)
    bytes = original.byteslice(0, 472) + session + original.byteslice(472, 216) + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, 1, width: 2)
    span(bytes, 224, 512, 1)
    span(bytes, 232, 672, 1)
    (240..352).step(8) { |offset| span(bytes, offset, 728, 0) }
    span(bytes, 360, 728, strings.bytesize)
    span(bytes, 376, 472, 1)
    span(bytes, 384, 728, 0)
    bytes
  end

  # Byte offsets of erx_mf_start's fields in abi/manifest.txt, and its size.
  START_FIELDS = { principal: 0, flags: 4, display: 8, restarts: 12, restart_period_s: 16, reserved: 20 }.freeze
  START_ROW = 24

  # The valid fixture as a development manifest plus count start rows, each
  # enabled, of principal 0, with no display and 5 restarts in 600 s, and fields
  # overriding the first row. Header392, principal80, limits160,
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
    strings_offset = 688 + rows.bytesize
    strings = original.byteslice(688..-1)
    bytes = original.byteslice(0, 688) + rows + strings
    integer(bytes, 8, bytes.bytesize)
    integer(bytes, 6, partial ? 3 : 1, width: 2)
    span(bytes, 360, strings_offset, strings.bytesize)
    span(bytes, 384, 688, count)
    bytes
  end
end
