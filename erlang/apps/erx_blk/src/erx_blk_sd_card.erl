%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_blk_sd_card).
-moduledoc """
The SD card's pure core (docs/design-storage.md, "The SD host controller"):
the card's identification as a state machine and the parsers of what the
card sends. Nothing here touches a device; the device process, erx_blk_sd,
performs the actions and hands back the events, and the module is tested and
fuzzed on the host (test/erlang/erx_blk_sd_card_tests.erl and
erx_blk_sd_fuzz.erl).

Identification is start/0 and then step/2 until an action says the card is
identified or refused. Every event is one of:

* `{response, none}` for CMD0, which has no response;
* `{response, Word}` with the 32-bit response word for R1, R3, R6 and R7;
* `{response, [Resp0, Resp1, Resp2, Resp3]}` with the four response words of
  an R2, as the controller stores them, without the CRC byte;
* `{data, R1, Bytes}` for a step that reads a data block: its R1 and the
  bytes in the order the card sent them;
* `timeout`, a command timeout: the command timeout error bit alone (with
  command CRC as well it is a CMD line conflict, Host Controller Table 2-26,
  and an `{error, Detail}`);
* `{error, Detail}`, any other error the device process saw (an error bit,
  a missed step deadline, a reset that did not clear), Detail a fixed term.

The actions are `{issue, Step}`, `{reset, cmd | dat}`, `{wait, Ms}`,
`{bus_width, 4}`, `{clock, Hz}`, and at the end exactly one of
`{identified, Card}` or `{refuse, {Phase, Detail}}`. A step names the
command and its full argument: `{cmd | acmd, Index, Argument}`, or with a
data block `{cmd | acmd, Index, Argument, {read, Bytes}}` or
`{cmd, 49, Argument, {write, Block}}`. The sequence is the design's step 4 to
6 of the start sequence, in FreeBSD's order: CMD0, CMD8, the ACMD41 inquiry,
CMD0 and CMD8 again, the ACMD41 loop, CMD2, CMD3, CMD9, CMD7, CMD16 on a
standard-capacity card, ACMD51, ACMD6, ACMD13 and the cache rule.

Everything the card sent is untrusted: a response of the wrong shape, an
R1 with an error bit, a register that does not parse or a card that
disagrees with itself refuses the card with a reason built from fixed atoms
and the card's integers, never an atom made from its data.
""".

-export([start/0, step/2, phase/1]).
-export([r1/1, r1_errors/1, r2/1, r3/1, r6/1, r7/1, csd/1, admit/2, scr/1,
         sd_status/1, general_information/1, performance_enhancement/1]).
-export([r1_error_mask/0]).

-export_type([state/0, event/0, action/0, step/0, card/0, csd/0, reason/0]).

%% CMD8's argument: supply 2.7 to 3.6 V and check pattern AAh (Physical
%% Layer 4.3.13, p.90). An R7 echoes both in its low 12 bits.
-define(IF_COND, 16#1AA).
-define(IF_COND_MASK, 16#FFF).
%% The OCR's 3.2-3.3 V and 3.3-3.4 V bits, capacity bit and busy bit
%% (MMC_OCR_320_330, MMC_OCR_330_340, MMC_OCR_CCS, MMC_OCR_CARD_BUSY,
%% mmcreg.h:638-650). ACMD41's HCS is the capacity bit's position.
-define(OCR_33V, 16#00300000).
-define(OCR_CCS, 16#40000000).
-define(OCR_READY, 16#80000000).
%% The R1 bits the specification types as errors: 31 to 26, 24 to 19, 16,
%% 15 and 3 (Physical Layer Table 4-42, p.120-122).
-define(R1_ERRORS, 16#FDF98008).
-define(R1_ILLEGAL_COMMAND, 16#00400000).
-define(R1_LOCKED, 16#02000000).
%% FreeBSD's bound on ACMD41's tries, every 10 ms (mmc.c:598-607).
-define(ACMD41_TRIES, 1000).
-define(ACMD41_WAIT_MS, 10).
%% A flush is polled every 10 ms for at most the 1 s the specification
%% gives it (Physical Layer 4.17, p.179).
-define(FLUSH_POLLS, 100).
-define(FLUSH_WAIT_MS, 10).
-define(CMD0_WAIT_MS, 1).
-define(BLOCK, 512).
-define(DEFAULT_SPEED_HZ, 25000000).
%% Extension registers (Physical Layer 5.7): the General Information is at
%% function 0, page 0, at most 1024 bytes; the Performance Enhancement
%% function's standard code is 0002h (Table 5-27, p.261); Cache Enable and
%% Flush Cache are bit 0 of bytes 260 and 261 of its register set
%% (Table 5-30, p.268-269).
-define(GI_MAX, 1024).
-define(GI_HEADER, 16).
-define(GI_EXTENSION_FIXED, 44).
-define(SFC_PERFORMANCE, 2).
-define(PE_CACHE_ENABLE, 260).
-define(PE_FLUSH_CACHE, 261).
-define(IS_WORD(W), (is_integer(W) andalso W >= 0 andalso W =< 16#FFFFFFFF)).

-type phase() :: go_idle_1 | if_cond_1 | app_inquiry | op_inquiry | go_idle_2
               | if_cond_2 | app_init | op_init | all_send_cid | send_rca
               | send_csd | select | blocklen | app_scr | scr | app_bus | bus
               | app_status | sd_status | gi_page0 | gi_page1 | pe_read
               | flush_write | flush_poll | disable_write | disable_check
               | finished.
-type step() :: {cmd | acmd, 0..63, 0..16#FFFFFFFF}
              | {cmd | acmd, 0..63, 0..16#FFFFFFFF, {read, pos_integer()}}
              | {cmd, 49, 0..16#FFFFFFFF, {write, binary()}}.
-type event() :: {response, none | integer() | [integer()]}
               | {data, integer(), binary()} | timeout | {error, term()}.
-type reason() :: {phase(), term()}.
-type card() :: #{addressing := byte | block, sectors := pos_integer(),
                  rca := 1..16#FFFF, ocr := 0..16#FFFFFFFF,
                  cid := non_neg_integer(), csd := csd(),
                  cmd8 := echoed | timeout, cache := absent | off | flushed}.
-type action() :: {issue, step()} | {reset, cmd | dat} | {wait, pos_integer()}
                | {bus_width, 4} | {clock, pos_integer()}
                | {identified, card()} | {refuse, reason()}.
-type csd() :: #{structure := 0, read_bl_len := 0..15, c_size := 0..16#FFF,
                 c_size_mult := 0..7}
             | #{structure := 1, read_bl_len := 0..15, c_size := 0..16#3FFFFF}.

%% What identification has learnt so far. cmd8 is the first CMD8's answer,
%% which the second must repeat; extension_registers is the SCR's CMD48 and
%% CMD49 bit, which the cache rule reads; illegal_ok is set by a CMD8 timeout and
%% excuses the illegal-command bit of the one R1 after it, CMD55's
%% (Physical Layer 4.6.1, p.95).
-record(id, {phase = go_idle_1 :: phase(),
             cmd8 :: undefined | echoed | timeout,
             illegal_ok = false :: boolean(),
             tries = 0 :: non_neg_integer(),
             ocr = 0 :: 0..16#FFFFFFFF,
             cid = 0 :: non_neg_integer(),
             rca = 0 :: 0..16#FFFF,
             csd :: undefined | csd(),
             fit :: undefined | #{addressing := byte | block, sectors := pos_integer()},
             gi_page0 = <<>> :: binary(),
             pe :: undefined | {0..15, 0..16#1FFFF},
             extension_registers = false :: boolean(),
             polls = 0 :: non_neg_integer()}).
-opaque state() :: #id{}.

%%% Identification

-doc "The first actions and state of identification: CMD0.".
-spec start() -> {[action()], state()}.
start() ->
    {[{issue, cmd(0, 0)}], #id{}}.

-doc "The phase identification is in, which a refusal and the log name.".
-spec phase(state()) -> phase().
phase(#id{phase = Phase}) -> Phase.

-doc """
One transition: the actions that follow Event in State and the next state.
A finished identification takes every event with no action.
""".
%% Any term is taken; one that is not an event() refuses the card.
-spec step(state(), term()) -> {[action()], state()}.
step(#id{phase = finished} = S, _Event) ->
    {[], S};
step(#id{phase = Phase} = S, timeout) when Phase =:= if_cond_1;
                                           Phase =:= if_cond_2 ->
    cmd8_answer(S, timeout);
step(#id{} = S, timeout) ->
    refuse(S, timeout);
step(#id{} = S, {error, Detail}) ->
    refuse(S, {error, Detail});
step(#id{} = S, Event) ->
    answer(S, Event).

%% The answer each phase expects, in the order the phases run.
answer(#id{phase = go_idle_1} = S, {response, none}) ->
    issue(S, if_cond_1, [{wait, ?CMD0_WAIT_MS}], cmd(8, ?IF_COND));
answer(#id{phase = Phase} = S, {response, R7}) when Phase =:= if_cond_1;
                                                    Phase =:= if_cond_2 ->
    case r7(R7) of
        {ok, _} when R7 band ?IF_COND_MASK =:= ?IF_COND -> cmd8_answer(S, echoed);
        _ -> refuse(S, {r7, word(R7)})
    end;
answer(#id{phase = app_inquiry} = S, {response, R1}) ->
    with_r1(S, R1, fun(S1) -> issue(S1, op_inquiry, [], acmd(41, 0)) end);
answer(#id{phase = op_inquiry} = S, {response, R3}) ->
    case r3(R3) of
        {ok, #{ocr := Ocr}} when Ocr band ?OCR_33V =/= 0 ->
            issue(S, go_idle_2, [], cmd(0, 0));
        _ ->
            refuse(S, {voltage_window, word(R3)})
    end;
answer(#id{phase = go_idle_2} = S, {response, none}) ->
    issue(S, if_cond_2, [{wait, ?CMD0_WAIT_MS}], cmd(8, ?IF_COND));
answer(#id{phase = app_init} = S, {response, R1}) ->
    with_r1(S, R1, fun(S1) -> issue(S1, op_init, [], acmd(41, op_cond(S1))) end);
answer(#id{phase = op_init} = S, {response, R3}) ->
    op_init(S, r3(R3));
answer(#id{phase = all_send_cid} = S, {response, Words}) ->
    case r2(Words) of
        {ok, Cid} -> issue(S#id{cid = Cid}, send_rca, [], cmd(3, 0));
        {error, _} -> refuse(S, {r2, shape(Words)})
    end;
answer(#id{phase = send_rca} = S, {response, R6}) ->
    case r6(R6) of
        {ok, #{rca := 0}} ->
            refuse(S, {rca, 0});
        {ok, #{rca := Rca, status := Status}} when Status band ?R1_ERRORS =:= 0 ->
            issue(S#id{rca = Rca}, send_csd, [], cmd(9, Rca bsl 16));
        _ ->
            refuse(S, {r6, word(R6)})
    end;
answer(#id{phase = send_csd, ocr = Ocr} = S, {response, Words}) ->
    Admitted = case r2(Words) of
                   {ok, Raw} ->
                       case csd(Raw) of
                           {ok, Csd} -> {Csd, admit(Ocr band ?OCR_CCS =/= 0, Csd)};
                           {error, _} = Error -> Error
                       end;
                   {error, _} = Error ->
                       Error
               end,
    case Admitted of
        {Csd1, {ok, Fit}} ->
            issue(S#id{csd = Csd1, fit = Fit}, select, [], cmd(7, S#id.rca bsl 16));
        {_, {error, Why}} -> refuse(S, Why);
        {error, Why} -> refuse(S, Why)
    end;
answer(#id{phase = select} = S, {response, R1}) when ?IS_WORD(R1),
                                                    R1 band ?R1_LOCKED =/= 0 ->
    refuse(S, {locked, R1});
answer(#id{phase = select, fit = #{addressing := byte}} = S, {response, R1}) ->
    with_r1(S, R1, fun(S1) -> issue(S1, blocklen, [], cmd(16, ?BLOCK)) end);
answer(#id{phase = Phase} = S, {response, R1}) when Phase =:= select;
                                                    Phase =:= blocklen ->
    with_r1(S, R1, fun(S1) -> app(S1, app_scr) end);
answer(#id{phase = app_scr} = S, {response, R1}) ->
    with_r1(S, R1, fun(S1) -> issue(S1, scr, [], acmd(51, 0, {read, 8})) end);
answer(#id{phase = scr} = S, {data, R1, Bytes}) ->
    with_r1(S, R1, fun(S1) ->
                           case scr(Bytes) of
                               {ok, #{four_bit := true} = Scr} ->
                                   app(S1#id{extension_registers = maps:get(extension_registers, Scr)},
                                       app_bus);
                               {ok, _} -> refuse(S1, no_four_bit_bus);
                               {error, Why} -> refuse(S1, {scr, Why})
                           end
                   end);
answer(#id{phase = app_bus} = S, {response, R1}) ->
    with_r1(S, R1, fun(S1) -> issue(S1, bus, [], acmd(6, 2)) end);
answer(#id{phase = bus} = S, {response, R1}) ->
    with_r1(S, R1, fun(S1) ->
                           {Actions, S2} = app(S1, app_status),
                           {[{bus_width, 4}, {clock, ?DEFAULT_SPEED_HZ} | Actions], S2}
                   end);
answer(#id{phase = app_status} = S, {response, R1}) ->
    with_r1(S, R1, fun(S1) -> issue(S1, sd_status, [], acmd(13, 0, {read, 64})) end);
answer(#id{phase = sd_status} = S, {data, R1, Bytes}) ->
    with_r1(S, R1, fun(S1) -> cache(S1, sd_status(Bytes)) end);
answer(#id{phase = gi_page0} = S, {data, R1, Bytes}) ->
    with_r1(S, R1, fun(S1) -> general_information_page(S1, Bytes) end);
answer(#id{phase = gi_page1, gi_page0 = Page0} = S, {data, R1, Bytes}) when is_binary(Bytes) ->
    with_r1(S, R1, fun(S1) -> performance_function(S1, <<Page0/binary, Bytes/binary>>) end);
answer(#id{phase = pe_read} = S, {data, R1, Bytes}) ->
    with_pe(S, R1, Bytes,
            fun(S1, #{cache_enable := false}) -> identified(S1, off);
               (S1, #{cache_enable := true}) ->
                    issue(S1, flush_write, [], pe_write(S1, ?PE_FLUSH_CACHE, 1))
            end);
answer(#id{phase = flush_write} = S, {response, R1}) ->
    with_r1(S, R1, fun(S1) -> issue(S1#id{polls = 1}, flush_poll, [], pe_read(S1)) end);
answer(#id{phase = flush_poll} = S, {data, R1, Bytes}) ->
    with_pe(S, R1, Bytes,
            fun(S1, #{flush := false}) ->
                    issue(S1, disable_write, [], pe_write(S1, ?PE_CACHE_ENABLE, 0));
               (#id{polls = Polls} = S1, #{flush := true}) when Polls >= ?FLUSH_POLLS ->
                    refuse(S1, {flush_timeout, Polls});
               (#id{polls = Polls} = S1, #{flush := true}) ->
                    issue(S1#id{polls = Polls + 1}, flush_poll, [{wait, ?FLUSH_WAIT_MS}],
                          pe_read(S1))
            end);
answer(#id{phase = disable_write} = S, {response, R1}) ->
    with_r1(S, R1, fun(S1) -> issue(S1, disable_check, [], pe_read(S1)) end);
answer(#id{phase = disable_check} = S, {data, R1, Bytes}) ->
    with_pe(S, R1, Bytes,
            fun(S1, #{cache_enable := false}) -> identified(S1, flushed);
               (S1, #{cache_enable := true}) -> refuse(S1, cache_still_enabled)
            end);
answer(#id{} = S, Event) ->
    refuse(S, {unexpected, shape(Event)}).

%% CMD8's answer, echoed or timed out. The first sets the card's kind and
%% the second must agree with it. A timeout needs the command and data line
%% resets before the next command can issue (Host Controller p.28, p.30).
cmd8_answer(#id{phase = if_cond_1} = S, Answer) ->
    cmd8_next(S#id{cmd8 = Answer}, Answer, app_inquiry);
cmd8_answer(#id{phase = if_cond_2, cmd8 = Answer} = S, Answer) ->
    cmd8_next(S, Answer, app_init);
cmd8_answer(#id{phase = if_cond_2} = S, Answer) ->
    refuse(S, {cmd8_disagrees, Answer}).

cmd8_next(S, echoed, Next) ->
    issue(S, Next, [], cmd(55, 0));
cmd8_next(S, timeout, Next) ->
    issue(S#id{illegal_ok = true}, Next, [{reset, cmd}, {reset, dat}], cmd(55, 0)).

%% ACMD41's argument in the loop: 3.2 to 3.4 V, and high capacity only
%% after an echoed CMD8. XPC and S18R stay clear (Physical Layer p.45).
op_cond(#id{cmd8 = echoed}) -> ?OCR_33V bor ?OCR_CCS;
op_cond(#id{cmd8 = timeout}) -> ?OCR_33V.

op_init(S, {ok, #{ready := true, ccs := true}}) when S#id.cmd8 =/= echoed ->
    refuse(S, capacity_without_hcs);
op_init(S, {ok, #{ready := true, ocr := Ocr}}) ->
    issue(S#id{ocr = Ocr}, all_send_cid, [], cmd(2, 0));
op_init(#id{tries = Tries} = S, {ok, #{ready := false}}) when Tries + 1 >= ?ACMD41_TRIES ->
    refuse(S, {busy, Tries + 1});
op_init(#id{tries = Tries} = S, {ok, #{ready := false}}) ->
    issue(S#id{tries = Tries + 1}, app_init, [{wait, ?ACMD41_WAIT_MS}], cmd(55, 0));
op_init(S, {error, _}) ->
    refuse(S, malformed_r3).

%% The cache rule: no cache goes on, a cache needs CMD48 and CMD49.
cache(S, {ok, #{cache := false}}) ->
    identified(S, absent);
cache(#id{extension_registers = false} = S, {ok, #{cache := true}}) ->
    refuse(S, cache_without_extension_registers);
cache(S, {ok, #{cache := true}}) ->
    issue(S, gi_page0, [], extension_read(0, 0));
cache(S, {error, Why}) ->
    refuse(S, {sd_status, Why}).

%% A General Information longer than a page continues on page 1.
general_information_page(S, <<_:16, Length:16/little, _/binary>> = Page0)
  when byte_size(Page0) =:= ?BLOCK, Length > ?BLOCK, Length =< ?GI_MAX ->
    issue(S#id{gi_page0 = Page0}, gi_page1, [], extension_read(0, ?BLOCK));
general_information_page(S, Page0) ->
    performance_function(S, Page0).

%% The register set must start on a page: it is 512 bytes and one CMD48
%% reads within one page (Physical Layer 5.7.2.1, p.248).
performance_function(S, Bytes) ->
    case general_information(Bytes) of
        {ok, #{performance := {_Fno, Start} = Pe}} when Start rem ?BLOCK =:= 0 ->
            issue(S#id{pe = Pe}, pe_read, [], pe_read(S#id{pe = Pe}));
        {ok, #{performance := {_, Start}}} -> refuse(S, {performance_unaligned, Start});
        {ok, #{performance := none}} -> refuse(S, no_performance_function);
        {error, Why} -> refuse(S, {general_information, Why})
    end.

with_pe(S, R1, Bytes, Next) ->
    with_r1(S, R1, fun(S1) ->
                           case performance_enhancement(Bytes) of
                               {ok, Pe} -> Next(S1, Pe);
                               {error, Why} -> refuse(S1, {performance_enhancement, Why})
                           end
                   end).

%% An R1 with no error bit lets the phase go on; the illegal-command bit
%% is excused once, in the R1 after a CMD8 timeout.
with_r1(#id{illegal_ok = Excused} = S, R1, Next) ->
    Errors = case r1_errors(R1) of
                 {ok, Bits} when Excused -> Bits band bnot ?R1_ILLEGAL_COMMAND;
                 {ok, Bits} -> Bits;
                 {error, _} -> malformed
             end,
    case Errors of
        0 -> Next(S#id{illegal_ok = false});
        malformed -> refuse(S, {r1, shape(R1)});
        _ -> refuse(S, {r1, R1})
    end.

identified(#id{fit = Fit, rca = Rca, ocr = Ocr, cid = Cid, csd = Csd, cmd8 = Cmd8} = S, Cache) ->
    Card = Fit#{rca => Rca, ocr => Ocr, cid => Cid, csd => Csd, cmd8 => Cmd8, cache => Cache},
    {[{identified, Card}], S#id{phase = finished}}.

refuse(#id{phase = Phase} = S, Detail) ->
    {[{refuse, {Phase, Detail}}], S#id{phase = finished}}.

issue(S, Next, Before, Step) ->
    {Before ++ [{issue, Step}], S#id{phase = Next}}.

app(#id{rca = Rca} = S, Next) ->
    issue(S, Next, [], cmd(55, Rca bsl 16)).

cmd(Index, Arg) -> {cmd, Index, Arg}.
acmd(Index, Arg) -> {acmd, Index, Arg}.
acmd(Index, Arg, Data) -> {acmd, Index, Arg, Data}.

%% CMD48 and CMD49's argument: MIO 0 (memory), FNO in bits 30-27, the
%% mask-write bit 26 clear, the 17-bit address in bits 25-9 and the length
%% less one in bits 8-0 (Physical Layer 5.7.2.1-2, p.247-249).
extension_arg(Fno, Address, Length) ->
    (Fno bsl 27) bor (Address bsl 9) bor (Length - 1).

extension_read(Fno, Address) ->
    {cmd, 48, extension_arg(Fno, Address, ?BLOCK), {read, ?BLOCK}}.

pe_read(#id{pe = {Fno, Start}}) ->
    extension_read(Fno, Start).

%% One byte written at the top of the 512-byte block; the rest is ignored.
pe_write(#id{pe = {Fno, Start}}, Offset, Value) ->
    {cmd, 49, extension_arg(Fno, Start + Offset, 1),
     {write, <<Value, 0:((?BLOCK - 1) * 8)>>}}.

%% A response word, or the kind of a malformed value, so a refusal never
%% carries a large term.
word(W) when ?IS_WORD(W) -> W;
word(V) -> shape(V).

shape(V) when is_integer(V) -> integer;
shape(V) when is_list(V) -> list;
shape(V) when is_binary(V) -> {binary, byte_size(V)};
shape({response, V}) -> {response, shape(V)};
shape({data, R1, B}) -> {data, shape(R1), shape(B)};
shape(V) when is_tuple(V) -> {tuple, tuple_size(V)};
shape(_) -> other.

%%% Responses

-doc "The R1 bits the specification types as errors.".
-spec r1_error_mask() -> 0..16#FFFFFFFF.
r1_error_mask() -> ?R1_ERRORS.

-doc """
An R1, the card status (Physical Layer Table 4-42, p.120-122): its error
bits, its current state (bits 12-9), ready for data (bit 8), card locked
(bit 25) and APP_CMD (bit 5).
""".
-spec r1(term()) -> {ok, #{errors := non_neg_integer(), state := 0..15,
                           ready := boolean(), locked := boolean(),
                           app_cmd := boolean()}} | {error, malformed}.
r1(W) when ?IS_WORD(W) ->
    {ok, #{errors => W band ?R1_ERRORS, state => (W bsr 9) band 15,
           ready => W band 16#100 =/= 0, locked => W band ?R1_LOCKED =/= 0,
           app_cmd => W band 16#20 =/= 0}};
r1(_) ->
    {error, malformed}.

-doc "An R1's error bits alone.".
-spec r1_errors(term()) -> {ok, non_neg_integer()} | {error, malformed}.
r1_errors(W) when ?IS_WORD(W) -> {ok, W band ?R1_ERRORS};
r1_errors(_) -> {error, malformed}.

-doc """
An R2's 128 bits from the controller's four response words. The controller
stores the response's bits 127 to 8 in the words' bits 119 to 0, without the
CRC, so the words are shifted one byte up before any field is read
(sdhci.c:1899-1912); bits 7 to 0 of the result are zero.
""".
-spec r2(term()) -> {ok, non_neg_integer()} | {error, malformed}.
r2([W0, W1, W2, W3]) when ?IS_WORD(W0), ?IS_WORD(W1), ?IS_WORD(W2), ?IS_WORD(W3) ->
    Stored = (W3 bsl 96) bor (W2 bsl 64) bor (W1 bsl 32) bor W0,
    {ok, (Stored bsl 8) band ((1 bsl 128) - 1)};
r2(_) ->
    {error, malformed}.

-doc """
An R3, the OCR: busy bit 31 set when the card is ready, the capacity bit 30
(valid once ready), and the word itself (Physical Layer 5.1, p.222).
""".
-spec r3(term()) -> {ok, #{ready := boolean(), ccs := boolean(),
                           ocr := 0..16#FFFFFFFF}} | {error, malformed}.
r3(W) when ?IS_WORD(W) ->
    {ok, #{ready => W band ?OCR_READY =/= 0, ccs => W band ?OCR_CCS =/= 0, ocr => W}};
r3(_) ->
    {error, malformed}.

-doc """
An R6: the card's new relative address in bits 31-16 and, in bits 15-0,
card status bits 23, 22, 19 and 12-0, returned in their R1 positions
(Physical Layer 4.9.5, p.128).
""".
-spec r6(term()) -> {ok, #{rca := 0..16#FFFF, status := 0..16#FFFFFFFF}}
                        | {error, malformed}.
r6(W) when ?IS_WORD(W) ->
    Status = ((W band 16#8000) bsl 8) bor ((W band 16#4000) bsl 8)
        bor ((W band 16#2000) bsl 6) bor (W band 16#1FFF),
    {ok, #{rca => W bsr 16, status => Status}};
r6(_) ->
    {error, malformed}.

-doc """
An R7: the accepted voltage in bits 11-8 and the echoed check pattern in
bits 7-0 (Physical Layer 4.9.6, p.129).
""".
-spec r7(term()) -> {ok, #{voltage := 0..15, pattern := 0..255}} | {error, malformed}.
r7(W) when ?IS_WORD(W) ->
    {ok, #{voltage => (W bsr 8) band 15, pattern => W band 255}};
r7(_) ->
    {error, malformed}.

%%% Registers

-doc """
The CSD's fields the admission reads, from r2/1's 128 bits: structure 0
(Physical Layer 5.3.2, p.226-231) or structure 1 (5.3.3, p.233-235). Any
other structure, SDUC's included, is refused.
""".
-spec csd(term()) -> {ok, csd()} | {error, {csd_structure, 2..3} | malformed}.
csd(Raw) when is_integer(Raw), Raw >= 0, Raw < 1 bsl 128 ->
    case <<Raw:128>> of
        <<0:2, _:42, ReadBlLen:4, _:6, CSize:12, _:12, CSizeMult:3, _:47>> ->
            {ok, #{structure => 0, read_bl_len => ReadBlLen, c_size => CSize,
                   c_size_mult => CSizeMult}};
        <<1:2, _:42, ReadBlLen:4, _:10, CSize:22, _:48>> ->
            {ok, #{structure => 1, read_bl_len => ReadBlLen, c_size => CSize}};
        <<Structure:2, _:126>> ->
            {error, {csd_structure, Structure}}
    end;
csd(_) ->
    {error, malformed}.

-doc """
A card's admission from the OCR's capacity bit and its CSD (the design's
"Admitting a card"): structure 0 goes with the bit clear and is addressed
in bytes, with READ_BL_LEN of 9, 10 or 11 (Physical Layer Table 5-8,
p.228); structure 1 goes with the bit set and is addressed in 512-byte
blocks, with READ_BL_LEN of 9. Those bounds keep every address within the
commands' 32-bit argument. The capacity is in 512-byte sectors.
""".
-spec admit(boolean(), csd()) ->
          {ok, #{addressing := byte | block, sectors := pos_integer()}}
              | {error, term()}.
admit(false, #{structure := 0, read_bl_len := Len, c_size := CSize, c_size_mult := Mult})
  when Len >= 9, Len =< 11 ->
    Bytes = (CSize + 1) bsl (Mult + 2 + Len),
    {ok, #{addressing => byte, sectors => Bytes div ?BLOCK}};
admit(true, #{structure := 1, read_bl_len := 9, c_size := CSize}) ->
    {ok, #{addressing => block, sectors => (CSize + 1) * 1024}};
admit(false, #{structure := 0, read_bl_len := Len}) ->
    {error, {read_bl_len, Len}};
admit(true, #{structure := 1, read_bl_len := Len}) ->
    {error, {read_bl_len, Len}};
admit(Ccs, #{structure := Structure}) ->
    {error, {capacity_disagrees, Structure, Ccs}}.

-doc """
The SCR from ACMD51's 8 bytes (Physical Layer 5.6, p.240-245): structure
0 only, whose layout this is; the 4-bit bus (SD_BUS_WIDTHS bit 2, SCR bit
50) and CMD48/CMD49 (CMD_SUPPORT, SCR bit 34, Table 5-23, p.245).
""".
-spec scr(term()) -> {ok, #{spec := 0..15, four_bit := boolean(),
                            extension_registers := boolean()}}
                         | {error, malformed | {scr_structure, 1..15}}.
scr(<<0:4, Spec:4, _:4, BusWidths:4, _:11, CmdSupport:5, _:32>>) ->
    {ok, #{spec => Spec, four_bit => BusWidths band 4 =/= 0,
           extension_registers => CmdSupport band 4 =/= 0}};
scr(<<Structure:4, _:60>>) ->
    {error, {scr_structure, Structure}};
scr(_) ->
    {error, malformed}.

-doc """
The 64-byte SD status from ACMD13 (Physical Layer 4.10.2, Table 4.10.2-1,
p.130): the bus width, bits 511-510, and cache support, bit 330
(Table 4.10.2-2, p.133).
""".
-spec sd_status(term()) -> {ok, #{bus_width := 0..3, cache := boolean()}}
                               | {error, malformed}.
sd_status(<<BusWidth:2, _:179, Cache:1, _:330>>) ->
    {ok, #{bus_width => BusWidth, cache => Cache =:= 1}};
sd_status(_) ->
    {error, malformed}.

-doc """
The General Information (Physical Layer 5.7.3, Figure 5-15, p.256-258),
little-endian: a 16-byte header with the length and the number of
extensions, then the extensions, each found from the one before by its
pointer. It is parsed within the length its header gives, at most 1024
bytes, and names the Performance Enhancement function's first register
set (standard function code 0002h) by its function number and start
address (Table 5-24, p.258), or none.
""".
-spec general_information(term()) ->
          {ok, #{length := pos_integer(), extensions := 0..255,
                 performance := none | {0..15, 0..16#1FFFF}}}
              | {error, term()}.
general_information(<<_Revision:16, Length:16/little, Count, _/binary>> = Bytes)
  when Length >= ?GI_HEADER, Length =< ?GI_MAX, Length =< byte_size(Bytes) ->
    Info = binary:part(Bytes, 0, Length),
    case extensions(Info, ?GI_HEADER, Count) of
        {ok, Performance} ->
            {ok, #{length => Length, extensions => Count, performance => Performance}};
        {error, _} = Error ->
            Error
    end;
general_information(<<_:16, Length:16/little, _/binary>>) ->
    {error, {length, Length}};
general_information(_) ->
    {error, malformed}.

%% Walks at most Count extensions; each pointer must move forward, so the
%% walk ends whatever the card wrote.
extensions(_Info, _Offset, 0) ->
    {ok, none};
extensions(Info, Offset, Count) ->
    case Info of
        <<_:Offset/binary, Sfc:16/little, _:38/binary, Next:16/little, Sets, _,
          Rest/binary>> when byte_size(Rest) >= Sets * 4 ->
            case {Sfc, Sets, Rest} of
                {?SFC_PERFORMANCE, 0, _} ->
                    {error, {no_register_set, Offset}};
                {?SFC_PERFORMANCE, _, <<Address:32/little, _/binary>>} ->
                    {ok, {(Address bsr 18) band 15, Address band 16#1FFFF}};
                _ ->
                    following(Info, Offset, Next band 16#3FF, Count - 1)
            end;
        _ ->
            {error, {extension, Offset}}
    end.

following(_Info, _Offset, 0, _Count) -> {ok, none};
following(_Info, _Offset, _Next, 0) -> {ok, none};
following(Info, Offset, Next, Count) when Next > Offset -> extensions(Info, Next, Count);
following(_Info, Offset, Next, _Count) -> {error, {pointer, Offset, Next}}.

-doc """
The Performance Enhancement register set as CMD48 read it from its start
(Physical Layer Table 5-30, p.268-269): the revision, byte 0; cache
support, byte 4 bit 0; Cache Enable, byte 260 bit 0; and Flush Cache, byte
261 bit 0. The block must reach byte 261.
""".
-spec performance_enhancement(term()) ->
          {ok, #{revision := 0..255, cache_support := boolean(),
                 cache_enable := boolean(), flush := boolean()}}
              | {error, malformed}.
performance_enhancement(<<Revision, _:3/binary, Support, _:255/binary, Enable, Flush,
                          _/binary>>) ->
    {ok, #{revision => Revision, cache_support => Support band 1 =:= 1,
           cache_enable => Enable band 1 =:= 1, flush => Flush band 1 =:= 1}};
performance_enhancement(_) ->
    {error, malformed}.
