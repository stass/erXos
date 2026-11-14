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

%% The stack's runtime seam and the export table, stood in for by the mint cases.
-export([serve/1, start_grant/2, export/3]).

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
    Request = {erx_facet_mint, 3, net, ?GRANTEE, <<"user">>, #{}},
    ?assertEqual({ok, 3, ?GRANTEE, #{}}, erx_net_admit:mint(?SYSTEM, {erx_origin, ?SYSTEM, Request})),
    ?assertEqual({refused, eperm, 3},
                 erx_net_admit:mint(?SYSTEM, {erx_origin, ?SYSTEM, {erx_facet_mint, 3, net, ?SYSTEM, <<"system">>, #{}}})),
    From = {self(), make_ref()},
    ?assertEqual({counts, From}, erx_net_admit:mint(?SYSTEM, {'$gen_call', From, counts})),
    ?assertEqual(unknown, erx_net_admit:mint(?SYSTEM, {erx_origin, ?SYSTEM, {'$gen_call', From, counts}})),
    [?assertEqual(unknown, erx_net_admit:mint(?SYSTEM, Message))
     || Message <- [Request, {erx_origin, ?OTHER, Request},
                    {erx_origin, ?SYSTEM, {erx_facet_mint, 3, storage, ?GRANTEE, <<"user">>, #{}}},
                    {erx_origin, ?SYSTEM, {erx_facet_mint, 0, net, ?GRANTEE, <<"user">>, #{}}},
                    {erx_origin, ?SYSTEM, {erx_facet_mint, 3, net, local, <<"user">>, #{}}},
                    {erx_origin, ?SYSTEM, {erx_facet_mint, 3, net, ?GRANTEE, <<"user">>, []}},
                    {erx_origin, ?SYSTEM, {erx_facet_mint, 3, net, ?GRANTEE, user, #{}}},
                    {erx_origin, ?SYSTEM, {erx_facet_mint, 3, net, ?GRANTEE, #{}}}]].

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
      {"an echo socket is its caller's, and ends with it", fun icmp_open_owned/0},
      {"a listener is its caller's, holds its key, and ends with it", fun tcp_listen_owned/0},
      {"a listen with an option the listener does not take is refused einval",
       fun tcp_listen_option_refused/0},
      {"a listen the grant's listen or addresses limit does not allow is refused eacces",
       fun tcp_listen_limits/0}]}.

remote_other_domain_dropped() ->
    {ok, Grant} = remote_grant(),
    Tag = make_ref(),
    Grant ! {erx_origin, ?OTHER, {'$gen_call', {pid_of(?OTHER), Tag}, interfaces}},
    Grant ! {erx_origin, ?OTHER, {'$gen_call', {self(), Tag}, interfaces}},
    ?assertEqual(#{unknown => 2, refused => 0}, erx_net_grant:counts(Grant)),
    nothing(Tag).

remote_foreign_owner_dropped() ->
    {ok, Grant} = remote_grant(),
    Tag = make_ref(),
    Grant ! {erx_origin, ?GRANTEE, {'$gen_call', {pid_of(?OTHER), Tag}, {icmp_open, inet}}},
    Grant ! {erx_origin, ?GRANTEE, {'$gen_call', {self(), Tag}, {tcp_connect, inet, {10, 0, 2, 2}, 80, [], infinity}}},
    ?assertEqual(#{unknown => 2, refused => 0}, erx_net_grant:counts(Grant)),
    nothing(Tag).

%% The reply goes to the grantee's caller, which the test cannot be; the count shows it
%% was refused rather than left out.
remote_bounds_refused() ->
    {ok, Grant} = remote_grant(),
    Caller = {pid_of(?GRANTEE), [alias | ref_of(?GRANTEE)]},
    Grant ! {erx_origin, ?GRANTEE, {'$gen_call', Caller, {udp_open, inet, any, 0, lists:duplicate(65, binary)}}},
    Grant ! {erx_origin, ?GRANTEE, {'$gen_call', Caller, {release_buffers, make_ref()}}},
    ?assertEqual(#{unknown => 0, refused => 2}, erx_net_grant:counts(Grant)).

remote_bare_dropped() ->
    {ok, Grant} = remote_grant(),
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

%% A listen on port 0 from a socket process of its own: the grant answers the listener,
%% whose key the bind claimed for the grant with the listener's entry, and whose sockname
%% is the port bound. The owner's end ends the listener and frees its key.
tcp_listen_owned() ->
    Self = self(),
    Owner = spawn(fun() ->
                          {ok, L} = Reply = gen_server:call(erx_net_grant, {tcp_listen, inet, any, 0, [{backlog, 2}]}),
                          Self ! {listening, Reply},
                          Self ! {sockname, call(L, sockname)},
                          receive stop -> ok end
                  end),
    L = receive {listening, {ok, P}} -> P after ?WAIT -> error(no_listener) end,
    ?assertEqual({ok, {ok, L}}, erx_sock_admit:answer(tcp_listen, whereis(erx_net_grant), {ok, L})),
    Port = receive {sockname, {ok, {{0, 0, 0, 0}, N}}} -> N after ?WAIT -> error(no_sockname) end,
    Grant = whereis(erx_net_grant),
    ?assertMatch([#{pid := L, grant := Grant, origin := local, listener := #{rcv_buf := 65536},
                    accept := #{nodelay := false, snd_hiwat := 32768, rcv_hiwat := 65536}}],
                 erx_net_tables:demux({tcp_listen, inet, any, Port})),
    Ref = monitor(process, L),
    Owner ! stop,
    receive {'DOWN', Ref, process, L, normal} -> ok after ?WAIT -> error(listener_outlived_owner) end,
    ?assertEqual([], erx_net_tables:demux({tcp_listen, inet, any, Port})).

tcp_listen_option_refused() ->
    ?assertEqual({error, einval}, gen_server:call(erx_net_grant, {tcp_listen, inet, any, 0, [{active, true}]})),
    ?assertEqual({error, einval}, gen_server:call(erx_net_grant, {tcp_listen, inet, any, 0, [{backlog, x}]})).

%% A grant whose listen limit is false refuses every listen; one whose addresses limit lists
%% an address refuses another and the wildcard alike, for a listener and a datagram socket.
tcp_listen_limits() ->
    ok = gen_server:stop(erx_net_grant),
    {ok, NoListen} = erx_net_grant:start_link(local, #{listen => false}),
    ?assertEqual({error, eacces}, gen_server:call(NoListen, {tcp_listen, inet, any, 0, []})),
    ok = gen_server:stop(NoListen),
    {ok, Narrow} = erx_net_grant:start_link(local, #{addresses => [{10, 0, 2, 15}]}),
    try
        ?assertEqual({error, eacces}, gen_server:call(Narrow, {tcp_listen, inet, any, 0, []})),
        ?assertEqual({error, eacces}, gen_server:call(Narrow, {tcp_listen, inet, {10, 0, 2, 16}, 0, []})),
        ?assertEqual({error, eacces}, gen_server:call(Narrow, {udp_open, inet, any, 0, []}))
    after
        ok = gen_server:stop(Narrow)
    end.

%% A socket protocol call of a socket from its socket process, the caller.
call(Sock, Request) ->
    Sock ! {erx_net, self(), {call, 1, Request}},
    receive {erx_net, Sock, {reply, 1, Reply}} -> Reply after ?WAIT -> error({no_reply, Request}) end.

%% --- erx_net:mint_grant/4 --------------------------------------------------------------
%%
%% The grants supervisor runs as in the stack, with this module as the runtime, whose
%% start_grant/2 starts the grant as erXos's does, and as the export table, whose export/3
%% tells the test what it was asked and whether the grant was alive then, and answers what
%% the case set under {?MODULE, export}: an answer, or {close, Connection, Answer}, the
%% connection ending during the export.

mint_grant_test_() ->
    {foreach, fun mint_setup/0, fun mint_cleanup/1,
     [{"a minted grant is exported to its grantee, send alone, before it is answered", fun minted_exported/0},
      {"a refused export ends the grant and answers the refusal", fun refused_export_ends_grant/0},
      {"a connection that ends during the mint leaves the refusal and no grant", fun connection_ends_during_mint/0},
      {"the grantee's call of a minted grant is served, a third domain's is not", fun minted_serves_grantee_only/0},
      {"a minted grant ends when its connection to the grantee ends", fun grant_ends_with_connection/0}]}.

minted_exported() ->
    {ok, Grant} = mint(connection()),
    receive
        {exported, Exported, Rights, Peer, Alive} ->
            ?assertEqual({Grant, [send], ?GRANTEE, true}, {Exported, Rights, Peer, Alive})
    after 0 ->
            error(answered_before_export)
    end,
    ?assertEqual([Grant], grants()).

refused_export_ends_grant() ->
    persistent_term:put({?MODULE, export}, {error, noconnection}),
    ?assertEqual({error, noconnection}, mint(connection())),
    receive {exported, Grant, _, _, true} -> ?assertNot(is_process_alive(Grant)) after 0 -> error(not_exported) end,
    ?assertEqual([], grants()).

connection_ends_during_mint() ->
    Connection = connection(),
    persistent_term:put({?MODULE, export}, {close, Connection, {error, noconnection}}),
    ?assertEqual({error, noconnection}, mint(Connection)),
    ?assertEqual([], grants()).

minted_serves_grantee_only() ->
    {ok, Grant} = mint(connection()),
    Grant ! {erx_origin, ?GRANTEE, {'$gen_call', {pid_of(?GRANTEE), [alias | ref_of(?GRANTEE)]}, interfaces}},
    Grant ! {erx_origin, ?OTHER, {'$gen_call', {pid_of(?OTHER), [alias | ref_of(?OTHER)]}, interfaces}},
    ?assertEqual(#{unknown => 1, refused => 0}, erx_net_grant:counts(Grant)).

grant_ends_with_connection() ->
    Connection = connection(),
    {ok, Grant} = mint(Connection),
    Ref = monitor(process, Grant),
    true = port_close(Connection),
    receive {'DOWN', Ref, process, Grant, Reason} -> ?assertEqual({shutdown, connection_ended}, Reason)
    after ?WAIT -> error(grant_outlived_connection)
    end,
    %% The supervisor's 'EXIT' may reach it after the 'DOWN' reaches the test.
    dropped(Grant, ?WAIT).

mint_setup() ->
    ok = persistent_term:put({erx_net_sup, runtime}, ?MODULE),
    persistent_term:put({?MODULE, export}, ok),
    {ok, Tables} = erx_net_tables:start_link(),
    unlink(Tables),
    {ok, Grants} = supervisor:start_link({local, erx_net_grants}, erx_net_sup, grants),
    unlink(Grants),
    {Tables, Grants}.

mint_cleanup({Tables, Grants}) ->
    [begin Ref = monitor(process, P), exit(P, kill), receive {'DOWN', Ref, _, _, _} -> ok end end
     || P <- [Grants, Tables]],
    persistent_term:erase({?MODULE, export}),
    persistent_term:erase({?MODULE, test}),
    ok.

%% Mints the grantee's grant over Connection, with this module as the export table, which
%% tells the calling test what it was asked.
mint(Connection) ->
    persistent_term:put({?MODULE, test}, self()),
    erx_net:mint_grant(?GRANTEE, Connection, #{}, ?MODULE).

grants() ->
    [Pid|| {_, Pid, _, _} <- supervisor:which_children(erx_net_grants)].

-doc false.
serve(_MaxRequest) ->
    ok.

-doc false.
start_grant(Grantee, Limits) ->
    erx_net_grant:start_link(Grantee, Limits).

-doc false.
export(Name, Rights, Peer) ->
    persistent_term:get({?MODULE, test}) ! {exported, Name, Rights, Peer, is_process_alive(Name)},
    case persistent_term:get({?MODULE, export}) of
        {close, Connection, Answer} ->
            true = port_close(Connection),
            ended(Name),
            Answer;
        Answer ->
            Answer
    end.

%% Waits for the grant's end after its connection's, and for the grants supervisor to drop
%% it, whose 'EXIT' may reach it after the 'DOWN' reaches the test, so the export's answer
%% meets a grant that is gone; nothing to wait for when the export runs in the grant itself.
ended(Grant) when Grant =:= self() ->
    ok;
ended(Grant) ->
    Ref = monitor(process, Grant),
    receive {'DOWN', Ref, process, Grant, _} -> ok after ?WAIT -> error(grant_outlived_connection) end,
    dropped(Grant, ?WAIT).

dropped(Grant, Left) ->
    case lists:member(Grant, grants()) of
        false -> ok;
        true when Left > 0 -> timer:sleep(10), dropped(Grant, Left - 10);
        true -> error(grant_kept)
    end.

%% --- erx_net_client_erxos:grant/0 ------------------------------------------------------

client_grant_test() ->
    Grant = pid_of(?OTHER),
    with_erx(#{net => Grant}, fun() -> ?assertEqual({ok, Grant, ?OTHER}, erx_net_client_erxos:grant()) end),
    with_erx(#{echo => Grant}, fun() -> ?assertEqual({error, enotconn}, erx_net_client_erxos:grant()) end).

%% Runs Fun with a stand-in of erx loaded: the facets this domain holds, read from the
%% registry's persistent term as erx:cap/1 reads it, and owner/1, the domain id a name's
%% creation carries, as erx_dist:owner/1 answers it.
with_erx(Facets, Fun) ->
    Text = ["-module(erx).", "-export([cap/1, owner/1]).",
            "cap(Name) -> maps:get(Name, persistent_term:get({erx, facets}, #{}), undefined).",
            "owner(Name) -> erx_net_admit:domain(Name)."],
    Forms = [begin {ok, Tokens, _} = erl_scan:string(Form), {ok, Parsed} = erl_parse:parse_form(Tokens), Parsed end
             || Form <- Text],
    {ok, erx, Beam} = compile:forms(Forms),
    {module, erx} = code:load_binary(erx, "erx.erl", Beam),
    persistent_term:put({erx, facets}, Facets),
    try Fun()
    after
        persistent_term:erase({erx, facets}),
        code:purge(erx),
        code:delete(erx)
    end.

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

%% A stand-in of the network domain's connection to the grantee: a port, whose end is the
%% connection's end, as the lane driver's port of an introduced connection is.
connection() ->
    open_port({spawn, "cat"}, [binary]).

%% A grant of ?GRANTEE over a connection of its own, exported through this module's
%% stand-in of the export table.
remote_grant() ->
    persistent_term:put({?MODULE, export}, ok),
    persistent_term:put({?MODULE, test}, self()),
    erx_net_grant:start_link({?GRANTEE, connection(), ?MODULE}, #{}).

%% A pid of domain Domain, as another domain's process arrives here: its node's creation is
%% the domain id.
%% A reference made in the domain `Domain`, as NEWER_REFERENCE_EXT carries it.
ref_of(Domain) ->
    Node = <<"erx_other@nowhere">>,
    binary_to_term(<<131, 90, 3:16, 119, (byte_size(Node)), Node/binary, Domain:32, 1:32, 2:32, 3:32>>).

pid_of(Domain) ->
    Node = <<"erx_other@nowhere">>,
    binary_to_term(<<131, 88, 119, (byte_size(Node)), Node/binary, 1:32, 0:32, Domain:32>>).
