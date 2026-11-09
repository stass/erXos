%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/ip_reass.c
%% Copyright (c) 2015 Gleb Smirnoff <glebius@FreeBSD.org>
%% Copyright (c) 2015 Adrian Chadd <adrian@FreeBSD.org>
%% Copyright (c) 1982, 1986, 1988, 1993
%%	The Regents of the University of California.  All rights reserved.
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
%%
%% FreeBSD: sys/netinet6/frag6.c
%% Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project.
%% All rights reserved.
%% Copyright (c) 2019 Netflix, Inc.
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

-module(erx_ip_reass).
-moduledoc """
The table of IP datagrams in reassembly that erx_ip4_reass and erx_ip6_reass
share, and the steps both take for each fragment, translated from
FreeBSD's ip_reass.c and frag6.c at the commit NOTICE-freebsd records
(docs/design-network-stack.md, "IPv4 and ARP", "IPv6, neighbour discovery
and autoconfiguration" and "Resource bounds").

A table belongs to one interface process and holds one family's
datagrams, each under a key its front module makes from the packet
(source, destination, identification, and for IPv4 the protocol). It is
a pure value: `input/3` takes the time and gives back the next table, and
the owner arms its timer at `next_deadline/1` and calls `expire/2` when it
fires; a timer that fires early finds nothing due.

What the table holds is bounded on every axis, by the limits `new/2`
takes (`limits()`):

* `lifetime`: a datagram is dropped this many milliseconds after its first
  fragment arrived: 30 seconds for IPv4 (`ipfragttl`) and 60 for IPv6
  (`IPV6_DEFFRAGTTL`), FreeBSD's defaults;
* `per_datagram`: a datagram that is still incomplete once it holds more
  than this many fragments is dropped, FreeBSD's `maxfragsperpacket` of 16
  for IPv4 and `ip6_maxfragsperpacket` of 64 for IPv6, checked after the
  fragment is placed so that the last one can still complete it;
* `datagrams`, `fragments` and `bytes`: the datagrams in reassembly, the
  fragments held and the bytes they keep alive, on the whole table.
  FreeBSD derives its first two from the system's mbuf clusters
  (`IP_MAXFRAGPACKETS`, `IP_MAXFRAGS`); the defaults here, 1,024 of each
  on an interface, are what FreeBSD allows at 32,768 clusters, and 2 MiB
  is 1,024 of its 2 KiB clusters.

A held fragment counts at the size of the binary it references, not its
own, since a sub-binary keeps its whole frame alive; one smaller than a
quarter of its frame is copied out first, so a peer cannot pin full
frames with tiny fragments (as `erx_tcp_reass` does). The head an
offset-0 fragment leaves (`head()`) is charged at its header bytes, and
every binary in it is copied out, so it keeps no frame alive. A fragment
that would take the table past `fragments` or `bytes` is dropped. A
fragment that starts a new datagram past `datagrams` makes room by
dropping the oldest datagram for IPv4, as `ipq_reuse` does, unless it is
dropped itself, and is dropped for IPv6, as `frag6_input` does.

For each fragment, in this order, the steps common to both families:

1. the ECN rule of RFC 3168, section 5.3: a CE fragment of a not-ECT
   datagram, or a not-ECT fragment of an ECT one, is dropped, and a CE
   fragment marks the datagram CE;
2. the first offset-0 fragment to arrive records the datagram's head, and
   with it the header bytes that IP's limit of 65,535 counts: a fragment
   whose end, with those bytes, would pass the limit is dropped
   (`too_long`), and an offset-0 fragment whose header bytes would put a
   fragment already held past it drops the datagram (`too_long_held`);
3. IPv4 only: once the last fragment has arrived, a fragment ending past
   it, or another last fragment ending elsewhere, is dropped (`ip_reass`'s
   `ipq_maxoff`);
4. placing it among the held fragments, by the family's rule: IPv4 trims
   the overlap away, keeping the bytes of the fragment before and taking
   the new bytes over the ones after (`ip_reass`); IPv6 drops an exact
   duplicate and drops the whole datagram on any other overlap (RFC 5722,
   `frag6_input`);
5. a datagram whose fragments run from 0 without a gap to one that has no
   more after it is complete, and is removed and returned.

Departures from FreeBSD, each in which datagrams complete or which
errors are sent, never in what the table may hold:

* IPv4 counts the header length against 65,535 bytes for every fragment
  once the offset-0 fragment has arrived; FreeBSD counts it only on
  completion, and drops the datagram then.
* When an offset-0 IPv6 fragment arrives and a held fragment would end
  past 65,535 bytes, FreeBSD drops each such fragment and answers each
  with a parameter problem; here the datagram is dropped unanswered.
* IPv6 answers with time exceeded only when a datagram expires;
  `frag6_freef` also answers when an overlap or the per-datagram cap
  drops it.
* IPv4 compares ECN with the first fragment to arrive, as `frag6_input`
  does; `ip_reass` compares with the fragment of lowest offset.
* IPv4 records where the last fragment ends only once that fragment is
  kept; `ip_reass` records it even when it then drops the fragment.
* IPv4 evicts the oldest datagram of the interface; `ipq_reuse` evicts
  within a hash bucket chosen under a secret seed, so here a flood of new
  datagrams always evicts the one that has waited longest.
""".

-export([new/2, input/3, expire/2, next_deadline/1, held/1]).

-export_type([table/0, family/0, limits/0, piece/0, head/0, result/0, reason/0]).

-define(ECN_NOTECT, 0).
-define(ECN_CE, 3).
-define(MAXPACKET, 16#FFFF).

-type family() :: inet | inet6.

-doc "The caps of a table; see the module's description.".
-type limits() :: #{lifetime := pos_integer(), per_datagram := pos_integer(),
                    datagrams := pos_integer(), fragments := pos_integer(),
                    bytes := pos_integer()}.

-doc """
One fragment as the front module hands it over: the datagram's key, the
offset of its data in bytes, whether more fragments follow, its ECN bits,
its data, and for a first fragment its head.
""".
-type piece() :: #{key := term(), off := non_neg_integer(), more := boolean(),
                   ecn := 0..3, data := binary(), head := none | head()}.

-doc """
What an offset-0 fragment records: the header bytes that IP's limit of
65,535 counts, and what its front module rebuilds the datagram from (the
family's header record, with the fragment's zone and link cast, which
the datagram takes, as `ip_reass` and `frag6_input` keep the first
fragment's packet header). For IPv4 the bytes are the
whole header, since the limit is on the total length; for IPv6 they are
the unfragmentable extension headers, since the limit is on the payload
length, which leaves out the 40-byte fixed header.
""".
-type head() :: {HdrLen :: non_neg_integer(), Header :: term()}.

-type reason() :: full | ecn | too_long | too_long_held | bad_end | covered
                | duplicate | overlap | too_many_fragments.

-type result() :: {done, head(), Ecn :: 0..3, Data :: [binary()], table()}
                | {held, table()}
                | {drop, reason(), table()}.

%% A held fragment: bytes [off, end) of the datagram, and the bytes it is
%% charged for.
-record(frag, {off :: non_neg_integer(), 'end' :: non_neg_integer(), more :: boolean(),
               data :: binary(), cost :: non_neg_integer()}).

%% A datagram in reassembly. `frags' are ordered by offset and never
%% overlap; `last_end' is where the last fragment ends once it has arrived
%% (IPv4 only).
-record(dgram, {expire :: integer(), ecn :: 0..3, head = none :: none | head(),
                last_end = none :: none | non_neg_integer(), frags = [] :: [#frag{}],
                cost = 0 :: non_neg_integer()}).

%% `order' holds {Expire, Key} for exactly the datagrams of `dgrams', so the
%% oldest is first; `fragments' counts the fragments of every datagram, and
%% `bytes' is the sum of their `cost'. settle/6 and remove/3 keep it so.
-record(table, {family :: family(), limits :: limits(), dgrams = #{} :: #{term() => #dgram{}},
                order = gb_sets:new() :: gb_sets:set({integer(), term()}),
                fragments = 0 :: non_neg_integer(), bytes = 0 :: non_neg_integer()}).

-opaque table() :: #table{}.

-doc "An empty table of Family, with Limits overriding FreeBSD's caps.".
-spec new(family(), #{atom() => pos_integer()}) -> table().
new(Family, Limits) when Family =:= inet; Family =:= inet6 ->
    Defaults = #{lifetime => lifetime(Family), per_datagram => per_datagram(Family),
                 datagrams => 1024, fragments => 1024, bytes => 2 * 1024 * 1024},
    Merged = maps:merge(Defaults, maps:with(maps:keys(Defaults), Limits)),
    true = lists:all(fun(V) -> is_integer(V) andalso V > 0 end, maps:values(Merged)),
    #table{family = Family, limits = Merged}.

lifetime(inet) -> 30000;
lifetime(inet6) -> 60000.

per_datagram(inet) -> 16;
per_datagram(inet6) -> 64.

-doc """
Takes one fragment at time Now (milliseconds, monotonic). Returns the
datagram it completes, with its head, ECN and data, or says it is held or
dropped and why.
""".
-spec input(piece(), integer(), table()) -> result().
input(#{data := Data0} = Piece, Now, T0) ->
    Data = keep(Data0),
    Frag = #frag{off = maps:get(off, Piece), 'end' = maps:get(off, Piece) + byte_size(Data),
                 more = maps:get(more, Piece), data = Data, cost = binary:referenced_byte_size(Data)},
    HeadCost = case Piece of
                   #{head := {HdrLen, _}} -> HdrLen;
                   #{head := none} -> 0
               end,
    #table{limits = #{fragments := MaxFrags, bytes := MaxBytes}} = T0,
    case T0 of
        #table{fragments = N} when N >= MaxFrags -> {drop, full, T0};
        #table{bytes = B} when B + Frag#frag.cost + HeadCost > MaxBytes -> {drop, full, T0};
        _ -> find(Piece, Frag, Now, T0)
    end.

%% The datagram Piece belongs to, or a new one if there is room for it.
find(#{key := Key} = Piece, Frag, Now, #table{dgrams = Dgrams} = T) ->
    case Dgrams of
        #{Key := D} -> step(Key, D, Piece, Frag, T);
        #{} -> create(Key, Piece, Frag, Now, T)
    end.

create(Key, #{ecn := Ecn} = Piece, Frag, Now,
       #table{family = Family, limits = #{datagrams := Max, lifetime := Lifetime}} = T) ->
    New = #dgram{expire = Now + Lifetime, ecn = Ecn},
    case map_size(T#table.dgrams) < Max of
        true -> step(Key, New, Piece, Frag, T);
        false when Family =:= inet ->
            case step(Key, New, Piece, Frag, remove_oldest(T)) of
                {drop, Reason, _} -> {drop, Reason, T};
                Result -> Result
            end;
        false -> {drop, full, T}
    end.

%% The steps of the module's description, on datagram D0 as the table holds
%% it (or a new one, which the table does not hold yet). `{drop, _}' drops
%% only the fragment; `{discard, _}' drops the datagram with it.
step(Key, D0, #{ecn := Ecn, head := Head}, Frag, #table{family = Family} = T) ->
    maybe
        {ok, D1} ?= ecn(Ecn, D0),
        {ok, D2} ?= head(Head, Frag, D1),
        {ok, D3} ?= last_end(Family, Frag, D2),
        {ok, Frags, Removed} ?= place(Family, Frag, D3#dgram.frags),
        settle(Key, D0, D3#dgram{frags = Frags}, Frag, Removed, T)
    else
        {drop, Reason} -> {drop, Reason, T};
        {discard, Reason} -> {drop, Reason, remove(Key, D0, T)}
    end.

ecn(?ECN_CE, #dgram{ecn = ?ECN_NOTECT}) -> {drop, ecn};
ecn(?ECN_CE, D) -> {ok, D#dgram{ecn = ?ECN_CE}};
ecn(?ECN_NOTECT, #dgram{ecn = Ecn}) when Ecn =/= ?ECN_NOTECT -> {drop, ecn};
ecn(_, D) -> {ok, D}.

%% The first offset-0 fragment records the head, charged at its header
%% bytes and holding no binary that keeps a frame alive; every fragment
%% must end within the largest datagram those bytes leave room for.
head({HdrLen, Header}, #frag{'end' = End}, #dgram{head = none, frags = Frags, cost = Cost} = D) ->
    if
        End + HdrLen > ?MAXPACKET -> {drop, too_long};
        true ->
            case lists:any(fun(#frag{'end' = E}) -> E + HdrLen > ?MAXPACKET end, Frags) of
                true -> {discard, too_long_held};
                false -> {ok, D#dgram{head = {HdrLen, own(Header)}, cost = Cost + HdrLen}}
            end
    end;
head(_, #frag{'end' = End}, #dgram{head = Head} = D) ->
    HdrLen = case Head of {L, _} -> L; none -> 0 end,
    case End + HdrLen > ?MAXPACKET of
        true -> {drop, too_long};
        false -> {ok, D}
    end.

last_end(inet6, _, D) -> {ok, D};
last_end(inet, #frag{more = More, 'end' = End}, #dgram{last_end = Last} = D) ->
    case {More, Last} of
        {true, none} -> {ok, D};
        {false, none} -> {ok, D#dgram{last_end = End}};
        {true, _} when End >= Last -> {drop, bad_end};
        {false, _} when End =/= Last -> {drop, bad_end};
        _ -> {ok, D}
    end.

%% Frag among the held fragments, by the family's rule: the new list and
%% the fragments it pushed out.
place(Family, #frag{off = Off} = Frag, Frags) ->
    {Before, After} = lists:splitwith(fun(#frag{off = O}) -> O =< Off end, Frags),
    place(Family, Frag, lists:reverse(Before), After).

%% IPv4: the fragment before keeps its bytes; the new one takes over the
%% bytes of those after it, which are cut or, if covered, pushed out.
place(inet, Frag0, RevBefore, After) ->
    maybe
        {ok, Frag} ?= trim_front(Frag0, RevBefore),
        {Kept, Removed} = trim_after(Frag, After, []),
        {ok, lists:reverse(RevBefore, [Frag | Kept]), Removed}
    end;
%% IPv6: an exact duplicate is dropped, any other overlap drops the datagram
%% (RFC 5722).
place(inet6, #frag{off = Off, 'end' = End} = Frag, RevBefore, After) ->
    case {RevBefore, After} of
        {[#frag{off = Off, 'end' = End} | _], _} -> {drop, duplicate};
        {[#frag{'end' = PrevEnd} | _], _} when PrevEnd > Off -> {discard, overlap};
        {_, [#frag{off = NextOff} | _]} when End > NextOff -> {discard, overlap};
        _ -> {ok, lists:reverse(RevBefore, [Frag | After]), []}
    end.

trim_front(#frag{'end' = End}, [#frag{'end' = PrevEnd} | _]) when PrevEnd >= End -> {drop, covered};
trim_front(#frag{off = Off} = Frag, [#frag{'end' = PrevEnd} | _]) when PrevEnd > Off ->
    {ok, cut(Frag, PrevEnd - Off)};
trim_front(Frag, _) -> {ok, Frag}.

trim_after(#frag{'end' = End} = Frag, [#frag{off = Off, 'end' = NextEnd} = Next | Rest], Removed)
  when End > Off ->
    case End < NextEnd of
        true -> {[cut(Next, End - Off) | Rest], Removed};
        false -> trim_after(Frag, Rest, [Next | Removed])
    end;
trim_after(_, After, Removed) -> {After, Removed}.

%% The fragment without its first N bytes; it is still charged for its frame.
cut(#frag{off = Off, data = Data} = Frag, N) ->
    Frag#frag{off = Off + N, data = binary_part(Data, N, byte_size(Data) - N)}.

%% Charges Frag and refunds Removed, moves the table's counts by as much as
%% the datagram moved from Old, the version the table holds (or a new, empty
%% one), then completes, holds or drops the datagram.
settle(Key, #dgram{frags = OldFrags, cost = OldCost}, #dgram{frags = Frags, cost = Cost} = D0,
       #frag{cost = Added}, Removed, #table{fragments = N, bytes = B, limits = #{per_datagram := Max}} = T0) ->
    Refund = lists:sum([C || #frag{cost = C} <- Removed]),
    D = D0#dgram{cost = Cost + Added - Refund},
    T = T0#table{fragments = N + length(Frags) - length(OldFrags), bytes = B + D#dgram.cost - OldCost},
    case complete(0, Frags) of
        true -> {done, D#dgram.head, D#dgram.ecn, [Data || #frag{data = Data} <- Frags], remove(Key, D, T)};
        false when length(Frags) > Max -> {drop, too_many_fragments, remove(Key, D, T)};
        false -> {held, store(Key, D, T)}
    end.

%% Whether the fragments run from At without a gap to one with no more
%% after it.
complete(At, [#frag{off = At, more = false}]) -> true;
complete(At, [#frag{off = At, 'end' = End} | [_ | _] = Rest]) -> complete(End, Rest);
complete(_, _) -> false.

store(Key, #dgram{expire = Expire} = D, #table{dgrams = Dgrams, order = Order} = T) ->
    T#table{dgrams = Dgrams#{Key => D}, order = gb_sets:add({Expire, Key}, Order)}.

%% The table without datagram Key, whose fragments and bytes D counts.
remove(Key, #dgram{expire = Expire, frags = Frags, cost = Cost},
       #table{dgrams = Dgrams, order = Order, fragments = N, bytes = B} = T) ->
    T#table{dgrams = maps:remove(Key, Dgrams), order = gb_sets:delete_any({Expire, Key}, Order),
            fragments = N - length(Frags), bytes = B - Cost}.

remove_oldest(#table{dgrams = Dgrams, order = Order} = T) ->
    {_, Key} = gb_sets:smallest(Order),
    remove(Key, map_get(Key, Dgrams), T).

%% A payload smaller than a quarter of the binary it references is copied
%% out, so it no longer keeps that binary alive.
keep(Data) ->
    case binary:referenced_byte_size(Data) > 4 * byte_size(Data) of
        true -> binary:copy(Data);
        false -> Data
    end.

%% Term with every binary in it copied unless it is all of the binary it
%% references.
own(Bin) when is_binary(Bin) ->
    case binary:referenced_byte_size(Bin) > byte_size(Bin) of
        true -> binary:copy(Bin);
        false -> Bin
    end;
own(List) when is_list(List) -> [own(X) || X <- List];
own(Tuple) when is_tuple(Tuple) -> list_to_tuple(own(tuple_to_list(Tuple)));
own(Term) -> Term.

-doc """
Drops every datagram whose lifetime ended at or before Now, and returns,
for each of them that holds its first fragment, that fragment's header
and data, which IPv6 answers with a time-exceeded error.
""".
-spec expire(integer(), table()) -> {[{Header :: term(), Data :: binary()}], table()}.
expire(Now, T) ->
    expire(Now, T, []).

expire(Now, #table{dgrams = Dgrams, order = Order} = T, Acc) ->
    case gb_sets:is_empty(Order) of
        false ->
            case gb_sets:smallest(Order) of
                {Expire, Key} when Expire =< Now ->
                    D = map_get(Key, Dgrams),
                    expire(Now, remove(Key, D, T), first_fragment(D) ++ Acc);
                _ ->
                    {lists:reverse(Acc), T}
            end;
        true ->
            {lists:reverse(Acc), T}
    end.

first_fragment(#dgram{head = {_, Header}, frags = [#frag{off = 0, data = Data} | _]}) -> [{Header, Data}];
first_fragment(_) -> [].

-doc "When the oldest datagram's lifetime ends, or `none` if the table is empty.".
-spec next_deadline(table()) -> integer() | none.
next_deadline(#table{order = Order}) ->
    case gb_sets:is_empty(Order) of
        true -> none;
        false -> element(1, gb_sets:smallest(Order))
    end.

-doc "What the table holds, for the inspector and the tests.".
-spec held(table()) -> #{datagrams := non_neg_integer(), fragments := non_neg_integer(),
                         bytes := non_neg_integer()}.
held(#table{dgrams = Dgrams, fragments = N, bytes = B}) ->
    #{datagrams => map_size(Dgrams), fragments => N, bytes => B}.
