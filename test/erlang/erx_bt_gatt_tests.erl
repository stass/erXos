%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of the GATT server's cores (docs/design-bluetooth.md, "Host tests of the cores"):
%% L2CAP's frames on the fixed channels (erx_l2cap), the gate (erx_gatt_gate), the attribute
%% table (erx_gatt_db) and the ATT server (erx_att, erx_gatt_server), whose bearer is also
%% explored over every state a small alphabet of PDUs and answers reaches. Every PDU here is
%% written from the numbers of the Core Specification 6.3, Vol 3 Parts A, F and G, not from
%% the modules' codes, so a code misread there disagrees with this module.
-module(erx_bt_gatt_tests).

-include_lib("eunit/include/eunit.hrl").

-define(OPEN, #{key => none, encrypted => false, bonded => false}).
-define(JUST_WORKS, #{key => encrypted, encrypted => true, bonded => false}).
-define(PASSKEY, #{key => authenticated, encrypted => true, bonded => false}).
-define(WRITES, 4).
%% GAP's values, which the table's Device Name and Appearance read with no handler.
-define(GAP, #{name => <<"erxos">>, appearance => 16#03C1}).

%% Two served services, given out of name order: nus, as the design's example declares it,
%% and sec, with a long readable value and an indication, both above `open`.
services() ->
    [#{name => sec, uuid => uuid("0000aaaa-0000-4000-8000-00000000beef"),
       characteristics => [#{name => key, uuid => uuid("0000aaab-0000-4000-8000-00000000beef"), max => 512,
                             access => #{read => encrypted, write => authenticated}, value => <<"initial">>},
                           #{name => ind, uuid => <<16#F0, 16#FF>>, max => 20,
                             access => #{indicate => encrypted, read => open}}]},
     #{name => nus, uuid => uuid("6e400001-b5a3-f393-e0a9-e50e24dcca9e"),
       characteristics => [#{name => rx, uuid => uuid("6e400002-b5a3-f393-e0a9-e50e24dcca9e"), max => 244,
                             access => #{write => open, write_without_response => open}},
                           #{name => tx, uuid => uuid("6e400003-b5a3-f393-e0a9-e50e24dcca9e"), max => 244,
                             access => #{notify => open}}]}].

%% A UUID's string form as ATT carries it, least significant octet first.
uuid(String) ->
    Bin = binary:decode_hex(iolist_to_binary(string:replace(String, "-", "", all))),
    list_to_binary(lists:reverse(binary_to_list(Bin))).

table() -> erx_gatt_db:build(?GAP, services()).

server(Security) -> server(Security, #{}).
server(Security, Values) -> #{table => table(), values => Values, security => Security}.

%% The table written out by hand from Part G, 3.1, 3.3 and 7.1: handle, type, value.
expected() ->
    Nus = uuid("6e400001-b5a3-f393-e0a9-e50e24dcca9e"),
    Rx = uuid("6e400002-b5a3-f393-e0a9-e50e24dcca9e"),
    Tx = uuid("6e400003-b5a3-f393-e0a9-e50e24dcca9e"),
    Sec = uuid("0000aaaa-0000-4000-8000-00000000beef"),
    Key = uuid("0000aaab-0000-4000-8000-00000000beef"),
    [{1, <<16#00, 16#28>>, <<16#00, 16#18>>},
     {2, <<16#03, 16#28>>, <<16#02, 3, 0, 16#00, 16#2A>>},
     {3, <<16#00, 16#2A>>, <<"erxos">>},
     {4, <<16#03, 16#28>>, <<16#02, 5, 0, 16#01, 16#2A>>},
     {5, <<16#01, 16#2A>>, <<16#C1, 16#03>>},
     {6, <<16#00, 16#28>>, <<16#01, 16#18>>},
     {7, <<16#03, 16#28>>, <<16#20, 8, 0, 16#05, 16#2A>>},
     {8, <<16#05, 16#2A>>, none},
     {9, <<16#02, 16#29>>, <<0, 0>>},
     {10, <<16#00, 16#28>>, Nus},
     {11, <<16#03, 16#28>>, <<16#0C, 12, 0, Rx/binary>>},
     {12, Rx, none},
     {13, <<16#03, 16#28>>, <<16#10, 14, 0, Tx/binary>>},
     {14, Tx, none},
     {15, <<16#02, 16#29>>, <<0, 0>>},
     {16, <<16#00, 16#28>>, Sec},
     {17, <<16#03, 16#28>>, <<16#0A, 18, 0, Key/binary>>},
     {18, Key, <<"initial">>},
     {19, <<16#03, 16#28>>, <<16#22, 20, 0, 16#F0, 16#FF>>},
     {20, <<16#F0, 16#FF>>, <<>>},
     {21, <<16#02, 16#29>>, <<0, 0>>}].

values() -> #{{gap, device_name} => <<"erxos">>}.

%% PDUs a phone sends (Part F, 3.4).
mtu_req(Mtu) -> <<16#02, Mtu:16/little>>.
find_info(S, E) -> <<16#04, S:16/little, E:16/little>>.
find_by_type_value(S, E, Type, Value) -> <<16#06, S:16/little, E:16/little, Type:16/little, Value/binary>>.
read_by_type(S, E, Type) -> <<16#08, S:16/little, E:16/little, Type/binary>>.
read(H) -> <<16#0A, H:16/little>>.
read_blob(H, Offset) -> <<16#0C, H:16/little, Offset:16/little>>.
read_by_group_type(S, E, Type) -> <<16#10, S:16/little, E:16/little, Type/binary>>.
write(H, V) -> <<16#12, H:16/little, V/binary>>.
write_cmd(H, V) -> <<16#52, H:16/little, V/binary>>.
prepare(H, Offset, Part) -> <<16#16, H:16/little, Offset:16/little, Part/binary>>.
execute(Flags) -> <<16#18, Flags>>.
confirm() -> <<16#1E>>.
error_rsp(Op, H, Code) -> <<16#01, Op, H:16/little, Code>>.

%% One request on a bearer: the PDUs sent and the other actions, and the bearer after.
ask(Pdu, Server, Bearer) ->
    {Actions, Next} = erx_gatt_server:request(Pdu, Server, Bearer),
    {[P || {send, P} <- Actions], [A || A <- Actions, not is_tuple(A) orelse element(1, A) =/= send], Next}.

%% A configuration write that changes the configuration, given as `configure` and answered
%% `ok`, as the link answers one on a link with no kept bond: the response and events of
%% the answer, and the bearer after it.
configured(Pdu, Server, Bearer) ->
    {[], [{configure, Ref, _Key, _Kind}], Asked} = ask(Pdu, Server, Bearer),
    {Actions, Next} = erx_gatt_server:reply(Ref, ok, Server, Asked),
    {[P || {send, P} <- Actions], [A || A <- Actions, element(1, A) =/= send], Next}.

%% The one response a request gets at once.
answer(Pdu, Server, Bearer) ->
    {[Response], [], _} = ask(Pdu, Server, Bearer),
    Response.

with_mtu(Mtu) ->
    {_, _, Bearer} = ask(mtu_req(Mtu), server(?OPEN), erx_gatt_server:new()),
    Bearer.

%% ---- erx_l2cap ----

reassembly_at_every_fragment_size_test() ->
    Payload = list_to_binary(lists:seq(1, 247)),
    Frame = <<247:16/little, 4:16/little, Payload/binary>>,
    [?assertEqual({frame, 4, Payload}, feed(chunks(Frame, Size))) || Size <- lists:seq(1, byte_size(Frame))].

feed([First | Rest]) ->
    lists:foldl(fun(Piece, {more, Partial}) -> erx_l2cap:reassemble(1, Piece, Partial) end,
                erx_l2cap:reassemble(2, First, none), Rest).

chunks(<<>>, _Size) -> [];
chunks(Bytes, Size) when byte_size(Bytes) =< Size -> [Bytes];
chunks(Bytes, Size) -> <<Piece:Size/binary, Rest/binary>> = Bytes, [Piece | chunks(Rest, Size)].

continuation_without_start_ends_the_link_test() ->
    ?assertEqual({error, continuation_without_start}, erx_l2cap:reassemble(1, <<1, 0, 4, 0, 0>>, none)).

start_inside_a_frame_ends_the_link_test() ->
    {more, Partial} = erx_l2cap:reassemble(2, <<5, 0, 4, 0, 1>>, none),
    ?assertEqual({error, start_inside_frame}, erx_l2cap:reassemble(2, <<1, 0, 4, 0, 1>>, Partial)).

frame_past_its_channel_bound_is_refused_test() ->
    ?assertMatch({more, _}, erx_l2cap:reassemble(2, <<247:16/little, 4:16/little>>, none)),
    ?assertEqual({error, {too_long, 4, 248}}, erx_l2cap:reassemble(2, <<248:16/little, 4:16/little>>, none)),
    ?assertMatch({more, _}, erx_l2cap:reassemble(2, <<65:16/little, 6:16/little>>, none)),
    ?assertEqual({error, {too_long, 6, 66}}, erx_l2cap:reassemble(2, <<66:16/little, 6:16/little>>, none)),
    ?assertEqual({error, {too_long, 9, 248}}, erx_l2cap:reassemble(2, <<248:16/little, 9:16/little>>, none)).

bytes_past_the_frame_and_foreign_flags_are_refused_test() ->
    ?assertEqual({error, overrun}, erx_l2cap:reassemble(2, <<1, 0, 4, 0, 1, 2>>, none)),
    ?assertEqual({error, {bad_boundary, 0}}, erx_l2cap:reassemble(0, <<1, 0, 4, 0, 1>>, none)),
    ?assertEqual({error, {bad_boundary, 3}}, erx_l2cap:reassemble(3, <<1, 0, 4, 0, 1>>, none)).

fragments_cut_at_the_controller_length_test() ->
    Payload = list_to_binary(lists:seq(1, 100)),
    [{0, First} | Rest] = Fragments = erx_l2cap:fragments(4, Payload, 27),
    ?assertEqual(<<100:16/little, 4:16/little>>, binary:part(First, 0, 4)),
    ?assert(lists:all(fun({B, D}) -> B =:= 1 andalso byte_size(D) =< 27 end, Rest)),
    ?assertEqual({frame, 4, Payload}, feed([D || {_, D} <- Fragments])),
    ?assertEqual([{0, <<0, 0, 4, 0>>}], erx_l2cap:fragments(4, <<>>, 27)).

le_signaling_rejects_requests_and_drops_responses_test() ->
    %% A Connection Parameter Update Request (0x12), identifier 7: Command not understood.
    ?assertEqual({reply, <<16#01, 7, 2, 0, 0, 0>>}, erx_l2cap:signal(<<16#12, 7, 8, 0, 0:64>>)),
    ?assertEqual({reply, <<16#01, 9, 2, 0, 0, 0>>}, erx_l2cap:signal(<<16#FE, 9, 0, 0>>)),
    [?assertEqual(drop, erx_l2cap:signal(<<Code, 1, 2, 0, 0, 0>>)) || Code <- [16#01, 16#07, 16#13, 16#15, 16#18, 16#1A]],
    ?assertEqual(drop, erx_l2cap:signal(<<16#12, 7, 9, 0, 0:64>>)),
    ?assertEqual(drop, erx_l2cap:signal(<<16#12>>)),
    %% Past MTUsig, 23 octets: Signaling MTU exceeded, with the MTU.
    ?assertEqual({reply, <<16#01, 3, 4, 0, 1, 0, 23, 0>>}, erx_l2cap:signal(<<16#14, 3, 20, 0, 0:160>>)).

%% ---- erx_gatt_gate ----

gate_follows_gap_table_10_2_test() ->
    Rows = [{open, none, false, ok}, {open, encrypted, false, ok}, {open, authenticated, true, ok},
            {encrypted, none, false, {error, insufficient_authentication}},
            {encrypted, encrypted, false, {error, insufficient_encryption}},
            {encrypted, authenticated, false, {error, insufficient_encryption}},
            {encrypted, encrypted, true, ok}, {encrypted, authenticated, true, ok},
            {authenticated, none, false, {error, insufficient_authentication}},
            {authenticated, encrypted, false, {error, insufficient_encryption}},
            {authenticated, authenticated, false, {error, insufficient_encryption}},
            {authenticated, encrypted, true, {error, insufficient_authentication}},
            {authenticated, authenticated, true, ok}],
    [?assertEqual({Level, Key, Encrypted, Bonded, Result},
                  {Level, Key, Encrypted, Bonded,
                   erx_gatt_gate:check(Level, #{key => Key, encrypted => Encrypted, bonded => Bonded})})
     || {Level, Key, Encrypted, Result} <- Rows, Bonded <- [false, true]].

%% `bonded` is `authenticated` on a link whose key is a kept bond's: a pairing link that
%% has its key, before the store has kept its bond, is refused as one with no key is.
gate_bonded_requires_the_kept_bond_test() ->
    Rows = [{none, false, false, {error, insufficient_authentication}},
            {encrypted, false, true, {error, insufficient_encryption}},
            {encrypted, true, true, {error, insufficient_authentication}},
            {authenticated, false, true, {error, insufficient_encryption}},
            {authenticated, true, false, {error, insufficient_authentication}},
            {authenticated, true, true, ok}],
    [?assertEqual({Key, Encrypted, Bonded, Result},
                  {Key, Encrypted, Bonded,
                   erx_gatt_gate:check(bonded, #{key => Key, encrypted => Encrypted, bonded => Bonded})})
     || {Key, Encrypted, Bonded, Result} <- Rows].

%% ---- erx_gatt_db ----

table_matches_the_hand_written_one_test() ->
    Server = server(?OPEN),
    lists:foreach(fun({Handle, Type, Value}) ->
                          {ok, #{type := T}} = erx_gatt_db:lookup(Handle, table()),
                          ?assertEqual({Handle, Type}, {Handle, T}),
                          Value =:= none orelse ?assertEqual({Handle, Value}, {Handle, value_of(Handle, Server)})
                  end, expected()),
    ?assertEqual(error, erx_gatt_db:lookup(22, table())),
    ?assertEqual(error, erx_gatt_db:lookup(0, table())).

value_of(Handle, Server) ->
    case answer(read(Handle), Server#{security := ?PASSKEY}, erx_gatt_server:new()) of
        <<16#0B, Value/binary>> -> Value
    end.

table_ignores_manifest_order_test() ->
    [Sec, Nus] = services(),
    ?assertEqual(erx_gatt_db:build(?GAP, [Sec, Nus]), erx_gatt_db:build(?GAP, [Nus, Sec])),
    {ok, #{type := <<16#00, 16#28>>, group_end := 15}} = erx_gatt_db:lookup(10, table()).

%% erx_gatt_decl, generated from abi/gatt/, declares nus as the design's example does, so
%% its term is the hand-written one, whose UUIDs uuid/1 spells independently of the
%% generator, and every declared service builds into one table, so every served set, a
%% subset of them, fits in the 0xFFFF handles build/1 allows.
declared_services_build_the_table_test() ->
    [Sec, Nus] = services(),
    Declared = [erx_gatt_decl:service(Name) || Name <- erx_gatt_decl:names()],
    ?assertEqual(Nus, erx_gatt_decl:service(nus)),
    ?assert(lists:member(nus, erx_gatt_decl:advertised())),
    ?assertEqual(table(), erx_gatt_db:build(?GAP, [Sec, erx_gatt_decl:service(nus)])),
    Table = erx_gatt_db:build(?GAP, Declared),
    lists:foreach(fun(#{name := Service, characteristics := Chars}) ->
                          [{ok, _} = erx_gatt_db:characteristic({Service, Char}, Table)
                           || #{name := Char} <- Chars]
                  end, Declared).

%% ATT carries a handle in 16 bits, so build/1, which gives every handle, refuses a table
%% past 0xFFFF: GAP's and GATT's services (9 handles), a service of 32,762 characteristics
%% that neither notify nor indicate (65,525) and one of none (1) fill it to 0xFFFF exactly,
%% and one more service of none passes it. UUIDs repeat: the layout does not read them.
table_past_0xffff_handles_is_refused_test() ->
    Wide = #{name => wide, uuid => <<16#F0, 16#FF>>,
             characteristics => [#{name => list_to_atom("c" ++ integer_to_list(Index)), uuid => <<16#F1, 16#FF>>,
                                   max => 0, access => #{read => open}}
                                 || Index <- lists:seq(1, 32762)]},
    Empty = fun(Name) -> #{name => Name, uuid => <<16#F2, 16#FF>>, characteristics => []} end,
    Full = erx_gatt_db:build(?GAP, [Wide, Empty(empty)]),
    ?assertMatch({ok, #{handle := 16#FFFF, group_end := 16#FFFF}}, erx_gatt_db:lookup(16#FFFF, Full)),
    ?assertError({handles_past_0xffff, 16#10000}, erx_gatt_db:build(?GAP, [Wide, Empty(empty), Empty(extra)])).

%% The hash covers what a client keeps of the table: a characteristic's UUID, its accesses,
%% which its properties name, and the characteristic itself change it; its maximum, its
%% levels and its initial value, which a client does not keep, do not.
hash_covers_the_layout_alone_test() ->
    [#{characteristics := [Key, Ind]} = Sec, Nus] = services(),
    Hash = fun(Chars) -> erx_gatt_db:hash(erx_gatt_db:build(?GAP, [Sec#{characteristics := Chars}, Nus])) end,
    Base = erx_gatt_db:hash(table()),
    ?assertEqual(32, byte_size(Base)),
    ?assertNotEqual(Base, Hash([Key#{uuid := <<16#F1, 16#FF>>}, Ind])),
    ?assertNotEqual(Base, Hash([Key#{access := #{read => encrypted}}, Ind])),
    ?assertNotEqual(Base, Hash([Key])),
    ?assertEqual(Base, Hash([Key#{max := 511, access := #{read => open, write => open}, value := <<>>}, Ind])).

configuration_write_is_gated_at_notify_level_test() ->
    %% ind is read open and indicate encrypted: its configuration is written only encrypted.
    ?assertEqual(error_rsp(16#12, 21, 16#05), answer(write(21, <<2, 0>>), server(?OPEN), erx_gatt_server:new())),
    ?assertMatch({[<<16#13>>], [{subscribed, {sec, ind}, indicate}], _},
                 configured(write(21, <<2, 0>>), server(?JUST_WORKS), erx_gatt_server:new())),
    ?assertEqual(<<16#0B, 0, 0>>, answer(read(21), server(?OPEN), erx_gatt_server:new())).

%% On a link that holds a key and is not yet encrypted, a configuration write is
%% Insufficient Encryption (0x0F) at every level the characteristic declares, tx's open
%% notify included, so the configuration stays the link's default until the key encrypts
%% the link (docs/design-bluetooth.md, "A link is its bond's only from its encryption").
%% Without a key, tx's configuration is written open.
keyed_configuration_write_waits_for_encryption_test() ->
    [begin
         {ok, #{configuration := Handle}} = erx_gatt_db:characteristic(Char, table()),
         [?assertEqual(error_rsp(16#12, Handle, 16#0F),
                       answer(write(Handle, <<Bits, 0>>), server(#{key => Key, encrypted => false}),
                              erx_gatt_server:new()))
          || Key <- [encrypted, authenticated]]
     end || {Char, Bits} <- [{{nus, tx}, 1}, {{sec, ind}, 2}]],
    {ok, #{configuration := Tx}} = erx_gatt_db:characteristic({nus, tx}, table()),
    ?assertMatch({[<<16#13>>], [{subscribed, {nus, tx}, notify}], _},
                 configured(write(Tx, <<1, 0>>), server(?OPEN), erx_gatt_server:new())).

%% ---- erx_gatt_server ----

exchange_mtu_takes_the_smaller_and_never_below_23_test() ->
    New = erx_gatt_server:new(),
    ?assertEqual({[<<16#03, 247:16/little>>], [{mtu, 100}], 100},
                 mtu_of(ask(mtu_req(100), server(?OPEN), New))),
    ?assertEqual({[<<16#03, 247:16/little>>], [{mtu, 247}], 247}, mtu_of(ask(mtu_req(517), server(?OPEN), New))),
    ?assertEqual({[<<16#03, 247:16/little>>], [], 23}, mtu_of(ask(mtu_req(22), server(?OPEN), New))),
    ?assertEqual({[<<16#03, 247:16/little>>], [], 100}, mtu_of(ask(mtu_req(50), server(?OPEN), with_mtu(100)))).

mtu_of({Sent, Others, Bearer}) -> {Sent, Others, erx_gatt_server:mtu(Bearer)}.

discovery_walks_the_whole_table_at_every_mtu_test() ->
    Server = server(?OPEN, values()),
    Expected = [{H, T} || {H, T, _} <- expected()],
    Services = [{1, 5, <<0, 16#18>>}, {6, 9, <<1, 16#18>>},
                {10, 15, uuid("6e400001-b5a3-f393-e0a9-e50e24dcca9e")},
                {16, 21, uuid("0000aaaa-0000-4000-8000-00000000beef")}],
    Declarations = [{H, V} || {H, <<16#03, 16#28>>, V} <- expected()],
    lists:foreach(fun(Mtu) ->
                          Bearer = with_mtu(Mtu),
                          ?assertEqual({Mtu, Expected}, {Mtu, walk(fun information/3, 1, Server, Bearer)}),
                          ?assertEqual({Mtu, Services}, {Mtu, walk(fun groups/3, 1, Server, Bearer)}),
                          ?assertEqual({Mtu, Declarations}, {Mtu, walk(fun characteristics/3, 1, Server, Bearer)})
                  end, lists:seq(23, 247)).

%% A discovery procedure from `Start` until Attribute Not Found, each response within the MTU.
walk(Step, Start, Server, Bearer) ->
    case Step(Start, Server, Bearer) of
        done -> [];
        Entries -> Entries ++ walk(Step, last(lists:last(Entries)) + 1, Server, Bearer)
    end.

last({H, _}) -> H;
last({_, E, _}) -> E.

information(Start, Server, Bearer) ->
    case answer(find_info(Start, 16#FFFF), Server, Bearer) of
        <<16#01, 16#04, Start:16/little, 16#0A>> -> done;
        <<16#05, 1, Data/binary>> = R -> within(R, Bearer), [{H, U} || <<H:16/little, U:2/binary>> <= Data];
        <<16#05, 2, Data/binary>> = R -> within(R, Bearer), [{H, U} || <<H:16/little, U:16/binary>> <= Data]
    end.

groups(Start, Server, Bearer) ->
    case answer(read_by_group_type(Start, 16#FFFF, <<0, 16#28>>), Server, Bearer) of
        <<16#01, 16#10, Start:16/little, 16#0A>> -> done;
        <<16#11, Length, Data/binary>> = R ->
            within(R, Bearer),
            Size = Length - 4,
            [{H, E, V} || <<H:16/little, E:16/little, V:Size/binary>> <= Data]
    end.

characteristics(Start, Server, Bearer) ->
    case answer(read_by_type(Start, 16#FFFF, <<3, 16#28>>), Server, Bearer) of
        <<16#01, 16#08, Start:16/little, 16#0A>> -> done;
        <<16#09, Length, Data/binary>> = R ->
            within(R, Bearer),
            Size = Length - 2,
            [{H, V} || <<H:16/little, V:Size/binary>> <= Data]
    end.

within(Response, Bearer) ->
    ?assert(byte_size(Response) =< erx_gatt_server:mtu(Bearer)).

range_requests_check_their_handles_test() ->
    S = server(?OPEN),
    B = erx_gatt_server:new(),
    ?assertEqual(error_rsp(16#04, 0, 16#01), answer(find_info(0, 5), S, B)),
    ?assertEqual(error_rsp(16#04, 6, 16#01), answer(find_info(6, 5), S, B)),
    ?assertEqual(error_rsp(16#04, 22, 16#0A), answer(find_info(22, 16#FFFF), S, B)),
    ?assertEqual(error_rsp(16#04, 100, 16#0A), answer(find_info(100, 16#FFFF), S, B)),
    ?assertEqual(error_rsp(16#10, 5149, 16#0A), answer(read_by_group_type(5149, 16#FFFF, <<0, 16#28>>), S, B)),
    ?assertEqual(error_rsp(16#10, 1, 16#10), answer(read_by_group_type(1, 16#FFFF, <<3, 16#28>>), S, B)),
    ?assertEqual(error_rsp(16#08, 9, 16#01), answer(read_by_type(9, 1, <<3, 16#28>>), S, B)).

find_by_type_value_finds_a_service_by_uuid_test() ->
    Nus = uuid("6e400001-b5a3-f393-e0a9-e50e24dcca9e"),
    S = server(?OPEN),
    ?assertEqual(<<16#07, 10:16/little, 15:16/little>>,
                 answer(find_by_type_value(1, 16#FFFF, 16#2800, Nus), S, erx_gatt_server:new())),
    ?assertEqual(<<16#07, 6:16/little, 9:16/little>>,
                 answer(find_by_type_value(1, 16#FFFF, 16#2800, <<1, 16#18>>), S, erx_gatt_server:new())),
    ?assertEqual(error_rsp(16#06, 11, 16#0A),
                 answer(find_by_type_value(11, 16#FFFF, 16#2800, Nus), S, erx_gatt_server:new())).

read_by_type_of_a_value_reads_through_the_gate_test() ->
    Key = uuid("0000aaab-0000-4000-8000-00000000beef"),
    ?assertEqual(error_rsp(16#08, 18, 16#05), answer(read_by_type(1, 16#FFFF, Key), server(?OPEN), erx_gatt_server:new())),
    ?assertEqual(<<16#09, 9, 18:16/little, "initial">>,
                 answer(read_by_type(1, 16#FFFF, Key), server(?JUST_WORKS), erx_gatt_server:new())),
    %% A 16-bit type matches its 128-bit form (Part F, 3.4.4.1).
    Wide = erx_att:uuid128(<<16#F0, 16#FF>>),
    ?assertEqual(<<16#09, 2, 20:16/little>>, answer(read_by_type(1, 16#FFFF, Wide), server(?OPEN), erx_gatt_server:new())).

reads_answer_their_errors_test() ->
    B = erx_gatt_server:new(),
    ?assertEqual(error_rsp(16#0A, 22, 16#01), answer(read(22), server(?OPEN), B)),
    ?assertEqual(error_rsp(16#0A, 8, 16#02), answer(read(8), server(?OPEN), B)),
    ?assertEqual(error_rsp(16#0A, 18, 16#05), answer(read(18), server(?OPEN), B)),
    ?assertEqual(error_rsp(16#0A, 18, 16#0F), answer(read(18), server(#{key => encrypted, encrypted => false, bonded => false}), B)),
    ?assertEqual(error_rsp(16#0C, 18, 16#07), answer(read_blob(18, 8), server(?JUST_WORKS), B)),
    ?assertEqual(<<16#0D>>, answer(read_blob(18, 7), server(?JUST_WORKS), B)).

read_blob_asks_the_gate_test() ->
    ?assertEqual(error_rsp(16#0C, 18, 16#05), answer(read_blob(18, 0), server(?OPEN), erx_gatt_server:new())).

long_reads_at_every_mtu_test() ->
    Long = list_to_binary([X rem 256 || X <- lists:seq(1, 512)]),
    Server = server(?JUST_WORKS, #{{sec, key} => Long}),
    lists:foreach(fun(Mtu) -> ?assertEqual({Mtu, Long}, {Mtu, long_read(18, Server, with_mtu(Mtu))}) end,
                  lists:seq(23, 247)).

%% Part G, 4.8.3: Read, then Read Blob from the end until a part shorter than MTU - 1.
long_read(Handle, Server, Bearer) ->
    <<16#0B, First/binary>> = answer(read(Handle), Server, Bearer),
    rest(Handle, First, Server, Bearer).

rest(Handle, Sofar, Server, Bearer) ->
    case byte_size(Sofar) rem (erx_gatt_server:mtu(Bearer) - 1) of
        0 ->
            case answer(read_blob(Handle, byte_size(Sofar)), Server, Bearer) of
                <<16#0D>> -> Sofar;
                <<16#0D, Part/binary>> -> rest(Handle, <<Sofar/binary, Part/binary>>, Server, Bearer)
            end;
        _ ->
            Sofar
    end.

write_waits_for_its_handler_test() ->
    S = server(?OPEN),
    {[], [{write, _, {nus, rx}, <<"hi">>}], B} = ask(write(12, <<"hi">>), S, erx_gatt_server:new()),
    ?assertMatch({[{send, <<16#13>>}], _}, erx_gatt_server:reply(1, ok, S, B)),
    ?assertMatch({[{send, <<16#01, 16#12, 12, 0, 16#80>>}], _}, erx_gatt_server:reply(1, {error, 16#80}, S, B)),
    ?assertMatch({[{send, <<16#01, 16#12, 12, 0, 16#13>>}], _}, erx_gatt_server:reply(1, {error, value_not_allowed}, S, B)),
    ?assertMatch({[{send, <<16#01, 16#12, 12, 0, 16#0E>>}], _}, erx_gatt_server:reply(1, timeout, S, B)),
    ?assertMatch({[{send, <<16#01, 16#12, 12, 0, 16#0E>>}], _}, erx_gatt_server:reply(1, {error, 16#A0}, S, B)).

writes_answer_their_errors_test() ->
    [Sec, #{characteristics := [Rx, Tx]} = Nus] = services(),
    Short = (server(?OPEN))#{table := erx_gatt_db:build(?GAP, [Sec, Nus#{characteristics := [Rx#{max := 4}, Tx]}])},
    B = erx_gatt_server:new(),
    ?assertEqual(error_rsp(16#12, 12, 16#0D), answer(write(12, <<1, 2, 3, 4, 5>>), Short, B)),
    ?assertEqual({[], [], B}, ask(write_cmd(12, <<1, 2, 3, 4, 5>>), Short, B)),
    ?assertEqual(error_rsp(16#12, 14, 16#03), answer(write(14, <<1>>), server(?OPEN), B)),
    ?assertEqual(error_rsp(16#12, 18, 16#05), answer(write(18, <<1>>), server(?JUST_WORKS), B)),
    ?assertEqual(error_rsp(16#12, 1, 16#03), answer(write(1, <<1>>), server(?OPEN), B)),
    ?assertEqual(error_rsp(16#12, 99, 16#01), answer(write(99, <<1>>), server(?OPEN), B)),
    %% A request longer than the MTU is Invalid PDU; a command that long is ignored.
    ?assertEqual(error_rsp(16#12, 0, 16#04), answer(write(12, binary:copy(<<0>>, 21)), server(?OPEN), B)),
    ?assertEqual({[], [], B}, ask(write_cmd(12, binary:copy(<<0>>, 21)), server(?OPEN), B)).

subscriptions_take_only_what_the_characteristic_allows_test() ->
    S = server(?OPEN),
    B = erx_gatt_server:new(),
    {[<<16#13>>], [{subscribed, {nus, tx}, notify}], B1} = configured(write(15, <<1, 0>>), S, B),
    ?assertEqual(<<16#0B, 1, 0>>, answer(read(15), S, B1)),
    ?assertEqual(error_rsp(16#12, 15, 16#13), answer(write(15, <<2, 0>>), S, B)),
    ?assertEqual(error_rsp(16#12, 15, 16#13), answer(write(15, <<3, 0>>), S, B)),
    ?assertEqual(error_rsp(16#12, 15, 16#0D), answer(write(15, <<1>>), S, B)),
    ?assertMatch({[<<16#13>>], [{subscribed, {nus, tx}, none}], _}, configured(write(15, <<0, 0>>), S, B1)).

%% A configuration changes only at its answer `ok` (docs/design-bluetooth.md, "Bonds and the
%% store"): any other answer is Unlikely Error (0x0E) and leaves it as it was, a write that
%% changes nothing is answered at once with no event, and a Write Command to the descriptor
%% changes it through the same answer where the gate allows a write, and is otherwise ignored.
configuration_changes_only_at_its_answer_test() ->
    S = server(?OPEN),
    B = erx_gatt_server:new(),
    {[], [{configure, Ref, {nus, tx}, notify}], Asked} = ask(write(15, <<1, 0>>), S, B),
    {Refused, Unchanged} = erx_gatt_server:reply(Ref, {error, unavailable}, S, Asked),
    ?assertEqual([{send, error_rsp(16#12, 15, 16#0E)}], Refused),
    ?assertEqual(<<16#0B, 0, 0>>, answer(read(15), S, Unchanged)),
    ?assertEqual({[<<16#13>>], [], B}, ask(write(15, <<0, 0>>), S, B)),
    {[], [{configure, Ref2, {nus, tx}, notify}], Commanded} = ask(write_cmd(15, <<1, 0>>), S, B),
    {[{subscribed, {nus, tx}, notify}], Subscribed} = erx_gatt_server:reply(Ref2, ok, S, Commanded),
    ?assertEqual(<<16#0B, 1, 0>>, answer(read(15), S, Subscribed)),
    ?assertEqual({[], [], B}, ask(write_cmd(15, <<3, 0>>), S, B)),
    ?assertEqual({[], [], B}, ask(write_cmd(21, <<2, 0>>), S, B)).

notifications_follow_subscription_gate_and_mtu_test() ->
    S = server(?OPEN),
    B = erx_gatt_server:new(),
    ?assertEqual({error, not_subscribed}, erx_gatt_server:notify(notify, {nus, tx}, <<"x">>, S, B)),
    {_, _, B1} = configured(write(15, <<1, 0>>), S, B),
    ?assertEqual({ok, <<16#1B, 14, 0, "x">>, B1}, erx_gatt_server:notify(notify, {nus, tx}, <<"x">>, S, B1)),
    ?assertEqual({error, too_long}, erx_gatt_server:notify(notify, {nus, tx}, binary:copy(<<0>>, 21), S, B1)),
    ?assertMatch({ok, _, _}, erx_gatt_server:notify(notify, {nus, tx}, binary:copy(<<0>>, 20), S, B1)),
    ?assertEqual({error, not_allowed}, erx_gatt_server:notify(indicate, {nus, tx}, <<"x">>, S, B1)),
    ?assertEqual({error, not_allowed}, erx_gatt_server:notify(notify, {nus, nope}, <<"x">>, S, B1)),
    ?assertEqual({error, insufficient_security}, erx_gatt_server:notify(indicate, {sec, ind}, <<"x">>, S, B1)).

one_indication_in_flight_test() ->
    S = server(?JUST_WORKS),
    {_, _, B} = configured(write(21, <<2, 0>>), S, erx_gatt_server:new()),
    {ok, <<16#1D, 20, 0, "a">>, B1} = erx_gatt_server:notify(indicate, {sec, ind}, <<"a">>, S, B),
    ?assertEqual({error, busy}, erx_gatt_server:notify(indicate, {sec, ind}, <<"b">>, S, B1)),
    {[], [{confirmed, {sec, ind}}], B2} = ask(confirm(), S, B1),
    ?assertMatch({ok, _, _}, erx_gatt_server:notify(indicate, {sec, ind}, <<"b">>, S, B2)),
    ?assertEqual({[], [], B2}, ask(confirm(), S, B2)).

second_request_before_the_response_ends_the_link_test() ->
    S = server(?OPEN),
    {_, _, B} = ask(write(12, <<"a">>), S, erx_gatt_server:new()),
    ?assertMatch({[], [{close, request_outstanding}], _}, ask(read(1), S, B)).

commands_wait_behind_the_handler_and_overflow_is_discarded_test() ->
    S = server(?OPEN),
    {[], [{write, _, {nus, rx}, <<0>>}], B0} = ask(write_cmd(12, <<0>>), S, erx_gatt_server:new()),
    B16 = lists:foldl(fun(N, B) -> {[], [], Next} = ask(write_cmd(12, <<N>>), S, B), Next end, B0, lists:seq(1, 16)),
    ?assertMatch({[], [discarded], _}, ask(write_cmd(12, <<17>>), S, B16)),
    %% A request waits behind the commands; the handler's answers release them in order.
    {[], [], B17} = ask(read(1), S, B16),
    {[{write, 2, {nus, rx}, <<1>>}], B18} = erx_gatt_server:reply(1, ok, S, B17),
    Final = lists:foldl(fun(N, B) -> {[{write, _, {nus, rx}, <<N>>}], Next} = erx_gatt_server:reply(N, ok, S, B), Next end,
                        B18, lists:seq(2, 16)),
    ?assertMatch({[{send, <<16#0B, 0, 16#18>>}], _}, erx_gatt_server:reply(17, ok, S, Final)).

%% An answer to a write that timed out is dropped, never taken for the next write.
late_answer_is_not_taken_for_the_next_write_test() ->
    S = server(?OPEN),
    {[], [{write, 1, {nus, rx}, <<"a">>}], B1} = ask(write(12, <<"a">>), S, erx_gatt_server:new()),
    {[{send, <<16#01, 16#12, 12, 0, 16#0E>>}], B2} = erx_gatt_server:reply(1, timeout, S, B1),
    {[], [{write, 2, {nus, rx}, <<"b">>}], B3} = ask(write(12, <<"b">>), S, B2),
    ?assertEqual({[], B3}, erx_gatt_server:reply(1, {error, 16#80}, S, B3)),
    ?assertMatch({[{send, <<16#13>>}], _}, erx_gatt_server:reply(2, ok, S, B3)).

unsupported_and_invalid_requests_test() ->
    S = server(?OPEN),
    B = erx_gatt_server:new(),
    ?assertEqual(error_rsp(16#0E, 0, 16#06), answer(<<16#0E, 1, 0, 2, 0>>, S, B)),
    ?assertEqual(error_rsp(16#20, 0, 16#06), answer(<<16#20, 1, 0, 2, 0>>, S, B)),
    ?assertEqual(error_rsp(16#0A, 0, 16#04), answer(<<16#0A, 1>>, S, B)),
    ?assertEqual(error_rsp(16#08, 0, 16#04), answer(<<16#08, 1, 0, 2, 0, 3, 0, 0>>, S, B)),
    ?assertEqual(error_rsp(16#18, 0, 16#04), answer(execute(2), S, B)),
    [?assertEqual({[], [], B}, ask(Pdu, S, B)) || Pdu <- [<<16#D2, 1, 0>>, <<16#1B, 1, 0>>, <<16#01, 2, 0, 0, 1>>, <<>>]].

prepared_writes_at_every_mtu_test() ->
    Long = list_to_binary([X rem 251 || X <- lists:seq(1, 244)]),
    S = server(?OPEN),
    lists:foreach(fun(Mtu) ->
                          Bearer = lists:foldl(fun({Offset, Part}, B) ->
                                                       Echo = <<16#17, 12, 0, Offset:16/little, Part/binary>>,
                                                       {[Echo], [], Next} = ask(prepare(12, Offset, Part), S, B),
                                                       Next
                                               end, with_mtu(Mtu), parts(Long, Mtu - 5)),
                          ?assertMatch({Mtu, {[], [{write, _, {nus, rx}, Long}], _}}, {Mtu, ask(execute(1), S, Bearer)})
                  end, lists:seq(23, 247)).

parts(Value, Size) ->
    [{Offset, binary:part(Value, Offset, min(Size, byte_size(Value) - Offset))}
     || Offset <- lists:seq(0, byte_size(Value) - 1, Size)].

prepared_writes_refuse_what_they_cannot_hold_test() ->
    S = server(?OPEN),
    {_, _, B} = ask(prepare(12, 0, <<1, 2>>), S, erx_gatt_server:new()),
    ?assertEqual(error_rsp(16#16, 15, 16#03), answer(prepare(15, 0, <<1, 0>>), S, B)),
    ?assertEqual(error_rsp(16#16, 1, 16#03), answer(prepare(1, 0, <<1>>), S, B)),
    Full = lists:foldl(fun(N, Acc) -> {_, _, Next} = ask(prepare(12, N * 10, <<0:80>>), S, Acc), Next end,
                       B, lists:seq(0, 23)),
    ?assertEqual(error_rsp(16#16, 12, 16#09), answer(prepare(12, 240, <<0:40>>), S, Full)),
    ?assertEqual(<<16#17, 12, 0, 240, 0, 0:32>>, answer(prepare(12, 240, <<0:32>>), S, Full)),
    %% An offset past what the parts before it wrote discards the queue (Part F, 3.4.6.3).
    {_, _, Gap} = ask(prepare(12, 5, <<1>>), S, erx_gatt_server:new()),
    {[Error], [], Cleared} = ask(execute(1), S, Gap),
    ?assertEqual(error_rsp(16#18, 12, 16#07), Error),
    ?assertEqual(<<16#19>>, answer(execute(1), S, Cleared)),
    ?assertEqual(<<16#19>>, answer(execute(0), S, B)).

gate_guards_commands_prepares_and_value_search_test() ->
    [#{characteristics := [Key, Ind]} = Sec, #{characteristics := [Rx, Tx]} = Nus] = services(),
    Gated = erx_gatt_db:build(?GAP, [Sec#{characteristics := [Key, Ind#{access := #{indicate => encrypted, read => encrypted}}]},
                               Nus#{characteristics := [Rx#{access := #{write => open, write_without_response => encrypted}}, Tx]}]),
    Open = (server(?OPEN))#{table := Gated},
    Encrypted = (server(?JUST_WORKS))#{table := Gated},
    B = erx_gatt_server:new(),
    ?assertEqual({[], [], B}, ask(write_cmd(12, <<"c">>), Open, B)),
    ?assertMatch({[], [{write, _, {nus, rx}, <<"c">>}], _}, ask(write_cmd(12, <<"c">>), Encrypted, B)),
    ?assertEqual(error_rsp(16#16, 18, 16#05), answer(prepare(18, 0, <<1>>), Encrypted, B)),
    ?assertEqual(<<16#17, 18, 0, 0, 0, 1>>, answer(prepare(18, 0, <<1>>), Encrypted#{security := ?PASSKEY}, B)),
    %% Find By Type Value compares no value the gate hides (Part F, 3.4.3.3).
    ?assertEqual(error_rsp(16#06, 1, 16#0A), answer(find_by_type_value(1, 16#FFFF, 16#FFF0, <<>>), Open, B)),
    ?assertEqual(<<16#07, 20:16/little, 20:16/little>>,
                 answer(find_by_type_value(1, 16#FFFF, 16#FFF0, <<>>), Encrypted, B)).

prepared_empty_parts_hold_nothing_test() ->
    S = server(?OPEN),
    Bearer = lists:foldl(fun(_, B) -> {_, _, N} = ask(prepare(12, 0, <<>>), S, B), N end,
                         erx_gatt_server:new(), lists:seq(1, 10000)),
    ?assert(erts_debug:flat_size(Bearer) < 100).

%% ---- the bearer, explored ----

%% Every state a small alphabet reaches, from a new bearer: requests, commands, a
%% confirmation, a subscription and a prepared write from the phone; the handler's answers;
%% and indications. A state is the bearer with the count of the phone's requests not yet
%% answered, which ATT allows to be at most one (Part F, 3.3.2). Each step must answer no
%% request twice and none it was not asked; a second request before a response must end
%% the link; nothing sent may pass the MTU; and from every state the handler's answers
%% must bring the count back to zero. The state also holds the ref of the last write given
%% to the handler, which answers that write, and an answer to the write before it must
%% change nothing; refs grow, so the exploration stops past ?WRITES writes.
bearer_explored_test_() ->
    {timeout, 120, fun explore/0}.

explore() ->
    S = server(?JUST_WORKS),
    Start = {erx_gatt_server:new(), 0, 0},
    Visited = explore([Start], #{Start => true}, S),
    io:format("~b states~n", [map_size(Visited)]),
    ?assert(map_size(Visited) > 1000).

explore([], Visited, _S) ->
    Visited;
explore([State | Rest], Visited, S) ->
    settles(State, S, 40),
    Next = [N || Event <- alphabet(), N <- [step(Event, State, S)], N =/= closed, element(3, N) =< ?WRITES,
                 not maps:is_key(N, Visited)],
    Unique = lists:usort(Next),
    explore(Unique ++ Rest, lists:foldl(fun(N, V) -> V#{N => true} end, Visited, Unique), S).

alphabet() ->
    [{phone, read(1)}, {phone, write(12, <<"w">>)}, {phone, write_cmd(12, <<"c">>)},
     {phone, prepare(12, 0, binary:copy(<<1>>, 100))}, {phone, execute(1)}, {phone, execute(0)},
     {phone, mtu_req(30)}, {phone, write(21, <<2, 0>>)}, {phone, confirm()},
     {handler, ok}, {handler, {error, 16#81}}, late, indicate].

step({phone, Pdu}, {Bearer, Outstanding, Ref}, S) ->
    Request = binary:first(Pdu) band 16#40 =:= 0 andalso binary:first(Pdu) =/= 16#1E,
    {Actions, Next} = erx_gatt_server:request(Pdu, S, Bearer),
    case Request andalso Outstanding =:= 1 of
        true -> ?assertEqual([{close, request_outstanding}], Actions), closed;
        false -> account(Actions, Outstanding + case Request of true -> 1; false -> 0 end, Ref, Bearer, Next)
    end;
step({handler, Answer}, {Bearer, Outstanding, Ref}, S) ->
    {Actions, Next} = erx_gatt_server:reply(Ref, Answer, S, Bearer),
    account(Actions, Outstanding, Ref, Bearer, Next);
step(late, {Bearer, _Outstanding, Ref} = State, S) ->
    ?assertEqual({[], Bearer}, erx_gatt_server:reply(Ref - 1, ok, S, Bearer)),
    State;
step(indicate, {Bearer, Outstanding, Ref}, S) ->
    case erx_gatt_server:notify(indicate, {sec, ind}, <<"i">>, S, Bearer) of
        {ok, Pdu, Next} -> ?assert(byte_size(Pdu) =< erx_gatt_server:mtu(Bearer)), {Next, Outstanding, Ref};
        {error, Reason} -> ?assert(lists:member(Reason, [busy, not_subscribed])), {Bearer, Outstanding, Ref}
    end.

%% The responses among `Actions` answer requests asked; none passes the MTU it was sent at.
account(Actions, Asked, Ref, Before, After) ->
    Responses = [P || {send, P} <- Actions],
    [?assert(byte_size(P) =< erx_gatt_server:mtu(Before)) || P <- Responses],
    ?assert(length(Responses) =< Asked),
    ?assertNot(lists:member({close, request_outstanding}, Actions)),
    Given = [R || {Kind, R, _, _} <- Actions, Kind =:= write orelse Kind =:= configure],
    [?assertEqual(Ref + 1, R) || R <- Given],
    {After, Asked - length(Responses), lists:max([Ref | Given])}.

settles({_Bearer, 0, _Ref}, _S, _Budget) ->
    ok;
settles(State, S, Budget) when Budget > 0 ->
    settles(step({handler, ok}, State, S), S, Budget - 1).
