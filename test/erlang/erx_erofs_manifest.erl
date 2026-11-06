%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_erofs_manifest).
-moduledoc """
The EROFS reader's side of the EROFS oracle (tools/lib/erx/erofs_oracle.rb).
Mounts each image file named on the command line with `erx_erofs` over a RAM
window (`erx_erofs_tests:window/1`), unchecked, walks it from the root, and
prints what the reader sees as the manifest that
tools/lib/erx/erofs_manifest.rb parses, the same lines the Linux guest prints
for the same images. Every answer of the reader is printed as it came: a file
the reader cannot read carries its error, never a guess.
""".

-export([main/1]).

-include_lib("kernel/include/file.hrl").

-define(PREFIX, "erx-erofs: ").

main(Paths) ->
    Count = length(Paths),
    lists:foreach(fun({Index, Path}) -> image(Index, Path) end,
                  lists:zip(lists:seq(0, Count - 1), Paths)),
    line(["done ", integer_to_list(Count)]),
    halt(0).

image(Index, Path) ->
    {ok, Bytes} = file:read_file(Path),
    case erx_erofs:mount(erx_erofs_tests:window(Bytes), unchecked, fun(_) -> ok end) of
        {ok, Fs} ->
            line(["image ", integer_to_list(Index)]),
            Entries = walk(Fs, [[]], 0),
            line(["end ", integer_to_list(Index), " ", integer_to_list(Entries)]);
        {error, Posix, _Diagnostic} ->
            line(["refused ", integer_to_list(Index), " ", atom_to_list(Posix)])
    end.

%% The work list holds the names of the files still to visit. Each step prints one
%% file's entry and puts a directory's children at the front of the list; the walk
%% answers how many entries it printed. It iterates over the list, so the image's
%% depth never drives recursion.
walk(_Fs, [], Printed) ->
    Printed;
walk(Fs, [Names | Rest], Printed) ->
    {Children, Line} = entry(Fs, Names, erx_erofs:file_info(Fs, Names)),
    line(Line),
    walk(Fs, Children ++ Rest, Printed + 1).

%% The children to visit and the entry line of the file Names names, from what
%% `prim_file` answers for it on erXos: `erx_erofs:file_info/2`'s record, whose mode
%% carries the type bits and whose mtime is in POSIX seconds.
entry(Fs, Names, #file_info{type = Type, mode = Mode} = Info) ->
    #file_info{size = Size, uid = Uid, gid = Gid, links = Links,
               mtime = Seconds, inode = Inode} = Info,
    {Children, Data} = contents(Fs, Names, Type),
    Fields = [hex(path(Names)), string:lowercase(integer_to_list(Mode, 16))
              | [integer_to_list(N) || N <- [Size, Uid, Gid, Links, Seconds, Inode]]],
    {Children, ["entry ", lists:join(" ", Fields ++ [Data])]};
entry(_Fs, Names, {error, Posix}) ->
    {[], ["entry ", hex(path(Names)), " 0 0 0 0 0 0 0 error:", atom_to_list(Posix)]}.

contents(Fs, Names, directory) ->
    case erx_erofs:list_dir(Fs, Names) of
        {ok, List} -> {[Names ++ [Name] || Name <- lists:sort(List)], "-"};
        {error, Posix} -> {[], ["error:", atom_to_list(Posix)]}
    end;
contents(Fs, Names, regular) ->
    case erx_erofs:read_file(Fs, Names) of
        {ok, Bytes} -> {[], ["sha256:", hex(crypto:hash(sha256, Bytes))]};
        {error, Posix} -> {[], ["error:", atom_to_list(Posix)]}
    end;
contents(Fs, Names, symlink) ->
    case erx_erofs:read_link(Fs, Names) of
        {ok, Text} -> {[], ["link:", hex(Text)]};
        {error, Posix} -> {[], ["error:", atom_to_list(Posix)]}
    end.

path([]) -> <<"/">>;
path(Names) -> iolist_to_binary([[<<"/">>, Name] || Name <- Names]).

hex(Binary) -> binary:encode_hex(Binary, lowercase).

line(Line) -> io:put_chars([?PREFIX, Line, $\n]).
