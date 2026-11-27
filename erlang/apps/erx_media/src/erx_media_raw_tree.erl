%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_media_raw_tree).
-moduledoc """
The raw tree (docs/design-drives.md, "Raw sectors"): the `erx_fs` callback module of
the service `media_raw`, of the media interface, which a session the manifest grants it
mounts at `/media/raw`. Its tree's name is `media_raw`; a grant reaches one tree, so no
`media` grant reaches a sector and a `media_raw` grant reaches nothing but sectors.

* The root lists `diskN` for each drive `{drive, N}` the registry holds at the request.
* A walk of `diskN` asks the drive process for its medium, as the media tree's does, so
  the listing that follows names every raw file: `data`, the medium whole, while the
  drive holds a medium whose sectors are served, and `sN.data` for each volume its table
  lists but an extended entry, served or not. A medium whose table is refused, or whose
  whole is held by a writer of `data`, lists `data` alone.
* Every open of a raw file goes to the medium's raw process (erx_media_raw), which the
  drive process starts at the first: a reading open is answered at once, a writing open
  takes the file's volumes out of service. Reads and writes are its waiting requests,
  fsync its window's flush, and a clunk of a writing open its close. A request through
  an old fid of an ended medium reaches a raw process that has ended and answers `eio`.

A raw file's size is its sectors times 512. qid paths are fixed: the root 0, drive N's
directory `(N + 1) bsl 16`, its `data` one above that and `sV.data` V + 1 above.
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4, statfs/1, clunk/2,
         write/4, make/4, setattr/3, unlink/4, rename/5, fsync/2]).

-define(TREE, <<"media_raw">>).
-define(READ, 0).

%% A node: the root, a drive's directory, or one of its raw files.
-type node_() :: root | {drive, non_neg_integer()} | {file, non_neg_integer(), erx_media_raw:file()}.

-doc false.
init(media_raw) -> {ok, media_raw}.

-doc false.
root(_Fs) -> {ok, ?TREE, root, qid(root)}.

-doc false.
-spec walk(node_(), binary(), media_raw) -> {ok, node_(), erx_fs:qid()} | {error, file:posix()}.
walk(root, <<"disk", Digits/binary>>, _Fs) ->
    case number(Digits) of
        {ok, N} -> drive_walk(N, medium(N));
        error -> {error, enoent}
    end;
walk({drive, N}, Name, _Fs) ->
    case lists:member(file(Name), files(N)) of
        true -> Node = {file, N, file(Name)}, {ok, Node, qid(Node)};
        false -> {error, enoent}
    end;
walk(_Node, _Name, _Fs) ->
    {error, enoent}.

%% The drive's directory, once the walk's ask has mounted its medium, if any.
drive_walk(_N, {error, no_drive}) -> {error, enoent};
drive_walk(_N, {error, eio}) -> {error, eio};
drive_walk(N, _Medium) -> {ok, {drive, N}, qid({drive, N})}.

-doc false.
getattr(root, _Fs) -> erx_fs_node:attr(qid(root), dir, 8#555);
getattr({drive, N}, _Fs) -> erx_fs_node:attr(qid({drive, N}), dir, 8#555);
getattr({file, N, File} = Node, _Fs) ->
    case sectors(N, File) of
        {ok, Sectors} ->
            {ok, Attr} = erx_fs_node:attr(qid(Node), file, 8#600),
            {ok, Attr#{size := Sectors * 512, blocks := Sectors}};
        {error, _} = Refused ->
            Refused
    end.

-doc false.
open(root, Flags, _Fs) when Flags band ?ERX_P9_O_ACCMODE =:= ?READ ->
    {ok, erx_fs_node:listing([{qid({drive, N}), ?ERX_P9_DT_DIR, <<"disk", (integer_to_binary(N))/binary>>}
                              || N <- drives()])};
open({drive, N}, Flags, _Fs) when Flags band ?ERX_P9_O_ACCMODE =:= ?READ ->
    {ok, erx_fs_node:listing([{qid({file, N, File}), ?ERX_P9_DT_REG, name(File)} || File <- files(N)])};
open({file, N, File}, Flags, _Fs) ->
    Mode = case Flags band ?ERX_P9_O_ACCMODE of ?READ -> read; _ -> write end,
    case raw(N) of
        {ok, Raw} -> opened(erx_media_raw:open(Raw, File, Mode), Raw, File, Flags);
        {error, _} = Refused -> Refused
    end;
open(_Dir, _Flags, _Fs) ->
    {error, eisdir}.

%% An open raw file: its raw process, its file, the open's name (a reference for a
%% writing open, which its clunk closes) and what the open allows.
opened({ok, Open}, Raw, File, Flags) ->
    Access = Flags band ?ERX_P9_O_ACCMODE,
    {ok, {raw, Raw, File, Open, #{read => Access =/= ?ERX_P9_O_WRONLY, write => Access =/= ?READ}}};
opened({error, _} = Refused, _Raw, _File, _Flags) ->
    Refused.

-doc false.
read({raw, Raw, File, _Open, #{read := true}}, Offset, Count, _Fs) ->
    {wait, Raw, {read, File, Offset, Count}};
read({raw, _Raw, _File, _Open, #{read := false}}, _Offset, _Count, _Fs) ->
    {error, ebadf};
read(_Listing, _Offset, _Count, _Fs) ->
    {error, eisdir}.

-doc false.
write({raw, Raw, File, _Open, #{write := true}}, Offset, Bytes, _Fs) ->
    {wait, Raw, {write, File, Offset, Bytes}};
write(_Handle, _Offset, _Bytes, _Fs) ->
    {error, ebadf}.

-doc false.
readdir(Handle, Offset, Max, _Fs) -> erx_fs_node:readdir(Handle, Offset, Max).

-doc false.
fsync({raw, Raw, _File, _Open, _Access}, _Fs) -> erx_media_raw:fsync(Raw);
fsync(_Handle, _Fs) -> ok.

-doc false.
clunk({raw, Raw, _File, Open, _Access}, _Fs) when is_reference(Open) -> erx_media_raw:close(Raw, Open);
clunk(_Handle, _Fs) -> ok.

-doc false.
statfs(_Fs) -> erx_fs_node:statfs(?ERX_P9_MAGIC_MEDIA).

%% The raw tree's names are fixed: nothing is made, changed, removed or renamed.
-doc false.
%% A create of a raw file that exists opens it, as O_CREAT does on FreeBSD and as
%% prim_file opens every file it writes, so `dd of=` and a writing open reach the
%% sectors; O_EXCL refuses it, and no new name is made.
make({drive, N}, Name, {file, _Mode, Flags}, Fs) ->
    case walk({drive, N}, Name, Fs) of
        {ok, Node, Qid} -> erx_fs_node:open_by_create(Node, Qid, Flags, fun(Opened) -> open(Node, Opened, Fs) end);
        {error, enoent} -> {error, eacces}
    end;
make(_Dir, _Name, _What, _Fs) -> {error, eacces}.
-doc false.
setattr(_Target, _Changes, _Fs) -> {error, eacces}.
-doc false.
unlink(_Dir, _Name, _Kind, _Fs) -> {error, eacces}.
-doc false.
rename(_Dir, _Name, _NewDir, _NewName, _Fs) -> {error, eacces}.

%% ---------------------------------------------------------------------------
%% The drives' raw files
%% ---------------------------------------------------------------------------

drives() ->
    lists:sort([N || {drive, N} <- maps:keys(erx:caps()), is_integer(N), N >= 0]).

%% Drive N's raw files, from its medium as the drive process answers it.
files(N) ->
    case medium(N) of
        {ok, #{table := {_Scheme, Volumes, _Unserved}}} ->
            [data | [Number || {#{number := Number}, Pid} <- Volumes, Pid =/= extended]];
        {ok, #{table := Table}} when Table =:= raw; element(1, Table) =:= refused ->
            [data];
        _None ->
            []
    end.

%% A raw file's length in sectors: the window's capacity for data, the table's entry
%% for a volume.
sectors(N, data) ->
    case medium(N) of
        {ok, #{proxy := Proxy}} ->
            case erx_media_medium:window(Proxy, info) of
                {ok, #{sectors := Sectors}} when is_integer(Sectors) -> {ok, Sectors};
                _Failed -> {error, eio}
            end;
        _None -> {error, eio}
    end;
sectors(N, Number) ->
    case medium(N) of
        {ok, #{table := {_Scheme, Volumes, _Unserved}}} ->
            case [Length || {#{number := V, length := Length}, _Pid} <- Volumes, V =:= Number] of
                [Length] -> {ok, Length};
                [] -> {error, eio}
            end;
        _Other -> {error, eio}
    end.

medium(N) ->
    try erx_media_drive:medium(N) catch exit:_Ended -> {error, eio} end.

raw(N) ->
    try erx_media_drive:raw(N) catch exit:_Ended -> {error, eio} end.

%% `data` or `sN.data`, by name; any other name is none.
file(<<"data">>) -> data;
file(<<"s", Rest/binary>>) ->
    case binary:split(Rest, <<".data">>) of
        [Digits, <<>>] -> case number(Digits) of {ok, V} when V > 0 -> V; _ -> none end;
        _ -> none
    end;
file(_Name) -> none.

name(data) -> <<"data">>;
name(V) -> <<"s", (integer_to_binary(V))/binary, ".data">>.

%% A decimal number as integer_to_binary/1 writes it.
number(Digits) when Digits =/= <<>> ->
    case lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Digits)) of
        true ->
            N = binary_to_integer(Digits),
            case integer_to_binary(N) of Digits -> {ok, N}; _ -> error end;
        false -> error
    end;
number(_Empty) ->
    error.

qid(root) -> {?ERX_P9_QTDIR, 0, 0};
qid({drive, N}) -> {?ERX_P9_QTDIR, 0, (N + 1) bsl 16};
qid({file, N, data}) -> {0, 0, ((N + 1) bsl 16) + 1};
qid({file, N, V}) -> {0, 0, ((N + 1) bsl 16) + V + 1}.
