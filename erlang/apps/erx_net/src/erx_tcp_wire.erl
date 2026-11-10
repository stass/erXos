%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/tcp.h
%% Copyright (c) 1982, 1986, 1993
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
%%
%% FreeBSD: sys/netinet/tcp_input.c
%% Copyright (c) 1982, 1986, 1988, 1990, 1993, 1994, 1995
%% The Regents of the University of California.  All rights reserved.
%% Copyright (c) 2007-2008,2010
%% Swinburne University of Technology, Melbourne, Australia.
%% Copyright (c) 2009-2010 Lawrence Stewart <lstewart@freebsd.org>
%% Copyright (c) 2010 The FreeBSD Foundation
%% Copyright (c) 2010-2011 Juniper Networks, Inc.
%% All rights reserved.
%%
%% Portions of this software were developed at the Centre for Advanced Internet
%% Architectures, Swinburne University of Technology, by Lawrence Stewart,
%% James Healy and David Hayes, made possible in part by a grant from the Cisco
%% University Research Program Fund at Community Foundation Silicon Valley.
%%
%% Portions of this software were developed at the Centre for Advanced
%% Internet Architectures, Swinburne University of Technology, Melbourne,
%% Australia by David Hayes under sponsorship from the FreeBSD Foundation.
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
%% FreeBSD: sys/netinet/tcp_output.c
%% Copyright (c) 1982, 1986, 1988, 1990, 1993, 1995
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

-module(erx_tcp_wire).
-moduledoc """
The TCP codec (RFC 9293) with its options, translated from FreeBSD at the commit NOTICE-freebsd
records: the header checks of `tcp_input_with_port` in sys/netinet/tcp_input.c, its option
parser `tcp_dooptions`, and the option writer `tcp_addoptions` in sys/netinet/tcp_output.c,
with the header layout and constants of sys/netinet/tcp.h (docs/design-network-stack.md,
"Packets become checked records once").

`decode/2` is total over its segment: it returns `{ok, #tcp{}, Payload}` or `{error,
Reason}` and never raises. It makes the checks `tcp_input_with_port` makes on the segment
before its connection lookup, in their order:

* a 20-byte header (`tcps_rcvshort`);
* the checksum over the pseudo-header and the whole segment (`tcps_rcvbadsum`);
* a data offset from 5 words to the bytes delivered (`tcps_rcvbadoff`).

Options never refuse a segment, as in `tcp_dooptions`: a malformed one ends the walk, keeping
what came before it, and one of the wrong length, of an unknown kind, or not allowed with the
segment's SYN flag is passed over. The decoder applies the SYN rule itself from the header's
flags, as `tcp_input_with_port` and `tcp_do_segment` pass `TO_SYN` exactly when the segment
carries SYN. The one check of `tcp_input_with_port` that differs by IP version, refusing an
unspecified source address (`ips_badaddr`, `ip6s_badscope`), reads the IP header, which the
codec does not see; it belongs to the step that hands the segment to TCP (TODO.md). So the
decoder takes no version.

TCP-MD5 signatures (RFC 2385) are outside the stack (docs/design-network-stack.md, "Outside
the stack"): the decoder records that a segment carried the option, as `tcp_dooptions` does,
so that the syncache refuses it as FreeBSD does for a listener without TCP-MD5, and the
encoder never writes it. Fast Open's option is passed over, as FreeBSD passes it over with
Fast Open disabled, its default.

The 32-bit numbers stay as received; erx_tcp_seq lifts them inside the connection.
""".

-include("erx_tcp_wire.hrl").

-export([decode/2, encode/3, optlen/1]).

-export_type([reason/0]).

-doc "Why `decode/2` refused a segment: a closed set, after FreeBSD's `tcpstat` counters where it has one.".
-type reason() :: too_short      % tcps_rcvshort
                | too_long       % more than an IP packet delivers
                | bad_sum        % tcps_rcvbadsum
                | bad_off.       % tcps_rcvbadoff

%% sizeof(struct tcphdr), in bytes and in the data offset's 32-bit words.
-define(TCP_HDR_LEN, 20).
-define(TCP_HDR_WORDS, 5).
%% TCP_MAXOLEN: the most option bytes a header holds, (15 - 5) words.
-define(TCP_MAXOLEN, 40).
%% The largest segment an IP packet delivers, and the most inet_csum/2 sums in a call.
-define(TCP_MAXSEG, 16#ffff).
-define(TCP_MAX_WINSHIFT, 14).

-define(TCPOPT_EOL, 0).
-define(TCPOPT_NOP, 1).
-define(TCPOPT_MAXSEG, 2).
-define(TCPOPT_WINDOW, 3).
-define(TCPOPT_SACK_PERMITTED, 4).
-define(TCPOPT_SACK, 5).
-define(TCPOPT_TIMESTAMP, 8).
-define(TCPOPT_SIGNATURE, 19).
-define(TCPOLEN_MAXSEG, 4).
-define(TCPOLEN_WINDOW, 3).
-define(TCPOLEN_SACK_PERMITTED, 2).
-define(TCPOLEN_SACKHDR, 2).
-define(TCPOLEN_SACK, 8).
-define(TCPOLEN_TIMESTAMP, 10).
-define(TCPOLEN_SIGNATURE, 18).
%% Where tcp_addoptions starts each option: after no-operation bytes, at an option length
%% that is Rem modulo Mod, as {Mod, Rem}.
-define(ALIGN_MSS, {4, 0}).
-define(ALIGN_WINDOW, {2, 1}).
-define(ALIGN_SACK_PERMITTED, {2, 0}).
-define(ALIGN_TIMESTAMP, {4, 2}).
-define(ALIGN_SACK, {4, 2}).

-doc """
Decodes the TCP segment in Segment, the payload of its IP packet, with `PseudoSum` the
partial sum of its pseudo-header over `byte_size(Segment)` (`erx_ip4_wire:pseudo_sum/4`,
`erx_ip6_wire:pseudo_sum/4`), as for every decoder above IP. Translates the checks of
`tcp_input_with_port` before its lookup, then `tcp_dooptions` over the options. A sum outside
0..16#ffff raises, since the IP layer computes it.
""".
-spec decode(0..16#ffff, binary()) -> {ok, #tcp{}, Payload :: binary()} | {error, reason()}.
decode(_, Segment) when not is_binary(Segment); byte_size(Segment) < ?TCP_HDR_LEN ->
    {error, too_short};
decode(_, Segment) when byte_size(Segment) > ?TCP_MAXSEG ->
    {error, too_long};
decode(PseudoSum, Segment) ->
    case erx_bytes:inet_csum(PseudoSum, Segment) of
        16#ffff -> header(Segment);
        _ -> {error, bad_sum}
    end.

%% The checksum is right, so the fields may be read. The sum of a right segment is 16#ffff and
%% never 0, since the pseudo-header's protocol word is nonzero.
header(<<_:96, Off:4, _:12, _/binary>> = Segment) when Off < ?TCP_HDR_WORDS; Off * 4 > byte_size(Segment) ->
    {error, bad_off};
header(<<Sport:16, Dport:16, Seq:32, Ack:32, Off:4, Flags:12, Win:16, _Sum:16, Urp:16,
         Rest/binary>>) ->
    <<Options:(Off * 4 - ?TCP_HDR_LEN)/binary, Payload/binary>> = Rest,
    Opts = options(Options, Flags band ?TH_SYN =/= 0, #tcp_opts{}),
    {ok, #tcp{sport = Sport, dport = Dport, seq = Seq, ack = Ack, flags = Flags, win = Win,
              urp = Urp, opts = Opts},
     Payload}.

-doc """
Translates `tcp_dooptions`: walks the option bytes, stopping at end-of-options, at an option
whose length byte is missing, below 2 or past the end, and records each known option of the
right length that the segment's SYN flag allows. A later option of a kind overwrites an
earlier one, as in FreeBSD.
""".
-spec options(binary(), Syn :: boolean(), #tcp_opts{}) -> #tcp_opts{}.
options(<<?TCPOPT_EOL, _/binary>>, _, Opts) ->
    Opts;
options(<<?TCPOPT_NOP, Rest/binary>>, Syn, Opts) ->
    options(Rest, Syn, Opts);
options(<<Kind, Len, _/binary>> = Bytes, Syn, Opts) when Len >= 2, Len =< byte_size(Bytes) ->
    <<_:16, Body:(Len - 2)/binary, Rest/binary>> = Bytes,
    options(Rest, Syn, option(Kind, Body, Syn, Opts));
options(_EndOrMalformed, _, Opts) ->
    Opts.

option(?TCPOPT_MAXSEG, <<Mss:16>>, true, Opts) ->
    Opts#tcp_opts{mss = Mss};
option(?TCPOPT_WINDOW, <<Shift>>, true, Opts) ->
    Opts#tcp_opts{wscale = min(Shift, ?TCP_MAX_WINSHIFT)};
option(?TCPOPT_TIMESTAMP, <<TsVal:32, TsEcr:32>>, _, Opts) ->
    Opts#tcp_opts{ts = {TsVal, TsEcr}};
%% V_tcp_do_sack is 1 by default and the stack offers SACK always (design, "Defaults kept").
option(?TCPOPT_SACK_PERMITTED, <<>>, true, Opts) ->
    Opts#tcp_opts{sack_permitted = true};
option(?TCPOPT_SACK, Blocks, false, Opts)
  when Blocks =/= <<>>, byte_size(Blocks) rem ?TCPOLEN_SACK =:= 0 ->
    Opts#tcp_opts{sacks = [{Start, End} || <<Start:32, End:32>> <= Blocks]};
option(?TCPOPT_SIGNATURE, Digest, _, Opts)
  when byte_size(Digest) =:= ?TCPOLEN_SIGNATURE - 2 ->
    Opts#tcp_opts{signature = true};
option(_Other, _, _, Opts) ->
    Opts.

-doc """
Encodes a segment carrying Payload. `PseudoSum` is the partial sum of its pseudo-header with
the length field zero (`pseudo_sum(Src, Dst, 0, ?IPPROTO_TCP)`): the encoder adds the
segment's length, which only it knows before encoding, since the options decide the header's
length. The length is one 16-bit word of either pseudo-header, so adding it to the sum is
writing it there. Raises `badarg` for a segment over 65535 bytes, since the stack encodes only
records it built.
""".
-spec encode(#tcp{}, iodata(), 0..16#ffff) -> iodata().
encode(#tcp{sport = Sport, dport = Dport, seq = Seq, ack = Ack, flags = Flags, win = Win,
            urp = Urp, opts = Opts}, Payload, PseudoSum) ->
    Options = add_options(Opts),
    Off = ?TCP_HDR_WORDS + byte_size(Options) div 4,
    Len = Off * 4 + iolist_size(Payload),
    Len =< ?TCP_MAXSEG orelse erlang:error(badarg),
    Head = <<Sport:16, Dport:16, Seq:32, Ack:32, Off:4, Flags:12, Win:16>>,
    Tail = <<Urp:16, Options/binary>>,
    Sum = bnot erx_bytes:inet_csum(PseudoSum, [<<Len:16>>, Head, Tail, Payload]) band 16#ffff,
    [Head, <<Sum:16>>, Tail, Payload].

-doc """
The bytes `encode/3` gives the options, a multiple of four: the `optlen` `tcp_addoptions`
returns, which output takes from the segment's payload room.
""".
-spec optlen(#tcp_opts{}) -> non_neg_integer().
optlen(#tcp_opts{} = Opts) -> byte_size(add_options(Opts)).

-doc """
Translates `tcp_addoptions`: the options in FreeBSD's order (MSS, window scale,
SACK-permitted, timestamps, SACK; never a signature), each after the no-operation bytes that align it as FreeBSD
aligns it, an option that does not fit left out (its alignment kept, as FreeBSD keeps it),
as many SACK blocks as fit, and end-of-options and zeros to a 4-byte boundary.

The options of almost every segment of an established connection are one of the two
layouts a run's frames share (docs/design-network-fastpath.md, "A run"): none, or the
timestamps alone, which the translation lays out as `NOP NOP TS` (`tcp_output.c:1794`).
Output, the frame layer and `encode/3` each ask for a segment's options, so those two are
written directly; `erx_tcp_wire_tests` checks them against the fold over random option
sets.
""".
-spec add_options(#tcp_opts{}) -> binary().
add_options(#tcp_opts{mss = none, wscale = none, sack_permitted = false, ts = none, sacks = []}) ->
    <<>>;
add_options(#tcp_opts{mss = none, wscale = none, sack_permitted = false, ts = {TsVal, TsEcr},
                      sacks = []}) ->
    <<?TCPOPT_NOP, ?TCPOPT_NOP, ?TCPOPT_TIMESTAMP, ?TCPOLEN_TIMESTAMP, TsVal:32, TsEcr:32>>;
add_options(#tcp_opts{} = Opts) ->
    Options = lists:foldl(fun(Step, Acc) -> add_option(Step, Opts, Acc) end, <<>>,
                          [mss, wscale, sack_permitted, ts, sacks]),
    <<Options/binary, 0:((4 - byte_size(Options) rem 4) rem 4 * 8)>>.

%% One case of tcp_addoptions' switch: the option if the segment carries it, else nothing.
add_option(mss, #tcp_opts{mss = none}, Acc) -> Acc;
add_option(mss, #tcp_opts{mss = Mss}, Acc) ->
    add(Acc, ?ALIGN_MSS, <<?TCPOPT_MAXSEG, ?TCPOLEN_MAXSEG, Mss:16>>);
add_option(wscale, #tcp_opts{wscale = none}, Acc) -> Acc;
add_option(wscale, #tcp_opts{wscale = Shift}, Acc) ->
    add(Acc, ?ALIGN_WINDOW, <<?TCPOPT_WINDOW, ?TCPOLEN_WINDOW, Shift>>);
add_option(sack_permitted, #tcp_opts{sack_permitted = false}, Acc) -> Acc;
add_option(sack_permitted, #tcp_opts{sack_permitted = true}, Acc) ->
    add(Acc, ?ALIGN_SACK_PERMITTED, <<?TCPOPT_SACK_PERMITTED, ?TCPOLEN_SACK_PERMITTED>>);
add_option(ts, #tcp_opts{ts = none}, Acc) -> Acc;
add_option(ts, #tcp_opts{ts = {TsVal, TsEcr}}, Acc) ->
    add(Acc, ?ALIGN_TIMESTAMP, <<?TCPOPT_TIMESTAMP, ?TCPOLEN_TIMESTAMP, TsVal:32, TsEcr:32>>);
add_option(sacks, #tcp_opts{sacks = []}, Acc) -> Acc;
add_option(sacks, #tcp_opts{sacks = Sacks}, Acc) ->
    add_sack(Acc, Sacks).

%% One option after its alignment. FreeBSD's `!optlen` tests add nothing, since a Rem of 1
%% or 2 already excludes 0. A full option area takes nothing more, as FreeBSD's loop breaks.
add(Acc, _, _) when byte_size(Acc) =:= ?TCP_MAXOLEN ->
    Acc;
add(Acc, Alignment, Option) ->
    Aligned = align(Acc, Alignment),
    case ?TCP_MAXOLEN - byte_size(Aligned) >= byte_size(Option) of
        true -> <<Aligned/binary, Option/binary>>;
        false -> Aligned
    end.

add_sack(Acc, _) when byte_size(Acc) =:= ?TCP_MAXOLEN ->
    Acc;
add_sack(Acc, Sacks) ->
    Aligned = align(Acc, ?ALIGN_SACK),
    Room = (?TCP_MAXOLEN - byte_size(Aligned) - ?TCPOLEN_SACKHDR) div ?TCPOLEN_SACK,
    case lists:sublist(Sacks, max(Room, 0)) of
        [] -> Aligned;
        Fit ->
            Blocks = << <<Start:32, End:32>> || {Start, End} <- Fit >>,
            <<Aligned/binary, ?TCPOPT_SACK, (?TCPOLEN_SACKHDR + byte_size(Blocks)), Blocks/binary>>
    end.

%% No-operation bytes until the length so far is Rem modulo Mod.
align(Acc, {Mod, Rem}) when byte_size(Acc) rem Mod =:= Rem -> Acc;
align(Acc, Alignment) -> align(<<Acc/binary, ?TCPOPT_NOP>>, Alignment).
