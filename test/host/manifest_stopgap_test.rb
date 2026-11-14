# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../../tools/lib/erx/manifest'
require_relative '../../tools/lib/erx/platform'
require_relative '../fixtures/manifest_context'

# Phase 1's manifest check (docs/design-stopgap.md): each kept property of
# design-system.md has a seeded violation here and each refusal a seeded record.
# Every seed edits the real development manifest or the real platform record,
# so a seed fails for its own reason and not for an unrelated difference.
class ManifestStopgapTest < Minitest::Test
  BLOCK = '/virtio_mmio@a003e00'
  SERVICE = "service probe\n  server system\n  interface 1\n"

  def setup
    root = File.expand_path('../..', __dir__)
    @codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root)))
    @source = File.binread(File.join(root, 'config/manifest/qemu-virt-development.txt'))
    @platform = JSON.parse(File.read(File.join(root, 'config/platforms/qemu-virt.json')))
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

  def refused(klass, property, field, source = @source, against = @context, message: nil)
    error = assert_raises(klass) { admit(source, against) }
    assert_equal property, error.property, error.message
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

  # The real platform with the unit with_extra_device places.
  def with_extra_device_platform(**fields)
    device = @platform.fetch('units').last.fetch('devices').first
                      .merge('path' => '/extra@0', 'placement_key' => 'extra', 'dma' => 'none', 'dma_memory' => 0)
                      .merge(fields.transform_keys(&:to_s))
    platform_with { |value| value.fetch('units') << { 'key' => 'extra', 'devices' => [device] } }
  end

  def window(role:, partition: 1, device: BLOCK, holder: 'system', image: 'none')
    "window seeded\n  holder #{holder}\n  device \"#{device}\"\n  role #{role}\n  partition #{partition}\n" \
      "  rights read\n  image #{image}\n"
  end

  # A device-tree row without its window or line would give its driver zeros to open.
  def test_a_device_tree_row_must_carry_its_window_and_line
    %w[base size line].each do |field|
      platform = platform_with { |value| value.fetch('units').first.fetch('devices').first.delete(field) }
      refused(Erx::Manifest::Invalid, 'context', 'platform.devices', @source, context(platform: platform), message: /lacks #{field}/)
    end
  end

  def test_a_device_tree_row_must_have_a_window
    platform = platform_with { |value| value.fetch('units').first.fetch('devices').first['size'] = 0 }
    refused(Erx::Manifest::Invalid, 'context', 'platform.devices', @source, context(platform: platform), message: /empty window/)
  end

  # A PL011's driver times characters and divides its baud rate from the UART's clock, which
  # only the board knows, so a PL011 row without a clock of at least one hertz is wrong.
  def test_a_pl011_row_must_carry_its_clock
    [nil, 0, -1, '24000000'].each do |clock|
      platform = platform_with do |value|
        device = value.fetch('units').first.fetch('devices').first
        clock.nil? ? device.delete('clock') : device['clock'] = clock
      end
      refused(Erx::Manifest::Invalid, 'context', 'platform.devices', @source, context(platform: platform), message: /PL011 .*clock/)
    end
  end

  # Only a PL011's driver reads a clock, so any other row's clock is 0.
  def test_a_row_of_another_device_carries_no_clock
    source, against = with_extra_device(compatible: 'virtio,mmio', clock: 24_000_000)
    refused(Erx::Manifest::Invalid, 'context', 'platform.devices', source, against, message: /clock/)
  end

  # Configuration space gives a PCIe function its window, so a platform row that names one is wrong.
  def test_a_pci_row_must_not_carry_a_window
    source, against = with_extra_device(selector: 'pci', role: 'ordinary', bridge: '/pcie@0', path: '')
    refused(Erx::Manifest::Invalid, 'context', 'platform.devices', source, against, message: /PCIe function carries/)
  end

  def test_the_real_development_manifest_is_admitted
    result = admit
    assert_instance_of Erx::Manifest::Admitted, result
    assert result.matches?(@context)
    assert result.bytes.frozen?
    view = @codec.open('manifest', result.bytes)
    assert_equal 4, view.count('domains')
    assert_equal 5, view.count('devices')
    assert_equal 6, view.count('windows')
    assert_equal 1, view.count('images')
  end

  # The website's manifest passes the same check: its storage and network domains, without
  # the web and display domains, hold the same windows and image and every device but the
  # display's gpu.
  def test_the_real_site_manifest_is_admitted
    result = admit(site_manifest)
    assert result.matches?(@context)
    view = @codec.open('manifest', result.bytes)
    assert_equal 2, view.count('domains')
    assert_equal 4, view.count('devices')
    assert_equal 6, view.count('windows')
    assert_equal 1, view.count('images')
  end

  # Each manifest's root_memory is what its budgets promise and an 8 MiB margin no one
  # is promised: the site manifest's, made from the development one, keeps the margin,
  # since each domain it leaves out gives back the room it took
  # (ManifestText.without_domain), the display unit's DMA memory included.
  def test_root_memory_is_the_promise_and_the_margin_in_both_manifests
    [@source, site_manifest].each do |source|
      report = admit(source).report
      assert_equal 8 << 20, report.fetch('root_memory') - report.fetch('promised_memory')
    end
  end

  # The website's manifest, made from the development one.
  def site_manifest
    root = File.expand_path('../..', __dir__)
    Erx::Platform.development(root).site_manifest_source(root)
  end

  def test_the_report_claims_only_what_was_checked
    report = admit.report
    assert_equal 'stopgap', report.fetch('mode')
    assert_equal 'declared', report.fetch('root_startup')
    assert_equal 'supplied_catalog', report.fetch('executable')
    assert_equal 'supplied_context', report.fetch('provenance')
    assert_equal 'unsupported', report.fetch('policy_admission')
    assert_equal 4, report.fetch('child_plan_instances')
    assert_equal 0, report.fetch('dynamic_domain_reservation')
    assert_equal @platform.fetch('fiasco_reserve'), report.fetch('fiasco_reserve')
    assert_equal @platform.fetch('ram_bytes'), report.fetch('ram_bytes')
    assert_equal 4096, report.fetch('root_image_loadable_bytes')
  end

  # The development manifest as a partial boot, which makes no sessions and configures
  # no domains, so without its session template, the services only sessions are granted
  # (inspect and apps) and its storage, network and web domains.
  def partial_boot
    changed(ManifestContextFixture.without_system_services(
      ManifestContextFixture.domainless(@source).sub('flags development', 'flags development,partial_boot')
                            .sub(/^session system\n(?:  .*\n)*/, '')
    ))
  end

  def test_a_partial_boot_flag_without_partial_boot_records_is_admitted
    source = partial_boot
    assert_equal 'stopgap', admit(source).report.fetch('mode')
  end

  def test_a_partial_boot_runs_no_services
    source = partial_boot + SERVICE
    refused(Erx::Manifest::Invalid, 2, 'service', source)
  end

  def test_admitted_services_reach_the_encoded_manifest
    view = @codec.open('manifest', admit(@source + SERVICE).bytes)
    # The development manifest's own, apps, data, display, inspect, log, net, network_ctl,
    # storage_ctl and web, and this one.
    assert_equal %w[apps data display inspect log net network_ctl probe storage_ctl web], view.count('services').times.map { |index| view.string(view.fetch('services', index).fetch('name')) }
    assert_equal 0, view.count('liveness')
  end

  # The watchdog pets whether or not a service lives, so a record that says it watches one is refused.
  def test_a_liveness_record_is_refused_because_nothing_reads_it
    refused(Erx::Manifest::Unsupported, 'unsupported', 'liveness', @source + SERVICE + "liveness @service.probe\n",
            message: /watchdog/)
  end

  def test_the_structural_fixture_rules_do_not_change
    error = assert_raises(Erx::Manifest::Unsupported) do
      Erx::Manifest.structural_fixture(source: @source, codec: @codec, context: @context)
    end
    assert_equal 'mode', error.field
  end

  # Property 1: one holder per device and unit.
  def test_a_unit_held_by_another_domain_is_refused
    refused(Erx::Manifest::Invalid, 1, 'unit.holder', changed(@source.sub("placement \"net\"\n  holder @domain.network", "placement \"net\"\n  holder other")))
  end

  def test_a_unit_placed_twice_is_refused
    refused(Erx::Manifest::Invalid, 1, 'unit.placement', @source + "unit again\n  placement \"block\"\n  holder system\n")
  end

  def test_a_device_in_two_units_is_refused
    source, against = with_extra_device(path: BLOCK)
    refused(Erx::Manifest::Invalid, 1, 'devices.path', source, against)
  end

  # Property 2: facets name servers, and no introductions.
  def test_a_service_on_another_server_is_refused
    refused(Erx::Manifest::Invalid, 2, 'service.server', @source + SERVICE.sub('server system', 'server storage'))
  end

  # Property 3: no holder of PCIe configuration space.
  def test_a_configuration_space_holder_is_refused
    source, against = with_extra_device(role: 'configuration')
    refused(Erx::Manifest::Invalid, 3, 'devices.role', source, against, message: /M9/)
  end

  # Property 4: budgets, grants and the root startup rule.
  # The development manifest's system_baseline, which the sums below fit against.
  def baseline = Integer(@source[/^  system_baseline (\d+)$/, 1])
  def root_memory = Integer(@source[/^  root_memory (\d+)$/, 1])
  # The development manifest with the system principal's budget set to bytes.
  def with_system_memory(bytes) = changed(@source.sub(/^(principal system\n  memory )\d+$/) { "#{Regexp.last_match(1)}#{bytes}" })

  def test_budgets_over_root_memory_are_refused
    refused(Erx::Manifest::Invalid, 4, 'principals.memory', with_system_memory(root_memory - baseline + 4096))
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
    assert admit(with_system_memory(root_memory - baseline - device_memory))
    refused(Erx::Manifest::Invalid, 4, 'principals.memory', with_system_memory(root_memory - baseline - device_memory + 4096))
  end

  def test_a_principal_domain_quota_is_refused
    refused(Erx::Manifest::Invalid, 4, 'principals.domains', changed(@source.sub(/^(principal system\n(?:  .*\n)*?  domains )(\d+)$/) { "#{Regexp.last_match(1)}#{Integer(Regexp.last_match(2)) + 1}" }))
  end

  # A principal row of the given name granted the share named share, small enough that
  # the development manifest's budgets still fit.
  def principal_row(name, share)
    "principal #{name}\n  memory 1048576\n  grant @share.#{share}\n  domains 0\n  names 1\n" \
      "  default_limits @limits.native\n  ceiling_limits @limits.native\n"
  end

  # A grant is a cap and promises no minimum, so principals whose caps together exceed
  # `users` are admitted; one principal's cap above `users` is not.
  def test_principal_grants_may_oversubscribe_users
    assert admit(changed(@source.sub("principal system\n", "#{principal_row('guest', 'users')}principal system\n")))
  end

  def test_a_principal_grant_over_users_is_refused
    over = @source.sub("principal system\n", "#{principal_row('guest', 'system')}principal system\n")
    refused(Erx::Manifest::Invalid, 4, 'principal.grant', changed(over))
  end

  def test_shares_over_the_root_rate_are_refused
    refused(Erx::Manifest::Invalid, 4, 'machine.shares', @source.sub('quota_ns 30000000', 'quota_ns 40000000'))
  end

  # The development manifest with root_memory set to bytes.
  def with_root_memory(bytes) = changed(@source.sub(/^(  root_memory )\d+$/) { "#{Regexp.last_match(1)}#{bytes}" })
  def ram_less_the_reserve = @platform.fetch('ram_bytes') - @platform.fetch('fiasco_reserve')

  def test_root_memory_over_ram_less_the_reserve_is_refused
    refused(Erx::Manifest::Invalid, 4, 'root_startup', with_root_memory(ram_less_the_reserve + 4096), message: /fiasco_reserve/)
  end

  def test_loadable_segments_and_baseline_over_root_memory_are_refused
    against = context do |arguments|
      image = arguments.fetch(:catalog).last.fetch('image')
      image['span'] = 335_544_320 + 4096
      image.fetch('segments') << { 'file_offset' => 8192, 'mem_offset' => 4096, 'file_size' => 0,
                                   'mem_size' => 335_544_320, 'prot' => @codec.member('prot', 'r'), 'flags' => 0 }
    end
    refused(Erx::Manifest::Invalid, 4, 'root_startup', @source, against, message: /loadable/)
  end

  def test_a_platform_without_the_reserve_is_not_admitted
    against = context(platform: platform_with { |value| value.delete('fiasco_reserve') })
    refused(Erx::Manifest::Unsupported, 4, 'root_startup', @source, against)
  end

  def test_a_reserve_that_leaves_no_ram_is_not_admitted
    against = context(platform: platform_with { |value| value['fiasco_reserve'] = value.fetch('ram_bytes') })
    refused(Erx::Manifest::Unsupported, 4, 'root_startup', @source, against)
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
    assert_equal [4, 'root_startup'], [error.property, error.field]
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
    refused(Erx::Manifest::Invalid, 4, 'devices.dma_memory', source, against, message: /mem_contiguous_max/)
  end

  def test_devices_memory_past_the_contiguous_pool_is_refused
    over = Erx::Manifest::RootStartup::CONTIGUOUS_POOL_MAX_BYTES - device_memory + 4096
    source, against = with_extra_device(role: 'ordinary', dma: 'unconfined', flags: 1, dma_memory: over)
    refused(Erx::Manifest::Invalid, 4, 'devices.dma_memory', source, against, message: /contiguous pool/)
  end

  def test_a_platform_without_root_withheld_packs_nothing
    platform = platform_with { |value| value.delete('root_withheld') }
    error = assert_raises(Erx::Manifest::Unsupported) { Erx::Manifest::RootStartup.archive_machine(platform) }
    assert_match(/root_withheld/, error.message)
  end

  # Property 5: names.
  def test_a_host_name_that_is_no_identifier_is_refused
    refused(Erx::Manifest::Invalid, 5, 'machine.host', @source.sub('host "erxos"', 'host "Not An Identifier"'))
  end

  def test_a_host_name_with_a_dot_is_refused
    refused(Erx::Manifest::Invalid, 5, 'machine.host', @source.sub('host "erxos"', 'host "a.b"'))
  end

  def test_two_services_sharing_a_name_are_refused
    second = "service other\n  name \"probe\"\n  server system\n  interface 2\n"
    refused(Erx::Manifest::Invalid, 5, 'service.name', @source + SERVICE + second)
  end

  # Property 6: no JIT in the root.
  def test_a_root_image_with_jit_is_refused
    against = context do |arguments|
      arguments.fetch(:catalog).last.fetch('image')['flags'] |= @codec.member('image_flags', 'jit')
    end
    refused(Erx::Manifest::Invalid, 6, 'catalog.root', @source, against)
  end

  # Property 7: no sealing secret.
  def test_a_sealing_mode_is_refused
    refused(Erx::Manifest::Invalid, 7, 'machine.sealing', @source.sub('sealing none', 'sealing device'))
  end

  def test_a_sealed_entry_is_refused
    against = context do |arguments|
      arguments.fetch(:catalog).first['flags'] |= @codec.member('entry_flags', 'seal')
    end
    refused(Erx::Manifest::Invalid, 7, 'catalog.flags', @source, against, message: /M11/)
  end

  def test_a_tpm_is_refused
    source, against = with_extra_device(role: 'tpm')
    refused(Erx::Manifest::Invalid, 7, 'devices.role', source, against, message: /M11/)
  end

  # Property 8: the UARTs and the windows.
  def test_the_console_and_host_link_must_differ
    refused(Erx::Manifest::Invalid, 8, 'machine.hostlink', @source.sub('hostlink "/pl011@9040000"', 'hostlink "/pl011@9000000"'))
  end

  def test_an_unassigned_console_is_refused
    source = @source.sub("unit console\n  placement \"console-uart\"\n  holder system\n", '')
    refused(Erx::Manifest::Invalid, 8, 'machine.console', source)
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
    refused(Erx::Manifest::Invalid, 8, 'machine.hostlink', source, context(platform: platform),
            message: /share interrupt line 33/)
  end

  # The network stack runs in the system domain in Phase 1, over the device its unit
  # places there (docs/design-stopgap.md, "Device records").
  def test_a_network_device_is_admitted
    source, against = with_extra_device(role: 'network')
    admit(source, against)
  end

  # The display's device on QEMU virt, a virtio-mmio transport of the gpu role, is held as
  # any unconfined DMA device is in a development build (docs/design-stopgap.md, "Device records").
  def test_a_gpu_device_is_admitted
    admit(*with_extra_device(role: 'gpu', dma: 'unconfined', flags: 1, dma_memory: 1_048_576))
  end

  # A framebuffer row (docs/design-device-tree.md, "The framebuffer record"): /chosen and
  # simple-framebuffer, with no line or flags, its window whole pages clear of every
  # register window: 0x7e000000, 4 MiB, above QEMU virt's devices.
  FRAMEBUFFER = { role: 'framebuffer', path: '/chosen', compatible: 'simple-framebuffer', line: 0, flags: 0,
                  base: 0x7e00_0000, size: 0x40_0000 }.freeze

  def test_a_framebuffer_window_clear_of_every_register_window_is_admitted
    admit(*with_extra_device(**FRAMEBUFFER))
  end

  # Seeded faults for check_framebuffer_windows: a window over a placed device's registers,
  # the console UART's page, and one over the registers of a device no unit of the manifest
  # places, which the firmware's tree could still hand the window's holder.
  def test_a_framebuffer_window_meeting_registers_is_refused
    console = @platform.fetch('units').first.fetch('devices').first
    source, against = with_extra_device(**FRAMEBUFFER, base: console.fetch('base') & ~0xfff, size: 0x1000)
    refused(Erx::Manifest::Invalid, 1, 'devices.base', source, against, message: /meets #{Regexp.escape(console.fetch('path'))}'s/)

    source, = with_extra_device(**FRAMEBUFFER)
    framebuffer = with_extra_device_platform(**FRAMEBUFFER)
    unplaced = console.merge('path' => '/unplaced@7e3ff000', 'base' => 0x7e3f_f000, 'size' => 0x10,
                             'placement_key' => 'unplaced')
    framebuffer.fetch('units') << { 'key' => 'unplaced', 'devices' => [unplaced] }
    refused(Erx::Manifest::Invalid, 1, 'devices.base', source, context(platform: framebuffer),
            message: %r{meets /unplaced@7e3ff000's})

    # The console's selector written as the codec's number is the same device-tree row.
    numbered = with_extra_device_platform(**FRAMEBUFFER, base: console.fetch('base') & ~0xfff, size: 0x1000)
    numbered.fetch('units').first.fetch('devices').first['selector'] = @codec.member('mf_selector', 'dt')
    refused(Erx::Manifest::Invalid, 1, 'devices.base', source, context(platform: numbered), message: /meets/)

    # A device starting at the window's end does not meet it.
    after = with_extra_device_platform(**FRAMEBUFFER)
    after.fetch('units') << { 'key' => 'after', 'devices' => [unplaced.merge('path' => '/after@7e400000', 'base' => 0x7e40_0000,
                                                                             'placement_key' => 'after')] }
    admit(source, context(platform: after))
  end

  # A window over the platform's RAM, and a framebuffer row no manifest places, which is
  # checked all the same.
  def test_a_framebuffer_window_meeting_ram_or_unplaced_is_refused
    refused(Erx::Manifest::Invalid, 1, 'devices.base', *with_extra_device(**FRAMEBUFFER, base: @platform.fetch('ram_first')),
            message: /RAM/)
    unplaced = with_extra_device_platform(**FRAMEBUFFER, size: 0x40_0800)
    refused(Erx::Manifest::Invalid, 'context', 'platform.devices', @source, context(platform: unplaced), message: /framebuffer/)
  end

  def test_a_framebuffer_row_of_another_shape_is_refused
    [{ path: '/framebuffer@0' }, { compatible: 'virtio,mmio' }, { line: 40 }, { flags: 1 },
     { size: 0x40_0800 }, { base: 0x7e00_0800 }, { dma: 'unconfined', dma_memory: 4096 }].each do |change|
      refused(Erx::Manifest::Invalid, 'context', 'platform.devices', *with_extra_device(**FRAMEBUFFER, **change),
              message: /framebuffer/)
    end
  end

  def test_a_vault_window_is_refused
    refused(Erx::Manifest::Invalid, 8, 'window.role', @source + window(role: 'vault'), message: /M11/)
  end

  def test_a_window_held_by_no_configured_domain_is_refused
    refused(Erx::Manifest::Invalid, 8, 'window.holder', @source + window(role: 'fat', holder: '@domain.absent'))
  end

  def test_a_window_on_no_placed_device_is_refused
    refused(Erx::Manifest::Invalid, 8, 'window.device', @source + window(role: 'fat', device: '/absent@0'))
  end

  def test_a_window_on_a_device_that_is_no_block_device_is_refused
    refused(Erx::Manifest::Invalid, 8, 'window.device', @source + window(role: 'fat', device: '/pl011@9000000'))
  end

  def test_two_windows_on_one_partition_are_refused
    refused(Erx::Manifest::Invalid, 8, 'window.partition', @source + window(role: 'data', partition: 0))
  end

  def test_a_fixed_role_must_carry_partition_zero
    refused(Erx::Manifest::Invalid, 8, 'window.partition', @source + window(role: 'slot_a', partition: 2))
  end

  def test_a_fat_window_must_name_a_primary_partition
    [0, 5].each do |partition|
      refused(Erx::Manifest::Invalid, 8, 'window.partition', @source + window(role: 'fat', partition: partition))
    end
  end

  def test_a_window_must_grant_read
    refused(Erx::Manifest::Invalid, 8, 'window.rights', @source + window(role: 'fat').sub('rights read', 'rights none'))
  end

  def test_windows_encode_in_contract_order_on_the_block_device
    view = @codec.open('manifest', admit.bytes)
    rows = (0...view.count('windows')).map { |index| view.fetch('windows', index) }
    order = rows.map { |row| row.values_at('holder', 'role') }
    assert_equal order.sort, order
    rows.each do |row|
      assert_equal @codec.member('mf_device_role', 'block'), view.fetch('devices', row.fetch('device')).fetch('role')
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

  def test_a_pci_function_is_refused
    source, against = with_extra_device(selector: 'pci', role: 'ordinary', bridge: '/pcie@0', path: '', base: 0, size: 0, line: 0)
    refused(Erx::Manifest::Invalid, 3, 'devices.selector', source, against, message: /M9/)
  end

  def test_an_unassigned_host_link_is_refused
    source = @source.sub("unit hostlink\n  placement \"hostlink-uart\"\n  holder system\n", '')
    refused(Erx::Manifest::Invalid, 8, 'machine.hostlink', source)
  end

  def test_a_service_name_that_is_no_identifier_is_refused
    refused(Erx::Manifest::Invalid, 5, 'service.name', @source + "service other\n  name \"Bad Name\"\n  server system\n  interface 2\n")
  end

  def test_root_memory_up_to_ram_less_the_reserve_is_admitted
    assert_instance_of Erx::Manifest::Admitted, admit(with_root_memory(ram_less_the_reserve))
  end

  # Property 9: release builds wait for the confinement check.
  def test_a_release_build_is_refused_naming_its_milestone
    source = @source.sub('flags development', 'flags none')
    refused(Erx::Manifest::Unsupported, 9, 'machine.flags', source, context(build_kind: 'release'), message: /M11/)
  end

  def test_a_build_kind_conflict_is_still_refused
    refused(Erx::Manifest::Invalid, 9, 'machine.flags', @source, context(build_kind: 'release'))
  end

  def test_a_confined_device_is_refused_naming_its_milestone
    source, against = with_extra_device(role: 'ordinary', dma: 'confined')
    refused(Erx::Manifest::Unsupported, 'unsupported', 'devices.dma', source, against, message: /M9/)
  end

  # A unit goes whole to one holder (property 1): a second unit row placing the same
  # unit and a unit row naming two holders are refused before anything is placed.
  # That devices sharing a page are one unit is the domain library's view's judgment,
  # which dom_planner_test runs through the build's planner.
  def test_a_unit_on_two_holders_is_refused
    twice = @source + "unit net_again\n  placement \"net\"\n  holder system\n"
    refused(Erx::Manifest::Invalid, 1, 'unit.placement', twice, message: /assigned more than once/)
    two = @source.sub(/^(unit net\n  placement "net"\n  holder @domain.network)$/, '\1 system')
    refute_equal @source, two
    error = assert_raises(Erx::ABI::SchemaError) { admit(two) }
    assert_match(/holder requires one value/, error.message)
  end

  def test_an_unconfined_device_without_memory_is_refused
    source, against = with_extra_device(role: 'ordinary', dma: 'unconfined', dma_memory: 0)
    refused(Erx::Manifest::Invalid, 4, 'devices.dma_memory', source, against)
  end

  def test_a_device_with_no_dma_cannot_declare_dma_memory
    source, against = with_extra_device(role: 'ordinary', dma: 'none', dma_memory: 4096)
    refused(Erx::Manifest::Invalid, 4, 'devices.dma_memory', source, against)
  end

  def test_a_partial_boot_record_is_refused_naming_its_milestone
    source = @source.sub('flags development', 'flags development,partial_boot') + "partial_boot probe\n  image @artifact.root\n"
    refused(Erx::Manifest::Unsupported, 'unsupported', 'partial_boot', source, message: /M5/)
  end

  # The release image (docs/design-stopgap.md, "The Phase 1 manifest check"): format
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
    assert_equal [{ 'slot_offset' => 128 << 20, 'length' => 8192 }], (0...view.count('extents')).map { |at| view.fetch('extents', at) }
    windows = (0...view.count('windows')).map { |at| view.fetch('windows', at) }
    verified = windows.select { |row| row.fetch('role') == @codec.member('mf_window_role', 'verified_image') }
    assert_equal [[0, @codec.member('mf_window_rights', 'read')]], verified.map { |row| row.values_at('image', 'rights') }
  end

  def test_an_image_input_must_be_an_image_artifact_of_the_pack
    ['@artifact.root', '@artifact.absent', '"release"'].each do |input|
      refused(Erx::Manifest::Invalid, 8, 'image.input', @source.sub('input @artifact.release', "input #{input}"))
    end
  end

  def test_image_extents_are_sorted_disjoint_sectors_inside_a_slot
    slot = 1_048_576 * 512
    [[], [{ 'slot_offset' => 0, 'length' => 0 }], [{ 'slot_offset' => 1, 'length' => 4096 }],
     [{ 'slot_offset' => slot - 4096, 'length' => 8192 }], [{ 'slot_offset' => 0, 'length' => 4000 }],
     [{ 'slot_offset' => 8192, 'length' => 4096 }, { 'slot_offset' => 0, 'length' => 4096 }],
     [{ 'slot_offset' => 0, 'length' => 4096 }, { 'slot_offset' => 2048, 'length' => 4096 }]].each do |extents|
      against = context { |arguments| arguments[:artifacts] = arguments[:artifacts].merge('release' => { 'kind' => 'erofs_image', 'extents' => extents }) }
      refused(Erx::Manifest::Invalid, 8, 'image.input', @source, against)
    end
  end

  def test_an_image_without_a_tree_takes_no_salt
    refused(Erx::Manifest::Invalid, 8, 'image.salt', @source.sub("input @artifact.release\n", "input @artifact.release\n  salt 0x00\n"))
  end

  def test_a_verified_image_window_is_read_only_and_names_its_image
    refused(Erx::Manifest::Invalid, 8, 'window.rights', @source.sub("  rights read\n  image @image.release", "  rights read,write\n  image @image.release"))
    refused(Erx::Manifest::Invalid, 8, 'window.image', @source.sub('image @image.release', 'image none'))
    refused(Erx::Manifest::Invalid, 8, 'window.image', @source + window(role: 'fat', image: '@image.release'))
  end
end
