%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the ble facet, erx_ble_facet (docs/design-bluetooth.md, "The `ble`
%% facet"), in front of the real registry, erx_gatt_srv, serving abi/gatt's declared
%% services, which the test registers, kills and registers again, and of its mint below
%% erx_bt_top. A request naming a service the grant names reaches the registry with the
%% grantee's caller in it, and the answer reaches the caller; a request naming another
%% service is refused not_granted and one of no operation's shape badarg, before the
%% registry sees either; with no registry registered, unavailable; after the registry is
%% killed and started again, the facet lives and the next request reaches the new one,
%% whose attachments start empty. The attaching caller, not the facet, hears the events,
%% and only it answers the writes handed to it. The mint names itself the service's mint,
%% refuses a grant to the system domain and one with no connection to its grantee, and its
%% end ends erx_bt_top. As in erx_pcie_facet_tests, this module stands in for the export
%% table, and the test's own calls in the envelope are the grantee's.
-module(erx_ble_facet_tests).
-include_lib("eunit/include/eunit.hrl").
-define(GAP, #{name => <<"erxos">>, appearance => 0}).
-export([export/3, owner/1]).

-define(SYSTEM, 4).
-define(GRANTEE, 7).
-define(WAIT_MS, 2000).
-define(ADDRESS, {random, <<16#C0, 16#FF, 16#EE, 16#12, 16#34, 16#56>>}).

export(_Pid, _Rights, _Peer) -> ok.

owner(_Name) -> ?GRANTEE.

%% ---- fixtures ----

%% The registry serving every declared service, registered as erx_gatt_srv and not
%% linked to the test.
start_registry() ->
    {ok, Registry} = erx_gatt_srv:start_link(?GAP, [erx_gatt_decl:service(Name) || Name <- erx_gatt_decl:names()]),
    unlink(Registry),
    Registry.

%% Kills Registry and waits until it has gone, so its name is free.
kill(Registry) ->
    Ref = monitor(process, Registry),
    exit(Registry, kill),
    receive {'DOWN', Ref, process, Registry, _} -> ok end.

%% A facet granted Services, as the mint starts one; ends it after Test(Facet).
with_facet(Services, Test) ->
    with_facet(Services, #{}, Test).

%% The same for a grant that also states Extra, such as `identity`.
with_facet(Services, Extra, Test) ->
    Mint = spawn(fun() -> receive after infinity -> ok end end),
    Grant = Extra#{grantee => ?GRANTEE, ends_with => [Mint], operations => [], services => Services},
    {ok, Facet} = erx_facet:start(erx_ble_facet, Grant, #{exports => ?MODULE}),
    try
        Test(Facet)
    after
        exit(Mint, kill)
    end.

%% The same over a registry; ends both.
with_registry(Services, Test) ->
    with_registry(Services, #{}, Test).

with_registry(Services, Extra, Test) ->
    Registry = start_registry(),
    try
        with_facet(Services, Extra, Test)
    after
        kill(Registry)
    end.

%% A gen_server call of Request to Facet in the grantee's envelope, from the calling
%% process.
call(Facet, Request) ->
    Alias = alias(),
    Facet ! {erx_origin, ?GRANTEE, {'$gen_call', {self(), [alias | Alias]}, Request}},
    receive {[alias | Alias], Reply} -> Reply after ?WAIT_MS -> none end.

%% A stand-in link: joins the registry and tells the test its Conn, then sends the
%% registry each write the test asks for and passes on what the registry sends it.
stand_in_link(Test) ->
    spawn(fun() ->
                  Conn = make_ref(),
                  #{table := _} = erx_gatt_srv:join(Conn, #{address => ?ADDRESS}),
                  Test ! {joined, self(), Conn},
                  link_loop(Test)
          end).

link_loop(Test) ->
    receive
        {write, Ref, Key, Value} -> erx_gatt_srv ! {erx_bt_link, self(), {write, Ref, Key, Value}};
        {security, Security} -> erx_gatt_srv ! {erx_bt_link, self(), {security, Security}};
        Message -> Test ! {link_got, Message}
    end,
    link_loop(Test).

%% ---- the facet ----

a_granted_request_reaches_the_registry_and_its_answer_the_caller_test() ->
    with_registry([<<"nus">>], fun(Facet) ->
        ?assertMatch({ok, #{rx := #{max := 244}, tx := #{max := 244}}}, call(Facet, {attach, nus})),
        ?assertEqual({error, attached}, call(Facet, {attach, nus})),
        ?assertEqual(ok, call(Facet, {set, nus, tx, <<"hi">>})),
        ?assertEqual({error, too_long}, call(Facet, {set, nus, tx, binary:copy(<<0>>, 245)})),
        ?assertEqual({error, gone}, call(Facet, {notify, make_ref(), nus, tx, <<1>>}))
    end).

%% With a grant that names no service, the registry would attach the caller.
a_request_naming_another_service_is_refused_test() ->
    with_registry([], fun(Facet) ->
        ?assertEqual({error, not_granted}, call(Facet, {attach, nus})),
        ?assertEqual({error, not_granted}, call(Facet, {set, nus, tx, <<>>})),
        ?assertEqual({error, not_granted}, call(Facet, {indicate, make_ref(), nus, tx, <<>>})),
        %% none is an atom like any other service's name: no grant names it.
        ?assertEqual({error, not_granted}, call(Facet, {attach, none})),
        ?assertEqual({error, not_granted}, call(Facet, {set, none, tx, <<>>}))
    end),
    with_registry([<<"nus">>, <<"undeclared">>], fun(Facet) ->
        ?assertEqual({error, not_granted}, call(Facet, {attach, undeclared}))
    end).

a_request_of_no_operation_s_shape_is_refused_badarg_test() ->
    with_registry([<<"nus">>], fun(Facet) ->
        [?assertEqual({error, badarg}, call(Facet, Request))
         || Request <- [{attach, <<"nus">>}, {set, nus, tx, not_a_binary}, {set, nus, tx, <<1:3>>},
                        {notify, not_a_ref, nus, tx, <<>>}, {flood, make_ref(), nus, tx, <<>>},
                        {reply, make_ref(), {error, 1}}, {reply, make_ref(), {error, 16#A0}},
                        {reply, make_ref(), perhaps}, {reply, not_a_ref, ok}, attach, {}]]
    end).

with_no_registry_a_request_is_refused_unavailable_test() ->
    with_facet([<<"nus">>], fun(Facet) ->
        ?assertEqual({error, unavailable}, call(Facet, {attach, nus})),
        ?assertEqual({error, unavailable}, call(Facet, {reply, make_ref(), ok})),
        ?assertEqual({error, badarg}, call(Facet, {attach, 1}))
    end).

%% The registry's end takes its attachments, not the facet: after it, the facet refuses
%% unavailable, and once a registry is registered again the next request reaches it,
%% where the service has no handler.
the_facet_outlives_a_registry_restart_test() ->
    with_facet([<<"nus">>], fun(Facet) ->
        Old = start_registry(),
        ?assertMatch({ok, _}, call(Facet, {attach, nus})),
        kill(Old),
        ?assert(is_process_alive(Facet)),
        ?assertEqual({error, unavailable}, call(Facet, {attach, nus})),
        New = start_registry(),
        try
            ?assertMatch({ok, _}, call(Facet, {attach, nus})),
            ?assertEqual({error, attached}, call(Facet, {attach, nus}))
        after
            kill(New)
        end
    end).

%% The attaching caller hears a link's connection and the write handed to it; another
%% process of the grantee's answering that write through the same facet is dropped, and
%% the caller's answer reaches the link.
the_caller_hears_the_events_and_alone_answers_its_writes_test() ->
    with_registry([<<"nus">>], fun(Facet) ->
        Test = self(),
        ?assertMatch({ok, _}, call(Facet, {attach, nus})),
        Link = stand_in_link(Test),
        Conn = receive {joined, Link, C} -> C after ?WAIT_MS -> no_join end,
        ?assertMatch({connected, Conn, #{level := open}},
                     receive {connected, _, _} = Connected -> Connected after ?WAIT_MS -> none end),
        Link ! {write, 1, {nus, rx}, <<"hi">>},
        {write, Req, Conn, rx, <<"hi">>} = receive {write, _, _, _, _} = Write -> Write after ?WAIT_MS -> none end,
        Other = spawn(fun() -> Test ! {other, call(Facet, {reply, Req, ok})} end),
        ?assertEqual(ok, receive {other, Answer} -> Answer after ?WAIT_MS -> none end),
        ?assertEqual(none, receive {link_got, _} = Early -> Early after 200 -> none end),
        ?assertEqual(ok, call(Facet, {reply, Req, {error, 16#80}})),
        ?assertEqual({registry, {answer, 1, {error, 16#80}}}, receive {link_got, Got} -> Got after ?WAIT_MS -> none end),
        exit(Other, kill),
        exit(Link, kill)
    end).

%% A bonded link's identity reaches the handler whose grant states `identity` true, and
%% no other: the facet forwards each attach with its grant's statement, so the registry
%% tells the one handler the identity and the other the link as bonded without it. A phone
%% that connects from its identity address still shows it in `address`.
bonded_identity_reaches_only_a_grant_that_states_it_test() ->
    Bonded = #{level => encrypted, bonded => true, identity => {random, <<16#C1, 2, 3, 4, 5, 6>>}},
    Heard = fun(Extra) ->
        with_registry([<<"nus">>], Extra, fun(Facet) ->
            Test = self(),
            ?assertMatch({ok, _}, call(Facet, {attach, nus})),
            Link = stand_in_link(Test),
            receive {joined, Link, _} -> ok after ?WAIT_MS -> error(no_join) end,
            ?assertMatch({connected, _, #{level := open, bonded := false}},
                         receive {connected, _, _} = Open -> Open after ?WAIT_MS -> none end),
            Link ! {security, Bonded},
            Event = receive {connected, _, _} = Connected -> Connected after ?WAIT_MS -> none end,
            exit(Link, kill),
            Event
        end)
    end,
    ?assertMatch({connected, _, #{bonded := true, identity := {random, <<16#C1, 2, 3, 4, 5, 6>>}, address := ?ADDRESS}},
                 Heard(#{identity => true})),
    {connected, _, Silent} = Heard(#{}),
    ?assertMatch(#{bonded := true, address := ?ADDRESS}, Silent),
    ?assertNot(maps:is_key(identity, Silent)),
    {connected, _, False} = Heard(#{identity => false}),
    ?assertNot(maps:is_key(identity, False)).

%% ---- the mint ----

%% The mint's answer to a mint request for Grantee, as the domain pid takes it.
minted_for(Mint, Grantee) ->
    persistent_term:put({erx, domain_pid}, self()),
    try
        Mint ! {erx_origin, ?SYSTEM, {erx_facet_mint, 9, ble, Grantee, <<"system">>, #{services => [<<"nus">>]}}},
        receive {erx_facet_minted, 9, Reply} -> Reply after ?WAIT_MS -> none end
    after
        persistent_term:erase({erx, domain_pid})
    end.

%% erx_bt_top started by a process that traps exits, as the application master does;
%% ends it after Test(Top, Mint).
with_top(Test) ->
    Trap = process_flag(trap_exit, true),
    {ok, Top} = erx_bt_top:start_link(),
    [Mint] = [Pid || {erx_ble_facet, Pid, worker, _} <- supervisor:which_children(Top)],
    try
        Test(Top, Mint)
    after
        exit(Top, kill),
        receive {'EXIT', Top, _} -> ok end,
        persistent_term:erase({erx, provides}),
        process_flag(trap_exit, Trap)
    end.

the_mint_is_provided_and_refuses_the_system_domain_and_an_unconnected_grantee_test() ->
    with_top(fun(_Top, Mint) ->
        ?assertEqual(#{ble => Mint}, persistent_term:get({erx, provides})),
        ?assertEqual(refused, minted_for(Mint, ?SYSTEM)),
        ?assertEqual(refused, minted_for(Mint, ?GRANTEE)),
        ?assert(is_process_alive(Mint))
    end).

the_end_of_the_mint_ends_the_top_supervisor_test() ->
    with_top(fun(Top, Mint) ->
        Ref = monitor(process, Top),
        exit(Mint, kill),
        ?assertEqual(ok, receive {'DOWN', Ref, process, Top, _} -> ok after ?WAIT_MS -> none end)
    end).
