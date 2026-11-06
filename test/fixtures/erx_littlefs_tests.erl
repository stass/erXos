%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The littlefs NIF and erx_lfs on the host over a RAM window
%% (test/host/erx_littlefs_test.rb). The runtime runs with one dirty I/O
%% scheduler, so every case also shows that a block callback completes
%% through the owner on normal schedulers. Each case prints "ok Name";
%% main/0 halts 0 only when all pass.
-module(erx_littlefs_tests).

-export([main/0, window/2]).
-export([synced_file_survives_a_cut/0, tree_operations/0, block_error_fails_the_volume/0,
         deadline_ends_a_request/0, refuses_bad_arguments/0]).

-include("generated/erx_abi.hrl").

-define(SECTOR, 512).
-define(DISK_SECTORS, 2048).

main() ->
    ok = erx_fs_version:init(),
    Cases = [synced_file_survives_a_cut, tree_operations, block_error_fails_the_volume,
             deadline_ends_a_request, refuses_bad_arguments],
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
%% A RAM window: answers gen_server calls as erx_blk_window does
%% ---------------------------------------------------------------------------

start_window(Disk) ->
    proc_lib:spawn(?MODULE, window, [Disk, normal]).

-doc false.
window(Disk, Mode) ->
    receive
        {'$gen_call', From, Request} ->
            {Reply, Disk1} = serve(Request, Disk, Mode),
            case Mode of
                silent -> ok;
                _ -> gen_server:reply(From, Reply)
            end,
            window(Disk1, Mode);
        {mode, Mode1} ->
            window(Disk, Mode1);
        {snapshot, Pid} ->
            Pid ! {snapshot, Disk},
            window(Disk, Mode)
    end.

serve(info, Disk, _) ->
    {{ok, #{role => data, sectors => byte_size(Disk) div ?SECTOR}}, Disk};
serve(_, Disk, fail) ->
    {{error, eio}, Disk};
serve({read, Sector, Count}, Disk, _) ->
    {{ok, binary:part(Disk, Sector * ?SECTOR, Count * ?SECTOR)}, Disk};
serve({write, Sector, Bytes}, Disk, _) ->
    At = Sector * ?SECTOR,
    <<Before:At/binary, _:(byte_size(Bytes))/binary, After/binary>> = Disk,
    {ok, <<Before/binary, Bytes/binary, After/binary>>}.

snapshot(Window) ->
    Window ! {snapshot, self()},
    receive {snapshot, Disk} -> Disk after 5000 -> error(no_snapshot) end.

start_volume(Disk, Name) ->
    Window = start_window(Disk),
    {ok, Owner} = erx_lfs:start_link({window, Window}, Name),
    unlink(Owner),
    {ok, Fs} = erx_lfs:init(Name),
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
    Volume = {Window, _, Fs} = start_volume(<<0:(?DISK_SECTORS * ?SECTOR)/unit:8>>, lfs_cut1),
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

%% Directories, listings, renames, removals and their refusals.
tree_operations() ->
    Volume = {_, _, Fs} = start_volume(<<0:(?DISK_SECTORS * ?SECTOR)/unit:8>>, lfs_tree),
    {ok, _, Root, {?ERX_P9_QTDIR, _, _}} = erx_lfs:root(Fs),
    {ok, Dir, {?ERX_P9_QTDIR, _, DirId}} = erx_lfs:make(Root, <<"d">>, {directory, 8#755}, Fs),
    {ok, File, {0, _, FileId}, H} = erx_lfs:make(Dir, <<"f">>, {file, 8#644, ?ERX_P9_O_WRONLY}, Fs),
    {ok, 3, 0} = erx_lfs:write(H, 0, <<"abc">>, Fs),
    %% A write-only file refuses a read, which littlefs would assert on.
    {error, ebadf} = erx_lfs:read(H, 0, 3, Fs),
    ok = erx_lfs:clunk(H, Fs),
    {error, eexist} = erx_lfs:make(Dir, <<"f">>, {file, 8#644, ?ERX_P9_O_WRONLY}, Fs),
    {error, eperm} = erx_lfs:make(Dir, <<"l">>, {symlink, <<"f">>}, Fs),
    {error, einval} = erx_lfs:walk(Dir, <<"a/b">>, Fs),
    {ok, Root, _} = erx_lfs:walk(Dir, <<"..">>, Fs),
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
    {ok, _, _} = erx_lfs:make(Root, <<"\xff">>, {directory, 8#755}, Fs),
    ok = erx_lfs:rename(Root, <<"\xff">>, Root, <<"\xfe">>, Fs),
    ok = erx_lfs:unlink(Root, <<"\xfe">>, directory, Fs),
    {ok, #{bsize := 4096, blocks := 256}} = erx_lfs:statfs(Fs),
    true = DirId =/= FileId,
    stop_volume(Volume).

%% A block request the window refuses fails its operation, and the volume
%% answers eio from then on, even once the window answers again.
block_error_fails_the_volume() ->
    Volume = {Window, _, Fs} = start_volume(<<0:(?DISK_SECTORS * ?SECTOR)/unit:8>>, lfs_fail),
    {ok, _, Root, _} = erx_lfs:root(Fs),
    Window ! {mode, fail},
    {error, eio} = erx_lfs:make(Root, <<"x">>, {directory, 8#755}, Fs),
    Window ! {mode, normal},
    {error, eio} = erx_lfs:make(Root, <<"y">>, {directory, 8#755}, Fs),
    {error, eio} = erx_lfs:walk(Root, <<"x">>, Fs),
    stop_volume(Volume).

%% A block request nobody answers ends at its deadline as eio; the owner's
%% answer after it is late and changes nothing, and the volume stays failed.
deadline_ends_a_request() ->
    Vol = erx_littlefs:new(self(), 16, 200),
    Self = self(),
    _ = spawn(fun() -> Self ! {result, erx_littlefs:mount(Vol)} end),
    {Req, Count} = receive {erx_lfs_block, read, _, C, R} -> {R, C} after 5000 -> error(no_request) end,
    {error, eio} = receive {result, Result} -> Result after 5000 -> error(no_deadline) end,
    late = erx_littlefs:complete(Req, {ok, <<0:(Count * 512)/unit:8>>}),
    {error, eio} = erx_littlefs:mount(Vol),
    ok.

%% Arguments outside the NIF's limits are badarg, never a crash.
refuses_bad_arguments() ->
    Bad = [fun() -> erx_littlefs:new(self(), 4, 100) end,
           fun() -> erx_littlefs:new(self(), 16, 0) end,
           fun() -> erx_littlefs:stat(make_ref(), <<"/">>) end,
           fun() -> erx_littlefs:complete(make_ref(), ok) end,
           fun() -> erx_littlefs:payload(make_ref()) end],
    [badarg = try F() catch error:badarg -> badarg end || F <- Bad],
    %% An unmounted volume refuses every operation.
    Vol = erx_littlefs:new(self(), 16, 100),
    {error, enodev} = erx_littlefs:stat(Vol, <<"/">>),
    {error, enodev} = erx_littlefs:read(Vol, 99, 0, 1),
    ok.
