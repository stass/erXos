%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The firmware framebuffer's display driver (docs/design-display.md, "The display device"):
%% the process that drives the framebuffer a board's firmware set up, the Raspberry Pi's,
%% registered as erx_fb, and implements erx_display for erx_screen, its one caller. Its
%% decisions are erx_firmware_fb_core's.
%%
%% Its start, and every restart, takes the domain's framebuffer record, checks it
%% (erx_firmware_fb_core:plan/1), maps the framebuffer with erx_device:framebuffer/0, which
%% gives a restart the same mapping, and allocates the screen image, an erx_memdraw image of
%% the framebuffer's size and channel in the driver's own memory. The framebuffer is device
%% memory, which takes no unaligned access, so erx_screen composes into the screen image and
%% never into the framebuffer. A record the core refuses, or a step that fails, gives one
%% line in the kernel log and no process: init/1 returns ignore, so the domain goes on
%% without a screen.
%%
%% A frame, which erx_screen sends with erx_display:flush_request/3, copies its rectangles,
%% clipped to the screen, into the framebuffer with erx_memdraw:store/4 and is answered at
%% once: the display hardware scans the framebuffer out all along, and nothing reads the
%% screen image after the copy. The firmware's framebuffer has no completion or vertical
%% blank this driver can wait for, so a client is paced by the copy. erx_screen hands a frame
%% only the screen image, since the driver reports direct false, and the driver refuses any
%% other image. Nothing here reads the display hardware's registers, which no domain holds.

-module(erx_firmware_fb).
-behaviour(gen_server).
-behaviour(erx_display).

-export([start_link/1]).
-export([info/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% The screen image's colour before erx_screen first paints it: opaque black, as RGBA.
-define(BLACK, 16#000000ff).

%% fb is erx_device:framebuffer/0's name, stride the framebuffer's, and info what erx_screen
%% reads; all are fixed once init/1 returns.
-record(state, {fb :: erx_device:framebuffer(), stride :: pos_integer(), info :: erx_display:info()}).

%% The driver of Record, a framebuffer record, registered as erx_fb.
-spec start_link(erx_device_record:framebuffer()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Record) ->
    gen_server:start_link({local, erx_fb}, ?MODULE, Record, []).

%% erx_display's one callback, as erx_screen calls it with the driver's process.
-spec info(pid()) -> erx_display:info().
info(Driver) ->
    gen_server:call(Driver, info).

%% Any exception of the start, a bug or a NIF that changed, is one line and no process as well.
init(Record) ->
    case try start(Record) catch Class:Raised -> {error, {Class, Raised}} end of
        {ok, State = #state{stride = Stride, info = #{width := Width, height := Height, chan := Chan}}} ->
            log("framebuffer ~bx~b stride ~b ~s", [Width, Height, Stride, Chan]),
            {ok, State};
        {error, Reason} ->
            log("the framebuffer is not driven: ~0p", [Reason]),
            ignore
    end.

start(Record) ->
    maybe
        {ok, #{chan := Chan, code := Code, width := Width, height := Height, stride := Stride}} ?=
            erx_firmware_fb_core:plan(Record),
        {ok, Fb} ?= step(framebuffer, erx_device:framebuffer()),
        Rect = {0, 0, Width, Height},
        {ok, Screen} ?= step(alloc, erx_memdraw:alloc(Code, Rect, Rect, false, ?BLACK)),
        ok ?= step(store, erx_memdraw:store(Screen, Fb, Stride, [Rect])),
        Info = #{width => Width, height => Height, chan => Chan, screen => Screen, partial => true,
                 direct => false},
        {ok, #state{fb = Fb, stride = Stride, info = Info}}
    end.

step(_Name, ok) -> ok;
step(_Name, {ok, Value}) -> {ok, Value};
step(Name, {error, Reason}) -> {error, {Name, Reason}}.

%% erx_display's requests (erx_display:request()) and info. A frame's answer is ok once its
%% rectangles are stored, or {error, einval} for a frame that is not of the screen image or
%% whose rectangles are not a list of four integers each. The firmware's framebuffer has no
%% panel power this driver controls, so every power level is answered ok and the screen
%% stays as erx_screen leaves it.
handle_call(info, _From, State = #state{info = Info}) ->
    {reply, Info, State};
handle_call({power, Level}, _From, State) when Level =:= on; Level =:= dim; Level =:= off ->
    {reply, ok, State};
handle_call({flush, Rects, Screen}, _From,
            State = #state{fb = Fb, stride = Stride, info = #{screen := Screen, width := Width, height := Height}}) ->
    case erx_firmware_fb_core:frame(Rects, Width, Height) of
        {ok, []} -> {reply, ok, State};
        {ok, Clipped} -> {reply, erx_memdraw:store(Screen, Fb, Stride, Clipped), State};
        {error, einval} -> {reply, {error, einval}, State}
    end;
%% A flush of anything but the screen image, and any other call: refused, not crashed on,
%% so no process that reaches the driver ends it.
handle_call(_Other, _From, State) ->
    {reply, {error, einval}, State}.

handle_cast(_Other, State) ->
    {noreply, State}.

handle_info(_Other, State) ->
    {noreply, State}.

%% One line of the kernel log. Every value in it is an integer, a fixed atom of this driver's,
%% its core's or the NIFs', or the channel's text, which erx_chan parsed from a format name of
%% the record reader's fixed table, never bytes of the device tree.
log(Format, Arguments) ->
    _ = erx_log:debug(["erx_fb: ", io_lib:format(Format, Arguments)]),
    ok.
