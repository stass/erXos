%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_eval).
-moduledoc """
The command shell's evaluator: rc's language over erx_shell_parse's syntax
tree (docs/design-shell.md, "The language"), as a functional core around one
interface to everything outside the language, the runner.

The evaluator owns what the language means: values, which are lists of
strings; variables, functions and the `if not` flag; concatenation, the
free carets the parser has already made explicit, `$#x`, `$"x` and
subscripts; `if`, `if not`, `for`, `while`, `switch`, `~`, `!`, `&&` and
`||`; `$status`; and the builtins that act on the language alone:
`builtin`, `eval`, `exit`, `shift` and `whatis`, with `exec` and `rfork`
refused, since the shell has no image to replace and no process to fork.

Everything else is the runner's. The evaluator asks it, by the requests of
the `request()` type, to run a command it does not define, to expand a
pattern against the namespace, to write a diagnostic, and to run a piece
of the tree under redirections, as a pipeline's stages, in a
substitution, in the background or as a subshell. Such a piece is handed
over as a `body()`, a closure over the shell's state that the runner may
call in the same process or in a stage process of its own: a body that
runs on a copy of the shell (a stage, a substitution, a background block
or a subshell) gives back only its status, so it cannot change its
parent's variables, as in rc; a body run under redirections gives back
the shell it changed. Every request and reply threads the runner's own
state, and the one effect outside the runner is parsing, which `eval`
and run_source/2 do in a bounded child process
(erx_shell_parse:next_bounded/3); so with a pure runner, such as the
tests' fake, evaluation is a function of the tree and the shell. A
runner that cannot do what it is asked, such as open a redirection's
file, replies `{fault, Message}`, which ends the unit as a fault of the
language does, as rc's Xerror does.

Status is a string, as in rc: empty for success, and true when it holds
only `0` and `|`. A fault of the language itself, such as a null list in
a concatenation, ends the unit: the evaluator writes `rc: ` and the
fault to descriptor 2, sets `$status` to `error` and returns the fault, so
a script stops there and a terminal goes on, as rc does. A fault inside a
body run on a copy ends that body alone, as rc's forked child does.

The tree's depth is bounded by the parser at 256 levels, so walking one
tree recurses no further than that. A function that calls itself recurses
once per call, as rc does, and is bounded only by the heap: the session
runs each evaluator with `max_heap_size` set, so a runaway recursion ends
its own process, never the session (docs/design-shell.md, SH2).
""".

-export([new/3, run_source/2, run_unit/2, parse_fault/2, status/1, var/2, runner_state/1,
         true_status/1, pattern_text/1, pattern_match/2]).

-export_type([shell/0, value/0, runner/0, request/0, body/1, pattern/0,
              redirection/0, outcome/0]).

-record(sh, {vars :: #{binary() => value()},
             fns = #{} :: #{binary() => [erx_shell_parse:cmd()]},
             %% rc's `if not` flag: set by an `if` whose condition was false
             %% or whose body did not finish, cleared when its body ends.
             ifnot = false :: boolean(),
             runner :: runner(),
             rs :: term()}).

-opaque shell() :: #sh{}.
%% A variable's value: rc's list of strings.
-type value() :: [binary()].
%% A word's text before globbing, in chunks: `lit` text came quoted or from
%% a value and is never a pattern; `src` text was written unquoted in the
%% source, where `*`, `?` and `[` are pattern characters, as rc marks them.
-type chunk() :: {lit | src, binary()}.
-type item() :: [chunk()].
%% A word that holds pattern characters, which the runner expands against
%% the namespace with pattern_match/2.
-type pattern() :: item().
%% The runner: answers one request, threading its own state.
-type runner() :: fun((request(), RunnerState :: term()) ->
                          {Reply :: term(), RunnerState :: term()}).
%% A piece of the tree handed to the runner, run on the runner state it is
%% called with.
-type body(T) :: fun((RunnerState :: term()) -> {T, RunnerState :: term()}).
%% The requests and what the runner replies to each:
%% * `{run, Argv, Vars}`: run a command the evaluator does not define, with
%%   the shell's variables for its environment; replies its status.
%% * `{glob, Pattern}`: the names the pattern matches, sorted; `[]` when
%%   none does, which leaves the word as written.
%% * `{write, Fd, Bytes}`: write a diagnostic or a builtin's output;
%%   replies `ok`.
%% * `{redirect, Redirections, Body}`: run Body with the redirections in
%%   place, undone after it; replies what Body returns.
%% * `{capture, Body}`: run Body with its standard output collected;
%%   replies `{Output, Status}`.
%% * `{pipeline, Stages}`: run each stage, the first with `none`, each
%%   other with the descriptors its pipe joins; replies their statuses.
%% * `{subshell, Body}`: run Body apart and reply its status.
%% * `{background, Body}`: start Body apart and reply the process id
%%   `$apid` names, `<<>>` when it started no program.
%% * `{pipefd, read | write, Body}`: run Body on a pipe; replies the path
%%   that names the pipe's other end.
%% * `{whatis, Name}`: what Name runs outside the language;
%%   `{found, Line}` or `not_found`.
%% Any request may instead be answered `{fault, Message}`, which ends the
%% unit with that message as a fault of the language.
-type request() ::
        {run, [binary(), ...], #{binary() => value()}}
      | {glob, pattern()}
      | {write, 1 | 2, iodata()}
      | {redirect, [redirection(), ...], body(term())}
      | {capture, body(binary())}
      | {pipeline, [{none | erx_shell_parse:pipe(), body(binary())}, ...]}
      | {subshell | background, body(binary())}
      | {pipefd, read | write, body(binary())}
      | {whatis, binary()}.
%% A redirection with its target expanded.
-type redirection() ::
        {write | append | read | rdwr, erx_shell_lex:fd(), Path :: binary()}
      | {here, erx_shell_lex:fd(), Text :: binary()}
      | {dup, To :: erx_shell_lex:fd(), From :: erx_shell_lex:fd()}
      | {close, erx_shell_lex:fd()}.
%% How a unit or a source ended: normally, by `exit`, at a unit that does
%% not parse, which ends a script with `$status` set as rc's does, or by a
%% language fault, which ends it with no status, as rc's ends. Message is
%% what was written to descriptor 2 after `rc: `.
-type outcome() :: {ok, shell()} | {exit, shell()}
                 | {syntax_error, Message :: binary(), shell()}
                 | {error, Message :: binary(), shell()}.

%% A language fault and an `exit` unwind to the unit as throws carrying the
%% shell as it stood.
-define(FAULT(Message, Sh), throw({rc_fault, Message, Sh})).

-define(LOCAL_NAME, <<"variable name must be singleton\n">>).
-define(GLOB_CHARS, [<<"*">>, <<"?">>, <<"[">>]).

%% The builtins whatis names; `builtin` is not one, as in rc.
-define(BUILTINS, [<<"eval">>, <<"exec">>, <<"exit">>,
                   <<"rfork">>, <<"shift">>, <<"whatis">>]).

%%% The shell and its state

-doc """
A shell with the given variables, over a runner and the runner's initial
state. `$ifs` defaults to space, tab and newline, and `$status` to empty.
""".
-spec new(#{binary() => value()}, runner(), term()) -> shell().
new(Vars, Runner, RunnerState) when is_map(Vars), is_function(Runner, 2) ->
    Defaults = #{<<"ifs">> => [<<" \t\n">>], <<"status">> => [<<>>]},
    #sh{vars = maps:merge(Defaults, Vars), runner = Runner, rs = RunnerState}.

-doc "The shell's `$status`, its first word or empty, as rc reads it.".
-spec status(shell()) -> binary().
status(#sh{vars = Vars}) ->
    case maps:get(<<"status">>, Vars, []) of
        [Status | _] -> Status;
        [] -> <<>>
    end.

-doc "A variable's value; `[]` when it is unset.".
-spec var(binary(), shell()) -> value().
var(Name, #sh{vars = Vars}) -> maps:get(Name, Vars, []).

-doc "The runner's state as the shell holds it.".
-spec runner_state(shell()) -> term().
runner_state(#sh{rs = RunnerState}) -> RunnerState.

-doc "Whether a status counts as success: it holds only `0` and `|`.".
-spec true_status(binary()) -> boolean().
true_status(Status) ->
    lists:all(fun(C) -> C =:= $0 orelse C =:= $| end, binary_to_list(Status)).

%%% Sources and units

-doc """
Runs a whole source, a script or a `-c` string, one unit at a time,
parsing each in a bounded child (erx_shell_parse:next_bounded/3). It stops
at `exit`, at a language fault, and at a unit that does not parse, whose
diagnostic it writes to descriptor 2 and whose message alone it sets as
`$status`, as rc does. Whether an `if not` may start a unit passes from
each unit to the next, starting without it, as rc's parser carries it
(erx_shell_parse:if_not_may_follow/2).
""".
-spec run_source(binary(), shell()) -> outcome().
run_source(Source, Sh) ->
    run_source(Source, 0, false, Sh).

%% Lines is how many lines of the source came before Source, so that a
%% diagnostic names the source's own line.
run_source(Source, Lines, IfBefore, Sh) ->
    case erx_shell_parse:next_bounded(Source, final, IfBefore) of
        eof ->
            {ok, Sh};
        {ok, Program, Rest} ->
            case run_unit(Program, Sh) of
                {ok, Sh1} ->
                    Lines1 = Lines + lines_used(Source, Rest),
                    IfAfter = erx_shell_parse:if_not_may_follow(Program, IfBefore),
                    run_source(Rest, Lines1, IfAfter, Sh1);
                Ended ->
                    Ended
            end;
        {incomplete, Pos, Message} ->
            parse_fault(after_lines({incomplete, Pos, Message}, Lines), Sh);
        {error, Diagnostic, _Rest} ->
            parse_fault(after_lines(Diagnostic, Lines), Sh)
    end.

%% The lines of Source a unit took, Rest being what follows it.
lines_used(Source, Rest) ->
    Used = binary_part(Source, 0, byte_size(Source) - byte_size(Rest)),
    length(binary:matches(Used, <<"\n">>)).

%% A diagnostic of a unit with its line counted from the start of the
%% source, Lines lines before the unit.
after_lines({too_long, _} = Diagnostic, _Lines) -> Diagnostic;
after_lines({too_deep, {Line, Column}}, Lines) ->
    {too_deep, {Line + Lines, Column}};
after_lines({Kind, {Line, Column}, Message}, Lines) ->
    {Kind, {Line + Lines, Column}, Message}.

-doc """
Runs one parsed unit. A language fault writes `rc: ` and the fault to
descriptor 2, sets `$status` to `error` and is returned, as is `exit`.
""".
-spec run_unit(erx_shell_parse:program(), shell()) -> outcome().
run_unit(Program, Sh) ->
    try seq(Program, Sh) of
        Sh1 -> {ok, Sh1}
    catch
        throw:{rc_exit, Sh1} -> {exit, Sh1};
        throw:{rc_fault, Message, Sh1} -> fault_outcome(Message, Sh1)
    end.

-doc """
Reports a unit that does not parse, Diagnostic being what the parser said
of it, as run_source/2 reports one: `rc: ` and the diagnostic written to
descriptor 2, and `$status` set to its message alone. Nothing of the unit
runs.
""".
-spec parse_fault(erx_shell_parse:diagnostic(), shell()) -> outcome().
parse_fault(Diagnostic, Sh) ->
    Printed = erx_shell_parse:format_error(Diagnostic),
    {syntax_error, Printed, syntax_status(Diagnostic, Printed, Sh)}.

%% The shell after a unit that does not parse: its diagnostic Printed written
%% to descriptor 2 and `$status` its message alone, as rc sets it.
syntax_status(Diagnostic, Printed, Sh) ->
    Sh1 = say(2, [<<"rc: ">>, Printed, $\n], Sh),
    set_status(erx_shell_parse:message(Diagnostic), Sh1).

fault_outcome(Message, Sh) ->
    Sh1 = say(2, [<<"rc: ">>, Message, $\n], Sh),
    {error, Message, set_status(<<"error">>, Sh1)}.

%%% Commands

seq(Cmds, Sh) -> lists:foldl(fun cmd/2, Sh, Cmds).

body(empty, Sh) -> Sh;
body(Cmd, Sh) -> cmd(Cmd, Sh).

cmd({simple, Words, []}, Sh) ->
    simple(Words, Sh);
cmd({simple, Words, Redirs}, Sh) ->
    with_redirs(Redirs, fun(Sh1) -> simple(Words, Sh1) end, Sh);
cmd({block, Cmds, []}, Sh) ->
    seq(Cmds, Sh);
cmd({block, Cmds, Redirs}, Sh) ->
    with_redirs(Redirs, fun(Sh1) -> seq(Cmds, Sh1) end, Sh);
cmd({redirect, Redir, Body}, Sh) ->
    with_redirs([Redir], fun(Sh1) -> body(Body, Sh1) end, Sh);
cmd({background, Cmd}, Sh) ->
    {Apid, Sh1} = ask({background, apart([Cmd], Sh)}, Sh),
    set_var(<<"apid">>, [Apid], Sh1);
cmd({subshell, Body}, Sh) ->
    {Status, Sh1} = ask({subshell, apart([Body || Body =/= empty], Sh)}, Sh),
    set_status(Status, Sh1);
cmd({pipeline, First, Rest}, Sh) ->
    Stages = [{none, apart([First], Sh)}
              | [{Pipe, apart([Cmd], Sh)} || {Pipe, Cmd} <- Rest]],
    {Statuses, Sh1} = ask({pipeline, Stages}, Sh),
    set_status(iolist_to_binary(lists:join($|, Statuses)), Sh1);
cmd({and_or, First, Rest}, Sh) ->
    lists:foldl(fun and_or/2, cmd(First, Sh), Rest);
cmd({'not', Body}, Sh) ->
    Sh1 = body(Body, Sh),
    set_status(case true_status(status(Sh1)) of
                   true -> <<"false">>;
                   false -> <<>>
               end, Sh1);
cmd({if_not, Body}, #sh{ifnot = true} = Sh) ->
    body(Body, Sh);
cmd({if_not, _Body}, Sh) ->
    Sh;
cmd({'if', Condition, Body}, Sh) ->
    Sh1 = (seq(Condition, Sh))#sh{ifnot = true},
    case true_status(status(Sh1)) of
        true -> (body(Body, Sh1))#sh{ifnot = false};
        false -> Sh1
    end;
cmd({while, Condition, Body}, Sh) ->
    while(Condition, Body, Sh);
cmd({for, Var, List, Body}, Sh) ->
    {Values, Sh1} = case List of
                        {in, Words} -> args(Words, Sh);
                        args -> {var(<<"*">>, Sh), Sh}
                    end,
    {Name, Sh2} = name(Var, ?LOCAL_NAME, Sh1),
    with_local(Name, var(Name, Sh2),
               fun(Sh3) -> for(Name, Values, Body, Sh3) end, Sh2);
cmd({switch, Subject, Arms}, Sh) ->
    {Text, Sh1} = joined(Subject, Sh),
    switch(Text, Arms, Sh1);
cmd({match, Subject, Patterns}, Sh) ->
    {Items, Sh1} = items(Patterns, Sh),
    {Text, Sh2} = joined(Subject, Sh1),
    set_status(case lists:any(fun(Item) -> matches(Text, Item) end, Items) of
                   true -> <<>>;
                   false -> <<"no match">>
               end, Sh2);
cmd({assign, Var, Value}, Sh) ->
    {Values, Sh1} = args([Value], Sh),
    {Name, Sh2} = name(Var, Sh1),
    set_var(Name, Values, Sh2);
cmd({local, Var, Value, Cmd}, Sh) ->
    {Values, Sh1} = args([Value], Sh),
    {Name, Sh2} = name(Var, ?LOCAL_NAME, Sh1),
    with_local(Name, Values, fun(Sh3) -> cmd(Cmd, Sh3) end, Sh2);
cmd({fn, Names, Body}, Sh) ->
    {Texts, Sh1} = texts(Names, Sh),
    Sh1#sh{fns = maps:merge(Sh1#sh.fns, maps:from_keys(Texts, Body))};
cmd({fn_delete, Names}, Sh) ->
    {Texts, Sh1} = texts(Names, Sh),
    Sh1#sh{fns = maps:without(Texts, Sh1#sh.fns)}.

and_or({'and', Cmd}, Sh) -> run_if(true, Cmd, Sh);
and_or({'or', Cmd}, Sh) -> run_if(false, Cmd, Sh).

run_if(Wanted, Cmd, Sh) ->
    case true_status(status(Sh)) of
        Wanted -> cmd(Cmd, Sh);
        _ -> Sh
    end.

%% An empty condition is true, as rc's `while()` is.
while(Condition, Body, Sh) ->
    Sh1 = case Condition of
              [] -> set_status(<<>>, Sh);
              _ -> seq(Condition, Sh)
          end,
    case true_status(status(Sh1)) of
        true -> while(Condition, Body, body(Body, Sh1));
        false -> Sh1
    end.

for(_Name, [], _Body, Sh) ->
    Sh;
for(Name, [Value | Values], Body, Sh) ->
    for(Name, Values, Body, body(Body, set_var(Name, [Value], Sh))).

%% The first arm one of whose patterns matches runs; patterns of later
%% arms are not expanded, as in rc.
switch(_Text, [], Sh) ->
    Sh;
switch(Text, [{'case', Patterns, Cmds} | Arms], Sh) ->
    {Items, Sh1} = items(Patterns, Sh),
    case lists:any(fun(Item) -> matches(Text, Item) end, Items) of
        true -> seq(Cmds, Sh1);
        false -> switch(Text, Arms, Sh1)
    end.

%%% Simple commands: functions, the language's builtins, and the runner

simple(Words, Sh) ->
    case args(Words, Sh) of
        {[], Sh1} -> ?FAULT(<<"empty argument list">>, Sh1);
        {[Name | Args], Sh1} ->
            case maps:find(Name, Sh1#sh.fns) of
                {ok, Body} -> call(Body, Args, Sh1);
                error -> builtin(Name, Args, Sh1)
            end
    end.

call(Body, Args, Sh) ->
    with_local(<<"*">>, Args, fun(Sh1) -> seq(Body, Sh1) end, Sh).

builtin(<<"builtin">>, [], Sh) ->
    Sh1 = say(2, <<"builtin: empty argument list\n">>, Sh),
    set_status(<<"empty arg list">>, Sh1);
builtin(<<"builtin">>, [Name | Args], Sh) ->
    builtin(Name, Args, Sh);
builtin(<<"eval">>, [], Sh) ->
    ?FAULT(<<"Usage: eval cmd ...">>, Sh);
builtin(<<"eval">>, Args, Sh) ->
    eval([lists:join($\s, Args), $\n], Sh);
builtin(<<"exit">>, [], Sh) ->
    throw({rc_exit, Sh});
builtin(<<"exit">>, [Status], Sh) ->
    throw({rc_exit, set_status(Status, Sh)});
builtin(<<"exit">>, [Status | _], Sh) ->
    Sh1 = say(2, <<"Usage: exit [status]\nExiting anyway\n">>, Sh),
    throw({rc_exit, set_status(Status, Sh1)});
builtin(<<"shift">>, [], Sh) ->
    shift(1, Sh);
builtin(<<"shift">>, [Count], Sh) ->
    shift(leading_number(Count), Sh);
builtin(<<"shift">>, _, Sh) ->
    set_status(<<"shift usage">>, say(2, <<"Usage: shift [n]\n">>, Sh));
builtin(<<"whatis">>, [], Sh) ->
    ?FAULT(<<"Usage: whatis name ...">>, Sh);
builtin(<<"whatis">>, Names, Sh) ->
    lists:foldl(fun whatis/2, set_status(<<>>, Sh), Names);
builtin(Name, _Args, Sh) when Name =:= <<"exec">>; Name =:= <<"rfork">> ->
    Sh1 = say(2, [Name, <<": not supported by this shell\n">>], Sh),
    set_status(<<"not supported">>, Sh1);
builtin(Name, Args, Sh) ->
    Argv = [Name | Args],
    case lists:any(fun holds_nul/1, Argv) of
        true ->
            ?FAULT(<<"an argument holds a NUL byte">>, Sh);
        false ->
            {Status, Sh1} = ask({run, Argv, Sh#sh.vars}, Sh),
            set_status(Status, Sh1)
    end.

%% A program takes its arguments and a file its path as C strings, which
%% end at a NUL: one inside a word would run something other than what the
%% language matched, so it is a fault.
holds_nul(Text) -> binary:match(Text, <<0>>) =/= nomatch.

%% `eval` runs its text as units of the current shell, a source of its own
%% for where `if not` may stand; a fault in it is the unit's fault, and text
%% that does not parse sets `$status` and ends it.
eval(Text, Sh) ->
    eval(iolist_to_binary(Text), 0, false, Sh).

eval(Text, Lines, IfBefore, Sh) ->
    case erx_shell_parse:next_bounded(Text, final, IfBefore) of
        eof ->
            Sh;
        {ok, Program, Rest} ->
            IfAfter = erx_shell_parse:if_not_may_follow(Program, IfBefore),
            eval(Rest, Lines + lines_used(Text, Rest), IfAfter, seq(Program, Sh));
        {incomplete, Pos, Message} ->
            eval_fault(after_lines({incomplete, Pos, Message}, Lines), Sh);
        {error, Diagnostic, _Rest} ->
            eval_fault(after_lines(Diagnostic, Lines), Sh)
    end.

eval_fault(Diagnostic, Sh) ->
    syntax_status(Diagnostic, erx_shell_parse:format_error(Diagnostic), Sh).

shift(Count, Sh) ->
    Star = var(<<"*">>, Sh),
    Kept = lists:nthtail(min(Count, length(Star)), Star),
    set_status(<<>>, set_var(<<"*">>, Kept, Sh)).

%% rc's whatis: a set variable as an assignment, then a function, a builtin
%% or what the runner runs for the name. A function's body is not printed:
%% the tree keeps no source text and the evaluator has no printer of trees
%% (TODO.md), so whatis says so instead of printing something else.
whatis(Name, Sh) ->
    Value = var(Name, Sh),
    Sh1 = case Value of
              [] -> Sh;
              _ -> say(1, [Name, $=, quote_value(Value), $\n], Sh)
          end,
    case {maps:is_key(Name, Sh1#sh.fns), lists:member(Name, ?BUILTINS)} of
        {true, _} ->
            Sh2 = say(2, [Name, <<": a function; its body is not shown\n">>],
                      Sh1),
            set_status(<<"not supported">>, Sh2);
        {false, true} ->
            say(1, [<<"builtin ">>, Name, $\n], Sh1);
        {false, false} ->
            case ask({whatis, Name}, Sh1) of
                {{found, Line}, Sh2} ->
                    say(1, [Line, $\n], Sh2);
                {not_found, Sh2} when Value =/= [] ->
                    Sh2;
                {not_found, Sh2} ->
                    Sh3 = say(2, [Name, <<": not found\n">>], Sh2),
                    set_status(<<"not found">>, Sh3)
            end
    end.

%% A value as whatis prints it: one word alone, more in parentheses, each
%% quoted as rc's pwrd quotes, when empty or holding a character that
%% ends a word in rc's lexer (lex.c's wordchr).
quote_value([Word]) -> quote(Word);
quote_value(Words) -> [$(, lists:join($\s, [quote(W) || W <- Words]), $)].

quote(<<>>) ->
    <<"''">>;
quote(Word) ->
    case lists:any(fun needs_quote/1, binary_to_list(Word)) of
        true -> [$', binary:replace(Word, <<"'">>, <<"''">>, [global]), $'];
        false -> Word
    end.

needs_quote(C) -> lists:member(C, "\n \t#;&|^$=`'{}()<>").

%%% Scopes: redirections, copies of the shell, local variables

%% Runs Fun on the shell under the redirections. The body the runner calls
%% never throws: a fault or an exit inside it comes back as a value and is
%% raised again once the runner has undone the redirections.
with_redirs(Redirs, Fun, Sh) ->
    {Expanded, Sh1} = redirections(Redirs, Sh),
    Body = fun(RunnerState) ->
                   Inner = Sh1#sh{rs = RunnerState},
                   Result = try {ok, Fun(Inner)}
                            catch
                                throw:{rc_exit, _} = Exit -> {unwind, Exit};
                                throw:{rc_fault, _, _} = Fault ->
                                    {unwind, Fault}
                            end,
                   {Result, runner_state_of(Result)}
           end,
    case ask({redirect, Expanded, Body}, Sh1) of
        %% Inner is the shell the body left; Outer holds the runner's state
        %% after the redirections were undone.
        {{ok, Inner}, Outer} -> Inner#sh{rs = Outer#sh.rs};
        {{unwind, Unwind}, Outer} -> throw(with_runner_state(Unwind, Outer#sh.rs))
    end.

runner_state_of({ok, #sh{rs = RunnerState}}) -> RunnerState;
runner_state_of({unwind, {rc_exit, #sh{rs = RunnerState}}}) -> RunnerState;
runner_state_of({unwind, {rc_fault, _, #sh{rs = RunnerState}}}) ->
    RunnerState.

with_runner_state({rc_exit, Sh}, RunnerState) ->
    {rc_exit, Sh#sh{rs = RunnerState}};
with_runner_state({rc_fault, Message, Sh}, RunnerState) ->
    {rc_fault, Message, Sh#sh{rs = RunnerState}}.

%% A body that runs the commands on a copy of the shell and gives back only
%% their status, as rc's forked child does: a fault ends the copy with its
%% diagnostic and the status `error`, and `exit` ends it with its status.
apart(Cmds, Sh) ->
    fun(RunnerState) ->
            Ended = outcome_shell(run_unit(Cmds, Sh#sh{rs = RunnerState})),
            {status(Ended), Ended#sh.rs}
    end.

outcome_shell({ok, Sh}) -> Sh;
outcome_shell({exit, Sh}) -> Sh;
outcome_shell({error, _Message, Sh}) -> Sh.

%% Runs Fun with Name bound to Value and gives the variable back its outer
%% value afterwards, on a fault or an exit too, as rc's local variables
%% of `x=v cmd`, `for` and a function's `$*` are.
with_local(Name, Value, Fun, Sh) ->
    Outer = maps:find(Name, Sh#sh.vars),
    try Fun(set_var(Name, Value, Sh)) of
        Sh1 -> restore(Name, Outer, Sh1)
    catch
        throw:{rc_exit, Sh1} ->
            throw({rc_exit, restore(Name, Outer, Sh1)});
        throw:{rc_fault, Message, Sh1} ->
            throw({rc_fault, Message, restore(Name, Outer, Sh1)})
    end.

restore(Name, {ok, Value}, Sh) -> set_var(Name, Value, Sh);
restore(Name, error, Sh) -> Sh#sh{vars = maps:remove(Name, Sh#sh.vars)}.

%%% Effects through the runner, and the shell's variables

ask(Request, #sh{runner = Runner, rs = RunnerState} = Sh) ->
    case Runner(Request, RunnerState) of
        {{fault, Message}, RunnerState1} when is_binary(Message) ->
            ?FAULT(Message, Sh#sh{rs = RunnerState1});
        {Reply, RunnerState1} ->
            {Reply, Sh#sh{rs = RunnerState1}}
    end.

%% The shell's own text, written as rc's pfmt writes it, best effort: a
%% runner that cannot write it changes nothing the unit does, and no fault
%% is raised outside run_unit/2's catch.
say(Fd, Text, #sh{runner = Runner, rs = RunnerState} = Sh) ->
    {_Reply, RunnerState1} = Runner({write, Fd, Text}, RunnerState),
    Sh#sh{rs = RunnerState1}.

set_var(Name, Value, Sh) -> Sh#sh{vars = (Sh#sh.vars)#{Name => Value}}.

set_status(Status, Sh) -> set_var(<<"status">>, [Status], Sh).

%%% Words

%% A command's or an assignment's words: expanded, then each pattern
%% globbed, as rc globs arguments, assigned values, `for` lists,
%% redirection targets and a substitution's split word.
args(Words, Sh) ->
    {Items, Sh1} = items(Words, Sh),
    {Globbed, Sh2} = lists:mapfoldl(fun glob/2, Sh1, Items),
    {lists:append(Globbed), Sh2}.

glob(Item, Sh) ->
    case is_pattern(Item) of
        false ->
            {[text(Item)], Sh};
        true ->
            case ask({glob, Item}, Sh) of
                {[], Sh1} -> {[text(Item)], Sh1};
                {Names, Sh1} -> {Names, Sh1}
            end
    end.

%% Words expanded to their texts without globbing: a variable's name, a
%% subscript, a function's name.
texts(Words, Sh) ->
    {Items, Sh1} = items(Words, Sh),
    {[text(Item) || Item <- Items], Sh1}.

%% A word that must expand to one text: a variable's name.
name(Word, Sh) -> name(Word, <<"variable name not singleton!">>, Sh).

%% rc words the fault apart for a local variable, `x=v cmd` and `for`'s.
name(Word, Fault, Sh) ->
    case texts([Word], Sh) of
        {[Name], Sh1} -> {Name, Sh1};
        {_, Sh1} -> ?FAULT(Fault, Sh1)
    end.

%% A subject of `~` or `switch`: its texts joined by spaces, as rc's
%% list2str joins them.
joined(Word, Sh) ->
    {Texts, Sh1} = texts([Word], Sh),
    {iolist_to_binary(lists:join($\s, Texts)), Sh1}.

%% Words are expanded right to left, as rc's code.c emits them, so the
%% rightmost word's substitution sets $status and its fault comes first.
items(Words, Sh) ->
    {Lists, Sh1} = lists:mapfoldr(fun word/2, Sh, Words),
    {lists:append(Lists), Sh1}.

%% One chunk, the common case, is its own text, shared rather than copied.
text([{_, Text}]) -> Text;
text(Item) -> iolist_to_binary([Text || {_, Text} <- Item]).

lits(Values) -> [[{lit, Value}] || Value <- Values].

-spec word(erx_shell_parse:word(), #sh{}) -> {[item()], #sh{}}.
word({word, Text}, Sh) ->
    {[[{src, Text}]], Sh};
word({quoted, Text}, Sh) ->
    {[[{lit, Text}]], Sh};
word({list, Words}, Sh) ->
    items(Words, Sh);
%% As rc's code.c: every part is evaluated, right to left, and then they
%% are joined left to right, `(a^b)^c`.
word({concat, Parts}, Sh) ->
    {[First | Rest], Sh1} = lists:mapfoldr(fun word/2, Sh, Parts),
    {lists:foldl(fun(Right, Left) -> concat(Left, Right, Sh1) end, First, Rest), Sh1};
word({var, Name}, Sh) ->
    {Text, Sh1} = name(Name, Sh),
    {lits(dollar(Text, Sh1)), Sh1};
word({count, Name}, Sh) ->
    {Text, Sh1} = name(Name, Sh),
    Count = case positional(Text) of
                {ok, _} -> length(dollar(Text, Sh1));
                error -> length(var(Text, Sh1))
            end,
    {lits([integer_to_binary(Count)]), Sh1};
word({flat, Name}, Sh) ->
    {Text, Sh1} = name(Name, Sh),
    {lits([iolist_to_binary(lists:join($\s, var(Text, Sh1)))]), Sh1};
word({var_sub, Name, Index}, Sh) ->
    {Text, Sh1} = name(Name, Sh),
    {Subscripts, Sh2} = texts(Index, Sh1),
    Value = var(Text, Sh2),
    {lits(lists:flatmap(fun(S) -> subscript(S, Value) end, Subscripts)),
     Sh2};
word({backquote, Split, Cmds}, Sh) ->
    {Separators, Sh1} = case Split of
                            ifs -> {first_word(var(<<"ifs">>, Sh)), Sh};
                            Word -> separators(Word, Sh)
                        end,
    {{Output, Status}, Sh2} = ask({capture, apart(Cmds, Sh1)}, Sh1),
    {lits(split(Output, Separators)), set_status(Status, Sh2)};
word({pipefd, Direction, Cmds}, Sh) ->
    {Path, Sh1} = ask({pipefd, Direction, apart(Cmds, Sh)}, Sh),
    {lits([Path]), Sh1}.

%% rc splits on the characters of the first word of $ifs or of the split
%% word.
separators(Word, Sh) ->
    {Texts, Sh1} = args([Word], Sh),
    {first_word(Texts), Sh1}.

first_word([Word | _]) -> Word;
first_word([]) -> <<>>.

%% `$x`, and `$1`, `$2`... for the words of `$*`; `$0` is a variable.
dollar(Text, Sh) ->
    case positional(Text) of
        {ok, N} ->
            Star = var(<<"*">>, Sh),
            case N =< length(Star) of
                true -> [lists:nth(N, Star)];
                false -> []
            end;
        error ->
            var(Text, Sh)
    end.

%% A name of digits alone with a value above zero names a word of `$*`.
positional(<<>>) ->
    error;
positional(Text) ->
    case lists:all(fun is_digit/1, binary_to_list(Text)) of
        true -> nonzero(binary_to_integer(Text));
        false -> error
    end.

nonzero(0) -> error;
nonzero(N) -> {ok, N}.

is_digit(C) -> C >= $0 andalso C =< $9.

%% The number a text starts with, as C's atoi reads digits; 0 for none.
leading_number(Text) ->
    case lists:takewhile(fun is_digit/1, binary_to_list(Text)) of
        [] -> 0;
        Digits -> list_to_integer(Digits)
    end.

%% rc's subscript: `n`, `n-m` or `n-`, counted from 1; one out of range
%% gives nothing, and a range past the end stops at the end.
subscript(Text, Value) ->
    Length = length(Value),
    Digits = length(lists:takewhile(fun is_digit/1, binary_to_list(Text))),
    From = leading_number(Text),
    <<_:Digits/binary, After/binary>> = Text,
    Following = case After of
                    <<"-">> -> Length - From;
                    <<"-", To/binary>> -> leading_number(To) - From;
                    _ -> 0
                end,
    case From < 1 orelse From > Length orelse Following < 0 of
        true -> [];
        false -> lists:sublist(Value, From, min(Following, Length - From) + 1)
    end.

%% rc's `^`: two lists of one length join word by word, a single word
%% joins every word of the other list, and two empty lists give an empty
%% one; anything else is a fault.
concat([], [], _Sh) -> [];
concat([], _, Sh) -> ?FAULT(<<"null list in concatenation">>, Sh);
concat(_, [], Sh) -> ?FAULT(<<"null list in concatenation">>, Sh);
concat([Left], Rights, _Sh) -> [Left ++ Right || Right <- Rights];
concat(Lefts, [Right], _Sh) -> [Left ++ Right || Left <- Lefts];
concat(Lefts, Rights, _Sh) when length(Lefts) =:= length(Rights) ->
    lists:zipwith(fun erlang:'++'/2, Lefts, Rights);
concat(_, _, Sh) ->
    ?FAULT(<<"mismatched list lengths in concatenation">>, Sh).

%% A substitution's output split at any of the separator characters, with
%% empty fields dropped.
split(Output, <<>>) ->
    [Output || Output =/= <<>>];
split(Output, Separators) ->
    Patterns = [case C of
                    {byte, B} -> <<B>>;
                    _ -> <<C/utf8>>
                end || C <- characters(Separators)],
    binary:split(Output, Patterns, [global, trim_all]).

%%% Redirections

redirections(Redirs, Sh) -> lists:mapfoldl(fun redirection/2, Sh, Redirs).

redirection({Kind, Fd, Target}, Sh)
  when Kind =:= write; Kind =:= append; Kind =:= read; Kind =:= rdwr ->
    Operator = maps:get(Kind, #{write => <<">">>, append => <<">>">>,
                                read => <<"<">>, rdwr => <<"<>">>}),
    case args([Target], Sh) of
        {[Path], Sh1} ->
            case holds_nul(Path) of
                true -> ?FAULT(<<Operator/binary, " file name holds a NUL byte">>, Sh1);
                false -> {{Kind, Fd, Path}, Sh1}
            end;
        {[], Sh1} -> ?FAULT(<<Operator/binary, " requires file\n">>, Sh1);
        {_, Sh1} -> ?FAULT(<<Operator/binary, " requires singleton\n">>, Sh1)
    end;
redirection({here, Fd, {literal, Text}}, Sh) ->
    {{here, Fd, Text}, Sh};
redirection({here, Fd, {template, Parts}}, Sh) ->
    Text = [case Part of
                {var, Name} -> lists:join($\s, dollar(Name, Sh));
                Literal -> Literal
            end || Part <- Parts],
    {{here, Fd, iolist_to_binary(Text)}, Sh};
redirection({dup, _, _} = Dup, Sh) ->
    {Dup, Sh};
redirection({close, _} = Close, Sh) ->
    {Close, Sh}.

%%% Patterns

-doc "A pattern's text as written, its pattern characters taken literally.".
-spec pattern_text(pattern()) -> binary().
pattern_text(Pattern) -> text(Pattern).

-doc """
Whether a name matches a pattern, as rc matches: `*` any text, `?` any
one character, `[...]` one character of a class of characters and ranges,
`[~...]` one character outside it; only characters written unquoted in
the source are pattern characters.
""".
-spec pattern_match(binary(), pattern()) -> boolean().
pattern_match(Name, Pattern) -> matches(Name, Pattern).

is_pattern(Item) ->
    lists:any(fun({src, Text}) -> binary:match(Text, ?GLOB_CHARS) =/= nomatch;
                 ({lit, _}) -> false
              end, Item).

matches(Text, Item) -> erx_shell_glob:match(Text, Item).

%% Characters of a text: code points where it is UTF-8, bytes elsewhere.
characters(<<>>) -> [];
characters(<<C/utf8, Rest/binary>>) -> [C | characters(Rest)];
characters(<<B, Rest/binary>>) -> [{byte, B} | characters(Rest)].
