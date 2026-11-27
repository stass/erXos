%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The read-only F2FS volume, erx_f2fs_volume, through its erx_fs callback
%% module erx_f2fs (docs/design-f2fs.md, "One process owns a volume" and
%% "The interface"), over a real erx_blk_window bound to a block device of
%% this module that serves an image from memory: every corpus image that
%% mounts lists through the callbacks as it lists through erx_f2fs_core read
%% straight from the image, names, sizes, modes, links, the first MiB of
%% each file's contents and
%% symlink targets; each callback's refusal; erofs for every mutation; the
%% mount's refusals; and the cache's bound over a whole tree's reads.
%% oracle_images/1 and oracle_compare/1 give the F2FS oracle guest's test
%% (test/host/f2fs_oracle_guest_test.rb) the corpus images, and compare
%% Linux's listing of each with erXos's through erx_f2fs_listing:diff/2.

-module(erx_f2fs_volume_tests).

-export([oracle_images/1, oracle_compare/1]).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(BLOCK, 4096).
-define(SECTOR, 512).
-define(ALLOWANCE, (1 bsl 30)).
%% The chunk a reader folds a file in, and the bytes of each file it folds.
-define(CHUNK, 65536).
-define(FOLD_BYTES, (1 bsl 20)).
-define(TYPE_MASK, 8#170000).

%%% The device and the window

%% A block device for erx_blk_window over Image: it answers {read, Sector,
%% Count} with the image's bytes, einval for more than MaxSectors, as a
%% transport refuses a request longer than it carries, or eio once told to
%% fail, and counts the reads of each block it served.
device(Image, MaxSectors) ->
    spawn_link(fun() -> device_loop(Image, MaxSectors, false, #{}) end).

device_loop(Image, MaxSectors, Failing, Served) ->
    receive
        {'$gen_call', From, {read, _Sector, Count}} when Count > MaxSectors ->
            gen_server:reply(From, {error, einval}),
            device_loop(Image, MaxSectors, Failing, Served);
        {'$gen_call', From, {read, _Sector, _Count}} when Failing ->
            gen_server:reply(From, {error, eio}),
            device_loop(Image, MaxSectors, Failing, Served);
        {'$gen_call', From, {read, Sector, Count}} ->
            gen_server:reply(From, {ok, binary:part(Image, Sector * ?SECTOR, Count * ?SECTOR)}),
            Blocks = lists:seq(Sector * ?SECTOR div ?BLOCK, ((Sector + Count) * ?SECTOR - 1) div ?BLOCK),
            device_loop(Image, MaxSectors, Failing,
                        lists:foldl(fun(B, S) -> S#{B => maps:get(B, S, 0) + 1} end, Served, Blocks));
        {'$gen_call', From, served} ->
            gen_server:reply(From, Served),
            device_loop(Image, MaxSectors, Failing, Served);
        {'$gen_call', From, {failing, Failing1}} ->
            gen_server:reply(From, ok),
            device_loop(Image, MaxSectors, Failing1, Served)
    end.

%% A volume over Image through a window of MaxSectors a request: the
%% volume's start answer and the device.
start(Image, MaxSectors, Allowance) ->
    Device = device(Image, MaxSectors),
    {ok, Window} = erx_blk_window:start_link({data, 0, byte_size(Image) div ?SECTOR}, Device,
                                             MaxSectors),
    {erx_f2fs_volume:start_link(Window, #{allowance => Allowance}), Device}.

start(Image) ->
    {{ok, Volume}, Device} = start(Image, 64, ?ALLOWANCE),
    {Volume, Device}.

image(Partition, Blocks) ->
    << <<(maps:get(A, Blocks, <<0:(?BLOCK * 8)>>))/binary>> || A <- lists:seq(0, Partition - 1) >>.

corpus_images() -> [Image || {_Name, Image} <- corpus()].

%% Each corpus image by its deps.lock id, and the cleared Fuchsia image.
corpus() ->
    [{Id, corpus_image(Pin)} || #{id := Id} = Pin <- erx_f2fs_corpus:pins(os:getenv("ERX_DEPS_LOCK"))]
        ++ [{"f2fs-fuchsia-cleared", erx_f2fs_mount_tests:cleared_fuchsia()}].

corpus_image(Pin) ->
    {ok, Image} = erx_f2fs_corpus:image(Pin, erx_f2fs_corpus:fetched(os:getenv("ERX_F2FS_CORPUS"), Pin)),
    Image.

%% The first corpus image that mounts, with its mount. It reads only the
%% images up to that one: each read hashes a whole image, and the tests
%% that need one tree must stay inside EUnit's five seconds on a slow host.
first_mounted() ->
    Reads = [fun() -> corpus_image(Pin) end || Pin <- erx_f2fs_corpus:pins(os:getenv("ERX_DEPS_LOCK"))]
        ++ [fun erx_f2fs_mount_tests:cleared_fuchsia/0],
    first_mounted(Reads).

first_mounted([Read | Rest]) ->
    Image = Read(),
    case mounted(Image) of
        {ok, Mounted} -> {Image, Mounted};
        _ -> first_mounted(Rest)
    end.

%% The image's mount straight from its bytes, as erx_f2fs_core's reader
%% below reads it.
mounted(Image) ->
    direct(Image, fun(Blocks) -> erx_f2fs_mount:mount(byte_size(Image) div ?BLOCK, ?ALLOWANCE, Blocks) end).

direct(Image, Step) -> direct(Image, Step, #{}).

direct(Image, Step, Blocks) ->
    case Step(Blocks) of
        {need, Addresses} ->
            direct(Image, Step, maps:merge(Blocks, #{A => binary:part(Image, A * ?BLOCK, ?BLOCK) || A <- Addresses}));
        Answer ->
            Answer
    end.

%%% Two readers of erx_f2fs_listing

kind(Mode) ->
    case Mode band ?TYPE_MASK of
        8#040000 -> directory;
        8#100000 -> regular;
        8#120000 -> symlink;
        8#020000 -> character;
        8#060000 -> block;
        8#010000 -> fifo;
        8#140000 -> socket
    end.

%% A path's node, each path resolved once, from its parent's: Child(Node,
%% Name) answers {ok, ChildNode} or an error, and Memo, an ETS table,
%% keeps what every path resolved to.
resolved(Memo, Root, Child, Path) ->
    case ets:lookup(Memo, Path) of
        [{Path, Resolved}] ->
            Resolved;
        [] ->
            Resolved = case Path of
                           [] -> {ok, Root};
                           _ -> maybe
                                    {ok, Parent} ?= resolved(Memo, Root, Child, lists:droplast(Path)),
                                    Child(Parent, lists:last(Path))
                                end
                       end,
            ets:insert(Memo, {Path, Resolved}),
            Resolved
    end.

%% The bytes of Size from Offset that a reader's fold covers, chunk by
%% chunk: its first Limit.
chunks(Size, Limit) -> [{At, min(?CHUNK, Limit - At)} || At <- lists:seq(0, min(Size, Limit) - 1, ?CHUNK)].

%% The tree through erx_f2fs's callbacks.
volume_reader(Volume) ->
    {ok, <<"data">>, Root, _Qid} = erx_f2fs:root(Volume),
    Memo = ets:new(volume_paths, [set, private]),
    Child = fun(Node, Name) ->
                    case erx_f2fs:walk(Node, Name, Volume) of
                        {ok, ChildNode, _} -> {ok, ChildNode};
                        Error -> Error
                    end
            end,
    On = fun(Path, Then) ->
                 maybe
                     {ok, Node} ?= resolved(Memo, Root, Child, Path),
                     Then(Node)
                 end
         end,
    #{list => fun(Path) -> On(Path, fun(Node) -> listed(Volume, Node) end) end,
      stat => fun(Path) ->
                      On(Path, fun(Node) ->
                                       case erx_f2fs:getattr(Node, Volume) of
                                           {ok, #{mode := Mode, nlink := Links, size := Size,
                                                  qid := {_, _, QidPath}}} ->
                                               {ok, #{kind => kind(Mode), mode => Mode band 8#7777,
                                                      links => Links, inode => QidPath band 16#ffffffff,
                                                      size => Size}};
                                           Error -> Error
                                       end
                               end)
              end,
      sha256 => fun(Path) ->
                        On(Path, fun(Node) ->
                                         erx_f2fs_listing:sha256_of(fun(Fun, Acc) -> folded(Volume, Node, Fun, Acc) end)
                                 end)
                end,
      read_link => fun(Path) -> On(Path, fun(Node) -> erx_f2fs:readlink(Node, Volume) end) end}.

%% Every name of directory Node, "." and ".." left out, a readdir of at
%% most 7 entries at a time, so listings take several calls; each entry's
%% offset is past the one before it.
listed(Volume, Node) ->
    {ok, Handle} = erx_f2fs:open(Node, 0, Volume),
    listed(Volume, Handle, 0, []).

listed(Volume, Handle, Offset, Names) ->
    case erx_f2fs:readdir(Handle, Offset, 7, Volume) of
        {ok, []} ->
            {ok, [Name || Name <- lists:reverse(Names), Name =/= <<".">>, Name =/= <<"..">>]};
        {ok, Entries} ->
            Offsets = [At || {_, At, _, _} <- Entries],
            ?assert(hd(Offsets) > Offset andalso Offsets =:= lists:usort(Offsets)),
            listed(Volume, Handle, lists:last(Offsets),
                   lists:reverse([Name || {_, _, _, Name} <- Entries], Names));
        Error ->
            Error
    end.

%% Fun folded over the file's first ?FOLD_BYTES, read through the volume
%% until it answers no bytes or the bound.
folded(Volume, Node, Fun, Acc) ->
    maybe
        {ok, Handle} ?= erx_f2fs:open(Node, 0, Volume),
        folded(Volume, Handle, 0, Fun, Acc)
    end.

folded(_Volume, _Handle, Offset, _Fun, Acc) when Offset >= ?FOLD_BYTES ->
    {ok, Acc};
folded(Volume, Handle, Offset, Fun, Acc) ->
    case erx_f2fs:read(Handle, Offset, min(?CHUNK, ?FOLD_BYTES - Offset), Volume) of
        {ok, <<>>} -> {ok, Acc};
        {ok, Bytes} -> folded(Volume, Handle, Offset + byte_size(Bytes), Fun, Fun(Bytes, Acc));
        Error -> Error
    end.

%% The tree through erx_f2fs_core alone, every block read straight from
%% Image: no window, no cache and no volume process. A check of the medium
%% that fails answers eio, as the volume does, an encrypted directory's
%% names among them. Its fold covers a file's first ?FOLD_BYTES, or its
%% first FoldBytes.
core_reader(Image, Volume) -> core_reader(Image, Volume, ?FOLD_BYTES).

core_reader(Image, #{superblock := #{root_ino := Root}} = Volume, FoldBytes) ->
    Run = fun(Step) ->
                  case direct(Image, Step) of
                      {error, _Failure} -> {error, eio};
                      Answer -> Answer
                  end
          end,
    Inode = fun(Nid) -> Run(fun(Blocks) -> erx_f2fs_core:inode(Volume, Nid, Blocks) end) end,
    Memo = ets:new(core_paths, [set, private]),
    Child = fun(Nid, Name) ->
                    {ok, Dir} = Inode(Nid),
                    case Run(fun(B) -> erx_f2fs_core:lookup(Volume, Dir, Name, B) end) of
                        {ok, #{ino := ChildNid}} -> {ok, ChildNid};
                        {ok, none} -> {error, enoent};
                        Error -> Error
                    end
            end,
    On = fun(Path, Then) ->
                 maybe
                     {ok, Nid} ?= resolved(Memo, Root, Child, Path),
                     {ok, Node} ?= Inode(Nid),
                     Then(Nid, Node)
                 end
         end,
    #{list => fun(Path) -> On(Path, fun(_Nid, Dir) -> core_listed(Run, Volume, Dir, 0, []) end) end,
      stat => fun(Path) ->
                      On(Path, fun(Nid, #{i_mode := Mode, i_links := Links, i_size := Size}) ->
                                       {ok, #{kind => kind(Mode), mode => Mode band 8#7777, links => Links,
                                              inode => Nid, size => Size}}
                               end)
              end,
      sha256 => fun(Path) ->
                        On(Path, fun(_Nid, #{i_size := Size} = File) ->
                                         Read = [Run(fun(B) -> erx_f2fs_core:read(Volume, File, At, Count, B) end)
                                                 || {At, Count} <- chunks(Size, FoldBytes)],
                                         erx_f2fs_listing:sha256_of(
                                           fun(Fun, Acc) ->
                                                   {ok, lists:foldl(fun({ok, Bytes}, A) -> Fun(Bytes, A) end, Acc, Read)}
                                           end)
                                 end)
                end,
      read_link => fun(Path) ->
                           On(Path, fun(_Nid, Link) -> Run(fun(B) -> erx_f2fs_core:symlink(Volume, Link, B) end) end)
                   end}.

core_listed(Run, Volume, Dir, Position, Names) ->
    case Run(fun(B) -> erx_f2fs_core:readdir(Volume, Dir, Position, B) end) of
        {ok, {Entries, Next}} ->
            Names1 = Names ++ [Name || #{name := Name} <- Entries, Name =/= <<".">>, Name =/= <<"..">>],
            case Next of
                done -> {ok, Names1};
                _ -> core_listed(Run, Volume, Dir, Next, Names1)
            end;
        Error ->
            Error
    end.

%%% The tree

%% Every corpus image that mounts lists through the volume as through the
%% core read straight from the image; the listings hold every name the
%% core tests count, and the cache stays within its limit though the
%% largest tree's reads cover more blocks than it holds. Each reader
%% resolves a path once, from its parent's, and folds a file's first MiB.
corpus_trees_list_through_the_volume_as_through_the_core_test_() ->
    {timeout, 300,
     fun() ->
             Results = [tree(Image) || Image <- corpus_images()],
             Mounted = [R || R <- Results, R =/= unmounted],
             ?assert(length(Mounted) >= 2),
             ?assert(lists:sum([Names || #{names := Names} <- Mounted]) > 2000),
             ?assert(lists:any(fun(#{read := Read, limit := Limit}) -> Read > Limit end, Mounted)),
             ?assert(lists:all(fun(#{cache := Cache, limit := Limit}) -> Cache =< Limit end, Mounted))
     end}.

tree(Image) ->
    case mounted(Image) of
        {ok, Mounted} ->
            {Volume, Device} = start(Image),
            Expected = erx_f2fs_listing:of_tree(core_reader(Image, Mounted)),
            Got = erx_f2fs_listing:of_tree(volume_reader(Volume)),
            ?assertEqual([], erx_f2fs_listing:diff(Expected, Got)),
            ?assertEqual(length(Expected), length(Got)),
            #{cache := #{blocks := Cached, limit := Limit}} = sys:get_state(Volume),
            Served = gen_server:call(Device, served),
            stop(Volume),
            #{names => length(Got), read => map_size(Served), cache => map_size(Cached), limit => Limit};
        {error, _} ->
            unmounted
    end.

stop(Volume) ->
    unlink(Volume),
    exit(Volume, kill).

%%% Refusals

%% The first corpus image that mounts, its volume and device, and a path of
%% each kind its tree holds.
some_tree() ->
    {Image, Mounted} = first_mounted(),
    Listing = erx_f2fs_listing:of_tree(core_reader(Image, Mounted)),
    Of = fun(Kind) -> hd([Path || {Path, #{kind := K}} <- Listing, K =:= Kind, Path =/= []]) end,
    {Volume, Device} = start(Image),
    {Volume, Device, Mounted, #{file => Of(regular), dir => Of(directory), symlink => Of(symlink)}}.

node(Volume, Path) ->
    {ok, <<"data">>, Root, _} = erx_f2fs:root(Volume),
    lists:foldl(fun(Name, Node) -> {ok, Child, _} = erx_f2fs:walk(Node, Name, Volume), Child end, Root, Path).

each_callback_refuses_what_it_cannot_do_test() ->
    {Volume, _Device, #{superblock := Super, checkpoint := Header}, Paths} = some_tree(),
    {ok, _, Root, {?ERX_P9_QTDIR, 0, _}} = erx_f2fs:root(Volume),
    File = node(Volume, maps:get(file, Paths)),
    Dir = node(Volume, maps:get(dir, Paths)),
    ?assertEqual({error, enoent}, erx_f2fs:walk(Root, <<"no such name here">>, Volume)),
    ?assertEqual({error, enotdir}, erx_f2fs:walk(File, <<"x">>, Volume)),
    [?assertEqual({error, einval}, erx_f2fs:walk(Root, Name, Volume))
     || Name <- [<<>>, <<".">>, <<"..">>, <<"a/b">>, <<"a", 0>>]],
    ?assertEqual({error, enametoolong}, erx_f2fs:walk(Root, binary:copy(<<"n">>, 256), Volume)),
    {ok, FileHandle} = erx_f2fs:open(File, 0, Volume),
    {ok, DirHandle} = erx_f2fs:open(Dir, 0, Volume),
    ?assertEqual({error, enotdir}, erx_f2fs:readdir(FileHandle, 0, 16, Volume)),
    ?assertEqual({error, eisdir}, erx_f2fs:read(DirHandle, 0, 16, Volume)),
    %% A directory opened for writing answers eisdir, before erofs; a
    %% symlink is never opened, as the server follows none.
    ?assertEqual({error, eisdir}, erx_f2fs:open(Dir, ?ERX_P9_O_WRONLY, Volume)),
    ?assertEqual({error, eloop}, erx_f2fs:open(node(Volume, maps:get(symlink, Paths)), 0, Volume)),
    ?assertEqual({error, einval}, erx_f2fs:readlink(File, Volume)),
    %% A nid past the NAT's capacity fails the NAT's check.
    ?assertEqual({error, eio}, erx_f2fs:getattr(1 bsl 31, Volume)),
    %% "." is the directory itself, ".." its parent, at positions 0 and 1.
    {ok, [{DotQid, 1, ?ERX_P9_DT_DIR, <<".">>}, {_, 2, ?ERX_P9_DT_DIR, <<"..">>} | _]} =
        erx_f2fs:readdir(DirHandle, 0, 256, Volume),
    {ok, #{qid := DotQid}} = erx_f2fs:getattr(Dir, Volume),
    {ok, #{type := ?ERX_P9_MAGIC_F2FS, bsize := ?BLOCK, blocks := Blocks, bfree := Free,
           namelen := 255}} = erx_f2fs:statfs(Volume),
    ?assertEqual({maps:get(user_block_count, Header),
                  maps:get(user_block_count, Header) - maps:get(valid_block_count, Header)},
                 {Blocks, Free}),
    ?assert(erx_f2fs_codec:nat_capacity(Super) > 0),
    stop(Volume).

%% A read-only volume answers every mutation erofs, an open for writing or
%% truncation among them; xattr is enotsup; fsync and clunk have nothing
%% to do.
every_mutation_answers_erofs_test() ->
    {Volume, _Device, _Mounted, Paths} = some_tree(),
    {ok, _, Root, _} = erx_f2fs:root(Volume),
    File = node(Volume, maps:get(file, Paths)),
    [?assertEqual({error, erofs}, erx_f2fs:open(File, Flags, Volume))
     || Flags <- [?ERX_P9_O_WRONLY, ?ERX_P9_O_RDWR, ?ERX_P9_O_TRUNC]],
    {ok, Handle} = erx_f2fs:open(File, 0, Volume),
    ?assertEqual([{error, erofs} || _ <- lists:seq(1, 8)],
                 [erx_f2fs:write(Handle, 0, <<"x">>, Volume),
                  erx_f2fs:make(Root, <<"new">>, {file, 8#644, 0}, Volume),
                  erx_f2fs:make(Root, <<"new">>, {directory, 8#755, self()}, Volume),
                  erx_f2fs:make(Root, <<"new">>, {symlink, <<"t">>}, Volume),
                  erx_f2fs:setattr({open, Handle}, #{valid => 0}, Volume),
                  erx_f2fs:setattr({node, File}, #{valid => 0}, Volume),
                  erx_f2fs:unlink(Root, lists:last(maps:get(file, Paths)), file, Volume),
                  erx_f2fs:rename(Root, <<"a">>, Root, <<"b">>, Volume)]),
    ?assertEqual({error, enotsup}, erx_f2fs:xattr(File, list, Volume)),
    ?assertEqual(ok, erx_f2fs:fsync(Handle, Volume)),
    ?assertEqual(ok, erx_f2fs:clunk(Handle, Volume)),
    stop(Volume).

%% A block the window cannot read answers eio and the volume goes on: what
%% the cache holds still reads, and once the device reads again so does
%% the rest.
a_failed_read_answers_eio_test() ->
    {Volume, Device, _Mounted, Paths} = some_tree(),
    {ok, _, Root, _} = erx_f2fs:root(Volume),
    ok = gen_server:call(Device, {failing, true}),
    ?assertEqual({error, eio}, erx_f2fs:walk(Root, hd(maps:get(file, Paths)), Volume)),
    ?assertMatch({ok, _, Root, _}, erx_f2fs:root(Volume)),
    ok = gen_server:call(Device, {failing, false}),
    ?assertMatch({ok, _, _}, erx_f2fs:walk(Root, hd(maps:get(file, Paths)), Volume)),
    stop(Volume).

%%% Requests over the core's fixtures

%% Request through erx_f2fs_request's moves over the fixture {Volume,
%% Blocks}, each step's needs answered from Blocks: the reply, or
%% {failed, Nid, Failure}.
requested({Volume, Blocks}, Request) ->
    moved(erx_f2fs_request:start(Request, Volume), Volume, Blocks).

moved({then, Step}, Volume, Blocks) ->
    moved(given(fun(Given) -> Step(Volume, Given) end, Blocks, #{}), Volume, Blocks);
moved({reply, Reply}, _Volume, _Blocks) ->
    Reply;
moved({failed, _Nid, _Failure} = Failed, _Volume, _Blocks) ->
    Failed.

given(Step, Blocks, Given) ->
    case Step(Given) of
        {need, Addresses} ->
            given(Step, Blocks, maps:merge(Given, #{A => maps:get(A, Blocks, <<0:(?BLOCK * 8)>>) || A <- Addresses}));
        Move ->
            Move
    end.

%% A directory held in nodes lists through the request's core calls, the
%% calls that find nothing read on past: every entry once, each with its
%% inode's qid and the offset past its slot, "." the directory's own
%% though its slot names the root, as ".." does; a maximum cuts the
%% listing where the next request resumes.
a_readdir_reads_on_through_the_core_calls_test() ->
    {Ino, Dir} = erx_f2fs_core_tests:fixture_node_directory(0),
    {Ino, Named} = erx_f2fs_core_tests:fixture_node_directory(Ino),
    {ok, Entries} = requested(Named, {readdir, Ino, 0, 256}),
    ?assertEqual([<<".">>, <<"..">> | [<<"n", D>> || D <- "01234"]], [Name || {_, _, _, Name} <- Entries]),
    {ok, #{qid := Qid}} = requested(Named, {getattr, Ino}),
    {ok, #{qid := RootQid}} = requested(Named, {getattr, ?ERX_F2FS_ROOT_INO}),
    ?assertNotEqual(Qid, RootQid),
    ?assertEqual([{Qid, 1}, {RootQid, 2}, {Qid, 3}], [{Q, At} || {Q, At, _, _} <- lists:sublist(Entries, 3)]),
    ?assertEqual([Qid], lists:usort([Q || {Q, _, _, _} <- lists:nthtail(2, Entries)])),
    ?assertEqual({ok, lists:sublist(Entries, 2)}, requested(Named, {readdir, Ino, 0, 2})),
    ?assertEqual({ok, lists:nthtail(2, Entries)}, requested(Named, {readdir, Ino, 2, 256})),
    %% An entry whose inode fails its check fails the readdir, naming that
    %% inode's nid, not the directory's.
    ?assertMatch({failed, 0, _}, requested(Dir, {readdir, Ino, 0, 256})).

%% A directory's core calls are bounded by its i_blocks: one whose 1,018
%% slots each name an empty dentry block of its own lists, reading on past
%% every call that finds nothing, while its i_blocks counts each slot, and
%% fails once it claims only three blocks.
a_readdir_is_bounded_by_the_blocks_its_directory_holds_test() ->
    {Ino, Honest} = erx_f2fs_core_tests:fixture_repeating_directory(1020),
    ?assertEqual({ok, []}, requested(Honest, {readdir, Ino, 0, 256})),
    {Ino, Claimed} = erx_f2fs_core_tests:fixture_repeating_directory(3),
    ?assertEqual({failed, Ino, {dir, blocks}}, requested(Claimed, {readdir, Ino, 0, 256})).

%%% The mount

%% A chain to replay, tables past the allowance, a medium that cannot be
%% read and a window whose requests cannot carry a block each refuse the
%% mount, and a volume that mounts read-write is still served read-only.
the_mount_refuses_what_it_cannot_serve_test() ->
    {Partition, Chained} = erx_f2fs_mount_tests:chained_volume(),
    ?assertMatch({{error, eintegrity}, _}, start(image(Partition, Chained), 64, ?ALLOWANCE)),
    Fixture = image(Partition, erx_f2fs_mount_tests:fixture_volume()),
    ?assertMatch({{error, enomem}, _}, start(Fixture, 64, 0)),
    ?assertMatch({{error, einval}, _}, start(Fixture, 4, ?ALLOWANCE)),
    Device = device(Fixture, 64),
    ok = gen_server:call(Device, {failing, true}),
    {ok, Window} = erx_blk_window:start_link({data, 0, byte_size(Fixture) div ?SECTOR}, Device, 64),
    ?assertEqual({error, eio}, erx_f2fs_volume:start_link(Window, #{allowance => ?ALLOWANCE})),
    {{ok, Volume}, _} = start(Fixture, 8, ?ALLOWANCE),
    {ok, _, Root, _} = erx_f2fs:root(Volume),
    ?assertEqual({error, erofs}, erx_f2fs:make(Root, <<"new">>, {file, 8#644, 0}, Volume)),
    stop(Volume).

%%% The oracle's trees

%% oracle_images([Directory]) writes each corpus image to Directory as
%% NAME.img, for the F2FS oracle guest to list.
oracle_images([Directory]) ->
    lists:foreach(fun({Name, Image}) -> ok = file:write_file(filename:join(Directory, Name ++ ".img"), Image) end,
                  corpus()).

%% oracle_compare([Directory, HashedBytes]) compares, for each corpus image
%% erx_f2fs_mount mounts, Linux's listing with erXos's listing of the whole
%% tree, each file's first HashedBytes hashed. Linux's listing is read from
%% NAME.linux, the guest's record, which the host writes only for an image
%% Linux mounted and listed. Writes to Directory the names compared
%% (compared.txt), a line per difference or per image Linux did not list or
%% whose record is refused (differences.txt), and a line per difference not
%% compared (uncompared.txt): each beneath, or at, a path other than the root
%% where Linux states a directory and erXos answers an error (an encrypted
%% directory, which erXos does not read). An error at the root, or at a name
%% Linux states as anything but a directory, is a difference.
oracle_compare([Directory, HashedBytes]) ->
    Results = [oracle_compared(Name, core_reader(Image, Mounted, list_to_integer(HashedBytes)),
                               file:read_file(filename:join(Directory, Name ++ ".linux")))
               || {Name, Image} <- corpus(), {ok, Mounted} <- [mounted(Image)]],
    Write = fun(File, Lines) -> ok = file:write_file(filename:join(Directory, File), Lines) end,
    Write("compared.txt", [[Name, $\n] || {Name, _, _} <- Results]),
    Write("differences.txt", [Lines || {_, Lines, _} <- Results]),
    Write("uncompared.txt", [Lines || {_, _, Lines} <- Results]).

oracle_compared(Name, ErxosReader, {ok, Record}) ->
    case erx_f2fs_listing:record_reader(Record) of
        {ok, LinuxReader} ->
            Erxos = erx_f2fs_listing:of_tree(ErxosReader),
            Linux = erx_f2fs_listing:of_tree(LinuxReader),
            Directories = #{Path => true || {Path, #{kind := directory}} <- Linux},
            Refused = [Path || {Path, {error, _}} <- Erxos, Path =/= [], is_map_key(Path, Directories)],
            Beneath = fun({Path, _, _}) -> lists:any(fun(Root) -> lists:prefix(Root, Path) end, Refused) end,
            {Uncompared, Differences} = lists:partition(Beneath, erx_f2fs_listing:diff(Linux, Erxos)),
            {Name, [oracle_line(Name, Entry) || Entry <- Differences],
             [oracle_line(Name, Entry) || Entry <- Uncompared]};
        {error, Reason} ->
            {Name, [io_lib:format("~s: Linux's record is refused: ~0p~n", [Name, Reason])], []}
    end;
oracle_compared(Name, _ErxosReader, {error, enoent}) ->
    {Name, [io_lib:format("~s: Linux did not list it~n", [Name])], []}.

oracle_line(Name, {Path, Linux, Erxos}) ->
    io_lib:format("~s: ~0p: Linux ~0p, erXos ~0p~n", [Name, Path, Linux, Erxos]).
