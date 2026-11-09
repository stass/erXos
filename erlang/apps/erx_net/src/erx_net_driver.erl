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
* **Receiving.** Each batch the transport delivers goes to the interface as one message
  `{frames, Driver, Frames}` against the receive credit, one unit per frame; a refused
  batch is dropped whole and counted as `no_room`.
* **Link changes.** The driver keeps the transport's latest link state and the last one it
  told the interface; while they differ it hands `{link, Driver, State}`, one unit. A
  refused notice is tried again after each later message and at a hint 10 ms later, so a
  link that goes down and stays silent is still told once there is room, and only the
  latest state is ever told.
* **Transmitting.** A sender hands `{transmit, Frames}` against the transmit credit, one
  unit per frame. Each frame's unit is taken when the frame leaves the driver, sent or
  dropped, not when its message arrives, so the credit bounds the mailbox and the backlog
  together; a frame the transport cannot take now (`full`) waits in the backlog, with
  those after it, until the transport's `writable` event.

Frames are untrusted: the driver reads none of their bytes; a transport parses nothing
either and only checks a frame's type and length.
""".

-behaviour(gen_server).

-export([start_link/3, attach/2, counters/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-export_type([link_info/0, event/0]).

-define(RETRY_US, 10000).

-doc """
What a transport tells of its medium at `init`: the link and link-layer address, the MTU,
the link state and how many frames may wait at the driver.
""".
-type link_info() :: #{link := ethernet | none,
                       lladdr := <<_:48>> | none,
                       mtu := 68..65535,
                       state := up | down,
                       tx_limit := pos_integer()}.

-doc """
What a transport makes of a message from its medium: a batch of frames, a link change,
room to transmit again, or a frame it dropped, by reason (`too_long`, `stranger`,
`malformed`).
""".
-type event() :: {frames, [binary() | {Zone :: term(), binary()}]}
               | {link, up | down}
               | writable
               | {dropped, Reason :: atom()}.

-callback init(Config :: map()) -> {ok, link_info(), T :: term()} | ignore | {error, Reason :: term()}.
-callback event(Msg :: term(), T) -> {[event()], T} when T :: term().
-callback transmit(erx_net_frame:frame(), T) -> {ok | full | {drop, Reason :: atom()}, T}
    when T :: term().

-record(state, {transport :: module(),
                t :: term(),
                info :: link_info(),
                tx :: erx_net_credit:credit(),
                iface = none :: none | {pid(), reference(), erx_net_credit:credit()},
                backlog = queue:new() :: queue:queue(erx_net_frame:frame()),
                blocked = false :: boolean(),
                latest :: up | down,     % the transport's link state
                told :: up | down,       % the last state the interface was told
                armed = infinity :: erx_net_clock:armed(),
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

-doc "The driver's drop counters, by reason.".
-spec counters(pid()) -> #{atom() => pos_integer()}.
counters(Driver) ->
    gen_server:call(Driver, counters, infinity).

%% --- gen_server ------------------------------------------------------------------

-doc false.
init({Name, Transport, Config}) ->
    case Transport:init(Config) of
        {ok, #{state := Link, tx_limit := Limit} = Info, T} ->
            ok = erx_net_tables:register_driver(Name, self()),
            {ok, #state{transport = Transport, t = T, info = Info,
                        tx = erx_net_credit:new(Limit), latest = Link, told = Link}};
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
handle_info(Msg, S0) ->
    {noreply, tell_link(message(Msg, S0))}.

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

message({transmit, Frames}, #state{backlog = Backlog} = S) when is_list(Frames) ->
    drain(S#state{backlog = queue:join(Backlog, queue:from_list(Frames))});
message({erx_net_clock, hint}, S) ->
    S#state{armed = infinity};
message({'DOWN', Ref, process, _, _}, #state{iface = {_, Ref, _}} = S) ->
    S#state{iface = none};
message(Msg, #state{transport = Transport, t = T0} = S) ->
    {Events, T} = Transport:event(Msg, T0),
    lists:foldl(fun event/2, S#state{t = T}, Events).

event({frames, []}, S) ->
    S;
event({frames, Frames}, #state{iface = none} = S) ->
    count(detached, length(Frames), S);
event({frames, Frames}, #state{iface = {Pid, _, Rx}} = S) ->
    case erx_net_credit:hand(Pid, Rx, length(Frames), {frames, self(), Frames}) of
        ok -> S;
        full -> count(no_room, length(Frames), S)
    end;
event({link, State}, S) when State =:= up; State =:= down ->
    S#state{latest = State};
event(writable, S) ->
    drain(S#state{blocked = false});
event({dropped, Reason}, S) when is_atom(Reason) ->
    count(Reason, 1, S).

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

count(Reason, N, #state{counters = Counters} = S) ->
    S#state{counters = maps:update_with(Reason, fun(C) -> C + N end, N, Counters)}.

demonitor_iface(none) -> true;
demonitor_iface({_, Ref, _}) -> erlang:demonitor(Ref, [flush]).
