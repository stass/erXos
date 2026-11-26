%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the control tree's ctl file (docs/design-bluetooth.md, "Bonds and
%% the store", "Refusals and error results"): erx_bt_fs_tree:parse/1, the reader of a
%% ctl write. A round takes one of the commands a write may hold, or one the design
%% refuses, as it is, with newlines, blanks or bytes added, mutated, or replaced by random
%% bytes. Whatever arrives, parse/1 makes no atom and never raises, and it agrees with a
%% writer of its own, a regular expression: `forget all` and `forget` with a bond's id, 32
%% lower-case hexadecimal digits, each with at most one trailing newline, the id as
%% written. The seed comes from make check-fuzz.

-module(erx_bt_ctl_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(GRAMMAR, "\\Aforget (?:all|([0-9a-f]{32}))\\n?\\z").
-define(COMMANDS, [<<"forget all">>, <<"forget ALL">>, <<"forget">>, <<"reset">>, <<>>,
                   <<"forget 0123456789abcdef0123456789abcde">>,
                   <<"forget 0123456789abcdef0123456789abcdef0">>,
                   <<"forget 0123456789ABCDEF0123456789ABCDEF">>,
                   <<"forget  0123456789abcdef0123456789abcdef">>,
                   <<"forget 00:1B:DC:0A:0B:0C public">>, <<"forget 00:1B:DC:0A:0B:0C random\n">>]).

run([Seed]) ->
    rand:seed(exsss, {20, 27, list_to_integer(Seed)}),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
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
        {match, [Id]} -> {forget, Id};
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
        6 -> rand:bytes(rand:uniform(48) - 1)
    end.

%% A refused command, or `forget` of a random id, now and then with one digit upper-case,
%% which most rounds take.
command() ->
    case rand:uniform(3) of
        1 -> lists:nth(rand:uniform(length(?COMMANDS)), ?COMMANDS);
        _ -> <<"forget ", (id())/binary>>
    end.

id() ->
    Id = binary:encode_hex(rand:bytes(16), lowercase),
    case rand:uniform(8) of
        1 ->
            At = rand:uniform(32) - 1,
            <<Before:At/binary, Digit, After/binary>> = Id,
            <<Before/binary, (string:to_upper(Digit)), After/binary>>;
        _ ->
            Id
    end.

suffix() ->
    lists:nth(rand:uniform(6), [<<"\n\n">>, <<" ">>, <<"\r\n">>, <<0>>, <<"0">>, rand:bytes(rand:uniform(4))]).

mutated(<<>>) ->
    <<>>;
mutated(Bytes) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Before:At/binary, _:8, After/binary>> = Bytes,
    <<Before/binary, (rand:uniform(256) - 1):8, After/binary>>.
