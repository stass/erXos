%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_virtio_gpu_core: the requests' bytes against the layouts of
%% abi/formats/virtio.txt, written out here field by field; the flush plan's clipping,
%% offsets and one fence; and decode/2 on answers the device may write, good and bad.

-module(erx_virtio_gpu_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FENCE_FLAG, 1).
-define(NODATA, 16#1100).
-define(DISPLAY_INFO, 16#1101).

%% A header as virtio_gpu_ctrl_hdr lays it out: type, flags, fence_id, ctx_id, ring_idx and
%% three bytes of padding.
hdr(Type, Flags, FenceId) -> <<Type:32/little, Flags:32/little, FenceId:64/little, 0:32, 0:8, 0:24>>.

screen() -> #{width => 64, height => 48, stride => 256, length => 256 * 48}.

identify_test() ->
    ?assertEqual(ok, erx_virtio_gpu_core:identify(16#74726976, 2, 16)),
    ?assertEqual({error, {device_id, 2}}, erx_virtio_gpu_core:identify(16#74726976, 2, 2)),
    ?assertEqual({error, {device_id, 0}}, erx_virtio_gpu_core:identify(16#74726976, 1, 0)),
    ?assertEqual({error, {version, 1}}, erx_virtio_gpu_core:identify(16#74726976, 1, 16)),
    ?assertEqual({error, {magic, 0}}, erx_virtio_gpu_core:identify(0, 2, 16)).

%% x8r8g8b8 keeps blue in a pixel's first byte in memory, so the device's format is
%% B8G8R8X8 (2); one with red first would swap the screen's red and blue.
x8r8g8b8_is_blue_first_test() ->
    ?assertEqual({ok, 2}, erx_virtio_gpu_core:format(<<"x8r8g8b8">>)),
    ?assertEqual({error, {chan, <<"r5g6b5">>}}, erx_virtio_gpu_core:format(<<"r5g6b5">>)).

requests_follow_the_layouts_test() ->
    ?assertEqual({[{out, hdr(16#0100, 0, 0)}, {in, 24 + 16 * 24}], display_info},
                 erx_virtio_gpu_core:display_info_request()),
    ?assertEqual({[{out, <<(hdr(16#0101, 0, 0))/binary, 7:32/little, 2:32/little, 640:32/little, 480:32/little>>},
                   {in, 24}], {nodata, none}},
                 erx_virtio_gpu_core:create_2d_request(7, 2, 640, 480)),
    ?assertEqual({[{out, <<(hdr(16#0103, 0, 0))/binary, 0:32, 0:32, 640:32/little, 480:32/little,
                           0:32/little, 7:32/little>>}, {in, 24}], {nodata, none}},
                 erx_virtio_gpu_core:set_scanout_request(0, 7, {640, 480})),
    ?assertEqual(56 + 24 + 16 * 24, erx_virtio_gpu_core:buffer_size()).

%% One rectangle is a transfer from its first pixel's offset and a flush, and the flush,
%% the frame's last request, carries the fence.
flush_of_one_rectangle_test() ->
    Rect = <<3:32/little, 2:32/little, 10:32/little, 5:32/little>>,
    Offset = 2 * 256 + 3 * 4,
    ?assertEqual({ok, [{[{out, <<(hdr(16#0105, 0, 0))/binary, Rect/binary, Offset:64/little, 7:32/little, 0:32>>},
                         {in, 24}], {nodata, none}},
                       {[{out, <<(hdr(16#0104, ?FENCE_FLAG, 99))/binary, Rect/binary, 7:32/little, 0:32>>},
                         {in, 24}], {nodata, {fence, 99}}}]},
                 erx_virtio_gpu_core:flush_plan([{3, 2, 13, 7}], screen(), 7, 99)).

%% Rectangles are clipped to the screen, empty ones dropped, and only the very last request
%% of the frame is fenced.
flush_clips_and_fences_once_test() ->
    {ok, Requests} = erx_virtio_gpu_core:flush_plan([{-5, -5, 2, 3}, {10, 10, 10, 20}, {60, 40, 100, 100}],
                                                     screen(), 7, 5),
    ?assertEqual(4, length(Requests)),
    Rects = [Rect || {[{out, <<_:24/binary, Rect:16/binary, _/binary>>}, _], _} <- Requests],
    ?assertEqual([<<0:32, 0:32, 2:32/little, 3:32/little>>, <<0:32, 0:32, 2:32/little, 3:32/little>>,
                  <<60:32/little, 40:32/little, 4:32/little, 8:32/little>>,
                  <<60:32/little, 40:32/little, 4:32/little, 8:32/little>>], Rects),
    ?assertEqual([{nodata, none}, {nodata, none}, {nodata, none}, {nodata, {fence, 5}}],
                 [Expect || {_, Expect} <- Requests]).

%% A rectangle or geometry that is not made of integers is nothing to show, or refused.
flush_refuses_what_is_not_integers_test() ->
    ?assertEqual({ok, []}, erx_virtio_gpu_core:flush_plan([{0.0, 0, 5, 5}, {0, 0, 5}, junk], screen(), 7, 1)),
    Float = (screen())#{length => 256.0 * 48},
    ?assertEqual({error, {geometry, Float}}, erx_virtio_gpu_core:flush_plan([{0, 0, 1, 1}], Float, 7, 1)).

flush_of_nothing_is_no_request_test() ->
    ?assertEqual({ok, []}, erx_virtio_gpu_core:flush_plan([], screen(), 7, 1)),
    ?assertEqual({ok, []}, erx_virtio_gpu_core:flush_plan([{64, 0, 70, 10}, {5, 5, 5, 9}], screen(), 7, 1)).

%% A stride other than the resource's rows, or an image too short for them, is refused.
flush_refuses_a_geometry_the_device_would_misread_test() ->
    Wide = (screen())#{stride => 260},
    Short = (screen())#{length => 256 * 47},
    ?assertEqual({error, {geometry, Wide}}, erx_virtio_gpu_core:flush_plan([{0, 0, 1, 1}], Wide, 7, 1)),
    ?assertEqual({error, {geometry, Short}}, erx_virtio_gpu_core:flush_plan([{0, 0, 1, 1}], Short, 7, 1)).

decode_nodata_test() ->
    ?assertEqual(ok, erx_virtio_gpu_core:decode({nodata, none}, hdr(?NODATA, 0, 0))),
    ?assertEqual(ok, erx_virtio_gpu_core:decode({nodata, {fence, 9}}, hdr(?NODATA, ?FENCE_FLAG, 9))),
    %% Flag bits other than FENCE are not read.
    ?assertEqual(ok, erx_virtio_gpu_core:decode({nodata, none}, hdr(?NODATA, 2, 0))).

decode_holds_the_fence_to_the_request_test() ->
    ?assertEqual({error, {fence, 1, 8}}, erx_virtio_gpu_core:decode({nodata, {fence, 9}}, hdr(?NODATA, ?FENCE_FLAG, 8))),
    ?assertEqual({error, {fence, 0, 9}}, erx_virtio_gpu_core:decode({nodata, {fence, 9}}, hdr(?NODATA, 0, 9))),
    ?assertEqual({error, {fence, 1, 3}}, erx_virtio_gpu_core:decode({nodata, none}, hdr(?NODATA, ?FENCE_FLAG, 3))).

decode_refuses_lengths_and_types_test() ->
    ?assertEqual({error, {length, 0}}, erx_virtio_gpu_core:decode({nodata, none}, <<>>)),
    ?assertEqual({error, {length, 23}}, erx_virtio_gpu_core:decode({nodata, none}, binary:part(hdr(?NODATA, 0, 0), 0, 23))),
    ?assertEqual({error, {length, 25}}, erx_virtio_gpu_core:decode({nodata, none}, <<(hdr(?NODATA, 0, 0))/binary, 0>>)),
    ?assertEqual({error, {type, ?DISPLAY_INFO}}, erx_virtio_gpu_core:decode({nodata, none}, hdr(?DISPLAY_INFO, 0, 0))),
    ?assertEqual({error, {type, ?NODATA}}, erx_virtio_gpu_core:decode(display_info, hdr(?NODATA, 0, 0))),
    ?assertEqual({error, {type, 16#0100}}, erx_virtio_gpu_core:decode({nodata, none}, hdr(16#0100, 0, 0))),
    ?assertEqual({error, {length, 24 + 23 * 16}},
                 erx_virtio_gpu_core:decode(display_info, <<(hdr(?DISPLAY_INFO, 0, 0))/binary, 0:(23 * 16 * 8)>>)).

decode_names_the_device_errors_test() ->
    Names = [unspec, out_of_memory, invalid_scanout_id, invalid_resource_id, invalid_context_id, invalid_parameter],
    ?assertEqual([{error, {device, Name}} || Name <- Names],
                 [erx_virtio_gpu_core:decode({nodata, {fence, 1}}, hdr(Type, 0, 0)) || Type <- lists:seq(16#1200, 16#1205)]),
    ?assertEqual({error, {type, 16#1206}}, erx_virtio_gpu_core:decode({nodata, none}, hdr(16#1206, 0, 0))).

display_info_and_mode_test() ->
    First = <<0:32, 0:32, 1280:32/little, 800:32/little, 1:32/little, 0:32>>,
    Rest = binary:copy(<<0:(24 * 8)>>, 15),
    {ok, Scanouts} = erx_virtio_gpu_core:decode(display_info, <<(hdr(?DISPLAY_INFO, 0, 0))/binary, First/binary, Rest/binary>>),
    ?assertEqual(16, length(Scanouts)),
    ?assertEqual(#{x => 0, y => 0, width => 1280, height => 800, enabled => true}, hd(Scanouts)),
    ?assertEqual({ok, {1280, 800}}, erx_virtio_gpu_core:mode(Scanouts, 1280 * 800 * 4)),
    ?assertEqual({error, {size, 1280, 800}}, erx_virtio_gpu_core:mode(Scanouts, 1280 * 800 * 4 - 1)),
    ?assertEqual({error, disabled}, erx_virtio_gpu_core:mode(tl(Scanouts), 1 bsl 30)),
    ?assertEqual({error, {size, 0, 5}},
                 erx_virtio_gpu_core:mode([#{x => 0, y => 0, width => 0, height => 5, enabled => true}], 1 bsl 30)).
