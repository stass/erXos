%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fat_plan).
-moduledoc """
The one writer of a FAT volume's plans (docs/design-fsck-fat.md, "The repair
order"): a plan is a list of steps, each a list of places and the image to write
there, and apply/4 writes each step's images and then flushes, so no write of a
step reaches the medium before the steps before it are durable. The FAT server's
volume process writes its batches through it, and erx_fat_check:write/4 a repair's
commits.

A place is one sector, or a FAT sector and its copies, `{copies, First, Stride,
Count}`: the same image at First and every Stride sectors after it, Count sectors in
all. A plan names each FAT sector once, so its size follows the sectors a batch
holds whatever count of FATs the volume's boot sector declares, and the copies are
written here. A step's writes go in rounds: every image to its first sector, then
to each copy, all of a step's second copies before any third, so the FAT the server
reads gets each step's images before its mirrors do.

A round is written as runs: its sectors in ascending order, each run the longest
stretch of contiguous sectors from where the one before ended, up to RunMax sectors,
written as one request of their images end to end. No flush lies inside a round, so
no rule orders its sectors and a medium may take them in any order; ordering them
by sector makes every run as long as the plan allows. A sector a round names twice
starts a run of its own, after the one that wrote it first, so its last image is
sent last. One run's bytes are built at a time.
""".

-export([apply/4, copies/3, first/1]).
-export_type([plan/0, place/0]).

-type plan() :: [{atom(), [{place(), binary()}]}].
-type place() :: non_neg_integer() | {copies, non_neg_integer(), pos_integer(), pos_integer()}.
-type write_run() :: fun((non_neg_integer(), pos_integer(), binary()) -> ok | {error, term()}).
-type flush() :: fun(() -> ok | {error, term()}).

-doc """
Plan written step by step, each step's images in runs of at most RunMax sectors
through Write, as Write(First, Count, Bytes), Count sectors from First, and then a
Flush; `ok`, or the first answer of Write or Flush that is not `ok`, after which
nothing more is written.
""".
-spec apply(plan(), pos_integer(), write_run(), flush()) -> ok | term().
apply([], _RunMax, _Write, _Flush) ->
    ok;
apply([{_Step, Images} | Rest], RunMax, Write, Flush) ->
    case written(Images, 0, RunMax, Write) of
        ok ->
            case Flush() of
                ok -> apply(Rest, RunMax, Write, Flush);
                Failed -> Failed
            end;
        Failed ->
            Failed
    end.

-doc """
The place of a FAT sector and its copies: First, the sector in the first FAT, and
each Stride sectors after it, Count sectors in all.
""".
-spec copies(non_neg_integer(), pos_integer(), pos_integer()) -> place().
copies(First, Stride, Count) -> {copies, First, Stride, Count}.

-doc "The first sector Place names: the sector itself, or the first FAT's of a FAT sector.".
-spec first(place()) -> non_neg_integer().
first({copies, First, _Stride, _Count}) -> First;
first(Sector) -> Sector.

%% Round Copy of Images written through Write, then the rounds after it, until a
%% round has nothing to write; `ok`, or the first answer of Write that is not.
written(Images, Copy, RunMax, Write) ->
    case round(Images, Copy) of
        [] -> ok;
        Round ->
            case runs_written(lists:keysort(1, Round), RunMax, Write) of
                ok -> written(Images, Copy + 1, RunMax, Write);
                Failed -> Failed
            end
    end.

%% Sectors, {Sector, Bytes} in ascending order, written as runs, each built when its
%% turn comes.
runs_written([], _RunMax, _Write) ->
    ok;
runs_written([{First, Bytes} | Rest], RunMax, Write) ->
    {Count, Parts, Next} = run(Rest, First + 1, 1, [Bytes], RunMax),
    case Write(First, Count, iolist_to_binary(lists:reverse(Parts))) of
        ok -> runs_written(Next, RunMax, Write);
        Failed -> Failed
    end.

%% The run that continues at sector Sector, Count sectors long so far with Parts its
%% images in reverse: {Count, Parts, Rest} once the next sector is not Sector or the
%% run holds RunMax.
run([{Sector, Bytes} | Rest], Sector, Count, Parts, RunMax) when Count < RunMax ->
    run(Rest, Sector + 1, Count + 1, [Bytes | Parts], RunMax);
run(Rest, _Sector, Count, Parts, _RunMax) ->
    {Count, Parts, Rest}.

%% The sectors round Copy writes, {Sector, Bytes}: round 0 every image's first
%% sector, round K > 0 the K-th copy after it of each image with more than K.
round(Images, Copy) ->
    [{Sector, Bytes} || {Place, Bytes} <- Images, Sector <- sector(Place, Copy)].

sector(Sector, 0) when is_integer(Sector) -> [Sector];
sector({copies, First, Stride, Count}, Copy) when Copy < Count -> [First + Copy * Stride];
sector(_Place, _Copy) -> [].
