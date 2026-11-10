%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/tcp_reass.c
%% Copyright (c) 1982, 1986, 1988, 1990, 1993, 1994, 1995
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

-module(erx_tcp_reass).
-moduledoc """
A TCP connection's reassembly queue: the data received ahead of `rcv_nxt`,
held until the gap before it fills, translated from `tcp_reass` in FreeBSD's
sys/netinet/tcp_reass.c at the commit NOTICE-freebsd records
(docs/design-network-stack.md, "The send log, SACK and reassembly").

The queue is a pure value the connection process owns. Sequence numbers in
and out are the unwrapped integers of erx_tcp_seq, so ordinary comparisons
order them. It holds two views of the same bytes:

* the ranges: the received spans above `rcv_nxt`, sorted, each one
  maximal, so no two touch. They are FreeBSD's queue entries, which
  `tcp_reass` merges whenever a segment joins two (`tcp_reass_append`,
  `tcp_reass_prepend`, `tcp_reass_merge_forward`), and the cap counts them;
* the pieces: the payload binaries, disjoint, keyed by their first
  sequence number, so the bytes of a range are the pieces inside it.

What it holds is bounded twice, as in FreeBSD. The bytes count against the
receive buffer: a segment out of order is dropped when the queue's bytes
and its own would exceed the room the caller gives (`sb_mbmax` less
`sb_mbcnt`). A held piece counts at the size of the binary it references,
not its own, since a sub-binary keeps its whole frame alive, and one
smaller than a quarter of its frame is copied out first, as FreeBSD's
socket buffers compress small mbufs, so a peer cannot pin many full frames
with one-byte segments. Each piece also counts `MSIZE`, 256 bytes, for
what holding it costs, as FreeBSD charges every mbuf of a queued chain at
least that (`tcp_reass_overhead_of_chain`), so a peer cannot make the
queue hold many one-byte pieces for the price of their bytes. And a segment that would open a new range is
dropped once the queue holds `min(hiwat div mss + 1, 100)` ranges
(`tcp_reass_maxqueuelen`), except the segment at `rcv_nxt`, which fills
the gap and always passes.

Overlaps are trimmed as FreeBSD trims them: a segment starting inside a
held range keeps that range's bytes and adds only what lies past its end;
past that, the new segment's bytes replace any held bytes they cover.

Two departures from FreeBSD's mechanism keep its decisions. A FIN queued
past a gap is a position, not an entry of its own, so it does not count
toward the cap. And any data past a queued FIN is dropped, where FreeBSD
checks only segments that start at or past its last entry and lets one
that starts earlier merge over a FIN-only entry and lose the FIN.
""".

-export([new/0, insert/4, present/2, held/1, is_empty/1]).

-export_type([reass/0, segment/0, context/0, result/0, drop/0]).

%% tcp_reass_maxqueuelen, tcp_reass.c:110.
-define(MAX_QUEUE_LEN, 100).
%% What each held piece costs beyond its bytes, FreeBSD's MSIZE.
-define(PIECE_OVERHEAD, 256).

-record(reass, {
    %% Received spans above rcv_nxt as {First, End}, End exclusive and
    %% greater than First, sorted and never touching.
    ranges = [] :: [{integer(), integer()}],
    %% The payload, keyed by each piece's first sequence number; every
    %% piece lies inside one range and the pieces of a range cover it.
    %% Each is held with its cost, fixed when it was taken (see hold/1).
    pieces = gb_trees:empty() :: gb_trees:tree(integer(), {binary(), non_neg_integer()}),
    %% The sequence number the peer's FIN takes, once a FIN is queued.
    fin = none :: none | integer(),
    %% What the pieces keep alive: the sum of their costs.
    bytes = 0 :: non_neg_integer()
}).

-opaque reass() :: #reass{}.

-doc """
A received segment, already trimmed by the caller to start at or after
`rcv_nxt` and to end inside the receive window: its first sequence number,
its payload, in pieces (erx_tcp_payload), each of which the queue holds on its own, and
whether it carries FIN.
""".
-type segment() :: #{seq := integer(), data := erx_tcp_payload:t(), fin := boolean()}.

-doc """
What the queue needs from the connection: whether it has reached
ESTABLISHED (before that nothing is delivered, as `TCPS_HAVEESTABLISHED`
gates `tcp_reass`), the room left in the receive buffer in bytes, and the
buffer's high-water mark and the MSS, which set the cap on ranges.
""".
-type context() :: #{established := boolean(), room := non_neg_integer(),
                     hiwat := pos_integer(), mss := pos_integer()}.

-doc """
Why a segment was not taken. `empty`: no payload and no FIN, or a bare FIN
before ESTABLISHED, which the peer will retransmit. `no_room`: the receive
buffer cannot take it. `queue_full`: it would open a range past the cap.
`after_fin`: it carries data past the FIN already queued. `fin_inside`: its
FIN lies before data already queued. In each case the queue is unchanged.
""".
-type drop() :: empty | no_room | queue_full | after_fin | fin_inside.

-doc """
`{delivered, Data, RcvNxt, Fin, Queue}`: Data, which may be empty, is in
order from the old `rcv_nxt` up to the new RcvNxt, and Fin says the peer's
FIN follows it (RcvNxt counts the data only; the FIN stage advances past
the FIN). `{queued, Queue}`: the segment is held, or was a duplicate of
what is, and nothing is in order yet. `{dropped, Reason, Queue}`.
""".
-type result() :: {delivered, iodata(), integer(), boolean(), reass()}
                | {queued, reass()}
                | {dropped, drop(), reass()}.

-doc "An empty queue.".
-spec new() -> reass().
new() -> #reass{}.

-doc """
Take a received segment, as `tcp_reass` does when called with a header:
the checks in FreeBSD's order (an empty segment, the room, a FIN before
queued data, data past the queued FIN), the overlap trimming, the cap on ranges, and then
the in-order data, if any, delivered as `present/2` would.
""".
-spec insert(reass(), segment(), integer(), context()) -> result().
insert(Q, #{seq := Seq, data := Data, fin := Fin}, RcvNxt, Ctx)
  when is_integer(Seq), is_list(Data), is_boolean(Fin), is_integer(RcvNxt), Seq >= RcvNxt ->
    #{established := Established, room := Room, hiwat := HiWat, mss := Mss} = Ctx,
    End = Seq + erx_tcp_payload:size(Data),
    InOrder = Seq =:= RcvNxt andalso Established,
    Fits = InOrder orelse Q#reass.bytes + lists:sum([cost(Piece) || Piece <- Data]) =< Room,
    Cap = min(HiWat div Mss + 1, ?MAX_QUEUE_LEN),
    case check(Q, Seq, End, Fin, Established, Fits) of
        ok ->
            case trim(Q#reass.ranges, Seq, End) of
                duplicate ->
                    {queued, Q};
                {new_range, Start} when not InOrder, Start < End, length(Q#reass.ranges) >= Cap ->
                    {dropped, queue_full, Q};
                {_, Start} ->
                    Q1 = place(Q, Start, End, erx_tcp_payload:part(Data, Start - Seq, End - Start)),
                    Q2 = case Fin of
                             true -> Q1#reass{fin = End};
                             false -> Q1
                         end,
                    case Established of
                        true -> present(Q2, RcvNxt);
                        false -> {queued, Q2}
                    end
            end;
        Reason ->
            {dropped, Reason, Q}
    end.

-doc """
Deliver what is in order at `rcv_nxt`, the `present` part of `tcp_reass`,
which FreeBSD also runs alone once a connection becomes ESTABLISHED to
pass up the data queued before. Because ranges never touch, at most the
first range is in order. RcvNxt is the connection's `rcv_nxt`, which never
passes the start of a queued range, since only this function delivers it.
""".
-spec present(reass(), integer()) -> result().
present(#reass{ranges = [{RcvNxt, End} | Rest]} = Q, RcvNxt) ->
    {Data, Pieces, Bytes} = take_until(End, Q#reass.pieces, Q#reass.bytes, []),
    {Fin, Q1} = take_fin(Q#reass{ranges = Rest, pieces = Pieces, bytes = Bytes}, End),
    {delivered, Data, End, Fin, Q1};
present(#reass{fin = RcvNxt} = Q, RcvNxt) ->
    {delivered, [], RcvNxt, true, Q#reass{fin = none}};
present(Q, RcvNxt) when is_integer(RcvNxt) ->
    {queued, Q}.

-doc """
What the queue holds: the bytes it keeps alive, counted against the
receive buffer, its ranges and the FIN's sequence number if one is queued.
""".
-spec held(reass()) -> #{bytes := non_neg_integer(), ranges := [{integer(), integer()}],
                         fin := none | integer()}.
held(#reass{ranges = Ranges, fin = Fin, bytes = Bytes}) ->
    #{bytes => Bytes, ranges => Ranges, fin => Fin}.

-doc "Whether nothing is queued, FreeBSD's `SEGQ_EMPTY`.".
-spec is_empty(reass()) -> boolean().
is_empty(#reass{ranges = Ranges, fin = Fin}) -> Ranges =:= [] andalso Fin =:= none.

%% The checks tcp_reass makes before it trims, in its order. A segment with
%% neither data nor FIN does no one any good, and a bare FIN before
%% ESTABLISHED is stripped. Then the room (Fits). A FIN whose end lies before the end of what is queued is "trying
%% to game us"; queued here includes a FIN beyond the last range, which
%% FreeBSD holds as an entry of its own. Data past a queued FIN is dropped.
check(_, Seq, Seq, false, _, _) -> empty;
check(_, Seq, Seq, true, false, _) -> empty;
check(_, _, _, _, _, false) -> no_room;
check(Q, _, End, Fin, _, true) ->
    Tail = tail(Q),
    if
        Fin, is_integer(Tail), End < Tail -> fin_inside;
        is_integer(Q#reass.fin), End > Q#reass.fin -> after_fin;
        true -> ok
    end.

%% The end of what is queued: the end of the last range or the FIN's
%% sequence number, whichever is later, or none when nothing is.
tail(#reass{ranges = [], fin = Fin}) -> Fin;
tail(#reass{ranges = Ranges, fin = none}) -> element(2, lists:last(Ranges));
tail(#reass{ranges = Ranges, fin = Fin}) -> max(element(2, lists:last(Ranges)), Fin).

%% Where the segment [Seq, End) starts once trimmed against the range it
%% starts in, and whether it then joins a held range or opens a new one,
%% which the cap counts. A segment starting inside or at the end of a range
%% keeps that range's bytes: it is a duplicate when the range already
%% covers it, and otherwise starts at the range's end and joins it. A
%% segment starting in no range joins one when it reaches the next range's
%% start.
trim([{RangeFirst, RangeEnd} | _], Seq, End) when RangeFirst =< Seq, Seq =< RangeEnd ->
    case RangeEnd > Seq andalso End =< RangeEnd of
        true -> duplicate;
        false -> {joins, max(Seq, RangeEnd)}
    end;
trim([{RangeFirst, _} | Rest], Seq, End) when RangeFirst =< Seq ->
    trim(Rest, Seq, End);
trim([{RangeFirst, _} | _], Seq, End) when RangeFirst =< End ->
    {joins, Seq};
trim(_, Seq, _) ->
    {new_range, Seq}.

%% Hold the trimmed payload Data at [Start, End): drop or cut the held
%% pieces it covers, since its bytes replace theirs, then add each of its
%% pieces at its own sequence number and merge its span into the ranges.
%% A bare FIN adds nothing here.
place(Q, End, End, _) ->
    Q;
place(#reass{ranges = Ranges, pieces = Pieces, bytes = Bytes} = Q, Start, End, Data) ->
    {Pieces1, Bytes1} = uncover(gb_trees:iterator_from(Start, Pieces), End, Pieces, Bytes),
    {Pieces2, Bytes2} = add(Data, Start, Pieces1, Bytes1),
    Q#reass{ranges = merge(Ranges, Start, End), pieces = Pieces2, bytes = Bytes2}.

%% The pieces of a payload, the first at Key, each held at its own sequence number.
add([], _, Pieces, Bytes) ->
    {Pieces, Bytes};
add([Data | Rest], Key, Pieces, Bytes) ->
    {_, Cost} = Piece = hold(Data),
    add(Rest, Key + byte_size(Data), gb_trees:insert(Key, Piece, Pieces), Bytes + Cost).

%% Delete the held pieces that start between the iterator's position and
%% End, and cut the one that runs past End down to its part after End.
%% No piece starts before the position and runs past it, because trim/3
%% returns as the start either the end of the range the segment starts in
%% or a point inside no range.
uncover(Iter, End, Pieces, Bytes) ->
    case gb_trees:next(Iter) of
        {Key, {Data, Cost}, Next} when Key < End ->
            Pieces1 = gb_trees:delete(Key, Pieces),
            case Key + byte_size(Data) of
                DataEnd when DataEnd =< End ->
                    uncover(Next, End, Pieces1, Bytes - Cost);
                DataEnd ->
                    {_, TailCost} = Tail = hold(binary:part(Data, End - Key, DataEnd - End)),
                    {gb_trees:insert(End, Tail, Pieces1), Bytes - Cost + TailCost}
            end;
        _ ->
            {Pieces, Bytes}
    end.

%% Ranges with [First, End) merged in, together with every range it
%% overlaps or touches.
merge([{F, L} | Rest], First, End) when L < First -> [{F, L} | merge(Rest, First, End)];
merge([{F, L} | Rest], First, End) when F =< End -> merge(Rest, min(F, First), max(L, End));
merge(Rest, First, End) -> [{First, End} | Rest].

%% The payload of the pieces before End, in order, taken out of the tree.
take_until(End, Pieces, Bytes, Acc) ->
    case gb_trees:is_empty(Pieces) of
        false ->
            case gb_trees:smallest(Pieces) of
                {Key, {Data, Cost}} when Key < End ->
                    take_until(End, gb_trees:delete(Key, Pieces), Bytes - Cost, [Data | Acc]);
                _ ->
                    {lists:reverse(Acc), Pieces, Bytes}
            end;
        true ->
            {lists:reverse(Acc), Pieces, Bytes}
    end.

take_fin(#reass{fin = End} = Q, End) -> {true, Q#reass{fin = none}};
take_fin(Q, _) -> {false, Q}.

%% A payload as the queue holds it, with what it costs the receive buffer
%% (see cost/1). The cost is fixed here, once, because a binary's
%% referenced size can change later: ERTS shrinks a binary built by
%% appending when it collects garbage.
hold(Data) ->
    Kept = case copy_out(Data) of
               true -> binary:copy(Data);
               false -> Data
           end,
    {Kept, cost(Kept)}.

%% What holding Data costs: all of the binary it keeps alive, or only its
%% own bytes once copied out, plus the per-piece overhead.
cost(Data) ->
    case copy_out(Data) of
        true -> byte_size(Data) + ?PIECE_OVERHEAD;
        false -> binary:referenced_byte_size(Data) + ?PIECE_OVERHEAD
    end.

%% Whether a payload is smaller than a quarter of the binary it references,
%% and so is copied out to stop keeping that binary alive.
copy_out(Data) -> binary:referenced_byte_size(Data) > 4 * byte_size(Data).
