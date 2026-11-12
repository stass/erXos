%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% The exhaustive exploration of erx_pipe:step/2 (erx_pipe_explore), with
%% the design's limits scaled down: a quota of two lanes, numbers up to 4
%% and two read ends a pipe. A violation fails the case with the property's
%% name, what it found and its shortest trace. The run must also reach the
%% cases its properties exist for. The landing gate explores to ?DEPTH
%% (about 30 s); the milestone gate (tools/erx check-fuzz) sets
%% ERX_PIPE_EXPLORE_DEPTH=full for ?FULL_DEPTH, and a number sets that
%% depth. Depth 8 takes about 130 s and 6 GB on an Apple M-series host with
%% stock OTP 29.1.2; depth 9 took about 630 s and more than 10 GB, too much
%% for a gate.

-module(erx_pipe_explore_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DEPTH, 7).
-define(FULL_DEPTH, 8).

-define(HITS, [pipe_made, {pipe, {enfile, quota}}, {pipe, {enfile, number}},
               {inherit, emfile}, {inherit, {enfile, quota}}, {inherit, {enfile, number}},
               {inherited, read}, {inherited, write}, inherit_forged,
               writer_joined, reader_joined, writer_gone_told, reader_gone_told,
               drained, drained_last, lock_freed, lost_reported, notice_ignored,
               gone_with_ends, pipe_forgotten]).

depth() ->
    case os:getenv("ERX_PIPE_EXPLORE_DEPTH") of
        false -> ?DEPTH;
        "full" -> ?FULL_DEPTH;
        Depth -> list_to_integer(Depth)
    end.

exploration_test_() ->
    {timeout, 800,
     fun() ->
             Result = erx_pipe_explore:explore(#{depth => depth()}),
             ?assertMatch({ok, #{states := States}} when States > 1000, Result),
             {ok, #{hits := Hits} = Stats} = Result,
             io:format(user, "erx_pipe_explore: ~p~n", [maps:without([hits], Stats)]),
             ?assertEqual([], [H || H <- ?HITS, not maps:is_key(H, Hits)])
     end}.
