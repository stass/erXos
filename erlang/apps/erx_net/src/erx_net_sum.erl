%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_sum).
-moduledoc """
One's-complement arithmetic on Internet checksum sums (RFC 1071), for the sums the copy hands
up with each received frame (docs/design-network-stack.md, "Checksums in the copy"). A sum
is the RFC 1071 sum of some bytes, folded to 16 bits and not complemented: what
`erx_bytes:inet_csum(0, Bytes)` returns for them.

A transport whose copy sums hands each frame up with its network sum, the sum of the bytes
after the link header. Each layer above derives the sum of the bytes its own checksum covers
from it with `span/4`, subtracting the sums of the headers before them and of the padding
after them, so no payload byte is read again to check it.

One's-complement arithmetic has two zeros, 0 and 16#ffff. The fold of a positive total is
never 0, so a sum derived by `add/2` or `sub/2` from a nonzero sum is nonzero, with zero
written 16#ffff: the form a decoder compares with when it checks a checksum.
""".

-export([add/2, sub/2, span/4]).

-export_type([sum/0]).

-define(IS_SUM(S), (is_integer(S) andalso S >= 0 andalso S =< 16#ffff)).

-doc "A folded, uncomplemented one's-complement sum.".
-type sum() :: 0..16#ffff.

-doc "The one's-complement sum of A and B; a sum outside 0..16#ffff is `badarg`.".
-spec add(sum(), sum()) -> sum().
add(A, B) when ?IS_SUM(A), ?IS_SUM(B) -> fold(A + B);
add(_, _) -> error(badarg).

-doc "A less B: adding a word's complement subtracts it (RFC 1071).".
-spec sub(sum(), sum()) -> sum().
sub(A, B) when ?IS_SUM(A), ?IS_SUM(B) -> fold(A + (16#ffff - B));
sub(_, _) -> error(badarg).

-doc """
The sum of the `Length` bytes of Packet from `Start`, given `Sum`, the sum of all of Packet:
`Sum` less the sum of the bytes before `Start` and less that of the bytes after
`Start + Length`. `Start` must be even, as an IP header's length is, so the bytes from it
are summed as words from their first byte. When the bytes
after start at an odd offset, their sum is byte-swapped first (RFC 1071, section 2(B)). A
range past Packet's end raises `badarg`; its bounds come from decoders that have checked
them against Packet.
""".
-spec span(binary(), sum(), non_neg_integer(), non_neg_integer()) -> sum().
span(Packet, Sum, Start, Length) when is_binary(Packet), ?IS_SUM(Sum),
                                      is_integer(Start), Start >= 0, Start rem 2 =:= 0,
                                      is_integer(Length), Length >= 0,
                                      Start + Length =< byte_size(Packet) ->
    <<Before:Start/binary, _:Length/binary, After/binary>> = Packet,
    sub(sub(Sum, piece(Before)), at(Start + Length, piece(After)));
span(_, _, _, _) ->
    error(badarg).

%% The sum of a piece, without a call for the empty one: every IPv4 header, which the IPv4 path
%% has already taken off, and every frame without padding.
piece(<<>>) -> 0;
piece(Bytes) -> erx_bytes:inet_csum(0, Bytes).

%% A sum taken from a piece's first byte, as seen from Offset in the whole.
at(Offset, Sum) when Offset rem 2 =:= 0 -> Sum;
at(_, Sum) -> (Sum bsr 8) bor ((Sum band 16#ff) bsl 8).

%% The end-around carry: A + B of two sums carries at most once, and its result never carries.
fold(Total) -> (Total band 16#ffff) + (Total bsr 16).
