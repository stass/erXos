%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_blk_sd_card, the SD card's identification and parsers
%% (docs/design-storage.md, "The SD host controller" and "Verification and
%% testing"). Identification runs against erx_blk_sd_card_model, a card
%% written from the specification, over a matrix of cards whose outcome
%% expected/1 states from the card's parameters alone; then every state the
%% runs reached is given every event of a fixed alphabet. The parsers are
%% checked on known values and by properties over their fields.

-module(erx_blk_sd_card_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, erx_blk_sd_card_model).
-define(EVENT_BUDGET, 5000).
-define(R1_ERROR_BITS, [31, 30, 29, 28, 27, 26, 24, 23, 22, 21, 20, 19, 16, 15, 3]).
-define(R1_PHASES, [app_inquiry, app_init, select, blocklen, app_scr, app_bus, bus,
                    app_status, flush_write, disable_write]).
-define(DATA_PHASES, [scr, sd_status, gi_page0, gi_page1, pe_read, flush_poll, disable_check]).
-define(ALL_PHASES, [go_idle_1, if_cond_1, app_inquiry, op_inquiry, go_idle_2, if_cond_2,
                     app_init, op_init, all_send_cid, send_rca, send_csd, select, blocklen,
                     app_scr, scr, app_bus, bus, app_status, sd_status, gi_page0, gi_page1,
                     pe_read, flush_write, flush_poll, disable_write, disable_check,
                     finished]).

%%% Running identification against the model

%% A card's parameters, with csd_fields turned into its CSD.
card(Params) ->
    Csd = case maps:get(csd_fields, Params, {1, 9, 8191}) of
              {0, Len, CSize, Mult} -> ?M:csd_v1(Len, CSize, Mult);
              {1, 9, CSize} -> ?M:csd_v2(CSize)
          end,
    ?M:card(maps:merge(#{csd => Csd}, maps:without([csd_fields, gi_kind], Params))).

%% Runs identification to its end: {Outcome, Actions, Card, States}, States
%% each state with the phase it was in when an event reached it.
run(Params) ->
    {Actions, State} = erx_blk_sd_card:start(),
    loop(Actions, State, card(Params), [], [], ?EVENT_BUDGET).

loop(_Actions, _State, _Card, _Seen, _States, 0) ->
    error(event_budget_spent);
loop(Actions, State, Card, Seen, States, Budget) ->
    lists:foreach(fun valid_action/1, Actions),
    Seen1 = Seen ++ Actions,
    case lists:last(Actions) of
        {issue, Step} ->
            [] = [A || A <- lists:droplast(Actions), element(1, A) =:= issue],
            {Event, Card1} = ?M:command(Step, Card),
            {Next, State1} = erx_blk_sd_card:step(State, Event),
            loop(Next, State1, Card1, Seen1, [State | States], Budget - 1);
        {identified, _} = Done ->
            {Done, Seen1, Card, lists:reverse([State | States])};
        {refuse, _} = Done ->
            {Done, Seen1, Card, lists:reverse([State | States])}
    end.

valid_action({issue, {Kind, Index, Arg}}) when (Kind =:= cmd orelse Kind =:= acmd),
                                               Index >= 0, Index < 64, Arg >= 0,
                                               Arg =< 16#FFFFFFFF -> ok;
valid_action({issue, {Kind, Index, Arg, {read, N}}}) when (Kind =:= cmd orelse Kind =:= acmd),
                                                          Index >= 0, Index < 64, Arg >= 0,
                                                          Arg =< 16#FFFFFFFF, N > 0 -> ok;
valid_action({issue, {cmd, 49, Arg, {write, Block}}}) when Arg >= 0, Arg =< 16#FFFFFFFF,
                                                           byte_size(Block) =:= 512 -> ok;
valid_action({reset, Line}) when Line =:= cmd; Line =:= dat -> ok;
valid_action({wait, Ms}) when is_integer(Ms), Ms > 0 -> ok;
valid_action({bus_width, 4}) -> ok;
valid_action({clock, 25000000}) -> ok;
valid_action({identified, #{sectors := S}}) when is_integer(S), S > 0 -> ok;
valid_action({refuse, {Phase, _}}) when is_atom(Phase) -> ok.

%%% The oracle: what the specification and the design say a card's
%%% identification ends in, from its parameters alone.

expected(Params) ->
    P = maps:merge(#{version => 2, hc => true, window => 16#FF8000, busy => 3, rca => 16#B368,
                     csd_fields => {1, 9, 8191}, locked => false, scr => ?M:scr(5, false),
                     status => ?M:sd_status(false), cache_on => false, flush_reads => 2,
                     disable_sticks => false, second_cmd8 => same, gi_kind => ok},
                   Params),
    #{version := Version, hc := Hc, window := Window, busy := Busy, rca := Rca,
      csd_fields := Fields, locked := Locked, scr := Scr, status := Status,
      cache_on := On, flush_reads := Reads, disable_sticks := Sticks,
      second_cmd8 := Second, gi_kind := GiKind} = P,
    <<_:12, Widths:4, _:13, Ext:1, _/bitstring>> = Scr,
    <<_:181, Cache:1, _/bitstring>> = Status,
    GiPhase = case GiKind of long -> gi_page1; _ -> gi_page0 end,
    Capacity = capacity(Hc, Fields),
    if
        Window band 16#300000 =:= 0 -> {refused, op_inquiry};
        Version =:= 2, Second =:= flip -> {refused, if_cond_2};
        Version =:= 1, Hc; Busy >= 1000 -> {refused, op_init};
        Rca =:= 0 -> {refused, send_rca};
        Capacity =:= refused -> {refused, send_csd};
        Locked -> {refused, select};
        Widths band 4 =:= 0 -> {refused, scr};
        Cache =:= 0 -> {identified, Capacity, absent};
        Ext =:= 0 -> {refused, sd_status};
        GiKind =:= no_pe; GiKind =:= unaligned; GiKind =:= malformed -> {refused, GiPhase};
        not On -> {identified, Capacity, off};
        Reads >= 100 -> {refused, flush_poll};
        Sticks -> {refused, disable_check};
        true -> {identified, Capacity, flushed}
    end.

%% Physical Layer 5.3.2 (p.229) and 5.3.3 (p.235), in 512-byte sectors.
capacity(false, {0, Len, CSize, Mult}) when Len >= 9, Len =< 11 ->
    {byte, (CSize + 1) * (1 bsl (Mult + 2)) * (1 bsl Len) div 512};
capacity(true, {1, 9, CSize}) ->
    {block, (CSize + 1) * 1024};
capacity(_, _) ->
    refused.

outcome({identified, #{addressing := A, sectors := S, cache := Cache}}) ->
    {identified, {A, S}, Cache};
outcome({refuse, {Phase, _}}) ->
    {refused, Phase}.

%%% The matrix of cards

cache_card(Extra) ->
    maps:merge(#{status => ?M:sd_status(true), scr => ?M:scr(5, true), cache_on => true},
               Extra).

long_gi() ->
    ?M:general_information([{16#10 + N, []} || N <- lists:seq(1, 12)] ++ [{2, [{3, 0}]}]).

cards() ->
    [#{},
     #{hc => false, csd_fields => {0, 9, 4095, 7}},
     #{version => 1, hc => false, csd_fields => {0, 10, 4095, 7}},
     #{version => 1, hc => false, csd_fields => {0, 11, 4095, 7}},
     #{version => 1, hc => true},
     #{busy => 0}, #{busy => 998}, #{busy => 999}, #{busy => 1000},
     #{version => 1, hc => false, csd_fields => {0, 9, 10, 0}, busy => 999},
     #{window => 16#100000}, #{window => 16#200000}, #{window => 16#008000},
     #{window => 16#C00000},
     #{second_cmd8 => flip},
     #{rca => 0}, #{rca => 1}, #{rca => 16#FFFF},
     #{csd_fields => {0, 9, 100, 3}},
     #{hc => false, csd_fields => {1, 9, 8191}},
     #{hc => false, csd_fields => {0, 12, 4095, 7}},
     #{hc => false, csd_fields => {0, 8, 4095, 7}},
     #{hc => false, csd_fields => {0, 15, 4095, 7}},
     #{csd_fields => {1, 9, 16#3FFFFF}}, #{csd_fields => {1, 9, 0}},
     #{locked => true},
     #{scr => ?M:scr(1, false)}, #{scr => ?M:scr(4, false)},
     #{status => ?M:sd_status(true)},
     #{status => ?M:sd_status(false), scr => ?M:scr(5, true)},
     cache_card(#{cache_on => false}),
     cache_card(#{flush_reads => 0}), cache_card(#{flush_reads => 2}),
     cache_card(#{flush_reads => 99}), cache_card(#{flush_reads => 100}),
     cache_card(#{disable_sticks => true}),
     cache_card(#{version => 1, hc => false, csd_fields => {0, 9, 4095, 7}}),
     cache_card(#{gi => ?M:general_information([{1, []}, {7, [{2, 0}]}]), gi_kind => no_pe}),
     cache_card(#{gi => ?M:general_information([{2, [{2, 4}]}]), pe_start => 4,
                  gi_kind => unaligned}),
     cache_card(#{gi => ?M:general_information([{2, [{5, 512}]}]), pe_fno => 5,
                  pe_start => 512}),
     cache_card(#{gi => ?M:general_information([{2, []}]), gi_kind => malformed}),
     cache_card(#{gi => <<0:16, 2000:16/little, 1, 0:88>>, gi_kind => malformed}),
     cache_card(#{gi => long_gi(), pe_fno => 3, gi_kind => long})].

matrix_test_() ->
    [{lists:flatten(io_lib:format("~0p", [maps:without([gi, scr, status], Card)])),
      fun() ->
              {Done, _Actions, Model, _States} = run(Card),
              ?assertEqual(expected(Card), outcome(Done)),
              ?assertEqual([], ?M:violations(Model))
      end} || Card <- cards()].

%%% Named cases of the design

the_sequence_of_a_high_capacity_card_test() ->
    {{identified, Card}, _, Model, _} = run(#{busy => 1}),
    ?assertMatch(#{addressing := block, sectors := 8388608, cmd8 := echoed, cache := absent,
                   rca := 16#B368}, Card),
    ?assertEqual([{cmd, 0}, {cmd, 8}, {cmd, 55}, {acmd, 41}, {cmd, 0}, {cmd, 8},
                  {cmd, 55}, {acmd, 41}, {cmd, 55}, {acmd, 41}, {cmd, 2}, {cmd, 3}, {cmd, 9},
                  {cmd, 7}, {cmd, 55}, {acmd, 51}, {cmd, 55}, {acmd, 6}, {cmd, 55}, {acmd, 13}],
                 ?M:trace(Model)).

a_standard_capacity_card_sets_its_block_length_test() ->
    {{identified, Card}, Actions, Model, _} =
        run(#{version => 1, hc => false, busy => 0, csd_fields => {0, 10, 4095, 7}}),
    ?assertMatch(#{addressing := byte, sectors := 4194304, cmd8 := timeout}, Card),
    ?assert(lists:member({issue, {cmd, 16, 512}}, Actions)),
    ?assertMatch([_, _, _, _, _, _, _, _, {cmd, 2}, {cmd, 3}, {cmd, 9}, {cmd, 7}, {cmd, 16} | _],
                 ?M:trace(Model)),
    %% ACMD41 offers 3.2-3.4 V and no HCS after CMD8 timed out.
    ?assert(lists:member({issue, {acmd, 41, 16#00300000}}, Actions)).

%% CMD8's timeout returns the command and data line resets and CMD55, in
%% that order, and the illegal-command bit of the next R1 is accepted.
cmd8_timeout_resets_both_lines_then_asks_cmd55_test() ->
    {_, S0} = erx_blk_sd_card:start(),
    {_, S1} = erx_blk_sd_card:step(S0, {response, none}),
    ?assertEqual(if_cond_1, erx_blk_sd_card:phase(S1)),
    {Actions, S2} = erx_blk_sd_card:step(S1, timeout),
    ?assertEqual([{reset, cmd}, {reset, dat}, {issue, {cmd, 55, 0}}], Actions),
    {Next, _} = erx_blk_sd_card:step(S2, {response, 16#00400020}),
    ?assertEqual([{issue, {acmd, 41, 0}}], Next).

illegal_command_without_a_cmd8_timeout_is_refused_test() ->
    {_, S0} = erx_blk_sd_card:start(),
    {_, S1} = erx_blk_sd_card:step(S0, {response, none}),
    {_, S2} = erx_blk_sd_card:step(S1, {response, 16#1AA}),
    ?assertMatch({[{refuse, {app_inquiry, {r1, 16#00400020}}}], _},
                 erx_blk_sd_card:step(S2, {response, 16#00400020})).

%% The cache step over scripted answers (the design's four cases).
cache_without_sd_status_bit_330_is_skipped_test() ->
    ?assertMatch({{identified, #{cache := absent}}, _, _, _},
                 run(#{scr => ?M:scr(5, true)})).

cache_without_cmd48_is_refused_test() ->
    ?assertMatch({{refuse, {sd_status, cache_without_extension_registers}}, _, _, _},
                 run(#{status => ?M:sd_status(true)})).

enabled_cache_is_flushed_disabled_and_read_back_test() ->
    {{identified, #{cache := flushed}}, Actions, Model, _} = run(cache_card(#{})),
    Writes = [{Arg band 16#7FFFFE00, Block} || {issue, {cmd, 49, Arg, {write, Block}}} <- Actions],
    ?assertMatch([{A1, <<1, _/binary>>}, {A0, <<0, _/binary>>}]
                 when A1 =:= (2 bsl 27) bor (261 bsl 9) andalso
                      A0 =:= (2 bsl 27) bor (260 bsl 9), Writes),
    ?assertEqual({cmd, 48}, lists:last(?M:trace(Model))).

cache_still_enabled_after_the_write_is_refused_test() ->
    ?assertMatch({{refuse, {disable_check, cache_still_enabled}}, _, _, _},
                 run(cache_card(#{disable_sticks => true}))).

%%% Every state, every event

alphabet() ->
    [timeout, {error, command_crc}, {error, deadline}, {response, none}, {response, 0},
     {response, 16#900}, {response, 16#1AA}, {response, 16#80FF8000}, {response, 16#C0FF8000},
     {response, 16#B3680500}, {response, [0, 0, 0, 0]},
     {response, ?M:r2_words(?M:csd_v2(8191))}, {data, 16#900, ?M:scr(5, true)},
     {data, 16#900, ?M:sd_status(true)}, {data, 16#900, <<0:4096>>},
     {data, 16#900, <<1:4096>>}]
        ++ garbage() ++ [{response, 1 bsl Bit} || Bit <- ?R1_ERROR_BITS]
        ++ [{data, 1 bsl Bit, <<0:4096>>} || Bit <- ?R1_ERROR_BITS]
        %% R6 words whose bits 15, 14 and 13 carry card status 23, 22 and 19.
        ++ [{response, 16#B3680000 bor (1 bsl Bit)} || Bit <- [15, 14, 13]].

garbage() ->
    [{response, -1}, {response, 1 bsl 32}, {response, [1, 2]}, {response, [-1, 0, 0, 0]},
     {data, none, <<>>}, {data, -1, <<0:4096>>}, {data, 16#900, not_binary}, nonsense,
     {response}, {error}, {data, 16#900}, {response, <<1>>}].

%% For each card version, a state of each phase on its first visit in a run
%% and one on a later visit (the ACMD41 loop and the flush poll repeat).
states() ->
    lists:foldl(fun(Card, Acc) ->
                        {_, _, _, States} = run(Card),
                        keep(States, maps:get(version, Card, 2), [], Acc)
                end, #{}, cards()).

keep([], _Version, _Seen, Acc) ->
    Acc;
keep([S | States], Version, Seen, Acc) ->
    Phase = erx_blk_sd_card:phase(S),
    Visit = case lists:member(Phase, Seen) of
                true -> later;
                false -> first
            end,
    %% The first state stored under a key stays.
    keep(States, Version, [Phase | Seen], maps:merge(#{{Phase, Version, Visit} => S}, Acc)).

every_state_takes_every_event_test_() ->
    {timeout, 120,
     fun() ->
             States = states(),
             Phases = lists:usort([P || {P, _, _} <- maps:keys(States)]),
             ?assertEqual(lists:sort(?ALL_PHASES), Phases),
             Pairs = [{Key, S, E} || {Key, S} <- maps:to_list(States), E <- alphabet()],
             lists:foreach(fun check_pair/1, Pairs),
             io:format(user, "~nidentification: ~p states x ~p events = ~p pairs~n",
                       [maps:size(States), length(alphabet()), length(Pairs)])
     end}.

check_pair({{Phase, Version, Visit} = Key, S, Event}) ->
    {Actions, S1} = try erx_blk_sd_card:step(S, Event)
                    catch C:R -> error({raised, Key, Event, C, R})
                    end,
    lists:foreach(fun valid_action/1, Actions),
    Expect = expected_pair(Phase, Version, Visit, Event),
    case {Expect, Actions} of
        {none, []} -> ?assertEqual(finished, erx_blk_sd_card:phase(S1));
        {resets, [{reset, cmd}, {reset, dat}, {issue, {cmd, 55, 0}}]} -> ok;
        {refuse, [{refuse, {Phase, _}}]} -> ?assertEqual(finished, erx_blk_sd_card:phase(S1));
        {accept, [_ | _]} -> ?assertMatch({issue, _}, lists:last(Actions));
        {any, _} -> ok;
        _ -> error({unexpected, Key, Event, Expect, Actions})
    end.

expected_pair(finished, _, _, _) -> none;
expected_pair(if_cond_1, _, _, timeout) -> resets;
expected_pair(if_cond_2, 1, _, timeout) -> resets;
expected_pair(_, _, _, timeout) -> refuse;
expected_pair(_, _, _, {error, _}) -> refuse;
expected_pair(send_rca, _, _, {response, R6}) when is_integer(R6), R6 band 16#E000 =/= 0 -> refuse;
expected_pair(Phase, _, _, {data, R1, _}) when is_integer(R1), R1 band 16#FDF98008 =/= 0 ->
    case lists:member(Phase, ?DATA_PHASES) of
        true -> refuse;
        false -> any
    end;
expected_pair(Phase, Version, Visit, {response, R1} = Event) when is_integer(R1) ->
    case lists:member(Phase, ?R1_PHASES) of
        true when R1 =:= 1 bsl 22, Version =:= 1, Visit =:= first,
                  (Phase =:= app_inquiry orelse Phase =:= app_init) -> any;
        true when R1 band (16#FDF98008) =/= 0 -> refuse;
        true when R1 < 0; R1 > 16#FFFFFFFF -> refuse;
        true when R1 =:= 16#900 -> accept;
        _ -> garbage_or_any(Event)
    end;
expected_pair(_, _, _, Event) ->
    garbage_or_any(Event).

garbage_or_any(Event) ->
    case lists:member(Event, garbage()) of
        true -> refuse;
        false -> any
    end.

%%% Admission: a property over every structure, capacity bit, READ_BL_LEN,
%%% C_SIZE and C_SIZE_MULT.

admission_property_test_() ->
    {timeout, 60,
     fun() ->
             CSizes12 = [0, 1, 2047, 4094, 4095],
             CSizes22 = [0, 1, 8191, 16#3FFFFE, 16#3FFFFF],
             Cases = [{Ccs, {0, Len, C, M}} || Ccs <- [false, true], Len <- lists:seq(0, 15),
                                                C <- CSizes12, M <- lists:seq(0, 7)]
                 ++ [{Ccs, {1, Len, C}} || Ccs <- [false, true], Len <- lists:seq(0, 15),
                                           C <- CSizes22]
                 ++ [{Ccs, {S, 9}} || Ccs <- [false, true], S <- [2, 3]],
             lists:foreach(fun admission_case/1, Cases),
             io:format(user, "~nadmission: ~p cases~n", [length(Cases)])
     end}.

admission_case({Ccs, Fields} = Case) ->
    Raw = case Fields of
              {0, Len, C, M} -> place([{127, 2, 0}, {83, 4, Len}, {73, 12, C}, {49, 3, M}]);
              {1, Len, C} -> place([{127, 2, 1}, {83, 4, Len}, {69, 22, C}]);
              {S, Len} -> place([{127, 2, S}, {83, 4, Len}])
          end,
    {ok, Value} = erx_blk_sd_card:r2(?M:r2_words(Raw)),
    Said = case erx_blk_sd_card:csd(Value) of
               {ok, Csd} -> erx_blk_sd_card:admit(Ccs, Csd);
               {error, _} = E -> E
           end,
    case {admissible(Ccs, Fields), Said} of
        {{Addressing, Sectors}, {ok, #{addressing := Addressing, sectors := Sectors}}} ->
            Last = Sectors - 1,
            case Addressing of
                byte -> ?assert(Last * 512 < 1 bsl 32);
                block -> ?assert(Last < 1 bsl 32)
            end;
        {refused, {error, _}} ->
            ok;
        Other ->
            error({admission_disagrees, Case, Other})
    end.

%% The rule of "Admitting a card", with the capacity of Physical Layer
%% p.229 and p.235.
admissible(false, {0, Len, C, M}) when Len >= 9, Len =< 11 ->
    {byte, (C + 1) * (1 bsl (M + 2)) * (1 bsl Len) div 512};
admissible(true, {1, 9, C}) ->
    {block, (C + 1) * 1024};
admissible(_, _) ->
    refused.

%% A 128-bit value with each {HighBit, Width, Value} field placed.
place(Fields) ->
    lists:foldl(fun({High, Width, V}, Acc) -> Acc bor (V bsl (High - Width + 1)) end, 0,
                Fields).

%%% Parsers on known values

csd_known_values_test() ->
    {ok, V1} = erx_blk_sd_card:r2(?M:r2_words(?M:csd_v1(10, 4095, 7))),
    {ok, Csd1} = erx_blk_sd_card:csd(V1),
    ?assertEqual(#{structure => 0, read_bl_len => 10, c_size => 4095, c_size_mult => 7}, Csd1),
    ?assertEqual({ok, #{addressing => byte, sectors => 4194304}},
                 erx_blk_sd_card:admit(false, Csd1)),
    {ok, V2} = erx_blk_sd_card:r2(?M:r2_words(?M:csd_v2(8191))),
    {ok, Csd2} = erx_blk_sd_card:csd(V2),
    ?assertEqual(#{structure => 1, read_bl_len => 9, c_size => 8191}, Csd2),
    ?assertEqual({ok, #{addressing => block, sectors => 8388608}},
                 erx_blk_sd_card:admit(true, Csd2)),
    {ok, Vu} = erx_blk_sd_card:r2(?M:r2_words(place([{127, 2, 2}]))),
    ?assertEqual({error, {csd_structure, 2}}, erx_blk_sd_card:csd(Vu)).

responses_known_values_test() ->
    ?assertEqual({ok, #{errors => 0, state => 4, ready => true, locked => false,
                        app_cmd => true}}, erx_blk_sd_card:r1(16#920)),
    ?assertMatch({ok, #{errors := 16#80000000}}, erx_blk_sd_card:r1(16#80000900)),
    ?assertEqual({error, malformed}, erx_blk_sd_card:r1(1 bsl 32)),
    ?assertEqual({ok, #{ready => true, ccs => true, ocr => 16#C0FF8000}},
                 erx_blk_sd_card:r3(16#C0FF8000)),
    %% R6 bits 15, 14 and 13 are card status 23, 22 and 19.
    ?assertEqual({ok, #{rca => 16#B368, status => (1 bsl 23) bor (1 bsl 22) bor (1 bsl 19)
                            bor 16#500}},
                 erx_blk_sd_card:r6(16#B368E500)),
    ?assertEqual({ok, #{voltage => 1, pattern => 16#AA}}, erx_blk_sd_card:r7(16#1AA)),
    ?assertEqual({error, malformed}, erx_blk_sd_card:r2([0, 0, 0])).

registers_known_values_test() ->
    ?assertEqual({ok, #{spec => 2, four_bit => true, extension_registers => true}},
                 erx_blk_sd_card:scr(?M:scr(5, true))),
    ?assertEqual({ok, #{spec => 2, four_bit => false, extension_registers => false}},
                 erx_blk_sd_card:scr(?M:scr(1, false))),
    ?assertEqual({error, {scr_structure, 1}}, erx_blk_sd_card:scr(<<16#12, 0:56>>)),
    ?assertEqual({ok, #{bus_width => 2, cache => true}},
                 erx_blk_sd_card:sd_status(?M:sd_status(true))),
    ?assertEqual({error, malformed}, erx_blk_sd_card:sd_status(<<0:504>>)),
    Gi = ?M:general_information([{1, [{1, 0}]}, {2, [{2, 16#200}, {2, 16#400}]}]),
    ?assertEqual({ok, #{length => byte_size(Gi), extensions => 2, performance => {2, 16#200}}},
                 erx_blk_sd_card:general_information(Gi)),
    Pe = <<0, 0, 0, 0, 1, 0:255/unit:8, 1, 0, 0:250/unit:8>>,
    ?assertEqual({ok, #{revision => 0, cache_support => true, cache_enable => true,
                        flush => false}}, erx_blk_sd_card:performance_enhancement(Pe)),
    ?assertEqual({error, malformed},
                 erx_blk_sd_card:performance_enhancement(binary:part(Pe, 0, 261))).

%%% Parsers: properties over their fields

scr_property_test() ->
    rand:seed(exsss, {20, 26, 2}),
    lists:foreach(
      fun(_) ->
              <<Raw:64>> = Bytes = rand:bytes(8),
              Field = fun(High, Width) -> (Raw bsr (High - Width + 1)) band ((1 bsl Width) - 1) end,
              Expected = case Field(63, 4) of
                             0 -> {ok, #{spec => Field(59, 4), four_bit => Field(50, 1) =:= 1,
                                         extension_registers => Field(34, 1) =:= 1}};
                             S -> {error, {scr_structure, S}}
                         end,
              ?assertEqual(Expected, erx_blk_sd_card:scr(Bytes))
      end, lists:seq(1, 2000)).

sd_status_property_test() ->
    rand:seed(exsss, {20, 26, 3}),
    lists:foreach(
      fun(_) ->
              <<Raw:512>> = Bytes = rand:bytes(64),
              ?assertEqual({ok, #{bus_width => Raw bsr 510, cache => (Raw bsr 330) band 1 =:= 1}},
                           erx_blk_sd_card:sd_status(Bytes))
      end, lists:seq(1, 2000)).

%% A General Information of random extensions finds the first Performance
%% Enhancement function's first register set, wherever it is.
general_information_property_test() ->
    rand:seed(exsss, {20, 26, 4}),
    lists:foreach(
      fun(_) ->
              Extensions = [{case rand:uniform(4) of 1 -> 2; _ -> rand:uniform(16#FFFF) end,
                             [{rand:uniform(16) - 1, rand:uniform(16#20000) - 1}
                              || _ <- lists:seq(1, rand:uniform(3) - 1)]}
                            || _ <- lists:seq(1, rand:uniform(15))],
              Gi = ?M:general_information(Extensions),
              Expected = case [Sets || {2, Sets} <- Extensions] of
                             _ when byte_size(Gi) > 1024 -> {error, {length, byte_size(Gi)}};
                             [] -> {ok, none};
                             [[] | _] -> error;
                             [[First | _] | _] -> {ok, First}
                         end,
              Said = case erx_blk_sd_card:general_information(Gi) of
                         {ok, #{performance := P}} -> {ok, P};
                         {error, {length, _}} = E -> E;
                         {error, _} -> error
                     end,
              ?assertEqual(Expected, Said)
      end, lists:seq(1, 2000)).
