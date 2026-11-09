# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the receiver SACK blocks' EUnit property,
# test/erlang/erx_tcp_sack_tests.erl. Then runs it again over a copy of
# erx_tcp_sack seeded with a fault, a D-SACK block that runs on to the end of
# the held range instead of stopping at the segment's end, which the property
# must catch.
class ErxTcpSackTest < Minitest::Test
  include ErxNetEunit

  DUPLICATE_PART = '{max(First, OldFirst), min(End, OldEnd)}'
  PAST_SEGMENT = '{max(First, OldFirst), max(End, OldEnd)}'

  def test_sack_property_passes_under_eunit
    assert_erx_net_eunit(:erx_tcp_sack_tests)
  end

  def test_property_catches_a_wrong_dsack_block
    fault = { 'erx_tcp_sack' => [DUPLICATE_PART, PAST_SEGMENT] }
    output = refute_erx_net_eunit(:erx_tcp_sack_tests, fault: fault)
    assert_match(/matches_model_test/, output)
  end
end
