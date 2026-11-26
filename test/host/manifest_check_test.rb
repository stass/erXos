# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../../tools/lib/erx/manifest'
require_relative '../../tools/lib/erx/platform'
require_relative '../../tools/lib/erx/medium_boot'
require_relative '../../tools/lib/erx/pcie_domain'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/dom_view_build'
require_relative '../fixtures/manifest_context'

# Phase 1's manifest check (docs/design-fiasco.md): each kept property of
# design-system.md has a seeded violation here and each refusal a seeded record.
# Every seed edits the real development manifest or the real platform record,
# so a seed fails for its own reason and not for an unrelated difference.
class ManifestCheckTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  BLOCK = '/virtio_mmio@a003e00'
  SERVICE = "service probe\n  server system\n  interface 1\n"

  def setup
    @codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    @source = Erx::Platform.load(root: ROOT, name: 'qemu-virt').manifest_source(ROOT)
    @platform = Erx::Platform.load(root: ROOT, name: 'qemu-virt').record
    @context = context
  end

  def context(platform: @platform, build_kind: 'development')
    arguments = ManifestContextFixture.arguments(@codec).merge(platform: platform, build_kind: build_kind)
    yield arguments if block_given?
    Erx::Manifest::Context.new(**arguments)
  end

  # source, which a test made from the development manifest, after checking that it
  # differs from it, so a substitution that no longer matches fails rather than
  # testing the manifest unchanged.
  def changed(source)
    refute_equal @source, source, 'the substitution matches the development manifest'
    source
  end

  def admit(source = @source, against = @context)
    Erx::Manifest.admit(source: source, codec: @codec, context: against, planner: ManifestContextFixture.accepting_planner)
  end

  def refused(klass, field, source = @source, against = @context, message: nil)
    error = assert_raises(klass) { admit(source, against) }
    assert_equal field, error.field, error.message
    assert_match message, error.message if message
    error
  end

  def platform_with
    JSON.parse(JSON.generate(@platform)).tap { |platform| yield platform }
  end

  # The real platform with one more unit holding one device of this form, and
  # the manifest placing it.
  def with_extra_device(**fields)
    [@source + "unit extra\n  placement \"extra\"\n  holder system\n", context(platform: with_extra_device_platform(**fields))]
  end

  # The real platform with the unit with_extra_device places, its device a copy of the
  # line unit's, as a network device with no DMA, with fields changed.
  def with_extra_device_platform(**fields)
    device = @platform.fetch('units').find { |unit| unit.fetch('key') == 'line' }.fetch('devices').first
                      .merge('path' => '/extra@0', 'placement_key' => 'extra', 'role' => 'network', 'dma' => 'none',
                             'flags' => 0, 'dma_memory' => 0)
                      .merge(fields.transform_keys(&:to_s))
    platform_with { |value| value.fetch('units') << { 'key' => 'extra', 'devices' => [device] } }
  end

  def window(role:, partition: 1, device: BLOCK, holder: 'system', image: 'none', name: 'seeded', drive: nil)
    "window #{name}\n  holder #{holder}\n  device \"#{device}\"\n  role #{role}\n#{"  partition #{partition}\n" if partition}" \
      "  image #{image}\n#{"  drive #{drive}\n" if drive}"
  end

  # A device-tree row without its window or line would give its driver zeros to open.
  def test_a_device_tree_row_must_carry_its_window_and_line
    %w[base size line].each do |field|
      platform = platform_with { |value| value.fetch('units').first.fetch('devices').first.delete(field) }
      refused(Erx::Manifest::Invalid, 'context.platform.devices', @source, context(platform: platform), message: /lacks #{field}/)
    end
  end

  def test_a_device_tree_row_must_have_a_window
    platform = platform_with { |value| value.fetch('units').first.fetch('devices').first['size'] = 0 }
    refused(Erx::Manifest::Invalid, 'context.platform.devices', @source, context(platform: platform), message: /empty window/)
  end

  # A device's path is the PATH of its device record, its name to its driver
  # (docs/design-fiasco.md, "Device records"): a node path of at most
  # device_path_max bytes. A path at the bound passes and one a byte longer, empty, relative or
  # holding an escape is refused.
  def test_a_device_tree_row_s_path_is_a_node_path_its_record_holds
    longest = '/extra@0/' + ('a' * (@codec.constant('device_path_max') - 9))
    assert_equal @codec.constant('device_path_max'), longest.bytesize
    admit(*with_extra_device(path: longest))
    [longest + 'a', '', 'extra@0', "/extra@0\e[2J", nil].each do |path|
      source, against = with_extra_device(path: path)
      refused(Erx::Manifest::Invalid, 'context.platform.devices', source, against, message: /path is not a node path/)
    end
  end

  # A device is one unit's (docs/design-system.md, "Devices"), so a device-tree path two
  # units' devices name is refused.
  def test_a_device_in_two_units_is_refused
    first = @platform.fetch('units').first.fetch('devices').first
    source, against = with_extra_device(path: first.fetch('path'))
    refused(Erx::Manifest::Invalid, 'devices.path', source, against, message: /more than one unit/)
  end

  # A PL011's driver times characters and divides its baud rate from the UART's clock, which
  # only the board knows, so a PL011 row without a clock of at least one hertz is wrong.
  def test_a_pl011_row_must_carry_its_clock
    [nil, 0, -1, '24000000'].each do |clock|
      platform = platform_with do |value|
        device = value.fetch('units').first.fetch('devices').first
        clock.nil? ? device.delete('clock') : device['clock'] = clock
      end
      refused(Erx::Manifest::Invalid, 'context.platform.devices', @source, context(platform: platform), message: /arm,pl011 device .*clock/)
    end
  end

  # Only a driver of a clocked kind reads a clock, so any other row's clock is 0.
  def test_a_row_of_another_device_carries_no_clock
    source, against = with_extra_device(compatible: 'virtio,mmio', clock: 24_000_000)
    refused(Erx::Manifest::Invalid, 'context.platform.devices', source, against, message: /clock/)
  end

  # Configuration space gives a PCIe function its window, so a platform row that names one is wrong.
  def test_a_pci_row_must_not_carry_a_window
    source, against = with_extra_device(selector: 'pci', role: 'ordinary', bridge: '/pcie@0', path: '')
    refused(Erx::Manifest::Invalid, 'context.platform.devices', source, against, message: /PCIe function carries/)
  end

  def test_the_real_development_manifest_is_accepted
    result = admit
    assert_instance_of Erx::Manifest::Admitted, result
    assert result.bytes.frozen?
    view = @codec.open('manifest', result.bytes)
    assert_equal ManifestContextFixture.rows(@source, 'domain'), view.count('domains')
    assert_equal 15, view.count('devices')
    assert_equal ManifestContextFixture.rows(@source, 'window'), view.count('windows')
    assert_equal 1, view.count('images')
  end

  # The pcie suite's base manifest, the development manifest without the web domain
  # (PcieDomain), passes the check and keeps the root's margin, since the web domain
  # gives back the room it took.
  def test_the_pcie_domain_s_manifest_is_accepted
    platform = Erx::Platform.load(root: ROOT, name: 'qemu-virt')
    result = admit(Erx::PcieDomain.manifest_source(ROOT, platform: platform))
    view = @codec.open('manifest', result.bytes)
    assert_equal 4, view.count('domains')
    assert_equal 8 << 20, result.report.fetch('root_memory') - result.report.fetch('promised_memory')
  end

  # The pcie QEMU suite's manifest (PcieDomain.manifest), on MediumBoot's machine, passes
  # too: the test holder's row, the xhci unit it holds and its pci facet.
  def test_the_pcie_suite_s_manifest_is_accepted
    platform = Erx::Platform.load(root: ROOT, name: 'qemu-virt')
    source = Erx::PcieDomain.manifest(Erx::PcieDomain.manifest_source(ROOT, platform: platform))
    medium = context do |arguments|
      arguments.merge!(ManifestContextFixture.manifest_arguments(@codec, source))
      arguments[:platform] = @platform.merge('ram_bytes' => Erx::MediumBoot.machine(platform).memory_mib << 20)
    end
    result = admit(source, medium)
    view = @codec.open('manifest', result.bytes)
    assert_equal ManifestContextFixture.rows(source, 'domain'), view.count('domains')
  end

  # The footprint cell's manifest (MediumBoot::Footprint.manifest), made from the website's,
  # passes too: its configured domains' small profile meets the code protocol's load floors.
  def test_the_footprint_cell_s_manifest_is_accepted
    platform = Erx::Platform.load(root: ROOT, name: 'qemu-virt')
    medium = context do |arguments|
      arguments.merge!(ManifestContextFixture.archive_arguments(@codec, boots: %w[bare blk net network storage]))
      arguments[:platform] = @platform.merge('ram_bytes' => Erx::MediumBoot.machine(platform).memory_mib << 20)
    end
    result = admit(Erx::MediumBoot::Footprint.manifest(site_manifest, system_tmp: 8_388_608), medium)
    assert_equal 5, @codec.open('manifest', result.bytes).count('domains')
  end

  # The website's manifest passes the same check: its storage and network domains, without
  # the web and display domains, hold the same windows and image and every device but the
  # display unit's, which lists every transport on the gpu's register page.
  def test_the_real_site_manifest_is_accepted
    result = admit(site_manifest)
    view = @codec.open('manifest', result.bytes)
    assert_equal 2, view.count('domains')
    assert_equal 5, view.count('devices')
    assert_equal 10, view.count('windows')
    assert_equal 1, view.count('images')
  end

  # Each manifest's root_memory is what its budgets promise and an 8 MiB margin no one
  # is promised: the site manifest's, made from the development one, keeps the margin,
  # since each domain it leaves out gives back the room it took
  # (Manifest::Edit.without_domain), the display unit's DMA memory included.
  def test_root_memory_is_the_promise_and_the_margin_in_both_manifests
    [@source, site_manifest].each do |source|
      report = admit(source).report
      assert_equal 8 << 20, report.fetch('root_memory') - report.fetch('promised_memory')
    end
  end

  # The website's manifest, made from the development one.
  def site_manifest
    Erx::Platform.development(ROOT).site_manifest_source(ROOT)
  end

  def test_the_report_carries_the_checked_numbers
    report = admit.report
    assert_equal ManifestContextFixture.rows(@source, 'domain'), report.fetch('child_plan_instances')
    assert_equal @platform.fetch('fiasco_reserve'), report.fetch('fiasco_reserve')
    assert_equal @platform.fetch('ram_bytes'), report.fetch('ram_bytes')
    assert_equal 4096, report.fetch('root_image_loadable_bytes')
  end

  # The development manifest as a partial boot, which makes no sessions and configures
  # no domains, so without its session template, the system domain's services (which only
  # sessions use) and its storage, network and web domains.
  def partial_boot
    changed(ManifestContextFixture.without_system_services(
      ManifestContextFixture.domainless(@source).sub('flags development', 'flags development,partial_boot')
                            .sub(/^session system\n(?:  .*\n)*/, '')
    ))
  end

  def test_a_partial_boot_flag_without_partial_boot_records_is_accepted
    assert_equal 0, admit(partial_boot).report.fetch('child_plan_instances')
  end

  def test_a_partial_boot_has_no_system_image
    refused(Erx::Manifest::Invalid, 'system_image', partial_boot + "system_image\n  input @artifact.release\n",
            message: /a partial boot has no domain to hold the system partition/)
  end

  def test_a_partial_boot_runs_no_services
    source = partial_boot + SERVICE
    refused(Erx::Manifest::Invalid, 'service', source, message: /a partial boot runs no services/)
  end

  def test_accepted_services_reach_the_encoded_manifest
    view = @codec.open('manifest', admit(@source + SERVICE).bytes)
    # The development manifest's own, clock, code_objects, data, display, home, inspect, install, line,
    # log, login, login_keys, machine, media, net, network_ctl, packages, pci, pci_bus, pcie, start, storage_ctl,
    # system, usb_input and web, and this one.
    assert_equal %w[clock code_objects data display home inspect install line log login login_keys machine media net network_ctl packages pci pci_bus pcie probe start storage_ctl system usb_input web], view.count('services').times.map { |index| view.string(view.fetch('services', index).fetch('name')) }
    assert_equal 0, view.count('liveness')
  end

  # The watchdog pets whether or not a service lives, so a record that says it watches one is refused.
  def test_a_liveness_record_is_refused_because_nothing_reads_it
    refused(Erx::Manifest::Unsupported, 'liveness', @source + SERVICE + "liveness @service.probe\n",
            message: /watchdog/)
  end

  # Property 1: one holder per device and unit.
  def test_a_unit_held_by_another_domain_is_refused
    refused(Erx::Manifest::Invalid, 'unit.holder', changed(@source.sub("placement \"net\"\n  holder @domain.network", "placement \"net\"\n  holder other")),
            message: /names neither the system domain nor a configured domain/)
  end

  def test_a_unit_placed_twice_is_refused
    refused(Erx::Manifest::Invalid, 'unit.placement', @source + "unit again\n  placement \"block\"\n  holder system\n",
            message: /unit is assigned more than once/)
  end

  def test_a_device_in_two_units_is_refused
    source, against = with_extra_device(path: BLOCK)
    refused(Erx::Manifest::Invalid, 'devices.path', source, against, message: /a device appears in more than one unit/)
  end

  # Property 2: facets name servers, and no introductions.
  def test_a_service_on_another_server_is_refused
    refused(Erx::Manifest::Invalid, 'service.server', @source + SERVICE.sub('server system', 'server storage'),
            message: /names neither the system domain nor a configured domain/)
  end

  # Property 3 and the drive windows of property 8 (docs/design-system.md, "The manifest";
  # docs/design-usb.md, "The Phase 1 part"). usb_platform adds three units to the real
  # platform: the ECAM bridge, whose node raises no line; qemu-xhci at its place on the
  # bridge's root bus; and a device-tree USB controller, the one a window can name by
  # path. usb_source places them, the bridge on the development manifest's PCIe domain.
  BRIDGE = '/pcie@10000000'
  STICK = '/usb@a004000'
  USB_HOLDERS = { 'pcie' => '@domain.pcie', 'xhci' => '@domain.network', 'stick' => '@domain.network' }.freeze

  # A platform device row with every field the record carries, inactive ones zero.
  def usb_row(key, **fields)
    { 'placement_key' => key, 'selector' => 'dt', 'role' => 'ordinary', 'path' => '', 'bridge' => '', 'compatible' => '',
      'base' => 0, 'size' => 0, 'line' => 0, 'bus' => 0, 'device' => 0, 'function' => 0, 'clock' => 0,
      'dma' => 'none', 'dma_memory' => 0, 'flags' => 0 }.merge(fields.transform_keys(&:to_s))
  end

  def hostile = @codec.member('mf_device_flags', 'hostile')

  def bridge_row = usb_row('pcie', role: 'configuration', path: BRIDGE, compatible: 'pci-host-ecam-generic',
                                   base: 0x40_1000_0000, size: 0x1000_0000)

  def xhci_row(**fields)
    usb_row('xhci', selector: 'pci', role: 'usb', bridge: BRIDGE, device: 2, compatible: 'pci1b36,000d',
                    dma: 'unconfined', dma_memory: 1 << 20, flags: hostile, **fields)
  end

  def stick_row = usb_row('stick', role: 'usb', path: STICK, compatible: 'generic-xhci', base: 0xa004000, size: 0x1000,
                                   line: 90, flags: hostile)

  # The real platform with the units of units, each key's list of devices, in place of the
  # platform's own unit of that key (QEMU virt's ECAM bridge and qemu-xhci).
  def usb_platform(**units)
    rows = { pcie: [bridge_row], xhci: [xhci_row], stick: [stick_row] }.merge(units)
    platform_with do |value|
      value.fetch('units').reject! { |unit| rows.key?(unit.fetch('key').to_sym) }
      rows.each { |key, devices| value.fetch('units') << { 'key' => key.to_s, 'devices' => devices } }
    end
  end

  # The development manifest without its media domain and that domain's drive window on the
  # xhci function (Manifest::Edit.without_domain), with the units of holders in place of its
  # bridge's and xhci's units, the pci facet of the function's holder when a configured domain
  # holds it, and the web service served by the PCIe domain when serving.
  def usb_source(holders = USB_HOLDERS, serving: false)
    without_media = Erx::Manifest::Edit.without_domain(@source, 'media', units: @platform.fetch('units'))
    bridgeless = changed(without_media.sub(/^unit pcie\n(?:  .*\n)*/, '').sub(/^unit xhci\n(?:  .*\n)*/, '').sub(/^facet pci\n(?:  .*\n)*/, ''))
    bridgeless = changed(bridgeless.sub("service web\n  server @domain.web\n", "service web\n  server @domain.pcie\n")) if serving
    holder = holders['xhci']
    bridgeless + units_of(holders) + (holder&.start_with?('@domain.') ? pcie_facet('pci', holder) : '')
  end

  # A facet row of the PCIe interface service, granted to grantee.
  def pcie_facet(service, grantee, name: service)
    "facet #{name}\n  name \"#{service}\"\n  grantee #{grantee}\n  service @service.#{service}\n  operations none\n  max_request 4096\n" \
      "  in_flight 1\n  reductions 100000\n  period_ns 1000000000\n  max_heap_size 65536\n"
  end

  def units_of(holders) = holders.map { |key, holder| "unit #{key}\n  placement \"#{key}\"\n  holder #{holder}\n" }.join

  def usb_admit(source = usb_source, platform = usb_platform) = admit(source, context(platform: platform))

  def usb_refused(field, message, source = usb_source, platform = usb_platform)
    refused(Erx::Manifest::Invalid, field, source, context(platform: platform), message: message)
  end

  def test_the_pcie_domain_holds_the_bridge_and_a_configured_domain_a_function
    view = @codec.open('manifest', usb_admit.bytes)
    devices = view.count('devices').times.map { |index| view.fetch('devices', index) }
    function = devices.find { |device| device.fetch('selector') == @codec.member('mf_selector', 'pci') }
    assert_equal [@codec.member('mf_device_role', 'usb'), 0, 2, 0], function.values_at('role', 'bus', 'device', 'function')
  end

  def test_a_bridge_held_by_another_domain_is_refused
    %w[system @domain.network].each do |holder|
      usb_refused('unit.holder', /only the domain pcie holds a PCIe bridge's unit/, usb_source(USB_HOLDERS.merge('pcie' => holder)))
    end
    usb_refused('unit.holder', /only the domain pcie holds a PCIe bridge's unit/,
                changed(@source.sub(/^unit pcie\n(?:  .*\n)*/, '').sub(/^unit xhci\n(?:  .*\n)*/, '')) +
                  units_of(USB_HOLDERS.merge('pcie' => '@domain.network')))
  end

  # A function, even one the platform marks as of the configuration role, is no bridge.
  def test_the_pcie_domain_holding_another_device_is_refused
    message = /the domain pcie holds only PCIe bridges' units/
    usb_refused('unit.holder', message, usb_source(USB_HOLDERS.merge('xhci' => '@domain.pcie')))
    usb_refused('unit.holder', message, usb_source,
                usb_platform(pcie: [bridge_row, stick_row.merge('path' => '/usb@a005000', 'base' => 0xa005000)]))
    usb_refused('unit.holder', message, usb_source, usb_platform(pcie: [bridge_row, xhci_row(role: 'configuration', device: 3)]))
  end

  # docs/design-drives.md, "Manifest rows": a media service of the files interface would
  # hand its grantees a drive's links to follow, since the nofollow mark comes from the
  # media interface's number.
  def test_a_media_service_of_another_interface_is_refused
    usb_refused('service.interface', /the service named media is of the media interface/,
                media_source.sub("interface media\n", "interface files\n") + drive_window('disk0'))
  end

  def test_the_pcie_domain_holding_a_window_or_a_service_is_refused
    usb_refused('windows', /pcie holds nothing but PCIe bridges' units, and its windows row/,
                media_source + drive_window('disk0', holder: '@domain.pcie'))
    usb_refused('services', /pcie holds nothing but PCIe bridges' units, and its services row/, usb_source(serving: true))
  end

  # The PCIe interfaces' parties (docs/design-pcie.md, "Facets" and "The manifest"): the
  # domain pcie serves pcie to the system domain and holds pci_bus, the system domain's.
  def test_the_pcie_domain_serves_pcie_and_holds_pci_bus
    usb_admit
  end

  # usb_source without the PCIe domain's pci_bus facet, so a pci_bus service moved off the
  # system domain or onto another interface meets the service check, not first the facet
  # check of operations on a configured domain's service or of undeclared operations.
  def without_pci_bus_facet = changed(usb_source.sub(/^facet pci_bus\n(?:  .*\n)*/, ''))

  def test_a_pcie_interface_of_another_server_is_refused
    usb_refused('service.server', /a pci service is named pci, is of interface pci and is served by the system domain alone/,
                usb_source.sub("service pci\n  server system\n", "service pci\n  server @domain.storage\n"))
    usb_refused('service.server', /a pci_bus service .* served by the system domain alone/,
                without_pci_bus_facet.sub("service pci_bus\n  server system\n", "service pci_bus\n  server @domain.network\n"))
    # The system domain takes no facet of its own service, so the pcie facet goes with the move.
    usb_refused('service.server', /a pcie service .* served by the domain pcie alone/,
                changed(usb_source.sub("service pcie\n  server @domain.pcie\n", "service pcie\n  server system\n")
                                .sub(/^facet pcie\n(?:  .*\n)*/, '')))
  end

  # The system domain finds a facet's callback by its service's name, so the name and the
  # interface go together both ways.
  def test_a_pcie_service_name_apart_from_its_interface_is_refused
    message = /a pci_bus service is named pci_bus, is of interface pci_bus/
    usb_refused('service.server', message, without_pci_bus_facet.sub("  interface pci_bus\n", "  interface log\n"))
    usb_refused('service.server', message, usb_source + "service pci_bus_too\n  server system\n  interface pci_bus\n")
  end

  def test_the_pcie_domain_holding_a_facet_of_another_interface_is_refused
    usb_refused('facets', /pcie holds nothing but PCIe bridges' units, and its facets row/,
                usb_source + pcie_facet('pci', '@domain.pcie', name: 'pci_pcie').sub('@service.pci', '@service.log'))
  end

  def test_a_pci_bus_facet_of_another_grantee_is_refused
    usb_refused('facet.grantee', /only the domain pcie holds a pci_bus facet/, usb_source + pcie_facet('pci_bus', '@domain.network', name: 'pci_bus_network'))
  end

  def test_a_pcie_facet_of_another_grantee_is_refused
    usb_refused('facet.grantee', /only the system domain holds a pcie facet/,
                usb_source + pcie_facet('pcie', '@domain.network', name: 'pcie_network'))
  end

  def test_a_pci_facet_is_held_exactly_by_the_holders_of_pci_devices
    message = /a configured domain holds a pci facet exactly when it holds a pci device/
    usb_refused('facet.grantee', message, usb_source.sub(/^facet pci\n(?:  .*\n)*/, ''))
    usb_refused('facet.grantee', message, usb_source + pcie_facet('pci', '@domain.storage', name: 'pci_storage'))
  end

  def test_a_function_held_by_the_system_domain_is_refused
    usb_refused('unit.holder', /a PCIe function is held by a configured domain/, usb_source(USB_HOLDERS.merge('xhci' => 'system')))
  end

  def test_a_function_that_is_not_unconfined_is_refused
    usb_refused('devices.dma', /a PCIe function is unconfined/, usb_source, usb_platform(xhci: [xhci_row(dma: 'none', dma_memory: 0)]))
  end

  def test_a_function_behind_a_bridge_no_unit_places_is_refused
    usb_refused('devices.bridge', /names no PCIe bridge the manifest places/, usb_source(USB_HOLDERS.except('pcie')))
    usb_refused('devices.bridge', /names no PCIe bridge the manifest places/, usb_source,
                usb_platform(xhci: [xhci_row(bridge: STICK)]))
  end

  def test_a_place_in_two_units_is_refused
    usb_refused('devices.place', /a device appears in more than one unit/,
                usb_source(USB_HOLDERS.merge('again' => '@domain.network')), usb_platform(again: [xhci_row]))
  end

  # QEMU virt's bridge is not closed, so a line given to qemu-xhci would be shared with
  # whatever the walk finds behind it.
  def test_an_intx_line_on_a_bridge_the_platform_does_not_close_is_refused
    usb_refused('context.platform.devices', /a PCIe function names a line only at a closed bridge's place/, usb_source,
                usb_platform(xhci: [xhci_row(line: 80)]))
  end

  def test_a_pci_row_must_carry_no_register_window
    usb_refused('context.platform.devices', /a PCIe function carries a window/, usb_source,
                usb_platform(xhci: [xhci_row(base: 0x1000, size: 0x1000)]))
  end

  # A closed bridge, as the Pi 4's record spells the BCM2711's (docs/design-pcie.md, "The
  # closed bus"): its flags and places in erx_pcie_place's own shape, its DMA limit, and the
  # VL805 at its one place with the line the bridge routes for the place's pin.
  CLOSED = '/scb/pcie@7d500000'
  VL805_LINE = 175
  PLACE = { 'bus' => 1, 'device' => 0, 'function' => 0, 'pin' => 1 }.freeze

  def closed_bridge_row(**fields)
    usb_row('pcie', role: 'configuration', path: CLOSED, compatible: 'brcm,bcm2711-pcie', base: 0x40_1000_0000,
                    **{ size: 0x1000_0000, flags: ['closed'], places: [PLACE], dma_limit: 0x3c00_0000 }.merge(fields))
  end

  def vl805_row(**fields)
    xhci_row(**{ bridge: CLOSED, bus: 1, device: 0, compatible: 'pci1106,3483', line: VL805_LINE }.merge(fields))
  end

  def closed_platform(bridge: closed_bridge_row, function: vl805_row, **units)
    usb_platform(pcie: [bridge], xhci: [function], **units)
  end

  def packed_rows(view, table) = view.count(table).times.map { |index| view.fetch(table, index) }

  def test_a_closed_bridge_packs_its_places_and_its_function_its_line_and_dma_limit
    view = @codec.open('manifest', usb_admit(usb_source, closed_platform).bytes)
    devices = packed_rows(view, 'devices')
    bridge = devices.find { |device| device.fetch('role') == @codec.member('mf_device_role', 'configuration') }
    function = devices.find { |device| device.fetch('selector') == @codec.member('mf_selector', 'pci') }
    assert_equal @codec.member('mf_device_flags', 'closed'), bridge.fetch('flags') & @codec.member('mf_device_flags', 'closed')
    assert_equal [PLACE], packed_rows(view, 'places')
    assert_equal 1, bridge.fetch('places').fetch('count')
    assert_equal [VL805_LINE, 0x3c00_0000], function.values_at('line', 'dma_limit')
    assert_equal [0], (devices - [bridge]).map { |device| device.fetch('places').fetch('count') }.uniq
  end

  # Flags read by name pack as their numbers do.
  def test_a_flags_field_reads_its_bits_by_name
    named = usb_admit(usb_source, usb_platform(stick: [stick_row.merge('flags' => ['hostile'])])).bytes
    assert_equal usb_admit.bytes, named
    assert_raises(Erx::ABI::DecodeError) { usb_admit(usb_source, usb_platform(stick: [stick_row.merge('flags' => ['made_up'])])) }
  end

  def test_a_function_behind_a_closed_bridge_at_no_listed_place_is_refused
    usb_refused('devices.place', /behind the closed bridge #{CLOSED} is at none of its listed places/, usb_source,
                closed_platform(function: vl805_row(device: 1)))
  end

  def test_a_function_at_a_closed_place_without_its_line_is_refused
    usb_refused('context.platform.devices', /names its place's line/, usb_source, closed_platform(function: vl805_row(line: 0)))
  end

  def test_places_only_on_a_closed_bridge_and_each_well_formed
    message = /a closed bridge lists its places, and only a closed PCIe bridge/
    [closed_bridge_row(flags: 0), closed_bridge_row(places: []),
     closed_bridge_row(places: [PLACE, PLACE.merge('device' => 1), PLACE.merge('device' => 2), PLACE.merge('device' => 3),
                                PLACE.merge('device' => 4)])].each do |bridge|
      usb_refused('context.platform.devices', message, usb_source, closed_platform(bridge: bridge))
    end
    usb_refused('context.platform.devices', message, usb_source,
                closed_platform(stick: [stick_row.merge('flags' => %w[hostile closed], 'places' => [PLACE])]))
    [PLACE.merge('bus' => 0), PLACE.merge('pin' => 0), PLACE.merge('pin' => 5), PLACE.merge('device' => 32),
     PLACE.merge('function' => 8), PLACE.except('pin'), PLACE.merge('bus' => '1')].each do |place|
      usb_refused('context.platform.devices', /a closed bridge's place is not/, usb_source,
                  closed_platform(bridge: closed_bridge_row(places: [place])))
    end
    usb_refused('context.platform.devices', /lists a place twice/, usb_source,
                closed_platform(bridge: closed_bridge_row(places: [PLACE, PLACE.merge('pin' => 2)])))
  end

  # An unplaced second row at the placed bridge's path, closed and listing the function's
  # place, must not let the function behind the open bridge name a line.
  def test_two_bridge_rows_at_one_path_are_refused
    usb_refused('context.platform.devices', /lists two PCIe bridges at #{BRIDGE}/, usb_source,
                usb_platform(xhci: [xhci_row(line: 80)],
                             twin: [closed_bridge_row(path: BRIDGE, places: [PLACE.merge('bus' => 1, 'device' => 2)])]))
  end

  def test_a_dma_limit_only_on_a_bridge_row
    usb_refused('context.platform.devices', /only a PCIe bridge row states a DMA limit/, usb_source,
                closed_platform(function: vl805_row(dma_limit: 1 << 30)))
    usb_refused('context.platform.devices', /only a PCIe bridge row states a DMA limit/, usb_source,
                usb_platform(stick: [stick_row.merge('dma_limit' => 1 << 30)]))
  end

  # A window names a PCIe function by its place (docs/design-abi.md, "Devices and partition
  # windows"): its bridge's path and its bus, device and function.
  def test_a_window_names_a_function_by_its_place
    view = @codec.open('manifest', usb_admit(media_source + drive_window('disk0', device: "#{BRIDGE}:0:2:0")).bytes)
    window = packed_rows(view, 'windows').find { |row| row.fetch('drive').zero? }
    function = view.fetch('devices', window.fetch('device'))
    assert_equal [@codec.member('mf_selector', 'pci'), 0, 2, 0], function.values_at('selector', 'bus', 'device', 'function')
    ["#{BRIDGE}:0:3:0", "#{BRIDGE}:1:2:0", "#{STICK}:0:2:0", "#{BRIDGE}:0:2", "#{BRIDGE}:0:2:0:0"].each do |name|
      usb_refused('window.device', /window names no block or USB device the manifest places/, media_source + drive_window('disk0', device: name))
    end
  end

  # The media domain of these manifests (docs/design-drives.md, "Manifest rows"): the
  # development manifest's usb domain, renamed media, without its usb_input service and
  # that service's facet (usb_source has taken its unit and its pci facet already), so it
  # holds nothing and serves the media service alone.
  MEDIA_SERVICE = "service media\n  server @domain.media\n  interface media\n"

  def media_source(holders = USB_HOLDERS)
    bare = usb_source(holders).sub(/^service usb_input\n(?:  .*\n)*/, '').sub(/^facet usb_input\n(?:  .*\n)*/, '')
    changed(bare.sub("domain usb\n", "domain media\n").gsub('@domain.usb', '@domain.media')) + MEDIA_SERVICE
  end

  def drive_window(drive, name: 'stick', device: STICK, role: 'drive', holder: '@domain.media', partition: nil)
    window(role: role, partition: partition, device: device, holder: holder, name: name, drive: drive)
  end

  # A files facet row of service granted to grantee, with rights when given.
  def files_facet(service, grantee, rights: nil, name: "#{service}_seeded")
    "facet #{name}\n  name \"#{service}\"\n  grantee #{grantee}\n  service @service.#{service}\n" \
      "#{"  parameter rights #{rights}\n" if rights}  operations none\n  max_request 131072\n  in_flight 16\n" \
      "  reductions 100000\n  period_ns 1000000000\n  max_heap_size 262144\n"
  end

  # The packed windows of view, split into those on the controller at path and the rest.
  def windows_on(view, path)
    rows = view.count('windows').times.map { |index| view.fetch('windows', index) }
    rows.partition { |row| view.string(view.fetch('devices', row.fetch('device')).fetch('path')) == path }
  end

  # A drive window packs its drive's number and no partition, mf_none, as every other
  # window packs no drive (docs/design-abi.md, "Devices and partition windows").
  def test_drive_windows_encode_their_drive_and_no_partition_and_others_none
    stick, others = windows_on(@codec.open('manifest', usb_admit(media_source + drive_window('disk0') + drive_window('disk3', name: 'other')).bytes), STICK)
    none = @codec.constant('mf_none')
    assert_equal [[none, 0], [none, 3]], stick.map { |row| row.values_at('partition', 'drive') }.sort
    assert_equal [none], others.map { |row| row.fetch('drive') }.uniq
  end

  def test_a_drive_window_with_a_partition_is_refused
    usb_refused('window.partition', /a drive window names no partition/, media_source + drive_window('disk0', partition: 1))
    usb_refused('window.partition', /a drive window names no partition/, media_source + drive_window('disk0', partition: 0))
  end

  def test_a_drive_window_without_a_drive_is_refused
    usb_refused('window.drive', /a drive window names its drive, and no window of another role names one/, media_source + drive_window(nil))
  end

  def test_a_drive_on_a_window_of_another_role_is_refused
    refused(Erx::Manifest::Invalid, 'window.drive', @source + window(role: 'data', partition: 0, drive: 'disk0'),
            message: /a drive window names its drive, and no window of another role names one/)
  end

  # Drive numbers are one namespace across the machine: no two windows name one drive.
  # Two on one controller would be one placement twice, which the windows' own rule
  # refuses too, so the seed's two lie on two controllers.
  def test_a_drive_named_twice_is_refused
    usb_refused('window.drive', /drive disk1 is named by two windows/,
                media_source + drive_window('disk1') + drive_window('disk1', name: 'other', device: "#{BRIDGE}:0:2:0"))
  end

  # A drive's name is disk and its decimal number, any number below mf_none: the cap is on
  # how many drives a controller names, not in the names.
  def test_a_drive_is_disk_and_a_number
    highest = @codec.constant('mf_none') - 1
    view = @codec.open('manifest', usb_admit(media_source + drive_window('disk7') + drive_window("disk#{highest}", name: 'high')).bytes)
    assert_equal [7, highest], windows_on(view, STICK).first.map { |row| row.fetch('drive') }.sort
    ["disk#{@codec.constant('mf_none')}", 'disk', 'disk01', 'da0', 'xdisk0', '0', '"disk0"'].each do |drive|
      usb_refused('window.drive', /a drive is disk and a decimal number below #{@codec.constant('mf_none')}/,
                  media_source + drive_window(drive))
    end
  end

  # The cap is the USB domain's, over the drives all its controllers' rows name: the media
  # it serves at once. USB_HOLDERS gives the stick's and the xhci function's units to one domain.
  def test_a_usb_domain_naming_more_than_usb_drives_max_drives_is_refused
    drives = @codec.constant('usb_drives_max')
    function = "#{BRIDGE}:0:2:0"
    rows = (0..drives).map do |number|
      drive_window("disk#{number * 2}", name: "stick#{number}", device: number.even? ? STICK : function)
    end
    usb_admit(media_source + rows.take(drives).join)
    usb_refused('window.drive', /a USB domain's controllers name more than #{drives} drives/, media_source + rows.join)
    holders = USB_HOLDERS.merge('xhci' => '@domain.storage')
    apart = (0...drives * 2).map do |number|
      drive_window("disk#{number}", name: "stick#{number}", device: number < drives ? STICK : function)
    end
    usb_admit(media_source(holders) + apart.join, usb_platform)
  end

  def test_a_usb_controller_s_window_is_a_drive_window
    usb_refused('window.role', /a window on a USB controller is a drive window/,
                media_source + drive_window('disk0') + window(role: 'data', partition: 0, device: STICK, holder: '@domain.storage'))
  end

  # A log facet row granted to grantee, as every configured domain may hold one
  # (docs/design-log.md, "The log facet").
  def log_facet(grantee, name: 'log_seeded')
    "facet #{name}\n  name \"log\"\n  grantee #{grantee}\n  service @service.log\n  operations write\n" \
      "  max_request 16384\n  in_flight 2\n  reductions 100000\n  period_ns 1000000000\n  max_heap_size 262144\n"
  end

  # The block device of block_drive_source, a copy of the line unit's device as a block
  # device with no DMA, on a register page and an interrupt line of its own, since the
  # domain library's boot view refuses devices of two units that share either.
  def extra_block_row
    @platform.fetch('units').find { |unit| unit.fetch('key') == 'line' }.fetch('devices').first
             .merge('path' => '/extra@0', 'placement_key' => 'extra', 'role' => 'block', 'dma' => 'none',
                    'flags' => 0, 'dma_memory' => 0, 'base' => 0xa005000, 'line' => 91)
  end

  # media_source with a block device's drive, disk0, whose device's unit holder holds
  # (by default disk, a copy of the development manifest's usb domain, which holds
  # nothing else), and the platform that places the device: block, which path names.
  def block_drive_source(holder: '@domain.disk', holders: USB_HOLDERS, block: extra_block_row, path: '/extra@0')
    disk = @source[/^domain usb\n(?:  .*\n)*/].sub("domain usb\n", "domain disk\n")
    [media_source(holders) + SPARE_UNIT + disk + "unit extra\n  placement \"extra\"\n  holder #{holder}\n" + drive_window('disk0', device: path),
     context(platform: usb_platform(extra: [block], spare: [spare_block_row]))]
  end

  # A second block device, /spare@0, its unit held by the storage domain, so a seed can
  # place a data window on it without naming the boot medium's partition again.
  def spare_block_row = extra_block_row.merge('path' => '/spare@0', 'placement_key' => 'spare', 'base' => 0xa006000, 'line' => 92)

  SPARE_UNIT = "unit spare\n  placement \"spare\"\n  holder @domain.storage\n"

  def spare_window(holder) = window(role: 'data', partition: 0, device: '/spare@0', holder: holder, name: 'spare')

  # A block device's drive (docs/design-drives.md, "A drive and its medium"): the device's
  # one window is its drive window, which the media domain holds.
  def test_a_block_device_s_drive_is_its_one_window
    source, against = block_drive_source
    view = @codec.open('manifest', admit(source + log_facet('@domain.disk'), against).bytes)
    assert_equal [[@codec.constant('mf_none'), 0]], windows_on(view, '/extra@0').first.map { |row| row.values_at('partition', 'drive') }
    refused(Erx::Manifest::Invalid, 'window.device', source + drive_window('disk1', device: '/extra@0', name: 'again'),
            against, message: /a block device with a drive window has no other window/)
    refused(Erx::Manifest::Invalid, 'window.device',
            source + window(role: 'data', partition: 0, device: '/extra@0', holder: '@domain.storage'),
            against, message: /a block device with a drive window has no other window/)
  end

  # The domain that holds a block device's drive holds that device and nothing else
  # (docs/design-drives.md, "A drive and its medium"): no other unit, no window, no
  # service but its driver control, no facet but a pci and the log's, and it is a
  # configured domain.
  def test_a_block_drive_s_holder_holding_anything_else_is_refused
    message = ->(scope) { /the holder of drive disk0, disk, holds nothing but its device's unit, one driver-control service, a pci facet and log facets, and its #{scope} row names it/ }
    source, against = block_drive_source
    units, = block_drive_source(holders: USB_HOLDERS.merge('stick' => '@domain.disk'))
    refused(Erx::Manifest::Invalid, 'units', units, against, message: message.call('units'))
    refused(Erx::Manifest::Invalid, 'windows', source + spare_window('@domain.disk'),
            against, message: message.call('windows'))
    refused(Erx::Manifest::Invalid, 'services', source + "service disk_tree\n  server @domain.disk\n  interface files\n",
            against, message: message.call('services'))
    refused(Erx::Manifest::Invalid, 'facets', source + files_facet('start', '@domain.disk', rights: 'rw'),
            against, message: message.call('facets'))
    two = context(platform: usb_platform(extra: [extra_block_row, spare_block_row.merge('placement_key' => 'extra')],
                                         spare: [spare_block_row.merge('path' => '/third@0')]))
    refused(Erx::Manifest::Invalid, 'units', source, two, message: message.call('units'))
    held, = block_drive_source(holder: 'system')
    refused(Erx::Manifest::Invalid, 'unit.holder', held, against,
            message: /the device of drive disk0 is held by a configured domain/)
  end

  # The system domain's boot carries no drive record (docs/design-fiasco.md, "Drive
  # records"), so a drive on a USB controller it holds is refused as a block drive is.
  def test_a_usb_drive_on_the_system_domain_s_controller_is_refused
    usb_refused('unit.holder', /the device of drive disk0 is held by a configured domain/,
                media_source(USB_HOLDERS.merge('stick' => 'system')) + drive_window('disk0'))
  end

  # The drive records of docs/design-fiasco.md, "Drive records", as the domain library's
  # boot view hangs them on their devices and erx_dom_args writes them into each configured
  # row's creation (test/fixtures/dom_view_driver.c):
  # two USB drives on one controller and a block drive give the network domain, which holds
  # the controller, its two `usb` records and the disk domain
  # its one `block` record, and the media domain, which holds the windows, and every other
  # domain none. Seeded with erx_dom_args writing the drives of a device outside the gives
  # and dropping the records, and with ERX_BOOT_DRIVE_WORDS_MAX a byte short or long.
  def test_a_drive_record_goes_to_the_holder_of_the_drive_s_device_alone
    source, against = block_drive_source
    view = @codec.open('manifest', admit(source + drive_window('disk3', name: 'first') + drive_window('disk1', name: 'second'), against).bytes)
    row = ->(name) { packed_rows(view, 'domains').index { |domain| view.string(domain.fetch('name')) == name } }
    expected = ["drive #{row.call('network')} usb 1", "drive #{row.call('network')} usb 3", "drive #{row.call('disk')} block 0"]
    Dir.mktmpdir('drive-records-') do |work|
      runner = Erx::Runner.new(owner_root: work, log_dir: File.join(work, 'logs'))
      File.binwrite(manifest = File.join(work, 'manifest.bin'), view.bytes)
      lines = lambda do |driver|
        File.readlines(runner.run([driver, manifest], name: File.basename(driver), deadline: 30).fetch('log'), chomp: true)
      end
      driver = DomViewBuild.build(output: File.join(work, 'view'), runner: runner, name: 'view')
      found = lines.call(driver)
      assert_equal expected.sort, found.grep(/\Adrive /).sort, found.join("\n")
      length, bound = found.grep(/\Adrive_bound /).first.split.drop(1)
      assert_equal bound, length

      args = File.read(File.join(DomViewBuild::ROOT, 'liberx/system/dom_args.c'))
      seeded = lambda do |name, old, new|
        File.write(source = File.join(work, "#{name}.c"), args.sub(old) { new }.tap { |text| refute_equal args, text })
        lines.call(DomViewBuild.build(output: File.join(work, name), runner: runner, name: name, args: source)).grep(/\Adrive /)
      end
      neighbour = seeded.call('neighbour', 'entry = &lib->view.devices[give->devices[d].index];',
                              'entry = &lib->view.devices[(give->devices[d].index + 1) % lib->view.ndevices];')
      refute_equal expected.sort, neighbour.sort, 'drive records of a device outside the gives passed'
      assert_empty seeded.call('dropped', 'runs[count++] = (erx_boot_words_t){ out->drive_words[drive++], length };',
                               'drive++;'), 'dropped drive records passed'

      words = File.read(File.join(DomViewBuild::ROOT, 'include/erx/boot_words.h'))
      { 'short' => '- 1u', 'long' => '+ 1u' }.each do |name, change|
        FileUtils.mkdir_p(File.join(work, name, 'erx'))
        File.write(File.join(work, name, 'erx/boot_words.h'), words.sub('sizeof("4294967294"))', "sizeof(\"4294967294\") #{change})"))
        built = DomViewBuild.build(output: File.join(work, "bound-#{name}"), runner: runner, name: "bound-#{name}",
                                   include: File.join(work, name))
        length, bound = lines.call(built).grep(/\Adrive_bound /).first.split.drop(1)
        refute_equal bound, length, "a bound one byte #{name} passed"
      end
    end
  end

  # The driver-control service a block drive's holder serves the system domain, as every
  # unit holder does (docs/design-system.md, "The holder's driver-control facet"), and
  # its facet row granted to the system domain.
  def driver_control_rows(name)
    "service #{name}\n  server @domain.disk\n  interface driver_control\nfacet #{name}\n  grantee system\n" \
      "  service @service.#{name}\n  operations none\n  max_request 256\n  in_flight 1\n  reductions 100000\n" \
      "  period_ns 1000000000\n  max_heap_size 65536\n"
  end

  # A block drive's holder serves one driver-control service (docs/design-drives.md,
  # "Manifest rows"); a second, as if for another unit, is refused.
  def test_a_block_drive_s_holder_serves_one_driver_control_service
    source, against = block_drive_source
    admit(source + log_facet('@domain.disk') + driver_control_rows('disk_ctl'), against)
    refused(Erx::Manifest::Invalid, 'services', source + driver_control_rows('disk_ctl') + driver_control_rows('other_ctl'),
            against, message: /the holder of drive disk0, disk, holds nothing but .*, and its services row names it/)
  end

  # A block drive whose device is a PCIe function, as an NVMe or a virtio-blk-pci drive is:
  # its holder holds the function's pci facet (docs/design-drives.md, "Manifest rows"). A
  # pci facet of the holder of a device-tree block device is refused, since check_pcie
  # admits a pci facet only to the holder of a PCIe function.
  def test_a_block_drive_s_holder_holds_a_pci_facet_only_for_a_pcie_function
    function = extra_block_row.merge('selector' => 'pci', 'path' => '', 'bridge' => BRIDGE, 'device' => 3, 'base' => 0,
                                     'size' => 0, 'line' => 0, 'dma' => 'unconfined', 'dma_memory' => 1 << 20)
    source, against = block_drive_source(block: function, path: "#{BRIDGE}:0:3:0")
    admit(source + pcie_facet('pci', '@domain.disk', name: 'pci_disk'), against)
    tree, against = block_drive_source
    refused(Erx::Manifest::Invalid, 'facet.grantee', tree + pcie_facet('pci', '@domain.disk', name: 'pci_disk'),
            against, message: /a configured domain holds a pci facet exactly when it holds a pci device/)
  end

  # Who holds drive windows (docs/design-drives.md, "Manifest rows"): the media domain, the
  # server of the one media service, alone, and only with one.
  def test_a_drive_window_held_by_another_domain_than_the_media_domain_is_refused
    usb_refused('service.server', /the service named media is served by the holder of every drive window/,
                media_source + drive_window('disk0', holder: '@domain.web'))
    usb_refused('service.server', /the service named media is served by the holder of every drive window/,
                media_source + drive_window('disk0') + drive_window('disk1', name: 'other', holder: '@domain.web'))
    usb_refused('service.name', /a manifest with a drive window holds one service named media/,
                usb_source + drive_window('disk0', holder: '@domain.usb'))
    second = @source[/^domain usb\n(?:  .*\n)*/].sub("domain usb\n", "domain media_too\n") +
             "service media_too\n  name \"media\"\n  server @domain.media_too\n  interface files\n"
    usb_refused('service.name', /a manifest with a drive window holds one service named media/,
                media_source + second + drive_window('disk0'))
    usb_refused('service.name', /a manifest without a drive window holds no service named media/, media_source)
  end

  # The system domain serves no media: a crafted volume reaches a configured domain alone.
  def test_a_media_service_of_the_system_domain_is_refused
    served = changed(media_source).sub("server @domain.media\n  interface media", "server system\n  interface media")
    usb_refused('service.server', /the media service is served by a configured domain/,
                served + drive_window('disk0', holder: 'system'))
  end

  # The media domain holds an allow-list (docs/design-drives.md, "Manifest rows"): drive
  # windows, log facets and the media service; every other row that names it is refused.
  MEDIA_HOLDS = /the media domain, media, holds nothing but drive windows, log facets and the media service, and its/

  def test_a_media_domain_holds_drive_windows_log_facets_and_the_media_service
    usb_admit(media_source + drive_window('disk0') + log_facet('@domain.media'))
  end

  def test_a_media_domain_holding_a_unit_is_refused
    usb_refused('units', /#{MEDIA_HOLDS} units row names it/,
                media_source(USB_HOLDERS.merge('stick' => '@domain.media')) + drive_window('disk0'))
  end

  def test_a_media_domain_holding_a_window_of_another_role_is_refused
    usb_refused('windows', /#{MEDIA_HOLDS} windows row names it/,
                media_source + SPARE_UNIT + drive_window('disk0') + spare_window('@domain.media'),
                usb_platform(spare: [spare_block_row]))
  end

  # A system domain's tree, start or machine, rw, or the storage domain's packages: any
  # facet but the log's is refused, whoever serves it.
  def test_a_media_domain_holding_a_facet_but_the_log_s_is_refused
    %w[start machine].each do |tree|
      usb_refused('facets', /#{MEDIA_HOLDS} facets row names it/,
                  media_source + drive_window('disk0') + files_facet(tree, '@domain.media', rights: 'rw'))
    end
    usb_refused('facets', /#{MEDIA_HOLDS} facets row names it/,
                media_source + drive_window('disk0') + files_facet('packages', '@domain.media'))
    # A facet of the log interface is the log's only as the service named log.
    usb_refused('facets', /#{MEDIA_HOLDS} facets row names it/,
                media_source + drive_window('disk0') + "service slog\n  server @domain.storage\n  interface log\n" +
                log_facet('@domain.media').sub('@service.log', '@service.slog').sub('operations write', 'operations none'))
  end

  def test_a_media_domain_serving_another_service_is_refused
    usb_refused('services', /#{MEDIA_HOLDS} services row names it/,
                media_source + drive_window('disk0') + "service media_more\n  server @domain.media\n  interface files\n")
  end

  # Nothing runs from a drive (docs/design-drives.md, "Links and rights"): no media grant is rx.
  def test_a_media_facet_granting_rx_is_refused
    usb_admit(media_source + drive_window('disk0') + files_facet('media', '@session.system', rights: 'ro'))
    # media_rights has no rx, so the row's parameter is refused as any value outside its
    # declared members is (abi/services/media.txt).
    error = assert_raises(Erx::ABI::SchemaError) do
      usb_admit(media_source + drive_window('disk0') + files_facet('media', '@session.system', rights: 'rx'))
    end
    assert_match(/parameter rights is one of ro, rw/, error.message)
  end

  # Nothing in a service tree runs (docs/design-app-trees.md, AT5): svc_rights has no rx,
  # so a facet row of an svc service is admitted ro or rw and refused rx, as any value
  # outside the enum's declared members is (abi/services/svc.txt).
  def test_an_svc_facet_granting_rx_is_refused
    tree = "service ntp_tree\n  server @domain.web\n  interface svc\n"
    %w[ro rw].each { |rights| admit(@source + tree + files_facet('ntp_tree', '@session.system', rights: rights)) }
    error = assert_raises(Erx::ABI::SchemaError) do
      admit(@source + tree + files_facet('ntp_tree', '@session.system', rights: 'rx'))
    end
    assert_match(/parameter rights is one of ro, rw/, error.message)
  end

  # The system domain's own service trees, the start table's and the machine's, are
  # trees of the svc interface (docs/design-app-trees.md, "Interfaces").
  def test_the_start_and_machine_services_are_svc_trees
    view = @codec.open('manifest', admit.bytes)
    services = view.count('services').times.map { |index| view.fetch('services', index) }
    interfaces = services.to_h { |row| [view.string(row.fetch('name')), row.fetch('interface')] }
    svc = @codec.schema.services.find { |service| service.fetch(:name) == 'svc' }.fetch(:number)
    assert_equal({ 'machine' => svc, 'start' => svc }, interfaces.slice('machine', 'start'))
  end

  # A service tree of interface svc named name served by a configured domain, under the
  # source alias as, since two rows may share a name but not an alias.
  def svc_tree(name, server: '@domain.web', as: name)
    "service #{as}\n  name \"#{name}\"\n  server #{server}\n  interface svc\n"
  end

  # No two service trees share a name (docs/design-app-trees.md, AT9): two services of
  # interface svc named wifi on two servers are refused, as one beside a files service of
  # that name is not, since only svc services are trees at /svc.
  def test_two_svc_services_of_one_name_are_refused
    admit(@source + svc_tree('wifi') + "service wifi_files\n  name \"wifi\"\n  server @domain.network\n  interface files\n")
    refused(Erx::Manifest::Invalid, 'service.name',
            @source + svc_tree('wifi') + svc_tree('wifi', server: '@domain.network', as: 'wifi_network'),
            message: /two services of interface svc share the name wifi/)
  end

  # Every start row's name is a principal's, so no svc service is named like a principal
  # (AT9): beside a principal wifi, which takes one of the system principal's domains and
  # 36 MiB of its memory, a service tree named wifi is refused, and one named otherwise is
  # admitted.
  def test_an_svc_service_named_like_a_principal_is_refused
    system = "principal system\n  memory 353419264\n  grant @share.users\n  domains 8\n"
    wifi = "principal wifi\n  memory 37748736\n  grant @share.users\n  domains 1\n  names 1\n" \
           "  default_limits @limits.native\n  ceiling_limits @limits.native\n"
    source = changed(@source.sub(system, "principal system\n  memory 315670528\n  grant @share.users\n  domains 7\n")) + wifi
    admit(source + svc_tree('bluetooth'))
    refused(Erx::Manifest::Invalid, 'service.name', source + svc_tree('wifi'),
            message: /service wifi of interface svc is named like principal wifi/)
  end

  # The system domain holds no svc grant (AT8): a facet row granting a service tree of a
  # configured domain to the system domain is refused, and one granting it to root's
  # session template is admitted.
  def test_an_svc_facet_granted_to_the_system_domain_is_refused
    admit(@source + svc_tree('bluetooth') + files_facet('bluetooth', '@session.system'))
    refused(Erx::Manifest::Invalid, 'facet.grantee', @source + svc_tree('bluetooth') + files_facet('bluetooth', 'system'),
            message: /the system domain holds no facet of interface svc: bluetooth/)
  end

  # Property 4: budgets, grants and the root startup rule.
  # The development manifest's system_baseline, which the sums below fit against.
  def baseline = Integer(@source[/^  system_baseline (\d+)$/, 1])
  def root_memory = Integer(@source[/^  root_memory (\d+)$/, 1])
  # The apps row's budget, which property 4 counts within root_memory.
  def apps_memory = Integer(@source[/^apps\n  memory (\d+)$/, 1])
  # The development manifest with the system principal's budget set to bytes.
  def with_system_memory(bytes) = changed(@source.sub(/^(principal system\n  memory )\d+$/) { "#{Regexp.last_match(1)}#{bytes}" })

  def test_budgets_over_root_memory_are_refused
    refused(Erx::Manifest::Invalid, 'principals.memory', with_system_memory(root_memory - baseline + 4096),
            message: /principal budgets, the apps budget, system baseline and device/)
  end

  # The platform's DMA reservations, which property 4 counts beside the budgets.
  # The memory of the devices of the units the development manifest places: an unplaced
  # unit's device, such as QEMU virt's display unit, is in no device row and gets none.
  def device_memory
    placed = @source.scan(/^  placement "([^"]+)"$/).flatten
    @platform.fetch('units').select { |unit| placed.include?(unit.fetch('key')) }
             .sum { |unit| unit.fetch('devices').sum { |device| device.fetch('dma_memory') } }
  end

  # Principal and baseline fit with the devices' reservations exactly, and one page
  # more does not.
  def test_device_memory_counts_against_root_memory
    assert admit(with_system_memory(root_memory - baseline - device_memory - apps_memory))
    refused(Erx::Manifest::Invalid, 'principals.memory',
            with_system_memory(root_memory - baseline - device_memory - apps_memory + 4096), message: /principal budgets, the apps budget, system baseline and device/)
  end

  def test_a_principal_domain_quota_is_refused
    refused(Erx::Manifest::Invalid, 'principals.domains', changed(@source.sub(/^(principal system\n(?:  .*\n)*?  domains )(\d+)$/) { "#{Regexp.last_match(1)}#{Integer(Regexp.last_match(2)) + 1}" }),
            message: /principal domain quotas and the apps row's max exceed/)
  end

  # A principal row of the given name granted the share named share, small enough that
  # the development manifest's budgets still fit.
  def principal_row(name, share)
    "principal #{name}\n  memory 1048576\n  grant @share.#{share}\n  domains 0\n  names 1\n" \
      "  default_limits @limits.native\n  ceiling_limits @limits.native\n"
  end

  # A grant is a cap and promises no minimum, so principals whose caps together exceed
  # `users` are accepted; one principal's cap above `users` is not.
  def test_principal_grants_may_oversubscribe_users
    assert admit(changed(@source.sub("principal system\n", "#{principal_row('guest', 'users')}principal system\n")))
  end

  def test_a_principal_grant_over_users_is_refused
    over = @source.sub("principal system\n", "#{principal_row('guest', 'system')}principal system\n")
    refused(Erx::Manifest::Invalid, 'principal.grant', changed(over), message: /principal grant exceeds users/)
  end

  def test_shares_over_the_root_rate_are_refused
    refused(Erx::Manifest::Invalid, 'machine.shares', changed(@source.sub('quota_ns 31000000', 'quota_ns 40000000')),
            message: /system and users exceed the root CPU rate/)
  end

  # The development manifest with root_memory set to bytes.
  def with_root_memory(bytes) = changed(@source.sub(/^(  root_memory )\d+$/) { "#{Regexp.last_match(1)}#{bytes}" })
  def ram_less_the_reserve = @platform.fetch('ram_bytes') - @platform.fetch('fiasco_reserve')

  def test_root_memory_over_ram_less_the_reserve_is_refused
    refused(Erx::Manifest::Invalid, 'root_startup', with_root_memory(ram_less_the_reserve + 4096), message: /fiasco_reserve/)
  end

  def test_loadable_segments_and_baseline_over_root_memory_are_refused
    against = context do |arguments|
      image = arguments.fetch(:catalog).last.fetch('image')
      image['span'] = 536_870_912 + 4096
      image.fetch('segments') << { 'file_offset' => 8192, 'mem_offset' => 4096, 'file_size' => 0,
                                   'mem_size' => 536_870_912, 'prot' => @codec.member('prot', 'r'), 'flags' => 0 }
    end
    refused(Erx::Manifest::Invalid, 'root_startup', @source, against, message: /loadable/)
  end

  def test_a_platform_without_the_reserve_is_not_accepted
    against = context(platform: platform_with { |value| value.delete('fiasco_reserve') })
    refused(Erx::Manifest::Unsupported, 'root_startup', @source, against,
            message: /the platform record states no RAM size and fiasco_reserve to/)
  end

  def test_a_reserve_that_leaves_no_ram_is_not_accepted
    against = context(platform: platform_with { |value| value['fiasco_reserve'] = value.fetch('ram_bytes') })
    refused(Erx::Manifest::Unsupported, 'root_startup', @source, against,
            message: /the platform record states no RAM size and fiasco_reserve to/)
  end

  # The archive rule (RootStartup.check_archive) against boots of the development image
  # from the development logs (the Apple M3 Max host, HVF, QEMU 11.1.3): each boot's RAM,
  # Fiasco's kernel memory, the archive, root_memory, the root's pool pages and image.
  # Each declared the development manifest's 1.25 MiB of devices' memory, so each took
  # a 2 MiB contiguous pool.
  # The root's own rule (root.c, root_memory_fits) passed the boot when the pool's pages
  # and the image held root_memory.
  Boot = Data.define(:ram, :reserve, :archive, :root_memory, :pool_pages, :image) do
    def offer = (pool_pages * 4096) + image
    def booted? = offer >= root_memory
  end
  MIB = 1 << 20
  BOOTS = {
    # The programs suite's test image before it outgrew root_memory 186.25 MiB.
    fit: Boot.new(ram: 256 * MIB, reserve: 16 * MIB, archive: 0x2f8d000, root_memory: 195_297_280,
                  pool_pages: 46_461, image: 0x4d7000),
    # The same suite 144 KiB later, which the root refused 64 KiB short.
    short: Boot.new(ram: 256 * MIB, reserve: 16 * MIB, archive: 0x2fb1000, root_memory: 195_297_280,
                    pool_pages: 46_425, image: 0x4d7000),
    # That archive with root_memory lowered to 184.75 MiB.
    lowered: Boot.new(ram: 256 * MIB, reserve: 16 * MIB, archive: 0x2fb1000, root_memory: 193_724_416,
                      pool_pages: 46_425, image: 0x4d7000),
    # A small machine (the footprint measurement's 112 MiB) and a large one (768 MiB),
    # whose page index is a half and four times the 256 MiB machine's.
    small: Boot.new(ram: 112 * MIB, reserve: 8 * MIB, archive: 0x1a42000, root_memory: 50_593_792,
                    pool_pages: 17_392, image: 0x4af000),
    large: Boot.new(ram: 768 * MIB, reserve: 48 * MIB, archive: 0x2d5b000, root_memory: 470_024_192,
                    pool_pages: 168_385, image: 0x4c5000)
  }.freeze

  # How far below a boot's own figure the packer may put what the root is given: the
  # record's root_withheld errs high by 388 KiB, and this leaves a little more.
  TOLERANCE = 512 << 10

  BOOT_DMA_MEMORY = 1_310_720

  # The record's root_withheld, on the boot's machine, with the boots' devices' memory.
  def machine(boot)
    platform = platform_with { |value| value.merge!('ram_bytes' => boot.ram, 'fiasco_reserve' => boot.reserve) }
    Erx::Manifest::RootStartup.archive_machine(platform).merge(dma_memory: BOOT_DMA_MEMORY)
  end

  def check_archive(boot)
    Erx::Manifest::RootStartup.check_archive(archive_bytes: boot.archive, root_memory: boot.root_memory, **machine(boot))
  end

  def test_the_packer_refuses_the_archive_the_root_refused
    boot = BOOTS.fetch(:short)
    refute_predicate boot, :booted?
    error = assert_raises(Erx::Manifest::Invalid) { check_archive(boot) }
    assert_equal 'root_startup', error.field
    assert_match(/the archive \(47\.69 MiB\) and root_memory \(186\.25 MiB\) exceed the 233\.50 MiB .* by 452 KiB\z/,
                 error.message)
  end

  # What the packer expects the root to be given is never more than a boot gave it, so
  # it never passes an archive the root refuses, and never more than TOLERANCE less.
  def test_the_packer_expects_at_most_what_each_boot_gave
    BOOTS.each do |name, boot|
      label = name.to_s
      kept = Erx::Manifest::RootStartup.boot_kept(archive_bytes: boot.archive, **machine(boot))
      assert_includes (boot.offer - TOLERANCE)..boot.offer, boot.ram - boot.reserve - boot.archive - kept, label
    end
  end

  # So the packer refuses every archive its root refused, and passes every one that
  # booted with more than TOLERANCE to spare.
  def test_the_packer_agrees_with_each_boot_outside_the_tolerance
    BOOTS.each do |name, boot|
      label = name.to_s
      if !boot.booted?
        assert_raises(Erx::Manifest::Invalid, label) { check_archive(boot) }
      elsif boot.offer - boot.root_memory > TOLERANCE
        assert_kind_of Erx::Manifest::RootStartup::ArchiveRoom, check_archive(boot), label
      end
    end
  end

  # The boot's side (RootStartup.check_boot), which the production image suite applies to
  # each of its boots: none of these kept more than the record's root_withheld and the
  # page index, and each kept more than a root_withheld TOLERANCE smaller.
  def test_each_boot_kept_no_more_than_the_packer_counts
    BOOTS.each do |name, boot|
      label = name.to_s
      figures = { archive_bytes: boot.archive, pool_pages: boot.pool_pages, image_bytes: boot.image, **machine(boot) }
      assert_nil Erx::Manifest::RootStartup.check_boot(**figures), label
      short = figures.merge(root_withheld: figures.fetch(:root_withheld) - TOLERANCE)
      assert_raises(Erx::Error, label) { Erx::Manifest::RootStartup.check_boot(**short) }
    end
  end

  # The pool is the smallest power of two that holds the devices' memory, from 2 MiB to
  # 16 MiB, as erx_fiasco_contig_order sizes it (FiascoVmTest checks the two agree).
  def test_the_contiguous_pool_holds_the_devices_memory_in_a_power_of_two
    pool = ->(bytes) { Erx::Manifest::RootStartup.contiguous_pool_bytes(bytes) }
    { 0 => 2 * MIB, BOOT_DMA_MEMORY => 2 * MIB, 2 * MIB => 2 * MIB, (2 * MIB) + 4096 => 4 * MIB,
      9 * MIB => 16 * MIB, 16 * MIB => 16 * MIB }.each { |bytes, expected| assert_equal expected, pool.call(bytes), bytes }
    assert_raises(Erx::Error) { pool.call((16 * MIB) + 4096) }
  end

  # A manifest whose devices ask for a 16 MiB pool
  # keeps 14 MiB more than one whose pool is 2 MiB, and the packer counts it, so an
  # archive that fits with the small pool is refused with the large one.
  def test_the_packer_counts_the_pool_the_devices_memory_takes
    boot = BOOTS.fetch(:lowered)
    figures = { archive_bytes: boot.archive, **machine(boot) }
    small = Erx::Manifest::RootStartup.boot_kept(**figures)
    assert_equal 14 * MIB, Erx::Manifest::RootStartup.boot_kept(**figures, dma_memory: 9 * MIB) - small
    room = check_archive(boot)
    assert_equal machine(boot).values_at(:ram_bytes, :fiasco_reserve).reduce(:-),
                 room.archive_max_bytes + room.root_memory + room.kept_bytes, 'the room is what the machine leaves'
    assert_equal boot.archive, room.archive_bytes
    assert_raises(Erx::Manifest::Invalid) do
      Erx::Manifest::RootStartup.check_archive(archive_bytes: boot.archive, root_memory: boot.root_memory,
                                               **machine(boot), dma_memory: 9 * MIB)
    end
  end

  def test_the_report_states_the_devices_memory
    assert_equal device_memory, admit.report.fetch('dma_memory')
  end

  # Each device's memory is one contiguous object, and every device's is made from one
  # pool of at most 16 MiB.
  def test_a_device_memory_past_mem_contiguous_max_is_refused
    max = @codec.constant('mem_contiguous_max')
    source, against = with_extra_device(role: 'ordinary', dma: 'unconfined', flags: 1, dma_memory: max + 4096)
    refused(Erx::Manifest::Invalid, 'devices.dma_memory', source, against, message: /mem_contiguous_max/)
  end

  def test_devices_memory_past_the_contiguous_pool_is_refused
    over = Erx::Manifest::RootStartup::CONTIGUOUS_POOL_MAX_BYTES - device_memory + 4096
    source, against = with_extra_device(role: 'ordinary', dma: 'unconfined', flags: 1, dma_memory: over)
    refused(Erx::Manifest::Invalid, 'devices.dma_memory', source, against, message: /contiguous pool/)
  end

  def test_a_platform_without_root_withheld_packs_nothing
    platform = platform_with { |value| value.delete('root_withheld') }
    error = assert_raises(Erx::Manifest::Unsupported) { Erx::Manifest::RootStartup.archive_machine(platform) }
    assert_match(/root_withheld/, error.message)
  end

  # Property 5: names.
  def test_a_host_name_that_is_no_identifier_is_refused
    refused(Erx::Manifest::Invalid, 'machine.host', @source.sub('host "erxos"', 'host "Not An Identifier"'),
            message: /host name is not a system identifier/)
  end

  def test_a_host_name_with_a_dot_is_refused
    refused(Erx::Manifest::Invalid, 'machine.host', @source.sub('host "erxos"', 'host "a.b"'),
            message: /host name is not a system identifier/)
  end

  def test_two_services_sharing_a_name_are_refused
    second = "service other\n  name \"probe\"\n  server system\n  interface 2\n"
    refused(Erx::Manifest::Invalid, 'service.name', @source + SERVICE + second, message: /two services of one server share a name/)
  end

  # Property 6: no JIT in the root.
  def test_a_root_image_with_jit_is_refused
    against = context do |arguments|
      arguments.fetch(:catalog).last.fetch('image')['flags'] |= @codec.member('image_flags', 'jit')
    end
    refused(Erx::Manifest::Invalid, 'catalog.root', @source, against, message: /root image has incompatible ABI or JIT authority/)
  end

  # Property 7: no sealing secret.
  def test_a_sealing_mode_is_refused
    refused(Erx::Manifest::Invalid, 'machine.sealing', @source.sub('sealing none', 'sealing device'),
            message: /no sealing service exists to hold a sealing secret/)
  end

  def test_a_sealed_entry_is_refused
    against = context do |arguments|
      arguments.fetch(:catalog).first['flags'] |= @codec.member('entry_flags', 'seal')
    end
    refused(Erx::Manifest::Invalid, 'catalog.flags', @source, against, message: /M11/)
  end

  def test_a_tpm_is_refused
    source, against = with_extra_device(role: 'tpm')
    refused(Erx::Manifest::Invalid, 'devices.role', source, against, message: /M11/)
  end

  # Property 8: the UARTs and the windows.
  def test_the_console_and_host_link_must_differ
    refused(Erx::Manifest::Invalid, 'machine.hostlink', @source.sub('hostlink "/pl011@9040000"', 'hostlink "/pl011@9000000"'),
            message: /console and host link must differ/)
  end

  def test_an_unassigned_console_is_refused
    source = @source.sub("unit console\n  placement \"console-uart\"\n  holder system\n", '')
    refused(Erx::Manifest::Invalid, 'machine.console', source, message: /UART is not placed/)
  end

  # Property 8's line clause (docs/design-shared-devices.md, "Lines inside a domain"): the
  # console and the host link each start the owner of their UART's line, and a line has
  # one binder, so the host link's PL011 moved onto the console's line, and into the
  # console's unit, which the system domain holds whole and the unit rule therefore
  # accepts, is refused. The shipped records, whose two UARTs are on lines of their own,
  # pass every other test here.
  def test_a_console_and_host_link_on_one_line_are_refused
    platform = platform_with do |value|
      units = value.fetch('units')
      hostlink = units.find { |unit| unit.fetch('key') == 'hostlink-uart' }
      console = units.find { |unit| unit.fetch('key') == 'console-uart' }.fetch('devices')
      console << hostlink.fetch('devices').first.merge('line' => console.first.fetch('line'))
      units.delete(hostlink)
    end
    source = ManifestContextFixture.substitute(@source, /^unit hostlink\n  placement "hostlink-uart"\n  holder system\n/, '')
    refused(Erx::Manifest::Invalid, 'machine.hostlink', source, context(platform: platform),
            message: /share interrupt line 33/)
  end

  # The Raspberry Pi 4's development manifest and platform record
  # (docs/design-header-io.md), whose header map gives GPIO 14 and 15 to the console and
  # GPIO 4 and 5 to the host link. pi_source leaves out the shipped manifest's gpio unit,
  # which the system domain holds for the on-board pins (docs/design-header-io.md,
  # "On-board pins"), so each test places gpio itself.
  def pi_shipped = Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT)
  def pi_source = pi_shipped.sub(PI_GPIO_UNIT, '')
  PI_GPIO_UNIT = "unit gpio\n  placement \"gpio\"\n  holder system\n"
  def pi_record = JSON.parse(File.read(File.join(ROOT, 'config/platforms/raspi4b.json')))
  def pi_context(record = pi_record) = context(platform: record)
  def pi_unit(name, holder) = "unit #{name}\n  placement \"#{name}\"\n  holder #{holder}\n"

  # The Pi's manifest with the framebuffer unit moved from the display domain to the
  # system domain, so the display domain holds whatever else a test gives it alone.
  def pi_display_holding_nothing
    row = pi_unit('framebuffer', '@domain.display')
    assert_includes pi_source, row
    pi_source.sub(row, pi_unit('framebuffer', 'system'))
  end

  # The clock rule (docs/design-header-io.md, "Clocks"): BSC1 and SPI0 divide the core
  # clock, which their rows carry as the PL011s carry theirs, so a manifest placing the
  # i2c and spi units is accepted.
  def test_the_pi_bus_units_carry_the_core_clock
    admit(pi_shipped + pi_unit('i2c', 'system') + pi_unit('spi', 'system'), pi_context)
  end

  # The Pi's record with change applied to the device at path in unit key.
  def pi_record_with(key, path)
    pi_record.tap do |record|
      yield record.fetch('units').find { |unit| unit.fetch('key') == key }.fetch('devices')
                  .find { |device| device.fetch('path') == path }
    end
  end

  # A row of a clocked kind without its clock, here BSC1's, would give its driver no rate
  # to divide.
  def test_a_bus_row_must_carry_its_clock
    [nil, 0, -1, '500000000'].each do |clock|
      record = pi_record_with('i2c', '/soc/i2c@7e804000') do |bsc1|
        clock.nil? ? bsc1.delete('clock') : bsc1['clock'] = clock
      end
      refused(Erx::Manifest::Invalid, 'context.platform.devices', pi_source + pi_unit('i2c', 'system'),
              pi_context(record), message: %r{brcm,bcm2835-i2c device "/soc/i2c@7e804000" lacks its clock})
    end
  end

  # A kind is its role and its compatible string together: BSC0, an I2C controller of
  # role ordinary that no driver drives, carries no clock, and neither does SPI3.
  def test_a_bus_row_of_no_kind_carries_no_clock
    { 'i2c' => '/soc/i2c@7e205000', 'spi' => '/soc/spi@7e204600' }.each do |key, path|
      record = pi_record_with(key, path) { |device| device['clock'] = 500_000_000 }
      refused(Erx::Manifest::Invalid, 'context.platform.devices', pi_source + pi_unit(key, 'system'),
              pi_context(record), message: /#{Regexp.escape(path)}" carries a clock/)
    end
  end

  # Property 8's pin controller clause (docs/design-header-io.md, "The pin controller and
  # the console"): whoever holds the GPIO page sets the console's pin functions, so the
  # pin controller's unit, gpio, is held by the system domain (the shipped manifest) or by a
  # domain of its own, which no row names but its units on the GPIO page, the services of
  # the interfaces they back and the boot order. Unplaced, it has no holder to apply the
  # rows of the devices the manifest places (docs/design-pinctrl.md), so it is refused.
  def test_the_pin_controller_unit_is_held_by_the_system_or_alone
    refused(Erx::Manifest::Invalid, 'context.platform.pins', pi_source, pi_context,
            message: %r{pin controller gpio's device /soc/gpio@7e200000 is not placed})
    assert_includes pi_shipped, PI_GPIO_UNIT
    admit(pi_shipped, pi_context)
    admit(pi_source + pi_pins_domain + pi_unit('gpio', '@domain.pins'), pi_context)
  end

  # A domain of the Pi's manifest, pins, that holds, serves and runs nothing until a test
  # gives it something.
  def pi_pins_domain
    domain = pi_source[/^domain display\n(?:  .*\n)*/]
    refute_nil domain
    domain.sub('domain display', 'domain pins')
  end

  # The display domain, holding no other unit once the framebuffer is the system domain's,
  # still serves the display service of the windows interface, so it may not hold gpio.
  def test_a_pin_controller_holder_serving_a_service_is_refused
    refused(Erx::Manifest::Invalid, 'unit.holder', pi_display_holding_nothing + pi_unit('gpio', '@domain.display'),
            pi_context, message: /domain display .*a row of services \(display\) names it/)
  end

  # A domain holding gpio and a partition window, here the SD card's data window, may
  # not hold gpio.
  def test_a_pin_controller_holder_with_a_window_is_refused
    window = "window seeded\n  holder @domain.pins\n  device \"/emmc2bus/mmc@7e340000\"\n  role data\n  partition 0\n" \
             "  image none\n"
    unheld = changed(pi_source.sub(/^window data\n(?:  .*\n)*/, ''))
    refused(Erx::Manifest::Invalid, 'unit.holder', unheld + pi_pins_domain + window + pi_unit('gpio', '@domain.pins'),
            pi_context, message: /domain pins .*a row of windows names it/)
  end

  # A domain holding gpio that is introduced to another, so that the other's processes may
  # message it, may not hold gpio.
  def test_a_pin_controller_holder_introduced_to_another_is_refused
    refused(Erx::Manifest::Invalid, 'unit.holder',
            "#{pi_source}#{pi_pins_domain}#{pi_unit('gpio', '@domain.pins')}introduce @domain.pins @domain.display\n",
            pi_context, message: /domain pins .*a row of introductions names it/)
  end

  # A domain holding gpio that is granted a facet of another service, here the network
  # domain's net service, may not hold gpio: the grant is a path in from that service.
  def test_a_pin_controller_holder_granted_a_facet_is_refused
    facet = pi_source[/^facet net\n(?:  .*\n)*/]
    refute_nil facet
    grant = facet.sub('facet net', 'facet pins_net').sub(/^  grantee .*$/, '  grantee @domain.pins')
    refused(Erx::Manifest::Invalid, 'unit.holder', pi_source + pi_pins_domain + grant + pi_unit('gpio', '@domain.pins'),
            pi_context, message: /domain pins .*a row of facets \(pins_net\) names it/)
  end

  # A session runs from a template, which is no domain row, so no session holds gpio: a
  # unit naming a session template as its holder is refused before the clause is reached.
  def test_a_session_holds_no_pin_controller
    refused(Erx::Manifest::Invalid, 'unit.holder', pi_source + pi_unit('gpio', '@session.system'), pi_context,
            message: /names neither the system domain nor a configured domain/)
  end

  # A domain holding gpio and another unit, here i2c, whose registers lie off the GPIO
  # page, may not hold gpio.
  def test_a_domain_holding_the_pin_controller_and_more_is_refused
    refused(Erx::Manifest::Invalid, 'unit.holder',
            pi_source + pi_pins_domain + pi_unit('gpio', '@domain.pins') + pi_unit('i2c', '@domain.pins'), pi_context,
            message: /unit gpio .*domain pins .*a row of units \(i2c\) names it/)
  end

  # The clause finds the pin controller's units by its register page, not its path: a
  # second row on the GPIO page under another path, in the i2c unit, makes that unit one
  # too, so the display domain may not hold it beside the framebuffer.
  def test_a_second_row_on_the_pin_controllers_page_is_caught
    record = pi_record
    units = record.fetch('units')
    gpio = units.find { |unit| unit.fetch('key') == 'gpio' }.fetch('devices').first
    units.find { |unit| unit.fetch('key') == 'i2c' }.fetch('devices') <<
      gpio.merge('path' => '/soc/gpiomem@7e200000', 'placement_key' => 'gpiomem')
    refused(Erx::Manifest::Invalid, 'unit.holder', pi_shipped + pi_unit('i2c', '@domain.display'),
            pi_context(record), message: %r{unit i2c reaches pin controller /soc/gpio@7e200000})
  end

  # The network stack runs in the system domain in Phase 1, over the device its unit
  # places there (docs/design-fiasco.md, "Device records").
  def test_a_network_device_is_accepted
    source, against = with_extra_device(role: 'network')
    admit(source, against)
  end

  # The display's device on QEMU virt, a virtio-mmio transport of the gpu role, is held as
  # any unconfined DMA device is in a development build (docs/design-fiasco.md, "Device records").
  def test_a_gpu_device_is_accepted
    admit(*with_extra_device(role: 'gpu', dma: 'unconfined', flags: 1, dma_memory: 1_048_576))
  end

  # A framebuffer row (docs/design-device-tree.md, "The framebuffer record"): /chosen and
  # simple-framebuffer, with no line or flags, its window whole pages clear of every
  # register window: 0x7e000000, 4 MiB, above QEMU virt's devices.
  FRAMEBUFFER = { role: 'framebuffer', path: '/chosen', compatible: 'simple-framebuffer', line: 0, flags: 0,
                  base: 0x7e00_0000, size: 0x40_0000 }.freeze

  def test_a_framebuffer_window_clear_of_every_register_window_is_accepted
    admit(*with_extra_device(**FRAMEBUFFER))
  end

  # Seeded faults for check_framebuffer_windows: a window over a placed device's registers,
  # the console UART's page, and one over the registers of a device no unit of the manifest
  # places, which the firmware's tree could still hand the window's holder.
  def test_a_framebuffer_window_meeting_registers_is_refused
    console = @platform.fetch('units').first.fetch('devices').first
    source, against = with_extra_device(**FRAMEBUFFER, base: console.fetch('base') & ~0xfff, size: 0x1000)
    refused(Erx::Manifest::Invalid, 'devices.base', source, against, message: /meets #{Regexp.escape(console.fetch('path'))}'s/)

    source, = with_extra_device(**FRAMEBUFFER)
    framebuffer = with_extra_device_platform(**FRAMEBUFFER)
    unplaced = console.merge('path' => '/unplaced@7e3ff000', 'base' => 0x7e3f_f000, 'size' => 0x10,
                             'placement_key' => 'unplaced')
    framebuffer.fetch('units') << { 'key' => 'unplaced', 'devices' => [unplaced] }
    refused(Erx::Manifest::Invalid, 'devices.base', source, context(platform: framebuffer),
            message: %r{meets /unplaced@7e3ff000's})

    # The console's selector written as the codec's number is the same device-tree row.
    numbered = with_extra_device_platform(**FRAMEBUFFER, base: console.fetch('base') & ~0xfff, size: 0x1000)
    numbered.fetch('units').first.fetch('devices').first['selector'] = @codec.member('mf_selector', 'dt')
    refused(Erx::Manifest::Invalid, 'devices.base', source, context(platform: numbered), message: /meets/)

    # A device starting at the window's end does not meet it.
    after = with_extra_device_platform(**FRAMEBUFFER)
    after.fetch('units') << { 'key' => 'after', 'devices' => [unplaced.merge('path' => '/after@7e400000', 'base' => 0x7e40_0000,
                                                                             'placement_key' => 'after')] }
    admit(source, context(platform: after))
  end

  # A window over the platform's RAM, and a framebuffer row no manifest places, which is
  # checked all the same.
  def test_a_framebuffer_window_meeting_ram_or_unplaced_is_refused
    refused(Erx::Manifest::Invalid, 'devices.base', *with_extra_device(**FRAMEBUFFER, base: @platform.fetch('ram_first')),
            message: /RAM/)
    unplaced = with_extra_device_platform(**FRAMEBUFFER, size: 0x40_0800)
    refused(Erx::Manifest::Invalid, 'context.platform.devices', @source, context(platform: unplaced), message: /framebuffer/)
  end

  def test_a_framebuffer_row_of_another_shape_is_refused
    [{ path: '/framebuffer@0' }, { compatible: 'virtio,mmio' }, { line: 40 }, { flags: 1 },
     { size: 0x40_0800 }, { base: 0x7e00_0800 }, { dma: 'unconfined', dma_memory: 4096 }].each do |change|
      refused(Erx::Manifest::Invalid, 'context.platform.devices', *with_extra_device(**FRAMEBUFFER, **change),
              message: /framebuffer/)
    end
  end

  def test_a_vault_window_is_refused
    refused(Erx::Manifest::Invalid, 'window.role', @source + window(role: 'vault'), message: /M11/)
  end

  def test_a_window_held_by_no_configured_domain_is_refused
    refused(Erx::Manifest::Invalid, 'window.holder', @source + window(role: 'data', partition: 0, holder: '@domain.absent'),
            message: /names neither the system domain nor a configured domain/)
  end

  def test_a_window_on_no_placed_device_is_refused
    refused(Erx::Manifest::Invalid, 'window.device', @source + window(role: 'data', partition: 0, device: '/absent@0'),
            message: /window names no block or USB device the manifest places/)
  end

  def test_a_window_on_a_device_that_is_no_block_device_is_refused
    refused(Erx::Manifest::Invalid, 'window.device', @source + window(role: 'data', partition: 0, device: '/pl011@9000000'),
            message: /window names no block or USB device the manifest places/)
  end

  def test_two_windows_on_one_partition_are_refused
    refused(Erx::Manifest::Invalid, 'window.partition', @source + window(role: 'data', partition: 0),
            message: /two windows name one role, partition and drive of a device/)
  end

  def test_a_fixed_role_must_carry_partition_zero
    refused(Erx::Manifest::Invalid, 'window.partition', @source + window(role: 'boot_a', partition: 2),
            message: /a window of a fixed role names partition 0/)
  end

  # PW1 as the manifest states it: the slot writer's windows, the boot and system
  # partitions of both slots and the records, are the system domain's alone.
  def test_a_slot_writer_window_held_by_a_configured_domain_is_refused
    %w[boot_a boot_b system_a system_b boot_selection reset_count].each do |role|
      source = changed(@source.sub(/(window #{role}\n)  holder system/, "\\1  holder @domain.storage"))
      refused(Erx::Manifest::Invalid, 'window.holder', source, message: /only the system domain, the slot writer, holds the slot windows/)
    end
  end

  # The one system window: on the slot's system partition, held by the storage domain
  # that holds the block device and so runs the block driver serving it, read-only by
  # its role (erx_blk_table_tests).
  def test_the_development_manifest_gives_one_system_window_to_the_storage_domain
    view = @codec.open('manifest', admit.bytes)
    windows = (0...view.count('windows')).map { |at| view.fetch('windows', at) }
    system = windows.select { |row| row.fetch('role') == @codec.member('mf_window_role', 'system') }
    storage = (0...view.count('domains')).find { |at| view.string(view.fetch('domains', at).fetch('name')) == 'storage' }
    assert_equal [[storage, 0]], system.map { |row| row.values_at('holder', 'partition') }
  end

  def test_a_second_system_window_is_refused
    second = window(role: 'system', partition: 0, holder: '@domain.storage').sub('window seeded', 'window system_again')
    refused(Erx::Manifest::Invalid, 'window.partition', @source + second, message: /two windows name one role, partition and drive/)
  end

  # Only the block device's holder runs the driver that serves the window, so a system
  # window named for the system domain or for any other domain would reach no holder.
  def test_a_system_window_held_by_another_domain_than_the_block_holder_is_refused
    %w[system @domain.network].each do |holder|
      source = changed(@source.sub(/(window system\n)  holder @domain.storage/, "\\1  holder #{holder}"))
      refused(Erx::Manifest::Invalid, 'window.holder', source, message: /a system window is held by the configured domain that holds its/)
    end
  end

  # Property 19's eighth clause: the system tree's service is served by the system
  # window's holder, and only the derived rows grant it.
  def test_the_system_service_is_served_by_the_system_window_s_holder
    source = changed(@source.sub("service system\n  server @domain.storage", "service system\n  server @domain.network"))
    refused(Erx::Manifest::Invalid, 'service.server', source, message: /holder of every system window/)
  end

  # The build's packages and system rows (docs/design-packaging.md, "The apps row"):
  # the system domain's packages grant rw and system grant ro, and the app template's
  # system grant rx, the one an app's session mounts /app through (design-files.md F6),
  # which the apps row names by index. Seeded: derived_facets deriving the template's system
  # row ro, or packing no system_facet, fails it.
  def test_the_build_derives_the_packages_and_system_rows
    view = @codec.open('manifest', admit.bytes)
    services = view.each('services').map { |row| view.string(row.fetch('name')) }
    parameters = view.each('facet_parameters').to_a
    first = view.header.fetch('facet_parameters').fetch('offset')
    granted = view.each('facets').map do |facet|
      span = facet.fetch('parameters')
      [facet.fetch('grantee_kind'), facet.fetch('grantee'), services.fetch(facet.fetch('service')),
       parameters[(span.fetch('offset') - first) / 32, span.fetch('count')].map { |row| row.fetch('scalar') }]
    end
    system, session = %w[system session].map { |kind| @codec.member('mf_grantee', kind) }
    ro, rw, rx = %w[ro rw rx].map { |name| @codec.member('files_rights', name) }
    assert_includes granted, [system, 0, 'packages', [rw]]
    assert_includes granted, [system, 0, 'system', [ro]]
    template = view.count('sessions') - 1
    assert_equal [session, template, 'system', [rx]], granted.fetch(view.each('apps').first.fetch('system_facet'))
  end

  # The row grants root's session template, which holds no derived system row, so
  # properties 2 and 5 do not refuse it first.
  def test_a_source_facet_row_of_the_system_service_is_refused
    row = "facet system_tree\n  grantee @session.system\n  service @service.system\n  operations none\n  max_request 131072\n" \
          "  in_flight 16\n  reductions 100000\n  period_ns 1000000000\n  max_heap_size 262144\n"
    refused(Erx::Manifest::Invalid, 'facet.service', @source + row, message: /only the derived system rows/)
  end

  # The development manifest without its apps row, whose own check of the system service
  # (derived_facets) would otherwise answer the seeds of the system window's first.
  def appless = Erx::Manifest::Edit.without_apps(@source)

  def test_a_system_service_of_another_interface_is_refused
    source = appless.sub("service system\n  server @domain.storage\n  interface files",
                         "service system\n  server @domain.storage\n  interface driver_control")
    refute_equal appless, source
    refused(Erx::Manifest::Invalid, 'service.interface', source, message: /of the files interface/)
  end

  # A session's line is minted only for the grantee the system domain names, so a service
  # row of a served_by session interface is refused, and with it any facet row of it.
  def test_a_service_or_facet_of_a_line_is_refused
    service = "service rogue_line\n  server @domain.network\n  interface tty_line\n"
    refused(Erx::Manifest::Invalid, 'service.interface', @source + service, message: /of tty_line, a session's line/)
    facet = "facet rogue_line\n  grantee system\n  service @service.rogue_line\n  operations none\n  max_request 256\n" \
            "  in_flight 1\n  reductions 100000\n  period_ns 1000000000\n  max_heap_size 65536\n"
    refused(Erx::Manifest::Invalid, 'service.interface', @source + service.sub('tty_line', 'web_line') + facet,
            message: /of web_line, a session's line/)
  end

  # A drive window row is the only grant of the drive interface, so a service row of it
  # is refused, and with it any facet row, which names a service row
  # (docs/design-drives.md, "Manifest rows").
  def test_a_service_of_the_drive_interface_is_refused
    service = "service rogue_drive\n  server @domain.network\n  interface drive\n"
    refused(Erx::Manifest::Invalid, 'service.interface', @source + service, message: /of drive, a drive window's grant/)
  end

  # No service row takes the name of an interface no row grants, drive or a session's
  # line, whatever its own interface: the domain service declares drive for each drive
  # window's serving row and keys a line's grant by its name, so a service of the same
  # name would share the grant records' names (docs/design-drives.md, "Manifest rows").
  def test_a_service_named_after_an_unrowed_interface_is_refused
    { 'drive' => /named drive, a drive window's grant/, 'tty_line' => /named tty_line, a session's line/ }.each do |name, message|
      service = "service #{name}\n  server @domain.network\n  interface files\n"
      refused(Erx::Manifest::Invalid, 'service.name', @source + service, message: message)
    end
  end

  # A second service record whose public name is system, under another label, on
  # another server, since property 5 refuses two names alike on one server first.
  def test_a_second_system_service_is_refused
    second = "service system_again\n  name \"system\"\n  server @domain.network\n  interface files\n"
    refused(Erx::Manifest::Invalid, 'service.name', appless + second, message: /a system window holds one service named system/)
    refused(Erx::Manifest::Invalid, 'service.name', @source + second, message: /an apps row holds one service named system/)
  end

  # The apps row's system_facet is a facet index, never absent (docs/design-abi.md), so a
  # manifest with an apps row and no system tree, whose image packages' /app no session
  # could mount, is refused at build.
  def test_an_apps_row_without_the_system_service_is_refused
    source = changed(@source.sub(/^window system\n(?:  .*\n)*/, '').sub("system_image\n  input @artifact.release\n", '')
                            .sub(/^service system\n(?:  .*\n)*/, ''))
    refused(Erx::Manifest::Invalid, 'service.name', source, message: /an apps row holds one service named system/)
  end

  # The service with no window, with the apps row and without it.
  def test_the_system_service_without_a_system_window_is_refused
    # The record_volume window goes too: only the system window's holder holds it.
    windowless = lambda do |text|
      without_login_keys(text).sub(/^window system\n(?:  .*\n)*/, '').sub("system_image\n  input @artifact.release\n", '')
    end
    refused(Erx::Manifest::Invalid, 'apps', windowless.call(@source), message: /apps row needs a system window/)
    refused(Erx::Manifest::Invalid, 'service.name', windowless.call(appless), message: /without a system window holds no/)
  end

  def test_a_system_window_without_the_system_service_is_refused
    source = appless.sub(/^service system\n(?:  .*\n)*/, '')
    refute_equal appless, source
    refused(Erx::Manifest::Invalid, 'service.name', source, message: /a system window holds one service named system/)
  end

  # Root's login keys on the medium (docs/design-ssh.md, "Who publishes it"): the
  # record_volume window, the login_keys service its holder serves and the system
  # domain's read-only grant of it, as a board with SSH holds them. The cases add them
  # to the development manifest taken without its own, root's session's grant included
  # (WITHOUT_LOGIN_KEYS).
  WITHOUT_LOGIN_KEYS = [/^window record_volume\n(?:  .*\n)*/, /^service login_keys\n(?:  .*\n)*/,
                        /^facet login_keys\n(?:  .*\n)*/, /^facet login_keys_session\n(?:  .*\n)*/].freeze

  def without_login_keys(source)
    WITHOUT_LOGIN_KEYS.reduce(source) { |text, row| ManifestContextFixture.substitute(text, row, '') }
  end

  def record_volume(holder: '@domain.storage', label: 'record_volume')
    window(role: 'record_volume', partition: 0, holder: holder).sub('window seeded', "window #{label}")
  end

  LOGIN_KEYS_SERVICE = "service login_keys\n  server @domain.storage\n  interface files\n"

  def login_keys_facet(grantee: 'system', rights: "  parameter rights ro\n")
    "facet login_keys\n  grantee #{grantee}\n  service @service.login_keys\n#{rights}" \
      "  operations none\n  max_request 131072\n  in_flight 16\n  reductions 100000\n  period_ns 1000000000\n" \
      "  max_heap_size 262144\n"
  end

  def login_keys_source(window: record_volume, service: LOGIN_KEYS_SERVICE, facet: login_keys_facet)
    without_login_keys(@source) + window + service + facet
  end

  def test_the_record_volume_window_and_its_login_keys_service_pass
    view = @codec.open('manifest', admit(login_keys_source).bytes)
    windows = (0...view.count('windows')).map { |at| view.fetch('windows', at) }
    volume = windows.select { |row| row.fetch('role') == @codec.member('mf_window_role', 'record_volume') }
    storage = (0...view.count('domains')).find { |at| view.string(view.fetch('domains', at).fetch('name')) == 'storage' }
    assert_equal [storage], volume.map { |row| row.fetch('holder') }
  end

  def test_login_keys_served_by_another_domain_than_the_window_s_holder_is_refused
    %w[@domain.web @domain.network].each do |server|
      service = LOGIN_KEYS_SERVICE.sub('@domain.storage', server)
      refused(Erx::Manifest::Invalid, 'service.server', login_keys_source(service: service),
              message: /holder of every record_volume window/)
    end
  end

  def test_a_login_keys_service_of_another_interface_is_refused
    service = LOGIN_KEYS_SERVICE.sub('interface files', 'interface driver_control')
    refused(Erx::Manifest::Invalid, 'service.interface', login_keys_source(service: service, facet: ''),
            message: /of the files interface/)
  end

  # A row that states no rights is rw (abi/services/files.txt).
  def test_a_login_keys_grant_that_is_not_read_only_is_refused
    ["  parameter rights rw\n", "  parameter rights rx\n", ''].each do |rights|
      refused(Erx::Manifest::Invalid, 'facet.parameter', login_keys_source(facet: login_keys_facet(rights: rights)),
              message: /read-only/)
    end
  end

  # Root's session template, @session.system, may hold a read-only grant beside the
  # system domain's, for SSH stage 1's daemon (docs/design-ssh.md, "Invariants", H8).
  def test_a_read_only_login_keys_grant_to_root_s_session_passes
    facets = login_keys_facet + login_keys_facet(grantee: '@session.system').sub('facet login_keys', 'facet login_keys_session')
    view = @codec.open('manifest', admit(login_keys_source(facet: facets)).bytes)
    service = (0...view.count('services')).find { |at| view.string(view.fetch('services', at).fetch('name')) == 'login_keys' }
    grants = (0...view.count('facets')).map { |at| view.fetch('facets', at) }.select { |row| row.fetch('service') == service }
    assert_equal [@codec.member('mf_grantee', 'system'), @codec.member('mf_grantee', 'session')].sort,
                 grants.map { |row| row.fetch('grantee_kind') }.sort
  end

  def test_a_login_keys_grant_to_root_s_session_that_is_not_read_only_is_refused
    ["  parameter rights rw\n", ''].each do |rights|
      facet = login_keys_facet(grantee: '@session.system', rights: rights)
      refused(Erx::Manifest::Invalid, 'facet.parameter', login_keys_source(facet: facet), message: /read-only/)
    end
  end

  # Another domain, or the session template of a principal other than the system's.
  def test_a_login_keys_grant_to_another_grantee_is_refused
    guest = "#{principal_row('guest', 'users')}principal system\n"
    session = "session guest\n  limits @limits.session\n  runtime @artifact.emu\n  release @artifact.session\nsession system\n"
    { '@domain.network' => @source, '@session.guest' => @source.sub("principal system\n", guest).sub("session system\n", session) }
      .each do |grantee, source|
        changed = without_login_keys(source) + record_volume + LOGIN_KEYS_SERVICE + login_keys_facet(grantee: grantee)
        refused(Erx::Manifest::Invalid, 'facet.grantee', changed, message: /session template/)
      end
  end

  def test_a_login_keys_service_without_a_record_volume_window_is_refused
    refused(Erx::Manifest::Invalid, 'service.name', login_keys_source(window: ''), message: /record_volume window/)
  end

  def test_a_record_volume_window_without_its_login_keys_service_is_refused
    refused(Erx::Manifest::Invalid, 'service.name', login_keys_source(service: '', facet: ''),
            message: /record_volume window/)
  end

  # A second record_volume window lies on the system window's block device, as the
  # first does, so it names the first's role and partition, and fails as such.
  def test_a_second_record_volume_window_is_refused
    second = record_volume(holder: '@domain.network', label: 'record_volume_again')
    refused(Erx::Manifest::Invalid, 'window.partition', login_keys_source(window: record_volume + second),
            message: /two windows name one role, partition and drive of a device/)
  end

  # A second block device, which its holder's driver does not serve, is no medium the
  # record partition's rules reason about.
  def test_a_record_volume_window_on_another_device_than_the_system_window_s_is_refused
    source, against = with_extra_device(role: 'block')
    window = record_volume.sub(BLOCK, '/extra@0')
    refused(Erx::Manifest::Invalid, 'window.device',
            without_login_keys(source) + window + LOGIN_KEYS_SERVICE + login_keys_facet, against, message: /lies on the system window's block device/)
  end

  # The view refuses a record_volume window held by another domain than the system
  # window's holder; the login_keys service its holder serves fails first.
  def test_a_record_volume_window_on_another_domain_than_the_system_window_s_holder_is_refused
    %w[@domain.web @domain.network].each do |holder|
      refused(Erx::Manifest::Invalid, 'service.server', login_keys_source(window: record_volume(holder: holder)),
              message: /served by the holder of every record_volume window/)
    end
  end

  # A window's role alone decides whether it is served writable (erx_blk_window), so a
  # window row has no rights: one naming them, here the data window naming read alone,
  # would claim a read-only window the block driver serves writable.
  def test_a_window_row_naming_rights_is_refused
    data = @source[/^window data\n(?:  .*\n)*/]
    stating_rights = data.sub('  image ', "  rights read\n  image ")
    error = assert_raises(Erx::ABI::SchemaError) { admit(changed(@source.sub(data, stating_rights))) }
    assert_match(/unknown or duplicate manifest property/, error.message)
  end

  # Every window lies on a block device or, as the media domain's drive window does, on a
  # USB controller.
  def test_windows_encode_in_contract_order_on_their_devices
    view = @codec.open('manifest', admit.bytes)
    rows = (0...view.count('windows')).map { |index| view.fetch('windows', index) }
    order = rows.map { |row| row.values_at('holder', 'role') }
    assert_equal order.sort, order
    rows.each do |row|
      assert_includes %w[block usb].map { |role| @codec.member('mf_device_role', role) }, view.fetch('devices', row.fetch('device')).fetch('role')
    end
  end

  def test_a_source_alias_does_not_reach_the_bytes
    assert_equal admit.bytes, admit(@source.sub('window data', 'window zzz')).bytes
  end

  # The development manifest grants the storage domain's data, a files facet, to the
  # system domain and to root's session template, under one name.
  def test_the_storage_domain_grants_data_to_the_system_and_root_s_session
    view = @codec.open('manifest', admit(@source).bytes)
    services = view.count('services').times.map { |index| view.fetch('services', index) }
    data = services.index { |row| view.string(row.fetch('name')) == 'data' }
    refute_nil data
    assert_equal @codec.schema.services.find { |service| service.fetch(:name) == 'files' }.fetch(:number),
                 services.fetch(data).fetch('interface')
    grants = view.count('facets').times.map { |index| view.fetch('facets', index) }
                 .select { |row| row.fetch('service') == data }
                 .map { |row| [view.string(row.fetch('name')), row.fetch('grantee_kind')] }
    kinds = %w[system session].map { |kind| @codec.member('mf_grantee', kind) }
    assert_equal kinds.map { |kind| ['data', kind] }.sort, grants.sort
  end

  def test_services_sort_by_encoded_name
    services = "service zeta\n  name \"alpha\"\n  server system\n  interface 1\n" \
               "service alpha\n  name \"zeta\"\n  server system\n  interface 2\n"
    view = @codec.open('manifest', admit(@source + services).bytes)
    names = view.count('services').times.map { |index| view.string(view.fetch('services', index).fetch('name')) }
    assert_equal names.sort, names
    assert_equal 1, view.fetch('services', names.index('alpha')).fetch('interface')
    assert_equal 2, view.fetch('services', names.index('zeta')).fetch('interface')
  end

  def test_an_unassigned_host_link_is_refused
    source = @source.sub("unit hostlink\n  placement \"hostlink-uart\"\n  holder system\n", '')
    refused(Erx::Manifest::Invalid, 'machine.hostlink', source, message: /UART is not placed/)
  end

  def test_a_service_name_that_is_no_identifier_is_refused
    refused(Erx::Manifest::Invalid, 'service.name', @source + "service other\n  name \"Bad Name\"\n  server system\n  interface 2\n",
            message: /service name is not a system identifier/)
  end

  def test_root_memory_up_to_ram_less_the_reserve_is_accepted
    assert_instance_of Erx::Manifest::Admitted, admit(with_root_memory(ram_less_the_reserve))
  end

  # Property 9: release builds wait for the confinement check.
  def test_a_release_build_is_refused_naming_its_milestone
    source = @source.sub('flags development', 'flags none')
    refused(Erx::Manifest::Unsupported, 'machine.flags', source, context(build_kind: 'release'), message: /M11/)
  end

  # docs/design-login.md, "Who holds it": a release manifest's row listing root_line is
  # refused as such, ahead of the release build's refusal, so no release image hands
  # anyone the console's root session.
  def test_a_release_manifest_grants_no_root_line
    source = @source.sub('flags development', 'flags none') +
             "facet lg\n  grantee @domain.alpha\n  service @service.login\n  operations root_line\n" \
             "  max_request 131072\n  in_flight 8\n  reductions 100000\n  period_ns 1000000000\n  max_heap_size 65536\n" \
             "  parameter line \"tty_line\"\n  parameter logins 1\n"
    refused(Erx::Manifest::Invalid, 'facet.operations', source, context(build_kind: 'release'),
            message: /facet lg lists root_line, which a release manifest grants no one/)
  end

  def test_a_build_kind_conflict_is_still_refused
    refused(Erx::Manifest::Invalid, 'machine.flags', @source, context(build_kind: 'release'),
            message: /configuration conflicts with checked build kind/)
  end

  def test_a_confined_device_is_refused_naming_its_milestone
    source, against = with_extra_device(role: 'ordinary', dma: 'confined')
    refused(Erx::Manifest::Unsupported, 'devices.dma', source, against, message: /M9/)
  end

  # A unit goes whole to one holder (property 1): a second unit row placing the same
  # unit and a unit row naming two holders are refused before anything is placed.
  # That devices sharing a page are one unit is the domain library's view's judgment,
  # which dom_planner_test runs through the build's planner.
  def test_a_unit_on_two_holders_is_refused
    twice = @source + "unit net_again\n  placement \"net\"\n  holder system\n"
    refused(Erx::Manifest::Invalid, 'unit.placement', twice, message: /assigned more than once/)
    two = @source.sub(/^(unit net\n  placement "net"\n  holder @domain.network)$/, '\1 system')
    refute_equal @source, two
    error = assert_raises(Erx::ABI::SchemaError) { admit(two) }
    assert_match(/holder requires one value/, error.message)
  end

  def test_an_unconfined_device_without_memory_is_refused
    source, against = with_extra_device(role: 'ordinary', dma: 'unconfined', dma_memory: 0)
    refused(Erx::Manifest::Invalid, 'devices.dma_memory', source, against, message: /an unconfined device needs a memory reservation/)
  end

  def test_a_device_with_no_dma_cannot_declare_dma_memory
    source, against = with_extra_device(role: 'ordinary', dma: 'none', dma_memory: 4096)
    refused(Erx::Manifest::Invalid, 'devices.dma_memory', source, against, message: /non-DMA device has a DMA reservation/)
  end

  def test_a_partial_boot_record_is_refused_naming_its_milestone
    source = @source.sub('flags development', 'flags development,partial_boot') + "partial_boot probe\n  image @artifact.root\n"
    refused(Erx::Manifest::Unsupported, 'partial_boot', source, message: /M5/)
  end

  # The system_image row packs the release artifact's image and tree as the fixture
  # gives them: two blocks from the partition's start and one tree block after them.
  def test_the_system_image_row_packs_the_release_images_tree
    view = @codec.open('manifest', admit.bytes)
    assert_equal 1, view.count('system_image')
    row = view.fetch('system_image', 0)
    assert_equal [8192, 8192, 4096, 32], row.values_at('image_length', 'tree_offset', 'tree_length', 'salt_length')
    assert_equal ["\x5a".b * 32, "\xa5".b * 32], row.values_at('salt', 'root_hash')
  end

  # A release artifact whose image or tree the system partition cannot hold as the
  # record describes it is refused.
  def test_a_system_image_the_record_cannot_describe_is_refused
    tree = ManifestContextFixture.images.fetch('release').fetch('tree')
    [{ 'extents' => [{ 'slot_offset' => 4096, 'length' => 8192 }] }, { 'tree' => nil },
     { 'tree' => tree.merge('offset' => 12_288) }, { 'tree' => tree.merge('length' => 100) },
     { 'tree' => tree.merge('salt' => 'AB') }, { 'tree' => tree.merge('salt' => '') },
     { 'tree' => tree.merge('root_hash' => '00') }, { 'tree' => tree.merge('length' => 1_048_576 * 512) }].each do |change|
      release = ManifestContextFixture.images.fetch('release').merge(change)
      against = context { |arguments| arguments[:artifacts] = arguments[:artifacts].merge('release' => release) }
      refused(Erx::Manifest::Invalid, 'system_image.input', @source, against)
    end
  end

# With no verified image sharing the release artifact, the system_image record alone
# reads its extents, and a refusal of them names that record.
def test_a_system_image_with_no_extents_is_refused_under_its_own_field
  source = changed(@source.sub(/^image release\n(?:  .*\n)*/, '').sub(/^window release\n(?:  .*\n)*/, ''))
  release = ManifestContextFixture.images.fetch('release').merge('extents' => [])
  against = context { |arguments| arguments[:artifacts] = arguments[:artifacts].merge('release' => release) }
  refused(Erx::Manifest::Invalid, 'system_image.input', source, against, message: /at least one extent/)
end

  def test_a_second_system_image_row_is_refused
    refused(Erx::Manifest::Invalid, 'system_image', @source + "system_image\n  input @artifact.release\n",
            message: /at most one system_image row/)
  end

  # The release image (docs/design-fiasco.md, "The Phase 1 manifest check"): format
  # erofs_unchecked, its extents from the artifact, every tree field zero.
  def test_the_release_image_is_recorded_without_a_tree
    view = @codec.open('manifest', admit.bytes)
    image = view.fetch('images', 0)
    assert_equal 'release', view.string(image.fetch('name'))
    assert_equal @codec.member('mf_image_format', 'erofs_unchecked'), image.fetch('format')
    assert_equal [8192, 4096, 2], image.values_at('data_bytes', 'data_block_size', 'data_blocks')
    assert_equal [0, 0, 0, 0, 0, 0], image.values_at('hash_block_size', 'hash_offset', 'hash_bytes', 'salt_length',
                                                     'hash_algorithm', 'salt').map { |value| value.is_a?(String) ? value.sum : value }
    assert_equal 0, image.fetch('root_hash').sum
    assert_equal [{ 'slot_offset' => 0, 'length' => 8192 }], (0...view.count('extents')).map { |at| view.fetch('extents', at) }
    windows = (0...view.count('windows')).map { |at| view.fetch('windows', at) }
    verified = windows.select { |row| row.fetch('role') == @codec.member('mf_window_role', 'verified_image') }
    assert_equal [0], verified.map { |row| row.fetch('image') }
  end

  def test_an_image_input_must_be_an_image_artifact_of_the_pack
    ['@artifact.root', '@artifact.absent', '"release"'].each do |input|
      refused(Erx::Manifest::Invalid, 'image.input', @source.sub('input @artifact.release', "input #{input}"),
              message: /input names no erofs_image artifact of this pack/)
    end
  end

  def test_image_extents_are_sorted_disjoint_sectors_inside_a_slot
    slot = 1_048_576 * 512
    [[], [{ 'slot_offset' => 0, 'length' => 0 }], [{ 'slot_offset' => 1, 'length' => 4096 }],
     [{ 'slot_offset' => slot - 4096, 'length' => 8192 }], [{ 'slot_offset' => 0, 'length' => 4000 }],
     [{ 'slot_offset' => 8192, 'length' => 4096 }, { 'slot_offset' => 0, 'length' => 4096 }],
     [{ 'slot_offset' => 0, 'length' => 4096 }, { 'slot_offset' => 2048, 'length' => 4096 }]].each do |extents|
      against = context { |arguments| arguments[:artifacts] = arguments[:artifacts].merge('release' => { 'kind' => 'erofs_image', 'extents' => extents }) }
      refused(Erx::Manifest::Invalid, 'image.input', @source, against)
    end
  end

  def test_an_image_without_a_tree_takes_no_salt
    refused(Erx::Manifest::Invalid, 'image.salt', @source.sub("input @artifact.release\n", "input @artifact.release\n  salt 0x00\n"),
            message: /an image without a hash tree takes no salt/)
  end

  def test_a_verified_image_window_names_its_image
    refused(Erx::Manifest::Invalid, 'window.image', @source.sub('image @image.release', 'image none'),
            message: /a verified-image window names its image/)
    refused(Erx::Manifest::Invalid, 'window.image', @source + window(role: 'data', partition: 0, image: '@image.release'),
            message: /only a verified-image window names an image/)
  end
end
