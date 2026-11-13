%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the Raspberry Pi 4's PHY machine, erx_phy_c22, and of the MDIO
%% command word, erx_mdio. The machine runs against erx_phy_bcm54213_model, a
%% reference PHY written from the register facts alone, and is checked
%% exhaustively over the register bits it decides on: every value of both ID
%% registers, every reset length up to past the bound, every data value of both
%% shadow registers, every word of each of the status register's two reads (the
%% other read showing the link up) from a link down and a link up, every
%% auxiliary status word, and every set of modes a
%% link partner can advertise, connected from the start, late, pulled, and
%% pulled and reconnected between two polls.

-module(erx_phy_c22_tests).
-include_lib("eunit/include/eunit.hrl").

-define(BMCR, 16#00).
-define(BMSR, 16#01).
-define(AUXCTL, 16#18).
-define(AUXSTS, 16#19).
-define(SHADOW_1C, 16#1c).
-define(LINK, 16#0004).
-define(ACOMP, 16#0020).
-define(POLL, 1000).
-define(MODES, ['1000fd', '1000hd', '100fd', '100hd', '10fd', '10hd']).

%% --- Driving the machine against the model -------------------------------------

%% Runs the machine on Model through the polls of Timeline, one function of the
%% model per poll after the first, applied before that poll's reads. Returns the
%% model, the machine and the reports, each tagged with the poll it came in
%% (0 for the setup and the first poll).
run(Model, Timeline) ->
    {Phy, Request} = erx_phy_c22:start(),
    loop(Model, Phy, Request, Timeline, 0, [], 10000).

loop(_Model, _Phy, _Request, _Timeline, _Poll, _Acc, 0) ->
    error(machine_does_not_settle);
loop(Model, Phy, stop, _Timeline, _Poll, Acc, _Budget) ->
    {Model, Phy, lists:reverse(Acc)};
loop(Model, Phy, {wait, ?POLL}, [], _Poll, Acc, _Budget) ->
    {Model, Phy, lists:reverse(Acc)};
loop(Model, Phy, {wait, ?POLL} = Request, [Event | Timeline], Poll, Acc, Budget) ->
    perform(Event(Model), Phy, Request, Timeline, Poll + 1, Acc, Budget);
loop(Model, Phy, Request, Timeline, Poll, Acc, Budget) ->
    perform(Model, Phy, Request, Timeline, Poll, Acc, Budget).

perform(Model, Phy, Request, Timeline, Poll, Acc, Budget) ->
    {Model1, Input} = erx_phy_bcm54213_model:exec(Model, Request),
    {Phy1, Request1, Reports} = erx_phy_c22:step(Phy, Input),
    Tagged = lists:reverse([{Poll, Report} || Report <- Reports]),
    loop(Model1, Phy1, Request1, Timeline, Poll, Tagged ++ Acc, Budget - 1).

reports(Options, Timeline) ->
    {_Model, _Phy, Reports} = run(erx_phy_bcm54213_model:new(Options), Timeline),
    Reports.

up(Model) -> erx_phy_bcm54213_model:cable(Model, up).
down(Model) -> erx_phy_bcm54213_model:cable(Model, down).
bounce(Model) -> erx_phy_bcm54213_model:bounce(Model).
same(Model) -> Model.

%% The speed a full-duplex-only advertisement shares with Partner, or down.
expected_link(Partner) ->
    case [S || {Mode, S} <- [{'1000fd', 1000}, {'100fd', 100}, {'10fd', 10}], lists:member(Mode, Partner)] of
        [Speed | _] -> {up, Speed};
        [] -> down
    end.

partners() ->
    [[M || {M, Bit} <- lists:zip(?MODES, lists:seq(0, 5)), Set band (1 bsl Bit) =/= 0]
     || Set <- lists:seq(0, 63)].

%% Feeds the machine scripted inputs from start/0 on; its state and the reports.
script(Inputs) ->
    {Phy, _} = erx_phy_c22:start(),
    lists:foldl(fun(Input, {P, _}) ->
                        {P1, _Req, Reports} = erx_phy_c22:step(P, Input),
                        {P1, Reports}
                end, {Phy, []}, Inputs).

%% The inputs that take a fresh machine to its first read of the status register.
to_first_poll() ->
    [ok,                 % reset written
     {ok, 16#1140},      % control read: reset done
     {ok, 16#600d},      % ID 1
     {ok, 16#84a2},      % ID 2: the BCM54213PE
     ok,                 % shadow 7 selected
     {ok, 16#0007},      % shadow 7 read
     ok,                 % shadow 7 written
     ok,                 % shadow 0x1C clock control selected
     {ok, 16#0c00},      % shadow 0x1C read
     ok,                 % shadow 0x1C written
     ok,                 % advertisement written
     ok,                 % 1000BASE-T control written
     ok].                % autonegotiation started

%% A machine waiting for the first of a poll's two status reads, link down or
%% up at 100 Mb/s.
latched_state(down) ->
    element(1, script(to_first_poll()));
latched_state(up) ->
    Inputs = to_first_poll() ++ [{ok, ?LINK bor ?ACOMP}, {ok, ?LINK bor ?ACOMP}, {ok, 16#0504}, ok],
    {Phy, _} = script(Inputs),
    {up, 100} = erx_phy_c22:link(Phy),
    Phy.

%% --- The whole machine ----------------------------------------------------------

a_connected_partner_is_up_at_the_first_poll_for_every_advertisement_test() ->
    [?assertEqual({Partner, link_reports(expected_link(Partner))},
                  {Partner, reports(#{partner => Partner}, [])})
     || Partner <- partners()].

link_reports(down) -> [];
link_reports({up, Speed}) -> [{0, {link, up, Speed}}].

a_late_cable_pulled_and_bounced_cable_reports_each_change_test() ->
    [begin
         Timeline = [fun same/1, fun up/1, fun same/1, fun down/1, fun up/1, fun bounce/1, fun same/1],
         Got = reports(#{partner => Partner, cable => down}, Timeline),
         Want = case expected_link(Partner) of
                    down -> [];
                    {up, S} -> [{2, {link, up, S}}, {4, {link, down}}, {5, {link, up, S}},
                                {6, {link, down}}, {6, {link, up, S}}]
                end,
         ?assertEqual({Partner, Want}, {Partner, Got})
     end || Partner <- partners()].

the_machine_writes_only_its_setup_and_advertises_full_duplex_test() ->
    {Model, _Phy, _} = run(erx_phy_bcm54213_model:new(#{}), [fun same/1]),
    ?assertEqual([{?BMCR, 16#8000}, {?AUXCTL, 16#7007}, {?AUXCTL, 16#8207},
                  {?SHADOW_1C, 16#0c00}, {?SHADOW_1C, 16#8c00},
                  {16#04, 16#0141}, {16#09, 16#0200}, {?BMCR, 16#1200}],
                 erx_phy_bcm54213_model:writes(Model)).

every_reset_length_up_to_the_bound_completes_and_none_past_it_test() ->
    Bound = erx_phy_c22:reset_polls(),
    [begin
         Got = reports(#{reset_reads => Held, partner => ['100fd']}, []),
         Want = case Held < Bound of
                    true -> [{0, {link, up, 100}}];
                    false -> [{0, {failed, reset_timeout}}]
                end,
         ?assertEqual({Held, Want}, {Held, Got})
     end || Held <- lists:seq(0, Bound + 1)].

every_shadow_data_value_keeps_its_other_bits_test() ->
    [begin
         Misc = Data bsl 3,
         Clock = Data band 16#3ff,
         {Model, _, _} = run(erx_phy_bcm54213_model:new(#{misc => Misc, clock => Clock}), []),
         ?assertEqual({Data, Misc bor 16#0200, Clock band bnot 16#0200},
                      {Data, erx_phy_bcm54213_model:misc(Model), erx_phy_bcm54213_model:clock(Model)})
     end || Data <- lists:seq(0, 16#fff)].

%% --- Identification -------------------------------------------------------------

the_bcm54213pe_id_decodes_to_its_oui_and_model_test() ->
    ?assertEqual(#{oui => 16#18c086, model => 16#0a, rev => 2}, erx_phy_c22:identify(16#600d, 16#84a2)).

every_id_1_but_the_broadcom_one_is_refused_test() ->
    [?assertEqual({Id1, Id1 =:= 16#600d}, {Id1, accepted(Id1, 16#84a2)}) || Id1 <- lists:seq(0, 16#ffff)].

every_id_2_of_another_model_is_refused_and_any_revision_accepted_test() ->
    [?assertEqual({Id2, Id2 band 16#fff0 =:= 16#84a0}, {Id2, accepted(16#600d, Id2)})
     || Id2 <- lists:seq(0, 16#ffff)].

%% Whether the machine goes on to the clock delays after reading Id1 and Id2.
accepted(Id1, Id2) ->
    {Phy, []} = script([ok, {ok, 0}, {ok, Id1}]),
    case erx_phy_c22:step(Phy, {ok, Id2}) of
        {_, {write, ?AUXCTL, 16#7007}, []} -> true;
        {_, stop, [{failed, {unknown_phy, #{}}}]} -> false
    end.

%% --- The link bits --------------------------------------------------------------

every_latched_status_word_decides_whether_the_link_dropped_test() ->
    [begin
         Phy = latched_state_after(Link, Latched),
         {_, {read, ?AUXSTS}, Reports} = erx_phy_c22:step(Phy, {ok, ?LINK bor ?ACOMP}),
         Dropped = Latched band ?LINK =:= 0,
         ?assertEqual({Link, Latched, Link =:= up andalso Dropped},
                      {Link, Latched, Reports =:= [{link, down}]})
     end || Link <- [down, up], Latched <- lists:seq(0, 16#ffff)].

every_current_status_word_decides_whether_the_link_is_up_test() ->
    [begin
         Phy = latched_state_after(Link, ?LINK bor ?ACOMP),
         {_, Request, Reports} = erx_phy_c22:step(Phy, {ok, Now}),
         Up = Now band ?LINK =/= 0 andalso Now band ?ACOMP =/= 0,
         WantReports = case {Link, Up} of {up, false} -> [{link, down}]; _ -> [] end,
         WantRequest = case Up of true -> {read, ?AUXSTS}; false -> {wait, ?POLL} end,
         ?assertEqual({Link, Now, WantRequest, WantReports}, {Link, Now, Request, Reports})
     end || Link <- [down, up], Now <- lists:seq(0, 16#ffff)].

latched_state_after(Link, Latched) ->
    {Phy, {read, ?BMSR}, []} = erx_phy_c22:step(latched_state(Link), {ok, Latched}),
    Phy.

every_auxiliary_status_word_resolves_to_its_full_duplex_speed_test() ->
    %% brgphyreg.h:223-229's codes, taken only with the link bit (bit 2) set.
    Speeds = #{16#0704 => 1000, 16#0504 => 100, 16#0204 => 10},
    [?assertEqual({Aux, maps:get(Aux band 16#0704, Speeds, none)}, {Aux, erx_phy_c22:resolution(Aux)})
     || Aux <- lists:seq(0, 16#ffff)].

a_half_duplex_resolution_takes_an_up_link_down_test() ->
    Phy = latched_state_after(up, ?LINK bor ?ACOMP),
    {Phy1, {read, ?AUXSTS}, []} = erx_phy_c22:step(Phy, {ok, ?LINK bor ?ACOMP}),
    ?assertMatch({_, {wait, ?POLL}, [{link, down}]}, erx_phy_c22:step(Phy1, {ok, 16#0304})).

an_auxiliary_status_without_its_link_bit_is_no_link_test() ->
    Phy = latched_state_after(down, ?LINK bor ?ACOMP),
    {Phy1, {read, ?AUXSTS}, []} = erx_phy_c22:step(Phy, {ok, ?LINK bor ?ACOMP}),
    ?assertEqual({{wait, ?POLL}, [], down}, without_state(erx_phy_c22:step(Phy1, {ok, 16#0700}))).

without_state({Phy, Request, Reports}) -> {Request, Reports, erx_phy_c22:link(Phy)}.

%% --- Failures -------------------------------------------------------------------

an_mdio_error_or_a_mismatched_result_ends_the_machine_for_good_test() ->
    {Phy, _} = erx_phy_c22:start(),
    {Failed, stop, [{failed, {mdio, timeout}}]} = erx_phy_c22:step(Phy, {error, timeout}),
    ?assertEqual({Failed, stop, []}, erx_phy_c22:step(Failed, ok)),
    ?assertMatch({_, stop, [{failed, {unexpected, reset, {ok, 1}}}]}, erx_phy_c22:step(Phy, {ok, 1})),
    ?assertMatch({_, stop, [{failed, {unexpected, _, ok}}]}, erx_phy_c22:step(latched_state(down), ok)).

%% --- The MDIO command word ------------------------------------------------------

commands_place_every_field_test() ->
    ?assertEqual(16#083f0000, erx_mdio:command({read, 1, 16#1f})),
    ?assertEqual(16#043c1234, erx_mdio:command({write, 1, 16#1c, 16#1234})),
    ?assertEqual(16#283f0000, erx_mdio:start(16#083f0000)),
    [?assertMatch(#{phy := Phy, reg := Reg, read := true, write := false, busy := false},
                  erx_mdio:decode(erx_mdio:command({read, Phy, Reg})))
     || Phy <- lists:seq(0, 31), Reg <- lists:seq(0, 31)].

polls_wait_while_busy_up_to_the_bound_test() ->
    Read = {read, 1, 2},
    Max = erx_mdio:max_polls(),
    ?assertEqual(1000, Max),
    ?assertEqual({wait, 2}, erx_mdio:poll(Read, 16#28220000, 1)),
    ?assertEqual({wait, Max}, erx_mdio:poll(Read, 16#28220000, Max - 1)),
    ?assertEqual({error, timeout}, erx_mdio:poll(Read, 16#28220000, Max)),
    ?assertEqual({ok, 16#600d}, erx_mdio:poll(Read, 16#0822600d, 2)),
    ?assertEqual({error, read_failed}, erx_mdio:poll(Read, 16#1822ffff, 2)),
    ?assertEqual(ok, erx_mdio:poll({write, 1, 4, 1}, 16#14240001, 2)).
