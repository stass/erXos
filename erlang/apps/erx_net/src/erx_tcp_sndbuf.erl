%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_sndbuf).
-moduledoc """
A connection's send buffer (docs/design-network-stack.md, "Transmitting"): the bytes from
`snd_una` on, kept as the queue of binaries the owner sent, never copied. Output reads a
range as sub-binaries of them; an acknowledgement drops bytes from the front.
""".

-export([new/0, append/2, size/1, range/3, drop/2]).

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
The `Len` bytes at offset `Off` from the front as sub-binaries, shorter when the buffer ends
first.
""".
-spec range(buf(), non_neg_integer(), non_neg_integer()) -> [binary()].
range(#sndbuf{chunks = Chunks}, Off, Len) when is_integer(Off), Off >= 0, is_integer(Len), Len >= 0 ->
    take(queue:to_list(Chunks), Off, Len).

take(_, _, 0) -> [];
take([], _, _) -> [];
take([Chunk | Rest], Off, Len) when Off >= byte_size(Chunk) ->
    take(Rest, Off - byte_size(Chunk), Len);
take([Chunk | Rest], Off, Len) ->
    N = min(Len, byte_size(Chunk) - Off),
    [binary:part(Chunk, Off, N) | take(Rest, 0, Len - N)].

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
