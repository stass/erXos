%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the code_objects facet's request decoder (docs/design-system.md,
%% "The code_objects facet"): erx_code_objects_facet:decode/1, the reader of the requests
%% a session sends for its code objects. A round builds a request: a third are creates
%% and drops the interface takes, their numbers at the edges most often; the rest are
%% those requests mutated (a number of 0, negative, past its bound or of another kind, an
%% extra element naming another session, another operation, a list for a tuple) and
%% random terms. Whatever arrives, decode/1 never raises, makes no atom, and agrees with
%% in_bounds/1 below, which restates the interface: it answers {ok, Request} for a
%% request within it and {error, badarg} for any other. The seed comes from make
%% check-fuzz.

-module(erx_code_objects_facet_fuzz).
-export([run/1]).

-define(ROUNDS, 30000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).
-define(SIZE_LIMIT, 1 bsl 64).
-define(NUMBER_LIMIT, 1 bsl 32).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    {ok, _} = erx_code_objects_facet:decode({create, 1}),
    {error, badarg} = erx_code_objects_facet:decode({resize, 1}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(request()) =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of(Request) ->
    Atoms = erlang:system_info(atom_count),
    Said = try erx_code_objects_facet:decode(Request)
           catch Class:Reason -> error({decode_raised, Request, Class, Reason})
           end,
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Request}),
    case {Said, in_bounds(Request)} of
        {{ok, Request}, true} -> accepted;
        {{error, badarg}, false} -> refused;
        {{ok, _}, false} -> error({accepted_out_of_bounds, Request});
        {_, true} -> error({refused_in_bounds, Request, Said})
    end.

%% The interface, restated: a create of a size in 1..2^64-1 or a drop of a number in
%% 1..2^32-1, and nothing else.
in_bounds({create, Size}) -> is_integer(Size) andalso Size >= 1 andalso Size < ?SIZE_LIMIT;
in_bounds({drop, Number}) -> is_integer(Number) andalso Number >= 1 andalso Number < ?NUMBER_LIMIT;
in_bounds(_Request) -> false.

%% A request: a third within the interface, the rest mutated or random.
request() ->
    Good = good(),
    case rand:uniform(6) of
        N when N =< 2 -> Good;
        3 -> mutate_number(Good);
        4 -> mutate_shape(Good);
        5 -> {pick([create, drop]), noise(2)};
        6 -> noise(3)
    end.

good() ->
    case rand:uniform(2) of
        1 -> {create, number(?SIZE_LIMIT)};
        2 -> {drop, number(?NUMBER_LIMIT)}
    end.

%% A number in 1..Limit-1, the edges most often.
number(Limit) ->
    case rand:uniform(4) of
        1 -> 1;
        2 -> Limit - 1;
        3 -> rand:uniform(4096);
        4 -> rand:uniform(Limit - 1)
    end.

%% The number past either edge, or of another kind; a drop's may be a size's.
mutate_number({Operation, Number}) ->
    Bad = case rand:uniform(6) of
              1 -> 0;
              2 -> -rand:uniform(?SIZE_LIMIT);
              3 -> limit(Operation) + rand:uniform(3) - 1;
              4 -> ?SIZE_LIMIT + rand:uniform(?SIZE_LIMIT);
              5 -> pick([float(Number), integer_to_binary(Number), integer_to_list(Number), one, [], self()]);
              6 -> pick([{Number}, [Number], #{size => Number}])
          end,
    {Operation, Bad}.

limit(create) -> ?SIZE_LIMIT;
limit(drop) -> ?NUMBER_LIMIT.

%% The request's shape changed: another session named beside the number, an element
%% missing, another operation's name, or a list for the tuple.
mutate_shape({Operation, Number} = Request) ->
    case rand:uniform(5) of
        1 -> {Operation, rand:uniform(?NUMBER_LIMIT), Number};
        2 -> {Operation, Number, noise(1)};
        3 -> {Operation};
        4 -> {pick([resize, seal, map, code_object, code_drop, 'create ', <<"create">>, "drop"]), Number};
        5 -> tuple_to_list(Request)
    end.

%% A random term of at most Depth levels.
noise(0) ->
    pick([0, 1, -7, 3.5, <<>>, <<"create">>, create, drop, []]);
noise(Depth) ->
    case rand:uniform(5) of
        1 -> noise(0);
        2 -> [noise(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)];
        3 -> list_to_tuple([noise(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)]);
        4 -> #{noise(0) => noise(Depth - 1)};
        5 -> {pick([create, drop]), noise(Depth - 1)}
    end.

pick(Choices) -> lists:nth(rand:uniform(length(Choices)), Choices).
