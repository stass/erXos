%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_firmware_fb_core, the firmware framebuffer driver's pure core: which records it
%% drives, and how a frame's rectangles are clipped to the screen. Run by
%% test/host/erx_firmware_fb_core_test.rb.

-module(erx_firmware_fb_core_tests).

-include_lib("eunit/include/eunit.hrl").

record(Overrides) ->
    maps:merge(#{window => {object, 7, 0, 1920 * 1080 * 4}, width => 1920, height => 1080, stride => 7680,
                 format => x8r8g8b8}, Overrides).

plan_test_() ->
    [?_assertMatch({ok, #{chan := <<"x8r8g8b8">>, width := 1920, height := 1080, stride := 7680}},
                   erx_firmware_fb_core:plan(record(#{}))),
     %% The firmware's stride may be wider than a row, and the framebuffer may start inside its page.
     ?_assertMatch({ok, #{stride := 8192}}, erx_firmware_fb_core:plan(record(#{stride => 8192}))),
     ?_assertMatch({ok, _}, erx_firmware_fb_core:plan(record(#{window => {object, 7, 64, 1920 * 1080 * 4}}))),
     ?_assertMatch({ok, #{chan := <<"r5g6b5">>}},
                   erx_firmware_fb_core:plan(record(#{format => r5g6b5, stride => 3840}))),
     %% 24 bits: a row of 3 pixels is 9 bytes, which the copy's words round up to 12.
     ?_assertMatch({ok, _}, erx_firmware_fb_core:plan(record(#{format => r8g8b8, width => 3, stride => 12}))),
     ?_assertEqual({error, short_stride},
                   erx_firmware_fb_core:plan(record(#{format => r8g8b8, width => 3, stride => 8}))),
     ?_assertEqual({error, short_stride}, erx_firmware_fb_core:plan(record(#{stride => 7676}))),
     ?_assertEqual({error, unaligned_stride}, erx_firmware_fb_core:plan(record(#{stride => 7682}))),
     ?_assertEqual({error, unaligned_offset},
                   erx_firmware_fb_core:plan(record(#{window => {object, 7, 2, 1920 * 1080 * 4}})))].

frame_test_() ->
    [?_assertEqual({ok, [{0, 0, 640, 480}]}, erx_firmware_fb_core:frame([{0, 0, 640, 480}], 640, 480)),
     %% Clipped to the screen at every edge, and empty rectangles dropped.
     ?_assertEqual({ok, [{0, 0, 640, 480}]}, erx_firmware_fb_core:frame([{-5, -5, 700, 500}], 640, 480)),
     ?_assertEqual({ok, [{639, 479, 640, 480}]}, erx_firmware_fb_core:frame([{639, 479, 641, 481}], 640, 480)),
     ?_assertEqual({ok, []}, erx_firmware_fb_core:frame([{640, 0, 700, 10}, {5, 5, 5, 9}, {9, 9, 3, 3}], 640, 480)),
     ?_assertEqual({ok, []}, erx_firmware_fb_core:frame([], 640, 480)),
     %% Anything but a list of four integers refuses the frame.
     ?_assertEqual({error, einval}, erx_firmware_fb_core:frame([{0, 0, 1}], 640, 480)),
     ?_assertEqual({error, einval}, erx_firmware_fb_core:frame([{0, 0, 1, 1.0}], 640, 480)),
     ?_assertEqual({error, einval}, erx_firmware_fb_core:frame([{0, 0, 1, 1} | tail], 640, 480)),
     ?_assertEqual({error, einval}, erx_firmware_fb_core:frame(rects, 640, 480))].
