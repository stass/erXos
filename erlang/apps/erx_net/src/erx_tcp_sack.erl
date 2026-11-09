%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_sack).
-moduledoc """
The receiver's SACK blocks of a TCP connection: which out-of-order ranges
its acknowledgements report, in which order, and the D-SACK block for a
duplicate (docs/design-network-stack.md, "The send log, SACK and
reassembly"). It is written from RFC 2018 section 4 and RFC 2883 section 4,
not translated from FreeBSD's `tcp_sack.c`, whose NRL notice carries an
advertising clause.

The value is pure and the connection owns it beside its erx_tcp_reass queue.
Sequence numbers in and out are the unwrapped integers of erx_tcp_seq; the
connection turns each edge into its 32-bit wire form when it builds the
acknowledgement.

It keeps two things:

* the held ranges, most recently touched first. They are exactly the ranges
  erx_tcp_reass holds, which `arrived/4` takes from `erx_tcp_reass:held/1`
  after every segment, so a range that is delivered leaves the list and
  ranges that merge become one. Only their order is this module's own: the
  range the last segment touched comes first, as RFC 2018 asks of the block
  "containing the segment which triggered this ACK", and the rest keep their
  order, so the ranges are ordered by their latest arrival. RFC 2018 asks
  for the most recently reported blocks first, which is the same order when
  every arrival is acknowledged.
* the pending D-SACK block, or `none`: the lowest contiguous part of the
  last duplicate segment that the receiver already had, below `rcv_nxt` or
  inside a held range (RFC 2883 section 4). `ack/1` reports it once, first,
  followed by the held range that contains it if there is one, and clears
  it; a later duplicate replaces one not yet reported.

The list is bounded by what erx_tcp_reass holds (its cap on ranges), and
`ack/1` gives at most `?MAX_SACK_BLOCKS`, the four blocks a 40-byte option
area can carry. erx_tcp_wire's encoder keeps as many from the front as the
segment's other options leave room for, so the order above is also the
order in which blocks are dropped.
""".

-export([new/0, arrived/4, ack/1]).

-export_type([sack/0, range/0]).

%% RFC 2018 section 3: an option of four blocks takes 34 of the 40 bytes.
-define(MAX_SACK_BLOCKS, 4).

-record(sack, {
    %% The held ranges, most recently touched first.
    ranges = [] :: [range()],
    %% The D-SACK block not yet reported.
    dsack = none :: none | range()
}).

-opaque sack() :: #sack{}.

-doc "A span of sequence numbers `{First, End}`, End the number after the last byte.".
-type range() :: {integer(), integer()}.

-doc "No ranges held and no D-SACK pending.".
-spec new() -> sack().
new() -> #sack{}.

-doc """
Account for a segment the reassembly has just seen, whether it delivered,
queued or dropped it; the connection calls it for every segment that passed
its acceptance checks (window, PAWS) and so reached erx_tcp_reass.

* Segment is the range of data the segment carried as it arrived, before
  the connection trimmed it to `rcv_nxt`: SYN and FIN take no part, so a
  segment without data gives an empty range.
* RcvNxtBefore is `rcv_nxt` when the segment arrived, before
  `erx_tcp_reass:insert/4`. Passing the advanced one would report the
  segment's own new data as a duplicate.
* HeldAfter is `maps:get(ranges, erx_tcp_reass:held(Queue))` after the
  insert, so a range at or below the new `rcv_nxt` is already gone from it.

The duplicate part is computed against the ranges held before, so it
covers bytes this receiver had kept, never bytes it dropped for room.
""".
-spec arrived(sack(), Segment :: range(), RcvNxtBefore :: integer(),
              HeldAfter :: [range()]) -> sack().
arrived(#sack{ranges = Old, dsack = Pending} = Sack, {First, End} = Segment, RcvNxtBefore,
        HeldAfter)
  when is_integer(First), is_integer(End), First =< End, is_integer(RcvNxtBefore),
       is_list(HeldAfter) ->
    Dsack = case duplicate(Segment, RcvNxtBefore, Old) of
                none -> Pending;
                Range -> Range
            end,
    Sack#sack{ranges = by_recency(Segment, Old, HeldAfter), dsack = Dsack}.

-doc """
The blocks for the next acknowledgement, at most `?MAX_SACK_BLOCKS` of
them: the pending D-SACK block first if there is one, then the held range
that contains it (RFC 2883), then the other held ranges, most recently
touched first (RFC 2018). An empty list when nothing is held and no
duplicate is pending. Returns the value with the D-SACK block cleared,
since each duplicate is reported once.
""".
-spec ack(sack()) -> {[range()], sack()}.
ack(#sack{ranges = Ranges, dsack = none} = Sack) ->
    {lists:sublist(Ranges, ?MAX_SACK_BLOCKS), Sack};
ack(#sack{ranges = Ranges, dsack = Dsack} = Sack) ->
    {Containing, Others} = lists:partition(fun(Range) -> overlaps(Dsack, Range) end, Ranges),
    Blocks = [Dsack | lists:sublist(Containing ++ Others, ?MAX_SACK_BLOCKS - 1)],
    {Blocks, Sack#sack{dsack = none}}.

%% The lowest contiguous part of Segment the receiver already had, or none.
%% Data below RcvNxt comes first: the byte at RcvNxt is never held once the
%% connection is ESTABLISHED. Otherwise the part inside the lowest held range
%% it overlaps, which is contiguous because held ranges never touch. Old is
%% the ranges held before the segment.
duplicate({First, End}, _RcvNxt, _Old) when First =:= End ->
    none;
duplicate({First, End}, RcvNxt, _Old) when First < RcvNxt ->
    {First, min(End, RcvNxt)};
duplicate({First, End} = Segment, _RcvNxt, Old) ->
    case [{max(First, OldFirst), min(End, OldEnd)}
          || {OldFirst, OldEnd} = Range <- Old, overlaps(Segment, Range)] of
        [] -> none;
        Parts -> lists:min(Parts)
    end.

%% Held in the order the option reports it: the ranges Segment touched, then
%% the old ranges still held, in their old order, then any held range the old
%% list does not know, in sequence order. A range that changed without being
%% touched (only when the queue moved without an arrival) is such a range.
by_recency(Segment, Old, Held) ->
    {Touched, Untouched} = lists:partition(fun(Range) -> overlaps(Segment, Range) end, Held),
    Known = sets:from_list(Old, [{version, 2}]),
    {Kept, Unknown} = lists:partition(fun(Range) -> sets:is_element(Range, Known) end, Untouched),
    Untouched1 = sets:from_list(Kept, [{version, 2}]),
    Touched ++ [Range || Range <- Old, sets:is_element(Range, Untouched1)] ++ Unknown.

%% Whether two ranges share a sequence number; an empty range shares none.
overlaps({First, End}, {OtherFirst, OtherEnd}) ->
    First < End andalso OtherFirst < OtherEnd andalso First < OtherEnd andalso OtherFirst < End.
