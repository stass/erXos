%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The pure core of the firmware framebuffer's driver, erx_firmware_fb (docs/design-display.md,
%% "The display device"): whether a framebuffer record can be driven, and what a frame
%% stores. The record is erx_device_record:framebuffers/0's, the geometry and format the
%% board's firmware wrote into its device tree, which the record's parser already checked
%% against the framebuffer's bytes.
%%
%% The screen image is an erx_memdraw image of the framebuffer's size and channel in the
%% driver's own memory, and a frame copies its changed rectangles into the framebuffer with
%% erx_memdraw:store/4, which stores whole 32-bit words: so the framebuffer's first byte
%% and its stride lie on 4-byte boundaries, and the stride holds a row rounded up to 4.
%% A format names its channel as Plan 9 does, highest bits first, which is how the
%% simple-framebuffer binding names it, so the channel's text is the format's name, and the
%% copy moves a pixel's bytes unchanged.

-module(erx_firmware_fb_core).

-export([plan/1, frame/3]).
-export_type([plan/0]).

%% What the driver needs of a record it can drive: the channel's text and code and the
%% geometry. erx_device:framebuffer/0 maps the record's window itself.
-type plan() :: #{chan := erx_display:chan(), code := 0..16#ffffffff, width := pos_integer(),
                  height := pos_integer(), stride := pos_integer()}.

%% The plan for Record, or why it cannot be driven: a format erx_chan does not take or whose
%% depth the copy does not take, or a layout off the copy's 4-byte words.
-spec plan(erx_device_record:framebuffer()) -> {ok, plan()} | {error, atom()}.
plan(#{window := {object, _Handle, Offset, _Size}, width := Width, height := Height,
       stride := Stride, format := Format}) ->
    Chan = atom_to_binary(Format),
    case erx_chan:parse(Chan) of
        {ok, Code, Depth} when Depth =:= 16; Depth =:= 24; Depth =:= 32 ->
            Row = 4 * ((Width * Depth + 31) div 32),
            if
                Offset rem 4 =/= 0 -> {error, unaligned_offset};
                Stride rem 4 =/= 0 -> {error, unaligned_stride};
                Stride < Row -> {error, short_stride};
                true -> {ok, #{chan => Chan, code => Code, width => Width, height => Height,
                               stride => Stride}}
            end;
        {ok, _Code, _Depth} ->
            {error, unsupported_depth};
        {error, einval} ->
            {error, unsupported_format}
    end.

%% The rectangles of a frame as the copy takes them: each clipped to the screen, and the
%% empty ones dropped. A rectangle that is not four integers is none of the screen's and
%% refuses the frame.
-spec frame(term(), pos_integer(), pos_integer()) -> {ok, [erx_display:rect()]} | {error, einval}.
frame(Rects, Width, Height) when is_list(Rects) ->
    clip(Rects, Width, Height, []);
frame(_Rects, _Width, _Height) ->
    {error, einval}.

clip([], _Width, _Height, Clipped) ->
    {ok, lists:reverse(Clipped)};
clip([{X0, Y0, X1, Y1} | Rest], Width, Height, Clipped)
  when is_integer(X0), is_integer(Y0), is_integer(X1), is_integer(Y1) ->
    Rect = {max(X0, 0), max(Y0, 0), min(X1, Width), min(Y1, Height)},
    case Rect of
        {A, B, C, D} when A < C, B < D -> clip(Rest, Width, Height, [Rect | Clipped]);
        _Empty -> clip(Rest, Width, Height, Clipped)
    end;
clip(_Rects, _Width, _Height, _Clipped) ->
    {error, einval}.
