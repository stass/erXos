%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the web domain's relay of the host link's `web` facet
%% (erx_web_relay, erx_web_relay_conn; docs/design-web.md, "The host tool's front
%% end"): requests made as its facet forwards them, with the test as each
%% connection's sink, and the facet's own admission. The mint and the facet's
%% export run end to end in a booted image.
-module(erx_web_relay_tests).

-include_lib("eunit/include/eunit.hrl").

-define(BUILD, <<"00000000000000ff">>).
-define(ROOT_LINE, #{principal => <<"root">>, build => ?BUILD}).

relay() ->
    {ok, Relay} = erx_web_relay:start_link(#{system => 4}),
    Relay.

connect(Relay, Sink, C) -> gen_server:call(Relay, {connect, Sink, C, ?ROOT_LINE}).
data(Relay, Sink, C, Message) ->
    {ok, Bytes} = erx_web_proto:encode(browser, Message),
    gen_server:call(Relay, {data, Sink, C, Bytes}).

%% What the sink was sent for connection C, decoded.
sent(C) ->
    receive
        {web, C, Bytes} -> {ok, Message} = erx_web_proto:decode(machine, Bytes), Message;
        {web_closed, C, Reason} -> {closed, Reason}
    after 5000 -> error(nothing_sent)
    end.

nothing_sent() ->
    receive {web, _, _} = M -> error({sent, M}); {web_closed, _, _} = M -> error({sent, M})
    after 100 -> ok
    end.

conns(Relay) ->
    {links, Links} = erlang:process_info(Relay, links),
    lists:sort(Links -- [self()]).

%% A connection greets with the line it was bound to, answers a view it cannot open
%% `ended unsupported`, and ends with `bye protocol` and its close on a message the
%% codec refuses, after which it takes no data.
hello_welcome_and_bye_test() ->
    Relay = relay(),
    ?assertEqual(ok, connect(Relay, self(), 3)),
    ?assertEqual(ok, data(Relay, self(), 3, {hello, erx_web_proto:hash()})),
    ?assertEqual({welcome, <<"root">>, ?BUILD}, sent(3)),
    ?assertEqual(ok, data(Relay, self(), 3, {open, 1, {path, []}})),
    ?assertEqual({ended, 1, <<"unsupported">>}, sent(3)),
    ?assertEqual(ok, gen_server:call(Relay, {data, self(), 3, <<255, 0>>})),
    ?assertEqual({bye, protocol}, sent(3)),
    ?assertEqual({closed, protocol}, sent(3)),
    ?assertEqual([], wait_conns(Relay, [])),
    ?assertEqual({error, closed}, gen_server:call(Relay, {data, self(), 3, <<>>})).

%% A sink holds at most four connections, and a number it has open cannot open again;
%% another sink has its own.
bounds_test() ->
    Relay = relay(),
    [?assertEqual(ok, connect(Relay, self(), C)) || C <- [1, 2, 3, 4]],
    ?assertEqual({error, busy}, connect(Relay, self(), 5)),
    ?assertEqual({error, badarg}, connect(Relay, self(), 1)),
    Other = spawn_link(fun() -> receive stop -> ok end end),
    ?assertEqual(ok, connect(Relay, Other, 1)),
    ?assertEqual({error, badarg}, gen_server:call(Relay, {connect, Other, 9, #{principal => 1, build => ?BUILD}})),
    ?assertEqual({error, badarg}, gen_server:call(Relay, {open, self(), 9})),
    ?assertEqual(5, length(conns(Relay))),
    Other ! stop.

%% A connection the host closes ends without a word to the sink and frees its number;
%% closing one that is not open is ok.
close_test() ->
    Relay = relay(),
    ?assertEqual(ok, connect(Relay, self(), 3)),
    ?assertEqual(ok, gen_server:call(Relay, {close, self(), 3})),
    ?assertEqual([], wait_conns(Relay, [])),
    nothing_sent(),
    ?assertEqual(ok, gen_server:call(Relay, {close, self(), 3})),
    ?assertEqual(ok, connect(Relay, self(), 3)).

%% A connection ends with its sink, the system domain's process of one host session.
ends_with_its_sink_test() ->
    Relay = relay(),
    Sink = spawn(fun() -> receive stop -> ok end end),
    ?assertEqual(ok, connect(Relay, Sink, 3)),
    ?assertEqual(ok, connect(Relay, self(), 3)),
    ?assertEqual(2, length(conns(Relay))),
    Sink ! stop,
    ?assertEqual(1, length(wait_conns(Relay, 1))).

%% The facet forwards the system domain's three requests to the relay with the caller as
%% the sink, and refuses any other shape.
facet_admission_test() ->
    Relay = self(),
    Sink = spawn(fun() -> ok end),
    ?assertEqual({forward, Relay, {connect, Sink, 3, ?ROOT_LINE}, Relay},
                 erx_web_relay:admit({connect, 3, ?ROOT_LINE}, Sink, Relay)),
    ?assertEqual({forward, Relay, {data, Sink, 3, <<"b">>}, Relay}, erx_web_relay:admit({data, 3, <<"b">>}, Sink, Relay)),
    ?assertEqual({forward, Relay, {close, Sink, 3}, Relay}, erx_web_relay:admit({close, 3}, Sink, Relay)),
    [?assertEqual({refuse, badarg, Relay}, erx_web_relay:admit(Bad, Sink, Relay))
     || Bad <- [{connect, 3}, {connect, -1, ?ROOT_LINE}, {connect, 3, #{principal => <<"root">>}},
                {data, 3, "b"}, {close, 1 bsl 32}, {open, 3}, close]].

%% The connections once their number is N, or the list is Want, waiting for exits.
wait_conns(Relay, Want) -> wait_conns(Relay, Want, 50).

wait_conns(Relay, _Want, 0) -> conns(Relay);
wait_conns(Relay, Want, Tries) ->
    Conns = conns(Relay),
    case Conns =:= Want orelse length(Conns) =:= Want of
        true -> Conns;
        false -> timer:sleep(20), wait_conns(Relay, Want, Tries - 1)
    end.
