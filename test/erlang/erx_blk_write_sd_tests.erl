%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The SD half of the write path, erx_blk_write's pure builders, and erx_blk_sd_regs's
%% spacing (docs/design-storage.md, "The SD host controller"). The expected words are
%% written out from FreeBSD's sdhci.h constants (SDHCI_CMD_RESP_*, SDHCI_CMD_CRC 0x08,
%% SDHCI_CMD_INDEX 0x10, SDHCI_CMD_DATA 0x20 in the command half; SDHCI_TRNS_BLK_CNT_EN
%% 0x02, SDHCI_TRNS_ACMD12 0x04, SDHCI_TRNS_READ 0x10, SDHCI_TRNS_MULTI 0x20 in the
%% transfer mode half), so they check the generated macros against an independent
%% source rather than against themselves.

-module(erx_blk_write_sd_tests).

-include_lib("eunit/include/eunit.hrl").

-define(W, erx_blk_write).
-define(BLOCK_CARD, #{addressing => block, sectors => 64, rca => 16#1234}).
-define(BYTE_CARD, #{addressing => byte, sectors => 64, rca => 16#1234}).
%% Command half: index << 8 | flags, placed in the word's upper half.
-define(CMD(Index, Flags), (((Index bsl 8) bor Flags) bsl 16)).
-define(R48, 16#1A).        % 48 bits, CRC and index checks
-define(R48_BUSY, 16#1B).
-define(R136, 16#09).
-define(R48_NOCHECK, 16#02).
-define(DATA, 16#20).
%% The cache rule's CMD49s (Physical Layer 5.7.2.2, p.249): function 2, the register set
%% at page 1 (address 512), one byte: Flush Cache (261) to 1, Cache Enable (260) to 0.
-define(EXT(Address), ((2 bsl 27) bor ((512 + Address) bsl 9))).
-define(FLUSH_WRITE, {cmd, 49, ?EXT(261), {write, <<1, 0:4088>>}}).
-define(DISABLE_WRITE, {cmd, 49, ?EXT(260), {write, <<0, 0:4088>>}}).

command(Step) ->
    {ok, Command} = ?W:sd_command(Step),
    Command.

identification_words_test_() ->
    [?_assertEqual(#{argument => 0, word => 0, blksizecnt => none, dat => false},
                   command({cmd, 0, 0})),
     ?_assertEqual(#{argument => 16#1AA, word => ?CMD(8, ?R48), blksizecnt => none, dat => false},
                   command({cmd, 8, 16#1AA})),
     ?_assertEqual(?CMD(2, ?R136), maps:get(word, command({cmd, 2, 0}))),
     ?_assertEqual(?CMD(9, ?R136), maps:get(word, command({cmd, 9, 16#12340000}))),
     ?_assertEqual(?CMD(41, ?R48_NOCHECK), maps:get(word, command({acmd, 41, 16#40300000}))),
     ?_assertEqual(?CMD(55, ?R48), maps:get(word, command({cmd, 55, 0}))),
     %% CMD7 answers with busy, so it waits for the data lines too.
     ?_assertEqual(#{argument => 16#12340000, word => ?CMD(7, ?R48_BUSY), blksizecnt => none, dat => true},
                   command({cmd, 7, 16#12340000})),
     %% ACMD51 reads the 8-byte SCR: one block of 8, read, block count enabled.
     ?_assertEqual(#{argument => 0, word => ?CMD(51, ?R48 bor ?DATA) bor 16#12,
                     blksizecnt => (1 bsl 16) bor 8, dat => true},
                   command({acmd, 51, 0, {read, 8}})),
     ?_assertEqual((1 bsl 16) bor 64, maps:get(blksizecnt, command({acmd, 13, 0, {read, 64}}))),
     ?_assertEqual(?CMD(48, ?R48 bor ?DATA) bor 16#12, maps:get(word, command({cmd, 48, 0, {read, 512}}))),
     %% CMD49 writes one 512-byte block: no read bit.
     ?_assertEqual(?CMD(49, ?R48 bor ?DATA) bor 16#02,
                   maps:get(word, command(?FLUSH_WRITE)))].

%% The table admits only identification's commands; the reads, the writes and CMD13
%% have their own builders, and a step whose data disagrees is refused.
refused_steps_test_() ->
    [?_assertMatch({error, {sd_refused, _}}, ?W:sd_command(Step))
     || Step <- [{cmd, 17, 0}, {cmd, 18, 0}, {cmd, 24, 0}, {cmd, 25, 0}, {cmd, 13, 0},
                 {cmd, 17, 0, {read, 512}}, {cmd, 24, 0, {write, <<0:4096>>}},
                 {cmd, 12, 0}, {cmd, 42, 0}, {cmd, 6, 0}, {acmd, 23, 0}, {cmd, 64, 0},
                 {acmd, 41, 0, {read, 8}}, {acmd, 51, 0}, {acmd, 51, 0, {read, 512}},
                 {cmd, 48, 0, {read, 64}}, {cmd, 49, 0, {write, <<1>>}}, {cmd, 49, 0, {read, 512}},
                 {cmd, 0, -1}, {cmd, 0, 1 bsl 32}, {cmd, 0, foo}, {bad, 0, 0}, {cmd, foo, 0},
                 {cmd, 0}, nonsense]].

%% CMD16 and CMD49 take only the arguments that keep the card's cache off and its block
%% length 512.
argument_test_() ->
    [?_assertMatch({ok, _}, ?W:sd_command({cmd, 16, 512})),
     ?_assertMatch({ok, _}, ?W:sd_command(?FLUSH_WRITE)),
     ?_assertMatch({ok, _}, ?W:sd_command(?DISABLE_WRITE))
     | [?_assertEqual({error, {sd_refused, {argument, cmd, Index}}}, ?W:sd_command(Step))
        || {Index, Step} <- [{16, {cmd, 16, 0}}, {16, {cmd, 16, 1024}},
                             %% Cache Enable to 1, Flush Cache to 0, another byte.
                             {49, {cmd, 49, ?EXT(260), {write, <<1, 0:4088>>}}},
                             {49, {cmd, 49, ?EXT(261), {write, <<0, 0:4088>>}}},
                             {49, {cmd, 49, ?EXT(262), {write, <<1, 0:4088>>}}},
                             %% Two bytes, the mask-write bit, I/O space, a dirty block.
                             {49, {cmd, 49, ?EXT(261) bor 1, {write, <<1, 0:4088>>}}},
                             {49, {cmd, 49, ?EXT(261) bor (1 bsl 26), {write, <<1, 0:4088>>}}},
                             {49, {cmd, 49, ?EXT(261) bor (1 bsl 31), {write, <<1, 0:4088>>}}},
                             {49, {cmd, 49, ?EXT(261), {write, <<1, 0:4080, 1>>}}}]]].

read_test_() ->
    {ok, One} = ?W:sd_read_command(5, 1, ?BLOCK_CARD),
    {ok, Three} = ?W:sd_read_command(5, 3, ?BLOCK_CARD),
    {ok, Bytes} = ?W:sd_read_command(5, 1, ?BYTE_CARD),
    [?_assertEqual(#{argument => 5, word => ?CMD(17, ?R48 bor ?DATA) bor 16#12,
                     blksizecnt => (1 bsl 16) bor 512, dat => true}, One),
     %% More than one block: multiple and Auto CMD12 as well.
     ?_assertEqual(#{argument => 5, word => ?CMD(18, ?R48 bor ?DATA) bor 16#36,
                     blksizecnt => (3 bsl 16) bor 512, dat => true}, Three),
     ?_assertEqual(5 * 512, maps:get(argument, Bytes)),
     ?_assertEqual({error, bad_count}, ?W:sd_read_command(0, 0, ?BLOCK_CARD)),
     ?_assertEqual({error, bad_count}, ?W:sd_read_command(0, 9, ?BLOCK_CARD)),
     ?_assertEqual({error, out_of_range}, ?W:sd_read_command(62, 3, ?BLOCK_CARD)),
     ?_assertEqual({error, out_of_range}, ?W:sd_read_command(-1, 1, ?BLOCK_CARD)),
     ?_assertMatch({ok, _}, ?W:sd_read_command(61, 3, ?BLOCK_CARD))].

write_test_() ->
    {ok, One} = ?W:sd_write_command(5, <<0:4096>>, ?BYTE_CARD),
    {ok, Two} = ?W:sd_write_command(5, <<0:8192>>, ?BLOCK_CARD),
    [?_assertEqual(#{argument => 5 * 512, word => ?CMD(24, ?R48 bor ?DATA) bor 16#02,
                     blksizecnt => (1 bsl 16) bor 512, dat => true}, One),
     ?_assertEqual(#{argument => 5, word => ?CMD(25, ?R48 bor ?DATA) bor 16#26,
                     blksizecnt => (2 bsl 16) bor 512, dat => true}, Two),
     ?_assertEqual({error, bad_count}, ?W:sd_write_command(0, <<>>, ?BLOCK_CARD)),
     ?_assertEqual({error, bad_count}, ?W:sd_write_command(0, <<0:4104>>, ?BLOCK_CARD)),
     ?_assertEqual({error, bad_count}, ?W:sd_write_command(0, not_binary, ?BLOCK_CARD)),
     ?_assertEqual({error, out_of_range}, ?W:sd_write_command(64, <<0:4096>>, ?BLOCK_CARD))].

status_test() ->
    ?assertEqual({ok, #{argument => 16#12340000, word => ?CMD(13, ?R48), blksizecnt => none, dat => false}},
                 ?W:sd_status_command(?BLOCK_CARD)).

%% No word the builders make enables DMA, bit 0 of the transfer mode.
no_dma_test() ->
    Words = [maps:get(word, C) || {ok, C} <- [?W:sd_command({acmd, 51, 0, {read, 8}}),
                                              ?W:sd_read_command(0, 4, ?BLOCK_CARD),
                                              ?W:sd_write_command(0, <<0:8192>>, ?BLOCK_CARD),
                                              ?W:sd_status_command(?BLOCK_CARD)]],
    ?assertEqual(4, length(Words)),
    ?assertEqual([], [W || W <- Words, W band 1 =/= 0]).

spacing_test_() ->
    [?_assertEqual(0, erx_blk_sd_regs:remaining_us(undefined, 100)),
     ?_assertEqual(6, erx_blk_sd_regs:remaining_us(100, 100)),
     ?_assertEqual(2, erx_blk_sd_regs:remaining_us(100, 104)),
     ?_assertEqual(0, erx_blk_sd_regs:remaining_us(100, 106)),
     ?_assertEqual(0, erx_blk_sd_regs:remaining_us(100, 1000))].
