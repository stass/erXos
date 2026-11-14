%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_listen).
-moduledoc """
A listening socket's process (docs/design-network-stack.md, "The listener"): the effects
around erx_tcp_listen_core, which decides everything. It holds the core, the listener's
accept credit, its one armed deadline and its counters, turns what it receives into the
core's events and performs the actions the core returns, in order. It waits on no one.

**Its start.** Its grant starts it with start_link/1 for the socket process that the grant's
`listen` names, whose messages arrive by `origin`. It traps exits, links to that socket
process, so either's end reaches the other, and makes its accept credit with the limit
erx_tcp_listen_core:credit_limit/1 gives for `backlog`, 5 when absent as on stock
(inet_int.hrl:279). A socket process already gone answers the link with `noproc`, which
ends the listener as its socket process's exit does.

**What it takes.**

* `{queued, Conn}` and `{bound, Conn}` from its connections, which only the stack's own
  processes send it, bare;
* the exits of its links: its socket process, its grant, its connections and the socket
  processes of the `accept` calls;
* `{erx_net_clock, hint}`, at which the core's waiting calls past their deadlines are
  answered;
* `{erx_net, SockProc, {call, N, {accept, Acceptor, Timeout}}}` from its socket process, bare
  or in the grantee's envelope, admitted by erx_net_admit:request/4 as a `tcp_listen`
  socket, which checks that `Acceptor` is a pid of the grantee's domain and the timeout
  within the longest timer. Anything else from outside the stack is dropped and counted,
  `unknown` when it is not its socket process's and the admission's reason when it is a
  request of another shape; a credit message, which the listener has no use for, is dropped.

**What it does.** `{link, P}` and `{unlink, P}`; `{bind, Conn, Acceptor}`, the message
`{bind, self(), Acceptor}` to the connection; `{reply, N, Reply}`, `{erx_net, self(),
{reply, N, Reply}}` to its socket process; `take_unit`, one unit taken back from its accept
credit; `stop`, its end. After each step it arms the clock for the core's earliest
deadline. The core keeps time in milliseconds and the clock in microseconds, so the
listener gives the core `erx_net_clock:now() div 1000` and arms at a deadline times 1000:
a hint comes at or after that, when the deadline is due.

**Its end.** It ends normally when the core says `stop`, at its socket process's exit. Its
grant is its parent, so gen_server ends it at the grant's exit, with the grant's reason,
before the core sees that exit. Its exit reaches every queued connection through their
links, and each aborts with a RST; a connection already sent `bind` ignores it. Its socket
process, seeing the exit, answers every call it still holds.
""".

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-export_type([start/0]).

%% stock's default backlog (inet_int.hrl:279).
-define(BACKLOG, 5).
%% The calls in flight a socket process may send (docs/design-network-stack.md, "Requests in
%% flight"); the listener takes nothing else from its grantee.
-define(MAX_IN_FLIGHT, 64).

-record(state, {socket :: pid(),
                origin :: erx_net_admit:origin(),
                core :: erx_tcp_listen_core:core(),
                credit :: erx_net_credit:credit(),
                armed = infinity :: erx_net_clock:armed(),
                counters = #{} :: #{atom() => pos_integer()}}).

-doc """
What the grant starts a listener with: its socket process, how the grantee's messages
arrive, and `listen`'s backlog.
""".
-type start() :: #{socket := pid(), origin := erx_net_admit:origin(), backlog => integer()}.

%% --- API -------------------------------------------------------------------------

-doc "Starts a listener linked to the calling process, its grant.".
-spec start_link(start()) -> {ok, pid()} | {error, term()}.
start_link(#{socket := Socket} = Start) when is_pid(Socket) ->
    gen_server:start_link(?MODULE, Start#{grant => self()}, []).

%% --- gen_server ------------------------------------------------------------------

-doc false.
init(#{socket := Socket, origin := Origin, grant := Grant} = Start) ->
    ok = (erx_net_sup:runtime()):serve(?MAX_IN_FLIGHT),
    process_flag(trap_exit, true),
    true = link(Socket),
    Credit = erx_net_credit:new(erx_tcp_listen_core:credit_limit(maps:get(backlog, Start, ?BACKLOG))),
    {ok, #state{socket = Socket, origin = Origin, core = erx_tcp_listen_core:new(Socket, Grant),
                credit = Credit}}.

-doc false.
handle_call(_Request, _From, S) ->
    {noreply, count(unknown, S)}.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

-doc false.
handle_info({queued, Conn}, S) when is_pid(Conn) ->
    step({queued, Conn}, S);
handle_info({bound, Conn}, S) when is_pid(Conn) ->
    step({bound, Conn}, S);
handle_info({'EXIT', Pid, _}, S) ->
    step({exit, Pid}, S);
handle_info({erx_net_clock, hint}, S) ->
    step(expired, S#state{armed = infinity});
handle_info(Msg, #state{socket = Socket, origin = Origin} = S) ->
    case erx_net_admit:request(tcp_listen, Origin, Socket, Msg) of
        {ok, {call, N, {accept, Acceptor, Timeout}}} -> step({accept, N, Acceptor, Timeout}, S);
        {ok, {credit, _}} -> {noreply, S};
        unknown -> {noreply, count(unknown, S)};
        {refused, Check} -> {noreply, count(Check, S)}
    end.

-doc false.
format_status(Status) ->
    maps:map(fun(state, #state{core = Core, counters = Counters}) ->
                     #{listener => erx_tcp_listen_core:view(Core), counters => Counters};
                (_, Value) ->
                     Value
             end, Status).

%% --- The step and its effects ----------------------------------------------------

%% One event through the core, its actions performed in order, then the clock armed for the
%% core's earliest deadline.
step(Event, #state{core = Core0} = S) ->
    {Core, Actions} = erx_tcp_listen_core:step(Event, Core0, #{now => now_ms()}),
    perform(Actions, S#state{core = Core}).

perform([], #state{core = Core, armed = Armed} = S) ->
    {noreply, S#state{armed = erx_net_clock:arm_by(to_us(erx_tcp_listen_core:next_deadline(Core)), Armed)}};
perform([stop | _], S) ->
    {stop, normal, S};
perform([Action | Rest], S) ->
    ok = effect(Action, S),
    perform(Rest, S).

effect({link, Pid}, _S) ->
    true = link(Pid),
    ok;
effect({unlink, Pid}, _S) ->
    true = unlink(Pid),
    ok;
effect({bind, Conn, Acceptor}, _S) ->
    Conn ! {bind, self(), Acceptor},
    ok;
effect({reply, N, Reply}, #state{socket = Socket}) ->
    Socket ! {erx_net, self(), {reply, N, Reply}},
    ok;
effect(take_unit, #state{credit = Credit}) ->
    erx_net_credit:take(Credit, 1).

now_ms() -> erx_net_clock:now() div 1000.

to_us(infinity) -> infinity;
to_us(Ms) -> Ms * 1000.

count(Reason, #state{counters = Counters} = S) ->
    S#state{counters = maps:update_with(Reason, fun(C) -> C + 1 end, 1, Counters)}.
