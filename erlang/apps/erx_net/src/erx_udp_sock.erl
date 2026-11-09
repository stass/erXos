%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_udp_sock).
-moduledoc """
A UDP socket (docs/design-network-stack.md, "UDP", "Transmitting", "The backend"): the
process holding a bound port's demultiplexing entry, its receive queue and its owner.
erx_gen_udp of erx_net_client reaches it as `{'$inet', erx_gen_udp, Pid}`, after the grant
opened it for the owner (`udp_open`); the stack's own users and tests open it with
open/2. The socket is charged to no grant's account, whose limits are not built, so
erx_net_tables watches it in the grant's place.

**Requests.** `{send_to, Ip, Port, Data}`, `{send, Data}` once connected,
`{connect, Ip, Port}`, `{recv, Timeout}`, `sockname` and `close`, each checked here,
since they may come from another domain: an IPv4 address as a tuple, a port, a binary, a
timeout. Anything else is answered `{error, einval}`.

**Owner.** The socket monitors its owner and closes when the owner ends, as a gen_udp
socket closes with its owning process.

**Receiving.** The socket's credit, one unit per datagram, bounds what interfaces may hand
it; they send `{items, Interface, Items}` with the units reserved. A connected socket
takes only its peer's datagrams, as FreeBSD's `in_pcblookup` finds a connected socket
only for its foreign address and port; the others are dropped and their units taken. In
active mode each datagram goes to the owner as `{udp, Socket, Ip, Port, Data}` at once
and its unit is taken, so, as with `gen_udp`'s `{active, true}`, the owner's mailbox is
bounded only by how fast the owner reads it; in passive mode the datagrams wait, holding
their units, until `{recv, Timeout}` takes them, so the queue never holds more than the
credit's limit. A payload smaller than a quarter of the binary it is part of (a frame, or
a reassembled datagram) is copied out, so a small datagram never keeps a large one alive.
Data is a binary, or a list in `list` mode.

**Sending.** A send builds the datagram's packets over the path the current
configuration gives (`erx_net_frame:path/3`, `udp/5`) and sends them through erx_net_tx,
to the driver or to the interface to resolve. A full credit answers `{error, enobufs}`.

**Timeouts.** `recv`'s timeout is a deadline in the socket's state, armed on
erx_net_clock, so the call itself waits with `infinity`.
""".

-behaviour(gen_server).

-export([open/2, options/1, send/4, recv/2, sockname/1, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([options/0]).

-define(LIMIT_DEFAULT, 64).
-define(MAX_REQUEST, 16).
-define(IS_PORT(P), (is_integer(P) andalso P >= 0 andalso P =< 16#ffff)).
-define(IS_BYTE(X), (is_integer(X) andalso X >= 0 andalso X =< 255)).
-define(IS_IP4(T), (tuple_size(T) =:= 4 andalso ?IS_BYTE(element(1, T)) andalso
                    ?IS_BYTE(element(2, T)) andalso ?IS_BYTE(element(3, T)) andalso
                    ?IS_BYTE(element(4, T)))).
-define(IS_TIMEOUT(T), (T =:= infinity orelse (is_integer(T) andalso T >= 0))).

-record(state, {owner :: pid(),
                socket :: {'$inet', erx_gen_udp, pid()},
                ip :: <<_:32>> | any,
                port :: 0..16#ffff,
                key :: erx_net_input:key(),
                credit :: erx_net_credit:credit(),
                active :: boolean(),
                mode :: binary | list,
                peer = none :: none | {<<_:32>>, 1..16#ffff},
                queue = queue:new() :: queue:queue(term()),
                waiter = none :: none | {gen_server:from(), Deadline :: integer() | infinity},
                gen :: erx_net_rand:gen(),
                config = none :: none | {non_neg_integer(), erx_net_frame:snapshot()},
                armed = infinity :: erx_net_clock:armed()}).

-type options() :: #{ip => inet:ip4_address() | any, active => boolean(), mode => binary | list,
                     limit => pos_integer(), owner => pid()}.

%% --- API -------------------------------------------------------------------------

-doc """
Opens a socket bound to `Port` (0 for an ephemeral port), linked to the calling process.
Options: the local address `ip` (`any` when absent), `active` (true when absent), `mode`
(binary when absent), `limit`, the datagrams that may wait (64 when absent), and `owner`,
the process the socket delivers to and ends with (the caller when absent).
""".
-spec open(0..16#ffff, options()) -> {ok, pid()} | {error, term()}.
open(Port, Opts) when ?IS_PORT(Port), is_map(Opts) ->
    gen_server:start_link(?MODULE, {maps:get(owner, Opts, self()), Port, Opts}, []).

-doc """
The options of a gen_udp open list that a socket takes, as open/2's map: `binary`,
`list`, `{mode, binary | list}` and `{active, boolean()}`; gen_udp's default mode is
`list`. Any other option is refused with `einval`.
""".
-spec options(list()) -> {ok, options()} | {error, einval}.
options(List) ->
    options(List, #{mode => list}).

options([], Opts) -> {ok, Opts};
options([binary | Rest], Opts) -> options(Rest, Opts#{mode => binary});
options([list | Rest], Opts) -> options(Rest, Opts#{mode => list});
options([{mode, M} | Rest], Opts) when M =:= binary; M =:= list -> options(Rest, Opts#{mode => M});
options([{active, A} | Rest], Opts) when is_boolean(A) -> options(Rest, Opts#{active => A});
options(_, _) -> {error, einval}.

-doc "Sends `Data` to `Ip`, port `Port`.".
-spec send(pid(), inet:ip4_address(), 0..16#ffff, iodata()) -> ok | {error, term()}.
send(Sock, Ip, Port, Data) ->
    gen_server:call(Sock, {send_to, Ip, Port, iolist_to_binary(Data)}, infinity).

-doc "Takes the next datagram of a passive socket, waiting at most `Timeout` milliseconds.".
-spec recv(pid(), timeout()) ->
          {ok, {inet:ip4_address(), 0..16#ffff, binary() | string()}} | {error, timeout | einval}.
recv(Sock, Timeout) ->
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
            _ = erlang:monitor(process, Owner),
            {ok, #state{owner = Owner, socket = {'$inet', erx_gen_udp, self()}, ip = Ip,
                        port = Port, key = KeyOf(Port), credit = Credit,
                        active = maps:get(active, Opts, true), mode = maps:get(mode, Opts, binary),
                        gen = Gen}};
        {error, Reason} ->
            {stop, Reason}
    end.

-doc false.
handle_call({send_to, Ip, Port, Data}, _From, S0)
  when ?IS_IP4(Ip), ?IS_PORT(Port), is_binary(Data) ->
    {Reply, S} = transmit(addr(Ip), Port, Data, configured(S0)),
    {reply, Reply, S};
handle_call({send, Data}, _From, #state{peer = {Ip, Port}} = S0) when is_binary(Data) ->
    {Reply, S} = transmit(Ip, Port, Data, configured(S0)),
    {reply, Reply, S};
handle_call({send, Data}, _From, #state{peer = none} = S) when is_binary(Data) ->
    {reply, {error, edestaddrreq}, S};
handle_call({connect, Ip, Port}, _From, S) when ?IS_IP4(Ip), ?IS_PORT(Port), Port > 0 ->
    {reply, ok, S#state{peer = {addr(Ip), Port}}};
handle_call({recv, Timeout}, _From, #state{active = true} = S) when ?IS_TIMEOUT(Timeout) ->
    {reply, {error, einval}, S};
handle_call({recv, Timeout}, _From, #state{waiter = {_, _}} = S) when ?IS_TIMEOUT(Timeout) ->
    {reply, {error, einval}, S};
handle_call({recv, Timeout}, From, S) when ?IS_TIMEOUT(Timeout) ->
    Deadline = case Timeout of
                   infinity -> infinity;
                   Ms -> erx_net_clock:now() + Ms * 1000
               end,
    {noreply, arm(serve(S#state{waiter = {From, Deadline}}))};
handle_call(sockname, _From, #state{ip = Ip, port = Port} = S) ->
    {reply, {ok, {tuple(Ip), Port}}, S};
handle_call(close, _From, #state{key = Key} = S) ->
    ok = erx_net_bind:delete(Key),
    {stop, normal, ok, S};
handle_call(_Request, _From, S) ->
    {reply, {error, einval}, S}.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

-doc false.
handle_info({items, _If, Items0}, #state{credit = Credit} = S0) ->
    {Items, Dropped} = lists:partition(fun(Item) -> from_peer(Item, S0) end, Items0),
    ok = erx_net_credit:take(Credit, length(Dropped)),
    {noreply, deliver(Items, S0)};
handle_info({erx_net_clock, hint}, S) ->
    {noreply, arm(serve(S#state{armed = infinity}))};
handle_info({'DOWN', _, process, Owner, _}, #state{owner = Owner, key = Key} = S) ->
    ok = erx_net_bind:delete(Key),
    {stop, normal, S};
handle_info(_Msg, S) ->
    {noreply, S}.

%% --- Receiving -------------------------------------------------------------------

%% A connected socket's datagrams come from its peer; an unconnected one takes any.
from_peer({datagram, Source, _Dst, _Data}, #state{peer = Peer}) ->
    Peer =:= none orelse Source =:= Peer;
from_peer(_Report, _S) ->
    true.

deliver(Items, #state{active = true, owner = Owner, socket = Socket, credit = Credit} = S) ->
    ok = erx_net_credit:take(Credit, length(Items)),
    [Owner ! {udp, Socket, tuple(Ip), Port, data(Data, S)}
     || {datagram, {Ip, Port}, _Dst, Data} <- Items],
    S;
deliver(Items, #state{queue = Queue} = S) ->
    arm(serve(S#state{queue = queue:join(Queue, queue:from_list(Items))})).

%% Answers a waiting recv with the next datagram, or with a timeout past its deadline.
serve(#state{waiter = none} = S) ->
    S;
serve(#state{waiter = {From, Deadline}, queue = Queue0, credit = Credit} = S) ->
    case queue:out(Queue0) of
        {{value, {datagram, {Ip, Port}, _Dst, Data}}, Queue} ->
            ok = erx_net_credit:take(Credit, 1),
            gen_server:reply(From, {ok, {tuple(Ip), Port, data(Data, S)}}),
            S#state{queue = Queue, waiter = none};
        {{value, _Report}, Queue} ->
            %% An ICMP error for a connected socket: dropped, since the socket reports no errors.
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

data(Data, #state{mode = list}) -> binary_to_list(Data);
data(Data, #state{mode = binary}) -> compact(Data).

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
