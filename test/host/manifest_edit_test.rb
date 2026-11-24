# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/manifest_edit'
require_relative '../../tools/lib/erx/platform'

# The edits harnesses make to a manifest (tools/lib/erx/manifest_edit.rb), over the
# manifest's own reader and its one printer (Manifest::Frontend.read and render), on the
# development manifest of QEMU virt.
class ManifestEditTest < Minitest::Test
  Edit = Erx::Manifest::Edit
  Frontend = Erx::Manifest::Frontend
  ROOT = File.expand_path('../..', __dir__)
  VIRT = Erx::Platform.development(ROOT)
  SOURCE = VIRT.manifest_source(ROOT)
  # The display unit's platform unit, of two device-tree devices with 4 and 3 bytes of DMA
  # memory.
  UNITS = [{ 'key' => 'display', 'devices' => [{ 'selector' => 'dt', 'path' => '/gpu@0', 'dma_memory' => 4 },
                                               { 'selector' => 'dt', 'path' => '/gpu@1', 'dma_memory' => 3 }] }].freeze

  # Each record of text by its first line, with what it holds: its properties and facet
  # parameters, each token as its value and whether it is quoted.
  def records(text)
    source = Frontend.read(text)
    [source.machine, *source.records.values.flatten].to_h do |record|
      tokens = ->(list) { list.map { |token| [token.value, token.quoted] } }
      [[record.kind, record.name || record.properties['targets']&.map(&:value)&.join(' ')],
       [record.properties.transform_values(&tokens), record.parameters.map(&tokens)]]
    end
  end

  def value(text, record, field) = Edit.value(text, record: record, field: field)

  # Every board's development manifest, printed, reads back to the same records.
  def test_the_printer_writes_what_the_reader_reads_back
    %w[qemu-virt raspi4b].each do |board|
      source = Erx::Platform.load(root: ROOT, name: board).manifest_source(ROOT)
      printed = Frontend.render(Frontend.read(source))
      assert_equal records(source), records(printed), board
      assert_equal printed, Frontend.render(Frontend.read(printed)), board
    end
    quoted = Erx::ABI::Token.new(value: "a \"b\" \\ \x01", quoted: true)
    assert_equal '"a \"b\" \\\\ \x01"', Frontend.send(:token_text, quoted)
  end

  # A field is reached through its record: the other records keep every field, and the
  # edited records every other one.
  def test_grow_and_set_edit_only_the_named_records_field
    grown = Edit.grow(SOURCE, { ['principal system', 'memory'] => 5, %w[machine root_memory] => -1 })
    set = Edit.set(grown, { %w[machine max_domains] => 7 })
    assert_equal value(SOURCE, 'principal system', 'memory') + 5, value(set, 'principal system', 'memory')
    assert_equal value(SOURCE, 'machine', 'root_memory') - 1, value(set, 'machine', 'root_memory')
    assert_equal 7, value(set, 'machine', 'max_domains')
    changed = records(SOURCE).reject { |key, held| records(set)[key] == held }.keys
    assert_equal [%w[machine], ['principal', 'system']], changed.map(&:compact).sort
    assert_equal 0, value(set, 'limits session', 'outer') - value(SOURCE, 'limits session', 'outer')
  end

  # A record or field that is not there, a value that is not a decimal number, and a
  # result below zero are refused, never applied somewhere else.
  # set states a number its record leaves out only where the record's kind may leave it
  # out: the machine's boot timeout, but no field a domain row does not take.
  def test_set_states_only_an_optional_field_left_out
    stated = Edit.set(SOURCE, { %w[machine boot_timeout_s] => 600 })
    assert_equal 600, value(stated, 'machine', 'boot_timeout_s')
    assert_equal records(SOURCE).except(['machine', nil]), records(stated).except(['machine', nil])
    assert_raises(Erx::Error) { Edit.set(SOURCE, { ['domain storage', 'boot_timeout_s'] => 600 }) }
  end

  def test_an_edit_that_has_no_one_place_is_refused
    root = value(SOURCE, 'machine', 'root_memory')
    { %w[machine absent] => 1, ['principal absent', 'memory'] => 1, %w[nothing root_memory] => 1,
      ['domain display', 'args'] => 1, ['unit display', 'placement'] => 1, %w[machine root_memory] => -root - 1 }
      .each do |field, number|
        assert_raises(Erx::Error, field.join(' ')) { Edit.grow(SOURCE, { field => number }) }
      end
    assert_raises(Erx::Error) { Edit.grow("#{SOURCE}machine\n  root_memory 1\n", { %w[machine root_memory] => 1 }) }
  end

  # A reference is pointed elsewhere only from the one it was: the network row's runtime,
  # and nothing else, changes; a row that no longer reads from is refused.
  def test_repoint_moves_one_reference_from_the_one_it_was
    jit = Edit.repoint(SOURCE, record: 'domain network', field: 'runtime', from: '@artifact.emu', to: '@artifact.jit')
    changed = records(SOURCE).reject { |key, held| records(jit)[key] == held }.keys
    assert_equal [%w[domain network]], changed
    assert_equal [['@artifact.jit', false]], records(jit).dig(%w[domain network], 0, 'runtime')
    [['domain network', 'runtime', '@artifact.emu'], ['domain network', 'absent', '@artifact.emu'],
     ['domain absent', 'runtime', '@artifact.emu'], ['unit display', 'placement', '"display"']].each do |record, field, from|
      assert_raises(Erx::Error, "#{record} #{field}") { Edit.repoint(jit, record: record, field: field, from: from, to: '@x.y') }
    end
  end

  # Named records are taken out and nothing else: no budget moves. A record that is not
  # there, one a record left in names, or the machine, which is never taken, is refused.
  def test_without_takes_only_the_named_records
    gone = Edit.without(SOURCE, ['facet network_ctl', 'service network_ctl'])
    assert_equal [%w[facet network_ctl], %w[service network_ctl]], (records(SOURCE).keys - records(gone).keys).sort
    assert_equal records(SOURCE).slice(*records(gone).keys), records(gone)
    error = assert_raises(Erx::Error) { Edit.without(SOURCE, ['service network_ctl']) }
    assert_match(/facet network_ctl names a record the edit takes out, @service.network_ctl/, error.message)
    assert_raises(Erx::Error) { Edit.without(SOURCE, ['service absent']) }
    assert_raises(Erx::Error) { Edit.without(SOURCE, ['machine']) }
  end

  # A facet's parameter is taken out and nothing else changes: root's display grant without
  # front, as the kiosk's seeded front cell boots it. A parameter the facet does not set
  # is refused, so a second edit of the same row is not silently a no-op.
  def test_without_parameter_takes_only_that_parameter
    plain = Edit.without_parameter(SOURCE, record: 'facet display_root', key: 'front')
    before, after = [SOURCE, plain].map { |text| records(text) }
    root = %w[facet display_root]
    assert_equal before.except(root), after.except(root)
    properties, parameters = before.fetch(root)
    assert_includes parameters, [['front', false], ['yes', false]]
    assert_equal [properties, parameters.reject { |name, _| name.first == 'front' }], after.fetch(root)
    error = assert_raises(Erx::Error) { Edit.without_parameter(plain, record: 'facet display_root', key: 'front') }
    assert_equal "the manifest's facet display_root sets no parameter front", error.message
  end

  # The session templates go with the facets granted to them, and nothing else does.
  def test_without_sessions_takes_the_templates_and_their_facets
    gone = Edit.without_sessions(SOURCE)
    taken = records(SOURCE).keys - records(gone).keys
    refute_empty taken
    assert_equal %w[facet session], taken.map(&:first).uniq.sort
    session_facets = Frontend.read(SOURCE).records.fetch('facet').select { |facet| facet.reference('grantee').start_with?('@session.') }
    assert_equal session_facets.map { |facet| ['facet', facet.name] }.sort, taken.select { |kind, _| kind == 'facet' }.sort
    assert_equal records(SOURCE).slice(*records(gone).keys), records(gone)
    error = assert_raises(Erx::Error) { Edit.without_sessions("#{SOURCE}start system\n  display @session.system\n") }
    assert_match(/start system names a record/, error.message)
  end

  # A part of a manifest, which is no manifest alone, is read record by record, each
  # pointing at its own file and line.
  def test_a_part_is_read_record_by_record
    part = File.binread(File.join(ROOT, VIRT.manifest_path))
    read = Frontend.records(part, path: VIRT.manifest_path)
    machine = read.find { |record| record.kind == 'machine' }
    assert_equal VIRT.manifest_path, machine.line.path
    assert_equal "machine\n", part.lines[machine.line.number - 1]
    assert_raises(Erx::Manifest::Invalid) { Frontend.read(part) }
    assert_raises(Erx::Error) { Frontend.records("facet f\n  grantee system\n", path: 'part.txt') }
  end

  # Taking the display domain out takes its records and those only it named, keeps the
  # share and runtime limits other records still name, and gives back its room: its
  # budgets from the principal and root_memory, its unit's DMA memory (4 and 3) from
  # root_memory, one domain, and one connection with the two of root's display_root,
  # its session's and a replacement session's, and the one usb_input takes, of the USB
  # domain's limits too.
  def test_without_domain_takes_its_records_and_gives_back_its_room
    gone = Edit.without_domain(SOURCE, 'display', units: UNITS)
    taken = records(SOURCE).keys - records(gone).keys
    assert_equal [%w[display display], %w[domain display], %w[facet display_root], %w[facet usb_input], %w[limits display], %w[runtime_limits display],
                  %w[service display], %w[share display], %w[unit display]], taken.sort
    budget = value(SOURCE, 'limits display', 'memory') + value(SOURCE, 'limits display', 'outer')
    { ['principal system', 'memory'] => -budget, ['principal system', 'domains'] => -1,
      %w[machine root_memory] => -budget - 7, %w[machine max_domains] => -1, %w[machine max_connections] => -4,
      ['limits usb', 'connections'] => -1 }
      .each do |(record, field), change|
        assert_equal value(SOURCE, record, field) + change, value(gone, record, field), "#{record} #{field}"
      end
    kept = records(gone).reject { |key, _held| [%w[machine], %w[principal system], %w[limits usb]].include?(key.compact) }
    assert_equal records(SOURCE).slice(*kept.keys), kept
  end

  # A domain's windows go with it, as its units do: the media domain's drive window
  # disk0 leaves with the domain, and nothing else that names no record taken out.
  # The window is the drive grant that joins the media domain to the USB domain, whose
  # xhci unit the drive lies on, so its connection comes back to the USB domain's limits
  # and to max_connections beside the media domain's system connection.
  def test_without_domain_takes_the_windows_it_holds
    gone = Edit.without_domain(SOURCE, 'media', units: VIRT.record.fetch('units'))
    taken = records(SOURCE).keys - records(gone).keys
    assert_equal [%w[domain media], %w[limits media], %w[runtime_limits media], %w[service media], %w[share media],
                  %w[window disk0]], taken.sort
    { %w[machine max_connections] => -2, ['limits usb', 'connections'] => -1 }.each do |(record, field), change|
      assert_equal value(SOURCE, record, field) + change, value(gone, record, field), "#{record} #{field}"
    end
  end

  # A window lies on its device's unit, so taking out the domain that holds the unit takes
  # out every window on it, another domain's too: the USB domain takes the media domain's
  # drive window disk0 on its xhci unit, and its drive grant's connection, of the media
  # domain's limits and of max_connections, beside the USB domain's system connection and
  # the one usb_input takes. The xhci unit's DMA memory comes back to root_memory.
  def test_without_domain_takes_the_windows_on_its_units
    units = VIRT.record.fetch('units')
    gone = Edit.without_domain(SOURCE, 'usb', units: units)
    taken = records(SOURCE).keys - records(gone).keys
    assert_includes taken, %w[window disk0]
    assert_equal [%w[window disk0]], taken.select { |kind, _name| kind == 'window' }
    { %w[machine max_connections] => -3, ['limits media', 'connections'] => -1, ['limits display', 'connections'] => -1 }
      .each do |(record, field), change|
        assert_equal value(SOURCE, record, field) + change, value(gone, record, field), "#{record} #{field}"
      end
  end

  # A platform device the edit cannot name, a PCIe function without its bridge or an entry
  # that is not a record, is refused as the edit's error, not a Ruby one, whether the
  # domain taken holds the unit it lies on (usb) or only a drive window (media).
  def test_without_domain_refuses_a_platform_device_it_cannot_name
    units = VIRT.record.fetch('units')
    [{ 'selector' => 'pci', 'bus' => 0, 'device' => 1, 'function' => 0 }, 'pci'].product(%w[usb media]).each do |device, name|
      malformed = [{ 'key' => 'malformed', 'devices' => [device] }, *units]
      error = assert_raises(Erx::Error) { Edit.without_domain(SOURCE, name, units: malformed) }
      assert_match(/malformed/, error.message)
    end
  end

  # with_unit places a unit and grows root_memory by its devices' DMA memory, giving back
  # what without_domain took for it; a key the platform has no unit of is refused.
  def test_with_unit_places_a_unit_with_its_room
    gone = Edit.without_domain(SOURCE, 'display', units: UNITS)
    placed = Edit.with_unit(gone, 'display', holder: '@domain.storage', units: UNITS)
    assert_equal value(gone, 'machine', 'root_memory') + 7, value(placed, 'machine', 'root_memory')
    assert placed.end_with?("unit display\n  placement \"display\"\n  holder @domain.storage\n")
    assert_raises(Erx::Error) { Edit.with_unit(gone, 'absent', holder: 'system', units: UNITS) }
  end

  # without_ble undoes offering: ble leaves the row's services, its gatt goes with it, and
  # max_connections gives back the connection each of the row's max apps made to the
  # Bluetooth domain; nothing else changes. A row that offers no ble is refused.
  def test_without_ble_takes_ble_and_its_gatt_out_of_the_apps_row
    offered = Edit.offering(SOURCE, service: 'ble', gatt: %w[nus])
    gone = Edit.without_ble(offered)
    assert_equal records(SOURCE), records(gone)
    assert_nil Frontend.read(gone).records.fetch('apps').first.properties['gatt']
    error = assert_raises(Erx::Error) { Edit.without_ble(SOURCE) }
    assert_equal "the manifest's apps row offers no ble", error.message
  end

  # The apps row taken out gives back its memory in root_memory, its max apps in
  # max_domains and, in max_connections, each app's system connection, its packages
  # connection and one for each service of the row, and nothing else changes; a
  # manifest with no apps row is returned as it is, and the site manifest carries none.
  def test_without_apps_takes_the_row_and_gives_back_its_room
    gone = Edit.without_apps(SOURCE)
    assert_equal [%w[apps]], records(SOURCE).keys.map(&:compact) - records(gone).keys.map(&:compact)
    apps = Frontend.read(SOURCE).records.fetch('apps').first
    max = apps.decimal('max')
    { 'root_memory' => -apps.decimal('memory'), 'max_domains' => -max,
      'max_connections' => -max * (2 + apps.properties.fetch('services').size) }.each do |field, change|
      assert_equal value(SOURCE, 'machine', field) + change, value(gone, 'machine', field), field
    end
    kept = records(gone).reject { |key, _held| key.compact == %w[machine] }
    assert_equal records(SOURCE).slice(*kept.keys), kept
    assert_equal gone, Edit.without_apps(gone)
    refute_match(/^apps$/, VIRT.site_manifest_source(ROOT))
  end

  # A share the machine names stays when the domain's limits name it too: the machine
  # is among the records that keep a definition in use.
  def test_without_domain_keeps_what_the_machine_names
    source = SOURCE.sub(/^(limits display\n(?:  .*\n)*?)  grant @share\.display\n/, "\\1  grant @share.system\n")
    refute_equal SOURCE, source
    assert_includes records(Edit.without_domain(source, 'display', units: UNITS)).keys, %w[share system]
  end

  # A domain that is not there, whose service is granted to another principal's template,
  # which leaves a record naming one it took, or whose unit is on no platform unit, is
  # refused.
  def test_without_domain_refuses_what_it_cannot_take_whole
    [['absent', SOURCE, /no record "@domain.absent"/],
     ['web', SOURCE.sub("facet web\n  grantee system\n", "facet web\n  grantee @session.other\n"), /granted by facet web/],
     ['display', "#{SOURCE}start system\n  display @service.display\n", /start system names a record/],
     ['display', "#{SOURCE}introduce @domain.storage @domain.display\n",
      /introduce @domain.storage @domain.display names a record/],
     ['display', SOURCE.sub('placement "display"', 'placement "spare"'), /placed on "spare"/]].each do |name, source, message|
      error = assert_raises(Erx::Error) { Edit.without_domain(source, name, units: UNITS) }
      assert_match message, error.message
    end
  end

  # A facet granting the domain's service to root's template goes with the domain and
  # gives back two of max_connections beside the domain's own one: its session's
  # connection and the one a replacement session makes beside it.
  def test_without_domain_takes_a_session_template_s_grant_with_its_connections
    granted = SOURCE.sub("facet web\n  grantee system\n", "facet web\n  grantee @session.system\n")
    connections = ->(text) { Erx::Manifest::Frontend.read(text).machine.decimal('max_connections') }
    taken = Edit.without_domain(granted, 'web', units: UNITS)
    assert_equal connections.(Edit.without_domain(SOURCE, 'web', units: UNITS)) - 2, connections.(taken)
    refute_match(/^facet web$/, taken)
  end

  # A facet granting the domain's service to another configured domain, as usb_input is
  # the display's, goes with the domain and gives back that domain's connection to it,
  # from its limits and from max_connections, beside the domain's own system connection.
  def test_without_domain_takes_a_grant_to_another_domain_with_its_connections
    granted = SOURCE.sub("facet web\n  grantee system\n", "facet web\n  grantee @domain.storage\n")
    taken = Edit.without_domain(granted, 'web', units: UNITS)
    refute_match(/^facet web$/, taken)
    assert_equal value(granted, 'machine', 'max_connections') - 2, value(taken, 'machine', 'max_connections')
    assert_equal value(granted, 'limits storage', 'connections') - 1, value(taken, 'limits storage', 'connections')
  end

  # A facet granting the domain a service of the system domain, as pci_bus is the PCIe
  # domain's, goes with the domain and gives back nothing beside the domain's own system
  # connection, which carries it; one granting it a service another domain serves goes too, and gives back
  # one connection of the server's limits and one of max_connections.
  def test_without_domain_takes_the_system_services_granted_to_it
    units = VIRT.record.fetch('units')
    connections = ->(text) { Erx::Manifest::Frontend.read(text).machine.decimal('max_connections') }
    taken = Edit.without_domain(SOURCE, 'pcie', units: units)
    refute_match(/^facet pci_bus$/, taken)
    assert_equal connections.(SOURCE) - 1, connections.(taken)
    peer = "#{SOURCE}facet peer\n  grantee @domain.pcie\n  service @service.storage_ctl\n  operations none\n" \
           "  max_request 1024\n  in_flight 1\n  reductions 100000\n  period_ns 1000000000\n  max_heap_size 8192\n"
    taken_peer = Edit.without_domain(peer, 'pcie', units: units)
    refute_match(/^facet peer$/, taken_peer)
    assert_equal connections.(peer) - 2, connections.(taken_peer)
    assert_equal value(peer, 'limits storage', 'connections') - 1, value(taken_peer, 'limits storage', 'connections')
  end
end
