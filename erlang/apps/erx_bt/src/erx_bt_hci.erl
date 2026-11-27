%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_hci).
-moduledoc """
The controller process (docs/design-bluetooth.md, "The controller process's effects"): a
loop around `erx_bt_hci_core`, started last in the controller group. It turns each message
into one input, reads the clock, steps the core and performs the actions in order; a stop
ends it, and the group's restart resets the line and the controller.

- **Configuration.** At its start it builds the core's configuration from owners that
  outlive the group: the connection limit from `erx_bt`'s application keys, the identity
  address from `erx_bt_store`, and the advertising data from `erx_bt_adv:data/1` of what
  the registry advertises, `erx_gatt_srv:advertised/0`: the service UUIDs, the name and
  the appearance. Then it steps `start`, whose one action is `line_reset`.
- **The line.** Items go to the writer, `erx_bt_line_tx`, whose answers, `written` and
  `line_ready`, are inputs. Stepping `line_ready` gives the reader, `erx_bt_line_rx`, its
  first acknowledgement; each read's bytes are appended to what the last split left, split
  with `erx_h4:split/1`, decoded with `erx_hci` and stepped packet by packet, and then
  acknowledged. A split error stops the process.
- **Links.** `link_up` starts a temporary `erx_bt_link` under `erx_bt_link_sup` with a fresh
  `Conn`, monitors it and maps the link's full name to it; `to_link` goes as `{hci, Event}`, the
  role the link knows the controller process by, to the process a
  name maps to, and is dropped for a name that maps to none; `link_down` removes
  the name and ends its process. A link process that ends while its name is mapped is its
  disconnect: the name is removed and `{request, Name, {disconnect, 16#13}}`, Remote User
  Terminated Connection, is stepped. A link's requests, its `taken` included, are stepped
  as they come.
  Names are unique only within one run of the core, so names, never handles, are mapped,
  and every link is in the group, which ends with the core.
- **Time.** One wake-up timer, at the core's deadline, is only a hint: `expired` changes
  nothing before the deadline, so a stale or early wake-up costs one look.
""".
-behaviour(gen_server).

-include("generated/erx_abi.hrl").

-export([start_link/0, facts/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-record(hci, {
    core :: erx_bt_hci_core:core(),
    rest = <<>> :: binary(),                   % the incomplete packet the last split left
    links = #{} :: #{erx_bt_hci_core:link() => pid()},
    monitors = #{} :: #{reference() => erx_bt_hci_core:link()},
    timer = none :: none | {reference(), erx_bt_hci_core:time()},
    ready = none :: none | map()               % the bring-up's facts, for /proc/bt
}).

-doc "Starts the controller process, last in the controller group.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "For `/proc/bt`: the core's facts and the bring-up's, `none` before `ready`.".
-spec facts() -> #{core := map(), ready := none | map()}.
facts() ->
    gen_server:call(?MODULE, facts).

init([]) ->
    Core = erx_bt_hci_core:new(config()),
    steps([start], #hci{core = Core}).

%% The core's configuration (docs/design-bluetooth.md, "The controller process's effects",
%% "Configuration").
config() ->
    Data = erx_bt_adv:data(erx_gatt_srv:advertised()),
    Data#{connections => application:get_env(erx_bt, connections, 1), address => erx_bt_store:address(),
          patch => patch(application:get_env(erx_bt, patch))}.

%% The patch the row names, read whole by erx_bt_patch, with the manufacturer it applies
%% to; a file the reader refuses ends the process before the line is touched.
patch(undefined) ->
    none;
patch({ok, File}) ->
    {ok, Manufacturer} = application:get_env(erx_bt, patch_manufacturer),
    case erx_bt_patch:records(File) of
        {ok, Records} -> #{manufacturer => Manufacturer, records => Records};
        {error, Reason} -> exit({patch_refused, File, Reason})
    end.

handle_info({erx_bt_line_tx, Answer}, State) when Answer =:= written; Answer =:= line_ready ->
    step_noreply(Answer, State);
handle_info({erx_bt_line_rx, Bytes}, #hci{rest = Rest} = State) ->
    case erx_h4:split(<<Rest/binary, Bytes/binary>>) of
        {error, Reason} ->
            {stop, {h4, Reason}, State};
        {Packets, Left} ->
            case steps([input(Packet) || Packet <- Packets], State#hci{rest = Left}) of
                {ok, Stepped} ->
                    erx_bt_line_rx ! {read, self()},
                    {noreply, Stepped};
                {stop, Reason} ->
                    {stop, Reason, State}
            end
    end;
handle_info({erx_bt_link, Name, Request}, State) ->
    step_noreply({request, Name, Request}, State);
%% The registry's word that the advertised services changed (docs/design-bluetooth.md,
%% "Advertising"): the scan response, the name and the appearance, does not change.
handle_info({advertised, Input}, State) ->
    #{advertising_data := Data} = erx_bt_adv:data(Input),
    step_noreply({advertising_data, Data}, State);
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, #hci{monitors = Monitors, links = Links} = State) ->
    case maps:take(Monitor, Monitors) of
        {Name, Rest} ->
            Ended = State#hci{monitors = Rest, links = maps:remove(Name, Links)},
            step_noreply({request, Name, {disconnect, ?ERX_HCI_DISCONNECT_REASON_REMOTE_USER_TERMINATED}}, Ended);
        error ->
            {noreply, State}
    end;
handle_info({timeout, Timer, wake}, #hci{timer = {Timer, _Deadline}} = State) ->
    step_noreply(expired, State#hci{timer = none});
handle_info(_Message, State) ->
    {noreply, State}.

handle_call(facts, _From, #hci{core = Core, ready = Ready} = State) ->
    {reply, #{core => erx_bt_hci_core:facts(Core), ready => Ready}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

%% A crash report shows sizes, never a packet's or a peer's bytes: the last read and
%% the incomplete packet are untrusted, and from pairing on they may carry keys. A link's
%% request shows as its kind alone: a packet carries a peer's data, and a Long Term Key
%% reply the key. The core shows as its facts, since its plan holds the patch's records,
%% the vendor's firmware, and its replies and command slot a key.
format_status(Status) ->
    erx_report:status(Status, #{state => fun hci_facts/1, message => fun message_kind/1}).

hci_facts(#hci{core = Core, rest = Rest} = State) ->
    erx_report:fields(State, [{#hci.core, {facts, erx_bt_hci_core:facts(Core)}},
                              {#hci.rest, erx_report:bytes(Rest)}]);
hci_facts(_State) ->
    hidden.

message_kind({erx_bt_line_rx, Bytes}) when is_binary(Bytes) -> {erx_bt_line_rx, erx_report:bytes(Bytes)};
message_kind({erx_bt_link, Name, Request}) -> {erx_bt_link, Name, erx_report:reason_name(Request)};
message_kind(_Message) -> hidden.

%% A packet from the controller as the core's input.
input({event, Code, Parameters}) -> {event, erx_hci:event(Code, Parameters)};
input({acl, Handle, Boundary, Broadcast, Data}) -> {acl, Handle, Boundary, Broadcast, Data}.

step_noreply(Input, State) ->
    case steps([Input], State) of
        {ok, Stepped} -> {noreply, Stepped};
        {stop, Reason} -> {stop, Reason, State}
    end.

%% Steps each input in order at the clock, performing its actions through
%% erx_actions:perform/3, where a stop, always the last, ends the process; then sets the
%% wake-up timer at the core's deadline.
steps([], State) ->
    {ok, wake_up(State)};
steps([Input | Inputs], #hci{core = Core} = State) ->
    {Next, Actions} = erx_bt_hci_core:step(Input, erlang:monotonic_time(millisecond), Core),
    case erx_actions:perform(Actions, fun perform/2, State#hci{core = Next}) of
        {continue, Performed} -> steps(Inputs, after_input(Input, Performed));
        {stop, Reason, _Performed} -> {stop, Reason}
    end.

%% The line's reset answered: the reader's first acknowledgement.
after_input(line_ready, State) ->
    erx_bt_line_rx ! {read, self()},
    State;
after_input(_Input, State) ->
    State.

perform(line_reset, State) ->
    erx_bt_line_tx ! {line_reset, self()},
    State;
perform({write, Bytes}, State) ->
    erx_bt_line_tx ! {write, self(), Bytes},
    State;
perform({ready, Facts}, State) ->
    State#hci{ready = Facts};
perform({link_up, Name, Info}, #hci{links = Links, monitors = Monitors} = State) ->
    {ok, Pid} = erx_bt_link_sup:start_child(#{name => Name, conn => make_ref(), info => Info, hci => self()}),
    State#hci{links = Links#{Name => Pid}, monitors = Monitors#{monitor(process, Pid) => Name}};
perform({to_link, Name, Event}, State) ->
    to_link(Name, Event, State);
perform({link_down, Name}, #hci{links = Links, monitors = Monitors} = State) ->
    case maps:take(Name, Links) of
        {Pid, Rest} ->
            [Monitor] = [M || M := N <- Monitors, N =:= Name],
            demonitor(Monitor, [flush]),
            _ = erx_bt_link_sup:stop_link(Pid),
            State#hci{links = Rest, monitors = maps:remove(Monitor, Monitors)};
        error ->
            State
    end.

%% An action for a name that maps to no process is dropped: its link has already ended.
to_link(Name, Event, #hci{links = Links} = State) ->
    case Links of
        #{Name := Pid} -> erx_bt_link:hci(Pid, Event);
        #{} -> ok
    end,
    State.

%% One timer, at the core's deadline; a timer at another deadline is cancelled.
wake_up(#hci{core = Core, timer = Timer} = State) ->
    case {erx_bt_hci_core:next_deadline(Core), Timer} of
        {Deadline, {_Ref, Deadline}} ->
            State;
        {Deadline, _} ->
            cancel(Timer),
            State#hci{timer = arm(Deadline)}
    end.

arm(infinity) -> none;
arm(Deadline) -> {erlang:start_timer(Deadline, self(), wake, [{abs, true}]), Deadline}.

cancel(none) -> ok;
cancel({Ref, _Deadline}) -> _ = erlang:cancel_timer(Ref), ok.
