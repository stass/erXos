%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The SD device process's start sequence (docs/design-storage.md, "The SD host
%% controller", The start sequence) over the recording stand-in for the device NIF, whose
%% reads answer as QEMU's raspi4b model reads (docs/research-sdhci-qemu-model.md, findings
%% 2 and 3): the controller's steps all pass and the start issues the card's first command.
%% No interrupt ever arrives, so identification then fails at its step deadline; the log
%% line that follows is the device NIF's and raises on the host, which the test catches.

-module(erx_blk_sd_start_tests).

-include_lib("eunit/include/eunit.hrl").

%% Present state: card inserted and stable, DAT[3:0] and CMD high, no inhibit.
-define(PRESENT, 16#01ff0000).
-define(CAPABILITIES, 16#052134b4).
-define(VERSION, 16#24020000).

start_reaches_the_first_command_test() ->
    erx_device:script(#{present => [?PRESENT], capabilities => [?CAPABILITIES], slotisr_ver => [?VERSION],
                        {control1, clock_int_stable} => [1], {control0, power_on} => [1]}),
    _ = try erx_blk_sd:init(#{}) catch error:undef -> log_raised end,
    Calls = [Op || {_Us, Op} <- erx_device:calls()],
    ?assertMatch([_ | _], [Word || {command, Word} <- Calls]),
    %% The interrupt enables come before the first command.
    {Before, _} = lists:splitwith(fun(Op) -> element(1, Op) =/= command end, Calls),
    ?assert(lists:any(fun(Op) -> Op =:= {write, irpt_en, erx_blk_sd_host:enable_mask()} end, Before)).
