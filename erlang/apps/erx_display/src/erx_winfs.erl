%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_winfs).
-moduledoc """
The window system of a display (docs/design-display.md, "Windows and the
window system" and "The window tree"): the mint of the display's service,
of the `windows` interface, whose name is the display's; the keeper of the
window table; and the `erx_fs` callback module of the tree each client's
grant serves.

**The process.** One plain `proc_lib` process, registered as `erx_winfs`,
not a `gen_server`: the system domain holds its pid as the service's mint,
and a `gen_server` would act on a `system` message from it. It takes:

* a mint request in the system domain's envelope (mint_request/3), which
  it answers with a grant of the client's directory, started with
  `erx_fs:start_link/4` under its own `erx_fs_grants` supervisor of
  per-grant trees; at the mint it opens the client's pixel area and keeps
  it for the grant, and when the grant ends it drops the area and ends
  the grant's windows;
* calls of its own domain's processes, in `gen_server`'s call shape: the
  tree's callbacks, which run in the grants, and
  attach/2, the screen's;
* shown/1's notices from the screen of what each answered frame shows,
  which the input router takes;
* input/2's records, the `DOWN`s of its grants, holders, screen and
  input sources, its repeat timer, and the `EXIT`s of its window
  processes, its grants' supervisor and its parent.

A message from another domain arrives only in the envelope
`{erx_origin, D, Msg}`, so a bare call shape is always of this domain;
every other message is dropped.

**The table.** The windows in stacking order, topmost first, each an
`erx_wm:window()` with its holder, its grant and its holder's monitor.
Every change goes through the policy (`erx_wm`), and after every change
each window whose rectangle or state moved is told so. After every
message the layout, the shown windows, topmost first, with their
decorations, is derived from the table and the policy's state together
and handed to the screen when it differs from the one last handed, so a
pick that changes no table still moves the border. `erx_winfs` calls the policy's arrange/4 after every change
it makes itself, and whenever the session it derives differs from the one
it last passed, so the table always holds the policy's answer for the
current session.

**Input.** A driver calls input/2, which returns once the record is
routed, so each source has at most one record waiting here. Each record,
a source's end and a timer's tick is stamped with this process's
monotonic clock in milliseconds and stepped by the router's core,
erx_input, which alone asks the policy about input; this process
performs its answers: an event cast to a window process, a window
ended, a new table committed, the one repeat timer replaced. It monitors each source from
its first record, so a source's end releases what it held, and tells the
screen of each record first, for its idle clock.

**The session.** The display's session is derived, never stored apart from
the grants: the client directory of the live grant most recently minted
with `session` set, or `none`.

**The front mark.** A window's `front` is its grant's `front` limit,
recorded in its row when the window is made; a grant's limits do not
change while it lives and its windows end with it, so the mark never
goes stale.

**The tree.** A grant's root is its client's directory, named by the
grantee's domain id in decimal, and lists the client's windows by the
names the client chose and, when the grant's limits carry `clipboard`, the
file `clipboard`; a window's directory lists `ctl`, `mouse`, `kbd`, `wctl` and
`label`. A node is `root`, `clipboard`, `{window, Id, Proc}` or
`{file, Id, Proc, File}`, made by this module from the table, never from
client bytes: a name is looked up, never turned into an atom. `wctl`
writes come here; every other file of a window is its window process's
(erx_window). A window that has ended answers `EIO`. It is a made tree:
its attributes, its statfs and its listings, each taken by a directory's
open, are erx_fs_node's.

**The clipboard.** The file `clipboard` (docs/design-display.md, "The
clipboard") is one buffer of this process, which every grant carrying
`clipboard` reads and writes and no other grant can walk to. Each write is
applied here, whole or not at all.
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([start_link/1, start_link/3, attach/2, shown/1, input/2, mint_request/3]).
%% The process.
-export([winfs_init/2, loop/1]).
%% The erx_fs callbacks of the tree.
-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4, statfs/1,
         clunk/2, write/4, make/4, unlink/4]).

-define(ID_MAX, 16#7fffffff).
-define(READ_ONLY, [mouse, kbd]).
%% The tree's own name for the clipboard, which no window takes.
-define(CLIPBOARD, <<"clipboard">>).

%% A window policy: its window manager module and that module's configuration.
-type policy() :: {module(), map()}.

-type options() :: #{service := atom(),
                     system := pos_integer(),
                     exports := module(),
                     minted := fun((pos_integer(), term()) -> term()),
                     area := fun((pos_integer()) -> {ok, term(), pos_integer()} | {error, term()}),
                     clients := domain | own,
                     provide := boolean(),
                     policy := policy(),
                     palette => erx_theme:palette(),
                     input => erx_input:config()}.

%% The input router's configuration when the options name none: the layout us,
%% FreeBSD's normal repeat of 500 and 126 milliseconds, and no reserved chord.
-define(INPUT, #{keymap => us, repeat_delay => 500, repeat_period => 126, chord => none}).

-record(winfs, {options :: options(),
                parent :: pid(),
                grants_sup :: pid(),
                policy :: module(),
                policy_state :: term(),
                %% The input router's state, each input source's monitor and the
                %% repeat timer erx_input last asked for.
                input :: erx_input:state(),
                sources = #{} :: #{pid() => reference()},
                timer = none :: none | reference(),
                %% Each live grant: its client directory, pixel area, windows
                %% quota, session mark, mint order and monitor.
                grants = #{} :: #{pid() => map()},
                windows = [] :: [map()],
                %% The session last passed to the policy.
                session = none :: binary() | none,
                chan = none :: none | binary(),
                depth = none :: none | pos_integer(),
                screen = none :: none | {pid(), reference()},
                %% The layout last handed to the screen.
                layout = [] :: erx_screen_core:layout(),
                next_id = 1 :: pos_integer(),
                %% The display's clipboard.
                clipboard = <<>> :: binary(),
                minted = 0 :: non_neg_integer()}).

%% The process ---------------------------------------------------------------

-doc """
Starts the display domain's window system linked to the caller, started by
`erx_fb_sup`: the mint of Service, the display's service, under Policy, the
window manager and its configuration, and Palette, the palette the
display's windows are drawn in, with the domain's own system id, export
table, mint answer and pixel areas, and the default input router.
""".
-spec start_link(atom(), policy(), erx_theme:palette()) -> {ok, pid()} | {error, term()}.
start_link(Service, Policy, Palette) when is_atom(Service) ->
    start_link(#{service => Service, system => erx_kernel_records:system_domain(), exports => erx_dist,
                 minted => fun erx_facet:minted/2, area => fun erx_area:open/1,
                 clients => domain, provide => true, policy => Policy, palette => Palette}).

-doc """
Starts the window system linked to the caller with Options: `service`, the
service whose mint requests it grants; `system`, the system domain's id;
`exports`, the export table grants export themselves through; `minted`, how
a mint is answered; `area`, how a client's pixel area is opened; `clients`,
`domain` for grants bound to their grantee's domain, or `own` for a host
test's grants of this domain; `provide`, whether it names itself the mint;
`policy`, the window policy and its configuration; `palette`, the palette
its windows' `ctl` names, the theme's first when the options name none; and
`input`, the input
router's configuration (erx_input:new/1). The display domain's router has
the layout `us`, FreeBSD's `normal` repeat of 500 and 126 milliseconds and
no reserved chord.
""".
-spec start_link(options()) -> {ok, pid()} | {error, term()}.
start_link(#{service := Service} = Options) when is_atom(Service) ->
    proc_lib:start_link(?MODULE, winfs_init, [self(), Options]).

-doc false.
winfs_init(Parent, #{service := Service, policy := {Policy, Config}} = Options) ->
    true = register(?MODULE, self()),
    process_flag(trap_exit, true),
    {ok, Sup} = erx_fs_grants:start_link(?MODULE),
    ok = case Options of
             #{provide := true} -> erx_facet:provide(Service, self());
             #{} -> ok
         end,
    State = #winfs{options = Options, parent = Parent, grants_sup = Sup, policy = Policy,
                   policy_state = Policy:init(Config),
                   input = erx_input:new(maps:get(input, Options, ?INPUT))},
    proc_lib:init_ack(Parent, {ok, self()}),
    loop(State).

-doc """
For `erx_screen` at its start: hands the input router the screen of
rectangle Rect and channel Chan, arranges the table for it once the router
has taken it, and answers the layout; `[]` with no window system, for a
channel erx_chan does not parse, or when the router refuses the rectangle
(an empty one), and in both refusals the old screen stays.
""".
-spec attach(erx_wm:rect(), binary()) -> erx_screen_core:layout().
attach(Rect, Chan) ->
    case call_winfs({attach, Rect, Chan}) of
        {ok, Layout} -> Layout;
        {error, _} -> []
    end.

-doc """
For `erx_screen`, when the driver takes a frame: hands the input router
the windows that frame shows, `{shown, Shown}`. Asynchronous, so the
screen waits on nothing; a notice naming a screen other than the one
attached, as one sent before that screen ended, is dropped, and so is
every notice with no window system. With no screen, and from a new
screen's attach until its first frame is taken, the router holds no
window displayed.
""".
-spec shown(erx_input:displayed()) -> ok.
shown(Shown) ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> Pid ! {shown, self(), Shown}, ok
    end.

-doc """
For an input driver: routes one record of its device, named Device in the
device table, and returns once it is routed; dropped with no window
system. The caller is the record's source.
""".
-spec input(binary(), erx_input:record()) -> ok.
input(Device, Record) ->
    _ = call_winfs({input, Device, Record}),
    ok.

-doc """
What the mint of the service Service does with Message, in a domain whose
system domain's id is System: a mint request of Service in the system
domain's envelope with a positive tag, a domain id as its grantee and a map
of limits is granted; anything else, a request of another service among
them, is unknown and dropped.
""".
-spec mint_request(pos_integer(), atom(), term()) -> {grant, pos_integer(), pos_integer(), map()} | unknown.
mint_request(System, Service, {erx_origin, System, {erx_facet_mint, Tag, Service, Grantee, _Principal, Limits}})
  when is_integer(Tag), Tag > 0, is_integer(Grantee), Grantee > 0, is_map(Limits) ->
    {grant, Tag, Grantee, Limits};
mint_request(_System, _Service, _Message) ->
    unknown.

%% Each message is handled whole, and the next is awaited through a remote call,
%% so the process moves to newly loaded code between messages.
-doc false.
%% After each message the layout is derived and handed to the screen when it changed, before
%% a call is answered, so a client that hears its wctl write answered presents into the
%% layout that write made.
loop(#winfs{options = #{system := System, service := Service}, parent = Parent, grants_sup = Sup} = State) ->
    {Next, Reply} =
        receive
            {erx_origin, System, _} = Message ->
                {mint(mint_request(System, Service, Message), State), noreply};
            {'$gen_call', {Pid, _} = From, Request} when is_pid(Pid) ->
                {Answer, Called} = handle_call(Request, Pid, State),
                {Called, {From, Answer}};
            {shown, Screen, Shown} ->
                {take_shown(Screen, Shown, State), noreply};
            {timeout, Timer, erx_input_tick} when Timer =:= State#winfs.timer ->
                {route({tick, now_ms()}, State#winfs{timer = none}), noreply};
            {'DOWN', Ref, process, Pid, _} ->
                {down(Ref, Pid, State), noreply};
            {'EXIT', Parent, Reason} ->
                exit(Reason);
            {'EXIT', Sup, Reason} ->
                exit(Reason);
            {'EXIT', Pid, Reason} ->
                {window_exit(Pid, Reason, State), noreply};
            _ ->
                {State, noreply}
        end,
    Presented = present(Next),
    ok = case Reply of
             {To, Answer1} -> gen_server:reply(To, Answer1);
             noreply -> ok
         end,
    ?MODULE:loop(Presented).

%% A local call with no timeout: erx_winfs calls no process that calls it, so no
%% cycle of waits exists. A window system that has ended answers eio.
call_winfs(Request) ->
    case whereis(?MODULE) of
        undefined -> {error, eio};
        Pid -> call(Pid, Request)
    end.

call(Pid, Request) ->
    try gen_server:call(Pid, Request, infinity)
    catch exit:_ -> {error, eio}
    end.

%% Mints ---------------------------------------------------------------------

mint(unknown, State) ->
    State;
mint({grant, Tag, Grantee, Limits}, #winfs{options = #{minted := Minted}} = State) ->
    {Reply, Next} = grant(Grantee, Limits, State),
    _ = Minted(Tag, Reply),
    with_session(Next).

grant(Grantee, Limits, #winfs{options = Options, grants_sup = Sup, minted = Minted} = State) ->
    Windows = maps:get(windows, Limits, ?ERX_WINDOWS_DEFAULT),
    Session = maps:get(session, Limits, false),
    HasClipboard = maps:get(clipboard, Limits, false),
    Front = maps:get(front, Limits, false),
    case is_integer(Windows) andalso Windows >= 0 andalso is_boolean(Session) andalso is_boolean(HasClipboard)
        andalso is_boolean(Front) of
        false ->
            {{error, einval}, State};
        true ->
            Client = integer_to_binary(Grantee),
            case binding(Grantee, Options) of
                {ok, Binding} ->
                    case erx_fs_grants:grant(Sup, #{winfs => self(), client => Client,
                                                    clipboard => HasClipboard},
                                             Limits, Binding) of
                        {ok, Grant, Tree} ->
                            Record = #{client => Client, area => area(Grantee, Options),
                                       windows => Windows, session => Session, front => Front,
                                       minted => Minted + 1,
                                       monitor => erlang:monitor(process, Grant)},
                            {{ok, Grant, Tree}, State#winfs{grants = (State#winfs.grants)#{Grant => Record},
                                                      minted = Minted + 1}};
                        {error, _} = Refused ->
                            {Refused, State}
                    end;
                {error, _} = Refused ->
                    {Refused, State}
            end
    end.

%% A grant for the system domain lives as long as this domain; any other grantee's
%% ends with this domain's connection to it, which must be up. A host test's grants
%% are of this domain.
binding(_Grantee, #{clients := own, exports := Exports}) ->
    {ok, #{client => own, ends_with => none, exports => Exports}};
binding(System, #{system := System, exports := Exports}) ->
    {ok, #{client => System, ends_with => none, exports => Exports}};
binding(Grantee, #{exports := Exports}) ->
    case erx_connections:connection(Grantee) of
        {ok, Connection} -> {ok, #{client => Grantee, ends_with => Connection, exports => Exports}};
        {error, _} = Refused -> Refused
    end.

area(Grantee, #{area := Open}) ->
    case Open(Grantee) of
        {ok, Area, Bytes} when is_integer(Bytes), Bytes > 0 -> {Area, Bytes};
        _ -> none
    end.

%% The client directory of the live grant most recently minted with session set.
derived_session(Grants) ->
    case lists:sort([{Minted, Client} || #{session := true, minted := Minted, client := Client}
                                             <- maps:values(Grants)]) of
        [] -> none;
        Marked -> element(2, lists:last(Marked))
    end.

%% Arranges the table whenever the derived session differs from the one last passed.
with_session(#winfs{grants = Grants, session = Last} = State) ->
    case derived_session(Grants) of
        Last -> State;
        Session -> arrange(State#winfs{session = Session})
    end.

%% Calls ---------------------------------------------------------------------

handle_call({attach, Rect, Chan}, Pid, State) ->
    case erx_chan:parse(Chan) of
        {ok, _Code, Depth} -> attach_screen(Rect, Chan, Depth, Pid, State);
        _ -> {{error, einval}, State}
    end;
handle_call({walk, Client, Name}, _Pid, State) ->
    {case find(Client, Name, State) of
         {ok, #{id := Id, proc := Proc}} -> {ok, Id, Proc};
         error -> {error, enoent}
     end, State};
handle_call({list, Client}, _Pid, #winfs{windows = Windows} = State) ->
    {{ok, lists:sort([{Id, Name, Proc} || #{id := Id, dir := {C, Name}, proc := Proc} <- Windows,
                                          C =:= Client])}, State};
handle_call({make, Grant, Client, Name, Owner}, _Pid, State) ->
    make_window(Grant, Client, Name, Owner, State);
%% Expect is the id the remover's fid named, or any for a remove by name alone, so a fid
%% left on a removed window never removes a later window of the same name.
handle_call({remove, Client, Name, Expect}, _Pid, State) ->
    case find(Client, Name, State) of
        {ok, #{id := Id}} when Expect =:= any; Expect =:= Id -> {ok, arrange(end_window(Id, State))};
        _ -> {{error, enoent}, State}
    end;
handle_call({wctl, Client, Id, Bytes}, _Pid, State) ->
    place_request(Client, Id, Bytes, State);
handle_call(clipboard_empty, _Pid, State) ->
    {ok, State#winfs{clipboard = <<>>}};
handle_call({clipboard_read, Offset, Count}, _Pid, #winfs{clipboard = Clipboard} = State) ->
    {{ok, clipboard_part(Clipboard, Offset, Count)}, State};
handle_call({clipboard_write, Offset, Data}, _Pid, #winfs{clipboard = Clipboard} = State) ->
    case clipboard_written(Clipboard, Offset, Data) of
        {ok, Written} -> {ok, State#winfs{clipboard = Written}};
        {error, _} = Refused -> {Refused, State}
    end;
handle_call({input, Device, Record}, Pid, #winfs{sources = Sources, screen = Screen} = State)
  when is_binary(Device) ->
    Monitored = case Sources of
                    #{Pid := _} -> State;
                    #{} -> State#winfs{sources = Sources#{Pid => erlang:monitor(process, Pid)}}
                end,
    ok = case Screen of
             {ScreenPid, _} -> gen_server:cast(ScreenPid, input);
             none -> ok
         end,
    {ok, route({record, Pid, Device, now_ms(), Record}, Monitored)};
handle_call(_Request, _Pid, State) ->
    {{error, einval}, State}.

find(Client, Name, #winfs{windows = Windows}) ->
    case [W || W = #{dir := {C, N}} <- Windows, C =:= Client, N =:= Name] of
        [W] -> {ok, W};
        [] -> error
    end.

%% The router is handed the screen first and alone decides whether it is one: taken, the
%% table is arranged for it and the attacher becomes the screen; refused, as an empty
%% rectangle is, the old screen stays and the router has counted the drop. The router
%% holds none only before the first screen, so none is never a screen taken.
attach_screen(Rect, Chan, Depth, Pid, #winfs{screen = Old} = State) ->
    Routed = route({screen, Rect}, State),
    case screen_rect(Routed) of
        Rect when Rect =/= none ->
            ok = demonitor_screen(Old),
            %% A new screen starts at the splash, which shows no window.
            Blank = route({shown, []}, Routed),
            Arranged = arrange(Blank#winfs{chan = Chan, depth = Depth, screen = none}),
            Layout = layout(Arranged),
            {{ok, Layout}, Arranged#winfs{screen = {Pid, erlang:monitor(process, Pid)},
                                          layout = Layout}};
        _Kept ->
            {{error, einval}, Routed}
    end.

demonitor_screen(none) -> ok;
demonitor_screen({_Pid, Ref}) -> true = erlang:demonitor(Ref, [flush]), ok.

%% The clipboard's bytes from Offset, at most Count of them, copied so that the reply
%% holds no reference to the whole buffer.
clipboard_part(Clipboard, Offset, Count) ->
    Size = byte_size(Clipboard),
    From = min(Offset, Size),
    binary:copy(binary:part(Clipboard, From, min(Count, Size - From))).

%% The clipboard with Data in place at Offset, zeros in any hole between its end and
%% Offset, or efbig when that would take it past its bound. A write of no bytes
%% changes nothing.
clipboard_written(Clipboard, _Offset, <<>>) ->
    {ok, Clipboard};
clipboard_written(Clipboard, Offset, Data) ->
    Size = byte_size(Clipboard),
    End = Offset + byte_size(Data),
    case max(Size, End) =< ?ERX_WINDOWS_CLIPBOARD_BYTES of
        true ->
            Head = binary:part(Clipboard, 0, min(Offset, Size)),
            Hole = binary:copy(<<0>>, max(0, Offset - Size)),
            Tail = binary:part(Clipboard, min(End, Size), Size - min(End, Size)),
            {ok, <<Head/binary, Hole/binary, Data/binary, Tail/binary>>};
        false ->
            {error, efbig}
    end.

%% A mkdir in a client's directory: the window takes the next id and the mkdir's
%% Owner as its holder, within its grant's windows quota.
make_window(Grant, Client, Name, Owner, #winfs{grants = Grants} = State) ->
    case Grants of
        #{Grant := #{client := Client} = Record} when is_pid(Owner) ->
            case refusal(Grant, Record, Name, State) of
                ok -> new_window(Grant, Record, Name, Owner, State);
                Refusal -> {{error, Refusal}, State}
            end;
        #{} ->
            {{error, eio}, State}
    end.

new_window(Grant, #{client := Client, area := Area, front := Front}, Name, Owner, State) ->
    #winfs{next_id = Id, chan = Chan, depth = Depth, windows = Windows,
           policy = Policy, policy_state = PolicyState, session = Session} = State,
    Screen = screen_rect(State),
    Palette = maps:get(palette, State#winfs.options, hd(erx_theme:palettes())),
    {ok, Proc} = erx_window:start_link(#{id => Id, chan => Chan, depth => Depth, palette => Palette,
                                         area => Area}),
    Row = #{id => Id, dir => {Client, Name}, front => Front, holder => Owner, rect => Screen, state => hidden,
            proc => Proc, grant => Grant, monitor => erlang:monitor(process, Owner)},
    Next = State#winfs{next_id = Id + 1},
    ok = log_ids_spent(Id),
    case Policy:place(new, Id, [Row | Windows], Screen, Session, PolicyState) of
        {ok, Table, PolicyState1} ->
            {{ok, Id, Proc}, commit(Table, Next#winfs{windows = [Row | Windows],
                                                       policy_state = PolicyState1}, [Id])};
        {error, einval} ->
            {{error, einval}, end_window(Id, Next#winfs{windows = [Row | Windows]})}
    end.

%% Why a mkdir may not make its window, or ok. The name is looked up before any limit,
%% as FreeBSD's mkdir finds an existing name before it checks a quota.
refusal(Grant, #{client := Client, windows := Quota}, Name,
        #winfs{next_id = Id, windows = Windows} = State) ->
    Screen = screen_rect(State),
    Held = length([W || W = #{grant := G} <- Windows, G =:= Grant]),
    Exists = Name =:= ?CLIPBOARD orelse find(Client, Name, State) =/= error,
    if
        Screen =:= none -> eio;
        Exists -> eexist;
        Id > ?ID_MAX -> enospc;
        Held >= Quota -> edquot;
        true -> ok
    end.

%% Each id is issued once, so the last one is issued once, and the line saying the
%% display's ids are spent is written once with no flag to keep.
log_ids_spent(?ID_MAX) ->
    _ = erx_log:debug(["erx_winfs: window ids are spent; every later mkdir fails with ENOSPC"]),
    ok;
log_ids_spent(_Id) ->
    ok.

%% A wctl write: the parsed command is a place request, which the policy may refuse.
place_request(Client, Id, Bytes, State) ->
    #winfs{windows = Windows, session = Session, policy = Policy,
           policy_state = PolicyState} = State,
    Screen = screen_rect(State),
    case {erx_wctl:parse(Bytes), [W || W = #{id := I, dir := {C, _}} <- Windows, I =:= Id, C =:= Client]} of
        {{ok, Command}, [_]} when Screen =/= none ->
            case Policy:place(Command, Id, Windows, Screen, Session, PolicyState) of
                {ok, Table, PolicyState1} -> {ok, commit(Table, State#winfs{policy_state = PolicyState1})};
                {error, einval} -> {{error, einval}, State}
            end;
        {{ok, _}, []} ->
            {{error, eio}, State};
        _ ->
            {{error, einval}, State}
    end.

%% Input ---------------------------------------------------------------------

%% One step of the router over the table as it stands, and its answers performed in order.
route(In, #winfs{windows = Windows, session = Session, policy = Policy,
                 policy_state = PolicyState, input = Input} = State) ->
    View = #{windows => Windows, session => Session, policy => Policy, policy_state => PolicyState},
    {Input1, Outs} = erx_input:step(In, View, Input),
    lists:foldl(fun perform/2, State#winfs{input = Input1}, Outs).

perform({policy_state, PolicyState}, State) ->
    State#winfs{policy_state = PolicyState};
perform({to, Id, Event}, #winfs{windows = Windows} = State) ->
    _ = [gen_server:cast(Proc, {input, Event}) || #{id := I, proc := Proc} <- Windows, I =:= Id],
    State;
perform({windows, Table}, State) ->
    commit(Table, State);
perform({delete, Id}, State) ->
    arrange(end_window(Id, State));
perform({wm, _Term}, State) ->
    State;
perform({wake, At}, #winfs{timer = Old} = State) ->
    ok = case Old of
             none -> ok;
             _ -> erlang:cancel_timer(Old, [{async, true}, {info, false}])
         end,
    State#winfs{timer = case At of
                            none -> none;
                            _ -> erlang:start_timer(At, self(), erx_input_tick, [{abs, true}])
                        end}.

%% What the attached screen's taken frame shows goes to the router; a notice naming any
%% other process, as a screen that has since ended, is dropped.
take_shown(Screen, Shown, #winfs{screen = {Screen, _}} = State) ->
    route({shown, Shown}, State);
take_shown(_Screen, _Shown, State) ->
    State.

now_ms() -> erlang:monotonic_time(millisecond).

%% Ends ----------------------------------------------------------------------

down(Ref, Pid, #winfs{screen = {Pid, Ref}} = State) ->
    %% With no screen no window is displayed.
    route({shown, []}, State#winfs{screen = none});
down(Ref, Pid, #winfs{sources = Sources} = State) when map_get(Pid, Sources) =:= Ref ->
    route({gone, Pid, now_ms()}, State#winfs{sources = maps:remove(Pid, Sources)});
down(Ref, Pid, #winfs{grants = Grants, windows = Windows} = State) ->
    case Grants of
        #{Pid := #{monitor := Ref}} ->
            %% The grant's area goes with its record; the collection releases it once
            %% its windows, which hold it too, have ended.
            Ended = lists:foldl(fun end_window/2,
                                State#winfs{grants = maps:remove(Pid, Grants)},
                                [Id || #{id := Id, grant := G} <- Windows, G =:= Pid]),
            Next = with_session(arrange(Ended)),
            true = erlang:garbage_collect(),
            Next;
        #{} ->
            case [Id || #{id := Id, holder := H, monitor := R} <- Windows, H =:= Pid, R =:= Ref] of
                [Id] -> arrange(end_window(Id, State));
                [] -> State
            end
    end.

window_exit(Pid, Reason, #winfs{windows = Windows} = State) ->
    case [Id || #{id := Id, proc := P} <- Windows, P =:= Pid] of
        [Id] ->
            _ = erx_log:debug(["erx_winfs: window ", integer_to_binary(Id), " ended: ",
                               io_lib:format("~0P", [Reason, 8])]),
            arrange(end_window(Id, State));
        [] ->
            State
    end.

%% Removes window Id from the table and ends its process; the caller arranges.
end_window(Id, #winfs{windows = Windows} = State) ->
    case [W || W = #{id := I} <- Windows, I =:= Id] of
        [#{proc := Proc, monitor := Ref}] ->
            true = erlang:demonitor(Ref, [flush]),
            true = unlink(Proc),
            true = exit(Proc, shutdown),
            receive {'EXIT', Proc, _} -> ok after 0 -> ok end,
            State#winfs{windows = [W || W = #{id := I} <- Windows, I =/= Id]};
        [] ->
            State
    end.

%% The table ------------------------------------------------------------------

%% The screen is the router's: it alone decides what it takes as one, so the table and
%% the policy's input see the same screen.
screen_rect(#winfs{input = Input}) ->
    erx_input:screen(Input).

arrange(#winfs{windows = Windows, session = Session, policy = Policy,
               policy_state = PolicyState} = State) ->
    case screen_rect(State) of
        none ->
            State;
        Screen ->
            {Table, PolicyState1} = Policy:arrange(Windows, Screen, Session, PolicyState),
            commit(Table, State#winfs{policy_state = PolicyState1})
    end.

%% Takes the policy's table: each window whose rectangle or state changed is told; the
%% loop hands the screen the layout. The policy keeps every field it does not
%% set, so a table that lost or gained a window is a policy's error and is refused
%% whole, keeping the old one.
commit(Table, State) ->
    commit(Table, State, []).

%% New names the windows just added, which are told their place whatever it is.
commit(Table, #winfs{windows = Old} = State, New) ->
    case lists:sort([Id || #{id := Id} <- Table]) =:= lists:sort([Id || #{id := Id} <- Old]) of
        true ->
            Before = maps:from_list([{Id, {R, S}} || #{id := Id, rect := R, state := S} <- Old]),
            _ = [gen_server:cast(Proc, {placed, R, S})
                 || #{id := Id, rect := R, state := S, proc := Proc} <- Table,
                    maps:get(Id, Before, none) =/= {R, S} orelse lists:member(Id, New)],
            State#winfs{windows = Table};
        false ->
            _ = erx_log:debug(["erx_winfs: the policy changed the table's windows"]),
            State
    end.

%% Hands the screen the layout when it differs from the one last handed: the layout is a
%% function of the table and the policy's state, so a pick that changes no table still
%% moves the border.
present(#winfs{screen = {Pid, _}, layout = Last} = State) ->
    case layout(State) of
        Last ->
            State;
        Layout ->
            ok = gen_server:cast(Pid, {layout, Layout}),
            State#winfs{layout = Layout}
    end;
present(#winfs{screen = none} = State) ->
    State.

%% The shown windows, topmost first, with their decorations.
layout(#winfs{windows = Windows, policy = Policy, policy_state = PolicyState} = State) ->
    Decorations = maps:from_list(Policy:decorate(Windows, screen_rect(State), PolicyState)),
    [#{id => Id, proc => Proc, rect => Rect, decorations => maps:get(Id, Decorations, [])}
     || #{id := Id, proc := Proc, rect := Rect, state := shown} <- Windows].

%% The tree ------------------------------------------------------------------

-doc false.
init(#{winfs := Winfs, client := Client, clipboard := HasClipboard})
  when is_pid(Winfs), is_binary(Client), is_boolean(HasClipboard) ->
    {ok, #{winfs => Winfs, client => Client, clipboard => HasClipboard, grant => self()}}.

-doc false.
root(_Fs) ->
    {ok, ?ERX_WINDOWS_TREE_BYTES, root, qid(root)}.

-doc false.
walk(root, ?CLIPBOARD, #{clipboard := true}) ->
    {ok, clipboard, qid(clipboard)};
walk(root, Name, #{winfs := Winfs, client := Client}) ->
    case call(Winfs, {walk, Client, Name}) of
        {ok, Id, Proc} -> {ok, {window, Id, Proc}, qid({window, Id, Proc})};
        {error, _} = Error -> Error
    end;
walk({window, Id, Proc}, Name, _Fs) ->
    case lists:keyfind(Name, 1, files()) of
        {Name, File, _} -> {ok, {file, Id, Proc, File}, qid({file, Id, Proc, File})};
        false -> {error, enoent}
    end;
walk({file, _, _, _}, _Name, _Fs) ->
    {error, enotdir}.

-doc false.
getattr({file, _, _, File} = Node, _Fs) -> erx_fs_node:attr(qid(Node), file, file_mode(File));
getattr(clipboard, _Fs) -> erx_fs_node:attr(qid(clipboard), file, 8#600);
getattr(Node, _Fs) -> erx_fs_node:attr(qid(Node), dir, 8#700).

file_mode(File) ->
    case lists:member(File, ?READ_ONLY) of
        true -> 8#400;
        false -> 8#600
    end.

%% A directory opens for reading only, as FreeBSD's open of one for writing fails with
%% EISDIR, and its open takes its listing (erx_fs_node:listing/1): the client's windows
%% at the root, a window's files in its directory.
-doc false.
open({file, _, _, File} = Node, Flags, _Fs) ->
    case lists:member(File, ?READ_ONLY) andalso Flags band ?ERX_P9_O_ACCMODE =/= 0 of
        true -> {error, eacces};
        false -> {ok, Node}
    end;
open(clipboard, Flags, #{winfs := Winfs}) ->
    case clipboard_open(Flags) of
        keep -> {ok, clipboard};
        empty -> maybe ok ?= call(Winfs, clipboard_empty), {ok, clipboard} end;
        refused -> {error, einval}
    end;
open(Dir, Flags, Fs) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> listing(Dir, Fs);
        _ -> {error, eisdir}
    end.

%% The root lists the file clipboard first when the grant carries it, then the client's
%% windows.
listing(root, #{winfs := Winfs, client := Client, clipboard := HasClipboard}) ->
    Entry = case HasClipboard of
                true -> [{qid(clipboard), ?ERX_P9_DT_REG, ?CLIPBOARD}];
                false -> []
            end,
    case call(Winfs, {list, Client}) of
        {ok, Windows} ->
            {ok, erx_fs_node:listing(Entry ++ [{qid({window, Id, Proc}), ?ERX_P9_DT_DIR, Name}
                                               || {Id, Name, Proc} <- Windows])};
        {error, _} = Error ->
            Error
    end;
listing({window, Id, Proc}, _Fs) ->
    {ok, erx_fs_node:listing([{qid({file, Id, Proc, File}), ?ERX_P9_DT_REG, Name}
                              || {Name, File, _} <- files()])}.

%% What an open of the file clipboard with Flags does to the clipboard: an open for writing with
%% O_TRUNC empties it, and access mode 3, which names no access, and O_APPEND, which the
%% clipboard does not keep, are refused.
clipboard_open(Flags) ->
    Access = Flags band ?ERX_P9_O_ACCMODE,
    Append = Flags band ?ERX_P9_O_APPEND =/= 0,
    Truncate = Flags band ?ERX_P9_O_TRUNC =/= 0,
    if
        Access =:= ?ERX_P9_O_ACCMODE; Append -> refused;
        Access =/= 0, Truncate -> empty;
        true -> keep
    end.

%% A read of mouse or kbd waits for a record, so the window process is its keeper
%% (docs/design-files.md, "Serving: the `erx_fs` behaviour", "Waiting requests").
-doc false.
read({file, _Id, Proc, File}, _Offset, Count, _Fs) when File =:= mouse; File =:= kbd ->
    {wait, Proc, {read, File, Count}};
read({file, _Id, Proc, File}, Offset, Count, _Fs) ->
    call(Proc, {read, File, Offset, Count});
read(clipboard, Offset, Count, #{winfs := Winfs}) ->
    call(Winfs, {clipboard_read, Offset, Count});
read({entries, _}, _Offset, _Count, _Fs) ->
    {error, eisdir}.

-doc false.
readdir(Handle, Offset, Max, _Fs) ->
    erx_fs_node:readdir(Handle, Offset, Max).

-doc false.
statfs(_Fs) ->
    erx_fs_node:statfs(?ERX_P9_MAGIC_RAMFS).

-doc false.
clunk(_Handle, _Fs) ->
    ok.

-doc false.
write({file, Id, _Proc, wctl}, Offset, Data, #{winfs := Winfs, client := Client}) ->
    written(call(Winfs, {wctl, Client, Id, Data}), Offset, Data);
write({file, _Id, Proc, ctl}, Offset, Data, _Fs) ->
    %% A present waits for the screen, so the window process keeps the write.
    {wait, Proc, {write, ctl, Offset, Data}};
write({file, _Id, Proc, File}, Offset, Data, _Fs) ->
    written(call(Proc, {write, File, Offset, Data}), Offset, Data);
write(clipboard, Offset, Data, #{winfs := Winfs}) ->
    written(call(Winfs, {clipboard_write, Offset, Data}), Offset, Data);
write({entries, _}, _Offset, _Data, _Fs) ->
    {error, eisdir}.

%% A write's answer names the offset its bytes were written at.
written(ok, Offset, Data) -> {ok, byte_size(Data), Offset};
written({error, _} = Error, _Offset, _Data) -> Error.

%% A create of the file clipboard opens it (erx_fs_node:open_by_create/4); every other
%% create in the root is a mkdir, which makes a window.
-doc false.
make(root, ?CLIPBOARD, {file, _Mode, Flags}, #{clipboard := true} = Fs) ->
    erx_fs_node:open_by_create(clipboard, qid(clipboard), Flags,
                               fun(F) -> open(clipboard, F, Fs) end);
make(root, Name, {directory, _Mode, Owner}, #{winfs := Winfs, client := Client, grant := Grant}) ->
    case call(Winfs, {make, Grant, Client, Name, Owner}) of
        {ok, Id, Proc} -> {ok, {window, Id, Proc}, qid({window, Id, Proc})};
        {error, _} = Error -> Error
    end;
make(_Dir, _Name, _What, _Fs) ->
    {error, eperm}.

-doc false.
unlink(root, ?CLIPBOARD, directory, #{clipboard := true}) ->
    {error, enotdir};
unlink(root, ?CLIPBOARD, _Kind, #{clipboard := true}) ->
    {error, eperm};
unlink(root, Name, directory, #{winfs := Winfs, client := Client}) ->
    call(Winfs, {remove, Client, Name, any});
unlink(root, Name, {node, {window, Id, _}}, #{winfs := Winfs, client := Client}) ->
    call(Winfs, {remove, Client, Name, Id});
unlink(root, _Name, {node, _}, _Fs) ->
    {error, enoent};
unlink(root, _Name, file, _Fs) ->
    {error, eisdir};
unlink(_Dir, _Name, _Kind, _Fs) ->
    {error, eperm}.

%% Paths: the root 0, clipboard 1, a window's directory its id times 8, and each of its
%% files that plus the file's number; ids start at 1, so no window's path is 1.
qid(root) -> {?ERX_P9_QTDIR, 0, 0};
qid(clipboard) -> {0, 0, 1};
qid({window, Id, _}) -> {?ERX_P9_QTDIR, 0, Id * 8};
qid({file, Id, _, File}) ->
    {File, N} = lists:keyfind(File, 1, ?ERX_WINDOWS_FILE_MEMBERS),
    {0, 0, Id * 8 + N}.

%% A window's files as the ABI's windows_file lists them: each name, the file and its
%% number.
files() -> [{atom_to_binary(File), File, N} || {File, N} <- ?ERX_WINDOWS_FILE_MEMBERS].
