%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The SD write path's effects, erx_blk_write:sd_issue/2 and sd_feed/3, against the
%% recording stand-in for the device NIF (test/erlang/stand_in/erx_device.erl)
%% (docs/design-storage.md, "The SD host controller", Issuing a command): the order of the
%% writes, the inhibit bound, the 6 us spacing of every write but `data`'s, and that a
%% write's blocks come from the bytes its plan checked.

-module(erx_blk_sd_issue_tests).

-include_lib("eunit/include/eunit.hrl").

-define(W, erx_blk_write).
-define(CARD, #{addressing => block, sectors => 64, rca => 16#1234}).
%% present: command inhibit is bit 0, data inhibit bit 1 (SDHCI_CMD_INHIBIT,
%% SDHCI_DAT_INHIBIT, sdhci.h:148-149).
-define(CMD_INHIBIT, 1).
-define(DAT_INHIBIT, 2).

issue(Plan, Reads) ->
    erx_device:script(Reads),
    Result = ?W:sd_issue(erx_blk_sd_regs:new(dev), Plan),
    {Result, erx_device:calls()}.

ops(Calls) -> [Op || {_Us, Op} <- Calls].

%% A data command: present until clear, then blksizecnt, arg and the command, built as the
%% plan's command says.
read_order_test() ->
    {ok, Plan} = ?W:sd_read_plan(5, 3, ?CARD),
    {ok, #{argument := Arg, word := Word, blksizecnt := Size}} = ?W:sd_read_command(5, 3, ?CARD),
    {{ok, _Regs}, Calls} = issue(Plan, #{present => [?DAT_INHIBIT, ?CMD_INHIBIT, 0]}),
    ?assertEqual([{read, present}, {read, present}, {read, present},
                  {write, blksizecnt, Size}, {write, arg, Arg}, {command, Word}], ops(Calls)).

%% A command without data writes no blksizecnt, and waits for command inhibit only.
status_order_test() ->
    {ok, Plan} = ?W:sd_status_plan(?CARD),
    {{ok, _Regs}, Calls} = issue(Plan, #{present => [?DAT_INHIBIT]}),
    ?assertMatch([{read, present}, {write, arg, 16#12340000}, {command, _}], ops(Calls)).

%% An inhibit that does not clear refuses after 10 ms and writes nothing.
inhibit_bound_test() ->
    {ok, Plan} = ?W:sd_write_plan(0, <<0:4096>>, ?CARD),
    Before = erlang:monotonic_time(microsecond),
    {Result, Calls} = issue(Plan, #{present => [?DAT_INHIBIT]}),
    Elapsed = erlang:monotonic_time(microsecond) - Before,
    ?assertEqual({error, {device, inhibit}}, Result),
    ?assertEqual([], [Op || Op <- ops(Calls), Op =/= {read, present}]),
    ?assert(Elapsed >= 10000),
    ?assert(length(Calls) > 1).

%% Every write but data's is at least 6 us after the one before it, across issues too, since
%% the register handle carries the last write's time.
spacing_test() ->
    {ok, Plan} = ?W:sd_read_plan(0, 2, ?CARD),
    erx_device:script(#{}),
    {ok, Regs} = ?W:sd_issue(erx_blk_sd_regs:new(dev), Plan),
    {ok, _} = ?W:sd_issue(Regs, Plan),
    Times = [Us || {Us, Op} <- erx_device:calls(), element(1, Op) =/= read],
    ?assertEqual(6, length(Times)),
    ?assertEqual([], [{A, B} || {A, B} <- lists:zip(lists:droplast(Times), tl(Times)), B - A < 6]).

%% A write's block Index is that block of the plan's data, little-endian words; a block the
%% plan does not hold, and a plan with no data to write, are refused before any write.
feed_test() ->
    Data = << <<I:8>> || I <- lists:seq(0, 1023) >>,
    {ok, Plan} = ?W:sd_write_plan(0, Data, ?CARD),
    erx_device:script(#{}),
    ok = ?W:sd_feed(erx_blk_sd_regs:new(dev), Plan, 1),
    Words = [W || {write, data, W} <- ops(erx_device:calls())],
    ?assertEqual(128, length(Words)),
    ?assertEqual(binary:part(Data, 512, 512), << <<W:32/little>> || W <- Words >>),
    erx_device:script(#{}),
    {ok, Read} = ?W:sd_read_plan(0, 2, ?CARD),
    ?assertEqual({error, {feed, 2}}, ?W:sd_feed(erx_blk_sd_regs:new(dev), Plan, 2)),
    ?assertEqual({error, {feed, -1}}, ?W:sd_feed(erx_blk_sd_regs:new(dev), Plan, -1)),
    ?assertEqual({error, {feed, 0}}, ?W:sd_feed(erx_blk_sd_regs:new(dev), Read, 0)),
    ?assertEqual([], erx_device:calls()).

%% CMD49's block is the step's own.
step_feed_test() ->
    Block = <<1, 0:4088>>,
    {ok, Plan} = ?W:sd_plan({cmd, 49, (2 bsl 27) bor ((512 + 261) bsl 9), {write, Block}}),
    ?assertEqual(#{response => r1, data => {write, 512, 1}}, ?W:sd_shape(Plan)),
    erx_device:script(#{}),
    ok = ?W:sd_feed(erx_blk_sd_regs:new(dev), Plan, 0),
    ?assertEqual(Block, << <<W:32/little>> || {write, data, W} <- ops(erx_device:calls()) >>).
