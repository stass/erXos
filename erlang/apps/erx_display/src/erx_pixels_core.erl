%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pixels_core).
-moduledoc """
The pure state of `erx_pixels` over one pixel area (docs/design-display.md,
"The pixel area", The allocator's core): which whole pages of the area are
free and which ranges are live, each with its owner and its lease.

The free list is a list of disjoint runs `{Start, Pages}`, in pages, in order
of `Start`, no two of them adjacent. A live range is in one of three states:

* owned: its owner lives and no lease of it is outstanding;
* lent: its owner lives and a lease of it is outstanding;
* orphaned: its owner has exited and a lease of it is outstanding.

A range leaves the live ranges only when its owner has exited and no lease of
it is outstanding, and then by zero, then join: the step answers a `zero`
effect and holds the run aside, and the run joins the free list, merged with
its neighbours, only at `zeroed/3`, once the process has stored zero over it.
So every page on the free list is zero, and `alloc/3` writes nothing.

Each event answers the next state and the effects to perform, in order:

* `{zero, Offset, Pages}`: store zero over the range with the area's `zero/3`,
  then call `zeroed/3`;
* `{lend, Offset, Pages, Owner}`: make a lease of the range for `Owner` with
  the area's `lend/5`, then call `lent/3` with its answer;
* `{reply, From, Reply}`: answer a `lend` call.

The process performs each effect, and the effects the follow-up call answers,
before it takes its next message. Offsets are in bytes at this module's
interface, multiples of the page size of abi/erx_abi.txt.
""".

-include("generated/erx_abi.hrl").

-export([new/1, alloc/3, lend/4, lent/3, returned/2, owner_down/2, zeroed/3]).
-export([holder/2, idle/1, ranges/1, free/1]).
-export_type([core/0, effect/0]).

-type lease() :: pos_integer().
-type from() :: term().

%% A live range. waiting is the owner's one lend that waits for the outstanding
%% lease's return, or that waits for lent/3 while its lease is being made.
-record(range, {pages :: pos_integer(),
                owner :: pid(),
                live = true :: boolean(),
                lease = none :: none | lease(),
                waiting = none :: none | from()}).

%% pages: the area's size. free: the free runs, by start. ranges: the live
%% ranges, by start page. zeroing: runs given a zero effect and not yet zeroed.
-record(core, {pages :: non_neg_integer(),
               free :: [{non_neg_integer(), pos_integer()}],
               ranges = #{} :: #{non_neg_integer() => #range{}},
               zeroing = #{} :: #{non_neg_integer() => pos_integer()}}).

-opaque core() :: #core{}.
-type effect() :: {zero, non_neg_integer(), pos_integer()}
                | {lend, non_neg_integer(), pos_integer(), pid()}
                | {reply, from(), {ok, lease(), pos_integer()} | {error, term()}}.

-define(PAGE, ?ERX_PAGE_SIZE).

-doc "An area of Bytes, wholly free and wholly zero, as a new area is.".
-spec new(non_neg_integer()) -> core().
new(Bytes) when is_integer(Bytes), Bytes >= 0 ->
    Pages = Bytes div ?PAGE,
    #core{pages = Pages, free = [{0, Pages} || Pages > 0]}.

-doc """
A range of Bytes, rounded up to whole pages, for Owner: `{ok, Offset, Core}`
from the start of the first free run long enough, the run keeping what is
left, or `{error, enomem}` when none is, however many pages are free in all.
""".
-spec alloc(core(), pid(), pos_integer()) -> {ok, non_neg_integer(), core()} | {error, enomem}.
alloc(#core{free = Free, ranges = Ranges} = Core, Owner, Bytes) when is_integer(Bytes), Bytes >= 1 ->
    Pages = (Bytes + ?PAGE - 1) div ?PAGE,
    case first_fit(Pages, Free) of
        {ok, Start, Rest} ->
            Range = #range{pages = Pages, owner = Owner},
            {ok, Start * ?PAGE, Core#core{free = Rest, ranges = Ranges#{Start => Range}}};
        none ->
            {error, enomem}
    end.

-doc """
Owner's lend of the range at Offset, a call answered through From. A range
Owner does not own at exactly that offset is refused with `einval`. With no
lease outstanding the lease is made now; with one outstanding the call waits
for its return. A range has at most one waiting lend: a later one takes the
place of the earlier, which is refused, since the owner, blocked in its call,
can have made a second only after giving up the first, as with
`gen_server:send_request/2`.
""".
-spec lend(core(), pid(), non_neg_integer(), from()) -> {core(), [effect()]}.
lend(#core{ranges = Ranges} = Core, Owner, Offset, From) ->
    case owned_range(Ranges, Owner, Offset) of
        {ok, Start, #range{lease = none, waiting = none, pages = Pages} = Range} ->
            {store(Core, Start, Range#range{waiting = From}), [{lend, Offset, Pages, Owner}]};
        {ok, Start, #range{waiting = Earlier} = Range} ->
            Refused = [{reply, Earlier, {error, einval}} || Earlier =/= none],
            {store(Core, Start, Range#range{waiting = From}), Refused};
        error ->
            {Core, [{reply, From, {error, einval}}]}
    end.

-doc """
The answer of the `lend` effect for the range at Offset: the lease is now
outstanding and the waiting call is answered `{ok, Lease, Pages}`, or no
lease was made and the call is answered with the error.
""".
-spec lent(core(), non_neg_integer(), {ok, lease()} | {error, term()}) -> {core(), [effect()]}.
lent(#core{ranges = Ranges} = Core, Offset, Answer) ->
    Start = Offset div ?PAGE,
    #range{waiting = From, pages = Pages} = Range = maps:get(Start, Ranges),
    case Answer of
        {ok, Lease} ->
            {store(Core, Start, Range#range{lease = Lease, waiting = none}),
             [{reply, From, {ok, Lease, Pages}}]};
        {error, _} = Error ->
            {store(Core, Start, Range#range{waiting = none}), [{reply, From, Error}]}
    end.

-doc """
A lease's return. A lent range is owned again, unless its owner's lend waits,
which then makes the next lease; an orphaned range is released. A lease this
area does not know changes nothing.
""".
-spec returned(core(), lease()) -> {core(), [effect()]}.
returned(#core{ranges = Ranges} = Core, Lease) ->
    case [{Start, Range} || Start := #range{lease = L} = Range <- Ranges, L =:= Lease] of
        [{Start, #range{live = false, pages = Pages}}] ->
            release(Start, Pages, Core#core{ranges = maps:remove(Start, Ranges)});
        [{Start, #range{waiting = none} = Range}] ->
            {store(Core, Start, Range#range{lease = none}), []};
        [{Start, #range{owner = Owner, pages = Pages} = Range}] ->
            {store(Core, Start, Range#range{lease = none}), [{lend, Start * ?PAGE, Pages, Owner}]};
        [] ->
            {Core, []}
    end.

-doc """
Owner's exit. Each owned range of Owner is released; each lent one is
orphaned, and the lend that waits on it, Owner's own, is dropped unanswered.
""".
-spec owner_down(core(), pid()) -> {core(), [effect()]}.
owner_down(#core{ranges = Ranges} = Core, Owner) ->
    Mine = lists:sort([{Start, Range} || Start := #range{owner = O} = Range <- Ranges, O =:= Owner]),
    lists:foldl(fun owner_gone/2, {Core, []}, Mine).

owner_gone({Start, #range{lease = none, pages = Pages}}, {#core{ranges = Ranges} = Core, Effects}) ->
    {Next, Zero} = release(Start, Pages, Core#core{ranges = maps:remove(Start, Ranges)}),
    {Next, Effects ++ Zero};
owner_gone({Start, Range}, {Core, Effects}) ->
    {store(Core, Start, Range#range{live = false, waiting = none}), Effects}.

%% Zero, then join: a released run is held aside until zeroed/3.
release(Start, Pages, #core{zeroing = Zeroing} = Core) ->
    {Core#core{zeroing = Zeroing#{Start => Pages}}, [{zero, Start * ?PAGE, Pages}]}.

-doc """
The `zero` effect for the run at Offset has been performed: the run joins the
free list, merged with the run that ends where it starts and the run that
starts where it ends.
""".
-spec zeroed(core(), non_neg_integer(), pos_integer()) -> core().
zeroed(#core{zeroing = Zeroing, free = Free} = Core, Offset, Pages) ->
    Start = Offset div ?PAGE,
    %% Asserts the run is the one the zero effect named.
    Pages = maps:get(Start, Zeroing),
    Core#core{zeroing = maps:remove(Start, Zeroing), free = join({Start, Pages}, Free)}.

-doc "The owner of the range that Lease, outstanding, is a lease of, or `error`.".
-spec holder(core(), lease()) -> {ok, pid()} | error.
holder(#core{ranges = Ranges}, Lease) ->
    case [Owner || _ := #range{lease = L, owner = Owner} <- Ranges, L =:= Lease] of
        [Owner] -> {ok, Owner};
        [] -> error
    end.

-doc "True once no range is live and no run waits for its zero: the area may be let go.".
-spec idle(core()) -> boolean().
idle(#core{ranges = Ranges, zeroing = Zeroing}) ->
    map_size(Ranges) =:= 0 andalso map_size(Zeroing) =:= 0.

-doc "The live ranges, `{Offset, Pages, Owner, State}`, by offset.".
-spec ranges(core()) -> [{non_neg_integer(), pos_integer(), pid(), owned | lent | orphaned}].
ranges(#core{ranges = Ranges}) ->
    lists:sort([{Start * ?PAGE, Pages, Owner, state(Range)}
                || Start := #range{pages = Pages, owner = Owner} = Range <- Ranges]).

-doc "The free runs, `{Offset, Pages}`, by offset.".
-spec free(core()) -> [{non_neg_integer(), pos_integer()}].
free(#core{free = Free}) ->
    [{Start * ?PAGE, Pages} || {Start, Pages} <- Free].

state(#range{live = false}) -> orphaned;
state(#range{lease = none}) -> owned;
state(#range{}) -> lent.

store(#core{ranges = Ranges} = Core, Start, Range) ->
    Core#core{ranges = Ranges#{Start => Range}}.

%% The range Owner owns that starts exactly at Offset.
owned_range(Ranges, Owner, Offset) when Offset rem ?PAGE =:= 0 ->
    case maps:find(Offset div ?PAGE, Ranges) of
        {ok, #range{owner = Owner, live = true} = Range} -> {ok, Offset div ?PAGE, Range};
        _ -> error
    end;
owned_range(_Ranges, _Owner, _Offset) ->
    error.

first_fit(Pages, [{Start, Run} | Rest]) when Run > Pages ->
    {ok, Start, [{Start + Pages, Run - Pages} | Rest]};
%% A run of exactly Pages, Pages already bound: taken whole.
first_fit(Pages, [{Start, Pages} | Rest]) ->
    {ok, Start, Rest};
first_fit(Pages, [Run | Rest]) ->
    case first_fit(Pages, Rest) of
        {ok, Start, Left} -> {ok, Start, [Run | Left]};
        none -> none
    end;
first_fit(_Pages, []) ->
    none.

%% Inserts a run into the free list, merged with its neighbours.
join({Start, Pages}, [{Next, More} | Rest]) when Start + Pages =:= Next ->
    join({Start, Pages + More}, Rest);
join({Start, Pages}, [{Prev, Before} | Rest]) when Prev + Before =:= Start ->
    join({Prev, Before + Pages}, Rest);
join({Start, _} = Run, [{Next, _} = Free | Rest]) when Next < Start ->
    [Free | join(Run, Rest)];
join(Run, Free) ->
    [Run | Free].
