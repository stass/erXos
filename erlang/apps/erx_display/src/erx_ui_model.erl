%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_model).
-moduledoc """
The realised widget tree and its one difference (docs/design-display.md,
"Widget trees"): delta/2 turns one realised tree into another, and
apply_ops/2 applies the operations to a realised tree. The widget
server sends a renderer `delta(R, R1)`, and the web's browser renderer
sends the browser `delta(Sent, Pending)`, a prefix at a time, so the
property `apply_ops(delta(A, B), A) == {ok, B}` covers both.

A realised tree maps each node's number to the node: its parent, its
kind, the properties a renderer shows, and its children's numbers in
order. Number 0 is the top, a node of no kind whose one child, when it
has one, is the root, so the root is inserted, moved and removed as any
other child is.

A node's number fixes its parent and its kind for its whole life, since
identity across trees includes both (erx_ui_model:pair/3 numbers a tree
that way). delta/2 therefore compares nodes by number and never searches
for a subtree; given two trees that break the rule, it raises
`{renumbered, Node}`.

The operations, in order: a `remove` for each topmost node of the first
tree missing from the second; then, in the second tree's depth-first
order, an `insert` for each new node, a `move` for each child outside
the longest run of its parent's children that kept their order, and a
`set` for each node whose properties differ; then `commit`. An index in
an `insert` or `move` is a position in the parent's children as they
stand when the operation applies, after a moved node is taken out, so
every prefix of a delta applies on its own, which a renderer that sends
a long change over several updates relies on. `commit` changes nothing
in the model; it marks where a renderer shows the change.
""".

-export([empty/0, delta/2, apply_ops/2]).
-export_type([realised/0, node_id/0, diff_op/0]).

-record(ui_node, {parent :: node_id() | 0 | none,
                  kind :: atom(),
                  props = #{} :: map(),
                  children = [] :: [node_id()]}).

-doc "The server's number for a node, never reused in a window.".
-type node_id() :: 1..16#ffffffff.
-doc "One operation on a realised tree; `Parent` is 0 for the root.".
-type diff_op() :: {insert, node_id(), Parent :: node_id() | 0, Index :: 0..65535,
                    Kind :: atom(), Props :: map()}
                 | {remove, node_id()}
                 | {set, node_id(), Changed :: map(), Removed :: [atom()]}
                 | {move, node_id(), Index :: 0..65535}
                 | commit.
-doc "A realised tree: each node by its number, and the top, 0.".
-opaque realised() :: #{node_id() | 0 => #ui_node{}}.

-define(TOP, 0).
-define(IS_ID(Id), (is_integer(Id) andalso Id >= 1 andalso Id =< 16#ffffffff)).
-define(IS_INDEX(Index), (is_integer(Index) andalso Index >= 0 andalso Index =< 65535)).

-doc "The realised tree with no nodes, which a renderer starts from.".
-spec empty() -> realised().
empty() -> #{?TOP => #ui_node{parent = none, kind = none}}.

-doc """
The operations that turn realised tree `A` into `B`, numbered from it,
ending with `commit`. Raises `{renumbered, Node}` when `Node` has another
parent or kind in `B` than in `A`.
""".
-spec delta(realised(), realised()) -> [diff_op()].
delta(A, B) ->
    Removes = [{remove, Id} || Id <- preorder(A), Id =/= ?TOP,
                               not is_map_key(Id, B), is_map_key(parent(Id, A), B)],
    Removes ++ lists:reverse(children_ops(?TOP, A, B, []), [commit]).

-doc """
Applies operations in order to a realised tree. The first that does not
fit the tree refuses the whole list as `{error, {Reason, Op}}`, `Reason`
one of `bad_op`, `no_node`, `node_exists`, `root_exists` and `bad_index`.
""".
-spec apply_ops([diff_op()], realised()) ->
          {ok, realised()} | {error, {atom(), term()}}.
apply_ops([], Ui) -> {ok, Ui};
apply_ops([Op | Ops], Ui) ->
    case apply_op(Op, Ui) of
        {ok, Ui1} -> apply_ops(Ops, Ui1);
        {error, Reason} -> {error, {Reason, Op}}
    end;
apply_ops(NotAList, _Ui) -> {error, {bad_op, NotAList}}.

%% The difference.

%% The operations, reversed onto Acc, that turn the children of node N
%% (present in both trees, or new in B) into B's, each child followed by
%% its own subtree's.
%%
%% Current is N's children as the operations so far leave them. It starts
%% as A's children that B keeps, in A's order. B's children are visited
%% in order; a new child is inserted and a kept child outside the run is
%% moved, each directly after the previously visited sibling, or first
%% when there is none. Children of the run never move, so they keep A's
%% order, which is B's order among them. Hence every visited child stands
%% before every unvisited child of the run, and the visited children stand
%% in B's order; unvisited children outside the run may stand anywhere
%% until their turn. Once all are visited, Current is B's children. For
%% A = [x, y, z] and B = [y, z, x] the run is [y, z]: y and z stand at 1
%% and 2 behind the unvisited x, and x moves after z, to index 2.
children_ops(N, A, B, Acc) ->
    Current = [C || C <- children(N, A), is_map_key(C, B)],
    Run = kept_run(Current, children(N, B)),
    {_, _, Acc1} = lists:foldl(fun(C, Visit) -> visit_child(C, N, A, B, Run, Visit) end,
                               {none, Current, Acc}, children(N, B)),
    Acc1.

%% Child C of N in B, visited after sibling Prev: its insert or move, its
%% set, then its subtree.
visit_child(C, N, A, B, Run, {Prev, Current, Acc}) ->
    #ui_node{kind = Kind, props = Props} = get_node(C, B),
    {Current1, Acc1} =
        case A of
            #{C := #ui_node{parent = N, kind = Kind, props = Old}} ->
                {Placed, PlaceOps} = place(C, Prev, Current, Run, Acc),
                {Placed, set_op(C, Old, Props, PlaceOps)};
            #{C := _} ->
                erlang:error({renumbered, C});
            #{} ->
                Index = after_index(Prev, Current),
                {insert_at(Index, C, Current), [{insert, C, N, Index, Kind, Props} | Acc]}
        end,
    {C, Current1, children_ops(C, A, B, Acc1)}.

%% A kept child outside the run moves to directly after its previous
%% sibling; one in the run stays where it stands.
place(C, Prev, Current, Run, Acc) ->
    case sets:is_element(C, Run) of
        true ->
            {Current, Acc};
        false ->
            Rest = lists:delete(C, Current),
            Index = after_index(Prev, Rest),
            {insert_at(Index, C, Rest), [{move, C, Index} | Acc]}
    end.

after_index(none, _Current) -> 0;
after_index(Prev, Current) -> index_of(Prev, Current) + 1.

set_op(_C, Props, Props, Acc) -> Acc;
set_op(C, Old, New, Acc) ->
    Changed = maps:filter(fun(Key, Value) -> not is_map_key(Key, Old) orelse
                                                 maps:get(Key, Old) =/= Value
                          end, New),
    Removed = [Key || Key <- lists:sort(maps:keys(Old)), not is_map_key(Key, New)],
    [{set, C, Changed, Removed} | Acc].

%% The longest run of the kept children whose order B does not change: the
%% longest subsequence of Target's kept children that is increasing in
%% their positions in Current. Each entry of Runs is a kept child's
%% position, the run's length, and the longest run ending with it,
%% reversed. Quadratic in a node's children; any increasing run would be
%% correct, and the longest emits the fewest moves.
kept_run(Current, Target) ->
    Positions = maps:from_list(lists:zip(Current, lists:seq(0, length(Current) - 1))),
    Kept = [{maps:get(C, Positions), C} || C <- Target, is_map_key(C, Positions)],
    Runs = lists:foldl(
             fun({Position, C}, Acc) ->
                     {Length, Run} = longest([{L, R} || {P, L, R} <- Acc, P < Position]),
                     [{Position, Length + 1, [C | Run]} | Acc]
             end, [], Kept),
    {_, Best} = longest([{L, R} || {_, L, R} <- Runs]),
    sets:from_list(Best, [{version, 2}]).

longest(Runs) -> lists:foldl(fun({L, _} = Run, {Best, _}) when L > Best -> Run;
                                (_, Best) -> Best
                             end, {0, []}, Runs).

%% The tree's numbers in depth-first order, the top first.
preorder(Ui) -> preorder([?TOP], Ui, []).

preorder([], _Ui, Acc) -> lists:reverse(Acc);
preorder([Id | Rest], Ui, Acc) -> preorder(children(Id, Ui) ++ Rest, Ui, [Id | Acc]).

%% Applying one operation.

apply_op({insert, Id, Parent, Index, Kind, Props}, Ui)
  when ?IS_ID(Id), (Parent =:= ?TOP orelse ?IS_ID(Parent)), ?IS_INDEX(Index),
       is_atom(Kind), is_map(Props) ->
    case Ui of
        #{Id := _} -> {error, node_exists};
        #{?TOP := #ui_node{children = [_]}} when Parent =:= ?TOP -> {error, root_exists};
        #{Parent := #ui_node{children = Siblings} = P} when Index =< length(Siblings) ->
            {ok, Ui#{Id => #ui_node{parent = Parent, kind = Kind, props = Props},
                     Parent := P#ui_node{children = insert_at(Index, Id, Siblings)}}};
        #{Parent := _} -> {error, bad_index};
        #{} -> {error, no_node}
    end;
apply_op({remove, Id}, Ui) when ?IS_ID(Id) ->
    case Ui of
        #{Id := #ui_node{parent = Parent}} ->
            P = get_node(Parent, Ui),
            Ui1 = maps:without(subtree([Id], Ui, []), Ui),
            Siblings = lists:delete(Id, P#ui_node.children),
            {ok, Ui1#{Parent := P#ui_node{children = Siblings}}};
        #{} -> {error, no_node}
    end;
apply_op({set, Id, Changed, Removed}, Ui)
  when ?IS_ID(Id), is_map(Changed), is_list(Removed) ->
    case Ui of
        #{Id := #ui_node{props = Props} = Node} ->
            case is_atom_list(Removed) of
                true ->
                    Props1 = maps:without(Removed, maps:merge(Props, Changed)),
                    {ok, Ui#{Id := Node#ui_node{props = Props1}}};
                false ->
                    {error, bad_op}
            end;
        #{} -> {error, no_node}
    end;
apply_op({move, Id, Index}, Ui) when ?IS_ID(Id), ?IS_INDEX(Index) ->
    case Ui of
        #{Id := #ui_node{parent = Parent}} ->
            P = get_node(Parent, Ui),
            Rest = lists:delete(Id, P#ui_node.children),
            case Index =< length(Rest) of
                true ->
                    Siblings = insert_at(Index, Id, Rest),
                    {ok, Ui#{Parent := P#ui_node{children = Siblings}}};
                false -> {error, bad_index}
            end;
        #{} -> {error, no_node}
    end;
apply_op(commit, Ui) -> {ok, Ui};
apply_op(_Op, _Ui) -> {error, bad_op}.

%% A proper list of atoms, as `set` removes property names.
is_atom_list([]) -> true;
is_atom_list([Key | Rest]) when is_atom(Key) -> is_atom_list(Rest);
is_atom_list(_) -> false.

subtree([], _Ui, Acc) -> Acc;
subtree([Id | Rest], Ui, Acc) -> subtree(children(Id, Ui) ++ Rest, Ui, [Id | Acc]).

%% Tree access.

get_node(Id, Ui) -> maps:get(Id, Ui).

parent(Id, Ui) -> (get_node(Id, Ui))#ui_node.parent.

children(Id, Ui) ->
    case Ui of
        #{Id := #ui_node{children = Children}} -> Children;
        #{} -> []
    end.

index_of(Id, List) -> index_of(Id, List, 0).

index_of(Id, [Id | _], Index) -> Index;
index_of(Id, [_ | Rest], Index) -> index_of(Id, Rest, Index + 1).

insert_at(Index, Id, List) ->
    {Before, After} = lists:split(Index, List),
    Before ++ [Id | After].
