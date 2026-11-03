%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_oracle_observer).
-moduledoc false.
-include("ct_event.hrl").
-export([start/6, finish/3, controller/2, worker/1, traversal/0]).

%% The controller owns this token locally. Reporting never writes testcase
%% configuration and never decides the result it observes.
start(Token, Worker, Suite, Case, Mode, Log) ->
    true = length(Mode) =< 64,
    Groups = [{Reference, bounded_name(proplists:get_value(name, Properties))}
              || {Reference, Properties, _Started} <- lists:reverse(Mode)],
    Owner = owner_suite(Suite, Mode),
    observe(erx_case_start, {Token, Worker, Owner, Case, Groups, bounded_name(Log)}).

finish(Token, Status, Number) ->
    observe(erx_case_finish, {Token, Status, Number}).

%% Only the controller owns this state. Requests stay local and are compared
%% as Erlang values; arbitrary specs and reasons never enter the writer.
controller(selection_begin, _Previous) ->
    Selection = make_ref(),
    observe(erx_selection_begin, Selection),
    {undefined, #{id => Selection, phase => planning, planned => [], workers => #{}}};
controller({job, Request, {_Client, _Function}}, #{phase := planning} = State) ->
    Job = make_ref(),
    {_Directory, Name, _Cases, _Skips} = Request,
    observe(erx_job_selected, {maps:get(id, State), Job, bounded_name(Name)}),
    {undefined, State#{planned := [{Job, Request} | maps:get(planned, State)]}};
controller(selection_seal, #{phase := planning} = State) ->
    Jobs = lists:reverse(maps:get(planned, State)),
    observe(erx_selection_seal, {maps:get(id, State), length(Jobs)}),
    {undefined, State#{phase := sealed, remaining => Jobs}};
controller({job, Request, false}, #{phase := sealed, remaining := [{Job, Request} | Rest]} = State) ->
    observe(erx_job_admitted, Job),
    {Job, State#{remaining := Rest}};
controller({spawned, Job, Pid}, #{workers := Workers} = State) when is_reference(Job) ->
    {undefined, State#{workers := Workers#{Pid => Job}}};
controller({worker_exit, Pid, Reason}, #{workers := Workers} = State) ->
    case maps:find(Pid, Workers) of
        {ok, Job} -> observe(erx_job_exit, {Job, Pid, Reason =:= normal});
        error -> ok
    end,
    {undefined, State#{workers := maps:remove(Pid, Workers)}};
controller({selection_close, Mode}, #{id := Selection} = State) ->
    observe(erx_selection_close, {Selection, Mode =:= true}),
    {undefined, State};
controller(_Event, undefined) -> {undefined, undefined};
controller(_Event, #{id := Selection} = State) ->
    observe(erx_selection_error, Selection),
    {undefined, State}.

worker(Job) when is_reference(Job) -> observe(erx_job_worker, {Job, self()});
worker(undefined) -> ok.

traversal() -> observe(erx_job_traversed, self()).

owner_suite(ct_framework, [{_Reference, Properties, _Started} | _]) ->
    proplists:get_value(suite, Properties, ct_framework);
owner_suite(Suite, _Mode) -> Suite.

bounded_name(undefined) -> undefined;
bounded_name(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
bounded_name(Name) when is_list(Name), length(Name) =< 4096 ->
    Binary = unicode:characters_to_binary(Name),
    true = is_binary(Binary) andalso byte_size(Binary) =< 4096,
    Binary;
bounded_name(Name) when is_binary(Name), byte_size(Name) =< 4096 -> Name.

%% Observer failure must not replace an existing Common Test outcome. Missing
%% start/final/completion records fail the host's completeness checks instead.
%% The writer acknowledges each record before this controller can announce
%% completion. The one-second bound applies only to reporting, outside the
%% testcase's own execution and timetrap.
observe(Name, Data) ->
    try gen_event:call(ct_event, erx_oracle_events,
                       {case_fact, #event{name = Name, data = Data}}, 1000) of
        _ -> ok
    catch
        _:_ -> ok
    end.
