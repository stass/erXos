%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random answers through erx_virtio_gpu_core:decode/2, the virtio-gpu driver's parse of
%% what the device wrote, and random rectangles through flush_plan/4. Whatever arrives,
%% decode/2 agrees with reference/2, which reads the header's words by position and judges
%% them in the order the specification gives them meaning; every plan keeps each transfer
%% inside the screen image and fences its last request alone. Types, flags, fence ids and
%% sizes cluster at the values that matter, so every path is common. The seed comes from
%% make check-fuzz.

-module(erx_virtio_gpu_core_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(HDR, 24).
-define(DISPLAY_INFO_SIZE, (24 + 16 * 24)).
-define(NODATA, 16#1100).
-define(DISPLAY_INFO, 16#1101).
%% The fewest rounds whose answer must decode, so an edit to the generator cannot leave the
%% accepting path untried.
-define(MIN_ACCEPTED, ?ROUNDS div 20).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of() =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of() ->
    check_plan(),
    Expect = case rand:uniform(3) of
                 1 -> display_info;
                 2 -> {nodata, none};
                 3 -> {nodata, {fence, rand:uniform(1 bsl 64) - 1}}
             end,
    Bytes = answer(Expect),
    Said = erx_virtio_gpu_core:decode(Expect, Bytes),
    case Said =:= reference(Expect, Bytes) of
        true when Said =:= ok -> accepted;
        true when element(1, Said) =:= ok -> accepted;
        true -> refused;
        false -> error({disagrees_with_reference, Expect, Bytes, Said})
    end.

%% An answer near the expected one: its type, flags, fence id and size each usually right.
answer(Expect) ->
    {WantType, WantSize, WantFence} = want(Expect),
    Type = pick([WantType, WantType, WantType, ?NODATA, ?DISPLAY_INFO, 16#1200 + rand:uniform(7) - 1,
                 rand:uniform(1 bsl 32) - 1]),
    {Flags, FenceId} = case {rand:uniform(4), WantFence} of
                           {1, _} -> {rand:uniform(1 bsl 32) - 1, rand:uniform(1 bsl 64) - 1};
                           {2, {fence, Id}} -> {1, Id bxor 1};
                           {_, {fence, Id}} -> {pick([1, 3]), Id};
                           {_, none} -> {pick([0, 0, 2]), rand:uniform(1 bsl 64) - 1}
                       end,
    Size = pick([WantSize, WantSize, WantSize, 0, ?HDR - 1, WantSize - 1, WantSize + 1, rand:uniform(512) - 1]),
    Whole = <<Type:32/little, Flags:32/little, FenceId:64/little, (rand:bytes(?DISPLAY_INFO_SIZE))/binary>>,
    binary:part(Whole, 0, min(max(Size, 0), byte_size(Whole))).

want(display_info) -> {?DISPLAY_INFO, ?DISPLAY_INFO_SIZE, none};
want({nodata, Fence}) -> {?NODATA, ?HDR, Fence}.

reference(_Expect, Bytes) when byte_size(Bytes) < ?HDR ->
    {error, {length, byte_size(Bytes)}};
reference(Expect, Bytes) ->
    Type = binary:decode_unsigned(binary:part(Bytes, 0, 4), little),
    Flags = binary:decode_unsigned(binary:part(Bytes, 4, 4), little),
    FenceId = binary:decode_unsigned(binary:part(Bytes, 8, 8), little),
    Errors = [unspec, out_of_memory, invalid_scanout_id, invalid_resource_id, invalid_context_id, invalid_parameter],
    {WantType, WantSize, WantFence} = want(Expect),
    Answered = case Flags band 1 of
                   1 -> {fence, FenceId};
                   0 -> none
               end,
    if
        Type >= 16#1200, Type =< 16#1205 -> {error, {device, lists:nth(Type - 16#1200 + 1, Errors)}};
        Type =/= WantType -> {error, {type, Type}};
        byte_size(Bytes) =/= WantSize -> {error, {length, byte_size(Bytes)}};
        Answered =/= WantFence -> {error, {fence, Flags, FenceId}};
        Expect =:= display_info -> {ok, [scanout(binary:part(Bytes, ?HDR + I * 24, 24)) || I <- lists:seq(0, 15)]};
        true -> ok
    end.

scanout(One) ->
    [X, Y, W, H, Enabled, _Flags] = [binary:decode_unsigned(binary:part(One, I * 4, 4), little) || I <- lists:seq(0, 5)],
    #{x => X, y => Y, width => W, height => H, enabled => Enabled =/= 0}.

%% A random plan: a geometry usually valid, rectangles around and across the screen, and a
%% fence. A valid geometry gives requests whose transfers stay inside the image, two for
%% each rectangle left after clipping, every one unfenced but the last.
check_plan() ->
    Width = rand:uniform(40),
    Height = rand:uniform(40),
    Stride = pick([Width * 4, Width * 4, Width * 4, Width * 4 + 4, Width * 4 - 4]),
    Length = pick([Stride * Height, Stride * Height + rand:uniform(64), Stride * Height - 1]),
    Geometry = #{width => Width, height => Height, stride => Stride, length => Length},
    Rects = [rect(Width, Height) || _ <- lists:seq(1, rand:uniform(5) - 1)],
    FenceId = rand:uniform(1 bsl 64) - 1,
    Valid = Stride =:= Width * 4 andalso Stride * Height =< Length,
    case {erx_virtio_gpu_core:flush_plan(Rects, Geometry, 1, FenceId), Valid} of
        {{error, {geometry, Geometry}}, false} -> ok;
        {{ok, Requests}, true} -> check_requests(Requests, Rects, Geometry, FenceId);
        Other -> error({plan_disagrees, Rects, Geometry, Other})
    end.

check_requests(Requests, Rects, #{width := Width, height := Height, stride := Stride, length := Length} = Geometry,
               FenceId) ->
    Left = [R || {X0, Y0, X1, Y1} = R <- Rects, max(X0, 0) < min(X1, Width), max(Y0, 0) < min(Y1, Height)],
    Expects = [Expect || {_Segments, Expect} <- Requests],
    Fences = case Requests of
                 [] -> [];
                 _ -> lists:duplicate(length(Requests) - 1, {nodata, none}) ++ [{nodata, {fence, FenceId}}]
             end,
    Inside = lists:all(fun(Request) -> inside(Request, Width, Height, Stride, Length) end, Requests),
    case length(Requests) =:= 2 * length(Left) andalso Expects =:= Fences andalso Inside of
        true -> ok;
        false -> error({plan_wrong, Rects, Geometry, Requests})
    end.

%% A request's rectangle inside the screen and, for a transfer, its offset the rectangle's
%% first pixel and its last row's last byte inside the image.
inside({[{out, <<Type:32/little, _:20/binary, X:32/little, Y:32/little, W:32/little, H:32/little, Rest/binary>>},
         {in, ?HDR}], _Expect}, Width, Height, Stride, Length) ->
    Within = W > 0 andalso H > 0 andalso X + W =< Width andalso Y + H =< Height,
    case {Type, Rest} of
        {16#0105, <<Offset:64/little, _/binary>>} ->
            Within andalso Offset =:= Y * Stride + X * 4 andalso Offset + (H - 1) * Stride + W * 4 =< Length;
        {16#0104, _} -> Within;
        _ -> false
    end;
inside(_Request, _Width, _Height, _Stride, _Length) ->
    false.

rect(Width, Height) ->
    X0 = rand:uniform(Width + 20) - 11,
    Y0 = rand:uniform(Height + 20) - 11,
    {X0, Y0, X0 + rand:uniform(Width + 10) - 3, Y0 + rand:uniform(Height + 10) - 3}.

pick(List) -> lists:nth(rand:uniform(length(List)), List).

