%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_genet_rx).
-moduledoc """
The Raspberry Pi 4 Ethernet controller's receive decision as a pure function
(docs/design-platforms.md, "Raspberry Pi 4 Model B"): what one receive
completion of the device NIF means. It reads no register and copies nothing;
the NIF walks the ring, moves the consumer index and copies each buffer, and
`frame/2` judges what it handed up.

A completion is the NIF's `{Flags, Bytes}` (docs/design-device-dma.md, "The
register ring (GENET)"). `Flags` are the descriptor status word's bits below
its length field, bits 15:0. `Bytes` are the bytes the controller wrote, as
many as the length field, bits 31:16 (FreeBSD masks 12 of them), said. The length is the size of `Bytes`
and nothing else, so no length can disagree with the bytes behind it or wrap
into the flags. Both are untrusted device data. The length counts the two bytes
of padding the controller writes before the frame so that the IP header lands
aligned; the frame is the bytes after them, a sub-binary of `Bytes`, which are
the NIF's own copy and never memory the controller may write again.

A completion whose flags carry any of the error bits 0 to 4, or lack the start
or end of packet, is dropped with its reason, as is one shorter than the
padding and an Ethernet header, or longer than a 2 KiB receive buffer. The NIF
refuses a longer length before it copies anything, so the last drop is a check
of its contract, not a case the controller can reach.

Facts from FreeBSD 975e3605ebb1, `sys/arm64/broadcom/genet/`: the status bits
(`if_genetreg.h:169-176`; bits 0, 1, 3 and 4 from the GENET facts record,
docs/research-genet-bcm2711.md, "The receive status word", whose rule of
dropping on any of them the design takes), the 2 KiB buffer
(`if_genet.c:790-792`, `MCLBYTES` in `sys/sys/param.h:196-199`), and the
padding, turned on by `GENET_RBUF_ALIGN_2B` and counted in the length
(`if_genet.c:521-524, 1440-1443`).
""".

-export([frame/2]).
-export_type([flags/0, drop/0, result/0]).

-include("generated/erx_hw_genet.hrl").

-define(BUFFER_BYTES, 2048).
%% The largest flags word: every status bit below the length field.
-define(FLAGS_MAX, ((1 bsl ?ERX_HW_GENET_RX_DESC_STATUS_BUFLEN_SHIFT) - 1)).
%% The padding before the frame, counted in the length field.
-define(PAD, 2).
-define(ETHER_HDR_LEN, 14).
%% The status word's bits, RX_DESC_STATUS's fields in hw/svd/genet/genet.svd.
-define(STATUS_EOP, ?ERX_HW_GENET_RX_DESC_STATUS_EOP_MASK).
-define(STATUS_SOP, ?ERX_HW_GENET_RX_DESC_STATUS_SOP_MASK).
%% The error bits, lowest first, each with the reason it drops a frame.
-define(STATUS_ERRORS, [{?ERX_HW_GENET_RX_DESC_STATUS_OVERFLOW_MASK, overflow},
                        {?ERX_HW_GENET_RX_DESC_STATUS_CRC_ERROR_MASK, crc_error},
                        {?ERX_HW_GENET_RX_DESC_STATUS_RX_ERROR_MASK, rx_error},
                        {?ERX_HW_GENET_RX_DESC_STATUS_NON_OCTET_MASK, non_octet},
                        {?ERX_HW_GENET_RX_DESC_STATUS_LENGTH_ERROR_MASK, length_error}]).
-define(STATUS_ERROR_MASK, (?ERX_HW_GENET_RX_DESC_STATUS_OVERFLOW_MASK bor
                            ?ERX_HW_GENET_RX_DESC_STATUS_CRC_ERROR_MASK bor
                            ?ERX_HW_GENET_RX_DESC_STATUS_RX_ERROR_MASK bor
                            ?ERX_HW_GENET_RX_DESC_STATUS_NON_OCTET_MASK bor
                            ?ERX_HW_GENET_RX_DESC_STATUS_LENGTH_ERROR_MASK)).

-doc "A receive completion's flags: the descriptor status bits below its length field.".
-type flags() :: 0..?FLAGS_MAX.
-doc """
Why a completion carried no frame: the lowest error bit set, `overflow` (bit
0), `crc_error` (1), `rx_error` (2, the controller's receive-error bit),
`non_octet` (3) or `length_error` (4); `fragment`, the start or end of packet
missing; `runt`, fewer bytes than the padding and an Ethernet header;
`too_long`, more bytes than a receive buffer holds.
""".
-type drop() :: overflow | crc_error | rx_error | non_octet | length_error | fragment | runt | too_long.
-type result() :: {frame, binary()} | {drop, drop()}.

-doc """
One receive completion: its flags and the bytes the controller wrote, the
padding first. A frame is a sub-binary of `Bytes`, at most 2,046 bytes long.
""".
-spec frame(flags(), binary()) -> result().
frame(Flags, Bytes) when is_integer(Flags), Flags >= 0, Flags =< ?FLAGS_MAX, is_binary(Bytes) ->
    if
        Flags band ?STATUS_ERROR_MASK =/= 0 -> {drop, error_reason(Flags)};
        Flags band ?STATUS_SOP =:= 0 -> {drop, fragment};
        Flags band ?STATUS_EOP =:= 0 -> {drop, fragment};
        byte_size(Bytes) < ?PAD + ?ETHER_HDR_LEN -> {drop, runt};
        byte_size(Bytes) > ?BUFFER_BYTES -> {drop, too_long};
        true -> {frame, binary:part(Bytes, ?PAD, byte_size(Bytes) - ?PAD)}
    end.

error_reason(Flags) ->
    hd([Reason || {Bit, Reason} <- ?STATUS_ERRORS, Flags band Bit =/= 0]).
