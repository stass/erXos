%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A pure model of a file tree and of what a file system's persistence points
%% promise (docs/design-crash-states.md, "Acknowledgements and obligations"). It
%% depends on nothing of PropEr, so the crash-state generator runs without it, and
%% the property-based tests take step/2 as their next-state function.
%%
%% * **A tree** maps each path, a list of names from the root ([] is the root), to
%%   `dir` or `{file, Bytes}`. step/2 runs one operation on it and answers the
%%   paths it changed, each as a name change (the path appeared, vanished or names
%%   another file) or a data change (a file's bytes or size).
%% * **Following a trace.** follow/3 takes the workload's marks in order: at
%%   `{'begin', I}` it applies operation I; at `{answered, I}` of a persistence point
%%   the tree as it stood when the point began becomes the acknowledged tree, which
%%   is FAT's scope: an `fsync` commits every waiting change in one batch. The base
%%   image's tree is acknowledged from the start.
%% * **An obligation** is the acknowledged tree and the changes of the operations
%%   begun since. A path's history is its acknowledged value followed by its value
%%   after each such change to it; judge/2 checks a tree read from a crash state
%%   against every path's history by FAT's rule for a cut batch
%%   (docs/design-storage.md, "Verification and testing", "FAT"): a path whose
%%   history is one value reads back exactly that; a longer history allows a
%%   file's size to be some entry's and each 512-byte block to be that block of
%%   some entry, its bytes past that entry's size being one other entry's bytes
%%   there, as the medium keeps them when a size and a data block land apart; a
%%   file's bytes follow it across a rename, so its old name may show changes
%%   made under its new one; a directory where some entry is one, and the name missing where
%%   some entry is absent or some change renamed it. A name the cut batch added may
%%   also stand under its short name alone, an alias of the form NAME~N.EXT in the
%%   same directory, judged by the long name's history.

-module(erx_fs_model).

-export([step/2, new/1, follow/3, obligation/1, history/2, judge/2]).
-export_type([path/0, value/0, tree/0, op/0, model/0, obligation/0]).

-define(BLOCK, 512).

-type path() :: [binary()].
-type value() :: absent | dir | {file, binary()}.
-type tree() :: #{path() => dir | {file, binary()}}.
-type op() :: {create, path()} | {mkdir, path()} | {write, path(), non_neg_integer(), binary()}
            | {truncate, path(), non_neg_integer()} | {remove, path()} | {rmdir, path()}
            | {rename, path(), path()} | fsync.
-type change() :: {path(), name | data, value()}.
%% A file's identity: its path in the base tree, or the operation that created it.
-type file_id() :: path() | {created, pos_integer()}.
%% A change as the model follows it: which file it changed, none for a directory.
-type followed() :: {path(), name | data, value(), file_id() | none}.
-type files() :: #{path() => file_id()}.
-type obligation() :: #{acked := tree(), acked_files := files(), changes := [followed()]}.
-type model() :: #{tree := tree(), files := files(), acked := tree(), acked_files := files(),
                   changes := [followed()]}.

%% ---------------------------------------------------------------------------
%% Operations
%% ---------------------------------------------------------------------------

%% Op applied to Tree: the tree after it and the paths it changed, or the error a
%% POSIX file system answers.
-spec step(op(), tree()) -> {ok, tree(), [change()]} | {error, enoent | eexist | enotdir | eisdir | enotempty}.
step(fsync, Tree) ->
    {ok, Tree, []};
step({create, Path}, Tree) ->
    added(Path, {file, <<>>}, Tree);
step({mkdir, Path}, Tree) ->
    added(Path, dir, Tree);
step({write, Path, Offset, Bytes}, Tree) ->
    with_file(Path, Tree, fun(Old) ->
                                  Padded = pad(Old, Offset),
                                  Tail = binary:part(Padded, min(byte_size(Padded), Offset + byte_size(Bytes)),
                                                     max(0, byte_size(Padded) - Offset - byte_size(Bytes))),
                                  <<(binary:part(Padded, 0, Offset))/binary, Bytes/binary, Tail/binary>>
                          end);
step({truncate, Path, Size}, Tree) ->
    with_file(Path, Tree, fun(Old) -> binary:part(pad(Old, Size), 0, Size) end);
step({remove, Path}, Tree) ->
    case Tree of
        #{Path := {file, _}} -> {ok, maps:remove(Path, Tree), [{Path, name, absent}]};
        #{Path := dir} -> {error, eisdir};
        #{} -> {error, enoent}
    end;
step({rmdir, Path}, Tree) ->
    case Tree of
        #{Path := dir} when Path =/= [] ->
            case children(Path, Tree) of
                [] -> {ok, maps:remove(Path, Tree), [{Path, name, absent}]};
                _ -> {error, enotempty}
            end;
        #{Path := _} -> {error, enotdir};
        #{} -> {error, enoent}
    end;
step({rename, From, To}, Tree) ->
    case {Tree, maps:get(To, Tree, absent), maps:get(parent(To), Tree, absent)} of
        {#{From := {file, _} = File}, ToValue, dir} when ToValue =/= dir ->
            {ok, (maps:remove(From, Tree))#{To => File}, [{From, name, absent}, {To, name, File}]};
        {#{From := _}, _, _} -> {error, eisdir};
        {#{}, _, _} -> {error, enoent}
    end.

added(Path, Value, Tree) ->
    case {maps:is_key(Path, Tree), maps:get(parent(Path), Tree, absent)} of
        {true, _} -> {error, eexist};
        {false, dir} -> {ok, Tree#{Path => Value}, [{Path, name, Value}]};
        {false, absent} -> {error, enoent};
        {false, _} -> {error, enotdir}
    end.

with_file(Path, Tree, Fun) ->
    case Tree of
        #{Path := {file, Old}} -> New = {file, Fun(Old)}, {ok, Tree#{Path := New}, [{Path, data, New}]};
        #{Path := dir} -> {error, eisdir};
        #{} -> {error, enoent}
    end.

pad(Bytes, Size) when byte_size(Bytes) >= Size -> Bytes;
pad(Bytes, Size) -> <<Bytes/binary, 0:((Size - byte_size(Bytes)) * 8)>>.

parent([]) -> none;
parent(Path) -> lists:droplast(Path).

children(Dir, Tree) ->
    [P || P := _ <- Tree, P =/= Dir, parent(P) =:= Dir].

%% ---------------------------------------------------------------------------
%% Following a trace
%% ---------------------------------------------------------------------------

%% A model whose acknowledged tree is Tree, the base image's.
-spec new(tree()) -> model().
new(Tree) ->
    Files = #{P => P || P := {file, _} <- Tree},
    #{tree => Tree, files => Files, acked => Tree, acked_files => Files, changes => []}.

%% Model after Mark, with Ops the workload's operations by number from 1. An
%% operation the model refuses is a workload the enumeration should not have made.
-spec follow({'begin' | answered, pos_integer()}, [op()], model()) -> model().
follow({'begin', I}, Ops, #{tree := Tree, files := Files, changes := Changes} = Model) ->
    Op = lists:nth(I, Ops),
    {ok, Tree1, New} = step(Op, Tree),
    Files1 = files_after(Op, I, Files),
    Followed = [{P, Kind, V, maps:get(P, Files1, maps:get(P, Files, none))} || {P, Kind, V} <- New],
    Model#{tree := Tree1, files := Files1, changes := Changes ++ Followed};
follow({answered, I}, Ops, #{tree := Tree, files := Files} = Model) ->
    case lists:nth(I, Ops) of
        fsync -> Model#{acked := Tree, acked_files := Files, changes := []};
        _ -> Model
    end.

files_after({create, Path}, I, Files) -> Files#{Path => {created, I}};
files_after({remove, Path}, _I, Files) -> maps:remove(Path, Files);
files_after({rename, From, To}, _I, Files) -> (maps:remove(From, Files))#{To => maps:get(From, Files)};
files_after(_Op, _I, Files) -> Files.

-spec obligation(model()) -> obligation().
obligation(Model) -> maps:with([acked, acked_files, changes], Model).

%% Path's history under Obligation: its acknowledged value, then each later change
%% to it, and each later change to the bytes of a file it named under another name,
%% since a cut batch may leave a renamed file under its old name.
-spec history(path(), obligation()) -> [{acked | name | data, value()}].
history(Path, #{acked := Acked, acked_files := AckedFiles, changes := Changes}) ->
    Ids = [Id || Id <- [maps:get(Path, AckedFiles, none) | [Id || {P, _, _, Id} <- Changes, P =:= Path]], Id =/= none],
    Later = [{Kind, V} || {P, Kind, V, Id} <- Changes, P =:= Path orelse (Kind =:= data andalso lists:member(Id, Ids))],
    [{acked, maps:get(Path, Acked, absent)} | Later].

%% ---------------------------------------------------------------------------
%% FAT's rule
%% ---------------------------------------------------------------------------

%% Actual, the tree read from a crash state, against Obligation: ok, or the first
%% path that breaks its history and why.
-spec judge(obligation(), tree()) -> ok | {error, {path(), term()}}.
judge(#{acked := Acked, changes := Changes} = Obligation, Actual) ->
    Promised = lists:usort(maps:keys(Acked) ++ [P || {P, _, _, _} <- Changes]),
    {Stand, Unpromised} = aliases(Obligation, Promised, Actual),
    Judged = [{P, allowed(history(P, Obligation), maps:get(P, Stand, absent))} || P <- Promised],
    case [{P, Why} || {P, {error, Why}} <- Judged] ++ [{P, unpromised_name} || P <- Unpromised] of
        [] -> ok;
        [First | _] -> {error, First}
    end.

%% The value each promised path stands for in Actual, a short alias standing in for
%% a long name the cut batch named and Actual lacks; and the paths of Actual that
%% stand for nothing promised.
aliases(Obligation, Promised, Actual) ->
    Extra = lists:sort([P || P := _ <- Actual, not lists:member(P, Promised)]),
    lists:foldl(fun(Path, {Stand, Unpromised}) ->
                        case [P || P <- Promised, not maps:is_key(P, Stand), aliased(Path, P, Obligation)] of
                            [Long | _] -> {Stand#{Long => maps:get(Path, Actual)}, Unpromised};
                            [] -> {Stand, Unpromised ++ [Path]}
                        end
                end, {maps:with(Promised, Actual), []}, Extra).

aliased(Alias, Long, Obligation) ->
    parent(Alias) =:= parent(Long) andalso Alias =/= [] andalso Long =/= []
        andalso short_alias(lists:last(Alias))
        andalso lists:any(fun({Kind, _}) -> Kind =:= name end, history(Long, Obligation)).

short_alias(Name) ->
    re:run(Name, <<"^[A-Z0-9_$]{1,6}~[0-9]{1,6}(\\.[A-Z0-9_$]{1,3})?$">>, [{capture, none}]) =:= match.

allowed([{acked, Value}], Actual) ->
    case Actual =:= Value of
        true -> ok;
        false -> {error, {not_as_acknowledged, shape(Value), shape(Actual)}}
    end;
allowed(History, Actual) ->
    Values = [V || {_, V} <- History],
    case Actual of
        absent ->
            ok_if(lists:member(absent, Values) orelse lists:keymember(name, 1, History), missing);
        dir ->
            ok_if(lists:member(dir, Values), not_a_directory_in_its_history);
        {file, Bytes} ->
            file_allowed(Bytes, [B || {file, B} <- Values])
    end.

file_allowed(_Bytes, []) ->
    {error, not_a_file_in_its_history};
file_allowed(Bytes, Files) ->
    Size = byte_size(Bytes),
    case lists:any(fun(F) -> byte_size(F) =:= Size end, Files) of
        false -> {error, {size_in_no_entry, Size}};
        true -> blocks_allowed(Bytes, Files, 0)
    end.

blocks_allowed(Bytes, _Files, At) when At >= byte_size(Bytes) ->
    ok;
blocks_allowed(Bytes, Files, At) ->
    Length = min(?BLOCK, byte_size(Bytes) - At),
    Block = binary:part(Bytes, At, Length),
    case lists:any(fun({F, G}) -> block_of(F, G, At, Block) end, [{F, G} || F <- Files, G <- Files]) of
        true -> blocks_allowed(Bytes, Files, At + ?BLOCK);
        false -> {error, {block_in_no_entry, At div ?BLOCK}}
    end.

%% Whether Block, at At, is entry F's block: F's bytes within its size and, past it,
%% entry G's at the same offsets, which the medium still holds when F's size and its
%% data block land apart.
block_of(F, G, At, Block) ->
    Own = max(0, min(byte_size(Block), byte_size(F) - At)),
    Tail = byte_size(Block) - Own,
    (Own =:= 0 orelse binary:part(F, At, Own) =:= binary:part(Block, 0, Own))
        andalso (Tail =:= 0 orelse (byte_size(G) >= At + byte_size(Block)
                                    andalso binary:part(G, At + Own, Tail) =:= binary:part(Block, Own, Tail))).

ok_if(true, _Why) -> ok;
ok_if(false, Why) -> {error, Why}.

shape(absent) -> absent;
shape(dir) -> dir;
shape({file, Bytes}) -> {file, byte_size(Bytes), erlang:phash2(Bytes)}.
