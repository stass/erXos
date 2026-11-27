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
%% prim_file:erx_mounts/0 answers the boot table. The changes are functions over a
%% table, change/2, which a session's handler can apply to a program's table as well;
%% each is pure but for an image's mount, which reads the image.
%%
%% The one EROFS mount, {erofs, app}, mounts the session's own package (design-files.md,
%% "Building, binding and mounting"): this process takes the file's facet, its names and
%% its layout from the app's record the session's agent holds, never from the caller,
%% walks the names on that facet's grant to a fid it owns (erx_file_remote:open_fid/2),
%% opens the image on the fid in erx_verity with the record's layout, and mounts it with
%% erx_erofs:mount/2, so every block the reader parses matched the root hash the domain
%% service put in the record (E1, design-storage.md). The record's facet is the app
%% template's packages or system facet, which the registry holds with its grant's rights
%% (erx_facets:facet/0): an rx mount through a grant that is not rx is refused with eacces
%% before the grant is walked, so the entry is rx only through an rx grant, which writes
%% nothing (F5, F6, design-files.md). The entry holds the reader's mount as its provider
%% and the grant and fid as its fid; the fid is clunked once no entry, a bind included,
%% holds it (closed/2), and the grant clunks it if this process ends first, so a
%% restarted process's image entries answer eio. Its rights are ro or rx, ro when none is
%% asked; rw is einval, as is any other source: no form takes a layout or an image.
%% A mount that fails answers its error, and its diagnostic goes to the kernel log, as
%% does the diagnostic of every later operation that fails on the image.
%%
%% The process monitors every grant pid its table holds. When one ends, it rewrites
%% that pid's entries to the provider ended, which answers eio, and they stay until
%% they are unmounted, so a pid later given to another process never receives a
%% mounted path's requests. The monitors are its only state beyond the term: a
%% restarted process reads the term and monitors its grants again, and one that ended
%% meanwhile answers 'DOWN' at once.
%%
%% A facet's mount, {facet, Name}, holds the facet's name and no pid: its entries, and
%% each bind of one, have the provider {facet, Name}, which a resolution reads as the
%% grant the domain's facet registry (erx_facets) holds for Name at that moment, on the
%% tree the registry holds with it, with the lesser of the entry's rights and the
%% grant's, or as ended when it holds none
%% (erx_facets:table/1, through prim_file:erx_table/0). That resolution also marks every
%% entry on a facet of an interface whose row says links none (media, svc) nofollow, from
%% the facet's interface number, so no link on a drive or in a service's tree is followed; no entry of this table holds the mark.
%% This is how a domain reaches a grant of another domain by path: a re-grant, such as
%% the one a restarted server's domain is given, serves the next lookup with no change
%% to the table, and the process monitors no facet's grant. A grant that has ended
%% answers each request with eio through the file client's own monitor on it. A
%% descriptor keeps the grant and fid it was opened on: once that grant has ended,
%% every operation that reaches it answers eio, a read may first answer bytes the
%% descriptor already holds, and only a new open finds the re-grant.
%%
%% Each call answers ok or {error, Reason}: einval for a malformed path, place,
%% source or option, a mount point holding . or .., or an unmount where no entry is; enametoolong
%% beyond the bounds of a place; enoent for a source no entry holds, and for an app mount
%% in a domain with no app's record, no grant of its facet or no file at its names, and for an
%% own mount of a name the domain's declaration lacks; eacces
%% for an rx app mount through a grant that is not rx; eexist for a point
%% that already has an entry; ebusy for unmounting /; system_limit beyond the table's
%% 64 entries; and for an image whose mount fails, the reader's error: eio for a
%% file that does not answer, does not fit its layout or does not match its tree, enotsup for a feature it
%% does not implement.

-module(erx_ns).

-behaviour(gen_server).

-export([start_link/0, start_link/1, mount/3, mount_facets/1, mount_own/2, unmount/1, bind/2, bind/3, tmp_limit/0,
         change/2, place/1, packages_place/0, home_place/1]).
-export([image_log/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export_type([entry/0, table/0, option/0]).

-include("generated/erx_abi.hrl").

%% Where every domain's /svc entry lies (mount_facets/1).
-define(SVC, <<"/svc">>).

-type name() :: binary().
-type rights() :: erx_abi_enums:files_rights().
-type provider() :: release | {erofs, erx_erofs:fs()} | {grant, pid(), Tree :: name()}
                  | {facet, Name :: atom()} | {facets, svc}
                  | {own, Name :: atom(), erx_facets:interface(), pid(), Tree :: name()}
                  | ended.
%% An image's entry also holds the grant and fid the image is read through.
-type entry() :: #{point := [name()], provider := provider(), root := [name()], rights := rights(),
                   fid => file()}.
-type file() :: {{pid(), Tree :: binary(), ro}, Fid :: non_neg_integer()}.
-type table() :: [entry()].
-type option() :: rights().
-type reason() :: einval | enametoolong | enoent | eexist | ebusy | system_limit | file:posix().
%% A change as the process receives it, from this module's functions or from any other
%% process, so every field is checked before it changes anything. A bind's source is
%% the place it reached, an absolute path of plain names.
-type request() :: {mount, To :: binary(), erx_fs:grant_handle() | {erofs, app} | {facet, atom()} | {facets, svc}
                                             | {own, atom(), erx_fs:grant_handle()}, [option()]}
                 | {bind, From :: binary(), To :: binary(), [] | [ro]}
                 | {unmount, To :: binary()}.
%% A change once checked against the table, with its paths as plain names.
-type checked() :: {mount, [name()], provider(), rights()}
                 | {mount_app, [name()], ro | rx}
                 | {mount, [name()], provider(), rights(), file()}
                 | {bind, [name()], [name()], boolean()}
                 | {unmount, [name()]}.
%% The module whose erx_mounts/0 reads the term (prim_file, or a stub in the EUnit
%% cases), the monitor of each grant pid the table holds and the fids its images hold,
%% both of which follow from the table.
-type state() :: #{prim := module(), monitors := #{pid() => reference()}, fids := [file()]}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(prim_file).

-spec start_link(module()) -> gen_server:start_ret().
start_link(Prim) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Prim, []).

%% Mounts at To the grant {Pid, Tree, Rights}, a local process with the tree it answered
%% and the rights it was started with, the handle what started it received from
%% erx_fs:start_link/3,4 (erx_fs:start_mounted/4, erx_fs_grants:own/1,2), so the entry's
%% tree is the one the grant's server names and no option names another
%% (docs/design-files.md, "The tree beneath an entry"). Options name at most one of ro,
%% rw and rx, ro when none is given; the entry has the lesser of those and Rights
%% (erx_path:lesser/2), as a facet's entry has at each resolution, so it never exceeds
%% its grant's (docs/design-files.md, "Rights beneath an entry").
%%
%% Or mounts at To the facet Name, {facet, Name}: whatever grant the domain's facet
%% registry holds for Name when a path under To is resolved, a grant of another domain
%% included, which is the only way such a grant is mounted. Its options name the rights
%% as a grant's mount does, and no tree: a resolution takes the tree the registry holds
%% with the facet, the one the grant's server named in the mint's reply
%% (docs/design-files.md, "The tree beneath an entry").
%%
%% Or mounts at To the session's own package, {erofs, app}, the image of the file the
%% app's record names, read-only with no option or ro, or read and execute with rx.
-spec mount(erx_fs:grant_handle() | {facet, atom()} | {facets, svc} | {own, atom(), erx_fs:grant_handle()} | {erofs, app},
            file:name_all(), [option()]) ->
          ok | {error, reason()}.
mount(Source, To, Options) ->
    request(fun() -> {mount, text(To), Source, Options} end).

%% Mounts the /svc entry, {facets, svc}, which shows at each resolution every facet of
%% the svc interface the domain's registry holds by its name, whatever the domain holds
%% now (docs/design-app-trees.md, "Mounting and resolving /svc"), and then each facet of
%% Names, the facets the domain holds or the manifest grants it (erx:caps/0 and
%% erx:granted/0, or the manifest itself in the system domain), at its place
%% (place/1). A name with no place mounts nothing, and a facet the domain neither holds
%% nor is granted is never mounted, so its path falls through to the root's own entry
%% (docs/design-files.md, "A facet's mount"). Stops at the first refusal and returns it.
-spec mount_facets([atom()]) -> ok | {error, reason()}.
mount_facets(Names) ->
    maybe
        ok ?= mount({facets, svc}, ?SVC, [rw]),
        mount_places(Names)
    end.

mount_places([]) ->
    ok;
mount_places([Name | Rest]) ->
    case mount_facet(place(Name), Name) of
        ok -> mount_places(Rest);
        Refused -> Refused
    end.

mount_facet(none, _Name) -> ok;
mount_facet({Point, Options}, Name) -> mount({facet, Name}, Point, Options).

%% Mounts Grant, {Pid, Tree, Rights}, a grant of the service Name that this domain serves
%% for its own domain (erx_fs_grants:own/1,2), on the tree its handle carries, where a
%% domain that holds the facet Name reaches it: a service of the svc interface at
%% /svc/Name, every other at Name's place (place/1), with rw lowered to Rights (mount/3).
%% The interface is the one the domain's declaration gives Name (declared/1), and the
%% entry's provider keeps it, {own, Name, Interface, Pid, Tree}, so erx_facets:table/1
%% marks the entry from it as it marks a facet's (docs/design-app-trees.md, "The
%% namespace entry" and "Links"). It first removes any entry an earlier instance of the
%% tree left there (docs/design-shell.md, "Interfaces"). So the system domain reaches
%% each tree it serves by the path its sessions do. enoent for a Name its declaration
%% lacks or of another interface with no place, each a configuration error its
%% caller's start fails on.
-spec mount_own(atom(), erx_fs:grant_handle()) -> ok | {error, reason()}.
mount_own(Name, Grant) ->
    case declared(Name) of
        {ok, ?ERX_SERVICE_SVC} ->
            own_at(Name, Grant, <<?SVC/binary, "/", (atom_to_binary(Name))/binary>>);
        {ok, _Interface} ->
            case place(Name) of
                {Point, [rw]} -> own_at(Name, Grant, Point);
                none -> {error, enoent}
            end;
        {error, enoent} = Refused ->
            Refused
    end.

own_at(Name, Grant, Point) ->
    _ = unmount(Point),
    mount({own, Name, Grant}, Point, [rw]).

%% The interface number the domain's declaration gives the service Name
%% (erx_serves:find/1), the one source of an own entry's interface; none in a domain
%% with no declaration, a session's included.
declared(Name) ->
    case erx_serves:find(atom_to_binary(Name)) of
        {ok, Interface} -> {ok, Interface};
        error -> {error, enoent}
    end.

%% Where the tree of each service Name mounts, with rw as the entry's own rights, which
%% a resolution lowers to the rights the facet's grant
%% carries (erx_facets:table/1), so a domain writes there only through an rw grant:
%% data, the storage domain's tree, at /data; media, the media domain's tree of every
%% drive, at /media (docs/design-drives.md, "Mounting it"); the system domain's trees
%% of the files interface: the package application's apps tree at /apps
%% (docs/design-packaging.md, "/apps"), and the line service's tree, line, at /line
%% (docs/design-bluetooth.md, "The controller's line"); and the storage domain's bt_state
%% tree, the Bluetooth domain's development store, at /data/bt, the path of the data
%% volume's bt/ in a namespace that mounts data at /data (docs/design-bluetooth.md,
%% "Bonds and the store"). /data and /media are also empty
%% directories of every release, so a domain granted neither lists each as empty
%% (ReleaseFiles::MOUNT_POINTS, tools/lib/erx/release_files.rb); a domain that holds no
%% apps or line facet has no such path, enoent. A tree of the svc interface, start and
%% machine among them, has no place: a domain that holds one reaches it through /svc
%% (mount_facets/1; docs/design-app-trees.md, "The namespace entry").
%%
%% The packages and system facets have no place, so no domain's mount_facets/1, a
%% session's included, mounts either: an app's session reaches them by erx:cap/1, its
%% {erofs, app} mount or an entry its own code puts in its table
%% (docs/design-packaging.md, "An app's session"), and the system domain mounts its
%% packages grant at its own place (packages_place/0).
-spec place(atom()) -> {binary(), [option()]} | none.
place(data) -> {<<"/data">>, [rw]};
place(media) -> {<<"/media">>, [rw]};
place(apps) -> {<<"/apps">>, [rw]};
place(line) -> {<<"/line">>, [rw]};
place(bt_state) -> {<<"/data/bt">>, [rw]};
place(_Name) -> none.

%% Where the storage domain's packages tree lies in the system domain alone, with the
%% same options as place/1: /packages, where erx_domain_srv mounts the system domain's
%% grant and erx_pkg_medium finds the installed packages (docs/design-packaging.md,
%% "Where a package lies"). place/1 gives packages no place, so mount_facets/1 never
%% mounts it, whatever facets a session holds.
-spec packages_place() -> {binary(), [option()]}.
packages_place() -> {<<"/packages">>, [rw]}.

%% Where the home of the user named User lies, with the same options as place/1
%% (docs/design-files.md, "A user's home"): /root for root and /home/User for any
%% other user, FreeBSD's paths, the same path in a session's namespace, where the
%% session mounts its home facet, and on the data volume, where the storage domain
%% roots the user's home grant. A User that is not one path name, empty, . or .., or
%% holding / or NUL, has no home: einval, so no name places a home above /home.
-spec home_place(binary()) -> {ok, {binary(), [option()]}} | {error, einval}.
home_place(User) when User =:= <<>>; User =:= <<".">>; User =:= <<"..">> ->
    {error, einval};
home_place(<<"root">>) ->
    {ok, {<<"/root">>, [rw]}};
home_place(User) when is_binary(User) ->
    case binary:match(User, [<<"/">>, <<0>>]) of
        nomatch -> {ok, {<<"/home/", User/binary>>, [rw]}};
        _ -> {error, einval}
    end.

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
    maybe
        {ok, Checked} ?= checked(Request, Table),
        {ok, Ready} ?= mounted(Checked),
        {ok, applied(Ready, Table)}
    end.

%% The process ---------------------------------------------------------------------

-spec init(module()) -> {ok, state()}.
init(Prim) ->
    Table = Prim:erx_mounts(),
    {ok, #{prim => Prim, monitors => watched(Table, #{}), fids => held(Table)}}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, ok | {error, reason()}, state()}.
handle_call(Request, _From, #{prim := Prim} = State) ->
    Table = Prim:erx_mounts(),
    case change(Request, Table) of
        {ok, Changed} ->
            {reply, ok, put_table(Changed, State)};
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
                false -> {noreply, put_table(ended(Pid, Prim:erx_mounts()), State)};
                true -> {noreply, State}
            end;
        #{} ->
            {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

put_table(Table, #{monitors := Monitors, fids := Fids} = State) ->
    persistent_term:put(erx_ns, Table),
    State#{monitors := watched(Table, Monitors), fids := closed(Table, Fids)}.

%% The fids the table's images hold, once each fid no entry holds any more is clunked.
closed(Table, Fids) ->
    Held = held(Table),
    _ = [erx_file_remote:exchange(Grant, [{clunk, Fid}]) || {Grant, Fid} <- Fids -- Held],
    Held.

held(Table) ->
    lists:usort([File || #{fid := File} <- Table]).

%% The monitors the table calls for: one for each grant pid it holds, none for any other.
watched(Table, Monitors) ->
    Pids = lists:usort([Pid || #{provider := Provider} <- Table, Pid <- [grant_pid(Provider)], is_pid(Pid)]),
    Kept = maps:with(Pids, Monitors),
    maps:foreach(fun(_Pid, Monitor) -> demonitor(Monitor, [flush]) end, maps:without(Pids, Monitors)),
    maps:merge(maps:from_list([{Pid, monitor(process, Pid)} || Pid <- Pids, not is_map_key(Pid, Kept)]), Kept).

%% The checks ----------------------------------------------------------------------

%% A change checked against the table: a mount's options before its point and a grant's
%% tree after it, a bind's source before its point.
-spec checked(term(), table()) -> {ok, checked()} | {error, reason()}.
checked({mount, To, {Pid, Tree, Granted}, Options}, Table)
  when is_pid(Pid), node(Pid) =:= node(), is_binary(Tree) ->
    maybe
        {ok, Asked} ?= asked(Options),
        {ok, Rights} ?= lowered(Asked, Granted),
        {ok, Point} ?= new_point(To, Table),
        ok ?= tree(Tree),
        {ok, {mount, Point, {grant, Pid, Tree}, Rights}}
    end;
checked({mount, To, {facet, Name}, Options}, Table) when is_atom(Name) ->
    maybe
        {ok, Rights} ?= asked(Options),
        {ok, Point} ?= new_point(To, Table),
        {ok, {mount, Point, {facet, Name}, Rights}}
    end;
checked({mount, To, {facets, svc}, [rw]}, Table) ->
    maybe
        {ok, Point} ?= new_point(To, Table),
        {ok, {mount, Point, {facets, svc}, rw}}
    end;
checked({mount, To, {own, Name, {Pid, Tree, Granted}}, [rw]}, Table)
  when is_atom(Name), is_pid(Pid), node(Pid) =:= node(), is_binary(Tree) ->
    maybe
        {ok, Rights} ?= lowered(rw, Granted),
        {ok, Point} ?= new_point(To, Table),
        ok ?= tree(Tree),
        {ok, Interface} ?= declared(Name),
        {ok, {mount, Point, {own, Name, Interface, Pid, Tree}, Rights}}
    end;
checked({mount, To, {erofs, app}, Options}, Table) ->
    maybe
        {ok, Rights} ?= image_rights(Options),
        {ok, Point} ?= new_point(To, Table),
        {ok, {mount_app, Point, Rights}}
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

%% The rights a grant's or a facet's mount asks: at most one rights, ro when none is
%% given, and no tree, which a grant's handle carries and a facet's registry holds.
asked([]) -> {ok, ro};
asked([Rights]) when ?ERX_IS_FILES_RIGHTS(Rights) -> {ok, Rights};
asked(_Options) -> {error, einval}.

%% A grant pid's entry: the lesser of the rights its mount asked and those its grant was
%% started with; einval for a grant of rights erx_path:lesser/2 does not order.
lowered(Asked, Granted) ->
    case erx_path:lesser(Asked, Granted) of
        none -> {error, einval};
        Rights -> {ok, Rights}
    end.

%% An image is never written: its mount is ro, or rx to run what it holds.
image_rights([]) -> {ok, ro};
image_rights([ro]) -> {ok, ro};
image_rights([rx]) -> {ok, rx};
image_rights(_Options) -> {error, einval}.

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
applied({mount, Point, Provider, Rights}, Table) ->
    Table ++ [#{point => Point, provider => Provider, root => [], rights => Rights}];
applied({mount, Point, Provider, Rights, File}, Table) ->
    Table ++ [#{point => Point, provider => Provider, root => [], rights => Rights, fid => File}];
applied({bind, Place, Point, ReadOnly}, Table) ->
    {ok, #{rights := Rights} = Holder} = holder(Place, Table),
    Table ++ [Holder#{point := Point, rights := case ReadOnly of true -> ro; false -> Rights end}];
applied({unmount, Point}, Table) ->
    [Entry || #{point := At} = Entry <- Table, At =/= Point].

%% The table once the grant Pid has ended: each of its entries answers eio.
ended(Pid, Table) ->
    [case grant_pid(Provider) of
         Pid -> Entry#{provider := ended};
         _ -> Entry
     end || #{provider := Provider} = Entry <- Table].

%% The grant pid an entry's provider holds, a grant's or an own service's, or none.
grant_pid({grant, Pid, _Tree}) -> Pid;
grant_pid({own, _Name, _Interface, Pid, _Tree}) -> Pid;
grant_pid(_Provider) -> none.

%% Mounting an image ---------------------------------------------------------------

%% The mount runs in erx_ns's process or change/2's caller, and its log in whatever
%% process reads a path on the image.

%% A checked change with its image mounted: the mount's entry change, or the error once
%% its diagnostic, fixed text and numbers, is in the kernel log. Every other change is
%% ready as it is.
mounted({mount_app, Point, Rights}) ->
    maybe
        {ok, #{place := {Facet, Names}, layout := Layout}} ?= app_record(),
        {ok, Grant} ?= erx_facets:file_grant(Facet, Rights),
        {ok, Fid} ?= erx_file_remote:open_fid(Grant, Names),
        {ok, Fs} ?= image(Grant, Fid, Layout),
        {ok, {mount, Point, {erofs, Fs}, Rights, {Grant, Fid}}}
    end;
mounted(Checked) ->
    {ok, Checked}.

%% The app's record as the session's agent holds it, its place a facet and plain names.
app_record() ->
    case erx_connections:app_held() of
        {ok, #{place := {Facet, Names}, layout := Layout} = Record}
          when (Facet =:= packages orelse Facet =:= system), is_list(Names), is_map(Layout) ->
            {ok, Record};
        _ ->
            {error, enoent}
    end.

%% The reader's mount of the image the fid holds under Layout; on a failure the fid is
%% clunked and the diagnostic logged.
image(Grant, Fid, Layout) ->
    Mounted = case erx_verity:open_file(Grant, Fid, Layout) of
                  {ok, Image} -> erx_erofs:mount(Image, fun ?MODULE:image_log/1);
                  {error, eio} -> {error, eio, <<"the file has no length or the layout does not fit it">>}
              end,
    case Mounted of
        {ok, Fs} ->
            {ok, Fs};
        {error, Reason, Diagnostic} ->
            _ = erx_file_remote:exchange(Grant, [{clunk, Fid}]),
            _ = image_log(Diagnostic),
            {error, Reason}
    end.

%% The kernel log line of an operation that failed on a mounted image, which runs in the
%% process that read the path: a fun of an exported function, so a reload of this module
%% leaves the mounts' log working.
-spec image_log(binary()) -> term().
image_log(Diagnostic) ->
    erx_log:debug(["erx_ns: image: ", Diagnostic]).

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
