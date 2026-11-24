%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the control tree's ctl file (docs/design-bluetooth.md, "Bonds and
%% the store", "Refusals and error results"): erx_bt_fs_tree:parse/1, the reader of a
%% ctl write. A round takes one of the commands a write may hold, or one the design
%% refuses, as it is, with newlines, blanks or bytes added, mutated, or replaced by random
%% bytes. Whatever arrives, parse/1 makes no atom and never raises, and it agrees with a
%% writer of its own, a regular expression: `forget all` and `forget` with six colon-split
%% pairs of hex digits, one space and `public` or `random`, each with at most one
%% trailing newline, the address's octets in the order written. The seed comes from make
%% check-fuzz.

-module(erx_bt_ctl_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(HEX, "([0-9A-Fa-f]{2})").
-define(GRAMMAR, "\\Aforget (?:all|" ?HEX ":" ?HEX ":" ?HEX ":" ?HEX ":" ?HEX ":" ?HEX
                  " (public|random))\\n?\\z").
-define(COMMANDS, [<<"forget all">>, <<"forget ALL">>, <<"forget">>, <<"reset">>, <<>>,
                   <<"forget +0:1B:DC:0A:0B:0C">>, <<"forget -1:1B:DC:0A:0B:0C">>,
                   <<"forget 00:1B:DC:0A:0B public">>, <<"forget 00-1B-DC-0A-0B-0C public">>,
                   <<"forget 00:1B:DC:0A:0B:0C">>, <<"forget 00:1B:DC:0A:0B:0C PUBLIC">>,
                   <<"forget 00:1B:DC:0A:0B:0C  random">>, <<"forget 00:1B:DC:0A:0B:0C static">>]).

run([Seed]) ->
    rand:seed(exsss, {20, 27, list_to_integer(Seed)}),
    [{module, _} = code:ensure_loaded(Module) || Module <- [erx_bt_fs_tree, binary, lists, re]],
    {ok, Grammar} = re:compile(?GRAMMAR),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(write(), Grammar) =:= accepted]),
    case Accepted >= ?ROUNDS div 20 of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of(Write, Grammar) ->
    Atoms = erlang:system_info(atom_count),
    Said = erx_bt_fs_tree:parse(Write),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Write}),
    case {Said, written(Write, Grammar)} of
        {{ok, Command}, Command} -> accepted;
        {{error, einval}, refused} -> refused;
        _ -> error({disagrees_with_writer, Write, Said})
    end.

%% What the writer means by Write: the command, or refused.
written(Write, Grammar) ->
    case re:run(Write, Grammar, [{capture, all_but_first, binary}]) of
        {match, []} -> {forget, all};
        {match, Captured} ->
            {Pairs, [Type]} = lists:split(6, Captured),
            {forget, {binary_to_existing_atom(Type), << <<(binary_to_integer(Pair, 16))>> || Pair <- Pairs >>}};
        nomatch -> refused
    end.

write() ->
    Command = command(),
    case rand:uniform(6) of
        1 -> Command;
        2 -> <<Command/binary, $\n>>;
        3 -> <<Command/binary, (suffix())/binary>>;
        4 -> <<(suffix())/binary, Command/binary>>;
        5 -> mutated(<<Command/binary, $\n>>);
        6 -> rand:bytes(rand:uniform(32) - 1)
    end.

%% A refused command, or `forget` of a random address in random case with its type, which
%% most rounds take.
command() ->
    case rand:uniform(3) of
        1 -> lists:nth(rand:uniform(length(?COMMANDS)), ?COMMANDS);
        _ -> iolist_to_binary(["forget ", lists:join($:, [pair() || _ <- lists:seq(1, 6)]), $\s, type()])
    end.

type() -> lists:nth(rand:uniform(2), [<<"public">>, <<"random">>]).

pair() ->
    Pair = io_lib:format("~2.16.0B", [rand:uniform(256) - 1]),
    case rand:uniform(2) of
        1 -> Pair;
        2 -> string:lowercase(Pair)
    end.

suffix() ->
    lists:nth(rand:uniform(6), [<<"\n\n">>, <<" ">>, <<"\r\n">>, <<0>>, <<":0D">>, rand:bytes(rand:uniform(4))]).

mutated(<<>>) ->
    <<>>;
mutated(Bytes) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Before:At/binary, _:8, After/binary>> = Bytes,
    <<Before/binary, (rand:uniform(256) - 1):8, After/binary>>.
