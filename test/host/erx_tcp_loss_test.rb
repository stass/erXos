# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the send log's and the default loss module's EUnit cases,
# test/erlang/erx_tcp_sendlog_tests.erl and erx_tcp_loss_dupack_tests.erl. Then
# runs the send log's again over a copy of erx_tcp_sendlog seeded with a fault,
# IsLost's byte threshold taken as "at least" instead of "more than", which the
# byte-map property must catch (docs/design-network-stack.md, "The send log,
# loss and congestion: properties and a FreeBSD oracle").
class ErxTcpLossTest < Minitest::Test
  include ErxNetEunit

  MORE_THAN = 'Runs >= DupThresh orelse Above > Limit'
  AT_LEAST = 'Runs >= DupThresh orelse Above >= Limit'

  def test_send_log_and_loss_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_sendlog_tests, :erx_tcp_loss_dupack_tests)
  end

  def test_property_catches_a_wrong_is_lost
    output = refute_erx_net_eunit(:erx_tcp_sendlog_tests, fault: { 'erx_tcp_sendlog' => [MORE_THAN, AT_LEAST] })
    assert_match(/matches_byte_map_test/, output)
  end
end
