%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The littlefs NIF and erx_lfs on the host over a RAM window
%% (test/host/erx_littlefs_test.rb). The runtime runs with one dirty I/O
%% scheduler, so every case also shows that a block callback completes
%% through the owner on normal schedulers. Each case prints "ok Name";
%% main/0 halts 0 only when all pass.
-module(erx_littlefs_tests).

-export([main/0, window/3]).
-export([synced_file_survives_a_cut/0, tree_operations/0, block_error_ends_the_owner/0,
         worker_end_ends_the_owner/0, window_end_ends_the_owner/0,
         mount_failure_ends_the_owner/0, corrupt_volume_never_formats/0, blank_blocks_do_not_mount/0,
         deadline_ends_a_request/0, refuses_bad_arguments/0, fsync_flushes_the_window/0,
         failed_flush_fails_the_fsync/0, a_tree_reaches_only_its_own/0,
         a_home_reaches_only_its_own/0, a_state_tree_reaches_only_its_own/0, a_grant_without_its_root_is_not_started/0]).

-include("generated/erx_abi.hrl").

-define(SECTOR, 512).
-define(DISK_SECTORS, 2048).
%% The fresh volume of a DISK_SECTORS partition, as installation writes it: lfs-format's
%% output (DataVolume.format), which the test leaves in the runtime's directory.
-define(VOLUME, "data.lfs").
-define(BLOCK, 4096).

main() ->
    ok = erx_fs_version:init(),
    Cases = [synced_file_survives_a_cut, tree_operations, block_error_ends_the_owner,
             worker_end_ends_the_owner, window_end_ends_the_owner,
             mount_failure_ends_the_owner, corrupt_volume_never_formats, blank_blocks_do_not_mount,
             deadline_ends_a_request, refuses_bad_arguments, fsync_flushes_the_window,
             failed_flush_fails_the_fsync, a_tree_reaches_only_its_own, a_home_reaches_only_its_own, a_state_tree_reaches_only_its_own,
             a_grant_without_its_root_is_not_started],
    Results = [run(Case) || Case <- Cases],
    erlang:halt(case lists:all(fun(R) -> R end, Results) of true -> 0; false -> 1 end).

run(Case) ->
    try ?MODULE:Case() of
        ok -> io:format("ok ~s~n", [Case]), true
    catch
        Class:Reason:Stack ->
            io:format("FAIL ~s ~p:~p ~p~n", [Case, Class, Reason, Stack]),
            false
    end.

%% ---------------------------------------------------------------------------
%% A RAM window: answers gen_server calls as erx_blk_window does, and counts the flushes
%% it receives. Mode normal answers every request; fail answers eio to every request but
%% info; flush_fail answers eio to a flush alone; silent answers nothing.
%% ---------------------------------------------------------------------------

start_window(Disk) ->
    proc_lib:spawn(?MODULE, window, [Disk, normal, 0]).

-doc false.
window(Disk, Mode, Flushes) ->
    receive
        {'$gen_call', From, Request} ->
            {Reply, Disk1} = serve(Request, Disk, Mode),
            case Mode of
                silent -> ok;
                _ -> gen_server:reply(From, Reply)
            end,
            window(Disk1, Mode, Flushes + case Request of flush -> 1; _ -> 0 end);
        {mode, Mode1} ->
            window(Disk, Mode1, Flushes);
        {snapshot, Pid} ->
            Pid ! {snapshot, Disk},
            window(Disk, Mode, Flushes);
        {flushes, Pid} ->
            Pid ! {flushes, Flushes},
            window(Disk, Mode, Flushes)
    end.

serve(info, Disk, _) ->
    {{ok, #{role => data, sectors => byte_size(Disk) div ?SECTOR}}, Disk};
serve(_, Disk, fail) ->
    {{error, eio}, Disk};
serve(flush, Disk, flush_fail) ->
    {{error, eio}, Disk};
serve(flush, Disk, _) ->
    {ok, Disk};
serve({read, Sector, Count}, Disk, _) ->
    {{ok, binary:part(Disk, Sector * ?SECTOR, Count * ?SECTOR)}, Disk};
serve({write, Sector, Bytes}, Disk, _) ->
    At = Sector * ?SECTOR,
    <<Before:At/binary, _:(byte_size(Bytes))/binary, After/binary>> = Disk,
    {ok, <<Before/binary, Bytes/binary, After/binary>>}.

%% A medium's data partition as installation leaves it: the fresh volume's blocks, then
%% zeros.
fresh_disk() ->
    {ok, Volume} = file:read_file(?VOLUME),
    <<Volume/binary, 0:((?DISK_SECTORS * ?SECTOR) - byte_size(Volume))/unit:8>>.

snapshot(Window) ->
    Window ! {snapshot, self()},
    receive {snapshot, Disk} -> Disk after 5000 -> error(no_snapshot) end.

flushes(Window) ->
    Window ! {flushes, self()},
    receive {flushes, Flushes} -> Flushes after 5000 -> error(no_flushes) end.

start_volume(Disk, Name) ->
    Window = start_window(Disk),
    {ok, Owner} = erx_lfs:start_link({window, Window}, Name),
    unlink(Owner),
    {ok, Fs} = erx_lfs:init({Name, data}),
    {Window, Owner, Fs}.

stop_volume({Window, Owner, _}) ->
    exit(Owner, kill),
    exit(Window, kill),
    ok.

%% ---------------------------------------------------------------------------
%% Cases
%% ---------------------------------------------------------------------------

%% A file synced before the power cut is read back whole after it, on a
%% fresh owner over the blocks as the cut left them; a file written but not
%% synced holds none of its data.
synced_file_survives_a_cut() ->
    Volume = {Window, _, Fs} = start_volume(fresh_disk(), lfs_cut1),
    {ok, <<"data">>, Root, _} = erx_lfs:root(Fs),
    Data = binary:copy(<<"synced data ">>, 1000),
    {ok, Path, _, Handle} = erx_lfs:make(Root, <<"kept">>, {file, 8#644, ?ERX_P9_O_RDWR}, Fs),
    {ok, Size, 0} = erx_lfs:write(Handle, 0, Data, Fs),
    Size = byte_size(Data),
    ok = erx_lfs:fsync(Handle, Fs),
    {ok, _, _, Lost} = erx_lfs:make(Root, <<"lost">>, {file, 8#644, ?ERX_P9_O_RDWR}, Fs),
    {ok, _, _} = erx_lfs:write(Lost, 0, <<"never synced">>, Fs),
    Image = snapshot(Window),
    ok = stop_volume(Volume),
    Again = {_, _, Fs2} = start_volume(Image, lfs_cut2),
    {ok, Path, _} = erx_lfs:walk(Root, <<"kept">>, Fs2),
    {ok, #{size := Size}} = erx_lfs:getattr(Path, Fs2),
    {ok, H2} = erx_lfs:open(Path, 0, Fs2),
    Data = read_all(H2, 0, Size, Fs2, <<>>),
    ok = erx_lfs:clunk(H2, Fs2),
    case erx_lfs:walk(Root, <<"lost">>, Fs2) of
        {error, enoent} -> ok;
        {ok, LostPath, _} -> {ok, #{size := 0}} = erx_lfs:getattr(LostPath, Fs2)
    end,
    stop_volume(Again).

read_all(_Handle, Offset, Size, _Fs, Acc) when Offset >= Size ->
    Acc;
read_all(Handle, Offset, Size, Fs, Acc) ->
    {ok, Bytes} = erx_lfs:read(Handle, Offset, 4096, Fs),
    true = byte_size(Bytes) > 0,
    read_all(Handle, Offset + byte_size(Bytes), Size, Fs, <<Acc/binary, Bytes/binary>>).

%% An fsync reaches the medium: littlefs's sync goes to the window as a flush, so the
%% fsync answers only once the window has flushed.
fsync_flushes_the_window() ->
    Volume = {Window, _, Fs} = start_volume(fresh_disk(), lfs_flush),
    {ok, _, Root, _} = erx_lfs:root(Fs),
    {ok, _, _, Handle} = erx_lfs:make(Root, <<"f">>, {file, 8#644, ?ERX_P9_O_RDWR}, Fs),
    {ok, 4, 0} = erx_lfs:write(Handle, 0, <<"data">>, Fs),
    Before = flushes(Window),
    ok = erx_lfs:fsync(Handle, Fs),
    true = flushes(Window) > Before,
    stop_volume(Volume).

%% A flush the window fails fails the fsync with eio though every write succeeded, and
%% breaks the volume: the owner and its worker end, as at any block failure.
failed_flush_fails_the_fsync() ->
    Volume = {Window, Owner, Fs} = start_volume(fresh_disk(), lfs_flush_fail),
    {ok, _, Root, _} = erx_lfs:root(Fs),
    {ok, _, _, Handle} = erx_lfs:make(Root, <<"f">>, {file, 8#644, ?ERX_P9_O_RDWR}, Fs),
    Monitors = [erlang:monitor(process, Pid) || Pid <- [Owner, worker(Owner)]],
    Window ! {mode, flush_fail},
    {ok, 4, 0} = erx_lfs:write(Handle, 0, <<"data">>, Fs),
    {error, eio} = erx_lfs:fsync(Handle, Fs),
    ok = ended(Monitors),
    {error, eio} = erx_lfs:getattr(<<"/">>, Fs),
    stop_volume(Volume).

%% Directories, listings, renames, removals and their refusals.
tree_operations() ->
    Volume = {_, _, Fs} = start_volume(fresh_disk(), lfs_tree),
    {ok, _, Root, {?ERX_P9_QTDIR, _, _}} = erx_lfs:root(Fs),
    {ok, Dir, {?ERX_P9_QTDIR, _, DirId}} = erx_lfs:make(Root, <<"d">>, {directory, 8#755, self()}, Fs),
    {ok, File, {0, _, FileId}, H} = erx_lfs:make(Dir, <<"f">>, {file, 8#644, ?ERX_P9_O_WRONLY}, Fs),
    {ok, 3, 0} = erx_lfs:write(H, 0, <<"abc">>, Fs),
    %% A write-only file refuses a read, which littlefs would assert on.
    {error, ebadf} = erx_lfs:read(H, 0, 3, Fs),
    ok = erx_lfs:clunk(H, Fs),
    {error, eexist} = erx_lfs:make(Dir, <<"f">>, {file, 8#644, ?ERX_P9_O_WRONLY}, Fs),
    {error, eperm} = erx_lfs:make(Dir, <<"l">>, {symlink, <<"f">>}, Fs),
    {error, einval} = erx_lfs:walk(Dir, <<"a/b">>, Fs),
    %% `.` and `..` are no entry: the grammar refuses `..` before any walk (erx_fs_grant).
    {error, einval} = erx_lfs:walk(Dir, <<"..">>, Fs),
    {error, einval} = erx_lfs:walk(Dir, <<".">>, Fs),
    {ok, DirH} = erx_lfs:open(Dir, 0, Fs),
    {ok, [{{0, _, FileId}, 1, 8, <<"f">>}]} = erx_lfs:readdir(DirH, 0, 16, Fs),
    {ok, []} = erx_lfs:readdir(DirH, 1, 16, Fs),
    {error, enotempty} = erx_lfs:unlink(Root, <<"d">>, directory, Fs),
    {error, eisdir} = erx_lfs:unlink(Root, <<"d">>, file, Fs),
    ok = erx_lfs:rename(Dir, <<"f">>, Root, <<"g">>, Fs),
    {ok, Moved, {0, _, FileId}} = erx_lfs:walk(Root, <<"g">>, Fs),
    {ok, #{size := 3}} = erx_lfs:getattr(Moved, Fs),
    ok = erx_lfs:setattr({node, Moved}, #{valid => ?ERX_P9_SETATTR_VALID_SIZE, size => 1}, Fs),
    {ok, #{size := 1}} = erx_lfs:getattr(Moved, Fs),
    {error, enoent} = erx_lfs:getattr(File, Fs),
    ok = erx_lfs:unlink(Root, <<"g">>, file, Fs),
    ok = erx_lfs:unlink(Root, <<"d">>, directory, Fs),
    {error, enoent} = erx_lfs:walk(Root, <<"d">>, Fs),
    %% A name that is not UTF-8 is bytes like any other.
    {ok, _, _} = erx_lfs:make(Root, <<"\xff">>, {directory, 8#755, self()}, Fs),
    ok = erx_lfs:rename(Root, <<"\xff">>, Root, <<"\xfe">>, Fs),
    ok = erx_lfs:unlink(Root, <<"\xfe">>, directory, Fs),
    {ok, #{bsize := 4096, blocks := 256}} = erx_lfs:statfs(Fs),
    true = DirId =/= FileId,
    stop_volume(Volume).

%% A grant of the packages tree reaches the volume's packages/ directory and
%% nothing above it: the mount made the directory, a file of the data tree's
%% root is no entry of the packages root, and no name walks, makes, removes
%% or renames out of it. The data tree, the whole volume, sees what the
%% packages grant wrote under packages/. A grant rooted at installed/, as the
%% app template's row roots its packages grant, reaches what lies there and
%% neither new/ beside it, where an upload in progress lies, nor anything above.
a_tree_reaches_only_its_own() ->
    Volume = {_, _, Data} = start_volume(fresh_disk(), lfs_trees),
    {ok, Packages} = erx_lfs:init({lfs_trees, packages}),
    {ok, <<"data">>, Top, _} = erx_lfs:root(Data),
    {ok, <<"data">>, Root, {?ERX_P9_QTDIR, _, _}} = erx_lfs:root(Packages),
    {ok, Root, {?ERX_P9_QTDIR, _, _}} = erx_lfs:walk(Top, <<"packages">>, Data),
    {ok, _, _, Secret} = erx_lfs:make(Top, <<"secret">>, {file, 8#644, ?ERX_P9_O_RDWR}, Data),
    ok = erx_lfs:clunk(Secret, Data),
    {error, enoent} = erx_lfs:walk(Root, <<"secret">>, Packages),
    Escapes = [erx_lfs:walk(Root, <<"..">>, Packages),
               erx_lfs:make(Root, <<"..">>, {directory, 8#755, self()}, Packages),
               erx_lfs:make(Root, <<"..">>, {file, 8#644, ?ERX_P9_O_RDWR}, Packages),
               erx_lfs:unlink(Root, <<"..">>, directory, Packages),
               erx_lfs:rename(Root, <<"..">>, Root, <<"moved">>, Packages),
               erx_lfs:rename(Root, <<"x">>, Root, <<"..">>, Packages),
               erx_lfs:unlink(Root, <<".">>, directory, Packages)],
    [{error, einval}] = lists:usort(Escapes),
    {ok, _, _, App} = erx_lfs:make(Root, <<"a.app">>, {file, 8#644, ?ERX_P9_O_RDWR}, Packages),
    ok = erx_lfs:clunk(App, Packages),
    {ok, RootH} = erx_lfs:open(Root, 0, Packages),
    {ok, Listed} = erx_lfs:readdir(RootH, 0, 16, Packages),
    [<<"a.app">>, <<"installed">>] = lists:sort([Name || {_, _, _, Name} <- Listed]),
    ok = erx_lfs:clunk(RootH, Packages),
    {ok, _, _} = erx_lfs:walk(Top, <<"secret">>, Data),
    {ok, _, {0, _, _}} = erx_lfs:walk(Root, <<"a.app">>, Data),
    {ok, InstalledArgs} = erx_lfs:subtree({lfs_trees, packages}, installed, #{client => 5, principal => <<"clock">>}),
    {ok, Installed} = erx_lfs:init(InstalledArgs),
    {ok, <<"data">>, Under, {?ERX_P9_QTDIR, _, _}} = erx_lfs:root(Installed),
    {ok, Under, {?ERX_P9_QTDIR, _, _}} = erx_lfs:walk(Root, <<"installed">>, Packages),
    {ok, New, _} = erx_lfs:make(Root, <<"new">>, {directory, 8#755, self()}, Packages),
    {ok, _, _, Upload} = erx_lfs:make(New, <<"tmp.1">>, {file, 8#644, ?ERX_P9_O_RDWR}, Packages),
    ok = erx_lfs:clunk(Upload, Packages),
    {ok, _, _, Accepted} = erx_lfs:make(Under, <<"b.app">>, {file, 8#644, ?ERX_P9_O_RDWR}, Packages),
    ok = erx_lfs:clunk(Accepted, Packages),
    {ok, _, {0, _, _}} = erx_lfs:walk(Under, <<"b.app">>, Installed),
    [{error, enoent}] = lists:usort([erx_lfs:walk(Under, Name, Installed) || Name <- [<<"new">>, <<"a.app">>]]),
    {error, einval} = erx_lfs:walk(Under, <<"..">>, Installed),
    [{error, einval}] = lists:usort([erx_lfs:subtree({lfs_trees, data}, installed, #{client => 5, principal => <<"clock">>}),
                                     erx_lfs:subtree({lfs_trees, packages}, apps, #{client => 5, principal => <<"clock">>}),
                                     erx_lfs:subtree({lfs_trees, packages}, packages, #{client => 5, principal => <<"clock">>})]),
    stop_volume(Volume).

%% A grant of a development state tree, bt_state or ssh_state, reaches the volume's bt/
%% or ssh/ directory, which the mount made, and nothing beside or above it: neither the
%% other state tree's files nor the data tree's, and no name walks, makes, removes or
%% renames out of it. The data tree, as root's session holds it at /data, sees what the
%% grant wrote. No row's tree roots a state grant anywhere else.
a_state_tree_reaches_only_its_own() ->
    Volume = {_, _, Data} = start_volume(fresh_disk(), lfs_state),
    {ok, <<"data">>, Top, _} = erx_lfs:root(Data),
    {ok, _, _, Secret} = erx_lfs:make(Top, <<"secret">>, {file, 8#644, ?ERX_P9_O_RDWR}, Data),
    ok = erx_lfs:clunk(Secret, Data),
    Trees = [{bt_state, <<"bt">>, <<"bonds.1">>}, {ssh_state, <<"ssh">>, <<"ssh_host_ed25519_key">>}],
    Grants = [begin
                  {ok, Grant} = erx_lfs:init({lfs_state, Tree}),
                  {ok, <<"data">>, Root, {?ERX_P9_QTDIR, _, _}} = erx_lfs:root(Grant),
                  {ok, Root, {?ERX_P9_QTDIR, _, _}} = erx_lfs:walk(Top, Dir, Data),
                  {ok, RootH} = erx_lfs:open(Root, 0, Grant),
                  {ok, []} = erx_lfs:readdir(RootH, 0, 16, Grant),
                  ok = erx_lfs:clunk(RootH, Grant),
                  {ok, _, _, Made} = erx_lfs:make(Root, Name, {file, 8#600, ?ERX_P9_O_RDWR}, Grant),
                  ok = erx_lfs:clunk(Made, Grant),
                  {ok, _, {0, _, _}} = erx_lfs:walk(Root, Name, Data),
                  Escapes = [erx_lfs:walk(Root, <<"..">>, Grant),
                             erx_lfs:make(Root, <<"..">>, {directory, 8#755, self()}, Grant),
                             erx_lfs:unlink(Root, <<"..">>, directory, Grant),
                             erx_lfs:rename(Root, Name, Root, <<"..">>, Grant)],
                  [{error, einval}] = lists:usort(Escapes),
                  [{error, einval}] = lists:usort([erx_lfs:subtree({lfs_state, Tree}, Sub, #{client => 5, principal => <<"root">>})
                                                   || Sub <- [installed, home, bt_state, ssh_state]]),
                  {Grant, Root, Name}
              end || {Tree, Dir, Name} <- Trees],
    [{BtGrant, BtRoot, BtName}, {SshGrant, SshRoot, SshName}] = Grants,
    [{error, enoent}] = lists:usort([erx_lfs:walk(BtRoot, Other, BtGrant) || Other <- [SshName, <<"secret">>, <<"ssh">>]] ++
                                    [erx_lfs:walk(SshRoot, Other, SshGrant) || Other <- [BtName, <<"secret">>, <<"bt">>]]),
    stop_volume(Volume).

%% A home grant (docs/design-files.md, "A user's home") is rooted at its user's home
%% alone: root's at /root and any other user's at /home/NAME, each made by the grant's
%% start, so the grant sees neither the volume's other files nor another user's home,
%% and a name that is not one path name, a tree other than home, or a home grant with no
%% tree roots nothing.
a_home_reaches_only_its_own() ->
    Volume = {_, _, Data} = start_volume(fresh_disk(), lfs_homes),
    {ok, <<"data">>, Top, _} = erx_lfs:root(Data),
    {ok, _, _, Secret} = erx_lfs:make(Top, <<"secret">>, {file, 8#644, ?ERX_P9_O_RDWR}, Data),
    ok = erx_lfs:clunk(Secret, Data),
    Grant = fun(User) ->
                    {ok, Args} = erx_lfs:subtree({lfs_homes, home}, home, #{client => 5, principal => User}),
                    {ok, Server} = erx_lfs:init(Args),
                    {ok, <<"data">>, Root, {?ERX_P9_QTDIR, _, _}} = erx_lfs:root(Server),
                    {Root, Server}
            end,
    {<<"/root">>, RootHome} = Grant(<<"root">>),
    {<<"/home/alice">>, Alice} = Grant(<<"alice">>),
    {ok, <<"/root">>, _} = erx_lfs:walk(Top, <<"root">>, Data),
    {ok, Homes, _} = erx_lfs:walk(Top, <<"home">>, Data),
    {ok, <<"/home/alice">>, _} = erx_lfs:walk(Homes, <<"alice">>, Data),
    {ok, _, _, Note} = erx_lfs:make(<<"/home/alice">>, <<"note">>, {file, 8#644, ?ERX_P9_O_RDWR}, Alice),
    ok = erx_lfs:clunk(Note, Alice),
    %% The data grant and root's home grant overlap: both answer the tree data, and
    %% /root/notes through the data grant and notes through the home grant are one
    %% file, one qid path of that tree's numbering.
    {ok, _, {_, _, NotesPath}, Notes} = erx_lfs:make(<<"/root">>, <<"notes">>, {file, 8#644, ?ERX_P9_O_RDWR}, RootHome),
    ok = erx_lfs:clunk(Notes, RootHome),
    {ok, _, {0, _, NotesPath}} = erx_lfs:walk(<<"/root">>, <<"notes">>, Data),
    ok = erx_lfs:unlink(<<"/root">>, <<"notes">>, file, RootHome),
    {ok, Listed} = erx_lfs:readdir(element(2, erx_lfs:open(<<"/root">>, 0, RootHome)), 0, 16, RootHome),
    [] = [Name || {_, _, _, Name} <- Listed, Name =/= <<".">>, Name =/= <<"..">>],
    [{error, enoent}] = lists:usort([erx_lfs:walk(<<"/root">>, Name, RootHome)
                                     || Name <- [<<"secret">>, <<"note">>, <<"home">>, <<"alice">>]]),
    Escapes = [erx_lfs:walk(<<"/root">>, <<"..">>, RootHome),
               erx_lfs:walk(<<"/home/alice">>, <<"..">>, Alice),
               erx_lfs:make(<<"/root">>, <<"..">>, {directory, 8#755, self()}, RootHome),
               erx_lfs:rename(<<"/root">>, <<"x">>, <<"/root">>, <<"..">>, RootHome)],
    [{error, einval}] = lists:usort(Escapes),
    {_, Again} = Grant(<<"alice">>),
    {ok, _, {0, _, _}} = erx_lfs:walk(<<"/home/alice">>, <<"note">>, Again),
    Refused = [erx_lfs:subtree({lfs_homes, home}, home, #{client => 5, principal => Bad})
               || Bad <- [<<>>, <<".">>, <<"..">>, <<"a/b">>, <<"../root">>, <<"a", 0, "b">>]] ++
              [erx_lfs:subtree({lfs_homes, data}, home, #{client => 5, principal => <<"root">>}),
               erx_lfs:subtree({lfs_homes, packages}, home, #{client => 5, principal => <<"root">>}),
               erx_lfs:subtree({lfs_homes, home}, installed, #{client => 5, principal => <<"root">>})],
    [{error, einval}] = lists:usort(Refused),
    {'EXIT', _} = catch erx_lfs:init({lfs_homes, home}),
    stop_volume(Volume).

%% A block request the window refuses fails its operation with eio, and the
%% owner ends, which ends its worker: nothing answers from a volume whose
%% state is unknown, and the storage domain's restart mounts it afresh.
block_error_ends_the_owner() ->
    Volume = {Window, Owner, Fs} = start_volume(fresh_disk(), lfs_fail),
    {ok, _, Root, _} = erx_lfs:root(Fs),
    Worker = worker(Owner),
    Monitors = [erlang:monitor(process, Pid) || Pid <- [Owner, Worker]],
    Window ! {mode, fail},
    {error, eio} = erx_lfs:make(Root, <<"x">>, {directory, 8#755, self()}, Fs),
    ok = ended(Monitors),
    {error, eio} = erx_lfs:walk(Root, <<"x">>, Fs),
    stop_volume(Volume).

%% A worker that ends ends its owner, and the request it ran answers eio.
worker_end_ends_the_owner() ->
    Volume = {_, Owner, Fs} = start_volume(fresh_disk(), lfs_worker),
    {ok, _, _, _} = erx_lfs:root(Fs),
    Monitor = erlang:monitor(process, Owner),
    exit(worker(Owner), kill),
    ok = ended([Monitor]),
    {error, eio} = erx_lfs:getattr(<<"/">>, Fs),
    stop_volume(Volume).

%% A window that ends ends the owner and its worker.
window_end_ends_the_owner() ->
    Volume = {Window, Owner, Fs} = start_volume(fresh_disk(), lfs_window),
    {ok, _, _, _} = erx_lfs:root(Fs),
    Monitors = [erlang:monitor(process, Pid) || Pid <- [Owner, worker(Owner)]],
    exit(Window, kill),
    ok = ended(Monitors),
    stop_volume(Volume).

%% A mount that fails ends the owner before it answers its start, so a
%% volume that did not mount never starts.
mount_failure_ends_the_owner() ->
    Window = start_window(<<0:(?DISK_SECTORS * ?SECTOR)/unit:8>>),
    Window ! {mode, fail},
    Trapped = process_flag(trap_exit, true),
    %% The link's 'EXIT', which proc_lib:start_link consumes, would kill a
    %% caller that did not trap exits.
    {error, _} = erx_lfs:start_link({window, Window}, lfs_unmounted),
    process_flag(trap_exit, Trapped),
    undefined = whereis(lfs_unmounted),
    exit(Window, kill),
    ok.

%% A populated volume whose superblock pair, both copies of the root's metadata pair, is
%% corrupt fails to mount with eintegrity, and the mount writes nothing: the files stay
%% for repair and the volume is never formatted over.
corrupt_volume_never_formats() ->
    Volume = {Window, _, Fs} = start_volume(fresh_disk(), lfs_corrupt1),
    {ok, <<"data">>, Root, _} = erx_lfs:root(Fs),
    {ok, _, _, Handle} = erx_lfs:make(Root, <<"kept">>, {file, 8#644, ?ERX_P9_O_RDWR}, Fs),
    {ok, 4000, 0} = erx_lfs:write(Handle, 0, binary:copy(<<"kept">>, 1000), Fs),
    ok = erx_lfs:fsync(Handle, Fs),
    Populated = snapshot(Window),
    ok = stop_volume(Volume),
    Corrupt = corrupt_block(corrupt_block(Populated, 0), 1),
    unmounted(Corrupt, lfs_corrupt2).

%% Blocks that hold no volume are no special case: the mount fails as for a corrupt one.
blank_blocks_do_not_mount() ->
    unmounted(<<0:(?DISK_SECTORS * ?SECTOR)/unit:8>>, lfs_blank).

%% The owner over Disk answers eintegrity and ends, and Disk is as it was.
unmounted(Disk, Name) ->
    Window = start_window(Disk),
    Trapped = process_flag(trap_exit, true),
    %% The link's 'EXIT', which proc_lib:start_link consumes, would kill a
    %% caller that did not trap exits.
    {error, eintegrity} = erx_lfs:start_link({window, Window}, Name),
    process_flag(trap_exit, Trapped),
    undefined = whereis(Name),
    Disk = snapshot(Window),
    exit(Window, kill),
    ok.

%% Disk with every byte of block Index inverted.
corrupt_block(Disk, Index) ->
    At = Index * ?BLOCK,
    <<Before:At/binary, Block:?BLOCK/binary, After/binary>> = Disk,
    <<Before/binary, << <<(B bxor 16#ff)>> || <<B>> <= Block >>/binary, After/binary>>.

%% The owner's worker: the one process it linked to besides its parent. It is
%% sensitive, so its initial call does not show.
worker(Owner) ->
    [{links, Links}, {parent, Parent}] = process_info(Owner, [links, parent]),
    [Worker] = [Pid || Pid <- Links, is_pid(Pid), Pid =/= Parent],
    Worker.

ended(Monitors) ->
    lists:foreach(fun(Monitor) ->
                          receive {'DOWN', Monitor, process, _, _} -> ok
                          after 5000 -> error(not_ended)
                          end
                  end, Monitors).

%% A block request nobody answers ends at its deadline as eio; the owner's
%% answer after it is late and changes nothing, and the volume stays failed.
deadline_ends_a_request() ->
    Vol = erx_littlefs:new(self(), 16, 200),
    Self = self(),
    _ = spawn(fun() -> Self ! {result, erx_littlefs:mount(Vol)} end),
    {Req, Count} = receive {erx_lfs_block, read, _, C, R} -> {R, C} after 5000 -> error(no_request) end,
    {error, eio} = receive {result, Result} -> Result after 5000 -> error(no_deadline) end,
    late = erx_littlefs:complete(Req, {ok, <<0:(Count * 512)/unit:8>>}),
    true = erx_littlefs:broken(Vol),
    {error, eio} = erx_littlefs:mount(Vol),
    ok.

%% Arguments outside the NIF's limits are badarg, never a crash.
refuses_bad_arguments() ->
    Bad = [fun() -> erx_littlefs:new(self(), 4, 100) end,
           fun() -> erx_littlefs:new(self(), 16, 0) end,
           fun() -> erx_littlefs:stat(make_ref(), <<"/">>) end,
           fun() -> erx_littlefs:complete(make_ref(), ok) end,
           fun() -> erx_littlefs:payload(make_ref()) end,
           fun() -> erx_littlefs:broken(make_ref()) end],
    [badarg = try F() catch error:badarg -> badarg end || F <- Bad],
    %% An unmounted volume refuses every operation.
    Vol = erx_littlefs:new(self(), 16, 100),
    {error, enodev} = erx_littlefs:stat(Vol, <<"/">>),
    false = erx_littlefs:broken(Vol),
    {error, enodev} = erx_littlefs:read(Vol, 99, 0, 1),
    ok.

%% A grant's root identity is fixed for its life, so a root the owner cannot answer
%% fails the grant's start instead of fixing a made-up one: a root directory the volume
%% lacks answers enoent, and every root of an owner that has ended answers eio
%% (erx_lfs:root/1); erx_fs_tests checks that a root's error fails the start.
a_grant_without_its_root_is_not_started() ->
    Volume = {_, Owner, Data} = start_volume(fresh_disk(), lfs_roots),
    {ok, <<"data">>, Top, _} = erx_lfs:root(Data),
    {ok, Packages, _} = erx_lfs:walk(Top, <<"packages">>, Data),
    ok = erx_lfs:unlink(Packages, <<"installed">>, directory, Data),
    {ok, Args} = erx_lfs:subtree({lfs_roots, packages}, installed, #{client => 5, principal => <<"clock">>}),
    {ok, Installed} = erx_lfs:init(Args),
    {error, enoent} = erx_lfs:root(Installed),
    Ref = erlang:monitor(process, Owner),
    exit(Owner, kill),
    receive {'DOWN', Ref, process, Owner, _} -> ok end,
    {error, eio} = erx_lfs:root(Data),
    stop_volume(Volume).
