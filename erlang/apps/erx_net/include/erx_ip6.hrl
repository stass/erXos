%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The IPv6 and ICMPv6 records that erx_ip6_wire and erx_icmp6_wire decode,
%% and the protocol numbers the stack compares them with (RFC 8200, RFC 4443,
%% RFC 4861; the names are FreeBSD's, from netinet/in.h and netinet/icmp6.h,
%% but for ICMP6_PARAMPROB_FIRSTFRAG, RFC 7112's code 3, which FreeBSD lacks).

-ifndef(ERX_IP6_HRL).
-define(ERX_IP6_HRL, true).

%% Next-header values (IANA "Assigned Internet Protocol Numbers").
-define(IPPROTO_HOPOPTS, 0).
-define(IPPROTO_TCP, 6).
-define(IPPROTO_UDP, 17).
-define(IPPROTO_ROUTING, 43).
-define(IPPROTO_FRAGMENT, 44).
-define(IPPROTO_ICMPV6, 58).
-define(IPPROTO_NONE, 59).
-define(IPPROTO_DSTOPTS, 60).

%% ICMPv6 message types.
-define(ICMP6_DST_UNREACH, 1).
-define(ICMP6_PACKET_TOO_BIG, 2).
-define(ICMP6_TIME_EXCEEDED, 3).
-define(ICMP6_PARAM_PROB, 4).
-define(ICMP6_ECHO_REQUEST, 128).
-define(ICMP6_ECHO_REPLY, 129).
-define(ND_ROUTER_SOLICIT, 133).
-define(ND_ROUTER_ADVERT, 134).
-define(ND_NEIGHBOR_SOLICIT, 135).
-define(ND_NEIGHBOR_ADVERT, 136).
-define(ND_REDIRECT, 137).

%% Parameter problem codes (RFC 4443, RFC 7112).
-define(ICMP6_PARAMPROB_HEADER, 0).
-define(ICMP6_PARAMPROB_NEXTHEADER, 1).
-define(ICMP6_PARAMPROB_OPTION, 2).
-define(ICMP6_PARAMPROB_FIRSTFRAG, 3).

%% A received IPv6 packet's headers, as erx_ip6_wire:decode/1 returns them.
%% `exthdrs' are the extension headers the walk passed, in wire order.
%% `fragment' is `none', or the offset, more-fragments flag and
%% identification of the fragment header that ended the walk because the
%% packet is a fragment that is not atomic: then `proto' is that header's
%% next header and the payload is fragment data, not the upper layer.
%% `proto' is the next-header value that ended the walk, `proto_ptr' the offset
%% from the start of the fixed header of the byte that names it, and
%% `hdrlen' the bytes of extension headers the walk passed. The payload after
%% them is the decoder's Rest.
-record(ip6, {
    tclass :: 0..255,
    flow :: 0..16#fffff,
    hlim :: 0..255,
    src :: <<_:128>>,
    dst :: <<_:128>>,
    exthdrs = [] :: [erx_ip6_wire:exthdr()],
    fragment = none :: none | {Offset :: 0..16#fff8, More :: boolean(), Id :: 0..16#ffffffff},
    proto :: 0..255,
    proto_ptr = 6 :: non_neg_integer(),
    hdrlen = 0 :: non_neg_integer()
}).

%% A received ICMPv6 message, as erx_icmp6_wire:decode/2 returns it; `msg'
%% holds the fields of its type (erx_icmp6_wire:msg()).
-record(icmp6, {
    type :: 0..255,
    code :: 0..255,
    msg :: erx_icmp6_wire:msg()
}).

-endif.
