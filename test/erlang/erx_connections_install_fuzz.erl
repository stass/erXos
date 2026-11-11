%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random sequences of messages to a domain's connection agent, erx_connections, as its
%% registry's installer (docs/design-system.md, "Facets a configured domain serves"):
%% installations {erx_facets_install, Tag, Name, Facet} in the system connection's
%% envelope, in another domain's envelope and bare, with tags, names and facets of every
%% shape (no integer, no atom, no pid, another domain's pid), tuples of the wrong size,
%% the facets answer in another domain's envelope, and arbitrary terms. The test process
%% plays the agent's kernel and its domain pid, as erx_connections_tests does.
%%
%% Whatever arrives, the agent stays up, and after every message:
%% * the registry, the persistent term {erx, facets}, holds exactly the installations a
%%   model took: those in the system connection's envelope with an integer tag, an atom
%%   name and a pid, each replacing an older pid of its name;
%% * each such installation, and nothing else, is acknowledged to the domain pid with
%%   its tag, in order;
%% * every other message is dropped and counted.
%% The seed comes from make check-fuzz.

-module(erx_connections_install_fuzz).
-export([run/1]).

-define(SYSTEM, 4).
-define(SEQUENCES, 2000).
-define(STEPS, 60).

run([Seed]) ->
    rand:seed(exsss, {16#c0, 16#11, list_to_integer(Seed)}),
    Tally = lists:foldl(fun(_, T) -> sequence(T) end, #{}, lists:seq(1, ?SEQUENCES)),
    io:format("fuzz: ~p sequences ok~n", [?SEQUENCES]),
    [io:format("~p: ~p~n", [Key, N]) || Key := N <- maps:iterator(Tally, ordered)],
    ok.

%% One agent per sequence, its registry empty at the start.
sequence(Tally) ->
    persistent_term:erase({erx, facets}),
    Agent = start(),
    try
        {Model, Dropped, Done} = lists:foldl(fun(_, Acc) -> message(Agent, Acc) end, {#{}, 0, Tally},
                                             lists:seq(1, ?STEPS)),
        Model =:= persistent_term:get({erx, facets}, #{}) orelse fail(registry_differs, Model),
        Done#{dropped => maps:get(dropped, Done, 0) + Dropped}
    after
        stop(Agent)
    end.

%% A message to the agent, then the agent's dropped count, which it answers after the
%% message, so the message has been acted on; the registry, the answers and the count
%% are checked against the model.
message(Agent, {Model, Dropped, Tally}) ->
    Message = random_message(),
    Agent ! Message,
    Count = gen_server:call(Agent, dropped),
    is_process_alive(Agent) orelse fail(agent_ended, Message),
    case accepted(Message) of
        {yes, Tag, Name, Facet} ->
            receive
                {erx_facets_installed, Tag} -> ok
            after 1000 -> fail(not_acknowledged, Tag)
            end,
            Next = Model#{Name => Facet},
            Count =:= Dropped orelse fail(counted_an_installation, Message),
            Next =:= persistent_term:get({erx, facets}, #{}) orelse fail(registry_differs, Message),
            nothing_else(),
            {Next, Dropped, Tally#{installed => maps:get(installed, Tally, 0) + 1}};
        no ->
            Count =:= Dropped + 1 orelse fail(not_counted, Message),
            Model =:= persistent_term:get({erx, facets}, #{}) orelse fail(installed_a_dropped_message, Message),
            nothing_else(),
            {Model, Dropped + 1, Tally}
    end.

%% The model: what the agent may install.
accepted({erx_origin, ?SYSTEM, {erx_facets_install, Tag, Name, Facet}})
  when is_integer(Tag), is_atom(Name), is_pid(Facet) ->
    {yes, Tag, Name, Facet};
accepted(_Message) ->
    no.

nothing_else() ->
    receive
        Other -> fail(unexpected_answer, Other)
    after 0 -> ok
    end.

random_message() ->
    Body = case rand:uniform(8) of
               1 -> random_term();
               2 -> {erx_facets, #{data => pid(5)}};
               3 -> list_to_tuple([erx_facets_install | [field() || _ <- lists:seq(1, pick([0, 1, 2, 4, 5]))]]);
               _ -> {erx_facets_install, tag(), name(), facet()}
           end,
    case rand:uniform(6) of
        1 -> Body;
        2 when element(1, Body) =:= erx_facets -> {erx_origin, pick([5, 99]), Body};
        2 -> {erx_origin, pick([5, 99, 0, -4, 4.0, system, self()]), Body};
        _ when element(1, Body) =:= erx_facets -> {erx_origin, 5, Body};
        _ -> {erx_origin, ?SYSTEM, Body}
    end.

tag() -> pick([1, 2, 7, 1 bsl 70, -3, 0, 1.0, tag, <<1>>, make_ref()]).
name() -> pick([data, echo, log, data, '', <<"data">>, 1, {data}, "data"]).
facet() -> pick([pid(5), pid(5), pid(99), self(), data, fun() -> ok end, make_ref(), {pid(5)}, [pid(5)]]).
field() -> pick([tag(), name(), facet()]).

random_term() ->
    pick([[], <<0, 255>>, {}, lists:duplicate(1000, x), #{a => b}, 3.5, {ok}, erx_facets_install,
          lists:foldl(fun(_, T) -> {T} end, x, lists:seq(1, 200))]).

%% A pid of domain Domain's node, as another domain's facet reaches this one.
pid(Domain) ->
    Name = atom_to_binary(list_to_atom("d" ++ integer_to_list(Domain) ++ "@h")),
    binary_to_term(<<131, 88, 119, (byte_size(Name)), Name/binary, 1:32, 0:32, Domain:32>>).

%% The agent, as erx_connections_tests starts it: the test process is its kernel and its
%% domain pid; no connection is ever introduced, so its opener is never called.
start() ->
    Test = self(),
    Agent = spawn(fun() ->
                          process_flag(trap_exit, true),
                          erx_connections:introduced(Test, ?SYSTEM, Test, fun(_) -> error(no_open) end)
                  end),
    %% introduced/4 names the domain pid before it serves a message.
    0 = gen_server:call(Agent, dropped),
    Agent.

stop(Agent) ->
    Monitor = monitor(process, Agent),
    exit(Agent, kill),
    receive {'DOWN', Monitor, process, Agent, _} -> ok end.

fail(What, Detail) ->
    error({check_failed, What, Detail}).

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
