%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_grant_tests).
-moduledoc """
The grant's admission (docs/design-network-stack.md, "The grant's contract"):
erx_net_admit:request/2 and mint/2 as pure checks, and a grant process that acts only on
what they admit. A domain's pid is made with the creation the domain id names, as the
external term format carries it, so a call of another domain, or one whose reply would go
to a third domain, is built here without that domain.
""".

-include_lib("eunit/include/eunit.hrl").

-define(GRANTEE, 7).
-define(OTHER, 9).
-define(SYSTEM, 4).
-define(WAIT, 3000).
-define(QUIET, 200).

%% --- erx_net_admit:request/2 -----------------------------------------------------------

request_test_() ->
    [{"a bare call of a local grantee from its node is admitted", fun local_admitted/0},
     {"an enveloped call of the grantee from its domain is admitted", fun grantee_admitted/0},
     {"a call of another domain is unknown", fun other_domain_unknown/0},
     {"a reply target of a third domain is unknown", fun third_domain_unknown/0},
     {"a reply alias of a third domain, or no alias, is unknown", fun third_domain_alias_unknown/0},
     {"a bare call of a remote grantee's grant is unknown", fun bare_call_of_remote_grantee/0},
     {"arguments past their bounds are refused", fun bounds_refused/0},
     {"the stack's own calls are admitted only bare and from its node", fun own_calls/0},
     {"a message that is no call is unknown", fun not_a_call/0}].

local_admitted() ->
    From = {self(), make_ref()},
    [?assertEqual({ok, Request, From}, erx_net_admit:request({'$gen_call', From, Request}, local))
     || Request <- [{tcp_connect, inet, {192, 0, 2, 1}, 80, [binary], 1000}, {udp_open, inet, any, 0, []},
                    {icmp_open, inet}, interfaces, resolver, watch_resolver]].

grantee_admitted() ->
    From = {pid_of(?GRANTEE), [alias | ref_of(?GRANTEE)]},
    Message = {erx_origin, ?GRANTEE, {'$gen_call', From, {icmp_open, inet}}},
    ?assertEqual({ok, {icmp_open, inet}, From}, erx_net_admit:request(Message, ?GRANTEE)).

other_domain_unknown() ->
    From = {pid_of(?OTHER), make_ref()},
    ?assertEqual(unknown, erx_net_admit:request({erx_origin, ?OTHER, {'$gen_call', From, interfaces}}, ?GRANTEE)),
    ?assertEqual(unknown, erx_net_admit:request({erx_origin, ?OTHER, {'$gen_call', From, interfaces}}, local)).

%% The owner of what a connect opens is the call's caller: one of a third domain is
%% refused, so no domain makes a socket that talks to another's process.
third_domain_unknown() ->
    From = {pid_of(?OTHER), [alias | ref_of(?GRANTEE)]},
    Connect = {tcp_connect, inet, {192, 0, 2, 1}, 80, [], infinity},
    ?assertEqual(unknown, erx_net_admit:request({erx_origin, ?GRANTEE, {'$gen_call', From, Connect}}, ?GRANTEE)),
    Local = {self(), [alias | ref_of(?GRANTEE)]},
    ?assertEqual(unknown, erx_net_admit:request({erx_origin, ?GRANTEE, {'$gen_call', Local, Connect}}, ?GRANTEE)).

%% gen:reply/2 sends to the alias, not to the pid, so an alias of a third domain would
%% take the reply there: domain A could answer domain C's own pending call.
third_domain_alias_unknown() ->
    Connect = {tcp_connect, inet, {192, 0, 2, 1}, 80, [], infinity},
    [?assertEqual(unknown, erx_net_admit:request({erx_origin, ?GRANTEE, {'$gen_call', From, Connect}}, ?GRANTEE))
     || From <- [{pid_of(?GRANTEE), [alias | ref_of(?OTHER)]}, {pid_of(?GRANTEE), [alias | make_ref()]},
                 {pid_of(?GRANTEE), ref_of(?GRANTEE)}, {pid_of(?GRANTEE), [[alias | ref_of(?GRANTEE)] | x]}]].

bare_call_of_remote_grantee() ->
    ?assertEqual(unknown, erx_net_admit:request({'$gen_call', {self(), make_ref()}, interfaces}, ?GRANTEE)).

bounds_refused() ->
    From = {self(), make_ref()},
    Ip = {192, 0, 2, 1},
    Long = lists:duplicate(65, binary),
    [?assertEqual({refused, shape, From}, erx_net_admit:request({'$gen_call', From, Request}, local))
     || Request <- [{tcp_connect, inet, Ip, 80, Long, 1000},
                    {tcp_connect, inet, Ip, 80, [binary | binary], 1000},
                    {tcp_connect, inet, Ip, 80, [], 4294967296},
                    {tcp_connect, inet, Ip, 0, [], 1000},
                    {tcp_connect, inet, {256, 0, 0, 1}, 80, [], 1000},
                    {tcp_connect, inet6, Ip, 80, [], 1000},
                    {udp_open, inet, any, 65536, []},
                    {udp_open, inet, any, 0, Long},
                    {udp_open, inet, {1, 2, 3}, 0, []},
                    {icmp_open, inet6},
                    {reserve_buffer, make_ref(), snd, -1},
                    {spawn, erlang, halt}]],
    ?assertMatch({ok, _, From}, erx_net_admit:request({'$gen_call', From, {tcp_connect, inet, Ip, 80,
                                                                             lists:duplicate(64, binary),
                                                                             4294967295}}, local)).

own_calls() ->
    Token = make_ref(),
    Local = {self(), make_ref()},
    Remote = {pid_of(?GRANTEE), [alias | ref_of(?GRANTEE)]},
    ?assertEqual({ok, {reserve_buffer, Token, snd, 8192}, Local},
                 erx_net_admit:request({'$gen_call', Local, {reserve_buffer, Token, snd, 8192}}, ?GRANTEE)),
    ?assertEqual({ok, counts, Local}, erx_net_admit:request({'$gen_call', Local, counts}, ?GRANTEE)),
    ?assertEqual({refused, shape, Remote},
                 erx_net_admit:request({erx_origin, ?GRANTEE, {'$gen_call', Remote, {release_buffers, Token}}}, ?GRANTEE)),
    ?assertEqual({refused, shape, Remote},
                 erx_net_admit:request({erx_origin, ?GRANTEE, {'$gen_call', Remote, counts}}, ?GRANTEE)).

not_a_call() ->
    [?assertEqual(unknown, erx_net_admit:request(Message, ?GRANTEE))
     || Message <- [interfaces, {erx_origin, ?GRANTEE, interfaces}, {erx_origin, ?GRANTEE, {'$gen_call', self(), interfaces}},
                    {erx_origin, ?GRANTEE, {'$gen_call', {grant, node()}, interfaces}},
                    {erx_origin, ?GRANTEE, {'$gen_cast', interfaces}}, {erx_origin, ?GRANTEE}]].

%% --- erx_net_admit:mint/2 --------------------------------------------------------------

mint_test() ->
    Request = {erx_facet_mint, 3, net, ?GRANTEE, #{}},
    ?assertEqual({ok, 3, ?GRANTEE, #{}}, erx_net_admit:mint(?SYSTEM, {erx_origin, ?SYSTEM, Request})),
    [?assertEqual(unknown, erx_net_admit:mint(?SYSTEM, Message))
     || Message <- [Request, {erx_origin, ?OTHER, Request},
                    {erx_origin, ?SYSTEM, {erx_facet_mint, 3, storage, ?GRANTEE, #{}}},
                    {erx_origin, ?SYSTEM, {erx_facet_mint, 0, net, ?GRANTEE, #{}}},
                    {erx_origin, ?SYSTEM, {erx_facet_mint, 3, net, local, #{}}},
                    {erx_origin, ?SYSTEM, {erx_facet_mint, 3, net, ?GRANTEE, []}}]].

domain_test() ->
    ?assertEqual(?GRANTEE, erx_net_admit:domain(pid_of(?GRANTEE))),
    ?assertEqual(16#12345678, erx_net_admit:domain(pid_of(16#12345678))),
    ?assertEqual(?GRANTEE, erx_net_admit:domain(ref_of(?GRANTEE))),
    LongNode = unicode:characters_to_binary(lists:duplicate(100, 16#20ac) ++ "@x"),
    ?assertEqual(?OTHER, erx_net_admit:domain(binary_to_term(<<131, 88, 118, (byte_size(LongNode)):16, LongNode/binary, 1:32, 0:32, ?OTHER:32>>))),
    ?assertEqual(?OTHER, erx_net_admit:domain(binary_to_term(<<131, 90, 1:16, 118, (byte_size(LongNode)):16, LongNode/binary, ?OTHER:32, 5:32>>))).

%% --- The grant process -----------------------------------------------------------------

grant_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [{"a call of another domain gets no answer and is counted", fun remote_other_domain_dropped/0},
      {"a call whose owner is of another domain gets no answer", fun remote_foreign_owner_dropped/0},
      {"a call of the grantee past its bounds is answered badarg", fun remote_bounds_refused/0},
      {"a local process's call of a remote grant is left out", fun remote_bare_dropped/0},
      {"the interfaces pass the client's check", fun interfaces_checked/0},
      {"an echo socket is its caller's, and ends with it", fun icmp_open_owned/0}]}.

remote_other_domain_dropped() ->
    {ok, Grant} = erx_net_grant:start_link(?GRANTEE, #{}),
    Tag = make_ref(),
    Grant ! {erx_origin, ?OTHER, {'$gen_call', {pid_of(?OTHER), Tag}, interfaces}},
    Grant ! {erx_origin, ?OTHER, {'$gen_call', {self(), Tag}, interfaces}},
    ?assertEqual(#{unknown => 2, refused => 0}, erx_net_grant:counts(Grant)),
    nothing(Tag).

remote_foreign_owner_dropped() ->
    {ok, Grant} = erx_net_grant:start_link(?GRANTEE, #{}),
    Tag = make_ref(),
    Grant ! {erx_origin, ?GRANTEE, {'$gen_call', {pid_of(?OTHER), Tag}, {icmp_open, inet}}},
    Grant ! {erx_origin, ?GRANTEE, {'$gen_call', {self(), Tag}, {tcp_connect, inet, {10, 0, 2, 2}, 80, [], infinity}}},
    ?assertEqual(#{unknown => 2, refused => 0}, erx_net_grant:counts(Grant)),
    nothing(Tag).

%% The reply goes to the grantee's caller, which the test cannot be; the count shows it
%% was refused rather than left out.
remote_bounds_refused() ->
    {ok, Grant} = erx_net_grant:start_link(?GRANTEE, #{}),
    Caller = {pid_of(?GRANTEE), [alias | ref_of(?GRANTEE)]},
    Grant ! {erx_origin, ?GRANTEE, {'$gen_call', Caller, {udp_open, inet, any, 0, lists:duplicate(65, binary)}}},
    Grant ! {erx_origin, ?GRANTEE, {'$gen_call', Caller, {release_buffers, make_ref()}}},
    ?assertEqual(#{unknown => 0, refused => 2}, erx_net_grant:counts(Grant)).

remote_bare_dropped() ->
    {ok, Grant} = erx_net_grant:start_link(?GRANTEE, #{}),
    Request = gen_server:send_request(Grant, interfaces),
    ?assertEqual(timeout, gen_server:wait_response(Request, ?QUIET)),
    ?assertEqual(#{unknown => 1, refused => 0}, erx_net_grant:counts(Grant)).

interfaces_checked() ->
    Answer = gen_server:call(erx_net_grant, interfaces),
    ?assertMatch({ok, [#{name := <<"en0">>, mtu := 1500, link := up, config := dhcp}]}, Answer),
    ?assertEqual({ok, Answer}, erx_sock_admit:answer(interfaces, whereis(erx_net_grant), Answer)),
    ?assertEqual(#{unknown => 0, refused => 0}, erx_net_grant:counts(whereis(erx_net_grant))).

icmp_open_owned() ->
    Self = self(),
    Owner = spawn(fun() -> Self ! {opened, gen_server:call(erx_net_grant, {icmp_open, inet})},
                           receive stop -> ok end
                  end),
    Sock = receive {opened, {ok, S}} -> S after ?WAIT -> error(no_open) end,
    ?assertEqual({ok, {ok, Sock}}, erx_sock_admit:answer(icmp_open, whereis(erx_net_grant), {ok, Sock})),
    Ref = monitor(process, Sock),
    Owner ! stop,
    receive {'DOWN', Ref, process, Sock, _} -> ok after ?WAIT -> error(socket_outlived_owner) end.

%% --- Set-up ----------------------------------------------------------------------------

setup() ->
    ok = persistent_term:put({erx_net_sup, runtime}, erx_net_local),
    {ok, Tables} = erx_net_tables:start_link(),
    unlink(Tables),
    Me = interface(),
    true = ets:insert(erx_net_ifs, {en0, Me, #{name => en0, pid => Me}}),
    {ok, Grant} = erx_net_grant:start_link(local, #{}),
    unlink(Grant),
    {Tables, Grant, Me}.

%% A stand-in interface that answers the status request.
interface() ->
    spawn(fun() ->
                  Status = #{name => en0, lladdr => <<2, 0, 0, 0, 0, 1>>, mtu => 1500, link => up, config => dhcp,
                             addrs => [#{addr => <<10, 0, 2, 15>>, plen => 24, broadcast => <<10, 0, 2, 255>>}],
                             routes => [], dns => [], search => []},
                  interface_loop(Status)
          end).

interface_loop(Status) ->
    receive
        {'$gen_call', From, {admin, status}} ->
            gen_server:reply(From, {ok, Status}),
            interface_loop(Status);
        stop ->
            ok
    end.

cleanup({Tables, Grant, Me}) ->
    [begin Ref = monitor(process, P), exit(P, kill), receive {'DOWN', Ref, _, _, _} -> ok end end
     || P <- [Grant, Me, Tables]],
    ok.

%% No reply under Tag arrives.
nothing(Tag) ->
    receive
        {Tag, Reply} -> error({answered, Reply})
    after ?QUIET ->
        ok
    end.

%% A pid of domain Domain, as another domain's process arrives here: its node's creation is
%% the domain id.
%% A reference made in the domain `Domain`, as NEWER_REFERENCE_EXT carries it.
ref_of(Domain) ->
    Node = <<"erx_other@nowhere">>,
    binary_to_term(<<131, 90, 3:16, 119, (byte_size(Node)), Node/binary, Domain:32, 1:32, 2:32, 3:32>>).

pid_of(Domain) ->
    Node = <<"erx_other@nowhere">>,
    binary_to_term(<<131, 88, 119, (byte_size(Node)), Node/binary, 1:32, 0:32, Domain:32>>).
