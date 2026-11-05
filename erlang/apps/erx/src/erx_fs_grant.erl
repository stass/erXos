%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_grant).
-moduledoc """
The pure core of one `erx_fs` grant (docs/design-files.md#serving-the-erx_fs-behaviour).

A grant serves one client domain's requests on one tree. This module holds
everything the grant knows, its fid table, the owners it monitors and the
requests it has in flight, and decides each step: `handle_frame/2` takes one
message the grant received and returns the effects to perform, in order, and
the next state. `erx_fs`, the process shell, performs them:

* `{reply, Alias, Reply}`: send `{erx_9p, Alias, Reply}` to `Alias`;
* `{monitor, Owner}`: monitor `Owner` and hand the reference back with
  `monitored/3` before the next step;
* `{demonitor, Ref}`: `erlang:demonitor(Ref, [flush])`.

The core calls the tree's callback module directly, since a walk asks it one
name at a time and each answer decides the next question; it reads no other
state and sends nothing.

Every frame passes one funnel, `decode/2`, which takes the grant's rights:
dispatch receives only requests the funnel admitted, so a writing request on a
read-only grant never reaches a callback (F5).

The fid table is the one record of which fids are alive. Each fid has an owner,
fixed for its life; `owners` maps each owner of a live fid to its monitor and
its set of fids, and holds no other process, so the grant never monitors more
processes than it holds fids (F10, design-files.md#fid-owners).
""".

-export([new/1, handle_frame/2, monitored/3, owner_down/3, defer/3,
         complete/3, info/1]).

-export_type([grant/0, effect/0, rights/0]).

-define(NOFID, 16#ffffffff).
-define(QTDIR, 16#80).
-define(AT_REMOVEDIR, 16#200).
-define(MSIZE_MIN, 4096).
-define(MSIZE_MAX, 65560).
-define(VERSION, <<"9P2000.L">>).
-define(IN_FLIGHT_MAX, 64).
-define(DEFAULT_POOL, 4096).

-type rights() :: ro | rw | rx.
-type fid() :: 0..16#fffffffe.
-type qid() :: {0..255, 0..16#ffffffff, 0..16#ffffffffffffffff}.

%% Where a fid stands: its node first, then each directory it was walked
%% through, back to the grant's root, each with the name it was reached by.
%% A walk of ".." takes the second step; at the root, the only step, it stays.
-type step() :: {Node :: term(), qid(), Name :: binary() | root}.
-type path() :: [step(), ...].

-record(fid, {owner :: pid(), path :: path()}).

%% An owner's monitor is `pending` from the step that made its first fid until
%% the shell hands its reference back with monitored/3.
-record(owner, {monitor :: reference() | pending,
                fids :: #{fid() => []}}).

%% A request answered outside the grant's step, and the flushes waiting on it.
-record(pending, {request :: tuple(), flushes :: [reference()]}).

-record(grant, {module :: module(),
                tree :: term(),
                rights :: rights(),
                client :: node(),
                pool :: pos_integer(),
                fids = #{} :: #{fid() => #fid{}},
                owners = #{} :: #{pid() => #owner{}},
                pending = #{} :: #{reference() => #pending{}},
                in_flight = 0 :: non_neg_integer(),
                refused = 0 :: non_neg_integer(),
                effects = [] :: [effect()]}).

-opaque grant() :: #grant{}.
-type effect() :: {reply, reference(), term()}
                | {monitor, pid()}
                | {demonitor, reference()}.

-doc """
A grant with no fids. `rights` is the grant's (`ro`, `rw` or `rx`); a tree
whose module has no `write/4` callback is read-only whatever they say (F5).
`client` is the node of the domain the grant serves, `pool` its fid bound.
""".
-spec new(#{module := module(), tree := term(), rights := rights(),
            client := node(), pool => pos_integer()}) -> grant().
new(#{module := Module, tree := Tree, rights := Rights, client := Client} = Options)
  when (Rights =:= ro orelse Rights =:= rw orelse Rights =:= rx),
       is_atom(Client) ->
    Pool = maps:get(pool, Options, ?DEFAULT_POOL),
    true = is_integer(Pool) andalso Pool > 0,
    Writes = erlang:function_exported(Module, write, 4),
    #grant{module = Module, tree = Tree, client = Client, pool = Pool,
           rights = effective_rights(Rights, Writes)}.

effective_rights(rw, false) -> ro;
effective_rights(Rights, _) -> Rights.

-doc "One message the grant received, other than an owner's `DOWN`.".
-spec handle_frame(term(), grant()) -> {[effect()], grant()}.
handle_frame(Frame, Grant) ->
    case decode(Frame, Grant) of
        drop ->
            drain(count_refusal(Grant));
        {refuse, Alias, Posix, Request} ->
            finish(Alias, Request, {error, Posix}, refused_remove(Request, Grant));
        {admit, Alias, Owner, Request} ->
            admit(Alias, Owner, Request, Grant)
    end.

-doc "The reference of the monitor the shell made for an `{monitor, Owner}` effect.".
-spec monitored(pid(), reference(), grant()) -> grant().
monitored(Owner, Ref, #grant{owners = Owners} = Grant) ->
    #{Owner := #owner{monitor = pending} = Record} = Owners,
    Grant#grant{owners = Owners#{Owner := Record#owner{monitor = Ref}}}.

-doc """
An owner's `DOWN`: every fid it still owns ends, as if it had sent the clunks.
A `DOWN` whose reference is not the owner's monitor changes nothing.
""".
-spec owner_down(reference(), pid(), grant()) -> {[effect()], grant()}.
owner_down(Ref, Owner, #grant{owners = Owners} = Grant) ->
    case Owners of
        #{Owner := #owner{monitor = Ref, fids = Fids}} ->
            drain(lists:foldl(fun end_fid/2, Grant, maps:keys(Fids)));
        #{} ->
            {[], Grant}
    end.

-doc """
Counts `Request`, sent to `Alias`, as in flight until `complete/3` answers it:
the hook for a request whose answer comes from outside the grant's step, such
as an open file's owner. A request admitted while 64 are in flight, flushes
waiting on them included, fails with `emfile`.
""".
-spec defer(reference(), tuple(), grant()) -> grant().
defer(Alias, Request, #grant{pending = Pending, in_flight = InFlight} = Grant)
  when not is_map_key(Alias, Pending) ->
    Grant#grant{pending = Pending#{Alias => #pending{request = Request, flushes = []}},
                in_flight = InFlight + 1}.

-doc "Answers a deferred request, then every flush that waited on it.".
-spec complete(reference(), term(), grant()) -> {[effect()], grant()}.
complete(Alias, Reply, #grant{pending = Pending, in_flight = InFlight} = Grant) ->
    {#pending{request = Request, flushes = Flushes}, Rest} = maps:take(Alias, Pending),
    Grant1 = Grant#grant{pending = Rest, in_flight = InFlight - 1 - length(Flushes)},
    {Effects, Grant2} = finish(Alias, Request, Reply, Grant1),
    {Effects ++ [{reply, Flush, ok} || Flush <- lists:reverse(Flushes)], Grant2}.

-doc "What the grant holds, for inspection and tests.".
-spec info(grant()) -> #{fids := non_neg_integer(), owners := non_neg_integer(),
                         in_flight := non_neg_integer(), refused := non_neg_integer(),
                         rights := rights()}.
info(#grant{fids = Fids, owners = Owners, in_flight = InFlight, refused = Refused,
            rights = Rights}) ->
    #{fids => map_size(Fids), owners => map_size(Owners), in_flight => InFlight,
      refused => Refused, rights => Rights}.

%% The funnel. A frame is admitted only if the grammar accepts it, its owner is
%% a process of the client's domain, and it does not write on a read-only
%% grant. A frame without an alias has no one to answer and is dropped, and so
%% is one whose alias is not the client domain's: the grant answers only its
%% own client, never a third domain on a client's behalf.
decode(Frame, #grant{client = Client, rights = Rights}) ->
    case erx_9p_grammar:decode_request_frame(Frame) of
        error ->
            drop;
        {error, Alias, _} when node(Alias) =/= Client ->
            drop;
        {ok, Alias, _, _} when node(Alias) =/= Client ->
            drop;
        {error, Alias, Posix} ->
            {refuse, Alias, Posix, none};
        {ok, Alias, Owner, _} when node(Owner) =/= Client ->
            {refuse, Alias, einval, none};
        {ok, Alias, Owner, Request} ->
            case Rights =:= rw orelse not erx_9p_grammar:writes(Request) of
                true -> {admit, Alias, Owner, Request};
                false -> {refuse, Alias, erofs, Request}
            end
    end.

%% A remove clunks its fid whatever the outcome, a refusal included.
refused_remove({remove, Fid}, Grant) -> end_fid_if_held(Fid, Grant);
refused_remove(_, Grant) -> Grant.

%% A flush of a request not in flight is answered at once, at the bound too,
%% since it holds nothing; one that must wait for its request takes a slot.
admit(Alias, _, {flush, OldTag} = Request, #grant{pending = Pending} = Grant)
  when not is_map_key(OldTag, Pending) ->
    finish(Alias, Request, ok, Grant);
admit(Alias, _, Request, #grant{in_flight = InFlight} = Grant)
  when InFlight >= ?IN_FLIGHT_MAX ->
    finish(Alias, Request, {error, emfile}, refused_remove(Request, Grant));
admit(Alias, _, {flush, OldTag}, #grant{pending = Pending, in_flight = InFlight} = Grant) ->
    #{OldTag := #pending{flushes = Flushes} = Record} = Pending,
    Waiting = Record#pending{flushes = [Alias | Flushes]},
    {[], Grant#grant{pending = Pending#{OldTag := Waiting}, in_flight = InFlight + 1}};
admit(Alias, Owner, Request, Grant) ->
    {Reply, Grant1} = dispatch(Owner, Request, Grant),
    finish(Alias, Request, Reply, Grant1).

%% Every answer leaves through here: held to its request by the grammar's
%% reply check, so a callback's malformed answer reaches the client as eio.
finish(Alias, Request, Reply, Grant) ->
    Checked = case Request of
                  none -> Reply;
                  _ -> checked_reply(Request, Reply)
              end,
    Grant1 = case Checked of
                 {error, _} -> count_refusal(Grant);
                 _ -> Grant
             end,
    {Effects, Grant2} = drain(Grant1),
    {Effects ++ [{reply, Alias, Checked}], Grant2}.

checked_reply(Request, Reply) ->
    case erx_9p_grammar:decode_reply(Request, Reply) of
        {ok, _} -> Reply;
        {error, eio} -> {error, eio}
    end.

count_refusal(#grant{refused = Refused} = Grant) ->
    Grant#grant{refused = Refused + 1}.

drain(#grant{effects = Effects} = Grant) ->
    {lists:reverse(Effects), Grant#grant{effects = []}}.

%% Each admitted operation, as {Reply, Grant}. Every fid a request names is
%% looked up here; a fid the grant does not hold is ebadf.
dispatch(_, {version, Msize, Version}, Grant) ->
    {version(Msize, Version), Grant};
dispatch(Owner, {attach, Fid, Afid, _, Aname, _}, Grant) ->
    attach(Owner, Fid, Afid, Aname, Grant);
dispatch(Owner, {walk, Fid, NewFid, Names}, Grant) ->
    walk(Owner, Fid, NewFid, Names, Grant);
dispatch(_, {getattr, Fid, _}, Grant) ->
    on_node(Fid, Grant, fun(Node, Module, Tree) -> Module:getattr(Node, Tree) end);
dispatch(_, {readlink, Fid}, Grant) ->
    on_node(Fid, Grant, fun(Node, Module, Tree) ->
                                optional(Module, readlink, [Node, Tree], {error, einval})
                        end);
dispatch(_, {statfs, Fid}, Grant) ->
    on_node(Fid, Grant, fun(_, Module, Tree) -> Module:statfs(Tree) end);
dispatch(_, {clunk, Fid}, Grant) ->
    case held(Fid, Grant) of
        true -> {ok, end_fid(Fid, Grant)};
        false -> {{error, ebadf}, Grant}
    end;
dispatch(_, {mkdir, Dfid, Name, Mode, _Gid}, Grant) ->
    make(Dfid, Name, {directory, Mode band 8#7777}, Grant);
dispatch(_, {symlink, Fid, Name, Target, _Gid}, Grant) ->
    make(Fid, Name, {symlink, Target}, Grant);
dispatch(_, {link, Dfid, Fid, Name}, Grant) ->
    case node_of(Fid, Grant) of
        {ok, Node} -> make(Dfid, Name, {link, Node}, Grant);
        error -> {{error, ebadf}, Grant}
    end;
dispatch(_, {mknod, Dfid, Name, Mode, Major, Minor, _Gid}, Grant) ->
    make(Dfid, Name, {node, Mode, Major, Minor}, Grant);
dispatch(_, {unlinkat, Dfid, Name, Flags}, Grant) ->
    Kind = case Flags band ?AT_REMOVEDIR of
               0 -> file;
               _ -> directory
           end,
    change_on_node(Dfid, Grant, unlink, fun(Dir) -> [Dir, Name, Kind] end);
dispatch(_, {remove, Fid}, Grant) ->
    remove(Fid, Grant);
dispatch(_, {renameat, OldDfid, OldName, NewDfid, NewName}, Grant) ->
    case node_of(NewDfid, Grant) of
        {ok, NewDir} ->
            change_on_node(OldDfid, Grant, rename,
                           fun(OldDir) -> [OldDir, OldName, NewDir, NewName] end);
        error ->
            {{error, ebadf}, Grant}
    end;
dispatch(_, {setattr, Fid, Attr}, Grant) ->
    change_on_node(Fid, Grant, setattr, fun(Node) -> [{node, Node}, Attr] end);
dispatch(_, Request, Grant) ->
    {unserved(element(1, Request)), Grant}.

%% This grant opens no fid, since it serves neither lopen nor lcreate, so the
%% operations of an open fid find none. auth, the extended attributes and the
%% locks are not served.
unserved(Op) when Op =:= read; Op =:= write; Op =:= readdir; Op =:= fsync ->
    {error, ebadf};
unserved(_) ->
    {error, enotsup}.

version(Msize, _) when Msize < ?MSIZE_MIN -> {error, einval};
version(Msize, ?VERSION) -> {ok, min(Msize, ?MSIZE_MAX), ?VERSION};
version(Msize, _) -> {ok, min(Msize, ?MSIZE_MAX), <<"unknown">>}.

attach(_, _, Afid, _, Grant) when Afid =/= ?NOFID ->
    %% auth is not served, so the grant holds no fid an Afid could name.
    {{error, ebadf}, Grant};
attach(Owner, Fid, _, Aname, #grant{module = Module, tree = Tree} = Grant) ->
    case new_fid_admissible(Fid, Grant) of
        ok ->
            case Module:root(Tree) of
                {ok, Aname, Root, Qid} ->
                    {{ok, Qid}, add_fid(Fid, Owner, [{Root, Qid, root}], Grant)};
                {ok, _, _, _} ->
                    {{error, enoent}, Grant}
            end;
        {error, _} = Error ->
            {Error, Grant}
    end.

%% A walk names a fid that is not open and a new fid that is not in use, unless
%% it is the same fid. It names the result only when every name was walked; one
%% that stops after the first name lists the qids it walked and changes nothing.
walk(Owner, Fid, NewFid, Names, #grant{fids = Fids} = Grant) ->
    case Fids of
        #{Fid := #fid{path = Path}} ->
            Admissible = case NewFid of
                             Fid -> ok;
                             _ -> new_fid_admissible(NewFid, Grant)
                         end,
            case Admissible of
                ok -> walked(Owner, Fid, NewFid, walk_names(Names, Path, [], Grant), Grant);
                {error, _} = Error -> {Error, Grant}
            end;
        #{} ->
            {{error, ebadf}, Grant}
    end.

walked(_, _, _, {stopped, [], Posix}, Grant) ->
    {{error, Posix}, Grant};
walked(_, _, _, {stopped, Qids, _}, Grant) ->
    {{ok, lists:reverse(Qids)}, Grant};
walked(_, Fid, Fid, {done, Path, Qids}, #grant{fids = Fids} = Grant) ->
    #{Fid := Record} = Fids,
    {{ok, lists:reverse(Qids)}, Grant#grant{fids = Fids#{Fid := Record#fid{path = Path}}}};
walked(Owner, _, NewFid, {done, Path, Qids}, Grant) ->
    {{ok, lists:reverse(Qids)}, add_fid(NewFid, Owner, Path, Grant)}.

walk_names([], Path, Qids, _) ->
    {done, Path, Qids};
walk_names([Name | Names], Path, Qids, Grant) ->
    case walk_step(Name, Path, Grant) of
        {ok, [{_, Qid, _} | _] = Path1} -> walk_names(Names, Path1, [Qid | Qids], Grant);
        {error, Posix} -> {stopped, Qids, Posix}
    end.

%% Only a directory is walked from, so a walk that reaches a symbolic link
%% stops at its next name and the callback is never asked to follow one (F2).
%% ".." is the grant's: it stays at the root and otherwise returns to the
%% directory recorded on the way down.
walk_step(_, [{_, {Type, _, _}, _} | _], _) when Type band ?QTDIR =:= 0 ->
    {error, enotdir};
walk_step(<<"..">>, [_] = Root, _) ->
    {ok, Root};
walk_step(<<"..">>, [_ | Parent], _) ->
    {ok, Parent};
walk_step(Name, [{Dir, _, _} | _] = Path, #grant{module = Module, tree = Tree}) ->
    case Module:walk(Dir, Name, Tree) of
        {ok, Node, Qid} -> {ok, [{Node, Qid, Name} | Path]};
        {error, _} = Error -> Error
    end.

%% A remove unlinks the name its fid was walked by from the directory it was
%% walked from, and clunks the fid whatever the outcome.
remove(Fid, #grant{fids = Fids} = Grant) ->
    case Fids of
        #{Fid := #fid{path = [{_, _, root}]}} ->
            {{error, einval}, end_fid(Fid, Grant)};
        #{Fid := #fid{path = [{_, _, Name}, {Dir, _, _} | _]}} ->
            {Reply, Grant1} = change(unlink, [Dir, Name, any], Grant),
            {Reply, end_fid(Fid, Grant1)};
        #{} ->
            {{error, ebadf}, Grant}
    end.

make(Dfid, Name, What, Grant) ->
    case node_of(Dfid, Grant) of
        {ok, Dir} ->
            case change(make, [Dir, Name, What], Grant) of
                {{ok, _Node, Qid}, Grant1} -> {made_reply(What, Qid), Grant1};
                {{error, _}, _} = Error -> Error
            end;
        error ->
            {{error, ebadf}, Grant}
    end.

made_reply({link, _}, _) -> ok;
made_reply(_, Qid) -> {ok, Qid}.

%% A callback that changes the tree returns its next state with its answer;
%% a tree without the callback keeps nothing of that kind (eperm).
change_on_node(Fid, Grant, Callback, Arguments) ->
    case node_of(Fid, Grant) of
        {ok, Node} -> change(Callback, Arguments(Node), Grant);
        error -> {{error, ebadf}, Grant}
    end.

change(Callback, Arguments, #grant{module = Module, tree = Tree} = Grant) ->
    case optional(Module, Callback, Arguments ++ [Tree], {error, eperm}) of
        {ok, Tree1} -> {ok, Grant#grant{tree = Tree1}};
        {ok, Node, Qid, Tree1} -> {{ok, Node, Qid}, Grant#grant{tree = Tree1}};
        {error, Posix} when is_atom(Posix) -> {{error, Posix}, Grant}
    end.

on_node(Fid, #grant{module = Module, tree = Tree} = Grant, Read) ->
    case node_of(Fid, Grant) of
        {ok, Node} -> {Read(Node, Module, Tree), Grant};
        error -> {{error, ebadf}, Grant}
    end.

optional(Module, Callback, Arguments, Absent) ->
    case erlang:function_exported(Module, Callback, length(Arguments)) of
        true -> apply(Module, Callback, Arguments);
        false -> Absent
    end.

node_of(Fid, #grant{fids = Fids}) ->
    case Fids of
        #{Fid := #fid{path = [{Node, _, _} | _]}} -> {ok, Node};
        #{} -> error
    end.

held(Fid, #grant{fids = Fids}) ->
    is_map_key(Fid, Fids).

%% A new fid is refused while its number is alive (einval, as QEMU answers a
%% fid in use) and when the pool is full (emfile).
new_fid_admissible(Fid, #grant{fids = Fids, pool = Pool}) ->
    if
        is_map_key(Fid, Fids) -> {error, einval};
        map_size(Fids) >= Pool -> {error, emfile};
        true -> ok
    end.

%% The only two functions that change the fid table, and with it the owners
%% and their monitors: an owner is recorded, and monitored, exactly while it
%% owns a fid.
add_fid(Fid, Owner, Path, #grant{fids = Fids, owners = Owners, effects = Effects} = Grant) ->
    Grant1 = Grant#grant{fids = Fids#{Fid => #fid{owner = Owner, path = Path}}},
    case Owners of
        #{Owner := #owner{fids = Owned} = Record} ->
            Grant1#grant{owners = Owners#{Owner := Record#owner{fids = Owned#{Fid => []}}}};
        #{} ->
            Grant1#grant{owners = Owners#{Owner => #owner{monitor = pending, fids = #{Fid => []}}},
                         effects = [{monitor, Owner} | Effects]}
    end.

end_fid(Fid, #grant{fids = Fids, owners = Owners, effects = Effects} = Grant) ->
    {#fid{owner = Owner}, Fids1} = maps:take(Fid, Fids),
    #{Owner := #owner{monitor = Ref, fids = Owned} = Record} = Owners,
    Grant1 = Grant#grant{fids = Fids1},
    case maps:remove(Fid, Owned) of
        Left when map_size(Left) =:= 0 ->
            Grant1#grant{owners = maps:remove(Owner, Owners),
                         effects = [{demonitor, Ref} | Effects]};
        Left ->
            Grant1#grant{owners = Owners#{Owner := Record#owner{fids = Left}}}
    end.

end_fid_if_held(Fid, Grant) ->
    case held(Fid, Grant) of
        true -> end_fid(Fid, Grant);
        false -> Grant
    end.
