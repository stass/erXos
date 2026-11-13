%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random input through every parser of what the SD card or its controller
%% writes (docs/design-storage.md, "Verification and testing"): the R1, R3,
%% R6 and R7 words, the R2 words with the CSD and its admission, the SCR,
%% the SD status, the General Information, the Performance Enhancement
%% register set and the interrupt decode; and random events through the
%% identification and transfer state machines. Each target returns a value
%% or a refusal for every input and never raises, and agrees with a
%% reference that reads the fields by their bit numbers. The CSD target
%% checks the admission's properties on every card it admits: the capacity
%% is the specification's formula and every address fits 32 bits. Inputs
%% cluster at the right sizes and at well-formed values, so the accepting
%% paths are common. The seed comes from make check-fuzz.

-module(erx_blk_sd_fuzz).
-export([run/1]).

-define(ROUNDS, 4000).
-define(C, erx_blk_sd_card).
-define(H, erx_blk_sd_host).
-define(MASK32, 16#FFFFFFFF).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Each parser must accept a twentieth of its rounds, so an edit to a
    %% generator cannot leave the accepting path untried; a random walk
    %% rarely completes a state machine, which has no such floor.
    Parsers = [{r1, fun r1/0}, {r3, fun r3/0}, {r6, fun r6/0}, {r7, fun r7/0},
               {csd, fun csd/0}, {scr, fun scr/0}, {sd_status, fun sd_status/0},
               {general_information, fun general_information/0},
               {performance_enhancement, fun performance_enhancement/0},
               {interrupt, fun interrupt/0}, {sd_command, fun sd_command/0},
               {registers, fun registers/0}],
    Machines = [{identification, fun identification/0}, {transfer, fun transfer/0}],
    Targets = [{Name, Round, ?ROUNDS div 20} || {Name, Round} <- Parsers]
        ++ [{Name, Round, 0} || {Name, Round} <- Machines],
    lists:foreach(fun({Name, Round, Floor}) ->
                          Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), Round() =:= accepted]),
                          Accepted >= Floor orelse error({too_few_accepted, Name, Accepted}),
                          io:format("fuzz ~p: ~p rounds ok, ~p accepted~n", [Name, ?ROUNDS, Accepted])
                  end, Targets),
    io:format("fuzz: ~p rounds ok, ~p targets~n", [?ROUNDS * length(Targets), length(Targets)]).

%%% Inputs

word() ->
    case rand:uniform(8) of
        1 -> -rand:uniform(1000);
        2 -> ?MASK32 + rand:uniform(1 bsl 40);
        3 -> lists:nth(rand:uniform(4), [0, ?MASK32, 16#1AA, 16#900]);
        4 -> 1 bsl (rand:uniform(32) - 1);
        5 -> not_a_word;
        _ -> rand:uniform(?MASK32 + 1) - 1
    end.

bits(V, High, Width) -> (V bsr (High - Width + 1)) band ((1 bsl Width) - 1).

bytes(Size) ->
    Actual = case rand:uniform(6) of
                 1 -> 0;
                 2 -> max(0, Size - 1);
                 3 -> Size + 1;
                 4 -> rand:uniform(2 * Size);
                 _ -> Size
             end,
    rand:bytes(Actual).

verdict({ok, _}) -> accepted;
verdict(ok) -> accepted;
verdict({error, _}) -> refused.

agree(Name, Input, Said, Expected) ->
    case Said =:= Expected of
        true -> verdict(Said);
        false -> error({disagrees_with_reference, Name, Input, Said, Expected})
    end.

is_word(W) -> is_integer(W) andalso W >= 0 andalso W =< ?MASK32.

%%% Responses

r1() ->
    W = word(),
    Mask = lists:foldl(fun(B, A) -> A bor (1 bsl B) end, 0,
                       [31, 30, 29, 28, 27, 26, 24, 23, 22, 21, 20, 19, 16, 15, 3]),
    Expected = case is_word(W) of
                   true -> {ok, #{errors => W band Mask, state => bits(W, 12, 4),
                                  ready => bits(W, 8, 1) =:= 1, locked => bits(W, 25, 1) =:= 1,
                                  app_cmd => bits(W, 5, 1) =:= 1}};
                   false -> {error, malformed}
               end,
    agree(r1, W, ?C:r1(W), Expected).

r3() ->
    W = word(),
    Expected = case is_word(W) of
                   true -> {ok, #{ready => bits(W, 31, 1) =:= 1, ccs => bits(W, 30, 1) =:= 1,
                                  ocr => W}};
                   false -> {error, malformed}
               end,
    agree(r3, W, ?C:r3(W), Expected).

r6() ->
    W = word(),
    Expected = case is_word(W) of
                   true -> {ok, #{rca => bits(W, 31, 16),
                                  status => (bits(W, 15, 1) bsl 23) bor (bits(W, 14, 1) bsl 22)
                                      bor (bits(W, 13, 1) bsl 19) bor bits(W, 12, 13)}};
                   false -> {error, malformed}
               end,
    agree(r6, W, ?C:r6(W), Expected).

r7() ->
    W = word(),
    Expected = case is_word(W) of
                   true -> {ok, #{voltage => bits(W, 11, 4), pattern => bits(W, 7, 8)}};
                   false -> {error, malformed}
               end,
    agree(r7, W, ?C:r7(W), Expected).

%%% The CSD and its admission

%% A CSD as the controller hands it over: four words holding the response's
%% bits 127 to 8, built from random fields or entirely random.
csd() ->
    Structure = rand:uniform(4) - 1,
    Len = case rand:uniform(3) of 1 -> 9; _ -> rand:uniform(16) - 1 end,
    Value = case Structure of
                0 -> (Len bsl 80) bor ((rand:uniform(4096) - 1) bsl 62)
                         bor ((rand:uniform(8) - 1) bsl 47);
                1 -> (1 bsl 126) bor (Len bsl 80) bor ((rand:uniform(1 bsl 22) - 1) bsl 48);
                _ -> (Structure bsl 126) bor (rand:uniform(1 bsl 120) - 1)
            end,
    Noise = rand:uniform(1 bsl 128) - 1,
    Raw = case rand:uniform(5) of
              1 -> Noise;
              2 -> Value bor (Noise band ((1 bsl 47) - 1));
              _ -> Value
          end,
    Stored = Raw bsr 8,
    Words = case rand:uniform(10) of
                1 -> [word() || _ <- lists:seq(1, rand:uniform(5))];
                _ -> [(Stored bsr S) band ?MASK32 || S <- [0, 32, 64, 96]]
            end,
    Ccs = rand:uniform(2) =:= 1,
    Said = case ?C:r2(Words) of
               {ok, V} ->
                   (V band 255) =:= 0 orelse error({r2_low_byte, Words, V}),
                   case ?C:csd(V) of
                       {ok, Csd} -> ?C:admit(Ccs, Csd);
                       {error, _} = E -> E
                   end;
               {error, _} = E ->
                   E
           end,
    admitted(Words, Ccs, Said).

%% On an admitted card: the capacity is the specification's formula from
%% the fields read by bit number, and the last sector's address fits the
%% commands' 32-bit argument (bytes on structure 0, blocks on structure 1).
admitted(Words, Ccs, {ok, #{addressing := Addressing, sectors := Sectors}} = Said) ->
    [W0, W1, W2, W3] = Words,
    V = (((W3 bsl 96) bor (W2 bsl 64) bor (W1 bsl 32) bor W0) bsl 8) band ((1 bsl 128) - 1),
    {Bytes, Structure} = case bits(V, 127, 2) of
                             0 -> {(bits(V, 73, 12) + 1) * (1 bsl (bits(V, 49, 3) + 2))
                                       * (1 bsl bits(V, 83, 4)), 0};
                             1 -> {(bits(V, 69, 22) + 1) * 512 * 1024, 1}
                         end,
    Fits = case Addressing of
               byte -> (Sectors - 1) * 512 < 1 bsl 32;
               block -> Sectors - 1 < 1 bsl 32
           end,
    Fits orelse error({last_address_overflow, Words, Ccs, Said}),
    Bytes =:= Sectors * 512 orelse error({capacity_disagrees, Words, Said}),
    {Structure, Ccs, Addressing} =:= {0, false, byte} orelse
        {Structure, Ccs, Addressing} =:= {1, true, block} orelse
        error({addressing_disagrees, Words, Ccs, Said}),
    accepted;
admitted(_Words, _Ccs, {error, _}) ->
    refused.

%%% Registers

scr() ->
    Bytes = case rand:uniform(3) of
                1 -> bytes(8);
                _ -> <<_:4, Rest:60/bitstring>> = rand:bytes(8),
                     <<0:4, Rest/bitstring>>
            end,
    Expected = case Bytes of
                   <<Raw:64>> when Raw bsr 60 =:= 0 ->
                       {ok, #{spec => bits(Raw, 59, 4), four_bit => bits(Raw, 50, 1) =:= 1,
                              extension_registers => bits(Raw, 34, 1) =:= 1}};
                   <<Raw:64>> -> {error, {scr_structure, Raw bsr 60}};
                   _ -> {error, malformed}
               end,
    agree(scr, Bytes, ?C:scr(Bytes), Expected).

sd_status() ->
    Bytes = bytes(64),
    Expected = case Bytes of
                   <<Raw:512>> -> {ok, #{bus_width => bits(Raw, 511, 2),
                                         cache => bits(Raw, 330, 1) =:= 1}};
                   _ -> {error, malformed}
               end,
    agree(sd_status, Bytes, ?C:sd_status(Bytes), Expected).

performance_enhancement() ->
    Bytes = bytes(512),
    Expected = case Bytes of
                   _ when byte_size(Bytes) >= 262 ->
                       At = fun(N) -> binary:at(Bytes, N) end,
                       {ok, #{revision => At(0), cache_support => At(4) band 1 =:= 1,
                              cache_enable => At(260) band 1 =:= 1,
                              flush => At(261) band 1 =:= 1}};
                   _ -> {error, malformed}
               end,
    agree(performance_enhancement, Bytes, ?C:performance_enhancement(Bytes), Expected).

%% A well-formed General Information, then often damaged: a byte changed,
%% cut short, or replaced by noise. Whatever arrives, the parse ends with a
%% value or a refusal, and on an undamaged one finds the first Performance
%% Enhancement function's first register set.
general_information() ->
    Extensions = [{case rand:uniform(3) of 1 -> 2; _ -> rand:uniform(16#FFFF) end,
                   [rand:uniform(1 bsl 22) - 1 || _ <- lists:seq(1, rand:uniform(4) - 1)]}
                  || _ <- lists:seq(1, rand:uniform(20))],
    Good = gi(Extensions),
    {Bytes, Intact} = case rand:uniform(4) of
                          1 -> {damage(Good), false};
                          2 -> {rand:bytes(rand:uniform(1100)), false};
                          _ -> {Good, true}
                      end,
    Said = ?C:general_information(Bytes),
    shape_gi(Bytes, Said),
    case Intact andalso byte_size(Good) =< 1024 of
        true ->
            Expected = case [Sets || {2, Sets} <- Extensions] of
                           [] -> none;
                           [[] | _] -> error;
                           [[First | _] | _] -> {bits(First, 21, 4), bits(First, 16, 17)}
                       end,
            case {Expected, Said} of
                {error, {error, _}} -> refused;
                {P, {ok, #{performance := P}}} -> accepted;
                _ -> error({disagrees_with_reference, general_information, Bytes, Said})
            end;
        false ->
            verdict(Said)
    end.

shape_gi(_Bytes, {ok, #{length := L, extensions := N, performance := P}})
  when is_integer(L), L >= 16, L =< 1024, is_integer(N), N >= 0, N =< 255 ->
    case P of
        none -> ok;
        {Fno, Start} when Fno >= 0, Fno =< 15, Start >= 0, Start =< 16#1FFFF -> ok
    end;
shape_gi(_Bytes, {error, _}) ->
    ok.

gi(Extensions) ->
    Sizes = [44 + 4 * length(Sets) || {_, Sets} <- Extensions],
    Ends = lists:foldl(fun(Size, [Last | _] = Acc) -> [Last + Size | Acc] end, [16], Sizes),
    Starts = lists:reverse(tl(Ends)),
    Nexts = tl(Starts) ++ [0],
    Body = << <<Sfc:16/little, 0:304, Next:16/little, (length(Sets)), 0,
                (<< <<A:32/little>> || A <- Sets >>)/binary>>
              || {{Sfc, Sets}, Next} <- lists:zip(Extensions, Nexts) >>,
    <<0:16, (16 + byte_size(Body)):16/little, (length(Extensions)), 0:88, Body/binary>>.

damage(<<>>) ->
    <<>>;
damage(Bytes) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    case rand:uniform(2) of
        1 -> <<Head:At/binary, _, Tail/binary>> = Bytes,
             <<Head/binary, (rand:uniform(256) - 1), Tail/binary>>;
        2 -> binary:part(Bytes, 0, At)
    end.

%%% The interrupt word

interrupt() ->
    W = word(),
    Names = #{0 => command_complete, 1 => transfer_complete, 4 => buffer_write_ready,
              5 => buffer_read_ready},
    Expected = case is_word(W) andalso W =/= 0 andalso W =/= ?MASK32 of
                   false ->
                       none;
                   true ->
                       Errors = [{error, B} || B <- lists:seq(16, 31), bits(W, B, 1) =:= 1],
                       Summary = [{error, 15} || Errors =:= [], bits(W, 15, 1) =:= 1],
                       Ordered = [maps:get(B, Names) || B <- [0, 4, 5, 1], bits(W, B, 1) =:= 1],
                       {length(Errors ++ Summary), Ordered}
               end,
    Said = ?H:decode(W),
    case {Expected, Said} of
        {none, none} ->
            refused;
        {{ErrorCount, Normal}, Events} when is_list(Events) ->
            {Errs, Rest} = lists:split(ErrorCount, Events),
            true = lists:all(fun({error, _}) -> true; (_) -> false end, Errs),
            Rest =:= Normal orelse error({disagrees_with_reference, interrupt, W, Said}),
            accepted;
        _ ->
            error({disagrees_with_reference, interrupt, W, Said})
    end.

%%% The state machines

%% Random answers, good-looking and malformed, until identification ends;
%% it must end with one terminal action within the bound or keep asking.
identification() ->
    {Actions, S} = ?C:start(),
    walk_identification(Actions, S, 60).

walk_identification(Actions, S, Left) ->
    case lists:last(Actions) of
        {identified, _} -> accepted;
        {refuse, {Phase, _}} when is_atom(Phase) -> refused;
        {issue, _} when Left =:= 0 -> refused;
        {issue, _} ->
            {Next, S1} = ?C:step(S, identification_event()),
            Next =/= [] orelse error({no_action, ?C:phase(S)}),
            walk_identification(Next, S1, Left - 1)
    end.

identification_event() ->
    case rand:uniform(12) of
        1 -> timeout;
        2 -> {error, command_crc};
        3 -> {response, none};
        4 -> {response, [word() || _ <- lists:seq(1, 4)]};
        5 -> {data, word(), rand:bytes(lists:nth(rand:uniform(4), [8, 64, 512, rand:uniform(600)]))};
        6 -> {response, lists:nth(rand:uniform(4), [16#1AA, 16#C0FF8000, 16#80FF8000, 16#B3680500])};
        7 -> rand:bytes(3);
        _ -> {response, lists:nth(rand:uniform(3), [16#900, 16#920, word()])}
    end.

%% Random controller events into a transfer: it never raises, every action
%% has its shape, and it ends with one terminal action.
transfer() ->
    T = ?H:new(#{op => lists:nth(rand:uniform(2), [read, write]), sector => rand:uniform(8) - 1,
                 count => rand:uniform(4), capacity => 12, rca => 7, accepted => 0}),
    walk_transfer(T, 40).

walk_transfer(_T, 0) ->
    refused;
walk_transfer(T, Left) ->
    Event = case rand:uniform(10) of
                1 -> {start, rand:uniform(12000)};
                2 -> {tick, rand:uniform(40000)};
                3 -> {command_complete, word()};
                4 -> {transfer_complete, word()};
                5 -> {error, data_crc};
                6 -> nonsense;
                7 -> buffer_write_ready;
                8 -> buffer_read_ready;
                _ -> {command_complete, 16#900}
            end,
    {Actions, T1} = ?H:step(T, Event),
    lists:foreach(fun transfer_action/1, Actions),
    case [A || A <- Actions, element(1, A) =:= answer orelse element(1, A) =:= fail] of
        [] -> walk_transfer(T1, Left - 1);
        [{answer, ok}] -> accepted;
        [_] -> refused
    end.

transfer_action({issue, transfer}) -> ok;
transfer_action({issue, status}) -> ok;
transfer_action(read_block) -> ok;
transfer_action({write_block, I}) when is_integer(I), I >= 0, I < 4 -> ok;
transfer_action({answer, ok}) -> ok;
transfer_action({answer, {error, {device, deadline}}}) -> ok;
transfer_action({fail, _}) -> ok.

%%% The write path's SD table and the register decisions

%% The identification commands the table lists, with the data each moves: the
%% reference the table must agree with (docs/design-storage.md, "The SD host
%% controller"; erx_blk_sd_card's steps).
listed({cmd, 0}) -> none;
listed({cmd, 2}) -> none;
listed({cmd, 3}) -> none;
listed({cmd, 7}) -> none;
listed({cmd, 8}) -> none;
listed({cmd, 9}) -> none;
listed({cmd, 16}) -> none;
listed({cmd, 48}) -> {read, 512};
listed({cmd, 49}) -> {write, 512};
listed({cmd, 55}) -> none;
listed({acmd, 6}) -> none;
listed({acmd, 13}) -> {read, 64};
listed({acmd, 41}) -> none;
listed({acmd, 51}) -> {read, 8};
listed(_) -> refused.

%% A random step: admitted exactly when the reference lists its command with its
%% data and its argument is a word; an admitted word carries its index, sets no
%% DMA bit and is one erx_device:command/2's field mask allows (bits 0-5 and
%% 16-29); a refused one never raises.
sd_command() ->
    Kind = lists:nth(rand:uniform(3), [cmd, acmd, other]),
    Index = case rand:uniform(2) of
                1 -> lists:nth(rand:uniform(16), [0, 2, 3, 6, 7, 8, 9, 13, 16, 17, 24, 41, 48, 49, 51, 55]);
                2 -> rand:uniform(70) - 3
            end,
    Arg0 = case rand:uniform(8) of 1 -> -rand:uniform(9); 2 -> 1 bsl 32; _ -> word() end,
    %% Half the steps carry the data the reference lists, so the admitting path is tried.
    Data = case rand:uniform(2) =:= 1 andalso listed({Kind, Index}) of
               {read, Size} -> {read, Size};
               {write, Size} -> {write, rand:bytes(Size)};
               none -> none;
               _ -> random_data()
           end,
    %% CMD16 and CMD49 take fixed arguments: half of theirs are ones the rule admits.
    {Arg, Data1} = case rand:uniform(2) =:= 1 andalso {Kind, Index, Data} of
                       {cmd, 16, none} -> {512, Data};
                       {cmd, 49, {write, _}} -> cache_write();
                       _ -> {Arg0, Data}
                   end,
    Step = case Data1 of none -> {Kind, Index, Arg}; _ -> {Kind, Index, Arg, Data1} end,
    Shape = case Data1 of {write, Block} -> {write, byte_size(Block)}; _ -> Data1 end,
    Expected = is_word(Arg) andalso listed({Kind, Index}) =:= Shape andalso argument_ok({Kind, Index}, Arg, Data1),
    case erx_blk_write:sd_command(Step) of
        {ok, #{word := Word, argument := Arg}} when Expected ->
            Index =:= (Word bsr 24) band 63 orelse error({index, Step, Word}),
            Word band 1 =:= 0 orelse error({dma, Step, Word}),
            Word band bnot 16#3FFF003F =:= 0 orelse error({unheld_bits, Step, Word}),
            accepted;
        {error, {sd_refused, _}} when not Expected ->
            refused;
        Said ->
            error({sd_command, Step, Said})
    end.

%% One of the cache rule's two CMD49 writes, at a random function and page:
%% Flush Cache (byte 261) to 1 or Cache Enable (byte 260) to 0, one byte.
cache_write() ->
    {Offset, Value} = lists:nth(rand:uniform(2), [{261, 1}, {260, 0}]),
    Address = rand:uniform(255) * 512 + Offset,
    {((rand:uniform(16) - 1) bsl 27) bor (Address bsl 9), {write, <<Value, 0:(511 * 8)>>}}.

%% The reference of the argument rule (Physical Layer 4.3.2, p.52; 5.7.2.2,
%% p.249; Table 5-30, p.268-269): CMD16 takes 512; CMD49 one byte of memory
%% space without mask, 1 into Flush Cache or 0 into Cache Enable, the rest zero.
argument_ok({cmd, 16}, Arg, _Data) ->
    Arg =:= 512;
argument_ok({cmd, 49}, Arg, {write, <<Value, Rest/binary>>}) when is_integer(Arg) ->
    Byte = (Arg bsr 9) rem 512,
    Arg bsr 31 =:= 0 andalso (Arg bsr 26) band 1 =:= 0 andalso Arg band 511 =:= 0
        andalso Rest =:= <<0:(511 * 8)>> andalso lists:member({Byte, Value}, [{261, 1}, {260, 0}]);
argument_ok({cmd, 49}, _Arg, _Data) ->
    false;
argument_ok(_Command, _Arg, _Data) ->
    true.

%% Random present, capabilities and host version words, some not words at all:
%% each decision agrees with its bits and never raises.
registers() ->
    Word = case rand:uniform(10) of 1 -> -rand:uniform(9); 2 -> 1 bsl 32 + rand:uniform(9); 3 -> nonsense; _ -> word() end,
    Valid = is_word(Word),
    Dat = rand:uniform(2) =:= 1,
    Inhibit = not Valid orelse Word band 1 =/= 0 orelse (Dat andalso Word band 2 =/= 0),
    same(inhibited, Word, ?H:inhibited(Word, Dat), Inhibit),
    same(dat0_high, Word, ?H:dat0_high(Word), Valid andalso Word band (1 bsl 20) =/= 0),
    Base = case Valid andalso bits(Word, 15, 8) of
               false -> {error, no_base_clock};
               0 -> {error, no_base_clock};
               Mhz -> {ok, Mhz * 1000000}
           end,
    agree(base_clock, Word, ?H:base_clock(Word, undefined), Base),
    Version = case Valid andalso bits(Word, 23, 8) of
                  false -> {error, {version, malformed}};
                  Spec when Spec >= 2 -> ok;
                  Spec -> {error, {version, Spec}}
              end,
    agree(version, Word, ?H:version(Word), Version),
    verdict(Version).

random_data() ->
    case rand:uniform(5) of
        1 -> {read, lists:nth(rand:uniform(4), [8, 64, 512, rand:uniform(600)])};
        2 -> {write, rand:bytes(lists:nth(rand:uniform(3), [512, 8, rand:uniform(600)]))};
        _ -> none
    end.

%% A decision that is a boolean, against its reference.
same(_Name, _Input, Said, Said) -> ok;
same(Name, Input, Said, Expected) -> error({disagrees_with_reference, Name, Input, Said, Expected}).
