%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the EROFS reader, erx_erofs, and its funnel, erx_verity, over the
%% fixture images tools/erofs_fixtures.rb writes with mkfs.erofs from the tree
%% test/fixtures/erofs/tree.terms declares (ERX_EROFS_FIXTURES names the directory).
-module(erx_erofs_tests).
-include_lib("eunit/include/eunit.hrl").

-export([fixture/1, open/1, open/2, expected/0, contents/2, agrees/1]).

-define(BLOCK, 4096).

%% Fixture helpers, which the fuzz target shares.

fixture(Name) ->
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_EROFS_FIXTURES"), Name ++ ".img")),
    Bytes.

%% A window over Bytes that serves what Serve makes of each request.
open(Bytes) -> open(Bytes, fun(_, _, Part) -> {ok, Part} end).

open(Bytes, Serve) ->
    erx_verity:open(fun(First, Count) ->
                            Serve(First, Count, binary:part(Bytes, First * ?BLOCK, Count * ?BLOCK))
                    end, byte_size(Bytes) div ?BLOCK).

expected() ->
    {ok, Terms} = file:consult(filename:join(os:getenv("ERX_EROFS_FIXTURES"), "tree.terms")),
    Terms.

contents(Size, Seed) -> << <<((I * 7 + Seed) band 255)>> || I <- lists:seq(0, Size - 1) >>.

mount(Name) ->
    {ok, Image} = open(fixture(Name)),
    {ok, Fs} = erx_erofs:mount(Image, fun(Line) -> self() ! {log, Line} end),
    Fs.

logged() ->
    receive {log, Line} -> Line after 0 -> none end.

%% The tree, through every operation, on each image the reader implements.

tree_test_() ->
    [{Name, fun() -> agrees(mount(Name)) end} || Name <- ["compact", "extended", "plain"]].

agrees(Fs) ->
    lists:foreach(fun(Entry) -> entry(Fs, Entry) end, expected()),
    none = logged().

entry(Fs, {regular, Names, Size, Seed}) ->
    Bytes = contents(Size, Seed),
    ?assertEqual({ok, Bytes}, erx_erofs:read_file(Fs, Names)),
    {ok, #{type := regular, size := Size, mode := 8#644, uid := 0, gid := 0, mtime := {0, 0}}} =
        erx_erofs:read_file_info(Fs, Names),
    [?assertEqual(slice(Bytes, Offset, Length), erx_erofs:pread(Fs, Names, Offset, Length))
     || Offset <- [0, 1, 4095, 4096, 3 * 4096 - 1, 3 * 4096, Size - 1, Size, Size + 1],
        Offset >= 0, Length <- [0, 1, 50, 5000, 1 bsl 40]],
    ?assertEqual({lists:duplicate(length(Names) - 1, directory) ++ [other], ok}, erx_erofs:walk(Fs, Names));
entry(Fs, {symlink, Names, Target}) ->
    ?assertEqual({ok, Target}, erx_erofs:read_link(Fs, Names)),
    {ok, #{type := symlink}} = erx_erofs:read_file_info(Fs, Names),
    ?assertEqual({error, einval}, erx_erofs:read_file(Fs, Names)),
    ?assertEqual({lists:duplicate(length(Names) - 1, directory) ++ [link], ok},
                 erx_erofs:walk(Fs, Names ++ [<<"after">>]));
entry(Fs, {directory, Names, Children}) ->
    ?assertEqual({ok, Children}, erx_erofs:list_dir(Fs, Names)),
    {ok, #{type := directory}} = erx_erofs:read_file_info(Fs, Names),
    ?assertEqual({error, eisdir}, erx_erofs:read_file(Fs, Names)),
    ?assertEqual({error, einval}, erx_erofs:read_link(Fs, Names)),
    ?assertEqual({lists:duplicate(length(Names), directory), ok}, erx_erofs:walk(Fs, Names)).

slice(Bytes, Offset, _) when Offset >= byte_size(Bytes) -> eof;
slice(Bytes, Offset, Length) -> {ok, binary:part(Bytes, Offset, min(Length, byte_size(Bytes) - Offset))}.

walks_end_as_the_resolver_reads_them_test() ->
    Fs = mount("compact"),
    ?assertEqual({[], {error, enoent}}, erx_erofs:walk(Fs, [<<"nope">>])),
    ?assertEqual({[directory], {error, enoent}}, erx_erofs:walk(Fs, [<<"a">>, <<"nope">>])),
    ?assertEqual({[other], {error, enotdir}}, erx_erofs:walk(Fs, [<<"small">>, <<"x">>])),
    ?assertEqual({[directory, directory, link], ok},
                 erx_erofs:walk(Fs, [<<"a">>, <<"b">>, <<"up">>, <<"x">>])),
    ?assertEqual({[], {error, enametoolong}}, erx_erofs:walk(Fs, lists:duplicate(257, <<"a">>))),
    ?assertEqual({[], {error, enametoolong}}, erx_erofs:walk(Fs, [binary:copy(<<"a">>, 256)])),
    ?assertEqual({error, enotdir}, erx_erofs:read_file(Fs, [<<"small">>, <<"x">>])),
    ?assertEqual({error, enoent}, erx_erofs:list_dir(Fs, [<<"many">>, <<"entry-9999">>])),
    ?assertEqual({error, enotdir}, erx_erofs:list_dir(Fs, [<<"small">>])),
    ?assertEqual({error, einval}, erx_erofs:pread(Fs, [<<"small">>], -1, 1)).

hard_links_share_an_inode_test() ->
    Fs = mount("compact"),
    {ok, #{inode := Inode, nlink := 2}} = erx_erofs:read_file_info(Fs, [<<"small">>]),
    {ok, #{inode := Inode, nlink := 2}} = erx_erofs:read_file_info(Fs, [<<"small-again">>]).

%% Refusals at mount, each with its diagnostic.

refused(Bytes) ->
    {ok, Image} = open(Bytes),
    erx_erofs:mount(Image, fun(_) -> ok end).

compression_and_chunks_are_refused_naming_their_bits_test() ->
    ?assertEqual({error, enotsup, <<"erofs: block 0: incompatible feature bits 0x1 are not implemented">>},
                 refused(fixture("lz4"))),
    ?assertEqual({error, enotsup, <<"erofs: block 0: incompatible feature bits 0x4 are not implemented">>},
                 refused(fixture("chunked"))).

superblock_test_() ->
    Image = fixture("compact"),
    Patch = fun(At, Byte) -> <<(binary:part(Image, 0, At))/binary, Byte,
                               (binary:part(Image, At + 1, byte_size(Image) - At - 1))/binary>> end,
    [?_assertEqual({error, eio, <<"erofs: block 0: superblock CRC-32C mismatch">>}, refused(Patch(1024 + 64, $x))),
     ?_assertEqual({error, eio, <<"erofs: block 0: superblock CRC-32C mismatch">>}, refused(Patch(4000, 1))),
     ?_assertEqual({error, eio, <<"erofs: block 0: no EROFS magic">>}, refused(Patch(1024, 0))),
     ?_assertEqual({error, enotsup, <<"erofs: block 0: block size 2^14, not 2^12">>}, refused(Patch(1024 + 12, 14))),
     ?_assertEqual({error, eio, <<"erofs: blocks 0+1 failed to read">>}, refused(<<>>))].

%% A block that changes after the mount fails the operation, with a diagnostic, and
%% not its caller.

malformed_blocks_fail_the_operation_test() ->
    Bytes = fixture("compact"),
    Gate = atomics:new(1, []),
    {ok, Image} = open(Bytes, fun(_, Count, Part) ->
                                      case atomics:get(Gate, 1) of
                                          0 -> {ok, Part};
                                          _ -> {ok, binary:copy(<<255>>, Count * ?BLOCK)}
                                      end
                              end),
    {ok, Fs} = erx_erofs:mount(Image, fun(Line) -> self() ! {log, Line} end),
    atomics:put(Gate, 1, 1),
    ?assertEqual({error, eio}, erx_erofs:read_file(Fs, [<<"small">>])),
    <<"erofs: inode 36: unknown format bits 0xFFFF">> = logged(),
    ?assertEqual({[], {error, eio}}, erx_erofs:walk(Fs, [<<"a">>])),
    true = is_binary(logged()).

%% The funnel.

funnel_refuses_what_it_cannot_serve_test() ->
    Bytes = fixture("compact"),
    Blocks = byte_size(Bytes) div ?BLOCK,
    {ok, Image} = open(Bytes),
    {ok, [Block0]} = erx_verity:read(Image, 0, 1),
    ?assertEqual(binary:part(Bytes, 0, ?BLOCK), Block0),
    {ok, All} = erx_verity:read(Image, 0, Blocks),
    ?assertEqual(Bytes, iolist_to_binary(All)),
    {ok, Large} = open(binary:copy(<<0>>, 20 * ?BLOCK)),
    {ok, Sixteen} = erx_verity:read(Large, 4, 16),
    16 = length(Sixteen),
    ?assertEqual({error, eio}, erx_verity:read(Large, 0, 17)),
    ?assertEqual({error, eio}, erx_verity:read(Image, 0, 0)),
    ?assertEqual({error, eio}, erx_verity:read(Image, Blocks, 1)),
    ?assertEqual({error, eio}, erx_verity:read(Image, -1, 1)),
    {ok, Short} = open(Bytes, fun(_, _, Part) -> {ok, binary:part(Part, 0, 100)} end),
    ?assertEqual({error, eio}, erx_verity:read(Short, 0, 1)),
    {ok, Failing} = open(Bytes, fun(_, _, _) -> {error, timeout} end),
    ?assertEqual({error, eio}, erx_verity:read(Failing, 0, 1)),
    {ok, Exiting} = open(Bytes, fun(_, _, _) -> exit(window_down) end),
    ?assertEqual({error, eio}, erx_verity:read(Exiting, 0, 1)).
