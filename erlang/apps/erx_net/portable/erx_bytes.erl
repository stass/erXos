%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bytes).

-moduledoc """
The per-byte primitives of the network stack outside erXos (docs/design-network-stack.md,
"Two places, four seams"), built only there: the module of the same name in erXos's `erx`
application has them as statically linked NIFs, and this one loads the same C, erx_net's
`c_src/erx_net_bytes.c` over its checksum and SipHash cores, from `priv/erx_bytes_nif.so`,
which `make -C c_src` builds. The checks before each call and the results are those of erXos's
module. A call takes at most 64 KiB, so it stays within a reduction slice on a normal
scheduler; `inet_csum/2` leaves longer inputs to its caller, who passes each result as the
next call's first argument. `inet_csum/2` and `siphash24/2` take iodata, so a header and a
payload are summed or hashed without being joined first.

Without its library the module does not load, and every call, `entropy/1`'s included, fails
with `undef`: nothing in Erlang stands in for the C, so the stack never runs, and is never
measured, on another implementation than the one erXos runs.

`entropy/1` is the host's generator, `crypto:strong_rand_bytes/1`, the one call to `crypto`
in `erx_net`.
""".

-export([inet_csum/2, inet_csum_update/3, siphash24/2, entropy/1]).

-nifs([inet_csum_nif/2, inet_csum_update_nif/3, siphash24_nif/2]).
-on_load(on_load/0).

%% The most bytes one NIF call takes (ERX_NET_BYTES_CALL_MAX in c_src/erx_net_bytes.h).
-define(CALL_MAX, 65536).
%% The most bytes one entropy/1 call returns, as on erXos (entropy_bytes_max of its ABI).
-define(ENTROPY_BYTES_MAX, 256).

%% Loads priv/erx_bytes_nif.so of erx_net. Any other answer than ok leaves the module unloaded,
%% and the code server logs it: {priv_dir, ...} when no erx_net/ebin is on the code path, or
%% load_nif's error when the library is missing or does not load.
-spec on_load() -> ok | {error, term()}.
on_load() ->
    case code:priv_dir(erx_net) of
        {error, Reason} -> {error, {priv_dir, erx_net, Reason}};
        Priv -> erlang:load_nif(filename:join(Priv, "erx_bytes_nif"), 0)
    end.

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
`N` bytes from the host's generator, `crypto:strong_rand_bytes/1`, where erXos reads its
kernel's. Keys, secrets and identifiers an attacker must not guess come from here, through
`erx_net_clock`. Fails with `badarg` unless `N` is an integer from 1 to 256, and with
`crypto`'s own error when the host's generator fails: it never returns fewer bytes, or bytes
from any other source.
""".
-spec entropy(N :: 1..?ENTROPY_BYTES_MAX) -> binary().
entropy(N) when is_integer(N), N >= 1, N =< ?ENTROPY_BYTES_MAX ->
    crypto:strong_rand_bytes(N);
entropy(_N) ->
    erlang:error(badarg).

inet_csum_nif(_Sum, _Data) ->
    erlang:nif_error(undef).

inet_csum_update_nif(_Checksum, _Before, _After) ->
    erlang:nif_error(undef).

siphash24_nif(_Key, _Data) ->
    erlang:nif_error(undef).
