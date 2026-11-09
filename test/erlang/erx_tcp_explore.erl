%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_explore).
-moduledoc """
The exhaustive exploration of the TCP core (docs/design-network-stack.md, "The TCP core:
exhaustive exploration"). It drives one connection, opened with `connect`, with small
buffers and windows through erx_tcp:step/3, against a model of its peer, over the base
alphabet:

* segments with every combination of SYN, ACK, FIN and RST, with and without data, at each
  sequence position class (below the receive window, at `rcv_nxt`, inside, at the right
  edge, beyond) and, with ACK, each acknowledgement class (below `snd_una - max_sndwnd`,
  old, at `snd_una`, in flight, at `snd_max`, beyond); a class with no value in the
  current state (in flight with nothing in flight) is left out;
* the owner's requests: send, recv (`rcvd` of what is buffered), close, shutdown of the
  write side and abort;
* the expiry of the connection's earliest deadline, which moves the clock to it.

The exploration is breadth-first. Every event of the alphabet is applied in every state
reached, and a state whose abstraction (`abstraction/1`: the TCP state, the FIN state,
which send and receive variables are equal, which deadlines are set, the recovery state)
was seen before is not explored again, until no new abstract state appears or the depth
limit is reached. Each transition is checked against the properties of `properties/0`;
the first one to fail ends the exploration with its name and its trace, the events from
the start. The trace is a shortest one in the explored graph, whose shorter traces were
all checked first; a node merged away may have had a shorter one.

The peer model is what the checks measure the connection against without reading its
reasoning: the peer's byte stream is a fixed function of the wire sequence number
(`stream/2`), so any segment's payload is the stream at its position and the bytes
delivered must be the stream from the initial receive sequence number on; the model keeps
the end of what the peer has sent and the right edge of the windows it has offered.

`explore/1` with `wrap => true` runs the same exploration with both initial sequence
numbers just below 2^32, so that every position class also crosses the wire's wrap.
""".

-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-export([explore/1, properties/0, abstraction/1]).

-export_type([result/0]).

-define(T0, 1000000000).
%% The initial sequence numbers of the base run, ours and the peer's, and of the second run,
%% where each space crosses 2^32 within the first three bytes after the SYN.
-define(ISS, 1000).
-define(PEER_ISS, 5000).
-define(WRAP_ISS, (16#100000000 - 3)).
%% A data segment of the alphabet carries two bytes; the peer offers a window of four, both
%% buffers hold eight and a send hands over three, so the windows close within a few events.
-define(DATA, 2).
-define(PEER_WIN, 4).
-define(HIWAT, 8).
-define(SEND, <<"abc">>).
%% The peer's stream repeats with a prime period, longer than any window here, so that a
%% byte delivered twice or out of place differs from the one expected.
-define(PERIOD, 251).
%% tcp_subr.c: tcp_ack_war_cnt, the challenge ACKs a connection sends in one window.
-define(ACK_WAR_CNT, 5).
-define(FLAG_NAMES, [{?TH_SYN, syn}, {?TH_ACK, ack}, {?TH_FIN, fin}, {?TH_RST, rst}]).

-record(peer, {
    iss :: integer(),                   % where the alphabet's SYN-SENT positions are measured
    %% The connection's initial receive sequence number, once it has taken a SYN: the
    %% delivered bytes are the stream from irs + 1 on.
    irs = none :: none | integer(),
    sent_end = none :: none | integer(), % past the last data byte of any segment sent
    delivered = 0 :: non_neg_integer(),  % bytes delivered so far
    %% The furthest right edge, ack + window, of the windows offered by a segment whose ACK
    %% the connection could take (at most snd_max), or of a SYN's.
    right_edge = none :: none | integer(),
    %% The answers to RST segments received at one instant of the explorer's clock, which
    %% all fall in one window of the challenge-ACK limit whatever its alignment.
    challenged = {none, 0} :: {none | integer(), non_neg_integer()}}).

-record(node, {tcb :: #tcb{}, peer :: #peer{}, now :: integer(), trace = [] :: [term()]}).

-doc """
`{ok, Stats}` when every transition kept every property: the abstract states seen, the
transitions taken, the levels explored, and whether the exploration ended because no new
abstract state appeared (`complete`) rather than at the depth limit. Otherwise the first
property to fail, the trace of events that reaches it, and what was seen.
""".
-type result() :: {ok, #{states := pos_integer(), transitions := pos_integer(),
                         depth := non_neg_integer(), complete := boolean()}}
                | {violation, Property :: atom(), Trace :: [term()], Detail :: term()}.

-doc """
Explores from a connection that has just sent its SYN, to `depth` events after `connect`;
`wrap => true` starts both sequence spaces just below 2^32 (see the module documentation).
""".
-spec explore(#{depth := pos_integer(), wrap => boolean()}) -> result().
explore(#{depth := Depth} = Opts) when is_integer(Depth), Depth > 0 ->
    {Iss, PeerIss} = case maps:get(wrap, Opts, false) of
                         false -> {?ISS, ?PEER_ISS};
                         true -> {?WRAP_ISS, ?WRAP_ISS}
                     end,
    Closed = #node{tcb = new(Iss), peer = #peer{iss = PeerIss}, now = ?T0},
    case transition(Closed, connect, {user, {connect, from()}}) of
        {ok, Start} ->
            level([Start], #{abstraction(Start#node.tcb) => true}, 1, Depth, 1);
        Violation ->
            Violation
    end.

-doc "The properties every transition is checked against, by the names a violation carries.".
-spec properties() -> [atom()].
properties() ->
    [step_never_raises | [Name || {Name, _} <- checks()]].

-doc """
The abstraction states are merged by: the TCP state and whether the connection has ended;
the FIN state; which of the send variables (`snd_una`, `snd_nxt`, `snd_max`, `snd_recover`,
`snd_wl2` and the end of the send buffer) and of the receive variables (`rcv_nxt`,
`rcv_adv`, `last_ack_sent`, `snd_wl1`) are equal; which deadlines are set; the recovery
state; which sides are closed; and whether received bytes are buffered or held for
reassembly and a window has been offered, which the classes of the alphabet read.
""".
-spec abstraction(#tcb{}) -> term().
abstraction(#tcb{snd_una = Una, rcv_nxt = RcvNxt, deadlines = Deadlines,
                 ccv = #ccv{fast_recovery = Fast, cong_recovery = Cong}} = Tcb) ->
    BufEnd = Una + erx_tcp_sndbuf:size(Tcb#tcb.sndbuf),
    {Tcb#tcb.state, Tcb#tcb.ended,
     case Tcb#tcb.fin of {sent, _} -> sent; Fin -> Fin end, Tcb#tcb.need_syn,
     equalities([Una, Tcb#tcb.snd_nxt, Tcb#tcb.snd_max, Tcb#tcb.snd_recover, Tcb#tcb.snd_wl2,
                 BufEnd]),
     equalities([RcvNxt, Tcb#tcb.rcv_adv, Tcb#tcb.last_ack_sent, Tcb#tcb.snd_wl1]),
     {case Tcb#tcb.send_timer of none -> none; {Kind, _} -> Kind end,
      Deadlines#deadlines.delack =/= infinity, Deadlines#deadlines.keep =/= infinity,
      Deadlines#deadlines.msl2 =/= infinity},
     {Fast, Cong},
     {Tcb#tcb.user_closed, Tcb#tcb.snd_closed, Tcb#tcb.rcv_closed},
     {Tcb#tcb.rcv_buffered > 0, erx_tcp_reass:is_empty(Tcb#tcb.reass), Tcb#tcb.max_sndwnd > 0}}.

%% Whether each pair of the values is equal, in a fixed order of pairs.
equalities(Values) ->
    [A =:= B || {I, A} <- lists:enumerate(Values), {J, B} <- lists:enumerate(Values), I < J].

%% --- the search ------------------------------------------------------------------------

%% One level of the breadth-first search: Frontier holds the nodes reached in Depth - 1
%% events after connect whose abstraction was new.
level([], Seen, Depth, _, Transitions) ->
    {ok, stats(Seen, Depth - 1, Transitions, true)};
level(_, Seen, Depth, Max, Transitions) when Depth > Max ->
    {ok, stats(Seen, Max, Transitions, false)};
level(Frontier, Seen0, Depth, Max, Transitions0) ->
    case expand(Frontier, Seen0, [], Transitions0) of
        {ok, Next, Seen, Transitions} -> level(lists:reverse(Next), Seen, Depth + 1, Max, Transitions);
        Violation -> Violation
    end.

stats(Seen, Depth, Transitions, Complete) ->
    #{states => map_size(Seen), transitions => Transitions, depth => Depth, complete => Complete}.

%% The nodes of one level, in order, each with every event of the alphabet in order.
expand([], Seen, Next, Transitions) ->
    {ok, Next, Seen, Transitions};
expand([#node{tcb = #tcb{ended = true}} | Rest], Seen, Next, Transitions) ->
    expand(Rest, Seen, Next, Transitions);
expand([Node | Rest], Seen, Next, Transitions) ->
    case apply_events(alphabet(Node), Node, Seen, Next, Transitions) of
        {ok, Seen1, Next1, Transitions1} -> expand(Rest, Seen1, Next1, Transitions1);
        Violation -> Violation
    end.

%% Each event from Node; a node whose key (key/1) is new joins the next level.
apply_events([], _, Seen, Next, Transitions) ->
    {ok, Seen, Next, Transitions};
apply_events([{Label, Input} | Rest], Node, Seen, Next, Transitions) ->
    case transition(Node, Label, Input) of
        {ok, Reached} ->
            Key = key(Reached),
            case Seen of
                #{Key := _} -> apply_events(Rest, Node, Seen, Next, Transitions + 1);
                _ -> apply_events(Rest, Node, Seen#{Key => true}, [Reached | Next], Transitions + 1)
            end;
        Violation ->
            Violation
    end.

%% What nodes are merged by: the control block's abstraction and the peer model's count of
%% answers to RSTs at this instant, so that a run of challenges is followed until the
%% limit stops it.
key(#node{tcb = Tcb, peer = #peer{challenged = {_, Count}}}) ->
    {abstraction(Tcb), min(Count, ?ACK_WAR_CNT + 1)}.

%% One event from Node: the step, the checks on what it did, and the node it reaches.
transition(#node{tcb = Pre, peer = Peer0, now = Now0, trace = Trace} = Node, Label, Input) ->
    {Event, Now} = event(Input, Now0),
    Ctx = ctx(Now),
    Path = lists:reverse([Label | Trace]),
    try erx_tcp:step(Event, Pre, Ctx) of
        {Post, Actions} ->
            Sent = peer_sent(Input, Pre, Post, Actions, Now, Peer0),
            T = #{pre => Pre, post => Post, actions => Actions, input => Input, ctx => Ctx,
                  peer => Sent},
            case check(checks(), T) of
                ok ->
                    Peer = Sent#peer{delivered = Sent#peer.delivered + byte_size(delivered(Actions))},
                    {ok, Node#node{tcb = Post, peer = Peer, now = Now, trace = [Label | Trace]}};
                {Property, Detail} ->
                    {violation, Property, Path, Detail}
            end
    catch
        Class:Reason:Stack ->
            {violation, step_never_raises, Path, {Class, Reason, lists:sublist(Stack, 3)}}
    end.

check([], _) ->
    ok;
check([{Name, Check} | Rest], T) ->
    %% A property that raises (a fault in it, or in the pipeline header_prediction_agrees
    %% runs) fails under its own name.
    try Check(T) of
        ok -> check(Rest, T);
        {fail, Detail} -> {Name, Detail}
    catch
        Class:Reason:Stack -> {Name, {raised, Class, Reason, lists:sublist(Stack, 3)}}
    end.

%% --- the alphabet ----------------------------------------------------------------------

%% Every event of the base alphabet in Node's state, each concrete event once, under the
%% first label that produced it.
alphabet(#node{tcb = Tcb, peer = Peer}) ->
    Entries = segments(Tcb, Peer) ++ requests(Tcb) ++ expirations(Tcb),
    {Unique, _} = lists:foldl(fun({_, Input} = Entry, {Kept, Seen}) ->
                                      case Seen of
                                          #{Input := _} -> {Kept, Seen};
                                          _ -> {[Entry | Kept], Seen#{Input => true}}
                                      end
                              end, {[], #{}}, Entries),
    lists:reverse(Unique).

segments(Tcb, Peer) ->
    {Base, Window} = receive_frame(Tcb, Peer),
    Positions = positions(Base, Window),
    Acks = acks(Tcb),
    [{{seg, [Name || {Bit, Name} <- ?FLAG_NAMES, Flags band Bit =/= 0], Carries, Position, AckClass},
      {segment, Seq, Ack, Flags, payload(Carries, Seq, Flags)}}
     || Flags <- flag_sets(), Carries <- [nodata, data], {Position, Seq} <- Positions,
        {AckClass, Ack} <- case Flags band ?TH_ACK of
                               0 -> [{none, Tcb#tcb.snd_una}];
                               _ -> Acks
                           end].

flag_sets() ->
    [lists:foldl(fun erlang:'bor'/2, 0, Bits)
     || Bits <- subsets([Bit || {Bit, _} <- ?FLAG_NAMES])].

subsets([]) -> [[]];
subsets([X | Xs]) -> [S || S0 <- subsets(Xs), S <- [S0, [X | S0]]].

%% Where the position classes are measured: rcv_nxt and the receive window the step will
%% use (erx_tcp_input's rcv_wnd), or before any SYN is taken, the peer's ISS and a full
%% buffer's worth.
receive_frame(#tcb{state = syn_sent}, #peer{iss = PeerIss}) ->
    {PeerIss, ?HIWAT};
receive_frame(#tcb{rcv_nxt = RcvNxt, rcv_adv = RcvAdv} = Tcb, _) ->
    {RcvNxt, max(erx_tcp:rcv_space(Tcb), RcvAdv - RcvNxt)}.

%% The sequence position classes: a segment wholly below the window, one starting a byte
%% before it (the peer's SYN again in SYN-RECEIVED, a keepalive probe), at its left edge, one
%% byte inside, at its last byte (so data straddles the edge) and just past it.
positions(Base, Window) ->
    [{below, Base - ?DATA}, {just_below, Base - 1}, {at, Base}]
        ++ [{inside, Base + 1} || Window >= 3]
        ++ [{edge, Base + Window - 1} || Window >= 2]
        ++ [{beyond, Base + Window}].

%% The acknowledgement classes (RFC 5961 section 5.2 for the first two).
acks(#tcb{snd_una = Una, snd_max = SndMax, max_sndwnd = MaxSndWnd}) ->
    [{too_old, Una - MaxSndWnd - 1}]
        ++ [{old, Una - 1} || MaxSndWnd >= 1]
        ++ [{at_una, Una}]
        ++ [{in_flight, Una + 1} || SndMax - Una >= 2]
        ++ [{at_max, SndMax} || SndMax > Una]
        ++ [{beyond, SndMax + 1}].

payload(nodata, _, _) -> <<>>;
payload(data, Seq, Flags) -> stream(Seq + syn_len(Flags), ?DATA).

requests(#tcb{rcv_buffered = Buffered}) ->
    [{send, {user, {send, from(), ?SEND}}}]
        ++ [{recv, {user, {rcvd, Buffered}}} || Buffered > 0]
        ++ [{close, {user, close}}, {shutdown, {user, {shutdown, from(), write}}},
            {abort, {user, abort}}].

expirations(Tcb) ->
    case erx_tcp:next_deadline(Tcb) of
        infinity -> [];
        Deadline -> [{expire, {expired, Deadline}}]
    end.

%% The step's event for an input, and the clock it runs at: an expiry moves it to the
%% deadline, everything else happens at the current time.
event({segment, Seq, Ack, Flags, Data}, Now) ->
    {{segments, [wire_segment(Seq, Ack, Flags, Data)]}, Now};
event({expired, Deadline}, Now) ->
    {{expired, Deadline}, max(Now, Deadline)};
event({user, _} = Request, Now) ->
    {Request, Now}.

wire_segment(Seq, Ack, Flags, Data) ->
    {#tcp{sport = 80, dport = 4000, seq = erx_tcp_seq:wire(Seq), ack = erx_tcp_seq:wire(Ack),
          flags = Flags, win = ?PEER_WIN, urp = 0}, Data, 0, unicast}.

%% The peer's byte at each wire sequence number from Seq on.
stream(Seq, Bytes) ->
    << <<(erx_tcp_seq:wire(S) rem ?PERIOD)>> || S <- lists:seq(Seq, Seq + Bytes - 1) >>.

%% --- the peer model --------------------------------------------------------------------

%% The peer once Input is a segment: the end of the data it has sent, the windows it has
%% offered and the answers its RSTs drew; and the connection's irs once it has taken a SYN.
peer_sent(Input, Pre, Post, Actions, Now, Peer0) ->
    Peer1 = case Input of
                {segment, Seq, Ack, Flags, Data} ->
                    challenged(Flags, Actions, Now, sends(Seq, Ack, Flags, Data, Pre, Peer0));
                _ ->
                    Peer0
            end,
    case Peer1 of
        #peer{irs = none} ->
            case erx_tcp:have_rcvd_syn(Post#tcb.state) of
                true -> Peer1#peer{irs = Post#tcb.irs};
                false -> Peer1
            end;
        _ ->
            Peer1
    end.

%% In SYN-SENT the connection takes the SYN's wire number as it is (erx_tcp_input's lift),
%% so the data's end is measured on the wire there too.
sends(Seq0, Ack, Flags, Data, #tcb{state = State, snd_una = Una, snd_max = SndMax}, Peer) ->
    Seq = case State of
              syn_sent -> erx_tcp_seq:wire(Seq0);
              _ -> Seq0
          end,
    SentEnd = case Data of
                  <<>> -> Peer#peer.sent_end;
                  _ -> max_known(Peer#peer.sent_end, Seq + syn_len(Flags) + byte_size(Data))
              end,
    Edge = case {Flags band ?TH_ACK =/= 0, Flags band ?TH_SYN =/= 0} of
               {true, _} when Ack =< SndMax -> max_known(Peer#peer.right_edge, Ack + ?PEER_WIN);
               {false, true} -> max_known(Peer#peer.right_edge, Una + ?PEER_WIN);
               _ -> Peer#peer.right_edge
           end,
    Peer#peer{sent_end = SentEnd, right_edge = Edge}.

%% A RST draws nothing but a challenge ACK, so every segment sent in answer to one counts.
challenged(Flags, Actions, Now, #peer{challenged = Challenged} = Peer)
  when Flags band ?TH_RST =/= 0 ->
    Answers = length([S || {transmit, Segments} <- Actions, S <- Segments]),
    Count = case Challenged of
                {Now, Before} -> Before + Answers;
                _ -> Answers
            end,
    Peer#peer{challenged = {Now, Count}};
challenged(_, _, _, Peer) ->
    Peer.

max_known(none, Value) -> Value;
max_known(Known, Value) -> max(Known, Value).

%% --- the properties --------------------------------------------------------------------

checks() ->
    [{send_sequence_ordered, fun send_sequence_ordered/1},
     {rcv_nxt_never_decreases, fun rcv_nxt_never_decreases/1},
     {delivered_in_order, fun delivered_in_order/1},
     {delivered_only_what_was_sent, fun delivered_only_what_was_sent/1},
     {sent_within_peer_window, fun sent_within_peer_window/1},
     {rst_only_at_last_ack_sent, fun rst_only_at_last_ack_sent/1},
     {challenge_acks_within_limit, fun challenge_acks_within_limit/1},
     {old_ack_keeps_send_window, fun old_ack_keeps_send_window/1},
     {state_change_allowed, fun state_change_allowed/1},
     {header_prediction_agrees, fun header_prediction_agrees/1}].

send_sequence_ordered(#{post := #tcb{snd_una = Una, snd_nxt = Nxt, snd_max = Max}}) ->
    holds(Una =< Nxt andalso Nxt =< Max, {Una, Nxt, Max}).

rcv_nxt_never_decreases(#{pre := #tcb{rcv_nxt = Before}, post := #tcb{rcv_nxt = After}}) ->
    holds(After >= Before, {Before, After}).

%% The bytes delivered continue the peer's stream from irs + 1 where the last left off.
delivered_in_order(#{actions := Actions, peer := #peer{irs = Irs, delivered = Delivered}}) ->
    case delivered(Actions) of
        <<>> -> ok;
        _ when Irs =:= none -> {fail, {delivered_before_a_syn, delivered(Actions)}};
        Bytes ->
            Expected = stream(Irs + 1 + Delivered, byte_size(Bytes)),
            holds(Bytes =:= Expected, {Delivered, Bytes, Expected})
    end.

delivered_only_what_was_sent(#{actions := Actions,
                               peer := #peer{irs = Irs, delivered = Delivered, sent_end = End}}) ->
    case byte_size(delivered(Actions)) of
        0 -> ok;
        Bytes -> holds(is_integer(Irs) andalso is_integer(End)
                       andalso Irs + 1 + Delivered + Bytes =< End,
                       {Irs, Delivered, Bytes, End})
    end.

%% Every data segment sent ends within the right edge the peer offered, but for a window
%% probe of one byte.
sent_within_peer_window(#{actions := Actions, post := #tcb{snd_una = Una},
                          peer := #peer{right_edge = Edge}}) ->
    Over = [{Start, Bytes}
            || {transmit, Segments} <- Actions, {#tcp{seq = Seq, flags = Flags}, _, Payload} <- Segments,
               Bytes <- [iolist_size(Payload)], Bytes > 1,
               Start <- [erx_tcp_seq:lift(Seq, Una) + syn_len(Flags)],
               Edge =:= none orelse Start + Bytes > Edge],
    holds(Over =:= [], {Edge, Over}).

%% In a synchronized state (and SYN-RECEIVED) a RST ends the connection only at exactly
%% last_ack_sent (RFC 5961 section 3); SYN-SENT has its own rule and TIME-WAIT ignores RSTs.
rst_only_at_last_ack_sent(#{input := {segment, Seq, _, Flags, _},
                            pre := #tcb{state = State, ended = false, last_ack_sent = LastAck},
                            post := #tcb{ended = Ended}})
  when Flags band ?TH_RST =/= 0, State =/= syn_sent, State =/= time_wait ->
    holds(not Ended orelse Seq =:= LastAck, {State, Seq, LastAck});
rst_only_at_last_ack_sent(_) ->
    ok.

%% The RSTs received at one instant, which all fall in one window of the limit, draw at most
%% tcp_ack_war_cnt challenge ACKs, counted by the peer as it receives them.
challenge_acks_within_limit(#{peer := #peer{challenged = {_, Count}}}) ->
    holds(Count =< ?ACK_WAR_CNT, Count).

%% A segment older than the last window update by the SND.WL1/SND.WL2 rule (RFC 9293
%% section 3.10.7.4) takes no window: SND.WL1 and SND.WL2 stay, and the window does not grow
%% (it shrinks by what the ACK takes, as tcp_input.c's `snd_wnd -= acked` keeps the right
%% edge). Its sequence number is the one the window update sees: past what trimming drops
%% below rcv_nxt.
old_ack_keeps_send_window(#{input := {segment, Seq, Ack, Flags, Data},
                            pre := #tcb{state = State, ended = false} = Pre, post := Post})
  when Flags band ?TH_ACK =/= 0, State =/= syn_sent, State =/= syn_received,
       State =/= time_wait ->
    Seen = Seq + min(max(Pre#tcb.rcv_nxt - Seq, 0), byte_size(Data)),
    Window = fun(#tcb{snd_wnd = Wnd, snd_wl1 = Wl1, snd_wl2 = Wl2}) -> {Wnd, Wl1, Wl2} end,
    Old = {Seen, Ack} < {Pre#tcb.snd_wl1, Pre#tcb.snd_wl2},
    Kept = {Pre#tcb.snd_wl1, Pre#tcb.snd_wl2} =:= {Post#tcb.snd_wl1, Post#tcb.snd_wl2}
        andalso Post#tcb.snd_wnd =< Pre#tcb.snd_wnd,
    holds(not Old orelse Kept, {{Seen, Ack}, Window(Pre), Window(Post)});
old_ack_keeps_send_window(_) ->
    ok.

%% The state after the step is one RFC 9293's diagram reaches from the state before it.
state_change_allowed(#{input := Input, pre := #tcb{state = From},
                       post := #tcb{state = To0, ended = Ended}}) ->
    To = case Ended of
             true -> closed;
             false -> To0
         end,
    holds(allowed(element(1, Input), From, To), {From, To}).

%% Where header prediction takes a segment, the general stages give the same control block
%% and actions; where it declines, both runs are the same pipeline.
header_prediction_agrees(#{input := {segment, Seq, Ack, Flags, Data} = Input,
                           pre := #tcb{state = State, ended = false} = Pre, ctx := Ctx})
  when State =/= closed, State =/= time_wait ->
    Segment = wire_segment(Seq, Ack, Flags, Data),
    Stages = erx_tcp_input:stages(),
    Fast = erx_tcp_input:run(Stages, Segment, Pre, Ctx),
    Slow = erx_tcp_input:run(lists:keydelete(header_prediction, 1, Stages), Segment, Pre, Ctx),
    holds(Fast =:= Slow, {Input, differing_fields(element(1, Fast), element(1, Slow))});
header_prediction_agrees(_) ->
    ok.

differing_fields(A, B) ->
    [Field || {Field, X, Y} <- lists:zip3(record_info(fields, tcb), tl(tuple_to_list(A)),
                                           tl(tuple_to_list(B))),
              X =/= Y].

holds(true, _) -> ok;
holds(false, Detail) -> {fail, Detail}.

%% RFC 9293's state diagram (section 3.3.2) as one step of each kind of input can take it:
%% an owner's request moves along one of its edges; a segment takes at most one edge on its
%% acknowledgement and then at most one on its FIN; an expiry only ends the connection; and
%% anything may end it (an abort, a RST, a timeout, the last ACK, the end of TIME-WAIT).
%% FreeBSD keeps a close in SYN-RECEIVED as a FIN owed (TF_NEEDFIN, tcp_usrclosed), so a
%% close leaves that state as it is and the ACK of the SYN leads to FIN-WAIT-1.
allowed(_, State, State) -> true;
allowed(_, _, closed) -> true;
allowed(user, From, To) ->
    lists:member(To, user_edges(From));
allowed(segment, From, To) ->
    AfterAck = [From | ack_edges(From)],
    lists:member(To, AfterAck ++ lists:flatmap(fun fin_edges/1, AfterAck));
allowed(expired, _, _) ->
    false.

user_edges(closed) -> [syn_sent];
user_edges(established) -> [fin_wait_1];
user_edges(close_wait) -> [last_ack];
user_edges(_) -> [].

ack_edges(syn_sent) -> [syn_received, established, fin_wait_1];
ack_edges(syn_received) -> [established, fin_wait_1];
ack_edges(fin_wait_1) -> [fin_wait_2];
ack_edges(closing) -> [time_wait];
ack_edges(_) -> [].

fin_edges(syn_received) -> [close_wait];
fin_edges(established) -> [close_wait];
fin_edges(fin_wait_1) -> [closing];
fin_edges(fin_wait_2) -> [time_wait];
fin_edges(_) -> [].

%% --- the connection --------------------------------------------------------------------

new(Iss) ->
    erx_tcp_user:new(#{family => inet, local => {<<10, 0, 0, 1>>, 4000},
                       remote => {<<10, 0, 0, 2>>, 80}, iss => Iss, ts_offset => 7,
                       cc => erx_tcp_cc_newreno, loss => erx_tcp_loss_dupack,
                       snd_hiwat => ?HIWAT, rcv_hiwat => ?HIWAT,
                       gen => erx_net_rand:new(<<0:128>>), now => ?T0}).

ctx(Now) -> #tcp_ctx{now = Now, credit = 64, mtu = 1500}.

%% The caller of a connect, send or shutdown; the step only hands it back in replies.
from() -> {self(), explore}.

delivered(Actions) -> iolist_to_binary([Bytes || {deliver, Bytes} <- Actions]).

syn_len(Flags) when Flags band ?TH_SYN =/= 0 -> 1;
syn_len(_) -> 0.
