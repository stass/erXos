# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the TCP connection core: the step's dispatch and settling, user
# requests, timer expirations and the send buffer (test/erlang/erx_tcp_tests.erl), and the
# segment pipeline's stages (test/erlang/erx_tcp_input_tests.erl and, from the ACK on, with
# header prediction, test/erlang/erx_tcp_input_ack_tests.erl), with seeded faults in the checks
# that guard against blind injection, at the window's edges and in the fast path's preconditions.
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
  # RFC 9293 3.10.7.4: only a newer segment (SND.WL1, SND.WL2) updates the send window.
  NEWER_WINDOW = 'Wl1 < Seq orelse (Wl1 =:= Seq andalso (Wl2 < Ack orelse'
  ANY_WINDOW = 'true orelse (Wl1 =:= Seq andalso (Wl2 < Ack orelse'
  # Header prediction takes no segment older than ts_recent (PAWS).
  HP_PAWS = 'andalso not_older(SegTs, Ts) andalso not Closed'
  HP_NO_PAWS = 'andalso (not_older(SegTs, Ts) orelse true) andalso not Closed'
  # The finished pure ACK restarts the retransmission timer as process_ack does
  # (docs/design-network-fastpath.md, Verification, test 6).
  HP_REXMT = 'rexmt_after_ack(Ack, rtt(Seg, spurious_rto(Seg, Tcb1#tcb{sendlog'
  HP_NO_REXMT = '(fun(_, T, _) -> T end)(Ack, rtt(Seg, spurious_rto(Seg, Tcb1#tcb{sendlog'
  # Header prediction takes nothing once the owner has closed (TF_CLOSED), whose data the
  # general stages answer with a RST.
  HP_OPEN = 'andalso not Closed,'
  HP_CLOSED_TOO = 'andalso (not Closed orelse true),'
  # An acknowledgement of what was never sent is dropped before the loss module sees it.
  ACK_TOO_MUCH = 'case Ack > erx_tcp_sendlog:snd_max(Log) of'
  ACK_ANY = 'case Ack > erx_tcp_sendlog:snd_max(Log) + (1 bsl 32) of'
  # tcp_dropwithreset answers no segment whose frame was link broadcast or multicast.
  NO_RST_FOR_LINK_CAST = 'Flags band ?TH_RST =/= 0; LinkCast =/= unicast ->'
  RST_FOR_ANY_LINK_CAST = 'Flags band ?TH_RST =/= 0; LinkCast =:= none ->'

  def test_core_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_tests, :erx_tcp_input_tests, :erx_tcp_input_ack_tests)
  end

  def test_an_in_window_rst_that_resets_is_caught
    output = refute_erx_net_eunit(:erx_tcp_input_tests,
                                  fault: { 'erx_tcp_input' => [EXACT_RST, ANY_RST_IN_WINDOW] })
    assert_match(/rst_in_window_draws_a_challenge_ack/, output)
  end

  def test_a_reset_for_a_link_broadcast_is_caught
    output = refute_erx_net_eunit(:erx_tcp_input_tests,
                                  fault: { 'erx_tcp_input' => [NO_RST_FOR_LINK_CAST, RST_FOR_ANY_LINK_CAST] })
    assert_match(/no_reset_for_link_broadcast/, output)
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

  def test_a_window_update_from_an_old_ack_is_caught
    output = refute_erx_net_eunit(:erx_tcp_input_ack_tests,
                                  fault: { 'erx_tcp_input' => [NEWER_WINDOW, ANY_WINDOW] })
    assert_match(/window_update/, output)
  end

  def test_header_prediction_without_paws_is_caught
    output = refute_erx_net_eunit(:erx_tcp_input_ack_tests,
                                  fault: { 'erx_tcp_input' => [HP_PAWS, HP_NO_PAWS] })
    assert_match(/agrees_with_the_general_stages/, output)
  end

  def test_a_fast_pure_ack_without_the_retransmission_timer_is_caught
    output = refute_erx_net_eunit(:erx_tcp_input_ack_tests,
                                  fault: { 'erx_tcp_input' => [HP_REXMT, HP_NO_REXMT] })
    assert_match(/agrees_with_the_general_stages/, output)
  end

  def test_header_prediction_after_the_owner_closed_is_caught
    output = refute_erx_net_eunit(:erx_tcp_input_ack_tests,
                                  fault: { 'erx_tcp_input' => [HP_OPEN, HP_CLOSED_TOO] })
    assert_match(/agrees_with_the_general_stages/, output)
  end

  def test_an_ack_of_unsent_data_reaching_the_loss_module_is_caught
    output = refute_erx_net_eunit(:erx_tcp_input_ack_tests,
                                  fault: { 'erx_tcp_input' => [ACK_TOO_MUCH, ACK_ANY] })
    assert_match(/ack_of_unsent_data/, output)
  end
end
