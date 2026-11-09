%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% erx_draw_core, the draw protocol's pure core (docs/design-display.md,
%% "Draw messages" and "Verification and testing"), run by
%% test/host/erx_draw_core_test.rb on stock's emulator.
%%
%% The exploration: every connection reachable from a new one over a small
%% alphabet of the messages that change it (ids 1 and 2, two channels, the
%% replicate bit, font caches of 1 and 257 glyphs, frees, a glyph and an
%% operation), under a quota of three pages and a side of 4, so that the quota
%% and the side are reached. From each of those connections, every message
%% of a larger alphabet: every message type, ids 0 to 2, and rectangles at
%% and across the side and across each image's edges. Each step must agree
%% with the refusal table written out here from the design, in devdraw's
%% order (expected_errno/2), and a step that succeeds must keep the derived
%% facts: the bytes charged are those of the images it holds and within the
%% quota, image 0 is unchanged, the images held change only as the message
%% says, and every drawing operation carries the operation set before it and
%% leaves SoverD.
-module(erx_draw_core_tests).
-include_lib("eunit/include/eunit.hrl").
-export([prelude/0, charged/1, in_coords/1]).

-define(PAGE, 4096).
-define(K1, 16#31).
-define(K8, 16#38).
-define(ARGB32, 16#48081828).
-define(WINDOW, {0, 0, 4, 4}).
-define(SMALL_QUOTA, #{pixels => 3 * ?PAGE, side => 4}).
-define(SOVERD, 11).

new(Quota) -> erx_draw_core:new(#{r => ?WINDOW, chan => ?ARGB32, quota => Quota}).

%% The messages that change a connection, from which the explored
%% connections are reached.
changes() ->
    [{alloc, 1, 0, 0, ?K8, 0, {0, 0, 4, 4}, {0, 0, 2, 2}, 0},
     {alloc, 1, 0, 0, ?ARGB32, 1, {-1, -1, 1, 1}, {5, 5, 6, 6}, 0},
     {alloc, 2, 0, 0, ?ARGB32, 0, {0, 0, 4, 4}, {9, 9, 10, 10}, 0},
     {free, 1}, {free, 2},
     {font, 1, 1, 3}, {font, 1, 257, 3}, {font, 2, 1, 2},
     {glyph, 1, 0, 0, {0, 0, 2, 3}, {0, 0}, 255, 2},
     {clip, 1, 1, {0, 0, 3, 3}},
     {op, 0}].

%% Rectangles at and across the side of 4 and the edges of the images the
%% connections hold, empty and inverted ones included.
rects() ->
    [{0, 0, 4, 4}, {0, 0, 5, 4}, {0, 0, 4, 5}, {-1, 0, 4, 4}, {-1, -1, 1, 1}, {-1, -1, 0, 0},
     {0, 0, 1, 1}, {1, 1, 1, 1}, {2, 2, 1, 1}].

ids() -> [0, 1, 2].

%% Every message type over ids 0 to 2.
alphabet() ->
    Chans = [?K1, ?K8, ?ARGB32, 16#33, 16#78, 0],
    AllocRects = [{0, 0, 4, 4}, {0, 0, 5, 4}, {0, 0, 4, 5}, {-1, -1, 1, 1}, {1, 1, 1, 2}, {2, 2, 1, 3}],
    Alpha = [0, 16#80000005, 16#c0000000],
    Axes = [{0, 0, 0}, {-1, 0, 0}, {0, -1, 0}, {0, 0, -1}, {2, 1, 1}],
    lists:append(
      [[{alloc, Id, Screen, 0, Chan, Repl, R, Clipr, 0}
        || Id <- ids(), Screen <- [0, 1], Chan <- Chans, Repl <- [0, 1], R <- AllocRects,
           Clipr <- [{0, 0, 2, 2}, {9, 9, 10, 10}]],
       [{clip, Id, Repl, {0, 0, 2, 2}} || Id <- ids(), Repl <- [0, 1]],
       [{draw, D, S, M, {0, 0, 2, 2}, {0, 0}, {1, 1}} || D <- ids(), S <- ids(), M <- ids()],
       [{Kind, D, S, {1, 1}, A, B, T, {0, 0}, Al, 90}
        || Kind <- [ellipse, fill_ellipse], D <- ids(), S <- [0, 1], {A, B, T} <- Axes, Al <- Alpha],
       [{free, Id} || Id <- ids()],
       [{font, Id, N, 3} || Id <- ids(), N <- [0, 1, 256, 257, 4096, 4097]],
       [{glyph, C, S, Index, {0, 0, 2, 3}, {0, 0}, 255, 2} || C <- ids(), S <- ids(), Index <- [0, 1, 256]],
       [{line, D, {0, 0}, {3, 3}, 0, 0, T, S, {0, 0}} || D <- ids(), T <- [-1, 0], S <- ids()],
       [{origin, Id, {0, 0}, {0, 0}} || Id <- ids()],
       [{op, Op} || Op <- [0, 11, 12, 255]],
       [{poly, D, 0, 0, T, S, {0, 0}, [{0, 0}, {1, 1}]} || D <- ids(), T <- [-1, 1], S <- ids()],
       [{fill_poly, D, 0, {0, 0}, S, {0, 0}, [{0, 0}, {1, 1}, {2, 0}]} || D <- ids(), S <- ids()],
       [{read, Id, R} || Id <- ids(), R <- rects()],
       [{string, D, S, F, {0, 3}, {0, 0, 4, 4}, Sp, Is}
        || D <- [0, 1], S <- [0, 1], F <- ids(), Is <- [[], [0], [0, 255], [256]],
           Sp <- [{0, 0}, {16#7fffffff, 0}]],
       [{string_bg, 0, 0, F, P, {0, 0, 4, 4}, Sp, Bg, {0, 0}, Is}
        || F <- ids(), Bg <- ids(), P <- [{0, 3}, {16#7fffffff, 3}, {0, -16#80000000}],
           Sp <- [{0, 0}, {16#7fffffff, 0}], Is <- [[0, 0], [256]]],
       [flush],
       [{load, Id, R, <<>>} || Id <- ids(), R <- rects()],
       [{cload, Id, R, <<>>} || Id <- ids(), R <- rects()]]).

%% Every connection reachable from a new one over changes().
reachable() -> reachable([new(?SMALL_QUOTA)], #{}).

reachable([], Seen) -> maps:keys(Seen);
reachable([State | States], Seen) when is_map_key(State, Seen) -> reachable(States, Seen);
reachable([State | States], Seen) ->
    Next = [N || Msg <- changes(), {ok, N, _} <- [erx_draw_core:step(State, Msg)]],
    reachable(Next ++ States, Seen#{State => true}).

exploration_test_() ->
    {timeout, 600,
     fun() ->
             States = reachable(),
             Outcomes = [explore(State, Msg) || State <- States, Msg <- alphabet()],
             %% Every refusal and success is reached, the quota's from both b and i.
             Seen = lists:usort(Outcomes),
             [?assert(lists:member(Outcome, Seen))
              || Outcome <- [{alloc, enomem}, {font, enomem}, {alloc, eexist}, {alloc, enoent}, {alloc, einval},
                             {alloc, ok}, {font, ok}, {glyph, einval}, {string, einval}, {string_bg, einval},
                             {string_bg, ok}, {read, einval}, {load, ok}, {cload, ok}]]
     end}.

explore(State, Msg) ->
    Name = name(Msg),
    Expected = expected_errno(State, Msg),
    case erx_draw_core:step(State, Msg) of
        {error, Errno} ->
            ?assertEqual({Msg, Expected}, {Msg, Errno}),
            {Name, Errno};
        {ok, Next, Ops} ->
            ?assertEqual({Msg, Expected}, {Msg, ok}),
            check_invariants(State, Msg, Next, Ops),
            {Name, ok}
    end.

name(Msg) when is_atom(Msg) -> Msg;
name(Msg) -> element(1, Msg).

check_invariants(State, Msg, Next, Ops) ->
    #{images := Images, bytes := Bytes, quota := #{pixels := Quota}} = Next,
    ?assertEqual({Msg, charged(Images)}, {Msg, Bytes}),
    ?assert(Bytes =< Quota),
    %% Image 0 keeps the window's size and channel and is never a font
    %% cache; only c changes it.
    Window = [r, depth, glyphs],
    ?assertEqual(maps:with(Window, maps:get(0, maps:get(images, State))), maps:with(Window, maps:get(0, Images))),
    Before = lists:sort(maps:keys(maps:get(images, State))),
    After = lists:sort(maps:keys(Images)),
    case Msg of
        {alloc, Id, _, _, _, _, _, _, _} -> ?assertEqual(lists:sort([Id | Before]), After);
        {free, Id} -> ?assertEqual(Before -- [Id], After);
        _ -> ?assertEqual(Before, After)
    end,
    check_op(State, Msg, Next, Ops),
    [?assert(in_coords(Op)) || Op <- Ops].

%% A drawing message carries the operation set before it and leaves SoverD;
%% no other message touches it but O.
check_op(#{op := Was}, Msg, #{op := Now}, Ops) ->
    Drawing = lists:member(name(Msg), [draw, ellipse, fill_ellipse, line, poly, fill_poly, string, string_bg]),
    case Msg of
        {op, Op} -> ?assertEqual(Op, Now);
        _ when Drawing ->
            ?assertEqual(?SOVERD, Now),
            [?assertEqual(Was, element(tuple_size(Op), Op)) || Op <- Ops, element(1, Op) =/= draw],
            [?assertEqual(Was, element(8, Op)) || {draw, _, _, _, _, _, _, _, _} = Op <- Ops];
        _ -> ?assertEqual(Was, Now)
    end.

in_coords(Op) when is_tuple(Op) ->
    lists:all(fun(V) -> not is_integer(V) orelse V >= -16#80000000 andalso V =< 16#7fffffff end,
              lists:flatten([tuple_to_list(F) || F <- tuple_to_list(Op), is_tuple(F)]));
in_coords(flush) -> true.

%% The bytes images are charged, from the design: pixel bytes rounded up to
%% a page, and a font cache's 16-byte records rounded up to a page; image 0
%% is the window's and not charged.
charged(Images) ->
    lists:sum([pages(erx_draw_image:bytes_per_line(R, D) * (Y1 - Y0)) + pages(16 * glyph_count(G))
               || Id := #{r := {_, Y0, _, Y1} = R, depth := D, glyphs := G} <- Images, Id =/= 0]).

glyph_count(none) -> 0;
glyph_count({_, Records}) -> byte_size(Records) div 16.

pages(Bytes) -> (Bytes + ?PAGE - 1) div ?PAGE * ?PAGE.

%% The refusal table of docs/design-display.md, "Draw messages", each
%% message's checks in devdraw's order.
expected_errno(#{images := Images, bytes := Bytes, quota := #{pixels := Quota, side := Side}, op := _}, Msg) ->
    Held = fun(Id) -> is_map_key(Id, Images) end,
    Font = fun(Id) -> case Images of #{Id := #{glyphs := G}} -> glyph_count(G); #{} -> 0 end end,
    Inside = fun(Id, {X0, Y0, X1, Y1}) ->
                     #{r := {A, B, C, D}} = maps:get(Id, Images),
                     A =< X0 andalso X0 =< X1 andalso X1 =< C andalso B =< Y0 andalso Y0 =< Y1 andalso Y1 =< D
             end,
    first(case Msg of
              {alloc, Id, Screen, _, Chan, _, {X0, Y0, X1, Y1}, _, _} ->
                  Depth = depth(Chan),
                  [{eexist, Held(Id)}, {enoent, Screen =/= 0}, {einval, Depth =:= 0},
                   {einval, X1 - X0 =< 0 orelse Y1 - Y0 =< 0 orelse X1 - X0 > Side orelse Y1 - Y0 > Side},
                   {enomem, fun() -> Bytes + pages(erx_draw_image:bytes_per_line({X0, Y0, X1, Y1}, Depth)
                                                   * (Y1 - Y0)) > Quota end}];
              {clip, Id, _, _} -> [{enoent, not Held(Id)}];
              {draw, D, S, M, _, _, _} -> unheld([D, S, M], Held);
              {K, D, S, _, A, B, T, _, _, _} when K =:= ellipse; K =:= fill_ellipse ->
                  unheld([D, S], Held) ++ [{einval, A < 0 orelse B < 0 orelse T < 0}];
              {free, Id} -> [{einval, Id =:= 0}, {enoent, not Held(Id)}];
              {font, Id, N, _} ->
                  [{einval, Id =:= 0}, {enoent, not Held(Id)}, {einval, N < 1 orelse N > 4096},
                   {enomem, fun() -> Bytes - pages(16 * Font(Id)) + pages(16 * N) > Quota end}];
              {glyph, C, S, Index, _, _, _, _} ->
                  [{enoent, not Held(C)}, {einval, Font(C) =:= 0}, {enoent, not Held(S)}, {einval, Index >= Font(C)}];
              {line, D, _, _, _, _, T, S, _} -> unheld([D], Held) ++ [{einval, T < 0}] ++ unheld([S], Held);
              {origin, Id, _, _} -> unheld([Id], Held);
              {op, Op} -> [{einval, Op > 11}];
              {poly, D, _, _, T, S, _, _} -> unheld([D], Held) ++ [{einval, T < 0}] ++ unheld([S], Held);
              {fill_poly, D, _, _, S, _, _} -> unheld([D, S], Held);
              {read, Id, R} -> [{enoent, not Held(Id)}, {einval, fun() -> not Inside(Id, R) end}];
              {string, D, S, F, P, _, Sp, Is} ->
                  string_checks(D, S, F, none, Is, Held, Font)
                      ++ [{einval, fun() -> not string_in_coords(Images, F, P, Sp, Is, false) end}];
              {string_bg, D, S, F, P, _, Sp, Bg, _, Is} ->
                  string_checks(D, S, F, Bg, Is, Held, Font)
                      ++ [{einval, fun() -> not string_in_coords(Images, F, P, Sp, Is, true) end}];
              flush -> [];
              {_, Id, R, _} -> [{enoent, not Held(Id)}, {einval, fun() -> not Inside(Id, R) end}]
          end).

string_checks(D, S, F, Bg, Is, Held, Font) ->
    unheld([D, S, F], Held) ++ [{einval, Font(F) =:= 0}] ++ unheld([Bg || Bg =/= none], Held)
        ++ [{einval, lists:any(fun(I) -> I >= Font(F) end, Is)}].

%% Every coordinate a string's draws derive is a 32-bit one: x's
%% background, from p raised by the ascent to the end of the glyphs'
%% advances, for an x only, and each glyph's rectangle and source point off
%% the advancing point and source point. The records are read from their
%% 16-byte layout.
string_in_coords(Images, F, {X, Y}, {SX, SY}, Is, WithBackground) ->
    #{glyphs := {Ascent, Records}, r := {_, FY0, _, FY1}} = maps:get(F, Images),
    Glyphs = [binary:part(Records, I * 16, 12) || I <- Is],
    {Coords, Advance} =
        lists:mapfoldl(fun(<<MinX:32/signed, MaxX:32/signed, MinY, MaxY, L:8/signed, W>>, Sum) ->
                               GX = X + Sum + L,
                               GY = Y - Ascent + MinY,
                               {[GX, GY, GX + MaxX - MinX, GY + MaxY - MinY, SX + Sum + L, SY + MinY], Sum + W}
                       end, 0, Glyphs),
    Background = case WithBackground of
                     true -> [X, Y - Ascent, X + Advance, Y - Ascent + FY1 - FY0];
                     false -> []
                 end,
    lists:all(fun(V) -> V >= -16#80000000 andalso V =< 16#7fffffff end, Background ++ lists:append(Coords)).

unheld(Ids, Held) -> [{enoent, not Held(Id)} || Id <- Ids].

first([]) -> ok;
first([{Errno, Fails} | Checks]) when is_function(Fails) -> first([{Errno, Fails()} | Checks]);
first([{Errno, true} | _]) -> Errno;
first([{_, false} | Checks]) -> first(Checks).

%% The depths of the channels the alphabet names, 0 for those draw(3) refuses.
depth(?K1) -> 1;
depth(?K8) -> 8;
depth(?ARGB32) -> 32;
depth(_) -> 0.

%% The cases outside the small quota: badrect's area bound, which only a
%% side of 16,384 reaches, and pixels charged over several pages.
large_quota_test() ->
    State = new(#{pixels => 64 * 1024 * 1024, side => 16384}),
    ?assertEqual({error, einval}, erx_draw_core:step(State, alloc(1, ?K8, {0, 0, 16384, 16384}))),
    %% 8,192 by 8,191 bytes is 16,382 pages, two short of the quota.
    {ok, Big, _} = erx_draw_core:step(State, alloc(1, ?K8, {0, 0, 8192, 8191})),
    ?assertEqual(8192 * 8191, maps:get(bytes, Big)),
    {ok, Full, _} = erx_draw_core:step(Big, alloc(2, ?K8, {0, 0, 8192, 1})),
    ?assertEqual(64 * 1024 * 1024, maps:get(bytes, Full)),
    {ok, Odd, _} = erx_draw_core:step(State, alloc(1, ?ARGB32, {0, 0, 33, 33})),
    ?assertEqual(2 * ?PAGE, maps:get(bytes, Odd)),
    ?assertEqual({error, enomem}, erx_draw_core:step(Big, alloc(2, ?K8, {0, 0, 8193, 1}))),
    {ok, Freed, [{free, 1}]} = erx_draw_core:step(Big, {free, 1}),
    ?assertEqual(0, maps:get(bytes, Freed)).

alloc(Id, Chan, R) -> {alloc, Id, 0, 0, Chan, 0, R, R, 0}.

%% A b's clip rectangle as devdraw sets it, and c's sticky replicate bit.
clip_test() ->
    State = new(?SMALL_QUOTA),
    {ok, _, [{alloc, 1, _, _, {1, 1, 4, 4}, false, _}]} =
        erx_draw_core:step(State, {alloc, 1, 0, 0, ?K8, 0, {0, 0, 4, 4}, {1, 1, 9, 9}, 0}),
    {ok, _, [{alloc, 1, _, _, {5, 5, 6, 6}, false, _}]} =
        erx_draw_core:step(State, {alloc, 1, 0, 0, ?K8, 0, {0, 0, 4, 4}, {5, 5, 6, 6}, 0}),
    {ok, Repl, [{alloc, 1, _, _, {1, 1, 9, 9}, true, _}]} =
        erx_draw_core:step(State, {alloc, 1, 0, 0, ?K8, 1, {0, 0, 4, 4}, {1, 1, 9, 9}, 0}),
    ?assertMatch({ok, _, [{clip, 1, true, {0, 0, 1, 1}}]}, erx_draw_core:step(Repl, {clip, 1, 0, {0, 0, 1, 1}})).

%% An arc as alpha's high bits say; a string as the draws of its glyphs.
shapes_and_strings_test() ->
    State = new(#{pixels => 16 * ?PAGE, side => 64}),
    E = fun(Kind, Alpha) -> {Kind, 0, 0, {1, 1}, 2, 1, 1, {0, 0}, Alpha, 90} end,
    ?assertMatch({ok, _, [{ellipse, 0, 0, {1, 1}, 2, 1, 1, {0, 0}, ?SOVERD}]},
                 erx_draw_core:step(State, E(ellipse, 5))),
    ?assertMatch({ok, _, [{arc, 0, 0, _, 2, 1, 1, _, 5, 90, _}]}, erx_draw_core:step(State, E(ellipse, 16#80000005))),
    ?assertMatch({ok, _, [{fill_arc, 0, 0, _, 2, 1, _, -16#40000000, 90, _}]},
                 erx_draw_core:step(State, E(fill_ellipse, 16#c0000000))),
    Write = << <<(erx_draw_codec:encode(M))/binary>>
               || M <- [{alloc, 1, 0, 0, ?K8, 0, {0, 0, 8, 10}, {0, 0, 8, 10}, 0}, {font, 1, 2, 7},
                        {glyph, 1, 0, 1, {2, 1, 5, 9}, {3, 3}, 255, 4}, {op, 3},
                        {string_bg, 0, 0, 1, {10, 20}, {0, 0, 4, 4}, {6, 6}, 0, {1, 2}, [1, 1]}] >>,
    {ok, _, Ops} = erx_draw_core:plan(State, Write),
    ?assertEqual([{alloc, 1, ?K8, {0, 0, 8, 10}, {0, 0, 8, 10}, false, 0},
                  {draw, 1, {2, 1, 5, 9}, 0, {3, 3}, opaque, {3, 3}, 10, dst},
                  {draw, 0, {10, 13, 18, 23}, 0, {1, 2}, opaque, {0, 0}, 3, {0, 0, 4, 4}},
                  {draw, 0, {9, 14, 12, 22}, 0, {5, 7}, 1, {2, 1}, 3, {0, 0, 4, 4}},
                  {draw, 0, {13, 14, 16, 22}, 0, {9, 7}, 1, {2, 1}, 3, {0, 0, 4, 4}}], Ops).

%% plan/2 frames each y with the depths as planned so far: an image a b
%% allocated earlier in the write, at every depth, an image freed before
%% its load, and image 0.
plan_test_() ->
    [fun() -> plan_case(Chan, Depth) end || {Chan, Depth} <- [{?K1, 1}, {16#32, 2}, {16#34, 4}, {?K8, 8},
                                                             {16#3838, 16}, {16#383838, 24}, {?ARGB32, 32}]].

plan_case(Chan, Depth) ->
    State = new(?SMALL_QUOTA),
    R = {-3, 0, 1, 2},
    Pixels = binary:copy(<<16#a5>>, erx_draw_image:bytes_per_line(R, Depth) * 2),
    B = erx_draw_codec:encode({alloc, 1, 0, 0, Chan, 0, R, R, 0}),
    Y = erx_draw_codec:encode({load, 1, R, Pixels}),
    {ok, Planned, [{alloc, 1, Chan, R, R, false, 0}, {load, 1, R, Pixels}]} =
        erx_draw_core:plan(State, <<B/binary, Y/binary>>),
    ?assertEqual(pages(byte_size(Pixels)), maps:get(bytes, Planned)),
    F = erx_draw_codec:encode({free, 1}),
    ?assertEqual({error, enoent, byte_size(B) + byte_size(F)},
                 erx_draw_core:plan(State, <<B/binary, F/binary, Y/binary>>)),
    Window = binary:copy(<<1>>, 4 * 4 * 4),
    {ok, _, [{load, 0, ?WINDOW, Window}]} =
        erx_draw_core:plan(State, erx_draw_codec:encode({load, 0, ?WINDOW, Window})).

%% A y cut across two writes fails the first at the y's offset, a write
%% over the file protocol's payload fails whole, and no write that fails
%% changes the connection it was planned from.
plan_failures_test() ->
    State = new(?SMALL_QUOTA),
    V = erx_draw_codec:encode(flush),
    Y = erx_draw_codec:encode({load, 0, ?WINDOW, binary:copy(<<0>>, 64)}),
    Cut = binary:part(Y, 0, byte_size(Y) - 1),
    ?assertEqual({error, einval, byte_size(V)}, erx_draw_core:plan(State, <<V/binary, Cut/binary>>)),
    ?assertEqual({error, einval, 0}, erx_draw_core:plan(State, binary:copy(V, 65537))),
    {ok, State, Flushes} = erx_draw_core:plan(State, binary:copy(V, 65536)),
    ?assertEqual(65536, length(Flushes)),
    ?assertEqual({ok, State, []}, erx_draw_core:plan(State, <<>>)).

%% An l keeps a glyph's rows to a byte each and its left as a signed byte,
%% as devdraw's FChar does, and an s draws the glyph from those.
glyph_record_test() ->
    State = new(#{pixels => 16 * ?PAGE, side => 64}),
    Write = << <<(erx_draw_codec:encode(M))/binary>>
               || M <- [{alloc, 1, 0, 0, ?K8, 0, {0, 0, 8, 10}, {0, 0, 8, 10}, 0}, {font, 1, 1, 7},
                        {glyph, 1, 0, 0, {0, -1, 2, 300}, {0, 0}, 200, 3},
                        {string, 0, 0, 1, {10, 20}, {0, 0, 4, 4}, {6, 6}, [0]}] >>,
    {ok, _, [_Alloc, _Copy, Glyph]} = erx_draw_core:plan(State, Write),
    %% Rows 255 and 44, left -56: the glyph's rectangle is inverted, which
    %% erx_memdraw draws as nothing.
    ?assertEqual({draw, 0, {-46, 268, -44, 57}, 0, {-50, 261}, 1, {0, 255}, ?SOVERD, {0, 0, 4, 4}}, Glyph).

%% Each r replaces what the one before it left for reading, so a plan keeps
%% only its write's last read, after the operations before it.
last_read_test() ->
    State = new(?SMALL_QUOTA),
    Write = << <<(erx_draw_codec:encode(M))/binary>>
               || M <- [{read, 0, {0, 0, 4, 4}}, flush, {read, 0, {0, 0, 1, 1}}, {op, 0}] >>,
    {ok, Planned, Ops} = erx_draw_core:plan(State, Write),
    ?assertEqual({0, [flush, {read, 0, {0, 0, 1, 1}}]}, {maps:get(op, Planned), Ops}).

%% A resized window's image 0 takes the new rectangle and keeps the
%% client's images; a load inside the new rectangle passes.
resize_test() ->
    {ok, State, _} = erx_draw_core:step(new(?SMALL_QUOTA), alloc(1, ?K8, {0, 0, 2, 2})),
    Load = {load, 0, {0, 0, 8, 8}, <<>>},
    ?assertEqual({error, einval}, erx_draw_core:step(State, Load)),
    Resized = erx_draw_core:resize(State, {0, 0, 8, 8}),
    ?assertMatch({ok, _, [{load, 0, _, _}]}, erx_draw_core:step(Resized, Load)),
    ?assertEqual(maps:get(1, maps:get(images, State)), maps:get(1, maps:get(images, Resized))).

%% The connection the fuzz target plans from: ids 1 to 7 allocated at the
%% depths 1, 2, 4, 8, 16, 24 and 32.
prelude() ->
    Chans = [?K1, 16#32, 16#34, ?K8, 16#3838, 16#383838, ?ARGB32],
    Write = << <<(erx_draw_codec:encode({alloc, Id, 0, 0, Chan, 0, {-2, -2, 6, 6}, {0, 0, 4, 4}, 0}))/binary>>
               || {Id, Chan} <- lists:zip(lists:seq(1, 7), Chans) >>,
    {ok, State, _} = erx_draw_core:plan(new(#{pixels => 64 * ?PAGE, side => 64}), Write),
    State.
