%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_screen).
-moduledoc """
The screen (docs/design-display.md, "The screen and its one path to the
device"): the one process that writes the screen image and the one sender
of frames to the display driver, as `{flush, Rects, Image}` requests (TODO.md, the
flush request). Its decisions are `erx_screen_core`'s;
this process performs the plans the core returns, filling with
`erx_memdraw`, and hands the driver each plan's pushed rectangles as one
frame.

It shows the empty layout: at start it reads the driver's `info/1`, makes
the core's state for the screen's rectangle and the background colour,
fills what the core's repaint names and flushes the result. Windows,
presents, the overlay and the layouts of `erx_winfs` are not served yet,
so the repaint at start is the only frame (TODO.md, the display domain).

A frame is sent with `gen_server:send_request/2` and its answer, or the
driver's end, arrives as a message, so the screen never waits on the
driver; while a frame is out the screen writes nothing. The driver's end
also ends this process: the supervisor that starts both, `erx_fb_sup`,
is `rest_for_one` with the driver first, so a restarted driver is
followed by a new screen whose start is the repaint the design asks for
after a driver's restart. That supervisor is the driver application's
only because the split of `erx_display` into a client-side and a
display-side application is undecided (TODO.md, "The display domain:
split erlang/apps/erx_display").
""".
-behaviour(gen_server).

-export([start_link/1, background/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% The background colour as erx_memdraw takes a colour, 0xRRGGBBAA: a slate
%% blue, which no blank or black screen shows, so a screenshot tells a filled
%% and flushed screen from one that was not.
-define(BACKGROUND, 16#3a6ea5ff).
%% The fill's source channel, Plan 9's RGB24: CHAN3(CRed, 8, CGreen, 8,
%% CBlue, 8) of draw(2)'s draw.h, red's type 0, green's 1 and blue's 2, each
%% a byte of type and bits, the first channel in the highest byte.
-define(FILL_CHAN, 16#081828).
%% draw(2)'s SoverD, the operation draw(3) applies by default.
-define(SOVERD, 11).
%% A replicated source covers any rectangle of the screen.
-define(EVERYWHERE, {-16#80000000, -16#80000000, 16#7fffffff, 16#7fffffff}).

-record(state, {driver :: pid(),
                screen :: erx_memdraw:image(),
                core :: erx_screen_core:state(),
                %% The frame the driver holds, or none.
                frame = none :: none | gen_server:request_id()}).

-doc """
The screen over the driver `{Module, Name}`, an `erx_display` callback
module and the name its process is registered under, registered as
`erx_screen`. With no process of that name, as after a driver whose start
found no device, there is no screen: `ignore`.
""".
-spec start_link({module(), atom()}) -> {ok, pid()} | ignore | {error, term()}.
start_link(Driver) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Driver, []).

-doc "The colour of the screen where no window is shown.".
-spec background() -> erx_screen_core:color().
background() -> ?BACKGROUND.

-doc false.
init({Module, Name}) ->
    case whereis(Name) of
        undefined ->
            ignore;
        Driver ->
            #{width := Width, height := Height, screen := Screen, partial := Partial} = Module:info(Driver),
            Rect = {0, 0, Width, Height},
            {ok, Core0} = erx_screen_core:new(Rect, ?BACKGROUND),
            {Plan, Core} = erx_screen_core:repaint(Core0),
            ok = fill(Screen, maps:get(fill, Plan)),
            Push = case Partial of
                       true -> maps:get(push, Plan);
                       false -> [Rect]
                   end,
            {ok, send(Push, #state{driver = Driver, screen = Screen, core = Core})}
    end.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, {error, einval}, State}.

-doc false.
handle_cast(_Request, State) ->
    {noreply, State}.

%% The frame's answer: ok, or a refusal after which the driver ends; either way the
%% frame is over, as it is when the driver ends while it holds it: then the supervisor
%% ends this process and starts it again behind the restarted driver.
-doc false.
handle_info(Message, State = #state{frame = Frame}) when Frame =/= none ->
    case gen_server:check_response(Message, Frame) of
        no_reply -> {noreply, State};
        {reply, ok} -> {noreply, State#state{frame = none}};
        {reply, Refused} ->
            _ = erx_log:debug(["erx_screen: the driver refused a frame: ", io_lib:format("~0p", [Refused])]),
            {noreply, State#state{frame = none}};
        {error, {_Reason, _Driver}} -> {noreply, State#state{frame = none}}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

%% Each of the plan's fills, a rectangle and a colour, drawn into the screen image
%% from a replicated pixel of the colour.
fill(Screen, Fills) ->
    lists:foreach(fun({R, Color}) ->
                          {ok, Source} = erx_memdraw:alloc(?FILL_CHAN, {0, 0, 1, 1}, ?EVERYWHERE, true, Color),
                          {ok, _Touched} = erx_memdraw:draw(Screen, R, Source, {0, 0}, opaque, {0, 0}, ?SOVERD, dst)
                  end, Fills).

%% One frame of the rectangles Push, unless there are none.
send([], State) ->
    State;
send(Push, State = #state{driver = Driver, screen = Screen, frame = none}) ->
    State#state{frame = gen_server:send_request(Driver, {flush, Push, Screen})}.
