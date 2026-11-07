%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the host link's session protocol, erx_hostlink_session
%% (docs/design-live.md, "The host link", invariants V3 and V4, and the
%% host-link items of "Verification and testing"), over the frame and stream
%% layers it stands on. Each scenario drives the pure machine through a
%% small host model, `host()`, that numbers frames as the host tool does and
%% hands them to the machine as wire bytes; what the machine sends is read
%% back through the host's deframer. explore_test_ then walks every sequence
%% of events up to a stated depth over small limits and checks each step
%% against an independent model of the call window and against the
%% invariants.
-module(erx_hostlink_session_tests).

-include_lib("eunit/include/eunit.hrl").

-define(S0, <<0:128>>).
-define(NONCE, <<"nonce-0123456789">>).
-define(NONCE2, <<"nonce-9876543210">>).
%% Every piece of a control message but the last: a frame's body less the
%% control header.
-define(PIECE, 8176).

%% The host side of a test: the machine, the session the host is in (its
%% identifier and serial) and its next frame number, the identifiers the
%% target's random source hands out next, in order, and the credit frames
%% the target has sent.
-record(host, {core, sid = none, serial = none, seq = 0, entropy = [], limits = #{}, credit = []}).

sid(N) -> <<N:128>>.

config(Limits) ->
    #{build => <<"build-1">>, versions => #{frame => 2},
      measure => fun measure/1, decode => fun decode/1, limits => Limits}.

%% A stand-in for the host grammar's check: the payload <<"bad">> and any
%% encoding that holds the atom `ungrammatical` fail it, and any other
%% payload decodes to its own size.
measure(<<"bad">>) -> {error, grammar};
measure(Payload) ->
    case binary:match(Payload, <<"ungrammatical">>) of
        nomatch -> {ok, byte_size(Payload)};
        _ -> {error, grammar}
    end.

decode(Payload) ->
    try {ok, binary_to_term(Payload, [safe])}
    catch error:badarg -> {error, badarg}
    end.

%% A machine that has drawn its first identifier, sid(1), and has no session;
%% its random source then hands out sid(2), sid(3), ...
boot(Limits) ->
    boot(Limits, [sid(N) || N <- lists:seq(1, 200)]).

boot(Limits, [First | Rest]) ->
    Core = erx_hostlink_session:new(config(Limits)),
    {Core1, []} = erx_hostlink_session:step({entropy, First}, Core),
    #host{core = Core1, entropy = Rest, limits = Limits}.

%% Feeds Event to the machine, answering each draw_entropy with the next
%% identifier, as the effect layer does.
step(Event, #host{core = Core, entropy = Entropy} = H) ->
    {Core1, Actions} = erx_hostlink_session:step(Event, Core),
    case {lists:member(draw_entropy, Actions), Entropy} of
        {true, [Next | Rest]} ->
            {Core2, []} = erx_hostlink_session:step({entropy, Next}, Core1),
            {H#host{core = Core2, entropy = Rest}, Actions};
        _ ->
            {H#host{core = Core1}, Actions}
    end.

%% One frame from the host, as one read of the link. The credit frames the
%% read earns are kept apart, in the host's `credit`, so that a scenario
%% sees what the frame itself caused.
frame(Frame, H) ->
    {H1, Actions} = step({input, erx_hostlink_frame:encode(Frame)}, H),
    {Credit, Caused} = lists:partition(fun({send, Bytes}) -> maps:get(stream, decoded(Bytes)) =:= credit;
                                          (_) -> false
                                       end, Actions),
    {H1#host{credit = H1#host.credit ++ Credit}, Caused}.

%% A control frame's body: the 16-byte header and a piece of the payload.
control(Kind, More, Total, Id, Piece) ->
    Flags = case More of
                true -> 1;
                false -> 0
            end,
    <<(kind_number(Kind)):8, Flags:8, 0:16, Total:32/little, Id:64/little, Piece/binary>>.

kind_number(call) -> 1;
kind_number(reply) -> 2;
kind_number(cast) -> 3.

kind_name(1) -> call;
kind_name(2) -> reply;
kind_name(3) -> cast.

hello_frame(Nonce) ->
    Payload = term_to_binary({hello, Nonce}),
    #{stream => control, session => ?S0, seq => 0, target => 0,
      body => control(call, false, byte_size(Payload), 1, Payload)}.

%% Sends a hello and, when the target answers it, moves the host into the
%% new session.
hello(H, Nonce) ->
    {H1, Actions} = frame(hello_frame(Nonce), H),
    case [Sid || {_, {hello, N, Sid, _, _}} <- replies(Actions), N =:= Nonce] of
        [Sid] when Sid =/= H#host.sid ->
            [Serial] = [S || {session_opened, _, S} <- Actions],
            {H1#host{sid = Sid, serial = Serial, seq = 0}, Actions};
        _ -> {H1, Actions}
    end.

open(Limits) ->
    {H, _} = hello(boot(Limits), ?NONCE),
    H.

%% The frames of one control message of the host's session, numbered from
%% the host's next frame, in pieces of ?PIECE bytes.
message_frames(#host{sid = Sid, seq = Seq}, Kind, Id, Target, Payload) ->
    Pieces = chunks(Payload, ?PIECE),
    Last = length(Pieces) - 1,
    [#{stream => control, session => Sid, seq => Seq + I, target => Target,
       body => control(Kind, I < Last, byte_size(Payload), Id, P)}
     || {I, P} <- lists:enumerate(0, Pieces)].

chunks(Bin, Max) when byte_size(Bin) =< Max -> [Bin];
chunks(Bin, Max) -> <<P:Max/binary, Rest/binary>> = Bin, [P | chunks(Rest, Max)].

%% Sends the frames of one message and returns every action they caused.
send_frames(H, Frames) ->
    lists:foldl(fun(Frame, {HAcc, Acc}) ->
                        {H1, Actions} = frame(Frame, HAcc),
                        {H1#host{seq = maps:get(seq, Frame) + 1}, Acc ++ Actions}
                end, {H, []}, Frames).

call(H, Id, Target, Payload) ->
    send_frames(H, message_frames(H, call, Id, Target, Payload)).

call(H, Id) -> call(H, Id, 0, <<"p">>).

done(H, Id, Term) -> done(H, Id, Term, []).

done(#host{serial = Serial} = H, Id, Term, Opened) ->
    step({call_done, Serial, Id, Term, Opened}, H).

%% The frames the actions send, as the host's deframer takes them, with a
%% control frame's header taken apart into `control` and its piece left as
%% the body.
sent(Actions) -> [decoded(Bytes) || {send, Bytes} <- Actions].

decoded(Bytes) ->
    {[{ok, Frame}], _} = erx_hostlink_frame:feed(Bytes, erx_hostlink_frame:deframer(host)),
    case Frame of
        #{stream := control,
          body := <<Kind:8, Flags:8, 0:16, Total:32/little, Id:64/little, Piece/binary>>} ->
            Frame#{body := Piece,
                   control => #{kind => kind_name(Kind), more => Flags band 1 =:= 1,
                                total => Total, id => Id}};
        #{} ->
            Frame
    end.

%% The replies the actions send, reassembled: [{Id, Term}].
replies(Actions) ->
    Frames = [F || #{stream := control, control := #{kind := reply}} = F <- sent(Actions)],
    reassemble(Frames, []).

reassemble([], Acc) ->
    lists:reverse(Acc);
reassemble(Frames, Acc) ->
    {Message, [Last | Rest]} = lists:splitwith(
                                 fun(#{control := #{more := More}}) -> More end, Frames),
    #{control := #{id := Id, total := Total}} = Last,
    Payload = iolist_to_binary([B || #{body := B} <- Message ++ [Last]]),
    ?assertEqual(Total, byte_size(Payload)),
    reassemble(Rest, [{Id, binary_to_term(Payload)} | Acc]).

executed(Actions) -> [{Id, Target} || {execute, _, Id, Target, _} <- Actions].

info(#host{core = Core}) -> erx_hostlink_session:info(Core).

counts(H) -> maps:get(counts, info(H)).

pid(N) -> list_to_pid("<0." ++ integer_to_list(N) ++ ".0>").

zeros(N) -> binary:copy(<<0>>, N).

%%% Hello and session replacement

hello_opens_a_session_test() ->
    {H, Actions} = hello(boot(#{}), ?NONCE),
    ?assertEqual([{1, {hello, ?NONCE, sid(1), <<"build-1">>, #{frame => 2}}}], replies(Actions)),
    ?assert(lists:member({session_opened, sid(1), 1}, Actions)),
    [#{session := ?S0, seq := 0}] = sent(Actions),
    ?assertEqual(sid(1), maps:get(session, info(H))).

hello_without_entropy_opens_nothing_test() ->
    Core = erx_hostlink_session:new(config(#{})),
    {_, Actions} = hello(#host{core = Core}, ?NONCE),
    ?assertEqual([], replies(Actions)).

zero_entropy_is_refused_test() ->
    Core = erx_hostlink_session:new(config(#{})),
    {Core1, Actions} = erx_hostlink_session:step({entropy, ?S0}, Core),
    ?assertEqual([draw_entropy], Actions),
    {_, Replies} = hello(#host{core = Core1}, ?NONCE),
    ?assertEqual([], replies(Replies)).

%% Weak entropy that repeats the current identifier never reopens it: old
%% frames would otherwise name the new session.
repeated_identifier_is_refused_test() ->
    H = open(#{}),
    {Core1, []} = erx_hostlink_session:step({entropy, sid(1)}, H#host.core),
    {H1, Actions} = hello(H#host{core = Core1}, ?NONCE2),
    ?assertEqual([], replies(Actions)),
    ?assertEqual(1, maps:get(repeated_entropy, counts(H1))),
    ?assertEqual(sid(1), maps:get(session, info(H1))).


%% A hello whose payload is any other term, or that is not a call to the
%% root, is malformed: it opens nothing, ends nothing and is not answered.
malformed_hello_is_not_answered_test() ->
    H = open(#{}),
    Hello = term_to_binary({hello, ?NONCE2}),
    Bodies = [control(call, false, byte_size(P), 1, P)
              || P <- [term_to_binary(foo), term_to_binary({hello, <<1>>}),
                       term_to_binary({hello, <<0:128>>, extra}), <<"bad">>]]
        ++ [control(cast, false, byte_size(Hello), 0, Hello)],
    H1 = lists:foldl(fun(Body, HAcc) ->
                             Frame = #{stream => control, session => ?S0, seq => 0, target => 0,
                                       body => Body},
                             {HNext, Actions} = frame(Frame, HAcc),
                             ?assertEqual({Body, []}, {Body, Actions}),
                             HNext
                     end, H, Bodies),
    {H2, []} = frame((hello_frame(?NONCE2))#{target := 1}, H1),
    ?assertEqual(6, maps:get(bad_hello, counts(H2))),
    ?assertEqual(sid(1), maps:get(session, info(H2))).

%% A hello repeated with the current session's nonce, its reply lost or the
%% frame sent again, gets the same reply and replaces nothing: the host's
%% frames under the first reply still reach the session. A new nonce
%% replaces it.
repeated_hello_gets_the_same_reply_test() ->
    H = boot(#{}),
    {H1, First} = hello(H, ?NONCE),
    {H2, _} = call(H1, 1),
    {H3, Again} = frame(hello_frame(?NONCE), H2),
    ?assertEqual([A || {send, _} = A <- First], Again),
    ?assertEqual(1, maps:get(repeated_hello, counts(H3))),
    ?assertMatch(#{session := <<1:128>>, calls := #{1 := {executing, _}}}, info(H3)),
    {H4, Next} = call(H3, 2),
    ?assertEqual([{2, root}], executed(Next)),
    {H5, Replaced} = hello(H4, ?NONCE2),
    ?assertEqual(sid(2), H5#host.sid),
    ?assert(lists:member({session_ended, sid(1), replaced}, Replaced)).

%% A session whose resident limit is full can still be replaced: a hello is
%% not held against the session it replaces.
hello_replaces_a_full_session_test() ->
    H = open(#{resident => 8}),
    {H1, [{execute, _, 1, root, _}]} = call(H, 1, 0, <<"01234567">>),
    ?assertEqual(8, maps:get(resident, info(H1))),
    {H2, _} = hello(H1, ?NONCE2),
    ?assertEqual({sid(2), 0}, {H2#host.sid, maps:get(resident, info(H2))}).

session_replacement_closes_facets_test() ->
    H = open(#{}),
    {H1, [{execute, _, 1, root, _}]} = call(H, 1),
    {H2, Opened} = done(H1, 1, {ok, pid(100)}, [pid(100)]),
    ?assertEqual([{1, {ok, {'$host_cap', 1}}}], replies(Opened)),
    ?assert(lists:member({monitor_facet, pid(100)}, Opened)),
    {H3, Replaced} = hello(H2, ?NONCE2),
    ?assertEqual(sid(2), H3#host.sid),
    ?assertEqual([{close_facet, pid(100)}, {session_ended, sid(1), replaced}, {session_opened, sid(2), 2}],
                 [A || A <- Replaced, element(1, A) =/= send, A =/= draw_entropy]),
    %% A frame of the replaced session is discarded unanswered.
    {H4, Stale} = send_frames(H3, message_frames(H2#host{seq = 1}, call, 2, 1, <<"p">>)),
    ?assertEqual([], Stale),
    ?assertEqual(1, maps:get(session, counts(H4))),
    %% The replaced session's facet number names nothing in the new one.
    {_, Refused} = call(H4, 1, 1, <<"p">>),
    ?assertEqual([{1, {error, noproc}}], replies(Refused)),
    ?assertEqual([], executed(Refused)).

%% A recorded hello and its calls, replayed at a machine that reset and drew
%% another identifier, open a different session and execute nothing.
replay_after_reset_matches_no_session_test() ->
    H = open(#{}),
    Recorded = message_frames(H, call, 1, 0, <<"p">>),
    {_, [{execute, _, 1, root, _}]} = send_frames(H, Recorded),
    Reset = boot(#{}, [sid(7), sid(8)]),
    {Reopened, _} = hello(Reset, ?NONCE),
    ?assertEqual(sid(7), Reopened#host.sid),
    {Replayed, Actions} = send_frames(Reopened, Recorded),
    ?assertEqual([], Actions),
    ?assertEqual(1, maps:get(session, counts(Replayed))).

%%% At-most-once calls

retried_call_executes_once_test() ->
    H = open(#{}),
    {H1, First} = call(H, 1),
    ?assertEqual([{1, root}], executed(First)),
    {H2, WhileExecuting} = call(H1, 1),
    ?assertEqual([], WhileExecuting),
    {H3, Done} = done(H2, 1, ok),
    ?assertEqual([{1, ok}], replies(Done)),
    {_, Retried} = call(H3, 1),
    ?assertEqual({[], [{1, ok}]}, {executed(Retried), replies(Retried)}).

%% 64 calls executing when a 65th arrives: it is answered busy without being
%% seen, and runs once when sent again after an earlier call is answered.
window_full_answers_busy_test() ->
    H = lists:foldl(fun(Id, HAcc) -> {H1, [{execute, _, Id, root, _}]} = call(HAcc, Id), H1 end,
                    open(#{}), lists:seq(1, 64)),
    {H1, Busy} = call(H, 65),
    ?assertEqual({[], [{65, {error, busy}}]}, {executed(Busy), replies(Busy)}),
    ?assertEqual(1, maps:get(low, info(H1))),
    {H2, Again} = call(H1, 65),
    ?assertEqual([{65, {error, busy}}], replies(Again)),
    {H3, _} = done(H2, 1, ok),
    {H4, Runs} = call(H3, 65),
    ?assertEqual([{65, root}], executed(Runs)),
    ?assertEqual(2, maps:get(low, info(H4))),
    {_, Dup} = call(H4, 65),
    ?assertEqual([], Dup).

reply_not_kept_is_lost_test() ->
    H = open(#{kept => 0}),
    {H1, _} = call(H, 1),
    {H2, Done} = done(H1, 1, ok),
    ?assertEqual([{1, ok}], replies(Done)),
    {_, Dup} = call(H2, 1),
    ?assertEqual([{1, {error, reply_lost}}], replies(Dup)).

%% Kept replies stay within the kept limit: the second does not fit.
kept_limit_test() ->
    Size = byte_size(term_to_binary(ok)),
    H = open(#{kept => Size + 1}),
    {H1, _} = call(H, 1),
    {H2, _} = call(H1, 2),
    {H3, _} = done(H2, 1, ok),
    {H4, _} = done(H3, 2, ok),
    ?assertEqual(Size, maps:get(kept, info(H4))),
    {H5, Kept} = call(H4, 1),
    ?assertEqual([{1, ok}], replies(Kept)),
    {_, Lost} = call(H5, 2),
    ?assertEqual([{2, {error, reply_lost}}], replies(Lost)).

expired_identifier_is_refused_test() ->
    H = open(#{}),
    {H1, _} = call(H, 1),
    {H2, _} = done(H1, 1, ok),
    {H3, [{execute, _, 100, root, _}]} = call(H2, 100),
    ?assertEqual(37, maps:get(low, info(H3))),
    {_, Expired} = call(H3, 1),
    ?assertEqual({[], [{1, {error, expired}}]}, {executed(Expired), replies(Expired)}).

%% A lost frame in a fragmented message drops the message; the retry executes
%% it once.
lost_frame_in_fragmented_message_test() ->
    H = open(#{}),
    Payload = binary:copy(<<"x">>, 2 * ?PIECE + 10),
    [F0, _Lost, F2] = message_frames(H, call, 1, 0, Payload),
    {H1, Partial} = send_frames(H, [F0, F2]),
    ?assertEqual([], Partial),
    ?assertEqual(1, maps:get(gap, counts(H1))),
    {H2, Retry} = call(H1, 1, 0, Payload),
    ?assertMatch([{execute, _, 1, root, Payload}], Retry),
    {_, Dup} = call(H2, 1, 0, Payload),
    ?assertEqual([], Dup).

a_frame_below_the_sequence_is_discarded_test() ->
    H = open(#{}),
    {H1, _} = call(H, 1),
    {H2, Old} = send_frames(H1, message_frames(H, call, 2, 0, <<"p">>)),
    ?assertEqual([], Old),
    ?assertEqual(1, maps:get(seq, counts(H2))).

%% A repeated piece is discarded and leaves the message under way alone.
a_repeated_piece_keeps_the_message_test() ->
    H = open(#{}),
    Payload = binary:copy(<<"y">>, ?PIECE + 1),
    [F0, F1] = message_frames(H, call, 1, 0, Payload),
    {H1, []} = send_frames(H, [F0, F0]),
    ?assertEqual(1, maps:get(seq, counts(H1))),
    {_, Actions} = send_frames(H1, [F1]),
    ?assertMatch([{execute, _, 1, root, Payload}], Actions).

%% A long reply is sent in pieces of one message and reassembles whole.
long_reply_is_fragmented_test() ->
    H = open(#{}),
    {H1, _} = call(H, 1),
    Reply = binary:copy(<<"r">>, 20000),
    {_, Done} = done(H1, 1, Reply),
    Frames = sent(Done),
    ?assert(length(Frames) > 1),
    ?assertEqual(lists:seq(0, length(Frames) - 1), [S || #{seq := S} <- Frames]),
    ?assertEqual([{1, Reply}], replies(Done)).

%%% Resident bytes and malformed input

%% A message the resident limit cannot hold is answered busy at its first
%% frame, and the rest of it is skipped.
resident_limit_answers_busy_test() ->
    H = open(#{resident => 8}),
    {H1, Actions} = call(H, 1, 0, <<"0123456789">>),
    ?assertEqual({[], [{1, {error, busy}}]}, {executed(Actions), replies(Actions)}),
    ?assertEqual(0, maps:get(resident, info(H1))),
    {_, Fits} = call(H1, 1, 0, <<"0123">>),
    ?assertEqual([{1, root}], executed(Fits)).

resident_counts_reassembly_and_executing_calls_test() ->
    H = open(#{}),
    Payload = binary:copy(<<"z">>, 9000),
    [F0 | _] = message_frames(H, call, 1, 0, Payload),
    {H1, []} = send_frames(H, [F0]),
    ?assertEqual(9000, maps:get(resident, info(H1))),
    {H2, _} = call(H, 1, 0, Payload),
    ?assertEqual(9000, maps:get(resident, info(H2))),
    {H3, _} = done(H2, 1, ok),
    ?assertEqual(byte_size(term_to_binary(ok)), maps:get(resident, info(H3))).

%% Phase 1's payload check, erx_hostlink_payload, as the session uses it by
%% default: a call's reservation counts its binaries' bytes, so two calls of
%% 9,000-byte binaries do not fit 12,000 resident bytes, and a payload that
%% holds a pid or reference, compressed or with bytes after the term, is
%% refused unanswered.
phase_1_payload_check_test() ->
    Config = maps:without([measure, decode], config(#{resident => 12000})),
    Booted = boot(#{}, [sid(N) || N <- lists:seq(1, 9)]),
    {H, _} = hello(Booted#host{core = new_core(Config)}, ?NONCE),
    Blob = term_to_binary({put, binary:copy(<<"b">>, 9000)}),
    {H1, [{execute, _, 1, root, Blob}]} = call(H, 1, 0, Blob),
    ?assert(maps:get(resident, info(H1)) > 9000),
    {H2, Busy} = call(H1, 2, 0, Blob),
    ?assertEqual({[], [{2, {error, busy}}]}, {executed(Busy), replies(Busy)}),
    Refused = [term_to_binary({get, self()}), term_to_binary({get, make_ref()}),
               term_to_binary(binary:copy(<<0>>, 1000), [compressed]),
               <<(term_to_binary(ok))/binary, 0>>],
    H3 = lists:foldl(fun({Id, Payload}, HAcc) ->
                             {HNext, Actions} = call(HAcc, Id, 0, Payload),
                             ?assertEqual({Id, []}, {Id, Actions}),
                             HNext
                     end, H2, lists:enumerate(3, Refused)),
    ?assertEqual(length(Refused), maps:get(bad_payload, counts(H3))),
    ?assertEqual({error, type}, erx_hostlink_payload:measure(term_to_binary(fun() -> ok end))),
    ?assertEqual({error, compressed}, erx_hostlink_payload:decode(lists:nth(3, Refused))).

new_core(Config) ->
    {Core, []} = erx_hostlink_session:step({entropy, sid(1)}, erx_hostlink_session:new(Config)),
    Core.

%% Malformed input is counted and never answered.
malformed_input_is_not_answered_test() ->
    H = open(#{message_max => 32}),
    Cases = [{too_long, call, 1, binary:copy(<<"l">>, 33)},
             {reply_from_host, reply, 1, <<"p">>},
             {call_without_id, call, 0, <<"p">>},
             {cast_with_id, cast, 3, <<"p">>}],
    lists:foldl(fun({Name, Kind, Id, Payload}, HAcc) ->
                        {H1, Actions} = send_frames(HAcc, message_frames(HAcc, Kind, Id, 0, Payload)),
                        ?assertEqual({Name, []}, {Name, Actions}),
                        H1
                end, H, Cases),
    {H2, BadPayload} = call(H, 1, 0, <<"bad">>),
    ?assertEqual([], BadPayload),
    ?assertEqual(1, maps:get(bad_payload, counts(H2))),
    {_, Later} = call(H2, 1),
    ?assertEqual([{1, root}], executed(Later)).

%%% Facets

%% The 1,025th facet is refused with system_limit and closed; a facet's number
%% is never reused.
facet_limit_test() ->
    H = open(#{}),
    {H1, _} = lists:foldl(fun(Id, {HAcc, _}) ->
                                  {HA, _} = call(HAcc, Id),
                                  done(HA, Id, {ok, pid(Id)}, [pid(Id)])
                          end, {H, []}, lists:seq(1, 1024)),
    ?assertEqual(1024, map_size(maps:get(facets, info(H1)))),
    {H2, _} = call(H1, 1025),
    {H3, Refused} = done(H2, 1025, {ok, pid(1025)}, [pid(1025)]),
    ?assertEqual([{1025, {error, system_limit}}], replies(Refused)),
    ?assert(lists:member({close_facet, pid(1025)}, Refused)),
    {H4, []} = step({facet_down, pid(7)}, H3),
    {H5, _} = call(H4, 1026),
    {_, Opened} = done(H5, 1026, {ok, pid(1026)}, [pid(1026)]),
    ?assertEqual([{1026, {ok, {'$host_cap', 1025}}}], replies(Opened)).

closed_facet_number_is_refused_test() ->
    H = open(#{}),
    {H1, _} = call(H, 1),
    {H2, _} = done(H1, 1, {ok, pid(100)}, [pid(100)]),
    {H3, OnFacet} = call(H2, 2, 1, <<"p">>),
    ?assertEqual([{2, pid(100)}], executed(OnFacet)),
    {H4, _} = done(H3, 2, ok),
    {H5, []} = step({facet_down, pid(100)}, H4),
    {H6, Refused} = call(H5, 3, 1, <<"p">>),
    ?assertEqual({[], [{3, {error, noproc}}]}, {executed(Refused), replies(Refused)}),
    {_, Dup} = call(H6, 3, 1, <<"p">>),
    ?assertEqual([{3, {error, noproc}}], replies(Dup)).

%% Pids that are not facets the call opened, and references, are names.
pids_and_references_are_names_test() ->
    H = open(#{}),
    {H1, _} = call(H, 1),
    Ref = make_ref(),
    {_, Done} = done(H1, 1, {pid(5), Ref, #{pid(6) => [pid(5)]}}),
    P5 = {'$pid', list_to_binary(pid_to_list(pid(5)))},
    P6 = {'$pid', list_to_binary(pid_to_list(pid(6)))},
    ?assertEqual([{1, {P5, {'$ref', list_to_binary(ref_to_list(Ref))}, #{P6 => [P5]}}}],
                 replies(Done)).

%% A facet the call opened but did not hand out is closed, never kept.
unused_opened_facet_is_closed_test() ->
    H = open(#{}),
    {H1, _} = call(H, 1),
    {H2, Done} = done(H1, 1, ok, [pid(9)]),
    ?assert(lists:member({close_facet, pid(9)}, Done)),
    ?assertEqual(#{}, maps:get(facets, info(H2))).

%% What a call of a replaced session opened is closed when it finishes.
call_of_an_ended_session_closes_what_it_opened_test() ->
    H = open(#{}),
    {H1, _} = call(H, 1),
    {H2, _} = hello(H1, ?NONCE2),
    {_, Late} = step({call_done, 1, 1, {ok, pid(4)}, [pid(4)]}, H2),
    ?assertEqual([{close_facet, pid(4)}], Late).

%%% Credit, streams and counters

%% Credit grants back only bytes read, in batches, as the total granted in
%% the session, so a host that sends within its credit never has more than
%% the starting 16 KiB unread. An idle link gets what is owed, or the last
%% grant again.
credit_test() ->
    H = open(#{}),
    {H1, []} = step({input, zeros(4095)}, H),
    {H2, Granted} = step({input, zeros(1)}, H1),
    ?assertMatch([#{stream := credit, target := 4096, session := <<1:128>>}], sent(Granted)),
    {H3, []} = step({input, zeros(10)}, H2),
    {H4, Idle} = step(idle, H3),
    ?assertMatch([#{stream := credit, target := 4106}], sent(Idle)),
    {_, Again} = step(idle, H4),
    ?assertMatch([#{stream := credit, target := 4106}], sent(Again)),
    {_, []} = step({input, zeros(8192)}, boot(#{})),
    {_, []} = step(idle, boot(#{})).

%% A session counts the reads after the one that held its hello, so it never
%% grants a byte the host sent before its hello.
credit_counts_the_reads_after_the_hello_test() ->
    Read = <<(zeros(5000))/binary, (erx_hostlink_frame:encode(hello_frame(?NONCE)))/binary,
             (zeros(5000))/binary>>,
    {H, Opened} = step({input, Read}, boot(#{})),
    ?assertEqual([], [F || #{stream := credit} = F <- sent(Opened)]),
    {_, Idle} = step(idle, H),
    ?assertMatch([#{stream := credit, target := 0}], sent(Idle)).

%% A host that sends 1,000-byte frames only within its credit, 16 KiB at the
%% start of the session: while the target consumes nothing it stops after 16
%% frames, with no more unread than its starting credit, and resumes only
%% as the target grants back what it read.
credit_exhaustion_test() ->
    Frame = 1000,
    H = open(#{}),
    {Credit1, Sent1} = send_within(16384, 0),
    ?assertEqual({384, 16}, {Credit1, Sent1}),
    ?assertEqual({384, 0}, send_within(Credit1, 0)),
    {H1, Grants} = consume(H, Sent1, Frame),
    Granted = lists:last(Grants),
    ?assert(Granted =< Sent1 * Frame),
    ?assert(Granted > Sent1 * Frame - 4096),
    {_, Resumed} = send_within(Credit1 + Granted, 0),
    ?assert(Resumed >= 12),
    {_, []} = step({input, zeros(1)}, H1).

%% Frames of 1,000 bytes a host may send with Credit: the credit left and the
%% number sent.
send_within(Credit, Sent) when Credit >= 1000 -> send_within(Credit - 1000, Sent + 1);
send_within(Credit, Sent) -> {Credit, Sent}.

%% The target reads Count frames of Size bytes; the totals it grants.
consume(H, Count, Size) ->
    lists:foldl(fun(_, {HAcc, Acc}) ->
                        {H1, Actions} = step({input, zeros(Size)}, HAcc),
                        {H1, Acc ++ [T || #{stream := credit, target := T} <- sent(Actions)]}
                end, {H, []}, lists:seq(1, Count)).

%% A message cut into short pieces is refused, and holds nothing: every
%% piece but the last is a full one, so a message has as many pieces as
%% its total needs.
short_pieces_are_refused_test() ->
    H = open(#{}),
    Payload = <<"0123456789">>,
    Pieces = [<<B>> || <<B>> <= Payload],
    Frames = [#{stream => control, session => sid(1), seq => Seq, target => 0,
                body => control(call, Seq < length(Pieces) - 1, byte_size(Payload), 1, P)}
              || {Seq, P} <- lists:enumerate(0, Pieces)],
    {Refused, []} = send_frames(H, Frames),
    ?assertEqual(0, maps:get(resident, info(Refused))),
    ?assertEqual(length(Pieces), maps:get(pieces, counts(Refused))),
    {_, Actions} = call(Refused, 1, 0, Payload),
    ?assertMatch([{execute, _, 1, root, Payload}], Actions).

%% A frame under another key than the message in progress drops that
%% message and starts its own.
another_message_drops_the_one_in_progress_test() ->
    H = open(#{}),
    [F0 | _] = message_frames(H, call, 1, 0, binary:copy(<<"w">>, 9000)),
    {H1, []} = send_frames(H, [F0]),
    {H2, Actions} = call(H1, 2),
    ?assertEqual([{2, root}], executed(Actions)),
    ?assertEqual(1, maps:get(pieces, counts(H2))).

%% Ports and funs in a reply are names: a fun's captured values never reach
%% the host.
ports_and_funs_are_names_test() ->
    H = open(#{}),
    {H1, _} = call(H, 1),
    Secret = <<"captured-secret">>,
    Fun = fun() -> Secret end,
    Port = hd(erlang:ports()),
    {_, Done} = done(H1, 1, {Fun, Port}),
    [{1, {{'$fun', FunName}, {'$port', PortName}}}] = replies(Done),
    ?assert(is_binary(FunName)),
    ?assertEqual(list_to_binary(port_to_list(Port)), PortName),
    ?assertEqual(nomatch, binary:match(reply_bytes(Done), Secret)).

%% A reply the host grammar refuses, or one over the message limit, is
%% replaced, and the facet it would have handed out is closed, not tabled.
unsendable_reply_is_replaced_test() ->
    H = open(#{message_max => 64}),
    {H1, _} = call(H, 1),
    {H2, Refused} = done(H1, 1, {ok, ungrammatical, pid(8)}, [pid(8)]),
    ?assertEqual([{1, {error, system_limit}}], replies(Refused)),
    ?assert(lists:member({close_facet, pid(8)}, Refused)),
    ?assertEqual(#{}, maps:get(facets, info(H2))),
    {H3, _} = call(H2, 2),
    {H4, Long} = done(H3, 2, {ok, binary:copy(<<"x">>, 100), pid(9)}, [pid(9)]),
    ?assertEqual([{2, {error, system_limit}}], replies(Long)),
    ?assert(lists:member({close_facet, pid(9)}, Long)),
    ?assertEqual(#{}, maps:get(facets, info(H4))).

%% With entropy that repeats an earlier session's identifier, the outcome of
%% that session's call does not land in the new session: calls are matched
%% by the session's serial.
late_outcome_with_a_repeated_identifier_test() ->
    H = boot(#{}, [sid(1), sid(2), sid(1), sid(9)]),
    {A, _} = hello(H, ?NONCE),
    {A1, _} = call(A, 5),
    {B, _} = hello(A1, ?NONCE2),
    {A2, _} = hello(B, ?NONCE),
    ?assertEqual({sid(1), 3}, {A2#host.sid, A2#host.serial}),
    {A3, [{execute, 3, 5, root, _}]} = call(A2, 5),
    {A4, Late} = step({call_done, 1, 5, {ok, pid(6)}, [pid(6)]}, A3),
    ?assertEqual([{close_facet, pid(6)}], Late),
    ?assertEqual(#{}, maps:get(facets, info(A4))),
    {_, Own} = done(A4, 5, ok),
    ?assertEqual([{5, ok}], replies(Own)).

%% A map whose keys would print alike cannot be shown faithfully, so the
%% reply is refused rather than lose a value.
colliding_map_keys_are_refused_test() ->
    H = open(#{}),
    {H1, _} = call(H, 1),
    Alias = {'$pid', list_to_binary(pid_to_list(pid(80)))},
    {_, Done} = done(H1, 1, #{pid(80) => a, Alias => b}),
    ?assertEqual([{1, {error, system_limit}}], replies(Done)).

%% The inspector sees a kept reply's size, never its bytes.
info_shows_no_reply_bytes_test() ->
    H = open(#{}),
    {H1, _} = call(H, 1),
    {H2, _} = done(H1, 1, ok),
    ?assertEqual(#{1 => {answered, byte_size(term_to_binary(ok))}}, maps:get(calls, info(H2))).

limits_are_checked_test() ->
    ?assertError({unknown_limit, windw}, erx_hostlink_session:new(config(#{windw => 2}))),
    Long = (config(#{}))#{build := binary:copy(<<"b">>, 9000)},
    ?assertError({config, hello_reply}, erx_hostlink_session:new(Long)).

streams_are_delivered_and_sent_test() ->
    H = open(#{}),
    Term = #{stream => terminal, session => sid(1), seq => 0, target => 0, body => <<"ls\r">>},
    {H1, [{deliver, terminal, <<"ls\r">>}]} = frame(Term, H),
    {H2, Out} = step({output, terminal, binary:copy(<<"x">>, 9000)}, H1),
    ?assertEqual([8192, 808], [byte_size(B) || #{stream := terminal, body := B} <- sent(Out)]),
    {H3, []} = step({output, files, binary:copy(<<"x">>, 8193)}, H2),
    ?assertEqual(1, maps:get(oversize_files_output, counts(H3))).

casts_execute_without_a_reply_test() ->
    H = open(#{}),
    {_, Actions} = send_frames(H, message_frames(H, cast, 0, 0, <<"p">>)),
    ?assertMatch([{cast, _, root, <<"p">>}], Actions).

%% Outgoing frame numbers end the session instead of wrapping.
outgoing_sequence_ends_the_session_test() ->
    H = open(#{last_seq => 2}),
    {H1, _} = call(H, 1),
    {H2, Done} = done(H1, 1, {ok, pid(3)}, [pid(3)]),
    ?assertMatch([#{seq := 0}], sent(Done)),
    {H3, Log1} = step({output, events, <<"log">>}, H2),
    ?assertMatch([#{seq := 1}], sent(Log1)),
    {H4, Log2} = step({output, events, <<"log">>}, H3),
    ?assertMatch([#{seq := 2}], sent(Log2)),
    {H5, Ended} = step({output, events, <<"log">>}, H4),
    ?assertEqual([{close_facet, pid(3)}, {session_ended, sid(1), exhausted}], Ended),
    ?assertEqual(none, maps:get(session, info(H5))).

%% The last incoming frame number is taken and ends the session, since
%% nothing can follow it; a frame of that session is then refused.
incoming_sequence_does_not_wrap_test() ->
    H = open(#{}),
    AtLast = H#host{seq = 16#FFFFFFFF},
    {H1, Actions} = send_frames(AtLast, message_frames(AtLast, call, 1, 0, <<"p">>)),
    ?assertMatch([{execute, _, 1, root, _}, {session_ended, _, exhausted}], Actions),
    ?assertEqual(none, maps:get(session, info(H1))),
    Later = H1#host{seq = 0},
    {H2, []} = send_frames(Later, message_frames(Later, call, 2, 0, <<"p">>)),
    ?assertEqual(1, maps:get(session, counts(H2))).

%% A frame at the last seq ends the session even when the receiver discards
%% it, since no frame can follow it either way.
malformed_last_frame_ends_the_session_test() ->
    H = open(#{}),
    Bad = #{stream => control, session => sid(1), seq => 16#FFFFFFFF, target => 0,
            body => <<9, 0, 0:16, 1:32/little, 1:64/little, 0>>},
    {H1, Actions} = frame(Bad, H),
    ?assertEqual([{session_ended, sid(1), exhausted}], Actions),
    ?assertEqual(none, maps:get(session, info(H1))).

%%% Exhaustive exploration

%% Every sequence of events up to ?DEPTH over a window of 2, one facet and
%% kept replies of 12 bytes, from an open session. The events are a hello
%% with a fresh nonce, which replaces the session, and the current session's
%% hello again, which replaces nothing; single-frame calls 1 to 4 to the
%% root and call 1 to facet 1; the two pieces of a call 3 of more than one
%% frame; a lost frame and a duplicated one; a call of the replaced session
%% and the late outcome of each call it left executing; the completion of
%% each executing call (with ok, or with a facet opened) and the exit of
%% each facet. Each step is checked against oracle/3, a model of V4 written
%% over the highest admitted identifier rather than the window's bottom,
%% and against the invariants of check/4. The resident limit is left at its
%% default here, so busy for want of resident bytes is covered by the
%% scenario tests alone.
-define(DEPTH, 8).
-define(LIMITS, #{window => 2, facets => 1, kept => 12}).
%% Call 3's payload: one full piece and a short last one.
-define(LONG, binary:copy(<<"abcd">>, (?PIECE + 4) div 4)).

explore_test_() ->
    {timeout, 600, fun() ->
        World = world(open(?LIMITS)),
        Visited = explore([World], ?DEPTH, sets:new([{version, 2}])),
        ?assert(sets:size(Visited) > 1000)
    end}.

%% A world is the host, the current session's nonce, the model of its
%% window, the message in progress, the host's last frame, the replaced
%% session and its calls left executing, and the history the invariants
%% need.
world(H) ->
    #{host => H, nonce => ?NONCE, old => none, late => [], partial => none, last => none,
      model => model(), executed => sets:new([{version, 2}]), numbers => #{},
      tx => #{H#host.sid => 0}, pids => 0}.

model() -> #{high => 0, executing => [], answered => #{}}.

explore([], _Depth, Visited) ->
    Visited;
explore(_Worlds, 0, Visited) ->
    Visited;
explore(Worlds, Depth, Visited) ->
    {Next, Visited1} =
        lists:foldl(fun(World, {Acc, Seen}) ->
                            Key = key(World),
                            case sets:is_element(Key, Seen) of
                                true -> {Acc, Seen};
                                false -> {[apply_event(E, World) || E <- events(World)] ++ Acc,
                                          sets:add_element(Key, Seen)}
                            end
                    end, {[], Visited}, Worlds),
    explore(Next, Depth - 1, Visited1).

%% A world's state, for finding the worlds already explored: the session as
%% info/1 shows it, less the discard counts and with what the stream holds,
%% and the host and the rest of the world. The grant's running count and
%% the counts change with every frame but decide nothing explored here.
key(#{host := H} = World) ->
    {maps:remove(counts, info(H)), H#host.seq, maps:remove(host, World)}.

events(#{host := H, old := Old, late := Late, last := Last}) ->
    #{calls := Calls, facets := Facets} = info(H),
    [hello, rehello, lose, {call, 1, 1}, first3, rest3]
        ++ [{call, Id, 0} || Id <- lists:seq(1, 4)]
        ++ [old_call || Old =/= none]
        ++ [duplicate || Last =/= none]
        ++ [{late_done, Serial, Id} || {Serial, Id} <- Late]
        ++ [{done, Id, Kind} || Id := {executing, _} <- Calls, Kind <- [ok, facet]]
        ++ [{down, Pid} || _ := Pid <- Facets].

%% Whether the target is reassembling call 3, as the world tracks it: its
%% first piece was the host's last frame; a lost frame since then means the
%% target dropped it, and a repeated frame changes nothing.
in_progress(#{partial := Seq, host := #host{seq = Next}}) -> Seq =:= Next - 1.

%% Sends Frames of the current session and remembers the last for a
%% duplicate.
send(Frames, #{host := H} = W) ->
    {H1, Actions} = send_frames(H, Frames),
    {W#{host => H1, last => lists:last(Frames)}, Actions}.

apply_event(hello, #{host := H} = W) ->
    Nonce = list_to_binary(io_lib:format("nonce-~10..0B", [length(H#host.entropy)])),
    {H1, Actions} = hello(H, Nonce),
    #{calls := Calls} = info(H),
    Late = [{H#host.serial, Id} || Id := {executing, _} <- Calls],
    W1 = W#{host => H1, nonce => Nonce, old => H#host.sid, late => Late, partial => none,
            last => none, model => model(), tx => (maps:get(tx, W))#{H1#host.sid => 0}},
    check(hello, Actions, W, W1);
apply_event(rehello, #{host := H, nonce := Nonce} = W) ->
    %% The current session's hello again: answered with its reply, and the
    %% session, its window and the message under way stay as they were.
    {H1, Actions} = frame(hello_frame(Nonce), H),
    ?assertMatch([{_, {hello, Nonce, _, _, _}}], replies(Actions)),
    [{_, {hello, Nonce, Sid, _, _}}] = replies(Actions),
    ?assertEqual({[], Sid}, {[A || A <- Actions, element(1, A) =/= send], H#host.sid}),
    check(rehello, Actions, W, W#{host => H1});
apply_event(lose, #{host := H} = W) ->
    W#{host => H#host{seq = H#host.seq + 1}};
apply_event(duplicate, #{host := H, last := Last} = W) ->
    {H1, Actions} = frame(Last, H),
    ?assertEqual([], Actions),
    check(duplicate, Actions, W, W#{host => H1});
apply_event({call, Id, Target} = Event, #{host := H} = W) ->
    %% A frame of another message while one is in progress drops that
    %% message and is taken whole.
    {W0, Actions} = send(message_frames(H, call, Id, Target, <<"p">>), W),
    W1 = observe(oracle(Id, Target, W), Id, Actions, W0#{partial => none}),
    check(Event, Actions, W, W1);
apply_event(old_call, #{host := H, old := Old} = W) ->
    %% A frame of the replaced session: the host's own numbering is that
    %% session's, so the current session's does not move.
    {H1, Actions} = send_frames(H, message_frames(H#host{sid = Old}, call, 1, 0, <<"p">>)),
    ?assertEqual([], Actions),
    check(old_call, Actions, W, W#{host => H#host{core = H1#host.core}});
apply_event({late_done, Serial, Id} = Event, #{host := H, late := Late, pids := Pids} = W) ->
    %% The replaced session's call finishes having opened a facet, which
    %% has no table to enter.
    P = pid(1000 + Pids),
    {H1, Actions} = step({call_done, Serial, Id, {ok, P}, [P]}, H),
    ?assertEqual([{close_facet, P}], Actions),
    check(Event, Actions, W, W#{host => H1, late => Late -- [{Serial, Id}], pids => Pids + 1});
apply_event(first3, #{host := H} = W) ->
    %% A first piece is reassembled whatever the window says; a second first
    %% piece of the same message overruns its total and drops it.
    [F0, _] = message_frames(H, call, 3, 0, ?LONG),
    {W0, Actions} = send([F0], W),
    ?assertEqual([], Actions),
    W1 = case in_progress(W) of
             false -> W0#{partial => H#host.seq};
             true -> W0#{partial => none}
         end,
    check(first3, Actions, W, W1);
apply_event(rest3, #{host := H} = W) ->
    [_, F1] = message_frames(H#host{seq = H#host.seq - 1}, call, 3, 0, ?LONG),
    {W0, Actions} = send([F1], W),
    Expected = case in_progress(W) of
                   true -> oracle(3, 0, W);
                   false -> nothing
               end,
    W1 = observe(Expected, 3, Actions, W0#{partial => none}),
    check(rest3, Actions, W, W1);
apply_event({done, Id, Kind} = Event, #{host := H, pids := Pids} = W) ->
    {Term, Opened} = case Kind of
                         ok -> {ok, []};
                         facet -> {{ok, pid(1000 + Pids)}, [pid(1000 + Pids)]}
                     end,
    {H1, Actions} = done(H, Id, Term, Opened),
    [{Id, _}] = replies(Actions),
    %% V3: a facet the call opened is in the table or closed.
    Facets = maps:values(maps:get(facets, info(H1))),
    ?assert(lists:all(fun(P) -> lists:member(P, Facets) orelse lists:member({close_facet, P}, Actions) end,
                      Opened)),
    W1 = W#{host => H1, pids => Pids + length(Opened),
            model => model_done(Id, reply_bytes(Actions), W)},
    check(Event, Actions, W, W1);
apply_event({down, Pid} = Event, #{host := H} = W) ->
    {H1, Actions} = step({facet_down, Pid}, H),
    check(Event, Actions, W, W#{host => H1}).

reply_bytes(Actions) ->
    iolist_to_binary([B || #{stream := control, body := B} <- sent(Actions)]).

%% The independent model of V4: the window is the Window identifiers up to the
%% highest one admitted. What the call should get: executed (or, naming no
%% facet, answered noproc), ignored, or answered.
oracle(Id, Target, #{model := #{high := High, executing := Executing, answered := Answered},
                     host := H}) ->
    #{window := Window} = ?LIMITS,
    Facets = maps:get(facets, info(H)),
    Admit = case Target =:= 0 orelse is_map_key(Target, Facets) of
                true -> execute;
                false -> noproc
            end,
    if
        Id =< High - Window -> {reply, {error, expired}};
        true ->
            case {lists:member(Id, Executing), Answered} of
                {true, _} -> nothing;
                {false, #{Id := {kept, Bytes}}} -> {reply, binary_to_term(Bytes)};
                {false, #{Id := lost}} -> {reply, {error, reply_lost}};
                {false, _} when Id =< High -> Admit;
                {false, _} ->
                    case [E || E <- Executing, E =< Id - Window] of
                        [] -> Admit;
                        _ -> {reply, {error, busy}}
                    end
            end
    end.

%% Compares what the machine did for call Id with the model's expectation
%% and advances the model.
observe(nothing, _Id, Actions, W) ->
    ?assertEqual([], [A || A <- Actions, element(1, A) =/= monitor_facet]),
    W;
observe({reply, Term}, Id, Actions, W) ->
    ?assertEqual({[], [{Id, Term}]}, {executed(Actions), replies(Actions)}),
    W;
observe(execute, Id, Actions, #{model := Model} = W) ->
    ?assertEqual([Id], [I || {I, _} <- executed(Actions)]),
    W#{model => admit(Id, Model#{executing := [Id | maps:get(executing, Model)]})};
observe(noproc, Id, Actions, #{model := Model} = W) ->
    ?assertEqual({[], [{Id, {error, noproc}}]}, {executed(Actions), replies(Actions)}),
    W1 = W#{model => admit(Id, Model#{executing := [Id | maps:get(executing, Model)]})},
    W1#{model => model_done(Id, reply_bytes(Actions), W1)}.

admit(Id, #{high := High, answered := Answered} = Model) ->
    #{window := Window} = ?LIMITS,
    High1 = max(High, Id),
    Model#{high := High1, answered := maps:filter(fun(I, _) -> I > High1 - Window end, Answered)}.

%% A call's reply is kept when the kept replies still fit the kept limit.
model_done(Id, Bytes, #{model := #{executing := Executing, answered := Answered} = Model}) ->
    #{kept := Limit} = ?LIMITS,
    Kept = lists:sum([byte_size(B) || _ := {kept, B} <- Answered]),
    Entry = case Kept + byte_size(Bytes) =< Limit of
                true -> {kept, Bytes};
                false -> lost
            end,
    Model#{executing := lists:delete(Id, Executing), answered := Answered#{Id => Entry}}.

%% The invariants of every step: a call executes at most once per session and
%% only on the root or a facet of the table; every frame sent names the
%% current session (or the all-zero one, for a hello's reply) with a frame
%% number above the last one's (a read's credit frames, which the host model
%% keeps apart, take numbers between them); the window, kept replies, resident bytes and the facet table
%% stay within their limits; and a facet number is never reused.
check(Event, Actions, #{host := Before}, #{host := After} = W) ->
    #{window := Window, kept := KeptLimit, facets := FacetLimit} = ?LIMITS,
    Sid = After#host.sid,
    FacetsBefore = maps:get(facets, info(Before)),
    Executed = lists:foldl(
                 fun({execute, S, Id, Target, _}, Set) ->
                         ?assertEqual({Event, S}, {Event, Before#host.serial}),
                         ?assertNot(sets:is_element({S, Id}, Set)),
                         case Target of
                             root -> ok;
                             Pid -> ?assert(lists:member(Pid, maps:values(FacetsBefore)))
                         end,
                         sets:add_element({S, Id}, Set);
                    (_, Set) -> Set
                 end, maps:get(executed, W), Actions),
    Tx = lists:foldl(
           fun(#{session := ?S0}, T) -> T;
              (#{session := S, seq := Seq}, T) ->
                   ?assertEqual({Event, S}, {Event, Sid}),
                   ?assert(Seq >= maps:get(S, T)),
                   T#{S => Seq + 1}
           end, maps:get(tx, W), sent(Actions)),
    Info = info(After),
    #{low := Low, calls := Calls, kept := Kept, facets := Facets} = Info,
    ?assert(lists:all(fun(Id) -> Id >= Low andalso Id < Low + Window end, maps:keys(Calls))),
    ?assert(Kept =< KeptLimit),
    ?assert(maps:get(resident, Info) =< maps:get(resident, erx_hostlink_session:default_limits())),
    ?assert(map_size(Facets) =< FacetLimit),
    Numbers = maps:get(numbers, W),
    Issued = maps:get(Sid, Numbers, []),
    New = maps:keys(Facets) -- maps:keys(FacetsBefore),
    ?assert(lists:all(fun(N) -> not lists:member(N, Issued) end, New)),
    W#{executed => Executed, tx => Tx, numbers => Numbers#{Sid => Issued ++ New}}.
