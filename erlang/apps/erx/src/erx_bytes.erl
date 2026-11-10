%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bytes).

-moduledoc """
The per-byte primitives (docs/design-runtime.md, "Per-byte primitives"): the work done once
per byte is C, BIFs of erXos's ERTS (`otp/erts/emulator/nifs/erxos/erx_bytes_bif.c`), each of
which checks its own arguments; the functions here stand for them. A call takes at most
64 KiB, so it stays within a reduction slice, and is charged reductions for its work.
`crc32c/2` and `inet_csum/2` leave longer inputs to their caller, who passes each result as
the next call's first argument; the SHA-256 calls take a binary of any size, and
`sha256_update/2` takes it 64 KiB at a time, so the process is preempted between pieces like
a loop of calls. `inet_csum/2` and `siphash24/2` take iodata and walk it in C, so a header
and a payload are summed or hashed without being joined first. `entropy/1`, beside them, is
Erlang's entry to the kernel's generator.
""".

-export([crc32c/2, inet_csum/2, inet_csum_update/3, siphash24/2, tcp_merge/1, tcp_merge_limit/0, entropy/1]).
-export([sha256/1, sha256_init/0, sha256_update/2, sha256_final/1]).
-export_type([sha256_state/0]).

-include("generated/erx_abi.hrl").

-doc """
A SHA-256 digest in progress: the bytes given so far. A state is a value: `sha256_update/2`
and `sha256_final/1` leave the state they are given as it was, so one state may be extended
in several ways or finished more than once. A state lives only in the runtime that made it:
sent to another domain or node, it is not a state there.
""".
-opaque sha256_state() :: reference().

-doc """
CRC-32C (Castagnoli, as RFC 3720 uses it) of `Data`, continuing from `Crc`, the value of the
bytes before it (0 for none). `crc32c(crc32c(0, A), B)` is `crc32c(0, <<A/binary, B/binary>>)`.
Fails with `badarg` unless `Crc` is in `0..16#FFFFFFFF` and `Data` is a binary of at most
65536 bytes.
""".
-spec crc32c(Crc :: 0..16#FFFFFFFF, Data :: binary()) -> 0..16#FFFFFFFF.
crc32c(_Crc, _Data) ->
    erlang:nif_error(undef).

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
inet_csum(_Sum, _Data) ->
    erlang:nif_error(undef).

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
inet_csum_update(_Checksum, _Before, _After) ->
    erlang:nif_error(undef).

-doc """
SipHash-2-4 (Aumasson and Bernstein, 2012) of `Data`'s bytes under the 16-byte `Key`, as the
64-bit integer whose little-endian bytes are the paper's output. Fails with `badarg` unless
`Key` is a 16-byte binary and `Data` is iodata of at most 65536 bytes, in lists of at most
131072 cells in all.
""".
-spec siphash24(Key :: <<_:128>>, Data :: iodata()) -> 0..16#FFFFFFFFFFFFFFFF.
siphash24(_Key, _Data) ->
    erlang:nif_error(undef).

-doc """
The merge of one batch of received Ethernet frames, FreeBSD's large receive offload rule
(docs/design-network-fastpath.md, "The merge"): each frame is a binary, or `{sum, Sum, Frame}`
with `Sum` the network sum its transport's copy computed, the sum of its bytes after the
Ethernet header. In-order TCP segments of one flow whose checksums are right become one unit
`{merged, N, First, Last, Payload}`: its `N` frames' first and last, each as `{sum, Sum,
Frame}`, and each member's payload, a sub-binary of its frame, in order, with the empty
payloads of the pure ACKs it holds left out. Every other frame is `{sum, Sum, Frame}`, the
term it came as when it came with its sum. Each unit stands where its first frame stood, so a
flow's frames keep their order. The merge only groups: it writes no header, and every value
TCP acts on is decoded again from the frames. A sum is believed as the copy's, as FreeBSD
believes a device's checksum verdict. Fails with `badarg` unless `Frames` is a proper list
within `tcp_merge_limit/0`, and no frame holds more than its byte limit.
""".
-spec tcp_merge(Frames :: [binary() | {sum, 0..16#FFFF, binary()}]) ->
          [{sum, 0..16#FFFF, binary()}
           | {merged, 2..256, {sum, 0..16#FFFF, binary()}, {sum, 0..16#FFFF, binary()}, [binary()]}].
tcp_merge(_Frames) ->
    erlang:nif_error(undef).

-doc """
The merge's limit, `{Frames, Bytes}`: a batch of `tcp_merge/1` holds at most `Frames` frames,
the frames before its last hold fewer than `Bytes` bytes in all, and no frame more than
`Bytes`. The answer is the C core's own two constants.
""".
-spec tcp_merge_limit() -> {pos_integer(), pos_integer()}.
tcp_merge_limit() ->
    erlang:nif_error(undef).

-doc """
The SHA-256 digest (FIPS 180-4) of `Data`, 32 bytes, the same as
`crypto:hash(sha256, Data)`. Fails with `badarg` unless `Data` is a binary.
""".
-spec sha256(Data :: binary()) -> <<_:256>>.
sha256(Data) ->
    sha256_final(sha256_update(sha256_init(), Data)).

-doc "The SHA-256 state of no bytes.".
-spec sha256_init() -> sha256_state().
sha256_init() ->
    erlang:nif_error(undef).

-doc """
The state of `State`'s bytes followed by `Data`. Fails with `badarg` unless `State` is a
SHA-256 state and `Data` a binary.
""".
-spec sha256_update(State :: sha256_state(), Data :: binary()) -> sha256_state().
sha256_update(_State, _Data) ->
    erlang:nif_error(undef).

-doc """
The SHA-256 digest of `State`'s bytes, 32 bytes. Fails with `badarg` unless `State` is a
SHA-256 state.
""".
-spec sha256_final(State :: sha256_state()) -> <<_:256>>.
sha256_final(_State) ->
    erlang:nif_error(undef).

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
entropy(_N) ->
    erlang:nif_error(undef).
