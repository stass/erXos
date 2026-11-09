%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/ip_input.c
%% Copyright (c) 1982, 1986, 1988, 1993
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
%%
%% FreeBSD: sys/netinet/ip_options.c
%% Copyright (c) 1982, 1986, 1988, 1993
%%      The Regents of the University of California.
%% Copyright (c) 2005 Andre Oppermann, Internet Business Solutions AG.
%% All rights reserved.
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

-module(erx_ip4_wire).
-moduledoc """
The IPv4 codec (docs/design-network-stack.md, "Packets become checked records once" and
"IPv4 and ARP"). `decode/1` takes the payload of an Ethernet frame of type IP, or a
reassembled datagram, and makes the checks `ip_input` makes before it reads a packet:
version, header length, header checksum and total length, cutting the trailing bytes at the
total length; then it walks the options as `ip_dooptions` does, checking each one's length.
`encode/1` writes a header to send. Translated from FreeBSD's
`sys/netinet/ip_input.c` and `sys/netinet/ip_options.c` at commit 95719d8a
(erlang/apps/erx_net/NOTICE-freebsd).

Two departures. The first changes only which counter a refused packet lands in, with
nothing on the wire changed: The header checksum is checked before any field but the version and header length
(the design's "Packets become checked records once"); `ip_input` reads the addresses first,
for its loopback check, which is `erx_ip4`'s here. The second: `ip_dooptions` answers a
malformed option with a parameter problem pointing at its length byte. This codec refuses
the packet with that pointer, `{bad_options, Pointer}`, so that `erx_ip4`, after its own
loopback check as in `ip_input`, can answer as FreeBSD does; whether it does is the
design's decision (docs/design-network-stack.md, "IPv4 and ARP").
""".

-include("erx_ip4_wire.hrl").

-export([decode/1, encode/1, options/1, pseudo_sum/4]).

-export_type([error_reason/0, option/0]).

-define(IPVERSION, 4).
%% sizeof(struct ip): the header without options.
-define(IP_HDR_LEN, 20).
-define(MAX_OPTIONS_LEN, 40).
%% Whether X fits an unsigned field of Bits bits, so that encoding never truncates a value.
-define(UINT(X, Bits), (is_integer(X) andalso X >= 0 andalso X < (1 bsl Bits))).

-doc """
Why a packet is refused, named after the `ipstat` counter `ip_input` raises for it:
`too_short` for fewer than 20 bytes or fewer than the total length, `bad_vers` for a version
other than 4, `bad_hlen` for a header length below 20 or beyond the packet, `bad_sum` for a
wrong header checksum, `bad_len` for a total length below the header length, and
`{bad_options, Pointer}` for an option whose length is missing, below 2 or past the
header, Pointer being the offset in the header of that length byte, the code
`ip_dooptions` gives its parameter problem.
""".
-type error_reason() :: too_short | bad_vers | bad_hlen | bad_sum | bad_len
                      | {bad_options, Pointer :: 21..60}.

-doc "An option other than NOP and EOL: its type and the bytes after its length byte.".
-type option() :: {Type :: 0..255, Data :: binary()}.

-doc """
The header of Packet and its payload, cut at the total length, or why it is refused. The
checks run in `ip_input`'s order but for the checksum, which comes right after the header
length (see the module's departures): the fixed header present, the version, the header
length, the checksum, the total length against the header and then against the packet, and
last the options. Total over binaries: it never raises.
""".
-spec decode(binary()) -> {ok, #ip4{}, Payload :: binary()} | {error, error_reason()}.
decode(Packet) when is_binary(Packet), byte_size(Packet) < ?IP_HDR_LEN ->
    {error, too_short};
decode(<<?IPVERSION:4, Hl:4, _/binary>> = Packet) ->
    header(Hl * 4, Packet);
decode(Packet) when is_binary(Packet) ->
    {error, bad_vers}.

%% The header length checks and the checksum, over the header alone (`in_cksum_hdr`).
header(Hlen, _Packet) when Hlen < ?IP_HDR_LEN ->
    {error, bad_hlen};
header(Hlen, Packet) when Hlen > byte_size(Packet) ->
    {error, bad_hlen};
header(Hlen, Packet) ->
    <<Header:Hlen/binary, Rest/binary>> = Packet,
    case erx_bytes:inet_csum(0, Header) of
        16#FFFF -> fields(Hlen, Header, Rest);
        _ -> {error, bad_sum}
    end.

fields(Hlen, <<_:8, Tos:8, Len:16, Id:16, Rf:1, Df:1, Mf:1, Off:13, Ttl:8, P:8, _Sum:16,
         Src:4/binary, Dst:4/binary, Options/binary>>, Rest) ->
    maybe
        true ?= Len >= Hlen orelse {error, bad_len},
        {ok, Payload} ?= payload(Rest, Len - Hlen),
        {ok, _} ?= walk(Options, ?IP_HDR_LEN, []),
        {ok, #ip4{tos = Tos, len = Len, id = Id, rf = Rf, df = Df, mf = Mf, off = Off, ttl = Ttl, p = P,
                  src = Src, dst = Dst, options = Options}, Payload}
    end.

%% The datagram's payload: the bytes after the header up to the total length, the rest (an
%% Ethernet frame's padding) cut off, or `too_short` when the packet ends before it.
payload(Rest, Length) when Length =< byte_size(Rest) -> {ok, binary:part(Rest, 0, Length)};
payload(_Rest, _Length) -> {error, too_short}.

-doc """
The options of a decoded header in order, without NOPs and stopping at EOL. Total on a
decoded header, whose options `decode/1` has walked.
""".
-spec options(#ip4{}) -> [option()].
options(#ip4{options = Options}) ->
    {ok, List} = walk(Options, ?IP_HDR_LEN, []),
    List.

%% The walk of `ip_dooptions`: EOL ends the options, NOP is one byte, and any other option
%% has a length byte of at least 2 that does not run past the header. At is the offset in
%% the header of the option in hand.
walk(<<>>, _At, Acc) ->
    {ok, lists:reverse(Acc)};
walk(<<?IPOPT_EOL, _/binary>>, _At, Acc) ->
    {ok, lists:reverse(Acc)};
walk(<<?IPOPT_NOP, Rest/binary>>, At, Acc) ->
    walk(Rest, At + 1, Acc);
walk(<<Type, Len, Rest/binary>>, At, Acc) when Len >= 2, Len - 2 =< byte_size(Rest) ->
    DataLength = Len - 2,
    <<Data:DataLength/binary, More/binary>> = Rest,
    walk(More, At + Len, [{Type, Data} | Acc]);
walk(_Options, At, _Acc) ->
    {error, {bad_options, At + 1}}.

-doc """
The header of Ip4 with its checksum, the inverse of `decode/1`: decoding the header followed
by `len` minus the header length bytes of payload gives Ip4 back. Ip4's options must be a
multiple of four bytes, at most 40, that walk as `decode/1` requires, and `len` at least the
header length; each other field fits its width.
""".
-spec encode(#ip4{}) -> binary().
encode(#ip4{tos = Tos, len = Len, id = Id, rf = Rf, df = Df, mf = Mf, off = Off, ttl = Ttl, p = P,
            src = <<_:32>> = Src, dst = <<_:32>> = Dst, options = Options})
  when ?UINT(Tos, 8), ?UINT(Len, 16), ?UINT(Id, 16), ?UINT(Rf, 1), ?UINT(Df, 1), ?UINT(Mf, 1),
       ?UINT(Off, 13), ?UINT(Ttl, 8), ?UINT(P, 8), is_binary(Options),
       byte_size(Options) rem 4 =:= 0, byte_size(Options) =< ?MAX_OPTIONS_LEN,
       Len >= ?IP_HDR_LEN + byte_size(Options) ->
    {ok, _} = walk(Options, ?IP_HDR_LEN, []),
    Hl = (?IP_HDR_LEN + byte_size(Options)) div 4,
    Head = <<?IPVERSION:4, Hl:4, Tos:8, Len:16, Id:16, Rf:1, Df:1, Mf:1, Off:13, Ttl:8, P:8>>,
    Tail = <<Src/binary, Dst/binary, Options/binary>>,
    Sum = bnot erx_bytes:inet_csum(0, [Head, Tail]) band 16#FFFF,
    <<Head/binary, Sum:16, Tail/binary>>.

-doc """
The partial Internet checksum of the pseudo-header that the upper layer's checksum covers
(RFC 768; RFC 9293, section 3.1): source and destination address, a zero byte, the protocol
and the upper-layer length, for `erx_bytes:inet_csum/2` to continue over the upper layer.
""".
-spec pseudo_sum(<<_:32>>, <<_:32>>, 0..16#FFFF, 0..255) -> 0..16#FFFF.
pseudo_sum(<<_:32>> = Src, <<_:32>> = Dst, Len, P) when ?UINT(Len, 16), ?UINT(P, 8) ->
    erx_bytes:inet_csum(0, <<Src/binary, Dst/binary, 0, P, Len:16>>).
