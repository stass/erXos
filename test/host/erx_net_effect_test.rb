# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'erx_net_eunit'

# Runs the EUnit cases of the network stack's effect layer: the interface core against
# canned frames (test/erlang/erx_net_if_core_tests.erl), the driver and pipe with a
# stand-in interface (erx_net_driver_tests.erl) and a TCP connection's loop with a
# stand-in interface, driver and peer (erx_tcp_conn_tests.erl), the grant's buffer
# reservations (erx_net_grant_core_tests.erl), and seeds the faults the design names for
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

  def test_grant_buffer_reservations_pass_under_eunit
    assert_erx_net_eunit(:erx_net_grant_core_tests)
  end

  # The connection loop's seeded failures, each failing its own case.
  CONN_FAULTS = {
    # The clock left unarmed after a step: no deadline of the step ever runs.
    syn_is_retransmitted_on_its_timer: [
      'S#state{armed = erx_net_clock:arm_by(lists:min(Deadlines), Armed)}.', '_ = {Deadlines, Armed}, S.'
    ],
    # Bytes handed to the owner never stepped as read: the window stays shut.
    reading_opens_the_window: [
      'settle(rcvd(Released, S1))', '_ = Released, settle(rcvd(0, S1))'
    ],
    # The step erx_tcp:rcvd/2 asks for ignored: the bytes come off, but no update is sent.
    a_read_sends_its_window_update: [
      'step -> step({user, {rcvd, Released}}, S)', 'step -> S#state{tcb = erx_tcp_user:rcvd(Released, Tcb0)}'
    ],
    # A batch's units never taken: the peer's segments hold the credit for good.
    credit_is_taken_as_items_arrive: [
      'ok = erx_net_credit:take(Credit, lists:sum([units(Item) || Item <- Batch])),', '_ = Credit, _ = fun units/1,'
    ],
    # The drain stopped after the first message: each queued message is stepped on its own,
    # and five queued segments are acknowledged in more than one ACK.
    queued_items_are_stepped_once: [
      'Batch = queued_items([Items]),', '_ = fun queued_items/1, Batch = Items,'
    ]
  }.freeze

  # The socket protocol's seeded failures in other modules than the connection, each
  # failing its own case: a connection that takes and answers a request in the envelope
  # of a domain that is not its grantee's, and a socket process that grants no credit,
  # whose owner stalls with the bytes in the connection.
  PROTOCOL_FAULTS = {
    a_non_grantee_envelope_is_dropped_and_counted: [
      'erx_net_admit', ['when Origin =/= local, D =:= Origin, is_pid(SockProc) ->', 'when Origin =:= Origin, D =:= D, is_pid(SockProc) ->']
    ],
    active_mode_delivers_to_the_owner: [
      'erx_gen_tcp', ['Conn ! {erx_net, self(), {credit, Bytes}},', '_ = {Conn, Bytes},']
    ]
  }.freeze

  PROTOCOL_FAULTS.each do |name, (mod, fault)|
    define_method("test_seeded_fault_fails_#{name}") do
      output = refute_erx_net_eunit(:erx_tcp_conn_tests, fault: { mod => fault })
      assert_match(/#{name}/, output)
    end
  end

  CONN_FAULTS.each do |name, fault|
    define_method("test_seeded_fault_fails_#{name}") do
      output = refute_erx_net_eunit(:erx_tcp_conn_tests, fault: { 'erx_tcp_conn' => fault })
      assert_match(/#{name}/, output)
    end
  end

  def test_accepted_connection_passes_under_eunit
    assert_erx_net_eunit(:erx_tcp_accept_tests)
  end

  # The accepted connection's seeded failures (docs/design-network-stack.md, "The backlog
  # and the hand-over, on a development host"), each failing its own case.
  ACCEPT_FAULTS = {
    # No release at `abandon`: the place in the backlog never comes back.
    abandon_releases_the_unit: [
      "        abandon ->\n            ok = erx_net_credit:release(Unit, 1);",
      "        abandon ->\n            _ = Unit;"
    ],
    # A connection that carries on after a refused adoption: no RST, and it is queued.
    refused_adoption_resets: [
      '{{error, _}, _} ->', '{{error, _}, Path1} when Path1 =:= x ->'
    ],
    # A queued connection that ignores its listener's exit: no RST to the peer.
    listener_exit_aborts_a_queued_connection: [
      'settle(step({user, abort}, S));', '{noreply, S};'
    ],
    # A bound connection that pushes before its socket process's first message.
    queued_connection_waits_for_the_first_contact: [
      "hand_over(#state{owner = {_Phase, _}} = S) ->\n    %% Queued or bound before the first contact: the bytes wait for the socket process.\n    S;\n",
      "hand_over(#state{owner = {bound, P}} = S) ->\n    hand_over(S#state{owner = P, push_credit = 65536});\n"
    ],
    # A bind that never looks for its socket process's noproc: the listener is told bound
    # for a socket process already gone, and would answer the accept {ok, Conn}.
    bind_to_a_gone_socket_process_closes: [
      "{'EXIT', SockProc, noproc} ->", "{'EXIT', SockProc, noproc_seeded} ->"
    ]
  }.freeze

  ACCEPT_FAULTS.each do |name, fault|
    define_method("test_seeded_fault_fails_#{name}") do
      output = refute_erx_net_eunit(:erx_tcp_accept_tests, fault: { 'erx_tcp_conn' => fault })
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

  # A view that holds only the interface's own addresses: the loopback interface drops a
  # packet to another interface's address as not the stack's.
  def test_core_whose_view_drops_the_stacks_other_addresses_fails
    output = refute_erx_net_eunit(:erx_net_if_core_tests, fault: {
      'erx_net_if_core' => ['stack4([A || {_, #{addr := A}} <- Addrs], Snapshot)',
                            'stack4([A || {_, #{addr := A}} <- Addrs], element(1, {none, Snapshot}))']
    })
    assert_match(/loopback_takes_a_packet_to_another_interfaces_address/, output)
  end

  # The loop that hands a frame up whatever reference its message carries.
  def test_loop_that_takes_a_message_it_did_not_make_fails
    output = refute_erx_net_eunit(:erx_net_driver_tests, fault: {
      'erx_net_loop' => ['event({erx_net_loop, Ref, Zone, Packet}, Ref) ->',
                         'event({erx_net_loop, _, Zone, Packet}, Ref) ->']
    })
    assert_match(/loop_ignores_a_message_it_did_not_make/, output)
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
      ["event({erx_net_pipe, Pid, Frame}, #process{pid = Pid} = T) when is_binary(Frame) ->\n    {burst([Frame], T), T};",
       "event({erx_net_pipe, Pid, Frame}, #process{pid = Pid} = T) ->\n    {[{frames, [received(Frame, T)]}], T};"]
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
    # Credit by units: a merged segment takes one unit of its connection's credit, so the
    # interface hands a slow connection more than its limit of frames.
    credit_counts_segments: [
      'erx_net_input', ['units({merged, N, _, _, _}) -> N;', 'units({merged, _N, _, _, _}) -> 1;']
    ],
    # A unit classified by its last frame: its segment starts at the last frame's sequence
    # number, which the unit's own claims refuse, so nothing reaches the connection.
    a_burst_reaches_its_connection_as_one_segment: [
      'erx_net_input', ['unit(N, ether(First, FirstSum, View), fun() -> ether(Last, LastSum, View) end, Payload);',
                        'unit(N, ether(Last, LastSum, View), fun() -> ether(First, FirstSum, View) end, Payload);']
    ],
    # A link start that fails when its driver ends under it: the stack's own start fails.
    crash_at_start_spins_no_supervisor: [
      'erx_net_sup', ['false -> {ok, Sup}', 'false -> stop_link(Sup, Error)']
    ],
    # A stack that starts no lo0 beside a configured interface: its own addresses are unreachable.
    own_addresses_are_reached_over_lo0: [
      'erx_net_sup', ['[] -> [#{}];', '[] -> [];']
    ],
    # A loopback address taken from the wire, as any address of the stack.
    loopback_address_off_lo0_is_dropped: [
      'erx_ip4', ['Wire, not Loopback -> {drop, bad_addr};', 'Wire, Loopback -> {drop, bad_addr};']
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
