%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/tcp_subr.c
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

-module(erx_tcp_isn).
-moduledoc """
Initial sequence numbers and timestamp offsets (docs/design-network-stack.md, "Connection
setup" and "Timers"), translated from `tcp_keyed_hash`, `tcp_new_isn` and
`tcp_new_ts_offset` of FreeBSD's sys/netinet/tcp_subr.c at the commit NOTICE-freebsd records.

Both are a SipHash-2-4 of the connection's four-tuple under a stack-wide secret, so they are
unpredictable to anyone who does not hold it (RFC 6528, RFC 7323 section 5.4). The two
secrets, FreeBSD's `isn_secret` and `ts_offset_secret`, are 16 bytes each, drawn once from
the kernel's entropy by `erx_net_tables` and held together in one `secrets()` value, so they
cannot be swapped or confused. This module draws nothing and reads no clock: both functions
are pure. Whoever holds the secrets computes a connection's two values and hands only those
on, so no connection's state, and no crash report of one, holds a secret.
""".

-export([secrets/2, isn/3, ts_offset/2]).

-export_type([secrets/0, four_tuple/0]).

-record(secrets, {isn :: <<_:128>>, ts :: <<_:128>>}).

-opaque secrets() :: #secrets{}.

-doc """
A connection's local and foreign address and port, both addresses IPv4 (4 bytes) or both
IPv6 (16 bytes), in network byte order as the IP codecs give them.
""".
-type four_tuple() :: {LocalAddr :: binary(), LocalPort :: 0..16#ffff,
                       ForeignAddr :: binary(), ForeignPort :: 0..16#ffff}.

-doc """
The stack's two secrets from two independent 16-byte draws: the ISN key and the timestamp
key. Equal keys are refused, since the difference of an ISN and a timestamp would then
reveal the clocks under the one hash.
""".
-spec secrets(<<_:128>>, <<_:128>>) -> secrets().
secrets(<<_:128>> = IsnKey, <<_:128>> = TsKey) when IsnKey =/= TsKey ->
    #secrets{isn = IsnKey, ts = TsKey}.

-doc """
The initial sequence number of an active open: the four-tuple's keyed hash under the ISN
secret plus a clock, as a 32-bit value (`tcp_new_isn`). FreeBSD's clock is a shared offset
advanced at 1,048,576 a second and by a random step per connection under a lock; here it is
`NowMicro`, the monotonic time in microseconds, RFC 6528's own construction, so the function
needs no shared counter. For one four-tuple the result advances with the clock, so a reused
four-tuple's new connection starts above the old one's sequence space, as TIME-WAIT
recycling expects, as long as the old connection averaged under a byte a microsecond and
the clock has not wrapped 2^32 microseconds (about 71 minutes) since it started. FreeBSD's
reseeding is off by default (`tcp_isn_reseed_interval` 0), and the secret is never reseeded.
""".
-spec isn(secrets(), four_tuple(), integer()) -> erx_tcp_seq:wire().
isn(#secrets{isn = Key}, FourTuple, NowMicro) when is_integer(NowMicro) ->
    erx_tcp_seq:wire(keyed_hash(Key, FourTuple) + NowMicro).

-doc """
The per-connection offset of the timestamp option's clock (`tcp_new_ts_offset` with
FreeBSD's default `tcp_ts_offset_per_conn` = 1, so the ports are hashed too): the four-tuple's
keyed hash under the timestamp secret. The connection's timestamp clock is the monotonic time
in milliseconds plus this offset, an unwrapped integer that `erx_tcp_seq:wire/1` reduces when
a segment carries it.
""".
-spec ts_offset(secrets(), four_tuple()) -> erx_tcp_seq:wire().
ts_offset(#secrets{ts = Key}, FourTuple) ->
    keyed_hash(Key, FourTuple).

%% tcp_keyed_hash: SipHash-2-4 over the foreign port, the local port, the foreign address
%% and the local address, as they lie in FreeBSD's in_conninfo (network byte order), folded
%% to 32 bits as `hash[0] ^ hash[1]` folds the digest's two little-endian words.
keyed_hash(Key, {LAddr, LPort, FAddr, FPort})
  when (byte_size(LAddr) =:= 4 andalso byte_size(FAddr) =:= 4 orelse
        byte_size(LAddr) =:= 16 andalso byte_size(FAddr) =:= 16),
       is_integer(LPort), LPort >= 0, LPort =< 16#ffff,
       is_integer(FPort), FPort >= 0, FPort =< 16#ffff ->
    Digest = erx_bytes:siphash24(Key, [<<FPort:16, LPort:16>>, FAddr, LAddr]),
    <<High:32, Low:32>> = <<Digest:64>>,
    High bxor Low.
