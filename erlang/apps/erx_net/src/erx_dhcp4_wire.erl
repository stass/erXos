%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dhcp4_wire).
-moduledoc """
The DHCP message codec (RFC 2131 section 2, with RFC 2132's options and RFC 3396's long
options; docs/design-network-stack.md, "Addresses and routes"), written from the RFCs. A
message arrives as the payload of a UDP datagram that erx_udp_wire has already checked, so
this decoder checks no sum of its own; it is the only maker of a received `#dhcp4{}`.

`decode/1` takes the fixed 236-byte header, the magic cookie and the options. An option is
a code, a length and that many bytes; pad (0) is skipped and end (255) ends the options,
and so does the end of the message, which some servers send without an end option. The
instances of one code are joined in order into one value (RFC 3396). Only the options of
`?OPTIONS` are kept, each under its own name and checked against RFC 2132's rules for its
length and value; every other option is skipped unread. A known option that breaks its
rule refuses the message when it is one of `?REQUIRED_SOUND` (the message type, mask,
lease time and server identifier) and is otherwise dropped, so a bad domain name or MTU
costs the server that option, not the lease. A message that is shorter than the header
and cookie, has an `op` other than 1 or 2, an `hlen` over 16, a wrong cookie, an option
running past the message, a bad required option, or no DHCP message type, is refused.
The option overload of RFC 2132 9.3, which moves options into
the `sname` and `file` fields, is not read: those fields are skipped.

`encode/1` writes the options of the map in `?OPTIONS`' order, the message type first,
splits a value longer than 255 bytes into instances of 255 (RFC 3396), ends them with the
end option and pads the message to BOOTP's 300 bytes (RFC 1542 section 2.1), as relays
may drop shorter ones. Decoding what it writes gives back any record `decode/1` made.
""".

-include("erx_dhcp4_wire.hrl").

-export([decode/1, encode/1]).

-export_type([options/0, message_type/0, error_reason/0]).

-define(COOKIE, 99, 130, 83, 99).
-define(FIXED_BYTES, 236).
-define(BOOTP_MIN_BYTES, 300).
-define(CHADDR_BYTES, 16).
-define(OPT_PAD, 0).
-define(OPT_END, 255).
-define(OPT_MAX_CHUNK, 255).
-define(DOMAIN_MAX, 253).
-define(MTU_MIN, 68).

%% The options the codec knows, in the order it encodes them: {Code, Name}. A name exists
%% only here, so decoding creates no atom.
-define(OPTIONS, [{53, message_type}, {1, subnet_mask}, {3, routers}, {6, dns},
                  {15, domain_name}, {26, mtu}, {50, requested_ip}, {51, lease_time},
                  {54, server_id}, {55, params}, {58, t1}, {59, t2}, {61, client_id}]).

%% The options whose bad value refuses the message, since the client cannot do without
%% them; any other known option with a bad value is dropped, as unknown ones are skipped.
-define(REQUIRED_SOUND, [message_type, subnet_mask, lease_time, server_id]).

-define(MESSAGE_TYPES, [discover, offer, request, decline, ack, nak, release, inform]).

-type message_type() :: discover | offer | request | decline | ack | nak | release | inform.

%% Each known option under its name: addresses are 4-byte binaries, times are seconds,
%% `params` holds the codes of a parameter request list, one byte each.
-type options() :: #{message_type => message_type(),
                     subnet_mask => <<_:32>>,
                     routers => [<<_:32>>, ...],
                     dns => [<<_:32>>, ...],
                     domain_name => binary(),
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
         _Sname:64/binary, _File:128/binary, Cookie:4/binary, Options/binary>>) ->
    maybe
        {ok, Direction} ?= op(Op),
        ok ?= hlen(Hlen),
        ok ?= cookie(Cookie),
        {ok, Raw} ?= raw_options(Options, #{}),
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

%% The options as {Code => [Data]}, each code's instances in reverse order of arrival.
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

%% One known option's joined value, checked against RFC 2132's rules for it.
value(message_type, <<Type>>) when Type >= 1, Type =< length(?MESSAGE_TYPES) ->
    {ok, lists:nth(Type, ?MESSAGE_TYPES)};
value(subnet_mask, <<Mask:32>> = Bytes) ->
    %% A mask is contiguous: its complement plus one is a power of two (RFC 950).
    Host = bnot Mask band 16#ffffffff,
    case Host band (Host + 1) of
        0 -> {ok, Bytes};
        _ -> error
    end;
value(Name, Bytes) when Name =:= routers; Name =:= dns ->
    addresses(Bytes);
value(domain_name, Bytes) ->
    domain_name(strip_nuls(Bytes));
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

%% Some servers end the domain name with NULs, which dhclient also strips.
strip_nuls(<<>>) -> <<>>;
strip_nuls(Bytes) ->
    case binary:last(Bytes) of
        0 -> strip_nuls(binary:part(Bytes, 0, byte_size(Bytes) - 1));
        _ -> Bytes
    end.

%% A domain name is the letters, digits, hyphens and dots of a host name (RFC 1123
%% section 2.1), at most 253 of them, so no control character or other byte from the server
%% reaches the resolver's configuration or a display.
domain_name(Name) when Name =/= <<>>, byte_size(Name) =< ?DOMAIN_MAX ->
    case lists:all(fun host_name_byte/1, binary_to_list(Name)) of
        true -> {ok, Name};
        false -> error
    end;
domain_name(_) ->
    error.

host_name_byte(Byte) ->
    (Byte >= $a andalso Byte =< $z) orelse (Byte >= $A andalso Byte =< $Z)
        orelse (Byte >= $0 andalso Byte =< $9) orelse Byte =:= $- orelse Byte =:= $..

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
encode_value(Name, Addrs) when Name =:= routers; Name =:= dns -> iolist_to_binary(Addrs);
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
