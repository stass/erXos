# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of name resolution, test/erlang/erx_net_dns_tests.erl: the
# grant's resolver operation, erx_gen_udp over erx_udp_sock, and erx_inet's check and
# load of the grant's answer into inet_db.
class ErxNetDnsTest < Minitest::Test
  include ErxNetEunit

  def test_resolver_and_udp_backend_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_net_dns_tests)
  end
end
