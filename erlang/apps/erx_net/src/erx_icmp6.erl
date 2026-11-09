%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet6/icmp6.c
%% FreeBSD: sys/netinet6/ip6_input.c
%%
%% Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project.
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
%% Copyright (c) 1982, 1986, 1988, 1993
%%	The Regents of the University of California.  All rights reserved.
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

-module(erx_icmp6).
-moduledoc """
The ICMPv6 decisions (docs/design-network-stack.md, "IPv6, neighbour discovery and
autoconfiguration"), translated from `icmp6_input`, `icmp6_error`, `icmp6_reflect`,
`icmp6_notify_error`, `icmp6_redirect_input`'s checks and `icmp6_errmap` in FreeBSD's
sys/netinet6/icmp6.c at the commit NOTICE-freebsd records. Pure, and shaped as erx_icmp4:
the interface calls `input/6` for each ICMPv6 message erx_icmp6_wire decoded, and
`error/4` for each error it decides to send about a received packet; both return actions
the interface performs and its rate limits advanced (erx_net_bandlim, whose ICMPv6 kinds
are `icmp6_ratelimit`'s: 100 a second each, with a jitter of up to 8).

Whether a datagram may be answered at all is `erx_ip6:input/4`'s one decision, its
`reply()`. Neighbour solicitations, advertisements and router messages are erx_nd6's and
erx_nd6_rtr's; a neighbour-discovery message that came in fragments never gets here
(`erx_ip6:input/4` drops it).

`input/6` answers an echo request within its limit. An error message becomes a report to
the protocol it quotes, which looks up the socket by the quoted addresses and upper-layer
header and maps the error with `errno/1`; a packet too big is reported the same way and
lowers the path MTU of the socket it names, unless its MTU is under the minimum of 1280
bytes, which `icmp6_mtudisc_update` ignores. A redirect that passes
`icmp6_redirect_input`'s checks on the message (a link-local source, a hop limit of 255, a
destination that is not multicast, a target that is link-local or the destination itself,
a target link-layer address, if any, of the interface's length)
becomes a request to the route table, which checks that the sender is the current router
for the destination and applies FreeBSD's rules (`rib_add_redirect`) and its bound on
redirect routes; it carries the target's link-layer address for the neighbour cache when
the message has one.

`error/4` makes `icmp6_error`'s checks on the datagram and builds its message: no error
about a datagram to a multicast address or from an unspecified or multicast one, and
none about an ICMPv6 error message or a redirect, found by `ip6_lasthdr`'s walk of the
datagram's headers; the quote is the datagram up to 1232 bytes (`ICMPV6_PLD_MAXLEN`), so
the error fits the minimum MTU.

Departures. Every error `error/4` sends counts against its kind's limit only once its
other checks pass, as in erx_icmp4. No error is sent about a datagram to a multicast
address at all, where `icmp6_error` sends a packet too big (which a host never sends) and
a parameter problem about an option whose type asks for one. `decode_quoted/1` takes the
quoted destination as the
final one, where `icmp6_notify_error` takes the last address of a type 0 routing header:
the stack sends no routing header, so no quote of its own packet has one. It also requires
8 bytes of the upper-layer header, the ports and for TCP the sequence number, which every
protocol here needs, where FreeBSD leaves that check to each protocol.
""".

-include("erx_ip6.hrl").

-export([input/6, error/4, decode_quoted/1, errno/1]).

-export_type([ctx/0, action/0, quoted/0, kind/0, errno/0]).

-define(IPPROTO_AH, 51).
-define(IP6_HDR_LEN, 40).
-define(UPPER_MIN, 8).
-define(IPV6_MMTU, 1280).
-define(IP6F_OFF_MASK, 16#fff8).
%% ICMPV6_PLD_MAXLEN (netinet/icmp6.h): IPV6_MMTU less the IPv6 and ICMPv6 headers.
-define(PLD_MAXLEN, 1232).
-define(UNSPECIFIED, <<0:128>>).
-define(LOOPBACK, <<1:128>>).

-doc """
What the decisions read from outside: the monotonic time in milliseconds for the rate
limits, and whether the message arrived on the loopback interface, where alone a quoted
loopback address can be genuine (`in6_setscope`).
""".
-type ctx() :: #{now := integer(), loopback := boolean()}.

-doc """
The datagram and the upper-layer header an ICMPv6 error quotes: the protocol that ended
the walk of its headers, its source and destination, and the bytes from that protocol's
header on (at least 8).
""".
-type quoted() :: #{proto := 0..255, src := <<_:128>>, dst := <<_:128>>, upper := binary()}.

-doc """
What the interface does: send an ICMPv6 message (its IPv6 header's fields for
`erx_ip6:output/4`, and the message), report an error to the protocol it quotes, or ask
the route table to apply a redirect for Dst to Target, sent by Router, with the target's
link-layer address when the redirect carries one.
""".
-type action() :: {send, erx_ip6:out(), iodata()}
                | {report, #icmp6{}, quoted()}
                | {redirect, Dst :: <<_:128>>, Target :: <<_:128>>, Router :: <<_:128>>,
                   Lladdr :: binary() | none}.

-doc """
An error `error/4` sends: destination unreachable with its code, a parameter problem with
its code and pointer, or time exceeded with its code (1 for reassembly).
""".
-type kind() :: {unreach, 0..6}
              | {param_problem, 0..3, Pointer :: 0..16#ffffffff}
              | {time_exceeded, 0..1}.

-doc "The error a report means to a socket, `icmp6_errmap`'s errno, or `none` to ignore it.".
-type errno() :: ehostunreach | econnrefused | enoprotoopt | emsgsize | none.

-doc """
The decisions `icmp6_input` makes on a decoded message Icmp with Rest the bytes after its
fixed fields, carried by datagram Ip which may be answered as Reply says
(`erx_ip6:input/4`).
""".
-spec input(#ip6{}, erx_ip6:reply(), #icmp6{}, binary(), ctx(), erx_net_bandlim:lim()) ->
          {[action()], erx_net_bandlim:lim()}.
input(#ip6{src = Src, dst = Dst}, true, #icmp6{type = ?ICMP6_ECHO_REQUEST, msg = {echo, Id, Seq}},
      Rest, #{now := Now}, Lim0) ->
    case erx_net_bandlim:check(icmp6_echo, Now, Lim0) of
        {allow, Lim} ->
            Reply = #icmp6{type = ?ICMP6_ECHO_REPLY, code = 0, msg = {echo, Id, Seq}},
            Out = #{src => Dst, dst => Src, proto => ?IPPROTO_ICMPV6},
            {[{send, Out, erx_icmp6_wire:encode(Reply, Rest, {Dst, Src})}], Lim};
        {deny, Lim} ->
            {[], Lim}
    end;
input(Ip, _, #icmp6{type = ?ND_REDIRECT, msg = {redirect, Target, Dst, Opts}}, _, _, Lim) ->
    {redirect(Ip, Target, Dst, Opts), Lim};
input(_, _, #icmp6{type = ?ICMP6_PACKET_TOO_BIG, msg = {error, Mtu}}, _, _, Lim) when Mtu < ?IPV6_MMTU ->
    {[], Lim};
input(_, _, #icmp6{msg = {error, _}} = Icmp, Rest, #{loopback := Loopback}, Lim) ->
    case decode_quoted(Rest) of
        {ok, #{src := Src, dst := Dst} = Quoted} when Loopback; Src =/= ?LOOPBACK, Dst =/= ?LOOPBACK ->
            {[{report, Icmp, Quoted}], Lim};
        _ ->
            {[], Lim}
    end;
input(_, _, _, _, _, Lim) ->
    {[], Lim}.

%% icmp6_redirect_input's checks on the message alone; the route table makes the one that
%% needs it, that Router is the current router for Dst. A target link-layer address must
%% have the interface's length, an Ethernet address, as erx_nd6 requires of its options.
redirect(#ip6{src = Router, hlim = Hlim}, Target, Dst, Opts) ->
    Lladdr = maps:get(tlla, Opts, none),
    Valid = erx_net_addr:is_link_local(Router)
        andalso (Lladdr =:= none orelse byte_size(Lladdr) =:= 6)
        andalso Hlim =:= 255
        andalso not erx_net_addr:is_multicast(Dst)
        andalso Target =/= ?LOOPBACK andalso Dst =/= ?LOOPBACK
        andalso (erx_net_addr:is_link_local(Target) orelse Target =:= Dst),
    case Valid of
        true -> [{redirect, Dst, Target, Router, Lladdr}];
        false -> []
    end.

-doc """
The ICMPv6 error of kind Kind about Packet, the received bytes of a datagram that
`erx_ip6:input/4` found may be answered, or nothing where `icmp6_error` sends nothing or
the limit is reached. The error is sent from the datagram's destination to its source.
""".
-spec error(kind(), binary(), ctx(), erx_net_bandlim:lim()) -> {[action()], erx_net_bandlim:lim()}.
error(Kind, Packet, #{now := Now}, Lim0) ->
    maybe
        {ok, Src, Dst, Quote} ?= quote(Packet),
        {allow, Lim} ?= erx_net_bandlim:check(limit(Kind), Now, Lim0),
        Out = #{src => Dst, dst => Src, proto => ?IPPROTO_ICMPV6},
        {[{send, Out, erx_icmp6_wire:encode(message(Kind), Quote, {Dst, Src})}], Lim}
    else
        {deny, Lim1} -> {[], Lim1};
        refused -> {[], Lim0}
    end.

message({unreach, Code}) -> #icmp6{type = ?ICMP6_DST_UNREACH, code = Code, msg = {error, 0}};
message({param_problem, Code, Pointer}) -> #icmp6{type = ?ICMP6_PARAM_PROB, code = Code, msg = {error, Pointer}};
message({time_exceeded, Code}) -> #icmp6{type = ?ICMP6_TIME_EXCEEDED, code = Code, msg = {error, 0}}.

limit({unreach, _}) -> icmp6_unreach;
limit({param_problem, _, _}) -> icmp6_param_prob;
limit({time_exceeded, _}) -> icmp6_time_exceeded.

%% icmp6_error's checks on the datagram, its bytes cut at its payload length as FreeBSD's
%% mbuf is: a fixed header present, a destination that is not multicast and a source
%% that is neither unspecified nor multicast, and no ICMPv6 error message or redirect
%% inside. reply() covers the addresses of a datagram input/4 delivered; they are checked
%% here too because a fragment that reassembly gives up on comes back without a reply(),
%% and one sent to a multicast group must not make every host on the link answer.
quote(<<_:32, Plen:16, Nxt, _, Src:16/binary, Dst:16/binary, _/binary>> = Packet0) ->
    Packet = binary:part(Packet0, 0, min(byte_size(Packet0), ?IP6_HDR_LEN + Plen)),
    Refused = erx_net_addr:is_multicast(Dst) orelse Dst =:= ?UNSPECIFIED
        orelse Src =:= ?UNSPECIFIED orelse erx_net_addr:is_multicast(Src)
        orelse not_to_answer(last_header(Nxt, ?IP6_HDR_LEN, Packet), Packet),
    case Refused of
        true -> refused;
        false -> {ok, Src, Dst, binary:part(Packet, 0, min(?PLD_MAXLEN, byte_size(Packet)))}
    end;
quote(_) ->
    refused.

%% Whether the walk of quote/1 ended at a header icmp6_error refuses to answer: an ICMPv6
%% error message or a redirect, or an ICMPv6 header cut short, which FreeBSD's m_pullup of
%% it refuses. A walk that runs off the datagram before any ICMPv6 header finds none,
%% and the error is sent, as icmp6_error sends it when ip6_lasthdr fails.
not_to_answer({?IPPROTO_ICMPV6, Off}, Packet) when Off + ?UPPER_MIN > byte_size(Packet) ->
    true;
not_to_answer({?IPPROTO_ICMPV6, Off}, Packet) ->
    Type = binary:at(Packet, Off),
    Type < ?ICMP6_ECHO_REQUEST orelse Type =:= ?ND_REDIRECT;
not_to_answer(_, _) ->
    false.

%% The walk of icmp6_notify_error and ip6_lasthdr from the header named Nxt at offset Off:
%% past hop-by-hop, destination options, routing and authentication headers, and a
%% fragment header with offset zero; it stops at any other header, or at a fragment header
%% with a nonzero offset, whose upper layer is not in the packet. Returns the protocol it
%% stopped at and its offset, or `truncated` when a header runs past Packet. Each step
%% advances at least 8 bytes, so the walk ends.
last_header(Nxt, Off, Packet) when Nxt =:= ?IPPROTO_HOPOPTS; Nxt =:= ?IPPROTO_DSTOPTS;
                                   Nxt =:= ?IPPROTO_ROUTING ->
    case Packet of
        <<_:Off/binary, Next, Len, _/binary>> -> last_header(Next, Off + (Len + 1) * 8, Packet);
        _ -> truncated
    end;
last_header(?IPPROTO_AH, Off, Packet) ->
    case Packet of
        <<_:Off/binary, Next, Len, _/binary>> -> last_header(Next, Off + (Len + 2) * 4, Packet);
        _ -> truncated
    end;
last_header(?IPPROTO_FRAGMENT, Off, Packet) ->
    case Packet of
        <<_:Off/binary, _, _, OffLg:16, _:32, _/binary>> when OffLg band ?IP6F_OFF_MASK =/= 0 ->
            {?IPPROTO_FRAGMENT, Off};
        <<_:Off/binary, Next, _, _:16, _:32, _/binary>> ->
            last_header(Next, Off + 8, Packet);
        _ -> truncated
    end;
last_header(Nxt, Off, _) ->
    {Nxt, Off}.

-doc """
The quoted datagram of an ICMPv6 error message, Invoking being the bytes after its fixed
fields: `icmp6_notify_error`'s walk of the quoted headers to the upper layer, with every
header it passes inside the quote and 8 bytes of the upper-layer header after them, and
neither quoted address unspecified. Total over binaries: it never raises. Invoking is
untrusted input, a datagram the sender of the error claims to have received from us.
""".
-spec decode_quoted(binary()) -> {ok, quoted()} | {error, bad_length | bad_addr}.
decode_quoted(<<_:48, Nxt, _, Src:16/binary, Dst:16/binary, _/binary>> = Invoking) ->
    case last_header(Nxt, ?IP6_HDR_LEN, Invoking) of
        {_, Off} when Off + ?UPPER_MIN > byte_size(Invoking) ->
            {error, bad_length};
        {_, _} when Src =:= ?UNSPECIFIED; Dst =:= ?UNSPECIFIED ->
            {error, bad_addr};
        {Proto, Off} ->
            <<_:Off/binary, Upper/binary>> = Invoking,
            {ok, #{proto => Proto, src => Src, dst => Dst, upper => Upper}};
        truncated ->
            {error, bad_length}
    end;
decode_quoted(_) ->
    {error, bad_length}.

-doc "The error a socket sees for a reported ICMPv6 error, `icmp6_errmap`'s mapping.".
-spec errno(#icmp6{}) -> errno().
errno(#icmp6{type = ?ICMP6_DST_UNREACH, code = Code}) ->
    if
        Code =:= 0; Code =:= 3 -> ehostunreach;
        Code =:= 1; Code =:= 4 -> econnrefused;
        Code =:= 2 -> enoprotoopt;
        true -> none
    end;
errno(#icmp6{type = ?ICMP6_PACKET_TOO_BIG}) -> emsgsize;
errno(#icmp6{type = ?ICMP6_TIME_EXCEEDED, code = 0}) -> ehostunreach;
errno(#icmp6{type = ?ICMP6_PARAM_PROB, code = ?ICMP6_PARAMPROB_NEXTHEADER}) -> econnrefused;
errno(#icmp6{type = ?ICMP6_PARAM_PROB, code = Code})
  when Code =:= ?ICMP6_PARAMPROB_HEADER; Code =:= ?ICMP6_PARAMPROB_OPTION -> enoprotoopt;
errno(_) -> none.
