%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ct_oracle).
-moduledoc """
Runs OTP suites under Common Test for `tools/erx oracle hosted`
(design-tmp.md, Verification, "OTP's suites"), on erXos and on stock alike.

`main([SuiteDir, WorkDir | Suites])` copies `SuiteDir`, the compiled
suites and their `_data` directories, to `WorkDir/suites`, so each
`data_dir` is writable as it is in a stock checkout, and runs the named
suites from there with Common Test's logs, and so every `priv_dir`, under
`WorkDir/logs`. The events `erx_oracle_events` records go to
`WorkDir/logs/events.jsonl`, which is then printed to standard output,
one line per event, each after the prefix `erx-oracle-event `: on erXos
`WorkDir` is under `/tmp`, which the host cannot read once the runtime
is gone. The text log of each suite follows, each line after
`erx-oracle-log `. The node then halts with 0; the comparison judges the
run by its events, not by the exit status.
""".

-export([main/1]).

-define(PREFIX, "erx-oracle-event ").

-spec main([string()]) -> no_return().
main([SuiteDir, WorkDir | Suites]) ->
    Copy = filename:join(WorkDir, "suites"),
    LogDir = filename:join(WorkDir, "logs"),
    ok = copy_tree(SuiteDir, Copy),
    Events = filename:join(LogDir, "events.jsonl"),
    ok = filelib:ensure_dir(Events),
    true = os:putenv("ERX_ORACLE_EVENTS", Events),
    Result = ct:run_test([{dir, Copy},
                          {suite, [list_to_atom(Suite) || Suite <- Suites]},
                          {logdir, LogDir},
                          {auto_compile, false},
                          {event_handler, erx_oracle_events}]),
    io:format("erx-oracle-result ~0p~n", [Result]),
    print_lines(?PREFIX, Events),
    [print_lines("erx-oracle-log ", Log)
     || Log <- filelib:wildcard(filename:join(LogDir, "ct_run.*/*.logs/run.*/suite.log"))],
    erlang:halt(0).

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
