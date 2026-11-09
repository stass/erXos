%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_draw_ref_tests).
-moduledoc """
The draw reference's cases (test/erlang/erx_draw_ref.erl): each operation,
channel conversion, replication and clip rule against pixels computed by hand.
With an opaque mask and the alphas chosen below, every factor an operation
uses is a whole number, so each expected channel is (Fs*S + Fd*D)/255 rounded,
the textbook Porter-Duff value; the partial-mask case works through
libmemdraw's rounded factor.
""".
-include_lib("eunit/include/eunit.hrl").

-define(RGBA32, erx_draw_ref:chan([{red, 8}, {green, 8}, {blue, 8}, {alpha, 8}])).
-define(RGB24, erx_draw_ref:chan([{red, 8}, {green, 8}, {blue, 8}])).
-define(XRGB32, erx_draw_ref:chan([{ignore, 8}, {red, 8}, {green, 8}, {blue, 8}])).
-define(RGB16, erx_draw_ref:chan([{red, 5}, {green, 6}, {blue, 5}])).
-define(GREY8, erx_draw_ref:chan([{grey, 8}])).
-define(GREY4, erx_draw_ref:chan([{grey, 4}])).
-define(GREY2, erx_draw_ref:chan([{grey, 2}])).
-define(GREY1, erx_draw_ref:chan([{grey, 1}])).
-define(GREYA16, erx_draw_ref:chan([{grey, 8}, {alpha, 8}])).
-define(CMAP8, erx_draw_ref:chan([{map, 8}])).
-define(ONE, {0, 0, 1, 1}).
-define(SIDE, 1024).
-define(WIDE, {-100, -100, 100, 100}).
%% The source and destination of the operator cases, premultiplied: source
%% alpha 1/3, destination alpha 3/5.
-define(SRC, 16#55330055).   % r 85, g 51, b 0, a 85
-define(DST, 16#00669999).   % r 0, g 102, b 153, a 153

%% A r8g8b8a8 pixel's bytes: alpha in the low byte.
px(R, G, B, A) -> <<A, B, G, R>>.

alloc(Id, Chan, R, Color) -> {alloc, Id, 0, 0, Chan, 0, R, R, Color}.
alloc_repl(Id, Chan, R, Color) -> {alloc, Id, 0, 0, Chan, 1, R, ?WIDE, Color}.
draw(R, Sp, Mp) -> {draw, 1, 2, 3, R, Sp, Mp}.

%% The messages applied in order, every one accepted, and image 1's pixels
%% in Rect.
run(Messages, Rect) ->
    State = lists:foldl(fun(Message, Acc) -> {ok, Next} = erx_draw_ref:step(Message, Acc), Next end,
                        erx_draw_ref:new({0, 0, 1, 1}, ?RGBA32, ?SIDE), Messages),
    {reply, Pixels, _} = erx_draw_ref:step({read, 1, Rect}, State),
    Pixels.

%% Image 1 (Dst), 2 (Src) and an opaque mask 3, then one draw at the origin
%% with operation Op.
compose(Op, DstChan, Dst, SrcChan, Src) ->
    run([alloc(1, DstChan, ?ONE, Dst), alloc(2, SrcChan, ?ONE, Src), alloc(3, ?GREY8, ?ONE, 16#ffffffff),
         {op, Op}, draw(?ONE, {0, 0}, {0, 0})], ?ONE).

%%% The twelve operations

operators_test_() ->
    Cases = [{0, px(0, 0, 0, 0)},          % Clear
             {1, px(0, 68, 102, 102)},     % DoutS: d(1-sa) = 2/3 d
             {2, px(34, 20, 0, 34)},       % SoutD: s(1-da) = 2/5 s
             {3, px(34, 88, 102, 136)},    % SxorD: 2/5 s + 2/3 d
             {4, px(0, 34, 51, 51)},       % DinS: d sa = 1/3 d
             {5, px(0, 102, 153, 153)},    % D
             {6, px(34, 54, 51, 85)},      % DatopS: 2/5 s + 1/3 d
             {7, px(34, 122, 153, 187)},   % DoverS: 2/5 s + d
             {8, px(51, 31, 0, 51)},       % SinD: s da = 3/5 s
             {9, px(51, 99, 102, 153)},    % SatopD: 3/5 s + 2/3 d
             {10, px(85, 51, 0, 85)},      % S
             {11, px(85, 119, 102, 187)}], % SoverD: s + 2/3 d
    [{integer_to_list(Op), ?_assertEqual(Want, compose(Op, ?RGBA32, ?DST, ?RGBA32, ?SRC))}
     || {Op, Want} <- Cases].

%% A mask of 128: Fs = 128, Fd = 255 - round(85*128/255) = 255 - 43 = 212.
%% r (128*85)/255 = 42.7, g (128*51 + 212*102)/255 = 110.4,
%% b (212*153)/255 = 127.2, a (128*85 + 212*153)/255 = 169.9.
partial_mask_test() ->
    ?assertEqual(px(43, 110, 127, 170),
                 run([alloc(1, ?RGBA32, ?ONE, ?DST), alloc(2, ?RGBA32, ?ONE, ?SRC),
                      alloc(3, ?GREY8, ?ONE, 16#808080ff), draw(?ONE, {0, 0}, {0, 0})], ?ONE)).

%% A mask with alpha is its alpha (64 here, though its grey is 255); one
%% without is its grey: RGB2K(0, 255, 0) = 78478290 >> 19 = 149.
mask_channel_test() ->
    Over = fun(MaskChan, MaskColor) ->
        run([alloc(1, ?RGBA32, ?ONE, 16#000000ff), alloc(2, ?RGBA32, ?ONE, 16#ffffffff),
             alloc(3, MaskChan, ?ONE, MaskColor), draw(?ONE, {0, 0}, {0, 0})], ?ONE)
    end,
    ?assertEqual(px(64, 64, 64, 255), Over(?RGBA32, 16#ffffff40)),
    ?assertEqual(px(149, 149, 149, 255), Over(?RGB24, 16#00ff00ff)).

%%% Channels

%% The fill colour r 0xc0, g 0x80, b 0x40, a 0x20 in each channel: narrowed
%% by truncation, grey RGB2K(192, 128, 64) = 73316736 >> 19 = 139, and below
%% 8 bits every pixel of the byte filled. Map entry 0xc0 is (204, 0, 204).
fill_test_() ->
    Cases = [{?GREY8, 16#c08040ff, <<139>>},
             {?GREY4, 16#c08040ff, <<16#88>>},           % 139 >> 4 = 8, twice
             {?GREY2, 16#c08040ff, <<2#10101010>>},      % 139 >> 6 = 2, four times
             {?GREY1, 16#c08040ff, <<16#ff>>},
             {?RGB16, 16#c08040ff, <<16#c408:16/little>>}, % 24 << 11 | 32 << 5 | 8
             {?RGB24, 16#c08040ff, <<16#40, 16#80, 16#c0>>},
             {?XRGB32, 16#c08040ff, <<16#40, 16#80, 16#c0, 0>>},
             {?RGBA32, 16#c0804020, px(16#c0, 16#80, 16#40, 16#20)},
             {?GREYA16, 16#c0804020, <<16#20, 139>>},
             {?CMAP8, 16#cc00ccff, <<16#c0>>}],
    [?_assertEqual(Want, run([alloc(1, Chan, ?ONE, Color)], ?ONE)) || {Chan, Color, Want} <- Cases].

%% Each channel read as a source, copied with S onto r8g8b8a8: widened by
%% replicating its bits (5 bits 24 = 11000 to 11000110 = 198, 6 bits 32 to
%% 130, 5 bits 8 to 66), alpha 255 where it has none.
widen_test_() ->
    Cases = [{?GREY8, 16#c08040ff, px(139, 139, 139, 255)},
             {?GREY4, 16#c08040ff, px(16#88, 16#88, 16#88, 255)},
             {?GREY2, 16#c08040ff, px(16#aa, 16#aa, 16#aa, 255)},
             {?GREY1, 16#c08040ff, px(255, 255, 255, 255)},
             {?RGB16, 16#c08040ff, px(198, 130, 66, 255)},
             {?RGB24, 16#c08040ff, px(16#c0, 16#80, 16#40, 255)},
             {?XRGB32, 16#c08040ff, px(16#c0, 16#80, 16#40, 255)},
             {?RGBA32, 16#c0804020, px(16#c0, 16#80, 16#40, 16#20)},
             {?GREYA16, 16#c0804020, px(139, 139, 139, 16#20)},
             {?CMAP8, 16#cc00ccff, px(204, 0, 204, 255)}],
    [?_assertEqual(Want, compose(10, ?RGBA32, 16#000000ff, Chan, Color)) || {Chan, Color, Want} <- Cases].

%% A grey destination composes greys: source grey 139 onto 100 through a mask
%% of 128 (Fs 128, Fd 127) is (128*139 + 127*100)/255 = 119.6, 120, where
%% composing r, g and b first and taking the grey after gives 119.
grey_destination_test() ->
    ?assertEqual(<<120>>,
                 run([alloc(1, ?GREY8, ?ONE, 16#646464ff), alloc(2, ?RGB24, ?ONE, 16#c08040ff),
                      alloc(3, ?GREY8, ?ONE, 16#808080ff), draw(?ONE, {0, 0}, {0, 0})], ?ONE)).

%% A colour drawn onto a map image is its nearest entry: white is entry 255.
map_destination_test() ->
    ?assertEqual(<<255>>, compose(10, ?CMAP8, 16#000000ff, ?RGBA32, 16#ffffffff)).

%% Below 8 bits the leftmost pixel is in the high bits: pixels 2 to 4 of a
%% k1 byte are 0011 1000.
sub_byte_destination_test() ->
    ?assertEqual(<<16#38>>,
                 run([alloc(1, ?GREY1, {0, 0, 8, 1}, 16#000000ff), alloc_repl(2, ?GREY8, ?ONE, 16#ffffffff),
                      alloc_repl(3, ?GREY8, ?ONE, 16#ffffffff), draw({2, 0, 5, 1}, {0, 0}, {0, 0})],
                     {0, 0, 8, 1})).

depth_test() ->
    ?assertEqual(32, erx_draw_ref:depth(?RGBA32)),
    ?assertEqual(16, erx_draw_ref:depth(?RGB16)),
    ?assertEqual(2, erx_draw_ref:depth(?GREY2)),
    ?assertEqual(0, erx_draw_ref:depth(erx_draw_ref:chan([{grey, 3}]))),            % 8 rem 3
    ?assertEqual(0, erx_draw_ref:depth(erx_draw_ref:chan([{red, 8}, {grey, 4}]))),  % 12 rem 8
    ?assertEqual(0, erx_draw_ref:depth(16#88)),                                       % type 8
    ?assertEqual(0, erx_draw_ref:depth(16#3800)),                                     % a zero byte
    ?assertEqual(0, erx_draw_ref:depth(0)).

%%% Replication and clipping

-define(RED, 16#ff0000ff).
-define(BLUE, 16#0000ffff).
-define(BLACK, 16#000000ff).

%% A 2x1 replicated source of red then blue, its clip rectangle Clipr, drawn
%% with S onto a black 5x1 r8g8b8a8 through an opaque replicated mask; Extra
%% runs before the draw.
stripes(Clipr, R, Sp, Extra) ->
    Two = {0, 0, 2, 1},
    run([alloc(1, ?RGBA32, {0, 0, 5, 1}, ?BLACK), {alloc, 2, 0, 0, ?RGBA32, 1, Two, Clipr, 16#00000000},
         {load, 2, Two, <<(px(255, 0, 0, 255))/binary, (px(0, 0, 255, 255))/binary>>},
         alloc_repl(3, ?GREY8, ?ONE, 16#ffffffff)] ++ Extra ++ [{op, 10}, draw(R, Sp, {0, 0})],
        {0, 0, 5, 1}).

pixels(Colors) ->
    << <<(case C of r -> px(255, 0, 0, 255); b -> px(0, 0, 255, 255); k -> px(0, 0, 0, 255) end)/binary>>
       || C <- Colors >>.

replication_test_() ->
    Row = {0, 0, 5, 1},
    [?_assertEqual(pixels([r, b, r, b, r]), stripes(?WIDE, Row, {0, 0}, [])),
     ?_assertEqual(pixels([b, r, b, r, b]), stripes(?WIDE, Row, {1, 0}, [])),
     ?_assertEqual(pixels([b, r, b, r, b]), stripes(?WIDE, Row, {-1, 0}, [])),
     ?_assertEqual(pixels([r, b, r, b, r]), stripes(?WIDE, Row, {-4, -7}, []))].

clipping_test_() ->
    Row = {0, 0, 5, 1},
    [%% The source's clip rectangle bounds a replicated source.
     ?_assertEqual(pixels([r, b, r, k, k]), stripes({0, 0, 3, 1}, Row, {0, 0}, [])),
     %% The destination's clip rectangle bounds the draw.
     ?_assertEqual(pixels([k, b, r, k, k]), stripes(?WIDE, Row, {0, 0}, [{clip, 1, 0, {1, 0, 3, 1}}])),
     %% Clearing the source's replicate bit is ignored: c only sets it.
     ?_assertEqual(pixels([r, b, r, b, r]), stripes(?WIDE, Row, {0, 0}, [{clip, 2, 0, ?WIDE}])),
     %% A rectangle far outside the destination draws nothing.
     ?_assertEqual(pixels([k, k, k, k, k]), stripes(?WIDE, {1000000, 0, 2000000, 1}, {0, 0}, [])),
     %% A rectangle partly outside draws its part inside, the source aligned
     %% with its corner: pixel 0 is source point 3, blue.
     ?_assertEqual(pixels([b, r, b, k, k]), stripes(?WIDE, {-3, 0, 3, 1}, {0, 0}, []))].

%% Without its replicate bit the source is its rectangle only, and the mask
%% too.
unreplicated_test_() ->
    Over = fun(SrcR, MaskR) ->
        run([alloc(1, ?RGBA32, {0, 0, 5, 1}, ?BLACK), alloc(2, ?RGBA32, SrcR, ?RED),
             alloc(3, ?GREY8, MaskR, 16#ffffffff), draw({0, 0, 5, 1}, {0, 0}, {0, 0})], {0, 0, 5, 1})
    end,
    [?_assertEqual(pixels([r, r, k, k, k]), Over({0, 0, 2, 1}, ?WIDE)),
     ?_assertEqual(pixels([k, r, r, r, k]), Over(?WIDE, {1, 0, 4, 1})),
     ?_assertEqual(pixels([k, r, k, k, k]), Over({0, 0, 2, 1}, {1, 0, 4, 1}))].

%% A draw reads the images as they were: copying [r, b, k] one pixel right
%% onto itself gives [r, r, b], not [r, r, r].
overlap_test() ->
    Three = {0, 0, 3, 1},
    ?assertEqual(pixels([r, r, b]),
                 run([alloc(1, ?RGBA32, Three, ?BLACK), {load, 1, {0, 0, 2, 1}, pixels([r, b])},
                      alloc_repl(3, ?GREY8, ?ONE, 16#ffffffff), {op, 10},
                      {draw, 1, 1, 3, {1, 0, 3, 1}, {0, 0}, {0, 0}}], Three)).

%%% y, Y and r

%% Loading pixels 3 to 9 of a k1 row sets only those bits: the row reads
%% 0001 1111 1100 0000, and reading 3 to 9 returns the same two bytes, edge
%% bits included.
sub_byte_load_test() ->
    Messages = [alloc(1, ?GREY1, {0, 0, 16, 1}, ?BLACK), {load, 1, {3, 0, 10, 1}, <<16#ff, 16#ff>>}],
    ?assertEqual(<<16#1f, 16#c0>>, run(Messages, {0, 0, 16, 1})),
    ?assertEqual(<<16#1f, 16#c0>>, run(Messages, {3, 0, 10, 1})).

%% A Y message decoded by erx_draw_codec loads like y.
compressed_load_test() ->
    R = {0, 0, 4, 2},
    Pixels = << <<(px(V, V, V, 255))/binary>> || V <- [1, 2, 3, 4, 5, 6, 7, 8] >>,
    Depth = fun(1) -> 32; (_) -> none end,
    {ok, Message, <<>>} = erx_draw_codec:decode(erx_draw_codec:encode({cload, 1, R, Pixels}), Depth),
    ?assertMatch({cload, 1, R, _}, Message),
    ?assertEqual(Pixels, run([alloc(1, ?RGBA32, R, ?BLACK), Message], R)).

%%% Refusals and the operation's lifetime

refusals_test() ->
    S0 = erx_draw_ref:new({0, 0, 4, 4}, ?RGBA32, ?SIDE),
    {ok, S} = erx_draw_ref:step(alloc(1, ?GREY8, {0, 0, 2, 2}, ?BLACK), S0),
    Refused = fun(Message) -> {error, Errno} = erx_draw_ref:step(Message, S), Errno end,
    ?assertEqual(eexist, Refused(alloc(1, ?GREY8, ?ONE, ?BLACK))),
    ?assertEqual(enoent, Refused({alloc, 2, 7, 0, ?GREY8, 0, ?ONE, ?ONE, ?BLACK})),
    ?assertEqual(einval, Refused(alloc(2, erx_draw_ref:chan([{grey, 3}]), ?ONE, ?BLACK))),
    ?assertEqual(einval, Refused({free, 0})),
    ?assertEqual(enoent, Refused({free, 9})),
    ?assertEqual(einval, Refused({op, 12})),
    ?assertEqual(enoent, Refused({draw, 1, 9, 1, ?ONE, {0, 0}, {0, 0}})),
    ?assertEqual(einval, Refused({load, 1, {1, 1, 3, 2}, <<0, 0>>})),     % outside the image
    ?assertEqual(einval, Refused({load, 1, {0, 0, 2, 1}, <<0>>})),        % short
    ?assertEqual(einval, Refused({read, 1, {-1, 0, 1, 1}})),
    ?assertEqual(enoent, Refused({read, 9, ?ONE})),
    ?assertEqual(enotsup, Refused({line, 1, {0, 0}, {1, 1}, 0, 0, 0, 1, {0, 0}})),
    ?assertMatch({ok, _}, erx_draw_ref:step(flush, S)),
    ?assertMatch({ok, _}, erx_draw_ref:step({origin, 1, {0, 0}, {0, 0}}, S)),
    ?assertMatch({ok, #{images := #{0 := _}}}, erx_draw_ref:step({free, 1}, S)).

%% O applies to the next draw only: the second draw of the same half-alpha
%% source is SoverD, not S.
op_lasts_one_draw_test() ->
    Half = 16#80000080,    % r 128, a 128
    ?assertEqual(px(192, 0, 0, 192),    % S, then SoverD: 128 + 127*128/255 = 191.7
                 run([alloc(1, ?RGBA32, ?ONE, ?BLACK), alloc(2, ?RGBA32, ?ONE, Half),
                      alloc(3, ?GREY8, ?ONE, 16#ffffffff), {op, 10}, draw(?ONE, {0, 0}, {0, 0}),
                      draw(?ONE, {0, 0}, {0, 0})], ?ONE)).

%% Rectangles draw(3) refuses: an image's empty, inverted or past the quota's
%% side; a read's inverted.
bad_rectangles_test() ->
    S = erx_draw_ref:new({0, 0, 4, 4}, ?RGBA32, ?SIDE),
    Refused = fun(Message) -> {error, Errno} = erx_draw_ref:step(Message, S), Errno end,
    [?assertEqual(einval, Refused(alloc(1, ?GREY8, R, ?BLACK)))
     || R <- [{3, 0, 1, 1}, {0, 3, 1, 1}, {0, 0, 0, 1}, {0, 0, ?SIDE + 1, 1}, {-16#80000000, 0, 16#7fffffff, 1}]],
    ?assertEqual(einval, Refused({alloc, 1, 0, 0, ?GREY8, 1, {0, 0, 0, 1}, ?WIDE, ?BLACK})),
    ?assertEqual(einval, Refused({read, 0, {2, 0, 1, 1}})),
    ?assertMatch({reply, <<>>, _}, erx_draw_ref:step({read, 0, {1, 0, 1, 1}}, S)),
    ?assertError(badarg, erx_draw_ref:new({1, 0, 0, 1}, ?RGBA32, ?SIDE)).

%% The mask is read at its own point: a 3x1 mask of 0, 255, 0 read from
%% mp {1, 0} lets only pixel 0 through, where reading it at sp {0, 0} would
%% let only pixel 1; its clip rectangle bounds it as a source's does.
mask_point_test_() ->
    Over = fun(Mp, Extra) ->
        run([alloc(1, ?RGBA32, {0, 0, 3, 1}, ?BLACK), alloc_repl(2, ?RGBA32, ?ONE, ?RED),
             alloc(3, ?GREY8, {0, 0, 3, 1}, 16#000000ff), {load, 3, {0, 0, 3, 1}, <<0, 255, 0>>}] ++ Extra ++
            [draw({0, 0, 3, 1}, {0, 0}, Mp)], {0, 0, 3, 1})
    end,
    [?_assertEqual(pixels([r, k, k]), Over({1, 0}, [])),
     ?_assertEqual(pixels([k, r, k]), Over({0, 0}, [])),
     ?_assertEqual(pixels([k, k, k]), Over({0, 0}, [{clip, 3, 0, {0, 0, 1, 1}}]))].

%% Left of 0 a pixel's byte is floor(X/8): pixel -1 of a k1 image is the low
%% bit of byte -1, which the row starting at -8 holds first.
sub_byte_left_of_zero_test() ->
    ?assertEqual(<<16#01, 16#80>>,
                 run([alloc(1, ?GREY1, {-8, 0, 8, 1}, ?BLACK), {load, 1, {-1, 0, 1, 1}, <<16#ff, 16#ff>>}],
                     {-8, 0, 8, 1})).
