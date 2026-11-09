%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% FreeBSD: sys/net/if_llatbl.c
%% Copyright (c) 2004 Luigi Rizzo, Alessandro Cerri. All rights reserved.
%% Copyright (c) 2004-2008 Qing Li. All rights reserved.
%% Copyright (c) 2008 Kip Macy. All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%% ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.

-module(erx_lltable).
-moduledoc """
The keyed neighbour table that `erx_arp` and `erx_nd6` keep their entries in
(docs/design-network-stack.md, "IPv4 and ARP"): a bounded map from a neighbour's address to
the module's own entry, ordered by each entry's deadline, with the transmit path's view of
every entry derived from the entry alone. FreeBSD's `lltable` is shared by ARP and neighbour
discovery the same way; the frame queue's rule is `lltable_append_entry_queue` of
`sys/net/if_llatbl.c` at commit 975e3605 (erlang/apps/erx_net/NOTICE-freebsd).

The owning module is a callback module that says three things of its entries: when the
table next hands an entry back to it (`deadline/1`); what the transmit path sees of it,
nothing while it is being resolved or a link-layer address `fresh` or `stale`
(`published/1`); and whether a published entry may be evicted to make room
(`reclaimable/1`), which is each protocol's own rule.

Every change goes through `lookup_or_create/3`, `lookup_or_learn/3`, `put/3` and `remove/2`, which keep the
deadline index in step and return the `publish` or `unpublish` action the change of the
published view needs, so a module cannot forget to publish: publication follows from the
entry. Past `max` entries, `lookup_or_create/3`, for a neighbour this host resolves, makes
room by deleting the oldest unpublished entry, else the oldest reclaimable one, and refuses
when there is neither; `lookup_or_learn/3`, for a sender learnt from an unsolicited ARP
request or neighbour solicitation, takes only free room and evicts nothing, so a sender
cycling through spoofed on-link addresses cannot push out the entries this host is
resolving or using. FreeBSD's `lltable` has a limit (`llt_maxentries`) that refuses every
new entry once reached, which learning follows, but neither ARP nor neighbour discovery
sets it, so their tables are unbounded (requirement N4).
""".

-export([new/2, count/1, find/2, is_key/2, lookup_or_create/3, lookup_or_learn/3, put/3,
         remove/2,
         expire/3, next_deadline/1, hold/3]).

-export_type([table/0, published/0, action/0]).

-doc "What the transmit path sees of an entry.".
-type published() :: none | {LinkAddr :: binary(), fresh | stale}.

-doc "A change of the transmit path's view of the neighbour `Key`.".
-type action() :: {publish, Key :: binary(), LinkAddr :: binary(), fresh | stale}
                | {unpublish, Key :: binary()}.

-doc "When the table next hands the entry to the owning module's `expire/3` step.".
-callback deadline(Entry :: term()) -> integer().
-doc "The transmit path's view of the entry, `none` until it has a link-layer address.".
-callback published(Entry :: term()) -> published().
-doc "Whether a published entry may be evicted to make room for a new neighbour.".
-callback reclaimable(Entry :: term()) -> boolean().

%% `entries' maps a key to its creation number and entry; `timers' holds {Deadline, Key}
%% for every entry, so that next_deadline/1 and expire/3 do not walk the table; `seq' is the
%% next creation number. Creation numbers order entries by age for eviction.
-record(lltable, {mod :: module(),
                  entries = #{} :: #{binary() => {non_neg_integer(), term()}},
                  timers = gb_sets:empty() :: gb_sets:set({integer(), binary()}),
                  max :: pos_integer(),
                  seq = 0 :: non_neg_integer()}).

-opaque table() :: #lltable{}.

-doc "An empty table of at most `Max` entries whose entries `Mod` describes.".
-spec new(module(), pos_integer()) -> table().
new(Mod, Max) when is_atom(Mod), is_integer(Max), Max > 0 ->
    #lltable{mod = Mod, max = Max};
new(_Mod, _Max) ->
    erlang:error(badarg).

-doc "The number of entries.".
-spec count(table()) -> non_neg_integer().
count(#lltable{entries = Entries}) ->
    map_size(Entries).

-doc "The entry of `Key`, or `none`.".
-spec find(binary(), table()) -> term() | none.
find(Key, #lltable{entries = Entries}) ->
    case Entries of
        #{Key := {_Created, Entry}} -> Entry;
        #{} -> none
    end.

-doc "Whether `Key` has an entry.".
-spec is_key(binary(), table()) -> boolean().
is_key(Key, #lltable{entries = Entries}) ->
    is_map_key(Key, Entries).

-doc """
The entry of `Key`, or else `Fresh`, stored once there is room for it, with the actions of
the eviction that made the room; `none` when the table is full of entries that may not be
evicted. `Fresh` is unpublished: a new neighbour is still to be resolved.
""".
-spec lookup_or_create(binary(), term(), table()) -> {term(), table(), [action()]} | none.
lookup_or_create(Key, Fresh, #lltable{entries = Entries} = T) ->
    case Entries of
        #{Key := {_Created, Entry}} ->
            {Entry, T, []};
        #{} ->
            case room(T) of
                full ->
                    none;
                {T1, Evicted} ->
                    {T2, []} = put(Key, Fresh, T1),
                    {Fresh, T2, Evicted}
            end
    end.

-doc """
The entry of `Key`, or else `Fresh` if there is free room for it, `none` otherwise: a
learnt sender never evicts an entry (`llt_maxentries`' refusal).
""".
-spec lookup_or_learn(binary(), term(), table()) -> {term(), table(), []} | none.
lookup_or_learn(Key, Fresh, #lltable{entries = Entries, max = Max} = T) ->
    case Entries of
        #{Key := {_Created, Entry}} ->
            {Entry, T, []};
        #{} when map_size(Entries) < Max ->
            {T1, []} = put(Key, Fresh, T),
            {Fresh, T1, []};
        #{} ->
            none
    end.

-doc """
Stores `Entry` as the entry of `Key`, and returns the `publish` or `unpublish` action if
what the transmit path sees of the neighbour changed. A new key takes the next creation
number.
""".
-spec put(binary(), term(), table()) -> {table(), [action()]}.
put(Key, Entry, #lltable{mod = Mod, entries = Entries, timers = Timers, seq = Seq} = T) ->
    Timer = {Mod:deadline(Entry), Key},
    case Entries of
        #{Key := {Created, Old}} ->
            Timers1 = gb_sets:add(Timer, gb_sets:delete({Mod:deadline(Old), Key}, Timers)),
            T1 = T#lltable{entries = Entries#{Key := {Created, Entry}}, timers = Timers1},
            {T1, publication(Key, Mod:published(Old), Mod:published(Entry))};
        #{} ->
            T1 = T#lltable{entries = Entries#{Key => {Seq, Entry}},
                           timers = gb_sets:add(Timer, Timers), seq = Seq + 1},
            {T1, publication(Key, none, Mod:published(Entry))}
    end.

-doc "Deletes the entry of `Key`, which must exist, and withdraws it if it was published.".
-spec remove(binary(), table()) -> {table(), [action()]}.
remove(Key, #lltable{mod = Mod, entries = Entries, timers = Timers} = T) ->
    #{Key := {_Created, Entry}} = Entries,
    T1 = T#lltable{entries = maps:remove(Key, Entries),
                   timers = gb_sets:delete({Mod:deadline(Entry), Key}, Timers)},
    {T1, publication(Key, Mod:published(Entry), none)}.

%% The action that moves the transmit path's view of Key from Before to After.
publication(_Key, Same, Same) -> [];
publication(Key, _Before, none) -> [{unpublish, Key}];
publication(Key, _Before, {LinkAddr, Freshness}) -> [{publish, Key, LinkAddr, Freshness}].

-doc """
Hands every entry whose deadline is at or before `Now` to `Step`, earliest first, and
returns the table and the actions of every step in order. `Step` returns the next table,
and must move the entry's deadline past `Now` or remove it.
""".
-spec expire(integer(), fun((binary(), term(), table()) -> {table(), list()}), table()) ->
          {table(), list()}.
expire(Now, Step, T) ->
    expire(Now, Step, T, []).

expire(Now, Step, T, Acc) ->
    case smallest(T) of
        {Deadline, Key} when Deadline =< Now ->
            {T1, Actions} = Step(Key, find(Key, T), T),
            expire(Now, Step, T1, lists:reverse(Actions, Acc));
        _Later ->
            {T, lists:reverse(Acc)}
    end.

-doc "The earliest deadline of any entry, or `infinity`.".
-spec next_deadline(table()) -> integer() | infinity.
next_deadline(T) ->
    case smallest(T) of
        {Deadline, _Key} -> Deadline;
        none -> infinity
    end.

-doc """
A frame queue with `Item` added (`lltable_append_entry_queue`): the newest joins at the end,
and the oldest go while the queue holds `Max`.
""".
-spec hold([term()], term(), pos_integer()) -> [term()].
hold(Held, Item, Max) when length(Held) >= Max ->
    lists:nthtail(length(Held) - Max + 1, Held) ++ [Item];
hold(Held, Item, _Max) ->
    Held ++ [Item].

smallest(#lltable{timers = Timers}) ->
    case gb_sets:is_empty(Timers) of
        true -> none;
        false -> gb_sets:smallest(Timers)
    end.

%% Room for one more entry: there is some, or the oldest unpublished entry goes, else the
%% oldest reclaimable one, which is withdrawn; full if neither. Candidates sort by their
%% eviction rank, then by age.
room(#lltable{entries = Entries, max = Max} = T) when map_size(Entries) < Max ->
    {T, []};
room(#lltable{mod = Mod, entries = Entries} = T) ->
    Candidates = [{Rank, Created, Key} || Key := {Created, Entry} <- Entries,
                                          {evict, Rank} <- [eviction(Mod, Entry)]],
    case Candidates of
        [] ->
            full;
        [_ | _] ->
            {_Rank, _Created, Victim} = lists:min(Candidates),
            remove(Victim, T)
    end.

%% Whether an entry may make room, and in which rank: unresolved entries first, then
%% reclaimable published ones; other entries are kept.
eviction(Mod, Entry) ->
    case Mod:published(Entry) of
        none ->
            {evict, 1};
        _Published ->
            case Mod:reclaimable(Entry) of
                true -> {evict, 2};
                false -> kept
            end
    end.
