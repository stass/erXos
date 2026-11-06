%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The runtime's namespace from Erlang (design-files.md, Building, binding and mounting).
%% A change takes effect for every process of the domain at once and for no other domain.
%%
%% The table is one persistent term under the key erx_ns, which only this module's
%% process writes: a registered process that takes each mount, bind and unmount in
%% turn, checks it, builds the new table from the one the term holds and puts it, so
%% two changes never lose each other and a resolution reads the term without a copy or
%% a lock. Until the process writes a table the term is absent, and
%% prim_file:erx_table/0 answers the boot table. The changes are pure functions over a
%% table, change/2, which a session's handler can apply to a program's table as well.
%%
%% The process monitors every grant pid its table holds. When one ends, it rewrites
%% that pid's entries to the provider ended, which answers eio, and they stay until
%% they are unmounted, so a pid later given to another process never receives a
%% mounted path's requests. The monitors are its only state beyond the term: a
%% restarted process reads the term and monitors its grants again, and one that ended
%% meanwhile answers 'DOWN' at once.
%%
%% Each call answers ok or {error, Reason}: einval for a malformed path, place or
%% option, a mount point holding . or .., or an unmount where no entry is; enametoolong
%% beyond the bounds of a place; enoent for a source no entry holds; eexist for a point
%% that already has an entry; ebusy for unmounting /; and system_limit beyond the
%% table's 64 entries.

-module(erx_ns).

-behaviour(gen_server).

-export([start_link/0, start_link/1, mount/3, unmount/1, bind/2, bind/3, tmp_limit/0, change/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export_type([entry/0, table/0]).

-include("generated/erx_abi.hrl").

-type name() :: binary().
-type rights() :: ro | rw | rx.
-type provider() :: release | {grant, pid(), Tree :: name()} | ended.
-type entry() :: #{point := [name()], provider := provider(), root := [name()], rights := rights()}.
-type table() :: [entry()].
-type option() :: {tree, binary()} | rights().
-type reason() :: einval | enametoolong | enoent | eexist | ebusy | system_limit.
%% A change as the process receives it, from this module's functions or from any other
%% process, so every field is checked before it changes anything. A bind's source is
%% the place it reached, an absolute path of plain names.
-type request() :: {mount, To :: binary(), pid(), [option()]}
                 | {bind, From :: binary(), To :: binary(), [] | [ro]}
                 | {unmount, To :: binary()}.
%% A change once checked against the table, with its paths as plain names.
-type checked() :: {mount, [name()], pid(), name(), rights()}
                 | {bind, [name()], [name()], boolean()}
                 | {unmount, [name()]}.
%% The module whose erx_table/0 reads the term (prim_file, or a stub in the EUnit
%% cases), and the monitor of each grant
%% pid the table holds, which follows from the table.
-type state() :: #{prim := module(), monitors := #{pid() => reference()}}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(prim_file).

-spec start_link(module()) -> gen_server:start_ret().
start_link(Prim) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Prim, []).

%% Mounts the grant Pid at To, a local process. Options name the tree the grant roots in,
%% {tree, Name}, once, and at most one of ro, rw and rx, ro when none is given.
-spec mount(pid(), file:name_all(), [option()]) -> ok | {error, reason()}.
mount(Pid, To, Options) ->
    request(fun() -> {mount, text(To), Pid, Options} end).

%% Removes the entry at exactly To.
-spec unmount(file:name_all()) -> ok | {error, reason()}.
unmount(To) ->
    request(fun() -> {unmount, text(To)} end).

%% Shows at To what From reaches, as From's provider or grant rooted there, read-only
%% with the option ro.
-spec bind(file:name_all(), file:name_all()) -> ok | {error, reason()}.
bind(From, To) ->
    bind(From, To, []).

-spec bind(file:name_all(), file:name_all(), [] | [ro]) -> ok | {error, reason()}.
bind(From, To, Options) ->
    request(fun() -> {bind, reached(text(From)), text(To), Options} end).

%% The cap of the domain's /tmp in bytes, from the tmp field of the runtime's startup
%% limits (design-tmp.md, Starting and mounting); 0 makes a /tmp that refuses every
%% creation with enospc.
-spec tmp_limit() -> non_neg_integer().
tmp_limit() ->
    prim_file:erx_tmp_limit().

%% One change of a table: the new table, or why the change is refused. Any term is
%% answered, a malformed one with einval.
-spec change(request() | term(), table()) -> {ok, table()} | {error, reason()}.
change(Request, Table) ->
    case checked(Request, Table) of
        {ok, Checked} -> {ok, applied(Checked, Table)};
        {error, _} = Error -> Error
    end.

%% The process ---------------------------------------------------------------------

-spec init(module()) -> {ok, state()}.
init(Prim) ->
    {ok, #{prim => Prim, monitors => watched(Prim:erx_table(), #{})}}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, ok | {error, reason()}, state()}.
handle_call(Request, _From, #{prim := Prim} = State) ->
    Table = Prim:erx_table(),
    case checked(Request, Table) of
        {ok, Checked} ->
            {reply, ok, put_table(applied(Checked, Table), State)};
        {error, _} = Error ->
            {reply, Error, State}
    end.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Request, State) ->
    {noreply, State}.

%% Only the monitor the process holds for the pid ends its entries, so the 'DOWN' of a
%% monitor that an unmount already dropped ends nothing.
-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({'DOWN', Monitor, process, Pid, _}, #{prim := Prim, monitors := Monitors} = State) ->
    case Monitors of
        #{Pid := Monitor} ->
            %% Any process can send a message that looks like a 'DOWN'.
            case is_process_alive(Pid) of
                false -> {noreply, put_table(ended(Pid, Prim:erx_table()), State)};
                true -> {noreply, State}
            end;
        #{} ->
            {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

put_table(Table, #{monitors := Monitors} = State) ->
    persistent_term:put(erx_ns, Table),
    State#{monitors := watched(Table, Monitors)}.

%% The monitors the table calls for: one for each grant pid it holds, none for any other.
watched(Table, Monitors) ->
    Pids = lists:usort([Pid || #{provider := {grant, Pid, _}} <- Table]),
    Kept = maps:with(Pids, Monitors),
    maps:foreach(fun(_Pid, Monitor) -> demonitor(Monitor, [flush]) end, maps:without(Pids, Monitors)),
    maps:merge(maps:from_list([{Pid, monitor(process, Pid)} || Pid <- Pids, not is_map_key(Pid, Kept)]), Kept).

%% The checks ----------------------------------------------------------------------

%% A change checked against the table: a mount's options before its point and its tree
%% after it, a bind's source before its point.
-spec checked(term(), table()) -> {ok, checked()} | {error, reason()}.
checked({mount, To, Pid, Options}, Table) when is_pid(Pid), node(Pid) =:= node() ->
    maybe
        {ok, Tree, Rights} ?= mount_options(Options, undefined, undefined),
        {ok, Point} ?= new_point(To, Table),
        ok ?= tree(Tree),
        {ok, {mount, Point, Pid, Tree, Rights}}
    end;
checked({bind, From, To, Options}, Table) when Options =:= []; Options =:= [ro] ->
    maybe
        {ok, Place} ?= names(From),
        {ok, #{root := Root}} ?= holder(Place, Table),
        {ok, Point} ?= new_point(To, Table),
        ok ?= bounded(Root),
        {ok, {bind, Place, Point, Options =:= [ro]}}
    end;
checked({unmount, To}, Table) ->
    case names(To) of
        {ok, []} ->
            {error, ebusy};
        {ok, Point} ->
            case lists:any(fun(#{point := At}) -> At =:= Point end, Table) of
                true -> {ok, {unmount, Point}};
                false -> {error, einval}
            end;
        {error, _} = Error ->
            Error
    end;
checked(_Request, _Table) ->
    {error, einval}.

mount_options([], Tree, Rights) when is_binary(Tree) ->
    {ok, Tree, case Rights of undefined -> ro; _ -> Rights end};
mount_options([{tree, Tree} | Rest], undefined, Rights) when is_binary(Tree) ->
    mount_options(Rest, Tree, Rights);
mount_options([Rights | Rest], Tree, undefined) when Rights =:= ro; Rights =:= rw; Rights =:= rx ->
    mount_options(Rest, Tree, Rights);
mount_options(_Options, _Tree, _Rights) ->
    {error, einval}.

%% A point no entry has yet, in a table with room for one more.
new_point(To, Table) ->
    maybe
        {ok, Point} ?= names(To),
        ok ?= case lists:any(fun(#{point := At}) -> At =:= Point end, Table) of
                  true -> {error, eexist};
                  false -> ok
              end,
        ok ?= case length(Table) < ?ERX_NS_MOUNTS_MAX of
                  true -> ok;
                  false -> {error, system_limit}
              end,
        {ok, Point}
    end.

%% A grant's tree is one plain name; anything else is a malformed option.
tree(Tree) ->
    case names(<<"/", Tree/binary>>) of
        {ok, [Tree]} -> ok;
        _ -> {error, einval}
    end.

%% The entry a place lies on, the one whose point is the place's longest prefix, with
%% the place's names below that point added to its root; enoent when no entry holds it.
holder(Place, Table) ->
    Holders = [{length(Point), Entry} || #{point := Point} = Entry <- Table, lists:prefix(Point, Place)],
    case lists:reverse(lists:keysort(1, Holders)) of
        [{Length, #{root := Root} = Entry} | _] -> {ok, Entry#{root := Root ++ lists:nthtail(Length, Place)}};
        [] -> {error, enoent}
    end.

%% A root a bind builds stays within the bounds of a place.
bounded(Root) ->
    case length(Root) =< ?ERX_NS_NAMES_MAX andalso byte_size(path(Root)) < ?ERX_PATH_MAX of
        true -> ok;
        false -> {error, enametoolong}
    end.

%% An absolute path's plain names, empty names dropped, so /a//b/ is [a, b]: einval for
%% a relative path, a . or .. among them, a NUL or bytes that are not UTF-8, and
%% enametoolong at ERX_PATH_MAX bytes, for a name past ERX_NAME_MAX or for more than
%% ERX_NS_NAMES_MAX names.
-spec names(term()) -> {ok, [name()]} | {error, einval | enametoolong}.
names(<<"/", _/binary>> = Path) when byte_size(Path) >= ?ERX_PATH_MAX ->
    {error, enametoolong};
names(<<"/", _/binary>> = Path) ->
    case unicode:characters_to_binary(Path) =:= Path andalso binary:match(Path, <<0>>) =:= nomatch of
        true -> plain([Name || Name <- binary:split(Path, <<"/">>, [global]), Name =/= <<>>]);
        false -> {error, einval}
    end;
names(_Path) ->
    {error, einval}.

plain(Names) ->
    Dotted = lists:any(fun(Name) -> Name =:= <<".">> orelse Name =:= <<"..">> end, Names),
    Long = length(Names) > ?ERX_NS_NAMES_MAX orelse
               lists:any(fun(Name) -> byte_size(Name) > ?ERX_NAME_MAX end, Names),
    if
        Dotted -> {error, einval};
        Long -> {error, enametoolong};
        true -> {ok, Names}
    end.

%% The changes ---------------------------------------------------------------------

-spec applied(checked(), table()) -> table().
applied({mount, Point, Pid, Tree, Rights}, Table) ->
    Table ++ [#{point => Point, provider => {grant, Pid, Tree}, root => [], rights => Rights}];
applied({bind, Place, Point, ReadOnly}, Table) ->
    {ok, #{rights := Rights} = Holder} = holder(Place, Table),
    Table ++ [Holder#{point := Point, rights := case ReadOnly of true -> ro; false -> Rights end}];
applied({unmount, Point}, Table) ->
    [Entry || #{point := At} = Entry <- Table, At =/= Point].

%% The table once the grant Pid has ended: each of its entries answers eio.
ended(Pid, Table) ->
    [case Entry of
         #{provider := {grant, Pid, _}} -> Entry#{provider := ended};
         #{} -> Entry
     end || Entry <- Table].

%% In the calling process ----------------------------------------------------------

%% Asks the process, once the request's names are text; a name that cannot be is
%% malformed, and a bind's source that reaches no place answers why.
request(Request) ->
    try Request() of
        Made -> gen_server:call(?MODULE, Made, infinity)
    catch
        throw:Reason -> {error, Reason}
    end.

%% A name as text, a binary; a name that is not text throws einval.
text(Name) when is_binary(Name) ->
    Name;
text(Name) when is_atom(Name) ->
    atom_to_binary(Name);
text(Name) when is_list(Name) ->
    try unicode:characters_to_binary(Name) of
        Text when is_binary(Text) -> Text;
        _ -> throw(einval)
    catch
        error:badarg -> throw(einval)
    end;
text(_Name) ->
    throw(einval).

%% The place a bind's source reaches, as prim_file places a path until erx_path does
%% (TODO.md, "paths resolve logically"): a relative path starts at the working
%% directory, empty names and . are dropped, and .. drops the name before it, or nothing
%% at /, and an empty path reaches nothing (enoent), as for any call. The process checks
%% the place whatever its sender did here.
reached(<<>>) ->
    throw(enoent);
reached(<<"/", _/binary>> = Path) ->
    path(lists:reverse(lists:foldl(fun step/2, [], binary:split(Path, <<"/">>, [global]))));
reached(Path) ->
    case prim_file:get_cwd() of
        {ok, Cwd} -> reached(<<(text(Cwd))/binary, "/", Path/binary>>);
        {error, Reason} -> throw(Reason)
    end.

step(<<>>, Names) -> Names;
step(<<".">>, Names) -> Names;
step(<<"..">>, []) -> [];
step(<<"..">>, [_ | Names]) -> Names;
step(Name, Names) -> [Name | Names].

%% The absolute path of plain names.
path([]) -> <<"/">>;
path(Names) -> iolist_to_binary([[<<"/">>, Name] || Name <- Names]).
