%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_lfs).
-moduledoc """
The domain's `/data`: the `erx_fs` callback module over littlefs, the stopgap
read-write file system (docs/design-stopgap.md#littlefs-in-the-system-domain),
on one window of the block service.

Two processes serve a volume. The **owner** takes every request of the
callbacks, one at a time in arrival order, and never blocks: it hands each
request's littlefs work to the **worker**, the one process that calls
`erx_littlefs`'s operations, each on a dirty I/O scheduler. While an operation
runs, littlefs's block callbacks post `{erx_lfs_block, Op, Sector, Count, Req}`
to the owner, which sends the request to the window with
`gen_server:send_request/2`, returns to its receive, and on the window's
answer calls `erx_littlefs:complete/2`, a normal NIF that wakes the callback.

**No deadlock.** The worker's operation holds one dirty I/O thread and waits
only for the owner's `complete/2`. The owner, the window and the block driver
run on normal schedulers, and the owner never waits for anything: it makes no
synchronous call after its start, so it always reaches the next block request.
None of them uses a file of `/data`, so nothing they wait on needs a second
dirty thread or the worker.

**Failure has one answer.** A block request the window refuses or never
answers, a window or worker that ends, or a deadline in the NIF leaves the
operation's outcome unknown: the operation answers `{error, eio}`, the volume
is unavailable until the next boot, and nothing is retried or remounted.

Nodes are paths from the volume's root, `<<"/">>` and `<<"/a/b">>`, and a
handle is `{dir, Path}` or `{file, Path, Slot}`. littlefs stores no file
numbers, so the owner draws a qid path from the domain's counter the first
time it meets a path and keeps it in a table of at most 65,536 paths, which a
rename moves and a remove drops (design-storage.md, "littlefs and FAT").
littlefs keeps no modes, owners, times, links or device nodes: files show as
0644, directories as 0755, times as 0, and a make of a link or a node is
`eperm`.

The handle `erx_fs` passes every callback is the owner's pid and a reference
it made at its start, published under its registered name; the owner acts
only on a request that carries the reference.
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([start_link/2, owner/1, worker/2]).
-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4, statfs/1,
         clunk/2, read_mode/0, write/4, make/4, setattr/3, unlink/4, rename/5,
         fsync/2]).

-define(TREE, <<"data">>).
-define(ROOT, <<"/">>).
%% statfs's type: littlefs's superblock magic, "littlefs" read as its first word.
-define(LFS_MAGIC, 16#7366656c).
-define(BLOCK_SIZE, 4096).
-define(SECTOR_SIZE, 512).
-define(MIN_BLOCKS, 8).
%% Longer than a window's own call timeout, so the window answers first.
-define(DEADLINE_MS, 60000).
-define(MAX_PATHS, 65536).
-define(PATH_MAX, 1023).
-define(NAME_MAX, 255).
%% littlefs's open flags (lfs.h).
-define(LFS_O_RDONLY, 1).
-define(LFS_O_WRONLY, 2).
-define(LFS_O_RDWR, 3).
-define(LFS_O_CREAT, 16#0100).
-define(LFS_O_EXCL, 16#0200).
-define(LFS_O_TRUNC, 16#0400).
-define(LFS_O_APPEND, 16#0800).
-define(DT_DIR, 4).
-define(DT_REG, 8).
-define(GETATTR_VALID, (?ERX_P9_GETATTR_MASK_MODE bor ?ERX_P9_GETATTR_MASK_NLINK
                        bor ?ERX_P9_GETATTR_MASK_UID bor ?ERX_P9_GETATTR_MASK_GID
                        bor ?ERX_P9_GETATTR_MASK_RDEV bor ?ERX_P9_GETATTR_MASK_ATIME
                        bor ?ERX_P9_GETATTR_MASK_MTIME bor ?ERX_P9_GETATTR_MASK_CTIME
                        bor ?ERX_P9_GETATTR_MASK_INO bor ?ERX_P9_GETATTR_MASK_SIZE
                        bor ?ERX_P9_GETATTR_MASK_BLOCKS
                        bor ?ERX_P9_GETATTR_MASK_DATA_VERSION)).

-record(owner, {secret :: reference(),
                vol :: erx_littlefs:vol(),
                worker :: pid(),
                window :: pid(),
                %% The request the worker runs: its caller's alias and what
                %% turns its result into the reply.
                busy = idle :: idle | {reference() | mount, fun()},
                queue = queue:new() :: queue:queue(),
                %% The one block request the window has: its id and the NIF's request.
                block = none :: none | {gen_server:request_id(), erx_littlefs:req()},
                failed = false :: boolean(),
                %% Each path met: its qid path and data version.
                paths = #{} :: #{binary() => {pos_integer(), pos_integer()}}}).

%% ---------------------------------------------------------------------------
%% The owner and the worker
%% ---------------------------------------------------------------------------

-doc """
Starts the owner of the volume on the block service's window of `Role`,
registered as `Name`, and mounts it, formatting blocks that hold no volume.
A machine without that window starts nothing: `ignore`. Tests pass
`{window, Pid}` for a window of their own.
""".
-spec start_link(erx_blk_table:role() | {window, pid()}, atom()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Role, Name) when is_atom(Name) ->
    proc_lib:start_link(?MODULE, owner, [{start, self(), Role, Name}]).

-doc false.
owner({start, Parent, Role, Name}) ->
    %% A crash report shows no queued request, whose data is the domain's files.
    _ = process_flag(sensitive, true),
    _ = process_flag(trap_exit, true),
    case window(Role) of
        {ok, Window, Blocks} ->
            true = register(Name, self()),
            Secret = make_ref(),
            Vol = erx_littlefs:new(self(), Blocks, ?DEADLINE_MS),
            Worker = proc_lib:spawn_link(?MODULE, worker, [self(), Vol]),
            _ = erlang:monitor(process, Window),
            persistent_term:put({?MODULE, Name}, {self(), Secret}),
            proc_lib:init_ack(Parent, {ok, self()}),
            State = #owner{secret = Secret, vol = Vol, worker = Worker, window = Window},
            ?MODULE:owner(run(mount, fun mount/1, fun mounted/2, State));
        {error, {refused, no_device}} ->
            %% A machine without a disk: no volume, and no line, as erx_blk has none.
            proc_lib:init_ack(Parent, ignore);
        {error, Reason} ->
            log("no volume on the ~p window: ~p", [Role, Reason]),
            proc_lib:init_ack(Parent, ignore)
    end;
owner(#owner{secret = Secret, worker = Worker} = State) ->
    receive
        {?MODULE, Secret, Alias, Request} when is_reference(Alias), node(Alias) =:= node() ->
            ?MODULE:owner(next(State#owner{queue = queue:in({Alias, Request},
                                                             State#owner.queue)}));
        {erx_lfs_block, Op, Sector, Count, Req} ->
            ?MODULE:owner(block(Op, Sector, Count, Req, State));
        {?MODULE, Worker, done, Result} ->
            ?MODULE:owner(next(done(Result, State)));
        {'EXIT', Worker, _} ->
            log("the worker ended; /data unavailable until reboot", []),
            ?MODULE:owner(next(done({error, eio}, State#owner{failed = true})));
        {'DOWN', _, process, Window, _} when Window =:= State#owner.window,
                                             State#owner.block =:= none ->
            ?MODULE:owner(State#owner{failed = true});
        Message ->
            ?MODULE:owner(answered(Message, State))
    end.

%% The window's pid and the volume's size in blocks.
window(Role) ->
    Found = case Role of
                {window, Pid} when is_pid(Pid) -> {ok, Pid};
                _ -> erx_blk_service:window(Role)
            end,
    case Found of
        {ok, Window} ->
            case erx_blk_window:info(Window) of
                {ok, #{sectors := Sectors}} when Sectors * ?SECTOR_SIZE div ?BLOCK_SIZE >= ?MIN_BLOCKS ->
                    {ok, Window, min(Sectors * ?SECTOR_SIZE div ?BLOCK_SIZE, 1 bsl 20)};
                {ok, _} -> {error, too_small};
                Error -> Error
            end;
        Error ->
            Error
    end.

-doc false.
%% The worker runs one request's littlefs work at a time, for its owner only.
worker(Owner, Vol) ->
    receive
        {?MODULE, Owner, run, Work} ->
            Result = try Work(Vol) catch _:_ -> {error, eio} end,
            Owner ! {?MODULE, self(), done, Result},
            ?MODULE:worker(Owner, Vol)
    end.

%% The next queued request, when the worker is idle. A failed volume answers
%% eio, and a request the owner answers itself never reaches the worker.
next(#owner{busy = idle, queue = Queue} = State) ->
    case queue:out(Queue) of
        {empty, _} ->
            State;
        {{value, {Alias, _}}, Queue1} when State#owner.failed ->
            reply(Alias, {error, eio}),
            next(State#owner{queue = Queue1});
        {{value, {Alias, Request}}, Queue1} ->
            State1 = State#owner{queue = Queue1},
            case plan(Request, State1) of
                {reply, Reply, State2} ->
                    reply(Alias, Reply),
                    next(State2);
                {run, Work, Then} ->
                    run(Alias, Work, Then, State1)
            end
    end;
next(State) ->
    State.

run(Alias, Work, Then, #owner{worker = Worker} = State) ->
    Worker ! {?MODULE, self(), run, Work},
    State#owner{busy = {Alias, Then}}.

done(_Result, #owner{busy = idle} = State) ->
    State;
done(Result, #owner{busy = {Alias, Then}} = State) ->
    {Reply, State1} = Then(Result, State#owner{busy = idle}),
    reply(Alias, Reply),
    State1.

reply(mount, _Reply) -> ok;
reply(Alias, Reply) -> erlang:send(Alias, {?MODULE, Alias, Reply}).

mount(Vol) ->
    case erx_littlefs:mount(Vol) of
        {error, eintegrity} ->
            %% Blocks that hold no volume: a fresh partition.
            case erx_littlefs:format(Vol) of
                ok -> erx_littlefs:mount(Vol);
                Error -> Error
            end;
        Result ->
            Result
    end.

mounted(ok, State) ->
    log("volume mounted", []),
    {ok, State};
mounted(Error, State) ->
    log("mount failed: ~p; /data unavailable until reboot", [Error]),
    {Error, State#owner{failed = true}}.

%% A block request from the worker's operation, sent on to the window. The
%% window has no flush: it answers each write once the device has, so a
%% flush has nothing left to wait for (TODO.md, storage).
block(Op, Sector, Count, Req, #owner{failed = Failed, block = Block, window = Window} = State) ->
    Request = case {Op, Failed, Block} of
                  {_, true, _} -> refuse;
                  {_, _, {_, _}} -> refuse;
                  {read, _, _} when is_integer(Sector), is_integer(Count) -> {read, Sector, Count};
                  {write, _, _} when is_integer(Sector) -> {write, Sector, payload(Req)};
                  {flush, _, _} -> flush;
                  _ -> refuse
              end,
    case Request of
        refuse ->
            complete(Req, error),
            State#owner{failed = true};
        flush ->
            complete(Req, ok),
            State;
        {write, _, error} ->
            complete(Req, error),
            State#owner{failed = true};
        _ ->
            State#owner{block = {gen_server:send_request(Window, Request), Req}}
    end.

%% The window's answer to the block request, or a message for no one.
answered(_Message, #owner{block = none} = State) ->
    State;
answered(Message, #owner{block = {Id, Req}} = State) ->
    case gen_server:check_response(Message, Id) of
        no_reply ->
            State;
        {reply, {ok, Bytes}} when is_binary(Bytes) ->
            complete(Req, {ok, Bytes}),
            State#owner{block = none};
        {reply, ok} ->
            complete(Req, ok),
            State#owner{block = none};
        Failure ->
            %% Complete first: the callback waits on it, and logging may wait.
            complete(Req, error),
            log("block request failed: ~p; /data unavailable until reboot", [Failure]),
            State#owner{block = none, failed = true}
    end.

%% A message that claims to be a block request but holds no request of the
%% NIF changes nothing.
complete(Req, Answer) ->
    try erx_littlefs:complete(Req, Answer) catch error:badarg -> late end.

payload(Req) ->
    try erx_littlefs:payload(Req) catch error:badarg -> error end.

log(Format, Arguments) ->
    _ = erx_log:debug(["erx_lfs: ", io_lib:format(Format, Arguments)]),
    ok.

%% ---------------------------------------------------------------------------
%% Requests: each is littlefs work for the worker and what makes its reply
%% ---------------------------------------------------------------------------

plan(root, State) ->
    plan({getattr, ?ROOT}, State);
plan({walk, Dir, Name}, State) ->
    case child(Dir, Name) of
        {ok, Path} ->
            {run, fun(V) -> erx_littlefs:stat(V, Path) end,
             fun({ok, Kind, _Size}, S) -> with_qid(Path, Kind, S, fun(Qid, _) -> {ok, Path, Qid} end);
                (Error, S) -> {Error, S}
             end};
        Error ->
            {reply, Error, State}
    end;
plan({getattr, Path}, _State) ->
    {run, fun(V) -> erx_littlefs:stat(V, Path) end,
     fun({ok, Kind, Size}, S) -> with_qid(Path, Kind, S, fun(Qid, S1) -> {ok, attr(Kind, Size, Qid, S1, Path)} end);
        (Error, S) -> {Error, S}
     end};
plan({open, Path, Flags}, _State) ->
    {run, fun(V) ->
                  case erx_littlefs:stat(V, Path) of
                      {ok, directory, _} -> {ok, {dir, Path}};
                      {ok, file, _} -> open_file(V, Path, lfs_flags(Flags));
                      Error -> Error
                  end
          end,
     fun({ok, {file, _, _}} = Reply, S) when Flags band ?ERX_P9_O_TRUNC =/= 0 -> {Reply, changed(Path, S)};
        (Reply, S) -> {Reply, S}
     end};
plan({read, {file, _, Slot}, Offset, Count}, _State) ->
    work(fun(V) -> erx_littlefs:read(V, Slot, Offset, Count) end);
plan({readdir, {dir, Path}, Offset, Max}, _State) ->
    {run, fun(V) -> erx_littlefs:readdir(V, Path, Offset, Max) end,
     fun({ok, Entries}, S) -> listing(Path, Offset, Entries, S);
        (Error, S) -> {Error, S}
     end};
plan(statfs, _State) ->
    {run, fun(V) -> erx_littlefs:fsstat(V) end,
     fun({ok, Bsize, Blocks, Used}, S) ->
             Free = max(0, Blocks - Used),
             {{ok, #{type => ?LFS_MAGIC, fsid => 0, bsize => Bsize, blocks => Blocks,
                     bfree => Free, bavail => Free, files => Free, ffree => Free,
                     namelen => ?NAME_MAX}}, S};
        (Error, S) -> {Error, S}
     end};
plan({clunk, {file, _, Slot}}, _State) ->
    work(fun(V) -> erx_littlefs:close(V, Slot) end);
plan({write, {file, Path, Slot}, Offset, Data}, _State) ->
    {run, fun(V) -> erx_littlefs:write(V, Slot, Offset, Data) end,
     fun({ok, _, _} = Reply, S) -> {Reply, changed(Path, S)};
        (Error, S) -> {Error, S}
     end};
plan({make, Dir, Name, What}, State) ->
    case {child(Dir, Name), What} of
        {{ok, Path}, {file, _Mode, Flags}} ->
            Lfs = lfs_flags(Flags) bor ?LFS_O_CREAT bor ?LFS_O_EXCL,
            {run, fun(V) -> open_file(V, Path, Lfs) end,
             fun({ok, Handle}, S) -> with_qid(Path, file, S, fun(Qid, _) -> {ok, Path, Qid, Handle} end);
                (Error, S) -> {Error, S}
             end};
        {{ok, Path}, {directory, _Mode}} ->
            {run, fun(V) -> erx_littlefs:mkdir(V, Path) end,
             fun(ok, S) -> with_qid(Path, directory, S, fun(Qid, _) -> {ok, Path, Qid} end);
                (Error, S) -> {Error, S}
             end};
        {{ok, _}, _} ->
            {reply, {error, eperm}, State};
        {Error, _} ->
            {reply, Error, State}
    end;
%% A size change truncates; littlefs keeps nothing else setattr sets.
plan({setattr, Target, #{valid := Valid, size := Size}}, _State)
  when Valid band ?ERX_P9_SETATTR_VALID_SIZE =/= 0 ->
    {Path, Work} = case Target of
                       {open, {file, P, Slot}} ->
                           {P, fun(V) -> erx_littlefs:truncate(V, Slot, Size) end};
                       {open, {dir, P}} ->
                           {P, fun(_) -> {error, eisdir} end};
                       {node, P} ->
                           {P, fun(V) -> truncate_path(V, P, Size) end}
                   end,
    {run, Work, fun(ok, S) -> {ok, changed(Path, S)};
                   (Error, S) -> {Error, S}
                end};
plan({setattr, _Target, _Changes}, State) ->
    {reply, ok, State};
plan({unlink, Dir, Name, Kind}, State) ->
    case child(Dir, Name) of
        {ok, Path} ->
            {run, fun(V) -> remove(V, Path, Kind) end,
             fun(ok, S) -> {ok, S#owner{paths = moved(Path, none, S#owner.paths)}};
                (Error, S) -> {Error, S}
             end};
        Error ->
            {reply, Error, State}
    end;
plan({rename, Dir, Name, NewDir, NewName}, State) ->
    case {child(Dir, Name), child(NewDir, NewName)} of
        {{ok, From}, {ok, To}} ->
            {run, fun(V) -> erx_littlefs:rename(V, From, To) end,
             fun(ok, S) -> {ok, S#owner{paths = moved(From, To, moved(To, none, S#owner.paths))}};
                (Error, S) -> {Error, S}
             end};
        {{ok, _}, Error} -> {reply, Error, State};
        {Error, _} -> {reply, Error, State}
    end;
plan({fsync, {file, _, Slot}}, _State) ->
    work(fun(V) -> erx_littlefs:sync(V, Slot) end);
plan({Op, {dir, _}}, State) when Op =:= clunk; Op =:= fsync ->
    {reply, ok, State};
plan(_Request, State) ->
    {reply, {error, einval}, State}.

work(Work) ->
    {run, Work, fun(Result, S) -> {Result, S} end}.

open_file(V, Path, Flags) ->
    case erx_littlefs:open(V, Path, Flags) of
        {ok, Slot} -> {ok, {file, Path, Slot}};
        Error -> Error
    end.

truncate_path(V, Path, Size) ->
    case erx_littlefs:open(V, Path, ?LFS_O_WRONLY) of
        {ok, Slot} ->
            Result = erx_littlefs:truncate(V, Slot, Size),
            case erx_littlefs:close(V, Slot) of
                ok -> Result;
                Error -> Error
            end;
        Error ->
            Error
    end.

%% unlink's kind must be the entry's: rmdir of a file is enotdir, unlink of
%% a directory eisdir.
remove(V, Path, Kind) ->
    case {erx_littlefs:stat(V, Path), Kind} of
        {{ok, file, _}, directory} -> {error, enotdir};
        {{ok, directory, _}, file} -> {error, eisdir};
        {{ok, _, _}, _} -> erx_littlefs:remove(V, Path);
        {Error, _} -> Error
    end.

%% A listing's entries, each with its qid; an entry's offset is where the
%% next listing continues.
listing(Dir, Offset, Entries, State) ->
    {Dirents, State1} =
        lists:foldl(fun({Name, Kind, _Size}, {Acc, S}) ->
                            Path = join(Dir, Name),
                            case qid(Path, Kind, S) of
                                {ok, Qid, S1} ->
                                    Next = Offset + length(Acc) + 1,
                                    {[{Qid, Next, dirent_type(Kind), Name} | Acc], S1};
                                {error, _} ->
                                    {Acc, S}
                            end
                    end, {[], State}, Entries),
    {{ok, lists:reverse(Dirents)}, State1}.

%% ---------------------------------------------------------------------------
%% Paths and qids
%% ---------------------------------------------------------------------------

child(Dir, <<"..">>) -> {ok, parent(Dir)};
child(Dir, <<".">>) -> {ok, Dir};
child(_Dir, Name) when byte_size(Name) =:= 0 -> {error, einval};
child(_Dir, Name) when byte_size(Name) > ?NAME_MAX -> {error, enametoolong};
child(Dir, Name) ->
    case binary:match(Name, [<<"/">>, <<0>>]) of
        nomatch ->
            Path = join(Dir, Name),
            case byte_size(Path) > ?PATH_MAX of
                true -> {error, enametoolong};
                false -> {ok, Path}
            end;
        _ ->
            {error, einval}
    end.

join(?ROOT, Name) -> <<"/", Name/binary>>;
join(Dir, Name) -> <<Dir/binary, "/", Name/binary>>.

parent(?ROOT) ->
    ?ROOT;
parent(Path) ->
    %% Names are bytes, not UTF-8, so the split is binary's, not string's.
    {At, _} = lists:last(binary:matches(Path, <<"/">>)),
    case At of
        0 -> ?ROOT;
        _ -> binary:part(Path, 0, At)
    end.

with_qid(Path, Kind, State, Reply) ->
    case qid(Path, Kind, State) of
        {ok, Qid, State1} -> {Reply(Qid, State1), State1};
        Error -> {Error, State}
    end.

%% A path's qid, drawing its qid path and version the first time it is met.
qid(Path, Kind, #owner{paths = Paths} = State) ->
    case Paths of
        #{Path := {Id, Version}} ->
            {ok, {qid_type(Kind), Version band 16#ffffffff, Id}, State};
        _ when map_size(Paths) >= ?MAX_PATHS ->
            {error, enfile};
        _ ->
            case {erx_fs_version:draw(), erx_fs_version:draw()} of
                {{ok, Id}, {ok, Version}} ->
                    qid(Path, Kind, State#owner{paths = Paths#{Path => {Id, Version}}});
                _ ->
                    {error, eio}
            end
    end.

%% A change to a file's data draws it a new version.
changed(Path, #owner{paths = Paths} = State) ->
    case {Paths, erx_fs_version:draw()} of
        {#{Path := {Id, _}}, {ok, Version}} -> State#owner{paths = Paths#{Path => {Id, Version}}};
        _ -> State
    end.

%% Moves the entries of From and everything under it to To, or drops them.
moved(From, To, Paths) ->
    Prefix = <<From/binary, "/">>,
    maps:fold(fun(Path, Entry, Acc) when Path =:= From ->
                      put_moved(To, <<>>, Entry, Acc);
                 (Path, Entry, Acc) ->
                      case Path of
                          <<Prefix:(byte_size(Prefix))/binary, Rest/binary>> ->
                              put_moved(To, <<"/", Rest/binary>>, Entry, Acc);
                          _ ->
                              Acc#{Path => Entry}
                      end
              end, #{}, Paths).

put_moved(none, _Rest, _Entry, Acc) -> Acc;
put_moved(To, Rest, Entry, Acc) -> Acc#{<<To/binary, Rest/binary>> => Entry}.

version(Path, #owner{paths = Paths}) ->
    {_, Version} = map_get(Path, Paths),
    Version.

qid_type(directory) -> ?ERX_P9_QTDIR;
qid_type(file) -> 0.

dirent_type(directory) -> ?DT_DIR;
dirent_type(file) -> ?DT_REG.

attr(Kind, Size, Qid, State, Path) ->
    {Mode, Nlink} = case Kind of
                        directory -> {?ERX_P9_S_IFDIR bor 8#755, 2};
                        file -> {?ERX_P9_S_IFREG bor 8#644, 1}
                    end,
    #{valid => ?GETATTR_VALID, qid => Qid, mode => Mode, uid => 0, gid => 0,
      nlink => Nlink, rdev => 0, size => Size, blksize => ?BLOCK_SIZE,
      blocks => (Size + 511) div 512,
      atime_sec => 0, atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0,
      ctime_sec => 0, ctime_nsec => 0, btime_sec => 0, btime_nsec => 0,
      gen => 0, data_version => version(Path, State)}.

%% Linux's open flags as littlefs's: the access mode, truncation and append.
lfs_flags(Flags) ->
    Access = case Flags band ?ERX_P9_O_ACCMODE of
                 ?ERX_P9_O_WRONLY -> ?LFS_O_WRONLY;
                 ?ERX_P9_O_RDWR -> ?LFS_O_RDWR;
                 _ -> ?LFS_O_RDONLY
             end,
    lists:foldl(fun({Bit, Lfs}, Acc) when Flags band Bit =/= 0 -> Acc bor Lfs;
                   (_, Acc) -> Acc
                end, Access, [{?ERX_P9_O_TRUNC, ?LFS_O_TRUNC}, {?ERX_P9_O_APPEND, ?LFS_O_APPEND}]).

%% ---------------------------------------------------------------------------
%% erx_fs's callbacks: one request to the owner each
%% ---------------------------------------------------------------------------

call({Pid, Secret}, Request) ->
    Alias = erlang:monitor(process, Pid, [{alias, reply_demonitor}]),
    erlang:send(Pid, {?MODULE, Secret, Alias, Request}),
    receive
        {?MODULE, Alias, Reply} -> Reply;
        {'DOWN', Alias, process, _, _} -> {error, eio}
    end.

-doc false.
init(Name) when is_atom(Name) ->
    {Pid, Secret} = persistent_term:get({?MODULE, Name}),
    true = Pid =:= whereis(Name),
    {ok, {Pid, Secret}}.

-doc false.
root(Server) ->
    case call(Server, root) of
        {ok, #{qid := Qid}} -> {ok, ?TREE, ?ROOT, Qid};
        %% A volume that is unavailable still roots a tree, whose every
        %% request then answers eio.
        _ -> {ok, ?TREE, ?ROOT, {?ERX_P9_QTDIR, 0, 0}}
    end.

-doc false.
walk(Dir, Name, Server) -> call(Server, {walk, Dir, Name}).
-doc false.
getattr(Path, Server) -> call(Server, {getattr, Path}).
-doc false.
open(Path, Flags, Server) -> call(Server, {open, Path, Flags}).
-doc false.
read(Handle, Offset, Count, Server) -> call(Server, {read, Handle, Offset, Count}).
-doc false.
readdir(Handle, Offset, Max, Server) -> call(Server, {readdir, Handle, Offset, Max}).
-doc false.
statfs(Server) ->
    case call(Server, statfs) of
        {ok, _} = Reply -> Reply;
        _ -> {ok, #{type => ?LFS_MAGIC, fsid => 0, bsize => ?BLOCK_SIZE, blocks => 0,
                    bfree => 0, bavail => 0, files => 0, ffree => 0, namelen => ?NAME_MAX}}
    end.
-doc false.
clunk(Handle, Server) ->
    _ = call(Server, {clunk, Handle}),
    ok.
-doc false.
read_mode() -> helper.
-doc false.
write(Handle, Offset, Data, Server) -> call(Server, {write, Handle, Offset, Data}).
-doc false.
make(Dir, Name, What, Server) -> call(Server, {make, Dir, Name, What}).
-doc false.
setattr(Target, Changes, Server) -> call(Server, {setattr, Target, Changes}).
-doc false.
unlink(Dir, Name, Kind, Server) -> call(Server, {unlink, Dir, Name, Kind}).
-doc false.
rename(Dir, Name, NewDir, NewName, Server) -> call(Server, {rename, Dir, Name, NewDir, NewName}).
-doc false.
fsync(Handle, Server) -> call(Server, {fsync, Handle}).
