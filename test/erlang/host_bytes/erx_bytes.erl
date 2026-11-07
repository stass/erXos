%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A stand-in for erx_bytes on stock's emulator, which lacks erXos's statically linked NIFs,
%% so host tests can run code that calls erx_bytes:crc32c/2 or erx_bytes:sha256/1. It computes
%% CRC-32C bit by bit, sharing nothing with the NIF's tables or with the Ruby host tool's, and
%% keeps the NIF's contract: badarg unless Crc is in 0..16#FFFFFFFF and Data a binary of at
%% most 65536 bytes. SHA-256 is stock's crypto:hash/2, badarg unless Data is a binary.
%% Only host tests compile it; it never reaches a release.

-module(erx_bytes).
-export([crc32c/2, sha256/1]).

-spec crc32c(0..16#FFFFFFFF, binary()) -> 0..16#FFFFFFFF.
crc32c(Crc, Data)
  when is_integer(Crc), Crc >= 0, Crc =< 16#FFFFFFFF, is_binary(Data), byte_size(Data) =< 65536 ->
    bytes(Data, Crc bxor 16#FFFFFFFF) bxor 16#FFFFFFFF;
crc32c(_Crc, _Data) ->
    erlang:error(badarg).

-spec sha256(binary()) -> <<_:256>>.
sha256(Data) when is_binary(Data) ->
    crypto:hash(sha256, Data);
sha256(_Data) ->
    erlang:error(badarg).

bytes(<<Byte, Rest/binary>>, State) -> bytes(Rest, bits(State bxor Byte, 8));
bytes(<<>>, State) -> State.

bits(State, 0) -> State;
bits(State, N) when State band 1 =:= 1 -> bits((State bsr 1) bxor 16#82F63B78, N - 1);
bits(State, N) -> bits(State bsr 1, N - 1).
