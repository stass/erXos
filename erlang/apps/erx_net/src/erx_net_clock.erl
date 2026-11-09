%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_clock).
-moduledoc """
The stack's one source of what differs from one run to the next: the time, the timers and
the random keys (docs/design-network-stack.md, "The clock"). Every process of erx_net reads
the time, arms its one timer and draws entropy here and nowhere else, which the build checks
of tools/lib/erx/net_checks.rb enforce.

The clock is chosen once, by `select/1`, before any process of the stack starts:

* `monotonic`, the default: `erlang:monotonic_time(microsecond)`, `erlang:send_after/4` at
  the deadline rounded up to the millisecond, and `erx_bytes:entropy/1`;
* `{virtual, Clock}`: a test's clock process served by `erx_net_vclock`, test code that no
  image or release holds. Where that module is absent, `select/1` refuses with
  `{error, {seam, clock, erx_net_vclock}}`, so a production build cannot run on a virtual
  clock.

A hint, the message `{erx_net_clock, hint}`, is only a hint: a process that gets one
looks at its own deadlines, which may have moved. `arm_by/2` keeps at most one timer per
caller, as the virtual clock keeps one deadline per caller: it arms only when the new
deadline is earlier than the armed one, and then cancels the armed timer. A process sets
its `armed()` to `infinity` when a hint arrives, since the one timer it had has fired.
""".

-export([select/1, now/0, arm/1, arm_by/2, entropy/1]).

-export_type([source/0, armed/0]).

-define(KEY, {?MODULE, source}).

-doc "Where the time, the timers and the entropy come from.".
-type source() :: monotonic | {virtual, Clock :: pid()}.

-doc """
The one timer a process has pending: its deadline and the timer to cancel when an earlier
one replaces it (`none` under the virtual clock, which keeps the earliest itself), or
`infinity` when none is pending.
""".
-type armed() :: {integer(), reference() | none} | infinity.

-doc """
Chooses the clock for every process of the stack on this node. Refuses a virtual clock
when the build holds no `erx_net_vclock`.
""".
-spec select(source()) -> ok | {error, {seam, clock, erx_net_vclock} | {clock, term()}}.
select(monotonic) ->
    persistent_term:put(?KEY, monotonic);
select({virtual, Clock} = Source) when is_pid(Clock) ->
    case code:ensure_loaded(erx_net_vclock) of
        {module, erx_net_vclock} -> persistent_term:put(?KEY, Source);
        {error, _} -> {error, {seam, clock, erx_net_vclock}}
    end;
select(Other) ->
    {error, {clock, Other}}.

-doc "The current time in microseconds.".
-spec now() -> integer().
now() ->
    case source() of
        monotonic -> erlang:monotonic_time(microsecond);
        {virtual, Clock} -> erx_net_vclock:now(Clock)
    end.

-doc """
Asks for `{erx_net_clock, hint}` to reach the caller at or after `Deadline`, in
microseconds.
""".
-spec arm(integer()) -> ok.
arm(Deadline) when is_integer(Deadline) ->
    case source() of
        monotonic ->
            _ = start(Deadline),
            ok;
        {virtual, _} ->
            _ = start(Deadline),
            ok
    end.

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

start(Deadline) ->
    case source() of
        monotonic -> erlang:send_after(ceil_ms(Deadline), self(), {?MODULE, hint}, [{abs, true}]);
        {virtual, Clock} -> ok = erx_net_vclock:arm(Clock, self(), Deadline), none
    end.

cancel(none) -> ok;
cancel(Timer) -> erlang:cancel_timer(Timer, [{async, true}, {info, false}]).

-doc "`N` bytes for a key. Raises when the source fails.".
-spec entropy(pos_integer()) -> binary().
entropy(N) ->
    case source() of
        monotonic -> erx_bytes:entropy(N);
        {virtual, Clock} -> erx_net_vclock:entropy(Clock, N)
    end.

%% Microseconds to milliseconds, rounded up: div truncates towards zero.
ceil_ms(Us) when Us >= 0 -> (Us + 999) div 1000;
ceil_ms(Us) -> Us div 1000.

source() ->
    persistent_term:get(?KEY, monotonic).
