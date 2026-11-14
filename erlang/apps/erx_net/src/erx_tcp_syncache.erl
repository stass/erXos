%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/tcp_syncache.c
%% Copyright (c) 2001 McAfee, Inc.
%% Copyright (c) 2006,2013 Andre Oppermann, Internet Business Solutions AG
%% All rights reserved.
%%
%% This software was developed for the FreeBSD Project by Jonathan Lemon
%% and McAfee Research, the Security Research Division of McAfee, Inc. under
%% DARPA/SPAWAR contract N66001-01-C-8035 ("CBOSS"), as part of the
%% DARPA CHATS research program. [2001 McAfee, Inc.]
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%% ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.
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

-module(erx_tcp_syncache).
-moduledoc """
The table of half-open passive connections and SYN cookies (docs/design-network-stack.md,
"Connection setup"), translated from `syncache_add`, `syncache_respond`, `syncache_expand`,
`syncache_chkrst`, `syncache_unreach`, `syncache_timer` and the syncookie functions of
FreeBSD's sys/netinet/tcp_syncache.c, with `tcp_challenge_ack_check` of
sys/netinet/tcp_subr.c, at the commit NOTICE-freebsd records.

Each interface process holds one table, bounded at 15,360 entries by default (FreeBSD's 512
buckets of 30). A SYN for a listener makes an entry and draws a SYN-ACK; the ACK that
completes the handshake removes the entry and returns the handshake's result, from which
the interface spawns the connection. Every SYN-ACK's initial sequence number is a SYN
cookie, FreeBSD's default, so the completing ACK can be recognised by its cookie alone. A
SYN that finds the table full pauses it, as `syncache_insert` and `syncache_pause` do: the
table drops every entry and for 15 s answers each SYN with a SYN-ACK alone and checks every
ACK as a cookie, the pause doubling up to 960 s while overflows recur. The pause ends by
time alone, read from each step's `now`, so it needs no timer. The SYN-ACK of an entry is
retransmitted after 1, 3.2 and 7.4 s and the entry dropped at 15.6 s, FreeBSD's limit of
three retransmissions with its backoff, driven by `expired/2` and `next_deadline/1`.

The secrets (the two cookie keys and the timestamp-offset key) are context, not state: the
interface reads them from `erx_net_tables`, which draws and rotates them, and passes them in
with each SYN or ACK. Neither the table nor an entry holds a key, only the values made from
them, the cookie and the timestamp offset, which reach the connection in the handshake's
result. A `secrets()` value keeps its keys in a closure, whose environment a crash report or
`io_lib:format/2` does not print.

Departures from FreeBSD, each recorded in the design: one table per interface, so the
overflow that pauses is the table's rather than a bucket's, the overflow time is the table's
and the pause the interface's rather than the stack's, ending at a whole second of uptime;
the cookie's MAC covers no bucket address; a signed (TCP-MD5) SYN, or a signed ACK under a
cookie, is dropped as a FreeBSD kernel without TCP-MD5 support drops it, and a signed ACK
for an entry is dropped too, where FreeBSD would complete it; and an entry's ICMP errors
only decide its drop, where FreeBSD also sends its later SYN-ACKs without IPv4's DF bit.
Every function is pure.
""".

-include("erx_tcp_wire.hrl").

-export([new/0, new/1, secrets/3, rotate/2, add/6, expand/5, chkrst/4, unreach/3, expired/2,
         next_deadline/1, size/1, cookies_only/2]).

-export_type([syncache/0, secrets/0, conn/0, listener/0, context/0, action/0, handshake/0,
              outcome/0]).

-define(TCP_SYNCACHE_LIMIT, 15360).   % TCP_SYNCACHE_HASHSIZE * TCP_SYNCACHE_BUCKETLIMIT
-define(SYNCACHE_MAXREXMTS, 3).
-define(SYNCOOKIE_LIFETIME, 15).      % seconds, tcp_syncache.h
-define(TCP_SYNCACHE_PAUSE_TIME, ?SYNCOOKIE_LIFETIME).
-define(TCP_SYNCACHE_MAX_BACKOFF, 6). % the longest pause is 15 s << 6, 16 minutes
-define(TCPTV_RTOBASE, 1000).         % tcp_rexmit_initial, ms
-define(TCPTV_MIN, 30).               % tcp_rexmit_min
-define(TCPTV_REXMTMAX, 64000).       % tcp_rexmit_max
-define(TCPTV_CPU_VAR, 200).          % tcp_rexmit_slop
-define(TCP_BACKOFF, {1, 2, 4, 8}).   % tcp_backoff[0..SYNCACHE_MAXREXMTS]
-define(TCP_MAXWIN, 65535).
-define(ACK_WAR_TIME_WINDOW, 1000).   % tcp_ack_war_time_window, ms
-define(ACK_WAR_CNT, 5).              % tcp_ack_war_cnt
-define(UNREACH_REXMTS, 4).           % 3 retransmissions + 1, syncache_unreach
-define(FLOWLABEL_MASK, 16#fffff).
-define(MAC_MASK, 16#ffffff00).

-define(IS_PORT(P), (is_integer(P) andalso P >= 0 andalso P =< 16#ffff)).
%% A four-tuple as conn() describes it, checked where it enters, before any key is used.
-define(IS_CONN(C), (is_tuple(C) andalso tuple_size(C) =:= 4 andalso
                     ?IS_PORT(element(2, C)) andalso ?IS_PORT(element(4, C)) andalso
                     is_binary(element(1, C)) andalso is_binary(element(3, C)) andalso
                     (byte_size(element(1, C)) =:= 4 andalso byte_size(element(3, C)) =:= 4 orelse
                      byte_size(element(1, C)) =:= 16 andalso byte_size(element(3, C)) =:= 16))).

%% tcp_sc_msstab and tcp_sc_wstab: the peer's MSS and window shift a cookie can carry, each
%% rounded down to the nearest entry. Window-shift index 0 means no window-scale option.
-define(MSSTAB, {216, 536, 1200, 1360, 1400, 1440, 1452, 1460}).
-define(WSTAB, {0, 0, 1, 2, 4, 6, 7, 8}).

-doc "A connection's four-tuple, `erx_tcp_isn:four_tuple()`: local address and port, then foreign.".
-type conn() :: erx_tcp_isn:four_tuple().

-doc """
What the listener contributes to a SYN-ACK: its receive buffer (`sol_sbrcv_hiwat`, offered
as the unscaled window up to 65,535) and the window shift it requests (the smallest that
reaches the largest socket buffer). The MSS option is not the listener's: add/6 takes it
for each SYN, from the route to that peer.
""".
-type listener() :: #{rcv_buf := non_neg_integer(), rcv_scale := 0..14}.

-doc "The current monotonic time in milliseconds and the stack's secrets, read by the loop.".
-type context() :: #{now := integer(), secrets := secrets()}.

-doc """
A segment to transmit from `conn()`'s local end, with the IPv6 flow label, the low 20 bits
of the cookie (`syncache_add`). A `challenge_ack` also charges the RST rate limit, as
`tcp_challenge_ack_check` charges `BANDLIM_TCP_RST`, and is sent whatever that answers;
`charge_rst` charges it for a challenge ACK the per-entry limit suppressed, so the limit's
count moves alike whether or not the four-tuple has an entry.
""".
-type action() :: {send | challenge_ack, conn(), #tcp{}, FlowLabel :: 0..16#fffff} | charge_rst.

-doc """
The result of a completed handshake, the fields `syncache_socket` copies into the new
connection: the initial send and receive sequence numbers, the receive window offered, the
peer's MSS (0 when it sent none, which `tcp_mss` reads as the default), the window shifts
(`{SndScale, RcvScale}`, or `none` when not negotiated), SACK permitted, the timestamp to
echo and the connection's timestamp offset (or `none`), ECN, the SYN-ACKs sent for the last
SYN (`sc_rxmits`, 0 for a cookie) and the challenge-ACK window, its end in milliseconds and
the challenge ACKs sent in it (`sc_challenge_ack_end`, `sc_challenge_ack_cnt`).
""".
-type handshake() :: #{iss := erx_tcp_seq:wire(), irs := erx_tcp_seq:wire(),
                       rcv_wnd := 0..16#ffff, peer_mss := 0..16#ffff,
                       wscale := none | {0..14, 0..14}, sack := boolean(),
                       ts := none | {TsRecent :: erx_tcp_seq:wire(), TsOffset :: erx_tcp_seq:wire()},
                       ecn := boolean(),
                       rxmits := non_neg_integer(),
                       challenge := none | {EndMs :: integer(), Sent :: non_neg_integer()}}.

-doc """
What an ACK for a listener leads to (`syncache_expand`'s return): a connection, a silent
drop (-1), or a RST from the caller (0), which tcp_input sends when no connection holds the
four-tuple either.
""".
-type outcome() :: {ok, handshake()} | drop | reset.

-record(keys, {ts :: erx_tcp_isn:secrets(),
               cookie :: {<<_:128>>, <<_:128>>},
               current :: 0 | 1}).

-opaque secrets() :: fun((keys) -> #keys{}).

%% One half-open connection, FreeBSD's struct syncache. irs and iss are wire values;
%% rxttime is the retransmission deadline and rxmits counts the SYN-ACKs sent since the last
%% SYN, as sc_rxmits does.
-record(entry, {irs :: erx_tcp_seq:wire(),
                iss :: erx_tcp_seq:wire(),
                rcv_wnd :: 0..16#ffff,
                mss_opt :: 0..16#ffff,
                peer_mss :: 0..16#ffff,
                wscale :: none | {0..14, 0..14},
                sack :: boolean(),
                ts :: none | {TsReflect :: erx_tcp_seq:wire(), TsOffset :: erx_tcp_seq:wire()},
                ecn :: boolean(),
                rxmits = 0 :: 0..?SYNCACHE_MAXREXMTS + 1,
                rxttime = none :: none | integer(),
                unreach = false :: boolean(),
                ack_war = none :: none | {EpochEnd :: integer(), Count :: non_neg_integer()}}).

%% last_overflow is sch_last_overflow; pause is the end of the last pause and its backoff,
%% FreeBSD's pause_until and pause_backoff. Both are whole seconds of uptime. FreeBSD's
%% paused flag is derived from them: the table is paused while uptime is before the end
%% (cookies_only/2).
-record(syncache, {limit :: non_neg_integer(),
                   entries = #{} :: #{conn() => #entry{}},
                   timers = gb_sets:empty() :: gb_sets:set({integer(), conn()}),
                   last_overflow = none :: none | integer(),
                   pause = none :: none | {Until :: integer(),
                                           Backoff :: 0..?TCP_SYNCACHE_MAX_BACKOFF}}).

-opaque syncache() :: #syncache{}.

-doc "An empty table of FreeBSD's default size, 15,360 entries.".
-spec new() -> syncache().
new() -> new(?TCP_SYNCACHE_LIMIT).

-doc "An empty table holding at most `Limit` entries.".
-spec new(non_neg_integer()) -> syncache().
new(Limit) when is_integer(Limit), Limit >= 0 -> #syncache{limit = Limit}.

-doc """
The stack's secrets: its ISN and timestamp secrets, for the timestamp offset, and two
independent 16-byte cookie keys, the first current (`syncache_init`).
""".
-spec secrets(erx_tcp_isn:secrets(), <<_:128>>, <<_:128>>) -> secrets().
secrets(Ts, <<_:128>> = Key0, <<_:128>> = Key1) when Key0 =/= Key1 ->
    seal(#keys{ts = Ts, cookie = {Key0, Key1}, current = 0}).

-doc """
The secrets after one rotation, every 15 s (`syncookie_reseed`): `NewKey` replaces the key
that is not current and becomes current, so a cookie validates under the rotation that made
it and the next, 15 to 30 s.
""".
-spec rotate(<<_:128>>, secrets()) -> secrets().
rotate(<<_:128>> = NewKey, Secrets) ->
    #keys{cookie = Keys, current = Current} = Keyset = unseal(Secrets),
    Other = 1 - Current,
    seal(Keyset#keys{cookie = setelement(Other + 1, Keys, NewKey), current = Other}).

-doc "The number of entries, the connections in SYN-RECEIVED.".
-spec size(syncache()) -> non_neg_integer().
size(#syncache{entries = Entries}) -> map_size(Entries).

-doc """
A SYN for a listener (`syncache_add`). A SYN to or from itself, from a multicast address
or to one, or from the limited broadcast is dropped, as tcp_input drops it before
syncache_add (tcp_input.c:1295-1338), and so is a signed SYN; one sent to a broadcast or
multicast address never gets here, since erx_net_input's listener row drops it against
the class erx_ip4 and erx_ip6 found for its destination. A SYN for a
four-tuple already in the table updates its timestamp and may withdraw ECN, but never grant
it, and draws the same SYN-ACK again with the retransmission count reset. Otherwise the SYN
draws a SYN-ACK whose sequence number is a cookie, and makes an entry if the table is not
paused and has room. A SYN that finds the table full pauses it (`pause/2`) and makes no
entry. `MssOpt` is the MSS option a new entry's SYN-ACKs offer, which the caller computes
from its route to the peer (`tcp_mssopt`), as `syncache_respond` does for each connection
(tcp_syncache.c:1823-1827); the entry keeps it for its retransmissions, and a repeated
SYN replaces it.
""".
-spec add(conn(), #tcp{}, listener(), 0..16#ffff, context(), syncache()) ->
          {syncache(), [action()]}.
add(Conn, #tcp{opts = #tcp_opts{signature = Signed}} = Syn, Listener, MssOpt,
    #{now := Now, secrets := Secrets}, #syncache{} = Cache)
  when ?IS_CONN(Conn), is_integer(MssOpt), MssOpt >= 0, MssOpt =< 16#ffff ->
    case not Signed andalso admissible(Conn) of
        false ->
            {Cache, []};
        true ->
            %% A paused table looks no entry up, as FreeBSD's cookiesonly path does (:1510).
            case cookies_only(Now, Cache) orelse Cache#syncache.entries of
                #{Conn := Entry} -> repeat_syn(Conn, Entry, Syn, MssOpt, Now, Cache);
                _ -> first_syn(Conn, Syn, Listener, MssOpt, Now, Secrets, Cache)
            end
    end.

%% tcp_input.c:1295-1338, the checks that read the four-tuple alone: not a connection to
%% itself, neither end a multicast address, and for IPv4 not a source at the limited
%% broadcast. The destination's broadcast test needs the receiving interface's broadcast
%% addresses (in_ifnet_broadcast) and is erx_net_input's listener row's.
admissible({Addr, Port, Addr, Port}) -> false;
admissible({Local, _, Foreign, _}) ->
    not erx_net_addr:is_multicast(Local) andalso not erx_net_addr:is_multicast(Foreign)
        andalso Foreign =/= <<255, 255, 255, 255>>.

%% The ECN of an entry may be withdrawn by a SYN without it, never granted.
repeat_syn(Conn, #entry{ts = Ts0, ecn = Ecn0} = Entry0,
           #tcp{flags = Flags, opts = #tcp_opts{ts = SynTs}}, MssOpt, Now, Cache) ->
    Ts = case {Ts0, SynTs} of
             {{_, TsOffset}, {TsVal, _}} -> {TsVal, TsOffset};
             _ -> none
         end,
    Entry = Entry0#entry{ts = Ts, ecn = Ecn0 andalso erx_tcp_ecn:syncache_add(Flags),
                         mss_opt = MssOpt, rxmits = 0},
    {arm(Conn, Entry, Now, Cache), [synack(Conn, Entry, Now)]}.

first_syn(Conn, #tcp{seq = Irs, flags = Flags, opts = Opts}, Listener, MssOpt, Now, Secrets,
          Cache) ->
    #{rcv_buf := RcvBuf, rcv_scale := RcvScale} = Listener,
    #tcp_opts{mss = PeerMss, wscale = SndScale, sack_permitted = Sack, ts = SynTs} = Opts,
    Entry0 = #entry{irs = Irs,
                    rcv_wnd = min(RcvBuf, ?TCP_MAXWIN),
                    mss_opt = MssOpt,
                    peer_mss = case PeerMss of none -> 0; _ -> PeerMss end,
                    wscale = case SndScale of none -> none; _ -> {SndScale, RcvScale} end,
                    sack = Sack,
                    ts = case SynTs of
                             none -> none;
                             {TsVal, _} -> {TsVal, ts_offset(Secrets, Conn)}
                         end,
                    ecn = erx_tcp_ecn:syncache_add(Flags)},
    Entry = Entry0#entry{iss = cookie(Secrets, Conn, Entry0)},
    #syncache{limit = Limit, entries = Entries} = Cache,
    Synack = synack(Conn, Entry, Now),
    case cookies_only(Now, Cache) of
        true -> {Cache, [Synack]};
        false when map_size(Entries) < Limit -> {arm(Conn, Entry, Now, Cache), [Synack]};
        false -> {pause(uptime(Now), Cache), [Synack]}
    end.

%% syncache_insert on a full bucket, with syncache_pause. FreeBSD drops the bucket's oldest
%% entry, inserts the new one and pauses; while paused it looks no entry up and its timer
%% drops every entry without answering. Every entry's next deadline is at most 8.2 s away
%% and a pause lasts at least 15 s, so all are dropped within the pause, and here the pause
%% drops them all at once and makes no entry. Only first_syn/7 makes a new entry and it
%% makes none while paused, so the table stays empty until the pause ends. A pause that
%% starts within the last pause's own length after that one ended doubles it, at most
%% TCP_SYNCACHE_MAX_BACKOFF times; any other lasts 15 s.
pause(Uptime, #syncache{pause = Last} = Cache) ->
    Backoff = case Last of
                  {Until, B} when Until + (?TCP_SYNCACHE_PAUSE_TIME bsl B) - Uptime > 0 ->
                      min(B + 1, ?TCP_SYNCACHE_MAX_BACKOFF);
                  _ ->
                      0
              end,
    Cache#syncache{entries = #{}, timers = gb_sets:empty(), last_overflow = Uptime,
                   pause = {Uptime + (?TCP_SYNCACHE_PAUSE_TIME bsl Backoff), Backoff}}.

-doc """
Whether the table is paused at `Now` (`syncache_cookiesonly`), so it makes no entries and
checks as a cookie every ACK that matches none. The pause lasts while the uptime in whole
seconds is before its end, the test `syncache_unpause` makes (`pause_until - time_uptime`
no longer positive). FreeBSD makes it when its callout fires, the pause's length after the
pause began, so its pause can end up to a second later than this one.
""".
-spec cookies_only(integer(), syncache()) -> boolean().
cookies_only(Now, #syncache{pause = {Until, _}}) when is_integer(Now) -> uptime(Now) < Until;
cookies_only(Now, #syncache{pause = none}) when is_integer(Now) -> false.

-doc """
An ACK, without SYN or RST, for a listener (`syncache_expand`). With an entry: a signed ACK
or one failing PAWS is dropped and the entry kept; a sequence number outside the window
draws a challenge ACK, limited to five a second; an acknowledgement other than the cookie
plus one is answered with a RST; otherwise the entry becomes the handshake. Without an
entry the ACK is checked as a cookie only if the table is paused or overflowed in the last
15 s, and a valid cookie becomes the handshake unless the ACK is signed.
""".
-spec expand(conn(), #tcp{}, listener(), context(), syncache()) ->
          {outcome(), syncache(), [action()]}.
expand(Conn, #tcp{} = Ack, Listener, #{now := Now, secrets := Secrets}, #syncache{} = Cache)
  when ?IS_CONN(Conn) ->
    case Cache#syncache.entries of
        #{Conn := Entry} ->
            expand_entry(Conn, Entry, Ack, Now, Cache);
        #{} ->
            Outcome = case checks_cookies(Cache, Now) of
                          true -> expand_cookie(Conn, Ack, Listener, Secrets);
                          false -> reset
                      end,
            {Outcome, Cache, []}
    end.

expand_entry(_Conn, _Entry, #tcp{opts = #tcp_opts{signature = true}}, _Now, Cache) ->
    {drop, Cache, []};
expand_entry(Conn, #entry{irs = Irs, iss = Iss, rcv_wnd = Wnd} = Entry,
             #tcp{seq = Seq, ack = Ack, opts = #tcp_opts{ts = AckTs}}, Now, Cache) ->
    %% SEG.SEQ must lie in (IRS, IRS + RCV.WND].
    Offset = erx_tcp_seq:lift(Seq, Irs) - Irs,
    case paws_fails(Entry#entry.ts, AckTs) of
        true ->
            {drop, Cache, []};
        false when Offset =< 0; Offset > Wnd ->
            {Cache1, Actions} = challenge_ack(Conn, Entry, Now, Cache),
            {drop, Cache1, Actions};
        false ->
            case erx_tcp_seq:wire(Iss + 1) of
                Ack -> {{ok, handshake(Entry)}, remove(Conn, Cache), []};
                _ -> {reset, Cache, []}
            end
    end.

%% RFC 7323 PAWS: a timestamp older than the one the SYN carried. A missing timestamp is
%% tolerated (tcp_tolerate_missing_ts = 1) and an unexpected one ignored.
paws_fails({TsReflect, _}, {TsVal, _}) -> erx_tcp_seq:lift(TsVal, TsReflect) < TsReflect;
paws_fails(_, _) -> false.

%% Whether an ACK matching no entry is checked as a cookie: always while paused, as FreeBSD
%% skips the table then, and otherwise only within SYNCOOKIE_LIFETIME whole seconds of the
%% last overflow, as FreeBSD compares time_uptime.
checks_cookies(Cache, Now) -> cookies_only(Now, Cache) orelse overflowed_recently(Cache, Now).

overflowed_recently(#syncache{last_overflow = none}, _Now) -> false;
overflowed_recently(#syncache{last_overflow = Last}, Now) ->
    not (Last < uptime(Now) - ?SYNCOOKIE_LIFETIME).

%% syncookie_expand: undo the handshake's sequence advance, recover the flags byte, and
%% accept the cookie if the MAC of the four-tuple, IRS and flags under the key the flags
%% name matches its top 24 bits.
expand_cookie(Conn, #tcp{opts = #tcp_opts{signature = true}} = Ack, _Listener, Secrets) ->
    case validate_cookie(Conn, Ack, Secrets) of
        {ok, _} -> drop;
        error -> reset
    end;
expand_cookie(Conn, #tcp{opts = #tcp_opts{ts = AckTs}} = Ack, Listener, Secrets) ->
    case validate_cookie(Conn, Ack, Secrets) of
        error ->
            reset;
        {ok, {Iss, Irs, Flags}} ->
            #{rcv_buf := RcvBuf, rcv_scale := RcvScale} = Listener,
            WsIdx = (Flags bsr 2) band 7,
            {ok, #{iss => Iss, irs => Irs,
                   rcv_wnd => min(RcvBuf, ?TCP_MAXWIN),
                   peer_mss => element((Flags bsr 5) + 1, ?MSSTAB),
                   wscale => case WsIdx of
                                 0 -> none;
                                 _ -> {element(WsIdx + 1, ?WSTAB), RcvScale}
                             end,
                   sack => Flags band 2 =/= 0,
                   ts => case AckTs of
                             none -> none;
                             {TsVal, _} -> {TsVal, ts_offset(Secrets, Conn)}
                         end,
                   ecn => false, rxmits => 0, challenge => none}}
    end.

validate_cookie(Conn, #tcp{seq = Seq, ack = Ack}, Secrets) ->
    Iss = erx_tcp_seq:wire(Ack - 1),
    Irs = erx_tcp_seq:wire(Seq - 1),
    Flags = (Iss band 16#ff) bxor (Iss bsr 24),
    Hash = mac(Secrets, Flags band 1, Conn, Irs, Flags),
    case Iss band ?MAC_MASK =:= Hash band ?MAC_MASK of
        true -> {ok, {Iss, Irs, Flags}};
        false -> error
    end.

%% syncookie_generate: the flags byte (MSS index, window-shift index, SACK, which key) in
%% the low 8 bits XORed with the MAC's top 8, under the MAC's top 24.
cookie(Secrets, Conn,
       #entry{irs = Irs, peer_mss = PeerMss, wscale = Wscale, sack = Sack}) ->
    WsIdx = case Wscale of
                none -> 0;
                {SndScale, _} -> index(SndScale, ?WSTAB)
            end,
    SackBit = case Sack of true -> 1; false -> 0 end,
    #keys{current = Current} = unseal(Secrets),
    Flags = (index(PeerMss, ?MSSTAB) bsl 5) bor (WsIdx bsl 2) bor (SackBit bsl 1) bor Current,
    Hash = mac(Secrets, Current, Conn, Irs, Flags),
    (Hash band ?MAC_MASK) bor (Flags bxor (Hash bsr 24)).

%% The highest index whose table value is at most Value, or 0.
index(Value, Table) -> index(Value, Table, tuple_size(Table) - 1).

index(_Value, _Table, 0) -> 0;
index(Value, Table, I) when element(I + 1, Table) =< Value -> I;
index(Value, Table, I) -> index(Value, Table, I - 1).

%% syncookie_mac: SipHash-2-4 over the foreign and local addresses, the foreign and local
%% ports in network byte order, the IRS in FreeBSD's host order (little-endian on its
%% AArch64 and amd64 targets) and the flags byte, folded to 32 bits as siphash[0] ^
%% siphash[1]. FreeBSD also hashes the bucket's address; one table has none.
mac(Secrets, Slot, {LAddr, LPort, FAddr, FPort}, Irs, Flags) ->
    #keys{cookie = Keys} = unseal(Secrets),
    Key = element(Slot + 1, Keys),
    Digest = erx_bytes:siphash24(Key, [FAddr, LAddr, <<FPort:16, LPort:16, Irs:32/little, Flags:8>>]),
    <<High:32, Low:32>> = <<Digest:64>>,
    High bxor Low.

handshake(#entry{irs = Irs, iss = Iss, rcv_wnd = Wnd, peer_mss = PeerMss, wscale = Wscale,
                 sack = Sack, ts = Ts, ecn = Ecn, rxmits = Rxmits, ack_war = War}) ->
    #{iss => Iss, irs => Irs, rcv_wnd => Wnd, peer_mss => PeerMss, wscale => Wscale,
      sack => Sack, ts => Ts, ecn => Ecn, rxmits => Rxmits, challenge => War}.

-doc """
A RST for a listener (`syncache_chkrst`). With an entry, a RST at exactly IRS + 1 drops it
(`tcp_insecure_rst` = 0); one elsewhere in the window draws a challenge ACK, RFC 5961; one
outside the window is ignored.
""".
-spec chkrst(conn(), #tcp{}, integer(), syncache()) -> {syncache(), [action()]}.
chkrst(Conn, #tcp{seq = Seq}, Now, #syncache{entries = Entries} = Cache) ->
    case Entries of
        #{Conn := #entry{irs = Irs, rcv_wnd = Wnd} = Entry} ->
            %% Distance from RCV.NXT, IRS + 1.
            Offset = erx_tcp_seq:lift(Seq, Irs) - Irs - 1,
            InWindow = Offset >= 0 andalso Offset < Wnd orelse Wnd =:= 0 andalso Offset =:= 0,
            if
                InWindow, Offset =:= 0 -> {remove(Conn, Cache), []};
                InWindow -> challenge_ack(Conn, Entry, Now, Cache);
                true -> {Cache, []}
            end;
        #{} ->
            {Cache, []}
    end.

-doc """
An ICMP unreachable or similar error quoting `Seq` for the four-tuple (`syncache_unreach`):
the entry is dropped on its second such error after three retransmissions, so a passing
outage does not end it.
""".
-spec unreach(conn(), erx_tcp_seq:wire(), syncache()) -> syncache().
unreach(Conn, Seq, #syncache{entries = Entries} = Cache) ->
    case Entries of
        #{Conn := #entry{iss = Seq, unreach = true, rxmits = Rxmits}}
          when Rxmits >= ?UNREACH_REXMTS ->
            remove(Conn, Cache);
        #{Conn := #entry{iss = Seq} = Entry} ->
            store(Conn, Entry#entry{unreach = true}, Cache);
        #{} ->
            Cache
    end.

-doc """
Runs every retransmission deadline at or before `Now` (`syncache_timer`): ECN is withdrawn
after the first retransmission, an entry past three retransmissions is dropped, and the
others resend their SYN-ACK and back off.
""".
-spec expired(integer(), syncache()) -> {syncache(), [action()]}.
expired(Now, Cache) when is_integer(Now) -> expired(Now, Cache, []).

expired(Now, #syncache{entries = Entries} = Cache, Acc) ->
    case next_timer(Cache) of
        {Deadline, Conn} when Deadline =< Now ->
            #{Conn := #entry{rxmits = Rxmits, ecn = Ecn} = Entry0} = Entries,
            Entry = Entry0#entry{ecn = erx_tcp_ecn:syncache_retransmit(Rxmits, Ecn)},
            case Rxmits > ?SYNCACHE_MAXREXMTS of
                true -> expired(Now, remove(Conn, Cache), Acc);
                false -> expired(Now, arm(Conn, Entry, Now, Cache), [synack(Conn, Entry, Now) | Acc])
            end;
        _ ->
            {Cache, lists:reverse(Acc)}
    end.

-doc "The earliest retransmission deadline, or `infinity` for an empty table.".
-spec next_deadline(syncache()) -> integer() | infinity.
next_deadline(Cache) ->
    case next_timer(Cache) of
        none -> infinity;
        {Deadline, _Conn} -> Deadline
    end.

next_timer(#syncache{timers = Timers}) ->
    case gb_sets:is_empty(Timers) of
        true -> none;
        false -> gb_sets:smallest(Timers)
    end.

%% syncache_timeout: the first SYN-ACK waits tcp_rexmit_initial; each retransmission waits
%% that times tcp_backoff[rxmits], plus the slop, held between the least and greatest RTO.
arm(Conn, #entry{rxmits = Rxmits} = Entry, Now, Cache) ->
    Rexmt = case Rxmits of
                0 -> ?TCPTV_RTOBASE;
                _ -> min(max(?TCPTV_RTOBASE * element(Rxmits + 1, ?TCP_BACKOFF) + ?TCPTV_CPU_VAR,
                             ?TCPTV_MIN), ?TCPTV_REXMTMAX)
            end,
    store(Conn, Entry#entry{rxttime = Now + Rexmt, rxmits = Rxmits + 1}, Cache).

%% store/3 and remove/2 are the only writers of entries and timers, with pause/2, which
%% empties both: the timer set holds exactly {rxttime, Conn} of each stored entry, so
%% expired/3 finds every timer's entry.
store(Conn, #entry{rxttime = Deadline} = Entry, #syncache{entries = Entries} = Cache) ->
    #syncache{timers = Timers} = Removed = remove(Conn, Cache),
    Removed#syncache{entries = Entries#{Conn => Entry},
                     timers = case Deadline of
                                  none -> Timers;
                                  _ -> gb_sets:add({Deadline, Conn}, Timers)
                              end}.

remove(Conn, #syncache{entries = Entries, timers = Timers} = Cache) ->
    case maps:take(Conn, Entries) of
        {#entry{rxttime = none}, Rest} ->
            Cache#syncache{entries = Rest};
        {#entry{rxttime = Deadline}, Rest} ->
            Cache#syncache{entries = Rest, timers = gb_sets:delete_any({Deadline, Conn}, Timers)};
        error ->
            Cache
    end.

%% syncache_send_challenge_ack with tcp_challenge_ack_check: at most ACK_WAR_CNT in each
%% window of ACK_WAR_TIME_WINDOW, counted per entry. Every attempt charges the RST rate
%% limit, a suppressed one through charge_rst, so the limit's count does not reveal whether
%% the entry exists.
challenge_ack(Conn, #entry{ack_war = War} = Entry, Now, Cache) ->
    {EpochEnd, Count} = case War of
                            {End, Sent} when End >= Now -> {End, Sent};
                            _ -> {Now + ?ACK_WAR_TIME_WINDOW, 0}
                        end,
    case Count < ?ACK_WAR_CNT of
        true ->
            Stored = Entry#entry{ack_war = {EpochEnd, Count + 1}},
            {store(Conn, Stored, Cache), [respond(challenge_ack, Conn, Stored, Now)]};
        false ->
            {Cache, [charge_rst]}
    end.

synack(Conn, Entry, Now) -> respond(send, Conn, Entry, Now).

%% syncache_respond: a SYN-ACK carries the MSS, window-scale, SACK-permitted and timestamp
%% options the entry negotiated; a challenge ACK carries only the timestamp.
respond(Tag, {_, LPort, _, FPort} = Conn,
        #entry{irs = Irs, iss = Iss, rcv_wnd = Wnd, mss_opt = MssOpt, wscale = Wscale,
               sack = Sack, ts = Ts, ecn = Ecn}, Now) ->
    TsOpt = case Ts of
                none -> none;
                {TsReflect, TsOffset} -> {erx_tcp_seq:wire(TsOffset + Now), TsReflect}
            end,
    {Seq, Flags, Opts} =
        case Tag of
            send ->
                {Iss, erx_tcp_ecn:syncache_respond(?TH_SYN bor ?TH_ACK, Ecn),
                 #tcp_opts{mss = MssOpt,
                           wscale = case Wscale of none -> none; {_, RcvScale} -> RcvScale end,
                           sack_permitted = Sack, ts = TsOpt}};
            challenge_ack ->
                {erx_tcp_seq:wire(Iss + 1), ?TH_ACK, #tcp_opts{ts = TsOpt}}
        end,
    Segment = #tcp{sport = LPort, dport = FPort, seq = Seq, ack = erx_tcp_seq:wire(Irs + 1),
                   flags = Flags, win = Wnd, urp = 0, opts = Opts},
    {Tag, Conn, Segment, Iss band ?FLOWLABEL_MASK}.

%% FreeBSD's time_uptime: whole seconds, rounded down for a negative monotonic time too.
uptime(Now) when Now >= 0 -> Now div 1000;
uptime(Now) -> -((999 - Now) div 1000).

seal(#keys{} = Keyset) -> fun(keys) -> Keyset end.

unseal(Secrets) when is_function(Secrets, 1) -> Secrets(keys).

%% Unseals only where a key is used, so no function clause that could fail holds a key in
%% its arguments, which a crash report prints.
ts_offset(Secrets, Conn) -> erx_tcp_isn:ts_offset((unseal(Secrets))#keys.ts, Conn).
