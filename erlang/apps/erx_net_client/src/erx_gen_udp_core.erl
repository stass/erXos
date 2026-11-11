%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_udp_core).
-moduledoc """
The decisions of a datagram socket process (docs/design-network-stack.md, "The socket
process", "Credit", "Requests in flight"): a pure step, `step(Event, Core) -> {Core,
[Action]}`, over what the socket process holds for its owner. erx_gen_udp is the effect
shell around it: it performs the actions in order and turns messages and its one timer
into events. The core reads no clock and sends nothing.

One core serves both datagram kinds: `udp`, a UDP socket, whose socket pushes
`{datagram, Ip, Port, Data}`, and `icmp`, an echo socket, whose socket pushes `{echo, Ip,
Ttl, Seq, Data}`, one echo reply. Each push is one whole datagram, held as it came.

**Requests.** Every call that needs the socket becomes `{request, N, Request}`, `N` the
core's count of its requests, so a reply names the request it answers. At most 64 requests
are in flight; a call past that waits, in arrival order, until a reply frees a place. A
UDP datagram larger than IPv4 allows (65,507 bytes) is refused here with `{error,
emsgsize}` before anything is sent, and an echo request's data likewise. `close` goes out
at once, is answered `ok`, and ends the socket process; every other call it holds is
answered `{error, closed}`.

**Credit.** The socket pushes a datagram only when the credit the core granted covers
its cost, its length or one byte for an empty one, so no push is free. The core keeps
what it holds plus the credit outstanding at its target, 128 KiB, twice the largest UDP
payload, and grants the shortfall once it reaches half the target, so a datagram never
waits in its socket while the core holds nothing. A push past the credit outstanding, a
reply to a request not in flight, a reply that fails its reply type, or a push of the
other kind's shape breaks the protocol: the socket is closed and every call held is
answered `{error, closed}`.

**Presenting.** A UDP socket in active mode presents each datagram at once as stock's
`{udp, S, Ip, Port, Data}` (a list in `list` mode); `{active, once}` turns passive after
one delivery, with no notice, and `{active, N}` counts deliveries down and sends
`{udp_passive, S}` once the count is at or below zero, at once when it is set or opened
so, as stock's inet does. In passive mode, the only mode
of an echo socket, a recv takes the oldest datagram held, `{ok, {Ip, Port, Data}}` or an
echo socket's `{ok, {Ip, Ttl, Seq, Data}}`, and waits for one otherwise, behind any
earlier recv, until its timeout; a recv of an active socket answers `{error, einval}`, as
do the recvs waiting when the socket turns active.

**The end.** The socket has no end of its own to push: when it exits the core answers
every call it holds `{error, closed}` and stops, and a call of the stopped socket process
answers as a closed socket. The owner's exit closes the socket.
""".

-export([new/3, step/2]).

-export_type([core/0, kind/0, event/0, action/0]).

-define(MAX_IN_FLIGHT, 64).
%% The target: twice the largest UDP payload (docs/design-network-stack.md, "Credit").
-define(TARGET, 131072).
%% The largest payload an IPv4 datagram carries: 65535 less the IPv4 and UDP or echo
%% headers. The socket's own bound (erx_net_admit) is IPv6's 65,527.
-define(MAX_DATAGRAM, 65507).
%% The longest timer the runtime arms, so a recv's timeout never crashes the socket process.
-define(MAX_TIMEOUT, 4294967295).
-define(IS_TIMEOUT(T), (T =:= infinity orelse (is_integer(T) andalso T >= 0 andalso T =< ?MAX_TIMEOUT))).
-define(IS_BYTE(X), (is_integer(X) andalso X >= 0 andalso X =< 255)).
-define(IS_IP4(T), (tuple_size(T) =:= 4 andalso ?IS_BYTE(element(1, T)) andalso ?IS_BYTE(element(2, T))
                    andalso ?IS_BYTE(element(3, T)) andalso ?IS_BYTE(element(4, T)))).
-define(IS_PORT(P), (is_integer(P) andalso P >= 0 andalso P =< 16#ffff)).

-doc "A datagram socket's kind: UDP, or an ICMP echo socket.".
-type kind() :: udp | icmp.

-type from() :: gen_statem:from().

-doc """
An event: a caller's call; a push from the socket as erx_sock_admit admitted it, or the
check that refused it; the waiting recv's deadline; the socket's exit; the owner's exit.
""".
-type event() :: {call, from(), term()}
               | {push, {ok, erx_sock_admit:push()} | {refused, erx_sock_admit:check()}}
               | recv_timeout
               | socket_down
               | owner_down.

-doc """
An action, performed in order: a request or a grant of credit to the socket, a reply to a
caller, a message to the owner, the recv timer armed (milliseconds) or cancelled, a
protocol break counted, the end of the socket process.
""".
-type action() :: {request, non_neg_integer(), term()}
                | {credit, pos_integer()}
                | {reply, from(), term()}
                | {tell, tuple()}
                | {recv_timer, non_neg_integer() | infinity | cancel}
                | {count, erx_sock_admit:check()}
                | stop.

-record(core, {sock :: tuple(),
               kind :: kind(),
               mode :: binary | list,
               active :: boolean() | once | integer(),
               held = queue:new() :: queue:queue(tuple()),  % datagrams, oldest first
               held_bytes = 0 :: non_neg_integer(),          % their cost
               outstanding = 0 :: non_neg_integer(),         % credit granted, not yet pushed
               next = 0 :: non_neg_integer(),                % the next request's N
               in_flight = #{} :: #{non_neg_integer() => {erx_sock_admit:result_kind(), from()}},
               waiting = queue:new() :: queue:queue({from(), term(), erx_sock_admit:result_kind()}),
               recv = none :: none | from(),                 % the recv waiting for a datagram
               recvs = queue:new() :: queue:queue({from(), timeout()})}).

-opaque core() :: #core{}.

-doc """
A core for the socket `Sock` of kind `Kind`, presenting with `Own`'s `mode` and `active`,
and the actions that start it: the first grant of credit, after the passive notice of a
count set at or below zero. An echo socket is passive only.
""".
-spec new(tuple(), kind(), #{mode := binary | list, active := boolean() | once | integer()}) ->
          {core(), [action()]}.
new(Sock, Kind, #{mode := Mode, active := Active}) when Kind =:= udp; Active =:= false ->
    passive_notice(#core{sock = Sock, kind = Kind, mode = Mode, active = Active}, []).

-doc "Steps `Event`: the next core and the actions to perform, in order.".
-spec step(event(), core()) -> {core(), [action()]}.
step({call, From, Call}, C) ->
    call(Call, From, C);
step({push, {ok, {reply, N, Result}}}, #core{in_flight = InFlight} = C) ->
    case maps:take(N, InFlight) of
        {{Kind, From}, Rest} ->
            case erx_sock_admit:result(Kind, Result) of
                {ok, Checked} -> drain(C#core{in_flight = Rest}, [{reply, From, Checked}]);
                {refused, Check} -> abort(Check, C)
            end;
        error ->
            abort(reply, C)
    end;
step({push, {ok, Datagram}}, C) ->
    datagram(Datagram, C);
step({push, {refused, Check}}, C) ->
    abort(Check, C);
step(recv_timeout, #core{recv = From} = C) when From =/= none ->
    next_recv(C#core{recv = none}, [{reply, From, {error, timeout}}]);
step(recv_timeout, C) ->
    {C, []};
step(socket_down, C) ->
    {C, closed_replies(C) ++ [stop]};
step(owner_down, C) ->
    {N, C1} = number(C),
    {C1, [{request, N, close}, stop]}.

%% --- Calls ---------------------------------------------------------------------------

call(close, From, C) ->
    {N, C1} = number(C),
    {C1, [{request, N, close}, {reply, From, ok} | closed_replies(C1)] ++ [stop]};
call({recv, Timeout}, From, #core{active = false, recv = none} = C) when ?IS_TIMEOUT(Timeout) ->
    start_recv(From, Timeout, C, []);
call({recv, Timeout}, From, #core{active = false, recvs = Recvs} = C) when ?IS_TIMEOUT(Timeout) ->
    {C#core{recvs = queue:in({From, Timeout}, Recvs)}, []};
call({setopts, Opts}, From, #core{kind = udp} = C) ->
    case erx_gen_tcp_core:options(Opts, own(C)) of
        {ok, Own, []} -> setopts(Own, From, C);
        _ -> {C, [{reply, From, {error, einval}}]}
    end;
call({getopts, Names}, From, #core{kind = udp} = C) when is_list(Names) ->
    Own = own(C),
    case lists:all(fun(Name) -> is_map_key(Name, Own) end, Names) of
        true -> {C, [{reply, From, {ok, [{Name, maps:get(Name, Own)} || Name <- Names]}}]};
        false -> {C, [{reply, From, {error, einval}}]}
    end;
call(Call, From, C) ->
    case request(Call, C#core.kind) of
        {ok, Request, Kind} -> issue(From, Request, Kind, C);
        {error, _} = Error -> {C, [{reply, From, Error}]}
    end.

%% A call the socket answers: the request to send and the kind of its reply, or the
%% refusal the socket would answer, given here before anything is sent.
request({send_to, Ip, Port, Data}, udp) when is_tuple(Ip), ?IS_IP4(Ip), ?IS_PORT(Port), is_binary(Data) ->
    sized({send_to, Ip, Port, Data}, Data, udp_send);
request({send, Data}, udp) when is_binary(Data) ->
    sized({send, Data}, Data, udp_send);
request({connect, Ip, Port}, udp) when is_tuple(Ip), ?IS_IP4(Ip), ?IS_PORT(Port), Port > 0 ->
    {ok, {connect, Ip, Port}, udp_connect};
request(sockname, udp) ->
    {ok, sockname, sockname};
request({echo_send, Ip, Seq, Ttl, Data}, icmp)
  when is_tuple(Ip), ?IS_IP4(Ip), ?IS_PORT(Seq), (Ttl =:= default orelse (is_integer(Ttl) andalso Ttl >= 1 andalso Ttl =< 255)),
       is_binary(Data) ->
    sized({echo_send, Ip, Seq, Ttl, Data}, Data, echo_send);
request(_Call, _Kind) ->
    {error, einval}.

sized(Request, Data, Kind) when byte_size(Data) =< ?MAX_DATAGRAM -> {ok, Request, Kind};
sized(_Request, _Data, _Kind) -> {error, emsgsize}.

%% A request goes out when it has a place, else waits behind the others in arrival order.
issue(From, Request, Kind, #core{in_flight = InFlight, waiting = Waiting} = C) ->
    case map_size(InFlight) < ?MAX_IN_FLIGHT andalso queue:is_empty(Waiting) of
        true -> send(From, Request, Kind, C, []);
        false -> {C#core{waiting = queue:in({From, Request, Kind}, Waiting)}, []}
    end.

send(From, Request, Kind, #core{in_flight = InFlight} = C0, Acts) ->
    {N, C} = number(C0),
    {C#core{in_flight = InFlight#{N => {Kind, From}}}, Acts ++ [{request, N, Request}]}.

%% A reply freed a place: the oldest waiting call takes it.
drain(#core{waiting = Waiting} = C, Acts) ->
    case queue:out(Waiting) of
        {{value, {From, Request, Kind}}, Rest} -> send(From, Request, Kind, C#core{waiting = Rest}, Acts);
        {empty, _} -> {C, Acts}
    end.

number(#core{next = N} = C) ->
    {N, C#core{next = N + 1}}.

own(#core{mode = Mode, active = Active}) ->
    #{mode => Mode, active => Active}.

%% The owner's options applied. A socket turning active answers the recvs that wait,
%% `{error, einval}`, and is shown what is held.
setopts(#{mode := Mode, active := false}, From, C) ->
    {C#core{mode = Mode, active = false}, [{reply, From, ok}]};
setopts(#{mode := Mode, active := Active}, From, #core{recv = Recv, recvs = Recvs} = C) ->
    Current = lists:append([[{reply, R, {error, einval}}, {recv_timer, cancel}] || R <- [Recv], R =/= none]),
    Queued = [{reply, R, {error, einval}} || {R, _} <- queue:to_list(Recvs)],
    passive_notice(C#core{mode = Mode, active = Active, recv = none, recvs = queue:new()},
                   [{reply, From, ok} | Current ++ Queued]).

%% --- Datagrams -----------------------------------------------------------------------

%% A push of the socket's own kind, within the credit outstanding, is held and presented;
%% any other closes the socket.
datagram(Datagram, #core{kind = Kind} = C) ->
    case shape(Kind, Datagram) of
        true -> credited(Datagram, cost(Datagram), C);
        false -> abort(push, C)
    end.

credited(Datagram, Cost, #core{outstanding = Out, held = Held, held_bytes = Bytes} = C) when Cost =< Out ->
    present(C#core{outstanding = Out - Cost, held = queue:in(Datagram, Held), held_bytes = Bytes + Cost}, []);
credited(_Datagram, _Cost, C) ->
    abort(credit, C).

shape(udp, Datagram) -> element(1, Datagram) =:= datagram;
shape(icmp, Datagram) -> element(1, Datagram) =:= echo.

%% A datagram's cost in credit: its length, and one byte for an empty one.
cost(Datagram) ->
    max(1, byte_size(element(tuple_size(Datagram), Datagram))).

%% What is held goes to the owner in active mode, else to the waiting recv; then credit.
present(#core{active = false, recv = From} = C, Acts) when From =/= none ->
    case take(C) of
        {ok, Reply, C1} -> next_recv(C1#core{recv = none}, Acts ++ [{reply, From, {ok, Reply}}, {recv_timer, cancel}]);
        empty -> grant(C, Acts)
    end;
present(#core{active = false} = C, Acts) ->
    grant(C, Acts);
present(#core{active = Active, sock = Sock} = C, Acts) ->
    case take(C) of
        {ok, {Ip, Port, Data}, C1} ->
            passive_notice(C1#core{active = spend(Active)}, Acts ++ [{tell, {udp, Sock, Ip, Port, Data}}]);
        empty ->
            grant(C, Acts)
    end.

%% `{active, N}` counts deliveries down to passive; `once` is one, and turns passive
%% without a notice.
spend(once) -> false;
spend(N) when is_integer(N) -> N - 1;
spend(Active) -> Active.

%% A count at or below zero turns the socket passive with stock's notice; any other mode
%% goes on presenting.
passive_notice(#core{active = N, sock = Sock} = C, Acts) when is_integer(N), N =< 0 ->
    grant(C#core{active = false}, Acts ++ [{tell, {udp_passive, Sock}}]);
passive_notice(C, Acts) ->
    present(C, Acts).

%% The oldest datagram held, as a recv or the owner is shown it.
take(#core{held = Held, held_bytes = Bytes, mode = Mode} = C) ->
    case queue:out(Held) of
        {{value, Datagram}, Rest} -> {ok, shown(Datagram, Mode), C#core{held = Rest, held_bytes = Bytes - cost(Datagram)}};
        {empty, _} -> empty
    end.

shown({datagram, Ip, Port, Data}, list) -> {Ip, Port, binary_to_list(Data)};
shown({datagram, Ip, Port, Data}, binary) -> {Ip, Port, Data};
shown({echo, Ip, Ttl, Seq, Data}, _Mode) -> {Ip, Ttl, Seq, Data}.

%% A recv that waits for a datagram, its deadline armed, or answered from what is held.
start_recv(From, Timeout, C, Acts) ->
    case take(C) of
        {ok, Reply, C1} -> next_recv(C1, Acts ++ [{reply, From, {ok, Reply}}]);
        empty -> grant(C#core{recv = From}, Acts ++ [{recv_timer, Timeout}])
    end.

next_recv(#core{recvs = Recvs} = C, Acts) ->
    case queue:out(Recvs) of
        {{value, {From, Timeout}}, Rest} -> start_recv(From, Timeout, C#core{recvs = Rest}, Acts);
        {empty, _} -> grant(C, Acts)
    end.

%% The credit rule: the shortfall below the target, granted once it reaches half the target.
grant(#core{held_bytes = Held, outstanding = Out} = C, Acts) ->
    case ?TARGET - Held - Out of
        Short when Short >= ?TARGET div 2 -> {C#core{outstanding = Out + Short}, Acts ++ [{credit, Short}]};
        _ -> {C, Acts}
    end.

%% --- The end -------------------------------------------------------------------------

%% A protocol break: counted, the socket closed, every call held answered closed.
abort(Check, C) ->
    {N, C1} = number(C),
    {C1, [{count, Check}, {request, N, close} | closed_replies(C1)] ++ [stop]}.

%% Every call the core holds, answered as a closed socket's.
closed_replies(#core{in_flight = InFlight, waiting = Waiting, recv = Recv, recvs = Recvs}) ->
    Froms = [From || {_, From} <- maps:values(InFlight)]
        ++ [From || {From, _, _} <- queue:to_list(Waiting)]
        ++ [From || From <- [Recv], From =/= none]
        ++ [From || {From, _} <- queue:to_list(Recvs)],
    [{reply, From, {error, closed}} || From <- Froms].
