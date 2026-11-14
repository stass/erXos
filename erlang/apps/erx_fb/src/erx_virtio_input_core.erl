%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_virtio_input_core).
-moduledoc """
The virtio-input driver's pure core (docs/design-display.md, "The
display device"): the parse of everything the device writes, its event
records and the configuration registers it answers a query in, and the
fold that turns the events of each update into the records the input
router takes,
`erx_input:record()`.

Every value and size comes through generated headers: the event layout
and the absinfo size from `abi/formats/virtio.txt` (OASIS Virtio 1.2,
section 5.8) in `erx_abi.hrl`, the configuration registers and SELECT's
values from peripheral VIRTIO_INPUT in `erx_hw_virtio_input.hrl`,
every evdev type, code and key state from `abi/formats/evdev.txt`, and
the bounds of a record from `abi/formats/input.txt`, which `erx_input`
holds records to as well. The bit syntax lays the event out field by
field, and a compile-time check below fails the build if the generated
offsets ever disagree with it.

Everything here reads what a device wrote, so it is untrusted input.
Each parse matches the exact layout or answers with a tagged reason, and
the fold counts what it cannot use; none of them raises on any input,
which `test/erlang/erx_virtio_input_core_fuzz.erl` checks.

event/1 reads one buffer of the event queue: an event the driver uses
becomes one of the closed set `event()` names, and one it does not use
is dropped with its reason, as section 5.8.6.1 asks ("A driver SHOULD
ignore eventq input events it does not recognize").

new/1 reads the one fact of the configuration space the fold needs, the
ranges of the device's two absolute axes, from the registers the driver
reads for each query queries/0 names;
it does not decide what kind of device it drives, so a device with keys
and axes sends both. fold/2 takes one buffer of the event queue at a time
and answers the records to send for it. Its state keeps of an update
only what it has not sent yet: the sum of its relative moves, the sum of
its wheel steps and whether it moved the position, besides the position
itself and the counts of the events it did not use. It never keeps an
event, so its size does not depend on how long an update runs.
""".

-export([event/1, absinfo/1, queries/0, new/1, fold/2, counts/1]).

-export_type([event/0, drop/0, query/0, read/0, range/0, unread/0, state/0, counts/0]).

-include("generated/erx_abi.hrl").
-include("generated/erx_hw_virtio_input.hrl").

%% A value the device NIF reads from an 8-bit register, and from a 32-bit one.
-define(BYTE(Value), (is_integer(Value) andalso Value >= 0 andalso Value =< 16#ff)).
-define(WORD(Value), (is_integer(Value) andalso Value >= 0 andalso Value =< 16#ffffffff)).

%% The generated layouts, as the bit syntax below lays them out.
-if(?ERX_VIRTIO_INPUT_EVENT_OFF_CODE =/= 2 orelse ?ERX_VIRTIO_INPUT_EVENT_OFF_VALUE =/= 4
    orelse ?ERX_VIRTIO_INPUT_EVENT_SIZE =/= 8).
-error("erx_virtio_input_core's bit syntax disagrees with abi/formats/virtio.txt").
-endif.

%% A relative event's delta is the layout's signed 32-bit value, and a new sum starts at
%% one event, so every such delta must lie within a record's range.
-if(?ERX_INPUT_REL_MIN > -16#80000000 orelse ?ERX_INPUT_REL_MAX < 16#7fffffff).
-error("a record's relative range in abi/formats/input.txt is narrower than an event's value").
-endif.

-doc """
One event the driver uses: the end of one update (`report`) or the device's word that it
dropped events since the last one (`dropped`); a key or button by its evdev code going up,
down or repeating; a move of a relative axis; a position on an absolute axis.
""".
-type event() :: {syn, report | dropped}
               | {key, Code :: 0..?ERX_EVDEV_KEY_MAX, up | down | repeat}
               | {rel, x | y | wheel, Delta :: -16#80000000..16#7fffffff}
               | {abs, x | y, Value :: -16#80000000..16#7fffffff}.
-doc "Why event/1 dropped a well-formed record: its type, or its code or value within the type.".
-type drop() :: {type, 0..16#ffff}
              | {syn, Code :: 0..16#ffff}
              | {key, Code :: 0..16#ffff, Value :: integer()}
              | {rel, Code :: 0..16#ffff}
              | {abs, Code :: 0..16#ffff}.
-doc "One query of the configuration space: the SELECT and SUBSEL the driver writes.".
-type query() :: {Select :: 0..255, Subsel :: 0..255}.
-doc "What the driver reads after a query: the SIZE, ABS_MIN and ABS_MAX registers' words.".
-type read() :: {Size :: 0..255, Min :: 0..16#ffffffff, Max :: 0..16#ffffffff}.
-doc "One absolute axis's range, from its ABS_INFO answer: Min is below Max.".
-type range() :: {Min :: -16#80000000..16#7fffffff, Max :: -16#80000000..16#7fffffff}.
-doc "Why new/1 could not read the axes: a query it was not handed, or a read absinfo/1 refused.".
-type unread() :: {missing, query()} | {query(), term()}.
-doc """
The events fold/2 did not use: those of another length than the layout's (`malformed`),
those event/1 dropped, a key's repeat and a position on a device without both axes
(`unused`), and those it skipped after `SYN_DROPPED` (`skipped`).
""".
-type counts() :: #{malformed := non_neg_integer(), unused := non_neg_integer(),
                    skipped := non_neg_integer()}.

-type rel() :: ?ERX_INPUT_REL_MIN..?ERX_INPUT_REL_MAX.
-type axis() :: 0..?ERX_INPUT_AXIS_MAX.
-type wheel() :: ?ERX_INPUT_WHEEL_MIN..?ERX_INPUT_WHEEL_MAX.
-record(fold, {
    %% The two absolute axes' ranges, or none when the device has not both.
    axes :: {range(), range()} | none,
    %% Folding updates, or skipping the rest of one whose start SYN_DROPPED lost.
    phase = folding :: folding | skipping,
    %% What this update has not sent yet: its relative sum, its wheel steps and whether
    %% it moved the position.
    rel = {0, 0} :: {rel(), rel()},
    wheel = 0 :: wheel(),
    moved = false :: boolean(),
    %% The position, each axis normalized, or none until that axis reports, from the
    %% start and again after SYN_DROPPED.
    position = {none, none} :: {axis() | none, axis() | none},
    counts = #{malformed => 0, unused => 0, skipped => 0} :: counts()}).
-opaque state() :: #fold{}.

-doc """
The event in one buffer of the event queue, Bytes being what the device wrote (the used
ring's length of it). The driver posts each buffer at exactly one event's size, so another
length means the device broke the layout: a record of another length than the layout's is
`{error, {length, N}}`; a well-formed record the driver does not use is `{drop, Why}`.
""".
-spec event(binary()) -> {ok, event()} | {drop, drop()} | {error, {length, non_neg_integer()}}.
event(<<Type:16/little, Code:16/little, Value:32/little-signed>>) -> typed(Type, Code, Value);
event(Bytes) -> {error, {length, byte_size(Bytes)}}.

typed(?ERX_EVDEV_EV_SYN, ?ERX_EVDEV_SYN_REPORT, _) -> {ok, {syn, report}};
typed(?ERX_EVDEV_EV_SYN, ?ERX_EVDEV_SYN_DROPPED, _) -> {ok, {syn, dropped}};
typed(?ERX_EVDEV_EV_SYN, Code, _) -> {drop, {syn, Code}};
typed(?ERX_EVDEV_EV_KEY, Code, Value) when Code =< ?ERX_EVDEV_KEY_MAX ->
    case Value of
        ?ERX_EVDEV_KEY_EVENT_UP -> {ok, {key, Code, up}};
        ?ERX_EVDEV_KEY_EVENT_DOWN -> {ok, {key, Code, down}};
        ?ERX_EVDEV_KEY_EVENT_REPEAT -> {ok, {key, Code, repeat}};
        _ -> {drop, {key, Code, Value}}
    end;
typed(?ERX_EVDEV_EV_KEY, Code, Value) -> {drop, {key, Code, Value}};
typed(?ERX_EVDEV_EV_REL, ?ERX_EVDEV_REL_X, Delta) -> {ok, {rel, x, Delta}};
typed(?ERX_EVDEV_EV_REL, ?ERX_EVDEV_REL_Y, Delta) -> {ok, {rel, y, Delta}};
typed(?ERX_EVDEV_EV_REL, ?ERX_EVDEV_REL_WHEEL, Delta) -> {ok, {rel, wheel, Delta}};
typed(?ERX_EVDEV_EV_REL, Code, _) -> {drop, {rel, Code}};
typed(?ERX_EVDEV_EV_ABS, ?ERX_EVDEV_ABS_X, Value) -> {ok, {abs, x, Value}};
typed(?ERX_EVDEV_EV_ABS, ?ERX_EVDEV_ABS_Y, Value) -> {ok, {abs, y, Value}};
typed(?ERX_EVDEV_EV_ABS, Code, _) -> {drop, {abs, Code}};
typed(Type, _, _) -> {drop, {type, Type}}.

-doc """
One axis's range from the registers read for its ABS_INFO query (section 5.8.4), after the
driver wrote SELECT and SUBSEL: `none` when SIZE is 0, the device having nothing for that
query (section 5.8.5.2), as QEMU's answers with zeros for an axis it lacks
(docs/research-virtio-input-qemu.md, "Configuration space", fact 10); otherwise SIZE must be
exactly one struct virtio_input_absinfo's, as section 5.8.5.1 asks the driver to check, and
ABS_MIN, read as a signed word, below ABS_MAX, so that the range normalizes. Each word must
fit its register, since the device NIF reads each at its declared width. The answer's
fuzz, flat and res are not read.
""".
-spec absinfo(read()) -> {ok, range() | none} | {error, {size, 0..255} | {range, integer(), integer()} | {read, term()}}.
absinfo({0, Min, Max}) when ?WORD(Min), ?WORD(Max) -> {ok, none};
absinfo({?ERX_VIRTIO_INPUT_ABSINFO_SIZE, Min, Max}) when ?WORD(Min), ?WORD(Max) ->
    case {signed(Min), signed(Max)} of
        {Low, High} when Low < High -> {ok, {Low, High}};
        {Low, High} -> {error, {range, Low, High}}
    end;
absinfo({Size, Min, Max}) when ?BYTE(Size), ?WORD(Min), ?WORD(Max) -> {error, {size, Size}};
absinfo(Read) -> {error, {read, Read}}.

signed(Word) ->
    <<Value:32/signed>> = <<Word:32>>,
    Value.

-doc "The queries new/1 needs, each the SELECT and SUBSEL the driver writes before its reads.".
-spec queries() -> [query()].
queries() ->
    [{?ERX_HW_VIRTIO_INPUT_SELECT_VALUE_ABS_INFO, ?ERX_EVDEV_ABS_X},
     {?ERX_HW_VIRTIO_INPUT_SELECT_VALUE_ABS_INFO, ?ERX_EVDEV_ABS_Y}].

-doc """
The fold of a device, from the registers read for each of queries/0. A device that lacks
either axis has no position. A query not handed, or a read absinfo/1 refuses, is an error
naming the query.
""".
-spec new(#{query() => read()}) -> {ok, state()} | {error, unread()}.
new(Reads) ->
    maybe
        {ok, X} ?= axis(?ERX_EVDEV_ABS_X, Reads),
        {ok, Y} ?= axis(?ERX_EVDEV_ABS_Y, Reads),
        {ok, #fold{axes = axes(X, Y)}}
    end.

axes({_, _} = X, {_, _} = Y) -> {X, Y};
axes(_X, _Y) -> none.

%% One axis's range, or none when the device answers that it has no such axis.
axis(Code, Reads) ->
    Query = {?ERX_HW_VIRTIO_INPUT_SELECT_VALUE_ABS_INFO, Code},
    case Reads of
        #{Query := Read} ->
            case absinfo(Read) of
                {ok, _} = Ok -> Ok;
                {error, Reason} -> {error, {Query, Reason}}
            end;
        #{} ->
            {error, {missing, Query}}
    end.

-doc """
Folds one buffer of the event queue, Bytes as event/1 takes it, into the records to send
for it, in order, and the next state (docs/design-display.md, "The display device"):

* `SYN_REPORT` sends what the update kept: its relative move, then its position, once
  both axes have a value, then its wheel steps, each only when there is one;
* a key's or button's edge sends what the update kept and then the edge, so a press
  lands where the events before it put the pointer; a device's own repeat is dropped,
  since repeat is the router's;
* a relative move or a wheel step adds to its sum; a wheel event's value is clamped to
  a record's range first, and an event that would take a sum past a record's range sends
  what the update kept, as `SYN_REPORT` does, and starts a new sum at itself, so no sum
  overflows, no movement is clamped away and what is kept is always sent in one order;
* a position on an axis is clamped to the axis's range and normalized across it, 0 at
  its minimum and the record's maximum at its maximum; the position outlives the update,
  so an update that moves one axis keeps the other;
* `SYN_DROPPED` forgets what the update kept and the position, sends `release`, and
  skips every event up to and including the next `SYN_REPORT`, which ends an update
  whose start is lost.

Nothing raises: every event it does not use is counted, as counts/1 reads.
""".
-spec fold(binary(), state()) -> {[erx_input:record()], state()}.
fold(Bytes, State) -> step(event(Bytes), State).

%% The clauses are tried in order, and the order is the rule: a malformed record is
%% counted as such in either phase; while skipping, every other record is skipped, the
%% next SYN_REPORT ending the skip; then a dropped record is unused, and a key's repeat is
%% matched before the edges that follow it.
step({error, _}, F) -> {[], count(malformed, F)};
step({ok, {syn, report}}, #fold{phase = skipping} = F) ->
    {[], count(skipped, F#fold{phase = folding})};
step(_, #fold{phase = skipping} = F) -> {[], count(skipped, F)};
step({drop, _}, F) -> {[], count(unused, F)};
step({ok, {syn, report}}, F) -> flush(F);
%% A fold made afresh, but for the device's axes and the counts.
step({ok, {syn, dropped}}, #fold{axes = Axes, counts = Counts}) ->
    {[release], #fold{axes = Axes, counts = Counts, phase = skipping}};
step({ok, {key, _, repeat}}, F) -> {[], count(unused, F)};
step({ok, {key, Code, Edge}}, F) ->
    {Kept, Next} = flush(F),
    {Kept ++ [{key, Edge, Code}], Next};
step({ok, {rel, wheel, V}}, F) ->
    wheel(max(?ERX_INPUT_WHEEL_MIN, min(?ERX_INPUT_WHEEL_MAX, V)), F);
step({ok, {rel, x, DX}}, F) -> move({DX, 0}, F);
step({ok, {rel, y, DY}}, F) -> move({0, DY}, F);
step({ok, {abs, _, _}}, #fold{axes = none} = F) -> {[], count(unused, F)};
step({ok, {abs, x, V}}, #fold{axes = {Range, _}, position = {_, Y}} = F) ->
    {[], F#fold{position = {normalize(V, Range), Y}, moved = true}};
step({ok, {abs, y, V}}, #fold{axes = {_, Range}, position = {X, _}} = F) ->
    {[], F#fold{position = {X, normalize(V, Range)}, moved = true}}.

count(Why, #fold{counts = Counts} = F) ->
    #{Why := N} = Counts,
    F#fold{counts = Counts#{Why := N + 1}}.

%% The update's relative sum moved by {DX, DY}; when that lies past a record's range,
%% what the update kept is sent and a new sum starts at the move alone.
move({DX, DY} = Move, #fold{rel = {SX, SY}} = F) ->
    case is_rel(SX + DX) andalso is_rel(SY + DY) of
        true -> {[], F#fold{rel = {SX + DX, SY + DY}}};
        false ->
            {Kept, Next} = flush(F),
            {Kept, Next#fold{rel = Move}}
    end.

%% The same for the wheel, with Steps already within a record's range.
wheel(Steps, #fold{wheel = Sum} = F) ->
    case is_wheel(Sum + Steps) of
        true -> {[], F#fold{wheel = Sum + Steps}};
        false ->
            {Kept, Next} = flush(F),
            {Kept, Next#fold{wheel = Steps}}
    end.

is_rel(V) -> V >= ?ERX_INPUT_REL_MIN andalso V =< ?ERX_INPUT_REL_MAX.
is_wheel(V) -> V >= ?ERX_INPUT_WHEEL_MIN andalso V =< ?ERX_INPUT_WHEEL_MAX.

%% A value on an axis of range Min..Max, Min below Max as new/1 holds every range, clamped
%% to the range and scaled to 0..?ERX_INPUT_AXIS_MAX.
normalize(V, {Min, Max}) ->
    (max(Min, min(Max, V)) - Min) * ?ERX_INPUT_AXIS_MAX div (Max - Min).

%% What the update kept, to send in its one order, and the update emptied; the position
%% stays.
flush(#fold{} = F) ->
    Kept = kept_move(F) ++ kept_position(F) ++ kept_wheel(F),
    {Kept, F#fold{rel = {0, 0}, wheel = 0, moved = false}}.

kept_move(#fold{rel = {0, 0}}) -> [];
kept_move(#fold{rel = {DX, DY}}) -> [{pointer, rel, DX, DY}].

kept_position(#fold{moved = true, position = {X, Y}}) when X =/= none, Y =/= none ->
    [{pointer, abs, X, Y}];
kept_position(#fold{}) -> [].

kept_wheel(#fold{wheel = 0}) -> [];
kept_wheel(#fold{wheel = Steps}) -> [{wheel, Steps}].

-doc "The events the fold has not used since new/1, by why (`counts()`).".
-spec counts(state()) -> counts().
counts(#fold{counts = Counts}) -> Counts.
