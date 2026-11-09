%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_draw_ref).
-moduledoc """
The slow reference of the draw protocol's compositing (docs/design-display.md,
"The pixel primitives"): images with their channel descriptors, `d` with its
mask and the twelve Porter-Duff operations of draw(2), replication, clipping,
`y`, `Y` and `r`, computed one pixel at a time and written to be read, not to
be fast. It is the oracle `erx_memdraw` is compared with pixel for pixel, so
step/2 takes the messages exactly as `erx_draw_codec:decode/2` returns them.
It draws no shapes; of the quotas it keeps only the side of an image, which
bounds the work of every message.

An image is stored as Plan 9 lays it out in memory, so that `r` returns what
`unloadmemimage` returns: each row holds the bytes that cover the image's
rectangle, pixel X at byte floor(X*Depth/8) counted from the byte of the
rectangle's left edge, little-endian for 8 bits and more, and packed from the
high bit down below 8.

A pixel is read and written as drawtest.c's getpixel and putpixel do (the
libmemdraw test of 9front and plan9port, src/libmemdraw/drawtest.c): each
channel is widened to 8 bits by replicating its bits and narrowed back by
truncating; an image of fewer than 8 bits a pixel is grey whatever its
channel types say; a map channel indexes Plan 9's default colour map; a
missing alpha is 255. The arithmetic is libmemdraw's own (draw.c's
alphacalc functions, CALC11 and CALC12, and its RGB2K), which agrees with
drawonepixel's for every premultiplied pixel and differs from it only where a
colour channel exceeds its alpha and the sum passes 257.
""".
-export([new/3, step/2, chan/1, depth/1]).
-export_type([state/0, chan_type/0]).

-type rect() :: erx_draw_codec:rect().
-type image_id() :: erx_draw_codec:image_id().
-type chan_type() :: red | green | blue | grey | alpha | map | ignore.
%% One 8-bit value per channel: red, green, blue and alpha.
-type rgba() :: {byte(), byte(), byte(), byte()}.
-type image() :: #{r := rect(), clipr := rect(), repl := boolean(),
                   chan := pos_integer(), depth := 1..32,
                   rows := #{integer() => binary()}}.
-type state() :: #{images := #{image_id() => image()}, op := 0..11, side := pos_integer()}.

%% draw(2)'s operations are four bits, one for each region of the overlap of
%% source and destination that the result keeps.
-define(SinD, 8).
-define(DinS, 4).
-define(SoutD, 2).
-define(DoutS, 1).
-define(SoverD, 11).
%% draw(3)'s colour meaning "do not fill" (DNofill).
-define(NOFILL, 16#ffffff00).

%%% The connection

-doc """
A connection whose image 0, the window, has rectangle R and channel Chan,
its pixels zero, and whose images are at most Side pixels wide and tall, the
quota's side, so that every message's work is bounded by Side squared.
""".
-spec new(rect(), pos_integer(), pos_integer()) -> state().
new(R, Chan, Side) ->
    case {depth(Chan), bad_rect(R, Side)} of
        {Depth, false} when Depth > 0 ->
            #{images => #{0 => image(R, R, false, Chan, Depth)}, op => ?SoverD, side => Side};
        _ ->
            error(badarg, [R, Chan, Side])
    end.

-doc """
One decoded draw message applied to the connection: its new state, or for
`r` the pixels read and the state, or the errno devdraw's checks give. A
message the reference does not model is `enotsup`.
""".
-spec step(erx_draw_codec:msg(), state()) ->
          {ok, state()} | {reply, binary(), state()} | {error, atom()}.
step({alloc, _, Screen, _, _, _, _, _, _}, _State) when Screen =/= 0 ->
    {error, enoent};
step({alloc, Id, _, _, _, _, _, _, _}, #{images := Images}) when is_map_key(Id, Images) ->
    {error, eexist};
step({alloc, Id, _, _, Chan, Repl, R, Clipr, Color}, #{side := Side} = State) ->
    Depth = depth(Chan),
    case Depth > 0 andalso supported_chan(Chan, Depth) andalso not bad_rect(R, Side) of
        true ->
            %% devdraw intersects the clip rectangle with R unless the image
            %% replicates; that is unobservable, since every draw clips to both
            %% and `c` replaces the clip rectangle whole, so Clipr is kept.
            Image = fill(image(R, Clipr, Repl =/= 0, Chan, Depth), Color),
            {ok, put_image(Id, Image, State)};
        _ ->
            {error, einval}
    end;
step({clip, Id, Repl, Clipr}, State) ->
    with_image(Id, State, fun(Image) ->
        {ok, put_image(Id, Image#{repl := Repl =/= 0 orelse maps:get(repl, Image), clipr := Clipr}, State)}
    end);
step({draw, Dst, Src, Mask, R, Sp, Mp}, #{images := Images, op := Op} = State) ->
    case [maps:find(Id, Images) || Id <- [Dst, Src, Mask]] of
        [{ok, D}, {ok, S}, {ok, M}] ->
            {ok, put_image(Dst, draw(D, R, S, Sp, M, Mp, Op), State#{op := ?SoverD})};
        _ ->
            {error, enoent}
    end;
step({free, 0}, _State) ->
    {error, einval};
step({free, Id}, #{images := Images} = State) ->
    with_image(Id, State, fun(_) -> {ok, State#{images := maps:remove(Id, Images)}} end);
step({op, Op}, _State) when Op > ?SoverD ->
    {error, einval};
step({op, Op}, State) ->
    {ok, State#{op := Op}};
step({origin, Id, _, _}, State) ->
    with_image(Id, State, fun(_) -> {ok, State} end);
step(flush, State) ->
    {ok, State};
step({Load, Id, R, Pixels}, State) when Load =:= load; Load =:= cload ->
    with_image(Id, State, fun(Image) ->
        case not empty(R) andalso inside(R, maps:get(r, Image)) andalso
             byte_size(Pixels) =:= wire_bytes(R, Image) * height(R) of
            true -> {ok, put_image(Id, load(Image, R, Pixels), State)};
            false -> {error, einval}
        end
    end);
step({read, Id, R}, State) ->
    with_image(Id, State, fun(Image) ->
        case not empty(R) andalso inside(R, maps:get(r, Image)) of
            true -> {reply, unload(Image, R), State};
            false -> {error, einval}
        end
    end);
step(_Message, _State) ->
    {error, enotsup}.

with_image(Id, #{images := Images}, Fun) ->
    case maps:find(Id, Images) of
        {ok, Image} -> Fun(Image);
        error -> {error, enoent}
    end.

put_image(Id, Image, #{images := Images} = State) ->
    State#{images := Images#{Id => Image}}.

%% An image rectangle draw(3) refuses: empty or inverted, as badrect and
%% allocmemimage refuse it, or wider or taller than the quota's side.
bad_rect({X0, Y0, X1, Y1}, Side) ->
    X1 - X0 < 1 orelse Y1 - Y0 < 1 orelse X1 - X0 > Side orelse Y1 - Y0 > Side orelse
        not badrect_bounds({X0, Y0, X1, Y1}).

%% 9front's badrect: x within 2^25 either side of 0 and x's width times
%% each y within 2^28, so libmemdraw's int arithmetic cannot overflow.
badrect_bounds({X0, Y0, X1, Y1}) ->
    DX = X1 - X0,
    lists:all(fun(X) -> X >= -(1 bsl 25) andalso X < 1 bsl 25 end, [X0, X1]) andalso
        lists:all(fun(Y) -> DX * Y >= -(1 bsl 28) andalso DX * Y < 1 bsl 28 end, [Y0, Y1]).

%% The channels erx_memdraw draws as draw(2) defines them (design-display.md,
%% "The pixel primitives"): no type twice but x, as memsetchan asks; below
%% 8 bits a pixel one grey channel; a map channel m8 alone; and no grey
%% beside a colour. Types are draw.h's: r, g, b 0 to 2, k 3, m 5, x 6.
supported_chan(Chan, Depth) ->
    Types = chan_types(Chan),
    Named = [Type || Type <- Types, Type =/= 6],
    Colour = [Type || Type <- Types, Type =< 2],
    lists:usort(Named) =:= lists:sort(Named) andalso
        case {Depth < 8, lists:member(5, Types)} of
            {true, _} -> Types =:= [3];
            {false, true} -> Chan =:= 16#58;
            {false, false} -> not (lists:member(3, Types) andalso Colour =/= [])
        end.

chan_types(0) -> [];
chan_types(Chan) -> [(Chan band 16#ff) bsr 4 | chan_types(Chan bsr 8)].

%% loadmemimage and unloadmemimage refuse, through badrect, an empty or
%% inverted rectangle.
empty({X0, Y0, X1, Y1}) -> X1 =< X0 orelse Y1 =< Y0.

%%% Channel descriptors

-doc """
The channel descriptor of a list of channels, the first the most significant,
as draw.h's CHAN macros build it: [{red, 8}, {green, 8}, {blue, 8}] is
RGB24, `r8g8b8`.
""".
-spec chan([{chan_type(), 1..15}]) -> pos_integer().
chan(Channels) ->
    lists:foldl(fun({Type, Bits}, Acc) -> (Acc bsl 8) bor (type_code(Type) bsl 4) bor Bits end,
                0, Channels).

-doc """
A channel descriptor's bits a pixel, or 0 for one draw(3) refuses, as
libdraw's chantodepth decides: each channel a known type of 1 to 8 bits, and
the total a whole number of bytes or a divisor of 8.
""".
-spec depth(non_neg_integer()) -> 0..32.
depth(Chan) ->
    Channels = channels(Chan),
    Total = lists:sum([Bits || {_, Bits} <- Channels]),
    Known = lists:all(fun({Type, Bits}) -> Type =/= unknown andalso Bits >= 1 andalso Bits =< 8 end,
                      Channels),
    case Known andalso Total > 0 andalso
         ((Total >= 8 andalso Total rem 8 =:= 0) orelse (Total < 8 andalso 8 rem Total =:= 0)) of
        true -> Total;
        false -> 0
    end.

%% The channels of a descriptor, least significant first, as each holds the
%% next bits from the pixel's low end; a zero byte ends the descriptor.
channels(0) -> [];
channels(Chan) when Chan band 16#ff =:= 0 -> [{unknown, 0}];
channels(Chan) -> [{type((Chan bsr 4) band 15), Chan band 15} | channels(Chan bsr 8)].

type(0) -> red;
type(1) -> green;
type(2) -> blue;
type(3) -> grey;
type(4) -> alpha;
type(5) -> map;
type(6) -> ignore;
type(_) -> unknown.

type_code(red) -> 0;
type_code(green) -> 1;
type_code(blue) -> 2;
type_code(grey) -> 3;
type_code(alpha) -> 4;
type_code(map) -> 5;
type_code(ignore) -> 6.

has(Type, #{chan := Chan}) ->
    lists:keymember(Type, 1, channels(Chan)).

%%% Pixels: raw values in an image's storage

image(R, Clipr, Repl, Chan, Depth) ->
    {_, Y0, _, Y1} = R,
    Row = binary:copy(<<0>>, stored_bytes(R, Depth)),
    #{r => R, clipr => Clipr, repl => Repl, chan => Chan, depth => Depth,
      rows => maps:from_list([{Y, Row} || Y <- lists:seq(Y0, Y1 - 1)])}.

%% The bytes a stored row of R covers at Depth: from the byte that holds R's
%% left edge to the one that holds its last pixel.
stored_bytes({X0, _, X1, _}, Depth) ->
    ceil_div(X1 * Depth, 8) - floor_div(X0 * Depth, 8).

%% The byte that holds pixel X, counted from the start of the stored row.
byte_offset(X, #{r := {X0, _, _, _}, depth := Depth}) ->
    floor_div(X * Depth, 8) - floor_div(X0 * Depth, 8).

%% Below 8 bits, the shift that brings pixel X to the low end of its byte:
%% the leftmost pixel of a byte is in its high bits.
sub_byte_shift(X, Depth) ->
    8 - Depth * (floor_mod(X, 8 div Depth) + 1).

get_raw(#{rows := Rows, depth := Depth} = Image, {X, Y}) ->
    Offset = byte_offset(X, Image),
    case Depth < 8 of
        true ->
            <<_:Offset/binary, Byte, _/binary>> = maps:get(Y, Rows),
            (Byte bsr sub_byte_shift(X, Depth)) band ((1 bsl Depth) - 1);
        false ->
            <<_:Offset/binary, Value:Depth/little, _/binary>> = maps:get(Y, Rows),
            Value
    end.

put_raw(#{rows := Rows, depth := Depth} = Image, {X, Y}, Value) ->
    Offset = byte_offset(X, Image),
    Row = maps:get(Y, Rows),
    New = case Depth < 8 of
              true ->
                  <<Before:Offset/binary, Byte, After/binary>> = Row,
                  Shift = sub_byte_shift(X, Depth),
                  Mask = ((1 bsl Depth) - 1) bsl Shift,
                  <<Before/binary, ((Byte band bnot Mask) bor (Value bsl Shift)), After/binary>>;
              false ->
                  <<Before:Offset/binary, _:Depth, After/binary>> = Row,
                  <<Before/binary, Value:Depth/little, After/binary>>
          end,
    Image#{rows := Rows#{Y := New}}.

%% A raw pixel as RGBA, drawtest.c's getpixel.
-spec unpack(non_neg_integer(), image()) -> rgba().
unpack(Value, #{depth := Depth}) when Depth < 8 ->
    K = replicate(Value, Depth, 8),
    {K, K, K, 255};
unpack(Value, #{chan := Chan}) ->
    {RGBA, _} = lists:foldl(fun unpack_channel/2, {{0, 0, 0, 255}, Value}, channels(Chan)),
    RGBA.

unpack_channel({Type, Bits}, {{R, G, B, A}, Value}) ->
    Raw = Value band ((1 bsl Bits) - 1),
    V = replicate(Raw, Bits, 8),
    RGBA = case Type of
               red -> {V, G, B, A};
               green -> {R, V, B, A};
               blue -> {R, G, V, A};
               grey -> {V, V, V, A};
               alpha -> {R, G, B, V};
               map -> {MR, MG, MB} = cmap_to_rgb(Raw), {MR, MG, MB, A};
               ignore -> {R, G, B, A}
           end,
    {RGBA, Value bsr Bits}.

%% RGBA as a raw pixel, drawtest.c's putpixel: an ignored channel is 0.
-spec pack(rgba(), image()) -> non_neg_integer().
pack({R, G, B, _}, #{depth := Depth}) when Depth < 8 ->
    replicate(grey(R, G, B), 8, Depth);
pack({R, G, B, A}, #{chan := Chan}) ->
    {Value, _} = lists:foldl(
        fun({Type, Bits}, {Acc, Shift}) ->
            Channel = case Type of
                          red -> replicate(R, 8, Bits);
                          green -> replicate(G, 8, Bits);
                          blue -> replicate(B, 8, Bits);
                          grey -> replicate(grey(R, G, B), 8, Bits);
                          alpha -> replicate(A, 8, Bits);
                          map -> rgb_to_cmap(R, G, B) band ((1 bsl Bits) - 1);
                          ignore -> 0
                      end,
            {Acc bor (Channel bsl Shift), Shift + Bits}
        end, {0, 0}, channels(Chan)),
    Value.

%% drawtest.c's replbits: widen by repeating the bits, narrow by truncating.
replicate(Value, Have, Want) ->
    widen(Value band ((1 bsl Have) - 1), Have, Want).

widen(V, Have, Want) when Have < Want -> widen(V bor (V bsl Have), Have * 2, Want);
widen(V, Have, Want) -> (V bsr (Have - Want)) band ((1 bsl Want) - 1).

%% libmemdraw's RGB2K; drawtest.c's (299r+587g+114b)/1000 gives the same
%% grey for every triple.
grey(R, G, B) ->
    (156763 * R + 307758 * G + 59769 * B) bsr 19.

%% Plan 9's default colour map: libdraw's cmap2rgb, and the 4096-entry
%% inverse memdefcmap holds, the nearest entry (the first of equals) to each
%% colour whose components are multiples of 17, indexed by their high nibbles.
cmap_to_rgb(C) ->
    R = C bsr 6,
    V = (C bsr 4) band 3,
    J = (C - V + R) band 15,
    G = J bsr 2,
    B = J band 3,
    case lists:max([R, G, B]) of
        0 -> {V * 17, V * 17, V * 17};
        Den -> Num = 17 * (4 * Den + V), {R * Num div Den, G * Num div Den, B * Num div Den}
    end.

rgb_to_cmap(R, G, B) ->
    Target = [(R bsr 4) * 17, (G bsr 4) * 17, (B bsr 4) * 17],
    Distance = fun(C) ->
        {MR, MG, MB} = cmap_to_rgb(C),
        lists:sum([(X - T) * (X - T) || {X, T} <- lists:zip([MR, MG, MB], Target)])
    end,
    {_, Best} = lists:min([{Distance(C), C} || C <- lists:seq(0, 255)]),
    Best.

%%% Messages that write pixels

%% `b`'s fill, memfillcolor's: every pixel the stored rows hold, those of
%% the bytes the rectangle shares with its neighbours included, unless the
%% colour is DNofill.
fill(Image, ?NOFILL) ->
    Image;
fill(#{r := {X0, Y0, X1, Y1}, depth := Depth} = Image, Color) ->
    Value = pack({Color bsr 24, (Color bsr 16) band 255, (Color bsr 8) band 255, Color band 255}, Image),
    Left = floor_div(X0 * Depth, 8) * 8 div Depth,
    Right = ceil_div(X1 * Depth, 8) * 8 div Depth,
    lists:foldl(fun(P, Acc) -> put_raw(Acc, P, Value) end, Image, points({Left, Y0, Right, Y1})).

%% `y`: R's pixels from rows of bytesperline(R) bytes, pixel X at the byte
%% floor(X*Depth/8) counted from the byte of R's left edge.
load(#{depth := Depth} = Image, {X0, Y0, X1, Y1} = R, Pixels) ->
    Stride = wire_bytes(R, Image),
    Source = #{r => R, depth => Depth, chan => maps:get(chan, Image),
               rows => maps:from_list([{Y, binary:part(Pixels, (Y - Y0) * Stride, Stride)}
                                       || Y <- lists:seq(Y0, Y1 - 1)])},
    lists:foldl(fun(P, Acc) -> put_raw(Acc, P, get_raw(Source, P)) end, Image,
                [{X, Y} || Y <- lists:seq(Y0, Y1 - 1), X <- lists:seq(X0, X1 - 1)]).

%% `r`: the bytes that hold R, row by row, as unloadmemimage copies them, so
%% an edge byte carries its neighbours' bits too. Where bytesperline counts a
%% byte more than the row covers, left of 0, that byte is past the stored
%% row and reads 0 here; in Plan 9 it is whatever memory follows.
unload(#{rows := Rows} = Image, {X0, Y0, _, Y1} = R) ->
    Offset = byte_offset(X0, Image),
    Length = wire_bytes(R, Image),
    << <<(row_part(maps:get(Y, Rows), Offset, Length))/binary>> || Y <- lists:seq(Y0, Y1 - 1) >>.

row_part(Row, Offset, Length) ->
    Present = binary:part(Row, Offset, min(Length, byte_size(Row) - Offset)),
    <<Present/binary, 0:((Length - byte_size(Present)) * 8)>>.

%% The bytes a row of R takes in `y`, `Y` and `r`: 9front's bytesperline.
wire_bytes(R, #{depth := Depth}) ->
    erx_draw_image:bytes_per_line(R, Depth).

%%% `d`

%% Every pixel P of R that lies in Dst's rectangle and clip rectangle, and
%% whose source and mask points both lie where those images are defined, is
%% composed; the rest of Dst is unchanged. This is the rectangle libmemdraw's
%% drawclip computes, stated one pixel at a time. Every pixel is read from the
%% images as they were before the message, as libmemdraw reads a source that
%% is Dst and does not replicate; a mask that is Dst, or a replicated source
%% that is, libmemdraw reads partly after writing (TODO.md).
draw(Dst, {RX0, RY0, _, _} = R, Src, {SX, SY}, Mask, {MX, MY}, Op) ->
    Targets = case intersect(R, maps:get(r, Dst)) of
                  empty -> empty;
                  InDst -> intersect(InDst, maps:get(clipr, Dst))
              end,
    Composed = [{P, compose(Op, rgba(Src, S), rgba(Dst, P), mask_value(Mask, M), Dst)}
                || {X, Y} = P <- points(Targets),
                   {ok, S} <- [source_point(Src, {SX + X - RX0, SY + Y - RY0})],
                   {ok, M} <- [source_point(Mask, {MX + X - RX0, MY + Y - RY0})]],
    lists:foldl(fun({P, Value}, Acc) -> put_raw(Acc, P, Value) end, Dst, Composed).

%% Where a source or mask point reads from: inside the clip rectangle, and
%% inside the rectangle or, when the image replicates, wrapped into it.
source_point(#{r := R, clipr := Clipr, repl := Repl}, P) ->
    case {contains(Clipr, P), contains(R, P), Repl} of
        {false, _, _} -> none;
        {true, true, _} -> {ok, P};
        {true, false, true} -> {ok, wrap(R, P)};
        {true, false, false} -> none
    end.

%% libdraw's drawrepl.
wrap({X0, Y0, X1, Y1}, {X, Y}) ->
    {X0 + floor_mod(X - X0, X1 - X0), Y0 + floor_mod(Y - Y0, Y1 - Y0)}.

%% One destination pixel's new raw value: drawtest.c's drawonepixel with
%% libmemdraw's alphacalc for every operation. The source, through the mask,
%% and the destination are each weighted by the factor the operation gives
%% it, every channel alike, alpha included. A grey destination composes the
%% greys of both colours, as libmemdraw converts the source on reading it.
compose(Op, Source, Destination, MV, Dst) ->
    {SR, SG, SB, SA} = as_destination_stores(Source, Dst),
    {DR, DG, DB, DA} = as_destination_stores(Destination, Dst),
    Fs = source_factor(Op, MV, DA),
    Fd = destination_factor(Op, SA, MV),
    Mix = fun(SC, DC) -> sum255(Fs, SC, Fd, DC) end,
    pack({Mix(SR, DR), Mix(SG, DG), Mix(SB, DB), Mix(SA, DA)}, Dst).

rgba(Image, P) ->
    unpack(get_raw(Image, P), Image).

%% A colour in the model Dst composes in: its grey when Dst has a grey
%% channel.
as_destination_stores({R, G, B, A}, Dst) ->
    case has(grey, Dst) of
        true -> K = grey(R, G, B), {K, K, K, A};
        false -> {R, G, B, A}
    end.

%% A mask is its alpha when it has one, otherwise its grey.
mask_value(Mask, M) ->
    {R, G, B, A} = rgba(Mask, M),
    case has(alpha, Mask) of
        true -> A;
        false -> grey(R, G, B)
    end.

%% How much of the source an operation keeps: the part over the destination
%% (SinD), the part outside it (SoutD), both, or neither, the mask applied.
source_factor(Op, M, Da) ->
    case {Op band ?SinD =/= 0, Op band ?SoutD =/= 0} of
        {true, true} -> M;
        {true, false} -> mul255(M, Da);
        {false, true} -> mul255(M, 255 - Da);
        {false, false} -> 0
    end.

%% How much of the destination it keeps: under the source (DinS), outside it
%% (DoutS), both, or neither, the source's alpha taken through the mask.
destination_factor(Op, Sa, M) ->
    case {Op band ?DinS =/= 0, Op band ?DoutS =/= 0} of
        {true, true} -> 255;
        {true, false} -> mul255(Sa, M);
        {false, true} -> 255 - mul255(Sa, M);
        {false, false} -> 0
    end.

%% libmemdraw's CALC11 and CALC12: A*V/255 and (A1*V1+A2*V2)/255 rounded to
%% nearest, kept to 8 bits as the C stores them in a byte.
mul255(A, V) -> sum255(A, V, 0, 0).

sum255(A1, V1, A2, V2) ->
    T = A1 * V1 + A2 * V2 + 128,
    ((T + (T bsr 8)) bsr 8) band 255.

%%% Rectangles

intersect({AX0, AY0, AX1, AY1}, {BX0, BY0, BX1, BY1}) ->
    case {max(AX0, BX0), max(AY0, BY0), min(AX1, BX1), min(AY1, BY1)} of
        {X0, Y0, X1, Y1} when X0 < X1, Y0 < Y1 -> {X0, Y0, X1, Y1};
        _ -> empty
    end.

inside({X0, Y0, X1, Y1}, {OX0, OY0, OX1, OY1}) ->
    X0 >= OX0 andalso Y0 >= OY0 andalso X1 =< OX1 andalso Y1 =< OY1.

contains({X0, Y0, X1, Y1}, {X, Y}) ->
    X >= X0 andalso X < X1 andalso Y >= Y0 andalso Y < Y1.

points(empty) -> [];
points({X0, Y0, X1, Y1}) -> [{X, Y} || Y <- lists:seq(Y0, Y1 - 1), X <- lists:seq(X0, X1 - 1)].

height({_, Y0, _, Y1}) -> Y1 - Y0.

floor_div(A, B) when A >= 0 -> A div B;
floor_div(A, B) -> -((-A + B - 1) div B).

ceil_div(A, B) -> -floor_div(-A, B).

floor_mod(A, B) -> A - floor_div(A, B) * B.
