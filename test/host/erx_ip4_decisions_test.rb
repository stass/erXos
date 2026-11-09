# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the IPv4, ICMPv4 and UDP decisions and the rate limits,
# test/erlang/erx_ip4_decisions_tests.erl. Then runs them again over a copy of
# erx_net_bandlim seeded with a limit that never refuses, which the property under
# virtual time must catch (docs/design-network-stack.md, "IPv4 and ARP").
class ErxIp4DecisionsTest < Minitest::Test
  include ErxNetEunit

  OVER = 'case Count + 1 > ?ICMPLIM + W#window.jitter of'
  NEVER_OVER = 'case Count + 1 > ?ICMPLIM * 1000 + W#window.jitter of'

  def test_decision_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_ip4_decisions_tests)
  end

  def test_property_catches_a_limit_that_never_refuses
    output = refute_erx_net_eunit(:erx_ip4_decisions_tests, fault: { 'erx_net_bandlim' => [OVER, NEVER_OVER] })
    assert_match(/limits_hold_under_virtual_time_test/, output)
  end
end
