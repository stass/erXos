%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/if_ether.c
%% Copyright (c) 1982, 1986, 1988, 1993
%% The Regents of the University of California.  All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%% 3. Neither the name of the University nor the names of its contributors
%%    may be used to endorse or promote products derived from this software
%%    without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%% ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.

-module(erx_arp).
-moduledoc """
The ARP neighbour table of one interface (docs/design-network-stack.md, "IPv4 and ARP"),
translated from `arpresolve_full`, `in_arpinput`, `arp_check_update_lle`,
`arp_mark_lle_reachable`, `arptimer`, `arprequest_internal` and `arp_announce_ifaddr` of
FreeBSD's `sys/netinet/if_ether.c` at commit 975e3605 (erlang/apps/erx_net/NOTICE-freebsd).
The table is a pure value in the interface process's state; every function returns the next
table and the actions the process performs, in order.

An entry is `incomplete` while its address is asked for, `reachable` once an ARP packet gave
it, and `verify` for its last seconds, FreeBSD's `ARP_LLINFO_*` states. A resolved entry is
kept 20 minutes (`arpt_keep`). Five seconds before that, the entry turns `verify` and is
published as stale: the first transmitter to use it sends the interface one hint
(`hint/2`, FreeBSD's datapath feedback), and while it has been used, a request goes out each
second, up to five (`la_preempt`), so an answer renews it before it lapses. An unused entry
is deleted when its 20 minutes are up.

An incomplete entry holds the last 16 frames sent to it (`arp_maxhold`) and asks for its
address at most once a second, each time a frame arrives, as `arpresolve_full` renews; it is
deleted with its frames 20 seconds after its last request (`arpt_down`). FreeBSD keeps
asking past five requests (`arp_maxtries`), answering its caller `EHOSTDOWN` instead of
`EWOULDBLOCK`; the frames here come from the interface's own queue and nobody waits on an
answer, so the count only tells whether a request has gone out.

Which packets change the table is `in_arpinput`'s rule: any ARP packet updates the entry of
its sender if one exists, and creates one only when it is addressed to one of the interface's
addresses and its sender is on a prefix of the interface. A sender that claims one of the
interface's own addresses produces a `conflict` action and an answer that reclaims it.

Departures. The table has a bound (`max_entries`, 1024 unless `new/1` is given another),
which FreeBSD's has not: past it, the oldest incomplete entry is deleted to make room, else
the oldest resolved entry no transmitter has hinted, and when there is none, no entry is
created. A packet from one of the interface's own addresses changes no entry, as FreeBSD's
static entry for each interface address refuses it (`arp_add_ifa_lle`). FreeBSD's route check for a new entry
(`in_lltable_rtcheck`) is the prefix check here; routes are not this module's. Static and
published (proxy) entries, `arp_proxyall`, bridges and CARP are not kept: the stack has no
command that makes them.

Time is milliseconds of the monotonic clock. Addresses are binaries: four bytes for IPv4,
six for Ethernet.
""".

-include("erx_arp_wire.hrl").

-export([new/0, new/1, resolve/5, input/4, hint/2, announce/2, expired/3, next_deadline/1,
         count/1]).
%% erx_lltable's callbacks. Not declared with -behaviour, which needs erx_lltable compiled
%% first, and erlc compiles erx_net's modules in name order.
-export([deadline/1, published/1, reclaimable/1]).

-export_type([table/0, iface/0, action/0]).

%% if_ether.c's defaults, in milliseconds.
-define(ARPT_KEEP, 1200000).       % arpt_keep, 20 minutes
-define(ARPT_DOWN, 20000).         % arpt_down, 20 seconds
-define(ARPT_REXMIT, 1000).        % arpt_rexmit, 1 second
-define(ARP_MAXTRIES, 5).          % arp_maxtries
-define(ARP_MAXHOLD, 16).          % arp_maxhold
-define(MAX_ENTRIES, 1024).

-define(BROADCAST, <<16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF>>).

-doc """
What the interface tells the table about itself: its Ethernet address and its IPv4 addresses
with their prefix lengths, in the order they were added.
""".
-type iface() :: #{lladdr := <<_:48>>, addrs := [{<<_:32>>, 0..32}]}.

-doc """
What the interface process does for the table, in order: send an ARP packet to an Ethernet
address; send frames that waited for a neighbour to its address; publish a neighbour's
address for the transmit path, `fresh` or `stale` (transmitters hint a stale one, once);
withdraw a neighbour; note that a host claims one of the interface's addresses.
""".
-type action() :: {send_arp, Dst :: <<_:48>>, #arp{}}
                | {send, Dst :: <<_:48>>, Frames :: [term()]}
                | {publish, Ip :: <<_:32>>, Mac :: <<_:48>>, fresh | stale}
                | {unpublish, Ip :: <<_:32>>}
                | {conflict, Ip :: <<_:32>>, Mac :: <<_:48>>}.

%% One neighbour. `deadline' is when expired/3 next looks at it (FreeBSD's callout); `expire'
%% when a resolved entry lapses or, while incomplete, when its last request went out
%% (la_expire); `asked' counts requests (la_asked), `preempt' the refreshes left
%% (la_preempt), `used' whether a transmitter hinted it while in verify (the hit time);
%% `held' the waiting frames, oldest first.
-record(entry, {state :: incomplete | reachable | verify,
                mac = none :: none | <<_:48>>,
                deadline :: integer(),
                expire :: integer(),
                asked = 0 :: non_neg_integer(),
                preempt = 0 :: non_neg_integer(),
                used = false :: boolean(),
                held = [] :: [term()]}).

%% The entries live in an erx_lltable keyed by IPv4 address, which this module describes
%% with deadline/1, published/1 and reclaimable/1.
-opaque table() :: erx_lltable:table().

-doc "An empty table of at most 1024 entries.".
-spec new() -> table().
new() ->
    new(#{}).

-doc "An empty table; `max_entries` bounds it.".
-spec new(#{max_entries => pos_integer()}) -> table().
new(Opts) ->
    erx_lltable:new(?MODULE, maps:get(max_entries, Opts, ?MAX_ENTRIES)).

-doc "The number of entries.".
-spec count(table()) -> non_neg_integer().
count(T) ->
    erx_lltable:count(T).

-doc """
A frame for the on-link neighbour `Ip` that the transmit path could not address
(`arpresolve_full`): sent at once if the entry is resolved; otherwise held, the oldest held
frame dropped past 16, and a request sent unless one went out in the last second. A frame for
a neighbour the full table has no room for is dropped.
""".
-spec resolve(<<_:32>>, term(), integer(), iface(), table()) -> {table(), [action()]}.
resolve(Ip, Frame, Now, Iface, T0) ->
    case lookup_or_create(Ip, Now, T0) of
        none -> {T0, []};
        {E, T, Evicted} -> prepend(Evicted, resolve_entry(Ip, E, Frame, Now, Iface, T))
    end.

resolve_entry(_Ip, #entry{state = reachable, mac = Mac}, Frame, _Now, _Iface, T) ->
    {T, [{send, Mac, [Frame]}]};
resolve_entry(Ip, #entry{state = verify, mac = Mac} = E, Frame, _Now, _Iface, T) ->
    then(erx_lltable:put(Ip, E#entry{used = true}, T), [{send, Mac, [Frame]}]);
resolve_entry(Ip, #entry{state = incomplete} = E, Frame, Now, Iface, T) ->
    Held = erx_lltable:hold(E#entry.held, Frame, ?ARP_MAXHOLD),
    case E#entry.asked =:= 0 orelse Now >= E#entry.expire + ?ARPT_REXMIT of
        true ->
            E1 = E#entry{held = Held, expire = Now, deadline = Now + ?ARPT_DOWN,
                         asked = E#entry.asked + 1},
            then(erx_lltable:put(Ip, E1, T), request(Ip, Iface));
        false ->
            erx_lltable:put(Ip, E#entry{held = Held}, T)
    end.

%% A table change's result with further actions after its own.
then({T, Actions}, More) ->
    {T, Actions ++ More}.

%% A step's result with the actions of an eviction ahead of its own.
prepend(Evicted, {T, Actions}) ->
    {T, Evicted ++ Actions}.

-doc """
A transmitter used the stale entry of `Ip` (FreeBSD's `llentry_provide_feedback`): while the
entry is in `verify`, the next second's look sends a refresh. Any other entry is unchanged.
""".
-spec hint(<<_:32>>, table()) -> table().
hint(Ip, T) ->
    case erx_lltable:find(Ip, T) of
        #entry{state = verify} = E ->
            %% Hinting changes neither state nor address, so nothing is published.
{T1, []} = erx_lltable:put(Ip, E#entry{used = true}, T),
            T1;
        _ ->
            T
    end.

-doc """
A received ARP packet (`in_arpinput`): updates or creates the sender's entry by FreeBSD's
rules, and answers a request for one of the interface's addresses. An interface with no IPv4
address ignores every packet.
""".
-spec input(#arp{}, integer(), iface(), table()) -> {table(), [action()]}.
input(#arp{sha = <<_:7, 1:1, _:40>>}, _Now, _Iface, T) ->
    {T, []};
input(#arp{} = Arp, Now, #{lladdr := Lladdr, addrs := Addrs} = Iface, T) ->
    case my_address(Arp, Addrs) of
        none ->
            {T, []};
        _MyAddr when Arp#arp.sha =:= Lladdr ->
            {T, []};
        MyAddr when Arp#arp.spa =:= MyAddr, MyAddr =/= <<0:32>> ->
            Answer = answer(Arp#arp{tpa = MyAddr}, MyAddr, Lladdr),
            {T, [{conflict, MyAddr, Arp#arp.sha} | Answer]};
        MyAddr ->
            {T1, Actions} = learn(Arp, MyAddr, Now, Iface, T),
            {T1, Actions ++ answer(Arp, MyAddr, Lladdr)}
    end.

-doc """
A gratuitous request announcing `Ip`, one of the interface's addresses
(`arp_announce_ifaddr`); nothing for the unspecified address.
""".
-spec announce(<<_:32>>, iface()) -> [action()].
announce(<<0:32>>, _Iface) ->
    [];
announce(Ip, #{lladdr := Lladdr}) ->
    [{send_arp, ?BROADCAST, #arp{hrd = ?ARPHRD_ETHER, op = ?ARPOP_REQUEST, sha = Lladdr,
                                 spa = Ip, tha = <<0:48>>, tpa = Ip}}].

-doc "Runs every entry's deadline at or before `Now` (`arptimer`).".
-spec expired(integer(), iface(), table()) -> {table(), [action()]}.
expired(Now, Iface, T) ->
    erx_lltable:expire(Now, fun(Ip, E, Tn) -> timer(Ip, E, Now, Iface, Tn) end, T).

-doc "The earliest deadline of any entry, or `infinity`.".
-spec next_deadline(table()) -> integer() | infinity.
next_deadline(T) ->
    erx_lltable:next_deadline(T).

%% arptimer for one entry whose deadline has come.
timer(Ip, #entry{state = reachable} = E, Now, _Iface, T) ->
    erx_lltable:put(Ip, E#entry{state = verify, used = false, deadline = Now + ?ARPT_REXMIT}, T);
timer(Ip, #entry{state = verify, used = true, preempt = P} = E, Now, Iface, T) when P > 0 ->
    then(erx_lltable:put(Ip, E#entry{preempt = P - 1, deadline = Now + ?ARPT_REXMIT}, T),
         request(Ip, Iface));
timer(Ip, #entry{state = verify, expire = Expire} = E, Now, _Iface, T) when Expire > Now ->
    erx_lltable:put(Ip, E#entry{deadline = Now + ?ARPT_REXMIT}, T);
timer(Ip, #entry{state = verify}, _Now, _Iface, T) ->
    erx_lltable:remove(Ip, T);
timer(Ip, #entry{state = incomplete}, _Now, _Iface, T) ->
    erx_lltable:remove(Ip, T).

-doc false.
-spec deadline(#entry{}) -> integer().
deadline(#entry{deadline = Deadline}) -> Deadline.

%% What the transmit path sees: nothing while incomplete, the address once resolved, stale
%% in the last seconds before it lapses.
-doc false.
-spec published(#entry{}) -> erx_lltable:published().
published(#entry{state = incomplete}) -> none;
published(#entry{state = reachable, mac = Mac}) -> {Mac, fresh};
published(#entry{state = verify, mac = Mac}) -> {Mac, stale}.

%% A resolved entry no transmitter has hinted may be evicted. Only an entry in verify is
%% ever hinted, so every reachable entry may be.
-doc false.
-spec reclaimable(#entry{}) -> boolean().
reclaimable(#entry{used = Used}) -> not Used.

%% in_arpinput's address match: the target if it is ours, else the sender if it is ours (a
%% conflict), else the interface's first address; none without an IPv4 address.
my_address(#arp{spa = Spa, tpa = Tpa}, Addrs) ->
    Mine = [A || {A, _Len} <- Addrs],
    case {lists:member(Tpa, Mine), lists:member(Spa, Mine), Mine} of
        {true, _, _} -> Tpa;
        {false, true, _} -> Spa;
        {false, false, [First | _]} -> First;
        {false, false, []} -> none
    end.

%% The table part of in_arpinput: an existing entry of the sender is updated from any
%% packet (arp_check_update_lle); a new one is made only for a packet to our address from a
%% sender on one of our prefixes, and only if the table has room.
learn(#arp{spa = Spa, sha = Sha, tpa = Tpa}, MyAddr, Now, #{addrs := Addrs} = Iface,
      T) ->
    Own = lists:keymember(Spa, 1, Addrs),
    case erx_lltable:find(Spa, T) of
        _ when Own ->
            {T, []};
        none when Tpa =:= MyAddr ->
            case on_link(Spa, Iface) of
                false -> {T, []};
                true -> learn_new(Spa, Sha, Now, T)
            end;
        none ->
            {T, []};
        E ->
            resolved(Spa, E, Sha, Now, T)
    end.

%% A new entry for a sender, if the table has free room for it: a learnt sender evicts
%% nothing (erx_lltable:lookup_or_learn/3).
learn_new(Spa, Sha, Now, T0) ->
    case erx_lltable:lookup_or_learn(Spa, fresh(Now), T0) of
        none -> {T0, []};
        {E, T, []} -> resolved(Spa, E, Sha, Now, T)
    end.

%% arp_check_update_lle and arp_mark_lle_reachable: the entry takes the sender's address,
%% is kept for arpt_keep, is looked at again maxtries refreshes before that, and sends what
%% it held.
resolved(Ip, E, Mac, Now, T) ->
    E1 = E#entry{state = reachable, mac = Mac, expire = Now + ?ARPT_KEEP,
                 deadline = Now + ?ARPT_KEEP - ?ARP_MAXTRIES * ?ARPT_REXMIT,
                 asked = 0, preempt = ?ARP_MAXTRIES, used = false, held = []},
    Send = case E#entry.held of
               [] -> [];
               Held -> [{send, Mac, Held}]
           end,
    then(erx_lltable:put(Ip, E1, T), Send).

%% The reply half of in_arpinput: only a request for our address is answered, by unicast
%% to the asker unless the address is IPv4 link-local (RFC 3927), which is answered by
%% broadcast. The reply keeps the request's hardware type.
answer(#arp{op = ?ARPOP_REQUEST, tpa = MyAddr} = Arp, MyAddr, Lladdr) ->
    Dst = case MyAddr of
              <<169, 254, _:16>> -> ?BROADCAST;
              _ -> Arp#arp.sha
          end,
    [{send_arp, Dst, Arp#arp{op = ?ARPOP_REPLY, sha = Lladdr, spa = MyAddr,
                             tha = Arp#arp.sha, tpa = Arp#arp.spa}}];
answer(#arp{}, _MyAddr, _Lladdr) ->
    [].

%% arprequest_internal's broadcast request for Ip, from the first of our addresses on Ip's
%% prefix, else from the last of them as FreeBSD's loop leaves it; nothing from an interface
%% without an address (EADDRNOTAVAIL).
request(_Ip, #{addrs := []}) ->
    [];
request(Ip, #{lladdr := Lladdr, addrs := Addrs}) ->
    Spa = case [A || {A, Len} <- Addrs, same_prefix(A, Ip, Len)] of
              [A | _] -> A;
              [] -> element(1, lists:last(Addrs))
          end,
    [{send_arp, ?BROADCAST, #arp{hrd = ?ARPHRD_ETHER, op = ?ARPOP_REQUEST, sha = Lladdr,
                                 spa = Spa, tha = <<0:48>>, tpa = Ip}}].

%% The route check of a new entry: the sender is not 0.0.0.0 and lies on one of our prefixes.
on_link(<<0:32>>, _Iface) ->
    false;
on_link(Ip, #{addrs := Addrs}) ->
    lists:any(fun({A, Len}) -> same_prefix(A, Ip, Len) end, Addrs).

same_prefix(A, B, Len) ->
    <<P:Len/bits, _/bits>> = A,
    <<Q:Len/bits, _/bits>> = B,
    P =:= Q.

%% The entry of Ip, or a new incomplete one if there is room or room can be made.
lookup_or_create(Ip, Now, T) ->
    erx_lltable:lookup_or_create(Ip, fresh(Now), T).

fresh(Now) -> #entry{state = incomplete, deadline = Now + ?ARPT_DOWN, expire = Now}.
