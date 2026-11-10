%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A stand-in for erx_bytes on stock's emulator, which lacks erXos's erx_bytes BIFs,
%% so host tests of erXos's applications can run code that calls erx_bytes, and the reference
%% model that the C cores and erx_net's portable erx_bytes over them are compared with
%% (test/host/erx_net_bytes_test.rb); erx_net's own host runs load that portable module.
%% Each primitive is a model written from its definition, sharing nothing with the C of the BIFs
%% and NIFs or with the Ruby host tools, and keeps their contract, failing with badarg where
%% erx_bytes does:
%%   * CRC-32C bit by bit: badarg unless Crc is in 0..16#FFFFFFFF and Data a binary of at most
%%     65536 bytes.
%%   * The Internet checksum (RFC 1071) a 16-bit word at a time, folding at the end, and RFC
%%     1624's equation 3 for the update: badarg unless Sum or Checksum is in 0..16#FFFF, Data is
%%     iodata of at most 65536 bytes in lists of at most 131072 cells in all, and Before and
%%     After are binaries of one even size of at most 65536 bytes.
%%   * SipHash-2-4 from the paper, with 64-bit arithmetic masked: badarg unless Key is a 16-byte
%%     binary and Data iodata of at most 65536 bytes in lists of at most 131072 cells in all.
%%   * SHA-256 is stock's crypto:hash/2: badarg unless Data is a binary.
%%   * entropy/1 is stock's crypto:strong_rand_bytes/1, the host's generator: badarg unless N
%%     is an integer from 1 to 256. It never fails a read, so the raise of a failed read is
%%     judged in the release (test/integration/runtime_hosted_smoke_test.rb).
%% Only host tests compile it; it never reaches a release.

-module(erx_bytes).
-export([crc32c/2, inet_csum/2, inet_csum_update/3, siphash24/2, sha256/1, entropy/1]).

-define(CALL_MAX, 65536).
-define(CELLS_MAX, 131072).
-define(MASK64, 16#FFFFFFFFFFFFFFFF).

-spec crc32c(0..16#FFFFFFFF, binary()) -> 0..16#FFFFFFFF.
crc32c(Crc, Data)
  when is_integer(Crc), Crc >= 0, Crc =< 16#FFFFFFFF, is_binary(Data), byte_size(Data) =< ?CALL_MAX ->
    bytes(Data, Crc bxor 16#FFFFFFFF) bxor 16#FFFFFFFF;
crc32c(_Crc, _Data) ->
    erlang:error(badarg).

-spec inet_csum(0..16#FFFF, iodata()) -> 0..16#FFFF.
inet_csum(Sum, Data) when is_integer(Sum), Sum >= 0, Sum =< 16#FFFF ->
    fold(words(call_bytes(Data), Sum));
inet_csum(_Sum, _Data) ->
    erlang:error(badarg).

-spec inet_csum_update(0..16#FFFF, binary(), binary()) -> 0..16#FFFF.
inet_csum_update(Checksum, Before, After)
  when is_integer(Checksum), Checksum >= 0, Checksum =< 16#FFFF, is_binary(Before), is_binary(After),
       byte_size(Before) =:= byte_size(After), byte_size(Before) rem 2 =:= 0,
       byte_size(Before) =< ?CALL_MAX ->
    Total = (bnot Checksum band 16#FFFF) + complements(Before, 0) + words(After, 0),
    bnot fold(Total) band 16#FFFF;
inet_csum_update(_Checksum, _Before, _After) ->
    erlang:error(badarg).

%% The message padded to whole words, zeros and then its length's low byte, every word
%% compressed alike, then 16#FF into V2 and four finishing rounds.
-spec siphash24(<<_:128>>, iodata()) -> 0..?MASK64.
siphash24(<<K0:64/little, K1:64/little>>, Data) ->
    Bytes = call_bytes(Data),
    Padding = (7 - byte_size(Bytes) rem 8) * 8,
    Padded = <<Bytes/binary, 0:Padding, (byte_size(Bytes) band 16#FF)>>,
    {V0, V1, V2, V3} = compress(Padded, {K0 bxor 16#736f6d6570736575, K1 bxor 16#646f72616e646f6d,
                                         K0 bxor 16#6c7967656e657261, K1 bxor 16#7465646279746573}),
    {W0, W1, W2, W3} = rounds(4, {V0, V1, V2 bxor 16#FF, V3}),
    W0 bxor W1 bxor W2 bxor W3;
siphash24(_Key, _Data) ->
    erlang:error(badarg).

-spec sha256(binary()) -> <<_:256>>.
sha256(Data) when is_binary(Data) ->
    crypto:hash(sha256, Data);
sha256(_Data) ->
    erlang:error(badarg).

-spec entropy(1..256) -> binary().
entropy(N) when is_integer(N), N >= 1, N =< 256 ->
    crypto:strong_rand_bytes(N);
entropy(_N) ->
    erlang:error(badarg).

bytes(<<Byte, Rest/binary>>, State) -> bytes(Rest, bits(State bxor Byte, 8));
bytes(<<>>, State) -> State.

bits(State, 0) -> State;
bits(State, N) when State band 1 =:= 1 -> bits((State bsr 1) bxor 16#82F63B78, N - 1);
bits(State, N) -> bits(State bsr 1, N - 1).

%% Data as one binary, badarg unless it is iodata of at most ?CALL_MAX bytes in lists of at
%% most ?CELLS_MAX cells in all.
call_bytes(Data) when is_binary(Data); is_list(Data) ->
    Bytes = iolist_to_binary(Data),
    case byte_size(Bytes) =< ?CALL_MAX andalso cells(Data, 0) =< ?CELLS_MAX of
        true -> Bytes;
        false -> erlang:error(badarg)
    end;
call_bytes(_Data) ->
    erlang:error(badarg).

%% The list cells of the iodata Data, added to N.
cells([Head | Tail], N) -> cells(Tail, cells(Head, N + 1));
cells(_Leaf, N) -> N.

words(<<Word:16, Rest/binary>>, Total) -> words(Rest, Total + Word);
words(<<Byte>>, Total) -> Total + (Byte bsl 8);
words(<<>>, Total) -> Total.

complements(<<Word:16, Rest/binary>>, Total) -> complements(Rest, Total + (bnot Word band 16#FFFF));
complements(<<>>, Total) -> Total.

fold(Total) when Total > 16#FFFF -> fold((Total band 16#FFFF) + (Total bsr 16));
fold(Total) -> Total.

compress(<<M:64/little, Rest/binary>>, {V0, V1, V2, V3}) ->
    {W0, W1, W2, W3} = rounds(2, {V0, V1, V2, V3 bxor M}),
    compress(Rest, {W0 bxor M, W1, W2, W3});
compress(<<>>, V) ->
    V.

%% The paper's SipRound, N times.
rounds(0, V) ->
    V;
rounds(N, {V0, V1, V2, V3}) ->
    A0 = (V0 + V1) band ?MASK64, A1 = rotl(V1, 13) bxor A0, B0 = rotl(A0, 32),
    A2 = (V2 + V3) band ?MASK64, A3 = rotl(V3, 16) bxor A2,
    C0 = (B0 + A3) band ?MASK64, C3 = rotl(A3, 21) bxor C0,
    C2 = (A2 + A1) band ?MASK64, C1 = rotl(A1, 17) bxor C2, D2 = rotl(C2, 32),
    rounds(N - 1, {C0, C1, D2, C3}).

rotl(X, B) -> ((X bsl B) bor (X bsr (64 - B))) band ?MASK64.
