%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/tcp_usrreq.c
%% Copyright (c) 1982, 1986, 1988, 1993
%% The Regents of the University of California.
%% Copyright (c) 2006-2007 Robert N. M. Watson
%% Copyright (c) 2010-2011 Juniper Networks, Inc.
%% All rights reserved.
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

-module(erx_tcp_user).
-moduledoc """
A connection's user requests (docs/design-network-stack.md, "Events and the step"),
translated from sys/netinet/tcp_usrreq.c (`tcp_connect`, `tcp_usr_send`, `tcp_usr_rcvd`,
`tcp_usr_shutdown`, `tcp_usr_close`, `tcp_disconnect`, `tcp_usrclosed`, `tcp_usr_abort`),
from sys/netinet/tcp_subr.c (`tcp_newtcpcb`, `tcp_drop`, `tcp_close`) and from
sys/netinet/tcp_syncache.c (`syncache_socket`) at the commit NOTICE-freebsd records.

The requests are those of FreeBSD's `pr_usrreqs` for a connected stream, as the connection
process passes them on: the socket layer (owner, active mode, packet framing, the receive
queue) is that process's, and the bytes it has not yet handed to its owner stay counted
in the control block so that the window follows them. A request that waits carries the
caller's `From`; the step answers it (erx_tcp). Each request returns the control block and
its own actions; output runs after it in erx_tcp:step/3, as each `pr_*` function ends by
calling `tcp_output`.
""".

-include("erx_tcp.hrl").

-export([new/1, accepted/3, request/3, rcvd/2, drop/2, close/1, usrclosed/2, fill/3]).

-export_type([request/0, init/0, listener_init/0]).

-doc """
A request: `connect` (`tcp_connect`), `send` (`tcp_usr_send`), `rcvd` (`Bytes` left the
receive buffer, read by the owner or held by a waiting recv, `tcp_usr_rcvd`), `shutdown`
(`tcp_usr_shutdown`), `close` (`tcp_usr_close`) and `abort` (`tcp_usr_abort`).
""".
-type request() :: {connect, gen_server:from()}
                 | {send, gen_server:from(), binary()}
                 | {rcvd, Bytes :: non_neg_integer()}
                 | {shutdown, gen_server:from(), read | write | read_write}
                 | close
                 | abort.

-doc """
What a new control block is made from: the four-tuple and its family, the initial sequence
number and timestamp offset erx_tcp_isn computed for it (`isn/3`, `ts_offset/2`), which the
connection receives from its claim through erx_net_bind, the congestion and loss modules
the socket chose with their parameters, the buffer sizes the grant reserved, the
generator split for the connection, the time, the socket options the step reads, and
whether the remote address is one of the machine's own (`local_peer`, false if absent).
""".
-type init() :: #{family := inet | inet6,
                  local := {binary(), 0..16#ffff},
                  remote := {binary(), 0..16#ffff},
                  local_peer => boolean(),
                  iss := erx_tcp_seq:wire(),
                  ts_offset := erx_tcp_seq:wire(),
                  cc := module(),
                  cc_params => erx_tcp_cc:params(),
                  loss := module(),
                  snd_hiwat := non_neg_integer(),
                  rcv_hiwat := non_neg_integer(),
                  snd_lowat => non_neg_integer(),
                  gen := erx_net_rand:gen(),
                  now := integer(),
                  nodelay => boolean(),
                  linger => off | non_neg_integer(),
                  keep_idle => pos_integer(),
                  keep_intvl => pos_integer(),
                  keep_cnt => pos_integer(),
                  keep_init => pos_integer()}.

-doc """
What accepted/3 makes a control block from besides the handshake: init()'s keys but `iss`,
`ts_offset` and `now`, which the handshake and the step's context give.
""".
-type listener_init() :: #{family := inet | inet6,
                           local := {binary(), 0..16#ffff},
                           remote := {binary(), 0..16#ffff},
                           local_peer => boolean(),
                           cc := module(),
                           cc_params => erx_tcp_cc:params(),
                           loss := module(),
                           snd_hiwat := pos_integer(),
                           rcv_hiwat := non_neg_integer(),
                           snd_lowat => non_neg_integer(),
                           gen := erx_net_rand:gen(),
                           nodelay => boolean(),
                           linger => off | non_neg_integer(),
                           keep_idle => pos_integer(),
                           keep_intvl => pos_integer(),
                           keep_cnt => pos_integer(),
                           keep_init => pos_integer()}.

%% tcp_subr.c: V_tcp_mssdflt and V_tcp_v6mssdflt (TCP_MSS, TCP6_MSS).
-define(TCP_MSS, 536).
-define(TCP6_MSS, 1220).
%% TCP_MAXWIN << TCP_MAX_WINSHIFT, the windows tcp_newtcpcb starts with.
-define(TCP_MAXWIN_SCALED, (16#ffff bsl 14)).
%% tcp_timer.h: TCPTV_KEEP_INIT, TCPTV_KEEP_IDLE, TCPTV_KEEPINTVL, TCPTV_KEEPCNT (ms).
-define(TCPTV_KEEP_INIT, 75000).
-define(TCPTV_KEEP_IDLE, (120 * 60 * 1000)).
-define(TCPTV_KEEPINTVL, 75000).
-define(TCPTV_KEEPCNT, 8).
%% so_snd.sb_lowat's default for a stream socket (MCLBYTES, uipc_socket.c: soreserve).
-define(SND_LOWAT, 2048).

-doc """
A new control block in CLOSED (`tcp_newtcpcb`): the default MSS of the family, timestamps,
window scaling and SACK requested (`tcp_do_rfc1323` 1, `tcp_do_sack` 1), ECN as erx_tcp_ecn
starts it, the RTT estimator's initial state, windows of `TCP_MAXWIN << TCP_MAX_WINSHIFT`,
and `t_rcvtime` now. Its next event is `connect`; a passive open's block is made by
accepted/3 instead.
""".
-spec new(init()) -> #tcb{}.
new(#{family := Family, local := Local, remote := Remote, iss := Iss, ts_offset := TsOffset,
      cc := Cc, loss := Loss, snd_hiwat := SndHiwat, rcv_hiwat := RcvHiwat, gen := Gen,
      now := Now} = Init) ->
    Maxseg = case Family of
                 inet -> ?TCP_MSS;
                 inet6 -> ?TCP6_MSS
             end,
    Ccv = #ccv{cwnd = ?TCP_MAXWIN_SCALED, ssthresh = ?TCP_MAXWIN_SCALED, maxseg = Maxseg,
               initwnd = erx_tcp_mss:initwnd(Maxseg), snd_scale = 0, snd_wnd = 0, pipe = 0,
               rxtshift = 0, srtt = 0, rtt_updated = 0, rexmit = false, now = Now,
               data = Cc:init(maps:get(cc_params, Init, #{}))},
    #tcb{state = closed, family = Family, local = Local, remote = Remote,
         local_peer = maps:get(local_peer, Init, false),
         iss = Iss, snd_una = Iss, snd_nxt = Iss, snd_max = Iss, snd_up = Iss,
         snd_recover = Iss,
         ts = {requested, TsOffset}, wscale = requested, sack = requested,
         ecn = erx_tcp_ecn:new(), maxseg = Maxseg,
         rtt = erx_tcp_rtt:new(), cc = Cc, ccv = Ccv,
         loss = Loss, loss_state = Loss:init(#{sack => false}),
         sendlog = erx_tcp_sendlog:new(Iss),
         sndbuf = erx_tcp_sndbuf:new(), snd_hiwat = SndHiwat,
         snd_lowat = min(maps:get(snd_lowat, Init, ?SND_LOWAT), SndHiwat),
         rcv_hiwat = RcvHiwat,
         reass = erx_tcp_reass:new(), rcv_sack = erx_tcp_sack:new(),
         rcvtime = Now,
         keep_init = keep_opt(keep_init, Init, ?TCPTV_KEEP_INIT),
         keep_idle = keep_opt(keep_idle, Init, ?TCPTV_KEEP_IDLE),
         keep_intvl = keep_opt(keep_intvl, Init, ?TCPTV_KEEPINTVL),
         keep_cnt = keep_opt(keep_cnt, Init, ?TCPTV_KEEPCNT),
         nodelay = maps:get(nodelay, Init, false),
         linger = maps:get(linger, Init, off),
         gen = Gen}.

-doc """
A control block in SYN-RECEIVED made from a completed handshake (`syncache_socket`,
tcp_syncache.c:894-984), with the listener's options in `Init`. Our SYN-ACK is the SYN in
flight: snd_una is the ISS, snd_nxt and snd_max are past it, and the send log holds it, so
the ACK that
completes the handshake moves snd_una past it in erx_tcp_input's SYN-RECEIVED stage, as
`incforsyn` does (tcp_input.c:2514-2515, :2897-2898). The receive side starts past the
peer's SYN with the window the SYN-ACK offered. The options are those the handshake
negotiated, ECN as `tcp_ecn_syncache_socket` sets it, the MSS from the peer's offer
(`tcp_mss`, whose buffer sizes the returned actions ask of the grant), one segment of
congestion window when the SYN-ACK was sent more than once, the entry's challenge-ACK
window, and the connection-establishment timer (TT_KEEP at TP_KEEPINIT). The connection
then steps the segment that completed the handshake, as tcp_input does.
""".
-spec accepted(erx_tcp_syncache:handshake(), listener_init(), #tcp_ctx{}) ->
          {#tcb{}, [erx_tcp:action()]}.
accepted(#{iss := Iss, irs := Irs, rcv_wnd := RcvWnd, peer_mss := PeerMss, wscale := Wscale,
           sack := Sack, ts := Ts, ecn := Ecn, rxmits := Rxmits, challenge := Challenge},
         Init, #tcp_ctx{now = Now} = Ctx) ->
    TsOffset = case Ts of
                   {_, Offset} -> Offset;
                   none -> 0
               end,
    #tcb{loss = Loss, ccv = Ccv, sendlog = Log, deadlines = D, keep_init = KeepInit} = Tcb0 =
        new(Init#{iss => Iss, ts_offset => TsOffset, now => Now}),
    %% tcp_rcvseqinit, tcp_sendseqinit and :894-905; the SYN-ACK takes one sequence number.
    Tcb1 = Tcb0#tcb{state = syn_received, irs = Irs, snd_wl1 = Irs,
                    snd_nxt = Iss + 1, snd_max = Iss + 1,
                    sendlog = erx_tcp_sendlog:sent(Log, Iss, Iss + 1, Tcb0#tcb.maxseg, Now),
                    rcv_nxt = Irs + 1, rcv_up = Irs + 1, rcv_wnd = RcvWnd,
                    rcv_adv = Irs + 1 + RcvWnd, last_ack_sent = Irs + 1,
                    %% :910-929.
                    wscale = case Wscale of
                                 {_, _} -> Wscale;
                                 none -> off
                             end,
                    ts = case Ts of
                             {Recent, _} -> #ts{recent = Recent, recent_age = Now, offset = TsOffset};
                             none -> off
                         end,
                    sack = case Sack of
                               true -> on;
                               false -> off
                           end,
                    loss_state = Loss:init(#{sack => Sack}),
                    ecn = erx_tcp_ecn:syncache_socket(Ecn),
                    %% :945-946, read by cc_conn_init as one segment.
                    ccv = case Rxmits > 1 of
                              true -> Ccv#ccv{cwnd = 1};
                              false -> Ccv
                          end,
                    %% :948-949, from the syncache's milliseconds.
                    challenge = case Challenge of
                                    {EndMs, Sent} -> {EndMs * 1000, Sent};
                                    none -> none
                                end,
                    %% :984.
                    deadlines = D#deadlines{keep = Now + ms(KeepInit)}},
    %% :938.
    erx_tcp_input:tcp_mss(PeerMss, Tcb1, Ctx).

%% A keepalive option: 0 or absent means the default, as TP_KEEPIDLE and its kin read
%% (tcp_timer.h); anything but a positive integer is refused.
keep_opt(Key, Init, Default) ->
    case maps:get(Key, Init, 0) of
        0 -> Default;
        Value when is_integer(Value), Value > 0 -> Value;
        Value -> erlang:error(badarg, [Key, Value])
    end.

-doc "Handles one request; output follows in erx_tcp:step/3.".
-spec request(request(), #tcb{}, #tcp_ctx{}) -> {#tcb{}, [erx_tcp:action()]}.
request({connect, From}, #tcb{state = closed} = Tcb, Ctx) ->
    {(connect(Tcb, Ctx))#tcb{connect_waiter = From}, []};
request({connect, From}, Tcb, _) ->
    {Tcb, [{reply, From, {error, already_connected(Tcb)}}]};
request({send, From, Data}, Tcb, _) when is_binary(Data) ->
    send(From, Data, Tcb);
request({rcvd, Bytes}, Tcb, _) when is_integer(Bytes), Bytes >= 0 ->
    {rcvd(Bytes, Tcb), []};
request({shutdown, From, How}, Tcb, Ctx) when How =:= read; How =:= write; How =:= read_write ->
    shutdown(From, How, Tcb, Ctx);
request(close, #tcb{state = time_wait} = Tcb, _) ->
    {Tcb, []};
request(close, Tcb, Ctx) ->
    {disconnect(Tcb#tcb{user_closed = true}, Ctx), []};
request(abort, Tcb, _) ->
    {drop(Tcb, econnaborted), []}.

-doc """
`Bytes` left the receive buffer (`tcp_usr_rcvd`): they no longer count against the window,
`sbspace`. The request's step runs output after it; erx_tcp:rcvd/2 takes them off without a
step when output would send nothing for them.
""".
-spec rcvd(non_neg_integer(), #tcb{}) -> #tcb{}.
rcvd(Bytes, #tcb{rcv_buffered = Buffered} = Tcb) ->
    Tcb#tcb{rcv_buffered = Buffered - min(Bytes, Buffered)}.

already_connected(#tcb{state = syn_sent}) -> ealready;
already_connected(_) -> eisconn.

%% tcp_connect: SYN-SENT, the connection-establishment timer (TT_KEEP at TP_KEEPINIT) and
%% tcp_sendseqinit's send sequence from the ISS new/1 was given; output sends the SYN.
connect(#tcb{deadlines = Deadlines, keep_init = KeepInit} = Tcb, #tcp_ctx{now = Now}) ->
    Tcb#tcb{state = syn_sent, deadlines = Deadlines#deadlines{keep = Now + ms(KeepInit)}}.

%% tcp_usr_send for a stream without out-of-band data, with sosend's admission: EPIPE after
%% shutdown, ENOTCONN before the connection is established. The buffer takes what fits
%% under its high watermark; the caller waits with the rest (erx_tcp's settling moves it in
%% as space opens) and is answered once all of it is in. One send waits at a time: the
%% connection process holds later ones until it is answered, so another is refused.
send(From, _, #tcb{snd_closed = true} = Tcb) ->
    {Tcb, [{reply, From, {error, epipe}}]};
send(From, _, #tcb{send_waiter = {_, _}} = Tcb) ->
    {Tcb, [{reply, From, {error, ebusy}}]};
send(From, Data, #tcb{state = State} = Tcb) ->
    case erx_tcp:have_established(State) of
        false -> {Tcb, [{reply, From, {error, enotconn}}]};
        true -> fill(From, Data, Tcb)
    end.

-doc """
Moves as much of `Data` into the send buffer as its high watermark leaves room for, and
answers `From` once all of it is in; otherwise `From` waits with the rest.
""".
-spec fill(gen_server:from(), binary(), #tcb{}) -> {#tcb{}, [erx_tcp:action()]}.
fill(From, Data, #tcb{sndbuf = Buf, snd_hiwat = Hiwat} = Tcb) ->
    Take = min(byte_size(Data), max(0, Hiwat - erx_tcp_sndbuf:size(Buf))),
    <<Part:Take/binary, Rest/binary>> = Data,
    Tcb1 = Tcb#tcb{sndbuf = erx_tcp_sndbuf:append(Buf, Part)},
    case Rest of
        <<>> -> {Tcb1#tcb{send_waiter = none}, [{reply, From, ok}]};
        _ -> {Tcb1#tcb{send_waiter = {From, Rest}}, []}
    end.

%% tcp_usr_shutdown: SHUT_RD flushes the receive side (sorflush), SHUT_WR and SHUT_RDWR
%% also close the send side and take tcp_usrclosed's transition. A connection that is
%% neither connected nor connecting answers ENOTCONN, and so does one in FIN-WAIT-2 or
%% TIME-WAIT, which tcp_usrclosed has already marked disconnected (soisdisconnected).
shutdown(From, _, #tcb{state = State} = Tcb, _)
  when State =:= closed; State =:= fin_wait_2; State =:= time_wait ->
    {Tcb, [{reply, From, {error, enotconn}}]};
shutdown(From, read, Tcb, _) ->
    {rcv_flush(Tcb), [{reply, From, ok}]};
shutdown(From, read_write, Tcb, Ctx) ->
    shutdown(From, write, rcv_flush(Tcb), Ctx);
shutdown(From, write, Tcb, Ctx) ->
    {usrclosed(Tcb, Ctx), [{reply, From, ok}]}.

rcv_flush(Tcb) -> Tcb#tcb{rcv_closed = true, rcv_buffered = 0}.

%% tcp_disconnect: before ESTABLISHED the connection simply closes; with SO_LINGER and a
%% linger time of 0 it is dropped with a RST; otherwise the receive side is flushed and
%% tcp_usrclosed sends the FIN.
disconnect(#tcb{state = State, linger = Linger} = Tcb, Ctx) ->
    case erx_tcp:have_established(State) of
        false -> close(Tcb);
        true when Linger =:= 0 -> drop(Tcb, none);
        true -> usrclosed(rcv_flush(Tcb), Ctx)
    end.

-doc """
`tcp_usrclosed`: the owner will send no more (SBS_CANTSENDMORE). CLOSED ends the connection; the handshake
states owe a FIN once established (TF_NEEDFIN); ESTABLISHED moves to FIN-WAIT-1 and
CLOSE-WAIT to LAST-ACK, each owing a FIN that output sends. A connection already in
FIN-WAIT-2 arms 2MSL at the keepalive's maximum idle time (`TP_MAXIDLE`), since FreeBSD's
fast FIN-WAIT-2 recycling is off.
""".
-spec usrclosed(#tcb{}, #tcp_ctx{}) -> #tcb{}.
usrclosed(#tcb{state = State} = Tcb0, Ctx) ->
    Tcb = Tcb0#tcb{snd_closed = true},
    Tcb1 = case State of
               closed -> close(Tcb);
               syn_sent -> Tcb#tcb{fin = queued};
               syn_received -> Tcb#tcb{fin = queued};
               established -> Tcb#tcb{state = fin_wait_1, fin = queued};
               close_wait -> Tcb#tcb{state = last_ack, fin = queued};
               _ -> Tcb
           end,
    case Tcb1 of
        #tcb{state = fin_wait_2, deadlines = D, keep_cnt = Cnt, keep_intvl = Intvl} ->
            Tcb1#tcb{deadlines = D#deadlines{msl2 = Ctx#tcp_ctx.now + ms(Cnt * Intvl)}};
        _ ->
            Tcb1
    end.

-doc """
`tcp_drop`: ends the connection with `Error`, or with no error (`so_error` 0) when the
owner asked for a RST by lingering 0. A connection that has received a SYN sends a RST as it closes. A
timeout reports the last soft error instead, as the owner of a connection that ICMP
reported unreachable sees EHOSTUNREACH rather than ETIMEDOUT.
""".
-spec drop(#tcb{}, atom()) -> #tcb{}.
drop(#tcb{state = State, soft_error = Soft} = Tcb, Error) ->
    Reported = case Error of
                   etimedout when Soft =/= none -> Soft;
                   none -> none;
                   _ -> Error
               end,
    close(Tcb#tcb{reset_peer = erx_tcp:have_rcvd_syn(State), error = Reported}).

-doc "`tcp_close`: the connection has ended (erx_tcp:step/3 settles the rest).".
-spec close(#tcb{}) -> #tcb{}.
close(Tcb) -> Tcb#tcb{state = closed, ended = true}.

ms(Millis) -> Millis * 1000.
