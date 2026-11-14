# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the listener's exhaustive exploration (test/erlang/erx_tcp_listen_core_tests.erl,
# docs/design-network-stack.md, "The listener: exploration, the backlog and binds") and
# seeds the design's faults of erx_tcp_listen_core, each of which the exploration must
# find. The model's own two faults are options of the exploration, checked by its cases.
class ErxTcpListenTest < Minitest::Test
  include ErxNetEunit

  def test_passive_open_exploration_passes_under_eunit
    assert_erx_net_eunit(:erx_tcp_listen_core_tests)
  end

  CORE_FAULTS = {
    # A unit also taken back at {bound, C}: the counter falls below its holders (p2).
    unit_taken_back_at_bound: [
      '[{reply, N, {ok, Conn}}, {unlink, Conn}, {unlink, SockProc}]',
      '[take_unit, {reply, N, {ok, Conn}}, {unlink, Conn}, {unlink, SockProc}]'
    ],
    # The call of an ended acceptor dropped without a reply: left in flight (p3).
    ended_acceptor_call_dropped: [
      '{Core#core{waiting = Left}, [{reply, N, {error, econnaborted}}]};',
      '_ = N, {Core#core{waiting = Left}, []};'
    ],
    # A call paired again after its connection's end: a call whose acceptor ended while it
    # was handing waits for ever (p3).
    call_paired_again_after_its_connection_ends: [
      '{Core#core{handing = Rest}, [{reply, N, {error, econnaborted}}, {unlink, SockProc}]};',
      'pair(Core#core{handing = Rest, waiting = [{N, SockProc, infinity} | Core#core.waiting]}, []);'
    ],
    # A deadline that fires only after its turn: the call is still waiting at it (p6).
    timeout_after_the_deadline: [
      'Deadline =< Now end, Waiting)', 'Deadline < Now end, Waiting)'
    ]
  }.freeze

  CORE_FAULTS.each do |name, fault|
    define_method("test_seeded_fault_fails_#{name}") do
      output = refute_erx_net_eunit(:erx_tcp_listen_core_tests, fault: { 'erx_tcp_listen_core' => fault })
      assert_match(/passive_open_is_explored_exhaustively/, output)
    end
  end

  # The effect process, erx_tcp_listen, with stand-ins for its grant, its socket process,
  # the acceptors and the connections (test/erlang/erx_tcp_listen_tests.erl).
  def test_listener_effect_process_passes_under_eunit
    assert_erx_net_eunit(:erx_tcp_listen_tests)
  end

  # The effect process's seeded failures, each failing the case named.
  EFFECT_FAULTS = {
    # No clock armed for the core's deadlines: an accept with a timeout waits on.
    accept_times_out: [
      '{noreply, S#state{armed = erx_net_clock:arm_by(to_us(erx_tcp_listen_core:next_deadline(Core)), Armed)}};',
      '_ = {Core, Armed}, _ = fun to_us/1, {noreply, S};'
    ],
    # take_unit not performed: a connection that leaves the queue keeps its place in the backlog.
    queued_exit_gives_the_unit_back: [
      'erx_net_credit:take(Credit, 1).', '_ = Credit, ok.'
    ]
  }.freeze

  EFFECT_FAULTS.each do |name, fault|
    define_method("test_seeded_fault_fails_#{name}") do
      output = refute_erx_net_eunit(:erx_tcp_listen_tests, fault: { 'erx_tcp_listen' => fault })
      assert_match(/#{name}/, output)
    end
  end
end
