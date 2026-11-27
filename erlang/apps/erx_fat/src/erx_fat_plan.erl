%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fat_plan).
-moduledoc """
The one writer of a FAT volume's plans (docs/design-fsck-fat.md, "The repair
order"): a plan is a list of steps, each a list of sectors and the images to write
there, and apply/3 writes each step's images and then flushes, so no write of a
step reaches the medium before the steps before it are durable. The FAT server's
volume process writes its batches through it, and erx_fat_check:write/4 a repair's
commits.
""".

-export([apply/3]).
-export_type([plan/0]).

-compile({no_auto_import, [apply/3]}).

-type plan() :: [{atom(), [{non_neg_integer(), binary()}]}].
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
    case written(Images, Write) of
        ok ->
            case Flush() of
                ok -> apply(Rest, Write, Flush);
                Failed -> Failed
            end;
        Failed ->
            Failed
    end.

written([], _Write) ->
    ok;
written([{Sector, Bytes} | Rest], Write) ->
    case Write(Sector, Bytes) of
        ok -> written(Rest, Write);
        Failed -> Failed
    end.
