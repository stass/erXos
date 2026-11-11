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

**Receiving.** An interface hands `{items, Interface, Items}` with one unit of the
socket's credit reserved per reply, so at most `limit` replies (16 when absent) wait for
`recv/2`, and a peer that floods replies with the socket's identifier fills the credit and
nothing more: what finds no room is dropped and counted by the interface. Each reply is
verified before it arrives (its length and checksum, `erx_icmp4_wire:decode/1`); its
data are the peer's bytes and are handed on as they came. A waiting reply holds its frame, which the credit bounds, and
`recv/2` hands it on compacted, so a small reply never
keeps a large frame alive. The socket matches no sequence number: that is its owner's
part, as it is ping's.

**Sending.** `send/4` builds an echo request with the socket's identifier, the given
sequence number and data, over the path the current configuration gives
(`erx_net_frame:path/3`, `ip/4`) with the TTL asked for, and sends it through erx_net_tx.
A full transmit path answers `{error, enobufs}`. Each request is checked for its shape: an
address, a sequence number, the data as a binary and a TTL; anything else is answered
`{error, einval}`. The socket takes plain calls only, so an enveloped call of another
domain reaches handle_info/2 and is dropped; taking its requests through erx_net_admit, as
a TCP connection does, is TODO.md's item on the socket protocol for UDP and ICMP. As FreeBSD's `rip_output` does, a request
may go to a broadcast address.

**Ending.** The socket monitors its owner and ends with it, giving up its identifier;
`close/1` does the same at once. A program opens it through its grant (`icmp_open`),
which links it; as with erx_udp_sock, erx_net_tables watches it in the grant's place,
since the grant's account is not built.
""".

-behaviour(gen_server).

-export([open/1, send/4, recv/2, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([options/0, send_options/0, reply/0]).

-include("erx_icmp4_wire.hrl").

-define(LIMIT_DEFAULT, 16).
-define(MAX_REQUEST, 16).
-define(PROTO_ICMP, 1).
-define(IDENTS, 16#10000).
-define(IP_HDR_LEN, 20).
-define(ICMP_MINLEN, 8).
-define(IP_MAXPACKET, 16#ffff).
%% A recv's timeout: `infinity`, or at most the longest timer, 4294967295 ms.
-define(IS_TIMEOUT(T), (T =:= infinity orelse (is_integer(T) andalso T >= 0 andalso T =< 4294967295))).

-record(state, {owner :: reference(),
                ident :: 0..16#ffff,
                credit :: erx_net_credit:credit(),
                queue = queue:new() :: queue:queue(term()),
                waiter = none :: none | {gen_server:from(), Deadline :: integer() | infinity},
                gen :: erx_net_rand:gen(),
                config = none :: none | {non_neg_integer(), erx_net_frame:snapshot()},
                armed = infinity :: erx_net_clock:armed()}).

-type options() :: #{limit => pos_integer(), owner => pid()}.
-type send_options() :: #{ttl => 1..255}.
-type reply() :: {inet:ip4_address(), Ttl :: 0..255, Seq :: 0..16#ffff, Data :: binary()}.

%% --- API -------------------------------------------------------------------------

-doc """
Opens an echo socket linked to the calling process. Options: `limit`, the replies that may
wait for `recv/2` (16 when absent), and `owner`, the process the socket monitors and ends
with (the caller when absent).
""".
-spec open(options()) -> {ok, pid()} | {error, term()}.
open(Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, {maps:get(owner, Opts, self()), Opts}, []).

-doc """
Sends an echo request with sequence number `Seq` and `Data` to `Ip`, with the TTL
`ttl` (the path's when absent).
""".
-spec send(pid(), inet:ip4_address(), 0..16#ffff, #{data := iodata(), ttl => 1..255}) ->
          ok | {error, term()}.
send(Sock, {_, _, _, _} = Ip, Seq, #{data := Data} = Opts)
  when is_integer(Seq), Seq >= 0, Seq =< 16#ffff ->
    gen_server:call(Sock, {send, addr(Ip), Seq, (maps:with([ttl], Opts))#{data => iolist_to_binary(Data)}}, infinity).

-doc """
Takes the next echo reply that carries the socket's identifier, waiting at most `Timeout`
milliseconds: its sender, TTL, sequence number and data.
""".
-spec recv(pid(), timeout()) -> {ok, reply()} | {error, timeout | einval}.
recv(Sock, Timeout) when Timeout =:= infinity; is_integer(Timeout), Timeout >= 0 ->
    gen_server:call(Sock, {recv, Timeout}, infinity).

-doc "Closes the socket, giving up its identifier.".
-spec close(pid()) -> ok.
close(Sock) ->
    gen_server:call(Sock, close, infinity).

%% --- gen_server ------------------------------------------------------------------

-doc false.
init({Owner, Opts}) ->
    ok = (erx_net_sup:runtime()):serve(?MAX_REQUEST),
    Credit = erx_net_credit:new(maps:get(limit, Opts, ?LIMIT_DEFAULT)),
    {Start, Gen} = erx_net_rand:uniform(?IDENTS, erx_net_rand:new(erx_net_clock:entropy(16))),
    case bind(Start, ?IDENTS, #{pid => self(), credit => Credit}) of
        {ok, Ident} ->
            ok = erx_net_tables:watch_holder(self()),
            {ok, #state{owner = monitor(process, Owner), ident = Ident, credit = Credit, gen = Gen}};
        {error, Reason} ->
            {stop, Reason}
    end.

-doc false.
handle_call({send, <<_:32>> = Dst, Seq, #{data := Data} = Opts}, _From, S0)
  when is_integer(Seq), Seq >= 0, Seq =< 16#ffff, is_binary(Data) ->
    case send_options(Opts) of
        true ->
            {Reply, S} = transmit(Dst, Seq, Opts, configured(S0)),
            {reply, Reply, S};
        false ->
            {reply, {error, einval}, S0}
    end;
handle_call({recv, Timeout}, _From, #state{waiter = {_, _}} = S) when ?IS_TIMEOUT(Timeout) ->
    {reply, {error, einval}, S};
handle_call({recv, Timeout}, From, S) when ?IS_TIMEOUT(Timeout) ->
    Deadline = case Timeout of
                   infinity -> infinity;
                   Ms -> erx_net_clock:now() + Ms * 1000
               end,
    {noreply, arm(serve(S#state{waiter = {From, Deadline}}))};
handle_call(close, _From, #state{ident = Ident} = S) ->
    ok = erx_net_bind:delete(key(Ident)),
    {stop, normal, ok, S};
handle_call(_Request, _From, S) ->
    {reply, {error, einval}, S}.

%% A send's options: the data alone, or the data and a TTL from 1 to 255.
send_options(#{ttl := Ttl} = Opts) ->
    map_size(Opts) =:= 2 andalso is_integer(Ttl) andalso Ttl >= 1 andalso Ttl =< 255;
send_options(Opts) ->
    map_size(Opts) =:= 1.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

-doc false.
handle_info({items, _If, Items}, #state{queue = Queue} = S) ->
    {noreply, arm(serve(S#state{queue = queue:join(Queue, queue:from_list(Items))}))};
handle_info({erx_net_clock, hint}, S) ->
    {noreply, arm(serve(S#state{armed = infinity}))};
handle_info({'DOWN', Ref, process, _, _}, #state{owner = Ref, ident = Ident} = S) ->
    ok = erx_net_bind:delete(key(Ident)),
    {stop, normal, S};
handle_info(_Msg, S) ->
    {noreply, S}.

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

%% Answers a waiting recv/2 with the next reply, or with a timeout past its deadline.
serve(#state{waiter = none} = S) ->
    S;
serve(#state{waiter = {From, Deadline}, queue = Queue0, credit = Credit} = S) ->
    case queue:out(Queue0) of
        {{value, {echo_reply, Src, Ttl, _Ident, Seq, Data}}, Queue} ->
            ok = erx_net_credit:take(Credit, 1),
            gen_server:reply(From, {ok, {tuple(Src), Ttl, Seq, compact(Data)}}),
            S#state{queue = Queue, waiter = none};
        {empty, _} when Deadline =/= infinity ->
            case erx_net_clock:now() >= Deadline of
                true ->
                    gen_server:reply(From, {error, timeout}),
                    S#state{waiter = none};
                false ->
                    S
            end;
        {empty, _} ->
            S
    end.

arm(#state{waiter = {_, Deadline}, armed = Armed} = S) when is_integer(Deadline) ->
    S#state{armed = erx_net_clock:arm_by(Deadline, Armed)};
arm(S) ->
    S.

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
