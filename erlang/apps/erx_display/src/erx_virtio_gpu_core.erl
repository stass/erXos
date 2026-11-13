%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The virtio-gpu display driver's pure core (docs/design-display.md, "The display
%% device"): the requests it posts on the device's control queue, the plan of one flush,
%% and the parse of what the device wrote back. Every value and size comes from
%% abi/formats/virtio.txt through the generated erx_abi.hrl; the bit syntax lays each
%% layout out field by field, and a compile-time check below fails the build if the
%% generated offsets ever disagree with it.
%%
%% A request goes to erx_device:post/4 as its segments, [{out, Request}, {in, Size}], with
%% what its answer must be, its expect(): Size is the answer's exact length. decode/2 holds
%% the device's answer to that expect(), and is the one parse of bytes the device wrote, so
%% it has a fuzz target (test/erlang/erx_virtio_gpu_core_fuzz.erl).
%%
%% flush_plan/4 is flush/3's plan: for each rectangle, clipped to the screen, a transfer of
%% its pixels from the resource's backing to the host and a flush of it to the scanout. The
%% frame's last request carries the FENCE flag, as the design asks. The device has taken the
%% frame once every one of its requests is answered and decoded ok, which the driver reaps
%% anyway to free their buffers, so that point does not rest on how the device orders the
%% answers; the fence is checked as a cross-check of the last answer.
%%
%% The resource's rows are its width times 4 bytes, the layout the device assumes of its
%% backing, so the plan takes the screen's geometry only when its stride is exactly that.

-module(erx_virtio_gpu_core).

-export([identify/3, format/1, buffer_size/0]).
-export([display_info_request/0, create_2d_request/4, set_scanout_request/3]).
-export([flush_plan/4, decode/2, mode/2]).

-export_type([fence/0, expect/0, request/0, scanout/0, geometry/0, reason/0]).

-include("generated/erx_abi.hrl").

-define(BYTES_PER_PIXEL, 4).
-define(U32_MAX, 16#ffffffff).
-define(U64_MAX, 16#ffffffffffffffff).
-define(IS_U32(Value), (is_integer(Value) andalso Value > 0 andalso Value =< ?U32_MAX)).
-define(DISPLAY_INFO_SIZE, (?ERX_VIRTIO_GPU_CTRL_HDR_SIZE + ?ERX_VIRTIO_GPU_MAX_SCANOUTS * ?ERX_VIRTIO_GPU_DISPLAY_ONE_SIZE)).

%% header/2, rect/4, the requests' bodies, decode/2 and scanout/1 lay the layouts out field
%% by field in the bit syntax; this fails the build if the generated layouts ever put a
%% field elsewhere.
-if(?ERX_VIRTIO_GPU_CTRL_HDR_OFF_FLAGS =/= 4 orelse ?ERX_VIRTIO_GPU_CTRL_HDR_OFF_FENCE_ID =/= 8
    orelse ?ERX_VIRTIO_GPU_CTRL_HDR_OFF_CTX_ID =/= 16 orelse ?ERX_VIRTIO_GPU_CTRL_HDR_OFF_RING_IDX =/= 20
    orelse ?ERX_VIRTIO_GPU_CTRL_HDR_SIZE =/= 24
    orelse ?ERX_VIRTIO_GPU_RECT_OFF_Y =/= 4 orelse ?ERX_VIRTIO_GPU_RECT_OFF_WIDTH =/= 8
    orelse ?ERX_VIRTIO_GPU_RECT_OFF_HEIGHT =/= 12 orelse ?ERX_VIRTIO_GPU_RECT_SIZE =/= 16
    orelse ?ERX_VIRTIO_GPU_DISPLAY_ONE_OFF_ENABLED =/= 16 orelse ?ERX_VIRTIO_GPU_DISPLAY_ONE_OFF_FLAGS =/= 20
    orelse ?ERX_VIRTIO_GPU_DISPLAY_ONE_SIZE =/= 24
    orelse ?ERX_VIRTIO_GPU_RESOURCE_CREATE_2D_OFF_RESOURCE_ID =/= 24
    orelse ?ERX_VIRTIO_GPU_RESOURCE_CREATE_2D_OFF_FORMAT =/= 28
    orelse ?ERX_VIRTIO_GPU_RESOURCE_CREATE_2D_OFF_WIDTH =/= 32
    orelse ?ERX_VIRTIO_GPU_RESOURCE_CREATE_2D_OFF_HEIGHT =/= 36
    orelse ?ERX_VIRTIO_GPU_RESOURCE_CREATE_2D_SIZE =/= 40
    orelse ?ERX_VIRTIO_GPU_SET_SCANOUT_OFF_R =/= 24 orelse ?ERX_VIRTIO_GPU_SET_SCANOUT_OFF_SCANOUT_ID =/= 40
    orelse ?ERX_VIRTIO_GPU_SET_SCANOUT_OFF_RESOURCE_ID =/= 44 orelse ?ERX_VIRTIO_GPU_SET_SCANOUT_SIZE =/= 48
    orelse ?ERX_VIRTIO_GPU_RESOURCE_FLUSH_OFF_R =/= 24 orelse ?ERX_VIRTIO_GPU_RESOURCE_FLUSH_OFF_RESOURCE_ID =/= 40
    orelse ?ERX_VIRTIO_GPU_RESOURCE_FLUSH_SIZE =/= 48
    orelse ?ERX_VIRTIO_GPU_TRANSFER_TO_HOST_2D_OFF_R =/= 24
    orelse ?ERX_VIRTIO_GPU_TRANSFER_TO_HOST_2D_OFF_OFFSET =/= 40
    orelse ?ERX_VIRTIO_GPU_TRANSFER_TO_HOST_2D_OFF_RESOURCE_ID =/= 48
    orelse ?ERX_VIRTIO_GPU_TRANSFER_TO_HOST_2D_SIZE =/= 56).
-error("erx_virtio_gpu_core's bit syntax disagrees with abi/formats/virtio.txt").
-endif.

%% A request's fence: none, or the FENCE flag with this fence_id.
-type fence() :: none | {fence, 0..?U64_MAX}.
%% What a request's answer must be: an OK_NODATA with the request's fence, or the
%% OK_DISPLAY_INFO of a GET_DISPLAY_INFO, which is never fenced.
-type expect() :: {nodata, fence()} | display_info.
%% A request ready for erx_device:post/4, and what its answer must be.
-type request() :: {[{out, binary()} | {in, pos_integer()}], expect()}.
%% One scanout of a display-info answer.
-type scanout() :: #{x := 0..?U32_MAX, y := 0..?U32_MAX, width := 0..?U32_MAX, height := 0..?U32_MAX,
                     enabled := boolean()}.
%% The screen image's layout: its size in pixels, the bytes from one row to the next, and
%% its length in bytes.
-type geometry() :: #{width := pos_integer(), height := pos_integer(), stride := pos_integer(),
                      length := pos_integer()}.
-type device_error() :: unspec | out_of_memory | invalid_scanout_id | invalid_resource_id
                      | invalid_context_id | invalid_parameter.
-type reason() :: {length, non_neg_integer()} | {type, 0..?U32_MAX} | {device, device_error()}
                | {fence, Flags :: 0..?U32_MAX, FenceId :: 0..?U64_MAX}.

%% Whether the first registers of a transport say a virtio-mmio version 2 GPU device; the
%% reason carries the word that disagreed. Device id 0 is an empty transport.
-spec identify(non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
          ok | {error, {magic | version | device_id, non_neg_integer()}}.
identify(Magic, _Version, _DeviceId) when Magic =/= ?ERX_VIRTIO_MMIO_MAGIC -> {error, {magic, Magic}};
identify(_Magic, _Version, 0) -> {error, {device_id, 0}};
identify(_Magic, Version, _DeviceId) when Version =/= ?ERX_VIRTIO_MMIO_VERSION -> {error, {version, Version}};
identify(_Magic, _Version, DeviceId) when DeviceId =/= ?ERX_VIRTIO_ID_GPU -> {error, {device_id, DeviceId}};
identify(_Magic, _Version, _DeviceId) -> ok.

%% The device's pixel format for an erx_memdraw channel. x8r8g8b8 is one little-endian
%% 32-bit word per pixel, so its bytes in memory are blue, green, red and the unused byte:
%% B8G8R8X8.
-spec format(erx_display:chan()) -> {ok, pos_integer()} | {error, {chan, binary()}}.
format(<<"x8r8g8b8">>) -> {ok, ?ERX_VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM};
format(Chan) -> {error, {chan, Chan}}.

%% The size of the control queue's buffers: the largest request and the largest answer,
%% end to end, as erx_device:post/4 lays them.
-spec buffer_size() -> pos_integer().
buffer_size() -> ?ERX_VIRTIO_GPU_TRANSFER_TO_HOST_2D_SIZE + ?DISPLAY_INFO_SIZE.

-spec display_info_request() -> request().
display_info_request() ->
    request(header(?ERX_VIRTIO_GPU_CMD_GET_DISPLAY_INFO, none), display_info).

%% A 2D resource of the format and size, which the device keeps on the host.
-spec create_2d_request(1..?U32_MAX, 1..?U32_MAX, 1..?U32_MAX, 1..?U32_MAX) -> request().
create_2d_request(ResourceId, Format, Width, Height)
  when ?IS_U32(ResourceId), ?IS_U32(Format), ?IS_U32(Width), ?IS_U32(Height) ->
    request(<<(header(?ERX_VIRTIO_GPU_CMD_RESOURCE_CREATE_2D, none))/binary,
              ResourceId:32/little, Format:32/little, Width:32/little, Height:32/little>>,
            {nodata, none}).

%% The scanout shows the resource, from its origin, at the size given.
-spec set_scanout_request(non_neg_integer(), pos_integer(), {pos_integer(), pos_integer()}) -> request().
set_scanout_request(ScanoutId, ResourceId, {Width, Height}) ->
    request(<<(header(?ERX_VIRTIO_GPU_CMD_SET_SCANOUT, none))/binary, (rect(0, 0, Width, Height))/binary,
              ScanoutId:32/little, ResourceId:32/little>>,
            {nodata, none}).

%% The requests of one flush of Rects from a screen image of Geometry, which backs the
%% resource: a transfer and a flush for each rectangle that is not empty once clipped to the
%% screen, the last flush with fence FenceId. No rectangle left is no request at all, since
%% the device then has nothing to take. A geometry whose stride is not the resource's rows,
%% or whose length does not hold its rows, is refused whole.
-spec flush_plan([erx_display:rect()], geometry(), 1..?U32_MAX, 0..?U64_MAX) ->
          {ok, [request()]} | {error, {geometry, geometry()}}.
flush_plan(Rects, Geometry, ResourceId, FenceId)
  when ?IS_U32(ResourceId), is_integer(FenceId), FenceId >= 0, FenceId =< ?U64_MAX ->
    case valid_geometry(Geometry) of
        true ->
            #{width := Width, height := Height, stride := Stride} = Geometry,
            Clipped = [Clip || Rect <- Rects, {ok, Clip} <- [clip(Rect, Width, Height)]],
            Bodies = lists:flatmap(fun(Rect) -> rect_bodies(Rect, Stride, ResourceId) end, Clipped),
            Last = length(Bodies),
            {ok, [fenced_request(Type, Body, fence_at(Index, Last, FenceId))
                  || {Index, {Type, Body}} <- lists:enumerate(Bodies)]};
        false ->
            {error, {geometry, Geometry}}
    end.

%% The device's answer, the bytes erx_device:complete/2 returned for a request, held to what
%% the request expects: an error type is the device's refusal, by name; otherwise its type,
%% then its exact length, then for a fenced request the FENCE flag with the request's
%% fence_id, and for an unfenced one no FENCE flag; flag bits other than FENCE are not
%% read. A fence that disagrees is reported with the flags and fence_id the device wrote.
%% Nothing the device wrote is trusted beyond that.
-spec decode(expect(), binary()) -> ok | {ok, [scanout()]} | {error, reason()}.
decode(Expect, <<Type:32/little, Flags:32/little, FenceId:64/little, _Ctx:32/little, _Ring:8, _Pad:24,
                 Data/binary>> = Bytes) ->
    Size = byte_size(Bytes),
    case {device_error(Type), answer_type(Expect), answer_size(Expect)} of
        {{ok, Name}, _, _} -> {error, {device, Name}};
        {none, Want, _} when Type =/= Want -> {error, {type, Type}};
        {none, _, Want} when Size =/= Want -> {error, {length, Size}};
        {none, _, _} -> fence_check(fence_of(Expect), Flags, FenceId, answer(Expect, Data))
    end;
decode(_Expect, Bytes) ->
    {error, {length, byte_size(Bytes)}}.

%% The size of scanout 0, which the driver shows, from a display-info answer: refused when
%% it is disabled, empty, or when its screen image of 4 bytes a pixel would not fit in
%% MaxBytes, the memory the driver has for it.
-spec mode([scanout()], non_neg_integer()) ->
          {ok, {pos_integer(), pos_integer()}} | {error, disabled | {size, non_neg_integer(), non_neg_integer()}}.
mode([#{enabled := false} | _], _MaxBytes) ->
    {error, disabled};
mode([#{width := Width, height := Height} | _], MaxBytes)
  when Width > 0, Height > 0, Width * Height * ?BYTES_PER_PIXEL =< MaxBytes ->
    {ok, {Width, Height}};
mode([#{width := Width, height := Height} | _], _MaxBytes) ->
    {error, {size, Width, Height}};
mode([], _MaxBytes) ->
    {error, disabled}.

request(Request, Expect) -> {[{out, Request}, {in, answer_size(Expect)}], Expect}.

fenced_request(Type, Body, Fence) -> request(<<(header(Type, Fence))/binary, Body/binary>>, {nodata, Fence}).

answer_type({nodata, _Fence}) -> ?ERX_VIRTIO_GPU_RESP_OK_NODATA;
answer_type(display_info) -> ?ERX_VIRTIO_GPU_RESP_OK_DISPLAY_INFO.

answer_size({nodata, _Fence}) -> ?ERX_VIRTIO_GPU_CTRL_HDR_SIZE;
answer_size(display_info) -> ?DISPLAY_INFO_SIZE.

header(Type, none) ->
    <<Type:32/little, 0:32/little, 0:64/little, 0:32/little, 0:8, 0:24>>;
header(Type, {fence, FenceId}) ->
    <<Type:32/little, ?ERX_VIRTIO_GPU_FLAG_FENCE:32/little, FenceId:64/little, 0:32/little, 0:8, 0:24>>.

rect(X, Y, Width, Height) -> <<X:32/little, Y:32/little, Width:32/little, Height:32/little>>.

%% The stride is the resource's rows, the image holds them, and every offset into them fits
%% the transfer's 64-bit offset field.
valid_geometry(#{width := Width, height := Height, stride := Stride, length := Length})
  when ?IS_U32(Width), ?IS_U32(Height), is_integer(Stride), is_integer(Length) ->
    Stride =:= Width * ?BYTES_PER_PIXEL andalso Stride * Height =< min(Length, ?U64_MAX);
valid_geometry(_Geometry) ->
    false.

%% A Plan 9 rectangle clipped to the screen, as origin and size; none when nothing is left.
clip({X0, Y0, X1, Y1}, Width, Height)
  when is_integer(X0), is_integer(Y0), is_integer(X1), is_integer(Y1) ->
    {Left, Top, Right, Bottom} = {max(X0, 0), max(Y0, 0), min(X1, Width), min(Y1, Height)},
    case Left < Right andalso Top < Bottom of
        true -> {ok, {Left, Top, Right - Left, Bottom - Top}};
        false -> none
    end;
clip(_Rect, _Width, _Height) ->
    none.

%% The bodies of a rectangle's two requests, after their headers: a transfer, which reads
%% the rectangle's rows from the backing starting at its first pixel, one stride apart, as
%% FreeBSD's vtgpu_transfer_to_host_2d computes the offset (the clip and the geometry check
%% keep its last byte inside the image), then a flush.
rect_bodies({X, Y, Width, Height}, Stride, ResourceId) ->
    Offset = Y * Stride + X * ?BYTES_PER_PIXEL,
    Rect = rect(X, Y, Width, Height),
    [{?ERX_VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D, <<Rect/binary, Offset:64/little, ResourceId:32/little, 0:32/little>>},
     {?ERX_VIRTIO_GPU_CMD_RESOURCE_FLUSH, <<Rect/binary, ResourceId:32/little, 0:32/little>>}].

%% The frame's fence goes on its last request alone.
fence_at(Last, Last, FenceId) -> {fence, FenceId};
fence_at(_Index, _Last, _FenceId) -> none.

fence_of({nodata, Fence}) -> Fence;
fence_of(display_info) -> none.

answer({nodata, _Fence}, <<>>) -> ok;
answer(display_info, Data) -> {ok, [scanout(One) || <<One:?ERX_VIRTIO_GPU_DISPLAY_ONE_SIZE/binary>> <= Data]}.

%% The answer's fence is the request's: a fenced request's answer carries the FENCE flag
%% and its fence_id, and an unfenced request's no FENCE flag.
fence_check({fence, FenceId}, Flags, FenceId, Result) when Flags band ?ERX_VIRTIO_GPU_FLAG_FENCE =/= 0 -> Result;
fence_check(none, Flags, _FenceId, Result) when Flags band ?ERX_VIRTIO_GPU_FLAG_FENCE =:= 0 -> Result;
fence_check(_Fence, Flags, FenceId, _Result) -> {error, {fence, Flags, FenceId}}.

scanout(<<X:32/little, Y:32/little, Width:32/little, Height:32/little, Enabled:32/little, _Flags:32/little>>) ->
    #{x => X, y => Y, width => Width, height => Height, enabled => Enabled =/= 0}.

device_error(?ERX_VIRTIO_GPU_RESP_ERR_UNSPEC) -> {ok, unspec};
device_error(?ERX_VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY) -> {ok, out_of_memory};
device_error(?ERX_VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID) -> {ok, invalid_scanout_id};
device_error(?ERX_VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID) -> {ok, invalid_resource_id};
device_error(?ERX_VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID) -> {ok, invalid_context_id};
device_error(?ERX_VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER) -> {ok, invalid_parameter};
device_error(_Type) -> none.
