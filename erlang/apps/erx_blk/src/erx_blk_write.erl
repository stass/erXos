%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The block driver's one write path (docs/design-storage.md, "The block driver", and
%% invariant U4), held by construction: this module is the only one that posts a request
%% to the device, and it builds every request it posts, the header's request type
%% included, so it holds the virtio transport's request builder. The virtio device
%% process, erx_blk_virtio, calls it for every request it hands the device. read/6 posts a
%% read, whose type is ERX_VIRTIO_BLK_T_IN; flush/3 posts a flush, whose type is
%% ERX_VIRTIO_BLK_T_FLUSH and which moves no sectors; write/6 posts a write, whose type is
%% ERX_VIRTIO_BLK_T_OUT, and is the only function that builds one. Nothing a caller passes
%% chooses the type, so no other module can make the device write.
%% tools/lib/erx/chokepoint_rules/device.rb holds the rule as a build check: no module but this one
%% calls erx_device:post/4.
%%
%% read_segments/3, write_segments/3 and flush_segments/0 are pure, so the requests are
%% tested and fuzzed on the host (test/erlang/erx_blk_request_tests.erl and
%% erx_blk_request_fuzz.erl). write/6 does not apply U4's trial rule, which refuses every
%% write but the boot-selection record's while a trial boots: TODO.md holds that gap.
%%
%% The SD host controller's half is the same rule for the other act: writing the command
%% register, which issues one command to the card. Only this module calls
%% erx_device:command/2 (tools/lib/erx/chokepoint_rules/device.rb), and it builds every command word
%% itself from the generated field macros of hw/svd/sdhci/sdhci.svd. A device process names
%% a card-identification step of erx_blk_sd_card, which the SD table admits only if it lists
%% the command, or asks for a read, a write or a status; only sd_read_command/3,
%% sd_write_command/3 and sd_status_command/1 build CMD17 and CMD18, CMD24 and CMD25, and
%% CMD13 as SEND_STATUS (ACMD13 is the table's), so one table and three builders decide every
%% command that reaches the card. Each builder makes a plan (sd_plan/1, sd_read_plan/3,
%% sd_write_plan/3, sd_status_plan/1), the one value sd_issue/2 issues and sd_feed/3 feeds a
%% write's blocks from, so the bytes that reach `data` and the block count are the ones the
%% builder checked. The builders are pure and tested and fuzzed on the host
%% (test/erlang/erx_blk_write_sd_tests.erl and erx_blk_sd_fuzz.erl); sd_issue/2 and sd_feed/3
%% are tested against a recording stand-in for the device NIF
%% (test/erlang/stand_in/erx_device.erl).

-module(erx_blk_write).

-export([read_segments/3, write_segments/3, flush_segments/0, read/6, write/6, flush/3]).
-export([sd_command/1, sd_read_command/3, sd_write_command/3, sd_status_command/1]).
-export([sd_plan/1, sd_read_plan/3, sd_write_plan/3, sd_status_plan/1, sd_shape/1]).
-export([sd_issue/2, sd_feed/3]).

-export_type([sd_command/0, sd_plan/0]).

-include("generated/erx_abi.hrl").
-include("generated/erx_hw_sdhci.hrl").

%% The status byte the device writes last, after the sectors.
-define(STATUS_BYTES, 1).
%% An SD data block, and how long an SD issue waits for the inhibits it needs to clear.
-define(SD_BLOCK, 512).
-define(INHIBIT_US, 10000).
-define(IS_SD_WORD(W), (is_integer(W) andalso W >= 0 andalso W =< 16#FFFFFFFF)).
%% CMD49's argument (Physical Layer 5.7.2.2, p.249): MIO in bit 31, the
%% mask-write bit 26, the address from bit 9 and the length less one in bits
%% 8-0; and the two bytes of the Performance Enhancement register set the
%% cache rule writes (Table 5-30, p.268-269).
-define(SD_EXT_MIO, 16#80000000).
-define(SD_EXT_MASK_WRITE, 16#04000000).
-define(SD_EXT_ADDRESS_SHIFT, 9).
-define(SD_EXT_LENGTH, 16#1FF).
-define(SD_PE_CACHE_ENABLE, 260).
-define(SD_PE_FLUSH_CACHE, 261).

%% One SD command as the controller issues it: the argument, the cmdtm word, the
%% blksizecnt word of a data command, and whether it uses the data lines.
-type sd_command() :: #{argument := 0..16#FFFFFFFF, word := 0..16#FFFFFFFF,
                        blksizecnt := none | 0..16#FFFFFFFF, dat := boolean()}.

%% A command ready to issue, made only by the plan builders below: the built
%% command, the response the controller takes, the data phase (direction, block
%% size and count), and for a write the bytes the builder checked, which
%% sd_feed/3 alone writes to `data`.
-record(sd_plan, {command :: sd_command(), response :: none | r1 | r1b | r2 | r3,
                  data :: none | {read | write, pos_integer(), pos_integer()},
                  feed = none :: none | binary()}).
-opaque sd_plan() :: #sd_plan{}.

%% A read of Count sectors from Sector: the header out, the sectors and the status in.
-spec read_segments(term(), term(), non_neg_integer()) ->
          {ok, [erx_device:segment()]} | {error, out_of_range | bad_count}.
read_segments(Sector, Count, Capacity) ->
    case erx_blk_request:range(Sector, Count, Capacity) of
        ok ->
            {ok, [{out, header(?ERX_VIRTIO_BLK_T_IN, Sector)},
                  {in, Count * ?ERX_VIRTIO_BLK_SECTOR_SIZE},
                  {in, ?STATUS_BYTES}]};
        Refused ->
            Refused
    end.

%% A write of Data, a whole number of sectors, from Sector: the header and the sectors out,
%% the status in. Data that is not a binary of one to max_sectors() whole sectors is
%% bad_count, and sectors past Capacity are out_of_range.
-spec write_segments(term(), term(), non_neg_integer()) ->
          {ok, [erx_device:segment()]} | {error, out_of_range | bad_count}.
write_segments(Sector, Data, Capacity) when is_binary(Data),
                                            byte_size(Data) rem ?ERX_VIRTIO_BLK_SECTOR_SIZE =:= 0 ->
    Count = byte_size(Data) div ?ERX_VIRTIO_BLK_SECTOR_SIZE,
    case erx_blk_request:range(Sector, Count, Capacity) of
        ok ->
            {ok, [{out, header(?ERX_VIRTIO_BLK_T_OUT, Sector)}, {out, Data}, {in, ?STATUS_BYTES}]};
        Refused ->
            Refused
    end;
write_segments(_Sector, _Data, _Capacity) ->
    {error, bad_count}.

%% A flush: the header out, with sector 0, since a flush names none (section 5.2.6), and
%% the status in.
-spec flush_segments() -> {ok, [erx_device:segment()]}.
flush_segments() ->
    {ok, [{out, header(?ERX_VIRTIO_BLK_T_FLUSH, 0)}, {in, ?STATUS_BYTES}]}.

%% Posts a read of Count sectors from Sector under Tag on the device's queue. A refused
%% read touches nothing.
-spec read(erx_device:device(), erx_device:queue(), non_neg_integer(), term(), term(),
           non_neg_integer()) -> ok | {error, out_of_range | bad_count | full | broken}.
read(Dev, Queue, Tag, Sector, Count, Capacity) ->
    post(Dev, Queue, Tag, read_segments(Sector, Count, Capacity)).

%% Posts a write of Data from Sector under Tag on the device's queue. A refused write
%% touches nothing.
-spec write(erx_device:device(), erx_device:queue(), non_neg_integer(), term(), term(),
            non_neg_integer()) -> ok | {error, out_of_range | bad_count | full | broken}.
write(Dev, Queue, Tag, Sector, Data, Capacity) ->
    post(Dev, Queue, Tag, write_segments(Sector, Data, Capacity)).

%% Posts a flush under Tag on the device's queue. Its completion says every write the
%% device completed before it is on the medium.
-spec flush(erx_device:device(), erx_device:queue(), non_neg_integer()) -> ok | {error, full | broken}.
flush(Dev, Queue, Tag) ->
    post(Dev, Queue, Tag, flush_segments()).

post(Dev, Queue, Tag, {ok, Segments}) -> erx_device:post(Dev, Queue, Tag, Segments);
post(_Dev, _Queue, _Tag, Refused) -> Refused.

%% A request's header, laid out as abi/formats/virtio.txt's erx_virtio_blk_req_header:
%% type, a reserved word and the first sector.
header(Type, Sector) ->
    <<Type:32/little, 0:32/little, Sector:64/little>>.

%%% The SD host controller

%% The SD table: the allowlist of the commands the card's identification may
%% issue (erx_blk_sd_card's steps), each with the response the controller is to
%% take and the data block it moves. R6 and R7 have R1's form, 48 bits with CRC
%% and index; R2 is 136 bits with CRC; R3, ACMD41's OCR, has neither check; R1b
%% is R1 followed by busy on DAT0 (Physical Layer 4.9, p.125-128; the command
%% list, 4.7.4, p.105-114). Any other command is refused: the reads, the writes
%% and CMD13 are built only by sd_read_command/3, sd_write_command/3 and
%% sd_status_command/1 below. sd_argument/3 fixes the arguments of the two
%% commands whose argument changes what the card keeps.
sd_table({cmd, 0}) -> {ok, none, none};
sd_table({cmd, 2}) -> {ok, r2, none};
sd_table({cmd, 3}) -> {ok, r1, none};
sd_table({cmd, 7}) -> {ok, r1b, none};
sd_table({cmd, 8}) -> {ok, r1, none};
sd_table({cmd, 9}) -> {ok, r2, none};
sd_table({cmd, 16}) -> {ok, r1, none};
sd_table({cmd, 48}) -> {ok, r1, {read, ?SD_BLOCK}};
sd_table({cmd, 49}) -> {ok, r1, {write, ?SD_BLOCK}};
sd_table({cmd, 55}) -> {ok, r1, none};
sd_table({acmd, 6}) -> {ok, r1, none};
sd_table({acmd, 13}) -> {ok, r1, {read, 64}};
sd_table({acmd, 41}) -> {ok, r3, none};
sd_table({acmd, 51}) -> {ok, r1, {read, 8}};
sd_table(_Command) -> refused.

%% CMD16 sets the block length to 512 and nothing else (Physical Layer 4.3.2,
%% p.52). CMD49 makes only the cache rule's two writes of the Performance
%% Enhancement register set (Physical Layer 5.7.2.2, p.249; Table 5-30,
%% p.268-269): one byte (length field 0), memory space (MIO clear), no mask,
%% Flush Cache (byte 261 of the page) set to 1 or Cache Enable (byte 260)
%% set to 0, the rest of the block zero. So no step can turn the card's
%% cache on.
sd_argument({cmd, 16}, Arg, none) ->
    Arg =:= ?SD_BLOCK;
sd_argument({cmd, 49}, Arg, {write, <<Value, Rest/binary>>}) ->
    Offset = (Arg bsr ?SD_EXT_ADDRESS_SHIFT) band (?SD_BLOCK - 1),
    Arg band (?SD_EXT_MIO bor ?SD_EXT_MASK_WRITE bor ?SD_EXT_LENGTH) =:= 0
        andalso Rest =:= <<0:((?SD_BLOCK - 1) * 8)>>
        andalso ({Offset, Value} =:= {?SD_PE_FLUSH_CACHE, 1} orelse {Offset, Value} =:= {?SD_PE_CACHE_ENABLE, 0});
sd_argument(_Command, _Arg, _Data) ->
    true.

%% One identification step of erx_blk_sd_card as the command the controller
%% issues: its argument, its cmdtm word, the block size and count for
%% blksizecnt, and whether it uses the data lines. A step the table does not
%% list, whose data disagrees with the table's, or whose argument
%% sd_argument/3 refuses, is refused.
-spec sd_command(term()) -> {ok, sd_command()} | {error, {sd_refused, term()}}.
sd_command(Step) ->
    command_of(sd_plan(Step)).

%% A read of Count sectors from Sector of the identified Card: CMD17 for one,
%% CMD18 with Auto CMD12 for more. The argument is the sector, times 512 on a
%% card addressed in bytes; the card's admission bounds both below 2^32.
-spec sd_read_command(term(), term(), erx_blk_sd_card:card()) ->
          {ok, sd_command()} | {error, out_of_range | bad_count}.
sd_read_command(Sector, Count, Card) ->
    command_of(sd_read_plan(Sector, Count, Card)).

%% A write of Data, whole sectors, from Sector: CMD24 for one, CMD25 with Auto
%% CMD12 for more. The only builder of a command that writes the medium.
-spec sd_write_command(term(), term(), erx_blk_sd_card:card()) ->
          {ok, sd_command()} | {error, out_of_range | bad_count}.
sd_write_command(Sector, Data, Card) ->
    command_of(sd_write_plan(Sector, Data, Card)).

%% CMD13, SEND_STATUS, to the card's address: a write's check that the card
%% has programmed it, and a flush (docs/design-storage.md, "Reads and writes").
-spec sd_status_command(erx_blk_sd_card:card()) -> {ok, sd_command()}.
sd_status_command(Card) ->
    command_of(sd_status_plan(Card)).

command_of({ok, #sd_plan{command = Command}}) -> {ok, Command};
command_of(Refused) -> Refused.

%% The plans: each builder above as the one value sd_issue/2 issues and
%% sd_feed/3 feeds, so the command issued, the blocks the device process
%% counts and the bytes it writes to `data` all come from the one check.
-spec sd_plan(term()) -> {ok, sd_plan()} | {error, {sd_refused, term()}}.
sd_plan({Kind, Index, Arg}) when ?IS_SD_WORD(Arg) ->
    sd_step(Kind, Index, Arg, none);
sd_plan({Kind, Index, Arg, {read, Size}}) when ?IS_SD_WORD(Arg) ->
    sd_step(Kind, Index, Arg, {read, Size});
sd_plan({Kind, Index, Arg, {write, Block}}) when ?IS_SD_WORD(Arg), is_binary(Block) ->
    sd_step(Kind, Index, Arg, {write, Block});
sd_plan(_Step) ->
    {error, {sd_refused, malformed}}.

sd_step(Kind, Index, Arg, Data) ->
    case {sd_table({Kind, Index}), sd_size(Data)} of
        {{ok, Response, Size}, Size} ->
            case sd_argument({Kind, Index}, Arg, Data) of
                true -> {ok, sd_plan_of(Index, Arg, Response, sd_blocks(Size, 1), sd_feed_of(Data))};
                false -> {error, {sd_refused, {argument, Kind, Index}}}
            end;
        {{ok, _Response, _Other}, _Size} ->
            {error, {sd_refused, {data, Kind, Index}}};
        {refused, _Size} when is_integer(Index) ->
            {error, {sd_refused, {Kind, Index}}};
        {refused, _Size} ->
            {error, {sd_refused, malformed}}
    end.

sd_size(none) -> none;
sd_size({read, Size}) -> {read, Size};
sd_size({write, Block}) -> {write, byte_size(Block)}.

sd_feed_of({write, Block}) -> Block;
sd_feed_of(_Data) -> none.

-spec sd_read_plan(term(), term(), erx_blk_sd_card:card()) ->
          {ok, sd_plan()} | {error, out_of_range | bad_count}.
sd_read_plan(Sector, Count, #{sectors := Sectors} = Card) ->
    case erx_blk_request:range(Sector, Count, Sectors) of
        ok -> {ok, sd_plan_of(sd_index(Count, 17, 18), sd_address(Sector, Card), r1,
                              {read, ?SD_BLOCK, Count}, none)};
        Refused -> Refused
    end.

-spec sd_write_plan(term(), term(), erx_blk_sd_card:card()) ->
          {ok, sd_plan()} | {error, out_of_range | bad_count}.
sd_write_plan(Sector, Data, #{sectors := Sectors} = Card)
  when is_binary(Data), byte_size(Data) rem ?SD_BLOCK =:= 0 ->
    Count = byte_size(Data) div ?SD_BLOCK,
    case erx_blk_request:range(Sector, Count, Sectors) of
        ok -> {ok, sd_plan_of(sd_index(Count, 24, 25), sd_address(Sector, Card), r1,
                              {write, ?SD_BLOCK, Count}, Data)};
        Refused -> Refused
    end;
sd_write_plan(_Sector, _Data, _Card) ->
    {error, bad_count}.

-spec sd_status_plan(erx_blk_sd_card:card()) -> {ok, sd_plan()}.
sd_status_plan(#{rca := Rca}) ->
    {ok, sd_plan_of(13, Rca bsl 16, r1, none, none)}.

%% What the device process waits for after the issue: the response it reads
%% and the data phase, the block size and count.
-spec sd_shape(sd_plan()) -> #{response := none | r1 | r1b | r2 | r3,
                               data := none | {read | write, pos_integer(), pos_integer()}}.
sd_shape(#sd_plan{response = Response, data = Data}) ->
    #{response => Response, data => Data}.

sd_blocks(none, _Count) -> none;
sd_blocks({Direction, Size}, Count) -> {Direction, Size, Count}.

sd_index(1, Single, _Multiple) -> Single;
sd_index(_Count, _Single, Multiple) -> Multiple.

sd_address(Sector, #{addressing := byte}) -> Sector * ?SD_BLOCK;
sd_address(Sector, #{addressing := block}) -> Sector.

sd_plan_of(Index, Arg, Response, Blocks, Feed) ->
    #sd_plan{command = sd_build(Index, Arg, Response, Blocks), response = Response, data = Blocks,
             feed = Feed}.

%% The command: the cmdtm word from the generated field macros, transfer mode
%% and command, DMA always off; blksizecnt for a data command.
sd_build(Index, Arg, Response, Blocks) ->
    {Resp, Crc, IndexCheck} = sd_response(Response),
    Data = case Blocks of none -> 0; _ -> 1 end,
    Command = ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_PUT(Index)
        bor ?ERX_HW_SDHCI_CMDTM_CMD_TYPE_PUT(?ERX_HW_SDHCI_CMDTM_CMD_TYPE_NORMAL)
        bor ?ERX_HW_SDHCI_CMDTM_CMD_RESP_PUT(Resp)
        bor ?ERX_HW_SDHCI_CMDTM_CMD_CRC_PUT(Crc)
        bor ?ERX_HW_SDHCI_CMDTM_CMD_INDEX_CHECK_PUT(IndexCheck)
        bor ?ERX_HW_SDHCI_CMDTM_CMD_DATA_PUT(Data),
    #{argument => Arg, word => Command bor sd_mode(Blocks), blksizecnt => sd_blksizecnt(Blocks),
      dat => Blocks =/= none orelse Response =:= r1b}.

sd_response(none) -> {?ERX_HW_SDHCI_CMDTM_CMD_RESP_NONE, 0, 0};
sd_response(r2) -> {?ERX_HW_SDHCI_CMDTM_CMD_RESP_BITS136, 1, 0};
sd_response(r3) -> {?ERX_HW_SDHCI_CMDTM_CMD_RESP_BITS48, 0, 0};
sd_response(r1) -> {?ERX_HW_SDHCI_CMDTM_CMD_RESP_BITS48, 1, 1};
sd_response(r1b) -> {?ERX_HW_SDHCI_CMDTM_CMD_RESP_BITS48_BUSY, 1, 1}.

%% The transfer mode (sdhci.c:1730-1743): block count enabled for every data
%% command, multiple blocks and Auto CMD12 for more than one, the direction;
%% TRNS_DMA is never set, and erx_device:command/2 refuses a word that sets it.
sd_mode(none) ->
    0;
sd_mode({Direction, _Size, Count}) ->
    Multiple = case Count of 1 -> 0; _ -> 1 end,
    Read = case Direction of read -> 1; write -> 0 end,
    ?ERX_HW_SDHCI_CMDTM_TRNS_BLK_CNT_EN_PUT(1)
        bor ?ERX_HW_SDHCI_CMDTM_TRNS_MULTI_PUT(Multiple)
        bor ?ERX_HW_SDHCI_CMDTM_TRNS_ACMD12_PUT(Multiple)
        bor ?ERX_HW_SDHCI_CMDTM_TRNS_READ_PUT(Read).

sd_blksizecnt(none) ->
    none;
sd_blksizecnt({_Direction, Size, Count}) ->
    ?ERX_HW_SDHCI_BLKSIZECNT_BLKSIZE_PUT(Size) bor ?ERX_HW_SDHCI_BLKSIZECNT_BLKCNT_PUT(Count).

%% The issue (facts record, "Issuing a command") of a plan the builders above
%% made: present until the inhibits the command needs clear, for at most
%% INHIBIT_US; `interrupt`'s one-to-clear bits, so that no status an earlier command
%% left before the issue reaches this one's wait (one it raises later still can); blksizecnt for a data command; arg; then the cmdtm
%% word, the one write erx_device:command/2 makes. Each write is spaced by
%% erx_blk_sd_regs.
%% An inhibited command touches nothing but `present`.
-spec sd_issue(erx_blk_sd_regs:regs(), sd_plan()) -> {ok, erx_blk_sd_regs:regs()} | {error, {device, inhibit}}.
sd_issue(Regs, #sd_plan{command = #{argument := Arg, word := Word, blksizecnt := BlkSizeCnt, dat := Dat}}) ->
    Dev = erx_blk_sd_regs:device(Regs),
    case sd_wait_inhibit(Dev, Dat, erlang:monotonic_time(microsecond) + ?INHIBIT_US) of
        ok ->
            Cleared = erx_blk_sd_regs:write(Regs, interrupt, erx_blk_sd_host:ack_mask()),
            Sized = case BlkSizeCnt of
                        none -> Cleared;
                        _ -> erx_blk_sd_regs:write(Cleared, blksizecnt, BlkSizeCnt)
                    end,
            Argued = erx_blk_sd_regs:write(Sized, arg, Arg),
            {ok, erx_blk_sd_regs:spaced(Argued, fun() -> erx_device:command(Dev, Word) end)};
        inhibited ->
            {error, {device, inhibit}}
    end.

sd_wait_inhibit(Dev, Dat, Until) ->
    case erx_blk_sd_host:inhibited(erx_device:read(Dev, present), Dat) of
        false -> ok;
        true ->
            case erlang:monotonic_time(microsecond) >= Until of
                true -> inhibited;
                false -> sd_wait_inhibit(Dev, Dat, Until)
            end
    end.

%% Block Index of a write plan's data into `data` at a buffer write ready:
%% 128 words, the first byte in the low byte of the first word (facts record,
%% "PIO data transfer"). The data port is exempt from the spacing. A block
%% the plan does not hold is refused before any write.
-spec sd_feed(erx_blk_sd_regs:regs(), sd_plan(), term()) -> ok | {error, {feed, term()}}.
sd_feed(Regs, #sd_plan{data = {write, Size, Count}, feed = Feed}, Index)
  when is_integer(Index), Index >= 0, Index < Count ->
    Dev = erx_blk_sd_regs:device(Regs),
    Block = binary:part(Feed, Index * Size, Size),
    lists:foreach(fun(Word) -> erx_device:write(Dev, data, Word) end,
                  [Word || <<Word:32/little>> <= Block]);
sd_feed(_Regs, _Plan, Index) ->
    {error, {feed, Index}}.
