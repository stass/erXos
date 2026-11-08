%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_namespace).
-moduledoc """
The command namespace (docs/design-shell.md, "Commands"): a map from a
command's name to what it runs, built when a shell starts from the
metadata of the command modules of the releases it holds.

A name resolves, in order, to a builtin of the runner (`cd`, and the job
builtins `jobs`, `fg`, `bg` and `kill`), then to an
Erlang command, a module that implements erx_cmd and declares
`-erx_command(Name)`. Two modules that declare one name leave it
unresolved: it runs nothing, and whatis names both. A name that holds a
`/` is a path, which names a program, and nothing else resolves to a
program yet, so both give `not found` (the evaluator's functions and its
own builtins come before all of these and never reach the namespace).

build/1 is the pure core: it takes each module's attributes and exports
and checks them, so a module whose metadata is malformed or that does
not export run/2 is left out with a problem naming it, never half
entered. from_applications/1 reads the metadata of an application's
modules, loading them but running no command body.
""".

-export([build/1, from_applications/1, lookup/2, whatis/2]).

-export_type([table/0, entry/0, command/0, problem/0]).

-type entry() :: #{name := binary(), module := module(), usage := binary(),
                   needs := [atom()]}.
-type command() :: {builtin, cd | jobs | fg | bg | kill} | {erlang, entry()} | {conflict, [module()]}.
-type table() :: #{binary() => command()}.
-type problem() :: {module(), malformed_metadata | no_run}.

%% The runner's builtins: what acts on the runner's own state.
-define(BUILTINS, #{<<"cd">> => {builtin, cd}, <<"jobs">> => {builtin, jobs},
                    <<"fg">> => {builtin, fg}, <<"bg">> => {builtin, bg},
                    <<"kill">> => {builtin, kill}}).

-doc """
The table of the given modules, each with its attributes and exports, and
the problems of those left out.
""".
-spec build([{module(), [{atom(), term()}], [{atom(), arity()}]}]) ->
          {table(), [problem()]}.
build(Modules) ->
    {Entries, Problems} =
        lists:foldl(fun({Module, Attributes, Exports}, {Found, Bad}) ->
                            case entry(Module, Attributes, Exports) of
                                none -> {Found, Bad};
                                {ok, Entry} -> {[Entry | Found], Bad};
                                {error, Problem} -> {Found, [{Module, Problem} | Bad]}
                            end
                    end, {[], []}, Modules),
    Erlang = maps:map(fun(_Name, [Entry]) -> {erlang, Entry};
                         (_Name, Entries1) -> {conflict, lists:sort([M || #{module := M} <- Entries1])}
                      end, maps:groups_from_list(fun(#{name := Name}) -> Name end, Entries)),
    {maps:merge(Erlang, ?BUILTINS), lists:reverse(Problems)}.

%% A module's entry, `none` when it declares no command.
entry(Module, Attributes, Exports) ->
    case proplists:get_all_values(erx_command, Attributes) of
        [] -> none;
        Names -> checked_entry(Module, Names, Attributes, Exports)
    end.

checked_entry(Module, Names, Attributes, Exports) ->
    Usage = proplists:get_all_values(erx_usage, Attributes),
    Needs = lists:append(proplists:get_all_values(erx_needs, Attributes)),
    %% The compiler keeps `-erx_command(ps).` as {erx_command, [ps]}, and a
    %% string or a list attribute as written.
    case {Names, Usage} of
        {[[Name]], [Line]} when is_atom(Name), is_list(Line) ->
            checked_entry(Module, Name, Line, Needs, Exports);
        _ ->
            {error, malformed_metadata}
    end.

checked_entry(Module, Name, Line, Needs, Exports) ->
    Atoms = fun(List) -> lists:all(fun is_atom/1, List) end,
    case io_lib:printable_latin1_list(Line) andalso Atoms(Needs) of
        false ->
            {error, malformed_metadata};
        true ->
            case lists:member({run, 2}, Exports) of
                false -> {error, no_run};
                true -> {ok, #{name => atom_to_binary(Name), module => Module,
                               usage => list_to_binary(Line), needs => Needs}}
            end
    end.

-doc """
The table of the command modules of the given applications, read from
their loaded metadata, with the problems of the modules left out.
""".
-spec from_applications([atom()]) -> {table(), [problem()]}.
from_applications(Applications) ->
    Modules = lists:append([modules(Application) || Application <- Applications]),
    build([{Module, Module:module_info(attributes), Module:module_info(exports)}
           || Module <- Modules, code:ensure_loaded(Module) =:= {module, Module}]).

modules(Application) ->
    _ = application:load(Application),
    case application:get_key(Application, modules) of
        {ok, Modules} -> Modules;
        undefined -> []
    end.

-doc "What a name runs: a builtin, an Erlang command, a conflict, or nothing.".
-spec lookup(binary(), table()) -> command() | not_found.
lookup(Name, Table) ->
    case binary:match(Name, <<"/">>) of
        nomatch -> maps:get(Name, Table, not_found);
        _ -> not_found
    end.

-doc "The line whatis prints for a name, or `not_found`.".
-spec whatis(binary(), table()) -> {found, binary()} | not_found.
whatis(Name, Table) ->
    case lookup(Name, Table) of
        {builtin, _} ->
            {found, <<"builtin ", Name/binary>>};
        {erlang, #{module := Module}} ->
            {found, <<Name/binary, ": Erlang command ", (atom_to_binary(Module))/binary>>};
        {conflict, Modules} ->
            Names = lists:join(<<" and ">>, [atom_to_binary(M) || M <- Modules]),
            {found, iolist_to_binary([Name, <<": unresolved, declared by ">>, Names])};
        not_found ->
            not_found
    end.
