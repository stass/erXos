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
  tree's callbacks, which run in the grants and their file processes, and
  attach/2, the screen's;
* input/1's events, the `DOWN`s of its grants, holders and screen, and
  the `EXIT`s of its window processes, its grants' supervisor and its
  parent.

A message from another domain arrives only in the envelope
`{erx_origin, D, Msg}`, so a bare call shape is always of this domain;
every other message is dropped.

**The table.** The windows in stacking order, topmost first, each an
`erx_wm:window()` with its holder, its grant and its holder's monitor.
Every change goes through the policy (`erx_wm`), and after every change
each window whose rectangle or state moved is told so, and the screen is
handed the layout: the shown windows, topmost first, with their
decorations. `erx_winfs` calls the policy's arrange/4 after every change
it makes itself, and whenever the session it derives differs from the one
it last passed, so the table always holds the policy's answer for the
current session.

**The session.** The display's session is derived, never stored apart from
the grants: the client directory of the live grant most recently minted
with `session` set, or `none`.

**The tree.** A grant's root is its client's directory, named by the
grantee's domain id in decimal, and lists the client's windows by the
names the client chose; a window's directory lists `ctl`, `mouse`, `kbd`,
`wctl` and `label`. A node is `root`, `{window, Id, Proc}` or
`{file, Id, Proc, File}`, made by this module from the table, never from
client bytes: a name is looked up, never turned into an atom. `wctl`
writes come here; every other file is its window process's
(erx_window). A window that has ended answers `EIO`.
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([start_link/1, attach/2, input/1, mint_request/3]).
%% The process.
-export([winfs_init/2, loop/1]).
%% The erx_fs callbacks of the tree.
-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4, statfs/1,
         clunk/2, write/4, make/4, unlink/4]).

-define(ID_MAX, 16#7fffffff).
-define(READ_ONLY, [mouse, kbd]).

-type options() :: #{service := atom(),
                     system := pos_integer(),
                     exports := module(),
                     minted := fun((pos_integer(), term()) -> term()),
                     area := fun((pos_integer()) -> {ok, term(), pos_integer()} | {error, term()}),
                     clients := domain | own,
                     provide := boolean(),
                     policy := {module(), map()}}.

-record(winfs, {options :: options(),
                parent :: pid(),
                grants_sup :: pid(),
                policy :: module(),
                policy_state :: term(),
                %% Each live grant: its client directory, pixel area, windows
                %% quota, session mark, mint order and monitor.
                grants = #{} :: #{pid() => map()},
                windows = [] :: [map()],
                %% The session last passed to the policy.
                session = none :: binary() | none,
                screen_rect = none :: none | erx_wm:rect(),
                chan = none :: none | binary(),
                depth = none :: none | pos_integer(),
                screen = none :: none | {pid(), reference()},
                next_id = 1 :: pos_integer(),
                minted = 0 :: non_neg_integer()}).

%% The process ---------------------------------------------------------------

-doc """
Starts the window system linked to the caller. Given an atom, Service,
it is this display domain's, started by `erx_fb_sup` under the single
policy, and names itself the mint of Service, the display's service. Given
Options: `service`, the service whose mint requests it grants; `system`,
the system domain's id; `exports`, the export table grants export
themselves through; `minted`, how a mint is answered; `area`, how a
client's pixel area is opened;
`clients`, `domain` for grants bound to their grantee's domain, or `own`
for a host test's grants of this domain; `provide`, whether it names
itself the mint; and `policy`, the window policy and its configuration.
""".
-spec start_link(atom() | options()) -> {ok, pid()} | {error, term()}.
start_link(Service) when is_atom(Service) ->
    start_link(#{service => Service, system => erx_kernel_records:system_domain(), exports => erx_dist,
                 minted => fun erx_facet:minted/2, area => fun erx_area:open/1,
                 clients => domain, provide => true, policy => {erx_wm_single, #{}}});
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
                   policy_state = Policy:init(Config)},
    proc_lib:init_ack(Parent, {ok, self()}),
    loop(State).

-doc """
For `erx_screen` at its start: records the screen of rectangle Rect and
channel Chan, arranges the table for it, and answers the layout; `[]` with
no window system.
""".
-spec attach(erx_wm:rect(), binary()) -> erx_screen_core:layout().
attach(Rect, Chan) ->
    case call_winfs({attach, Rect, Chan}) of
        {ok, Layout} -> Layout;
        {error, _} -> []
    end.

-doc "Routes one input event through the policy; dropped with no window system.".
-spec input(erx_wm:input()) -> ok.
input(Input) ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> Pid ! {erx_winfs_input, Input}, ok
    end.

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
loop(#winfs{options = #{system := System, service := Service}, parent = Parent, grants_sup = Sup} = State) ->
    receive
        {erx_origin, System, _} = Message ->
            ?MODULE:loop(mint(mint_request(System, Service, Message), State));
        {'$gen_call', {Pid, _} = From, Request} when is_pid(Pid) ->
            {Reply, Next} = handle_call(Request, Pid, State),
            gen_server:reply(From, Reply),
            ?MODULE:loop(Next);
        {erx_winfs_input, Input} ->
            ?MODULE:loop(route(Input, State));
        {'DOWN', Ref, process, Pid, _} ->
            ?MODULE:loop(down(Ref, Pid, State));
        {'EXIT', Parent, Reason} ->
            exit(Reason);
        {'EXIT', Sup, Reason} ->
            exit(Reason);
        {'EXIT', Pid, Reason} ->
            ?MODULE:loop(window_exit(Pid, Reason, State));
        _ ->
            ?MODULE:loop(State)
    end.

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
    case is_integer(Windows) andalso Windows >= 0 andalso is_boolean(Session) of
        false ->
            {{error, einval}, State};
        true ->
            Client = integer_to_binary(Grantee),
            case binding(Grantee, Options) of
                {ok, Binding} ->
                    case erx_fs_grants:grant(Sup, #{winfs => self(), client => Client}, Limits, Binding) of
                        {ok, Grant} ->
                            Record = #{client => Client, area => area(Grantee, Options),
                                       windows => Windows, session => Session,
                                       minted => Minted + 1,
                                       monitor => erlang:monitor(process, Grant)},
                            {{ok, Grant}, State#winfs{grants = (State#winfs.grants)#{Grant => Record},
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

handle_call({attach, Rect, Chan}, Pid, #winfs{screen = Old} = State) ->
    case erx_chan:parse(Chan) of
        {ok, _Code, Depth} when tuple_size(Rect) =:= 4 ->
            ok = demonitor_screen(Old),
            Arranged = arrange(State#winfs{screen_rect = Rect, chan = Chan, depth = Depth,
                                           screen = none}),
            Screen = {Pid, erlang:monitor(process, Pid)},
            {{ok, layout(Arranged)}, Arranged#winfs{screen = Screen}};
        _ ->
            {{error, einval}, State}
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
handle_call(_Request, _Pid, State) ->
    {{error, einval}, State}.

find(Client, Name, #winfs{windows = Windows}) ->
    case [W || W = #{dir := {C, N}} <- Windows, C =:= Client, N =:= Name] of
        [W] -> {ok, W};
        [] -> error
    end.

demonitor_screen(none) -> ok;
demonitor_screen({_Pid, Ref}) -> true = erlang:demonitor(Ref, [flush]), ok.

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

new_window(Grant, #{client := Client, area := Area}, Name, Owner, State) ->
    #winfs{next_id = Id, chan = Chan, depth = Depth, screen_rect = Screen, windows = Windows,
           policy = Policy, policy_state = PolicyState, session = Session} = State,
    {ok, Proc} = erx_window:start_link(#{id => Id, chan => Chan, depth => Depth, area => Area}),
    Row = #{id => Id, dir => {Client, Name}, holder => Owner, rect => Screen, state => hidden,
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
        #winfs{screen_rect = Screen, next_id = Id, windows = Windows} = State) ->
    Held = length([W || W = #{grant := G} <- Windows, G =:= Grant]),
    Exists = find(Client, Name, State) =/= error,
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
    #winfs{windows = Windows, screen_rect = Screen, session = Session, policy = Policy,
           policy_state = PolicyState} = State,
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

%% The screen hears of the event first, for its idle clock; then the policy routes it.
route(Input, #winfs{windows = Windows, session = Session, policy = Policy,
                    policy_state = PolicyState, screen = Screen} = State) ->
    ok = case Screen of
             {Pid, _} -> gen_server:cast(Pid, input);
             none -> ok
         end,
    {Route, PolicyState1} = Policy:input(Input, Windows, Session, PolicyState),
    Next = State#winfs{policy_state = PolicyState1},
    case Route of
        {to, Id, Event} ->
            _ = [gen_server:cast(Proc, {input, Event}) || #{id := I, proc := Proc} <- Windows, I =:= Id],
            Next;
        {windows, Table} ->
            commit(Table, Next);
        {wm, _} ->
            Next;
        drop ->
            Next
    end.

%% Ends ----------------------------------------------------------------------

down(Ref, Pid, #winfs{screen = {Pid, Ref}} = State) ->
    State#winfs{screen = none};
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

arrange(#winfs{screen_rect = none} = State) ->
    State;
arrange(#winfs{windows = Windows, screen_rect = Screen, session = Session, policy = Policy,
               policy_state = PolicyState} = State) ->
    {Table, PolicyState1} = Policy:arrange(Windows, Screen, Session, PolicyState),
    commit(Table, State#winfs{policy_state = PolicyState1}).

%% Takes the policy's table: each window whose rectangle or state changed is told,
%% and the screen is handed the layout. The policy keeps every field it does not
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
            Next = State#winfs{windows = Table},
            ok = case Next#winfs.screen of
                     {Pid, _} -> gen_server:cast(Pid, {layout, layout(Next)});
                     none -> ok
                 end,
            Next;
        false ->
            _ = erx_log:debug(["erx_winfs: the policy changed the table's windows"]),
            State
    end.

%% The shown windows, topmost first, with their decorations.
layout(#winfs{windows = Windows, screen_rect = Screen, policy = Policy}) ->
    Decorations = maps:from_list(Policy:decorate(Windows, Screen)),
    [#{id => Id, proc => Proc, rect => Rect, decorations => maps:get(Id, Decorations, [])}
     || #{id := Id, proc := Proc, rect := Rect, state := shown} <- Windows].

%% The tree ------------------------------------------------------------------

-doc false.
init(#{winfs := Winfs, client := Client}) when is_pid(Winfs), is_binary(Client) ->
    {ok, #{winfs => Winfs, client => Client, grant => self()}}.

-doc false.
root(_Fs) ->
    {ok, ?ERX_WINDOWS_TREE_BYTES, root, qid(root)}.

-doc false.
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
getattr(Node, _Fs) ->
    {Kind, Mode} = case Node of
                       {file, _, _, File} -> {?ERX_P9_S_IFREG, file_mode(File)};
                       _ -> {?ERX_P9_S_IFDIR, 8#700}
                   end,
    {ok, #{valid => ?ERX_P9_GETATTR_MASK_MODE bor ?ERX_P9_GETATTR_MASK_NLINK
                        bor ?ERX_P9_GETATTR_MASK_SIZE,
           qid => qid(Node), mode => Kind bor Mode, uid => 0, gid => 0, nlink => 1,
           rdev => 0, size => 0, blksize => 4096, blocks => 0,
           atime_sec => 0, atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0,
           ctime_sec => 0, ctime_nsec => 0, btime_sec => 0, btime_nsec => 0,
           gen => 0, data_version => 0}}.

file_mode(File) ->
    case lists:member(File, ?READ_ONLY) of
        true -> 8#400;
        false -> 8#600
    end.

-doc false.
open({file, _, _, File} = Node, Flags, _Fs) ->
    case lists:member(File, ?READ_ONLY) andalso Flags band ?ERX_P9_O_ACCMODE =/= 0 of
        true -> {error, eacces};
        false -> {ok, Node}
    end;
open(Node, _Flags, _Fs) ->
    {ok, {dir, Node}}.

-doc false.
read({file, _Id, Proc, File}, Offset, Count, _Fs) ->
    call(Proc, {read, File, Offset, Count});
read({dir, _}, _Offset, _Count, _Fs) ->
    {error, eisdir}.

-doc false.
readdir({dir, root}, Offset, Max, #{winfs := Winfs, client := Client}) ->
    case call(Winfs, {list, Client}) of
        {ok, Windows} ->
            entries([{qid({window, Id, Proc}), ?ERX_P9_DT_DIR, Name} || {Id, Name, Proc} <- Windows],
                    Offset, Max);
        {error, _} = Error ->
            Error
    end;
readdir({dir, {window, Id, Proc}}, Offset, Max, _Fs) ->
    entries([{qid({file, Id, Proc, File}), ?ERX_P9_DT_REG, Name} || {Name, File, _} <- files()],
            Offset, Max);
readdir(_Handle, _Offset, _Max, _Fs) ->
    {error, enotdir}.

%% A listing's offset is the count of entries before it.
entries(All, Offset, Max) ->
    Numbered = lists:zip(lists:seq(1, length(All)), All),
    {ok, [{Qid, N, Type, Name} || {N, {Qid, Type, Name}} <- lists:sublist(Numbered, Offset + 1, Max)]}.

-doc false.
statfs(_Fs) ->
    {ok, #{type => 0, bsize => 4096, blocks => 0, bfree => 0, bavail => 0, files => 0,
           ffree => 0, fsid => 0, namelen => 255}}.

-doc false.
clunk(_Handle, _Fs) ->
    ok.

-doc false.
write({file, Id, _Proc, wctl}, Offset, Data, #{winfs := Winfs, client := Client}) ->
    written(call(Winfs, {wctl, Client, Id, Data}), Offset, Data);
write({file, _Id, Proc, File}, Offset, Data, _Fs) ->
    written(call(Proc, {write, File, Offset, Data}), Offset, Data);
write({dir, _}, _Offset, _Data, _Fs) ->
    {error, eisdir}.

written(ok, Offset, Data) -> {ok, byte_size(Data), Offset + byte_size(Data)};
written({error, _} = Error, _Offset, _Data) -> Error.

-doc false.
make(root, Name, {directory, _Mode, Owner}, #{winfs := Winfs, client := Client, grant := Grant}) ->
    case call(Winfs, {make, Grant, Client, Name, Owner}) of
        {ok, Id, Proc} -> {ok, {window, Id, Proc}, qid({window, Id, Proc})};
        {error, _} = Error -> Error
    end;
make(_Dir, _Name, _What, _Fs) ->
    {error, eperm}.

-doc false.
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

%% Paths: the root 0, a window's directory its id times 8, and each of its files
%% that plus the file's number.
qid(root) -> {?ERX_P9_QTDIR, 0, 0};
qid({window, Id, _}) -> {?ERX_P9_QTDIR, 0, Id * 8};
qid({file, Id, _, File}) ->
    {File, N} = lists:keyfind(File, 1, ?ERX_WINDOWS_FILE_MEMBERS),
    {0, 0, Id * 8 + N}.

%% A window's files as the ABI's windows_file lists them: each name, the file and its
%% number.
files() -> [{atom_to_binary(File), File, N} || {File, N} <- ?ERX_WINDOWS_FILE_MEMBERS].
