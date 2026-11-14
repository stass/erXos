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
pid. The spec is erx_program:start/1's, but for its descriptors, which
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

The pid, ppid and pgid come from the command server, which assigns
process ids (docs/design-programs.md, "The parties").

When the program ends the starter gets `{erx_prog_exit, Handler,
Status}`, `Status` read by erx_prog:status/1: `{exited, N}` or
`{signaled, Signal}`. A port the driver closes with no status, when a
record of the program's end may be lost, ends the handler with no report,
since it read none. stop/1 stops the program, which then ends signaled
`sigkill`; the starter's exit stops it too, so no program outlives the
session process that started it. The handler then exits normally. Its
crash closes the program's port, which kills the program; a starter that
needs to know monitors the handler.

The handler monitors the pipe server and, when it goes, sends the program
`pipe_server_lost` (docs/design-pipes.md, "The pipe server").
""".

-export([start/1, stop/1]).

-record(h, {core :: erx_prog_handler_core:core(),
            starter :: pid(),
            spec :: map(),
            port :: port() | undefined,
            %% The monitor of the port, whose close ends the handler.
            closed :: reference() | undefined,
            %% The answer start/1 waits for, until it is given.
            reply :: {pid(), reference()} | undefined,
            pipes :: reference() | undefined}).

-doc """
Starts the program `Spec` names, as described above, with the caller as
its starter: `{ok, Handler, Offsets}`, `Offsets` each buffer's
`{N, Offset}`, or `{error, Errno}`: `einval` for a spec the program's
start refuses, a descriptor of another form or a `pid` another handler
speaks for, `ebadf` for a pipe end the caller does not hold, `emfile`
beyond a pipe's read ends, `enfile` at the session's pipes quota,
`enodev` for a buffer in a domain where no pixel allocator runs,
`einval` for a buffer in an area the domain does not share with `Peer`,
`enomem` (for a pipe server that is gone too), `eio` when the handler
crashed, `e2big` for strings past the startup message's bound, or the
start's own refusal (erx_program:start/1). Nothing the start reserved
survives an error.
""".
-spec start(map()) -> {ok, pid(), [{0..1023, non_neg_integer()}]} | {error, atom()}.
start(#{pid := _} = Spec) ->
    Self = self(),
    Ref = make_ref(),
    Handler = spawn(fun() -> init(Self, Ref, Spec) end),
    Watch = monitor(process, Handler),
    receive
        {Ref, {ok, Offsets}} ->
            demonitor(Watch, [flush]),
            {ok, Handler, Offsets};
        {Ref, {error, _} = Refused} ->
            demonitor(Watch, [flush]),
            Refused;
        {'DOWN', Watch, process, Handler, _} ->
            %% The handler crashed, a fault of the session's own code; its
            %% hand-offs, lease and holder entry went with it.
            {error, eio}
    end;
start(_Spec) ->
    {error, einval}.

-doc """
Stops the program the handler serves, when its starter calls it; its end
follows as `erx_prog_exit`. A call by any other process does nothing.
""".
-spec stop(pid()) -> ok.
stop(Handler) when is_pid(Handler) ->
    Handler ! {erx_prog_stop, self()},
    ok.

init(Starter, Ref, #{pid := Pid} = Spec) ->
    erlang:monitor(process, Starter),
    case erx_prog_handler_core:new(Pid, maps:get(fds, Spec, [])) of
        {ok, Core, Actions} ->
            H = #h{core = Core, starter = Starter, spec = maps:remove(fds, Spec),
                   reply = {Starter, Ref}, pipes = watch_pipes()},
            loop(perform(Actions, H));
        {error, _} = Refused ->
            Starter ! {Ref, Refused}
    end.

loop(#h{core = Core, port = Port, closed = Closed, starter = Starter, spec = #{pid := Pid}, pipes = Pipes} = H) ->
    case erx_prog_handler_core:phase(Core) of
        ended ->
            ok;
        _ ->
            Event = receive
                        {erx_channel, Port, Frame} -> {frame, Frame};
                        {erx_channel_room, Port} -> room;
                        {Port, {exit_status, Status}} -> {exit_status, Status};
                        %% After the port's exit status, which it sends first, if any.
                        {'DOWN', Closed, port, Port, _} -> port_closed;
                        {pipe_report, Pid, Report} -> {report, Report};
                        {erx_prog_stop, Starter} -> stop;
                        {'DOWN', _, process, Starter, _} -> stop;
                        {'DOWN', Pipes, process, _, _} -> pipes_lost;
                        %% Nothing else is for the handler; it must not pile up.
                        _Other -> ignored
                    end,
            loop(watched(Event, event(Event, H)))
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
act({start, Fds}, #h{spec = Spec} = H) ->
    %% A spec of the wrong shape is the starter's, refused as einval.
    Started = try erx_program:start(Spec#{fds => Fds})
              catch error:badarg -> {error, einval}
              end,
    case Started of
        {error, Errno} -> {event, {refused, Errno}, H};
        Port -> {event, started, H#h{port = Port, closed = erlang:monitor(port, Port)}}
    end;
act({answer, Answer}, #h{reply = {To, Ref}} = H) ->
    To ! {Ref, Answer},
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
act({forward, Notice}, H) ->
    %% A pipe server that is gone has forgotten the end; the handler's
    %% monitor tells the program.
    _ = try erx_pipe_srv:forward(Notice) catch exit:_ -> lost end,
    H;
act({stop, Status}, #h{port = Port} = H) ->
    %% A program already ending refuses the stop; its exit status follows.
    _ = driver(Port, fun() -> erx_program:stop(Port, anchor, Status) end, {error, einval}),
    H;
act({tell_starter, Status}, #h{starter = Starter} = H) ->
    Starter ! {erx_prog_exit, self(), erx_prog:status(Status)},
    H;
act(exit, H) ->
    H.

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
%% domain whose release lacks it, or while it is not running, the buffer is
%% refused with enodev, as the domain has no display to lend from. A lend
%% refused after the alloc leaves the range allocated; the refusal ends the
%% handler, and the allocator frees an exited owner's ranges.
lend(Peer, Bytes) ->
    try erx_pixels:alloc(Peer, Bytes) of
        {ok, Offset} ->
            case erx_pixels:lend(Peer, Offset) of
                {ok, Lease, Pages} -> {reserved, {mem, Lease, Pages, Offset}};
                {error, Errno} -> {refused, Errno}
            end;
        {error, none} -> {refused, einval};
        {error, Errno} -> {refused, Errno}
    catch
        error:undef -> {refused, enodev};
        exit:{noproc, _} -> {refused, enodev}
    end.

%% A monitor of the pipe server, or none while it is between restarts.
watch_pipes() ->
    case whereis(erx_pipe_srv) of
        undefined -> undefined;
        Server -> monitor(process, Server)
    end.
