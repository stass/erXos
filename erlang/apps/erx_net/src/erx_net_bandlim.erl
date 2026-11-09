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

-module(erx_net_bandlim).
-moduledoc """
The rate limits on the answers an interface makes to what it receives
(docs/design-network-stack.md, "IPv4 and ARP"): ICMP port unreachable, echo and
timestamp replies, TCP resets to closed ports, and ICMPv6 errors, each at most
`icmplim` (200) a second. Translated from `badport_bandlim` and `icmplim_new_jitter` in
FreeBSD's sys/netinet/ip_icmp.c at the commit NOTICE-freebsd records, over the
one-second window that `counter_ratecheck` keeps.

Each limit counts the answers of one window: the window opens at the first answer after
the previous one ended and lasts a second. Past the limit, every answer of that window is
refused. The limit of each kind is moved by a jitter drawn uniformly from -16..16
(`icmplim_jitter`), and drawn again when a window opens after one that went over the
limit, as `badport_bandlim` does whenever `counter_ratecheck` reports the rate of a window
that exceeded it. So an observer cannot learn the limit exactly, and cannot use it to
count which of its probes reached an open port (Pan et al., CCS 2020).

The value is a pure part of the interface's state. Its generator is split from the
interface's when the interface starts; time is the interface's monotonic clock in
milliseconds.
""".

-export([new/1, check/3]).

-export_type([lim/0, which/0]).

%% icmplim and icmplim_jitter, FreeBSD's defaults; counter_ratecheck's window of hz ticks.
-define(ICMPLIM, 200).
-define(JITTER, 16).
-define(WINDOW_MS, 1000).

-doc """
The kinds of answer limited separately, FreeBSD's `BANDLIM_*` without SCTP's: port and
protocol unreachable, echo replies, timestamp replies, TCP resets, ICMPv6 errors.
""".
-type which() :: icmp_unreach | icmp_echo | icmp_tstamp | tcp_rst | icmp6_unreach.

%% One kind's window: when it opened (none before the first answer), how many answers it
%% counted, and the current jitter (counter_rate and icmplim_curr_jitter[which]). The
%% jitter changes only when a window opens and the count only grows within one, so a
%% window is over its limit exactly when its count exceeds the limit (counter_rate's
%% cr_over).
-record(window, {start = none :: none | integer(), count = 0 :: non_neg_integer(),
                 jitter :: -?JITTER..?JITTER}).

-opaque lim() :: {#{which() => #window{}}, erx_net_rand:gen()}.

-define(KINDS, [icmp_unreach, icmp_echo, icmp_tstamp, tcp_rst, icmp6_unreach]).

-doc "Limits with a jitter drawn for each kind from Gen, as `icmp_bandlimit_init` draws.".
-spec new(erx_net_rand:gen()) -> lim().
new(Gen0) ->
    lists:foldl(fun(Which, {Windows, Gen}) ->
                        {Jitter, Gen1} = jitter(Gen),
                        {Windows#{Which => #window{jitter = Jitter}}, Gen1}
                end, {#{}, Gen0}, ?KINDS).

-doc """
Whether one more answer of kind Which may be sent at time Now (`badport_bandlim` is 0 or
-1). Every call counts, refused or not, as `counter_ratecheck` counts.
""".
-spec check(which(), integer(), lim()) -> {allow | deny, lim()}.
check(Which, Now, {Windows, Gen}) ->
    #window{jitter = Jitter} = W0 = maps:get(Which, Windows),
    {#window{count = Count} = W, Gen1} =
        case W0 of
            #window{start = Start} when Start =:= none; Now - Start >= ?WINDOW_MS ->
                open(W0, Now, ?ICMPLIM + Jitter, Gen);
            _ -> {W0, Gen}
        end,
    Verdict = case Count + 1 > ?ICMPLIM + W#window.jitter of
                  true -> deny;
                  false -> allow
              end,
    {Verdict, {Windows#{Which := W#window{count = Count + 1}}, Gen1}}.

%% counter_ratecheck's reset: a new window, and a new jitter when the window ending went
%% over its limit (the positive rate badport_bandlim answers with icmplim_new_jitter).
open(#window{count = Count}, Now, Limit, Gen) when Count > Limit ->
    {Jitter, Gen1} = jitter(Gen),
    {#window{start = Now, jitter = Jitter}, Gen1};
open(W, Now, _, Gen) ->
    {W#window{start = Now, count = 0}, Gen}.

%% arc4random_uniform(icmplim_jitter * 2 + 1) - icmplim_jitter.
jitter(Gen) ->
    {N, Gen1} = erx_net_rand:uniform(2 * ?JITTER + 1, Gen),
    {N - ?JITTER, Gen1}.
