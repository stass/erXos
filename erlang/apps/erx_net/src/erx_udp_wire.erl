%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/udp_usrreq.c
%% Copyright (c) 1982, 1986, 1988, 1990, 1993, 1995
%% The Regents of the University of California.
%% Copyright (c) 2008 Robert N. M. Watson
%% Copyright (c) 2010-2011 Juniper Networks, Inc.
%% Copyright (c) 2014 Kevin Lo
%% All rights reserved.
%%
%% Portions of this software were developed by Robert N. M. Watson under
%% contract to Juniper Networks, Inc.
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

-module(erx_udp_wire).
-moduledoc """
The UDP codec (RFC 768), for IPv4 and IPv6 alike, translated from FreeBSD's `udp_input` in
sys/netinet/udp_usrreq.c at the commit NOTICE-freebsd records
(docs/design-network-stack.md, "Packets become checked records once" and "UDP").

`decode/2` is total: it returns `{ok, #udp{}, Payload}` or `{error, Reason}` and never
raises. It makes the checks `udp_input` makes before its lookup: the 8-byte header; a UDP
length of at least 8 and at most the bytes the IP layer delivered, the bytes past it cut off;
the checksum over the pseudo-header and the datagram, unless the checksum field is zero; and
a destination port other than 0. One departure, in a counter only: `udp_input` refuses
port 0 before it reads the length and the checksum, and this decoder after them, since the
design checks a layer's checksum before its other fields.

The caller gives `PseudoSum`, the partial sum of the pseudo-header over the length of the
bytes it hands the decoder (`erx_ip4_wire:pseudo_sum/4`, `erx_ip6_wire:pseudo_sum/4`), as for
every decoder above IP. Where the UDP length is shorter, which IPv4 allows, `udp_input` sums
the pseudo-header with the UDP length, and so does this decoder, replacing the one length
with the other in the sum.

The rules that differ by IP version are erx_udp's (docs/design-network-stack.md, "UDP"):
over IPv6, `udp6_input` refuses a datagram without a checksum (`csum = absent`) and one
whose UDP length is not the payload length the IPv6 header gives, which a payload shorter
than that length minus 8 shows. `udp6_input` counts the second as a bad length before it
sums; here a datagram with a wrong checksum is refused as `bad_sum` first, a departure in a
counter only.

`decode/2` is total over Bytes. `PseudoSum` comes from the IP layer, not the wire; one
outside 0..16#ffff raises `badarg`.
""".

-include("erx_udp_wire.hrl").

-export([decode/2, encode/3]).

-export_type([reason/0]).

-doc "Why `decode/2` refused a datagram: a closed set, after FreeBSD's `udpstat` counters.".
-type reason() :: too_short      % udps_hdrops
                | bad_len        % udps_badlen
                | bad_sum        % udps_badsum
                | bad_port.      % dropped uncounted by udp_input

-define(UDP_HDR_LEN, 8).
%% The largest UDP length, and the most inet_csum/2 sums in a call (64 KiB).
-define(MAX_DATAGRAM, 16#ffff).

-doc """
Decodes the UDP datagram in Bytes, the payload of its IP packet, with `PseudoSum` the
partial sum of its pseudo-header over `byte_size(Bytes)`. Translates `udp_input`'s checks in
its order but for the port (see the module's departure).
""".
-spec decode(0..16#ffff, binary()) -> {ok, #udp{}, Payload :: binary()} | {error, reason()}.
decode(_, Bytes) when not is_binary(Bytes); byte_size(Bytes) < ?UDP_HDR_LEN ->
    {error, too_short};
decode(_, Bytes) when byte_size(Bytes) > ?MAX_DATAGRAM ->
    {error, bad_len};
decode(_, <<_:32, Ulen:16, _/binary>> = Bytes) when Ulen < ?UDP_HDR_LEN; Ulen > byte_size(Bytes) ->
    {error, bad_len};
decode(PseudoSum, <<_:32, Ulen:16, _/binary>> = Bytes) ->
    <<Datagram:Ulen/binary, _Trailing/binary>> = Bytes,
    checksum(with_length(PseudoSum, byte_size(Bytes), Ulen), Datagram).

%% The pseudo-header's sum with its length Delivered replaced by Ulen: adding the ones'
%% complement of a word subtracts it (RFC 1071), and the length is one 16-bit word of the
%% pseudo-header of either IP version. The result is never 0, since Ulen is at least 8, so
%% the sum over the datagram is 16#ffff exactly when its checksum is right.
with_length(PseudoSum, Delivered, Ulen) ->
    erx_bytes:inet_csum(PseudoSum, <<(16#ffff - Delivered):16, Ulen:16>>).

checksum(_, <<Sport:16, Dport:16, _:16, 0:16, Payload/binary>>) ->
    dest_port(#udp{sport = Sport, dport = Dport, csum = absent}, Payload);
checksum(PseudoSum, <<Sport:16, Dport:16, _:32, Payload/binary>> = Datagram) ->
    case erx_bytes:inet_csum(PseudoSum, Datagram) of
        16#ffff -> dest_port(#udp{sport = Sport, dport = Dport}, Payload);
        _ -> {error, bad_sum}
    end.

dest_port(#udp{dport = 0}, _) -> {error, bad_port};
dest_port(Udp, Payload) -> {ok, Udp, Payload}.

-doc """
Encodes a datagram carrying Payload, with `PseudoSum` the partial sum of its pseudo-header
over the datagram's length, 8 bytes more than the payload's. A computed checksum of zero is
sent as 16#ffff (RFC 768); `csum = absent` writes zero. Raises `badarg` for a datagram over
65535 bytes, since the stack encodes only records it built.
""".
-spec encode(#udp{}, iodata(), 0..16#ffff) -> iodata().
encode(#udp{sport = Sport, dport = Dport, csum = Csum}, Payload, PseudoSum) ->
    Len = ?UDP_HDR_LEN + iolist_size(Payload),
    Len =< ?MAX_DATAGRAM orelse erlang:error(badarg),
    Header = <<Sport:16, Dport:16, Len:16>>,
    Sum = case Csum of
              absent -> 0;
              checked ->
                  Computed = bnot erx_bytes:inet_csum(PseudoSum, [Header, <<0:16>>, Payload]) band 16#ffff,
                  nonzero(Computed)
          end,
    [Header, <<Sum:16>>, Payload].

nonzero(0) -> 16#ffff;
nonzero(Sum) -> Sum.
