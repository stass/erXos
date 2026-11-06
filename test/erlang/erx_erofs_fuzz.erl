%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the EROFS reader, erx_erofs, and its funnel, erx_verity
%% (docs/design-storage.md, Reading EROFS images and Verification). It runs from
%% tools/fuzz/erx_erofs.rb, which also runs it against seeded faults.
%%
%% First the fixture images that mkfs.erofs wrote must read as the tree that
%% tools/erofs_fixtures.rb gave mkfs.erofs (failure `mismatch`). Then each case
%% mutates one of them, byte writes and little-endian field values biased to the
%% superblock, the root inode and its inline directory, and the rest of block 0, mostly with the
%% superblock's CRC-32C fixed up by this module's own table-driven CRC so that the
%% mutations reach the parser, and runs every operation over the tree's names and
%% some others. Each must answer a value of its declared shape (`shape`), never
%% raise (`crash`), read a bounded number of blocks (`unbounded`), hand every
%% failure of a malformed image to the log (`silent_eio`) as printable ASCII
%% (`diagnostic_text`), refuse an image whose superblock changed under its
%% checksum (`crc`), and refuse a walk of more than ERX_NS_NAMES_MAX names
%% (`names_bound`).
-module(erx_erofs_fuzz).
-export([run/1]).

-define(CASES, 1500).
-define(BLOCK, 4096).
-define(READS_MAX, 2000).
-define(IMAGES, ["compact", "extended", "plain"]).
%% Every fixture has its root, inode 36, at this byte, with its inline
%% directory entries after it but in the plain image.
-define(ROOT_INODE, (36 * 32)).

run([Seed]) ->
    rand:seed(exsss, list_to_integer(Seed)),
    Images = [{Name, erx_erofs_tests:fixture(Name)} || Name <- ?IMAGES],
    Tree = erx_erofs_tests:expected(),
    [clean(Name, Bytes) || {Name, Bytes} <- Images],
    Names = [element(2, Entry) || Entry <- Tree] ++ bogus(),
    [mutated(Images, Names) || _ <- lists:seq(1, ?CASES)],
    io:format("fuzz: ~b images ok~n", [?CASES + length(Images)]),
    halt(0).

fail(Property, Detail) ->
    io:format("fuzz failure: ~s: ~0tp~n", [Property, Detail]),
    halt(1).

bogus() ->
    [[<<"nope">>], [<<"a">>, <<"nope">>], [<<"small">>, <<"x">>], [<<"a">>, <<"b">>, <<"up">>, <<"c">>],
     [<<".">>], [<<"..">>], [<<0>>], [<<"a/b">>], [binary:copy(<<"x">>, 255)]].

clean(Name, Bytes) ->
    {ok, Image} = erx_erofs_tests:open(Bytes),
    try
        {ok, Fs} = erx_erofs:mount(Image, fun(Line) -> self() ! {log, Line} end),
        erx_erofs_tests:agrees(Fs)
    catch
        Class:Reason -> fail(mismatch, {Name, Class, Reason})
    end.

%% One case: a mutated image, mounted and read through a counting window.
mutated(Images, Names) ->
    {Name, Clean} = lists:nth(rand:uniform(length(Images)), Images),
    Mutations = [mutation(byte_size(Clean)) || _ <- lists:seq(1, rand:uniform(8))],
    Mutated = lists:foldl(fun apply_mutation/2, Clean, Mutations),
    Fixed = rand:uniform(10) =/= 1,
    Bytes = case Fixed of
                true -> fix_crc(Mutated);
                false -> Mutated
            end,
    %% Blocks read by the current operation, and whether it went past the bound.
    Reads = atomics:new(2, []),
    {ok, Image} = erx_erofs_tests:open(Bytes, fun(_, Count, Part) ->
                                                      case atomics:add_get(Reads, 1, Count) of
                                                          N when N > ?READS_MAX ->
                                                              atomics:put(Reads, 2, 1),
                                                              {error, unbounded};
                                                          _ -> {ok, Part}
                                                      end
                                              end),
    Case = {Name, Mutations, Fixed},
    try
        case guarded(Case, fun() -> erx_erofs:mount(Image, fun(Line) -> self() ! {log, Line} end) end) of
            {ok, Fs} ->
                checksummed(Bytes) andalso superblock_changed(Clean, Bytes) andalso not Fixed
                    andalso fail(crc, Case),
                [operations(Case, Fs, Reads, pick(Names)) || _ <- lists:seq(1, 20)],
                atomics:put(Reads, 1, 0),
                {[], {error, enametoolong}} =:= erx_erofs:walk(Fs, lists:duplicate(257, <<"a">>))
                    orelse fail(names_bound, Case);
            {error, Posix, Text} when is_atom(Posix), is_binary(Text) ->
                printable(Case, Text);
            Other ->
                fail(shape, {Case, mount, Other})
        end
    after
        flush()
    end.

%% Whether the image still asks for its superblock's checksum to be checked.
checksummed(<<_:1032/binary, Compat:32/little, _/binary>>) -> Compat band 1 =:= 1;
checksummed(_) -> false.

superblock_changed(Clean, Bytes) ->
    binary:part(Clean, 1024, ?BLOCK - 1024) =/= binary:part(Bytes, 1024, ?BLOCK - 1024).

operations(Case, Fs, Reads, Path) ->
    Offset = rand:uniform(5 * ?BLOCK) - 1,
    Length = rand:uniform(3 * ?BLOCK),
    Ops = [{walk, fun() -> erx_erofs:walk(Fs, Path) end},
           {info, fun() -> erx_erofs:read_file_info(Fs, Path) end},
           {list, fun() -> erx_erofs:list_dir(Fs, Path) end},
           {read, fun() -> erx_erofs:read_file(Fs, Path) end},
           {link, fun() -> erx_erofs:read_link(Fs, Path) end},
           {pread, fun() -> erx_erofs:pread(Fs, Path, Offset, Length) end}],
    [begin
         atomics:put(Reads, 1, 0),
         flush(),
         Result = guarded(Case, Op),
         atomics:get(Reads, 2) =:= 0 orelse fail(unbounded, {Case, Kind, Path}),
         shaped(Kind, Result) orelse fail(shape, {Case, Kind, Path, Result}),
         eio(Result) andalso logged(Case, Kind, Path)
     end || {Kind, Op} <- Ops].

guarded(Case, Op) ->
    try Op()
    catch
        Class:Reason:Stack -> fail(crash, {Case, Class, Reason, Stack})
    end.

shaped(walk, {Kinds, End}) ->
    is_list(Kinds) andalso lists:all(fun(K) -> lists:member(K, [directory, link, other]) end, Kinds)
        andalso (End =:= ok orelse posix(End));
shaped(info, {ok, #{type := T, size := S}}) -> lists:member(T, [regular, directory, symlink]) andalso S >= 0;
shaped(list, {ok, Names}) -> lists:all(fun is_binary/1, Names);
shaped(read, {ok, Bytes}) -> is_binary(Bytes);
shaped(link, {ok, Text}) -> is_binary(Text) andalso byte_size(Text) >= 1;
shaped(pread, {ok, Bytes}) -> is_binary(Bytes);
shaped(pread, eof) -> true;
shaped(_, Result) -> posix(Result).

posix({error, Posix}) -> lists:member(Posix, [eio, enotsup, enoent, enotdir, eisdir, einval, enametoolong]);
posix(_) -> false.

eio({error, eio}) -> true;
eio({_, {error, eio}}) -> true;
eio(_) -> false.

logged(Case, Kind, Path) ->
    receive
        {log, Text} -> printable(Case, Text)
    after 0 -> fail(silent_eio, {Case, Kind, Path})
    end.

printable(Case, Text) ->
    lists:all(fun(C) -> C >= 32 andalso C =< 126 end, binary_to_list(Text))
        orelse fail(diagnostic_text, {Case, Text}).

flush() ->
    receive {log, _} -> flush() after 0 -> ok end.

%% Mutations: {At, Bytes} written over the image.

mutation(Size) ->
    At = case rand:uniform(3) of
             1 -> ?ROOT_INODE + rand:uniform(512) - 1;
             2 -> 1024 + rand:uniform(?BLOCK - 1024) - 1;
             3 -> rand:uniform(Size) - 1
         end,
    Value = case rand:uniform(3) of
                1 -> <<(rand:uniform(256) - 1)>>;
                2 -> <<(pick([0, 1, 12, 255, 4095, 4096, 16#7fff, 16#ffff])):16/little>>;
                3 -> <<(pick([0, 1, 36, 4096, 16#7fffffff, 16#ffffffff])):32/little>>
            end,
    {At - At rem byte_size(Value), Value}.

pick(List) -> lists:nth(rand:uniform(length(List)), List).

apply_mutation({At, Value}, Bytes) when At + byte_size(Value) =< byte_size(Bytes) ->
    <<Before:At/binary, _:(byte_size(Value))/binary, After/binary>> = Bytes,
    <<Before/binary, Value/binary, After/binary>>;
apply_mutation(_, Bytes) ->
    Bytes.

%% The superblock checksum written as mkfs.erofs writes it, by a table-driven
%% CRC-32C independent of the reader's.
fix_crc(Bytes) when byte_size(Bytes) >= ?BLOCK ->
    <<Head:1028/binary, _:32, Rest/binary>> = Bytes,
    <<Covered:(?BLOCK - 1028)/binary, Tail/binary>> = Rest,
    Crc = crc(<<(binary:part(Head, 1024, 4))/binary, 0:32, Covered/binary>>),
    <<Head/binary, Crc:32/little, Covered/binary, Tail/binary>>;
fix_crc(Bytes) ->
    Bytes.

crc(Bytes) ->
    Table = list_to_tuple([entry(N, 8) || N <- lists:seq(0, 255)]),
    lists:foldl(fun(Byte, Crc) -> element(((Crc bxor Byte) band 255) + 1, Table) bxor (Crc bsr 8) end,
                16#FFFFFFFF, binary_to_list(Bytes)).

entry(Crc, 0) -> Crc;
entry(Crc, N) when Crc band 1 =:= 1 -> entry((Crc bsr 1) bxor 16#82F63B78, N - 1);
entry(Crc, N) -> entry(Crc bsr 1, N - 1).
