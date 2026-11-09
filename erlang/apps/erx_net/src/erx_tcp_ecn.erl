%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/tcp_ecn.c
%% Copyright (c) 1982, 1986, 1988, 1990, 1993, 1994, 1995
%%      The Regents of the University of California.  All rights reserved.
%% Copyright (c) 2007-2008,2010
%%      Swinburne University of Technology, Melbourne, Australia.
%% Copyright (c) 2009-2010 Lawrence Stewart <lstewart@freebsd.org>
%% Copyright (c) 2010 The FreeBSD Foundation
%% Copyright (c) 2010-2011 Juniper Networks, Inc.
%% Copyright (c) 2019 Richard Scheffenegger <srichard@netapp.com>
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

-module(erx_tcp_ecn).
-moduledoc """
Explicit congestion notification for TCP, RFC 3168 (docs/design-network-stack.md, "Defaults
kept"), translated from sys/netinet/tcp_ecn.c with the ECN parts of `cc_cong_signal`
(sys/netinet/tcp_input.c), `tcp_output` (sys/netinet/tcp_output.c) and `syncache_timer`
(sys/netinet/tcp_syncache.c), at the commit NOTICE-freebsd records.

The stack runs FreeBSD's default mode, `tcp_do_ecn` = 2: it accepts ECN when a peer's SYN
asks for it and never asks itself, so an active open's SYN carries no ECN flags and only the
branches of mode 2 are translated. A peer that asks for AccECN gets RFC 3168 ECN, as
`tcp_ecn_syncache_add` answers it; AccECN (modes 3 and 4) is an extension
(design-network-stack.md, "Scope").

A connection's ECN state is `off` or, once negotiated, whether it owes the peer ECE (a CE
mark arrived and no CWR yet) and whether it owes CWR (it reduced its window and has not yet
said so); FreeBSD's `TF2_ECN_PERMIT`, `TF2_ECN_SND_ECE` and `TF2_ECN_SND_CWR`. Flags are
FreeBSD's `thflags` as `erx_tcp_wire` gives them; `IpTos` is the IPv4 TOS or IPv6 traffic
class byte, whose low two bits are the ECN field.
""".

-include("erx_tcp_wire.hrl").

-export([new/0, input_syn_sent/2, input_parallel_syn/2, input_segment/4, output/2, signal_cwr/1,
         enabled/1, syncache_add/1, syncache_respond/2, syncache_retransmit/2,
         syncache_socket/1]).

-export_type([state/0, segment/0]).

%% ip.h: the ECN field of the TOS byte and its code points.
-define(IPTOS_ECN_MASK, 3).
-define(IPTOS_ECN_NOTECT, 0).
-define(IPTOS_ECN_ECT0, 2).
-define(IPTOS_ECN_CE, 3).
%% tcp_ecn.c: tcp_ecn_maxretries, the SYN-ACK retransmissions after which ECN is dropped.
-define(TCP_ECN_MAXRETRIES, 1).

-record(ecn, {snd_ece = false :: boolean(),
              snd_cwr = false :: boolean()}).

-opaque state() :: off | #ecn{}.

-doc """
What `output/2` needs of the segment being sent: its payload length, `snd_nxt` and `snd_max`
before it is sent, whether it retransmits SACKed holes, whether it is a forced one-byte
window probe (`TF_FORCEDATA`), and whether the connection is in SYN-RECEIVED.
""".
-type segment() :: #{len := non_neg_integer(), snd_nxt := integer(), snd_max := integer(),
                     retransmit := boolean(), forced := boolean(),
                     phase := syn_received | synchronized}.

-doc "The ECN state of an active open, whose SYN does not ask for ECN.".
-spec new() -> state().
new() -> off.

-doc """
A SYN-ACK in SYN-SENT (`tcp_ecn_input_syn_sent`): ECE without CWR turns ECN on. FreeBSD reads
it even though a mode-2 SYN never asked, and so does the stack.
""".
-spec input_syn_sent(0..16#fff, state()) -> state().
input_syn_sent(Flags, State) when Flags band (?TH_CWR bor ?TH_ECE) =:= ?TH_ECE -> permit(State);
input_syn_sent(_Flags, State) -> State.

-doc """
A SYN without ACK in SYN-SENT, a simultaneous open (`tcp_ecn_input_parallel_syn`): ECE with
CWR turns ECN on and owes the peer the ECE of a SYN-ACK.
""".
-spec input_parallel_syn(0..16#fff, state()) -> state().
input_parallel_syn(Flags, State) when Flags band ?TH_ACK =/= 0 -> State;
input_parallel_syn(Flags, State) when Flags band (?TH_CWR bor ?TH_ECE) =:= ?TH_CWR bor ?TH_ECE ->
    (permit(State))#ecn{snd_ece = true};
input_parallel_syn(_Flags, State) -> State.

-doc """
A segment arriving once the connection has a SYN from its peer, in TcpState, the state
before the segment (`tcp_ecn_input_segment`). Returns whether the peer echoed congestion
(ECE on a segment without SYN), for which the caller signals its congestion module with
`CC_ECN`; whether an ACK must go out now, because the peer's CWR ended our ECE in a state
past the handshake in which the peer has sent no FIN (ESTABLISHED, FIN-WAIT-1 or
FIN-WAIT-2; in any other the CWR ends our ECE without an ACK); and the new state, which
owes ECE when the segment arrived marked CE. A congestion module's per-packet ECN hook
(`cc_ecnpkt_handler`, DCTCP's) is the caller's.
""".
-spec input_segment(0..16#fff, 0..255, erx_tcp:state(), state()) ->
          {Echo :: boolean(), AckNow :: boolean(), state()}.
input_segment(_Flags, _IpTos, _TcpState, off) ->
    {false, false, off};
input_segment(Flags, IpTos, TcpState, #ecn{} = State0) ->
    Echo = Flags band (?TH_SYN bor ?TH_ECE) =:= ?TH_ECE,
    Cwr = Flags band ?TH_CWR =/= 0,
    AckNow = Cwr andalso (TcpState =:= established orelse TcpState =:= fin_wait_1
                          orelse TcpState =:= fin_wait_2),
    State1 = case Cwr of
                 true -> State0#ecn{snd_ece = false};
                 false -> State0
             end,
    State = case IpTos band ?IPTOS_ECN_MASK of
                ?IPTOS_ECN_CE -> State1#ecn{snd_ece = true};
                _ -> State1
            end,
    {Echo, AckNow, State}.

-doc """
The ECN marks of a segment sent once a SYN has been received (`tcp_ecn_output_established`,
with `tcp_output`'s clearing of a SYN-ACK's ECE): the flags to add to the header, the ECN
field of the IP header, ECT(0) for new data and Not-ECT otherwise, and the new state. CWR goes
on the first new data after a window reduction; ECE on every segment while owed, except that
the one ECE of a simultaneous open is owed only once.
""".
-spec output(segment(), state()) -> {Flags :: 0..16#fff, IpEcn :: 0..3, state()}.
output(_Segment, off) ->
    {0, ?IPTOS_ECN_NOTECT, off};
output(#{len := Len, snd_nxt := SndNxt, snd_max := SndMax, retransmit := Retransmit,
         forced := Forced, phase := Phase}, #ecn{snd_ece = SndEce, snd_cwr = SndCwr} = State0) ->
    NewData = Len > 0 andalso SndNxt >= SndMax andalso not Retransmit
        andalso not (Forced andalso Len =:= 1),
    IpEcn = case NewData of
                true -> ?IPTOS_ECN_ECT0;
                false -> ?IPTOS_ECN_NOTECT
            end,
    {CwrFlag, State1} = case NewData andalso SndCwr of
                            true -> {?TH_CWR, State0#ecn{snd_cwr = false}};
                            false -> {0, State0}
                        end,
    EceFlag = case SndEce of
                  true -> ?TH_ECE;
                  false -> 0
              end,
    State = case Phase of
                syn_received -> State1#ecn{snd_ece = false};
                synchronized -> State1
            end,
    {CwrFlag bor EceFlag, IpEcn, State}.

-doc """
The connection reduced its window for a duplicate-ACK loss outside fast recovery, an echoed
congestion mark, or a retransmission timeout (`cc_cong_signal`'s `CC_NDUPACK`, `CC_ECN` and
`CC_RTO`): with ECN on, it owes the peer CWR. The congestion code decides when.
""".
-spec signal_cwr(state()) -> state().
signal_cwr(off) -> off;
signal_cwr(#ecn{} = State) -> State#ecn{snd_cwr = true}.

-doc "Whether ECN was negotiated (`TF2_ECN_PERMIT`).".
-spec enabled(state()) -> boolean().
enabled(off) -> false;
enabled(#ecn{}) -> true.

-doc """
Whether a SYN for a listener asks for ECN the stack grants (`tcp_ecn_syncache_add` in mode
2): CWR and ECE, with or without AccECN's AE, which mode 2 answers as RFC 3168 ECN.
""".
-spec syncache_add(0..16#fff) -> boolean().
syncache_add(Flags) ->
    Asked = Flags band (?TH_AE bor ?TH_CWR bor ?TH_ECE),
    Asked =:= ?TH_CWR bor ?TH_ECE orelse Asked =:= ?TH_AE bor ?TH_CWR bor ?TH_ECE.

-doc "The flags of a SYN-ACK from a syncache entry (`tcp_ecn_syncache_respond`): ECE when ECN was granted.".
-spec syncache_respond(0..16#fff, boolean()) -> 0..16#fff.
syncache_respond(Flags, true) when Flags band ?TH_SYN =/= 0 -> Flags bor ?TH_ECE;
syncache_respond(Flags, _Ecn) -> Flags.

-doc """
Whether a syncache entry still grants ECN after `Rxmits` SYN-ACK retransmissions
(`syncache_timer`): not after more than `tcp_ecn_maxretries` (1), in case ECN-marked
SYN-ACKs are what is being lost.
""".
-spec syncache_retransmit(non_neg_integer(), boolean()) -> boolean().
syncache_retransmit(Rxmits, Ecn) -> Ecn andalso Rxmits =< ?TCP_ECN_MAXRETRIES.

-doc "The ECN state of a connection made from a syncache entry (`tcp_ecn_syncache_socket`).".
-spec syncache_socket(boolean()) -> state().
syncache_socket(true) -> #ecn{};
syncache_socket(false) -> off.

permit(off) -> #ecn{};
permit(#ecn{} = State) -> State.
