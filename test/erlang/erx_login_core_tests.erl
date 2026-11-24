%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The login service's core against docs/design-login.md's table, "A row's states",
%% exhaustively: every state a row can be in, against every event, gives the next
%% state, the effects by kind and the answer the table names. Then the cases the
%% table's rows imply beyond one step: the bound, a cookie's retirement, late answers.
-module(erx_login_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FROM, from).
-define(COOKIE, <<"cookie-16-bytes!">>).

owner() -> list_to_pid("<0.4001.0>").
other() -> list_to_pid("<0.4002.0>").
facet() -> list_to_pid("<0.4100.0>").
other_facet() -> list_to_pid("<0.4101.0>").

grant() -> grant(facet(), 2).
grant(Facet, Logins) ->
    #{facet => Facet, grantee => 7, line => tty_line, logins => Logins, holder => <<"ssh">>}.

req(Request) -> {request, owner(), grant(), ?FROM, Request}.

-define(PASS, {login_passphrase, <<"alice">>, <<"secret">>, <<"peer">>}).
-define(KEY(Verdict), {login_key, <<"alice">>, <<"blob">>, Verdict}).

%% Each state the table names, reached by the core's own steps from an empty table.
states() ->
    [none, cookie, checking_from_none, checking_from_cookie, passphrase_from_cookie, starting, minting, logged_in].

reach(State) ->
    lists:foldl(fun(Event, T) -> element(1, erx_login_core:step(Event, T)) end,
                erx_login_core:new(), path(State)).

path(none) -> [];
path(cookie) -> [req({cookie, {ok, ?COOKIE}})];
path(checking_from_none) -> [req(?PASS)];
path(checking_from_cookie) -> path(cookie) ++ [req(?KEY(verified))];
path(passphrase_from_cookie) -> path(cookie) ++ [req(?PASS)];
%% Step ids are the table's counter: cookie's grace is 0, the check 1, the start 2,
%% the mint 3 along the key path.
path(starting) -> path(checking_from_cookie) ++ [{answer, {step, 1}, {found, 42}}];
path(minting) -> path(starting) ++ [{answer, {step, 2}, {ok, session}}];
path(logged_in) -> path(minting) ++ [{answer, {step, 3}, {ok, line}}].

%% The step id outstanding in each pending state, and the grace of a cookie row.
outstanding(checking_from_none) -> {step, 0};
outstanding(checking_from_cookie) -> {step, 1};
outstanding(passphrase_from_cookie) -> {step, 1};
outstanding(starting) -> {step, 2};
outstanding(minting) -> {step, 3};
outstanding(_State) -> none.

requests() ->
    [{cookie, {ok, ?COOKIE}}, {cookie, error}, {key_ok, <<"alice">>, <<"blob">>},
     ?KEY(verified), ?KEY(not_verified), ?PASS].

%% The design's table for a request: {next state of the owner's row, effect kinds, answer}.
expected_request(S, _Request) when S =:= checking_from_none; S =:= checking_from_cookie; S =:= passphrase_from_cookie;
                                   S =:= starting; S =:= minting ->
    {pending, [reply], {error, badarg}};
expected_request(logged_in, _Request) -> {logged_in, [reply], {error, badarg}};
expected_request(none, {cookie, {ok, _}}) -> {cookie, [monitor, arm_grace, reply], {ok, ?COOKIE}};
expected_request(cookie, {cookie, {ok, _}}) -> {cookie, [arm_grace, reply], {ok, ?COOKIE}};
expected_request(none, {cookie, error}) -> {none, [reply], {error, unavailable}};
expected_request(cookie, {cookie, error}) -> {cookie, [reply], {error, unavailable}};
expected_request(S, {key_ok, _, _}) -> {S, [key_ok], none};
expected_request(none, {login_key, _, _, _}) -> {none, [reply], {error, no_match}};
expected_request(cookie, {login_key, _, _, not_verified}) -> {cookie, [reply], {error, no_match}};
expected_request(cookie, {login_key, _, _, verified}) -> {pending, [find_key], none};
expected_request(none, {login_passphrase, _, _, _}) -> {pending, [monitor, check], none};
expected_request(cookie, {login_passphrase, _, _, _}) -> {pending, [check], none}.

the_table_holds_for_every_state_and_request_test_() ->
    [{lists:flatten(io_lib:format("~p x ~p", [S, element(1, R)])),
      fun() -> ?assertEqual(expected_request(S, R), observed(erx_login_core:step(req(R), reach(S))))
      end} || S <- states(), R <- requests()].

%% The design's table for the answer of the outstanding step: {state, effects, answer}.
answers(checking_from_none) ->
    [{{match, 42}, {pending, [start], none}},
     {no_match, {none, [demonitor, reply], {error, no_match}}},
     {limited, {none, [demonitor, reply], {error, limited}}},
     {unavailable, {none, [demonitor, reply], {error, unavailable}}}];
answers(checking_from_cookie) ->
    [{{found, 42}, {pending, [start], none}},
     {not_found, {cookie, [reply], {error, no_match}}},
     {unavailable, {cookie, [reply], {error, unavailable}}}];
%% A passphrase login from a cookie row returns to the cookie on every failure.
answers(passphrase_from_cookie) ->
    [{{match, 42}, {pending, [start], none}},
     {no_match, {cookie, [reply], {error, no_match}}},
     {limited, {cookie, [reply], {error, limited}}},
     {unavailable, {cookie, [reply], {error, unavailable}}}];
answers(starting) ->
    [{{ok, session}, {pending, [mint], none}},
     {{error, quota}, {none, [log, demonitor, reply], {error, unavailable}}}];
answers(minting) ->
    [{{ok, line}, {logged_in, [reply], {ok, line}}},
     {{error, no_line}, {none, [log, stop, demonitor, reply], {error, unavailable}}}];
answers(_State) -> [].

every_pending_step_answers_as_the_table_says_test_() ->
    [{lists:flatten(io_lib:format("~p answered ~p", [S, A])),
      fun() -> ?assertEqual(E, observed(erx_login_core:step({answer, outstanding(S), A}, reach(S)))) end}
     || S <- states(), {A, E} <- answers(S)].

late_answers_and_graces_change_nothing_test_() ->
    [{atom_to_list(S),
      fun() ->
              T = reach(S),
              ?assertEqual({T, []}, erx_login_core:step({answer, {step, 99}, {match, 42}}, T)),
              ?assertEqual({T, []}, erx_login_core:step({grace, {step, 99}}, T)),
              ?assertEqual({T, []}, erx_login_core:step({down, other()}, T))
      end} || S <- states()].

the_owner_s_end_frees_every_row_test_() ->
    [{atom_to_list(S),
      fun() ->
              {T, Effects} = erx_login_core:step({down, owner()}, reach(S)),
?assertEqual(case outstanding(S) of
                 {step, _} -> [{reply, ?FROM, {error, unavailable}}];
                 none -> []
             end, Effects),
              ?assertEqual(#{}, erx_login_core:rows(T)),
              ?assertEqual(0, erx_login_core:count(facet(), T))
      end} || S <- states()].

a_cookie_s_grace_frees_its_row_test() ->
    {T, Effects} = erx_login_core:step({grace, {step, 0}}, reach(cookie)),
    ?assertEqual(#{}, erx_login_core:rows(T)),
    ?assertEqual([{demonitor, owner()}], Effects).

a_grace_while_pending_returns_the_row_to_none_test() ->
    {T, []} = erx_login_core:step({grace, {step, 0}}, reach(checking_from_cookie)),
    {T1, Effects} = erx_login_core:step({answer, {step, 1}, not_found}, T),
    ?assertEqual(#{}, erx_login_core:rows(T1)),
    ?assertEqual([{demonitor, owner()}, {reply, ?FROM, {error, no_match}}], Effects).

a_replaced_cookie_s_grace_is_dropped_test() ->
    {T, _} = erx_login_core:step(req({cookie, {ok, <<"second">>}}), reach(cookie)),
    ?assertEqual({T, []}, erx_login_core:step({grace, {step, 0}}, T)),
    {T1, _} = erx_login_core:step({grace, {step, 1}}, T),
    ?assertEqual(#{}, erx_login_core:rows(T1)).

%% Once a key matches, the row keeps no cookie: the cookie's grace no longer names it, the
%% start's failure frees the row rather than returning to the cookie, and the old cookie
%% then logs no one in.
a_key_match_retires_the_cookie_test() ->
    T = reach(starting),
    ?assertEqual({T, []}, erx_login_core:step({grace, {step, 0}}, T)),
    {T1, Effects} = erx_login_core:step({answer, {step, 2}, {error, quota}}, T),
    ?assertEqual(#{}, erx_login_core:rows(T1)),
    ?assertEqual([log, demonitor, reply], [element(1, E) || E <- Effects]),
    ?assertMatch({_, [{reply, ?FROM, {error, no_match}}]}, erx_login_core:step(req(?KEY(verified)), T1)).

%% The cookie's grace, step 0 on every path through a cookie, against every state: it
%% frees a cookie row, drops a pending row's way back to its cookie, and changes nothing
%% else.
the_cookie_s_grace_against_every_state_test_() ->
    [{atom_to_list(S),
      fun() ->
              T = reach(S),
              {T1, Effects} = erx_login_core:step({grace, {step, 0}}, T),
              case S of
                  cookie ->
                      ?assertEqual({#{}, [{demonitor, owner()}]}, {erx_login_core:rows(T1), Effects});
                  _ when S =:= checking_from_cookie; S =:= passphrase_from_cookie ->
                      ?assertEqual({erx_login_core:rows(T), []}, {erx_login_core:rows(T1), Effects}),
                      {T2, _} = erx_login_core:step({answer, outstanding(S), no_match}, T1),
                      ?assertEqual(#{}, erx_login_core:rows(T2));
                  _ ->
                      ?assertEqual({T, []}, {T1, Effects})
              end
      end} || S <- states()].

%% A step id is never reused: the answer of a check that failed back to its cookie is
%% dropped once the row has a later check outstanding.
a_late_answer_to_a_finished_step_is_dropped_test() ->
    {T, _} = erx_login_core:step({answer, {step, 1}, not_found}, reach(checking_from_cookie)),
    {T1, [{find_key, {step, 2}, _, _}]} = erx_login_core:step(req(?KEY(verified)), T),
    ?assertEqual({T1, []}, erx_login_core:step({answer, {step, 1}, {found, 42}}, T1)).

a_passphrase_check_names_the_grant_s_terminal_test() ->
    {_T, [{monitor, _}, {check, _Step, <<"alice">>, <<"secret">>, network, Terminal}]} =
        erx_login_core:step(req(?PASS), erx_login_core:new()),
    ?assertEqual({<<"ssh">>, <<"peer">>}, Terminal).

the_start_ends_with_the_owner_and_the_facet_test() ->
    {_T, [{start, _Step, 42, Start}]} = erx_login_core:step({answer, {step, 1}, {found, 42}}, reach(checking_from_cookie)),
    ?assertEqual(#{ends_with => [owner(), facet()]}, Start),
    Web = (grant())#{line => web_line},
    {T1, _} = erx_login_core:step({request, owner(), Web, ?FROM, ?PASS}, erx_login_core:new()),
    {_T2, [{start, _, 42, WebStart}]} = erx_login_core:step({answer, {step, 0}, {match, 42}}, T1),
    ?assertEqual(#{ends_with => [owner(), facet()], display => web}, WebStart).

the_mint_names_the_grant_s_line_and_grantee_test() ->
    {_T, [{mint, _Step, tty_line, session, 7, Facet}]} =
        erx_login_core:step({answer, {step, 2}, {ok, session}}, reach(starting)),
    ?assertEqual(facet(), Facet).

the_logins_th_row_is_taken_and_the_next_refused_test() ->
    Grant = grant(facet(), 2),
    Owners = [list_to_pid("<0.5000.0>"), list_to_pid("<0.5001.0>"), list_to_pid("<0.5002.0>")],
    Cookie = fun(Owner, T) -> erx_login_core:step({request, Owner, Grant, ?FROM, {cookie, {ok, ?COOKIE}}}, T) end,
    [A, B, C] = Owners,
    {T1, _} = Cookie(A, erx_login_core:new()),
    {T2, E2} = Cookie(B, T1),
    ?assertMatch([{monitor, _}, {arm_grace, _}, {reply, ?FROM, {ok, _}}], E2),
    {T3, E3} = Cookie(C, T2),
    ?assertEqual([{reply, ?FROM, {error, unavailable}}], E3),
    {T4, E4} = erx_login_core:step({request, C, Grant, ?FROM, ?PASS}, T3),
    ?assertEqual([{reply, ?FROM, {error, unavailable}}], E4),
    {T5, []} = erx_login_core:step({down, A}, T4),
    {_T6, E6} = Cookie(C, T5),
    ?assertMatch([{monitor, _}, {arm_grace, _}, {reply, ?FROM, {ok, _}}], E6).

each_grant_s_bound_is_its_own_test() ->
    {T1, _} = erx_login_core:step({request, owner(), grant(facet(), 1), ?FROM, ?PASS}, erx_login_core:new()),
    {_T2, Effects} = erx_login_core:step({request, other(), grant(other_facet(), 1), ?FROM, ?PASS}, T1),
    ?assertMatch([{monitor, _}, {check, _, _, _, network, _}], Effects).

%% A row of one grant, in any state, answers every request through another grant badarg
%% and changes nothing.
a_request_through_another_grant_touches_no_row_test_() ->
    [{lists:flatten(io_lib:format("~p x ~p", [S, element(1, R)])),
      fun() ->
              T = reach(S),
              ?assertEqual({T, [{reply, ?FROM, {error, badarg}}]},
                           erx_login_core:step({request, owner(), grant(other_facet(), 2), ?FROM, R}, T))
      end} || S <- states(), S =/= none, R <- requests()].

%% The row's state, the kinds of the effects and the answer, if one went back.
observed({T, Effects}) ->
    State = maps:get(owner(), erx_login_core:rows(T), none),
    Answer = case [A || {reply, ?FROM, A} <- Effects] of
                 [A] -> A;
                 [] -> none
             end,
    {State, [element(1, E) || E <- Effects], Answer}.
