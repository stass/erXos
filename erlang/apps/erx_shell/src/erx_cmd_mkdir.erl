%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_mkdir).
-moduledoc """
`mkdir [-p] dir ...`: makes each directory; `-p` makes its missing
parents too and takes one that exists as made.
""".

-behaviour(erx_cmd).
-erx_command(mkdir).
-erx_usage("mkdir [-p] dir ...").

-export([run/2]).

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "p") of
        {ok, _Flags, []} -> {error, usage};
        {ok, Flags, Dirs} -> each(Dirs, lists:member($p, Flags), Ctx);
        {error, usage} -> {error, usage}
    end.

each(Dirs, Parents, Ctx) ->
    case [Reason || Dir <- Dirs, {error, Reason} <- [make(Dir, Parents, Ctx)]] of
        [] -> ok;
        [First | _] -> {error, {reported, First}}
    end.

make(Dir, Parents, Ctx) ->
    Path = erx_cmd:path(Ctx, Dir),
    Result = case Parents of
                 true -> filelib:ensure_path(Path);
                 false -> file:make_dir(Path)
             end,
    case Result of
        ok -> ok;
        {error, Reason} -> erx_cmd:report(Ctx, Dir, Reason), {error, Reason}
    end.
