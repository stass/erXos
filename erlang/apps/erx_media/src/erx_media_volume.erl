%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_media_volume).
-moduledoc """
A volume's process (docs/design-drives.md, "Volumes"): a temporary child of its
medium's supervisor (erx_media_medium), and the volume's mount, which is made when it
starts and ends when it ends. It runs under the memory bound of "Time and memory",
`max_heap_size` of `media_volume_bytes` in words, with `kill` and
`include_shared_binaries`, so a volume whose heap, stack and the binaries it holds
pass the bound at a collection is ended alone.

It reads its volume through the window proxy alone, each sector placed by
erx_media_table:place/3, so no request reaches a sector outside the volume. Before
it answers anything it probes the volume (erx_media_probe:format/3), mounts the
selected format if it serves it, and applies the writable rule (writable/4), so a
call made while it mounts waits for the mount. Its outcome is what `sN_mount` and
`sN_ro_reason` show:

* `rw`;
* `{ro, Reason}`, the writable rule's first condition that does not hold: `format`,
  `{also, Name}`, `flush` (the medium cannot flush), `dirty`, `hard_error`, `mirror`,
  `too_large` or `tree`, the last two the ownership check's (erx_fat:check/1), which
  runs only once every condition before it holds;
* `{none, Reason}`, no files: `format` for a format not served, FAT12 among them,
  `unknown`, `{flush, Reason}` for a flush that answered neither `ok` nor `enotsup`,
  or `{failed, Why}` for a probe whose read failed or a mount the format refused.

A read-only outcome's reason reads as one plain line, ro_reason/1, which the media
tree shows as `sN_ro_reason` and the volume logs once when it mounts, so status and
the log line come from the one outcome the rule gave. The media tree takes
every write in a volume to the volume's changes below, each of which answers
`erofs` unless its mount is `rw`.

**Writing.** A volume mounted `rw` holds a batch of the FAT server's changes
(erx_fat_dir) and writes it through the window proxy alone, in the batch's steps
with a flush after each (docs/design-storage.md, "Durability"): before the first
batch after the mount the dirty flag's plan, and then each batch at `fsync`, 5 s
after a change while changes wait, as soon as the batch holds more than its bound
(?BATCH_SECTORS, the lesser of 1,024 sectors and a quarter of `media_volume_bytes`),
and at the volume's finish, its last batches and the clean bit: at finish/1, or
when its process ends without one. A change answers once the batch holds it. A write or flush that fails ends
the volume, `{shutdown, {failed, Why}}`, so every request after answers `eio` and
the medium mounts read-only as dirty when it next mounts. The changes are calls,
each naming its file or directory by its qid path: create/3, mkdir/3, write/4,
truncate/3, setattr/3, remove/3, rmdir/3, rename/5 and fsync/1; a volume mounted
`ro` answers each `erofs`.

**Files by fid** (docs/design-storage.md, "File identity and version"). The volume
keeps a table of the nodes fids name, each under its qid path with the set of its
holders, and beside it a key from where a name's entry lies (erx_fat:key/1) to the
path of the node there. A holder is a grant of the files service, which holds each
node a callback of its tree answered until none of its fids names it and then
forgets it (erx_fs, `forget/2`): every named answer, of root/1, walk/3, create/3
and mkdir/3, adds its caller to the node's holders, forget/2 takes the caller away,
and a holder's end takes it from every node, so no client's fids, clones or walks
can leave a node held after the grant lets it go or ends. The mount holds the
root. A node no holder names leaves the table, so a file walked
again after its last clunk may get a new path, and a listing answers the path the
table has for a name or one drawn for it alone. A rename moves the key and a
removal drops it, so a name made later in the same place is another file with a
path of its own. A removed file stays in the table, out of the key, and reads,
writes and takes setattr through its path as before, publishing no entry, until its last
holder forgets it; then its chain goes to the next batch's release. A removed
directory leaves the table at once, so its path answers `enoent`. The table holds
at most ?TABLE_MAX nodes, a removed file's among them, as many as fit an eighth of
the volume's memory bound, and evicts none: a walk, create or mkdir that would add
one to a full table answers `enfile` and changes nothing.

The formats served are FAT16 and FAT32, through the FAT server (erx_fat); no other
format falls back to another. Every byte of the volume is untrusted, and its label
reaches no sink here: the media tree shows it through the field escape.

Its last request is finish/1 ("Finishing a volume"), the volume's one admission
barrier: the process takes its requests one at a time, so every request sent before
the finish is answered before it. A writable volume then writes what it holds, every
chain a removed file kept released and its last batches with the clean bit
(last_batch/1), and has the window flush; a read-only volume, or one that mounted no
files, has nothing to write. From then the volume is finished: every later request,
a second finish among them, answers `eio` without reaching its format, while
outcome/1 and root_path/1, which only describe the mount, still answer.

Once mounted it serves its files to the media tree (erx_media_tree, "The media tree"):
root/1, walk/3, attr/2 and list/2 are calls, each naming a node by its FAT node and
its qid path (path/0), and a read is a waiting request whose keeper is this process,
answered as soon as its sectors are read. The calls carry no timer, as "Time and
memory" has it: they end when the volume answers or ends, and a volume that has ended,
or that mounted no files, answers `eio`.

A qid path is the volume's mount number, drawn from the media domain's counter
(new_mounts/0) when the process starts, whether or not it serves files, in its high
24 bits, and in its low 40 a number of this mount's, drawn in order and never
twice, the root's 0 ("Identity"), so no path names two files while the media
domain lives and a medium mounted again is another set of files. root_path/1
answers the root's path for any outcome, which the listing of the drive's
directory shows for `sN`. A mount past the 24 bits' last number is
`{none, {failed, enfile}}` and has no path, and a node past the 40 bits' last
number answers `enfile`.
""".

-behaviour(gen_server).

-export([start_link/2, outcome/1, writable/4, ro_reason/1, new_mounts/0]).
-export([root/1, root_path/1, walk/3, attr/2, list/2, finish/1]).
-export([create/3, mkdir/3, write/4, append/3, truncate/3, setattr/3, remove/3, rmdir/3, unlink_node/4, rename/5, fsync/1,
         forget/2]).
-export([format_status/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export_type([outcome/0, mount/0, path/0]).

-include("erx_fs_waits.hrl").
-include("generated/erx_abi.hrl").

-define(MOUNT_BITS, 24).
-define(NODE_BITS, 40).
%% Where the media domain's mount counter lies (new_mounts/0).
-define(MOUNTS, {?MODULE, mounts}).
%% The most nodes the table holds (docs/design-storage.md, "File identity and version"):
%% an eighth of the volume's memory bound over the words one node costs at most, its
%% entry, FAT node and key and its slots in both maps, measured flat (shares counted
%% twice) for a file under a directory and a path past 2^59, 38 words. An eighth,
%% since a collection counts the heap's old and new blocks at once, measured at about
%% four times the live words, beside the batch's quarter of binaries.
%% (erx_media_volume_write_tests checks the table full against its eighth.)
-define(TABLE_ENTRY_WORDS, 44).
-define(TABLE_MAX, (?ERX_MEDIA_VOLUME_BYTES div 8 div (?TABLE_ENTRY_WORDS * 8))).

%% The formats the media domain writes on a drive: FAT alone, the format table's one
%% row that writes and is served here (docs/design-drives.md, "The writable rule").
-define(WRITTEN, [msdosfs]).
%% A batch commits once it holds more than this many sectors (docs/design-storage.md,
%% "Durability"), and 5 s after a change while changes wait.
-define(BATCH_SECTORS, min(1024, ?ERX_MEDIA_VOLUME_BYTES div 4 div 512)).
-define(BATCH_DELAY_MS, 5000).
%% A growth past a file's size is zeroed this many bytes a change at a time, so no
%% one change holds more than half a batch.
-define(GROWTH_BYTES, (?BATCH_SECTORS * 512 div 2)).
%% The largest file FAT holds: 4 GiB less one byte.
-define(FILE_MAX, 16#ffffffff).

-type mount() :: rw
               | {ro, format | {also, erx_media_probe:name()} | flush | dirty | hard_error | mirror
                      | too_large | tree}
               | {none, format | unknown | {flush, atom()} | {failed, term()}}.
-type outcome() :: #{format := erx_media_probe:name() | unknown, mount := mount(),
                     fat => erx_fat_read:fat_type(), label => binary() | none,
                                          serial => non_neg_integer() | none}.
-type path() :: 0..16#ffffffffffffffff.
%% A node as the media tree holds it: its kind and qid path beside the FAT node itself.
-type named() :: {ok, dir | file, path()}.
-type errno() :: enoent | enotdir | eisdir | eio | enfile | erofs | erx_fat_dir:error().

-doc """
Starts the process of Volume, an entry erx_media_table:read/2 answered, over the
window proxy Proxy, linked to the caller, the medium's supervisor.
""".
-spec start_link(pid(), erx_media_table:volume()) -> {ok, pid()}.
start_link(Proxy, #{first := _, length := _} = Volume) when is_pid(Proxy) ->
    gen_server:start_link(?MODULE, {Proxy, Volume}, []).

-doc """
Makes the media domain's mount counter, whose first number is 1, so that no volume's
path has mount number 0, the media tree's own; erx_media_sup makes it once per
incarnation, before any volume starts.
""".
-spec new_mounts() -> ok.
new_mounts() ->
    persistent_term:put(?MOUNTS, atomics:new(1, [{signed, false}])).

-doc "The root directory of the volume Pid's files.".
-spec root(pid()) -> named() | {error, errno()}.
root(Pid) -> call(Pid, {root, self()}).

-doc """
The qid path of the volume Pid's root, whatever its outcome: `eio` once it has ended,
`enfile` for a mount past the counter's last number.
""".
-spec root_path(pid()) -> {ok, path()} | {error, eio | enfile}.
root_path(Pid) -> call(Pid, root_path).

-doc "The entry named Name of directory Dir of the volume Pid.".
-spec walk(pid(), path(), binary()) -> named() | {error, errno()}.
walk(Pid, Dir, Name) -> call(Pid, {walk, Dir, Name, self()}).

-doc "The attributes (erx_fat:attr/1) and qid path of the node at Path.".
-spec attr(pid(), path()) -> {ok, map(), path()} | {error, errno()}.
attr(Pid, Path) -> call(Pid, {attr, Path}).

-doc "Directory Dir's entries, in the volume's order: each name, its kind and its qid path.".
-spec list(pid(), path()) -> {ok, [{binary(), dir | file, path()}]} | {error, errno()}.
list(Pid, Dir) -> call(Pid, {list, Dir}).

-doc """
Finishes the volume Pid: `ok` once every request before it is answered and what a
writable volume holds is written and flushed; the first failure of those writes or
the flush; or `eio` for a volume already finished or ended.
""".
-spec finish(pid()) -> ok | {error, atom()}.
finish(Pid) -> call(Pid, finish).

-doc "A new empty file Name in the directory at Dir.".
-spec create(pid(), path(), binary()) -> named() | {error, errno()}.
create(Pid, Dir, Name) -> call(Pid, {create, Dir, Name, self()}).

-doc "A new empty directory Name in the directory at Dir.".
-spec mkdir(pid(), path(), binary()) -> named() | {error, errno()}.
mkdir(Pid, Dir, Name) -> call(Pid, {mkdir, Dir, Name, self()}).

-doc "Bytes written to the file at Path from Offset: the count written.".
-spec write(pid(), path(), non_neg_integer(), binary()) -> {ok, non_neg_integer()} | {error, errno()}.
write(Pid, Path, Offset, Bytes) -> call(Pid, {write, Path, Offset, Bytes}).

-doc "Bytes written at the end of the file at Path: the count written and the offset it was written at.".
-spec append(pid(), path(), binary()) -> {ok, non_neg_integer(), non_neg_integer()} | {error, errno()}.
append(Pid, Path, Bytes) -> call(Pid, {append, Path, Bytes}).

-doc "The file at Path cut or grown to Size bytes.".
-spec truncate(pid(), path(), non_neg_integer()) -> ok | {error, errno()}.
truncate(Pid, Path, Size) -> call(Pid, {truncate, Path, Size}).

-doc "The file at Path given the time `mtime` and the attribute `read_only` Changes holds.".
-spec setattr(pid(), path(), #{mtime => integer(), read_only => boolean()}) -> ok | {error, errno()}.
setattr(Pid, Path, Changes) -> call(Pid, {setattr, Path, Changes}).

-doc "File Name of the directory at Dir removed.".
-spec remove(pid(), path(), binary()) -> ok | {error, errno()}.
remove(Pid, Dir, Name) -> call(Pid, {remove, Dir, Name}).

-doc "Empty directory Name of the directory at Dir removed.".
-spec rmdir(pid(), path(), binary()) -> ok | {error, errno()}.
rmdir(Pid, Dir, Name) -> call(Pid, {rmdir, Dir, Name}).

-doc """
Name of the directory at Dir removed, a file as remove/3 removes it and a directory
as rmdir/3, only while it still names the node at Path; `enoent` otherwise.
""".
-spec unlink_node(pid(), path(), binary(), path()) -> ok | {error, errno()}.
unlink_node(Pid, Dir, Name, Path) -> call(Pid, {unlink_node, Dir, Name, Path}).

-doc "Name From of the directory at FromDir renamed To in the directory at ToDir.".
-spec rename(pid(), path(), binary(), path(), binary()) -> ok | {error, errno()}.
rename(Pid, FromDir, From, ToDir, To) -> call(Pid, {rename, FromDir, From, ToDir, To}).

-doc "Every change the volume holds written to the medium.".
-spec fsync(pid()) -> ok | {error, errno()}.
fsync(Pid) -> call(Pid, fsync).

-doc """
The caller no longer holds the node at Path: no fid of its names it (erx_fs,
`forget/2`). A cast, so it reaches the volume before the caller's later calls; a
path the caller does not hold changes nothing.
""".
-spec forget(pid(), path()) -> ok.
forget(Pid, Path) -> gen_server:cast(Pid, {forget, Path, self()}).

call(Pid, Request) ->
    try gen_server:call(Pid, Request, infinity) catch exit:_Ended -> {error, eio} end.

-doc "The volume's outcome, once its probe and mount are done.".
-spec outcome(pid()) -> outcome().
outcome(Pid) ->
    gen_server:call(Pid, outcome, infinity).

-doc """
The writable rule (docs/design-drives.md, "The writable rule") for a volume of the
selected format Format, on which the probe also found the written formats Also, and
whose format's own state Own answers (`ok`, a reason, or `{none, Why}` for a
check that could not read the volume): `rw` when every condition holds, else
`{ro, Reason}` for the first that does not, or `{none, {flush, Reason}}` for a flush
that answered anything but `ok` or `enotsup`, which refuses the mount with nothing
written. Flush sends the mount's one flush; it is called only once the first two
conditions hold, and before anything is written; Own only once the flush answered
`ok`.
""".
-spec writable(erx_media_probe:name(), [erx_media_probe:name()], fun(() -> ok | {error, term()}),
               fun(() -> ok | atom() | {none, term()})) -> mount().
writable(Format, Also, Flush, Own) ->
    case {lists:member(Format, ?WRITTEN), Also} of
        {false, _} -> {ro, format};
        {true, [Name | _]} -> {ro, {also, Name}};
        {true, []} -> flushed(Flush(), Own)
    end.

flushed(ok, Own) ->
    case Own() of
        ok -> rw;
        {none, _} = Refused -> Refused;
        Reason -> {ro, Reason}
    end;
flushed({error, enotsup}, _Own) -> {ro, flush};
flushed({error, Reason}, _Own) when is_atom(Reason) -> {none, {flush, Reason}};
flushed(_Malformed, _Own) -> {none, {flush, eio}}.

-doc """
The reason a read-only outcome gives, as one plain line for `sN_ro_reason` and the
mount's log line; `none` for an outcome that is not read-only. A format's name is an
atom of the probe's closed set, never a byte of the medium.
""".
-spec ro_reason(outcome()) -> binary() | none.
ro_reason(#{format := Format, mount := {ro, Reason}}) -> reason(Format, Reason);
ro_reason(#{mount := _NotReadOnly}) -> none.

reason(Format, format) -> <<"erXos does not write ", (atom_to_binary(Format))/binary>>;
reason(_Format, {also, Name}) -> <<"a ", (atom_to_binary(Name))/binary, " signature is also on the volume">>;
reason(_Format, flush) -> <<"the medium cannot flush">>;
reason(_Format, dirty) -> <<"the FAT's dirty flag is set">>;
reason(_Format, hard_error) -> <<"the FAT's hard-error flag is set">>;
reason(_Format, mirror) -> <<"the volume's FATs are not mirrored">>;
reason(_Format, too_large) -> <<"the volume has more clusters than the ownership check holds">>;
reason(_Format, tree) ->
    <<"a cluster is reached twice, a chain reaches a free cluster, or a directory's .. does not name its parent">>.

%% The process ---------------------------------------------------------------------

-doc false.
init({Proxy, Volume}) ->
    process_flag(max_heap_size, erx_media_medium:memory_bound()),
    %% The medium's supervisor ends the volume with shutdown, which runs its finish
    %% unless finish/1 ran it.
    process_flag(trap_exit, true),
    {ok, #{proxy => Proxy, volume => Volume, finished => false, batch => read_only, dirty => false,
           timer => none, places => #{}, nodes => #{}, holders => #{}, next => 0}, {continue, mount}}.

-doc false.
handle_continue(mount, #{proxy := Proxy, volume := #{length := Length} = Volume} = State) ->
    case new_mount() of
        {ok, Mount} ->
            Read = fun(Sector) -> read_sector(Proxy, Volume, Sector) end,
            {Outcome, Fat} = mounted(erx_media_probe:format(Read, Length, ?WRITTEN), Read, Length, Proxy),
            log_read_only(Volume, Outcome),
            Batch = case Outcome of #{mount := rw} -> erx_fat_dir:new(Fat); #{} -> read_only end,
            {noreply, named_root(State#{outcome => Outcome, mount => Mount, fat => Fat, batch => Batch})};
        enfile ->
            Outcome = #{format => unknown, mount => {none, {failed, enfile}}},
            {noreply, State#{outcome => Outcome, mount => none, fat => none}}
    end.

-doc false.
handle_call(outcome, _From, #{outcome := Outcome} = State) ->
    {reply, Outcome, State};
handle_call(root_path, _From, #{mount := none} = State) ->
    {reply, {error, enfile}, State};
handle_call(root_path, _From, #{mount := Mount} = State) ->
    {reply, {ok, Mount bsl ?NODE_BITS}, State};
handle_call(_Request, _From, #{finished := true} = State) ->
    {reply, {error, eio}, State};
handle_call(finish, _From, State) ->
    {reply, finished(State), State#{finished := true}};
handle_call(_Files, _From, #{fat := none} = State) ->
    {reply, {error, eio}, State};
handle_call(Request, _From, State) ->
    try request(Request, State) of
        {Reply, Next} -> {reply, Reply, Next}
    catch
        throw:{?MODULE, refused, Errno} -> {reply, {error, Errno}, State};
        %% Refused after a part of the change was committed: the state as that part left it.
        throw:{?MODULE, refused_after, Errno, Partial} -> {reply, {error, Errno}, Partial};
        throw:{?MODULE, failed, Why} -> {stop, {shutdown, {failed, Why}}, {error, eio}, State}
    end.

-doc false.
handle_cast({forget, Path, Holder}, State) ->
    effect(fun() -> forgotten(Path, Holder, State) end, State);
handle_cast(_Other, State) ->
    {noreply, State}.

%% A read is a waiting request whose keeper is the volume, answered once its sectors
%% are read; a flush that follows its answer finds nothing to flush.
-doc false.
handle_info(?ERX_FS_WAIT({_Grant, Alias}, _Request), #{finished := true} = State) ->
    Alias ! ?ERX_FS_ANSWER(Alias, {error, eio}),
    {noreply, State};
handle_info(?ERX_FS_WAIT({_Grant, Alias}, {read, Path, Offset, Count}), State) ->
    Answer = try {ok, Bytes} = fat_read(node(Path, State), Offset, Count, State), {ok, Bytes}
             catch throw:{?MODULE, refused, Errno} -> {error, Errno} end,
    Alias ! ?ERX_FS_ANSWER(Alias, Answer),
    {noreply, State};
handle_info({timeout, Timer, commit}, #{timer := Timer, finished := false} = State) ->
    effect(fun() -> committed(State#{timer := none}) end, State);
handle_info({'DOWN', _Ref, process, Holder, _Why}, #{holders := Holders, finished := false} = State)
  when is_map_key(Holder, Holders) ->
    effect(fun() -> holder_ended(Holder, State) end, State);
handle_info(_Other, State) ->
    {noreply, State}.

%% A change no request answers, a commit or a holder let go: a write that fails ends
%% the volume. A finished volume makes none.
effect(Change, State) ->
    try {noreply, Change()}
    catch throw:{?MODULE, failed, Why} -> {stop, {shutdown, {failed, Why}}, State}
    end.

%% A volume that ends without finish/1 finishes here (last_batch/1); a volume whose
%% write failed, or that finish/1 already finished, writes nothing more.
-doc false.
terminate({shutdown, {failed, _}}, _State) ->
    ok;
terminate(_Why, #{finished := false, batch := Batch} = State) when Batch =/= read_only ->
    try last_batch(State) catch throw:{?MODULE, _, _} -> ok end;
terminate(_Why, _State) ->
    ok.

%% A report of the volume (erx_report:status/2) shows its outcome and counts, never the
%% batch, the mount's tables or a request's bytes, so it holds no file's contents; a
%% request shows by its kind.
-doc false.
format_status(Status) -> erx_report:status(Status, #{state => fun shown/1, message => fun erx_report:reason_name/1}).

shown(#{batch := Batch, nodes := Nodes, holders := Holders} = State) ->
    (maps:with([volume, outcome, mount, dirty, next], State))#{
        batch_sectors => case Batch of read_only -> read_only; _ -> erx_fat_dir:held(Batch) end,
        nodes => map_size(Nodes), holders => map_size(Holders)};
shown(_Other) ->
    unknown.

%% The requests ------------------------------------------------------------------

request({root, Holder}, #{mount := Mount} = State) ->
    {{ok, dir, Mount bsl ?NODE_BITS}, holder_added(Mount bsl ?NODE_BITS, Holder, State)};
request({walk, Dir, Name, Holder}, State) ->
    named_node(fat(erx_fat:walk(node(Dir, State), Name, view(State))), Holder, State);
request({attr, Path}, State) ->
    {{ok, erx_fat:attr(node(Path, State)), Path}, State};
request({list, Dir}, State) ->
    listed(fat(erx_fat:list(node(Dir, State), view(State))), [], State);
request(_Change, #{batch := read_only} = State) ->
    {{error, erofs}, State};
request(fsync, State) ->
    {ok, committed(State)};
request({create, Dir, Name, Holder}, State) ->
    made(fun(B) -> erx_fat_dir:create(B, node(Dir, State), Name, now_s()) end, Holder, State);
request({mkdir, Dir, Name, Holder}, State) ->
    made(fun(B) -> erx_fat_dir:mkdir(B, node(Dir, State), Name, now_s()) end, Holder, State);
request({write, Path, Offset, Bytes}, State) ->
    Offset + byte_size(Bytes) =< ?FILE_MAX orelse refuse(efbig),
    #{size := Size} = erx_fat:attr(node(Path, State)),
    Grown = grown(Path, Offset, Size, State),
    {{ok, byte_size(Bytes)}, after_growth(Path, {write, Offset, Bytes}, Grown)};
request({append, Path, Bytes}, State) ->
    #{size := Size} = erx_fat:attr(node(Path, State)),
    {{ok, Count}, Next} = request({write, Path, Size, Bytes}, State),
    {{ok, Count, Size}, Next};
request({truncate, Path, Size}, State) ->
    Size =< ?FILE_MAX orelse refuse(efbig),
    #{size := Old} = erx_fat:attr(node(Path, State)),
    Grown = grown(Path, Size, Old, State),
    {ok, after_growth(Path, {truncate, Size}, Grown)};
request({setattr, Path, Changes}, State) ->
    {ok, changed(Path, {setattr, Changes}, State)};
request({remove, Dir, Name}, State) ->
    {Node, B} = dir_changed(erx_fat_dir:remove(batch(State), node(Dir, State), Name)),
    {ok, held(unnamed(Node, State#{batch := B}))};
request({rmdir, Dir, Name}, State) ->
    {Node, B} = dir_changed(erx_fat_dir:rmdir(batch(State), node(Dir, State), Name)),
    {ok, held(unnamed(Node, State#{batch := B}))};
request({unlink_node, Dir, Name, Path}, #{places := Places} = State) ->
    Found = fat(erx_fat:walk(node(Dir, State), Name, view(State))),
    maps:get(erx_fat:key(Found), Places, none) =:= Path orelse refuse(enoent),
    case kind(Found) of
        file -> request({remove, Dir, Name}, State);
        dir -> request({rmdir, Dir, Name}, State)
    end;
request({rename, FromDir, From, ToDir, To}, State) ->
    Moving = erx_fat:key(fat(erx_fat:walk(node(FromDir, State), From, view(State)))),
    {{Node, Replaced}, B} = dir_changed(erx_fat_dir:rename(batch(State), node(FromDir, State), From,
                                                            node(ToDir, State), To)),
    State1 = case Replaced of none -> State#{batch := B}; _ -> unnamed(Replaced, State#{batch := B}) end,
    {ok, held(moved(Moving, Node, State1))};
request(_Other, State) ->
    {{error, einval}, State}.

%% A growth to Target past a file's size Size, zeroed a part at a time, each part a
%% change of its own, so that no change holds more than half a batch.
grown(Path, Target, Size, State) when Target > Size + ?GROWTH_BYTES ->
    Part = Size + ?GROWTH_BYTES,
    grown(Path, Target, Part, after_growth(Path, {truncate, Part}, State));
grown(_Path, _Target, _Size, State) ->
    State.

%% The change Change of the file at Path after a growth's parts, each of which may
%% have committed: a refusal keeps the state the parts left.
after_growth(Path, Change, State) ->
    try changed(Path, Change, State)
    catch throw:{?MODULE, refused, Errno} -> throw({?MODULE, refused_after, Errno, State})
    end.

%% The finish --------------------------------------------------------------------

%% The finish's answer: a writable volume's last batches written, then the window's
%% flush; any other volume wrote nothing, so has nothing to flush. A write that
%% fails answers its reason, and the finished volume writes nothing more.
finished(#{outcome := #{mount := rw}, proxy := Proxy} = State) ->
    try last_batch(State) of
        _Written -> flush_answer(erx_media_medium:window(Proxy, flush))
    catch
        throw:{?MODULE, failed, Why} -> flush_answer({error, Why})
    end;
finished(#{}) ->
    ok.

%% What a writable volume has not yet written, when it ever wrote: every chain a
%% removed file kept released, its last batches and the clean bit.
last_batch(#{batch := B, dirty := Dirty, nodes := Nodes} = State) ->
    Removed = [Path || Path := {removed, _, _} <- Nodes],
    case Dirty orelse erx_fat_dir:held(B) > 0 orelse Removed =/= [] of
        true -> batches_finished(marked(released_all(State)));
        false -> ok
    end.

flush_answer(ok) -> ok;
flush_answer({error, Reason}) when is_atom(Reason) -> {error, Reason};
flush_answer(_Malformed) -> {error, eio}.

%% The changes -------------------------------------------------------------------

%% The file at Path changed by Change, through its name while one leads to it, else
%% as a removed file, whose changes publish no entry; the table keeps the file as
%% the batch then leaves it.
changed(Path, Change, #{nodes := Nodes} = State) ->
    {Held, File, Holders} = entry(Path, State),
    {Changed, B} = dir_changed(file_changed(Held, Change, batch(State), File)),
    held(State#{batch := B, nodes := Nodes#{Path := {Held, Changed, Holders}}}).

file_changed(named, {write, Offset, Bytes}, B, File) -> erx_fat_dir:write(B, File, Offset, Bytes, now_s());
file_changed(named, {truncate, Size}, B, File) -> erx_fat_dir:truncate(B, File, Size, now_s());
file_changed(named, {setattr, Changes}, B, File) -> erx_fat_dir:setattr(B, File, Changes);
file_changed(removed, {write, Offset, Bytes}, B, File) -> erx_fat_dir:write_removed(B, File, Offset, Bytes);
file_changed(removed, {truncate, Size}, B, File) -> erx_fat_dir:truncate_removed(B, File, Size);
file_changed(removed, {setattr, Changes}, B, File) -> erx_fat_dir:setattr_removed(B, File, Changes).

%% A new name made by Make(Batch): its node, held by Holder.
made(Make, Holder, State) ->
    {Node, B} = dir_changed(Make(batch(State))),
    {Reply, Next} = named_node(Node, Holder, State#{batch := B}),
    {Reply, held(Next)}.

dir_changed({ok, Result, B}) -> {Result, B};
dir_changed({ok, B}) -> {ok, B};
dir_changed({error, Errno}) when is_atom(Errno) -> refuse(errno(Errno)).

%% Node's name taken away, so its place leads to no path. A file a holder names stays
%% in the table as removed; a directory leaves it, and a file no holder names, or a
%% directory, has its chain go to a coming release.
unnamed(Node, #{places := Places, nodes := Nodes} = State) ->
    case {maps:take(erx_fat:key(Node), Places), kind(Node)} of
        {{Path, Rest}, file} ->
            {named, _, Holders} = maps:get(Path, Nodes),
            State#{places := Rest, nodes := Nodes#{Path := {removed, Node, Holders}}};
        {{Path, Rest}, dir} ->
            released(Node, State#{places := Rest, nodes := maps:remove(Path, Nodes)});
        {error, _} ->
            released(Node, State)
    end.

%% The chain of Node, which no name and no fid reaches any more, to a coming release.
released(Node, #{batch := B} = State) ->
    case erx_fat:first(Node) of
        0 -> State;
        First -> {ok, B1} = dir_changed(erx_fat_dir:free(B, First)), State#{batch := B1}
    end.

%% Holder added to the holders of the node at Path, once however often it is named;
%% a process holder is monitored from its first hold until its end.
holder_added(Path, Holder, #{nodes := Nodes} = State) ->
    {Held, Node, Holders} = entry(Path, State),
    monitored(Holder, State#{nodes := Nodes#{Path := {Held, Node, Holders#{Holder => []}}}}).

monitored(Holder, #{holders := Holders} = State) when is_pid(Holder), not is_map_key(Holder, Holders) ->
    State#{holders := Holders#{Holder => erlang:monitor(process, Holder)}};
monitored(_Holder, State) ->
    State.

%% Holder lets the node at Path go: once no holder names it, the node leaves the
%% table, and a removed file's chain goes to a coming release. A path Holder does
%% not hold changes nothing.
forgotten(Path, Holder, #{places := Places, nodes := Nodes} = State) ->
    case Nodes of
        #{Path := {Held, Node, #{Holder := []} = Holders}} when map_size(Holders) > 1 ->
            State#{nodes := Nodes#{Path := {Held, Node, maps:remove(Holder, Holders)}}};
        #{Path := {named, Node, #{Holder := []}}} ->
            State#{places := maps:remove(erx_fat:key(Node), Places), nodes := maps:remove(Path, Nodes)};
        #{Path := {removed, Node, #{Holder := []}}} ->
            held(released(Node, State#{nodes := maps:remove(Path, Nodes)}));
        #{} ->
            State
    end.

%% An ended holder lets go of every node it held.
holder_ended(Holder, #{nodes := Nodes, holders := Holders} = State) ->
    Held = [Path || Path := {_, _, #{Holder := []}} <- Nodes],
    lists:foldl(fun(Path, Acc) -> forgotten(Path, Holder, Acc) end,
                State#{holders := maps:remove(Holder, Holders)}, Held).

%% Every chain a removed file still keeps, released at the finish.
released_all(#{nodes := Nodes} = State) ->
    maps:fold(fun(_Path, {removed, Node, _Holders}, Acc) -> released(Node, Acc); (_Path, _Named, Acc) -> Acc end,
              State, Nodes).

%% The renamed entry, once at place Old, now Node at its new place.
moved(Old, Node, #{places := Places, nodes := Nodes} = State) ->
    case maps:take(Old, Places) of
        {Path, Rest} ->
            {named, _, Holders} = maps:get(Path, Nodes),
            State#{places := Rest#{erx_fat:key(Node) => Path}, nodes := Nodes#{Path := {named, Node, Holders}}};
        error ->
            State
    end.

%% The batch, once it holds a change: committed when it holds more than its bound,
%% else committed 5 s on.
held(#{batch := B, timer := Timer} = State) ->
    case {erx_fat_dir:held(B) > ?BATCH_SECTORS, Timer} of
        {true, _} -> committed(State);
        {false, none} -> State#{timer := erlang:start_timer(?BATCH_DELAY_MS, self(), commit)};
        {false, _} -> State
    end.

%% Every change the batch holds written, batch after batch until no chain waits for
%% its release; before the first after the mount, the dirty flag's plan.
committed(#{timer := Timer} = State) ->
    _ = Timer =:= none orelse erlang:cancel_timer(Timer),
    committing(marked(State#{timer := none})).

committing(#{batch := B} = State) ->
    {Plan, B1} = planned(erx_fat_dir:commit(B)),
    applied(Plan, State),
    case erx_fat_dir:held(B1) of
        0 -> State#{batch := B1};
        _ -> committing(State#{batch := B1})
    end.

marked(#{dirty := true} = State) -> State;
marked(#{fat := Fat} = State) ->
    %% A flag that cannot be read, as a stick pulled, ends the volume as a failed write does.
    case erx_fat_alloc:dirty(erx_fat_alloc:new(erx_fat:layout(Fat))) of
        {ok, Plan} -> applied(Plan, State);
        {error, Why} -> failed(Why)
    end,
    State#{dirty := true}.

batches_finished(#{batch := B} = State) ->
    case planned(erx_fat_dir:finish(B)) of
        {Plan, finished} -> applied(Plan, State);
        {Plan, B1} -> applied(Plan, State), batches_finished(State#{batch := B1})
    end.

%% A commit's or finish's plan. A commit that fails ends the volume: an earlier plan
%% of the same commit may have reached the medium, so the batch from before the
%% request no longer describes it, and no later change may build on that batch.
planned({ok, Plan, Next}) -> {Plan, Next};
planned({error, Why}) -> failed(Why).

%% Plan written step by step through the window proxy,  each step's writes and then
%% a flush, so no write of a step reaches the medium before the steps before it.
applied(Plan, #{proxy := Proxy, volume := Volume}) ->
    lists:foreach(fun({_Step, Writes}) ->
                          lists:foreach(fun({Sector, Bytes}) -> placed_write(Proxy, Volume, Sector, Bytes) end, Writes),
                          answered(erx_media_medium:window(Proxy, flush))
                  end, Plan).

placed_write(Proxy, Volume, Sector, Bytes) ->
    case erx_media_table:place(Volume, Sector, 1) of
        {ok, Lba} -> answered(erx_media_medium:window(Proxy, {write, Lba, Bytes}));
        {error, Why} -> failed(Why)
    end.

answered(ok) -> ok;
answered({error, Why}) -> failed(Why);
answered(Other) -> failed({unexpected, Other}).

failed(Why) -> throw({?MODULE, failed, Why}).
refuse(Errno) -> throw({?MODULE, refused, Errno}).

now_s() -> erlang:system_time(second).

%% The files --------------------------------------------------------------------

%% The volume's mount number, the next of the media domain's counter.
new_mount() ->
    case atomics:add_get(persistent_term:get(?MOUNTS), 1, 1) of
        Mount when Mount < 1 bsl ?MOUNT_BITS -> {ok, Mount};
        _Past -> enfile
    end.

%% The root named first, so its number is 0, held by the mount.
named_root(#{fat := none} = State) -> State;
named_root(#{fat := Fat} = State) -> element(2, named_node(erx_fat:root(Fat), mount, State)).

batch(#{batch := B}) -> B.

%% The volume as reads see it: as the batch leaves it while one is held.
view(#{batch := read_only, fat := Fat}) -> Fat;
view(#{batch := B}) -> erx_fat_dir:view(B).

%% The table's entry at Path: {named | removed, Node, Holders}.
entry(Path, #{nodes := Nodes}) ->
    case Nodes of
        #{Path := Entry} -> Entry;
        #{} -> refuse(enoent)
    end.

%% The node at Path: a named one or a removed file's.
node(Path, State) -> element(2, entry(Path, State)).

fat_read(Node, Offset, Count, State) ->
    {ok, fat(erx_fat:read(Node, Offset, Count, view(State)))}.

%% Node, as a walk or a create found it, held by Holder: under the path its place
%% leads to, kept as the volume now reads it, or else added to the table under the
%% next path drawn.
named_node(Node, Holder, #{places := Places, nodes := Nodes} = State) ->
    Key = erx_fat:key(Node),
    case Places of
        #{Key := Path} ->
            {named, _, Holders} = maps:get(Path, Nodes),
            {{ok, kind(Node), Path},
             monitored(Holder, State#{nodes := Nodes#{Path := {named, Node, Holders#{Holder => []}}}})};
        #{} when map_size(Nodes) < ?TABLE_MAX ->
            {Path, Drawn} = drawn(State),
            {{ok, kind(Node), Path},
             monitored(Holder, Drawn#{places := Places#{Key => Path}, nodes := Nodes#{Path => {named, Node, #{Holder => []}}}})};
        #{} ->
            refuse(enfile)
    end.

%% A directory's entries, each under the path its place leads to, or one drawn for
%% the listing alone, since no fid names it.
listed([], Acc, State) ->
    {{ok, lists:reverse(Acc)}, State};
listed([{Name, Node} | Rest], Acc, #{places := Places} = State) ->
    Key = erx_fat:key(Node),
    {Path, Next} = case Places of
                       #{Key := Kept} -> {Kept, State};
                       #{} -> drawn(State)
                   end,
    listed(Rest, [{Name, kind(Node), Path} | Acc], Next).

%% The next of the mount's paths, which are never drawn twice.
drawn(#{mount := Mount, next := Next} = State) when Next < 1 bsl ?NODE_BITS ->
    {(Mount bsl ?NODE_BITS) bor Next, State#{next := Next + 1}};
drawn(_State) ->
    refuse(enfile).

kind(Node) -> maps:get(kind, erx_fat:attr(Node)).

fat({ok, Value}) -> Value;
fat({error, Why}) -> refuse(errno(Why)).

errno(not_found) -> enoent;
errno(not_dir) -> enotdir;
errno(is_dir) -> eisdir;
errno(Errno) when Errno =:= einval; Errno =:= enametoolong; Errno =:= eexist; Errno =:= enoent;
                  Errno =:= enospc; Errno =:= enotempty; Errno =:= enotdir; Errno =:= eisdir;
                  Errno =:= efbig -> Errno;
errno(_Finding) -> eio.

%% The mount --------------------------------------------------------------------

%% The outcome of the probe's answer, and the FAT server's mount when it serves the
%% volume (none otherwise). Only FAT16 and FAT32 are served; the selected format is the
%% volume's one reading, and the FAT type shown is the one the mount read, since the
%% medium answers each read afresh.
mounted({error, Why}, _Read, _Length, _Proxy) ->
    {#{format => unknown, mount => {none, {failed, Why}}}, none};
mounted({ok, #{format := msdosfs, also := Also, fat := Type}}, Read, Length, Proxy)
  when Type =:= 16; Type =:= 32 ->
    case erx_fat:mount(Read, Length) of
        {ok, Fat} ->
            #{type := Mounted, label := Label, serial := Serial} = erx_fat:info(Fat),
            Mount = writable(msdosfs, Also, fun() -> erx_media_medium:window(Proxy, flush) end, fun() -> owned(Fat) end),
            {#{format => msdosfs, fat => Mounted, label => Label, serial => Serial, mount => Mount}, served(Mount, Fat)};
        {error, Finding} ->
            {#{format => msdosfs, fat => Type, mount => {none, {failed, Finding}}}, none}
    end;
mounted({ok, #{format := msdosfs, fat := Type}}, _Read, _Length, _Proxy) ->
    {#{format => msdosfs, fat => Type, mount => {none, format}}, none};
mounted({ok, #{format := unknown}}, _Read, _Length, _Proxy) ->
    {#{format => unknown, mount => {none, unknown}}, none};
mounted({ok, #{format := Format}}, _Read, _Length, _Proxy) ->
    {#{format => Format, mount => {none, format}}, none}.

%% A read-only mount's one log line, naming the volume and the rule's reason.
log_read_only(#{number := Number}, #{format := Format} = Outcome) ->
    case ro_reason(Outcome) of
        none -> ok;
        Reason -> logger:notice("erx_media: volume s~b (~s) mounted read-only: ~s", [Number, Format, Reason])
    end.

%% The writable rule's fourth condition: the volume's flags, then the ownership
%% check, which runs only on a volume the flags admit and reads it whole.
owned(Fat) ->
    case erx_fat_alloc:writable(erx_fat:info(Fat)) of
        {read_only, Reason} -> Reason;
        ok -> case erx_fat:check(Fat) of
                  ok -> ok;
                  {read_only, Reason} -> Reason;
                  {error, Why} -> {none, {failed, Why}}
              end
    end.

%% A mount the writable rule refused, for a flush that failed, serves no files.
served({none, _Reason}, _Fat) -> none;
served(_Mount, Fat) -> Fat.

%% The volume's sector Sector, read through the proxy at its place on the medium.
read_sector(Proxy, Volume, Sector) ->
    case erx_media_table:place(Volume, Sector, 1) of
        {ok, Lba} -> erx_media_medium:window(Proxy, {read, Lba, 1});
        {error, erange} = Refused -> Refused
    end.
