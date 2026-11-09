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
%% which CC_RTO_ERR undoes a spurious timeout.
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
    last_ack_sent = 0 :: integer(),

    %% TF_SENTFIN and TF_NEEDFIN.
    %% A FIN owed and not sent is `queued`: in SYN-SENT and SYN-RECEIVED it waits for the
    %% handshake (TF_NEEDFIN); in FIN-WAIT-1, CLOSING and LAST-ACK output sends it.
    fin = none :: none | queued | {sent, integer()},
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
    cc :: module(),
    ccv :: #ccv{},
    loss :: module(),
    loss_state :: term(),
    snd_recover = 0 :: integer(),
    rexmt_prev = none :: none | #rexmt_prev{},
    sendlog :: erx_tcp_sendlog:log(),

    %% Buffers. The send buffer holds the bytes from snd_una on; received bytes leave the
    %% step in `deliver` actions and stay counted in rcv_buffered until the owner reads them.
    sndbuf :: erx_tcp_sndbuf:buf(),
    snd_hiwat :: non_neg_integer(),             % so_snd.sb_hiwat
    snd_lowat :: non_neg_integer(),             % so_snd.sb_lowat: free space that wakes a writer
    rcv_hiwat :: non_neg_integer(),             % so_rcv.sb_hiwat
    rcv_buffered = 0 :: non_neg_integer(),      % sbavail(&so->so_rcv)
    snd_closed = false :: boolean(),            % SBS_CANTSENDMORE
    rcv_closed = false :: boolean(),            % SBS_CANTRCVMORE
    reass :: erx_tcp_reass:reass(),
    rcv_sack :: erx_tcp_sack:sack(),

    %% Timers.
    send_timer = none :: none | {rexmt, integer(), non_neg_integer()}
                       | {persist, integer(), non_neg_integer()},
    deadlines = #deadlines{} :: #deadlines{},
    rcvtime :: integer(),                       % t_rcvtime, the last segment received
    keep_init :: pos_integer(),                 % TP_KEEPINIT, milliseconds
    keep_idle :: pos_integer(),                 % TP_KEEPIDLE
    keep_intvl :: pos_integer(),                % TP_KEEPINTVL
    keep_cnt :: pos_integer(),                  % TP_KEEPCNT

    %% Per-step requests to output, which output clears.
    ack_now = false :: boolean(),               % TF_ACKNOW
    force_data = false :: boolean(),            % TF_FORCEDATA
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

    %% The per-connection challenge-ACK limit (tcp_send_challenge_ack): the start of the
    %% current one-second window and the challenge ACKs sent in it.
    challenge = {0, 0} :: {integer(), non_neg_integer()},
    gen :: erx_net_rand:gen()      % the connection's random generator, split from its spawner's
}).

%% The step's context (docs/design-network-stack.md, "One owner, one step"): the monotonic
%% time in microseconds, the frames the transmit path accepts this step, and the path MTU.
-record(tcp_ctx, {now :: integer(),
                  credit :: non_neg_integer(),
                  mtu :: pos_integer()}).
