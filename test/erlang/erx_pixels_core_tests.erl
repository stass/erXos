%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pixels_core_tests).
-moduledoc """
EUnit cases of erx_pixels_core (docs/design-display.md, "The pixel area",
The allocator's core, and Verification), run by
test/host/erx_pixels_core_test.rb with its seeded faults.

random_sequences_test plays the allocating process over random sequences of
allocs, lends, owners' exits and leases' returns, and keeps a model of the
area's pages: a page is dirty from the alloc that hands it out until a zero
effect over it is performed. It delivers each zero effect at a random later
step, so a run joins the free list early only if the core joins it before its
zero. After every step: no two live ranges overlap, every range and free run
lies within the area, every range whose owner lives or whose lease is
outstanding is still live, and every page an alloc hands out is clean. At
the end, once every owner has exited, every lease has returned and every zero
is performed, one alloc of the whole area succeeds.
""".

-include_lib("eunit/include/eunit.hrl").

-define(PAGE, 4096).
-define(PAGES, 16).
-define(SEQUENCES, 300).
-define(STEPS, 80).
-define(OWNERS, 4).

owner(N) -> list_to_pid("<0." ++ integer_to_list(1000 + N) ++ ".0>").

new_area_is_wholly_free_test() ->
    Core = erx_pixels_core:new(?PAGES * ?PAGE + 100),
    ?assertEqual([{0, ?PAGES}], erx_pixels_core:free(Core)),
    ?assert(erx_pixels_core:idle(Core)),
    ?assertEqual([], erx_pixels_core:free(erx_pixels_core:new(?PAGE - 1))).

alloc_rounds_up_and_takes_the_first_fit_test() ->
    A = owner(1),
    Core0 = erx_pixels_core:new(4 * ?PAGE),
    {ok, 0, Core1} = erx_pixels_core:alloc(Core0, A, 1),
    {ok, ?PAGE, Core2} = erx_pixels_core:alloc(Core1, A, ?PAGE + 1),
    ?assertEqual([{3 * ?PAGE, 1}], erx_pixels_core:free(Core2)),
    ?assertEqual({error, enomem}, erx_pixels_core:alloc(Core2, A, 2 * ?PAGE)),
    ?assertEqual([{0, 1, A, owned}, {?PAGE, 2, A, owned}], erx_pixels_core:ranges(Core2)).

owners_exit_zeroes_then_joins_test() ->
    A = owner(1),
    B = owner(2),
    {ok, 0, C1} = erx_pixels_core:alloc(erx_pixels_core:new(3 * ?PAGE), A, ?PAGE),
    {ok, ?PAGE, C2} = erx_pixels_core:alloc(C1, B, ?PAGE),
    {C3, Effects} = erx_pixels_core:owner_down(C2, A),
    ?assertEqual([{zero, 0, 1}], Effects),
    ?assertEqual([{2 * ?PAGE, 1}], erx_pixels_core:free(C3)),
    C4 = erx_pixels_core:zeroed(C3, 0, 1),
    ?assertEqual([{0, 1}, {2 * ?PAGE, 1}], erx_pixels_core:free(C4)),
    {C5, [{zero, ?PAGE, 1}]} = erx_pixels_core:owner_down(C4, B),
    ?assertNot(erx_pixels_core:idle(C5)),
    C6 = erx_pixels_core:zeroed(C5, ?PAGE, 1),
    ?assertEqual([{0, 3}], erx_pixels_core:free(C6)),
    ?assert(erx_pixels_core:idle(C6)).

lend_refusals_test() ->
    A = owner(1),
    B = owner(2),
    {ok, 0, Core} = erx_pixels_core:alloc(erx_pixels_core:new(4 * ?PAGE), A, 2 * ?PAGE),
    ?assertMatch({_, [{lend, 0, 2, A}]}, erx_pixels_core:lend(Core, A, 0, from)),
    ?assertEqual({Core, [{reply, from, {error, einval}}]}, erx_pixels_core:lend(Core, B, 0, from)),
    ?assertEqual({Core, [{reply, from, {error, einval}}]}, erx_pixels_core:lend(Core, A, ?PAGE, from)),
    ?assertEqual({Core, [{reply, from, {error, einval}}]}, erx_pixels_core:lend(Core, A, 1, from)),
    ?assertEqual({Core, [{reply, from, {error, einval}}]}, erx_pixels_core:lend(Core, A, 2 * ?PAGE, from)).

a_lend_waits_for_the_outstanding_lease_test() ->
    A = owner(1),
    {ok, 0, C0} = erx_pixels_core:alloc(erx_pixels_core:new(4 * ?PAGE), A, ?PAGE),
    {C1, [{lend, 0, 1, A}]} = erx_pixels_core:lend(C0, A, 0, first),
    {C2, [{reply, first, {ok, 7, 1}}]} = erx_pixels_core:lent(C1, 0, {ok, 7}),
    ?assertEqual({ok, A}, erx_pixels_core:holder(C2, 7)),
    {C3, []} = erx_pixels_core:lend(C2, A, 0, second),
    {C4, [{reply, second, {error, einval}}]} = erx_pixels_core:lend(C3, A, 0, third),
    {C5, [{lend, 0, 1, A}]} = erx_pixels_core:returned(C4, 7),
    ?assertEqual(error, erx_pixels_core:holder(C5, 7)),
    {C6, [{reply, third, {ok, 8, 1}}]} = erx_pixels_core:lent(C5, 0, {ok, 8}),
    {C7, []} = erx_pixels_core:returned(C6, 8),
    ?assertEqual([{0, 1, A, owned}], erx_pixels_core:ranges(C7)),
    {C8, [{lend, 0, 1, A}]} = erx_pixels_core:lend(C7, A, 0, fourth),
    {C9, [{reply, fourth, {error, noproc}}]} = erx_pixels_core:lent(C8, 0, {error, noproc}),
    ?assertEqual([{0, 1, A, owned}], erx_pixels_core:ranges(C9)).

an_orphaned_range_waits_for_its_return_test() ->
    A = owner(1),
    {ok, 0, C0} = erx_pixels_core:alloc(erx_pixels_core:new(2 * ?PAGE), A, ?PAGE),
    {C1, _} = erx_pixels_core:lend(C0, A, 0, first),
    {C2, _} = erx_pixels_core:lent(C1, 0, {ok, 3}),
    {C3, []} = erx_pixels_core:lend(C2, A, 0, waiting),
    {C4, []} = erx_pixels_core:owner_down(C3, A),
    ?assertEqual([{0, 1, A, orphaned}], erx_pixels_core:ranges(C4)),
    ?assertEqual({error, enomem}, erx_pixels_core:alloc(C4, owner(2), 2 * ?PAGE)),
    {C5, [{zero, 0, 1}]} = erx_pixels_core:returned(C4, 3),
    ?assert(erx_pixels_core:idle(erx_pixels_core:zeroed(C5, 0, 1))).

random_sequences_test_() ->
    {timeout, 120, fun() -> lists:foreach(fun sequence/1, lists:seq(1, ?SEQUENCES)) end}.

%% The model: core; memory, page => dirty for each dirty page; live, the owners
%% alive; ranges, offset => {Pages, Owner, Lease} for every range the model
%% says must still be live; pending, the zero effects not yet performed; next,
%% the next lease number.
sequence(Seed) ->
    _ = rand:seed(exsss, {Seed, 17, 29}),
    Model0 = #{core => erx_pixels_core:new(?PAGES * ?PAGE), memory => #{}, live => lists:seq(1, ?OWNERS),
               ranges => #{}, pending => [], next => 1},
    Model = lists:foldl(fun(_, M) -> check(step(M)) end, Model0, lists:seq(1, ?STEPS)),
    finish(Model).

step(Model) ->
    case rand:uniform(6) of
        1 -> alloc(Model);
        2 -> alloc(Model);
        3 -> lend(Model);
        4 -> return_one(Model);
        5 -> exit_one(Model);
        6 -> zero_one(Model)
    end.

alloc(#{live := []} = Model) ->
    Model;
alloc(#{core := Core, live := Live, memory := Memory, ranges := Ranges} = Model) ->
    N = pick(Live),
    case erx_pixels_core:alloc(Core, owner(N), rand:uniform(3 * ?PAGE)) of
        {ok, Offset, Next} ->
            [{Offset, Pages, _, owned}] = [R || {O, _, _, _} = R <- erx_pixels_core:ranges(Next), O =:= Offset],
            Handed = pages(Offset, Pages),
            ?assertEqual([], [P || P <- Handed, maps:is_key(P, Memory)]),
            Model#{core := Next, memory := maps:merge(Memory, maps:from_keys(Handed, dirty)),
                   ranges := Ranges#{Offset => {Pages, N, none}}};
        {error, enomem} ->
            Model
    end.

lend(#{ranges := Ranges, live := Live} = Model) ->
    case [{O, N} || O := {_, N, _} <- Ranges, lists:member(N, Live)] of
        [] -> Model;
        Owned -> lend_range(pick(Owned), Model)
    end.

lend_range({Offset, N}, #{core := Core} = Model) ->
    From = make_ref(),
    perform(erx_pixels_core:lend(Core, owner(N), Offset, From), Model).

%% Performs effects as erx_pixels does, but queues each zero for a later step.
perform({Core, Effects}, Model) ->
    lists:foldl(fun effect/2, Model#{core := Core}, Effects).

effect({zero, Offset, Pages}, #{pending := Pending} = Model) ->
    Model#{pending := Pending ++ [{Offset, Pages}]};
effect({reply, _From, _Reply}, Model) ->
    Model;
effect({lend, Offset, _Pages, _Owner}, #{core := Core, next := Lease, ranges := Ranges} = Model) ->
    {Pages, N, none} = maps:get(Offset, Ranges),
    Kept = Model#{next := Lease + 1, ranges := Ranges#{Offset => {Pages, N, Lease}}},
    perform(erx_pixels_core:lent(Core, Offset, {ok, Lease}), Kept).

return_one(#{ranges := Ranges} = Model) ->
    case [{O, L} || O := {_, _, L} <- Ranges, L =/= none] of
        [] ->
            Model;
        Lent ->
            {Offset, Lease} = pick(Lent),
            #{Offset := {Pages, N, Lease}} = Ranges,
            Returned = Model#{ranges := Ranges#{Offset => {Pages, N, none}}},
            settle(perform(erx_pixels_core:returned(maps:get(core, Model), Lease), Returned))
    end.

exit_one(#{live := []} = Model) ->
    Model;
exit_one(#{live := Live, core := Core} = Model) ->
    N = pick(Live),
    settle(perform(erx_pixels_core:owner_down(Core, owner(N)), Model#{live := Live -- [N]})).

zero_one(#{pending := []} = Model) ->
    Model;
zero_one(#{pending := [{Offset, Pages} | Rest], memory := Memory, core := Core} = Model) ->
    Model#{pending := Rest, memory := maps:without(pages(Offset, Pages), Memory),
           core := erx_pixels_core:zeroed(Core, Offset, Pages)}.

%% Drops from the model the ranges that need not stay live any more.
settle(#{ranges := Ranges, live := Live} = Model) ->
    Model#{ranges := maps:filter(fun(_, {_, N, Lease}) -> Lease =/= none orelse lists:member(N, Live) end,
                                 Ranges)}.

check(#{core := Core, ranges := Ranges} = Model) ->
    Live = erx_pixels_core:ranges(Core),
    Extents = [{O, P} || {O, P, _, _} <- Live] ++ erx_pixels_core:free(Core),
    Pages = lists:append([pages(O, P) || {O, P} <- Extents]),
    ?assertEqual(length(Pages), length(lists:usort(Pages))),
    ?assertEqual([], [P || P <- Pages, P < 0 orelse P >= ?PAGES]),
    [?assert(lists:member({O, P}, [{LO, LP} || {LO, LP, _, _} <- Live])) || O := {P, _, _} <- Ranges],
    Model.

finish(Model0) ->
    Exited = lists:foldl(fun(_, M) -> exit_one(M) end, Model0, lists:seq(1, ?OWNERS)),
    Returned = lists:foldl(fun(_, M) -> return_one(M) end, Exited, lists:seq(1, ?PAGES)),
    #{core := Core} = lists:foldl(fun(_, M) -> zero_one(M) end, Returned, lists:seq(1, 2 * ?PAGES)),
    ?assertMatch({ok, 0, _}, erx_pixels_core:alloc(Core, owner(0), ?PAGES * ?PAGE)),
    ?assert(erx_pixels_core:idle(Core)).

pages(Offset, Pages) -> lists:seq(Offset div ?PAGE, Offset div ?PAGE + Pages - 1).

pick(List) -> lists:nth(rand:uniform(length(List)), List).
