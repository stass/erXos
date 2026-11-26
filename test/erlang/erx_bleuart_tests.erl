%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bleuart_tests).
-moduledoc """
erx_bleuart over a stub line and a stub erx_gatt_serial (docs/design-bluetooth.md,
"The console", the relay row of its tests). The test process is root's line: the
stub line forwards each call to it, and it answers. Each tty is a stub process that
forwards what it is sent. The stub serial module, this module, records each send.

A connection opens one tty running the shell; each connection's bytes reach its own
tty and its tty's output its own client; a loss of input hangs the tty up and later
bytes reach no tty; the shell's end ends the relay; `unavailable` sends the one line
at the client's subscription and opens no tty; a refused open leaves the connection
with no tty; the line's end ends erx_bleuart.
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([start_link/2, send/2]).

%% Root's session's domain.
-define(ROOT, 7).
-define(PEER, erx_bleuart_tests_peer).
%% The next message that matches Pattern, which it binds; an error after 2 s.
-define(received(Pattern),
        (fun() -> receive Pattern = Received__ -> Received__ after 2000 -> error({not_received, ??Pattern}) end end)()).
-define(LOST, <<"\r\nbleuart: input was lost; the shell has ended\r\n">>).
-define(ENDED, <<"\r\nbleuart: the shell has ended\r\n">>).
-define(UNAVAILABLE, <<"bleuart: root's session is not running\r\n">>).

%% The stub serial module: a handler that does nothing, and sends told to the peer; a
%% send of <<"block">> waits for release.
start_link(nus, Owner) when is_pid(Owner) ->
    {ok, spawn_link(fun() -> receive after infinity -> ok end end)}.

send(Conn, <<"block">>) ->
    ?PEER ! {blocked, Conn, self()},
    receive release -> ok end;
send(Conn, Bytes) ->
    ?PEER ! {sent, Conn, Bytes},
    ok.

%% erx_bleuart with root's line answering as RootLine says, and the line process.
start(RootLine) ->
    true = register(?PEER, self()),
    Test = self(),
    Line = spawn(fun() -> line(Test) end),
    Effects = #{serial => ?MODULE, owner => fun(_Pid) -> ?ROOT end,
                root_line => fun() -> RootLine(Line) end},
    {ok, Bleuart} = erx_bleuart:start_link(Effects),
    unlink(Bleuart),
    {Bleuart, Line}.

stop({Bleuart, Line}) ->
    Monitor = monitor(process, Bleuart),
    exit(Bleuart, kill),
    receive {'DOWN', Monitor, process, Bleuart, _} -> ok end,
    exit(Line, kill),
    unregister(?PEER).

%% The stub line: each call goes to the test process, which answers it.
line(Test) ->
    receive
        {'$gen_call', From, Request} -> Test ! {line_call, From, Request}
    end,
    line(Test).

%% A stub tty, which tells the test process what it is sent.
tty(Name) ->
    Test = self(),
    spawn(fun Loop() -> receive Message -> Test ! {Name, Message}, Loop() end end).

with_line(Fun) ->
    State = start(fun(Line) -> {ok, Line} end),
    try Fun(State) after stop(State) end.

%% A connection, its open_tty answered Answer; the master it named.
connect(Conn, Answer) ->
    erx_bleuart ! {connected, Conn, #{level => open, bond => none}},
    receive
        {line_call, From, {open_tty, Master, shell, <<>>, 0, 0}} ->
            gen_server:reply(From, Answer),
            Master
    after 2000 -> error(no_open_tty)
    end.

%% A connection whose tty Name has named itself to its master.
opened(Conn, Name) ->
    Master = connect(Conn, ok),
    Tty = tty(Name),
    Master ! {erx_origin, ?ROOT, {tty_open, Tty}},
    Master.


nothing() ->
    receive Message -> error({unexpected, Message}) after 200 -> ok end.

a_connection_opens_one_shell_test() ->
    with_line(fun({Bleuart, _Line}) ->
                      Master = connect(make_ref(), ok),
                      ?assert(is_pid(Master) andalso Master =/= Bleuart),
                      nothing()
              end).

each_connection_reaches_its_own_tty_test() ->
    with_line(fun(_) ->
                      A = make_ref(), B = make_ref(),
                      _ = opened(A, a),
                      MasterB = opened(B, b),
                      erx_bleuart ! {serial, A, <<"ls\r">>},
                      ?assertEqual({a, {tty_input, 0, <<"ls\r">>}}, ?received({a, _})),
                      MasterB ! {erx_origin, ?ROOT, {tty_output, 0, <<"% ">>}},
                      erx_bleuart ! {subscribed, B, tx, notify},
                      ?assertEqual({sent, B, <<"% ">>}, ?received({sent, _, _})),
                      ?assertEqual({b, {tty_taken, 0}}, ?received({b, _})),
                      nothing()
              end).

%% The seeded fault, serial_lost ignored, delivers <<"mp\r">> and sends no hangup.
a_loss_hangs_the_tty_up_test() ->
    with_line(fun(_) ->
                      Conn = make_ref(),
                      _ = opened(Conn, a),
                      erx_bleuart ! {serial, Conn, <<"cd /t">>},
                      erx_bleuart ! {serial_lost, Conn},
                      erx_bleuart ! {serial, Conn, <<"mp\r">>},
                      ?assertEqual({a, {tty_input, 0, <<"cd /t">>}}, ?received({a, _})),
                      ?assertEqual({a, tty_hangup}, ?received({a, tty_hangup})),
                      ?assertEqual({sent, Conn, ?LOST}, ?received({sent, Conn, _})),
                      nothing()
              end).

the_shells_end_ends_the_relay_test() ->
    with_line(fun(_) ->
                      Conn = make_ref(),
                      Master = opened(Conn, a),
                      Monitor = monitor(process, Master),
                      Master ! {erx_origin, ?ROOT, {exited, 0}},
                      ?assertEqual({sent, Conn, ?ENDED}, ?received({sent, Conn, _})),
                      ?received({'DOWN', Monitor, process, Master, normal}),
                      erx_bleuart ! {serial, Conn, <<"ls\r">>},
                      nothing()
              end).

a_disconnect_hangs_the_tty_up_test() ->
    with_line(fun(_) ->
                      Conn = make_ref(),
                      _ = opened(Conn, a),
                      erx_bleuart ! {disconnected, Conn},
                      ?assertEqual({a, tty_hangup}, ?received({a, tty_hangup})),
                      nothing()
              end).

unavailable_sends_one_line_at_the_subscription_test() ->
    Test = self(),
    State = start(fun(_Line) -> Test ! root_line_asked, {error, unavailable} end),
    try
        Conn = make_ref(),
        erx_bleuart ! {connected, Conn, #{level => open, bond => none}},
        ?received(root_line_asked),
        nothing(),
        erx_bleuart ! {subscribed, Conn, tx, notify},
        ?assertEqual({sent, Conn, ?UNAVAILABLE}, ?received({sent, _, _})),
        erx_bleuart ! {serial, Conn, <<"ls\r">>},
        erx_bleuart ! {subscribed, Conn, tx, notify},
        nothing(),
        erx_bleuart ! {connected, make_ref(), #{}},
        ?received(root_line_asked),
        nothing()
    after
        stop(State)
    end.

a_refused_open_leaves_no_tty_test() ->
    with_line(fun({Bleuart, _Line}) ->
                      Conn = make_ref(),
                      Master = connect(Conn, {error, limited}),
                      Monitor = monitor(process, Master),
                      ?received({'DOWN', Monitor, process, Master, normal}),
                      erx_bleuart ! {serial, Conn, <<"ls\r">>},
                      nothing(),
                      ?assert(is_process_alive(Bleuart))
              end).

the_lines_end_ends_bleuart_test() ->
    State = {Bleuart, Line} = start(fun(Line) -> {ok, Line} end),
    try
        _ = connect(make_ref(), ok),
        Monitor = monitor(process, Bleuart),
        exit(Line, kill),
        ?assertMatch({'DOWN', Monitor, process, Bleuart, {shutdown, {line_ended, killed}}},
                     ?received({'DOWN', Monitor, process, Bleuart, _}))
    after
        stop(State)
    end.

%% A master that does not keep up loses the shell, not input: past twice bt_write_queue
%% messages in its queue the next event is a gap, which hangs the tty up, and nothing
%% after it reaches the master; a burst of bt_write_queue writes, all the link keeps
%% unanswered, while a send is pending reaches the tty whole. The seeded fault, every
%% event forwarded, delivers every write and sends no hangup.
a_master_behind_ends_the_relay_test() ->
    with_line(fun(_) ->
                      Conn = make_ref(),
                      Master = opened(Conn, a),
                      erx_bleuart ! {subscribed, Conn, tx, notify},
                      Master ! {erx_origin, ?ROOT, {tty_output, 0, <<"block">>}},
                      {blocked, Conn, Sender} = ?received({blocked, Conn, _}),
                      [erx_bleuart ! {serial, Conn, <<"x">>} || _ <- lists:seq(1, 2 * ?ERX_BT_WRITE_QUEUE + 2)],
                      erx_bleuart ! {serial, Conn, <<"late">>},
                      timer:sleep(200),
                      Sender ! release,
                      Inputs = [ok || _ <- lists:seq(1, 2 * ?ERX_BT_WRITE_QUEUE)],
                      ?assertEqual(Inputs, [ok || {a, {tty_input, _, <<"x">>}} <- [?received({a, {tty_input, _, _}}) || _ <- Inputs]]),
                      ?assertEqual({a, {tty_taken, 0}}, ?received({a, {tty_taken, _}})),
                      ?assertEqual({a, tty_hangup}, ?received({a, tty_hangup})),
                      ?assertEqual({sent, Conn, ?LOST}, ?received({sent, Conn, _})),
                      nothing()
              end).
