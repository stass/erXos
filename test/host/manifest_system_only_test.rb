# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../../tools/lib/erx/manifest'
require_relative '../fixtures/manifest_context'

# Phase 1's manifest check (docs/design-stopgap.md): each kept property of
# design-system.md has a seeded violation here and each refusal a seeded record.
# Every seed edits the real development manifest or the real platform record,
# so a seed fails for its own reason and not for an unrelated difference.
class ManifestSystemOnlyTest < Minitest::Test
  BLOCK = '/virtio_mmio@a003e00'
  DOMAIN = "domain d\n  principal @principal.system\n  limits @limits.native\n  kind service\n  flags none\n" \
           "  runtime \"r\"\n  release \"r\"\n  restarts 0\n  restart_period_s 0\n"
  SERVICE = "service log\n  server system\n  interface 1\n"

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

  def admit(source = @source, against = @context)
    Erx::Manifest.admit(source: source, codec: @codec, context: against)
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
    device = @platform.fetch('units').last.fetch('devices').first
                      .merge('path' => '/extra@0', 'placement_key' => 'extra', 'dma' => 'none', 'dma_memory' => 0)
                      .merge(fields.transform_keys(&:to_s))
    platform = platform_with { |value| value.fetch('units') << { 'key' => 'extra', 'devices' => [device] } }
    [@source + "unit extra\n  placement \"extra\"\n  holder system\n", context(platform: platform)]
  end

  def window(role:, partition: 1, device: BLOCK, holder: 'system', image: 'none')
    "window seeded\n  holder #{holder}\n  device \"#{device}\"\n  role #{role}\n  partition #{partition}\n" \
      "  rights read\n  image #{image}\n"
  end

  def test_the_real_development_manifest_is_admitted
    result = admit
    assert_instance_of Erx::Manifest::Admitted, result
    assert result.matches?(@context)
    assert result.bytes.frozen?
    view = @codec.open('manifest', result.bytes)
    assert_equal 0, view.count('domains')
    assert_equal 3, view.count('devices')
    assert_equal 5, view.count('windows')
  end

  def test_the_report_claims_only_what_was_checked
    report = admit.report
    assert_equal 'system_only', report.fetch('mode')
    assert_equal 'declared', report.fetch('root_startup')
    assert_equal 'supplied_catalog', report.fetch('executable')
    assert_equal 'supplied_context', report.fetch('provenance')
    assert_equal 'unsupported', report.fetch('policy_admission')
    assert_equal 0, report.fetch('child_plan_instances')
    assert_equal 0, report.fetch('dynamic_domain_reservation')
    assert_equal @platform.fetch('fiasco_reserve'), report.fetch('fiasco_reserve')
    assert_equal @platform.fetch('ram_bytes'), report.fetch('ram_bytes')
    assert_equal 4096, report.fetch('root_image_loadable_bytes')
  end

  def test_a_partial_boot_flag_without_partial_boot_records_is_admitted
    source = @source.sub('flags development', 'flags development,partial_boot')
    assert_equal 'system_only', admit(source).report.fetch('mode')
  end

  def test_a_partial_boot_runs_no_services
    source = @source.sub('flags development', 'flags development,partial_boot') + SERVICE
    refused(Erx::Manifest::Invalid, 2, 'service', source)
  end

  def test_admitted_services_reach_the_encoded_manifest
    view = @codec.open('manifest', admit(@source + SERVICE).bytes)
    assert_equal 1, view.count('services')
    assert_equal 0, view.count('liveness')
  end

  # The watchdog pets whether or not a service lives, so a record that says it watches one is refused.
  def test_a_liveness_record_is_refused_because_nothing_reads_it
    refused(Erx::Manifest::Unsupported, 'unsupported', 'liveness', @source + SERVICE + "liveness @service.log\n",
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
    refused(Erx::Manifest::Invalid, 1, 'unit.holder', @source.sub("placement \"block\"\n  holder system", "placement \"block\"\n  holder storage"))
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

  def test_a_facet_naming_no_service_is_refused
    facet = "facet f\n  grantee system\n  service @service.absent\n  operations none\n  max_request 1\n" \
            "  in_flight 1\n  reductions 1\n  period_ns 1\n  max_heap_size 1\n"
    refused(Erx::Manifest::Invalid, 2, 'facet.service', @source + SERVICE + facet)
  end

  def test_a_facet_with_a_service_is_refused_because_no_domain_can_hold_it
    facet = "facet f\n  grantee system\n  service @service.log\n  operations none\n  max_request 1\n" \
            "  in_flight 1\n  reductions 1\n  period_ns 1\n  max_heap_size 1\n"
    refused(Erx::Manifest::Unsupported, 'unsupported', 'facet', @source + SERVICE + facet, message: /M5/)
  end

  def test_an_introduction_is_refused_naming_its_milestone
    refused(Erx::Manifest::Unsupported, 'unsupported', 'introduce', @source + "introduce a b\n", message: /M5/)
  end

  # Property 3: no holder of PCIe configuration space.
  def test_a_configuration_space_holder_is_refused
    source, against = with_extra_device(role: 'configuration')
    refused(Erx::Manifest::Invalid, 3, 'devices.role', source, against, message: /M9/)
  end

  # Property 4: budgets, grants and the root startup rule.
  def test_budgets_over_root_memory_are_refused
    refused(Erx::Manifest::Invalid, 4, 'principals.memory', @source.sub('memory 134217728', 'memory 335544321'))
  end

  def test_device_memory_counts_against_root_memory
    # Principal and baseline alone fit by exactly the device's reservation less one page.
    source = @source.sub('memory 134217728', "memory #{402_653_184 - 134_217_728 - 2_097_152 + 4096}")
    refused(Erx::Manifest::Invalid, 4, 'principals.memory', source)
  end

  def test_a_nonzero_max_domains_is_refused
    refused(Erx::Manifest::Invalid, 4, 'machine.max_domains', @source.sub('max_domains 0', 'max_domains 4'), message: /M5/)
  end

  def test_a_principal_domain_quota_is_refused
    refused(Erx::Manifest::Invalid, 4, 'principals.domains', @source.sub('domains 0', 'domains 1'))
  end

  def test_shares_over_the_root_rate_are_refused
    refused(Erx::Manifest::Invalid, 4, 'machine.shares', @source.sub('quota_ns 30000000', 'quota_ns 40000000'))
  end

  def test_root_memory_over_ram_less_the_reserve_is_refused
    refused(Erx::Manifest::Invalid, 4, 'root_startup', @source.sub('root_memory 402653184', 'root_memory 469766144'), message: /fiasco_reserve/)
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

  # Property 5: names.
  def test_a_host_name_that_is_no_identifier_is_refused
    refused(Erx::Manifest::Invalid, 5, 'machine.host', @source.sub('host "erxos"', 'host "Not An Identifier"'))
  end

  def test_two_services_sharing_a_name_are_refused
    second = "service other\n  name \"log\"\n  server system\n  interface 2\n"
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

  # Property 8: the UARTs, the windows and the network device.
  def test_the_console_and_host_link_must_differ
    refused(Erx::Manifest::Invalid, 8, 'machine.hostlink', @source.sub('hostlink "/pl011@9040000"', 'hostlink "/pl011@9000000"'))
  end

  def test_an_unassigned_console_is_refused
    source = @source.sub("unit console\n  placement \"console-uart\"\n  holder system\n", '')
    refused(Erx::Manifest::Invalid, 8, 'machine.console', source)
  end

  def test_a_network_device_is_refused
    source, against = with_extra_device(role: 'network')
    refused(Erx::Manifest::Invalid, 8, 'devices.role', source, against, message: /M9/)
  end

  def test_a_vault_window_is_refused
    refused(Erx::Manifest::Invalid, 8, 'window.role', @source + window(role: 'vault'), message: /M11/)
  end

  def test_a_window_held_by_another_domain_is_refused
    refused(Erx::Manifest::Invalid, 8, 'window.holder', @source + window(role: 'fat', holder: 'storage'), message: /M9/)
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
    roles = rows.map { |row| row.fetch('role') }
    assert_equal roles.sort, roles
    rows.each do |row|
      assert_equal @codec.member('mf_device_role', 'block'), view.fetch('devices', row.fetch('device')).fetch('role')
    end
  end

  def test_a_source_alias_does_not_reach_the_bytes
    assert_equal admit.bytes, admit(@source.sub('window data', 'window zzz')).bytes
  end

  def test_services_sort_by_encoded_name
    services = "service zeta\n  name \"alpha\"\n  server system\n  interface 1\n" \
               "service alpha\n  name \"zeta\"\n  server system\n  interface 2\n"
    view = @codec.open('manifest', admit(@source + services).bytes)
    assert_equal 1, view.fetch('services', 0).fetch('interface')
    assert_equal 2, view.fetch('services', 1).fetch('interface')
  end

  def test_a_pci_function_is_refused
    source, against = with_extra_device(selector: 'pci', role: 'ordinary', bridge: '/pcie@0', path: '')
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
    assert_instance_of Erx::Manifest::Admitted, admit(@source.sub('root_memory 402653184', 'root_memory 469762048'))
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

  def test_an_unconfined_device_without_memory_is_refused
    source, against = with_extra_device(role: 'ordinary', dma: 'unconfined', dma_memory: 0)
    refused(Erx::Manifest::Invalid, 4, 'devices.dma_memory', source, against)
  end

  def test_a_device_with_no_dma_cannot_declare_dma_memory
    source, against = with_extra_device(role: 'ordinary', dma: 'none', dma_memory: 4096)
    refused(Erx::Manifest::Invalid, 4, 'devices.dma_memory', source, against)
  end

  # Records of later milestones, 10 to 13 among them.
  def test_a_domain_record_is_refused_naming_its_milestone
    refused(Erx::Manifest::Unsupported, 'unsupported', 'domain', @source + DOMAIN, message: /M5/)
  end

  def test_a_partial_boot_record_is_refused_naming_its_milestone
    source = @source.sub('flags development', 'flags development,partial_boot') + "partial_boot probe\n  image @artifact.root\n"
    refused(Erx::Manifest::Unsupported, 'unsupported', 'partial_boot', source, message: /M5/)
  end

  def test_an_image_record_is_refused_naming_its_milestone
    refused(Erx::Manifest::Unsupported, 'unsupported', 'image', @source + "image i\n  device \"d\"\n  input \"i\"\n", message: /M6/)
  end

  def test_a_verified_image_window_is_refused_naming_its_milestone
    refused(Erx::Manifest::Unsupported, 'unsupported', 'window.role', @source + window(role: 'verified_image'), message: /M6/)
  end

  def test_a_window_naming_an_image_is_refused
    refused(Erx::Manifest::Unsupported, 'unsupported', 'window.image', @source + window(role: 'fat', image: '@image.i'), message: /M6/)
  end
end
