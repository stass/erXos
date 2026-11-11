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
class ManifestStopgapTest < Minitest::Test
  BLOCK = '/virtio_mmio@a003e00'
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

  # source, which a test made from the development manifest, after checking that it
  # differs from it, so a substitution that no longer matches fails rather than
  # testing the manifest unchanged.
  def changed(source)
    refute_equal @source, source, 'the substitution matches the development manifest'
    source
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
    assert_equal 0, view.count('domains')
    assert_equal 4, view.count('devices')
    assert_equal 6, view.count('windows')
    assert_equal 1, view.count('images')
  end

  def test_the_report_claims_only_what_was_checked
    report = admit.report
    assert_equal 'stopgap', report.fetch('mode')
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

  # The development manifest as a partial boot, which makes no sessions, so without
  # its session template.
  def partial_boot = changed(@source.sub('flags development', 'flags development,partial_boot').sub(/^session system\n(?:  .*\n)*/, ''))

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
  def device_memory = @platform.fetch('units').sum { |unit| unit.fetch('devices').sum { |device| device.fetch('dma_memory') } }

  # Principal and baseline fit with the devices' reservations exactly, and one page
  # more does not.
  def test_device_memory_counts_against_root_memory
    assert admit(with_system_memory(root_memory - baseline - device_memory))
    refused(Erx::Manifest::Invalid, 4, 'principals.memory', with_system_memory(root_memory - baseline - device_memory + 4096))
  end

  def test_a_principal_domain_quota_is_refused
    refused(Erx::Manifest::Invalid, 4, 'principals.domains', changed(@source.sub(/^(principal system\n(?:  .*\n)*?  domains )(\d+)$/) { "#{Regexp.last_match(1)}#{Integer(Regexp.last_match(2)) + 1}" }))
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

  # Property 5: names.
  def test_a_host_name_that_is_no_identifier_is_refused
    refused(Erx::Manifest::Invalid, 5, 'machine.host', @source.sub('host "erxos"', 'host "Not An Identifier"'))
  end

  def test_a_host_name_with_a_dot_is_refused
    refused(Erx::Manifest::Invalid, 5, 'machine.host', @source.sub('host "erxos"', 'host "a.b"'))
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

  # Property 8: the UARTs and the windows.
  def test_the_console_and_host_link_must_differ
    refused(Erx::Manifest::Invalid, 8, 'machine.hostlink', @source.sub('hostlink "/pl011@9040000"', 'hostlink "/pl011@9000000"'))
  end

  def test_an_unassigned_console_is_refused
    source = @source.sub("unit console\n  placement \"console-uart\"\n  holder system\n", '')
    refused(Erx::Manifest::Invalid, 8, 'machine.console', source)
  end

  # The network stack runs in the system domain in Phase 1, over the device its unit
  # places there (docs/design-stopgap.md, "Device records").
  def test_a_network_device_is_admitted
    source, against = with_extra_device(role: 'network')
    admit(source, against)
  end

  def test_a_vault_window_is_refused
    refused(Erx::Manifest::Invalid, 8, 'window.role', @source + window(role: 'vault'), message: /M11/)
  end

  def test_a_window_held_by_no_configured_domain_is_refused
    refused(Erx::Manifest::Invalid, 8, 'window.holder', @source + window(role: 'fat', holder: '@domain.storage'))
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
    two = @source.sub(/^(unit net\n  placement "net"\n  holder system)$/, '\1 system')
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
