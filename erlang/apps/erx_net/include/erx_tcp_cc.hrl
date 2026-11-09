%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% What a congestion module reads and writes (erx_tcp_cc): FreeBSD's struct cc_var together
%% with the fields of struct tcpcb its modules reach through CCV(). The connection keeps one
%% #ccv{} for its life, as struct tcpcb keeps t_ccv: the module's results (cwnd, ssthresh,
%% the recovery flags, abc_sentawnd and data) stay in it from call to call, and before each
%% call the connection refreshes the inputs from its control block. The inputs that change
%% between calls have no defaults, so one never set fails in arithmetic instead of reading
%% as zero. Byte counts are unwrapped integers, never 32-bit values.
-record(ccv, {
    cwnd :: non_neg_integer(),                 % snd_cwnd
    ssthresh :: non_neg_integer(),             % snd_ssthresh
    %% TF_FASTRECOVERY and TF_CONGRECOVERY. A module enters recovery as FreeBSD's do
    %% (ENTER_RECOVERY sets both, ENTER_CONGRECOVERY the second); the connection leaves it.
    %% Fast recovery without congestion recovery is a state FreeBSD reaches: an ECN mark at
    %% or past the recovery point leaves congestion recovery before the module is called.
    fast_recovery = false :: boolean(),
    cong_recovery = false :: boolean(),
    maxseg :: pos_integer(),                   % tcp_fixed_maxseg(tp), at least 1
    initwnd :: pos_integer(),                  % tcp_compute_initwnd(maxseg), the restart window
    snd_scale :: 0..14,                        % the peer's window shift
    snd_wnd :: non_neg_integer(),              % the peer's window
    pipe :: non_neg_integer(),                 % tcp_compute_pipe(tp), bytes in flight
    rxtshift :: non_neg_integer(),             % t_rxtshift, timeouts in a row
    srtt :: non_neg_integer(),                 % tcp_get_srtt(tp, TCP_TMR_GRANULARITY_USEC)
    rtt_updated :: non_neg_integer(),          % t_rttupdated, RTT samples taken
    rexmit :: boolean(),                       % snd_nxt =/= snd_max: resending after a timeout
    now :: integer(),                          % the monotonic clock in microseconds
    abc_sentawnd = false :: boolean(),         % CCF_ABC_SENTAWND: set by the connection,
                                               % cleared by the module
    labc = none :: none | pos_integer(),       % CCF_USE_LOCAL_ABC with labc
    hystart = off :: erx_tcp_cc:hystart_mode(),% CCF_HYSTART_ALLOWED, _CAN_SH_CWND, _CONS_SSTH
    data :: term()                             % cc_data: the module's own state
}).

%% One acknowledgement as cc_ack_received hands it to a module.
-record(cc_ack, {
    bytes :: non_neg_integer(),                % bytes_this_ack
    nsegs = 1 :: pos_integer(),                % segments coalesced into it
    %% CCF_CWND_LIMITED: snd_cwnd =< snd_wnd (tcp_input.c:301-306). This bounds CUBIC's
    %% growth, which has no TCP_MAXWIN cap of its own, at the peer's window and a segment.
    cwnd_limited :: boolean(),
    curack :: integer()                        % th_ack, unwrapped
}).

%% FreeBSD's net.inet.tcp.cc.newreno.beta and beta_ecn defaults (cc/cc.c:106-108), percent.
-define(NEWRENO_BETA, 50).
-define(NEWRENO_BETA_ECN, 80).
