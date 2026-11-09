# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the syncache's EUnit properties, test/erlang/erx_tcp_syncache_tests.erl. Then runs
# them over two copies of erx_tcp_syncache seeded with the faults the design names: a
# rotation that drops the previous secret at once, and an overflow window measured with
# =< where FreeBSD uses <.
class ErxTcpSyncacheTest < Minitest::Test
  include ErxNetEunit

  # rotate/2 writes the new key over the slot that is not current; writing it over the
  # current one forgets the key the last cookies were made with.
  ROTATE = 'setelement(Other + 1, Keys, NewKey)'
  ROTATE_DROPS_PREVIOUS = 'setelement(Current + 1, Keys, NewKey)'
  WINDOW = 'not (Last < uptime(Now)'
  WINDOW_AT_MOST = 'not (Last =< uptime(Now)'

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
end
