%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_listen_tests).
-moduledoc """
The listener's effect process, erx_tcp_listen (docs/design-network-stack.md, "The
listener"), with stand-ins for every party around it: its grant, which starts it; its
socket process, which sends the `accept` calls and takes their replies; the acceptors'
socket processes; and connections that queue themselves on a unit of its accept credit, as
an adopted connection does, and answer `bind` as the test tells them. The cases check what
the effects add to the explored core: links made and undone, a unit taken back as a
connection leaves the queue, the replies reaching the socket process, the clock armed for a
deadline, the ends of the socket process and the grant, and what admission keeps out.
""".

-include_lib("eunit/include/eunit.hrl").

-define(WAIT, 3000).

listen_test_() ->
    [{Name, fun() -> process_flag(trap_exit, true),
                     ok = persistent_term:put({erx_net_sup, runtime}, erx_net_local),
                     try Case() after cleanup() end
            end}
     || {Name, Case} <-
     [{"a queued connection is bound to the next accept and the call answered at bound",
       fun queued_connection_goes_to_an_accept/0},
      {"an accept waits for the next connection", fun accept_waits_for_a_connection/0},
      {"an accept past its deadline is answered timeout", fun accept_times_out/0},
      {"an acceptor that ends while waiting is answered econnaborted and passed over",
       fun ended_acceptor_is_passed_over/0},
      {"an acceptor already gone is answered econnaborted", fun gone_acceptor_is_answered/0},
      {"a connection that ends after pairing answers its call econnaborted",
       fun connection_ending_after_pairing_aborts_the_call/0},
      {"a queued connection's exit gives its unit back", fun queued_exit_gives_the_unit_back/0},
      {"the socket process's exit ends the listener and reaches its queue",
       fun socket_exit_ends_the_listener/0},
      {"the grant's exit ends the listener", fun grant_exit_ends_the_listener/0},
      {"a call past 64 in flight is answered badarg", fun call_past_64_is_refused/0},
      {"an accept naming the listener's own socket process or grant is answered badarg",
       fun own_process_as_acceptor_is_refused/0},
      {"a message that is not its socket process's is dropped and counted",
       fun stranger_is_dropped/0},
      {"the accept credit holds 3 * backlog div 2 + 1, the backlog clamped to 128",
       fun credit_limit_follows_the_backlog/0}]].

cleanup() ->
    flush(),
    process_flag(trap_exit, false).

flush() ->
    receive _ -> flush() after 0 -> ok end.

%% --- The stand-ins ---------------------------------------------------------------

%% A listener started by a stand-in grant for a stand-in socket process, which hands the test
%% every message it takes as {sock, Msg}.
start() -> start(#{}).

start(Extra) ->
    Test = self(),
    Sock = relay(sock),
    Grant = spawn(fun() ->
                          {ok, L} = erx_tcp_listen:start_link(Extra#{socket => Sock, origin => local}),
                          Test ! {listener, L},
                          receive stop -> ok end
                  end),
    L = receive {listener, P} -> P after ?WAIT -> error(no_listener) end,
    #{l => L, sock => Sock, grant => Grant, credit => credit(L)}.

%% The listener's accept credit, read from its state.
credit(L) -> element(5, sys:get_state(L)).

%% A process that traps exits and hands the test every message it takes, tagged.
relay(Tag) ->
    Test = self(),
    spawn(fun() ->
                  process_flag(trap_exit, true),
                  (fun Loop() -> receive Msg -> Test ! {Tag, Msg}, Loop() end end)()
          end).

%% An acceptor's socket process: it lives until it is told to stop or is killed.
acceptor() -> spawn(fun() -> receive stop -> ok end end).

%% A connection that queues itself as an adopted connection does, its unit reserved and its
%% link to the listener made before its notice. At bind it hands the test the bind and then
%% answers `bound` after linking to the acceptor, or ends.
conn(#{l := L, credit := Credit}, OnBind) ->
    Test = self(),
    spawn(fun() ->
                  process_flag(trap_exit, true),
                  ok = erx_net_credit:reserve(Credit, 1),
                  true = link(L),
                  L ! {queued, self()},
                  conn_loop(Test, L, OnBind)
          end).

conn_loop(Test, L, OnBind) ->
    receive
        {bind, L, Acceptor} = Bind ->
            Test ! {conn, self(), Bind},
            case OnBind of
                bound ->
                    true = link(Acceptor),
                    L ! {bound, self()},
                    conn_loop(Test, L, OnBind);
                die ->
                    exit(ended)
            end;
        Msg ->
            Test ! {conn, self(), Msg},
            conn_loop(Test, L, OnBind)
    end.

accept(#{l := L, sock := Sock}, N, Acceptor, Timeout) ->
    L ! {erx_net, Sock, {call, N, {accept, Acceptor, Timeout}}}.

reply(#{l := L}, N) ->
    receive {sock, {erx_net, L, {reply, N, Reply}}} -> Reply
    after ?WAIT -> error({no_reply, N})
    end.

no_reply(#{l := L}, Wait) ->
    receive {sock, {erx_net, L, {reply, _, _} = Reply}} -> error({unexpected, Reply})
    after Wait -> ok
    end.

bind_of(Conn) ->
    receive {conn, Conn, {bind, _, Acceptor}} -> Acceptor after ?WAIT -> error({no_bind, Conn}) end.

no_bind(Conn, Wait) ->
    receive {conn, Conn, {bind, _, _} = Bind} -> error({unexpected, Bind}) after Wait -> ok end.

%% The listener's links once it has performed what it last took: the reply goes out before
%% the unlinks after it, so a state read first is the barrier.
links(L) ->
    _ = sys:get_state(L),
    {links, Links} = process_info(L, links),
    lists:sort(Links).

%% Waits until the accept credit has Free units free.
await_free(Credit, Free) -> await_free(Credit, Free, 300).
await_free(Credit, Free, 0) -> ?assertEqual(Free, erx_net_credit:free(Credit));
await_free(Credit, Free, N) ->
    case erx_net_credit:free(Credit) of
        Free -> ok;
        _ -> receive after 10 -> await_free(Credit, Free, N - 1) end
    end.

await_down(Pid) ->
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, Reason} -> Reason after ?WAIT -> error({still_running, Pid}) end.

%% --- Cases -----------------------------------------------------------------------

queued_connection_goes_to_an_accept() ->
    #{l := L, sock := Sock, grant := Grant, credit := Credit} = Ctx = start(),
    %% The default backlog, 5: a credit of 8.
    ?assertEqual(8, erx_net_credit:free(Credit)),
    Conn = conn(Ctx, bound),
    await_free(Credit, 7),
    A = acceptor(),
    accept(Ctx, 1, A, infinity),
    ?assertEqual(A, bind_of(Conn)),
    ?assertEqual({ok, Conn}, reply(Ctx, 1)),
    %% Off the queue, the unit is back; answered, the listener holds neither the
    %% connection nor the acceptor.
    ?assertEqual(8, erx_net_credit:free(Credit)),
    ?assertEqual(lists:sort([Sock, Grant]), links(L)).

accept_waits_for_a_connection() ->
    #{credit := Credit} = Ctx = start(#{backlog => 1}),
    ?assertEqual(2, erx_net_credit:free(Credit)),
    A = acceptor(),
    accept(Ctx, 7, A, infinity),
    no_reply(Ctx, 100),
    Conn = conn(Ctx, bound),
    ?assertEqual(A, bind_of(Conn)),
    ?assertEqual({ok, Conn}, reply(Ctx, 7)),
    ?assertEqual(2, erx_net_credit:free(Credit)).

accept_times_out() ->
    #{l := L, sock := Sock, grant := Grant} = Ctx = start(),
    A = acceptor(),
    accept(Ctx, 1, A, 100),
    ?assertEqual({error, timeout}, reply(Ctx, 1)),
    ?assertEqual(lists:sort([Sock, Grant]), links(L)),
    %% A connection that arrives later waits for the next accept.
    Conn = conn(Ctx, bound),
    no_bind(Conn, 100),
    accept(Ctx, 2, A, infinity),
    ?assertEqual(A, bind_of(Conn)),
    ?assertEqual({ok, Conn}, reply(Ctx, 2)).

ended_acceptor_is_passed_over() ->
    Ctx = start(),
    A1 = acceptor(),
    A2 = acceptor(),
    accept(Ctx, 1, A1, infinity),
    accept(Ctx, 2, A2, infinity),
    exit(A1, kill),
    ?assertEqual({error, econnaborted}, reply(Ctx, 1)),
    Conn = conn(Ctx, bound),
    ?assertEqual(A2, bind_of(Conn)),
    ?assertEqual({ok, Conn}, reply(Ctx, 2)).

gone_acceptor_is_answered() ->
    Ctx = start(),
    Gone = acceptor(),
    killed = await_down_after_kill(Gone),
    accept(Ctx, 1, Gone, infinity),
    ?assertEqual({error, econnaborted}, reply(Ctx, 1)).

await_down_after_kill(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, Reason} -> Reason end.

connection_ending_after_pairing_aborts_the_call() ->
    #{l := L, sock := Sock, grant := Grant, credit := Credit} = Ctx = start(),
    Conn = conn(Ctx, die),
    A = acceptor(),
    accept(Ctx, 1, A, infinity),
    ?assertEqual(A, bind_of(Conn)),
    ?assertEqual({error, econnaborted}, reply(Ctx, 1)),
    %% The unit came back at the pairing, and only then.
    ?assertEqual(8, erx_net_credit:free(Credit)),
    ?assertEqual(lists:sort([Sock, Grant]), links(L)),
    %% The call is not paired again: the next connection waits for the next accept.
    Conn2 = conn(Ctx, bound),
    no_bind(Conn2, 100).

queued_exit_gives_the_unit_back() ->
    #{credit := Credit} = Ctx = start(),
    Conn = conn(Ctx, bound),
    await_free(Credit, 7),
    exit(Conn, kill),
    await_free(Credit, 8),
    %% Dropped from the queue: an accept waits rather than taking it.
    accept(Ctx, 1, acceptor(), infinity),
    no_reply(Ctx, 100).

socket_exit_ends_the_listener() ->
    #{l := L, sock := Sock} = Ctx = start(),
    Conn = conn(Ctx, bound),
    await_free(maps:get(credit, Ctx), 7),
    exit(Sock, kill),
    ?assertEqual(normal, await_down(L)),
    receive {conn, Conn, {'EXIT', L, normal}} -> ok after ?WAIT -> error(queue_not_told) end.

%% The grant is the listener's parent: gen_server ends the listener with the grant's reason.
grant_exit_ends_the_listener() ->
    #{l := L, grant := Grant} = start(),
    exit(Grant, kill),
    ?assertEqual(killed, await_down(L)),
    receive {sock, {'EXIT', L, killed}} -> ok after ?WAIT -> error(socket_not_told) end.

call_past_64_is_refused() ->
    Ctx = start(),
    [accept(Ctx, N, acceptor(), infinity) || N <- lists:seq(1, 64)],
    accept(Ctx, 65, acceptor(), infinity),
    ?assertEqual({error, badarg}, reply(Ctx, 65)),
    %% The 64 still wait, and the first of them takes the next connection.
    Conn = conn(Ctx, bound),
    _ = bind_of(Conn),
    ?assertEqual({ok, Conn}, reply(Ctx, 1)).

own_process_as_acceptor_is_refused() ->
    #{l := L, sock := Sock, grant := Grant} = Ctx = start(),
    accept(Ctx, 1, Sock, infinity),
    ?assertEqual({error, badarg}, reply(Ctx, 1)),
    accept(Ctx, 2, Grant, 100),
    ?assertEqual({error, badarg}, reply(Ctx, 2)),
    %% Neither call holds a link or a deadline: the listener still ends with its socket process.
    ?assertEqual(lists:sort([Sock, Grant]), links(L)),
    no_reply(Ctx, 200),
    exit(Sock, kill),
    ?assertEqual(normal, await_down(L)).

stranger_is_dropped() ->
    #{l := L, sock := Sock} = Ctx = start(),
    Stranger = acceptor(),
    %% Named for another socket process, in a foreign envelope, of another kind's shape, and
    %% naming no pid: none is answered or stepped.
    L ! {erx_net, Stranger, {call, 1, {accept, acceptor(), infinity}}},
    L ! {erx_origin, 7, {erx_net, Sock, {call, 2, {accept, acceptor(), infinity}}}},
    L ! {erx_net, Sock, {call, 3, {send, <<"x">>}}},
    L ! {erx_net, Sock, {call, 4, {accept, not_a_pid, infinity}}},
    no_reply(Ctx, 100),
    #{counters := Counters} = status(L),
    ?assertEqual(#{unknown => 2, shape => 2}, Counters),
    #{waiting := []} = maps:get(listener, status(L)).

status(L) ->
    {status, _, _, [_, _, _, _, Misc]} = sys:get_status(L),
    hd([State || {data, Data} <- Misc, {"State", State} <- Data]).

credit_limit_follows_the_backlog() ->
    ?assertEqual(1, erx_tcp_listen_core:credit_limit(0)),
    ?assertEqual(2, erx_tcp_listen_core:credit_limit(1)),
    ?assertEqual(8, erx_tcp_listen_core:credit_limit(5)),
    ?assertEqual(193, erx_tcp_listen_core:credit_limit(128)),
    ?assertEqual(193, erx_tcp_listen_core:credit_limit(129)),
    ?assertEqual(193, erx_tcp_listen_core:credit_limit(-1)).
