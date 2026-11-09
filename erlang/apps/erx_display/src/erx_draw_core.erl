%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_draw_core).
-moduledoc """
The draw protocol's pure core (docs/design-display.md, "Draw messages" and
"The window process"): what one window's connection holds, and what each
message a client writes to `draw` does to it.

The **state** is a connection's images, the pixel bytes they are charged
against the window's quota, and the compose operation the next drawing
message uses. Image 0 is the window's image, made by `new/1` and `resize/2`
from the size the policy gave the window; it is never charged, freed or
made a font cache. Every other image is a client's, allocated by `b` and
charged its pixel bytes rounded up to 4 KiB, plus, once `i` makes it a font
cache, 16 bytes for each glyph record rounded up to 4 KiB. A font cache's
records are held as a binary of 16-byte records, so what the core holds is
what it charged. The charge is a function of the image, and `replace/3`
alone puts an image into the state, recharging it, so freeing or remaking a
font cache gives back exactly what it took. An image costs at least 4 KiB,
so the quota bounds the number of images and the state with it.

`step/2` takes a state and one message decoded by `erx_draw_codec` and
returns the next state and the operations `erx_memdraw` performs for it, or
the errno of the refusal: `enoent` for an id the connection does not hold or
a screen other than 0, `eexist` for a `b` of an id it holds, `enomem` past
the quota, and `einval` for the rest the design lists. For a message the
codec has framed, the checks are devdraw's in devdraw's order, so a message
failing two of them fails with the errno devdraw reports. `plan/2` folds a
whole write: it decodes each message with the depths of the images as
planned so far, so an image a `b` allocated earlier in the same write has
its depth and one an `f` freed has none, and it returns the state and the
operations, or the errno and the offset of the first message that failed.
The caller performs the operations only after `plan/2` returns, so a write
is checked whole before any of it is applied.

**Operations** name images by id; the window process maps ids to its
`erx_memdraw` images while it applies them, in order. Every decision that
needs the connection is made here, so `erx_memdraw` needs no state of its
own beyond the images: an allocation carries its clip rectangle as devdraw
sets it, a `c` carries the replicate bit as it stands after it, each drawing
operation carries its compose operation, an `e` or `E` is an ellipse or an
arc as alpha's high bits say, and an `s` or `x` becomes the `draw` of its
background and one `draw` per glyph, with the glyph's rectangle in the font
cache as the mask, clipped to the message's clip rectangle. Those `draw`s
are the one place the core derives coordinates; a derived coordinate outside
draw(3)'s 32 bits fails the message with `einval`, so every coordinate an
operation carries is a 32-bit one. An `r` replaces what the previous one
left for reading, so a plan keeps only its write's last `read`. `i` and `O`
change only the state, `o` changes nothing, and none of the three has an
operation.
""".
-export([new/1, resize/2, step/2, plan/2]).
-export_type([state/0, quota/0, op/0, glyph/0]).

%% The compose operations of draw(2) that the core names: S, which `l`
%% uses, and SoverD, which every drawing message uses unless `O` set
%% another for it.
-define(S, 10).
-define(SOVERD, 11).
-define(MAX_OP, 11).
-define(PAGE, 4096).
-define(GLYPH_BYTES, 16).
-define(MAX_GLYPHS, 4096).
%% A write carries at most the file protocol's payload.
-define(MAX_WRITE, 65536).
%% 9front's badrect: an image's area is below this many pixels.
-define(MAX_AREA, 16#10000000).
-define(COORD_MIN, -16#80000000).
-define(COORD_MAX, 16#7fffffff).

-type image_id() :: erx_draw_codec:image_id().
-type point() :: erx_draw_codec:point().
-type rect() :: erx_draw_codec:rect().
-type errno() :: einval | enoent | eexist | enomem.
-type compose() :: 0..?MAX_OP.

-type quota() :: #{pixels := non_neg_integer(),   % pixel and glyph bytes charged to the window's images
                   side := pos_integer()}.        % the widest and tallest image

%% devdraw's FChar: the glyph's columns in the cache, its rows in the
%% cache kept to a byte each, its offset from the baseline point and its
%% advance. A font cache holds each as 16 bytes (glyph/2, set_glyph/3).
-type glyph() :: {MinX :: integer(), MaxX :: integer(), MinY :: byte(), MaxY :: byte(),
                  Left :: -128..127, Width :: byte()}.
%% Only what a later message reads: the rectangle (r, y, Y and an x's
%% background), the depth (the codec's framing and the charge), the
%% replicate bit (c) and the glyph records (l, s, x).
-type image() :: #{r := rect(), depth := 1..32, repl := boolean(),
                   glyphs := none | {Ascent :: byte(), Records :: binary()}}.
-type state() :: #{images := #{image_id() => image()},
                   bytes := non_neg_integer(),  % the sum of charge/1 over the images
                   op := compose(),
                   quota := quota()}.

-type op() ::
        {alloc, image_id(), Chan :: 0..16#ffffffff, R :: rect(), Clipr :: rect(), Repl :: boolean(),
         Color :: 0..16#ffffffff}
      | {clip, image_id(), Repl :: boolean(), Clipr :: rect()}
      | {free, image_id()}
      %% Compose Src through Mask onto R of Dst; Clip is Dst's own clip
      %% rectangle, or the one a string message sets in its place.
      | {draw, Dst :: image_id(), R :: rect(), Src :: image_id(), Sp :: point(),
         Mask :: image_id() | opaque, Mp :: point(), compose(), Clip :: dst | rect()}
      | {ellipse, Dst :: image_id(), Src :: image_id(), C :: point(), A :: non_neg_integer(),
         B :: non_neg_integer(), Thick :: non_neg_integer(), Sp :: point(), compose()}
      | {fill_ellipse, Dst :: image_id(), Src :: image_id(), C :: point(), A :: non_neg_integer(),
         B :: non_neg_integer(), Sp :: point(), compose()}
      | {arc, Dst :: image_id(), Src :: image_id(), C :: point(), A :: non_neg_integer(),
         B :: non_neg_integer(), Thick :: non_neg_integer(), Sp :: point(), Alpha :: integer(),
         Phi :: integer(), compose()}
      | {fill_arc, Dst :: image_id(), Src :: image_id(), C :: point(), A :: non_neg_integer(),
         B :: non_neg_integer(), Sp :: point(), Alpha :: integer(), Phi :: integer(), compose()}
      | {line, Dst :: image_id(), P0 :: point(), P1 :: point(), End0 :: 0..16#ffffffff,
         End1 :: 0..16#ffffffff, Thick :: non_neg_integer(), Src :: image_id(), Sp :: point(), compose()}
      | {poly, Dst :: image_id(), [point(), ...], End0 :: 0..16#ffffffff, End1 :: 0..16#ffffffff,
         Thick :: non_neg_integer(), Src :: image_id(), Sp :: point(), compose()}
      | {fill_poly, Dst :: image_id(), [point(), ...], Wind :: integer(), Src :: image_id(),
         Sp :: point(), compose()}
      | {load, image_id(), rect(), Pixels :: binary()}
      | {read, image_id(), rect()}
      | flush.

-doc """
A connection holding only image 0, the window's image with rectangle R and
channel Chan, under Quota. The caller is trusted: Chan must be a channel
draw(3) knows.
""".
-spec new(#{r := rect(), chan := 0..16#ffffffff, quota := quota()}) -> state().
new(#{r := R, chan := Chan, quota := #{pixels := Pixels, side := Side} = Quota})
  when is_integer(Pixels), Pixels >= 0, is_integer(Side), Side > 0 ->
    {ok, Depth} = chan_depth(Chan),
    #{images => #{0 => #{r => R, depth => Depth, repl => false, glyphs => none}}, bytes => 0, op => ?SOVERD,
      quota => Quota}.

-doc """
The connection after the policy gave its window the rectangle R: the window
process makes a new image 0 of that size, which replaces the old one here.
The client's images are kept.
""".
-spec resize(state(), rect()) -> state().
resize(#{images := #{0 := Window} = Images} = State, R) ->
    State#{images := Images#{0 := Window#{r := R, repl := false}}}.

-doc """
The state and operations after the whole write Bytes, or the errno and the
offset from the write's start of the message that failed. A write longer
than the file protocol's payload fails whole at offset 0.
""".
-spec plan(state(), binary()) -> {ok, state(), [op()]} | {error, errno(), Offset :: non_neg_integer()}.
plan(_State, Bytes) when byte_size(Bytes) > ?MAX_WRITE -> {error, einval, 0};
plan(State, Bytes) -> plan(State, Bytes, 0, []).

plan(State, <<>>, _Offset, Planned) ->
    {ok, State, last_read_only(lists:append(lists:reverse(Planned)))};
plan(State, Bytes, Offset, Planned) ->
    maybe
        {ok, Msg, Rest} ?= erx_draw_codec:decode(Bytes, depth_fun(State)),
        {ok, Next, Ops} ?= step(State, Msg),
        plan(Next, Rest, Offset + byte_size(Bytes) - byte_size(Rest), [Ops | Planned])
    else
        {error, Errno, _Field} -> {error, Errno, Offset};
        {error, Errno} -> {error, Errno, Offset}
    end.

%% Each r replaces what the one before it left for the next read of draw,
%% and a read comes only after the write, so only the last read counts.
last_read_only(Ops) ->
    case lists:partition(fun is_read/1, Ops) of
        {[], _} -> Ops;
        {Reads, Others} -> Others ++ [lists:last(Reads)]
    end.

is_read({read, _, _}) -> true;
is_read(_Op) -> false.

%% The codec's view of the connection: an image's depth, or none.
depth_fun(#{images := Images}) ->
    fun(Id) ->
            case Images of
                #{Id := #{depth := Depth}} -> Depth;
                #{} -> none
            end
    end.

-doc "The state and operations after one decoded message, or the errno of its refusal.".
-spec step(state(), erx_draw_codec:msg()) -> {ok, state(), [op()]} | {error, errno()}.
step(State, {alloc, Id, Screen, _Refresh, Chan, Repl, R, Clipr, Color}) ->
    maybe
        ok ?= absent(State, Id),
        ok ?= check(Screen =:= 0, enoent),
        {ok, Depth} ?= chan_depth(Chan),
        ok ?= check(supported_chan(Chan, Depth), einval),
        ok ?= check_image_rect(R, quota(State)),
        Clip = alloc_clip(Repl =/= 0, R, Clipr),
        {ok, Next} ?= replace(State, Id, #{r => R, depth => Depth, repl => Repl =/= 0, glyphs => none}),
        {ok, Next, [{alloc, Id, Chan, R, Clip, Repl =/= 0, Color}]}
    end;
step(State, {clip, Dst, Repl, Clipr}) ->
    maybe
        {ok, #{repl := Was} = Image} ?= lookup(State, Dst),
        %% devdraw sets the bit and never clears it.
        Now = Was orelse Repl =/= 0,
        {ok, Next} ?= replace(State, Dst, Image#{repl := Now}),
        {ok, Next, [{clip, Dst, Now, Clipr}]}
    end;
step(State, {draw, Dst, Src, Mask, R, Sp, Mp}) ->
    maybe
        ok ?= held(State, [Dst, Src, Mask]),
        {Op, Next} = take_op(State),
        {ok, Next, [{draw, Dst, R, Src, Sp, Mask, Mp, Op, dst}]}
    end;
step(State, {Kind, Dst, Src, C, A, B, Thick, Sp, Alpha, Phi}) when Kind =:= ellipse; Kind =:= fill_ellipse ->
    maybe
        ok ?= held(State, [Dst, Src]),
        ok ?= check(A >= 0 andalso B >= 0 andalso Thick >= 0, einval),
        {Op, Next} = take_op(State),
        {ok, Next, [ellipse(Kind, Dst, Src, C, A, B, Thick, Sp, arc(Alpha), Phi, Op)]}
    end;
step(_State, {free, 0}) -> {error, einval};
step(State, {free, Id}) ->
    maybe
        ok ?= held(State, [Id]),
        {ok, Next} ?= replace(State, Id, none),
        {ok, Next, [{free, Id}]}
    end;
step(_State, {font, 0, _N, _Ascent}) -> {error, einval};
step(State, {font, Id, N, Ascent}) ->
    maybe
        {ok, Image} ?= lookup(State, Id),
        ok ?= check(N >= 1 andalso N =< ?MAX_GLYPHS, einval),
        %% devdraw drops a font cache's old records when it remakes it,
        %% and zeroes the new ones.
        {ok, Next} ?= replace(State, Id, Image#{glyphs := {Ascent, <<0:(N * ?GLYPH_BYTES)/unit:8>>}}),
        {ok, Next, []}
    end;
step(State, {glyph, Cache, Src, Index, {X0, Y0, X1, Y1} = R, Sp, Left, Width}) ->
    maybe
        {ok, #{glyphs := {Ascent, Records}} = Font} ?= font_cache(State, Cache),
        ok ?= held(State, [Src]),
        ok ?= check(Index < glyph_count(Records), einval),
        Glyph = {X0, X1, Y0 band 16#ff, Y1 band 16#ff, signed_byte(Left), Width},
        {ok, Next} ?= replace(State, Cache, Font#{glyphs := {Ascent, set_glyph(Records, Index, Glyph)}}),
        {ok, Next, [{draw, Cache, R, Src, Sp, opaque, Sp, ?S, dst}]}
    end;
step(State, {line, Dst, P0, P1, End0, End1, Thick, Src, Sp}) ->
    maybe
        ok ?= held(State, [Dst]),
        ok ?= check(Thick >= 0, einval),
        ok ?= held(State, [Src]),
        {Op, Next} = take_op(State),
        {ok, Next, [{line, Dst, P0, P1, End0, End1, Thick, Src, Sp, Op}]}
    end;
step(State, {origin, Id, _Rmin, _Scr}) ->
    maybe
        ok ?= held(State, [Id]),
        {ok, State, []}
    end;
step(State, {op, Op}) when Op =< ?MAX_OP -> {ok, State#{op := Op}, []};
step(_State, {op, _Op}) -> {error, einval};
step(State, {poly, Dst, End0, End1, Thick, Src, Sp, Points}) ->
    maybe
        ok ?= held(State, [Dst]),
        ok ?= check(Thick >= 0, einval),
        ok ?= held(State, [Src]),
        {Op, Next} = take_op(State),
        {ok, Next, [{poly, Dst, Points, End0, End1, Thick, Src, Sp, Op}]}
    end;
step(State, {fill_poly, Dst, Wind, _Ignore, Src, Sp, Points}) ->
    maybe
        ok ?= held(State, [Dst, Src]),
        {Op, Next} = take_op(State),
        {ok, Next, [{fill_poly, Dst, Points, Wind, Src, Sp, Op}]}
    end;
step(State, {read, Id, R}) ->
    maybe
        ok ?= inside(State, Id, R),
        {ok, State, [{read, Id, R}]}
    end;
step(State, {string, Dst, Src, Font, P, Clipr, Sp, Indices}) ->
    string(State, #{dst => Dst, src => Src, font => Font, clip => Clipr}, P, Sp, none, Indices);
step(State, {string_bg, Dst, Src, Font, P, Clipr, Sp, Bg, Bp, Indices}) ->
    string(State, #{dst => Dst, src => Src, font => Font, clip => Clipr}, P, Sp, {Bg, Bp}, Indices);
step(State, flush) -> {ok, State, [flush]};
step(State, {Load, Id, R, Pixels}) when Load =:= load; Load =:= cload ->
    %% The codec framed the pixels at the image's depth, so it holds the
    %% image; a cload's pixels are already decoded and load as a load's.
    maybe
        ok ?= inside(State, Id, R),
        {ok, State, [{load, Id, R, Pixels}]}
    end.

%% An s or x: the background's draw for an x, then one draw per glyph, the
%% glyph's rectangle of the cache as the mask, each advancing the point and
%% the source point by the glyph's width, all clipped to the message's clip
%% rectangle in place of the destination's, as devdraw's drawchar does.
%% Str holds what every one of those draws shares.
string(State, #{dst := Dst, src := Src, font := FontId} = Str, P, Sp, Background, Indices) ->
    maybe
        ok ?= held(State, [Dst, Src]),
        {ok, #{glyphs := {Ascent, Records}, r := FontR}} ?= font_cache(State, FontId),
        ok ?= held(State, [Bg || {Bg, _} <- [Background]]),
        ok ?= check(lists:all(fun(Index) -> Index < glyph_count(Records) end, Indices), einval),
        Glyphs = [glyph(Records, Index) || Index <- Indices],
        {Op, Next} = take_op(State),
        Shared = Str#{op => Op, ascent => Ascent},
        Ops = background(Shared, Background, P, height(FontR), Glyphs) ++ glyph_draws(Shared, Glyphs, P, Sp),
        ok ?= check(lists:all(fun in_coords/1, Ops), einval),
        {ok, Next, Ops}
    end.

%% x's background: from p raised by the ascent, as wide as the glyphs'
%% advances and as tall as the font cache, filled from bg with bp at its
%% upper left corner.
background(_Str, none, _P, _Height, _Glyphs) -> [];
background(#{dst := Dst, op := Op, clip := Clip, ascent := Ascent}, {Bg, Bp}, {X, Y}, Height, Glyphs) ->
    Top = Y - Ascent,
    Advance = lists:sum([Width || {_, _, _, _, _, Width} <- Glyphs]),
    [{draw, Dst, {X, Top, X + Advance, Top + Height}, Bg, Bp, opaque, {0, 0}, Op, Clip}].

glyph_draws(_Str, [], _P, _Sp) -> [];
glyph_draws(#{dst := Dst, src := Src, font := Font, op := Op, clip := Clip, ascent := Ascent} = Str,
            [{MinX, MaxX, MinY, MaxY, Left, Width} | Glyphs], {X, Y}, {SX, SY}) ->
    X0 = X + Left,
    Y0 = Y - (Ascent - MinY),
    Draw = {draw, Dst, {X0, Y0, X0 + (MaxX - MinX), Y0 + (MaxY - MinY)}, Src, {SX + Left, SY + MinY}, Font,
            {MinX, MinY}, Op, Clip},
    [Draw | glyph_draws(Str, Glyphs, {X + Width, Y}, {SX + Width, SY})].

%% A derived draw's rectangle and source point are 32-bit coordinates; its
%% mask point and clip rectangle came from the cache's records and the
%% message, which hold only those.
in_coords({draw, _Dst, {X0, Y0, X1, Y1}, _Src, {SX, SY}, _Mask, _Mp, _Op, _Clip}) ->
    lists:all(fun(V) -> V >= ?COORD_MIN andalso V =< ?COORD_MAX end, [X0, Y0, X1, Y1, SX, SY]).

%% An e or E as the shape alpha's high bit picks: the whole ellipse or an arc.
ellipse(Kind, Dst, Src, C, A, B, Thick, Sp, Arc, Phi, Op) ->
    case {Kind, Arc} of
        {ellipse, none} -> {ellipse, Dst, Src, C, A, B, Thick, Sp, Op};
        {fill_ellipse, none} -> {fill_ellipse, Dst, Src, C, A, B, Sp, Op};
        {ellipse, Alpha} -> {arc, Dst, Src, C, A, B, Thick, Sp, Alpha, Phi, Op};
        {fill_ellipse, Alpha} -> {fill_arc, Dst, Src, C, A, B, Sp, Alpha, Phi, Op}
    end.

%% alpha's high bit marks an arc; devdraw then clears it unless the next
%% bit is set too, which leaves alpha a negative 32-bit angle.
arc(Alpha) when Alpha band 16#80000000 =:= 0 -> none;
arc(Alpha) when Alpha band 16#40000000 =:= 0 -> Alpha band 16#7fffffff;
arc(Alpha) -> Alpha - 16#100000000.

%% The operation for this drawing message; the next one uses SoverD.
take_op(#{op := Op} = State) -> {Op, State#{op := ?SOVERD}}.

lookup(#{images := Images}, Id) ->
    case Images of
        #{Id := Image} -> {ok, Image};
        #{} -> {error, enoent}
    end.

held(_State, []) -> ok;
held(State, [Id | Ids]) ->
    maybe
        {ok, _} ?= lookup(State, Id),
        held(State, Ids)
    end.

absent(#{images := Images}, Id) ->
    case Images of
        #{Id := _} -> {error, eexist};
        #{} -> ok
    end.

%% An image the connection holds that i made a font cache.
font_cache(State, Id) ->
    case lookup(State, Id) of
        {ok, #{glyphs := {_, _}} = Font} -> {ok, Font};
        {ok, _} -> {error, einval};
        {error, _} = Error -> Error
    end.

%% R lies within the image, as devdraw's rectinrect asks of r, y and Y, and
%% is not empty, as loadmemimage's and unloadmemimage's badrect asks.
inside(State, Id, {X0, Y0, X1, Y1}) ->
    maybe
        {ok, #{r := {IX0, IY0, IX1, IY1}}} ?= lookup(State, Id),
        check(IX0 =< X0 andalso X0 < X1 andalso X1 =< IX1 andalso IY0 =< Y0 andalso Y0 < Y1 andalso Y1 =< IY1,
              einval)
    end.

%% An image's rectangle passes 9front's badrect and the quota's side.
check_image_rect({X0, Y0, X1, Y1} = R, #{side := Side}) ->
    DX = X1 - X0,
    DY = Y1 - Y0,
    check(DX > 0 andalso DY > 0 andalso DX * DY < ?MAX_AREA andalso DX =< Side andalso DY =< Side andalso
          badrect_bounds(R), einval).

%% 9front's badrect: x within 2^25 either side of 0 and x's width times
%% each y within 2^28, so libmemdraw's int arithmetic cannot overflow.
badrect_bounds({X0, Y0, X1, Y1}) ->
    DX = X1 - X0,
    lists:all(fun(X) -> X >= -(1 bsl 25) andalso X < 1 bsl 25 end, [X0, X1]) andalso
        lists:all(fun(Y) -> DX * Y >= -(1 bsl 28) andalso DX * Y < 1 bsl 28 end, [Y0, Y1]).

%% devdraw's b: clipr as given for a replicated image, otherwise clipped
%% to r by rectclip, which leaves a rectangle disjoint from r as it was.
alloc_clip(true, _R, Clipr) -> Clipr;
alloc_clip(false, {RX0, RY0, RX1, RY1}, {X0, Y0, X1, Y1} = Clipr) ->
    case X0 < RX1 andalso RX0 < X1 andalso Y0 < RY1 andalso RY0 < Y1 of
        true -> {max(X0, RX0), max(Y0, RY0), min(X1, RX1), min(Y1, RY1)};
        false -> Clipr
    end.

%% Put New at Id in place of what is there, none to free it: the one way an
%% image enters or leaves the state, so the bytes charged always equal the
%% charges of the images held, and the one place the quota is checked.
replace(#{images := Images, bytes := Bytes, quota := #{pixels := Quota}} = State, Id, New) ->
    Old = maps:get(Id, Images, none),
    Charged = Bytes - charge(Old) + charge(New),
    maybe
        ok ?= check(Charged =< Quota, enomem),
        Next = case New of
                   none -> maps:remove(Id, Images);
                   #{} -> Images#{Id => New}
               end,
        {ok, State#{images := Next, bytes := Charged}}
    end.

%% An image's charge: its pixel bytes and its glyph records, each rounded
%% up to 4 KiB. Image 0 is the window's and charged nothing.
charge(none) -> 0;
charge(#{r := {_, Y0, _, Y1} = R, depth := Depth, glyphs := Glyphs}) ->
    Pixels = erx_draw_image:bytes_per_line(R, Depth) * (Y1 - Y0),
    Records = case Glyphs of
                  none -> 0;
                  {_, Binary} -> byte_size(Binary)
              end,
    pages(Pixels) + pages(Records).

pages(Bytes) -> (Bytes + ?PAGE - 1) div ?PAGE * ?PAGE.

%% A font cache's records, 16 bytes each: the columns as two 32-bit
%% integers, then the rows, left and width a byte each, then padding.
glyph_count(Records) -> byte_size(Records) div ?GLYPH_BYTES.

glyph(Records, Index) ->
    <<MinX:32/signed, MaxX:32/signed, MinY, MaxY, Left:8/signed, Width, _:4/binary>> =
        binary:part(Records, Index * ?GLYPH_BYTES, ?GLYPH_BYTES),
    {MinX, MaxX, MinY, MaxY, Left, Width}.

set_glyph(Records, Index, {MinX, MaxX, MinY, MaxY, Left, Width}) ->
    <<Before:(Index * ?GLYPH_BYTES)/binary, _:?GLYPH_BYTES/binary, After/binary>> = Records,
    %% Built whole, so the binary is exactly the records' size.
    iolist_to_binary([Before, <<MinX:32/signed, MaxX:32/signed, MinY, MaxY, Left:8/signed, Width, 0:32>>, After]).

height({_, Y0, _, Y1}) -> Y1 - Y0.

quota(#{quota := Quota}) -> Quota.

signed_byte(Byte) when Byte >= 16#80 -> Byte - 16#100;
signed_byte(Byte) -> Byte.

check(true, _Errno) -> ok;
check(false, Errno) -> {error, Errno}.

%% 9front's chantodepth: each byte of a channel descriptor, from the low
%% one, is a type below NChan (7) in its high nibble and 1 to 8 bits in its
%% low nibble, and the bits sum to a valid depth.
chan_depth(Chan) -> chan_depth(Chan, 0).

chan_depth(0, Depth) ->
    case valid_depth(Depth) of
        true -> {ok, Depth};
        false -> {error, einval}
    end;
chan_depth(Chan, Depth) ->
    Byte = Chan band 16#ff,
    Bits = Byte band 16#f,
    case Byte bsr 4 < 7 andalso Bits >= 1 andalso Bits =< 8 of
        true -> chan_depth(Chan bsr 8, Depth + Bits);
        false -> {error, einval}
    end.

%% A depth below 8 divides 8; one of 8 or more is a multiple of 8.
valid_depth(Depth) when Depth > 0, Depth < 8 -> 8 rem Depth =:= 0;
valid_depth(Depth) when Depth >= 8 -> Depth rem 8 =:= 0;
valid_depth(_Depth) -> false.

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
