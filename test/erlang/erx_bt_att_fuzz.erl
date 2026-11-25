%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of what a phone sends on an LE link (docs/design-bluetooth.md, "Fuzz
%% targets"): the L2CAP reassembly and frame decoder (erx_l2cap:reassemble/3), the LE
%% signaling decoder (erx_l2cap:signal/1), and erx_att:decode/1 with the ATT server over it
%% (erx_gatt_server:request/3), the readers of bytes anyone in radio range writes. A round
%% takes one of them and an input this module writes from the specification's layouts (Core
%% 6.3 Vol 3 Part A, sections 3.1 and 4; Part F, section 3.4), used as written, cut,
%% mutated, or replaced by random bytes. Whatever arrives, no reader makes an atom or
%% raises, and each answer is checked against what this module knows independently:
%%
%% * reassemble/3 gives back a written frame cut anywhere, refuses one past its channel's
%%   bound (247 octets, 65 on SMP's channel 0x0006) at its header, and never holds or
%%   gives a frame past that bound;
%% * signal/1 answers only a command that is not a response, with a Command Reject of its
%%   identifier;
%% * decode/1 reads a written request back as written; the server, over a table with a
%%   value longer than any MTU, sends nothing longer than the bearer's MTU, answers a
%%   request it takes at once with exactly one PDU, a response or an error of that
%%   request's opcode, and closes the link only for a second request outstanding.
%%
%% The seed comes from make check-fuzz.
-module(erx_bt_att_fuzz).
-define(GAP, #{name => <<"erxos">>, appearance => 0}).
-export([run/1]).

-define(ROUNDS, 20000).
-define(RESPONSES, [16#01, 16#07, 16#13, 16#15, 16#18, 16#1A]).
%% The requests the server takes, the opcodes of its responses beside them (Part F, 3.4).
-define(REQUESTS, [{16#02, 16#03}, {16#04, 16#05}, {16#06, 16#07}, {16#08, 16#09}, {16#0A, 16#0B}, {16#0C, 16#0D},
                   {16#10, 16#11}, {16#12, 16#13}, {16#16, 16#17}, {16#18, 16#19}]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    Server = server(),
    Kinds = [frames, signals, requests],
    {Tally, _} = lists:foldl(fun(_, {T, Bearer}) ->
                                     Kind = pick(Kinds),
                                     {Accepted, Next} = round_of(Kind, Server, Bearer),
                                     {maps:update_with({Kind, Accepted}, fun(N) -> N + 1 end, 1, T), Next}
                             end, {#{}, erx_gatt_server:new()}, lists:seq(1, ?ROUNDS)),
    Counts = [{K, maps:get({K, true}, Tally, 0)} || K <- Kinds],
    case lists:all(fun({_, N}) -> N >= ?ROUNDS div 20 end, Counts) of
        true -> io:format("fuzz: ~p rounds ok, ~p frames, ~p signals answered, ~p requests answered~n",
                          [?ROUNDS | [N || {_, N} <- Counts]]);
        false -> error({too_few_accepted, Counts})
    end.

server() ->
    Long = #{name => long, uuid => <<16#F1, 16#FF>>, max => 512, value => binary:copy(<<7>>, 512),
             access => #{read => open, write => open, write_without_response => open, notify => open}},
    Gated = #{name => gated, uuid => <<16#F2, 16#FF>>, max => 20, access => #{read => encrypted, indicate => open}},
    Table = erx_gatt_db:build(?GAP, [#{name => fuzz, uuid => <<16#F0, 16#FF>>, characteristics => [Long, Gated]}]),
    #{table => Table, values => #{}, security => #{key => none, encrypted => false, bonded => false}}.

%% ---- frames ----

round_of(frames, _Server, Bearer) ->
    Cid = pick([4, 5, 6, 7, 16#40]),
    Bound = case Cid of 6 -> 65; _ -> 247 end,
    Length = rand:uniform(Bound + 4) - 1,
    Frame = <<Length:16/little, Cid:16/little, (rand:bytes(Length))/binary>>,
    Cut = cut(Frame),
    {Pieces, Written} = case rand:uniform(4) of
                            1 -> {[{rand:uniform(4) - 1, rand:bytes(rand:uniform(30) - 1)}
                                   || _ <- lists:seq(1, rand:uniform(6))], false};
                            2 -> {mutate_pieces(Cut), false};
                            _ -> {Cut, true}
                        end,
    Said = no_atoms(Pieces, fun() -> feed(Pieces) end),
    case {Written, Length > Bound, Said} of
        {true, true, {error, {too_long, Cid, Length}}} -> ok;
        {true, true, _} -> error({frame_over_bound, Frame, Said});
        {true, false, {frame, Cid, Payload}} -> Payload =:= binary:part(Frame, 4, Length) orelse error({frame_misread, Frame});
        {true, false, _} -> error({frame_refused, Frame, Said});
        {false, _, _} -> ok
    end,
    {element(1, Said) =:= frame, Bearer};
round_of(signals, _Server, Bearer) ->
    Frame = case rand:uniform(3) of
                1 -> rand:bytes(rand:uniform(40) - 1);
                _ -> Data = rand:bytes(rand:uniform(30) - 1),
                     <<(rand:uniform(256) - 1), (rand:uniform(256) - 1), (byte_size(Data)):16/little, Data/binary>>
            end,
    Said = no_atoms(Frame, fun() -> erx_l2cap:signal(Frame) end),
    case {Said, Frame} of
        {drop, _} -> {false, Bearer};
        {{reply, <<16#01, Id, Length:16/little, Rest/binary>>}, <<Code, Id, _/binary>>} when byte_size(Rest) =:= Length ->
            lists:member(Code, ?RESPONSES) andalso error({response_answered, Frame}),
            {true, Bearer};
        _ -> error({signal_misanswered, Frame, Said})
    end;
round_of(requests, Server, Bearer0) ->
    Bearer = case rand:uniform(50) of 1 -> erx_gatt_server:new(); _ -> Bearer0 end,
    {Pdu, Expected} = request_case(),
    case Expected of
        none -> ok;
        _ -> (Said = erx_att:decode(Pdu)) =:= Expected orelse error({decoded_wrongly, Pdu, Said})
    end,
    Mtu = erx_gatt_server:mtu(Bearer),
    {Actions, Next} = no_atoms(Pdu, fun() -> erx_gatt_server:request(Pdu, Server, Bearer) end),
    Sent = [P || {send, P} <- Actions],
    [byte_size(P) =< Mtu orelse error({response_over_mtu, Pdu, P}) || P <- Sent],
    Answered = check_answer(Pdu, Actions, Sent),
    %% Now and then the handler answers the write this request gave it, or some write,
    %% the one that waits or a late one.
    Ref = lists:max([rand:uniform(16) | [R || {write, R, _, _} <- Actions]]),
    {Released, After} = case rand:uniform(3) of
                            1 -> erx_gatt_server:reply(Ref, pick([ok, {error, 16#80}, timeout]), Server, Next);
                            _ -> {[], Next}
                        end,
    [byte_size(P) =< erx_gatt_server:mtu(Next) orelse error({response_over_mtu, Pdu, P}) || {send, P} <- Released],
    {Answered, After}.

feed([{B, D} | Rest]) ->
    lists:foldl(fun({B1, D1}, {more, P}) -> held(P), erx_l2cap:reassemble(B1, D1, P);
                   (_, Done) -> Done
                end, erx_l2cap:reassemble(B, D, none), Rest).

%% A frame in progress never holds more than its header and the largest bound.
held(Partial) when byte_size(Partial) =< 4 + 247 -> ok;
held(Partial) -> error({frame_over_bound, held, byte_size(Partial)}).

%% A frame cut into ACL packets of one random length, as a controller delivers them.
cut(Frame) ->
    [First | Rest] = pieces(Frame, rand:uniform(byte_size(Frame))),
    [{2, First} | [{1, P} || P <- Rest]].

pieces(<<>>, _Size) -> [];
pieces(Bytes, Size) when byte_size(Bytes) =< Size -> [Bytes];
pieces(Bytes, Size) -> <<P:Size/binary, Rest/binary>> = Bytes, [P | pieces(Rest, Size)].

mutate_pieces(Pieces) ->
    case rand:uniform(3) of
        1 -> tl(Pieces) ++ [{1, <<>>}];
        2 -> [{rand:uniform(4) - 1, D} || {_, D} <- Pieces];
        3 -> Pieces ++ [{1, rand:bytes(rand:uniform(5))}]
    end.

%% ---- requests ----

%% A PDU and what decode/1 must read from it: a request written from its layout, or none
%% for one mutated or random.
request_case() ->
    H = pick([rand:uniform(17), rand:uniform(16#FFFF + 1) - 1]),
    S = pick([0, 1, 2, 3, 5, rand:uniform(16#FFFF)]),
    E = pick([16#FFFF, S, S + 1, 0]) band 16#FFFF,
    U = pick([<<0, 16#28>>, <<3, 16#28>>, <<16#F1, 16#FF>>, rand:bytes(16)]),
    V = rand:bytes(rand:uniform(260) - 1),
    O = pick([0, 1, 22, 512, rand:uniform(16#FFFF)]),
    Written = pick([{<<16#02, H:16/little>>, {request, {exchange_mtu, H}}},
                    {<<16#04, S:16/little, E:16/little>>, {request, {find_information, S, E}}},
                    {<<16#06, S:16/little, E:16/little, 0, 16#28, V/binary>>,
                     {request, {find_by_type_value, S, E, <<0, 16#28>>, V}}},
                    {<<16#08, S:16/little, E:16/little, U/binary>>, {request, {read_by_type, S, E, U}}},
                    {<<16#0A, H:16/little>>, {request, {read, H}}},
                    {<<16#0C, H:16/little, O:16/little>>, {request, {read_blob, H, O}}},
                    {<<16#10, S:16/little, E:16/little, U/binary>>, {request, {read_by_group_type, S, E, U}}},
                    {<<16#12, H:16/little, V/binary>>, {request, {write, H, V}}},
                    {<<16#16, H:16/little, O:16/little, V/binary>>, {request, {prepare_write, H, O, V}}},
                    {<<16#18, 0>>, {request, {execute_write, cancel}}},
                    {<<16#18, 1>>, {request, {execute_write, write}}},
                    {<<16#52, H:16/little, V/binary>>, {write_command, H, V}},
                    {<<16#1E>>, confirmation}]),
    {Pdu, _} = Written,
    case rand:uniform(4) of
        1 -> {mutate(Pdu), none};
        2 -> {rand:bytes(rand:uniform(30) - 1), none};
        _ -> Written
    end.

mutate(<<>>) -> <<>>;
mutate(Pdu) ->
    case rand:uniform(3) of
        1 -> binary:part(Pdu, 0, rand:uniform(byte_size(Pdu)) - 1);
        2 -> <<Pdu/binary, (rand:bytes(rand:uniform(4)))/binary>>;
        3 -> At = rand:uniform(byte_size(Pdu)) - 1,
             <<Head:At/binary, _, Tail/binary>> = Pdu,
             <<Head/binary, (rand:uniform(256) - 1), Tail/binary>>
    end.

%% A request the server takes at once is answered by one PDU of its own response, or an
%% error naming its opcode; one it gives to a handler, or queues, sends nothing yet; and
%% only a request can close the link.
check_answer(<<Op, _/binary>> = Pdu, Actions, Sent) ->
    Request = lists:keymember(Op, 1, ?REQUESTS) orelse (Op band 16#40 =:= 0 andalso not server_pdu(Op)),
    Closed = lists:member({close, request_outstanding}, Actions),
    Closed andalso not Request andalso error({closed_by_a_command, Pdu}),
    Own = [P || P <- Sent, own_answer(Op, P)],
    length(Own) =< 1 orelse error({answered_twice, Pdu, Sent}),
    Own =/= [];
check_answer(<<>>, Actions, _Sent) ->
    Actions =:= [] orelse error({empty_pdu_answered, Actions}),
    false.

own_answer(Op, <<16#01, Op, _:16, _>>) -> true;
own_answer(Op, <<Response, _/binary>>) -> lists:member({Op, Response}, ?REQUESTS);
own_answer(_Op, _Pdu) -> false.

server_pdu(Op) ->
    lists:member(Op, [16#01, 16#03, 16#05, 16#07, 16#09, 16#0B, 16#0D, 16#0F, 16#11, 16#13, 16#17, 16#19, 16#1B, 16#1D,
                      16#1E, 16#21, 16#23]).

no_atoms(Input, Read) ->
    Atoms = erlang:system_info(atom_count),
    Said = Read(),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Input}),
    Said.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
