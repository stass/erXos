%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hostlink).
-behaviour(gen_server).

-moduledoc """
The host link's process in the system domain (docs/design-live.md, "The host
link"): the effects around erx_hostlink_session's pure state machine, and the
one sink of the host link's UART.

It finds the UART the system manifest names as `machine.hostlink` among the
root's device records (`-erx device hostlink pl011 ...`) and starts erx_pl011
on it as its owner, so only this process hands that line bytes to write. A
machine whose manifest names no host link has no record, and the process is
not started (`ignore`), as a machine without a disk has no block driver.

Everything the session decides is erx_hostlink_session's; this module only
performs what `step/2` returns, in order, and feeds back what happened:

* the line's bytes go in as `input` events, and once no byte has arrived for
  `?IDLE_MS` an `idle` event lets the session grant what it owes;
* a `send` action joins the output queue, which hands the driver one frame at
  a time, the next once the driver says the last is written;
* an `execute` action runs the call in a monitored process of its own, whose
  heap is held to the session's resident limit: it decodes the payload, asks
  the root or the facet and reports a `call_done`, and a process that ends
  without reporting reports `{error, failed}`, so no call stays executing;
* a facet the session took into its table is monitored and its exit reported
  as `facet_down`; a facet it closes is ended;
* `draw_entropy` is answered with a fresh session identifier.

**Bounded output.** A host can ask for more output than it sends, by repeating
a call whose kept reply is large. While the output queue holds more than
`?OUTPUT_BACKLOG` bytes the process takes no input: the line's bytes wait,
unread by the session, so it grants no credit, and the host, which sends only
within credit, stops. What waits is at most the credit the host held.

**Bounded decoding.** Phase 1's payload check (erx_hostlink_payload) builds
the term before its size is known. It runs in a process whose heap is held
to the session's resident limit, which is killed on passing it, and the
payload is then refused as too large.

The root (target 0) offers `{open, Name}`. Of the facets the design lists, the
install facet exists (erx_hostlink_install, over erx_code); the others answer
`{error, unsupported}` until their services exist, and any other request to
the root `{error, badarg}`. Casts reach no facet: none takes them.
""".

-export([start_link/0, root/2, build/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-include("generated/erx_abi.hrl").

%% How long the line stays quiet before the session hears `idle`. The host
%% waits for a grant only when it has less credit than its next frame needs,
%% so this is the longest a host short of credit waits.
-define(IDLE_MS, 20).
%% The output the queue holds before input waits: four of the largest frames.
-define(OUTPUT_BACKLOG, 4 * ?ERX_HOSTLINK_ENCODED_MAX).
%% The facets docs/design-live.md lists for a development build's host whose
%% services this package does not serve yet.
-define(NOT_SERVED, [inspect, trace, update, code, domain, console, web]).
%% The build identifier's bits: the pack header's build_id, the bytes from its
%% offset to the next field's.
-define(BUILD_BITS, (8 * (?ERX_PACK_HEADER_OFF_INDEX_HASH - ?ERX_PACK_HEADER_OFF_BUILD_ID))).

-record(state, {
    driver :: pid(),
    core :: erx_hostlink_session:state(),
    %% The idle timer, armed by input.
    idle = none :: none | reference(),
    %% Frames not yet handed to the driver, and whether one is being written.
    output = queue:new() :: queue:queue(binary()),
    output_bytes = 0 :: non_neg_integer(),
    writing = false :: boolean(),
    %% Input held while the output queue is over its backlog.
    held = <<>> :: binary(),
    %% Each executing worker's monitor and the call it answers, by its pid.
    workers = #{} :: #{pid() => {reference(), erx_hostlink_session:serial(), pos_integer()}}
}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc false.
init([]) ->
    case erx_device_record:find(hostlink, pl011) of
        {ok, []} ->
            ignore;
        {ok, [Spec]} ->
            start(Spec);
        {ok, [_, _ | _]} ->
            {stop, {hostlink, "more than one host link device record"}};
        {error, Reason} ->
            {stop, Reason}
    end.

start(Spec) ->
    case build(arguments()) of
        {ok, Build} ->
            {ok, Driver} = erx_pl011:start_link(Spec, self()),
            Core = erx_hostlink_session:new(#{build => Build, versions => versions(),
                                              measure => fun bounded_measure/1}),
            {ok, perform(erx_hostlink_session:step({entropy, entropy()}, Core),
                         #state{driver = Driver, core = Core})};
        {error, Reason} ->
            {stop, Reason}
    end.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, {error, badarg}, State}.

-doc false.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc false.
handle_info({erx_console_input, Bytes}, #state{held = Held} = State) ->
    {noreply, take_input(State#state{held = <<Held/binary, Bytes/binary>>})};
handle_info({timeout, Ref, idle}, #state{idle = Ref} = State) ->
    {noreply, step(idle, State#state{idle = none})};
handle_info({erx_console_written, self}, State) ->
    {noreply, take_input(write_next(State#state{writing = false}))};
handle_info({call_done, Worker, Reply, Opened}, #state{workers = Workers} = State) ->
    case maps:take(Worker, Workers) of
        {{Ref, Serial, Id}, Rest} ->
            erlang:demonitor(Ref, [flush]),
            {noreply, step({call_done, Serial, Id, Reply, Opened}, State#state{workers = Rest})};
        error ->
            {noreply, State}
    end;
handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{workers = Workers} = State) ->
    case maps:take(Pid, Workers) of
        {{_Monitor, Serial, Id}, Rest} ->
            %% A worker that ended without reporting: killed at its heap limit,
            %% or failed outside its own handling.
            {noreply, step({call_done, Serial, Id, {error, failed}, []}, State#state{workers = Rest})};
        error ->
            {noreply, step({facet_down, Pid}, State)}
    end;
handle_info(_Other, State) ->
    {noreply, State}.

-doc """
The state and the message being handled as a crash report or
`sys:get_status/1` shows them: the session's snapshot
(erx_hostlink_session:info/1), which holds counts and sizes, never a
payload's bytes, and of the message only that one was there, since it may
hold the host's bytes or a reply.
""".
format_status(Status) ->
    maps:map(fun(state, #state{core = Core, output_bytes = Out, held = Held}) ->
                     #{session => erx_hostlink_session:info(Core), output_bytes => Out,
                       held_bytes => byte_size(Held)};
                (message, _Message) ->
                     hidden;
                (_Key, Value) ->
                     Value
             end, Status).

%% Feeds held input to the session unless the output queue is over its backlog,
%% and arms the idle timer for it.
take_input(#state{held = <<>>} = State) ->
    State;
take_input(#state{output_bytes = Out} = State) when Out > ?OUTPUT_BACKLOG ->
    State;
take_input(#state{held = Bytes, idle = Idle} = State) ->
    _ = Idle =:= none orelse erlang:cancel_timer(Idle),
    Timer = erlang:start_timer(?IDLE_MS, self(), idle),
    step({input, Bytes}, State#state{held = <<>>, idle = Timer}).

step(Event, #state{core = Core} = State) ->
    perform(erx_hostlink_session:step(Event, Core), State).

%% Performs the actions in order. Only draw_entropy feeds the session again,
%% and the session never asks for entropy in answer to entropy it took, so
%% the recursion ends.
perform({Core, Actions}, State) ->
    lists:foldl(fun act/2, State#state{core = Core}, Actions).

act({send, Bytes}, #state{output = Output, output_bytes = Out} = State) ->
    write_next(State#state{output = queue:in(Bytes, Output), output_bytes = Out + byte_size(Bytes)});
act({execute, Serial, Id, Target, Payload}, #state{workers = Workers} = State) ->
    Server = self(),
    {Pid, Ref} = spawn_opt(fun() -> work(Server, Target, Payload) end,
                           [monitor, {max_heap_size, heap_limit()}]),
    State#state{workers = Workers#{Pid => {Ref, Serial, Id}}};
act({cast, _Serial, _Target, _Payload}, State) ->
    %% Neither the root nor the install facet takes casts.
    State;
act({deliver, _Stream, _Body}, State) ->
    %% The terminal and files streams have no consumer on this machine yet:
    %% a console session and the 9P bridge come with their own services.
    State;
act({monitor_facet, Facet}, State) ->
    _ = erlang:monitor(process, Facet),
    State;
act({close_facet, Facet}, State) ->
    exit(Facet, shutdown),
    State;
act({session_opened, _Id, _Serial}, State) ->
    State;
act({session_ended, _Id, _Reason}, State) ->
    State;
act(draw_entropy, #state{core = Core} = State) ->
    perform(erx_hostlink_session:step({entropy, entropy()}, Core), State).

%% Hands the driver the next frame unless one is being written. The driver
%% answers {erx_console_written, self} once it is.
write_next(#state{writing = true} = State) ->
    State;
write_next(#state{output = Output, output_bytes = Out, driver = Driver} = State) ->
    case queue:out(Output) of
        {{value, Bytes}, Rest} ->
            Driver ! {erx_console_output, self, Bytes},
            State#state{output = Rest, output_bytes = Out - byte_size(Bytes), writing = true};
        {empty, _} ->
            State
    end.

%% A call, in the process that runs it, reporting its reply and the facets it
%% opened to Server. The session measured the payload with the same check
%% before it admitted the call, so it decodes.
work(Server, Target, Payload) ->
    {ok, Term} = erx_hostlink_payload:decode(Payload),
    {Reply, Opened} = case Target of
                          root -> root(Term, Server);
                          Facet -> {erx_hostlink_install:call(Facet, Term), []}
                      end,
    Server ! {call_done, self(), Reply, Opened}.

-doc """
What the root answers a request, with the facets the answer opened: the
session takes those into its table or closes them (erx_hostlink_session,
"The facet table"), so every facet started here is in the table or ended.
Each facet ends with `Link`, the host link's process.
""".
-spec root(term(), pid()) -> {{ok, pid()} | {error, unsupported | badarg}, [pid()]}.
root({open, install}, Link) ->
    {ok, Facet} = erx_hostlink_install:start(Link),
    {{ok, Facet}, [Facet]};
root({open, Name}, _Link) when is_atom(Name) ->
    case lists:member(Name, ?NOT_SERVED) of
        true -> {{error, unsupported}, []};
        false -> {{error, badarg}, []}
    end;
root(_Request, _Link) ->
    {{error, badarg}, []}.

arguments() ->
    case init:get_argument(erx) of
        {ok, Found} -> Found;
        error -> []
    end.

-doc """
The boot image's build identifier among init's `-erx` arguments, as the hello
reports it: in lower-case hexadecimal, two digits per byte of the pack
header's `build_id`, as the root's identity line and the host tool print it.
The root adds `-erx build ID`, the bytes read big-endian as one number in
decimal, since init parses each `-erx` value as a term and hexadecimal digits
need not scan as one. Pure, for its tests.
""".
-spec build([[string()]]) -> {ok, binary()} | {error, {atom(), string()}}.
build(Arguments) ->
    case [Word || ["build", Word | _] <- Arguments] of
        [Word] ->
            case decimal(Word, ?BUILD_BITS) of
                {ok, Id} -> {ok, iolist_to_binary(io_lib:format("~*.16.0b", [?BUILD_BITS div 4, Id]))};
                error -> {error, {bad_build, "-erx build is not the build identifier in decimal"}}
            end;
        [] ->
            {error, {no_build, "the root gave no -erx build"}};
        [_, _ | _] ->
            {error, {bad_build, "more than one -erx build"}}
    end.

%% Digits only, at most as many as the field's largest value has, so no word
%% builds a large integer before the range check.
decimal(Word, Bits) ->
    Max = (1 bsl Bits) - 1,
    case Word =/= [] andalso length(Word) =< length(integer_to_list(Max))
        andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Word) of
        true ->
            case list_to_integer(Word) of
                Value when Value =< Max -> {ok, Value};
                _ -> error
            end;
        false ->
            error
    end.

%% The formats a host must speak: the host link's frame version.
versions() ->
    #{hostlink => ?ERX_HOSTLINK_VERSION}.

%% A session identifier. Phase 1 has no entropy source in the system domain,
%% so this is rand's generator under the seed it takes from the time and the
%% node, which the design accepts only in trusted development modes
%% (docs/design-live.md, "Sessions"; TODO.md).
entropy() ->
    rand:bytes(16).

%% The heap, in words, of a process that decodes a payload: the session's
%% resident limit.
heap_limit() ->
    #{size => maps:get(resident, erx_hostlink_session:default_limits()) div erlang:system_info(wordsize),
      kill => true, error_logger => false}.

%% erx_hostlink_payload:measure/1 in a process held to heap_limit(): one
%% killed on passing it measured a payload too large to hold.
bounded_measure(Payload) ->
    {Pid, Ref} = spawn_opt(fun() -> exit({measured, erx_hostlink_payload:measure(Payload)}) end,
                           [monitor, {max_heap_size, heap_limit()}]),
    receive
        {'DOWN', Ref, process, Pid, {measured, Result}} -> Result;
        {'DOWN', Ref, process, Pid, _Killed} -> {error, too_large}
    end.
