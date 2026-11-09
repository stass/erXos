# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of a connection's ICMP reports (test/erlang/erx_tcp_icmp_tests.erl)
# and TIME-WAIT (test/erlang/erx_tcp_timewait_tests.erl), with seeded faults in the checks
# that keep blind senders out: the quoted sequence number in flight (RFC 5927), the MSS that
# only goes down, the RST TIME-WAIT ignores (RFC 1337) and the newer timestamp a reused
# four-tuple needs (RFC 6191).
class ErxTcpTeardownTest < Minitest::Test
  include ErxNetEunit

  IN_FLIGHT = 'Lifted >= Una andalso Lifted < SndMax.'
  UP_TO_SND_MAX = 'Lifted >= Una andalso Lifted =< SndMax.'
  DECREASE_ONLY = 'case Mtu < Old + ProtoH of'
  ANY_MTU = 'case Mtu < Old + ProtoH + 1 of'
  RST_DROPPED = "Flags band ?TH_RST =/= 0 ->\n            {Tcb, []};"
  RST_OBEYED = "Flags band ?TH_RST =/= 0 ->\n            {erx_tcp_user:close(Tcb), []};"
  NEVER_ABOVE_OLD = 'Maxseg = min(update(Family, {mtu, Mtu}, PathMtu, 0), Old),'
  ANY_UPDATE = 'Maxseg = update(Family, {mtu, Mtu}, PathMtu, 0),'
  NEWER_TS = 'erx_tcp_seq:lift(Val, Recent) > Recent;'
  SAME_TS = 'erx_tcp_seq:lift(Val, Recent) >= Recent;'

  def test_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_icmp_tests, :erx_tcp_timewait_tests)
  end

  def test_a_report_quoting_snd_max_that_acts_is_caught
    output = refute_erx_net_eunit(:erx_tcp_icmp_tests, fault: { 'erx_tcp_icmp' => [IN_FLIGHT, UP_TO_SND_MAX] })
    assert_match(/sequence_in_flight/, output)
  end

  def test_a_report_at_the_current_mtu_that_acts_is_caught
    output = refute_erx_net_eunit(:erx_tcp_icmp_tests, fault: { 'erx_tcp_mss' => [DECREASE_ONLY, ANY_MTU] })
    assert_match(/mtu_decreases_only/, output)
  end

  def test_an_mss_raised_with_no_route_is_caught
    output = refute_erx_net_eunit(:erx_tcp_icmp_tests, fault: { 'erx_tcp_mss' => [NEVER_ABOVE_OLD, ANY_UPDATE] })
    assert_match(/mss_never_grows/, output)
  end

  def test_a_rst_ending_time_wait_is_caught
    output = refute_erx_net_eunit(:erx_tcp_timewait_tests,
                                  fault: { 'erx_tcp_timewait' => [RST_DROPPED, RST_OBEYED] })
    assert_match(/rst_is_dropped/, output)
  end

  def test_a_syn_reusing_with_an_equal_timestamp_is_caught
    output = refute_erx_net_eunit(:erx_tcp_timewait_tests, fault: { 'erx_tcp_timewait' => [NEWER_TS, SAME_TS] })
    assert_match(/syn_with_newer_timestamp/, output)
  end
end
