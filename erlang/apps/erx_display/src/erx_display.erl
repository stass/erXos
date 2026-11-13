%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The display driver's behaviour (docs/design-display.md, "The display device"). A display
%% driver is an Erlang process over the device NIF that implements these callbacks;
%% erx_screen is their one caller.
%%
%% info/1 names the screen image, an erx_memdraw image of the display's size and channel
%% over memory the driver chose, which erx_screen composes into and nothing else writes;
%% whether flush/3 takes rectangles (partial) and whether it takes a client's buffer that
%% covers the screen (direct).
%%
%% flush/3 makes the device show the rectangles of the image that changed, and returns when
%% the device has taken them: after that the device reads nothing of the image until the
%% next flush. The driver reads the image only while the callback runs, clips every
%% rectangle to it and computes every offset into it against its length.
%%
%% power/2 turns the panel on, dims it or turns it off.

-module(erx_display).

-export_type([chan/0, rect/0, info/0]).

%% A Plan 9 channel descriptor, such as <<"x8r8g8b8">>.
-type chan() :: binary().
%% A rectangle as Plan 9 has it: {X0, Y0, X1, Y1}, X0 and Y0 inside, X1 and Y1 just outside.
-type rect() :: erx_screen_core:rect().
-type info() :: #{width := pos_integer(), height := pos_integer(), chan := chan(),
                  screen := erx_memdraw:image(), partial := boolean(), direct := boolean()}.

-callback info(State :: term()) -> info().
-callback flush(Rects :: [rect()], Image :: erx_memdraw:image(), State :: term()) -> {ok, State :: term()}.
-callback power(on | dim | off, State :: term()) -> {ok, State :: term()}.
