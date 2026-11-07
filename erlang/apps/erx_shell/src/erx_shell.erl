%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell).
-moduledoc """
The command shell's interactive layer (docs/design-shell.md, "The
language", Interaction): a person at a terminal types rc's lines and gets
their results.

The shell is a group's shell, as the Erlang shell is: the group, OTP's
`group` with `edlin`, draws the prompt, edits the line and keeps its
history, and the shell asks it for one line at a time with `get_line`.
What it reads it adds to the unit read so far and hands to the parser
(erx_shell_parse:next_bounded/3); a unit that only more lines could
complete is read on with the continuation prompt, `$prompt(2)`, and a
whole one runs in a process of its own (erx_shell_eval:run_unit/2) with
the heap limit every evaluator has (SH2), so that `Ctrl-C` can end it
and leave the shell. A unit that does not parse is reported and the
shell reads on, as rc does at a terminal; `exit`, and the end of input,
end the shell.

The decisions are pure: after_parse/3 says what the parser's answer to
the source read so far means, and prompt/2 which prompt to show. The
process around them reads, runs and writes.

The shell is a plain process, as the Erlang shell's evaluator is, and the
group, which links to it, owns it. It waits for one event at a time: the
line it asked the group for, the group's interrupt (`Ctrl-C`) or stop
(`Ctrl-Z`), a request of a line or job (background/2, builtin/3), or the
end of a job's first process. It asks for a line by sending the request,
not by io:request/2, so that it serves its jobs while a line is edited. A
unit's process is monitored, never linked.

Job control (docs/design-shell.md, "Job control") is the job table's,
erx_shell_jobs, a pure state machine: the shell feeds it each event and
carries out the effects it returns. The line in the foreground is a job,
and `&` on the shell's own line starts a numbered job in the background;
`&` inside a piece run apart, a job's block among them, stays in that
piece's job, as an `&` inside a UNIX subshell stays in its process group.
Each job's processes share a group leader of the job's own, which passes
the io protocol on to the shell's group: every process a job starts, and
every process those start, inherits it unless it sets a leader of its
own, so it stands in for the job tag of docs/design-shell.md, "Jobs and
their tags". Stopping a job pauses its processes with
erlang:suspend_process/1 and continuing resumes them; `Ctrl-C`, `kill`,
the heap limit or a crash kills them, as an application master kills its
application's processes, and the job's leader then ends. When a job's
first process ends of itself, the job is done and the processes it
started that still run stay with its leader, unlisted, as the processes
a UNIX job leaves stay in its process group, until they end. If the
shell ends first, for any reason, each leader ends every process it
leads, so nothing a job started outlives the session. The
runner needs no rule of its own for this, and its state from the line is
dropped with the line's process; a line that was stopped finishes as a
job, and what it changed is dropped with it.

In Phase 1 the shell is the first shell of the system domain's console:
erx_console starts console/0 on its first group at boot, and starts it
again whenever it ends while input may still come. Its `erl` runs the
Erlang shell above it until that shell ends (erx_cmd_erl), and start/0,
typed at an Erlang shell, has erx_console run another command shell on a
group of its own until it ends, and the Erlang shell then reads on.

Everything outside the language is the runner's (erx_shell_eval's
`runner()`), which the shell builds at its start from a module with
`new(Terminal) -> {Runner, RunnerState}`. `Terminal` is the terminal the
shell runs on, `#{write := fun((iodata()) -> ok)}`, whose `write` puts a
unit's output on the line as bytes, unchanged but for the terminal's own
newline processing, and returns once they are written; the shell adds
`job_control`, which the runner passes to background/2 and builtin/3.
erx_shell_runner, the runner of the session's domain, is the default.
""".

-export([start/0, start/1, server/1, console/0]).
-export([after_parse/3, prompt/2, reader/1]).
-export([background/2, builtin/3]).

-export_type([options/0, terminal/0, reader/0, job_control/0]).

%% How start/1 sets the shell up: the runner's module, and the terminal.
-type options() :: #{runner => module(), terminal => terminal()}.
%% The terminal a runner writes a unit's output to.
-type terminal() :: #{write := fun((iodata()) -> ok), job_control => job_control()}.
%% How a runner reaches the shell's job table: the shell's process.
-opaque job_control() :: pid().

%% What has been read of the next unit: its source so far, and whether an
%% `if not` may start it (erx_shell_parse:if_not_may_follow/2).
-record(reader, {source = <<>> :: binary(),
                 if_before = false :: boolean()}).
-opaque reader() :: #reader{}.

%% The shell's process: what it has read of the next unit, whether more
%% input may come, the job table, and what the effects of the table act on.
-record(s, {sh :: erx_shell_eval:shell(),
            reader :: reader(),
            write :: fun((iodata()) -> ok),
            group :: pid(),
            input = open :: input(),
            jobs = erx_shell_jobs:new() :: erx_shell_jobs:jobs(),
            %% The first process of each job, by its monitor: the job's tag
            %% (the group leader its processes share) and the process.
            firsts = #{} :: #{reference() => {pid(), pid()}},
            %% The processes the shell paused, by the job's tag, which is
            %% the job's leader.
            paused = #{} :: #{pid() => [pid()]},
            %% The shell's own get_line while it waits for a line.
            reading = none :: none | reference(),
            %% The running line's text, which names the jobs it starts.
            text = <<>> :: binary(),
            stop = false :: boolean()}).

%% Whether more input may come.
-type input() :: open | ended.

%% What to do once the parser has seen the source read so far.
-type action() :: read                       % read another line
                | {run, erx_shell_parse:program()}
                | {refuse, erx_shell_parse:diagnostic()}
                | stop.                      % the input ended, and nothing is left

%% The default `$prompt`: the primary prompt, `% ` as csh shows it,
%% where rc shows `; `, and the continuation prompt, empty as in rc.
-define(DEFAULT_PROMPT, [<<"% ">>, <<>>]).
%% Each unit runs within the heap the design gives every evaluator.
-define(UNIT_HEAP_BYTES, (4 * 1024 * 1024)).
%% How often a job's leader looks for the processes its job left running.
-define(LEFTOVER_LOOK_MS, 1000).
-define(BANNER, <<"rc: the command shell; exit ends it\n">>).
%% The console's own shell, which the console starts again when it ends.
-define(CONSOLE_BANNER, <<"rc: the command shell; erl starts the Erlang shell\n">>).

%%% Starting the shell

-doc "start/1 with the default runner and the console's terminal.".
-spec start() -> ok | {error, term()}.
start() ->
    start(#{}).

-doc """
Runs the shell on the console until it ends, in place of the shell that
calls this, and returns `ok`, or `{error, Reason}` with the reason its
process ended if it did not end normally (erx_console:run_shell/1).
Input reaches the shell's own group while
it runs: its history is its own while `kernel`'s `shell_history` is off,
as it is by default, and `Ctrl-C` reaches it, not the caller.
""".
-spec start(options()) -> ok | {error, term()}.
start(Options) when is_map(Options) ->
    Runner = maps:get(runner, Options, erx_shell_runner),
    Terminal = maps:get(terminal, Options, #{write => fun erx_console:write/1}),
    erx_console:run_shell({?MODULE, server, [{Runner, Terminal}]}).

-doc """
Starts the shell's process for a group, which calls this as it calls a
shell's start function, with itself as the group leader, and returns the
process the group then interrupts.
""".
-spec server({module(), terminal()}) -> pid().
server({Runner, Terminal}) ->
    proc_lib:spawn(fun() -> init(Runner, Terminal, ?BANNER) end).

-doc """
Starts the console's own command shell for a group, as server/1 does, with
the default runner and the console's terminal: the shell erx_console starts
on its first group at boot, and again whenever that shell ends.
""".
-spec console() -> pid().
console() ->
    Terminal = #{write => fun erx_console:write/1},
    proc_lib:spawn(fun() -> ok = booted(), init(erx_shell_runner, Terminal, ?CONSOLE_BANNER) end).

%% As stock's first shell does, the console's reads nothing until init has started
%% the boot's applications, unless init was told -async_shell_start.
booted() ->
    case init:get_argument(async_shell_start) of
        {ok, _} -> ok;
        error ->
            case init:notify_when_started(self()) of
                started -> ok;
                _ -> init:wait_until_started()
            end
    end.

init(Runner, Terminal = #{write := Write}, Banner) ->
    process_flag(trap_exit, true),
    {RunnerFun, RunnerState} = Runner:new(Terminal#{job_control => self()}),
    Sh = erx_shell_eval:new(#{<<"prompt">> => ?DEFAULT_PROMPT, <<"*">> => []},
                            RunnerFun, RunnerState),
    ok = Write(Banner),
    next(#s{sh = Sh, reader = reader(<<>>), write = Write, group = group_leader()}).

%%% The functional core

-doc "A reader that has read Source of the next unit, with no `if not` allowed.".
-spec reader(binary()) -> reader().
reader(Source) ->
    #reader{source = Source}.

-doc """
What the parser's answer to the source read so far means, given whether
more input may come. A unit that parses runs, and reading resumes after
it; one that only more lines could complete reads on, or, once the input
has ended, is refused with what the parser said is missing; one that
does not parse is refused with its diagnostic. After a refusal the next
line starts a new unit with no `if not` allowed, as after a unit that ran
none. Once the input has ended and nothing is left, the shell stops.
""".
-spec after_parse(erx_shell_parse:result(), reader(), input()) -> {action(), reader()}.
after_parse({ok, Program, Rest}, R = #reader{if_before = IfBefore}, _Input) ->
    {{run, Program},
     R#reader{source = Rest,
              if_before = erx_shell_parse:if_not_may_follow(Program, IfBefore)}};
after_parse(eof, R, open) ->
    {read, R#reader{source = <<>>}};
after_parse(eof, R, ended) ->
    {stop, R#reader{source = <<>>}};
after_parse({incomplete, _Pos, _Message}, R, open) ->
    {read, R};
after_parse(Missing = {incomplete, _Pos, _Message}, _R, ended) ->
    {{refuse, Missing}, reader(<<>>)};
after_parse({error, Diagnostic, _Rest}, _R, _Input) ->
    {{refuse, Diagnostic}, reader(<<>>)}.

-doc """
The prompt for the next line: `$prompt(1)` at the start of a unit and
`$prompt(2)` within one, empty where `$prompt` has no such element.
""".
-spec prompt(erx_shell_eval:value(), reader()) -> binary().
prompt(Prompt, #reader{source = <<>>}) -> nth_or_empty(1, Prompt);
prompt(Prompt, #reader{}) -> nth_or_empty(2, Prompt).

nth_or_empty(N, List) when length(List) >= N -> lists:nth(N, List);
nth_or_empty(_N, _List) -> <<>>.

%%% The process


%% What comes next once an event is handled: with no line running and no
%% line being read, the next unit runs or the next line is read.
next(#s{stop = true}) ->
    ok;
next(S = #s{reading = none, jobs = Jobs}) ->
    case erx_shell_jobs:line(Jobs) of
        idle -> proceed(S);
        busy -> wait(S)
    end;
next(S) ->
    wait(S).

%% Does what the parser's answer to the source read so far calls for: runs a
%% unit, reports a refused one, reads a line, or ends.
proceed(S = #s{sh = Sh, reader = R = #reader{source = Source, if_before = IfBefore}, input = Input}) ->
    Parsed = erx_shell_parse:next_bounded(Source, more, IfBefore),
    case after_parse(Parsed, R, Input) of
        {read, R1} ->
            wait(read(S#s{reader = R1}));
        {stop, _R1} ->
            ok;
        {{run, Program}, R1 = #reader{source = Rest}} ->
            Text = unit_text(Source, Rest),
            wait(start_line(fun() -> erx_shell_eval:run_unit(Program, Sh) end, Text,
                            S#s{reader = R1}));
        {{refuse, Diagnostic}, R1} ->
            %% The evaluator reports it as it reports a unit of a script that
            %% does not parse: the diagnostic on descriptor 2, and `$status`.
            wait(start_line(fun() -> erx_shell_eval:parse_fault(Diagnostic, Sh) end, <<>>,
                            S#s{reader = R1}))
    end.

%% The text of the unit just parsed: what was read before Rest, without the
%% newline that ended it.
unit_text(Source, Rest) ->
    Unit = binary:part(Source, 0, byte_size(Source) - byte_size(Rest)),
    string:trim(Unit, trailing, "\n").

%% Reports the background jobs done since the last prompt, as a UNIX shell
%% does, and asks the group for the next line. The request is sent, not
%% made with io:request/2, so that the shell serves its jobs and sees their
%% ends while the line is edited.
read(S = #s{jobs = Jobs, group = Group, sh = Sh, reader = R}) ->
    {Reports, Jobs1} = erx_shell_jobs:reap(Jobs),
    S1 = effects(Reports, S#s{jobs = Jobs1}),
    Prompt = prompt(erx_shell_eval:var(<<"prompt">>, Sh), R),
    Ref = make_ref(),
    Group ! {io_request, self(), Ref, {get_line, unicode, chars(Prompt)}},
    S1#s{reading = Ref}.

%% Waits for the next event: the line read, the group's interrupt or stop,
%% a job's request, or the end of a job's first process.
wait(S = #s{group = Group, reading = Reading, firsts = Firsts}) ->
    receive
        {io_reply, Reading, Reply} when Reading =/= none ->
            next(got_line(Reply, S#s{reading = none}));
        {'EXIT', Group, interrupt} ->
            %% Ctrl-C while a line runs. While the shell's own get_line is
            %% outstanding the group answers it with `{error, interrupted}`
            %% instead (group.erl, `handle_info/3` on `interrupt`), so an
            %% interrupt that arrives while a line is read came before it,
            %% and the table, with no line running, ignores it.
            next(table(erx_shell_jobs:interrupt(S#s.jobs), S));
        {Group, suspend} ->
            next(table(erx_shell_jobs:suspend(S#s.jobs), S));
        {?MODULE, From, Ref, Request} when is_pid(From), is_reference(Ref) ->
            next(request(Request, {From, Ref}, S));
        {'DOWN', Ref, process, _Pid, Reason} when is_map_key(Ref, Firsts) ->
            next(first_ended(Ref, Reason, S));
        {'EXIT', Group, _Reason} ->
            %% The group, and with it the terminal, is gone. The shell ends,
            %% and each job's leader ends its job when it sees that.
            ok;
        _Other ->
            wait(S)
    end.

%% A line the end of input ended has no newline of its own, as the group's
%% editor ends the line it edits when its input ends: the line runs, and
%% the shell ends.
got_line(eof, S) ->
    S#s{input = ended};
got_line({error, interrupted}, S = #s{write = Write, reader = R}) ->
    %% Ctrl-C while editing: the unit read so far is dropped.
    ok = Write(<<"\n">>),
    S#s{reader = R#reader{source = <<>>}};
got_line({error, _Reason}, S) ->
    S#s{stop = true};
got_line(Chars, S = #s{reader = R = #reader{source = Source}}) ->
    Line = unicode:characters_to_binary(Chars),
    Input = case ends_in_newline(Line) of
                true -> open;
                false -> ended
            end,
    S#s{reader = R#reader{source = <<Source/binary, (with_newline(Line))/binary>>}, input = Input}.

ends_in_newline(Line) ->
    byte_size(Line) > 0 andalso binary:last(Line) =:= $\n.

with_newline(Line) ->
    case ends_in_newline(Line) of
        true -> Line;
        false -> <<Line/binary, $\n>>
    end.

%% A prompt's bytes as the group's characters, UTF-8 where they are and
%% latin-1 where they are not.
chars(Prompt) ->
    case unicode:characters_to_list(Prompt) of
        Chars when is_list(Chars) -> Chars;
        _Invalid -> binary_to_list(Prompt)
    end.

%%% Lines and jobs

%% Runs Evaluate, which calls the evaluator and through it the runner, as
%% the line in the foreground. A crash ends the process with a fixed reason
%% and no report, since a crash's reason and stack carry the shell's
%% variables and the runner's state, which must not reach a log.
start_line(Evaluate, Text, S = #s{jobs = Jobs}) ->
    Unit = fun() ->
                   Outcome = try Evaluate()
                             catch _Class:_Reason -> crashed
                             end,
                   exit({?MODULE, Outcome})
           end,
    {Leader, S1} = start_first(Unit, S),
    S1#s{jobs = erx_shell_jobs:start_line(Leader, Text, Jobs), text = Text}.

%% Starts Run, a background block of the running line, as a numbered job.
start_job(Run, S) ->
    Job = fun() ->
                  Status = try Run()
                           catch _Class:_Reason -> crashed
                           end,
                  exit({?MODULE, job, Status})
          end,
    start_first(Job, S).

%% Starts a job's first process under a group leader of the job's own,
%% which is its tag, with the heap limit every evaluator has (SH2). The
%% process waits until the shell has given it the leader, so everything it
%% starts inherits the leader, and the leader finds it if the shell ends.
start_first(Body, S = #s{group = Group, firsts = Firsts}) ->
    Leader = leader(Group),
    Heap = #{size => ?UNIT_HEAP_BYTES div erlang:system_info(wordsize),
             kill => true, error_logger => false, include_shared_binaries => true},
    First = fun() -> receive {?MODULE, go} -> Body() end end,
    {Pid, Ref} = spawn_opt(First, [monitor, {max_heap_size, Heap}]),
    true = group_leader(Leader, Pid),
    Pid ! {?MODULE, go},
    {Leader, S#s{firsts = Firsts#{Ref => {Leader, Pid}}}}.

%% What a job's first process ended with, for the table, and for the
%% shell if the process was the line's and the line ends in the foreground.
ending({?MODULE, {exit, Sh}}) -> {{exited, status(Sh)}, stop};
ending({?MODULE, crashed}) -> {failed, {diagnose, <<"rc: the line crashed\n">>}};
ending({?MODULE, job, crashed}) -> {failed, none};
ending({?MODULE, job, Status}) when is_binary(Status) -> {{exited, Status}, none};
ending({?MODULE, Outcome}) -> {{exited, status(shell(Outcome))}, {continue, shell(Outcome)}};
ending(killed) -> {failed, {diagnose, <<"rc: the line passed its heap limit\n">>}};
ending(_Crash) -> {failed, {diagnose, <<"rc: the line crashed\n">>}}.

%% The shell an evaluator's outcome leaves.
shell({ok, Sh}) -> Sh;
shell({syntax_error, _Message, Sh}) -> Sh;
shell({error, _Message, Sh}) -> Sh.

%% `$status` as one text, a pipeline's statuses joined by `|` as rc shows them.
status(Sh) ->
    iolist_to_binary(lists:join($|, erx_shell_eval:var(<<"status">>, Sh))).

first_ended(Ref, Reason, S = #s{firsts = Firsts, jobs = Jobs}) ->
    {Tag, _Pid} = maps:get(Ref, Firsts),
    {Result, ForShell} = ending(Reason),
    {Effects, Jobs1} = erx_shell_jobs:ended(Tag, Result, Jobs),
    S1 = effects(Effects, S#s{jobs = Jobs1, firsts = maps:remove(Ref, Firsts)}),
    case lists:member({finish_line, Tag}, Effects) of
        true -> finish_line(ForShell, S1);
        false -> S1
    end.

%% The line ended in the foreground: the shell goes on with what it left,
%% keeps what it had if it failed, or ends after `exit`.
finish_line(stop, S) -> S#s{stop = true};
finish_line({continue, Sh}, S) -> S#s{sh = Sh};
finish_line({diagnose, Message}, S = #s{write = Write}) -> ok = Write(Message), S.

%% The table after an event, with its effects carried out.
table({Effects, Jobs}, S) ->
    effects(Effects, S#s{jobs = Jobs}).

%% A request of the running line or of a job (background/2, builtin/3).
%% Any process may send one, so the shell checks it whole: starting and
%% moving jobs is the line's alone, and a malformed request is refused.
request(Request, Waiter = {From, _Ref}, S) ->
    case erx_shell_jobs:valid_request(Request) of
        false ->
            answer(Waiter, {error, <<"malformed request">>}, S);
        true when element(1, Request) =:= jobs; element(1, Request) =:= signal ->
            serve(Request, Waiter, S);
        true ->
            case from_line(From, S) of
                true -> serve(Request, Waiter, S);
                false -> answer(Waiter, {error, <<"no job control">>}, S)
            end
    end.

%% Whether From is a process of the running line: the line's first process
%% or one that shares its leader.
from_line(From, #s{jobs = Jobs}) ->
    case erx_shell_jobs:line_tag(Jobs) of
        none -> false;
        Tag -> process_info(From, group_leader) =:= {group_leader, Tag}
    end.

serve({background, Run}, Waiter, S = #s{text = Text}) ->
    {Leader, S1 = #s{jobs = Jobs}} = start_job(Run, S),
    {Id, Effects, Jobs1} = erx_shell_jobs:start_background(Leader, Text, Jobs),
    answer(Waiter, {ok, Id}, effects(Effects, S1#s{jobs = Jobs1}));
serve({jobs}, Waiter, S = #s{jobs = Jobs}) ->
    {Text, Jobs1} = erx_shell_jobs:list(Jobs),
    answer(Waiter, {ok, Text}, S#s{jobs = Jobs1});
serve({fg, Spec}, Waiter, S = #s{jobs = Jobs}) ->
    case erx_shell_jobs:foreground(Spec, Waiter, Jobs) of
        {wait, Effects, Jobs1} -> effects(Effects, S#s{jobs = Jobs1});
        {Error, Effects, Jobs1} -> answer(Waiter, Error, effects(Effects, S#s{jobs = Jobs1}))
    end;
serve({bg, Spec}, Waiter, S = #s{jobs = Jobs}) ->
    {Reply, Effects, Jobs1} = erx_shell_jobs:background(Spec, Jobs),
    answer(Waiter, Reply, effects(Effects, S#s{jobs = Jobs1}));
serve({signal, Signal, Spec}, Waiter, S = #s{jobs = Jobs}) ->
    {Reply, Effects, Jobs1} = erx_shell_jobs:signal(Signal, Spec, Jobs),
    answer(Waiter, Reply, effects(Effects, S#s{jobs = Jobs1})).

answer({From, Ref}, Reply, S) ->
    From ! {Ref, Reply},
    S.

%%% The effects of the job table

effects(Effects, S) ->
    lists:foldl(fun effect/2, S, Effects).

effect({stop, Tag}, S) -> pause(Tag, S);
effect({resume, Tag}, S) -> resume(Tag, S);
effect({terminate, Tag}, S) -> terminate(Tag, S);
effect({release, Tag, Fate}, S) ->
    S1 = resume(Tag, S),
    ok = release(Fate, Tag),
    S1;
effect({finish_line, _Tag}, S) -> S;
effect({say, Bytes}, S = #s{write = Write}) -> ok = Write(Bytes), S;
effect({answer, Waiter, Reply}, S) -> answer(Waiter, Reply, S).

%% Pauses every process of the job tagged Tag. Each pass pauses those not
%% paused yet; erlang:suspend_process/1 returns once its process is
%% paused, and a paused process starts nothing, so the passes end when one
%% finds none, with every process the job had then paused.
pause(Tag, S = #s{paused = Paused}) ->
    Done = pause_passes(Tag, firsts_of(Tag, S), maps:get(Tag, Paused, [])),
    S#s{paused = Paused#{Tag => Done}}.

pause_passes(Tag, Firsts, Done) ->
    case lists:usort(Firsts ++ led_by(Tag)) -- Done of
        [] ->
            Done;
        New ->
            %% A process that ended meanwhile is tried once and never found again.
            [_ = suspend_quietly(Pid) || Pid <- New],
            pause_passes(Tag, [], New ++ Done)
    end.

%% Resumes the processes pause/2 paused for the job tagged Tag.
resume(Tag, S = #s{paused = Paused}) ->
    [resume_quietly(Pid) || Pid <- maps:get(Tag, Paused, [])],
    S#s{paused = maps:remove(Tag, Paused)}.

%% Ends every process of the job tagged Tag, its first process even before
%% it has taken the job's leader, then resumes those it had paused, as
%% `kill` of a stopped UNIX job continues it after the signal, and ends the
%% leader. The first process's end still reaches first_ended/3.
terminate(Tag, S = #s{paused = Paused}) ->
    [exit(Pid, kill) || Pid <- firsts_of(Tag, S)],
    ok = each_process_led_by(Tag, fun(Pid) -> exit(Pid, kill) end),
    [resume_quietly(Pid) || Pid <- maps:get(Tag, Paused, [])],
    exit(Tag, kill),
    S#s{paused = maps:remove(Tag, Paused)}.

firsts_of(Tag, #s{firsts = Firsts}) ->
    [Pid || {T, Pid} <- maps:values(Firsts), T =:= Tag].

suspend_quietly(Pid) ->
    try erlang:suspend_process(Pid)
    catch error:badarg -> false
    end.

%% A process that has ended, or was never paused because it ended first,
%% is left as it is.
resume_quietly(Pid) ->
    try erlang:resume_process(Pid)
    catch error:badarg -> false
    end.

%%% A job's processes

%% The group leader of a job's processes, which is the job's tag: it passes
%% each io request on to the shell's group, which answers the requester
%% itself, and drops any other message. Once the job's first process has
%% ended (release/2), the leader stays while it still leads a process,
%% looking once a second, and then ends. If the shell ends first, for any
%% reason, the leader ends every process it leads and then itself, so no
%% process a job started outlives its session.
leader(Group) ->
    Shell = self(),
    spawn(fun() -> forward(Group, monitor(process, Shell), infinity) end).

forward(Group, ShellRef, Look) ->
    receive
        {io_request, _From, _ReplyAs, _Request} = Request ->
            Group ! Request,
            forward(Group, ShellRef, Look);
        {'DOWN', ShellRef, process, _, _} ->
            each_process_led_by(self(), fun(Pid) -> exit(Pid, kill) end);
        {?MODULE, released} ->
            forward(Group, ShellRef, ?LEFTOVER_LOOK_MS);
        _Other ->
            forward(Group, ShellRef, Look)
    after Look ->
        case led_by(self()) of
            [] -> ok;
            _Left -> forward(Group, ShellRef, Look)
        end
    end.

%% The job's first process has ended. After a crash or the heap limit
%% (`kill`) every process the job's leader leads is killed, and then the
%% leader; after a normal end (`keep`) the processes it started still
%% running stay with the leader, unlisted, as the processes a UNIX job
%% leaves stay in its process group, and end with the session at the
%% latest. Each pass looks at every process. exit/2 is a signal, and the
%% next pass's process_info/2 is a signal from the same sender to the same
%% process, which arrives after it, so a process a pass killed is not found
%% again; one started meanwhile is found by the next pass. The passes end
%% when one finds none, as application_master's kill_all_procs does.
release(kill, Leader) ->
    ok = each_process_led_by(Leader, fun(Pid) -> exit(Pid, kill) end),
    exit(Leader, kill),
    ok;
release(keep, Leader) ->
    Leader ! {?MODULE, released},
    ok.

each_process_led_by(Leader, Act) ->
    case led_by(Leader) of
        [] ->
            ok;
        Led ->
            lists:foreach(Act, Led),
            each_process_led_by(Leader, Act)
    end.

%% The processes Leader leads. The leader is excluded only for clarity: its
%% own group leader is the shell's group.
led_by(Leader) ->
    [Pid || Pid <- processes(), Pid =/= Leader,
            process_info(Pid, group_leader) =:= {group_leader, Leader}].

%%% What runners ask of the shell

-doc """
Starts Run, a background block of the line the shell is running, as a
numbered job, and returns its number; JobControl is what the shell put in
the terminal it gave the runner. Run returns the block's status.
""".
-spec background(job_control(), fun(() -> binary())) -> {ok, pos_integer()} | {error, binary()}.
background(Shell, Run) when is_pid(Shell), is_function(Run, 0) ->
    call(Shell, {background, Run}).

-doc """
Runs the job builtin Name (`jobs`, `fg`, `bg` or `kill`) with Args, and
returns its status and what it writes on standard output and standard
error. Where is how the runner reached the builtin: from the shell's own
line, from a piece of a line run apart (a stage, a substitution, a
subshell or a block inside a job), which may list and signal jobs but not
move them, or with no job control at all, as in a script.
""".
-spec builtin(binary(), [binary()], {job_control(), line | apart} | none) ->
          {binary(), iodata(), iodata()}.
builtin(Name, _Args, none) ->
    failed(Name, <<"no job control">>);
builtin(<<"jobs">>, [], {Shell, _Where}) ->
    case call(Shell, {jobs}) of
        {ok, Text} -> {<<>>, Text, []};
        {error, Reason} -> failed(<<"jobs">>, Reason)
    end;
builtin(<<"jobs">>, _Args, _JobControl) ->
    usage(<<"jobs">>);
builtin(Name, _Args, {_Shell, apart}) when Name =:= <<"fg">>; Name =:= <<"bg">> ->
    failed(Name, <<"no job control">>);
builtin(Name, Args, {Shell, line}) when Name =:= <<"fg">>; Name =:= <<"bg">> ->
    Request = case Name of
                  <<"fg">> -> fg;
                  <<"bg">> -> bg
              end,
    case Args of
        [] -> moved(Name, call(Shell, {Request, current}));
        [Arg] -> on_job(Name, Arg, fun(Spec) -> moved(Name, call(Shell, {Request, Spec})) end);
        _ -> usage(Name)
    end;
builtin(<<"kill">>, Args, {Shell, _Where}) ->
    case erx_shell_jobs:parse_kill(Args) of
        list -> {<<>>, erx_shell_jobs:signal_names(), []};
        usage -> usage(<<"kill">>);
        {ok, Signal, Jobs} -> kill(Shell, Signal, Jobs)
    end;
builtin(Name, _Args, _JobControl) ->
    failed(Name, <<"not a job builtin">>).

%% Signals each job in turn; the status is the first failure's, as
%% FreeBSD's kill fails if any of its operands does.
kill(Shell, Signal, Jobs) ->
    Each = [on_job(<<"kill">>, Arg,
                   fun(Spec) -> moved(<<"kill">>, call(Shell, {signal, Signal, Spec})) end)
            || Arg <- Jobs],
    Status = case [S || {S, _, _} <- Each, S =/= <<>>] of
                 [] -> <<>>;
                 [First | _] -> First
             end,
    {Status, [Out || {_, Out, _} <- Each], [Err || {_, _, Err} <- Each]}.

on_job(Name, Arg, Act) ->
    case erx_shell_jobs:parse_spec(Arg) of
        {ok, Spec} -> Act(Spec);
        error -> failed(Name, [erx_text:escape_line(Arg), <<": no such job">>])
    end.

moved(_Name, ok) -> {<<>>, [], []};
moved(_Name, {ok, Status}) when is_binary(Status) -> {Status, [], []};
moved(Name, {error, Reason}) -> failed(Name, Reason).

failed(Name, Reason) ->
    Text = iolist_to_binary(Reason),
    {Text, [], [Name, <<": ">>, Text, $\n]}.

usage(<<"jobs">>) -> {<<"usage">>, [], <<"usage: jobs\n">>};
usage(<<"fg">>) -> {<<"usage">>, [], <<"usage: fg [%job]\n">>};
usage(<<"bg">>) -> {<<"usage">>, [], <<"usage: bg [%job]\n">>};
usage(<<"kill">>) -> {<<"usage">>, [], <<"usage: kill [-s signal | -signal] %job ...\n       kill -l\n">>}.

%% Asks the shell and waits for its answer, which for `fg` comes when the
%% job ends or stops.
call(Shell, Request) ->
    Ref = monitor(process, Shell),
    Shell ! {?MODULE, self(), Ref, Request},
    receive
        {Ref, Reply} ->
            demonitor(Ref, [flush]),
            Reply;
        {'DOWN', Ref, process, _, _} ->
            {error, <<"the shell has ended">>}
    end.
