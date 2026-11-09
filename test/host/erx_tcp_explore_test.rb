# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the TCP core's exhaustive exploration over the base alphabet and its six extra
# dimensions (test/erlang/erx_tcp_explore.erl, docs/design-network-stack.md, "The TCP core:
# exhaustive exploration") at the landing gate's depths, or with ERX_TCP_EXPLORE=full at
# the milestone gate's, as tools/erx check-fuzz runs it. Each of the design's seeded
# failures must be caught by the property named for it; the exploration is breadth-first,
# so the trace it reports is a shortest one in the graph it explores.
class ErxTcpExploreTest < Minitest::Test
  include ErxNetEunit

  NEWER_WINDOW = 'Wl1 < Seq orelse (Wl1 =:= Seq andalso (Wl2 < Ack orelse (Wl2 =:= Ack andalso Win > SndWnd))).'
  ANY_WINDOW = 'Wl1 =/= Seq orelse Wl2 =/= Ack orelse Win =/= SndWnd.'
  WINDOW_TAKEN = 'true -> Tcb0#tcb{snd_wnd = Win, snd_wl1'
  WINDOW_NEVER_SHRUNK = 'true -> Tcb0#tcb{snd_wnd = max(Win, Tcb0#tcb.snd_wnd), snd_wl1'
  URGENT_KEPT_OUT = '-> {[Before, After], Tcb#tcb{rcv_oob = none}};'
  URGENT_DELIVERED = '-> {[Before, <<_Urgent>>, After], Tcb#tcb{rcv_oob = none}};'
  RST_EXACT = 'true when Seq =:= LastAck ->'
  RST_IN_WINDOW = 'true when Seq >= LastAck, Seq < LastAck + RcvWnd ->'
  RST_FROM_LAST_ACK = '#tcb{last_ack_sent = LastAck, rcv_wnd = RcvWnd, state = State} = Tcb,'
  RST_FROM_RCV_NXT = '#tcb{rcv_nxt = LastAck, rcv_wnd = RcvWnd, state = State} = Tcb,'
  ADVANCED = 'Tcb1#tcb{rcv_nxt = RcvNxt + Tlen}'
  ADVANCED_ON_THE_WIRE = 'Tcb1#tcb{rcv_nxt = erx_tcp_seq:wire(RcvNxt + Tlen)}'
  COUNTED = '{Tcb#tcb{challenge = {End, Sent + 1}, last_ack_sent = RcvNxt},'
  UNCOUNTED = '{Tcb#tcb{challenge = {End, Sent}, last_ack_sent = RcvNxt},'
  PAWS_CHECKED = 'andalso not_older(SegTs, Ts) andalso not Closed,'
  PAWS_SKIPPED = 'andalso (not_older(SegTs, Ts) orelse true) andalso not Closed,'
  SEQUENCE_CHECKED = 'case in_flight(Seq, Tcb) of'
  SEQUENCE_SKIPPED = 'case in_flight(Seq, Tcb) orelse true of'
  WINDOW_CHECKED = 'has(Flags, ?TH_ACK) andalso newer_window(Seg, Tcb0) of'
  SHRINK_AT_UNA_IGNORED = 'has(Flags, ?TH_ACK) andalso newer_window(Seg, Tcb0) andalso ' \
                          'not (element(1, Seg#seg.arrived) =:= element(2, Seg#seg.arrived) andalso ' \
                          'Ack =:= Tcb0#tcb.snd_una andalso Win < Tcb0#tcb.snd_wnd) of'
  DUPLICATE_WINDOW = 'pure = First =:= End andalso Win =:= SndWnd,'
  DUPLICATE_ANY_WINDOW = 'pure = First =:= End andalso (Win =:= SndWnd orelse true),'
  PAWS_OLDER = 'when Recent =/= 0, Val < Recent ->'
  PAWS_NEVER = 'when Recent =/= 0, Val < Recent, false ->'
  LOWER_BOUND = 'Lifted >= Una andalso Lifted < SndMax.'
  NO_LOWER_BOUND = 'Lifted >= min(Una, Lifted) andalso Lifted < SndMax.'

  def test_the_base_and_wrapped_runs_keep_every_property
    assert_erx_net_eunit(:erx_tcp_explore_tests, extra: [:erx_tcp_explore])
  end

  def test_a_window_update_without_the_wl1_wl2_rule_is_caught
    assert_caught(NEWER_WINDOW, ANY_WINDOW, /old_ack_keeps_send_window/)
  end

  # The peer model keeps the newest window by the WL1/WL2 rule, so a connection that keeps
  # a wider window over a zeroed one sends past the peer's edge.
  def test_a_window_update_that_never_shrinks_the_window_is_caught
    assert_caught(WINDOW_TAKEN, WINDOW_NEVER_SHRUNK, /sent_within_peer_window/)
  end

  # The urgent byte of a segment taken in order is delivered at once, so it must be kept out.
  def test_an_urgent_byte_delivered_in_band_is_caught
    output = assert_caught(URGENT_KEPT_OUT, URGENT_DELIVERED, /delivered_in_order/)
    assert_match(/held/, output)
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

  # A pure ACK at snd_una that shrinks the window is no duplicate the loss module may end,
  # since FreeBSD counts one only when it offers the same window.
  def test_a_window_shrink_ignored_on_a_pure_ack_at_snd_una_is_caught
    assert_caught(WINDOW_CHECKED, SHRINK_AT_UNA_IGNORED, /sent_within_peer_window/)
  end

  # FreeBSD counts a pure ACK as a duplicate only when it offers the window already held, so
  # a loss module that counts one that changes it drops a window update the peer model keeps.
  # The window it sends past lies 7 events after connect, past the landing depth.
  def test_a_duplicate_ack_counted_whatever_its_window_is_caught
    assert_caught(DUPLICATE_WINDOW, DUPLICATE_ANY_WINDOW, /sent_within_peer_window/, mode: 'base')
  end

  def test_a_segment_older_than_ts_recent_taken_is_caught
    assert_caught(PAWS_OLDER, PAWS_NEVER, /paws_drops_older/)
  end

  # A data segment at rcv_nxt with a TSval older than ts_recent, two events after connect,
  # is the shortest: the fast path takes what PAWS drops.
  def test_header_prediction_skipping_paws_is_caught
    output = assert_caught(PAWS_CHECKED, PAWS_SKIPPED, /header_prediction_agrees/)
    assert_match(/ts_older/, output)
  end

  # A report quoting the number below snd_una in SYN-SENT, the first event after connect,
  # is the shortest, for the whole check left out and for its lower bound alone.
  def test_an_icmp_report_without_its_sequence_check_is_caught
    output = assert_caught(SEQUENCE_CHECKED, SEQUENCE_SKIPPED, /icmp_outside_flight_changes_nothing/,
                           module_name: 'erx_tcp_icmp')
    assert_match(/\[connect,\s*\{icmp,needfrag,below\}\]/, output)
  end

  def test_an_icmp_report_checked_only_against_snd_max_is_caught
    output = assert_caught(LOWER_BOUND, NO_LOWER_BOUND, /icmp_outside_flight_changes_nothing/,
                           module_name: 'erx_tcp_icmp')
    assert_match(/\[connect,\s*\{icmp,needfrag,below\}\]/, output)
  end

  # The sixth challenge lies 7 events after connect, past the landing depth, so this seed
  # runs the base at the full depth.
  def test_challenge_acks_past_the_limit_are_caught
    assert_caught(COUNTED, UNCOUNTED, /challenge_acks_within_limit/, module_name: 'erx_tcp', mode: 'base')
  end

  private

  # Runs the explorer's cases on a copy of the module with the fault planted, at the
  # landing gate's depths unless `mode` names another (so a full run at the milestone gate
  # explores each seed only as deep as it needs), and expects the property to fail.
  def assert_caught(exact, faulty, property, module_name: 'erx_tcp_input', mode: nil)
    previous = ENV.fetch('ERX_TCP_EXPLORE', nil)
    ENV['ERX_TCP_EXPLORE'] = mode
    output = refute_erx_net_eunit(:erx_tcp_explore_tests, extra: [:erx_tcp_explore],
                                                          fault: { module_name => [exact, faulty] })
    assert_match(property, output)
    output
  ensure
    ENV['ERX_TCP_EXPLORE'] = previous
  end
end
