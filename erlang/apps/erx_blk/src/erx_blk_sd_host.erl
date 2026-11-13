%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_blk_sd_host).
-moduledoc """
The SD host controller's pure core (docs/design-storage.md, "The SD host
controller"): the decode of the `interrupt` word into a closed set of
events, the SDHCI 3.00 clock divider, one identification command's wait
(command/1 and command_step/2), and one request's transfer as a state
machine with the transport contract's deadlines. Nothing here touches a
device; the device process, erx_blk_sd, reads and writes the registers,
performs the actions and hands back the events. Tested and fuzzed on the
host (test/erlang/erx_blk_sd_host_tests.erl and erx_blk_sd_fuzz.erl).

A transfer is new/1 and then step/2. Its events:

* `{start, Now}`, the device process's offer to issue the request;
* `{tick, Now}`, the request's timer;
* `{command_complete, R1}`, with `resp0` read at that event;
* `buffer_read_ready` and `buffer_write_ready`;
* `{transfer_complete, AutoR1}`, with `resp3`, where the controller leaves
  Auto CMD12's R1 (Host Controller p.48), read at that event;
* `{error, Name}`, an error bit of decode/1.

Its actions: `{issue, transfer}`, the request's own CMD17, CMD18, CMD24 or
CMD25, which erx_blk_write builds; `{issue, status}`, CMD13, which
erx_blk_write builds too;
`read_block`, 128 words from `data`; `{write_block, Index}`, the request's
block Index into `data`; and at the end exactly one of `{answer, ok}`,
`{answer, {error, {device, deadline}}}` for a request that waited past the
wait limit and was never issued, or `{fail, Detail}`, after which the
device process ends. Times are monotonic milliseconds.
""".

-export([decode/1, ack_mask/0, enable_mask/0, signalling/1, divider/2]).
-export([inhibited/2, dat0_high/1, base_clock/2, version/1]).
-export([command/1, command_step/2, awaited/1]).
-export([new/1, step/2, phase/1, deadline/1]).
-export([wait_limit_ms/0, in_flight_ms/0]).

-export_type([event/0, interrupt_event/0, transfer/0, request/0, action/0, command/0, command_action/0]).

-include("generated/erx_hw_sdhci.hrl").

%% The transport contract (docs/design-storage.md, "Data model"): a request
%% is issued only within 10 s of its acceptance, and one issued must be
%% complete 18 s after it was issued.
-define(WAIT_LIMIT_MS, 10000).
-define(IN_FLIGHT_MS, 18000).
%% SDHCI 3.00's largest divisor of the 10-bit divided clock (Host
%% Controller p.68-69; SDHCI_300_MAX_DIVIDER).
-define(MAX_DIVISOR, 2046).
-define(SIGNALLING_1V8, ?ERX_HW_SDHCI_CONTROL2_S18_ENABLE_MASK).
%% Card status bits of an R1 response, which the card sends and no register holds.
-define(R1_OUT_OF_RANGE, 16#80000000).
-define(R1_STATE_TRAN, 4).
-define(R1_READY_FOR_DATA, 16#100).
-define(IS_WORD(W), (is_integer(W) andalso W >= 0 andalso W =< 16#FFFFFFFF)).

-type error_name() :: command_timeout | command_crc | command_end_bit | command_index
                    | data_timeout | data_crc | data_end_bit | current_limit
                    | auto_cmd | adma | tuning | response | error_interrupt
                    | {vendor, 28..31}.
-type interrupt_event() :: command_complete | transfer_complete | buffer_write_ready
                         | buffer_read_ready | {error, error_name()}.
-type event() :: {start, integer()} | {tick, integer()}
               | {command_complete, term()} | {transfer_complete, term()}
               | buffer_read_ready | buffer_write_ready | {error, error_name()}.
-type request() :: #{op := read | write, sector := non_neg_integer(),
                     count := pos_integer(), capacity := pos_integer(),
                     accepted := integer()}
                 | #{op := flush, accepted := integer()}.
-type action() :: {issue, transfer | status} | read_block
                | {write_block, non_neg_integer()} | {answer, ok}
                | {answer, {error, {device, deadline}}} | {fail, term()}.
-type phase() :: waiting | command | data | status | done.

%% One request: moved counts the blocks through `data` so far.
-record(transfer, {phase = waiting :: phase(),
                   op :: read | write | flush,
                   count = 0 :: non_neg_integer(),
                   last = false :: boolean(),
                   accepted :: integer(),
                   issued :: undefined | integer(),
                   moved = 0 :: non_neg_integer()}).
-opaque transfer() :: #transfer{}.

%% One identification command's wait (command/1): whether command complete, the response,
%% has come, and what its data track still awaits: none for a command with no data track,
%% [] once its data track is done.
-record(wait, {response = waiting :: waiting | taken,
                  data = none :: none | [interrupt_event()]}).
-opaque command() :: #wait{}.
-type command_action() :: read_response | read_block | write_block.

%%% The interrupt word

-doc """
The `interrupt` word as events, errors first, then command complete, the
buffer events and transfer complete, so a word carrying an error fails the
transfer before anything acts on its data. A word of zero or all ones is
not this controller's, `none` (facts record, "Interrupts"). Normal bits
other than the four the transfer uses (block gap, DMA, card insertion and
removal, card interrupt, INT_A to INT_C, re-tuning, FX event) are not
events: the driver arms no DMA, forces the card present and offers none of
the rest. Bit 15, error interrupt, is an event only when no error bit
says which error it was (Host Controller p.30-35).
""".
-spec decode(term()) -> none | [interrupt_event()].
decode(0) ->
    none;
decode(16#FFFFFFFF) ->
    none;
decode(Word) when ?IS_WORD(Word) ->
    Errors = [{error, Name} || {Mask, Name} <- error_bits(), Word band Mask =/= 0],
    Summary = [{error, error_interrupt} || Errors =:= [], Word band ?ERX_HW_SDHCI_INTERRUPT_ERROR_MASK =/= 0],
    Normal = [Event || {Mask, Event} <- [{?ERX_HW_SDHCI_INTERRUPT_RESPONSE_MASK, command_complete},
                                         {?ERX_HW_SDHCI_INTERRUPT_SPACE_AVAIL_MASK, buffer_write_ready},
                                         {?ERX_HW_SDHCI_INTERRUPT_DATA_AVAIL_MASK, buffer_read_ready},
                                         {?ERX_HW_SDHCI_INTERRUPT_DATA_END_MASK, transfer_complete}],
                       Word band Mask =/= 0],
    Errors ++ Summary ++ Normal;
decode(_) ->
    none.

%% The error bits from the lowest, each with its name: the error fields of
%% INTERRUPT in hw/svd/sdhci/sdhci.svd (Host Controller 2.2.19, p.82-85), the
%% four vendor bits of VENDOR_ERR one by one.
error_bits() ->
    [{?ERX_HW_SDHCI_INTERRUPT_TIMEOUT_MASK, command_timeout},
     {?ERX_HW_SDHCI_INTERRUPT_CRC_MASK, command_crc},
     {?ERX_HW_SDHCI_INTERRUPT_END_BIT_MASK, command_end_bit},
     {?ERX_HW_SDHCI_INTERRUPT_INDEX_MASK, command_index},
     {?ERX_HW_SDHCI_INTERRUPT_DATA_TIMEOUT_MASK, data_timeout},
     {?ERX_HW_SDHCI_INTERRUPT_DATA_CRC_MASK, data_crc},
     {?ERX_HW_SDHCI_INTERRUPT_DATA_END_BIT_MASK, data_end_bit},
     {?ERX_HW_SDHCI_INTERRUPT_BUS_POWER_MASK, current_limit},
     {?ERX_HW_SDHCI_INTERRUPT_ACMD12ERR_MASK, auto_cmd},
     {?ERX_HW_SDHCI_INTERRUPT_ADMAERR_MASK, adma},
     {?ERX_HW_SDHCI_INTERRUPT_TUNEERR_MASK, tuning},
     {?ERX_HW_SDHCI_INTERRUPT_RESP_ERR_MASK, response}
     | [{1 bsl Bit, {vendor, Bit}}
        || Bit <- lists:seq(?ERX_HW_SDHCI_INTERRUPT_VENDOR_ERR_SHIFT,
                            ?ERX_HW_SDHCI_INTERRUPT_VENDOR_ERR_SHIFT + ?ERX_HW_SDHCI_INTERRUPT_VENDOR_ERR_WIDTH - 1)]].

-doc """
The bits of an `interrupt` word the device process writes back to clear
them: every one-to-clear field of INTERRUPT. The rest (card interrupt,
INT_A to INT_C, re-tuning and the error summary) follow their sources and
are read-only, so erx_device:write/3 refuses a word that sets them.
""".
-spec ack_mask() -> 0..16#FFFFFFFF.
ack_mask() ->
    lists:foldl(fun(Mask, Acc) -> Mask bor Acc end, 0, [Mask || {Mask, _Name} <- clear_bits()]).

-doc """
The status and signal enable word, written to both `irpt_mask` and
`irpt_en` at the start, whose fields lie as INTERRUPT's (Host Controller
2.2.20-2.2.23, p.86-93): the enable of every status the device process can
clear, the statuses decode/1 turns into events: command complete, the two
buffer events, transfer complete and every error. Block gap, DMA and card
insertion and removal are cleared when seen but not enabled, since the
driver arms no DMA and forces the card present; a status that follows its
source is never enabled, so no level the driver cannot clear holds the line.
""".
-spec enable_mask() -> 0..16#FFFFFFFF.
enable_mask() ->
    lists:foldl(fun(Mask, Acc) -> Mask bor Acc end, 0,
                [?ERX_HW_SDHCI_IRPT_MASK_RESPONSE_MASK, ?ERX_HW_SDHCI_IRPT_MASK_DATA_END_MASK,
                 ?ERX_HW_SDHCI_IRPT_MASK_SPACE_AVAIL_MASK, ?ERX_HW_SDHCI_IRPT_MASK_DATA_AVAIL_MASK,
                 ?ERX_HW_SDHCI_IRPT_MASK_TIMEOUT_MASK, ?ERX_HW_SDHCI_IRPT_MASK_CRC_MASK,
                 ?ERX_HW_SDHCI_IRPT_MASK_END_BIT_MASK, ?ERX_HW_SDHCI_IRPT_MASK_INDEX_MASK,
                 ?ERX_HW_SDHCI_IRPT_MASK_DATA_TIMEOUT_MASK, ?ERX_HW_SDHCI_IRPT_MASK_DATA_CRC_MASK,
                 ?ERX_HW_SDHCI_IRPT_MASK_DATA_END_BIT_MASK, ?ERX_HW_SDHCI_IRPT_MASK_BUS_POWER_MASK,
                 ?ERX_HW_SDHCI_IRPT_MASK_ACMD12ERR_MASK, ?ERX_HW_SDHCI_IRPT_MASK_ADMAERR_MASK,
                 ?ERX_HW_SDHCI_IRPT_MASK_TUNEERR_MASK, ?ERX_HW_SDHCI_IRPT_MASK_RESP_ERR_MASK,
                 ?ERX_HW_SDHCI_IRPT_MASK_VENDOR_ERR_MASK]).

%% INTERRUPT's one-to-clear fields: the normal ones, then error_bits/0's.
clear_bits() ->
    [{?ERX_HW_SDHCI_INTERRUPT_RESPONSE_MASK, command_complete},
     {?ERX_HW_SDHCI_INTERRUPT_DATA_END_MASK, transfer_complete},
     {?ERX_HW_SDHCI_INTERRUPT_BLOCK_GAP_MASK, block_gap},
     {?ERX_HW_SDHCI_INTERRUPT_DMA_END_MASK, dma},
     {?ERX_HW_SDHCI_INTERRUPT_SPACE_AVAIL_MASK, buffer_write_ready},
     {?ERX_HW_SDHCI_INTERRUPT_DATA_AVAIL_MASK, buffer_read_ready},
     {?ERX_HW_SDHCI_INTERRUPT_CARD_INSERT_MASK, card_insert},
     {?ERX_HW_SDHCI_INTERRUPT_CARD_REMOVE_MASK, card_remove}
     | error_bits()].

%%% Register values the start and the issue decide on

-doc """
Whether `present` says the next command cannot issue: command inhibit, or
for a command that uses the data lines or answers with busy, data inhibit
as well (SDHCI_CMD_INHIBIT, SDHCI_DAT_INHIBIT, sdhci.h:148-149). A value
that is not a word is inhibited, so it never lets a command through.
""".
-spec inhibited(term(), boolean()) -> boolean().
inhibited(Present, UsesDat) when ?IS_WORD(Present) ->
    Dat = case UsesDat of
              true -> ?ERX_HW_SDHCI_PRESENT_DAT_INHIBIT_MASK;
              false -> 0
          end,
    Present band (?ERX_HW_SDHCI_PRESENT_CMD_INHIBIT_MASK bor Dat) =/= 0;
inhibited(_Present, _UsesDat) ->
    true.

-doc """
Whether `present` reads DAT0 high, the end of a card's busy (Host
Controller p.53-57): DAT_LEVEL's lowest bit.
""".
-spec dat0_high(term()) -> boolean().
dat0_high(Present) when ?IS_WORD(Present) ->
    ?ERX_HW_SDHCI_PRESENT_DAT_LEVEL_GET(Present) band 1 =:= 1;
dat0_high(_Present) ->
    false.

-doc """
The controller's base clock in Hz from `capabilities` (BASE_CLOCK, MHz,
sdhci.h:278), or the platform's `clock` when the field is zero (Host
Controller p.110); a zero field and no clock is refused, never guessed.
""".
-spec base_clock(term(), non_neg_integer() | undefined) -> {ok, pos_integer()} | {error, no_base_clock}.
base_clock(Capabilities, Platform) when ?IS_WORD(Capabilities) ->
    case ?ERX_HW_SDHCI_CAPABILITIES_BASE_CLOCK_GET(Capabilities) of
        0 when is_integer(Platform), Platform > 0 -> {ok, Platform};
        0 -> {error, no_base_clock};
        Mhz -> {ok, Mhz * 1000000}
    end;
base_clock(_Capabilities, _Platform) ->
    {error, no_base_clock}.

-doc """
The start's refusal of a controller older than version 3.00, from
`slotisr_ver`'s SPEC_VER: 2 is version 3.00, each later version one more
(sdhci.h:335; Host Controller 2.3.16, p.138).
""".
-spec version(term()) -> ok | {error, {version, non_neg_integer() | malformed}}.
version(SlotIsrVer) when ?IS_WORD(SlotIsrVer) ->
    case ?ERX_HW_SDHCI_SLOTISR_VER_SPEC_VER_GET(SlotIsrVer) of
        Spec when Spec >= ?ERX_HW_SDHCI_SLOTISR_VER_SPEC_VER_V300 -> ok;
        Spec -> {error, {version, Spec}}
    end;
version(_SlotIsrVer) ->
    {error, {version, malformed}}.

%%% Signalling

-doc """
The start's refusal of a card switched to 1.8 V: the `control2` word, read
before the reset for all clears it, holds host control 2 in its upper half,
whose bit 3 is the 1.8 V signalling enable (Host Controller p.53, p.96), so
word bit 19. Only a power cycle returns such a card to 3.3 V, which the
driver cannot do.
""".
-spec signalling(term()) -> ok | {error, needs_power_cycle | malformed}.
signalling(Control2) when ?IS_WORD(Control2), Control2 band ?SIGNALLING_1V8 =/= 0 ->
    {error, needs_power_cycle};
signalling(Control2) when ?IS_WORD(Control2) ->
    ok;
signalling(_) ->
    {error, malformed}.

%%% The clock

-doc """
SDHCI 3.00's 10-bit divided clock for a base clock and a target, both in
Hz: the base itself when the target is at least the base, otherwise the
smallest even divisor up to 2046 whose quotient is at most the target. The
result is the divisor and the clock control bits that select it: half the
divisor, its low 8 bits in bits 15-8 and its high 2 bits in bits 7-6
(sdhci.c:463-484; sdhci.h:186-190; Host Controller p.68-69). A target no
divisor reaches is refused rather than exceeded.
""".
-spec divider(term(), term()) -> {ok, pos_integer(), 0..16#FFC0}
                                     | {error, bad_clock | too_slow}.
divider(Base, Target) when is_integer(Base), Base > 0, is_integer(Target), Target >= Base ->
    {ok, 1, 0};
divider(Base, Target) when is_integer(Base), Base > 0, is_integer(Target), Target > 0 ->
    %% Base / Divisor is at most Target exactly when Base =< Target * Divisor.
    case [D || D <- lists:seq(2, ?MAX_DIVISOR, 2), Base =< Target * D] of
        [Divisor | _] ->
            %% CONTROL1's DIVIDER takes half the divisor's low bits, DIVIDER_HI the rest.
            Half = Divisor div 2,
            Low = Half band ((1 bsl ?ERX_HW_SDHCI_CONTROL1_DIVIDER_WIDTH) - 1),
            High = Half bsr ?ERX_HW_SDHCI_CONTROL1_DIVIDER_WIDTH,
            {ok, Divisor, ?ERX_HW_SDHCI_CONTROL1_DIVIDER_PUT(Low) bor ?ERX_HW_SDHCI_CONTROL1_DIVIDER_HI_PUT(High)};
        [] ->
            {error, too_slow}
    end;
divider(_, _) ->
    {error, bad_clock}.

%%% One identification command

-doc """
The wait for one identification command, from its plan's shape
(erx_blk_write:sd_shape/1). It has two tracks, as FreeBSD keeps cmd_done and
data_done (sdhci.c:1878, 1921-1923, 2047, 2057-2059). The command track is
command complete, which every command raises. The data track is transfer
complete for a busy response (R1b); the buffer event and then transfer
complete for a data block; and there is none for any other command. The
tracks advance independently, since a controller may raise transfer
complete before command complete (sdhci.c:2026-2033), and the command is
answered once both are empty.
""".
-spec command(#{response := none | r1 | r1b | r2 | r3,
                data := none | {read | write, pos_integer(), 1}}) -> command().
command(#{response := Response, data := Data}) ->
    #wait{data = data_track(Response, Data)}.

data_track(_Response, {read, _Size, 1}) -> [buffer_read_ready, transfer_complete];
data_track(_Response, {write, _Size, 1}) -> [buffer_write_ready, transfer_complete];
data_track(r1b, none) -> [transfer_complete];
data_track(_Response, none) -> none.

-doc """
One `interrupt` word's events, as decode/1 gives them, taken by the command:
`{continue, Actions, Command}` while a track still waits, `{done, Actions}`
once both are empty, or `{fail, Event}` with the event erx_blk_sd_card takes:
`timeout` for a command timeout alone, `{error, {interrupt, Names}}` for any
other error bits, and `{error, {unexpected, Awaited, Got}}` for an event of
a track the command has that is not that track's next. Error bits fail the
word before any of its other events acts. An event of a track the command
does not have is not this command's and is ignored, as FreeBSD ignores a
data interrupt for a command with neither data nor busy (sdhci.c:2242-2249);
a buffer event of a busy command is not ignored, as FreeBSD's is not
(sdhci.c:2254-2260). The actions, in the order the device process performs
them: `read_response` at command complete, `read_block` at buffer read
ready and `write_block` at buffer write ready.
""".
-spec command_step(command(), [interrupt_event()]) ->
          {continue, [command_action()], command()} | {done, [command_action()]}
          | {fail, timeout | {error, term()}}.
command_step(#wait{} = W, Events) when is_list(Events) ->
    case [Name || {error, Name} <- Events] of
        [] -> take(Events, W, []);
        [command_timeout] -> {fail, timeout};
        Names -> {fail, {error, {interrupt, Names}}}
    end.

-doc "The events the command still awaits, in each track's order, which a missed deadline names.".
-spec awaited(command()) -> [interrupt_event()].
awaited(#wait{response = Response, data = Data}) ->
    [command_complete || Response =:= waiting] ++ [Event || is_list(Data), Event <- Data].

%% The clauses' order is the rule: command complete on its track, the data track's next
%% event, a data event of a command with no data track ignored, anything else a failure.
take([], #wait{response = taken, data = Data}, Actions) when Data =:= []; Data =:= none ->
    {done, lists:reverse(Actions)};
take([], W, Actions) ->
    {continue, lists:reverse(Actions), W};
take([command_complete | Rest], #wait{response = waiting} = W, Actions) ->
    take(Rest, W#wait{response = taken}, [read_response | Actions]);
take([Event | Rest], #wait{data = [Event | Track]} = W, Actions) ->
    take(Rest, W#wait{data = Track}, data_action(Event) ++ Actions);
take([Event | Rest], #wait{data = none} = W, Actions) when Event =/= command_complete ->
    take(Rest, W, Actions);
take([Event | _Rest], W, _Actions) ->
    {fail, {error, {unexpected, awaited(W), event_name(Event)}}}.

data_action(buffer_read_ready) -> [read_block];
data_action(buffer_write_ready) -> [write_block];
data_action(transfer_complete) -> [].

%%% The transfer

-doc "The wait limit, from acceptance to issue, in milliseconds.".
-spec wait_limit_ms() -> pos_integer().
wait_limit_ms() -> ?WAIT_LIMIT_MS.

-doc "The in-flight bound, from issue to completion, in milliseconds.".
-spec in_flight_ms() -> pos_integer().
in_flight_ms() -> ?IN_FLIGHT_MS.

-doc """
A request accepted at `accepted`, not yet issued. last records whether it
ends at the card's last sector, which only a multi-block read may report as
out of range (Physical Layer 4.3.3, p.52). A flush moves no block: it is
CMD13 alone, issued as the status phase.
""".
-spec new(request()) -> transfer().
new(#{op := flush, accepted := Accepted}) ->
    #transfer{op = flush, accepted = Accepted};
new(#{op := Op, sector := Sector, count := Count, capacity := Capacity,
      accepted := Accepted}) when Op =:= read; Op =:= write ->
    #transfer{op = Op, count = Count, last = Sector + Count =:= Capacity, accepted = Accepted}.

-doc """
When the request's one timer must next fire: its wait limit while it
waits, its in-flight bound once issued, none once it is finished. The
device process arms the timer after every step and hands back
`{tick, Now}` when it fires.
""".
-spec deadline(transfer()) -> integer() | none.
deadline(#transfer{phase = waiting, accepted = Accepted}) -> Accepted + ?WAIT_LIMIT_MS;
deadline(#transfer{phase = done}) -> none;
deadline(#transfer{issued = Issued}) -> Issued + ?IN_FLIGHT_MS.

-doc "The phase a transfer is in, which a failure's log line names.".
-spec phase(transfer()) -> phase().
phase(#transfer{phase = Phase}) -> Phase.

-doc """
One transition of the transfer. An event in a finished transfer, or any
event but start and tick before it is issued, is no request's and gives no
action, as the design drops an event with no request in flight.
""".
%% Any term is taken; one that is not an event() fails an issued transfer.
-spec step(transfer(), term()) -> {[action()], transfer()}.
step(#transfer{phase = done} = T, _Event) ->
    {[], T};
step(#transfer{phase = waiting, accepted = Accepted} = T, {Offer, Now})
  when (Offer =:= start orelse Offer =:= tick), is_integer(Now),
       Now - Accepted >= ?WAIT_LIMIT_MS ->
    finish(T, {answer, {error, {device, deadline}}});
step(#transfer{phase = waiting, op = flush} = T, {start, Now}) when is_integer(Now) ->
    {[{issue, status}], T#transfer{phase = status, issued = Now}};
step(#transfer{phase = waiting} = T, {start, Now}) when is_integer(Now) ->
    {[{issue, transfer}], T#transfer{phase = command, issued = Now}};
step(#transfer{phase = waiting} = T, _Event) ->
    {[], T};
step(#transfer{issued = Issued} = T, {tick, Now}) when is_integer(Now) ->
    case Now - Issued >= ?IN_FLIGHT_MS of
        true -> finish(T, {fail, in_flight_bound});
        false -> {[], T}
    end;
step(T, {error, Name}) ->
    finish(T, {fail, {interrupt, Name}});
step(T, Event) ->
    issued(T, Event).

%% The issued phases: the command's R1, the blocks, transfer complete with
%% Auto CMD12's R1, and after a write CMD13's R1.
issued(#transfer{phase = command} = T, {command_complete, R1}) ->
    case r1_errors(R1) of
        0 -> {[], T#transfer{phase = data}};
        _ -> finish(T, {fail, {r1, word(R1)}})
    end;
issued(#transfer{phase = data, op = read, moved = Moved, count = Count} = T, buffer_read_ready)
  when Moved < Count ->
    {[read_block], T#transfer{moved = Moved + 1}};
issued(#transfer{phase = data, op = write, moved = Moved, count = Count} = T, buffer_write_ready)
  when Moved < Count ->
    {[{write_block, Moved}], T#transfer{moved = Moved + 1}};
issued(#transfer{phase = data, moved = Count, count = Count} = T, {transfer_complete, AutoR1}) ->
    case auto_cmd12_errors(T, AutoR1) of
        0 when T#transfer.op =:= read ->
            finish(T, {answer, ok});
        0 ->
            {[{issue, status}], T#transfer{phase = status}};
        _ ->
            finish(T, {fail, {auto_cmd12, word(AutoR1)}})
    end;
issued(#transfer{phase = status} = T, {command_complete, R1}) ->
    case ready(R1) of
        true -> finish(T, {answer, ok});
        false -> finish(T, {fail, {not_ready, word(R1)}})
    end;
issued(#transfer{phase = Phase} = T, Event) ->
    finish(T, {fail, {unexpected, Phase, event_name(Event)}}).

%% Auto CMD12 ends only a transfer of more than one block; on a CMD18 that
%% ends at the card's last sector its out of range alone is not an error.
auto_cmd12_errors(#transfer{count = 1}, _AutoR1) ->
    0;
auto_cmd12_errors(#transfer{op = read, last = true}, AutoR1) ->
    without_out_of_range(r1_errors(AutoR1));
auto_cmd12_errors(#transfer{}, AutoR1) ->
    r1_errors(AutoR1).

%% A write is done when CMD13 finds no error, the transfer state and ready
%% for data (mmcreg.h:145, 155; Physical Layer p.54).
ready(R1) ->
    r1_errors(R1) =:= 0 andalso (R1 bsr 9) band 15 =:= ?R1_STATE_TRAN
        andalso R1 band ?R1_READY_FOR_DATA =/= 0.

%% An R1's error bits, or malformed, which is never 0 and so never passes.
r1_errors(R1) ->
    case erx_blk_sd_card:r1_errors(R1) of
        {ok, Errors} -> Errors;
        {error, malformed} -> malformed
    end.

without_out_of_range(malformed) -> malformed;
without_out_of_range(Errors) -> Errors band bnot ?R1_OUT_OF_RANGE.

word(W) when ?IS_WORD(W) -> W;
word(_) -> malformed.

event_name(Event) when is_atom(Event) -> Event;
event_name(Event) when is_tuple(Event), tuple_size(Event) > 0, is_atom(element(1, Event)) ->
    element(1, Event);
event_name(_) -> other.

finish(T, Action) ->
    {[Action], T#transfer{phase = done}}.
