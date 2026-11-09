# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the IPv6 codecs, test/erlang/erx_ip6_wire_tests.erl
# and erx_icmp6_wire_tests.erl, over hand-built packets.
class ErxIp6CodecsTest < Minitest::Test
  include ErxNetEunit

  def test_ip6_wire_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_ip6_wire_tests)
  end

  def test_icmp6_wire_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_icmp6_wire_tests)
  end
end
