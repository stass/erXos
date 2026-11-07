%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random path texts through erx_schema:resolve_text/1, the reader of the untrusted path
%% text that /proc and the host hand the inspector. Whatever arrives, it answers
%% {ok, Path, Declaration} or {error, bad_path | unknown_path} and makes no atom. Half the
%% texts are paths of the declarations, written by encode/1, a writer that shares no
%% code with the module, and each must read back as its path; the other half are those
%% texts mutated and random bytes. Every text that resolves must be what encode/1 writes
%% for its path, so each path has exactly one spelling. The seed comes from make
%% check-fuzz.

-module(erx_schema_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).
-define(PLAIN, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+,:=@-").

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Pids = [self() | [spawn(fun() -> receive stop -> ok end end) || _ <- lists:seq(1, 3)]],
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(text(Pids)) =:= accepted]),
    [Pid ! stop || Pid <- tl(Pids)],
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

%% The atom count is read around the call alone, since the round's own helpers load code.
round_of({Text, Expected}) ->
    Atoms = erlang:system_info(atom_count),
    Said = erx_schema:resolve_text(Text),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Text}),
    case {Said, Expected} of
        {{ok, Path, Declaration}, _} when Expected =:= none; Expected =:= Path ->
            {ok, Declaration} =:= erx_schema:resolve(Path) orelse error({term_disagrees, Text, Path}),
            canonical(Text) =:= encode(Path) orelse error({second_spelling, Text, Path}),
            accepted;
        {{error, Reason}, none} when Reason =:= bad_path; Reason =:= unknown_path ->
            refused;
        {Said, _} ->
            error({disagrees_with_reference, Text, Expected, Said})
    end.

canonical(<<"/", Rest/binary>>) -> Rest;
canonical(Text) -> Text.

%% {Text, Path} for a written path, {Text, none} for anything else.
text(Pids) ->
    {Path, Text} = written(Pids),
    case rand:uniform(4) of
        1 -> {Text, Path};
        2 -> {<<"/", Text/binary>>, Path};
        3 -> {mutate(Text), none};
        4 -> {noise(), none}
    end.

written(Pids) ->
    Declarations = erx_schema:declarations(),
    #{pattern := Pattern} = lists:nth(rand:uniform(length(Declarations)), Declarations),
    Path = [segment(Element, Pids) || Element <- Pattern],
    {Path, encode(Path)}.

segment({variable, Type}, Pids) -> value(Type, Pids);
segment(Literal, _Pids) -> Literal.

value({type, Name}, Pids) ->
    {ok, Descriptor} = erx_schema:type(Name),
    value(Descriptor, Pids);
value({integer, Minimum, Maximum, 1}, _Pids) ->
    lists:nth(rand:uniform(4), [Minimum, Maximum, Minimum + rand:uniform(Maximum - Minimum + 1) - 1,
                                (Minimum + Maximum) div 2]);
value({text, Maximum, Encoding}, _Pids) ->
    Bytes = << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, rand:uniform(min(Maximum, 12))) >>,
    case Encoding of
        utf8 -> << <<(Byte rem 128)>> || <<Byte>> <= Bytes >>;
        bytes -> Bytes
    end;
value(pid, Pids) ->
    lists:nth(rand:uniform(length(Pids)), Pids).

%% The writer of /proc names and pids, from docs/design-live.md, "The /proc tree".
encode(Path) ->
    iolist_to_binary(lists:join(<<"/">>, [encode_segment(Segment) || Segment <- Path])).

encode_segment(Segment) when is_atom(Segment) -> atom_to_binary(Segment);
encode_segment(Segment) when is_integer(Segment) -> integer_to_binary(Segment);
encode_segment(Segment) when is_pid(Segment) -> list_to_binary(string:trim(pid_to_list(Segment), both, "<>"));
encode_segment(Segment) when is_binary(Segment) ->
    << <<(case lists:member(Byte, ?PLAIN) of
              true -> <<Byte>>;
              false -> list_to_binary(io_lib:format("%~2.16.0B", [Byte]))
          end)/binary>> || <<Byte>> <= Segment >>.

mutate(Text) ->
    Position = rand:uniform(byte_size(Text) + 1) - 1,
    <<Head:Position/binary, Tail/binary>> = Text,
    case {rand:uniform(5), Tail} of
        {1, <<_, Rest/binary>>} -> <<Head/binary, Rest/binary>>;
        {2, <<_, Rest/binary>>} -> <<Head/binary, (piece())/binary, Rest/binary>>;
        {3, _} -> <<Head/binary, (piece())/binary, Tail/binary>>;
        {4, _} -> <<Head/binary, "/", Tail/binary>>;
        _ -> <<Text/binary, "/", (piece())/binary>>
    end.

noise() ->
    iolist_to_binary([piece() || _ <- lists:seq(1, rand:uniform(8) - 1)]).

piece() ->
    Pieces = [<<"/">>, <<"%">>, <<"%2E">>, <<"%2e">>, <<"%41">>, <<"%FF">>, <<".">>, <<"-">>, <<"0">>,
              <<"00">>, <<"-0">>, <<"18446744073709551616">>, <<"4294967295">>, <<"domains">>,
              <<"modules">>, <<"processes">>, <<"budgets">>, <<"cpus">>, <<"budget">>, <<"63">>, <<"64">>,
              <<"0.1.0">>, <<(rand:uniform(256) - 1)>>],
    lists:nth(rand:uniform(length(Pieces)), Pieces).
