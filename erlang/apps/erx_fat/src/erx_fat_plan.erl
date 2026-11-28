%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fat_plan).
-moduledoc """
The one writer of a FAT volume's plans (docs/design-fsck-fat.md, "The repair
order"): a plan is a list of steps, each a list of places and the image to write
there, and apply/3 writes each step's images and then flushes, so no write of a
step reaches the medium before the steps before it are durable. The FAT server's
volume process writes its batches through it, and erx_fat_check:write/4 a repair's
commits.

A place is one sector, or a FAT sector and its copies, `{copies, First, Stride,
Count}`: the same image at First and every Stride sectors after it, Count sectors in
all. A plan names each FAT sector once, so its size follows the sectors a batch
holds whatever count of FATs the volume's boot sector declares, and the copies are
written here, one at a time. A step's writes go in rounds: every image to its first
sector, then to each copy, all of a step's second copies before any third, so the
FAT the server reads gets each step's images before its mirrors do.
""".

-export([apply/3, copies/3, first/1]).
-export_type([plan/0, place/0]).

-compile({no_auto_import, [apply/3]}).

-type plan() :: [{atom(), [{place(), binary()}]}].
-type place() :: non_neg_integer() | {copies, non_neg_integer(), pos_integer(), pos_integer()}.
-type write_sector() :: fun((non_neg_integer(), binary()) -> ok | {error, term()}).
-type flush() :: fun(() -> ok | {error, term()}).

-doc """
Plan written step by step, each step's images through Write and then a Flush;
`ok`, or the first answer of Write or Flush that is not `ok`, after which nothing
more is written.
""".
-spec apply(plan(), write_sector(), flush()) -> ok | term().
apply([], _Write, _Flush) ->
    ok;
apply([{_Step, Images} | Rest], Write, Flush) ->
    case written(Images, 0, Write) of
        ok ->
            case Flush() of
                ok -> apply(Rest, Write, Flush);
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
written(Images, Copy, Write) ->
    case round(Images, Copy) of
        [] -> ok;
        Round ->
            case each_written(Round, Write) of
                ok -> written(Images, Copy + 1, Write);
                Failed -> Failed
            end
    end.

each_written([], _Write) ->
    ok;
each_written([{Sector, Bytes} | Rest], Write) ->
    case Write(Sector, Bytes) of
        ok -> each_written(Rest, Write);
        Failed -> Failed
    end.

%% The sectors round Copy writes, {Sector, Bytes}: round 0 every image's first
%% sector, round K > 0 the K-th copy after it of each image with more than K.
round(Images, Copy) ->
    [{Sector, Bytes} || {Place, Bytes} <- Images, Sector <- sector(Place, Copy)].

sector(Sector, 0) when is_integer(Sector) -> [Sector];
sector({copies, First, Stride, Count}, Copy) when Copy < Count -> [First + Copy * Stride];
sector(_Place, _Copy) -> [].
