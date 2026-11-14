%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_listen_core).
-moduledoc """
The listener's step (docs/design-network-stack.md, "The listener"): a pure state machine
over the connections queued for `accept`, the `accept` calls waiting for one, and the
calls handing a connection, chosen for them and not yet heard back from. erx_tcp_listen
performs what it returns.

A connection joins the queue at its `{queued, Conn}` notice, which carries one unit of the
listener's accept credit; the unit is taken back exactly when the connection leaves the
queue, paired with a call or ended while queued, so the units the listener holds are the
connections on its queue. An `accept` call links the listener to its acceptor's socket
process and waits, with its deadline, behind any that wait. Whenever a call waits and a
connection is queued, the oldest of each are paired: the connection is sent `bind` and the
call is handing it, until the connection answers `{bound, Conn}`, which answers the call
`{ok, Conn}`, or ends, which answers it `{error, econnaborted}` and never pairs it again.
A waiting call is answered `{error, econnaborted}` when its socket process ends and
`{error, timeout}` at its deadline; a handing call has no deadline and ignores its socket
process's end, which ends its connection in turn. So each call the step takes is answered
exactly once while the listener runs. The exit of the listener's own socket process or of
its grant is the listener's end, `stop`; its socket process then answers the calls it still
holds.

A call past the 64 in flight, or one naming the listener's own socket process or its grant
as its acceptor, whose unlink would cut a link the listener ends by, is answered
`{error, badarg}` at once and holds nothing. Two calls in flight naming the same number or
the same socket process are a programming error of the listener's socket process, and so
is a second notice from one connection; each raises, since each link, reply and unit
belongs to one call or one connection, and the listener's end then answers every call. The
notices are taken on their word: only a connection the stack's interface spawned holds the
listener's pid, and a connection links to the listener before its notice, so its exit
always follows.
""".

-export([new/2, step/3, next_deadline/1, view/1, credit_limit/1]).
-export_type([core/0, event/0, action/0, reply/0]).

-record(core, {socket :: pid(),
               grant :: pid(),
               %% Oldest first.
               queue = [] :: [pid()],
               %% Oldest first: the call's number, its socket process and its deadline.
               waiting = [] :: [{call_id(), pid(), deadline()}],
               %% Connection => the call it is handed to.
               handing = #{} :: #{pid() => {call_id(), pid()}}}).

-opaque core() :: #core{}.

%% The calls a socket process may have in flight (docs/design-network-stack.md, "Requests in
%% flight"), and FreeBSD's SOMAXCONN (socket.h:434), the largest backlog a listener takes.
-define(MAX_IN_FLIGHT, 64).
-define(SOMAXCONN, 128).
-type call_id() :: non_neg_integer().
-type deadline() :: integer() | infinity.

-doc """
What the step takes: a connection's notice and its answer to `bind`; an `accept` call
numbered `N` from the listener's socket process, for the acceptor's socket process, with
its timeout in milliseconds; the exit of a linked process; and the clock's turn.
""".
-type event() :: {queued, Conn :: pid()}
               | {bound, Conn :: pid()}
               | {accept, call_id(), SockProc :: pid(), timeout()}
               | {exit, pid()}
               | expired.

-type reply() :: {ok, pid()} | {error, econnaborted | timeout | badarg}.

-doc """
What the effect does: link to or unlink from a process; send a connection
`{bind, self(), SockProc}`; answer call `N`; take one unit back from the accept credit;
end the listener.
""".
-type action() :: {link, pid()}
                | {unlink, pid()}
                | {bind, Conn :: pid(), SockProc :: pid()}
                | {reply, call_id(), reply()}
                | take_unit
                | stop.

-doc "A listener for its socket process and its grant, with nothing queued or waiting.".
-spec new(pid(), pid()) -> core().
new(Socket, Grant) -> #core{socket = Socket, grant = Grant}.

-doc "One event at `now`, the stack's clock in milliseconds.".
-spec step(event(), core(), #{now := integer()}) -> {core(), [action()]}.
step({queued, Conn}, #core{queue = Queue, handing = Handing} = Core, _Ctx) ->
    case lists:member(Conn, Queue) orelse is_map_key(Conn, Handing) of
        true -> erlang:error({duplicate_notice, Conn});
        false -> pair(Core#core{queue = Queue ++ [Conn]}, [])
    end;
step({accept, N, SockProc, Timeout}, #core{socket = Socket, grant = Grant, waiting = Waiting,
                                           handing = Handing} = Core, #{now := Now}) ->
    case is_call(N, SockProc, Core) of
        true -> erlang:error({duplicate_call, N, SockProc});
        false -> ok
    end,
    Deadline = case Timeout of
                   infinity -> infinity;
                   _ when is_integer(Timeout), Timeout >= 0 -> Now + Timeout;
                   _ -> erlang:error({bad_timeout, Timeout})
               end,
    Refused = SockProc =:= Socket orelse SockProc =:= Grant
                  orelse length(Waiting) + map_size(Handing) >= ?MAX_IN_FLIGHT,
    case Refused of
        false -> pair(Core#core{waiting = Waiting ++ [{N, SockProc, Deadline}]}, [{link, SockProc}]);
        true -> {Core, [{reply, N, {error, badarg}}]}
    end;
step({bound, Conn}, #core{handing = Handing} = Core, _Ctx) ->
    case maps:take(Conn, Handing) of
        {{N, SockProc}, Rest} ->
            {Core#core{handing = Rest},
             [{reply, N, {ok, Conn}}, {unlink, Conn}, {unlink, SockProc}]};
        error ->
            {Core, []}
    end;
step({exit, Pid}, Core, _Ctx) ->
    exit_of(Pid, Core);
step(expired, #core{waiting = Waiting} = Core, #{now := Now}) ->
    {Due, Left} = lists:partition(fun({_, _, Deadline}) -> Deadline =< Now end, Waiting),
    {Core#core{waiting = Left},
     lists:append([[{reply, N, {error, timeout}}, {unlink, SockProc}] || {N, SockProc, _} <- Due])}.

%% Whose exit it is decides what it ends: the listener itself; a queued connection, whose
%% unit comes back; the call a connection was handed to; a waiting call. The exit of a
%% handing call's socket process changes nothing here: its connection ends, and that exit
%% answers the call.
exit_of(Pid, #core{socket = Pid} = Core) ->
    {Core, [stop]};
exit_of(Pid, #core{grant = Pid} = Core) ->
    {Core, [stop]};
exit_of(Pid, #core{queue = Queue} = Core) ->
    case lists:member(Pid, Queue) of
        true -> {Core#core{queue = lists:delete(Pid, Queue)}, [take_unit]};
        false -> handing_exit(Pid, Core)
    end.

handing_exit(Pid, #core{handing = Handing} = Core) ->
    case maps:take(Pid, Handing) of
        {{N, SockProc}, Rest} ->
            {Core#core{handing = Rest}, [{reply, N, {error, econnaborted}}, {unlink, SockProc}]};
        error ->
            acceptor_exit(Pid, Core)
    end.

acceptor_exit(Pid, #core{waiting = Waiting} = Core) ->
    case lists:keytake(Pid, 2, Waiting) of
        {value, {N, _, _}, Left} -> {Core#core{waiting = Left}, [{reply, N, {error, econnaborted}}]};
        false -> {Core, []}
    end.

%% The oldest waiting call and the oldest queued connection, while there are both: the
%% connection leaves the queue, its unit comes back, and it is sent bind.
pair(#core{queue = [Conn | Queue], waiting = [{N, SockProc, _} | Waiting], handing = Handing} = Core,
     Acc) ->
    pair(Core#core{queue = Queue, waiting = Waiting, handing = Handing#{Conn => {N, SockProc}}},
         Acc ++ [take_unit, {bind, Conn, SockProc}]);
pair(Core, Acc) ->
    {Core, Acc}.

is_call(N, SockProc, #core{waiting = Waiting, handing = Handing}) ->
    Calls = [{M, P} || {M, P, _} <- Waiting] ++ maps:values(Handing),
    lists:any(fun({M, P}) -> M =:= N orelse P =:= SockProc end, Calls).

-doc """
The limit of a listener's accept credit for `listen`'s `Backlog`, `3 * Backlog div 2 + 1`:
FreeBSD's `solisten_clone` refuses a connection once `sol_qlen > 3 * sol_qlimit / 2`
(uipc_socket.c:1032), so a queue holds that many and one more. A backlog below zero or
above 128 is taken as 128, as `solisten_proto` clamps it to `somaxconn`
(uipc_socket.c:1542-1544).
""".
-spec credit_limit(integer()) -> pos_integer().
credit_limit(Backlog) when is_integer(Backlog), Backlog >= 0, Backlog =< ?SOMAXCONN ->
    3 * Backlog div 2 + 1;
credit_limit(Backlog) when is_integer(Backlog) ->
    credit_limit(?SOMAXCONN).

-doc "The earliest deadline of a waiting call, or `infinity`.".
-spec next_deadline(core()) -> deadline().
next_deadline(#core{waiting = Waiting}) ->
    lists:min([infinity | [Deadline || {_, _, Deadline} <- Waiting]]).

-doc """
What the listener holds, oldest first, for its inspection and its tests: the queued
connections, the waiting calls as `{N, SockProc, Deadline}`, and the handing calls as
`{Conn, N, SockProc}`.
""".
-spec view(core()) -> #{queue := [pid()], waiting := [{call_id(), pid(), deadline()}],
                        handing := [{pid(), call_id(), pid()}]}.
view(#core{queue = Queue, waiting = Waiting, handing = Handing}) ->
    #{queue => Queue, waiting => Waiting,
      handing => lists:sort([{Conn, N, SockProc} || Conn := {N, SockProc} <- Handing])}.
