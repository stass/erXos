%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bytes).

-moduledoc """
The per-byte primitives (docs/design-runtime.md, "Per-byte primitives"): the work done once
per byte is C, statically linked NIFs behind these calls. A NIF call takes at most 64 KiB, so
it stays within a reduction slice. `crc32c/2` leaves longer inputs to its caller, who passes
each result as the next call's first argument; the SHA-256 calls take a binary of any size and
stream it to their NIF 64 KiB at a time themselves.
""".

-export([crc32c/2, sha256/1, sha256_init/0, sha256_update/2, sha256_final/1]).
-export_type([sha256_state/0]).

-nifs([crc32c_nif/2, sha256_nif/1, sha256_init_nif/0, sha256_update_nif/2, sha256_final_nif/1]).
-on_load(on_load/0).

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

crc32c_nif(_Crc, _Data) ->
    erlang:nif_error(undef).

sha256_nif(_Data) ->
    erlang:nif_error(undef).

sha256_init_nif() ->
    erlang:nif_error(undef).

sha256_update_nif(_State, _Data) ->
    erlang:nif_error(undef).

sha256_final_nif(_State) ->
    erlang:nif_error(undef).
