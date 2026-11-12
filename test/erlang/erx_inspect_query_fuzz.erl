%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the inspect facet's request decoder (docs/design-live.md, "The
%% inspect service", Bounds): erx_inspect_query:decode/1, the reader of the term another
%% domain sends through its inspect facet. A round builds a request: a third are requests
%% the interface takes, over the paths abi/inspection.txt declares; the rest are those
%% requests mutated (a path past 16 segments, an improper list, a segment of another
%% shape or out of range, an atom no path holds, an option the interface does not name,
%% a scope among the options, an extra element) and random terms. Whatever arrives,
%% decode/1 never raises, makes no atom, and agrees with in_bounds/1 below, which
%% restates the Bounds: it answers {ok, Request} for a request within them and
%% {error, badarg} for any other. The seed comes from make check-fuzz.

-module(erx_inspect_query_fuzz).
-export([run/1]).

-define(ROUNDS, 30000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).
-define(MAX_SEGMENTS, 16).
-define(MAX_TEXT, 765).
-define(MAX_LIMIT, 1000).
-define(U32, 16#100000000).
-define(U64, 16#10000000000000000).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Literals = literals(),
    %% Loading the decoder and the modules it calls makes atoms; a round must not.
    {ok, _} = erx_inspect_query:decode({inspect, [], #{offset => 0, limit => 1}}),
    {error, badarg} = erx_inspect_query:decode({entries, [bad_segment]}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(request(Literals), Literals) =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of(Request, Literals) ->
    Atoms = erlang:system_info(atom_count),
    Said = try erx_inspect_query:decode(Request)
           catch Class:Reason -> error({decode_raised, Request, Class, Reason})
           end,
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Request}),
    case {Said, in_bounds(Request, Literals)} of
        {{ok, Request}, true} -> accepted;
        {{error, badarg}, false} -> refused;
        {{ok, _}, false} -> error({accepted_out_of_bounds, Request});
        {_, true} -> error({refused_in_bounds, Request, Said})
    end.

%% The Bounds, restated: one of the two operations, a proper path of at most 16
%% segments, and options holding at most offset and limit.
in_bounds({inspect, Path, Options}, Literals) ->
    path_in_bounds(Path, Literals) andalso options_in_bounds(Options);
in_bounds({entries, Path}, Literals) ->
    path_in_bounds(Path, Literals);
in_bounds(_Request, _Literals) ->
    false.

path_in_bounds(Path, Literals) ->
    is_list(Path) andalso proper(Path) andalso length(Path) =< ?MAX_SEGMENTS andalso
        lists:all(fun(Segment) -> segment_in_bounds(Segment, Literals) end, Path).

proper([]) -> true;
proper([_ | Rest]) -> proper(Rest);
proper(_Tail) -> false.

segment_in_bounds(Atom, Literals) when is_atom(Atom) -> lists:member(Atom, Literals);
segment_in_bounds(Integer, _) when is_integer(Integer) -> 0 =< Integer andalso Integer < ?U64;
segment_in_bounds({pid, D, N, S}, _) -> lists:all(fun(Part) -> is_integer(Part) andalso 0 =< Part andalso Part < ?U32 end, [D, N, S]);
segment_in_bounds(Text, _) when is_binary(Text) -> byte_size(Text) =< ?MAX_TEXT;
segment_in_bounds(_Segment, _) -> false.

options_in_bounds(Options) when is_map(Options) ->
    lists:all(fun({offset, Offset}) -> is_integer(Offset) andalso 0 =< Offset andalso Offset < ?U64;
                 ({limit, Limit}) -> is_integer(Limit) andalso 1 =< Limit andalso Limit =< ?MAX_LIMIT;
                 (_Other) -> false
              end, maps:to_list(Options));
options_in_bounds(_Options) ->
    false.

literals() ->
    lists:usort([Atom || #{pattern := Pattern} <- erx_schema:declarations(), Atom <- Pattern, is_atom(Atom)]).

%% A request: a third within the Bounds, the rest mutated or random.
request(Literals) ->
    Good = good(),
    case rand:uniform(9) of
        N when N =< 3 -> Good;
        4 -> mutate_path(Good, Literals);
        5 -> mutate_path(Good, Literals);
        6 -> mutate_options(Good);
        7 -> mutate_shape(Good);
        8 -> {pick([inspect, entries]), long_path(), #{}};
        9 -> noise(3)
    end.

good() ->
    Path = path(),
    case rand:uniform(2) of
        1 -> {entries, Path};
        2 -> {inspect, Path, maps:from_list(lists:sublist([{offset, pick([0, ?U64 - 1, rand:uniform(1000)])},
                                                           {limit, pick([1, ?MAX_LIMIT, rand:uniform(?MAX_LIMIT)])}],
                                                          rand:uniform(3) - 1))}
    end.

%% A declared path with each variable filled, or a prefix of one.
path() ->
    Declarations = erx_schema:declarations(),
    #{pattern := Pattern} = lists:nth(rand:uniform(length(Declarations)), Declarations),
    Path = [segment(Element) || Element <- Pattern],
    lists:sublist(Path, rand:uniform(length(Path) + 1) - 1).

segment({variable, Type}) -> value(Type);
segment(Literal) -> Literal.

value({type, Name}) ->
    {ok, Descriptor} = erx_schema:type(Name),
    value(Descriptor);
value({integer, Minimum, Maximum, 1}) ->
    pick([Minimum, Maximum, Minimum + rand:uniform(Maximum - Minimum + 1) - 1]);
value({text, Maximum, utf8}) ->
    pick([<<>>, binary:copy(<<"a">>, min(Maximum, ?MAX_TEXT)), <<"init">>]);
value(proc_id) ->
    {pid, part(), part(), part()}.

part() -> pick([0, ?U32 - 1, rand:uniform(?U32) - 1]).

%% A path of 15 to 18 segments the Bounds take one by one, so only its length decides.
long_path() ->
    [pick([0, <<"x">>, {pid, 0, 1, 0}]) || _ <- lists:seq(1, ?MAX_SEGMENTS - 1 + rand:uniform(4))].

mutate_path({entries, Path}, Literals) -> {entries, mutated(Path, Literals)};
mutate_path({inspect, Path, Options}, Literals) -> {inspect, mutated(Path, Literals), Options}.

mutated(Path, Literals) ->
    case rand:uniform(6) of
        1 -> Path ++ long_path();
        2 -> improper(Path);
        3 -> insert(Path, bad_segment());
        4 -> insert(Path, pick(stray_atoms(Literals)));
        5 -> insert(Path, pick([?U64 - 1, <<0:(?MAX_TEXT * 8)>>, {pid, ?U32 - 1, 0, ?U32 - 1}]));
        6 -> noise(2)
    end.

improper([]) -> pick([inspect, 0, <<>>]);
improper(Path) -> lists:foldr(fun(Segment, Tail) -> [Segment | Tail] end, pick([0, <<>>, kernel]), Path).

insert(Path, Segment) ->
    At = rand:uniform(length(Path) + 1) - 1,
    {Before, After} = lists:split(At, Path),
    Before ++ [Segment | After].

bad_segment() ->
    pick([-1, ?U64, 1.0, <<0:((?MAX_TEXT + 1) * 8)>>, {pid, ?U32, 0, 0}, {pid, 0, -1, 0},
          {pid, 0, 0}, {pid, 0, 0, 0, 0}, {pid, a, 0, 0}, [kernel], #{}, self(), make_ref(), "text"]).

%% Atoms that exist but name no path segment, some of them a scope's.
stray_atoms(Literals) ->
    [Atom || Atom <- [all, own, scope, true, undefined, pid, ok, error, inspect, entries, offset, limit],
             not lists:member(Atom, Literals)].

mutate_options({entries, Path}) ->
    {entries, Path, #{}};
mutate_options({inspect, Path, Options}) ->
    case rand:uniform(6) of
        1 -> {inspect, Path, Options#{scope => pick([all, own, {domain, 1}])}};
        2 -> {inspect, Path, Options#{limit => pick([0, ?MAX_LIMIT + 1, -1, 1.0, all])}};
        3 -> {inspect, Path, Options#{offset => pick([-1, ?U64, 0.5, undefined])}};
        4 -> {inspect, Path, maps:to_list(Options)};
        5 -> {inspect, Path, Options#{pick([timeout, kind, 0, <<"limit">>]) => 1}};
        6 -> {inspect, Path, noise(1)}
    end.

mutate_shape(Request) ->
    Elements = tuple_to_list(Request),
    case rand:uniform(4) of
        1 -> list_to_tuple(Elements ++ [noise(1)]);
        2 -> list_to_tuple(lists:droplast(Elements));
        3 -> list_to_tuple([pick([read, list, call, 'inspect ', all]) | tl(Elements)]);
        4 -> Elements
    end.

%% A random term of at most Depth levels.
noise(0) ->
    pick([0, -7, ?U64, 3.5, <<>>, <<"proc">>, kernel, []]);
noise(Depth) ->
    case rand:uniform(5) of
        1 -> noise(0);
        2 -> [noise(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)];
        3 -> list_to_tuple([noise(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)]);
        4 -> #{noise(0) => noise(Depth - 1)};
        5 -> {pick([inspect, entries]), noise(Depth - 1)}
    end.

pick(Choices) -> lists:nth(rand:uniform(length(Choices)), Choices).
