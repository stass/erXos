%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the ble facet's admission (docs/design-bluetooth.md, "The `ble`
%% facet" and "Fuzz targets"): erx_ble_facet:admit/3, the reader of what an app in
%% another domain asks of the registry. A round builds a request: a third are operations
%% of the interface's shapes, naming a granted service or another one, a reply's answer
%% at and near each edge of the Application Error range (the generated ABI header's); the rest are those requests
%% with one field given another type, a field dropped or added, another operation, and
%% random terms. Whatever arrives, admit/3 never raises, makes no atom, keeps its state,
%% and agrees with verdict/2 below, which restates the interface: it forwards
%% {facet, Caller, Request} to the registered registry for an operation of the
%% interface's shapes that names a granted service or is a reply, refuses not_granted
%% for one naming another service, and refuses badarg for anything else. The seed comes
%% from make check-fuzz.

-module(erx_ble_facet_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(ROUNDS, 30000).
-define(MIN_FORWARDED, ?ROUNDS div 10).
-define(GRANTED, [console, battery]).
%% The other services: names no grant holds, and the atoms the facet and the registry
%% use as literals, which a decoded request may name as a service all the same.
-define(OTHERS, [heart_rate, hid, ble, none, reply, ok, error, undefined]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Registry = spawn_link(fun idle/0),
    true = register(erx_gatt_srv, Registry),
    Caller = self(),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    Grant = grant(),
    {forward, Registry, _, Grant} = erx_ble_facet:admit({attach, console}, Caller, Grant),
    Forwarded = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(request(), Registry, Caller) =:= forward]),
    case Forwarded >= ?MIN_FORWARDED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Forwarded]);
        false -> error({too_few_forwarded, Forwarded})
    end.

% The request the facet forwards: an attach with the grant's identity, every other as made.
as_granted({attach, Service}) -> {attach, Service, false};
as_granted(Request) -> Request.

%% The grant the rounds are admitted under: the services of GRANTED, no identity.
grant() -> #{services => ?GRANTED, identity => false}.

idle() ->
    receive stop -> ok end.

round_of(Request, Registry, Caller) ->
    Atoms = erlang:system_info(atom_count),
    Said = try erx_ble_facet:admit(Request, Caller, grant())
           catch Class:Reason -> error({admit_raised, Request, Class, Reason})
           end,
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Request}),
    Expected = verdict(Request, ?GRANTED),
    Forwarded = as_granted(Request),
    Grant = grant(),
    case {Expected, Said} of
        {forward, {forward, Registry, {facet, Caller, Forwarded}, Grant}} -> forward;
        {Refusal, {refuse, Refusal, Grant}} -> Refusal;
        {forward, _} -> error({should_forward, Request, Said});
        {badarg, _} -> error({should_refuse_badarg, Request, Said});
        {not_granted, _} -> error({should_refuse_not_granted, Request, Said})
    end.

%% The interface, restated: an operation of one of the four shapes, naming a service of
%% Granted, is forwarded, and a reply names no service; one naming another service is
%% not granted; anything else is badarg.
verdict({attach, Service}, Granted) when is_atom(Service) ->
    granted(Service, Granted);
verdict({set, Service, Char, Value}, Granted) when is_atom(Service), is_atom(Char), is_binary(Value) ->
    granted(Service, Granted);
verdict({Kind, Conn, Service, Char, Value}, Granted)
  when (Kind =:= notify orelse Kind =:= indicate), is_reference(Conn), is_atom(Service), is_atom(Char),
       is_binary(Value) ->
    granted(Service, Granted);
verdict({reply, Req, ok}, _Granted) when is_reference(Req) ->
    forward;
verdict({reply, Req, {error, value_not_allowed}}, _Granted) when is_reference(Req) ->
    forward;
verdict({reply, Req, {error, Code}}, _Granted)
  when is_reference(Req), is_integer(Code), Code >= ?ERX_ATT_APPLICATION_ERROR_MIN,
       Code =< ?ERX_ATT_APPLICATION_ERROR_MAX ->
    forward;
verdict(_Request, _Granted) ->
    badarg.

granted(Service, Granted) ->
    case lists:member(Service, Granted) of
        true -> forward;
        false -> not_granted
    end.

%% A request: a third of the interface's shapes, the rest mutated or random.
request() ->
    Good = case rand:uniform(5) of
               1 -> {attach, service()};
               2 -> {set, service(), char(), value()};
               3 -> {pick([notify, indicate]), make_ref(), service(), char(), value()};
               4 -> {reply, make_ref(), answer()};
               5 -> {reply, make_ref(), {error, code()}}
           end,
    case rand:uniform(9) of
        N when N =< 3 -> Good;
        N when N =< 6 -> mutate_field(Good);
        7 -> mutate_shape(Good);
        8 -> noise(3);
        9 -> list_to_tuple([pick([attach, set, notify, indicate, reply])
                            | [noise(1) || _ <- lists:seq(1, rand:uniform(6) - 1)]])
    end.

%% A granted service most often, else another one.
service() ->
    case rand:uniform(3) of
        3 -> pick(?OTHERS);
        _ -> pick(?GRANTED)
    end.

char() -> pick([tx, rx, level, x]).

value() -> bytes(rand:uniform(24) - 1).

bytes(N) -> << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, N) >>.

answer() -> pick([ok, {error, value_not_allowed}]).

%% An Application Error code, the range's edges and just past them most often.
code() ->
    case rand:uniform(3) of
        1 -> pick([?ERX_ATT_APPLICATION_ERROR_MIN - 1, ?ERX_ATT_APPLICATION_ERROR_MIN,
                   ?ERX_ATT_APPLICATION_ERROR_MAX, ?ERX_ATT_APPLICATION_ERROR_MAX + 1]);
        _ -> rand:uniform(16#100) - 1
    end.

%% One field of Request after its operation given another type.
mutate_field(Request) ->
    At = rand:uniform(tuple_size(Request) - 1) + 1,
    setelement(At, Request, bad_field(element(At, Request))).

bad_field(Field) when is_reference(Field) -> pick([0, <<"ref">>, self(), {ref}]);
bad_field(Field) when is_atom(Field) -> pick([<<"console">>, "console", 0, {console}]);
bad_field(Field) when is_binary(Field) -> pick([binary_to_list(Field), 0, <<1:3>>, [Field]]);
bad_field({error, _}) ->
    pick([{error, ?ERX_ATT_APPLICATION_ERROR_MIN - 1}, {error, ?ERX_ATT_APPLICATION_ERROR_MAX + 1}, {error, -1},
          {error, ?ERX_ATT_APPLICATION_ERROR_MIN, x}, {error, 1.0e2}, {error, value_not_allowed_}, {ok}, error,
          {error, <<?ERX_ATT_APPLICATION_ERROR_MIN>>}]);
bad_field(_Field) -> pick([okay, {ok, 1}, 0, [], <<>>]).

%% The request's shape changed: a field dropped or added, another operation, or a list.
mutate_shape(Request) ->
    Fields = tuple_to_list(Request),
    case rand:uniform(5) of
        1 -> list_to_tuple(lists:droplast(Fields));
        2 -> list_to_tuple(Fields ++ [noise(1)]);
        3 -> list_to_tuple([pick([attach, set, notify, indicate, reply, write, detach, facet]) | tl(Fields)]);
        4 -> Fields;
        5 -> element(1, Request)
    end.

%% A random term of at most Depth levels.
noise(0) ->
    pick([0, -7, 3.5, <<>>, <<"console">>, console, heart_rate, none, reply, ok, error, [], 16#80]);
noise(Depth) ->
    case rand:uniform(5) of
        1 -> noise(0);
        2 -> [noise(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)];
        3 -> list_to_tuple([noise(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)]);
        4 -> #{noise(0) => noise(Depth - 1)};
        5 -> {attach, noise(Depth - 1)}
    end.

pick(Choices) -> lists:nth(rand:uniform(length(Choices)), Choices).
