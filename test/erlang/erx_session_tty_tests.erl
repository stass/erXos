%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_tty_tests).
-moduledoc """
The session's tty relay, erx_session_tty, with the command shell on it and a
fake master in the same node: the test process takes each output, answering
`{tty_taken, N}` as the console does, and types into the tty with
`{tty_input, Bytes}`. `echo hi` and `erl` return, `exit` starts the command
shell again, and an answer the master never sends is asked for again within
the resend second. A hangup ends the relay.
""".

-include_lib("eunit/include/eunit.hrl").

-define(WAIT_MS, 10000).

%% One process is the master throughout, so the steps run in order in it.
relay_test_() ->
    {timeout, 60, fun relay/0}.

relay() ->
    Master = self(),
    process_flag(trap_exit, true),
    {ok, Shells} = erx_session_tty:start_link(fun() -> Master end),
    {ok, _} = await(<<"% ">>),
    echo_and_erl_return(),
    exit_starts_the_shell_again(),
    a_lost_answer_is_asked_for_again(),
    a_hangup_ends_the_relay(Shells).

%% A hangup while the Erlang shell runs ends that shell, the command shell then
%% reads the end of its input, and the relay and its tty end with it, normally,
%% leaving the runtime running and both names free.
a_hangup_ends_the_relay(Shells) ->
    type(<<"erl\r">>),
    {ok, _} = await(<<"1> ">>),
    Tty = monitor(process, whereis(erx_session_tty)),
    erx_session_tty ! tty_hangup,
    receive {'EXIT', Shells, Reason} -> ?assertEqual(normal, Reason) after ?WAIT_MS -> error(relay_runs_on) end,
    receive {'DOWN', Tty, process, _, _} -> ok after ?WAIT_MS -> error(tty_runs_on) end,
    ?assertEqual(undefined, whereis(erx_session_shell)),
    ?assertEqual(undefined, whereis(erx_session_tty)).

echo_and_erl_return() ->
    type(<<"echo hi\r">>),
    {ok, _} = await(<<"hi\r\n% ">>),
    type(<<"erl\r">>),
    {ok, _} = await(<<"1> ">>),
    %% The Erlang shell's group ends, so run_shell/1 returns and `erl` with it.
    type(<<"exit(group_leader(), kill).\r">>),
    {ok, Seen} = await(<<"% ">>),
    ?assertNotEqual(nomatch, binary:match(Seen, <<"killed">>)).

exit_starts_the_shell_again() ->
    type(<<"exit\r">>),
    {ok, _} = await(<<"exit ends it\r\n% ">>),
    type(<<"echo again\r">>),
    {ok, _} = await(<<"again\r\n% ">>).

a_lost_answer_is_asked_for_again() ->
    type(<<"echo lost\r">>),
    %% The first output's answer is lost: the tty sends it again, empty, and the
    %% master answers that.
    N = receive {tty_output, Number, <<_, _/binary>>} -> Number after ?WAIT_MS -> error(no_output) end,
    Started = erlang:monotonic_time(millisecond),
    receive {tty_output, N, <<>>} -> ok after 3000 -> error(no_resend) end,
    ?assert(erlang:monotonic_time(millisecond) - Started >= 900),
    erx_session_tty ! {tty_taken, N},
    {ok, _} = await(<<"lost\r\n% ">>).

%%% The fake master

type(Bytes) ->
    erx_session_tty ! {tty_input, Bytes}.

%% Takes every output until what it took contains Pattern, and returns it.
await(Pattern) ->
    await(Pattern, <<>>).

await(Pattern, Seen) ->
    receive
        {tty_output, N, Bytes} ->
            erx_session_tty ! {tty_taken, N},
            All = <<Seen/binary, Bytes/binary>>,
            case binary:match(All, Pattern) of
                nomatch -> await(Pattern, All);
                _ -> {ok, All}
            end
    after ?WAIT_MS ->
            {timeout, Pattern, Seen}
    end.
