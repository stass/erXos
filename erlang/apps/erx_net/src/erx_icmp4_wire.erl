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

-module(erx_icmp4_wire).
-moduledoc """
The ICMPv4 codec (RFC 792), translated from FreeBSD's `icmp_input` in
sys/netinet/ip_icmp.c at the commit NOTICE-freebsd records
(docs/design-network-stack.md, "Packets become checked records once" and "IPv4 and ARP").

`decode/1` is total: it returns `{ok, #icmp4{}, Rest}` or `{error, Reason}` and never
raises. It makes the checks `icmp_input` makes before it acts on a message: the 8 bytes
of `ICMP_MINLEN`; the checksum over the message alone, as RFC 792 defines it (ICMPv4 has no
pseudo-header), checked before any other field is read; then, for the types `icmp_input`
handles, the codes it accepts and the length it requires: an error message (unreachable,
redirect, time exceeded, parameter problem) quotes an IP header of at least 20 bytes and 8
bytes beyond it (`ICMP_ADVLEN`), and a timestamp request has the 20 bytes of `ICMP_TSLEN`.
FreeBSD drops an error message of a bad length, and hands a message with a bad code, or a
redirect or timestamp request of a bad length, to raw sockets without acting on it; this
stack has no raw ICMP sockets, so the decoder refuses them all. Messages of the other types, which
`icmp_input` passes to raw sockets alone, decode as `other`.

Rest is what follows the part the decoder reads: an error message's invoking packet, an
echo's data, a timestamp request's bytes past its three timestamps, and the body of an
`other` message after its first four bytes.

The checks that need more than the message (an error quoting a multicast or unspecified
address, an echo to a broadcast address, the rate limits) are erx_icmp4's.
""".

-include("erx_icmp4_wire.hrl").

-export([decode/1, encode/2]).

-export_type([msg/0, reason/0]).

-doc """
The fields of a message by its kind. An error message keeps its second word: the next-hop
MTU in its low 16 bits for fragmentation needed (RFC 1191), the pointer in its top byte for
a parameter problem, unused otherwise. A redirect keeps its gateway address. A timestamp
request keeps its identifier, sequence number and the three timestamps of RFC 792.
""".
-type msg() :: {error, Word :: 0..16#ffffffff}
             | {redirect, Gateway :: <<_:32>>}
             | {echo, Id :: 0..16#ffff, Seq :: 0..16#ffff}
             | {timestamp, Id :: 0..16#ffff, Seq :: 0..16#ffff, Originate :: 0..16#ffffffff,
                Receive :: 0..16#ffffffff, Transmit :: 0..16#ffffffff}
             | other.

-doc "Why `decode/1` refused a message: a closed set, after FreeBSD's `icmpstat` counters.".
-type reason() :: too_short      % icps_tooshort
                | bad_sum        % icps_checksum
                | bad_code       % icps_badcode
                | bad_length.    % icps_badlen

-define(ICMP_MINLEN, 8).
%% inet_csum/2 sums at most 64 KiB a call; no IPv4 datagram carries more than 65535 bytes.
-define(MAX_MESSAGE, 16#ffff).
-define(IP_HDR_WORDS, 5).
-define(IS_ERROR(Type), (Type =:= ?ICMP_UNREACH orelse Type =:= ?ICMP_REDIRECT orelse
                         Type =:= ?ICMP_TIMXCEED orelse Type =:= ?ICMP_PARAMPROB)).

-doc """
Decodes one ICMPv4 message, the payload of its IPv4 datagram. Translates the checks of
`icmp_input` in its order: the length, the checksum, then each type's code and length.
""".
-spec decode(binary()) -> {ok, #icmp4{}, Rest :: binary()} | {error, reason()}.
decode(Message) when not is_binary(Message); byte_size(Message) < ?ICMP_MINLEN ->
    {error, too_short};
decode(Message) when byte_size(Message) > ?MAX_MESSAGE ->
    {error, bad_length};
decode(<<Type, Code, _Sum:16, Body/binary>> = Message) ->
    case erx_bytes:inet_csum(0, Message) of
        16#ffff -> message(Type, Code, Body);
        _ -> {error, bad_sum}
    end.

%% icmp_input's switch on the type: the code first, then the length.
message(Type, Code, <<Word:32, Invoking/binary>>) when ?IS_ERROR(Type) ->
    maybe
        true ?= Code =< max_code(Type) orelse {error, bad_code},
        true ?= quotes_header(Invoking) orelse {error, bad_length},
        {ok, #icmp4{type = Type, code = Code, msg = error_msg(Type, Word)}, Invoking}
    end;
message(Type, Code, <<Id:16, Seq:16, Data/binary>>) when Type =:= ?ICMP_ECHO; Type =:= ?ICMP_ECHOREPLY ->
    {ok, #icmp4{type = Type, code = Code, msg = {echo, Id, Seq}}, Data};
message(?ICMP_TSTAMP = Type, Code, <<Id:16, Seq:16, Orig:32, Recv:32, Xmit:32, More/binary>>) ->
    {ok, #icmp4{type = Type, code = Code, msg = {timestamp, Id, Seq, Orig, Recv, Xmit}}, More};
message(?ICMP_TSTAMP, _, _) ->
    {error, bad_length};
message(Type, Code, Body) ->
    {ok, #icmp4{type = Type, code = Code, msg = other}, Body}.

%% The highest code icmp_input accepts for each error type: ICMP_UNREACH_PRECEDENCE_CUTOFF,
%% the redirect's four codes, ICMP_TIMXCEED_REASS and ICMP_PARAMPROB_LENGTH.
max_code(?ICMP_UNREACH) -> 15;
max_code(?ICMP_REDIRECT) -> 3;
max_code(?ICMP_TIMXCEED) -> 1;
max_code(?ICMP_PARAMPROB) -> 2.

%% icmp_input's length check on an error message: the invoking packet holds an IP header
%% of at least 20 bytes and the 8 bytes after it (ICMP_ADVLENMIN and ICMP_ADVLEN).
quotes_header(<<_:4, Hl:4, _/binary>> = Invoking) ->
    Hl >= ?IP_HDR_WORDS andalso byte_size(Invoking) >= Hl * 4 + 8;
quotes_header(_) ->
    false.

error_msg(?ICMP_REDIRECT, Word) -> {redirect, <<Word:32>>};
error_msg(_, Word) -> {error, Word}.

-doc """
Encodes a message followed by Rest, with its checksum over the message. Raises `badarg`
for a message over 65535 bytes, since the stack encodes only records it built.
""".
-spec encode(#icmp4{}, iodata()) -> iodata().
encode(#icmp4{type = Type, code = Code, msg = Msg}, Rest) ->
    Tail = [body(Msg), Rest],
    4 + iolist_size(Tail) =< ?MAX_MESSAGE orelse erlang:error(badarg),
    Sum = bnot erx_bytes:inet_csum(0, [<<Type, Code, 0:16>>, Tail]) band 16#ffff,
    [<<Type, Code, Sum:16>>, Tail].

body({error, Word}) -> <<Word:32>>;
body({redirect, <<_:32>> = Gateway}) -> Gateway;
body({echo, Id, Seq}) -> <<Id:16, Seq:16>>;
body({timestamp, Id, Seq, Orig, Recv, Xmit}) -> <<Id:16, Seq:16, Orig:32, Recv:32, Xmit:32>>;
body(other) -> <<>>.
