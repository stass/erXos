%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(oracle_identity_SUITE).
-moduledoc false.
-export([all/0, groups/0, peer_case/1, repeated/1, crash/1,
         timeout/1, init_per_group/2, end_per_group/2, never_started/1,
         huge_integer/1, binary_reason/1]).

all() -> [{group, parallel}, {group, repeated}, crash, timeout,
          {group, skipped}, huge_integer, binary_reason].
groups() ->
    [{parallel, [parallel], [{group, one}, {group, two}, {group, three}]},
     {one, [], [peer_case]}, {two, [], [peer_case]}, {three, [], [peer_case]},
     {repeated, [{repeat, 2}], [repeated]},
     {skipped, [], [never_started]}].

init_per_group(skipped, _Config) -> {skip, same_skip_reason};
init_per_group(_Group, Config) -> Config.
end_per_group(_Group, _Config) -> ok.

peer_case(Config) ->
    ground_truth(peer_case, Config),
    {ok, Peer, _Node} = peer:start_link(#{connection => standard_io,
        args => ["-boot", "no_dot_erlang", "+S", "1", "+SDcpu", "1", "+SDio", "1"]}),
    ok = peer:stop(Peer),
    {skip, same_skip_reason}.

repeated(Config) -> ground_truth(repeated, Config), ok.
crash(Config) -> ground_truth(crash, Config), exit(expected_fixture_crash).
timeout(Config) ->
    ground_truth(timeout, Config),
    ct:timetrap(100),
    receive never -> ok end.
never_started(_Config) -> erlang:error(skipped_case_executed).
huge_integer(Config) -> ground_truth(huge_integer, Config), 1 bsl 100000.
binary_reason(Config) -> ground_truth(binary_reason, Config), {skip, <<255, 254, 0>>}.

ground_truth(Case, Config) ->
    Log = proplists:get_value(tc_logfile, Config),
    Current = proplists:get_value(tc_group_properties, Config, []),
    Parents = proplists:get_value(tc_group_path, Config, []),
    Names = [atom_to_binary(Name, utf8) || Properties <- lists:reverse([Current | Parents]),
              Name <- [proplists:get_value(name, Properties)], Name =/= undefined],
    Record = #{testcase => atom_to_binary(Case, utf8), groups => Names,
               log => unicode:characters_to_binary(Log)},
    Path = filename:join(os:getenv("ERX_GROUND_TRUTH"), filename:basename(Log) ++ ".json"),
    ok = file:write_file(Path, json:encode(Record)).
