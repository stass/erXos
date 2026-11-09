%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_tcp).
-moduledoc """
The TCP socket backend (docs/design-network-stack.md, "The backend"). A socket is
`{'$inet', erx_gen_tcp, Pid}`, `Pid` its connection, so `gen_tcp:send/2`, `recv/2,3`,
`shutdown/2`, `close/1` and `inet:setopts/2`, `getopts/2`, `sockname/1` and `peername/1`
reach this module through the dispatch they already have. On stock OTP, whose `inet`
knows no `erx` backend, a caller opens the socket with `connect/4` here.

Each call is one request to one process: `connect` to the grant erx_inet:grant/0 finds,
the rest to the connection. Every request waits with the
timeout `infinity`, since a `recv` timeout is a deadline the connection enforces. A
connection that has ended answers as a closed socket does, `{error, closed}`, and closing
it again is `ok`.

Only IPv4 is taken: a host name given to `connect/4` resolves through inet's own path
(inet_db's lookup methods, the hosts file and then DNS) to its IPv4 addresses, which are
tried in order within the one timeout. Only the options the connection knows (`binary`,
`list`, `mode`, `active`, `nodelay`, `{packet, raw}`) are taken. What the backend does not
offer fails with `enotsup`: `listen/2`, `fdopen/2`, `connect/3` with a socket-address map
and `controlling_process/2`.
""".

-export([connect/3, connect/4, listen/2, fdopen/2, send/2, recv/2, recv/3, shutdown/2, close/1, controlling_process/2,
         setopts/2, getopts/2, sockname/1, peername/1]).

-export_type([socket/0]).

-type socket() :: {'$inet', erx_gen_tcp, pid()}.

-doc "Connects to `Address`, port `Port`, with `gen_tcp:connect/4`'s arguments.".
-spec connect(inet:ip4_address() | inet:hostname(), inet:port_number(), [term()], timeout()) ->
          {ok, socket()} | {error, term()}.
connect({_, _, _, _} = Address, Port, Opts, Timeout) when is_list(Opts) ->
    connect_one(Address, Port, Opts, Timeout);
connect(Host, Port, Opts, Timeout) when (is_list(Host) orelse is_atom(Host)), is_list(Opts) ->
    Timer = inet:start_timer(Timeout),
    try
        case inet:getaddrs_tm(Host, inet, Timer) of
            {ok, Addresses} -> connect_each(Addresses, Port, Opts, Timer, {error, nxdomain});
            {error, _} = Error -> Error
        end
    after
        _ = inet:stop_timer(Timer)
    end;
connect(_Address, _Port, _Opts, _Timeout) ->
    {error, einval}.

%% Tries each address in turn, as gen_tcp's own backend does: a refusal or an unreachable
%% address moves on to the next, while a bad argument or the timeout ends the attempt.
connect_each([Address | Rest], Port, Opts, Timer, _Last) ->
    case connect_one(Address, Port, Opts, inet:timeout(Timer)) of
        {ok, _} = Ok -> Ok;
        {error, Reason} = Error when Reason =:= einval; Reason =:= timeout -> Error;
        {error, _} = Error -> connect_each(Rest, Port, Opts, Timer, Error)
    end;
connect_each([], _Port, _Opts, _Timer, Last) ->
    Last.

connect_one(Address, Port, Opts, Timeout) ->
    maybe
        {ok, Grant} ?= erx_inet:grant(),
        call(Grant, {tcp_connect, inet, Address, Port, Opts, Timeout})
    end.

-doc "Not offered by this backend, which answers `enotsup`: a socket-address map, `gen_tcp:connect/3`'s first form.".
-spec connect(map(), [term()], timeout()) -> {error, enotsup}.
connect(SockAddr, _Opts, _Timeout) when is_map(SockAddr) ->
    {error, enotsup}.

-doc "Not offered by this backend, which answers `enotsup`: the grant opens no listening socket.".
-spec listen(inet:port_number(), [term()]) -> {error, enotsup}.
listen(_Port, _Opts) ->
    {error, enotsup}.

-doc "Not offered by this backend: erXos has no file descriptor of a socket to take.".
-spec fdopen(non_neg_integer(), [term()]) -> {error, enotsup}.
fdopen(_Fd, _Opts) ->
    {error, enotsup}.

-doc "Sends `Data`; returns once it is in the connection's send buffer.".
-spec send(socket(), iodata()) -> ok | {error, term()}.
send({'$inet', ?MODULE, Conn}, Data) ->
    call(Conn, {send, iolist_to_binary(Data)}).

-doc "Receives `Length` bytes (0 for what is there) from a passive socket.".
-spec recv(socket(), non_neg_integer()) -> {ok, binary() | string()} | {error, term()}.
recv(Socket, Length) ->
    recv(Socket, Length, infinity).

-doc "Receives as `recv/2`, waiting at most `Timeout` milliseconds.".
-spec recv(socket(), non_neg_integer(), timeout()) -> {ok, binary() | string()} | {error, term()}.
recv({'$inet', ?MODULE, Conn}, Length, Timeout) ->
    call(Conn, {recv, Length, Timeout}).

-doc "Shuts down one or both directions.".
-spec shutdown(socket(), read | write | read_write) -> ok | {error, term()}.
shutdown({'$inet', ?MODULE, Conn}, How) ->
    call(Conn, {shutdown, How}).

-doc "Closes the socket; the connection sends its FIN and ends on its own.".
-spec close(socket()) -> ok.
close({'$inet', ?MODULE, Conn}) ->
    case call(Conn, close) of
        ok -> ok;
        {error, closed} -> ok
    end.

-doc "Not offered by this backend: answers `enotsup`.".
-spec controlling_process(socket(), pid()) -> {error, enotsup}.
controlling_process({'$inet', ?MODULE, _Conn}, Pid) when is_pid(Pid) ->
    {error, enotsup}.

-doc "Sets the options the connection knows.".
-spec setopts(socket(), [term()]) -> ok | {error, term()}.
setopts({'$inet', ?MODULE, Conn}, Opts) ->
    call(Conn, {setopts, Opts}).

-doc "The values of the named options the connection knows.".
-spec getopts(socket(), [atom()]) -> {ok, [{atom(), term()}]} | {error, term()}.
getopts({'$inet', ?MODULE, Conn}, Names) ->
    call(Conn, {getopts, Names}).

-doc "The local address and port.".
-spec sockname(socket()) -> {ok, {inet:ip4_address(), inet:port_number()}} | {error, term()}.
sockname({'$inet', ?MODULE, Conn}) ->
    call(Conn, sockname).

-doc "The remote address and port.".
-spec peername(socket()) -> {ok, {inet:ip4_address(), inet:port_number()}} | {error, term()}.
peername({'$inet', ?MODULE, Conn}) ->
    call(Conn, peername).

%% A request to a process that has ended, however it ended, answers as a closed socket, so
%% no crash reason of the stack reaches the caller.
call(Pid, Request) ->
    try
        gen_server:call(Pid, Request, infinity)
    catch
        exit:_ ->
            {error, closed}
    end.
