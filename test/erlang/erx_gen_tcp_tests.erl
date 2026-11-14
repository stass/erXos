%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_tcp_tests).
-moduledoc """
EUnit cases of erx_gen_tcp's calls outside an open connection
(docs/design-network-stack.md, "The backend"): the calls the backend does not offer
answer `{error, enotsup}`, and a host name given to `connect/4` resolves through inet's
own path before the grant is asked. The grant is a stand-in process, named by the
`erx_net_client` application's `grant` key, that reports each request to the test and
refuses it; the host name comes from inet_db's own hosts table, with `file` the only
lookup method, so the case needs no network.
""".

-include_lib("eunit/include/eunit.hrl").

-define(WAIT, 3000).

unsupported_test_() ->
    [{"fdopen is not offered", ?_assertEqual({error, enotsup}, erx_gen_tcp:fdopen(3, []))},
     {"connect with a socket-address map is not offered",
      ?_assertEqual({error, enotsup},
                    erx_gen_tcp:connect(#{family => inet, addr => {10, 0, 2, 2}, port => 80}, [], 1000))}].

%% A connection that crashes while it holds a call answers as a closed socket, whatever its
%% reason, so no crash of the stack reaches the caller.
crashed_connection_test() ->
    Conn = spawn(fun() -> receive {'$gen_call', _, _} -> exit(boom) end end),
    ?assertEqual({error, closed}, erx_gen_tcp:recv({'$inet', erx_gen_tcp, Conn}, 0, 1000)).

host_name_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [{"a host name is resolved and each address tried in turn", fun connect_resolves/0},
      {"an unknown host name fails as inet's lookup does", fun connect_unknown/0},
      {"an address list is refused", ?_assertEqual({error, einval}, erx_gen_tcp:connect(<<"peer">>, 80, [], 1000))}]}.

setup() ->
    Lookup = inet_db:res_option(lookup),
    ok = inet_db:set_lookup([file]),
    ok = inet_db:add_host({192, 0, 2, 10}, ["peer.erxos.test"]),
    ok = inet_db:add_host({192, 0, 2, 11}, ["peer.erxos.test"]),
    Lookup.

cleanup(Lookup) ->
    ok = inet_db:del_host({192, 0, 2, 10}),
    ok = inet_db:del_host({192, 0, 2, 11}),
    ok = inet_db:set_lookup(Lookup).

%% Runs Case with a stand-in grant that reports each request to this process and
%% refuses it, as a peer that answers RST does.
with_grant(Case) ->
    Self = self(),
    Grant = spawn(fun() -> grant(Self) end),
    ok = application:set_env(erx_net_client, grant, {erlang, apply, [fun() -> {ok, Grant, local} end, []]}),
    try Case()
    after
        exit(Grant, kill),
        ok = application:unset_env(erx_net_client, grant)
    end.

grant(Test) ->
    receive
        {'$gen_call', From, Request} ->
            Test ! {grant, Request},
            gen_server:reply(From, {error, econnrefused}),
            grant(Test)
    end.

connect_resolves() ->
    with_grant(fun connect_resolves_case/0).

connect_resolves_case() ->
    ?assertEqual({error, econnrefused}, erx_gen_tcp:connect("peer.erxos.test", 80, [binary], 1000)),
    Asked = [receive {grant, {tcp_connect, inet, Address, 80, [], _Timeout}} -> Address
             after ?WAIT -> none end || _ <- [1, 2]],
    ?assertEqual([{192, 0, 2, 10}, {192, 0, 2, 11}], lists:sort(Asked)),
    receive {grant, Extra} -> ?assertEqual(none, Extra) after 0 -> ok end.

connect_unknown() ->
    with_grant(fun connect_unknown_case/0).

connect_unknown_case() ->
    ?assertEqual({error, nxdomain}, erx_gen_tcp:connect("absent.erxos.test", 80, [], 1000)),
    receive {grant, Request} -> ?assertEqual(none, Request) after 0 -> ok end.

%% --- Stock's end of a stream ----------------------------------------------------------

%% What erx_gen_tcp_core's end follows (docs/design-network-stack.md, "The socket
%% process"), shown on the oracle's own gen_tcp over loopback: a passive socket meets the
%% peer's FIN only when it reads, so its sends go on, a recv the FIN leaves short answers
%% `{error, closed}`, every recv after it `{error, enotconn}` and a send `{error, closed}`
%% (inet_drv's tcp_recv_closed); and once an active count runs out, the bytes and the FIN
%% wait for the owner to re-arm.
stock_end_test_() ->
    [{"stock: passive sends go on after the FIN until a recv meets it", fun stock_passive_end/0},
     {"stock: the end waits for an owner whose once ran out", fun stock_once_end/0}].

%% A connected pair on loopback: ours with Opts, the peer's passive.
stock_pair(Opts) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    {ok, Ours} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary | Opts], ?WAIT),
    {ok, Peer} = gen_tcp:accept(L, ?WAIT),
    ok = gen_tcp:close(L),
    {Ours, Peer}.

%% The FIN reaches our kernel; nothing on our side reads it.
fin_arrives() ->
    timer:sleep(200).

stock_passive_end() ->
    {Ours, Peer} = stock_pair([{active, false}]),
    ok = gen_tcp:send(Peer, <<"tail">>),
    ok = gen_tcp:shutdown(Peer, write),
    fin_arrives(),
    ?assertEqual(ok, gen_tcp:send(Ours, <<"x">>)),
    ?assertEqual({ok, <<"x">>}, gen_tcp:recv(Peer, 1, ?WAIT)),
    ?assertEqual({error, closed}, gen_tcp:recv(Ours, 10, ?WAIT)),
    ?assertEqual({error, enotconn}, gen_tcp:recv(Ours, 0, ?WAIT)),
    ?assertEqual({error, closed}, gen_tcp:send(Ours, <<"y">>)),
    gen_tcp:close(Peer).

stock_once_end() ->
    {Ours, Peer} = stock_pair([{active, once}]),
    ok = gen_tcp:send(Peer, <<"a">>),
    ?assertEqual({tcp, Ours, <<"a">>}, receive {tcp, Ours, _} = M -> M after ?WAIT -> timeout end),
    ok = gen_tcp:send(Peer, <<"b">>),
    ok = gen_tcp:shutdown(Peer, write),
    fin_arrives(),
    ?assertEqual(none, receive M1 -> M1 after 0 -> none end),
    ok = inet:setopts(Ours, [{active, once}]),
    ?assertEqual({tcp, Ours, <<"b">>}, receive M2 -> M2 after ?WAIT -> timeout end),
    ok = inet:setopts(Ours, [{active, once}]),
    ?assertEqual({tcp_closed, Ours}, receive M3 -> M3 after ?WAIT -> timeout end),
    gen_tcp:close(Peer).
