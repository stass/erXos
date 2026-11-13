%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_model).
-moduledoc """
The realised widget tree and the four pure functions that do all the tree
work (docs/design-display.md, "Widget trees"): pair/3 numbers an
application's tree against the realised one, delta/2 turns one realised
tree into another, apply_ops/2 applies the operations to a realised tree,
and hit/4 checks a renderer's report against it. The widget
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

A realised node's properties are the tree's own, its `key` and its event
terms included, which the binary form never writes, plus the state value
the server keeps for it: the last the tree set or the user made through
the renderer, whichever came later. pair/3 and hit/4 take every fact about
kinds and properties (which property is a kind's state, which are fixed,
which events a kind takes, what a value may be) from erx_ui_schema, so
ui.txt stays the one source.
""".

-export([empty/0, pair/3, delta/2, apply_ops/2, hit/4]).
-export_type([realised/0, node_id/0, diff_op/0, tree/0, next/0]).

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
-doc "The number pair/3 gives next; past the last node_id() when none is left.".
-type next() :: 1..16#100000000.
-doc "An application's widget tree, valid by erx_ui_schema:validate/2.".
-type tree() :: {Kind :: atom(), Props :: #{atom() => term()}, Children :: [tree()]}.
-doc "A realised tree: each node by its number, and the top, 0.".
-opaque realised() :: #{node_id() | 0 => #ui_node{}}.

-define(TOP, 0).
-define(IS_ID(Id), (is_integer(Id) andalso Id >= 1 andalso Id =< 16#ffffffff)).
%% The number after the last a window can give: pair/3 refuses to reach it.
-define(PAST_LAST_ID, 16#100000000).
-define(IS_INDEX(Index), (is_integer(Index) andalso Index >= 0 andalso Index =< 65535)).

-doc "The realised tree with no nodes, which a renderer starts from.".
-spec empty() -> realised().
empty() -> #{?TOP => #ui_node{parent = none, kind = none}}.

-doc """
Numbers `Tree`, which erx_ui_schema:validate/2 accepted, against realised
tree `Ui`. A node whose identity matches a realised node keeps that node's
number and its kept state; any other node takes the next number, from
`Next` on, in depth-first order. A node's identity is its parent's, its
kind, its fixed properties, and its `key` when it has one or else its
index among its siblings, so a node never changes parent or kind. A state
property the tree omits keeps the realised node's value while the node's
new properties admit it. Answers the realised tree and the number to give
next, or `{error, limit}` when a node would need a number past 2^32 - 1.
""".
-spec pair(realised(), tree(), Next :: next()) -> {realised(), next()} | {error, limit}.
pair(Ui, Tree, Next) when is_integer(Next), Next >= 1, Next =< ?PAST_LAST_ID ->
    try pair_children(?TOP, children(?TOP, Ui), [Tree], Ui, {#{}, Next}) of
        {Root, {Paired, Next1}} ->
            {Paired#{?TOP => #ui_node{parent = none, kind = none, children = Root}}, Next1}
    catch
        throw:{?MODULE, limit} -> {error, limit}
    end.

-doc """
Checks a renderer's report of event `Event` on node `Node` against
realised tree `Ui`; `Value` is the node's new state value for an event
whose detail is the state (`on_change`, `on_submit`), and `none`
otherwise. A state value is recorded, except a secret `input`'s text,
which is never kept and reaches the application as `{erx_secret, Text}`.
Answers `{fire, Term, Detail, Ui1}` when the node carries the event, `Term`
the tree's value for it; `{keep, Ui1}` when the node's kind takes the
event but the node does not carry it; and `drop`, recording nothing, for a
node not in the tree, an event the kind does not take, a value the node's
state property does not admit, a value on an event that carries none, and
a `select` on a node with no `present` whose status is `ok` or `partial`.
A `select`'s detail is the tree's own `{select, Type, Value}`, never the
renderer's.
""".
-spec hit(realised(), Node :: term(), Event :: term(), Value :: term()) ->
          {fire, Term :: term(), Detail :: term(), realised()} | {keep, realised()} | drop.
hit(Ui, Node, Event, Value) when Node =/= ?TOP ->
    case Ui of
        #{Node := #ui_node{kind = Kind, props = Props} = N} ->
            case takes_event(Kind, Event) andalso detail(Event, Value, Kind, Props) of
                {ok, Detail, Props1} ->
                    Ui1 = Ui#{Node := N#ui_node{props = Props1}},
                    case Props of
                        #{Event := Term} -> {fire, Term, Detail, Ui1};
                        #{} -> {keep, Ui1}
                    end;
                _NotTaken -> drop
            end;
        #{} ->
            drop
    end;
hit(_Ui, _Top, _Event, _Value) ->
    drop.

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

%% The numbering.

%% Numbers Trees, the children of node Parent, against Old, the realised
%% children of the node Parent paired with (none for a new node): each
%% takes the number of the old child of its identity, or the next number.
%% Answers their numbers in order and the accumulator, the tree paired so
%% far and the number to give next.
pair_children(Parent, Old, Trees, Ui, Acc) ->
    Known = maps:from_list([{identity(Kind, Props, Index), Id}
                            || {Index, Id} <- lists:enumerate(0, Old),
                               #ui_node{kind = Kind, props = Props} <- [get_node(Id, Ui)]]),
    {Ids, {Acc1, _}} = lists:mapfoldl(
                         fun(Tree, {AccN, Index}) ->
                                 {Id, AccN1} = pair_node(Parent, Tree, Index, Known, Ui, AccN),
                                 {Id, {AccN1, Index + 1}}
                         end, {Acc, 0}, Trees),
    {Ids, Acc1}.

pair_node(Parent, {Kind, Props, Trees}, Index, Known, Ui, Acc) ->
    {Id, Kept, Old, Acc1} =
        case maps:find(identity(Kind, Props, Index), Known) of
            {ok, Same} ->
                #ui_node{props = OldProps, children = OldChildren} = get_node(Same, Ui),
                {Same, keep_state(Kind, Props, OldProps), OldChildren, Acc};
            error ->
                {New, AccNew} = next_id(Acc),
                {New, Props, [], AccNew}
        end,
    {Children, {Paired, Next}} = pair_children(Id, Old, Trees, Ui, Acc1),
    Node = #ui_node{parent = Parent, kind = Kind, props = Kept, children = Children},
    {Id, {Paired#{Id => Node}, Next}}.

next_id({_Paired, ?PAST_LAST_ID}) -> throw({?MODULE, limit});
next_id({Paired, Next}) -> {Next, {Paired, Next + 1}}.

%% A node's identity among its siblings: its kind, its fixed properties
%% (absent as their default), and its key or else its index.
identity(Kind, Props, Index) ->
    #{fixed := Fixed} = erx_ui_schema:kind(Kind),
    Place = case Props of
                #{key := Key} -> {key, Key};
                #{} -> {index, Index}
            end,
    {Kind, [fixed_value(Property, Props) || Property <- Fixed], Place}.

fixed_value(Property, Props) ->
    case Props of
        #{Property := Value} -> Value;
        #{} -> maps:get(default, erx_ui_schema:property(Property), absent)
    end.

%% The tree's properties, with the realised node's state value where the
%% tree omits the kind's state property and the node's new properties
%% admit the value; a value that no longer fits is dropped.
keep_state(Kind, Props, Old) ->
    #{state := State} = erx_ui_schema:kind(Kind),
    case Old of
        #{State := Value} when not is_map_key(State, Props) ->
            Kept = Props#{State => Value},
            case admits(Kind, Kept) of
                true -> Kept;
                false -> Props
            end;
        #{} ->
            Props
    end.

%% Whether a node of Kind with Props and no children is valid, by the
%% generated validator, so a state value meets every bound ui.txt gives it.
admits(Kind, Props) -> erx_ui_schema:validate({Kind, Props, []}, 1) =:= ok.

%% Events.

takes_event(Kind, Event) ->
    #{takes := Takes} = erx_ui_schema:kind(Kind),
    lists:member(Event, Takes) andalso maps:get(type, erx_ui_schema:property(Event)) =:= event.

%% An event's detail and the node's properties after it, or drop.
detail(on_click, none, _Kind, Props) -> {ok, click, Props};
detail(on_select, none, _Kind, Props) ->
    case selection(maps:get(present, Props, none)) of
        {ok, Type, Value} -> {ok, {select, Type, Value}, Props};
        error -> drop
    end;
detail(on_change, Value, Kind, Props) -> state_detail(change, Value, Kind, Props);
detail(on_submit, Value, Kind, Props) -> state_detail(submit, Value, Kind, Props);
detail(_Event, _Value, _Kind, _Props) -> drop.

%% A state event: the value must be one the node's state property admits,
%% and a plain value, never a tuple: the status form a tree may give a
%% status property such as `text` is no value a user makes. A secret
%% input's text is checked as an open input's would be, and neither kept
%% nor shown.
state_detail(_Tag, Value, _Kind, _Props) when is_tuple(Value) -> drop;
state_detail(Tag, Value, Kind, Props) ->
    #{state := State} = erx_ui_schema:kind(Kind),
    case Props of
        #{secret := true} ->
            case admits(Kind, (maps:remove(secret, Props))#{State => Value}) of
                true -> {ok, {Tag, {erx_secret, Value}}, Props};
                false -> drop
            end;
        #{} ->
            Recorded = Props#{State => Value},
            case admits(Kind, Recorded) of
                true -> {ok, {Tag, Value}, Recorded};
                false -> drop
            end
    end.

%% The {Type, Value} of a `present` property whose status is `ok` or
%% `partial`. As erx_ui_wire reads one, a two-tuple whose first element is
%% a reporter is an attr() carrying the presentation; anything else is the
%% presentation itself.
selection({Reporter, Carried}) when Reporter =:= kernel; Reporter =:= service;
                                    Reporter =:= runtime ->
    carried(Carried);
selection({{stopgap, _}, Carried}) -> carried(Carried);
selection({Type, Value}) -> {ok, Type, Value};
selection(_None) -> error.

carried({ok, {Type, Value}}) -> {ok, Type, Value};
carried({partial, {Type, Value}}) -> {ok, Type, Value};
carried(_Status) -> error.

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
