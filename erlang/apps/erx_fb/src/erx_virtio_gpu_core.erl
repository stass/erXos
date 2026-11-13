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
%% flush_plan/4 is a frame's plan: for each rectangle, clipped to the screen, a transfer of
%% its pixels from the resource's backing to the host and a flush of it to the scanout. The
%% frame's last request carries the FENCE flag, as the design asks. The device has taken the
%% frame once every one of its requests is answered and decoded ok, which the driver reaps
%% anyway to free their buffers, so that point does not rest on how the device orders the
%% answers; the fence is checked as a cross-check of the last answer.
%%
%% The resource's rows are its width times 4 bytes, the layout the device assumes of its
%% backing, so the plan takes the screen's geometry only when its stride is exactly that.
%%
%% The driver's conversation with the device is two pure machines, which erx_virtio_gpu
%% runs and whose actions it performs. The bring-up, setup_start/1 and setup_next/2, asks
%% one request at a time, as FreeBSD's vtgpu_attach does: the display's size, then the
%% screen image's region (the driver's erx_device:region/3), then a 2D resource of that
%% size, its backing, which is the region, and the scanout; it ends ready with what the
%% driver keeps, or stopped with the reason. A frame, frame_start/2 and frame_step/2, posts
%% a list of requests in order under consecutive tags, takes back one the full queue
%% refused, holds each answer to its request through decode/2, and is done when every
%% request is answered ok; the bring-up's requests and every flush run as frames. Any
%% answer that fails its check stops the frame: the driver then ends, and its restart
%% resets the device (docs/design-display.md, "The display device").

-module(erx_virtio_gpu_core).

-export([identify/3, format/1, buffer_size/0]).
-export([display_info_request/0, create_2d_request/4, set_scanout_request/3]).
-export([attach_backing_request/2, chan_code/1, region_size/1]).
-export([flush_plan/4, decode/2, mode/2]).
-export([setup_start/1, setup_next/2, frame_start/2, frame_step/2]).

-export_type([fence/0, expect/0, request/0, scanout/0, geometry/0, reason/0]).
-export_type([setup/0, setup_action/0, ready/0, frame/0, frame_action/0]).

-include("generated/erx_abi.hrl").

-define(BYTES_PER_PIXEL, 4).
-define(U32_MAX, 16#ffffffff).
-define(U64_MAX, 16#ffffffffffffffff).
-define(IS_U32(Value), (is_integer(Value) andalso Value > 0 andalso Value =< ?U32_MAX)).
%% The one resource the driver makes, and the scanout it shows.
-define(RESOURCE_ID, 1).
-define(SCANOUT, 0).
%% The screen's channel, and the bytes past its rows that libmemdraw may load: one ulong
%% (display/memdraw/erx_memdraw.c, erx_memdraw_wrap), taken here at its widest.
-define(CHAN, <<"x8r8g8b8">>).
-define(WORD_PAST_ROWS, 8).
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
    orelse ?ERX_VIRTIO_GPU_TRANSFER_TO_HOST_2D_SIZE =/= 56
    orelse ?ERX_VIRTIO_GPU_RESOURCE_ATTACH_BACKING_OFF_RESOURCE_ID =/= 24
    orelse ?ERX_VIRTIO_GPU_RESOURCE_ATTACH_BACKING_OFF_NR_ENTRIES =/= 28
    orelse ?ERX_VIRTIO_GPU_RESOURCE_ATTACH_BACKING_SIZE =/= 32).
-error("erx_virtio_gpu_core's bit syntax disagrees with abi/formats/virtio.txt").
-endif.

%% A request's fence: none, or the FENCE flag with this fence_id.
-type fence() :: none | {fence, 0..?U64_MAX}.
%% What a request's answer must be: an OK_NODATA with the request's fence, or the
%% OK_DISPLAY_INFO of a GET_DISPLAY_INFO, which is never fenced.
-type expect() :: {nodata, fence()} | display_info.
%% A request ready for erx_device:post/4, and what its answer must be. A region is the
%% device NIF's opaque name of the screen image's memory, which only a driver names.
-type request() :: {[{out, binary()} | {out, {region, term()}} | {in, pos_integer()}], expect()}.
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

%% The bring-up's state: the step whose answer it waits for, the memory the screen image
%% may take, and what earlier steps settled.
-type setup() :: #{step := display_info | region | create | attach | scanout, max_bytes := non_neg_integer(),
                   mode => {pos_integer(), pos_integer()}, region => term()}.
-type setup_event() :: {answer, ok | {ok, [scanout()]}} | {region, term()}.
%% What the driver keeps once the scanout shows the resource: the screen image's layout,
%% its region, the resource and erx_memdraw's code of the channel.
-type ready() :: #{geometry := geometry(), region := term(), resource := pos_integer(), chan := 0..?U32_MAX}.
-type setup_action() :: {post, request()} | {region, pos_integer()} | {ready, ready()} | {stop, term()}.

%% A frame: the requests not yet posted, in order, each with its place; each posted request by
%% tag, with its place in the frame; the answers so far by place; and the next tag.
-type frame() :: #{todo := [{pos_integer(), request()}], inflight := #{0..?U64_MAX => {pos_integer(), request()}},
                   answers := #{pos_integer() => ok | {ok, [scanout()]}}, tag := 0..?U64_MAX}.
-type frame_event() :: next | {full, 0..?U64_MAX} | {answers, [{0..?U64_MAX, binary()}]}.
-type frame_action() :: {post, 0..?U64_MAX, [{out, binary()} | {out, {region, term()}} | {in, pos_integer()}]}
                      | wait | {done, [ok | {ok, [scanout()]}], 0..?U64_MAX} | {stop, term()}.

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

%% The resource's backing: the request's header, the resource and one entry, then the
%% region's segment, which erx_device:post/4 writes as the region's mem_entry, its device
%% address and length, so no address passes through here.
-spec attach_backing_request(1..?U32_MAX, term()) -> request().
attach_backing_request(ResourceId, Region) when ?IS_U32(ResourceId) ->
    Expect = {nodata, none},
    {[{out, <<(header(?ERX_VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING, none))/binary, ResourceId:32/little, 1:32/little>>},
      {out, {region, Region}}, {in, answer_size(Expect)}],
     Expect}.

%% erx_memdraw's code of a channel descriptor, as erx_chan:parse/1 reads it. Only the
%% channel the device can show is taken: format/1 admits x8r8g8b8 alone, which parse/1
%% always reads, so its match cannot fail.
-spec chan_code(erx_display:chan()) -> {ok, 0..?U32_MAX} | {error, {chan, binary()}}.
chan_code(Chan) ->
    case format(Chan) of
        {ok, _Format} ->
            {ok, Code, _Depth} = erx_chan:parse(Chan),
            {ok, Code};
        Refused ->
            Refused
    end.

%% The bytes of the screen image's region for a mode: its rows, and the word past them
%% that erx_memdraw:wrap/4 asks for.
-spec region_size({pos_integer(), pos_integer()}) -> pos_integer().
region_size({Width, Height}) -> Width * ?BYTES_PER_PIXEL * Height + ?WORD_PAST_ROWS.

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

%% The bring-up's first request, the display's size; MaxBytes bounds the screen image.
-spec setup_start(non_neg_integer()) -> {setup_action(), setup()}.
setup_start(MaxBytes) when is_integer(MaxBytes), MaxBytes >= 0 ->
    {{post, display_info_request()}, #{step => display_info, max_bytes => MaxBytes}}.

%% The bring-up's next action, from the answer to the step's request (decoded and checked
%% by the frame that carried it) or the region the driver made. Anything else for the step
%% stops it.
-spec setup_next(setup(), setup_event()) -> {setup_action(), setup()}.
setup_next(S = #{step := display_info, max_bytes := MaxBytes}, {answer, {ok, Scanouts}}) ->
    case mode(Scanouts, MaxBytes) of
        {ok, Mode} -> {{region, region_size(Mode)}, S#{step := region, mode => Mode}};
        {error, Reason} -> {{stop, {mode, Reason}}, S}
    end;
setup_next(S = #{step := region, mode := {Width, Height}}, {region, Region}) ->
    {ok, Format} = format(?CHAN),
    {{post, create_2d_request(?RESOURCE_ID, Format, Width, Height)}, S#{step := create, region => Region}};
setup_next(S = #{step := create, region := Region}, {answer, ok}) ->
    {{post, attach_backing_request(?RESOURCE_ID, Region)}, S#{step := attach}};
setup_next(S = #{step := attach, mode := Mode}, {answer, ok}) ->
    {{post, set_scanout_request(?SCANOUT, ?RESOURCE_ID, Mode)}, S#{step := scanout}};
setup_next(S = #{step := scanout, mode := {Width, Height}, region := Region}, {answer, ok}) ->
    {ok, Chan} = chan_code(?CHAN),
    Stride = Width * ?BYTES_PER_PIXEL,
    Geometry = #{width => Width, height => Height, stride => Stride, length => Stride * Height},
    {{ready, #{geometry => Geometry, region => Region, resource => ?RESOURCE_ID, chan => Chan}}, S};
setup_next(S = #{step := Step}, Event) ->
    {{stop, {unexpected, Step, Event}}, S}.

%% A frame of Requests whose first is posted under Tag.
-spec frame_start([request()], 0..?U64_MAX) -> frame().
frame_start(Requests, Tag) when is_integer(Tag), Tag >= 0, Tag =< ?U64_MAX ->
    #{todo => lists:enumerate(Requests), inflight => #{}, answers => #{}, tag => Tag}.

%% The frame's next action after Event: `next` after a post the queue took, and to begin;
%% `{full, Tag}` after the queue refused the post of Tag, whose request goes back to the
%% front; `{answers, Completions}`, what erx_device:complete/2 returned.
-spec frame_step(frame(), frame_event()) -> {frame_action(), frame()}.
frame_step(F = #{todo := [Next = {_Place, {Segments, _Expect}} | Rest], inflight := Inflight, tag := Tag}, next) ->
    {{post, Tag, Segments}, F#{todo := Rest, inflight := Inflight#{Tag => Next}, tag := (Tag + 1) band ?U64_MAX}};
frame_step(F = #{todo := [], inflight := Inflight, answers := Answers, tag := Tag}, next) ->
    case map_size(Inflight) of
        0 -> {{done, [Answer || {_Place, Answer} <- lists:sort(maps:to_list(Answers))], Tag}, F};
        _ -> {wait, F}
    end;
%% Only the post just made can be refused, so its tag is the next one's again and tags
%% stay consecutive; with nothing else in flight no answer would ever free the queue.
frame_step(F = #{todo := Todo, inflight := Inflight, tag := Next}, {full, Tag}) when (Tag + 1) band ?U64_MAX =:= Next ->
    case maps:take(Tag, Inflight) of
        {Posted, Rest} when map_size(Rest) > 0 -> {wait, F#{todo := [Posted | Todo], inflight := Rest, tag := Tag}};
        {_Posted, _Rest} -> {{stop, {queue, full}}, F};
        error -> {{stop, {tag, Tag}}, F}
    end;
frame_step(F, {full, Tag}) ->
    {{stop, {tag, Tag}}, F};
frame_step(F, {answers, Completions}) ->
    answer_each(Completions, F).

request(Request, Expect) -> {[{out, Request}, {in, answer_size(Expect)}], Expect}.

%% Each completion held to its request in turn; the first that fails stops the frame.
answer_each([], F) ->
    frame_step(F, next);
answer_each([{Tag, Bytes} | Rest], F = #{inflight := Inflight, answers := Answers}) ->
    case maps:take(Tag, Inflight) of
        {{Place, {_Segments, Expect}}, Left} ->
            case decode(Expect, Bytes) of
                {error, Reason} -> {{stop, {answer, Tag, Reason}}, F};
                Answer -> answer_each(Rest, F#{inflight := Left, answers := Answers#{Place => Answer}})
            end;
        error ->
            {{stop, {tag, Tag}}, F}
    end.

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
