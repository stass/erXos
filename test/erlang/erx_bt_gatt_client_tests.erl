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
    %% `identity` comes exactly with `bonded` true, and is an address.
    Bonded = Connected#{bonded => true, identity => ?IDENTITY},
    ?assertEqual({ok, {connected, C, Bonded}}, erx_gatt:event(?BT, {erx_origin, ?BT, {connected, C, Bonded}})),
    [?assertEqual(unknown, erx_gatt:event(?BT, {erx_origin, ?BT, {connected, C, Info}}))
     || Info <- [Connected#{identity => ?IDENTITY}, Connected#{bonded => true},
                 Bonded#{identity => {random, <<1, 2, 3>>}}, Bonded#{extra => 1}]].

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
      end]}.

write_reaches_the_owner() ->
    {Link, Conn} = joined_link(),
    {ok, _} = erx_gatt_serial:start_link(nus, self()),
    Bytes = binary:copy(<<"x">>, 100),
    erx_gatt_srv ! {erx_bt_link, Link, {write, 7, {nus, rx}, Bytes}},
    receive {serial, Conn, Got} -> ?assertEqual(Bytes, Got) after ?WAIT_MS -> error(no_serial) end,
    receive {from_link, Link, {registry, {answer, 7, ok}}} -> ok after ?WAIT_MS -> error(no_answer) end.

owner_behind_refuses() ->
    {Link, _Conn} = joined_link(),
    Owner = spawn(fun() -> receive stop -> ok end end),
    {ok, _} = erx_gatt_serial:start_link(nus, Owner),
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
    Sender = sender(Conn, <<"abc">>),
    First = notification(Link, {error, busy}),
    ?assertEqual(First, notification(Link, ok)),
    ?assertEqual(ok, sent(Sender)).

forged_event_dropped() ->
    {_Link, Conn} = joined_link(),
    {ok, Serial} = erx_gatt_serial:start_link(nus, self()),
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

%% ---- fixtures ----

%% The registry serving every declared service and console(), with the relaying facet
%% installed as ble.
start_registry() ->
    persistent_term:put(erx_dist_owner, ?BT),
    Served = [erx_gatt_decl:service(Name) || Name <- erx_gatt_decl:names()] ++ [console()],
    {ok, Registry} = erx_gatt_srv:start_link(?GAP, Served),
    unlink(Registry),
    Facet = spawn(fun() -> relaying_facet(#{}) end),
    erx_facets:install(#{ble => Facet}),
    {Registry, Facet}.

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
        {handler, erx_gatt_serial, _, _, {serial, _, _, #{Conn := Mtu}}} -> ok;
        _ when Tries > 0 -> timer:sleep(10), mtu_heard(Conn, Mtu, Tries - 1)
    end.
