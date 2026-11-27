%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_volume).
-moduledoc """
The volume process of a mounted F2FS volume (docs/design-f2fs.md, "One
process owns a volume" and "Processes and ownership"): the one process
that holds the volume's state and reads and writes its window, and the
one client of that window. The callback module erx_f2fs makes each erx_fs
callback one call to it.

It mounts in init/1 (erx_f2fs_mount) and then serves one request at a
time, in the order they arrive, so no two requests interleave. What a
request does is erx_f2fs_request's, pure; this module does its effects.
A step that answers {need, Addresses} has those blocks read, every
contiguous run of them as one window request of at most the window's
max_sectors, all sent at once and collected in order, and runs again
from the start with them added. The blocks a step reads join the cache,
which no eviction touches while the step runs, so every block a step was
given stays until it answers; after it the cache drops its oldest blocks
down to its limit, ?CACHE_BLOCKS. The mount's own blocks, the SIT among
them, are not cached: the mount's state holds what it decoded.

A step that fails a check of the medium, or a block read the window
refuses, answers eio and logs one line naming the node and the rule, or
the blocks; the volume goes on.

A volume started with mode read_write mounts read-write when its window's
role is writable and the mount answers read_write, and read-only
otherwise, with a log line naming why. A read-write mount builds
erx_f2fs_core's state and writes the mount checkpoint before it serves
anything ("Read-write mounts: the mount checkpoint"). Its requests read
the state's view, and every change is held in the state until an fsync,
or unmount/1, runs erx_f2fs_plan's checkpoint: each phase's blocks
written, contiguous ones as one request, all sent at once, then a flush,
and the committed state adopted only once the last flush is answered
("Checkpoints"). A write's blocks are claimed in the warm data log and
set in their slots in a state of its own, which is adopted only once the
blocks are written, so a checkpoint's first flush covers them (ordering
1); a state that would leave the next checkpoint no room is dropped
for a checkpoint and a second try, and a write past the space the volume
offers answers enospc having changed nothing. Every block written joins the cache over
whatever it held at that address, so no read and no plan takes a block
older than the medium's. A write or flush the window refuses ends the
volume with eio: until the last flush, the medium holds the committed
checkpoint whole, and the restart mounts it.
""".
-behaviour(gen_server).

-export([start_link/2, call/2, unmount/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("generated/erx_abi.hrl").

-define(BLOCK_SIZE, (1 bsl ?ERX_F2FS_LOG_BLOCK_SIZE)).
%% The window's sector.
-define(SECTOR_SIZE, 512).
-define(SECTORS_PER_BLOCK, (?BLOCK_SIZE div ?SECTOR_SIZE)).
%% The blocks the cache keeps between steps, 4 MiB.
-define(CACHE_BLOCKS, 1024).
%% The log a write's blocks are claimed in (docs/design-f2fs.md, "Scope: features and forms").
-define(WARM_DATA, 1).

%% The blocks a request's steps may use: the cache's, by address, the
%% order they joined it in, oldest first, and how many it keeps.
-type cache() :: #{blocks := #{non_neg_integer() => binary()}, order := queue:queue(),
                   limit := pos_integer()}.

-doc """
The volume over Window, an erx_blk_window, linked to the caller, mounting
with at most Allowance bytes of tables: {ok, Pid}, or {error, Reason},
eintegrity for an image that fails a check or holds a chain to replay,
enomem for one whose tables pass the allowance, eio for a block read,
write or flush that failed or a window whose info fails, and einval for a
window whose requests cannot carry a block. Mode, read_only unless given,
asks for a read-write mount.
""".
-spec start_link(pid(), #{allowance := non_neg_integer(), mode => read_only | read_write}) ->
          {ok, pid()} | {error, term()}.
start_link(Window, #{allowance := Allowance} = Options) when is_pid(Window) ->
    gen_server:start_link(?MODULE, {Window, Allowance, maps:get(mode, Options, read_only)}, []).

-doc """
Unmounts Volume: a read-write volume writes a checkpoint of everything it
holds first. ok, or eio when that checkpoint failed; the volume ends either way.
""".
-spec unmount(pid()) -> ok | {error, eio}.
unmount(Volume) -> call(Volume, unmount).

-doc "Request on Volume, eio once the volume has ended.".
-spec call(pid(), erx_f2fs_request:request()) -> term().
call(Volume, Request) ->
    try gen_server:call(Volume, Request, infinity) catch exit:_ -> {error, eio} end.

%%% The mount

-doc false.
-spec init({pid(), non_neg_integer(), read_only | read_write}) -> {ok, map()} | {error, term()}.
init({Window, Allowance, Mode}) ->
    case erx_blk_window:info(Window) of
        {ok, #{sectors := Sectors, max_sectors := MaxSectors, role := Role}}
          when MaxSectors >= ?SECTORS_PER_BLOCK ->
            Effects = #{window => Window, max_blocks => MaxSectors div ?SECTORS_PER_BLOCK,
                        cache => #{blocks => #{}, order => queue:new(), limit => ?CACHE_BLOCKS}},
            Partition = Sectors div ?SECTORS_PER_BLOCK,
            Mount = fun(Blocks) -> erx_f2fs_mount:mount(Partition, Allowance, Blocks) end,
            case need_loop(Mount, #{}, [], Effects) of
                {{ok, Volume}, Blocks, _Read} ->
                    mounted(Effects#{volume => Volume}, writable(Mode, Role, Volume), Blocks);
                {Failed, _Blocks, _Read} ->
                    {error, refused(Failed)}
            end;
        {ok, #{}} ->
            {error, einval};
        Failed ->
            logger:error("f2fs: the window's info failed: ~0p", [Failed]),
            {error, eio}
    end.

%% Whether a mount asked for in Mode, over a window of Role, is read-write;
%% a read-only answer to a read-write ask is logged with its reason.
writable(read_only, _Role, _Volume) ->
    false;
writable(read_write, Role, #{mode := Mode}) ->
    case {erx_blk_table:read_only(Role), Mode} of
        {false, read_write} -> true;
        {true, _} -> read_only_because(window_read_only);
        {false, {read_only, Reasons}} -> read_only_because(Reasons)
    end.

read_only_because(Reason) ->
    logger:notice("f2fs: mounting read-only: ~0p", [Reason]),
    false.

%% A mounted volume's state: a read-write one's core state, built from the
%% mount's blocks, committed by the mount checkpoint.
mounted(State, false, _Blocks) ->
    {ok, State};
mounted(#{volume := Volume} = State, true, Blocks) ->
    case need_loop(fun(Given) -> erx_f2fs_core:state(Volume, Given) end, Blocks, [], State) of
        {{ok, Core}, _Blocks, _Read} ->
            case checkpoint(State#{core => Core}) of
                {ok, Committed} -> {ok, Committed};
                {error, eio} -> {error, eio}
            end;
        {{error, Failure}, _Blocks, _Read} ->
            read_only_because(Failure),
            {ok, State};
        {Failed, _Blocks, _Read} ->
            {error, refused(Failed)}
    end.

%% Why a mount failed, logged once.
refused({error, {allowance, _} = Failure}) ->
    logger:error("f2fs: the mount's tables pass its allowance: ~0p", [Failure]),
    enomem;
refused({error, {walk, {chain, Start, Ino}}}) ->
    logger:error("f2fs: the volume holds a roll-forward chain from block ~b, its first fsynced "
                 "node inode ~b's, which erXos does not replay; mount it once in Linux, which "
                 "replays the chain and writes a checkpoint", [Start, Ino]),
    eintegrity;
refused({error, {walk, long}}) ->
    logger:error("f2fs: the volume holds more than ~b matching node blocks after its checkpoint; mount it once "
                 "in Linux, which replays the chain and writes a checkpoint", [erx_f2fs_mount:walk_blocks()]),
    eintegrity;
refused({unread, _Runs}) ->
    eio;
refused({error, Failure}) ->
    logger:error("f2fs: the mount failed: ~0p", [Failure]),
    eintegrity.

%%% Requests

-doc false.
handle_call(unmount, _From, #{core := _} = State) ->
    case committed(State) of
        {ok, Committed} -> {stop, normal, ok, Committed};
        {error, eio} -> {stop, eio, {error, eio}, State}
    end;
handle_call(unmount, _From, State) ->
    {stop, normal, ok, State};
handle_call(Request, _From, State) ->
    case moved(erx_f2fs_request:start(Request, reader(State)), State) of
        {ended, Reply, State1} -> {stop, eio, Reply, State1};
        {Reply, State1} -> {reply, Reply, State1}
    end.

%% What a request reads: a read-write volume's view of its state, else the
%% mounted volume.
reader(#{core := Core}) -> erx_f2fs_core:view(Core);
reader(#{volume := Volume}) -> Volume.

-doc false.
handle_cast(_Request, State) ->
    {noreply, State}.

%% The window's late answers and stray messages are dropped.
-doc false.
handle_info(_Message, State) ->
    {noreply, State}.

%% A request's moves to its answer, each step run through the need loop
%% and the cache trimmed after it.
moved({reply, Reply}, State) ->
    {Reply, State};
moved({failed, Nid, Failure}, State) ->
    logger:error("f2fs: node ~b failed a check: ~0p", [Nid, Failure]),
    {{error, eio}, State};
moved(checkpoint, State) ->
    case committed(State) of
        {ok, Committed} -> {ok, Committed};
        {error, eio} -> {ended, {error, eio}, State}
    end;
moved({write, _Ino, _Placed, _Size, _Reply} = Write, State) ->
    stored(Write, State, first);
moved({then, Step}, #{cache := #{blocks := Cached} = Cache} = State) ->
    Reader = reader(State),
    {Move, Blocks, Read} = need_loop(fun(Given) -> Step(Reader, Given) end, Cached, [], State),
    State1 = State#{cache := trimmed(Cache#{blocks := Blocks}, Read)},
    case Move of
        {unread, _Runs} -> {{error, eio}, State1};
        _ -> moved(Move, State1)
    end.

%% A checkpoint when the epoch changed anything, else nothing to write.
committed(#{core := Core} = State) ->
    case erx_f2fs_core:changed(Core) of
        false -> {ok, State};
        true -> checkpoint(State)
    end.

%% A write tried on the state: its blocks claimed in the warm data log and
%% set in their slots. The state that leaves is adopted once the blocks are
%% written, if it leaves the next checkpoint room (erx_f2fs_core:roomy/1);
%% else the volume checkpoints what it holds and tries once more, and
%% answers enospc when it holds nothing to commit or the second try finds
%% no room either. A write past the space the volume offers answers enospc
%% at once, as a checkpoint frees none of it. Nothing is written or adopted
%% before the write is admitted.
stored(Write, State, Try) ->
    case tried(Write, State) of
        {ok, Core, Writes, State1} ->
            case erx_f2fs_core:roomy(Core) of
                true -> adopted(Write, Core, Writes, State1);
                false -> made_room(Write, State1, Try)
            end;
        {no_room, State1} ->
            made_room(Write, State1, Try);
        Refused ->
            Refused
    end.

%% The write tried again after a checkpoint, when the first try found no
%% room and the state holds something to commit.
made_room(Write, #{core := Core} = State, first) ->
    case erx_f2fs_core:changed(Core) andalso checkpoint(State) of
        false -> {{error, enospc}, State};
        {ok, Committed} -> stored(Write, Committed, second);
        {error, eio} -> {ended, {error, eio}, State}
    end;
made_room(_Write, State, second) ->
    {{error, enospc}, State}.

%% The core's state after the write, and the blocks to write, {Address,
%% Bytes} each; no_room when no free section takes the blocks.
tried({write, Ino, Placed, Size, _Reply}, #{core := Core, cache := #{blocks := Cached} = Cache} = State) ->
    {Blocks, Bytes} = lists:unzip(Placed),
    case erx_f2fs_core:allocate(Core, ?WARM_DATA, length(Placed)) of
        {ok, Addresses, Claimed} ->
            Time = erlang:system_time(nanosecond),
            Set = fun(Given) ->
                          erx_f2fs_core:write(Claimed, Ino, lists:zip(Blocks, Addresses), Size, Time, Given)
                  end,
            {Answer, Read, Order} = need_loop(Set, Cached, [], State),
            State1 = State#{cache := trimmed(Cache#{blocks := Read}, Order)},
            case Answer of
                {ok, Written} -> {ok, Written, lists:zip(Addresses, Bytes), State1};
                {error, {space, full}} -> {{error, enospc}, State1};
                {unread, _Runs} -> {{error, eio}, State1};
                {error, Failure} ->
                    logger:error("f2fs: setting a write's slots failed: ~0p", [Failure]),
                    {{error, eio}, State1}
            end;
        {error, enospc} ->
            {no_room, State}
    end.

%% The write's blocks written, then its state adopted and its answer given.
adopted({write, _Ino, _Placed, _Size, Reply}, Core, Writes, State) ->
    case written(Writes, State) of
        {ok, State1} -> {Reply, State1#{core := Core}};
        {error, eio} ->
            {ended, {error, eio}, State}
    end.

%%% Checkpoints and writes

%% The checkpoint of State's core: the plan, each phase written and then
%% flushed, and the committed state adopted after the last flush.
checkpoint(#{core := Core, cache := #{blocks := Cached} = Cache} = State) ->
    {Answer, Blocks, Read} = need_loop(fun(Given) -> erx_f2fs_plan:checkpoint(Core, Given) end,
                                       Cached, [], State),
    State1 = State#{cache := trimmed(Cache#{blocks := Blocks}, Read)},
    case Answer of
        {ok, Plan, Committed} ->
            case lists:foldl(fun(Phase, {ok, S}) -> flushed(written(Phase, S));
                                (_Phase, Failed) -> Failed
                             end, {ok, State1}, Plan) of
                {ok, State2} -> {ok, State2#{core := Committed}};
                Failed -> Failed
            end;
        {unread, _Runs} ->
            {error, eio};
        {error, Failure} ->
            logger:error("f2fs: a checkpoint's plan failed: ~0p", [Failure]),
            {error, eio}
    end.

%% Writes, {Address, Block} each, sent to the window, each run of
%% contiguous blocks as requests of at most max_blocks, all before the
%% first answer is taken; every block joins the cache once all are answered.
written(Writes, #{window := Window, max_blocks := MaxBlocks, cache := Cache} = State) ->
    Requests = [{First, Count, gen_server:send_request(Window, {write, First * ?SECTORS_PER_BLOCK, Bytes})}
                || {First, Count, Bytes} <- write_runs(lists:keysort(1, Writes), MaxBlocks)],
    Answers = [{First, Count, gen_server:receive_response(Id, infinity)} || {First, Count, Id} <- Requests],
    case [{First, Count} || {First, Count, Answer} <- Answers, Answer =/= {reply, ok}] of
        [] ->
            #{blocks := Blocks} = Cache,
            Cached = lists:foldl(fun({Address, Block}, Acc) -> Acc#{Address => Block} end, Blocks, Writes),
            Added = [A || {A, _} <- Writes, not is_map_key(A, Blocks)],
            {ok, State#{cache := trimmed(Cache#{blocks := Cached}, Added)}};
        Failed ->
            logger:error("f2fs: writing blocks failed, {first, count} each: ~0p", [Failed]),
            {error, eio}
    end.

%% A flush after written blocks; a medium that cannot flush keeps no
%% order, as docs/design-storage.md records.
flushed({ok, #{window := Window} = State}) ->
    case gen_server:call(Window, flush, infinity) of
        ok -> {ok, State};
        {error, enotsup} -> {ok, State};
        Failed ->
            logger:error("f2fs: a flush failed: ~0p", [Failed]),
            {error, eio}
    end;
flushed(Failed) ->
    Failed.

%% Sorted writes as runs {First, Count, Bytes} of contiguous blocks, each
%% at most Max long.
write_runs([], _Max) -> [];
write_runs([{First, Block} | Rest], Max) -> write_runs(First, 1, [Block], Rest, Max).

write_runs(First, Count, Run, [{Next, Block} | Rest], Max) when Next =:= First + Count, Count < Max ->
    write_runs(First, Count + 1, [Block | Run], Rest, Max);
write_runs(First, Count, Run, Rest, Max) ->
    [{First, Count, iolist_to_binary(lists:reverse(Run))} | write_runs(Rest, Max)].

%% Step run over Blocks until it answers, each need's blocks read and
%% added: its answer, the blocks, and the addresses read, latest first. A
%% read the window refuses ends the loop with {unread, Runs}, a tag no step
%% answers.
need_loop(Step, Blocks, Read, Effects) ->
    case Step(Blocks) of
        {need, Addresses} ->
            Wanted = lists:usort(Addresses),
            case read_blocks(Wanted, Effects) of
                {ok, Got} ->
                    Blocks1 = lists:foldl(fun({Address, Block}, Acc) -> Acc#{Address => Block} end,
                                          Blocks, Got),
                    need_loop(Step, Blocks1, lists:reverse(Wanted, Read), Effects);
                {unread, _Runs} = Failed ->
                    {Failed, Blocks, Read}
            end;
        Answer ->
            {Answer, Blocks, Read}
    end.

%% The blocks at Addresses, sorted, read through the window: each run of
%% contiguous blocks as requests of at most MaxBlocks, all sent before the
%% first answer is taken.
read_blocks(Addresses, #{window := Window, max_blocks := MaxBlocks}) ->
    Requests = [{First, Count, gen_server:send_request(Window, {read, First * ?SECTORS_PER_BLOCK,
                                                                Count * ?SECTORS_PER_BLOCK})}
                || {First, Count} <- runs(Addresses, MaxBlocks)],
    Answers = [{First, Count, gen_server:receive_response(Id, infinity)}
               || {First, Count, Id} <- Requests],
    case [{First, Count} || {First, Count, Answer} <- Answers, not full_read(Answer, Count)] of
        [] ->
            {ok, lists:append([split(First, Bytes) || {First, _Count, {reply, {ok, Bytes}}} <- Answers])};
        Failed ->
            logger:error("f2fs: reading blocks failed, {first, count} each: ~0p", [Failed]),
            {unread, Failed}
    end.

full_read({reply, {ok, Bytes}}, Count) -> byte_size(Bytes) =:= Count * ?BLOCK_SIZE;
full_read(_Answer, _Count) -> false.

split(_Address, <<>>) -> [];
split(Address, <<Block:?BLOCK_SIZE/binary, Rest/binary>>) -> [{Address, Block} | split(Address + 1, Rest)].

%% Sorted addresses as runs {First, Count} of contiguous blocks, each at
%% most Max long.
runs([], _Max) -> [];
runs([First | Rest], Max) -> runs(First, 1, Rest, Max).

runs(First, Count, [Next | Rest], Max) when Next =:= First + Count, Count < Max ->
    runs(First, Count + 1, Rest, Max);
runs(First, Count, Rest, Max) ->
    [{First, Count} | runs(Rest, Max)].

%% The cache after a step that read Read, latest first: they join it last,
%% and the oldest blocks leave until it holds at most its limit.
-spec trimmed(cache(), [non_neg_integer()]) -> cache().
trimmed(#{order := Order} = Cache, Read) ->
    evicted(Cache#{order := lists:foldr(fun queue:in/2, Order, Read)}).

evicted(#{blocks := Blocks, order := Order, limit := Limit} = Cache) when map_size(Blocks) > Limit ->
    {{value, Oldest}, Order1} = queue:out(Order),
    evicted(Cache#{blocks := maps:remove(Oldest, Blocks), order := Order1});
evicted(Cache) ->
    Cache.
