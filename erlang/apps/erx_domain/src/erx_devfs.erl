%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_devfs).
-moduledoc """
`/dev`, the device catalogue as a file tree (docs/design-system.md, "The
/dev tree"): the `erx_fs` callback module the device service serves it
with. erx_devfs_core makes every decision; this module reads the
catalogue, the manifest's services and the facets the system domain holds
for it, and calls the holder's driver-control facet for a ctl write.

* **Two trees.** The read-only tree (`rights => ro`, served by an `ro`
  grant) holds each shown device's directory and its `status` file. The
  control tree (`rights => rw`, served by an `rw` grant) holds the same and
  a `ctl` file in each device's directory, which the read-only tree neither
  walks to, nor opens, nor writes, whatever node it is handed.
* **Who may write ctl.** Whoever holds the control tree's grant: holding
  the path is holding the control, as for every file server
  (docs/design.md, Decisions), so no write is checked against its writer.
  The grant acts for the system domain, whose facet it calls, and asks the
  holder for nothing the system shell could not ask through `erx:cap/1`.
* **Reads.** Each walk and open reads the catalogue anew, since a device's
  holder changes with its domain's restarts; an open of `status` takes its
  text once, and reads see that text until the clunk. Every node is owned
  by uid 0 and has size 0, as a `/proc` file does.
* **Writes.** A write to `ctl` is one command (erx_devfs_core:command/1),
  whatever its offset, acted on within the write: the facet call waits up
  to erx_driver_ctl's own bound, and a call that fails or exits answers
  `eio` and ends nothing here. The write runs in the file's process, so
  writes to one open ctl run one at a time.

In Phase 1 the design's device service is the system domain's domain
service: its supervisor starts the control tree with start_link/0, which
mounts it at `/dev` in the system domain's own namespace, the system
shell's. Nothing mounts the read-only tree yet.
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([start_link/0]).
-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, write/4, make/4, readdir/4,
         statfs/1, clunk/2, read_mode/0]).

%% The tree's name, which a mount's {tree, Name} and attach's Aname name.
-define(TREE, <<"dev">>).
-define(POINT, <<"/dev">>).
%% statfs's type: Linux's DEVFS_SUPER_MAGIC.
-define(DEVFS_SUPER_MAGIC, 16#1373).
-define(DT_DIR, 4).
-define(DT_REG, 8).
-define(GETATTR_VALID, (?ERX_P9_GETATTR_MASK_MODE bor ?ERX_P9_GETATTR_MASK_NLINK
                        bor ?ERX_P9_GETATTR_MASK_UID bor ?ERX_P9_GETATTR_MASK_GID
                        bor ?ERX_P9_GETATTR_MASK_RDEV bor ?ERX_P9_GETATTR_MASK_ATIME
                        bor ?ERX_P9_GETATTR_MASK_MTIME bor ?ERX_P9_GETATTR_MASK_CTIME
                        bor ?ERX_P9_GETATTR_MASK_INO bor ?ERX_P9_GETATTR_MASK_SIZE
                        bor ?ERX_P9_GETATTR_MASK_BLOCKS)).

%% The root, a device's directory, its status file and its ctl file, each device by its
%% catalogue index.
-type node_() :: root | {device, non_neg_integer()} | {status, non_neg_integer()}
               | {ctl, non_neg_integer()}.

-doc """
Starts the control tree and mounts it at `/dev`, after removing any entry
an earlier instance left there; `ignore` where the system domain has no
domain library, and so no catalogue, and where the mount fails.
""".
-spec start_link() -> {ok, pid()} | ignore.
start_link() ->
    case erx_devices:catalogue() of
        {ok, _Devices} -> serve();
        {error, _} -> ignore
    end.

serve() ->
    {ok, Grant} = erx_fs:start_link(?MODULE, #{rights => rw}, rw),
    _ = erx_ns:unmount(?POINT),
    case erx_ns:mount(Grant, ?POINT, [{tree, ?TREE}, rw]) of
        ok ->
            {ok, Grant};
        {error, Reason} ->
            %% A grant the supervisor does not know of must not outlive the start, and
            %% a /dev that cannot be mounted does not stop the domain service's start.
            unlink(Grant),
            exit(Grant, kill),
            logger:warning("/dev not mounted: ~0p", [Reason]),
            ignore
    end.

%% ---------------------------------------------------------------------------
%% The erx_fs callbacks
%% ---------------------------------------------------------------------------

%% Args names the tree's rights, ro or rw; a test also hands in stand-ins for the
%% catalogue, the manifest's services and the system domain's facets.
-doc false.
init(#{rights := Rights} = Args) when Rights =:= ro; Rights =:= rw ->
    {ok, maps:merge(#{catalogue => fun erx_devices:catalogue/0, services => fun services/0,
                      cap => fun erx:cap/1}, Args)}.

-doc false.
root(_Fs) ->
    {ok, ?TREE, root, qid(root)}.

-doc false.
walk(root, Name, Fs) ->
    case erx_devfs_core:find(Name, catalogue(Fs)) of
        {ok, #{index := Index}} -> found({device, Index});
        error -> {error, enoent}
    end;
walk({device, Index}, <<"status">>, _Fs) ->
    found({status, Index});
walk({device, Index}, <<"ctl">>, #{rights := rw}) ->
    found({ctl, Index});
walk({device, _Index}, _Name, _Fs) ->
    {error, enoent};
walk(_File, _Name, _Fs) ->
    {error, enotdir}.

found(Node) ->
    {ok, Node, qid(Node)}.

-doc false.
getattr(Node, _Fs) ->
    {Type, Mode, Nlink} = case Node of
                              root -> {?ERX_P9_S_IFDIR, 8#555, 2};
                              {device, _} -> {?ERX_P9_S_IFDIR, 8#555, 2};
                              {status, _} -> {?ERX_P9_S_IFREG, 8#444, 1};
                              {ctl, _} -> {?ERX_P9_S_IFREG, 8#200, 1}
                          end,
    {ok, #{valid => ?GETATTR_VALID, qid => qid(Node), mode => Type bor Mode,
           uid => 0, gid => 0, nlink => Nlink, rdev => 0, size => 0,
           blksize => 4096, blocks => 0,
           atime_sec => 0, atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0,
           ctime_sec => 0, ctime_nsec => 0, btime_sec => 0, btime_nsec => 0,
           gen => 0, data_version => 0}}.

%% A directory or status opens for reading only, and ctl, in the control tree, for
%% writing only.
-doc false.
open({ctl, Index}, Flags, #{rights := rw}) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        ?ERX_P9_O_WRONLY -> {ok, {ctl, Index}};
        _ -> {error, eacces}
    end;
open({ctl, _Index}, _Flags, _Fs) ->
    {error, erofs};
open(Node, Flags, Fs) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> snapshot(Node, catalogue(Fs), Fs);
        _ -> {error, erofs}
    end.

snapshot(root, Devices, _Fs) ->
    {ok, {entries, entries([{erx_devfs_core:name(Device), {device, Index}}
                            || #{index := Index} = Device <- erx_devfs_core:shown(Devices)])}};
snapshot({device, Index}, Devices, #{rights := Rights}) ->
    case device(Index, Devices) of
        {ok, _Device} -> {ok, {entries, entries(files(Rights, Index))}};
        error -> {error, enoent}
    end;
snapshot({status, Index}, Devices, _Fs) ->
    case device(Index, Devices) of
        {ok, Device} -> {ok, {bytes, erx_devfs_core:status(Device)}};
        error -> {error, enoent}
    end.

%% A device directory's files: ctl only in the control tree.
files(rw, Index) -> [{<<"ctl">>, {ctl, Index}}, {<<"status">>, {status, Index}}];
files(ro, Index) -> [{<<"status">>, {status, Index}}].

entries(Named) ->
    [{qid(Node), Offset, dirent_type(Node), Name} || {Offset, {Name, Node}} <- lists:enumerate(1, Named)].

-doc false.
read({bytes, Bytes}, Offset, _Count, _Fs) when Offset >= byte_size(Bytes) ->
    {ok, <<>>};
read({bytes, Bytes}, Offset, Count, _Fs) ->
    {ok, binary:part(Bytes, Offset, min(Count, byte_size(Bytes) - Offset))};
read({entries, _}, _Offset, _Count, _Fs) ->
    {error, eisdir};
read({ctl, _}, _Offset, _Count, _Fs) ->
    {error, eacces}.

-doc false.
write({ctl, Index}, Offset, Bytes, #{rights := rw} = Fs) ->
    case control(Index, Bytes, Fs) of
        ok -> {ok, byte_size(Bytes), Offset};
        {error, _} = Error -> Error
    end;
write({ctl, _Index}, _Offset, _Bytes, _Fs) ->
    {error, erofs};
write(_Handle, _Offset, _Bytes, _Fs) ->
    {error, ebadf}.

%% prim_file opens every file it writes through a create, so a create of ctl in the
%% control tree opens the existing one for writing, as open/3 does, unless it must make
%% a new file (O_EXCL). The tree makes nothing else.
-doc false.
make({device, Index}, <<"ctl">>, {file, _Mode, Flags}, #{rights := rw} = Fs) ->
    case Flags band ?ERX_P9_O_EXCL of
        0 ->
            case open({ctl, Index}, Flags, Fs) of
                {ok, Handle} -> {ok, {ctl, Index}, qid({ctl, Index}), Handle};
                {error, _} = Error -> Error
            end;
        _ ->
            {error, eexist}
    end;
make(_Dir, _Name, _What, #{rights := rw}) ->
    {error, eacces};
make(_Dir, _Name, _What, _Fs) ->
    {error, erofs}.

%% The command Bytes asks for, acted on through the facet of the device Index's holder.
control(Index, Bytes, Fs) ->
    maybe
        {ok, Operation} ?= erx_devfs_core:command(Bytes),
        {ok, #{unit_name := Unit} = Device} ?= device(Index, catalogue(Fs)),
        {ok, Services} ?= services(Fs),
        {ok, Name} ?= erx_devfs_core:facet(Device, Services),
        {ok, Facet} ?= held(Name, Fs),
        %% The unit's name is the manifest's, which bounds the atoms it makes; the
        %% holder looks it up in its own table of units.
        erx_devfs_core:answer(call(Operation, Facet, binary_to_atom(Unit)))
    else
        {error, _} = Error -> Error;
        error -> {error, enxio}
    end.

%% The facet Name the system domain holds, or enxio before its holder has installed one.
held(Name, #{cap := Cap}) ->
    case Cap(Name) of
        Facet when is_pid(Facet) -> {ok, Facet};
        undefined -> {error, enxio}
    end.

%% A call that exits, at the facet's end or the grantee's timeout, answers as the facet's
%% failure, so a write ends nothing here.
call(Operation, Facet, Unit) ->
    try erx_driver_ctl:Operation(Facet, Unit)
    catch exit:Reason -> {exit, Reason}
    end.

%% An entry's offset is its place in the listing, so a read from Offset
%% continues after the entry that carried it.
-doc false.
readdir({entries, Entries}, Offset, Max, _Fs) ->
    {ok, lists:sublist(Entries, Offset + 1, Max)};
readdir(_Handle, _Offset, _Max, _Fs) ->
    {error, enotdir}.

-doc false.
statfs(_Fs) ->
    {ok, #{type => ?DEVFS_SUPER_MAGIC, bsize => 4096, blocks => 0, bfree => 0, bavail => 0,
           files => 0, ffree => 0, fsid => 0, namelen => 255}}.

-doc false.
clunk(_Handle, _Fs) ->
    ok.

%% A read is a part of the text the open already took.
-doc false.
read_mode() -> immediate.

%% ---------------------------------------------------------------------------
%% The catalogue and the services
%% ---------------------------------------------------------------------------

%% The catalogue, or none where the library answers an error: /dev is then empty.
catalogue(#{catalogue := Catalogue}) ->
    case Catalogue() of
        {ok, Devices} -> Devices;
        {error, _} -> []
    end.

device(Index, Devices) ->
    case [Device || #{index := At} = Device <- erx_devfs_core:shown(Devices), At =:= Index] of
        [Device] -> {ok, Device};
        _None -> error
    end.

services(#{services := Services}) ->
    case Services() of
        {ok, _} = Found -> Found;
        {error, _} -> {error, enxio}
    end.

services() ->
    case erx_domain_lib:configured() of
        {ok, #{services := Services}} -> {ok, Services};
        _NoServices -> {error, enxio}
    end.

%% A qid's path is a 64-bit hash of the node, the same for the node in every grant.
-spec qid(node_()) -> erx_fs:qid().
qid(Node) ->
    Path = (erlang:phash2({erx_devfs, high, Node}, 1 bsl 32) bsl 32)
        bor erlang:phash2({erx_devfs, low, Node}, 1 bsl 32),
    {qid_type(Node), 0, Path}.

qid_type(root) -> ?ERX_P9_QTDIR;
qid_type({device, _}) -> ?ERX_P9_QTDIR;
qid_type(_File) -> 0.

dirent_type(root) -> ?DT_DIR;
dirent_type({device, _}) -> ?DT_DIR;
dirent_type(_File) -> ?DT_REG.
