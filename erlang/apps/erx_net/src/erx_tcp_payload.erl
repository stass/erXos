%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_payload).
-moduledoc """
A received segment's payload as TCP holds it: a flat list of binaries, in sequence order
(docs/design-network-fastpath.md, "A merged segment in TCP"). A segment off the wire has one
piece, a merged segment one per member that carried data, each a sub-binary of its frame.
Trimming, reassembly and delivery take parts of a payload with `part/3`, which makes
sub-binaries of the pieces and copies no byte, so nothing on the receive path joins the
pieces; the receive queue joins them once, when the owner reads (erx_tcp_conn).

A payload never holds an empty piece: `from_wire/1` and `part/3` leave them out, so the
empty payload is `[]` and a payload's pieces count what it holds.
""".

-compile({no_auto_import, [size/1]}).
-export([from_wire/1, size/1, part/3]).
-export_type([t/0, wire/0]).

-doc "A payload: its pieces in sequence order, none of them empty.".
-type t() :: [binary()].

-doc """
A payload as the interface hands a segment to the connection (erx_tcp:segment()): the
payload binary of one frame, or the merge's unit, with N the count of segments merged into
it (pure ACKs among them, which add no piece) and its members' payload pieces in order.
""".
-type wire() :: binary() | {merged, N :: 2..256, Pieces :: [binary()]}.

-doc """
A wire payload as `{Payload, Length, NSegs}`: its pieces without empty ones, their total
length and the count of segments it stands for. Anything else fails with `badarg`, since
only the interface makes a wire payload and the merge's count is checked there.
""".
-spec from_wire(wire()) -> {t(), non_neg_integer(), 1..256}.
from_wire(<<>>) ->
    {[], 0, 1};
from_wire(Bin) when is_binary(Bin) ->
    {[Bin], byte_size(Bin), 1};
from_wire({merged, N, Pieces}) when is_integer(N), N >= 2, N =< 256, is_list(Pieces) ->
    lists:all(fun erlang:is_binary/1, Pieces) orelse error(badarg),
    Kept = [Piece || Piece <- Pieces, Piece =/= <<>>],
    {Kept, size(Kept), N};
from_wire(_) ->
    error(badarg).

-doc "The bytes a payload holds.".
-spec size(t()) -> non_neg_integer().
size(Payload) ->
    lists:foldl(fun(Piece, Sum) -> Sum + byte_size(Piece) end, 0, Payload).

-doc """
The Len bytes of Payload from offset Skip on, as `binary:part/3` takes them from one binary:
whole pieces kept as they are, the pieces at either edge cut to sub-binaries. Fails with
`badarg` when the range is not inside the payload.
""".
-spec part(t(), non_neg_integer(), non_neg_integer()) -> t().
part(Payload, Skip, Len) when is_integer(Skip), Skip >= 0, is_integer(Len), Len >= 0 ->
    take(drop(Payload, Skip), Len);
part(_, _, _) ->
    error(badarg).

%% Payload without its first Skip bytes.
drop(Payload, 0) ->
    Payload;
drop([Piece | Rest], Skip) when Skip >= byte_size(Piece) ->
    drop(Rest, Skip - byte_size(Piece));
drop([Piece | Rest], Skip) ->
    [binary:part(Piece, Skip, byte_size(Piece) - Skip) | Rest];
drop([], _) ->
    error(badarg).

%% The first Len bytes of Payload.
take(_, 0) ->
    [];
take([Piece | Rest], Len) when Len >= byte_size(Piece) ->
    [Piece | take(Rest, Len - byte_size(Piece))];
take([Piece | _], Len) ->
    [binary:part(Piece, 0, Len)];
take([], _) ->
    error(badarg).
