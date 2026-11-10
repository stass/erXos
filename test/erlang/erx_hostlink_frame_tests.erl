%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the host link's frame layer, erx_hostlink_frame and erx_hostlink_stream
%% (docs/design-live.md, "Host link frames"): the shared vectors of
%% test/fixtures/hostlink_frames.txt, which the Ruby frame layer checks too, named by
%% ERX_HOSTLINK_VECTORS, then the session's receiving, sending and credit. Run on stock's
%% emulator with test/erlang/host_bytes/erx_bytes.erl standing in for the BIFs.

-module(erx_hostlink_frame_tests).

-include_lib("eunit/include/eunit.hrl").

-define(S, <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>).
-define(ZERO, <<0:128>>).
-define(MIB16, 16777216).

%% --- The shared vectors ---

vectors() ->
    {ok, Text} = file:read_file(os:getenv("ERX_HOSTLINK_VECTORS")),
    [string:lexemes(Line, " ") || Line <- string:lexemes(Text, "\n"), binary:first(Line) =/= $#].

vector_test_() ->
    [{iolist_to_binary([Kind, " ", Name]), fun() -> check_vector(Vector) end}
     || [Kind, Name | _] = Vector <- vectors()].

check_vector([<<"cobs">>, _Name, Decoded, Encoded]) ->
    ?assertEqual(bytes(Encoded), erx_hostlink_frame:cobs_encode(bytes(Decoded))),
    ?assertEqual({ok, bytes(Decoded)}, erx_hostlink_frame:cobs_decode(bytes(Encoded)));
check_vector([<<"cobs_bad">>, _Name, Encoded]) ->
    ?assertEqual({error, cobs}, erx_hostlink_frame:cobs_decode(bytes(Encoded)));
check_vector([<<"crc">>, _Name, Data, Crc]) ->
    ?assertEqual(binary_to_integer(Crc, 16), erx_bytes:crc32c(0, bytes(Data)));
check_vector([<<"feed">>, _Name, Side, Results, Hex]) ->
    Bytes = bytes(Hex),
    Deframer = erx_hostlink_frame:deframer(binary_to_existing_atom(Side)),
    {Whole, _} = erx_hostlink_frame:feed(Bytes, Deframer),
    ?assertEqual(results(Results), Whole),
    ?assertEqual(Whole, by_bytes(Bytes, Deframer)),
    %% A vector of exactly one frame is what encode/1 makes of it.
    case {Whole, binary:first(Bytes)} of
        {[{ok, Frame}], First} when First =/= 0 -> ?assertEqual(Bytes, erx_hostlink_frame:encode(Frame));
        _ -> ok
    end.

%% The same bytes fed one at a time give the same results.
by_bytes(Bytes, Deframer) ->
    {Results, _} = lists:foldl(fun(Byte, {Acc, D}) ->
                                       {Out, D1} = erx_hostlink_frame:feed(<<Byte>>, D),
                                       {Acc ++ Out, D1}
                               end, {[], Deframer}, binary_to_list(Bytes)),
    Results.

results(<<"none">>) -> [];
results(Text) -> [result(string:split(Item, ":", all)) || Item <- string:lexemes(Text, ",")].

result([<<"discard">>, Reason]) -> {error, binary_to_existing_atom(Reason)};
result([<<"frame">>, Stream, Session, Seq, Target, Body]) ->
    {ok, #{stream => binary_to_existing_atom(Stream), session => bytes(Session),
           seq => binary_to_integer(Seq), target => binary_to_integer(Target), body => bytes(Body)}}.

bytes(<<"-">>) -> <<>>;
bytes(Hex) -> binary:decode_hex(Hex).

%% --- Deframing ---

counts_test() ->
    D = erx_hostlink_frame:deframer(target),
    {_, D1} = erx_hostlink_frame:feed(<<5, 17, 34, 0, 5, 17, 0, 1, 0>>, D),
    ?assertEqual(#{cobs => 2, short => 1}, erx_hostlink_frame:counts(D1)).

encode_refuses_a_long_body_test() ->
    ?assertError(badarg, erx_hostlink_frame:encode(#{stream => files, session => ?S, seq => 0, target => 0,
                                                     body => binary:copy(<<1>>, 8193)})).

partial_kept_across_feeds_test() ->
    Frame = terminal(?S, 0, <<"abc">>),
    Bytes = erx_hostlink_frame:encode(Frame),
    {[], D} = erx_hostlink_frame:feed(binary:part(Bytes, 0, 5), erx_hostlink_frame:deframer(target)),
    ?assertMatch({[{ok, Frame}], _},
                 erx_hostlink_frame:feed(binary:part(Bytes, 5, byte_size(Bytes) - 5), D)).

%% --- Receiving within a session ---

terminal(Session, Seq, Body) ->
    #{stream => terminal, session => Session, seq => Seq, target => 0, body => Body}.

%% The frames a sender of Session makes for Payload, decoded again at the target.
message_frames(Kind, Id, Payload) -> message_frames(Kind, Id, Payload, erx_hostlink_stream:sender(?S)).

message_frames(Kind, Id, Payload, Sender) ->
    {ok, Wire, Next} = erx_hostlink_stream:message(Kind, Id, 3, Payload, Sender),
    {[{ok, F} || F <- decoded(Wire)], Next}.

decoded(Wire) ->
    [Frame || Bytes <- Wire,
              {[{ok, Frame}], _} <- [erx_hostlink_frame:feed(Bytes, erx_hostlink_frame:deframer(target))]].

accept_all(Frames, Receiver) -> accept_all(Frames, ?MIB16, Receiver).

accept_all(Frames, Room, Receiver) ->
    lists:mapfoldl(fun({ok, F}, R) -> erx_hostlink_stream:accept(F, Room, R);
                      (F, R) -> erx_hostlink_stream:accept(F, Room, R)
                   end, Receiver, Frames).

receiver() -> erx_hostlink_stream:set_session(?S, erx_hostlink_stream:receiver(?MIB16)).

reassembles_a_long_message_test() ->
    Payload = << <<(N rem 256)>> || N <- lists:seq(1, 20000) >>,
    {Frames, _} = message_frames(call, 9, Payload),
    ?assertEqual(3, length(Frames)),
    {Results, R} = accept_all(Frames, receiver()),
    ?assertEqual([pending, pending,
                  {message, #{kind => call, id => 9, target => 3, session => ?S, payload => Payload}}],
                 Results),
    ?assertEqual(0, erx_hostlink_stream:held(R)).

empty_and_exact_pieces_test() ->
    [begin
         {Frames, _} = message_frames(cast, 0, binary:copy(<<7>>, Size)),
         ?assertEqual(Count, length(Frames)),
         {Results, _} = accept_all(Frames, receiver()),
         ?assertMatch({message, #{payload := P}} when byte_size(P) =:= Size, lists:last(Results))
     end || {Size, Count} <- [{0, 1}, {8176, 1}, {8177, 2}, {16352, 2}]].

held_while_reassembling_test() ->
    {[First | _], _} = message_frames(call, 1, binary:copy(<<1>>, 9000)),
    {[pending], R} = accept_all([First], receiver()),
    ?assertEqual(9000, erx_hostlink_stream:held(R)).

gap_drops_the_message_under_way_test() ->
    {[First, Second], _} = message_frames(call, 1, binary:copy(<<1>>, 9000)),
    {ok, Lost} = Second,
    Skipped = {ok, Lost#{seq := 2}},
    {Results, R} = accept_all([First, Skipped], receiver()),
    ?assertEqual([pending, {error, pieces}], Results),
    ?assertEqual(#{gap => 1, pieces => 1}, erx_hostlink_stream:counts(R)),
    ?assertEqual(0, erx_hostlink_stream:held(R)).

message_after_a_gap_still_arrives_test() ->
    {[First, _Second], Sender} = message_frames(call, 1, binary:copy(<<1>>, 9000)),
    {[Next], _} = message_frames(call, 2, <<"x">>, Sender),
    {Results, R} = accept_all([First, Next], receiver()),
    ?assertMatch([pending, {message, #{id := 2, payload := <<"x">>}}], Results),
    ?assertEqual(#{gap => 1}, erx_hostlink_stream:counts(R)).

%% A frame whose seq is below the one expected is a repeat: discarded, and the message
%% under way is left alone.
a_repeated_frame_is_discarded_test() ->
    {[First, Second], _} = message_frames(call, 1, binary:copy(<<1>>, 9000)),
    {Results, R} = accept_all([First, First, Second], receiver()),
    ?assertMatch([pending, {error, seq}, {message, #{id := 1}}], Results),
    ?assertEqual(#{seq => 1}, erx_hostlink_stream:counts(R)).

%% A hello is not held to Room: it replaces the session whose bytes Room leaves out.
a_hello_is_not_held_to_room_test() ->
    Hello = #{stream => control, session => ?ZERO, seq => 0, target => 0,
              body => <<1, 0, 0:16, 1:32/little, 1:64/little, 131>>},
    ?assertMatch({{hello, #{payload := <<131>>}}, _}, erx_hostlink_stream:accept(Hello, 0, receiver())).

other_streams_pass_between_pieces_test() ->
    {[First, Second], _} = message_frames(call, 1, binary:copy(<<1>>, 9000)),
    {ok, F1} = First,
    {ok, F2} = Second,
    Between = terminal(?S, 1, <<"k">>),
    {Results, _} = accept_all([F1, Between, F2#{seq := 2}], receiver()),
    ?assertMatch([pending, {frame, Between}, {message, #{id := 1}}], Results).

piece_of_another_message_starts_anew_test() ->
    {[First, _], Sender} = message_frames(call, 1, binary:copy(<<1>>, 9000)),
    {[{ok, Other}], _} = message_frames(call, 2, <<"y">>, Sender),
    {Results, R} = accept_all([First, Other#{seq := 1}], receiver()),
    ?assertMatch([pending, {message, #{id := 2}}], Results),
    ?assertEqual(#{pieces => 1}, erx_hostlink_stream:counts(R)).

refused_message_skips_its_pieces_test() ->
    {Frames, Sender} = message_frames(call, 1, binary:copy(<<1>>, 20000)),
    {[After], _} = message_frames(call, 2, <<"z">>, Sender),
    {Results, R} = accept_all(Frames ++ [After], 10000, receiver()),
    ?assertMatch([{refused, #{kind := call, id := 1, total := 20000}}, skipped, skipped,
                  {message, #{id := 2}}], Results),
    ?assertEqual(#{}, erx_hostlink_stream:counts(R)).

too_large_for_the_receiver_test() ->
    {Frames, _} = message_frames(call, 1, binary:copy(<<1>>, 9000)),
    Small = erx_hostlink_stream:set_session(?S, erx_hostlink_stream:receiver(8192)),
    {[First, Second], _} = accept_all(Frames, Small),
    ?assertEqual({error, too_large}, First),
    ?assertEqual(skipped, Second).

session_filter_test() ->
    Hello = #{stream => control, session => ?ZERO, seq => 0, target => 0,
              body => <<1, 0, 0:16, 1:32/little, 1:64/little, 131>>},
    Before = erx_hostlink_stream:receiver(?MIB16),
    {[{hello, #{session := ?ZERO, payload := <<131>>}}, {error, session}], _} =
        accept_all([Hello, terminal(?ZERO, 1, <<"a">>)], Before),
    {[{error, session}, {hello, _}, {frame, _}], _} =
        accept_all([terminal(<<9:128>>, 0, <<"a">>), Hello, terminal(?S, 0, <<"b">>)], receiver()),
    ?assertError(function_clause, erx_hostlink_stream:set_session(?ZERO, Before)).

malformed_control_headers_test() ->
    Base = #{stream => control, session => ?S, seq => 0, target => 0},
    Bodies = [<<1, 0, 0:16, 1:32/little>>,                      % short of a header
              <<4, 0, 0:16, 1:32/little, 1:64/little, 0>>,      % kind 4
              <<1, 2, 0:16, 1:32/little, 1:64/little, 0>>,      % unknown flag
              <<1, 0, 1:16, 1:32/little, 1:64/little, 0>>,      % reserved set
              <<1, 0, 0:16, 1:32/little, 0:64/little, 0>>,      % a call with id 0
              <<3, 0, 0:16, 1:32/little, 5:64/little, 0>>],     % a cast with an id
    [?assertMatch({{error, control}, _}, erx_hostlink_stream:accept(Base#{body => Body}, ?MIB16, receiver()))
     || Body <- Bodies],
    Overrun = <<1, 0, 0:16, 1:32/little, 1:64/little, 0, 0>>,
    Short = <<1, 0, 0:16, 3:32/little, 1:64/little, 0, 0>>,
    Full = <<1, 1, 0:16, 2:32/little, 1:64/little, 0, 0>>,
    [?assertMatch({{error, pieces}, _}, erx_hostlink_stream:accept(Base#{body => Body}, ?MIB16, receiver()))
     || Body <- [Overrun, Short, Full]].

%% Every piece but the last is a whole 8,176 bytes, so a message has as many pieces as its
%% total says and an empty or short piece with MORE set is refused.
short_pieces_with_more_are_refused_test() ->
    Base = #{stream => control, session => ?S, target => 0},
    Empty = Base#{seq => 0, body => <<1, 1, 0:16, 2:32/little, 1:64/little>>},
    {[{error, pieces}, {error, pieces}], R} =
        accept_all([Empty, Empty#{seq => 1}], receiver()),
    ?assertEqual(0, erx_hostlink_stream:held(R)),
    Short = Base#{seq => 0, body => <<1, 1, 0:16, 9000:32/little, 1:64/little, 0:8000>>},
    ?assertMatch({{error, pieces}, _}, erx_hostlink_stream:accept(Short, ?MIB16, receiver())).

%% --- Sending ---

sender_numbers_frames_test() ->
    {ok, A, S1} = erx_hostlink_stream:frame(terminal, 0, <<"a">>, erx_hostlink_stream:sender(?S)),
    {ok, B, _} = erx_hostlink_stream:frame(files, 0, <<"b">>, S1),
    ?assertMatch([#{seq := 0}, #{seq := 1}], decoded([A, B])).

%% A sender near the end of its numbers, by its record's next field.
sender_stops_before_wrapping_test() ->
    Near = setelement(3, erx_hostlink_stream:sender(?S), 16#FFFFFFFF),
    {ok, Last, Done} = erx_hostlink_stream:frame(terminal, 0, <<>>, Near),
    ?assertMatch([#{seq := 16#FFFFFFFF}], decoded([Last])),
    ?assertEqual({error, exhausted}, erx_hostlink_stream:frame(terminal, 0, <<>>, Done)),
        ?assertEqual({error, exhausted},
                     erx_hostlink_stream:message(call, 1, 0, binary:copy(<<1>>, 9000), Near)).

    %% A sender given a lower last seq stops there.
    sender_stops_at_its_last_seq_test() ->
        {ok, _, One} = erx_hostlink_stream:frame(terminal, 0, <<>>, erx_hostlink_stream:sender(?S, 1)),
        {ok, Last, Done} = erx_hostlink_stream:frame(terminal, 0, <<>>, One),
        ?assertMatch([#{seq := 1}], decoded([Last])),
        ?assertEqual({error, exhausted}, erx_hostlink_stream:frame(terminal, 0, <<>>, Done)).

sender_refuses_a_message_over_16_mib_test() ->
    ?assertEqual({error, too_large},
                 erx_hostlink_stream:message(cast, 0, 0, binary:copy(<<0>>, ?MIB16 + 1),
                                             erx_hostlink_stream:sender(?S))).

%% --- Credit ---

%% A grant is the total granted in the session, so a later one makes up for a lost one,
%% and flush/1 grants what is owed, or repeats the last grant.
grant_after_a_quarter_test() ->
    G = erx_hostlink_stream:grant(),
    {none, G1} = erx_hostlink_stream:consumed(4000, G),
    {{grant, 4100}, G2} = erx_hostlink_stream:consumed(100, G1),
    ?assertEqual({none, G2}, erx_hostlink_stream:consumed(0, G2)),
    {{grant, 8200}, G3} = erx_hostlink_stream:consumed(4100, G2),
    {none, G4} = erx_hostlink_stream:consumed(10, G3),
    {{grant, 8210}, G5} = erx_hostlink_stream:flush(G4),
    ?assertMatch({{grant, 8210}, _}, erx_hostlink_stream:flush(G5)).

grant_wraps_at_32_bits_test() ->
    {{grant, Big}, G} = erx_hostlink_stream:consumed(16#FFFFFFFF, erx_hostlink_stream:grant()),
    ?assertEqual(16#FFFFFFFF, Big),
    ?assertMatch({{grant, 4095}, _}, erx_hostlink_stream:consumed(4096, G)).

%% A hello is one frame: one of more frames is refused, and it leaves the current
%% session's message under way alone.
hello_is_one_frame_test() ->
    {[First, _], _} = message_frames(call, 1, binary:copy(<<1>>, 9000)),
    {Hello, _} = message_frames(cast, 0, binary:copy(<<2>>, 9000), erx_hostlink_stream:sender(?ZERO)),
    {Results, R} = accept_all([First | Hello], receiver()),
    ?assertEqual([pending, {error, pieces}, {error, pieces}], Results),
    ?assertEqual(9000, erx_hostlink_stream:held(R)).

set_session_drops_the_message_under_way_test() ->
    {[First, _], _} = message_frames(call, 1, binary:copy(<<1>>, 9000)),
    {[pending], R} = accept_all([First], receiver()),
    ?assertEqual(0, erx_hostlink_stream:held(erx_hostlink_stream:set_session(none, R))).

encode_refuses_a_target_on_terminal_test() ->
    ?assertError(badarg, erx_hostlink_frame:encode((terminal(?S, 0, <<>>))#{target := 1})),
    ?assertError(badarg, erx_hostlink_frame:encode((terminal(?S, 0, <<>>))#{stream := other})).
