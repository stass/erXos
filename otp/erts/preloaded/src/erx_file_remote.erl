%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% prim_file's operations on a path below a file server's grant (design-files.md, Erlang
%% clients). prim_file's NIF answers such a path with its mount entry's grant, {Pid, Tree,
%% Rights}, and the names from that tree's root, the entry's root included, and prim_file
%% calls the operation here, in the calling process. Rights are the entry's, so a read-only
%% bind of a writable grant arrives read-only, and a request that writes is refused with
%% erofs here, before anything is sent.
%%
%% Each path operation attaches a fid of its own, walks from it into new fids, acts on the
%% fid the walks reached and clunks every fid it made, all sent together. A request names
%% only a walk's new fid, which exists only if the walk passed every name, so after a walk
%% that stops early the request fails with ebadf and changes nothing, and the answer is the
%% walk's. Every fid is drawn from prim_file:erx_fid/0 and owned by the calling process, so
%% the grant clunks it if the process ends first.
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
%% Not yet done here (TODO.md): following a symbolic link the path meets, which answers
%% enotsup; a listing's entries for the mount points below a directory; open files,
%% read_file and set_cwd, and with set_cwd the working-directory step of del_dir.

-module(erx_file_remote).

-export([read_file_info/3, read_link/2, list_dir/2, write_file_info/3, make_dir/3,
         del_dir/3, delete/3, rename/5, make_link/5, make_symlink/4]).
-export([open/3, read_file/2, set_cwd/2]).
-export([last_name/1, names/1]).

-include("file.hrl").
-include("generated/erx_abi.hrl").

-type grant() :: {pid(), Tree :: binary(), Rights :: ro | rw | rx}.
%% A path's names from the tree's root, joined by "/": <<>> is the root.
-type names() :: binary().
%% A path as the caller wrote it, encoded as prim_file encodes it for its NIF, NUL-terminated.
-type path() :: binary().
-type posix() :: atom().

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

%% Reading -----------------------------------------------------------------

%% read_file_info (FollowLinks 1) and read_link_info (0): the #file_info{} of a stat, its
%% times POSIX seconds, for prim_file to convert.
-spec read_file_info(grant(), names(), 0 | 1) -> #file_info{} | {error, posix()}.
read_file_info(Grant, Names, FollowLinks) ->
    Follow = case FollowLinks of
                 1 -> follow;
                 _ -> nofollow
             end,
    case act(Grant, [{names(Names), Follow}], fun([Fid]) -> {getattr, Fid, ?INFO_MASK} end) of
        {ok, Attr} -> file_info(Grant, Attr);
        {error, _} = Error -> Error
    end.

-spec read_link(grant(), names()) -> {ok, binary()} | {error, posix()}.
read_link(Grant, Names) ->
    act(Grant, [{names(Names), nofollow}], fun([Fid]) -> {readlink, Fid} end).

%% The names of a directory's entries, "." and ".." left out, as raw names.
-spec list_dir(grant(), names()) -> {ok, [binary()]} | {error, posix()}.
list_dir({Pid, _, _} = Grant, Names) ->
    session(Grant, [{names(Names), follow}],
            fun([Fid]) -> [{lopen, Fid, 0}] end,
            fun([Fid], [{ok, _Qid, _Iounit}]) -> listing(Pid, Fid, 0, 0, []);
               (_, [{error, _} = Error]) -> Error
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
%% rest, except enotsup, which stock passes over.
-spec write_file_info(grant(), names(), #file_info{}) -> ok | {error, posix()}.
write_file_info({Pid, _, _} = Grant, Names, Info) ->
    case {writable(Grant), set_attrs(Info)} of
        {false, _} ->
            {error, erofs};
        {true, {error, _} = Error} ->
            Error;
        {true, {ok, Steps}} ->
            session(Grant, [{names(Names), follow}], fun(_) -> [] end,
                    fun([Fid], []) -> set_each(Pid, Fid, Steps) end)
    end.

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

-spec make_dir(grant(), names(), path()) -> ok | {error, posix()}.
make_dir(Grant, Names, Path) ->
    make(Grant, names(Names), Path,
         fun(DirFid, Name) -> {mkdir, DirFid, Name, 8#777 band bnot ?UMASK, 0} end).

-spec make_symlink(grant(), names(), Target :: binary(), path()) -> ok | {error, posix()}.
make_symlink(Grant, Names, EncodedTarget, Path) ->
    case text(EncodedTarget) of
        Target when byte_size(Target) > ?ERX_P9_SYMLINK_MAX ->
            {error, enametoolong};
        Target ->
            make(Grant, names(Names), Path,
                 fun(DirFid, Name) -> {symlink, DirFid, Name, Target, 0} end)
    end.

%% An operation that makes a name: a last "." or ".." answers eexist once the rest of the
%% path is a directory (step 2), as does the tree's root, which always exists.
make(Grant, NameList, Path, Request) ->
    case last_name_step(Path, fun(_) -> {error, eexist} end) of
        plain when NameList =:= [] -> {error, eexist};
        plain -> in_directory(Grant, NameList, Request);
        {error, _} = Error -> Error
    end.

-spec del_dir(grant(), names(), path()) -> ok | {error, posix()}.
del_dir(Grant, Names, Path) ->
    Answer = remove(Grant, names(Names), Path,
                    fun(<<".">>) -> {error, einval};
                       (<<"..">>) -> {error, enotempty}
                    end,
                    fun(DirFid, Name) -> {unlinkat, DirFid, Name, ?ERX_P9_AT_REMOVEDIR} end),
    case Answer of
        {error, enotempty} -> {error, eexist};
        _ -> Answer
    end.

-spec delete(grant(), names(), path()) -> ok | {error, posix()}.
delete(Grant, Names, Path) ->
    Answer = remove(Grant, names(Names), Path, fun(_) -> {error, eisdir} end,
                    fun(DirFid, Name) -> {unlinkat, DirFid, Name, 0} end),
    case Answer of
        {error, eisdir} -> {error, eperm};
        _ -> Answer
    end.

%% An operation that removes a name: a last "." or ".." answers Special's error once the
%% rest of the path is a directory (step 2), and the tree's root, a mount point, ebusy
%% (step 3).
remove(Grant, NameList, Path, Special, Request) ->
    case last_name_step(Path, Special) of
        plain when NameList =:= [] -> {error, ebusy};
        plain -> in_directory(Grant, NameList, Request);
        {error, _} = Error -> Error
    end.

-spec rename(grant(), names(), names(), path(), path()) -> ok | {error, posix()}.
rename(Grant, Names, OtherNames, Source, Destination) ->
    {From, To} = {names(Names), names(OtherNames)},
    Answer =
        case {text(Source), special(Source) orelse special(Destination)} of
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
                renamed(Grant, From, To)
        end,
    case Answer of
        {error, enotempty} -> {error, eexist};
        _ -> Answer
    end.

renamed(Grant, From, To) ->
    case writable(Grant) of
        true ->
            {FromDir, FromName} = split_last(From),
            {ToDir, ToName} = split_last(To),
            ok_of(act(Grant, [{FromDir, follow}, {ToDir, follow}],
                      fun([FromFid, ToFid]) -> {renameat, FromFid, FromName, ToFid, ToName} end));
        false ->
            {error, erofs}
    end.

%% A hard link: the existing path is reached first and not followed, as Linux's linkat
%% looks it up before the new name, so its failure is the answer; the new name is made as
%% make_dir makes one.
-spec make_link(grant(), names(), names(), path(), path()) -> ok | {error, posix()}.
make_link(Grant, Names, OtherNames, _Existing, New) ->
    {Existing, Made} = {names(Names), names(OtherNames)},
    case special(New) orelse Made =:= [] of
        true ->
            %% The new name is "." or "..", or the tree's root: once the existing path
            %% is reached, the answer is step 2's or the root's eexist.
            case act(Grant, [{Existing, nofollow}], fun([Fid]) -> {getattr, Fid, ?INFO_MASK} end) of
                {ok, _} -> existing_name(New);
                {error, _} = Error -> Error
            end;
        false ->
            linked(Grant, Existing, Made)
    end.

existing_name(New) ->
    case last_name_step(New, fun(_) -> {error, eexist} end) of
        plain -> {error, eexist};
        Error -> Error
    end.

linked(Grant, Existing, Made) ->
    case writable(Grant) of
        true ->
            {Dir, Name} = split_last(Made),
            ok_of(act(Grant, [{Existing, nofollow}, {Dir, follow}],
                      fun([Fid, DirFid]) -> {link, DirFid, Fid, Name} end));
        false ->
            {error, erofs}
    end.

%% Not yet served here: open files, read_file and a working directory on a grant.
-spec open(grant(), names(), list()) -> {error, enotsup}.
open(_Grant, _Names, _Modes) -> {error, enotsup}.

-spec read_file(grant(), names()) -> {error, enotsup}.
read_file(_Grant, _Names) -> {error, enotsup}.

-spec set_cwd(grant(), names()) -> {error, enotsup}.
set_cwd(_Grant, _Names) -> {error, enotsup}.

%% The error steps -----------------------------------------------------------

%% Step 2: a path whose last name, as the caller wrote it, is "." or ".." changes nothing;
%% the rest of the path must be a directory, and Special gives the answer past it. A plain
%% last name answers plain.
last_name_step(Path, Special) ->
    {Rest, Last} = last_name(Path),
    case special_name(Last) of
        true -> on_ok(directory(Rest), Special(Last));
        false -> plain
    end.

%% Request on the directory of NameList's last name and that name, unless the rights
%% refuse a write.
in_directory(Grant, NameList, Request) ->
    case writable(Grant) of
        true ->
            {Dir, Name} = split_last(NameList),
            ok_of(act(Grant, [{Dir, follow}], fun([DirFid]) -> Request(DirFid, Name) end));
        false ->
            {error, erofs}
    end.

writable({_, _, rw}) -> true;
writable({_, _, _}) -> false.

%% ok for a directory the path reaches after its links, as Linux finds a last name's
%% directory; the path goes through prim_file, so it may lie on any provider.
directory(Path) ->
    case prim_file:read_file_info(Path) of
        {ok, #file_info{type = directory}} -> ok;
        {ok, #file_info{}} -> {error, enotdir};
        {error, _} = Error -> Error
    end.

special(Path) ->
    {_, Last} = last_name(Path),
    special_name(Last).

special_name(<<".">>) -> true;
special_name(<<"..">>) -> true;
special_name(_) -> false.

rest(Path) ->
    {Rest, _} = last_name(Path),
    Rest.

on_ok(ok, Then) -> Then;
on_ok({error, _} = Error, _) -> Error.

ok_of({ok, _}) -> ok;
ok_of(Answer) -> Answer.

%% Paths ---------------------------------------------------------------------

%% A path's last name as the caller wrote it, past any trailing "/", and the rest of the
%% path, which names the last name's directory: up to and including the "/" before the
%% last name, or "." for a path of one name. A path of only "/" has no last name (<<>>)
%% and is its own rest, as is the empty path, which the NIF refuses before this is asked.
-spec last_name(path()) -> {Rest :: binary(), Last :: binary()}.
last_name(Encoded) when is_binary(Encoded) ->
    Path = text(Encoded),
    Trimmed = trim_slashes(Path, byte_size(Path)),
    case binary:matches(Trimmed, <<"/">>) of
        _ when Trimmed =:= <<>> ->
            {Path, <<>>};
        [] ->
            {<<".">>, Trimmed};
        Slashes ->
            {At, 1} = last(Slashes),
            {binary:part(Trimmed, 0, At + 1),
             binary:part(Trimmed, At + 1, byte_size(Trimmed) - At - 1)}
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

%% The NIF's names as a list: <<>> is the tree's root.
-spec names(names()) -> [binary()].
names(<<>>) -> [];
names(Names) -> binary:split(Names, <<"/">>, [global]).

%% A non-empty name list's directory names and last name.
split_last(NameList) ->
    {Dir, [Name]} = split_at(length(NameList) - 1, NameList),
    {Dir, Name}.

%% The exchange ---------------------------------------------------------------

%% Reaches each path from one new attach, sends Act on the fids the paths reached, then
%% clunks every fid made, all together. The answer is the first path's failure, in order,
%% else Act's reply.
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
                 {error, _} = Error -> Error
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
    Reaches = [reach(Root, NameList, Follow) || {NameList, Follow} <- Paths],
    {Root, Reaches, [Walk || {Walks, _, _} <- Reaches, Walk <- Walks]}.

reach(From, NameList, Follow) ->
    {Walks, Last} = walks(From, NameList),
    {Walks, Last, Follow}.

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

%% ok when the attach and every walk reached their ends, else the first failure. A path
%% marked follow that ends on a symbolic link, and any whose walk stops at one, would need
%% the link followed.
reached({ok, RootQid}, Reaches, Walked) ->
    reached_paths(Reaches, Walked, RootQid);
reached({error, _} = Error, _, _) ->
    Error.

reached_paths([], _, _) ->
    ok;
reached_paths([{Walks, _, Follow} | Reaches], Walked, RootQid) ->
    {Mine, Others} = split_at(length(Walks), Walked),
    case walked(Walks, Mine, RootQid) of
        {ok, {Type, _, _}} when Type band ?ERX_P9_QTSYMLINK =/= 0, Follow =:= follow ->
            unfollowed();
        {ok, _} ->
            reached_paths(Reaches, Others, RootQid);
        link ->
            unfollowed();
        {error, _} = Error ->
            Error
    end.

%% The qid a chain of walks ends on, or why it stopped. A walk that lists fewer qids than
%% names stopped at the name after its last qid: at a link, or at a name missing from a
%% directory, or because its last qid is not a directory.
walked([], [], Qid) ->
    {ok, Qid};
walked([{walk, _, _, NameList} | Walks], [{ok, Qids} | Replies], Qid) ->
    case {length(Qids) =:= length(NameList), Qids} of
        {true, []} -> walked(Walks, Replies, Qid);
        {true, _} -> walked(Walks, Replies, last(Qids));
        {false, _} -> stopped(last(Qids))
    end;
walked([_ | _], [{error, _} = Error | _], _) ->
    Error.

stopped({Type, _, _}) when Type band ?ERX_P9_QTSYMLINK =/= 0 -> link;
stopped({Type, _, _}) when Type band ?ERX_P9_QTDIR =/= 0 -> {error, enoent};
stopped(_) -> {error, enotdir}.

%% A path that meets a symbolic link: the client does not yet follow links (TODO.md).
unfollowed() ->
    {error, enotsup}.

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
%% record would carry its target's access, which needs the link followed: unknown.
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
