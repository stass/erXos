%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_sndbuf).
-moduledoc """
A connection's send buffer (docs/design-network-stack.md, "Transmitting"): the bytes from
`snd_una` on, kept as the queue of binaries the owner sent, never copied. Output reads a
range as sub-binaries of them; an acknowledgement drops bytes from the front.
""".

-export([new/0, append/2, size/1, range/4, drop/2]).

-export_type([buf/0]).

-record(sndbuf, {size = 0 :: non_neg_integer(),
                 chunks = queue:new() :: queue:queue(binary())}).

-opaque buf() :: #sndbuf{}.

-doc "An empty buffer.".
-spec new() -> buf().
new() -> #sndbuf{}.

-doc "Appends `Data` at the end; empty data changes nothing.".
-spec append(buf(), binary()) -> buf().
append(Buf, <<>>) -> Buf;
append(#sndbuf{size = Size, chunks = Chunks}, Data) when is_binary(Data) ->
    #sndbuf{size = Size + byte_size(Data), chunks = queue:in(Data, Chunks)}.

-doc "The bytes held (`sbavail(&so->so_snd)`).".
-spec size(buf()) -> non_neg_integer().
size(#sndbuf{size = Size}) -> Size.

-doc """
The `Len` bytes at offset `Off` from the front as at most `Max` sub-binaries, one for each
binary the range meets, so shorter when the buffer ends first or the range meets more
binaries than `Max`. A run's payload is at most the 64 binaries that the C which cuts it
walks (docs/design-network-fastpath.md, "A run").
""".
-spec range(buf(), non_neg_integer(), non_neg_integer(), pos_integer() | infinity) -> [binary()].
range(#sndbuf{chunks = Chunks}, Off, Len, Max)
  when is_integer(Off), Off >= 0, is_integer(Len), Len >= 0,
       Max =:= infinity orelse is_integer(Max) andalso Max > 0 ->
    take(queue:to_list(Chunks), Off, Len, Max).

take(_, _, 0, _) -> [];
take(_, _, _, 0) -> [];
take([], _, _, _) -> [];
take([Chunk | Rest], Off, Len, Max) when Off >= byte_size(Chunk) ->
    take(Rest, Off - byte_size(Chunk), Len, Max);
take([Chunk | Rest], Off, Len, Max) ->
    N = min(Len, byte_size(Chunk) - Off),
    [binary:part(Chunk, Off, N) | take(Rest, 0, Len - N, fewer(Max))].

fewer(infinity) -> infinity;
fewer(Max) -> Max - 1.

-doc "Drops the first `N` bytes, at most what the buffer holds (`sbdrop`).".
-spec drop(buf(), non_neg_integer()) -> buf().
drop(#sndbuf{size = Size, chunks = Chunks}, N) when is_integer(N), N >= 0 ->
    drop(Chunks, min(N, Size), Size).

drop(Chunks, 0, Size) -> #sndbuf{size = Size, chunks = Chunks};
drop(Chunks0, N, Size) ->
    {{value, Chunk}, Chunks} = queue:out(Chunks0),
    case byte_size(Chunk) of
        Len when Len =< N -> drop(Chunks, N - Len, Size - Len);
        Len -> #sndbuf{size = Size - N, chunks = queue:in_r(binary:part(Chunk, N, Len - N), Chunks)}
    end.
