%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_genet_rx).
-moduledoc """
The Raspberry Pi 4 Ethernet controller's receive side as pure decisions
(docs/design-platforms.md, "Raspberry Pi 4 Model B"): what a receive
descriptor's status word and the bytes read from its buffer mean, and how far
the consumer index moves. It reads no register and copies nothing the caller
did not hand it; the transport reads the producer index, each descriptor's
status and its buffer, and writes back the consumer index this module returns.
The bytes it hands over are its own copy, never memory the controller may
write again, since a frame is a sub-binary of them and keeps them alive.

Every descriptor holds one buffer of `buffer_bytes/0` (2 KiB), so a frame the
controller accepted, at most 1,536 bytes, never spans two. The status word is
untrusted device data. Its length field, bits 27:16, counts the two bytes of
padding the controller writes before the frame so that the IP header lands
aligned; the frame is the bytes after them. A descriptor whose status carries
the receive-error bit, lacks the start or end of packet, or whose length is
shorter than the padding and an Ethernet header, longer than the buffer or
longer than the bytes read is dropped with its reason. Either way the
descriptor is consumed: `batch/2` moves the consumer index by one for every
descriptor it is handed, frame or drop, so a bad frame never holds up the
ring.

Facts from FreeBSD 975e3605ebb1, `sys/arm64/broadcom/genet/`: the status bits
(`if_genetreg.h:169-176`), the 256-descriptor ring and its 16-bit free-running
indexes (`if_genetreg.h:116, 131`; `if_genet.c:1384-1388`), the 2 KiB buffer
(`if_genet.c:790-792`, `MCLBYTES` in `sys/sys/param.h:196-199`), and the padding, turned on by `GENET_RBUF_ALIGN_2B`
and counted in the length (`if_genet.c:521-524, 1440-1443`). FreeBSD's error
path leaves its index and the consumer index where they were
(`if_genet.c:1406-1416`); this module consumes the descriptor instead.
""".

-export([buffer_bytes/0, ring_size/0]).
-export([frame/2, batch/2, pending/2, slot/1]).
-export_type([status/0, index/0, drop/0, result/0]).

-define(BUFFER_BYTES, 2048).
-define(RING_SIZE, 256).
-define(INDEX_MASK, 16#ffff).
%% The padding before the frame, counted in the length field.
-define(PAD, 2).
-define(ETHER_HDR_LEN, 14).
-define(STATUS_EOP, 16#4000).
-define(STATUS_SOP, 16#2000).
-define(STATUS_RX_ERROR, 16#0004).
-define(BUFLEN_SHIFT, 16).
-define(BUFLEN_MASK, 16#fff).

-define(IS_U32(V), (is_integer(V) andalso V >= 0 andalso V =< 16#ffffffff)).

-doc "A receive descriptor's status word, as the controller wrote it.".
-type status() :: 0..16#ffffffff.
-doc "A producer or consumer index: 16 bits, free-running past the ring's size.".
-type index() :: 0..16#ffff.
-doc """
Why a descriptor carried no frame: `rx_error`, the controller's receive-error
bit; `fragment`, the start or end of packet missing; `runt`, a length shorter
than the padding and an Ethernet header; `too_long`, a length past the
buffer; `truncated`, a length past the bytes the caller read.
""".
-type drop() :: rx_error | fragment | runt | too_long | truncated.
-type result() :: {frame, binary()} | {drop, drop()}.

-doc "The bytes of each descriptor's buffer.".
-spec buffer_bytes() -> pos_integer().
buffer_bytes() -> ?BUFFER_BYTES.

-doc "The descriptors of the receive ring.".
-spec ring_size() -> pos_integer().
ring_size() -> ?RING_SIZE.

-doc """
One descriptor: its status word and the bytes read from its buffer, from the
buffer's start. A frame is a sub-binary of `Bytes`, at most
`buffer_bytes() - 2` long.
""".
-spec frame(status(), binary()) -> result().
frame(Status, Bytes) when ?IS_U32(Status), is_binary(Bytes) ->
    Length = (Status bsr ?BUFLEN_SHIFT) band ?BUFLEN_MASK,
    if
        Status band ?STATUS_RX_ERROR =/= 0 -> {drop, rx_error};
        Status band ?STATUS_SOP =:= 0 -> {drop, fragment};
        Status band ?STATUS_EOP =:= 0 -> {drop, fragment};
        Length < ?PAD + ?ETHER_HDR_LEN -> {drop, runt};
        Length > ?BUFFER_BYTES -> {drop, too_long};
        Length > byte_size(Bytes) -> {drop, truncated};
        true -> {frame, binary:part(Bytes, ?PAD, Length - ?PAD)}
    end.

-doc """
The descriptors from consumer index `Cons` on, in ring order, each a status
word and the bytes read from its buffer: the consumer index after all of
them, the frames in order and the drops in order. The index moves by one per
descriptor whatever it carried.
""".
-spec batch(index(), [{status(), binary()}]) -> {index(), [binary()], [drop()]}.
batch(Cons, Descriptors) when is_integer(Cons), Cons >= 0, Cons =< ?INDEX_MASK,
                              length(Descriptors) =< ?RING_SIZE ->
    Results = lists:map(fun({Status, Bytes}) -> frame(Status, Bytes) end, Descriptors),
    Next = (Cons + length(Descriptors)) band ?INDEX_MASK,
    {Next, [Frame || {frame, Frame} <- Results], [Drop || {drop, Drop} <- Results]}.

-doc """
How many descriptors the controller has filled, from the producer index it
reports (only its low 16 bits count) and the consumer index last written. More
than the ring holds is a controller fault, refused.
""".
-spec pending(0..16#ffffffff, index()) ->
          {ok, 0..?RING_SIZE} | {error, {overrun, non_neg_integer()}}.
pending(Prod, Cons) when ?IS_U32(Prod), is_integer(Cons), Cons >= 0,
                         Cons =< ?INDEX_MASK ->
    case (Prod - Cons) band ?INDEX_MASK of
        Filled when Filled =< ?RING_SIZE -> {ok, Filled};
        Filled -> {error, {overrun, Filled}}
    end.

-doc "The descriptor a consumer or producer index names.".
-spec slot(index()) -> 0..(?RING_SIZE - 1).
slot(Index) when is_integer(Index), Index >= 0, Index =< ?INDEX_MASK ->
    Index band (?RING_SIZE - 1).
