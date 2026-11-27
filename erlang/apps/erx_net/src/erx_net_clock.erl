%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_clock).
-moduledoc """
The stack's one source of what differs from one run to the next: the time, the timers and
the random keys (docs/design-network-stack.md, "The clock"). Every process of erx_net reads
the time, arms its one timer and draws entropy here and nowhere else, which the build checks
of tools/lib/erx/net_checks.rb enforce for calls; the two exceptions they allow pace a
supervisor or a device on the host's clock: the driver's hold and the Pi 4 Ethernet's MDIO
and PHY waits.

The clock is chosen once, by `select/1`, before any process of the stack starts:

* `monotonic`, the default: `erlang:monotonic_time(microsecond)`, `erlang:send_after/4` at
  the deadline rounded up to the millisecond, and `erx_bytes:entropy/1`;
* `{virtual, Clock}`: a test's clock process, to be served by `erx_net_vclock`, test code
  that no image or release holds. That module is not built (docs/todo-network.md), so
  `select/1` refuses a virtual clock with `{error, {seam, clock, erx_net_vclock}}` and the
  stack runs only on the monotonic clock.

A hint, the message `{erx_net_clock, hint}`, is only a hint: a process that gets one
looks at its own deadlines, which may have moved. `arm_by/2` keeps at most one timer per
caller, as the virtual clock keeps one deadline per caller: it arms only when the new
deadline is earlier than the armed one, and then cancels the armed timer. A process passes
its `armed()` through `hinted/1` when a hint arrives: the cancel is asynchronous, so the
hint may be the replaced timer's, and only a hint at or after the armed deadline is that
timer's own. Both sources keep the contract this rests on: the hint for a deadline arrives
only once `now/0` has reached it (`send_after/4` at the deadline rounded up, never early;
the virtual clock sets the time before it sends).
""".

-export([select/1, now/0, arm/1, arm_by/2, hinted/1, entropy/1]).
-compile({no_auto_import, [now/0]}).

-export_type([source/0, armed/0]).

-define(KEY, {?MODULE, source}).

-doc "Where the time, the timers and the entropy come from.".
-type source() :: monotonic | {virtual, Clock :: pid()}.

-doc """
The one timer a process has pending: its deadline and the timer to cancel when an earlier
one replaces it, or `infinity` when none is pending.
""".
-type armed() :: {integer(), reference()} | infinity.

-doc """
Chooses the clock for every process of the stack on this node. Refuses a virtual clock,
whose `erx_net_vclock` is not built (docs/todo-network.md).
""".
-spec select(source()) -> ok | {error, {seam, clock, erx_net_vclock} | {clock, term()}}.
select(monotonic) ->
    persistent_term:put(?KEY, monotonic);
select({virtual, Clock}) when is_pid(Clock) ->
    {error, {seam, clock, erx_net_vclock}};
select(Other) ->
    {error, {clock, Other}}.

-doc "The current time in microseconds.".
-spec now() -> integer().
now() ->
    case source() of
        monotonic -> erlang:monotonic_time(microsecond)
    end.

-doc """
Asks for `{erx_net_clock, hint}` to reach the caller at or after `Deadline`, in
microseconds.
""".
-spec arm(integer()) -> ok.
arm(Deadline) when is_integer(Deadline) ->
    _ = start(Deadline),
    ok.

-doc """
Arms `Next` when no timer is pending or it comes before the pending one, which it then
cancels, and returns what is armed now.
""".
-spec arm_by(integer() | infinity, armed()) -> armed().
arm_by(infinity, Armed) ->
    Armed;
arm_by(Next, infinity) ->
    {Next, start(Next)};
arm_by(Next, {Deadline, Timer}) when Next < Deadline ->
    _ = cancel(Timer),
    {Next, start(Next)};
arm_by(_Next, Armed) ->
    Armed.

-doc """
What is armed once a hint has arrived: nothing when the armed deadline has passed, since
its timer has fired; otherwise the hint was a replaced timer's, and the armed one is still
pending.
""".
-spec hinted(armed()) -> armed().
hinted({Deadline, _Timer} = Armed) ->
    case Deadline =< now() of
        true -> infinity;
        false -> Armed
    end;
hinted(infinity) ->
    infinity.

start(Deadline) ->
    case source() of
        monotonic -> erlang:send_after(ceil_ms(Deadline), self(), {?MODULE, hint}, [{abs, true}])
    end.

cancel(Timer) -> erlang:cancel_timer(Timer, [{async, true}, {info, false}]).

-doc "`N` bytes for a key. Raises when the source fails.".
-spec entropy(pos_integer()) -> binary().
entropy(N) ->
    case source() of
        monotonic -> erx_bytes:entropy(N)
    end.

%% Microseconds to milliseconds, rounded up: div truncates towards zero.
ceil_ms(Us) when Us >= 0 -> (Us + 999) div 1000;
ceil_ms(Us) -> Us div 1000.

source() ->
    persistent_term:get(?KEY, monotonic).
