%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_sock_admit_tests).
-moduledoc """
EUnit cases of the check of the grant's answers (docs/design-network-stack.md,
"Untrusted input", "Answers from the grant"): erx_sock_admit's refusals of a hostile
network domain's answers and change messages, and the paths that use it, erx_inet:call/1
behind `erx_gen_tcp:connect/4` and `erx_gen_udp:open/2`, and the resolver loader.

A grant of another domain is played by a stand-in process named by the `erx_net_client`
application's `grant` key with the origin `?DOMAIN`, and a pid of another node is made
by decoding the external form of a pid with another node's name, so no case needs
distribution.
""".

-include_lib("eunit/include/eunit.hrl").

-define(DOMAIN, 7).
-define(WAIT, 3000).
-define(SERVERS, [{{10, 0, 2, 3}, 53}]).
-define(ANSWER, #{nameservers => ?SERVERS, search => [<<"erxos.test">>]}).

%% --- answer/3 ----------------------------------------------------------------------

answer_test_() ->
    [{"an open's socket of the grant's node is taken apart for its pid", fun open_socket_taken/0},
     {"an open's socket of another node is refused", fun open_socket_other_node/0},
     {"an open's socket that is a name is refused", fun open_socket_name/0},
     {"an answer off the reply type is refused", fun answer_off_schema/0},
     {"an error reason off the operation's list is refused", fun answer_off_reasons/0},
     {"an operation with no reply type is refused", fun answer_unknown_operation/0},
     {"a resolver answer passes the resolver check", fun answer_resolver/0}].

open_socket_taken() ->
    Grant = self(),
    Conn = spawn(fun() -> ok end),
    ?assertEqual({ok, {ok, Conn}}, erx_sock_admit:answer(tcp_connect, Grant, {ok, Conn})),
    ?assertEqual({ok, {ok, Conn}}, erx_sock_admit:answer(udp_open, Grant, {ok, Conn})),
    ?assertEqual({ok, {error, econnrefused}}, erx_sock_admit:answer(tcp_connect, Grant, {error, econnrefused})),
    ?assertEqual({ok, {error, enoprotoopt}}, erx_sock_admit:answer(tcp_connect, Grant, {error, enoprotoopt})),
    ?assertEqual({ok, {error, eaddrinuse}}, erx_sock_admit:answer(udp_open, Grant, {error, eaddrinuse})).

%% A network domain that names a process of a third domain, or of its client's own, as
%% the socket: the socket must be of the grant's node, whichever side is remote.
open_socket_other_node() ->
    Remote = remote_pid(),
    ?assertEqual({refused, socket},
                 erx_sock_admit:answer(tcp_connect, self(), {ok, Remote})),
    ?assertEqual({refused, socket}, erx_sock_admit:answer(udp_open, self(), {ok, Remote})),
    ?assertEqual({refused, socket}, erx_sock_admit:answer(udp_open, Remote, {ok, self()})).

%% gen_server:call/3 follows a registered name, `{global, _}` and `{via, M, _}` as it
%% follows a pid, so none of them may become a socket.
open_socket_name() ->
    Names = [erx_net_grant, {global, sock}, {via, global, sock}, {erx_net_grant, node()}, {'$inet', erx_gen_tcp, x}],
    [?assertEqual({refused, socket}, erx_sock_admit:answer(udp_open, self(), {ok, Name})) || Name <- Names],
    [?assertEqual({refused, socket}, erx_sock_admit:answer(tcp_connect, self(), {ok, Name}))
     || Name <- Names].

answer_off_schema() ->
    Me = self(),
    Off = [ok, Me, {ok, Me, extra}, {ok}, {error, econnrefused, extra}, [{ok, Me}], #{ok => Me}],
    [?assertEqual({refused, shape}, erx_sock_admit:answer(udp_open, Me, Answer)) || Answer <- Off],
    %% A connection is answered as its pid, never as a socket term.
    [?assertEqual({refused, socket}, erx_sock_admit:answer(tcp_connect, Me, {ok, Socket}))
     || Socket <- [{'$inet', erx_gen_udp, Me}, {'$inet', erx_gen_tcp, Me, extra}]].

answer_off_reasons() ->
    Off = [made_up, econnrefused_x, {econnrefused}, "closed", <<"closed">>, {'EXIT', self(), kill}, 1],
    [?assertEqual({refused, reason}, erx_sock_admit:answer(tcp_connect, self(), {error, Reason})) || Reason <- Off],
    %% A datagram socket is never refused by a peer, nor a resolver closed.
    ?assertEqual({refused, reason}, erx_sock_admit:answer(udp_open, self(), {error, econnrefused})),
    ?assertEqual({refused, reason}, erx_sock_admit:answer(watch_resolver, self(), {error, closed})).

answer_unknown_operation() ->
    [?assertEqual({refused, operation}, erx_sock_admit:answer(Operation, self(), Answer))
     || Operation <- [getifaddrs, hostname, tcp_listen], Answer <- [{ok, self()}, {error, badarg}]].

answer_resolver() ->
    ?assertEqual({ok, {ok, #{nameservers => ?SERVERS, search => ["erxos.test"]}}},
                 erx_sock_admit:answer(watch_resolver, self(), {ok, ?ANSWER})),
    ?assertEqual({refused, resolver},
                 erx_sock_admit:answer(resolver, self(), {ok, #{nameservers => [{{10, 0, 2, 3}, 54}], search => []}})).

%% --- change/3 ----------------------------------------------------------------------

change_test_() ->
    [{"a local grant's change arrives bare", fun change_local/0},
     {"a remote grant's change arrives in its domain's envelope", fun change_remote/0},
     {"a change without the grant's envelope is refused", fun change_wrong_envelope/0},
     {"a change of another grant or off the resolver type is refused", fun change_wrong_grant/0}].

change_local() ->
    Grant = self(),
    Checked = #{nameservers => ?SERVERS, search => ["erxos.test"]},
    ?assertEqual({ok, Checked}, erx_sock_admit:change(local, Grant, {erx_net_resolver, Grant, ?ANSWER})),
    ?assertEqual({refused, origin},
                 erx_sock_admit:change(local, Grant, {erx_origin, ?DOMAIN, {erx_net_resolver, Grant, ?ANSWER}})).

change_remote() ->
    Grant = self(),
    ?assertEqual({ok, #{nameservers => ?SERVERS, search => ["erxos.test"]}},
                 erx_sock_admit:change(?DOMAIN, Grant, {erx_origin, ?DOMAIN, {erx_net_resolver, Grant, ?ANSWER}})).

%% A bare message is one from the loader's own domain, which a grant of another domain
%% cannot send; an envelope of another domain is another domain's forgery.
change_wrong_envelope() ->
    Grant = self(),
    Change = {erx_net_resolver, Grant, ?ANSWER},
    [?assertEqual({refused, origin}, erx_sock_admit:change(?DOMAIN, Grant, Message))
     || Message <- [Change, {erx_origin, ?DOMAIN + 1, Change}, {erx_origin, local, Change},
                    {erx_origin, ?DOMAIN, {erx_origin, ?DOMAIN, Change}}, {erx_origin, ?DOMAIN, Change, extra}]].

change_wrong_grant() ->
    Grant = self(),
    Other = spawn(fun() -> ok end),
    ?assertEqual({refused, origin},
                 erx_sock_admit:change(?DOMAIN, Grant, {erx_origin, ?DOMAIN, {erx_net_resolver, Other, ?ANSWER}})),
    ?assertEqual({refused, origin}, erx_sock_admit:change(local, Grant, {erx_net_resolver, Other, ?ANSWER})),
    ?assertEqual({refused, resolver},
                 erx_sock_admit:change(?DOMAIN, Grant, {erx_origin, ?DOMAIN, {erx_net_resolver, Grant, #{}}})).

%% --- The paths through erx_inet:call/1 ---------------------------------------------

call_test_() ->
    [{"a connect whose socket fails the check is badarg", fun connect_forged/0},
     {"an open whose socket fails the check is badarg", fun open_forged/0},
     {"an admitted open is the backend's socket", fun open_admitted/0},
     {"a grant that ends while asked answers closed", fun call_grant_ends/0}].

connect_forged() ->
    [with_grant(fun(_) -> {ok, Forged} end,
                fun() -> ?assertEqual({error, badarg}, erx_gen_tcp:connect({192, 0, 2, 1}, 80, [], 1000)) end)
     || Forged <- [remote_pid(), {global, sock}, {via, global, sock}]].

open_forged() ->
    [with_grant(fun(_) -> Answer end, fun() -> ?assertEqual({error, badarg}, erx_gen_udp:open(0, [])) end)
     || Answer <- [{ok, remote_pid()}, {ok, {global, sock}}, {error, {crash, [stack]}}, {ok, self(), extra}]].

open_admitted() ->
    Sock = spawn(fun() -> receive stop -> ok end end),
    with_grant(fun({udp_open, inet, any, 0, []}) -> {ok, Sock} end,
               fun() -> ?assertEqual({ok, {'$inet', erx_gen_udp, Sock}}, erx_gen_udp:open(0, [])) end),
    Sock ! stop.

call_grant_ends() ->
    with_grant(fun(_) -> exit(gone) end,
               fun() -> ?assertEqual({error, closed}, erx_inet:call({udp_open, inet, any, 0, []})) end).

%% --- The resolver loader -----------------------------------------------------------

loader_test_() ->
    {setup, fun save_resolver/0, fun restore_resolver/1,
     [{"the loader takes changes only in the grant's envelope", fun loader_envelope/0},
      {"the loader keeps watching a grant whose answer it refused", fun loader_keeps_refusing_grant/0}]}.

save_resolver() ->
    [{Opt, inet_db:res_option(Opt)} || Opt <- [resolv_conf, nameservers, search, lookup]].

restore_resolver(Saved) ->
    [ok = inet_db:res_option(Opt, Value) || {Opt, Value} <- Saved, Value =/= undefined].

%% The first answer loads; then each forged change is dropped and the loaded answer stays,
%% until a change in the grant's own envelope replaces it.
loader_envelope() ->
    with_loader(fun(watch_resolver) -> {ok, ?ANSWER} end,
                fun(Grant, Loader) ->
                    ?assertEqual(?SERVERS, inet_db:res_option(nameservers)),
                    New = #{nameservers => [{{10, 0, 2, 4}, 53}], search => [<<"erxos.test">>]},
                    Change = {erx_net_resolver, Grant, New},
                    [begin
                         Loader ! Forged,
                         _ = sys:get_state(Loader),
                         ?assertEqual(?SERVERS, inet_db:res_option(nameservers))
                     end || Forged <- [Change, {erx_origin, ?DOMAIN + 1, Change},
                                       {erx_origin, ?DOMAIN, {erx_net_resolver, self(), New}}]],
                    Loader ! {erx_origin, ?DOMAIN, Change},
                    _ = sys:get_state(Loader),
                    ?assertEqual([{{10, 0, 2, 4}, 53}], inet_db:res_option(nameservers))
                end).

%% An answer the check refuses leaves inet_db as it was and the grant watched; the loader
%% lets it go only when it ends.
loader_keeps_refusing_grant() ->
    ok = inet_db:res_option(nameservers, []),
    with_loader(fun(watch_resolver) -> {error, refused} end,
                fun(Grant, Loader) ->
                    ?assertEqual([], inet_db:res_option(nameservers)),
                    ?assertEqual({monitors, [{process, Grant}]}, erlang:process_info(Loader, monitors)),
                    Ref = erlang:monitor(process, Grant),
                    exit(Grant, kill),
                    receive {'DOWN', Ref, process, Grant, _} -> ok end,
                    _ = sys:get_state(Loader),
                    ?assertEqual({monitors, []}, erlang:process_info(Loader, monitors))
                end).

%% --- Stand-ins ---------------------------------------------------------------------

%% Runs Case with a stand-in grant of domain ?DOMAIN that answers each call Answer(Request).
with_grant(Answer, Case) ->
    Grant = spawn(fun() -> grant(Answer) end),
    ok = application:set_env(erx_net_client, grant, {erlang, apply, [fun() -> {ok, Grant, ?DOMAIN} end, []]}),
    try Case()
    after
        exit(Grant, kill),
        ok = application:unset_env(erx_net_client, grant)
    end.

%% Runs Case(Grant, Loader) once a loader has asked a stand-in grant for its resolver.
with_loader(Answer, Case) ->
    Me = self(),
    Grant = spawn(fun() -> grant(fun(Request) -> Me ! asked, Answer(Request) end) end),
    ok = application:set_env(erx_net_client, grant, {erlang, apply, [fun() -> {ok, Grant, ?DOMAIN} end, []]}),
    {ok, Loader} = gen_server:start(erx_inet, [], []),
    try
        receive asked -> ok after ?WAIT -> error(no_request) end,
        _ = sys:get_state(Loader),
        Case(Grant, Loader)
    after
        exit(Loader, kill),
        exit(Grant, kill),
        ok = application:unset_env(erx_net_client, grant)
    end.

grant(Answer) ->
    receive
        {'$gen_call', From, Request} ->
            gen_server:reply(From, Answer(Request)),
            grant(Answer)
    end.

%% A pid of the node 'erx_other@nowhere', from its external form (NEW_PID_EXT with a
%% SMALL_ATOM_UTF8_EXT node name).
remote_pid() ->
    Node = <<"erx_other@nowhere">>,
    binary_to_term(<<131, 88, 119, (byte_size(Node)), Node/binary, 1:32, 0:32, 1:32>>).
