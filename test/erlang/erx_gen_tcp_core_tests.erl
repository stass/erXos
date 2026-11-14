%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_tcp_core_tests).
-moduledoc """
The socket protocol's pure parts (docs/design-network-stack.md, "The socket process",
"Message sizes", "Requests in flight"): erx_gen_tcp_core's step, and the checks of each
side, erx_sock_admit:push/4 and result/2 for the socket process and
erx_net_admit:request/4 for the connection. The core is driven with events and its
actions read back: a send is cut into pieces sent one at a time and in order, a second
send waits for the first, at most 64 requests are in flight, credit is granted at half
the target and at once for a recv that needs it, and a push past the credit or a reply
to no request aborts the socket.
""".

-include_lib("eunit/include/eunit.hrl").

-define(PIECE, 65536).
-define(SOCK, {'$inet', erx_gen_tcp, self()}).

new(Own) ->
    {Core, Actions} = erx_gen_tcp_core:new(?SOCK, maps:merge(#{mode => binary, active => false}, Own)),
    ?assertEqual([{credit, 65536}], Actions),
    Core.

step(Event, Core) -> erx_gen_tcp_core:step(Event, Core).

call(From, Call, Core) -> step({call, From, Call}, Core).

reply(N, Result, Core) -> step({push, {ok, {reply, N, Result}}}, Core).

data(Bytes, Core) -> step({push, {ok, {data, [binary:copy(<<"d">>, Bytes)]}}}, Core).

requests(Actions) -> [{N, R} || {request, N, R} <- Actions].

core_test_() ->
    [{"a send goes in pieces, one at a time, in order", fun send_in_pieces/0},
     {"a second send waits for the first", fun second_send_waits/0},
     {"a send's first error answers it and the next send goes", fun send_error/0},
     {"at most 64 requests are in flight", fun in_flight_bound/0},
     {"credit is granted again at half the target", fun credit_at_half_target/0},
     {"a waiting recv longer than the target is granted at once", fun recv_raises_target/0},
     {"a push past the credit aborts the socket", fun push_past_credit/0},
     {"a reply to no request aborts the socket", fun reply_to_nothing/0},
     {"a reply off its type aborts the socket", fun reply_off_type/0},
     {"active once and a count of one present one push", fun active_once/0},
     {"a recv that times out leaves what is held", fun recv_timeout_keeps/0},
     {"eof in active mode presents, closes and answers", fun eof_active/0},
     {"the socket's exit is econnaborted", fun socket_down/0},
     {"after eof a passive socket sends until a recv meets the end", fun eof_passive/0},
     {"an error after once ran out waits for the owner to re-arm", fun once_spent_error/0},
     {"the socket's exit after a count ran out waits for the owner", fun count_spent_exit/0},
     {"an abort after once ran out waits for the owner", fun once_spent_abort/0},
     {"eof then closed after once ran out is one tcp_closed", fun once_spent_eof_closed/0},
     {"an error in passive mode waits for a recv", fun passive_error_recv/0},
     {"a waiting recv is answered einval when the socket turns active", fun recv_then_active/0},
     {"a recv timeout past the longest timer is einval", fun recv_timeout_bound/0},
     {"a delivery within one piece shares it, not a copy", fun one_piece_shared/0},
     {"a delivery across pieces joins them in order", fun pieces_joined/0}].

send_in_pieces() ->
    C0 = new(#{}),
    Data = binary:copy(<<"s">>, 2 * ?PIECE + 10),
    {C1, A1} = call(f1, {send, Data}, C0),
    ?assertEqual([{0, {send, binary:part(Data, 0, ?PIECE)}}], requests(A1)),
    {C2, A2} = reply(0, ok, C1),
    ?assertEqual([{1, {send, binary:part(Data, ?PIECE, ?PIECE)}}], requests(A2)),
    {C3, A3} = reply(1, ok, C2),
    ?assertEqual([{2, {send, binary:part(Data, 2 * ?PIECE, 10)}}], requests(A3)),
    {_, A4} = reply(2, ok, C3),
    ?assertEqual([{reply, f1, ok}], A4).

second_send_waits() ->
    C0 = new(#{}),
    {C1, _} = call(f1, {send, <<"one">>}, C0),
    {C2, A2} = call(f2, {send, <<"two">>}, C1),
    ?assertEqual([], A2),
    %% Other calls are not held behind a waiting send.
    {C3, A3} = call(f3, peername, C2),
    ?assertEqual([{1, peername}], requests(A3)),
    {_, A4} = reply(0, ok, C3),
    ?assertEqual([{reply, f1, ok}, {request, 2, {send, <<"two">>}}], A4).

send_error() ->
    C0 = new(#{}),
    {C1, _} = call(f1, {send, binary:copy(<<"e">>, ?PIECE + 1)}, C0),
    {C2, _} = call(f2, {send, <<"next">>}, C1),
    {_, A} = reply(0, {error, epipe}, C2),
    ?assertEqual([{reply, f1, {error, epipe}}, {request, 1, {send, <<"next">>}}], A).

in_flight_bound() ->
    C0 = new(#{}),
    {C1, A1} = lists:foldl(fun(I, {C, Acc}) -> {C2, A} = call({f, I}, sockname, C), {C2, Acc ++ A} end,
                           {C0, []}, lists:seq(1, 65)),
    ?assertEqual(lists:seq(0, 63), [N || {N, _} <- requests(A1)]),
    {_, A2} = reply(7, {ok, {{10, 0, 2, 15}, 4000}}, C1),
    ?assertEqual([{reply, {f, 8}, {ok, {{10, 0, 2, 15}, 4000}}}, {request, 64, sockname}], A2).

%% In active mode every push is presented at once; once the pushes reach half the target
%% the shortfall is granted, one credit message per half target.
credit_at_half_target() ->
    C0 = new(#{active => true}),
    {C1, A1} = data(30000, C0),
    ?assertEqual([], [A || {credit, _} = A <- A1]),
    ?assertMatch([{tell, {tcp, _, _}}], A1),
    {_, A2} = data(3000, C1),
    ?assertEqual([{credit, 33000}], [A || {credit, _} = A <- A2]).

recv_raises_target() ->
    C0 = new(#{}),
    {_, A} = call(f1, {recv, 200000, infinity}, C0),
    ?assertEqual([{credit, 200000 - 65536}], [A1 || {credit, _} = A1 <- A]),
    ?assertEqual({error, enomem}, element(3, hd(element(2, call(f2, {recv, 67108865, 0}, C0))))).

push_past_credit() ->
    C0 = new(#{active => true}),
    {C1, A} = data(65537, C0),
    ?assertMatch([{count, credit}, {tell, {tcp_error, _, econnaborted}}, {tell, {tcp_closed, _}},
                  {request, 0, close}], A),
    ?assertEqual({error, closed}, element(3, hd(element(2, call(f1, {send, <<"x">>}, C1))))).

reply_to_nothing() ->
    {_, A} = reply(5, ok, new(#{})),
    ?assertMatch([{count, reply} | _], A).

reply_off_type() ->
    {C1, _} = call(f1, peername, new(#{})),
    {_, A} = reply(0, {ok, {{10, 0, 2, 256}, 1}}, C1),
    ?assertMatch([{count, shape} | _], A),
    ?assert(lists:member({reply, f1, {error, closed}}, A)).

%% `once` goes passive without a word, as stock does; a count of 1 ends in
%% `{tcp_passive, S}`.
active_once() ->
    {_, N1} = data(100, new(#{active => 1})),
    ?assertMatch([{tell, {tcp, _, <<_:100/binary>>}}, {tell, {tcp_passive, _}}], N1),
    {C1, A1} = data(100, new(#{active => once})),
    ?assertMatch([{tell, {tcp, _, <<_:100/binary>>}}], A1),
    {C2, A2} = data(50, C1),
    ?assertEqual([], A2),
    {_, A3} = call(f1, {recv, 0, infinity}, C2),
    ?assertMatch([{reply, f1, {ok, <<_:50/binary>>}} | _], A3).

recv_timeout_keeps() ->
    {C1, A1} = call(f1, {recv, 100, 1000}, new(#{})),
    ?assertEqual([{recv_timer, 1000}], A1),
    {C2, _} = data(60, C1),
    {C3, A3} = step(recv_timeout, C2),
    ?assertEqual([{reply, f1, {error, timeout}}], A3),
    {_, A4} = call(f2, {recv, 0, 0}, C3),
    ?assertMatch([{reply, f2, {ok, <<_:60/binary>>}} | _], A4).

eof_active() ->
    {C1, _} = call(f1, {send, <<"x">>}, new(#{active => true})),
    {_, A} = step({push, {ok, eof}}, C1),
    ?assertMatch([{tell, {tcp_closed, _}}, {request, 1, close}, {reply, f1, {error, closed}}], A).

socket_down() ->
    {C1, _} = call(f1, {recv, 10, infinity}, new(#{})),
    {_, A} = step(socket_down, C1),
    ?assertMatch([{reply, f1, {error, econnaborted}} | _], A).

setopts(From, Opts, Core) -> call(From, {setopts, Opts}, Core).

tells(Actions) -> [Message || {tell, Message} <- Actions].

%% Once the count runs out, a push of 10 bytes presented and 5 more held.
spent(Active) ->
    {C1, A1} = data(10, new(#{active => Active})),
    ?assertMatch([{tcp, _, <<_:10/binary>>} | _], tells(A1)),
    {C2, A2} = data(5, C1),
    ?assertEqual([], tells(A2)),
    C2.

%% Stock's passive inet driver meets the peer's FIN only on a read: sends go on, a recv
%% takes what is held, the recv after it is answered `{error, closed}`, every recv after
%% that `{error, enotconn}`, and a send `{error, closed}` (inet_drv's tcp_recv_closed).
eof_passive() ->
    {C1, _} = data(3, new(#{})),
    {C2, A2} = step({push, {ok, eof}}, C1),
    ?assertEqual([], A2),
    {C3, A3} = call(f1, {send, <<"x">>}, C2),
    ?assertEqual([{0, {send, <<"x">>}}], requests(A3)),
    {C4, A4} = call(f2, {recv, 0, infinity}, C3),
    ?assertMatch([{reply, f2, {ok, <<_:3/binary>>}} | _], A4),
    {C5, A5} = call(f3, {recv, 0, infinity}, C4),
    ?assertMatch([{reply, f3, {error, closed}}, {recv_timer, cancel}, {request, 1, close},
                  {reply, f1, {error, closed}}], A5),
    ?assertEqual({error, enotconn}, element(3, hd(element(2, call(f4, {recv, 0, 0}, C5))))),
    ?assertEqual({error, closed}, element(3, hd(element(2, call(f5, {send, <<"y">>}, C5))))).

%% The held bytes, the error and the close wait until the owner turns active again.
once_spent_error() ->
    {C1, A1} = step({push, {ok, {error, econnreset}}}, spent(once)),
    ?assertEqual([], tells(A1)),
    {_, A2} = setopts(f1, [{active, true}], C1),
    ?assertMatch([{reply, f1, ok}, {tell, {tcp, _, <<_:5/binary>>}}, {tell, {tcp_error, _, econnreset}},
                  {tell, {tcp_closed, _}}], [A || A <- A2, element(1, A) =/= request]).

count_spent_exit() ->
    {C1, A1} = step(socket_down, spent(1)),
    ?assertEqual([], tells(A1)),
    {_, A2} = setopts(f1, [{active, 2}], C1),
    ?assertMatch([{tcp, _, <<_:5/binary>>}, {tcp_error, _, econnaborted}, {tcp_closed, _}], tells(A2)).

once_spent_abort() ->
    {C1, A1} = reply(9, ok, spent(once)),
    ?assertMatch([{count, reply} | _], A1),
    ?assertEqual([], tells(A1)),
    {C2, A2} = setopts(f1, [{active, once}], C1),
    ?assertMatch([{tcp, _, <<_:5/binary>>}], tells(A2)),
    {_, A3} = setopts(f2, [{active, once}], C2),
    ?assertMatch([{tcp_error, _, econnaborted}, {tcp_closed, _}], tells(A3)).

%% The connection's `{error, closed}` after eof ends nothing the owner has not seen: one
%% `{tcp_closed, S}`, no `tcp_error`.
once_spent_eof_closed() ->
    {C1, _} = step({push, {ok, eof}}, spent(once)),
    {C2, A2} = step({push, {ok, {error, closed}}}, C1),
    ?assertEqual([], tells(A2)),
    {_, A3} = setopts(f1, [{active, true}], C2),
    ?assertMatch([{tcp, _, <<_:5/binary>>}, {tcp_closed, _}], tells(A3)),
    {_, A4} = call(f2, {recv, 0, infinity}, C2),
    ?assertMatch([{reply, f2, {ok, <<_:5/binary>>}}], A4).

passive_error_recv() ->
    {C1, _} = data(4, new(#{})),
    {C2, A2} = step({push, {ok, {error, etimedout}}}, C1),
    ?assertEqual([], tells(A2)),
    {C3, A3} = call(f1, {recv, 0, infinity}, C2),
    ?assertMatch([{reply, f1, {ok, <<_:4/binary>>}}], A3),
    {_, A4} = call(f2, {recv, 0, infinity}, C3),
    ?assertMatch([{reply, f2, {error, etimedout}}], A4).

recv_then_active() ->
    {C1, _} = call(f1, {recv, 10, infinity}, new(#{})),
    {C2, _} = call(f2, {recv, 10, infinity}, C1),
    {_, A} = setopts(f3, [{active, true}], C2),
    ?assertEqual([{reply, f1, {error, einval}}, {recv_timer, cancel}, {reply, f2, {error, einval}},
                  {reply, f3, ok}], [X || X <- A, element(1, X) =/= credit]).

%% --- The socket process's check of a push ----------------------------------------------

push_test_() ->
    Sock = spawn(fun() -> ok end),
    Other = spawn(fun() -> ok end),
    [{"a local socket's bare push is taken",
      ?_assertEqual({ok, eof}, erx_sock_admit:push(tcp, local, Sock, {erx_net, Sock, eof}))},
     {"another process's push is unknown",
      ?_assertEqual(unknown, erx_sock_admit:push(tcp, local, Sock, {erx_net, Other, eof}))},
     {"the grant's domain's envelope is taken",
      ?_assertEqual({ok, eof}, erx_sock_admit:push(tcp, 7, Sock, {erx_origin, 7, {erx_net, Sock, eof}}))},
     {"another domain's envelope is unknown",
      ?_assertEqual(unknown, erx_sock_admit:push(tcp, 7, Sock, {erx_origin, 8, {erx_net, Sock, eof}}))},
     {"a bare push from a remote socket is unknown",
      ?_assertEqual(unknown, erx_sock_admit:push(tcp, 7, Sock, {erx_net, Sock, eof}))},
     {"data of 64 binaries and a piece is taken",
      ?_assertMatch({ok, {data, _}},
                    erx_sock_admit:push(tcp, local, Sock, {erx_net, Sock, {data, lists:duplicate(64, <<0:8192>>)}}))},
     {"data of 65 binaries is refused",
      ?_assertEqual({refused, push},
                    erx_sock_admit:push(tcp, local, Sock, {erx_net, Sock, {data, lists:duplicate(65, <<0>>)}}))},
     {"data past a piece is refused",
      ?_assertEqual({refused, push},
                    erx_sock_admit:push(tcp, local, Sock, {erx_net, Sock, {data, [<<0:524288>>, <<0>>]}}))},
     {"empty, improper or non-binary data is refused",
      [?_assertEqual({refused, push}, erx_sock_admit:push(tcp, local, Sock, {erx_net, Sock, {data, D}}))
       || D <- [[], [<<>>], [<<1>> | <<2>>], [<<1>>, "2"], <<1>>]]},
     {"an ICMP parameter problem's enoprotoopt ends a socket and answers a request",
      [?_assertEqual({ok, {error, enoprotoopt}},
                     erx_sock_admit:push(tcp, local, Sock, {erx_net, Sock, {error, enoprotoopt}})),
       ?_assertEqual({ok, {error, enoprotoopt}}, erx_sock_admit:result(send, {error, enoprotoopt}))]},
     {"an end reason off the list is refused",
      ?_assertEqual({refused, push}, erx_sock_admit:push(tcp, local, Sock, {erx_net, Sock, {error, made_up}}))},
     {"a reply's result is checked against its request",
      [?_assertEqual({ok, ok}, erx_sock_admit:result(send, ok)),
       ?_assertEqual({refused, shape}, erx_sock_admit:result(peername, ok)),
       ?_assertEqual({refused, reason}, erx_sock_admit:result(send, {error, made_up})),
       ?_assertEqual({refused, shape}, erx_sock_admit:result(getopts, {ok, [{active, true}]}))]}].

%% --- The connection's check of a request ----------------------------------------------

request_test_() ->
    SockProc = spawn(fun() -> ok end),
    Req = {erx_net, SockProc, {call, 3, peername}},
    [{"a local socket process's bare request is taken",
      ?_assertEqual({ok, {call, 3, peername}}, erx_net_admit:request(tcp, local, SockProc, Req))},
     {"the grantee's envelope is taken",
      ?_assertEqual({ok, {call, 3, peername}}, erx_net_admit:request(tcp, 7, SockProc, {erx_origin, 7, Req}))},
     {"another domain's envelope is unknown",
      ?_assertEqual(unknown, erx_net_admit:request(tcp, 7, SockProc, {erx_origin, 8, Req}))},
     {"an envelope to a local grantee is unknown",
      ?_assertEqual(unknown, erx_net_admit:request(tcp, local, SockProc, {erx_origin, 8, Req}))},
     {"another process's request is unknown",
      ?_assertEqual(unknown, erx_net_admit:request(tcp, local, self(), Req))},
     {"no request is taken once the socket process is gone",
      ?_assertEqual(unknown, erx_net_admit:request(tcp, local, none, Req))},
     {"a send past a piece, a credit past 64 MiB and other shapes are refused",
      [?_assertEqual({refused, shape}, erx_net_admit:request(tcp, local, SockProc, {erx_net, SockProc, Body}))
       || Body <- [{call, 1, {send, <<0:524296>>}}, {credit, 67108865}, {credit, 0},
                   {call, -1, close}, {call, 1, {setopts, [{active, true}]}}, {call, 1, recv}]]}].

%% A timeout past the longest timer the runtime arms is refused, not armed: armed, it
%% would crash the socket process.
recv_timeout_bound() ->
    ?assertEqual([{reply, f1, {error, einval}}], element(2, call(f1, {recv, 10, 4294967296}, new(#{})))),
    ?assertEqual([{recv_timer, 4294967295}], element(2, call(f2, {recv, 10, 4294967295}, new(#{})))).

pieces(Pieces, Core) -> step({push, {ok, {data, Pieces}}}, Core).

recv(From, Length, Core) ->
    {Core1, [{reply, From, {ok, Data}} | _]} = call(From, {recv, Length, infinity}, Core),
    {Data, Core1}.

%% A merged segment's payload is a sub-binary of its frame (docs/design-network-fastpath.md,
%% "Copies"). A delivery that lies within one piece is a sub-binary of that piece, still
%% sharing the frame, not a copy; a copy would reference only its own bytes.
one_piece_shared() ->
    Frame = binary:copy(<<"f">>, 1500),
    Piece = binary:part(Frame, 40, 1400),
    {C1, _} = pieces([Piece], new(#{})),
    {Whole, _} = recv(f1, 0, C1),
    ?assertEqual(Piece, Whole),
    ?assertEqual(1500, binary:referenced_byte_size(Whole)),
    {Head, C2} = recv(f1, 100, C1),
    {Rest, _} = recv(f2, 0, C2),
    ?assertEqual(Piece, <<Head/binary, Rest/binary>>),
    ?assertEqual([1500, 1500], [binary:referenced_byte_size(B) || B <- [Head, Rest]]),
    {_, [{tell, {tcp, _, Told}}]} = pieces([Piece], new(#{active => true})),
    ?assertEqual(1500, binary:referenced_byte_size(Told)),
    {C3, _} = pieces([Piece, binary:copy(<<"g">>, 200)], new(#{})),
    {Shared, _} = recv(f1, 100, C3),
    ?assertEqual(1500, binary:referenced_byte_size(Shared)),
    {C4, _} = pieces([Piece], new(#{mode => list})),
    ?assertEqual(binary_to_list(Piece), element(1, recv(f1, 0, C4))).

%% Pieces held from several pushes are delivered oldest first, whatever bytes a recv
%% takes and whatever is pushed between recvs, in either mode. A delivery across pieces
%% is the join of its own bytes only, and leaves the rest of the last piece shared.
pieces_joined() ->
    Core = lists:foldl(fun(Push, C) -> element(1, pieces(Push, C)) end, new(#{}),
                       [[<<"ab">>, <<"cd">>], [<<"ef">>]]),
    {A, C1} = recv(f1, 1, Core),
    {BCD, C2} = recv(f2, 3, C1),
    {C3, _} = pieces([<<"gh">>], C2),
    {EFG, C4} = recv(f3, 3, C3),
    {H, _} = recv(f4, 0, C4),
    ?assertEqual([<<"a">>, <<"bcd">>, <<"efg">>, <<"h">>], [A, BCD, EFG, H]),
    ?assertEqual(<<"abcdef">>, element(1, recv(f1, 0, Core))),
    Frame = binary:copy(<<"f">>, 1500),
    {J1, _} = pieces([binary:part(Frame, 0, 100), binary:part(Frame, 100, 1400)], new(#{})),
    {Joined, J2} = recv(f1, 200, J1),
    {Left, _} = recv(f2, 0, J2),
    ?assertEqual([200, 1500], [binary:referenced_byte_size(B) || B <- [Joined, Left]]),
    {L1, _} = pieces([<<"ab">>, <<"cd">>], new(#{mode => list})),
    ?assertEqual("abc", element(1, recv(f1, 3, L1))).

%% --- Options, a listening socket and a transfer's hold ----------------------------------

%% An option given twice is forwarded once, the last value: the socket admits one `nodelay`
%% in a `setopts`, and refuses a request of two without an answer.
options_forwarded_once_test() ->
    Own = #{mode => binary, active => false},
    ?assertEqual({ok, Own, [{nodelay, false}]}, erx_gen_tcp_core:options([{nodelay, true}, {nodelay, false}], Own)).

listen_options_test() ->
    ?assertEqual({ok, #{mode => binary, active => true}, [{backlog, 8}, {reuseaddr, true}, {nodelay, true}]},
                 erx_gen_tcp_core:listen_options([{backlog, 8}, binary, {nodelay, true}, {reuseaddr, true}])),
    ?assertEqual({error, einval}, erx_gen_tcp_core:listen_options([{keepalive, true}])).

listener(Own) ->
    erx_gen_tcp_core:listener(?SOCK, maps:merge(#{mode => binary, active => false}, Own),
                              #{nodelay => false, node => node()}).

listener_test_() ->
    [{"an accepted connection is handed over with the listening socket's options", fun accept_hands_over/0},
     {"an accept answered with an error ends its socket process", fun accept_error_discards/0},
     {"an accepted connection of another node aborts the listening socket", fun accept_other_node/0},
     {"the listener's exit answers every accept closed", fun listener_down/0},
     {"a listening socket answers what only a connection answers enotconn", fun listener_enotconn/0},
     {"a listening socket keeps its options and forwards nodelay", fun listener_options/0},
     {"an accept's reply type", fun accept_result/0}].

accept_hands_over() ->
    {C1, A1} = call(f1, {accept, sp1, infinity}, listener(#{active => once})),
    ?assertEqual([{request, 0, {accept, sp1, infinity}}], A1),
    {_, A2} = reply(0, {ok, self()}, C1),
    ?assertEqual([{hand_over, f1, sp1, self(), #{mode => binary, active => once}}], A2).

accept_error_discards() ->
    {C1, _} = call(f1, {accept, sp1, 10}, listener(#{})),
    ?assertEqual([{reply, f1, {error, timeout}}, {discard, sp1}], element(2, reply(0, {error, timeout}, C1))),
    ?assertEqual([{reply, f2, {error, einval}}, {discard, sp2}], element(2, call(f2, {accept, sp2, -1}, C1))).

accept_other_node() ->
    {C1, _} = call(f1, {accept, sp1, infinity}, listener(#{})),
    {C2, A2} = reply(0, {ok, remote_pid()}, C1),
    ?assertEqual([{count, socket}, {request, 1, close}, {reply, f1, {error, closed}}, {discard, sp1}], A2),
    ?assertEqual([{reply, f2, {error, closed}}, {discard, sp2}], element(2, call(f2, {accept, sp2, infinity}, C2))).

listener_down() ->
    {C1, _} = call(f1, {accept, sp1, infinity}, listener(#{})),
    {C2, _} = call(f2, {accept, sp2, 100}, C1),
    {C3, A3} = step(socket_down, C2),
    ?assertEqual([{request, 2, close}, {reply, f1, {error, closed}}, {reply, f2, {error, closed}},
                  {discard, sp1}, {discard, sp2}], A3),
    ?assertEqual([{reply, f3, ok}, stop], element(2, call(f3, close, C3))).

listener_enotconn() ->
    C = listener(#{}),
    [?assertEqual([{reply, f1, {error, enotconn}}], element(2, call(f1, Call, C)))
     || Call <- [{send, <<"x">>}, {recv, 0, 0}, {shutdown, write}, peername]],
    ?assertEqual([{reply, f1, {error, einval}}], element(2, call(f1, {no_such_call}, C))).

listener_options() ->
    {C1, A1} = call(f1, {setopts, [{active, true}, {nodelay, true}]}, listener(#{})),
    ?assertEqual([{request, 0, {setopts, [{nodelay, true}]}}], A1),
    ?assertEqual([{reply, f1, ok}], element(2, reply(0, ok, C1))),
    ?assertEqual([{reply, f2, {ok, [{active, true}, {nodelay, true}, {mode, binary}]}}],
                 element(2, call(f2, {getopts, [active, nodelay, mode, packet]}, C1))),
    ?assertEqual([{reply, f3, {error, einval}}], element(2, call(f3, {setopts, [{backlog, 5}]}, C1))),
    ?assertEqual([{request, 1, sockname}], element(2, call(f4, sockname, C1))).

accept_result() ->
    ?assertEqual({ok, {ok, self()}}, erx_sock_admit:result({accept, node()}, {ok, self()})),
    ?assertEqual({refused, socket}, erx_sock_admit:result({accept, node()}, {ok, remote_pid()})),
    ?assertEqual({refused, socket}, erx_sock_admit:result({accept, node()}, {ok, erx_net_grant})),
    ?assertEqual({ok, {error, econnaborted}}, erx_sock_admit:result({accept, node()}, {error, econnaborted})),
    ?assertEqual({refused, reason}, erx_sock_admit:result({accept, node()}, {error, eperm})).

hold_test_() ->
    [{"a held socket presents nothing until its release", fun hold_then_release/0},
     {"a held socket takes no more than its credit", fun hold_within_credit/0},
     {"a socket that has shown its end cannot be moved", fun hold_after_end/0}].

hold_then_release() ->
    {ok, C1} = erx_gen_tcp_core:hold(new(#{active => true})),
    {C2, A2} = data(10, C1),
    {C3, A3} = step({push, {ok, eof}}, C2),
    ?assertEqual([], [T || {tell, _} = T <- A2 ++ A3]),
    {_, A4} = erx_gen_tcp_core:release(C3),
    ?assertEqual([{tcp, ?SOCK, binary:copy(<<"d">>, 10)}, {tcp_closed, ?SOCK}], [M || {tell, M} <- A4]).

hold_within_credit() ->
    {ok, C1} = erx_gen_tcp_core:hold(new(#{active => true})),
    {C2, A2} = data(?PIECE, C1),
    ?assertEqual([], [A || {Kind, _} = A <- A2, Kind =:= credit orelse Kind =:= tell]),
    ?assertMatch({_, [{count, credit} | _]}, data(1, C2)).

hold_after_end() ->
    {C1, _} = step({push, {ok, eof}}, new(#{active => true})),
    ?assertEqual({error, closed}, erx_gen_tcp_core:hold(C1)),
    {C2, _} = step({push, {ok, eof}}, new(#{})),
    ?assertMatch({ok, _}, erx_gen_tcp_core:hold(C2)),
    %% A passive recv that met the end leaves stock's port open, so the socket still moves.
    {C3, _} = call(f1, {recv, 0, infinity}, C2),
    ?assertMatch({ok, _}, erx_gen_tcp_core:hold(C3)).

%% A pid of the node 'erx_other@nowhere', from its external form (NEW_PID_EXT with a
%% SMALL_ATOM_UTF8_EXT node name).
remote_pid() ->
    Node = <<"erx_other@nowhere">>,
    binary_to_term(<<131, 88, 119, (byte_size(Node)), Node/binary, 1:32, 0:32, 1:32>>).
