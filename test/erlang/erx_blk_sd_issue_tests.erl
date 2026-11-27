%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The SD write path's effects, erx_blk_write:sd_issue/2 and sd_feed/3, against the
%% recording stand-in for the device NIF (test/erlang/stand_in/erx_device.erl)
%% (docs/design-storage.md, "The SD host controller", Issuing a command): the order of the
%% writes, the inhibit bound, the 6 us spacing of every write but `data`'s, and that a
%% write's blocks come from the bytes its plan checked.

-module(erx_blk_sd_issue_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(W, erx_blk_write).
-define(CARD, #{addressing => block, sectors => 64, rca => 16#1234}).
%% present: command inhibit is bit 0, data inhibit bit 1 (SDHCI_CMD_INHIBIT,
%% SDHCI_DAT_INHIBIT, sdhci.h:148-149).
-define(CMD_INHIBIT, 1).
-define(DAT_INHIBIT, 2).
%% The transfer mode of a multi-block write: block count enabled, Auto CMD12 and multiple
%% blocks (sdhci.c:1730-1743).
-define(MULTI_WRITE_MODE, 16#26).

issue(Plan, Reads) ->
    erx_device:script(Reads),
    Result = ?W:sd_issue(erx_blk_sd_regs:new(dev), Plan),
    {Result, erx_device:calls()}.

ops(Calls) -> [Op || {_Us, Op} <- Calls].

%% A data command: present until clear, then `interrupt` cleared, blksizecnt, arg and the
%% command, built as the
%% plan's command says.
read_order_test() ->
    {ok, Plan} = ?W:sd_read_plan(5, 3, ?CARD),
    {ok, #{argument := Arg, word := Word, blksizecnt := Size}} = ?W:sd_read_command(5, 3, ?CARD),
    {{ok, _Regs}, Calls} = issue(Plan, #{present => [?DAT_INHIBIT, ?CMD_INHIBIT, 0]}),
    ?assertEqual([{read, present}, {read, present}, {read, present},
                  {write, interrupt, erx_blk_sd_host:ack_mask()}, {write, blksizecnt, Size}, {write, arg, Arg}, {command, Word}], ops(Calls)).

%% A command without data writes no blksizecnt, and waits for command inhibit only.
status_order_test() ->
    {ok, Plan} = ?W:sd_status_plan(?CARD),
    {{ok, _Regs}, Calls} = issue(Plan, #{present => [?DAT_INHIBIT]}),
    ?assertMatch([{read, present}, {write, interrupt, _}, {write, arg, 16#12340000}, {command, _}], ops(Calls)).

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
    ?assertEqual(8, length(Times)),
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

%% The largest write the SD transport takes, blk_sd_max_sectors (docs/design-storage.md,
%% "Data model"), is one command sequence: one CMD25 with that block count and Auto
%% CMD12, each block of the caller's data fed through `data` on its
%% buffer-ready event, and CMD13 after transfer complete. One sector more is refused by the
%% plan builder, which is pure, so before the device is touched.
largest_write_test() ->
    Data = << <<(I rem 251):8>> || I <- lists:seq(0, ?ERX_BLK_SD_MAX_SECTORS * 512 - 1) >>,
    {ok, Plan} = ?W:sd_write_plan(0, Data, ?CARD),
    {{ok, Regs}, Calls} = issue(Plan, #{}),
    [Word] = [W || {command, W} <- ops(Calls)],
    ?assertEqual({25, ?MULTI_WRITE_MODE}, {(Word bsr 24) band 16#3f, Word band 16#ffff}),
    ?assertEqual([(?ERX_BLK_SD_MAX_SECTORS bsl 16) bor 512], [S || {write, blksizecnt, S} <- ops(Calls)]),
    ?assertEqual(Data, fed(Plan, Regs)),
    ?assertEqual({error, bad_count}, ?W:sd_write_plan(0, <<Data/binary, 0:4096>>, ?CARD)).

%% The transfer core run over a write plan as the device process runs it, each block it asks
%% for fed from the plan to the stand-in, until it issues CMD13; the words fed, as bytes.
fed(Plan, Regs) ->
    #{data := {write, 512, Count}} = ?W:sd_shape(Plan),
    T0 = erx_blk_sd_host:new(#{op => write, sector => 0, count => Count, capacity => maps:get(sectors, ?CARD),
                               accepted => 0}),
    {T1, [{issue, transfer}]} = erx_blk_sd_host:step(T0, {start, 0}),
    {T2, []} = erx_blk_sd_host:step(T1, {command_complete, 16#900}),
    erx_device:script(#{}),
    T3 = lists:foldl(fun(Index, T) ->
                             {Next, [{write_block, Index}]} = erx_blk_sd_host:step(T, buffer_write_ready),
                             ok = ?W:sd_feed(Regs, Plan, Index),
                             Next
                     end, T2, lists:seq(0, Count - 1)),
    {_Done, [{issue, status}]} = erx_blk_sd_host:step(T3, {transfer_complete, 16#900}),
    << <<W:32/little>> || {write, data, W} <- ops(erx_device:calls()) >>.
