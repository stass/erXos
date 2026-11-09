# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the IPv6 and ICMPv6 decisions and their rate limits,
# test/erlang/erx_ip6_decisions_tests.erl (docs/design-network-stack.md, "IPv6, neighbour
# discovery and autoconfiguration"). Then runs them again over a copy of erx_ip6 seeded to
# let a neighbour-discovery message rebuilt by reassembly through, which the cases must
# catch.
class ErxIp6DecisionsTest < Minitest::Test
  include ErxNetEunit

  REASSEMBLED = 'case Origin =:= reassembled orelse lists:keymember(fragment, 1, ExtHdrs) of'
  ATOMIC_ONLY = 'case Origin =:= received andalso lists:keymember(fragment, 1, ExtHdrs) of'

  def test_decision_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_ip6_decisions_tests)
  end

  def test_cases_catch_reassembled_neighbour_discovery_let_through
    output = refute_erx_net_eunit(:erx_ip6_decisions_tests, fault: { 'erx_ip6' => [REASSEMBLED, ATOMIC_ONLY] })
    assert_match(/neighbour_discovery_in_fragments_dropped_test/, output)
  end
end
