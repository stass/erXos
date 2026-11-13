%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_blk_sd_card_model).
-moduledoc """
A reference SD memory card for the host tests of erx_blk_sd_card, written
from the Physical Layer Simplified Specification 9.10, not from the driver:
the card states of Figure 4-1 (p.42) and Figure 4-13, the responses of
4.9 (p.126-129), the registers of chapter 5 built bit by bit from their
tables, and the extension registers of 5.7 and Table 5-30. It answers each
step the driver issues as the controller would hand it to the device
process: `{response, ...}`, `{data, R1, Bytes}` or `timeout`.

A card is a map of parameters (card/1 lists them with their defaults) and
the model's own state. A command the card would not take in its state is
answered as a card answers it, with no response and, for an illegal one,
the illegal-command bit in the next R1 (4.6.1, p.95), and is recorded in
`violations`, which a run on a good card must leave empty.
""".

-export([card/1, command/2, violations/1, trace/1]).
-export([csd_v1/3, csd_v2/1, r2_words/1, scr/2, sd_status/1, general_information/1,
         pe_offset/0]).

-define(ILLEGAL, 16#00400000).
-define(LOCKED, 16#02000000).
-define(APP_CMD, 16#20).
-define(READY_FOR_DATA, 16#100).
-define(OCR_READY, 16#80000000).
-define(OCR_CCS, 16#40000000).

-doc """
A card from parameters over these defaults: a version 2.00 or later card
(`version => 1` does not know CMD8), high capacity, the full 2.7-3.6 V
window, ready on the fourth ACMD41, a 4 GiB CSD, a 4-bit SCR without
extension registers, no cache in its SD status, and a General Information
naming the Performance Enhancement function at function 2.
""".
card(Params) ->
    Defaults = #{version => 2, hc => true, window => 16#FF8000, busy => 3,
                 rca => 16#B368, cid => 16#0353445345433136478012345678015D00,
                 csd => csd_v2(8191), locked => false,
                 scr => scr(5, false), status => sd_status(false),
                 gi => general_information([{1, []}, {2, [{2, 0}]}]),
                 pe_fno => 2, pe_start => 0, cache_on => false, flush_reads => 2,
                 disable_sticks => false, second_cmd8 => same},
    maps:merge(maps:merge(Defaults, Params),
               #{state => idle, app => false, pending => 0, hcs => false, acmd41 => 0,
                 cmd8s => 0, bus => 1, flush => 0, violations => [], trace => []}).

violations(#{violations := V}) -> lists:reverse(V).
trace(#{trace := T}) -> lists:reverse(T).

-doc "The card's answer to one step, and the card after it.".
command(Step, #{trace := T} = Card) ->
    answer(Step, Card#{trace := [index(Step) | T]}).

index({Kind, Index, _}) -> {Kind, Index};
index({Kind, Index, _, _}) -> {Kind, Index}.

%% CMD0 returns every state but inactive to idle (p.41).
answer({cmd, 0, 0}, #{state := inactive} = C) ->
    {timeout, C};
answer({cmd, 0, 0}, C) ->
    {{response, none}, C#{state := idle, app := false, hcs := false, acmd41 := 0}};
%% CMD8 (4.3.13, p.90): a version 1.x card does not know it; a later card
%% echoes the argument when it takes the supply, else does not answer.
answer({cmd, 8, Arg}, #{state := idle, version := 1} = C) ->
    illegal({cmd, 8, Arg}, C, false);
answer({cmd, 8, Arg}, #{state := idle, cmd8s := N, second_cmd8 := Second} = C) ->
    C1 = C#{cmd8s := N + 1},
    Echo = (Arg bsr 8) band 15 =:= 1 andalso Arg band 255 =:= 16#AA,
    case {N, Second, Echo} of
        {1, flip, _} -> {timeout, C1};
        {_, _, true} -> {{response, Arg band 16#FFF}, C1};
        {_, _, false} -> {timeout, C1}
    end;
%% CMD55 to the card's address, or to address 0 before it has one.
answer({cmd, 55, Arg}, #{state := State} = C) when State =:= idle; State =:= ready ->
    addressed(Arg, 0, C, fun(C1) -> r1(C1#{app := true}, idle) end);
answer({cmd, 55, Arg}, #{state := State, rca := Rca} = C) when State =:= stby; State =:= tran ->
    addressed(Arg, Rca bsl 16, C, fun(C1) -> r1(C1#{app := true}, State) end);
%% ACMD41 (4.2.3.1, p.45): argument 0 asks the window; otherwise a card
%% whose window meets the argument's initialises, busy until ready, and a
%% high-capacity card stays busy unless the host offers HCS.
answer({acmd, 41, Arg}, #{state := idle, app := true, window := Window} = C) ->
    C1 = C#{app := false},
    case Arg band 16#FFFFFF of
        0 ->
            {{response, Window}, C1};
        Offered when Offered band Window =:= 0 ->
            {timeout, violation({acmd41_window, Arg}, C1#{state := inactive})};
        _ ->
            initialise(Arg, C1)
    end;
answer({cmd, 2, 0}, #{state := ready, cid := Cid} = C) ->
    {{response, r2_words(Cid)}, C#{state := ident}};
%% CMD3's R6 (4.9.5, p.128): status bits 23, 22, 19 and 12-0.
answer({cmd, 3, 0}, #{state := State, rca := Rca} = C) when State =:= ident; State =:= stby ->
    Status = status(C, State),
    Low = ((Status bsr 8) band 16#C000) bor ((Status bsr 6) band 16#2000) bor (Status band 16#1FFF),
    {{response, (Rca bsl 16) bor Low}, C#{state := stby, pending := 0}};
answer({cmd, 9, Arg}, #{state := stby, rca := Rca, csd := Csd} = C) ->
    addressed(Arg, Rca bsl 16, C, fun(C1) -> {{response, r2_words(Csd)}, C1} end);
answer({cmd, 7, Arg}, #{state := stby, rca := Rca} = C) ->
    addressed(Arg, Rca bsl 16, C, fun(C1) -> r1(C1#{state := tran}, stby) end);
%% CMD16 sets SDSC's block length; a high-capacity card's is fixed, and the
%% design issues it only on standard capacity.
answer({cmd, 16, 512}, #{state := tran, hc := Hc} = C) ->
    C1 = case Hc of
             true -> violation(cmd16_on_high_capacity, C);
             false -> C
         end,
    r1(C1, tran);
answer({acmd, 51, 0, {read, 8}}, #{state := tran, app := true, scr := Scr} = C) ->
    data(C#{app := false}, Scr);
answer({acmd, 6, 2}, #{state := tran, app := true} = C) ->
    r1(C#{app := false, bus := 4}, tran);
answer({acmd, 13, 0, {read, 64}}, #{state := tran, app := true, bus := Bus, status := Status} = C) ->
    C1 = case Bus of
             4 -> C;
             _ -> violation(sd_status_before_bus, C)
         end,
    data(C1#{app := false}, Status);
answer({cmd, 48, Arg, {read, 512}}, #{state := tran} = C) ->
    extension(Arg, C, fun(C1) -> read_extension(Arg, C1) end);
answer({cmd, 49, Arg, {write, Block}}, #{state := tran} = C) when byte_size(Block) =:= 512 ->
    extension(Arg, C, fun(C1) -> write_extension(Arg, Block, C1) end);
answer(Step, C) ->
    illegal(Step, C, true).

initialise(Arg, #{acmd41 := N, busy := Busy, hc := Hc, window := Window, version := Version} = C) ->
    Hcs = Arg band ?OCR_CCS =/= 0,
    C1 = C#{acmd41 := N + 1, hcs := Hcs},
    Ready = N >= Busy andalso (not Hc orelse Hcs) andalso (Version =:= 2 orelse not Hc),
    case Ready of
        true ->
            Ccs = case Hc of true -> ?OCR_CCS; false -> 0 end,
            {{response, ?OCR_READY bor Ccs bor Window}, C1#{state := ready}};
        false ->
            {{response, Window}, C1}
    end.

%% A command for another address is not answered (4.3.1).
addressed(Arg, Arg, C, Next) -> Next(C);
addressed(Arg, _, C, _) -> {timeout, violation({wrong_address, Arg}, C)}.

%% Extension register access needs SCR bit 34 (Table 5-23, p.245).
extension(Arg, #{scr := <<_:3/binary, _:5, 1:1, _:2, _/binary>>} = C, Next) ->
    case Arg bsr 31 of
        0 -> Next(C);
        1 -> illegal({mio, Arg}, C, true)
    end;
extension(Arg, C, _Next) ->
    illegal({cmd, 48, Arg}, C, true).

read_extension(Arg, #{gi := Gi, pe_fno := PeFno, pe_start := Start} = C) ->
    {Fno, Address, Length} = extension_fields(Arg),
    case Fno of
        0 ->
            Page = pad(binary:part(pad(Gi, 1024), Address, Length)),
            data(C, Page);
        PeFno when Address >= Start, Address - Start + Length =< 512 ->
            {Register, C1} = pe_register(C),
            data(C1, pad(binary:part(Register, Address - Start, Length)));
        _ ->
            {timeout, violation({read_extension, Arg}, C)}
    end.

%% Cache Enable and Flush Cache are bit 0 of bytes 260 and 261 (Table 5-30);
%% a flush reads as running for flush_reads reads and then clears.
pe_register(#{cache_on := On, flush := Flush} = C) ->
    Register = <<0, 0, 0, 0, 1, 0:255/unit:8, (bit(On)), (bit(Flush > 0)), 0:250/unit:8>>,
    {Register, C#{flush := max(0, Flush - 1)}}.

write_extension(Arg, <<Value, _/binary>>, #{pe_fno := Fno, pe_start := Start,
                                            flush_reads := Reads, disable_sticks := Sticks} = C) ->
    case {extension_fields(Arg), Arg band (1 bsl 26)} of
        {{Fno, Address, 1}, 0} when Address =:= Start + 261, Value band 1 =:= 1 ->
            r1(C#{flush := Reads}, tran);
        {{Fno, Address, 1}, 0} when Address =:= Start + 260 ->
            r1(C#{cache_on := Sticks orelse Value band 1 =:= 1}, tran);
        _ ->
            {timeout, violation({write_extension, Arg}, C)}
    end.

extension_fields(Arg) ->
    {(Arg bsr 27) band 15, (Arg bsr 9) band 16#1FFFF, (Arg band 511) + 1}.

%% A command the card does not take: no response, and if illegal, the bit in
%% the next R1.
illegal(Step, #{pending := P} = C, Record) ->
    C1 = C#{pending := P bor ?ILLEGAL, app := false},
    case Record of
        true -> {timeout, violation({illegal, Step}, C1)};
        false -> {timeout, C1}
    end.

violation(What, #{violations := V} = C) -> C#{violations := [What | V]}.

%% An R1 shows the state the card was in when it took the command.
r1(C, State) ->
    {{response, status(C, State)}, C#{pending := 0}}.

data(C, Bytes) ->
    {{response, R1}, C1} = r1(C, tran),
    {{data, R1, Bytes}, C1}.

status(#{pending := Pending, app := App, locked := Locked}, State) ->
    (state_code(State) bsl 9) bor Pending
        bor (case App of true -> ?APP_CMD; false -> 0 end)
        bor (case Locked of true -> ?LOCKED; false -> 0 end)
        bor (case State of tran -> ?READY_FOR_DATA; _ -> 0 end).

state_code(idle) -> 0;
state_code(ready) -> 1;
state_code(ident) -> 2;
state_code(stby) -> 3;
state_code(tran) -> 4.

bit(true) -> 1;
bit(false) -> 0.

pad(B) -> pad(B, 512).

pad(B, Size) when byte_size(B) >= Size -> B;
pad(B, Size) -> <<B/binary, 0:((Size - byte_size(B)) * 8)>>.

%%% Registers, built field by field from their tables

-doc """
A structure 0 CSD (Table 5-4, p.226) as 128 bits, CRC byte zero: TAAC,
NSAC, TRAN_SPEED and CCC typical, READ_BL_LEN, C_SIZE and C_SIZE_MULT as
given, WRITE_BL_LEN equal to READ_BL_LEN.
""".
csd_v1(ReadBlLen, CSize, Mult) ->
    <<V:128>> = <<0:2, 0:6, 16#26, 0, 16#32, 16#5B5:12, ReadBlLen:4, 0:6, CSize:12,
                  16#3F:12, Mult:3, 1:1, 16#7F:7, 0:7, 0:1, 0:2, 2:3, ReadBlLen:4, 0:1,
                  0:5, 0:1, 0:1, 0:1, 0:1, 0:2, 0:2, 0:7, 1:1>>,
    V.

-doc "A structure 1 CSD (Table 5-16, p.233) with the given C_SIZE.".
csd_v2(CSize) ->
    <<V:128>> = <<1:2, 0:6, 16#0E, 0, 16#32, 16#5B5:12, 9:4, 0:6, 0:4, CSize:22, 0:1,
                  1:1, 16#7F:7, 0:7, 0:1, 0:2, 2:3, 9:4, 0:1, 0:5, 0:4, 0:2, 0:2, 0:7, 1:1>>,
    V.

-doc """
The four response words the controller stores for an R2: the response's
bits 127 to 8 in their bits 119 to 0 (Host Controller 2.2.7, p.48).
""".
r2_words(Value) ->
    Stored = Value bsr 8,
    [(Stored bsr Shift) band 16#FFFFFFFF || Shift <- [0, 32, 64, 96]].

-doc """
An SCR (Table 5-17, p.240): structure 0, SD_SPEC 2 and SD_SPEC3, the given
SD_BUS_WIDTHS, and CMD48/CMD49 support (SCR bit 34) as given.
""".
scr(BusWidths, Extension) ->
    <<0:4, 2:4, 0:1, 3:3, BusWidths:4, 1:1, 0:4, 0:1, 0:4, 0:1, 0:2, (bit(Extension)):1, 0:2, 0:32>>.

-doc "A 64-byte SD status (Table 4.10.2-1, p.130) on a 4-bit bus, with bit 330 as given.".
sd_status(Cache) ->
    <<2:2, 0:179, (bit(Cache)):1, 0:330>>.

-doc """
A General Information (Figure 5-15, p.257) of the given extensions, each
`{StandardFunctionCode, [{Fno, StartAddress}]}`, laid out one after another
from byte 16 with each pointer to the next and the last pointer 0.
""".
general_information(Extensions) ->
    Sizes = [44 + 4 * length(Sets) || {_, Sets} <- Extensions],
    Ends = lists:foldl(fun(Size, [Last | _] = Acc) -> [Last + Size | Acc] end, [16], Sizes),
    Starts = lists:reverse(tl(Ends)),
    Nexts = tl(Starts) ++ [0],
    Body = << <<(gi_extension(Sfc, Sets, Next))/binary>>
              || {{Sfc, Sets}, Next} <- lists:zip(Extensions, Nexts) >>,
    Length = 16 + byte_size(Body),
    <<0:16, Length:16/little, (length(Extensions)), 0:88, Body/binary>>.

gi_extension(Sfc, Sets, Next) ->
    Addresses = << <<((Fno bsl 18) bor Start):32/little>> || {Fno, Start} <- Sets >>,
    <<Sfc:16/little, 0:16, 0:16, 0:128, 0:16, 0:128, Next:16/little, (length(Sets)), 0,
      Addresses/binary>>.

-doc "Where Cache Enable sits in the Performance Enhancement register set.".
pe_offset() -> 260.
