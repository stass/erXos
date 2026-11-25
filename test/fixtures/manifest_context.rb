# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Unit tests supply the checked-boundary facts below explicitly. Real pack
# integration obtains its image facts from erx_elf_plan and provenance receipts.
require 'digest'
require_relative '../../tools/lib/erx/device_kinds'
require_relative '../../tools/lib/erx/domain_startup'
require_relative '../../tools/lib/erx/gatt_decl'
require_relative '../../tools/lib/erx/production_image'
require_relative '../../tools/lib/erx/structural_pack'

module ManifestContextFixture
  module_function

  # The release image and the platform are the structural pack's, so a unit test's
  # context and the structural archive's agree.
  def images = Erx::StructuralPack.images

  # The tree's own device kinds, which the checked context carries.
  def device_kinds = Erx::DeviceKinds.context_rows(File.expand_path('../..', __dir__))

  # The names of the services the tree's abi/gatt declares, which the checked context carries.
  def gatt_services(codec) = Erx::GattDecl.services(root: File.expand_path('../..', __dir__), schema: codec.schema).map(&:name)

  def platform = Erx::StructuralPack.platform

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
  # names, the app boot script of the app template the build derives from its apps row
  # (which domain_source's domains also name), the display, storage, network and web
  # boot scripts its domain rows name, the ntpd boot script of the ntpd session template
  # the raspi4b manifest and the net_device suite add, the bleuart boot script of the
  # raspi4b manifest's bleuart session template, the pcie boot script of the pcie
  # suite's PCIe domain, the usb boot script of the USB domain, the media boot script of
  # the media domain, the bt boot script of the raspi4b manifest's Bluetooth domain, the
  # domain runtime images, runtimes/emu and runtimes/jit, and the system release's
  # generated files and root.
  def arguments(codec) = archive_arguments(codec, boots: %w[app bleuart bt display media network ntpd pcie session storage usb web])

  # The archive of source's own releases, a boot script for each release its domain rows,
  # session templates and apps row name (Manifest.release_names, as the image carries
  # them), for a test that admits one suite's manifest.
  def manifest_arguments(codec, source)
    archive_arguments(codec, boots: Erx::Manifest.release_names(source: source, codec: codec))
  end

  # How many records of kind source holds: its configured domains for 'domain', which
  # the library plans one child plan for each, and the encoded manifest a row for each.
  def rows(source, kind) = Erx::Manifest::Frontend.read(source).records.fetch(kind, []).size

  # An archive of the domain release, with a boot script for each of boots and one
  # library file, then runtimes/emu, then system/, the order the archive's sorted paths
  # take, with its artifacts named as ProductionImage.artifacts names them: each boot
  # script names the release's whole run, and starts the client side of the display,
  # which property 18 asks of every script a display's grant holder boots. Every script
  # here starts it, the display's own among them, unlike the real scripts, so only a
  # test that records what real scripts start (production_image_test) sees that clause
  # refuse.
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
    runs = boots.to_h do |name|
      [name, { 'kind' => 'release', 'entry' => 0, 'files' => domains.size, 'started' => Erx::DomainStartup::DISPLAY_CLIENT }]
    end
    root = paths.index('system/root')
    { build_kind: 'development', platform: platform, root_entry: root,
      artifacts: { 'root' => { 'kind' => 'executable', 'entry' => root },
                   'emu' => { 'kind' => 'executable', 'entry' => paths.index('runtimes/emu') },
                   'jit' => { 'kind' => 'executable', 'entry' => paths.index('runtimes/jit') } }.merge(runs, images),
      catalog: catalog,
      provenance: [{ 'path' => 'fixture/root.c', 'sha256' => 'a' * 64,
                     'license' => 'BSD-2-Clause', 'evidence' => 'fixture',
                     'status' => 'permanent', 'notice' => "original\xffnotice".b }],
      device_kinds: device_kinds, gatt_services: gatt_services(codec) }
  end

  # The development manifest's text with two configured domains of the domain
  # release app and the runtime emu (arguments), alpha and beta, beta started
  # by the rescue configuration; a service alpha serves, their introduction and the
  # data window held by alpha. The manifest's own session template stays. The system
  # principal's quota covers the domains and one session, and max_domains is that quota.
  def domain_source(plain)
    domain = lambda do |name, flags|
      "domain #{name}\n  principal @principal.system\n  limits @limits.app\n  kind service\n  flags #{flags}\n" \
        "  runtime @artifact.emu\n  release @artifact.app\n  restarts 3\n  restart_period_s 5\n  args \"-x y\"\n"
    end
    app = "limits app\n  memory 4194304\n  outer 1048576\n  grant @share.users\n  spaces none\n  lane 4096\n" \
          "  connections 2\n  crash 0\n  flags none\n  runtime_limits @runtime_limits.system\n  band app\n" \
          "  peer_held 4096\n  peer_held_total 4096\n"
    with_quota(domainless(plain), 3).sub("window data\n  holder system", "window data\n  holder @domain.alpha") +
      app + domain.call('alpha', 'required') + domain.call('beta', 'rescue') +
      "service probe\n  server @domain.alpha\n  interface 1\nintroduce @domain.alpha @domain.beta\n"
  end

  # The system tree an apps row needs (property 19, docs/design-packaging.md, "The apps
  # row"), added to a source of configured domains whose block device the system domain
  # holds: the block device held by holder, which property 8 makes the system window's
  # holder, that window on the device's partition 0, its system_image row and holder's
  # service named system_service.
  def with_system_tree(source, holder:)
    substitute(source, BLOCK_UNIT, "\\1#{holder}") +
      "window system\n  holder #{holder}\n  device \"/virtio_mmio@a003e00\"\n  role system\n  partition 0\n" \
      "  image none\nsystem_image\n  input @artifact.release\n" \
      "service system\n  server #{holder}\n  interface files\n"
  end

  # The system principal's session template, its domain quota and max_domains in
  # the development manifest.
  SESSION_TEMPLATE = /^session system\n(?:  .*\n)*/
  # The development manifest's apps row.
  APPS_ROW = /^apps\n(?:  .*\n)*/
  SYSTEM_WINDOW = /^window system\n(?:  .*\n)*/
  RECORD_VOLUME_WINDOW = /^window record_volume\n(?:  .*\n)*/
  SYSTEM_IMAGE = /^system_image\n(?:  .*\n)*/
  BLOCK_UNIT = /^(unit block\n(?:  .*\n)*?  holder )system$/
  SYSTEM_QUOTA = /^(principal system\n(?:  .*\n)*?  domains )\d+$/
  MAX_DOMAINS = /^(  max_domains )\d+$/

  # The development manifest's own configured domains, storage, network, web, display, pcie, usb and media,
  # with the profiles and runtime limits only they name, their services (storage's
  # driver-control, data, packages, system and login_keys, network's driver-control and net, web's relay, the display's
  # window tree with its display record, and the PCIe domain's pcie) and the system domain's facets of them, the
  # PCIe domain's pci_bus facet, the display unit, which only a display domain holds (docs/design-fiasco.md, "Device
  # records"), so a manifest without one places none, the ECAM bridge's unit, which only the PCIe domain holds, and the
  # USB domain's xhci unit, its pci facet and its input tree, usb_input, with the display's facet of it, and the
  # media domain's service media and the drive window it holds (root's session's facet of
  # media is among SESSION_FACETS).
  DOMAIN_ROWS = [/^runtime_limits storage\n(?:  .*\n)*/, /^limits storage\n(?:  .*\n)*/, /^domain storage\n(?:  .*\n)*/,
                 /^service storage_ctl\n(?:  .*\n)*/, /^facet storage_ctl\n(?:  .*\n)*/,
                 /^service data\n(?:  .*\n)*/, /^service home\n(?:  .*\n)*/, /^facet data\n(?:  .*\n)*/, /^service packages\n(?:  .*\n)*/,
                 /^service system\n(?:  .*\n)*/, /^service login_keys\n(?:  .*\n)*/, /^facet login_keys\n(?:  .*\n)*/,
                 /^runtime_limits network\n(?:  .*\n)*/, /^limits network\n(?:  .*\n)*/, /^domain network\n(?:  .*\n)*/,
                 /^service network_ctl\n(?:  .*\n)*/, /^facet network_ctl\n(?:  .*\n)*/,
                 /^service net\n(?:  .*\n)*/,
                 /^runtime_limits web\n(?:  .*\n)*/, /^limits web\n(?:  .*\n)*/, /^domain web\n(?:  .*\n)*/,
                 /^service web\n(?:  .*\n)*/, /^facet web\n(?:  .*\n)*/,
                 /^runtime_limits display\n(?:  .*\n)*/, /^limits display\n(?:  .*\n)*/, /^domain display\n(?:  .*\n)*/,
                 /^service display\n(?:  .*\n)*/, /^display display\n(?:  .*\n)*/, /^unit display\n(?:  .*\n)*/,
                 /^runtime_limits pcie\n(?:  .*\n)*/, /^limits pcie\n(?:  .*\n)*/, /^domain pcie\n(?:  .*\n)*/,
                 /^unit pcie\n(?:  .*\n)*/, /^service pcie\n(?:  .*\n)*/, /^facet pcie\n(?:  .*\n)*/,
                 /^facet pci_bus\n(?:  .*\n)*/,
                 /^runtime_limits usb\n(?:  .*\n)*/, /^limits usb\n(?:  .*\n)*/,
                 /^domain usb\n(?:  .*\n)*/, /^unit xhci\n(?:  .*\n)*/, /^facet pci\n(?:  .*\n)*/,
                 /^service usb_input\n(?:  .*\n)*/, /^facet usb_input\n(?:  .*\n)*/,
                 /^runtime_limits media\n(?:  .*\n)*/, /^limits media\n(?:  .*\n)*/, /^domain media\n(?:  .*\n)*/,
                 /^service media\n(?:  .*\n)*/, /^window \w+\n  holder @domain\.media\n(?:  .*\n)*/].freeze
  # Root's session template's facets, of data, net, inspect, start, machine, the clock,
  # login_keys, install and media, which a sessionless source (ProductionImage.without_sessions) does not hold.
  SESSION_FACETS = [/^facet data_session\n(?:  .*\n)*/, /^facet net\n(?:  .*\n)*/, /^facet inspect\n(?:  .*\n)*/,
                    /^facet start\n(?:  .*\n)*/, /^facet machine\n(?:  .*\n)*/,
                    /^facet root_clock\n(?:  .*\n)*/, /^facet login_keys_session\n(?:  .*\n)*/,
                    /^facet display_root\n(?:  .*\n)*/, /^facet install\n(?:  .*\n)*/, /^facet media\n(?:  .*\n)*/].freeze
  # A service the system domain serves (inspect, start, machine, clock and install, to session templates
  # alone; log and code_objects, which no facet row grants), by its server line, so a new
  # one goes with the rest.
  SYSTEM_SERVICE = /^service \S+\n  server system\n(?:  .*\n)*/
  DOMAIN_HOLDER = /^  holder @domain\.(?:storage|network)$/

  # The development manifest as the domain tests start from it: without its session
  # template, since they write their own, without its own configured domain, so the
  # domains a test adds are the only ones, and with no domain quota or max_domains,
  # since they set what their rows need. The system domain's own services go with the
  # template, the one grantee of their facets, or are granted to no one.
  def sessionless(source)
    templateless = substitute(domainless(source), SESSION_TEMPLATE, '')
    with_quota(without_system_services(templateless), 0)
  end

  # source without every SYSTEM_SERVICE, for a source whose session facets are gone.
  def without_system_services(source)
    raise ArgumentError, "the manifest has no match for #{SYSTEM_SERVICE.inspect}" unless source.match?(SYSTEM_SERVICE)

    source.gsub(SYSTEM_SERVICE, '')
  end

  # source without its configured domains, storage, network, web and display: their rows
  # removed and what they hold but the display unit held by the system domain, as a
  # manifest that configures no domain holds them. A session facet is removed where the
  # source still has it, and so is its apps row, whose services those domains serve, and
  # its system and record_volume windows, which only a storage domain holds (property 8),
  # with the system_image row that names the system window's image.
  def domainless(source)
    raise ArgumentError, 'the manifest has no configured domain holder' unless source.match?(DOMAIN_HOLDER)

    appless = source.sub(APPS_ROW, '').sub(SYSTEM_WINDOW, '').sub(RECORD_VOLUME_WINDOW, '').sub(SYSTEM_IMAGE, '')
    held = SESSION_FACETS.reduce(appless.gsub(DOMAIN_HOLDER, '  holder system')) { |text, facet| text.sub(facet, '') }
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

  # Two UARTs beyond a board's console and host link, each a unit of its own, line_a and
  # line_b, by path, register base and interrupt line, for the line interface's grants
  # (docs/design-bluetooth.md, "The controller's line").
  LINE_UARTS = { 'line_a' => ['/pl011@9050000', 0x9050000, 41], 'line_b' => ['/pl011@9060000', 0x9060000, 42] }.freeze

  # A virtio console beyond them, a unit of its own, line_serial, by path, register base
  # and interrupt line: a line's device of role serial (docs/design-bluetooth.md, "The
  # line on QEMU `virt`").
  LINE_SERIAL = ['line_serial', '/virtio_mmio@a008000', 0xa008000, 43].freeze

  # The platform record with the LINE_UARTS units added, each a copy of the console's
  # UART row at its own path, base and interrupt line, or the line lines gives by unit,
  # and the LINE_SERIAL unit, a copy of the gpu's transport with 256 KiB of DMA memory.
  def line_platform(platform, lines: {})
    devices = platform.fetch('units').flat_map { |unit| unit.fetch('devices') }
    console = devices.find { |device| device['path'] == platform.fetch('console') }
    units = LINE_UARTS.map do |key, (path, base, line)|
      { 'key' => key, 'devices' => [console.merge('path' => path, 'base' => base, 'line' => lines.fetch(key, line), 'placement_key' => key)] }
    end
    key, path, base, line = LINE_SERIAL
    serial = devices.find { |device| device['role'] == 'gpu' }
                    .merge('role' => 'serial', 'path' => path, 'base' => base, 'line' => line, 'dma_memory' => 262_144, 'placement_key' => key)
    platform.merge('units' => platform.fetch('units') + units + [{ 'key' => key, 'devices' => [serial] }])
  end

  # source with the unit records of the LINE_UARTS, each held by the system domain unless
  # holders, by unit name, says otherwise, and of LINE_SERIAL when serial says so, the
  # system domain's line service, which takes the place of source's own if it has one (the
  # development manifest declares it, sessionless drops it), and grants.
  def with_line(source, *grants, holders: {}, serial: false)
    keys = LINE_UARTS.keys + (serial ? [LINE_SERIAL.first] : [])
    units = keys.map { |key| "unit #{key}\n  placement \"#{key}\"\n  holder #{holders.fetch(key, 'system')}\n" }
    service = "service line\n  server system\n  interface line\n"
    source.sub(service, '') + units.join + service + grants.join
  end

  # A facet row granting grantee the line service on the device at device, its
  # max_request floor, the files_max_frame_min of a tree served as an erx_fs grant, with
  # a UART's rate and flow, each left out when nil.
  def line_grant(name, grantee, device, floor:, rate: 115_200, flow: 'none')
    "facet #{name}\n  grantee #{grantee}\n  service @service.line\n  operations none\n  max_request #{floor}\n" \
      "  in_flight 1\n  reductions 1\n  period_ns 1\n  max_heap_size 1\n  parameter device \"#{device}\"\n" +
      (rate ? "  parameter rate #{rate}\n" : '') + (flow ? "  parameter flow \"#{flow}\"\n" : '')
  end

  # The codec of the tree's ABI with one more interface, declared by DECLARATION.
  def codec_with(declaration)
    sources = Erx::ABI::Sources.read(root: File.expand_path('../..', __dir__))
    extra = Erx::ABI::Syntax.parse(declaration, path: 'abi/services/extra.txt')
    Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::SourceSet.new(declarations: sources.declarations + extra,
                                                                         inputs: sources.inputs)))
  end

  # Names of GATT services for a context's gatt_services, nine of them: one more than a
  # ble grant's set holds (abi/services/ble.txt), in strict byte order, nus before nusb,
  # its extension, and nusb before nv.
  GATT_NAMES = %w[nus nusb nv nw nx ny nz oa ob].freeze

  # A service of the ble interface named service and served by server, and grantee's
  # facet nm of it naming services, in the given order.
  def ble_grant(services, grantee: '@domain.alpha', server: '@domain.beta', service: 'ble')
    "service #{service}\n  server #{server}\n  interface ble\nfacet nm\n  grantee #{grantee}\n  service @service.#{service}\n" \
      "  operations none\n  max_request 1\n  in_flight 1\n  reductions 1\n  period_ns 1\n  max_heap_size 1\n" +
      services.map { |name| "  parameter services \"#{name}\"\n" }.join
  end

  # A planner that plans every configured domain, introduction and session, for
  # checks that test the rest.
  def accepting_planner = ->(view) { { 'domains' => view.fetch('order').map { 0 }, 'introductions' => view.fetch('introductions').map { 0 },
                                          'sessions' => view.fetch('sessions').map { 0 } } }
end
