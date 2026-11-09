# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the syncache's EUnit properties, test/erlang/erx_tcp_syncache_tests.erl. Then runs
# them over copies of erx_tcp_syncache seeded with the faults the design names: a
# rotation that drops the previous secret at once, an overflow window measured with
# =< where FreeBSD uses <, and a pause held through its last second.
class ErxTcpSyncacheTest < Minitest::Test
  include ErxNetEunit

  # rotate/2 writes the new key over the slot that is not current; writing it over the
  # current one forgets the key the last cookies were made with.
  ROTATE = 'setelement(Other + 1, Keys, NewKey)'
  ROTATE_DROPS_PREVIOUS = 'setelement(Current + 1, Keys, NewKey)'
  WINDOW = 'not (Last < uptime(Now)'
  WINDOW_AT_MOST = 'not (Last =< uptime(Now)'
  # The pause holds while uptime is before its end; holding it through the end second too
  # keeps the table cookies-only one second longer than FreeBSD's syncache_unpause.
  PAUSE = 'uptime(Now) < Until'
  PAUSE_THROUGH_END = 'uptime(Now) =< Until'
  # tcp_input.c:1297 and :1320 drop a SYN to or from itself before the syncache.
  NO_SELF = 'admissible({Addr, Port, Addr, Port}) -> false;'
  SELF_ADMITTED = 'admissible({Addr, Port, Addr, Port}) when Port < 0 -> false;'

  def test_syncache_properties_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_syncache_tests)
  end

  def test_rotation_property_catches_a_dropped_previous_secret
    output = refute_erx_net_eunit(:erx_tcp_syncache_tests,
                                  fault: { 'erx_tcp_syncache' => [ROTATE, ROTATE_DROPS_PREVIOUS] })
    assert_match(/rotation_test/, output)
  end

  def test_overflow_window_catches_an_inclusive_comparison
    output = refute_erx_net_eunit(:erx_tcp_syncache_tests,
                                  fault: { 'erx_tcp_syncache' => [WINDOW, WINDOW_AT_MOST] })
    assert_match(/overflow_window_test/, output)
  end

  def test_pause_property_catches_a_pause_held_through_its_end
    output = refute_erx_net_eunit(:erx_tcp_syncache_tests,
                                  fault: { 'erx_tcp_syncache' => [PAUSE, PAUSE_THROUGH_END] })
    assert_match(/pause_test/, output)
  end

  def test_address_checks_catch_a_connection_to_itself
    output = refute_erx_net_eunit(:erx_tcp_syncache_tests,
                                  fault: { 'erx_tcp_syncache' => [NO_SELF, SELF_ADMITTED] })
    assert_match(/address_checks_test/, output)
  end
end
