%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ct_oracle).
-moduledoc """
Runs OTP suites under Common Test for `tools/erx oracle hosted`
(design-tmp.md, Verification, "OTP's suites"), on erXos and on stock alike.

`main([SuiteDir, WorkDir])` copies `SuiteDir`, the compiled suites and
their `_data` directories, to `WorkDir/suites`, so each `data_dir` is
writable as it is in a stock checkout. It runs every suite of the copy,
in name order. Common Test's logs, and so every `priv_dir`, go under
`WorkDir/logs`. The events `erx_oracle_events` records go to
`WorkDir/logs/events.jsonl` and, as each happens, to standard output as
one line after the prefix `erx-oracle-event `: on erXos `WorkDir` is
under `/tmp`, which the host cannot read once the runtime is gone, and a
run cut off by its deadline has still printed every finished case. The
text log of each suite follows, each line after `erx-oracle-log `. The
node then halts with 0; the comparison judges the run by its events, not
by the exit status.

The module is also the run's Common Test hook. On erXos the whole group
shares `/tmp`'s cap, so the hook deletes each suite's `priv_dir` once the
suite is done with it, and prints `erx-oracle-note SUITE priv_dir BYTES`,
the logical size of the regular files the suite left there, so a run's
log says what used `/tmp`. The `_data` copies stay: a suite may read
another's (string_SUITE reads unicode_util_SUITE_data).
""".

-include_lib("kernel/include/file.hrl").

-export([main/1]).
-export([init/2, pre_init_per_suite/3, post_end_per_suite/4, terminate/1]).

%% The hook's state: the priv_dir not yet deleted, with the suite it
%% belongs to, or none.
-type pending() :: none | {module(), file:filename()}.

-spec main([string()]) -> no_return().
main([SuiteDir, WorkDir]) ->
    Copy = filename:join(WorkDir, "suites"),
    LogDir = filename:join(WorkDir, "logs"),
    ok = copy_tree(SuiteDir, Copy),
    Events = filename:join(LogDir, "events.jsonl"),
    ok = filelib:ensure_dir(Events),
    true = os:putenv("ERX_ORACLE_EVENTS", Events),
    Result = ct:run_test([{dir, Copy},
                          {suite, suites(Copy)},
                          {logdir, LogDir},
                          {auto_compile, false},
                          {ct_hooks, [?MODULE]},
                          {event_handler, erx_oracle_events}]),
    io:format("erx-oracle-result ~0p~n", [Result]),
    [print_lines("erx-oracle-log ", Log)
     || Log <- filelib:wildcard(filename:join(LogDir, "ct_run.*/*.logs/run.*/suite.log"))],
    erlang:halt(0).

-doc "Starts the hook with no priv_dir pending.".
-spec init(term(), term()) -> {ok, pending()}.
init(_Id, _Options) ->
    {ok, none}.

-doc """
Takes note of the suite's priv_dir. A suite whose init_per_suite fails
ends without post_end_per_suite, so what an earlier suite left is deleted
here, as the next suite starts.
""".
-spec pre_init_per_suite(module(), term(), pending()) -> {term(), pending()}.
pre_init_per_suite(Suite, Config, Pending) ->
    ok = delete_priv_dir(Pending),
    {Config, pending(Suite, Config)}.

-doc "Deletes the suite's priv_dir once end_per_suite is done.".
-spec post_end_per_suite(module(), term(), term(), pending()) -> {term(), pending()}.
post_end_per_suite(_Suite, _Config, Return, Pending) ->
    ok = delete_priv_dir(Pending),
    {Return, none}.

-doc "Deletes what the last suite left, if it ended without post_end_per_suite.".
-spec terminate(pending()) -> ok.
terminate(Pending) ->
    delete_priv_dir(Pending).

%% The priv_dir a suite's Config names. Config is {skip, _} or {fail, _}
%% when an earlier hook refused the suite.
pending(Suite, Config) when is_list(Config) ->
    case proplists:get_value(priv_dir, Config) of
        Dir when is_list(Dir) -> {Suite, Dir};
        undefined -> none
    end;
pending(_Suite, _Config) ->
    none.

%% Deletes a suite's priv_dir and notes the bytes it held, or why it was
%% not deleted; a failed deletion costs space, not the run. Only the
%% directory Common Test made for this suite alone is deleted,
%% .../ct_run.*/*.Suite.logs/run.*/log_private; a job that ran several
%% suites would name another. Common Test sets it before any of the
%% suite's code runs, so the suite cannot move it. The note goes through
%% erlang:display_string/2 because the hook runs in a process whose io
%% goes to the suite's log, not to standard output.
-spec delete_priv_dir(pending()) -> ok.
delete_priv_dir(none) ->
    ok;
delete_priv_dir({Suite, Dir}) ->
    Note = case suite_priv_dir(Suite, Dir) of
               false ->
                   io_lib:format("~nerx-oracle-note ~ts priv_dir ~0p not deleted: not its own~n",
                                 [Suite, Dir]);
               true ->
                   Bytes = tree_bytes(Dir),
                   case file:del_dir_r(Dir) of
                       ok ->
                           io_lib:format("~nerx-oracle-note ~ts priv_dir ~b~n", [Suite, Bytes]);
                       {error, Reason} ->
                           io_lib:format("~nerx-oracle-note ~ts priv_dir ~b not deleted: ~0p~n",
                                         [Suite, Bytes, Reason])
                   end
           end,
    true = erlang:display_string(stdout, unicode:characters_to_binary(Note)),
    ok.

%% Whether Dir ends in ct_run.*/*.Suite.logs/run.*/log_private.
suite_priv_dir(Suite, Dir) ->
    case lists:reverse(filename:split(Dir)) of
        ["log_private", "run." ++ _, SuiteLogs, "ct_run." ++ _ | _] ->
            lists:suffix("." ++ atom_to_list(Suite) ++ ".logs", SuiteLogs);
        _ ->
            false
    end.

%% The logical size of the regular files under Path. Links are not
%% followed, so a link a suite left (filelib_SUITE makes loops of them)
%% is neither counted through nor walked into.
tree_bytes(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            case file:list_dir_all(Path) of
                {ok, Names} -> lists:sum([tree_bytes(filename:join(Path, Name)) || Name <- Names]);
                {error, _} -> 0
            end;
        {ok, #file_info{type = regular, size = Size}} ->
            Size;
        _ ->
            0
    end.

%% The suites compiled into Dir, sorted by name. The directory holds
%% exactly the selection: the host compiles only the chosen suites into
%% it, so no list of names has to reach the runtime, whose command line
%% the kernel bounds (ERX_BOOT_STRINGS_MAX).
suites(Dir) ->
    case filelib:wildcard("*_SUITE.beam", Dir) of
        [] -> error({no_suites, Dir});
        Beams -> [list_to_atom(filename:basename(Beam, ".beam")) || Beam <- Beams]
    end.

%% Every regular file under From, at the same relative path under To. The
%% copy reads and writes whole files, so it needs nothing of file:copy/2.
copy_tree(From, To) ->
    lists:foreach(
      fun(Relative) ->
              Source = filename:join(From, Relative),
              Target = filename:join(To, Relative),
              case filelib:is_regular(Source) of
                  true ->
                      ok = filelib:ensure_dir(Target),
                      {ok, Bytes} = file:read_file(Source),
                      ok = file:write_file(Target, Bytes);
                  false ->
                      ok = filelib:ensure_path(Target)
              end
      end,
      filelib:wildcard("**", From)).

%% Each line of the file at Path after Prefix, or why it cannot be read.
print_lines(Prefix, Path) ->
    case file:read_file(Path) of
        {ok, Bytes} ->
            [io:put_chars([Prefix, Line, $\n])
             || Line <- binary:split(Bytes, <<"\n">>, [global, trim_all])],
            ok;
        {error, Reason} ->
            io:format("erx-oracle-result unreadable ~ts ~0p~n", [Path, Reason])
    end.
