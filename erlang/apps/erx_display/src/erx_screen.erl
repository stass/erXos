%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_screen).
-moduledoc """
The screen (docs/design-display.md, "The screen and its one path to the
device"): the one process that reads clients' buffers, the one that writes
the screen image and the one sender of frames to the display driver, each
through `erx_display:flush_request/3`. Its decisions are
`erx_screen_core`'s; this process performs the plans the core returns,
filling and copying with `erx_memdraw`, and hands the driver each plan's
pushed rectangles as one frame.

At start it reads the driver's `info/1`, attaches to `erx_winfs`
(erx_winfs:attach/2), which answers the layout, paints the whole screen
from it and asks every shown window to present again, since it holds no
image of any buffer. After that it takes:

* a **layout** from `erx_winfs`, the shown windows topmost first: the
  core's plan fills the decorations and background, and copies the part
  of each window the screen does not already show from the image of its
  last present; where a window's buffer does not reach its rectangle,
  and for a window it holds no image of, it fills the background, and it
  asks a window it holds no image of to present again. Images of windows
  the layout no longer shows are dropped;
* a **present** from a window (present_request/2): an image over the
  buffer in the client's pixel area, `erx_memdraw:wrap/4`, which checks
  the range against the area again; for a shown window the core's plan
  names the rectangles to copy and push, and the present is answered when
  the driver has taken the frame that shows it; a hidden window's present
  copies nothing and is answered at once.

A frame's request returns at once and its answer, or the driver's end,
arrives as a message, so the screen never waits on the driver, and while
a frame is out the screen writes nothing into the screen image. What
arrives meanwhile is **pending state** of fixed size: one layout, which a
later one replaces, and one waiting present for each window, a window
having at most one in flight. When the frame is answered, the screen
answers its presents, applies the pending layout, then the waiting
presents, and sends what they push as one frame.

The core is made with the direct path closed: the core decides that path
from the layout alone, without the buffer's size the design asks for, so
every frame takes the copy path (TODO.md, the display domain).

A window's end, seen by the screen's monitor on it, drops its image and
its waiting present. The driver's end also ends this process: the
supervisor that starts both, `erx_fb_sup`, is `rest_for_one` with the
driver before the screen, so a restarted driver is followed by a new
screen whose start is the repaint the design asks for after a driver's
restart.
""".
-behaviour(gen_server).

-export([start_link/1, background/0, present_request/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% The background colour as erx_memdraw takes a colour, 0xRRGGBBAA: a slate
%% blue, which no blank or black screen shows, so a screenshot tells a filled
%% and flushed screen from one that was not.
-define(BACKGROUND, 16#3a6ea5ff).
%% The fill's source channel, Plan 9's RGB24: CHAN3(CRed, 8, CGreen, 8,
%% CBlue, 8) of draw(2)'s draw.h, red's type 0, green's 1 and blue's 2, each
%% a byte of type and bits, the first channel in the highest byte.
-define(FILL_CHAN, 16#081828).
%% draw(2)'s operations: S, which copies the source, and SoverD.
-define(S, 10).
-define(SOVERD, 11).
%% A replicated source covers any rectangle of the screen.
-define(EVERYWHERE, {-16#80000000, -16#80000000, 16#7fffffff, 16#7fffffff}).

-record(state, {driver :: pid(),
                screen :: erx_memdraw:image(),
                rect :: erx_screen_core:rect(),
                partial :: boolean(),
                chan :: 0..16#ffffffff,
                core :: erx_screen_core:state(),
                %% The layout the core holds.
                layout = [] :: erx_screen_core:layout(),
                %% The frame the driver holds, or none, and the presents it shows.
                frame = none :: none | gen_server:request_id(),
                answers = [] :: [gen_server:from()],
                %% Pending while a frame is out.
                pending_layout = none :: none | erx_screen_core:layout(),
                waiting = #{} :: #{pos_integer() => {gen_server:from(), erx_memdraw:image(),
                                                    {pos_integer(), pos_integer()}, list()}},
                %% The image of each shown window's last present, keyed by window id:
                %% its process, the image and the buffer's width and height.
                images = #{} :: #{pos_integer() => {pid(), erx_memdraw:image(),
                                                   {pos_integer(), pos_integer()}}},
                monitors = #{} :: #{pid() => reference()}}).

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

-doc """
For window Id's process: asks the screen to show the buffer Present names,
`#{area, offset, width, height, rects}` with the rectangles in the
buffer's coordinates, none meaning the whole buffer. Returns at once; the
answer, `ok` or `{error, einval}`, or the screen's end, arrives as
`gen_server`'s response to the request. `{error, eio}` with no screen.
""".
-spec present_request(pos_integer(), map()) -> {ok, gen_server:request_id()} | {error, eio}.
present_request(Id, #{area := Area, offset := Offset, width := Width, height := Height,
                      rects := Rects}) ->
    case whereis(?MODULE) of
        undefined -> {error, eio};
        Pid -> {ok, gen_server:send_request(Pid, {present, Id, Area, Offset, Width, Height, Rects})}
    end.

-doc false.
init({Module, Name}) ->
    case whereis(Name) of
        undefined ->
            ignore;
        Driver ->
            #{width := Width, height := Height, screen := Screen, partial := Partial,
              chan := Chan} = Module:info(Driver),
            {ok, Code, _Depth} = erx_display:chan_format(Chan),
            Rect = {0, 0, Width, Height},
            {ok, Core} = erx_screen_core:new(Rect, ?BACKGROUND, false),
            State = #state{driver = Driver, screen = Screen, rect = Rect, partial = Partial,
                           chan = Code, core = Core},
            {Push, Laid} = apply_layout(erx_winfs:attach(Rect, Chan), State),
            {ok, send(Push, Laid)}
    end.

-doc false.
handle_call({present, Id, Area, Offset, Width, Height, Rects}, {Proc, _} = From,
            #state{chan = Chan} = State) when is_integer(Id), is_list(Rects) ->
    case erx_memdraw:wrap(Area, Offset, {0, 0, Width, Height}, Chan) of
        {ok, Image} ->
            Watched = watch(Proc, State),
            Present = {From, Image, {Width, Height}, Rects},
            case Watched of
                #state{frame = none} ->
                    {Push, Next} = present(Id, Present, Watched),
                    {noreply, answer_or_hold([From], Push, Next)};
                #state{waiting = Waiting} ->
                    ok = case Waiting of
                             #{Id := {Older, _, _, _}} -> gen_server:reply(Older, ok);
                             #{} -> ok
                         end,
                    {noreply, Watched#state{waiting = Waiting#{Id => Present}}}
            end;
        {error, _} ->
            {reply, {error, einval}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, einval}, State}.

-doc false.
handle_cast({layout, Layout}, #state{frame = none} = State) ->
    {Push, Next} = apply_layout(Layout, State),
    {noreply, send(Push, Next)};
handle_cast({layout, Layout}, State) ->
    {noreply, State#state{pending_layout = Layout}};
%% An input notice, for the idle clock the screen does not keep yet.
handle_cast(input, State) ->
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

%% The frame's answer: ok, or a refusal after which the driver ends; either way the
%% frame is over and its presents are answered, as when the driver ends while it
%% holds it: then the supervisor ends this process and starts it again behind the
%% restarted driver.
-doc false.
handle_info({'DOWN', Ref, process, Proc, _}, #state{monitors = Monitors} = State)
  when is_map_key(Proc, Monitors), map_get(Proc, Monitors) =:= Ref ->
    {noreply, forget(Proc, State)};
handle_info(Message, State = #state{frame = Frame}) when Frame =/= none ->
    case gen_server:check_response(Message, Frame) of
        no_reply ->
            {noreply, State};
        {reply, ok} ->
            {noreply, frame_over(State)};
        {reply, Refused} ->
            _ = erx_log:debug(["erx_screen: the driver refused a frame: ", io_lib:format("~0p", [Refused])]),
            {noreply, frame_over(State)};
        {error, {_Reason, _Driver}} ->
            {noreply, frame_over(State)}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

%% Answers the frame's presents, then takes what is pending: the layout, then each
%% window's waiting present, all pushed as one frame.
frame_over(#state{answers = Answers, pending_layout = Pending, waiting = Waiting} = State) ->
    _ = [gen_server:reply(From, ok) || From <- Answers],
    Over = State#state{frame = none, answers = [], pending_layout = none, waiting = #{}},
    {LayoutPush, Laid} = case Pending of
                             none -> {[], Over};
                             _ -> apply_layout(Pending, Over)
                         end,
    {Push, Froms, Presented} =
        maps:fold(fun(Id, {From, _, _, _} = Present, {PushAcc, FromAcc, S}) ->
                          {P, S1} = present(Id, Present, S),
                          {P ++ PushAcc, [From | FromAcc], S1}
                  end, {LayoutPush, [], Laid}, Waiting),
    answer_or_hold(Froms, Push, Presented).

%% Presents that pushed nothing are answered now; the rest with the frame.
answer_or_hold(Froms, [], State) ->
    _ = [gen_server:reply(From, ok) || From <- Froms],
    State;
answer_or_hold(Froms, Push, #state{answers = Answers} = State) ->
    send(Push, State#state{answers = Froms ++ Answers}).

%% Layouts -------------------------------------------------------------------

%% Brings the screen to Layout: the core's fills, and each window's copies from the
%% image the screen holds of it, the background where it holds none or where the
%% buffer does not reach. A window shown without an image is asked to present again.
apply_layout(Layout, #state{core = Core} = State) ->
    case erx_screen_core:layout(Layout, Core) of
        {ok, #{fill := Fills, copy := Copies, push := Push}, Core1} ->
            Shown = maps:from_list([{Id, Entry} || #{id := Id} = Entry <- Layout]),
            Kept = keep_images(Shown, State#state{core = Core1, layout = Layout}),
            ok = fill(Kept#state.screen, Fills),
            _ = [copy_window(Id, Rects, maps:get(Id, Shown), Kept) || {Id, Rects} <- Copies],
            _ = [Proc ! {erx_screen, present_again}
                 || #{id := Id, proc := Proc} <- Layout, not has_image(Id, Proc, Kept)],
            {Push, Kept};
        {error, einval} ->
            _ = erx_log:debug(["erx_screen: a malformed layout"]),
            {[], State}
    end.

%% Drops the image of every window the layout no longer shows from the same process,
%% and collects, so the area it maps is released.
keep_images(Shown, #state{images = Images} = State) ->
    Kept = maps:filter(fun(Id, {Proc, _, _}) ->
                               case Shown of
                                   #{Id := #{proc := Proc}} -> true;
                                   #{} -> false
                               end
                       end, Images),
    case map_size(Kept) =:= map_size(Images) of
        true -> State;
        false ->
            true = erlang:garbage_collect(),
            State#state{images = Kept}
    end.

has_image(Id, Proc, #state{images = Images}) ->
    case Images of
        #{Id := {Proc, _, _}} -> true;
        #{} -> false
    end.

copy_window(Id, Rects, #{proc := Proc, rect := {X0, Y0, _, _}},
            #state{images = Images, screen = Screen}) ->
    case Images of
        #{Id := {Proc, Image, {Width, Height}}} ->
            Bounds = {X0, Y0, X0 + Width, Y0 + Height},
            _ = [copy(Screen, Piece, Image, {X0, Y0}) || R <- Rects, Piece <- [intersect(R, Bounds)],
                                                         not is_empty(Piece)],
            fill(Screen, [{Piece, ?BACKGROUND} || R <- Rects, Piece <- subtract(R, Bounds)]);
        #{} ->
            fill(Screen, [{R, ?BACKGROUND} || R <- Rects])
    end.

%% Presents ------------------------------------------------------------------

%% A present of a window the layout shows from the presenting process: its image is
%% kept, and the core's rectangles are copied from it; any other copies nothing.
present(Id, {{Proc, _}, Image, {Width, Height}, Rects}, #state{layout = Layout} = State) ->
    case [Entry || #{id := I, proc := P} = Entry <- Layout, I =:= Id, P =:= Proc] of
        [#{rect := {X0, Y0, _, _}}] ->
            Kept = State#state{images = (State#state.images)#{Id => {Proc, Image, {Width, Height}}}},
            Bounds = {X0, Y0, X0 + Width, Y0 + Height},
            Placed = case Rects of
                         [] -> [Bounds];
                         _ -> [{A + X0, B + Y0, C + X0, D + Y0} || {A, B, C, D} <- Rects]
                     end,
            case erx_screen_core:present({Id, Proc}, Bounds, Placed, Kept#state.core) of
                {copy, Pieces} ->
                    _ = [copy(Kept#state.screen, Piece, Image, {X0, Y0}) || Piece <- Pieces],
                    {Pieces, Kept};
                {direct, _} ->
                    {[], Kept};
                {error, einval} ->
                    {[], Kept}
            end;
        [] ->
            {[], State}
    end.

watch(Proc, #state{monitors = Monitors} = State) ->
    case Monitors of
        #{Proc := _} -> State;
        #{} -> State#state{monitors = Monitors#{Proc => erlang:monitor(process, Proc)}}
    end.

%% A window's end drops its image and its waiting present.
forget(Proc, #state{images = Images, waiting = Waiting, monitors = Monitors} = State) ->
    Next = State#state{images = maps:filter(fun(_, {P, _, _}) -> P =/= Proc end, Images),
                       waiting = maps:filter(fun(_, {{P, _}, _, _, _}) -> P =/= Proc end, Waiting),
                       monitors = maps:remove(Proc, Monitors)},
    true = erlang:garbage_collect(),
    Next.

%% Drawing -------------------------------------------------------------------

%% Each of the plan's fills, a rectangle and a colour, drawn into the screen image
%% from a replicated pixel of the colour.
fill(Screen, Fills) ->
    lists:foreach(fun({R, Color}) ->
                          {ok, Source} = erx_memdraw:alloc(?FILL_CHAN, {0, 0, 1, 1}, ?EVERYWHERE, true, Color),
                          {ok, _Touched} = erx_memdraw:draw(Screen, R, Source, {0, 0}, opaque, {0, 0}, ?SOVERD, dst)
                  end, Fills).

%% Copies screen rectangle R from a window's image placed with its top left corner at
%% Origin.
copy(Screen, {X0, Y0, _, _} = R, Image, {OX, OY}) ->
    _ = erx_memdraw:draw(Screen, R, Image, {X0 - OX, Y0 - OY}, opaque, {0, 0}, ?S, dst),
    ok.

intersect({AX0, AY0, AX1, AY1}, {BX0, BY0, BX1, BY1}) ->
    {max(AX0, BX0), max(AY0, BY0), min(AX1, BX1), min(AY1, BY1)}.

is_empty({X0, Y0, X1, Y1}) -> X0 >= X1 orelse Y0 >= Y1.

%% R less B: at most four disjoint rectangles, the bands above and below B and the
%% parts left and right of it.
subtract({X0, Y0, X1, Y1} = R, B) ->
    {IX0, IY0, IX1, IY1} = I = intersect(R, B),
    case is_empty(I) of
        true -> [R];
        false ->
            [P || P <- [{X0, Y0, X1, IY0}, {X0, IY1, X1, Y1},
                        {X0, IY0, IX0, IY1}, {IX1, IY0, X1, IY1}],
                  not is_empty(P)]
    end.

%% One frame of the rectangles Push, unless there are none: the whole screen for a
%% driver that cannot flush part of it.
send([], State) ->
    State;
send(Push, #state{driver = Driver, screen = Screen, frame = none, partial = Partial,
                  rect = Rect} = State) ->
    Rects = case Partial of
                true -> Push;
                false -> [Rect]
            end,
    State#state{frame = erx_display:flush_request(Driver, Rects, Screen)}.
