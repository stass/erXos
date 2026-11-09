%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_memdraw).
-moduledoc """
The pixel primitives of the display domain (docs/design-display.md, "The
window process"): images and the `d`, `y` and `r` operations that
`erx_draw_core` plans, performed by erXos's copy of 9front's libmemdraw
(display/libmemdraw) through the NIF display/memdraw/erx_memdraw_nif.c.

The caller is the window process, applying a plan the core checked, so
channels, rectangles and lengths are ones the core admitted; the NIF still
refuses what would leave an image. Each operation that writes pixels
returns the clipped rectangle it touched, or `none`, which the window
process unions into its dirty list. An image is freed when no process holds
it, and is used by one process at a time.
""".

-export([alloc/5, clip/3, draw/8, load/3, read/2, cload/3]).
-nifs([alloc/5, clip/3, draw/8, load/3, read/2, cload/3]).
-on_load(load_nif/0).

-type image() :: reference().
-type rect() :: {integer(), integer(), integer(), integer()}.
-type point() :: {integer(), integer()}.
-type touched() :: rect() | none.
-export_type([image/0, touched/0]).

load_nif() ->
    erlang:load_nif(atom_to_list(?MODULE), 0).

-define(NIF, erlang:nif_error(not_loaded)).

-doc """
A new image of channel Chan over R with clip rectangle Clipr, its pixels and
row padding zero, then filled with the RGBA Color unless it is draw(3)'s
DNofill. `einval` for a channel draw(3)'s `b` refuses or a rectangle
9front's badrect refuses.
""".
-spec alloc(0..16#ffffffff, rect(), rect(), boolean(), 0..16#ffffffff) ->
          {ok, image()} | {error, einval | enomem}.
alloc(_Chan, _R, _Clipr, _Repl, _Color) -> ?NIF.

-doc "`c`: the image's replicate bit and clip rectangle as they stand after it.".
-spec clip(image(), boolean(), rect()) -> ok.
clip(_Image, _Repl, _Clipr) -> ?NIF.

-doc """
`d`: Src through Mask onto R of Dst with draw(2)'s operation Op, Sp and Mp
aligned with R's corner, clipped to Clip in place of Dst's clip rectangle
unless Clip is `dst`.
""".
-spec draw(image(), rect(), image(), point(), image() | opaque, point(), 0..11, dst | rect()) ->
          {ok, touched()} | {error, enomem}.
draw(_Dst, _R, _Src, _Sp, _Mask, _Mp, _Op, _Clip) -> ?NIF.

-doc """
`y`: R's pixels, as many bytes a row as 9front's bytesperline counts, into
the image. R lies inside the image and passes badrect.
""".
-spec load(image(), rect(), binary()) -> {ok, rect()} | {error, einval}.
load(_Image, _R, _Pixels) -> ?NIF.

-doc "`r`: R's pixels as `y` takes them.".
-spec read(image(), rect()) -> {ok, binary()} | {error, einval | enomem}.
read(_Image, _R) -> ?NIF.

-doc """
Test tool only, absent from a release's NIF: 9front's cloadmemimage of Data
into a new image over R, the decoded rows and the bytes the codes took. The
oracle of `erx_draw_image:decode/3`.
""".
-spec cload(0..16#ffffffff, rect(), binary()) ->
          {ok, binary(), non_neg_integer()} | {error, einval | enomem}.
cload(_Chan, _R, _Data) -> ?NIF.
