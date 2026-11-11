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
%% incarnations. Every step the model allows is taken from every reachable
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
           #{services => [{?T, data}], grants => [{?G, data, ?S, #{}}], owner => Owner}],
    [?assertError(badarg, erx_domain_mints:new(Config)) || Config <- Bad].

%% Exhaustive exploration.

explore_row_grantee_test_() ->
    {timeout, 300, fun() -> explore_and_report([?G], 2) end}.

explore_two_grants_test_() ->
    {timeout, 300, fun() -> explore_and_report([?G, system], 1) end}.

explore_and_report(Grantees, Incarnations) ->
    {States, Transitions} = explore(Grantees, Incarnations),
    io:format(user, "~nerx_domain_mints, grantees ~p: ~b states, ~b transitions~n", [Grantees, States, Transitions]).

%% The model's state: per row its incarnations started and its live one, as
%% {running | reported | ready, Id, Honest}; the next domain id; the messages
%% in flight to the core; the requests the core made of a party; the armed
%% deadlines; the tags whose introduction succeeded; the installs sent, as
%% {Tag, GranteeId}; the highest tag issued; the hostile act and the duplicate
%% left; and whether the run is honest.
initial(Grantees, Incarnations) ->
    Rows = maps:from_list([{?S, {0, none}}, {?T, {1, {running, 50, true}}}] ++
                              [{?G, {0, none}} || lists:member(?G, Grantees)]),
    #{rows => Rows, incarnations => Incarnations, next_id => 5, msgs => [], reqs => [], armed => [],
      introduced => [], installs => [], tags => 0, hostile => 1, dup => 1, honest => true}.

explore(Grantees, Incarnations) ->
    Start = {erx_domain_mints:new(config(Grantees)), initial(Grantees, Incarnations)},
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
    (ready_id(?S, Env) =:= ServerId andalso ready_id(?G, Env) =:= GranteeId)
        orelse violation(current_pair, Node, Label, Seen),
    Env#{reqs := lists:sort([{introduce, Tag} | Reqs])};
apply_action({mint, Tag, Mint, data, GranteeId, #{max_request := 4096}}, #{reqs := Reqs} = Env, Node, Label, Seen) ->
    ServerId = ready_id(?S, Env),
    (Mint =:= mint(ServerId) andalso honest_report(?S, Env) andalso is_grantee(GranteeId, Env))
        orelse violation(authentic_mint, Node, Label, Seen),
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

check_honest_progress(Grants, #{msgs := Msgs, reqs := Reqs, honest := Honest} = Env, Node, Seen) ->
    Stuck = [Key || Key := Grant <- Grants, element(1, Grant) =/= installed,
                    honest_report(?S, Env), element(2, current_pair(Key, Env)) =/= none],
    (Honest andalso Msgs =:= [] andalso Reqs =:= [] andalso Stuck =/= [])
        andalso violation(honest_progress, Node, state, Seen).

%% The pair the model says grant Key should carry.
current_pair({system, data}, Env) -> {ready_id(?S, Env), 4};
current_pair({?G, data}, Env) -> {ready_id(?S, Env), ready_id(?G, Env)}.

is_grantee(4, _Env) -> true;
is_grantee(Id, Env) -> Id =:= ready_id(?G, Env).

%% Every move the model allows from Env: {Label, Event | none, Env1}.
moves(Env) ->
    lists:append([row_moves(Env), message_moves(Env), request_moves(Env), deadline_moves(Env), third_moves(Env)]).

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
