%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_driver).
-moduledoc """
One interface's driver (docs/design-network-stack.md, "The driver"): a process running a
transport, its callback module, which holds only its medium. The driver holds everything
the credits and the interface need, written once for every transport: the attach, the
receive and transmit credits, the transmit backlog and the link state.

* **Attaching.** The interface calls `attach/2` with its receive credit; the driver
  monitors it and answers its link information and its transmit credit, made at start
  with the transport's `tx_limit`. While no interface is attached, received frames are
  dropped and counted as `detached`.
* **Receiving.** Each batch the transport delivers is cut into batches within the merge's
  limit, `erx_bytes:tcp_merge_limit/0` (docs/design-network-fastpath.md, "The merge, before
  classification"), so the interface's merge never refuses one: a batch ends at its last
  allowed frame or at the frame that brings it to the limit's bytes, and a frame longer than
  those bytes, which no medium's MTU allows, is dropped and counted as `too_long`. Each batch
  goes to the interface as one message `{frames, Driver, Frames}` against the receive credit,
  one unit per frame; a refused batch is dropped whole and counted as `no_room`.
* **Link changes.** The driver keeps the transport's latest link state and the last one it
  told the interface; while they differ it hands `{link, Driver, State}`, one unit. A
  refused notice is tried again after each later message and at a hint 10 ms later, so a
  link that goes down and stays silent is still told once there is room, and only the
  latest state is ever told.
* **Ending.** The driver ends when its medium does, and its supervisor then starts the
  link again, transport and all. Three things end it. A transport answers `{stop,
  Reason}` from `event/2` when its medium is gone, such as a pipe whose far end ended,
  and the driver ends with `{shutdown, Reason}`. The driver traps exits, and an exit
  signal from anything linked to it but its supervisor (a port or socket of its medium)
  ends it with `{shutdown, {linked, Reason}}`. A crash ends it with the crash's reason.
* **The hold.** Once running, the driver lives a second (`?HOLD_MS`) at the least,
  whatever ends it, except its supervisor's own stop (`shutdown`), which is at once.
  A stop that comes sooner waits out the rest of the second with the driver still
  answering and its link told `down`, so that the interface starting beside it attaches;
  a crash that comes sooner waits in `terminate/2`. A medium that fails at every start
  therefore restarts its link at most once a second, and `starts_within/1` bounds the
  restarts a supervisor above can count. A transport whose `init` fails is not held: it
  never ran, and its start fails.
* **Transmitting.** A sender hands `{transmit, Frames}` against the transmit credit, one
  unit per frame. Each frame's unit is taken when the frame leaves the driver, sent or
  dropped, not when its message arrives, so the credit bounds the mailbox and the backlog
  together; a frame the transport cannot take now (`full`) waits in the backlog, with
  those after it, until the transport's `writable` event. Before it gives the transport
  anything, the driver joins the frames of every further `{transmit, ...}` already in its
  mailbox to the backlog, in arrival order (docs/design-network-fastpath.md, "Processes and
  batching"), so the transport is handed all that waits at once.

Frames are untrusted: the driver reads none of their bytes; a transport parses nothing
either and only checks a frame's type and length.
""".

-behaviour(gen_server).

-export([start_link/3, attach/2, counters/1, starts_within/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

-export_type([link_info/0, finisher/0, event/0, rx_frame/0]).

-define(RETRY_US, 10000).
%% How long a driver lives at the least: an end sooner waits out the rest.
-define(HOLD_MS, 1000).

-doc """
What a transport tells of its medium at `init`: the link and link-layer address, the MTU,
the link state, how many frames may wait at the driver, and who finishes a frame's delayed
checksum (`finisher()`).
""".
-type link_info() :: #{link := ethernet | none,
                       lladdr := <<_:48>> | none,
                       mtu := 68..65535,
                       state := up | down,
                       tx_limit := pos_integer(),
                       finish := finisher()}.

-doc """
Who finishes what a sender leaves unfinished, a delayed checksum
(docs/design-network-stack.md, "Checksums in the copy"): `device` when the device does,
`copy` when the transport's own copy does, and `none` when nobody below the sender does,
so the frame layer finishes every checksum itself. It is fixed by the transport and its
configuration, so a driver's restart never changes it. A transport whose `finish` is
`none` drops a delayed frame (`erx_net_frame:delayed()`) as `malformed`, and one that
finishes drops a frame that is not `erx_net_frame:finishable/2` the same way.
""".
-type finisher() :: copy | device | none.

-doc """
A received frame: its bytes alone, which the frame's decoders sum; with its network sum, the
sum (`erx_net_sum`) of its bytes after the link header, which the transport's copy computed
over the bytes the binary holds (docs/design-network-stack.md, "Checksums in the copy"); or
the loopback interface's packet with its zone.
""".
-type rx_frame() :: binary()
                  | {sum, erx_net_sum:sum(), binary()}
                  | {Zone :: term(), binary()}.

-doc """
What a transport makes of a message from its medium: a batch of frames, a link change,
room to transmit again, or a frame it dropped, by reason (`too_long`, `stranger`,
`malformed`).
""".
-type event() :: {frames, [rx_frame()]}
               | {link, up | down}
               | writable
               | {dropped, Reason :: atom()}.

-callback init(Config :: map()) -> {ok, link_info(), T :: term()} | ignore | {error, Reason :: term()}.
-callback event(Msg :: term(), T) -> {[event()], T} | {stop, Reason :: term()} when T :: term().
-callback transmit(erx_net_frame:frame(), T) -> {ok | full | {drop, Reason :: atom()}, T}
    when T :: term().

-record(state, {transport :: module(),
                t :: term(),
                info :: link_info(),
                tx :: erx_net_credit:credit(),
                started :: integer(),    % erlang:monotonic_time() at init, in native units
                ending = none :: none | {shutdown, term()},  % the end a stop waits to make
                iface = none :: none | {pid(), reference(), erx_net_credit:credit()},
                backlog = queue:new() :: queue:queue(erx_net_frame:frame()),
                blocked = false :: boolean(),
                latest :: up | down,     % the transport's link state
                told :: up | down,       % the last state the interface was told
                armed = infinity :: erx_net_clock:armed(),
                merge_limit :: {pos_integer(), pos_integer()},  % erx_bytes:tcp_merge_limit/0
                counters = #{} :: #{atom() => pos_integer()}}).

%% --- API -------------------------------------------------------------------------

-doc """
Starts the driver of interface `Name` over `Transport` with its configuration, and
registers it with erx_net_tables, where the interface finds it. A transport with
nothing to drive answers `ignore` at its `init`, and so does the start.
""".
-spec start_link(term(), module(), map()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Name, Transport, Config) ->
    gen_server:start_link(?MODULE, {Name, Transport, Config}, []).

-doc """
Attaches the calling interface process with its receive credit; the answer is the link
information and the transmit credit every sender hands frames against.
""".
-spec attach(pid(), erx_net_credit:credit()) -> {ok, link_info(), erx_net_credit:credit()}.
attach(Driver, RxCredit) ->
    gen_server:call(Driver, {attach, RxCredit}, infinity).

-doc """
The most starts of one link that a supervisor counting restarts over `Period` seconds
can see from its drivers' ends, as an intensity that such starts never exceed. OTP's
supervisor keeps a restart while its whole second is within `Period` of the latest
one's, so the restarts it counts at once span less than `Period + 1` seconds; two starts
of a link are a hold apart at the least, so at most `ceil((Period + 1) s / hold)` of
them fit, and the supervisor gives up only at one more than its intensity.
""".
-spec starts_within(pos_integer()) -> pos_integer().
starts_within(Period) ->
    ((Period + 1) * 1000 + ?HOLD_MS - 1) div ?HOLD_MS.

-doc "The driver's drop counters, by reason.".
-spec counters(pid()) -> #{atom() => pos_integer()}.
counters(Driver) ->
    gen_server:call(Driver, counters, infinity).

%% --- gen_server ------------------------------------------------------------------

-doc false.
init({Name, Transport, Config}) ->
    Started = erlang:monotonic_time(),
    process_flag(trap_exit, true),
    case Transport:init(Config) of
        {ok, #{state := Link, tx_limit := Limit} = Info, T} ->
            ok = erx_net_tables:register_driver(Name, self()),
            {ok, #state{transport = Transport, t = T, info = Info, started = Started,
                        tx = erx_net_credit:new(Limit), latest = Link, told = Link,
                        merge_limit = erx_bytes:tcp_merge_limit()}};
        ignore ->
            ignore;
        {error, Reason} ->
            {stop, Reason}
    end.

-doc false.
handle_call({attach, RxCredit}, {Pid, _}, #state{iface = Old} = S) ->
    _ = demonitor_iface(Old),
    Info = (S#state.info)#{state := S#state.latest},
    Ref = erlang:monitor(process, Pid),
    {reply, {ok, Info, S#state.tx},
     S#state{iface = {Pid, Ref, RxCredit}, told = S#state.latest}};
handle_call(counters, _From, S) ->
    {reply, S#state.counters, S}.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

-doc false.
handle_info({?MODULE, held}, #state{ending = {shutdown, _} = End} = S) ->
    {stop, End, S};
handle_info(Msg, S0) ->
    case message(Msg, S0) of
        {stop, Reason} -> end_after_hold({shutdown, Reason}, S0);
        S -> {noreply, tell_link(S)}
    end.

%% A crash before the driver has lived its hold waits out the rest here; the supervisor's
%% stop ends it at once. The hold is on the host's clock, not erx_net_clock's, since what
%% it paces is the supervisor's, which counts the host's seconds.
-doc false.
terminate(shutdown, _S) ->
    ok;
terminate(_Reason, S) ->
    receive after max(held_in(S), 0) -> ok end.

%% Ends the driver with End once it has lived its hold. Sooner, it keeps answering with its
%% link down until the hold is over: an interface starting beside it still attaches, so its
%% link's start completes. The first end decided is the one made.
end_after_hold(_End, #state{ending = {shutdown, _}} = S) ->
    {noreply, S};
end_after_hold(End, S) ->
    case held_in(S) of
        Left when Left > 0 ->
            _ = erlang:send_after(Left, self(), {?MODULE, held}),
            {noreply, tell_link(S#state{ending = End, latest = down})};
        _ ->
            {stop, End, S}
    end.

%% Milliseconds until the driver has lived its hold, rounded up so that a wait of that
%% long never ends short of it; zero or less once it has.
held_in(#state{started = Started}) ->
    Lived = erlang:convert_time_unit(erlang:monotonic_time() - Started, native, microsecond),
    (?HOLD_MS * 1000 - Lived + 999) div 1000.

%% A crash report names the frames the driver held by their count, never their bytes, which
%% are senders' data and the network's.
-doc false.
format_status(Status) ->
    maps:map(fun(state, #state{backlog = Backlog} = S) ->
                     S#state{backlog = {frames, queue:len(Backlog)}};
                (message, _) -> redacted;
                (log, _) -> [];
                (_, Value) -> Value
             end, Status).

%% --- One message -----------------------------------------------------------------

%% The state after one message, or `{stop, Reason}` when the message ends the medium.

message({transmit, Frames}, #state{backlog = Backlog} = S) when is_list(Frames) ->
    drain(S#state{backlog = queued_transmits(queue:join(Backlog, queue:from_list(Frames)))});
message({erx_net_clock, hint}, S) ->
    S#state{armed = infinity};
message({'DOWN', Ref, process, _, _}, #state{iface = {_, Ref, _}} = S) ->
    S#state{iface = none};
message({'EXIT', _Medium, Reason}, _S) ->
    {stop, {linked, Reason}};
message(Msg, #state{transport = Transport, t = T0} = S) ->
    case Transport:event(Msg, T0) of
        {stop, _Reason} = Stop -> Stop;
        {Events, T} -> lists:foldl(fun event/2, S#state{t = T}, Events)
    end.

event({frames, []}, S) ->
    S;
event({frames, Frames}, #state{iface = none} = S) ->
    count(detached, length(Frames), S);
event({frames, Frames}, #state{iface = {Pid, _, Rx}, merge_limit = Limit} = S0) ->
    {Batches, TooLong} = batches(Frames, Limit),
    S = case TooLong of 0 -> S0; _ -> count(too_long, TooLong, S0) end,
    lists:foldl(fun(Batch, S1) -> hand_batch(Pid, Rx, Batch, S1) end, S, Batches);
event({link, _}, #state{ending = {shutdown, _}} = S) ->
    S;
event({link, State}, S) when State =:= up; State =:= down ->
    S#state{latest = State};
event(writable, S) ->
    drain(S#state{blocked = false});
event({dropped, Reason}, S) when is_atom(Reason) ->
    count(Reason, 1, S).

%% The backlog with the frames of every further `{transmit, ...}` already in the mailbox
%% joined in arrival order. Senders hand frames only against the transmit credit, so the
%% drain ends within its limit.
queued_transmits(Backlog) ->
    receive
        {transmit, Frames} when is_list(Frames) ->
            queued_transmits(queue:join(Backlog, queue:from_list(Frames)))
    after 0 ->
        Backlog
    end.

%% Gives the transport the backlog's frames in order until it is empty or the transport
%% is full; each frame that leaves, sent or dropped, takes its unit.
drain(#state{blocked = true} = S) ->
    S;
drain(#state{backlog = Backlog0, transport = Transport, t = T0, tx = Tx} = S) ->
    case queue:out(Backlog0) of
        {empty, _} ->
            S;
        {{value, Frame}, Backlog} ->
            case Transport:transmit(Frame, T0) of
                {ok, T} ->
                    ok = erx_net_credit:take(Tx, 1),
                    drain(S#state{backlog = Backlog, t = T});
                {{drop, Reason}, T} ->
                    ok = erx_net_credit:take(Tx, 1),
                    drain(count(Reason, 1, S#state{backlog = Backlog, t = T}));
                {full, T} ->
                    S#state{t = T, blocked = true}
            end
    end.

%% Tells the attached interface the latest link state when it differs from the last one
%% told; a refused notice waits for the next message or a hint 10 ms on.
tell_link(#state{iface = {Pid, _, Rx}, latest = Latest, told = Told} = S) when Latest =/= Told ->
    case erx_net_credit:hand(Pid, Rx, 1, {link, self(), Latest}) of
        ok ->
            S#state{told = Latest};
        full ->
            Retry = erx_net_clock:now() + ?RETRY_US,
            S#state{armed = erx_net_clock:arm_by(Retry, S#state.armed)}
    end;
tell_link(S) ->
    S.

hand_batch(Pid, Rx, Batch, S) ->
    case erx_net_credit:hand(Pid, Rx, length(Batch), {frames, self(), Batch}) of
        ok -> S;
        full -> count(no_room, length(Batch), S)
    end.

%% Frames cut into batches within {MaxFrames, MaxBytes}, in order, and how many frames of more
%% than MaxBytes bytes were left out. A batch ends at its MaxFrames-th frame or at the frame that
%% brings its bytes to MaxBytes, so the frames before its last hold fewer.
batches(Frames, Limit) ->
    cut(Frames, Limit, [], 0, 0, [], 0).

cut([], _Limit, Batch, _N, _Bytes, Batches, Long) ->
    {lists:reverse(closed(Batch, Batches)), Long};
cut([Frame | Rest], {MaxFrames, MaxBytes} = Limit, Batch, N, Bytes, Batches, Long) ->
    Size = frame_size(Frame),
    if
        Size > MaxBytes ->
            cut(Rest, Limit, Batch, N, Bytes, Batches, Long + 1);
        N + 1 =:= MaxFrames; Bytes + Size >= MaxBytes ->
            cut(Rest, Limit, [], 0, 0, closed([Frame | Batch], Batches), Long);
        true ->
            cut(Rest, Limit, [Frame | Batch], N + 1, Bytes + Size, Batches, Long)
    end.

closed([], Batches) -> Batches;
closed(Batch, Batches) -> [lists:reverse(Batch) | Batches].

frame_size({sum, _Sum, Bytes}) -> byte_size(Bytes);
frame_size({_Zone, Bytes}) -> byte_size(Bytes);
frame_size(Bytes) -> byte_size(Bytes).

count(Reason, N, #state{counters = Counters} = S) ->
    S#state{counters = maps:update_with(Reason, fun(C) -> C + N end, N, Counters)}.

demonitor_iface(none) -> true;
demonitor_iface({_, Ref, _}) -> erlang:demonitor(Ref, [flush]).
