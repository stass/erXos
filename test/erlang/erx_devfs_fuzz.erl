%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of /dev's two readers of untrusted bytes (docs/design-system.md,
%% "The /dev tree"): erx_devfs_core:find/2, which reads the name a walk hands the
%% tree, and erx_devfs_core:command/1, which reads a write to ctl. A round makes a
%% catalogue of a few devices, each with a random index, role and compatible string
%% (random bytes or none), and then a name and a write: a third of each are what the
%% tree writes or takes (a shown device's name/1, one of ctl's six spellings), the rest
%% those mutated, other devices' names and random bytes. Whatever arrives, neither
%% raises nor makes an atom; find/2 accepts a name only when it is exactly name/1 of a
%% device the tree shows, and command/1 only the six spellings, each read as its
%% operation. The seed comes from make check-fuzz.

-module(erx_devfs_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).
-define(SPELLINGS, [{<<"stop">>, stop}, {<<"stop\n">>, stop}, {<<"start">>, start},
                    {<<"start\n">>, start}, {<<"reset">>, restart}, {<<"reset\n">>, restart}]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = lists:sum([round_of() || _ <- lists:seq(1, ?ROUNDS)]),
    case Accepted >= 2 * ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

%% The number of the round's two inputs that were accepted.
round_of() ->
    Devices = [device(Index) || Index <- lists:usort([rand:uniform(20) - 1 || _ <- lists:seq(1, 4)])],
    Name = name_case(Devices),
    Write = write_case(),
    Atoms = erlang:system_info(atom_count),
    Found = erx_devfs_core:find(Name, Devices),
    Command = erx_devfs_core:command(Write),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Name, Write}),
    found(Name, Devices, Found) + commanded(Write, Command).

found(Name, Devices, {ok, Device}) ->
    lists:member(Device, erx_devfs_core:shown(Devices)) orelse error({not_shown, Name, Device}),
    erx_devfs_core:name(Device) =:= Name orelse error({second_spelling, Name, Device}),
    1;
found(Name, Devices, error) ->
    [error({name_refused, Name, Device})
     || Device <- erx_devfs_core:shown(Devices), erx_devfs_core:name(Device) =:= Name],
    0.

commanded(Write, Command) ->
    case {lists:keyfind(Write, 1, ?SPELLINGS), Command} of
        {{Write, Operation}, {ok, Operation}} -> 1;
        {false, {error, einval}} -> 0;
        _ -> error({command_disagrees, Write, Command})
    end.

%% A catalogue entry of index Index, which is unique within a catalogue, as the
%% manifest's device rows are.
device(Index) ->
    #{index => Index, unit => 0, unit_name => <<"block">>, row => 1,
      role => pick([block, block, net, none]),
      compatible => pick([<<"virtio,mmio">>, none, bytes(12)]),
      registers => {16#a003e00, 512}, ranges => [{16#a003000, 4096}], lines => [79],
      confined => false, holder => 6}.

name_case(Devices) ->
    Names = [erx_devfs_core:name(Device) || Device <- Devices],
    case rand:uniform(3) of
        1 -> pick(Names);
        2 -> mutate(pick(Names ++ [<<"status">>, <<"ctl">>, <<"..">>]));
        3 -> bytes(24)
    end.

write_case() ->
    case rand:uniform(3) of
        1 -> element(1, pick(?SPELLINGS));
        2 -> mutate(element(1, pick(?SPELLINGS)));
        3 -> bytes(40)
    end.

%% Bytes with one byte inserted, removed, replaced or repeated, or the whole repeated.
mutate(<<>>) ->
    bytes(4);
mutate(Bytes) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Before:At/binary, Byte, After/binary>> = Bytes,
    case rand:uniform(5) of
        1 -> <<Before/binary, (rand:uniform(256) - 1), Byte, After/binary>>;
        2 -> <<Before/binary, After/binary>>;
        3 -> <<Before/binary, (rand:uniform(256) - 1), After/binary>>;
        4 -> <<Before/binary, Byte, Byte, After/binary>>;
        5 -> <<Bytes/binary, Bytes/binary>>
    end.

bytes(Most) ->
    << <<(pick([$\n, $-, $,, $%, $/, $0, $1, $a, rand:uniform(256) - 1]))>>
       || _ <- lists:seq(1, rand:uniform(Most + 1) - 1) >>.

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
