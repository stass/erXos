%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_tcp).
-moduledoc """
The TCP socket backend and its socket process (docs/design-network-stack.md, "The
backend", "The socket process"). A socket is `{'$inet', erx_gen_tcp, Pid}`, `Pid` its
socket process, a `gen_statem` in the owner's own domain, so `gen_tcp:send/2`,
`recv/2,3`, `shutdown/2`, `close/1` and `inet:setopts/2`, `getopts/2`, `sockname/1` and
`peername/1` reach this module through the dispatch they already have. On stock OTP,
whose `inet` knows no `erx` backend, a caller opens the socket with `connect/4` or
`listen/2` here.

**The stub.** Each function here is a local call of the socket process, waiting with
`infinity`, since a `recv` timeout is a deadline the socket process keeps. A socket
process of another node, which is another domain's, is refused with `{error, einval}`
before anything is sent; one that has ended answers as a closed socket, `{error,
closed}`, and closing it again is `ok`.

**The socket process.** The one party that talks to the socket, and the one that talks
to the owner about it. `connect/4` and `listen/2` check their options, start it, owned
by the caller, and make its one open call with the grant's request for the connection
or the listener. In `opening` it asks the grant through erx_inet:open/1, which checks
the answer, and takes the socket and the grant's origin exactly as it takes an accepted
connection (**Accepting**). From then on, in `open` for a connection and `listening`
for a listener, it talks to its socket only
in the socket protocol, `{erx_net, Sender, Body}`: it sends requests and credit, and
takes the socket's replies and pushes through erx_sock_admit:push/4, which leaves out
(`unknown`, dropped and counted) what is not its socket's from the socket's domain.
What to send, present and answer is decided by erx_gen_tcp_core's pure step; this
module performs its actions in order and arms its one timer, a waiting recv's deadline.
It monitors its owner, whose exit closes the socket, and its socket, whose exit without
a last push is `econnaborted`. It traps exits, since a listener and an accepted
connection link to it so that its end ends them; the exit of its socket is left to the
monitor, and any other is dropped and counted. A listening socket's process and an
accept's are exposed to the network domain (erx_inet:expose/1) before their socket links
to them; a connection's is not, since a connection only monitors it. It is started
without `{erx_serve, any}`, so no call from another domain reaches it.

**Accepting.** `accept/2` calls the listening socket's socket process, which starts a
socket process for the caller, owned by it and watching its starter, and sends the
listener `{accept, SockProc, Timeout}` naming it. The new one is started with the
listening socket's origin and exposes itself to the listener's domain as it starts,
since the listener and the connection it binds link to it; a refused export is the
accept's answer. The listener binds a connection to it and answers `{ok, Conn}`; the
listening socket's process hands the new one its connection and the listening socket's
presentation options, and answers the caller with the new socket, or `{error,
econnaborted}` when the new one has ended. On an error it ends the new one and answers
the error. In `opening` the new socket process ends at its owner's or its starter's exit
and at any exit signal, the listener's or the connection's, so nothing it was not handed
lives on.

**controlling_process.** As `gen_tcp_socket` does: the owner's first call moves the
socket process to `{transfer, NewOwner, State}`, in which the core presents nothing
(erx_gen_tcp_core:hold/1) and every other call waits; the stub moves the socket's
`{tcp, S, Data}` and `{tcp_closed, S}` messages already in the caller's mailbox to the
new owner, as stock's inet does, and its second call moves the owner's monitor and
presents what arrived meanwhile to the new owner. Pushes, exits and the recv deadline
are taken during the transfer as in `State`. A call from another process than the owner
is `{error, not_owner}`, a new owner that is not a live process of this node `{error,
badarg}`, and a socket that has shown its owner its end `{error, closed}`, as on stock.

Only IPv4 is taken: a host name given to `connect/4` resolves through inet's own path
(inet_db's lookup methods, the hosts file and then DNS) to its IPv4 addresses, which are
tried in order within the one timeout, each by a socket process of its own. The options
taken are the socket process's own (`binary`, `list`, `mode`, `active`, `{packet, raw}`)
and the connection's `nodelay`; `listen/2` also takes the local address (`ip` or
`ifaddr`) and the listener's `backlog`, `reuseaddr` and `reuseport`. `listen/2` and
`connect/4` first check the options as stock's gen_tcp does, with inet's own parser, so an
option stock does not know, or a value it does not take, raises `badarg` as on stock; one
stock takes and this backend does not is answered `{error, einval}`. What the backend
does not offer fails with `enotsup`: `fdopen/2` and `connect/3` with a socket-address
map.
""".

-behaviour(gen_statem).

-export([connect/3, connect/4, listen/2, accept/2, fdopen/2, send/2, recv/2, recv/3, shutdown/2, close/1,
         controlling_process/2,
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

%% A connection to one address, owned by the caller; options it does not take start no
%% socket process.
connect_one(Address, Port, Opts, Timeout) ->
    ok = stock_takes(connect, Opts),
    maybe
        {ok, Own, Fwd} ?= erx_gen_tcp_core:options(Opts, #{mode => list, active => true}),
        open({tcp_connect, inet, Address, Port, Fwd, Timeout}, Own)
    end.

-doc "Not offered by this backend, which answers `enotsup`: a socket-address map, `gen_tcp:connect/3`'s first form.".
-spec connect(map(), [term()], timeout()) -> {error, enotsup}.
connect(SockAddr, _Opts, _Timeout) when is_map(SockAddr) ->
    {error, enotsup}.

-doc """
Listens on `Port` (0 for an ephemeral port) with `gen_tcp:listen/2`'s options; a port
outside 0 to 65535 raises `badarg`, as stock's does.
""".
-spec listen(inet:port_number(), [term()]) -> {ok, socket()} | {error, term()}.
listen(Port, Opts) when is_integer(Port), Port >= 0, Port =< 16#ffff, is_list(Opts) ->
    ok = stock_takes(listen, Opts),
    maybe
        {ok, Local, Rest} ?= erx_gen_tcp_core:local(Opts),
        {ok, Own, Listener} ?= erx_gen_tcp_core:listen_options(Rest),
        open({tcp_listen, inet, Local, Port, Listener}, Own)
    end;
listen(_Port, _Opts) ->
    exit(badarg).

%% A socket process owned by the caller, which opens its socket with the grant's
%% `Request`, a connection's or a listener's, and presents with `Own`; it ends by itself
%% when the open fails.
open(Request, Own) ->
    {ok, Pid} = gen_statem:start(?MODULE, self(), []),
    case call(Pid, {open, Request, Own}) of
        ok -> {ok, {'$inet', ?MODULE, Pid}};
        {error, _} = Error -> Error
    end.

%% `ok` when stock's gen_tcp takes every option of Opts for a connect or a listen; else
%% the exit stock's own backend raises for it (inet_tcp:connect/4 and listen/2), badarg.
%% inet's parser decides, over the options without the family and the module, which
%% gen_tcp takes out before its backend sees them (inet:tcp_module/1), so the options
%% stock knows are never listed here.
stock_takes(Call, Opts) ->
    {_Module, Rest} = inet:tcp_module(Opts),
    Parsed = case Call of
                 connect -> inet:connect_options(Rest, inet_tcp);
                 listen -> inet:listen_options(Rest, inet_tcp)
             end,
    case Parsed of
        {ok, _} -> ok;
        {error, Reason} -> exit(Reason)
    end.

-doc "Accepts a connection on a listening socket, waiting at most `Timeout` milliseconds.".
-spec accept(socket(), timeout()) -> {ok, socket()} | {error, term()}.
accept({'$inet', ?MODULE, Pid}, Timeout) ->
    call(Pid, {accept, Timeout}).

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

-doc "Makes `NewOwner` the socket's owner, moving the socket's messages queued for the caller.".
-spec controlling_process(socket(), pid()) -> ok | {error, closed | not_owner | badarg | einval}.
controlling_process({'$inet', ?MODULE, Pid} = S, NewOwner) when is_pid(NewOwner) ->
    case call(Pid, {controlling_process, NewOwner}) of
        transfer ->
            move_messages(S, NewOwner),
            call(Pid, controlling_process);
        Reply ->
            Reply
    end.

%% The socket's messages already in the caller's mailbox, sent on to the new owner in
%% their order, as stock's inet moves them (inet:tcp_sync_input/3).
move_messages(S, NewOwner) ->
    receive
        {tcp, S, _} = Msg -> NewOwner ! Msg, move_messages(S, NewOwner);
        {tcp_closed, S} = Msg -> NewOwner ! Msg, move_messages(S, NewOwner)
    after 0 ->
        ok
    end.

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
               starter_ref = none :: reference() | none, % an accepted socket's, until handed its connection
               sock = none :: pid() | none,              % the connection or the listener, once open
               sock_ref = none :: reference() | none,
               origin = local :: erx_sock_admit:origin(),
               core = none :: erx_gen_tcp_core:core() | none,
               counters = #{} :: #{atom() => pos_integer()}}).

-doc false.
callback_mode() ->
    handle_event_function.

%% A socket process for an opener, its owner, or for an accept's caller, its owner, started
%% by the listening socket's process, which it watches until that process hands it its
%% connection. The accept's exposes itself to the listener's domain, Origin, before its
%% start returns, so before the listener can link to it; a refused export is its start's
%% answer, which a `shutdown` reason keeps out of the crash reports.
-doc false.
init({accepted, Owner, Starter, Origin}) when is_pid(Owner), is_pid(Starter) ->
    process_flag(trap_exit, true),
    case erx_inet:expose(Origin) of
        ok ->
            {ok, opening, #data{owner = Owner, owner_ref = erlang:monitor(process, Owner),
                                starter_ref = erlang:monitor(process, Starter), origin = Origin}};
        {error, Reason} ->
            {stop, {shutdown, Reason}}
    end;
init(Owner) when is_pid(Owner) ->
    process_flag(trap_exit, true),
    {ok, opening, #data{owner = Owner, owner_ref = erlang:monitor(process, Owner)}}.

%% Calls: the open in `opening`; controlling_process/2's two calls, between which every
%% other call waits; an accept, which starts its caller's socket process; and the rest,
%% which the core steps. Every other event is taken in a transfer as in the state it holds.
-doc false.
handle_event({call, From}, {open, Request, Own}, opening, #data{starter_ref = none} = D) ->
    Becomes = becomes(Request),
    case erx_inet:open(Request) of
        {ok, Sock, Origin} -> take(Sock, Origin, Becomes, Own, From, D);
        {error, _} = Error -> {stop_and_reply, normal, [{reply, From, Error}]}
    end;
handle_event({call, From}, {hand_over, Conn, Own}, opening, #data{starter_ref = Ref, origin = Origin} = D)
  when is_reference(Ref) ->
    true = erlang:demonitor(Ref, [flush]),
    take(Conn, Origin, connection, Own, From, D#data{starter_ref = none});
handle_event({call, From}, _Request, opening, _D) ->
    {keep_state_and_data, [{reply, From, {error, einval}}]};
handle_event({call, From}, {controlling_process, NewOwner}, State, D) when State =:= open; State =:= listening ->
    transfer(From, NewOwner, State, D);
handle_event({call, {Owner, _} = From}, controlling_process, {transfer, NewOwner, State},
             #data{owner = Owner, owner_ref = Ref, core = Core0} = D) ->
    true = erlang:demonitor(Ref, [flush]),
    gen_statem:reply(From, ok),
    {Core, Actions} = erx_gen_tcp_core:release(Core0),
    D1 = D#data{owner = NewOwner, owner_ref = erlang:monitor(process, NewOwner), core = Core},
    enter(State, perform(Actions, D1, []));
handle_event({call, _From}, _Request, {transfer, _, _}, _D) ->
    {keep_state_and_data, [postpone]};
handle_event({call, {Caller, _} = From}, {accept, Timeout}, listening, #data{origin = Origin} = D) ->
    case gen_statem:start(?MODULE, {accepted, Caller, self(), Origin}, []) of
        {ok, SockProc} -> step({call, From, {accept, SockProc, Timeout}}, D);
        {error, {shutdown, Reason}} -> {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;
handle_event({call, From}, Request, _State, D) ->
    step({call, From, Request}, D);
handle_event(cast, discard, opening, _D) ->
    {stop, normal};
handle_event(cast, _Msg, _State, D) ->
    {keep_state, count(unknown, D)};
handle_event(Type, Content, {transfer, _, State}, D) ->
    event(Type, Content, State, D);
handle_event(Type, Content, State, D) ->
    event(Type, Content, State, D).

%% Exits, deadlines and pushes, in the state the socket process is in or, during a
%% transfer, the one the transfer holds.
event(info, {'DOWN', Ref, process, _, _}, opening, #data{owner_ref = Ref}) ->
    {stop, normal};
event(info, {'DOWN', Ref, process, _, _}, opening, #data{starter_ref = Ref}) ->
    {stop, normal};
event(info, {'EXIT', _, _}, opening, _D) ->
    {stop, normal};
event(info, _Msg, opening, D) ->
    {keep_state, count(unknown, D)};
event(info, {'DOWN', Ref, process, _, _}, _State, #data{owner_ref = Ref} = D) ->
    step(owner_down, D);
event(info, {'DOWN', Ref, process, _, _}, _State, #data{sock_ref = Ref} = D) ->
    step(socket_down, D);
event(info, {'EXIT', Sock, _}, _State, #data{sock = Sock}) ->
    keep_state_and_data;
event(info, {'EXIT', _, _}, _State, D) ->
    {keep_state, count(unknown, D)};
event({timeout, recv}, expired, open, D) ->
    step(recv_timeout, D);
event(info, Msg, State, #data{origin = Origin, sock = Sock} = D) ->
    case erx_sock_admit:push(kind(State), Origin, Sock, Msg) of
        unknown -> {keep_state, count(unknown, D)};
        Admitted -> step({push, Admitted}, D)
    end.

kind(open) -> tcp;
kind(listening) -> tcp_listen.

%% A crash report shows the owner, the socket and the counters, never the bytes held or a
%% message in hand, since both may hold the peer's data.
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

%% What an open's request makes of its socket process: a connection, or a listener whose
%% accepted connections start with its `nodelay`.
becomes({tcp_connect, _Family, _Address, _Port, _Opts, _Timeout}) -> connection;
becomes({tcp_listen, _Family, _Local, _Port, Opts}) -> {listener, proplists:get_value(nodelay, Opts, false)}.

%% The one way a socket process takes its socket, the grant's answer to its open (already
%% checked by erx_inet) or a connection the listening socket's process hands over, and
%% becomes `open` or `listening`. It monitors the socket and keeps its domain's origin.
%%
%% The caller is answered after the core is built and before the monitor, so a listening
%% socket's process that hands a connection over never waits on the lane the monitor
%% crosses.
take(Sock, Origin, Becomes, Own, From, D) ->
    Self = {'$inet', ?MODULE, self()},
    {State, Core, Actions} =
        case Becomes of
            connection ->
                {C, As} = erx_gen_tcp_core:new(Self, Own),
                {open, C, As};
            {listener, Nodelay} ->
                %% Every connection the listener answers an accept with must be of its node.
                {listening, erx_gen_tcp_core:listener(Self, Own, #{nodelay => Nodelay, node => node(Sock)}), []}
        end,
    gen_statem:reply(From, ok),
    D1 = D#data{sock = Sock, sock_ref = erlang:monitor(process, Sock), origin = Origin, core = Core},
    enter(State, perform(Actions, D1, [])).

%% controlling_process/2's first call, answered as stock's inet answers it: `ok` when the
%% new owner is the owner, `not_owner` for a caller that is not, `badarg` for a new owner
%% that is no live process of this node or is the socket process itself, and `closed` when the core has nothing to move.
transfer({Caller, _} = From, NewOwner, State, #data{owner = Owner, core = Core0} = D) ->
    case erx_gen_tcp_core:hold(Core0) of
        {error, closed} = Error ->
            {keep_state_and_data, [{reply, From, Error}]};
        {ok, _} when NewOwner =:= Owner ->
            {keep_state_and_data, [{reply, From, ok}]};
        {ok, _} when Caller =/= Owner ->
            {keep_state_and_data, [{reply, From, {error, not_owner}}]};
        {ok, Core} ->
            case node(NewOwner) =:= node() andalso NewOwner =/= self() andalso is_process_alive(NewOwner) of
                true -> {next_state, {transfer, NewOwner, State}, D#data{core = Core}, [{reply, From, transfer}]};
                false -> {keep_state_and_data, [{reply, From, {error, badarg}}]}
            end
    end.

step(Event, #data{core = Core0} = D) ->
    {Core, Actions} = erx_gen_tcp_core:step(Event, Core0),
    perform(Actions, D#data{core = Core}, []).

%% A transition into State with what perform/3 returned for the state left.
enter(State, {keep_state, D, Timers}) -> {next_state, State, D, Timers};
enter(_State, Stop) -> Stop.

%% The core's actions, in order. Messages and replies go at once, so the owner sees them
%% in the order the core made them; the timer becomes a transition action.
perform([], D, Timers) ->
    {keep_state, D, lists:reverse(Timers)};
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
perform([{recv_timer, cancel} | Rest], D, Timers) ->
    perform(Rest, D, [{{timeout, recv}, cancel} | Timers]);
perform([{recv_timer, Ms} | Rest], D, Timers) ->
    perform(Rest, D, [{{timeout, recv}, Ms, expired} | Timers]);
perform([{hand_over, From, SockProc, Conn, Own} | Rest], D, Timers) ->
    gen_statem:reply(From, hand_over(SockProc, Conn, Own)),
    perform(Rest, D, Timers);
perform([{discard, SockProc} | Rest], D, Timers) ->
    gen_statem:cast(SockProc, discard),
    perform(Rest, D, Timers);
perform([{count, Check} | Rest], D, Timers) ->
    logger:warning("erx_gen_tcp: the socket's push fails the ~s check", [Check]),
    perform(Rest, count(Check, D), Timers).

%% An accepted connection handed to the socket process started for its caller, which is
%% in `opening` and answers at once; one that has ended answers as a connection aborted
%% before it was handed out.
hand_over(SockProc, Conn, Own) ->
    try gen_statem:call(SockProc, {hand_over, Conn, Own}, infinity) of
        ok -> {ok, {'$inet', ?MODULE, SockProc}}
    catch
        exit:_ -> {error, econnaborted}
    end.

count(Name, #data{counters = Counters} = D) ->
    D#data{counters = maps:update_with(Name, fun(N) -> N + 1 end, 1, Counters)}.
