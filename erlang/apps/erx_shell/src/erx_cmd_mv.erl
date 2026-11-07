%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_mv).
-moduledoc """
`mv source target` and `mv source ... dir`: renames each source to the
target, or into the directory under its own last name. pairs/2, which
cp shares, decides which form a line of arguments is.
""".

-behaviour(erx_cmd).
-erx_command(mv).
-erx_usage("mv source target | mv source ... dir").

-export([run/2, pairs/2]).

run(Args, Ctx) ->
    case pairs(Args, Ctx) of
        {ok, Pairs} -> each(Pairs, fun file:rename/2, Ctx);
        {error, usage} -> {error, usage}
    end.

-doc """
The sources of a line of arguments, each with where it goes, as absolute
paths with the source as written: into the last argument when it is a
directory, else to it, which takes one source alone.
""".
-spec pairs([binary()], erx_cmd:ctx()) -> {ok, [{binary(), binary(), binary()}]} | {error, usage}.
pairs(Args, Ctx) when length(Args) >= 2 ->
    {Sources, [Target]} = lists:split(length(Args) - 1, Args),
    To = erx_cmd:path(Ctx, Target),
    case {filelib:is_dir(To), Sources} of
        {true, _} ->
            {ok, [{Source, erx_cmd:path(Ctx, Source), erx_cmd:path(To, filename:basename(Source))}
                  || Source <- Sources]};
        {false, [Source]} ->
            {ok, [{Source, erx_cmd:path(Ctx, Source), To}]};
        {false, _} ->
            {error, usage}
    end;
pairs(_Args, _Ctx) ->
    {error, usage}.

each(Pairs, Act, Ctx) ->
    Failed = [begin erx_cmd:report(Ctx, Shown, Reason), Reason end
              || {Shown, From, To} <- Pairs, {error, Reason} <- [Act(From, To)]],
    case Failed of
        [] -> ok;
        [First | _] -> {error, {reported, First}}
    end.
