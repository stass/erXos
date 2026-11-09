%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/tcp_seq.h
%% Copyright (c) 1982, 1986, 1993, 1995
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

-module(erx_tcp_seq).
-moduledoc """
Sequence space: the one place where TCP's 32-bit wire numbers meet the unwrapped integers the
TCP core works in (docs/design-network-stack.md, "Packets become checked records once;
sequence numbers are integers"). It replaces the modular comparisons of FreeBSD's
sys/netinet/tcp_seq.h, at the commit NOTICE-freebsd records, with one conversion each way.

Inside a connection, sequence and acknowledgement numbers, SACK block edges and timestamps
are integers that never wrap. `lift/2` turns a received 32-bit value into such an integer
against a reference the connection holds, and `wire/1` turns an integer back into the 32-bit
value a segment carries. After lifting, ordinary comparisons order the numbers, so no other
module does wrap arithmetic, which a build check enforces (`NetChecks`, rule seq-wrap).
""".

-export([lift/2, wire/1]).

-export_type([wire/0]).

-define(MODULUS, (1 bsl 32)).
-define(HALF, (1 bsl 31)).

-doc "A 32-bit value as a segment carries it: a sequence number, an acknowledgement, a timestamp.".
-type wire() :: 0..16#ffffffff.

-doc """
The integer congruent to Wire modulo 2^32 that lies nearest Reference: the one in
`[Reference - 2^31, Reference + 2^31)`. At exactly 2^31 from Reference the lower one is
taken, as `SEQ_LT(Wire, Reference)` holds there in tcp_seq.h, whose `(int)(a - b) < 0` reads
a distance of 2^31 as negative. Reference is any integer the connection holds (`rcv_nxt`,
`snd_una`, the last timestamp recorded); Wire comes from a decoded segment, so a value
outside 32 bits raises.
""".
-spec lift(wire(), integer()) -> integer().
lift(Wire, Reference) when is_integer(Wire), Wire >= 0, Wire < ?MODULUS, is_integer(Reference) ->
    %% Distance from Reference - 2^31 up to the nearest value congruent to Wire, in
    %% [0, 2^32): band takes the residue for negative differences too.
    Offset = (Wire - Reference + ?HALF) band (?MODULUS - 1),
    Reference - ?HALF + Offset.

-doc "The low 32 bits of an unwrapped integer, the value a segment carries for it.".
-spec wire(integer()) -> wire().
wire(Integer) when is_integer(Integer) ->
    Integer band (?MODULUS - 1).
