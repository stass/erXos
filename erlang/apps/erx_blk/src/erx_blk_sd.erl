%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_blk_sd).
-moduledoc """
The block driver's SD host controller transport (docs/design-storage.md,
"The SD host controller"): the device process erx_blk starts for a block
record whose peripheral is sdhci, registered as erx_blk, under erx_blk_sup
in the storage domain, over erx_device. It drives one SD memory card by
programmed I/O at default speed and answers the transport contract's calls
(erx_blk).

It is the effect layer around three pure cores: erx_blk_sd_card, the card's
identification; erx_blk_sd_host, the `interrupt` word's decode, the divider
and one request's transfer; and erx_blk_write's SD plans, the only builders
of the commands it issues and of the blocks it writes to `data`. Every
register write but `data`'s goes through erx_blk_sd_regs, 6 us apart.

**The start** (init/1) is the design's start sequence, run whole on every
start: the record opened and its line attached; a controller left at 1.8 V
refused; DAT0 awaited; the reset for all; the version and base clock; power,
the card-detect test bits, the 400 kHz clock and the interrupt enables; then
the card's identification, each step's command issued through
erx_blk_write and its answer awaited on the line within 1 s. Each
`interrupt` word goes whole to the command in flight, whose wait
(erx_blk_sd_host:command/1) takes command complete and the data track in
either order and ignores what is not its own. Any refusal is one line in the
log and no process: init/1 returns ignore, so a missing or refused card
ends nothing and is not restarted.

**Requests** run one at a time, in arrival order, each as an
erx_blk_sd_host transfer with one timer at the transfer's deadline; at most
64 wait behind it, and more are answered busy. A request the plan builders
refuse (out_of_range, bad_count) is answered before the device is touched.
Any failure the transfer reports answers the request in flight and every
waiting one `{error, {device, Detail}}`, writes one line and ends the
process; erx_blk_sup restarts nothing, so the storage domain's restart runs
the start sequence again (design, "Failure").

**An interrupt** is read once from `interrupt`: a word of zero or all ones
is not this controller's and the line is answered done; otherwise its
one-to-clear bits are written back, the line is answered and the word's
events go to the start's command or to the transfer in flight, and are
dropped when no request is in flight.
""".

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("generated/erx_hw_sdhci.hrl").

-define(IRQ_LINE, 0).
-define(MAX_WAITING, 64).
%% The start's bounds (design, "The start sequence" and "Deadlines and
%% interrupts"): each command and its data 1 s, DAT0's release 1 s, a reset
%% 100 ms, the internal clock 150 ms (Host Controller 3.2.1, p.153-154).
-define(STEP_MS, 1000).
-define(DAT0_MS, 1000).
-define(RESET_MS, 100).
-define(CLOCK_STABLE_MS, 150).
-define(POWER_WAIT_MS, 1).
-define(CLOCK_WAIT_MS, 2).
-define(IDENTIFICATION_HZ, 400000).
%% The BCM2711's floor on the card clock (facts record, "Quirks of the
%% BCM2711 integration").
-define(CLOCK_FLOOR_HZ, 200000).
-define(BLOCK_WORDS, 128).
-define(DEPTH, 12).

%% A request: who asked, what, its plan and when it was accepted.
-record(job, {from :: gen_server:from(), op :: read | write | flush, sector = 0 :: non_neg_integer(),
              plan :: erx_blk_write:sd_plan(), accepted :: integer()}).

%% dev, irq, card, base and clock are fixed once init/1 returns; regs carries the last
%% spaced write's time; current is the request in flight with its transfer, the blocks
%% read so far and its timer.
-record(state, {dev :: erx_device:device(), regs :: erx_blk_sd_regs:regs(), irq :: erx_irq_line:handle(),
                base = 0 :: non_neg_integer(), clock = 0 :: non_neg_integer(),
                card :: undefined | erx_blk_sd_card:card(),
                current = none :: none | {#job{}, erx_blk_sd_host:transfer(), [binary()], reference() | none},
                waiting = queue:new() :: queue:queue(#job{})}).

-doc "The device process of the SD block record Spec, registered as erx_blk.".
-spec start_link(erx_device_record:spec()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Spec) ->
    gen_server:start_link({local, erx_blk}, ?MODULE, Spec, []).

%%% The start

%% Any exception of the sequence is one line and no process as well, as erx_blk_virtio's:
%% the application is permanent, so a raise here would end the boot.
init(Spec) ->
    case try start(Spec) catch Class:Raised -> {error, {Class, Raised}} end of
        {ok, State} ->
            #{addressing := Addressing, sectors := Sectors} = State#state.card,
            log("SD card, ~s capacity, ~b sectors, 4-bit bus at ~b Hz",
                [capacity_name(Addressing), Sectors, State#state.clock]),
            {ok, State};
        {error, Reason} ->
            log("the SD card is not driven: ~0P", [Reason, ?DEPTH]),
            ignore
    end.

capacity_name(byte) -> "standard";
capacity_name(block) -> "high".

start(Spec) ->
    maybe
        {ok, Dev} ?= tagged(open, erx_device:open(Spec)),
        {ok, Irq} ?= tagged(attach, erx_irq_line:attach(Dev, ?IRQ_LINE)),
        ok ?= tagged(signalling, erx_blk_sd_host:signalling(erx_device:read(Dev, control2))),
        ok = dat0(Dev),
        {ok, Reset} ?= reset(#state{dev = Dev, regs = erx_blk_sd_regs:new(Dev), irq = Irq}, reset_all),
        ok ?= tagged(version, erx_blk_sd_host:version(erx_device:read(Dev, slotisr_ver))),
        {ok, Base} ?= tagged(base_clock, erx_blk_sd_host:base_clock(erx_device:read(Dev, capabilities),
                                                                  maps:get(clock, Spec, 0))),
        {ok, Powered} ?= power(Reset#state{base = Base}),
        {ok, Clocked} ?= clock(Powered, ?IDENTIFICATION_HZ),
        ok = timer:sleep(?CLOCK_WAIT_MS),
        Enabled = enable(Clocked),
        identify(Enabled, erx_blk_sd_card:start())
    end.

%% A step's own answer, its error tagged with the step's name.
tagged(_Name, ok) -> ok;
tagged(_Name, {ok, Value}) -> {ok, Value};
tagged(Name, {error, Reason}) -> {error, {Name, Reason}}.

%% A card still programming holds DAT0 low, and the CMD0 ahead would end its programming;
%% past 1 s the start goes on and says so.
dat0(Dev) ->
    case poll(fun() -> erx_blk_sd_host:dat0_high(erx_device:read(Dev, present)) end, ?DAT0_MS) of
        ok -> ok;
        timeout -> log("DAT0 still low after ~b ms; the start goes on", [?DAT0_MS])
    end.

%% A software reset, reset_all, reset_cmd or reset_data in control1: set, then polled
%% until it clears, for at most 100 ms.
reset(#state{dev = Dev, regs = Regs} = S, Field) ->
    Set = erx_blk_sd_regs:write_field(Regs, control1, Field, 1),
    case poll(fun() -> erx_device:read_field(Dev, control1, Field) =:= 0 end, ?RESET_MS) of
        ok -> {ok, S#state{regs = Set}};
        timeout -> {error, {Field, not_cleared}}
    end.

%% Power cleared, 3.3 V, bus power on and read back, 1 ms; then the card-detect test bits,
%% so the controller takes the card as inserted (the bus stays 1 bit wide from the reset).
power(#state{dev = Dev, regs = Regs} = S) ->
    Cleared = erx_blk_sd_regs:write(Regs, control0, 0),
    Voltage = erx_blk_sd_regs:write_field(Cleared, control0, voltage, ?ERX_HW_SDHCI_CONTROL0_VOLTAGE_V330),
    On = erx_blk_sd_regs:write_field(Voltage, control0, power_on, 1),
    case erx_device:read_field(Dev, control0, power_on) of
        1 ->
            ok = timer:sleep(?POWER_WAIT_MS),
            Detect = erx_blk_sd_regs:write_field(On, control0, card_det, 1),
            {ok, S#state{regs = erx_blk_sd_regs:write_field(Detect, control0, force_card, 1)}};
        _ ->
            {error, {power, off}}
    end.

%% A clock change (design, "The controller's clock"): the card clock stopped, the divider,
%% the internal clock enabled and the data timeout at its largest valid value in one word,
%% the internal clock awaited stable, the card clock started.
clock(#state{dev = Dev, regs = Regs, base = Base} = S, Target) ->
    maybe
        {ok, Divisor, Bits} ?= case erx_blk_sd_host:divider(Base, Target) of
                                   {ok, D, B} -> {ok, D, B};
                                   {error, Reason} -> {error, {clock, Reason}}
                               end,
        Hz = Base div Divisor,
        ok ?= above_floor(Hz),
        Stopped = erx_blk_sd_regs:write_field(Regs, control1, clock_card_en, 0),
        Word = Bits bor ?ERX_HW_SDHCI_CONTROL1_CLOCK_INT_EN_PUT(1)
            bor ?ERX_HW_SDHCI_CONTROL1_TIMEOUT_PUT(?ERX_HW_SDHCI_CONTROL1_TIMEOUT_MAX),
        Divided = erx_blk_sd_regs:write(Stopped, control1, Word),
        ok ?= case poll(fun() -> erx_device:read_field(Dev, control1, clock_int_stable) =:= 1 end,
                        ?CLOCK_STABLE_MS) of
                  ok -> ok;
                  timeout -> {error, {clock, unstable}}
              end,
        {ok, S#state{regs = erx_blk_sd_regs:write_field(Divided, control1, clock_card_en, 1), clock = Hz}}
    end.

above_floor(Hz) when Hz >= ?CLOCK_FLOOR_HZ -> ok;
above_floor(Hz) -> {error, {clock, {below_floor, Hz}}}.

%% One mask of every status the transfer acts on, to both status and signal enable.
enable(#state{regs = Regs} = S) ->
    Mask = erx_blk_sd_regs:write(Regs, irpt_mask, erx_blk_sd_host:enable_mask()),
    S#state{regs = erx_blk_sd_regs:write(Mask, irpt_en, erx_blk_sd_host:enable_mask())}.

%% Identification: each action of erx_blk_sd_card in order; an issue is always the last
%% action of a step, and its answer is the card core's next event.
identify(S, {[{issue, Step}], Card}) ->
    {Event, Next} = command(S, Step),
    identify(Next, erx_blk_sd_card:step(Card, Event));
identify(S, {[{reset, Line} | Rest], Card}) ->
    maybe
        {ok, Next} ?= reset(S, line_reset(Line)),
        identify(Next, {Rest, Card})
    end;
identify(S, {[{wait, Ms} | Rest], Card}) ->
    ok = timer:sleep(Ms),
    identify(S, {Rest, Card});
identify(#state{regs = Regs} = S, {[{bus_width, 4} | Rest], Card}) ->
    identify(S#state{regs = erx_blk_sd_regs:write_field(Regs, control0, bus_4bit, 1)}, {Rest, Card});
identify(S, {[{clock, Hz} | Rest], Card}) ->
    maybe
        {ok, Next} ?= clock(S, Hz),
        identify(Next, {Rest, Card})
    end;
identify(S, {[{identified, Card}], _Card}) ->
    {ok, S#state{card = Card}};
identify(_S, {[{refuse, Reason}], _Card}) ->
    {error, {refused, Reason}};
identify(_S, {Actions, _Card}) ->
    {error, {identify, {actions, length(Actions)}}}.

line_reset(cmd) -> reset_cmd;
line_reset(dat) -> reset_data.

%% One identification command through its plan, and its answer as the card core's event,
%% everything within 1 s of the issue: erx_blk_sd_host's wait for the command takes each
%% interrupt word, and its actions read the response at command complete, the block from
%% `data` at buffer read ready and feed the plan's block at buffer write ready. Every
%% event a word carries goes to the command whose issue preceded it; the issue clears
%% what an earlier command left in `interrupt` (erx_blk_write:sd_issue/2).
command(#state{regs = Regs} = S, Step) ->
    Deadline = now_ms() + ?STEP_MS,
    maybe
        {ok, Plan} ?= erx_blk_write:sd_plan(Step),
        {ok, Issued} ?= erx_blk_write:sd_issue(Regs, Plan),
        Shape = erx_blk_write:sd_shape(Plan),
        await(S#state{regs = Issued}, {Plan, Shape}, erx_blk_sd_host:command(Shape), #{}, Deadline)
    else
        {error, Reason} -> {{error, Reason}, S}
    end.

%% The command's wait, Wait, given each delivery's word until it is done or fails, or
%% Deadline passes. Got holds what the actions read so far: the response and the bytes.
await(#state{dev = Dev} = S, Command, Wait, Got, Deadline) ->
    receive
        {erx_irq, Dev, ?IRQ_LINE} ->
            {Events, Serviced} = service(S),
            case erx_blk_sd_host:command_step(Wait, Events) of
                {fail, Event} ->
                    {Event, Serviced};
                Step ->
                    {Actions, Next} = case Step of
                                          {continue, A, N} -> {A, N};
                                          {done, A} -> {A, done}
                                      end,
                    case act(Serviced, Command, Actions, Got) of
                        {error, _} = Failed -> {Failed, Serviced};
                        {ok, Read} when Next =:= done -> {answer(Command, Read), Serviced};
                        {ok, Read} -> next_word(Serviced, Command, Next, Read, Deadline)
                    end
            end
    after max(0, Deadline - now_ms()) ->
        {{error, {deadline, erx_blk_sd_host:awaited(Wait)}}, S}
    end.

%% The next word, unless the deadline has passed: a run of deliveries that move no track
%% (words of no events, or only ignored ones) cannot hold the step past it.
next_word(S, Command, Wait, Got, Deadline) ->
    case now_ms() >= Deadline of
        true -> {{error, {deadline, erx_blk_sd_host:awaited(Wait)}}, S};
        false -> await(S, Command, Wait, Got, Deadline)
    end.

%% The wait's actions in order, each adding what it read to Got.
act(S, Command, Actions, Got) ->
    lists:foldl(fun(Action, {ok, G}) -> act_one(S, Command, Action, G);
                   (_Action, Failed) -> Failed
                end, {ok, Got}, Actions).

act_one(#state{dev = Dev}, {_Plan, #{response := Response}}, read_response, Got) ->
    {ok, Got#{response => response(Dev, Response)}};
act_one(#state{dev = Dev}, {_Plan, #{data := {read, Size, 1}}}, read_block, Got) ->
    {ok, Got#{bytes => read_words(Dev, Size div 4)}};
act_one(#state{regs = Regs}, {Plan, _Shape}, write_block, Got) ->
    case erx_blk_write:sd_feed(Regs, Plan, 0) of
        ok -> {ok, Got};
        {error, _} = Failed -> Failed
    end.

%% The card core's event for a finished command: a read's R1 and bytes, or the response.
answer({_Plan, #{data := {read, _Size, 1}}}, #{response := R1, bytes := Bytes}) -> {data, R1, Bytes};
answer(_Command, #{response := Response}) -> {response, Response}.

%% The response registers: none for CMD0, all four for an R2, resp0 otherwise.
response(_Dev, none) -> none;
response(Dev, r2) -> [erx_device:read(Dev, {resp, N}) || N <- [0, 1, 2, 3]];
response(Dev, _R48) -> erx_device:read(Dev, {resp, 0}).

%% Words from `data`, the first byte in the low byte of the first word.
read_words(Dev, Words) ->
    << <<(erx_device:read(Dev, data)):32/little>> || _ <- lists:seq(1, Words) >>.

%%% The interrupt

%% One delivery: the word read once; none for a word that is not this controller's;
%% otherwise its one-to-clear bits written back, then the line answered, then its events.
service(#state{dev = Dev, regs = Regs, irq = Irq} = S) ->
    Word = erx_device:read(Dev, interrupt),
    case erx_blk_sd_host:decode(Word) of
        none ->
            ok = erx_irq_line:ack(Irq),
            {[], S};
        Events ->
            Cleared = erx_blk_sd_regs:write(Regs, interrupt, Word band erx_blk_sd_host:ack_mask()),
            ok = erx_irq_line:ack(Irq),
            {Events, S#state{regs = Cleared}}
    end.

%%% Requests

handle_call(info, _From, State = #state{card = Card, clock = Clock}) ->
    #{addressing := Addressing, sectors := Sectors, cid := Cid, cache := Cache} = Card,
    {reply, {ok, #{transport => sdhci, capacity => Sectors, max_sectors => erx_blk_request:max_sectors(),
                   detail => #{addressing => Addressing, clock => Clock, bus_width => 4, cid => Cid,
                               cache => Cache}}}, State};
handle_call({read, Sector, Count}, From, State = #state{card = Card}) ->
    accept(From, read, Sector, erx_blk_write:sd_read_plan(Sector, Count, Card), State);
handle_call({write, Sector, Data}, From, State = #state{card = Card}) ->
    accept(From, write, Sector, erx_blk_write:sd_write_plan(Sector, Data, Card), State);
handle_call(flush, From, State = #state{card = Card}) ->
    accept(From, flush, 0, erx_blk_write:sd_status_plan(Card), State);
%% A call outside the transport contract is refused, not crashed on, as erx_blk_virtio's.
handle_call(_Other, _From, State) ->
    {reply, {error, bad_count}, State}.

handle_cast(_Other, State) ->
    {noreply, State}.

handle_info({erx_irq, Dev, ?IRQ_LINE}, State = #state{dev = Dev}) ->
    {Events, Serviced} = service(State),
    lists:foldl(fun(Event, {noreply, S}) -> transfer(S, event(S, Event));
                   (_Event, Stopped) -> Stopped
                end, {noreply, Serviced}, Events);
handle_info({timeout, Timer, tick}, State = #state{current = {_Job, _T, _Read, Timer}}) ->
    transfer(State, {tick, now_ms()});
handle_info(_Other, State) ->
    {noreply, State}.

%% An interrupt event as the transfer takes it, with the response register it carries
%% read at that event.
event(#state{dev = Dev}, command_complete) -> {command_complete, erx_device:read(Dev, {resp, 0})};
event(#state{dev = Dev}, transfer_complete) -> {transfer_complete, erx_device:read(Dev, {resp, 3})};
event(_S, Event) -> Event.

%% A request whose plan the builders made waits its turn; one they refused is answered now.
accept(_From, _Op, _Sector, {error, Reason}, State) ->
    {reply, {error, Reason}, State};
accept(From, Op, Sector, {ok, Plan}, State = #state{waiting = Waiting}) ->
    case queue:len(Waiting) < ?MAX_WAITING of
        true ->
            Job = #job{from = From, op = Op, sector = Sector, plan = Plan, accepted = now_ms()},
            next(State#state{waiting = queue:in(Job, Waiting)});
        false ->
            {reply, {error, busy}, State}
    end.

%% The next waiting request, offered to issue, when none is in flight.
next(State = #state{current = none, waiting = Waiting, card = #{sectors := Sectors}}) ->
    case queue:out(Waiting) of
        {empty, _} ->
            {noreply, State};
        {{value, Job}, Rest} ->
            T = erx_blk_sd_host:new(request(Job, Sectors)),
            transfer(State#state{current = {Job, T, [], none}, waiting = Rest}, {start, now_ms()})
    end;
next(State) ->
    {noreply, State}.

%% The transfer's request, its block count from the plan, so the blocks counted are the
%% ones the plan's command moves.
request(#job{op = flush, accepted = Accepted}, _Sectors) ->
    #{op => flush, accepted => Accepted};
request(#job{op = Op, sector = Sector, plan = Plan, accepted = Accepted}, Sectors) ->
    #{data := {_Direction, _Size, Count}} = erx_blk_write:sd_shape(Plan),
    #{op => Op, sector => Sector, count => Count, capacity => Sectors, accepted => Accepted}.

%% One event of the request in flight, its actions performed in order, and its timer moved
%% to the transfer's next deadline. An event with no request in flight is dropped.
transfer(State = #state{current = none}, _Event) ->
    {noreply, State};
transfer(State = #state{current = {Job, T, Read, Timer}}, Event) ->
    {Actions, Next} = erx_blk_sd_host:step(T, Event),
    perform(Actions, State#state{current = {Job, Next, Read, Timer}}).

perform([], State = #state{current = {Job, T, Read, Timer}}) ->
    {noreply, State#state{current = {Job, T, Read, rearm(Timer, erx_blk_sd_host:deadline(T))}}};
perform([Action | Rest], State = #state{current = {Job, T, Read, Timer}, regs = Regs, card = Card}) ->
    case Action of
        {issue, transfer} ->
            issued(Rest, State, erx_blk_write:sd_issue(Regs, Job#job.plan));
        {issue, status} ->
            {ok, Status} = erx_blk_write:sd_status_plan(Card),
            issued(Rest, State, erx_blk_write:sd_issue(Regs, Status));
        read_block ->
            Block = read_words(State#state.dev, ?BLOCK_WORDS),
            perform(Rest, State#state{current = {Job, T, [Block | Read], Timer}});
        {write_block, Index} ->
            case erx_blk_write:sd_feed(Regs, Job#job.plan, Index) of
                ok -> perform(Rest, State);
                {error, Reason} -> fail(Reason, State)
            end;
        {answer, Answer} ->
            _ = cancel(Timer),
            gen_server:reply(Job#job.from, reply(Job, Answer, Read)),
            next(State#state{current = none});
        {fail, Detail} ->
            fail(Detail, State)
    end.

issued(Rest, State, {ok, Regs}) -> perform(Rest, State#state{regs = Regs});
issued(_Rest, State, {error, {device, Detail}}) -> fail(Detail, State).

reply(#job{op = read}, ok, Read) -> {ok, iolist_to_binary(lists:reverse(Read))};
reply(_Job, ok, _Read) -> ok;
reply(_Job, {error, _} = Refused, _Read) -> Refused.

%% The card or the controller failed: the request in flight and every waiting one are
%% answered {device, Detail}, one line names the request and the detail, and the process
%% ends (moduledoc).
fail(Detail, State = #state{current = Current, waiting = Waiting}) ->
    InFlight = case Current of
                   {Job, _T, _Read, Timer} -> _ = cancel(Timer), [Job];
                   none -> []
               end,
    Jobs = InFlight ++ queue:to_list(Waiting),
    lists:foreach(fun(#job{from = From}) -> gen_server:reply(From, {error, {device, Detail}}) end, Jobs),
    Op = case InFlight of [#job{op = O, sector = Sector}] -> {O, Sector}; [] -> none end,
    log("the SD card failed ~0P: ~0P; the storage domain ends", [Op, ?DEPTH, Detail, ?DEPTH]),
    {stop, {shutdown, sd_failed}, State#state{current = none, waiting = queue:new()}}.

rearm(Timer, Deadline) ->
    _ = cancel(Timer),
    case Deadline of
        none -> none;
        _ -> erlang:start_timer(Deadline, self(), tick, [{abs, true}])
    end.

cancel(none) -> ok;
cancel(Timer) -> erlang:cancel_timer(Timer, [{async, true}, {info, false}]).

%%% Helpers

%% Fun until it holds, checked at once and then every millisecond, for at most Ms.
poll(Fun, Ms) ->
    poll_until(Fun, now_ms() + Ms).

poll_until(Fun, Until) ->
    case Fun() of
        true -> ok;
        false ->
            case now_ms() >= Until of
                true -> timeout;
                false -> ok = timer:sleep(1), poll_until(Fun, Until)
            end
    end.

now_ms() ->
    erlang:monotonic_time(millisecond).

%% One line of the kernel log. Every value in it is an integer or a fixed atom of this
%% driver's, of erx_device's or of the cores', never text the card sent.
log(Format, Arguments) ->
    _ = erx_log:debug(["erx_blk: ", io_lib:format(Format, Arguments)]),
    ok.
