%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_media_probe).
-moduledoc """
The format of a drive's volume, named by its own bytes (docs/design-drives.md,
"The probe"). format/3 reads a fixed set of the volume's 512-byte sectors through
the function it is handed, the volume's placement, each once, and tries each
format's signature in `fstyp`'s order, the header at the largest offset first. The
first format found **selects** the volume's format; of the other formats the build
writes, those whose signatures are also found are answered as `also`, for the
writable rule. A volume where none is found is `unknown`.

The signatures are abi/formats/probe.txt's rows, EROFS's and F2FS's magic from
their own formats' tables, and FAT's test is the FAT server's boot-sector decoder,
erx_fat_read:boot_sector/1, which also gives the FAT type, so the type has one
source: a FAT12 volume is answered as `fat` with `fat => 12`, for its mount to
refuse by name.

The probe is handed the volume's length in sectors: a sector at or past it is not
read, and the volume lacks the signatures there. A failed read of any sector inside
it, `erange` included, is the probe's one failure, `{error, {read, Reason}}`: a
signature it could not read is not known to be absent, and reading on would select a
later format by mistake.
""".

-include("generated/erx_abi.hrl").

-export([format/3]).
-export_type([name/0, probe/0, read_sector/0]).

-define(SECTOR, 512).

-type name() :: ufs | cd9660 | 'hfs+' | ext2fs | f2fs | erofs | littlefs | apfs | exfat | fat | ntfs.
-type probe() :: #{format := name() | unknown, also := [name()], fat => erx_fat_read:fat_type()}.
-type read_sector() :: fun((non_neg_integer()) -> {ok, binary()} | {error, term()}).
%% A signature: the bytes Bytes at byte Offset of the volume.
-type signature() :: {non_neg_integer(), binary()}.

-doc """
The format of a volume of Length sectors, read through Read, with the formats
Written that the build writes also found on it.
""".
-spec format(read_sector(), non_neg_integer(), [name()]) -> {ok, probe()} | {error, {read, term()}}.
format(Read, Length, Written) when is_integer(Length), Length >= 0 ->
    try
        Sectors = maps:from_list([{Lba, read(Read, Lba, Length)} || Lba <- lists:usort(sectors())]),
        Found = [Name || {Name, Test} <- order(), found(Test, Sectors)],
        {ok, probe(Found, Written, Sectors)}
    catch
        throw:{?MODULE, Reason} -> {error, {read, Reason}}
    end.

%% The probe's order (docs/design-drives.md, "The probe"), each format with its
%% signatures, any one of which names it.
-spec order() -> [{name(), [signature()] | boot_sector}].
order() ->
    [{ufs, [{Superblock + ?ERX_PROBE_UFS_MAGIC_OFFSET, Magic}
            || Superblock <- [?ERX_PROBE_UFS_SUPERBLOCK_UFS2, ?ERX_PROBE_UFS_SUPERBLOCK_UFS1,
                              ?ERX_PROBE_UFS_SUPERBLOCK_FLOPPY, ?ERX_PROBE_UFS_SUPERBLOCK_PIGGY],
               Magic <- [?ERX_PROBE_UFS1_MAGIC_BYTES, ?ERX_PROBE_UFS2_MAGIC_BYTES]]},
     {cd9660, [{?ERX_PROBE_CD9660_OFFSET, ?ERX_PROBE_CD9660_MAGIC_BYTES}]},
     {'hfs+', [{?ERX_PROBE_HFSPLUS_OFFSET, ?ERX_PROBE_HFSPLUS_MAGIC_BYTES},
               {?ERX_PROBE_HFSPLUS_OFFSET, ?ERX_PROBE_HFSX_MAGIC_BYTES}]},
     {ext2fs, [{?ERX_PROBE_EXT2FS_OFFSET, ?ERX_PROBE_EXT2FS_MAGIC_BYTES}]},
     {f2fs, [{?ERX_F2FS_SUPER_OFFSET, <<?ERX_F2FS_MAGIC:32/little>>}]},
     {erofs, [{?ERX_EROFS_SUPER_OFFSET, <<?ERX_EROFS_MAGIC:32/little>>}]},
     {littlefs, [{Block + ?ERX_PROBE_LITTLEFS_OFFSET, ?ERX_PROBE_LITTLEFS_MAGIC_BYTES}
                 || Block <- [0, ?ERX_PROBE_LITTLEFS_BLOCK]]},
     {apfs, [{?ERX_PROBE_APFS_OFFSET, ?ERX_PROBE_APFS_MAGIC_BYTES}]},
     {exfat, [{?ERX_PROBE_EXFAT_OFFSET, ?ERX_PROBE_EXFAT_MAGIC_BYTES}]},
     {fat, boot_sector},
     {ntfs, [{?ERX_PROBE_NTFS_OFFSET, ?ERX_PROBE_NTFS_MAGIC_BYTES}]}].

%% Every sector a signature lies in; no signature crosses a sector's end.
sectors() ->
    [0 | [Offset div ?SECTOR || {_Name, Signatures} <- order(), is_list(Signatures), {Offset, _} <- Signatures]].

read(_Read, Lba, Length) when Lba >= Length ->
    past_the_volume;
read(Read, Lba, _Length) ->
    case Read(Lba) of
        {ok, <<Sector:?SECTOR/binary>>} -> Sector;
        {ok, Other} -> throw({?MODULE, {short, byte_size(Other)}});
        {error, Reason} -> throw({?MODULE, Reason})
    end.

found(boot_sector, #{0 := <<_:?SECTOR/binary>> = Sector}) ->
    erx_fat_read:boot_sector(Sector) =/= not_fat;
found(boot_sector, _Sectors) ->
    false;
found(Signatures, Sectors) ->
    lists:any(fun(Signature) -> holds(Signature, Sectors) end, Signatures).

holds({Offset, Bytes}, Sectors) ->
    Within = Offset rem ?SECTOR,
    Size = byte_size(Bytes),
    case maps:get(Offset div ?SECTOR, Sectors) of
        <<_:Within/binary, Bytes:Size/binary, _/binary>> -> true;
        _ -> false
    end.

probe([], _Written, _Sectors) ->
    #{format => unknown, also => []};
probe([Selected | Others], Written, Sectors) ->
    Probe = #{format => Selected, also => [Name || Name <- Others, lists:member(Name, Written)]},
    case Selected of
        fat ->
            {fat, Type} = erx_fat_read:boot_sector(maps:get(0, Sectors)),
            Probe#{fat => Type};
        _ ->
            Probe
    end.
