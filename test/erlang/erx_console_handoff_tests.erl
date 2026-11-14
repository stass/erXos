%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The kernel log's handoff to the system console (docs/design-log.md, "The kernel's
%% records", The handoff; "the handoff order" and "one taker (L4)" of "Verification and
%% testing"): the log service is the ring's one taker and makes the first take before the
%% console's driver writes anything, and the console writes the lines it is handed. Run
%% with test/fixtures/erx_log_standin.erl as erx_log, which tells the recorder each take.
-module(erx_console_handoff_tests).
-include_lib("eunit/include/eunit.hrl").

-export([shell/0]).

%% Long enough for three of the log service's 100 ms ticks.
-define(TICKS_MS, 350).

handoff_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun the_console_never_takes_the_ring/1,
      fun the_first_take_comes_before_the_drivers_first_write/1,
      fun the_console_writes_the_services_lines/1]}.

setup() ->
    process_flag(trap_exit, true),
    persistent_term:erase({erx_syslog, started}),
    Recorder = spawn(fun() -> register(erx_log_standin, self()), recorder([], []) end),
    wait_registered(erx_log_standin),
    Recorder.

cleanup(Recorder) ->
    [stop(Name) || Name <- [erx_console, erx_syslog_sup]],
    exit(Recorder, kill),
    persistent_term:erase({erx_syslog, started}),
    flush().

%% The console started alone, as before the log service runs: it asks the service for
%% lines and takes nothing from the ring itself.
the_console_never_takes_the_ring(_Recorder) ->
    ?_test(begin
               Console = start_console(),
               timer:sleep(?TICKS_MS),
               ?assertEqual([], [Event || {take, Pid} = Event <- events(), Pid =:= Console])
           end).

%% The log service, whose init makes the first take, then the console with its driver,
%% in the order kernel_sup starts them (otp/lib/kernel/src/kernel.erl, which this host
%% test does not run; the QEMU suites boot it): the first take precedes every byte the
%% driver writes, and each kernel line the ring held is written once, ended in CR-LF.
the_first_take_comes_before_the_drivers_first_write(_Recorder) ->
    ?_test(begin
               program([{ok, 1, 0, [<<"#1 0.000001 info kernel early\n">>]}]),
               {ok, _Sup} = start_syslog(),
               start_console(),
               timer:sleep(?TICKS_MS),
               Events = events(),
               Order = [Kind || {Kind, _} <- Events, Kind =:= take orelse Kind =:= write],
               Writes = [Bytes || {write, Bytes} <- Events],
               ?assertMatch([take | _], Order),
               ?assertEqual(1, length([W || W <- Writes, W =:= <<"#1 0.000001 info kernel early\r\n">>]))
           end).

%% A system domain record the service renders reaches the line through the line escape.
the_console_writes_the_services_lines(_Recorder) ->
    ?_test(begin
               {ok, _Sup} = start_syslog(),
               start_console(),
               erx_syslog !{log, notice, <<"a\e[2Jb">>},
               timer:sleep(?TICKS_MS),
               Writes = [Bytes || {write, Bytes} <- events()],
               ?assertMatch([_], [W || W <- Writes,
                                       binary:match(W, <<"system: a<U+001B>[2Jb\r\n">>) =/= nomatch])
           end).

%% erx_syslog_sup as kernel_sup starts it in the system domain; start_link/0 ignores a
%% runtime whose user is not the system console, as this test's is not.
start_syslog() ->
    supervisor:start_link({local, erx_syslog_sup}, erx_syslog_sup, []).

start_console() ->
    {ok, Console} = erx_console:start_link(#{role => system, name => erx_console, menu => false,
                                             principal => 1, owner => fun(_Pid) -> 0 end,
                                             driver => fun driver/1,
                                             line_owners => fun() -> {ok, []} end,
                                             first_shell => {?MODULE, shell, []}}),
    Console.

%% A shell that reads nothing and stays.
shell() ->
    spawn_link(fun() -> receive after infinity -> ok end end).

%% The fake driver: each write is an event of the recorder's and is done at once.
driver(Console) ->
    Pid = spawn_link(fun Loop() ->
                             receive
                                 {erx_console_output, From, Bytes} ->
                                     erx_log_standin ! {event, {write, iolist_to_binary(Bytes)}},
                                     Console ! {erx_console_written, From},
                                     Loop()
                             end
                     end),
    {ok, Pid, false}.

%% The recorder: each take and write in order, and the takes' programmed answers.
recorder(Events, Answers) ->
    receive
        {take, Pid, Ref} ->
            {Answer, Rest} = case Answers of
                                 [First | Others] -> {First, Others};
                                 [] -> {{ok, 0, 0, []}, []}
                             end,
            Pid ! {Ref, Answer},
            recorder([{take, Pid} | Events], Rest);
        {event, Event} ->
            recorder([Event | Events], Answers);
        {program, More} ->
            recorder(Events, Answers ++ More);
        {events, From, Ref} ->
            From ! {Ref, lists:reverse(Events)},
            recorder(Events, Answers)
    end.

program(Answers) ->
    erx_log_standin ! {program, Answers},
    ok.

events() ->
    Ref = make_ref(),
    erx_log_standin ! {events, self(), Ref},
    receive {Ref, Events} -> Events after 2000 -> error(no_recorder) end.

wait_registered(Name) ->
    case whereis(Name) of
        undefined -> timer:sleep(5), wait_registered(Name);
        _Pid -> ok
    end.

stop(Name) ->
    case whereis(Name) of
        undefined ->
            ok;
        Pid ->
            Ref = monitor(process, Pid),
            unlink(Pid),
            exit(Pid, kill),
            receive {'DOWN', Ref, process, Pid, _} -> ok end
    end.

flush() ->
    receive _ -> flush() after 0 -> ok end.
