%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The display driver's behaviour (docs/design-display.md, "The display device"). A display
%% driver is an Erlang process over the device NIF: a gen_server that implements the one
%% callback, info/1, and answers in its handle_call/3 the two requests this module defines,
%% request(). erx_screen is the one caller of both functions here, which the build check
%% DisplayDriverCallers (tools/lib/erx/display_driver_callers.rb) holds. erx_screen hands
%% info/1 the driver's process.
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

-export([flush_request/3, power_request/2, chan_format/1]).
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

-doc """
The format of channel descriptor `Chan`, as draw(2)'s `strtochan` reads one:
`{ok, Code, Depth}`, the descriptor as `erx_memdraw` takes a channel, one
byte of type and bits for each channel, the first channel in the highest
byte, and the bits of a pixel; `{error, einval}` for a descriptor of no
channel, more than four, a letter outside `rgbkamx`, a channel of no bits
or more than 8, or a depth that is not a whole divisor or multiple of 8.
""".
-spec chan_format(chan()) -> {ok, 0..16#ffffffff, 1..32} | {error, einval}.
chan_format(Chan) when is_binary(Chan) ->
    chan_format(Chan, 0, 0, 0);
chan_format(_) ->
    {error, einval}.

%% draw(2)'s channel types: CRed 0, CGreen 1, CBlue 2, CGrey 3, CAlpha 4, CMap 5,
%% CIgnore 6.
chan_format(<<Letter, Bits, Rest/binary>>, Code, Depth, Count)
  when Bits >= $1, Bits =< $8, Count < 4 ->
    case chan_type(Letter) of
        error -> {error, einval};
        Type -> chan_format(Rest, (Code bsl 8) bor (Type bsl 4) bor (Bits - $0),
                            Depth + Bits - $0, Count + 1)
    end;
chan_format(<<>>, Code, Depth, Count) when Count > 0, (Depth rem 8 =:= 0 orelse 8 rem Depth =:= 0) ->
    {ok, Code, Depth};
chan_format(_, _, _, _) ->
    {error, einval}.

chan_type($r) -> 0;
chan_type($g) -> 1;
chan_type($b) -> 2;
chan_type($k) -> 3;
chan_type($a) -> 4;
chan_type($m) -> 5;
chan_type($x) -> 6;
chan_type(_) -> error.
