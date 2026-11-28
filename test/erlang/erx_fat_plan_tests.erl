%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the plans' one writer, erx_fat_plan:apply/4 (docs/design-storage.md,
%% "Durability"): what it hands Write and Flush, in order, for plans whose sectors
%% are images of their own numbers, so every byte written says where it belongs.

-module(erx_fat_plan_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SECTOR, 512).

%% The image of sector N: N in its first 8 bytes and zeros after.
image(N) -> <<N:64, 0:((?SECTOR - 8) * 8)>>.

%% The calls Plan makes, in order: {write, First, Count} for each run, after checking
%% it carries the image of Holds(S) at each of its sectors S, and flush; Writes answer
%% Answer(call number) and flushes `ok`, and the last element is apply/4's answer.
calls(Plan, RunMax) -> calls(Plan, RunMax, fun(_) -> ok end, fun(S) -> S end).

calls(Plan, RunMax, Answer) -> calls(Plan, RunMax, Answer, fun(S) -> S end).

calls(Plan, RunMax, Answer, Holds) ->
    Ref = make_ref(),
    Counter = counters:new(1, []),
    Write = fun(First, Count, Bytes) ->
                    ?assertEqual(iolist_to_binary([image(Holds(S)) || S <- lists:seq(First, First + Count - 1)]), Bytes),
                    counters:add(Counter, 1, 1),
                    self() ! {Ref, {write, First, Count}},
                    Answer(counters:get(Counter, 1))
            end,
    Result = erx_fat_plan:apply(Plan, RunMax, Write, fun() -> self() ! {Ref, flush}, ok end),
    recorded(Ref) ++ [Result].

recorded(Ref) ->
    receive {Ref, Call} -> [Call | recorded(Ref)] after 0 -> [] end.

plain(Sectors) -> [{S, image(S)} || S <- Sectors].

%% A round's sectors in ascending order, each run as long as the next sector follows
%% it and RunMax allows, and a gap ending a run.
runs_are_the_longest_contiguous_stretches_test() ->
    ?assertEqual([{write, 5, 1}, {write, 10, 3}, {write, 13, 1}, {write, 20, 2}, flush, ok],
                 calls([{step, plain([20, 12, 5, 21, 10, 13, 11])}], 3)),
    ?assertEqual([{write, 5, 1}, {write, 10, 4}, {write, 20, 2}, flush, ok],
                 calls([{step, plain([20, 12, 5, 21, 10, 13, 11])}], 64)).

%% A run never crosses a gap, however long RunMax is, so no image lands at a sector
%% after one the plan did not name.
a_gap_ends_a_run_test() ->
    ?assertEqual([{write, 1, 2}, {write, 4, 1}, {write, 7, 2}, flush, ok], calls([{step, plain([1, 2, 4, 7, 8])}], 64)).

%% A FAT sector's copies after every first sector of its step, each round as runs:
%% sectors 100-102 of the first FAT, then their copies, each with its first sector's
%% image, at 200-202 and 300-302, and a data run at 50 beside the first FAT in round 0.
mirrors_follow_the_first_fat_test() ->
    Images = [{erx_fat_plan:copies(S, 100, 3), image(S)} || S <- [101, 100, 102]] ++ plain([50, 51]),
    Holds = fun(S) when S >= 100 -> 100 + S rem 100; (S) -> S end,
    ?assertEqual([{write, 50, 2}, {write, 100, 3}, {write, 200, 3}, {write, 300, 3}, flush, ok],
                 calls([{step, Images}], 64, fun(_) -> ok end, Holds)).

%% Each step's writes, then its flush, before the next step's.
a_flush_follows_every_step_test() ->
    ?assertEqual([{write, 1, 2}, flush, {write, 3, 1}, flush, {write, 9, 1}, flush, ok],
                 calls([{preparation, plain([1, 2])}, {linking, plain([3])}, {publication, plain([9])}], 64)).

%% A write that fails ends the plan with its answer: no later write, no flush.
a_failed_write_stops_the_plan_test() ->
    Answer = fun(2) -> {error, eio}; (_) -> ok end,
    ?assertEqual([{write, 1, 1}, {write, 3, 1}, {error, eio}],
                 calls([{preparation, plain([1, 3, 5])}, {linking, plain([7])}], 64, Answer)).

%% A sector a round names twice is written twice, in the plan's order, so its later
%% image is sent last.
a_sector_named_twice_lands_its_last_image_test() ->
    Ref = make_ref(),
    Write = fun(First, Count, Bytes) -> self() ! {Ref, {First, Count, Bytes}}, ok end,
    ok = erx_fat_plan:apply([{step, [{4, <<2:4096>>}, {5, image(5)}, {4, <<1:4096>>}]}], 64, Write, fun() -> ok end),
    ?assertEqual([{4, 1, <<2:4096>>}, {4, 2, <<1:4096, (image(5))/binary>>}], recorded(Ref)).
