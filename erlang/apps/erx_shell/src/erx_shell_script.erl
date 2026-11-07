%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_script).
-moduledoc """
Runs rc's language with real commands: a source evaluated by
erx_shell_eval over erx_shell_runner, with the command namespace of the
shell's release (docs/design-shell.md). The interactive layer reads lines
and calls the same evaluator; this module runs a whole source, a line
typed at the Erlang shell or a script, and gives how it ended.

The evaluator runs in a process of its own with a heap limit, so a
runaway script ends that process and never its caller (SH2). In Phase 1
the shell runs in the system domain with the session's whole authority,
so the context it hands commands holds every facet its commands declare,
each the system domain's own (docs/plan.md, Phase 1).
""".

-export([run/1, run/2, script/1, main/1, session_facets/0]).

-export_type([options/0, ending/0]).

-type options() :: #{cwd => binary(),
                     fds => #{erx_shell_lex:fd() => erx_cmd:stream()},
                     vars => #{binary() => [binary()]},
                     applications => [atom()]}.
%% How a source ended, with the final `$status`: it ran to its end, ran
%% `exit`, stopped on a fault of the language or did not parse.
-type ending() :: {ok | exit | fault | syntax_error, Status :: binary()}.

%% The facets of the session in the system domain: the domain's own.
-define(MAX_HEAP_WORDS, 32 bsl 20).

-doc "The session's facets in the system domain: the domain's own.".
-spec session_facets() -> #{atom() => term()}.
session_facets() -> #{inspect => local}.

-doc "Runs a source at the terminal, from `/`.".
-spec run(iodata()) -> ending().
run(Source) -> run(Source, #{}).

-doc """
Runs a source with the given working directory (`/`), descriptors (0 at
end of input, 1 and 2 the terminal), variables and command releases (the
command shell's own).
""".
-spec run(iodata(), options()) -> ending().
run(Source, Options) ->
    Leader = group_leader(),
    Terminal = {tty, fun(Bytes) -> file:write(Leader, Bytes) end},
    Fds = maps:get(fds, Options, #{0 => null, 1 => Terminal, 2 => Terminal}),
    {Table, _Problems} = erx_shell_namespace:from_applications(
                           maps:get(applications, Options, [erx_shell])),
    State = erx_shell_runner:state(#{cwd => maps:get(cwd, Options, <<"/">>), fds => Fds,
                                   table => Table, facets => session_facets()}),
    Vars = maps:merge(#{<<"home">> => [<<"/">>], <<"*">> => []}, maps:get(vars, Options, #{})),
    Shell = erx_shell_eval:new(Vars, erx_shell_runner:runner(), State),
    evaluate(iolist_to_binary(Source), Shell).

-doc "Runs the rc script at Path, at the terminal.".
-spec script(file:name_all()) -> ending() | {error, file:posix()}.
script(Path) ->
    case file:read_file(Path) of
        {ok, Source} -> run(Source, #{vars => #{<<"0">> => [iolist_to_binary(Path)]}});
        {error, Reason} -> {error, Reason}
    end.

%% The evaluator's process: the source's ending, or the reason it was killed.
evaluate(Source, Shell) ->
    Limit = #{size => ?MAX_HEAP_WORDS, kill => true, error_logger => false,
              include_shared_binaries => true},
    {_Pid, Ref} = spawn_opt(fun() -> exit({ending, ending(erx_shell_eval:run_source(Source, Shell))}) end,
                            [monitor, {max_heap_size, Limit}]),
    receive
        {'DOWN', Ref, process, _, {ending, Ending}} -> Ending;
        {'DOWN', Ref, process, _, Reason} ->
            {fault, iolist_to_binary(io_lib:format("~0tp", [Reason]))}
    end.

ending({ok, Shell}) -> {ok, erx_shell_eval:status(Shell)};
ending({exit, Shell}) -> {exit, erx_shell_eval:status(Shell)};
ending({error, _Message, Shell}) -> {fault, erx_shell_eval:status(Shell)};
ending({syntax_error, _Printed, Shell}) -> {syntax_error, erx_shell_eval:status(Shell)}.

-doc """
`erl -run erx_shell_script main Script Output Work`: runs Script from the empty
directory Work, as the rc oracle runs its scripts, and writes `stdout`,
`stderr` and `status` into Output. `status` holds the ending and the
final `$status`, as erx_shell_fake_runner:main/1 writes them.
""".
-spec main([string()]) -> no_return().
main([Script, Output, Work]) ->
    {ok, Source} = file:read_file(Script),
    {ok, Out} = file:open(filename:join(Output, "stdout"), [write, binary]),
    {ok, Err} = file:open(filename:join(Output, "stderr"), [write, binary]),
    Vars = #{<<"0">> => [<<"../script.rc">>], <<"path">> => [<<"/bin">>, <<"/usr/bin">>],
             <<"home">> => [<<"/var/empty">>]},
    {Ending, Status} = run(Source, #{cwd => unicode:characters_to_binary(Work), vars => Vars,
                                     fds => #{0 => null, 1 => {dev, Out}, 2 => {dev, Err}}}),
    ok = file:close(Out),
    ok = file:close(Err),
    Outcome = case Ending of
                  fault -> <<"fault\n">>;
                  _ -> <<"ok\n">>
              end,
    ok = file:write_file(filename:join(Output, "status"), [Outcome, Status, $\n]),
    halt(0).
