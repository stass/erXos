%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The pairing window's core, erx_bt_window (docs/design-bluetooth.md, "The pairing
%% window", "A pairing's outcome has one ordering point"): an exploration of every input
%% sequence to a bounded depth over two opens and two links, fresh and stale tags, each
%% state keyed by the whole core with its times made relative to the clock (the pairing's
%% address is the one phone's, so it needs no key), checking the window's rules at every
%% step, then the pairing wait and the lines case by case.
-module(erx_bt_window_tests).

-include_lib("eunit/include/eunit.hrl").

-define(L1, list_to_pid("<0.901.0>")).
-define(L2, list_to_pid("<0.902.0>")).
-define(PHONE, {random, <<16#C0, 1, 2, 3, 4, 5>>}).
-define(IDENTITY, {public, <<16#00, 16#1B, 16#DC, 16#0A, 16#0B, 16#0C>>}).
-define(DEPTH, 16).

%% Exploration -----------------------------------------------------------------

%% Every input the exploration offers: opens a and b, their modes and clunks, a link's
%% every message with its own and a stale tag, the store's outcomes, the ends of both
%% links, and time moving to the core's deadline or past the longest wait.
alphabet() ->
    [{open, a}, {open, b}, {write, a, display}, {write, b, nodisplay}, {clunk, a}, {clunk, b},
     {link, ?L1, {admit, 1, ?PHONE}}, {link, ?L1, {admit, 2, ?PHONE}}, {link, ?L2, {admit, 1, ?PHONE}},
     {link, ?L1, {passkey, 1, 123}}, {link, ?L1, {outcome, 1, {failed, confirm}}},
     {link, ?L1, {outcome, 2, {failed, withdrawn}}}, {link, ?L1, {keeping, 1}}, {link, ?L2, {keeping, 1}},
     {link, ?L1, wait}, {down, ?L1}, {down, ?L2},
     {store, {outcome, ?L1, 1, {bonded, ?IDENTITY, authenticated}}}, {store, {outcome, ?L1, 1, {failed, unavailable}}},
     {store, {outcome, ?L2, 1, {failed, bonds_full}}}, deadline, later].

%% The explorer's state: the core, the clock, the links the process would monitor, and
%% each open's lines read so far.
-record(x, {core, now = 0, monitored = [], read = #{}}).

explore_test_() ->
    {timeout, 600, fun() ->
        Seen = explore([#x{core = erx_bt_window:new(read)}], ?DEPTH, #{}),
        io:format(user, "explored ~B states~n", [map_size(Seen)]),
        ?assert(map_size(Seen) > 1000)
    end}.

explore([], _Depth, Seen) ->
    Seen;
explore(_Frontier, 0, Seen) ->
    Seen;
explore(Frontier, Depth, Seen) ->
    {Next, Seen1} = lists:foldl(
        fun(X, Acc) ->
            lists:foldl(fun(Input, {Found, S}) ->
                                X1 = transition(Input, X),
                                Key = X1#x{now = 0, core = rebased(X1)},
                                case S of
                                    #{Key := _} -> {Found, S};
                                    #{} -> {[X1 | Found], S#{Key => []}}
                                end
                        end, Acc, alphabet())
        end, {[], Seen}, Frontier),
    explore(Next, Depth - 1, Seen1).

%% A state's key ignores where on the clock it stands: the core's facts relative to now.
rebased(#x{core = Core, now = Now}) ->
    Facts = erx_bt_window:facts(Core),
    Window = case Facts of #{window := {admitting, Id, Mode, D, A}} -> {admitting, Id, Mode, D - Now, A}; #{window := W} -> W end,
    Facts#{window := Window, last_failure := case Facts of #{last_failure := none} -> none; #{last_failure := L} -> Now - L end,
           wait_until := case Facts of #{wait_until := none} -> none; #{wait_until := U} -> max(0, U - Now) end,
           deadline => case erx_bt_window:next_deadline(Core) of infinity -> infinity; Due -> Due - Now end}.

transition(deadline, #x{core = Core, now = Now} = X) ->
    case erx_bt_window:next_deadline(Core) of
        infinity -> X;
        Deadline -> transition(expired, X#x{now = max(Now, Deadline)})
    end;
transition(later, #x{now = Now} = X) ->
    transition(expired, X#x{now = Now + 64001});
transition({open, Id} = Input, #x{core = Core} = X) ->
    case lists:member(Id, erx_bt_window:opens(Core)) of
        true -> X;   % an open names a fid, which the grant never reuses while open
        false -> step(Input, X)
    end;
transition(Input, X) ->
    step(Input, X).

step(Input, #x{core = Core, now = Now, monitored = Monitored} = X) ->
    Before = erx_bt_window:facts(Core),
    {Actions, Core1} = erx_bt_window:step(Input, Now, Core),
    After = erx_bt_window:facts(Core1),
    %% A monitored link's end removes its monitor, as the runtime does.
    Monitored1 = monitors(Actions, Monitored -- [L || {down, L} <- [Input]]),
    check(Input, Before, Actions, After, Monitored, Monitored1, Now),
    Read = maps:without([Id || {clunk, Id} <- [Input]] ++ [Id || {open, Id} <- [Input], {answer, ok} <- Actions], X#x.read),
    read_all(X#x{core = Core1, monitored = Monitored1, read = Read}).

%% Monitors: a link is monitored once, from its `open` verdict while its pairing runs.
monitors([{monitor, Link} | Rest], Monitored) ->
    ?assertNot(lists:member(Link, Monitored)),
    monitors(Rest, [Link | Monitored]);
monitors([{demonitor, Link} | Rest], Monitored) ->
    ?assert(lists:member(Link, Monitored)),
    monitors(Rest, Monitored -- [Link]);
monitors([_ | Rest], Monitored) ->
    monitors(Rest, Monitored);
monitors([], Monitored) ->
    Monitored.

check(Input, Before, Actions, After, Monitored, Monitored1, Now) ->
    %% The monitors follow the pairing's stage.
    case After of
        #{pairing := {Link, _, running}} -> ?assertEqual([Link], Monitored1);
        #{} -> ?assertEqual([], Monitored1)
    end,
    %% At most one window, and a window takes its one pairing.
    case After of
        #{window := {pairing, _}} -> ?assertNotEqual(none, maps:get(pairing, After));
        #{} -> ok
    end,
    %% An open is answered ok only with no window and no pairing awaited.
    [?assertMatch(#{window := none, pairing := none}, Before) || {answer, ok} <- Actions, is_tuple(Input), element(1, Input) =:= open],
    %% Each admit is answered once, with its own tag; `open` only with nothing awaited and
    %% the wait passed.
    case Input of
        {link, Link0, {admit, Tag0, _}} ->
            [{Link0, Tag0, Verdict}] = [{L, T, {open, M}} || {open, L, T, M} <- Actions]
                                       ++ [{L, T, V} || {send, L, {admission, T, V}} <- Actions],
            [?assertMatch(#{pairing := none, window := {admitting, _, _, _, _}}, Before) || {open, _} <- [Verdict]],
            [?assert(case Before of #{wait_until := none} -> true; #{wait_until := U} -> U =< Now end)
             || {open, _} <- [Verdict]];
        _ -> ok
    end,
    %% A withdrawal comes only from a clunk, to the running pairing's link and tag.
    [begin
         ?assertMatch({clunk, _}, Input),
         ?assertMatch(#{pairing := {L, T, running}} when L =:= Link1 andalso T =:= Tag1, Before)
     end || {send, Link1, {withdraw, Tag1}} <- Actions],
    %% The wait moves at exactly the failures of the awaited pairing: its link's failure
    %% or end while it runs, or the store's failed outcome.
    Failure = case {Input, Before} of
                  {{down, L2}, #{pairing := {L2, _, running}}} -> true;
                  {{link, L2, {outcome, T2, {failed, _}}}, #{pairing := {L2, T2, running}}} -> true;
                  {{store, {outcome, L2, T2, {failed, _}}}, #{pairing := {L2, T2, _}}} -> true;
                  _ -> false
              end,
    case Failure of
        true -> ?assert(maps:get(wait_until, After) >= Now + 2000);
        false -> ?assertEqual(maps:get(wait_until, Before), maps:get(wait_until, After))
    end,
    %% The end of a link the process does not monitor changes nothing.
    case Input of
        {down, L3} -> lists:member(L3, Monitored) orelse ?assertEqual(Before, After);
        _ -> ok
    end.

%% Reads every open's lines; a line never follows the last, and each is one of the
%% window's forms.
read_all(#x{core = Core} = X) ->
    lists:foldl(fun(Id, #x{core = C, read = R} = Acc) ->
                        Lines = maps:get(Id, R, []),
                        case erx_bt_window:take(Id, 4096, C) of
                            {{ok, Bytes}, C1} ->
                                New = binary:split(Bytes, <<"\n">>, [global, trim]),
                                [?assertNot(terminal(Line)) || Line <- Lines],
                                [?assert(well_formed(Line)) || Line <- New],
                                Acc#x{core = C1, read = R#{Id => Lines ++ New}};
                            {eof, _} ->
                                ?assert(lists:any(fun terminal/1, Lines)),
                                Acc;
                            {none, _} ->
                                ?assertNot(lists:any(fun terminal/1, Lines)),
                                Acc
                        end
                end, X, erx_bt_window:opens(Core)).

terminal(<<"bonded ", _/binary>>) -> true;
terminal(<<"failed ", _/binary>>) -> true;
terminal(<<"closed ", _/binary>>) -> true;
terminal(_) -> false.

well_formed(Line) ->
    lists:any(fun(Pattern) -> re:run(Line, Pattern, [{capture, none}]) =:= match end,
              ["^wait [0-9]+$", "^waiting$", "^passkey [0-9]{6} ([0-9A-F]{2}:){5}[0-9A-F]{2}$",
               "^bonded ([0-9A-F]{2}:){5}[0-9A-F]{2} (public|random) (authenticated|unauthenticated)$",
               "^failed ([0-9A-F]{2}:){5}[0-9A-F]{2} [a-z_]+$", "^closed timeout$"]).

%% Cases -----------------------------------------------------------------------

new() -> erx_bt_window:new(read).

%% Steps the inputs at Now in order, returning every action and the last core.
run(Inputs, Now, Core) ->
    lists:foldl(fun(Input, {Acts, C}) -> {A, C1} = erx_bt_window:step(Input, Now, C), {Acts ++ A, C1} end,
                {[], Core}, Inputs).

lines(Id, Core) ->
    case erx_bt_window:take(Id, 4096, Core) of
        {{ok, Bytes}, _} -> Bytes;
        {Other, _} -> Other
    end.

%% A window open at Now in the given mode.
window(Id, Mode, Now, Core) ->
    {[{answer, ok}, {answer, ok}], Opened} = run([{open, Id}, {write, Id, Mode}], Now, Core),
    Opened.

%% A pairing that one window admits at Now and that L1's end fails: the next core,
%% and the wait it set.
failed_once(Now, Core) ->
    {_, C1} = run([{open, f}, {write, f, display}, {link, ?L1, {admit, Now, ?PHONE}}, {down, ?L1}, {clunk, f}], Now, Core),
    {C1, maps:get(wait_until, erx_bt_window:facts(C1)) - Now}.

wait_doubles_to_its_maximum_test() ->
    {Waits, _} = lists:mapfoldl(fun(I, C) -> {C1, W} = failed_once(I * 100000, C), {W, C1} end,
                                new(), lists:seq(1, 7)),
    ?assertEqual([2000, 4000, 8000, 16000, 32000, 64000, 64000], Waits).

%% A failure imposes twice the last one's wait, halved per whole 600 s since it, within
%% 2 s and 64 s.
wait_halves_for_each_decay_without_a_failure_test() ->
    C = lists:foldl(fun(I, Acc) -> element(1, failed_once(I * 100000, Acc)) end, new(), lists:seq(1, 6)),
    %% After a 64 s wait: 64 s until 1200 s have passed, then 32 s, and 2 s at last.
    ?assertEqual(64000, element(2, failed_once(600000 + 599999, C))),
    ?assertEqual(64000, element(2, failed_once(600000 + 600000, C))),
    ?assertEqual(32000, element(2, failed_once(600000 + 1200000, C))),
    ?assertEqual(2000, element(2, failed_once(600000 + 6000000, C))),
    %% After a 4 s wait: 8 s once it has passed, 4 s after 600 s, never below 2 s.
    {C2, 4000} = failed_once(200000, element(1, failed_once(100000, new()))),
    ?assertEqual(8000, element(2, failed_once(204000, C2))),
    ?assertEqual(4000, element(2, failed_once(800000, C2))),
    ?assertEqual(2000, element(2, failed_once(2000000, C2))).

a_request_during_the_wait_is_repeated_attempts_and_leaves_the_window_test() ->
    {C, 2000} = failed_once(0, new()),
    W = window(a, display, 500, C),
    ?assertEqual(<<"wait 2\n">>, lines(a, W)),
    {[{send, _, {admission, 7, waiting}}], W1} = erx_bt_window:step({link, ?L2, {admit, 7, ?PHONE}}, 1000, W),
    ?assertMatch(#{window := {admitting, _, _, _, _}, pairing := none}, erx_bt_window:facts(W1)),
    ?assertEqual(2000, erx_bt_window:next_deadline(W1)),
    {[], W2} = erx_bt_window:step(expired, 2000, W1),
    ?assertEqual(<<"wait 2\nwaiting\n">>, lines(a, W2)),
    ?assertMatch({[{open, _, 8, display}, {monitor, _}], _},
                 erx_bt_window:step({link, ?L2, {admit, 8, ?PHONE}}, 2000, W2)).

back_to_back_windows_do_not_shorten_the_wait_test() ->
    {C, 2000} = failed_once(0, new()),
    {_, C1} = run([{open, a}, {clunk, a}, {open, b}, {write, b, nodisplay}], 10, C),
    ?assertMatch({[{send, _, {admission, 1, waiting}}], _}, erx_bt_window:step({link, ?L1, {admit, 1, ?PHONE}}, 1999, C1)).

a_disconnection_mid_pairing_fails_and_counts_test() ->
    W = window(a, display, 0, new()),
    {_, W1} = run([{link, ?L1, {admit, 1, ?PHONE}}, {link, ?L1, {passkey, 1, 42}}], 10, W),
    {Actions, W2} = erx_bt_window:step({down, ?L1}, 20, W1),
    ?assertMatch([{log, #{outcome := {failed, disconnected}}}], Actions),
    ?assertEqual(<<"waiting\npasskey 000042 C0:01:02:03:04:05\nfailed C0:01:02:03:04:05 disconnected\n">>, lines(a, W2)),
    ?assertMatch(#{wait_until := 2020, window := none, pairing := none}, erx_bt_window:facts(W2)).

keeping_then_down_leaves_the_store_to_decide_test() ->
    W = window(a, display, 0, new()),
    {Actions, W1} = run([{link, ?L1, {admit, 1, ?PHONE}}, {link, ?L1, {keeping, 1}}, {clunk, a}, {down, ?L1}], 10, W),
    ?assertEqual([], [A || {send, _, {withdraw, _}} = A <- Actions]),
    ?assertEqual({[{answer, {error, ebusy}}], W1}, erx_bt_window:step({open, b}, 20, W1)),
    {_, W2} = erx_bt_window:step({store, {outcome, ?L1, 1, {bonded, ?IDENTITY, authenticated}}}, 30, W1),
    ?assertMatch(#{wait_until := none, pairing := none}, erx_bt_window:facts(W2)),
    ?assertMatch({[{answer, ok}], _}, erx_bt_window:step({open, b}, 40, W2)).

a_bond_is_written_with_the_identity_and_level_test() ->
    W = window(a, nodisplay, 0, new()),
    {_, W1} = run([{link, ?L1, {admit, 1, ?PHONE}}, {link, ?L1, {keeping, 1}},
                   {store, {outcome, ?L1, 1, {bonded, ?IDENTITY, unauthenticated}}}], 10, W),
    ?assertEqual(<<"waiting\nbonded 00:1B:DC:0A:0B:0C public unauthenticated\n">>, lines(a, W1)),
    {eof, _} = erx_bt_window:take(a, 10, element(2, erx_bt_window:take(a, 4096, W1))).

closing_withdraws_a_running_pairing_test() ->
    W = window(a, display, 0, new()),
    {_, W1} = run([{link, ?L1, {admit, 3, ?PHONE}}], 10, W),
    {[{send, Link, {withdraw, 3}}], W2} = erx_bt_window:step({clunk, a}, 20, W1),
    ?assertEqual(?L1, Link),
    ?assertMatch({[{answer, {error, ebusy}}], _}, erx_bt_window:step({open, b}, 25, W2)),
    {Actions, W3} = erx_bt_window:step({link, ?L1, {outcome, 3, {failed, withdrawn}}}, 30, W2),
    ?assertMatch([{demonitor, _}, {log, #{outcome := {failed, withdrawn}}}], Actions),
    ?assertMatch(#{wait_until := 2030}, erx_bt_window:facts(W3)),
    ?assertEqual([], erx_bt_window:opens(W3)).

stale_tags_change_nothing_test() ->
    W = window(a, display, 0, new()),
    {_, W1} = run([{link, ?L1, {admit, 2, ?PHONE}}], 10, W),
    [?assertEqual({[], W1}, erx_bt_window:step(Late, 20, W1))
     || Late <- [{link, ?L1, {passkey, 1, 5}}, {link, ?L1, {outcome, 1, {failed, confirm}}}, {link, ?L1, {keeping, 1}},
                 {link, ?L2, {keeping, 2}}, {store, {outcome, ?L1, 1, {failed, unavailable}}}, {down, ?L2}]],
    ?assertMatch({[{send, _, {admission, 9, closed}}], _}, erx_bt_window:step({link, ?L2, {admit, 9, ?PHONE}}, 20, W1)).

the_store_outcome_before_keeping_decides_test() ->
    W = window(a, display, 0, new()),
    {Actions, W1} = run([{link, ?L1, {admit, 1, ?PHONE}}, {store, {outcome, ?L1, 1, {failed, already_bonded}}}], 10, W),
    ?assertMatch([{open, _, 1, display}, {monitor, _}, {demonitor, _}, {log, _}], Actions),
    ?assertEqual(<<"waiting\nfailed C0:01:02:03:04:05 already_bonded\n">>, lines(a, W1)),
    ?assertEqual({[], W1}, erx_bt_window:step({link, ?L1, {keeping, 1}}, 20, W1)).

no_window_admits_nothing_and_the_time_runs_out_test() ->
    ?assertMatch({[{send, _, {admission, 1, closed}}], _}, erx_bt_window:step({link, ?L1, {admit, 1, ?PHONE}}, 0, new())),
    {_, R} = erx_bt_window:step({open, a}, 0, new()),
    ?assertMatch({[{send, _, {admission, 1, closed}}], _}, erx_bt_window:step({link, ?L1, {admit, 1, ?PHONE}}, 0, R)),
    W = window(a, display, 0, new()),
    ?assertEqual(120000, erx_bt_window:next_deadline(W)),
    {[], W1} = erx_bt_window:step(expired, 120000, W),
    ?assertEqual(<<"waiting\nclosed timeout\n">>, lines(a, W1)),
    ?assertMatch({[{send, _, {admission, 1, closed}}], _}, erx_bt_window:step({link, ?L1, {admit, 1, ?PHONE}}, 120000, W1)),
    ?assertMatch({[{answer, ok}], _}, erx_bt_window:step({open, b}, 120001, W1)).

%% Only a store unknown since its start refuses; after an unconfirmed put the store reads
%% before the pairing's keep, so the window opens.
open_refusals_test() ->
    ?assertMatch({[{answer, {error, eio}}], _}, erx_bt_window:step({open, a}, 0, erx_bt_window:new({unknown, start}))),
    ?assertMatch({[{answer, ok}], _}, erx_bt_window:step({open, a}, 0, erx_bt_window:new({unknown, put}))),
    {_, R} = erx_bt_window:step({open, a}, 0, new()),
    ?assertMatch({[{answer, {error, ebusy}}], _}, erx_bt_window:step({open, b}, 0, R)),
    {_, W} = erx_bt_window:step({write, a, display}, 0, R),
    ?assertMatch({[{answer, {error, einval}}], _}, erx_bt_window:step({write, a, display}, 0, W)),
    ?assertMatch({[{answer, {error, einval}}], _}, erx_bt_window:step({write, b, display}, 0, W)).

%% A store unknown since its start leaves that state only by a confirmed `forget`, whose
%% answer the process steps as `{store, read}`: the window opens from then on.
a_confirmed_forget_ends_the_refusal_test() ->
    {[], Read} = erx_bt_window:step({store, read}, 0, erx_bt_window:new({unknown, start})),
    ?assertMatch({[{answer, ok}], _}, erx_bt_window:step({open, a}, 0, Read)),
    {[], Same} = erx_bt_window:step({store, read}, 0, new()),
    ?assertMatch({[{answer, ok}], _}, erx_bt_window:step({open, a}, 0, Same)).

the_wait_answers_a_bonded_link_test() ->
    ?assertMatch({[{send, _, {wait, 0}}], _}, erx_bt_window:step({link, ?L1, wait}, 0, new())),
    {C, 2000} = failed_once(100, new()),
    ?assertMatch({[{send, _, {wait, 1500}}], _}, erx_bt_window:step({link, ?L2, wait}, 600, C)).

a_read_takes_at_most_its_count_test() ->
    W = window(a, display, 0, new()),
    {{ok, <<"wai">>}, W1} = erx_bt_window:take(a, 3, W),
    {{ok, <<"ting\n">>}, W2} = erx_bt_window:take(a, 100, W1),
    ?assertMatch({none, _}, erx_bt_window:take(a, 100, W2)).

parse_test() ->
    [?assertEqual({ok, display}, erx_bt_window:parse(B)) || B <- [<<"display">>, <<"display\n">>]],
    [?assertEqual({ok, nodisplay}, erx_bt_window:parse(B)) || B <- [<<"nodisplay">>, <<"nodisplay\n">>]],
    [?assertEqual({error, einval}, erx_bt_window:parse(B))
     || B <- [<<>>, <<"display\n\n">>, <<"Display">>, <<"displayx">>, <<" display">>, <<"display\r\n">>,
              binary:copy(<<"x">>, 17)]].
