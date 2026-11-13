%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_blk_sd_host).
-moduledoc """
The SD host controller's pure core (docs/design-storage.md, "The SD host
controller"): the decode of the `interrupt` word into a closed set of
events, the SDHCI 3.00 clock divider, and one request's transfer as a state
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
CMD25, which erx_blk_write builds; `{issue, {cmd, 13, Argument}}`;
`read_block`, 128 words from `data`; `{write_block, Index}`, the request's
block Index into `data`; and at the end exactly one of `{answer, ok}`,
`{answer, {error, {device, deadline}}}` for a request that waited past the
wait limit and was never issued, or `{fail, Detail}`, after which the
device process ends. Times are monotonic milliseconds.
""".

-export([decode/1, signalling/1, divider/2, new/1, step/2, phase/1, deadline/1]).
-export([wait_limit_ms/0, in_flight_ms/0]).

-export_type([event/0, interrupt_event/0, transfer/0, request/0, action/0]).

%% The transport contract (docs/design-storage.md, "Data model"): a request
%% is issued only within 10 s of its acceptance, and one issued must be
%% complete 18 s after it was issued.
-define(WAIT_LIMIT_MS, 10000).
-define(IN_FLIGHT_MS, 18000).
%% SDHCI 3.00's largest divisor of the 10-bit divided clock (Host
%% Controller p.68-69; SDHCI_300_MAX_DIVIDER).
-define(MAX_DIVISOR, 2046).
-define(R1_OUT_OF_RANGE, 16#80000000).
-define(SIGNALLING_1V8, 16#00080000).
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
                     rca := 0..16#FFFF, accepted := integer()}.
-type action() :: {issue, transfer | {cmd, 13, 0..16#FFFFFFFF}} | read_block
                | {write_block, non_neg_integer()} | {answer, ok}
                | {answer, {error, {device, deadline}}} | {fail, term()}.
-type phase() :: waiting | command | data | status | done.

%% One request: moved counts the blocks through `data` so far.
-record(transfer, {phase = waiting :: phase(),
                   op :: read | write,
                   count :: pos_integer(),
                   last :: boolean(),
                   rca :: 0..16#FFFF,
                   accepted :: integer(),
                   issued :: undefined | integer(),
                   moved = 0 :: non_neg_integer()}).
-opaque transfer() :: #transfer{}.

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
    Errors = [{error, error_name(Bit)} || Bit <- lists:seq(16, 31), Word band (1 bsl Bit) =/= 0],
    Summary = [{error, error_interrupt} || Errors =:= [], Word band 16#8000 =/= 0],
    Normal = [Event || {Bit, Event} <- [{0, command_complete}, {4, buffer_write_ready},
                                        {5, buffer_read_ready}, {1, transfer_complete}],
                       Word band (1 bsl Bit) =/= 0],
    Errors ++ Summary ++ Normal;
decode(_) ->
    none.

error_name(16) -> command_timeout;
error_name(17) -> command_crc;
error_name(18) -> command_end_bit;
error_name(19) -> command_index;
error_name(20) -> data_timeout;
error_name(21) -> data_crc;
error_name(22) -> data_end_bit;
error_name(23) -> current_limit;
error_name(24) -> auto_cmd;
error_name(25) -> adma;
error_name(26) -> tuning;
error_name(27) -> response;
error_name(Bit) -> {vendor, Bit}.

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
            Half = Divisor div 2,
            {ok, Divisor, ((Half band 16#FF) bsl 8) bor (((Half bsr 8) band 3) bsl 6)};
        [] ->
            {error, too_slow}
    end;
divider(_, _) ->
    {error, bad_clock}.

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
out of range (Physical Layer 4.3.3, p.52).
""".
-spec new(request()) -> transfer().
new(#{op := Op, sector := Sector, count := Count, capacity := Capacity, rca := Rca,
      accepted := Accepted}) ->
    #transfer{op = Op, count = Count, last = Sector + Count =:= Capacity, rca = Rca,
              accepted = Accepted}.

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
            {[{issue, {cmd, 13, T#transfer.rca bsl 16}}], T#transfer{phase = status}};
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
