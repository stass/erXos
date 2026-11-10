%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bytes).

-moduledoc """
The per-byte primitives of the network stack outside erXos (docs/design-network-stack.md,
"Two places, four seams"), built only there: the module of the same name in erXos's `erx`
application has them as BIFs of erXos's ERTS, and this one loads the same C, erx_net's
`c_src/erx_bytes_nif.c` over its checksum and SipHash cores and its iodata walk, from
`priv/erx_bytes_nif.so`, which `make -C c_src` builds. Each of `inet_csum/2`,
`inet_csum_update/3` and `siphash24/2` calls a NIF that checks its arguments, as each BIF
does: the iodata through the walk both share, the other arguments by checks of its own that
the shared probe judges against erXos's. The NIF API copies a binary that starts at a bit
offset whole before its size is known, so each function first refuses, in Erlang and
without a copy, any argument of more than twice the walk's limits, which bounds both that
copy and the work of sizing it; within those bounds every refusal is the NIF's. A call
takes at most 64 KiB, so it stays within a reduction slice on a normal scheduler;
`inet_csum/2` leaves longer inputs
to its caller, who passes each result as the next call's first argument. `inet_csum/2` and
`siphash24/2` take iodata and walk it in C, so a header and a payload are summed or hashed
without being joined first.

Without its library the module does not load, and every call, `entropy/1`'s included, fails
with `undef`: nothing in Erlang stands in for the C, so the stack never runs, and is never
measured, on another implementation than the one erXos runs.

`entropy/1` is the host's generator, `crypto:strong_rand_bytes/1`, the one call to `crypto`
in `erx_net`.
""".

-export([inet_csum/2, inet_csum_update/3, siphash24/2, entropy/1]).

-nifs([inet_csum_nif/2, inet_csum_update_nif/3, siphash24_nif/2]).
-on_load(on_load/0).

%% The most bytes one entropy/1 call returns, as on erXos (entropy_bytes_max of its ABI).
-define(ENTROPY_BYTES_MAX, 256).

%% The most bytes one call takes and the most list cells one walk visits, ERX_BYTES_CALL_MAX
%% and ERX_IODATA_CELLS_MAX of c_src/erx_iodata.h; the library refuses to load unless they
%% are its own.
-define(CALL_MAX, 65536).
-define(CELLS_MAX, 131072).

%% Loads priv/erx_bytes_nif.so of erx_net. Any other answer than ok leaves the module unloaded,
%% and the code server logs it: {priv_dir, ...} when no erx_net/ebin is on the code path, or
%% load_nif's error when the library is missing, does not load or has other limits.
-spec on_load() -> ok | {error, term()}.
on_load() ->
    case code:priv_dir(erx_net) of
        {error, Reason} -> {error, {priv_dir, erx_net, Reason}};
        Priv -> erlang:load_nif(filename:join(Priv, "erx_bytes_nif"), {?CALL_MAX, ?CELLS_MAX})
    end.

-doc """
The Internet checksum sum (RFC 1071) of `Data`'s bytes, continuing from `Sum`, the sum of the
bytes before them (0 for none), which must be of even length, as every header is. The sum is
the one's-complement sum of the bytes as 16-bit big-endian words, a last odd byte padded with
a zero byte, folded to 16 bits. A checksum field holds its complement,
`bnot Sum band 16#FFFF`, so the sum of bytes that include a right field is `16#FFFF`.
`inet_csum(inet_csum(0, A), B)` is `inet_csum(0, [A, B])` when `A` is of even length. Fails
with `badarg` unless `Sum` is in `0..16#FFFF` and `Data` is iodata of at most 65536 bytes,
in lists of at most 131072 cells in all.
""".
-spec inet_csum(Sum :: 0..16#FFFF, Data :: iodata()) -> 0..16#FFFF.
inet_csum(Sum, Data) ->
    iodata_fits(Data) orelse erlang:error(badarg),
    inet_csum_nif(Sum, Data).

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
inet_csum_update(Checksum, Before, After) ->
    (binary_fits(Before) andalso binary_fits(After)) orelse erlang:error(badarg),
    inet_csum_update_nif(Checksum, Before, After).

-doc """
SipHash-2-4 (Aumasson and Bernstein, 2012) of `Data`'s bytes under the 16-byte `Key`, as the
64-bit integer whose little-endian bytes are the paper's output. Fails with `badarg` unless
`Key` is a 16-byte binary and `Data` is iodata of at most 65536 bytes, in lists of at most
131072 cells in all.
""".
-spec siphash24(Key :: <<_:128>>, Data :: iodata()) -> 0..16#FFFFFFFFFFFFFFFF.
siphash24(Key, Data) ->
    (binary_fits(Key) andalso iodata_fits(Data)) orelse erlang:error(badarg),
    siphash24_nif(Key, Data).

%% The checks below only bound what a NIF is handed; they never decide a refusal the NIF or
%% its walk would not also make. Their bounds are twice the walk's limits, so every limit is
%% the C's alone, and its tests judge it.
-define(FITS_BYTES, 2 * ?CALL_MAX).
-define(FITS_CELLS, 2 * ?CELLS_MAX).

%% False when Term is a binary of more than ?FITS_BYTES bytes; true otherwise. byte_size/1
%% copies nothing.
-spec binary_fits(term()) -> boolean().
binary_fits(Term) ->
    not is_binary(Term) orelse byte_size(Term) =< ?FITS_BYTES.

%% False when Term is a binary of more than ?FITS_BYTES bytes, or a list whose binaries hold
%% more than ?FITS_BYTES bytes or that has more than ?FITS_CELLS cells; true otherwise. It
%% walks the list as the walk does, sharing walked again, skips every term but a list or a
%% binary, copies nothing, and stops past either bound, so it visits at most ?FITS_CELLS + 1
%% cells.
-spec iodata_fits(term()) -> boolean().
iodata_fits(Term) when is_list(Term) ->
    iodata_fits(Term, [], 0, 0);
iodata_fits(Term) ->
    binary_fits(Term).

%% Walks Term, then each term of Rest; Bytes and Cells are those seen before Term.
iodata_fits(_Term, _Rest, Bytes, Cells) when Bytes > ?FITS_BYTES; Cells > ?FITS_CELLS ->
    false;
iodata_fits([Head | Tail], Rest, Bytes, Cells) ->
    iodata_fits(Head, [Tail | Rest], Bytes, Cells + 1);
iodata_fits(Term, Rest, Bytes, Cells) when is_binary(Term) ->
    fits_rest(Rest, Bytes + byte_size(Term), Cells);
iodata_fits(_Term, Rest, Bytes, Cells) ->
    fits_rest(Rest, Bytes, Cells).

fits_rest([], Bytes, Cells) ->
    Bytes =< ?FITS_BYTES andalso Cells =< ?FITS_CELLS;
fits_rest([Next | Rest], Bytes, Cells) ->
    iodata_fits(Next, Rest, Bytes, Cells).

%% The NIFs of c_src/erx_bytes_nif.c, which replace these stubs as the module loads.
inet_csum_nif(_Sum, _Data) ->
    erlang:nif_error(undef).

inet_csum_update_nif(_Checksum, _Before, _After) ->
    erlang:nif_error(undef).

siphash24_nif(_Key, _Data) ->
    erlang:nif_error(undef).

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
