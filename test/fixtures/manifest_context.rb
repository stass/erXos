# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Unit tests supply the checked-boundary facts below explicitly. Real pack
# integration obtains its image facts from erx_elf_plan and provenance receipts.
module ManifestContextFixture
  module_function

  # The release image the development manifest names, as ReleaseMedium.image describes
  # a built one: two blocks at the slot's images start.
  def images
    { 'release' => { 'kind' => 'erofs_image', 'extents' => [{ 'slot_offset' => 128 << 20, 'length' => 8192 }] } }
  end

  def platform
    { 'name' => 'fixture', 'cpuset' => 1, 'console' => '/uart@0', 'hostlink' => '',
      'units' => [{ 'key' => 'uart0', 'devices' => [
        { 'selector' => 'dt', 'role' => 'uart', 'path' => '/uart@0', 'bridge' => '',
          'compatible' => 'arm,pl011', 'bus' => 0, 'device' => 0, 'function' => 0,
          'dma' => 'none', 'flags' => 0, 'dma_memory' => 0, 'placement_key' => 'uart0',
          'base' => 0, 'size' => 4096, 'line' => 33 }
      ] }] }
  end

  def image(codec)
    { 'magic' => codec.constant('image_magic'), 'version' => codec.constant('image_version'),
      'abi_version' => codec.abi_version, 'flags' => codec.member('image_flags', 'fixed'),
      'span' => 4096, 'fixed_base' => 65536, 'entry' => 0, 'phdr_offset' => 0,
      'phnum' => 1, 'base_alignment' => 4096,
      'segments' => [{ 'file_offset' => 4096, 'mem_offset' => 0, 'file_size' => 64,
                       'mem_size' => 64, 'prot' => codec.member('prot', 'rx'), 'flags' => 0 }] }
  end

  def arguments(codec)
    system = codec.member('entry_flags', 'system')
    ordinary = codec.member('entry_kind', 'file')
    { build_kind: 'development', platform: platform, root_entry: 2,
      artifacts: { 'root' => { 'kind' => 'executable', 'entry' => 2 } }.merge(images),
      catalog: [
        { 'path' => 'system/NOTICES', 'kind' => ordinary, 'flags' => system,
          'source' => { 'kind' => 'generated', 'producer' => 'notices' } },
        { 'path' => 'system/manifest', 'kind' => ordinary, 'flags' => system,
          'source' => { 'kind' => 'generated', 'producer' => 'manifest' } },
        { 'path' => 'system/root', 'kind' => codec.member('entry_kind', 'image'), 'flags' => system,
          'source' => { 'kind' => 'artifact', 'id' => 'root', 'sha256' => 'a' * 64 },
          'image' => image(codec) }
      ],
      provenance: [{ 'path' => 'fixture/root.c', 'sha256' => 'a' * 64,
                     'license' => 'BSD-2-Clause', 'evidence' => 'fixture',
                     'status' => 'permanent', 'notice' => "original\xffnotice".b }] }
  end
end
