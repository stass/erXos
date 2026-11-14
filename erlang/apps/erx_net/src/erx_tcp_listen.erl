%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_listen).
-moduledoc """
A listening socket's process (docs/design-network-stack.md, "The listener"): the effects
around erx_tcp_listen_core, which decides everything. It holds the core, the listener's
accept credit, its one armed deadline and its counters, turns what it receives into the
core's events and performs the actions the core returns, in order. It waits on no one.

**Its start.** Its grant starts it with start_link/1 for the socket process that called
the grant's `tcp_listen`, whose messages arrive by `origin`, with the options
erx_tcp_listen_core:options/1 took. It traps exits, links to that socket process, so
either's end reaches the other, makes its accept credit with the limit
erx_tcp_listen_core:credit_limit/1 gives for `backlog`, and claims its key,
`{tcp_listen, inet, Local, Port}`, by an explicit bind (erx_net_bind:bind/2) within the
ports `allowed`, `reuseaddr` and `reuseport` as the options give them and an ephemeral
search for port 0 starting where its own generator says. A refused bind unlinks the socket
process and is its start's answer, `{error, Reason}`, returned from init/1 rather than
raised, so a refusal a client may repeat at will logs no crash report. A socket process already gone
answers the link with `noproc`, which ends the listener as its socket process's exit does.

**Its entry.** The key's entry holds, besides its pid, accept credit and grant, its
grantee's `origin`, its `listener`, the receive buffer and window shift each SYN-ACK
offers, and its `accept`, what each connection it accepts starts with: the congestion and
loss modules, `nodelay`, and FreeBSD's `tcp_sendspace` and `tcp_recvspace` as the buffer
sizes. A `setopts` of `nodelay` rewrites the entry with erx_net_bind:update/2 before it is
answered, so a handshake completing after the answer starts with the new value; `gone`, a
key its grant's end deleted, ends the listener as its grant's exit does.

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
  within the longest timer; `{setopts, [{nodelay, Boolean}]}`, `sockname`, answered with
  the bound address and port (`{0, 0, 0, 0}` for `any`), and `close`, answered `ok` before
  the listener ends, its key deleted first. Anything else from outside the stack is dropped and counted,
  `unknown` when it is not its socket process's and the admission's reason when it is a
  request of another shape; a credit message, which the listener has no use for, is dropped.

**What it does.** `{link, P}` and `{unlink, P}`; `{bind, Conn, Acceptor}`, the message
`{bind, self(), Acceptor}` to the connection; `{reply, N, Reply}`, `{erx_net, self(),
{reply, N, Reply}}` to its socket process; `take_unit`, one unit taken back from its accept
credit; `stop`, its end. After each step it arms the clock for the core's earliest
deadline. The core keeps time in milliseconds and the clock in microseconds, so the
listener gives the core `erx_net_clock:now() div 1000` and arms at a deadline times 1000:
a hint comes at or after that, when the deadline is due.

**Its end.** It ends normally when the core says `stop`, at its socket process's exit, or
at `close`, and deletes its key as it does. Its
grant is its parent, so gen_server ends it at the grant's exit, with the grant's reason,
before the core sees that exit. Its exit reaches every queued connection through their
links, and each aborts with a RST; a connection already sent `bind` ignores it. Its socket
process, seeing the exit, answers every call it still holds.
""".

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-export_type([start/0]).

%% FreeBSD's tcp_sendspace and tcp_recvspace (tcp_usrreq.c), the buffer sizes an accepted
%% connection starts with.
-define(SNDBUF, 32768).
-define(RCVBUF, 65536).
%% The calls in flight a socket process may send (docs/design-network-stack.md, "Requests in
%% flight"); the listener takes nothing else from its grantee.
-define(MAX_IN_FLIGHT, 64).

-record(state, {socket :: pid(),
                origin :: erx_net_admit:origin(),
                core :: erx_tcp_listen_core:core(),
                credit :: erx_net_credit:credit(),
                armed = infinity :: erx_net_clock:armed(),
                counters = #{} :: #{atom() => pos_integer()},
                key :: erx_net_input:key(),
                entry :: erx_net_input:entry()}).

-doc """
What the grant starts a listener with: its socket process, how the grantee's messages
arrive, the local address and port to bind (0 for an ephemeral port), the ports its grant
allows it, and `listen`'s options as erx_tcp_listen_core:options/1 took them.
""".
-type start() :: #{socket := pid(), origin := erx_net_admit:origin(),
                   local := inet:ip4_address() | any, port := 0..16#ffff,
                   allowed := erx_net_bind:ports(), options := erx_tcp_listen_core:options()}.

%% --- API -------------------------------------------------------------------------

-doc "Starts a listener linked to the calling process, its grant.".
-spec start_link(start()) -> {ok, pid()} | {error, term()}.
start_link(#{socket := Socket} = Start) when is_pid(Socket) ->
    gen_server:start_link(?MODULE, Start#{grant => self()}, []).

%% --- gen_server ------------------------------------------------------------------

-doc false.
init(#{socket := Socket, origin := Origin, grant := Grant, local := Local, port := Port0,
       allowed := Allowed,
       options := #{backlog := Backlog, reuseaddr := ReuseAddr, reuseport := ReusePort,
                    nodelay := Nodelay}}) ->
    ok = (erx_net_sup:runtime()):serve(?MAX_IN_FLIGHT),
    process_flag(trap_exit, true),
    true = link(Socket),
    Credit = erx_net_credit:new(erx_tcp_listen_core:credit_limit(Backlog)),
    Ip = addr(Local),
    Entry = #{pid => self(), credit => Credit, grant => Grant, origin => Origin,
              listener => #{rcv_buf => ?RCVBUF, rcv_scale => erx_tcp_output:request_r_scale()},
              accept => #{cc => erx_tcp_cc_cubic, loss => erx_tcp_loss_dupack, nodelay => Nodelay,
                          snd_hiwat => ?SNDBUF, rcv_hiwat => ?RCVBUF}},
    {Start, _Gen} = erx_net_bind:ephemeral_start(erx_net_rand:new(erx_net_clock:entropy(16))),
    Spec = #{transport => tcp, family => inet, local => Ip, port => Port0, start => Start,
             reuseaddr => ReuseAddr, reuseport => ReusePort, allowed => Allowed},
    case erx_net_bind:bind(Spec, Entry) of
        {ok, Port} ->
            {ok, #state{socket = Socket, origin = Origin, core = erx_tcp_listen_core:new(Socket, Grant),
                        credit = Credit, key = {tcp_listen, inet, Ip, Port}, entry = Entry}};
        {error, Reason} ->
            %% The socket process learns of the refusal from the grant's answer, not from
            %% this process's exit.
            true = unlink(Socket),
            {error, Reason}
    end.

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
        {ok, {call, N, Request}} -> request(N, Request, S);
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
perform([stop | _], #state{key = Key} = S) ->
    ok = erx_net_bind:delete(Key),
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

%% The socket protocol's requests of a listener beside accept, which the core takes no part
%% in: the options of its entry, its address and its close.
request(N, {setopts, []}, S) ->
    perform([{reply, N, ok}], S);
request(N, {setopts, [{nodelay, Nodelay}]}, #state{key = Key, entry = #{accept := Accept} = Entry0} = S) ->
    Entry = Entry0#{accept := Accept#{nodelay := Nodelay}},
    case erx_net_bind:update(Key, Entry) of
        ok -> perform([{reply, N, ok}], S#state{entry = Entry});
        gone -> {stop, {shutdown, grant_ended}, S}
    end;
request(N, sockname, #state{key = {tcp_listen, inet, Ip, Port}} = S) ->
    perform([{reply, N, {ok, {tuple(Ip), Port}}}], S);
request(N, close, #state{key = Key} = S) ->
    %% The port is free before close is answered, as FreeBSD's soclose frees it before
    %% close returns, so a listen on it right after the answer is not refused eaddrinuse.
    ok = erx_net_bind:delete(Key),
    perform([{reply, N, ok}, stop], S).

addr(any) -> any;
addr({A, B, C, D}) -> <<A, B, C, D>>.

tuple(any) -> {0, 0, 0, 0};
tuple(<<A, B, C, D>>) -> {A, B, C, D}.

now_ms() -> erx_net_clock:now() div 1000.

to_us(infinity) -> infinity;
to_us(Ms) -> Ms * 1000.

count(Reason, #state{counters = Counters} = S) ->
    S#state{counters = maps:update_with(Reason, fun(C) -> C + 1 end, 1, Counters)}.
