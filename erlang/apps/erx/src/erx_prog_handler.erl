%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_prog_handler).
-moduledoc """
A program's handler (docs/design-programs.md, "The handler"): the Erlang
process that starts one native program with the descriptors its starter
names, owns the program's port, alone sends to the program, forwards the
program's notices to the pipe server, and tells the starter how the
program ended. erx_prog_handler_core decides everything; this process
performs each action in order and turns what happens outside it back
into events.

A session process starts a program with start/1 and gets the handler's
pid and a monitor of it. The spec is erx_program:start/1's, but for its descriptors, which
the starter names as it holds them (docs/design-pipes.md, "Inherited
ends"):

* `{N, {pipe, End}}`, a pipe end the starter holds, made with
  erx_pipe_srv. The handler asks the pipe server for an end of the same
  kind for the program, with the starter as the end's holder, and hands
  it to the program as descriptor `N`. The starter keeps its own end and
  closes it once start/1 returns, as a UNIX parent closes after a fork.
* `{N, {buffer, Peer, Bytes}}`, a window's buffer of `Bytes` in the pixel
  area of the display domain `Peer`. The handler allocates the range and
  lends it to the program, which finds it mapped as descriptor `N`
  (docs/design-display.md, "The pixel area"). The range belongs to the
  handler, so it rejoins the free list only after the program's mapping
  is gone. start/1 answers the range's offset, which the starter names in
  the window's presents.

The spec names no `pid`, `ppid` or `pgid`: start/1 asks the command
server (erx_command_srv) for the program's handler, and the server
assigns the program's process id, records it in the caller's job with
1, the server, as its parent and its job's group, and spawns the handler
outside every job (docs/design-programs.md, "The command server"). The
handler takes the three values from the server's table and waits for
its start, which start/1 sends with a key only it holds once it monitors
the handler; it exits if the caller ends first. Until the runtime's job tags exist, the caller's
job is its group leader, as the shell's jobs are (TODO.md, "a job's
processes are found by group leader").

The spec's `window => Display`, in place of a buffer, starts the program
with a window of its own on the display whose grant this domain names
`Display`: the handler opens the window as its holder, starts a draw
connection on it and gives the program a `/dev` of its own, an
erx_session_export tree that serves the connection's `draw` and `ctl` and
relays the window's `kbd`, `mouse`, `wctl`, `label` and the display's
`clipboard` (docs/design-files.md, "A program's window"). All three end
when the handler does. erx_session_export:start_window/1 makes them, so
this module, which the display domain's release ships, names none of the
window library's modules; its one client name is the pixel allocator's,
erx_pixels, G9's one exception (docs/design-display.md, G9).

A program started with neither a window nor a buffer gets the same window at
its first open of `/dev/draw` (docs/design-programs.md, "The handler";
erx_prog_handler_core): on the display its `display` variable names, or the
session's only display (erx_session_export:displays/0). No display refuses the
open with `enodev` and the program runs on; a window that fails once its
opening began ends the handler `{shutdown, {window, Errno}}`, and the program
with it.

start/1 waits 30 seconds for the handler's answer; start/2, the tests'
seam, takes the wait in milliseconds. Past it, the start kills the
handler and answers `{error, timeout}`: a handler stuck in a call to the
pixel allocator or the pipe server would hold the range, the lease, the
holder entry and the hand-offs until that call answers, and its end
gives each of them back through its owner, as each owner sees the exit.
A kill takes effect only between the handler's calls of a driver or a
NIF, so the answer can come that much later.

start/1 answers a monitor of the handler with it, made before the handler
could end, and the monitor's `'DOWN'` is the starter's one report of the
program's end (docs/design-programs.md, "The handler"). Once the program
has ended the handler exits `{shutdown, {program_exit, Status}}`, `Status`
read by erx_prog:status/1: `{exited, N}` or `{signaled, Signal}`;
`shutdown` marks that end as an ordinary one, as OTP reads an exit reason. Any other reason
is the handler's own end, and the program ended with it: a crash closes
the program's port, which kills the program, and a port the driver closes
with no status, when a record of the program's end may be lost, ends the
handler `program_lost`, since it read no status. stop/1 stops the
program, which then ends signaled `sigkill`; the starter's exit stops it
too, so no program outlives the session process that started it.

The handler monitors the pipe server and, when it goes, sends the program
`pipe_server_lost` (docs/design-pipes.md, "The pipe server").

The handler serves the program's file requests over its starter's
namespace, the runtime's mounts (prim_file:erx_mounts/0) as they stand at
the start, narrowed by the spec's `within`: absent, the whole table; or
a list of `{Path, Rights}`, each an absolute path the program reaches
with `Rights`, `ro` or the starter's own there, and nothing else
(docs/design-files.md, "Narrowing for a program"). A relative path
resolves from the spec's `cwd`. Each open is an open-file description,
an erx_file_description process the handler links, and the bytes of a
read or a write cross the program's data area through the program
driver (erx_program:data_read/3 and data_write/3).
""".

-export([start/1, start/2, stop/1, serve/1]).

%% How long start/1 waits for the handler's answer.
-define(START_MS, 30000).

-record(h, {core :: erx_prog_handler_core:core(),
            starter :: pid(),
            spec :: map(),
            port :: port() | undefined,
            %% The monitor of the port, whose close ends the handler.
            closed :: reference() | undefined,
            %% The starter, until it has start/1's answer.
            reply :: pid() | undefined,
            pipes :: reference() | undefined}).

-doc """
Starts the program `Spec` names, as described above, with the caller as
its starter: `{ok, Handler, Monitor, Offsets}`, `Monitor` the caller's
monitor of the handler, whose `'DOWN'` reports the program's end, and
`Offsets` each buffer's `{N, Offset}`; or `{error, Errno}`, with no
monitor left: `einval` for a spec the program's start refuses, one that
names a `pid`, `ppid` or `pgid`, or a descriptor of another form,
`enotsup` in a domain that runs no command server, `eagain` once the
server has given every process id, `ebadf` for a pipe end the caller
does not hold, `emfile`
beyond a pipe's read ends, `enfile` at the session's pipes quota,
`enodev` for a buffer in a domain where no pixel allocator runs,
`einval` for a buffer in an area the domain does not share with `Peer`,
`einval` for a window beside a buffer or for a table with no room for the
window's `/dev`, `eacces` for a window whose program's table holds an entry
at `/dev` itself that cannot write, `enodev` for a window in a domain without the display
client or with no grant of the display, the display's or the connection's
errno for a window they refuse, `eio` for a `/dev` tree that does not start,
`enomem` (for a pipe server that is gone too), `eio` when the handler
crashed, `e2big` for strings past the startup message's bound, for an
image that is an absolute path (an executable file) `enoent` for no file
there, `eacces` for anything but a file on an `rx` entry or for a path
through a symbolic link, the resolution's own error for a path it cannot
read, and `enotsup` for a file it names, which no start yet runs
(erx_prog_handler_core:resolve_image/3), the
start's own refusal (erx_program:start/1), or `timeout` when the handler
has not answered within 30 seconds.
Nothing the start reserved survives an error.
""".
-spec start(map()) -> {ok, pid(), reference(), [{0..1023, non_neg_integer()}]} | {error, atom()}.
start(Spec) ->
    start(Spec, ?START_MS).

-doc "start/1 with a wait of `Timeout` milliseconds for the handler's answer.".
-spec start(map(), timeout()) -> {ok, pid(), reference(), [{0..1023, non_neg_integer()}]} | {error, atom()}.
start(Spec, Timeout) when is_map(Spec), not is_map_key(pid, Spec), not is_map_key(ppid, Spec),
                          not is_map_key(pgid, Spec),
                          Timeout =:= infinity orelse is_integer(Timeout) andalso Timeout >= 0 ->
    Key = make_ref(),
    case erx_command_srv:handler({process, group_leader()}, Key) of
        {ok, Handler, _Pid} -> started(Handler, Key, Spec, Timeout);
        {error, _} = Refused -> Refused
    end;
start(_Spec, _Timeout) ->
    {error, einval}.

%% The handler's answer to the start, which is sent only once the handler
%% is monitored. The handler does nothing but wait for its start until it
%% has it, so the monitor holds from before the handler can end, and its
%% 'DOWN', the program's end, always comes.
started(Handler, Key, Spec, Timeout) ->
    Watch = monitor(process, Handler),
    Handler ! {start, Key, Spec},
    receive
        {erx_prog_started, Handler, {ok, Offsets}} ->
            {ok, Handler, Watch, Offsets};
        {erx_prog_started, Handler, {error, _} = Refused} ->
            demonitor(Watch, [flush]),
            Refused;
        {'DOWN', Watch, process, Handler, _} ->
            %% The handler crashed, a fault of the session's own code; its
            %% hand-offs, lease and holder entry went with it.
            {error, eio}
    after Timeout ->
        %% Killed, the handler frees nothing itself: what it reserved goes
        %% back to each owner, once, at its exit. Every message it sent
        %% arrives before its 'DOWN', so an answer that crossed the kill is
        %% taken out of the mailbox here.
        exit(Handler, kill),
        receive {'DOWN', Watch, process, Handler, _} -> ok end,
        receive {erx_prog_started, Handler, _} -> ok after 0 -> ok end,
        {error, timeout}
    end.

-doc """
Stops the program the handler serves, when its starter calls it; its end
follows as the `'DOWN'` of the starter's monitor. A call by any other
process does nothing.
""".
-spec stop(pid()) -> ok.
stop(Handler) when is_pid(Handler) ->
    Handler ! {erx_prog_stop, self()},
    ok.

-doc """
A program's handler as the command server spawns it, from the server's
`Init` (erx_command_core:init()): it waits for `{start, Key, Spec}`,
`Key` the reference Init names, which only the starter that asked for
the handler holds, so no other process can start it, and builds the
program from `Spec` with the process id, parent and group of `Init`; it
exits if the starter ends first.
""".
-spec serve(erx_command_core:init()) -> ok.
serve(#{starter := Starter, key := Key} = Init) ->
    Watch = monitor(process, Starter),
    receive
        {start, Key, Spec} when is_map(Spec) ->
            init(Starter, maps:merge(Spec, maps:with([pid, ppid, pgid], Init)));
        {'DOWN', Watch, process, Starter, _} ->
            ok
    end.

%% serve/1's monitor of the starter stays, and the loop reads its 'DOWN'
%% as a stop.
init(Starter, #{pid := Pid} = Spec) ->
    Files = (maps:merge(maps:with([window, image], Spec), display_variable(Spec)))#{
              table => erx_file_description:table(),
              within => maps:get(within, Spec, all),
              cwd => maps:get(cwd, Spec, undefined),
              slots => erx_program:slots(Spec)},
    case erx_prog_handler_core:new(Pid, maps:get(fds, Spec, []), Files) of
        {ok, Core, Actions} ->
            H = #h{core = Core, starter = Starter, spec = maps:without([fds, within, window], Spec),
                   reply = Starter, pipes = watch_pipes()},
            loop(perform(Actions, H));
        {error, _} = Refused ->
            Starter ! {erx_prog_started, self(), Refused},
            ok
    end.

%% Once the core has ended, the handler exits with the core's reason, which it
%% first logs when it is neither `normal` nor the program's exit: the starter then
%% tells no status, and the log says why.
loop(#h{core = Core, port = Port, closed = Closed, starter = Starter, spec = #{pid := Pid}, pipes = Pipes} = H) ->
    case erx_prog_handler_core:phase(Core) of
        {ended, Reason} ->
            ok = log_end(Pid, Reason),
            exit(Reason);
        _ ->
            Event = next_event(Port, Closed, Starter, Pid, Pipes),
            loop(watched(Event, event(Event, H)))
    end.

%% The next message for the handler, as the core's event.
next_event(Port, Closed, Starter, Pid, Pipes) ->
    receive
        {erx_channel, Port, Frame} -> {frame, Frame};
        {erx_channel_room, Port} -> room;
        {Port, {exit_status, Status}} -> {exit_status, Status};
        %% After the port's exit status, which it sends first, if any.
        {'DOWN', Closed, port, Port, _} -> port_closed;
        {pipe_report, Pid, Report} -> {report, Report};
        {erx_prog_stop, Starter} -> stop;
        {'DOWN', _, process, Starter, _} -> stop;
        {'DOWN', Pipes, process, _, _} -> pipes_lost;
        %% The command server's, for a kill or the program's job.
        {erx_signal, Signal, _Sender} -> {signal, Signal};
        {erx_job, {signal, Signal}} -> {signal, Signal};
        {erx_file_opened, Slot, Result} -> {file_opened, Slot, Result};
        {erx_file_done, Slot, Result} -> {file_done, Slot, Result};
        %% Nothing else is for the handler; it must not pile up.
        _Other -> ignored
    end.

%% After the pipe server's loss, a monitor of its restart, if it is up.
watched(pipes_lost, H) -> H#h{pipes = watch_pipes()};
watched(_Event, H) -> H.

%% One event's step and its actions.
event(Event, #h{core = Core} = H) ->
    {Core1, Actions} = erx_prog_handler_core:step(Core, Event),
    perform(Actions, H#h{core = Core1}).

%% Performs the actions in order; an action whose result the core needs
%% steps the core with it at once, and the actions that step gives run
%% before the rest.
perform([], H) ->
    H;
perform([Action | Rest], H) ->
    case act(Action, H) of
        {event, Event, H1} -> perform(Rest, event(Event, H1));
        H1 -> perform(Rest, H1)
    end.

act({resolve, Image, Program}, H) ->
    %% Each facet's mount is read as the grant the registry holds now, as an open reads it,
    %% with no display's facet (erx_facets:program_table/1).
    Table = erx_facets:program_table(Program),
    {event, {resolved, erx_prog_handler_core:resolve_image(Image, Table, fun prim_file:erx_walk/2)}, H};
act(holder, #h{spec = #{pid := Pid}} = H) ->
    {event, {holder, erx_pipe_nif:program_holder(Pid)}, H};
act({inherit, End}, #h{starter = Starter, spec = #{pid := Pid}} = H) ->
    Result = try erx_pipe_srv:forward({inherit, {process, Starter}, End, {program, Pid}})
             catch exit:_ -> {error, enomem}
             end,
    case Result of
        {ok, {pipe_hand, _, _} = Hand} -> {event, {reserved, Hand}, H};
        {error, Errno} when is_atom(Errno) -> {event, {refused, Errno}, H}
    end;
act({lend, Peer, Bytes}, H) ->
    {event, lend(Peer, Bytes), H};
act({window, Display}, H) ->
    {event, window(Display), H};
act({first_window, Named}, H) ->
    {event, {first_window, first_window(Named)}, H};
act({start, Fds}, #h{spec = Spec} = H) ->
    %% A spec of the wrong shape is the starter's, refused as einval.
    Started = try erx_program:start(Spec#{fds => Fds})
              catch error:badarg -> {error, einval}
              end,
    case Started of
        {error, Errno} -> {event, {refused, Errno}, H};
        Port -> {event, started, H#h{port = Port, closed = erlang:monitor(port, Port)}}
    end;
act({answer, Answer}, #h{reply = To} = H) ->
    To ! {erx_prog_started, self(), Answer},
    H#h{reply = undefined};
act({hand_drop, Number}, H) ->
    ok = erx_pipe_nif:hand_drop(Number),
    H;
act({unlend, Lease}, H) ->
    ok = erx_pixels:unlend(Lease),
    H;
act(holder_drop, #h{spec = #{pid := Pid}} = H) ->
    ok = erx_pipe_nif:holder_drop(Pid),
    H;
act({send, Frame}, #h{port = Port} = H) ->
    {event, {sent, driver(Port, fun() -> erx_program:send(Port, Frame) end, {error, einval})}, H};
act({install, Hand}, #h{port = Port} = H) ->
    case driver(Port, fun() -> erx_program:install(Port, Hand) end, {error, edead}) of
        {ok, Filled} -> {event, {installed, Filled}, H};
        {error, Errno} -> {event, {install_refused, Errno}, H}
    end;
act({make_pipe, Flags}, #h{spec = #{pid := Pid}} = H) ->
    %% A pipe server that is gone makes nothing, as when its objects cannot be made.
    Made = try erx_pipe_srv:forward({pipe, {program, Pid}, Flags})
           catch exit:_ -> {error, enomem}
           end,
    {event, {pipe_made, Made}, H};
act({install_end, Hand}, #h{port = Port} = H) ->
    case driver(Port, fun() -> erx_program:install(Port, Hand) end, {error, edead}) of
        {ok, Filled} -> {event, {end_installed, Filled}, H};
        {error, Errno} -> {event, {end_refused, Errno}, H}
    end;
act({forward, Notice}, H) ->
    %% A pipe server that is gone has forgotten the end; the handler's
    %% monitor tells the program.
    _ = try erx_pipe_srv:forward(Notice) catch exit:_ -> lost end,
    H;
act({end_program, Status}, #h{port = Port} = H) ->
    %% A program already ending refuses the stop; its exit status follows.
    _ = driver(Port, fun() -> erx_program:stop(Port, anchor, Status) end, {error, einval}),
    H;
act({open, Slot, Path, Flags, Mode, Program, Cwd}, H) ->
    %% The open walks the program's table as the registry stands now, with no display's facet.
    _ = erx_file_description:open(Slot, Path, Flags, Mode, erx_facets:program_table(Program), Cwd),
    H;
act({read, Description, Slot, Count}, H) ->
    ok = erx_file_description:read(Description, Slot, Count),
    H;
act({pread, Description, Slot, Offset, Count}, H) ->
    ok = erx_file_description:pread(Description, Slot, Offset, Count),
    H;
act({write, Description, Slot, Data, Count}, H) ->
    taken(H, Slot, Data, Count, fun(Bytes) -> erx_file_description:write(Description, Slot, Bytes) end);
act({pwrite, Description, Slot, Data, Offset, Count}, H) ->
    taken(H, Slot, Data, Count, fun(Bytes) -> erx_file_description:pwrite(Description, Slot, Offset, Bytes) end);
act({seek, Description, Slot, Offset, Whence}, H) ->
    ok = erx_file_description:seek(Description, Slot, Offset, Whence),
    H;
act({getattr, Description, Slot}, H) ->
    ok = erx_file_description:getattr(Description, Slot),
    H;
act({copy_in, Slot, Data, Bytes}, #h{port = Port} = H) ->
    Copied = driver(Port, fun() -> erx_program:data_write(Port, Data, Bytes) end, {error, edead}),
    {event, {file_copied, Slot, Copied}, H};
act({clunk, Description, Slot}, H) ->
    ok = erx_file_description:clunk(Description, Slot),
    H.

%% A write's bytes, Count of them taken from data slot Data before the write
%% is queued by Write; a failed take answers the request's slot.
taken(#h{port = Port} = H, Slot, Data, Count, Write) ->
    case driver(Port, fun() -> erx_program:data_read(Port, Data, Count) end, {error, edead}) of
        {ok, Bytes} ->
            ok = Write(Bytes),
            H;
        {error, Errno} ->
            {event, {file_done, Slot, {error, Errno}}, H}
    end.

%% A call of the program driver on the program's port, or Ended, the driver's
%% answer for a program that has ended, once the port is closed. The driver
%% sends the exit status and closes the port in one step, so a send, install
%% or stop taken from the mailbox ahead of that status meets a closed port,
%% where port_control/3 raises badarg; the status, already queued, or the
%% port's close then ends the handler. A badarg on an open port is the handler's bug and stays one.
driver(Port, Call, Ended) ->
    try
        Call()
    catch
        error:badarg:Stack ->
            case erlang:port_info(Port) of
                undefined -> Ended;
                _ -> erlang:raise(error, badarg, Stack)
            end
    end.

%% A window's buffer of Bytes in Peer's area, allocated and lent with the
%% handler as the range's owner and the lease's holder (docs/design-display.md,
%% "The pixel area"). The allocator is the display client's, in erx_win: in a
%% domain whose release lacks it, or where it is not running (alloc/2's none),
%% or with no area to Peer, the buffer is refused with enodev, as the domain has
%% no display to lend from. Of undefs, only that of erx_pixels where it is not
%% loaded means the same; any other undef is a fault of the code, raised again. A lend
%% refused after the alloc leaves the range allocated; the refusal ends the
%% handler, and the allocator frees an exited owner's ranges.
lend(Peer, Bytes) ->
    try erx_pixels:alloc(Peer, Bytes) of
        {ok, Offset} ->
            case erx_pixels:lend(Peer, Offset) of
                {ok, Lease, Pages} -> {reserved, {mem, Lease, Pages, Offset}};
                {error, Errno} -> {refused, Errno}
            end;
        {error, none} -> {refused, enodev};
        {error, Errno} -> {refused, Errno}
    catch
        error:undef:Stack -> absent(erx_pixels, Stack, {refused, enodev})
    end.

log_end(_Pid, normal) ->
    ok;
log_end(_Pid, {shutdown, {program_exit, _Status}}) ->
    ok;
log_end(Pid, Reason) ->
    logger:notice("erx_prog_handler: program ~b ended with no status: ~0P", [Pid, Reason, 8]).

%% The program's own /dev tree on a window of its own on Display, with the handler
%% as the one owner of the window, its draw connection and the tree
%% (erx_session_export:start_window/1). A domain without the session's application,
%% the display domain among them, or without the display client (start_window/1's
%% enodev) refuses with enodev. Only the undef of erx_session_export where it is not
%% loaded says so; any other undef is a fault of the code, raised again.
window(Display) ->
    try erx_session_export:start_window(Display) of
        {ok, DevGrant} -> {windowed, DevGrant};
        {error, Errno} -> {refused, Errno}
    catch
        error:undef:Stack -> absent(erx_session_export, Stack, {refused, enodev})
    end.

%% The window of a program's first open of /dev/draw, on the display Named
%% chooses among those the session holds (erx_prog_handler_core:display/2): enodev
%% for none, decided before anything opens, else the window's /dev tree as
%% window/1 opens it, or its refusal, which comes once the opening has begun.
first_window(Named) ->
    case erx_prog_handler_core:display(Named, displays()) of
        {ok, Display} ->
            case window(Display) of
                {windowed, DevGrant} -> {ok, DevGrant};
                {refused, Errno} -> {failed, Errno}
            end;
        {error, enodev} = Refused ->
            Refused
    end.

%% The displays the session holds (erx_session_export:displays/0), none in a domain
%% without the session's application. Only the undef of erx_session_export where it
%% is not loaded says so; any other undef is a fault of the code, raised again.
displays() ->
    try erx_session_export:displays()
    catch
        error:undef:Stack -> absent(erx_session_export, Stack, [])
    end.

%% Returns Answer when the undef raised with Stack is a call of Module where Module
%% is not loaded, as in a domain whose code path lacks it; otherwise raises the undef
%% again, since any other undef is a fault of the code.
absent(Module, [{Module, _, _, _} | _] = Stack, Answer) ->
    case erlang:module_loaded(Module) of
        false -> Answer;
        true -> erlang:raise(error, undef, Stack)
    end;
absent(_Module, Stack, _Answer) ->
    erlang:raise(error, undef, Stack).

%% The program's display variable, as its spec's environment names it, if it does;
%% an empty one names none.
display_variable(#{env := Env}) when is_list(Env) ->
    case [Value || <<"display=", Value/binary>> <- Env, Value =/= <<>>] of
        [Value | _] -> #{display => Value};
        [] -> #{}
    end;
display_variable(_Spec) ->
    #{}.

%% A monitor of the pipe server, or none while it is between restarts.
watch_pipes() ->
    case whereis(erx_pipe_srv) of
        undefined -> undefined;
        Server -> monitor(process, Server)
    end.
