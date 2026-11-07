%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ct_oracle).
-moduledoc """
Runs OTP suites under Common Test for `tools/erx oracle hosted`
(design-tmp.md, Verification, "OTP's suites"), on erXos and on stock alike.

`main([SuiteDir, WorkDir | Logs])` copies `SuiteDir`, the compiled
suites and their `_data` directories, to `WorkDir/suites`, so each
`data_dir` is writable as it is in a stock checkout. It runs every suite
of the copy, in name order.

On stock, where `Logs` is `[]`, Common Test runs as it does anywhere:
its logs go to `WorkDir/logs`, and each suite's `priv_dir` is its run
directory's `log_private`, below the current directory Common Test
gives each case (tar_SUITE:borderline names its `priv_dir` relative to
that directory).

On erXos, where `Logs` is `[LogDir, Cap]`, Common Test's logs go to a
RAM file system of `Cap` bytes this module mounts at `LogDir`, and each
suite's `priv_dir` goes under `WorkDir/priv` (the patched
`test_server_ctrl` reads that root from `ERX_ORACLE_PRIV_ROOT`).
`WorkDir` is under `/tmp`, whose cap the whole group shares, and a suite
that fills it (sendfile_SUITE writes 510 MiB) can then fail only its
own cases: Common Test still writes its logs, the suite still ends, and
its `priv_dir` is deleted before the next suite starts.

The events `erx_oracle_events` records go to `events.jsonl` in the log
directory and, as each happens, to standard output as one line after the
prefix `erx-oracle-event `: the host cannot read erXos's file systems
once the runtime is gone, and a run cut off by its deadline has still
printed every finished case. The text log of each suite follows, each
line after `erx-oracle-log `. The node then halts with 0; the comparison
judges the run by its events, not by the exit status.

The module is also the run's Common Test hook. It deletes each suite's
`priv_dir` once the suite is done with it, and prints `erx-oracle-note
SUITE priv_dir BYTES`, the logical size of the regular files the suite
left there, so a run's log says what used `/tmp`. The `_data` copies
stay: a suite may read another's (string_SUITE reads
unicode_util_SUITE_data).
""".

-include_lib("kernel/include/file.hrl").

-export([main/1]).
-export([init/2, pre_init_per_suite/3, post_init_per_suite/4, post_end_per_suite/4, terminate/1]).

%% The hook's state: the directory every priv_dir is under, which the
%% hook deletes under only, and the priv_dir not yet deleted, with the
%% suite it belongs to, or none.
-type pending() :: none | {module(), file:filename()}.
-type state() :: {file:filename(), pending()}.

%% Stock: the logs beside the work directory, and each priv_dir where
%% stock Common Test puts it, in the log tree; ERX_ORACLE_PRIV_ROOT stays
%% unset. erXos: the logs on a RAM file system of Cap bytes mounted at
%% LogDir, whose tree process is registered as erx_ct_oracle_logs, and
%% each priv_dir under WorkDir/priv, named in ERX_ORACLE_PRIV_ROOT for the
%% patched test_server_ctrl. The host tool passes both forms.
-spec main([string()]) -> no_return().
main([SuiteDir, WorkDir]) ->
    LogDir = filename:join(WorkDir, "logs"),
    ok = filelib:ensure_path(LogDir),
    run(SuiteDir, WorkDir, LogDir, resolved_dir(LogDir));
main([SuiteDir, WorkDir, LogDir, Cap]) ->
    {ok, _} = erx_ramfs_sup:start_link(list_to_integer(Cap), list_to_binary(LogDir), erx_ct_oracle_logs),
    Priv = filename:join(WorkDir, "priv"),
    ok = filelib:ensure_path(Priv),
    PrivRoot = resolved_dir(Priv),
    true = os:putenv("ERX_ORACLE_PRIV_ROOT", PrivRoot),
    run(SuiteDir, WorkDir, LogDir, PrivRoot).

%% The existing directory Dir by the absolute name file:get_cwd/0 gives it
%% once entered, which follows symbolic links (macOS's /var is
%% /private/var). Common Test names its log directory so, and with it
%% every stock priv_dir, so the hook's prefix test compares like names.
resolved_dir(Dir) ->
    {ok, Cwd} = file:get_cwd(),
    ok = file:set_cwd(Dir),
    {ok, Resolved} = file:get_cwd(),
    ok = file:set_cwd(Cwd),
    Resolved.

%% Runs the suites of SuiteDir from a copy under WorkDir, with the logs in
%% LogDir and every priv_dir under PrivRoot, and halts. The hook deletes
%% under PrivRoot only.
-spec run(file:filename(), file:filename(), file:filename(), file:filename()) -> no_return().
run(SuiteDir, WorkDir, LogDir, PrivRoot) ->
    Copy = filename:join(WorkDir, "suites"),
    ok = copy_tree(SuiteDir, Copy),
    Events = filename:join(LogDir, "events.jsonl"),
    ok = filelib:ensure_dir(Events),
    true = os:putenv("ERX_ORACLE_EVENTS", Events),
    Result = ct:run_test([{dir, Copy},
                          {suite, suites(Copy)},
                          {logdir, LogDir},
                          {auto_compile, false},
                          {ct_hooks, [{?MODULE, PrivRoot}]},
                          {event_handler, erx_oracle_events}]),
    io:format("erx-oracle-result ~0p~n", [Result]),
    [print_lines("erx-oracle-log ", Log)
     || Log <- filelib:wildcard(filename:join(LogDir, "ct_run.*/*.logs/run.*/suite.log"))],
    erlang:halt(0).

-doc "Starts the hook with the priv_dir root run/4 passes and no priv_dir pending.".
-spec init(term(), file:filename()) -> {ok, state()}.
init(_Id, PrivRoot) ->
    {ok, {PrivRoot, none}}.

-doc """
Takes note of the suite's priv_dir. Any priv_dir still pending is an
earlier suite's that ended without either post function; it is deleted
first.
""".
-spec pre_init_per_suite(module(), term(), state()) -> {term(), state()}.
pre_init_per_suite(Suite, Config, {PrivRoot, Pending}) ->
    ok = delete_priv_dir(PrivRoot, Pending),
    {Config, {PrivRoot, pending(Suite, Config)}}.

-doc """
Deletes the suite's priv_dir when init_per_suite failed or skipped the
suite, which then ends without end_per_suite and post_end_per_suite: the
next suite's priv_dir is made before any hook of it runs, so a full tree
left until then would fail that suite too. Return is the Config list when
init_per_suite succeeded, and {fail, _}, {skip, _} or how it crashed
otherwise; this is the run's only hook, so no later one changes it.
""".
-spec post_init_per_suite(module(), term(), term(), state()) -> {term(), state()}.
post_init_per_suite(_Suite, _Config, Return, State) when is_list(Return) ->
    {Return, State};
post_init_per_suite(_Suite, _Config, Return, {PrivRoot, Pending}) ->
    ok = delete_priv_dir(PrivRoot, Pending),
    {Return, {PrivRoot, none}}.

-doc "Deletes the suite's priv_dir once end_per_suite is done.".
-spec post_end_per_suite(module(), term(), term(), state()) -> {term(), state()}.
post_end_per_suite(_Suite, _Config, Return, {PrivRoot, Pending}) ->
    ok = delete_priv_dir(PrivRoot, Pending),
    {Return, {PrivRoot, none}}.

-doc "Deletes what the last suite left, if it ended without post_end_per_suite.".
-spec terminate(state()) -> ok.
terminate({PrivRoot, Pending}) ->
    delete_priv_dir(PrivRoot, Pending).

%% The priv_dir a suite's Config names. Config is {skip, _} or {fail, _}
%% when an earlier hook refused the suite.
pending(Suite, Config) when is_list(Config) ->
    case proplists:get_value(priv_dir, Config) of
        Dir when is_list(Dir) -> {Suite, Dir};
        undefined -> none
    end;
pending(_Suite, _Config) ->
    none.

%% Deletes a suite's priv_dir under PrivRoot and notes the bytes it held,
%% or why it was not deleted; a failed deletion costs space, not the run. Only the
%% directory Common Test made for this suite alone is deleted,
%% .../ct_run.*/*.Suite.logs/run.*/log_private; a job that ran several
%% suites would name another. Common Test sets it before any of the
%% suite's code runs, so the suite cannot move it. The note goes through
%% erlang:display_string/2 because the hook runs in a process whose io
%% goes to the suite's log, not to standard output.
-spec delete_priv_dir(file:filename(), pending()) -> ok.
delete_priv_dir(_PrivRoot, none) ->
    ok;
delete_priv_dir(PrivRoot, {Suite, Dir}) ->
    Note = case suite_priv_dir(PrivRoot, Suite, Dir) of
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

%% Whether Dir is under PrivRoot and ends in
%% ct_run.*/*.Suite.logs/run.*/log_private.
suite_priv_dir(PrivRoot, Suite, Dir) ->
    lists:prefix(filename:split(PrivRoot), filename:split(Dir))
        andalso own_priv_dir(Suite, Dir).

own_priv_dir(Suite, Dir) ->
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
