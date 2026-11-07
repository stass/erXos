%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_ls).
-moduledoc """
`ls [-l] [path ...]`: one record per name, the working directory's for
no path. A file is listed by the path given, a directory by the names it
holds, sorted, without those that start with `.`; with more than one
path, each directory's names follow a record of the directory's own,
as FreeBSD's ls heads them. `-l` adds each name's type (`d`, `-`, `l` or
`?`) and size. A name is the file system's text, so the terminal shows
it through the line escape (erx_render).
""".

-behaviour(erx_cmd).
-erx_command(ls).
-erx_usage("ls [-l] [path ...]").
-erx_fields([type, size, name]).

-export([run/2]).

-include_lib("kernel/include/file.hrl").

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "l") of
        {ok, Flags, Paths} ->
            Long = lists:member($l, Flags),
            list(case Paths of [] -> [<<".">>]; _ -> Paths end, Long, Ctx);
        {error, usage} ->
            {error, usage}
    end.

list(Paths, Long, Ctx) ->
    Infos = [{Path, file:read_file_info(erx_cmd:path(Ctx, Path))} || Path <- Paths],
    Errors = [begin erx_cmd:report(Ctx, Path, Reason), Reason end
              || {Path, {error, Reason}} <- Infos],
    Files = [{Path, Info} || {Path, {ok, #file_info{type = Type} = Info}} <- Infos, Type =/= directory],
    Dirs = [Path || {Path, {ok, #file_info{type = directory}}} <- Infos],
    [emit(Path, Info, Long, Ctx) || {Path, Info} <- lists:sort(Files)],
    Headed = length(Paths) > 1,
    DirErrors = [Reason || Dir <- lists:sort(Dirs), {error, Reason} <- [directory(Dir, Headed, Long, Ctx)]],
    case Errors ++ DirErrors of
        [] -> ok;
        [First | _] -> {error, {reported, First}}
    end.

directory(Dir, Headed, Long, Ctx) ->
    Path = erx_cmd:path(Ctx, Dir),
    case file:list_dir(Path) of
        {ok, Names} ->
            Headed andalso erx_cmd:emit(Ctx, #{name => ok(<<Dir/binary, ":">>)}),
            Shown = lists:sort([Name || Name <- lists:map(fun binary_name/1, Names),
                                        binary:first(Name) =/= $.]),
            [emit(Name, info(erx_cmd:path(Path, Name)), Long, Ctx) || Name <- Shown],
            ok;
        {error, Reason} ->
            erx_cmd:report(Ctx, Dir, Reason),
            {error, Reason}
    end.

info(Path) ->
    case file:read_link_info(Path) of
        {ok, Info} -> Info;
        {error, _} -> unknown
    end.

emit(Name, _Info, false, Ctx) ->
    erx_cmd:emit(Ctx, #{name => ok(Name)});
emit(Name, unknown, true, Ctx) ->
    erx_cmd:emit(Ctx, #{type => {service, unknown}, size => {service, unknown}, name => ok(Name)});
emit(Name, #file_info{type = Type, size = Size}, true, Ctx) ->
    erx_cmd:emit(Ctx, #{type => ok(type_letter(Type)), size => ok(Size), name => ok(Name)}).

ok(Value) -> {service, {ok, Value}}.

type_letter(directory) -> <<"d">>;
type_letter(regular) -> <<"-">>;
type_letter(symlink) -> <<"l">>;
type_letter(_) -> <<"?">>.

binary_name(Name) when is_binary(Name) -> Name;
binary_name(Name) -> unicode:characters_to_binary(Name).
