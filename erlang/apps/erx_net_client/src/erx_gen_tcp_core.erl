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
keeps what it holds plus the credit outstanding at its target: the receive buffer's
64 KiB, raised to a waiting `recv(S, Length)`'s `Length`, up to stock's 64 MiB. It grants
the shortfall once it reaches half the target, so credit costs one message per half
target received, and at once when a waiting recv needs more than it holds and has
outstanding. So the socket process holds at most its target, and the connection pushes
nothing the core has not asked for. A push past the credit outstanding, a reply to a
request not in flight, or a reply that fails its reply type breaks the protocol: the
socket is aborted with `econnaborted`.

**Presenting.** In active mode every push is presented at once, as one `{tcp, S, Data}`
(its pieces joined into one binary, or a list in `list` mode); `{active, once}` and
`{active, N}` count deliveries down and send `{tcp_passive, S}` at zero. A passive
`recv(S, 0)` takes all that is held, `recv(S, Length)` exactly `Length` bytes; a recv
that times out leaves what is held for the next one. Recvs that wait when the socket
turns active are answered `{error, einval}`, as a recv of an active socket is.

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
from what is still held, takes `setopts` while the end waits for the owner, and answers
every other call but `close` with `{error, closed}`.
""".

-export([new/2, step/2, options/2]).

-export_type([core/0, event/0, action/0, request/0, own/0]).

%% The piece: what one request or push carries at most (docs/design-network-stack.md,
%% "Message sizes").
-define(PIECE, 65536).
-define(MAX_IN_FLIGHT, 64).
%% The default target: the connection's receive buffer (erx_tcp_conn's RCVBUF).
-define(TARGET, 65536).
%% stock's TCP_MAX_PACKET_SIZE, the longest recv (inet_drv.c).
-define(MAX_RECV, 67108864).
-define(IS_RECV(L, T), (is_integer(L) andalso L >= 0 andalso
                         (T =:= infinity orelse (is_integer(T) andalso T >= 0 andalso T =< ?MAX_TIMEOUT)))).
%% The longest timer the runtime arms, so a recv's timeout never crashes the socket process.
-define(MAX_TIMEOUT, 4294967295).

-doc "The options the socket process keeps: how it presents data to its owner.".
-type own() :: #{mode := binary | list, active := active()}.

-type active() :: boolean() | once | integer().

-doc "A request to the connection (the socket protocol's `{call, N, Request}`).".
-type request() :: {send, binary()} | {shutdown, read | write | read_write} | close
                 | {setopts, [{nodelay, boolean()}]} | {getopts, [nodelay]} | sockname | peername.

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
An action, performed in order: a request or a grant of credit to the connection, a
reply to a caller, a message to the owner, the recv timer armed (milliseconds) or
cancelled, a protocol break counted, the end of the socket process.
""".
-type action() :: {request, non_neg_integer(), request()}
                | {credit, pos_integer()}
                | {reply, from(), term()}
                | {tell, tuple()}
                | {recv_timer, non_neg_integer() | cancel}
                | {count, erx_sock_admit:check()}
                | stop.

%% What a request in flight answers: its caller, and what the core does with its result.
-type tag() :: {send, from()} | {shutdown, from()} | {setopts, from()}
             | {getopts, from(), [{atom(), term()}]} | {sockname, from()} | {peername, from()}.

-record(core, {sock :: erx_gen_tcp:socket(),
               state = open :: open | closed,
               mode :: binary | list,
               active :: active(),
               held = [] :: [iodata()],              % pushes, newest first
               held_bytes = 0 :: non_neg_integer(),
               outstanding = 0 :: non_neg_integer(), % credit granted, not yet pushed
               next = 0 :: non_neg_integer(),        % the next request's N
               in_flight = #{} :: #{non_neg_integer() => tag()},
               waiting :: queue:queue({request(), tag()}),
               sending = none :: none | {from(), [binary()]},
               sends :: queue:queue({from(), binary()}),
               recv = none :: none | {from(), non_neg_integer()},
               recvs :: queue:queue({from(), non_neg_integer(), timeout()}),
               ended = none :: none | eof | {error, atom()},  % the end the owner has not been shown
               recv_met_end = false :: boolean()}).          % a recv was answered the end

-opaque core() :: #core{}.

-doc """
A core for an open connection presented as `Sock`, with the owner's options `Own`; the
first action grants the connection its target.
""".
-spec new(erx_gen_tcp:socket(), own()) -> {core(), [action()]}.
new(Sock, #{mode := Mode, active := Active}) ->
    settle(#core{sock = Sock, mode = Mode, active = Active, waiting = queue:new(),
                 sends = queue:new(), recvs = queue:new()}, []).

-doc """
Splits `gen_tcp`'s options `Opts` into the socket process's own, applied over `Own`,
and those for the connection; `{error, einval}` for one neither takes.
""".
-spec options([term()], own()) -> {ok, own(), [{nodelay, boolean()}]} | {error, einval}.
options(Opts, Own) ->
    options(Opts, Own, []).

options([], Own, Fwd) ->
    {ok, Own, lists:reverse(Fwd)};
options([Opt | Rest], Own, Fwd) ->
    case option(Opt, Own) of
        {own, Own1} -> options(Rest, Own1, Fwd);
        {fwd, Kv} -> options(Rest, Own, [Kv | Fwd]);
        error -> {error, einval}
    end;
options(_Opts, _Own, _Fwd) ->
    {error, einval}.

option(binary, Own) -> {own, Own#{mode := binary}};
option(list, Own) -> {own, Own#{mode := list}};
option({mode, M}, Own) when M =:= binary; M =:= list -> {own, Own#{mode := M}};
option({active, A}, Own) when is_boolean(A); A =:= once -> {own, Own#{active := A}};
option({active, N}, #{active := Current} = Own) when is_integer(N), N >= -32768, N =< 32767 ->
    %% `{active, N}` adds to a count already running, as inet:setopts/2 does.
    case running(Current) + N of
        Sum when Sum =< 32767 -> {own, Own#{active := Sum}};
        _ -> error
    end;
option({packet, P}, Own) when P =:= raw; P =:= 0 -> {own, Own};
option(inet, Own) -> {own, Own};
option({nodelay, B}, _Own) when is_boolean(B) -> {fwd, {nodelay, B}};
option(_, _) -> error.

running(Count) when is_integer(Count) -> Count;
running(_) -> 0.

%% The option names the connection answers.
-define(SOCKET_NAMES, [nodelay]).

-doc "Steps `Event`: the next core and the actions to perform, in order.".
-spec step(event(), core()) -> {core(), [action()]}.
step({call, From, close}, #core{state = open} = C) ->
    {N, C1} = number(C),
    {C1, [{request, N, close}, {reply, From, ok}, stop]};
step({call, From, close}, C) ->
    {C, [{reply, From, ok}, stop]};
step({call, From, Call}, #core{state = open} = C) ->
    call(Call, From, C);
step({call, From, Call}, C) ->
    closed_call(Call, From, C);
step({push, {refused, Check}}, #core{state = open} = C) ->
    abort(Check, C);
step({push, {ok, Body}}, #core{state = open} = C) ->
    push(Body, C);
step({push, _}, C) ->
    {C, []};
step(recv_timeout, #core{recv = {From, _}} = C) ->
    next_recv(C#core{recv = none}, [{reply, From, {error, timeout}}]);
step(recv_timeout, C) ->
    {C, []};
step(socket_down, #core{state = open} = C) ->
    ended({error, econnaborted}, C, []);
step(socket_down, C) ->
    {C, []};
step(owner_down, #core{state = open} = C) ->
    {N, C1} = number(C),
    {C1, [{request, N, close}, stop]};
step(owner_down, C) ->
    {C, [stop]}.

%% --- Calls of an open socket ------------------------------------------------------------

call({send, Data}, From, #core{sending = none} = C) when is_binary(Data) ->
    start_send(From, Data, C, []);
call({send, Data}, From, #core{sends = Q} = C) when is_binary(Data) ->
    {C#core{sends = queue:in({From, Data}, Q)}, []};
call({recv, _, _}, From, #core{active = Active} = C) when Active =/= false ->
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
    Local = local_opts(Names, C),
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

own(#core{mode = Mode, active = Active}) ->
    #{mode => Mode, active => Active}.

local_opts(Names, C) ->
    Own = own(C),
    [{Name, Value} || Name <- Names, {ok, Value} <- [maps:find(Name, Own)]].

%% The owner's options applied. A socket turning active answers the recvs that wait,
%% `{error, einval}`, as a recv of an active socket is answered.
apply_own(#{mode := Mode, active := false}, C) ->
    {C#core{mode = Mode, active = false}, []};
apply_own(#{mode := Mode, active := Active}, #core{recv = Recv, recvs = Recvs} = C) ->
    Current = [[{reply, From, {error, einval}}, {recv_timer, cancel}] || {From, _} <- [Recv]],
    Queued = [{reply, From, {error, einval}} || {From, _, _} <- queue:to_list(Recvs)],
    {C#core{mode = Mode, active = Active, recv = none, recvs = queue:new()}, lists:append(Current) ++ Queued}.

%% Calls of a closed core. A recv takes what is still held, then meets the end; while the
%% owner has not seen the end, it may turn the socket active to be shown it. Everything
%% else is closed.
closed_call({recv, Length, _}, From, C) when is_integer(Length), Length >= 0 ->
    case take(wanted(Length), C) of
        {ok, Data, C1} -> {C1, [{reply, From, {ok, data(C#core.mode, Data)}}]};
        short -> recv_meets_end(From, C)
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
            case erx_sock_admit:result(kind(Tag), Result) of
                {ok, Checked} ->
                    {C1, Acts} = answered(Tag, Checked, C#core{in_flight = Rest}),
                    drain(C1, Acts);
                {refused, Check} ->
                    abort(Check, C)
            end;
        error ->
            abort(reply, C)
    end.

kind(Tag) -> element(1, Tag).

caller({getopts, From, _Local}) -> From;
caller({_Kind, From}) -> From.

answered({send, From}, ok, #core{sending = {From, [Piece | Rest]}} = C) ->
    issue({send, Piece}, {send, From}, C#core{sending = {From, Rest}}, []);
answered({send, From}, Result, C) ->
    next_send(C, [{reply, From, Result}]);
answered({getopts, From, Local}, {ok, Remote}, C) ->
    {C, [{reply, From, {ok, Local ++ Remote}}]};
answered(Tag, Result, C) ->
    {C, [{reply, caller(Tag), Result}]}.

%% --- Pushes ---------------------------------------------------------------------------

push({reply, N, Result}, C) ->
    replied(N, Result, C);
push({data, _}, #core{ended = Ended} = C) when Ended =/= none ->
    abort(order, C);
push({data, Pieces}, #core{outstanding = Out, held = Held, held_bytes = Bytes} = C) ->
    case iolist_size(Pieces) of
        Size when Size =< Out ->
            settle(C#core{outstanding = Out - Size, held = [Pieces | Held], held_bytes = Bytes + Size}, []);
        _ ->
            abort(credit, C)
    end;
push(eof, #core{ended = none} = C) ->
    ended(eof, C, []);
push(eof, C) ->
    abort(order, C);
push({error, Reason}, C) ->
    ended({error, Reason}, C, []).

%% A push that breaks the protocol: counted, and the socket aborted.
abort(Check, C) ->
    ended({error, econnaborted}, C, [{count, Check}]).

%% The end of the stream. The owner is shown the first end only: after `eof` the stream
%% is whole, so a later end means only that the connection is gone.
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

present(#core{active = Active, held_bytes = Bytes, sock = Sock, mode = Mode} = C, Acts)
  when Active =/= false, Bytes > 0 ->
    {ok, Data, C1} = take(all, C),
    passive_notice(C1#core{active = spend(Active)}, Acts ++ [{tell, {tcp, Sock, data(Mode, Data)}}]);
present(#core{active = false, recv = {From, Length}} = C, Acts) ->
    case take(wanted(Length), C) of
        {ok, Data, C1} ->
            next_recv(C1#core{recv = none}, Acts ++ [{reply, From, {ok, data(C#core.mode, Data)}},
                                                    {recv_timer, cancel}]);
        short ->
            {C, Acts}
    end;
present(C, Acts) ->
    {C, Acts}.

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
    <<Data:Length/binary, Left/binary>> = iolist_to_binary(lists:reverse(Held)),
    {ok, Data, C#core{held = [Left || Left =/= <<>>], held_bytes = Bytes - Length}}.

data(binary, Data) -> Data;
data(list, Data) -> binary_to_list(Data).

discard(C) ->
    C#core{held = [], held_bytes = 0}.

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
finish(#core{active = Active, ended = Ended, sock = Sock} = C, Acts) when Active =/= false ->
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

%% Closed: the connection is told `close`, and every call the core holds is answered.
%% What is held and the end not yet shown stay for the owner.
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
    Timer = [{recv_timer, cancel} || Recv =/= none],
    {C1#core{state = closed, in_flight = #{}, waiting = queue:new(), sending = none,
             sends = queue:new(), recv = none, recvs = queue:new()},
     Acts ++ [{request, N, close} | Closed] ++ Timer}.

%% The credit rule: the shortfall below the target, granted once it reaches half the
%% target, or at once when a waiting recv needs more than is held and outstanding.
grant(#core{state = open, ended = none, held_bytes = Held, outstanding = Out, recv = Recv} = C, Acts) ->
    Need = case Recv of
               {_, Length} -> Length;
               none -> 0
           end,
    Target = max(?TARGET, Need),
    Short = Target - Held - Out,
    Waits = Recv =/= none andalso (Need > Held + Out orelse Held + Out =:= 0),
    case Short > 0 andalso (Short >= Target div 2 orelse Waits) of
        true -> {C#core{outstanding = Out + Short}, Acts ++ [{credit, Short}]};
        false -> {C, Acts}
    end;
grant(C, Acts) ->
    {C, Acts}.
