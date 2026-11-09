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

A dimension (`dimensions/0`) is one of the design's extra explorations: the base alphabet
plus the variants of its segments that the dimension makes (an option, a window, a flag,
the IP header's ECN field) and any events of its own, run on the connection the dimension
asks for, with the abstraction widened by the state the dimension reads and its own
properties added (`dimension/1`).

The peer model is what the checks measure the connection against without reading its
reasoning: the peer's byte stream is a fixed function of the wire sequence number
(`stream/2`), so any segment's payload is the stream at its position and the bytes
delivered must be the stream from the initial receive sequence number on, less the urgent
bytes the peer pointed at; the model keeps the end of what the peer has sent and the right
edge of the windows it has offered.

`explore/1` with `wrap => true` runs the same exploration with both initial sequence
numbers, and the peer's first timestamp, just below 2^32, so that every position class
also crosses the wire's wrap.
""".

-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").
-include("erx_icmp4_wire.hrl").

-export([explore/1, properties/0, abstraction/1, dimensions/0]).

-export_type([result/0]).

-define(T0, 1000000000).
%% The initial sequence numbers of the base run, ours and the peer's, and of the second run,
%% where each space crosses 2^32 within the first three bytes after the SYN.
-define(ISS, 1000).
-define(PEER_ISS, 5000).
-define(WRAP_ISS, (16#100000000 - 3)).
%% The peer's first TSval, and in the second run one that wraps after two more.
-define(PEER_TS, 100).
-define(WRAP_TS, (16#100000000 - 2)).
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
%% tcp_subr.c: V_tcp_minmss, the least MSS a peer's option sets.
-define(TCP_MINMSS, 216).
%% The MTU a fragmentation-needed report proposes: below the path's, so it lowers the MSS.
-define(REPORT_MTU, 296).
-define(FLAG_NAMES, [{?TH_SYN, syn}, {?TH_ACK, ack}, {?TH_FIN, fin}, {?TH_RST, rst}]).

%% A segment the peer sends, before wire_segment/1 encodes it. Seq and ack are unwrapped
%% integers in the connection's spaces (in SYN-SENT, seq is the wire value the SYN names).
-record(in, {seq :: integer(),
             ack :: integer(),
             flags :: 0..16#fff,
             data :: binary(),
             win = ?PEER_WIN :: 0..16#ffff,
             urp = 0 :: 0..16#ffff,
             opts = #tcp_opts{} :: #tcp_opts{},
             ip_ecn = 0 :: 0..3}).

-record(peer, {
    iss :: integer(),                   % where the alphabet's SYN-SENT positions are measured
    ts :: erx_tcp_seq:wire(),           % the TSval of the peer's SYN
    %% The connection's initial receive sequence number, once it has taken a SYN: the
    %% delivered bytes are the stream from irs + 1 on.
    irs = none :: none | integer(),
    sent_end = none :: none | integer(), % past the last data byte of any segment sent
    next = none :: none | integer(),     % the stream position the next delivered byte is at
    %% The positions of the bytes the peer's urgent pointers named, which the connection may
    %% keep out of the stream (tcp_pulloutofband).
    urgent = [] :: ordsets:ordset(integer()),
    %% CWR as a debt: a window reduction owes one CWR and the first CWR sent pays it, as
    %% FreeBSD clears TF2_ECN_SND_CWR once it sends one. A reduction is what the peer can
    %% see of one (cc_cong_signal's CC_ECN, CC_RTO, CC_NDUPACK): ECE it sent on a segment
    %% without SYN, or a segment of ours it received again. `unowed` records a CWR sent
    %% with nothing owed.
    cwr = owed_none :: owed_none | owed | unowed,
    acked = none :: none | integer(),    % the furthest ACK sent that the connection could take
    ours_end = none :: none | integer(), % past the furthest sequence number of ours received
    %% The furthest right edge, ack + window, of the windows offered by a segment whose ACK
    %% the connection could take (at most snd_max), or of a SYN's.
    right_edge = none :: none | integer(),
    %% The answers to RST segments received at one instant of the explorer's clock, which
    %% all fall in one window of the challenge-ACK limit whatever its alignment.
    challenged = {none, 0} :: {none | integer(), non_neg_integer()}}).

-record(node, {tcb :: #tcb{}, peer :: #peer{}, now :: integer(), trace = [] :: [term()],
               dim :: dimension()}).

-doc """
`{ok, Stats}` when every transition kept every property: the abstract states seen, the
transitions taken, the levels explored, whether the exploration ended because no new
abstract state appeared (`complete`) rather than at the depth limit, and for each property
the transitions on which it judged its non-trivial case (`hits`, see `check/2`). Otherwise
the first property to fail, the trace of events that reaches it, and what was seen.
""".
-type result() :: {ok, #{states := pos_integer(), transitions := pos_integer(),
                         depth := non_neg_integer(), complete := boolean(),
                         hits := #{atom() => pos_integer()}}}
                | {violation, Property :: atom(), Trace :: [term()], Detail :: term()}.

%% What a dimension adds to the base exploration (see dimension/1).
-type dimension() :: #{variants := fun((#in{}, #node{}) -> [{atom(), #in{}}]),
                       events := fun((#node{}) -> [{term(), term()}]),
                       connection := #{snd_hiwat => pos_integer(), send => binary()},
                       abstraction := fun((#tcb{}) -> term()),
                       checks := [{atom(), fun((map()) -> ok | hit | {fail, term()})}]}.

-doc """
Explores from a connection that has just sent its SYN, to `depth` events after `connect`;
`wrap => true` starts both sequence spaces just below 2^32, and `dimension` adds one of
`dimensions/0` to the base alphabet (see the module documentation).
""".
-spec explore(#{depth := pos_integer(), wrap => boolean(), dimension => base | atom()}) ->
    result().
explore(#{depth := Depth} = Opts) when is_integer(Depth), Depth > 0 ->
    {Iss, PeerIss, PeerTs} = case maps:get(wrap, Opts, false) of
                                 false -> {?ISS, ?PEER_ISS, ?PEER_TS};
                                 true -> {?WRAP_ISS, ?WRAP_ISS, ?WRAP_TS}
                             end,
    #{connection := Conn} = Dim = dimension(maps:get(dimension, Opts, base)),
    Closed = #node{tcb = new(Iss, Conn), peer = #peer{iss = PeerIss, ts = PeerTs}, now = ?T0,
                   dim = Dim},
    case transition(Closed, connect, {user, {connect, from()}}) of
        {ok, Start, Hits} ->
            level([Start], #{key(Start) => true}, 1, Depth, {1, count_hits(Hits, #{})});
        Violation ->
            Violation
    end.

-doc "The extra dimensions of the design, each explored on its own with `dimension => Name`.".
-spec dimensions() -> [atom()].
dimensions() ->
    [timestamps, ecn, urgent, sack, window, icmp].

-doc """
The properties every transition is checked against, by the names a violation carries: the
base exploration's, then those the dimensions add.
""".
-spec properties() -> [atom()].
properties() ->
    Names = [step_never_raises | [Name || {Name, _} <- checks()]]
        ++ [Name || D <- dimensions(), {Name, _} <- maps:get(checks, dimension(D))],
    lists:uniq(Names).

-doc """
The abstraction states are merged by: the TCP state and whether the connection has ended;
the FIN state; which of the send variables (`snd_una`, `snd_nxt`, `snd_max`, `snd_recover`,
`snd_wl2` and the end of the send buffer) and of the receive variables (`rcv_nxt`,
`rcv_adv`, `last_ack_sent`, `snd_wl1`) are equal; which deadlines are set; the recovery
state; which sides are closed; and whether received bytes are buffered or held for
reassembly and a window has been offered, which the classes of the alphabet read. A
dimension widens it by its own fields.
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
%% events after connect whose key was new. Counts is the transitions taken and the hits.
level([], Seen, Depth, _, Counts) ->
    {ok, stats(Seen, Depth - 1, Counts, true)};
level(_, Seen, Depth, Max, Counts) when Depth > Max ->
    {ok, stats(Seen, Max, Counts, false)};
level(Frontier, Seen0, Depth, Max, Counts0) ->
    case expand(Frontier, Seen0, [], Counts0) of
        {ok, Next, Seen, Counts} -> level(lists:reverse(Next), Seen, Depth + 1, Max, Counts);
        Violation -> Violation
    end.

stats(Seen, Depth, {Transitions, Hits}, Complete) ->
    #{states => map_size(Seen), transitions => Transitions, depth => Depth,
      complete => Complete, hits => Hits}.

%% The nodes of one level, in order, each with every event of the alphabet in order.
expand([], Seen, Next, Counts) ->
    {ok, Next, Seen, Counts};
expand([#node{tcb = #tcb{ended = true}} | Rest], Seen, Next, Counts) ->
    expand(Rest, Seen, Next, Counts);
expand([Node | Rest], Seen, Next, Counts) ->
    case apply_events(alphabet(Node), Node, Seen, Next, Counts) of
        {ok, Seen1, Next1, Counts1} -> expand(Rest, Seen1, Next1, Counts1);
        Violation -> Violation
    end.

%% Each event from Node; a node whose key (key/1) is new joins the next level.
apply_events([], _, Seen, Next, Counts) ->
    {ok, Seen, Next, Counts};
apply_events([{Label, Input} | Rest], Node, Seen, Next, {Transitions, Hits0}) ->
    case transition(Node, Label, Input) of
        {ok, Reached, Hit} ->
            Counts = {Transitions + 1, count_hits(Hit, Hits0)},
            Key = key(Reached),
            case Seen of
                #{Key := _} -> apply_events(Rest, Node, Seen, Next, Counts);
                _ -> apply_events(Rest, Node, Seen#{Key => true}, [Reached | Next], Counts)
            end;
        Violation ->
            Violation
    end.

count_hits(Names, Hits) ->
    lists:foldl(fun(Name, Acc) -> maps:update_with(Name, fun(N) -> N + 1 end, 1, Acc) end,
                Hits, Names).

%% What nodes are merged by: the control block's abstraction, widened by the dimension's,
%% the peer model's count of answers to RSTs at this instant, so that a run of challenges
%% is followed until the limit stops it, and whether it is owed a CWR.
key(#node{tcb = Tcb, peer = #peer{challenged = {_, Count}, cwr = Cwr},
          dim = #{abstraction := Abs}}) ->
    {abstraction(Tcb), Abs(Tcb), min(Count, ?ACK_WAR_CNT + 1), Cwr}.

%% One event from Node: the step, the checks on what it did, and the node it reaches with
%% the properties that judged their non-trivial case on it.
transition(#node{tcb = Pre, peer = Peer0, now = Now0, trace = Trace, dim = Dim} = Node,
           Label, Input) ->
    {Event, Now} = event(Input, Now0),
    Ctx = ctx(Now),
    Path = lists:reverse([Label | Trace]),
    try erx_tcp:step(Event, Pre, Ctx) of
        {Post, Actions} ->
            Sent = peer_sent(Input, Pre, Post, Actions, Now, Peer0),
            T = #{pre => Pre, post => Post, actions => Actions, input => Input, ctx => Ctx,
                  peer => Sent},
            case check(checks() ++ maps:get(checks, Dim), T, []) of
                {ok, Hits} ->
                    Peer = Sent#peer{next = delivered_to(Actions, Sent)},
                    {ok, Node#node{tcb = Post, peer = Peer, now = Now, trace = [Label | Trace]},
                     Hits};
                {Property, Detail} ->
                    {violation, Property, Path, Detail}
            end
    catch
        Class:Reason:Stack ->
            {violation, step_never_raises, Path, {Class, Reason, lists:sublist(Stack, 3)}}
    end.

%% A check returns `ok`, `hit` when the transition reached the case the property exists
%% for (the fast path taken, a RST accepted, an old ACK judged; see each property), which
%% the stats count to show the property is not vacuous, or `{fail, Detail}`.
check([], _, Hits) ->
    {ok, Hits};
check([{Name, Check} | Rest], T, Hits) ->
    %% A property that raises (a fault in it, or in the pipeline header_prediction_agrees
    %% runs) fails under its own name.
    try Check(T) of
        ok -> check(Rest, T, Hits);
        hit -> check(Rest, T, [Name | Hits]);
        {fail, Detail} -> {Name, Detail}
    catch
        Class:Reason:Stack -> {Name, {raised, Class, Reason, lists:sublist(Stack, 3)}}
    end.

%% --- the alphabet ----------------------------------------------------------------------

%% Every event of the alphabet in Node's state, each concrete event once, under the first
%% label that produced it.
alphabet(#node{tcb = Tcb, dim = #{events := Events, connection := Conn}} = Node) ->
    Entries = segments(Node) ++ requests(Tcb, Conn) ++ expirations(Tcb) ++ Events(Node),
    {Unique, _} = lists:foldl(fun({_, Input} = Entry, {Kept, Seen}) ->
                                      case Seen of
                                          #{Input := _} -> {Kept, Seen};
                                          _ -> {[Entry | Kept], Seen#{Input => true}}
                                      end
                              end, {[], #{}}, Entries),
    lists:reverse(Unique).

%% The base segments, each followed by the dimension's variants of it, labelled with the
%% base label and the variant's name. A RST has none: it is judged, by its own sequence
%% check, before anything a dimension varies.
segments(#node{tcb = Tcb, peer = Peer, dim = #{variants := Variants}} = Node) ->
    {Base, Window} = receive_frame(Tcb, Peer),
    Positions = positions(Base, Window),
    Acks = acks(Tcb),
    [Entry
     || Flags <- flag_sets(), Carries <- [nodata, data], {Position, Seq} <- Positions,
        {AckClass, Ack} <- case Flags band ?TH_ACK of
                               0 -> [{none, Tcb#tcb.snd_una}];
                               _ -> Acks
                           end,
        Label <- [{seg, [Name || {Bit, Name} <- ?FLAG_NAMES, Flags band Bit =/= 0], Carries,
                   Position, AckClass}],
        In <- [#in{seq = Seq, ack = Ack, flags = Flags, data = payload(Carries, Seq, Flags)}],
        Entry <- [{Label, {segment, In}}
                  | [{{Label, Variant}, {segment, Varied}} || {Variant, Varied} <- variants(Variants, In, Node)]]].

variants(_, #in{flags = Flags}, _) when Flags band ?TH_RST =/= 0 -> [];
variants(Variants, In, Node) -> Variants(In, Node).

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

requests(#tcb{rcv_buffered = Buffered}, Conn) ->
    [{send, {user, {send, from(), maps:get(send, Conn, ?SEND)}}}]
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
event({segment, #in{} = In}, Now) ->
    {{segments, [wire_segment(In)]}, Now};
event({icmp, Kind, Seq}, Now) ->
    {{icmp, icmp_report(Kind, Seq)}, Now};
event({expired, Deadline}, Now) ->
    {{expired, Deadline}, max(Now, Deadline)};
event({user, _} = Request, Now) ->
    {Request, Now}.

%% The one place a segment of the peer's is encoded, as the interface hands it on.
wire_segment(#in{seq = Seq, ack = Ack, flags = Flags, data = Data, win = Win, urp = Urp,
                 opts = Opts, ip_ecn = IpEcn}) ->
    {#tcp{sport = 80, dport = 4000, seq = erx_tcp_seq:wire(Seq), ack = erx_tcp_seq:wire(Ack),
          flags = Flags, win = Win, urp = Urp, opts = Opts}, Data, IpEcn, unicast}.

%% An ICMPv4 error quoting the start of a segment of ours at Seq, as erx_net_input hands it
%% on: fragmentation needed proposing ?REPORT_MTU, or port unreachable. The connection is
%% IPv4, so ICMPv6's packet-too-big takes the same path through erx_tcp_icmp and is left out.
icmp_report(Kind, Seq) ->
    Icmp = case Kind of
               needfrag -> #icmp4{type = ?ICMP_UNREACH, code = 4, msg = {error, ?REPORT_MTU}};
               unreach -> #icmp4{type = ?ICMP_UNREACH, code = 3, msg = {error, 0}}
           end,
    {Icmp, #{proto => 6, len => 40, src => <<10, 0, 0, 1>>, dst => <<10, 0, 0, 2>>,
             upper => <<4000:16, 80:16, (erx_tcp_seq:wire(Seq)):32, 0:32>>}}.

%% The peer's byte at each wire sequence number from Seq on.
stream(Seq, Bytes) ->
    << <<(stream_byte(S))>> || S <- lists:seq(Seq, Seq + Bytes - 1) >>.

stream_byte(Seq) -> erx_tcp_seq:wire(Seq) rem ?PERIOD.

%% --- the dimensions --------------------------------------------------------------------

%% Each dimension as a value: `variants` of a base segment in the node's state, `events` of
%% its own, the `connection` it runs on (a send buffer and a send larger than the base's),
%% the `abstraction` fields it widens the key by, and its `checks`.
dimension(base) ->
    #{variants => fun(_, _) -> [] end, events => fun(_) -> [] end,
      connection => #{}, abstraction => fun(_) -> none end, checks => []};
%% A SYN with the timestamp option, so connections negotiate it or not; on any other
%% segment a TSval older than, equal to and newer than ts_recent (the peer's first before
%% any is recorded), so the `timestamps` stage and PAWS are reached in every state.
dimension(timestamps) ->
    Variants = fun(#in{flags = Flags, opts = Opts} = In, #node{tcb = Tcb, peer = Peer}) ->
                       case Flags band ?TH_SYN of
                           0 ->
                               Recent = case Tcb#tcb.ts of
                                            #ts{recent = R} -> R;
                                            _ -> Peer#peer.ts
                                        end,
                               [{Name, In#in{opts = Opts#tcp_opts{ts = {erx_tcp_seq:wire(Recent + D), 0}}}}
                                || {Name, D} <- [{ts_older, -1}, {ts_equal, 0}, {ts_newer, 1}]];
                           _ ->
                               [{ts, In#in{opts = Opts#tcp_opts{ts = {Peer#peer.ts, 0}}}}]
                       end
               end,
    Abs = fun(#tcb{ts = off}) -> off;
             (#tcb{ts = {requested, _}}) -> requested;
             (#tcb{ts = #ts{recent = Recent}}) -> {on, Recent =:= 0}
          end,
    (dimension(base))#{variants => Variants, abstraction => Abs,
                       checks => [{options_unnegotiated_ignored, fun options_unnegotiated_ignored/1}]};
%% ECE on a SYN-ACK, ECE and CWR on a SYN (mode 2 grants both, tcp_ecn_input_syn_sent and
%% tcp_ecn_input_parallel_syn), so connections negotiate ECN or not; on any other segment
%% ECE, CWR, or the CE mark in the IP header.
dimension(ecn) ->
    Variants = fun(#in{flags = Flags} = In, _) ->
                       case {Flags band ?TH_SYN =/= 0, Flags band ?TH_ACK =/= 0} of
                           {true, true} -> [{ece, In#in{flags = Flags bor ?TH_ECE}}];
                           {true, false} -> [{ece_cwr, In#in{flags = Flags bor ?TH_ECE bor ?TH_CWR}}];
                           {false, _} -> [{ece, In#in{flags = Flags bor ?TH_ECE}},
                                          {cwr, In#in{flags = Flags bor ?TH_CWR}},
                                          {ce, In#in{ip_ecn = 3}}]
                       end
               end,
    %% erx_tcp_ecn's state is opaque to its callers; as a key it is only compared.
    Abs = fun(#tcb{ecn = Ecn}) -> Ecn end,
    (dimension(base))#{variants => Variants, abstraction => Abs,
                       checks => [{cwr_only_after_reduction, fun cwr_only_after_reduction/1},
                                  {options_unnegotiated_ignored, fun options_unnegotiated_ignored/1}]};
%% URG on a segment with ACK, its pointer naming the segment's last byte, the byte past it,
%% and a byte past the receive window.
dimension(urgent) ->
    Variants = fun(#in{flags = Flags, seq = Seq} = In, #node{tcb = Tcb, peer = Peer})
                     when Flags band ?TH_ACK =/= 0, Flags band ?TH_SYN =:= 0 ->
                       {Base, Window} = receive_frame(Tcb, Peer),
                       Urgent = In#in{flags = Flags bor ?TH_URG},
                       [{urg_inside, Urgent#in{urp = ?DATA}},
                        {urg_beyond_segment, Urgent#in{urp = ?DATA + 1}},
                        {urg_beyond_window,
                         Urgent#in{urp = min(16#ffff, max(?DATA + 1, Base + Window + 1 - Seq))}}];
                  (_, _) ->
                       []
               end,
    Abs = fun(#tcb{rcv_up = Up, rcv_nxt = Nxt, rcv_oob = Oob}) -> {Up > Nxt, Oob =:= none} end,
    (dimension(base))#{variants => Variants, abstraction => Abs};
%% SACK permitted on a SYN, so connections negotiate it or not; on an acknowledgement a
%% block inside the flight, one beyond snd_max and one below snd_una (D-SACK); the base
%% alphabet's ACKs at snd_una are the duplicates without a block. The duplicates counted
%% join the key, so fast retransmit is reached.
dimension(sack) ->
    Variants = fun(#in{flags = Flags, opts = Opts} = In, #node{tcb = Tcb}) ->
                       case {Flags band ?TH_SYN =/= 0, Flags band ?TH_ACK =/= 0} of
                           {true, _} ->
                               [{sack_permitted, In#in{opts = Opts#tcp_opts{sack_permitted = true}}}];
                           {false, true} ->
                               #tcb{snd_una = Una, snd_max = SndMax} = Tcb,
                               Blocks = [{sack_in_flight, Una + 1, Una + 2} || SndMax - Una >= 2]
                                   ++ [{sack_beyond, SndMax + 1, SndMax + 3},
                                       {dsack, Una - 2, Una}],
                               [{Name, In#in{opts = Opts#tcp_opts{sacks = [{erx_tcp_seq:wire(S), erx_tcp_seq:wire(E)}]}}}
                                || {Name, S, E} <- Blocks];
                           {false, false} ->
                               []
                       end
               end,
    Abs = fun(#tcb{sack = Sack, sendlog = Log, loss = Loss, loss_state = State}) ->
                  Dupacks = case Loss of
                                erx_tcp_loss_dupack -> erx_tcp_loss_dupack:dupacks(State);
                                _ -> 0
                            end,
                  {Sack, erx_tcp_sendlog:has_holes(Log), min(Dupacks, 4)}
          end,
    (dimension(base))#{variants => Variants, abstraction => Abs,
                       checks => [{options_unnegotiated_ignored, fun options_unnegotiated_ignored/1}]};
%% The peer's window zero and full besides the base's four, below one MSS, so persist,
%% window probes and silly-window avoidance are reached; a SYN with window scaling, or with
%% the least MSS FreeBSD takes, on a connection whose send buffer and send exceed it, so
%% that one output pass sends more than one segment (sendalot).
dimension(window) ->
    Variants = fun(#in{flags = Flags, opts = Opts} = In, _) ->
                       Syn = case Flags band ?TH_SYN of
                                 0 -> [];
                                 _ -> [{wscale, In#in{opts = Opts#tcp_opts{wscale = 2}}},
                                       {mss_min, In#in{opts = Opts#tcp_opts{mss = ?TCP_MINMSS}}}]
                             end,
                       Wins = case Flags band ?TH_ACK of
                                  0 -> [];
                                  _ -> [{win_zero, In#in{win = 0}}, {win_full, In#in{win = 16#ffff}}]
                              end,
                       Syn ++ Wins
               end,
    Abs = fun(#tcb{snd_wnd = Wnd, maxseg = Maxseg, wscale = Wscale}) ->
                  {Wnd =:= 0, Wnd < Maxseg, Maxseg, is_tuple(Wscale)}
          end,
    (dimension(base))#{variants => Variants, abstraction => Abs,
                       connection => #{snd_hiwat => 2 * ?TCP_MINMSS + ?HIWAT,
                                       send => stream(0, ?TCP_MINMSS + 1)},
                       checks => [{sent_within_maxseg, fun sent_within_maxseg/1}]};
%% Fragmentation needed and port unreachable, each quoting snd_una (in flight when anything
%% is) and, never in flight, the number below it and snd_max, in every state.
dimension(icmp) ->
    Events = fun(#node{tcb = #tcb{snd_una = Una, snd_max = SndMax}}) ->
                     [{{icmp, Kind, Where}, {icmp, Kind, Seq}}
                      || Kind <- [needfrag, unreach],
                         {Where, Seq} <- [{in_flight, Una} || SndMax > Una]
                                            ++ [{below, Una - 1}, {outside, SndMax}]]
             end,
    Abs = fun(#tcb{maxseg = Maxseg, soft_error = Soft}) -> {Maxseg, Soft} end,
    (dimension(base))#{events => Events, abstraction => Abs,
                       checks => [{icmp_outside_flight_changes_nothing,
                                   fun icmp_outside_flight_changes_nothing/1}]};
dimension(Name) ->
    erlang:error({unknown_dimension, Name}).

%% --- the peer model --------------------------------------------------------------------

%% The peer once Input is a segment: the end of the data it has sent, the windows it has
%% offered, the urgent bytes and ECE it has sent and the answers its RSTs drew; and the
%% connection's irs once it has taken a SYN.
peer_sent(Input, Pre, Post, Actions, Now, Peer0) ->
    Peer1 = case Input of
                {segment, #in{flags = Flags} = In} ->
                    challenged(Flags, Actions, Now, sends(In, Pre, Peer0));
                _ ->
                    Peer0
            end,
    case receives(Actions, Post, Peer1) of
        #peer{irs = none} = Peer2 ->
            case erx_tcp:have_rcvd_syn(Post#tcb.state) of
                true -> Peer2#peer{irs = Post#tcb.irs, next = Post#tcb.irs + 1};
                false -> Peer2
            end;
        Peer2 ->
            Peer2
    end.

%% In SYN-SENT the connection takes the SYN's wire number as it is (erx_tcp_input's lift),
%% so the data's end is measured on the wire there too. A window is scaled as lift scales
%% it, by the shift the connection has before the segment (none in SYN-SENT).
sends(#in{seq = Seq0, ack = Ack, flags = Flags, data = Data, win = Win, urp = Urp},
      #tcb{state = State, snd_una = Una, snd_max = SndMax, wscale = Wscale}, Peer) ->
    Seq = case State of
              syn_sent -> erx_tcp_seq:wire(Seq0);
              _ -> Seq0
          end,
    First = Seq + syn_len(Flags),
    SentEnd = case Data of
                  <<>> -> Peer#peer.sent_end;
                  _ -> max_known(Peer#peer.sent_end, First + byte_size(Data))
              end,
    Shift = case Wscale of
                {Snd, _} -> Snd;
                _ -> 0
            end,
    Edge = case {Flags band ?TH_ACK =/= 0, Flags band ?TH_SYN =/= 0} of
               {true, _} when Ack =< SndMax ->
                   max_known(Peer#peer.right_edge, max_known(Peer#peer.acked, Ack) + (Win bsl Shift));
               {false, true} -> max_known(Peer#peer.right_edge, Una + Win);
               _ -> Peer#peer.right_edge
           end,
    Urgent = case Flags band ?TH_URG =/= 0 andalso Urp >= 1 andalso Urp =< byte_size(Data) of
                 true -> ordsets:add_element(First + Urp - 1, Peer#peer.urgent);
                 false -> Peer#peer.urgent
             end,
    Cwr = case Flags band (?TH_ECE bor ?TH_SYN) of
              ?TH_ECE -> owe_cwr(Peer#peer.cwr);
              _ -> Peer#peer.cwr
          end,
    Acked = case Flags band ?TH_ACK =/= 0 andalso Ack =< SndMax of
                true -> max_known(Peer#peer.acked, Ack);
                false -> Peer#peer.acked
            end,
    Peer#peer{sent_end = SentEnd, right_edge = Edge, urgent = Urgent, cwr = Cwr,
              acked = Acked}.

%% The peer once it has received the segments the step sent: the furthest sequence number
%% of ours, and what of CWR is owed (a segment of ours received again owes one).
receives(Actions, #tcb{snd_una = Una}, Peer) ->
    lists:foldl(fun({#tcp{seq = Seq, flags = Flags}, _, Payload}, #peer{ours_end = End} = P) ->
                        Start = erx_tcp_seq:lift(Seq, Una),
                        Len = syn_len(Flags) + fin_len(Flags) + iolist_size(Payload),
                        Again = Len > 0 andalso End =/= none andalso Start < End,
                        Owed = case Again of
                                   true -> owe_cwr(P#peer.cwr);
                                   false -> P#peer.cwr
                               end,
                        Ours = case Len of
                                   0 -> End;
                                   _ -> max_known(End, Start + Len)
                               end,
                        P#peer{ours_end = Ours, cwr = pay_cwr(Flags, Owed)}
                end, Peer, [S || {transmit, Segments} <- Actions, S <- Segments]).

owe_cwr(unowed) -> unowed;
owe_cwr(_) -> owed.

pay_cwr(Flags, owed) when Flags band ?TH_CWR =/= 0 -> owed_none;
pay_cwr(Flags, owed_none) when Flags band ?TH_CWR =/= 0 -> unowed;
pay_cwr(_, Cwr) -> Cwr.

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

%% The stream position after the bytes delivered, matched from the peer's next position;
%% `{error, At}` where a byte differs from the stream and is not an urgent byte kept out.
%% The stream's bytes at adjacent positions always differ, so a byte the connection kept
%% out shows as a mismatch at its position.
match(<<>>, Next, _, Skipped) ->
    {ok, Next, Skipped};
match(<<Byte, Rest/binary>> = Bytes, Next, Urgent, Skipped) ->
    case stream_byte(Next) of
        Byte -> match(Rest, Next + 1, Urgent, Skipped);
        _ ->
            case ordsets:is_element(Next, Urgent) of
                true -> match(Bytes, Next + 1, Urgent, Skipped + 1);
                false -> {error, Next}
            end
    end.

delivered_to(Actions, #peer{next = Next, urgent = Urgent}) ->
    case delivered(Actions) of
        <<>> -> Next;
        Bytes ->
            {ok, After, _} = match(Bytes, Next, Urgent, 0),
            After
    end.

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

%% The bytes delivered continue the peer's stream from irs + 1 where the last left off, but
%% for urgent bytes the peer pointed at, which the connection keeps out (a hit).
delivered_in_order(#{actions := Actions, peer := #peer{irs = Irs, next = Next, urgent = Urgent}}) ->
    case delivered(Actions) of
        <<>> -> ok;
        Bytes when Irs =:= none -> {fail, {delivered_before_a_syn, Bytes}};
        Bytes ->
            case match(Bytes, Next, Urgent, 0) of
                {ok, _, 0} -> ok;
                {ok, _, _} -> hit;
                {error, At} -> {fail, {Next, Bytes, {differs_at, At}}}
            end
    end.

delivered_only_what_was_sent(#{actions := Actions,
                               peer := #peer{irs = Irs, sent_end = End} = Peer}) ->
    case delivered(Actions) of
        <<>> -> ok;
        _ when Irs =:= none; End =:= none -> {fail, {Irs, End}};
        _ ->
            After = delivered_to(Actions, Peer),
            holds(After =< End, {After, End})
    end.

%% Every data segment sent ends within the right edge the peer offered, but for a window
%% probe of one byte while the peer's window is zero (a hit).
sent_within_peer_window(#{actions := Actions, post := #tcb{snd_una = Una, snd_wnd = Wnd},
                          peer := #peer{right_edge = Edge}}) ->
    Over = [{Start, Bytes}
            || {Start, Bytes} <- sent_data(Actions, Una), Bytes > 0,
               Edge =:= none orelse Start + Bytes > Edge],
    case Over of
        [] -> ok;
        [{_, 1}] when Wnd =:= 0 -> hit;
        _ -> {fail, {Edge, Wnd, Over}}
    end.

%% The start and length of the data of each segment sent.
sent_data(Actions, Una) ->
    [{erx_tcp_seq:lift(Seq, Una) + syn_len(Flags), iolist_size(Payload)}
     || {transmit, Segments} <- Actions, {#tcp{seq = Seq, flags = Flags}, _, Payload} <- Segments].

%% In a synchronized state (and SYN-RECEIVED) a RST ends the connection only at exactly
%% last_ack_sent (RFC 5961 section 3); SYN-SENT has its own rule and TIME-WAIT ignores RSTs.
%% A RST that ends the connection is a hit.
rst_only_at_last_ack_sent(#{input := {segment, #in{seq = Seq, flags = Flags}},
                            pre := #tcb{state = State, ended = false, last_ack_sent = LastAck},
                            post := #tcb{ended = Ended}})
  when Flags band ?TH_RST =/= 0, State =/= syn_sent, State =/= time_wait ->
    case Ended of
        false -> ok;
        true when Seq =:= LastAck -> hit;
        true -> {fail, {State, Seq, LastAck}}
    end;
rst_only_at_last_ack_sent(_) ->
    ok.

%% The RSTs received at one instant, which all fall in one window of the limit, draw at most
%% tcp_ack_war_cnt challenge ACKs, counted by the peer as it receives them; a hit at the
%% limit.
challenge_acks_within_limit(#{peer := #peer{challenged = {_, Count}}}) ->
    if
        Count < ?ACK_WAR_CNT -> ok;
        Count =:= ?ACK_WAR_CNT -> hit;
        true -> {fail, Count}
    end.

%% A segment older than the last window update by the SND.WL1/SND.WL2 rule (RFC 9293
%% section 3.10.7.4) takes no window: SND.WL1 and SND.WL2 stay, and the window does not grow
%% (it shrinks by what the ACK takes, as tcp_input.c's `snd_wnd -= acked` keeps the right
%% edge). Its sequence number is the one the window update sees: past what trimming drops
%% below rcv_nxt. An old segment judged is a hit.
old_ack_keeps_send_window(#{input := {segment, #in{seq = Seq, ack = Ack, flags = Flags, data = Data}},
                            pre := #tcb{state = State, ended = false} = Pre, post := Post})
  when Flags band ?TH_ACK =/= 0, State =/= syn_sent, State =/= syn_received,
       State =/= time_wait ->
    Seen = Seq + min(max(Pre#tcb.rcv_nxt - Seq, 0), byte_size(Data)),
    Window = fun(#tcb{snd_wnd = Wnd, snd_wl1 = Wl1, snd_wl2 = Wl2}) -> {Wnd, Wl1, Wl2} end,
    Old = {Seen, Ack} < {Pre#tcb.snd_wl1, Pre#tcb.snd_wl2},
    Kept = {Pre#tcb.snd_wl1, Pre#tcb.snd_wl2} =:= {Post#tcb.snd_wl1, Post#tcb.snd_wl2}
        andalso Post#tcb.snd_wnd =< Pre#tcb.snd_wnd,
    case {Old, Kept} of
        {false, _} -> ok;
        {true, true} -> hit;
        {true, false} -> {fail, {{Seen, Ack}, Window(Pre), Window(Post)}}
    end;
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

%% Where header prediction takes a segment (a hit), the general stages give the same
%% control block and actions; where it declines, both runs are the same pipeline, so only
%% a segment it takes is run both ways.
header_prediction_agrees(#{input := {segment, In},
                           pre := #tcb{state = State, ended = false} = Pre, ctx := Ctx})
  when State =/= closed, State =/= time_wait ->
    Segment = wire_segment(In),
    Stages = erx_tcp_input:stages(),
    case fast_path_taken(Stages, Segment, Pre, Ctx) of
        false ->
            ok;
        true ->
            Fast = erx_tcp_input:run(Stages, Segment, Pre, Ctx),
            Slow = erx_tcp_input:run(lists:keydelete(header_prediction, 1, Stages), Segment, Pre, Ctx),
            case Fast =:= Slow of
                true -> hit;
                false -> {fail, {In, differing_fields(element(1, Fast), element(1, Slow))}}
            end
    end;
header_prediction_agrees(_) ->
    ok.

%% Whether header prediction jumps past the general stages: the stages up to it, with its
%% jump turned into a marker.
fast_path_taken(Stages, Segment, Pre, Ctx) ->
    {Before, [{header_prediction, Predict} | _]} =
        lists:splitwith(fun({Name, _}) -> Name =/= header_prediction end, Stages),
    Marked = fun(Seg, Tcb, C) ->
                     case Predict(Seg, Tcb, C) of
                         {goto, _, _, _, _} -> {done, Tcb, [fast_path]};
                         _ -> {done, Tcb, []}
                     end
             end,
    {_, Actions} = erx_tcp_input:run(Before ++ [{header_prediction, Marked}], Segment, Pre, Ctx),
    lists:member(fast_path, Actions).

differing_fields(A, B) ->
    [Field || {Field, X, Y} <- lists:zip3(record_info(fields, tcb), tl(tuple_to_list(A)),
                                           tl(tuple_to_list(B))),
              X =/= Y].

%% A report quoting a sequence number outside snd_una up to snd_max changes nothing: the
%% step gives what it gives on no event at all (an empty batch, where only output runs).
%% A report in flight that changes the connection is a hit.
icmp_outside_flight_changes_nothing(#{input := {icmp, _, Seq}, pre := Pre, post := Post,
                                      actions := Actions, ctx := Ctx}) ->
    #tcb{snd_una = Una, snd_max = SndMax} = Pre,
    Nothing = erx_tcp:step({segments, []}, Pre, Ctx),
    InFlight = Seq >= Una andalso Seq < SndMax,
    case {InFlight, {Post, Actions} =:= Nothing} of
        {false, true} -> ok;
        {false, false} -> {fail, {Una, Seq, SndMax, differing_fields(Post, element(1, Nothing))}};
        {true, true} -> ok;
        {true, false} -> hit
    end;
icmp_outside_flight_changes_nothing(_) ->
    ok.

%% A segment sent carries CWR only to pay for a window reduction since the last one: the
%% peer sent ECE, or a segment of ours came again, after a timeout or three duplicates
%% (cc_cong_signal owes CWR for CC_ECN, CC_RTO and CC_NDUPACK alike). A CWR sent is a hit.
cwr_only_after_reduction(#{actions := Actions, peer := #peer{cwr = Owed}}) ->
    Cwr = [S || {transmit, Segments} <- Actions, {#tcp{flags = F}, _, _} = S <- Segments,
                F band ?TH_CWR =/= 0],
    case {Cwr, Owed} of
        {[], _} -> ok;
        {_, unowed} -> {fail, Cwr};
        {_, _} -> hit
    end.

%% A segment without SYN carrying an option the connection did not negotiate (a timestamp,
%% SACK blocks, ECE, CWR or an ECN mark) gives the same step as without it (a hit when there
%% was one to strip). SYN-SENT, whose SYN-ACK negotiates, is left out.
options_unnegotiated_ignored(#{input := {segment, #in{flags = Flags} = In},
                               pre := #tcb{state = State} = Pre, post := Post,
                               actions := Actions, ctx := Ctx})
  when Flags band ?TH_SYN =:= 0, State =/= syn_sent ->
    case unnegotiated(In, Pre) of
        In ->
            ok;
        Stripped ->
            {Event, _} = event({segment, Stripped}, 0),
            Without = erx_tcp:step(Event, Pre, Ctx),
            case Without =:= {Post, Actions} of
                true -> hit;
                false -> {fail, {In, differing_fields(Post, element(1, Without))}}
            end
    end;
options_unnegotiated_ignored(_) ->
    ok.

unnegotiated(#in{opts = Opts0, flags = Flags} = In, #tcb{ts = Ts, sack = Sack, ecn = Ecn}) ->
    Opts1 = case Ts of
                off -> Opts0#tcp_opts{ts = none};
                _ -> Opts0
            end,
    Opts = case Sack of
               on -> Opts1;
               _ -> Opts1#tcp_opts{sacks = []}
           end,
    case erx_tcp_ecn:enabled(Ecn) of
        true -> In#in{opts = Opts};
        false -> In#in{opts = Opts, flags = Flags band bnot (?TH_ECE bor ?TH_CWR), ip_ecn = 0}
    end.

%% No segment carries more data than the MSS, and a pass that sends more than one data
%% segment (sendalot) is a hit.
sent_within_maxseg(#{actions := Actions, post := #tcb{snd_una = Una, maxseg = Maxseg}}) ->
    Sizes = [Bytes || {_, Bytes} <- sent_data(Actions, Una), Bytes > 0],
    case [B || B <- Sizes, B > Maxseg] of
        [] when length(Sizes) > 1 -> hit;
        [] -> ok;
        Over -> {fail, {Maxseg, Over}}
    end.

holds(true, _) -> ok;
holds(false, Detail) -> {fail, Detail}.

%% RFC 9293's state diagram (section 3.3.2) as one step of each kind of input can take it:
%% an owner's request moves along one of its edges; a segment takes at most one edge on its
%% acknowledgement and then at most one on its FIN; an expiry or an ICMP report only ends
%% the connection; and anything may end it (an abort, a RST, a timeout, the last ACK, the
%% end of TIME-WAIT). FreeBSD keeps a close in SYN-RECEIVED as a FIN owed (TF_NEEDFIN,
%% tcp_usrclosed), so a close leaves that state as it is and the ACK of the SYN leads to
%% FIN-WAIT-1.
allowed(_, State, State) -> true;
allowed(_, _, closed) -> true;
allowed(user, From, To) ->
    lists:member(To, user_edges(From));
allowed(segment, From, To) ->
    AfterAck = [From | ack_edges(From)],
    lists:member(To, AfterAck ++ lists:flatmap(fun fin_edges/1, AfterAck));
allowed(expired, _, _) ->
    false;
allowed(icmp, _, _) ->
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

new(Iss, Conn) ->
    erx_tcp_user:new(#{family => inet, local => {<<10, 0, 0, 1>>, 4000},
                       remote => {<<10, 0, 0, 2>>, 80}, iss => Iss, ts_offset => 7,
                       cc => erx_tcp_cc_newreno, loss => erx_tcp_loss_dupack,
                       snd_hiwat => maps:get(snd_hiwat, Conn, ?HIWAT), rcv_hiwat => ?HIWAT,
                       gen => erx_net_rand:new(<<0:128>>), now => ?T0}).

ctx(Now) -> #tcp_ctx{now = Now, credit = 64, mtu = 1500}.

%% The caller of a connect, send or shutdown; the step only hands it back in replies.
from() -> {self(), explore}.

delivered(Actions) -> iolist_to_binary([Bytes || {deliver, Bytes} <- Actions]).

syn_len(Flags) when Flags band ?TH_SYN =/= 0 -> 1;
syn_len(_) -> 0.

fin_len(Flags) when Flags band ?TH_FIN =/= 0 -> 1;
fin_len(_) -> 0.
