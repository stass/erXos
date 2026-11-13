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

%% The backing's request is its header, the resource and one entry, then the region's
%% segment, which the device NIF writes as the region's mem_entry: no address is here.
attach_backing_names_the_region_test() ->
    ?assertEqual({[{out, <<(hdr(16#0106, 0, 0))/binary, 7:32/little, 1:32/little>>}, {out, {region, r}}, {in, 24}],
                  {nodata, none}},
                 erx_virtio_gpu_core:attach_backing_request(7, r)).

%% x8r8g8b8 as Plan 9's CHAN4(CIgnore, 8, CRed, 8, CGreen, 8, CBlue, 8), XRGB32 of draw.h.
chan_code_test() ->
    ?assertEqual({ok, 16#68081828}, erx_virtio_gpu_core:chan_code(<<"x8r8g8b8">>)),
    ?assertEqual({error, {chan, <<"r5g6b5">>}}, erx_virtio_gpu_core:chan_code(<<"r5g6b5">>)).

display_info(Width, Height, Enabled) ->
    <<(hdr(?DISPLAY_INFO, 0, 0))/binary, 0:32, 0:32, Width:32/little, Height:32/little, Enabled:32/little, 0:32,
      (binary:copy(<<0:(24 * 8)>>, 15))/binary>>.

%% The bring-up, one request at a time: the display's size, the screen image's region,
%% the resource, its backing (the region), then the scanout; ready with the geometry.
setup_in_order_test() ->
    {{post, Info}, S0} = erx_virtio_gpu_core:setup_start(1 bsl 24),
    ?assertEqual(erx_virtio_gpu_core:display_info_request(), Info),
    {{region, Bytes}, S1} = erx_virtio_gpu_core:setup_next(S0, {answer, decoded(Info, display_info(640, 480, 1))}),
    ?assertEqual(640 * 4 * 480 + 8, Bytes),
    {{post, Create}, S2} = erx_virtio_gpu_core:setup_next(S1, {region, r}),
    ?assertEqual(erx_virtio_gpu_core:create_2d_request(1, 2, 640, 480), Create),
    {{post, Attach}, S3} = erx_virtio_gpu_core:setup_next(S2, {answer, ok}),
    ?assertEqual(erx_virtio_gpu_core:attach_backing_request(1, r), Attach),
    {{post, Scanout}, S4} = erx_virtio_gpu_core:setup_next(S3, {answer, ok}),
    ?assertEqual(erx_virtio_gpu_core:set_scanout_request(0, 1, {640, 480}), Scanout),
    ?assertMatch({{ready, #{geometry := #{width := 640, height := 480, stride := 2560, length := 2560 * 480},
                            region := r, resource := 1, chan := 16#68081828}}, _},
                 erx_virtio_gpu_core:setup_next(S4, {answer, ok})).

decoded({_Segments, Expect}, Bytes) -> erx_virtio_gpu_core:decode(Expect, Bytes).

%% A disabled scanout, a screen past the memory, and an event out of its step each stop it.
setup_stops_test() ->
    {_, S0} = erx_virtio_gpu_core:setup_start(1 bsl 24),
    ?assertMatch({{stop, {mode, disabled}}, _},
                 erx_virtio_gpu_core:setup_next(S0, {answer, erx_virtio_gpu_core:decode(display_info, display_info(640, 480, 0))})),
    ?assertMatch({{stop, {mode, {size, 4096, 4096}}}, _},
                 erx_virtio_gpu_core:setup_next(S0, {answer, erx_virtio_gpu_core:decode(display_info, display_info(4096, 4096, 1))})),
    ?assertMatch({{stop, {unexpected, display_info, {region, r}}}, _}, erx_virtio_gpu_core:setup_next(S0, {region, r})),
    ?assertMatch({{stop, {unexpected, display_info, {answer, ok}}}, _}, erx_virtio_gpu_core:setup_next(S0, {answer, ok})).

two() ->
    {ok, Requests} = erx_virtio_gpu_core:flush_plan([{0, 0, 1, 1}], screen(), 7, 99),
    Requests.

%% A frame posts its requests in order, each under the next tag, waits, and is done when
%% every one is answered ok, in whatever order the answers come, with the next frame's tag.
frame_posts_waits_and_finishes_test() ->
    [{Transfer, _}, {Flush, _}] = two(),
    F0 = erx_virtio_gpu_core:frame_start(two(), 10),
    {{post, 10, Transfer}, F1} = erx_virtio_gpu_core:frame_step(F0, next),
    {{post, 11, Flush}, F2} = erx_virtio_gpu_core:frame_step(F1, next),
    {wait, F3} = erx_virtio_gpu_core:frame_step(F2, next),
    {wait, F4} = erx_virtio_gpu_core:frame_step(F3, {answers, [{10, hdr(?NODATA, 0, 0)}]}),
    ?assertMatch({{done, [ok, ok], 12}, _}, erx_virtio_gpu_core:frame_step(F4, {answers, [{11, hdr(?NODATA, ?FENCE_FLAG, 99)}]})),
    ?assertMatch({{done, [], 5}, _}, erx_virtio_gpu_core:frame_step(erx_virtio_gpu_core:frame_start([], 5), next)).

%% A full queue takes the request back: it waits for an answer and is posted again; full
%% with nothing in flight would wait for ever, so it stops.
frame_full_test() ->
    [{Transfer, _}, {Flush, _}] = two(),
    F0 = erx_virtio_gpu_core:frame_start(two(), 0),
    {{post, 0, Transfer}, F1} = erx_virtio_gpu_core:frame_step(F0, next),
    ?assertMatch({{stop, {queue, full}}, _}, erx_virtio_gpu_core:frame_step(F1, {full, 0})),
    {{post, 1, Flush}, F2} = erx_virtio_gpu_core:frame_step(F1, next),
    {wait, F3} = erx_virtio_gpu_core:frame_step(F2, {full, 1}),
    {{post, 1, Flush}, _} = erx_virtio_gpu_core:frame_step(F3, {answers, [{0, hdr(?NODATA, 0, 0)}]}).

%% An answer the device refused, one that fails its check, and a tag not in flight stop it.
frame_stops_on_bad_answers_test() ->
    F0 = erx_virtio_gpu_core:frame_start(two(), 0),
    {_, F1} = erx_virtio_gpu_core:frame_step(F0, next),
    ?assertMatch({{stop, {answer, 0, {device, invalid_parameter}}}, _},
                 erx_virtio_gpu_core:frame_step(F1, {answers, [{0, hdr(16#1205, 0, 0)}]})),
    ?assertMatch({{stop, {answer, 0, {length, 1}}}, _}, erx_virtio_gpu_core:frame_step(F1, {answers, [{0, <<0>>}]})),
    ?assertMatch({{stop, {tag, 1}}, _}, erx_virtio_gpu_core:frame_step(F1, {answers, [{1, hdr(?NODATA, 0, 0)}]})).

%% Tags wrap at 2^64, as erx_device:post/4 takes them.
frame_tags_wrap_test() ->
    F0 = erx_virtio_gpu_core:frame_start(two(), 16#ffffffffffffffff),
    {{post, 16#ffffffffffffffff, _}, F1} = erx_virtio_gpu_core:frame_step(F0, next),
    ?assertMatch({{post, 0, _}, _}, erx_virtio_gpu_core:frame_step(F1, next)).
