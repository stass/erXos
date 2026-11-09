%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/ip_icmp.c
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

-module(erx_icmp4).
-moduledoc """
The ICMPv4 decisions (docs/design-network-stack.md, "IPv4 and ARP"), translated from
`icmp_input`, `icmp_error`, `icmp_reflect` and `icmp_errmap` in FreeBSD's
sys/netinet/ip_icmp.c at the commit NOTICE-freebsd records. Pure: the interface calls
`input/6` for each ICMP message erx_net_input verified, and `error/4` for each error it
decides to send about a received packet; both return actions the interface performs and
its rate limits advanced (erx_net_bandlim).

Whether a datagram may be answered at all is `erx_ip4:input/3`'s one decision, its
`reply()`: addressed to one of the stack's addresses, in a unicast frame, from a source
`icmp_reflect` and `ip_output` would answer. So nothing here answers a broadcast or
multicast (`icmpbmcastecho` 0) or a source that cannot be answered.

`input/6` answers echo and timestamp requests (`icmptstamprepl` 1) within their rate
limits; it does not answer address mask requests (`icmpmaskrepl` 0). An error message
becomes a report to the protocol it quotes, which looks up the socket by the quoted
addresses and ports and maps the error with `errno/1`; a redirect becomes a request to
the route table, which applies FreeBSD's rules for accepting it (`rib_add_redirect`) and
its bound on redirect routes.

`error/4` makes `icmp_error`'s checks on the datagram and builds its message: no error
about a fragment other than the first or an ICMP error message; the quote holds the
header and up to 548 bytes after it (`icmp_quotelen`), at least 8, within the datagram's
total length.

Departures. Replies carry no IP options, where `icmp_reflect` gives an echo reply the
request's record-route and timestamp options (the design's "IPv4 and ARP"). Every error
`error/4` sends passes the unreachable limit, where FreeBSD limits only the unreachable
messages `udp_input` and `rip_input` send; the interface answers nothing else. An error
counts against the limit only once its other checks pass.
""".

-include("erx_ip4_wire.hrl").
-include("erx_icmp4_wire.hrl").

-export([input/6, error/4, decode_quoted/1, errno/1]).

-export_type([ctx/0, action/0, quoted/0, kind/0, errno/0]).

-define(IPPROTO_ICMP, 1).
-define(ICMP_ROUTERADVERT, 9).
-define(ICMP_ROUTERSOLICIT, 10).
-define(ICMP_TSTAMPREPLY, 14).
-define(ICMP_IREQ, 15).
-define(ICMP_IREQREPLY, 16).
-define(ICMP_MASKREQ, 17).
-define(ICMP_MASKREPLY, 18).
-define(ICMP_MINLEN, 8).
%% icmp_quotelen, FreeBSD's default.
-define(QUOTELEN, 548).

-doc """
What the decisions read from outside: the monotonic time in milliseconds for the rate
limits, and the milliseconds since midnight UTC that a timestamp reply carries (RFC 792,
FreeBSD's `iptime`), read by the interface's loop from the wall clock.
""".
-type ctx() :: #{now := integer(), time_of_day := 0..86399999}.

-doc """
The datagram and the protocol header an ICMP error quotes: its protocol, source and
destination, and the bytes after its IP header (at least 8: the ports and, for TCP, the
sequence number).
""".
-type quoted() :: #{proto := 0..255, src := <<_:32>>, dst := <<_:32>>, upper := binary()}.

-doc """
What the interface does: send an ICMP message (its IP header's fields for
`erx_ip4:output/4`, and the message), report an error to the protocol it quotes, or ask
the route table to apply a redirect for Dst through Gateway, sent by Router.
""".
-type action() :: {send, erx_ip4:out(), iodata()}
                | {report, #icmp4{}, quoted()}
                | {redirect, Dst :: <<_:32>>, Gateway :: <<_:32>>, Router :: <<_:32>>}.

-doc "An error `error/4` sends: destination unreachable with its code, or a parameter problem.".
-type kind() :: {unreach, 0..15} | {param_problem, Pointer :: 0..255}.

-doc "The error a report means to a socket, `icmp_errmap`'s errno, or `none` to ignore it.".
-type errno() :: ehostunreach | emsgsize | econnrefused | enoprotoopt | none.

-doc """
The decisions `icmp_input` makes on a verified message Icmp with Rest the bytes after its
fixed fields, carried by datagram Ip which may be answered as Reply says
(`erx_ip4:input/3`).
""".
-spec input(#ip4{}, erx_ip4:reply(), #icmp4{}, binary(), ctx(), erx_net_bandlim:lim()) ->
          {[action()], erx_net_bandlim:lim()}.
input(Ip, true, #icmp4{type = ?ICMP_ECHO, code = Code, msg = {echo, Id, Seq}}, Rest, #{now := Now}, Lim) ->
    Reply = #icmp4{type = ?ICMP_ECHOREPLY, code = Code, msg = {echo, Id, Seq}},
    reflect(Ip, icmp_echo, Reply, Rest, Now, Lim);
input(Ip, true, #icmp4{type = ?ICMP_TSTAMP, code = Code, msg = {timestamp, Id, Seq, Orig, _, _}}, Rest,
      #{now := Now, time_of_day := Time}, Lim) ->
    Reply = #icmp4{type = ?ICMP_TSTAMPREPLY, code = Code, msg = {timestamp, Id, Seq, Orig, Time, Time}},
    reflect(Ip, icmp_tstamp, Reply, Rest, Now, Lim);
input(#ip4{src = Router}, _, #icmp4{type = ?ICMP_REDIRECT, msg = {redirect, Gateway}}, Rest, _, Lim) ->
    case decode_quoted(Rest) of
        {ok, #{dst := Dst}} -> {[{redirect, Dst, Gateway, Router}], Lim};
        {error, _} -> {[], Lim}
    end;
input(_, _, #icmp4{msg = {error, _}} = Icmp, Rest, _, Lim) ->
    case decode_quoted(Rest) of
        {ok, Quoted} -> {[{report, Icmp, Quoted}], Lim};
        {error, _} -> {[], Lim}
    end;
input(_, _, _, _, _, Lim) ->
    {[], Lim}.

%% icmp_input's echo and timestamp cases within their limit, then icmp_reflect. The reply
%% keeps the request's type of service, as icmp_reflect keeps the header.
reflect(#ip4{src = Src, dst = Dst, tos = Tos}, Which, Reply, Rest, Now, Lim0) ->
    case erx_net_bandlim:check(Which, Now, Lim0) of
        {allow, Lim} ->
            Out = #{src => Dst, dst => Src, proto => ?IPPROTO_ICMP, tos => Tos},
            {[{send, Out, erx_icmp4_wire:encode(Reply, Rest)}], Lim};
        {deny, Lim} ->
            {[], Lim}
    end.

-doc """
The ICMP error of kind Kind about Packet, the received bytes of a datagram that
`erx_ip4:input/3` found may be answered, or nothing where `icmp_error` sends nothing or the
limit is reached. The error is sent from the datagram's destination to its source.
""".
-spec error(kind(), binary(), ctx(), erx_net_bandlim:lim()) -> {[action()], erx_net_bandlim:lim()}.
error(Kind, Packet, #{now := Now}, Lim0) ->
    maybe
        {ok, Src, Dst, Quote} ?= quote(Packet),
        {allow, Lim} ?= erx_net_bandlim:check(icmp_unreach, Now, Lim0),
        Out = #{src => Dst, dst => Src, proto => ?IPPROTO_ICMP},
        {[{send, Out, erx_icmp4_wire:encode(message(Kind), Quote)}], Lim}
    else
        {deny, Lim1} -> {[], Lim1};
        refused -> {[], Lim0}
    end.

message({unreach, Code}) -> #icmp4{type = ?ICMP_UNREACH, code = Code, msg = {error, 0}};
message({param_problem, Pointer}) -> #icmp4{type = ?ICMP_PARAMPROB, code = 0, msg = {error, Pointer bsl 24}}.

%% icmp_error's checks on the datagram, its bytes cut at its total length as FreeBSD's
%% mbuf is: an IP header and 8 bytes present, not a fragment other than the first (any
%% offset or the reserved flag), not an ICMP error message. The quote is the header and
%% max(8, min(icmp_quotelen, payload)) bytes.
quote(<<_:4, Hl:4, _:8, Len:16, _:16, Reserved:1, _:2, Off:13, _:8, P, _:16,
        Src:4/binary, Dst:4/binary, _/binary>> = Packet) ->
    HdrLen = Hl * 4,
    Available = min(Len, byte_size(Packet)),
    if
        Hl < 5; Available < HdrLen + ?ICMP_MINLEN -> refused;
        Off =/= 0; Reserved =/= 0 -> refused;
        true ->
            case icmp_error_message(P, binary:at(Packet, HdrLen)) of
                true -> refused;
                false -> {ok, Src, Dst, binary:part(Packet, 0, HdrLen + min(?QUOTELEN, Available - HdrLen))}
            end
    end;
quote(_) ->
    refused.

%% The complement of ICMP_INFOTYPE (netinet/ip_icmp.h): not a query or its reply.
icmp_error_message(?IPPROTO_ICMP, Type) ->
    not lists:member(Type, [?ICMP_ECHOREPLY, ?ICMP_ECHO, ?ICMP_ROUTERADVERT, ?ICMP_ROUTERSOLICIT,
                            ?ICMP_TSTAMP, ?ICMP_TSTAMPREPLY, ?ICMP_IREQ, ?ICMP_IREQREPLY,
                            ?ICMP_MASKREQ, ?ICMP_MASKREPLY]);
icmp_error_message(_, _) -> false.

-doc """
The quoted datagram of an ICMP error message, Invoking being the bytes after its fixed
fields: `icmp_input`'s checks before it hands an error to a protocol, a header of at least
20 bytes with 8 more after it, a destination that is not multicast, and neither address
0.0.0.0. Total over binaries: it never raises. Invoking is untrusted input, a datagram
the sender of the error claims to have received from us.
""".
-spec decode_quoted(binary()) -> {ok, quoted()} | {error, bad_length | bad_addr}.
decode_quoted(<<_:4, Hl:4, _:64, P, _:16, Src:4/binary, Dst:4/binary, _/binary>> = Invoking)
  when Hl >= 5, byte_size(Invoking) >= Hl * 4 + ?ICMP_MINLEN ->
    Bad = erx_ip4:addr_class(Dst) =:= multicast orelse Src =:= <<0:32>> orelse Dst =:= <<0:32>>,
    case Bad of
        false ->
            <<_:Hl/unit:32, Upper/binary>> = Invoking,
            {ok, #{proto => P, src => Src, dst => Dst, upper => Upper}};
        true -> {error, bad_addr}
    end;
decode_quoted(_) ->
    {error, bad_length}.

-doc "The error a socket sees for a reported ICMP error, `icmp_errmap`'s mapping.".
-spec errno(#icmp4{}) -> errno().
errno(#icmp4{type = ?ICMP_UNREACH, code = Code}) ->
    if
        Code =:= 4 -> emsgsize;
        Code =:= 2; Code =:= 3; Code =:= 9; Code =:= 10; Code =:= 13 -> econnrefused;
        Code =< 15 -> ehostunreach;
        true -> none
    end;
errno(#icmp4{type = ?ICMP_TIMXCEED, code = 0}) -> ehostunreach;
errno(#icmp4{type = ?ICMP_PARAMPROB, code = Code}) when Code =< 1 -> enoprotoopt;
errno(_) -> none.
