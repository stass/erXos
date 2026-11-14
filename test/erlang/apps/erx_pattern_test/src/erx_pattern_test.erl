%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pattern_test).
-moduledoc """
The display suite's client (tools/lib/erx/display_domain.rb): a session the
start row keeps on the display. It opens a window with `erx_win:open/2` on
the grant its registry holds under the display's service name, `display`
(docs/design-system.md, "Facets a configured domain serves"), draws a known
pattern into the window's buffer and presents it, so a screenshot of the
display shows the pattern (docs/design-display.md, "Erlang clients" and
"A display's session").

show/0 logs `erx_pattern_test: started`, then opens the window, retrying
while the session holds no grant of the display or no pixel area to it,
both of which arrive after the session starts, as `{error, none}`. It fills
the window with the rectangles of pattern/0, in order, presents the whole
window and logs one notice, which the console prints under the session's
name:

    erx_pattern_test: presented

or `erx_pattern_test: {error, Step, Reason}` naming the step that failed,
`open` when the window was refused or the wait of ?POLLS polls ran out
(Reason `none`). Once presented, it reads the window's input, which the
harness types through QMP: the first typed rune among the next ?KBD_READS
records of its `kbd` file, then the first record of its `mouse` file, each
logged as one notice,

    erx_pattern_test: kbd {typed,97}
    erx_pattern_test: mouse {0,0,0}

the mouse record's position and buttons, or one notice naming the read that
failed. The process then waits for ever: it holds the window, which ends
when its holder does.
""".

-export([show/0, pattern/0]).

-define(DISPLAY, display).
-define(POLLS, 240).
-define(POLL_MS, 500).
-define(KBD_READS, 8).
%% The fill's three constants are erx_screen's (erlang/apps/erx_display/src/erx_screen.erl).
%% A fill's source channel, Plan 9's RGB24: CHAN3(CRed, 8, CGreen, 8, CBlue, 8)
%% of draw(2)'s draw.h, the first channel in the highest byte, as erx_screen fills.
-define(FILL_CHAN, 16#081828).
%% draw(2)'s operation S, which copies the source.
-define(S, 10).
%% A replicated one-pixel source covers any rectangle.
-define(EVERYWHERE, {-16#80000000, -16#80000000, 16#7fffffff, 16#7fffffff}).

-doc """
The pattern, as rectangles in window coordinates and colours as
`erx_memdraw` takes them, 0xRRGGBBAA, drawn in order: the whole window in a
pale orange, then a red, a green and a blue square of 256 pixels a side on
one row. Every colour has three different channels or is a primary, so a
swapped channel moves a colour to another square. The squares fit any
window of at least 960 by 320 pixels; the first rectangle is clipped to the
window.
""".
-spec pattern() -> [{erx_win_core:rect(), 0..16#ffffffff}].
pattern() ->
    [{{0, 0, 16#4000, 16#4000}, 16#f0c080ff},
     {{64, 64, 320, 320}, 16#ff0000ff},
     {{384, 64, 640, 320}, 16#00ff00ff},
     {{704, 64, 960, 320}, 16#0000ffff}].

-spec show() -> no_return().
show() ->
    logger:notice("erx_pattern_test: started"),
    case presented() of
        {ok, Window} ->
            logger:notice("erx_pattern_test: presented"),
            read_input(Window);
        Failed ->
            logger:notice("erx_pattern_test: ~0p", [Failed])
    end,
    receive after infinity -> ok end.

presented() ->
    maybe
        {ok, Window} ?= step(open, opened(?POLLS)),
        {ok, Image} ?= step(image, erx_win:image(Window)),
        ok ?= step(draw, drawn(Image, pattern())),
        ok ?= step(present, erx_win:present(Window, [])),
        {ok, Window}
    end.

%% The window's first typed rune, from its kbd file, then its first mouse record, each
%% logged as one notice; a read that fails is logged instead and ends the reads.
read_input(Window) ->
    maybe
        {ok, Typed} ?= typed(Window, ?KBD_READS),
        logger:notice("erx_pattern_test: kbd ~0p", [Typed]),
        {ok, {mouse, X, Y, Buttons, _Msec}} ?= erx_win:mouse(Window),
        logger:notice("erx_pattern_test: mouse ~0p", [{X, Y, Buttons}])
    else
        Failed -> logger:notice("erx_pattern_test: kbd or mouse read ~0p", [Failed])
    end.

%% The first typed record among the next N kbd records: a key's down and up come as
%% records of the keys held besides its typed rune.
typed(_Window, 0) ->
    {error, no_typed};
typed(Window, N) ->
    case erx_win:kbd(Window) of
        {ok, {typed, _} = Typed} -> {ok, Typed};
        {ok, _Held} -> typed(Window, N - 1);
        {error, _} = Error -> Error
    end.

%% Ends: each retry lowers the finite count.
opened(0) ->
    {error, none};
opened(N) ->
    case erx_win:open(?DISPLAY, #{name => <<"pattern">>}) of
        {error, none} -> timer:sleep(?POLL_MS), opened(N - 1);
        Answer -> Answer
    end.

drawn(_Image, []) ->
    ok;
drawn(Image, [{Rect, Color} | Rest]) ->
    maybe
        {ok, Source} ?= erx_memdraw:alloc(?FILL_CHAN, {0, 0, 1, 1}, ?EVERYWHERE, true, Color),
        {ok, _} ?= erx_memdraw:draw(Image, Rect, Source, {0, 0}, opaque, {0, 0}, ?S, dst),
        drawn(Image, Rest)
    end.

step(_Step, {ok, _} = Done) -> Done;
step(_Step, ok) -> ok;
step(Step, {error, Reason}) -> {error, Step, Reason}.
