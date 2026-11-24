%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_h4, erx_hci and erx_bt_hci_core (docs/design-bluetooth.md,
%% "Verification"). Every number is written out here, so a value changed in
%% abi/formats/bluetooth.txt fails a case. The explored case walks every state the core
%% reaches from start against a controller that may answer each command well, badly or
%% not at all, and checks the core's invariants on every transition.
-module(erx_bt_hci_tests).

-include_lib("eunit/include/eunit.hrl").

-define(READY_CONFIG(Limit), config(Limit)).
%% The phone every connection of the cases comes from.
-define(PEER, {random, <<16#C1, 1, 2, 3, 4, 5>>}).
%% LE Long Term Key Request Reply and Negative Reply.
-define(IS_LTK(Opcode), (Opcode =:= 16#201A orelse Opcode =:= 16#201B)).

%% erx_h4.

a_stream_cut_anywhere_splits_the_same_test() ->
    Stream = <<4, 16#0E, 4, 1, 3, 16#0C, 0,                      % Command Complete for HCI_Reset
               2, 16#40, 16#20, 5, 0, 1, 0, 4, 0, 16#AA,         % ACL on handle 0x040, start
               4, 16#13, 5, 1, 16#40, 0, 1, 0>>,                 % Number Of Completed Packets
    {Whole, <<>>} = erx_h4:split(Stream),
    ?assertEqual([{event, 16#0E, <<1, 3, 16#0C, 0>>}, {acl, 16#040, 2, 0, <<1, 0, 4, 0, 16#AA>>},
                  {event, 16#13, <<1, 16#40, 0, 1, 0>>}], Whole),
    [begin
         <<Head:Cut/binary, Tail/binary>> = Stream,
         {First, Rest} = erx_h4:split(Head),
         {Second, <<>>} = erx_h4:split(<<Rest/binary, Tail/binary>>),
         ?assertEqual(Whole, First ++ Second)
     end || Cut <- lists:seq(0, byte_size(Stream))].

unknown_indicator_is_an_error_test() ->
    ?assertEqual({error, {bad_indicator, 3}}, erx_h4:split(<<3, 1, 0, 0>>)),
    ?assertEqual({error, {bad_indicator, 1}}, erx_h4:split(<<4, 16#10, 1, 0, 1, 3, 16#0C, 0>>)).

acl_of_251_octets_splits_test() ->
    Data = binary:copy(<<7>>, 251),
    ?assertMatch({[{acl, 1, 2, 0, Data}], <<>>}, erx_h4:split(<<2, 1, 16#20, 251, 0, Data/binary>>)).

acl_of_252_octets_is_an_error_test() ->
    %% Refused at its header, before its data arrive.
    ?assertEqual({error, {acl_too_long, 252}}, erx_h4:split(<<2, 1, 16#20, 252, 0>>)),
    ?assertEqual({error, {acl_too_long, 16#0100}}, erx_h4:split(<<2, 1, 16#20, 0, 1>>)).

framing_round_trips_test() ->
    ?assertEqual(<<1, 3, 16#0C, 0>>, erx_h4:command(16#0C03, <<>>)),
    ?assertEqual(<<2, 16#41, 0, 2, 0, 9, 9>>, erx_h4:acl(16#041, 0, <<9, 9>>)).

%% erx_hci.

opcodes_are_ogf_and_ocf_test() ->
    ?assertEqual([16#0C03, 16#0C01, 16#0C33, 16#1001, 16#1002, 16#1005, 16#1009, 16#2001, 16#2002, 16#2003,
                  16#2005, 16#2006, 16#2008, 16#2009, 16#200A, 16#0406],
                 [erx_hci:opcode(Name) || Name <- [reset, set_event_mask, host_buffer_size, read_local_version,
                                                   read_local_commands, read_buffer_size, read_bd_addr,
                                                   le_set_event_mask, le_read_buffer_size, le_read_features,
                                                   le_set_random_address, le_set_advertising_parameters,
                                                   le_set_advertising_data, le_set_scan_response_data,
                                                   le_set_advertising_enable, disconnect]]).

command_parameters_test() ->
    ?assertEqual({16#0C33, <<251, 0, 0, 8, 0, 0, 0>>}, erx_hci:command({host_buffer_size, 251, 8})),
    ?assertEqual({16#2005, <<5, 4, 3, 2, 1, 16#C0>>}, erx_hci:command({le_set_random_address, <<16#C0, 1, 2, 3, 4, 5>>})),
    ?assertEqual({16#2006, <<160, 0, 160, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 7, 0>>},
                 erx_hci:command({le_set_advertising_parameters, 160})),
    {16#2008, <<3, 2, 1, 6, Zeros/binary>>} = erx_hci:command({le_set_advertising_data, <<2, 1, 6>>}),
    ?assertEqual(binary:copy(<<0>>, 28), Zeros),
    ?assertEqual({16#0406, <<16#41, 0, 16#13>>}, erx_hci:command({disconnect, 16#41, 16#13})).

events_decode_test() ->
    ?assertEqual({command_complete, 1, 16#0C03, <<0>>}, erx_hci:event(16#0E, <<1, 3, 16#0C, 0>>)),
    ?assertEqual({command_status, 0, 1, 16#0406}, erx_hci:event(16#0F, <<0, 1, 6, 4>>)),
    ?assertEqual({disconnection_complete, 0, 16#40, 16#13}, erx_hci:event(16#05, <<0, 16#40, 16#F0, 16#13>>)),
    ?assertEqual({number_of_completed_packets, [{1, 2}, {3, 4}]},
                 erx_hci:event(16#13, <<2, 1, 0, 2, 0, 3, 0, 4, 0>>)),
    ?assertEqual({hardware_error, 9}, erx_hci:event(16#10, <<9>>)),
    ?assertEqual({le_connection_complete, 16#40, {public, <<6, 5, 4, 3, 2, 1>>}},
                 erx_hci:event(16#3E, <<1, 0, 16#40, 0, 1, 0, 1, 2, 3, 4, 5, 6, 24, 0, 0, 0, 16#48, 0, 0>>)),
    ?assertEqual({le_long_term_key_request, 16#40, <<0:64>>, 0}, erx_hci:event(16#3E, <<5, 16#40, 0, 0:64, 0:16>>)).

wrong_lengths_are_malformed_and_unknown_codes_are_named_test() ->
    ?assertEqual(malformed, erx_hci:event(16#13, <<2, 1, 0, 2, 0>>)),
    ?assertEqual(malformed, erx_hci:event(16#13, <<1, 1, 0, 2, 0, 0>>)),
    ?assertEqual(malformed, erx_hci:event(16#05, <<0, 1, 0>>)),
    ?assertEqual(malformed, erx_hci:event(16#3E, <<1, 0, 16#40, 0, 1, 0>>)),
    ?assertEqual(malformed, erx_hci:event(16#05, <<0, 0, 16#0F, 16#13>>)),
    ?assertEqual({unknown, 16#FF}, erx_hci:event(16#FF, <<1, 2, 3>>)),
    ?assertEqual({unknown, {le_meta, 16#02}}, erx_hci:event(16#3E, <<2, 0>>)).

%% LE Connection Complete (7.7.65.1): Peer_Address_Type 0x00 and 0x01 are a public and a
%% random device address, and any other value is reserved, so a successful event that
%% carries one is malformed, as one with a reserved handle is. A failed event carries no
%% valid parameter but its Status (4.5.1, Table 4.1): it decodes from its Status alone,
%% whatever the octets after it hold.
le_connection_complete_reads_its_status_first_test() ->
    Event = fun(Status, Handle, Type) ->
                    erx_hci:event(16#3E, <<1, Status, Handle:16/little, 1, Type, 1, 2, 3, 4, 5, 6,
                                           24, 0, 0, 0, 16#48, 0, 0>>)
            end,
    ?assertEqual({le_connection_complete, 16#40, {public, <<6, 5, 4, 3, 2, 1>>}}, Event(0, 16#40, 0)),
    ?assertEqual({le_connection_complete, 16#40, {random, <<6, 5, 4, 3, 2, 1>>}}, Event(0, 16#40, 1)),
    ?assertEqual(malformed, Event(0, 16#40, 2)),
    ?assertEqual(malformed, Event(0, 16#40, 16#FF)),
    ?assertEqual(malformed, Event(0, 16#FFFF, 0)),
    ?assertEqual({le_connection_complete, {failed, 16#3C}}, Event(16#3C, 16#FFFF, 16#FF)),
    ?assertEqual({le_connection_complete, {failed, 16#3C}}, erx_hci:event(16#3E, <<1, 16#3C>>)).

returns_decode_test() ->
    ?assertEqual({ok, #{hci_version => 9, hci_subversion => 16#0102, lmp_version => 9, company => 15,
                        lmp_subversion => 16#0304}},
                 erx_hci:return(read_local_version, <<0, 9, 2, 1, 9, 15, 0, 4, 3>>)),
    ?assertEqual({ok, {27, 4}}, erx_hci:return(le_read_buffer_size, <<0, 27, 0, 4>>)),
    ?assertEqual({failed, 12}, erx_hci:return(le_read_buffer_size, <<12>>)),
    ?assertEqual(malformed, erx_hci:return(le_read_buffer_size, <<0, 27, 0>>)),
    ?assertEqual(malformed, erx_hci:return(reset, <<>>)),
    ?assertEqual(malformed, erx_hci:return(le_read_buffer_size, <<0>>)),
    ?assertEqual(malformed, erx_hci:return(read_local_version, <<0>>)).

%% LE Long Term Key Request Reply and Negative Reply (Part E, 7.8.25, 7.8.26): OCFs 0x001A
%% and 0x001B of the LE group; the handle, then the key least significant octet first
%% (5.2); each answered by its status and the handle.
ltk_commands_test() ->
    ?assertEqual([16#201A, 16#201B], [erx_hci:opcode(le_long_term_key_request_reply),
                                      erx_hci:opcode(le_long_term_key_request_negative_reply)]),
    Key = list_to_binary(lists:seq(1, 16)),
    ?assertEqual({16#201A, <<16#FF, 16#0E, (list_to_binary(lists:seq(16, 1, -1)))/binary>>},
                 erx_hci:command({le_long_term_key_request_reply, 16#0EFF, Key})),
    ?assertEqual({16#201B, <<16#41, 0>>}, erx_hci:command({le_long_term_key_request_negative_reply, 16#41})),
    [begin
         ?assertEqual({ok, 16#41}, erx_hci:return(Name, <<0, 16#41, 0>>)),
         ?assertEqual({ok, 16#41}, erx_hci:return(Name, <<0, 16#41, 16#30>>)),   % the flag bits are not the handle's
         ?assertEqual({failed, 16#0C}, erx_hci:return(Name, <<16#0C, 16#41, 0>>)),
         ?assertEqual(malformed, erx_hci:return(Name, <<0, 16#00, 16#0F>>)),      % reserved handle 0xF00
         ?assertEqual(malformed, erx_hci:return(Name, <<0, 16#41>>)),
         ?assertEqual(malformed, erx_hci:return(Name, <<0, 16#41, 0, 0>>)),
         ?assertEqual(malformed, erx_hci:return(Name, <<0>>))
     end || Name <- [le_long_term_key_request_reply, le_long_term_key_request_negative_reply]].

%% erx_bt_hci_core, case by case. A controller answers through answer/2.

bringup_reaches_ready_with_advertising_test() ->
    {Actions, Core} = ready(1),
    ?assert(lists:keymember(ready, 1, Actions)),
    ?assertMatch(#{advertising := true, free := 4, read_local_version := #{company := 15}},
                 erx_bt_hci_core:facts(Core)).

a_failed_step_stops_with_its_label_and_status_test() ->
    {_, Core} = to_command(16#2002, new(1)),
    ?assertMatch({_, [{stop, {step_failed, buffers, 12}}]}, answer(Core, complete(16#2002, <<12>>))).

an_answer_naming_another_command_stops_test() ->
    {_, Core} = to_command(16#0C03, new(1)),
    ?assertMatch({_, [{stop, {answer_to_other_command, 16#1001}}]}, answer(Core, complete(16#1001, <<0>>))).

opcode_zero_only_updates_the_count_test() ->
    {_, Core} = to_command(16#0C03, new(1)),
    {Same, []} = answer(Core, {command_complete, 1, 0, <<>>}),
    going(answer(Same, complete(16#0C03, <<0>>))).

an_unanswered_command_stops_test() ->
    {_, Core} = to_command(16#0C03, new(1)),
    ?assertEqual(5000, erx_bt_hci_core:next_deadline(Core)),
    ?assertEqual({Core, []}, erx_bt_hci_core:step(expired, 4999, Core)),
    ?assertMatch({_, [{stop, {command_timeout, reset}}]}, erx_bt_hci_core:step(expired, 5000, Core)),
    ?assertMatch({_, [{stop, {command_timeout, reset}}]}, erx_bt_hci_core:step(expired, 9000, Core)).

shared_buffers_are_read_with_read_buffer_size_test() ->
    {_, Core} = to_command(16#2002, new(1)),
    {Written, []} = step(written, Core),
    {Next, Actions} = answer(Written, complete(16#2002, <<0, 0, 0, 0>>)),
    {_, Shared} = drive(16#1005, Actions, Next),
    {Read, _} = going(answer(Shared, complete(16#1005, <<0, 27, 0, 0, 6, 0, 0, 0>>))),
    ?assertMatch(#{free := 6}, erx_bt_hci_core:facts(Read)).

reserved_buffer_lengths_stop_test() ->
    {_, Core} = to_command(16#2002, new(1)),
    ?assertMatch({_, [{stop, {step_failed, buffers, {buffers, 26, 4}}}]}, answer(Core, complete(16#2002, <<0, 26, 0, 4>>))).

a_patch_for_another_controller_stops_test() ->
    Patched = erx_bt_hci_core:new((?READY_CONFIG(1))#{patch => #{manufacturer => 305, records => [{16#FC4C, <<1>>}]}}),
    {_, Core} = to_command(16#1001, Patched),
    ?assertMatch({_, [{stop, {patch_for_other_controller, 15}}]}, answer(Core, complete(16#1001, version(15)))).

disconnection_returns_a_handles_packets_test() ->
    {Link, Core} = linked(1, 16#40),
    {Sent, _} = going(step({request, Link, {send, 0, <<1>>}}, Core)),
    ?assertMatch(#{free := 3, links := #{16#40 := 1}}, erx_bt_hci_core:facts(Sent)),
    {Gone, Actions} = step({event, {disconnection_complete, 0, 16#40, 16#13}}, Sent),
    ?assert(lists:member({link_down, Link}, Actions)),
    ?assertMatch(#{free := 4, links := #{}}, erx_bt_hci_core:facts(Gone)).

a_forged_completion_stops_test() ->
    {Link, Core} = linked(1, 16#40),
    {Sent, _} = going(step({request, Link, {send, 0, <<1>>}}, Core)),
    ?assertMatch({_, [{stop, {completion_beyond_in_flight, 16#40, 2}}]},
                 step({event, {number_of_completed_packets, [{16#40, 2}]}}, Sent)),
    ?assertMatch({_, [{stop, {completion_for_dead_handle, 16#41}}]},
                 step({event, {number_of_completed_packets, [{16#41, 1}]}}, Sent)).

a_link_beyond_its_share_is_busy_test() ->
    {Link, Core} = linked(2, 16#40),
    {One, _} = going(step({request, Link, {send, 0, <<1>>}}, Core)),
    {Two, _} = going(step({request, Link, {send, 1, <<2>>}}, One)),
    ?assertMatch({_, [{to_link, Link, busy}]}, step({request, Link, {send, 1, <<3>>}}, Two)).

%% link_up names the phone, as erx_hci decodes it, and the identity address the
%% controller advertises with, so the link reads nothing at its start to learn either.
link_up_carries_the_phone_and_the_identity_address_test() ->
    {_, Core} = ready(1),
    {_, [{link_up, {16#41, 1}, Info}]} = answer(Core, {le_connection_complete, 16#41, ?PEER}),
    ?assertEqual(#{peer => ?PEER, identity => <<16#C0, 1, 2, 3, 4, 5>>, acl_tx_max => 27, share => 4}, Info).

%% A failed LE Connection Complete is no connection: nothing changes.
a_failed_connection_changes_nothing_test() ->
    {_, Core} = ready(1),
    ?assertEqual({Core, []}, answer(Core, {le_connection_complete, {failed, 16#3C}})).

%% LE Connection Update Complete has no consumer: it reaches no link.
a_connection_update_reaches_no_link_test() ->
    {_Link, Core} = linked(1, 16#41),
    ?assertMatch({_, []}, going(answer(Core, {le_connection_update_complete, 0, 16#41}))).

%% A link's backlog (docs/design-bluetooth.md, "Commands and data credits"): the core
%% counts every message it sends a link, events, ACL packets and completions alike, until
%% the link's `taken` acknowledges it. A link that acknowledges nothing is sent exactly
%% bt_link_backlog, 32, messages; the next is dropped, the handle's disconnect is asked
%% with Low Resources (0x14, HCI 7.1.6) and written at once, and nothing more reaches the
%% link, acknowledged or not.
a_link_that_acknowledges_nothing_is_sent_32_messages_test() ->
    {Link, Core} = linked(1, 16#41),
    {Full, Sent} = traffic(Link, 16, Core),
    ?assertEqual(32, length(Sent)),
    ?assertEqual(16, length([C || {completed, _} = C <- Sent])),
    {Cut, Actions} = going(step({event, {encryption_change, 0, 16#41, 1}}, Full)),
    ?assertEqual([{write, <<1, 16#06, 16#04, 3, 16#41, 0, 16#14>>}], Actions),
    {Acknowledged, []} = going(step({request, Link, taken}, Cut)),
    {_, Later} = traffic(Link, 4, element(1, going(step(written, Acknowledged)))),
    ?assertEqual([], Later).

%% A link that acknowledges every message it is sent is never cut off.
a_link_that_acknowledges_everything_is_never_disconnected_test() ->
    {Link, Core} = linked(1, 16#41),
    {_, Sent} = lists:foldl(fun(_, {C, All}) ->
                                    {Next, Messages} = traffic(Link, 1, C),
                                    {Taken, []} = lists:foldl(fun(_, {T, []}) -> going(step({request, Link, taken}, T)) end,
                                                              {Next, []}, Messages),
                                    {Taken, All ++ Messages}
                            end, {Core, []}, lists:seq(1, 40)),
    ?assertEqual(80, length(Sent)).

%% A cut-off link's handle, once its Disconnection Complete gives it a new peer, starts
%% the new link with an empty backlog: it is sent its own 32 messages.
a_cut_handle_given_a_new_peer_starts_afresh_test() ->
    {Old, Core} = linked(1, 16#41),
    {Full, _} = traffic(Old, 16, Core),
    {Cut, [{write, _}]} = going(step({acl, 16#41, 2, 0, <<3>>}, Full)),
    {Answered, []} = going(answer(element(1, going(step(written, Cut))), {command_status, 0, 1, 16#0406})),
    {Gone, _} = going(answer(Answered, {disconnection_complete, 0, 16#41, 16#14})),
    {Reused, Up} = going(answer(Gone, {le_connection_complete, 16#41, ?PEER})),
    {_, Sent} = traffic(link_of(Up), 16, element(1, going(step(written, Reused)))),
    ?assertEqual(32, length(Sent)).

%% A link cut off after asking its own disconnect keeps that one: the handle's disconnect
%% is written once, with the link's reason.
a_cut_after_the_links_own_disconnect_writes_one_disconnect_test() ->
    {Link, Core} = linked(1, 16#41),
    {Full, _} = traffic(Link, 16, Core),
    {Asked, [{write, Written}]} = going(step({request, Link, {disconnect, 16#13}}, Full)),
    ?assertEqual(<<1, 16#06, 16#04, 3, 16#41, 0, 16#13>>, Written),
    ?assertMatch({_, []}, going(step({acl, 16#41, 2, 0, <<3>>}, element(1, going(step(written, Asked)))))).

%% A gone link's acknowledgement changes nothing, even with its handle given a new
%% peer: it never lowers the new link's backlog.
a_gone_links_acknowledgement_changes_nothing_test() ->
    {Old, Core} = linked(1, 16#41),
    {Some, _} = traffic(Old, 2, Core),
    {Gone, _} = going(answer(Some, {disconnection_complete, 0, 16#41, 16#13})),
    {Reused, Up} = going(answer(Gone, {le_connection_complete, 16#41, ?PEER})),
    New = link_of(Up),
    {Full, _} = traffic(New, 16, element(1, going(step(written, Reused)))),
    ?assertEqual({Full, []}, step({request, Old, taken}, Full)).

%% Rounds of a link's traffic: a packet the link sends, written and completed, and an
%% ACL packet for it, so each round sends the link a completion and a packet. Returns
%% the core and the messages the link was sent.
traffic(Link, Rounds, Core) ->
    lists:foldl(fun(_, {C, Sent}) -> traffic_round(Link, C, Sent) end, {Core, []}, lists:seq(1, Rounds)).

traffic_round({Handle, _} = Link, Core, Sent) ->
    {Sending, _} = going(step({request, Link, {send, 0, <<1>>}}, Core)),
    {Written, []} = going(step(written, Sending)),
    {Completed, A1} = going(answer(Written, {number_of_completed_packets, [{Handle, 1}]})),
    {Delivered, A2} = going(step({acl, Handle, 2, 0, <<2>>}, Completed)),
    {Delivered, Sent ++ [Message || {to_link, To, Message} <- A1 ++ A2, To =:= Link]}.

advertising_resumes_after_a_disconnection_test() ->
    {_, Core} = connected(1, 16#40),
    ?assertMatch(#{advertising := false}, erx_bt_hci_core:facts(Core)),
    {_, Actions} = step({event, {disconnection_complete, 0, 16#40, 16#13}}, Core),
    ?assert(lists:member({write, <<1, 16#0A, 16#20, 1, 1>>}, Actions)).

a_disconnect_answered_by_status_frees_the_slot_test() ->
    {Link, Core} = linked(1, 16#40),
    {Asked, Actions} = step({request, Link, {disconnect, 16#13}}, Core),
    ?assert(lists:member({write, <<1, 6, 4, 3, 16#40, 0, 16#13>>}, Actions)),
    {Written, []} = step(written, Asked),
    {Answered, []} = answer(Written, {command_status, 0, 1, 16#0406}),
    {_, More} = step({event, {disconnection_complete, 0, 16#40, 16#16}}, Answered),
    ?assert(lists:member({write, <<1, 16#0A, 16#20, 1, 1>>}, More)).

%% A disconnect asked for while the writer holds a packet waits; when its handle goes
%% and the controller gives it to a new peer, the disconnect goes with the old one and
%% the writer's next item is the advertising enable, not a disconnect of the new peer.
a_disconnect_never_reaches_a_reused_handle_test() ->
    {Actions, Core} = connected(2, 1),
    Link = link_of(Actions),
    ?assert(lists:member({write, <<1, 16#0A, 16#20, 1, 1>>}, Actions)),
    {Written, []} = step(written, Core),
    {Advertising, []} = answer(Written, complete(16#200A, <<0>>)),
    {Busy, [{write, <<2, _/binary>>}]} = step({request, Link, {send, 0, <<1>>}}, Advertising),
    {Asked, []} = step({request, Link, {disconnect, 16#13}}, Busy),
    ?assertEqual(5000, erx_bt_hci_core:next_deadline(Asked)),
    {Gone, _} = going(answer(Asked, {disconnection_complete, 0, 1, 16#13})),
    {Reused, _} = going(answer(Gone, {le_connection_complete, 1, ?PEER})),
    ?assertEqual({ok, [{write, <<1, 16#0A, 16#20, 1, 1>>}]},
                 element_pair(step(written, Reused))).

%% A link is named by its handle and the connection that gave it the handle: once the
%% handle goes and the controller gives it to a new peer, the old link's requests are
%% refused, changing nothing, and the new link's go through, so neither the old link's
%% packet nor its disconnect reaches the new peer.
a_gone_links_requests_never_reach_the_handles_next_peer_test() ->
    {Old, Core} = linked(1, 1),
    {Gone, Down} = answer(Core, {disconnection_complete, 0, 1, 16#13}),
    ?assert(lists:member({link_down, Old}, Down)),
    {Written, []} = step(written, Gone),
    {Reused, Up} = answer(Written, {le_connection_complete, 1, ?PEER}),
    New = link_of(Up),
    ?assertNotEqual(Old, New),
    {Settled, []} = answer(Reused, complete(16#200A, <<0>>)),
    ?assertEqual({Settled, []}, step({request, Old, {send, 0, <<1>>}}, Settled)),
    ?assertEqual({Settled, []}, step({request, Old, {disconnect, 16#13}}, Settled)),
    ?assertMatch({_, [{write, <<2, 1, 0, 1, 0, 1>>}]},
                 step({request, New, {send, 0, <<1>>}}, Settled)),
    ?assertMatch({_, [{write, <<1, 6, 4, 3, 1, 0, 16#13>>}]},
                 step({request, New, {disconnect, 16#13}}, Settled)).

%% A disconnect keeps its mark until Disconnection Complete: a second request is
%% ignored after the first was answered. Unknown Connection Identifier is the handle
%% already gone, and Command Disallowed what NimBLE's and Zephyr's controllers answer
%% for a connection already ending, so either keeps the mark until the handle's
%% Disconnection Complete, sending nothing more; any other failure stops.
a_disconnect_is_asked_once_and_a_failure_other_than_gone_or_ending_stops_test() ->
    {Link, Core} = linked(1, 16#40),
    {Asked, _} = going(step({request, Link, {disconnect, 16#13}}, Core)),
    {Written, []} = step(written, Asked),
    {Answered, []} = answer(Written, {command_status, 0, 1, 16#0406}),
    ?assertMatch({_, []}, step({request, Link, {disconnect, 16#13}}, Answered)),
    ?assertMatch({_, []}, answer(Written, {command_status, 2, 1, 16#0406})),
    {Disallowed, []} = answer(Written, {command_status, 16#0C, 1, 16#0406}),
    ?assertEqual({Disallowed, []}, step({request, Link, {disconnect, 16#13}}, Disallowed)),
    ?assertMatch({_, [{link_down, Link} | _]},
                 answer(Disallowed, {disconnection_complete, 0, 16#40, 16#13})),
    ?assertMatch({_, [{stop, {disconnect_failed, 16#40, {failed, 16#12}}}]},
                 answer(Written, {command_status, 16#12, 1, 16#0406})).

%% A disconnect is not asked again, which would hold off the Long Term Key replies: a
%% connection not ended by a successful Disconnection Complete 45 s after its disconnect
%% was handed to the writer, past the longest supervision timeout, stops, whether the
%% disconnect was answered Command Disallowed for a connection that is not ending (as
%% Zephyr's is with no procedure context free) or its Disconnection Complete failed.
%% Nothing is written before then, and a successful Disconnection Complete drops the
%% deadline. The deadline counts from the moment the writer takes the disconnect, 1000.
a_disconnect_not_completed_by_its_deadline_stops_test() ->
    {Link, Core} = linked(1, 16#40),
    At = fun(Time, Input, Before) -> erx_bt_hci_core:step(Input, Time, Before) end,
    {Asked, [{write, <<1, 6, 4, 3, 16#40, 0, 16#13>>}]} = At(1000, {request, Link, {disconnect, 16#13}}, Core),
    ?assertEqual(6000, erx_bt_hci_core:next_deadline(Asked)),
    {Written, []} = At(1100, written, Asked),
    {Disallowed, []} = At(1200, {event, {command_status, 16#0C, 1, 16#0406}}, Written),
    {Succeeded, []} = At(1200, {event, {command_status, 0, 1, 16#0406}}, Written),
    {Failed, []} = At(1300, {event, {disconnection_complete, 16#0C, 16#40, 16#13}}, Succeeded),
    [begin
         ?assertEqual(46000, erx_bt_hci_core:next_deadline(Refused)),
         ?assertEqual({Refused, []}, At(45999, expired, Refused)),
         ?assertMatch({_, [{stop, {disconnect_not_completed, 16#40}}]}, At(46000, expired, Refused))
     end || Refused <- [Disallowed, Failed]],
    {Gone, [{link_down, Link}, {write, <<1, 16#0A, 16#20, 1, 1>>}]} =
        At(2000, {event, {disconnection_complete, 0, 16#40, 16#16}}, Failed),
    {Advertising, []} = At(2100, written, Gone),
    {Quiet, []} = At(2200, {event, complete(16#200A, <<0>>)}, Advertising),
    ?assertEqual(infinity, erx_bt_hci_core:next_deadline(Quiet)).

%% New advertising data (docs/design-bluetooth.md, "Advertising"): written with LE Set
%% Advertising Data at the next free command slot; two inputs before the slot frees write
%% only the later; one given during the bring-up is written once the core is ready.
advertising_data_is_written_at_the_next_free_slot_test() ->
    {_, Ready} = ready(1),
    {Written, Actions} = going(step({advertising_data, <<2, 1, 6, 3, 2, 1, 2>>}, Ready)),
    ?assertEqual([{write, set_advertising_data(<<2, 1, 6, 3, 2, 1, 2>>)}], Actions),
    {Busy, []} = going(step({advertising_data, <<2, 1, 6>>}, Written)),
    {Later, []} = going(step({advertising_data, <<2, 1, 7>>}, Busy)),
    {Taken, []} = going(step(written, Later)),
    {Answered, Next} = going(answer(Taken, complete(16#2008, <<0>>))),
    ?assertEqual([{write, set_advertising_data(<<2, 1, 7>>)}], Next),
    {Idle, []} = going(answer(element(1, going(step(written, Answered))), complete(16#2008, <<0>>))),
    ?assertEqual(infinity, erx_bt_hci_core:next_deadline(Idle)),
    {BringUp, _} = going(step(start, new(1))),
    {Given, []} = going(step({advertising_data, <<2, 1, 9>>}, BringUp)),
    {Core1, Actions1} = going(step(line_ready, Given)),
    ?assertEqual([set_advertising_data(<<2, 1, 6>>), set_advertising_data(<<2, 1, 9>>)],
                 [W || <<1, 16#2008:16/little, _/binary>> = W <- writes_until(16#200A, Actions1, Core1)]).

%% A controller that refuses new advertising data stops the core, whose restart writes the
%% configuration's data in the bring-up.
refused_advertising_data_stops_test() ->
    {_, Ready} = ready(1),
    {Written, _} = going(step({advertising_data, <<2, 1, 6>>}, Ready)),
    {Taken, []} = going(step(written, Written)),
    ?assertMatch({_, [{stop, {step_failed, advertising_update, _}}]}, answer(Taken, complete(16#2008, <<16#12>>))).

set_advertising_data(Data) ->
    {Opcode, Parameters} = erx_hci:command({le_set_advertising_data, Data}),
    erx_h4:command(Opcode, Parameters).

%% Every write from Actions on, answering each command well, until the command Opcode is
%% written.
writes_until(Opcode, Actions, Core) ->
    Writes = [W || {write, W} <- Actions],
    case [Op || <<1, Op:16/little, _/binary>> <- Writes] of
        [Opcode] -> Writes;
        [Other] ->
            {Written, []} = step(written, Core),
            {Answered, Next} = answer(Written, complete(Other, good({Other, x}))),
            Writes ++ writes_until(Opcode, Next, Answered)
    end.

%% The advertising data input explored: from a ready core of one connection, every
%% sequence of up to three inputs of two data, interleaved with the writer taking its
%% item, each command answered well, and a connection on handle 1 made and ended, twice
%% at most. On every transition the core never stops, and each LE Set Advertising Data
%% written carries the data last given, given since the last such write; at quiescence (the
%% writer idle, no command unanswered, no deadline) the data last written is the data last
%% given.
-record(adv, {core, writer = idle, command = none, given = none, pending = false, written = none, inputs = 0,
              connections = 0, live = false}).

explored_advertising_data_test() ->
    {_, Ready} = ready(1),
    Start = #adv{core = Ready},
    Count = adv_walk([Start], sets:from_list([adv_key(Start)], [{version, 2}]), 0),
    ?assert(Count > 100).

adv_walk([], _Seen, Count) ->
    Count;
adv_walk([World | Rest], Seen, Count) ->
    adv_quiescent(World),
    {Next, Seen1} = lists:foldl(fun(Input, {Queue, S}) ->
                                        After = adv_step(Input, World),
                                        Key = adv_key(After),
                                        case sets:is_element(Key, S) of
                                            true -> {Queue, S};
                                            false -> {[After | Queue], sets:add_element(Key, S)}
                                        end
                                end, {Rest, Seen}, adv_inputs(World)),
    adv_walk(Next, Seen1, Count + 1).

adv_key(#adv{} = World) -> World.

adv_inputs(#adv{writer = Writer, command = Command, inputs = Inputs, connections = Connections, live = Live}) ->
    [{advertising_data, D} || Inputs < 3, D <- [<<2, 1, 6>>, <<2, 1, 7>>]] ++
        [written || Writer =:= busy] ++
        [{event, complete(Opcode, <<0>>)} || {Opcode, _} <- [Command], Writer =:= idle] ++
        [{event, {le_connection_complete, 1, ?PEER}} || not Live, Connections < 2] ++
        [{event, {disconnection_complete, 0, 1, 16#13}} || Live].

adv_step(Input, #adv{core = Core} = World) ->
    {Next, Actions} = step(Input, Core),
    ?assertNotMatch([{stop, _}], Actions),
    Observed = lists:foldl(fun adv_observe/2, adv_consume(Input, World#adv{core = Next}), Actions),
    Observed.

adv_consume({advertising_data, D}, #adv{inputs = N} = World) -> World#adv{given = D, pending = true, inputs = N + 1};
adv_consume(written, World) -> World#adv{writer = idle};
adv_consume({event, {command_complete, _, _, _}}, World) -> World#adv{command = none};
adv_consume({event, {le_connection_complete, 1, _}}, #adv{connections = N} = World) ->
    World#adv{live = true, connections = N + 1};
adv_consume({event, {disconnection_complete, 0, 1, _}}, World) -> World#adv{live = false}.

adv_observe({write, <<1, 16#2008:16/little, _Length, Data/binary>> = Packet},
            #adv{given = Given, pending = Pending} = World) ->
    ?assertEqual(set_advertising_data(Given), Packet),
    ?assert(Pending),
    World#adv{writer = busy, command = {16#2008, Data}, written = Given, pending = false};
adv_observe({write, <<1, Opcode:16/little, _Length, Parameters/binary>>}, World) ->
    World#adv{writer = busy, command = {Opcode, Parameters}};
adv_observe(_Action, World) ->
    World.

adv_quiescent(#adv{writer = idle, command = none, core = Core, given = Given, written = Written}) ->
    case erx_bt_hci_core:next_deadline(Core) of
        infinity when Given =/= none -> ?assertEqual(Given, Written);
        _ -> ok
    end;
adv_quiescent(_World) ->
    ok.

%% A connection that completes while the advertising enable is written and unanswered
%% came from that enable: its answer leaves advertising off, and the disconnection
%% enables it again.
a_connection_before_the_enable_answer_leaves_advertising_off_test() ->
    {_, Core} = to_command(16#200A, new(1)),
    {Connected, _} = going(answer(Core, {le_connection_complete, 1, ?PEER})),
    {Written, []} = step(written, Connected),
    {Answered, []} = answer(Written, complete(16#200A, <<0>>)),
    ?assertMatch(#{advertising := false}, erx_bt_hci_core:facts(Answered)),
    {_, Actions} = answer(Answered, {disconnection_complete, 0, 1, 16#13}),
    ?assert(lists:member({write, <<1, 16#0A, 16#20, 1, 1>>}, Actions)).

%% The line's reset is under a deadline too, which the line's readiness drops for the
%% first command's.
a_line_reset_that_never_ends_stops_test() ->
    {Resetting, [line_reset]} = step(start, new(1)),
    ?assertEqual(5000, erx_bt_hci_core:next_deadline(Resetting)),
    ?assertMatch({_, [{stop, line_reset_timeout}]}, erx_bt_hci_core:step(expired, 5000, Resetting)),
    {Ready, [{write, <<1, 3, 16#0C, 0>>}]} = erx_bt_hci_core:step(line_ready, 1000, Resetting),
    ?assertEqual(6000, erx_bt_hci_core:next_deadline(Ready)).

%% A disconnect written and unanswered may be carried out on whichever peer holds its
%% handle when the controller reads it, so a new connection on that handle stops.
a_connection_on_a_handle_being_disconnected_stops_test() ->
    {Link, Core} = linked(2, 1),
    {Written, []} = step(written, Core),
    {Advertising, []} = answer(Written, complete(16#200A, <<0>>)),
    {Asked, [{write, <<1, 6, 4, 3, 1, 0, 16#13>>}]} =
        step({request, Link, {disconnect, 16#13}}, Advertising),
    {Gone, _} = going(answer(Asked, {disconnection_complete, 0, 1, 16#13})),
    ?assertMatch({_, [{stop, {connection_while_disconnecting, 1}}]}, answer(Gone, {le_connection_complete, 1, ?PEER})).

element_pair({_Core, Actions}) -> {ok, Actions}.

%% Num_HCI_Command_Packets 0: the next command falls due, unsent, under a deadline from
%% the moment it falls due, which passes unless an opcode-0 event allows it (Part E,
%% 4.4).
a_command_the_controller_never_allows_stops_on_its_deadline_test() ->
    {_, Core} = to_command(16#0C03, new(1)),
    {Written, []} = step(written, Core),
    {Due, []} = erx_bt_hci_core:step({event, {command_complete, 0, 16#0C03, <<0>>}}, 1000, Written),
    ?assertEqual(6000, erx_bt_hci_core:next_deadline(Due)),
    ?assertMatch({_, [{stop, {command_timeout, {first, read_local_version}}}]}, erx_bt_hci_core:step(expired, 6000, Due)),
    {Sent, [{write, <<1, 1, 16#10, 0>>}]} = erx_bt_hci_core:step({event, {command_complete, 1, 0, <<>>}}, 3000, Due),
    ?assertEqual(6000, erx_bt_hci_core:next_deadline(Sent)),
    {_, Allowed} = answer(Due, {command_complete, 1, 0, <<>>}),
    ?assertEqual([{write, <<1, 1, 16#10, 0>>}], Allowed).

%% At the limit, with the controller allowing no command, connections that complete and
%% end in turn make the advertising enable due, not due and due again: its deadline runs
%% from the moment it first fell due through every refill, so the controller process stops
%% on it, by its label when it is due then and as no command taken when it is not. Only
%% a controller allowing a command while none is due empties the slot.
a_command_due_again_keeps_its_deadline_test() ->
    {_, Core} = connected(1, 16#40),
    At = fun(Now, Event, Before) -> going(erx_bt_hci_core:step({event, Event}, Now, Before)) end,
    {Refusing, []} = At(0, {command_complete, 0, 0, <<>>}, Core),
    {Due, _} = At(1000, {disconnection_complete, 0, 16#40, 16#13}, Refusing),
    ?assertEqual(6000, erx_bt_hci_core:next_deadline(Due)),
    {Full, _} = At(2000, {le_connection_complete, 16#41, ?PEER}, Due),
    ?assertEqual(6000, erx_bt_hci_core:next_deadline(Full)),
    ?assertMatch({_, [{stop, command_not_written}]}, erx_bt_hci_core:step(expired, 6000, Full)),
    {Again, _} = At(3000, {disconnection_complete, 0, 16#41, 16#13}, Full),
    ?assertEqual(6000, erx_bt_hci_core:next_deadline(Again)),
    ?assertMatch({_, [{stop, {command_timeout, advertise}}]}, erx_bt_hci_core:step(expired, 6000, Again)),
    {Allowed, []} = At(4000, {command_complete, 1, 0, <<>>}, Full),
    ?assertEqual(infinity, erx_bt_hci_core:next_deadline(Allowed)).

%% Number Of Completed Packets passes each live handle's count to its link, named in
%% full, so the link counts its own share back.
completions_reach_each_handles_link_test() ->
    {_, Ready} = ready(2),
    {One, Up1} = answer(Ready, {le_connection_complete, 16#40, ?PEER}),
    {Advertising, _} = going(step(written, One)),
    {Enabled, _} = going(answer(Advertising, complete(16#200A, <<0>>))),
    {Two, Up2} = answer(Enabled, {le_connection_complete, 16#41, ?PEER}),
    {A, B} = {link_of(Up1), link_of(Up2)},
    {S1, [{write, _}]} = step({request, A, {send, 0, <<1>>}}, Two),
    {W1, []} = step(written, S1),
    {S2, [{write, _}]} = step({request, B, {send, 0, <<2>>}}, W1),
    {W2, []} = step(written, S2),
    ?assertMatch({_, [{to_link, A, {completed, 1}}, {to_link, B, {completed, 1}}]},
                 step({event, {number_of_completed_packets, [{16#40, 1}, {16#41, 1}]}}, W2)),
    %% A count of 0 tells the link nothing; a handle named twice is counted twice.
    ?assertMatch({_, [{to_link, B, {completed, 1}}]},
                 step({event, {number_of_completed_packets, [{16#40, 0}, {16#41, 1}]}}, W2)),
    ?assertMatch({_, [{stop, {completion_beyond_in_flight, 16#41, 1}}]},
                 step({event, {number_of_completed_packets, [{16#41, 1}, {16#41, 1}]}}, W2)).

%% A packet still on the writer's list has not reached the controller, so a completion
%% of it is forged: the list stays within the credits however the line stalls.
a_completion_of_a_queued_packet_stops_test() ->
    {Link, Core} = linked(1, 16#40),
    {One, [{write, _}]} = step({request, Link, {send, 0, <<1>>}}, Core),
    {Two, []} = step({request, Link, {send, 0, <<2>>}}, One),
    ?assertMatch({_, [{to_link, Link, {completed, 1}}]},
                 step({event, {number_of_completed_packets, [{16#40, 1}]}}, Two)),
    ?assertMatch({_, [{stop, {completion_beyond_in_flight, 16#40, 2}}]},
                 step({event, {number_of_completed_packets, [{16#40, 2}]}}, Two)).

%% A command is in flight once the writer has it: with the line stalled, an answer to
%% the next command, due and not yet written, is forged.
an_answer_to_a_command_not_yet_written_stops_test() ->
    {_, Core} = to_command(16#0C03, new(1)),
    {Due, []} = answer(Core, complete(16#0C03, <<0>>)),
    ?assertMatch({_, [{stop, {answer_to_other_command, 16#1001}}]}, answer(Due, complete(16#1001, version(15)))).

fewer_buffers_than_connections_lower_the_limit_test() ->
    {_, Core} = to_command(16#2002, new(2)),
    {Read, _} = going(answer(Core, complete(16#2002, <<0, 27, 0, 1>>))),
    ?assertMatch(#{limit := 1, free := 1}, erx_bt_hci_core:facts(Read)).

%% LE Read Buffer Size's length 0 also means shared buffers; Read Buffer Size reserves
%% no lengths, but a length or count of 0 is outside its range (7.8.2, 7.4.5).
shared_buffers_take_any_length_from_one_test() ->
    {_, Core} = to_command(16#2002, new(1)),
    {Written, []} = step(written, Core),
    {Next, Actions} = answer(Written, complete(16#2002, <<0, 0, 0, 4>>)),
    {_, Shared} = drive(16#1005, Actions, Next),
    {Read, _} = going(answer(Shared, complete(16#1005, <<0, 8, 0, 0, 3, 0, 0, 0>>))),
    ?assertMatch(#{free := 3}, erx_bt_hci_core:facts(Read)),
    ?assertMatch({_, [{stop, {step_failed, shared_buffers, {buffers, 0, 3}}}]},
                 answer(Shared, complete(16#1005, <<0, 0, 0, 0, 3, 0, 0, 0>>))).

%% The LE Long Term Key Request reaches the handle's link; the link's reply is sent for
%% its own handle with its key, least significant octet first, and the Command Complete
%% goes back to it.
a_long_term_key_reply_reaches_the_controller_and_its_answer_the_link_test() ->
    {Link, Core} = linked(1, 16#41),
    Request = {le_long_term_key_request, 16#41, <<0:64>>, 0},
    ?assertMatch({_, [{to_link, Link, Request}]}, answer(Core, Request)),
    Key = list_to_binary(lists:seq(1, 16)),
    {Asked, [{write, Written}]} = going(step({request, Link, {ltk_reply, Key}}, Core)),
    ?assertEqual(<<1, 16#1A, 16#20, 18, 16#41, 0, (list_to_binary(lists:seq(16, 1, -1)))/binary>>, Written),
    {Sent, []} = step(written, Asked),
    ?assertMatch({_, [{to_link, Link, {ltk_reply_complete, ok}}]}, answer(Sent, complete(16#201A, <<0, 16#41, 0>>))),
    ?assertMatch({_, [{to_link, Link, {ltk_reply_complete, {failed, 16#0C}}}]},
                 answer(Sent, complete(16#201A, <<16#0C, 16#41, 0>>))),
    ?assertMatch({_, [{to_link, Link, {ltk_reply_complete, {failed, 16#0C}}}]},
                 answer(Sent, {command_status, 16#0C, 1, 16#201A})),
    ?assertMatch({_, [{stop, {ltk_reply_answer, 16#41, {ok, 16#42}}}]}, answer(Sent, complete(16#201A, <<0, 16#42, 0>>))),
    ?assertMatch({_, [{stop, {ltk_reply_answer, 16#41, malformed}}]}, answer(Sent, complete(16#201A, <<0, 16#41>>))),
    ?assertMatch({_, [{stop, {ltk_reply_answer, 16#41, {ok, none}}}]}, answer(Sent, {command_status, 0, 1, 16#201A})).

a_link_with_no_key_sends_a_negative_reply_test() ->
    {Link, Core} = linked(1, 16#41),
    ?assertMatch({_, [{write, <<1, 16#1B, 16#20, 2, 16#41, 0>>}]}, step({request, Link, {ltk_reply, none}}, Core)).

%% A second reply asked before the first is taken is ignored; one asked after it is
%% taken is sent after the first is answered.
a_reply_waits_once_with_its_handle_test() ->
    {Link, Core} = linked(1, 16#41),
    {Busy, [{write, <<1, 16#1B, 16#20, 2, 16#41, 0>>}]} = step({request, Link, {ltk_reply, none}}, Core),
    {Asked, []} = going(step({request, Link, {ltk_reply, <<7:128>>}}, Busy)),
    ?assertEqual({Asked, []}, step({request, Link, {ltk_reply, <<8:128>>}}, Asked)),
    {Written, []} = step(written, Asked),
    {Answered, Actions} = answer(Written, complete(16#201B, <<0, 16#41, 0>>)),
    ?assertMatch([{to_link, Link, {ltk_reply_complete, ok}}, {write, <<1, 16#1A, 16#20, 18, 16#41, 0, 7, 0:120>>}],
                 Actions),
    ?assertMatch({_, []}, step(written, Answered)).

%% A reply asked and not yet taken goes with its handle at Disconnection Complete; one
%% handed to the writer and unanswered stops a connection on its handle.
a_reply_never_reaches_a_reused_handle_test() ->
    {Link, Core} = linked(1, 16#41),
    {Busy, [{write, <<1, 16#06, 16#04, _/binary>>}]} = step({request, Link, {disconnect, 16#13}}, Core),
    {Asked, []} = going(step({request, Link, {ltk_reply, <<7:128>>}}, Busy)),
    {Gone, [{link_down, Link}]} = answer(Asked, {disconnection_complete, 0, 16#41, 16#13}),
    {Free, []} = step(written, Gone),
    ?assertMatch({_, [{write, <<1, 16#0A, 16#20, 1, 1>>}]}, answer(Free, {command_status, 0, 1, 16#0406})),
    {Link2, Core2} = linked(1, 16#41),
    {Sending, [{write, <<1, 16#1A, 16#20, _/binary>>}]} = step({request, Link2, {ltk_reply, <<9:128>>}}, Core2),
    {Down, [{link_down, Link2}]} = answer(Sending, {disconnection_complete, 0, 16#41, 16#13}),
    ?assertEqual({Down, [{stop, {connection_while_replying, 16#41}}]},
                 answer(Down, {le_connection_complete, 16#41, ?PEER})).

%% A request the core does not know stops without the request in the reason, since a
%% malformed reply may hold a key.
a_malformed_reply_stops_without_its_key_test() ->
    {Link, Core} = linked(1, 16#41),
    ?assertEqual({Core, [{stop, {unexpected_request, Link}}]}, step({request, Link, {ltk_reply, <<7:120>>}}, Core)).

%% The explored case: every state reachable from start, breadth first, until none is
%% left; running out of the budget first fails. The world is the core and what the
%% process and the controller hold: whether the line is being reset, the writer's item,
%% the command written and not yet answered, the clock, the live handles whose
%% disconnect was asked for since they connected and whether it was written, each live link's identity from its
%% link_up, the identities of the links gone, and the connections made. The clock starts
%% at 0 and moves only to the core's deadline, when it passes; only a bring-up wait's
%% passing leaves the core running, so the clock takes one value more than the waits (at
%% most three, with the patch's two), and every deadline is one of those values plus a
%% timeout. A link's identity is new with every connection, so a path makes at most
%% ?EXPLORE_CONNECTIONS connections on a handle not live, enough for a handle to be given
%% a new peer while the other handle is live, and the states are finite. From start, at
%% each state the line, the controller and the clock may: finish the line's reset; take
%% the writer's item; let the deadline pass, which must stop the core or change it, after
%% a wake-up just before it changed nothing; answer the command written well (and
%% allowing one more command or none), with a failed status, with another command's
%% opcode, or by Command Status; send an opcode-0 event allowing one command or none;
%% report a hardware error or a malformed event; identify a controller of another
%% company; once, an event or ACL packet the core drops; connect, in any state, on a
%% handle not live or past the limit; and for each live handle, disconnect it from
%% either side, fail its Disconnection Complete, take or deliver a packet, ask a Long Term Key reply (on handle 1 with a
%% key, on handle 2 without one; in the configuration without a patch, and while no
%% other reply waits or is in flight, so queued replies are the cases'), report a Long Term Key Request, and complete packets truly or falsely. The
%% invariants hold on every transition; a request naming a gone link, its handle given a
%% new peer or not, is refused and changes nothing, and some state has a gone link's
%% handle live again; every state before ready has a deadline, so every path ends in
%% ready or a stop; a path patches at most once; a written disconnect names a handle
%% whose disconnect was asked for since it last connected, and is written at most once
%% before the handle connects again; a written Long Term Key reply
%% is the one its handle's link asked since it was last taken, for that handle, with that
%% link's key or none; its answer reaches only that link; advertising is never on at
%% the limit in force, and at quiescence it is on exactly while connections are below
%% it.
-record(world, {core, line = none, writer = idle, command = none, now = 0, asked = #{}, patches = 0,
                ready = false, names = #{}, gone = [], connections = 0, replied = #{}, replies = false}).

%% The connections on a handle not live that one path makes.
-define(EXPLORE_CONNECTIONS, 3).

%% About 800,000 states for the configuration without a patch, where links ask Long Term
%% Key replies, and 160,000 for the patched one, whose states once ready are the same.
-define(EXPLORE_BUDGET, 1000000).

explored_core_keeps_its_invariants_test_() ->
    {timeout, 120, fun() ->
        Patched = (?READY_CONFIG(2))#{patch => #{manufacturer => 15, records => [{16#FC4C, <<1, 2>>}, {16#FC4E, <<>>}]}},
        Stops = lists:usort(lists:append([explore(Config) || Config <- [?READY_CONFIG(2), Patched]])),
        ?assertEqual([answer_to_other_command, command_not_written, command_timeout, completion_beyond_in_flight,
                      completion_for_dead_handle, connection_beyond_limit, connection_during_bringup,
                      connection_while_disconnecting,
                      connection_while_replying, disconnect_failed, disconnect_not_completed, duplicate_handle, hardware_error,
                      line_reset_timeout, ltk_reply_answer, malformed_event,
                      patch_for_other_controller, step_failed],
                     Stops)
    end}.

%% Walks every state of one configuration and returns the reasons it stopped for.
explore(Config) ->
    {Core, Actions} = step(start, erx_bt_hci_core:new(Config)),
    Start = observe(Actions, #world{core = Core, replies = maps:get(patch, Config) =:= none}),
    {exhausted, Stats} = walk(queue:from_list([Start]), sets:from_list([key(Start)], [{version, 2}]),
                              #{ready => 0, stops => #{}, clocks => #{}, reused => 0}, ?EXPLORE_BUDGET),
    ?assert(maps:get(ready, Stats) > 0),
    ?assert(maps:get(reused, Stats) > 0),
    ?assert(map_size(maps:get(clocks, Stats)) =< 3),
    maps:keys(maps:get(stops, Stats)).

walk(Queue, Seen, Stats, Budget) ->
    case queue:out(Queue) of
        {empty, _} -> {exhausted, Stats};
        {_, _} when Budget =:= 0 -> {budget_spent, Stats};
        {{value, World}, Rest} ->
            check_progress(World),
            check_quiescent(World),
            check_early_wake_up(World),
            check_gone_refused(World),
            Clocks = maps:put(World#world.now, true, maps:get(clocks, Stats)),
            Counted = (count_reused(World, count_ready(World, Stats)))#{clocks := Clocks},
            {Queue1, Seen1, Stats1} = lists:foldl(fun(Input, Acc) -> visit(World, Input, Acc) end,
                                                  {Rest, Seen, Counted}, inputs(World)),
            walk(Queue1, Seen1, Stats1, Budget - 1)
    end.

%% The clock's input, {expired, Deadline}, steps expired with the clock at the deadline;
%% every other input steps at the clock.
visit(#world{core = Before, now = Now} = World, Input, {Queue, Seen, Stats}) ->
    Stepped = case Input of
                  {expired, Deadline} -> erx_bt_hci_core:step(expired, Deadline, Before);
                  _ -> erx_bt_hci_core:step(Input, Now, Before)
              end,
    case Stepped of
        {_, [{stop, Reason}]} ->
            ?assertNotMatch({unexpected_input, _}, Reason),
            ?assertNotMatch({unexpected_request, _}, Reason),
            {Queue, Seen, Stats#{stops := maps:update_with(element(1, tuple(Reason)), fun(N) -> N + 1 end, 1,
                                                          maps:get(stops, Stats))}};
        {Stepped1, Actions} ->
            Core = acknowledged(Actions, Now, Stepped1),
            check_deadline_kept(Input, World),
            check_expiry_acts(Input, Before, Core),
            check_completions_passed(Input, World, Actions),
            check_replies_answered(Input, World, Actions),
            Next = observe(Actions, (consume(Input, World))#world{core = Core}),
            check(Next),
            Key = key(Next),
            case sets:is_element(Key, Seen) of
                true -> {Queue, Seen, Stats};
                false -> {queue:in(Next, Queue), sets:add_element(Key, Seen), Stats}
            end
    end.

%% Each link acknowledges every message it was sent, as a link that keeps up does, so
%% the backlogs stay empty and no link is ever cut off: every acknowledgement is taken
%% and changes nothing but the backlog.
acknowledged(Actions, Now, Core) ->
    lists:foldl(fun({to_link, Link, _}, Acc) ->
                        {Taken, []} = erx_bt_hci_core:step({request, Link, taken}, Now, Acc),
                        Taken;
                   (_, Acc) -> Acc
                end, Core, Actions).

tuple(Reason) when is_tuple(Reason) -> Reason;
tuple(Reason) -> {Reason}.

key(#world{core = Core, line = Line, writer = Writer, command = Command, now = Now, asked = Asked,
           patches = Patches, gone = Gone, replied = Replied}) ->
    {Core, Line, Writer, Command, Now, Asked, Patches, Gone, Replied}.

count_ready(#world{ready = true}, #{ready := N} = Stats) -> Stats#{ready := N + 1};
count_ready(_, Stats) -> Stats.

%% The states where a gone link's handle has been given a new peer.
count_reused(#world{names = Ids, gone = Gone}, #{reused := N} = Stats) ->
    case lists:any(fun({Handle, _}) -> is_map_key(Handle, Ids) end, Gone) of
        true -> Stats#{reused := N + 1};
        false -> Stats
    end.

%% What the line, the controller and the clock may do next. Left out: a dropped input
%% after the first, since the count is all it changes; an answer to a command due and
%% not yet written, which a case gives; events with a failed status except Disconnection Complete, the link events
%% other than Encryption Change, and completions of several handles or of no packet,
%% none of which the core reads beyond passing it on or ignoring it.
inputs(#world{core = Core, line = Line, writer = Writer, command = Command, ready = Ready, names = Ids,
              connections = Connections, replied = Replied, replies = Replies}) ->
    #{links := Links, dropped := Dropped, limit := Limit} = erx_bt_hci_core:facts(Core),
    Deadline = erx_bt_hci_core:next_deadline(Core),
    [line_ready || Line =:= resetting] ++
        [written || Writer =:= busy] ++
        [{expired, Deadline} || Deadline =/= infinity] ++
        answers(Command) ++
        [{event, {command_complete, Allowed, 0, <<>>}} || Allowed <- [0, 1]] ++
        [{event, {hardware_error, 1}}, {event, malformed}, {event, {le_connection_complete, {failed, 16#3C}}}] ++
        [Drop || Dropped =:= 0, Drop <- [{event, {unknown, 16#FF}}, {acl, 3, 2, 0, <<1>>},
                                         {event, {disconnection_complete, 0, 3, 16#13}}]] ++
        [{event, {le_connection_complete, Handle, ?PEER}} || Connections < ?EXPLORE_CONNECTIONS, Handle <- [1, 2],
                                                              not is_map_key(Handle, Links)] ++
        [{event, {le_connection_complete, 4, ?PEER}} || Ready, map_size(Links) >= Limit] ++
        lists:append([[{event, {le_connection_complete, Handle, ?PEER}},
                       {event, {disconnection_complete, 0, Handle, 16#13}},
                       {event, {disconnection_complete, 16#0C, Handle, 16#13}},
                       {request, map_get(Handle, Ids), {disconnect, 16#13}},
                       {request, map_get(Handle, Ids), {send, 0, <<Handle>>}},
                       {event, {le_long_term_key_request, Handle, <<0:64>>, 0}},
                       {acl, Handle, 2, 0, <<Handle>>},
                       {event, {encryption_change, 0, Handle, 1}},
                       {event, {number_of_completed_packets, [{Handle, InFlight + 1}]}}] ++
                      [{event, {number_of_completed_packets, [{Handle, 1}]}} || InFlight > 0] ++
                      [{request, map_get(Handle, Ids), {ltk_reply, key_of(Handle)}}
                       || Replies, map_size(Replied) =:= 0, not is_ltk(Command)]
                      || Handle := InFlight <- Links]) ++
        [{event, {number_of_completed_packets, [{3, 1}]}}].

%% Whether the command in flight is a Long Term Key reply.
is_ltk({Opcode, _}) -> ?IS_LTK(Opcode);
is_ltk(none) -> false.

answers(none) -> [];
answers({Opcode, _}) when Opcode =:= 16#0406 ->
    [{event, {command_status, 0, 1, Opcode}}, {event, {command_status, 2, 1, Opcode}},
     {event, {command_status, 16#0C, 1, Opcode}}, {event, {command_status, 16#12, 1, Opcode}},
     {event, complete(Opcode, <<0>>)}, {event, complete(Opcode, <<2>>)}];
answers({Opcode, _} = Command) ->
    [{event, {command_complete, Allowed, Opcode, good(Command)}} || Allowed <- [0, 1], not is_buffers(Opcode)] ++
        [{event, complete(Opcode, <<1>>)}, {event, complete(Opcode, bad_layout(Command))},
         {event, complete(Opcode bxor 1, <<0>>)}, {event, {command_status, 0, 1, Opcode}}] ++
        [{event, complete(Opcode, Return)} || Return <- buffers(Opcode)] ++
        [{event, complete(Opcode, version(305))} || Opcode =:= 16#1001] ++
        ltk_answers(Command).

%% A Long Term Key reply answered for another handle, or by a failed Command Status.
ltk_answers({Opcode, <<1, Opcode:16/little, _, Handle:16/little, _/binary>>}) when ?IS_LTK(Opcode) ->
    [{event, complete(Opcode, <<0, (Handle bxor 3):16/little>>)}, {event, {command_status, 16#0C, 1, Opcode}}];
ltk_answers(_Command) ->
    [].

good({16#1001, _}) -> version(15);
good({16#1002, _}) -> <<0, 0:512>>;
good({16#2003, _}) -> <<0, 0:64>>;
good({16#1009, _}) -> <<0, 1, 2, 3, 4, 5, 6>>;
good({16#2002, _}) -> <<0, 27, 0, 4>>;
good({16#1005, _}) -> <<0, 27, 0, 0, 3, 0, 0, 0>>;
good({Opcode, <<1, Opcode:16/little, _, Handle:16/little, _/binary>>}) when ?IS_LTK(Opcode) -> <<0, Handle:16/little>>;
good(_) -> <<0>>.

%% A success whose return parameters are one octet too long.
bad_layout(Command) -> <<(good(Command))/binary, 0>>.

%% The buffer answers explored, in place of good/1's: two buffers, one per connection;
%% five, two per connection and one no link may take; shared buffers by a count or a length of 0; one buffer,
%% below the limit of 2; and a reserved LE length; then from Read Buffer Size two
%% buffers, and a count of 0.
buffers(16#2002) -> [<<0, 27, 0, 2>>, <<0, 27, 0, 5>>, <<0, 27, 0, 0>>, <<0, 0, 0, 2>>, <<0, 27, 0, 1>>, <<0, 26, 0, 2>>];
buffers(16#1005) -> [<<0, 27, 0, 0, 2, 0, 0, 0>>, <<0, 27, 0, 0, 0, 0, 0, 0>>];
buffers(_) -> [].

is_buffers(Opcode) -> buffers(Opcode) =/= [].

%% The world after an input, from the world before it: the line ready, the writer's item
%% taken, the command answered, the clock at the deadline, a live handle's disconnect asked
%% for by its current link (the only links whose requests are fed), a live handle gone.
consume(line_ready, World) -> World#world{line = none};
consume(written, World) -> World#world{writer = idle};
consume({request, {Handle, _}, {disconnect, _}}, #world{asked = Asked} = World) ->
    World#world{asked = maps:merge(#{Handle => asked}, Asked)};
consume({request, {Handle, _}, {ltk_reply, Key}}, #world{replied = Replied} = World) ->
    World#world{replied = maps:merge(#{Handle => Key}, Replied)};
consume({event, {disconnection_complete, 0, Handle, _}}, #world{asked = Asked, replied = Replied} = World) ->
    World#world{asked = maps:remove(Handle, Asked), replied = maps:remove(Handle, Replied)};
consume({expired, Deadline}, World) -> World#world{now = Deadline};
consume({event, {command_complete, _, Opcode, _}}, #world{command = {Opcode, _}} = World) -> World#world{command = none};
consume({event, {command_status, _, _, Opcode}}, #world{command = {Opcode, _}} = World) -> World#world{command = none};
consume(_, World) -> World.

%% The world after the core's actions, checking that the writer is given one item at a
%% time and that a command is written only while none is in flight, and keeping the
%% live links' identities and the gone ones'.
observe(Actions, World) ->
    lists:foldl(fun observe_action/2, World, Actions).

observe_action({write, _}, #world{writer = busy}) ->
    erlang:error(second_item_before_written);
observe_action({write, <<1, 16#0406:16/little, 3, Handle:16/little, _>> = Bytes},
               #world{command = none, asked = Asked} = World) ->
    ?assertEqual({Handle, asked}, {Handle, maps:get(Handle, Asked, not_asked)}),
    World#world{writer = busy, command = {16#0406, Bytes}, asked = Asked#{Handle := written}};
observe_action({write, <<1, Opcode:16/little, _, Handle:16/little, Key/binary>> = Bytes},
               #world{command = none, replied = Replied} = World) when ?IS_LTK(Opcode) ->
    ?assertEqual({ok, asked_key(Opcode, Key)}, maps:find(Handle, Replied)),
    World#world{writer = busy, command = {Opcode, Bytes}, replied = maps:remove(Handle, Replied)};
observe_action({write, <<1, Opcode:16/little, _/binary>> = Bytes}, #world{command = none, patches = P} = World) ->
    World#world{writer = busy, command = {Opcode, Bytes}, patches = P + patch_start(Opcode)};
observe_action({write, <<1, _/binary>>}, _World) ->
    erlang:error(second_command_in_flight);
observe_action({write, <<2, _/binary>>}, World) ->
    World#world{writer = busy};
observe_action(line_reset, World) ->
    World#world{line = resetting};
observe_action({ready, _}, World) ->
    World#world{ready = true};
observe_action({link_up, {Handle, _} = Link, _Info}, #world{names = Ids, connections = N} = World) ->
    World#world{names = Ids#{Handle => Link}, connections = N + 1};
observe_action({link_down, {Handle, _} = Link}, #world{names = Ids, gone = Gone} = World) ->
    ?assertEqual(#{Handle => Link}, maps:with([Handle], Ids)),
    World#world{names = maps:remove(Handle, Ids), gone = lists:usort([Link | Gone])};
observe_action(_, World) ->
    World.

patch_start(16#FC2E) -> 1;
patch_start(_) -> 0.

%% A written reply's key as the link asked it: most significant octet first, or none.
asked_key(16#201A, <<Key:128/little>>) -> <<Key:128>>;
asked_key(16#201B, <<>>) -> none.

%% What each handle's link replies: on handle 1 a key, on handle 2 none, so a reply sent for
%% the other handle is one its link did not ask.
key_of(1) -> <<16#AA, 1:120>>;
key_of(2) -> none.

check(#world{core = Core, patches = Patches}) ->
    #{links := Links, free := Free, limit := Limit, advertising := Advertising, backlogs := Backlogs} =
        erx_bt_hci_core:facts(Core),
    ?assert(lists:all(fun(Backlog) -> Backlog =:= 0 end, maps:values(Backlogs))),
    ?assert(Patches =< 1),
    ?assert(not Advertising orelse map_size(Links) < Limit),
    ?assert(Free >= 0),
    ?assert(map_size(Links) =< Limit),
    ?assert(lists:all(fun(InFlight) -> InFlight >= 0 end, maps:values(Links))).

%% An input that neither answers a command nor fills the slot starts no deadline, the
%% writer taking the due command included, so an opcode-0 event or any traffic repeated
%% cannot hold a command off for ever: it keeps the slot's deadline, or empties the slot
%% when the line would take a command and none is due, so the deadline never comes
%% earlier. The clock moves only at a deadline, so a deadline started at the clock would
%% equal the one kept: the input is stepped again a millisecond later, where only a
%% deadline started at the input differs.
check_deadline_kept(Input, #world{core = Before, now = Now}) ->
    case keeps_deadline(Input) andalso {erx_bt_hci_core:step(Input, Now, Before),
                                         erx_bt_hci_core:step(Input, Now + 1, Before)} of
        {{_, [{stop, _}]}, _} -> ok;
        {{AtNow, _}, {Later, _}} ->
            ?assertEqual(erx_bt_hci_core:next_deadline(AtNow), erx_bt_hci_core:next_deadline(Later)),
            ?assert(erx_bt_hci_core:next_deadline(Later) >= erx_bt_hci_core:next_deadline(Before));
        false -> ok
    end.

keeps_deadline(written) -> true;
keeps_deadline({event, {command_complete, _, 0, _}}) -> true;
keeps_deadline({event, {Kind, _}}) -> Kind =:= number_of_completed_packets orelse Kind =:= unknown;
keeps_deadline({event, {encryption_change, _, _, _}}) -> true;
keeps_deadline({request, _, {send, _, _}}) -> true;
keeps_deadline({acl, _, _, _, _}) -> true;
keeps_deadline(_) -> false.

%% A deadline that passes changes the core when it does not stop it.
check_expiry_acts({expired, _}, Before, After) ->
    ?assertNotEqual(Before, After);
check_expiry_acts(_Input, _Before, _After) ->
    ok.

%% A wake-up before the deadline, or with none, is only a look: nothing changes.
check_early_wake_up(#world{core = Core, now = Now}) ->
    Early = case erx_bt_hci_core:next_deadline(Core) of
                infinity -> Now;
                Deadline -> Deadline - 1
            end,
    ?assertEqual({Core, []}, erx_bt_hci_core:step(expired, Early, Core)).

%% A gone link's requests are refused, whether its handle is live again or not: nothing
%% changes, so its packet and its disconnect never reach the handle's next peer, and its
%% acknowledgement never lowers the next link's backlog.
check_gone_refused(#world{core = Core, now = Now, gone = Gone}) ->
    [?assertEqual({Core, []}, erx_bt_hci_core:step({request, Link, Request}, Now, Core))
     || Link <- Gone, Request <- [{send, 0, <<0>>}, {disconnect, 16#13}, {ltk_reply, <<0:128>>}, {ltk_reply, none},
                                  taken]],
    ok.

%% Before ready, the core always has a deadline, which passes into the next step or a
%% stop.
check_progress(#world{ready = false, core = Core}) ->
    ?assertNotEqual(infinity, erx_bt_hci_core:next_deadline(Core));
check_progress(_) ->
    ok.

%% With nothing written, in flight or due, a ready core advertises exactly while
%% connections are below the limit in force. No command is due when a controller
%% allowing one would be written none: the idle writer takes a due command at once. Then,
%% the controller allowing one, every deadline left is a live handle's disconnect, so with
%% no live handle there is none; until then a slot whose command stopped being due keeps
%% its deadline.
check_quiescent(#world{ready = true, writer = idle, command = none, core = Core, now = Now}) ->
    #{links := Links, advertising := Advertising, limit := Limit} = erx_bt_hci_core:facts(Core),
    case erx_bt_hci_core:step({event, {command_complete, 1, 0, <<>>}}, Now, Core) of
        {Allowed, []} ->
            ?assertEqual(map_size(Links) < Limit, Advertising),
            ?assert(map_size(Links) > 0 orelse erx_bt_hci_core:next_deadline(Allowed) =:= infinity);
        {_, _Due} -> ok
    end;
check_quiescent(_) ->
    ok.

%% Each live handle's count in Number Of Completed Packets, but a count of 0, reaches the
%% handle's current link.
check_completions_passed({event, {number_of_completed_packets, Pairs}}, #world{names = Ids}, Actions) ->
    ?assertEqual([{to_link, map_get(Handle, Ids), {completed, Count}} || {Handle, Count} <- Pairs, Count > 0],
                 [Action || {to_link, _, {completed, _}} = Action <- Actions]);
check_completions_passed(_Input, _World, _Actions) ->
    ok.

%% The answer to the Long Term Key reply in flight reaches its handle's current link, if
%% any, with the outcome the controller gave, and nothing else does.
check_replies_answered(Input, #world{command = Command, names = Ids}, Actions) ->
    Expected = case {Input, Command} of
                   {{event, {command_complete, _, Opcode, <<Status, _/binary>>}},
                    {Opcode, <<1, Opcode:16/little, _, Handle:16/little, _/binary>>}} when ?IS_LTK(Opcode) ->
                       [{Link, outcome(Status)} || Link <- maps:values(maps:with([Handle], Ids))];
                   {{event, {command_status, Status, _, Opcode}},
                    {Opcode, <<1, Opcode:16/little, _, Handle:16/little, _/binary>>}} when ?IS_LTK(Opcode), Status =/= 0 ->
                       [{Link, outcome(Status)} || Link <- maps:values(maps:with([Handle], Ids))];
                   _ -> []
               end,
    ?assertEqual(Expected, [{Link, Outcome} || {to_link, Link, {ltk_reply_complete, Outcome}} <- Actions]).

outcome(0) -> ok;
outcome(Status) -> {failed, Status}.

%% Helpers: a core driven by a controller that answers every command well, at time 0.

step(Input, Core) -> erx_bt_hci_core:step(Input, 0, Core).

new(Limit) -> erx_bt_hci_core:new(?READY_CONFIG(Limit)).

%% A configuration of Limit connections with no patch.
config(Limit) ->
    #{connections => Limit, address => <<16#C0, 1, 2, 3, 4, 5>>, advertising_data => <<2, 1, 6>>,
      scan_response_data => <<>>, patch => none}.

complete(Opcode, Return) -> {command_complete, 1, Opcode, Return}.

version(Company) -> <<0, 9, 0, 0, 9, Company:16/little, 0, 0>>.

answer(Core, Event) -> step({event, Event}, Core).

%% A step's result, which must not stop.
going({_Core, Actions} = Result) ->
    ?assertNotMatch([{stop, _}], Actions),
    Result.

%% Runs the bring-up, answering each command well, until the command Opcode is written;
%% returns that step's actions and the core waiting for its answer. The bring-up's waits
%% come only with a patch, after the commands the cases drive to.
to_command(Opcode, Core0) ->
    {Core1, _} = going(step(start, Core0)),
    {Core2, Actions} = step(line_ready, Core1),
    drive(Opcode, Actions, Core2).

drive(Opcode, Actions, Core) ->
    case [Op || {write, <<1, Op:16/little, _/binary>>} <- Actions] of
        [Opcode] -> {Actions, Core};
        [Other] ->
            {Written, []} = step(written, Core),
            {Answered, Next} = answer(Written, complete(Other, good({Other, x}))),
            drive(Opcode, Next, Answered)
    end.

%% A ready core whose advertising enable has been written and answered.
ready(Limit) ->
    {Actions, Core} = to_command(16#200A, new(Limit)),
    {Written, []} = step(written, Core),
    {Ready, []} = answer(Written, complete(16#200A, <<0>>)),
    {Actions, Ready}.

%% The identity link_up gave the one link Actions started.
link_of(Actions) ->
    [Link] = [Link || {link_up, Link, _Info} <- Actions],
    Link.

%% A ready core with one link on Handle, and that link's identity.
linked(Limit, Handle) ->
    {Actions, Core} = connected(Limit, Handle),
    {link_of(Actions), Core}.

%% A ready core with one link on Handle.
connected(Limit, Handle) ->
    {_, Core} = ready(Limit),
    {Linked, Actions} = answer(Core, {le_connection_complete, Handle, ?PEER}),
    {Actions, Linked}.
