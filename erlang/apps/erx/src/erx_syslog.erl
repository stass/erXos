%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_syslog).
-moduledoc """
The system log's service (docs/design-log.md, "Overview"): the one process
that takes the records every domain and the kernel write, stamps them,
holds each domain to its rate, escapes them, and hands the lines to the log's
consumers, the console and the store. Its decisions are erx_syslog_core's;
this process does the effects: the takes, the clock, the answers and the
monitors. It touches no file.

**What comes in.**

* The kernel's ring: every TICK_MS the service takes the lines nobody has
  taken (erx_log:take/0), and it is the ring's one taker (invariant L4). Its
  init makes the first take, which is also the handoff of the UART from the
  early console ("The kernel's records"), so kernel_sup starts it before
  user_sup starts the console's driver. A kernel line arrives escaped by the
  kernel; its own newline is cut, and it joins the backlogs as a `kernel`
  line. A take that reports records lost or a record that failed its checks
  adds the service's note saying so.
* Another domain's records: the log facet's callback (erx_log_facet) forwards
  a decoded `write` as the call `{write, Grantee, Records}`, Grantee bound
  when the facet was minted, so the domain id is the facet's and never the
  request's (invariant L1). The call is answered `ok` once the lines are in
  the backlogs, never once a consumer has them (invariant L3).
* The system domain's records: erx_log_h sends each as `{log, Level, Text}`
  to this registered name. Another domain's send to a registered name never
  leaves that domain (edit 27 of docs/design-runtime.md), so a record here
  is the system domain's.

Every record's line is made by erx_syslog_core:line/5, through the line
escape, and the core charges it to its domain's rate (invariant L2). At each
tick the rate's second may turn, which writes each domain's drops line.

**What goes out.** A consumer asks with next/1 and gets one batch per
request ("Consumers and backlogs"). The service monitors the asker, and a
kept request whose sender ends is dropped.

**Its lifetime** ("Service lifetime and restart"). erx_syslog_sup restarts
it. The first start in a boot writes `erx_syslog: start` with the release and
the build identifier and sets a persistent_term key; every later start finds
the key and writes `erx_syslog: restarted`, since the old service's backlogs
are gone.

**Stand-ins.** start_link/1 takes the take, the clock and the source of a
domain's id, so the host tests run the service without the kernel's ring.
""".
-behaviour(gen_server).

-export([start_link/0, start_link/1, next/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).
-export_type([config/0]).

-define(TICK_MS, 100).
-define(STARTED, {?MODULE, started}).

%% The service's effects at its edge, each replaceable by a host test: the take of
%% the kernel's ring, the monotonic clock in nanoseconds, and who a domain id is.
-type config() :: #{take => fun(() -> erx_log:lines()),
                    clock => fun(() -> non_neg_integer()),
                    source => fun((pos_integer()) -> erx_syslog_core:source())}.

-record(state, {take :: fun(() -> erx_log:lines()),
                clock :: fun(() -> non_neg_integer()),
                source :: fun((pos_integer()) -> erx_syslog_core:source()),
                %% The system domain's own source; its principal is unknown until the
                %% domain service names it (principal/1).
                system :: erx_syslog_core:source(),
                %% The outstanding ask of the domain service for the system principal.
                asking = none :: none | done | gen_server:request_id(),
                rate :: erx_syslog_core:table(),
                consumers = erx_syslog_core:consumers() :: erx_syslog_core:consumers()}).

-doc "Starts the service registered as erx_syslog, with the kernel's ring and clock.".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(#{}).

-doc "Starts the service with Config's stand-ins for its effects.".
-spec start_link(config()) -> {ok, pid()} | {error, term()}.
start_link(Config) when is_map(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

-doc """
Asks for the role's next batch: the console's lines, or the store's lines each
with its family. The answer comes as a message, which the caller takes with
gen_server:check_response/2; a `{error, _}` answer says the service ended or
was not running, and the caller asks again later. For the two consumers alone.
""".
-spec next(erx_syslog_core:role()) -> gen_server:request_id().
next(Role) when Role =:= console; Role =:= store ->
    gen_server:send_request(?MODULE, {next, Role}).

-spec init(config()) -> {ok, #state{}}.
init(Config) ->
    Clock = maps:get(clock, Config, fun() -> os:perf_counter(nanosecond) end),
    Now = Clock(),
    State0 = #state{take = maps:get(take, Config, fun erx_log:take/0),
                    clock = Clock,
                    source = maps:get(source, Config, fun unknown_source/1),
                    system = #{id => erx_kernel_records:system_domain(), principal => unknown,
                               name => <<"system">>},
                    rate = erx_syslog_core:new(Now)},
    %% The first take is the handoff: from it every kernel record waits in the ring for
    %% the service, so no console write may come before it.
    State1 = take(Now, State0),
    State = notes(Now, [started()], State1),
    erlang:send_after(?TICK_MS, self(), tick),
    {ok, State}.

-spec handle_call(term(), gen_server:from(), #state{}) -> {reply, term(), #state{}} | {noreply, #state{}}.
handle_call({write, Grantee, Records}, _From, State = #state{source = Source})
  when is_integer(Grantee), Grantee > 0, is_list(Records) ->
    {reply, ok, written(Source(Grantee), Records, State)};
handle_call({next, Role}, {Pid, _Tag} = From, State = #state{clock = Clock, system = System,
                                                             consumers = Consumers})
  when Role =:= console; Role =:= store ->
    Monitor = monitor(process, Pid),
    {Actions, Next} = erx_syslog_core:ask(Role, {From, Monitor}, Clock(), System, Consumers),
    {noreply, act(Actions, State#state{consumers = Next})};
handle_call(_Request, _From, State) ->
    {reply, {error, badarg}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(Message, State = #state{asking = Request, system = System})
  when Request =/= none, Request =/= done ->
    %% The domain service's answer, or its end, comes first: its DOWN is no consumer's.
    case gen_server:check_response(Message, Request) of
        {reply, {ok, Principal}} when is_integer(Principal), Principal > 0 ->
            {noreply, State#state{asking = done, system = System#{principal := Principal}}};
        {reply, _NoPrincipal} ->
            {noreply, State#state{asking = done}};
        {error, _Reason} ->
            {noreply, State#state{asking = none}};
        no_reply ->
            info(Message, State)
    end;
handle_info(Message, State) ->
    info(Message, State).

info(tick, State = #state{clock = Clock}) ->
    Now = Clock(),
    erlang:send_after(?TICK_MS, self(), tick),
    {noreply, tick(Now, principal(take(Now, State)))};
info({log, Level, Text}, State = #state{system = System}) when is_atom(Level), is_binary(Text) ->
    {noreply, written(System, [{Level, Text}], State)};
info({'DOWN', Monitor, process, _Pid, _Reason}, State = #state{consumers = Consumers}) ->
    {noreply, State#state{consumers = erx_syslog_core:ended(Monitor, Consumers)}};
info(_Message, State) ->
    {noreply, State}.

%% A crash report or sys:get_status/1 shows neither the backlogs nor the last message,
%% which hold other domains' text, so no domain's bytes appear in the system domain's
%% own report.
-spec format_status(gen_server:format_status()) -> gen_server:format_status().
format_status(Status) ->
    maps:map(fun(state, #state{} = State) -> State#state{consumers = held_back};
                (message, _Message) -> held_back;
                (log, Log) -> [held_back || _ <- Log];
                (_Key, Value) -> Value
             end, Status).

%% Records of Source, rendered and charged by the core, join the backlogs.
written(Source, Records, State = #state{clock = Clock, rate = Rate}) ->
    Now = Clock(),
    {Lines, Next} = erx_syslog_core:write(Now, Source, Records, Rate),
    joined(Now, [{messages, Line} || Line <- Lines], State#state{rate = Next}).

%% A tick: the rate's second may turn, writing its drops lines, and the store's batch
%% may fall due with no line added.
tick(Now, State = #state{system = System, rate = Rate, consumers = Consumers}) ->
    {Drops, NextRate} = erx_syslog_core:turn(Now, System, Rate),
    {Actions, Next} = erx_syslog_core:due(Now, System, Consumers),
    joined(Now, [{messages, Line} || Line <- Drops],
           act(Actions, State#state{rate = NextRate, consumers = Next})).

%% The kernel's lines nobody has taken, with the service's notes of a loss, a record
%% that failed its checks or a refused take.
take(Now, State = #state{take = Take}) ->
    {Lines, Notes} =
        case Take() of
            {Whole, _Next, Lost, Taken} when Whole =:= ok; Whole =:= corrupt ->
                {[kernel_line(Line) || Line <- Taken, Line =/= <<>>],
                 [<<"erx_syslog: ", (integer_to_binary(Lost))/binary, " kernel log records lost">> || Lost > 0] ++
                     [<<"erx_syslog: a kernel log record failed its checks">> || Whole =:= corrupt]};
            {error, Status} when is_integer(Status) ->
                {[], [<<"erx_syslog: the kernel log refused a take: ", (integer_to_binary(Status))/binary>>]}
        end,
    notes(Now, Notes, joined(Now, [{kernel, Line} || Line <- Lines], State)).

%% The service's own notes, as lines of the system domain.
notes(_Now, [], State) ->
    State;
notes(Now, Texts, State = #state{system = System}) ->
    joined(Now, [{messages, erx_syslog_core:note(Now, System, Text)} || Text <- Texts], State).

joined(Now, Lines, State = #state{system = System, consumers = Consumers}) ->
    {Actions, Next} = erx_syslog_core:lines(Now, System, Lines, Consumers),
    act(Actions, State#state{consumers = Next}).

%% The core's actions: a batch answers its request, and an answered or replaced
%% request's monitor is forgotten.
act(Actions, State) ->
    lists:foreach(fun({send, {From, Monitor}, Batch}) ->
                          demonitor(Monitor, [flush]),
                          gen_server:reply(From, Batch);
                     ({forget, {_From, Monitor}}) ->
                          demonitor(Monitor, [flush]);
                     ({refuse, {From, Monitor}}) ->
                          demonitor(Monitor, [flush]),
                          gen_server:reply(From, {error, busy})
                  end, Actions),
    State.

%% A line of the ring ends in its one newline, which a line in the backlogs does not.
kernel_line(Line) ->
    case binary:last(Line) of
        $\n -> binary:part(Line, 0, byte_size(Line) - 1);
        _ -> Line
    end.

%% The first start in a boot, or a restart after the old service's backlogs were lost.
started() ->
    case persistent_term:get(?STARTED, false) of
        true ->
            <<"erx_syslog: restarted">>;
        false ->
            persistent_term:put(?STARTED, true),
            iolist_to_binary([<<"erx_syslog: start, release ">>, release(), <<", build ">>, build()])
    end.

release() ->
    {Name, Version} = init:script_id(),
    [Name, $\s, Version].

build() ->
    case erx_build:id() of
        {ok, Id} -> Id;
        {error, _} -> <<"unknown">>
    end.

%% The system principal, once the domain service runs: asked once, without waiting,
%% and asked again only if the service ended before it answered.
principal(State = #state{asking = none}) ->
    case whereis(erx_domain_srv) of
        undefined -> State;
        Service -> State#state{asking = gen_server:send_request(Service, system_principal)}
    end;
principal(State) ->
    State.

%% Who a domain id is, until the domain service names its domains to the service: the
%% id alone, which is the facet's and so the domain's own, with its principal and
%% name unknown rather than guessed (TODO.md).
unknown_source(Id) ->
    #{id => Id, principal => unknown, name => <<"unknown">>}.
