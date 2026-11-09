# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the TCP core's exhaustive exploration over the base alphabet
# (test/erlang/erx_tcp_explore.erl, docs/design-network-stack.md, "The TCP core: exhaustive
# exploration") at the landing gate's depth, or with ERX_TCP_EXPLORE=full at the design's
# depth of 8, as tools/erx check-fuzz runs it at the milestone gate. Each of the design's
# seeded failures of the base alphabet must be caught by the property named for it; the
# exploration is breadth-first, so the trace it reports is a shortest one in the graph
# it explores.
class ErxTcpExploreTest < Minitest::Test
  include ErxNetEunit

  NEWER_WINDOW = 'Wl1 < Seq orelse (Wl1 =:= Seq andalso (Wl2 < Ack orelse (Wl2 =:= Ack andalso Win > SndWnd))).'
  ANY_WINDOW = 'Wl1 =/= Seq orelse Wl2 =/= Ack orelse Win =/= SndWnd.'
  RST_EXACT = 'true when Seq =:= LastAck ->'
  RST_IN_WINDOW = 'true when Seq >= LastAck, Seq < LastAck + RcvWnd ->'
  RST_FROM_LAST_ACK = '#tcb{last_ack_sent = LastAck, rcv_wnd = RcvWnd, state = State} = Tcb,'
  RST_FROM_RCV_NXT = '#tcb{rcv_nxt = LastAck, rcv_wnd = RcvWnd, state = State} = Tcb,'
  ADVANCED = 'Tcb1#tcb{rcv_nxt = RcvNxt + Tlen}'
  ADVANCED_ON_THE_WIRE = 'Tcb1#tcb{rcv_nxt = erx_tcp_seq:wire(RcvNxt + Tlen)}'
  COUNTED = '{Tcb#tcb{challenge = {End, Sent + 1}, last_ack_sent = RcvNxt},'
  UNCOUNTED = '{Tcb#tcb{challenge = {End, Sent}, last_ack_sent = RcvNxt},'

  def test_the_base_and_wrapped_runs_keep_every_property
    assert_erx_net_eunit(:erx_tcp_explore_tests, extra: [:erx_tcp_explore])
  end

  def test_a_window_update_without_the_wl1_wl2_rule_is_caught
    assert_caught(NEWER_WINDOW, ANY_WINDOW, /old_ack_keeps_send_window/)
  end

  def test_a_rst_accepted_anywhere_in_the_window_is_caught
    assert_caught(RST_EXACT, RST_IN_WINDOW, /rst_only_at_last_ack_sent/)
  end

  def test_a_rst_judged_against_rcv_nxt_with_an_ack_delayed_is_caught
    assert_caught(RST_FROM_LAST_ACK, RST_FROM_RCV_NXT, /rst_only_at_last_ack_sent/)
  end

  # Below 2^32 the wire value and the unwrapped one agree, so only the second run sees it.
  def test_rcv_nxt_advanced_without_lifting_is_caught_across_the_wrap
    output = assert_caught(ADVANCED, ADVANCED_ON_THE_WIRE, /rcv_nxt_never_decreases/)
    assert_match(/wrap_run_test.*\*failed\*/, output)
    refute_match(/base_run_test.*\*failed\*/, output)
  end

  # The sixth challenge lies 7 events after connect, past the landing depth, so this seed
  # runs at the full depth.
  def test_challenge_acks_past_the_limit_are_caught
    previous = ENV.fetch('ERX_TCP_EXPLORE', nil)
    ENV['ERX_TCP_EXPLORE'] = 'full'
    output = refute_erx_net_eunit(:erx_tcp_explore_tests, extra: [:erx_tcp_explore],
                                                          fault: { 'erx_tcp' => [COUNTED, UNCOUNTED] })
    assert_match(/challenge_acks_within_limit/, output)
  ensure
    ENV['ERX_TCP_EXPLORE'] = previous
  end

  private

  def assert_caught(exact, faulty, property)
    output = refute_erx_net_eunit(:erx_tcp_explore_tests, extra: [:erx_tcp_explore],
                                                          fault: { 'erx_tcp_input' => [exact, faulty] })
    assert_match(property, output)
    output
  end
end
