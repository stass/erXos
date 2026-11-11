# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the socket protocol's datagram side,
# test/erlang/erx_gen_udp_core_tests.erl, and two seeded failures: a socket process that
# takes a datagram past the credit it granted, so a socket could push without bound into
# the owner's domain; and one that grants again only once all it granted is pushed.
class ErxGenUdpCoreTest < Minitest::Test
  include ErxNetEunit

  CREDIT_CHECK = 'held_bytes = Bytes} = C) when Cost =< Out ->'
  NO_CREDIT_CHECK = 'held_bytes = Bytes} = C) ->'
  HALF_TARGET = 'Short when Short >= ?TARGET div 2 ->'
  WHOLE_TARGET = 'Short when Short >= ?TARGET ->'

  def test_datagram_protocol_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_gen_udp_core_tests)
  end

  def test_a_datagram_past_the_credit_is_caught
    output = refute_erx_net_eunit(:erx_gen_udp_core_tests, fault: { 'erx_gen_udp_core' => [CREDIT_CHECK, NO_CREDIT_CHECK] })
    assert_match(/past_credit/, output)
  end

  def test_a_grant_only_at_the_whole_target_is_caught
    output = refute_erx_net_eunit(:erx_gen_udp_core_tests, fault: { 'erx_gen_udp_core' => [HALF_TARGET, WHOLE_TARGET] })
    assert_match(/credit_at_half_target/, output)
  end
end
