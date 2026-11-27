%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_fs).
-moduledoc """
The Bluetooth domain's file service (docs/design-bluetooth.md, "The pairing window",
"Concurrency"): the process, registered as `erx_bt_fs`, that serves the control tree
through `erx_fs` grants of `erx_bt_fs_tree`, keeps its waiting reads and runs the
window's core, `erx_bt_window`. The core decides; this process does the effects: the
clock, one wake-up timer at the core's deadline, the monitors of links and of the grants
that opened `pair`, the messages to links, the log and the answers to the grants.

What reaches it:

* from a grant of the tree, the calls of `pair`'s open, first write and clunk, each
  answered at once, and its reads, which wait for a line as waiting requests the
  process keeps in an `erx_fs_waits` set (docs/design-files.md, "Waiting requests").
  After every step the waiting reads are offered the lines, in the order they came.
  A grant that ends closes every open it made, as its clunks would;
* from a link, `{erx_bt_link, Link, Message}` (docs/design-bluetooth.md, "The link's
  messages"), answered by `{window, Answer}` to the link's pid; an `open` verdict
  carries the pairing's fresh values (`erx_smp_crypto:fresh/0`), drawn here, so the
  core stays pure;
* from the store, `{outcome, Link, Tag, Outcome}`, the answer to a pairing's `keep`, and
  `{store, read}` once it has confirmed a `forget`, which ends a refusal since the
  store's start;
* a monitored link's `'DOWN'`.

**The tree's grants are the mint's** (docs/design-bluetooth.md, "The control tree"). The
mint of `bluetooth`, `erx_bt_tree_mint` (start_mint/0), starts with `erx_bt_top`, before
init's ready report, while this process starts with the rest of the stack after it; the
mint's mount, mounted/0, waits for the message this process sends it once its start has
taken the store's state, and every grant of the tree serves from the pid it carries. This
process is a temporary, `significant` child of `erx_bt_sup`, so its end ends the domain,
and the mount links the mint to it, so its end ends the mint and every grant even before
that: no grant ever holds the pid of a window process that has ended. It registers
before it takes the store's state, so a `forget` the store
confirms after that reaches it as `{store, read}`, and one confirmed before is in the
state it takes.

The core's lines may hold a passkey and its verdicts carry fresh values, so a crash
report and `sys:get_status/1` show the core's `facts/1` alone.
""".
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("erx_fs_waits.hrl").

-export([start_link/0, start_mint/0, mounted/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-record(fs, {core :: erx_bt_window:core(),
             links = #{} :: #{pid() => reference()},              % the monitored links
             opens = #{} :: #{reference() => erx_bt_window:id()}, % a monitor of each open's grant
             timer = none :: none | {reference(), integer()},
             waits = erx_fs_waits:new() :: erx_fs_waits:waits()}).

-doc """
Starts the service under `erx_bt_sup`, after the store, registered as `erx_bt_fs`, over the
state the store answers once the name is taken (`erx_bt_store:known/0`), and tells the
tree's mint its pid.
""".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Starts the mint of the control tree, the service `bluetooth`, below `erx_bt_top` from the
boot script, registered as `erx_bt_tree_mint`, the name this process tells its pid to.
The mint names itself the service's mint and returns before it runs mounted/0.
""".
-spec start_mint() -> {ok, pid()}.
start_mint() ->
    {ok, Mint} = erx_fs_mint:start_link(bluetooth, erx_bt_fs_tree, fun mounted/0),
    true = register(erx_bt_tree_mint, Mint),
    {ok, Mint}.

-doc """
The tree's mount, run in the mint's process: the pid of this service, which the mint's
grants serve from, once its start has sent it as `{erx_bt_fs, Pid}`, linked to the mint,
so the window's end ends the mint and every grant with it whatever restarts the
supervisors allow. A mint request that comes first waits in the mint's queue.
""".
-spec mounted() -> pid().
mounted() ->
    receive {erx_bt_fs, Pid} when is_pid(Pid) -> link(Pid), Pid end.

%% gen_server registers the name before init/1 runs, so the store's notice of a forget
%% confirmed after known/0 answers finds this process. The mint is erx_bt_top's, so it
%% is there whenever erx_bt_sup runs; a host test that runs the service alone has none,
%% and the send to its name reaches no one.
-doc false.
init([]) ->
    Core = erx_bt_window:new(erx_bt_store:known()),
    {erx_bt_tree_mint, node()} ! {erx_bt_fs, self()},
    {ok, #fs{core = Core}}.

%% An open is named by the opening grant and a reference, and its grant is monitored, so
%% a grant's end closes it.
-doc false.
handle_call({open, Grant}, _From, Fs) when is_pid(Grant) ->
    Id = {Grant, make_ref()},
    case step({open, Id}, Fs) of
        {ok, #fs{opens = Opens} = Opened} ->
            {reply, {ok, Id}, Opened#fs{opens = Opens#{monitor(process, Grant) => Id}}};
        {Refused, Same} ->
            {reply, Refused, Same}
    end;
handle_call({write, Id, Mode}, _From, Fs) ->
    {Answer, Next} = step({write, Id, Mode}, Fs),
    {reply, Answer, Next};
handle_call({clunk, Id}, _From, #fs{opens = Opens} = Fs) ->
    [demonitor(Monitor, [flush]) || {Monitor, Open} <- maps:to_list(Opens), Open =:= Id],
    {_, Next} = step({clunk, Id}, Fs#fs{opens = maps:filter(fun(_, Open) -> Open =/= Id end, Opens)}),
    {reply, ok, Next};
handle_call(_Request, _From, Fs) ->
    {reply, {error, einval}, Fs}.

-doc false.
handle_cast(_Request, Fs) ->
    {noreply, Fs}.

-doc false.
handle_info(Message, Fs) ->
    {noreply, event(Message, Fs)}.

%% The state shows as the core's facts; a message, which may be a link's passkey, as its
%% kind alone; and the log of sys events, which holds messages, as empty.
-doc false.
format_status(Status) ->
    erx_report:status(Status, #{state => fun window_facts/1, message => fun link_kind/1}).

window_facts(#fs{core = Core}) -> erx_bt_window:facts(Core);
window_facts(_State) -> hidden.

link_kind({erx_bt_link, Link, Message}) ->
    {erx_bt_link, Link, erx_report:reason_name(Message)};
link_kind(_Message) ->
    hidden.

%% ---------------------------------------------------------------------------
%% Events
%% ---------------------------------------------------------------------------

event({erx_bt_link, Link, Message}, Fs) when is_pid(Link) ->
    stepped({link, Link, Message}, Fs);
event({outcome, Link, Tag, Outcome}, Fs) ->
    stepped({store, {outcome, Link, Tag, Outcome}}, Fs);
event({store, read}, Fs) ->
    stepped({store, read}, Fs);
event({timeout, Timer, wake}, #fs{timer = {Timer, _}} = Fs) ->
    stepped(expired, Fs#fs{timer = none});
event({'DOWN', Monitor, process, Pid, _} = Down, #fs{links = Links, opens = Opens} = Fs) ->
    case {Links, Opens} of
        {#{Pid := Monitor}, _} -> stepped({down, Pid}, Fs#fs{links = maps:remove(Pid, Links)});
        {_, #{Monitor := Id}} -> stepped({clunk, Id}, Fs#fs{opens = maps:remove(Monitor, Opens)});
        _ -> waits(Down, Fs)
    end;
event(?ERX_FS_WAIT(Wait, {read, _Id, _Count} = Read), #fs{waits = Waits} = Fs) ->
    pump(Fs#fs{waits = erx_fs_waits:hold(?ERX_FS_WAIT(Wait, Read), Waits)});
event(Message, Fs) ->
    waits(Message, Fs).

waits(Message, #fs{waits = Waits} = Fs) ->
    case erx_fs_waits:info(Message, Waits) of
        {flushed, Settled} -> Fs#fs{waits = Settled};
        %% A read is never begun: it is answered in the step that takes its bytes.
        {dropped, Dropped} -> Fs#fs{waits = Dropped};
        %% A late timer, a demonitored link's or grant's end, or a stranger's message.
        unknown -> Fs
    end.

stepped(Input, Fs) ->
    {_, Next} = step(Input, Fs),
    Next.

%% One step of the core and its effects: the file request's answer is returned, the
%% rest done here, then the waiting reads offered the lines and the timer set.
step(Input, #fs{core = Core} = Fs) ->
    {Actions, Stepped} = erx_bt_window:step(Input, clock(), Core),
    {Answer, Done} = lists:foldl(fun perform/2, {none, Fs#fs{core = Stepped}}, Actions),
    {Answer, wake_up(pump(Done))}.

perform({answer, Answer}, {_, Fs}) ->
    {Answer, Fs};
perform({open, Link, Tag, Mode}, Acc) ->
    Link ! {window, {admission, Tag, {open, Mode, erx_smp_crypto:fresh()}}},
    Acc;
perform({send, Link, Message}, Acc) ->
    Link ! {window, Message},
    Acc;
perform({monitor, Link}, {Answer, #fs{links = Links} = Fs}) ->
    {Answer, Fs#fs{links = Links#{Link => monitor(process, Link)}}};
perform({demonitor, Link}, {Answer, #fs{links = Links} = Fs}) ->
    {Monitor, Rest} = maps:take(Link, Links),
    demonitor(Monitor, [flush]),
    {Answer, Fs#fs{links = Rest}};
perform({log, #{address := Address, outcome := Outcome}}, Acc) ->
    ?LOG_NOTICE(#{what => bt_pairing, address => Address, outcome => Outcome}),
    Acc.

%% Each waiting read, in the order it came, takes what its open has: lines, or the end
%% of the file once they are read; a read whose open has no line yet waits.
pump(#fs{waits = Waits} = Fs) ->
    lists:foldl(fun offer/2, Fs, [{Wait, Id, Count} || {Wait, {read, Id, Count}, waiting} <- erx_fs_waits:list(Waits)]).

offer({Wait, Id, Count}, #fs{core = Core, waits = Waits} = Fs) ->
    case erx_bt_window:take(Id, Count, Core) of
        {none, _} -> Fs;
        {eof, Same} -> Fs#fs{core = Same, waits = erx_fs_waits:answer(Wait, {ok, <<>>}, Waits)};
        {{ok, Bytes}, Taken} -> Fs#fs{core = Taken, waits = erx_fs_waits:answer(Wait, {ok, Bytes}, Waits)}
    end.

%% One wake-up timer, at the core's next deadline.
wake_up(#fs{core = Core, timer = Timer} = Fs) ->
    case {erx_bt_window:next_deadline(Core), Timer} of
        {Deadline, {_, Deadline}} ->
            Fs;
        {Deadline, _} ->
            cancel(Timer),
            Fs#fs{timer = arm(Deadline)}
    end.

arm(infinity) -> none;
arm(Deadline) -> {erlang:start_timer(Deadline, self(), wake, [{abs, true}]), Deadline}.

cancel(none) -> ok;
cancel({Timer, _}) -> _ = erlang:cancel_timer(Timer), ok.

clock() -> erlang:monotonic_time(millisecond).
