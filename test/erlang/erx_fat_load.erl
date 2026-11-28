%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fat_load).
-moduledoc """
A sustained, seeded load of the FAT server's write path (docs/design-storage.md,
"Removable media: FAT"; docs/design-drives.md, "Volumes"), driven by
test/host/erx_fat_load_test.rb. A volume process (erx_media_volume) runs over a
window proxy that reads and writes an image file on the host, and takes these of
the calls the media tree sends it for a session's file operations: create/3,
mkdir, write, truncate, remove, rename, fsync, walk, list, finish and the waiting
read. create/4's open and truncate, append, setattr, rmdir and a holder's end are
not driven; the volume's own tests cover them.

The jobs follow fio's shapes, sized from the volume:

* `seq`: one file written in 64 KiB pieces, a sixteenth of the volume (file_cap/1)
  up to 256 MiB,
  then read back;
* `rand-fsyncN`: 4 KiB reads and writes at aligned random offsets of a file of an
  thirty-second of the volume up to 64 MiB, half each, with `fsync` after every N writes,
  N 0 (never), 1 and 16 (docs/design-bench.md's `rand-io`);
* `mixed`: reads and writes of 1 byte to 64 KiB at any offset of that file, past
  its end among them;
* `interleave`: four files appended to in turn, in pieces of 1 byte to 32 KiB;
* `truncate`: those files shrunk, extended and written across their ends;
* `files`: small files in a two-level tree of directories, created until the
  volume answers `enospc`, half removed or renamed (some onto a file that exists),
  and the volume filled again, which must take back what the removals freed;
* `remount`: the volume finished, mounted again, which runs the ownership check,
  and every directory's listing and every file's bytes checked.

The expected contents are a model, each file its size and its 4 KiB chunks, every
byte drawn from a pool of seeded random bytes, so a run's calls are reproduced by
its seed; when the volume commits between them also follows its 5 s timer, and so
the host's speed. File sizes are capped by file_cap/1, a sixteenth of the volume.
Every read is compared with the model as it answers, and each job's files are read
whole when it ends. The first difference, or any answer that is not the expected
one, ends the run with `FAILED seed=S op=N job=J: What`, N the count of the
volume's calls so far, and status 1. A run that passes writes the model as a
manifest, one line per file (`f SIZE MD5 PATH`) and per directory (`d PATH`), for
the host test to compare with fsimg's extract, and prints one `RESULT` line per job
and kind of call: its calls, bytes and microseconds spent in the volume's calls.
""".

-export([main/1]).

-include("erx_fs_waits.hrl").

-define(SECTOR, 512).
%% The model's unit of contents.
-define(CHUNK, 4096).
%% The largest write and read request, as a 9P message of 64 KiB would carry.
-define(PIECE, 65536).
%% The pool of random bytes that every write takes a slice of.
-define(POOL, 1048576).
%% The longest run of sectors the proxy reads in one request.
-define(RUN, 64).
%% Interleaved files.
-define(INTERLEAVED, 4).
%% The tree of the small files: MIDS directories, each with LEAVES.
-define(MIDS, 8).
%% No file is larger than a sixteenth of the volume (file_cap/1): thousands of
%% clusters on every volume, so a file's chain is long, and room for the jobs' files
%% beside each other.
-define(FILE_SHARE, 16).
-define(LEAVES, 8).
%% The least room the ballast leaves for the small files.
-define(ROOM_MIN, 4194304).

-doc """
Runs the load on the FAT32 image at Image, writes the manifest to Manifest, and
halts: 0 when every check passed, 1 at the first that did not. Seed and Ops (the
count of each random job's calls) are decimal strings.
""".
-spec main([string()]) -> no_return().
main([Image, Manifest, Seed, Ops]) ->
    process_flag(trap_exit, true),
    ok = erx_media_volume:new_mounts(),
    io:format("OTP ~s ~s", [erlang:system_info(otp_release), erlang:system_info(system_version)]),
    Status = try run(Image, Manifest, list_to_integer(Seed), list_to_integer(Ops)) of
                 Results -> lists:foreach(fun print_result/1, Results), 0
             catch throw:{load_failed, Op, Job, What} ->
                     io:format("FAILED seed=~s op=~b job=~s: ~0p~n", [Seed, Op, Job, What]), 1;
                   Class:Reason:Stack ->
                     io:format("FAILED seed=~s crashed: ~0p~n", [Seed, {Class, Reason, Stack}]), 1
             end,
    halt(Status).

run(Image, Manifest, Seed, Ops) ->
    {Proxy, Sectors} = medium(Image),
    Ctx0 = #{proxy => Proxy, sectors => Sectors, cluster => cluster_bytes(Image), seed => Seed, ops => Ops,
             op => 0, job => "mount", results => #{}, files => #{}, dirs => #{}, held => #{}},
    Jobs = [fun mounted/1, fun seq/1, fun rand/1, fun mixed/1, fun interleaved/1, fun truncated/1,
            fun small_files/1, fun remounted/1],
    Ctx = lists:foldl(fun(Job, C) -> Job(C) end, Ctx0, Jobs),
    finished(Ctx),
    ok = file:write_file(Manifest, manifest(Ctx)),
    results(Ctx).

%% ---------------------------------------------------------------------------
%% The medium: an image file behind a window proxy
%% ---------------------------------------------------------------------------

%% A proxy over the image at Path that answers info, runs of reads, writes of whole
%% sectors and flush, as erx_media_medium's window proxy does, and the image's count
%% of sectors. It ends with the test.
medium(Path) ->
    Test = self(),
    Proxy = spawn_link(fun() ->
                               erlang:monitor(process, Test),
                               {ok, Fd} = file:open(Path, [read, write, raw, binary]),
                               {ok, Bytes} = file:position(Fd, eof),
                               Test ! {medium, self(), Bytes div ?SECTOR},
                               medium_serve(Fd, Bytes div ?SECTOR)
                       end),
    receive {medium, Proxy, Sectors} -> {Proxy, Sectors} end.

medium_serve(Fd, Sectors) ->
    receive
        {'DOWN', _, process, _Test, _} ->
            ok;
        {'$gen_call', From, Request} ->
            gen:reply(From, medium_answer(Fd, Sectors, Request)),
            medium_serve(Fd, Sectors)
    end.

medium_answer(_Fd, Sectors, info) ->
    {ok, #{role => drive, sectors => Sectors, max_sectors => ?RUN}};
medium_answer(Fd, Sectors, {read, Lba, Count}) when Count >= 1, Count =< ?RUN, Lba + Count =< Sectors ->
    {ok, _} = file:pread(Fd, Lba * ?SECTOR, Count * ?SECTOR);
medium_answer(Fd, Sectors, {write, Lba, Bytes})
  when byte_size(Bytes) > 0, byte_size(Bytes) rem ?SECTOR =:= 0, byte_size(Bytes) div ?SECTOR =< ?RUN,
       Lba + byte_size(Bytes) div ?SECTOR =< Sectors ->
    file:pwrite(Fd, Lba * ?SECTOR, Bytes);
medium_answer(_Fd, _Sectors, flush) ->
    ok;
medium_answer(_Fd, _Sectors, Unserved) ->
    error({unserved, Unserved}).

%% The bytes of a cluster, from the boot sector of the image at Path.
cluster_bytes(Path) ->
    {ok, Fd} = file:open(Path, [read, raw, binary]),
    {ok, <<_:11/binary, BytesPerSector:16/little, PerCluster, _/binary>>} = file:pread(Fd, 0, ?SECTOR),
    ok = file:close(Fd),
    BytesPerSector * PerCluster.

%% ---------------------------------------------------------------------------
%% The volume's calls, each counted and timed
%% ---------------------------------------------------------------------------

%% Call run as the job's next call of kind Kind; its answer, and Ctx with the call
%% counted, its time and the bytes it moved added to the job's kind.
timed(Ctx = #{op := Op, job := Job, results := Results}, Kind, Call) ->
    Start = erlang:monotonic_time(microsecond),
    Answer = Call(),
    Spent = erlang:monotonic_time(microsecond) - Start,
    Moved = case Answer of {ok, Bytes} when is_binary(Bytes) -> byte_size(Bytes); {ok, N} when is_integer(N) -> N; _ -> 0 end,
    Key = {Job, Kind},
    {First, Us, Calls, Total} = maps:get(Key, Results, {Op + 1, 0, 0, 0}),
    {Answer, Ctx#{op := Op + 1, results := Results#{Key => {First, Us + Spent, Calls + 1, Total + Moved}}}}.

%% The run's end at its last call: What is reported with the volume's exit, if it
%% ended.
failed(#{op := Op, job := Job, pid := Pid}, What) ->
    Exit = receive {'EXIT', Pid, Why} -> Why after 0 -> running end,
    throw({load_failed, Op, Job, {What, {volume, Exit}}}).

pid(#{pid := Pid}) -> Pid.

%% The volume's answer to the call, which must match Expected.
expect(Ctx, Kind, What, Call, Expected) ->
    case timed(Ctx, Kind, Call) of
        {Answer, Next} -> Expected(Answer) orelse failed(Next, {What, Answer}), {Answer, Next}
    end.

create(Ctx, Dir, Name) ->
    case timed(Ctx, create, fun() -> erx_media_volume:create(pid(Ctx), Dir, Name) end) of
        {{ok, file, Q}, Next} -> {{ok, Q}, Next};
        {{error, enospc}, Next} -> {enospc, Next};
        {Other, Next} -> failed(Next, {create, Name, Other})
    end.

mkdir(Ctx, Dir, Name) ->
    case timed(Ctx, mkdir, fun() -> erx_media_volume:mkdir(pid(Ctx), Dir, Name) end) of
        {{ok, dir, Q}, Next} -> {Q, Next};
        {Other, Next} -> failed(Next, {mkdir, Name, Other})
    end.

write(Ctx, Q, Offset, Bytes) ->
    Size = byte_size(Bytes),
    case timed(Ctx, write, fun() -> erx_media_volume:write(pid(Ctx), Q, Offset, binary:copy(Bytes)) end) of
        {{ok, Size}, Next} -> {ok, Next};
        {{error, enospc}, Next} -> {enospc, Next};
        {Other, Next} -> failed(Next, {write, Offset, Size, Other})
    end.

%% A write the volume must take.
write_ok(Ctx, Q, Offset, Bytes) ->
    case write(Ctx, Q, Offset, Bytes) of
        {ok, Next} -> Next;
        {enospc, Next} -> failed(Next, {write, Offset, byte_size(Bytes), enospc})
    end.

truncate(Ctx, Q, Size) ->
    {_, Next} = expect(Ctx, truncate, {truncate, Size}, fun() -> erx_media_volume:truncate(pid(Ctx), Q, Size) end,
                       fun(A) -> A =:= ok end),
    Next.

fsync(Ctx) -> synced(Ctx, fsync).

synced(Ctx, Kind) ->
    {_, Next} = expect(Ctx, Kind, Kind, fun() -> erx_media_volume:fsync(pid(Ctx)) end, fun(A) -> A =:= ok end),
    Next.

remove(Ctx, Dir, Name) ->
    {_, Next} = expect(Ctx, remove, {remove, Name}, fun() -> erx_media_volume:remove(pid(Ctx), Dir, Name) end,
                       fun(A) -> A =:= ok end),
    Next.

%% A rename: ok, or enospc where the target directory has no room for the name and
%% the volume no cluster to grow it.
rename(Ctx, FromDir, From, ToDir, To) ->
    case timed(Ctx, rename, fun() -> erx_media_volume:rename(pid(Ctx), FromDir, From, ToDir, To) end) of
        {ok, Next} -> {ok, Next};
        {{error, enospc}, Next} -> {enospc, Next};
        {Other, Next} -> failed(Next, {rename, From, To, Other})
    end.

walk(Ctx, Dir, Name, Kind) ->
    case timed(Ctx, walk, fun() -> erx_media_volume:walk(pid(Ctx), Dir, Name) end) of
        {{ok, Kind, Q}, Next} -> {Q, Next};
        {Other, Next} -> failed(Next, {walk, Name, Other})
    end.

list(Ctx, Dir) ->
    case timed(Ctx, list, fun() -> erx_media_volume:list(pid(Ctx), Dir) end) of
        {{ok, Entries}, Next} -> {Entries, Next};
        {Other, Next} -> failed(Next, {list, Other})
    end.

%% The node is no longer named by the test.
forget(Ctx, Q) -> erx_media_volume:forget(pid(Ctx), Q).

%% Count bytes of the file at Q from Offset, through the volume's waiting request, as
%% the media tree sends it.
read(Ctx, Q, Offset, Count) ->
    case timed(Ctx, read, fun() -> waiting_read(pid(Ctx), Q, Offset, Count) end) of
        {{ok, Bytes}, Next} -> {Bytes, Next};
        {Other, Next} -> failed(Next, {read, Offset, Count, Other})
    end.

waiting_read(Pid, Q, Offset, Count) ->
    Monitor = erlang:monitor(process, Pid),
    Alias = alias(),
    Pid ! ?ERX_FS_WAIT({grant, Alias}, {read, Q, Offset, Count}),
    receive
        ?ERX_FS_ANSWER(Alias, Answer) -> erlang:demonitor(Monitor, [flush]), unalias(Alias), Answer;
        {'DOWN', Monitor, process, Pid, Why} -> unalias(Alias), {error, {ended, Why}}
    end.

%% ---------------------------------------------------------------------------
%% The model of a file: its size and its 4 KiB chunks
%% ---------------------------------------------------------------------------
%% Each chunk is ?CHUNK bytes, zero past the size, and a chunk not held is zeros, so
%% a file extended by a write past its end or a truncate reads zeros in the gap.

empty() -> {0, #{}}.

model_size({Size, _Chunks}) -> Size.

model_write({Size, Chunks}, Offset, Bytes) ->
    {max(Size, Offset + byte_size(Bytes)), put_bytes(Chunks, Offset, Bytes)}.

put_bytes(Chunks, _Offset, <<>>) ->
    Chunks;
put_bytes(Chunks, Offset, Bytes) ->
    Index = Offset div ?CHUNK,
    At = Offset rem ?CHUNK,
    Take = min(?CHUNK - At, byte_size(Bytes)),
    <<Part:Take/binary, Rest/binary>> = Bytes,
    Chunk = case Take of
                ?CHUNK -> Part;
                _ -> <<Head:At/binary, _:Take/binary, Tail/binary>> = chunk(Chunks, Index),
                     <<Head/binary, Part/binary, Tail/binary>>
            end,
    put_bytes(Chunks#{Index => Chunk}, Offset + Take, Rest).

chunk(Chunks, Index) -> maps:get(Index, Chunks, <<0:(?CHUNK * 8)>>).

model_truncate({Size, Chunks}, New) when New >= Size ->
    {New, Chunks};
model_truncate({_Size, Chunks}, New) ->
    Index = New div ?CHUNK,
    Kept = maps:filter(fun(I, _) -> I < Index end, Chunks),
    case {New rem ?CHUNK, Chunks} of
        {At, #{Index := Chunk}} when At > 0 ->
            <<Head:At/binary, _/binary>> = Chunk,
            {New, Kept#{Index => <<Head/binary, 0:((?CHUNK - At) * 8)>>}};
        _ ->
            {New, Kept}
    end.

%% The bytes a read of Count from Offset answers.
model_read({Size, Chunks}, Offset, Count) ->
    End = min(Size, Offset + Count),
    iolist_to_binary(get_bytes(Chunks, Offset, End)).

get_bytes(_Chunks, Offset, End) when Offset >= End ->
    [];
get_bytes(Chunks, Offset, End) ->
    Index = Offset div ?CHUNK,
    At = Offset rem ?CHUNK,
    Take = min(?CHUNK - At, End - Offset),
    [binary:part(chunk(Chunks, Index), At, Take) | get_bytes(Chunks, Offset + Take, End)].

model_md5({Size, Chunks}) ->
    Last = (Size + ?CHUNK - 1) div ?CHUNK,
    Context = lists:foldl(fun(Index, C) ->
                                  Take = min(?CHUNK, Size - Index * ?CHUNK),
                                  erlang:md5_update(C, binary:part(chunk(Chunks, Index), 0, Take))
                          end, erlang:md5_init(), lists:seq(0, Last - 1)),
    erlang:md5_final(Context).

%% ---------------------------------------------------------------------------
%% Jobs
%% ---------------------------------------------------------------------------

%% Ctx as job Name starts: its seeded draws and its pool of bytes.
job(Ctx = #{seed := Seed}, Name) ->
    Rand0 = rand:seed_s(exsss, {Seed, erlang:phash2(Name), 16#fa7}),
    {Pool, Rand} = rand:bytes_s(?POOL + ?PIECE, Rand0),
    Ctx#{job := Name, rand => Rand, pool => Pool}.

uniform(Ctx = #{rand := Rand}, N) ->
    {X, Next} = rand:uniform_s(N, Rand),
    {X, Ctx#{rand := Next}}.

%% Count bytes to write, a slice of the pool at a random place, which the model keeps;
%% write/4 sends the volume a copy, a binary of its own as a request's bytes are.
bytes(Ctx = #{pool := Pool}, Count) when Count =< ?PIECE ->
    {At, Next} = uniform(Ctx, ?POOL),
    {binary:part(Pool, At - 1, Count), Next}.

volume_bytes(#{sectors := Sectors}) -> Sectors * ?SECTOR.

%% The largest size of a file.
file_cap(Ctx = #{cluster := Cluster}) -> volume_bytes(Ctx) div ?FILE_SHARE div Cluster * Cluster.

%% Size scaled from the volume, at most Max, a multiple of Unit.
scaled(Ctx, Share, Max, Unit) -> min(volume_bytes(Ctx) div Share, Max) div Unit * Unit.

%% The file at Path, created and held, empty in the model.
new_file(Ctx, Path) ->
    {Parent, Name} = split(Path),
    #{dirs := #{Parent := Dir}} = Ctx,
    case create(Ctx, Dir, Name) of
        {{ok, Q}, C = #{held := Held, files := Files}} ->
            {Q, C#{held := Held#{Path => Q}, files := Files#{Path => empty()}}};
        {enospc, C} -> failed(C, {create, Path, enospc})
    end.

split(Path) -> {lists:droplast(Path), lists:last(Path)}.

%% A write of Bytes at Offset of the held file at Path, in the model too.
file_write(Ctx, Path, Offset, Bytes) ->
    #{held := #{Path := Q}} = Ctx,
    C = #{files := Files} = write_ok(Ctx, Q, Offset, Bytes),
    C#{files := Files#{Path := model_write(maps:get(Path, Files), Offset, Bytes)}}.

%% Size bytes appended to the held file at Path, in pieces of at most Piece.
fill_file(Ctx, Path, Size, Piece) ->
    #{files := #{Path := Model}} = Ctx,
    case model_size(Model) of
        At when At >= Size -> Ctx;
        At -> {Bytes, C} = bytes(Ctx, min(Piece, Size - At)), fill_file(file_write(C, Path, At, Bytes), Path, Size, Piece)
    end.

%% The held file at Path read whole, each piece compared with the model, and a
%% read at its end, which answers nothing.
verify_held(Ctx, Path) ->
    #{held := #{Path := Q}} = Ctx,
    verify(Ctx, Path, Q).

verify(Ctx, Path, Q) ->
    #{files := #{Path := Model}} = Ctx,
    Size = model_size(Model),
    C = lists:foldl(fun(Offset, Acc) -> compared(Acc, Path, Q, Offset, ?PIECE) end, Ctx,
                    lists:seq(0, Size - 1, ?PIECE)),
    compared(C, Path, Q, Size, ?PIECE).

%% A read of Count at Offset of the file at Q, compared with the model of Path.
compared(Ctx, Path, Q, Offset, Count) ->
    {Bytes, C} = read(Ctx, Q, Offset, Count),
    #{files := #{Path := Model}} = C,
    case model_read(Model, Offset, Count) of
        Bytes -> C;
        Expected -> failed(C, {differs, join(Path), Offset, first_difference(Bytes, Expected),
                               byte_size(Bytes), byte_size(Expected)})
    end.

first_difference(A, B) -> binary:longest_common_prefix([A, B]).

mounted(Ctx = #{proxy := Proxy, sectors := Sectors}) ->
    C0 = job(Ctx, "mount"),
    {{Pid, Outcome}, C1} = timed(C0, mount, fun() ->
                                                    {ok, P} = erx_media_volume:start_link(
                                                                Proxy, #{number => 1, first => 0, length => Sectors}),
                                                    {P, erx_media_volume:outcome(P)}
                                            end),
    C2 = C1#{pid => Pid},
    is_map(Outcome) andalso maps:get(mount, Outcome, none) =:= rw orelse failed(C2, {outcome, Outcome}),
    case timed(C2, walk, fun() -> erx_media_volume:root(Pid) end) of
        {{ok, dir, Root}, C3} -> C3#{dirs := #{[] => Root}, held := #{}};
        {Other, C3} -> failed(C3, {root, Other})
    end.

seq(Ctx) ->
    C0 = job(Ctx, "seq"),
    Path = [<<"seq.bin">>],
    {_, C1} = new_file(C0, Path),
    C2 = fsync(fill_file(C1, Path, min(scaled(C1, 4, 256 bsl 20, ?PIECE), file_cap(C1) div ?PIECE * ?PIECE), ?PIECE)),
    verify_held(C2, Path).

rand_path() -> [<<"rand.bin">>].

rand(Ctx) ->
    C0 = job(Ctx, "rand-layout"),
    {_, C1} = new_file(C0, rand_path()),
    C2 = fsync(fill_file(C1, rand_path(), min(scaled(C1, 8, 64 bsl 20, ?CHUNK), file_cap(C1) div 2 div ?CHUNK * ?CHUNK), ?PIECE)),
    C3 = lists:foldl(fun(Every, C) -> rand_job(job(C, "rand-fsync" ++ integer_to_list(Every)), Every) end, C2,
                     [0, 1, 16]),
    verify_held(job(C3, "rand-verify"), rand_path()).

rand_job(Ctx = #{ops := Ops}, Every) ->
    {_, C} = lists:foldl(fun(_, {Writes, Acc}) -> rand_op(Acc, Every, Writes) end, {0, Ctx}, lists:seq(1, Ops)),
    C.

rand_op(Ctx = #{files := #{[<<"rand.bin">>] := Model}}, Every, Writes) ->
    {Block, C1} = uniform(Ctx, model_size(Model) div ?CHUNK),
    Offset = (Block - 1) * ?CHUNK,
    case uniform(C1, 2) of
        {1, C2} ->
            #{held := #{[<<"rand.bin">>] := Q}} = C2,
            {Writes, compared(C2, rand_path(), Q, Offset, ?CHUNK)};
        {2, C2} ->
            {Bytes, C3} = bytes(C2, ?CHUNK),
            C4 = file_write(C3, rand_path(), Offset, Bytes),
            case Every > 0 andalso (Writes + 1) rem Every =:= 0 of
                true -> {Writes + 1, fsync(C4)};
                false -> {Writes + 1, C4}
            end
    end.

mixed(Ctx = #{ops := Ops}) ->
    C = lists:foldl(fun(_, Acc) -> mixed_op(Acc) end, job(Ctx, "mixed"), lists:seq(1, Ops)),
    verify_held(C, rand_path()).

mixed_op(Ctx = #{files := #{[<<"rand.bin">>] := Model}}) ->
    {Offset1, C1} = uniform(Ctx, min(model_size(Model) + ?PIECE, file_cap(Ctx))),
    {Count0, C2} = uniform(C1, ?PIECE),
    Count = min(Count0, file_cap(C2) - (Offset1 - 1)),
    case uniform(C2, 2) of
        {1, C3} -> #{held := #{[<<"rand.bin">>] := Q}} = C3, compared(C3, rand_path(), Q, Offset1 - 1, Count);
        {2, C3} -> {Bytes, C4} = bytes(C3, Count), file_write(C4, rand_path(), Offset1 - 1, Bytes)
    end.

interleaved_paths() -> [[<<"inter">>, <<"stream ", (integer_to_binary(N))/binary, ".dat">>] || N <- lists:seq(1, ?INTERLEAVED)].

interleaved(Ctx) ->
    C0 = job(Ctx, "interleave"),
    C1 = made_dir([<<"inter">>], C0),
    C2 = lists:foldl(fun(Path, C) -> element(2, new_file(C, Path)) end, C1, interleaved_paths()),
    Target = min(scaled(C2, 32, 32 bsl 20, 1), file_cap(C2) div 2),
    C3 = fsync(interleave(C2, interleaved_paths(), Target)),
    lists:foldl(fun(Path, C) -> verify_held(C, Path) end, C3, interleaved_paths()).

%% Each file in turn given a piece of up to 32 KiB, until each holds Target bytes.
interleave(Ctx, [], _Target) ->
    Ctx;
interleave(Ctx, [Path | Rest], Target) ->
    #{files := #{Path := Model}} = Ctx,
    case model_size(Model) of
        Size when Size >= Target -> interleave(Ctx, Rest, Target);
        Size -> {Count, C1} = uniform(Ctx, min(32768, Target - Size)),
                {Bytes, C2} = bytes(C1, Count),
                interleave(file_write(C2, Path, Size, Bytes), Rest ++ [Path], Target)
    end.

truncated(Ctx = #{ops := Ops}) ->
    Paths = [rand_path() | interleaved_paths()],
    C = lists:foldl(fun(_, Acc) -> truncate_op(Acc, Paths) end, job(Ctx, "truncate"), lists:seq(1, max(1, Ops div 2))),
    lists:foldl(fun(Path, Acc) -> verify_held(Acc, Path) end, fsync(C), Paths).

%% A file shrunk, extended or written across its end, and the bytes about its new
%% end read back.
truncate_op(Ctx, Paths) ->
    {Pick, C1} = uniform(Ctx, length(Paths)),
    Path = lists:nth(Pick, Paths),
    #{files := #{Path := Model}, held := #{Path := Q}} = C1,
    Size = model_size(Model),
    {C3, New} = case uniform(C1, 3) of
                    {1, C2} -> {Smaller, C} = uniform(C2, Size + 1), {resized(C, Path, Q, Smaller - 1), Smaller - 1};
                    {2, C2} -> {More, C} = uniform(C2, ?PIECE),
                               Grown = min(Size + More, file_cap(C)),
                               {resized(C, Path, Q, Grown), Grown};
                    {3, C2} -> {Back, Cb} = uniform(C2, min(Size, ?CHUNK) + 1),
                               {Count0, Cc} = uniform(Cb, 16384),
                               Count = max(0, min(Count0, file_cap(Cc) - (Size - (Back - 1)))),
                               {Bytes, C} = bytes(Cc, Count),
                               {file_write(C, Path, Size - (Back - 1), Bytes), Size - (Back - 1) + Count}
                end,
    compared(C3, Path, Q, max(0, New - ?CHUNK), 2 * ?CHUNK).

resized(Ctx, Path, Q, Size) ->
    C = #{files := Files} = truncate(Ctx, Q, Size),
    C#{files := Files#{Path := model_truncate(maps:get(Path, Files), Size)}}.

%% ---------------------------------------------------------------------------
%% Small files until the volume is full, then churn and fill again
%% ---------------------------------------------------------------------------

%% Files of file_cap/1 bytes, written whole, until about an eighth of the volume, at
%% least ?ROOM_MIN, is left for the small files, which then fill that much; each is
%% read back whole by the remount.
ballast(Ctx) ->
    C0 = made_dir([<<"ballast">>], job(Ctx, "ballast")),
    Left = volume_bytes(C0) * 9 div 10 - used_bytes(C0) - max(?ROOM_MIN, volume_bytes(C0) div 8),
    lists:foldl(fun(N, C) ->
                        Path = [<<"ballast">>, <<"b", (integer_to_binary(N))/binary, ".bin">>],
                        {Q, C1} = new_file(C, Path),
                        C2 = #{held := Held} = fill_file(C1, Path, file_cap(C1), ?PIECE),
                        forget(C2, Q),
                        C2#{held := maps:remove(Path, Held)}
                end, C0, lists:seq(1, max(0, Left div file_cap(C0)))).

%% The bytes the model's files and directories take on the volume, in clusters.
used_bytes(Ctx = #{files := Files, dirs := Dirs, cluster := Cluster}) ->
    Cluster * (map_size(Dirs) + lists:sum([clusters(model_size(Model), Ctx) || _ := Model <- Files])).

small_files(Ctx) ->
    C0 = job(ballast(Ctx), "files"),
    C1 = tree(C0),
    {First, C2} = fill(C1, 0, 0),
    {Freed, C3} = churn(fsync(C2)),
    C4 = verify_small(fsync(C3)),
    {Refilled, C5} = fill(C4, maps:get(next_id, C4), 0),
    C6 = verify_small(fsync(C5)),
    %% The refill takes back what the churn freed, less the last file that did not
    %% fit, and the clusters that directories took.
    Slack = clusters(small_max(C6), C6) + 64 + Freed div 50,
    Refilled >= Freed - Slack orelse failed(C6, {refill_short, #{first => First, freed => Freed, refilled => Refilled}}),
    C6.

%% The directories of the small files, held: a top, ?MIDS below it and ?LEAVES below
%% each, the leaves holding the files.
tree(Ctx) ->
    Top = [<<"tree">>],
    Mids = [Top ++ [<<"Mid level ", (integer_to_binary(M))/binary>>] || M <- lists:seq(1, ?MIDS)],
    Leaves = [Mid ++ [<<"d", (integer_to_binary(L))/binary>>] || Mid <- Mids, L <- lists:seq(1, ?LEAVES)],
    C = lists:foldl(fun made_dir/2, Ctx, [Top | Mids] ++ Leaves),
    C#{leaves => Leaves}.

%% The directory at Path made and held.
made_dir(Path, Ctx) ->
    {Parent, Name} = split(Path),
    #{dirs := #{Parent := Dir}} = Ctx,
    {Q, C} = mkdir(Ctx, Dir, Name),
    add_dir(C, Path, Q).

add_dir(Ctx = #{dirs := Dirs}, Path, Q) -> Ctx#{dirs := Dirs#{Path => Q}}.

small_max(Ctx) -> min(max(16384, volume_bytes(Ctx) div 4096), file_cap(Ctx)).

clusters(Size, #{cluster := Cluster}) -> (Size + Cluster - 1) div Cluster.

%% Files made until the volume answers enospc: the clusters they took. Id names the
%% next file.
fill(Ctx, Id, Taken) ->
    {Pick, C1} = uniform(Ctx, length(maps:get(leaves, Ctx))),
    Leaf = lists:nth(Pick, maps:get(leaves, C1)),
    {Size, C2} = small_size(C1),
    Name = small_name(Id),
    Path = Leaf ++ [Name],
    #{dirs := #{Leaf := Dir}} = C2,
    case create(C2, Dir, Name) of
        {enospc, C3} ->
            {Taken, C3#{next_id => Id + 1}};
        {{ok, Q}, C3} ->
            case small_write(C3, Q, 0, Size, empty()) of
                {enospc, C4} ->
                    forget(C4, Q),
                    {Taken, (remove(C4, Dir, Name))#{next_id => Id + 1}};
                {Model, C4 = #{files := Files}} ->
                    forget(C4, Q),
                    fill(C4#{files := Files#{Path => Model}}, Id + 1, Taken + clusters(Size, C4))
            end
    end.

%% Size bytes written from Offset to the file at Q, in pieces: the model, or enospc.
small_write(Ctx, _Q, Offset, Size, Model) when Offset >= Size ->
    {Model, Ctx};
small_write(Ctx, Q, Offset, Size, Model) ->
    {Bytes, C1} = bytes(Ctx, min(?PIECE, Size - Offset)),
    case write(C1, Q, Offset, Bytes) of
        {ok, C2} -> small_write(C2, Q, Offset + byte_size(Bytes), Size, model_write(Model, Offset, Bytes));
        {enospc, C2} -> {enospc, C2}
    end.

%% Most files small, some up to small_max/1.
small_size(Ctx) ->
    case uniform(Ctx, 4) of
        {1, C} -> uniform_from_zero(C, 512);
        {2, C} -> uniform_from_zero(C, 4096);
        {_, C} -> uniform_from_zero(C, small_max(C))
    end.

uniform_from_zero(Ctx, Max) ->
    {X, C} = uniform(Ctx, Max + 1),
    {X - 1, C}.

%% Short names, long names and names that need a long entry for their case.
small_name(Id) ->
    Number = integer_to_binary(Id),
    case Id rem 3 of
        0 -> <<"F", Number/binary, ".DAT">>;
        1 -> <<"file ", Number/binary, " of the load test.dat">>;
        2 -> <<"f", Number/binary, ".data">>
    end.

small_paths(#{files := Files}) -> lists:sort([Path || [<<"tree">> | _] = Path <- maps:keys(Files)]).

%% Each small file removed or renamed, half of them: the clusters freed. A rename
%% moves a file to another directory under a new name, or onto another small file,
%% which it replaces.
churn(Ctx) ->
    lists:foldl(fun(Path, {Freed, C}) -> churned(C, Path, Freed) end, {0, Ctx}, small_paths(Ctx)).

churned(Ctx = #{files := Files}, Path, Freed) when not is_map_key(Path, Files) ->
    {Freed, Ctx};
churned(Ctx, Path, Freed) ->
    {Parent, Name} = split(Path),
    #{dirs := #{Parent := Dir}, files := Files} = Ctx,
    Size = model_size(maps:get(Path, Files)),
    case uniform(Ctx, 16) of
        {Pick, C} when Pick =< 6 ->
            {Freed + clusters(Size, C), (remove(C, Dir, Name))#{files := maps:remove(Path, Files)}};
        {7, C} ->
            {Target, C1} = other_small(C, Path),
            {TargetParent, TargetName} = split(Target),
            #{dirs := #{TargetParent := TargetDir}} = C1,
            Replaced = model_size(maps:get(Target, Files)),
            case rename(C1, Dir, Name, TargetDir, TargetName) of
                {ok, C2} -> {Freed + clusters(Replaced, C2),
                             C2#{files := maps:remove(Path, Files#{Target := maps:get(Path, Files)})}};
                {enospc, C2} -> {Freed, C2}
            end;
        {8, C} ->
            {Pick, C1} = uniform(C, length(maps:get(leaves, C))),
            Leaf = lists:nth(Pick, maps:get(leaves, C1)),
            #{dirs := #{Leaf := LeafDir}, next_id := Id} = C1,
            NewName = small_name(Id),
            case rename(C1#{next_id := Id + 1}, Dir, Name, LeafDir, NewName) of
                {ok, C2} -> {Freed, C2#{files := maps:remove(Path, Files#{Leaf ++ [NewName] => maps:get(Path, Files)})}};
                {enospc, C2} -> {Freed, C2}
            end;
        {_, C} ->
            {Freed, C}
    end.

%% Another small file than Path, drawn at random.
other_small(Ctx, Path) ->
    Others = lists:delete(Path, small_paths(Ctx)),
    {Pick, C} = uniform(Ctx, length(Others)),
    {lists:nth(Pick, Others), C}.

%% Every small file walked to and read whole.
verify_small(Ctx) ->
    lists:foldl(fun(Path, C) -> verify_walked(C, Path) end, Ctx, small_paths(Ctx)).

verify_walked(Ctx, Path) ->
    {Parent, Name} = split(Path),
    #{dirs := #{Parent := Dir}} = Ctx,
    {Q, C1} = walk(Ctx, Dir, Name, file),
    C2 = verify(C1, Path, Q),
    forget(C2, Q),
    C2.

%% ---------------------------------------------------------------------------
%% Remount: the volume finished, mounted again and read whole
%% ---------------------------------------------------------------------------

%% Every directory walked to and held and listed, and then every file read whole.
remounted(Ctx) ->
    C1 = finished(job(Ctx, "remount")),
    C2 = mounted(C1),
    C3 = job(C2, "remount"),
    C4 = lists:foldl(fun walked_dir/2, C3, lists:sort(maps:keys(model_dirs(Ctx)))),
    C5 = lists:foldl(fun listed/2, C4, lists:sort(maps:keys(model_dirs(Ctx)))),
    lists:foldl(fun(Path, C) -> verify_walked(C, Path) end, C5, lists:sort(maps:keys(maps:get(files, C5)))).

%% The directories of the model: each held one's path, the root among them.
model_dirs(#{dirs := Dirs}) -> Dirs.

walked_dir([], Ctx) ->
    Ctx;
walked_dir(Path, Ctx) ->
    {Parent, Name} = split(Path),
    #{dirs := #{Parent := Dir}} = Ctx,
    {Q, C} = walk(Ctx, Dir, Name, dir),
    add_dir(C, Path, Q).

%% The directory's listing holds exactly the model's names, each of its kind.
listed(Path, Ctx = #{dirs := Dirs, files := Files}) ->
    {Entries, C} = list(Ctx, maps:get(Path, Dirs)),
    Children = fun(Map, Kind) -> [{Name, Kind} || P <- maps:keys(Map), P =/= [], {Parent, Name} <- [split(P)],
                                                Parent =:= Path] end,
    Expected = lists:sort(Children(Dirs, dir) ++ Children(Files, file)),
    case lists:sort([{Name, Kind} || {Name, Kind, _} <- Entries]) of
        Expected -> C;
        Got -> failed(C, {listing, join(Path), {missing, Expected -- Got}, {unexpected, Got -- Expected}})
    end.

%% The volume finished and its process ended, as its supervisor ends it.
finished(Ctx = #{pid := Pid}) ->
    {_, C} = expect(Ctx, finish, finish, fun() -> erx_media_volume:finish(Pid) end, fun(A) -> A =:= ok end),
    unlink(Pid),
    exit(Pid, shutdown),
    C.

%% ---------------------------------------------------------------------------
%% Output
%% ---------------------------------------------------------------------------

join(Path) -> lists:join(<<"/">>, Path).

manifest(Ctx = #{files := Files}) ->
    Dirs = [[<<"d ">>, join(Path), $\n] || Path <- maps:keys(model_dirs(Ctx)), Path =/= []],
    Lines = [[<<"f ">>, integer_to_binary(model_size(Model)), $\s, hex(model_md5(Model)), $\s, join(Path), $\n]
             || Path := Model <- Files],
    lists:sort([iolist_to_binary(Line) || Line <- Dirs ++ Lines]).

hex(Bytes) -> binary:encode_hex(Bytes, lowercase).

%% Each job's kinds of call, in the order the run first made them.
results(#{results := Results}) ->
    lists:sort([{First, Job, Kind, Us, Calls, Bytes} || {Job, Kind} := {First, Us, Calls, Bytes} <- Results]).

print_result({_First, Job, Kind, Us, Calls, Bytes}) ->
    io:format("RESULT ~s ~s ~b ~b ~b~n", [Job, Kind, Calls, Bytes, Us]).
