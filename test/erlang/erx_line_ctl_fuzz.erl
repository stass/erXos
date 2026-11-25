%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the line tree's ctl file (docs/design-bluetooth.md, "The
%% controller's line"): erx_line_fs:parse/1, the reader of one untrusted write and the
%% line service's one grammar. A round takes one of the words a write may hold, or a word
%% the design refuses, as it is, with newlines, blanks or bytes added, mutated, or replaced
%% by random bytes. Whatever arrives, parse/1 makes no atom and never raises, and it
%% accepts exactly reset with at most one trailing newline. The seed comes from make
%% check-fuzz.

-module(erx_line_ctl_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(ACCEPTED, #{<<"reset">> => reset, <<"reset\n">> => reset}).
-define(WORDS, [<<"reset">>, <<"off">>, <<"Reset">>, <<"resets">>, <<>>]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(write()) =:= accepted]),
    case Accepted >= ?ROUNDS div 20 of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of(Write) ->
    Atoms = erlang:system_info(atom_count),
    Said = erx_line_fs:parse(Write),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Write}),
    case {Said, maps:find(Write, ?ACCEPTED)} of
        {{ok, End}, {ok, End}} -> accepted;
        {{error, einval}, error} -> refused;
        _ -> error({disagrees_with_writer, Write, Said})
    end.

write() ->
    Word = lists:nth(rand:uniform(length(?WORDS)), ?WORDS),
    case rand:uniform(6) of
        1 -> Word;
        2 -> <<Word/binary, $\n>>;
        3 -> <<Word/binary, (suffix())/binary>>;
        4 -> <<(suffix())/binary, Word/binary>>;
        5 -> mutated(<<Word/binary, $\n>>);
        6 -> rand:bytes(rand:uniform(16) - 1)
    end.

suffix() ->
    lists:nth(rand:uniform(6), [<<"\n\n">>, <<" ">>, <<"\r\n">>, <<0>>, <<" now\n">>, rand:bytes(rand:uniform(4))]).

mutated(<<>>) ->
    <<>>;
mutated(Bytes) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Before:At/binary, _:8, After/binary>> = Bytes,
    <<Before/binary, (rand:uniform(256) - 1):8, After/binary>>.
