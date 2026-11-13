%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_memdraw).
-moduledoc """
The pixel primitives of the display domain (docs/design-display.md, "The
window process"): images and the `d`, shape, `y` and `r` operations that
`erx_draw_core` plans, performed by erXos's copy of 9front's libmemdraw
(display/libmemdraw) through the NIF display/memdraw/erx_memdraw_nif.c.

The caller is the window process, applying a plan the core checked, so
channels, rectangles and lengths are ones the core admitted; the NIF still
refuses what would leave an image. Each operation that writes pixels
returns the clipped rectangle it touched, or `none`, which the window
process unions into its dirty list. An image is freed when no process holds
it, and is used by one process at a time.
""".

-export([alloc/5, wrap/4, clip/3, draw/8, line/9, poly/8, fill_poly/6, ellipse/8, arc/10, load/3, read/2,
         cload/3, test_area/2]).
-nifs([alloc/5, wrap/4, clip/3, draw/8, line/9, poly/8, fill_poly/6, ellipse/8, arc/10, load/3, read/2,
         cload/3, test_area/2]).
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

-doc """
An image of channel Chan over R whose pixels are the bytes of Backing, from
Offset on, laid out as `alloc/5` lays out its own; nothing is written, and
the clip rectangle is R. Backing is a connection's pixel area from
`erx_area:open/1`, which the image keeps mapped until it is freed, or a
device's region, the screen image a display driver made with the device
NIF's region call and the device reads, which is kept for the boot. Only a
driver names the device NIF, so a region appears here as the opaque term
that call returns. `einval` for an Offset that is
not a multiple of the page size, a channel or rectangle `alloc/5` refuses,
or rows that, with one word libmemdraw may load past them, pass the
backing's end. An image over the display's read-only mapping is read and
never written: an operation that would write it fails with `badarg`.
""".
-spec wrap(erx_area:area() | term(),non_neg_integer(), rect(), 0..16#ffffffff) ->
          {ok, image()} | {error, einval | enomem}.
wrap(_Backing, _Offset, _R, _Chan) -> ?NIF.

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
The shapes, libmemdraw's algorithms composing Src onto Dst with operation Op,
Sp aligned as draw(3) aligns it: `L` (`line/9`), `p` (`poly/8`), `P`
(`fill_poly/6`), and `e` and `E` (`ellipse/8`, `arc/10`, with `fill` for a
filled one). Every point, centre and source point lies within 2^19 of the
origin, semi-axes are at most 2^14 and thicknesses at most 2^10, as
`erx_draw_core` admits them, else `einval`. Each runs on a dirty scheduler
and returns the union of the clipped rectangles it wrote, or `none`;
`{error, enomem, Touched}` when a temporary could not be allocated, after
which the part of the shape inside Touched may have been drawn.
""".
-spec line(image(), point(), point(), 0..16#ffffffff, 0..16#ffffffff, non_neg_integer(), image(), point(),
           0..11) -> {ok, touched()} | {error, einval} | {error, enomem, touched()}.
line(_Dst, _P0, _P1, _End0, _End1, _Thick, _Src, _Sp, _Op) -> ?NIF.

-doc "`p`: the polyline through Points; see `line/9`.".
-spec poly(image(), [point()], 0..16#ffffffff, 0..16#ffffffff, non_neg_integer(), image(), point(), 0..11) ->
          {ok, touched()} | {error, einval} | {error, enomem, touched()}.
poly(_Dst, _Points, _End0, _End1, _Thick, _Src, _Sp, _Op) -> ?NIF.

-doc "`P`: the polygon Points filled under winding rule Wind; see `line/9`.".
-spec fill_poly(image(), [point()], integer(), image(), point(), 0..11) ->
          {ok, touched()} | {error, einval} | {error, enomem, touched()}.
fill_poly(_Dst, _Points, _Wind, _Src, _Sp, _Op) -> ?NIF.

-doc "`e` or `E`: the ellipse with centre C and semi-axes A and B; see `line/9`.".
-spec ellipse(image(), point(), non_neg_integer(), non_neg_integer(), non_neg_integer() | fill, image(), point(),
              0..11) -> {ok, touched()} | {error, einval} | {error, enomem, touched()}.
ellipse(_Dst, _C, _A, _B, _Thick, _Src, _Sp, _Op) -> ?NIF.

-doc "`e` or `E` as an arc from Alpha through Phi degrees; see `line/9`.".
-spec arc(image(), point(), non_neg_integer(), non_neg_integer(), non_neg_integer() | fill, image(), point(),
          integer(), integer(), 0..11) -> {ok, touched()} | {error, einval} | {error, enomem, touched()}.
arc(_Dst, _C, _A, _B, _Thick, _Src, _Sp, _Alpha, _Phi, _Op) -> ?NIF.

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

-doc """
Test only: absent from the runtime, where it raises `undef`, and present in
the bundle stock's emulator loads: a stand-in pixel area of
Bytes, whole host pages, with an untouchable page past it, writable or
read-only, and the host's page size; its unmap sends the caller
`erx_area_unmapped` (test/display/erx_area_stand_in.c).
""".
-spec test_area(pos_integer(), write | read) -> {ok, erx_area:area(), pos_integer()}.
test_area(_Bytes, _Mode) -> ?NIF.
