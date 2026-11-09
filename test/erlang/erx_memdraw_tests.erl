%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_memdraw_tests).
-moduledoc """
erx_memdraw against its oracles (docs/design-display.md, "The pixel
primitives"), run by test/host/erx_memdraw_test.rb and
tools/fuzz/erx_memdraw_y.rb on stock's emulator with the NIF built
for the host.

`diff`: random draw messages, rectangles far outside every image among
them, go through erx_draw_core to erx_memdraw and through erx_draw_ref; the
two agree on every refusal, every `r`, and every image's pixels after every
message, but for the bits of an `x` channel, which draw(3) leaves undefined.
A draw's touched rectangle lies in its rectangle and its destination, and a
draw that touched nothing changed nothing.

`y`: random and mutated image(6) payloads decode alike through
erx_draw_image:decode/3 and 9front's cloadmemimage (erx_memdraw:cload/3).

`unit`: the cases a random walk would rarely reach.
""".
-export([main/1]).

-define(NOFILL, 16#ffffff00).
-define(SIDE, 12).
-define(MESSAGES, 40).

main([Mode, Seed, Rounds]) ->
    rand:seed(exsss, list_to_integer(Seed)),
    Verdict = try run(list_to_atom(Mode), list_to_integer(Rounds)) of
                  ok -> "ok"
              catch
                  Class:Reason:Stack -> io_lib:format("FAIL ~p:~0p~n~0p", [Class, Reason, Stack])
              end,
    io:format("~s ~s~n", [Mode, Verdict]),
    halt(0).

run(diff, Rounds) ->
    repeat(Rounds, fun() -> walk(?MESSAGES, connection()) end);
run(y, Rounds) ->
    repeat(Rounds, fun y_case/0);
run(unit, _) ->
    lists:foreach(fun(Case) -> Case() end,
                  [fun new_image_padding_is_zero/0, fun far_draw_touches_the_clip/0,
                   fun empty_clip_draws_nothing/0, fun replicated_grey_alpha_mask/0, fun refusals/0]).

repeat(0, _Fun) -> ok;
repeat(N, Fun) -> Fun(), repeat(N - 1, Fun).

%%% The differential walk

connection() ->
    Chan = pick(chans()),
    X = small(),
    Y = small(),
    R = {X, Y, X + rand:uniform(?SIDE), Y + rand:uniform(?SIDE)},
    Ref = erx_draw_ref:new(R, Chan, ?SIDE),
    Core = erx_draw_core:new(#{r => R, chan => Chan, quota => #{pixels => 1 bsl 40, side => ?SIDE}}),
    {ok, Image} = erx_memdraw:alloc(Chan, R, R, false, ?NOFILL),
    %% Each image with its rectangle, which the NIF does not report.
    #{core => Core, ref => Ref, images => #{0 => {Image, R}}, log => []}.

walk(0, _Connection) -> ok;
walk(N, Connection) -> walk(N - 1, step(message(Connection), Connection)).

step(Message, #{core := Core, ref := Ref, images := Images, log := Log} = Connection) ->
    Seen = Connection#{log := [Message | Log]},
    case {erx_draw_ref:step(Message, Ref), erx_draw_core:step(Core, Message)} of
        {{error, Errno}, {error, Errno}} ->
            Seen;
        {{ok, Ref1}, {ok, Core1, Ops}} ->
            Images1 = lists:foldl(fun(Op, Acc) -> perform(Op, Acc, Seen) end, Images, Ops),
            Next = Seen#{core := Core1, ref := Ref1, images := Images1},
            same_images(Next),
            Next;
        {{reply, Pixels, Ref1}, {ok, Core1, [{read, Id, R}]}} ->
            {ok, Read} = erx_memdraw:read(element(1, maps:get(Id, Images)), R),
            same_pixels(Pixels, Read, maps:get(Id, maps:get(images, Ref1)), Seen),
            Seen#{core := Core1, ref := Ref1};
        Other ->
            error({disagree, Other, lists:reverse(Seen)})
    end.

perform({alloc, Id, Chan, R, Clipr, Repl, Color}, Images, _) ->
    {ok, Image} = erx_memdraw:alloc(Chan, R, Clipr, Repl, Color),
    Images#{Id => {Image, R}};
perform({clip, Id, Repl, Clipr}, Images, _) ->
    ok = erx_memdraw:clip(element(1, maps:get(Id, Images)), Repl, Clipr),
    Images;
perform({free, Id}, Images, _) ->
    maps:remove(Id, Images);
perform({draw, Dst, R, Src, Sp, Mask, Mp, Op, Clip}, Images, Seen) ->
    #{Dst := {D, DR}, Src := {S, _}} = Images,
    M = case Mask of opaque -> opaque; _ -> element(1, maps:get(Mask, Images)) end,
    Before = whole(D, DR),
    case erx_memdraw:draw(D, R, S, Sp, M, Mp, Op, Clip) of
        {ok, none} -> Before =:= whole(D, DR) orelse error({touched_nothing_but_changed, Seen});
        {ok, T} -> inside(T, R) andalso inside(T, DR) orelse error({touched_outside, T, Seen})
    end,
    Images;
perform({load, Id, R, Pixels}, Images, _) ->
    {ok, R} = erx_memdraw:load(element(1, maps:get(Id, Images)), R, Pixels),
    Images.

%% Every image's stored bytes agree with the reference's.
same_images(#{ref := #{images := RefImages} = Ref, images := Images} = Connection) ->
    maps:foreach(fun(Id, #{r := R} = RefImage) ->
                         {reply, Pixels, _} = erx_draw_ref:step({read, Id, R}, Ref),
                         {ok, Read} = erx_memdraw:read(element(1, maps:get(Id, Images)), R),
                         same_pixels(Pixels, Read, RefImage, Connection)
                 end, RefImages).

same_pixels(Expected, Got, #{chan := Chan, depth := Depth}, Connection) ->
    case without_x(Expected, Chan, Depth) =:= without_x(Got, Chan, Depth) of
        true -> ok;
        false -> error({pixels, Chan, Expected, Got, lists:reverse(maps:get(log, Connection))})
    end.

%% A pixel's x bits cleared: a copy keeps the source's, alphadraw writes 0.
without_x(Bytes, Chan, Depth) when Depth >= 8 ->
    Keep = keep_mask(Chan, 0, 0),
    << <<(V band Keep):Depth/little>> || <<V:Depth/little>> <= Bytes >>;
without_x(Bytes, _Chan, _Depth) ->
    Bytes.

keep_mask(0, _Shift, Mask) -> Mask;
keep_mask(Chan, Shift, Mask) ->
    Bits = Chan band 16#f,
    Field = case (Chan band 16#ff) bsr 4 of
                6 -> 0;
                _ -> ((1 bsl Bits) - 1) bsl Shift
            end,
    keep_mask(Chan bsr 8, Shift + Bits, Mask bor Field).

whole(Image, R) ->
    {ok, Bytes} = erx_memdraw:read(Image, R),
    Bytes.

inside({X0, Y0, X1, Y1}, {A0, B0, A1, B1}) ->
    A0 =< X0 andalso X0 < X1 andalso X1 =< A1 andalso B0 =< Y0 andalso Y0 < Y1 andalso Y1 =< B1.

%%% Messages

message(#{ref := #{images := Images}}) ->
    Held = maps:keys(Images),
    Id = fun() -> pick([0, 1, 2, 3]) end,
    case rand:uniform(12) of
        1 -> {alloc, pick([1, 2, 3]), 0, 0, pick(chans() ++ refused_chans()), rand:uniform(2) - 1,
              image_rect(), clip_rect(), color()};
        2 -> {clip, Id(), rand:uniform(2) - 1, clip_rect()};
        3 -> {op, rand:uniform(12) - 1};
        4 -> {free, pick([1, 2, 3])};
        5 -> load(Images);
        6 -> {read, Id(), within(Images)};
        _ -> {draw, pick(Held), pick(Held), pick(Held), clip_rect(), point(), point()}
    end.

load(Images) ->
    Id = pick(maps:keys(Images)),
    #{r := Image, depth := Depth} = maps:get(Id, Images),
    R = sub_rect(Image),
    {_, Y0, _, Y1} = R,
    Length = case R of
                 {X0, _, X1, _} when X1 > X0, Y1 > Y0 -> erx_draw_image:bytes_per_line(R, Depth) * (Y1 - Y0);
                 _ -> rand:uniform(3) - 1
             end,
    {load, Id, R, rand:bytes(Length)}.

within(Images) ->
    case maps:values(Images) of
        [] -> clip_rect();
        Values -> sub_rect(maps:get(r, pick(Values)))
    end.

%% A rectangle inside R, sometimes empty.
sub_rect({X0, Y0, X1, Y1}) ->
    {A0, A1} = span(X0, X1),
    {B0, B1} = span(Y0, Y1),
    {A0, B0, A1, B1}.

span(Lo, Hi) ->
    A = Lo + rand:uniform(Hi - Lo + 1) - 1,
    {A, A + rand:uniform(Hi - A + 1) - 1}.

image_rect() ->
    X = pick([small(), (1 bsl 25) - rand:uniform(20), -(1 bsl 25) + rand:uniform(20) - 5]),
    Y = pick([small(), small(), (1 bsl 24) + rand:uniform(8)]),
    {X, Y, X + rand:uniform(?SIDE), Y + rand:uniform(?SIDE)}.

%% Draw and clip rectangles: mostly near the images, some anywhere in 32 bits.
clip_rect() ->
    case rand:uniform(4) of
        1 -> {coord(), coord(), coord(), coord()};
        2 -> {-16#80000000, -16#80000000, 16#7fffffff, 16#7fffffff};
        _ -> X = small(), Y = small(), {X, Y, X + rand:uniform(16) - 2, Y + rand:uniform(16) - 2}
    end.

point() -> {coord(), coord()}.

coord() ->
    case rand:uniform(5) of
        1 -> min(16#7fffffff, max(-16#80000000, pick([-16#80000000, 16#7fffffff, -(1 bsl 30), 1 bsl 30,
                                                      (1 bsl 25) - 3, -(1 bsl 25)]) + small()));
        _ -> small()
    end.

small() -> rand:uniform(41) - 21.

color() ->
    case rand:uniform(4) of
        1 -> ?NOFILL;
        _ -> rand:uniform(1 bsl 32) - 1
    end.

chans() ->
    [erx_draw_ref:chan(C) || C <- [[{grey, 1}], [{grey, 2}], [{grey, 4}], [{grey, 8}], [{map, 8}],
                                   [{red, 5}, {green, 6}, {blue, 5}], [{red, 8}, {green, 8}, {blue, 8}],
                                   [{ignore, 8}, {red, 8}, {green, 8}, {blue, 8}],
                                   [{red, 8}, {green, 8}, {blue, 8}, {alpha, 8}],
                                   [{alpha, 8}, {red, 8}, {green, 8}, {blue, 8}], [{grey, 8}, {alpha, 8}]]].

refused_chans() ->
    [erx_draw_ref:chan(C) || C <- [[{map, 4}], [{red, 1}, {green, 1}, {blue, 1}, {ignore, 1}],
                                   [{grey, 8}, {red, 8}], [{map, 8}, {alpha, 8}], [{red, 8}, {red, 8}]]].

pick(List) -> lists:nth(rand:uniform(length(List)), List).

%%% Y against cloadmemimage

y_case() ->
    Chan = pick(chans()),
    Depth = erx_draw_ref:depth(Chan),
    X = small(),
    R = {X, small(), X + rand:uniform(20), 0},
    R1 = setelement(4, R, element(2, R) + rand:uniform(5)),
    {_, Y0, _, Y1} = R1,
    Pixels = pixels(erx_draw_image:bytes_per_line(R1, Depth) * (Y1 - Y0)),
    Payload = case rand:uniform(3) of
                  1 -> erx_draw_image:encode(Pixels, R1);
                  2 -> mutate(erx_draw_image:encode(Pixels, R1));
                  3 -> rand:bytes(rand:uniform(64))
              end,
    case {erx_draw_image:decode(Payload, R1, Depth), erx_memdraw:cload(Chan, R1, Payload)} of
        {{ok, Decoded, Rest}, {ok, Decoded, Used}} when Used =:= byte_size(Payload) - byte_size(Rest) -> ok;
        {error, {error, einval}} -> ok;
        Other -> error({y, Chan, R1, Payload, Other})
    end.

%% Bytes with repeats, so codes reach back.
pixels(N) -> << <<(pick([0, 255, rand:uniform(256) - 1]))>> || _ <- lists:seq(1, N) >>.

mutate(Bytes) ->
    case rand:uniform(3) of
        1 -> binary:part(Bytes, 0, rand:uniform(byte_size(Bytes)) - 1);
        2 -> Bytes;
        3 -> At = rand:uniform(byte_size(Bytes)) - 1,
             <<Head:At/binary, _, Tail/binary>> = Bytes,
             <<Head/binary, (rand:uniform(256) - 1), Tail/binary>>
    end.

%%% Unit cases

new_image_padding_is_zero() ->
    R = {-3, 0, 2, 3},
    {ok, Image} = erx_memdraw:alloc(erx_draw_ref:chan([{grey, 1}]), R, R, false, ?NOFILL),
    {ok, <<0:48>>} = erx_memdraw:read(Image, R).

far_draw_touches_the_clip() ->
    R = {2, 3, 7, 9},
    Chan = erx_draw_ref:chan([{grey, 8}]),
    Far = {-16#80000000, -16#80000000, 16#7fffffff, 16#7fffffff},
    {ok, Dst} = erx_memdraw:alloc(Chan, R, {4, 0, 100, 5}, false, ?NOFILL),
    {ok, Src} = erx_memdraw:alloc(Chan, {0, 0, 1, 1}, Far, true, 16#ffffffff),
    {ok, {4, 3, 7, 5}} = erx_memdraw:draw(Dst, Far, Src, {-16#80000000, -16#80000000}, opaque, {-16#80000000, -16#80000000}, 11, dst),
    {ok, none} = erx_memdraw:draw(Dst, {7, 3, 9, 9}, Src, {0, 0}, opaque, {0, 0}, 11, dst),
    {ok, {2, 3, 3, 4}} = erx_memdraw:draw(Dst, Far, Src, {-16#80000000, -16#80000000}, opaque, {-16#80000000, -16#80000000}, 11, {0, 0, 3, 4}),
    {ok, <<255, 0, 255, 255, 255, 0, 0, 255, 255, 255>>} = erx_memdraw:read(Dst, {2, 3, 7, 5}).

%% A clip rectangle may be empty or inverted (draw(3) checks neither): a draw
%% through one touches nothing. rectXrect alone would pass both, leaving an
%% empty rectangle, or an inverted one whose rows alphadraw never ends.
empty_clip_draws_nothing() ->
    R = {0, 0, 4, 4},
    Chan = erx_draw_ref:chan([{grey, 8}]),
    {ok, Src} = erx_memdraw:alloc(Chan, {0, 0, 1, 1}, R, true, 16#ffffffff),
    {ok, Dst} = erx_memdraw:alloc(Chan, R, {1, 2, 3, 2}, false, ?NOFILL),
    {ok, none} = erx_memdraw:draw(Dst, R, Src, {0, 0}, opaque, {0, 0}, 11, dst),
    {ok, none} = erx_memdraw:draw(Dst, R, Src, {0, 0}, opaque, {0, 0}, 11, {1, 1, 1, 3}),
    ok = erx_memdraw:clip(Dst, false, {0, 3, 4, 1}),
    {ok, none} = erx_memdraw:draw(Dst, R, Src, {0, 0}, opaque, {0, 0}, 11, dst),
    ok = erx_memdraw:clip(Src, true, {0, 3, 4, 1}),
    {ok, none} = erx_memdraw:draw(Dst, R, Src, {0, 0}, opaque, {0, 0}, 11, R),
    {ok, <<0:128>>} = erx_memdraw:read(Dst, R).

%% A mask with grey and alpha that replicates is read through readbyte's
%% per-pixel loop, which must read its alpha alone: each pixel's grey
%% interleaved there made the second pixel's mask the first one's grey.
replicated_grey_alpha_mask() ->
    R = {0, 0, 2, 1},
    K8 = erx_draw_ref:chan([{grey, 8}]),
    {ok, Mask} = erx_memdraw:alloc(erx_draw_ref:chan([{grey, 8}, {alpha, 8}]), R, R, true, ?NOFILL),
    {ok, R} = erx_memdraw:load(Mask, R, <<0, 255, 0, 0>>),
    {ok, Src} = erx_memdraw:alloc(K8, {0, 0, 1, 1}, R, true, 16#ffffffff),
    {ok, Dst} = erx_memdraw:alloc(K8, R, R, false, ?NOFILL),
    {ok, R} = erx_memdraw:draw(Dst, R, Src, {0, 0}, Mask, {0, 0}, 11, dst),
    {ok, <<0, 0>>} = erx_memdraw:read(Dst, R).

refusals() ->
    R = {0, 0, 4, 4},
    {error, einval} = erx_memdraw:alloc(erx_draw_ref:chan([{map, 4}]), R, R, false, ?NOFILL),
    {error, einval} = erx_memdraw:alloc(erx_draw_ref:chan([{grey, 8}, {red, 8}]), R, R, false, ?NOFILL),
    {error, einval} = erx_memdraw:alloc(erx_draw_ref:chan([{grey, 8}]), {1 bsl 25, 0, (1 bsl 25) + 1, 1}, R,
                                        false, ?NOFILL),
    %% Wider than erx_memdraw allows: alphadraw's int buffer size would overflow.
    {error, einval} = erx_memdraw:alloc(erx_draw_ref:chan([{grey, 1}]), {0, 0, (1 bsl 16) + 1, 1}, R, false,
                                        ?NOFILL),
    {ok, Image} = erx_memdraw:alloc(erx_draw_ref:chan([{grey, 8}]), R, R, false, ?NOFILL),
    {error, einval} = erx_memdraw:load(Image, {0, 0, 2, 2}, <<1, 2, 3>>),
    {error, einval} = erx_memdraw:load(Image, {0, 0, 5, 1}, <<1, 2, 3, 4, 5>>),
    {error, einval} = erx_memdraw:read(Image, {1, 1, 1, 3}),
    {ok, {0, 0, 2, 2}} = erx_memdraw:load(Image, {0, 0, 2, 2}, <<1, 2, 3, 4>>),
    {ok, <<1, 2, 3, 4>>} = erx_memdraw:read(Image, {0, 0, 2, 2}).
