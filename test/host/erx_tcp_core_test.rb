# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the TCP connection core: the step's dispatch and settling, user
# requests, timer expirations and the send buffer (test/erlang/erx_tcp_tests.erl), and the
# segment pipeline's stages (test/erlang/erx_tcp_input_tests.erl), with seeded faults in
# the checks that guard against blind injection and at the window's edges.
class ErxTcpCoreTest < Minitest::Test
  include ErxNetEunit

  # RFC 5961 section 3: only the exact RST resets; an in-window one is challenged.
  EXACT_RST = 'true when Seq =:= LastAck ->'
  ANY_RST_IN_WINDOW = 'true when Seq >= LastAck, Seq < LastAck + max(RcvWnd, 1) ->'
  # The ghost-ACK floor at the ISS.
  GHOST_FLOOR = 'false -> max(Iss + 1, Una - MaxSndWnd)'
  NO_GHOST_FLOOR = 'false -> Una - MaxSndWnd'
  # A segment starting at the window's right edge is past it.
  INSIDE = 'Todrop < Tlen ->'
  INSIDE_AT_EDGE = 'Todrop =< Tlen ->'

  def test_core_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_tests, :erx_tcp_input_tests)
  end

  def test_an_in_window_rst_that_resets_is_caught
    output = refute_erx_net_eunit(:erx_tcp_input_tests,
                                  fault: { 'erx_tcp_input' => [EXACT_RST, ANY_RST_IN_WINDOW] })
    assert_match(/rst_in_window_draws_a_challenge_ack/, output)
  end

  def test_a_missing_ghost_ack_floor_is_caught
    output = refute_erx_net_eunit(:erx_tcp_input_tests,
                                  fault: { 'erx_tcp_input' => [GHOST_FLOOR, NO_GHOST_FLOOR] })
    assert_match(/ack_floor/, output)
  end

  def test_a_segment_at_the_right_edge_kept_is_caught
    output = refute_erx_net_eunit(:erx_tcp_input_tests,
                                  fault: { 'erx_tcp_input' => [INSIDE, INSIDE_AT_EDGE] })
    assert_match(/trim_back/, output)
  end
end
