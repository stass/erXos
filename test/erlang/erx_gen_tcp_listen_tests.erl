%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gen_tcp_listen_tests).
-moduledoc """
`listen/2`, `accept/2` and `controlling_process/2` of erx_gen_tcp against stock's gen_tcp
(docs/design-network-stack.md, "The backend", "The socket process", **Accepting** and
**controlling_process**). One scenario runs twice: on stock's own gen_tcp over the host's
loopback, and on erx_gen_tcp over the stack's `lo0`, started here with no other
interface; each step's result must be the same on both. Only `listen` and `connect`
name the backend, as on stock OTP, whose inet knows no `erx` backend; every other call
goes through gen_tcp and inet, which reach erx_gen_tcp through the dispatch they already
have.

The steps: a listening socket's options and its answers to what only a connection
answers; an accept that times out; an accepted socket that starts with the listening
socket's options at the time of the accept; controlling_process's answers to its owner,
another process, a dead process and the new owner's messages, which move with it; the new
owner's exit closing the socket; a listening socket moved to another owner; an accept
waiting when its listening socket closes, and the calls after the close; and the
listen-time answers of a port in use, a local address, a bad port and the defaults.
""".

-include_lib("eunit/include/eunit.hrl").

-define(WAIT, 5000).
-define(LOOPBACK, {127, 0, 0, 1}).

differential_test_() ->
    {setup, fun start_stack/0, fun stop_stack/1,
     {timeout, 60,
      fun() ->
              Stock = scenario(#{listen => fun gen_tcp:listen/2, connect => connect(gen_tcp)}),
              Erx = scenario(#{listen => fun erx_gen_tcp:listen/2, connect => connect(erx_gen_tcp)}),
              ?assertEqual(length(Stock), length(Erx)),
              [?assertEqual(Expected, Got) || {Expected, Got} <- lists:zip(Stock, Erx)]
      end}}.

connect(Module) ->
    fun(Port, Opts) -> Module:connect(?LOOPBACK, Port, Opts, ?WAIT) end.

%% Each step as `{Name, Result}`, with no socket, port or pid in a result, so that the two
%% runs compare.
scenario(#{listen := Listen, connect := Connect}) ->
    {ok, L} = Listen(0, [binary, {active, false}]),
    {ok, {_, Port}} = inet:sockname(L),
    Listening =
        [{listen_opts, inet:getopts(L, [active, mode, nodelay])},
         {accept_times_out, gen_tcp:accept(L, 0)},
         {send_on_listener, gen_tcp:send(L, <<"x">>)},
         {recv_on_listener, gen_tcp:recv(L, 0, 0)},
         {peername_on_listener, inet:peername(L)},
         {shutdown_on_listener, gen_tcp:shutdown(L, write)},
         {setopts_on_listener, inet:setopts(L, [{active, once}, {nodelay, true}])},
         {bad_setopts_on_listener, inet:setopts(L, [{no_such_option, true}])},
         {listen_opts_after_setopts, inet:getopts(L, [active, mode, nodelay])}],
    {ok, C} = Connect(Port, [binary, {active, false}]),
    ok = gen_tcp:send(C, <<"hello">>),
    {ok, A} = gen_tcp:accept(L, ?WAIT),
    Accepted =
        [{first_message, receive {tcp, A, Data} -> Data after ?WAIT -> none end},
         {accepted_opts, inet:getopts(A, [active, mode, nodelay])},
         {accept_on_connection, gen_tcp:accept(A, 0)},
         {cp_to_its_owner, gen_tcp:controlling_process(A, self())},
         {cp_by_another_process, elsewhere(fun() -> gen_tcp:controlling_process(A, self()) end)},
         {cp_to_a_dead_process, gen_tcp:controlling_process(A, dead_pid())}],
    ok = inet:setopts(A, [{active, true}]),
    ok = gen_tcp:send(C, <<"moved">>),
    Queued = queued(A),
    NewOwner = spawn(fun() -> receive {report, To} -> To ! {moved, receive M -> M after ?WAIT -> none end} end,
                                   receive exit -> ok end end),
    Moved =
        [{message_queued, Queued},
         {cp_to_another_process, gen_tcp:controlling_process(A, NewOwner)},
         {moved_message, (fun() -> NewOwner ! {report, self()},
                                   receive {moved, {tcp, A, D}} -> {tcp, D}; {moved, M} -> M end end)()},
         {cp_after_giving_it_away, gen_tcp:controlling_process(A, self())},
         {new_owner_exit_closes, (fun() -> NewOwner ! exit, gen_tcp:recv(C, 0, ?WAIT) end)()}],
    Other = spawn(fun() -> receive stop -> ok end end),
    MovedListener =
        [{cp_of_the_listener, gen_tcp:controlling_process(L, Other)},
         {accept_by_former_owner, gen_tcp:accept(L, 0)}],
    Other ! stop,
    {ok, L2} = Listen(0, []),
    Test = self(),
    spawn(fun() -> Test ! {pending, gen_tcp:accept(L2, ?WAIT)} end),
    timer:sleep(200),
    ok = gen_tcp:close(L2),
    Closed =
        [{waiting_accept_at_close, receive {pending, Pending} -> Pending after ?WAIT -> none end},
         {accept_after_close, gen_tcp:accept(L2, 0)},
         {cp_after_close, gen_tcp:controlling_process(L2, self())}],
    ListenTime =
        [{port_in_use, Listen(Port, [])},
         {local_address, address(Listen(0, [{ip, ?LOOPBACK}]))},
         {bad_port, try Listen(70000, []) catch exit:Reason -> {exit, Reason} end},
         {default_opts, (fun() -> {ok, L3} = Listen(0, []), inet:getopts(L3, [active, mode]) end)()}],
    _ = [gen_tcp:close(S) || S <- [C, L]],
    lists:append([Listening, Accepted, Moved, MovedListener, Closed, ListenTime]).

%% What F answers in a process of its own.
elsewhere(F) ->
    Test = self(),
    Pid = spawn(fun() -> Test ! {self(), F()} end),
    receive {Pid, Result} -> Result after ?WAIT -> none end.

dead_pid() ->
    {Pid, Ref} = spawn_monitor(fun() -> ok end),
    receive {'DOWN', Ref, process, Pid, _} -> Pid end.

%% Whether a `{tcp, S, _}` message reaches the test's mailbox, left there.
queued(S) ->
    queued(S, erlang:monotonic_time(millisecond) + ?WAIT).

queued(S, Deadline) ->
    {messages, Messages} = process_info(self(), messages),
    case [M || {tcp, Sock, _} = M <- Messages, Sock =:= S] of
        [_ | _] -> true;
        [] ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(20), queued(S, Deadline);
                false -> false
            end
    end.

address({ok, S}) ->
    {ok, {Ip, _Port}} = inet:sockname(S),
    ok = gen_tcp:close(S),
    Ip;
address(Error) ->
    Error.

%% The stack with lo0 alone, unlinked so that its end fails the case rather than ending it.
start_stack() ->
    {ok, Stack} = erx_net_sup:start_link(#{interfaces => []}),
    unlink(Stack),
    Stack.

stop_stack(Stack) ->
    proc_lib:stop(Stack, shutdown, infinity).
