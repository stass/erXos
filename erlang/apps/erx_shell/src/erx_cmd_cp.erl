%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_cp).
-moduledoc """
`cp source target` and `cp source ... dir`: copies each file's bytes to
the target, or into the directory under its own last name, as
erx_cmd_mv:pairs/2 decides. A source and target that are one file, by
device and inode, are refused as `identical` before either is opened,
since opening the target would empty the source.
""".

-behaviour(erx_cmd).
-erx_command(cp).
-erx_usage("cp source target | cp source ... dir").

-export([run/2]).

-include_lib("kernel/include/file.hrl").

run(Args, Ctx) ->
    case erx_cmd_mv:pairs(Args, Ctx) of
        {ok, Pairs} ->
            Failed = [begin erx_cmd:report(Ctx, Shown, Reason), Reason end
                      || {Shown, From, To} <- Pairs, {error, Reason} <- [copy(From, To)]],
            case Failed of
                [] -> ok;
                [First | _] -> {error, {reported, First}}
            end;
        {error, usage} ->
            {error, usage}
    end.

copy(From, To) ->
    case {file:read_file_info(From), file:read_file_info(To)} of
        {{ok, #file_info{major_device = Device, inode = Inode}},
         {ok, #file_info{major_device = Device, inode = Inode}}} -> {error, identical};
        _ -> copy_bytes(From, To)
    end.

copy_bytes(From, To) ->
    case file:copy(From, To) of
        {ok, _Bytes} -> ok;
        {error, Reason} -> {error, Reason}
    end.
