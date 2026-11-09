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

-module(erx_udp).
-moduledoc """
The UDP decisions (docs/design-network-stack.md, "UDP"), translated from `udp_input` and
`udp_common_ctlinput` in FreeBSD's sys/netinet/udp_usrreq.c at the commit NOTICE-freebsd
records. The checksum and length rules of each IP version are erx_udp_wire's; the lookup
of the sockets a datagram names is erx_net_input's, against the demultiplexing table.

`input/3` decides what becomes of a verified datagram given the sockets the lookup found:
a datagram to a unicast address goes to the one socket bound most specifically, one to a
broadcast or multicast address to every socket the lookup found (`udp_multi_input`; the
lookup stops, as FreeBSD's does, at the first socket that does not share its port), and a
datagram that names no socket draws a port unreachable only when it may be answered
(`erx_ip4:reply()` or `erx_ip6:reply()`, which leave out link-layer broadcasts and
multicasts as `udps_noportbcast` and `udps_noportmcast` do), sent with `erx_icmp4:error/4`
or `erx_icmp6:error/4` within the unreachable limit (`udp_blackhole` 0); the same decisions
serve IPv6 datagrams. `report/1` decides whether a reported ICMP or ICMPv6 error
reaches a socket: only one whose errno is not `none`, and only the socket connected to
the quoted destination, which the caller looks up by the full four-tuple, as
`udp_common_ctlinput` does without a wildcard.
""".

-include("erx_icmp4_wire.hrl").
-include("erx_ip6.hrl").

-export([input/3, report/1]).

-export_type([result/1]).

-doc "Deliver to these sockets, answer with a port unreachable, or drop.".
-type result(Socket) :: {deliver, [Socket, ...]} | port_unreach | {drop, no_port}.

-doc """
What `udp_input` does with a datagram to an address of class Cast, which may be answered
as Reply says, for which the lookup found Sockets, most specific first.
""".
-spec input(erx_ip4:cast() | erx_ip6:cast(), erx_ip4:reply() | erx_ip6:reply(), [Socket]) ->
          result(Socket).
input(unicast, _, [Socket | _]) -> {deliver, [Socket]};
input(_, true, []) -> port_unreach;
input(_, _, []) -> {drop, no_port};
input(_, _, Sockets) -> {deliver, Sockets}.

-doc """
The error to notify a connected socket of for a reported ICMPv4 or ICMPv6 error, or
`ignore` (`udp_common_ctlinput` returns when `icmp_errmap` or `icmp6_errmap` gives 0).
""".
-spec report(#icmp4{} | #icmp6{}) -> {notify, erx_icmp4:errno() | erx_icmp6:errno()} | ignore.
report(Icmp) ->
    case errno(Icmp) of
        none -> ignore;
        Errno -> {notify, Errno}
    end.

errno(#icmp4{} = Icmp) -> erx_icmp4:errno(Icmp);
errno(#icmp6{} = Icmp) -> erx_icmp6:errno(Icmp).
