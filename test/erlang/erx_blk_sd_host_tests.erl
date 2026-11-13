%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_blk_sd_host (docs/design-storage.md, "The SD host
%% controller" and "Verification and testing"): the interrupt decode against
%% the register's bit table, the divider as a property over base clocks and
%% targets, and the transfer exhaustively: every event sequence of every
%% shape of request, explored until the transfer ends, against oracle/3, a
%% statement of what the specification and the design accept at each point.

-module(erx_blk_sd_host_tests).
-include_lib("eunit/include/eunit.hrl").

-define(H, erx_blk_sd_host).
-define(RCA, 16#B368).
-define(ISSUED, 1000).

%%% The interrupt word

%% Host Controller 2.2.17-2.2.18 (p.80-86): normal status bits 0-15, error
%% status bits 16-31.
names() ->
    #{0 => command_complete, 1 => transfer_complete, 4 => buffer_write_ready,
      5 => buffer_read_ready, 16 => {error, command_timeout}, 17 => {error, command_crc},
      18 => {error, command_end_bit}, 19 => {error, command_index},
      20 => {error, data_timeout}, 21 => {error, data_crc}, 22 => {error, data_end_bit},
      23 => {error, current_limit}, 24 => {error, auto_cmd}, 25 => {error, adma},
      26 => {error, tuning}, 27 => {error, response}, 28 => {error, {vendor, 28}},
      29 => {error, {vendor, 29}}, 30 => {error, {vendor, 30}}, 31 => {error, {vendor, 31}}}.

decode_none_test() ->
    ?assertEqual(none, ?H:decode(0)),
    ?assertEqual(none, ?H:decode(16#FFFFFFFF)),
    ?assertEqual(none, ?H:decode(-1)),
    ?assertEqual(none, ?H:decode(1 bsl 32)),
    ?assertEqual(none, ?H:decode(nonsense)).

decode_each_bit_test() ->
    lists:foreach(fun(Bit) ->
                          Expected = case maps:find(Bit, names()) of
                                         {ok, Event} -> [Event];
                                         error when Bit =:= 15 -> [{error, error_interrupt}];
                                         error -> []
                                     end,
                          ?assertEqual(Expected, ?H:decode(1 bsl Bit))
                  end, lists:seq(0, 31)).

decode_property_test() ->
    rand:seed(exsss, {20, 26, 1}),
    lists:foreach(
      fun(_) ->
              Word = rand:uniform(16#FFFFFFFE),
              Events = ?H:decode(Word),
              Set = [maps:get(B, names()) || B <- lists:seq(0, 31), Word band (1 bsl B) =/= 0,
                                             maps:is_key(B, names())],
              Errors = [E || {error, _} = E <- Set],
              Summary = [{error, error_interrupt} || Errors =:= [], Word band 16#8000 =/= 0],
              ?assertEqual(lists:sort(Set ++ Summary), lists:sort(Events)),
              %% Errors come before anything acts on the data.
              {Front, _} = lists:split(length(Errors ++ Summary), Events),
              ?assertEqual(lists:sort(Errors ++ Summary), lists:sort(Front))
      end, lists:seq(1, 5000)).

%%% The divider

divider_property_test() ->
    Bases = [1, 2, 3, 400000, 41666666, 50000000, 100000000, 200000000, 250000000, 255000000],
    Targets = fun(Base) ->
                      Exact = [Base div D || D <- [1, 2, 3, 4, 250, 1022, 1023, 2046], Base div D > 0],
                      lists:usort([1, 200000, 400000, 25000000, Base, Base + 1 | Exact]
                                  ++ [T + Delta || T <- Exact, Delta <- [-1, 1], T + Delta > 0])
              end,
    Cases = [{B, T} || B <- Bases, T <- Targets(B)],
    lists:foreach(fun divider_case/1, Cases),
    io:format(user, "~ndivider: ~p cases~n", [length(Cases)]).

%% The chosen clock is at most the target and the next smaller divisor would
%% exceed it; the bits give back half the divisor.
divider_case({Base, Target}) ->
    case ?H:divider(Base, Target) of
        {ok, 1, 0} ->
            ?assert(Target >= Base);
        {ok, Divisor, Bits} ->
            ?assert(Target < Base),
            ?assertEqual(0, Divisor rem 2),
            ?assert(Divisor =< 2046),
            ?assert(Base =< Target * Divisor),
            ?assert(Divisor =:= 2 orelse Base > Target * (Divisor - 2)),
            ?assertEqual(Divisor div 2, ((Bits bsr 8) band 16#FF) bor (((Bits bsr 6) band 3) bsl 8)),
            ?assertEqual(0, Bits band 16#3F);
        {error, too_slow} ->
            ?assert(Base > Target * 2046)
    end.

divider_known_values_test() ->
    %% 100 MHz to 400 kHz is 250, half 125; to 25 MHz is 4, half 2.
    ?assertEqual({ok, 250, 125 bsl 8}, ?H:divider(100000000, 400000)),
    ?assertEqual({ok, 4, 2 bsl 8}, ?H:divider(100000000, 25000000)),
    ?assertEqual({ok, 2046, (16#FF bsl 8) bor (3 bsl 6)}, ?H:divider(2046, 1)),
    ?assertEqual({error, too_slow}, ?H:divider(2047, 1)),
    ?assertEqual({error, bad_clock}, ?H:divider(0, 1)).

%%% The transfer's deadlines

request(Op, Sector, Count) ->
    ?H:new(#{op => Op, sector => Sector, count => Count, capacity => 64, rca => ?RCA,
             accepted => 0}).

wait_limit_test() ->
    T = request(read, 0, 1),
    ?assertEqual(10000, ?H:deadline(T)),
    ?assertMatch({[{issue, transfer}], _}, ?H:step(T, {start, 9999})),
    ?assertMatch({[{answer, {error, {device, deadline}}}], _}, ?H:step(T, {start, 10000})),
    ?assertMatch({[], _}, ?H:step(T, {tick, 9999})),
    {[{answer, {error, {device, deadline}}}], Done} = ?H:step(T, {tick, 10000}),
    ?assertEqual(none, ?H:deadline(Done)).

in_flight_bound_test() ->
    {_, T} = ?H:step(request(write, 0, 2), {start, 9000}),
    ?assertEqual(27000, ?H:deadline(T)),
    ?assertMatch({[], _}, ?H:step(T, {tick, 26999})),
    ?assertMatch({[{fail, in_flight_bound}], _}, ?H:step(T, {tick, 27000})).

%% Each layer answers before its caller gives up: erx_blk:call/1 waits 30 s.
deadlines_below_the_callers_test() ->
    ?assert(?H:wait_limit_ms() + ?H:in_flight_ms() < 30000).

%%% The transfer, exhaustively

%% The events the exploration offers at every point.
alphabet() ->
    [{command_complete, 16#900}, {command_complete, 16#E00}, {command_complete, 1 bsl 19},
     {command_complete, 1 bsl 31}, {command_complete, -1},
     buffer_read_ready, buffer_write_ready,
     {transfer_complete, 16#900}, {transfer_complete, 16#80000900},
     {transfer_complete, 16#80080900}, {transfer_complete, 1 bsl 33},
     {error, data_crc}, {error, auto_cmd}, {tick, ?ISSUED + 100}, {tick, ?ISSUED + 18000},
     {start, ?ISSUED}, nonsense].

%% What the specification and the design accept, as a script of the events
%% a good transfer sees: the command's R1, one buffer event per block,
%% transfer complete with Auto CMD12's R1, and after a write CMD13's R1.
script(read, Count) -> [command] ++ lists:duplicate(Count, block) ++ [transfer];
script(write, Count) -> [command] ++ lists:duplicate(Count, block) ++ [transfer, status].

%% {continue, Actions} or fail, for Event where the script expects What.
oracle(_Shape, _What, {tick, Now}) when Now - ?ISSUED < 18000 -> {continue, []};
oracle(_Shape, _What, {tick, _}) -> fail;
oracle(_Shape, _What, {error, _}) -> fail;
oracle(_Shape, command, {command_complete, R1}) ->
    case no_error(R1) of
        true -> {continue, []};
        false -> fail
    end;
oracle({read, _, _, _Moved}, block, buffer_read_ready) -> {continue, [read_block]};
oracle({write, _, _, Moved}, block, buffer_write_ready) -> {continue, [{write_block, Moved}]};
oracle({Op, Count, Last, _}, transfer, {transfer_complete, Auto}) ->
    %% Auto CMD12 runs only after more than one block; out of range alone
    %% is no error on a CMD18 that ended at the last sector (p.52).
    Ignored = case {Op, Last} of {read, true} -> 1 bsl 31; _ -> 0 end,
    Ok = Count =:= 1 orelse (is_integer(Auto) andalso no_error(Auto band bnot Ignored)),
    case {Ok, Op} of
        {true, read} -> {continue, [{answer, ok}]};
        {true, write} -> {continue, [{issue, status}]};
        {false, _} -> fail
    end;
oracle(_Shape, status, {command_complete, R1}) ->
    %% CMD13: no error, the transfer state and ready for data (p.54).
    case no_error(R1) andalso (R1 bsr 9) band 15 =:= 4 andalso R1 band 16#100 =/= 0 of
        true -> {continue, [{answer, ok}]};
        false -> fail
    end;
oracle(_Shape, _What, _Event) ->
    fail.

no_error(R1) ->
    is_integer(R1) andalso R1 >= 0 andalso R1 =< 16#FFFFFFFF andalso
        R1 band erx_blk_sd_card:r1_error_mask() =:= 0.

every_transfer_sequence_test_() ->
    {timeout, 120,
     fun() ->
             Shapes = [{Op, Sector, Count} || Op <- [read, write], Count <- [1, 2, 3],
                                              Sector <- [0, 64 - Count]],
             Nodes = lists:sum([explore(Op, Sector, Count) || {Op, Sector, Count} <- Shapes]),
             io:format(user, "~ntransfer: ~p shapes, ~p event sequences~n",
                       [length(Shapes), Nodes])
     end}.

explore(Op, Sector, Count) ->
    {[{issue, transfer}], T} = ?H:step(request(Op, Sector, Count), {start, ?ISSUED}),
    Last = Sector + Count =:= 64,
    walk(T, {Op, Count, Last}, script(Op, Count), 0, [], 2).

%% Every event at this point; a sequence ends when the transfer ends, and
%% early ticks are offered at most Ticks times in a row so the walk ends.
walk(T, Shape, Script, Moved, Path, Ticks) ->
    lists:sum([visit(T, Shape, Script, Moved, Path, Ticks, E) || E <- alphabet(),
                                                                 Ticks > 0 orelse not early(E)]).

early({tick, Now}) -> Now - ?ISSUED < 18000;
early(_) -> false.

visit(T, {Op, Count, Last} = Shape, [What | Rest] = Script, Moved, Path, Ticks, Event) ->
    Path1 = [Event | Path],
    {Actions, T1} = ?H:step(T, Event),
    case {oracle({Op, Count, Last, Moved}, What, Event), Actions} of
        {fail, [{fail, _}]} ->
            ?assertEqual(done, ?H:phase(T1)),
            1;
        {{continue, Expected}, Expected} ->
            case early(Event) of
                true ->
                    1 + walk(T1, Shape, Script, Moved, Path1, Ticks - 1);
                false ->
                    Moved1 = case What of block -> Moved + 1; _ -> Moved end,
                    1 + next(T1, Shape, Rest, Moved1, Path1)
            end;
        Mismatch ->
            error({disagrees, lists:reverse(Path1), Shape, Mismatch})
    end.

next(T, _Shape, [], _Moved, _Path) ->
    ?assertEqual(done, ?H:phase(T)),
    lists:foreach(fun(E) -> ?assertMatch({[], _}, ?H:step(T, E)) end, alphabet()),
    0;
next(T, Shape, Script, Moved, Path) ->
    walk(T, Shape, Script, Moved, Path, 2).

%%% The Auto CMD12 rule, by name

out_of_range_on_the_last_sector_of_a_multi_block_read_is_ignored_test() ->
    ?assertEqual([{answer, ok}], finish(read, 62, 2, 16#80000900)).

out_of_range_elsewhere_fails_the_transfer_test() ->
    ?assertMatch([{fail, {auto_cmd12, _}}], finish(read, 0, 2, 16#80000900)),
    ?assertMatch([{fail, {auto_cmd12, _}}], finish(write, 62, 2, 16#80000900)),
    ?assertMatch([{fail, {auto_cmd12, _}}], finish(read, 62, 2, 16#80080900)).

finish(Op, Sector, Count, Auto) ->
    {_, T0} = ?H:step(request(Op, Sector, Count), {start, ?ISSUED}),
    {[], T1} = ?H:step(T0, {command_complete, 16#900}),
    Ready = case Op of read -> buffer_read_ready; write -> buffer_write_ready end,
    T2 = lists:foldl(fun(_, T) -> element(2, ?H:step(T, Ready)) end, T1, lists:seq(1, Count)),
    element(1, ?H:step(T2, {transfer_complete, Auto})).

%%% The 1.8 V refusal

%% Host control 2's 1.8 V signalling enable, bit 3 of the register at 0x3E,
%% is bit 19 of the control2 word; it alone refuses the start.
signalling_test() ->
    ?assertEqual({error, needs_power_cycle}, ?H:signalling(1 bsl 19)),
    ?assertEqual({error, needs_power_cycle}, ?H:signalling(16#FFFFFFFF)),
    ?assertEqual(ok, ?H:signalling(16#FFFFFFFF band bnot (1 bsl 19))),
    ?assertEqual(ok, ?H:signalling(0)),
    ?assertEqual({error, malformed}, ?H:signalling(1 bsl 32)).

%%% The write-back, the enables and the register decisions

%% Bits 0-7 and 16-31 are one to clear; 8-12 and 15 follow their sources, 13-14 are
%% reserved (Host Controller 2.2.18-2.2.19, p.76-85).
ack_and_enable_masks_test() ->
    ?assertEqual(16#FFFF00FF, ?H:ack_mask()),
    ?assertEqual(16#FFFF0033, ?H:enable_mask()).

decode_response_and_vendor_bits_test() ->
    ?assertEqual([{error, response}], ?H:decode(1 bsl 27)),
    ?assertEqual([{error, {vendor, 28}}, {error, {vendor, 31}}], ?H:decode((1 bsl 28) bor (1 bsl 31))).

inhibited_test_() ->
    [?_assertNot(?H:inhibited(0, false)),
     ?_assertNot(?H:inhibited(0, true)),
     ?_assert(?H:inhibited(1, false)),
     ?_assertNot(?H:inhibited(2, false)),
     ?_assert(?H:inhibited(2, true)),
     ?_assert(?H:inhibited(-1, false)),
     ?_assert(?H:inhibited(nonsense, false))].

dat0_test_() ->
    [?_assert(?H:dat0_high(16#01ff0000)),
     ?_assertNot(?H:dat0_high(16#01ef0000)),
     ?_assertNot(?H:dat0_high(1 bsl 32))].

base_clock_test_() ->
    %% The model's capabilities word: base clock 52 MHz (research-sdhci-qemu-model.md).
    [?_assertEqual({ok, 52000000}, ?H:base_clock(16#052134b4, undefined)),
     ?_assertEqual({ok, 100000000}, ?H:base_clock(16#052100b4, 100000000)),
     ?_assertEqual({error, no_base_clock}, ?H:base_clock(16#052100b4, undefined)),
     ?_assertEqual({error, no_base_clock}, ?H:base_clock(16#052100b4, 0)),
     ?_assertEqual({error, no_base_clock}, ?H:base_clock(-1, undefined))].

version_test_() ->
    %% The model's host version word reads 3.00 (research-sdhci-qemu-model.md).
    [?_assertEqual(ok, ?H:version(16#24020000)),
     ?_assertEqual(ok, ?H:version(16#00050000)),
     ?_assertEqual({error, {version, 1}}, ?H:version(16#00010000)),
     ?_assertEqual({error, {version, malformed}}, ?H:version(nonsense))].

%% A flush is CMD13 alone, answered as a write's status.
flush_test_() ->
    New = ?H:new(#{op => flush, accepted => 0}),
    {Issue, Issued} = ?H:step(New, {start, ?ISSUED}),
    [?_assertEqual([{issue, status}], Issue),
     ?_assertEqual(?ISSUED + 18000, ?H:deadline(Issued)),
     ?_assertMatch({[{answer, ok}], _}, ?H:step(Issued, {command_complete, 16#900})),
     ?_assertMatch({[{fail, {not_ready, _}}], _}, ?H:step(Issued, {command_complete, 16#800})),
     ?_assertMatch({[{fail, {interrupt, command_timeout}}], _}, ?H:step(Issued, {error, command_timeout})),
     ?_assertMatch({[{fail, {unexpected, status, buffer_read_ready}}], _}, ?H:step(Issued, buffer_read_ready))].

%% spaced/2 makes its write and leaves at least 6 us between two writes.
spaced_test() ->
    Self = self(),
    Write = fun() -> Self ! {wrote, erlang:monotonic_time(microsecond)}, ok end,
    Regs = erx_blk_sd_regs:spaced(erx_blk_sd_regs:spaced(erx_blk_sd_regs:new(0), Write), Write),
    ?assertEqual(0, erx_blk_sd_regs:device(Regs)),
    First = receive {wrote, T1} -> T1 end,
    Second = receive {wrote, T2} -> T2 end,
    ?assert(Second - First >= 6).
