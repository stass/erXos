%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the EROFS reader, erx_erofs, and its funnel, erx_verity, over the
%% fixture images tools/erofs_fixtures.rb writes with mkfs.erofs from the tree
%% test/fixtures/erofs/tree.terms declares (ERX_EROFS_FIXTURES names the directory).
-module(erx_erofs_tests).
-include_lib("eunit/include/eunit.hrl").

-export([fixture/1, window/1, window/2, open/1, open/2, expected/0, contents/2, agrees/1]).

-include_lib("kernel/include/file.hrl").

-define(BLOCK, 4096).
-define(SECTOR, 512).
%% How long a RAM window waits for a request before it ends, so the fuzz target's windows
%% do not pile up.
-define(WINDOW_IDLE, 60000).

%% Fixture helpers, which the fuzz target shares.

fixture(Name) ->
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_EROFS_FIXTURES"), Name ++ ".img")),
    Bytes.

%% A RAM window over Bytes: a process that answers gen_server calls as erx_blk_window
%% does, info with its length in sectors and each read of whole blocks with what
%% Serve(FirstBlock, Blocks, Part) makes of the blocks asked for. Anything else, and a
%% read past the bytes, ends it, as a crashed window would.
window(Bytes) -> window(Bytes, fun(_, _, Part) -> {ok, Part} end).

window(Bytes, Serve) -> spawn(fun() -> serve(Bytes, Serve) end).

serve(Bytes, Serve) ->
    receive
        {'$gen_call', From, info} ->
            gen:reply(From, {ok, #{role => slot_a, sectors => byte_size(Bytes) div ?SECTOR}});
        {'$gen_call', From, {read, Sector, Count}} when Sector rem 8 =:= 0, Count rem 8 =:= 0 ->
            Part = binary:part(Bytes, Sector * ?SECTOR, Count * ?SECTOR),
            gen:reply(From, Serve(Sector div 8, Count div 8, Part))
    after ?WINDOW_IDLE ->
        exit(idle)
    end,
    serve(Bytes, Serve).

%% The funnel open on a RAM window over Bytes.
open(Bytes) -> erx_verity:open(window(Bytes), unchecked).

open(Bytes, Serve) -> erx_verity:open(window(Bytes, Serve), unchecked).

expected() ->
    {ok, Terms} = file:consult(filename:join(os:getenv("ERX_EROFS_FIXTURES"), "tree.terms")),
    Terms.

contents(Size, Seed) -> << <<((I * 7 + Seed) band 255)>> || I <- lists:seq(0, Size - 1) >>.

mount(Name) ->
    {ok, Fs} = erx_erofs:mount(window(fixture(Name)), unchecked, fun(Line) -> self() ! {log, Line} end),
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
    erx_erofs:mount(window(Bytes), unchecked, fun(_) -> ok end).

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
    Window = window(Bytes, fun(_, Count, Part) ->
                                      case atomics:get(Gate, 1) of
                                          0 -> {ok, Part};
                                          _ -> {ok, binary:copy(<<255>>, Count * ?BLOCK)}
                                      end
                              end),
    {ok, Fs} = erx_erofs:mount(Window, unchecked, fun(Line) -> self() ! {log, Line} end),
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
    ?assertEqual({error, eio}, erx_verity:read(Exiting, 0, 1)),
    ?assertEqual({error, eio}, erx_verity:read(Exiting, 0, 1)).

%% The funnel opens only a window that answers its length, and only unchecked.

funnel_opens_only_a_window_test() ->
    {Gone, Ref} = spawn_monitor(fun() -> ok end),
    receive {'DOWN', Ref, process, Gone, _} -> ok end,
    ?assertEqual({error, eio}, erx_verity:open(Gone, unchecked)),
    ?assertEqual({error, eio}, erx_verity:open(window(<<>>), {root, <<0:256>>})),
    ?assertEqual({error, eio}, erx_verity:open(not_a_pid, unchecked)),
    Wrong = spawn(fun() -> receive {'$gen_call', From, info} -> gen:reply(From, {ok, #{}}) end end),
    ?assertEqual({error, eio}, erx_verity:open(Wrong, unchecked)),
    ?assertMatch({error, eio, <<"erofs: the window did not answer its length">>},
                 erx_erofs:mount(Gone, unchecked, fun(_) -> ok end)),
    %% A window of 20 blocks and 7 sectors is 20 blocks long.
    {ok, Odd} = open(binary:copy(<<1>>, 20 * ?BLOCK + 7 * ?SECTOR)),
    {ok, _} = erx_verity:read(Odd, 19, 1),
    ?assertEqual({error, eio}, erx_verity:read(Odd, 20, 1)),
    %% The funnel's calls leave nothing in the caller's mailbox.
    ?assertEqual({messages, []}, process_info(self(), messages)).

%% Each block is matched to its request whatever order the window answers in.

funnel_matches_answers_to_requests_test() ->
    Bytes = <<(binary:copy(<<1>>, ?BLOCK))/binary, (binary:copy(<<2>>, ?BLOCK))/binary>>,
    Reversed = spawn(fun() -> reversed(Bytes) end),
    {ok, Image} = erx_verity:open(Reversed, unchecked),
    ?assertEqual({ok, [binary:part(Bytes, 0, ?BLOCK), binary:part(Bytes, ?BLOCK, ?BLOCK)]},
                 erx_verity:read(Image, 0, 2)).

%% A window that answers info, then takes two reads and answers the second first.
reversed(Bytes) ->
    receive {'$gen_call', Info, info} -> gen:reply(Info, {ok, #{sectors => byte_size(Bytes) div ?SECTOR}}) end,
    [{First, S1}, {Second, S2}] = [receive {'$gen_call', From, {read, S, 8}} -> {From, S} end || _ <- [1, 2]],
    gen:reply(Second, {ok, binary:part(Bytes, S2 * ?SECTOR, ?BLOCK)}),
    gen:reply(First, {ok, binary:part(Bytes, S1 * ?SECTOR, ?BLOCK)}).

%% An open file of an image: what file does with it.

open_file_reads_as_stock_test() ->
    Fs = mount("compact"),
    Big = contents(12388, 3),
    {ok, Fd} = erx_erofs_file:open(Fs, [<<"big">>], [read, binary]),
    ?assertEqual({ok, binary:part(Big, 0, 5000)}, file:read(Fd, 5000)),
    ?assertEqual({ok, binary:part(Big, 5000, 7388)}, file:read(Fd, 100000)),
    ?assertEqual(eof, file:read(Fd, 1)),
    ?assertEqual({ok, 12388}, file:position(Fd, eof)),
    ?assertEqual({ok, 12000}, file:position(Fd, {cur, -388})),
    ?assertEqual({ok, binary:part(Big, 12000, 388)}, file:read(Fd, 1000)),
    ?assertEqual({error, einval}, file:position(Fd, {bof, -1})),
    ?assertEqual({ok, binary:part(Big, 4090, 10)}, file:pread(Fd, 4090, 10)),
    ?assertEqual(eof, file:pread(Fd, 12388, 1)),
    ?assertEqual({error, einval}, file:pread(Fd, -1, 1)),
    ?assertEqual({ok, [binary:part(Big, 0, 2), eof]}, file:pread(Fd, [{0, 2}, {20000, 2}])),
    {ok, #file_info{type = regular, size = 12388, access = read}} = file:read_file_info(Fd, [{time, posix}]),
    ?assertEqual({error, ebadf}, file:write(Fd, <<"x">>)),
    ?assertEqual({error, ebadf}, file:pwrite(Fd, 0, <<"x">>)),
    ?assertEqual({error, einval}, file:truncate(Fd)),
    ?assertEqual({ok, binary:part(Big, 0, 2)}, file:pread(Fd, 0, 2)),
    Self = self(),
    spawn(fun() -> Self ! {other, try file:read(Fd, 1) catch error:Reason -> Reason end} end),
    receive {other, Other} -> ?assertEqual(not_on_controlling_process, Other) end,
    ?assertEqual(ok, file:close(Fd)),
    ?assertEqual({error, einval}, file:close(Fd)),
    ?assertEqual({error, einval}, file:read(Fd, 1)).

open_file_reads_lines_test() ->
    Fs = mount("compact"),
    %% The file holds a "\n" every 256 bytes, so its lines cross blocks and reads.
    {ok, Fd} = erx_erofs_file:open(Fs, [<<"big">>], [read]),
    Big = contents(12388, 3),
    Read = read_lines(Fd, []),
    ?assertEqual(Big, iolist_to_binary(Read)),
    Breaks = length(binary:matches(Big, <<"\n">>)),
    ?assertEqual(Breaks + 1, length(Read)),
    ?assertEqual(eof, file:read_line(Fd)),
    ok = file:close(Fd).

read_lines(Fd, Lines) ->
    case file:read_line(Fd) of
        {ok, Line} -> read_lines(Fd, [Line | Lines]);
        eof -> lists:reverse(Lines)
    end.

open_file_refusals_test() ->
    Fs = mount("compact"),
    ?assertEqual({error, eisdir}, erx_erofs_file:open(Fs, [<<"a">>], [read])),
    ?assertEqual({error, enotsup}, erx_erofs_file:open(Fs, [<<"a">>], [read, directory])),
    ?assertEqual({error, enotdir}, erx_erofs_file:open(Fs, [<<"small">>], [read, directory])),
    ?assertEqual({error, enoent}, erx_erofs_file:open(Fs, [<<"nope">>], [read])),
    ?assertEqual({error, enotdir}, erx_erofs_file:open(Fs, [<<"small">>, <<"x">>], [read])),
    #file_info{type = symlink, access = undefined} = erx_erofs:file_info(Fs, [<<"to-small">>]),
    #file_info{type = directory, access = read, mode = Mode} = erx_erofs:file_info(Fs, [<<"a">>]),
    ?assertEqual(8#040000, Mode band 8#170000).
