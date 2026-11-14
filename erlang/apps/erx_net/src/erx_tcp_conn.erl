%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_conn).
-moduledoc """
A TCP connection's process (docs/design-network-stack.md, "One owner, one step",
"Receiving", "Transmitting", "Connection setup"): the loop around the pure `erx_tcp:step/3`
and the socket layer FreeBSD keeps in `struct socket` (the owner, the credit it was
granted, the bytes not yet pushed). It decides nothing a step could decide.

**One step per mailbox.** Each message becomes one step, except that an `{items, ...}`
takes every further one already queued with it: segments and ICMP reports from an
interface, `{items, Interface, Items}`; the owner's requests; the clock's hint, `{expired,
Now}`. The loop steps the segments of all the `{items, ...}` it took together, in arrival
order, and only then takes their units from the connection's credit
(docs/design-network-fastpath.md, "One step per mailbox"). Until then the interface can
hand no more than the credit's room, so the batch never exceeds the credit's limit. An
idle connection steps each message as it arrives, and under load one step and its one
output pass answer many segments with one ACK. The step's context is
the clock's time, the room left on the driver's transmit credit, and the path's MTU and
route, read again whenever the configuration generation moves. The loop performs the
actions in order:

* `transmit` frames the segments over the path (erx_net_frame) and sends them in one
  message (erx_net_tx); a full credit drops them, which the step's retransmission timer
  recovers;
* `deliver` appends to the receive queue; `notify` records end of stream, an error, or the
  end; `reply` answers the connect caller with `{ok, self()}`, and a request of the socket
  process with `{reply, N, Result}`;
* `reset` and `charge_rst` go to the interface, which holds the RST limit;
* `reserve_buffer` waits until the step's other actions are performed; then each is asked
  of the grant in order (erx_net_grant:reserve_buffer/4) and its answer stepped, `{buffer,
  Kind, Bytes}` when the grant reserved the size and `{buffer, Kind, refused}` when its
  `buffers` limit refused it, so no step runs inside another's actions;
* `finish` ends the process once the step's answers are out.

After the actions the loop pushes the receive queue to its socket process within the
credit it holds, and gives what left the receive buffer to erx_tcp:rcvd/2, so the window
opens as the socket process takes the bytes: it steps `{user, {rcvd, Bytes}}` only when
output would send for them (a window update, an owed ACK, or what a full driver queue held
back), as FreeBSD's `tcp_usr_rcvd` sends nothing below tcp_output's thresholds, and
otherwise takes them off the control block without a step. A connection in TIME-WAIT whose
socket process is gone then gives both of its buffers back to the grant
(erx_net_grant:release_buffers/2): its send buffer is empty, since the peer acknowledged
the FIN, its receive queue was dropped with the socket process, and nothing more can be
queued or delivered, so a client's closed connections hold none of the grant's `buffers`
limit through the 2MSL wait. Then the loop arms the clock no later than the earliest of
the step's deadline and the connect deadline.

**The socket protocol** (docs/design-network-stack.md, "The socket process"). The
connection's owner is its socket process, the grant's caller, which it monitors and the
only party it talks to after the connect. It takes the socket process's messages,
`{erx_net, SockProc, Body}`, bare when its grantee is `local` or in the envelope of the
grantee's domain, through erx_net_admit:request/3; any other message is dropped and
counted (`unknown`), so no reply goes to a party of another domain. Each `{call, N,
Request}` is answered `{erx_net, self(), {reply, N, Result}}`, at once or, for `send` and
`shutdown`, when the step answers. At most 64 are in flight, and only one `send`: past
either, or under an `N` already in flight, the request is answered `{error, badarg}`,
which only a socket process that breaks the protocol meets. `{credit, Bytes}` adds to the
bytes the connection may push, up to 64 MiB. It pushes `{data, Pieces}`, each at most a
piece, 64 KiB, of at most 64 of the receive queue's binaries; then `eof` once every byte
before the peer's FIN is pushed, and `{error, Reason}` as its last push when it ends with
the socket process still its owner.

**Bounds.** The interface hands segments only against the connection's credit, and the
step keeps the bytes it delivered counted until they are pushed (`rcv_buffered`), so the
receive queue holds at most the receive buffer, whatever the peer sends or the socket
process grants. A payload smaller than a quarter of its frame is copied out as it is
queued, so tiny segments do not keep their frames alive. The send buffer holds at most its
high watermark and one piece beyond it, the piece whose reply waits for room. What a client
domain can make the connection hold in requests is 64 requests of the protocol's bounded
shapes, one of them a piece.

**Raises.** A step over segments or a report that raises is counted as `raised` and the
connection keeps its state from before it, so segments that trip a bug cost only the
step they were in; nothing of them is logged. Should the loop itself crash, its report shows
the connection's state name, four-tuple and counters, never its buffers or the message
that was in hand, since both hold the peer's bytes.

An active open starts in its grant (erx_net_grant), which links to it, and monitors its
owner, the socket process: the owner's exit closes the connection as `close/1` does.

**An accepted connection** (docs/design-network-stack.md, "A connection from the
syncache", "The listener") starts in its interface, which calls accept/1 for a completed
handshake: one unit of the listener's accept credit is reserved, the connection spawned with
it and its four-tuple inserted, and the connection's first message is the verdict on the
insertion, `go` or `abandon`. The unit is the connection's from the spawn until its
`{queued, Conn}` notice carries it to the listener, so whichever way the connection gives
up before then, at `abandon`, at the interface's end before the verdict or at a refused
adoption, it releases the unit itself. After `go` it is adopted by its grant
(erx_net_grant:adopt/2), which it linked to first, and only then links to its listener and
queues itself: from its spawn to its end it holds a unit, one of its grant's sockets, or
both. A refused adoption hands the interface `{accept_refused, FourTuple, Segment}` for
its RST, deletes the key and ends.

Its owner moves through three phases. **Queued**, `{listener, L}`: it runs as any
connection does, acknowledging and taking bytes into its receive buffer, but pushes
nothing and admits no request; its listener's exit is its abort, a RST and its end. At
`{bind, SockProc}` from its listener it links to `SockProc` and answers `{bound, self()}`:
**bound**, `{bound, SockProc}`, it still sends nothing, since nothing crosses to a socket
process before that process's first message; from that first admitted message on the
owner is `SockProc`, as an active open's is. An accepted connection traps exits: its
grant's exit ends it without a step, its owner's closes it as the owner's `'DOWN'` closes an
active open, and any other exit, its listener's once bound among them, changes nothing.
""".

-behaviour(gen_server).

-include("erx_tcp.hrl").

-export([start_link/1, accept/1, accepted/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_continue/2,
         format_status/1]).

-export_type([start/0, accept/0]).

-define(CREDIT_LIMIT, 256).
%% The socket protocol's bounds (docs/design-network-stack.md, "Message sizes", "Requests
%% in flight"): a piece, the binaries of one push, the requests in flight, and the most
%% credit a socket process may hold out, stock's TCP_MAX_PACKET_SIZE.
-define(PIECE, 65536).
-define(MAX_PIECES, 64).
-define(MAX_IN_FLIGHT, 64).
-define(MAX_PUSH_CREDIT, 67108864).
%% A delivered piece smaller than this joins a small newest piece of the receive queue.
-define(SMALL_PIECE, 512).

-doc """
What the grant starts a connection with: its owner, the socket process; how its grantee's
messages arrive; the connect caller it answers; the remote address and port; the
connection's own options (`nodelay`); the connect timeout in milliseconds; the generator
split from the grant's; the grant itself, which reserves the buffers; the token that names
this connection in the grant's buffer calls; and the initial buffer sizes it reserved.
""".
-type start() :: #{owner := pid(), origin := erx_net_admit:origin(), from := gen_server:from(),
                   remote := {<<_:32>>, 1..16#ffff}, opts := list(), timeout := timeout(),
                   gen := erx_net_rand:gen(), grant := pid(), token := reference(),
                   buffers := #{snd := pos_integer(), rcv := pos_integer()}}.

-doc """
What an interface hands accept/1 for a completed handshake: the listener's entry in the
demultiplexing table, the four-tuple (local end first), the syncache's handshake, the
segment that completed it, the generator the `accept` action carries, and the interface's
pid and sender credit, under which a refused connection hands back its RST.
""".
-type accept() :: #{entry := #{pid := pid(), credit := erx_net_credit:credit(),
                               grant := pid(), origin := erx_net_admit:origin(),
                               accept := map(), atom() => term()},
                    conn := erx_tcp_syncache:conn(),
                    handshake := erx_tcp_syncache:handshake(),
                    segment := erx_tcp:segment(),
                    gen := erx_net_rand:gen(),
                    interface := pid(),
                    sender := erx_net_credit:credit()}.

%% The owner: an active open's socket process from the start; an accepted connection's
%% listener while it is queued, then the socket process an accept bound it to, which it
%% sends nothing until that process's first message; none once the owner closed.
-type owner() :: pid() | {listener, pid()} | {bound, pid()} | none.

-record(state, {tcb :: #tcb{},
                key :: erx_net_input:key(),
                credit :: erx_net_credit:credit(),
                owner :: owner(),
                owner_ref :: reference() | none,     % an active open's monitor of its owner
                origin :: erx_net_admit:origin(),
                grant :: pid(),                      % reserves the buffers
                token :: reference(),                % names this connection to the grant
                buffers = held :: held | released,   % released in TIME-WAIT once the owner closed
                push_credit = 0 :: non_neg_integer(), % bytes the socket process granted
                pending = #{} :: #{non_neg_integer() => send | shutdown}, % requests in flight
                rcvq = [] :: [binary()],             % newest first
                rcv_bytes = 0 :: non_neg_integer(),
                eof = false :: boolean(),            % the peer's FIN
                error = none :: none | atom(),
                ended = false :: boolean(),          % the connection closed
                told = none :: none | eof | ended,   % the last of eof and the end pushed
                finished = false :: boolean(),
                connect :: none | {gen_server:from(), integer() | infinity},
                path :: erx_net_frame:path(),
                template = erx_net_frame:no_template() :: erx_net_frame:template_cache(),
                route = ok :: ok | {error, ehostunreach},
                config_gen :: non_neg_integer(),
                gen :: erx_net_rand:gen(),
                armed = infinity :: erx_net_clock:armed(),
                counters = #{} :: #{atom() => pos_integer()}}).

%% --- Start -----------------------------------------------------------------------

-doc """
Starts an active open, linked to the caller, its grant. It claims a local port and the
four-tuple through erx_net_bind, sends the SYN and returns; the connect caller is answered
once the connection is established, fails, or its timeout passes.
""".
-spec start_link(start()) -> {ok, pid()} | {error, term()}.
start_link(Start) ->
    gen_server:start_link(?MODULE, Start, []).

-doc false.
init(#{owner := Owner, origin := Origin, from := From, remote := {Raddr, Rport}, opts := Opts0,
       timeout := Timeout, gen := Rand0, grant := Grant, token := Token,
       buffers := #{snd := SndBuf, rcv := RcvBuf}}) ->
    %% The requests in flight, the close that goes out past them, and a credit message.
    ok = (erx_net_sup:runtime()):serve(?MAX_IN_FLIGHT + 2),
    maybe
        {ok, Opts} ?= options(Opts0, #{}),
        {ConfigGen, Snap} = erx_net_tables:configuration(),
        {ok, #{src := Src} = Path} ?= erx_net_frame:path(Raddr, #{}, Snap),
        Credit = erx_net_credit:new(?CREDIT_LIMIT),
        {Start, Rand1} = erx_net_bind:ephemeral_start(Rand0),
        Now = erx_net_clock:now(),
        KeyOf = fun(P) -> {tcp, inet, Src, P, Raddr, Rport} end,
        {ok, Port, Iss, TsOffset} ?= erx_net_bind:claim_tcp(KeyOf, Start, self(),
                                                           #{pid => self(), credit => Credit}, Now),
        ok = erx_net_tables:watch_holder(self()),
        {TcbGen, Rand} = erx_net_rand:split(Rand1),
        Tcb = erx_tcp_user:new(#{family => inet, local => {Src, Port}, remote => {Raddr, Rport},
                                 iss => Iss, ts_offset => TsOffset,
                                 cc => erx_tcp_cc_cubic, loss => erx_tcp_loss_dupack,
                                 snd_hiwat => SndBuf, rcv_hiwat => RcvBuf, gen => TcbGen,
                                 now => Now, nodelay => maps:get(nodelay, Opts, false)}),
        S = #state{tcb = Tcb, key = KeyOf(Port), credit = Credit, owner = Owner,
                   owner_ref = erlang:monitor(process, Owner), origin = Origin, grant = Grant,
                   token = Token, connect = {From, deadline(Timeout, Now)},
                   path = Path, config_gen = ConfigGen, gen = Rand},
        {ok, S, {continue, connect}}
    else
        {error, Reason} -> {stop, Reason}
    end.

-doc """
An interface's effect for a completed handshake: reserves one unit of the listener's accept
credit, or answers `full` and starts nothing; otherwise spawns the connection with the unit
and its receive credit, inserts its four-tuple through erx_net_bind, and sends the
connection the verdict, `go`, or `abandon` when another socket holds the four-tuple. The
interface waits on nothing here, and from the spawn on the unit is the connection's.
""".
-spec accept(accept()) -> ok | full.
accept(#{entry := #{credit := Unit}, conn := Conn} = Accept) ->
    case erx_net_credit:reserve(Unit, 1) of
        full ->
            full;
        ok ->
            Credit = erx_net_credit:new(?CREDIT_LIMIT),
            Pid = proc_lib:spawn(?MODULE, accepted, [Accept#{credit => Credit}]),
            Pid ! case erx_net_bind:insert(key(Conn), Pid, #{pid => Pid, credit => Credit}) of
                      ok -> go;
                      {error, eaddrinuse} -> abandon
                  end,
            ok
    end.

-doc false.
%% The spawned connection's start, in the order "An accepted connection's start" gives: the
%% links and the watch first, then the verdict alone, the adoption, the listener, and the
%% control block with the completing segment stepped.
-spec accepted(map()) -> ok.
accepted(#{entry := #{credit := Unit, grant := Grant}, interface := Interface} = Accept) ->
    %% First, so that erx_net_tables deletes the four-tuple the interface inserts for this
    %% process when it ends, however it ends.
    ok = erx_net_tables:watch_holder(self()),
    process_flag(trap_exit, true),
    true = link(Grant),
    IfRef = erlang:monitor(process, Interface),
    receive
        go ->
            true = erlang:demonitor(IfRef, [flush]),
            adopt(Accept);
        abandon ->
            ok = erx_net_credit:release(Unit, 1);
        {'DOWN', IfRef, process, _, _} ->
            ok = erx_net_credit:release(Unit, 1),
            exit({shutdown, interface_ended})
    end.

%% Adopted by the grant, or refused: the unit released, the refusal's RST handed to the
%% interface under its sender credit, the key deleted, and the process ended. A grant that
%% has ended is a refusal too. No route to the peer, whose SYN-ACK just left over one, is
%% met only when the configuration changed in between, and is refused alike.
adopt(#{entry := #{credit := Unit, grant := Grant, accept := Init}, conn := Conn,
        segment := Segment, interface := Interface, sender := Sender} = Accept) ->
    #{snd_hiwat := SndHiwat, rcv_hiwat := RcvHiwat} = Init,
    {ConfigGen, Snap} = erx_net_tables:configuration(),
    {Local, _, Remote, _} = Conn,
    Adopted = case erx_net_frame:path(Remote, #{src => Local}, Snap) of
                  {ok, Path} -> {grant_adopt(Grant, #{snd => SndHiwat, rcv => RcvHiwat}), Path};
                  {error, _} -> {{error, ehostunreach}, none}
              end,
    case Adopted of
        {{ok, Token}, Path1} ->
            queue(Accept, Token, Path1, ConfigGen);
        {{error, _}, _} ->
            ok = erx_net_credit:release(Unit, 1),
            %% A full sender credit drops the RST, as a full queue drops any; the peer's
            %% retransmitted ACK then finds no entry and draws one from the syncache.
            _ = erx_net_credit:hand(Interface, Sender, 1, {accept_refused, Conn, Segment}),
            erx_net_bind:delete(key(Conn))
    end.

grant_adopt(Grant, Sizes) ->
    try
        erx_net_grant:adopt(Grant, Sizes)
    catch
        exit:{_, {gen_server, call, _}} -> {error, closed}
    end.

%% Adopted: linked to the listener and queued on it under the unit, then the control block
%% made from the handshake and the completing segment stepped, and the loop entered queued.
%% A listener already gone answers the link with its exit, which the loop takes as an abort.
queue(#{entry := #{pid := Listener, grant := Grant, origin := Origin, accept := Init}, conn := Conn,
        handshake := Handshake, segment := Segment, gen := Rand0, credit := Credit},
      Token, #{mtu := Mtu, iface := #{driver_credit := Tx}} = Path, ConfigGen) ->
    ok = (erx_net_sup:runtime()):serve(?MAX_IN_FLIGHT + 2),
    true = link(Listener),
    ok = erx_net_credit:send(Listener, {queued, self()}),
    {Local, Lport, Remote, Rport} = Conn,
    {TcbGen, Rand} = erx_net_rand:split(Rand0),
    Ctx = #tcp_ctx{now = erx_net_clock:now(), credit = erx_net_credit:free(Tx), mtu = Mtu,
                   route = ok},
    {Tcb, Actions} = erx_tcp_user:accepted(Handshake,
                                           Init#{family => family(Local), local => {Local, Lport},
                                                 remote => {Remote, Rport}, gen => TcbGen},
                                           Ctx),
    S0 =#state{tcb = Tcb, key = key(Conn), credit = Credit, owner = {listener, Listener},
                owner_ref = none, origin = Origin, grant = Grant, token = Token, connect = none,
                path = Path, config_gen = ConfigGen, gen = Rand},
    {S1a, Reserves} = perform_actions(Actions, S0),
    S1 = ask_grant(Reserves, S1a),
    case settle(guarded({segments, [Segment]}, S1)) of
        {noreply, S} -> gen_server:enter_loop(?MODULE, [], S);
        {stop, normal, _} -> ok
    end.

key({Local, Lport, Remote, Rport}) -> {tcp, family(Local), Local, Lport, Remote, Rport}.

family(<<_:32>>) -> inet;
family(<<_:128>>) -> inet6.

%% --- gen_server ------------------------------------------------------------------

%% The connect's step runs once the grant is out of start_link/1, so a buffer the step asks
%% for can be asked of the grant.
-doc false.
handle_continue(connect, #state{connect = {From, _}} = S) ->
    settle(step({user, {connect, From}}, S)).

-doc false.
handle_call(_Request, _From, S) ->
    {reply, {error, einval}, S}.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

-doc false.
handle_info({items, _If, Items}, #state{credit = Credit} = S0) when is_list(Items) ->
    Batch = queued_items([Items]),
    S = items(Batch, S0),
    ok = erx_net_credit:take(Credit, lists:sum([units(Item) || Item <- Batch])),
    settle(S);
handle_info({erx_net_clock, hint}, S) ->
    settle(timeouts(step({expired, erx_net_clock:now()}, S#state{armed = infinity})));
handle_info({'DOWN', Ref, process, _, _}, #state{owner_ref = Ref} = S) ->
    settle(owner_closed(S));
%% The exits an accepted connection traps: its grant's ends it without a step; its
%% listener's while queued is its abort, a RST; its owner's closes it; any other, its
%% listener's once bound among them, changes nothing.
handle_info({'EXIT', Grant, _}, #state{grant = Grant} = S) ->
    {stop, {shutdown, grant_ended}, S};
handle_info({'EXIT', Listener, _}, #state{owner = {listener, Listener}} = S) ->
    settle(step({user, abort}, S));
handle_info({'EXIT', Owner, _}, #state{owner = {bound, Owner}} = S) ->
    settle(owner_closed(S));
handle_info({'EXIT', Owner, _}, #state{owner = Owner} = S) when is_pid(Owner) ->
    settle(owner_closed(S));
handle_info({'EXIT', _, _}, S) ->
    {noreply, S};
%% An accept takes the queued connection for SockProc: linked, it answers its listener, and
%% sends SockProc nothing until SockProc's first message. A SockProc already gone answers
%% the link with its exit. A bind once bound is a programming error that ends it.
handle_info({bind, SockProc}, #state{owner = {listener, Listener}} = S) when is_pid(SockProc) ->
    true = link(SockProc),
    Listener ! {bound, self()},
    settle(S#state{owner = {bound, SockProc}});
handle_info({bind, _} = Bind, _S) ->
    exit({unexpected, Bind});
handle_info(_Msg, #state{owner = {listener, _}} = S) ->
    %% Queued: there is no socket process whose request could be admitted.
    {noreply, count(unknown, S)};
handle_info(Msg, #state{origin = Origin, owner = Owner} = S) ->
    Admitted = case Owner of
                   {bound, SockProc} -> SockProc;
                   _ -> Owner
               end,
    case erx_net_admit:request(tcp, Origin, Admitted, Msg) of
        %% The socket process's first admitted message is the first contact.
        {ok, Request} -> request(Request, S#state{owner = Admitted});
        unknown -> {noreply, count(unknown, S)};
        {refused, Check} -> {noreply, count(Check, S)}
    end.

%% --- The socket protocol -----------------------------------------------------------

%% A request of the socket process, admitted by erx_net_admit. `send` and `shutdown` are
%% answered when the step answers them, under `{call, N}`; the rest at once.
request({credit, Bytes}, #state{push_credit = Credit} = S) ->
    settle(S#state{push_credit = min(Credit + Bytes, ?MAX_PUSH_CREDIT)});
request({call, N, _}, #state{pending = Pending} = S)
  when is_map_key(N, Pending); map_size(Pending) >= ?MAX_IN_FLIGHT ->
    %% Refused without touching Pending: an N already in flight keeps its entry.
    {noreply, push({reply, N, {error, badarg}}, S)};
request({call, N, {send, Piece}}, #state{pending = Pending} = S) ->
    case lists:member(send, maps:values(Pending)) of
        true -> {noreply, push({reply, N, {error, badarg}}, S)};
        false -> settle(step({user, {send, {call, N}, Piece}}, S#state{pending = Pending#{N => send}}))
    end;
request({call, N, {shutdown, How}}, #state{pending = Pending} = S) ->
    settle(step({user, {shutdown, {call, N}, How}}, S#state{pending = Pending#{N => shutdown}}));
request({call, _N, close}, S) ->
    settle(owner_closed(S));
request({call, N, {setopts, Opts}}, #state{tcb = #tcb{nodelay = Nodelay} = Tcb} = S) ->
    {noreply, answer(N, ok, S#state{tcb = Tcb#tcb{nodelay = proplists:get_value(nodelay, Opts, Nodelay)}})};
request({call, N, {getopts, Names}}, #state{tcb = #tcb{nodelay = Nodelay}} = S) ->
    {noreply, answer(N, {ok, [{nodelay, Nodelay} || lists:member(nodelay, Names)]}, S)};
request({call, N, sockname}, #state{tcb = #tcb{local = {Ip, Port}}} = S) ->
    {noreply, answer(N, {ok, {tuple(Ip), Port}}, S)};
request({call, N, peername}, #state{tcb = #tcb{remote = {Ip, Port}}} = S) ->
    {noreply, answer(N, {ok, {tuple(Ip), Port}}, S)}.

%% The reply to request N, to the socket process while it is the owner.
answer(N, Result, #state{pending = Pending} = S) ->
    push({reply, N, Result}, S#state{pending = maps:remove(N, Pending)}).

push(Body, #state{owner = Owner} = S) when not is_pid(Owner) ->
    _ = Body,
    S;
push(Body, #state{owner = Owner} = S) ->
    Owner ! {erx_net, self(), Body},
    S.


-doc false.
format_status(Status) ->
    maps:map(fun(state, #state{tcb = #tcb{state = Name, local = Local, remote = Remote},
                               counters = Counters}) ->
                     #{state => Name, local => Local, remote => Remote, counters => Counters};
                (message, _) -> redacted;
                (log, _) -> [];
                (_, Value) -> Value
             end, Status).

%% --- Steps -------------------------------------------------------------------------

%% The items of the messages taken so far (`Taken`, newest first) followed by those of every
%% further `{items, _, _}` message already in the mailbox. No unit is taken back while the
%% drain runs, so the interface hands nothing past the credit's room and the drain ends
%% within the credit's limit.
queued_items(Taken) ->
    receive
        {items, _If, Items} when is_list(Items) ->
            queued_items([Items | Taken])
    after 0 ->
        lists:append(lists:reverse(Taken))
    end.

%% The credit an item took at the interface (erx_net_input:units/1): a merged segment one unit
%% for each of the segments it holds (docs/design-network-fastpath.md, "Credit counts
%% segments"), anything else one.
units({_Tcp, {merged, N, _Pieces}, _IpEcn, _LinkCast}) -> N;
units(_Item) -> 1.

%% A batch's segments go to the step together, in arrival order, and each ICMP report on
%% its own, so the step sees the items as the interfaces handed them.
items([], S) ->
    S;
items([{report, Icmp, Quoted} | Rest], S) ->
    items(Rest, guarded({icmp, {Icmp, Quoted}}, S));
items(Items, S) ->
    {Segments, Rest} = lists:splitwith(fun(Item) -> element(1, Item) =/= report end, Items),
    items(Rest, guarded({segments, Segments}, S)).

guarded(Event, S) ->
    try
        step(Event, S)
    catch
        error:_ -> count(raised, S)
    end.

%% Steps Event and performs its actions, then asks the grant for each buffer the step asked
%% for, in order, and steps each answer in turn, whose own actions may ask for more.
step(Event, S0) ->
    {S, Reserves} = step_once(Event, S0),
    ask_grant(Reserves, S).

ask_grant([], S) ->
    S;
ask_grant([{reserve_buffer, Kind, Bytes} | Rest], #state{grant = Grant, token = Token} = S0) ->
    Answer = case erx_net_grant:reserve_buffer(Grant, Token, Kind, Bytes) of
                 ok -> Bytes;
                 {error, enobufs} -> refused;
                 %% The grant does not know this connection or its token: a bug, which
                 %% ends the connection rather than counting it as a raised step.
                 {error, badarg} -> exit(badarg)
             end,
    {S, More} = step_once({buffer, Kind, Answer}, S0),
    ask_grant(Rest ++ More, S).

%% One step of the TCB with its actions performed, but for the buffer reservations it asks
%% for, which it returns in order.
step_once(Event, S0) ->
    #state{tcb = Tcb0, path = #{mtu := Mtu, iface := #{driver_credit := Tx}}, route = Route} =
        S = configured(S0),
    Ctx = #tcp_ctx{now = erx_net_clock:now(), credit = erx_net_credit:free(Tx), mtu = Mtu,
                   route = Route},
    {Tcb, Actions} = erx_tcp:step(Event, Tcb0, Ctx),
    perform_actions(Actions, S#state{tcb = Tcb}).

%% A step's actions performed in order, but for the buffer reservations, returned in order.
perform_actions(Actions, S) ->
    {Reserves, Rest} = lists:partition(fun({reserve_buffer, _, _}) -> true;
                                          (_) -> false
                                       end, Actions),
    {lists:foldl(fun perform/2, S, Rest), Reserves}.

%% The path, built again over the configuration when its generation moved; a path that no
%% longer exists keeps the old one and makes the route the step's EHOSTUNREACH.
configured(#state{config_gen = Gen0, path = #{src := Src}, tcb = #tcb{remote = {Raddr, _}}} = S) ->
    case erx_net_tables:generation() of
        Gen0 ->
            S;
        _ ->
            {Gen, Snap} = erx_net_tables:configuration(),
            case erx_net_frame:path(Raddr, #{src => Src}, Snap) of
                {ok, Path} -> S#state{config_gen = Gen, path = Path, route = ok};
                {error, _} -> S#state{config_gen = Gen, route = {error, ehostunreach}}
            end
    end.

perform({transmit, Segments}, #state{path = Path, gen = Gen0, template = Template0} = S) ->
    case erx_net_frame:tcp(Path, Segments, Gen0, Template0) of
        {ok, Packets, Gen, Template} ->
            sent(erx_net_tx:send(Path, Packets), tx_full, S#state{gen = Gen, template = Template});
        {error, Reason} -> count(Reason, S)
    end;
perform({deliver, Data}, #state{rcvq = Q, rcv_bytes = N} = S) ->
    S#state{rcvq = lists:foldl(fun queue/2, Q, Data),
            rcv_bytes = N + erx_tcp_payload:size(Data)};
perform({notify, eof}, S) ->
    S#state{eof = true};
perform({notify, {error, Reason}}, S) ->
    S#state{error = Reason};
perform({notify, closed}, S) ->
    S#state{ended = true};
perform({notify, {ready, _}}, S) ->
    S;
perform({reply, From, Reply}, #state{connect = {From, _}} = S) ->
    gen_server:reply(From, case Reply of
                               ok -> {ok, self()};
                               Error -> Error
                           end),
    S#state{connect = none};
perform({reply, {call, N}, Reply}, S) ->
    answer(N, Reply, S);
perform({reply, From, Reply}, S) ->
    gen_server:reply(From, Reply),
    S;
perform({reset, Segment}, #state{path = #{next_hop := NextHop, src := Src} = Path, gen = Gen0} = S) ->
    case erx_net_frame:tcp(Path, [Segment], Gen0) of
        {ok, Packets, Gen} ->
            sent(erx_net_tx:hand(Path, {reset, NextHop, Src, Packets}), if_full, S#state{gen = Gen});
        {error, Reason} ->
            count(Reason, S)
    end;
perform(charge_rst, #state{path = Path} = S) ->
    sent(erx_net_tx:hand(Path, charge_rst), if_full, S);
perform({reinject, _Segment}, S) ->
    %% A SYN for a listener reaching TIME-WAIT: no listener exists yet.
    count(reinject, S);
perform(finish, S) ->
    S#state{finished = true}.

%% A delivered piece onto the receive queue Q, newest first, as sbcompress appends an mbuf
%% to the socket buffer (uipc_sockbuf.c): a small piece is joined to a small newest one, so
%% a peer's tiny segments cost the queue their bytes and not a binary and a cons cell each;
%% any other piece is compacted and queued on its own. The pieces of a merged segment are
%% judged one by one, each a sub-binary of its own frame, and the queue joins what it holds
%% once, when the owner reads (take/2). So the queue keeps alive at most four times its
%% bytes, plus a few words for each piece of at least ?SMALL_PIECE bytes, within the
%% eight times of FreeBSD's sb_mbmax (sb_efficiency).
queue(<<>>, Q) ->
    Q;
queue(Piece, [Newest | Q]) when byte_size(Piece) < ?SMALL_PIECE,
                                byte_size(Newest) < 4 * ?SMALL_PIECE ->
    [<<Newest/binary, Piece/binary>> | Q];
queue(Piece, Q) ->
    [compact(Piece) | Q].

%% A payload piece smaller than a quarter of the frame it references is copied out, as the
%% reassembly queue copies it (erx_tcp_reass), so that queued tiny segments do not keep
%% their whole frames alive.
compact(Bin) ->
    case binary:referenced_byte_size(Bin) > 4 * byte_size(Bin) of
        true -> binary:copy(Bin);
        false -> Bin
    end.

sent(ok, _Reason, S) -> S;
sent(full, Reason, S) -> count(Reason, S).

count(Reason, #state{counters = Counters} = S) ->
    S#state{counters = maps:update_with(Reason, fun(N) -> N + 1 end, 1, Counters)}.

%% The owner closed the socket or exited: nothing more reaches it, and no request of it is
%% answered.
owner_closed(#state{owner = none} = S) ->
    S;
owner_closed(#state{owner_ref = Ref} = S) ->
    _ = Ref =:= none orelse erlang:demonitor(Ref, [flush]),
    step({user, close}, S#state{owner = none, owner_ref = none, pending = #{}}).

%% --- Settling: the socket process, the end and the clock ----------------------------

%% Pushes the receive queue within the credit, giving the step what left the receive buffer
%% until nothing more does, pushes the end, then ends the process or arms the clock. What
%% left the buffer is what it counted before the pushes less what it counts after, so no way
%% of pushing can give the step more or less than it took.
settle(S0) ->
    S1 = hand_over(S0),
    case S0#state.rcv_bytes - S1#state.rcv_bytes of
        0 ->
            S = release_buffers(tell_end(S1)),
            case S of
                #state{finished = true, key = Key} ->
                    ok = erx_net_bind:delete(Key),
                    {stop, normal, S};
                _ ->
                    {noreply, arm(S)}
            end;
        Released ->
            settle(rcvd(Released, S1))
    end.

%% Bytes that left the receive buffer: a step only when its output would send for them, a
%% window update, an owed ACK or what a full driver queue held back (erx_tcp:rcvd/2);
%% otherwise they are taken off the control block alone, and the next segment out carries
%% the window they opened.
rcvd(Released, #state{tcb = Tcb0} = S) ->
    case erx_tcp:rcvd(Released, Tcb0) of
        {quiet, Tcb} -> S#state{tcb = Tcb};
        step -> step({user, {rcvd, Released}}, S)
    end.

%% The receive queue pushed in pieces while the socket process's credit lasts; dropped
%% whole once there is no socket process.
hand_over(#state{rcv_bytes = 0} = S) ->
    S;
hand_over(#state{owner = none} = S) ->
    S#state{rcvq = [], rcv_bytes = 0};
hand_over(#state{owner = {_Phase, _}} = S) ->
    %% Queued or bound before the first contact: the bytes wait for the socket process.
    S;
hand_over(#state{push_credit = 0} = S) ->
    S;
hand_over(#state{rcvq = Q, rcv_bytes = N, push_credit = Credit} = S) ->
    {Pieces, Bytes, Rest} = pieces(lists:reverse(Q), min(Credit, ?PIECE), ?MAX_PIECES, [], 0),
    hand_over(push({data, Pieces}, S#state{rcvq = lists:reverse(Rest), rcv_bytes = N - Bytes,
                                           push_credit = Credit - Bytes})).

%% The oldest binaries of the queue (oldest first), at most Room bytes in at most Count
%% binaries, the last one cut to fit: the pieces, their bytes and what is left, oldest first.
pieces([Bin | Rest], Room, Count, Acc, Bytes) when Count > 0, Room > 0 ->
    case Bin of
        <<_:Room/binary, _/binary>> when byte_size(Bin) > Room ->
            <<Part:Room/binary, Left/binary>> = Bin,
            {lists:reverse([Part | Acc]), Bytes + Room, [Left | Rest]};
        _ ->
            pieces(Rest, Room - byte_size(Bin), Count - 1, [Bin | Acc], Bytes + byte_size(Bin))
    end;
pieces(Rest, _Room, _Count, Acc, Bytes) ->
    {lists:reverse(Acc), Bytes, Rest}.

%% Both buffers given back to the grant once the connection is in TIME-WAIT and its owner is
%% gone: nothing is left in them and nothing more can enter them.
release_buffers(#state{buffers = held, owner = none, tcb = #tcb{state = time_wait},
                       grant = Grant, token = Token} = S) ->
    ok = erx_net_grant:release_buffers(Grant, Token),
    S#state{buffers = released};
release_buffers(S) ->
    S.

%% The end of the stream, once every byte before it was pushed: `eof` for the peer's FIN,
%% then `{error, Reason}` (`closed` without an error) as the last push when the connection
%% ends, at once if it finishes with bytes the socket process has not taken.
tell_end(#state{owner = Owner} = S) when not is_pid(Owner) ->
    %% No socket process, or none that has made its first contact: the end waits with it.
    S;
tell_end(#state{told = none, eof = true, rcv_bytes = 0} = S) ->
    tell_end(push(eof, S#state{told = eof}));
tell_end(#state{told = Told, error = Error, ended = Ended, finished = Finished, rcv_bytes = N} = S)
  when Told =/= ended, (Error =/= none orelse Ended orelse Finished), (N =:= 0 orelse Finished) ->
    push({error, case Error of
                     none -> closed;
                     _ -> Error
                 end}, S#state{told = ended});
tell_end(S) ->
    S.

%% The connect deadline, which the socket enforces as the step enforces its own: a connect
%% past its timeout ends the connection, which has received no SYN and so owes the peer
%% nothing (`tcp_close` in SYN-SENT).
timeouts(#state{connect = {From, Deadline}} = S) when is_integer(Deadline) ->
    case erx_net_clock:now() >= Deadline of
        true ->
            gen_server:reply(From, {error, timeout}),
            S#state{connect = none, finished = true};
        false ->
            S
    end;
timeouts(S) ->
    S.

%% One hint no later than the earliest deadline: the step's and the connect's.
arm(#state{tcb = Tcb, connect = Connect, armed = Armed} = S) ->
    Deadlines = [erx_tcp:next_deadline(Tcb)] ++ [D || {_, D} <- [Connect]],
    S#state{armed = erx_net_clock:arm_by(lists:min(Deadlines), Armed)}.

deadline(infinity, _Now) -> infinity;
deadline(Ms, Now) -> Now + Ms * 1000.

%% --- Options -----------------------------------------------------------------------

%% The options the connection takes at its start: `nodelay`; the socket process keeps the
%% rest. Any other is refused.
options([], Acc) ->
    {ok, Acc};
options([{nodelay, B} | Rest], Acc) when is_boolean(B) ->
    options(Rest, Acc#{nodelay => B});
options(_Opts, _Acc) ->
    {error, einval}.

tuple(<<A, B, C, D>>) -> {A, B, C, D}.
