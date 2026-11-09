%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet6/ip6_input.c
%% FreeBSD: sys/netinet6/dest6.c
%% FreeBSD: sys/netinet6/route6.c
%% FreeBSD: sys/netinet6/frag6.c
%%
%% Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project.
%% All rights reserved.
%% Copyright (c) 2019 Netflix, Inc.
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

-module(erx_ip6_wire).
-moduledoc """
The IPv6 codec: the fixed header and the walk of its extension headers
(RFC 8200), translated from FreeBSD's ip6_input.c, dest6.c, route6.c and
frag6.c at the commit NOTICE-freebsd records
(docs/design-network-stack.md, "IPv6, neighbour discovery and
autoconfiguration").

`decode/1` is total: it returns `{ok, #ip6{}, Payload}` or `{error, Reason}`
and never raises. It makes every check that needs nothing but the packet's
bytes, in FreeBSD's order but for one departure below: the frame holds a fixed header of version 6, the
payload length fits the frame and the bytes after it are cut, and the walk
hands the packet on at most 15 times after the hop-by-hop header, counting
each extension header and the upper layer as FreeBSD's `ip6_hdrnestlimit`
loop does, each extension header lying wholly inside the payload. FreeBSD
reads the hop-by-hop options before it checks the payload length; here the
length comes first, so a frame both short and carrying a bad option is
dropped silently where FreeBSD answers it with a parameter problem, a
departure in which ICMPv6 error a refused packet draws. Along the walk:

* hop-by-hop and destination options are parsed and skipped by their
  option types' rules (`ip6_unknown_opt`); every option must lie inside its
  header, as `dest6_input` requires of both kinds;
* a jumbo payload option is an option this stack does not recognise, so its
  type's rule refuses it (RFC 2675: a node without jumbogram support treats
  it as unrecognised), and a zero payload length with a hop-by-hop header
  is refused as `ip6_input_hbh` refuses it;
* a hop-by-hop header after the first position is an unrecognised next
  header (RFC 8200, section 4.1);
* a routing header with segments left is refused, whatever its type, which
  refuses type 0 as RFC 5095 requires (`route6_input`); one with no
  segments left is passed over;
* a fragment header that is not atomic ends the walk, is returned in the
  record's `fragment` field, and the payload is
  the fragment's data; an atomic one is passed over (`frag6_input`). A
  first fragment must hold the rest of the header chain through the upper
  layer's fixed header (RFC 7112), which FreeBSD does not check.

The checks that need more than the packet (addresses, the interface,
whether to answer with an ICMPv6 error) are erx_ip6's. A refusal that
FreeBSD answers with a parameter problem carries the code and pointer, so
erx_ip6 can decide whether to send it:

* `{param_problem, Code, Pointer}`: FreeBSD calls `icmp6_error`;
* `{param_problem_unicast, Code, Pointer}`: an option whose type says to
  answer only a packet sent to neither a multicast address nor a link-layer
  broadcast or multicast;
* `unknown_option`: an option whose type says to discard silently.

The other reasons are silent drops, each named after the FreeBSD counter it
would bump. IPv6 has no header checksum.
""".

-include("erx_ip6.hrl").

-export([decode/1, encode/2, pseudo_sum/4]).

-export_type([exthdr/0, option/0, reason/0]).

-doc """
An extension header the walk passed. Options are `{Type, Data}` in wire
order with the padding options left out; a routing header keeps its type
and the bytes after its first four; a fragment header keeps its offset in
bytes, its more-fragments flag and its identification.
""".
-type exthdr() :: {hopopts, [option()]}
                | {dstopts, [option()]}
                | {routing, Type :: 0..255, Data :: binary()}
                | {fragment, Offset :: 0..16#fff8, More :: boolean(),
                   Id :: 0..16#ffffffff}.

-type option() :: {Type :: 2..255, Data :: binary()}.

-doc "Why `decode/1` refused a packet: a closed set.".
-type reason() :: too_short                 % ip6s_toosmall
                | bad_version               % ip6s_badvers
                | truncated                 % ip6s_tooshort
                | header_too_long           % ip6s_exthdrtoolong
                | bad_option                % ip6s_toosmall in the options
                | too_many_headers          % ip6s_toomanyhdr
                | unknown_option
                | {param_problem, 0..3, non_neg_integer()}
                | {param_problem_unicast, 2, non_neg_integer()}.

-define(FIXED_LEN, 40).
-define(NXT_PTR, 6).
-define(PLEN_PTR, 4).
%% How many extension headers one walk passes: FreeBSD's ip6_hdrnestlimit.
-define(HDRNESTLIMIT, 15).
-define(IP6OPT_PAD1, 0).
-define(IP6OPT_PADN, 1).
-define(IP6OPT_ROUTER_ALERT, 5).
-define(IP6OPT_RTALERT_LEN, 4).
-define(IP6F_OFF_MASK, 16#fff8).
-define(IP6F_MORE_FRAG, 16#0001).
-define(FRAG_LEN, 8).
-define(IS_EXTHDR(Nxt), (Nxt =:= ?IPPROTO_HOPOPTS orelse Nxt =:= ?IPPROTO_DSTOPTS
                         orelse Nxt =:= ?IPPROTO_ROUTING
                         orelse Nxt =:= ?IPPROTO_FRAGMENT)).

%% The walk's position: `ptr' is the offset of the byte naming the next
%% header, `off' the offset of the next header itself, both from the start of
%% the fixed header; `count' is the extension headers passed so far and `acc'
%% those headers, newest first.
-record(walk, {ptr = ?NXT_PTR :: non_neg_integer(),
               off = ?FIXED_LEN :: non_neg_integer(),
               count = 0 :: non_neg_integer(),
               acc = [] :: [exthdr()]}).

-doc """
Decodes one IPv6 packet. `Payload` is what follows the last header the
walk passed, cut at the payload length, as a sub-binary of `Frame`.
Translates the checks of FreeBSD's `ip6_input`, `ip6_input_hbh`,
`ip6_hopopts_input`, `ip6_process_hopopts`, `ip6_unknown_opt`,
`dest6_input`, `route6_input` and `frag6_input` that read only the packet.
""".
-spec decode(binary()) -> {ok, #ip6{}, Payload :: binary()} | {error, reason()}.
decode(Frame) when byte_size(Frame) < ?FIXED_LEN ->
    {error, too_short};
decode(<<6:4, TClass:8, Flow:20, Plen:16, Nxt:8, Hlim:8,
         Src:16/binary, Dst:16/binary, Rest/binary>>) ->
    Header = #ip6{tclass = TClass, flow = Flow, hlim = Hlim,
                  src = Src, dst = Dst, proto = Nxt},
    case Rest of
        <<Payload:Plen/binary, _/binary>> -> fixed(Header, Payload);
        _Short -> {error, truncated}
    end;
decode(_) ->
    {error, bad_version}.

%% A zero payload length with a hop-by-hop header announces a jumbogram,
%% refused as ip6_input_hbh refuses one without its option.
fixed(#ip6{proto = ?IPPROTO_HOPOPTS}, <<>>) ->
    {error, {param_problem, ?ICMP6_PARAMPROB_HEADER, ?PLEN_PTR}};
fixed(#ip6{proto = Nxt} = Header, Payload) ->
    walk(Nxt, #walk{}, Payload, Header).

%% One step of the walk over the header named Nxt, which starts Bin; the
%% loop of ip6_input with the extension-header handlers it dispatches to.
walk(_, #walk{count = Count}, _, _) when Count >= ?HDRNESTLIMIT ->
    {error, too_many_headers};
walk(?IPPROTO_HOPOPTS, #walk{ptr = Ptr, off = Off}, _, _) when Off =/= ?FIXED_LEN ->
    {error, {param_problem, ?ICMP6_PARAMPROB_NEXTHEADER, Ptr}};
walk(Nxt, Walk, Bin, Header) when Nxt =:= ?IPPROTO_HOPOPTS; Nxt =:= ?IPPROTO_DSTOPTS ->
    Kind = case Nxt of ?IPPROTO_HOPOPTS -> hopopts; ?IPPROTO_DSTOPTS -> dstopts end,
    maybe
        {ok, Next, <<_:16, Body/binary>> = Ext, More} ?= ext_header(Bin),
        {ok, Options} ?= options(Body, Walk#walk.off + 2, Kind, []),
        next(Next, {Kind, Options}, byte_size(Ext), Walk, More, Header)
    end;
walk(?IPPROTO_ROUTING, #walk{off = Off}, <<_, _, _, SegLeft, _/binary>>, _) when SegLeft =/= 0 ->
    {error, {param_problem, ?ICMP6_PARAMPROB_HEADER, Off + 2}};
walk(?IPPROTO_ROUTING, Walk, Bin, Header) ->
    maybe
        {ok, Next, <<_:16, Type, 0, Data/binary>> = Ext, More} ?= ext_header(Bin),
        next(Next, {routing, Type, Data}, byte_size(Ext), Walk, More, Header)
    end;
walk(?IPPROTO_FRAGMENT, Walk, <<Next, _, OffLg:16, Id:32, Data/binary>>, Header) ->
    fragment(Next, OffLg, Id, Walk, Data, Header);
walk(?IPPROTO_FRAGMENT, _, _, _) ->
    {error, header_too_long};
walk(Nxt, #walk{ptr = Ptr, off = Off, acc = Acc}, Payload, Header) ->
    {ok, Header#ip6{exthdrs = lists:reverse(Acc), proto = Nxt, proto_ptr = Ptr,
                    hdrlen = Off - ?FIXED_LEN}, Payload}.

next(Nxt, ExtHdr, Bytes, #walk{off = Off, count = Count, acc = Acc}, More, Header) ->
    walk(Nxt, #walk{ptr = Off, off = Off + Bytes, count = Count + dispatches(ExtHdr),
                    acc = [ExtHdr | Acc]}, More, Header).

%% FreeBSD handles the hop-by-hop header before its dispatch loop, so only
%% the headers after it count against ip6_hdrnestlimit.
dispatches({hopopts, _}) -> 0;
dispatches(_) -> 1.

%% The checks frag6_input makes of one fragment header before reassembly.
%% A fragment with more to follow carries a multiple of 8 bytes; an atomic
%% fragment (offset 0, no more to follow) is passed over; any other must
%% carry data, and ends the walk with that data as the payload.
fragment(_, OffLg, _, _, Data, _) when OffLg band ?IP6F_MORE_FRAG =/= 0,
                                       byte_size(Data) rem 8 =/= 0 ->
    {error, {param_problem, ?ICMP6_PARAMPROB_HEADER, ?PLEN_PTR}};
fragment(Next, OffLg, Id, Walk, Data, Header)
  when OffLg band (?IP6F_OFF_MASK bor ?IP6F_MORE_FRAG) =:= 0 ->
    next(Next, {fragment, 0, false, Id}, ?FRAG_LEN, Walk, Data, Header);
fragment(_, _, _, _, <<>>, _) ->
    {error, {param_problem, ?ICMP6_PARAMPROB_HEADER, ?PLEN_PTR}};
fragment(Next, OffLg, Id, #walk{off = Off, count = Count, acc = Acc}, Data, Header) ->
    Offset = OffLg band ?IP6F_OFF_MASK,
    Frag = {Offset, OffLg band ?IP6F_MORE_FRAG =/= 0, Id},
    Chain = case Offset of 0 -> complete(Next, Data, Count + 1); _ -> ok end,
    maybe
        ok ?= Chain,
        {ok, Header#ip6{exthdrs = lists:reverse(Acc), fragment = Frag, proto = Next,
                        proto_ptr = Off, hdrlen = Off + ?FRAG_LEN - ?FIXED_LEN}, Data}
    end.

%% RFC 7112: a first fragment holds every header after the fragment header
%% through the upper layer's fixed header, as long as the upper layer's input
%% function first requires (struct tcphdr, struct udphdr, struct icmp6_hdr).
complete(Nxt, _, Count) when Count >= ?HDRNESTLIMIT, ?IS_EXTHDR(Nxt) ->
    {error, too_many_headers};
complete(?IPPROTO_FRAGMENT, <<Next, _:7/binary, More/binary>>, Count) ->
    complete(Next, More, Count + 1);
complete(?IPPROTO_FRAGMENT, _, _) ->
    incomplete();
complete(Nxt, Bin, Count) when ?IS_EXTHDR(Nxt) ->
    case ext_header(Bin) of
        {ok, Next, _, More} -> complete(Next, More, Count + 1);
        {error, _} -> incomplete()
    end;
complete(Nxt, Bin, _) ->
    case byte_size(Bin) >= upper_header_len(Nxt) of
        true -> ok;
        false -> incomplete()
    end.

incomplete() ->
    {error, {param_problem, ?ICMP6_PARAMPROB_FIRSTFRAG, 0}}.

upper_header_len(?IPPROTO_TCP) -> 20;
upper_header_len(?IPPROTO_UDP) -> 8;
upper_header_len(?IPPROTO_ICMPV6) -> 8;
upper_header_len(_) -> 0.

%% An options or routing header, whole: (Len + 1) * 8 bytes by its second
%% byte, as ip6_hopopts_input, dest6_input and route6_input pull it up.
ext_header(<<Next, Len, _/binary>> = Bin) when byte_size(Bin) >= (Len + 1) * 8 ->
    Bytes = (Len + 1) * 8,
    <<Ext:Bytes/binary, More/binary>> = Bin,
    {ok, Next, Ext, More};
ext_header(_) ->
    {error, header_too_long}.

%% The options of a hop-by-hop or destination options header, Ptr the offset
%% of the first; the loops of ip6_process_hopopts and dest6_input. Every
%% option but Pad1 lies inside the header (dest6_input's rule, which
%% ip6_process_hopopts makes only of the options it knows).
options(<<>>, _, _, Acc) ->
    {ok, lists:reverse(Acc)};
options(<<?IP6OPT_PAD1, Rest/binary>>, Ptr, Kind, Acc) ->
    options(Rest, Ptr + 1, Kind, Acc);
options(<<Type, Len, Data:Len/binary, Rest/binary>> = Bin, Ptr, Kind, Acc) ->
    case option(Type, Data, byte_size(Bin), Ptr, Kind) of
        skip -> options(Rest, Ptr + 2 + Len, Kind, Acc);
        keep -> options(Rest, Ptr + 2 + Len, Kind, [{Type, Data} | Acc]);
        {error, _} = Error -> Error
    end;
options(_, _, _, _) ->
    {error, bad_option}.

%% One option, Avail the bytes left in its header from its type on. Only
%% hop-by-hop headers know the router alert (ip6_process_hopopts); a jumbo
%% payload option is unknown here, so its type's rule refuses it.
option(?IP6OPT_PADN, _, _, _, _) ->
    skip;
option(?IP6OPT_ROUTER_ALERT, _, Avail, _, hopopts) when Avail < ?IP6OPT_RTALERT_LEN ->
    {error, bad_option};
option(?IP6OPT_ROUTER_ALERT, Data, _, Ptr, hopopts) when byte_size(Data) =/= 2 ->
    {error, {param_problem, ?ICMP6_PARAMPROB_HEADER, Ptr + 1}};
option(?IP6OPT_ROUTER_ALERT, _, _, _, hopopts) ->
    keep;
option(Type, _, _, Ptr, _) ->
    unknown_option(Type, Ptr).

%% ip6_unknown_opt: the two high bits of an unrecognised option's type say
%% what to do with the packet (RFC 8200, section 4.2).
unknown_option(Type, Ptr) ->
    case Type band 16#c0 of
        16#00 -> keep;
        16#40 -> {error, unknown_option};
        16#80 -> {error, {param_problem, ?ICMP6_PARAMPROB_OPTION, Ptr}};
        16#c0 -> {error, {param_problem_unicast, ?ICMP6_PARAMPROB_OPTION, Ptr}}
    end.

-doc """
Encodes a packet: the fixed header, the extension headers of `exthdrs` in
order and the payload, with the payload length and every next-header value
computed and options padded to 8 bytes with Pad1 and PadN. `proto_ptr` and
`hdrlen` are ignored; a `fragment` is written after `exthdrs`. Raises
`badarg` when the payload length would pass 65535 or an extension header
or option cannot be encoded, since the stack encodes only records it built.
""".
-spec encode(#ip6{}, iodata()) -> iodata().
encode(#ip6{tclass = TClass, flow = Flow, hlim = Hlim, src = Src, dst = Dst,
            exthdrs = ExtHdrs, fragment = Fragment, proto = Proto}, Payload) ->
    Chain = case Fragment of
                none -> ExtHdrs;
                {Offset, More, Id} -> ExtHdrs ++ [{fragment, Offset, More, Id}]
            end,
    {Nxt, Headers} = lists:foldr(fun(ExtHdr, {Next, Acc}) ->
                                         {exthdr_type(ExtHdr), [encode_exthdr(ExtHdr, Next) | Acc]}
                                 end, {Proto, []}, Chain),
    Plen = iolist_size(Headers) + iolist_size(Payload),
    Plen =< 16#ffff orelse erlang:error(badarg),
    [<<6:4, TClass:8, Flow:20, Plen:16, Nxt:8, Hlim:8, Src:16/binary, Dst:16/binary>>,
     Headers, Payload].

-doc """
The partial Internet checksum of the pseudo-header that the upper layer's
checksum covers (RFC 8200, section 8.1): source and destination address,
the upper-layer length and the next-header value, for
`erx_bytes:inet_csum/2` to continue over the upper layer.
""".
-spec pseudo_sum(<<_:128>>, <<_:128>>, 0..16#ffffffff, 0..255) -> 0..16#ffff.
pseudo_sum(Src, Dst, Len, Nxt) ->
    erx_bytes:inet_csum(0, <<Src:16/binary, Dst:16/binary, Len:32, 0:24, Nxt>>).

exthdr_type({hopopts, _}) -> ?IPPROTO_HOPOPTS;
exthdr_type({dstopts, _}) -> ?IPPROTO_DSTOPTS;
exthdr_type({routing, _, _}) -> ?IPPROTO_ROUTING;
exthdr_type({fragment, _, _, _}) -> ?IPPROTO_FRAGMENT.

encode_exthdr({Kind, Options}, Next) when Kind =:= hopopts; Kind =:= dstopts ->
    Body = << <<(encode_option(Type, Data))/binary>> || {Type, Data} <- Options >>,
    Size = 2 + byte_size(Body),
    Total = (Size + 7) div 8 * 8,
    [<<Next, (ext_len(Total))>>, Body, padding(Total - Size)];
encode_exthdr({routing, Type, Data}, Next) ->
    <<Next, (ext_len(4 + byte_size(Data))), Type, 0, Data/binary>>;
encode_exthdr({fragment, Offset, More, Id}, Next) when Offset band ?IP6F_OFF_MASK =:= Offset ->
    MoreBit = case More of true -> ?IP6F_MORE_FRAG; false -> 0 end,
    <<Next, 0, (Offset bor MoreBit):16, Id:32>>;
encode_exthdr(_, _) ->
    erlang:error(badarg).

%% Pad1 and PadN are the encoder's own padding, never options of a record.
encode_option(Type, Data) when Type >= 2, Type =< 255, byte_size(Data) =< 255 ->
    <<Type, (byte_size(Data)), Data/binary>>;
encode_option(_, _) ->
    erlang:error(badarg).

%% The length byte of a header of Total bytes, a multiple of 8 up to 2048.
ext_len(Total) when Total rem 8 =:= 0, Total >= 8, Total =< 2048 -> Total div 8 - 1;
ext_len(_) -> erlang:error(badarg).

padding(0) -> <<>>;
padding(1) -> <<?IP6OPT_PAD1>>;
padding(N) -> <<?IP6OPT_PADN, (N - 2), 0:((N - 2) * 8)>>.
