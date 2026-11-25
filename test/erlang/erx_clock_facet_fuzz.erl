%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the clock facet's request decoder (docs/design-time.md,
%% "Verification and testing", erx_clock_facet_fuzz): erx_clock_facet:decode/1, the
%% reader of what another domain sends the wall clock's authority. A round builds a
%% request: a third are samples and sets the interface takes, their fields at and near
%% each edge; the rest are those requests with one field moved past its bound or given
%% another type, a field dropped or added, another operation, and random terms.
%% Whatever arrives, decode/1 never raises, makes no atom, and agrees with in_bounds/1
%% below, which restates the interface: it answers {ok, Request} for a request within
%% it and {error, badarg} for any other; and operation/1 names the operation of what
%% decode/1 admits and error for anything else, so the grant's check and admit/3 read
%% each request one way. The bounds come from the generated ABI header; the seed comes
%% from make check-fuzz.

-module(erx_clock_facet_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(ROUNDS, 30000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).
-define(OFFSET_MAX, ?ERX_TIME_OFFSET_MAX).
-define(DISTANCE_MAX, ?ERX_CLOCK_DISTANCE_MAX_NS).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    {ok, _} = erx_clock_facet:decode({set, 0}),
    {ok, set} = erx_clock_facet:operation({set, 0}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(request()) =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of(Request) ->
    Atoms = erlang:system_info(atom_count),
    Said = try erx_clock_facet:decode(Request)
           catch Class:Reason -> error({decode_raised, Request, Class, Reason})
           end,
    Operation = try erx_clock_facet:operation(Request)
                catch OpClass:OpReason -> error({operation_raised, Request, OpClass, OpReason})
                end,
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Request}),
    agreed(Request, Said, Operation),
    case {Said, in_bounds(Request)} of
        {{ok, Request}, true} -> accepted;
        {{error, badarg}, false} -> refused;
        {{ok, _}, false} -> error({accepted_out_of_bounds, Request});
        {_, true} -> error({refused_in_bounds, Request, Said})
    end.

%% operation/1 answers the first element of what decode/1 admits, and error for the rest.
agreed(_Request, {ok, Decoded}, {ok, Operation}) when Operation =:= element(1, Decoded) -> ok;
agreed(_Request, {error, badarg}, error) -> ok;
agreed(Request, Said, Operation) -> error({operation_disagrees, Request, Said, Operation}).

%% The interface, restated: a sample of an offset, a distance, a stratum of 1 to 15 and
%% an IPv4 address, or a set of an offset.
in_bounds({sample, W, Distance, Stratum, Server}) ->
    offset(W) andalso is_integer(Distance) andalso Distance >= 0 andalso Distance < ?DISTANCE_MAX andalso
        is_integer(Stratum) andalso Stratum >= 1 andalso Stratum =< 15 andalso address(Server);
in_bounds({set, W}) ->
    offset(W);
in_bounds(_Request) ->
    false.

offset(W) -> is_integer(W) andalso W >= 0 andalso W =< ?OFFSET_MAX.

address(Server) ->
    is_tuple(Server) andalso tuple_size(Server) =:= 4 andalso
        lists:all(fun(Byte) -> is_integer(Byte) andalso Byte >= 0 andalso Byte =< 255 end, tuple_to_list(Server)).

%% A request: a third within the interface, the rest mutated or random.
request() ->
    Good = case rand:uniform(2) of
               1 -> {sample, offset(), distance(), stratum(), {byte(), byte(), byte(), byte()}};
               2 -> {set, offset()}
           end,
    case rand:uniform(9) of
        N when N =< 3 -> Good;
        N when N =< 6 -> mutate_field(Good);
        7 -> mutate_shape(Good);
        8 -> noise(3);
        9 -> list_to_tuple([pick([sample, set]) | [noise(1) || _ <- lists:seq(1, rand:uniform(6) - 1)]])
    end.

%% Values within each bound, the edges most often.
offset() -> edge(0, ?OFFSET_MAX).
distance() -> edge(0, ?DISTANCE_MAX - 1).
stratum() -> edge(1, 15).
byte() -> edge(0, 255).

edge(Low, High) ->
    case rand:uniform(4) of
        1 -> Low;
        2 -> High;
        _ -> Low + rand:uniform(High - Low + 1) - 1
    end.

%% One field of Request moved just past its bound, or given another type.
mutate_field(Request) ->
    At = rand:uniform(tuple_size(Request) - 1) + 1,
    setelement(At, Request, bad_field(At, element(1, Request))).

bad_field(At, sample) when At =:= 5 ->
    pick([{byte(), byte(), byte()}, {byte(), byte(), byte(), byte(), byte()}, {256, 0, 0, 0}, {0, 0, 0, -1},
          {0, 0, 0, a}, [0, 0, 0, 0], {0, 0, 0, 1.0}, <<0, 0, 0, 0>>]);
bad_field(At, sample) when At =:= 4 ->
    pick([0, 16, -1, 1.0, one, <<1>>]);
bad_field(At, sample) when At =:= 3 ->
    pick([-1, ?DISTANCE_MAX, ?DISTANCE_MAX + 1, 0.0, [], self()]);
bad_field(_At, _Operation) ->
    pick([-1, ?OFFSET_MAX + 1, ?OFFSET_MAX * 2, 1.0, <<0>>, "0", set, #{}, 1 bsl 64]).

%% The request's shape changed: a field dropped or added, another operation, or a list.
mutate_shape(Request) ->
    Fields = tuple_to_list(Request),
    case rand:uniform(5) of
        1 -> list_to_tuple(lists:droplast(Fields));
        2 -> list_to_tuple(Fields ++ [noise(1)]);
        3 -> list_to_tuple([pick([sample, set, write, sample_, 'set ', clock, read]) | tl(Fields)]);
        4 -> Fields;
        5 -> element(1, Request)
    end.

%% A random term of at most Depth levels.
noise(0) ->
    pick([0, -7, 3.5, <<>>, <<"set">>, set, sample, [], ?OFFSET_MAX + 1]);
noise(Depth) ->
    case rand:uniform(5) of
        1 -> noise(0);
        2 -> [noise(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)];
        3 -> list_to_tuple([noise(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)]);
        4 -> #{noise(0) => noise(Depth - 1)};
        5 -> {set, noise(Depth - 1)}
    end.

pick(Choices) -> lists:nth(rand:uniform(length(Choices)), Choices).
