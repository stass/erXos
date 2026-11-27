%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_blk_image, the windows on the booted slot's EROFS images
%% (test/host/erx_blk_image_test.rb runs them). The manifest cases read manifests the
%% packer wrote from the development manifest into the working directory: manifest-good
%% names the release image in one extent of two blocks at the start of the slot's system
%% partition, as the packer places it,
%% manifest-two-extents the same image in two extents, and manifest-no-window the image
%% with no window on it.

-module(erx_blk_image_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(UNCHECKED, ?ERX_MF_IMAGE_FORMAT_EROFS_UNCHECKED).
-define(SLOT_BYTES, (?ERX_MEDIUM_SYSTEM_SECTORS * 512)).
-define(AT, (32 bsl 20)).

image(Extents) ->
    #{name => <<"release">>, format => ?UNCHECKED, data_bytes => lists:sum([Length || {_, Length} <- Extents]),
      extents => Extents}.

place_test_() ->
    [?_assertEqual({ok, {{image, <<"release">>}, ?ERX_MEDIUM_SYSTEM_A_START + ?AT div 512, 16}},
                   erx_blk_image:place(image([{?AT, 8192}]), a)),
     ?_assertEqual({ok, {{image, <<"release">>}, ?ERX_MEDIUM_SYSTEM_B_START + ?AT div 512, 16}},
                   erx_blk_image:place(image([{?AT, 8192}]), b)),
     %% The slot's last sector is the image's last.
     ?_assertEqual({ok, {{image, <<"release">>}, ?ERX_MEDIUM_SYSTEM_A_START + ?ERX_MEDIUM_SYSTEM_SECTORS - 1, 1}},
                   erx_blk_image:place(image([{?SLOT_BYTES - 512, 512}]), a))].

place_refusals_test_() ->
    Refused = fun(Why, Image) -> ?_assertEqual({error, {<<"release">>, Why}}, erx_blk_image:place(Image, a)) end,
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
    {ok, Window} = erx_blk_window:start_link({{image, <<"release">>}, 0, 8}, 8),
    ?assertEqual({error, erofs}, erx_blk_window:write(Window, 0, <<0:4096>>)),
    ?assertEqual({ok, #{role => {image, <<"release">>}, sectors => 8, max_sectors => 8}}, erx_blk_window:info(Window)),
    unlink(Window),
    exit(Window, kill).

manifest_test_() ->
    Release = {{image, <<"release">>}, ?ERX_MEDIUM_SYSTEM_A_START, 16},
    [?_assertEqual({ok, [Release], []}, erx_blk_image:windows(manifest("good"), a)),
     ?_assertEqual({ok, [], []}, erx_blk_image:windows(manifest("good"), none)),
     ?_assertEqual({ok, [], [{<<"release">>, extent_count}]}, erx_blk_image:windows(manifest("two-extents"), a)),
     ?_assertEqual({ok, [], []}, erx_blk_image:windows(manifest("no-window"), b)),
     ?_assertEqual({error, manifest}, erx_blk_image:windows(<<"not a manifest">>, a)),
     ?_assertEqual({error, manifest}, erx_blk_image:windows(binary:part(manifest("good"), 0, 512), a))].
