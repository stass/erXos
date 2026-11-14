%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% A TCP connection's control block, #tcb{}, translated from FreeBSD's `struct tcpcb`
%% (sys/netinet/tcp_var.h), and the step's context (docs/design-network-stack.md, "The
%% control block" and "One owner, one step"). Sequence numbers are unwrapped integers
%% (erx_tcp_seq). Times are the monotonic clock in microseconds; deadlines are absolute
%% times on that clock, `infinity` when not armed. Where FreeBSD keeps a flag word whose
%% combinations are not all legal, a field holds a variant of the legal ones.

-include("erx_tcp_cc.hrl").

%% The timestamp option once negotiated (TF_RCVD_TSTMP): ts_recent, ts_recent_age (the
%% monotonic time it was taken) and ts_offset, the per-connection offset of our clock.
-record(ts, {recent = 0 :: erx_tcp_seq:wire(),
             recent_age = 0 :: integer(),
             offset :: erx_tcp_seq:wire()}).

%% The deadlines other than retransmission and persist, which share `send_timer`
%% (t_timers[] of tcp_timer.c): delayed ACK, keepalive (also the connection-establishment
%% timeout before ESTABLISHED) and 2MSL (TIME-WAIT, and the end of FIN-WAIT-2).
-record(deadlines, {delack = infinity :: integer() | infinity,
                    keep = infinity :: integer() | infinity,
                    msl2 = infinity :: integer() | infinity}).

%% The snapshot tcp_timer_rexmt takes at the first timeout (snd_cwnd_prev, snd_ssthresh_prev,
%% snd_recover_prev, TF_WASFRECOVERY, TF_WASCRECOVERY, t_badrxtwin under TF_PREVVALID), from
%% which CC_RTO_ERR undoes a spurious timeout. `badrxtwin` is our timestamp clock (milliseconds,
%% without ts_offset) when output last sent a segment during the first retransmission
%% (tcp_output.c:848-849), `none` until then and on a connection without timestamps: an
%% acknowledgement echoing an earlier time answers the original transmission.
-record(rexmt_prev, {cwnd :: non_neg_integer(),
                     ssthresh :: non_neg_integer(),
                     recover :: integer(),
                     fast :: boolean(),
                     cong :: boolean(),
                     badrxtwin :: integer() | none}).

-record(tcb, {
    state = closed :: erx_tcp:state(),          % t_state
    %% INP_DROPPED: tcp_close has run and the connection has ended. A new control block
    %% is in CLOSED too, but has not ended.
    ended = false :: boolean(),
    family :: inet | inet6,
    local :: {Addr :: binary(), Port :: 0..16#ffff},
    remote :: {Addr :: binary(), Port :: 0..16#ffff},

    %% Sequence space (tcp_var.h), unwrapped.
    iss = 0 :: integer(),
    irs = 0 :: integer(),
    snd_una = 0 :: integer(),
    snd_nxt = 0 :: integer(),
    snd_max = 0 :: integer(),
    snd_wl1 = 0 :: integer(),
    snd_wl2 = 0 :: integer(),
    snd_wnd = 0 :: non_neg_integer(),
    max_sndwnd = 0 :: non_neg_integer(),
    snd_up = 0 :: integer(),
    rcv_nxt = 0 :: integer(),
    rcv_adv = 0 :: integer(),
    rcv_wnd = 0 :: non_neg_integer(),
    rcv_up = 0 :: integer(),
    %% The urgent byte that tcp_pulloutofband keeps out of the stream, by its sequence number,
    %% so it is left out however the bytes around it arrive; `none` when there is none ahead.
    rcv_oob = none :: none | integer(),
    last_ack_sent = 0 :: integer(),

    %% TF_SENTFIN and TF_NEEDFIN.
    %% A FIN owed and not sent is `queued`: in SYN-SENT and SYN-RECEIVED it waits for the
    %% handshake (TF_NEEDFIN); in FIN-WAIT-1, CLOSING and LAST-ACK output sends it.
    fin = none :: none | queued | {sent, integer()},
    %% TF_NEEDSYN: a SYN-RECEIVED entered from SYN-SENT on a simultaneous open, whose own SYN
    %% the peer has not acknowledged yet. Its ACK of the SYN leaves SYN-RECEIVED.
    need_syn = false :: boolean(),
    %% Options. Before the handshake completes each holds what our SYN asks for
    %% (TF_REQ_TSTMP, TF_REQ_SCALE, TF_SACK_PERMIT); after it, what was negotiated.
    ts = off :: off | {requested, Offset :: erx_tcp_seq:wire()} | #ts{},
    wscale = off :: off | requested | {SndShift :: 0..14, RcvShift :: 0..14},
    sack = off :: off | requested | on,
    ecn :: erx_tcp_ecn:state(),
    maxseg :: pos_integer(),                    % t_maxseg

    %% Estimators and the seams of loss detection and congestion control.
    rtt :: erx_tcp_rtt:rtt(),
    rtt_probe = none :: none | {Seq :: integer(), SentAt :: integer()}, % t_rtseq, t_rtttime
    sndtime = none :: none | integer(),         % t_sndtime, when snd_max last advanced
    cc :: module(),
    ccv :: #ccv{},
    loss :: module(),
    loss_state :: term(),
    snd_recover = 0 :: integer(),
    rexmt_prev = none :: none | #rexmt_prev{},
    %% t_bytes_acked: appropriate byte counting above ssthresh, which sets #ccv.abc_sentawnd
    %% once a window's worth is acknowledged (cc_ack_received).
    bytes_acked = 0 :: non_neg_integer(),
    sendlog :: erx_tcp_sendlog:log(),

    %% Buffers. The send buffer holds the bytes from snd_una on; received bytes leave the
    %% step in `deliver` actions and stay counted in rcv_buffered until they leave the receive
    %% buffer: read by the owner, or held by a waiting recv.
    sndbuf :: erx_tcp_sndbuf:buf(),
    snd_hiwat :: non_neg_integer(),             % so_snd.sb_hiwat
    %% SB_AUTOSIZE on so_snd: output may grow the send buffer (erx_tcp_output:
    %% sndbuf_autoscale/2) until a reservation is refused.
    snd_autosize = true :: boolean(),
    snd_lowat :: non_neg_integer(),             % so_snd.sb_lowat: free space that wakes a writer
    rcv_hiwat :: non_neg_integer(),             % so_rcv.sb_hiwat
    rcv_buffered = 0 :: non_neg_integer(),      % sbavail(&so->so_rcv)
    snd_closed = false :: boolean(),            % SBS_CANTSENDMORE
    rcv_closed = false :: boolean(),            % SBS_CANTRCVMORE
    reass :: erx_tcp_reass:reass(),
    rcv_sack :: erx_tcp_sack:sack(),

    %% Timers.
    send_timer = none :: none | {rexmt, integer()} | {persist, integer()},
    %% t_rxtshift: the timeouts in a row of the retransmission or persist timer. Stopping
    %% the timer keeps it; FreeBSD resets it on an RTT sample (tcp_xmit_timer), on an undone
    %% spurious timeout (CC_RTO_ERR) and when output leaves persist.
    rxtshift = 0 :: 0..12,
    deadlines = #deadlines{} :: #deadlines{},
    rcvtime :: integer(),                       % t_rcvtime, the last segment received
    keep_init :: pos_integer(),                 % TP_KEEPINIT, milliseconds
    keep_idle :: pos_integer(),                 % TP_KEEPIDLE
    keep_intvl :: pos_integer(),                % TP_KEEPINTVL
    keep_cnt :: pos_integer(),                  % TP_KEEPCNT

    %% Per-step requests to output, which output clears.
    ack_now = false :: boolean(),               % TF_ACKNOW
    force_data = false :: boolean(),            % TF_FORCEDATA
    rxwin0_sent = false :: boolean(),           % TF_RXWIN0SENT: our last window was 0
    %% Output's last pass stopped at a full driver queue (ENOBUFS) with a segment left to
    %% send; while it is set, bytes leaving the receive buffer step the connection, so the
    %% next read sends what the queue held back (erx_tcp:rcvd/2). Each pass sets it afresh.
    stopped_short = false :: boolean(),
    %% The loss module's window for this step's output and the one kept after it, which
    %% input sets from allowance/3 after an acknowledgement (erx_tcp_loss).
    allowance = none :: erx_tcp_loss:allowance(),
    %% Socket options read by the step.
    nodelay = false :: boolean(),               % TF_NODELAY
    linger = off :: off | non_neg_integer(),    % SO_LINGER and so_linger, seconds
    %% TF_CLOSED: the owner closed the socket, so arriving data is answered with a RST.
    user_closed = false :: boolean(),

    %% How the connection ends: the error the owner sees (so_error), the last soft error
    %% (t_softerror, from ICMP), and whether the closing output sends a RST (tcp_drop of a
    %% connection that has received a SYN).
    error = none :: none | atom(),
    soft_error = none :: none | atom(),
    reset_peer = false :: boolean(),

    %% The callers waiting on the connection: `connect` until it is established or ends;
    %% one `send` with the bytes that did not fit yet, until they are all in the buffer.
    connect_waiter = none :: none | gen_server:from(),
    send_waiter = none :: none | {gen_server:from(), Rest :: binary()},

    %% The per-connection challenge-ACK limit (tcp_challenge_ack_check): the end of the
    %% current one-second window (t_challenge_ack_end) and the challenge ACKs sent in it,
    %% `none` before the first.
    challenge = none :: none | {End :: integer(), Sent :: non_neg_integer()},
    gen :: erx_net_rand:gen()      % the connection's random generator, split from its spawner's
}).

%% A received segment lifted into the connection's sequence space by erx_tcp_input's `lift`
%% stage, as the later stages read and trim it: tcp_do_segment's th, thflags, tlen and tiwin
%% and the options of its struct tcpopt that the stages act on. It is a different record
%% from the decoded #tcp{}, so a wire number cannot be mistaken for a lifted one.
-record(seg, {
    seq :: integer(),                   % th_seq against rcv_nxt; past the SYN once it is taken
    ack :: integer(),                   % th_ack against snd_una
    flags :: 0..16#fff,                 % thflags, whose bits the stages clear
    hdr_flags :: 0..16#fff,             % tcp_get_flags(th), what tcp_dropwithreset answers
    win :: non_neg_integer(),           % tiwin: th_win << snd_scale
    urp :: 0..16#ffff,                  % th_urp, which trimming moves
    data :: erx_tcp_payload:t(),        % the payload as trimmed so far, in pieces
    len :: non_neg_integer(),           % tlen: the bytes of data
    %% The segments it stands for: 1, or the count of a merged unit (lro_nsegs), which
    %% cc_ack_received takes.
    nsegs = 1 :: 1..256,
    %% The data's range as it arrived, before any trimming, for erx_tcp_sack:arrived/4.
    arrived :: {integer(), integer()},
    %% TOF_TS: TSval against ts_recent, and TSecr less ts_offset on our millisecond clock,
    %% `none` when it is 0 or later than now, as tcp_do_segment zeroes it.
    ts = none :: none | {Val :: integer(), Ecr :: none | integer()},
    mss = none :: none | 0..16#ffff,    % the options of a SYN
    wscale = none :: none | 0..14,
    sack_permitted = false :: boolean(),
    sacks = [] :: [{integer(), integer()}], % SACK blocks against snd_una
    ip_ecn :: 0..3,                     % the IP header's ECN field, iptos
    link_cast :: unicast | broadcast | multicast % the frame's M_BCAST and M_MCAST
}).

%% The step's context (docs/design-network-stack.md, "One owner, one step"): the monotonic
%% time in microseconds, the frames the transmit path accepts this step, and the path MTU.
-record(tcp_ctx, {now :: integer(),
                  credit :: non_neg_integer(),
                  mtu :: pos_integer(),
                  %% The path's route: `ok`, or ip_output's EHOSTUNREACH when it has none.
                  route = ok :: ok | {error, ehostunreach},
                  %% The path leads to one of the machine's own addresses (its `loopback`,
                  %% in_localip of the foreign address), which shortens TIME-WAIT
                  %% (tcp_eff_msl). erx_tcp_conn:ctx/2, the one maker, takes it from the path.
                  loopback :: boolean()}).
