%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% prim_file's operations on a path below a file server's grant (design-files.md, Erlang
%% clients). prim_file's NIF answers such a path with its mount entry's grant, {Pid, Tree,
%% Rights}, and its place, {Point, Root, Names}: the entry's point in the namespace, the
%% entry's root in the tree, and the path's names from the tree's root, the entry's root
%% included. prim_file calls the operation here, in the calling process, with the path as
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
%% with POSIX times, raw names), so prim_file converts both alike. A server's reply is
%% untrusted: a reply of any other shape answers eio and raises nothing in the caller, which
%% may be the code server.
%%
%% This module is preloaded and calls only BIFs and preloaded modules (T6 of
%% design-tmp.md), which test/host/erx_file_remote_test.rb checks with xref.
%%
%% Not yet done here (TODO.md): a listing's entries for the mount points below a
%% directory; open files, read_file and set_cwd, and with set_cwd the working-directory
%% step of del_dir.

-module(erx_file_remote).

-export([read_file_info/4, read_link/3, list_dir/3, write_file_info/4, make_dir/3,
         del_dir/3, delete/3, rename/5, make_link/5, make_symlink/4]).
-export([open/3, read_file/2, set_cwd/2]).
-export([last_name/1, names/1]).

-include("file.hrl").
-include("generated/erx_abi.hrl").

-type grant() :: {pid(), Tree :: binary(), Rights :: ro | rw | rx}.
%% A path's names from the tree's root, joined by "/": <<>> is the root.
-type names() :: binary().
%% Where a path lies on its grant: the entry maps the namespace path Point to the tree's
%% names Root, and Names begins with Root.
-type place() :: {Point :: binary(), Root :: names(), Names :: names()}.
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
        fun({Pid, _, _} = OnGrant, NameList, Text) ->
                session(OnGrant, [{NameList, followed(Text)}],
                        fun([Fid]) -> [{lopen, Fid, 0}] end,
                        fun([Fid], [{ok, _Qid, _Iounit}]) -> listing(Pid, Fid, 0, 0, []);
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
listing(Pid, Fid, Offset, Count, Pages) ->
    case exchange(Pid, [{readdir, Fid, Offset, ?READDIR_COUNT}]) of
        [{ok, []}] ->
            {ok, [Name || Page <- lists:reverse(Pages, []), Name <- Page]};
        [{ok, Entries}] ->
            {_, Next, _, _} = last(Entries),
            Page = [Name || {_, _, _, Name} <- Entries, Name =/= <<".">>, Name =/= <<"..">>],
            listing(Pid, Fid, Next, Count + length(Entries), [Page | Pages]);
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
        fun({Pid, _, _} = OnGrant, NameList, Text) ->
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
                                fun([Fid], []) -> set_each(Pid, Fid, Steps) end)
                end
        end,
        fun(Text) -> prim_file:write_file_info(Text, Info, [{time, posix}]) end).

set_each(_, _, []) ->
    ok;
set_each(Pid, Fid, [Attr | Steps]) ->
    case exchange(Pid, [{setattr, Fid, Attr}]) of
        [ok] -> set_each(Pid, Fid, Steps);
        [{error, enotsup}] -> set_each(Pid, Fid, Steps);
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
    Answer = one(Grant, Place, Path,
                 fun(OnGrant, NameList, Text) ->
                         remove(OnGrant, NameList, Text,
                                fun(<<".">>) -> {error, einval};
                                   (<<"..">>) -> {error, enotempty}
                                end,
                                fun(Names) ->
                                        in_directory(OnGrant, Names,
                                                     fun(DirFid, Name) ->
                                                             {unlinkat, DirFid, Name, ?ERX_P9_AT_REMOVEDIR}
                                                     end)
                                end)
                 end,
                 fun(Text) -> prim_file:del_dir(Text) end),
    case Answer of
        {error, enotempty} -> {error, eexist};
        _ -> Answer
    end.

%% A last name written with a trailing "/" is not followed and removes nothing: eisdir
%% for a directory, enotdir for anything else, a link included, as Linux's unlink answers.
-spec delete(grant(), place(), path()) -> ok | {error, posix()}.
delete(Grant, Place, Path) ->
    Answer = one(Grant, Place, Path,
                 fun(OnGrant, NameList, Text) ->
                         remove(OnGrant, NameList, Text, fun(_) -> {error, eisdir} end,
                                fun(Names) ->
                                        case slashed(Text) of
                                            false ->
                                                in_directory(OnGrant, Names,
                                                             fun(DirFid, Name) ->
                                                                     {unlinkat, DirFid, Name, 0}
                                                             end);
                                            true ->
                                                looked(OnGrant, Names, fun not_a_directory/1)
                                        end
                                end)
                 end,
                 fun(Text) -> prim_file:delete(Text) end),
    case Answer of
        {error, eisdir} -> {error, eperm};
        _ -> Answer
    end.

%% An operation that removes a name: a last "." or ".." answers Special's error once the
%% rest of the path is a directory (step 2), and the tree's root, a mount point, ebusy
%% (step 3); else Remove runs on the names, unless the rights refuse a write.
remove(Grant, NameList, Text, Special, Remove) ->
    case last_name_step(Text, Special) of
        plain when NameList =:= [] -> {error, ebusy};
        plain -> if_writable(Grant, [{dir_of(NameList), follow}], fun() -> Remove(NameList) end);
        {error, _} = Error -> Error
    end.

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

renamed(Grant, [{_, _, Names}, {_, _, OtherNames}], [Source, Destination]) ->
    {From, To} = {names(Names), names(OtherNames)},
    case {Source, special(Source) orelse special(Destination)} of
        {<<"/">>, _} ->
            %% Step 1: stock's own answer for a failed rename of "/".
            {error, einval};
        {_, true} ->
            %% Both paths' directories first, the source's before, as Linux finds them
            %% before it looks at either last name.
            case directory(rest(Source)) of
                ok -> on_ok(directory(rest(Destination)), {error, ebusy});
                Error -> Error
            end;
        {_, false} when From =:= []; To =:= [] ->
            {error, ebusy};
        {_, false} ->
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

linked(Grant, [{_, _, Names}, {_, _, OtherNames}], [ExistingText, NewText]) ->
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

%% Not yet served here: open files, read_file and a working directory on a grant.
-spec open(grant(), place(), list()) -> {error, enotsup}.
open(_Grant, _Place, _Modes) -> {error, enotsup}.

-spec read_file(grant(), place()) -> {error, enotsup}.
read_file(_Grant, _Place) -> {error, enotsup}.

-spec set_cwd(grant(), place()) -> {error, enotsup}.
set_cwd(_Grant, _Place) -> {error, enotsup}.

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
               fun(OnGrant, [{_, _, Names}], [Text]) -> Try(OnGrant, names(Names), Text) end,
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
link_path(Grant, {Point, Root, Names}, At, Slashed) ->
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
act({Pid, Tree, _}, Paths, Act) ->
    {Root, Reaches, Walks} = reaches(Paths),
    Made = [Root | [New || {walk, _, New, _} <- Walks]],
    Requests = [attach(Root, Tree) | Walks]
        ++ [Act([Fid || {_, Fid, _} <- Reaches]) | [{clunk, Fid} || Fid <- Made]],
    [Attached | Replies] = exchange(Pid, Requests),
    {Walked, [Reply | _]} = split_at(length(Walks), Replies),
    on_ok(reached(Attached, Reaches, Walked), Reply).

%% As act/3, but First's requests go with the walks, and Then runs on the fids and
%% First's replies before the clunks are sent, for an operation of several round trips.
session({Pid, Tree, _}, Paths, First, Then) ->
    {Root, Reaches, Walks} = reaches(Paths),
    Fids = [Fid || {_, Fid, _} <- Reaches],
    Made = [Root | [New || {walk, _, New, _} <- Walks]],
    [Attached | Replies] = exchange(Pid, [attach(Root, Tree) | Walks] ++ First(Fids)),
    {Walked, Opened} = split_at(length(Walks), Replies),
    Answer = case reached(Attached, Reaches, Walked) of
                 ok -> Then(Fids, Opened);
                 Other -> Other
             end,
    _ = exchange(Pid, [{clunk, Fid} || Fid <- Made]),
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

%% Sends each request to an alias of its own, all at once, and answers their replies in
%% order, each checked against its request. Once the grant's process has ended, a request
%% whose reply has not arrived answers eio.
exchange(Pid, Requests) ->
    Monitor = erlang:monitor(process, Pid),
    Sent = [{send(Pid, Request), Request} || Request <- Requests],
    Replies = collect(Sent, Monitor, live),
    erlang:demonitor(Monitor, [flush]),
    Replies.

send(Pid, Request) ->
    Alias = erlang:alias([reply]),
    erlang:send(Pid, {erx_9p, Alias, self(), Request}),
    Alias.

collect([], _, _) ->
    [];
collect([{Alias, Request} | Sent], Monitor, live) ->
    receive
        {erx_9p, Alias, Reply} ->
            [checked(Request, Reply) | collect(Sent, Monitor, live)];
        {'DOWN', Monitor, process, _, _} ->
            collect([{Alias, Request} | Sent], Monitor, gone)
    end;
collect([{Alias, Request} | Sent], Monitor, gone) ->
    receive
        {erx_9p, Alias, Reply} ->
            [checked(Request, Reply) | collect(Sent, Monitor, gone)]
    after 0 ->
            erlang:unalias(Alias),
            [{error, eio} | collect(Sent, Monitor, gone)]
    end.

%% A reply in the shape its request's operation answers, with what this module reads of
%% it in range; any other term is eio.
checked(_, {error, Posix}) when is_atom(Posix) ->
    {error, Posix};
checked({attach, _, _, _, _, _}, {ok, Qid} = Reply) ->
    if_valid(is_qid(Qid), Reply);
checked({walk, _, _, NameList}, {ok, Qids} = Reply) ->
    if_valid(is_list_of(fun is_qid/1, Qids, length(NameList))
             andalso (NameList =:= [] orelse Qids =/= []), Reply);
checked({getattr, _, _}, {ok, Attr} = Reply) ->
    if_valid(is_attr(Attr), Reply);
checked({readlink, _}, {ok, Target} = Reply) ->
    if_valid(is_binary(Target) andalso byte_size(Target) =< ?ERX_P9_SYMLINK_MAX
             andalso binary:match(Target, <<0>>) =:= nomatch, Reply);
checked({lopen, _, _}, {ok, Qid, Iounit} = Reply) ->
    if_valid(is_qid(Qid) andalso is_u(Iounit, 32), Reply);
checked({readdir, _, _, _}, {ok, Entries} = Reply) ->
    if_valid(is_list_of(fun is_dirent/1, Entries, ?ERX_P9_DIRENTS_MAX), Reply);
checked({mkdir, _, _, _, _}, {ok, Qid} = Reply) ->
    if_valid(is_qid(Qid), Reply);
checked({symlink, _, _, _, _}, {ok, Qid} = Reply) ->
    if_valid(is_qid(Qid), Reply);
checked(Request, ok) ->
    case element(1, Request) of
        Operation when Operation =:= unlinkat; Operation =:= link; Operation =:= renameat;
                       Operation =:= setattr; Operation =:= clunk -> ok;
        _ -> {error, eio}
    end;
checked(_, _) ->
    {error, eio}.

if_valid(true, Reply) -> Reply;
if_valid(false, _) -> {error, eio}.

is_qid({Type, Version, Path}) -> is_u(Type, 8) andalso is_u(Version, 32) andalso is_u64(Path);
is_qid(_) -> false.

%% A listed name is one name: a caller joins it to the directory's path (file:del_dir_r/1
%% does), so a "/", an empty name or a NUL would name another file.
is_dirent({Qid, Offset, Type, Name}) ->
    is_qid(Qid) andalso is_u64(Offset) andalso is_u(Type, 8) andalso is_entry_name(Name);
is_dirent(_) -> false.

is_entry_name(Name) ->
    is_binary(Name) andalso Name =/= <<>> andalso byte_size(Name) =< ?ERX_P9_STRING_MAX
        andalso binary:match(Name, [<<"/">>, <<0>>]) =:= nomatch.

is_attr(#{qid := Qid, mode := Mode, uid := Uid, gid := Gid, nlink := Links, rdev := Rdev,
          size := Size, atime_sec := ATime, mtime_sec := MTime, ctime_sec := CTime}) ->
    is_qid(Qid) andalso is_u(Mode, 32) andalso is_u(Uid, 32) andalso is_u(Gid, 32)
        andalso is_u64(Links) andalso is_u64(Rdev) andalso is_u64(Size)
        andalso is_u64(ATime) andalso is_u64(MTime) andalso is_u64(CTime);
is_attr(_) -> false.

%% Walks at most Left elements of a proper list, and refuses any other term.
is_list_of(_, [], _) -> true;
is_list_of(Check, [Head | Tail], Left) when Left > 0 ->
    Check(Head) andalso is_list_of(Check, Tail, Left - 1);
is_list_of(_, _, _) -> false.

is_u64(Value) -> is_u(Value, 64).

is_u(Value, Bits) -> is_integer(Value) andalso Value >= 0 andalso Value < (1 bsl Bits).

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
