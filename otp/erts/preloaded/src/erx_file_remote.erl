%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% prim_file's operations on a path below a file server's grant (design-files.md, Erlang
%% clients). prim_file's NIF answers such a path with its mount entry's grant, {Pid, Tree,
%% Rights}, and its place, {Point, Root, Names, Top}: the entry's point in the namespace,
%% the entry's root in the tree, the path's names from the tree's root, the entry's root
%% included, and whether the path is the entry's point itself, the top of a mount or of
%% a bind, as the namespace decides it. prim_file calls the operation here, in the calling process, with the path as
%% the caller wrote it. Rights are the entry's, so a read-only bind of a writable grant
%% arrives read-only, and a request that writes is refused with erofs here, before
%% anything is sent.
%%
%% Each path operation attaches a fid of its own, walks from it into new fids, acts on the
%% fid the walks reached and clunks every fid it made, all sent together. A request names
%% only a walk's new fid, which exists only if the walk passed every name, so after a walk
%% that stops early the request fails with ebadf and changes nothing, and the answer is the
%% walk's. Every fid is drawn from prim_file:erx_fid/0 and owned by the calling process, so
%% the grant clunks it if the process ends first.
%%
%% A walk that stops at a symbolic link, or ends on one the operation follows, sends the
%% client through the link (design-files.md, Resolving a path): it reads the link, puts its
%% text in place of the names up to the link, a relative text joined to the link's
%% directory as a namespace path, and resolves the result again through prim_file's NIF,
%% so a link leads only where the caller's own namespace leads, with the rights of the
%% entry it reaches. At most 40 links are followed for one operation. A path written with
%% a trailing "/" names a directory: its last name is followed, and a last name that is
%% not a directory answers enotdir, as Linux's path resolution answers.
%%
%% The answers are stock prim_file's on a Unix host, by design-files.md's error steps, and
%% the results have the shapes prim_file's NIF returns for a local path (a #file_info{}
%% with POSIX times, raw names), so prim_file converts both alike.
%%
%% An open file is OTP's #file_descriptor{} with this module as its module, so file
%% dispatches its operations here. Its data holds the grant, the fid it owns, the
%% opening process, which alone may use it, and an atomics array holding the offset and
%% whether the file is closed. Each read or write is one request of at most 64 KiB, and
%% a write's reply sets the offset by the rule of design-files.md's Open files and
%% offsets (offset_after/4).
%%
%% Every request passes exchange/2, which checks it against the generated protocol
%% grammar, erx_9p_grammar, and sends nothing that writes through rights other than rw;
%% the grammar holds each reply to its request. A server's reply is untrusted: a reply of
%% any other shape answers eio and raises nothing in the caller, which may be the code
%% server.
%%
%% This module and the grammar are preloaded and call only BIFs and preloaded modules
%% (T6 of design-tmp.md), which test/host/erx_file_remote_test.rb checks with xref.
%%
%% Not yet done here (TODO.md): a listing's entries for the mount points below a
%% directory.

-module(erx_file_remote).

-export([read_file_info/4, read_link/3, list_dir/3, write_file_info/4, make_dir/3,
         del_dir/3, delete/3, rename/5, make_link/5, make_symlink/4]).
-export([open/4, read_file/3, set_cwd/3]).
%% An open file's operations, which file dispatches to by its descriptor's module.
-export([close/1, read/2, read_line/1, pread/2, pread/3, write/2, pwrite/2, pwrite/3,
         position/2, truncate/1, sync/1, datasync/1, advise/4, allocate/3,
         read_handle_info/2, copy/3, sendfile/8, ipread_s32bu_p32bu/3]).
-export([last_name/1, names/1]).

-include("file.hrl").
-include("generated/erx_abi.hrl").

-type grant() :: {pid(), Tree :: binary(), Rights :: ro | rw | rx}.
%% A path's names from the tree's root, joined by "/": <<>> is the root.
-type names() :: binary().
%% Where a path lies on its grant: the entry maps the namespace path Point to the tree's
%% names Root, and Names begins with Root. Top is the namespace's own answer to whether
%% the path is Point itself, which rename, del_dir and delete take from here and not
%% from the names: a bind's top has its root's names.
-type place() :: {Point :: binary(), Root :: names(), Names :: names(), Top :: boolean()}.
%% A path as the caller wrote it, encoded as prim_file encodes it for its NIF, NUL-terminated.
-type path() :: binary().
%% A path's text: a path() without its NUL.
-type text() :: binary().
-type posix() :: atom().
%% How a walk treats a symbolic link as its last name: follow it, act on the link itself,
%% or follow it and require a directory, for a path written with a trailing "/".
-type mode() :: follow | nofollow | directory.
%% A walk of the Which'th path of an operation met a link at its At'th name, from 0.
-type link() :: {link, Which :: 1 | 2, At :: non_neg_integer()}.

%% The domain's umask, which a host's kernel would take off stock's modes.
-define(UMASK, 8#022).
-define(PERMISSION_BITS, 8#6777).
-define(INFO_MASK, (?ERX_P9_GETATTR_MASK_MODE bor ?ERX_P9_GETATTR_MASK_NLINK
                    bor ?ERX_P9_GETATTR_MASK_UID bor ?ERX_P9_GETATTR_MASK_GID
                    bor ?ERX_P9_GETATTR_MASK_RDEV bor ?ERX_P9_GETATTR_MASK_ATIME
                    bor ?ERX_P9_GETATTR_MASK_MTIME bor ?ERX_P9_GETATTR_MASK_CTIME
                    bor ?ERX_P9_GETATTR_MASK_INO bor ?ERX_P9_GETATTR_MASK_SIZE
                    bor ?ERX_P9_GETATTR_MASK_BLOCKS bor ?ERX_P9_GETATTR_MASK_DATA_VERSION)).
%% One listing page's count, and the most entries a listing takes before it answers eio,
%% so a server that never ends a listing cannot fill the caller's heap.
-define(READDIR_COUNT, 8192).
-define(LISTING_MAX, 1048576).
%% The most links one operation follows, Linux's MAXSYMLINKS; the next answers eloop.
-define(LINKS_MAX, 40).
%% An open file's cells: its offset, and 1 once it is closed.
-define(OFFSET, 1).
-define(CLOSED, 2).
-define(CELLS, 2).
%% The largest offset, a file's size included, as off_t holds it.
-define(OFFSET_MAX, 16#7fffffffffffffff).
-define(U64_MAX, 16#ffffffffffffffff).
%% Stock prim_file's read-ahead for a bare read_ahead option, and the least one read of
%% read_line asks for.
-define(READ_AHEAD, 65536).
-define(LINE_READ, 256).
%% The most one read answers, as Linux's read(2) caps a count at MAX_RW_COUNT.
-define(READ_MAX, 16#7ffff000).

%% Reading -----------------------------------------------------------------

%% read_file_info (FollowLinks 1) and read_link_info (0): the #file_info{} of a stat, its
%% times POSIX seconds, for prim_file to convert. A link's own record carries the access
%% of the file it leads to, as stock's access(2) follows links.
-spec read_file_info(grant(), place(), 0 | 1, path()) -> #file_info{} | {error, posix()}.
read_file_info(Grant, Place, FollowLinks, Path) ->
    one(Grant, Place, Path,
        fun(OnGrant, NameList, Text) ->
                Mode = case {FollowLinks, slashed(Text)} of
                           {_, true} -> directory;
                           {1, false} -> follow;
                           {_, false} -> nofollow
                       end,
                case {act(OnGrant, [{NameList, Mode}], fun([Fid]) -> {getattr, Fid, ?INFO_MASK} end), Mode} of
                    {{ok, Attr}, nofollow} -> with_access(file_info(OnGrant, Attr), Text);
                    {{ok, Attr}, _} -> followed_info(file_info(OnGrant, Attr));
                    {Other, _} -> Other
                end
        end,
        fun(Text) ->
                Options = [{time, posix}],
                Local = case FollowLinks of
                            1 -> prim_file:read_file_info(Text, Options);
                            _ -> prim_file:read_link_info(Text, Options)
                        end,
                case Local of
                    {ok, Info} -> Info;
                    {error, _} = Error -> Error
                end
        end).

%% A walk that followed every link ends on a file that is not one; a server that says
%% otherwise answers eio, so with_access/2 never meets a link it would follow again.
followed_info(#file_info{type = symlink}) -> {error, eio};
followed_info(Info) -> Info.

with_access(#file_info{type = symlink} = Info, Text) ->
    Access = case prim_file:read_file_info(Text) of
                 {ok, #file_info{type = symlink}} -> none;
                 {ok, #file_info{access = Followed}} -> Followed;
                 {error, _} -> none
             end,
    Info#file_info{access = Access};
with_access(Info, _) ->
    Info.

%% A path written with a trailing "/" names a directory, which is not a link: einval, as
%% readlink answers for any file that is not a link, once the path reaches a directory.
-spec read_link(grant(), place(), path()) -> {ok, binary()} | {error, posix()}.
read_link(Grant, Place, Path) ->
    one(Grant, Place, Path,
        fun(OnGrant, NameList, Text) ->
                case slashed(Text) of
                    false ->
                        act(OnGrant, [{NameList, nofollow}], fun([Fid]) -> {readlink, Fid} end);
                    true ->
                        case act(OnGrant, [{NameList, directory}],
                                 fun([Fid]) -> {getattr, Fid, ?INFO_MASK} end) of
                            {ok, _} -> {error, einval};
                            Other -> Other
                        end
                end
        end,
        fun(Text) ->
                case prim_file:read_link_all(Text) of
                    {ok, Name} -> {ok, raw(Name)};
                    {error, _} = Error -> Error
                end
        end).

%% The names of a directory's entries, "." and ".." left out, as raw names.
-spec list_dir(grant(), place(), path()) -> {ok, [binary()]} | {error, posix()}.
list_dir(Grant, Place, Path) ->
    one(Grant, Place, Path,
        fun(OnGrant, NameList, Text) ->
                session(OnGrant, [{NameList, followed(Text)}],
                        fun([Fid]) -> [{lopen, Fid, 0}] end,
                        fun([Fid], [{ok, _Qid, _Iounit}]) -> listing(OnGrant, Fid, 0, 0, []);
                           (_, [{error, _} = Error]) -> Error
                        end)
        end,
        fun(Text) ->
                case prim_file:list_dir_all(Text) of
                    {ok, Names} -> {ok, [raw(Name) || Name <- Names]};
                    {error, _} = Error -> Error
                end
        end).

%% A page at a time, each from the offset the last entry of the one before gave, until
%% an empty page.
listing(_, _, _, Count, _) when Count > ?LISTING_MAX ->
    {error, eio};
listing(Grant, Fid, Offset, Count, Pages) ->
    case exchange(Grant, [{readdir, Fid, Offset, ?READDIR_COUNT}]) of
        [{ok, []}] ->
            {ok, [Name || Page <- lists:reverse(Pages, []), Name <- Page]};
        [{ok, Entries}] ->
            {_, Next, _, _} = last(Entries),
            Page = [Name || {_, _, _, Name} <- Entries, Name =/= <<".">>, Name =/= <<"..">>],
            listing(Grant, Fid, Next, Count + length(Entries), [Page | Pages]);
        [{error, _} = Error] ->
            Error
    end.

%% Changing ----------------------------------------------------------------

%% Stock's write_file_info_1 in its order: the owner if either id is given, then the mode,
%% then the times, which prim_file has worked out as POSIX seconds. A failed step stops the
%% rest, except enotsup, which stock passes over. The last name's link is followed, so on
%% a read-only entry the path is walked first: a link may lead to a writable one, and only
%% a path that ends on this entry answers erofs.
-spec write_file_info(grant(), place(), #file_info{}, path()) -> ok | {error, posix()}.
write_file_info(Grant, Place, Info, Path) ->
    one(Grant, Place, Path,
        fun(OnGrant, NameList, Text) ->
                Walk = [{NameList, followed(Text)}],
                case {writable(OnGrant), set_attrs(Info)} of
                    {_, {error, _} = Error} ->
                        Error;
                    {false, _} ->
                        case act(OnGrant, Walk, fun([Fid]) -> {getattr, Fid, ?INFO_MASK} end) of
                            {ok, _} -> {error, erofs};
                            Other -> Other
                        end;
                    {true, {ok, Steps}} ->
                        session(OnGrant, Walk, fun(_) -> [] end,
                                fun([Fid], []) -> set_each(OnGrant, Fid, Steps) end)
                end
        end,
        fun(Text) -> prim_file:write_file_info(Text, Info, [{time, posix}]) end).

set_each(_, _, []) ->
    ok;
set_each(Grant, Fid, [Attr | Steps]) ->
    case exchange(Grant, [{setattr, Fid, Attr}]) of
        [ok] -> set_each(Grant, Fid, Steps);
        [{error, enotsup}] -> set_each(Grant, Fid, Steps);
        [{error, _} = Error] -> Error
    end.

%% The setattr attributes of each step a record asks for, or why it cannot be sent: a
%% field of the wrong type is badarg, as stock's NIF refuses it, and an id or time out of
%% the protocol's range einval.
set_attrs(#file_info{uid = Uid, gid = Gid, mode = Mode, atime = ATime, mtime = MTime}) ->
    Steps = [owner_attr(Uid, Gid), mode_attr(Mode), times_attr(ATime, MTime)],
    case [Why || {error, Why} <- Steps] of
        [] -> {ok, [Attr || {set, Attr} <- Steps]};
        [Why | _] -> {error, Why}
    end;
set_attrs(_) ->
    {error, badarg}.

%% An id of -1 or undefined is left as it is, as chown's -1 leaves it.
owner_attr(Uid, Gid) ->
    case {owner_id(Uid, ?ERX_P9_SETATTR_VALID_UID), owner_id(Gid, ?ERX_P9_SETATTR_VALID_GID)} of
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error;
        {{ok, 0, _}, {ok, 0, _}} -> none;
        {{ok, UidBit, UidValue}, {ok, GidBit, GidValue}} ->
            {set, (unset())#{valid := UidBit bor GidBit, uid := UidValue, gid := GidValue}}
    end.

owner_id(Id, _) when Id =:= undefined; Id =:= -1 -> {ok, 0, 0};
owner_id(Id, Bit) when is_integer(Id), Id >= 0, Id =< 16#fffffffe -> {ok, Bit, Id};
owner_id(Id, _) when is_integer(Id) -> {error, einval};
owner_id(_, _) -> {error, badarg}.

%% Masked as stock's efile_set_permissions masks it: a record read back carries its type
%% bits, which are not a mode.
mode_attr(undefined) ->
    none;
mode_attr(Mode) when is_integer(Mode) ->
    {set, (unset())#{valid := ?ERX_P9_SETATTR_VALID_MODE, mode := Mode band ?PERMISSION_BITS}};
mode_attr(_) ->
    {error, badarg}.

times_attr(ATime, MTime) when is_integer(ATime), is_integer(MTime) ->
    case is_u64(ATime) andalso is_u64(MTime) of
        true ->
            {set, (unset())#{valid := ?ERX_P9_SETATTR_VALID_ATIME bor ?ERX_P9_SETATTR_VALID_ATIME_SET
                                 bor ?ERX_P9_SETATTR_VALID_MTIME bor ?ERX_P9_SETATTR_VALID_MTIME_SET,
                             atime_sec := ATime, mtime_sec := MTime}};
        false ->
            {error, einval}
    end;
times_attr(_, _) ->
    {error, badarg}.

unset() ->
    #{valid => 0, mode => 0, uid => 0, gid => 0, size => 0,
      atime_sec => 0, atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0}.


-spec make_dir(grant(), place(), path()) -> ok | {error, posix()}.
make_dir(Grant, Place, Path) ->
    one(Grant, Place, Path,
        fun(OnGrant, NameList, Text) ->
                make(OnGrant, NameList, Text,
                     fun(Names) ->
                             in_directory(OnGrant, Names,
                                          fun(DirFid, Name) ->
                                                  {mkdir, DirFid, Name, 8#777 band bnot ?UMASK, 0}
                                          end)
                     end)
        end,
        fun(Text) -> prim_file:make_dir(Text) end).

%% A new name written with a trailing "/" names a directory, which a link is not: nothing
%% is made, and the answer is eexist for a name that exists, else the walk's, as Linux's
%% symlink answers.
-spec make_symlink(grant(), place(), Target :: binary(), path()) -> ok | {error, posix()}.
make_symlink(Grant, Place, EncodedTarget, Path) ->
    case text(EncodedTarget) of
        Target when byte_size(Target) > ?ERX_P9_SYMLINK_MAX ->
            {error, enametoolong};
        Target ->
            one(Grant, Place, Path,
                fun(OnGrant, NameList, Text) ->
                        make(OnGrant, NameList, Text,
                             fun(Names) ->
                                     case slashed(Text) of
                                         false ->
                                             in_directory(OnGrant, Names,
                                                          fun(DirFid, Name) ->
                                                                  {symlink, DirFid, Name, Target, 0}
                                                          end);
                                         true ->
                                             looked(OnGrant, Names, fun exists/1)
                                     end
                             end)
                end,
                fun(Text) -> prim_file:make_symlink(EncodedTarget, Text) end)
    end.

%% An operation that makes a name: a last "." or ".." answers eexist once the rest of the
%% path is a directory (step 2), as does the tree's root, which always exists; else Make
%% runs on the names, unless the rights refuse a write.
make(Grant, NameList, Text, Make) ->
    case last_name_step(Text, fun(_) -> {error, eexist} end) of
        plain when NameList =:= [] -> {error, eexist};
        plain -> if_writable(Grant, [{dir_of(NameList), follow}], fun() -> Make(NameList) end);
        {error, _} = Error -> Error
    end.

%% A trailing "/" changes nothing here: rmdir acts only on a directory, and a link, which
%% the last name is never followed through, answers enotdir from the server.
-spec del_dir(grant(), place(), path()) -> ok | {error, posix()}.
del_dir(Grant, Place, Path) ->
    Answer = remove(Grant, Place, Path,
                    fun(<<".">>) -> {error, einval};
                       (<<"..">>) -> {error, enotempty}
                    end,
                    fun(OnGrant, Names, _) ->
                            in_directory(OnGrant, Names,
                                         fun(DirFid, Name) ->
                                                 {unlinkat, DirFid, Name, ?ERX_P9_AT_REMOVEDIR}
                                         end)
                    end,
                    fun(Text) -> prim_file:del_dir(Text) end),
    case Answer of
        {error, Full} when Full =:= enotempty; Full =:= eexist -> working_directory_step(Path);
        _ -> Answer
    end.

%% Step 5: a directory del_dir found full answers einval when it is the working directory,
%% as stock answers after it compares the stats of the path and of ".", else eexist.
working_directory_step(Path) ->
    {ok, Cwd} = prim_file:get_cwd(),
    case identity(text(Path)) of
        none -> {error, eexist};
        Identity ->
            case identity(raw(Cwd)) of
                Identity -> {error, einval};
                _ -> {error, eexist}
            end
    end.

%% A last name written with a trailing "/" is not followed and removes nothing: eisdir
%% for a directory, enotdir for anything else, a link included, as Linux's unlink answers.
-spec delete(grant(), place(), path()) -> ok | {error, posix()}.
delete(Grant, Place, Path) ->
    Answer = remove(Grant, Place, Path, fun(_) -> {error, eisdir} end,
                    fun(OnGrant, Names, Text) ->
                            case slashed(Text) of
                                false ->
                                    in_directory(OnGrant, Names,
                                                 fun(DirFid, Name) -> {unlinkat, DirFid, Name, 0} end);
                                true ->
                                    looked(OnGrant, Names, fun not_a_directory/1)
                            end
                    end,
                    fun(Text) -> prim_file:delete(Text) end),
    case Answer of
        {error, eisdir} -> {error, eperm};
        _ -> Answer
    end.

%% An operation that removes a name, following links as one/5 does: a last "." or ".."
%% answers Special's error once the rest of the path is a directory (step 2), and a path
%% whose place says Top, the top of a mount or of a bind, ebusy (step 3); else Remove runs
%% on the grant, the names and the text, unless the rights refuse a write.
remove(Grant, Place, Path, Special, Remove, Local) ->
    with_links(Grant, [Place], [text(Path)],
               fun(OnGrant, [{_, _, Names, Top}], [Text]) ->
                       case {last_name_step(Text, Special), Top} of
                           {plain, true} ->
                               {error, ebusy};
                           {plain, false} ->
                               NameList = names(Names),
                               if_writable(OnGrant, [{dir_of(NameList), follow}],
                                           fun() -> Remove(OnGrant, NameList, Text) end);
                           {{error, _} = Error, _} ->
                               Error
                       end
               end,
               fun([Text]) -> Local(Text) end).

%% A source that is not a directory, written with a trailing "/" on either side, answers
%% enotdir, as Linux's rename answers once it has found the source.
-spec rename(grant(), place(), place(), path(), path()) -> ok | {error, posix()}.
rename(Grant, Place, OtherPlace, Source, Destination) ->
    Answer = with_links(Grant, [Place, OtherPlace], [text(Source), text(Destination)],
                        fun renamed/3,
                        fun([From, To]) -> prim_file:rename(From, To) end),
    case Answer of
        {error, enotempty} -> {error, eexist};
        _ -> Answer
    end.

renamed(Grant, [{_, _, Names, FromTop}, {_, _, OtherNames, ToTop}], [Source, Destination]) ->
    {From, To} = {names(Names), names(OtherNames)},
    case special(Source) orelse special(Destination) of
        true ->
            %% Both paths' directories first, the source's before, as Linux finds them
            %% before it looks at either last name.
            case directory(rest(Source)) of
                ok -> on_ok(directory(rest(Destination)), {error, ebusy});
                Error -> Error
            end;
        false when FromTop; ToTop ->
            %% Step 3: either path is its entry's top, as the namespace placed it.
            {error, ebusy};
        false ->
            if_writable(Grant, [{dir_of(From), follow}, {dir_of(To), follow}],
                        fun() -> moved(Grant, From, To, slashed(Source) orelse slashed(Destination)) end)
    end.

moved(Grant, From, To, false) ->
    {FromDir, FromName} = split_last(From),
    {ToDir, ToName} = split_last(To),
    ok_of(act(Grant, [{FromDir, follow}, {ToDir, follow}],
              fun([FromFid, ToFid]) -> {renameat, FromFid, FromName, ToFid, ToName} end));
moved(Grant, From, To, true) ->
    {ToDir, _} = split_last(To),
    case act(Grant, [{From, nofollow}, {ToDir, follow}], fun([Fid, _]) -> {getattr, Fid, ?INFO_MASK} end) of
        {ok, #{mode := Mode}} when Mode band ?ERX_P9_S_IFMT =:= ?ERX_P9_S_IFDIR -> moved(Grant, From, To, false);
        {ok, _} -> {error, enotdir};
        Other -> Other
    end.

%% A hard link: the existing path is reached first and not followed, as Linux's linkat
%% looks it up before the new name, so its failure is the answer; the new name is made as
%% make_symlink makes one. An existing path written with a trailing "/" is followed and
%% must be a directory, which is never linked: once the new name's directory is found and
%% the name is free, eperm, as Linux's link answers, and nothing is sent that links.
-spec make_link(grant(), place(), place(), path(), path()) -> ok | {error, posix()}.
make_link(Grant, Place, OtherPlace, Existing, New) ->
    with_links(Grant, [Place, OtherPlace], [text(Existing), text(New)], fun linked/3,
               fun([From, To]) -> prim_file:make_link(From, To) end).

linked(Grant, [{_, _, Names, _}, {_, _, OtherNames, _}], [ExistingText, NewText]) ->
    {Existing, Made} = {names(Names), names(OtherNames)},
    Walk = {Existing, case slashed(ExistingText) of
                           true -> directory;
                           false -> nofollow
                       end},
    case special(NewText) orelse Made =:= [] of
        true ->
            %% The new name is "." or "..", or the tree's root: once the existing path
            %% is reached, the answer is step 2's or the root's eexist.
            case act(Grant, [Walk], fun([Fid]) -> {getattr, Fid, ?INFO_MASK} end) of
                {ok, _} -> special_new_name(NewText);
                Other -> Other
            end;
        false ->
            if_writable(Grant, [Walk, {dir_of(Made), follow}],
                        fun() -> link_made(Grant, Walk, Made, slashed(NewText)) end)
    end.

%% The answer for a new name that is ".", ".." or the tree's root.
special_new_name(New) ->
    case last_name_step(New, fun(_) -> {error, eexist} end) of
        plain -> {error, eexist};
        Error -> Error
    end.

%% A new name written with a trailing "/" is never made: eexist for a name that exists,
%% else the walk's answer. An existing directory is never linked: once the new name's
%% directory is found and the name is free, eperm.
link_made(Grant, Walk, Made, Slashed) ->
    {Dir, Name} = split_last(Made),
    Named = fun() ->
                    exists(act(Grant, [Walk, {Made, nofollow}],
                               fun([_, Fid]) -> {getattr, Fid, ?INFO_MASK} end))
            end,
    case {Walk, Slashed} of
        {_, true} ->
            Named();
        {{_, directory}, false} ->
            case act(Grant, [Walk, {Dir, directory}], fun([_, DirFid]) -> {getattr, DirFid, ?INFO_MASK} end) of
                {ok, _} -> on_ok(free(Named()), {error, eperm});
                Other -> Other
            end;
        {_, false} ->
            ok_of(act(Grant, [Walk, {Dir, follow}], fun([Fid, DirFid]) -> {link, DirFid, Fid, Name} end))
    end.

%% Open files ----------------------------------------------------------------

%% Opens the file as stock's NIF opens one, with Linux's flags for the modes. An open
%% that does not write walks the path and opens the file it reaches with lopen. One that
%% writes walks the last name's directory and sends lcreate, which creates the file or
%% opens the one already there in one step; a link there is followed, unless the open is
%% exclusive, which answers eexist, as Linux's O_EXCL does. On an entry that is not rw
%% the walks run, sending nothing that writes, before the answer. The descriptor names
%% this module, so file dispatches the open file's operations here.
-spec open(grant(), place(), list(), path()) -> {ok, #file_descriptor{}} | {error, posix()}.
open(Grant, Place, Modes, Path) ->
    Open = open_mode(Modes),
    one(Grant, Place, Path,
        fun(OnGrant, NameList, Text) -> open_on(OnGrant, NameList, Text, Open) end,
        fun(Text) -> prim_file:open(Text, Modes) end).

%% What the modes ask, as stock's efile_translate_modelist and get_flags read them:
%% append and exclusive write, an open that neither reads nor writes reads, and only a
%% write without read or append truncates.
open_mode(Modes) ->
    Append = has(append, Modes),
    Writes = has(write, Modes) orelse Append orelse has(exclusive, Modes),
    Access = case {has(read, Modes) orelse not Writes, Writes} of
                 {true, false} -> read;
                 {false, true} -> write;
                 {true, true} -> read_write
             end,
    Flags = access_flag(Access)
        bor flag(Access =:= write andalso not Append, ?ERX_P9_O_TRUNC)
        bor flag(Append, ?ERX_P9_O_APPEND)
        bor flag(has(exclusive, Modes), ?ERX_P9_O_EXCL)
        bor flag(has(sync, Modes), ?ERX_P9_O_SYNC),
    #{access => Access, flags => Flags, append => Append, directory => has(directory, Modes),
      type_check => not has(skip_type_check, Modes), ahead => ahead(Modes)}.

%% How far a read reads ahead, as stock's build_fd_data reads the modes: the last
%% read_ahead option, 64 KiB for a bare one, none without one. A size that is not a
%% count reads none ahead.
ahead(Modes) -> ahead(Modes, 0).

ahead([read_ahead | Modes], _) -> ahead(Modes, ?READ_AHEAD);
ahead([{read_ahead, Size} | Modes], _) when is_integer(Size), Size >= 0 -> ahead(Modes, Size);
ahead([{read_ahead, _} | Modes], _) -> ahead(Modes, 0);
ahead([_ | Modes], Size) -> ahead(Modes, Size);
ahead(_, Size) -> Size.

access_flag(read) -> 0;
access_flag(write) -> ?ERX_P9_O_WRONLY;
access_flag(read_write) -> ?ERX_P9_O_RDWR.

flag(true, Flag) -> Flag;
flag(false, _) -> 0.

%% Whether the mode list holds Mode, reading only its proper part, as the NIF reads it.
has(Mode, [Mode | _]) -> true;
has(Mode, [_ | Modes]) -> has(Mode, Modes);
has(_, _) -> false.

open_on(Grant, NameList, Text, #{access := read, directory := Directory, flags := Flags} = Open) ->
    Mode = case Directory orelse slashed(Text) of
               true -> directory;
               false -> follow
           end,
    described(kept(Grant, {NameList, Mode}, fun(Fid) -> {lopen, Fid, Flags} end), Grant, Open);
open_on(_, _, _, #{directory := true}) ->
    %% A directory is never opened to write: einval, as Linux answers O_DIRECTORY with
    %% O_CREAT, before anything is walked or truncated.
    {error, einval};
open_on(Grant, NameList, Text, Open) ->
    case last_name_step(Text, fun(_) -> {error, eisdir} end) of
        plain when NameList =:= [] -> {error, eisdir};
        plain -> created(Grant, NameList, slashed(Text), Open);
        {error, _} = Error -> Error
    end.

%% An open that writes, on its last name's directory. A name written with a trailing "/"
%% is never made: once the directory is found, eisdir, as Linux's open with O_CREAT
%% answers. On an entry that is not rw, the name is looked at as Linux looks before it
%% refuses: eexist for an exclusive open of any name there, eisdir for a directory, and
%% erofs for a file or a missing name.
created(Grant, NameList, true, _) ->
    on_ok(ok_of(act(Grant, [{dir_of(NameList), follow}], fun stat/1)), {error, eisdir});
created({_, _, rw} = Grant, NameList, false, #{flags := Flags} = Open) ->
    {Dir, Name} = split_last(NameList),
    Create = fun(DirFid) -> {lcreate, DirFid, Name, Flags, 8#666 band bnot ?UMASK, 0} end,
    case {kept(Grant, {Dir, follow}, Create), exclusive(Flags)} of
        {{error, eloop}, false} -> {link, 1, length(NameList) - 1};
        {{error, eloop}, true} -> {error, eexist};
        {Kept, _} -> described(Kept, Grant, Open)
    end;
created(Grant, NameList, false, #{flags := Flags}) ->
    Last = case exclusive(Flags) of
               true -> nofollow;
               false -> follow
           end,
    case act(Grant, [{dir_of(NameList), follow}], fun stat/1) of
        {ok, _} ->
            case {act(Grant, [{NameList, Last}], fun stat/1), Last} of
                {{ok, _}, nofollow} -> {error, eexist};
                {{ok, #{mode := Mode}}, _} when Mode band ?ERX_P9_S_IFMT =:= ?ERX_P9_S_IFDIR -> {error, eisdir};
                {{ok, _}, _} -> {error, erofs};
                {{error, enoent}, _} -> {error, erofs};
                {Other, _} -> Other
            end;
        Other ->
            Other
    end.

exclusive(Flags) -> Flags band ?ERX_P9_O_EXCL =/= 0.

stat([Fid | _]) -> {getattr, Fid, ?INFO_MASK}.

%% Reaches a path into a new fid and sends Open on that fid with the walks. The fid is
%% kept for the caller when the walk reached its end and Open succeeded, as
%% {ok, Fid, Qid, Iounit}; otherwise it is clunked with the walk's other fids, and the
%% answer is the first failure or link.
kept({_, Tree, _} = Grant, Path, Open) ->
    {Root, [{_, Fid, _}] = Reaches, Walks} = reaches([Path]),
    Others = [Root | [New || {walk, _, New, _} <- Walks, New =/= Fid]],
    [Attached | Replies] = exchange(Grant, [attach(Root, Tree) | Walks]
                                    ++ [Open(Fid) | [{clunk, Other} || Other <- Others]]),
    {Walked, [Reply | _]} = split_at(length(Walks), Replies),
    case on_ok(reached(Attached, Reaches, Walked), Reply) of
        {ok, Qid, Iounit} ->
            {ok, Fid, Qid, Iounit};
        Failed ->
            _ = exchange(Grant, [{clunk, Fid}]),
            Failed
    end.

%% The descriptor of a file kept open. Opening a directory without [directory] answers
%% eisdir (error step 6), as stock's open answers.
described({ok, Fid, {Type, _, _}, _}, Grant, #{directory := false, type_check := true})
  when Type band ?ERX_P9_QTDIR =/= 0 ->
    _ = exchange(Grant, [{clunk, Fid}]),
    {error, eisdir};
described({ok, Fid, _, Iounit}, Grant, #{access := Access, append := Append, ahead := Ahead}) ->
    Unit = case Iounit of
               0 -> ?ERX_P9_IO_MAX;
               _ -> min(Iounit, ?ERX_P9_IO_MAX)
           end,
    Cells = atomics:new(?CELLS, [{signed, false}]),
    {ok, #file_descriptor{module = ?MODULE,
                          data = #{grant => Grant, fid => Fid, owner => self(), cells => Cells,
                                   access => Access, append => Append, unit => Unit,
                                   ahead => Ahead, buffer => prim_buffer:new()}}};
described(Other, _, _) ->
    Other.

%% The open file's state, for its controlling process alone: any other process's call
%% raises, as stock's get_fd_data/1 raises. A closed file answers einval, as stock's does.
on_open(#file_descriptor{module = ?MODULE, data = #{owner := Owner, cells := Cells} = File}, Act) ->
    case {self(), atomics:get(Cells, ?CLOSED)} of
        {Owner, 0} -> Act(File);
        {Owner, _} -> {error, einval};
        _ -> error(not_on_controlling_process)
    end.

%% The fid is clunked once: a second close answers einval.
-spec close(#file_descriptor{}) -> ok | {error, posix()}.
close(Fd) ->
    on_open(Fd, fun(#{grant := Grant, fid := Fid, cells := Cells}) ->
                        atomics:put(Cells, ?CLOSED, 1),
                        [Reply] = exchange(Grant, [{clunk, Fid}]),
                        Reply
                end).

%% Reading --------------------------------------------------------------------

%% The read buffer. The offset in the cells is the caller's: the next byte read/2 or
%% read_line/1 answers. The buffer holds the bytes from that offset on as an earlier read
%% fetched them, the bytes read ahead, so a read answers them however the file has
%% changed since, as stock's read-ahead does, and only the owning process, which alone
%% passes on_open, touches it. position/2, write/2, pwrite/2,3 and truncate/1 empty it,
%% as stock's do, and leave the offset where the caller's reads moved it, so no byte is
%% lost or answered twice.

%% Reads from the offset and moves it past what was read: what the buffer holds first,
%% then a read of the rest plus the read-ahead size, the excess kept,
%% as stock's read_1 reads.
-spec read(#file_descriptor{}, non_neg_integer()) -> {ok, binary()} | eof | {error, posix()}.
read(Fd, Size) when is_integer(Size), Size >= 0 ->
    on_open(Fd, fun(#{cells := Cells} = File) ->
                        Offset = atomics:get(Cells, ?OFFSET),
                        case buffered(File, Offset, Size) of
                            {ok, Data} = Read ->
                                on_ok(moved_past(Cells, Offset + byte_size(Data)), Read);
                            Other ->
                                Other
                        end
                end);
read(_, _) ->
    {error, badarg}.

%% A write-only file answers ebadf before the buffer is looked at, a read of no bytes
%% included, which read_at would not reach.
buffered(#{access := write}, _, _) ->
    {error, ebadf};
buffered(#{buffer := Buffer} = File, Offset, Size) ->
    case prim_buffer:size(Buffer) of
        Held when Held >= Size ->
            {ok, prim_buffer:read(Buffer, Size)};
        Held ->
            fetched(File, Offset + Held, Size - Held, prim_buffer:read(Buffer, Held))
    end.

%% Need bytes at Offset after the Head the buffer held. eof or an error after a Head
%% answers the Head, which the caller's offset then moves past.
fetched(#{buffer := Buffer, ahead := Ahead} = File, Offset, Need, Head) ->
    case read_at(File, Offset, Need + Ahead) of
        {ok, Data} when byte_size(Data) > Need ->
            {First, Rest} = split_binary(Data, Need),
            prim_buffer:write(Buffer, [Rest]),
            {ok, <<Head/binary, First/binary>>};
        {ok, Data} ->
            {ok, <<Head/binary, Data/binary>>};
        _ when Head =/= <<>> ->
            {ok, Head};
        Other ->
            Other
    end.

%% Act on an open file once its buffer is empty, which leaves the offset at the next byte
%% the caller has not read: for the calls that move the offset or change the file.
emptied(Fd, Act) ->
    on_open(Fd, fun(#{buffer := Buffer} = File) ->
                        prim_buffer:wipe(Buffer),
                        Act(File)
                end).

%% Up to Size bytes at Offset, in requests of at most a unit each (design-files.md, Open
%% files and offsets), until Size is read or a reply is shorter than its request, as at
%% the end of the file: so a read of a regular file answers every byte up to its end, as
%% stock's read(2) of one does, whatever the unit. eof when the file has none there. An
%% error after some bytes answers those bytes, as read(2) answers a short count, and the
%% next read meets it again. One call reads at most ?READ_MAX bytes. Through a file not opened for reading, ebadf, as stock
%% answers, sending nothing.
read_at(#{access := write}, _, _) ->
    {error, ebadf};
read_at(_, Offset, _) when Offset < 0; Offset > ?OFFSET_MAX ->
    {error, einval};
read_at(File, Offset, Size) ->
    case read_in_units(File, Offset, min(Size, ?READ_MAX), []) of
        {ok, <<>>} when Size > 0 -> eof;
        Read -> Read
    end.

%% Parts holds the replies so far, newest first, each a whole request's count. A reply
%% longer than its request, which no server of erXos sends, answers eio; a request whose
%% offset would pass 2^63 - 1 is not sent, and what was read is answered.
read_in_units(_, Offset, Size, Parts) when Size =:= 0; Offset > ?OFFSET_MAX ->
    {ok, iolist_to_binary(lists:reverse(Parts, []))};
read_in_units(#{grant := Grant, fid := Fid, unit := Unit} = File, Offset, Size, Parts) ->
    Count = min(Size, Unit),
    case exchange(Grant, [{read, Fid, Offset, Count}]) of
        [{ok, Data}] when byte_size(Data) =:= Count ->
            read_in_units(File, Offset + Count, Size - Count, [Data | Parts]);
        [{ok, Data}] when byte_size(Data) < Count ->
            {ok, iolist_to_binary(lists:reverse(Parts, [Data]))};
        [{ok, _}] ->
            {error, eio};
        [{error, _} = Error] when Parts =:= [] ->
            Error;
        [{error, _}] ->
            {ok, iolist_to_binary(lists:reverse(Parts, []))}
    end.

%% The offset after a read; a server that sent bytes past 2^63 - 1 answers eio.
moved_past(Cells, Offset) ->
    case checked_offset(Offset) of
        {ok, _} -> atomics:put(Cells, ?OFFSET, Offset);
        Error -> Error
    end.

%% A positioned read answers eof for no bytes, a request of none included, and einval
%% for a negative size, as stock's pread_nif answers.
-spec pread(#file_descriptor{}, integer(), integer()) -> {ok, binary()} | eof | {error, posix()}.
pread(Fd, Offset, Size) when is_integer(Offset), is_integer(Size) ->
    on_open(Fd, fun(File) -> read_placed(File, Offset, Size) end);
pread(_, _, _) ->
    {error, badarg}.

read_placed(_, _, Size) when Size < 0 ->
    {error, einval};
read_placed(File, Offset, Size) ->
    case read_at(File, Offset, Size) of
        {ok, <<>>} -> eof;
        Read -> Read
    end.

%% file:ipread_s32bu_p32bu/3, as stock's ipread_s32bu_p32bu_nif reads it: the 8-byte
%% block at Offset, <<Size:32, At:32>> big-endian, then Size bytes at At. A block cut
%% short by the end of the file, or a Size over MaxSize, answers eof; no bytes at At,
%% {ok, {Size, At, eof}}. Any atom stands for infinity, 2^31 - 1, as in prim_file; an
%% Offset that is negative or past 2^63 - 1, or a MaxSize from 2^31 or below -2^63,
%% answers einval before anything is read.
-spec ipread_s32bu_p32bu(#file_descriptor{}, term(), term()) ->
          {ok, {non_neg_integer(), non_neg_integer(), binary() | eof}} | eof |
          {error, posix() | badarg}.
ipread_s32bu_p32bu(Fd, Offset, Infinity) when is_atom(Infinity) ->
    ipread_s32bu_p32bu(Fd, Offset, (1 bsl 31) - 1);
ipread_s32bu_p32bu(Fd, Offset, MaxSize) when is_integer(Offset), is_integer(MaxSize) ->
    on_open(Fd, fun(File) -> read_pointer_block(File, Offset, MaxSize) end);
ipread_s32bu_p32bu(_, _, _) ->
    {error, badarg}.

read_pointer_block(_, Offset, MaxSize)
  when Offset < 0; Offset > ?OFFSET_MAX; MaxSize >= 1 bsl 31; MaxSize < -?OFFSET_MAX - 1 ->
    {error, einval};
read_pointer_block(File, Offset, MaxSize) ->
    case read_at(File, Offset, 8) of
        {ok, <<Size:32, At:32>>} when Size =< MaxSize -> pointed_data(read_at(File, At, Size), Size, At);
        {ok, _} -> eof;
        eof -> eof;
        {error, _} = Error -> Error
    end.

%% A Size of 0 reads nothing and answers eof in place of the data, as stock's does.
pointed_data({ok, <<>>}, Size, At) -> {ok, {Size, At, eof}};
pointed_data({ok, Data}, Size, At) -> {ok, {Size, At, Data}};
pointed_data(eof, Size, At) -> {ok, {Size, At, eof}};
pointed_data({error, _} = Error, _, _) -> Error.

-spec pread(#file_descriptor{}, [{integer(), non_neg_integer()}]) ->
          {ok, [binary() | eof]} | {error, posix()}.
pread(Fd, Positions) ->
    on_open(Fd, fun(File) -> read_each(File, Positions, []) end).

read_each(_, [], Results) ->
    {ok, lists:reverse(Results, [])};
read_each(File, [{Offset, Size} | Positions], Results)
  when is_integer(Offset), is_integer(Size) ->
    case read_placed(File, Offset, Size) of
        {ok, Data} -> read_each(File, Positions, [Data | Results]);
        eof -> read_each(File, Positions, [eof | Results]);
        Error -> Error
    end;
read_each(_, _, _) ->
    {error, badarg}.

%% The bytes up to and including the next "\n", a "\r\n" given as "\n" as stock gives
%% it, or the rest of the file before its end; eof at the end. The offset moves past the
%% line as the file holds it. As stock's read_line_1, it looks in the buffer first and
%% appends reads of at least ?LINE_READ bytes, or the read-ahead if more, until the buffer
%% holds a "\n" or the file ends, and the bytes after the line stay buffered.
-spec read_line(#file_descriptor{}) -> {ok, binary()} | eof | {error, posix()}.
read_line(Fd) ->
    on_open(Fd, fun(#{cells := Cells, buffer := Buffer} = File) ->
                        line(File, atomics:get(Cells, ?OFFSET),
                             prim_buffer:find_byte_index(Buffer, $\n))
                end).

%% The third argument is prim_buffer:find_byte_index's answer for a "\n" in the buffer.
line(#{buffer := Buffer, ahead := Ahead} = File, Offset, not_found) ->
    Held = prim_buffer:size(Buffer),
    case read_at(File, Offset + Held, max(?LINE_READ, Ahead)) of
        {ok, Data} ->
            prim_buffer:write(Buffer, [Data]),
            line(File, Offset, prim_buffer:find_byte_index(Buffer, $\n));
        eof when Held =:= 0 ->
            eof;
        eof ->
            taken(File, Offset, prim_buffer:read(Buffer, Held));
        Error ->
            Error
    end;
line(#{buffer := Buffer} = File, Offset, {ok, At}) ->
    taken(File, Offset, prim_buffer:read(Buffer, At + 1)).

%% A line taken from the buffer: the offset moves past it as the file holds it.
taken(#{cells := Cells}, Offset, Line) ->
    on_ok(moved_past(Cells, Offset + byte_size(Line)), {ok, without_cr(Line)}).

without_cr(Line) when byte_size(Line) >= 2 ->
    case binary_part(Line, byte_size(Line) - 2, 2) of
        <<"\r\n">> -> <<(binary_part(Line, 0, byte_size(Line) - 2))/binary, "\n">>;
        _ -> Line
    end;
without_cr(Line) ->
    Line.

%% The whole file, as stock's read_file reads it: up to the size getattr answers once the
%% file is open, or to its end if that comes first.
-spec read_file(grant(), place(), path()) -> {ok, binary()} | {error, posix()}.
read_file(Grant, Place, Path) ->
    one(Grant, Place, Path,
        fun(OnGrant, NameList, Text) ->
                case open_on(OnGrant, NameList, Text, open_mode([read])) of
                    {ok, Fd} ->
                        Contents = on_open(Fd, fun(File) -> contents(File) end),
                        _ = close(Fd),
                        Contents;
                    Other ->
                        Other
                end
        end,
        fun(Text) -> prim_file:read_file(Text) end).

contents(File) ->
    case size_of(File) of
        {ok, Size} -> contents(File, 0, Size, []);
        Error -> Error
    end.

contents(_, Offset, Size, Parts) when Offset >= Size ->
    {ok, iolist_to_binary(lists:reverse(Parts, []))};
contents(File, Offset, Size, Parts) ->
    case read_at(File, Offset, Size - Offset) of
        {ok, Data} -> contents(File, Offset + byte_size(Data), Size, [Data | Parts]);
        eof -> contents(File, Size, Size, Parts);
        Error -> Error
    end.

%% Writing --------------------------------------------------------------------

%% Writes at the offset, which moves past each request's bytes as it is answered.
-spec write(#file_descriptor{}, iodata()) -> ok | {error, posix()}.
write(Fd, Bytes) ->
    emptied(Fd, fun(#{cells := Cells} = File) ->
                        written(File, atomics:get(Cells, ?OFFSET), Bytes,
                                fun(Offset) -> atomics:put(Cells, ?OFFSET, Offset) end)
                end).

%% A positioned write leaves the offset where it was, whatever the reply.
-spec pwrite(#file_descriptor{}, integer(), iodata()) -> ok | {error, posix()}.
pwrite(Fd, Offset, Bytes) when is_integer(Offset) ->
    emptied(Fd, fun(File) -> written(File, Offset, Bytes, fun(_) -> ok end) end);
pwrite(_, _, _) ->
    {error, badarg}.

%% As stock's: the writes in order, and the count of those that succeeded with the error.
-spec pwrite(#file_descriptor{}, [{integer(), iodata()}]) ->
          ok | {error, {non_neg_integer(), posix()}}.
pwrite(Fd, Positions) ->
    emptied(Fd, fun(File) -> write_each(File, Positions, 0) end).

write_each(_, [], _) ->
    ok;
write_each(File, [{Offset, Bytes} | Positions], Done) when is_integer(Offset) ->
    case written(File, Offset, Bytes, fun(_) -> ok end) of
        ok -> write_each(File, Positions, Done + 1);
        {error, Why} -> {error, {Done, Why}}
    end;
write_each(_, _, _) ->
    {error, badarg}.

%% Bytes written from Offset in requests of at most a unit each, each atomic against
%% every other: a request refused part way leaves the ones before it written, and Moved
%% has been given the offset past them. Through a file not opened for writing, ebadf,
%% as stock answers, sending nothing.
written(#{access := read}, _, _, _) ->
    {error, ebadf};
written(_, Offset, _, _) when Offset < 0; Offset > ?OFFSET_MAX ->
    {error, einval};
written(File, Offset, Bytes, Moved) ->
    try iolist_to_binary(Bytes) of
        Data -> requests(File, Offset, Data, Moved)
    catch
        error:badarg -> {error, badarg}
    end.

requests(_, _, <<>>, _) ->
    ok;
requests(#{grant := Grant, fid := Fid, unit := Unit} = File, Offset, Data, Moved) ->
    Chunk = binary_part(Data, 0, min(Unit, byte_size(Data))),
    case exchange(Grant, [{write, Fid, Offset, Chunk}]) of
        [{ok, 0, _}] ->
            {error, eio};
        [{ok, Count, At}] ->
            case offset_after(File, Offset, Count, At) of
                {ok, Next} ->
                    Moved(Next),
                    requests(File, Next, binary_part(Data, Count, byte_size(Data) - Count), Moved);
                Error ->
                    Error
            end;
        [{error, _} = Error] ->
            Error
    end.

%% The offset after Count bytes written by a request sent at Sent, by the rule of
%% design-files.md's Open files and offsets: At plus the count when the reply names At,
%% where the bytes landed; else the offset sent plus the count, or, through an append
%% fid, the file's size once the reply has arrived. A server that answers an offset past
%% 2^63 - 1, which no file reaches, answers eio.
offset_after(File, Sent, Count, At) ->
    case {At, File} of
        {_, _} when is_integer(At) -> checked_offset(At + Count);
        {unknown, #{append := false}} -> checked_offset(Sent + Count);
        {unknown, #{append := true}} -> size_of(File)
    end.

checked_offset(Offset) when Offset =< ?OFFSET_MAX -> {ok, Offset};
checked_offset(_) -> {error, eio}.

size_of(#{grant := Grant, fid := Fid}) ->
    case exchange(Grant, [{getattr, Fid, ?ERX_P9_GETATTR_MASK_SIZE}]) of
        [{ok, #{size := Size}}] -> checked_offset(Size);
        [{error, _} = Error] -> Error
    end.

%% Moves the offset as stock's seek does: from the start, the offset or the file's end,
%% to a place from 0 to 2^63 - 1, else einval.
-spec position(#file_descriptor{}, term()) -> {ok, non_neg_integer()} | {error, posix()}.
position(Fd, At) ->
    emptied(Fd, fun(File) -> moved(File, At) end).

moved(File, Mark) when Mark =:= bof; Mark =:= cur; Mark =:= eof ->
    moved(File, {Mark, 0});
moved(File, Offset) when is_integer(Offset) ->
    moved(File, {bof, Offset});
moved(#{cells := Cells} = File, {Mark, Offset}) when is_integer(Offset) ->
    case {base(File, Mark), Offset} of
        {{ok, Base}, _} when Base + Offset >= 0, Base + Offset =< ?OFFSET_MAX ->
            atomics:put(Cells, ?OFFSET, Base + Offset),
            {ok, Base + Offset};
        {{ok, _}, _} -> {error, einval};
        {Error, _} -> Error
    end;
moved(_, _) ->
    {error, badarg}.

base(_, bof) -> {ok, 0};
base(#{cells := Cells}, cur) -> {ok, atomics:get(Cells, ?OFFSET)};
base(File, eof) -> size_of(File);
base(_, _) -> {error, badarg}.

%% Sets the size to the offset. Through a file not opened for writing, einval, as Linux's
%% ftruncate answers, sending nothing.
-spec truncate(#file_descriptor{}) -> ok | {error, posix()}.
truncate(Fd) ->
    emptied(Fd, fun(#{access := read}) ->
                        {error, einval};
                   (#{grant := Grant, fid := Fid, cells := Cells}) ->
                        Size = (unset())#{valid := ?ERX_P9_SETATTR_VALID_SIZE,
                                          size := atomics:get(Cells, ?OFFSET)},
                        [Reply] = exchange(Grant, [{setattr, Fid, Size}]),
                        Reply
                end).

-spec sync(#file_descriptor{}) -> ok | {error, posix()}.
sync(Fd) -> synced(Fd, 0).

-spec datasync(#file_descriptor{}) -> ok | {error, posix()}.
datasync(Fd) -> synced(Fd, 1).

synced(Fd, DataOnly) ->
    on_open(Fd, fun(#{grant := Grant, fid := Fid}) ->
                        [Reply] = exchange(Grant, [{fsync, Fid, DataOnly}]),
                        Reply
                end).

%% 9P2000.L has no operation for advice, which is only a recommendation: ok, as stock's
%% efile_advise answers without posix_fadvise, once the arguments pass stock's
%% advise_nif: an offset or length that is not a number is badarg, and one that is not
%% an integer from 0 to 2^63 - 1, or advice POSIX does not name, einval.
-spec advise(#file_descriptor{}, term(), term(), term()) -> ok | {error, posix() | badarg}.
advise(Fd, Offset, Length, Advice) ->
    on_open(Fd, fun(_) -> advised(Offset, Length, Advice) end).

advised(Offset, Length, _) when not is_number(Offset); not is_number(Length) ->
    {error, badarg};
advised(Offset, Length, Advice)
  when is_integer(Offset), Offset >= 0, Offset =< ?OFFSET_MAX,
       is_integer(Length), Length >= 0, Length =< ?OFFSET_MAX ->
    case known_advice(Advice) of
        true -> ok;
        false -> {error, einval}
    end;
advised(_, _, _) ->
    {error, einval}.

known_advice(Advice) ->
    Advice =:= normal orelse Advice =:= random orelse Advice =:= sequential
        orelse Advice =:= will_need orelse Advice =:= dont_need orelse Advice =:= no_reuse.

%% Nor for preallocation: enotsup, as stock answers without it.
-spec allocate(#file_descriptor{}, integer(), integer()) -> {error, posix()}.
allocate(Fd, _Offset, _Length) ->
    on_open(Fd, fun(_) -> {error, enotsup} end).

%% A remote file has no descriptor to hand to the host's sendfile: enotsup, on which
%% file:sendfile/5 takes its fallback of reads and sends.
-spec sendfile(#file_descriptor{}, term(), integer(), integer(), integer(), list(), list(),
               list()) -> {error, enotsup}.
sendfile(_Fd, _Socket, _Offset, _Bytes, _ChunkSize, _Headers, _Trailers, _Flags) ->
    {error, enotsup}.

%% file:read_file_info/2 on an open file: getattr through its fid, the record as
%% read_file_info/4 builds it, its times in the type asked for.
-spec read_handle_info(#file_descriptor{}, list()) -> {ok, #file_info{}} | {error, posix()}.
read_handle_info(Fd, Options) ->
    try
        on_open(Fd, fun(#{grant := Grant, fid := Fid}) ->
                            case time_type(Options) of
                                badarg -> {error, badarg};
                                Type -> handle_info(Grant, Fid, Type)
                            end
                    end)
    catch
        %% As stock's read_handle_info_1: a time a server sends past what the conversion
        %% takes, or a call from another process, answers badarg and raises nothing.
        error:_ -> {error, badarg}
    end.

handle_info(Grant, Fid, Type) ->
    case exchange(Grant, [{getattr, Fid, ?INFO_MASK}]) of
        [{ok, Attr}] -> {ok, times(file_info(Grant, Attr), Type)};
        [Error] -> Error
    end.

time_type([{time, Type} | _]) when Type =:= posix; Type =:= universal; Type =:= local -> Type;
time_type([{time, _} | _]) -> badarg;
time_type([_ | Options]) -> time_type(Options);
time_type(_) -> local.

%% As stock's adjust_times/2 converts them.
times(Info, posix) ->
    Info;
times(#file_info{atime = ATime, mtime = MTime, ctime = CTime} = Info, Type) ->
    Info#file_info{atime = datetime(ATime, Type), mtime = datetime(MTime, Type),
                   ctime = datetime(CTime, Type)}.

datetime(Seconds, universal) -> erlang:posixtime_to_universaltime(Seconds);
datetime(Seconds, local) -> erlang:universaltime_to_localtime(erlang:posixtime_to_universaltime(Seconds)).

%% file:copy/3 between two open files of servers: reads and writes of a unit at a time.
-spec copy(#file_descriptor{}, #file_descriptor{}, non_neg_integer() | infinity) ->
          {ok, non_neg_integer()} | {error, posix()}.
copy(Source, Destination, Length) ->
    copied(Source, Destination, Length, 0).

copied(_, _, 0, Done) ->
    {ok, Done};
copied(Source, Destination, Left, Done) ->
    Chunk = case is_integer(Left) of
                true -> min(Left, ?ERX_P9_IO_MAX);
                false -> ?ERX_P9_IO_MAX
            end,
    case read(Source, Chunk) of
        {ok, Data} ->
            case write(Destination, Data) of
                ok when not is_integer(Left) -> copied(Source, Destination, Left, Done + byte_size(Data));
                ok -> copied(Source, Destination, Left - byte_size(Data), Done + byte_size(Data));
                Error -> Error
            end;
        eof ->
            {ok, Done};
        Error ->
            Error
    end.

%% The working directory is a namespace path (design-files.md, Erlang clients): set_cwd
%% follows the path's links, as chdir does, and makes the namespace path of the directory
%% it reaches the working directory, which prim_file's NIF resolves every relative path
%% against. A path that a link led to the NIF's own providers is set there.
-spec set_cwd(grant(), place(), path()) -> ok | {error, posix()}.
set_cwd(Grant, Place, Path) ->
    with_links(Grant, [Place], [text(Path)],
               fun(OnGrant, [Reached], [Text]) -> cwd_at(OnGrant, Reached, Text) end,
               fun([Text]) -> prim_file:set_cwd(Text) end).

%% chdir's checks on what the path reaches: a directory, which the domain's user may
%% search, as the owner whose permission bits a server checks (design-tmp.md,
%% Permissions); else enotdir or eacces, or the walk's answer.
cwd_at(Grant, {_, _, Names, _} = Reached, Text) ->
    case act(Grant, [{names(Names), followed(Text)}], fun([Fid]) -> {getattr, Fid, ?INFO_MASK} end) of
        {ok, #{mode := Mode}} when Mode band ?ERX_P9_S_IFMT =/= ?ERX_P9_S_IFDIR -> {error, enotdir};
        {ok, #{mode := Mode}} when Mode band 8#100 =:= 0 -> {error, eacces};
        {ok, _} -> prim_file:erx_set_cwd(namespace_path(Reached));
        Other -> Other
    end.

%% The namespace path a place names: the entry's point, then the names below its root.
namespace_path({Point, Root, Names, _}) ->
    {_, Below} = split_at(length(names(Root)), names(Names)),
    joined([Point | Below], false).

%% Step 5's identity of the directory a path names, its links followed and "." and ".."
%% resolved on its text by the NIF: its grant's pid and tree and the qid path a getattr
%% answers, or none when the path lies on no grant or reaching it fails, so two failures
%% never compare as one directory.
-spec identity(text()) -> {pid(), binary(), non_neg_integer()} | none.
identity(Text) ->
    Found = case prim_file:erx_resolve([Text]) of
                {remote, Grant, Place} ->
                    with_links(Grant, [Place], [Text],
                               fun({Pid, Tree, _} = OnGrant, [{_, _, Names, _}], _) ->
                                       case act(OnGrant, [{names(Names), follow}],
                                                fun([Fid]) -> {getattr, Fid, ?INFO_MASK} end) of
                                           {ok, #{qid := {_, _, QidPath}}} -> {found, {Pid, Tree, QidPath}};
                                           Other -> Other
                                       end
                               end,
                               fun(_) -> none end);
                _ ->
                    none
            end,
    case Found of
        {found, Identity} -> Identity;
        _ -> none
    end.

%% The error steps -----------------------------------------------------------

%% Step 2: a path whose last name, as the caller wrote it, is "." or ".." changes nothing;
%% the rest of the path must be a directory, and Special gives the answer past it. A plain
%% last name answers plain.
last_name_step(Text, Special) ->
    {Rest, Last, _} = last_name(Text),
    case special_name(Last) of
        true -> on_ok(directory(Rest), Special(Last));
        false -> plain
    end.

%% Request on the directory of NameList's last name and that name.
in_directory(Grant, NameList, Request) ->
    {Dir, Name} = split_last(NameList),
    ok_of(act(Grant, [{Dir, follow}], fun([DirFid]) -> Request(DirFid, Name) end)).

%% What a last name that is not followed is, for an operation written with a trailing
%% "/" that does nothing: Meaning reads the getattr answer.
looked(Grant, NameList, Meaning) ->
    Meaning(act(Grant, [{NameList, nofollow}], fun([Fid]) -> {getattr, Fid, ?INFO_MASK} end)).

exists({ok, _}) -> {error, eexist};
exists(Other) -> Other.

%% ok for a name exists/1 found missing.
free({error, enoent}) -> ok;
free(Other) -> Other.

not_a_directory({ok, #{mode := Mode}}) when Mode band ?ERX_P9_S_IFMT =:= ?ERX_P9_S_IFDIR -> {error, eisdir};
not_a_directory({ok, _}) -> {error, enotdir};
not_a_directory(Other) -> Other.

%% Then, on an entry that allows writes. On any other the walks run first, sending
%% nothing that writes, so a link among them leads the operation to the entry it
%% reaches, and a missing directory answers before erofs, as on Linux.
if_writable({_, _, rw}, _, Then) ->
    Then();
if_writable(Grant, Walks, _) ->
    case act(Grant, Walks, fun([Fid | _]) -> {getattr, Fid, ?INFO_MASK} end) of
        {ok, _} -> {error, erofs};
        Other -> Other
    end.

%% The names of a non-empty name list's directory.
dir_of(NameList) ->
    {Dir, _} = split_last(NameList),
    Dir.

writable({_, _, rw}) -> true;
writable({_, _, _}) -> false.

%% ok for a directory the path reaches after its links, as Linux finds a last name's
%% directory; the path goes through prim_file, so it may lie on any provider.
directory(Text) ->
    case prim_file:read_file_info(Text) of
        {ok, #file_info{type = directory}} -> ok;
        {ok, #file_info{}} -> {error, enotdir};
        {error, _} = Error -> Error
    end.

special(Text) ->
    {_, Last, _} = last_name(Text),
    special_name(Last).

special_name(<<".">>) -> true;
special_name(<<"..">>) -> true;
special_name(_) -> false.

rest(Text) ->
    {Rest, _, _} = last_name(Text),
    Rest.

%% A path written with a "/" after its last name names a directory.
slashed(Text) ->
    {_, _, Slashed} = last_name(Text),
    Slashed.

%% How a walk that follows its last link treats it: a path written with a trailing "/"
%% must end on a directory.
followed(Text) ->
    case slashed(Text) of
        true -> directory;
        false -> follow
    end.

on_ok(ok, Then) -> Then;
on_ok(Other, _) -> Other.

ok_of({ok, _}) -> ok;
ok_of(Answer) -> Answer.

%% Paths ---------------------------------------------------------------------

%% A path's last name as the caller wrote it, past any trailing "/", the rest of the path,
%% which names the last name's directory: up to and including the "/" before the last
%% name, or "." for a path of one name, and whether a "/" follows the last name. A path of
%% only "/" has no last name (<<>>) and is its own rest, as is the empty path, which the
%% NIF refuses before this is asked.
-spec last_name(path() | text()) -> {Rest :: binary(), Last :: binary(), Slashed :: boolean()}.
last_name(Encoded) when is_binary(Encoded) ->
    Path = text(Encoded),
    Trimmed = trim_slashes(Path, byte_size(Path)),
    Slashed = byte_size(Trimmed) < byte_size(Path),
    case binary:matches(Trimmed, <<"/">>) of
        _ when Trimmed =:= <<>> ->
            {Path, <<>>, false};
        [] ->
            {<<".">>, Trimmed, Slashed};
        Slashes ->
            {At, 1} = last(Slashes),
            {binary:part(Trimmed, 0, At + 1),
             binary:part(Trimmed, At + 1, byte_size(Trimmed) - At - 1), Slashed}
    end.

trim_slashes(Path, Size) when Size > 0, binary_part(Path, Size - 1, 1) =:= <<"/">> ->
    trim_slashes(Path, Size - 1);
trim_slashes(Path, Size) ->
    binary:part(Path, 0, Size).

%% An encoded path's text: prim_file's encoding ends in the NUL its NIF hands to C.
text(Encoded) when byte_size(Encoded) > 0, binary_part(Encoded, byte_size(Encoded) - 1, 1) =:= <<0>> ->
    binary_part(Encoded, 0, byte_size(Encoded) - 1);
text(Path) ->
    Path.

%% A name prim_file gives back for a local path, as the raw name this module answers.
raw(Name) when is_binary(Name) -> Name;
raw(Name) -> text(prim_file:internal_name2native(Name)).

%% The NIF's names as a list: <<>> is the tree's root.
-spec names(names()) -> [binary()].
names(<<>>) -> [];
names(Names) -> binary:split(Names, <<"/">>, [global]).

%% A non-empty name list's directory names and last name.
split_last(NameList) ->
    {Dir, [Name]} = split_at(length(NameList) - 1, NameList),
    {Dir, Name}.

%% Following links ------------------------------------------------------------

%% One path's operation: Try runs on the grant the path lies on, its name list and its
%% text, Local on the text of a path that a link led to the NIF's own providers.
one(Grant, Place, Path, Try, Local) ->
    with_links(Grant, [Place], [text(Path)],
               fun(OnGrant, [{_, _, Names, _}], [Text]) -> Try(OnGrant, names(Names), Text) end,
               fun([Text]) -> Local(Text) end).

%% Runs Try on the grant and the places its paths lie on, and gives its answer, unless a
%% walk met a symbolic link it must follow (link()). The link's path is then rewritten
%% through the link and every path of the operation resolved again by prim_file's NIF:
%% Try runs again where they lie now, or Local runs on their texts when no grant holds
%% them. Each link counts towards one limit for the operation, the links met while
%% reading a link included, so following ends after ?LINKS_MAX links with eloop.
-spec with_links(grant(), [place()], [text()], Try, Local) -> term() when
      Try :: fun((grant(), [place()], [text()]) -> term() | link()),
      Local :: fun(([text()]) -> term()).
with_links(Grant, Places, Texts, Try, Local) ->
    with_links(Grant, Places, Texts, Try, Local, [0 || _ <- Places]).

with_links(Grant, Places, Texts, Try, Local, Followed) ->
    case Try(Grant, Places, Texts) of
        {link, Which, At} -> through(Grant, Places, Texts, Try, Local, Followed, Which, At);
        Answer -> Answer
    end.

through(Grant, Places, Texts, Try, Local, Followed, Which, At) ->
    case nth(Which, Followed) of
        ?LINKS_MAX -> {error, eloop};
        Count -> follow(Grant, Places, Texts, Try, Local, replaced(Which, Followed, Count + 1), Which, At)
    end.

follow(Grant, Places, Texts, Try, Local, Followed, Which, At) ->
    case link_path(Grant, nth(Which, Places), At, slashed(nth(Which, Texts))) of
        {ok, Next} ->
            Nexts = replaced(Which, Texts, Next),
            case prim_file:erx_resolve(Nexts) of
                {remote, NextGrant, NextPlace} ->
                    with_links(NextGrant, [NextPlace], Nexts, Try, Local, Followed);
                {remote, NextGrant, NextPlace, OtherPlace} ->
                    with_links(NextGrant, [NextPlace, OtherPlace], Nexts, Try, Local, Followed);
                local ->
                    Local(Nexts);
                {error, _} = Error ->
                    Error
            end;
        {link, _, Before} ->
            through(Grant, Places, Texts, Try, Local, Followed, Which, Before);
        {error, _} = Error ->
            Error
    end.

%% The path the link at a place's At'th name leads to: the link's text, joined to the
%% link's directory as a namespace path when it is relative, then the names after the
%% link, and a "/" when the path was written with one. The link's directory is the
%% entry's point and the names between the entry's root and the link; a link among the
%% root's own names has no such directory, and a relative one answers enoent. A link that
%% is empty answers enoent, as on Linux. Reading the link may meet an earlier one, which
%% is answered as a link() for the caller to follow.
link_path(Grant, {Point, Root, Names, _}, At, Slashed) ->
    {Through, After} = split_at(At + 1, names(Names)),
    case act(Grant, [{Through, nofollow}], fun([Fid]) -> {readlink, Fid} end) of
        {ok, <<>>} ->
            {error, enoent};
        {ok, <<"/", _/binary>> = Target} ->
            {ok, joined([Target | After], Slashed)};
        {ok, Target} ->
            RootCount = length(names(Root)),
            case length(Through) - 1 of
                Count when Count < RootCount ->
                    {error, enoent};
                Count ->
                    {Dir, _} = split_at(Count, Through),
                    {_, Below} = split_at(RootCount, Dir),
                    {ok, joined([Point | Below] ++ [Target | After], Slashed)}
            end;
        Other ->
            Other
    end.

%% The Which'th of the one or two paths of an operation, and their texts with it replaced.
nth(1, [First | _]) -> First;
nth(2, [_, Second]) -> Second.

replaced(1, [_ | Rest], New) -> [New | Rest];
replaced(2, [First, _], New) -> [First, New].

%% Pieces joined by "/", and a "/" after the last when Slashed. Doubled slashes are
%% harmless: the NIF drops empty names.
joined(Pieces, Slashed) ->
    iolist_to_binary([separated(Pieces) | case Slashed of
                                              true -> [<<"/">>];
                                              false -> []
                                          end]).

separated([Piece]) -> [Piece];
separated([Piece | Pieces]) -> [Piece, <<"/">> | separated(Pieces)].

%% The exchange ---------------------------------------------------------------

%% Reaches each path from one new attach, sends Act on the fids the paths reached, then
%% clunks every fid made, all together. The answer is the first path's failure or link,
%% in order, else Act's reply.
-spec act(grant(), [{[binary()], mode()}], fun(([non_neg_integer()]) -> tuple())) -> term().
act({_, Tree, _} = Grant, Paths, Act) ->
    {Root, Reaches, Walks} = reaches(Paths),
    Made = [Root | [New || {walk, _, New, _} <- Walks]],
    Requests = [attach(Root, Tree) | Walks]
        ++ [Act([Fid || {_, Fid, _} <- Reaches]) | [{clunk, Fid} || Fid <- Made]],
    [Attached | Replies] = exchange(Grant, Requests),
    {Walked, [Reply | _]} = split_at(length(Walks), Replies),
    on_ok(reached(Attached, Reaches, Walked), Reply).

%% As act/3, but First's requests go with the walks, and Then runs on the fids and
%% First's replies before the clunks are sent, for an operation of several round trips.
session({_, Tree, _} = Grant, Paths, First, Then) ->
    {Root, Reaches, Walks} = reaches(Paths),
    Fids = [Fid || {_, Fid, _} <- Reaches],
    Made = [Root | [New || {walk, _, New, _} <- Walks]],
    [Attached | Replies] = exchange(Grant, [attach(Root, Tree) | Walks] ++ First(Fids)),
    {Walked, Opened} = split_at(length(Walks), Replies),
    Answer = case reached(Attached, Reaches, Walked) of
                 ok -> Then(Fids, Opened);
                 Other -> Other
             end,
    _ = exchange(Grant, [{clunk, Fid} || Fid <- Made]),
    Answer.

attach(Fid, Tree) ->
    {attach, Fid, ?ERX_P9_NOFID, <<>>, Tree, 0}.

%% Each path's walks from the root fid, at most ?ERX_P9_MAXWELEM names each, each into a
%% new fid. A path of no names still walks, into a copy of the root, so every request
%% acts on a fid its own walk made.
reaches(Paths) ->
    Root = fid(),
    Reaches = [reach(Root, NameList, Mode) || {NameList, Mode} <- Paths],
    {Root, Reaches, [Walk || {Walks, _, _} <- Reaches, Walk <- Walks]}.

reach(From, NameList, Mode) ->
    {Walks, Last} = walks(From, NameList),
    {Walks, Last, Mode}.

walks(From, NameList) when length(NameList) =< ?ERX_P9_MAXWELEM ->
    New = fid(),
    {[{walk, From, New, NameList}], New};
walks(From, NameList) ->
    {First, Rest} = split_at(?ERX_P9_MAXWELEM, NameList),
    New = fid(),
    {More, Last} = walks(New, Rest),
    {[{walk, From, New, First} | More], Last}.

fid() ->
    prim_file:erx_fid().

%% ok when the attach and every walk reached their ends as their modes ask, else the
%% first failure, or the first link a path must follow, as a link() naming the path by
%% its place in Paths.
reached({ok, RootQid}, Reaches, Walked) ->
    reached_paths(Reaches, Walked, RootQid, 1);
reached({error, _} = Error, _, _) ->
    Error.

reached_paths([], _, _, _) ->
    ok;
reached_paths([{Walks, _, Mode} | Reaches], Walked, RootQid, Which) ->
    {Mine, Others} = split_at(length(Walks), Walked),
    case walked(Walks, Mine, RootQid, 0) of
        {ok, {Type, _, _}, Count} when Type band ?ERX_P9_QTSYMLINK =/= 0, Mode =/= nofollow ->
            {link, Which, Count - 1};
        {ok, {Type, _, _}, _} when Type band ?ERX_P9_QTDIR =:= 0, Mode =:= directory ->
            {error, enotdir};
        {ok, _, _} ->
            reached_paths(Reaches, Others, RootQid, Which + 1);
        {link, At} ->
            {link, Which, At};
        {error, _} = Error ->
            Error
    end.

%% The qid a chain of walks ends on and the names walked, or why it stopped. A walk that
%% lists fewer qids than names stopped at the name after its last qid: at a link, whose
%% name is the last one walked, or at a name missing from a directory, or because its
%% last qid is not a directory.
walked([], [], Qid, Count) ->
    {ok, Qid, Count};
walked([{walk, _, _, NameList} | Walks], [{ok, Qids} | Replies], Qid, Count) ->
    case {length(Qids) =:= length(NameList), Qids} of
        {true, []} -> walked(Walks, Replies, Qid, Count);
        {true, _} when Walks =/= [] -> chunk_end(last(Qids), Walks, Replies, Count + length(Qids));
        {true, _} -> walked(Walks, Replies, last(Qids), Count + length(Qids));
        {false, _} -> stopped(last(Qids), Count + length(Qids) - 1)
    end;
walked([_ | _], [{error, _} = Error | _], _, _) ->
    Error.

%% A walk of ?ERX_P9_MAXWELEM names that ends on a link stops there: the next walk would
%% start from the link's fid.
chunk_end({Type, _, _}, _, _, Count) when Type band ?ERX_P9_QTSYMLINK =/= 0 -> {link, Count - 1};
chunk_end(Qid, Walks, Replies, Count) -> walked(Walks, Replies, Qid, Count).

stopped({Type, _, _}, At) when Type band ?ERX_P9_QTSYMLINK =/= 0 -> {link, At};
stopped({Type, _, _}, _) when Type band ?ERX_P9_QTDIR =/= 0 -> {error, enoent};
stopped(_, _) -> {error, enotdir}.

%% Every request the client sends passes here, so what holds here holds for every
%% operation: a request the protocol's grammar refuses sends nothing and answers einval,
%% and a request that writes, through rights other than rw, sends nothing and answers
%% erofs, as the grant's own funnel would. Nothing else is sent; else each request goes
%% to an alias of its own, all at once, and the replies are answered in order.
exchange({Pid, _, Rights}, Requests) ->
    case refused(Requests, Rights) of
        none -> sent(Pid, Requests);
        Why -> [{error, Why} || _ <- Requests]
    end.

refused([], _) ->
    none;
refused([Request | Requests], Rights) ->
    case erx_9p_grammar:decode_request(Request) of
        {ok, _} when Rights =:= rw -> refused(Requests, Rights);
        {ok, _} ->
            case erx_9p_grammar:writes(Request) of
                true -> erofs;
                false -> refused(Requests, Rights)
            end;
        {error, einval} -> einval
    end.

%% Each reply is held to its request by the grammar; any other term is eio. Once the
%% grant's process has ended, a request whose reply has not arrived answers eio.
sent(Pid, Requests) ->
    Monitor = erlang:monitor(process, Pid),
    Sent = [{send(Pid, Request), Request} || Request <- Requests],
    Replies = collect(Sent, Monitor, live),
    erlang:demonitor(Monitor, [flush]),
    Replies.

send(Pid, Request) ->
    Alias = erlang:alias(),
    erlang:send(Pid, {erx_9p, Alias, self(), Request}),
    Alias.

%% Each alias stays active until its reply's shape arrives, so a message of another shape
%% sent to it cannot end it before the reply; the alias ends when the reply is taken.
collect([], _, _) ->
    [];
collect([{Alias, Request} | Sent], Monitor, live) ->
    receive
        {erx_9p, Alias, Reply} ->
            erlang:unalias(Alias),
            [decoded(Request, Reply) | collect(Sent, Monitor, live)];
        {'DOWN', Monitor, process, _, _} ->
            collect([{Alias, Request} | Sent], Monitor, gone)
    end;
collect([{Alias, Request} | Sent], Monitor, gone) ->
    receive
        {erx_9p, Alias, Reply} ->
            erlang:unalias(Alias),
            [decoded(Request, Reply) | collect(Sent, Monitor, gone)]
    after 0 ->
            erlang:unalias(Alias),
            [{error, eio} | collect(Sent, Monitor, gone)]
    end.

decoded(Request, Reply) ->
    case erx_9p_grammar:decode_reply(Request, Reply) of
        {ok, Valid} -> Valid;
        {error, eio} -> {error, eio}
    end.

is_u64(Value) -> is_integer(Value) andalso Value >= 0 andalso Value =< ?U64_MAX.

%% File information -----------------------------------------------------------

%% The record stock's build_file_info builds from a stat. The device number stands for
%% st_dev: the same for every path into one grant's tree.
file_info({Pid, Tree, _}, #{qid := {_, _, Inode}, mode := Mode, uid := Uid, gid := Gid,
                            nlink := Links, rdev := Rdev, size := Size,
                            atime_sec := ATime, mtime_sec := MTime, ctime_sec := CTime}) ->
    Type = file_type(Mode),
    #file_info{size = Size, type = Type, access = access(Type, Mode),
               atime = ATime, mtime = MTime, ctime = CTime, mode = Mode, links = Links,
               major_device = erlang:phash2({Pid, Tree}),
               minor_device = case Type of
                                  device -> Rdev;
                                  _ -> 0
                              end,
               inode = Inode, uid = Uid, gid = Gid}.

file_type(Mode) ->
    case Mode band ?ERX_P9_S_IFMT of
        ?ERX_P9_S_IFREG -> regular;
        ?ERX_P9_S_IFDIR -> directory;
        ?ERX_P9_S_IFLNK -> symlink;
        ?ERX_P9_S_IFCHR -> device;
        ?ERX_P9_S_IFBLK -> device;
        _ -> other
    end.

%% The owner's read and write bits, as stock's check_access reads them. A link's own
%% record takes the access of the file it leads to, from with_access/2.
access(symlink, _) -> undefined;
access(_, Mode) ->
    case {Mode band 8#400, Mode band 8#200} of
        {0, 0} -> none;
        {0, _} -> write;
        {_, 0} -> read;
        {_, _} -> read_write
    end.

%% Lists ----------------------------------------------------------------------

%% lists:split/2 and lists:last/1, which are not BIFs, and lists is not preloaded. Every
%% caller splits a list it built at no more than its length.
split_at(Count, List) ->
    split_at(Count, List, []).

split_at(0, List, Front) -> {lists:reverse(Front, []), List};
split_at(Count, [Head | Tail], Front) -> split_at(Count - 1, Tail, [Head | Front]).

last([Only]) -> Only;
last([_ | Tail]) -> last(Tail).
