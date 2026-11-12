%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_inspect_agent).
-moduledoc """
A domain's inspection agent (docs/design-live.md, "The runtime agent"):
the one process through which the system domain's inspector asks what
only this runtime knows, its processes and the paths below them.

* Every domain but the system domain starts it, from kernel's safe
  supervisor, before init's ready report, which names it as `inspect`
  and so exports it to the system domain with `send` (edit 65). In the
  system domain, and on a host that is not erXos, start_link/0 answers
  `ignore`: there the inspector collects for itself.
* It takes only `{erx_origin, SystemId, {erx_inspect_ask, Alias, Query}}`
  with `Alias` a reference, the envelope the system connection puts on a
  frame from the system domain, and answers `Alias ! {Alias, Answer}`.
  Every other message, another domain's question included, it drops and
  counts in its process dictionary as `dropped`, for a local debugger;
  no inspection record shows the count yet.
* It answers only what its own domain owns (owns/2): `[domains, Self |
  _]`, and `[processes, P | _]` for a `P` of its own domain, every path
  the schema declares below a process included; and the listing
  `{entries, [processes]}`, its own processes. Every other question is
  `{error, scope}`: a runtime describes only itself. Within that, the
  answer is its collectors' record at scope `all`, with only the
  attributes `runtime` reports: the system domain's query worker
  (erx_inspect_worker), not the agent, gives the rest and applies the
  asker's scope.
* It takes questions one at a time, in arrival order. Its listing is the
  inspector's page: at most 1,000 entries, and an encoding within
  inspect_reply_max. A question whose collector
  raises is answered `{error, failed}`, so no question ends the agent.
* The domain record keeps the pid the one ready report named, for the
  domain's life, so a second agent would be one nobody can reach: kernel
  starts it `temporary`, and a domain whose agent ended has none.
""".

-export([start_link/0, start_link/2, answer/2, handle/3, owns/2]).
-export([init/2]).

-type query() :: {inspect, [erx_schema:segment()], map()} | {entries, [erx_schema:segment()]}.
-type answer() :: erx_inspector:answer() | erx_inspector:entries().

-doc """
Starts the agent of the domain this runtime is, which asks only the
system domain's questions; `ignore` in the system domain, whose boot page
names no domain pid, and in a runtime that is not erXos's.
""".
-spec start_link() -> {ok, pid()} | ignore.
start_link() ->
    case erlang:system_info(os_type) of
        {unix, erxos} ->
            case erx_dist:boot() of
                {Self, {SystemId, _SystemNode, DomainPid}} when is_pid(DomainPid) -> start_link(Self, SystemId);
                _ -> ignore
            end;
        _ ->
            ignore
    end.

-doc """
Starts the agent of domain Self, which takes questions only in domain
SystemId's envelope, registered as erx_inspect_agent.
""".
-spec start_link(non_neg_integer(), non_neg_integer()) -> {ok, pid()} | {error, term()}.
start_link(Self, SystemId) ->
    proc_lib:start_link(?MODULE, init, [Self, SystemId]).

%% Acknowledges the start only once the name is registered, so init's ready report,
%% which reads the name after kernel has started, finds the agent.
-doc false.
init(Self, SystemId) ->
    true = register(?MODULE, self()),
    put(dropped, 0),
    proc_lib:init_ack({ok, self()}),
    loop(Self, SystemId).

loop(Self, SystemId) ->
    receive
        Message ->
            case handle(Message, Self, SystemId) of
                {reply, Alias, Answer} -> Alias ! {Alias, Answer};
                drop -> put(dropped, get(dropped) + 1)
            end,
            loop(Self, SystemId)
    end.

-doc """
What the agent of domain Self does with Message: answer a question the
system domain, SystemId, asked, to its alias; drop anything else.
""".
-spec handle(term(), non_neg_integer(), non_neg_integer()) -> {reply, reference(), answer()} | drop.
handle({erx_origin, SystemId, {erx_inspect_ask, Alias, Query}}, Self, SystemId) when is_reference(Alias) ->
    Answer = try reported(answer(Query, Self)) catch _:_ -> {error, failed} end,
    {reply, Alias, Answer};
handle(_Message, _Self, _SystemId) ->
    drop.

-doc """
The answer of domain Self's runtime to Query: its collectors' record or
listing for a path Self owns, `{error, scope}` for any other question.
""".
-spec answer(query() | term(), non_neg_integer()) -> answer().
answer({entries, [processes]}, _Self) ->
    erx_inspector:entries([processes], all);
answer({inspect, [domains, Self], Options}, Self) when is_map(Options) ->
    erx_runtime_records:domain(Self);
answer({inspect, Path, Options}, Self) when is_map(Options) ->
    case owns(Path, Self) of
        true -> erx_inspector:inspect(Path, all, Options);
        false -> {error, scope}
    end;
answer({entries, Path}, Self) ->
    case owns(Path, Self) of
        true -> erx_inspector:entries(Path, all);
        false -> {error, scope}
    end;
answer(_Query, _Self) ->
    {error, scope}.

%% The answer as this runtime reports it: only the attributes the schema
%% lets `runtime` report, since the query worker takes no other from an
%% agent and gives the rest itself.
reported({ok, Record}) when is_map(Record) -> {ok, runtime_only(Record)};
reported({Status, Records}) when is_list(Records) -> {Status, [runtime_only(Record) || Record <- Records]};
reported(Error) -> Error.

runtime_only(#{kind := Kind, attrs := Attrs} = Record) ->
    Record#{attrs := maps:filter(fun(Key, _Attr) ->
                                         {ok, #{reporters := Reporters}} = erx_schema:attribute(Kind, Key),
                                         lists:member(runtime, Reporters)
                                 end, Attrs)}.

-doc """
Whether domain Self owns Path: its own domain's paths, and a process of
its own domain with every path below it. This is the bound on what the
agent answers, not a promise of an answer: below `[domains, Self]`,
erx_inspector collects a domain's paths only in the system domain
(erx_inspector:collects_domain/2), so such a path is still `{error,
scope}`, which is why answer/2 takes `[domains, Self]` itself from
erx_runtime_records.
""".
-spec owns(term(), non_neg_integer()) -> boolean().
owns([domains, Self | _], Self) -> true;
owns([processes, {pid, Self, _Number, _Serial} | _], Self) -> true;
owns(_Path, _Self) -> false.
