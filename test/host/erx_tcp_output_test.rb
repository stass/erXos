# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of TCP output (test/erlang/erx_tcp_output_tests.erl): windows, Nagle,
# silly-window avoidance, persist, FIN and RST, SACK retransmission, options, credit and a
# missing route, with a seeded fault that settles a lost segment's ACK as if it had left.
class ErxTcpOutputTest < Minitest::Test
  include ErxNetEunit

  # tcp_output.c:1722-1735: only a segment that left settles the pending ACK.
  SETTLED_ON_SUCCESS = '{sent(Route, RecWin, Tcb),'
  SETTLED_ALWAYS = '{sent(ok, RecWin, Tcb),'

  def test_output_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_output_tests)
  end

  def test_an_ack_settled_without_a_route_is_caught
    output = refute_erx_net_eunit(:erx_tcp_output_tests,
                                  fault: { 'erx_tcp_output' => [SETTLED_ON_SUCCESS, SETTLED_ALWAYS] })
    assert_match(/no_route_keeps_the_ack_owed/, output)
  end
end
