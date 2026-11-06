%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_fake_runner).
-moduledoc """
A pure runner for erx_shell_eval's tests and its differential corpus: the
world outside rc's language reduced to what a script of the language alone
needs, with no process, file or pipe.

It knows three commands, `echo` (with `-n`), `true` and `false`, as the
host's `/bin` has them for plan9port's rc, and finds nothing else. Output
goes to named sinks: descriptor 1 to `stdout` and 2 to `stderr` until a
redirection moves them; `/dev/null` and a closed descriptor drop what is
written. A substitution collects descriptor 1 into a sink of its own. A
pipeline runs its stages in order, every stage but the last writing
nowhere, since none of its commands reads its input. Globbing finds
nothing, as in the oracle's empty working directory. A request it cannot
serve, such as a redirection to a file, fails the test with an error.

`main/1` runs one script for the corpus test and writes its output, its
errors and its final status into a directory.
""".

-export([new/0, runner/0, stdout/1, stderr/1, run/1, main/1]).

-type state() :: #{fds := #{non_neg_integer() => sink()},
                   sinks := #{sink() => binary()},
                   next := non_neg_integer()}.
-type sink() :: stdout | stderr | {capture, non_neg_integer()}.

-doc "A runner state whose descriptors 1 and 2 are stdout and stderr.".
-spec new() -> state().
new() ->
    #{fds => #{1 => stdout, 2 => stderr},
      sinks => #{stdout => <<>>, stderr => <<>>}, next => 0}.

-doc "The runner function to give erx_shell_eval:new/3.".
-spec runner() -> erx_shell_eval:runner().
runner() -> fun request/2.

-doc "What reached stdout.".
-spec stdout(state()) -> binary().
stdout(#{sinks := #{stdout := Out}}) -> Out.

-doc "What reached stderr.".
-spec stderr(state()) -> binary().
stderr(#{sinks := #{stderr := Err}}) -> Err.

-doc """
Runs a source in a shell set up as the oracle runs its scripts (`$0`,
`$path`, `$home`, an empty `$*`), and gives how it ended with the output
and errors it wrote.
""".
-spec run(binary()) -> {erx_shell_eval:outcome(), binary(), binary()}.
run(Source) ->
    Vars = #{<<"0">> => [<<"../script.rc">>], <<"*">> => [],
             <<"path">> => [<<"/bin">>, <<"/usr/bin">>],
             <<"home">> => [<<"/var/empty">>]},
    Outcome = erx_shell_eval:run_source(
                Source, erx_shell_eval:new(Vars, runner(), new())),
    State = erx_shell_eval:runner_state(element(tuple_size(Outcome), Outcome)),
    {Outcome, stdout(State), stderr(State)}.

-doc """
`erl -run erx_shell_fake_runner main Script Directory`: runs Script and
writes `stdout`, `stderr` and `status` into Directory. `status` holds the
final `$status` after `ok`, the outcome, or after `fault` for a fault of
the language, which ends a script with no status, as in rc. A unit that
does not parse ends a script with its `$status` set, as in rc, so it is
`ok`.
""".
-spec main([string()]) -> no_return().
main([Script, Directory]) ->
    {ok, Source} = file:read_file(Script),
    {Outcome, Out, Err} = run(Source),
    Status = case Outcome of
                 {error, _, Shell} -> [<<"fault\n">>, status_line(Shell)];
                 {syntax_error, _, Shell} -> [<<"ok\n">>, status_line(Shell)];
                 {_, Shell} -> [<<"ok\n">>, status_line(Shell)]
             end,
    ok = file:write_file(filename:join(Directory, "stdout"), Out),
    ok = file:write_file(filename:join(Directory, "stderr"), Err),
    ok = file:write_file(filename:join(Directory, "status"), Status),
    halt(0).

status_line(Shell) -> [erx_shell_eval:status(Shell), $\n].

request({run, [Name | Args], _Vars}, State) ->
    command(Name, Args, State);
request({glob, _Pattern}, State) ->
    {[], State};
request({write, Fd, Text}, State) ->
    {ok, write(Fd, Text, State)};
request({redirect, Redirections, Body}, #{fds := Fds} = State) ->
    {Result, State1} = Body(lists:foldl(fun redirect/2, State, Redirections)),
    {Result, State1#{fds := Fds}};
request({capture, Body}, #{fds := Fds, next := Next} = State) ->
    Sink = {capture, Next},
    #{sinks := Sinks} = State,
    Inner = State#{fds := Fds#{1 => Sink}, sinks := Sinks#{Sink => <<>>},
                   next := Next + 1},
    {Status, #{sinks := Sinks1} = State1} = Body(Inner),
    {{maps:get(Sink, Sinks1), Status},
     State1#{fds := Fds, sinks := maps:remove(Sink, Sinks1)}};
request({pipeline, Stages}, State) ->
    {Front, [{_, Last}]} = lists:split(length(Stages) - 1, Stages),
    {Statuses, State1} = lists:mapfoldl(fun({_Pipe, Body}, S) ->
                                                silenced(Body, S)
                                        end, State, Front),
    {Status, State2} = Last(State1),
    {Statuses ++ [Status], State2};
request({subshell, Body}, State) ->
    Body(State);
request({whatis, Name}, State) ->
    case lists:member(Name, [<<"echo">>, <<"true">>, <<"false">>]) of
        true -> {{found, where(Name)}, State};
        false -> {not_found, State}
    end;
request(Request, _State) ->
    error({not_served_by_fake_runner, element(1, Request)}).

%% Where macOS keeps the three commands.
where(<<"echo">>) -> <<"/bin/echo">>;
where(Name) -> <<"/usr/bin/", Name/binary>>.

silenced(Body, #{fds := Fds} = State) ->
    {Status, State1} = Body(State#{fds := maps:remove(1, Fds)}),
    {Status, State1#{fds := Fds}}.

command(<<"echo">>, [<<"-n">> | Args], State) ->
    {<<>>, write(1, lists:join($\s, Args), State)};
command(<<"echo">>, Args, State) ->
    {<<>>, write(1, [lists:join($\s, Args), $\n], State)};
command(<<"true">>, [], State) ->
    {<<>>, State};
command(<<"false">>, [], State) ->
    {<<"1">>, State};
command(Name, _Args, State) ->
    {<<"not found">>, write(2, [Name, <<": not found\n">>], State)}.

write(Fd, Text, #{fds := Fds, sinks := Sinks} = State) ->
    case maps:find(Fd, Fds) of
        {ok, Sink} ->
            Old = maps:get(Sink, Sinks),
            State#{sinks := Sinks#{Sink := iolist_to_binary([Old, Text])}};
        error ->
            State
    end.

redirect({dup, To, From}, #{fds := Fds} = State) ->
    case maps:find(From, Fds) of
        {ok, Sink} -> State#{fds := Fds#{To => Sink}};
        error -> State#{fds := maps:remove(To, Fds)}
    end;
redirect({close, Fd}, #{fds := Fds} = State) ->
    State#{fds := maps:remove(Fd, Fds)};
redirect({Kind, Fd, <<"/dev/null">>}, #{fds := Fds} = State)
  when Kind =:= write; Kind =:= append ->
    State#{fds := maps:remove(Fd, Fds)};
redirect(Redirection, _State) ->
    error({not_served_by_fake_runner, Redirection}).
