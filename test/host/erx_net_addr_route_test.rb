# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the network stack's addresses and routes:
# erx_net_addr and erx_net_route (test/erlang/erx_net_route_tests.erl),
# erx_in6_src (erx_in6_src_tests.erl) and erx_nd6_rtr (erx_nd6_rtr_tests.erl).
class ErxNetAddrRouteTest < Minitest::Test
  include ErxNetEunit

  def test_route_lookup_and_address_checks_pass_under_eunit
    assert_erx_net_eunit(:erx_net_route_tests)
  end

  def test_source_selection_passes_under_eunit
    assert_erx_net_eunit(:erx_in6_src_tests)
  end

  def test_router_advertisements_pass_under_eunit
    assert_erx_net_eunit(:erx_nd6_rtr_tests)
  end
end
