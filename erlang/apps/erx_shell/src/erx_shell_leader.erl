%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_leader).
-moduledoc """
A job's leader: the group leader of every process a job starts, which ends
them all when the process that started the leader ends, so no process a job
started outlives the shell or the exec it ran under. It stands in for the
runtime's job tag (docs/design-shell.md, "Jobs and their tags"; TODO.md, "a
job's processes are found by group leader"). The command shell starts one
per job (erx_shell), and `rc -c` on a tty one for its whole command
(erx_shell_script:command/3).

A process joins the job by having the leader as its group leader, which
everything it spawns inherits, so membership needs no list: the processes a
leader leads are found by asking each process for its group leader.

The leader passes each io request on to the terminal's group, which answers
the requester itself and drops the request of a reader that has ended, and
drops any other message. It ends every process it
leads, and then itself, when its starter ends, for any reason; release/2
ends the job's processes at once (`kill`), or lets the leader end on its own
once it leads none (`keep`), as the processes a UNIX job leaves stay in its
process group; close/1 ends them and the leader once the leader has passed
on every io request they sent.
""".

-export([start/1, spawn_member/3, release/2, close/1, end_all/1, led_by/1]).

%% How often a released leader looks for the processes its job left running.
-define(LEFTOVER_LOOK_MS, 1000).

-doc """
Starts a leader for a job of the calling process whose io goes to Group, the
terminal's group. The leader ends what it leads once the caller ends.
""".
-spec start(pid()) -> pid().
start(Group) ->
    Starter = self(),
    spawn(fun() -> forward(Group, monitor(process, Starter), infinity) end).

forward(Group, StarterRef, Look) ->
    receive
        {io_request, From, _ReplyAs, _Request} = Message when is_pid(From) ->
            %% Every request is passed on, the last output of a process that has ended
            %% included; the group watches the process that reads, so the terminal
            %% never reads input for one that has ended.
            Group ! Message,
            forward(Group, StarterRef, Look);
        {'DOWN', StarterRef, process, _, _} ->
            end_all(self());
        {?MODULE, released} ->
            forward(Group, StarterRef, ?LEFTOVER_LOOK_MS);
        {?MODULE, close} ->
            ok;
        _Other ->
            forward(Group, StarterRef, Look)
    after Look ->
        case led_by(self()) of
            [] -> ok;
            _Left -> forward(Group, StarterRef, Look)
        end
    end.

-doc """
Spawns Body, evaluator code, as a process of Leader's job, with a monitor and
a heap limit of HeapWords, as erx_shell_runner:spawn_evaluator/3 spawns it and
with the ending that gives: it is given Leader as its group leader before it runs,
so everything it starts is led by Leader too, and it waits for Go, which the
caller calls once it has recorded the process. The caller is not linked to
it; it watches the caller while it waits, so a caller that ends before Go,
as one killed between the spawn and the group leader's change, ends it too,
having run nothing.
""".
-spec spawn_member(pid(), fun(() -> term()), pos_integer()) ->
          {pid(), reference(), fun(() -> ok)}.
spawn_member(Leader, Body, HeapWords) ->
    Go = make_ref(),
    Caller = self(),
    Member = fun() ->
                     Watch = monitor(process, Caller),
                     receive
                         Go -> demonitor(Watch, [flush]), Body();
                         {'DOWN', Watch, process, _, _} -> unstarted
                     end
             end,
    {Pid, Ref} = erx_shell_runner:spawn_evaluator(Member, HeapWords, [monitor]),
    true = group_leader(Leader, Pid),
    {Pid, Ref, fun() -> Pid ! Go, ok end}.

-doc """
The job's first process has ended. After a crash, the heap limit or an
interrupt (`kill`) the job ends (close/1); after a normal end (`keep`) the
processes still running stay with the leader, unlisted, and end with its
starter at the latest.
""".
-spec release(kill | keep, pid()) -> ok.
release(kill, Leader) ->
    close(Leader);
release(keep, Leader) ->
    Leader ! {?MODULE, released},
    ok.

-doc """
Ends the job of Leader: kills every process it leads (end_all/1), and
returns once the leader has passed on to the terminal's group every io
request that came before, and ended. A process the job killed sent its
last request before it died, so the group has all the job's output when
this returns, and output the job wrote comes before anything the caller
says once this returns, such as its exit status. That rests on ERTS, not on
Erlang's per-pair order: on one node a send joins its receiver's queue at once,
which holds while neither the leader nor the group keeps its messages off heap.
""".
-spec close(pid()) -> ok.
close(Leader) ->
    ok = end_all(Leader),
    Watch = monitor(process, Leader),
    Leader ! {?MODULE, close},
    receive {'DOWN', Watch, process, _, _} -> ok end.

-doc """
Kills every process Leader leads. Each pass looks at every process. exit/2
is a signal, and the next pass's process_info/2 is a signal from the same
sender to the same process, which arrives after it, so a process a pass
killed is not found again; one started meanwhile is found by the next pass.
The passes end when one finds none, as application_master's kill_all_procs
does.
""".
-spec end_all(pid()) -> ok.
end_all(Leader) ->
    case led_by(Leader) of
        [] ->
            ok;
        Led ->
            lists:foreach(fun(Pid) -> exit(Pid, kill) end, Led),
            end_all(Leader)
    end.

-doc """
The processes Leader leads. The leader is excluded only for clarity: its own
group leader is its starter's.
""".
-spec led_by(pid()) -> [pid()].
led_by(Leader) ->
    [Pid || Pid <- processes(), Pid =/= Leader,
            process_info(Pid, group_leader) =:= {group_leader, Leader}].
