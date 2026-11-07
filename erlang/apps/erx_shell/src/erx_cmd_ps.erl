%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_ps).
-moduledoc """
`ps`: one record for each process of the domain, with its pid, its name
(the registered name, or the function it started in), its status, its
memory in bytes, its reductions and the messages in its queue. A process
that ends while it is read gives `unknown` for each value it no longer
has, never a guess. It needs the `inspect` facet; in Phase 1 the
session's is the system domain's own, so it reads this runtime directly.
""".

-behaviour(erx_cmd).
-erx_command(ps).
-erx_usage("ps").
-erx_needs([inspect]).
-erx_fields([pid, name, status, memory, reductions, messages]).

-export([run/2]).

-define(KEYS, [registered_name, status, memory, reductions, message_queue_len]).

run([], Ctx) ->
    {ok, local} = erx_cmd:facet(Ctx, inspect),
    lists:foreach(fun(Pid) -> erx_cmd:emit(Ctx, record(Pid)) end, erlang:processes());
run(_Args, _Ctx) ->
    {error, usage}.

record(Pid) ->
    case erlang:process_info(Pid, ?KEYS) of
        undefined ->
            maps:from_list([{pid, ok(Pid)}
                            | [{Field, {runtime, unknown}}
                               || Field <- [name, status, memory, reductions, messages]]]);
        Info ->
            #{pid => ok(Pid), name => ok(name(Pid, proplists:get_value(registered_name, Info))),
              status => ok(proplists:get_value(status, Info)),
              memory => ok(proplists:get_value(memory, Info)),
              reductions => ok(proplists:get_value(reductions, Info)),
              messages => ok(proplists:get_value(message_queue_len, Info))}
    end.

ok(Value) -> {runtime, {ok, Value}}.

name(_Pid, Name) when is_atom(Name), Name =/= [] -> Name;
name(Pid, _None) ->
    case proc_lib:translate_initial_call(Pid) of
        {Module, Function, Arity} ->
            iolist_to_binary([atom_to_binary(Module), $:, atom_to_binary(Function), $/,
                              integer_to_binary(Arity)])
    end.
