%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The SD device process's identification over the recording stand-in for the device NIF
%% (test/erlang/stand_in/erx_device.erl), with the interrupt line's deliveries sent to the
%% test process, which runs init/1 itself: each delivery reads the next scripted
%% `interrupt` word. The card answers as a high-capacity card answers (CMD8 echoed, ready
%% on the first ACMD41 of the loop), and the words come as a controller may raise them
%% (docs/design-storage.md, "The SD host controller"): a command's command complete and
%% its transfer complete in either order, one word or two, as FreeBSD's sdhci_finish_data
%% takes them (sdhci.c:2027-2033, "the case when data interrupt happened first"), and a
%% data end on a command with neither data nor busy, which FreeBSD ignores
%% (sdhci.c:2242-2249). Identification must pass CMD7, the first command with busy, and
%% issue CMD55 and ACMD51 after it. The script ends there, so ACMD51 fails at its
%% deadline; the log line that follows is the device NIF's and raises on the host, which
%% the test catches.

-module(erx_blk_sd_events_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PRESENT, 16#01ff0000).
-define(CAPABILITIES, 16#052134b4).
-define(VERSION, 16#24020000).
%% The `interrupt` word's command complete and transfer complete bits (Host Controller
%% 2.2.18, p.76).
-define(CC, 16#1).
-define(TC, 16#2).
-define(RCA, 16#1234).

%% The commands up to CMD7, and CMD55 and ACMD51 after it.
-define(THROUGH_SELECT, [0, 8, 55, 41, 0, 8, 55, 41, 2, 3, 9, 7, 55, 51]).

busy_end_before_command_complete_test_() ->
    {timeout, 10, fun() -> ?assertEqual(?THROUGH_SELECT, through(#{select => [?TC, ?CC]})) end}.

busy_end_with_command_complete_test_() ->
    {timeout, 10, fun() -> ?assertEqual(?THROUGH_SELECT, through(#{select => [?CC bor ?TC]})) end}.

data_end_on_a_command_without_data_test_() ->
    {timeout, 10, fun() -> ?assertEqual(?THROUGH_SELECT, through(#{send_csd => [?CC bor ?TC]})) end}.

%% The command indices init/1 issued, with Words's interrupt words for CMD9 and CMD7.
through(Words) ->
    Cid = erx_blk_sd_card_model:r2_words(16#1D4144534443415244101234567800C7),
    Csd = erx_blk_sd_card_model:r2_words(erx_blk_sd_card_model:csd_v2(7579)),
    Interrupts = lists:duplicate(10, [?CC]) ++ [maps:get(send_csd, Words, [?CC]),
                                                maps:get(select, Words, [?CC, ?TC]), [?CC]],
    Flat = lists:append(Interrupts),
    erx_device:script(#{present => [?PRESENT], capabilities => [?CAPABILITIES], slotisr_ver => [?VERSION],
                        {control1, clock_int_stable} => [1], {control0, power_on} => [1],
                        interrupt => Flat ++ [0],
                        {resp, 0} => [16#1AA, 16#120, 16#00FF8000, 16#1AA, 16#120, 16#C0FF8000,
                                      hd(Cid), (?RCA bsl 16) bor 16#0500, hd(Csd), 16#0700, 16#0920],
                        {resp, 1} => [lists:nth(2, Cid), lists:nth(2, Csd)],
                        {resp, 2} => [lists:nth(3, Cid), lists:nth(3, Csd)],
                        {resp, 3} => [lists:nth(4, Cid), lists:nth(4, Csd)]}),
    lists:foreach(fun(_) -> self() ! {erx_irq, dev, 0} end, Flat),
    _ = try erx_blk_sd:init(#{}) catch error:undef -> log_raised end,
    flush(),
    [(Word bsr 24) band 63 || {_Us, {command, Word}} <- erx_device:calls()].

flush() ->
    receive {erx_irq, dev, 0} -> flush() after 0 -> ok end.
