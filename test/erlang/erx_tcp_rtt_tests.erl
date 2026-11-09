%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_tcp_rtt against RFC 6298's estimator (design-network-stack.md, "The send log, loss and
%% congestion: properties and a FreeBSD oracle"), and the backoff of tcp_timer_rexmt.
-module(erx_tcp_rtt_tests).

-include_lib("eunit/include/eunit.hrl").

%% Before any sample the RTO is RFC 6298's initial 1 s.
new_test() ->
    ?assertEqual(1000, erx_tcp_rtt:rto(erx_tcp_rtt:new())).

%% RFC 6298 2.2: the first sample R gives SRTT = R, RTTVAR = R/2, RTO = 3R, plus FreeBSD's
%% 200 ms slop (TCPT_RANGESET).
first_sample_test() ->
    Rtt = erx_tcp_rtt:sample(erx_tcp_rtt:new(), 100, 0),
    ?assertEqual(100 * 32, erx_tcp_rtt:srtt(Rtt)),
    ?assertEqual(500, erx_tcp_rtt:rto(Rtt)).

%% RFC 6298 2.3 over random sample sequences: FreeBSD's fixed point follows the RFC's
%% SRTT and RTO, computed in floating point, within the bias its comments describe (the
%% sample is taken from origin 0, `rtt - 1`, and shifts truncate: within a tick on SRTT
%% and four on RTO, at every scale) with FreeBSD's 200 ms slop added to an RTO of at least 30 ms
%% (TCP_REXMTVAL), and the RTO stays within [max(30, R + 2), 64000].
rfc6298_test() ->
    _ = rand:seed(exsss, {6, 2, 98}),
    [check_sequence([rand:uniform(Scale) || _ <- lists:seq(1, 200)])
     || Scale <- [5, 50, 400, 3000, 40000], _ <- lists:seq(1, 20)].

check_sequence([First | Rest]) ->
    Start = {erx_tcp_rtt:sample(erx_tcp_rtt:new(), First, 0), float(First), First / 2},
    lists:foldl(fun(R, {Rtt0, Srtt0, Var0}) ->
                        Rtt = erx_tcp_rtt:sample(Rtt0, R, 0),
                        Var = 0.75 * Var0 + 0.25 * abs(Srtt0 - R),
                        Srtt = 0.875 * Srtt0 + 0.125 * R,
                        Rto = erx_tcp_rtt:rto(Rtt),
                        ?assert(abs(erx_tcp_rtt:srtt(Rtt) / 32 - Srtt) =< 1),
                        ?assert(Rto >= max(30, R + 2) andalso Rto =< 64000),
                        Expected = min(64000, max(max(30, R + 2), max(30, Srtt + 4 * Var) + 200)),
                        ?assert(abs(Rto - Expected) =< 4),
                        {Rtt, Srtt, Var}
                end, Start, Rest).

%% After more than TCP_RTT_INVALIDATE (3) backoffs the estimate is retaken from the sample,
%% not smoothed into the old one.
invalidate_test() ->
    Old = erx_tcp_rtt:sample(erx_tcp_rtt:new(), 1000, 0),
    ?assertNotEqual(10 * 32, erx_tcp_rtt:srtt(erx_tcp_rtt:sample(Old, 10, 3))),
    ?assertEqual(10 * 32, erx_tcp_rtt:srtt(erx_tcp_rtt:sample(Old, 10, 4))).

%% tcp_timer_rexmt: the handshake doubles the initial RTO, a synchronized connection its
%% REXMTVAL, both up to tcp_backoff's 512 and the 64 s cap.
backoff_test() ->
    New = erx_tcp_rtt:new(),
    ?assertEqual(2200, erx_tcp_rtt:rto(erx_tcp_rtt:backoff(New, handshake, 1))),
    ?assertEqual(64000, erx_tcp_rtt:rto(erx_tcp_rtt:backoff(New, handshake, 7))),
    Rtt = erx_tcp_rtt:sample(New, 10, 0),
    ?assertEqual(30, erx_tcp_rtt:rexmtval(Rtt)),
    ?assertEqual(30 * 8 + 200, erx_tcp_rtt:rto(erx_tcp_rtt:backoff(Rtt, synchronized, 3))),
    ?assertEqual(30 * 512 + 200, erx_tcp_rtt:rto(erx_tcp_rtt:backoff(Rtt, synchronized, 12))).

%% Samples above 64 s, which a peer can cause by echoing an old timestamp, still leave the
%% RTO at 64 s: the cap applies after the floor of the sample plus two ticks.
cap_test() ->
    Rtt = lists:foldl(fun(_, R) -> erx_tcp_rtt:sample(R, 1000000, 0) end,
                      erx_tcp_rtt:new(), lists:seq(1, 50)),
    ?assertEqual(64000, erx_tcp_rtt:rto(Rtt)).
