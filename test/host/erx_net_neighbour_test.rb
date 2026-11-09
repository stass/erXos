# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the network stack's neighbour tables and duplicate address
# detection: test/erlang/erx_arp_tests.erl, erx_nd6_tests.erl and erx_nd6_dad_tests.erl.
class ErxNetNeighbourTest < Minitest::Test
  include ErxNetEunit

  def test_neighbour_table_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_arp_tests, :erx_nd6_tests, :erx_nd6_dad_tests)
  end
end
