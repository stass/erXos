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
    {ok, Entries} = requested(Named, {readdir, {Ino, read}, 0, 256}),
    ?assertEqual([<<".">>, <<"..">> | [<<"n", D>> || D <- "01234"]], [Name || {_, _, _, Name} <- Entries]),
    {ok, #{qid := Qid}} = requested(Named, {getattr, Ino}),
    {ok, #{qid := RootQid}} = requested(Named, {getattr, ?ERX_F2FS_ROOT_INO}),
    ?assertNotEqual(Qid, RootQid),
    ?assertEqual([{Qid, 1}, {RootQid, 2}, {Qid, 3}], [{Q, At} || {Q, At, _, _} <- lists:sublist(Entries, 3)]),
    ?assertEqual([Qid], lists:usort([Q || {Q, _, _, _} <- lists:nthtail(2, Entries)])),
    ?assertEqual({ok, lists:sublist(Entries, 2)}, requested(Named, {readdir, {Ino, read}, 0, 2})),
    ?assertEqual({ok, lists:nthtail(2, Entries)}, requested(Named, {readdir, {Ino, read}, 2, 256})),
    %% An entry whose inode fails its check fails the readdir, naming that
    %% inode's nid, not the directory's.
    ?assertMatch({failed, 0, _}, requested(Dir, {readdir, {Ino, read}, 0, 256})).

%% A directory's core calls are bounded by its i_blocks: one whose 1,018
%% slots each name an empty dentry block of its own lists, reading on past
%% every call that finds nothing, while its i_blocks counts each slot, and
%% fails once it claims only three blocks.
a_readdir_is_bounded_by_the_blocks_its_directory_holds_test() ->
    {Ino, Honest} = erx_f2fs_core_tests:fixture_repeating_directory(1020),
    ?assertEqual({ok, []}, requested(Honest, {readdir, {Ino, read}, 0, 256})),
    {Ino, Claimed} = erx_f2fs_core_tests:fixture_repeating_directory(3),
    ?assertEqual({failed, Ino, {dir, blocks}}, requested(Claimed, {readdir, {Ino, read}, 0, 256})).

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

%%% Read-write volumes

%% A medium is {Partition, Blocks}: its size in blocks and its blocks by
%% address, zeros where Blocks has none, so a crash state shares every
%% block it does not change.
medium(Image) ->
    Zero = <<0:(?BLOCK * 8)>>,
    {byte_size(Image) div ?BLOCK,
     maps:from_list([{A, B} || A <- lists:seq(0, byte_size(Image) div ?BLOCK - 1),
                               B <- [binary:part(Image, A * ?BLOCK, ?BLOCK)], B =/= Zero])}.

block({_Partition, Blocks}, A) -> maps:get(A, Blocks, <<0:(?BLOCK * 8)>>).

%% Medium with Writes, {Block, Bytes} each, landed in order.
landed({Partition, Blocks}, Writes) -> {Partition, maps:merge(Blocks, maps:from_list(Writes))}.

%% A block device over Medium that also writes and flushes, recording every
%% write and flush in the order it served them, for the crash states; once
%% told to fail writes or flushes, it answers each eio and records nothing.
recorder(Medium) -> spawn_link(fun() -> recorder_loop(Medium, [], none) end).

recorder_loop(Medium, Journal, Failing) ->
    receive
        {'$gen_call', From, {read, Sector, Count}} ->
            First = Sector * ?SECTOR div ?BLOCK,
            gen_server:reply(From, {ok, << <<(block(Medium, A))/binary>>
                                           || A <- lists:seq(First, First + Count * ?SECTOR div ?BLOCK - 1) >>}),
            recorder_loop(Medium, Journal, Failing);
        {'$gen_call', From, {write, _Sector, _Bytes}} when Failing =:= write ->
            gen_server:reply(From, {error, eio}),
            recorder_loop(Medium, Journal, Failing);
        {'$gen_call', From, {write, Sector, Bytes}} ->
            gen_server:reply(From, ok),
            Blocks = [{Sector * ?SECTOR div ?BLOCK + I, binary:part(Bytes, I * ?BLOCK, ?BLOCK)}
                      || I <- lists:seq(0, byte_size(Bytes) div ?BLOCK - 1)],
            recorder_loop(landed(Medium, Blocks), [{write, Blocks} | Journal], Failing);
        {'$gen_call', From, flush} when Failing =:= flush ->
            gen_server:reply(From, {error, eio}),
            recorder_loop(Medium, Journal, Failing);
        {'$gen_call', From, flush} ->
            gen_server:reply(From, ok),
            recorder_loop(Medium, [flush | Journal], Failing);
        {'$gen_call', From, {failing, Failing1}} ->
            gen_server:reply(From, ok),
            recorder_loop(Medium, Journal, Failing1);
        {'$gen_call', From, journal} ->
            gen_server:reply(From, {Medium, lists:reverse(Journal)}),
            recorder_loop(Medium, Journal, Failing)
    end.

%% A volume over Medium in Mode, and its device.
start_on({Partition, _} = Medium, Mode) ->
    Device = recorder(Medium),
    {ok, Window} = erx_blk_window:start_link({data, 0, Partition * ?BLOCK div ?SECTOR}, Device, 64),
    {ok, Volume} = erx_f2fs_volume:start_link(Window, #{allowance => ?ALLOWANCE, mode => Mode}),
    {Volume, Device}.

%% Medium's checkpoint version, as a mount reads it.
version({Partition, _} = Medium) -> version(Medium, erx_f2fs_mount:mount(Partition, ?ALLOWANCE, #{}), #{}).

version(_Medium, {ok, #{checkpoint := #{checkpoint_ver := Version}}}, _Given) -> Version;
version({Partition, _} = Medium, {need, Addresses}, Given) ->
    Given1 = maps:merge(Given, maps:from_list([{A, block(Medium, A)} || A <- Addresses])),
    version(Medium, erx_f2fs_mount:mount(Partition, ?ALLOWANCE, Given1), Given1).

%% A file's bytes through a volume's handle, read to its end.
contents(Volume, Handle) -> contents(Volume, Handle, 0, <<>>).

contents(Volume, Handle, At, Acc) ->
    case erx_f2fs:read(Handle, At, 65536, Volume) of
        {ok, <<>>} -> Acc;
        {ok, Bytes} -> contents(Volume, Handle, At + byte_size(Bytes), <<Acc/binary, Bytes/binary>>)
    end.

%% A file's bytes on Medium, through a read-only volume.
file_on(Medium, Path) ->
    {Volume, _Device} = start_on(Medium, read_only),
    {ok, Handle} = erx_f2fs:open(node(Volume, Path), 0, Volume),
    Bytes = contents(Volume, Handle),
    stop(Volume),
    Bytes.

%% The first corpus image that mounts read-write with a regular file of
%% more than two blocks whose size Wanted accepts: the image as a medium,
%% the file's path, the image's mount and the file's inode nid and size.
writable_file(Wanted) -> writable_file(Wanted, corpus_images()).

writable_file(Wanted, [Image | Images]) ->
    Files = case mounted(Image) of
                {ok, #{mode := read_write} = Mounted} ->
                    #{stat := Stat} = Reader = core_reader(Image, Mounted),
                    [{Path, Mounted, Nid, Size}
                     || {Path, #{kind := regular, size := Size}} <- erx_f2fs_listing:of_tree(Reader),
                        Size > 2 * ?BLOCK, Wanted(Size), {ok, #{inode := Nid}} <- [Stat(Path)]];
                _ -> []
            end,
    case Files of
        [{Path, Found, Nid, Size} | _] -> {medium(Image), Path, Found, {Nid, Size}};
        [] -> writable_file(Wanted, Images)
    end.

any_size(_Size) -> true.

%% Old with Bytes written at At, zeros filling any gap past its end.
overwritten(Old, At, Bytes) ->
    Padded = <<Old/binary, 0:(max(0, At - byte_size(Old)) * 8)>>,
    End = At + byte_size(Bytes),
    <<(binary:part(Padded, 0, At))/binary, Bytes/binary,
      (binary:part(Padded, min(End, byte_size(Padded)), max(0, byte_size(Padded) - End)))/binary>>.

%% A read-write volume writes its mount checkpoint, reads a write back
%% before and after the fsync that commits it, and its unmount checkpoint
%% leaves a medium whose file holds the write. Every crash state of what
%% it wrote mounts at one of its checkpoints, with the file's old bytes
%% before the fsync's and its new bytes from it on: each phase between two
%% flushes over the medium as the flushes before left it, sampled as none
%% of its blocks, all, all but each one, each torn in half and random
%% subsets.
a_write_survives_fsync_unmount_and_every_cut_test_() ->
    {timeout, 900,
     fun() ->
             {Medium, Path, _Mounted, _File} = writable_file(fun any_size/1),
             V0 = version(Medium),
             Old = file_on(Medium, Path),
             {Volume, Device} = start_on(Medium, read_write),
             {ok, Handle} = erx_f2fs:open(node(Volume, Path), ?ERX_P9_O_RDWR, Volume),
             Patch = binary:copy(<<16#c3>>, ?BLOCK + 1000),
             At = ?BLOCK - 500,
             ?assertEqual({ok, byte_size(Patch), At}, erx_f2fs:write(Handle, At, Patch, Volume)),
             New = overwritten(Old, At, Patch),
             ?assertEqual(New, contents(Volume, Handle)),
             ?assertEqual(ok, erx_f2fs:fsync(Handle, Volume)),
             ?assertEqual(New, contents(Volume, Handle)),
             ?assertEqual(ok, erx_f2fs_volume:unmount(Volume)),
             {After, Journal} = gen_server:call(Device, journal),
             ?assertEqual(V0 + 2, version(After)),
             ?assertEqual(New, file_on(After, Path)),
             cuts(Medium, Journal, fun(Crashed) ->
                                           V = version(Crashed),
                                           ?assert(V >= V0 andalso V =< V0 + 2),
                                           Expected = case V >= V0 + 2 of
                                                          true -> New;
                                                          false -> Old
                                                      end,
                                           ?assertEqual({V, Expected}, {V, file_on(Crashed, Path)})
                                   end)
     end}.

%% Check over every crash state of Journal's writes on Medium.
cuts(Medium, Journal, Check) ->
    rand:seed(exsss, {16#f2f5, 10, length(Journal)}),
    lists:foldl(fun(Phase, Prefix) ->
                        Writes = lists:append([Blocks || {write, Blocks} <- Phase]),
                        [Check(landed(Prefix, Landed)) || Landed <- landings(Writes, Prefix)],
                        landed(Prefix, Writes)
                end, Medium, phases(Journal)),
    ok.

%% The journal's writes between flushes, a list for each.
phases(Journal) ->
    {Last, Done} = lists:foldl(fun(flush, {Current, Acc}) -> {[], [lists:reverse(Current) | Acc]};
                                  (Write, {Current, Acc}) -> {[Write | Current], Acc}
                               end, {[], []}, Journal),
    lists:reverse([lists:reverse(Last) | Done]).

landings(Writes, Medium) ->
    Torn = fun({A, Bytes}) -> {A, <<(binary:part(Bytes, 0, ?BLOCK div 2))/binary,
                                    (binary:part(block(Medium, A), ?BLOCK div 2, ?BLOCK div 2))/binary>>}
           end,
    [[], Writes] ++ [Writes -- [W] || W <- Writes] ++ [[Torn(W) | Writes -- [W]] || W <- Writes] ++
        [[W || W <- Writes, rand:uniform(2) =:= 1] || _ <- lists:seq(1, 4)].

%%% What a write refuses, cuts and ends

%% Fixture as a read-write view, whose requests take the write path.
writable({Volume, Blocks}) -> {Volume#{dirty => #{}}, Blocks}.

%% A handle answers only the access it was opened for: a write through one
%% opened to read, appending or not, and a read through one opened only to
%% write answer ebadf. An open for writing or truncation needs the owner's
%% permission bits for its access, as erx_ramfs_core's opens do, whoever
%% opens it.
a_handle_answers_its_access_and_a_write_open_needs_the_owners_bits_test() ->
    {Ino, ReadOnly} = erx_f2fs_core_tests:fixture_file_mode(8#100444),
    {ok, Reader} = requested(writable(ReadOnly), {open, Ino, 0}),
    {ok, Appender} = requested(writable(ReadOnly), {open, Ino, ?ERX_P9_O_APPEND}),
    [?assertEqual({error, ebadf}, requested(writable(ReadOnly), {write, {Handle, 0, <<"x">>}}))
     || Handle <- [Reader, Appender]],
    [?assertEqual({error, eacces}, requested(writable(ReadOnly), {open, Ino, Flags}))
     || Flags <- [?ERX_P9_O_WRONLY, ?ERX_P9_O_RDWR, ?ERX_P9_O_TRUNC]],
    ?assertEqual({error, einval}, requested(writable(ReadOnly), {open, Ino, ?ERX_P9_O_ACCMODE})),
    {Ino, WriteOnly} = erx_f2fs_core_tests:fixture_file_mode(8#100200),
    {ok, Writer} = requested(writable(WriteOnly), {open, Ino, ?ERX_P9_O_WRONLY}),
    ?assertEqual({error, ebadf}, requested(writable(WriteOnly), {read, Writer, 0, 1})),
    ?assertEqual({error, eacces}, requested(writable(WriteOnly), {open, Ino, ?ERX_P9_O_RDWR})),
    {Ino, Owned} = erx_f2fs_core_tests:fixture_file_mode(8#100600),
    {ok, Both} = requested(writable(Owned), {open, Ino, ?ERX_P9_O_RDWR}),
    ?assertMatch({ok, <<_>>}, requested(writable(Owned), {read, Both, 0, 1})).

%% An open to read needs the owner's read bit, as erx_ramfs_core's does, on
%% a read-only volume and a read-write one alike.
an_open_to_read_needs_the_owners_read_bit_test() ->
    {Ino, WriteOnly} = erx_f2fs_core_tests:fixture_file_mode(8#100200),
    [?assertEqual({error, eacces}, requested(View, {open, Ino, Flags}))
     || View <- [WriteOnly, writable(WriteOnly)], Flags <- [0, ?ERX_P9_O_APPEND]],
    {Ino, Readable} = erx_f2fs_core_tests:fixture_file_mode(8#100400),
    ?assertEqual({ok, {Ino, read}}, requested(Readable, {open, Ino, 0})).

%% statfs counts the space the volume offers on a read-write mount, so its
%% free blocks run out when writes answer enospc, and none are free once
%% the volume is past it; a read-only mount counts the checkpoint's user
%% blocks.
statfs_counts_the_space_a_read_write_volume_offers_test() ->
    {_Ino, {Volume, Blocks}} = erx_f2fs_core_tests:fixture_file_mode(8#100644),
    #{superblock := Super, checkpoint := Header} = Volume,
    Offered = (40 - 16) * 512,
    Counted = fun(Valid) ->
                      {Volume#{superblock := Super#{section_count := 40, segs_per_sec := 1},
                               checkpoint := Header#{user_block_count := Offered + 512,
                                                     valid_block_count := Valid}}, Blocks}
              end,
    ?assertEqual(Offered, erx_f2fs_mount:offered(element(1, Counted(0)))),
    Space = fun(View) ->
                    {ok, #{blocks := Total, bfree := Free, bavail := Avail}} = requested(View, statfs),
                    {Total, Free, Avail}
            end,
    ?assertEqual({Offered, Offered - 1000, Offered - 1000}, Space(writable(Counted(1000)))),
    ?assertEqual({Offered, 0, 0}, Space(writable(Counted(Offered + 100)))),
    ?assertEqual({Offered + 512, Offered - 488, Offered - 488}, Space(Counted(1000))),
    ?assertEqual({Offered + 512, 412, 412}, Space(Counted(Offered + 100))).

%% Three writes, each committed by an fsync, read back through the volume
%% after each, and a medium after unmount whose file holds all three: each
%% checkpoint reads the tables and nodes the one before it wrote, which the
%% cache must hold as written.
writes_read_back_across_checkpoints_test_() ->
    {timeout, 300,
     fun() ->
             {Medium, Path, _Mounted, _File} = writable_file(fun any_size/1),
             Old = file_on(Medium, Path),
             {Volume, Device} = start_on(Medium, read_write),
             {ok, Handle} = erx_f2fs:open(node(Volume, Path), ?ERX_P9_O_RDWR, Volume),
             New = lists:foldl(fun(Round, Was) ->
                                       Patch = binary:copy(<<Round>>, 100),
                                       At = Round * 1000,
                                       {ok, 100, At} = erx_f2fs:write(Handle, At, Patch, Volume),
                                       ok = erx_f2fs:fsync(Handle, Volume),
                                       Now = overwritten(Was, At, Patch),
                                       ?assertEqual(Now, contents(Volume, Handle)),
                                       Now
                               end, Old, [1, 2, 3]),
             ?assertEqual(ok, erx_f2fs_volume:unmount(Volume)),
             {After, _Journal} = gen_server:call(Device, journal),
             ?assertEqual(New, file_on(After, Path))
     end}.

%% A write needs a node to hold each block's slot, and blocks of the file's
%% own: one reaching a block no node holds, from it or from the block
%% before, and one into inline data answer enotsup.
a_write_refuses_a_slot_no_node_holds_and_inline_data_test() ->
    {Ino, Block, File} = erx_f2fs_core_tests:fixture_unmapped_file(),
    ?assertEqual({error, enotsup}, requested(writable(File), {write, {{Ino, read_write}, Block * ?BLOCK, <<"x">>}})),
    ?assertEqual({error, enotsup}, requested(writable(File), {write, {{Ino, read_write}, Block * ?BLOCK - 1, <<"xy">>}})),
    {InlineIno, Inline} = erx_f2fs_core_tests:fixture_inline_file(),
    ?assertEqual({error, enotsup}, requested(writable(Inline), {write, {{InlineIno, read_write}, 0, <<"x">>}})).

%% A read-write volume opens no file to append or truncate, and refuses a
%% write that starts past the block holding the size, which would leave
%% blocks between that no write cleared.
a_read_write_volume_refuses_appends_truncation_and_gaps_test() ->
    {Medium, Path, _Mounted, {_Nid, Size}} = writable_file(fun any_size/1),
    {Volume, _Device} = start_on(Medium, read_write),
    File = node(Volume, Path),
    [?assertEqual({error, enotsup}, erx_f2fs:open(File, Flags, Volume))
     || Flags <- [?ERX_P9_O_RDWR bor ?ERX_P9_O_APPEND, ?ERX_P9_O_WRONLY bor ?ERX_P9_O_APPEND,
                  ?ERX_P9_O_RDWR bor ?ERX_P9_O_TRUNC, ?ERX_P9_O_TRUNC]],
    {ok, Handle} = erx_f2fs:open(File, ?ERX_P9_O_RDWR, Volume),
    ?assertEqual({error, enotsup}, erx_f2fs:write(Handle, (Size div ?BLOCK + 1) * ?BLOCK, <<"x">>, Volume)),
    stop(Volume).

%% The bytes of the size's block past the size read as zeros, whatever the
%% medium holds there, so a write past the size within that block shows
%% nothing of what the block held beyond its file; and a write takes at
%% most 64 blocks from its first, answering the bytes it took.
a_write_reads_zeros_past_the_size_and_is_cut_at_64_blocks_test_() ->
    {timeout, 300,
     fun() ->
             {{Partition, Blocks} = Clean, Path, Mounted, {Nid, Size}} =
                 writable_file(fun(S) -> S rem ?BLOCK > 0 andalso S rem ?BLOCK < ?BLOCK - 200 end),
             Image = image(Partition, Blocks),
             {ok, Inode} = direct(Image, fun(B) -> erx_f2fs_core:inode(Mounted, Nid, B) end),
             {ok, {_, _, Tail}} = direct(Image, fun(B) -> erx_f2fs_core:slot(Mounted, Inode, Size div ?BLOCK, B) end),
             Kept = Size rem ?BLOCK,
             Medium = landed(Clean, [{Tail, <<(binary:part(block(Clean, Tail), 0, Kept))/binary,
                                              (binary:copy(<<16#5a>>, ?BLOCK - Kept))/binary>>}]),
             Old = file_on(Medium, Path),
             {Volume, _Device} = start_on(Medium, read_write),
             {ok, Handle} = erx_f2fs:open(node(Volume, Path), ?ERX_P9_O_RDWR, Volume),
             ?assertEqual({ok, 4, Size + 100}, erx_f2fs:write(Handle, Size + 100, <<"tail">>, Volume)),
             Tailed = overwritten(Old, Size + 100, <<"tail">>),
             ?assertEqual(Tailed, contents(Volume, Handle)),
             Long = binary:copy(<<16#e7>>, 65 * ?BLOCK),
             ?assertEqual({ok, 64 * ?BLOCK - 100, 100}, erx_f2fs:write(Handle, 100, Long, Volume)),
             ?assertEqual(overwritten(Tailed, 100, binary:part(Long, 0, 64 * ?BLOCK - 100)),
                          contents(Volume, Handle)),
             stop(Volume)
     end}.

%% A write the medium refuses, or a flush it fails, ends the volume with
%% eio, and every later request answers eio.
a_failed_write_or_flush_ends_the_volume_with_eio_test_() ->
    {timeout, 300,
     fun() ->
             {Medium, Path, _Mounted, _File} = writable_file(fun any_size/1),
             Write = fun(Handle, Volume) -> erx_f2fs:write(Handle, 0, <<"x">>, Volume) end,
             Fsync = fun(Handle, Volume) ->
                             {ok, 1, 0} = Write(Handle, Volume),
                             erx_f2fs:fsync(Handle, Volume)
                     end,
             [begin
                  {Volume, Device} = start_on(Medium, read_write),
                  unlink(Volume),
                  Down = monitor(process, Volume),
                  {ok, Handle} = erx_f2fs:open(node(Volume, Path), ?ERX_P9_O_RDWR, Volume),
                  ok = gen_server:call(Device, {failing, Failing}),
                  ?assertEqual({Failing, {error, eio}}, {Failing, Request(Handle, Volume)}),
                  ?assertEqual({Failing, eio}, receive {'DOWN', Down, process, Volume, Why} -> {Failing, Why}
                                               after 5000 -> {Failing, running}
                                               end),
                  ?assertEqual({error, eio}, erx_f2fs:read(Handle, 0, 1, Volume))
              end || {Failing, Request} <- [{write, Write}, {flush, Fsync}]],
             ok
     end}.
