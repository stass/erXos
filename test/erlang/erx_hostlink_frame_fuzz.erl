%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Mutated byte streams through the host link's deframer, erx_hostlink_frame, fed in random
%% pieces, and frames changed field by field through erx_hostlink_stream's receiver.
%% Whatever arrives, nothing raises, the deframer's results agree with reference/2, a
%% reader that shares no code with it (it splits the whole stream at its zeros and decodes
%% COBS over a list), and each frame taken re-encodes to a frame that decodes the same. The
%% byte streams start from the shared vectors' bytes (test/fixtures/hostlink_frames.txt,
%% named by ERX_HOSTLINK_VECTORS), from a sender's messages, and from runs at the encoded
%% bound. The receiver's results, reservation and counts agree with ref_accept/3's.
%% Mutated external-term-format payloads through erx_hostlink_payload, Phase 1's check of
%% a payload from the host: it never raises, refuses compressed and trailing bytes, and
%% what it passes decodes, in safe mode, to a term that encodes back to the same bytes'
%% term.
%% The seed comes from make check-fuzz.

-module(erx_hostlink_frame_fuzz).
-export([run/1]).

-define(ROUNDS, 4000).
-define(ENCODED_MAX, 8300).
-define(FRAME_MAX, (28 + 8192 + 4)).
-define(S, <<7:128>>).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Seeds = seeds(),
    Taken = lists:sum([round_of(mutate(pick(Seeds)), side()) || _ <- lists:seq(1, ?ROUNDS)]),
    Messages = lists:sum([receiver_round() || _ <- lists:seq(1, ?ROUNDS)]),
    Passed = lists:sum([payload_round(mutate(pick(payload_seeds()))) || _ <- lists:seq(1, ?ROUNDS)]),
    case Taken > ?ROUNDS div 10 andalso Messages > ?ROUNDS andalso Passed > ?ROUNDS div 10 of
        true -> io:format("fuzz: ~p rounds ok, ~p frames taken, ~p messages~n", [?ROUNDS, Taken, Messages]);
        false -> error({too_few_taken, Taken, Messages})
    end.

side() -> pick([target, host]).

payload_seeds() ->
    [term_to_binary(T) || T <- [{hello, <<0:128>>}, {open, inspect}, [1, 2.5, <<"x">>, #{a => [b]}],
                                {call, "text", -1 bsl 70}, {self(), make_ref()}]]
        ++ [term_to_binary(lists:seq(1, 300), [compressed])].

%% 1 when erx_hostlink_payload passes Payload, after checking what it passes and refuses.
payload_round(Payload) ->
    case {erx_hostlink_payload:measure(Payload), erx_hostlink_payload:decode(Payload)} of
        {{ok, Size}, {ok, Term}} when is_integer(Size), Size >= 0 ->
            Term = binary_to_term(term_to_binary(Term)),
            1;
        {{error, Reason}, {error, Reason}} when Reason =:= too_large; Reason =:= badarg; Reason =:= type ->
            0;
        {{error, compressed}, {error, compressed}} when binary_part(Payload, 0, 2) =:= <<131, 80>> ->
            0;
        Other ->
            error({payload_check_disagrees, Payload, Other})
    end.

pick(List) -> lists:nth(rand:uniform(length(List)), List).

seeds() ->
    {ok, Text} = file:read_file(os:getenv("ERX_HOSTLINK_VECTORS")),
    Vectors = [binary:decode_hex(Hex) || Line <- string:lexemes(Text, "\n"),
                                         [<<"feed">>, _, _, _, Hex] <- [string:lexemes(Line, " ")]],
    Sender = erx_hostlink_stream:sender(?S),
    {ok, Long, S1} = erx_hostlink_stream:message(call, 1, 0, binary:copy(<<0, 1, 2>>, 6000), Sender),
    {ok, Cast, S2} = erx_hostlink_stream:message(cast, 0, 0, <<131, 106>>, S1),
    {ok, Key, _} = erx_hostlink_stream:frame(terminal, 0, <<"k">>, S2),
    Vectors ++ [iolist_to_binary(Long ++ Cast ++ [Key]),
                <<(binary:copy(<<255>>, ?ENCODED_MAX))/binary, 0>>,
                <<(binary:copy(<<255>>, ?ENCODED_MAX + 1))/binary, 0>>,
                <<(binary:copy(<<1>>, ?ENCODED_MAX))/binary, 0, Key/binary>>].

mutate(Bytes) ->
    lists:foldl(fun(_, Acc) -> mutation(rand:uniform(6), Acc) end, Bytes,
                lists:seq(1, rand:uniform(4) - 1)).

mutation(_, <<>>) -> <<>>;
mutation(1, Bytes) -> at(Bytes, fun(Byte) -> <<(Byte bxor (1 bsl (rand:uniform(8) - 1)))>> end);
mutation(2, Bytes) -> binary:part(Bytes, 0, rand:uniform(byte_size(Bytes)) - 1);
mutation(3, Bytes) -> at(Bytes, fun(_) -> <<0>> end);
mutation(4, Bytes) -> at(Bytes, fun(Byte) -> <<Byte, 0, 0>> end);
mutation(5, Bytes) -> <<Bytes/binary, Bytes/binary>>;
mutation(6, Bytes) -> at(Bytes, fun(_) -> <<(rand:uniform(256) - 1)>> end).

at(Bytes, Change) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Before:At/binary, Byte, After/binary>> = Bytes,
    <<Before/binary, (Change(Byte))/binary, After/binary>>.

%% The number of frames taken from Bytes.
round_of(Bytes, Side) ->
    Results = in_pieces(Bytes, erx_hostlink_frame:deframer(Side), []),
    Expected = reference(Side, Bytes),
    Results =:= Expected orelse error({disagrees_with_reference, Side, Bytes, Results, Expected}),
    Frames = [Frame || {ok, Frame} <- Results],
    [roundtrip(Side, Frame) || Frame <- Frames],
    length(Frames).

in_pieces(<<>>, _Deframer, Acc) ->
    lists:append(lists:reverse(Acc));
in_pieces(Bytes, Deframer, Acc) ->
    Size = min(rand:uniform(600), byte_size(Bytes)),
    <<Piece:Size/binary, Rest/binary>> = Bytes,
    {Results, Next} = erx_hostlink_frame:feed(Piece, Deframer),
    [ok = closed(Result) || Result <- Results],
    in_pieces(Rest, Next, [Results | Acc]).

closed({ok, #{stream := Stream, session := <<_:16/binary>>, seq := Seq, target := Target, body := Body}})
  when is_atom(Stream), is_integer(Seq), is_integer(Target), byte_size(Body) =< 8192 -> ok;
closed({error, Reason}) when Reason =:= oversize; Reason =:= cobs; Reason =:= short; Reason =:= crc;
                             Reason =:= version; Reason =:= header; Reason =:= stream -> ok.

roundtrip(Side, Frame) ->
    Bytes = erx_hostlink_frame:encode(Frame),
    {[{ok, Frame}], _} = erx_hostlink_frame:feed(Bytes, erx_hostlink_frame:deframer(Side)),
    ok.

%% --- The receiver against its reference ---

%% One round of control and terminal frames: a sender's messages, interleaved and changed
%% field by field with valid CRCs, through the receiver and through ref_accept/3, a
%% reassembler written from erx_hostlink_stream's moduledoc that shares no code with it.
%% The two must give the same results, hold the same bytes and count the same discards.
%% Returns the number of whole messages given.
receiver_round() ->
    Max = pick([16777216, 16777216, 8192]),
    Frames = [change(Frame) || Frame <- stream_of_frames()],
    Receiver = erx_hostlink_stream:set_session(?S, erx_hostlink_stream:receiver(Max)),
    {Given, Final, RefFinal} =
        lists:foldl(fun(Frame, {Count, R, Ref}) ->
                            Room = pick([0, 100, 9000, 20000, 16777216]),
                            {Result, R1} = erx_hostlink_stream:accept(Frame, Room, R),
                            {Expected, Ref1} = ref_accept(Frame, Room, Ref),
                            Result =:= Expected orelse
                                error({disagrees_with_reference, Frame, Room, Result, Expected}),
                            Held = erx_hostlink_stream:held(R1),
                            Held =:= ref_held(Ref1) orelse error({held_disagrees, Frame, Held}),
                            {Count + whole(Result), R1, Ref1}
                    end, {0, Receiver, ref_receiver(Max)}, Frames),
    Counts = erx_hostlink_stream:counts(Final),
    Counts =:= maps:get(counts, RefFinal) orelse error({counts_disagree, Counts, RefFinal}),
    Given.

whole({message, _}) -> 1;
whole({hello, _}) -> 1;
whole(_) -> 0.

%% A few messages of sizes about the piece bounds, a hello and a keystroke, in order.
stream_of_frames() ->
    Sizes = [pick([0, 1, 8175, 8176, 8177, 16352, 16353, 20000]) || _ <- lists:seq(1, rand:uniform(3))],
    {Frames, _} = lists:foldl(fun(Size, {Acc, Sender}) ->
                                      Kind = pick([call, reply, cast]),
                                      Id = case Kind of cast -> 0; _ -> rand:uniform(3) end,
                                      {ok, Wire, Next} = erx_hostlink_stream:message(
                                                           Kind, Id, rand:uniform(2) - 1,
                                                           binary:copy(<<5>>, Size), Sender),
                                      {ok, Key, Next1} = erx_hostlink_stream:frame(terminal, 0, <<"k">>, Next),
                                      {Acc ++ decoded(Wire ++ [Key]), Next1}
                              end, {[], erx_hostlink_stream:sender(?S)}, Sizes),
    {ok, Hello, _} = erx_hostlink_stream:message(call, 1, 0, <<"hello">>, erx_hostlink_stream:sender(<<0:128>>)),
    Frames ++ decoded(Hello).

decoded(Wire) ->
    [Frame || {ok, Frame} <- element(1, erx_hostlink_frame:feed(iolist_to_binary(Wire),
                                                                erx_hostlink_frame:deframer(target)))].

%% Most frames pass as made; the others get one field changed.
change(Frame) ->
    case rand:uniform(8) of
        1 -> Frame#{seq := maps:get(seq, Frame) + pick([1, 2, -1])};
        2 -> Frame#{session := pick([<<0:128>>, <<9:128>>])};
        3 -> control_field(Frame);
        4 -> Frame#{body := cut(maps:get(body, Frame))};
        _ -> Frame
    end.

control_field(#{stream := control, body := <<Kind, Flags, Reserved:16, Total:32/little, Id:64/little,
                                             Piece/binary>>} = Frame) ->
    Body = case rand:uniform(5) of
               1 -> <<(pick([0, 1, 2, 3, 4])), Flags, Reserved:16, Total:32/little, Id:64/little, Piece/binary>>;
               2 -> <<Kind, (pick([0, 1, 2, 3])), Reserved:16, Total:32/little, Id:64/little, Piece/binary>>;
               3 -> <<Kind, Flags, 1:16, Total:32/little, Id:64/little, Piece/binary>>;
               4 -> <<Kind, Flags, Reserved:16, (Total + pick([-1, 1, 9000000])):32/little, Id:64/little,
                      Piece/binary>>;
               5 -> <<Kind, Flags, Reserved:16, Total:32/little, (pick([0, 1, 2])):64/little, Piece/binary>>
           end,
    Frame#{body := Body};
control_field(Frame) ->
    Frame.

cut(<<>>) -> <<>>;
cut(Body) -> binary:part(Body, 0, byte_size(Body) - 1).

-define(PIECE, 8176).

ref_receiver(Max) -> #{max => Max, current => ?S, expect => none, msg => none, counts => #{}}.

ref_held(#{msg := #{mode := keep, total := Total}}) -> Total;
ref_held(_) -> 0.

ref_count(Key, #{counts := Counts} = St) ->
    St#{counts := Counts#{Key => maps:get(Key, Counts, 0) + 1}}.

ref_error(Reason, St) -> {{error, Reason}, ref_count(Reason, St)}.

ref_accept(#{stream := control, session := <<0:128>>, body := Body, target := Target}, _Room, St) ->
    case ref_header(Body) of
        error -> ref_error(control, St);
        {_Kind, _More, Total, _Id, _Piece} when Total > map_get(max, St) -> ref_error(too_large, St);
        {_Kind, true, _Total, _Id, _Piece} -> ref_error(pieces, St);
        {_Kind, false, Total, _Id, Piece} when byte_size(Piece) =/= Total -> ref_error(pieces, St);
        {Kind, false, _Total, Id, Piece} ->
            {{hello, #{kind => Kind, id => Id, target => Target, session => <<0:128>>, payload => Piece}}, St}
    end;
ref_accept(#{session := Session}, _Room, #{current := Current} = St) when Session =/= Current ->
    ref_error(session, St);
ref_accept(#{seq := Seq}, _Room, #{expect := Expect} = St) when Expect =/= none, Seq < Expect ->
    ref_error(seq, St);
ref_accept(#{seq := Seq} = Frame, Room, #{expect := Expect} = St) ->
    Sequenced = case Expect =:= none orelse Seq =:= Expect of
                    true -> St#{expect := Seq + 1};
                    false -> (ref_count(gap, St))#{expect := Seq + 1, msg := none}
                end,
    ref_taken(Frame, Room, Sequenced).

ref_taken(#{stream := control, body := Body, target := Target, session := Session}, Room, St) ->
    case ref_header(Body) of
        error ->
            ref_error(control, St#{msg := none});
        {Kind, More, Total, Id, Piece} ->
            Key = {Kind, Id, Target, Session, Total},
            case St of
                #{msg := #{key := Key} = Msg} -> ref_piece(Msg, More, Piece, St);
                #{msg := none} -> ref_first(Key, More, Piece, Room, St);
                #{msg := _Other} -> ref_first(Key, More, Piece, Room, (ref_count(pieces, St))#{msg := none})
            end
    end;
ref_taken(Frame, _Room, St) ->
    {{frame, Frame}, St}.

ref_first({Kind, Id, Target, Session, Total} = Key, More, Piece, Room, #{max := Max} = St) ->
    Head = #{kind => Kind, id => Id, target => Target, session => Session, total => Total},
    if
        Total > Max -> ref_unkept({error, too_large}, Key, More, Piece, ref_count(too_large, St));
        Total > Room -> ref_unkept({refused, Head}, Key, More, Piece, St);
        true -> ref_piece(#{mode => keep, key => Key, total => Total, got => 0, acc => <<>>}, More, Piece, St)
    end.

ref_unkept(Result, {_, _, _, _, Total} = Key, More, Piece, St) ->
    case ref_fits(0, More, Piece, Total) of
        false -> ref_error(pieces, St);
        true when More -> {Result, St#{msg := #{mode => skip, key => Key, total => Total,
                                                got => byte_size(Piece), acc => <<>>}}};
        true -> {Result, St}
    end.

ref_piece(#{mode := Mode, key := {Kind, Id, Target, Session, Total}, got := Got, acc := Acc} = Msg,
          More, Piece, St) ->
    case {ref_fits(Got, More, Piece, Total), More, Mode} of
        {false, _, _} -> ref_error(pieces, St#{msg := none});
        {true, true, keep} -> {pending, St#{msg := Msg#{got := Got + byte_size(Piece), acc := <<Acc/binary, Piece/binary>>}}};
        {true, false, keep} ->
            {{message, #{kind => Kind, id => Id, target => Target, session => Session,
                         payload => <<Acc/binary, Piece/binary>>}}, St#{msg := none}};
        {true, true, skip} -> {skipped, St#{msg := Msg#{got := Got + byte_size(Piece)}}};
        {true, false, skip} -> {skipped, St#{msg := none}}
    end.

ref_fits(Got, true, Piece, Total) -> byte_size(Piece) =:= ?PIECE andalso Got + ?PIECE < Total;
ref_fits(Got, false, Piece, Total) -> Got + byte_size(Piece) =:= Total.

%% The control header as the moduledoc states it, or error.
ref_header(<<KindNumber, Flags, Reserved:16, Total:32/little, Id:64/little, Piece/binary>>) ->
    Kind = case KindNumber of 1 -> call; 2 -> reply; 3 -> cast; _ -> unknown end,
    IdRight = (Kind =:= cast andalso Id =:= 0) orelse (Kind =/= cast andalso Id =/= 0),
    case Kind =/= unknown andalso Flags =< 1 andalso Reserved =:= 0 andalso IdRight of
        true -> {Kind, Flags =:= 1, Total, Id, Piece};
        false -> error
    end;
ref_header(_Body) ->
    error.

%% --- The reference ---

reference(Side, Bytes) ->
    [_Unended | Ended] = split_zeros(binary_to_list(Bytes), [], []),
    [ref_frame(Side, Segment) || Segment <- lists:reverse(Ended), Segment =/= []].

%% The runs between zeros, last first: the bytes after the last zero, then each ended run.
split_zeros([], Run, Runs) -> [lists:reverse(Run) | Runs];
split_zeros([0 | Rest], Run, Runs) -> split_zeros(Rest, [], [lists:reverse(Run) | Runs]);
split_zeros([Byte | Rest], Run, Runs) -> split_zeros(Rest, [Byte | Run], Runs).

ref_frame(_Side, Segment) when length(Segment) > ?ENCODED_MAX -> {error, oversize};
ref_frame(Side, Segment) ->
    case ref_cobs(Segment, []) of
        error -> {error, cobs};
        Decoded when length(Decoded) < 32 -> {error, short};
        Decoded when length(Decoded) > ?FRAME_MAX -> {error, oversize};
        Decoded -> ref_fields(Side, list_to_binary(Decoded))
    end.

ref_cobs([], Out) -> Out;
ref_cobs([Code | Rest], Out) when length(Rest) >= Code - 1 ->
    {Group, After} = lists:split(Code - 1, Rest),
    Zero = case Code =:= 255 orelse After =:= [] of
               true -> [];
               false -> [0]
           end,
    ref_cobs(After, Out ++ Group ++ Zero);
ref_cobs(_Encoded, _Out) -> error.

ref_fields(Side, Decoded) ->
    Size = byte_size(Decoded) - 4,
    <<Covered:Size/binary, Crc:32/little>> = Decoded,
    <<Version, Stream, Reserved:16, Session:16/binary, Seq:32/little, Target:32/little,
      Body/binary>> = Covered,
    Receives = case Side of
                   target -> [0, 1, 4];
                   host -> [0, 1, 2, 3, 4]
               end,
    Names = {control, terminal, events, credit, files},
    Computed = erx_bytes:crc32c(0, Covered),
    if
        Crc =/= Computed -> {error, crc};
        Version =/= 2 -> {error, version};
        Reserved =/= 0 -> {error, header};
        Stream > 4 -> {error, stream};
        true ->
            case lists:member(Stream, Receives) of
                false -> {error, stream};
                true when Target =/= 0, Stream =/= 0, Stream =/= 3 -> {error, header};
                true ->
                    {ok, #{stream => element(Stream + 1, Names), session => Session, seq => Seq,
                           target => Target, body => Body}}
            end
    end.
