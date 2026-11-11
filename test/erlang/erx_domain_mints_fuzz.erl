%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random sequences of events through erx_domain_mints, the domain service's pure core
%% for facets configured domains serve (docs/design-system.md, "Facets a configured
%% domain serves"), with two targets over the two untrusted inputs it reads:
%% * report: ready reports whose provides are any term a server could send: maps of
%%   declared, undeclared and malformed names to mints its incarnation owns, pids of
%%   another domain, pids with its creation and another domain's node, funs, {M, F, A},
%%   registered names and deep terms; maps larger than the row declares; no map at all;
%%   reports of stale incarnations and of a row that serves nothing;
%% * reply: mint replies and installation acknowledgements with the right and wrong
%%   tags (finished, never issued, not integers), from the server, the grantee and a
%%   third domain, naming facets the server owns, facets of a third domain and forged
%%   pids, or no {ok, Pid} at all; interleaved with ends, restarts and deadlines.
%% A shell here performs the core's actions as erx_domain_srv does: it arms and disarms
%% deadlines, answers an installation in the system domain at once, and feeds back
%% introductions, replies and deadlines later, in any order.
%%
%% Whatever arrives, the core never raises, and after every step:
%% * each grant's pair is the one an oracle computes from the reports so far: the
%%   server row's newest ready incarnation, if a mint it owns (node and creation) was
%%   accepted for the name, and the grantee's newest ready incarnation;
%% * a mint request goes only to the mint the oracle accepted for that incarnation;
%% * an installation names only a facet the pair's server owns, from that server's
%%   reply to the operation's tag, for the pair's grantee;
%% * every pending operation has exactly one armed deadline, a tag is armed once, and
%%   only an armed tag is disarmed;
%% * every refusal and drop carries only atoms and integers, at most three of them.
%% The seed comes from make check-fuzz.

-module(erx_domain_mints_fuzz).
-export([run/1, owner/1]).

-define(CORE, erx_domain_mints).
-define(SEQUENCES, 20000).
-define(STEPS, 40).
%% Rows: S serves data and log, T serves other, G is a grantee, U serves nothing.
-define(S, 0).
-define(G, 1).
-define(T, 2).
-define(U, 7).
-define(SYSTEM, 4).
-define(THIRD, 99).
-define(DECLARED, #{?S => [data, log], ?T => [other]}).
-define(GRANTS, [{?G, data, ?S}, {system, data, ?S}, {?G, other, ?T}, {system, log, ?S}]).

%% The shell's view of one sequence: the core; the oracle's rows, each {Id, ready, Node,
%% Accepted} or {Id, ended}; every id handed out, and by row; the tags armed now and ever; the
%% operations the shell owes an answer, by tag: introductions to feed back, mints asked
%% (server id, name) and installations sent (grantee id); and a tally of what happened.
-record(shell, {core, rows = #{}, next_id = 10, ids = [], row_ids = #{}, armed = #{}, ever = #{},
                intros = #{}, mints = #{}, installs = #{}, tally = #{}}).

run([Target, Seed]) ->
    rand:seed(exsss, {16#d0, 16#4a, list_to_integer(Seed)}),
    Kind = list_to_existing_atom(Target),
    true = lists:member(Kind, [report, reply]),
    Tally = lists:foldl(fun(_, T) -> sequence(Kind, T) end, #{}, lists:seq(1, ?SEQUENCES)),
    io:format("fuzz: ~p sequences ok~n", [?SEQUENCES]),
    [io:format("~p: ~p~n", [Key, N]) || Key := N <- maps:iterator(Tally, ordered)],
    ok.

%% erx:owner/1 as the system domain reads it: the pid's creation.
owner(Pid) ->
    <<131, 88, 119, Length, _Node:Length/binary, _Number:32, _Serial:32, Creation:32>> = term_to_binary(Pid),
    Creation.

sequence(Kind, Tally) ->
    Config = #{services => [{Row, Name} || Row := Names <- ?DECLARED, Name <- Names],
               grants => [{Grantee, Name, Server, #{max_request => 4096}} || {Grantee, Name, Server} <- ?GRANTS],
               owner => fun ?MODULE:owner/1, deadline => 10000},
    Shell = #shell{core = ?CORE:new(Config), tally = Tally},
    %% The reply target starts with every row ready and serving, so its steps reach
    %% minting and installing.
    Prologue = case Kind of
                   reply -> [fun(S) -> ready(Row, good, S) end || Row <- [?S, ?T, ?G]];
                   report -> []
               end,
    Steps = [fun(S) -> event(Kind, S) end || _ <- lists:seq(1, ?STEPS)],
    %% Any exception but a failed check, the core's or the shell's, fails the check
    %% that the core never raises.
    try lists:foldl(fun(Step, S) -> Step(S) end, Shell, Prologue ++ Steps) of
        #shell{tally = Done} -> Done
    catch
        error:{check_failed, _, _} = Failed -> error(Failed);
        Class:Reason -> fail(raised, {Class, Reason})
    end.

event(report, Shell) ->
    weighted([{6, fun(S) -> ready(pick([?S, ?S, ?T, ?G, ?U]), random, S) end},
              {1, fun ended/1}, {2, fun introduced/1}, {2, fun minted/1},
              {1, fun installed/1}, {1, fun deadline/1}], Shell);
event(reply, Shell) ->
    weighted([{1, fun(S) -> ready(pick([?S, ?T, ?G]), good, S) end},
              {1, fun ended/1}, {3, fun introduced/1}, {6, fun minted/1},
              {4, fun installed/1}, {1, fun deadline/1}], Shell).

%%% Events.

%% A ready report of Row: mostly a new incarnation, sometimes a stale or repeated one,
%% at its own node or, rarely, another's. The ids and the rows come from the domain
%% service's own records, which give an id to one row only.
ready(Row, Provides, #shell{next_id = Next, ids = Ids, rows = Rows, row_ids = RowIds} = Shell) ->
    Id = case {rand:uniform(6), maps:get(Row, RowIds, [])} of
             {1, [_ | _] = Own} -> pick(Own);
             _ -> Next
         end,
    Node = case rand:uniform(10) of
               1 -> node_of(pick([?THIRD | Ids ++ [Next + 1]]));
               _ -> node_of(Id)
           end,
    Report = provides(Provides, Row, Id, Node),
    Oracle = case Rows of
                 #{Row := Newest} when Id =< element(1, Newest) -> Rows;
                 #{} -> Rows#{Row => {Id, ready, Node, accepted(Row, Id, Node, Report)}}
             end,
    step({ready, Row, Id, Node, Report},
         Shell#shell{rows = Oracle, next_id = max(Next, Id + 1), ids = lists:usort([Id | Ids]),
                     row_ids = RowIds#{Row => lists:usort([Id | maps:get(Row, RowIds, [])])}}).

%% An end of a row's newest incarnation, mostly, or of an older one of the row.
ended(#shell{rows = Rows, row_ids = RowIds} = Shell) ->
    Row = pick([?S, ?T, ?G, ?U]),
    Id = case {Rows, rand:uniform(4), maps:get(Row, RowIds, [])} of
             {#{Row := Newest}, N, _} when N > 1 -> element(1, Newest);
             {_, _, [_ | _] = Own} -> pick(Own);
             _ -> Shell#shell.next_id
         end,
    Next = max(Shell#shell.next_id, Id + 1),
    Oracle = case Rows of
                 #{Row := Newest2} when Id < element(1, Newest2) -> Rows;
                 #{} -> Rows#{Row => {Id, ended}}
             end,
    step({ended, Row, Id}, Shell#shell{rows = Oracle, next_id = Next,
                                       row_ids = (Shell#shell.row_ids)#{Row => lists:usort([Id | maps:get(Row, Shell#shell.row_ids, [])])}}).

%% An introduction the shell started, settled, or one of a tag it never started.
introduced(#shell{intros = Intros} = Shell) ->
    Result = pick([ok, ok, ok, {error, refused}, {error, noconnection}]),
    case maps:keys(Intros) of
        [] -> step({introduced, random_tag(Shell), Result}, Shell);
        Tags ->
            Tag = pick(Tags),
            step({introduced, Tag, Result}, Shell#shell{intros = maps:remove(Tag, Intros)})
    end.

%% A mint's reply: to a request the shell sent, from its server, mostly with a facet the
%% server owns; or from the wrong domain, with the wrong tag, or with a facet of a
%% third domain, a forged pid or no {ok, Pid}.
minted(#shell{mints = Mints, ids = Ids} = Shell) ->
    {Origin, Tag, Facet} =
        case maps:to_list(Mints) of
            [] -> {pick([?THIRD | Ids]), random_tag(Shell), pid(node_of(?THIRD), ?THIRD, 2)};
            Asked ->
                {T, {ServerId, _Name}} = pick(Asked),
                case rand:uniform(8) of
                    1 -> {pick([?THIRD, ?SYSTEM | Ids]), T, pid(node_of(ServerId), ServerId, 2)};
                    2 -> {ServerId, random_tag(Shell), pid(node_of(ServerId), ServerId, 2)};
                    _ -> {ServerId, T, pick([pid(node_of(ServerId), ServerId, 2), pid(node_of(ServerId), ServerId, 2),
                                             pid(node_of(?THIRD), ?THIRD, 2), pid(node_of(?THIRD), ServerId, 2),
                                             pid(node_of(ServerId), ?THIRD, 2)])}
                end
        end,
    Reply = case rand:uniform(6) of
                1 -> random_term();
                2 -> pick([{error, busy}, {ok, self()}, {ok, Facet, extra}, ok, {ok, fun() -> Facet end}]);
                _ -> {ok, Facet}
            end,
    step({minted, Origin, Tag, Reply}, Shell#shell{mints = maps:remove(Tag, Mints)}).

%% An installation's acknowledgement: from the grantee the shell sent it to, mostly.
installed(#shell{installs = Installs, ids = Ids} = Shell) ->
    {Origin, Tag} = case maps:to_list(Installs) of
                        [] -> {pick([?THIRD | Ids]), random_tag(Shell)};
                        Sent ->
                            {T, GranteeId} = pick(Sent),
                            case rand:uniform(5) of
                                1 -> {pick([?THIRD, ?SYSTEM | Ids]), T};
                                2 -> {GranteeId, random_tag(Shell)};
                                _ -> {GranteeId, T}
                            end
                    end,
    step({installed, Origin, Tag}, Shell#shell{installs = maps:remove(Tag, Installs)}).

%% An armed deadline firing: erx_domain_srv forgets the timer before it feeds the event.
deadline(#shell{armed = Armed} = Shell) ->
    case maps:keys(Armed) of
        [] -> Shell;
        Tags ->
            Tag = pick(Tags),
            step({deadline, Tag}, Shell#shell{armed = maps:remove(Tag, Armed)})
    end.

%%% The step, the shell's effects and the checks.

step(Event, #shell{core = Core, tally = Tally} = Shell) ->
    {Actions, Next} = ?CORE:step(Event, Core),
    progressed(Event, ?CORE:grants(Core), Actions, ?CORE:grants(Next), Shell),
    After = lists:foldl(fun(Action, S) -> act(Action, Event, Next, S) end,
                        Shell#shell{core = Next, tally = Tally#{element(1, Event) => maps:get(element(1, Event), Tally, 0) + 1}},
                        Actions),
    checked(After).

act({arm, Tag, _Ms}, _Event, _Core, #shell{armed = Armed, ever = Ever} = Shell) ->
    is_map_key(Tag, Ever) andalso fail(tag_armed_twice, Tag),
    Shell#shell{armed = Armed#{Tag => true}, ever = Ever#{Tag => true}};
act({disarm, Tag}, _Event, _Core, #shell{armed = Armed} = Shell) ->
    is_map_key(Tag, Armed) orelse fail(disarmed_unarmed_tag, Tag),
    Shell#shell{armed = maps:remove(Tag, Armed)};
act({introduce, Tag, ServerId, GranteeId}, _Event, Core, #shell{intros = Intros} = Shell) ->
    {Key, {introducing, {ServerId, GranteeId}, Tag}} = pending(Tag, Core),
    element(1, Key) =/= system orelse fail(introduced_system, Tag),
    Shell#shell{intros = Intros#{Tag => true}};
act({mint, Tag, Mint, Name, GranteeId, _Limits}, _Event, Core, #shell{mints = Mints} = Shell) ->
    {{_, Name} = Key, {minting, {ServerId, GranteeId}, Tag}} = pending(Tag, Core),
    {Server, _} = grant_of(Key),
    case Shell#shell.rows of
        #{Server := {ServerId, ready, _, #{Name := Mint}}} -> ok;
        #{} -> fail(mint_not_accepted, {Server, ServerId, Name})
    end,
    Shell#shell{mints = Mints#{Tag => {ServerId, Name}}};
act({install, Tag, GranteeId, Name, Facet}, Event, Core, Shell) ->
    {{_, Name} = Key, {installing, {ServerId, GranteeId}, Tag, Facet}} = pending(Tag, Core),
    {Server, _} = grant_of(Key),
    #{Server := {ServerId, ready, Node, _}} = Shell#shell.rows,
    Event =:= {minted, ServerId, Tag, {ok, Facet}} orelse fail(install_without_reply, Tag),
    (node(Facet) =:= Node andalso owner(Facet) =:= ServerId) orelse fail(install_of_foreign_facet, Tag),
    case GranteeId of
        %% erx_domain_srv installs in the system domain's own registry and feeds the
        %% acknowledgement back at once.
        ?SYSTEM -> step({installed, ?SYSTEM, Tag}, Shell);
        _ -> Shell#shell{installs = (Shell#shell.installs)#{Tag => GranteeId}}
    end;
act({Kind, Reason, Detail}, _Event, _Core, Shell) when Kind =:= refused; Kind =:= dropped ->
    (is_atom(Reason) andalso is_tuple(Detail) andalso tuple_size(Detail) =< 3
     andalso lists:all(fun(F) -> is_atom(F) orelse is_integer(F) end, tuple_to_list(Detail)))
        orelse fail(unbounded_detail, Kind),
    Shell;
act({failed, Key, _Pair, _Reason}, _Event, _Core, Shell) ->
    lists:keymember(Key, 1, [{{G, N}, S} || {G, N, S} <- ?GRANTS]) orelse fail(failed_unknown_grant, Key),
    Shell.

%% An honest answer moves its operation on: an introduction's ok to its mint request, a
%% reply from the pair's server naming a facet it owns to its installation, and the
%% grantee's acknowledgement to installed.
progressed({introduced, Tag, ok}, Before, Actions, _After, _Shell) ->
    case [Key || Key := {introducing, _, T} <- Before, T =:= Tag] of
        [_] -> lists:keymember(mint, 1, Actions) orelse fail(introduction_stalled, Tag);
        [] -> ok
    end;
progressed({minted, Origin, Tag, {ok, Facet}}, Before, Actions, _After, #shell{rows = Rows}) when is_pid(Facet) ->
    Owned = [Key || Key := {minting, {S, _}, T} <- Before, T =:= Tag, S =:= Origin,
                    {S2, ready, Node, _} <- [maps:get(element(1, grant_of(Key)), Rows, none)], S2 =:= S,
                    node(Facet) =:= Node, owner(Facet) =:= S],
    case Owned of
        [_] -> lists:keymember(install, 1, Actions) orelse fail(honest_reply_refused, Tag);
        [] -> ok
    end;
progressed({installed, Origin, Tag}, Before, _Actions, After, _Shell) ->
    case [Key || Key := {installing, {_, G}, T, _} <- Before, T =:= Tag, G =:= Origin] of
        [Key] -> element(1, maps:get(Key, After)) =:= installed orelse fail(acknowledgement_ignored, Tag);
        [] -> ok
    end;
progressed(_Event, _Before, _Actions, _After, _Shell) ->
    ok.

%% After a step: each grant carries the oracle's pair, and the armed deadlines are
%% exactly the pending operations'.
checked(#shell{core = Core, rows = Rows, armed = Armed} = Shell) ->
    Grants = ?CORE:grants(Core),
    [carried(Grant) =:= oracle_pair(Key, Rows) orelse fail(pair_differs, {Key, Grant})
     || Key := Grant <- Grants],
    Pending = lists:sort([tag(Grant) || _ := Grant <- Grants, tag(Grant) =/= none]),
    Pending =:= lists:sort(maps:keys(Armed)) orelse fail(deadlines_differ, {Pending, maps:keys(Armed)}),
    Shell.

oracle_pair({Grantee, Name} = Key, Rows) ->
    {Server, _} = grant_of(Key),
    GranteeId = case {Grantee, Rows} of
                    {system, _} -> ?SYSTEM;
                    {_, #{Grantee := {Id, ready, _, _}}} -> Id;
                    _ -> none
                end,
    case Rows of
        #{Server := {ServerId, ready, _, #{Name := _}}} when GranteeId =/= none -> {ServerId, GranteeId};
        #{} -> none
    end.

%% What the design lets a report provide: nothing from a value that is no map or holds
%% more entries than the row declares; else each declared name whose mint the
%% incarnation owns, node and creation.
accepted(Row, Id, Node, Provides) ->
    Names = maps:get(Row, ?DECLARED, []),
    case is_map(Provides) andalso map_size(Provides) =< length(Names) of
        false -> #{};
        true ->
            #{Name => Mint || Name := Mint <- Provides, lists:member(Name, Names), is_pid(Mint),
                              node(Mint) =:= Node, owner(Mint) =:= Id}
    end.

carried(idle) -> none;
carried(Grant) -> element(2, Grant).

tag({introducing, _, Tag}) -> Tag;
tag({minting, _, Tag}) -> Tag;
tag({installing, _, Tag, _}) -> Tag;
tag(_) -> none.

pending(Tag, Core) ->
    case [{Key, Grant} || Key := Grant <- ?CORE:grants(Core), tag(Grant) =:= Tag] of
        [Found] -> Found;
        Other -> fail(no_pending_operation, {Tag, Other})
    end.

grant_of({Grantee, Name}) ->
    [Server] = [S || {G, N, S} <- ?GRANTS, G =:= Grantee, N =:= Name],
    {Server, Name}.

fail(What, Detail) ->
    error({check_failed, What, Detail}).

%%% Inputs.

%% A report's provides: a server's honest one, each declared name to a mint it owns, or
%% anything a server could send.
provides(good, Row, Id, Node) ->
    #{Name => pid(Node, Id, 1) || Name <- maps:get(Row, ?DECLARED, [])};
provides(random, Row, Id, Node) ->
    case rand:uniform(10) of
        1 -> pick([[{data, pid(Node, Id, 1)}], data, <<"data">>, {data, pid(Node, Id, 1)}, random_term()]);
        2 -> maps:from_list([{list_to_atom("n" ++ integer_to_list(N)), pid(Node, Id, N)} || N <- lists:seq(1, 50)]);
        3 -> provides(good, Row, Id, Node);
        _ ->
            Keys = [data, log, other, junk, <<"data">>, 7, {data}],
            maps:from_list([{pick(Keys), mint_value(Node, Id)} || _ <- lists:seq(1, rand:uniform(4) - 1)])
    end.

mint_value(Node, Id) ->
    pick([pid(Node, Id, 1), pid(Node, Id, 1), pid(Node, ?THIRD, 1), pid(node_of(?THIRD), Id, 1),
          pid(node_of(?THIRD), ?THIRD, 1), self(), fun() -> ok end, {erlang, halt, []},
          erx_domain_srv, make_ref(), random_term()]).

random_tag(#shell{ever = Ever}) ->
    pick([0, -1, 1.0, 1 bsl 70, tag, make_ref(), {1}, 1 + map_size(Ever) + rand:uniform(3)
          | maps:keys(Ever)]).

random_term() ->
    pick([[], <<0, 255>>, {}, lists:duplicate(1000, x), #{a => {b, [c]}}, 3.5, {ok},
          lists:foldl(fun(_, T) -> {T} end, x, lists:seq(1, 200))]).

node_of(Id) -> list_to_atom("d" ++ integer_to_list(Id) ++ "@h").

%% A pid of Node with creation Creation, as another domain's pid reaches the system domain.
pid(Node, Creation, Number) ->
    Name = atom_to_binary(Node),
    binary_to_term(<<131, 88, 119, (byte_size(Name)), Name/binary, Number:32, 0:32, Creation:32>>).

weighted(Choices, Shell) ->
    Total = lists:sum([W || {W, _} <- Choices]),
    pick_weighted(rand:uniform(Total), Choices, Shell).

pick_weighted(N, [{W, Fun} | _], Shell) when N =< W -> Fun(Shell);
pick_weighted(N, [{W, _} | Rest], Shell) -> pick_weighted(N - W, Rest, Shell).

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
