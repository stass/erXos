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

  # A development manifest's text with two configured domains of the domain
  # release app and the runtime emu (domain_arguments), alpha and beta, beta started
  # by the rescue configuration; a service alpha serves, their introduction and the
  # data window held by alpha. The system principal's quota covers them, and
  # max_domains is that quota.
  def domain_source(plain)
    domain = lambda do |name, flags|
      "domain #{name}\n  principal @principal.system\n  limits @limits.app\n  kind service\n  flags #{flags}\n" \
        "  runtime @artifact.emu\n  release @artifact.app\n  restarts 3\n  restart_period_s 5\n  args \"-x y\"\n"
    end
    plain.sub("  domains 0\n", "  domains 2\n").sub('max_domains 0', 'max_domains 2')
         .sub("window data\n  holder system", "window data\n  holder @domain.alpha") +
      "limits app\n  memory 4194304\n  outer 1048576\n  grant @share.users\n  spaces none\n  lane 4096\n" \
      "  connections 2\n  crash 0\n  flags none\n  runtime_limits @runtime_limits.system\n" \
      "  peer_held 4096\n  peer_held_total 4096\n" + domain.call('alpha', 'required') + domain.call('beta', 'rescue') +
      "service log\n  server @domain.alpha\n  interface 1\nintroduce @domain.alpha @domain.beta\n"
  end

  # A planner that plans every configured domain and introduction, for checks that
  # test the rest.
  def accepting_planner = ->(view) { view.slice('domains', 'introductions').transform_values { |rows| rows.map { 0 } } }

  # The same pack with a domain release, app, of two files under domains/app/ and the
  # domain runtime image, runtimes/emu, as ProductionImage.artifacts names them: the
  # archive's paths sort domains/ first, then runtimes/, then system/.
  def domain_arguments(codec)
    base = arguments(codec)
    file = codec.member('entry_kind', 'file')
    added = [
      { 'path' => 'domains/app/bin/start.boot', 'kind' => file, 'flags' => 0,
        'source' => { 'kind' => 'artifact', 'id' => 'app-boot', 'sha256' => 'b' * 64 } },
      { 'path' => 'domains/app/lib/kernel.beam', 'kind' => file, 'flags' => 0,
        'source' => { 'kind' => 'artifact', 'id' => 'app-kernel', 'sha256' => 'c' * 64 } },
      { 'path' => 'runtimes/emu', 'kind' => codec.member('entry_kind', 'image'), 'flags' => 0,
        'source' => { 'kind' => 'artifact', 'id' => 'domain-runtime', 'sha256' => 'd' * 64 }, 'image' => image(codec) }
    ]
    root = added.size + base.fetch(:root_entry)
    base.merge(catalog: added + base.fetch(:catalog), root_entry: root,
               artifacts: { 'root' => { 'kind' => 'executable', 'entry' => root },
                            'emu' => { 'kind' => 'executable', 'entry' => 2 },
                            'app' => { 'kind' => 'release', 'entry' => 0, 'files' => 2 } }.merge(images))
  end
end
