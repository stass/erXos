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

  # The echo domain's grant of ble names nus alone, and its row boots the test-only
  # release that starts erx_gatt_echo_test.
  def test_the_manifest_grants_ble_for_nus_to_the_echo_domain
    source = Erx::BtDomain.manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM)
    grant = source[source.index("facet ble\n")..]
    assert grant.start_with?("facet ble\n  grantee @domain.echo\n  service @service.ble\n")
    assert_equal ["  parameter services \"nus\"\n"], grant.lines.grep(/^  parameter /)
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
end
