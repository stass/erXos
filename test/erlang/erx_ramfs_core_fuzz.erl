%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random sequences of up to 64 requests through erx_ramfs_core:step/4 under a low cap,
%% over a few names and directories, with offsets and sizes drawn to include 0, chunk
%% boundaries, 2^63 - 1 and negative values, and inode numbers kept after their nodes
%% are gone (docs/design-tmp.md, "Sequences"). After every step: check/1 holds, a
%% refused step left the tree as it was, and what the tree says of a file agrees with
%% a model that keeps each file as the list of writes that reached it, cut at its size,
%% which shares no code with the chunked store and predicts where each write lands and
%% how much of it. Walks hold for two holders, which forget nodes and end, and a model
%% keeps each holder's set: at the end of a sequence every node a holder still holds is
%% there, then every open is closed and both holders end, after which no inode number
%% the run saw names a node without a name: a leaked open or hold would keep one. Every
%% operation must have been accepted at least ?MIN_ACCEPTED times over the run, so a
%% step that always refuses fails it. The seed comes from make check-fuzz.

-module(erx_ramfs_core_fuzz).
-export([run/1]).

-define(SEQUENCES, 30000).
-define(MAX_STEPS, 64).
-define(ROOT, 1).
-define(MAX_SIZE, ((1 bsl 63) - 1)).
-define(MAX_READ, 65536).
-define(GONE, 999999999).
-define(MIN_ACCEPTED, 500).
-define(OPERATIONS, [walk, getattr, open, read, write, readdir, readlink, setattr,
                     unlink, rename, clunk, {make, file}, {make, directory},
                     {make, symlink}, {make, link}, forget, forget_holder]).
-define(HOLDERS, [g1, g2]).

%% The state of one sequence: the tree; the next stamp; every inode number a
%% reply named, kept after its node is gone; the handles open; and per file
%% the model: its size and its writes, newest first; the {Holder, Ino} pairs
%% the walks hold; and per operation the steps the tree accepted, which the
%% run reports to show what it reached.
-record(run, {tree, stamp = 2, inos = [?ROOT], handles = [], files = #{},
              holds = [], accepted = #{}}).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = lists:foldl(fun(Number, Sum) ->
                                   maps:merge_with(fun(_, A, B) -> A + B end,
                                                   Sum, sequence(Number))
                           end, #{}, lists:seq(1, ?SEQUENCES)),
    io:format("accepted steps by operation: ~p~n", [Accepted]),
    case [Op || Op <- ?OPERATIONS, maps:get(Op, Accepted, 0) < ?MIN_ACCEPTED] of
        [] -> ok;
        Rare -> error({rarely_accepted, Rare})
    end,
    io:format("fuzz: ~p sequences ok~n", [?SEQUENCES]).

sequence(Number) ->
    Cap = pick([0, 2000, 3 * 4096 + 2000, 10 * 4096, 10 * 4096, 64 * 4096]),
    Run = #run{tree = erx_ramfs_core:new(Cap, ?ROOT, 0)},
    Steps = rand:uniform(?MAX_STEPS),
    Run1 = lists:foldl(fun(Step, R) -> apply_step(Number, Step, request(R), R) end,
                       Run, lists:seq(1, Steps)),
    lists:foreach(fun({_, Ino}) -> held_is_there(Number, Ino, Run1#run.tree) end,
                  Run1#run.holds),
    Run2 = lists:foldl(fun(Handle, R) -> apply_step(Number, last, {clunk, Handle}, R) end,
                       Run1, Run1#run.handles),
    Run3 = lists:foldl(fun(Holder, R) -> apply_step(Number, last, {forget_holder, Holder}, R) end,
                       Run2, ?HOLDERS),
    lists:foreach(fun(Ino) -> closed_or_named(Number, Ino, Run3#run.tree) end,
                  Run3#run.inos),
    Run3#run.accepted.

%% A node a holder holds is there, named or not.
held_is_there(Number, Ino, Tree) ->
    case erx_ramfs_core:step({getattr, Ino}, 1, 0, Tree) of
        {{ok, _}, _} -> ok;
        {Reply, _} -> error({held_node_gone, Number, Ino, Reply})
    end.

%% With every open closed, a node is named or gone.
closed_or_named(Number, Ino, Tree) ->
    case erx_ramfs_core:step({getattr, Ino}, 1, 0, Tree) of
        {{ok, #{nlink := 0}}, _} -> error({open_leaked, Number, Ino});
        {_, _} -> ok
    end.

apply_step(Number, Step, Request, #run{tree = Tree, stamp = Stamp} = Run) ->
    {Reply, Tree1} = erx_ramfs_core:step(Request, Stamp, Stamp, Tree),
    case erx_ramfs_core:check(Tree1) of
        ok -> ok;
        {error, Problems} ->
            error({check_failed, Number, Step, Request, Reply, Problems})
    end,
    case Reply of
        {error, _} when Tree1 =/= Tree ->
            error({refusal_changed_tree, Number, Step, Request, Reply});
        _ ->
            ok
    end,
    observed(Number, Step, Request, Reply,
             Run#run{tree = Tree1, stamp = Stamp + 1,
                     accepted = accepted(Request, Reply, Run#run.accepted)}).

accepted(_Request, {error, _}, Accepted) ->
    Accepted;
accepted(Request, _Reply, Accepted) ->
    Operation = case Request of
                    {make, _, _, What} -> {make, element(1, What)};
                    _ when is_tuple(Request) -> element(1, Request);
                    _ -> Request
                end,
    maps:update_with(Operation, fun(Count) -> Count + 1 end, 1, Accepted).

%% ---------------------------------------------------------------------------
%% Requests
%% ---------------------------------------------------------------------------

request(Run) ->
    case rand:uniform(22) of
        1 -> {walk, ino(Run), name(), holder()};
        2 -> {getattr, ino(Run)};
        3 -> {open, ino(Run), flags()};
        4 -> {make, ino(Run), name(), {file, mode(), flags()}};
        5 -> {make, ino(Run), name(), {directory, mode()}};
        6 -> {make, ino(Run), name(), {symlink, pick([<<"t">>, <<>>, <<"a", 0>>,
                                                      binary:copy(<<"t">>, 4095),
                                                      binary:copy(<<"t">>, 4096)])}};
        7 -> {make, ino(Run), name(), {link, ino(Run)}};
        8 -> {read, handle(Run), offset(), pick([0, 1, 4095, 4096, 4097, 9000, -1])};
        9 -> {write, handle(Run), offset(), data()};
        10 -> {write, handle(Run), offset(), data()};
        11 -> {readdir, handle(Run), pick([0, 1, 2, 5, -1]), pick([1, 2, 256, 0])};
        12 -> {readlink, ino(Run)};
        13 -> {setattr, target(Run), changes()};
        14 -> {unlink, ino(Run), name(), pick([file, directory, {node, ino(Run)}])};
        15 -> {rename, ino(Run), name(), ino(Run), name()};
        16 -> {rename, ino(Run), name(), ino(Run), name()};
        17 -> clunk_request(Run);
        18 -> pick([statfs, {fsync, handle(Run)}, {xattr, ino(Run), get}]);
        19 -> {make, ino(Run), name(), {node, mode(), 1, 3}};
        20 -> pick([{nonsense}, {open, ino(Run), {read, [trunc | append]}},
                    {setattr, {node, ino(Run)}, #{size => <<"big">>}}]);
        21 -> {forget, held_ino(Run), holder()};
        22 -> {forget_holder, holder()}
    end.

holder() -> pick(?HOLDERS).

%% A node some holder holds, most often.
held_ino(#run{holds = []} = Run) -> ino(Run);
held_ino(#run{holds = Holds} = Run) ->
    case rand:uniform(4) of
        1 -> ino(Run);
        _ -> element(2, pick(Holds))
    end.

ino(#run{inos = Inos}) ->
    case rand:uniform(10) of
        1 -> ?GONE;
        _ -> pick(Inos)
    end.

name() ->
    case rand:uniform(20) of
        1 -> pick([<<>>, <<".">>, <<"..">>, <<"x/y">>, binary:copy(<<"n">>, 256)]);
        _ -> pick([<<"a">>, <<"b">>, <<"c">>, <<"dd">>])
    end.

mode() -> pick([8#755, 8#644, 8#700, 8#600, 8#500, 8#444, 8#200, 8#000]).

flags() ->
    Options = [Option || Option <- [trunc, append, excl, directory],
                         rand:uniform(4) =:= 1],
    {pick([read, write, read_write]), Options}.

offset() ->
    case rand:uniform(4) of
        1 -> rand:uniform(20000) - 1;
        _ -> pick([0, 1, 4095, 4096, 4097, 8191, 8192, 65536, ?MAX_SIZE - 1,
                   ?MAX_SIZE, ?MAX_SIZE + 1, -1, -4096])
    end.

data() -> rand:bytes(pick([0, 1, 2, 100, 4095, 4096, 4097, 9000])).

handle(#run{handles = []}) -> {?GONE, read_write, false};
handle(#run{handles = Handles}) ->
    case rand:uniform(20) of
        1 -> {?GONE, read_write, false};
        _ -> pick(Handles)
    end.

target(Run) ->
    case rand:uniform(2) of
        1 -> {open, handle(Run)};
        2 -> {node, ino(Run)}
    end.

changes() ->
    Fields = [{mode, mode()}, {uid, pick([0, 5])}, {gid, pick([0, 5])},
              {size, offset()}, {atime, pick([now, 7, -7])},
              {mtime, pick([now, 9])}],
    maps:from_list([Field || Field <- Fields, rand:uniform(4) =:= 1]).

%% Each open handle is clunked once, as erx_fs clunks it.
clunk_request(#run{handles = []} = Run) -> {getattr, ino(Run)};
clunk_request(#run{handles = Handles}) -> {clunk, pick(Handles)}.

pick(List) -> lists:nth(rand:uniform(length(List)), List).

%% ---------------------------------------------------------------------------
%% What the replies say, against the model
%% ---------------------------------------------------------------------------

observed(_N, _S, {walk, _, _, Holder}, {ok, Ino, _Qid}, #run{holds = Holds} = Run) ->
    known(Ino, Run#run{holds = lists:usort([{Holder, Ino} | Holds])});
observed(_N, _S, {forget, Ino, Holder}, ok, #run{holds = Holds} = Run) ->
    Run#run{holds = lists:delete({Holder, Ino}, Holds)};
observed(_N, _S, {forget_holder, Holder}, ok, #run{holds = Holds} = Run) ->
    Run#run{holds = [Hold || {H, _} = Hold <- Holds, H =/= Holder]};
observed(N, S, {getattr, Ino}, {ok, #{kind := file, size := Size}}, Run) ->
    case Run#run.files of
        #{Ino := {Size, _}} -> Run;
        #{Ino := Model} -> error({size_disagrees, N, S, Ino, Size, Model});
        #{} -> Run
    end;
observed(_N, _S, {open, Ino, {_, Options}}, {ok, Handle}, Run) ->
    opened(Handle, truncated_if(Options, Ino, Run));
observed(_N, _S, {make, _, _, {file, _, {_, Options}}}, {ok, Ino, _Qid, Handle},
         #run{files = Files} = Run) ->
    Run1 = case Files of
               #{Ino := _} -> truncated_if(Options, Ino, Run);
               #{} -> Run#run{files = Files#{Ino => {0, []}}}
           end,
    opened(Handle, known(Ino, Run1));
observed(_N, _S, {make, _, _, _}, {ok, Ino, _Qid}, Run) ->
    known(Ino, Run);
%% A write lands at the end for an append handle and at its offset
%% otherwise, and is cut short at the largest size.
observed(N, S, {write, {Ino, _, Append}, Offset, Data}, {ok, Count, At},
         #run{files = Files} = Run) ->
    {Size, Writes} = map_get(Ino, Files),
    ExpectedAt = case Append of
                     true -> Size;
                     false -> Offset
                 end,
    ExpectedCount = min(byte_size(Data), max(0, ?MAX_SIZE - ExpectedAt)),
    case {At, Count} of
        {ExpectedAt, ExpectedCount} -> ok;
        _ -> error({write_disagrees, N, S, Ino, {At, Count},
                    {ExpectedAt, ExpectedCount}})
    end,
    Model = case Count of
                0 -> {Size, Writes};
                _ -> {max(Size, At + Count),
                      [{At, binary_part(Data, 0, Count)} | Writes]}
            end,
    Run#run{files = Files#{Ino := Model}};
observed(N, S, {read, {Ino, _, _}, Offset, Count}, {ok, Bytes}, Run) ->
    Expected = expected(map_get(Ino, Run#run.files), Offset, Count),
    case Bytes =:= Expected of
        true -> Run;
        false -> error({read_disagrees, N, S, Ino, Offset, Count})
    end;
observed(_N, _S, {setattr, Target, #{size := Size}}, ok, Run) ->
    Ino = case Target of
              {open, {I, _, _}} -> I;
              {node, I} -> I
          end,
    resized(Ino, Size, Run);
observed(_N, _S, {clunk, Handle}, ok, #run{handles = Handles} = Run) ->
    Run#run{handles = lists:delete(Handle, Handles)};
observed(_N, _S, _Request, _Reply, Run) ->
    Run.

known(Ino, #run{inos = Inos} = Run) ->
    case lists:member(Ino, Inos) of
        true -> Run;
        false -> Run#run{inos = [Ino | Inos]}
    end.

opened(Handle, #run{handles = Handles} = Run) ->
    Run#run{handles = [Handle | Handles]}.

truncated_if(Options, Ino, Run) ->
    case lists:member(trunc, Options) andalso is_map_key(Ino, Run#run.files) of
        true -> resized(Ino, 0, Run);
        false -> Run
    end.

resized(Ino, Size, #run{files = Files} = Run) ->
    {_Old, Writes} = map_get(Ino, Files),
    Kept = [{At, binary_part(Bytes, 0, min(byte_size(Bytes), Size - At))} ||
               {At, Bytes} <- Writes, At < Size],
    Run#run{files = Files#{Ino := {Size, Kept}}}.

%% The bytes a read should return: zeros, with every write that reached the
%% range laid over them, oldest first.
expected({Size, Writes}, Offset, Count) ->
    Length = max(0, min(Offset + min(Count, ?MAX_READ), Size) - Offset),
    lists:foldr(fun({At, Bytes}, Acc) -> overlay(At, Bytes, Offset, Length, Acc) end,
                <<0:(Length * 8)>>, Writes).

overlay(At, Bytes, Offset, Length, Acc) ->
    From = max(At, Offset),
    To = min(At + byte_size(Bytes), Offset + Length),
    case From < To of
        true ->
            Lo = From - Offset,
            Hi = To - Offset,
            <<(binary_part(Acc, 0, Lo))/binary,
              (binary_part(Bytes, From - At, To - From))/binary,
              (binary_part(Acc, Hi, Length - Hi))/binary>>;
        false ->
            Acc
    end.
