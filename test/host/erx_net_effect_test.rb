# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the network stack's effect layer: the interface core against
# canned frames (test/erlang/erx_net_if_core_tests.erl), the driver and pipe with a
# stand-in interface (erx_net_driver_tests.erl) and a TCP connection's loop with a
# stand-in interface, driver and peer (erx_tcp_conn_tests.erl), and seeds the faults the design names for
# them ("The stack on a development host", "The driver and the clock"; "Receiving").
class ErxNetEffectTest < Minitest::Test
  include ErxNetEunit

  def test_interface_core_passes_under_eunit
    assert_erx_net_eunit(:erx_net_if_core_tests)
  end

  def test_driver_and_pipe_pass_under_eunit
    assert_erx_net_eunit(:erx_net_driver_tests)
  end

  def test_tcp_connection_passes_under_eunit
    assert_erx_net_eunit(:erx_tcp_conn_tests)
  end

  # The connection loop's seeded failures, each failing its own case.
  CONN_FAULTS = {
    # The clock left unarmed after a step: no deadline of the step ever runs.
    syn_is_retransmitted_on_its_timer: [
      'S#state{armed = erx_net_clock:arm_by(lists:min(Deadlines), Armed)}.', '_ = {Deadlines, Armed}, S.'
    ],
    # Bytes handed to the owner never stepped as read: the window stays shut.
    reading_opens_the_window: [
      'settle(step({user, {rcvd, Released}}, S1))', '_ = Released, settle(S1)'
    ],
    # A recv short of its length holds nothing: its bytes keep the window shut, and a
    # sender's silly window avoidance never sends the last part of a segment it waits for.
    recv_of_the_whole_buffer_completes: [
      'S#state{rcv_held = N};', '_ = N, S;'
    ],
    # Held bytes still marked held once taken: they are stepped as read a second time,
    # and the window overstates the room.
    recv_that_times_out_keeps_what_it_held: [
      'rcv_held = max(Held - Bytes, 0)}}.', 'rcv_held = Held + 0 * Bytes}}.'
    ],
    # A batch's units never taken: the peer's segments hold the credit for good.
    credit_is_taken_as_items_arrive: [
      'ok = erx_net_credit:take(Credit, length(Batch)),', '_ = Credit,'
    ],
    # The drain stopped after the first message: each queued message is stepped on its own,
    # and five queued segments are acknowledged in more than one ACK.
    queued_items_are_stepped_once: [
      'Batch = queued_items([Items]),', '_ = fun queued_items/1, Batch = Items,'
    ]
  }.freeze

  CONN_FAULTS.each do |name, fault|
    define_method("test_seeded_fault_fails_#{name}") do
      output = refute_erx_net_eunit(:erx_tcp_conn_tests, fault: { 'erx_tcp_conn' => fault })
      assert_match(/#{name}/, output)
    end
  end

  # A failed check that keeps the token it spent starves the interface of its bucket.
  def test_core_that_keeps_a_failed_frames_token_fails
    output = refute_erx_net_eunit(:erx_net_if_core_tests, fault: {
      'erx_net_if_core' => ['Core#core{bucket = B#bucket{tokens = min(Burst * ?TOKEN, T + ?TOKEN)}}.',
                            '_ = {T, Burst, B}, Core.']
    })
    assert_match(/failed_check_gives_its_token_back/, output)
  end

  # The design's seeded failures of the driver and the pipe, each failing its own case.
  DRIVER_FAULTS = {
    # A unit taken when the message arrives, not when the frame leaves.
    backlog_never_exceeds_the_transmit_credit: [
      'erx_net_driver',
      ["when is_list(Frames) ->\n    drain(",
       "when is_list(Frames) ->\n    ok = erx_net_credit:take(S#state.tx, length(Frames)),\n    drain("]
    ],
    # A refused link notice retried only at later messages.
    silent_link_is_told_once_room_returns: [
      'erx_net_driver',
      ["Retry = erx_net_clock:now() + ?RETRY_US,\n            S#state{armed = erx_net_clock:arm_by(Retry, S#state.armed)}", 'S']
    ],
    # Every link change queued instead of only the latest told.
    flap_while_full_is_not_told: [
      'erx_net_driver',
      ['event({link, State}, S) when State =:= up; State =:= down ->',
       "event({link, State}, #state{iface = {Pid, _, _}} = S) ->\n    Pid ! {link, self(), State}, S;\n" \
       'event({link, State}, S) when State =:= up; State =:= down ->']
    ],
    # A process end without its type check.
    process_end_counts_a_frame_that_is_not_a_binary: [
      'erx_net_pipe',
      ['#process{pid = Pid, mtu = Mtu} = T) when is_binary(Frame) ->', '#process{pid = Pid, mtu = Mtu} = T) ->']
    ],
    # A socket opened {active, true}.
    udp_end_bounds_the_driver_queue_against_a_stranger: [
      'erx_net_pipe', ['{ip, LocalIp}, {active, ?ACTIVE}]', '{ip, LocalIp}, {active, true}]']
    ],
    # A driver that stays alive on its far end's end, the link down for good.
    far_end_end_restarts_the_link: [
      'erx_net_pipe',
      ["event({'DOWN', Ref, process, _, Reason}, #process{ref = Ref}) ->\n    {stop, {far_end, Reason}};",
       "event({'DOWN', Ref, process, _, _Reason}, #process{ref = Ref} = T) ->\n    {[{link, down}], T};"]
    ],
    # A driver with no hold to speak of: a far end that is never there restarts its link at once.
    far_end_never_there_spins_no_supervisor: [
      'erx_net_driver', ['-define(HOLD_MS, 1000).', '-define(HOLD_MS, 1).']
    ],
    # The driver's drain stopped after the first transmit: a transmit queued behind a
    # message that fills the transport waits for room.
    queued_transmits_leave_together: [
      'erx_net_driver',
      ['drain(S#state{backlog = queued_transmits(queue:join(Backlog, queue:from_list(Frames)))});',
       '_ = fun queued_transmits/1, drain(S#state{backlog = queue:join(Backlog, queue:from_list(Frames))});']
    ],
    # The interface's drain stopped after the first batch: each batch reaches the holder in
    # a message of its own.
    queued_batches_reach_a_holder_as_one_message: [
      'erx_net_if', ['queued_frames([Frames], S);', '_ = fun queued_frames/2, frames([Frames], S);']
    ],
    # The driver's cut removed: an event reaches the interface whole, past the merge's limit.
    batches_are_cut_to_the_merge_limit: [
      'erx_net_driver', ['    cut(Frames, Limit, [], 0, 0, [], 0).', '    _ = fun cut/7, _ = Limit, {[Frames], 0}.']
    ],
    # A link start that fails when its driver ends under it: the stack's own start fails.
    crash_at_start_spins_no_supervisor: [
      'erx_net_sup', ['false -> {ok, Sup}', 'false -> stop_link(Sup, Error)']
    ]
  }.freeze

  DRIVER_FAULTS.each do |name, (mod, fault)|
    define_method("test_seeded_fault_fails_#{name}") do
      output = refute_erx_net_eunit(:erx_net_driver_tests, fault: { mod => fault })
      assert_match(/#{name}/, output)
    end
  end

  # The interfaces supervisor at OTP's default intensity, below what a held link reaches.
  def test_seeded_fault_fails_far_end_never_there_at_the_default_intensity
    output = refute_erx_net_eunit(:erx_net_driver_tests, fault: {
      'erx_net_sup' => ['Intensity = length(Interfaces)', 'Intensity = 1 + 0 * length(Interfaces)']
    })
    assert_match(/far_end_never_there_spins_no_supervisor/, output)
  end
end
