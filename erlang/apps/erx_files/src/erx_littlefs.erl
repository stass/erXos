%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_littlefs).
-moduledoc """
littlefs as a NIF (otp/erts/emulator/nifs/erxos/erx_littlefs_nif.c), the stopgap read-write file system of
docs/design-stopgap.md#littlefs-in-the-system-domain. `erx_lfs` is its one
user: the volume's worker alone calls the operations, each on a dirty I/O
scheduler; the owner alone calls `complete/2` and `payload/1`, which are
normal NIFs, as it serves the block requests the operations post to it.

Paths are binaries from the volume's root, `<<"/">>` and `<<"/a/b">>`.
Open flags are littlefs's `LFS_O_` bits, which `erx_lfs` builds.
""".

-export([new/3, complete/2, payload/1]).
-export([format/1, mount/1, stat/2, readdir/4, open/3, read/4, write/4,
         truncate/3, size/2, sync/2, close/2, mkdir/2, remove/2, rename/3,
         fsstat/1]).

-nifs([new/3, complete/2, payload/1, format/1, mount/1, stat/2, readdir/4,
       open/3, read/4, write/4, truncate/3, size/2, sync/2, close/2, mkdir/2,
       remove/2, rename/3, fsstat/1]).

-on_load(load/0).

-type vol() :: reference().
-type req() :: reference().
-type slot() :: non_neg_integer().
-type kind() :: file | directory.
-export_type([vol/0, req/0, slot/0, kind/0]).

load() ->
    erlang:load_nif(atom_to_list(?MODULE), 0).

-define(NIF, erlang:nif_error(not_loaded)).

-doc "A volume of `Blocks` 4 KiB blocks whose block requests go to `Owner`.".
-spec new(pid(), pos_integer(), pos_integer()) -> vol().
new(_Owner, _Blocks, _DeadlineMs) -> ?NIF.

-doc "The owner's answer to a block request: `late` after its deadline.".
-spec complete(req(), ok | {ok, binary()} | error) -> ok | late.
complete(_Req, _Answer) -> ?NIF.

-doc "A write request's bytes.".
-spec payload(req()) -> binary().
payload(_Req) -> ?NIF.

-spec format(vol()) -> ok | {error, atom()}.
format(_Vol) -> ?NIF.
-doc "Mounts; `{error, eintegrity}` when the blocks hold no volume.".
-spec mount(vol()) -> ok | {error, atom()}.
mount(_Vol) -> ?NIF.
-spec stat(vol(), binary()) -> {ok, kind(), non_neg_integer()} | {error, atom()}.
stat(_Vol, _Path) -> ?NIF.
-doc "At most `Max` entries of a directory after its first `Skip`.".
-spec readdir(vol(), binary(), non_neg_integer(), 1..256) ->
          {ok, [{binary(), kind(), non_neg_integer()}]} | {error, atom()}.
readdir(_Vol, _Path, _Skip, _Max) -> ?NIF.
-spec open(vol(), binary(), non_neg_integer()) -> {ok, slot()} | {error, atom()}.
open(_Vol, _Path, _Flags) -> ?NIF.
-spec read(vol(), slot(), non_neg_integer(), 1..65536) -> {ok, binary()} | {error, atom()}.
read(_Vol, _Slot, _Offset, _Count) -> ?NIF.
-spec write(vol(), slot(), non_neg_integer(), binary()) ->
          {ok, non_neg_integer(), non_neg_integer()} | {error, atom()}.
write(_Vol, _Slot, _Offset, _Data) -> ?NIF.
-spec truncate(vol(), slot(), non_neg_integer()) -> ok | {error, atom()}.
truncate(_Vol, _Slot, _Size) -> ?NIF.
-spec size(vol(), slot()) -> {ok, non_neg_integer()} | {error, atom()}.
size(_Vol, _Slot) -> ?NIF.
-doc "The file's data and metadata to the medium, then a flush.".
-spec sync(vol(), slot()) -> ok | {error, atom()}.
sync(_Vol, _Slot) -> ?NIF.
-spec close(vol(), slot()) -> ok | {error, atom()}.
close(_Vol, _Slot) -> ?NIF.
-spec mkdir(vol(), binary()) -> ok | {error, atom()}.
mkdir(_Vol, _Path) -> ?NIF.
-spec remove(vol(), binary()) -> ok | {error, atom()}.
remove(_Vol, _Path) -> ?NIF.
-spec rename(vol(), binary(), binary()) -> ok | {error, atom()}.
rename(_Vol, _From, _To) -> ?NIF.
-doc "`{ok, BlockSize, Blocks, BlocksUsed}`.".
-spec fsstat(vol()) -> {ok, pos_integer(), pos_integer(), non_neg_integer()} | {error, atom()}.
fsstat(_Vol) -> ?NIF.
