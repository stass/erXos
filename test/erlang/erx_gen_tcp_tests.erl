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
    [{"listen is not offered", ?_assertEqual({error, enotsup}, erx_gen_tcp:listen(8080, [binary]))},
     {"fdopen is not offered", ?_assertEqual({error, enotsup}, erx_gen_tcp:fdopen(3, []))},
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
    ok = application:set_env(erx_net_client, grant, {erlang, apply, [fun() -> {ok, Grant} end, []]}),
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
    Asked = [receive {grant, {tcp_connect, inet, Address, 80, [binary], _Timeout}} -> Address
             after ?WAIT -> none end || _ <- [1, 2]],
    ?assertEqual([{192, 0, 2, 10}, {192, 0, 2, 11}], lists:sort(Asked)),
    receive {grant, Extra} -> ?assertEqual(none, Extra) after 0 -> ok end.

connect_unknown() ->
    with_grant(fun connect_unknown_case/0).

connect_unknown_case() ->
    ?assertEqual({error, nxdomain}, erx_gen_tcp:connect("absent.erxos.test", 80, [], 1000)),
    receive {grant, Request} -> ?assertEqual(none, Request) after 0 -> ok end.
