%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_media_tree).
-moduledoc """
The media tree (docs/design-drives.md, "The media tree"): the `erx_fs` callback module
of the service `media`, of the media interface (abi/services/media.txt), which every
session the manifest grants it mounts at `/media`. Its tree's name is `media`. The
namespace marks every entry on a facet of that interface nofollow (erx_facets:table/1),
so no link a medium holds is ever followed through it.

* The root lists `diskN` for each drive `{drive, N}` the registry holds at the
  request.
* A walk of `diskN` asks the drive process for its medium (erx_media_drive:medium/1),
  which mounts it, so the listing that follows names every volume: `status`, `ctl`,
  and `sN` for each volume the table serves, whatever its outcome. An MBR's extended
  entry has no volume and shows only in `status`.
* `sN` is volume N's root, reached through its volume process (erx_media_volume),
  which waits for its mount and answers `eio` for a volume that mounted no files. No
  node is ever a link: every attribute is a directory's or a regular file's. Every
  request on a volume's node goes to the process the node names, so an old fid never
  reaches the next medium's files; a read is a waiting request whose keeper is that
  process, and every other operation a call that ends when it answers or ends.
* `status` is status/3's text, made at its open; `ctl` takes `eject`, which answers
  `enotsup` until the finish is built, and anything else `einval`.

Nothing is written: no volume has a write path, so a write of a file and a create,
remove or rename inside a volume answer `erofs`; one of an entry of the root or of a
drive's directory answers `eacces`, and a rename between two volumes `exdev`, decided
from the two nodes before any volume is asked ("Links and rights").

A qid's path is the node's volume's mount number in its high 24 bits and its path
within the volume in its low 40 (erx_media_volume:path/0); the root, each `diskN`,
`status` and `ctl` take fixed paths of mount number 0 (qid/1).
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4, statfs/1, clunk/2,
         write/4, make/4, setattr/3, unlink/4, rename/5]).
-export([status/3]).

-define(TREE, <<"media">>).
%% The access mode of an open that only reads.
-define(READ, 0).

%% A node: the root, a drive's directory, its status or ctl, or a node of volume Pid,
%% the FAT node itself beside its kind and qid path.
-type node_() :: root | {drive | status | ctl, non_neg_integer()}
               | {volume, pid(), erx_fat:fat_node(), dir | file, erx_media_volume:path()}.

%% ---------------------------------------------------------------------------
%% The erx_fs callbacks
%% ---------------------------------------------------------------------------

-doc false.
init(media) ->
    {ok, media}.

-doc false.
root(_Fs) ->
    {ok, ?TREE, root, qid(root)}.

-doc false.
-spec walk(node_(), binary(), media) -> {ok, node_(), erx_fs:qid()} | {error, file:posix()}.
walk(root, Name, _Fs) ->
    case number(<<"disk">>, Name) of
        {ok, N} -> drive_walk(N, medium(N));
        error -> {error, enoent}
    end;
walk({drive, N}, <<"status">>, _Fs) ->
    {ok, {status, N}, qid({status, N})};
walk({drive, N}, <<"ctl">>, _Fs) ->
    {ok, {ctl, N}, qid({ctl, N})};
walk({drive, N}, Name, _Fs) ->
    case lists:keyfind(Name, 1, volumes(N)) of
        {Name, Pid} -> named(Pid, erx_media_volume:root(Pid));
        false -> {error, enoent}
    end;
walk({volume, Pid, Dir, dir, _Path}, Name, _Fs) ->
    named(Pid, erx_media_volume:walk(Pid, Dir, Name));
walk(_File, _Name, _Fs) ->
    {error, enotdir}.

%% The drive's directory, once the walk's ask has mounted its medium, if any.
drive_walk(_N, {error, no_drive}) -> {error, enoent};
drive_walk(_N, {error, eio}) -> {error, eio};
drive_walk(N, _Medium) -> {ok, {drive, N}, qid({drive, N})}.

named(Pid, {ok, Node, Kind, Path}) -> {ok, {volume, Pid, Node, Kind, Path}, qid(Kind, Path)};
named(_Pid, {error, _} = Refused) -> Refused.

-doc false.
getattr(root, _Fs) -> erx_fs_node:attr(qid(root), dir, 8#555);
getattr({drive, N}, _Fs) -> erx_fs_node:attr(qid({drive, N}), dir, 8#555);
getattr({status, N}, _Fs) -> erx_fs_node:attr(qid({status, N}), file, 8#444);
getattr({ctl, N}, _Fs) -> erx_fs_node:attr(qid({ctl, N}), file, 8#200);
getattr({volume, Pid, Node, _Kind, _Path}, _Fs) ->
    case erx_media_volume:attr(Pid, Node) of
        {ok, #{kind := Kind, size := Size, mtime := Mtime}, Path} ->
            {ok, Attr} = erx_fs_node:attr(qid(Kind, Path), Kind, mode(Kind)),
            {ok, Attr#{size := Size, blocks := (Size + 511) div 512, mtime_sec := Mtime, ctime_sec := Mtime}};
        {error, _} = Refused ->
            Refused
    end.

mode(dir) -> 8#555;
mode(file) -> 8#444.

-doc false.
open({ctl, N}, _Flags, _Fs) ->
    {ok, {ctl, N}};
open(Node, Flags, _Fs) when Flags band ?ERX_P9_O_ACCMODE =/= ?READ ->
    {error, refused_write(Node)};
open(root, _Flags, _Fs) ->
    {ok, erx_fs_node:listing([{qid({drive, N}), ?ERX_P9_DT_DIR, name(<<"disk">>, N)} || N <- drives()])};
%% Every volume of the table is listed, by its root's qid, whatever its outcome: one that
%% mounted no files answers `eio` at its walk, and its drive's status shows why. A volume
%% that has ended, or that drew no mount number, has no root's path and is left out.
open({drive, N}, _Flags, _Fs) ->
    Volumes = [{qid(dir, Path), ?ERX_P9_DT_DIR, Name}
               || {Name, Pid} <- volumes(N), {ok, Path} <- [erx_media_volume:root_path(Pid)]],
    {ok, erx_fs_node:listing([{qid({status, N}), ?ERX_P9_DT_REG, <<"status">>},
                              {qid({ctl, N}), ?ERX_P9_DT_REG, <<"ctl">>} | Volumes])};
open({status, N}, _Flags, _Fs) ->
    case medium(N) of
        {ok, #{proxy := Proxy, table := Table}} ->
            {ok, {text, status(erx_media_medium:window(Proxy, info), Table, fun outcome/1)}};
        {error, eio} = Ended ->
            Ended;
        {error, _NoMedium} ->
            {ok, {text, status(none, none, fun outcome/1)}}
    end;
open({volume, Pid, Dir, dir, _Path}, _Flags, _Fs) ->
    case erx_media_volume:list(Pid, Dir) of
        {ok, Entries} ->
            {ok, erx_fs_node:listing([{qid(Kind, Path), dirent_type(Kind), Name} || {Name, Kind, Path} <- Entries])};
        {error, _} = Refused ->
            Refused
    end;
open({volume, Pid, File, file, _Path}, _Flags, _Fs) ->
    {ok, {file, Pid, File}}.

dirent_type(dir) -> ?ERX_P9_DT_DIR;
dirent_type(file) -> ?ERX_P9_DT_REG.

-doc false.
read({text, Text}, Offset, Count, _Fs) ->
    {ok, binary:part(Text, min(Offset, byte_size(Text)), min(Count, max(byte_size(Text) - Offset, 0)))};
read({file, Pid, File}, Offset, Count, _Fs) ->
    {wait, Pid, {read, File, Offset, Count}};
read({ctl, _N}, _Offset, _Count, _Fs) ->
    {ok, <<>>};
read({entries, _}, _Offset, _Count, _Fs) ->
    {error, eisdir}.

-doc false.
readdir(Handle, Offset, Max, _Fs) ->
    erx_fs_node:readdir(Handle, Offset, Max).

%% `eject`, compared as bytes, its trailing newline optional ("Commands").
-doc false.
write({ctl, _N}, _Offset, Command, _Fs) when Command =:= <<"eject">>; Command =:= <<"eject\n">> ->
    {error, enotsup};
write({ctl, _N}, _Offset, _Command, _Fs) ->
    {error, einval};
write(_Handle, _Offset, _Bytes, _Fs) ->
    {error, erofs}.

%% A create of status or ctl opens it, as prim_file opens every file it writes
%% (erx_fs_node:open_by_create/4), so `echo eject > ctl` reaches ctl's command.
-doc false.
make({drive, N}, Name, {file, _Mode, Flags}, Fs) when Name =:= <<"status">>; Name =:= <<"ctl">> ->
    {ok, Node, Qid} = walk({drive, N}, Name, Fs),
    erx_fs_node:open_by_create(Node, Qid, Flags, fun(Opened) -> open(Node, Opened, Fs) end);
make(Dir, _Name, _What, _Fs) -> {error, refused_write(Dir)}.

%% A change of attributes, a truncate among them, as any other change.
-doc false.
setattr({node, Node}, _Changes, _Fs) -> {error, refused_write(Node)};
setattr({open, {file, _Pid, _File}}, _Changes, _Fs) -> {error, erofs};
setattr({open, _TreeHandle}, _Changes, _Fs) -> {error, eacces}.

-doc false.
unlink(Dir, _Name, _Kind, _Fs) -> {error, refused_write(Dir)}.

-doc false.
rename({volume, From, _, _, _}, _Name, {volume, To, _, _, _}, _NewName, _Fs) when From =/= To ->
    {error, exdev};
rename(Dir, _Name, NewDir, _NewName, _Fs) ->
    case {refused_write(Dir), refused_write(NewDir)} of
        {erofs, erofs} -> {error, erofs};
        _OfTheTree -> {error, eacces}
    end.

%% A change inside a volume, which has no write path, or of the tree's own entries.
refused_write({volume, _, _, _, _}) -> erofs;
refused_write(_TreeNode) -> eacces.

-doc false.
statfs(_Fs) ->
    erx_fs_node:statfs(?ERX_P9_MAGIC_MEDIA).

-doc false.
clunk(_Handle, _Fs) ->
    ok.

%% ---------------------------------------------------------------------------
%% Status
%% ---------------------------------------------------------------------------

outcome(Pid) ->
    try erx_media_volume:outcome(Pid) catch exit:_Ended -> #{format => unknown, mount => {none, {failed, ended}}} end.

-doc """
The text of a drive's `status` ("Status"): one attribute a line, `NAME <tab> VALUE`,
each value through the field escape (erx_text:escape_field/1), for the window's answer
to `info` and the table the medium's reader answered, or none for no medium, with
each served volume's outcome from Outcome. The window does not say its transport or
whether it flushes, so both are `unknown`.
""".
-spec status(term(), erx_media_medium:table() | none, fun((pid()) -> erx_media_volume:outcome())) -> binary().
status(_Info, none, _Outcome) ->
    lines([{medium, none}]);
status(Info, Table, Outcome) ->
    lines([{medium, medium_line(Table)}, {transport, unknown}, {sectors, sectors(Info)}, {flush, unknown}
           | table(Table, Outcome)]).

medium_line({refused, _Finding}) -> [idle, table];
medium_line({failed, Why}) -> [idle, failed, Why];
medium_line({_Scheme, _Volumes, _Unserved}) -> ready.

sectors({ok, #{sectors := Sectors}}) when is_integer(Sectors) -> Sectors;
sectors(_Info) -> unknown.

table({refused, Finding}, _Outcome) ->
    [{table, [refused, Finding]}];
table({failed, _Why}, _Outcome) ->
    [];
table({Scheme, Volumes, Unserved}, Outcome) ->
    [{table, Scheme} | lists:append([volume(Volume, Outcome) || Volume <- Volumes])] ++ [{unserved, Unserved}].

volume({#{number := Number}, extended}, _Outcome) ->
    [{field(Number, <<>>), extended}, {field(Number, <<"_mount">>), [none, extended]}];
volume({#{number := Number, length := Length}, Pid}, Outcome) ->
    #{format := Format, mount := Mount} = Shown = Outcome(Pid),
    Fields = [{<<>>, Format}, {<<"_mount">>, mount(Mount)}]
             ++ [{<<"_ro_reason">>, Reason} || Reason <- [erx_media_volume:ro_reason(Shown)], Reason =/= none]
             ++ [{<<"_sectors">>, Length}]
             ++ [{<<"_", (atom_to_binary(Key))/binary>>, maps:get(Key, Shown)}
                 || Key <- [fat, label, serial], maps:get(Key, Shown, none) =/= none],
    [{field(Number, Suffix), Value} || {Suffix, Value} <- Fields].

%% A read-only mount's reason is its own line, `sN_ro_reason`, from
%% erx_media_volume:ro_reason/1, the line the volume logs at its mount.
mount(rw) -> rw;
mount({ro, _Reason}) -> ro;
mount({none, {Reason, Why}}) -> [none, Reason, Why];
mount({none, Reason}) -> [none, Reason].

field(Number, Suffix) -> <<"s", (integer_to_binary(Number))/binary, Suffix/binary>>.

lines(Attributes) ->
    iolist_to_binary([[key(Name), $\t, erx_text:escape_field(iolist_to_binary(text(Value))), $\n]
                      || {Name, Value} <- Attributes]).

key(Name) when is_atom(Name) -> atom_to_binary(Name);
key(Name) when is_binary(Name) -> Name.

%% A value as its words, space-separated: atoms and numbers as written, a medium's
%% bytes as they are, and any other term as Erlang writes it.
text(Words) when is_list(Words) -> lists:join($\s, [text(Word) || Word <- Words]);
text(Word) when is_atom(Word) -> atom_to_binary(Word);
text(Word) when is_integer(Word) -> integer_to_binary(Word);
text(Word) when is_binary(Word) -> Word;
text(Word) -> io_lib:format("~0p", [Word]).

%% ---------------------------------------------------------------------------
%% Names and qids
%% ---------------------------------------------------------------------------

%% The drives the registry holds, in number order.
drives() ->
    lists:sort([N || {drive, N} <- maps:keys(erx:caps()), is_integer(N), N >= 0]).

%% The served volumes of drive N's medium, mounted by this ask: each `sN` with its pid.
volumes(N) ->
    case medium(N) of
        {ok, #{table := {_Scheme, Volumes, _Unserved}}} ->
            [{name(<<"s">>, Number), Pid} || {#{number := Number}, Pid} <- Volumes, is_pid(Pid)];
        _NoVolumes ->
            []
    end.

name(Prefix, N) -> <<Prefix/binary, (integer_to_binary(N))/binary>>.

%% Drive N's medium as its drive process answers it (erx_media_drive:medium/1), or eio
%% for a drive process that ended during the ask, so its end costs the session one
%% answer and not its grant.
medium(N) ->
    try erx_media_drive:medium(N) catch exit:_Ended -> {error, eio} end.

%% The number a name of Prefix followed by a decimal number, written as
%% integer_to_binary/1 writes it, names.
number(Prefix, Name) ->
    Size = byte_size(Prefix),
    case Name of
        <<Prefix:Size/binary, Digits/binary>> when Digits =/= <<>> ->
            case lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Digits)) of
                true -> canonical(binary_to_integer(Digits), Digits);
                false -> error
            end;
        _Other ->
            error
    end.

canonical(N, Digits) ->
    case integer_to_binary(N) of
        Digits -> {ok, N};
        _Padded -> error
    end.

%% The tree's own nodes' qids, of mount number 0: the root's path 0, and drive N's
%% directory, status and ctl 4N + 1, 2 and 3.
-spec qid(root | {drive | status | ctl, non_neg_integer()}) -> erx_fs:qid().
qid(root) -> qid(dir, 0);
qid({drive, N}) -> qid(dir, 4 * N + 1);
qid({status, N}) -> qid(file, 4 * N + 2);
qid({ctl, N}) -> qid(file, 4 * N + 3).

qid(dir, Path) -> {?ERX_P9_QTDIR, 0, Path};
qid(file, Path) -> {0, 0, Path}.
