%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_icmp_sock).
-moduledoc """
An ICMP echo socket (docs/design-network-stack.md, "Scope", the raw ICMP socket for
`ping`): the process holding one echo identifier's demultiplexing entry, its queue of
echo replies and its owner. It does the part of FreeBSD's raw ICMP socket that ping(8)
uses (`rip_input`, `rip_send`), with the identifier filter ping applies to what its raw
socket receives moved into the stack, so the socket receives only the echo replies that
carry its identifier and nothing else of the network's ICMP.

**The identifier.** `open/1` draws a random start from a generator of its own, as ping
draws its identifier from `arc4random`, and takes the first identifier from there, in
order and wrapping, that no other echo socket holds, through erx_net_bind's funnel, so two
sockets never share one.

**The socket protocol.** It takes only `{erx_net, SockProc, Body}` from its socket
process, erx_gen_icmp's (erx_gen_udp's socket process of kind `icmp`), bare when its
grantee is `local` or in the envelope of the grantee's domain, through
erx_net_admit:request/4 as an `icmp` socket; any other message is dropped and counted
(`unknown`), and a body of another shape is counted (`shape`). `{call, N, {echo_send, Ip,
Seq, Ttl, Data}}` is answered at once, `{erx_net, self(), {reply, N, Result}}`; `close`
gives up the identifier and ends the socket, with no reply; `{credit, Bytes}` adds to the
bytes the socket may push, up to 64 MiB.

**Receiving.** An interface hands `{items, Interface, Items}` with one unit of the
socket's credit reserved per reply, so at most `limit` replies (16 when absent) wait in
the socket, and a peer that floods replies with the socket's identifier fills the credit
and nothing more: what finds no room is dropped and counted by the interface. Each reply
is verified before it arrives (its length and checksum, `erx_icmp4_wire:decode/1`); its
data are the peer's bytes and are handed on as they came, each reply pushed whole as
`{echo, Ip, Ttl, Seq, Data}` while the bytes granted cover its data (one byte for empty
data), compacted, so a small reply never keeps a large frame alive. The socket matches no
sequence number: that is its owner's part, as it is ping's.

**Sending.** An echo request carries the socket's identifier, the given sequence number
and data, over the path the current configuration gives (`erx_net_frame:path/3`, `ip/4`)
with the TTL asked for (`default`, the path's), and goes through erx_net_tx. A full
transmit path answers `{error, enobufs}`. As FreeBSD's `rip_output` does, a request may go
to a broadcast address.

**Ending.** The socket monitors its socket process and ends with it, giving up its
identifier. The grant opens it (`icmp_open`), linked to the grant; as with erx_udp_sock,
erx_net_tables watches it in the grant's place, since the grant's account is not built.
""".

-behaviour(gen_server).

-export([open/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([options/0]).

-include("erx_icmp4_wire.hrl").

-define(LIMIT_DEFAULT, 16).
%% The requests a socket process may have in flight: its 64 calls, two credit messages
%% (each grant is at least half the target and they sum to at most the target) and its
%% close, which waits for no place.
-define(MAX_REQUEST, 67).
%% The most bytes a socket process may grant, as for a datagram socket.
-define(MAX_PUSH_CREDIT, 67108864).
-define(PROTO_ICMP, 1).
-define(IDENTS, 16#10000).
-define(IP_HDR_LEN, 20).
-define(ICMP_MINLEN, 8).
-define(IP_MAXPACKET, 16#ffff).

-record(state, {owner :: pid(),
                origin :: erx_net_admit:origin(),
                ident :: 0..16#ffff,
                credit :: erx_net_credit:credit(),
                push_credit = 0 :: non_neg_integer(),
                queue = queue:new() :: queue:queue(term()),
                gen :: erx_net_rand:gen(),
                config = none :: none | {non_neg_integer(), erx_net_frame:snapshot()},
                counters = #{} :: #{atom() => pos_integer()}}).

-type options() :: #{owner := pid(), origin := erx_net_admit:origin(), limit => pos_integer()}.

%% --- API -------------------------------------------------------------------------

-doc """
Opens an echo socket linked to the calling process, for the socket process `owner`, whose
messages arrive by `origin`. Options: `limit`, the replies that may wait (16 when absent).
""".
-spec open(options()) -> {ok, pid()} | {error, term()}.
open(#{owner := Owner} = Opts) when is_pid(Owner) ->
    gen_server:start_link(?MODULE, Opts, []).

%% --- gen_server ------------------------------------------------------------------

-doc false.
init(#{owner := Owner, origin := Origin} = Opts) ->
    ok = (erx_net_sup:runtime()):serve(?MAX_REQUEST),
    Credit = erx_net_credit:new(maps:get(limit, Opts, ?LIMIT_DEFAULT)),
    {Start, Gen} = erx_net_rand:uniform(?IDENTS, erx_net_rand:new(erx_net_clock:entropy(16))),
    case bind(Start, ?IDENTS, #{pid => self(), credit => Credit}) of
        {ok, Ident} ->
            ok = erx_net_tables:watch_holder(self()),
            _ = monitor(process, Owner),
            {ok, #state{owner = Owner, origin = Origin, ident = Ident, credit = Credit, gen = Gen}};
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
handle_info({items, _If, Items}, #state{queue = Queue} = S) when is_list(Items) ->
    {noreply, hand_over(S#state{queue = queue:join(Queue, queue:from_list(Items))})};
handle_info({'DOWN', _, process, Owner, _}, #state{owner = Owner, ident = Ident} = S) ->
    ok = erx_net_bind:delete(key(Ident)),
    {stop, normal, S};
handle_info(Msg, #state{origin = Origin, owner = Owner} = S) ->
    case erx_net_admit:request(icmp, Origin, Owner, Msg) of
        {ok, Request} -> request(Request, S);
        unknown -> {noreply, count(unknown, S)};
        {refused, Check} -> {noreply, count(Check, S)}
    end.

%% --- The socket protocol ---------------------------------------------------------

%% A request of the socket process, admitted by erx_net_admit, answered at once.
request({credit, Bytes}, #state{push_credit = Credit} = S) ->
    {noreply, hand_over(S#state{push_credit = min(Credit + Bytes, ?MAX_PUSH_CREDIT)})};
request({call, _N, close}, #state{ident = Ident} = S) ->
    ok = erx_net_bind:delete(key(Ident)),
    {stop, normal, S};
request({call, N, {echo_send, Ip, Seq, Ttl, Data}}, S0) ->
    Opts = case Ttl of
               default -> #{};
               _ -> #{ttl => Ttl}
           end,
    {Result, S} = transmit(addr(Ip), Seq, Opts#{data => Data}, configured(S0)),
    push({reply, N, Result}, S),
    {noreply, S}.

push(Body, #state{owner = Owner}) ->
    Owner ! {erx_net, self(), Body},
    ok.

count(Name, #state{counters = Counters} = S) ->
    S#state{counters = maps:update_with(Name, fun(N) -> N + 1 end, 1, Counters)}.

%% --- The identifier ----------------------------------------------------------------

key(Ident) -> {icmp_echo, inet, Ident}.

%% The first identifier from Ident on, wrapping, that no other socket holds.
bind(_Ident, 0, _Entry) ->
    {error, eaddrinuse};
bind(Ident, Left, Entry) ->
    case erx_net_bind:insert(key(Ident), self(), Entry) of
        ok -> {ok, Ident};
        {error, eaddrinuse} -> bind((Ident + 1) rem ?IDENTS, Left - 1, Entry)
    end.

%% --- Receiving -------------------------------------------------------------------

%% The queue pushed in order while the bytes granted cover the next reply's data.
hand_over(#state{queue = Queue0, credit = Credit, push_credit = Bytes} = S) ->
    case queue:out(Queue0) of
        {{value, {echo_reply, Src, Ttl, _Ident, Seq, Data}}, Queue} when max(1, byte_size(Data)) =< Bytes ->
            ok = erx_net_credit:take(Credit, 1),
            push({echo, tuple(Src), Ttl, Seq, compact(Data)}, S),
            hand_over(S#state{queue = Queue, push_credit = Bytes - max(1, byte_size(Data))});
        _ ->
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

%% An echo request whose IPv4 datagram would pass 65535 bytes is refused before it is built,
%% since erx_icmp4_wire encodes only messages that fit one.
transmit(Dst, Seq, #{data := Data} = Opts, #state{ident = Ident, gen = Gen0, config = {_, Snap}} = S) ->
    maybe
        true ?= ?IP_HDR_LEN + ?ICMP_MINLEN + iolist_size(Data) =< ?IP_MAXPACKET orelse {error, emsgsize},
        {ok, Path} ?= erx_net_frame:path(Dst, (maps:with([ttl], Opts))#{broadcast => true}, Snap),
        Request = erx_icmp4_wire:encode(#icmp4{type = ?ICMP_ECHO, code = 0, msg = {echo, Ident, Seq}}, Data),
        {ok, Packets, Gen} ?= erx_net_frame:ip(Path, ?PROTO_ICMP, Request, Gen0),
        {handed(erx_net_tx:send(Path, Packets)), S#state{gen = Gen}}
    else
        {error, _} = Error -> {Error, S}
    end.

handed(ok) -> ok;
handed(full) -> {error, enobufs}.

addr({A, B, C, D}) -> <<A, B, C, D>>.

tuple(<<A, B, C, D>>) -> {A, B, C, D}.
