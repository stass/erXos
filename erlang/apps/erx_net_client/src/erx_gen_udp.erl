%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_udp).
-moduledoc """
The UDP socket backend (docs/design-network-stack.md, "The backend"), as far as OTP's
resolver, inet_res, needs it. A socket is `{'$inet', erx_gen_udp, Pid}`, `Pid` its
datagram socket in the network stack, so `gen_udp:connect/3`, `send/2,3,4`, `recv/2,3`
and `close/1` reach this module through the dispatch they already have, and
`gen_udp:open/2` reaches it through `inet:gen_udp_module/1` for the `erx` backend. On
stock OTP, whose `inet` knows no `erx` backend, a caller opens the socket with `open/2`
here.

Each call is one request to one process: `open` to the grant erx_inet:grant/0 finds, the
rest to the socket. Every request waits with the timeout `infinity`, since a `recv`
timeout is a deadline the socket enforces. A socket that has ended answers as a closed
socket does, `{error, closed}`, and closing it again is `ok`.

Only IPv4 is taken: `inet6` and `local` are refused with `eafnosupport`. Port -1, OTP's
private request for a port drawn more randomly than an ephemeral one, is an ephemeral
port here, since the stack draws every ephemeral port at random (erx_net_bind). The
options the socket knows are `binary`, `list`, `mode`, `active` and the local address
`ip` (or `ifaddr`); any other is refused with `einval`. Data is delivered as stock's
`{udp, Socket, Ip, Port, Data}` in active mode, and `recv` answers `{ok, {Ip, Port, Data}}`.
""".

-export([open/1, open/2, connect/3, send/2, send/3, send/4, recv/2, recv/3, close/1,
         sockname/1, controlling_process/2]).

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
        {ok, Grant} ?= erx_inet:grant(),
        {ok, Sock} ?= call(Grant, {udp_open, inet, Local, max(Port, 0), Rest}),
        {ok, {'$inet', ?MODULE, Sock}}
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

-doc """
Connects the socket to `Address`, port `Port`: sends go there, and datagrams from elsewhere
arriving after the connect are dropped; those queued before it stay, as on FreeBSD.
""".
-spec connect(socket(), inet:ip4_address(), inet:port_number()) -> ok | {error, term()}.
connect({'$inet', ?MODULE, Sock}, {_, _, _, _} = Address, Port) ->
    call(Sock, {connect, Address, Port});
connect({'$inet', ?MODULE, _Sock}, _Address, _Port) ->
    {error, einval}.

-doc "Sends `Packet` to the connected peer.".
-spec send(socket(), iodata()) -> ok | {error, term()}.
send({'$inet', ?MODULE, Sock}, Packet) ->
    call(Sock, {send, iolist_to_binary(Packet)}).

-doc "Sends `Packet` to `{Address, Port}`.".
-spec send(socket(), {inet:ip4_address(), inet:port_number()}, iodata()) -> ok | {error, term()}.
send(S, {Address, Port}, Packet) ->
    send(S, Address, Port, Packet).

-doc "Sends `Packet` to `Address`, port `Port`.".
-spec send(socket(), inet:ip4_address(), inet:port_number(), iodata()) -> ok | {error, term()}.
send({'$inet', ?MODULE, Sock}, {_, _, _, _} = Address, Port, Packet) ->
    call(Sock, {send_to, Address, Port, iolist_to_binary(Packet)});
send({'$inet', ?MODULE, _Sock}, _Address, _Port, _Packet) ->
    {error, einval}.

-doc "Receives a datagram from a passive socket; `Length` is ignored, as on stock.".
-spec recv(socket(), non_neg_integer()) ->
          {ok, {inet:ip4_address(), inet:port_number(), binary() | string()}} | {error, term()}.
recv(S, Length) ->
    recv(S, Length, infinity).

-doc "Receives as `recv/2`, waiting at most `Timeout` milliseconds.".
-spec recv(socket(), non_neg_integer(), timeout()) ->
          {ok, {inet:ip4_address(), inet:port_number(), binary() | string()}} | {error, term()}.
recv({'$inet', ?MODULE, Sock}, _Length, Timeout) ->
    call(Sock, {recv, Timeout}).

-doc "Closes the socket, giving up its port.".
-spec close(socket()) -> ok.
close({'$inet', ?MODULE, Sock}) ->
    case call(Sock, close) of
        ok -> ok;
        {error, closed} -> ok
    end.

-doc "The local address and port; an unbound address is `{0, 0, 0, 0}`.".
-spec sockname(socket()) -> {ok, {inet:ip4_address(), inet:port_number()}} | {error, term()}.
sockname({'$inet', ?MODULE, Sock}) ->
    case call(Sock, sockname) of
        {ok, {any, Port}} -> {ok, {{0, 0, 0, 0}, Port}};
        Other -> Other
    end.

-doc "Not offered by this backend: answers `enotsup`.".
-spec controlling_process(socket(), pid()) -> {error, enotsup}.
controlling_process({'$inet', ?MODULE, _Sock}, Pid) when is_pid(Pid) ->
    {error, enotsup}.

%% A request to a process that has ended, however it ended, answers as a closed socket, so
%% no crash reason of the stack reaches the caller.
call(Pid, Request) ->
    try
        gen_server:call(Pid, Request, infinity)
    catch
        exit:_ ->
            {error, closed}
    end.
