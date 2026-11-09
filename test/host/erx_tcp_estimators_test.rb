# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of TCP's RTT estimator, MSS and initial window, initial sequence
# numbers and ECN: test/erlang/erx_tcp_rtt_tests.erl, erx_tcp_mss_tests.erl,
# erx_tcp_isn_tests.erl and erx_tcp_ecn_tests.erl; and the RTT cases again over a copy of
# erx_tcp_rtt seeded with a clamp that applies its floor last.
class ErxTcpEstimatorsTest < Minitest::Test
  include ErxNetEunit

  # TCPT_RANGESET raises to the floor and then lowers to the ceiling. Applying the floor
  # last lets a sample above 64 s, which a peer echoing an old timestamp can cause, push the
  # RTO past 64 s; cap_test must catch it.
  CLAMP = 'min(max(Value + ?TCPTV_CPU_VAR, Min), Max)'
  FLOOR_LAST = 'max(min(Value + ?TCPTV_CPU_VAR, Max), Min)'

  def test_rtt_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_rtt_tests)
  end

  def test_rtt_cap_catches_a_floor_applied_last
    output = refute_erx_net_eunit(:erx_tcp_rtt_tests, fault: { 'erx_tcp_rtt' => [CLAMP, FLOOR_LAST] })
    assert_match(/cap_test/, output)
  end

  def test_mss_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_mss_tests)
  end

  def test_isn_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_isn_tests)
  end

  def test_ecn_cases_pass_under_eunit
    assert_erx_net_eunit(:erx_tcp_ecn_tests)
  end
end
