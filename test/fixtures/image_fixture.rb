# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../tools/lib/erx/abi'

# An image entry of the boot archive as the pack tool writes one
# (tools/lib/erx/pack_wire.rb, write_image): the erx_image_manifest page, a
# read-execute segment of one page, then a read-write segment of two pages
# whose first 16 bytes are stored. The codec encodes the manifest, as the pack
# tool's does; offsets name its fields, so a test can plant a bad value the
# codec would not encode.
module ImageFixture
  module_function

  PAGE = 4096
  FIXED_BASE = 0x40_0000
  ENTRY = 0x40
  # Byte offsets of the manifest's fields and of a segment's, from abi/erx_abi.txt.
  MAGIC = 0
  VERSION = 4
  NSEGMENTS = 6
  ABI_VERSION = 8
  SEGMENTS = 56
  SEGMENT_SIZE = 40
  FILE_OFFSET = 0
  MEM_OFFSET = 8
  FILE_SIZE = 16
  PROT = 32
  FIXED_BASE_FIELD = 24
  ENTRY_FIELD = 32

  ROOT = File.expand_path('../..', __dir__)

  def schema = (@schema ||= Erx::ABI::Generator.plan(root: ROOT).schema)
  def codec = (@codec ||= Erx::ABI::Codec.new(schema))

  def prot(name) = codec.member('prot', name)

  def segments
    [{ 'file_offset' => PAGE, 'mem_offset' => 0, 'file_size' => PAGE, 'mem_size' => PAGE, 'prot' => prot('rx'),
       'flags' => 0 },
     { 'file_offset' => 2 * PAGE, 'mem_offset' => PAGE, 'file_size' => 16, 'mem_size' => 2 * PAGE,
       'prot' => prot('rw'), 'flags' => 0 }]
  end

  def valid
    manifest = codec.encode_layout('erx_image_manifest',
                                   'magic' => codec.constant('image_magic'), 'version' => codec.constant('image_version'),
                                   'abi_version' => schema.version,
                                   'flags' => codec.member('image_flags', 'fixed'), 'span' => 3 * PAGE, 'fixed_base' => FIXED_BASE, 'entry' => ENTRY,
                                   'phdr_offset' => 64, 'phnum' => 2, 'base_alignment' => PAGE, 'segments' => segments)
    manifest.ljust(PAGE, "\0".b) + ("\xd5".b * PAGE) + ("\x5a".b * 16).ljust(PAGE, "\0".b)
  end

  # valid with one field set to value, little-endian over width bytes.
  def patch(offset, value, width:)
    format = { 2 => 'v', 4 => 'V', 8 => 'Q<' }.fetch(width)
    bytes = valid.dup
    bytes[offset, width] = [value].pack(format)
    bytes
  end

  def segment_field(index, field) = SEGMENTS + (index * SEGMENT_SIZE) + field
end
