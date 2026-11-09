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
%%
%% FreeBSD: sys/netinet6/udp6_usrreq.c
%% Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project.
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
%% 3. Neither the name of the project nor the names of its contributors
%%    may be used to endorse or promote products derived from this software
%%    without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE PROJECT AND CONTRIBUTORS ``AS IS'' AND
%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%% ARE DISCLAIMED.  IN NO EVENT SHALL THE PROJECT OR CONTRIBUTORS BE LIABLE
%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.
%%
%% $KAME: udp6_usrreq.c,v 1.27 2001/05/21 05:45:10 jinmei Exp $
%% $KAME: udp6_output.c,v 1.31 2001/05/21 16:39:15 jinmei Exp $

-module(erx_udp_wire).
-moduledoc """
The UDP codec (RFC 768) over IPv4 and IPv6, translated from FreeBSD's `udp_input` in
sys/netinet/udp_usrreq.c and `udp6_input` in sys/netinet6/udp6_usrreq.c at the commit
NOTICE-freebsd records (docs/design-network-stack.md, "Packets become checked records once"
and "UDP").

`decode/3` is total over Bytes: it returns `{ok, #udp{}, Payload}` or `{error, Reason}` and
never raises. It makes the checks the two input functions make before their lookup, with the
rules that differ by IP version, so that no protocol code sees an unchecked length:

* the 8-byte header;
* over IPv4, a UDP length from 8 to the bytes delivered, the bytes past it cut off, as
  `udp_input` cuts them; over IPv6, a UDP length equal to the bytes delivered, as
  `udp6_input` requires (RFC 8200, section 8.1);
* over IPv6, a nonzero checksum field, since IPv6 has no datagram without a checksum
  (`udp6_input` with its default `zero_checksum_port` of 0);
* the checksum over the pseudo-header and the datagram, unless an IPv4 datagram carries none
  (a zero checksum field, which RFC 768 allows);
* a destination port other than 0.

One departure, in a counter only: both input functions refuse port 0 before they read the
length and the checksum, and this decoder after them, since the design checks a layer's
checksum before its other fields.

The caller gives the IP version and `PseudoSum`, the partial sum of the pseudo-header over
the length of the bytes it hands the decoder (`erx_ip4_wire:pseudo_sum/4`,
`erx_ip6_wire:pseudo_sum/4`), as for every decoder above IP. Where an IPv4 UDP length is
shorter, `udp_input` sums the pseudo-header with the UDP length, and so does this decoder,
replacing the one length with the other in the sum. Both arguments come from the IP layer,
not the wire: another version, or a sum outside 0..16#ffff, raises.
""".

-include("erx_udp_wire.hrl").

-export([decode/3, encode/3]).

-export_type([family/0, reason/0]).

-doc "The IP version that delivered the datagram.".
-type family() :: inet | inet6.

-doc "Why `decode/3` refused a datagram: a closed set, after FreeBSD's `udpstat` counters.".
-type reason() :: too_short      % udps_hdrops
                | bad_len        % udps_badlen
                | no_sum         % udps_nosum, then dropped over IPv6
                | bad_sum        % udps_badsum
                | bad_port.      % dropped uncounted

-define(UDP_HDR_LEN, 8).
%% The largest UDP length, and the most inet_csum/2 sums in a call (64 KiB).
-define(MAX_DATAGRAM, 16#ffff).

-doc """
Decodes the UDP datagram in Bytes, the payload of its IP packet, with `PseudoSum` the partial
sum of its pseudo-header over `byte_size(Bytes)`. Translates the checks of `udp_input` or
`udp6_input` in their order but for the port (see the module's departure).
""".
-spec decode(family(), 0..16#ffff, binary()) -> {ok, #udp{}, Payload :: binary()} | {error, reason()}.
decode(_, _, Bytes) when not is_binary(Bytes); byte_size(Bytes) < ?UDP_HDR_LEN ->
    {error, too_short};
decode(_, _, Bytes) when byte_size(Bytes) > ?MAX_DATAGRAM ->
    {error, bad_len};
decode(inet6, _, <<_:32, Ulen:16, _/binary>> = Bytes) when Ulen =/= byte_size(Bytes) ->
    {error, bad_len};
decode(inet6, _, <<_:48, 0:16, _/binary>>) ->
    {error, no_sum};
decode(inet6, PseudoSum, Bytes) ->
    checksum(PseudoSum, Bytes);
decode(inet, _, <<_:32, Ulen:16, _/binary>> = Bytes) when Ulen < ?UDP_HDR_LEN; Ulen > byte_size(Bytes) ->
    {error, bad_len};
decode(inet, _, <<Sport:16, Dport:16, Ulen:16, 0:16, Rest/binary>>) ->
    dest_port(#udp{sport = Sport, dport = Dport}, binary:part(Rest, 0, Ulen - ?UDP_HDR_LEN));
decode(inet, PseudoSum, <<_:32, Ulen:16, _/binary>> = Bytes) ->
    <<Datagram:Ulen/binary, _Trailing/binary>> = Bytes,
    checksum(with_length(PseudoSum, byte_size(Bytes), Ulen), Datagram).

%% The pseudo-header's sum with its length Delivered replaced by Ulen: adding the ones'
%% complement of a word subtracts it (RFC 1071), and the length is one 16-bit word of the
%% IPv4 pseudo-header. The result is never 0, since Ulen is at least 8, so the sum over the
%% datagram is 16#ffff exactly when its checksum is right.
with_length(PseudoSum, Delivered, Ulen) ->
    erx_bytes:inet_csum(PseudoSum, <<(16#ffff - Delivered):16, Ulen:16>>).

checksum(PseudoSum, <<Sport:16, Dport:16, _:32, Payload/binary>> = Datagram) ->
    case erx_bytes:inet_csum(PseudoSum, Datagram) of
        16#ffff -> dest_port(#udp{sport = Sport, dport = Dport}, Payload);
        _ -> {error, bad_sum}
    end.

dest_port(#udp{dport = 0}, _) -> {error, bad_port};
dest_port(Udp, Payload) -> {ok, Udp, Payload}.

-doc """
Encodes a datagram carrying Payload, with `PseudoSum` the partial sum of its pseudo-header
over the datagram's length, 8 bytes more than the payload's. The checksum is always sent, as
FreeBSD's default `udp_cksum` sends it, and a computed zero goes out as 16#ffff (RFC 768).
Raises `badarg` for a datagram over 65535 bytes, since the stack encodes only records it
built.
""".
-spec encode(#udp{}, iodata(), 0..16#ffff) -> iodata().
encode(#udp{sport = Sport, dport = Dport}, Payload, PseudoSum) ->
    Len = ?UDP_HDR_LEN + iolist_size(Payload),
    Len =< ?MAX_DATAGRAM orelse erlang:error(badarg),
    Header = <<Sport:16, Dport:16, Len:16>>,
    Computed = bnot erx_bytes:inet_csum(PseudoSum, [Header, <<0:16>>, Payload]) band 16#ffff,
    [Header, <<(nonzero(Computed)):16>>, Payload].

nonzero(0) -> 16#ffff;
nonzero(Sum) -> Sum.
