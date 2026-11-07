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

The shell is a plain process, as the Erlang shell's evaluator is: it
spends its life blocked in a group's `get_line` and in waiting for a
unit, and the group, which links to it, owns it. A unit's process is
monitored, never linked.

What a line starts ends with it. A unit's process has a group leader of
its own, the line's, which passes the io protocol on to the shell's
group, and every process the unit starts, and every process those start,
inherits it unless it sets a leader of its own; it stands in for the
job tag of docs/design-shell.md, "Jobs and their tags". When `Ctrl-C`, the heap limit or a crash ends the line, the
shell kills every process whose group leader is the line's, as an
application master kills its application's processes; when the line
ends of itself, those still running, its background blocks, get the
shell's group as their group leader and run on. Either way the line's
leader then ends. The runner needs no rule of its own for this, and its
state from the line is dropped with the line's process.

In Phase 1 the shell takes the system domain's console from the Erlang
shell: start/0, typed at the Erlang shell, has erx_console run it on a
group of its own until it ends, and the Erlang shell then reads on.

Everything outside the language is the runner's (erx_shell_eval's
`runner()`), which the shell builds at its start from a module with
`new(Terminal) -> {Runner, RunnerState}`. `Terminal` is the terminal the
shell runs on, `#{write := fun((iodata()) -> ok)}`, whose `write` puts a
unit's output on the line as bytes, unchanged but for the terminal's own
newline processing, and returns once they are written.
erx_shell_runner, the runner of the session's domain, is the default.
""".

-export([start/0, start/1, server/1]).
-export([after_parse/3, prompt/2, reader/1, hand_over/2]).

-export_type([options/0, terminal/0, reader/0]).

%% How start/1 sets the shell up: the runner's module, and the terminal.
-type options() :: #{runner => module(), terminal => terminal()}.
%% The terminal a runner writes a unit's output to.
-type terminal() :: #{write := fun((iodata()) -> ok)}.

%% What has been read of the next unit: its source so far, and whether an
%% `if not` may start it (erx_shell_parse:if_not_may_follow/2).
-record(reader, {source = <<>> :: binary(),
                 if_before = false :: boolean()}).
-opaque reader() :: #reader{}.

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
-define(BANNER, <<"rc: the command shell; exit ends it\n">>).

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
    proc_lib:spawn(fun() -> init(Runner, Terminal) end).

init(Runner, Terminal = #{write := Write}) ->
    process_flag(trap_exit, true),
    {RunnerFun, RunnerState} = Runner:new(Terminal),
    Sh = erx_shell_eval:new(#{<<"prompt">> => ?DEFAULT_PROMPT, <<"*">> => []},
                            RunnerFun, RunnerState),
    ok = Write(?BANNER),
    loop(Sh, reader(<<>>), Write, open).

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

%% Does what the parser's answer to the source read so far calls for: runs a
%% unit, reports a refused one, reads a line, or ends.
loop(Sh, R = #reader{source = Source, if_before = IfBefore}, Write, Input) ->
    Parsed = erx_shell_parse:next_bounded(Source, more, IfBefore),
    case after_parse(Parsed, R, Input) of
        {read, R1} ->
            read(Sh, R1, Write);
        {stop, _R1} ->
            ok;
        {{run, Program}, R1} ->
            next(run(fun() -> erx_shell_eval:run_unit(Program, Sh) end, Sh, Write),
                 R1, Write, Input);
        {{refuse, Diagnostic}, R1} ->
            %% The evaluator reports it as it reports a unit of a script that
            %% does not parse: the diagnostic on descriptor 2, and `$status`.
            next(run(fun() -> erx_shell_eval:parse_fault(Diagnostic, Sh) end, Sh, Write),
                 R1, Write, Input)
    end.

next({continue, Sh}, R, Write, Input) -> loop(Sh, R, Write, Input);
next(stop, _R, _Write, _Input) -> ok.

%% Reads the next line. A line the end of input ended has no newline of its
%% own, as the group's editor ends the line it edits when its input ends:
%% the line runs, and the shell ends.
read(Sh, R = #reader{source = Source}, Write) ->
    Group = group_leader(),
    Prompt = prompt(erx_shell_eval:var(<<"prompt">>, Sh), R),
    Reply = io:request(Group, {get_line, unicode, chars(Prompt)}),
    drop_interrupts(Group),
    case Reply of
        eof ->
            loop(Sh, R, Write, ended);
        {error, interrupted} ->
            %% Ctrl-C while editing: the unit read so far is dropped.
            ok = Write(<<"\n">>),
            read(Sh, R#reader{source = <<>>}, Write);
        {error, _Reason} ->
            ok;
        Chars ->
            Line = unicode:characters_to_binary(Chars),
            Input = case ends_in_newline(Line) of
                        true -> open;
                        false -> ended
                    end,
            loop(Sh, R#reader{source = <<Source/binary, (with_newline(Line))/binary>>},
                 Write, Input)
    end.

ends_in_newline(Line) ->
    byte_size(Line) > 0 andalso binary:last(Line) =:= $\n.

with_newline(Line) ->
    case ends_in_newline(Line) of
        true -> Line;
        false -> <<Line/binary, $\n>>
    end.

%% Drops the group's interrupts already queued. The group interrupts the
%% shell only while no line is being read, and signals between two
%% processes arrive in the order they were sent, so an interrupt queued
%% when a line's reply has arrived came before that line and ends nothing.
drop_interrupts(Group) ->
    receive
        {'EXIT', Group, interrupt} -> drop_interrupts(Group)
    after 0 ->
        ok
    end.

%% A prompt's bytes as the group's characters, UTF-8 where they are and
%% latin-1 where they are not.
chars(Prompt) ->
    case unicode:characters_to_list(Prompt) of
        Chars when is_list(Chars) -> Chars;
        _Invalid -> binary_to_list(Prompt)
    end.

%% The shell an evaluator's outcome leaves.
shell({ok, Sh}) -> Sh;
shell({exit, Sh}) -> Sh;
shell({syntax_error, _Message, Sh}) -> Sh;
shell({error, _Message, Sh}) -> Sh.

%% Runs Evaluate, which calls the evaluator and through it the runner, in a
%% process of its own under the line's own group leader, which Ctrl-C ends,
%% and returns whether the shell goes on and with what, once the processes
%% the line started have ended or joined the shell's group (end_line/3). A
%% crash ends the process with a fixed reason and no report, since a
%% crash's reason and stack carry the shell's variables and the runner's
%% state, which must not reach a log.
run(Evaluate, Sh, Write) ->
    Group = group_leader(),
    Leader = line_leader(Group),
    Heap = #{size => ?UNIT_HEAP_BYTES div erlang:system_info(wordsize),
             kill => true, error_logger => false, include_shared_binaries => true},
    Unit = fun() ->
                   %% First, so that every process the line starts inherits
                   %% the line's leader.
                   true = group_leader(Leader, self()),
                   Outcome = try Evaluate()
                             catch _Class:_Reason -> crashed
                             end,
                   exit({?MODULE, Outcome})
           end,
    {Pid, Ref} = spawn_opt(Unit, [monitor, {max_heap_size, Heap}]),
    {Fate, Next} = wait(Group, Pid, Ref, Sh, Write),
    ok = end_line(Fate, Leader, Group),
    Next.

%% How the unit ended: what becomes of the processes the line started,
%% `adopt` when the line ended of itself and `kill` otherwise, and whether
%% the shell goes on.
wait(Group, Pid, Ref, Sh, Write) ->
    receive
        {'DOWN', Ref, process, Pid, {?MODULE, {exit, _Sh1}}} ->
            {adopt, stop};
        {'DOWN', Ref, process, Pid, {?MODULE, crashed}} ->
            ok = Write(<<"rc: the line crashed\n">>),
            {kill, {continue, Sh}};
        {'DOWN', Ref, process, Pid, {?MODULE, Outcome}} ->
            %% A fault of the language was written by the evaluator; a
            %% terminal reads on.
            {adopt, {continue, shell(Outcome)}};
        {'DOWN', Ref, process, Pid, killed} ->
            ok = Write(<<"rc: the line passed its heap limit\n">>),
            {kill, {continue, Sh}};
        {'DOWN', Ref, process, Pid, _Crash} ->
            ok = Write(<<"rc: the line crashed\n">>),
            {kill, {continue, Sh}};
        {'EXIT', Group, interrupt} ->
            %% Ctrl-C while the unit runs: it ends, and the shell keeps the
            %% state it had before the unit. The terminal shows the key as a
            %% cooked tty echoes it.
            exit(Pid, kill),
            receive {'DOWN', Ref, process, Pid, _} -> ok end,
            ok = Write(<<"^C\n">>),
            {kill, {continue, Sh}};
        {'EXIT', Group, _Reason} ->
            %% The group, and with it the terminal, is gone, so no group is
            %% left to hand the line's processes to: they end with it.
            exit(Pid, kill),
            receive {'DOWN', Ref, process, Pid, _} -> ok end,
            {kill, stop}
    end.

%%% A line's processes

%% The group leader of a line's processes: it passes each io request on to
%% the shell's group, which answers the requester itself, drops any other
%% message, and ends when the shell does or end_line/3 kills it.
line_leader(Group) ->
    Shell = self(),
    spawn(fun() -> forward(Group, monitor(process, Shell)) end).

forward(Group, ShellRef) ->
    receive
        {io_request, _From, _ReplyAs, _Request} = Request ->
            Group ! Request,
            forward(Group, ShellRef);
        {'DOWN', ShellRef, process, _, _} ->
            ok;
        _Other ->
            forward(Group, ShellRef)
    end.

%% Kills the processes the line's leader leads, or gives them the shell's
%% group as their leader, and then kills the line's leader. Each pass looks
%% at every process. exit/2 and group_leader/2 are signals, and the next
%% pass's process_info/2 is a signal from the same sender to the same
%% process, which arrives after them, so a process a pass killed or handed
%% over is not found again; one started meanwhile is found by the next
%% pass. The passes end when one finds none, as application_master's
%% kill_all_procs does. A process may end between being found and being
%% acted on: exit/2 ignores that, and hand_over/2 allows for it.
end_line(Fate, Leader, Group) ->
    Act = case Fate of
              kill -> fun(Pid) -> exit(Pid, kill) end;
              adopt -> fun(Pid) -> hand_over(Group, Pid) end
          end,
    ok = each_process_led_by(Leader, Act),
    exit(Leader, kill),
    ok.

-doc """
Gives Pid the shell's group, Group, as its group leader, and returns `ok`,
as end_line/3 hands over a line's processes; a process that has ended
meanwhile is left as it is. Exported for the tests.
""".
-spec hand_over(pid(), pid()) -> ok.
hand_over(Group, Pid) ->
    try group_leader(Group, Pid) of
        true -> ok
    catch
        %% Group is a pid, so badarg means that Pid has ended.
        error:badarg -> ok
    end.

%% The leader is excluded only for clarity: its own group leader is the
%% shell's group.
each_process_led_by(Leader, Act) ->
    case [Pid || Pid <- processes(), Pid =/= Leader,
                 process_info(Pid, group_leader) =:= {group_leader, Leader}] of
        [] ->
            ok;
        Led ->
            lists:foreach(Act, Led),
            each_process_led_by(Leader, Act)
    end.
