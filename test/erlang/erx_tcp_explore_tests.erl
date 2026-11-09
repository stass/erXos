%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% The TCP core's exhaustive exploration (erx_tcp_explore): the base run and the second run
%% with both sequence spaces starting just below 2^32, over the base alphabet and over each
%% of the design's extra dimensions. ERX_TCP_EXPLORE selects the depths:
%%
%% * unset, the landing gate's: the base runs to depth 5, each dimension to depth 3, the
%%   second run of a dimension left out;
%% * `full`, the milestone gate's (tools/erx check-fuzz): the base runs to the design's
%%   depth of 8 and each dimension, both runs, to its own bound (full_depth/1);
%% * `base`, the base runs to depth 8 and the dimensions at the landing gate's, for a seeded
%%   failure the base finds only deep.
%%
%% A violation fails the case with the property's name and its shortest trace. Each run
%% must also reach the cases its properties exist for (erx_tcp_explore's hits): the fast
%% path, a RST accepted, an old ACK judged, and each dimension's own.

-module(erx_tcp_explore_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FULL_DEPTH, 8).
-define(LANDING_DEPTH, 5).
-define(LANDING_DIMENSION_DEPTH, 3).

mode() ->
    case os:getenv("ERX_TCP_EXPLORE") of
        "full" -> full;
        "base" -> base;
        _ -> landing
    end.

base_depth() ->
    case mode() of
        landing -> ?LANDING_DEPTH;
        _ -> ?FULL_DEPTH
    end.

dimension_depth(Dimension) ->
    case mode() of
        full -> full_depth(Dimension);
        _ -> ?LANDING_DIMENSION_DEPTH
    end.

%% A dimension's bound in place of the design's 8: the depth at which one run takes up to
%% about half a minute; each level deeper costs two to three times as much.
full_depth(icmp) -> 8;
full_depth(ecn) -> 5;
full_depth(window) -> 5;
full_depth(_) -> 6.

%% The base cases its properties judge, which every base run reaches.
-define(BASE_HITS, [header_prediction_agrees, rst_only_at_last_ack_sent,
                    old_ack_keeps_send_window]).

%% Each dimension's own case: an option stripped and compared, a CWR sent, an urgent byte
%% kept out, a pass sending more than one segment and a window probe at the edge, a
%% report in flight acted on.
hits(timestamps) -> [options_unnegotiated_ignored, paws_drops_older];
hits(ecn) -> [cwr_only_after_reduction, options_unnegotiated_ignored];
hits(urgent) -> [delivered_in_order];
hits(sack) -> [options_unnegotiated_ignored];
hits(window) -> [sent_within_maxseg, sent_within_peer_window, options_unnegotiated_ignored];
hits(icmp) -> [icmp_outside_flight_changes_nothing].

base_run_test_() ->
    {timeout, 280, fun() -> explores(#{depth => base_depth(), wrap => false}, ?BASE_HITS) end}.

wrap_run_test_() ->
    {timeout, 280, fun() -> explores(#{depth => base_depth(), wrap => true}, ?BASE_HITS) end}.

dimension_runs_test_() ->
    Wraps = case mode() of
                full -> [false, true];
                _ -> [false]
            end,
    [{atom_to_list(D) ++ case Wrap of true -> " wrapped"; false -> "" end,
      {timeout, 280,
       fun() -> explores(#{depth => dimension_depth(D), wrap => Wrap, dimension => D}, hits(D)) end}}
     || D <- erx_tcp_explore:dimensions(), Wrap <- Wraps].

%% Every property holds to the depth, over more abstract states than the handshake alone
%% reaches, so the alphabet gets past it, and the named properties judged their cases.
explores(Opts, Hits) ->
    #{depth := Depth} = Opts,
    Result = erx_tcp_explore:explore(Opts),
    ?assertMatch({ok, #{depth := Depth, states := States}} when States > 100, Result),
    {ok, #{hits := Reached}} = Result,
    ?assertEqual([], [Name || Name <- Hits, not maps:is_key(Name, Reached)]).
