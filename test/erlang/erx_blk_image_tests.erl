%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_blk_image, the windows on the booted slot's EROFS images
%% (test/host/erx_blk_image_test.rb runs them). The manifest cases read manifests the
%% packer wrote from the development manifest into the working directory: manifest-good
%% names the release image in one extent of two blocks at 128 MiB into the slot,
%% manifest-two-extents the same image in two extents, and manifest-no-window the image
%% with no window on it.

-module(erx_blk_image_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(UNCHECKED, ?ERX_MF_IMAGE_FORMAT_EROFS_UNCHECKED).
-define(SLOT_BYTES, (?ERX_MEDIUM_SLOT_SECTORS * 512)).
-define(AT, (128 bsl 20)).

image(Extents) ->
    #{name => <<"release">>, format => ?UNCHECKED, data_bytes => lists:sum([Length || {_, Length} <- Extents]),
      extents => Extents}.

boot_slot_test_() ->
    [?_assertEqual({ok, none}, erx_blk_image:boot_slot([])),
     ?_assertEqual({ok, none}, erx_blk_image:boot_slot([["console_uart", "1", "2", "3"]])),
     ?_assertEqual({ok, none}, erx_blk_image:boot_slot([["boot", "unknown", "none"]])),
     ?_assertEqual({ok, slot_a}, erx_blk_image:boot_slot([["console_uart"], ["boot", "normal", "a"]])),
     ?_assertEqual({ok, slot_b}, erx_blk_image:boot_slot([["boot", "trial", "b"]])),
     ?_assertEqual({ok, slot_a}, erx_blk_image:boot_slot([["boot", "trial", "a"]]))].

%% Every pair boot_pair.h refuses, a word too many or too few, two lists, and terms that
%% are not init's arguments.
boot_slot_refusals_test_() ->
    [?_assertEqual({error, bad_boot}, erx_blk_image:boot_slot(Arguments))
     || Arguments <- [[["boot", "unknown", "a"]], [["boot", "normal", "none"]], [["boot", "normal", "c"]],
                      [["boot", "other", "a"]], [["boot", "normal"]], [["boot"]], [["boot", "normal", "a", "x"]],
                      [["boot", "normal", "a"], ["boot", "normal", "a"]], [["boot", 1, "a"]],
                      not_a_list, <<"boot normal a">>]].

place_test_() ->
    [?_assertEqual({ok, {{image, <<"release">>}, ?ERX_MEDIUM_SLOT_A_START + ?AT div 512, 16}},
                   erx_blk_image:place(image([{?AT, 8192}]), slot_a)),
     ?_assertEqual({ok, {{image, <<"release">>}, ?ERX_MEDIUM_SLOT_B_START + ?AT div 512, 16}},
                   erx_blk_image:place(image([{?AT, 8192}]), slot_b)),
     %% The slot's last sector is the image's last.
     ?_assertEqual({ok, {{image, <<"release">>}, ?ERX_MEDIUM_SLOT_A_START + ?ERX_MEDIUM_SLOT_SECTORS - 1, 1}},
                   erx_blk_image:place(image([{?SLOT_BYTES - 512, 512}]), slot_a))].

place_refusals_test_() ->
    Refused = fun(Why, Image) -> ?_assertEqual({error, {<<"release">>, Why}}, erx_blk_image:place(Image, slot_a)) end,
    [Refused(extent_bounds, image([{?AT + 1, 8192}])),
     Refused(extent_bounds, image([{?AT, 8000}])),
     Refused(extent_bounds, image([{?AT, 0}])),
     Refused(extent_bounds, image([{?SLOT_BYTES - 4096, 8192}])),
     Refused(extent_bounds, image([{?SLOT_BYTES, 512}])),
     Refused(length, (image([{?AT, 8192}]))#{data_bytes := 4096}),
     Refused(extent_count, image([{?AT, 4096}, {?AT + 8192, 4096}])),
     Refused(extent_count, image([])),
     Refused(format, (image([{?AT, 8192}]))#{format := ?ERX_MF_IMAGE_FORMAT_EROFS_VERITY})].

manifest(Name) ->
    {ok, Bytes} = file:read_file("manifest-" ++ Name),
    Bytes.

%% An image window refuses a write without reaching a device: no erx_blk runs here, so
%% a write that reached one would answer eio.
image_window_is_read_only_test() ->
    {ok, Window} = erx_blk_window:start_link({{image, <<"release">>}, 0, 8}),
    ?assertEqual({error, erofs}, erx_blk_window:write(Window, 0, <<0:4096>>)),
    ?assertEqual({ok, #{role => {image, <<"release">>}, sectors => 8}}, erx_blk_window:info(Window)),
    unlink(Window),
    exit(Window, kill).

manifest_test_() ->
    Release = {{image, <<"release">>}, ?ERX_MEDIUM_SLOT_A_START + ?AT div 512, 16},
    [?_assertEqual({ok, [Release], []}, erx_blk_image:windows(manifest("good"), slot_a)),
     ?_assertEqual({ok, [], []}, erx_blk_image:windows(manifest("good"), none)),
     ?_assertEqual({ok, [], [{<<"release">>, extent_count}]}, erx_blk_image:windows(manifest("two-extents"), slot_a)),
     ?_assertEqual({ok, [], []}, erx_blk_image:windows(manifest("no-window"), slot_b)),
     ?_assertEqual({error, manifest}, erx_blk_image:windows(<<"not a manifest">>, slot_a)),
     ?_assertEqual({error, manifest}, erx_blk_image:windows(binary:part(manifest("good"), 0, 512), slot_a))].
