%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_udp).
-moduledoc """
The UDP socket backend and the datagram socket process (docs/design-network-stack.md,
"The backend", "The socket process"). A socket is `{'$inet', erx_gen_udp, Pid}`, `Pid`
its socket process, a `gen_statem` in the owner's own domain, so `gen_udp:connect/3`,
`send/2,3,4`, `recv/2,3`, `close/1` and `inet:setopts/2`, `getopts/2` and `sockname/1`
reach this module through the dispatch they already have, and `gen_udp:open/2` reaches
it through `inet:gen_udp_module/1` for the `erx` backend. On stock OTP, whose `inet`
knows no `erx` backend, a caller opens the socket with `open/2` here. erx_gen_icmp's echo
socket runs the same socket process, of kind `icmp`.

**The stub.** Each function here is a local call of the socket process, waiting with
`infinity`, since a `recv` timeout is a deadline the socket process keeps. A socket
process of another node, which is another domain's, is refused with `{error, einval}`
before anything is sent; one that has ended answers as a closed socket, `{error,
closed}`, and closing it again is `ok`.

**The socket process.** The one party that talks to the datagram socket, and the one that
talks to the owner about it. open/2 starts it, owned by the caller; in `opening` it asks
the grant for the socket through erx_inet:open/1, which checks the answer, and keeps the
origin the grant was found with. From then on, in `open`, it talks to the socket only in
the socket protocol, `{erx_net, Sender, Body}`: it sends requests and credit, and takes
the socket's replies and datagrams through erx_sock_admit:push/4, which leaves out
(`unknown`, dropped and counted) what is not its socket's from the socket's domain. What
to send, present and answer is decided by erx_gen_udp_core's pure step; this module
performs its actions in order and arms its one timer, a waiting recv's deadline. It
monitors its owner, whose exit closes the socket, and its socket. It is started without
`{erx_serve, any}`, so no call from another domain reaches it.

Only IPv4 is taken: `inet6` and `local` are refused with `eafnosupport`. Port -1, OTP's
private request for a port drawn more randomly than an ephemeral one, is an ephemeral
port here, since the stack draws every ephemeral port at random (erx_net_bind). The
options taken are the socket process's own, `binary`, `list`, `mode` and `active`, and
the local address `ip` (or `ifaddr`); any other is refused with `einval`.
`controlling_process/2` is not offered and answers `enotsup`.
""".

-behaviour(gen_statem).

-export([open/1, open/2, connect/3, send/2, send/3, send/4, recv/2, recv/3, close/1,
         setopts/2, getopts/2, sockname/1, controlling_process/2]).
-export([start/2, call/2]).
-export([init/1, callback_mode/0, handle_event/4, format_status/1]).

-export_type([socket/0]).

-type socket() :: {'$inet', erx_gen_udp, pid()}.

-doc "Opens a socket bound to `Port`, with gen_udp's default options.".
-spec open(integer()) -> {ok, socket()} | {error, term()}.
open(Port) ->
    open(Port, []).

-doc "Opens a socket bound to `Port` with `gen_udp:open/2`'s options.".
-spec open(integer(), list()) -> {ok, socket()} | {error, term()}.
open(Port, Opts) when is_integer(Port), Port >= -1, Port =< 16#ffff, is_list(Opts) ->
    maybe
        {ok, Local, Rest} ?= local(Opts, any, []),
        {ok, Own, []} ?= own(erx_gen_tcp_core:options(Rest, #{mode => list, active => true})),
        {ok, Pid} ?= start(udp, {{udp_open, inet, Local, max(Port, 0), []}, Own}),
        {ok, {'$inet', ?MODULE, Pid}}
    end;
open(_Port, _Opts) ->
    {error, einval}.

%% The family and the local address, which the grant takes apart from the options.
local([], Local, Rest) -> {ok, Local, lists:reverse(Rest)};
local([inet | Opts], Local, Rest) -> local(Opts, Local, Rest);
local([Family | _], _, _) when Family =:= inet6; Family =:= local -> {error, eafnosupport};
local([{Key, {_, _, _, _} = Ip} | Opts], _, Rest) when Key =:= ip; Key =:= ifaddr ->
    local(Opts, Ip, Rest);
local([Opt | Opts], Local, Rest) -> local(Opts, Local, [Opt | Rest]).

%% The socket process's own options; one it does not keep is refused, since the
%% datagram socket takes none.
own({ok, Own, []}) -> {ok, Own, []};
own(_) -> {error, einval}.

-doc """
Starts a socket process of kind `Kind`, owned by the caller, which opens its socket with
the grant's `Request` and presents with `Own`; answers its pid once the socket is open.
erx_gen_icmp opens its echo socket so.
""".
-spec start(erx_gen_udp_core:kind(), {term(), map()}) -> {ok, pid()} | {error, term()}.
start(Kind, {Request, Own}) ->
    {ok, Pid} = gen_statem:start(?MODULE, {self(), Kind}, []),
    case call(Pid, {open, Request, Own}) of
        ok -> {ok, Pid};
        {error, _} = Error -> Error
    end.

-doc """
Connects the socket to `Address`, port `Port`: sends go there, and datagrams from elsewhere
arriving after the connect are dropped; those queued before it stay, as on FreeBSD.
""".
-spec connect(socket(), inet:ip4_address(), inet:port_number()) -> ok | {error, term()}.
connect({'$inet', ?MODULE, Pid}, Address, Port) ->
    call(Pid, {connect, Address, Port}).

-doc "Sends `Packet` to the connected peer.".
-spec send(socket(), iodata()) -> ok | {error, term()}.
send({'$inet', ?MODULE, Pid}, Packet) ->
    with_binary(Packet, fun(Bin) -> call(Pid, {send, Bin}) end).

-doc "Sends `Packet` to `{Address, Port}`.".
-spec send(socket(), {inet:ip4_address(), inet:port_number()}, iodata()) -> ok | {error, term()}.
send(S, {Address, Port}, Packet) ->
    send(S, Address, Port, Packet).

-doc "Sends `Packet` to `Address`, port `Port`.".
-spec send(socket(), inet:ip4_address(), inet:port_number(), iodata()) -> ok | {error, term()}.
send({'$inet', ?MODULE, Pid}, Address, Port, Packet) ->
    with_binary(Packet, fun(Bin) -> call(Pid, {send_to, Address, Port, Bin}) end).

with_binary(Packet, Fun) ->
    try iolist_to_binary(Packet) of
        Bin -> Fun(Bin)
    catch
        error:badarg -> {error, einval}
    end.

-doc "Receives a datagram from a passive socket; `Length` is ignored, as on stock.".
-spec recv(socket(), non_neg_integer()) ->
          {ok, {inet:ip4_address(), inet:port_number(), binary() | string()}} | {error, term()}.
recv(S, Length) ->
    recv(S, Length, infinity).

-doc "Receives as `recv/2`, waiting at most `Timeout` milliseconds.".
-spec recv(socket(), non_neg_integer(), timeout()) ->
          {ok, {inet:ip4_address(), inet:port_number(), binary() | string()}} | {error, term()}.
recv({'$inet', ?MODULE, Pid}, _Length, Timeout) ->
    call(Pid, {recv, Timeout}).

-doc "Closes the socket, giving up its port.".
-spec close(socket()) -> ok.
close({'$inet', ?MODULE, Pid}) ->
    case call(Pid, close) of
        ok -> ok;
        {error, _} -> ok
    end.

-doc "Sets the socket process's own options, `active` and `mode`.".
-spec setopts(socket(), [term()]) -> ok | {error, term()}.
setopts({'$inet', ?MODULE, Pid}, Opts) ->
    call(Pid, {setopts, Opts}).

-doc "The values of the named options, `active` and `mode`.".
-spec getopts(socket(), [atom()]) -> {ok, [{atom(), term()}]} | {error, term()}.
getopts({'$inet', ?MODULE, Pid}, Names) ->
    call(Pid, {getopts, Names}).

-doc "The local address and port; an unbound address is `{0, 0, 0, 0}`.".
-spec sockname(socket()) -> {ok, {inet:ip4_address(), inet:port_number()}} | {error, term()}.
sockname({'$inet', ?MODULE, Pid}) ->
    call(Pid, sockname).

-doc "Not offered by this backend: answers `enotsup`.".
-spec controlling_process(socket(), pid()) -> {error, enotsup}.
controlling_process({'$inet', ?MODULE, _Pid}, NewOwner) when is_pid(NewOwner) ->
    {error, enotsup}.

-doc """
A call of a socket process of this node. One that has ended, however it ended, answers as
a closed socket, so no crash reason reaches the caller; one of another node, which is
another domain's, is refused before anything is sent.
""".
-spec call(pid(), term()) -> term().
call(Pid, Request) when is_pid(Pid), node(Pid) =:= node() ->
    try
        gen_statem:call(Pid, Request, infinity)
    catch
        exit:_ ->
            {error, closed}
    end;
call(_Pid, _Request) ->
    {error, einval}.

%% --- The socket process ----------------------------------------------------------

-record(data, {owner :: pid(),
               owner_ref :: reference(),
               kind :: erx_gen_udp_core:kind(),
               sock = none :: pid() | none,          % the datagram or echo socket, once open
               sock_ref = none :: reference() | none,
               origin = local :: erx_sock_admit:origin(),
               core = none :: erx_gen_udp_core:core() | none,
               counters = #{} :: #{atom() => pos_integer()}}).

-doc false.
callback_mode() ->
    handle_event_function.

-doc false.
init({Owner, Kind}) when is_pid(Owner), (Kind =:= udp orelse Kind =:= icmp) ->
    {ok, opening, #data{owner = Owner, owner_ref = erlang:monitor(process, Owner), kind = Kind}}.

-doc false.
handle_event({call, From}, {open, Request, Own}, opening, #data{} = D) ->
    open(erx_inet:open(Request), From, Own, D);
handle_event({call, From}, _Request, opening, _D) ->
    {keep_state_and_data, [{reply, From, {error, einval}}]};
handle_event({call, From}, Request, open, D) ->
    step({call, From, Request}, D);
handle_event(info, {'DOWN', Ref, process, _, _}, opening, #data{owner_ref = Ref}) ->
    {stop, normal};
handle_event(info, {'DOWN', Ref, process, _, _}, open, #data{owner_ref = Ref} = D) ->
    step(owner_down, D);
handle_event(info, {'DOWN', Ref, process, _, _}, open, #data{sock_ref = Ref} = D) ->
    step(socket_down, D);
handle_event({timeout, recv}, expired, open, D) ->
    step(recv_timeout, D);
handle_event(info, Msg, open, #data{kind = Kind, origin = Origin, sock = Sock} = D) ->
    case erx_sock_admit:push(Kind, Origin, Sock, Msg) of
        unknown -> {keep_state, count(unknown, D)};
        Admitted -> step({push, Admitted}, D)
    end;
handle_event(info, _Msg, opening, D) ->
    {keep_state, count(unknown, D)}.

%% A crash report shows the owner, the socket and the counters, never the datagrams held
%% or a message in hand, since both may hold a peer's data.
-doc false.
format_status(Status) ->
    maps:map(fun(data, #data{owner = Owner, sock = Sock, counters = Counters}) ->
                     #{owner => Owner, sock => Sock, counters => Counters};
                (message, _) -> redacted;
                (queue, _) -> [];
                (postponed, _) -> [];
                (log, _) -> [];
                (_, Value) -> Value
             end, Status).

%% The grant's answer to the open, already checked by erx_inet: the socket, which the
%% socket process monitors from now on, and its domain's origin.
open({ok, Sock, Origin}, From, Own, #data{kind = Kind} = D) ->
    {Core, Actions} = erx_gen_udp_core:new({'$inet', ?MODULE, self()}, Kind, Own),
    D1 = D#data{sock = Sock, sock_ref = erlang:monitor(process, Sock), origin = Origin, core = Core},
    gen_statem:reply(From, ok),
    perform(Actions, D1, []);
open({error, _} = Error, From, _Own, _D) ->
    {stop_and_reply, normal, [{reply, From, Error}]}.

step(Event, #data{core = Core0} = D) ->
    {Core, Actions} = erx_gen_udp_core:step(Event, Core0),
    perform(Actions, D#data{core = Core}, []).

%% The core's actions, in order. Messages and replies go at once, so the owner sees them
%% in the order the core made them; the timer becomes a transition action.
perform([], D, Timers) ->
    {next_state, open, D, lists:reverse(Timers)};
perform([stop | _], D, _Timers) ->
    {stop, normal, D};
perform([{request, N, Request} | Rest], #data{sock = Sock} = D, Timers) ->
    Sock ! {erx_net, self(), {call, N, Request}},
    perform(Rest, D, Timers);
perform([{credit, Bytes} | Rest], #data{sock = Sock} = D, Timers) ->
    Sock ! {erx_net, self(), {credit, Bytes}},
    perform(Rest, D, Timers);
perform([{reply, From, Reply} | Rest], D, Timers) ->
    gen_statem:reply(From, Reply),
    perform(Rest, D, Timers);
perform([{tell, Msg} | Rest], #data{owner = Owner} = D, Timers) ->
    Owner ! Msg,
    perform(Rest, D, Timers);
perform([{recv_timer, Ms} | Rest], D, Timers) when Ms =:= cancel; Ms =:= infinity ->
    perform(Rest, D, [{{timeout, recv}, cancel} | Timers]);
perform([{recv_timer, Ms} | Rest], D, Timers) ->
    perform(Rest, D, [{{timeout, recv}, Ms, expired} | Timers]);
perform([{count, Check} | Rest], #data{kind = Kind} = D, Timers) ->
    logger:warning("erx_gen_udp: the ~s socket's push fails the ~s check", [Kind, Check]),
    perform(Rest, count(Check, D), Timers).

count(Name, #data{counters = Counters} = D) ->
    D#data{counters = maps:update_with(Name, fun(N) -> N + 1 end, 1, Counters)}.
