%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_udp_sock).
-moduledoc """
A UDP socket (docs/design-network-stack.md, "UDP", "Transmitting"): the process holding a
bound port's demultiplexing entry, its receive queue and its owner. Its interface is a
first one, shaped like `gen_udp`'s, which `erx_gen_udp` of erx_net_client will call; the
requests are not yet those of the network service's schema, and the socket belongs to no
grant yet, so erx_net_tables watches it in the grant's place.

**Receiving.** The socket's credit, one unit per datagram, bounds what interfaces may hand
it; they send `{items, Interface, Items}` with the units reserved. In active mode each
datagram goes to the owner as `{udp, Socket, Ip, Port, Data}` at once and its unit is
taken, so, as with `gen_udp`'s `{active, true}`, the owner's mailbox is bounded only by
how fast the owner reads it; in passive mode the datagrams wait, holding their units, until `recv/2` takes them,
so the queue never holds more than the credit's limit. A payload smaller than a quarter of
the binary it is part of (a frame, or a reassembled datagram) is copied out, so a small
datagram never keeps a large one alive.

**Sending.** `send/4` builds the datagram's packets over the path the current
configuration gives (`erx_net_frame:path/3`, `udp/5`) and sends them through erx_net_tx,
to the driver or to the interface to resolve. A full credit answers `{error, enobufs}`.

**Timeouts.** `recv/2`'s timeout is a deadline in the socket's state, armed on
erx_net_clock, so the call itself waits with `infinity`.
""".

-behaviour(gen_server).

-export([open/2, send/4, recv/2, sockname/1, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(LIMIT_DEFAULT, 64).
-define(MAX_REQUEST, 16).

-record(state, {owner :: pid(),
                ip :: <<_:32>> | any,
                port :: 0..16#ffff,
                key :: erx_net_input:key(),
                credit :: erx_net_credit:credit(),
                active :: boolean(),
                queue = queue:new() :: queue:queue(term()),
                waiter = none :: none | {gen_server:from(), Deadline :: integer() | infinity},
                gen :: erx_net_rand:gen(),
                config = none :: none | {non_neg_integer(), erx_net_frame:snapshot()},
                armed = infinity :: erx_net_clock:armed()}).

-type options() :: #{ip => inet:ip4_address() | any, active => boolean(),
                     limit => pos_integer()}.

%% --- API -------------------------------------------------------------------------

-doc """
Opens a socket bound to `Port` (0 for an ephemeral port) for the calling process, linked
to it. Options: the local address `ip` (`any` when absent), `active` (true when absent) and
`limit`, the datagrams that may wait (64 when absent).
""".
-spec open(0..16#ffff, options()) -> {ok, pid()} | {error, term()}.
open(Port, Opts) when is_integer(Port), Port >= 0, Port =< 16#ffff, is_map(Opts) ->
    gen_server:start_link(?MODULE, {self(), Port, Opts}, []).

-doc "Sends `Data` to `Ip`, port `Port`.".
-spec send(pid(), inet:ip4_address(), 0..16#ffff, iodata()) -> ok | {error, term()}.
send(Sock, {_, _, _, _} = Ip, Port, Data) when is_integer(Port), Port >= 0, Port =< 16#ffff ->
    gen_server:call(Sock, {send, addr(Ip), Port, Data}, infinity).

-doc "Takes the next datagram of a passive socket, waiting at most `Timeout` milliseconds.".
-spec recv(pid(), timeout()) ->
          {ok, {inet:ip4_address(), 0..16#ffff, binary()}} | {error, timeout | einval}.
recv(Sock, Timeout) when Timeout =:= infinity; is_integer(Timeout), Timeout >= 0 ->
    gen_server:call(Sock, {recv, Timeout}, infinity).

-doc "The address and port the socket is bound to.".
-spec sockname(pid()) -> {ok, {inet:ip4_address() | any, 0..16#ffff}}.
sockname(Sock) ->
    gen_server:call(Sock, sockname, infinity).

-doc "Closes the socket, giving up its port.".
-spec close(pid()) -> ok.
close(Sock) ->
    gen_server:call(Sock, close, infinity).

%% --- gen_server ------------------------------------------------------------------

-doc false.
init({Owner, Port0, Opts}) ->
    ok = (erx_net_sup:runtime()):serve(?MAX_REQUEST),
    Ip = case maps:get(ip, Opts, any) of
             any -> any;
             Tuple -> addr(Tuple)
         end,
    Credit = erx_net_credit:new(maps:get(limit, Opts, ?LIMIT_DEFAULT)),
    Entry = #{pid => self(), credit => Credit},
    Gen0 = erx_net_rand:new(erx_net_clock:entropy(16)),
    KeyOf = fun(P) -> {udp, inet, Ip, P} end,
    {Bound, Gen} =
        case Port0 of
            0 ->
                {Start, Gen1} = erx_net_bind:ephemeral_start(Gen0),
                {erx_net_bind:insert_ephemeral(KeyOf, Start, self(), Entry), Gen1};
            _ ->
                {case erx_net_bind:insert(KeyOf(Port0), self(), Entry) of
                     ok -> {ok, Port0};
                     Error -> Error
                 end, Gen0}
        end,
    case Bound of
        {ok, Port} ->
            ok = erx_net_tables:watch_holder(self()),
            {ok, #state{owner = Owner, ip = Ip, port = Port, key = KeyOf(Port), credit = Credit,
                        active = maps:get(active, Opts, true), gen = Gen}};
        {error, Reason} ->
            {stop, Reason}
    end.

-doc false.
handle_call({send, Dst, Dport, Data}, _From, S0) ->
    {Reply, S} = transmit(Dst, Dport, Data, configured(S0)),
    {reply, Reply, S};
handle_call({recv, _Timeout}, _From, #state{active = true} = S) ->
    {reply, {error, einval}, S};
handle_call({recv, _Timeout}, _From, #state{waiter = {_, _}} = S) ->
    {reply, {error, einval}, S};
handle_call({recv, Timeout}, From, S) ->
    Deadline = case Timeout of
                   infinity -> infinity;
                   Ms -> erx_net_clock:now() + Ms * 1000
               end,
    {noreply, arm(serve(S#state{waiter = {From, Deadline}}))};
handle_call(sockname, _From, #state{ip = Ip, port = Port} = S) ->
    {reply, {ok, {tuple(Ip), Port}}, S};
handle_call(close, _From, #state{key = Key} = S) ->
    ok = erx_net_bind:delete(Key),
    {stop, normal, ok, S}.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

-doc false.
handle_info({items, _If, Items}, #state{active = true, owner = Owner, credit = Credit} = S) ->
    ok = erx_net_credit:take(Credit, length(Items)),
    [Owner ! {udp, self(), tuple(Ip), Port, compact(Data)}
     || {datagram, {Ip, Port}, _Dst, Data} <- Items],
    {noreply, S};
handle_info({items, _If, Items}, #state{queue = Queue} = S) ->
    {noreply, arm(serve(S#state{queue = queue:join(Queue, queue:from_list(Items))}))};
handle_info({erx_net_clock, hint}, S) ->
    {noreply, arm(serve(S#state{armed = infinity}))};
handle_info(_Msg, S) ->
    {noreply, S}.

%% --- Receiving -------------------------------------------------------------------

%% Answers a waiting recv/2 with the next datagram, or with a timeout past its deadline.
serve(#state{waiter = none} = S) ->
    S;
serve(#state{waiter = {From, Deadline}, queue = Queue0, credit = Credit} = S) ->
    case queue:out(Queue0) of
        {{value, {datagram, {Ip, Port}, _Dst, Data}}, Queue} ->
            ok = erx_net_credit:take(Credit, 1),
            gen_server:reply(From, {ok, {tuple(Ip), Port, compact(Data)}}),
            S#state{queue = Queue, waiter = none};
        {{value, _Report}, Queue} ->
            %% An ICMP error for a connected socket: no socket connects yet.
            ok = erx_net_credit:take(Credit, 1),
            serve(S#state{queue = Queue});
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

tuple(any) -> any;
tuple(<<A, B, C, D>>) -> {A, B, C, D}.
