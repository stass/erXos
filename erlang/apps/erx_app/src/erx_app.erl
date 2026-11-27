%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app).
-moduledoc """
An app's session (docs/design-packaging.md, "Starting an app"): the application
that the app template's `-eval` starts, which asks for the app's record (erx:app/0),
answered once the session's namespace is in place, then mounts the package's image
at `/app` and starts what the package declares.

For an Erlang app it puts each `/app/lib/*/ebin` at the end of the code path,
after the release's, so a module the app ships under a name the release already
uses is never the one the code server finds, and starts each declared
application, permanent, so a declared application's end ends the session and
the start row's keeper starts it again.

For a native app it starts the package's program, `/app/` and the record's path,
which the package reader admits only as plain names, so it names a file of the
image and nothing outside it, with erx_prog_handler:start/1. This process is the
program's starter: the program's namespace is the session's, and when the
record's `window` holds, the spec's `window` names the session's default
display, the environment's `display`, so the handler opens the program's window
and binds its `/dev/draw`, `/dev/kbd`, `/dev/mouse` and `/dev/wctl`. The
handler's monitor is the one report of the program's end, which ends this
process: with `{program_exit, Status}` when the program ended, and with the
handler's own reason otherwise. The starter's end stops the program, so the
program never outlives the session.

erx_app's process acknowledges its start first and only then mounts and starts
the app, so an app that names erx_app, or depends on it, finds it started
rather than waiting on its own start. The process holds nothing; erx_app is
permanent, so its end, with the first step's failure or the program's end as
its reason, ends the session.
""".
-behaviour(application).

-export([start/2, stop/1]).
-export([run/2, init/1]).
-export_type([effects/0]).

-include("generated/erx_abi.hrl").

-doc """
The effects run/2 performs: the mount of `/app`, where the mounted image lies,
the start type of the declared applications, the session's default display,
`none` when it has none, and the program's start. The application passes its
own (effects/0): permanent, so a declared application's end ends the session,
and erx_prog_handler:start/1; a host test passes a mount over a fixture
directory, `temporary`, so a failed start ends only the case, and a start that
reports what it was asked.
""".
-type effects() :: #{mount := fun(() -> ok | {error, term()}),
                     root := string(),
                     type := permanent | temporary,
                     display := atom() | none,
                     start_program := fun((map()) -> {ok, pid(), reference(), list()}
                                                         | {error, atom()})}.

start(_Type, _Args) ->
    proc_lib:start_link(?MODULE, init, [self()]).

stop(_State) ->
    ok.

-doc false.
-spec init(pid()) -> no_return().
init(Parent) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    {ok, Record} = erx:app(),
    try run(Record, effects()) of
        ok -> receive after infinity -> ok end;
        {error, Reason} -> exit(Reason)
    after
        erx_log_h:sync()
    end.

-doc """
Mounts the package of `Record` at `/app` and starts what it declares, through
`Effects`. The first step that fails is the answer; a step that raises
raises again. Either way the domain's log has the end's line (log_end/2),
which init/1 waits to reach the kernel log before the session ends. An
Erlang app's answer is
`ok` once its applications have started; a native app's comes once its
program has ended, as `{error, {program_exit, Status}}`, or once its handler
has ended for another reason, as `{error, Reason}`.
""".
-spec run(erx:app_record(), effects()) -> ok | {error, term()}.
run(Record, Effects) ->
    try
        start_app(Record, Effects)
    catch
        throw:{erx_app, Reason} ->
            log_end(Record, why(Reason)),
            {error, Reason};
        Class:Reason:Stack ->
            log_end(Record, {error, io_lib:format("crashed: ~ts ~ts", [Class, name(Reason)])}),
            erlang:raise(Class, Reason, Stack)
    end.

%% The line that says why the app's session ends, since the session's halt shows the
%% operator only its exit status: the package's name and the names in the reason
%% alone. The reason holds what the app's own code returned or crashed with, so, as
%% the report filter does for OTP's reports, the line keeps only names and drops every
%% other term (docs/design-log.md, "Reports carry no term"). The kernel log, where the
%% domain's log sink writes the line, escapes it.
log_end(Record, {Level, Why}) ->
    logger:log(Level, "erx_app: ~ts: ~ts", [package_name(Record), Why]).

%% The package's name, which the domain service admitted: its place names the
%% package's one file, NAME.app (erx_principal:place/2).
package_name(#{place := {_Where, [File]}}) ->
    filename:rootname(File).

%% Each of erx_app's own reasons as its level and its names: a program's end is a
%% native app's ordinary end, every other reason a failure.
why({program_exit, {How, What}}) when is_atom(How), is_integer(What) orelse is_atom(What) ->
    {notice, io_lib:format("program ended: ~ts ~w", [How, What])};
why({start, App, {App, Reason}}) ->
    {error, io_lib:format("application ~ts did not start: ~ts", [App, failure(App, Reason)])};
why({start, App, {Failed, Reason}}) when is_atom(Failed) ->
    {error, io_lib:format("application ~ts did not start: ~ts failed: ~ts", [App, Failed, failure(Failed, Reason)])};
why({Step, Reason}) when Step =:= mount; Step =:= program; Step =:= window ->
    {error, io_lib:format("~ts failed: ~ts", [Step, name(Reason)])};
why({path, _Ebin, Reason}) ->
    {error, io_lib:format("code path refused: ~ts", [name(Reason)])};
why(Reason) ->
    {error, io_lib:format("ended: ~ts", [name(Reason)])}.

%% Why an application did not start. The application controller's answer for one
%% whose .app file it cannot read is the file's error text and its name
%% (otp/lib/kernel/src/application_controller.erl:1520-1530, make_appl/1); the line
%% rebuilds the name from the application's, says "no" for a file the code path does
%% not hold, as application:ensure_all_started/2 reads that answer, and "bad" for one
%% it could not read or parse, so none of the reason's own bytes reach it. Any other
%% reason shows its leading atom.
failure(Failed, Reason) ->
    File = atom_to_list(Failed) ++ ".app",
    case Reason of
        {"no such file or directory", File} -> ["no ", File];
        {_Error, File} -> ["bad ", File];
        _ -> name(Reason)
    end.

%% A foreign term's leading atom, as the report filter shows a reason, or none.
name(Reason) ->
    erx_report:reason_name(Reason).

%% The session's own effects: the package's image mounted read and execute at /app,
%% and the app's paths under it. The mount names the session's own package, `app`:
%% erx_ns's process takes the file's place and layout from the record the session's
%% agent keeps, so nothing this process passes chooses what /app holds.
effects() ->
    #{mount => fun() -> erx_ns:mount({erofs, app}, <<"/app">>, [rx]) end,
      root => "/app",
      type => permanent,
      display => default_display(os:getenv(binary_to_list(?ERX_DISPLAY_KEY_BYTES))),
      start_program => fun erx_prog_handler:start/1}.

%% The session's default display, which its planning names in its environment,
%% as the atom the domain's grant of it already made; none when the environment
%% names no display, as for a session planned without one, or names one no atom
%% stands for.
default_display(false) ->
    none;
default_display(Name) ->
    try list_to_existing_atom(Name)
    catch error:badarg -> none
    end.

start_app(#{start := {applications, Names}}, #{root := Root, type := Type} = Effects) ->
    mount(Effects),
    lists:foreach(fun add_path/1, ebins(Root)),
    lists:foreach(fun(Name) -> start_application(binary_to_atom(Name), Type) end, Names);
start_app(#{start := {program, Program, Args}, window := Window},
          #{root := Root, start_program := Start} = Effects) ->
    mount(Effects),
    Image = iolist_to_binary([Root, $/, Program]),
    Spec = #{image => Image, argv => [Image | Args], env => [], cwd => <<"/">>,
             spawn => false, sigmask => [], sigignore => [], umask => 8#022},
    Windowed = window(Window, Spec, Effects),
    case Start(Windowed) of
        {ok, _Handler, Monitor, _Offsets} -> ended(Monitor);
        {error, Errno} -> fail({program, Errno})
    end.

mount(#{mount := Mount}) ->
    case Mount() of
        ok -> logger:notice("erx_app: mounted /app");
        {error, Reason} -> fail({mount, Reason})
    end.

%% A program with a window has it on the session's default display.
window(false, Spec, _Effects) -> Spec;
window(true, _Spec, #{display := none}) -> fail({window, no_display});
window(true, Spec, #{display := Display}) -> Spec#{window => Display}.

%% The program's end, which the handler's monitor alone reports. It never returns:
%% a native app's end, an exit with status 0 too, is always its session's end.
-spec ended(reference()) -> no_return().
ended(Monitor) ->
    receive
        {'DOWN', Monitor, process, _Handler, {shutdown, {program_exit, Status}}} ->
            fail({program_exit, Status});
        {'DOWN', Monitor, process, _Handler, Reason} ->
            fail(Reason)
    end.

%% Each lib/*/ebin under Root, sorted, so the code path the app adds does not
%% depend on the order the directory lists.
ebins(Root) ->
    lists:sort(filelib:wildcard(filename:join([Root, "lib", "*", "ebin"]))).

add_path(Ebin) ->
    case code:add_pathz(Ebin) of
        true -> ok;
        {error, Reason} -> fail({path, Ebin, Reason})
    end.

start_application(App, Type) ->
    case application:ensure_all_started(App, Type) of
        {ok, _Started} -> ok;
        {error, Reason} -> fail({start, App, Reason})
    end.

fail(Reason) ->
    throw({erx_app, Reason}).
