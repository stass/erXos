%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_link).
-moduledoc """
A link process, one for each connection the controller's core names: the effects around
`erx_bt_link_core` (docs/design-bluetooth.md, "One owner, one step" and "The link's
messages"). The controller process starts it as a temporary child of `erx_bt_link_sup` with
the link's name, its `Conn`, its `Info` (the phone's address and type from LE Connection
Complete, the identity address the controller advertises with, `acl_tx_max` and its share
of the controller's buffers) and the controller process's pid; it ends at `link_down`.

- **The start.** `init/1` reads only its argument, so the controller's synchronous
  `start_child` cannot fail in it. Before its first step the link makes its only two
  calls: `erx_bt_store:resolve/1` for the bond the phone's address names, and
  `erx_gatt_srv:join/2` for the table and the values the handlers last set; then
  `erx_bt_link_core:new/1` builds the core with the clock's reading as its `now`, so a
  resolved link's first wake-up asks the window for the pairing wait at once. What
  arrives meanwhile waits in the mailbox and is stepped in order after. A call that
  fails or is not answered within OTP's 5 s default ends the link, and the phone
  reconnects.
- **Inputs.** Each message is `{Role, Input}`, stepped as it arrives at the monotonic clock;
  the core's clauses alone say what each role may send, and a message none takes raises
  in the core and ends the link. The registry's notifications are requests of
  `gen_server:send_request/2`, stepped as `{registry, {notify, From, Kind, Key, Value}}`,
  so a link that ends first answers its caller through the request's monitor. One
  wake-up timer, at `next_deadline/1`, steps `expired`; the core changes nothing before
  its deadline, so a stale wake-up costs one look.
- **Actions.** `{hci, Message}` goes to the controller process as `{erx_bt_link, Name,
  Message}`; what goes to the window, the registry and the store is sent to its registered
  name as `{erx_bt_link, Pid, Message}`, where `Pid` is the link's own; a notification's
  answer goes to its `From`; a `close` ends the process with `{shutdown, Reason}`.
- **Its end.** A link's pid is its address: every owner that keeps it monitors the link
  and acts at its `'DOWN'`, so the link traps no exits, has no `terminate/2`, and a kill
  reaches the owners as any other end does.
- **Secrets.** The core holds the LTK and, while pairing, the private key, passkey and
  DHKey; the window's verdict carries the fresh values and the store's bond an LTK.
  `format_status/1` shows the core's `facts/1` and each message as its role and kind
  alone, and a raise in `step/3`, whose stack trace carries the core, ends the process
  with a reason built from `facts/1` alone. `sys:get_state/1` and sys tracing show the raw
  state and messages to whoever in the domain asks for them.
""".
-behaviour(gen_server).

-export([start_link/1, hci/2]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-record(link, {
    name :: erx_bt_hci_core:link(),
    conn :: reference(),
    hci :: pid(),
    core = starting :: starting | erx_bt_link_core:core(),  % secret: never shown, see format_status/1
    timer = none :: none | {reference(), erx_bt_link_core:time()}
}).

-doc "Starts a link; `erx_bt_link_sup`'s child start.".
-spec start_link(#{name := erx_bt_hci_core:link(), conn := reference(), info := map(), hci := pid()}) ->
          gen_server:start_ret().
start_link(Start) ->
    gen_server:start_link(?MODULE, Start, []).

-doc """
Sends `Event`, one of the controller's messages for a link, to the link process `Link`;
the controller process's one way to reach a link, so the envelope the core's `{hci, _}`
clauses take is written here alone.
""".
-spec hci(pid(), term()) -> ok.
hci(Link, Event) ->
    Link ! {hci, Event},
    ok.

init(#{name := Name, conn := Conn, info := Info, hci := Hci}) ->
    {ok, #link{name = Name, conn = Conn, hci = Hci}, {continue, {start, Info}}}.

%% The link's two calls, then its core. `Info` holds the phone's address as `erx_hci`
%% decodes it, `{public | random, Address}`, and the identity address the controller
%% advertises with.
handle_continue({start, Info}, #link{conn = Conn} = Link) ->
    #{peer := Address, identity := Identity, share := Share, acl_tx_max := AclTxMax} = Info,
    try
        Bond = called(store, fun() -> erx_bt_store:resolve(Address) end),
        #{table := Table, values := Values} = called(registry, fun() -> erx_gatt_srv:join(Conn, Address) end),
        Core = erx_bt_link_core:new(#{table => Table, values => Values, bond => Bond, share => Share,
                                      acl_tx_max => AclTxMax, now => erlang:monotonic_time(millisecond),
                                      addresses => #{central => Address, peripheral => {random, Identity}}}),
        {noreply, wake_up(Link#link{core = Core})}
    catch
        throw:{start, Owner} -> {stop, {shutdown, {start, Owner}}, Link};
        %% An answer new/1 does not take is a defect of the owner's, and its terms carry the
        %% bond's LTK: the reason names the class alone.
        Class:_Raised -> {stop, {start_raised, Class}, Link}
    end.

%% A call of the start, whose failure or timeout, an exit of gen_server:call/3, is thrown
%% as the owner's alone: its reason may carry the answer's terms.
called(Owner, Call) ->
    try Call()
    catch exit:_Reason -> throw({start, Owner})
    end.

handle_info({timeout, Timer, wake}, #link{timer = {Timer, _Deadline}} = Link) ->
    step(expired, Link#link{timer = none});
handle_info({timeout, _Stale, wake}, Link) ->
    {noreply, Link};
handle_info(Message, Link) ->
    step(Message, Link).

handle_call({notify, Kind, Key, Value}, From, Link) ->
    step({registry, {notify, From, Kind, Key, Value}}, Link);
%% Any other call or cast is wrapped in a label no clause of the core takes, so it ends the
%% link through step/2's raise; unwrapped, a call shaped `{hci, _}` would be stepped as a
%% controller message and its caller never answered.
handle_call(Request, _From, Link) ->
    step({call, Request}, Link).

handle_cast(Message, Link) ->
    step({cast, Message}, Link).

%% A crash report and sys:get_status/1 show the core's facts, never the core, and a
%% message as its role and kind alone: the window's verdict carries the fresh private key
%% and passkey, a peer's packet its data. The log of sys events holds messages too, so it
%% shows empty: gen_server's report formats a list there.
format_status(Status) ->
    erx_report:status(Status, #{state => fun link_facts/1, message => fun input_kind/1}).

link_facts(#link{name = Name, conn = Conn, core = Core}) -> #{name => Name, conn => Conn, core => facts(Core)};
link_facts(_State) -> hidden.

facts(starting) -> starting;
facts(Core) -> erx_bt_link_core:facts(Core).

input_kind({Role, Input}) when is_atom(Role) -> {Role, erx_report:reason_name(Input)};
input_kind(_Message) -> message.

%% Steps one input at the clock and performs its actions in order; a close, always last,
%% ends the process. A raise ends it with the facts of the core before the input, never
%% the raise's reason or stack trace, which carry the core.
step(Input, #link{core = Core} = Link) ->
    try erx_bt_link_core:step(Input, erlang:monotonic_time(millisecond), Core) of
        {Actions, Next} ->
            case erx_actions:perform(lists:map(fun close_to_stop/1, Actions), fun perform/2, Link#link{core = Next}) of
                {continue, Performed} -> {noreply, wake_up(Performed)};
                {stop, Reason, Performed} -> {stop, Reason, Performed}
            end
    catch
        Class:_Raised ->
            {stop, {step_raised, Class, erx_bt_link_core:facts(Core)}, Link}
    end.

%% A close is an end the core decided, often at a peer's misstep, not a crash: it ends the
%% process with a shutdown, so a peer that loses its link costs no error report
%% (docs/design-bluetooth.md, "What a radio peer can make the domain spend").
close_to_stop({close, Reason}) -> {stop, {shutdown, Reason}};
close_to_stop(Action) -> Action.

perform({hci, Message}, #link{hci = Hci, name = Name} = Link) ->
    Hci ! {?MODULE, Name, Message},
    Link;
perform({reply, From, Answer}, Link) ->
    gen_server:reply(From, Answer),
    Link;
perform({Role, Message}, Link) ->
    {owner(Role), node()} ! {?MODULE, self(), Message},
    Link.

%% The registered name of each owner the link sends to; one that is not running drops the
%% message, as a message to an ended process is dropped, and the owner's monitor is what
%% tells it of the link's end.
owner(window) -> erx_bt_fs;
owner(registry) -> erx_gatt_srv;
owner(store) -> erx_bt_store.

%% One wake-up timer, at the core's earliest deadline.
wake_up(#link{core = Core, timer = Timer} = Link) ->
    case {erx_bt_link_core:next_deadline(Core), Timer} of
        {Deadline, {_Ref, Deadline}} ->
            Link;
        {Deadline, _} ->
            cancel(Timer),
            Link#link{timer = arm(Deadline)}
    end.

arm(infinity) -> none;
arm(Deadline) -> {erlang:start_timer(Deadline, self(), wake, [{abs, true}]), Deadline}.

cancel(none) -> ok;
cancel({Ref, _Deadline}) -> _ = erlang:cancel_timer(Ref), ok.
