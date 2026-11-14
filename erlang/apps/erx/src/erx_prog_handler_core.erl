%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_prog_handler_core).
-moduledoc """
The decisions of a program's handler (docs/design-programs.md, "The
handler"): one pure state machine, step/2, from an event to the next
state and the actions erx_prog_handler performs, in order.

A handler lives through three phases:

* **reserving**, steps 5 and 6 of "Starting a program": the program's
  holder entry, then each descriptor the starter named, one at a time in
  the order given (a pipe end as an `inherit` with the starter as the
  end's holder, a window's buffer as an allocation and a lease the
  handler holds), then the start itself. Any refusal undoes everything
  reserved, without knowing how far the start went: every hand-off is
  dropped and the lease given back, both of which do nothing to what the
  start took (docs/design-pipes.md, "Hand-offs", Giving back), and the
  holder entry is let go, so the pipe server reads the program's gone.
* **running**: the handler alone sends to the program. Reports from the
  pipe server, and those that arrived while the program was being built,
  queue in arrival order behind the startup message; the head of the
  queue is sent, or for a hand-off installed first and then sent with the
  values the install gave. A send the driver answers `busy` stays at the
  head, owed, until the program frees room, so nothing newer passes it.
  The program's notices go to the pipe server as events naming the
  program.
* **ended**: the program's exit status reached the handler, which tells
  the starter and exits, or its port closed with none, and the handler
  exits without a report.

A stop, asked by the starter or forced by its exit, stops the program's
anchor with `ERX_EXIT_SIGNAL + SIGKILL`, a stop by its session, and the
handler then waits for the exit status like any other end. So a session
process's programs never outlive it, as a program's children never
outlive their parent (docs/design-programs.md, "A program's end").

Every event the core does not expect in its phase leaves the state as it
was and does nothing: the handler's mailbox is reached only by session
code and the program's own driver, which delivers only frames of the
program protocol's grammar within the program's credit.
""".

-include("generated/erx_abi.hrl").

-export([new/2, step/2, phase/1]).
-export_type([core/0, event/0, action/0, starter_fd/0]).

%% A descriptor as the starter names it: a pipe end the starter holds, or a
%% window's buffer of Bytes in the area of the display domain Peer, which
%% the handler allocates and lends to the program (docs/design-display.md,
%% "The pixel area": a buffer mapped into a program belongs to its handler).
-type starter_fd() :: {0..1023, {pipe, term()} | {buffer, pos_integer(), pos_integer()}}.
%% A descriptor as erx_program:start/1 takes it.
-type program_fd() :: {0..1023, {pipe_hand, pos_integer(), term()} | {mem, pos_integer(), pos_integer()}}.

-type event() :: {holder, ok | {error, atom()}}
               | {reserved, {pipe_hand, pos_integer(), term()}}
               | {reserved, {mem, Lease :: pos_integer(), Pages :: pos_integer(), Offset :: non_neg_integer()}}
               | {refused, atom()}
               | started
               | {report, term()}
               | {frame, term()}
               | {sent, ok | busy | {error, atom()}}
               | {installed, term()}
               | {install_refused, atom()}
               | room
               | pipes_lost
               | stop
               | {exit_status, integer()}
               | port_closed
               | ignored.

-type action() :: holder
                | {inherit, term()}
                | {lend, pos_integer(), pos_integer()}
                | {start, [program_fd()]}
                | {answer, {ok, [{0..1023, non_neg_integer()}]} | {error, atom()}}
                | {hand_drop, pos_integer()}
                | {unlend, pos_integer()}
                | holder_drop
                | {send, term()}
                | {install, {pipe_hand, pos_integer(), term()}}
                | {forward, tuple()}
                | {stop, non_neg_integer()}
                | {tell_starter, integer()}
                | exit.

%% What waits to reach the program, oldest first: a frame to send, or a
%% hand-off to install, whose filled report is then sent.
-type outgoing() :: {frame, term()} | {hand, {pipe_hand, pos_integer(), term()}}.

-record(core, {pid :: pos_integer(),
               phase = reserving :: reserving | running | ended,
               %% reserving: the starter's descriptors not yet reserved, in order.
               todo = [] :: [starter_fd()],
               %% reserving: the reserved descriptors, newest first, for the start
               %% and for the undo of a refusal.
               made = [] :: [program_fd()],
               %% reserving: each buffer's offset in its area, for the starter.
               offsets = [] :: [{0..1023, non_neg_integer()}],
               queue = queue:new() :: queue:queue(outgoing()),
               %% The head of the queue is out: sent and not yet answered, or
               %% answered busy and owed until the program frees room; or a
               %% frame was lost, and nothing more is sent to the program.
               out = false :: false | sending | owed | lost,
               %% A stop was asked once; a second asks nothing more.
               stopping = false :: boolean()}).
-opaque core() :: #core{}.

-define(IS_FD(N), (is_integer(N) andalso N >= 0 andalso N < ?ERX_PROG_FDS_MAX)).
-define(IS_POS(N), (is_integer(N) andalso N > 0)).
-define(IS_PID(P), (is_integer(P) andalso P >= 2 andalso P =< 16#7fffffff)).
%% A stop by the session reads as signaled SIGKILL (docs/design-programs.md,
%% "A program's end").
-define(STOP_STATUS, (?ERX_EXIT_SIGNAL + ?ERX_SIGKILL)).

-doc """
A handler for program `Pid` that starts it with the starter's
descriptors `Fds`, and its first action, or `{error, einval}` for a
`Pid` outside 2..2^31-1, a descriptor of another form, a number named
twice, or more than one buffer, which the program may have only one of.
""".
-spec new(term(), term()) -> {ok, core(), [action()]} | {error, einval}.
new(Pid, Fds) when ?IS_PID(Pid), is_list(Fds) ->
    case valid_fds(Fds) of
        true -> {ok, #core{pid = Pid, todo = Fds}, [holder]};
        false -> {error, einval}
    end;
new(_Pid, _Fds) ->
    {error, einval}.

-doc "The handler's phase: `reserving`, `running` or `ended`.".
-spec phase(core()) -> reserving | running | ended.
phase(#core{phase = Phase}) -> Phase.

-doc "The next state and the actions that carry out one event.".
-spec step(core(), event()) -> {core(), [action()]}.
%% Reserving: one descriptor at a time, then the start.
step(#core{phase = reserving} = C, {holder, ok}) ->
    reserve_next(C);
step(#core{phase = reserving} = C, {holder, {error, Errno}}) when is_atom(Errno) ->
    %% No entry was made for this handler, so it has nothing to let go.
    %% eexist: the pid has an entry, another handler speaks for it, and
    %% the starter named a pid that is not its program's.
    {C#core{phase = ended}, [{answer, {error, holder_errno(Errno)}}, exit]};
step(#core{phase = reserving, todo = [{N, {pipe, _}} | Todo], made = Made} = C,
     {reserved, {pipe_hand, Number, _Term} = Hand}) when ?IS_POS(Number) ->
    reserve_next(C#core{todo = Todo, made = [{N, Hand} | Made]});
step(#core{phase = reserving, todo = [{N, {buffer, _, _}} | Todo], made = Made, offsets = Offsets} = C,
     {reserved, {mem, Lease, Pages, Offset}}) when ?IS_POS(Lease), ?IS_POS(Pages) ->
    reserve_next(C#core{todo = Todo, made = [{N, {mem, Lease, Pages}} | Made],
                        offsets = [{N, Offset} | Offsets]});
step(#core{phase = reserving} = C, {refused, Errno}) when is_atom(Errno) ->
    {C#core{phase = ended}, undo(C) ++ [{answer, {error, Errno}}, exit]};
step(#core{phase = reserving, todo = []} = C, started) ->
    {C1, Actions} = pump(C#core{phase = running}),
    {C1, [{answer, {ok, lists:reverse(C#core.offsets)}} | Actions]};
%% Reports queue from the first: those that arrive while the program is
%% built wait behind its startup message, which the start wrote.
step(#core{phase = Phase} = C, {report, Report}) when Phase =/= ended ->
    pump(enqueue(C, outgoing(Report)));
step(#core{phase = Phase} = C, pipes_lost) when Phase =/= ended ->
    pump(enqueue(C, {frame, {erx_prog, 1, pipe_server_lost}}));
%% Running: the queue's head, and the program's notices.
step(#core{phase = running, out = sending} = C, {sent, ok}) ->
    pump(drop_head(C));
step(#core{phase = running, out = sending} = C, {sent, busy}) ->
    {C#core{out = owed}, []};
step(#core{phase = running, out = sending} = C, {sent, {error, _}}) ->
    %% A frame the driver refused is lost, and a running program must never
    %% miss a report and read the later ones, so nothing more is sent and the
    %% program is stopped, as a refused install's pass stops it; one already
    %% ending refuses the stop.
    stop(C#core{out = lost, queue = queue:new()});
step(#core{phase = running, out = owed} = C, room) ->
    pump(C#core{out = false});
step(#core{phase = running, out = sending, queue = Q} = C, {installed, Filled}) ->
    %% The values the install gave stand where the hand-off named copies.
    pump(C#core{out = false, queue = queue:in_r({frame, {erx_prog, 1, Filled}}, queue:drop(Q))});
step(#core{phase = running, out = sending, queue = Q} = C, {install_refused, _}) ->
    %% The end the report concerns stays the program's and is lost
    %% (docs/design-pipes.md, "Hand-offs").
    {hand, {pipe_hand, _, Report}} = queue:head(Q),
    {C1, Actions} = pump(drop_head(C)),
    {C1, [{forward, {install_failed, holder(C), element(2, Report), element(3, Report)}} | Actions]};
step(#core{phase = running} = C, {frame, {erx_prog, 1, {closed, Pipe, End}}}) ->
    {C, [{forward, {closed, holder(C), Pipe, End}}]};
step(#core{phase = running} = C, {frame, {erx_prog, 1, {drained, Pipe, End, Writer}}}) ->
    {C, [{forward, {drained, holder(C), Pipe, End, Writer}}]};
step(#core{phase = running} = C, stop) ->
    stop(C);
step(#core{phase = running} = C, {exit_status, Status}) when is_integer(Status) ->
    {C#core{phase = ended, queue = queue:new()}, [{tell_starter, Status}, exit]};
step(#core{phase = running} = C, port_closed) ->
    %% The port closed with no status: a record of the end may be lost, and
    %% the starter is told nothing the handler did not read.
    {C#core{phase = ended, queue = queue:new()}, [exit]};
step(C, _Event) ->
    {C, []}.

%% A stop by the session, asked once.
stop(#core{stopping = false} = C) -> {C#core{stopping = true}, [{stop, ?STOP_STATUS}]};
stop(C) -> {C, []}.

%% The next descriptor's reservation, or the start once none is left.
reserve_next(#core{todo = [{_N, {pipe, End}} | _]} = C) ->
    {C, [{inherit, End}]};
reserve_next(#core{todo = [{_N, {buffer, Peer, Bytes}} | _]} = C) ->
    {C, [{lend, Peer, Bytes}]};
reserve_next(#core{todo = [], made = Made} = C) ->
    {C, [{start, lists:reverse(Made)}]}.

%% Everything a refused start reserved, given back whatever the start took.
undo(#core{made = Newest}) ->
    Made = lists:reverse(Newest),
    [{hand_drop, Number} || {_, {pipe_hand, Number, _}} <- Made] ++
        [{unlend, Lease} || {_, {mem, Lease, _}} <- Made] ++
        [holder_drop].

%% Sends the queue's head when nothing is out.
pump(#core{phase = running, out = false, queue = Q} = C) ->
    case queue:peek(Q) of
        {value, {frame, Frame}} -> {C#core{out = sending}, [{send, Frame}]};
        {value, {hand, Hand}} -> {C#core{out = sending}, [{install, Hand}]};
        empty -> {C, []}
    end;
pump(C) ->
    {C, []}.

enqueue(#core{queue = Q} = C, Out) ->
    C#core{queue = queue:in(Out, Q)}.

drop_head(#core{queue = Q} = C) ->
    C#core{out = false, queue = queue:drop(Q)}.

%% A report that lists copies arrives as the pipe server's hand-off.
outgoing({pipe_hand, Number, _Term} = Hand) when ?IS_POS(Number) -> {hand, Hand};
outgoing(Report) -> {frame, {erx_prog, 1, Report}}.

holder(#core{pid = Pid}) -> {program, Pid}.

holder_errno(eexist) -> einval;
holder_errno(Errno) -> Errno.

%% Each number once, each descriptor of a starter's form, at most one buffer.
valid_fds(Fds) ->
    Numbers = [N || {N, _} <- Fds],
    lists:all(fun valid_fd/1, Fds)
        andalso length(lists:usort(Numbers)) =:= length(Fds)
        andalso length([B || {_, {buffer, _, _}} = B <- Fds]) =< 1.

valid_fd({N, {pipe, _End}}) when ?IS_FD(N) -> true;
valid_fd({N, {buffer, Peer, Bytes}}) when ?IS_FD(N), ?IS_POS(Peer), ?IS_POS(Bytes) -> true;
valid_fd(_) -> false.
