%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_path).
-moduledoc """
Resolves one path against one namespace table and one working directory, as
FreeBSD's `namei` and `vfs_lookup` resolve it (docs/design-files.md,
Resolving a path), and lists a directory it reached as its provider and the
mount points below it show it (Listings across mounts).

A resolution keeps its place: the namespace path of the directory it has
reached, every name of which a walk answered as a directory, or the table
gave as an entry's mount point or a directory above one. `..` removes the
place's last name, nothing at `/`, and `.` leaves the place as it is, so
neither reaches a server, and `..` after a link names the parent of the
link's target. The path's other names gather into runs, each ended by a
`.`, a `..` or the last name. A run lies on the entry whose mount point is
the longest prefix of the place and the run joined: its names down to the
point join the place without a walk, and the rest are walked through the
`walk` callback from the entry's top, the entry's `root` names first, so
every walk retraces the place. A link a walk meets is read through the
`read_link` callback, and its text takes its name's place among the names
still to read, from the link's directory or from `/`.

The last name is the operation's, FreeBSD's `nameiop`. A lookup returns the
target, a walk to the last name that the caller sends with the operation;
a create, delete or rename returns the parent, a walk to the directory
sent with the operation on the last name; and a last name that is an
entry's top, which no request to a parent can name, returns the top. When
the walk sent with an operation stops short, or ends on a link the
operation follows, the caller hands the walk's reply to the action's
resumption, and the resolution goes on from there. A path whose last name
is followed by `/` walks that name as a run first, so a link there is
followed and it must be a directory, whatever the operation.

A narrowed table may have no `/`; the directories above its mount points
then form the empty root, read-only and held by no provider. A lookup or a
create that names one of them returns `{empty_root, Place}` for the caller
to answer, and a change to the empty root answers `erofs` here, as
`vfs_lookup` answers on a read-only file system.

The caller checks the table and the working directory when it writes them,
and the resolver trusts both. It trusts nothing else: the path, each link's
text and each walk's reply are checked here as they are read. A resolution
reads each name once, makes at most one walk for each run and two for each
link, follows at most 32 links and holds at most `ERX_NS_NAMES_MAX` names in
its place, so its work is bounded by its path. It calls only BIFs, its own
functions and the two callbacks, and reads no state but its arguments, so a
table changed while it runs is not seen by it.
""".

-export([resolve/6, cwd/1, target_place/1, listing/3]).
-export_type([name/0, place/0, entry/0, table/0, op/0, flags/0, kind/0,
              reply/0, callbacks/0, action/0, resume/0]).

-include("generated/erx_abi.hrl").

%% The most links one resolution follows, FreeBSD's MAXSYMLINKS; the next one
%% answers eloop.
-define(LINKS_MAX, 32).

%% A plain name: 1 to 255 bytes of UTF-8, not "." or "..", without "/" or NUL.
-type name() :: binary().
%% A namespace path, absolute; every name a directory the resolution reached.
-type place() :: [name()].
%% An entry is its caller's; the resolver reads only its mount point and the
%% names in the provider where it starts, and hands it back in an action.
-type entry() :: #{point := [name()], root := [name()], term() => term()}.
-type table() :: [entry()].
-type posix() :: atom().
%% What the operation does with its last name: FreeBSD's nameiop.
-type op() :: lookup | create | delete | rename.
%% FreeBSD's FOLLOW, and WILLBEDIR: a missing last name written with a
%% trailing "/" may be made, as a directory.
-type flags() :: #{follow := boolean(), willbedir := boolean()}.
%% A walk is handed names from the provider's root and answers the kind of
%% each name it passed, in order, up to and including the first that is not a
%% directory, and how it ended.
-type kind() :: directory | link | other.
-type reply() :: {[kind()], ok | {error, posix()}}.
-type callbacks() :: #{walk := fun((entry(), [name()]) -> reply()),
                       read_link := fun((entry(), [name()]) ->
                                            {ok, binary()} | {error, posix()})}.
-type action() :: {target, entry(), [name()], resume()}
                | {parent, entry(), [name()], name(), resume()}
                | {top, entry()}
                | {empty_root, place()}
                | {error, posix()}.
-type resume() :: fun((reply()) -> action()).

%% What a resolution carries from name to name besides its place and the
%% names still to read: the operation and its flags, whether the path or a
%% last link's text ended in "/" (FreeBSD's TRAILINGSLASH, which nothing
%% clears), the links followed so far, and the table and callbacks it was
%% handed. Between two walks it lives only in a resumption's closure.
-record(st, {op :: op(),
             follow :: boolean(),
             willbedir :: boolean(),
             slash = false :: boolean(),
             links = 0 :: 0..?LINKS_MAX,
             table :: table(),
             callbacks :: callbacks()}).

-doc """
Resolves `Path` for an operation `Op` with FreeBSD's flags, over `Table`
and, for a relative path, from the working directory `Cwd`, and returns the
last action. A target or a parent carries the names to walk from the
provider's root and a resumption, which the caller calls with the reply of
the walk sent with the operation when that walk stopped short or ended on a
link the operation follows; for a parent, a link at the last name is
reported as one more kind, `link`, after the directory's names.
""".
-spec resolve(binary(), op(), flags(), table(), place(), callbacks()) ->
          action().
resolve(Path, Op, #{follow := Follow, willbedir := WillBeDir}, Table, Cwd,
        Callbacks)
  when is_binary(Path),
       Op =:= lookup orelse Op =:= create orelse Op =:= delete orelse
       Op =:= rename ->
    read(Path, Cwd, [], #st{op = Op, follow = Follow, willbedir = WillBeDir,
                            table = Table, callbacks = Callbacks}).

-doc """
Reads the text of a working directory as the place it names: `/` alone, or
`/` and then plain names joined by single `/` with none after the last, at
most `ERX_NS_NAMES_MAX` of them and the whole shorter than `ERX_PATH_MAX`
bytes, so it fits with its NUL. Anything else, any other term included, is
`error`. `prim_file:set_cwd/1` stores only a place this accepts, so the
working directory every resolution starts from is one.
""".
-spec cwd(term()) -> {ok, place()} | error.
cwd(<<"/">>) ->
    {ok, []};
cwd(<<"/", Names/binary>> = Text) when byte_size(Text) < ?ERX_PATH_MAX ->
    Place = binary:split(Names, <<"/">>, [global]),
    case text(Text) andalso length(Place) =< ?ERX_NS_NAMES_MAX andalso
             [Name || Name <- Place, not plain(Name)] =:= [] of
        true -> {ok, Place};
        false -> error
    end;
cwd(_) ->
    error.

-doc """
The place a target lies at: its entry's mount point, then its names below
the entry's root. Every walk retraces the place, so a target's names are
its root's and then the place's below the point.
""".
-spec target_place(action()) -> place().
target_place({target, #{point := Point, root := Root}, Names, _}) ->
    {ok, Below} = below(Root, Names),
    Point ++ Below.

-doc """
The names of the directory a lookup reached, as a listing shows them
(docs/design-files.md, Listings across mounts). For a target, `Listed` is
what its provider listed, followed by the last name of each mount point
directly below the target's place that `Listed` lacks, each once, so a
mount point hides the provider's entry of its name. A directory of the
empty root has no provider and lists nothing of its own, so it lists the
next name of each mount point below it. Only the caller's table is read: no
provider learns of another's mounts.
""".
-spec listing(action(), [binary()], table()) -> [binary()].
listing({target, _, _, _} = Target, Listed, Table) ->
    Place = target_place(Target),
    case [Name || #{point := P} <- Table, {ok, [Name]} <- [below(Place, P)]] of
        [] -> Listed;
        Mounts -> Listed ++ fresh(Mounts, maps:from_list([{Name, true} || Name <- Listed]))
    end;
listing({empty_root, Place}, [], Table) ->
    fresh([Next || #{point := P} <- Table, {ok, [Next | _]} <- [below(Place, P)]], #{}).

%% Names not in Seen, each once, in order.
fresh([Name | Names], Seen) when is_map_key(Name, Seen) -> fresh(Names, Seen);
fresh([Name | Names], Seen) -> [Name | fresh(Names, Seen#{Name => true})];
fresh([], _) -> [].

plain(Name) ->
    Name =/= <<>> andalso Name =/= <<".">> andalso Name =/= <<"..">> andalso
        byte_size(Name) =< ?ERX_NAME_MAX.

%% Reads Text, the path or a link's, before Rest, the names still to read
%% after it: from "/" when the text is absolute and from Place otherwise. A
%% text ending in "/" with no names after it sets TRAILINGSLASH.
read(Text, Place, Rest, St) ->
    case text_error(Text, Rest) of
        none ->
            Slash = St#st.slash orelse
                (Rest =:= [] andalso binary:last(Text) =:= $/),
            next(start(Text, Place), names(Text) ++ Rest, St#st{slash = Slash});
        Posix ->
            {error, Posix}
    end.

%% A text is refused as FreeBSD's namei refuses a path or a link's text:
%% empty, too long to fit ERX_PATH_MAX with the names after it and its NUL,
%% or, rather than being cut short, not UTF-8 or holding a NUL.
text_error(<<>>, _) -> enoent;
text_error(Text, Rest) ->
    case byte_size(Text) + text_size(Rest, 1) > ?ERX_PATH_MAX of
        true -> enametoolong;
        false ->
            case text(Text) of
                true -> none;
                false -> einval
            end
    end.

start(<<"/", _/binary>>, _) -> [];
start(_, Place) -> Place.

%% Reads the names still to read from Place. Names that run out with no last
%% name, from "/" or from a last link to "/", are FreeBSD's degenerate name:
%% the target "/" for a lookup, and eisdir for an operation that changes it.
next(Place, [], #st{op = lookup} = St) ->
    target(Place, St);
next(_, [], _) ->
    {error, eisdir};
next(Place, Names, St) ->
    {Run, Rest} = run(Names, []),
    case fits(Place, Run) of
        true -> step(Place, Run, Rest, St);
        false -> {error, enametoolong}
    end.

%% A run: the plain names up to the next "." or "..", or to the last name.
run([Name | Rest], Run) when Name =/= <<".">>, Name =/= <<"..">> ->
    run(Rest, [Name | Run]);
run(Rest, Run) ->
    {lists:reverse(Run, []), Rest}.

%% A run that ends at the path's last name is the operation's, unless the
%% name is followed by "/", which walks it first as a directory. A "." or
%% ".." acts on the place once the run before it has joined the place.
step(Place, Run, [], #st{slash = false} = St) ->
    last(Place ++ Run, St);
step(Place, [], [Dot | Rest], St) ->
    dot(Place, Dot, Rest, St);
step(Place, Run, Rest, St) ->
    walk(Place, Run, Rest, St).

dot(Place, <<".">>, Rest, St) -> after_dot(Place, Rest, St);
dot(Place, <<"..">>, Rest, St) -> after_dot(up(Place), Rest, St).

after_dot(Place, [], St) -> last_dot(Place, St);
after_dot(Place, Rest, St) -> next(Place, Rest, St).

%% A last "." or "..": its directory is the target of a lookup and the top of
%% a create, and rmdir(2) and rename(2) refuse it.
last_dot(Place, #st{op = lookup} = St) -> target(Place, St);
last_dot(Place, #st{op = create} = St) -> top(Place, St);
last_dot(_, _) -> {error, einval}.

%% A plain last name, the end of Path, by the operation: the target of a
%% lookup; for a name whose directory is the empty root, that read-only
%% directory's answer; the top when the name is an entry's mount point; and
%% otherwise the parent, its directory.
last(Path, #st{op = lookup} = St) ->
    target(Path, St);
last(Path, St) ->
    {Dir, Last} = split_last(Path),
    case {place(Dir, St#st.table), place(Path, St#st.table)} of
        {empty_root, Placed} -> in_empty_root(Placed, Path, St);
        {_, {on, Entry, _, []}} -> {top, Entry};
        _ -> parent(Dir, Last, St)
    end.

target(Path, St) ->
    case place(Path, St#st.table) of
        {on, Entry, Point, Below} ->
            {target, Entry, root(Entry) ++ Below,
             fun(Reply) -> resumed(Reply, Entry, Point, Below, St) end};
        Elsewhere ->
            elsewhere(Elsewhere, Path)
    end.

parent(Dir, Last, St) ->
    case place(Dir, St#st.table) of
        {on, Entry, Point, Below} ->
            {parent, Entry, root(Entry) ++ Below, Last,
             fun(Reply) -> resumed(Reply, Entry, Point, Below ++ [Last], St) end};
        _ ->
            %% No entry holds the directory; one in the empty root is last/2's.
            {error, enoent}
    end.

top(Place, St) ->
    case place(Place, St#st.table) of
        {on, Entry, _, _} -> {top, Entry};
        Elsewhere -> elsewhere(Elsewhere, Place)
    end.

%% The action for a path no entry holds.
elsewhere(empty_root, Path) -> {empty_root, Path};
elsewhere(nowhere, _) -> {error, enoent}.

%% The last name, the end of Path, of a create, delete or rename whose
%% directory is the empty root, read-only, where Placed is where Path lies.
%% A create of an existing name answers as for any existing directory: the
%% empty root's own, or an entry's top. Anything else answers erofs, as
%% FreeBSD answers on a read-only mount: vfs_cache_lookup refuses DELETE
%% and RENAME before it looks the name up, a mount point included, and a
%% missing name's CREATE fails its write check, ahead of the trailing "/"
%% check.
in_empty_root(empty_root, Path, #st{op = create}) -> {empty_root, Path};
in_empty_root({on, Entry, _, []}, _, #st{op = create}) -> {top, Entry};
in_empty_root(_, _, _) -> {error, erofs}.

%% Walks a run whose every name must be a directory, from Place; Rest are the
%% names after it, none for a last name followed by "/". In the empty root
%% the run joins the place without a walk, and a last name it does not hold
%% is the operation's to answer there.
walk(Place, Run, Rest, St) ->
    case place(Place ++ Run, St#st.table) of
        {on, Entry, Point, Below} ->
            Reply = case root(Entry) ++ Below of
                        [] -> {[], ok};
                        Names -> (maps:get(walk, St#st.callbacks))(Entry, Names)
                    end,
            walked(Reply, Entry, Point, Below, Rest, St);
        empty_root ->
            passed(Place ++ Run, Rest, St);
        nowhere when Rest =:= [] ->
            last(Place ++ Run, St);
        nowhere ->
            {error, enoent}
    end.

%% Goes on from the walk of a run: Below are the names under the entry's
%% point, the place's and then the run's, each of which must be a directory.
%% Once all have joined the place the resolution goes on with Rest; a link
%% among them is followed, its text before the names after it; and a name
%% that is anything else answers enotdir. A last name followed by "/" that
%% the walk did not find is missing.
walked(Reply, Entry, Point, Below, Rest, St) ->
    case landing(Reply, root(Entry), Below) of
        all_directories ->
            passed(Point ++ Below, Rest, St);
        {link, Joined, Name, After} ->
            follow(Entry, Point, Joined, Name, After ++ Rest, St);
        {other, _, _, _} ->
            {error, enotdir};
        {stopped, enoent, Joined, Name, []} when Rest =:= [] ->
            missing(Point ++ Joined, Name, St);
        {stopped, Posix, _, _, _} ->
            {error, Posix};
        {error, _} = Error ->
            Error
    end.

%% Goes on from the walk sent with an action's operation. Names are the
%% target's, or the parent's and then its last name, which the walk did not
%% carry, so that a link the operation met there is the reply's one kind
%% past the directory's. The caller calls this only when the walk stopped
%% short or ended on a link the operation follows: one before the last name,
%% or at it under FOLLOW. A name before the last that is not a directory
%% answers enotdir, and any other reply, whose walk passed and whose
%% operation ended the action, answers eio.
resumed(Reply, Entry, Point, Names, St) ->
    case landing(Reply, root(Entry), Names) of
        {link, Joined, Name, After} when After =/= []; St#st.follow ->
            follow(Entry, Point, Joined, Name, After, St);
        {other, _, _, [_ | _]} ->
            {error, enotdir};
        {stopped, Posix, _, _, _} ->
            {error, Posix};
        {error, _} = Error ->
            Error;
        _ ->
            {error, eio}
    end.

%% A missing last name followed by "/" may be made only as a directory, so the
%% operation's parent follows only under WILLBEDIR, as vfs_lookup has it.
missing(Dir, Last, #st{willbedir = true, op = Op} = St)
  when Op =:= create; Op =:= rename ->
    parent(Dir, Last, St);
missing(_, _, _) ->
    {error, enoent}.

%% Every name of a run joined the place: a "." or ".." acts on it next, or,
%% for a last name followed by "/", the operation's own action follows.
passed(Place, [], St) -> last(Place, St);
passed(Place, [Dot | Rest], St) -> dot(Place, Dot, Rest, St).

%% Where a walk of the entry's Root names and then Names ended, read from its
%% reply: all_directories, every name a directory and the walk ok; {Kind,
%% Joined, Name, After} at Name, a link or other, after the names Joined and
%% before After; or {stopped, Posix, Joined, Name, After} before Name with
%% the walk's error. Every root name must be a directory: a walk that
%% stopped among them answers its error, and one that is not answers
%% enoent, since it has no place in the namespace. A reply that does not fit
%% its request answers eio, as a reply that exceeds its request fails the
%% client's checks: an ending neither ok nor an error, more kinds than
%% names, a kind other than a directory before the last, a short reply
%% ending ok, or a whole one ending in an error.
landing({Kinds, ok}, Root, Names) ->
    root_kinds(Kinds, ok, Root, Names);
landing({Kinds, {error, Posix} = End}, Root, Names) when is_atom(Posix) ->
    root_kinds(Kinds, End, Root, Names);
landing(_, _, _) ->
    {error, eio}.

root_kinds(Kinds, End, [], Names) -> kinds(Kinds, End, Names, []);
root_kinds([directory | Kinds], End, [_ | Root], Names) -> root_kinds(Kinds, End, Root, Names);
root_kinds([], {error, _} = Error, _, _) -> Error;
root_kinds([Kind], _, _, _) when Kind =:= link; Kind =:= other -> {error, enoent};
root_kinds(_, _, _, _) -> {error, eio}.

kinds([directory | Kinds], End, [Name | After], Joined) ->
    kinds(Kinds, End, After, [Name | Joined]);
kinds([], ok, [], _) ->
    all_directories;
kinds([Kind], _, [Name | After], Joined) when Kind =:= link; Kind =:= other ->
    {Kind, lists:reverse(Joined, []), Name, After};
kinds([], {error, Posix}, [Name | After], Joined) ->
    {stopped, Posix, lists:reverse(Joined, []), Name, After};
kinds(_, _, _, _) ->
    {error, eio}.

%% Follows the link Name, below the entry's point after the names Joined,
%% the link's directory: its text is read before Rest.
follow(_, _, _, _, _, #st{links = ?LINKS_MAX}) ->
    {error, eloop};
follow(Entry, Point, Joined, Name, Rest, St) ->
    case (maps:get(read_link, St#st.callbacks))(Entry, root(Entry) ++ Joined ++ [Name]) of
        {ok, Text} when is_binary(Text) ->
            read(Text, Point ++ Joined, Rest, St#st{links = St#st.links + 1});
        {error, Posix} when is_atom(Posix) ->
            {error, Posix};
        _ ->
            {error, eio}
    end.

%% A place and run fit when they hold at most ERX_NS_NAMES_MAX names, each at
%% most ERX_NAME_MAX bytes, and their text with its NUL fits ERX_PATH_MAX, the
%% bounds a working directory is held to.
fits(Place, Run) ->
    length(Place) + length(Run) =< ?ERX_NS_NAMES_MAX andalso
        short(Run) andalso text_size(Place ++ Run, 1) =< ?ERX_PATH_MAX.

short([Name | Names]) -> byte_size(Name) =< ?ERX_NAME_MAX andalso short(Names);
short([]) -> true.

%% The bytes of "/" and each name, from Size.
text_size([Name | Names], Size) -> text_size(Names, Size + 1 + byte_size(Name));
text_size([], Size) -> Size.

%% Where a namespace path lies: on the entry whose mount point is its longest
%% prefix, comparing whole names, with the names below that point; in the
%% empty root when it is "/" or a directory above a mount point that no entry
%% holds; and nowhere otherwise.
place(Path, Table) ->
    case longest(Table, Path, none) of
        {Entry, Below} -> {on, Entry, point(Entry), Below};
        none ->
            case Path =:= [] orelse above_point(Table, Path) of
                true -> empty_root;
                false -> nowhere
            end
    end.

longest([Entry | Table], Path, Best) ->
    case below(point(Entry), Path) of
        {ok, Below} when Best =:= none; length(Below) < length(element(2, Best)) ->
            longest(Table, Path, {Entry, Below});
        _ ->
            longest(Table, Path, Best)
    end;
longest([], _, Best) ->
    Best.

above_point([Entry | Table], Path) ->
    case below(Path, point(Entry)) of
        {ok, [_ | _]} -> true;
        _ -> above_point(Table, Path)
    end;
above_point([], _) ->
    false.

%% The names of Path below Prefix, when Prefix's names begin it.
below([Name | Prefix], [Name | Path]) -> below(Prefix, Path);
below([], Path) -> {ok, Path};
below(_, _) -> false.

point(#{point := Point}) -> Point.
root(#{root := Root}) -> Root.

up([]) -> [];
up(Place) -> element(1, split_last(Place)).

split_last(Names) ->
    [Last | Dir] = lists:reverse(Names, []),
    {lists:reverse(Dir, []), Last}.

names(Text) -> [Name || Name <- binary:split(Text, <<"/">>, [global]), Name =/= <<>>].

%% UTF-8 without NUL.
text(<<>>) -> true;
text(<<0, _/binary>>) -> false;
text(<<_/utf8, Rest/binary>>) -> text(Rest);
text(_) -> false.
