# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the DHCP client and the ephemeral port search,
# test/erlang/erx_dhcp4_tests.erl: erx_dhcp4_wire, erx_dhcp4_core through a lease's life,
# and erx_net_bind's port choice.
class ErxNetDhcp4Test < Minitest::Test
  include ErxNetEunit

  def test_dhcp_and_port_choice_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_dhcp4_tests)
  end
end
