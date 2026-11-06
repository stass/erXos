%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A model file tree, the server that answers erx_path's walks and link reads
%% on it, and the executor that drives one resolution to its outcome, as
%% erx_file_remote drives one against a grant (docs/design-files.md, Erlang
%% clients). The tests and the fuzz target of erx_path share them.
%%
%% A tree is a map from node number to node, 0 its root: {dir, Children,
%% Parent}, with Children a map from name to node number and the root its
%% own parent, file, or {link, Text}. Every entry of a table built over it
%% names the one tree, from its root names, as binds of one grant do.

-module(erx_path_tree).
-export([new/1, walk/2, read_link/2, callbacks/1, resolve/6, execute/3]).

%% A tree from a nested description: a map from name to a description is a
%% directory, the atom file a file, and {link, Text} a symbolic link.
new(Spec) when is_map(Spec) ->
    add(Spec, 0, #{}).

add(Spec, Parent, Tree) when is_map(Spec) ->
    Id = map_size(Tree),
    maps:fold(fun(Name, Child, Acc) ->
                      ChildId = map_size(Acc),
                      Added = add(Child, Id, Acc),
                      {dir, Children, Up} = maps:get(Id, Added),
                      Added#{Id := {dir, Children#{Name => ChildId}, Up}}
              end, Tree#{Id => {dir, #{}, Parent}}, Spec);
add(file, _, Tree) ->
    Tree#{map_size(Tree) => file};
add({link, Text}, _, Tree) ->
    Tree#{map_size(Tree) => {link, Text}}.

%% A walk from the tree's root, as a server answers one: the kind of each
%% name passed, up to and including the first that is not a directory, and
%% enoent for a missing name or enotdir for one past a file or a link.
walk(Tree, Names) ->
    walk(Tree, 0, Names, []).

walk(_, _, [], Kinds) ->
    {lists:reverse(Kinds), ok};
walk(Tree, Id, [Name | Names], Kinds) ->
    {dir, Children, _} = maps:get(Id, Tree),
    case Children of
        #{Name := Child} ->
            case maps:get(Child, Tree) of
                {dir, _, _} ->
                    walk(Tree, Child, Names, [directory | Kinds]);
                Leaf ->
                    Ending = case Names of
                                 [] -> ok;
                                 _ -> {error, enotdir}
                             end,
                    {lists:reverse([kind(Leaf) | Kinds]), Ending}
            end;
        #{} ->
            {lists:reverse(Kinds), {error, enoent}}
    end.

kind({link, _}) -> link;
kind(file) -> other.

%% A walk to a link and its readlink, sent together.
read_link(Tree, Names) ->
    case walk(Tree, Names) of
        {Kinds, ok} when length(Kinds) =:= length(Names) ->
            case node_at(Tree, 0, Names) of
                {link, Text} -> {ok, Text};
                _ -> {error, einval}
            end;
        {_, ok} ->
            {error, enotdir};
        {_, Error} ->
            Error
    end.

node_at(Tree, Id, []) ->
    maps:get(Id, Tree);
node_at(Tree, Id, [Name | Names]) ->
    {dir, #{Name := Child}, _} = maps:get(Id, Tree),
    node_at(Tree, Child, Names).

callbacks(Tree) ->
    #{walk => fun(_, Names) -> walk(Tree, Names) end,
      read_link => fun(_, Names) -> read_link(Tree, Names) end}.

%% One resolution over Tree, driven to its outcome by execute/3.
resolve(Path, Op, Flags, Table, Cwd, Tree) ->
    Action = erx_path:resolve(Path, Op, Flags, Table, Cwd, callbacks(Tree)),
    execute(Action, Tree, maps:get(follow, Flags)).

%% Drives an action as the client does: sends each target's and parent's walk
%% with the operation, and calls the resumption with the walk's reply when
%% the walk stopped short or ended on a link the operation follows; for a
%% parent, a link at its last name, which the operation met there (lcreate's
%% eloop), is one more kind of the reply, and an operation sent on a parent
%% that is a file fails as the server fails it, with enotdir. The outcome is
%% the last action
%% without its resumption, or the resolution's error. A resolver that keeps
%% asking past every bound is reported as unbounded.
execute(Action, Tree, Follow) ->
    execute(Action, Tree, Follow, 100).

execute(_, _, _, 0) ->
    erlang:error(unbounded);
execute({target, Entry, Names, Resume}, Tree, Follow, Fuel) ->
    Reply = walk(Tree, Names),
    case stopped(Reply, Names) orelse (Follow andalso ends_on_link(Reply)) of
        true -> execute(Resume(Reply), Tree, Follow, Fuel - 1);
        false -> {target, Entry, Names}
    end;
execute({parent, Entry, Names, Last, Resume}, Tree, Follow, Fuel) ->
    Reply = walk(Tree, Names),
    case stopped(Reply, Names) orelse ends_on_link(Reply) of
        true ->
            execute(Resume(Reply), Tree, Follow, Fuel - 1);
        false ->
            {Kinds, ok} = Reply,
            OnFile = Kinds =/= [] andalso lists:last(Kinds) =:= other,
            case OnFile orelse Follow andalso ends_on_link(walk(Tree, Names ++ [Last])) of
                true when OnFile -> {error, enotdir};
                true -> execute(Resume({Kinds ++ [link], ok}), Tree, Follow, Fuel - 1);
                false -> {parent, Entry, Names, Last}
            end
    end;
execute(Outcome, _, _, _) ->
    Outcome.

stopped({Kinds, _}, Names) -> length(Kinds) < length(Names).

ends_on_link({Kinds, _}) -> Kinds =/= [] andalso lists:last(Kinds) =:= link.
