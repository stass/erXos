%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the log facet's request decoder (docs/design-log.md, "Verification
%% and testing"): erx_log_facet:decode/1, the reader of the records another domain sends
%% through its log facet. A round builds a request: a third are writes the interface
%% takes, of 0 to 16 records at every level with texts of 0 to 4,096 bytes; the rest are
%% those writes mutated (past 16 records, a text past 4,096 bytes or not a binary, an
%% atom that is no level, an improper list, a record of another shape, an extra element,
%% another operation) and random terms. Whatever arrives, decode/1 never raises, makes
%% no atom, and agrees with in_bounds/1 below, which restates the interface: it answers
%% {ok, Records} for a write within it and {error, badarg} for any other request. The
%% seed comes from make check-fuzz.

-module(erx_log_facet_fuzz).
-export([run/1]).

-define(ROUNDS, 30000).
-define(MIN_ACCEPTED, ?ROUNDS div 10).
-define(WRITE_MAX, 16).
-define(TEXT_MAX, 4096).
-define(LEVELS, [emergency, alert, critical, error, warning, notice, info, debug]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loading the decoder and the modules it calls makes atoms; a round must not.
    {ok, _} = erx_log_facet:decode({write, [{info, <<>>}]}),
    {error, badarg} = erx_log_facet:decode({write, [{bad_level, <<>>}]}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(request()) =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of(Request) ->
    Atoms = erlang:system_info(atom_count),
    Said = try erx_log_facet:decode(Request)
           catch Class:Reason -> error({decode_raised, Request, Class, Reason})
           end,
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Request}),
    case {Said, in_bounds(Request)} of
        {{ok, Records}, true} when {write, Records} =:= Request -> accepted;
        {{error, badarg}, false} -> refused;
        {{ok, _}, false} -> error({accepted_out_of_bounds, Request});
        {_, true} -> error({refused_in_bounds, Request, Said})
    end.

%% The interface, restated: one write of a proper list of at most 16 records, each a
%% level and a binary of at most 4,096 bytes.
in_bounds({write, Records}) ->
    is_list(Records) andalso proper(Records) andalso length(Records) =< ?WRITE_MAX andalso
        lists:all(fun record_in_bounds/1, Records);
in_bounds(_Request) ->
    false.

proper([]) -> true;
proper([_ | Rest]) -> proper(Rest);
proper(_Tail) -> false.

record_in_bounds({Level, Text}) ->
    lists:member(Level, ?LEVELS) andalso is_binary(Text) andalso byte_size(Text) =< ?TEXT_MAX;
record_in_bounds(_Record) ->
    false.

%% A request: a third within the interface, the rest mutated or random.
request() ->
    Good = {write, [record() || _ <- lists:seq(1, rand:uniform(?WRITE_MAX + 1) - 1)]},
    case rand:uniform(9) of
        N when N =< 3 -> Good;
        4 -> mutate_records(Good);
        5 -> mutate_records(Good);
        6 -> mutate_record(Good);
        7 -> mutate_shape(Good);
        8 -> {write, [record() || _ <- lists:seq(1, ?WRITE_MAX + rand:uniform(4))]};
        9 -> noise(3)
    end.

record() -> {pick(?LEVELS), text()}.

%% A text of 0 to 4,096 bytes, the edges most often, of any bytes: the decoder looks at
%% a text's size alone.
text() ->
    case rand:uniform(4) of
        1 -> <<>>;
        2 -> binary:copy(<<"a">>, ?TEXT_MAX);
        3 -> rand:bytes(rand:uniform(64) - 1);
        4 -> binary:copy(<<16#1b, 16#ff>>, rand:uniform(?TEXT_MAX div 2))
    end.

%% The list mutated: longer than 16, improper, or with a stray element inserted.
mutate_records({write, Records}) ->
    case rand:uniform(4) of
        1 -> {write, Records ++ [record() || _ <- lists:seq(1, ?WRITE_MAX + 1 - length(Records))]};
        2 -> {write, improper(Records, pick([{info, <<>>}, nil, <<>>, 0]))};
        3 -> {write, insert(Records, pick([info, <<"text">>, {info}, {info, <<>>, extra}, [{info, <<>>}], #{}]))};
        4 -> {write, insert(Records, noise(2))}
    end.

%% One record mutated: a text past the bound or of another kind, or a level that is not one.
mutate_record({write, Records}) ->
    Level = pick(?LEVELS),
    Bad = case rand:uniform(3) of
              1 -> {Level, binary:copy(<<"a">>, ?TEXT_MAX + rand:uniform(3))};
              2 -> {Level, pick(["text", [<<"io">>, <<"list">>], <<1:7>>, text, 0, self()])};
              3 -> {pick([warn, all, none, fatal, write, ok, true, undefined, <<"info">>, "info", 3]), text()}
          end,
    {write, insert(Records, Bad)}.

%% List's elements ending in Tail instead of [], or Tail alone for an empty list.
improper(List, Tail) -> lists:foldr(fun(Element, Rest) -> [Element | Rest] end, Tail, List).

insert(List, Element) ->
    At = rand:uniform(length(List) + 1) - 1,
    {Before, After} = lists:split(At, List),
    Before ++ [Element | After].

mutate_shape({write, Records} = Request) ->
    case rand:uniform(4) of
        1 -> {write, Records, noise(1)};
        2 -> {write};
        3 -> {pick([inspect, entries, log, 'write ', read]), Records};
        4 -> tuple_to_list(Request)
    end.

%% A random term of at most Depth levels.
noise(0) ->
    pick([0, -7, 3.5, <<>>, <<"info">>, info, write, []]);
noise(Depth) ->
    case rand:uniform(5) of
        1 -> noise(0);
        2 -> [noise(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)];
        3 -> list_to_tuple([noise(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)]);
        4 -> #{noise(0) => noise(Depth - 1)};
        5 -> {write, noise(Depth - 1)}
    end.

pick(Choices) -> lists:nth(rand:uniform(length(Choices)), Choices).
