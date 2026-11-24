%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The registry (docs/design-bluetooth.md, "The `ble` facet" and "The link's messages"):
%% its core, erx_gatt_registry, first case by case for each answer and refusal, then every
%% sequence of four inputs over two links, two handlers and two services checked against a
%% model of who may hear what; then its process, erx_gatt_srv, over stand-in links and
%% handlers: a join racing sets misses none, an answer is taken once and only from the
%% handler the write went to, and a link that ends with a notification pending answers its
%% caller `{error, gone}`.

-module(erx_bt_registry_tests).

-include_lib("eunit/include/eunit.hrl").

-define(WAIT_MS, 2000).
-define(GAP, #{name => <<"erxos">>, appearance => 16#03C1}).
-define(ADDRESS, {random, <<16#C0, 16#FF, 16#EE, 16#12, 16#34, 16#56>>}).
-define(IDENTITY, {public, <<16#00, 16#1B, 16#DC, 16#0A, 16#0B, 16#0C>>}).

%% ---- the core, case by case ----

services() ->
    [#{name => a, uuid => <<16#00, 16#FF>>,
       characteristics => [#{name => x, uuid => <<16#01, 16#FF>>, max => 4,
                             access => #{write => open, notify => open}}]},
     #{name => b, uuid => <<16#10, 16#FF>>,
       characteristics => [#{name => y, uuid => <<16#11, 16#FF>>, max => 4,
                             access => #{write => open, indicate => encrypted}}]}].

pid(N) -> list_to_pid("<0." ++ integer_to_list(N) ++ ".0>").

-define(L1, pid(101)).
-define(L2, pid(102)).
-define(H1, pid(201)).
-define(H2, pid(202)).

step(Input, Core) -> erx_gatt_registry:step(Input, Core).

steps(Inputs) ->
    lists:foldl(fun(Input, {_, Core}) -> step(Input, Core) end, {[], erx_gatt_registry:new(?GAP, services())}, Inputs).

attach_answers_the_limits_and_refuses_test() ->
    {Actions, _} = steps([{facet, ?H1, {attach, a}, from}]),
    ?assertEqual([{monitor, ?H1}, {reply, from, {ok, #{x => #{max => 4, access => #{write => open, notify => open}}}}}],
                 Actions),
    ?assertMatch({[{reply, f2, {error, attached}}], _},
                 steps([{facet, ?H1, {attach, a}, f1}, {facet, ?H2, {attach, a}, f2}])),
    %% A handler of two services is monitored once.
    ?assertMatch({[{reply, f2, {ok, _}}], _},
                 steps([{facet, ?H1, {attach, a}, f1}, {facet, ?H1, {attach, b}, f2}])).

attach_hears_the_live_links_test() ->
    C = make_ref(),
    {Actions, _} = steps([{join, ?L1, C, #{address => ?ADDRESS}, j},
                          {link, ?L1, {security, #{level => encrypted, bonded => true, identity => ?IDENTITY}}},
                          {facet, ?H1, {attach, a}, f}]),
    ?assertEqual({event, ?H1, {connected, C, #{address => ?ADDRESS, level => encrypted, bonded => true,
                                              identity => ?IDENTITY}}},
                 lists:last(Actions)).

%% `connected` carries the bond's identity exactly when the link reports itself bonded,
%% and the address the phone connected from in `address` either way.
connected_carries_the_identity_of_a_bonded_link_alone_test() ->
    C = make_ref(),
    {Unbonded, Core} = steps([{facet, ?H1, {attach, a}, f}, {join, ?L1, C, #{address => ?ADDRESS}, j},
                              {link, ?L1, {security, #{level => encrypted, bonded => false}}}]),
    ?assertEqual([{event, ?H1, {connected, C, #{address => ?ADDRESS, level => encrypted, bonded => false}}}],
                 Unbonded),
    {Bonded, _} = step({link, ?L1, {security, #{level => authenticated, bonded => true, identity => ?IDENTITY}}},
                       Core),
    ?assertEqual([{event, ?H1, {connected, C, #{address => ?ADDRESS, level => authenticated, bonded => true,
                                               identity => ?IDENTITY}}}],
                 Bonded).

set_refusals_test() ->
    Set = fun(Op) -> {[A], _} = steps([{facet, ?H1, {attach, a}, f0}, {facet, ?H1, Op, f}]), A end,
    ?assertEqual({reply, f, ok}, Set({set, a, x, <<1, 2, 3, 4>>})),
    ?assertEqual({reply, f, {error, too_long}}, Set({set, a, x, <<1, 2, 3, 4, 5>>})),
    ?assertEqual({reply, f, {error, no_such_characteristic}}, Set({set, a, y, <<>>})),
    ?assertEqual({reply, f, {error, badarg}}, Set({set, a, x, not_a_binary})),
    ?assertEqual({reply, f, {error, badarg}}, Set(unknown)).

notify_refusals_test() ->
    C = make_ref(),
    Joined = [{join, ?L1, C, #{address => ?ADDRESS}, j}, {facet, ?H1, {attach, a}, f0}],
    ?assertMatch({[{request, _, {notify, notify, {a, x}, <<1>>}, f}], _},
                 steps(Joined ++ [{facet, ?H1, {notify, C, a, x, <<1>>}, f}])),
    ?assertMatch({[{reply, f, {error, gone}}], _}, steps(Joined ++ [{facet, ?H1, {notify, make_ref(), a, x, <<1>>}, f}])),
    ?assertMatch({[{reply, f, {error, too_long}}], _}, steps(Joined ++ [{facet, ?H1, {indicate, C, a, x, <<1:40>>}, f}])).

%% Only a service's handler sets, notifies and indicates its values (docs/design-bluetooth.md,
%% "A service belongs to its handler"): another process, the handler of another service or
%% of none, is refused not_attached, and nothing reaches a link.
set_notify_and_indicate_only_from_the_handler_test() ->
    C = make_ref(),
    Joined = [{join, ?L1, C, #{address => ?ADDRESS}, j}, {facet, ?H1, {attach, a}, f0}, {facet, ?H2, {attach, b}, f1}],
    Refused = {error, not_attached},
    ?assertMatch({[{reply, f, Refused}], _}, steps(Joined ++ [{facet, ?H2, {set, a, x, <<1>>}, f}])),
    ?assertMatch({[{reply, f, Refused}], _}, steps(Joined ++ [{facet, ?H2, {notify, C, a, x, <<1>>}, f}])),
    ?assertMatch({[{reply, f, Refused}], _}, steps(Joined ++ [{facet, ?H2, {indicate, C, a, x, <<1>>}, f}])),
    ?assertMatch({[{reply, f, Refused}], _}, steps([{facet, ?H1, {set, a, x, <<1>>}, f}])),
    %% A handler's end detaches it, so its next set is refused too.
    ?assertMatch({[{reply, f, Refused}], _}, steps(Joined ++ [{down, ?H1}, {facet, ?H1, {set, a, x, <<1>>}, f}])).

write_without_a_handler_is_unlikely_error_test() ->
    {Actions, _} = steps([{join, ?L1, make_ref(), #{address => ?ADDRESS}, j}, {write, ?L1, 1, {b, y}, <<0>>, req}]),
    ?assertEqual([{to_link, ?L1, {answer, 1, {error, unlikely_error}}}], Actions).

subscription_goes_to_its_service_alone_test() ->
    C = make_ref(),
    {Actions, _} = steps([{facet, ?H1, {attach, a}, f1}, {facet, ?H2, {attach, b}, f2},
                          {join, ?L1, C, #{address => ?ADDRESS}, j}, {link, ?L1, {subscribed, {b, y}, indicate}}]),
    ?assertEqual([{event, ?H2, {subscribed, C, y, indicate}}], Actions).

%% ---- the core, every sequence against a model ----

%% The model: the links joined and their Conn, those ended, the handlers attached, the
%% writes delivered and not yet answered, the values set and the count of writes, which
%% numbers each write's Req.
-record(model, {joined = #{}, ended = [], handlers = #{}, delivered = #{}, values = #{}, writes = 0}).

conn(L) -> maps:get(L, #{?L1 => c1, ?L2 => c2}).

%% The inputs, each a function of the model, since a write's Req is the one the core is
%% handed and a reply names the last one delivered.
alphabet() ->
    [{join, ?L1}, {join, ?L2}, {write, ?L1, {a, x}}, {write, ?L2, {b, y}},
     {attach, ?H1, a}, {attach, ?H2, b}, {attach, ?H2, a}, {attach, ?H1, b},
     {set, ?H1, <<7>>}, {notify, ?L1}, {notify, ?L2},
     {reply, ?H1}, {reply, ?H2}, {reply_earlier, ?H1}, {down, ?L1}, {down, ?H1}, {security, ?L2}].

%% From the empty registry, and from one where H1 handles a and L1 has joined, so that a
%% write, the link's end and a late answer fit in four steps.
every_sequence_of_four_keeps_the_model_test_() ->
    {timeout, 300, fun() ->
        Empty = erx_gatt_registry:new(?GAP, services()),
        {Model, Core} = lists:foldl(fun(Symbol, {M, C}) ->
                                            Input = input(Symbol, M),
                                            {Actions, Next} = step(Input, C),
                                            {check(Input, Actions, M), Next}
                                    end, {#model{}, Empty}, [{attach, ?H1, a}, {join, ?L1}]),
        ?assert(walk(4, alphabet(), #model{}, Empty, 0) > 10000),
        ?assert(walk(4, alphabet(), Model, Core, 0) > 10000)
    end}.

walk(0, _Alphabet, _Model, _Core, Count) ->
    Count + 1;
walk(Depth, Alphabet, Model, Core, Count) ->
    lists:foldl(fun(Symbol, Acc) ->
                        case input(Symbol, Model) of
                            skip -> Acc;
                            Input ->
                                {Actions, Next} = step(Input, Core),
                                walk(Depth - 1, Alphabet, check(Input, Actions, Model), Next, Acc)
                        end
                end, Count, Alphabet).

%% A link joins once and never after its end, as a link process does.
input({join, L}, #model{joined = J, ended = E}) ->
    case is_map_key(L, J) orelse lists:member(L, E) of
        true -> skip;
        false -> {join, L, conn(L), #{address => ?ADDRESS}, from}
    end;
input({write, L, Key}, #model{writes = N}) -> {write, L, 1, Key, <<1>>, {req, N}};
input({attach, H, S}, _M) -> {facet, H, {attach, S}, from};
input({set, H, V}, _M) -> {facet, H, {set, a, x, V}, from};
input({notify, L}, _M) -> {facet, ?H1, {notify, conn(L), a, x, <<1>>}, from};
input({reply, H}, #model{writes = N}) -> {facet, H, {reply, {req, N - 1}, ok}, from};
input({reply_earlier, H}, #model{writes = N}) -> {facet, H, {reply, {req, N - 2}, ok}, from};
input({down, P}, _M) -> {down, P};
input({security, L}, _M) -> {link, L, {security, #{level => encrypted, bonded => false}}}.

%% Checks one step's actions against the model and returns the model after it.
check({join, L, C, _, From}, Actions, #model{joined = J, values = V} = M) ->
    ?assertEqual(1, length([ok || {reply, F, #{values := Values}} <- Actions, F =:= From, Values =:= V])),
    events_only_to_handlers(Actions, M),
    M#model{joined = J#{L => C}};
check({write, L, Ref, {S, _}, _, Req}, Actions, #model{joined = J, handlers = H, delivered = D, writes = N} = M0) ->
    %% A link's new write supersedes its earlier one.
    M = M0#model{writes = N + 1, delivered = #{R => W || R := {_, L1, _} = W <- D, L1 =/= L}},
    case {J, H} of
        {#{L := _}, #{S := Handler}} ->
            ?assertMatch([{event, Handler, {write, Req, _, _, _}}], Actions),
            M#model{delivered = (M#model.delivered)#{Req => {Handler, L, Ref}}};
        {#{L := _}, _} ->
            ?assertEqual([{to_link, L, {answer, Ref, {error, unlikely_error}}}], Actions),
            M;
        _ ->
            ?assertEqual([], Actions),
            M
    end;
check({facet, Caller, {reply, Req, _}, From}, Actions, #model{delivered = D} = M) ->
    case D of
        #{Req := {Caller, L, Ref}} ->
            ?assertEqual([{reply, From, ok}, {to_link, L, {answer, Ref, ok}}], Actions),
            M#model{delivered = maps:remove(Req, D)};
        #{} ->
            ?assertEqual([{reply, From, ok}], Actions),
            M
    end;
check({facet, Caller, {attach, S}, From}, Actions, #model{handlers = H} = M) ->
    case H of
        #{S := _} -> ?assertEqual([{reply, From, {error, attached}}], Actions), M;
        #{} ->
            ?assertEqual(1, length([ok || {reply, _, {ok, _}} <- Actions])),
            Hears = case lists:member(Caller, maps:values(H)) of
                        true -> 0;
                        false -> map_size(M#model.joined)
                    end,
            ?assertEqual(Hears, length([ok || {event, P, {connected, _, _}} <- Actions, P =:= Caller])),
            M#model{handlers = H#{S => Caller}}
    end;
check({facet, Caller, Op, From}, Actions, #model{handlers = H} = M)
  when element(1, Op) =:= set, map_get(element(2, Op), H) =/= Caller;
       element(1, Op) =:= set, not is_map_key(element(2, Op), H);
       element(1, Op) =:= notify, map_get(element(3, Op), H) =/= Caller;
       element(1, Op) =:= notify, not is_map_key(element(3, Op), H) ->
    ?assertEqual([{reply, From, {error, not_attached}}], Actions),
    M;
check({facet, _Caller, {set, S, C, V}, From}, Actions, #model{joined = J, values = Values} = M) ->
    ?assertEqual([{reply, From, ok} | [{to_link, L, {set, {S, C}, V}} || L <- lists:sort(maps:keys(J))]], Actions),
    M#model{values = Values#{{S, C} => V}};
check({facet, _Caller, {notify, C, _, _, _}, From}, Actions, #model{joined = J} = M) ->
    case [L || L := Conn <- J, Conn =:= C] of
        [L] -> ?assertMatch([{request, L, {notify, notify, _, _}, From}], Actions);
        [] -> ?assertEqual([{reply, From, {error, gone}}], Actions)
    end,
    M;
check({down, P}, Actions, #model{joined = J, handlers = H, delivered = D, ended = E} = M) ->
    case J of
        #{P := C} ->
            ?assertEqual(lists:usort(maps:values(H)), [Handler || {event, Handler, {disconnected, C1}} <- Actions, C1 =:= C]),
            M#model{joined = maps:remove(P, J), ended = [P | E],
                    delivered = #{R => W || R := {_, L, _} = W <- D, L =/= P}};
        #{} ->
            ?assertEqual([], Actions),
            M#model{handlers = #{S => X || S := X <- H, X =/= P},
                    delivered = #{R => W || R := {X, _, _} = W <- D, X =/= P}}
    end;
check({link, L, {security, _}}, Actions, #model{joined = J} = M) ->
    case J of
        #{L := _} -> events_only_to_handlers(Actions, M);
        #{} -> ?assertEqual([], Actions)
    end,
    M.

events_only_to_handlers(Actions, #model{handlers = H}) ->
    Handlers = lists:usort(maps:values(H)),
    ?assertEqual(Handlers, lists:sort([P || {event, P, _} <- Actions])).

%% ---- the process, over stand-ins ----

registry_test_() ->
    {foreach,
     fun() -> {ok, Pid} = erx_gatt_srv:start_link(?GAP, services()), unlink(Pid), Pid end,
     fun stop/1,
     [fun(_) -> {"a join racing sets misses none", fun join_races_sets/0} end,
      fun(_) -> {"an answer is taken once, from its handler", fun answer_only_from_its_handler/0} end,
      fun(_) -> {"a link ending mid-notification answers gone", fun link_ends_mid_notification/0} end,
      fun(_) -> {"a notification's answer reaches the caller", fun notification_answered/0} end]}.

%% A handler sets 1..100, then 101..200 while a link joins: the link's values, then the
%% sets it hears, end at the last value, and the sets it hears follow the joined value
%% without a gap. The first hundred are set before the join, so a join answering no
%% values misses them on any schedule.
join_races_sets() ->
    Test = self(),
    Set = fun(Ns) -> [ok = erx_gatt_srv:facet(self(), {set, a, x, <<N:16>>}, ?WAIT_MS) || N <- Ns] end,
    Setter = spawn_link(fun() ->
                                {ok, _} = erx_gatt_srv:facet(self(), {attach, a}, ?WAIT_MS),
                                Set(lists:seq(1, 100)),
                                Test ! first_sets,
                                receive go -> ok end,
                                Set(lists:seq(101, 200)),
                                Test ! set_done
                        end),
    Link = link_stand_in(Test),
    receive first_sets -> ok after ?WAIT_MS -> error(no_sets) end,
    Setter ! go,
    Link ! join,
    #{values := Values} = receive {joined, Link, Answer} -> Answer after ?WAIT_MS -> error(no_join) end,
    receive set_done -> ok after ?WAIT_MS -> error(no_sets) end,
    First = case Values of #{{a, x} := <<V:16>>} -> V; #{} -> 0 end,
    Heard = heard_sets(Link),
    ?assertEqual(lists:seq(First + 1, 200), Heard).

heard_sets(Link) ->
    receive {from_link, Link, {registry, {set, {a, x}, <<N:16>>}}} -> [N | heard_sets(Link)]
    after 200 -> []
    end.

answer_only_from_its_handler() ->
    H1 = handler_stand_in(self(), a),
    H2 = handler_stand_in(self(), b),
    Link = joined_link(),
    erx_gatt_srv ! {erx_bt_link, Link, {write, 7, {a, x}, <<1>>}},
    Req = receive {handler, H1, {write, R, _Conn, x, <<1>>}} -> R after ?WAIT_MS -> error(no_write) end,
    ok = erx_gatt_srv:facet(H2, {reply, Req, ok}, ?WAIT_MS),
    ok = erx_gatt_srv:facet(H1, {reply, make_ref(), ok}, ?WAIT_MS),
    ok = erx_gatt_srv:facet(H1, {reply, Req, {error, 16#80}}, ?WAIT_MS),
    ok = erx_gatt_srv:facet(H1, {reply, Req, ok}, ?WAIT_MS),
    sync(),
    ?assertEqual([{registry, {answer, 7, {error, 16#80}}}], drain(Link)).

link_ends_mid_notification() ->
    H1 = handler_stand_in(self(), a),
    {Link, Conn} = joined_link_conn(),
    H1 ! {do, {notify, Conn, a, x, <<1>>}},
    receive {from_link, Link, {'$gen_call', _From, {notify, notify, {a, x}, <<1>>}}} -> ok after ?WAIT_MS -> error(no_request) end,
    Link ! stop,
    ?assertEqual({error, gone}, caller_answer(H1)),
    receive {handler, H1, {disconnected, Conn}} -> ok after ?WAIT_MS -> error(no_disconnected) end,
    ?assertEqual({error, gone}, erx_gatt_srv:facet(H1, {notify, Conn, a, x, <<1>>}, ?WAIT_MS)).

notification_answered() ->
    {Link, Conn} = joined_link_conn(),
    H2 = handler_stand_in(self(), b),
    H2 ! {do, {indicate, Conn, b, y, <<2>>}},
    receive {from_link, Link, {'$gen_call', From, {notify, indicate, {b, y}, <<2>>}}} -> gen_server:reply(From, ok)
    after ?WAIT_MS -> error(no_request)
    end,
    ?assertEqual(ok, caller_answer(H2)).

%% What the advertising carries (docs/design-bluetooth.md, "Advertising"): the UUIDs of
%% the served services abi/gatt marks `advertise`, and GAP's name and appearance. Every
%% declared service is served (erx_bt_sup), so the declared set must fit the advertising
%% data, which erx_bt_adv:data/1 refuses with badarg.
advertised_test() ->
    Nus = erx_gatt_decl:service(nus),
    ?assertEqual(maps:put(uuids, [maps:get(uuid, Nus)], ?GAP), advertised([Nus | services()])),
    ?assertEqual(maps:put(uuids, [], ?GAP), advertised(services())),
    Declared = [erx_gatt_decl:service(Name) || Name <- erx_gatt_decl:names()],
    #{advertising_data := _} = erx_bt_adv:data(advertised(Declared)).

advertised(Services) ->
    {ok, Pid} = erx_gatt_srv:start_link(?GAP, Services),
    unlink(Pid),
    try erx_gatt_srv:advertised() after stop(Pid) end.

%% GAP's values from the application keys: the configured name, the bare host name
%% of the node name by default, the 248-octet bound, text alone, and a 16-bit appearance.
gap_from_the_keys_test() ->
    ?assertEqual(#{name => <<"bt">>, appearance => 16#03C1}, erx_bt_sup:gap({ok, "bt"}, {ok, 16#03C1}, 'a@b')),
    ?assertEqual(#{name => <<"erxos">>, appearance => 0}, erx_bt_sup:gap(undefined, undefined, 'bt@erxos')),
    ?assertEqual(#{name => <<"pi">>, appearance => 0}, erx_bt_sup:gap(undefined, undefined, 'bt@pi.example.com')),
    Longest = binary:copy(<<"a">>, 248),
    ?assertMatch(#{name := Longest}, erx_bt_sup:gap({ok, Longest}, undefined, 'a@b')),
    [?assertError({bad_name, Name}, erx_bt_sup:gap({ok, Name}, undefined, 'a@b'))
     || Name <- [<<Longest/binary, "a">>, <<16#FF>>, erxos]],
    [?assertError({bad_appearance, A}, erx_bt_sup:gap(undefined, {ok, A}, 'a@b')) || A <- [-1, 16#10000, foo]].

%% Ends the registry and waits for its end, so the next case can register its own.
stop(Pid) ->
    Monitor = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok end.

%% ---- the stand-ins ----

%% A link: joins on `join` and passes on everything it receives; ends on `stop`.
link_stand_in(Test) ->
    spawn(fun() -> link_loop(Test) end).

link_loop(Test) ->
    receive
        join ->
            Answer = erx_gatt_srv:join(make_ref(), #{address => ?ADDRESS}),
            Test ! {joined, self(), Answer},
            link_loop(Test);
        {join, Conn} ->
            Test ! {joined, self(), erx_gatt_srv:join(Conn, #{address => ?ADDRESS})},
            link_loop(Test);
        stop ->
            ok;
        Message ->
            Test ! {from_link, self(), Message},
            link_loop(Test)
    end.

joined_link() -> element(1, joined_link_conn()).

joined_link_conn() ->
    Conn = make_ref(),
    Link = link_stand_in(self()),
    Link ! {join, Conn},
    receive {joined, Link, #{table := _}} -> {Link, Conn} after ?WAIT_MS -> error(no_join) end.

%% A handler of Service: attaches, passes on its events and makes the operation of each
%% `{do, Op}`, answering it to the test.
handler_stand_in(Test, Service) ->
    Pid = spawn(fun() ->
                        {ok, _} = erx_gatt_srv:facet(self(), {attach, Service}, ?WAIT_MS),
                        Test ! {attached, self()},
                        handler_loop(Test)
                end),
    receive {attached, Pid} -> Pid after ?WAIT_MS -> error(no_attach) end.

handler_loop(Test) ->
    receive
        {do, Op} -> Test ! {answer, self(), erx_gatt_srv:facet(self(), Op, 10 * ?WAIT_MS)};
        Event -> Test ! {handler, self(), Event}
    end,
    handler_loop(Test).

caller_answer(Caller) ->
    receive {answer, Caller, Answer} -> Answer after ?WAIT_MS -> error(no_answer) end.

%% The registry has stepped everything sent to it before.
sync() -> _ = sys:get_state(erx_gatt_srv), ok.

drain(Link) ->
    receive {from_link, Link, Message} -> [Message | drain(Link)] after 100 -> [] end.
