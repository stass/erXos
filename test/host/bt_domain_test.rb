# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/bt_domain'

# The Bluetooth suite's harness (tools/lib/erx/bt_domain.rb): the bring-up case's check of
# the shell's answer, and the manifest's line grant on the platform's line unit. The
# manifest's admission and plan are dom_planner_test's.
class BtDomainTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PLATFORM = Erx::Platform.development(ROOT)
  LOG = 'serial-peer.log'

  # The facts the Bluetooth domain prints come as a string after the prompt; a timeout, a
  # missing domain or a term that arrived as a foreign reason is refused with what came.
  def test_the_bring_up_case_wants_the_facts_as_a_string
    Erx::BtDomain.check_ready(%(4> {bt_ready,"\#{core => \#{free => 8},ready => \#{free => 8}}"}\r\n))
    ['{bt_ready,{timeout,none}}', '{bt_ready,{no_domain,[]}}',
     "{bt_ready,{timeout,{'EXIT',{signal,{erx_foreign_reason,<<131>>}}}}}"].each do |answer|
      error = assert_raises(Erx::Error) { Erx::BtDomain.check_ready(answer) }
      assert_includes error.message, answer
    end
  end

  # The grant names the platform's line unit's virtio console and states no rate or flow,
  # and the manifest places that unit on the system domain.
  def test_the_manifest_grants_the_line_unit_s_console
    source = Erx::BtDomain.manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM)
    assert_includes source, "unit line\n  placement \"line\"\n  holder system\n"
    assert_includes source, "  parameter device \"/virtio_mmio@a000e00\"\n"
    refute_match(/^  parameter (rate|flow)/, source[source.index("facet line\n")..])
  end

  # The echo domain's grant of ble names nus, which its handler attaches, and bondcheck,
  # which runs no handler (docs/design-bluetooth.md, "The bond check"), and its row boots
  # the test-only release that starts erx_gatt_echo_test.
  def test_the_manifest_grants_ble_for_nus_and_bondcheck_to_the_echo_domain
    source = Erx::BtDomain.manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM)
    grant = source[source.index("facet ble\n")..]
    assert grant.start_with?("facet ble\n  grantee @domain.echo\n  service @service.ble\n")
    assert_equal ["  parameter services \"nus\"\n", "  parameter services \"bondcheck\"\n"], grant.lines.grep(/^  parameter /)
    assert_includes source, "domain echo\n"
    assert_includes source, "  release @artifact.#{Erx::BtDomain::ECHO_BOOT.name}\n"
    assert_includes Erx::BtDomain::ECHO_BOOT.applications, 'erx_gatt_echo_test'
  end

  # The app cell's manifest: the apps row offers ble beside its services and gatt nus,
  # each of its apps gains the connection to ble's server, and no echo domain or grant of
  # ble to one is left, so the echo answers only through the app's own grant. Both cells
  # start from one medium manifest, so the app cell leaves out the media domain as the
  # echo cell does, and its connections are the echo cell's without the echo's own
  # (BtDomain::ECHO_CONNECTIONS) and with one per app.
  def test_the_app_cell_offers_ble_and_nus_to_apps_in_place_of_the_echo_domain
    source = Erx::BtDomain.app_manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM)
    apps = source[source.index("\napps\n")..][/\A\napps\n(?:  [^\n]*\n)+/]
    assert_includes apps, "  services display net ble\n"
    assert_includes apps, "  gatt nus\n"
    refute_includes source, "domain echo\n"
    refute_includes source, "facet ble\n"
    refute_includes source, "domain media\n"
    assert_includes source, "service ble\n  server @domain.bt\n"
    assert_includes source, "service bluetooth\n  server @domain.bt\n  interface svc\n"
    plain = Erx::BtDomain.manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM)
    connections = ->(text) { Erx::Manifest::Edit.value(text, record: 'machine', field: 'max_connections') }
    max = Erx::Manifest::Edit.value(source, record: 'apps', field: 'max')
    assert_equal connections.call(plain) - Erx::BtDomain::ECHO_CONNECTIONS + max, connections.call(source)
  end

  # The echo case passes only when the echo domain answers that its handler attached nus.
  def test_the_echo_case_wants_the_application_started
    Erx::BtDomain.check_echo("5> {bt_echo,attached}\r\n")
    ['{bt_echo,timeout}', '{bt_echo,{no_domain,[]}}', '{bt_echo,attached,more}'].each do |answer|
      error = assert_raises(Erx::Error) { Erx::BtDomain.check_echo(answer) }
      assert_includes error.message, answer
    end
  end

  # The serial row passes on the peer's one passing line; any other output fails with it
  # escaped, so a control byte the peer printed never reaches the terminal raw.
  def test_the_serial_row_wants_the_peer_s_passing_line
    Erx::BtDomain::Serial.check("serial passed 65536 247\n", log: LOG)
    ["serial failed 12 of 65536 octets back within 60 s\n", '', "serial passed 65536 247\nmore\n"].each do |output|
      assert_raises(Erx::Error) { Erx::BtDomain::Serial.check(output, log: LOG) }
    end
    error = assert_raises(Erx::Error) { Erx::BtDomain::Serial.check("serial failed \e]0;x\a\n", log: LOG) }
    refute_includes error.message, "\e"
  end

  # The bleuart cell's manifest keeps the system principal's session template, so the
  # console logs root in and root_line has a session to answer, carries the Pi 4's
  # bleuart records whole, and grows max_domains by its one domain; it has no echo
  # domain, so nus has one handler.
  def test_the_bleuart_manifest_runs_bleuart_beside_root_s_session
    board = Erx::Platform.load(root: ROOT, name: Erx::BtDomain::BLEUART_PLATFORM).manifest_source(ROOT)
    source = Erx::BtDomain.bleuart_manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM, board: board)
    assert_includes source, "session system\n"
    assert_includes source, "start bleuart\n  enable YES\n  published_enable NO\n"
    assert_includes source, "  operations root_line\n"
    %w[inspect start].each { |facet| assert_includes source, "facet #{facet}\n  grantee @session.system\n" }
    refute_includes source, "domain echo\n"
    plain = Erx::BtDomain.app_manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM)
    domains = ->(text) { Erx::Manifest::Edit.value(text, record: 'machine', field: 'max_domains') }
    assert_equal domains.call(plain) + 1, domains.call(source)
  end

  # Every cell declares the store's development grant, bt_state, whose row the build
  # derives to the Bluetooth domain; the bleuart cell, the one with root's template,
  # carries root's grant of the control tree from the Pi 4's manifest, with room for it
  # and its replacement in max_connections.
  def test_the_cells_declare_the_store_and_the_bleuart_cell_grants_root_the_tree
    store = "service bt_state\n  server @domain.storage\n  interface files\n"
    plain = Erx::BtDomain.app_manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM)
    [Erx::BtDomain.manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM), plain].each do |source|
      assert_includes source, store
      refute_includes source, "facet bluetooth_root\n"
    end
    board = Erx::Platform.load(root: ROOT, name: Erx::BtDomain::BLEUART_PLATFORM).manifest_source(ROOT)
    source = Erx::BtDomain.bleuart_manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM, board: board)
    grant = source[source.index("facet bluetooth_root\n")..][/\Afacet bluetooth_root\n(?:  [^\n]*\n)+/]
    assert_includes grant, "  grantee @session.system\n  service @service.bluetooth\n"
    assert_includes grant, "  parameter rights rw\n"
    connections = ->(text) { Erx::Manifest::Edit.value(text, record: 'machine', field: 'max_connections') }
    echo = Erx::BtDomain.manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM)
    assert_equal connections.call(echo) - Erx::BtDomain::ECHO_CONNECTIONS + Erx::BtDomain::BLEUART_CONNECTIONS +
                 Erx::BtDomain::ROOT_BLUETOOTH_CONNECTIONS, connections.call(source)
    storage = ->(text) { Erx::Manifest::Edit.value(text, record: 'limits storage', field: 'connections') }
    assert_equal storage.call(echo) + Erx::BtDomain::STORAGE_CONNECTIONS, storage.call(source)
  end

  # bleuart's peers pass on their own passing lines alone: the shell peer's is not the
  # absent peer's, nor the serial peer's.
  def test_the_bleuart_rows_want_their_own_peer_s_line
    shell = Erx::BtDomain::Serial::BLEUART_SHELL
    Erx::BtDomain::Serial.check("bleuart passed shell\n", log: LOG, script: shell)
    Erx::BtDomain::Serial.check("bleuart passed absent\n", log: LOG, script: Erx::BtDomain::Serial::BLEUART_ABSENT)
    ["bleuart passed absent\n", "bleuart failed ps on the line lists the system domain's login service\n",
     "serial passed 65536 247\n"].each do |output|
      assert_raises(Erx::Error) { Erx::BtDomain::Serial.check(output, log: LOG, script: shell) }
    end
  end
end
