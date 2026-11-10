%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_runner).
-moduledoc """
The command shell's runner in the session's domain: what erx_shell_eval
asks of the world outside rc's language (its `request()` type), done with
Erlang processes, the session's namespace of files and the command
namespace (docs/design-shell.md, "Commands" and "Pipelines").

State. The runner's state is the working directory, the descriptor
table, the command namespace and the session's facets. The working
directory is the shell's own, never the runtime's, which every process
of the domain shares: every path the runner opens or a command takes is
made absolute against it (erx_cmd:path/2). A descriptor holds a stream
(erx_cmd:stream()): a file's io device, the terminal, a pipe or nothing.

Commands. A name runs the builtin `cd`, which changes the state's
working directory, a job builtin (`jobs`, `fg`, `bg`, `kill`), which
erx_shell:builtin/3 runs against the interactive shell's job table, or
an Erlang command, which runs in a process of its
own with a heap limit, reached by its context alone (erx_cmd). A command
whose declared facets the session lacks fails with `no_facet` before it
starts. Anything else is `not found`: programs, and names that hold `/`,
are Phase 2's (docs/plan.md).

Pieces of the tree. A pipeline's stages, a substitution, a subshell and
a background block each run apart, in a stage process with a heap limit
whose descriptors the runner set before it starts, and give back only
their status. A background block on the interactive shell's own line
is a job of its own (erx_shell:background/2); one inside a piece run
apart, or in a script, which has no job control, runs apart in place.
Stages are joined by pipes (erx_shell_pipe), each end
attached to the stage that holds it, so the reader sees the end of input
when its writer's stage ends and the writer `epipe` when its reader's
stage ends. A substitution reads its body's standard output from a pipe
of which the runner holds the read end. Every pipe and file the runner
opens for a request it closes when the request ends.

Redirections open files through the namespace (`file`, which is
prim_file's namespace on erXos): `>` and `>>` and `<>` as io devices, `<`
and a here document as a pipe a pump fills, so every input of an Erlang
command has the pipe's bounds; `/dev/null` is no stream at all. A file
that cannot be opened is a fault of the unit, as in rc. `<{...}` and
`>{...}` need a path that names a pipe, which the namespace has not got,
and are refused.

Globbing expands a pattern one path component at a time against the
namespace, a component with no pattern character taken as written, as rc
does; a pattern character never matches a leading `.`, and a pattern
that matches nothing stays as written.
""".

-export([new/1, state/1, runner/0, glob/2]).

-include_lib("kernel/include/file.hrl").

-export_type([state/0]).

-type fd() :: erx_shell_lex:fd().
-type state() :: #{cwd := binary(),
                   fds := #{fd() => erx_cmd:stream()},
                   table := erx_shell_namespace:table(),
                   facets := #{atom() => term()},
                   %% The terminal's run_shell, which the interactive shell's commands get.
                   run_shell => fun((erx_console:shell()) -> ok | {error, term()}),
                   %% The interactive shell's job control, and whether this state
                   %% is its line's or a piece's run apart; `none` in a script.
                   job_control => {erx_shell:job_control(), line | apart} | none}.

%% Each command and stage process: a heap limit, counting the binaries it
%% references, past which it alone is killed (docs/design-shell.md, SH2).
-define(MAX_HEAP_WORDS, 8 bsl 20).
-define(MAX_STATUS, 256).

-doc """
The runner and its state for the interactive layer: from `/`, with
standard input at its end and standard output and error the terminal,
whose write function takes a command's bytes unchanged and whose
run_shell its commands get in their context, the command
namespace of the shell's release and the session's facets.
""".
-spec new(erx_shell:terminal()) -> {erx_shell_eval:runner(), state()}.
new(Terminal = #{write := Write}) ->
    {Table, _Problems} = erx_shell_namespace:from_applications([erx_shell]),
    S = state(#{cwd => <<"/">>, fds => #{0 => null, 1 => {tty, Write}, 2 => {tty, Write}},
                table => Table, facets => erx_shell_script:session_facets()}),
    JobControl = case Terminal of
                     #{job_control := Shell} -> {Shell, line};
                     _ -> none
                 end,
    WithShell = maps:merge(S, maps:with([run_shell], Terminal)),
    {runner(), WithShell#{job_control => JobControl}}.

-doc "A runner state from a working directory, descriptors, table and facets.".
-spec state(#{cwd := binary(), fds := #{fd() => erx_cmd:stream()},
              table := erx_shell_namespace:table(), facets := #{atom() => term()}}) -> state().
state(#{cwd := _, fds := _, table := _, facets := _} = State) -> State.

-doc "The runner function to give erx_shell_eval:new/3.".
-spec runner() -> erx_shell_eval:runner().
runner() -> fun guarded/2.

%% The evaluator expects no request to throw: anything that escapes one
%% is a fault of the unit, with a bounded text.
guarded(Request, S) ->
    try request(Request, S)
    catch Class:Reason -> {{fault, status_text(iolist_to_binary(
                                         io_lib:format("~0tp", [{Class, Reason}], [{chars_limit, 256}])))}, S}
    end.

request({run, [Name | Args], Vars}, #{table := Table} = S) ->
    case erx_shell_namespace:lookup(Name, Table) of
        {builtin, cd} -> cd(Args, Vars, S);
        {builtin, _Job} -> {job_builtin(Name, Args, S), S};
        {erlang, Entry} -> {command(Entry, Args, Vars, S), S};
        _NotFoundOrConflict -> {<<"not found">>, diagnose(S, [Name, <<": not found\n">>])}
    end;
request({glob, Pattern}, #{cwd := Cwd} = S) ->
    {glob(Pattern, Cwd), S};
request({write, Fd, Bytes}, S) ->
    {ok, write_fd(Fd, Bytes, S)};
request({redirect, Redirections, Body}, S) ->
    redirect(Redirections, Body, S);
request({capture, Body}, S) ->
    {capture(Body, S), S};
request({pipeline, Stages}, S) ->
    {pipeline(Stages, S), S};
request({subshell, Body}, S) ->
    {Pid, Ref} = start_apart(Body, S, []),
    {await(Pid, Ref), S};
request({background, Body}, S) ->
    Apart = apart(S),
    Run = fun() -> {Status, _} = Body(Apart), Status end,
    InPlace = fun() ->
                      %% Nothing waits for it, so it is not monitored: its end
                      %% leaves no message behind.
                      _ = spawn_opt(fun() -> _ = Run() end, [heap_limit()])
              end,
    case maps:get(job_control, S, none) of
        {Shell, line} ->
            %% The shell refuses once the line is no longer its line, as when
            %% Ctrl-Z stopped it while the request was on its way: the block
            %% then runs in the job the line has become.
            case erx_shell:background(Shell, Run) of
                {ok, _Id} -> ok;
                {error, _Reason} -> InPlace()
            end;
        _ ->
            InPlace()
    end,
    {<<>>, S};
request({pipefd, _Direction, _Body}, S) ->
    {{fault, <<"<{...} and >{...} are not supported">>}, S};
request({whatis, Name}, #{table := Table} = S) ->
    {erx_shell_namespace:whatis(Name, Table), S}.

%%% Builtins

cd(Args, Vars, #{cwd := Cwd} = S) ->
    case Args of
        [] -> cd_to(maps:get(<<"home">>, Vars, []), S);
        [Dir] -> cd_to([erx_cmd:path(Cwd, Dir)], S);
        _ -> {<<"usage">>, diagnose(S, <<"usage: cd [directory]\n">>)}
    end.

cd_to([Dir | _], S) ->
    Path = erx_cmd:path(<<"/">>, Dir),
    case file:read_file_info(Path) of
        {ok, #file_info{type = directory}} -> {<<>>, S#{cwd := Path}};
        {ok, _} -> cant_cd(Dir, enotdir, S);
        {error, Reason} -> cant_cd(Dir, Reason, S)
    end;
cd_to([], S) ->
    {<<"can't cd">>, diagnose(S, <<"cd: no home directory\n">>)}.

cant_cd(Dir, Reason, S) ->
    {<<"can't cd">>, diagnose(S, [<<"cd: ">>, Dir, <<": ">>, erx_cmd:format_error(Reason), $\n])}.

%% A job builtin's status, with its output and diagnostic written.
job_builtin(Name, Args, S) ->
    {Status, Out, Err} = erx_shell:builtin(Name, Args, maps:get(job_control, S, none)),
    [_ = write_fd(Fd, Bytes, S) || {Fd, Bytes} <- [{1, Out}, {2, Err}], iolist_size(Bytes) > 0],
    Status.

%% The state a piece run apart starts from: it may list and signal jobs,
%% but not start or move them.
apart(S = #{job_control := {Shell, _Where}}) -> S#{job_control := {Shell, apart}};
apart(S) -> S.

%%% Erlang commands

command(#{name := Name, module := Module, usage := Usage, needs := Needs},
        Args, Vars, #{cwd := Cwd, facets := Facets} = S) ->
    Ctx0 = #{name => Name, cwd => Cwd, env => Vars,
            stdin => stream(0, S), stdout => stream(1, S), stderr => stream(2, S),
            facets => Facets},
    Ctx = maps:merge(Ctx0, maps:with([run_shell], S)),
    case [Need || Need <- Needs, not is_map_key(Need, Facets)] of
        [] ->
            outcome(isolated(fun() -> invoke(Module, Args, Ctx) end), Usage, Ctx);
        _Missing ->
            safe_say(Ctx, [Name, <<": no_facet\n">>]),
            <<"no_facet">>
    end.

%% What run/2 gave, or how it stopped: a write it could not do, or a crash.
invoke(Module, Args, Ctx) ->
    try Module:run(Args, Ctx) of
        ok -> ok;
        {error, _} = Error -> Error;
        Other -> {crashed, {bad_return, Other}}
    catch
        throw:{erx_cmd_stop, Reason} -> {stopped, Reason};
        Class:Reason -> {crashed, {Class, Reason}}
    end.

%% A command's status and the diagnostic it did not write itself. A write
%% on a pipe with no reader ends it quietly, as SIGPIPE does.
outcome(ok, _Usage, _Ctx) ->
    <<>>;
outcome({error, usage}, Usage, Ctx) ->
    safe_say(Ctx, [<<"usage: ">>, Usage, $\n]),
    <<"usage">>;
outcome({error, {reported, Reason}}, _Usage, _Ctx) ->
    status_text(erx_cmd:format_error(Reason));
outcome({stopped, epipe}, _Usage, _Ctx) ->
    erx_cmd:format_error(epipe);
outcome({Kind, Reason}, _Usage, #{name := Name} = Ctx) when Kind =:= error; Kind =:= stopped ->
    Text = status_text(erx_cmd:format_error(Reason)),
    safe_say(Ctx, [Name, <<": ">>, Text, $\n]),
    Text;
outcome({crashed, Reason}, _Usage, #{name := Name} = Ctx) ->
    Text = status_text(iolist_to_binary(io_lib:format("~0tp", [Reason]))),
    safe_say(Ctx, [Name, <<": crashed: ">>, Text, $\n]),
    Text.

safe_say(Ctx, Bytes) ->
    try erx_cmd:say(Ctx, Bytes) catch throw:{erx_cmd_stop, _} -> ok end.

%% A status is cut at 256 bytes (docs/design-shell.md, "Diagnostics").
status_text(<<Text:?MAX_STATUS/binary, _/binary>>) -> Text;
status_text(Text) -> Text.

%% Runs Fun in a process of its own with the heap limit and gives what it
%% returned, or `{crashed, Reason}` when the process was killed.
isolated(Fun) ->
    {_Pid, Ref} = spawn_opt(fun() -> exit({result, Fun()}) end, [monitor, heap_limit()]),
    receive
        {'DOWN', Ref, process, _, {result, Result}} -> Result;
        {'DOWN', Ref, process, _, Reason} -> {crashed, Reason}
    end.

heap_limit() ->
    {max_heap_size, #{size => ?MAX_HEAP_WORDS, kill => true, error_logger => false,
                      include_shared_binaries => true}}.

%%% Pieces run apart

%% Starts Body in a stage process on a copy of the state, once each pipe
%% end it holds is attached to it, so a stage that ends at once still
%% closes its ends.
start_apart(Body, S, Ends) ->
    {Pid, Ref} = spawn_opt(fun() ->
                                   receive go -> ok end,
                                   {Status, _} = Body(apart(S)),
                                   exit({status, Status})
                           end, [monitor, heap_limit()]),
    [erx_shell_pipe:attach(Pipe, End, Pid) || {End, Pipe} <- Ends],
    Pid ! go,
    {Pid, Ref}.

%% A stage's status, or its crash reason as one.
await(_Pid, Ref) ->
    receive
        {'DOWN', Ref, process, _, {status, Status}} -> Status;
        {'DOWN', Ref, process, _, Reason} ->
            status_text(iolist_to_binary(io_lib:format("~0tp", [Reason])))
    end.

capture(Body, S) ->
    Pipe = erx_shell_pipe:new(),
    erx_shell_pipe:attach(Pipe, read, self()),
    {Pid, Ref} = start_apart(Body, with_stream(1, {pipe, Pipe}, S), [{write, Pipe}]),
    Output = drain(Pipe, []),
    Status = await(Pid, Ref),
    erx_shell_pipe:stop(Pipe),
    {Output, Status}.

drain(Pipe, Acc) ->
    case erx_shell_pipe:get_bytes(Pipe) of
        {bytes, Bytes} -> drain(Pipe, [Acc, Bytes]);
        eof -> iolist_to_binary(Acc)
    end.

%% Stage K reads the pipe that joins it to stage K-1 on that pipe's right
%% descriptor and writes the one to stage K+1 on its left descriptor.
pipeline(Stages, S) ->
    Joins = [{erx_shell_pipe:new(), Pipe} || {Pipe, _Body} <- tl(Stages)],
    Ins = [none | Joins],
    Outs = Joins ++ [none],
    Started = [start_stage(Body, In, Out, S)
               || {{_, Body}, In, Out} <- lists:zip3(Stages, Ins, Outs)],
    Statuses = [await(Pid, Ref) || {Pid, Ref} <- Started],
    [erx_shell_pipe:stop(Pipe) || {Pipe, _} <- Joins],
    Statuses.

start_stage(Body, In, Out, S) ->
    {S1, Ends1} = joined(Out, fun({Left, _Right}) -> Left end, write, {S, []}),
    {S2, Ends2} = joined(In, fun({_Left, Right}) -> Right end, read, {S1, Ends1}),
    start_apart(Body, S2, Ends2).

joined(none, _Side, _End, Acc) ->
    Acc;
joined({Pipe, Join}, Side, End, {S, Ends}) ->
    {with_stream(Side(Join), {pipe, Pipe}, S), [{End, Pipe} | Ends]}.

%%% Descriptors and redirections

stream(Fd, #{fds := Fds}) -> maps:get(Fd, Fds, closed).

with_stream(Fd, Stream, #{fds := Fds} = S) -> S#{fds := Fds#{Fd => Stream}}.

%% The runner's own text, best effort: a stream that cannot take it
%% changes nothing the unit does.
diagnose(S, Bytes) -> write_fd(2, Bytes, S).

write_fd(Fd, Bytes, S) ->
    _ = case stream(Fd, S) of
            {pipe, Pipe} -> erx_shell_pipe:put(Pipe, iolist_to_binary(Bytes));
            {dev, Device} -> file:write(Device, Bytes);
            {tty, Write} -> Write(Bytes);
            _NullOrClosed -> ok
        end,
    S.

%% Runs Body with the redirections in place; the descriptors are given
%% back and what was opened for them closed afterwards, while what Body
%% did to the rest of the state, such as `cd`, stands.
redirect(Redirections, Body, #{fds := Fds} = S) ->
    case open_all(Redirections, S, []) of
        {ok, S1, Opened} ->
            {Result, S2} = try Body(S1) after close_all(Opened) end,
            {Result, S2#{fds := Fds}};
        {error, Message, Opened} ->
            close_all(Opened),
            {{fault, Message}, S}
    end.

open_all([], S, Opened) ->
    {ok, S, Opened};
open_all([Redirection | Rest], S, Opened) ->
    case open_one(Redirection, S) of
        {ok, Fd, Stream} ->
            open_all(Rest, with_stream(Fd, Stream, S), [Stream | Opened]);
        {fds, S1} ->
            open_all(Rest, S1, Opened);
        {error, Message} ->
            {error, Message, Opened}
    end.

open_one({dup, To, From}, #{fds := Fds} = S) ->
    case maps:find(From, Fds) of
        {ok, Stream} -> {fds, S#{fds := Fds#{To => Stream}}};
        error -> {fds, S#{fds := maps:remove(To, Fds)}}
    end;
open_one({close, Fd}, #{fds := Fds} = S) ->
    {fds, S#{fds := maps:remove(Fd, Fds)}};
open_one({here, Fd, Text}, _S) ->
    {ok, Fd, {pipe, erx_shell_pipe:from_binary(Text)}};
open_one({_Kind, Fd, <<"/dev/null">>}, _S) ->
    {ok, Fd, null};
open_one({read, Fd, Target}, #{cwd := Cwd}) ->
    case erx_shell_pipe:from_file(erx_cmd:path(Cwd, Target)) of
        {ok, Pipe} -> {ok, Fd, {pipe, Pipe}};
        {error, Reason} -> cant_open(Target, Reason)
    end;
open_one({Kind, Fd, Target}, #{cwd := Cwd}) ->
    Modes = maps:get(Kind, #{write => [write], append => [append], rdwr => [read, write]}),
    case file:open(erx_cmd:path(Cwd, Target), [binary | Modes]) of
        {ok, Device} -> {ok, Fd, {dev, Device}};
        {error, Reason} -> cant_open(Target, Reason)
    end.

cant_open(Target, Reason) ->
    {error, iolist_to_binary([<<"can't open ">>, Target, <<": ">>, erx_cmd:format_error(Reason)])}.

close_all(Opened) ->
    lists:foreach(fun({dev, Device}) -> _ = file:close(Device);
                     ({pipe, Pipe}) -> erx_shell_pipe:stop(Pipe);
                     (_Null) -> ok
                  end, Opened).

%%% Globbing

-doc """
The paths a pattern matches against the namespace, from the working
directory Cwd, sorted; `[]` when none does.
""".
-spec glob(erx_shell_eval:pattern(), binary()) -> [binary()].
glob(Pattern, Cwd) ->
    Components = components(Pattern),
    Start = case Components of
                [[] | _] -> [{<<"/">>, <<"/">>}];
                _ -> [{<<>>, Cwd}]
            end,
    Rest = case Components of
               [[] | After] -> After;
               _ -> Components
           end,
    Found = lists:foldl(fun expand/2, Start, Rest),
    lists:sort([Shown || {Shown, Path} <- Found, exists(Path)]).

%% The pattern's chunks split at each `/` into path components.
components(Pattern) ->
    {Last, Done} =
        lists:foldl(fun({Kind, Text}, {Current, Acc}) ->
                            [First | More] = binary:split(Text, <<"/">>, [global]),
                            Current1 = add_chunk(Kind, First, Current),
                            lists:foldl(fun(Piece, {Cur, A}) ->
                                                {add_chunk(Kind, Piece, []), [lists:reverse(Cur) | A]}
                                        end, {Current1, Acc}, More)
                    end, {[], []}, Pattern),
    lists:reverse([lists:reverse(Last) | Done]).

add_chunk(_Kind, <<>>, Current) -> Current;
add_chunk(Kind, Text, Current) -> [{Kind, Text} | Current].

%% Each match so far is {what the word shows, the absolute path}.
expand([], Found) ->
    [{<<Shown/binary, "/">>, Path} || {Shown, Path} <- Found];
expand(Component, Found) ->
    case is_pattern(Component) of
        false ->
            Name = erx_shell_eval:pattern_text(Component),
            [{join(Shown, Name), erx_cmd:path(Path, Name)} || {Shown, Path} <- Found];
        true ->
            [{join(Shown, Name), erx_cmd:path(Path, Name)}
             || {Shown, Path} <- Found, Name <- names(Path),
                visible(Name, Component), erx_shell_eval:pattern_match(Name, Component)]
    end.

is_pattern(Component) ->
    lists:any(fun({src, Text}) -> binary:match(Text, [<<"*">>, <<"?">>, <<"[">>]) =/= nomatch;
                 ({lit, _}) -> false
              end, Component).

%% A name that starts with `.` matches only a pattern that starts with one.
visible(<<".", _/binary>>, [{_, <<".", _/binary>>} | _]) -> true;
visible(<<".", _/binary>>, _Component) -> false;
visible(_Name, _Component) -> true.

join(<<>>, Name) -> Name;
join(Shown, Name) ->
    case binary:last(Shown) of
        $/ -> <<Shown/binary, Name/binary>>;
        _ -> <<Shown/binary, "/", Name/binary>>
    end.

names(Path) ->
    case file:list_dir(Path) of
        {ok, Names} -> [name(Name) || Name <- Names];
        {error, _} -> []
    end.

name(Name) when is_binary(Name) -> Name;
name(Name) -> unicode:characters_to_binary(Name).

exists(Path) -> element(1, file:read_link_info(Path)) =:= ok.
