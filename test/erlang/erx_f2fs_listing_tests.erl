%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_listing_tests).

-include_lib("eunit/include/eunit.hrl").

%%% Over OTP's file module

%% A tree on the host: a directory a with a file x and its hard link y, an
%% empty directory b inside it, an empty file e, and a symlink s to a/x.
host_tree() ->
    Root = filename:absname("listing-tree-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Root),
    ok = file:make_dir(filename:join(Root, "a")),
    ok = file:make_dir(filename:join([Root, "a", "b"])),
    ok = file:write_file(filename:join([Root, "a", "x"]), <<"hello">>),
    ok = file:change_mode(filename:join([Root, "a", "x"]), 8#640),
    ok = file:make_link(filename:join([Root, "a", "x"]), filename:join([Root, "a", "y"])),
    ok = file:write_file(filename:join(Root, "e"), <<>>),
    ok = file:make_symlink("a/x", filename:join(Root, "s")),
    Root.

a_host_tree_lists_every_name_in_path_order_test() ->
    Listing = erx_f2fs_listing:of_tree(erx_f2fs_listing:file_reader(host_tree())),
    ?assertEqual([[], [<<"a">>], [<<"a">>, <<"b">>], [<<"a">>, <<"x">>],
                  [<<"a">>, <<"y">>], [<<"e">>], [<<"s">>]],
                 [Path || {Path, _} <- Listing]).

each_kind_has_its_attributes_test() ->
    Entries = maps:from_list(erx_f2fs_listing:of_tree(erx_f2fs_listing:file_reader(host_tree()))),
    X = [<<"a">>, <<"x">>],
    Hello = crypto:hash(sha256, <<"hello">>),
    ?assertEqual(#{kind => regular, mode => 8#640, links => 2, size => 5,
                   link_class => [X, [<<"a">>, <<"y">>]], sha256 => Hello},
                 maps:get(X, Entries)),
    ?assertEqual(maps:get(X, Entries), maps:get([<<"a">>, <<"y">>], Entries)),
    ?assertMatch(#{kind := symlink, target := <<"a/x">>, links := 1, size := 3,
                   link_class := [[<<"s">>]]},
                 maps:get([<<"s">>], Entries)),
    ?assertMatch(#{kind := directory}, maps:get([<<"a">>, <<"b">>], Entries)),
    ?assertNot(is_map_key(link_class, maps:get([<<"a">>], Entries))).

the_second_depth_adds_the_owner_and_the_times_test() ->
    Reader = erx_f2fs_listing:file_reader(host_tree()),
    [{[], Shallow} | _] = erx_f2fs_listing:of_tree(Reader),
    [{[], Deep} | _] = erx_f2fs_listing:of_tree(Reader, 2),
    ?assertEqual([], [Key || Key <- [uid, gid, atime, mtime, ctime], is_map_key(Key, Shallow)]),
    ?assertEqual(Shallow, maps:without([uid, gid, atime, mtime, ctime], Deep)),
    ?assertMatch(#{uid := Uid, mtime := Mtime} when is_integer(Uid) andalso is_integer(Mtime),
                 Deep).

%%% Over a reader of a tree held as a map

%% A reader of Tree, a map from each path to {Stat, Contents}: a
%% directory's names, a file's bytes or a symlink's target; or to
%% {error, Reason} for a name the reader cannot state.
map_reader(Tree) ->
    Contents = fun(Path) ->
                       case maps:get(Path, Tree) of
                           {error, _} = Error -> Error;
                           {_Stat, Value} -> {ok, Value}
                       end
               end,
    Sha256 = fun(Path) ->
                     case Contents(Path) of
                         {ok, Bytes} -> {ok, crypto:hash(sha256, Bytes)};
                         {error, _} = Error -> Error
                     end
             end,
    #{list => Contents, sha256 => Sha256, read_link => Contents,
      stat => fun(Path) ->
                      case maps:get(Path, Tree) of
                          {error, _} = Error -> Error;
                          {Stat, _Value} -> {ok, Stat}
                      end
              end}.

stat(Kind, Inode) ->
    #{kind => Kind, mode => 8#755, links => 1, inode => Inode, size => 0,
      uid => 0, gid => 0, atime => 0, mtime => 0, ctime => 0}.

%% A directory reached again by its inode is an error and the walk ends.
a_directory_reached_twice_ends_the_walk_test() ->
    Tree = #{[] => {stat(directory, 1), [<<"loop">>]},
             [<<"loop">>] => {stat(directory, 1), [<<"loop">>]}},
    ?assertMatch([{[], #{kind := directory}}, {[<<"loop">>], {error, directory_reached_twice}}],
                 erx_f2fs_listing:of_tree(map_reader(Tree))).

%% An entry the reader refuses is its error, and nothing beneath it is
%% listed; a file whose bytes fail is its error too.
a_refused_entry_hides_what_lies_beneath_test() ->
    Tree = #{[] => {stat(directory, 1), [<<"bad">>, <<"file">>]},
             [<<"bad">>] => {error, {inode, checksum}},
             [<<"file">>] => {error, eio}},
    ?assertEqual([{[], #{kind => directory, mode => 8#755, links => 1, size => 0}},
                  {[<<"bad">>], {error, {inode, checksum}}},
                  {[<<"file">>], {error, eio}}],
                 erx_f2fs_listing:of_tree(map_reader(Tree))).

%% Devices list their numbers; names sharing an inode share the class of
%% every name found sharing it, in path order, whatever order the reader
%% lists them in.
devices_and_link_classes_test() ->
    Device = (stat(character, 7))#{device => {1, 3}},
    Tree = #{[] => {stat(directory, 1), [<<"z">>, <<"m">>, <<"null">>]},
             [<<"z">>] => {stat(fifo, 5), none},
             [<<"m">>] => {stat(fifo, 5), none},
             [<<"null">>] => {Device, none}},
    Listing = erx_f2fs_listing:of_tree(map_reader(Tree)),
    ?assertMatch({_, #{kind := character, device := {1, 3}, link_class := [[<<"null">>]]}},
                 lists:keyfind([<<"null">>], 1, Listing)),
    ?assertEqual([[[<<"m">>], [<<"z">>]], [[<<"m">>], [<<"z">>]]],
                 [Class || {[Name], #{link_class := Class}} <- Listing,
                           Name =:= <<"m">> orelse Name =:= <<"z">>]).

diff_names_each_entry_that_differs_test() ->
    Left = [{[], #{kind => directory}}, {[<<"a">>], #{size => 1}}, {[<<"b">>], #{size => 2}}],
    Right = [{[], #{kind => directory}}, {[<<"a">>], #{size => 3}}, {[<<"c">>], #{size => 2}}],
    ?assertEqual([{[<<"a">>], #{size => 1}, #{size => 3}},
                  {[<<"b">>], #{size => 2}, absent},
                  {[<<"c">>], absent, #{size => 2}}],
                 erx_f2fs_listing:diff(Left, Right)).

%% A name OTP answers as a string comes back as its bytes in the file name
%% encoding; the name here is UTF-8 and in NFC, which macOS keeps.
a_non_ascii_name_lists_as_its_bytes_test() ->
    Root = host_tree(),
    Name = <<16#c3, 16#a9>>,
    ok = file:write_file(filename:join(Root, Name), <<>>),
    Listing = erx_f2fs_listing:of_tree(erx_f2fs_listing:file_reader(Root)),
    ?assertMatch({_, #{kind := regular}}, lists:keyfind([Name], 1, Listing)).

%% The host's /dev/null decodes to the major and minor the test runner read
%% with Ruby's File::Stat, the host's own major() and minor().
a_host_device_decodes_to_major_and_minor_test() ->
    [Major, Minor] = [list_to_integer(Field) || Field <- string:lexemes(os:getenv("ERX_F2FS_DEV_NULL"), " ")],
    #{stat := Stat} = erx_f2fs_listing:file_reader("/dev"),
    ?assertMatch({ok, #{kind := character, device := {Major, Minor}}}, Stat([<<"null">>])).

%% A file's bytes are hashed chunk by chunk: 256 MiB folded in fresh 1 MiB
%% chunks lists in a process whose memory, shared binaries included, is
%% capped at 4 Mi words (32 MiB on a 64-bit emulator).
a_large_file_hashes_in_bounded_memory_test() ->
    Chunk = binary:copy(<<16#5a>>, 1 bsl 20),
    Chunks = 256,
    Tree = #{[] => {stat(directory, 1), [<<"big">>]},
             [<<"big">>] => {(stat(regular, 2))#{size => Chunks bsl 20}, unused}},
    Fold = fun([<<"big">>], Fun, Acc) ->
                   {ok, lists:foldl(fun(_, A) -> Fun(binary:copy(Chunk), A) end, Acc,
                                    lists:seq(1, Chunks))}
           end,
    Sha256 = fun(Path) -> erx_f2fs_listing:sha256_of(fun(Fun, Acc) -> Fold(Path, Fun, Acc) end) end,
    Reader = (map_reader(Tree))#{sha256 := Sha256},
    Expected = crypto:hash_final(lists:foldl(fun(_, S) -> crypto:hash_update(S, Chunk) end,
                                             crypto:hash_init(sha256), lists:seq(1, Chunks))),
    Self = self(),
    {Pid, Ref} = spawn_opt(fun() -> Self ! {listed, erx_f2fs_listing:of_tree(Reader)} end,
                           [monitor, {max_heap_size, #{size => 4 bsl 20, kill => true,
                                                       error_logger => false,
                                                       include_shared_binaries => true}}]),
    receive {'DOWN', Ref, process, Pid, Reason} -> ?assertEqual(normal, Reason) end,
    receive {listed, Listing} ->
            ?assertMatch({_, #{sha256 := Expected}}, lists:keyfind([<<"big">>], 1, Listing))
    end.

%% The walk goes in path order whatever order a directory lists in, so the
%% later of two paths reaching one directory is the one in error.
the_later_path_to_a_directory_is_reached_twice_test() ->
    Shared = {stat(directory, 2), []},
    Listings = [erx_f2fs_listing:of_tree(map_reader(#{[] => {stat(directory, 1), Names},
                                                       [<<"a">>] => Shared,
                                                       [<<"b">>] => Shared}))
                || Names <- [[<<"a">>, <<"b">>], [<<"b">>, <<"a">>]]],
    ?assertMatch([[{[], _}, {[<<"a">>], #{kind := directory}},
                   {[<<"b">>], {error, directory_reached_twice}}] = Same, Same],
                 Listings).

%% A name a directory lists twice is one entry, duplicate_name, and nothing
%% beneath it is read.
a_name_listed_twice_is_a_duplicate_test() ->
    Tree = #{[] => {stat(directory, 1), [<<"x">>, <<"y">>, <<"x">>]},
             [<<"y">>] => {stat(fifo, 3), none}},
    ?assertMatch([{[], _}, {[<<"x">>], {error, duplicate_name}}, {[<<"y">>], #{kind := fifo}}],
                 erx_f2fs_listing:of_tree(map_reader(Tree))).

%% A name no path can hold is refused before any reader is asked about it:
%% the map reader has no entry for these paths and would fail if asked.
names_no_path_can_hold_are_refused_test() ->
    Bad = [<<>>, <<".">>, <<"..">>, <<"a/b">>, <<"..", "/", "etc">>, <<"n", 0>>],
    Listing = erx_f2fs_listing:of_tree(map_reader(#{[] => {stat(directory, 1), Bad}})),
    ?assertEqual(lists:sort([{[Name], {error, bad_name}} || Name <- Bad]), tl(Listing)).

%% A reader that states no owner or times lists the same at both depths.
owner_and_times_are_optional_test() ->
    Stat = maps:without([uid, gid, atime, mtime, ctime], stat(directory, 1)),
    Reader = map_reader(#{[] => {Stat, []}}),
    ?assertEqual(erx_f2fs_listing:of_tree(Reader), erx_f2fs_listing:of_tree(Reader, 2)).

%% A path one listing holds twice is reported, never hidden by the other.
diff_reports_a_repeated_path_test() ->
    Entry = {[<<"a">>], #{size => 1}},
    ?assertEqual([{[<<"a">>], #{size => 1}, absent}],
                 erx_f2fs_listing:diff([Entry, Entry], [Entry])).

%% A link class is compared over the names both sides state without an
%% error: the entry in error differs, the class of its sibling does not.
diff_cuts_link_classes_to_names_without_errors_test() ->
    X = [<<"x">>],
    Y = [<<"y">>],
    Left = [{X, #{kind => regular, link_class => [X, Y]}},
            {Y, #{kind => regular, link_class => [X, Y]}}],
    Right = [{X, #{kind => regular, link_class => [X]}}, {Y, {error, {inode, checksum}}}],
    ?assertEqual([{Y, #{kind => regular, link_class => [X]}, {error, {inode, checksum}}}],
                 erx_f2fs_listing:diff(Left, Right)).

%% The reader over OTP's file module folds a file in chunks too: a sparse
%% host file of 256 MiB lists under the same cap.
a_sparse_host_file_lists_in_bounded_memory_test() ->
    Root = host_tree(),
    {ok, File} = file:open(filename:join(Root, "sparse"), [write, raw, binary]),
    {ok, _} = file:position(File, 256 bsl 20),
    ok = file:write(File, <<1>>),
    ok = file:close(File),
    Reader = erx_f2fs_listing:file_reader(Root),
    Self = self(),
    {Pid, Ref} = spawn_opt(fun() -> Self ! {listed, erx_f2fs_listing:of_tree(Reader)} end,
                           [monitor, {max_heap_size, #{size => 4 bsl 20, kill => true,
                                                       error_logger => false,
                                                       include_shared_binaries => true}}]),
    receive {'DOWN', Ref, process, Pid, Reason} -> ?assertEqual(normal, Reason) end,
    receive {listed, Listing} ->
            ?assertMatch({_, #{size := 268435457}}, lists:keyfind([<<"sparse">>], 1, Listing))
    end.

%%% Over the Linux oracle guest's record

%% A record as the guest's `record` prints it: seven NUL-terminated fields
%% per name.
record(Entries) ->
    iolist_to_binary([[Field, 0] || Entry <- Entries, Field <- Entry]).

guest_record() ->
    Hello = binary:encode_hex(crypto:hash(sha256, <<"hello">>), lowercase),
    record([[".", "d", "755", "3", "2", "4096", ""],
            ["./a", "d", "700", "2", "3", "4096", ""],
            ["./a/x", "f", "640", "2", "7", "5", ["=", Hello]],
            ["./a/y", "f", "640", "2", "7", "5", ["=", Hello]],
            ["./d", "c", "620", "1", "8", "0", ""],
            ["./e", "f", "4755", "1", "9", "2", "!"],
            ["./s", "l", "777", "1", "10", "3", "=a/x"]]).

a_guest_record_lists_as_its_tree_test() ->
    {ok, Reader} = erx_f2fs_listing:record_reader(guest_record()),
    Entries = maps:from_list(erx_f2fs_listing:of_tree(Reader)),
    X = [<<"a">>, <<"x">>],
    ?assertEqual([[], [<<"a">>], X, [<<"a">>, <<"y">>], [<<"d">>], [<<"e">>], [<<"s">>]],
                 lists:sort(maps:keys(Entries))),
    ?assertEqual(#{kind => regular, mode => 8#640, links => 2, size => 5,
                   link_class => [X, [<<"a">>, <<"y">>]], sha256 => crypto:hash(sha256, <<"hello">>)},
                 maps:get(X, Entries)),
    ?assertEqual(#{kind => directory, mode => 8#755, links => 3, size => 4096}, maps:get([], Entries)),
    ?assertEqual(#{kind => character, mode => 8#620, links => 1, size => 0, link_class => [[<<"d">>]]},
                 maps:get([<<"d">>], Entries)),
    ?assertEqual({error, unreadable}, maps:get([<<"e">>], Entries)),
    ?assertMatch(#{kind := symlink, target := <<"a/x">>}, maps:get([<<"s">>], Entries)).

%% Linux's record and another reader's listing of the same tree compare
%% through diff/2, link classes included: a hard link Linux sees that the
%% other reader does not is a difference.
a_guest_record_compares_link_classes_test() ->
    {ok, Reader} = erx_f2fs_listing:record_reader(guest_record()),
    Linux = erx_f2fs_listing:of_tree(Reader),
    Split = [case Entry of
                 {[<<"a">>, <<"y">>] = Path, Attributes} -> {Path, Attributes#{link_class := [Path]}};
                 {[<<"a">>, <<"x">>] = Path, Attributes} -> {Path, Attributes#{link_class := [Path]}};
                 Other -> Other
             end || Entry <- Linux],
    ?assertEqual([], erx_f2fs_listing:diff(Linux, Linux)),
    ?assertMatch([{[<<"a">>, <<"x">>], _, _}, {[<<"a">>, <<"y">>], _, _}], erx_f2fs_listing:diff(Linux, Split)).

each_malformed_record_is_refused_by_its_rule_test() ->
    Root = [".", "d", "755", "2", "2", "4096", ""],
    File = fun(Path, Content) -> [Path, "f", "644", "1", "5", "0", Content] end,
    Cases = [{partial_entry, <<".", 0, "d", 0>>},
             {partial_entry, binary:part(record([Root]), 0, 14)},
             {no_root, record([])},
             {duplicate_path, record([Root, Root])},
             {bad_path, record([Root, File("a", "!")])},
             {bad_path, record([Root, File("./a//b", "!")])},
             {bad_path, record([Root, File("./..", "!")])},
             {orphan, record([Root, File("./a/b", "!")])},
             {orphan, record([Root, File("./a", "!"), File("./a/b", "!")])},
             {bad_type, record([[".", "x", "755", "2", "2", "4096", ""]])},
             {bad_number, record([[".", "d", "9", "2", "2", "4096", ""]])},
             {bad_number, record([[".", "d", "755", "-1", "2", "4096", ""]])},
             {bad_number, record([[".", "d", "755", "2", "", "4096", ""]])},
             {bad_number, record([[".", "d", "755", "2", "2", lists:duplicate(21, $9), ""]])},
             {bad_content, record([Root, File("./a", "")])},
             {bad_content, record([Root, File("./a", ["=", lists:duplicate(64, $g)])])},
             {bad_content, record([Root, File("./a", "=ab")])},
             {bad_content, record([[".", "d", "755", "2", "2", "4096", "!"]])}],
    [?assertEqual({error, {record, Rule}}, erx_f2fs_listing:record_reader(Record), Record)
     || {Rule, Record} <- Cases].

%% The record is untrusted: every mutation of a valid one, bytes changed,
%% cut or inserted (NULs, slashes and the content marks among them), either
%% is refused by a rule or reads into a reader whose whole listing builds.
a_mutated_record_is_refused_or_lists_test() ->
    Seed = guest_record(),
    State = rand:seed_s(exsss, {1, 2, 3}),
    lists:foldl(fun(_, Random0) ->
                        {Record, Random} = mutate(Seed, Random0),
                        case erx_f2fs_listing:record_reader(Record) of
                            {ok, Reader} -> ?assert(is_list(erx_f2fs_listing:of_tree(Reader)));
                            {error, {record, Rule}} -> ?assert(is_atom(Rule))
                        end,
                        Random
                end, State, lists:seq(1, 4000)).

mutate(Record, Random0) ->
    {Times, Random1} = rand:uniform_s(3, Random0),
    lists:foldl(fun(_, {Bytes, R0}) ->
                        {Kind, R1} = rand:uniform_s(3, R0),
                        {At, R2} = rand:uniform_s(byte_size(Bytes) + 1, R1),
                        {Byte, R3} = rand:uniform_s(256, R2),
                        {Token, R4} = rand:uniform_s(5, R3),
                        Before = binary:part(Bytes, 0, At - 1),
                        After = binary:part(Bytes, At - 1, byte_size(Bytes) - At + 1),
                        Mutated = case Kind of
                                      1 when After =/= <<>> -> <<Before/binary, (Byte - 1), (tail(After))/binary>>;
                                      2 -> Before;
                                      _ -> <<Before/binary, (lists:nth(Token, [<<0>>, <<"/">>, <<"=">>, <<"!">>, <<"./">>]))/binary,
                                             After/binary>>
                                  end,
                        {Mutated, R4}
                end, {Record, Random1}, lists:seq(1, Times)).

tail(<<_, Rest/binary>>) -> Rest.
