%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet6/icmp6.c
%% FreeBSD: sys/netinet6/nd6.c
%% FreeBSD: sys/netinet6/nd6_rtr.c
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

-module(erx_icmp6_wire).
-moduledoc """
The ICMPv6 codec (RFC 4443) with the neighbour-discovery messages and their
option parser (RFC 4861), translated from FreeBSD's icmp6.c, nd6.c and
nd6_rtr.c at the commit NOTICE-freebsd records
(docs/design-network-stack.md, "IPv6, neighbour discovery and
autoconfiguration").

`decode/2` is total: it returns `{ok, #icmp6{}, Rest}` or `{error, Reason}`
and never raises. It makes the checks `icmp6_input` makes before it acts on
a message: the 8 bytes of `struct icmp6_hdr`; the checksum over the
pseudo-header and the message (RFC 4443, section 2.3), checked before any
other field is read, as `icmp6_input` checks it; for each type it knows, the
codes it accepts and the length of the type's fixed part; an error message
quoting at least an IPv6 header (`icmp6_notify_error`); and the options of
a neighbour-discovery message parsing as `nd6_options` parses them. FreeBSD
hands a message with a bad code or length to raw sockets without acting on
it; this stack has no raw ICMPv6 sockets, so the decoder refuses it.
Messages of the types it does not know (MLD, router renumbering, node
information, unassigned types) decode as `other`.

Rest is what follows the part the decoder reads: an error message's
invoking packet, an echo's data, the body of an `other` message after its
first four bytes, and nothing for neighbour discovery, whose options are
decoded.

The caller gives the pseudo-header's partial sum
(`erx_ip6_wire:pseudo_sum/4`), since the addresses belong to the IPv6
layer, and `encode/3` writes the sum over the addresses it is given. The
checks that need more than the message (the
hop limit of 255, a multicast target, a link-layer address of the
interface's length, a prefix's lifetimes) are erx_icmp6's, erx_nd6's and
erx_nd6_rtr's.
""".

-include("erx_ip6.hrl").

-export([decode/2, encode/3]).

-export_type([msg/0, nd_opts/0, prefix/0, reason/0]).

-doc """
The fields of a message by its kind. An error message (a type below 128)
keeps its second word, which is the MTU of a packet too big, the pointer of
a parameter problem and unused otherwise. Target and destination addresses
are 16 bytes. Reserved fields are dropped on decode and written as zero.
""".
-type msg() :: {error, Word :: 0..16#ffffffff}
             | {echo, Id :: 0..16#ffff, Seq :: 0..16#ffff}
             | {rs, nd_opts()}
             | {ra, CurHopLimit :: 0..255, Flags :: 0..255,
                RouterLifetime :: 0..16#ffff, ReachableTime :: 0..16#ffffffff,
                RetransTimer :: 0..16#ffffffff, nd_opts()}
             | {ns, Target :: <<_:128>>, nd_opts()}
             | {na, Flags :: 0..7, Target :: <<_:128>>, nd_opts()}
             | {redirect, Target :: <<_:128>>, Dst :: <<_:128>>, nd_opts()}
             | other.

-doc """
The options of a neighbour-discovery message as `nd6_options` and
`nd6_ra_input` take them: the first source and target link-layer address,
redirected header, MTU and nonce options (an address or nonce as its option
body, padding included; a redirected header as the packet after its six
reserved bytes; an MTU only when the first MTU option has the length of
one), and every prefix information option of the right length, in order.
Other options are ignored. A key is absent when its option is.
""".
-type nd_opts() :: #{slla => binary(), tlla => binary(),
                     prefixes => [prefix(), ...], mtu => 0..16#ffffffff,
                     redirected => binary(), nonce => binary()}.

-type prefix() :: #{len := 0..255, flags := 0..255,
                    valid := 0..16#ffffffff, preferred := 0..16#ffffffff,
                    prefix := <<_:128>>}.

-doc "Why `decode/2` refused a message: a closed set, after FreeBSD's counters.".
-type reason() :: too_short      % icp6s_tooshort
                | bad_code       % icp6s_badcode
                | bad_sum        % icp6s_checksum
                | bad_length     % icp6s_badlen; icp6s_tooshort for a short quote
                | bad_option.    % icp6s_nd_badopt

-define(ICMP6_HDR_LEN, 8).
-define(IPV6_MAXPACKET, 16#ffff).
-define(IP6_HDR_LEN, 40).
-define(ICMP6_INFOMSG_MASK, 128).
%% nd6_options reads options until the count passes nd6_maxndopt.
-define(ND6_MAXNDOPT, 10).
-define(ND_OPT_SOURCE_LINKADDR, 1).
-define(ND_OPT_TARGET_LINKADDR, 2).
-define(ND_OPT_PREFIX_INFORMATION, 3).
-define(ND_OPT_REDIRECTED_HEADER, 4).
-define(ND_OPT_MTU, 5).
-define(ND_OPT_NONCE, 14).
-define(IS_ND(Type), (Type >= ?ND_ROUTER_SOLICIT andalso Type =< ?ND_REDIRECT)).
-define(IS_ECHO(Type), (Type =:= ?ICMP6_ECHO_REQUEST orelse Type =:= ?ICMP6_ECHO_REPLY)).

-doc """
Decodes one ICMPv6 message, the payload of its IPv6 packet, with
`PseudoSum` the partial sum of its pseudo-header. Translates the
checks of FreeBSD's `icmp6_input`, `icmp6_notify_error`, `nd6_option_init`,
`nd6_option` and `nd6_options`, and of `nd6_ra_input` on its prefix and MTU
options' lengths.
""".
-spec decode(0..16#ffff, binary()) -> {ok, #icmp6{}, Rest :: binary()} | {error, reason()}.
decode(_, Message) when not is_binary(Message); byte_size(Message) < ?ICMP6_HDR_LEN ->
    {error, too_short};
decode(_, Message) when byte_size(Message) > ?IPV6_MAXPACKET ->
    {error, bad_length};
decode(PseudoSum, <<Type, Code, _Sum:16, Body/binary>> = Message) ->
    case erx_bytes:inet_csum(PseudoSum, Message) of
        16#ffff -> message(Type, Code, Body);
        _ -> {error, bad_sum}
    end.

%% icmp6_input's switch on the type: the code first, then the length.
message(Type, Code, <<Word:32, Invoking/binary>>) when Type < ?ICMP6_INFOMSG_MASK ->
    case error_code(Type, Code) of
        false -> {error, bad_code};
        true when byte_size(Invoking) < ?IP6_HDR_LEN -> {error, bad_length};
        true -> {ok, #icmp6{type = Type, code = Code, msg = {error, Word}}, Invoking}
    end;
message(Type, Code, _) when Code =/= 0, ?IS_ECHO(Type) orelse ?IS_ND(Type) ->
    {error, bad_code};
message(Type, 0, <<Id:16, Seq:16, Data/binary>>) when ?IS_ECHO(Type) ->
    {ok, #icmp6{type = Type, code = 0, msg = {echo, Id, Seq}}, Data};
message(?ND_ROUTER_SOLICIT = Type, 0, <<_:32, Opts/binary>>) ->
    nd(Type, Opts, fun(Parsed) -> {rs, Parsed} end);
message(?ND_ROUTER_ADVERT = Type, 0, <<CurHop, Flags, Lifetime:16, Reachable:32,
                                       Retrans:32, Opts/binary>>) ->
    nd(Type, Opts, fun(Parsed) -> {ra, CurHop, Flags, Lifetime, Reachable, Retrans, Parsed} end);
message(?ND_NEIGHBOR_SOLICIT = Type, 0, <<_:32, Target:16/binary, Opts/binary>>) ->
    nd(Type, Opts, fun(Parsed) -> {ns, Target, Parsed} end);
message(?ND_NEIGHBOR_ADVERT = Type, 0, <<Flags:3, _:29, Target:16/binary, Opts/binary>>) ->
    nd(Type, Opts, fun(Parsed) -> {na, Flags, Target, Parsed} end);
message(?ND_REDIRECT = Type, 0, <<_:32, Target:16/binary, Dst:16/binary, Opts/binary>>) ->
    nd(Type, Opts, fun(Parsed) -> {redirect, Target, Dst, Parsed} end);
message(Type, _, _) when ?IS_ND(Type) ->
    {error, bad_length};
message(Type, Code, Body) ->
    {ok, #icmp6{type = Type, code = Code, msg = other}, Body}.

%% The codes icmp6_input accepts for the error types it knows; it passes
%% every code of the others on to icmp6_notify_error.
error_code(?ICMP6_DST_UNREACH, Code) -> Code =< 4;
error_code(?ICMP6_TIME_EXCEEDED, Code) -> Code =< 1;
error_code(?ICMP6_PARAM_PROB, Code) -> Code =< 2;
error_code(_, _) -> true.

nd(Type, Opts, Make) ->
    case nd_options(Opts, 0, #{}) of
        {ok, Parsed} -> {ok, #icmp6{type = Type, code = 0, msg = Make(Parsed)}, <<>>};
        {error, _} = Error -> Error
    end.

%% nd6_option and nd6_options: each option states its length in units of 8
%% bytes, which must be nonzero and keep it inside the message; a malformed
%% option refuses the message. Seen counts the options read, and reading
%% stops once it passes nd6_maxndopt, ignoring what follows.
nd_options(<<>>, _, Opts) ->
    {ok, finish(Opts)};
nd_options(_, Seen, Opts) when Seen > ?ND6_MAXNDOPT ->
    {ok, finish(Opts)};
nd_options(<<Type, Len, Rest/binary>>, Seen, Opts) when Len > 0 ->
    case Rest of
        <<Body:(Len * 8 - 2)/binary, More/binary>> ->
            nd_options(More, Seen + 1, nd_option(Type, Len, Body, Opts));
        _Overrun -> {error, bad_option}
    end;
nd_options(_, _, _) ->
    {error, bad_option}.

%% One option, by nd6_options's rules: the first of each single option
%% counts, and every prefix option does; nd6_ra_input then takes an MTU
%% option only of length 1 and a prefix option only of length 4.
nd_option(?ND_OPT_SOURCE_LINKADDR, _, Body, Opts) ->
    first(slla, Body, Opts);
nd_option(?ND_OPT_TARGET_LINKADDR, _, Body, Opts) ->
    first(tlla, Body, Opts);
nd_option(?ND_OPT_REDIRECTED_HEADER, _, <<_:48, Packet/binary>>, Opts) ->
    first(redirected, Packet, Opts);
nd_option(?ND_OPT_MTU, 1, <<_:16, Mtu:32>>, Opts) ->
    first(mtu, Mtu, Opts);
nd_option(?ND_OPT_MTU, _, _, Opts) ->
    first(mtu, ignored, Opts);
nd_option(?ND_OPT_NONCE, _, Body, Opts) ->
    first(nonce, Body, Opts);
nd_option(?ND_OPT_PREFIX_INFORMATION, 4, <<Len, Flags, Valid:32, Preferred:32, _:32,
                                           Prefix:16/binary>>, Opts) ->
    Info = #{len => Len, flags => Flags, valid => Valid, preferred => Preferred,
             prefix => Prefix},
    Opts#{prefixes => [Info | maps:get(prefixes, Opts, [])]};
nd_option(_, _, _, Opts) ->
    Opts.

first(Key, _, Opts) when is_map_key(Key, Opts) -> Opts;
first(Key, Value, Opts) -> Opts#{Key => Value}.

%% Drops a first MTU option of the wrong length and puts the prefixes,
%% collected newest first, in wire order.
finish(#{mtu := ignored} = Opts) ->
    finish(maps:remove(mtu, Opts));
finish(#{prefixes := Prefixes} = Opts) ->
    Opts#{prefixes := lists:reverse(Prefixes)};
finish(Opts) ->
    Opts.

-doc """
Encodes a message followed by Rest, with its checksum over the pseudo-header
of the source and destination addresses given. Neighbour-discovery options
are written
in a fixed order (source and target link-layer addresses, prefixes, MTU,
redirected header, nonce), each padded with zeros to 8 bytes. Raises
`badarg` for an option too long to encode or a message over 65535 bytes, since the stack encodes only
records it built.
""".
-spec encode(#icmp6{}, iodata(), {Src :: <<_:128>>, Dst :: <<_:128>>}) -> iodata().
encode(#icmp6{type = Type, code = Code, msg = Msg}, Rest, {Src, Dst}) ->
    Tail = [body(Msg), Rest],
    Len = 4 + iolist_size(Tail),
    Len =< ?IPV6_MAXPACKET orelse erlang:error(badarg),
    PseudoSum = erx_ip6_wire:pseudo_sum(Src, Dst, Len, ?IPPROTO_ICMPV6),
    Sum = bnot erx_bytes:inet_csum(PseudoSum, [<<Type, Code, 0:16>>, Tail]) band 16#ffff,
    [<<Type, Code, Sum:16>>, Tail].

body({error, Word}) ->
    <<Word:32>>;
body({echo, Id, Seq}) ->
    <<Id:16, Seq:16>>;
body({rs, Opts}) ->
    [<<0:32>>, encode_options(Opts)];
body({ra, CurHop, Flags, Lifetime, Reachable, Retrans, Opts}) ->
    [<<CurHop, Flags, Lifetime:16, Reachable:32, Retrans:32>>, encode_options(Opts)];
body({ns, Target, Opts}) ->
    [<<0:32, Target:16/binary>>, encode_options(Opts)];
body({na, Flags, Target, Opts}) ->
    [<<Flags:3, 0:29, Target:16/binary>>, encode_options(Opts)];
body({redirect, Target, Dst, Opts}) ->
    [<<0:32, Target:16/binary, Dst:16/binary>>, encode_options(Opts)];
body(other) ->
    <<>>.

encode_options(Opts) ->
    Single = fun(Key, Type, Wrap) ->
                     case Opts of
                         #{Key := Value} -> [nd_opt(Type, Wrap(Value))];
                         _ -> []
                     end
             end,
    Same = fun(Value) -> Value end,
    [Single(slla, ?ND_OPT_SOURCE_LINKADDR, Same),
     Single(tlla, ?ND_OPT_TARGET_LINKADDR, Same),
     [nd_opt(?ND_OPT_PREFIX_INFORMATION,
             <<Len, Flags, Valid:32, Preferred:32, 0:32, Prefix:16/binary>>)
      || #{len := Len, flags := Flags, valid := Valid, preferred := Preferred,
           prefix := Prefix} <- maps:get(prefixes, Opts, [])],
     Single(mtu, ?ND_OPT_MTU, fun(Mtu) -> <<0:16, Mtu:32>> end),
     Single(redirected, ?ND_OPT_REDIRECTED_HEADER, fun(Packet) -> <<0:48, Packet/binary>> end),
     Single(nonce, ?ND_OPT_NONCE, Same)].

%% One option: type, length in units of 8 bytes, body and zero padding.
nd_opt(Type, Body) ->
    Size = 2 + byte_size(Body),
    Units = (Size + 7) div 8,
    Units =< 255 orelse erlang:error(badarg),
    <<Type, Units, Body/binary, 0:((Units * 8 - Size) * 8)>>.
