# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Unit tests supply the checked-boundary facts below explicitly. Real pack
# integration obtains its image facts from erx_elf_plan and provenance receipts.
require 'digest'

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

  # The archive the development manifest names, as both packs carry it: the session
  # release its session template names, of one file under domains/session/, the domain
  # runtime image, runtimes/emu, and the system release's generated files and root.
  def arguments(codec) = archive_arguments(codec, releases: { 'session' => %w[bin/start.boot] })

  # The same archive with the domain release app, of two files under domains/app/,
  # which domain_source's domains name.
  def domain_arguments(codec)
    archive_arguments(codec, releases: { 'app' => %w[bin/start.boot lib/kernel.beam], 'session' => %w[bin/start.boot] })
  end

  # An archive of releases (name => files) under domains/, then runtimes/emu, then
  # system/, the order the archive's sorted paths take, with its artifacts named as
  # ProductionImage.artifacts names them.
  def archive_arguments(codec, releases:)
    system = codec.member('entry_flags', 'system')
    ordinary = codec.member('entry_kind', 'file')
    executable = codec.member('entry_kind', 'image')
    domains = releases.flat_map do |name, files|
      files.map do |file|
        path = "domains/#{name}/#{file}"
        { 'path' => path, 'kind' => ordinary, 'flags' => 0,
          'source' => { 'kind' => 'artifact', 'id' => path, 'sha256' => Digest::SHA256.hexdigest(path) } }
      end
    end
    catalog = [
      *domains,
      { 'path' => 'runtimes/emu', 'kind' => executable, 'flags' => 0,
        'source' => { 'kind' => 'artifact', 'id' => 'domain-runtime', 'sha256' => 'd' * 64 }, 'image' => image(codec) },
      { 'path' => 'system/NOTICES', 'kind' => ordinary, 'flags' => system,
        'source' => { 'kind' => 'generated', 'producer' => 'notices' } },
      { 'path' => 'system/manifest', 'kind' => ordinary, 'flags' => system,
        'source' => { 'kind' => 'generated', 'producer' => 'manifest' } },
      { 'path' => 'system/root', 'kind' => executable, 'flags' => system,
        'source' => { 'kind' => 'artifact', 'id' => 'root', 'sha256' => 'a' * 64 },
        'image' => image(codec) }
    ]
    paths = catalog.map { |row| row.fetch('path') }
    runs = releases.to_h do |name, files|
      [name, { 'kind' => 'release', 'entry' => paths.index { |path| path.start_with?("domains/#{name}/") }, 'files' => files.size }]
    end
    root = paths.index('system/root')
    { build_kind: 'development', platform: platform, root_entry: root,
      artifacts: { 'root' => { 'kind' => 'executable', 'entry' => root },
                   'emu' => { 'kind' => 'executable', 'entry' => paths.index('runtimes/emu') } }.merge(runs, images),
      catalog: catalog,
      provenance: [{ 'path' => 'fixture/root.c', 'sha256' => 'a' * 64,
                     'license' => 'BSD-2-Clause', 'evidence' => 'fixture',
                     'status' => 'permanent', 'notice' => "original\xffnotice".b }] }
  end

  # The development manifest's text with two configured domains of the domain
  # release app and the runtime emu (domain_arguments), alpha and beta, beta started
  # by the rescue configuration; a service alpha serves, their introduction and the
  # data window held by alpha. The manifest's own session template stays. The system
  # principal's quota covers the domains and one session, and max_domains is that quota.
  def domain_source(plain)
    domain = lambda do |name, flags|
      "domain #{name}\n  principal @principal.system\n  limits @limits.app\n  kind service\n  flags #{flags}\n" \
        "  runtime @artifact.emu\n  release @artifact.app\n  restarts 3\n  restart_period_s 5\n  args \"-x y\"\n"
    end
    app = "limits app\n  memory 4194304\n  outer 1048576\n  grant @share.users\n  spaces none\n  lane 4096\n" \
          "  connections 2\n  crash 0\n  flags none\n  runtime_limits @runtime_limits.system\n" \
          "  peer_held 4096\n  peer_held_total 4096\n"
    with_quota(plain, 3).sub("window data\n  holder system", "window data\n  holder @domain.alpha") +
      app + domain.call('alpha', 'required') + domain.call('beta', 'rescue') +
      "service log\n  server @domain.alpha\n  interface 1\nintroduce @domain.alpha @domain.beta\n"
  end

  # The system principal's session template, its domain quota and max_domains in
  # the development manifest.
  SESSION_TEMPLATE = /^session system\n(?:  .*\n)*/
  SYSTEM_QUOTA = /^(principal system\n(?:  .*\n)*?  domains )\d+$/
  MAX_DOMAINS = /^(  max_domains )\d+$/

  # The development manifest as the domain tests start from it: without its session
  # template, since they write their own, and with no domain quota or max_domains,
  # since they set what their rows need.
  def sessionless(source) = with_quota(substitute(source, SESSION_TEMPLATE, ''), 0)

  # source with the system principal's domain quota and max_domains both quota.
  def with_quota(source, quota) = substitute(substitute(source, SYSTEM_QUOTA, "\\1#{quota}"), MAX_DOMAINS, "\\1#{quota}")

  # source with pattern's first match replaced. A pattern that no longer matches the
  # manifest raises, so a test built on it fails rather than testing the manifest
  # unchanged.
  def substitute(source, pattern, replacement)
    raise ArgumentError, "the manifest has no match for #{pattern.inspect}" unless source.match?(pattern)

    source.sub(pattern, replacement)
  end

  # A planner that plans every configured domain and introduction, for checks that
  # test the rest.
  def accepting_planner = ->(view) { { 'domains' => view.fetch('order').map { 0 }, 'introductions' => view.fetch('introductions').map { 0 } } }
end
