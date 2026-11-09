# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the TCP reassembly queue's EUnit cases, test/erlang/erx_tcp_reass_tests.erl:
# the byte-map property, the overlap rule, the caps and the FIN rules. Then
# runs them again over a copy of erx_tcp_reass seeded with a fault, a
# segment starting at a range's end taken as a duplicate, which the property
# must catch (docs/design-network-stack.md, "Reassembly and buffers:
# properties against a byte map").
class ErxTcpReassTest < Minitest::Test
  include ErxNetEunit

  DUPLICATE = 'case RangeEnd > Seq andalso End =< RangeEnd of'
  TOUCHING_IS_DUPLICATE = 'case RangeEnd >= Seq andalso End =< RangeEnd + 1 of'

  def test_reassembly_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_reass_tests)
  end

  def test_property_catches_a_lost_segment
    output = refute_erx_net_eunit(:erx_tcp_reass_tests, fault: { 'erx_tcp_reass' => [DUPLICATE, TOUCHING_IS_DUPLICATE] })
    assert_match(/matches_byte_map_test/, output)
  end
end
