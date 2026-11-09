%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/net/if_ethersubr.c
%% Copyright (c) 1982, 1989, 1993
%% The Regents of the University of California.  All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%% 3. Neither the name of the University nor the names of its contributors
%%    may be used to endorse or promote products derived from this software
%%    without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%% ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.

-module(erx_net_eth).
-moduledoc """
The Ethernet II codec (docs/design-network-stack.md, "Packets become checked records
once"). `decode/1` is the first decoder of a received frame, whose device header the driver
has already stripped; `encode/1` writes the header of a frame to send. The check is the one
`ether_input_internal` makes before reading the header, translated from FreeBSD's
`sys/net/if_ethersubr.c` at commit 975e3605 (erlang/apps/erx_net/NOTICE-freebsd).

What the addresses and the EtherType mean (broadcast, multicast, which protocol) is the
classifier's decision, not the codec's: any EtherType decodes, and 802.3 length fields and
VLAN tags arrive as EtherTypes the classifier does not act on.
""".

-include("erx_net_eth.hrl").

-export([decode/1, encode/1]).

-export_type([error_reason/0]).

-define(ETHER_HDR_LEN, 14).

-doc "Why a frame is refused: too short to hold the header.".
-type error_reason() :: too_short.

-doc """
The header of Frame and the payload behind it, or `too_short` for a frame of fewer than
14 bytes, as `ether_input_internal` drops a frame whose first mbuf is shorter than
`ETHER_HDR_LEN`. Total over binaries: it never raises.
""".
-spec decode(binary()) -> {ok, #eth{}, Payload :: binary()} | {error, error_reason()}.
decode(<<Dst:6/binary, Src:6/binary, Type:16, Payload/binary>>) ->
    {ok, #eth{dst = Dst, src = Src, type = Type}, Payload};
decode(Frame) when is_binary(Frame), byte_size(Frame) < ?ETHER_HDR_LEN ->
    {error, too_short}.

-doc "The 14-byte header of Eth, the inverse of `decode/1`.".
-spec encode(#eth{}) -> <<_:112>>.
encode(#eth{dst = <<_:48>> = Dst, src = <<_:48>> = Src, type = Type})
  when is_integer(Type), Type >= 0, Type =< 16#FFFF ->
    <<Dst/binary, Src/binary, Type:16>>.
