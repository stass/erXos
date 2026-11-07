%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_rm).
-moduledoc """
`rm [-rf] path ...`: removes each file; `-r` removes a directory and
everything under it, and `-f` takes a path that names nothing as removed.
An operand whose last component, as written, is `.` or `..`, or that
names `/`, is refused, as FreeBSD refuses it.
""".

-behaviour(erx_cmd).
-erx_command(rm).
-erx_usage("rm [-rf] path ...").

-export([run/2]).

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "rf") of
        {ok, _Flags, []} -> {error, usage};
        {ok, Flags, Paths} -> each(Paths, Flags, Ctx);
        {error, usage} -> {error, usage}
    end.

each(Paths, Flags, Ctx) ->
    case [Reason || Path <- Paths, {error, Reason} <- [remove(Path, Flags, Ctx)]] of
        [] -> ok;
        [First | _] -> {error, {reported, First}}
    end.

remove(Path, Flags, Ctx) ->
    Last = lists:last([<<>> | binary:split(Path, <<"/">>, [global, trim_all])]),
    case lists:member(Last, [<<>>, <<".">>, <<"..">>]) of
        true -> erx_cmd:report(Ctx, Path, einval), {error, einval};
        false -> remove_path(Path, Flags, Ctx)
    end.

remove_path(Path, Flags, Ctx) ->
    Absolute = erx_cmd:path(Ctx, Path),
    Result = case lists:member($r, Flags) andalso filelib:is_dir(Absolute) of
                 true -> file:del_dir_r(Absolute);
                 false -> file:delete(Absolute)
             end,
    case {Result, lists:member($f, Flags)} of
        {ok, _} -> ok;
        {{error, enoent}, true} -> ok;
        {{error, Reason}, _} -> erx_cmd:report(Ctx, Path, Reason), {error, Reason}
    end.
