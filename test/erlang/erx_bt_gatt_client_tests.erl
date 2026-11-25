%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the `ble` facet's client side (docs/design-bluetooth.md, "The client",
%% "Stage 3: the serial service"): erx_gatt's event reader and its attach retry, and the
%% serial service, erx_gatt_serial over erx_gatt_service, against the real registry,
%% erx_gatt_srv, serving abi/gatt's declared services. The facet is a stand-in installed
%% as `ble` in erx_facets: it forwards each operation to the registry with a relay as its
%% caller, and the relay puts each event the registry sends in the Bluetooth domain's
%% envelope, as the funnel delivers it in an app's domain. erx_dist is the host stand-in
%% whose owner/1 answers ?BT for every name.
-module(erx_bt_gatt_client_tests).
-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

-define(BT, 5).
-define(OTHER, 9).
-define(WAIT_MS, 2000).
-define(ADDRESS, {random, <<16#C0, 16#FF, 16#EE, 16#12, 16#34, 16#56>>}).
-define(IDENTITY, {public, <<16#00, 16#1B, 16#DC, 16#0A, 16#0B, 16#0C>>}).
-define(GAP, #{name => <<"erxos">>, appearance => 0}).

%% ---- the event reader ----

event_from_the_facet_owner_alone_test() ->
    C = make_ref(),
    R = make_ref(),
    Write = {write, R, C, rx, <<"hi">>},
    ?assertEqual({ok, Write}, erx_gatt:event(?BT, {erx_origin, ?BT, Write})),
    ?assertEqual(unknown, erx_gatt:event(?BT, {erx_origin, ?OTHER, Write})),
    ?assertEqual(unknown, erx_gatt:event(?BT, Write)),
    ?assertEqual(unknown, erx_gatt:event(?BT, {erx_origin, ?BT, {mtu, C, 22}})),
    ?assertEqual(unknown, erx_gatt:event(?BT, {erx_origin, ?BT, {write, R, C, <<"rx">>, <<>>}})),
    Connected = #{address => ?ADDRESS, bonded => false, level => open},
    ?assertMatch({ok, _}, erx_gatt:event(?BT, {erx_origin, ?BT, {connected, C, Connected}})),
    ?assertEqual(unknown, erx_gatt:event(?BT, {erx_origin, ?BT, {connected, C, Connected#{extra => 1}}})),
    Bonded = Connected#{bonded => true},
    ?assertEqual({ok, {connected, C, Bonded}}, erx_gatt:event(?BT, {erx_origin, ?BT, {connected, C, Bonded}})),
    %% No event carries a bond's identity address.
    [?assertEqual(unknown, erx_gatt:event(?BT, {erx_origin, ?BT, {connected, C, Info}}))
     || Info <- [Connected#{identity => ?IDENTITY}, Bonded#{identity => ?IDENTITY}, Connected#{bonded => yes},
                 Bonded#{extra => 1}]].

%% ---- attach and the owner's answers, over a facet that answers a script ----

attach_asks_again_until_the_previous_handler_has_gone_test() ->
    with_scripted_facet([{error, attached}, {error, attached}, {ok, #{}}],
                        fun() -> ?assertEqual({ok, #{}}, erx_gatt:attach(nus)) end).

attach_answers_attached_at_the_deadline_test_() ->
    {timeout, 30,
     fun() ->
             with_scripted_facet(lists:duplicate(1000, {error, attached}),
                                 fun() ->
                                         Start = erlang:monotonic_time(millisecond),
                                         ?assertEqual({error, attached}, erx_gatt:attach(nus)),
                                         Took = erlang:monotonic_time(millisecond) - Start,
                                         ?assert(Took >= 4900 andalso Took < 6000)
                                 end)
     end}.

not_attached_ends_the_caller_test() ->
    with_scripted_facet([{error, not_attached}],
                        fun() -> ?assertExit({not_attached, nus}, erx_gatt:set(nus, tx, <<>>)) end).

an_answer_of_no_shape_is_badarg_test() ->
    with_scripted_facet([{ok, #{rx => #{max => 9999, access => #{}}}}, {error, "text"}],
                        fun() ->
                                ?assertEqual({error, badarg}, erx_gatt:attach(nus)),
                                ?assertEqual({error, badarg}, erx_gatt:set(nus, tx, <<>>))
                        end).

%% A facet whose server ended is a dead pid until the next incarnation installs another:
%% the call exits the caller, as a call to any server that ended does.
an_ended_facet_exits_the_caller_test() ->
    erx_facets:install(#{ble => ended_pid()}),
    ?assertExit({noproc, _}, erx_gatt:attach(nus)).

%% ---- the serial service against the registry ----

serial_test_() ->
    {foreach, fun start_registry/0, fun stop/1,
     [fun(_) -> {"a write of rx reaches the owner and is answered at once", fun write_reaches_the_owner/0} end,
      fun(_) -> {"a write to an owner that is behind is refused", fun owner_behind_refuses/0} end,
      fun(_) -> {"send cuts at Mtu - 3", fun send_cuts_at_the_mtu/0} end,
      fun(_) -> {"send asks again while the link is busy", fun send_waits_while_busy/0} end,
      fun(_) -> {"an event from another domain reaches no owner", fun forged_event_dropped/0} end,
      fun(_) -> {"a serial handler of console answers console alone", fun console_serial_answers_its_service_alone/0}
      end,
      fun(_) -> {"a service without the serial shape gets no serial handler", fun misshaped_refused/0} end,
      fun(_) -> {"a run of dropped writes is one serial_lost", fun dropped_writes_are_one_loss/0} end,
      fun(_) -> {"the owner hears a link's subscription", fun subscription_reaches_the_owner/0} end,
      fun(_) -> {"a handler started before its domain holds ble attaches once it does", fun start_waits_for_the_facet/0}
      end,
      fun(_) -> {"no report of a handler that held a write shows its bytes", fun reports_show_no_bytes/0} end,
      fun(_) -> {"the echo app answers each link on its own link", fun echo_answers_each_link_alone/0} end]}.

%% A phone's bytes reach no report: once the serial handler has taken a write, its
%% status shows none of the bytes (sys:get_status/1 holds the sys log raw, as tracing
%% does, so the log stays off), and when a call that carries them crashes it, neither
%% gen_server's report, whose last message is that call, nor proc_lib's, nor the exit
%% reason its monitor sees does.
reports_show_no_bytes() ->
    {Link, Conn} = joined_link(),
    {ok, Serial} = erx_gatt_serial:start_link(nus, self()),
    unlink(Serial),
    _ = sys:get_state(Serial),
    Secret = <<"passphrase 0123456789">>,
    erx_gatt_srv ! {erx_bt_link, Link, {write, 7, {nus, rx}, Secret}},
    receive {serial, Conn, Secret} -> ok after ?WAIT_MS -> error(no_serial) end,
    ?assertEqual(nomatch, binary:match(term_to_binary(sys:get_status(Serial)), Secret)),
    Monitor = monitor(process, Serial),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{test => self()}}),
    try
        ?assertExit(_, erx_gatt_service:call(Serial, {crash, Secret})),
        receive {'DOWN', Monitor, process, Serial, Reason} -> ?assertEqual({error, function_clause}, Reason)
        after ?WAIT_MS -> error(no_end)
        end,
        Reports = reports(Serial, []),
        ?assertEqual(2, length(Reports)),
        ?assertEqual(nomatch, binary:match(term_to_binary(Reports), Secret))
    after
        logger:remove_handler(?MODULE)
    end.

%% The reports logged by Pid, which a crash logs at once, so a short wait finds them all.
reports(Pid, Reports) ->
    receive {logged, #{meta := #{pid := Pid}} = Event} -> reports(Pid, [Event | Reports])
    after 200 -> lists:reverse(Reports)
    end.

-doc false.
log(Event, #{config := #{test := Test}}) ->
    Test ! {logged, Event}.

%% A service whose rx the phone cannot write, or whose tx the machine cannot notify, is no
%% serial line: the handler stops with the refusal, and no serial handler runs. (The
%% stand-in facet's relay stays attached for the ended handler, so the case does not
%% start a second one.)
misshaped_refused() ->
    {ok, Serial} = erx_gatt_serial:start_link(misshaped, self()),
    unlink(Serial),
    Monitor = monitor(process, Serial),
    receive {'DOWN', Monitor, process, Serial, Reason} -> ?assertEqual({not_serial, misshaped}, Reason)
    after ?WAIT_MS -> error(not_stopped)
    end,
    ?assertEqual(undefined, whereis(erx_gatt_serial)).

%% An owner whose queue holds bt_write_queue messages: each of three writes is answered
%% 0x80 and one serial_lost stands for the three; a write the owner takes ends the run, so
%% the next drop is a loss of its own (docs/design-bluetooth.md, "For apps").
dropped_writes_are_one_loss() ->
    {Link, Conn} = joined_link(),
    Test = self(),
    Owner = spawn(fun() -> receive go -> ok end, owner_loop(Test) end),
    {ok, _} = erx_gatt_serial:start_link(nus, Owner),
    _ = sys:get_state(erx_gatt_serial),
    [Owner ! {filler, N} || N <- lists:seq(1, 16)],
    [begin
         erx_gatt_srv ! {erx_bt_link, Link, {write, Ref, {nus, rx}, <<Ref>>}},
         receive {from_link, Link, {registry, {answer, Ref, Answer}}} -> ?assertEqual({error, 16#80}, Answer)
         after ?WAIT_MS -> error(no_answer)
         end
     end || Ref <- [1, 2, 3]],
    {messages, Held} = process_info(Owner, messages),
    ?assertEqual([{serial_lost, Conn}], [M || M <- Held, is_stream(M)]),
    Owner ! go,
    ?assertEqual({serial_lost, Conn}, owner_heard()),
    erx_gatt_srv ! {erx_bt_link, Link, {write, 4, {nus, rx}, <<"in">>}},
    ?assertEqual({serial, Conn, <<"in">>}, owner_heard()),
    exit(Owner, kill).

%% The owner passes on the stream the serial handler sends it, its bytes and its gaps.
owner_loop(Test) ->
    receive
        Message ->
            _ = is_stream(Message) andalso (Test ! {owner, Message}),
            owner_loop(Test)
    end.

is_stream(Message) -> element(1, Message) =:= serial orelse element(1, Message) =:= serial_lost.

owner_heard() ->
    receive {owner, Message} -> Message after ?WAIT_MS -> error(nothing_heard) end.

subscription_reaches_the_owner() ->
    {Link, Conn} = joined_link(),
    {ok, _} = erx_gatt_serial:start_link(nus, self()),
    _ = sys:get_state(erx_gatt_serial),
    erx_gatt_srv ! {erx_bt_link, Link, {subscribed, {nus, tx}, notify}},
    receive {subscribed, Conn, tx, notify} -> ok after ?WAIT_MS -> error(no_subscribed) end.

write_reaches_the_owner() ->
    {Link, Conn} = joined_link(),
    {ok, _} = erx_gatt_serial:start_link(nus, self()),
    _ = sys:get_state(erx_gatt_serial),
    Bytes = binary:copy(<<"x">>, 100),
    erx_gatt_srv ! {erx_bt_link, Link, {write, 7, {nus, rx}, Bytes}},
    receive {serial, Conn, Got} -> ?assertEqual(Bytes, Got) after ?WAIT_MS -> error(no_serial) end,
    receive {from_link, Link, {registry, {answer, 7, ok}}} -> ok after ?WAIT_MS -> error(no_answer) end.

owner_behind_refuses() ->
    {Link, _Conn} = joined_link(),
    Owner = spawn(fun() -> receive stop -> ok end end),
    {ok, _} = erx_gatt_serial:start_link(nus, Owner),
    _ = sys:get_state(erx_gatt_serial),
    [Owner ! {filler, N} || N <- lists:seq(1, 16)],
    erx_gatt_srv ! {erx_bt_link, Link, {write, 7, {nus, rx}, <<"late">>}},
    receive {from_link, Link, {registry, {answer, 7, Answer}}} -> ?assertEqual({error, 16#80}, Answer)
    after ?WAIT_MS -> error(no_answer)
    end,
    {messages, Held} = process_info(Owner, messages),
    ?assertEqual([], [M || {serial, _, _} = M <- Held]),
    exit(Owner, kill).

send_cuts_at_the_mtu() ->
    {Link, Conn} = joined_link(),
    {ok, _} = erx_gatt_serial:start_link(nus, self()),
    erx_gatt_srv ! {erx_bt_link, Link, {mtu, 50}},
    mtu_heard(Conn, 50, 100),
    Sender = sender(Conn, binary:copy(<<"abcdefghij">>, 10)),
    Pieces = [notification(Link, ok) || _ <- lists:seq(1, 3)],
    ?assertEqual([47, 47, 6], [byte_size(P) || P <- Pieces]),
    ?assertEqual(binary:copy(<<"abcdefghij">>, 10), iolist_to_binary(Pieces)),
    ?assertEqual(ok, sent(Sender)).

send_waits_while_busy() ->
    {Link, Conn} = joined_link(),
    {ok, _} = erx_gatt_serial:start_link(nus, self()),
    _ = sys:get_state(erx_gatt_serial),
    Sender = sender(Conn, <<"abc">>),
    First = notification(Link, {error, busy}),
    ?assertEqual(First, notification(Link, ok)),
    ?assertEqual(ok, sent(Sender)).

forged_event_dropped() ->
    {_Link, Conn} = joined_link(),
    {ok, Serial} = erx_gatt_serial:start_link(nus, self()),
    _ = sys:get_state(Serial),
    Serial ! {erx_origin, ?OTHER, {write, make_ref(), Conn, rx, <<"forged">>}},
    Serial ! {write, make_ref(), Conn, rx, <<"bare">>},
    sync(),
    _ = sys:get_state(Serial),
    receive {serial, _, Bytes} -> error({forged, Bytes}) after 100 -> ok end.

%% A serial handler started for `console` takes console's writes and notifies console's tx;
%% a write of nus, which it was not started for, reaches no owner and is answered Unlikely
%% Error, as a service with no handler is. The handler is unlinked so that its end fails
%% the case rather than cancelling it.
console_serial_answers_its_service_alone() ->
    {Link, Conn} = joined_link(),
    {ok, Serial} = erx_gatt_serial:start_link(console, self()),
    unlink(Serial),
    _ = sys:get_state(Serial),
    erx_gatt_srv ! {erx_bt_link, Link, {write, 7, {console, rx}, <<"in">>}},
    receive {serial, Conn, Got} -> ?assertEqual(<<"in">>, Got) after ?WAIT_MS -> error(no_serial) end,
    receive {from_link, Link, {registry, {answer, 7, ok}}} -> ok after ?WAIT_MS -> error(no_answer) end,
    erx_gatt_srv ! {erx_bt_link, Link, {write, 8, {nus, rx}, <<"other">>}},
    receive {from_link, Link, {registry, {answer, 8, Answer}}} -> ?assertEqual({error, unlikely_error}, Answer)
    after ?WAIT_MS -> error(no_answer)
    end,
    Sender = sender(Conn, <<"out">>),
    ?assertEqual(<<"out">>, notification(Link, {console, tx}, ok)),
    ?assertEqual(ok, sent(Sender)),
    receive {serial, _, Bytes} -> error({other_service, Bytes}) after 100 -> ok end.

%% The echo app of examples/echo over the serial service: a write from each of two links
%% comes back on that link alone, the second link's first, so an echo that sent every
%% write to the first link to have written would send the first link's bytes to the
%% second. Nothing else is notified on either link.
echo_answers_each_link_alone() ->
    {LinkA, _ConnA} = joined_link(),
    {LinkB, _ConnB} = joined_link(),
    {ok, Echo} = erx_echo:start_link(),
    unlink(Echo),
    echoed(LinkB, 7, <<"from b">>),
    echoed(LinkA, 8, <<"from a">>),
    receive {from_link, _, {'$gen_call', _, {notify, notify, _, Piece}}} -> error({notified_again, Piece})
    after 100 -> ok
    end,
    kill(Echo).

%% A session's grants are installed only after its start has finished: the echo started
%% while the domain holds no ble answers its start at once, attaches once the facet is
%% installed, and echoes (docs/design-bluetooth.md, "The client"). The registry of
%% facets is emptied as erx_facets keeps it before any install, and erx_connections is
%% a stand-in for the connection agent, which answers a waiter once an installation has
%% followed its read.
start_waits_for_the_facet() ->
    Facet = erx_facets:find(ble),
    persistent_term:put({erx, facets}, {erx_facets:generation(), #{}}),
    Agent = spawn(fun connection_agent/0),
    register(erx_connections, Agent),
    Test = self(),
    Starter = spawn(fun() -> Test ! {started, erx_echo:start_link()}, receive stop -> ok end end),
    receive {started, {ok, _}} -> ok after ?WAIT_MS -> error(no_start) end,
    erx_facets:install(#{ble => Facet}),
    _ = sys:get_state(erx_gatt_serial),
    {Link, _Conn} = joined_link(),
    echoed(Link, 9, <<"late">>),
    [kill(P) || P <- [Starter, Agent]].

%% The connection agent's answer to changed/1: ok once the registry's generation has
%% passed the one the waiter read.
connection_agent() ->
    receive
        {'$gen_call', From, {changed, Generation}} ->
            spawn(fun() -> changed_after(From, Generation) end),
            connection_agent()
    end.

changed_after(From, Generation) ->
    case erx_facets:generation() > Generation of
        true -> gen:reply(From, ok);
        false -> timer:sleep(10), changed_after(From, Generation)
    end.

%% Link writes Bytes to nus's rx as request Id: the write is answered ok and Bytes come
%% back to Link as one notification of tx.
echoed(Link, Id, Bytes) ->
    erx_gatt_srv ! {erx_bt_link, Link, {write, Id, {nus, rx}, Bytes}},
    receive {from_link, Link, {registry, {answer, Id, ok}}} -> ok after ?WAIT_MS -> error({no_answer, Id}) end,
    ?assertEqual(Bytes, notification(Link, ok)).

%% ---- fixtures ----

%% The registry serving every declared service and console(), with the relaying facet
%% installed as ble.
start_registry() ->
    persistent_term:put(erx_dist_owner, ?BT),
    {_Registry, Facet} = Started = start_registry_only(),
    erx_facets:install(#{ble => Facet}),
    Started.

%% The registry and the relaying facet, not yet installed.
start_registry_only() ->
    Served = [erx_gatt_decl:service(Name) || Name <- erx_gatt_decl:names()] ++ [console(), misshaped()],
    {ok, Registry} = erx_gatt_srv:start_link(?GAP, Served),
    unlink(Registry),
    {Registry, spawn(fun() -> relaying_facet(#{}) end)}.

stop({Registry, Facet}) ->
    [kill(P) || P <- [whereis(erx_gatt_serial), Facet, Registry], is_pid(P)],
    ok.

kill(Pid) ->
    unlink(Pid),
    Monitor = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok end.

%% The stand-in facet: each caller's operation goes to the registry with the caller's
%% relay as the handler.
relaying_facet(Relays) ->
    receive
        {'$gen_call', {Caller, _} = From, Op} ->
            Relay = case Relays of
                        #{Caller := Known} -> Known;
                        #{} -> spawn(fun() -> link(Caller), relay(Caller) end)
                    end,
            gen_server:reply(From, erx_gatt_srv:facet(Relay, Op, ?WAIT_MS)),
            relaying_facet(Relays#{Caller => Relay})
    end.

relay(Handler) ->
    receive Event -> Handler ! {erx_origin, ?BT, Event}, relay(Handler) end.

%% A facet that answers each call with the next answer of Answers.
with_scripted_facet(Answers, Test) ->
    persistent_term:put(erx_dist_owner, ?BT),
    Facet = spawn(fun() -> scripted(Answers) end),
    erx_facets:install(#{ble => Facet}),
    try Test() after exit(Facet, kill) end.

scripted([]) ->
    receive after infinity -> ok end;
scripted([Answer | Rest]) ->
    receive {'$gen_call', From, _Op} -> gen_server:reply(From, Answer), scripted(Rest) end.

ended_pid() ->
    Pid = spawn(fun() -> ok end),
    Monitor = monitor(process, Pid),
    receive {'DOWN', Monitor, process, Pid, _} -> Pid end.

%% A link that has joined, passing on everything it receives; and its Conn.
joined_link() ->
    Test = self(),
    Conn = make_ref(),
    Link = spawn(fun() ->
                         Test ! {joined, self(), erx_gatt_srv:join(Conn, #{address => ?ADDRESS})},
                         pass_on(Test)
                 end),
    receive {joined, Link, #{table := _}} -> {Link, Conn} after ?WAIT_MS -> error(no_join) end.

pass_on(Test) ->
    receive Message -> Test ! {from_link, self(), Message}, pass_on(Test) end.

%% A stand-in for the phone console's service (docs/design-bluetooth.md, "The console"):
%% nus's serial shape under its own name, each UUID nus's with its first octet inverted so
%% the table holds each once.
console() ->
    #{uuid := Uuid, characteristics := Chars} = Nus = erx_gatt_decl:service(nus),
    Nus#{name => console, uuid => other_uuid(Uuid),
         characteristics => [C#{uuid => other_uuid(U)} || #{uuid := U} = C <- Chars]}.

other_uuid(<<First, Rest/binary>>) -> <<(First bxor 16#FF), Rest/binary>>.

%% A stand-in service of nus's names with its accesses swapped: rx only notified and tx
%% only written.
misshaped() ->
    #{uuid := Uuid, characteristics := [Rx, Tx]} = Nus = erx_gatt_decl:service(nus),
    Nus#{name => misshaped, uuid => other_uuid(second_flipped(Uuid)),
         characteristics => [Rx#{uuid => second_flipped(maps:get(uuid, Rx)), access => maps:get(access, Tx)},
                             Tx#{uuid => second_flipped(maps:get(uuid, Tx)), access => maps:get(access, Rx)}]}.

second_flipped(<<First, Second, Rest/binary>>) -> <<First, (Second bxor 16#FF), Rest/binary>>.

%% The next notification of nus's tx the registry asks Link for, answered Answer.
notification(Link, Answer) -> notification(Link, {nus, tx}, Answer).

%% The next notification of Key the registry asks Link for, answered Answer.
notification(Link, Key, Answer) ->
    receive
        {from_link, Link, {'$gen_call', From, {notify, notify, Key, Piece}}} ->
            gen_server:reply(From, Answer),
            Piece
    after ?WAIT_MS -> error(no_notification)
    end.

sender(Conn, Bytes) ->
    Test = self(),
    spawn(fun() -> Test ! {sent, self(), erx_gatt_serial:send(Conn, Bytes)} end).

sent(Sender) ->
    receive {sent, Sender, Answer} -> Answer after ?WAIT_MS -> error(no_send_answer) end.

sync() -> _ = sys:get_state(erx_gatt_srv), ok.

%% The serial handler has taken Conn's mtu event, which reaches it through the relay.
mtu_heard(Conn, Mtu, Tries) ->
    case sys:get_state(erx_gatt_serial) of
        {handler, erx_gatt_serial, _, _, {serial, _, _, #{Conn := Mtu}, _}} -> ok;
        _ when Tries > 0 -> timer:sleep(10), mtu_heard(Conn, Mtu, Tries - 1)
    end.
