%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_tcp).
-moduledoc """
The TCP socket backend and its socket process (docs/design-network-stack.md, "The
backend", "The socket process"). A socket is `{'$inet', erx_gen_tcp, Pid}`, `Pid` its
socket process, a `gen_statem` in the owner's own domain, so `gen_tcp:send/2`,
`recv/2,3`, `shutdown/2`, `close/1` and `inet:setopts/2`, `getopts/2`, `sockname/1` and
`peername/1` reach this module through the dispatch they already have. On stock OTP,
whose `inet` knows no `erx` backend, a caller opens the socket with `connect/4` here.

**The stub.** Each function here is a local call of the socket process, waiting with
`infinity`, since a `recv` timeout is a deadline the socket process keeps. A socket
process of another node, which is another domain's, is refused with `{error, einval}`
before anything is sent; one that has ended answers as a closed socket, `{error,
closed}`, and closing it again is `ok`.

**The socket process.** The one party that talks to the connection, and the one that
talks to the owner about it. `connect/4` starts it, owned by the caller; in `opening`
it asks the grant for the connection through erx_inet:open/1, which checks the answer,
and keeps the origin the grant was found with. From then on, in `open`, it talks to the
connection only in the socket protocol, `{erx_net, Sender, Body}`: it sends requests and
credit, and takes the connection's replies and pushes through erx_sock_admit:push/3,
which leaves out (`unknown`, dropped and counted) what is not its connection's from the
connection's domain. What to send, present and answer is decided by erx_gen_tcp_core's
pure step; this module performs its actions in order and arms its one timer, a waiting
recv's deadline. It monitors its owner, whose exit closes the socket, and its
connection, whose exit without a last push is `econnaborted`. It is started without
`{erx_serve, any}`, so no call from another domain reaches it.

Only IPv4 is taken: a host name given to `connect/4` resolves through inet's own path
(inet_db's lookup methods, the hosts file and then DNS) to its IPv4 addresses, which are
tried in order within the one timeout, each by a socket process of its own. The options
taken are the socket process's own (`binary`, `list`, `mode`, `active`, `{packet, raw}`)
and the connection's `nodelay`. What the backend does not offer fails with `enotsup`:
`listen/2`, `fdopen/2`, `connect/3` with a socket-address map and
`controlling_process/2`.
""".

-behaviour(gen_statem).

-export([connect/3, connect/4, listen/2, fdopen/2, send/2, recv/2, recv/3, shutdown/2, close/1, controlling_process/2,
         setopts/2, getopts/2, sockname/1, peername/1]).
-export([init/1, callback_mode/0, handle_event/4, format_status/1]).

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
%% address moves on to the next, while a bad argument, the timeout or an answer of the
%% grant that fails its check (badarg) ends the attempt.
connect_each([Address | Rest], Port, Opts, Timer, _Last) ->
    case connect_one(Address, Port, Opts, inet:timeout(Timer)) of
        {ok, _} = Ok -> Ok;
        {error, Reason} = Error when Reason =:= einval; Reason =:= timeout; Reason =:= badarg -> Error;
        {error, _} = Error -> connect_each(Rest, Port, Opts, Timer, Error)
    end;
connect_each([], _Port, _Opts, _Timer, Last) ->
    Last.

%% A socket process for one address, owned by the caller; it ends by itself when the
%% connect fails.
connect_one(Address, Port, Opts, Timeout) ->
    {ok, Pid} = gen_statem:start(?MODULE, self(), []),
    case call(Pid, {connect, Address, Port, Opts, Timeout}) of
        ok -> {ok, {'$inet', ?MODULE, Pid}};
        {error, _} = Error -> Error
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

-doc "Sends `Data`; returns once its last piece is in the connection's send buffer.".
-spec send(socket(), iodata()) -> ok | {error, term()}.
send({'$inet', ?MODULE, Pid}, Data) ->
    try iolist_to_binary(Data) of
        Bin -> call(Pid, {send, Bin})
    catch
        error:badarg -> {error, einval}
    end.

-doc "Receives `Length` bytes (0 for what is there) from a passive socket.".
-spec recv(socket(), non_neg_integer()) -> {ok, binary() | string()} | {error, term()}.
recv(Socket, Length) ->
    recv(Socket, Length, infinity).

-doc "Receives as `recv/2`, waiting at most `Timeout` milliseconds.".
-spec recv(socket(), non_neg_integer(), timeout()) -> {ok, binary() | string()} | {error, term()}.
recv({'$inet', ?MODULE, Pid}, Length, Timeout) ->
    call(Pid, {recv, Length, Timeout}).

-doc "Shuts down one or both directions.".
-spec shutdown(socket(), read | write | read_write) -> ok | {error, term()}.
shutdown({'$inet', ?MODULE, Pid}, How) ->
    call(Pid, {shutdown, How}).

-doc "Closes the socket; the connection sends its FIN and ends on its own.".
-spec close(socket()) -> ok.
close({'$inet', ?MODULE, Pid}) ->
    case call(Pid, close) of
        ok -> ok;
        {error, _} -> ok
    end.

-doc "Not offered by this backend: answers `enotsup`.".
-spec controlling_process(socket(), pid()) -> {error, enotsup}.
controlling_process({'$inet', ?MODULE, _Pid}, NewOwner) when is_pid(NewOwner) ->
    {error, enotsup}.

-doc "Sets options: the socket process's own, and `nodelay` on the connection.".
-spec setopts(socket(), [term()]) -> ok | {error, term()}.
setopts({'$inet', ?MODULE, Pid}, Opts) ->
    call(Pid, {setopts, Opts}).

-doc "The values of the named options the socket process and the connection know.".
-spec getopts(socket(), [atom()]) -> {ok, [{atom(), term()}]} | {error, term()}.
getopts({'$inet', ?MODULE, Pid}, Names) ->
    call(Pid, {getopts, Names}).

-doc "The local address and port.".
-spec sockname(socket()) -> {ok, {inet:ip4_address(), inet:port_number()}} | {error, term()}.
sockname({'$inet', ?MODULE, Pid}) ->
    call(Pid, sockname).

-doc "The remote address and port.".
-spec peername(socket()) -> {ok, {inet:ip4_address(), inet:port_number()}} | {error, term()}.
peername({'$inet', ?MODULE, Pid}) ->
    call(Pid, peername).

%% A call of a socket process of this node. One that has ended, however it ended, answers
%% as a closed socket, so no crash reason reaches the caller; one of another node, which
%% is another domain's, is refused before anything is sent.
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
               conn = none :: pid() | none,          % the connection, once open
               conn_ref = none :: reference() | none,
               origin = local :: erx_sock_admit:origin(),
               core = none :: erx_gen_tcp_core:core() | none,
               counters = #{} :: #{atom() => pos_integer()}}).

-doc false.
callback_mode() ->
    handle_event_function.

-doc false.
init(Owner) when is_pid(Owner) ->
    {ok, opening, #data{owner = Owner, owner_ref = erlang:monitor(process, Owner)}}.

-doc false.
handle_event({call, From}, {connect, Address, Port, Opts, Timeout}, opening, #data{} = D) ->
    case erx_gen_tcp_core:options(Opts, #{mode => list, active => true}) of
        {ok, Own, Fwd} -> open(erx_inet:open({tcp_connect, inet, Address, Port, Fwd, Timeout}), From, Own, D);
        {error, _} = Error -> {stop_and_reply, normal, [{reply, From, Error}]}
    end;
handle_event({call, From}, _Request, opening, _D) ->
    {keep_state_and_data, [{reply, From, {error, einval}}]};
handle_event({call, From}, Request, open, D) ->
    step({call, From, Request}, D);
handle_event(info, {'DOWN', Ref, process, _, _}, _State, #data{owner_ref = Ref} = D) ->
    owner_down(D);
handle_event(info, {'DOWN', Ref, process, _, _}, open, #data{conn_ref = Ref} = D) ->
    step(socket_down, D);
handle_event({timeout, recv}, expired, open, D) ->
    step(recv_timeout, D);
handle_event(info, Msg, open, #data{origin = Origin, conn = Conn} = D) ->
    case erx_sock_admit:push(tcp, Origin, Conn, Msg) of
        unknown -> {keep_state, count(unknown, D)};
        Admitted -> step({push, Admitted}, D)
    end;
handle_event(info, _Msg, opening, D) ->
    {keep_state, count(unknown, D)}.

%% A crash report shows the owner, the connection and the counters, never the bytes held
%% or a message in hand, since both may hold the peer's data.
-doc false.
format_status(Status) ->
    maps:map(fun(data, #data{owner = Owner, conn = Conn, counters = Counters}) ->
                     #{owner => Owner, conn => Conn, counters => Counters};
                (message, _) -> redacted;
                (queue, _) -> [];
                (postponed, _) -> [];
                (log, _) -> [];
                (_, Value) -> Value
             end, Status).

%% The grant's answer to the connect, already checked by erx_inet: the connection, which
%% the socket process monitors from now on, and its domain's origin.
open({ok, Conn, Origin}, From, Own, D) ->
    {Core, Actions} = erx_gen_tcp_core:new({'$inet', ?MODULE, self()}, Own),
    D1 = D#data{conn = Conn, conn_ref = erlang:monitor(process, Conn), origin = Origin, core = Core},
    gen_statem:reply(From, ok),
    perform(Actions, D1, []);
open({error, _} = Error, From, _Own, _D) ->
    {stop_and_reply, normal, [{reply, From, Error}]}.

owner_down(#data{core = none}) ->
    {stop, normal};
owner_down(D) ->
    step(owner_down, D).

step(Event, #data{core = Core0} = D) ->
    {Core, Actions} = erx_gen_tcp_core:step(Event, Core0),
    perform(Actions, D#data{core = Core}, []).

%% The core's actions, in order. Messages and replies go at once, so the owner sees them
%% in the order the core made them; the timer becomes a transition action.
perform([], D, Timers) ->
    {next_state, open, D, lists:reverse(Timers)};
perform([stop | _], D, _Timers) ->
    {stop, normal, D};
perform([{request, N, Request} | Rest], #data{conn = Conn} = D, Timers) ->
    Conn ! {erx_net, self(), {call, N, Request}},
    perform(Rest, D, Timers);
perform([{credit, Bytes} | Rest], #data{conn = Conn} = D, Timers) ->
    Conn ! {erx_net, self(), {credit, Bytes}},
    perform(Rest, D, Timers);
perform([{reply, From, Reply} | Rest], D, Timers) ->
    gen_statem:reply(From, Reply),
    perform(Rest, D, Timers);
perform([{tell, Msg} | Rest], #data{owner = Owner} = D, Timers) ->
    Owner ! Msg,
    perform(Rest, D, Timers);
perform([{recv_timer, cancel} | Rest], D, Timers) ->
    perform(Rest, D, [{{timeout, recv}, cancel} | Timers]);
perform([{recv_timer, Ms} | Rest], D, Timers) ->
    perform(Rest, D, [{{timeout, recv}, Ms, expired} | Timers]);
perform([{count, Check} | Rest], D, Timers) ->
    logger:warning("erx_gen_tcp: the connection's push fails the ~s check", [Check]),
    perform(Rest, count(Check, D), Timers).

count(Name, #data{counters = Counters} = D) ->
    D#data{counters = maps:update_with(Name, fun(N) -> N + 1 end, 1, Counters)}.
