%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet6/nd6.c
%% FreeBSD: sys/netinet6/nd6_nbr.c
%%
%% Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project.
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%% 3. Neither the name of the project nor the names of its contributors
%%    may be used to endorse or promote products derived from this software
%%    without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE PROJECT AND CONTRIBUTORS ``AS IS'' AND
%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%% ARE DISCLAIMED.  IN NO EVENT SHALL THE PROJECT OR CONTRIBUTORS BE LIABLE
%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.
%%

-module(erx_nd6).
-moduledoc """
The IPv6 neighbour cache of one interface (docs/design-network-stack.md, "IPv6, neighbour
discovery and autoconfiguration"), translated from `nd6_resolve_slow`, `nd6_llinfo_timer`,
`nd6_llinfo_setstate`, `nd6_is_stale`, `nd6_cache_lladdr` and `nd6_llinfo_get_holdsrc` of
FreeBSD's `sys/netinet6/nd6.c`, and `nd6_ns_input`, `nd6_na_input` and the address choices
of `nd6_na_output_fib` and `nd6_ns_output_fib` of `sys/netinet6/nd6_nbr.c`, at commit
95719d8a (erlang/apps/erx_net/NOTICE-freebsd). The cache is a pure value in the interface
process's state; every function returns the next cache and the actions the process
performs, in order.

An entry moves through RFC 4861's states as FreeBSD moves it. `incomplete`: solicited by
multicast once a second (`retrans`), three times (`nd6_mmaxtries`), holding the last 16
frames sent to it (`nd6_maxqueuelen`); unanswered, it is deleted and the oldest frame is
returned for an ICMPv6 address-unreachable error. `reachable` for the interface's reachable
time, then `stale`. A stale entry still addresses frames, and is published as such: the
first transmitter to use it hints the interface once (`hint/3`, FreeBSD's datapath feedback),
and five seconds later (`nd6_delay`) the entry turns `probe`, as FreeBSD's timer switches a
stale entry used since; one unused for a day (`nd6_gctimer`) is deleted. A frame that reaches
the interface for a stale entry turns it `delay`, which turns `probe` after five seconds.
`probe` solicits by unicast once a second, three times (`nd6_umaxtries`), then deletes the
entry. Only neighbour solicitations and advertisements with a hop limit of 255 are accepted,
by `nd6_ns_input`'s and `nd6_na_input`'s rules.

The reachable time is drawn from the cache's generator (an `erx_net_rand` value split from
the interface's) when the cache is made and every two hours after
(`nd6_recalc_reachtm_interval`), uniformly between half and one and a half times its base,
30 seconds (`ND_COMPUTE_RTIME`). FreeBSD ANDs a random word with a mask that is not a power
of two, which is not uniform and gives whole seconds: a departure in timing alone
(docs/design-network-stack.md).

Departures. The cache has a bound (`max_entries`, 1024 unless `new/3` is given another), as
`erx_arp`'s table has: past it the oldest incomplete entry is deleted to make room, else the
oldest stale entry no transmitter has hinted (reclaimable by RFC 4861 5.3), and when there
is neither, no entry is made. A solicitation from one of the interface's own addresses
changes no entry, as FreeBSD's static entry for each interface address refuses it. A
message that came in an IPv6 fragment is dropped (RFC 6980, FreeBSD's `M_FRAGMENTED`
check); the caller drops one rebuilt by reassembly. A solicitation's held-frame source is
used only when it is a preferred or anycast address of the interface, never a tentative
one, which RFC 4862 forbids and FreeBSD's `nd6_ns_output_fib` allows. The base reachable
time (30 seconds) and the retransmission interval (one second) are fixed here;
`erx_nd6_rtr` sets them from router advertisements. A solicitation without a source link-layer
address makes no entry, where FreeBSD makes one with neither an address nor a timer that
lasts until the interface goes. A neighbour advertisement whose router flag clears a
neighbour's produces `not_router` for `erx_nd6_rtr`, which owns the default-router list
(`defrouter_remove`). Proxy and static entries and CARP are not kept: the stack has no
command that makes them. Duplicate address detection is `erx_nd6_dad`'s: a solicitation
or advertisement for a tentative address of the interface is handed on as a `dad` action.

Time is milliseconds of the monotonic clock. Addresses are binaries: sixteen bytes for
IPv6, six for Ethernet.
""".

-include("erx_ip6.hrl").

-export([new/3, resolve/6, input/5, hint/3, expired/3, next_deadline/1, count/1,
         reachable_time/1]).
%% erx_lltable's callbacks. Not declared with -behaviour, which needs erx_lltable compiled
%% first, and erlc compiles erx_net's modules in name order.
-export([deadline/1, published/1, reclaimable/1]).

-export_type([cache/0, iface/0, action/0]).

%% nd6.c's and nd6.h's defaults, in milliseconds.
-define(REACHABLE_TIME, 30000).           % REACHABLE_TIME, the base
-define(RETRANS_TIMER, 1000).             % RETRANS_TIMER
-define(ND6_DELAY, 5000).                 % nd6_delay
-define(ND6_GCTIMER, 86400000).           % nd6_gctimer, a day
-define(ND6_RECALC, 7200000).             % nd6_recalc_reachtm_interval, two hours
-define(ND6_MMAXTRIES, 3).                % nd6_mmaxtries
-define(ND6_UMAXTRIES, 3).                % nd6_umaxtries
-define(ND6_MAXQUEUELEN, 16).             % nd6_maxqueuelen
-define(MAX_ENTRIES, 1024).

-define(ND_NA_FLAG_ROUTER, 4).
-define(ND_NA_FLAG_SOLICITED, 2).
-define(ND_NA_FLAG_OVERRIDE, 1).
-define(UNSPECIFIED, <<0:128>>).
-define(ALL_NODES, <<16#FF02:16, 0:96, 1:16>>).
-define(IS_MULTICAST(A), (binary_part(A, 0, 1) =:= <<16#FF>>)).


-doc """
What the interface tells the cache about itself: its Ethernet address, its IPv6 addresses
with their states, and the prefixes it holds on-link. A link-local address is always on-link.
""".
-type iface() :: #{lladdr := <<_:48>>,
                   addrs := [{<<_:128>>, preferred | tentative | duplicated | anycast}],
                   onlink := [{<<_:128>>, 0..128}]}.

-doc """
What the interface process does for the cache, in order. `send_nd` sends a neighbour
discovery message with a hop limit of 255 from `Src`, or from the source the interface
selects for `Dst`, and is addressed at the link layer like any packet to `Dst`. `send`
sends frames that waited for a neighbour. `unreachable` returns a frame whose neighbour never
answered, for an ICMPv6 address-unreachable error. `publish` and `unpublish` keep the
transmit path's view of a neighbour, `fresh` or `stale` (transmitters hint a stale one,
once). `not_router` tells `erx_nd6_rtr` a neighbour stopped advertising itself as a router.
`conflict` notes an advertisement for one of the interface's addresses; `dad` hands a
message about a tentative address to duplicate address detection.
""".
-type action() :: {send_nd, Src :: select | <<_:128>>, Dst :: <<_:128>>, #icmp6{}}
                | {send, Dst :: <<_:48>>, Frames :: [term()]}
                | {unreachable, Frame :: term()}
                | {publish, Ip :: <<_:128>>, Mac :: <<_:48>>, fresh | stale}
                | {unpublish, Ip :: <<_:128>>}
                | {not_router, Ip :: <<_:128>>}
                | {conflict, Ip :: <<_:128>>, Mac :: none | <<_:48>>}
                | {dad, {ns, Target :: <<_:128>>, Nonce :: none | binary()}
                      | {na, Target :: <<_:128>>}}.

%% One neighbour: its state and link-layer address; `deadline' when expired/3 next looks at
%% it (FreeBSD's callout); `asked' the solicitations sent in this state (la_asked); `used'
%% whether a transmitter hinted it while stale (the hit time); `router' its IsRouter flag;
%% `held' the waiting frames with their IPv6 sources, oldest first.
-record(entry, {state :: incomplete | reachable | stale | delay | probe,
                mac = none :: none | <<_:48>>,
                deadline :: integer(),
                asked = 0 :: non_neg_integer(),
                used = false :: boolean(),
                router = false :: boolean(),
                held = [] :: [{Src :: <<_:128>>, Frame :: term()}]}).

%% `table' holds the entries keyed by IPv6 address, which this module describes with
%% deadline/1, published/1 and reclaimable/1. `reachable' is the drawn reachable time,
%% `recalc' when it is next drawn, `gen' the generator it is drawn from.
-record(cache, {table :: erx_lltable:table(),
                reachable :: pos_integer(),
                recalc :: integer(),
                gen :: erx_net_rand:gen()}).

-opaque cache() :: #cache{}.

-doc """
An empty cache at time `Now` with its own generator `Gen`, which the interface splits from
its own; `max_entries` bounds it (1024 by default).
""".
-spec new(erx_net_rand:gen(), integer(), #{max_entries => pos_integer()}) -> cache().
new(Gen, Now, Opts) ->
    Table = erx_lltable:new(?MODULE, maps:get(max_entries, Opts, ?MAX_ENTRIES)),
    draw_reachable(Now, #cache{table = Table, gen = Gen}).

-doc "The number of entries.".
-spec count(cache()) -> non_neg_integer().
count(#cache{table = Table}) ->
    erx_lltable:count(Table).

-doc "The reachable time in milliseconds, as last drawn.".
-spec reachable_time(cache()) -> pos_integer().
reachable_time(#cache{reachable = Reachable}) ->
    Reachable.

-doc """
A frame from `Src` for the on-link neighbour `Ip` that the transmit path could not address
(`nd6_resolve_slow`). A stale entry turns `delay` and, like any resolved entry, takes the
frame at once. Otherwise the frame is held, the oldest held frame dropped past 16, and a
new entry is solicited by multicast. A frame for a neighbour the full cache has no room for
is dropped.
""".
-spec resolve(<<_:128>>, <<_:128>>, term(), integer(), iface(), cache()) -> {cache(), [action()]}.
resolve(Ip, Src, Frame, Now, Iface, C0) ->
    case lookup_or_create(Ip, Now, C0) of
        none -> {C0, []};
        {E, C, Evicted} -> prepend(Evicted, resolve_entry(Ip, E, Src, Frame, Now, Iface, C))
    end.

resolve_entry(Ip, #entry{state = stale, mac = Mac} = E, _Src, Frame, Now, _Iface, C) ->
    then(put(Ip, E#entry{state = delay, asked = 0, deadline = Now + ?ND6_DELAY}, C),
         [{send, Mac, [Frame]}]);
resolve_entry(Ip, #entry{state = incomplete, asked = 0} = E, Src, Frame, Now, Iface, C) ->
    E1 = E#entry{held = hold(E#entry.held, {Src, Frame}), asked = 1, deadline = Now + ?RETRANS_TIMER},
    then(put(Ip, E1, C), [solicit(Ip, multicast, E1, Iface)]);
resolve_entry(Ip, #entry{state = incomplete} = E, Src, Frame, _Now, _Iface, C) ->
    put(Ip, E#entry{held = hold(E#entry.held, {Src, Frame})}, C);
resolve_entry(_Ip, #entry{mac = Mac}, _Src, Frame, _Now, _Iface, C) ->
    {C, [{send, Mac, [Frame]}]}.

%% A step's result with the actions of an eviction ahead of its own.
prepend(Evicted, {C, Actions}) ->
    {C, Evicted ++ Actions}.

%% A step's result with further actions after its own.
then({C, Actions}, More) ->
    {C, Actions ++ More}.

-doc """
A transmitter used the stale entry of `Ip` at `Now` (FreeBSD's `llentry_provide_feedback`):
the entry is probed five seconds later unless something resolves it first. Any other entry,
or one already hinted, is unchanged.
""".
-spec hint(<<_:128>>, integer(), cache()) -> cache().
hint(Ip, Now, #cache{table = Table} = C) ->
    case erx_lltable:find(Ip, Table) of
        #entry{state = stale, used = false} = E ->
            %% Hinting changes neither state nor address, so nothing is published.
{C1, []} = put(Ip, E#entry{used = true, deadline = Now + ?ND6_DELAY}, C),
            C1;
        _ ->
            C
    end.

-doc """
A received neighbour solicitation or advertisement with its IPv6 header; any other message is
not this module's and changes nothing.
""".
-spec input(#ip6{}, #icmp6{}, integer(), iface(), cache()) -> {cache(), [action()]}.
input(#ip6{hlim = Hlim}, #icmp6{}, _Now, _Iface, C) when Hlim =/= 255 ->
    {C, []};
input(#ip6{fragment = Fragment}, #icmp6{}, _Now, _Iface, C) when Fragment =/= none ->
    {C, []};
input(#ip6{exthdrs = Exthdrs} = Ip6, #icmp6{} = Icmp6, Now, Iface, C) when Exthdrs =/= [] ->
    case lists:keymember(fragment, 1, Exthdrs) of
        true -> {C, []};
        false -> input(Ip6#ip6{exthdrs = []}, Icmp6, Now, Iface, C)
    end;
input(#ip6{} = Ip6, #icmp6{msg = {ns, Target, Opts}}, Now, Iface, C) ->
    ns_input(Ip6, Target, Opts, Now, Iface, C);
input(#ip6{} = Ip6, #icmp6{msg = {na, Flags, Target, Opts}}, Now, Iface, C) ->
    na_input(Ip6, Flags, Target, Opts, Now, Iface, C);
input(#ip6{}, #icmp6{}, _Now, _Iface, C) ->
    {C, []}.

-doc "Runs every deadline at or before `Now` (`nd6_llinfo_timer`, and the reachable time's).".
-spec expired(integer(), iface(), cache()) -> {cache(), [action()]}.
expired(Now, Iface, #cache{recalc = Recalc} = C) when Recalc =< Now ->
    expired(Now, Iface, draw_reachable(Now, C));
expired(Now, Iface, #cache{table = Table} = C) ->
    {Table1, Actions} = erx_lltable:expire(Now, fun(Ip, E, T) -> timer(Ip, E, Now, Iface, T) end, Table),
    {C#cache{table = Table1}, Actions}.

-doc "The earliest deadline: an entry's, or when the reachable time is next drawn.".
-spec next_deadline(cache()) -> integer().
next_deadline(#cache{table = Table, recalc = Recalc}) ->
    case erx_lltable:next_deadline(Table) of
    infinity -> Recalc;
    Deadline -> min(Deadline, Recalc)
end.

%% nd6_llinfo_timer for one entry whose deadline has come, on the table alone.
timer(Ip, #entry{state = incomplete, asked = Asked} = E, Now, Iface, T) when Asked < ?ND6_MMAXTRIES ->
    E1 = E#entry{asked = Asked + 1, deadline = Now + ?RETRANS_TIMER},
    then(erx_lltable:put(Ip, E1, T), [solicit(Ip, multicast, E1, Iface)]);
timer(Ip, #entry{state = incomplete, held = Held}, _Now, _Iface, T) ->
    then(erx_lltable:remove(Ip, T), [{unreachable, Frame} || {_Src, Frame} <- lists:sublist(Held, 1)]);
timer(Ip, #entry{state = reachable} = E, Now, _Iface, T) ->
    erx_lltable:put(Ip, stale(E, Now), T);
timer(Ip, #entry{state = stale, used = false}, _Now, _Iface, T) ->
    erx_lltable:remove(Ip, T);
timer(Ip, #entry{state = State} = E, Now, Iface, T) when State =:= stale; State =:= delay ->
    E1 = E#entry{state = probe, asked = 1, used = false, deadline = Now + ?RETRANS_TIMER},
    then(erx_lltable:put(Ip, E1, T), [solicit(Ip, unicast, E1, Iface)]);
timer(Ip, #entry{state = probe, asked = Asked} = E, Now, Iface, T) when Asked < ?ND6_UMAXTRIES ->
    E1 = E#entry{asked = Asked + 1, deadline = Now + ?RETRANS_TIMER},
    then(erx_lltable:put(Ip, E1, T), [solicit(Ip, unicast, E1, Iface)]);
timer(Ip, #entry{state = probe}, _Now, _Iface, T) ->
    erx_lltable:remove(Ip, T).

%% nd6_ns_input after the hop limit check.
ns_input(#ip6{src = Src, dst = Dst}, Target, Opts, Now, Iface, C) ->
    Lladdr = maps:get(slla, Opts, none),
    SourceOk = case Src of
                   ?UNSPECIFIED -> solicited_node_multicast(Dst) andalso Lladdr =:= none;
                   _ -> neighbour(Src, Iface) orelse erx_lltable:is_key(Src, C#cache.table)
               end,
    Mine = lists:keyfind(Target, 1, maps:get(addrs, Iface)),
    if
        not SourceOk; ?IS_MULTICAST(Target); Mine =:= false; Target =:= Src ->
            {C, []};
        not (Lladdr =:= none orelse byte_size(Lladdr) =:= 6) ->
            {C, []};
        element(2, Mine) =:= duplicated ->
            {C, []};
        element(2, Mine) =:= tentative, Src =:= ?UNSPECIFIED ->
            {C, [{dad, {ns, Target, maps:get(nonce, Opts, none)}}]};
        element(2, Mine) =:= tentative ->
            {C, []};
        true ->
            Multicast = ?IS_MULTICAST(Dst),
            Override = case Multicast andalso element(2, Mine) =/= anycast of
                           true -> ?ND_NA_FLAG_OVERRIDE;
                           false -> 0
                       end,
            NaOpts = case Multicast of
                         true -> #{tlla => maps:get(lladdr, Iface)};
                         false -> #{}
                     end,
            {C1, Learnt, Solicited, NaDst} =
                case Src of
                    ?UNSPECIFIED ->
                        {C, [], 0, ?ALL_NODES};
                    _ ->
                        {C2, Learnt2} = learn(Src, Lladdr, Now, Iface, C),
                        {C2, Learnt2, ?ND_NA_FLAG_SOLICITED, Src}
                end,
            Na = #icmp6{type = ?ND_NEIGHBOR_ADVERT, code = 0,
                        msg = {na, Override bor Solicited, Target, NaOpts}},
            {C1, Learnt ++ [{send_nd, select, NaDst, Na}]}
    end.

%% nd6_cache_lladdr for a solicitation from Src: a new entry is stale with the given
%% address; an existing one whose address changes takes it, turns stale and sends what it
%% held. Without an address nothing changes.
learn(_Src, none, _Now, _Iface, C) ->
    {C, []};
learn(Src, Mac, Now, #{addrs := Addrs}, C0) ->
    case lists:keymember(Src, 1, Addrs) orelse lookup_or_learn(Src, Now, C0) of
        Refused when Refused =:= true; Refused =:= none ->
            {C0, []};
        {#entry{mac = Mac}, C, Evicted} ->
            {C, Evicted};
        {E, C, Evicted} ->
            {C1, Actions} = put(Src, (stale(E, Now))#entry{mac = Mac, held = []}, C),
            {C1, Evicted ++ Actions ++ release(Mac, E#entry.held)}
    end.

%% nd6_na_input after the hop limit check.
na_input(#ip6{dst = Dst}, Flags, Target, Opts, Now, Iface, #cache{table = Table} = C) ->
    Lladdr = maps:get(tlla, Opts, none),
    Solicited = Flags band ?ND_NA_FLAG_SOLICITED =/= 0,
    Mine = lists:keyfind(Target, 1, maps:get(addrs, Iface)),
    if
        ?IS_MULTICAST(Target); Solicited andalso ?IS_MULTICAST(Dst) ->
            {C, []};
        not (Lladdr =:= none orelse byte_size(Lladdr) =:= 6) ->
            {C, []};
        Mine =/= false, element(2, Mine) =:= tentative ->
            {C, [{dad, {na, Target}}]};
        Mine =/= false ->
            {C, [{conflict, Target, Lladdr}]};
        true ->
            case erx_lltable:find(Target, Table) of
                none -> {C, []};
                E -> advertised(Target, E, Flags, Lladdr, Now, C)
            end
    end.

%% The entry part of nd6_na_input: an incomplete entry takes the address, reachable if
%% solicited and stale if not; a resolved one follows RFC 4861's override rules (7.2.5).
%% Case (1) changes only the state, as nd6_na_input leaves it; every other case also takes
%% the router flag, restarts the solicitation count and sends the held frames.
advertised(_Ip, #entry{state = incomplete}, _Flags, none, _Now, C) ->
    {C, []};
advertised(Ip, #entry{state = incomplete} = E, Flags, Mac, Now, C) ->
    E1 = case Flags band ?ND_NA_FLAG_SOLICITED of
             0 -> stale(E#entry{mac = Mac}, Now);
             _ -> reachable(E#entry{mac = Mac}, Now, C)
         end,
    finish_advert(Ip, E, E1, Flags, C);
advertised(Ip, #entry{mac = Old} = E, Flags, Lladdr, Now, C) ->
    Override = Flags band ?ND_NA_FLAG_OVERRIDE =/= 0,
    Solicited = Flags band ?ND_NA_FLAG_SOLICITED =/= 0,
    Change = Lladdr =/= none andalso Lladdr =/= Old,
    if
        not Override, Change, E#entry.state =:= reachable ->                     % (1)
            put(Ip, stale(E, Now), C);
        not Override, Change ->                                                  % (1)
            {C, []};
        true ->
            finish_advert(Ip, E, overridden(E, Solicited, Change, Lladdr, Now, C), Flags, C)
    end.

%% The state and address cases (2a), (2b) and (2c) leave an entry in.
overridden(E, Solicited, Change, Lladdr, Now, C) ->
    if
             Solicited, Lladdr =:= none -> reachable(E, Now, C);                 % (2c)
             Solicited -> reachable(E#entry{mac = Lladdr}, Now, C);              % (2a), (2b)
             Change -> stale(E#entry{mac = Lladdr}, Now);                        % (2a)
             true -> E                                                           % (2b), (2c)
    end.

%% The end of nd6_na_input for both: the router flag is taken, a neighbour that stopped
%% being a router is reported, the solicitation count restarts and held frames go out.
finish_advert(Ip, Old, New, Flags, C) ->
    Router = Flags band ?ND_NA_FLAG_ROUTER =/= 0,
    NotRouter = [{not_router, Ip} || Old#entry.router, not Router],
    New1 = New#entry{router = Router, asked = 0, held = []},
    {C1, Actions} = put(Ip, New1, C),
    {C1, NotRouter ++ Actions ++ release(New1#entry.mac, Old#entry.held)}.

%% nd6_llinfo_setstate(REACHABLE): good for the drawn reachable time.
reachable(E, Now, #cache{reachable = Reachable}) ->
    E#entry{state = reachable, used = false, deadline = Now + Reachable}.

%% nd6_llinfo_setstate(STALE): unused, looked at again when the garbage-collection time
%% is up unless a hint comes first.
stale(E, Now) ->
    E#entry{state = stale, used = false, deadline = Now + ?ND6_GCTIMER}.

%% A solicitation for Ip: by multicast to its solicited-node group while it is resolved for
%% the first time, by unicast to it while it is probed. The source is that of the oldest held
%% frame when it is one of the interface's usable addresses (nd6_llinfo_get_holdsrc), else
%% the interface selects one; the source link-layer address option goes with it.
solicit(Ip, How, #entry{held = Held}, #{lladdr := Lladdr, addrs := Addrs}) ->
    Src = case Held of
              [{HeldSrc, _} | _] ->
                  case lists:keyfind(HeldSrc, 1, Addrs) of
                      {HeldSrc, State} when State =:= preferred; State =:= anycast -> HeldSrc;
                      _ -> select
                  end;
              [] ->
                  select
          end,
    Dst = case How of
              multicast -> solicited_node(Ip);
              unicast -> Ip
          end,
    {send_nd, Src, Dst, #icmp6{type = ?ND_NEIGHBOR_SOLICIT, code = 0, msg = {ns, Ip, #{slla => Lladdr}}}}.

solicited_node(<<_:104, Low:24>>) ->
    <<16#FF02:16, 0:64, 1:16, 16#FF:8, Low:24>>.

solicited_node_multicast(<<16#FF02:16, 0:64, 1:16, 16#FF:8, _:24>>) -> true;
solicited_node_multicast(_Dst) -> false.

%% nd6_is_addr_neighbor, as far as this module knows it: link-local, or on an on-link prefix.
neighbour(<<16#3FA:10, _:118>>, _Iface) ->
    true;
neighbour(Ip, #{onlink := Prefixes}) ->
    lists:any(fun({Prefix, Len}) ->
                  <<P:Len/bits, _/bits>> = Prefix,
                  <<Q:Len/bits, _/bits>> = Ip,
                  P =:= Q
              end, Prefixes).

release(_Mac, []) -> [];
release(Mac, Held) -> [{send, Mac, [Frame || {_Src, Frame} <- Held]}].

hold(Held, Frame) ->
    erx_lltable:hold(Held, Frame, ?ND6_MAXQUEUELEN).

%% ND_COMPUTE_RTIME's interval, drawn uniformly.
draw_reachable(Now, #cache{gen = Gen} = C) ->
    {Offset, Gen1} = erx_net_rand:uniform(?REACHABLE_TIME, Gen),
    C#cache{reachable = ?REACHABLE_TIME div 2 + Offset, recalc = Now + ?ND6_RECALC, gen = Gen1}.

%% The entry of Ip, or a new incomplete one if there is room or room can be made, with
%% the actions of the eviction that made it; none if there is no room.
lookup_or_create(Ip, Now, C) -> entry_for(fun erx_lltable:lookup_or_create/3, Ip, Now, C).

%% The same for a sender learnt from a solicitation, if there is free room: a learnt
%% sender evicts nothing (erx_lltable:lookup_or_learn/3).
lookup_or_learn(Ip, Now, C) -> entry_for(fun erx_lltable:lookup_or_learn/3, Ip, Now, C).

entry_for(Lookup, Ip, Now, #cache{table = Table} = C) ->
    New = #entry{state = incomplete, deadline = Now + ?RETRANS_TIMER},
    case Lookup(Ip, New, Table) of
        none -> none;
        {E, Table1, Evicted} -> {E, C#cache{table = Table1}, Evicted}
    end.

%% Stores the entry of Ip, with the publication its change needs.
put(Ip, E, #cache{table = Table} = C) ->
    {Table1, Actions} = erx_lltable:put(Ip, E, Table),
    {C#cache{table = Table1}, Actions}.

-doc false.
-spec deadline(#entry{}) -> integer().
deadline(#entry{deadline = Deadline}) -> Deadline.

%% What the transmit path sees of an entry: nothing until it has an address, then the
%% address, stale while in the stale state.
-doc false.
-spec published(#entry{}) -> erx_lltable:published().
published(#entry{mac = none}) -> none;
published(#entry{state = stale, mac = Mac}) -> {Mac, stale};
published(#entry{mac = Mac}) -> {Mac, fresh}.

%% A stale entry no transmitter has hinted may be evicted (reclaimable by RFC 4861 5.3);
%% reachable, delay and probe entries are kept.
-doc false.
-spec reclaimable(#entry{}) -> boolean().
reclaimable(#entry{state = State, used = Used}) -> State =:= stale andalso not Used.
