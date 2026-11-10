%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% prim_file's operations on a path below a file server's grant (design-files.md, Erlang
%% clients). erx_path resolves the path in prim_file, and this module is its executor on
%% a grant: it performs the walks and link reads the resolver asks for (walk/2 and
%% link_text/2), and runs an operation at the resolver's last action, which names the
%% names to walk from the tree's root, the entry's root names first: a target, {target,
%% Names}, or a directory and its last name, {parent, Names, Name}. The grant is {Pid,
%% Tree, Rights} as the path's entry holds it, so a read-only bind of a writable grant
%% arrives read-only, and a request that writes is refused with erofs here, before
%% anything is sent. This module never reads a path's text.
%%
%% Each operation attaches a fid of its own, walks from it into new fids, acts on the fid
%% the walks reached and clunks every fid it made, all sent together. A request names
%% only a walk's new fid, which exists only if the walk passed every name, so after a walk
%% that stops early the request fails with ebadf and changes nothing. The operation then
%% answers {resume, Which, Reply}, the walk's reply for the Which'th of its paths, as it
%% does when the walk ends on a link it follows, or a parent's walk on a name that is not
%% a directory;
%% prim_file calls that path's resumption with the reply, and the resolver answers the
%% walk's error or follows the link. Every fid is drawn from prim_file:erx_fid/0 and
%% owned by the calling process, so the grant clunks it if the process ends first.
%%
%% The answers are stock prim_file's on a Unix host whose path resolution is FreeBSD's,
%% by design-files.md's error steps, and the results have the shapes prim_file's NIF
%% returns for a local path (a #file_info{} with POSIX times, raw names), so prim_file
%% converts both alike.
%%
%% An open file is OTP's #file_descriptor{} with this module as its module, so file
%% dispatches its operations here. Its data holds the grant, the fid it owns, the
%% opening process, which alone may use it, and an atomics array holding the offset and
%% whether the file is closed. Each read or write is one request of at most 64 KiB, and
%% a write's reply sets the offset by the rule of design-files.md's Open files and
%% offsets (offset_after/4).
%%
%% Every request passes exchange/2, which checks it against the generated protocol
%% grammar, erx_9p_grammar, refuses a walk that names "..", which the grammar lets a
%% server take, so no walk this client sends names ".", ".." or an empty name, and sends
%% nothing that writes through rights other than rw; the grammar holds each reply to its
%% request. A server's reply is untrusted: a reply of any other shape answers eio and
%% raises nothing in the caller, which may be the code server. A server of another
%% domain's reply arrives in the envelope of edit 16, {erx_origin, D, {erx_9p, Alias,
%% Reply}}, and is taken as a bare one is, whatever D, as gen takes a call's reply (edit
%% 58): each request has an alias of its own, handed only to the server, and an alias
%% cannot be guessed (edit 17), so whoever answers at it answers for the server.
%%
%% This module and the grammar are preloaded and call only BIFs and preloaded modules
%% (T6 of design-tmp.md), which test/host/erx_file_remote_test.rb checks with xref.
%%
%% Not yet done here (TODO.md): a listing's entries for the mount points below a
%% directory.

-module(erx_file_remote).

%% erx_path's callbacks on a grant, and how prim_file reads a walk's reply; refused/2 and
%% walk_reply/2 for the fuzz target (test/erlang/erx_file_remote_fuzz.erl), and sent/2,
%% the exchange with a server, for it and for test/erlang/erx_file_remote_tests.erl.
-export([walk/2, link_text/2, passed/2, refused/2, walk_reply/2, sent/2]).
-export([read_file_info/3, read_link/2, list_dir/2, write_file_info/3, make_dir/2,
         del_dir/2, delete/2, rename/3, make_link/3, make_symlink/3]).
-export([open/3, read_file/2, set_cwd/2, identity/2]).
%% An open file's operations, which file dispatches to by its descriptor's module.
-export([close/1, read/2, read_line/1, pread/2, pread/3, write/2, pwrite/2, pwrite/3,
         position/2, truncate/1, sync/1, datasync/1, advise/4, allocate/3,
         read_handle_info/2, copy/3, sendfile/8, ipread_s32bu_p32bu/3]).

-include("file.hrl").
-include("generated/erx_abi.hrl").

-type grant() :: {pid(), Tree :: binary(), Rights :: ro | rw | rx}.
%% Where the resolver's last action lies on the grant, as names from the tree's root.
-type where() :: {target, [binary()]} | {parent, [binary()], Name :: binary()}.
%% erx_path's reply of a walk: the kind of each name passed, and how it ended.
-type reply() :: {[directory | link | other], ok | {error, posix()}}.
%% The walk of one of an operation's paths did not pass as its mode asks.
-type resume() :: {resume, 1 | 2, reply()}.
%% A path as prim_file encodes it for its NIF, NUL-terminated: a symbolic link's target.
-type path() :: binary().
-type posix() :: atom().
%% How a walk's last name must be for the operation to stand: anything (nofollow), not a
%% link, which the operation follows (follow), or a directory, a parent's (directory).
-type mode() :: follow | nofollow | directory.

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
%% The most bytes one read answers, 4 KiB short of 2 GiB: a larger count reads short, as a
%% read may, and the caller reads on.
-define(READ_MAX, 16#7ffff000).
%% What read_file asks for at a time of a file whose size is 0, as stock's NIF does.
-define(END_PIECE, 16384).

%% Reading -----------------------------------------------------------------

%% read_file_info (Follow true) and read_link_info: the #file_info{} of a stat, its times
%% POSIX seconds, for prim_file to convert. A link's own record carries no access, which
%% prim_file takes from the file the link leads to, as stock's access(2) follows links.
-spec read_file_info(grant(), where(), boolean()) -> #file_info{} | {error, posix()} | resume().
read_file_info(Grant, {target, Names}, Follow) ->
    Mode = case Follow of
               true -> follow;
               false -> nofollow
           end,
    case act(Grant, [{Names, Mode}], fun stat/1) of
        {ok, Attr} -> followed_info(file_info(Grant, Attr), Mode);
        Other -> Other
    end.

%% A walk that followed every link ends on a file that is not one; a server that says
%% otherwise answers eio, so prim_file never meets a link it would follow again.
followed_info(#file_info{type = symlink}, follow) -> {error, eio};
followed_info(Info, _) -> Info.

%% A link's text. A path written with a trailing "/" reaches a directory, which is not a
%% link, and the server answers einval, as readlink answers for any file not a link.
-spec read_link(grant(), where()) -> {ok, binary()} | {error, posix()} | resume().
read_link(Grant, {target, Names}) ->
    act(Grant, [{Names, nofollow}], fun([Fid]) -> {readlink, Fid} end).

%% The names of a directory's entries, "." and ".." left out, as raw names.
-spec list_dir(grant(), where()) -> {ok, [binary()]} | {error, posix()} | resume().
list_dir(Grant, {target, Names}) ->
    session(Grant, [{Names, follow}], fun([Fid]) -> [{lopen, Fid, 0}] end,
            fun([Fid], [{ok, _Qid, _Iounit}]) -> listing(Grant, Fid, 0, 0, []);
               (_, [{error, _} = Error]) -> Error
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
%% rest, except enotsup, which stock passes over. On a read-only entry the path is walked
%% first, so a link leads the resolver to the entry it reaches, and only a path that ends
%% on this entry answers erofs.
-spec write_file_info(grant(), where(), #file_info{}) -> ok | {error, posix()} | resume().
write_file_info(Grant, {target, Names}, Info) ->
    Walk = [{Names, follow}],
    case {writable(Grant), set_attrs(Info)} of
        {_, {error, _} = Error} ->
            Error;
        {false, _} ->
            on_ok(ok_of(act(Grant, Walk, fun stat/1)), {error, erofs});
        {true, {ok, Steps}} ->
            session(Grant, Walk, fun(_) -> [] end, fun([Fid], []) -> set_each(Grant, Fid, Steps) end)
    end.

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

-spec make_dir(grant(), where()) -> ok | {error, posix()} | resume().
make_dir(Grant, Where) ->
    made(Grant, Where, fun(DirFid, Name) -> {mkdir, DirFid, Name, 8#777 band bnot ?UMASK, 0} end).

-spec make_symlink(grant(), where(), Target :: path()) -> ok | {error, posix()} | resume().
make_symlink(Grant, Where, EncodedTarget) ->
    case text(EncodedTarget) of
        Target when byte_size(Target) > ?ERX_P9_SYMLINK_MAX ->
            {error, enametoolong};
        Target ->
            made(Grant, Where, fun(DirFid, Name) -> {symlink, DirFid, Name, Target, 0} end)
    end.

%% Makes the last name in its directory. On an entry that is not rw nothing that writes is
%% sent: the name is looked up, as FreeBSD's namei looks up CREATE's last name on a
%% read-only mount, so a name that exists answers eexist and a missing one erofs.
made(Grant, {parent, Dir, Name}, Make) ->
    case writable(Grant) of
        true -> ok_of(act(Grant, [{Dir, directory}], fun([DirFid]) -> Make(DirFid, Name) end));
        false -> exists(looked_up(Grant, Dir, Name, nofollow))
    end.

%% A last name on an entry that is not rw: its attributes, erofs when its directory holds
%% no such name, or the walk's resumption, its reply over the directory's names and the
%% last name as the resolver reads a parent's.
looked_up(Grant, Dir, Name, Mode) ->
    case act(Grant, [{Dir ++ [Name], Mode}], fun stat/1) of
        {resume, 1, {Kinds, {error, enoent}}} when length(Kinds) =:= length(Dir) -> {error, erofs};
        Other -> Other
    end.

exists({ok, _}) -> {error, eexist};
exists(Other) -> Other.

%% unlink and rmdir of the last name: the server answers for a name of the wrong type,
%% and prim_file turns the answers by the error steps.
-spec delete(grant(), where()) -> ok | {error, posix()} | resume().
delete(Grant, {parent, Dir, Name}) ->
    if_writable(Grant, [{Dir, directory}], fun([DirFid]) -> {unlinkat, DirFid, Name, 0} end).

-spec del_dir(grant(), where()) -> ok | {error, posix()} | resume().
del_dir(Grant, {parent, Dir, Name}) ->
    if_writable(Grant, [{Dir, directory}],
                fun([DirFid]) -> {unlinkat, DirFid, Name, ?ERX_P9_AT_REMOVEDIR} end).

%% A rename between two parents on this grant.
-spec rename(grant(), where(), where()) -> ok | {error, posix()} | resume().
rename(Grant, {parent, FromDir, FromName}, {parent, ToDir, ToName}) ->
    if_writable(Grant, [{FromDir, directory}, {ToDir, directory}],
                fun([FromFid, ToFid]) -> {renameat, FromFid, FromName, ToFid, ToName} end).

%% A hard link to the file the existing path reaches, its last link followed. The link
%% is sent only once both walks have passed, so it never links a link the resolver then
%% follows. On an entry that is not rw the new name is looked up as made/3 looks it up.
-spec make_link(grant(), where(), where()) -> ok | {error, posix()} | resume().
make_link(Grant, {target, Names}, {parent, Dir, Name}) ->
    case writable(Grant) of
        true ->
            session(Grant, [{Names, follow}, {Dir, directory}], fun(_) -> [] end,
                    fun([Fid, DirFid], []) -> ok_of(only(exchange(Grant, [{link, DirFid, Fid, Name}]))) end);
        false ->
            case act(Grant, [{Names, follow}], fun stat/1) of
                {ok, _} ->
                    case exists(looked_up(Grant, Dir, Name, nofollow)) of
                        {resume, 1, Reply} -> {resume, 2, Reply};
                        Answer -> Answer
                    end;
                Other ->
                    Other
            end
    end.

only([Reply]) -> Reply.

%% Sends Act on the fids the walks reach, on an entry that allows writes. On any other the
%% walks run first, sending nothing that writes, so a link among them leads the resolver
%% to the entry it reaches and a missing directory answers before erofs, as FreeBSD's
%% lookup refuses the last name of DELETE and RENAME on a read-only mount.
if_writable({_, _, rw} = Grant, Walks, Act) ->
    ok_of(act(Grant, Walks, Act));
if_writable(Grant, Walks, _) ->
    on_ok(ok_of(act(Grant, Walks, fun stat/1)), {error, erofs}).

writable({_, _, rw}) -> true;
writable({_, _, _}) -> false.

on_ok(ok, Then) -> Then;
on_ok(Other, _) -> Other.

ok_of({ok, _}) -> ok;
ok_of(Answer) -> Answer.

%% Open files ----------------------------------------------------------------

%% Opens the file as stock's NIF opens one, with the flags for the modes. An open that
%% does not write is a target, opened with lopen. One that writes is a parent: it walks
%% the last name's directory and sends lcreate, which creates the file or opens the one
%% already there in one step. A link there answers eloop, which hands the link to the
%% resolver as one more kind past the directory's, unless the open is exclusive, which
%% answers eexist, as O_EXCL does. On an entry that is not rw the name is looked up as
%% FreeBSD's vn_open looks before it refuses: eexist for an exclusive open of any name
%% there, eisdir for a directory, and erofs for a file or a missing name. The descriptor
%% names this module, so file dispatches the open file's operations here.
-spec open(grant(), where(), list()) -> {ok, #file_descriptor{}} | {error, posix()} | resume().
open(Grant, {target, Names}, Modes) ->
    #{flags := Flags} = Open = open_mode(Modes),
    described(kept(Grant, {Names, follow}, fun(Fid) -> {lopen, Fid, Flags} end), Grant, Open);
open(Grant, {parent, Dir, Name}, Modes) ->
    case open_mode(Modes) of
        #{directory := true} ->
            %% A directory is never opened to write: einval, before anything is walked.
            {error, einval};
        #{flags := Flags} = Open ->
            created(Grant, Dir, Name, exclusive(Flags), Open)
    end.

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

created({_, _, rw} = Grant, Dir, Name, Exclusive, #{flags := Flags} = Open) ->
    Create = fun(DirFid) -> {lcreate, DirFid, Name, Flags, 8#666 band bnot ?UMASK, 0} end,
    case {kept(Grant, {Dir, directory}, Create), Exclusive} of
        {{error, eloop}, false} -> {resume, 1, {[directory || _ <- Dir] ++ [link], ok}};
        {{error, eloop}, true} -> {error, eexist};
        {Kept, _} -> described(Kept, Grant, Open)
    end;
created(Grant, Dir, Name, Exclusive, _) ->
    Mode = case Exclusive of
               true -> nofollow;
               false -> follow
           end,
    case looked_up(Grant, Dir, Name, Mode) of
        {ok, _} when Exclusive -> {error, eexist};
        {ok, #{mode := Type}} when Type band ?ERX_P9_S_IFMT =:= ?ERX_P9_S_IFDIR -> {error, eisdir};
        {ok, _} -> {error, erofs};
        Other -> Other
    end.

exclusive(Flags) -> Flags band ?ERX_P9_O_EXCL =/= 0.

stat([Fid | _]) -> {getattr, Fid, ?INFO_MASK}.

%% Reaches a path into a new fid and sends Open on that fid with the walks. The fid is
%% kept for the caller when the walk passed and Open succeeded, as {ok, Fid, Qid,
%% Iounit}; otherwise it is clunked with the walk's other fids, and the answer is the
%% attach's failure, the walk's resumption or Open's failure.
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
%% eisdir (error step 6), as stock's open answers, and opening anything else with it
%% enotdir, as O_DIRECTORY does.
described({ok, Fid, {Type, _, _}, _}, Grant, #{directory := false, type_check := true})
  when Type band ?ERX_P9_QTDIR =/= 0 ->
    _ = exchange(Grant, [{clunk, Fid}]),
    {error, eisdir};
described({ok, Fid, {Type, _, _}, _}, Grant, #{directory := true}) when Type band ?ERX_P9_QTDIR =:= 0 ->
    _ = exchange(Grant, [{clunk, Fid}]),
    {error, enotdir};
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
%% file is open, or to its end if that comes first; a file whose size is 0, as a /proc
%% file's is, is read to its end.
-spec read_file(grant(), where()) -> {ok, binary()} | {error, posix()} | resume().
read_file(Grant, Where) ->
    case open(Grant, Where, [read]) of
        {ok, Fd} ->
            Contents = on_open(Fd, fun(File) -> contents(File) end),
            _ = close(Fd),
            Contents;
        Other ->
            Other
    end.

contents(File) ->
    case size_of(File) of
        {ok, 0} -> to_end(File, 0, []);
        {ok, Size} -> contents(File, 0, Size, []);
        Error -> Error
    end.

%% Stock's read_file reads a file of size 0 in 16 KiB pieces until a read comes up short.
to_end(File, Offset, Parts) ->
    case read_at(File, Offset, ?END_PIECE) of
        {ok, Data} when byte_size(Data) =:= ?END_PIECE -> to_end(File, Offset + ?END_PIECE, [Data | Parts]);
        {ok, Data} -> {ok, iolist_to_binary(lists:reverse(Parts, [Data]))};
        eof -> {ok, iolist_to_binary(lists:reverse(Parts, []))};
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

%% Sets the size to the offset. Through a file not opened for writing, einval, as FreeBSD's
%% kern_ftruncate answers, sending nothing.
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

%% The working directory (design-files.md, Erlang clients): chdir's checks on what the
%% path reaches, its last link followed: a directory, which the domain's user may search,
%% as the owner whose permission bits a server checks (design-tmp.md, Permissions); else
%% enotdir or eacces. prim_file stores the place the resolution reached.
-spec set_cwd(grant(), where()) -> ok | {error, posix()} | resume().
set_cwd(Grant, {target, Names}) ->
    case act(Grant, [{Names, follow}], fun stat/1) of
        {ok, #{mode := Mode}} when Mode band ?ERX_P9_S_IFMT =/= ?ERX_P9_S_IFDIR -> {error, enotdir};
        {ok, #{mode := Mode}} when Mode band 8#100 =:= 0 -> {error, eacces};
        {ok, _} -> ok;
        Other -> Other
    end.

%% Error step 5's identity of the directory a path reaches, its last link followed: its
%% grant's pid and tree and the qid path a getattr answers.
-spec identity(grant(), where()) -> {pid(), binary(), non_neg_integer()} | {error, posix()} | resume().
identity({Pid, Tree, _} = Grant, {target, Names}) ->
    case act(Grant, [{Names, follow}], fun stat/1) of
        {ok, #{qid := {_, _, QidPath}}} -> {Pid, Tree, QidPath};
        Other -> Other
    end.

%% erx_path's callbacks ------------------------------------------------------

%% A walk the resolver asks for, from a fid attached to the tree's root, into fids that
%% are clunked with it, all sent together: the kind of each name it passed, up to and
%% including the first that is not a directory, and how it ended.
-spec walk(grant(), [binary()]) -> reply().
walk({_, Tree, _} = Grant, Names) ->
    Root = fid(),
    {Walks, _} = walks(Root, Names),
    Made = [Root | [New || {walk, _, New, _} <- Walks]],
    case exchange(Grant, [attach(Root, Tree) | Walks] ++ [{clunk, Fid} || Fid <- Made]) of
        [{ok, _} | Walked] -> walk_reply(Walks, Walked);
        [{error, _} = Error | _] -> {[], Error}
    end.

%% A link's text, read on a walk to the link sent with its readlink. A walk that stops
%% answers its error.
-spec link_text(grant(), [binary()]) -> {ok, binary()} | {error, posix()}.
link_text(Grant, Names) ->
    case act(Grant, [{Names, nofollow}], fun([Fid]) -> {readlink, Fid} end) of
        {resume, _, {_, Error}} -> Error;
        Answer -> Answer
    end.

%% Whether a walk's kinds, of every name it walked, stand for an operation whose last
%% name must be as Mode asks: not a link it follows, or a directory for a parent. Every
%% name before the last must be a directory, as the resolver reads a reply.
-spec passed([directory | link | other], mode()) -> boolean().
passed([], _) -> true;
passed([Last], Mode) -> last_passed(Last, Mode);
passed([directory | Kinds], Mode) -> passed(Kinds, Mode);
passed(_, _) -> false.

last_passed(_, nofollow) -> true;
last_passed(Kind, follow) -> Kind =/= link;
last_passed(Kind, directory) -> Kind =:= directory.

%% The exchange ---------------------------------------------------------------

%% Reaches each path from one new attach, sends Act on the fids the paths reached, then
%% clunks every fid made, all together. The answer is the attach's failure, the first
%% path's resumption, in order, else Act's reply.
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
    Reaches = [reach(Root, Names, Mode) || {Names, Mode} <- Paths],
    {Root, Reaches, [Walk || {Walks, _, _} <- Reaches, Walk <- Walks]}.

reach(From, Names, Mode) ->
    {Walks, Last} = walks(From, Names),
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

%% ok when the attach succeeded and every path's walks passed as its mode asks; else the
%% attach's failure, or {resume, Which, Reply} for the first path that did not, by its
%% place in Paths.
reached({ok, _}, Reaches, Walked) ->
    reached_paths(Reaches, Walked, 1);
reached({error, _} = Error, _, _) ->
    Error.

reached_paths([], _, _) ->
    ok;
reached_paths([{Walks, _, Mode} | Reaches], Walked, Which) ->
    {Mine, Others} = split_at(length(Walks), Walked),
    case walk_reply(Walks, Mine) of
        {Kinds, ok} = Reply ->
            case passed(Kinds, Mode) of
                true -> reached_paths(Reaches, Others, Which + 1);
                false -> {resume, Which, Reply}
            end;
        Reply ->
            {resume, Which, Reply}
    end.

%% A chain of walks' reply as the resolver reads it, from the grammar's checked reply to
%% each walk, in order (any replies after them are another request's). The server's
%% replies are untrusted, and the grammar has already held each to its request's names
%% (decode_reply/2). A walk that lists fewer qids than names stopped: at a missing name
%% when its last qid is a directory (enoent), else on a file that is not one (enotdir). A
%% chunk that ends on a file that is not a directory ends the walk there, since the next
%% would start from it. A qid after one that is not a directory names a walk past a file,
%% which no server makes: that reply answers eio, with the kinds of the chunks before it.
-spec walk_reply([tuple()], [term()]) -> reply().
walk_reply(Walks, Replies) ->
    walk_reply(Walks, Replies, []).

walk_reply([], _, Kinds) ->
    {lists:reverse(Kinds, []), ok};
walk_reply([{walk, _, _, Names} | Walks], [{ok, Qids} | Replies], Kinds) ->
    case kinds(Qids, Kinds) of
        past_a_file -> {lists:reverse(Kinds, []), {error, eio}};
        {walked, Passed} when length(Qids) =:= length(Names) ->
            chunk_end(whole, Passed, Walks, Replies);
        {walked, Passed} -> chunk_end(short, Passed, Walks, Replies)
    end;
walk_reply([_ | _], [{error, _} = Error | _], Kinds) ->
    {lists:reverse(Kinds, []), Error}.

%% How a chunk that listed a qid for every name (whole) or fewer (short) leaves the
%% reading, Passed the kinds so far, last first: the last chunk whole ends ok, a whole
%% chunk that ends on a directory goes on to the next, and otherwise the walk ends at the
%% chunk's last qid, enotdir on a file that is not a directory and enoent, the next name
%% missing, on a directory.
chunk_end(whole, Passed, [], _) -> {lists:reverse(Passed, []), ok};
chunk_end(whole, [directory | _] = Passed, Walks, Replies) -> walk_reply(Walks, Replies, Passed);
chunk_end(_, [Kind | _] = Passed, _, _) when Kind =/= directory -> {lists:reverse(Passed, []), {error, enotdir}};
chunk_end(_, Passed, _, _) -> {lists:reverse(Passed, []), {error, enoent}}.

%% Each qid's kind onto Kinds, last first, as {walked, Kinds}; past_a_file when a qid
%% follows one that is not a directory.
kinds([], Kinds) ->
    {walked, Kinds};
kinds([Qid | Qids], Kinds) ->
    case {kind(Qid), Qids} of
        {directory, _} -> kinds(Qids, [directory | Kinds]);
        {Kind, []} -> {walked, [Kind | Kinds]};
        {_, [_ | _]} -> past_a_file
    end.

kind({Type, _, _}) when Type band ?ERX_P9_QTDIR =/= 0 -> directory;
kind({Type, _, _}) when Type band ?ERX_P9_QTSYMLINK =/= 0 -> link;
kind(_) -> other.

%% An encoded path's text: prim_file's encoding ends in the NUL its NIF hands to C.
text(Encoded) when byte_size(Encoded) > 0, binary_part(Encoded, byte_size(Encoded) - 1, 1) =:= <<0>> ->
    binary_part(Encoded, 0, byte_size(Encoded) - 1);
text(Path) ->
    Path.

%% Every request the client sends passes here, so what holds here holds for every
%% operation: a request the protocol's grammar refuses sends nothing and answers einval,
%% as does a walk that names "..", which the grammar lets a server take but which only
%% the resolver acts on (design-files.md, Resolving a path); and a request that writes,
%% through rights other than rw, sends nothing and answers erofs, as the grant's own
%% funnel would. Nothing else is sent; else each request goes to an alias of its own, all
%% at once, and the replies are answered in order.
exchange({Pid, _, Rights}, Requests) ->
    case refused(Requests, Rights) of
        none -> sent(Pid, Requests);
        Why -> [{error, Why} || _ <- Requests]
    end.

-spec refused([tuple()], ro | rw | rx) -> none | einval | erofs.
refused([], _) ->
    none;
refused([Request | Requests], Rights) ->
    case {erx_9p_grammar:decode_request(Request), dot_dot(Request)} of
        {_, true} -> einval;
        {{ok, _}, false} when Rights =:= rw -> refused(Requests, Rights);
        {{ok, _}, false} ->
            case erx_9p_grammar:writes(Request) of
                true -> erofs;
                false -> refused(Requests, Rights)
            end;
        {{error, einval}, false} -> einval
    end.

dot_dot({walk, _, _, [<<"..">> | _]}) -> true;
dot_dot({walk, Fid, NewFid, [_ | Names]}) -> dot_dot({walk, Fid, NewFid, Names});
dot_dot(_) -> false.


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

%% Liveness is live until the server's monitor fires, and gone after. Each alias stays
%% active until its reply's shape arrives, so a message of another shape sent to it
%% cannot end it before the reply; the alias ends when the reply is taken or the server
%% is gone. A message of another shape at a live alias is not taken and stays in the
%% caller's mailbox (a security residual in TODO.md).
collect([], _, _) ->
    [];
collect([{Alias, Request} | Sent] = Waiting, Monitor, Liveness) ->
    case reply(Alias, Monitor, Liveness) of
        {reply, Reply} ->
            erlang:unalias(Alias),
            [decoded(Request, Reply) | collect(Sent, Monitor, Liveness)];
        down ->
            collect(Waiting, Monitor, gone);
        none ->
            erlang:unalias(Alias),
            [{error, eio} | collect(Sent, Monitor, gone)]
    end.

%% Waits for the reply at Alias, bare from a server of this domain or in one envelope
%% from a server of another. While the server is live it returns {reply, Reply}, or down
%% when the server's monitor fires first. Once the server is gone it returns
%% {reply, Reply} for a reply that arrived before the server's end, and none otherwise.
reply(Alias, Monitor, live) ->
    receive
        {erx_9p, Alias, Reply} -> {reply, Reply};
        {erx_origin, _, {erx_9p, Alias, Reply}} -> {reply, Reply};
        {'DOWN', Monitor, process, _, _} -> down
    end;
reply(Alias, _, gone) ->
    receive
        {erx_9p, Alias, Reply} -> {reply, Reply};
        {erx_origin, _, {erx_9p, Alias, Reply}} -> {reply, Reply}
    after 0 -> none
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
