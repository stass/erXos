%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The bounded workloads of the crash-state generator (docs/design-crash-states.md,
%% "Workloads"), enumerated as Ace bounds them. A pure module: it writes no workload
%% to disk, and a workload is named by its sequence length, its position in the
%% enumeration and the enumeration's version, this module's MD5, so a name read back
%% after the module changed is refused, not misread.
%%
%% The file set is the volume tests' tree (test/fixtures/fat_volumes.rb): the root
%% with two files, `sub` with one file and the nested directory `sub/Deeper`, which
%% holds one. Over a tree, the operations are, in this order: `create` of a short and
%% of a long new name in every directory; `mkdir` of a new name in every directory;
%% `write` within every non-empty file, extending every file and past every file's
%% end, each at most 1,024 bytes, two of the FAT32 volume's clusters; `truncate`
%% shorter of every non-empty file and longer of every file; `remove` of every file;
%% `rename` of every file to a new name in its directory, to the next directory, and
%% onto the next other file; and `rmdir` of every empty directory but the root.
%% `seq-N` is every sequence of N such operations, each over the tree the ones
%% before it leave, with every placement of an `fsync` between them and one always
%% after the last, so each workload ends acknowledged.

-module(erx_crash_workloads).

-export([file_set/0, fits/1, count/1, workload/2, name/2, named/1, version/0]).
-export_type([name/0]).

-type name() :: {seq, pos_integer(), pos_integer(), binary()}.

-define(WRITE_MAX, 1024).

%% The enumeration's version: this module's MD5, in hex.
-spec version() -> binary().
version() -> binary:encode_hex(?MODULE:module_info(md5), lowercase).

%% The file set's shape: each path with `dir` or its file's size.
-spec file_set() -> #{erx_fs_model:path() => dir | non_neg_integer()}.
file_set() ->
    #{[] => dir, [<<"hello.txt">>] => 13, [<<"empty">>] => 0, [<<"sub">>] => dir,
      [<<"sub">>, <<"Long File Name.dat">>] => 5000, [<<"sub">>, <<"Deeper">>] => dir,
      [<<"sub">>, <<"Deeper">>, <<"x.TXT">>] => 5}.

%% Whether Tree, a volume's tree, has the file set's shape.
-spec fits(erx_fs_model:tree()) -> boolean().
fits(Tree) ->
    #{P => shape(V) || P := V <- Tree} =:= file_set().

shape(dir) -> dir;
shape({file, Bytes}) -> byte_size(Bytes).

%% The count of workloads of seq-N.
-spec count(pos_integer()) -> non_neg_integer().
count(N) -> length(sequences(N)).

%% The Position-th workload of seq-N, from 1: its operations, fsyncs placed.
-spec workload(pos_integer(), pos_integer()) -> [erx_fs_model:op()].
workload(N, Position) -> lists:nth(Position, sequences(N)).

-spec name(pos_integer(), pos_integer()) -> name().
name(N, Position) -> {seq, N, Position, version()}.

%% The workload Name names, refused when another version of this module named it.
-spec named(name()) -> {ok, [erx_fs_model:op()]} | {error, {version, binary(), binary()}}.
named({seq, N, Position, Version}) ->
    case version() of
        Version -> {ok, workload(N, Position)};
        Ours -> {error, {version, Version, Ours}}
    end.

%% Every workload of seq-N over the file set, in order.
sequences(N) ->
    Start = #{P => tree_value(V) || P := V <- file_set()},
    [placed(Ops, Placement) || Ops <- operations(N, Start), Placement <- placements(N)].

tree_value(dir) -> dir;
tree_value(Size) -> {file, binary:copy(<<0>>, Size)}.

operations(0, _Tree) ->
    [[]];
operations(N, Tree) ->
    [[Op | Rest] || Op <- next(Tree, N), {ok, Tree1, _} <- [erx_fs_model:step(Op, Tree)],
                    Rest <- operations(N - 1, Tree1)].

%% Each of the N-1 gaps holds an fsync or not; the last operation always has one.
placements(N) ->
    lists:foldl(fun(_, Acc) -> [[S | P] || S <- [false, true], P <- Acc] end, [[true]], lists:seq(2, N)).

placed(Ops, Placement) ->
    lists:append([[Op | [fsync || Sync]] || {Op, Sync} <- lists:zip(Ops, Placement)]).

%% The operations over Tree, in the order above; Salt, the count of operations still
%% to come, makes each write's bytes differ from the ones before it.
next(Tree, Salt) ->
    Dirs = lists:sort([P || P := dir <- Tree]),
    Files = lists:sort([{P, byte_size(B)} || P := {file, B} <- Tree]),
    Paths = [P || {P, _} <- Files],
    lists:append([
        [{create, D ++ [Name]} || D <- Dirs, Name <- [<<"new.txt">>, <<"A New Long Name.txt">>]],
        [{mkdir, D ++ [<<"newdir">>]} || D <- Dirs],
        [{write, P, Size div 4, bytes(min(Size div 2, ?WRITE_MAX), Salt)} || {P, Size} <- Files, Size > 1],
        [{write, P, max(0, Size - 6), bytes(1000, Salt)} || {P, _} <- Files, Size <- [size_of(P, Files)]],
        [{write, P, Size + 700, bytes(300, Salt)} || {P, Size} <- Files],
        [{truncate, P, Size div 2} || {P, Size} <- Files, Size > 0],
        [{truncate, P, Size + 1500} || {P, Size} <- Files],
        [{remove, P} || P <- Paths],
        [{rename, P, lists:droplast(P) ++ [<<"renamed.txt">>]} || P <- Paths],
        [{rename, P, next_of(lists:droplast(P), Dirs) ++ [lists:last(P)]} || P <- Paths],
        [{rename, P, next_of(P, Paths)} || P <- Paths, length(Paths) > 1],
        [{rmdir, D} || D <- Dirs, D =/= [], not lists:any(fun(P) -> P =/= [] andalso lists:droplast(P) =:= D end, maps:keys(Tree))]
    ]).

size_of(P, Files) -> element(2, lists:keyfind(P, 1, Files)).

%% The element after X in the sorted list Xs, wrapping, never X itself.
next_of(X, Xs) ->
    case lists:dropwhile(fun(Y) -> Y =< X end, Xs) of
        [Next | _] -> Next;
        [] -> hd(Xs)
    end.

bytes(Length, Salt) -> << <<((I * 7 + Salt * 31) rem 251 + 1)>> || I <- lists:seq(1, Length) >>.
