%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_volume).
-moduledoc """
The volume process of a mounted F2FS volume (docs/design-f2fs.md, "One
process owns a volume" and "Processes and ownership"), read-only: the one
process that holds the volume's state and reads its window, and the one
client of that window. The callback module erx_f2fs makes each erx_fs
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
""".
-behaviour(gen_server).

-export([start_link/2, call/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("generated/erx_abi.hrl").

-define(BLOCK_SIZE, (1 bsl ?ERX_F2FS_LOG_BLOCK_SIZE)).
%% The window's sector.
-define(SECTOR_SIZE, 512).
-define(SECTORS_PER_BLOCK, (?BLOCK_SIZE div ?SECTOR_SIZE)).
%% The blocks the cache keeps between steps, 4 MiB.
-define(CACHE_BLOCKS, 1024).

%% The blocks a request's steps may use: the cache's, by address, the
%% order they joined it in, oldest first, and how many it keeps.
-type cache() :: #{blocks := #{non_neg_integer() => binary()}, order := queue:queue(),
                   limit := pos_integer()}.

-doc """
The volume over Window, an erx_blk_window, linked to the caller, mounting
with at most Allowance bytes of tables: {ok, Pid}, or {error, Reason},
eintegrity for an image that fails a check or holds a chain to replay,
enomem for one whose tables pass the allowance, eio for a block read that
failed or a window whose info fails, and einval for a window whose
requests cannot carry a block.
""".
-spec start_link(pid(), #{allowance := non_neg_integer()}) -> {ok, pid()} | {error, term()}.
start_link(Window, #{allowance := Allowance}) when is_pid(Window) ->
    gen_server:start_link(?MODULE, {Window, Allowance}, []).

-doc "Request on Volume, eio once the volume has ended.".
-spec call(pid(), erx_f2fs_request:request()) -> term().
call(Volume, Request) ->
    try gen_server:call(Volume, Request, infinity) catch exit:_ -> {error, eio} end.

%%% The mount

-doc false.
-spec init({pid(), non_neg_integer()}) -> {ok, map()} | {error, term()}.
init({Window, Allowance}) ->
    case erx_blk_window:info(Window) of
        {ok, #{sectors := Sectors, max_sectors := MaxSectors}} when MaxSectors >= ?SECTORS_PER_BLOCK ->
            Effects = #{window => Window, max_blocks => MaxSectors div ?SECTORS_PER_BLOCK},
            Partition = Sectors div ?SECTORS_PER_BLOCK,
            Mount = fun(Blocks) -> erx_f2fs_mount:mount(Partition, Allowance, Blocks) end,
            case need_loop(Mount, #{}, [], Effects) of
                {{ok, Volume}, _Blocks, _Read} ->
                    {ok, Effects#{volume => Volume,
                                  cache => #{blocks => #{}, order => queue:new(),
                                             limit => ?CACHE_BLOCKS}}};
                {Failed, _Blocks, _Read} ->
                    {error, refused(Failed)}
            end;
        {ok, #{}} ->
            {error, einval};
        Failed ->
            logger:error("f2fs: the window's info failed: ~0p", [Failed]),
            {error, eio}
    end.

%% Why a mount failed, logged once.
refused({error, {allowance, _} = Failure}) ->
    logger:error("f2fs: the mount's tables pass its allowance: ~0p", [Failure]),
    enomem;
refused({error, {walk, chain}}) ->
    logger:error("f2fs: the volume holds a chain of fsynced nodes to replay; mount it once in "
                 "Linux, which replays the chain and writes a checkpoint"),
    eintegrity;
refused({unread, _Runs}) ->
    eio;
refused({error, Failure}) ->
    logger:error("f2fs: the mount failed: ~0p", [Failure]),
    eintegrity.

%%% Requests

-doc false.
handle_call(Request, _From, #{volume := Volume} = State) ->
    {Reply, State1} = moved(erx_f2fs_request:start(Request, Volume), State),
    {reply, Reply, State1}.

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
moved({then, Step}, #{volume := Volume, cache := #{blocks := Cached} = Cache} = State) ->
    {Move, Blocks, Read} = need_loop(fun(Given) -> Step(Volume, Given) end, Cached, [], State),
    State1 = State#{cache := trimmed(Cache#{blocks := Blocks}, Read)},
    case Move of
        {unread, _Runs} -> {{error, eio}, State1};
        _ -> moved(Move, State1)
    end.

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
