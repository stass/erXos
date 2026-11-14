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
                     {ok, Tables} = erx_net_tables:start_link(),
                     try Case() after cleanup(Tables) end
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
       fun credit_limit_follows_the_backlog/0},
      {"listen's options: the listener's four, a later one replacing an earlier, others einval",
       fun options_are_the_listeners_four/0},
      {"its key holds the entry an accepted connection starts from, and its end deletes it",
       fun the_key_holds_the_entry/0},
      {"a refused bind is its start's answer and leaves its socket process unlinked",
       fun a_refused_bind_is_the_answer/0},
      {"setopts of nodelay rewrites the entry before it is answered", fun setopts_rewrites_the_entry/0},
      {"close is answered and ends the listener, deleting its key", fun close_ends_the_listener/0},
      {"once close is answered the port is free to listen on again", fun close_frees_the_port_before_its_answer/0}]].

cleanup(Tables) ->
    unlink(Tables),
    exit(Tables, kill),
    flush(),
    process_flag(trap_exit, false).

flush() ->
    receive _ -> flush() after 0 -> ok end.

%% --- The stand-ins ---------------------------------------------------------------

%% A listener started by a stand-in grant for a stand-in socket process, which hands the test
%% every message it takes as {sock, Msg}.
start() -> start(#{}).

%% Extra holds listen's options, and may name the port to bind.
start(Extra) ->
    Test = self(),
    Sock = relay(sock),
    {ok, Options} = erx_tcp_listen_core:options(maps:to_list(maps:remove(port, Extra))),
    Start = #{socket => Sock, origin => local, local => any, port => maps:get(port, Extra, 0),
              allowed => [{1024, 65535}], options => Options},
    Grant = spawn(fun() ->
                          {ok, L} = erx_tcp_listen:start_link(Start),
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

options_are_the_listeners_four() ->
    ?assertEqual({ok, #{backlog => 5, reuseaddr => false, reuseport => false, nodelay => false}},
                 erx_tcp_listen_core:options([])),
    ?assertEqual({ok, #{backlog => 1, reuseaddr => true, reuseport => true, nodelay => true}},
                 erx_tcp_listen_core:options([{backlog, 9}, {reuseaddr, true}, {reuseport, true},
                                              {nodelay, true}, {backlog, 1}])),
    [?assertEqual({error, einval}, erx_tcp_listen_core:options(Opts))
     || Opts <- [[{active, true}], [{backlog, 1.0}], [{reuseaddr, 1}], [{nodelay, true} | x], x]].

the_key_holds_the_entry() ->
    #{l := L, sock := Sock, grant := Grant, credit := Credit} = start(#{nodelay => true}),
    {ok, {{0, 0, 0, 0}, Port}} = sock_call(L, Sock, 1, sockname),
    Key = {tcp_listen, inet, any, Port},
    ?assertMatch([#{pid := L, credit := Credit, grant := Grant, origin := local,
                    listener := #{rcv_buf := 65536, rcv_scale := _},
                    accept := #{cc := erx_tcp_cc_cubic, loss := erx_tcp_loss_dupack, nodelay := true,
                                snd_hiwat := 32768, rcv_hiwat := 65536}}],
                 erx_net_tables:demux(Key)),
    exit(Sock, kill),
    ?assertEqual(normal, await_down(L)),
    ?assertEqual([], erx_net_tables:demux(Key)).

a_refused_bind_is_the_answer() ->
    #{l := L, sock := Sock} = start(),
    {ok, {_, Port}} = sock_call(L, Sock, 1, sockname),
    Test = self(),
    Sock2 = relay(sock2),
    {ok, Options} = erx_tcp_listen_core:options([]),
    spawn(fun() ->
                  process_flag(trap_exit, true),
                  Test ! {started, erx_tcp_listen:start_link(#{socket => Sock2, origin => local, local => any,
                                                                port => Port, allowed => [{1024, 65535}],
                                                                options => Options})}
          end),
    receive {started, Started} -> ?assertEqual({error, eaddrinuse}, Started) after ?WAIT -> error(no_start) end,
    spawn(fun() ->
                  process_flag(trap_exit, true),
                  Test ! {started, erx_tcp_listen:start_link(#{socket => Sock2, origin => local, local => any,
                                                                port => 80, allowed => [{1024, 65535}],
                                                                options => Options})}
          end),
    receive {started, Started2} -> ?assertEqual({error, eacces}, Started2) after ?WAIT -> error(no_start) end,
    %% The refused listener unlinked before it ended, so its socket process heard no exit.
    receive {sock2, {'EXIT', _, _} = Exit} -> error({told, Exit}) after 100 -> ok end,
    ?assertEqual({links, []}, process_info(Sock2, links)).

setopts_rewrites_the_entry() ->
    #{l := L, sock := Sock} = start(),
    {ok, {_, Port}} = sock_call(L, Sock, 1, sockname),
    ?assertEqual(ok, sock_call(L, Sock, 2, {setopts, [{nodelay, true}]})),
    [#{accept := #{nodelay := true}}] = erx_net_tables:demux({tcp_listen, inet, any, Port}),
    ?assertEqual(ok, sock_call(L, Sock, 3, {setopts, []})),
    %% A key its grant's end deleted is gone: the listener ends as at its grant's exit.
    ets:delete(erx_net_demux, {tcp_listen, inet, any, Port}),
    L ! {erx_net, Sock, {call, 4, {setopts, [{nodelay, false}]}}},
    ?assertEqual({shutdown, grant_ended}, await_down(L)).

close_ends_the_listener() ->
    #{l := L, sock := Sock} = start(),
    {ok, {_, Port}} = sock_call(L, Sock, 1, sockname),
    Ref = monitor(process, L),
    ?assertEqual(ok, sock_call(L, Sock, 2, close)),
    receive {'DOWN', Ref, process, L, Reason} -> ?assertEqual(normal, Reason) after ?WAIT -> error(still_running) end,
    ?assertEqual([], erx_net_tables:demux({tcp_listen, inet, any, Port})).

%% stock's listen, close, listen on one port works, as FreeBSD's soclose frees the port before
%% close returns: the listener deletes its key before it sends close's answer. A process's
%% trace messages arrive in the order its events happened, so the trace of the listener's
%% call of erx_net_bind:delete/1 and of its send of the answer gives the order outright.
close_frees_the_port_before_its_answer() ->
    #{l := L, sock := Sock} = start(),
    {ok, {_, Port}} = sock_call(L, Sock, 1, sockname),
    Key = {tcp_listen, inet, any, Port},
    1 = erlang:trace_pattern({erx_net_bind, delete, 1}, true, [global]),
    1 = erlang:trace(L, true, [call, send]),
    try
        ok = sock_call(L, Sock, 2, close),
        %% The stop that follows deletes again, finding nothing.
        ?assertMatch([delete, reply | _], traced(L, Key, Sock))
    after
        erlang:trace_pattern({erx_net_bind, delete, 1}, false, [global])
    end.

%% The listener's delete of Key and its send of close's answer to Sock, in the order traced.
traced(L, Key, Sock) ->
    receive
        {trace, L, call, {erx_net_bind, delete, [Key]}} -> [delete | traced(L, Key, Sock)];
        {trace, L, send, {erx_net, L, {reply, 2, ok}}, Sock} -> [reply | traced(L, Key, Sock)];
        {trace, L, _, _} -> traced(L, Key, Sock);
        {trace, L, _, _, _} -> traced(L, Key, Sock)
    after 200 -> []
    end.

%% A call of the listener from its socket process, answered to that process.
sock_call(L, Sock, N, Request) ->
    L ! {erx_net, Sock, {call, N, Request}},
    receive {sock, {erx_net, L, {reply, N, Reply}}} -> Reply after ?WAIT -> error({no_reply, N}) end.
