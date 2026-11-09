%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% An acknowledgement as a loss module sees it (erx_tcp_loss): the segment's fields and the
%% control block's, read where tcp_do_segment reads them (sys/netinet/tcp_input.c). The
%% connection fills it after its own checks: th_ack is at most snd_max, and sequence numbers
%% are unwrapped integers. The #ccv{} is the connection's, refreshed, and carries cwnd,
%% ssthresh, maxseg, t_rxtshift and the two recovery flags.
-record(loss_ack, {
    ack :: integer(),                          % th_ack
    %% snd_una before this segment: ack/4 sets it from the log, the one authority for snd_una
    una :: integer() | undefined,
    snd_nxt :: integer(),                      % snd_nxt
    recover :: integer(),                      % snd_recover
    sack_opt = false :: boolean(),             % TOF_SACK: the segment carried SACK blocks
    sack_blocks = [] :: [{integer(), integer()}], % right edges exclusive
    %% RFC 5681's conditions for a duplicate without SACK: no data and the window unchanged
    pure :: boolean(),
    new_fin = false :: boolean(),              % TH_FIN and not TCPS_HAVERCVDFIN(t_state)
    rexmt_armed :: boolean(),                  % tcp_timer_active(tp, TT_REXMT)
    ccv :: erx_tcp_cc:ccv()
}).
