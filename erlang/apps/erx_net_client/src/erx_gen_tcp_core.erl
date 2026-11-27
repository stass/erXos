%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_tcp_core).
-moduledoc """
The decisions of a TCP socket process (docs/design-network-stack.md, "The socket
process", "Message sizes", "Requests in flight"): a pure step, `step(Event, Core) ->
{Core, [Action]}`, over what the socket process holds for its owner. erx_gen_tcp is the
effect shell around it: it performs the actions in order and turns messages and its one
timer into events. The core reads no clock and sends nothing.

**Requests.** Every call that needs the connection becomes `{request, N, Request}`, `N`
the core's count of its requests, so a reply names the request it answers and replies
come in any order. At most 64 requests are in flight; a request past that waits, in
arrival order, until a reply frees a place. A `send` is cut into pieces of at most
64 KiB, sent one at a time, each after the reply to the one before; its caller is
answered after the last piece's reply, or with the first error. A `send` waits for the
`send` before it, and a passive `recv` for the `recv` before it. `close` goes out at
once, is answered `ok`, and ends the socket process.

**Credit.** The connection pushes only within the bytes the core has granted. The core
keeps what it holds plus the credit outstanding at its target: the `buffer` option, the
receive buffer's 64 KiB unless set, raised to a waiting `recv(S, Length)`'s `Length`, up
to stock's 64 MiB, or to what the packet in progress needs. It grants the shortfall once
it reaches half the target, so credit costs one message per half target received, and
at once when a waiting recv or the packet in progress needs more than it holds and has
outstanding. So the socket process holds at most its target, and the connection pushes
nothing the core has not asked for. A push past the credit outstanding, a reply to a
request not in flight, or a reply that fails its reply type breaks the protocol: the
socket is aborted with `econnaborted`.

**Presenting.** In active mode every push is presented at once, as one `{tcp, S, Data}`
(its pieces joined into one binary, or a list in `list` mode); `{active, once}` turns
passive after one delivery, with no notice, and `{active, N}` counts deliveries down and
sends `{tcp_passive, S}` at zero, as stock's inet does. A passive
`recv(S, 0)` takes all that is held, `recv(S, Length)` exactly `Length` bytes; a recv
that times out leaves what is held for the next one. Recvs that wait when the socket
turns active are answered `{error, einval}`, as a recv of an active socket is.

**Packets.** In a packet mode (`{packet, 1 | 2 | 4 | line}`) a delivery is one packet,
framed by erx_net_packet from the bytes held when it is presented, so a change of packet
mode applies to every byte not yet presented, as on stock: each `{tcp, S, Packet}` in
active mode is one delivery, and a passive recv takes one packet, its `Length` 0 (another
is `{error, einval}`, as on stock). A packet over `packet_size` ends the stream with
`{error, emsgsize}` where the packet would be, as stock's driver ends it; a partial packet
at the end is dropped, as stock drops it. A send in a length mode gets its header.

**The end.** `eof` comes after every byte, and `{error, Reason}` is the socket's last
push; the socket's exit without one is `{error, econnaborted}`. The owner is shown the
first end only: after `eof` the stream is whole, and a later end means only that the
connection is gone. In active mode the core presents what it holds, then `{tcp_error, S,
Reason}` for an error other than `closed` and `{tcp_closed, S}`, and closes: the socket
is told `close` and the core answers every call it holds `{error, closed}`.

In passive mode, whether the owner chose it or an active count ran out, the end waits
for the owner, as in stock's inet driver, which meets the end only when it reads. The
first recv that what is held cannot complete is answered with the error, or `{error,
closed}` after `eof` (stock's `tcp_recv_closed`), the held bytes discarded, and every
recv after it `{error, enotconn}`; or the owner turns the socket active and is shown
what is held and the end as above. After `eof`
sends go on until then. After an error the connection is gone, so the core closes at
once and keeps what is held and the end for the owner. A closed core answers `recv`
from what is still held, takes `setopts` while the end waits for the owner, answers
`getstat` as before, and answers every other call but `close` with `{error, closed}`.

**Listening.** A listener's core, listener/3, holds its socket process's calls of the
listening socket: `accept`, numbered as every request is and sent to the listener with the
socket process started for its caller, at most 64 in flight as every request; `setopts`,
whose presentation options the core keeps for the sockets it hands out and whose
`nodelay` it keeps too, since the listener answers no `getopts`, and forwards; `getopts`,
answered from what it keeps; `getstat`; `sockname`, forwarded; and `close`. `send`, `recv`,
`shutdown` and `peername` are `{error, enotconn}`, as stock's listening socket answers
them. The listener's `{ok, Conn}`, checked against the listener's node, becomes
`{hand_over, From, SockProc, Conn, Own}`: the shell hands the new socket process its
connection and the listening socket's options, and answers the caller. Every other
answer to an `accept`, the listener's error, the socket's end or a closed core's refusal,
answers the caller and ends that socket process, `{discard, SockProc}`. The listener's
exit, or a push that breaks the protocol, closes the core as a connection's error does.

**Statistics.** The core counts what crosses it as stock's inet driver counts at its
port: each push of data it holds is one delivery received, and each `send` one delivery
sent, counted with its packet header when the core takes it. A `getstat` is answered
from those counts in every state, without a request: the eight statistics they give,
averages truncated as the driver reports them; `recv_dvi` and `send_pend`, which the
core does not measure, left out; and `{error, einval}` for any other name, as stock.

**Holding.** While controlling_process/2 moves the socket to a new owner, hold/1 makes
the core present nothing: what arrives is held and the end waits, as in passive mode,
within the credit it granted; release/1 presents what was held to the new owner.
""".

-export([new/2, listener/3, step/2, hold/1, release/1, options/1, options/2, listen_options/1, local/1]).

-export_type([core/0, event/0, action/0, request/0, own/0]).

%% The piece: what one request or push carries at most (docs/design-network-stack.md,
%% "Message sizes").
-define(PIECE, 65536).
-define(MAX_IN_FLIGHT, 64).
%% The default `buffer`, the target: the connection's receive buffer (erx_tcp_conn's RCVBUF).
-define(TARGET, 65536).
%% stock's TCP_MAX_PACKET_SIZE (inet_drv.c): the longest recv, the largest `buffer`, the
%% longest packet, and the most credit outstanding.
-define(MAX_RECV, 67108864).
%% The largest `packet_size` stock keeps.
-define(MAX_PACKET_SIZE, 16#ffffffff).
-define(IS_TIMEOUT(T), (T =:= infinity orelse (is_integer(T) andalso T >= 0 andalso T =< ?MAX_TIMEOUT))).
-define(IS_RECV(L, T), (is_integer(L) andalso L >= 0 andalso ?IS_TIMEOUT(T))).
%% The longest timer the runtime arms, so a recv's timeout never crashes the socket process.
-define(MAX_TIMEOUT, 4294967295).

-doc "The options the socket process keeps: how it presents data to its owner.".
-type own() :: #{mode := binary | list, active := active(), packet := packet(),
                 packet_size := non_neg_integer(), buffer := pos_integer()}.

-type packet() :: raw | erx_net_packet:type().

-type active() :: boolean() | once | integer().

-doc "A request to the connection (the socket protocol's `{call, N, Request}`).".
-type request() :: {send, binary()} | {shutdown, read | write | read_write} | close
                 | {setopts, [{nodelay, boolean()}]} | {getopts, [nodelay]} | sockname | peername
                 | {accept, pid(), timeout()}.

-type from() :: gen_statem:from().

-doc """
An event: a caller's call; a push from the connection as erx_sock_admit admitted it, or
the check that refused it; the waiting recv's deadline; the connection's exit; the
owner's exit.
""".
-type event() :: {call, from(), term()}
               | {push, {ok, erx_sock_admit:push()} | {refused, erx_sock_admit:check()}}
               | recv_timeout
               | socket_down
               | owner_down.

-doc """
An action, performed in order: a request or a grant of credit to the socket, a reply to
a caller, a message to the owner, the recv timer armed (milliseconds) or cancelled, a
protocol break counted, an accepted connection handed to the socket process started for
it and its caller answered, a socket process started for an accept ended, the end of the
socket process.
""".
-type action() :: {request, non_neg_integer(), request()}
                | {credit, pos_integer()}
                | {reply, from(), term()}
                | {tell, tuple()}
                | {recv_timer, non_neg_integer() | cancel}
                | {count, erx_sock_admit:check()}
                | {hand_over, from(), pid(), pid(), own()}
                | {discard, pid()}
                | {stop, normal}.

%% What a request in flight answers: its caller, and what the core does with its result.
-type tag() :: {send, from()} | {shutdown, from()} | {setopts, from()}
             | {getopts, from(), [{atom(), term()}]} | {sockname, from()} | {peername, from()}
             | {accept, from(), pid()}.

%% A direction's statistics as stock's inet driver keeps them (inet_drv.c,
%% inet_input_count/2 and inet_output_count/2): its bytes, the deliveries that carried
%% them, and the largest delivery.
-record(count, {oct = 0 :: non_neg_integer(), cnt = 0 :: non_neg_integer(), max = 0 :: non_neg_integer()}).

-record(core, {sock :: erx_gen_tcp:socket(),
               state = open :: open | listening | closed,
               mode :: binary | list,
               active :: active(),
               packet :: packet(),
               packet_size :: non_neg_integer(),
               buffer :: pos_integer(),
               held = [] :: [[binary()]],            % pushes' pieces and a take's leftover:
                                                     % lists newest first, each oldest first
               held_bytes = 0 :: non_neg_integer(),
               wait = none :: none | erx_net_packet:wait(), % what the packet in progress waits
                                                     % for; none: frame at the next delivery
               outstanding = 0 :: non_neg_integer(), % credit granted, not yet pushed
               next = 0 :: non_neg_integer(),        % the next request's N
               in_flight = #{} :: #{non_neg_integer() => tag()},
               waiting :: queue:queue({request(), tag()}),
               sending = none :: none | {from(), [binary()]},
               sends :: queue:queue({from(), binary()}),
               recv = none :: none | {from(), non_neg_integer()},
               recvs :: queue:queue({from(), non_neg_integer(), timeout()}),
               ended = none :: none | eof | {error, atom()},  % the end the owner has not been shown
               recv_met_end = false :: boolean(),            % a recv was answered the end
               holding = false :: boolean(),                 % a transfer: nothing presented
               nodelay = false :: boolean(),                 % a listener's, for getopts
               listener_node = none :: node() | none,       % a listener's, for accepted pids
               received = #count{} :: #count{},             % the pushes of data, for getstat
               sent = #count{} :: #count{}}).               % the sends, framed, for getstat

-opaque core() :: #core{}.

-doc """
A core for an open connection presented as `Sock`, with the owner's options `Own`; the
first action grants the connection its target.
""".
-spec new(erx_gen_tcp:socket(), own()) -> {core(), [action()]}.
new(Sock, Own) ->
    settle(fresh(Sock, Own), []).

-doc """
A core for a listener on the node `Node`, presented as `Sock`, whose accepted sockets
start with `Own` and whose connections with `Nodelay`. It sends nothing until its first
`accept`.
""".
-spec listener(erx_gen_tcp:socket(), own(), #{nodelay := boolean(), node := node()}) -> core().
listener(Sock, Own, #{nodelay := Nodelay, node := Node}) ->
    (fresh(Sock, Own))#core{state = listening, nodelay = Nodelay, listener_node = Node}.

-doc """
Holds what the core presents while its socket moves to a new owner; `{error, closed}`
for a closed core whose owner was shown its end in active mode, which stock's inet has
closed. A passive socket whose recv met the end still moves, as stock's port does.
""".
-spec hold(core()) -> {ok, core()} | {error, closed}.
hold(#core{state = closed, ended = none, recv_met_end = false}) ->
    {error, closed};
hold(C) ->
    {ok, C#core{holding = true}}.

-doc "Ends the hold: what arrived meanwhile is presented, to the new owner.".
-spec release(core()) -> {core(), [action()]}.
release(#core{state = listening} = C) ->
    {C#core{holding = false}, []};
release(C) ->
    settle(C#core{holding = false}, []).

-doc "As options/2 over stock's defaults: a list, active socket with no packet framing.".
-spec options([term()]) -> {ok, own(), [{nodelay, boolean()}]} | {error, einval}.
options(Opts) ->
    options(Opts, #{mode => list, active => true, packet => raw, packet_size => 0, buffer => ?TARGET}).

-doc """
Splits `gen_tcp`'s options `Opts` into the socket process's own, applied over `Own`,
and those for the connection, each at most once, a later one replacing an earlier as
stock takes them; `{error, einval}` for one neither takes. `Own` is a TCP socket's
own(), or the mode and active a datagram socket keeps.
""".
-spec options([term()], Own) -> {ok, Own, [{nodelay, boolean()}]} | {error, einval}
          when Own :: #{atom() => term()}.
options(Opts, Own) ->
    options(Opts, Own, []).

options([], Own, Fwd) ->
    {ok, Own, lists:reverse(Fwd)};
options([Opt | Rest], Own, Fwd) ->
    case option(Opt, Own) of
        {own, Own1} -> options(Rest, Own1, Fwd);
        {fwd, {Key, _} = Kv} -> options(Rest, Own, [Kv | lists:keydelete(Key, 1, Fwd)]);
        error -> {error, einval}
    end;
options(_Opts, _Own, _Fwd) ->
    {error, einval}.

option(binary, Own) -> keep(mode, binary, Own);
option(list, Own) -> keep(mode, list, Own);
option({mode, M}, Own) when M =:= binary; M =:= list -> keep(mode, M, Own);
option({active, A}, Own) when is_boolean(A); A =:= once -> keep(active, A, Own);
option({active, N}, #{active := Current} = Own) when is_integer(N), N >= -32768, N =< 32767 ->
    %% `{active, N}` adds to a count already running, as inet:setopts/2 does.
    case running(Current) + N of
        Sum when Sum =< 32767 -> keep(active, Sum, Own);
        _ -> error
    end;
option({packet, P}, Own) when P =:= raw; P =:= 0 -> keep(packet, raw, Own);
option({packet, P}, Own) when P =:= 1; P =:= 2; P =:= 4; P =:= line -> keep(packet, P, Own);
option({packet_size, N}, Own) when is_integer(N), N >= 0, N =< ?MAX_PACKET_SIZE -> keep(packet_size, N, Own);
%% stock keeps a buffer of at least one byte; the socket process holds at most 64 MiB.
option({buffer, N}, Own) when is_integer(N) -> keep(buffer, min(max(N, 1), ?MAX_RECV), Own);
option(inet, Own) -> {own, Own};
%% `{header, 0}`, no list header, is stock's default and changes no delivery; ssl sets it
%% (tls_socket:internal_inet_values/1), on a datagram socket too. A header of N bytes is not
%% presented, so any other length is refused.
option({header, 0}, Own) -> {own, Own};
option({nodelay, B}, _Own) when is_boolean(B) -> {fwd, {nodelay, B}};
option(_, _) -> error.

%% An option of the socket's own sets its key in Own, and only a key Own holds: each kind
%% of socket passes the options it keeps, so one it does not keep (a datagram socket's
%% `buffer` or `packet`) is refused, never added.
keep(Key, Value, Own) when is_map_key(Key, Own) -> {own, Own#{Key := Value}};
keep(_Key, _Value, _Own) -> error.

running(Count) when is_integer(Count) -> Count;
running(_) -> 0.

-doc """
Splits `gen_tcp:listen/2`'s options `Opts` (the family and local address taken out by
local/1) into the listening socket process's own, the presentation options its accepted
sockets start with, applied over stock's defaults, and the listener's: `backlog`,
`reuseaddr`, `reuseport` and `nodelay`, whose values the grant checks.
""".
-spec listen_options([term()]) -> {ok, own(), [{atom(), term()}]} | {error, einval}.
listen_options(Opts) ->
    {Listener, Rest} = lists:partition(fun listener_option/1, Opts),
    case options(Rest) of
        {ok, Own, Fwd} -> {ok, Own, Listener ++ Fwd};
        {error, _} = Error -> Error
    end.

listener_option({Key, _}) -> Key =:= backlog orelse Key =:= reuseaddr orelse Key =:= reuseport;
listener_option(_) -> false.

-doc """
Takes the family and the local address out of an open's options `Opts`: `inet`, and
`{ip, Ip}` or `{ifaddr, Ip}` with an IPv4 address, the last one given; `any` when none
names one. Another family is `{error, eafnosupport}`.
""".
-spec local([term()]) -> {ok, any | inet:ip4_address(), [term()]} | {error, eafnosupport}.
local(Opts) ->
    local(Opts, any, []).

local([], Local, Rest) -> {ok, Local, lists:reverse(Rest)};
local([inet | Opts], Local, Rest) -> local(Opts, Local, Rest);
local([Family | _], _, _) when Family =:= inet6; Family =:= local -> {error, eafnosupport};
local([{Key, {_, _, _, _} = Ip} | Opts], _, Rest) when Key =:= ip; Key =:= ifaddr ->
    local(Opts, Ip, Rest);
local([Opt | Opts], Local, Rest) -> local(Opts, Local, [Opt | Rest]).

%% The option names the connection answers.
-define(SOCKET_NAMES, [nodelay]).

-doc "Steps `Event`: the next core and the actions to perform, in order.".
-spec step(event(), core()) -> {core(), [action()]}.
step({call, From, close}, #core{state = closed} = C) ->
    {C, [{reply, From, ok}, {stop, normal}]};
step({call, From, close}, C) ->
    {N, C1} = number(C),
    {C1, [{request, N, close}, {reply, From, ok}, {stop, normal}]};
step({call, From, {getstat, Names}}, C) when is_list(Names) ->
    {C, [{reply, From, stats(Names, C)}]};
step({call, From, Call}, #core{state = open} = C) ->
    call(Call, From, C);
step({call, From, Call}, #core{state = listening} = C) ->
    listening_call(Call, From, C);
step({call, From, Call}, C) ->
    closed_call(Call, From, C);
step({push, {refused, Check}}, #core{state = State} = C) when State =/= closed ->
    abort(Check, C);
step({push, {ok, Body}}, #core{state = open} = C) ->
    push(Body, C);
step({push, {ok, {reply, N, Result}}}, #core{state = listening} = C) ->
    replied(N, Result, C);
step({push, {ok, _}}, #core{state = listening} = C) ->
    abort(push, C);
step({push, _}, C) ->
    {C, []};
step(recv_timeout, #core{recv = {From, _}} = C) ->
    next_recv(C#core{recv = none}, [{reply, From, {error, timeout}}]);
step(recv_timeout, C) ->
    {C, []};
step(socket_down, #core{state = closed} = C) ->
    {C, []};
step(socket_down, C) ->
    ended({error, econnaborted}, C, []);
step(owner_down, #core{state = closed} = C) ->
    {C, [{stop, normal}]};
step(owner_down, C) ->
    {N, C1} = number(C),
    {C1, [{request, N, close}, {stop, normal}]}.

%% --- Calls of an open socket ------------------------------------------------------------

call({send, Data}, From, #core{sent = Sent} = C) when is_binary(Data) ->
    %% Counted when taken, its header included, as stock's driver counts a send.
    Framed = framed(Data, C),
    send(From, Framed, C#core{sent = counted(byte_size(Framed), Sent)});
call({recv, _, _}, From, #core{active = Active} = C) when Active =/= false ->
    {C, [{reply, From, {error, einval}}]};
call({recv, Length, _}, From, #core{packet = Packet} = C) when Packet =/= raw, Length =/= 0 ->
    {C, [{reply, From, {error, einval}}]};
call({recv, Length, _}, From, C) when is_integer(Length), Length > ?MAX_RECV ->
    {C, [{reply, From, {error, enomem}}]};
call({recv, Length, Timeout}, From, #core{recv = none} = C) when ?IS_RECV(Length, Timeout) ->
    start_recv(From, Length, Timeout, C, []);
call({recv, Length, Timeout}, From, #core{recvs = Q} = C) when ?IS_RECV(Length, Timeout) ->
    {C#core{recvs = queue:in({From, Length, Timeout}, Q)}, []};
call({shutdown, How}, From, C) when How =:= read; How =:= write; How =:= read_write ->
    issue({shutdown, How}, {shutdown, From}, C, []);
call({setopts, Opts}, From, C) ->
    %% The socket process's own options take effect at once; the caller is answered when
    %% the connection has taken the rest.
    case options(Opts, own(C)) of
        {ok, Own, []} ->
            {C1, Acts} = apply_own(Own, C),
            settle(C1, Acts ++ [{reply, From, ok}]);
        {ok, Own, Fwd} ->
            {C1, Acts} = apply_own(Own, C),
            {C2, Acts2} = issue({setopts, Fwd}, {setopts, From}, C1, Acts),
            settle(C2, Acts2);
        {error, _} = Error ->
            {C, [{reply, From, Error}]}
    end;
call({getopts, Names}, From, C) when is_list(Names) ->
    Local = values(Names, own(C)),
    case [Name || Name <- lists:uniq(Names), lists:member(Name, ?SOCKET_NAMES)] of
        [] -> {C, [{reply, From, {ok, Local}}]};
        Asked -> issue({getopts, Asked}, {getopts, From, Local}, C, [])
    end;
call(sockname, From, C) ->
    issue(sockname, {sockname, From}, C, []);
call(peername, From, C) ->
    issue(peername, {peername, From}, C, []);
call(_Call, From, C) ->
    {C, [{reply, From, {error, einval}}]}.

send(From, Framed, #core{sending = none} = C) ->
    start_send(From, Framed, C, []);
send(From, Framed, #core{sends = Q} = C) ->
    {C#core{sends = queue:in({From, Framed}, Q)}, []}.

own(#core{mode = Mode, active = Active, packet = Packet, packet_size = Size, buffer = Buffer}) ->
    #{mode => Mode, active => Active, packet => Packet, packet_size => Size, buffer => Buffer}.

%% A core with nothing held, queued or waiting, presenting as Own says; built whole, so
%% no field is ever undefined against its declared type.
fresh(Sock, #{mode := Mode, active := Active, packet := Packet, packet_size := Size, buffer := Buffer}) ->
    #core{sock = Sock, mode = Mode, active = Active, packet = Packet, packet_size = Size, buffer = Buffer,
          waiting = queue:new(), sends = queue:new(), recvs = queue:new()}.

set_own(#{mode := Mode, active := Active, packet := Packet, packet_size := Size, buffer := Buffer}, C) ->
    %% A packet in progress is framed again only under new framing options.
    Wait = case C of
               #core{packet = Packet, packet_size = Size, buffer = Buffer, wait = Kept} -> Kept;
               _ -> none
           end,
    C#core{mode = Mode, active = Active, packet = Packet, packet_size = Size, buffer = Buffer, wait = Wait}.

%% The values of the named options Known holds, in the order asked, as stock shows them:
%% no packet framing is `{packet, 0}`.
%% `header` is always 0, the only length option/2 takes.
values(Names, Known) ->
    Shown = Known#{header => 0},
    [{Name, shown(Name, Value)} || Name <- Names, {ok, Value} <- [maps:find(Name, Shown)]].

shown(packet, raw) -> 0;
shown(_Name, Value) -> Value.

%% A send's bytes as they go on the stream: in a length mode after their header.
framed(Data, #core{packet = raw}) -> Data;
framed(Data, #core{packet = Packet}) -> erx_net_packet:encode(Packet, Data).

%% The owner's options applied. A socket turning active answers the recvs that wait,
%% `{error, einval}`, as a recv of an active socket is answered.
apply_own(#{active := false} = Own, C) ->
    {set_own(Own, C), []};
apply_own(Own, #core{recv = Recv, recvs = Recvs} = C) ->
    Current = [[{reply, From, {error, einval}}, {recv_timer, cancel}] || {From, _} <- [Recv]],
    Queued = [{reply, From, {error, einval}} || {From, _, _} <- queue:to_list(Recvs)],
    {set_own(Own, C#core{recv = none, recvs = queue:new()}), lists:append(Current) ++ Queued}.

%% --- Calls of a listening socket --------------------------------------------------------

%% An accept goes to the listener, naming the socket process started for its caller; the
%% options are the core's own but for `nodelay`, which it keeps and forwards; what only a
%% connection answers is `enotconn`, as on stock.
listening_call({accept, SockProc, Timeout}, From, C) when ?IS_TIMEOUT(Timeout) ->
    issue({accept, SockProc, Timeout}, {accept, From, SockProc}, C, []);
listening_call({accept, SockProc, _}, From, C) ->
    {C, refuse_accept(From, SockProc, einval)};
listening_call({setopts, Opts}, From, #core{nodelay = Nodelay} = C) ->
    case options(Opts, own(C)) of
        {ok, Own, Fwd} ->
            C1 = set_own(Own, C#core{nodelay = proplists:get_value(nodelay, Fwd, Nodelay)}),
            case Fwd of
                [] -> {C1, [{reply, From, ok}]};
                _ -> issue({setopts, Fwd}, {setopts, From}, C1, [])
            end;
        {error, _} = Error ->
            {C, [{reply, From, Error}]}
    end;
listening_call({getopts, Names}, From, #core{nodelay = Nodelay} = C) when is_list(Names) ->
    {C, [{reply, From, {ok, values(Names, (own(C))#{nodelay => Nodelay})}}]};
listening_call(sockname, From, C) ->
    issue(sockname, {sockname, From}, C, []);
listening_call(peername, From, C) ->
    {C, [{reply, From, {error, enotconn}}]};
listening_call({Op, _}, From, C) when Op =:= send; Op =:= shutdown ->
    {C, [{reply, From, {error, enotconn}}]};
listening_call({recv, _, _}, From, C) ->
    {C, [{reply, From, {error, enotconn}}]};
listening_call(_Call, From, C) ->
    {C, [{reply, From, {error, einval}}]}.

%% An accept answered with an error: its caller is told, and the socket process started for
%% it ends, holding nothing.
refuse_accept(From, SockProc, Reason) ->
    [{reply, From, {error, Reason}}, {discard, SockProc}].

%% Calls of a closed core. A recv takes what is still held, then meets the end; while the
%% owner has not seen the end, it may turn the socket active to be shown it. Everything
%% else is closed.
closed_call({accept, SockProc, _}, From, C) ->
    {C, refuse_accept(From, SockProc, closed)};
closed_call({recv, Length, _}, From, #core{packet = Packet, ended = Ended} = C)
  when Packet =/= raw, Length =/= 0, Ended =/= none ->
    %% While the end waits for the owner, stock's driver is still connected and checks the
    %% packet mode; once a recv met the end or it was shown, it finds the socket closed.
    {C, [{reply, From, {error, einval}}]};
closed_call({recv, Length, _}, From, C) when is_integer(Length), Length >= 0 ->
    case deliver(Length, C) of
        {ok, Data, C1} -> {C1, [{reply, From, {ok, data(C#core.mode, Data)}}]};
        {short, C1} -> recv_meets_end(From, C1);
        {error, Reason, C1} -> recv_meets_end(From, framing_end(Reason, C1))
    end;
closed_call({setopts, Opts}, From, #core{ended = Ended} = C) when Ended =/= none ->
    case options(Opts, own(C)) of
        {ok, Own, []} ->
            {C1, Acts} = apply_own(Own, C),
            settle(C1, Acts ++ [{reply, From, ok}]);
        _ ->
            {C, [{reply, From, {error, closed}}]}
    end;
closed_call(_Call, From, C) ->
    {C, [{reply, From, {error, closed}}]}.

%% --- Requests in flight ---------------------------------------------------------------

number(#core{next = N} = C) ->
    {N, C#core{next = N + 1}}.

%% Sends Request under a new N, or queues it behind the others waiting for a place.
issue(Request, Tag, #core{in_flight = InFlight, waiting = Waiting} = C, Acts) ->
    case map_size(InFlight) < ?MAX_IN_FLIGHT andalso queue:is_empty(Waiting) of
        true ->
            {N, C1} = number(C),
            {C1#core{in_flight = InFlight#{N => Tag}}, Acts ++ [{request, N, Request}]};
        false ->
            {C#core{waiting = queue:in({Request, Tag}, Waiting)}, Acts}
    end.

%% The requests that waited for a place, sent while there is one.
drain(#core{in_flight = InFlight, waiting = Waiting} = C, Acts) ->
    case map_size(InFlight) < ?MAX_IN_FLIGHT andalso queue:out(Waiting) of
        {{value, {Request, Tag}}, Rest} -> drain_one(Request, Tag, C#core{waiting = Rest}, Acts);
        _ -> {C, Acts}
    end.

drain_one(Request, Tag, #core{in_flight = InFlight} = C, Acts) ->
    {N, C1} = number(C),
    drain(C1#core{in_flight = InFlight#{N => Tag}}, Acts ++ [{request, N, Request}]).

start_send(From, <<>>, C, Acts) ->
    next_send(C, Acts ++ [{reply, From, ok}]);
start_send(From, Data, C, Acts) ->
    [Piece | Rest] = cut(Data),
    issue({send, Piece}, {send, From}, C#core{sending = {From, Rest}}, Acts).

next_send(#core{sends = Q} = C, Acts) ->
    case queue:out(Q) of
        {{value, {From, Data}}, Rest} -> start_send(From, Data, C#core{sends = Rest, sending = none}, Acts);
        {empty, _} -> {C#core{sending = none}, Acts}
    end.

%% Data cut into pieces of at most ?PIECE bytes, each a sub-binary of Data.
cut(Data) when byte_size(Data) =< ?PIECE -> [Data];
cut(<<Piece:?PIECE/binary, Rest/binary>>) -> [Piece | cut(Rest)].

%% A reply to request N, checked against its request's reply type.
replied(N, Result, #core{in_flight = InFlight} = C) ->
    case maps:take(N, InFlight) of
        {Tag, Rest} ->
            case erx_sock_admit:result(kind(Tag, C), Result) of
                {ok, Checked} ->
                    {C1, Acts} = answered(Tag, Checked, C#core{in_flight = Rest}),
                    drain(C1, Acts);
                {refused, Check} ->
                    abort(Check, C)
            end;
        error ->
            abort(reply, C)
    end.

%% What a reply is checked as: an accept's connection must be a pid of its listener's node.
kind({accept, _From, _SockProc}, #core{listener_node = Node}) -> {accept, Node};
kind(Tag, _C) -> element(1, Tag).

caller({getopts, From, _Local}) -> From;
caller({accept, From, _SockProc}) -> From;
caller({_Kind, From}) -> From.

answered({send, From}, ok, #core{sending = {From, [Piece | Rest]}} = C) ->
    issue({send, Piece}, {send, From}, C#core{sending = {From, Rest}}, []);
answered({send, From}, Result, C) ->
    next_send(C, [{reply, From, Result}]);
answered({accept, From, SockProc}, {ok, Conn}, C) ->
    {C, [{hand_over, From, SockProc, Conn, own(C)}]};
answered({accept, From, SockProc}, {error, Reason}, C) ->
    {C, refuse_accept(From, SockProc, Reason)};
answered({getopts, From, Local}, {ok, Remote}, C) ->
    {C, [{reply, From, {ok, Local ++ Remote}}]};
answered(Tag, Result, C) ->
    {C, [{reply, caller(Tag), Result}]}.

%% --- Pushes ---------------------------------------------------------------------------

push({reply, N, Result}, C) ->
    replied(N, Result, C);
push({data, _}, #core{ended = Ended} = C) when Ended =/= none ->
    abort(order, C);
push({data, Pieces}, #core{outstanding = Out, held = Held, held_bytes = Bytes, wait = Wait,
                           received = Received} = C) ->
    case iolist_size(Pieces) of
        Size when Size =< Out ->
            settle(C#core{outstanding = Out - Size, held = [Pieces | Held], held_bytes = Bytes + Size,
                          wait = arrived(Wait, Pieces), received = counted(Size, Received)}, []);
        _ ->
            abort(credit, C)
    end;
push(eof, #core{ended = none} = C) ->
    ended(eof, C, []);
push(eof, C) ->
    abort(order, C);
push({error, Reason}, C) ->
    ended({error, Reason}, C, []).

%% --- Statistics -----------------------------------------------------------------------

counted(Size, #count{oct = Oct, cnt = Cnt, max = Max}) ->
    #count{oct = Oct + Size, cnt = Cnt + 1, max = max(Max, Size)}.

%% The named statistics in the order asked: a name not measured here is left out, and
%% one that is no statistic refuses the call, as stock's driver refuses it.
stats(Names, #core{received = Received, sent = Sent}) ->
    case lists:all(fun(Name) -> lists:member(Name, inet:stats()) end, Names) of
        true -> {ok, [{Name, Value} || Name <- Names, Value <- stat(Name, Received, Sent)]};
        false -> {error, einval}
    end.

stat(recv_oct, #count{oct = Oct}, _) -> [Oct];
stat(recv_cnt, #count{cnt = Cnt}, _) -> [Cnt];
stat(recv_max, #count{max = Max}, _) -> [Max];
stat(recv_avg, Received, _) -> [average(Received)];
stat(send_oct, _, #count{oct = Oct}) -> [Oct];
stat(send_cnt, _, #count{cnt = Cnt}) -> [Cnt];
stat(send_max, _, #count{max = Max}) -> [Max];
stat(send_avg, _, Sent) -> [average(Sent)];
stat(_Name, _, _) -> [].

%% The mean delivery, truncated, as stock's inet driver reports it.
average(#count{cnt = 0}) -> 0;
average(#count{oct = Oct, cnt = Cnt}) -> Oct div Cnt.

%% A push that breaks the protocol: counted, and the socket aborted.
abort(Check, C) ->
    ended({error, econnaborted}, C, [{count, Check}]).

%% The end of the stream. The owner is shown the first end only: after `eof` the stream
%% is whole, so a later end means only that the connection is gone.
ended(_End, #core{state = listening} = C, Acts) ->
    close_out(C, Acts);
ended(End, #core{ended = none} = C, Acts) ->
    settle(C#core{ended = End}, Acts);
ended(_End, C, Acts) ->
    close_out(C, Acts).

%% --- Presenting, the end and credit ---------------------------------------------------

%% After any change: a count run out, then what the owner may take, then the end, then
%% the credit.
settle(C, Acts) ->
    {C0, Acts0} = passive_notice(C, Acts),
    {C1, Acts1} = present(C0, Acts0),
    {C2, Acts2} = finish(C1, Acts1),
    grant(C2, Acts2).

%% In active mode each delivery is one message, until the count runs out or nothing more
%% can be delivered; in passive mode the waiting recv takes one. A packet over its bound
%% ends the stream there, for finish/2 to show.
present(#core{active = Active, holding = false} = C, Acts) when Active =/= false ->
    {C1, Told} = deliveries(C, []),
    {C1, Acts ++ Told};
present(#core{active = false, recv = {From, Length}} = C, Acts) ->
    case deliver(Length, C) of
        {ok, Data, C1} ->
            next_recv(C1#core{recv = none}, Acts ++ [{reply, From, {ok, data(C#core.mode, Data)}},
                                                    {recv_timer, cancel}]);
        {short, C1} ->
            {C1, Acts};
        {error, Reason, C1} ->
            {framing_end(Reason, C1), Acts}
    end;
present(C, Acts) ->
    {C, Acts}.

%% The active deliveries and the passive notice a count ends in, Told newest first, so a
%% push of many small packets costs one message each.
deliveries(#core{active = false} = C, Told) ->
    {C, lists:reverse(Told)};
deliveries(#core{active = Active, sock = Sock, mode = Mode} = C, Told) ->
    case deliver(0, C) of
        {ok, Data, C1} ->
            Delivered = [{tell, {tcp, Sock, data(Mode, Data)}} | Told],
            case spend(Active) of
                N when is_integer(N), N =< 0 -> deliveries(C1#core{active = false}, [{tell, {tcp_passive, Sock}} | Delivered]);
                Left -> deliveries(C1#core{active = Left}, Delivered)
            end;
        {short, C1} ->
            {C1, lists:reverse(Told)};
        {error, Reason, C1} ->
            {framing_end(Reason, C1), lists:reverse(Told)}
    end.

%% A packet over its bound ends the stream where it would be: it and every byte after it
%% are discarded, and the end is the error, as stock's driver ends it.
framing_end(Reason, C) ->
    discard(C#core{ended = {error, Reason}}).

%% `{active, N}` counts deliveries down to passive; `once` is one.
spend(once) -> false;
spend(N) when is_integer(N) -> N - 1;
spend(Active) -> Active.

passive_notice(#core{active = N, sock = Sock} = C, Acts) when is_integer(N), N =< 0 ->
    {C#core{active = false}, Acts ++ [{tell, {tcp_passive, Sock}}]};
passive_notice(C, Acts) ->
    {C, Acts}.

start_recv(From, Length, Timeout, C, Acts) ->
    {C1, Acts1} = settle(C#core{recv = {From, Length}}, Acts),
    case C1#core.recv of
        {From, _} when is_integer(Timeout) -> {C1, Acts1 ++ [{recv_timer, Timeout}]};
        _ -> {C1, Acts1}
    end.

next_recv(#core{recvs = Q} = C, Acts) ->
    case queue:out(Q) of
        {{value, {From, Length, Timeout}}, Rest} -> start_recv(From, Length, Timeout, C#core{recvs = Rest}, Acts);
        {empty, _} -> {C, Acts}
    end.

%% The next delivery from what is held: in raw mode a recv of Length's bytes, all of them
%% for 0; in a packet mode the next packet, whatever Length. `{short, C}` when none can be
%% made yet, C knowing what the packet in progress waits for; `{error, emsgsize, C}` for a
%% packet over packet_size, for the caller to end the stream with (framing_end/2).
%%
%% A packet in progress waits until what it waits for has arrived (erx_net_packet:arrived/2
%% looks at each push once), then is framed again.
deliver(Length, #core{packet = raw} = C) ->
    case take(wanted(Length), C) of
        {ok, _, _} = Ok -> Ok;
        short -> {short, C}
    end;
deliver(_Length, #core{held_bytes = 0} = C) ->
    {short, C};
deliver(_Length, #core{held_bytes = Bytes, wait = {_, Upto}} = C) when Bytes < Upto ->
    {short, C};
deliver(_Length, C) ->
    frame(C).

%% The next packet of what is held. The oldest piece is framed alone first: framing reads
%% from the front, so a packet, a cut line or an error within it is what the whole would
%% give. Only a packet that runs past it joins what is held, which then stays one binary
%% while the packet waits, so a packet costs a copy of the bytes it spans and each byte
%% is joined about once.
frame(#core{held = Held} = C) ->
    case lists:append(lists:reverse(Held)) of
        [Oldest | [_ | _] = Newer] = Pieces ->
            case decode(Oldest, C) of
                {more, _} -> whole(join(Pieces), C);
                Answer -> framed(Answer, Oldest, Newer, C)
            end;
        [One] ->
            whole(One, C)
    end.

whole(Bytes, C) ->
    framed(decode(Bytes, C), Bytes, [], C).

decode(Bytes, #core{packet = Packet} = C) ->
    erx_net_packet:decode(Packet, Bytes, limits(C)).

%% The answer of framing First, the oldest bytes held, with the pieces Newer after it.
framed({ok, Data, Rest}, First, Newer, #core{held_bytes = Bytes} = C) ->
    Left = [Rest || Rest =/= <<>>] ++ Newer,
    {ok, Data, C#core{held = [Left || Left =/= []], held_bytes = Bytes - (byte_size(First) - byte_size(Rest)),
                      wait = none}};
framed({more, Wait}, First, [], C) ->
    {short, C#core{held = [[First]], wait = Wait}};
framed({error, Reason}, _First, _Newer, C) ->
    {error, Reason, C}.

%% The framing's limits. The longest packet is packet_size, 0 for none, bounded by the
%% most the socket process holds, so a packet never needs more credit than it may grant:
%% a documented difference from stock's driver, which frames up to any packet_size.
limits(#core{packet_size = Size, buffer = Buffer}) ->
    Longest = case Size of
                  0 -> ?MAX_RECV;
                  _ -> min(Size, ?MAX_RECV)
              end,
    #{longest => Longest, buffer => Buffer}.

%% What a push brings the packet in progress.
arrived(none, _Pieces) -> none;
arrived(Wait, Pieces) -> erx_net_packet:arrived(Wait, Pieces).

%% The bytes the packet in progress needs held: a length mode's whole packet; one more
%% than is held for a partial line, up to the bytes that decide it.
packet_need(#core{wait = none}) -> 0;
packet_need(#core{wait = {length, Needed}}) -> Needed;
packet_need(#core{wait = {line, Upto}, held_bytes = Held}) -> min(Held + 1, Upto).

%% What a recv of Length takes: `all` that is held for 0, as gen_tcp:recv/2 does.
wanted(0) -> all;
wanted(Length) -> Length.

%% The first Length bytes held, or `all` of them, or `short` when fewer are held (none,
%% for `all`).
take(all, #core{held_bytes = 0}) ->
    short;
take(all, #core{held_bytes = Bytes} = C) ->
    take(Bytes, C);
take(Length, #core{held_bytes = Bytes}) when Length > Bytes ->
    short;
take(Length, #core{held = Held, held_bytes = Bytes} = C) ->
    {Data, Left} = split(Length, lists:append(lists:reverse(Held))),
    {ok, Data, C#core{held = [Left || Left =/= []], held_bytes = Bytes - Length}}.

%% The first Length bytes of Pieces, the held binaries oldest first, and the binaries
%% after them; take/2 ensures 0 < Length =< the bytes held. A delivery within one piece
%% is a sub-binary of it, not a copy. A delivery across pieces is the join of exactly
%% its bytes, the socket process's one copy of them (docs/design-network-stack.md,
%% "Copies"), so it references only its own bytes and no byte is joined twice. The
%% binaries left stay the pieces or a sub-binary of one.
split(Length, Pieces) ->
    {Head, Left} = cut(Length, Pieces, []),
    {join(Head), Left}.

%% Binaries as one: a single one itself, several joined.
join([One]) -> One;
join(Pieces) -> iolist_to_binary(Pieces).

%% The pieces holding the first Length bytes, the last one cut at them, oldest first,
%% and the pieces after them. Head collects the whole pieces taken, newest first.
cut(Length, [Piece | Rest], Head) when byte_size(Piece) >= Length ->
    <<Last:Length/binary, Tail/binary>> = Piece,
    {lists:reverse(Head, [Last]), [Tail || Tail =/= <<>>] ++ Rest};
cut(Length, [Piece | Rest], Head) ->
    cut(Length - byte_size(Piece), Rest, [Piece | Head]).

data(binary, Data) -> Data;
data(list, Data) -> binary_to_list(Data).

discard(C) ->
    C#core{held = [], held_bytes = 0, wait = none}.

%% A recv that what is held cannot complete. The first one is answered the end, the held
%% bytes discarded; every one after it `{error, enotconn}`, as stock's driver answers
%% once `tcp_recv_closed` or `tcp_recv_error` has closed its socket. A recv after the end
%% was shown in active mode finds the socket closed.
recv_meets_end(From, #core{ended = none, recv_met_end = true} = C) ->
    {C, [{reply, From, {error, enotconn}}]};
recv_meets_end(From, #core{ended = none} = C) ->
    {C, [{reply, From, {error, closed}}]};
recv_meets_end(From, C) ->
    {discard(C#core{ended = none, recv_met_end = true}), [{reply, From, {error, end_reason(C)}}]}.

end_reason(#core{ended = {error, Reason}}) -> Reason;
end_reason(_) -> closed.

%% The end, once what is held has been presented: see the module's documentation.
%% `ended` is the end the owner has not been shown yet; `state` is whether the connection
%% still takes requests. They part in passive mode, where the end waits for the owner.
finish(#core{ended = none} = C, Acts) ->
    {C, Acts};
finish(#core{active = Active, holding = false, ended = Ended, sock = Sock} = C, Acts) when Active =/= false ->
    Error = [{tell, {tcp_error, Sock, Reason}} || {error, Reason} <- [Ended], Reason =/= closed],
    close_out(C#core{ended = none}, Acts ++ Error ++ [{tell, {tcp_closed, Sock}}]);
finish(#core{recv = {From, _}} = C, Acts) ->
    {C1, Reply} = recv_meets_end(From, C#core{recv = none}),
    close_out(C1, Acts ++ Reply ++ [{recv_timer, cancel}]);
finish(#core{ended = eof} = C, Acts) ->
    %% Passive after the peer's FIN: sends go on until a recv meets the end.
    {C, Acts};
finish(C, Acts) ->
    %% Passive after an error: the connection is gone, and the end waits for the owner.
    close_out(C, Acts).

%% Closed: the socket is told `close`, and every call the core holds is answered, an
%% accept's socket process ended. What is held and the end not yet shown stay for the owner.
close_out(#core{state = closed} = C, Acts) ->
    {C, Acts};
close_out(#core{in_flight = InFlight, waiting = Waiting, sending = Sending, sends = Sends,
                recv = Recv, recvs = Recvs} = C, Acts) ->
    {N, C1} = number(C),
    Callers = [caller(Tag) || Tag <- maps:values(InFlight)]
        ++ [caller(Tag) || {_, Tag} <- queue:to_list(Waiting)]
        ++ [From || {From, _} <- [Sending]]
        ++ [From || {From, _} <- queue:to_list(Sends)]
        ++ [From || {From, _} <- [Recv]]
        ++ [From || {From, _, _} <- queue:to_list(Recvs)],
    Closed = [{reply, From, {error, closed}} || From <- lists:uniq(Callers)],
    Discards = [{discard, SockProc} || {accept, _, SockProc} <- maps:values(InFlight)
                                                              ++ [Tag || {_, Tag} <- queue:to_list(Waiting)]],
    Timer = [{recv_timer, cancel} || Recv =/= none],
    {C1#core{state = closed, in_flight = #{}, waiting = queue:new(), sending = none,
             sends = queue:new(), recv = none, recvs = queue:new()},
     Acts ++ [{request, N, close} | Closed] ++ Discards ++ Timer}.

%% The credit rule: the shortfall below the target, granted once it reaches half the
%% target, or at once when a waiting recv or the packet in progress needs more than is
%% held and outstanding. The credit outstanding never passes 64 MiB, the most the
%% connection keeps (erx_tcp_conn's MAX_PUSH_CREDIT), whatever a recv or a packet asks for.
grant(#core{state = open, ended = none, held_bytes = Held, outstanding = Out, recv = Recv, buffer = Buffer} = C,
      Acts) ->
    RecvLength = case Recv of
                     {_, Length} -> Length;
                     none -> 0
                 end,
    Need = max(RecvLength, packet_need(C)),
    Target = max(Buffer, Need),
    Short = min(Target - Held - Out, ?MAX_RECV - Out),
    Waits = Need > Held + Out orelse (Recv =/= none andalso Held + Out =:= 0),
    case Short > 0 andalso (Short >= Target div 2 orelse Waits) of
        true -> {C#core{outstanding = Out + Short}, Acts ++ [{credit, Short}]};
        false -> {C, Acts}
    end;
grant(C, Acts) ->
    {C, Acts}.
