%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bytes).

-moduledoc """
The per-byte primitives (docs/design-runtime.md, "Per-byte primitives"): the work done once
per byte is C, statically linked NIFs behind these calls. A NIF call takes at most 64 KiB, so
it stays within a reduction slice. `crc32c/2` and `inet_csum/2` leave longer inputs to their
caller, who passes each result as the next call's first argument; the SHA-256 calls take a
binary of any size and stream it to their NIF 64 KiB at a time themselves. `inet_csum/2` and
`siphash24/2` take iodata, so a header and a payload are summed or hashed without being
joined first. `entropy/1`, beside them, is Erlang's entry to the kernel's generator.
""".

-export([crc32c/2, inet_csum/2, inet_csum_update/3, siphash24/2, entropy/1]).
-export([sha256/1, sha256_init/0, sha256_update/2, sha256_final/1]).
-export_type([sha256_state/0]).

-nifs([crc32c_nif/2, inet_csum_nif/2, inet_csum_update_nif/3, siphash24_nif/2, entropy_nif/1]).
-nifs([sha256_nif/1, sha256_init_nif/0, sha256_update_nif/2, sha256_final_nif/1]).
-on_load(on_load/0).

-include("generated/erx_abi.hrl").

%% The most bytes one NIF call takes (ERX_BYTES_CALL_MAX in erx_bytes_nif.c).
-define(CALL_MAX, 65536).

-doc """
A SHA-256 digest in progress: the bytes given so far. A state is a value: `sha256_update/2`
and `sha256_final/1` leave the state they are given as it was, so one state may be extended
in several ways or finished more than once. A state lives in the runtime that made it: it
cannot be stored, or sent to another domain or node, and used there.
""".
-opaque sha256_state() :: reference().

-spec on_load() -> ok | {error, term()}.
on_load() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

-doc """
CRC-32C (Castagnoli, as RFC 3720 uses it) of `Data`, continuing from `Crc`, the value of the
bytes before it (0 for none). `crc32c(crc32c(0, A), B)` is `crc32c(0, <<A/binary, B/binary>>)`.
The size is checked here, before the NIF can copy a misaligned binary. Fails with `badarg`
unless `Crc` is in `0..16#FFFFFFFF` and `Data` is a binary of at most 65536 bytes.
""".
-spec crc32c(Crc :: 0..16#FFFFFFFF, Data :: binary()) -> 0..16#FFFFFFFF.
crc32c(Crc, Data)
  when is_integer(Crc), Crc >= 0, Crc =< 16#FFFFFFFF, is_binary(Data),
       byte_size(Data) =< ?CALL_MAX ->
    crc32c_nif(Crc, Data);
crc32c(_Crc, _Data) ->
    erlang:error(badarg).

-doc """
The Internet checksum sum (RFC 1071) of `Data`'s bytes, continuing from `Sum`, the sum of the
bytes before them (0 for none), which must be of even length, as every header is. The sum is
the one's-complement sum of the bytes as 16-bit big-endian words, a last odd byte padded with
a zero byte, folded to 16 bits. A checksum field holds its complement,
`bnot Sum band 16#FFFF`, so the sum of bytes that include a right field is `16#FFFF`.
`inet_csum(inet_csum(0, A), B)` is `inet_csum(0, [A, B])` when `A` is of even length. Fails
with `badarg` unless `Sum` is in `0..16#FFFF` and `Data` is iodata of at most 65536 bytes.
""".
-spec inet_csum(Sum :: 0..16#FFFF, Data :: iodata()) -> 0..16#FFFF.
inet_csum(Sum, Data)
  when is_integer(Sum), Sum >= 0, Sum =< 16#FFFF, is_binary(Data), byte_size(Data) =< ?CALL_MAX ->
    inet_csum_nif(Sum, Data);
inet_csum(Sum, Data) when is_integer(Sum), Sum >= 0, Sum =< 16#FFFF, is_list(Data) ->
    inet_csum_nif(Sum, call_iovec(Data));
inet_csum(_Sum, _Data) ->
    erlang:error(badarg).

-doc """
RFC 1624's incremental update, its equation 3: the checksum field that replaces `Checksum`
when the bytes `Before`, at an even offset of what the checksum covers, become the bytes
`After`. When `Checksum` was right, the result is the field a full recomputation gives,
except that for a non-empty `Before` it is `0` where that is `16#FFFF`, the other zero of
one's-complement arithmetic, which a full recomputation gives only when every covered byte is
zero; a wrong `Checksum` stays wrong by the same amount. UDP sends a computed `0` as `16#FFFF`
(RFC 768), since there `0` means no checksum; that is the caller's rule, for this result as
for a full recomputation. Fails with `badarg` unless `Checksum` is in
`0..16#FFFF` and `Before` and `After` are binaries of one even size of at most 65536 bytes.
""".
-spec inet_csum_update(Checksum :: 0..16#FFFF, Before :: binary(), After :: binary()) -> 0..16#FFFF.
inet_csum_update(Checksum, Before, After)
  when is_integer(Checksum), Checksum >= 0, Checksum =< 16#FFFF, is_binary(Before), is_binary(After),
       byte_size(Before) =:= byte_size(After), byte_size(Before) rem 2 =:= 0,
       byte_size(Before) =< ?CALL_MAX ->
    inet_csum_update_nif(Checksum, Before, After);
inet_csum_update(_Checksum, _Before, _After) ->
    erlang:error(badarg).

-doc """
SipHash-2-4 (Aumasson and Bernstein, 2012) of `Data`'s bytes under the 16-byte `Key`, as the
64-bit integer whose little-endian bytes are the paper's output. Fails with `badarg` unless
`Key` is a 16-byte binary and `Data` is iodata of at most 65536 bytes.
""".
-spec siphash24(Key :: <<_:128>>, Data :: iodata()) -> 0..16#FFFFFFFFFFFFFFFF.
siphash24(Key, Data)
  when is_binary(Key), byte_size(Key) =:= 16, is_binary(Data), byte_size(Data) =< ?CALL_MAX ->
    siphash24_nif(Key, Data);
siphash24(Key, Data) when is_binary(Key), byte_size(Key) =:= 16, is_list(Data) ->
    siphash24_nif(Key, call_iovec(Data));
siphash24(_Key, _Data) ->
    erlang:error(badarg).

%% The iolist Data as a list of binaries for a NIF call: badarg unless it is an iolist of at
%% most ?CALL_MAX bytes. The size is checked before erlang:iolist_to_iovec/1 joins anything.
%% That call keeps large binaries as they are, joins small ones and drops empty ones, so the
%% NIF sees few pieces, each byte-aligned.
call_iovec(Data) ->
    case iolist_size(Data) of
        Size when Size =< ?CALL_MAX -> erlang:iolist_to_iovec(Data);
        _ -> erlang:error(badarg)
    end.

-doc """
The SHA-256 digest (FIPS 180-4) of `Data`, 32 bytes, the same as
`crypto:hash(sha256, Data)`. Fails with `badarg` unless `Data` is a binary.
""".
-spec sha256(Data :: binary()) -> <<_:256>>.
sha256(Data) when is_binary(Data), byte_size(Data) =< ?CALL_MAX ->
    sha256_nif(Data);
sha256(Data) when is_binary(Data) ->
    sha256_final(sha256_update(sha256_init(), Data));
sha256(_Data) ->
    erlang:error(badarg).

-doc "The SHA-256 state of no bytes.".
-spec sha256_init() -> sha256_state().
sha256_init() ->
    sha256_init_nif().

-doc """
The state of `State`'s bytes followed by `Data`. Fails with `badarg` unless `State` is a
SHA-256 state and `Data` a binary.
""".
-spec sha256_update(State :: sha256_state(), Data :: binary()) -> sha256_state().
sha256_update(State, Data) when is_binary(Data), byte_size(Data) =< ?CALL_MAX ->
    sha256_update_nif(State, Data);
%% Rest/binary matches whole bytes only, so a long bitstring falls to badarg before any NIF call.
sha256_update(State, <<Chunk:?CALL_MAX/binary, Rest/binary>>) ->
    sha256_update(sha256_update_nif(State, Chunk), Rest);
sha256_update(_State, _Data) ->
    erlang:error(badarg).

-doc """
The SHA-256 digest of `State`'s bytes, 32 bytes. Fails with `badarg` unless `State` is a
SHA-256 state.
""".
-spec sha256_final(State :: sha256_state()) -> <<_:256>>.
sha256_final(State) ->
    sha256_final_nif(State).

-doc """
`N` bytes from the kernel's generator, read by one `erx_entropy_read` (docs/design-runtime.md,
"Per-byte primitives", the entropy entry). Keys, secrets and identifiers an attacker must not
guess come from here, directly or through a generator keyed from here, never from `rand`. It
is a synchronous kernel call, on the stopgap a request to the root's generator service. Fails
with `badarg` unless `N` is an integer from 1 to 256, and with `{entropy, Status}`, `Status`
the ABI file's name of the status the read returned (its integer for a value no status
names), when the read fails: it never returns fewer bytes, or bytes from any other source.
""".
-spec entropy(N :: 1..?ERX_ENTROPY_BYTES_MAX) -> binary().
entropy(N) when is_integer(N), N >= 1, N =< ?ERX_ENTROPY_BYTES_MAX ->
    entropy_nif(N);
entropy(_N) ->
    erlang:error(badarg).

crc32c_nif(_Crc, _Data) ->
    erlang:nif_error(undef).

inet_csum_nif(_Sum, _Data) ->
    erlang:nif_error(undef).

inet_csum_update_nif(_Checksum, _Before, _After) ->
    erlang:nif_error(undef).

siphash24_nif(_Key, _Data) ->
    erlang:nif_error(undef).

entropy_nif(_N) ->
    erlang:nif_error(undef).

sha256_nif(_Data) ->
    erlang:nif_error(undef).

sha256_init_nif() ->
    erlang:nif_error(undef).

sha256_update_nif(_State, _Data) ->
    erlang:nif_error(undef).

sha256_final_nif(_State) ->
    erlang:nif_error(undef).
