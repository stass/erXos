%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_version_tests).
-moduledoc """
EUnit tests of the domain's file version counter
(docs/design-files.md#identity-and-version): draws start at 1, never repeat
under concurrent drawers, refuse rather than wrap at 2^64 - 1, and the
published counter survives a second `init/0`.
""".

-include_lib("eunit/include/eunit.hrl").

-define(LAST, 16#ffffffffffffffff).

draws_start_at_one_and_count_up_test() ->
    Counter = erx_fs_version:new(),
    ?assertEqual([{ok, 1}, {ok, 2}, {ok, 3}],
                 [erx_fs_version:draw(Counter) || _ <- lists:seq(1, 3)]).

the_last_value_is_drawn_once_then_refused_test() ->
    Counter = erx_fs_version:new(),
    atomics:put(Counter, 1, ?LAST - 1),
    ?assertEqual({ok, ?LAST}, erx_fs_version:draw(Counter)),
    ?assertEqual({error, eio}, erx_fs_version:draw(Counter)),
    ?assertEqual({error, eio}, erx_fs_version:draw(Counter)),
    ?assertEqual(?LAST, atomics:get(Counter, 1)).

concurrent_draws_never_repeat_test() ->
    Counter = erx_fs_version:new(),
    Parent = self(),
    Drawers = [spawn(fun() ->
                             Values = [V || _ <- lists:seq(1, 5000),
                                            {ok, V} <- [erx_fs_version:draw(Counter)]],
                             Parent ! {drawn, self(), Values}
                     end) || _ <- lists:seq(1, 8)],
    Drawn = lists:append([receive {drawn, Pid, Values} -> Values end || Pid <- Drawers]),
    ?assertEqual(lists:seq(1, 40000), lists:sort(Drawn)).

init_publishes_once_test() ->
    Key = {erx_fs_version, counter},
    persistent_term:erase(Key),
    try
        ok = erx_fs_version:init(),
        {ok, 1} = erx_fs_version:draw(),
        ok = erx_fs_version:init(),
        ?assertEqual({ok, 2}, erx_fs_version:draw())
    after
        persistent_term:erase(Key)
    end.
