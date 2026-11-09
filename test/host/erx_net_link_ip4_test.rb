# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the known-answer EUnit cases of the network stack's link and IPv4 codecs:
# test/erlang/erx_arp_wire_tests.erl (with erx_net_eth) and erx_ip4_wire_tests.erl.
class ErxNetLinkIp4Test < Minitest::Test
  include ErxNetEunit

  def test_link_and_ip4_codec_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_arp_wire_tests, :erx_ip4_wire_tests)
  end
end
