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

  # The archive the development manifest names, as both packs carry it: the domain
  # release under domains/erxos/ with the session boot script its session template
  # names and the storage and network boot scripts its storage and network rows name, the
  # domain runtime images, runtimes/emu and runtimes/jit, and the system release's
  # generated files and root.
  def arguments(codec) = archive_arguments(codec, boots: %w[network session storage])

  # The same archive with the boot script app beside session, which domain_source's
  # domains name.
  def domain_arguments(codec) = archive_arguments(codec, boots: %w[app network session storage])

  # An archive of the domain release, with a boot script for each of boots and one
  # library file, then runtimes/emu, then system/, the order the archive's sorted paths
  # take, with its artifacts named as ProductionImage.artifacts names them: each boot
  # script names the release's whole run.
  def archive_arguments(codec, boots:)
    system = codec.member('entry_flags', 'system')
    ordinary = codec.member('entry_kind', 'file')
    executable = codec.member('entry_kind', 'image')
    domains = [*boots.sort.map { |name| "bin/#{name}.boot" }, 'lib/kernel.beam'].map do |file|
      path = "domains/erxos/#{file}"
      { 'path' => path, 'kind' => ordinary, 'flags' => 0,
        'source' => { 'kind' => 'artifact', 'id' => path, 'sha256' => Digest::SHA256.hexdigest(path) } }
    end
    catalog = [
      *domains,
      { 'path' => 'runtimes/emu', 'kind' => executable, 'flags' => 0,
        'source' => { 'kind' => 'artifact', 'id' => 'domain-runtime', 'sha256' => 'd' * 64 }, 'image' => image(codec) },
      { 'path' => 'runtimes/jit', 'kind' => executable, 'flags' => 0,
        'source' => { 'kind' => 'artifact', 'id' => 'jit-runtime', 'sha256' => 'e' * 64 }, 'image' => image(codec) },
      { 'path' => 'system/NOTICES', 'kind' => ordinary, 'flags' => system,
        'source' => { 'kind' => 'generated', 'producer' => 'notices' } },
      { 'path' => 'system/manifest', 'kind' => ordinary, 'flags' => system,
        'source' => { 'kind' => 'generated', 'producer' => 'manifest' } },
      { 'path' => 'system/root', 'kind' => executable, 'flags' => system,
        'source' => { 'kind' => 'artifact', 'id' => 'root', 'sha256' => 'a' * 64 },
        'image' => image(codec) }
    ]
    paths = catalog.map { |row| row.fetch('path') }
    runs = boots.to_h { |name| [name, { 'kind' => 'release', 'entry' => 0, 'files' => domains.size }] }
    root = paths.index('system/root')
    { build_kind: 'development', platform: platform, root_entry: root,
      artifacts: { 'root' => { 'kind' => 'executable', 'entry' => root },
                   'emu' => { 'kind' => 'executable', 'entry' => paths.index('runtimes/emu') },
                   'jit' => { 'kind' => 'executable', 'entry' => paths.index('runtimes/jit') } }.merge(runs, images),
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
    with_quota(domainless(plain), 3).sub("window data\n  holder system", "window data\n  holder @domain.alpha") +
      app + domain.call('alpha', 'required') + domain.call('beta', 'rescue') +
      "service log\n  server @domain.alpha\n  interface 1\nintroduce @domain.alpha @domain.beta\n"
  end

  # The system principal's session template, its domain quota and max_domains in
  # the development manifest.
  SESSION_TEMPLATE = /^session system\n(?:  .*\n)*/
  SYSTEM_QUOTA = /^(principal system\n(?:  .*\n)*?  domains )\d+$/
  MAX_DOMAINS = /^(  max_domains )\d+$/

  # The development manifest's own configured domains, storage and network, with the
  # profiles and runtime limits only they name, their driver-control, data and net
  # services and the system domain's facets of them, root's session template's facets of
  # data and net (which a sessionless source, ProductionImage.without_sessions, does not
  # holds), and the holder lines naming them.
  DOMAIN_ROWS = [/^runtime_limits storage\n(?:  .*\n)*/, /^limits storage\n(?:  .*\n)*/, /^domain storage\n(?:  .*\n)*/,
                 /^service storage_ctl\n(?:  .*\n)*/, /^facet storage_ctl\n(?:  .*\n)*/,
                 /^service data\n(?:  .*\n)*/, /^facet data\n(?:  .*\n)*/,
                 /^runtime_limits network\n(?:  .*\n)*/, /^limits network\n(?:  .*\n)*/, /^domain network\n(?:  .*\n)*/,
                 /^service network_ctl\n(?:  .*\n)*/, /^facet network_ctl\n(?:  .*\n)*/,
                 /^service net\n(?:  .*\n)*/].freeze
  SESSION_FACETS = [/^facet data_session\n(?:  .*\n)*/, /^facet net\n(?:  .*\n)*/].freeze
  DOMAIN_HOLDER = /^  holder @domain\.(?:storage|network)$/

  # The development manifest as the domain tests start from it: without its session
  # template, since they write their own, without its own configured domain, so the
  # domains a test adds are the only ones, and with no domain quota or max_domains,
  # since they set what their rows need.
  def sessionless(source) = with_quota(substitute(domainless(source), SESSION_TEMPLATE, ''), 0)

  # source without the storage and network domains: their rows removed and what they
  # hold held by the system domain, as a manifest that configures no domain holds them.
  # A session facet is removed where the source still has it.
  def domainless(source)
    raise ArgumentError, 'the manifest has no configured domain holder' unless source.match?(DOMAIN_HOLDER)

    held = SESSION_FACETS.reduce(source.gsub(DOMAIN_HOLDER, '  holder system')) { |text, facet| text.sub(facet, '') }
    DOMAIN_ROWS.reduce(held) { |text, row| substitute(text, row, '') }
  end

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
