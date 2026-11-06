%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The reference model of erx_path: FreeBSD's namei and vfs_lookup
%% (sys/kern/vfs_lookup.c, the version the design's Sources name) transcribed over an
%% erx_path_tree tree with a table's entries mounted on it, for the fuzz
%% target's comparison (docs/design-files.md, Verification).
%%
%% It shares nothing with erx_path's own approach. erx_path keeps a place, a
%% list of names, and walks each run from its entry's top; the model keeps
%% FreeBSD's current directory, a vnode, and reads the path's text a
%% component at a time. A vnode is {Entry, Node}, a node of the tree as that
%% entry's mount shows it, or {empty, Path}, a directory of the empty root of
%% a table without "/". Each entry is mounted as mount(8) mounts a file
%% system: its point is looked up through the entries mounted before it, and
%% the vnode found is covered, so a lookup that reaches it continues at the
%% entry's root, and ".." at the entry's root steps back through it.
%% ".." elsewhere takes the node's parent in the tree; at "/" it stays.
%%
%% One rule departs from vfs_lookup's text, as the design states: a last "."
%% or ".." of DELETE or RENAME is refused with EINVAL only once the name
%% before it is found to be a directory, the order of FreeBSD's name-cache
%% lookup, where vfs_lookup refuses it first.
%%
%% The outcome is the one erx_path's executor reaches: a lookup's target
%% vnode, the parent directory and name of a create, delete or rename, the
%% top when that name is the root of a mounted entry or a create's last "."
%% or "..", the empty root's directory that a lookup reaches or a create
%% names, or an error. The empty root is read-only: every last name in it
%% of a delete or rename, and a missing one of a create, is EROFS, as
%% vfs_cache_lookup and a file system's write check answer on a read-only
%% mount.

-module(erx_path_model).
-export([namespace/2, namei/5, cwd/2, lookup/3, type/2, children/2]).

-define(MAXSYMLINKS, 32).
-define(NAME_MAX, 255).
-define(MAXPATHLEN, 4096).

%% The namespace: the tree, the root vnode, each entry's root vnode, the
%% vnode each entry covers and the reverse, and the points of the empty
%% root's mounts. Mounts are attempted in order of their points' length; an
%% entry whose point or root is not a directory reached without a link is
%% left out, as mount(8) would refuse it, and namespace/2 returns the entries
%% it mounted, which are the table both sides resolve against.
namespace(Table, Tree) ->
    Mounted = settle(Table, Tree),
    {build(Mounted, Tree), Mounted}.

settle(Table, Tree) ->
    Sorted = lists:sort(fun(A, B) -> length(point(A)) =< length(point(B)) end,
                        Table),
    Mounted = mount_all(Sorted, Tree),
    case length(Mounted) =:= length(Table) of
        true -> Table -- (Table -- Mounted);
        false -> settle(Mounted, Tree)
    end.

mount_all(Sorted, Tree) ->
    Empty = #{tree => Tree, table => Sorted, mounted => #{}, roots => #{},
              covered => #{}, root => {empty, []}},
    {_, Mounted} = lists:foldl(fun(Entry, {NS, Done}) ->
                                       case mount(Entry, NS) of
                                           {ok, NS1} -> {NS1, [Entry | Done]};
                                           refused -> {NS, Done}
                                       end
                               end, {Empty, []}, Sorted),
    lists:reverse(Mounted).

build(Mounted, Tree) ->
    Empty = #{tree => Tree, table => Mounted, mounted => #{}, roots => #{},
              covered => #{}, root => {empty, []}},
    lists:foldl(fun(Entry, NS) -> {ok, NS1} = mount(Entry, NS), NS1 end,
                Empty, Mounted).

mount(Entry, NS = #{tree := Tree, roots := Roots}) ->
    case node_of(Tree, 0, root(Entry)) of
        {ok, Node} ->
            RootVnode = {Entry, Node},
            NS1 = NS#{roots := Roots#{Entry => RootVnode}},
            case point(Entry) of
                [] ->
                    {ok, NS1#{root := RootVnode}};
                Point ->
                    case lookup_dirs(maps:get(root, NS), Point, NS) of
                        {ok, Covered} ->
                            #{mounted := Mounted, covered := Covers} = NS1,
                            {ok, NS1#{mounted := Mounted#{Covered => Entry},
                                      covered := Covers#{Entry => Covered}}};
                        refused ->
                            refused
                    end
            end;
        refused ->
            refused
    end.

%% A tree path of directories, without links, from Id.
node_of(_, Id, []) -> {ok, Id};
node_of(Tree, Id, [Name | Names]) ->
    case maps:get(Id, Tree) of
        {dir, #{Name := Child}, _} ->
            case maps:get(Child, Tree) of
                {dir, _, _} -> node_of(Tree, Child, Names);
                _ -> refused
            end;
        _ ->
            refused
    end.

lookup_dirs(Vnode, [], _) -> {ok, Vnode};
lookup_dirs(Vnode, [Name | Names], NS) ->
    case lookup(Vnode, Name, NS) of
        none -> refused;
        Found ->
            case type(Found, NS) of
                dir -> lookup_dirs(Found, Names, NS);
                _ -> refused
            end
    end.

%% The working directory's vnode, for a place of plain names that are each
%% a directory reached without a link.
cwd(Place, NS) ->
    {ok, Vnode} = lookup_dirs(maps:get(root, NS), Place, NS),
    Vnode.

%% The names a directory holds, for the fuzz target to steer its paths by.
children({empty, Path}, NS) ->
    lists:usort([Name || E <- maps:get(table, NS), {ok, [Name | _]} <- [suffix(Path, point(E))]]);
children({_, Id}, #{tree := Tree}) ->
    case maps:get(Id, Tree) of
        {dir, Children, _} -> maps:keys(Children);
        _ -> []
    end.

suffix([Name | Prefix], [Name | Names]) -> suffix(Prefix, Names);
suffix([], Names) -> {ok, Names};
suffix(_, _) -> false.

%% VOP_LOOKUP of a plain name in a directory, then the crossing into an entry
%% mounted on the vnode found, as vfs_lookup's cross_mount does.
lookup({empty, Path}, Name, NS) ->
    Child = Path ++ [Name],
    case lists:any(fun(E) -> lists:prefix(Child, point(E)) end, maps:get(table, NS)) of
        true -> cross({empty, Child}, NS);
        false -> none
    end;
lookup({Entry, Id}, Name, NS = #{tree := Tree}) ->
    case maps:get(Id, Tree) of
        {dir, #{Name := Child}, _} -> cross({Entry, Child}, NS);
        _ -> none
    end.

cross(Vnode, NS = #{mounted := Mounted, roots := Roots}) ->
    case Mounted of
        #{Vnode := Entry} -> cross(maps:get(Entry, Roots), NS);
        #{} -> Vnode
    end.

type({empty, _}, _) -> dir;
type({_, Id}, #{tree := Tree}) ->
    case maps:get(Id, Tree) of
        {dir, _, _} -> dir;
        {link, _} -> link;
        file -> file
    end.

%% "..", by vfs_lookup's loop: at the process's root it stays; at the root of
%% a mounted entry it steps to the covered vnode and looks again; elsewhere
%% it is the node's parent.
dotdot(Dp, NS) ->
    case Dp =:= maps:get(root, NS) of
        true -> Dp;
        false ->
            case mount_root_of(Dp, NS) of
                {ok, Entry} -> dotdot(maps:get(Entry, maps:get(covered, NS)), NS);
                none -> parent(Dp, NS)
            end
    end.

mount_root_of({empty, _}, _) -> none;
mount_root_of(Vnode = {Entry, _}, #{roots := Roots}) ->
    case Roots of
        #{Entry := Vnode} -> {ok, Entry};
        #{} -> none
    end.

parent({empty, Path}, _) -> {empty, lists:droplast(Path)};
parent({Entry, Id}, #{tree := Tree}) ->
    {dir, _, Up} = maps:get(Id, Tree),
    {Entry, Up}.

%% namei: an empty path is ENOENT and one that does not fit MAXPATHLEN with
%% its NUL ENAMETOOLONG; the walk starts at the root for an absolute path and
%% at the working directory otherwise.
namei(<<>>, _, _, _, _) ->
    {error, enoent};
namei(Path, _, _, _, _) when byte_size(Path) >= ?MAXPATHLEN ->
    {error, enametoolong};
namei(Path, Op, Flags, NS, Cwd) ->
    Nd = #{op => Op, follow => maps:get(follow, Flags),
           willbedir => maps:get(willbedir, Flags), slash => false,
           loopcnt => 0, ns => NS},
    outcome(pass(Path, Cwd, Nd), Nd).

%% One pass of vfs_lookup over a buffer, from the directory Dp: leading
%% slashes restart at the root, an empty name is the degenerate case, and
%% trailing slashes are cut off and set TRAILINGSLASH, which stays set.
pass(Buf, Dp, Nd = #{ns := NS}) ->
    {Buf1, Dp1} = case Buf of
                      <<"/", _/binary>> -> {strip_leading(Buf), maps:get(root, NS)};
                      _ -> {Buf, Dp}
                  end,
    case Buf1 of
        <<>> ->
            case maps:get(op, Nd) of
                lookup -> {found, Dp1, Dp1, <<>>};
                _ -> {error, eisdir}
            end;
        _ ->
            {Buf2, Slashed} = strip_trailing(Buf1),
            dirloop(Buf2, Dp1, Nd#{slash := maps:get(slash, Nd) orelse Slashed})
    end.

dirloop(Buf, Dp, Nd = #{ns := NS, op := Op}) ->
    {Name, Next} = component(Buf),
    Last = Next =:= <<>>,
    Dot = Name =:= <<".">> orelse Name =:= <<"..">>,
    if
        byte_size(Name) > ?NAME_MAX -> {error, enametoolong};
        true ->
            case type(Dp, NS) of
                dir when Last andalso Dot andalso (Op =:= delete orelse Op =:= rename) ->
                    {error, einval};
                dir ->
                    Vp = case Name of
                             <<".">> -> Dp;
                             <<"..">> -> dotdot(Dp, NS);
                             _ -> lookup(Dp, Name, NS)
                         end,
                    found(Vp, Dp, Name, Next, Last, Nd);
                _ ->
                    {error, enotdir}
            end
    end.

%% What vfs_lookup does with the vnode a component reached.
found(none, {empty, _}, _, _, true, #{op := Op}) when Op =/= lookup ->
    %% The empty root is read-only: vfs_cache_lookup answers EROFS for a
    %% last name of DELETE or RENAME before it looks, and a missing name's
    %% CREATE fails its write check with EROFS, before TRAILINGSLASH counts.
    {error, erofs};
found(none, Dp, Name, _, true, Nd = #{op := Op}) when Op =/= lookup ->
    %% A missing name followed by "/" is made only as a directory: VOP_LOOKUP
    %% answers EJUSTRETURN for CREATE and RENAME alone, then WILLBEDIR.
    case maps:get(slash, Nd) andalso
             (Op =:= delete orelse not maps:get(willbedir, Nd)) of
        true -> {error, enoent};
        false -> {created, Dp, Name}
    end;
found(none, _, _, _, _, _) ->
    {error, enoent};
found(Vp, Dp, Name, Next, Last, Nd = #{ns := NS}) ->
    Follows = maps:get(follow, Nd) orelse maps:get(slash, Nd) orelse not Last,
    case type(Vp, NS) =:= link andalso Follows of
        true ->
            follow_link(Vp, Dp, Next, Nd);
        false when not Last ->
            dirloop(strip_leading(Next), Vp, Nd);
        false ->
            case maps:get(slash, Nd) andalso type(Vp, NS) =/= dir of
                true -> {error, enotdir};
                false -> {found, Dp, Vp, Name}
            end
    end.

%% namei_follow_link: the link's text is read, an empty one is ENOENT, one
%% that with the rest of the buffer does not fit MAXPATHLEN ENAMETOOLONG, and
%% the text followed by the rest is looked up from the link's directory.
follow_link(_, _, _, #{loopcnt := ?MAXSYMLINKS}) ->
    {error, eloop};
follow_link({_, Id}, Dp, Next, Nd = #{ns := #{tree := Tree}, loopcnt := Count}) ->
    {link, Text} = maps:get(Id, Tree),
    if
        Text =:= <<>> -> {error, enoent};
        byte_size(Text) + byte_size(Next) + 1 > ?MAXPATHLEN -> {error, enametoolong};
        true -> pass(<<Text/binary, Next/binary>>, Dp, Nd#{loopcnt := Count + 1})
    end.

component(Buf) ->
    case binary:split(Buf, <<"/">>) of
        [Name] -> {Name, <<>>};
        [Name, Rest] -> {Name, <<"/", Rest/binary>>}
    end.

strip_leading(<<"/", Rest/binary>>) -> strip_leading(Rest);
strip_leading(Buf) -> Buf.

strip_trailing(Buf) ->
    Size = byte_size(Buf) - 1,
    case Buf of
        <<Head:Size/binary, "/">> -> {element(1, strip_trailing(Head)), true};
        _ -> {Buf, false}
    end.

%% The model's result as an action: a vnode named by its entry and its tree
%% names, the parent's directory with the last name, or the top.
outcome({error, _} = Error, _) ->
    Error;
outcome({found, _, Vp, _}, #{op := lookup, ns := NS}) ->
    target(Vp, NS);
outcome({found, Dp, Vp, Name}, #{op := Op, ns := NS}) ->
    Dot = Name =:= <<".">> orelse Name =:= <<"..">>,
    case element(1, Dp) =:= empty andalso not Dot of
        %% DELETE and RENAME in the read-only empty root are refused before
        %% the name is looked up, so before a mount on it is crossed.
        true when Op =/= create -> {error, erofs};
        _ when Dot -> top(Vp);
        _ -> case mount_root_of(Vp, NS) =/= none orelse element(1, Dp) =:= empty of
                 true -> top(Vp);
                 false -> parent(Dp, Name, NS)
             end
    end;
outcome({created, Dp, Name}, #{ns := NS}) ->
    parent(Dp, Name, NS).

target({empty, Path}, _) -> {empty_root, Path};
target({Entry, Id}, #{tree := Tree}) -> {target, Entry, names_of(Tree, Id)}.

top({empty, Path}) -> {empty_root, Path};
top({Entry, _}) -> {top, Entry}.

parent({Entry, Id}, Name, #{tree := Tree}) -> {parent, Entry, names_of(Tree, Id), Name}.

%% A node's names from the tree's root, through the directories that hold it.
names_of(_, 0) -> [];
names_of(Tree, Id) ->
    [{Up, Name}] = [{Dir, N} || {Dir, {dir, Children, _}} <- maps:to_list(Tree),
                                {N, Child} <- maps:to_list(Children), Child =:= Id],
    names_of(Tree, Up) ++ [Name].

point(#{point := Point}) -> Point.
root(#{root := Root}) -> Root.
