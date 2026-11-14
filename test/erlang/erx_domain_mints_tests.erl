%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_domain_mints, the domain service's pure core for facets
%% a configured domain serves (docs/design-system.md, "Facets a configured
%% domain serves"): named scenarios, then an exhaustive exploration of every
%% order of its events.
%%
%% Rows: S (0) serves data, G (1) is granted it, T (2) serves only other.
%% Domain D's node is dD@h, and a pid of D is a remote pid of that node with
%% creation D: mint(D) is D's mint, facet(D) a facet D minted, and owner/1
%% reads the creation back, as erx:owner/1 does on the system domain.
%% forged(D) has D's creation but domain 99's node, so a send to it would
%% reach 99. Domain 99 is a third domain the manifest never names.
%%
%% The explorer drives the core from a model of its environment written
%% independently of it: up to two incarnations of S and of G, each started,
%% reporting ready and ending in any order; T, id 50, running from the start
%% and claiming data; a ready report that may arrive after its domain's end;
%% introductions that succeed or fail; a server that answers each mint
%% request or stays silent; a grantee that acknowledges each install or stays
%% silent; every armed deadline firing; replies delivered in any order, one
%% of them twice; and one hostile act: S naming domain 99's mint or a forged
%% one, S answering with a facet of 99 or a forged one, a refused mint or
%% introduction, or any domain the model started, or 99, answering any tag
%% as a mint or as a grantee. It runs with the grant to G alone, and with
%% grants to G and to the system domain side by side, over fewer
%% incarnations, and with the grant to template 0's sessions: one session
%% beside two incarnations of S, and two sessions beside one, each started, reporting ready and ending in any order beside
%% S's incarnations. A session's report reaches the core when it is made,
%% before its end, as erx_domain_srv passes it on; a session answers
%% hostile acts like any other domain, so one session may acknowledge
%% another's install. Every step the model allows is taken from every reachable
%% state, breadth first, and these hold everywhere:
%%
%% * one_timer: the armed deadlines are exactly the pending operations' tags,
%%   so every operation ends and none has two;
%% * current_pair: every grant that is not idle carries the server's and its
%%   grantee's current ready incarnations, and an installed facet is the
%%   server's;
%% * authentic_mint: every mint request goes to the mint of the server's
%%   current incarnation, never to another domain's;
%% * authentic_install: every install goes to a current grantee, a row
%%   grantee only after its introduction, and names a facet of the server's
%%   current incarnation;
%% * acknowledged: a grant becomes installed only on its grantee's
%%   acknowledgement of the install sent for that operation;
%% * session_entries: the core holds a session's grant exactly while the
%%   session is ready, so an ended session leaves nothing behind;
%% * session_mark: every mint, the first and each one after the server's
%%   restart, carries session => true exactly when its grantee is a session
%%   whose report marked the grant, and its row's limits else;
%% * honest_progress: once nothing is in flight in a run with no hostile act,
%%   no refused step and no fired deadline, every grant that has a pair is
%%   installed.

-module(erx_domain_mints_tests).
-include_lib("eunit/include/eunit.hrl").

-export([owner/1]).

-define(S, 0).
-define(G, 1).
-define(T, 2).
-define(THIRD, 99).
-define(LIMITS, #{max_request => 4096}).
%% A marked grant's limits as its mint carries them: the session mark added.
-define(MARKED_LIMITS, #{max_request => 4096, session => true}).

owner(Pid) ->
    <<131, 88, 119, Length, _Node:Length/binary, _Id:32, _Serial:32, Creation:32>> = term_to_binary(Pid),
    Creation.

node_of(Domain) -> list_to_atom("d" ++ integer_to_list(Domain) ++ "@h").

pid(Node, Creation, Number) ->
    Name = atom_to_binary(Node),
    binary_to_term(<<131, 88, 119, (byte_size(Name)), Name/binary, Number:32, 0:32, Creation:32>>).

mint(Domain) -> pid(node_of(Domain), Domain, 1).
facet(Domain) -> pid(node_of(Domain), Domain, 2).
forged(Domain) -> pid(node_of(?THIRD), Domain, 2).

ready(Row, Id, Provides) -> {ready, Row, Id, node_of(Id), Provides}.

config(Grantees) ->
    #{services => [{?S, data}, {?T, other}], grants => [{Grantee, data, ?S, ?LIMITS} || Grantee <- Grantees],
      owner => fun ?MODULE:owner/1, deadline => 10000}.

new() -> erx_domain_mints:new(config([?G])).

%% Steps Events in order; the actions of each, and the last state.
run(Events, State) ->
    lists:mapfoldl(fun erx_domain_mints:step/2, State, Events).

grant(State) -> maps:get({?G, data}, erx_domain_mints:grants(State)).

%% S1 = 5 and G1 = 6 ready, the introduction done: the grant is minting tag 1.
minting() ->
    {_, State} = run([ready(?S, 5, #{data => mint(5)}), ready(?G, 6, #{}), {introduced, 1, ok}], new()),
    {minting, {5, 6}, 1} = grant(State),
    State.

%% Named scenarios.

in_order_test() ->
    {Actions, State} = run([ready(?S, 5, #{data => mint(5)}), ready(?G, 6, #{}), {introduced, 1, ok},
                            {minted, 5, 1, {ok, facet(5)}}, {installed, 6, 1}], new()),
    ?assertEqual([[],
                  [{arm, 1, 10000}, {introduce, 1, 5, 6}],
                  [{mint, 1, mint(5), data, 6, ?LIMITS}],
                  [{install, 1, 6, data, facet(5)}],
                  [{disarm, 1}]], Actions),
    ?assertEqual({installed, {5, 6}, facet(5)}, grant(State)).

%% The pixel area is a fact of the pair (pair_area/3): a windows grant's server reads
%% an area of the grant's pixels in whole pages, or windows_pixels_default where its
%% limits state none, for a pair of that server's row and the grantee, its row or a
%% session of its template, in either order and whatever incarnation is ready; any
%% other pair, a grant of another service's or a request's domain, has none.
windows(Grants) ->
    erx_domain_mints:new(#{services => [{?S, display}, {?S, data}], grants => Grants,
                           owner => fun ?MODULE:owner/1, windows => [display]}).

windows_pair_has_the_grants_pixels_test() ->
    Mints = windows([{?G, display, ?S, #{pixels => 8 * 4096}}]),
    ?assertEqual({8 * 4096, 5}, erx_domain_mints:pair_area({5, {configured, ?S}}, {6, {configured, ?G}}, Mints)),
    ?assertEqual({8 * 4096, 5}, erx_domain_mints:pair_area({6, {configured, ?G}}, {5, {configured, ?S}}, Mints)).

windows_pair_rounds_its_pixels_to_pages_test() ->
    Mints = windows([{?G, display, ?S, #{pixels => 4096 + 1}}]),
    ?assertEqual({2 * 4096, 5}, erx_domain_mints:pair_area({5, {configured, ?S}}, {6, {configured, ?G}}, Mints)).

windows_pair_without_pixels_has_the_default_test() ->
    Mints = windows([{?G, display, ?S, #{}}]),
    ?assertEqual({8 bsl 20, 5}, erx_domain_mints:pair_area({5, {configured, ?S}}, {6, {configured, ?G}}, Mints)).

other_pairs_have_no_area_test() ->
    Mints = windows([{?G, data, ?S, #{pixels => 4096}}, {{template, 0}, display, ?S, #{}}]),
    ?assertEqual(none, erx_domain_mints:pair_area({5, {configured, ?S}}, {6, {configured, ?G}}, Mints)),
    ?assertEqual(none, erx_domain_mints:pair_area({5, {configured, ?S}}, {9, {session, 1}}, Mints)),
    ?assertEqual(none, erx_domain_mints:pair_area({5, {configured, ?S}}, {9, request}, Mints)),
    ?assertEqual(none, erx_domain_mints:pair_area({5, {configured, ?T}}, {9, {session, 0}}, Mints)).

session_pair_has_its_templates_pixels_test() ->
    Mints = windows([{{template, 0}, display, ?S, #{pixels => 3 * 4096}}]),
    ?assertEqual({3 * 4096, 5}, erx_domain_mints:pair_area({9, {session, 0}}, {5, {configured, ?S}}, Mints)).

%% Two displays granted to each other share one connection: the lower server row's
%% grant gives the pair its area (TODO.md, pair_area/3).
displays_granted_to_each_other_test() ->
    Mints = erx_domain_mints:new(#{services => [{?S, display}, {?G, view}],
                                   grants => [{?G, display, ?S, #{pixels => 4096}}, {?S, view, ?G, #{pixels => 8192}}],
                                   owner => fun ?MODULE:owner/1, windows => [display, view]}),
    ?assertEqual({4096, 5}, erx_domain_mints:pair_area({6, {configured, ?G}}, {5, {configured, ?S}}, Mints)).

%% The introduction of a windows grant names only the pair; the area is the pair's.
windows_grant_introduces_the_pair_test() ->
    {Actions, _} = run([ready(?S, 5, #{display => mint(5)}), ready(?G, 6, #{})],
                       windows([{?G, display, ?S, #{pixels => 8 * 4096}}])),
    ?assertEqual([[], [{arm, 1, 10000}, {introduce, 1, 5, 6}]], Actions).

grantee_first_test() ->
    {Actions, _} = run([ready(?G, 6, #{}), ready(?S, 7, #{data => mint(7)})], new()),
    ?assertEqual([[], [{arm, 1, 10000}, {introduce, 1, 7, 6}]], Actions).

system_grantee_skips_the_introduction_test() ->
    {Actions, State} = run([ready(?S, 5, #{data => mint(5)}), {minted, 5, 1, {ok, facet(5)}},
                            {installed, 4, 1}], erx_domain_mints:new(config([system]))),
    ?assertEqual([[{arm, 1, 10000}, {mint, 1, mint(5), data, 4, ?LIMITS}],
                  [{install, 1, 4, data, facet(5)}],
                  [{disarm, 1}]], Actions),
    ?assertEqual(#{{system, data} => {installed, {5, 4}, facet(5)}}, erx_domain_mints:grants(State)).

two_grants_keep_their_own_operations_test() ->
    {Actions, State} = run([ready(?S, 5, #{data => mint(5)}), ready(?G, 6, #{}), {minted, 5, 2, {ok, facet(5)}},
                            {installed, 6, 1}, {installed, 4, 1}],
                           erx_domain_mints:new(config([?G, system]))),
    ?assertEqual([[{arm, 1, 10000}, {mint, 1, mint(5), data, 4, ?LIMITS}],
                  [{arm, 2, 10000}, {introduce, 2, 5, 6}],
                  [{dropped, unexpected, {minted, 5}}],
                  [{dropped, unexpected, {installed, 6}}],
                  [{dropped, unexpected, {installed, 4}}]], Actions),
    ?assertEqual(#{{?G, data} => {introducing, {5, 6}, 2}, {system, data} => {minting, {5, 4}, 1}},
                 erx_domain_mints:grants(State)).

restart_installs_the_new_facet_test() ->
    {_, Installed} = run([{minted, 5, 1, {ok, facet(5)}}, {installed, 6, 1}], minting()),
    {Actions, State} = run([{ended, ?S, 5}, ready(?S, 8, #{data => mint(8)}), {introduced, 2, ok},
                            {minted, 8, 2, {ok, facet(8)}}, {installed, 6, 2}], Installed),
    ?assertEqual([[], [{arm, 2, 10000}, {introduce, 2, 8, 6}], [{mint, 2, mint(8), data, 6, ?LIMITS}],
                  [{install, 2, 6, data, facet(8)}], [{disarm, 2}]], Actions),
    ?assertEqual({installed, {8, 6}, facet(8)}, grant(State)).

reply_with_a_facet_of_another_domain_fails_test() ->
    lists:foreach(fun(Facet) ->
                          {[Actions], State} = run([{minted, 5, 1, {ok, Facet}}], minting()),
                          ?assertEqual([{disarm, 1}, {failed, {?G, data}, {5, 6}, bad_reply}], Actions),
                          ?assertEqual({failed, {5, 6}, bad_reply}, grant(State))
                  end, [facet(?THIRD), forged(5)]).

malformed_replies_fail_test() ->
    lists:foreach(fun(Reply) ->
                          {[Actions], _} = run([{minted, 5, 1, Reply}], minting()),
                          ?assertEqual([{disarm, 1}, {failed, {?G, data}, {5, 6}, bad_reply}], Actions)
                  end, [ok, {ok, "<0.5.2>"}, {ok, facet(5), extra}, {error, enospc}, facet(5)]).

malformed_tags_match_nothing_test() ->
    {Actions, State} = run([{minted, 5, 1.0, {ok, facet(5)}}, {minted, 5, none, {ok, facet(5)}},
                            {minted, 5, [1], {ok, facet(5)}}, {installed, 6, 1.0}], minting()),
    ?assertEqual([[{dropped, unknown_tag, {minted, 5}}], [{dropped, unknown_tag, {minted, 5}}],
                  [{dropped, unknown_tag, {minted, 5}}], [{dropped, unknown_tag, {installed, 6}}]], Actions),
    ?assertEqual({minting, {5, 6}, 1}, grant(State)).

refused_mint_fails_and_stays_failed_test() ->
    {_, State} = run([{minted, 5, 1, {error, enospc}}, ready(?T, 7, #{})], minting()),
    ?assertEqual({failed, {5, 6}, bad_reply}, grant(State)).

wrong_provider_claiming_data_is_refused_test() ->
    {Actions, State} = run([ready(?T, 7, #{data => mint(7)}), ready(?G, 6, #{})], new()),
    ?assertEqual([[{refused, undeclared, {?T, 7}}], []], Actions),
    ?assertEqual(idle, grant(State)).

mint_of_another_domain_is_refused_and_never_called_test() ->
    lists:foreach(fun(Mint) ->
                          {Actions, State} = run([ready(?S, 5, #{data => Mint}), ready(?G, 6, #{})], new()),
                          ?assertEqual([[{refused, foreign_mint, {?S, 5, data}}], []], Actions),
                          ?assertEqual(idle, grant(State))
                  end, [mint(?THIRD), pid(node_of(5), ?THIRD, 1), pid(node_of(?THIRD), 5, 1)]).

callbacks_as_mints_are_refused_test() ->
    Fun = fun() -> ok end,
    lists:foreach(fun(Mint) ->
                          {[Actions], _} = run([ready(?S, 5, #{data => Mint})], new()),
                          ?assertEqual([{refused, not_a_pid, {?S, 5, data}}], Actions)
                  end, [Fun, {erx_storage, mint, []}, erx_storage_mint, "data"]).

malformed_provides_are_refused_whole_test() ->
    {[NotMap], _} = run([ready(?S, 5, [{data, mint(5)}])], new()),
    ?assertEqual([{refused, not_a_map, {?S, 5}}], NotMap),
    {[Oversized, []], State} = run([ready(?S, 5, #{data => mint(5), other => mint(5)}), ready(?G, 6, #{})], new()),
    ?assertEqual([{refused, oversized, {?S, 5, 2}}], Oversized),
    ?assertEqual(idle, grant(State)).

stale_report_provides_nothing_test() ->
    {Actions, State} = run([ready(?G, 6, #{}), {ended, ?S, 5}, ready(?S, 5, #{data => mint(5)}),
                            ready(?S, 8, #{data => mint(8)}), ready(?S, 5, #{data => mint(5)})], new()),
    ?assertEqual([[], [], [{refused, stale_report, {?S, 5}}], [{arm, 1, 10000}, {introduce, 1, 8, 6}],
                  [{refused, stale_report, {?S, 5}}]], Actions),
    ?assertEqual({introducing, {8, 6}, 1}, grant(State)).

silent_mint_meets_its_deadline_test() ->
    {Actions, State} = run([{deadline, 1}, ready(?T, 7, #{}), {minted, 5, 1, {ok, facet(5)}}, {deadline, 1}],
                           minting()),
    ?assertEqual([[{failed, {?G, data}, {5, 6}, {deadline, minting}}], [], [{dropped, unknown_tag, {minted, 5}}], []],
                 Actions),
    ?assertEqual({failed, {5, 6}, {deadline, minting}}, grant(State)).

old_reply_after_a_new_grant_is_dropped_test() ->
    {Actions, State} = run([{ended, ?S, 5}, ready(?S, 8, #{data => mint(8)}), {introduced, 2, ok},
                            {minted, 5, 1, {ok, facet(5)}}, {minted, 5, 2, {ok, facet(5)}},
                            {minted, 8, 2, {ok, facet(8)}}, {installed, 6, 2}],
                           minting()),
    ?assertEqual([[{disarm, 1}], [{arm, 2, 10000}, {introduce, 2, 8, 6}], [{mint, 2, mint(8), data, 6, ?LIMITS}],
                  [{dropped, unknown_tag, {minted, 5}}], [{dropped, wrong_domain, {minted, 5}}],
                  [{install, 2, 6, data, facet(8)}], [{disarm, 2}]],
                 Actions),
    ?assertEqual({installed, {8, 6}, facet(8)}, grant(State)).

grantee_exit_while_minting_cancels_test() ->
    {Actions, State} = run([{ended, ?G, 6}, {minted, 5, 1, {ok, facet(5)}}], minting()),
    ?assertEqual([[{disarm, 1}], [{dropped, unknown_tag, {minted, 5}}]], Actions),
    ?assertEqual(idle, grant(State)).

second_trigger_leaves_one_operation_test() ->
    {Actions, State} = run([ready(?G, 6, #{}), ready(?T, 7, #{}), ready(?S, 5, #{data => mint(5)})], minting()),
    ?assertEqual([[{refused, stale_report, {?G, 6}}], [], [{refused, stale_report, {?S, 5}}]], Actions),
    ?assertEqual({minting, {5, 6}, 1}, grant(State)).

replies_from_the_wrong_domain_or_step_are_dropped_test() ->
    {Actions, _} = run([{minted, ?THIRD, 1, {ok, facet(?THIRD)}}, {minted, 6, 1, {ok, facet(6)}}, {installed, 6, 1},
                        {minted, 5, 7, {ok, facet(5)}}, {minted, 5, 1, {ok, facet(5)}}, {minted, 5, 1, {ok, facet(5)}},
                        {installed, ?THIRD, 1}, {installed, 5, 1}, {installed, 6, 1}, {installed, 6, 1}], minting()),
    ?assertEqual([[{dropped, wrong_domain, {minted, ?THIRD}}], [{dropped, wrong_domain, {minted, 6}}],
                  [{dropped, unexpected, {installed, 6}}], [{dropped, unknown_tag, {minted, 5}}],
                  [{install, 1, 6, data, facet(5)}], [{dropped, unexpected, {minted, 5}}],
                  [{dropped, wrong_domain, {installed, ?THIRD}}], [{dropped, wrong_domain, {installed, 5}}],
                  [{disarm, 1}], [{dropped, unknown_tag, {installed, 6}}]], Actions).

failed_introduction_fails_the_operation_test() ->
    {_, Ready} = run([ready(?S, 5, #{data => mint(5)}), ready(?G, 6, #{})], new()),
    {[Actions], State} = run([{introduced, 1, {error, elimit}}], Ready),
    ?assertEqual([{disarm, 1}, {failed, {?G, data}, {5, 6}, {introduce, {error, elimit}}}], Actions),
    ?assertMatch({failed, _, _}, grant(State)).

invalid_configuration_is_refused_test() ->
    Owner = fun ?MODULE:owner/1,
    Bad = [#{services => [], grants => [{?G, data, ?S, #{}}], owner => Owner},
           #{services => [{?S, data}], grants => [{?S, data, ?S, #{}}], owner => Owner},
           #{services => [{?S, data}], grants => [{?G, data, ?S, #{}}, {?G, data, ?S, #{}}], owner => Owner},
           #{services => [{?T, data}], grants => [{?G, data, ?S, #{}}], owner => Owner},
           #{services => [{?S, data}, {system, apps}], grants => [{?G, data, ?S, #{}}], owner => Owner}],
    [?assertError(badarg, erx_domain_mints:new(Config)) || Config <- Bad].

%% Sessions: template 0's sessions are granted data. A session's id is never reused
%% within a boot, and the service passes on its ready report at most once, before its end.

sessions() -> erx_domain_mints:new(config([{template, 0}])).

session_grants(State) -> erx_domain_mints:grants(State).

%% S1 = 5 ready, session 9 ready and introduced: its grant is minting tag 1.
session_minting() ->
    {_, State} = run([ready(?S, 5, #{data => mint(5)}), {session_ready, 0, 9, none}, {introduced, 1, ok}], sessions()),
    ?assertEqual(#{{{session, 9}, data} => {minting, {5, 9}, 1}}, session_grants(State)),
    State.

%% Session 9's grant installed, and session 10's.
two_sessions_installed() ->
    {_, State} = run([{session_ready, 0, 10, none}, {introduced, 2, ok}, {minted, 5, 1, {ok, facet(5)}},
                      {minted, 5, 2, {ok, facet(5)}}, {installed, 9, 1}, {installed, 10, 2}],
                     session_minting()),
    State.

session_ready_installs_test() ->
    {Actions, State} = run([ready(?S, 5, #{data => mint(5)}), {session_ready, 0, 9, none}, {introduced, 1, ok},
                            {minted, 5, 1, {ok, facet(5)}}, {installed, 9, 1}], sessions()),
    ?assertEqual([[],
                  [{arm, 1, 10000}, {introduce, 1, 5, 9}],
                  [{mint, 1, mint(5), data, 9, ?LIMITS}],
                  [{install, 1, 9, data, facet(5)}],
                  [{disarm, 1}]], Actions),
    ?assertEqual(#{{{session, 9}, data} => {installed, {5, 9}, facet(5)}}, session_grants(State)).

%% A namespace in place (docs/design-system.md, "A session takes the console"): each
%% grant of a files service to the grantee is installed or failed, or has no operation
%% while its server is not starting. data is a files service here.
files_sessions() -> erx_domain_mints:new((config([{template, 0}]))#{files => [data]}).

in_place(Starting, State) -> erx_domain_mints:in_place({session, 9}, Starting, State).

namespace_waits_for_its_files_grants_test() ->
    {_, Idle} = run([{session_ready, 0, 9, none}], files_sessions()),
    %% No operation: the session waits while its server is starting, and not once it
    %% has ended or never started, when /data answers I/O error.
    ?assertNot(in_place([?S], Idle)),
    ?assert(in_place([], Idle)),
    {_, Minting} = run([ready(?S, 5, #{data => mint(5)}), {introduced, 1, ok}], Idle),
    ?assertNot(in_place([], Minting)),
    {_, Installed} = run([{minted, 5, 1, {ok, facet(5)}}, {installed, 9, 1}], Minting),
    ?assert(in_place([], Installed)),
    {_, Failed} = run([{deadline, 1}], Minting),
    ?assert(in_place([], Failed)),
    {_, Ended} = run([{ended, ?S, 5}], Minting),
    ?assert(in_place([], Ended)),
    ?assertNot(in_place([?S], Ended)),
    %% A ready server that does not provide the name gives the grant no operation to wait for.
    {_, Unprovided} = run([ready(?S, 5, #{})], Idle),
    ?assert(in_place([], Unprovided)).

namespace_waits_for_no_other_grant_test() ->
    {_, Minting} = run([ready(?S, 5, #{data => mint(5)}), {session_ready, 0, 9, none}, {introduced, 1, ok}], sessions()),
    ?assert(in_place([?S], Minting)),
    ?assert(erx_domain_mints:in_place({session, 10}, [?S], Minting)),
    ?assert(erx_domain_mints:in_place({session, 10}, [?S], files_sessions())).

session_before_its_server_waits_test() ->
    {Actions, State} = run([{session_ready, 0, 9, none}, ready(?S, 5, #{data => mint(5)})], sessions()),
    ?assertEqual([[], [{arm, 1, 10000}, {introduce, 1, 5, 9}]], Actions),
    ?assertEqual(#{{{session, 9}, data} => {introducing, {5, 9}, 1}}, session_grants(State)).

session_end_cancels_and_drops_its_late_replies_test() ->
    {Actions, State} = run([{session_ended, 9}, {minted, 5, 1, {ok, facet(5)}}, {installed, 9, 1}],
                           session_minting()),
    ?assertEqual([[{disarm, 1}], [{dropped, unknown_tag, {minted, 5}}], [{dropped, unknown_tag, {installed, 9}}]],
                 Actions),
    ?assertEqual(#{}, session_grants(State)).

two_sessions_get_two_grants_test() ->
    {Actions, State} = run([{session_ready, 0, 10, none}, {introduced, 2, ok}, {minted, 5, 1, {ok, facet(5)}},
                            {minted, 5, 2, {ok, facet(5)}}, {installed, 10, 1}, {installed, 9, 2},
                            {installed, 9, 1}, {installed, 10, 2}], session_minting()),
    ?assertEqual([[{arm, 2, 10000}, {introduce, 2, 5, 10}],
                  [{mint, 2, mint(5), data, 10, ?LIMITS}],
                  [{install, 1, 9, data, facet(5)}],
                  [{install, 2, 10, data, facet(5)}],
                  [{dropped, wrong_domain, {installed, 10}}],
                  [{dropped, wrong_domain, {installed, 9}}],
                  [{disarm, 1}],
                  [{disarm, 2}]], Actions),
    ?assertEqual(#{{{session, 9}, data} => {installed, {5, 9}, facet(5)},
                   {{session, 10}, data} => {installed, {5, 10}, facet(5)}}, session_grants(State)).

one_session_ending_leaves_the_other_its_grant_test() ->
    {Actions, State} = run([{session_ended, 9}, {deadline, 2}], two_sessions_installed()),
    ?assertEqual([[], []], Actions),
    ?assertEqual(#{{{session, 10}, data} => {installed, {5, 10}, facet(5)}}, session_grants(State)).

server_restart_regrants_every_live_session_test() ->
    {Actions, State} = run([{ended, ?S, 5}, ready(?S, 8, #{data => mint(8)})], two_sessions_installed()),
    ?assertEqual([[], [{arm, 3, 10000}, {introduce, 3, 8, 9}, {arm, 4, 10000}, {introduce, 4, 8, 10}]], Actions),
    ?assertEqual(#{{{session, 9}, data} => {introducing, {8, 9}, 3},
                   {{session, 10}, data} => {introducing, {8, 10}, 4}}, session_grants(State)).

second_report_of_a_live_session_is_refused_test() ->
    {Actions, State} = run([{session_ready, 0, 9, none}, {session_ended, 77}], session_minting()),
    ?assertEqual([[{refused, stale_report, {session, 9}}], []], Actions),
    ?assertEqual(#{{{session, 9}, data} => {minting, {5, 9}, 1}}, session_grants(State)).

session_of_a_template_without_grants_holds_nothing_test() ->
    {Actions, State} = run([{session_ready, 1, 11, none}, {session_ended, 11}], session_minting()),
    ?assertEqual([[], []], Actions),
    ?assertEqual(#{{{session, 9}, data} => {minting, {5, 9}, 1}}, session_grants(State)).

%% Each ended session leaves nothing behind: the core is the same size after many as
%% after one.
repeated_sessions_leave_no_entry_test() ->
    {_, Ready} = run([ready(?S, 5, #{data => mint(5)})], sessions()),
    Cycle = fun(Id, State) ->
                    {[_, [{arm, Tag, _}, _] | _], Next} =
                        run([{session_ended, Id - 1}, {session_ready, 0, Id, none}], State),
                    {_, Done} = run([{introduced, Tag, ok}, {minted, 5, Tag, {ok, facet(5)}}, {installed, Id, Tag}], Next),
                    Done
            end,
    One = Cycle(1000, Ready),
    Many = lists:foldl(Cycle, One, lists:seq(1001, 1100)),
    ?assertEqual(#{{{session, 1100}, data} => {installed, {5, 1100}, facet(5)}}, session_grants(Many)),
    ?assertEqual(erts_debug:flat_size(One), erts_debug:flat_size(Many)).

%% The session mark (docs/design-system.md, "Facets a configured domain serves"): template
%% 0's sessions are granted data and other, and row G data, its row's limits naming
%% session, which no facet row may set.
marked() ->
    erx_domain_mints:new(#{services => [{?S, data}, {?T, other}],
                           grants => [{{template, 0}, data, ?S, ?LIMITS}, {{template, 0}, other, ?T, ?LIMITS},
                                      {?G, data, ?S, ?MARKED_LIMITS}],
                           owner => fun ?MODULE:owner/1, deadline => 10000}).

%% The limits of every mint the core asks for once Events are stepped and each
%% introduction they start succeeds, by grantee id and name; and the last state.
minted_limits(Events, State) ->
    {Actions, Stepped} = run(Events, State),
    {More, Last} = run([{introduced, Tag, ok} || {introduce, Tag, _, _} <- lists:append(Actions)], Stepped),
    {#{{GranteeId, Name} => Limits || {mint, _, _, Name, GranteeId, Limits} <- lists:append(Actions ++ More)}, Last}.

session_mark_test() ->
    %% Session 9 is data's display session; session 10 and session 11, which names a
    %% display its template is not granted, are not, and row G's limits lose session.
    {First, Minting} = minted_limits([ready(?S, 5, #{data => mint(5)}), ready(?T, 6, #{other => mint(6)}),
                                      ready(?G, 7, #{}), {session_ready, 0, 9, {display, data}},
                                      {session_ready, 0, 10, none}, {session_ready, 0, 11, {display, log}}],
                                     marked()),
    ?assertEqual(#{{7, data} => ?LIMITS,
                   {9, data} => ?MARKED_LIMITS, {9, other} => ?LIMITS,
                   {10, data} => ?LIMITS, {10, other} => ?LIMITS,
                   {11, data} => ?LIMITS, {11, other} => ?LIMITS}, First),
    %% Data's server restarts: its new incarnation mints session 9's grant with the mark again.
    {Again, _} = minted_limits([{ended, ?S, 5}, ready(?S, 8, #{data => mint(8)})], Minting),
    ?assertEqual(#{{7, data} => ?LIMITS, {9, data} => ?MARKED_LIMITS,
                   {10, data} => ?LIMITS, {11, data} => ?LIMITS}, Again).

granted_names_the_templates_grants_test() ->
    ?assert(erx_domain_mints:granted(0, data, marked())),
    ?assert(erx_domain_mints:granted(0, other, marked())),
    ?assertNot(erx_domain_mints:granted(0, log, marked())),
    ?assertNot(erx_domain_mints:granted(1, data, marked())),
    ?assertNot(erx_domain_mints:granted(0, "data", marked())).

invalid_template_grants_are_refused_test() ->
    Owner = fun ?MODULE:owner/1,
    Bad = [#{services => [{?S, data}], grants => [{{template, 0}, other, ?S, #{}}], owner => Owner},
           #{services => [{?S, data}], grants => [{{template, 0}, data, ?S, #{}}, {{template, 0}, data, ?S, #{}}],
             owner => Owner},
           #{services => [{?S, data}], grants => [{{template, 0}, data, ?S, none}], owner => Owner}],
    [?assertError(badarg, erx_domain_mints:new(Config)) || Config <- Bad].

%% Exhaustive exploration.

explore_row_grantee_test_() ->
    {timeout, 300, fun() -> explore_and_report([?G], 2, 0) end}.

explore_two_grants_test_() ->
    {timeout, 300, fun() -> explore_and_report([?G, system], 1, 0) end}.

explore_session_regrant_test_() ->
    {timeout, 300, fun() -> explore_and_report([{template, 0}], 2, 1) end}.

explore_two_sessions_test_() ->
    {timeout, 300, fun() -> explore_and_report([{template, 0}], 1, 2) end}.

explore_and_report(Grantees, Incarnations, Sessions) ->
    {States, Transitions} = explore(Grantees, Incarnations, Sessions),
    io:format(user, "~nerx_domain_mints, grantees ~p: ~b states, ~b transitions~n", [Grantees, States, Transitions]).

%% The model's state: per row its incarnations started and its live one, as
%% {running | reported | ready, Id, Honest}; the next domain id; the messages
%% in flight to the core; the requests the core made of a party; the armed
%% deadlines; the tags whose introduction succeeded; the installs sent, as
%% {Tag, GranteeId}; the highest tag issued; the hostile act and the duplicate
%% left; whether the run is honest; and each session started, running or
%% ready by its id, and how many more may start.
initial(Grantees, Incarnations, Sessions) ->
    Rows = maps:from_list([{?S, {0, none}}, {?T, {1, {running, 50, true}}}] ++
                              [{?G, {0, none}} || lists:member(?G, Grantees)]),
    #{rows => Rows, incarnations => Incarnations, next_id => 5, msgs => [], reqs => [], armed => [],
      introduced => [], installs => [], tags => 0, hostile => 1, dup => 1, honest => true,
      sessions => #{}, session_starts => Sessions}.

explore(Grantees, Incarnations, Sessions) ->
    Start = {erx_domain_mints:new(config(Grantees)), initial(Grantees, Incarnations, Sessions)},
    bfs(queue:from_list([Start]), #{Start => root}, 0).

bfs(Queue, Seen, Transitions) ->
    case queue:out(Queue) of
        {empty, _} ->
            {map_size(Seen), Transitions};
        {{value, {Core, Env} = Node}, Rest} ->
            check_state(Core, Env, Node, Seen),
            Next = [{Label, step(Event, Core, Env1, Node, Label, Seen)}
                    || {Label, Event, Env1} <- moves(Env)],
            {Queue1, Seen1} = lists:foldl(fun({Label, Child}, {Q, S}) ->
                                                  case S of
                                                      #{Child := _} -> {Q, S};
                                                      #{} -> {queue:in(Child, Q), S#{Child => {Node, Label}}}
                                                  end
                                          end, {Rest, Seen}, Next),
            bfs(Queue1, Seen1, Transitions + length(Next))
    end.

%% The core's step, then its actions applied to the model, each checked as it goes.
step(none, Core, Env, _Node, _Label, _Seen) ->
    {Core, Env};
step(Event, Core, Env, Node, Label, Seen) ->
    {Actions, Core1} = erx_domain_mints:step(Event, Core),
    check_acknowledged(Event, Core, Core1, Env, Node, Label, Seen),
    Env1 = lists:foldl(fun(Action, E) -> apply_action(Action, E, Node, Label, Seen) end, Env, Actions),
    {Core1, Env1}.

%% A grant that became installed did so on its grantee's acknowledgement of its install.
check_acknowledged(Event, Before, After, #{installs := Installs}, Node, Label, Seen) ->
    Old = erx_domain_mints:grants(Before),
    lists:foreach(fun({Key, {installed, {_, GranteeId}, _} = Grant}) when Grant =/= map_get(Key, Old) ->
                          case Event of
                              {installed, GranteeId, Tag} ->
                                  {installing, _, Tag, _} = map_get(Key, Old),
                                  lists:member({Tag, GranteeId}, Installs)
                                      orelse violation(acknowledged, Node, Label, Seen);
                              _ ->
                                  violation(acknowledged, Node, Label, Seen)
                          end;
                     (_) ->
                          ok
                  end, maps:to_list(erx_domain_mints:grants(After))).

apply_action({arm, Tag, _}, #{armed := Armed, tags := Tags} = Env, Node, Label, Seen) ->
    Tag > Tags orelse violation(fresh_tag, Node, Label, Seen),
    Env#{armed := lists:sort([Tag | Armed]), tags := Tag};
apply_action({disarm, Tag}, #{armed := Armed} = Env, Node, Label, Seen) ->
    lists:member(Tag, Armed) orelse violation(one_timer, Node, Label, Seen),
    Env#{armed := Armed -- [Tag]};
apply_action({introduce, Tag, ServerId, GranteeId}, #{reqs := Reqs} = Env, Node, Label, Seen) ->
    (ready_id(?S, Env) =:= ServerId andalso GranteeId =/= 4 andalso is_grantee(GranteeId, Env))
        orelse violation(current_pair, Node, Label, Seen),
    Env#{reqs := lists:sort([{introduce, Tag} | Reqs])};
apply_action({mint, Tag, Mint, data, GranteeId, Limits}, #{reqs := Reqs} = Env, Node, Label, Seen) ->
    ServerId = ready_id(?S, Env),
    (Mint =:= mint(ServerId) andalso honest_report(?S, Env) andalso is_grantee(GranteeId, Env))
        orelse violation(authentic_mint, Node, Label, Seen),
    Limits =:= session_limits(GranteeId, Env) orelse violation(session_mark, Node, Label, Seen),
    Env#{reqs := lists:sort([{mint, Tag, ServerId} | Reqs])};
apply_action({install, Tag, GranteeId, data, Facet}, #{reqs := Reqs, introduced := Introduced, installs := Installs} = Env,
             Node, Label, Seen) ->
    (is_grantee(GranteeId, Env) andalso Facet =:= facet(ready_id(?S, Env))
     andalso (GranteeId =:= 4 orelse lists:member(Tag, Introduced)))
        orelse violation(authentic_install, Node, Label, Seen),
    Env#{reqs := lists:sort([{install, Tag, GranteeId} | Reqs]), installs := [{Tag, GranteeId} | Installs]};
apply_action({Log, _Reason, _Detail}, Env, _Node, _Label, _Seen) when Log =:= refused; Log =:= dropped ->
    Env;
apply_action({failed, _Key, _Pair, _Reason}, Env, _Node, _Label, _Seen) ->
    Env;
apply_action(Action, _Env, Node, Label, Seen) ->
    violation({unknown_action, Action}, Node, Label, Seen).

check_state(Core, Env, Node, Seen) ->
    Grants = erx_domain_mints:grants(Core),
    check_one_timer(Grants, Env, Node, Seen),
    check_current_pair(Grants, Env, Node, Seen),
    check_session_entries(Grants, Env, Node, Seen),
    check_honest_progress(Grants, Env, Node, Seen).

check_one_timer(Grants, #{armed := Armed}, Node, Seen) ->
    Pending = lists:sort([Tag || {Step, _, Tag} <- maps:values(Grants), Step =/= installed, Step =/= failed] ++
                         [Tag || {installing, _, Tag, _} <- maps:values(Grants)]),
    Pending =:= Armed orelse violation(one_timer, Node, state, Seen).

check_current_pair(Grants, Env, Node, Seen) ->
    maps:foreach(fun(_Key, idle) -> ok;
                    (Key, {installed, Pair, Facet}) ->
                         (Pair =:= current_pair(Key, Env) andalso Facet =:= facet(element(1, Pair)))
                             orelse violation(current_pair, Node, state, Seen);
                    (Key, Grant) ->
                         element(2, Grant) =:= current_pair(Key, Env) orelse violation(current_pair, Node, state, Seen)
                 end, Grants).

check_session_entries(Grants, #{sessions := Sessions}, Node, Seen) ->
    Held = lists:sort([Id || {{session, Id}, data} := _ <- Grants]),
    Held =:= lists:sort([Id || Id := ready <- Sessions]) orelse violation(session_entries, Node, state, Seen).

check_honest_progress(Grants, #{msgs := Msgs, reqs := Reqs, honest := Honest} = Env, Node, Seen) ->
    Stuck = [Key || Key := Grant <- Grants, element(1, Grant) =/= installed,
                    honest_report(?S, Env), element(2, current_pair(Key, Env)) =/= none],
    (Honest andalso Msgs =:= [] andalso Reqs =:= [] andalso Stuck =/= [])
        andalso violation(honest_progress, Node, state, Seen).

%% The pair the model says grant Key should carry.
current_pair({system, data}, Env) -> {ready_id(?S, Env), 4};
current_pair({?G, data}, Env) -> {ready_id(?S, Env), ready_id(?G, Env)};
current_pair({{session, Id}, data}, Env) -> {ready_id(?S, Env), ready_session(Id, Env)}.

%% A session with an odd id is its display's session: its report marks data.
mark(Id) when Id rem 2 =:= 1 -> {display, data};
mark(_Id) -> none.

%% The limits a mint for GranteeId must carry: the row's, with session => true for a
%% session whose report marked data.
session_limits(GranteeId, #{sessions := Sessions}) ->
    case is_map_key(GranteeId, Sessions) andalso mark(GranteeId) =/= none of
        true -> ?MARKED_LIMITS;
        false -> ?LIMITS
    end.

is_grantee(4, _Env) -> true;
is_grantee(Id, Env) -> Id =:= ready_id(?G, Env) orelse Id =:= ready_session(Id, Env).

ready_session(Id, #{sessions := Sessions}) ->
    case Sessions of
        #{Id := ready} -> Id;
        #{} -> none
    end.

%% Every move the model allows from Env: {Label, Event | none, Env1}.
moves(Env) ->
    lists:append([row_moves(Env), session_moves(Env), message_moves(Env), request_moves(Env), deadline_moves(Env), third_moves(Env)]).

row_moves(#{rows := Rows} = Env) ->
    lists:append([row_moves(Row, Live, Env) || Row := Live <- Rows]).

row_moves(Row, {Started, none}, #{next_id := Id, incarnations := Most} = Env) ->
    [{{start, Row, Id}, none, set_row(Row, {Started + 1, {running, Id, true}}, Env#{next_id := Id + 1})}
     || Started < Most];
row_moves(Row, {Started, {running, Id, _}}, Env) ->
    [{{report, Row, Id, Kind}, none,
      spend(Kind, set_row(Row, {Started, {reported, Id, Kind =:= honest}},
                          send(ready(Row, Id, provides(Row, Id, Kind)), Env)))}
     || Kind <- report_kinds(Row, Env)] ++ end_move(Row, Started, Id, Env);
row_moves(Row, {Started, {_Phase, Id, _}}, Env) ->
    end_move(Row, Started, Id, Env).

end_move(?T, _Started, _Id, _Env) ->
    [];
end_move(Row, Started, Id, #{reqs := Reqs} = Env) ->
    %% A dead party answers nothing: its requests go.
    Live = [Req || Req <- Reqs, party(Req) =/= Id],
    [{{'end', Row, Id}, {ended, Row, Id}, set_row(Row, {Started, none}, Env#{reqs := Live})}].

report_kinds(?S, #{hostile := 1}) -> [honest, third_mint, forged_mint];
report_kinds(_Row, _Env) -> [honest].

provides(?S, Id, honest) -> #{data => mint(Id)};
provides(?S, _Id, third_mint) -> #{data => mint(?THIRD)};
provides(?S, Id, forged_mint) -> #{data => pid(node_of(?THIRD), Id, 1)};
provides(?G, _Id, honest) -> #{};
provides(?T, Id, honest) -> #{data => mint(Id)}.

%% A session started with the next id while starts are left; a running session
%% reporting ready, which the core hears at once; any session ending, its requests
%% gone with it.
session_moves(#{sessions := Sessions, session_starts := Left, next_id := Id, reqs := Reqs} = Env) ->
    [{{session_start, Id}, none, Env#{sessions := Sessions#{Id => running}, session_starts := Left - 1, next_id := Id + 1}}
     || Left > 0] ++
    [{{session_report, S}, {session_ready, 0, S, mark(S)}, Env#{sessions := Sessions#{S := ready}}} || S := running <- Sessions] ++
    [{{session_end, S}, {session_ended, S},
      Env#{sessions := maps:remove(S, Sessions), reqs := [Req || Req <- Reqs, party(Req) =/= S]}}
     || S := _ <- Sessions].

%% Each message in flight delivered, once, or once and kept for a duplicate.
message_moves(#{msgs := Msgs, dup := Dup} = Env) ->
    lists:append([deliver(Msg, Env#{msgs := Msgs -- [Msg]}) ++
                      [{{duplicate, Msg}, Msg, Env#{dup := 0}} || Dup =:= 1, element(1, Msg) =/= ready]
                  || Msg <- lists:usort(Msgs)]).

deliver({ready, Row, Id, _, _} = Msg, #{rows := Rows} = Env) ->
    Delivered = case maps:get(Row, Rows) of
                    {Started, {reported, Id, Honest}} -> set_row(Row, {Started, {ready, Id, Honest}}, Env);
                    _Stale -> Env
                end,
    [{{deliver, Msg}, Msg, Delivered}];
deliver(Msg, Env) ->
    [{{deliver, Msg}, Msg, Env}].

request_moves(#{reqs := Reqs} = Env) ->
    lists:append([answers(Req, Env#{reqs := Reqs -- [Req]}) || Req <- lists:usort(Reqs)]).

answers({introduce, Tag}, #{introduced := Introduced} = Env) ->
    [{{introduced, Tag}, {introduced, Tag, ok}, Env#{introduced := lists:sort([Tag | Introduced])}} |
     [{{introduce_refused, Tag}, {introduced, Tag, {error, elimit}}, spend(hostile, Env)} || hostile(Env)]];
answers({mint, Tag, ServerId}, Env) ->
    Replies = [{honest, {ok, facet(ServerId)}}] ++
        [{Kind, Reply} || hostile(Env), {Kind, Reply} <- [{third_facet, {ok, facet(?THIRD)}},
                                                          {forged_facet, {ok, forged(ServerId)}},
                                                          {refused, {error, enospc}}]],
    [{{answer, Tag, Kind}, none, spend(Kind, send({minted, ServerId, Tag, Reply}, Env))} || {Kind, Reply} <- Replies];
answers({install, Tag, GranteeId}, Env) ->
    [{{acknowledge, Tag}, none, send({installed, GranteeId, Tag}, Env)}].

deadline_moves(#{armed := Armed} = Env) ->
    [{{deadline, Tag}, {deadline, Tag}, Env#{armed := Armed -- [Tag], honest := false}} || Tag <- Armed].

%% Any domain the model started, or 99, answers any tag issued so far, as a mint
%% with a facet of its own or as a grantee.
third_moves(#{tags := Tags, next_id := NextId} = Env) ->
    [{{third, Event}, Event, spend(hostile, Env)}
     || hostile(Env), Domain <- [?THIRD, 50 | lists:seq(5, NextId - 1)], Tag <- lists:seq(1, Tags),
        Event <- [{minted, Domain, Tag, {ok, facet(Domain)}}, {installed, Domain, Tag}]].

hostile(#{hostile := Left}) -> Left =:= 1.

spend(honest, Env) -> Env;
spend(_Hostile, Env) -> Env#{hostile := 0, honest := false}.

send(Msg, #{msgs := Msgs} = Env) -> Env#{msgs := lists:sort([Msg | Msgs])}.

set_row(Row, Live, #{rows := Rows} = Env) -> Env#{rows := Rows#{Row := Live}}.

party({introduce, _Tag}) -> none;
party({mint, _Tag, ServerId}) -> ServerId;
party({install, _Tag, GranteeId}) -> GranteeId.

ready_id(Row, #{rows := Rows}) ->
    case maps:get(Row, Rows, {0, none}) of
        {_, {ready, Id, _}} -> Id;
        _ -> none
    end.

honest_report(Row, #{rows := Rows}) ->
    case maps:get(Row, Rows) of
        {_, {ready, _, Honest}} -> Honest;
        _ -> false
    end.

%% The violated property and the moves that led to it, from the start.
violation(Property, Node, Label, Seen) ->
    error({Property, lists:reverse([Label | trace(Node, Seen)])}).

trace(Node, Seen) ->
    case maps:get(Node, Seen) of
        root -> [];
        {Parent, Label} -> [Label | trace(Parent, Seen)]
    end.
