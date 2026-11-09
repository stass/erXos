%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% The TCP core's exhaustive exploration (erx_tcp_explore) over the base alphabet: the base
%% run and the second run with both sequence spaces starting just below 2^32. With
%% ERX_TCP_EXPLORE=full each explores to the design's depth of 8 events after connect, as
%% the milestone gate runs it (tools/erx check-fuzz); otherwise to the landing gate's depth.
%% A violation fails the case with the property's name and its shortest trace.

-module(erx_tcp_explore_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FULL_DEPTH, 8).
-define(LANDING_DEPTH, 5).

depth() ->
    case os:getenv("ERX_TCP_EXPLORE") of
        "full" -> ?FULL_DEPTH;
        _ -> ?LANDING_DEPTH
    end.

base_run_test_() ->
    {timeout, 280, fun() -> explores(false) end}.

wrap_run_test_() ->
    {timeout, 280, fun() -> explores(true) end}.

%% Every property holds to the depth, over more abstract states than the handshake alone
%% reaches, so the alphabet gets past it.
explores(Wrap) ->
    Depth = depth(),
    Result = erx_tcp_explore:explore(#{depth => Depth, wrap => Wrap}),
    ?assertMatch({ok, #{depth := Depth, states := States}} when States > 100, Result).
