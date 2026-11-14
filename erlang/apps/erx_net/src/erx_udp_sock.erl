%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_udp_sock).
-moduledoc """
A UDP socket (docs/design-network-stack.md, "UDP", "Transmitting", "The socket
process"): the process holding a bound port's demultiplexing entry and its receive
queue, for its socket process, erx_gen_udp's, in the owner's domain. The grant opens it
for the socket process that asked (`udp_open`), with the origin its grantee's messages
arrive by. The socket is charged to no grant's account, whose limits are not built, so
erx_net_tables watches it in the grant's place.

**The socket protocol.** It takes only `{erx_net, SockProc, Body}` from its socket
process, bare when its grantee is `local` or in the envelope of the grantee's domain,
through erx_net_admit:request/4 as a `udp` socket; any other message is dropped and
counted (`unknown`), and a body of another shape is counted (`shape`), so no reply goes
to a party of another domain. Each `{call, N, Request}` is answered at once,
`{erx_net, self(), {reply, N, Result}}`: `{send_to, Ip, Port, Data}`, `{send, Data}` to
the connected peer (`edestaddrreq` before a connect), `{connect, Ip, Port}`, and
`sockname`, an unbound address answered as `{0, 0, 0, 0}`. `close` gives up the port
and ends the socket, with no reply. `{credit, Bytes}` adds to the bytes the socket may
push, up to 64 MiB.

**Receiving.** The interface credit, one unit per datagram, bounds what interfaces may
hand it; they send `{items, Interface, Items}` with the units reserved, and the queue
holds at most the credit's limit, as FreeBSD drops on a full receive buffer. A
connected socket takes only its peer's datagrams, as FreeBSD's `in_pcblookup` finds a
connected socket only for its foreign address and port; the others are dropped and
their units taken. The queue is pushed in order, each datagram whole as `{datagram, Ip,
Port, Data}` while the bytes granted cover its length (one byte for an empty one), and
its unit taken when it leaves. An ICMP error queued for a connected socket is dropped,
since the socket reports no errors. A payload smaller than a quarter of the binary it is
part of (a frame, or a reassembled datagram) is copied out, so a small datagram never
keeps a large one alive.

**Ending.** The socket monitors its socket process and ends with it, as a gen_udp socket
closes with its owning process.

**Sending.** A send builds the datagram's packets over the path the current
configuration gives (`erx_net_frame:path/3`, `udp/5`) and sends them through erx_net_tx,
to the driver or to the interface to resolve. A full driver credit answers `{error,
enobufs}`.
""".

-behaviour(gen_server).

-export([open/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([options/0]).

-define(LIMIT_DEFAULT, 64).
%% The requests a socket process may have in flight: its 64 calls, two credit messages
%% (each grant is at least half the target and they sum to at most the target) and its
%% close, which waits for no place.
-define(MAX_REQUEST, 67).
%% The most bytes a socket process may grant, stock's TCP_MAX_PACKET_SIZE as for a connection.
-define(MAX_PUSH_CREDIT, 67108864).

-record(state, {owner :: pid(),
                origin :: erx_net_admit:origin(),
                ip :: <<_:32>> | any,
                port :: 0..16#ffff,
                key :: erx_net_input:key(),
                credit :: erx_net_credit:credit(),
                push_credit = 0 :: non_neg_integer(),
                peer = none :: none | {<<_:32>>, 1..16#ffff},
                queue = queue:new() :: queue:queue(term()),
                gen :: erx_net_rand:gen(),
                config = none :: none | {non_neg_integer(), erx_net_frame:snapshot()},
                counters = #{} :: #{atom() => pos_integer()}}).

-type options() :: #{owner := pid(), origin := erx_net_admit:origin(), grant := pid(),
                     ports := erx_net_bind:ports(), ip => inet:ip4_address() | any,
                     limit => pos_integer()}.

%% --- API -------------------------------------------------------------------------

-doc """
Opens a socket bound to `Port` (0 for an ephemeral port), linked to the calling process,
for the socket process `owner`, whose messages arrive by `origin`, as a socket of `grant`,
which may bind the inclusive port ranges of `ports`. The bind is explicit
(erx_net_bind:bind/2), so it meets the UDP keys it overlaps, those of another grant
included. Options: the local address `ip` (`any` when absent) and `limit`, the datagrams
that may wait (64 when absent).
""".
-spec open(0..16#ffff, options()) -> {ok, pid()} | {error, term()}.
open(Port, #{owner := Owner} = Opts) when is_integer(Port), Port >= 0, Port =< 16#ffff, is_pid(Owner) ->
    gen_server:start_link(?MODULE, {Port, Opts}, []).

%% --- gen_server ------------------------------------------------------------------

-doc false.
init({Port0, #{owner := Owner, origin := Origin, grant := Grant, ports := Ports} = Opts}) ->
    ok = (erx_net_sup:runtime()):serve(?MAX_REQUEST),
    Ip = case maps:get(ip, Opts, any) of
             any -> any;
             Tuple -> addr(Tuple)
         end,
    Credit = erx_net_credit:new(maps:get(limit, Opts, ?LIMIT_DEFAULT)),
    Entry = #{pid => self(), credit => Credit, grant => Grant},
    {Start, Gen} = erx_net_bind:ephemeral_start(erx_net_rand:new(erx_net_clock:entropy(16))),
    KeyOf = fun(P) -> {udp, inet, Ip, P} end,
    Spec = #{transport => udp, family => inet, local => Ip, port => Port0, start => Start,
             reuseaddr => false, reuseport => false, allowed => Ports},
    case erx_net_bind:bind(Spec, Entry) of
        {ok, Port} ->
            _ = erlang:monitor(process, Owner),
            {ok, #state{owner = Owner, origin = Origin, ip = Ip, port = Port, key = KeyOf(Port),
                        credit = Credit, gen = Gen}};
        {error, Reason} ->
            {stop, Reason}
    end.

-doc false.
handle_call(_Request, _From, S) ->
    {reply, {error, einval}, S}.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

-doc false.
handle_info({items, _If, Items0}, #state{credit = Credit, queue = Queue} = S) when is_list(Items0) ->
    {Items, Dropped} = lists:partition(fun(Item) -> from_peer(Item, S) end, Items0),
    ok = erx_net_credit:take(Credit, length(Dropped)),
    {noreply, hand_over(S#state{queue = queue:join(Queue, queue:from_list(Items))})};
handle_info({'DOWN', _, process, Owner, _}, #state{owner = Owner, key = Key} = S) ->
    ok = erx_net_bind:delete(Key),
    {stop, normal, S};
handle_info(Msg, #state{origin = Origin, owner = Owner} = S) ->
    case erx_net_admit:request(udp, Origin, Owner, Msg) of
        {ok, Request} -> request(Request, S);
        unknown -> {noreply, count(unknown, S)};
        {refused, Check} -> {noreply, count(Check, S)}
    end.

%% --- The socket protocol ---------------------------------------------------------

%% A request of the socket process, admitted by erx_net_admit, answered at once.
request({credit, Bytes}, #state{push_credit = Credit} = S) ->
    {noreply, hand_over(S#state{push_credit = min(Credit + Bytes, ?MAX_PUSH_CREDIT)})};
request({call, _N, close}, #state{key = Key} = S) ->
    ok = erx_net_bind:delete(Key),
    {stop, normal, S};
request({call, N, Request}, S0) ->
    {Result, S} = call(Request, S0),
    push({reply, N, Result}, S),
    {noreply, S}.

call({send_to, Ip, Port, Data}, S) ->
    transmit(addr(Ip), Port, Data, configured(S));
call({send, Data}, #state{peer = {Ip, Port}} = S) ->
    transmit(Ip, Port, Data, configured(S));
call({send, _Data}, #state{peer = none} = S) ->
    {{error, edestaddrreq}, S};
call({connect, Ip, Port}, S) ->
    {ok, S#state{peer = {addr(Ip), Port}}};
call(sockname, #state{ip = Ip, port = Port} = S) ->
    {{ok, {tuple(Ip), Port}}, S}.

push(Body, #state{owner = Owner}) ->
    Owner ! {erx_net, self(), Body},
    ok.

count(Name, #state{counters = Counters} = S) ->
    S#state{counters = maps:update_with(Name, fun(N) -> N + 1 end, 1, Counters)}.

%% --- Receiving -------------------------------------------------------------------

%% A connected socket's datagrams come from its peer; an unconnected one takes any.
from_peer({datagram, Source, _Dst, _Data}, #state{peer = Peer}) ->
    Peer =:= none orelse Source =:= Peer;
from_peer(_Report, _S) ->
    true.

%% The queue pushed in order while the bytes granted cover the next datagram.
hand_over(#state{queue = Queue0, credit = Credit, push_credit = Bytes} = S) ->
    case queue:out(Queue0) of
        {{value, {datagram, {Ip, Port}, _Dst, Data}}, Queue} when max(1, byte_size(Data)) =< Bytes ->
            ok = erx_net_credit:take(Credit, 1),
            push({datagram, tuple(Ip), Port, compact(Data)}, S),
            hand_over(S#state{queue = Queue, push_credit = Bytes - max(1, byte_size(Data))});
        {{value, {datagram, _, _, _}}, _} ->
            S;
        {{value, _Report}, Queue} ->
            ok = erx_net_credit:take(Credit, 1),
            hand_over(S#state{queue = Queue});
        {empty, _} ->
            S
    end.

compact(Data) ->
    case byte_size(Data) * 4 < binary:referenced_byte_size(Data) of
        true -> binary:copy(Data);
        false -> Data
    end.

%% --- Sending ---------------------------------------------------------------------

%% The configuration, read again when its generation moved.
configured(#state{config = Config} = S) ->
    Gen = erx_net_tables:generation(),
    case Config of
        {Gen, _} -> S;
        _ -> S#state{config = erx_net_tables:configuration()}
    end.

transmit(Dst, Dport, Data, #state{ip = Ip, port = Port, gen = Gen0, config = {_, Snap}} = S) ->
    Opts = case Ip of
               any -> #{};
               _ -> #{src => Ip}
           end,
    maybe
        {ok, Path} ?= erx_net_frame:path(Dst, Opts, Snap),
        {ok, Packets, Gen} ?= erx_net_frame:udp(Path, Port, Dport, Data, Gen0),
        {handed(erx_net_tx:send(Path, Packets)), S#state{gen = Gen}}
    else
        {error, _} = Error -> {Error, S}
    end.

handed(ok) -> ok;
handed(full) -> {error, enobufs}.

addr({A, B, C, D}) -> <<A, B, C, D>>.

tuple(any) -> {0, 0, 0, 0};
tuple(<<A, B, C, D>>) -> {A, B, C, D}.
