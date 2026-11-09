%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sbin/dhclient/dhclient.c
%% Copyright 2004 Henning Brauer <henning@openbsd.org>
%% Copyright (c) 1995, 1996, 1997, 1998, 1999
%% The Internet Software Consortium.    All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%%
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%% 3. Neither the name of The Internet Software Consortium nor the names
%%    of its contributors may be used to endorse or promote products derived
%%    from this software without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE INTERNET SOFTWARE CONSORTIUM AND
%% CONTRIBUTORS ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
%% INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
%% DISCLAIMED.  IN NO EVENT SHALL THE INTERNET SOFTWARE CONSORTIUM OR
%% CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
%% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
%% LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
%% USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
%% ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
%% OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
%% OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.
%%
%% This software has been written for the Internet Software Consortium
%% by Ted Lemon <mellon@fugue.com> in cooperation with Vixie
%% Enterprises.  To learn more about the Internet Software Consortium,
%% see ``http://www.vix.com/isc''.  To learn more about Vixie
%% Enterprises, see ``http://www.vix.com''.
%%
%% This client was substantially modified and enhanced by Elliot Poger
%% for use on Linux while he was working on the MosquitoNet project at
%% Stanford.
%%
%% The current version owes much to Elliot's Linux enhancements, but
%% was substantially reorganized and partially rewritten by Ted Lemon
%% so as to use the same networking framework that the Internet Software
%% Consortium DHCP server uses.   Much system-specific configuration code
%% was moved into a shell script so that as support for more operating
%% systems is added, it will not be necessary to port and maintain
%% system-specific configuration code to these operating systems - instead,
%% the shell script can invoke the native tools to accomplish the same
%% purpose.
%%
%% FreeBSD: sbin/dhclient/options.c
%% Copyright (c) 1995, 1996, 1997, 1998 The Internet Software Consortium.
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%%
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%% 3. Neither the name of The Internet Software Consortium nor the names
%%    of its contributors may be used to endorse or promote products derived
%%    from this software without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE INTERNET SOFTWARE CONSORTIUM AND
%% CONTRIBUTORS ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
%% INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
%% DISCLAIMED.  IN NO EVENT SHALL THE INTERNET SOFTWARE CONSORTIUM OR
%% CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
%% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
%% LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
%% USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
%% ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
%% OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
%% OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.
%%
%% This software has been written for the Internet Software Consortium
%% by Ted Lemon <mellon@fugue.com> in cooperation with Vixie
%% Enterprises.  To learn more about the Internet Software Consortium,
%% see ``http://www.vix.com/isc''.  To learn more about Vixie
%% Enterprises, see ``http://www.vix.com''.

-module(erx_dhcp4_wire).
-moduledoc """
The DHCP message codec (RFC 2131 section 2, with RFC 2132's options, RFC 3396's long
options and RFC 3442's classless static routes; docs/design-network-stack.md, "Addresses
and routes"). It is written from the RFCs, except that the option overload, the routes'
checks and the domain name's checks translate FreeBSD's `dhclient` (`parse_options` of
`sbin/dhclient/options.c`; `check_classless_option`, `res_hnok`, `check_search` and
`option_as_string` of `sbin/dhclient/dhclient.c`, at commit 95719d8a,
erlang/apps/erx_net/NOTICE-freebsd). A message arrives as the payload of a UDP datagram
that erx_udp_wire has already checked, so this decoder checks no sum of its own; it is the
only maker of a received `#dhcp4{}`.

`decode/1` takes the fixed 236-byte header, the magic cookie and the options. An option is
a code, a length and that many bytes; pad (0) is skipped and end (255) ends the options,
and so does the end of the message, which some servers send without an end option. When
the options field carries an overload option (52, RFC 2132 9.3), the `file` field and then
the `sname` field, as its value says, hold more options, read the same way up to an end
option or the field's end; that is RFC 3396's order and `parse_options`'. The instances of
one code, across the fields, are joined in order into one value (RFC 3396). Only the
options of `?OPTIONS` are kept, each under its own name and checked against its rule;
every other option is skipped unread. A known option that breaks its rule refuses the
message when it is one of `?REQUIRED_SOUND` (the message type, mask, lease time, server
identifier and classless routes) and is otherwise dropped, so a bad domain name or MTU
costs the server that option, not the lease. A bad classless route refuses the message, as
`dhclient` ignores an offer whose option fails `check_classless_option`: routing from half
a route list is worse than none. A message that is shorter than the header and cookie, has
an `op` other than 1 or 2, an `hlen` over 16, a wrong cookie, an option running past its
field, an overload value other than 1, 2 or 3, a bad required option, or no DHCP message
type, is refused.

The rules beyond RFC 2132's lengths: a mask is contiguous; an MTU is at least 68 (RFC 791,
`dhclient`'s `MIN_MTU`); a classless route has a prefix length of at most 32, the octets
that length needs and a router, and its prefix keeps only its first prefix-length bits
(RFC 3442 section 4); the domain name, without one trailing NUL that some servers add, is
one to six names separated by blanks in at most 256 bytes (`check_search`, after
resolv.conf(5); stricter than `dhclient`, which lets one name that passes `res_hnok`
through at any length), each name's dot-separated labels letters, digits and hyphens that begin
and end with a letter or digit (`res_hnok`). So no control character or other byte from a
server reaches the resolver's configuration or a display.

`encode/1` writes the options of the map in `?OPTIONS`' order, the message type first, all
in the options field, splits a value longer than 255 bytes into instances of 255 (RFC
3396), ends them with the end option and pads the message to BOOTP's 300 bytes (RFC 1542
section 2.1), as relays may drop shorter ones. Decoding what it writes gives back any
record `decode/1` made.
""".

-include("erx_dhcp4_wire.hrl").

-export([decode/1, encode/1]).

-export_type([options/0, message_type/0, route/0, error_reason/0]).

-define(COOKIE, 99, 130, 83, 99).
-define(FIXED_BYTES, 236).
-define(BOOTP_MIN_BYTES, 300).
-define(CHADDR_BYTES, 16).
-define(OPT_PAD, 0).
-define(OPT_OVERLOAD, 52).
-define(OPT_END, 255).
-define(OPT_MAX_CHUNK, 255).
-define(OVERLOAD_FILE, 1).
-define(OVERLOAD_SNAME, 2).
-define(MTU_MIN, 68).
-define(PLEN_MAX, 32).
-define(ROUTE_MIN_BYTES, 5).
-define(SEARCH_BYTES_MAX, 256).
-define(SEARCH_NAMES_MAX, 6).

%% The options the codec knows, in the order it encodes them: {Code, Name}. A name exists
%% only here, so decoding creates no atom.
-define(OPTIONS, [{53, message_type}, {1, subnet_mask}, {121, classless_routes},
                  {3, routers}, {6, dns}, {15, domain_name}, {26, mtu}, {50, requested_ip},
                  {51, lease_time}, {54, server_id}, {55, params}, {58, t1}, {59, t2},
                  {61, client_id}]).

%% The options whose bad value refuses the message: the client cannot do without the first
%% four, and a part of a route list is worse than none. Any other known option with a bad
%% value is dropped, as unknown ones are skipped.
-define(REQUIRED_SOUND, [message_type, subnet_mask, lease_time, server_id, classless_routes]).

-define(MESSAGE_TYPES, [discover, offer, request, decline, ack, nak, release, inform]).

-type message_type() :: discover | offer | request | decline | ack | nak | release | inform.

-doc "A classless static route: destinations in Prefix/Plen go to Router (RFC 3442).".
-type route() :: {Prefix :: <<_:32>>, Plen :: 0..32, Router :: <<_:32>>}.

%% Each known option under its name: addresses are 4-byte binaries, times are seconds,
%% `params` holds the codes of a parameter request list, one byte each, and `domain_name`
%% the names of the domain name option.
-type options() :: #{message_type => message_type(),
                     subnet_mask => <<_:32>>,
                     classless_routes => [route(), ...],
                     routers => [<<_:32>>, ...],
                     dns => [<<_:32>>, ...],
                     domain_name => [binary(), ...],
                     mtu => ?MTU_MIN..16#ffff,
                     requested_ip => <<_:32>>,
                     lease_time => 0..16#ffffffff,
                     server_id => <<_:32>>,
                     params => binary(),
                     t1 => 0..16#ffffffff,
                     t2 => 0..16#ffffffff,
                     client_id => binary()}.

-type error_reason() :: too_short | bad_op | bad_hlen | bad_cookie | truncated_option
                      | {bad_option, 0..255} | no_message_type.

-doc "Decodes one DHCP message, the whole payload of its UDP datagram.".
-spec decode(binary()) -> {ok, #dhcp4{}} | {error, error_reason()}.
decode(<<Op, Htype, Hlen, Hops, Xid:32, Secs:16, Broadcast:1, _:15, Ciaddr:4/binary,
         Yiaddr:4/binary, Siaddr:4/binary, Giaddr:4/binary, Chaddr:?CHADDR_BYTES/binary,
         Sname:64/binary, File:128/binary, Cookie:4/binary, Options/binary>>) ->
    maybe
        {ok, Direction} ?= op(Op),
        ok ?= hlen(Hlen),
        ok ?= cookie(Cookie),
        {ok, Raw} ?= all_options(Options, File, Sname),
        {ok, Known} ?= known_options(Raw),
        ok ?= has_message_type(Known),
        {ok, #dhcp4{op = Direction, htype = Htype, hops = Hops, xid = Xid, secs = Secs,
                    broadcast = Broadcast =:= 1, ciaddr = Ciaddr, yiaddr = Yiaddr,
                    siaddr = Siaddr, giaddr = Giaddr, chaddr = binary:part(Chaddr, 0, Hlen),
                    options = Known}}
    end;
decode(_) ->
    {error, too_short}.

op(1) -> {ok, request};
op(2) -> {ok, reply};
op(_) -> {error, bad_op}.

hlen(Hlen) when Hlen =< ?CHADDR_BYTES -> ok;
hlen(_) -> {error, bad_hlen}.

cookie(<<?COOKIE>>) -> ok;
cookie(_) -> {error, bad_cookie}.

has_message_type(#{message_type := _}) -> ok;
has_message_type(_) -> {error, no_message_type}.

%% The options of the options field and of the fields its overload option names, as
%% {Code => [Data]}, each code's instances in reverse order of arrival (`parse_options`).
all_options(Options, File, Sname) ->
    maybe
        {ok, Raw} ?= raw_options(Options, #{}),
        {ok, Overload} ?= overload(Raw),
        {ok, WithFile} ?= overloaded(Overload band ?OVERLOAD_FILE, File, Raw),
        overloaded(Overload band ?OVERLOAD_SNAME, Sname, WithFile)
    end.

%% Which fields hold more options: 1 the file field, 2 the sname field, 3 both. Only the
%% options field's overload option counts; one in another field is read and ignored.
overload(#{?OPT_OVERLOAD := Instances}) ->
    case iolist_to_binary(Instances) of
        <<Fields>> when Fields >= 1, Fields =< 3 -> {ok, Fields};
        _ -> {error, {bad_option, ?OPT_OVERLOAD}}
    end;
overload(_) ->
    {ok, 0}.

overloaded(0, _Field, Raw) -> {ok, Raw};
overloaded(_, Field, Raw) -> raw_options(Field, Raw).

raw_options(<<>>, Acc) -> {ok, Acc};
raw_options(<<?OPT_END, _/binary>>, Acc) -> {ok, Acc};
raw_options(<<?OPT_PAD, Rest/binary>>, Acc) -> raw_options(Rest, Acc);
raw_options(<<Code, Len, Data:Len/binary, Rest/binary>>, Acc) ->
    raw_options(Rest, maps:update_with(Code, fun(Seen) -> [Data | Seen] end, [Data], Acc));
raw_options(_, _) -> {error, truncated_option}.

known_options(Raw) -> known_options(?OPTIONS, Raw, #{}).

known_options([], _Raw, Known) ->
    {ok, Known};
known_options([{Code, _Name} | Rest], Raw, Known) when not is_map_key(Code, Raw) ->
    known_options(Rest, Raw, Known);
known_options([{Code, Name} | Rest], Raw, Known) ->
    Joined = iolist_to_binary(lists:reverse(map_get(Code, Raw))),
    case {value(Name, Joined), lists:member(Name, ?REQUIRED_SOUND)} of
        {{ok, Decoded}, _} -> known_options(Rest, Raw, Known#{Name => Decoded});
        {error, true} -> {error, {bad_option, Code}};
        {error, false} -> known_options(Rest, Raw, Known)
    end.

%% One known option's joined value, checked against its rule.
value(message_type, <<Type>>) when Type >= 1, Type =< length(?MESSAGE_TYPES) ->
    {ok, lists:nth(Type, ?MESSAGE_TYPES)};
value(subnet_mask, <<Mask:32>> = Bytes) ->
    %% A mask is contiguous: its complement plus one is a power of two (RFC 950).
    Host = bnot Mask band 16#ffffffff,
    case Host band (Host + 1) of
        0 -> {ok, Bytes};
        _ -> error
    end;
value(classless_routes, Bytes) when byte_size(Bytes) >= ?ROUTE_MIN_BYTES ->
    classless_routes(Bytes, []);
value(Name, Bytes) when Name =:= routers; Name =:= dns ->
    addresses(Bytes);
value(domain_name, Bytes) ->
    search_list(without_final_nul(Bytes));
value(mtu, <<Mtu:16>>) when Mtu >= ?MTU_MIN -> {ok, Mtu};
value(Name, <<Seconds:32>>) when Name =:= lease_time; Name =:= t1; Name =:= t2 -> {ok, Seconds};
value(Name, <<_:32>> = Addr) when Name =:= requested_ip; Name =:= server_id -> {ok, Addr};
value(params, Codes) when byte_size(Codes) >= 1 -> {ok, Codes};
value(client_id, Id) when byte_size(Id) >= 2 -> {ok, Id};
value(_, _) -> error.

addresses(Bytes) when Bytes =/= <<>>, byte_size(Bytes) rem 4 =:= 0 ->
    {ok, [Addr || <<Addr:4/binary>> <= Bytes]};
addresses(_) ->
    error.

%% RFC 3442's routes, each a prefix length, the octets of the prefix that length needs and
%% a router (`check_classless_option`): a length over 32 or a route cut short is an error,
%% and the prefix's bits past its length are cleared (RFC 3442 section 4).
classless_routes(<<>>, Routes) ->
    {ok, lists:reverse(Routes)};
classless_routes(<<Plen, Rest/binary>>, Routes) when Plen =< ?PLEN_MAX ->
    Octets = (Plen + 7) div 8,
    case Rest of
        <<Significant:Octets/binary, Router:4/binary, More/binary>> ->
            <<Prefix:32>> = <<Significant/binary, 0:((4 - Octets) * 8)>>,
            Mask = (16#ffffffff bsl (32 - Plen)) band 16#ffffffff,
            classless_routes(More, [{<<(Prefix band Mask):32>>, Plen, Router} | Routes]);
        _ ->
            error
    end;
classless_routes(_, _) ->
    error.

%% Some servers end a text option with a NUL; `option_as_string` drops one final NUL and
%% keeps any other, which the name check then refuses.
without_final_nul(<<>>) -> <<>>;
without_final_nul(Bytes) ->
    case binary:last(Bytes) of
        0 -> binary:part(Bytes, 0, byte_size(Bytes) - 1);
        _ -> Bytes
    end.

%% `check_search`: names separated by spaces or tabs, one to six of them in at most 256
%% bytes, each a host name.
search_list(Text) when byte_size(Text) =< ?SEARCH_BYTES_MAX ->
    case binary:split(Text, [<<" ">>, <<"\t">>], [global, trim_all]) of
        Names when Names =/= [], length(Names) =< ?SEARCH_NAMES_MAX ->
            case lists:all(fun host_name/1, Names) of
                true -> {ok, Names};
                false -> error
            end;
        _ ->
            error
    end;
search_list(_) ->
    error.

%% `res_hnok`: every label between dots is empty or letters, digits and hyphens that begin
%% and end with a letter or digit (RFC 1123 section 2.1).
host_name(Name) ->
    lists:all(fun label/1, binary:split(Name, <<".">>, [global])).

label(<<>>) ->
    true;
label(Label) ->
    border_byte(binary:first(Label)) andalso border_byte(binary:last(Label))
        andalso lists:all(fun(Byte) -> border_byte(Byte) orelse Byte =:= $- end,
                          binary_to_list(Label)).

border_byte(Byte) ->
    (Byte >= $a andalso Byte =< $z) orelse (Byte >= $A andalso Byte =< $Z)
        orelse (Byte >= $0 andalso Byte =< $9).

-doc "Encodes a DHCP message, padded to 300 bytes.".
-spec encode(#dhcp4{}) -> binary().
encode(#dhcp4{op = Op, htype = Htype, hops = Hops, xid = Xid, secs = Secs,
              broadcast = Broadcast, ciaddr = Ciaddr, yiaddr = Yiaddr, siaddr = Siaddr,
              giaddr = Giaddr, chaddr = Chaddr, options = Options})
  when byte_size(Chaddr) =< ?CHADDR_BYTES ->
    Hlen = byte_size(Chaddr),
    Pad = (?CHADDR_BYTES - Hlen) * 8,
    Message = iolist_to_binary(
                [<<(op_code(Op)), Htype, Hlen, Hops, Xid:32, Secs:16,
                   (flag(Broadcast)):1, 0:15, Ciaddr/binary, Yiaddr/binary, Siaddr/binary,
                   Giaddr/binary, Chaddr/binary, 0:Pad, 0:(64 * 8), 0:(128 * 8), ?COOKIE>>,
                 [encode_option(Code, encode_value(Name, map_get(Name, Options)))
                  || {Code, Name} <- ?OPTIONS, is_map_key(Name, Options)],
                 ?OPT_END]),
    Short = max(0, ?BOOTP_MIN_BYTES - byte_size(Message)),
    <<Message/binary, 0:(Short * 8)>>.

op_code(request) -> 1;
op_code(reply) -> 2.

flag(true) -> 1;
flag(false) -> 0.

encode_value(message_type, Type) -> <<(index(Type, ?MESSAGE_TYPES, 1))>>;
encode_value(classless_routes, Routes) ->
    << <<Plen, (binary:part(Prefix, 0, (Plen + 7) div 8))/binary, Router/binary>>
       || {Prefix, Plen, Router} <- Routes >>;
encode_value(Name, Addrs) when Name =:= routers; Name =:= dns -> iolist_to_binary(Addrs);
encode_value(domain_name, Names) -> iolist_to_binary(lists:join(<<" ">>, Names));
encode_value(mtu, Mtu) -> <<Mtu:16>>;
encode_value(Name, Seconds) when Name =:= lease_time; Name =:= t1; Name =:= t2 -> <<Seconds:32>>;
encode_value(_, Bytes) when is_binary(Bytes) -> Bytes.

index(Type, [Type | _], At) -> At;
index(Type, [_ | Rest], At) -> index(Type, Rest, At + 1).

encode_option(Code, Value) when byte_size(Value) > ?OPT_MAX_CHUNK ->
    <<Chunk:?OPT_MAX_CHUNK/binary, Rest/binary>> = Value,
    [<<Code, ?OPT_MAX_CHUNK, Chunk/binary>> | encode_option(Code, Rest)];
encode_option(Code, Value) ->
    <<Code, (byte_size(Value)), Value/binary>>.
