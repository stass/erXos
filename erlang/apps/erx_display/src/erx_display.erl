%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The display driver's behaviour (docs/design-display.md, "The display device"). A display
%% driver is an Erlang process over the device NIF: a gen_server that implements the one
%% callback, info/1, and answers in its handle_call/3 the two requests this module defines,
%% request(). erx_screen is the one caller of both functions here, which the chokepoint
%% display-driver-callers (tools/lib/erx/chokepoint_rules/display.rb) holds. erx_screen
%% hands info/1 the driver's process.
%%
%% info/1 names the screen image, an erx_memdraw image of the display's size and channel
%% over memory the driver chose, which erx_screen composes into and nothing else writes;
%% whether a frame takes rectangles (partial) and whether it takes a client's buffer that
%% covers the screen (direct).
%%
%% flush_request/3 sends the driver one frame, the rectangles of the image that changed,
%% and returns at once with the request's id: erx_screen never waits on the driver. The
%% answer arrives as a message that gen_server:check_response/2 reads, `ok` when the device
%% has taken the rectangles, after which the device reads nothing of the image until the
%% next frame, or a refusal; the driver's end while it holds the frame ends the request as
%% gen_server's does. Until the answer the driver may read the image, which the request
%% holds a reference to; it clips every rectangle to the image and computes every offset
%% into it against its length.
%%
%% power_request/2 asks the driver to turn the panel on, dim it or turn it off, and is
%% answered the same way: `ok` once the panel is at that level, or a refusal.

-module(erx_display).

-export([flush_request/3, power_request/2]).
-export_type([chan/0, rect/0, info/0, level/0, request/0]).

%% A Plan 9 channel descriptor, such as <<"x8r8g8b8">>.
-type chan() :: binary().
%% A rectangle as Plan 9 has it: {X0, Y0, X1, Y1}, X0 and Y0 inside, X1 and Y1 just outside.
-type rect() :: erx_screen_core:rect().
-type info() :: #{width := pos_integer(), height := pos_integer(), chan := chan(),
                  screen := erx_memdraw:image(), partial := boolean(), direct := boolean()}.
-type level() :: on | dim | off.
%% What a driver's handle_call/3 is handed: a frame or a power level. A driver answers
%% anything else with a refusal, so no process that reaches it ends it.
-type request() :: {flush, [rect()], erx_memdraw:image()} | {power, level()}.

-callback info(Driver :: pid()) -> info().

%% One frame to Driver: the rectangles Rects of Image.
-spec flush_request(pid(), [rect()], erx_memdraw:image()) -> gen_server:request_id().
flush_request(Driver, Rects, Image) ->
    gen_server:send_request(Driver, {flush, Rects, Image}).

%% The panel of Driver to Level.
-spec power_request(pid(), level()) -> gen_server:request_id().
power_request(Driver, Level) ->
    gen_server:send_request(Driver, {power, Level}).
