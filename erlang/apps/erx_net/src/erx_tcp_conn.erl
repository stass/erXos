%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_conn).
-moduledoc """
A TCP connection's process (docs/design-network-stack.md, "One owner, one step",
"Receiving", "Transmitting", "Connection setup"): the loop around the pure `erx_tcp:step/3`
and the socket layer FreeBSD keeps in `struct socket` (the owner, the active mode, the bytes
not yet handed over, a waiting `recv`). It decides nothing a step could decide.

**One event.** Each message becomes one step: segments and ICMP reports from an interface,
`{items, Interface, Items}`, whose units the loop takes from the connection's credit on
arrival; the owner's requests; the clock's hint, `{expired, Now}`. The step's context is
the clock's time, the room left on the driver's transmit credit, and the path's MTU and
route, read again whenever the configuration generation moves. The loop performs the
actions in order:

* `transmit` frames the segments over the path (erx_net_frame) and sends them in one
  message (erx_net_tx); a full credit drops them, which the step's retransmission timer
  recovers;
* `deliver` appends to the receive queue; `notify` records end of stream, an error, or the
  end; `reply` answers a caller, the connect caller with `{ok, Socket}`;
* `reset` and `charge_rst` go to the interface, which holds the RST limit;
* `reserve_buffer` is granted at once, with the size the step asked for, which erx_tcp_mss
  holds to `SB_MAX` (the grant's reservations are not built);
* `finish` ends the process once the step's answers are out.

After the actions the loop hands the receive queue to the owner, in active mode as one
`{tcp, Socket, Data}` or to a waiting `recv/3`, and steps `{user, {rcvd, Bytes}}` for what
it handed, so the window opens as the owner reads. Then it arms the clock no later than the
earliest of the step's deadline and the connect and recv deadlines.

**Bounds.** The interface hands segments only against the connection's credit, and the
step keeps the bytes it delivered counted until the owner has them (`rcv_buffered`), so
the receive queue never holds more than the receive buffer; the send buffer holds at most
its high watermark, the rest of a `send` waiting with its caller. In `{active, true}`
mode, as with `gen_tcp`, the owner's mailbox is bounded only by how fast the owner reads.

**Raises.** A step over segments or a report that raises is counted as `raised` and the
connection keeps its state from before it, so a segment that trips a bug costs only
itself; nothing of the segment is logged. Should the loop itself crash, its report shows
the connection's state name, four-tuple and counters, never its buffers or the message
that was in hand, since both hold the peer's bytes.

The process starts in its grant (erx_net_grant), which links to it, and monitors its owner:
the owner's exit closes the connection as `close/1` does.
""".

-behaviour(gen_server).

-include("erx_tcp.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_continue/2,
         format_status/1]).

-export_type([start/0]).

-define(CREDIT_LIMIT, 256).
-define(MAX_REQUEST, 16).
%% tcp_sendspace and tcp_recvspace, FreeBSD's default buffer sizes (tcp_usrreq.c).
-define(SNDBUF, 32768).
-define(RCVBUF, 65536).

-doc """
What the grant starts a connection with: its owner, the connect caller it answers, the
remote address and port, `gen_tcp`'s options, the connect timeout in milliseconds and the
generator split from the grant's.
""".
-type start() :: #{owner := pid(), from := gen_server:from(),
                   remote := {<<_:32>>, 1..16#ffff}, opts := list(), timeout := timeout(),
                   gen := erx_net_rand:gen()}.

-type active() :: boolean() | once | integer().

-record(state, {tcb :: #tcb{},
                socket :: term(),
                key :: erx_net_input:key(),
                credit :: erx_net_credit:credit(),
                owner :: pid() | none,               % none once the owner closed
                owner_ref :: reference() | none,
                active :: active(),
                mode :: binary | list,
                rcvq = [] :: [binary()],             % newest first
                rcv_bytes = 0 :: non_neg_integer(),
                eof = false :: boolean(),            % the peer's FIN
                error = none :: none | atom(),
                ended = false :: boolean(),          % the connection closed
                told = false :: boolean(),           % tcp_closed sent
                finished = false :: boolean(),
                connect :: none | {gen_server:from(), integer() | infinity},
                recv = none :: none | {gen_server:from(), non_neg_integer(), integer() | infinity},
                path :: erx_net_frame:path(),
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
init(#{owner := Owner, from := From, remote := {Raddr, Rport}, opts := Opts0, timeout := Timeout,
       gen := Rand0}) ->
    ok = (erx_net_sup:runtime()):serve(?MAX_REQUEST),
    maybe
        {ok, #{active := Active, mode := Mode} = Opts} ?= options(Opts0, #{active => true, mode => list}),
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
                                 snd_hiwat => ?SNDBUF, rcv_hiwat => ?RCVBUF, gen => TcbGen,
                                 now => Now, nodelay => maps:get(nodelay, Opts, false)}),
        S = #state{tcb = Tcb, socket = {'$inet', erx_gen_tcp, self()}, key = KeyOf(Port),
                   credit = Credit, owner = Owner, owner_ref = erlang:monitor(process, Owner),
                   active = Active, mode = Mode, connect = {From, deadline(Timeout, Now)},
                   path = Path, config_gen = ConfigGen, gen = Rand},
        {ok, step({user, {connect, From}}, S), {continue, settle}}
    else
        {error, Reason} -> {stop, Reason}
    end.

%% --- gen_server ------------------------------------------------------------------

-doc false.
handle_continue(settle, S) ->
    settle(S).

-doc false.
handle_call({send, Data}, From, S) when is_binary(Data) ->
    settle(step({user, {send, From, Data}}, S));
handle_call({recv, _Length, _Timeout}, _From, #state{active = Active} = S) when Active =/= false ->
    {reply, {error, einval}, S};
handle_call({recv, _Length, _Timeout}, _From, #state{recv = {_, _, _}} = S) ->
    {reply, {error, ealready}, S};
handle_call({recv, Length, _Timeout}, _From, #state{tcb = #tcb{rcv_hiwat = Hiwat}} = S)
  when is_integer(Length), Length > Hiwat ->
    {reply, {error, enomem}, S};
handle_call({recv, Length, Timeout}, From, S)
  when is_integer(Length), Length >= 0, Timeout =:= infinity;
       is_integer(Length), Length >= 0, is_integer(Timeout), Timeout >= 0 ->
    settle(S#state{recv = {From, Length, deadline(Timeout, erx_net_clock:now())}});
handle_call({shutdown, How}, From, S) when How =:= read; How =:= write; How =:= read_write ->
    settle(step({user, {shutdown, From, How}}, S));
handle_call(close, From, S) ->
    gen_server:reply(From, ok),
    settle(owner_closed(S));
handle_call({setopts, Opts}, _From, #state{active = Active0, mode = Mode0} = S0) ->
    case options(Opts, #{active => Active0, mode => Mode0}) of
        {ok, #{active := Active, mode := Mode}} ->
            S = passive_notice(S0#state{active = Active, mode = Mode}),
            {reply, ok, S, {continue, settle}};
        {error, _} = Error ->
            {reply, Error, S0}
    end;
handle_call({getopts, Names}, _From, #state{active = Active, mode = Mode} = S) when is_list(Names) ->
    Known = #{active => Active, mode => Mode},
    {reply, {ok, [{Name, Value} || Name <- Names, {ok, Value} <- [maps:find(Name, Known)]]}, S};
handle_call(sockname, _From, #state{tcb = #tcb{local = {Ip, Port}}} = S) ->
    {reply, {ok, {tuple(Ip), Port}}, S};
handle_call(peername, _From, #state{tcb = #tcb{remote = {Ip, Port}}} = S) ->
    {reply, {ok, {tuple(Ip), Port}}, S};
handle_call(_Request, _From, S) ->
    {reply, {error, einval}, S}.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

-doc false.
handle_info({items, _If, Items}, #state{credit = Credit} = S) when is_list(Items) ->
    ok = erx_net_credit:take(Credit, length(Items)),
    settle(items(Items, S));
handle_info({erx_net_clock, hint}, S) ->
    settle(timeouts(step({expired, erx_net_clock:now()}, S#state{armed = infinity})));
handle_info({'DOWN', Ref, process, _, _}, #state{owner_ref = Ref} = S) ->
    settle(owner_closed(S));
handle_info(_Msg, S) ->
    {noreply, S}.

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

%% A batch's segments go to the step together, in arrival order, and each ICMP report on
%% its own, so the step sees the items as the interface received them.
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

step(Event, S0) ->
    #state{tcb = Tcb0, path = #{mtu := Mtu, iface := #{driver_credit := Tx}}, route = Route} =
        S = configured(S0),
    Ctx = #tcp_ctx{now = erx_net_clock:now(), credit = erx_net_credit:free(Tx), mtu = Mtu,
                   route = Route},
    {Tcb, Actions} = erx_tcp:step(Event, Tcb0, Ctx),
    lists:foldl(fun perform/2, S#state{tcb = Tcb}, Actions).

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

perform({transmit, Segments}, #state{path = Path, gen = Gen0} = S) ->
    case erx_net_frame:tcp(Path, Segments, Gen0) of
        {ok, Packets, Gen} -> sent(erx_net_tx:send(Path, Packets), tx_full, S#state{gen = Gen});
        {error, Reason} -> count(Reason, S)
    end;
perform({deliver, Data}, #state{rcvq = Q, rcv_bytes = N} = S) ->
    Bin = iolist_to_binary(Data),
    S#state{rcvq = [Bin | Q], rcv_bytes = N + byte_size(Bin)};
perform({notify, eof}, S) ->
    S#state{eof = true};
perform({notify, {error, Reason}}, S) ->
    S#state{error = Reason};
perform({notify, closed}, S) ->
    S#state{ended = true};
perform({notify, {ready, _}}, S) ->
    S;
perform({reply, From, Reply}, #state{connect = {From, _}, socket = Sock} = S) ->
    gen_server:reply(From, case Reply of
                               ok -> {ok, Sock};
                               Error -> Error
                           end),
    S#state{connect = none};
perform({reply, From, Reply}, S) ->
    gen_server:reply(From, Reply),
    S;
perform({reserve_buffer, Kind, Bytes}, S) ->
    step({buffer, Kind, Bytes}, S);
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

sent(ok, _Reason, S) -> S;
sent(full, Reason, S) -> count(Reason, S).

count(Reason, #state{counters = Counters} = S) ->
    S#state{counters = maps:update_with(Reason, fun(N) -> N + 1 end, 1, Counters)}.

%% The owner closed the socket or exited: nothing more reaches it, and a waiting recv is
%% answered.
owner_closed(#state{owner = none} = S) ->
    S;
owner_closed(#state{owner_ref = Ref, recv = Recv} = S) ->
    _ = erlang:demonitor(Ref, [flush]),
    [gen_server:reply(From, {error, closed}) || {From, _, _} <- [Recv]],
    step({user, close}, S#state{owner = none, owner_ref = none, recv = none}).

%% --- Settling: the owner, the end and the clock --------------------------------------

%% Hands the receive queue over, stepping `rcvd` for what was handed until nothing more
%% moves, tells the owner of the end, then ends the process or arms the clock.
settle(S0) ->
    case hand_over(S0) of
        {0, S1} ->
            S = tell_end(S1),
            case S of
                #state{finished = true, key = Key} ->
                    ok = erx_net_bind:delete(Key),
                    {stop, normal, S};
                _ ->
                    {noreply, arm(S)}
            end;
        {Bytes, S1} ->
            settle(step({user, {rcvd, Bytes}}, S1))
    end.

%% What the owner takes now: all of the queue in active mode or for `recv(_, 0, _)`,
%% `Length` bytes for a recv that waits for them, and the whole queue, dropped, once the
%% owner is gone.
hand_over(#state{rcv_bytes = 0} = S) ->
    {0, S};
hand_over(#state{owner = none, rcv_bytes = N} = S) ->
    {N, S#state{rcvq = [], rcv_bytes = 0}};
hand_over(#state{active = Active, owner = Owner, socket = Sock, mode = Mode, rcv_bytes = N} = S)
  when Active =/= false ->
    {Data, Rest} = take(N, S),
    Owner ! {tcp, Sock, data(Mode, Data)},
    {N, passive_notice(Rest#state{active = spend(Active)})};
hand_over(#state{recv = {From, Length, _}, mode = Mode, rcv_bytes = N} = S) when N >= Length ->
    Take = case Length of
               0 -> N;
               _ -> Length
           end,
    {Data, Rest} = take(Take, S),
    gen_server:reply(From, {ok, data(Mode, Data)}),
    {Take, Rest#state{recv = none}};
hand_over(S) ->
    {0, S}.

take(Bytes, #state{rcvq = Q, rcv_bytes = N} = S) ->
    <<Data:Bytes/binary, Left/binary>> = iolist_to_binary(lists:reverse(Q)),
    {Data, S#state{rcvq = [Left || Left =/= <<>>], rcv_bytes = N - Bytes}}.

data(binary, Data) -> Data;
data(list, Data) -> binary_to_list(Data).

%% `{active, N}` counts deliveries down to passive; `once` is one.
spend(once) -> false;
spend(N) when is_integer(N) -> N - 1;
spend(Active) -> Active.

passive_notice(#state{active = N, owner = Owner, socket = Sock} = S) when is_integer(N), N =< 0 ->
    [Owner ! {tcp_passive, Sock} || Owner =/= none],
    S#state{active = false};
passive_notice(S) ->
    S.

%% The end of the stream, once everything before it was handed over: in active mode
%% `{tcp_error, S, Reason}` when there was one and then `{tcp_closed, S}`, once; a waiting
%% recv gets the error, or `closed`, also when fewer bytes remain than it waits for.
tell_end(#state{eof = false, ended = false} = S) ->
    S;
tell_end(#state{owner = none} = S) ->
    S;
tell_end(#state{active = Active, told = false, rcv_bytes = 0, owner = Owner, socket = Sock,
                error = Error} = S) when Active =/= false ->
    [Owner ! {tcp_error, Sock, Error} || Error =/= none],
    Owner ! {tcp_closed, Sock},
    S#state{told = true};
tell_end(#state{recv = {From, Length, _}, rcv_bytes = N, error = Error} = S)
  when N =:= 0; N < Length ->
    gen_server:reply(From, {error, case Error of
                                       none -> closed;
                                       _ -> Error
                                   end}),
    S#state{recv = none};
tell_end(S) ->
    S.

%% The connect and recv deadlines, which the socket enforces as the step enforces its own:
%% a connect past its timeout ends the connection, which has received no SYN and so owes
%% the peer nothing (`tcp_close` in SYN-SENT); a recv past its timeout is answered.
timeouts(#state{connect = {From, Deadline}} = S0) when is_integer(Deadline) ->
    case erx_net_clock:now() >= Deadline of
        true ->
            gen_server:reply(From, {error, timeout}),
            timeouts(S0#state{connect = none, finished = true});
        false ->
            timeouts_recv(S0)
    end;
timeouts(S) ->
    timeouts_recv(S).

timeouts_recv(#state{recv = {From, _, Deadline}} = S) when is_integer(Deadline) ->
    case erx_net_clock:now() >= Deadline of
        true -> gen_server:reply(From, {error, timeout}), S#state{recv = none};
        false -> S
    end;
timeouts_recv(S) ->
    S.

%% One hint no later than the earliest deadline: the step's, the connect's and the recv's.
arm(#state{tcb = Tcb, connect = Connect, recv = Recv, armed = Armed} = S) ->
    Deadlines = [erx_tcp:next_deadline(Tcb)] ++ [D || {_, D} <- [Connect]]
        ++ [D || {_, _, D} <- [Recv]],
    S#state{armed = erx_net_clock:arm_by(lists:min(Deadlines), Armed)}.

deadline(infinity, _Now) -> infinity;
deadline(Ms, Now) -> Now + Ms * 1000.

%% --- Options -----------------------------------------------------------------------

%% The options this connection takes from `gen_tcp:connect/4` and `inet:setopts/2`; any
%% other is refused.
options([], Acc) ->
    {ok, Acc};
options([Opt | Rest], Acc) ->
    case option(Opt) of
        {ok, Kv} -> options(Rest, maps:merge(Acc, active(Kv, Acc)));
        error -> {error, einval}
    end;
options(_Opts, _Acc) ->
    {error, einval}.

option(binary) -> {ok, #{mode => binary}};
option(list) -> {ok, #{mode => list}};
option({mode, Mode}) when Mode =:= binary; Mode =:= list -> {ok, #{mode => Mode}};
option({active, A}) when is_boolean(A); A =:= once -> {ok, #{active => A}};
option({active, N}) when is_integer(N), N >= -32768, N =< 32767 -> {ok, #{active => {add, N}}};
option({nodelay, B}) when is_boolean(B) -> {ok, #{nodelay => B}};
option({packet, P}) when P =:= raw; P =:= 0 -> {ok, #{}};
option(inet) -> {ok, #{}};
option(_) -> error.

%% `{active, N}` adds to a count already running, as `inet:setopts/2` does.
active(#{active := {add, N}} = Kv, #{active := Current}) when is_integer(Current) ->
    Kv#{active := Current + N};
active(#{active := {add, N}} = Kv, _Acc) ->
    Kv#{active := N};
active(Kv, _Acc) ->
    Kv.

tuple(<<A, B, C, D>>) -> {A, B, C, D}.
