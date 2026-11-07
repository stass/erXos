%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of /proc's entry names (docs/design-live.md, "The /proc tree"):
%% erx_procfs_core:child/2, the reader of the untrusted name a walk hands the tree, and
%% walk/3 above it. A round takes a directory of a declared path and a name: a third of
%% the names are what name/1 writes for a segment that may stand below the directory,
%% which must read back as that segment; the rest are those names mutated, the tree's
%% marker and file names, and random bytes. Whatever arrives, child/2 answers
%% {ok, Child} or error and makes no atom, and an accepted name is exactly what name/1
%% writes for the last segment of Child, one level below the directory, so each entry
%% has one spelling. walk/3, under a lookup that answers every path, never raises and
%% answers a node or enoent. The seed comes from make check-fuzz.

-module(erx_procfs_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Pids = [self() | [spawn(fun() -> receive stop -> ok end end) || _ <- lists:seq(1, 3)]],
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(case_of(Pids)) =:= accepted]),
    [Pid ! stop || Pid <- tl(Pids)],
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of({Dir, Name, Expected}) ->
    Atoms = erlang:system_info(atom_count),
    Said = erx_procfs_core:child(Dir, Name),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Dir, Name}),
    walked(Dir, Name, Said),
    case {Said, Expected} of
        {{ok, Child}, _} when Expected =:= none; Expected =:= Child ->
            length(Child) =:= length(Dir) + 1 andalso lists:prefix(Dir, Child)
                orelse error({not_one_level_below, Dir, Name, Child}),
            erx_procfs_core:name(lists:last(Child)) =:= Name orelse error({second_spelling, Dir, Name, Child}),
            accepted;
        {error, none} ->
            refused;
        _ ->
            error({disagrees_with_writer, Dir, Name, Expected, Said})
    end.

%% A walk under a lookup that answers every question finds what child/2 found, the
%% status file, a marker or nothing, and never raises.
walked(Dir, Name, Said) ->
    Lookup = fun({exists, _Path}) -> {ok, exists};
                ({listing, Path}) -> listing(Path)
             end,
    case {erx_procfs_core:walk(Dir, Name, Lookup), Said} of
        {{ok, {dir, Child}}, {ok, Child}} -> ok;
        %% A text entry spelled "status", a module's of that name, is shadowed by the
        %% directory's status file (TODO.md, /proc).
        {{ok, {status, Dir}}, _} when Name =:= <<"status">> -> ok;
        {{ok, {partial, Dir}}, error} when Name =:= <<".partial">> -> ok;
        {{error, enoent}, error} -> ok;
        Other -> error({walk_disagrees, Dir, Name, Other})
    end.

%% Every listing is partial, so `.partial` is found below any directory that lists the
%% inspector's entries.
listing(Path) ->
    {ok, #{schema => 1, path => Path, kind => listing, id => lists:last(Path), attrs => #{},
           children => {partial, []}}}.

%% {Dir, Name, Child} for a written name, {Dir, Name, none} for anything else.
case_of(Pids) ->
    {Dir, Child} = written(Pids),
    Name = erx_procfs_core:name(lists:last(Child)),
    case rand:uniform(6) of
        N when N =< 2 -> {Dir, Name, Child};
        3 -> {Dir, mutate(Name), none};
        4 -> {Dir, lists:nth(rand:uniform(6), [<<"status">>, <<".partial">>, <<".unknown">>, <<".">>,
                                                <<"..">>, <<>>]), none};
        5 -> {Dir, noise(), none};
        6 -> {Dir, <<"/", Name/binary>>, none}
    end.

%% A declared path of at least one segment, split into its directory and itself.
written(Pids) ->
    Declarations = [D || #{pattern := [_ | _]} = D <- erx_schema:declarations()],
    #{pattern := Pattern} = lists:nth(rand:uniform(length(Declarations)), Declarations),
    Child = [segment(Element, Pids) || Element <- Pattern],
    {lists:droplast(Child), Child}.

segment({variable, Type}, Pids) -> value(Type, Pids);
segment(Literal, _Pids) -> Literal.

value({type, Name}, Pids) ->
    {ok, Descriptor} = erx_schema:type(Name),
    value(Descriptor, Pids);
value({integer, Minimum, Maximum, 1}, _Pids) ->
    lists:nth(rand:uniform(3), [Minimum, Maximum, Minimum + rand:uniform(Maximum - Minimum + 1) - 1]);
value({text, Maximum, utf8}, _Pids) ->
    Points = [lists:nth(rand:uniform(6), [$a, $., $%, $/, 16#e9, 16#1F600]) || _ <- lists:seq(1, rand:uniform(min(Maximum, 12)))],
    unicode:characters_to_binary(Points);
value(pid, Pids) ->
    lists:nth(rand:uniform(length(Pids)), Pids).

mutate(<<>>) ->
    noise();
mutate(Name) ->
    At = rand:uniform(byte_size(Name)) - 1,
    <<Before:At/binary, Byte, After/binary>> = Name,
    case rand:uniform(3) of
        1 -> <<Before/binary, (rand:uniform(256) - 1), After/binary>>;
        2 -> <<Before/binary, After/binary>>;
        3 -> <<Before/binary, (lists:nth(rand:uniform(5), [$., $%, $/, $0, $<])), Byte, After/binary>>
    end.

noise() ->
    << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, rand:uniform(20)) >>.
