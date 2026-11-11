%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_udp_core_tests).
-moduledoc """
The datagram side of the socket protocol (docs/design-network-stack.md, "The socket
process", "Credit", "Requests in flight"): erx_gen_udp_core's step for a UDP socket and an
echo socket, and the checks of each side for the two kinds, erx_sock_admit:push/4 and
result/2 for the socket process and erx_net_admit:request/4 for the socket. The core is
driven with events and its actions read back: recvs wait in order and time out, active
modes present and count down, credit is granted at half the target and covers every
datagram, an empty one included, and a push past the credit, a reply to no request, a
reply outside its kind's errors and a push of the other kind's shape close the socket.
""".

-include_lib("eunit/include/eunit.hrl").

-define(SOCK, {'$inet', erx_gen_udp, self()}).
-define(TARGET, 131072).
-define(IP, {10, 0, 2, 3}).

new(Own) -> new(udp, Own).

new(Kind, Own) ->
    {Core, Actions} = erx_gen_udp_core:new(?SOCK, Kind, maps:merge(#{mode => binary, active => false}, Own)),
    ?assertEqual([{credit, ?TARGET}], Actions),
    Core.

step(Event, Core) -> erx_gen_udp_core:step(Event, Core).

call(From, Call, Core) -> step({call, From, Call}, Core).

reply(N, Result, Core) -> step({push, {ok, {reply, N, Result}}}, Core).

datagram(Data, Core) -> step({push, {ok, {datagram, ?IP, 53, Data}}}, Core).


ends(Actions) -> lists:last(Actions) =:= stop.

core_test_() ->
    [{"a passive recv takes what is held, else waits for a datagram", fun recv_held_and_waiting/0},
     {"recvs wait in order and time out", fun recvs_in_order/0},
     {"active modes present, count down and turn passive", fun active_modes/0},
     {"list mode presents a string", fun list_mode/0},
     {"credit is granted again at half the target", fun credit_at_half_target/0},
     {"an empty datagram costs a byte of credit", fun empty_costs_a_byte/0},
     {"a datagram past the credit closes the socket", fun past_credit/0},
     {"a reply to no request closes the socket", fun stray_reply/0},
     {"a reply outside its kind's errors closes the socket", fun reply_reason/0},
     {"at most 64 requests are in flight", fun in_flight_bound/0},
     {"a datagram larger than IPv4 allows is refused here", fun emsgsize/0},
     {"close goes out, answers ok and the rest closed", fun close_answers/0},
     {"the socket's exit answers every call closed", fun socket_down/0},
     {"turning active answers the waiting recvs einval", fun active_answers_recvs/0},
     {"an echo socket takes echo replies only", fun echo_kind/0}].

recv_held_and_waiting() ->
    {C1, []} = datagram(<<"one">>, new(#{})),
    {C2, [{reply, a, {ok, {?IP, 53, <<"one">>}}} | _]} = call(a, {recv, 1000}, C1),
    {C3, Acts} = call(b, {recv, 1000}, C2),
    ?assertEqual([{recv_timer, 1000}], Acts),
    {_, Acts2} = datagram(<<"two">>, C3),
    ?assertEqual([{reply, b, {ok, {?IP, 53, <<"two">>}}}, {recv_timer, cancel}], Acts2).

recvs_in_order() ->
    {C1, [{recv_timer, 50}]} = call(a, {recv, 50}, new(#{})),
    {C2, []} = call(b, {recv, infinity}, C1),
    {C3, Acts} = step(recv_timeout, C2),
    ?assertEqual([{reply, a, {error, timeout}}, {recv_timer, infinity}], Acts),
    {_, Acts2} = datagram(<<"x">>, C3),
    ?assertEqual([{reply, b, {ok, {?IP, 53, <<"x">>}}}, {recv_timer, cancel}], Acts2).

active_modes() ->
    {_, Acts} = datagram(<<"a">>, new(#{active => true})),
    ?assertEqual([{tell, {udp, ?SOCK, ?IP, 53, <<"a">>}}], Acts),
    {C1, Once} = datagram(<<"b">>, new(#{active => once})),
    ?assertEqual([{tell, {udp, ?SOCK, ?IP, 53, <<"b">>}}], Once),
    {C2, []} = datagram(<<"c">>, C1),
    {_, Rearm} = call(r, {setopts, [{active, 2}]}, C2),
    ?assertEqual([{reply, r, ok}, {tell, {udp, ?SOCK, ?IP, 53, <<"c">>}}], Rearm),
    ?assertMatch({_, [{reply, r, {error, einval}}]}, call(r, {setopts, [{nodelay, true}]}, C2)),
    ?assertMatch({_, [{reply, r, {ok, [{active, false}, {mode, binary}]}}]}, call(r, {getopts, [active, mode]}, C2)),
    {C3, Counted} = datagram(<<"d">>, new(#{active => 1})),
    ?assertEqual([{tell, {udp, ?SOCK, ?IP, 53, <<"d">>}}, {tell, {udp_passive, ?SOCK}}], Counted),
    {C4, []} = datagram(<<"e">>, C3),
    ?assertEqual({C4, [{reply, r, ok}, {tell, {udp_passive, ?SOCK}}]}, call(r, {setopts, [{active, 0}]}, C4)),
    {_, Zero} = erx_gen_udp_core:new(?SOCK, udp, #{mode => binary, active => 0}),
    ?assertEqual([{tell, {udp_passive, ?SOCK}}, {credit, ?TARGET}], Zero).

list_mode() ->
    {_, Acts} = datagram(<<"ab">>, new(#{active => true, mode => list})),
    ?assertEqual([{tell, {udp, ?SOCK, ?IP, 53, "ab"}}], Acts).

%% In active mode nothing is held, so the shortfall is what was pushed: no grant until half
%% the target has been pushed, then one grant of exactly that.
credit_at_half_target() ->
    Half = binary:copy(<<"h">>, 65507),
    {C1, Acts1} = datagram(Half, new(#{active => true})),
    ?assertEqual([], [A || {credit, _} = A <- Acts1]),
    {_, Acts2} = datagram(binary:copy(<<"h">>, ?TARGET div 2 - 65507), C1),
    ?assertEqual([{credit, ?TARGET div 2}], [A || {credit, _} = A <- Acts2]).

empty_costs_a_byte() ->
    Core = lists:foldl(fun(_, C) -> element(1, datagram(<<>>, C)) end, new(#{}), lists:seq(1, ?TARGET)),
    {_, Acts} = datagram(<<>>, Core),
    ?assertEqual({count, credit}, hd(Acts)),
    ?assert(ends(Acts)).

past_credit() ->
    Big = binary:copy(<<"b">>, 65507),
    {C1, []} = datagram(Big, new(#{})),
    {C2, []} = datagram(Big, C1),
    {_, Acts} = datagram(binary:copy(<<"o">>, 100), C2),
    ?assertMatch([{count, credit}, {request, _, close} | _], Acts),
    ?assert(ends(Acts)).

stray_reply() ->
    {_, Acts} = reply(7, ok, new(#{})),
    ?assertMatch([{count, reply}, {request, _, close}, stop], Acts).

reply_reason() ->
    {C1, [{request, 0, {send_to, ?IP, 53, <<"q">>}}]} = call(a, {send_to, ?IP, 53, <<"q">>}, new(#{})),
    ?assertMatch({_, [{reply, a, {error, ehostunreach}}]}, reply(0, {error, ehostunreach}, C1)),
    %% A broadcast destination without SO_BROADCAST, as FreeBSD answers it.
    ?assertMatch({_, [{reply, a, {error, eacces}}]}, reply(0, {error, eacces}, C1)),
    {_, Acts} = reply(0, {error, econnreset}, C1),
    ?assertMatch([{count, reason}, {request, 1, close}, {reply, a, {error, closed}}, stop], Acts),
    {C2, [{request, 0, sockname}]} = call(s, sockname, new(#{})),
    ?assertMatch({_, [{count, reason} | _]}, reply(0, {error, ehostunreach}, C2)).

in_flight_bound() ->
    Send = {send_to, ?IP, 53, <<"q">>},
    Full = lists:foldl(fun(I, C) -> element(1, call(I, Send, C)) end, new(#{}), lists:seq(0, 63)),
    {C1, Acts} = call(waits, Send, Full),
    ?assertEqual([], Acts),
    {_, Acts2} = reply(5, ok, C1),
    ?assertEqual([{reply, 5, ok}, {request, 64, Send}], Acts2).

emsgsize() ->
    Core = new(#{}),
    ?assertMatch({_, [{reply, a, {error, emsgsize}}]}, call(a, {send_to, ?IP, 53, binary:copy(<<0>>, 65508)}, Core)),
    ?assertMatch({_, [{request, 0, _}]}, call(a, {send, binary:copy(<<0>>, 65507)}, Core)),
    ?assertMatch({_, [{reply, a, {error, einval}}]}, call(a, {send_to, {1, 2, 3}, 53, <<>>}, Core)),
    ?assertMatch({_, [{reply, a, {error, einval}}]}, call(a, {connect, ?IP, 0}, Core)),
    ?assertMatch({_, [{reply, a, {error, einval}}]}, call(a, {recv, -1}, Core)).

close_answers() ->
    {C1, _} = call(s, {send, <<"x">>}, new(#{})),
    {C2, _} = call(r, {recv, infinity}, C1),
    {_, Acts} = call(c, close, C2),
    ?assertEqual([{request, 1, close}, {reply, c, ok}, {reply, s, {error, closed}}, {reply, r, {error, closed}}, stop],
                 Acts).

socket_down() ->
    {C1, _} = call(r, {recv, infinity}, new(#{})),
    ?assertEqual({C1, [{reply, r, {error, closed}}, stop]}, step(socket_down, C1)).

active_answers_recvs() ->
    {C1, _} = call(a, {recv, infinity}, new(#{})),
    {C2, []} = call(b, {recv, 10}, C1),
    {_, Acts} = call(s, {setopts, [{active, true}]}, C2),
    ?assertEqual([{reply, s, ok}, {reply, a, {error, einval}}, {recv_timer, cancel}, {reply, b, {error, einval}}], Acts),
    {C3, _} = call(s, {setopts, [{active, true}]}, new(#{})),
    ?assertMatch({_, [{reply, x, {error, einval}}]}, call(x, {recv, 0}, C3)).

echo_kind() ->
    Core = new(icmp, #{}),
    Echo = {echo, ?IP, 64, 7, <<"ping">>},
    {C1, []} = step({push, {ok, Echo}}, Core),
    ?assertMatch({_, [{reply, a, {ok, {?IP, 64, 7, <<"ping">>}}}]}, call(a, {recv, 0}, C1)),
    ?assertMatch({_, [{reply, a, {error, einval}}]}, call(a, {setopts, [{active, true}]}, Core)),
    ?assertMatch({_, [{reply, a, {error, einval}}]}, call(a, {send_to, ?IP, 53, <<>>}, Core)),
    ?assertMatch({_, [{request, 0, {echo_send, ?IP, 1, default, <<>>}}]}, call(a, {echo_send, ?IP, 1, default, <<>>}, Core)),
    ?assertMatch({_, [{count, push} | _]}, step({push, {ok, {datagram, ?IP, 53, <<>>}}}, Core)),
    ?assertMatch({_, [{count, push} | _]}, datagram(<<>>, Core)).

%% --- The checks of each side -------------------------------------------------------

admit_test_() ->
    Sock = spawn(fun() -> ok end),
    SockProc = self(),
    Push = fun(Kind, Body) -> erx_sock_admit:push(Kind, local, Sock, {erx_net, Sock, Body}) end,
    Req = fun(Kind, Call) -> erx_net_admit:request(Kind, local, SockProc, {erx_net, SockProc, {call, 1, Call}}) end,
    [?_assertEqual({ok, {datagram, ?IP, 53, <<>>}}, Push(udp, {datagram, ?IP, 53, <<>>})),
     ?_assertEqual({refused, push}, Push(tcp, {datagram, ?IP, 53, <<>>})),
     ?_assertEqual({refused, push}, Push(udp, eof)),
     ?_assertEqual({refused, push}, Push(udp, {data, [<<"x">>]})),
     ?_assertEqual({refused, push}, Push(udp, {datagram, ?IP, 70000, <<>>})),
     ?_assertEqual({refused, push}, Push(udp, {datagram, ?IP, 53, binary:copy(<<0>>, 65528)})),
     ?_assertEqual({ok, {echo, ?IP, 0, 65535, <<>>}}, Push(icmp, {echo, ?IP, 0, 65535, <<>>})),
     ?_assertEqual({refused, push}, Push(icmp, {echo, ?IP, 256, 1, <<>>})),
     ?_assertEqual({refused, push}, Push(icmp, {datagram, ?IP, 53, <<>>})),
     ?_assertEqual(unknown, erx_sock_admit:push(udp, 7, Sock, {erx_origin, 8, {erx_net, Sock, {reply, 1, ok}}})),
     ?_assertEqual({ok, ok}, erx_sock_admit:result(udp_send, ok)),
     ?_assertEqual({ok, {error, edestaddrreq}}, erx_sock_admit:result(udp_send, {error, edestaddrreq})),
     ?_assertEqual({refused, reason}, erx_sock_admit:result(udp_connect, {error, ehostunreach})),
     ?_assertEqual({refused, reason}, erx_sock_admit:result(setopts, {error, epipe})),
     ?_assertEqual({refused, reason}, erx_sock_admit:result(shutdown, {error, ebusy})),
     ?_assertEqual({ok, {error, ebusy}}, erx_sock_admit:result(send, {error, ebusy})),
     ?_assertEqual({refused, shape}, erx_sock_admit:result(close, {ok, 1})),
     ?_assertEqual({ok, {call, 1, {send_to, ?IP, 0, <<>>}}}, Req(udp, {send_to, ?IP, 0, <<>>})),
     ?_assertEqual({refused, shape}, Req(udp, {send_to, ?IP, 0, binary:copy(<<0>>, 65528)})),
     ?_assertEqual({refused, shape}, Req(udp, {connect, ?IP, 0})),
     ?_assertEqual({ok, {call, 1, {send, <<"x">>}}}, Req(udp, {send, <<"x">>})),
     ?_assertEqual({refused, shape}, Req(udp, peername)),
     ?_assertEqual({refused, shape}, Req(tcp, {send_to, ?IP, 0, <<>>})),
     ?_assertEqual({ok, {call, 1, close}}, Req(icmp, close)),
     ?_assertEqual({refused, shape}, Req(icmp, sockname)),
     ?_assertEqual({ok, {call, 1, {echo_send, ?IP, 1, 64, <<>>}}}, Req(icmp, {echo_send, ?IP, 1, 64, <<>>})),
     ?_assertEqual({refused, shape}, Req(icmp, {echo_send, ?IP, 1, 0, <<>>})),
     ?_assertEqual(unknown, erx_net_admit:request(udp, local, SockProc, {erx_net, Sock, {call, 1, close}}))].
