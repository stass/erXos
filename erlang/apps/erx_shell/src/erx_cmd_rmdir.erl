%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_rmdir).
-moduledoc """
`rmdir [-pv] dir ...`: removes each empty directory, as FreeBSD's
rmdir(1) does. `-p` then removes each parent the operand names, from the
last up, stopping at the first that cannot be removed; `-v` prints each
directory removed. A directory that is not empty is reported as such and
left; the status is the first failure's.
""".

-behaviour(erx_cmd).
-erx_command(rmdir).
-erx_usage("rmdir [-pv] dir ...").

-export([run/2]).

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "pv") of
        {ok, _Flags, []} -> {error, usage};
        {ok, Flags, Dirs} -> each(Dirs, Flags, Ctx);
        {error, usage} -> {error, usage}
    end.

each(Dirs, Flags, Ctx) ->
    case [Reason || Dir <- Dirs, {error, Reason} <- [remove(Dir, Flags, Ctx)]] of
        [] -> ok;
        [First | _] -> {error, {reported, First}}
    end.

%% Dir, then with -p each parent it names, as FreeBSD's rm_path strips a
%% last component and its slashes at a time.
remove(Dir, Flags, Ctx) ->
    Removed = removed(Dir, Flags, Ctx),
    case Removed =:= ok andalso lists:member($p, Flags) of
        true -> parents(Dir, Flags, Ctx);
        false -> Removed
    end.

parents(Dir, Flags, Ctx) ->
    case parent(Dir) of
        none -> ok;
        Parent -> on_ok(removed(Parent, Flags, Ctx), fun() -> parents(Parent, Flags, Ctx) end)
    end.

%% The operand with its last component and the slashes before it taken
%% off, or none once no slash is left or only the leading ones are.
parent(Dir) ->
    case string:split(string:trim(Dir, trailing, "/"), <<"/">>, trailing) of
        [_Last] -> none;
        [Head, _Last] ->
            case string:trim(Head, trailing, "/") of
                <<>> -> none;
                Parent -> Parent
            end
    end.

removed(Dir, Flags, Ctx) ->
    case file:del_dir(erx_cmd:path(Ctx, Dir)) of
        ok ->
            _ = lists:member($v, Flags) andalso erx_cmd:write(Ctx, [Dir, $\n]),
            ok;
        {error, Reason} ->
            Shown = shown(Reason),
            erx_cmd:report(Ctx, Dir, Shown),
            {error, Shown}
    end.

%% file:del_dir/1 answers eexist for a directory that is not empty, as stock
%% OTP does; rmdir(2) calls it ENOTEMPTY.
shown(eexist) -> enotempty;
shown(Reason) -> Reason.

on_ok(ok, Then) -> Then();
on_ok(Error, _Then) -> Error.
