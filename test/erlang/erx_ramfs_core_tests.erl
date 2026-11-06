%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_ramfs_core, run on plain tree values: for each row of the
%% callback table in docs/design-tmp.md, each error with the condition that causes
%% it and the tree unchanged after it, and each success with its reply and
%% check/1, which every successful step here passes through. test/host/
%% erx_ramfs_core_test.rb also runs them against seeded faults of the module,
%% each of which one case named there must catch.

-module(erx_ramfs_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ROOT, 1).
-define(BORN, 1000).
-define(NOW, 2000).
-define(CAP, (1 bsl 20)).
-define(MAX_SIZE, ((1 bsl 63) - 1)).
-define(CHUNK, 4096).

%% ---------------------------------------------------------------------------
%% Fixtures
%% ---------------------------------------------------------------------------

tree() -> tree(?CAP).

tree(Cap) -> erx_ramfs_core:new(Cap, ?ROOT, ?BORN).

%% A fresh stamp per step, as the domain's counter gives one.
stamp() -> 100 + erlang:unique_integer([positive, monotonic]).

step(Request, Tree) ->
    erx_ramfs_core:step(Request, stamp(), ?NOW, Tree).

%% A step that succeeds and leaves every invariant holding.
ok_step(Request, Tree) ->
    {Reply, Tree1} = step(Request, Tree),
    ?assertNotMatch({error, _}, Reply),
    ?assertEqual(ok, erx_ramfs_core:check(Tree1)),
    {Reply, Tree1}.

%% A step refused with Error and nothing changed.
refused(Error, Request, Tree) ->
    ?assertEqual({{error, Error}, Tree}, step(Request, Tree)).

mkdir(Dir, Name, Tree) -> mkdir(Dir, Name, 8#755, Tree).

mkdir(Dir, Name, Mode, Tree) ->
    {{ok, Ino, {directory, _, Ino}}, Tree1} =
        ok_step({make, Dir, Name, {directory, Mode}}, Tree),
    {Ino, Tree1}.

%% A new file, open for reading and writing.
create(Dir, Name, Tree) -> create(Dir, Name, 8#644, Tree).

create(Dir, Name, Mode, Tree) ->
    {{ok, Ino, {file, _, Ino}, Handle}, Tree1} =
        ok_step({make, Dir, Name, {file, Mode, {read_write, []}}}, Tree),
    {Ino, Handle, Tree1}.

%% A closed file holding Data.
file(Dir, Name, Data, Tree) ->
    {Ino, Handle, Tree1} = create(Dir, Name, Tree),
    Tree2 = write(Handle, 0, Data, Tree1),
    {Ino, clunk(Handle, Tree2)}.

symlink(Dir, Name, Text, Tree) ->
    {{ok, Ino, {symlink, _, Ino}}, Tree1} =
        ok_step({make, Dir, Name, {symlink, Text}}, Tree),
    {Ino, Tree1}.

open(Ino, Flags, Tree) ->
    {{ok, Handle}, Tree1} = ok_step({open, Ino, Flags}, Tree),
    {Handle, Tree1}.

write(Handle, Offset, Data, Tree) ->
    {{ok, _Count, _At}, Tree1} = ok_step({write, Handle, Offset, Data}, Tree),
    Tree1.

read(Handle, Offset, Count, Tree) ->
    {{ok, Bytes}, Tree} = step({read, Handle, Offset, Count}, Tree),
    Bytes.

clunk(Handle, Tree) ->
    {ok, Tree1} = ok_step({clunk, Handle}, Tree),
    Tree1.

attr(Ino, Tree) ->
    {{ok, Attr}, Tree} = step({getattr, Ino}, Tree),
    Attr.

attr(Field, Ino, Tree) -> maps:get(Field, attr(Ino, Tree)).

walk(Dir, Name, Tree) ->
    {{ok, Ino, _Qid}, _Held} = step({walk, Dir, Name, holder}, Tree),
    Ino.

%% The names of a directory, by one listing from the start.
names(Dir, Tree) ->
    {Handle, Tree1} = open(Dir, {read, []}, Tree),
    {{ok, Page}, _} = step({readdir, Handle, 0, 256}, Tree1),
    [Name || {_Qid, _Seq, Name} <- Page].

held(Tree) -> erx_ramfs_core:held(Tree).

%% ---------------------------------------------------------------------------
%% A new tree
%% ---------------------------------------------------------------------------

new_tree_is_an_empty_root_test() ->
    Tree = tree(),
    ?assertEqual(ok, erx_ramfs_core:check(Tree)),
    ?assertEqual(0, held(Tree)),
    ?assertMatch(#{kind := directory, mode := 8#1777, nlink := 2, size := 0,
                   ino := ?ROOT, data_version := ?ROOT}, attr(?ROOT, Tree)).

zero_cap_refuses_every_creation_test() ->
    Tree = tree(0),
    refused(enospc, {make, ?ROOT, <<"f">>, {file, 8#644, {write, []}}}, Tree),
    refused(enospc, {make, ?ROOT, <<"d">>, {directory, 8#755}}, Tree),
    refused(enospc, {make, ?ROOT, <<"l">>, {symlink, <<"t">>}}, Tree).

%% ---------------------------------------------------------------------------
%% walk
%% ---------------------------------------------------------------------------

walk_finds_the_named_node_with_its_qid_test() ->
    {Dir, Tree} = mkdir(?ROOT, <<"d">>, tree()),
    ?assertMatch({{ok, Dir, {directory, _, Dir}}, _},
                 step({walk, ?ROOT, <<"d">>, holder}, Tree)).

walk_refusals_test() ->
    {Dir, Tree1} = mkdir(?ROOT, <<"d">>, tree()),
    {File, Tree2} = file(?ROOT, <<"f">>, <<>>, Tree1),
    {_, Tree3} = mkdir(?ROOT, <<"shut">>, 8#600, Tree2),
    Shut = walk(?ROOT, <<"shut">>, Tree3),
    refused(enoent, {walk, ?ROOT, <<"missing">>, holder}, Tree3),
    refused(enoent, {walk, 999999, <<"x">>, holder}, Tree3),
    refused(enotdir, {walk, File, <<"x">>, holder}, Tree3),
    refused(eacces, {walk, Shut, <<"x">>, holder}, Tree3),
    refused(enametoolong, {walk, Dir, binary:copy(<<"n">>, 256), holder}, Tree3).

%% A walk holds what it found: a rename over the name leaves the old node with no
%% name and its charge, and the holder's forget frees it and returns the charge.
walk_holds_a_node_until_its_holder_forgets_it_test() ->
    {_, Tree1} = file(?ROOT, <<"a">>, <<"new">>, tree()),
    {Old, Tree2} = file(?ROOT, <<"b">>, binary:copy(<<1>>, 5000), Tree1),
    {{ok, Old, _}, Tree3} = ok_step({walk, ?ROOT, <<"b">>, g1}, Tree2),
    {ok, Tree4} = ok_step({rename, ?ROOT, <<"a">>, ?ROOT, <<"b">>}, Tree3),
    ?assertEqual(0, attr(nlink, Old, Tree4)),
    ?assertEqual(5000, attr(size, Old, Tree4)),
    refused(enoent, {open, Old, {read, []}}, Tree4),
    {ok, Tree5} = ok_step({forget, Old, g1}, Tree4),
    refused(enoent, {getattr, Old}, Tree5),
    ?assert(erx_ramfs_core:held(Tree5) < erx_ramfs_core:held(Tree4)),
    %% A second forget, or one of a holder that holds nothing, changes nothing.
    ?assertEqual({ok, Tree5}, step({forget, Old, g1}, Tree5)),
    ?assertEqual({ok, Tree5}, step({forget, Old, g2}, Tree5)).

%% Holds are kept per holder: walking twice holds once, and every holder must let go.
a_node_lives_until_every_holder_lets_go_test() ->
    {File, Tree1} = file(?ROOT, <<"f">>, <<"x">>, tree()),
    {_, Tree2} = ok_step({walk, ?ROOT, <<"f">>, g1}, Tree1),
    {_, Tree3} = ok_step({walk, ?ROOT, <<"f">>, g1}, Tree2),
    {_, Tree4} = ok_step({walk, ?ROOT, <<"f">>, g2}, Tree3),
    {ok, Tree5} = ok_step({unlink, ?ROOT, <<"f">>, file}, Tree4),
    {ok, Tree6} = ok_step({forget, File, g1}, Tree5),
    ?assertEqual(0, attr(nlink, File, Tree6)),
    {ok, Tree7} = ok_step({forget_holder, g2}, Tree6),
    refused(enoent, {getattr, File}, Tree7),
    ?assertEqual(erx_ramfs_core:held(tree()), erx_ramfs_core:held(Tree7)).

%% A removed directory finds nothing, even while a holder keeps it.
a_removed_directory_finds_nothing_test() ->
    {Dir, Tree1} = mkdir(?ROOT, <<"d">>, tree()),
    {_, Tree2} = ok_step({walk, ?ROOT, <<"d">>, g1}, Tree1),
    {ok, Tree3} = ok_step({unlink, ?ROOT, <<"d">>, directory}, Tree2),
    ?assertEqual(0, attr(nlink, Dir, Tree3)),
    refused(enoent, {walk, Dir, <<"x">>, g1}, Tree3),
    refused(enoent, {make, Dir, <<"x">>, {directory, 8#755}}, Tree3),
    {ok, Tree4} = ok_step({forget, Dir, g1}, Tree3),
    refused(enoent, {getattr, Dir}, Tree4).

%% ---------------------------------------------------------------------------
%% getattr
%% ---------------------------------------------------------------------------

getattr_reports_links_size_and_blocks_test() ->
    {File, Tree} = file(?ROOT, <<"f">>, <<1, 2, 3>>, tree()),
    ?assertMatch(#{kind := file, mode := 8#644, nlink := 1, size := 3,
                   blocks := 8, ino := File, mtime := ?NOW}, attr(File, Tree)).

getattr_of_a_node_gone_is_enoent_test() ->
    {File, Tree1} = file(?ROOT, <<"f">>, <<>>, tree()),
    {ok, Tree2} = ok_step({unlink, ?ROOT, <<"f">>, {node, File}}, Tree1),
    refused(enoent, {getattr, File}, Tree2).

%% ---------------------------------------------------------------------------
%% open
%% ---------------------------------------------------------------------------

open_with_trunc_frees_every_chunk_test() ->
    {File, Tree1} = file(?ROOT, <<"f">>, binary:copy(<<7>>, 3 * ?CHUNK), tree()),
    Before = held(Tree1),
    {_Handle, Tree2} = open(File, {write, [trunc]}, Tree1),
    ?assertEqual(Before - 3 * ?CHUNK, held(Tree2)),
    ?assertMatch(#{size := 0, blocks := 0, mtime := ?NOW}, attr(File, Tree2)).

open_refusals_test() ->
    {Dir, Tree1} = mkdir(?ROOT, <<"d">>, tree()),
    {File, Tree2} = file(?ROOT, <<"f">>, <<>>, Tree1),
    {Link, Tree3} = symlink(?ROOT, <<"l">>, <<"f">>, Tree2),
    {ok, Tree4} = ok_step({setattr, {node, File}, #{mode => 8#400}}, Tree3),
    refused(enoent, {open, 999999, {read, []}}, Tree4),
    refused(eisdir, {open, Dir, {write, []}}, Tree4),
    refused(eisdir, {open, Dir, {read, [trunc]}}, Tree4),
    refused(eloop, {open, Link, {read, []}}, Tree4),
    refused(enotdir, {open, File, {read, [directory]}}, Tree4),
    refused(eacces, {open, File, {write, []}}, Tree4),
    refused(eacces, {open, File, {read, [trunc]}}, Tree4),
    refused(einval, {open, File, {sideways, []}}, Tree4),
    refused(einval, {open, File, {read, [trunc | append]}}, Tree4).

%% ---------------------------------------------------------------------------
%% make of a file (lcreate)
%% ---------------------------------------------------------------------------

make_file_charges_a_node_and_a_name_test() ->
    {File, _Handle, Tree} = create(?ROOT, <<"abc">>, tree()),
    ?assertEqual(256 + 64 + 3, held(Tree)),
    ?assertMatch(#{nlink := 1, size := 0, data_version := File}, attr(File, Tree)),
    ?assertMatch(#{mtime := ?NOW, data_version := File}, attr(?ROOT, Tree)).

make_file_takes_the_mode_it_is_given_test() ->
    {File, _Handle, Tree} = create(?ROOT, <<"f">>, 8#640, tree()),
    ?assertEqual(8#640, attr(mode, File, Tree)).

%% Opened on creation whatever the mode, as Linux opens a file it just made.
make_file_opens_a_new_file_whatever_its_mode_test() ->
    {{ok, File, _, {File, read_write, false}}, _} =
        ok_step({make, ?ROOT, <<"f">>, {file, 8#000, {read_write, []}}}, tree()).

make_file_without_excl_opens_the_existing_file_test() ->
    {File, Tree1} = file(?ROOT, <<"f">>, <<"data">>, tree()),
    {Reply, Tree2} =
        ok_step({make, ?ROOT, <<"f">>, {file, 8#600, {write, [trunc, append]}}},
                Tree1),
    ?assertMatch({ok, File, {file, _, File}, {File, write, true}}, Reply),
    ?assertMatch(#{size := 0, mode := 8#644}, attr(File, Tree2)).

make_file_refusals_test() ->
    {_Dir, Tree1} = mkdir(?ROOT, <<"d">>, tree()),
    {_File, Tree2} = file(?ROOT, <<"f">>, <<>>, Tree1),
    {_Link, Tree3} = symlink(?ROOT, <<"dangling">>, <<"nowhere">>, Tree2),
    {Gone, Tree4} = mkdir(?ROOT, <<"gone">>, Tree3),
    {_GoneHandle, Tree5} = open(Gone, {read, []}, Tree4),
    {ok, Tree6} = ok_step({unlink, ?ROOT, <<"gone">>, directory}, Tree5),
    {Shut, Tree7} = mkdir(?ROOT, <<"shut">>, 8#500, Tree6),
    Make = fun(Dir, Name, Options) ->
                   {make, Dir, Name, {file, 8#644, {read_write, Options}}}
           end,
    refused(eexist, Make(?ROOT, <<"f">>, [excl]), Tree7),
    refused(eexist, Make(?ROOT, <<"dangling">>, [excl]), Tree7),
    refused(eloop, Make(?ROOT, <<"dangling">>, []), Tree7),
    refused(eisdir, Make(?ROOT, <<"d">>, []), Tree7),
    refused(enoent, Make(Gone, <<"new">>, []), Tree7),
    refused(eacces, Make(Shut, <<"new">>, []), Tree7),
    refused(einval, Make(?ROOT, <<"new">>, [directory]), Tree7),
    refused(einval, Make(?ROOT, <<"a/b">>, []), Tree7),
    refused(enoent, Make(?ROOT, <<>>, []), Tree7),
    refused(enospc, Make(?ROOT, <<"new">>, []), tree(256 + 64 + 2)),
    ?assertMatch({{ok, _, _, _}, _},
                 step(Make(?ROOT, <<"new">>, []), tree(256 + 64 + 3))).

%% A repeated stamp would overwrite a node; the step refuses it instead.
make_with_a_used_stamp_is_eio_test() ->
    Tree = tree(),
    ?assertEqual({{error, eio}, Tree},
                 erx_ramfs_core:step({make, ?ROOT, <<"d">>, {directory, 8#755}},
                                     ?ROOT, ?NOW, Tree)).

%% ---------------------------------------------------------------------------
%% make of a directory
%% ---------------------------------------------------------------------------

make_directory_links_its_dotdot_to_the_parent_test() ->
    {Dir, Tree} = mkdir(?ROOT, <<"d">>, tree()),
    ?assertMatch(#{nlink := 2, mode := 8#755}, attr(Dir, Tree)),
    ?assertEqual(3, attr(nlink, ?ROOT, Tree)).

make_directory_refusals_test() ->
    {Gone, Tree1} = mkdir(?ROOT, <<"gone">>, tree()),
    {_Handle, Tree2} = open(Gone, {read, []}, Tree1),
    {ok, Tree3} = ok_step({unlink, ?ROOT, <<"gone">>, {node, Gone}}, Tree2),
    {Shut, Tree4} = mkdir(?ROOT, <<"shut">>, 8#500, Tree3),
    refused(eexist, {make, ?ROOT, <<"shut">>, {directory, 8#755}}, Tree4),
    refused(enoent, {make, Gone, <<"x">>, {directory, 8#755}}, Tree4),
    refused(eacces, {make, Shut, <<"x">>, {directory, 8#755}}, Tree4),
    refused(enospc, {make, ?ROOT, <<"x">>, {directory, 8#755}}, tree(100)).

%% ---------------------------------------------------------------------------
%% make of a symbolic link
%% ---------------------------------------------------------------------------

make_symlink_charges_its_text_test() ->
    Text = binary:copy(<<"t">>, 4095),
    {Link, Tree} = symlink(?ROOT, <<"l">>, Text, tree()),
    ?assertEqual(256 + 64 + 1 + 4095, held(Tree)),
    ?assertMatch(#{kind := symlink, mode := 8#777, size := 4095}, attr(Link, Tree)),
    ?assertEqual({{ok, Text}, Tree}, step({readlink, Link}, Tree)).

make_symlink_refusals_test() ->
    {_, Tree} = file(?ROOT, <<"f">>, <<>>, tree()),
    Make = fun(Name, Text) -> {make, ?ROOT, Name, {symlink, Text}} end,
    refused(enoent, Make(<<"l">>, <<>>), Tree),
    refused(enametoolong, Make(<<"l">>, binary:copy(<<"t">>, 4096)), Tree),
    refused(einval, Make(<<"l">>, <<"a", 0, "b">>), Tree),
    refused(eexist, Make(<<"f">>, <<"t">>), Tree),
    refused(enospc, Make(<<"l">>, <<"tt">>), tree(256 + 64 + 1 + 1)).

%% ---------------------------------------------------------------------------
%% make of a hard link, and of a device node
%% ---------------------------------------------------------------------------

make_link_adds_a_name_test() ->
    {File, Tree1} = file(?ROOT, <<"f">>, <<>>, tree()),
    Held = held(Tree1),
    {Reply, Tree2} = ok_step({make, ?ROOT, <<"g">>, {link, File}}, Tree1),
    ?assertMatch({ok, File, {file, _, File}}, Reply),
    ?assertEqual(2, attr(nlink, File, Tree2)),
    ?assertEqual(Held + 64 + 1, held(Tree2)).

make_link_refusals_test() ->
    {Dir, Tree1} = mkdir(?ROOT, <<"d">>, tree()),
    {File, _Handle, Tree2} = create(?ROOT, <<"open">>, Tree1),
    {ok, Tree3} = ok_step({unlink, ?ROOT, <<"open">>, file}, Tree2),
    {Kept, Tree4} = file(?ROOT, <<"kept">>, <<>>, Tree3),
    {Shut, Tree5} = mkdir(?ROOT, <<"shut">>, 8#500, Tree4),
    refused(eperm, {make, ?ROOT, <<"x">>, {link, Dir}}, Tree5),
    refused(enoent, {make, ?ROOT, <<"x">>, {link, 999999}}, Tree5),
    refused(enoent, {make, ?ROOT, <<"x">>, {link, File}}, Tree5),
    refused(eexist, {make, ?ROOT, <<"kept">>, {link, Kept}}, Tree5),
    refused(eacces, {make, Shut, <<"x">>, {link, Kept}}, Tree5),
    {Small, Tree6} = file(?ROOT, <<"k">>, <<>>, tree(256 + 65 + 64)),
    refused(enospc, {make, ?ROOT, <<"x">>, {link, Small}}, Tree6).

make_device_node_is_eperm_test() ->
    refused(eperm, {make, ?ROOT, <<"n">>, {node, 8#644, 1, 3}}, tree()).

%% ---------------------------------------------------------------------------
%% read
%% ---------------------------------------------------------------------------

read_returns_holes_as_zeros_and_stops_at_the_size_test() ->
    {File, Handle, Tree1} = create(?ROOT, <<"f">>, tree()),
    Tree2 = write(Handle, 2 * ?CHUNK, <<"end">>, Tree1),
    ?assertEqual(2 * ?CHUNK + 3, attr(size, File, Tree2)),
    ?assertEqual(<<0:(4 * 8), "end">>, read(Handle, 2 * ?CHUNK - 4, 100, Tree2)),
    ?assertEqual(<<>>, read(Handle, 2 * ?CHUNK + 3, 10, Tree2)),
    ?assertEqual(<<>>, read(Handle, ?MAX_SIZE, 10, Tree2)),
    ?assertEqual(65536, byte_size(read(Handle, 0, 1 bsl 40,
                                       write(Handle, 70000, <<1>>, Tree2)))).

read_of_one_whole_chunk_returns_the_stored_chunk_test() ->
    Chunk = binary:copy(<<5>>, ?CHUNK),
    {File, Tree1} = file(?ROOT, <<"f">>, Chunk, tree()),
    {Handle, Tree2} = open(File, {read, []}, Tree1),
    Bytes = read(Handle, 0, ?CHUNK, Tree2),
    ?assertEqual(Chunk, Bytes),
    ?assertEqual(?CHUNK, binary:referenced_byte_size(Bytes)).

read_refusals_test() ->
    {_File, Handle, Tree1} = create(?ROOT, <<"f">>, tree()),
    {Writer, Tree2} = open(walk(?ROOT, <<"f">>, Tree1), {write, []}, Tree1),
    {Dir, Tree3} = mkdir(?ROOT, <<"d">>, Tree2),
    {DirHandle, Tree4} = open(Dir, {read, []}, Tree3),
    refused(ebadf, {read, Writer, 0, 1}, Tree4),
    refused(eisdir, {read, DirHandle, 0, 1}, Tree4),
    refused(einval, {read, Handle, -1, 1}, Tree4),
    refused(einval, {read, Handle, 0, -1}, Tree4),
    refused(ebadf, {read, not_a_handle, 0, 1}, Tree4).

%% ---------------------------------------------------------------------------
%% write
%% ---------------------------------------------------------------------------

write_extends_the_file_and_answers_where_it_wrote_test() ->
    {File, Handle, Tree1} = create(?ROOT, <<"f">>, tree()),
    {Reply, Tree2} = ok_step({write, Handle, 10, <<"abc">>}, Tree1),
    ?assertEqual({ok, 3, 10}, Reply),
    ?assertMatch(#{size := 13, mtime := ?NOW}, attr(File, Tree2)),
    ?assertEqual(<<0:80, "abc">>, read(Handle, 0, 100, Tree2)).

write_through_an_append_handle_lands_at_the_end_test() ->
    {File, Tree1} = file(?ROOT, <<"f">>, <<"head">>, tree()),
    {Appender, Tree2} = open(File, {write, [append]}, Tree1),
    {Reply, Tree3} = ok_step({write, Appender, 0, <<"tail">>}, Tree2),
    ?assertEqual({ok, 4, 4}, Reply),
    {Reader, Tree4} = open(File, {read, []}, Tree3),
    ?assertEqual(<<"headtail">>, read(Reader, 0, 100, Tree4)).

overwrite_costs_nothing_test() ->
    {_File, Handle, Tree1} = create(?ROOT, <<"f">>, tree()),
    Tree2 = write(Handle, 0, binary:copy(<<1>>, 2 * ?CHUNK), Tree1),
    Held = held(Tree2),
    Tree3 = write(Handle, 100, binary:copy(<<2>>, ?CHUNK), Tree2),
    ?assertEqual(Held, held(Tree3)).

write_far_past_the_end_costs_one_chunk_test() ->
    {File, Handle, Tree1} = create(?ROOT, <<"f">>, tree()),
    Held = held(Tree1),
    Tree2 = write(Handle, ?MAX_SIZE - 1, <<9>>, Tree1),
    ?assertEqual(Held + ?CHUNK, held(Tree2)),
    ?assertEqual(?MAX_SIZE, attr(size, File, Tree2)).

%% Linux's limit: at or past the largest size EFBIG; a write crossing it is
%% cut short there.
write_at_the_largest_size_test() ->
    {_File, Handle, Tree1} = create(?ROOT, <<"f">>, tree()),
    refused(efbig, {write, Handle, ?MAX_SIZE, <<1>>}, Tree1),
    {Reply, _} = ok_step({write, Handle, ?MAX_SIZE - 2, <<"abcd">>}, Tree1),
    ?assertEqual({ok, 2, ?MAX_SIZE - 2}, Reply).

write_of_no_bytes_changes_nothing_test() ->
    {_File, Handle, Tree} = create(?ROOT, <<"f">>, tree()),
    ?assertEqual({{ok, 0, ?MAX_SIZE}, Tree}, step({write, Handle, ?MAX_SIZE, <<>>}, Tree)).

write_past_the_cap_writes_nothing_test() ->
    {File, Handle, Tree1} = create(?ROOT, <<"f">>, tree(256 + 65 + ?CHUNK)),
    Tree2 = write(Handle, 0, <<"x">>, Tree1),
    refused(enospc, {write, Handle, ?CHUNK - 1, <<"yz">>}, Tree2),
    ?assertEqual(1, attr(size, File, Tree2)).

write_refusals_test() ->
    {File, Handle, Tree1} = create(?ROOT, <<"f">>, tree()),
    {Reader, Tree2} = open(File, {read, []}, Tree1),
    refused(ebadf, {write, Reader, 0, <<"x">>}, Tree2),
    refused(einval, {write, Handle, -1, <<"x">>}, Tree2),
    refused(einval, {write, Handle, 0, not_a_binary}, Tree2).

%% ---------------------------------------------------------------------------
%% readdir
%% ---------------------------------------------------------------------------

readdir_lists_in_creation_order_test() ->
    Tree = lists:foldl(fun(Name, T) -> element(2, file(?ROOT, Name, <<>>, T)) end,
                       tree(), [<<"c">>, <<"a">>, <<"b">>]),
    ?assertEqual([<<"c">>, <<"a">>, <<"b">>], names(?ROOT, Tree)).

%% Resumed after its first page, the listing neither repeats nor skips an
%% entry that stayed, whatever was removed and added between the pages.
readdir_resumes_without_repeating_or_skipping_test() ->
    Tree1 = lists:foldl(fun(Name, T) -> element(2, file(?ROOT, Name, <<>>, T)) end,
                        tree(), [<<"a">>, <<"b">>, <<"c">>, <<"d">>]),
    {Handle, Tree2} = open(?ROOT, {read, []}, Tree1),
    {{ok, [_, {_, Offset, <<"b">>}]}, _} = step({readdir, Handle, 0, 2}, Tree2),
    {ok, Tree3} = ok_step({unlink, ?ROOT, <<"a">>, file}, Tree2),
    {ok, Tree4} = ok_step({unlink, ?ROOT, <<"c">>, file}, Tree3),
    {_, Tree5} = file(?ROOT, <<"e">>, <<>>, Tree4),
    {{ok, Page}, _} = step({readdir, Handle, Offset, 256}, Tree5),
    ?assertEqual([<<"d">>, <<"e">>], [Name || {_, _, Name} <- Page]).

rename_gives_the_entry_a_new_sequence_number_test() ->
    Tree1 = lists:foldl(fun(Name, T) -> element(2, file(?ROOT, Name, <<>>, T)) end,
                        tree(), [<<"a">>, <<"b">>]),
    {ok, Tree2} = ok_step({rename, ?ROOT, <<"a">>, ?ROOT, <<"c">>}, Tree1),
    ?assertEqual([<<"b">>, <<"c">>], names(?ROOT, Tree2)).

readdir_refusals_test() ->
    {_File, Handle, Tree1} = create(?ROOT, <<"f">>, tree()),
    {DirHandle, Tree2} = open(?ROOT, {read, []}, Tree1),
    refused(enotdir, {readdir, Handle, 0, 10}, Tree2),
    refused(ebadf, {readdir, {?ROOT, write, false}, 0, 10}, Tree2),
    refused(einval, {readdir, DirHandle, -1, 10}, Tree2),
    refused(einval, {readdir, DirHandle, 0, 0}, Tree2).

%% ---------------------------------------------------------------------------
%% readlink
%% ---------------------------------------------------------------------------

readlink_refusals_test() ->
    {File, Tree} = file(?ROOT, <<"f">>, <<>>, tree()),
    refused(einval, {readlink, File}, Tree),
    refused(enoent, {readlink, 999999}, Tree).

%% ---------------------------------------------------------------------------
%% setattr
%% ---------------------------------------------------------------------------

setattr_changes_mode_and_times_test() ->
    {File, Tree1} = file(?ROOT, <<"f">>, <<"x">>, tree()),
    Version = attr(data_version, File, Tree1),
    {ok, Tree2} = ok_step({setattr, {node, File},
                           #{mode => 8#600, atime => 5, mtime => now}}, Tree1),
    ?assertMatch(#{mode := 8#600, atime := 5, mtime := ?NOW, ctime := ?NOW,
                   data_version := Version}, attr(File, Tree2)).

setattr_to_owner_zero_changes_only_ctime_test() ->
    {File, Tree1} = file(?ROOT, <<"f">>, <<"x">>, tree()),
    {ok, Tree2} = ok_step({setattr, {node, File}, #{uid => 0, gid => 0}}, Tree1),
    ?assertEqual(maps:remove(ctime, attr(File, Tree1)),
                 maps:remove(ctime, attr(File, Tree2))).

setattr_size_frees_chunks_and_zeroes_the_tail_test() ->
    {File, Handle, Tree1} = create(?ROOT, <<"f">>, tree()),
    Tree2 = write(Handle, 0, binary:copy(<<"y">>, 3 * ?CHUNK), Tree1),
    Held = held(Tree2),
    {ok, Tree3} = ok_step({setattr, {open, Handle}, #{size => ?CHUNK + 10}}, Tree2),
    ?assertEqual(Held - ?CHUNK, held(Tree3)),
    {ok, Tree4} = ok_step({setattr, {node, File}, #{size => 2 * ?CHUNK}}, Tree3),
    ?assertEqual(<<(binary:copy(<<"y">>, 10))/binary, 0:((?CHUNK - 10) * 8)>>,
                 read(Handle, ?CHUNK, ?CHUNK, Tree4)),
    ?assertEqual(Held - ?CHUNK, held(Tree4)).

setattr_size_extends_with_a_hole_test() ->
    {File, Tree1} = file(?ROOT, <<"f">>, <<>>, tree()),
    Held = held(Tree1),
    {ok, Tree2} = ok_step({setattr, {node, File}, #{size => ?MAX_SIZE}}, Tree1),
    ?assertMatch(#{size := ?MAX_SIZE, blocks := 0}, attr(File, Tree2)),
    ?assertEqual(Held, held(Tree2)).

%% Through an opened fid the open decides, not the mode, as for ftruncate.
setattr_size_through_a_writable_handle_ignores_the_mode_test() ->
    {File, Handle, Tree1} = create(?ROOT, <<"f">>, tree()),
    {ok, Tree2} = ok_step({setattr, {node, File}, #{mode => 8#444}}, Tree1),
    ?assertMatch({ok, _}, ok_step({setattr, {open, Handle}, #{size => 1}}, Tree2)).

setattr_refusals_test() ->
    {Dir, Tree1} = mkdir(?ROOT, <<"d">>, tree()),
    {File, Tree2} = file(?ROOT, <<"f">>, <<>>, Tree1),
    {Reader, Tree3} = open(File, {read, []}, Tree2),
    {Link, Tree4} = symlink(?ROOT, <<"l">>, <<"f">>, Tree3),
    {ReadOnly, Tree5} = file(?ROOT, <<"ro">>, <<>>, Tree4),
    {ok, Tree6} = ok_step({setattr, {node, ReadOnly}, #{mode => 8#444}}, Tree5),
    Set = fun(Target, Changes) -> {setattr, Target, Changes} end,
    refused(eperm, Set({node, File}, #{uid => 5}), Tree6),
    refused(eperm, Set({node, File}, #{gid => 5}), Tree6),
    refused(efbig, Set({node, File}, #{size => ?MAX_SIZE + 1}), Tree6),
    refused(einval, Set({node, File}, #{size => -1}), Tree6),
    refused(einval, Set({open, Reader}, #{size => 0}), Tree6),
    refused(eacces, Set({node, ReadOnly}, #{size => 0}), Tree6),
    refused(eisdir, Set({node, Dir}, #{size => 0}), Tree6),
    refused(einval, Set({node, Link}, #{size => 0}), Tree6),
    refused(enoent, Set({node, 999999}, #{mode => 8#600}), Tree6),
    refused(einval, Set({node, File}, #{colour => blue}), Tree6),
    refused(einval, Set({node, File}, not_a_map), Tree6).

%% ---------------------------------------------------------------------------
%% unlink
%% ---------------------------------------------------------------------------

unlink_of_a_file_frees_its_charge_test() ->
    Tree1 = tree(),
    {_File, Tree2} = file(?ROOT, <<"f">>, binary:copy(<<1>>, 5000), Tree1),
    {ok, Tree3} = ok_step({unlink, ?ROOT, <<"f">>, file}, Tree2),
    ?assertEqual(0, held(Tree3)),
    ?assertEqual([], names(?ROOT, Tree3)).

unlink_of_a_directory_returns_its_dotdot_link_test() ->
    {_Dir, Tree1} = mkdir(?ROOT, <<"d">>, tree()),
    {ok, Tree2} = ok_step({unlink, ?ROOT, <<"d">>, directory}, Tree1),
    ?assertEqual(2, attr(nlink, ?ROOT, Tree2)),
    ?assertEqual(0, held(Tree2)).

unlink_refusals_test() ->
    {Dir, Tree1} = mkdir(?ROOT, <<"d">>, tree()),
    {_, Tree2} = file(Dir, <<"inner">>, <<>>, Tree1),
    {_, Tree3} = file(?ROOT, <<"f">>, <<>>, Tree2),
    {Shut, Tree4} = mkdir(?ROOT, <<"shut">>, Tree3),
    {_, Tree5} = mkdir(Shut, <<"x">>, Tree4),
    {ok, Tree6} = ok_step({setattr, {node, Shut}, #{mode => 8#500}}, Tree5),
    refused(enoent, {unlink, ?ROOT, <<"missing">>, file}, Tree6),
    refused(enotdir, {unlink, ?ROOT, <<"f">>, directory}, Tree6),
    refused(eisdir, {unlink, ?ROOT, <<"d">>, file}, Tree6),
    refused(enotempty, {unlink, ?ROOT, <<"d">>, directory}, Tree6),
    refused(enotempty, {unlink, ?ROOT, <<"d">>, {node, Dir}}, Tree6),
    refused(eacces, {unlink, Shut, <<"x">>, directory}, Tree6),
    refused(einval, {unlink, ?ROOT, <<"f">>, sideways}, Tree6),
    refused(einval, {unlink, ?ROOT, <<"f">>, any}, Tree6),
    refused(einval, {unlink, ?ROOT, <<"f">>, {node, none}}, Tree6).

%% remove names the node its fid stands at: a name that has come to name
%% another node since is left alone (enoent), and the step changes nothing.
unlink_of_a_node_removes_the_name_only_while_it_names_that_node_test() ->
    {Old, Tree1} = file(?ROOT, <<"a">>, <<"old">>, tree()),
    {ok, Tree2} = ok_step({rename, ?ROOT, <<"a">>, ?ROOT, <<"b">>}, Tree1),
    {New, Tree3} = file(?ROOT, <<"a">>, <<"new">>, Tree2),
    refused(enoent, {unlink, ?ROOT, <<"a">>, {node, Old}}, Tree3),
    {ok, Tree4} = ok_step({unlink, ?ROOT, <<"b">>, {node, Old}}, Tree3),
    refused(enoent, {getattr, Old}, Tree4),
    ?assertEqual(New, walk(?ROOT, <<"a">>, Tree4)),
    {ok, Tree5} = ok_step({unlink, ?ROOT, <<"a">>, {node, New}}, Tree4),
    ?assertEqual([], names(?ROOT, Tree5)).

%% ---------------------------------------------------------------------------
%% Open after unlink, and clunk
%% ---------------------------------------------------------------------------

an_unlinked_open_file_lives_until_its_last_clunk_test() ->
    Tree1 = tree(),
    {File, Handle, Tree2} = create(?ROOT, <<"f">>, Tree1),
    {ok, Tree3} = ok_step({unlink, ?ROOT, <<"f">>, file}, Tree2),
    Tree4 = write(Handle, 0, <<"still here">>, Tree3),
    ?assertEqual(<<"still here">>, read(Handle, 0, 100, Tree4)),
    ?assertMatch(#{nlink := 0, size := 10}, attr(File, Tree4)),
    ?assertEqual(256 + ?CHUNK, held(Tree4)),
    Tree5 = clunk(Handle, Tree4),
    ?assertEqual(held(Tree1), held(Tree5)),
    refused(enoent, {getattr, File}, Tree5),
    ?assertEqual({ok, Tree5}, step({clunk, Handle}, Tree5)).

%% An open of a node no name reaches opens nothing, as an open after the
%% unlink would not find it; the open made before the unlink still works.
open_of_a_node_with_no_name_is_enoent_test() ->
    {File, Handle, Tree1} = create(?ROOT, <<"f">>, tree()),
    Tree2 = write(Handle, 0, <<"kept">>, Tree1),
    {ok, Tree3} = ok_step({unlink, ?ROOT, <<"f">>, file}, Tree2),
    refused(enoent, {open, File, {read, []}}, Tree3),
    ?assertEqual(<<"kept">>, read(Handle, 0, 100, Tree3)),
    {Dir, Tree4} = mkdir(?ROOT, <<"d">>, Tree3),
    {_DirHandle, Tree5} = open(Dir, {read, []}, Tree4),
    {ok, Tree6} = ok_step({unlink, ?ROOT, <<"d">>, directory}, Tree5),
    refused(enoent, {open, Dir, {read, []}}, Tree6).

an_unlinked_open_directory_lists_empty_until_closed_test() ->
    {Dir, Tree1} = mkdir(?ROOT, <<"d">>, tree()),
    {Handle, Tree2} = open(Dir, {read, []}, Tree1),
    {ok, Tree3} = ok_step({unlink, ?ROOT, <<"d">>, directory}, Tree2),
    ?assertEqual({{ok, []}, Tree3}, step({readdir, Handle, 0, 10}, Tree3)),
    ?assertEqual(0, attr(nlink, Dir, Tree3)),
    refused(enoent, {make, Dir, <<"x">>, {directory, 8#755}}, Tree3),
    Tree4 = clunk(Handle, Tree3),
    refused(enoent, {getattr, Dir}, Tree4).

%% ---------------------------------------------------------------------------
%% rename
%% ---------------------------------------------------------------------------

rename_moves_the_name_test() ->
    {File, Tree1} = file(?ROOT, <<"a">>, <<"x">>, tree()),
    {ok, Tree2} = ok_step({rename, ?ROOT, <<"a">>, ?ROOT, <<"longer">>}, Tree1),
    ?assertEqual(File, walk(?ROOT, <<"longer">>, Tree2)),
    ?assertEqual(held(Tree1) + 5, held(Tree2)).

rename_over_a_file_frees_the_replaced_test() ->
    {_, Tree1} = file(?ROOT, <<"a">>, <<"new">>, tree()),
    {Old, Tree2} = file(?ROOT, <<"b">>, binary:copy(<<1>>, 5000), Tree1),
    {ok, Tree3} = ok_step({rename, ?ROOT, <<"a">>, ?ROOT, <<"b">>}, Tree2),
    refused(enoent, {getattr, Old}, Tree3),
    ?assertEqual(256 + 65 + ?CHUNK, held(Tree3)).

rename_over_an_open_file_keeps_its_bytes_test() ->
    {_, Tree1} = file(?ROOT, <<"a">>, <<"new">>, tree()),
    {Old, Tree2} = file(?ROOT, <<"b">>, <<"old">>, Tree1),
    {Handle, Tree3} = open(Old, {read, []}, Tree2),
    {ok, Tree4} = ok_step({rename, ?ROOT, <<"a">>, ?ROOT, <<"b">>}, Tree3),
    ?assertEqual(<<"old">>, read(Handle, 0, 10, Tree4)),
    ?assertEqual(0, attr(nlink, Old, Tree4)).

rename_of_a_directory_moves_its_dotdot_test() ->
    {A, Tree1} = mkdir(?ROOT, <<"a">>, tree()),
    {B, Tree2} = mkdir(?ROOT, <<"b">>, Tree1),
    {ok, Tree3} = ok_step({rename, ?ROOT, <<"a">>, B, <<"a">>}, Tree2),
    ?assertEqual(3, attr(nlink, ?ROOT, Tree3)),
    ?assertEqual(3, attr(nlink, B, Tree3)),
    ?assertEqual(A, walk(B, <<"a">>, Tree3)).

rename_of_a_directory_over_an_empty_one_test() ->
    {A, Tree1} = mkdir(?ROOT, <<"a">>, tree()),
    {B, Tree2} = mkdir(?ROOT, <<"b">>, Tree1),
    {_Victim, Tree3} = mkdir(B, <<"v">>, Tree2),
    {ok, Tree4} = ok_step({rename, ?ROOT, <<"a">>, B, <<"v">>}, Tree3),
    ?assertEqual(3, attr(nlink, B, Tree4)),
    ?assertEqual(3, attr(nlink, ?ROOT, Tree4)),
    ?assertEqual(A, walk(B, <<"v">>, Tree4)).

rename_between_names_of_one_node_changes_nothing_test() ->
    {File, Tree1} = file(?ROOT, <<"a">>, <<>>, tree()),
    {_, Tree2} = ok_step({make, ?ROOT, <<"b">>, {link, File}}, Tree1),
    ?assertEqual({ok, Tree2}, step({rename, ?ROOT, <<"a">>, ?ROOT, <<"b">>}, Tree2)).

rename_into_grandchild_is_einval_test() ->
    {A, Tree1} = mkdir(?ROOT, <<"a">>, tree()),
    {B, Tree2} = mkdir(A, <<"b">>, Tree1),
    {C, Tree3} = mkdir(B, <<"c">>, Tree2),
    refused(einval, {rename, ?ROOT, <<"a">>, C, <<"a">>}, Tree3),
    refused(einval, {rename, ?ROOT, <<"a">>, B, <<"a">>}, Tree3),
    refused(einval, {rename, ?ROOT, <<"a">>, A, <<"a">>}, Tree3).

rename_refusals_test() ->
    {A, Tree1} = mkdir(?ROOT, <<"a">>, tree()),
    {_, Tree2} = mkdir(A, <<"inner">>, Tree1),
    {_, Tree3} = mkdir(?ROOT, <<"empty">>, Tree2),
    {_, Tree4} = file(?ROOT, <<"f">>, <<>>, Tree3),
    {_, Tree5} = file(A, <<"g">>, <<>>, Tree4),
    {Shut, Tree6} = mkdir(?ROOT, <<"shut">>, 8#500, Tree5),
    {_, Tree7} = mkdir(?ROOT, <<"fixed">>, 8#500, Tree6),
    Rename = fun(Dir, Name, NewDir, NewName) -> {rename, Dir, Name, NewDir, NewName} end,
    refused(enoent, Rename(?ROOT, <<"missing">>, ?ROOT, <<"x">>), Tree7),
    refused(enotdir, Rename(?ROOT, <<"empty">>, ?ROOT, <<"f">>), Tree7),
    refused(eisdir, Rename(?ROOT, <<"f">>, ?ROOT, <<"empty">>), Tree7),
    refused(enotempty, Rename(?ROOT, <<"empty">>, ?ROOT, <<"a">>), Tree7),
    %% The target holds the source: Linux's trap answers before the kinds.
    refused(enotempty, Rename(A, <<"g">>, ?ROOT, <<"a">>), Tree7),
    refused(eacces, Rename(?ROOT, <<"f">>, Shut, <<"f">>), Tree7),
    refused(eacces, Rename(?ROOT, <<"fixed">>, A, <<"fixed">>), Tree7),
    %% A longer name costs more, and a full tree has no room for it.
    {_, Full} = file(?ROOT, <<"f">>, <<>>, tree(256 + 65)),
    refused(enospc, Rename(?ROOT, <<"f">>, ?ROOT, <<"longer">>), Full).

%% ---------------------------------------------------------------------------
%% Stored binaries
%% ---------------------------------------------------------------------------

%% A name, a link text and data handed in as parts of larger binaries are
%% stored as copies, so the tree holds no bytes it was not charged for.
stored_binaries_are_copies_test() ->
    Big = binary:copy(<<"abcdefgh">>, 1000),
    %% Longer than 64 bytes: ERTS copies a smaller part out on its own.
    Name = binary_part(Big, 1, 200),
    Text = binary_part(Big, 2, 300),
    ?assert(binary:referenced_byte_size(Name) > 200),
    ?assert(binary:referenced_byte_size(Text) > 300),
    {_, Handle, Tree1} = create(?ROOT, Name, tree()),
    {_, Tree2} = symlink(?ROOT, <<"l">>, Text, Tree1),
    {_, Tree3} = ok_step({write, Handle, 0, binary_part(Big, 3, 10)}, Tree2),
    ?assertEqual(ok, erx_ramfs_core:check(Tree3)).

%% Every chunk a write or a truncation builds is a binary of exactly 4,096
%% bytes that references nothing more, whether the write fills the chunk,
%% covers part of it or crosses into the next one, and whatever part of a
%% larger request it came from: check/1 after each step tests that. A whole
%% stored chunk reads back as itself, so the reads then show that each kept
%% binary holds the right bytes, each part joined at its place.
chunks_are_built_alone_test() ->
    Request = list_to_binary([I rem 251 || I <- lists:seq(1, 8 * ?CHUNK)]),
    Part = fun(Offset, Length) -> binary_part(Request, Offset, Length) end,
    {_, Handle, Tree1} = create(?ROOT, <<"f">>, tree()),
    %% Chunks 0 to 3 whole, then part of chunk 0, then the end of chunk 1
    %% and the start of chunk 2.
    Tree2 = write(Handle, 0, Part(8, 4 * ?CHUNK), Tree1),
    Tree3 = write(Handle, 10, Part(1, 100), Tree2),
    Tree4 = write(Handle, 2 * ?CHUNK - 50, Part(3, 200), Tree3),
    %% Truncation inside chunk 3 zeroes its tail; chunk 4 is written whole.
    {ok, Tree5} = ok_step({setattr, {open, Handle}, #{size => 3 * ?CHUNK + 20}},
                          Tree4),
    Tree6 = write(Handle, 4 * ?CHUNK, Part(5, ?CHUNK), Tree5),
    Expected = lists:foldl(
                 fun({At, Bytes}, File) -> overlaid(File, At, Bytes) end,
                 <<(Part(8, 3 * ?CHUNK + 20))/binary,
                   0:((2 * ?CHUNK - 20) * 8)>>,
                 [{10, Part(1, 100)}, {2 * ?CHUNK - 50, Part(3, 200)},
                  {4 * ?CHUNK, Part(5, ?CHUNK)}]),
    lists:foreach(
      fun(I) ->
              Chunk = read(Handle, I * ?CHUNK, ?CHUNK, Tree6),
              ?assertEqual(binary_part(Expected, I * ?CHUNK, ?CHUNK), Chunk),
              ?assertEqual(?CHUNK, binary:referenced_byte_size(Chunk))
      end, lists:seq(0, 4)).

%% File with Bytes written over it at At, inside its size.
overlaid(File, At, Bytes) ->
    End = At + byte_size(Bytes),
    <<(binary_part(File, 0, At))/binary, Bytes/binary,
      (binary_part(File, End, byte_size(File) - End))/binary>>.

%% ---------------------------------------------------------------------------
%% fsync, statfs, xattr and requests no callback builds
%% ---------------------------------------------------------------------------

fsync_does_nothing_test() ->
    {_, Handle, Tree} = create(?ROOT, <<"f">>, tree()),
    ?assertEqual({ok, Tree}, step({fsync, Handle}, Tree)).

statfs_counts_blocks_and_nodes_test() ->
    {_, Tree} = file(?ROOT, <<"f">>, <<"x">>, tree(100 * ?CHUNK)),
    Free = 100 * ?CHUNK - (256 + 65 + ?CHUNK),
    ?assertEqual({{ok, #{bsize => ?CHUNK, blocks => 100,
                         bfree => Free div ?CHUNK, bavail => Free div ?CHUNK,
                         files => 2 + Free div 256, ffree => Free div 256,
                         namelen => 255}}, Tree},
                 step(statfs, Tree)).

xattr_is_enotsup_test() ->
    refused(enotsup, {xattr, ?ROOT, {get, <<"user.x">>}}, tree()).

requests_no_callback_builds_are_einval_test() ->
    Tree = tree(),
    refused(einval, {frobnicate, ?ROOT}, Tree),
    refused(einval, {make, ?ROOT, <<"x">>, {directory, not_a_mode}}, Tree),
    ?assertEqual({{error, einval}, Tree},
                 erx_ramfs_core:step({getattr, ?ROOT}, 0, ?NOW, Tree)).

%% ---------------------------------------------------------------------------
%% Times and versions: one case per row of the design's table. Fixtures are
%% made at ?NOW; the step under test runs at ?LATER, so a time it sets is told
%% apart from one it left.
%% ---------------------------------------------------------------------------

-define(LATER, 3000).

later(Request, Tree) ->
    {Reply, Tree1} = erx_ramfs_core:step(Request, stamp(), ?LATER, Tree),
    ?assertNotMatch({error, _}, Reply),
    ?assertEqual(ok, erx_ramfs_core:check(Tree1)),
    Tree1.

%% The fields a step changed, as {Field, Before, After}.
changed_fields(Ino, Before, After) ->
    A = attr(Ino, Before),
    B = attr(Ino, After),
    [{Field, maps:get(Field, A), maps:get(Field, B)} ||
        Field <- [atime, mtime, ctime, data_version, nlink, size, mode],
        maps:get(Field, A) =/= maps:get(Field, B)].

fields(Changed) -> [Field || {Field, _, _} <- Changed].

write_sets_mtime_ctime_and_version_test() ->
    {File, Handle, Tree1} = create(?ROOT, <<"f">>, tree()),
    Tree2 = later({write, Handle, 0, <<"x">>}, Tree1),
    ?assertEqual([mtime, ctime, data_version, size],
                 fields(changed_fields(File, Tree1, Tree2))).

truncation_takes_a_version_only_when_the_size_changes_test() ->
    {File, Tree1} = file(?ROOT, <<"f">>, <<"abc">>, tree()),
    Same = later({setattr, {node, File}, #{size => 3}}, Tree1),
    ?assertEqual([mtime, ctime], fields(changed_fields(File, Tree1, Same))),
    Shorter = later({setattr, {node, File}, #{size => 1}}, Tree1),
    ?assertEqual([mtime, ctime, data_version, size],
                 fields(changed_fields(File, Tree1, Shorter))),
    {Empty, Tree2} = file(?ROOT, <<"e">>, <<>>, Tree1),
    Opened = later({open, Empty, {write, [trunc]}}, Tree2),
    ?assertEqual([mtime, ctime], fields(changed_fields(Empty, Tree2, Opened))),
    Emptied = later({open, File, {write, [trunc]}}, Tree2),
    ?assertEqual([mtime, ctime, data_version, size],
                 fields(changed_fields(File, Tree2, Emptied))).

a_new_node_changes_its_directory_test() ->
    {Dir, Tree1} = mkdir(?ROOT, <<"d">>, tree()),
    Tree2 = later({make, Dir, <<"l">>, {symlink, <<"t">>}}, Tree1),
    ?assertEqual([mtime, ctime, data_version], fields(changed_fields(Dir, Tree1, Tree2))),
    Link = walk(Dir, <<"l">>, Tree2),
    ?assertMatch(#{atime := ?LATER, mtime := ?LATER, ctime := ?LATER,
                   data_version := Link}, attr(Link, Tree2)).

unlink_changes_the_directory_and_a_surviving_node_test() ->
    {File, Tree1} = file(?ROOT, <<"f">>, <<>>, tree()),
    {_, Tree2} = ok_step({make, ?ROOT, <<"g">>, {link, File}}, Tree1),
    Tree3 = later({unlink, ?ROOT, <<"f">>, file}, Tree2),
    ?assertEqual([mtime, ctime, data_version],
                 fields(changed_fields(?ROOT, Tree2, Tree3))),
    ?assertEqual([ctime, nlink], fields(changed_fields(File, Tree2, Tree3))).

link_changes_the_node_ctime_and_the_directory_test() ->
    {File, Tree1} = file(?ROOT, <<"f">>, <<>>, tree()),
    Tree2 = later({make, ?ROOT, <<"g">>, {link, File}}, Tree1),
    ?assertEqual([ctime, nlink], fields(changed_fields(File, Tree1, Tree2))),
    ?assertEqual([mtime, ctime, data_version],
                 fields(changed_fields(?ROOT, Tree1, Tree2))).

rename_changes_both_directories_and_the_nodes_test() ->
    {A, Tree1} = mkdir(?ROOT, <<"a">>, tree()),
    {B, Tree2} = mkdir(?ROOT, <<"b">>, Tree1),
    {Moved, Tree3} = file(A, <<"m">>, <<>>, Tree2),
    {Replaced, Tree4} = file(B, <<"r">>, <<>>, Tree3),
    {_Handle, Tree5} = open(Replaced, {read, []}, Tree4),
    Tree6 = later({rename, A, <<"m">>, B, <<"r">>}, Tree5),
    ?assertEqual([mtime, ctime, data_version], fields(changed_fields(A, Tree5, Tree6))),
    ?assertEqual([mtime, ctime, data_version], fields(changed_fields(B, Tree5, Tree6))),
    ?assertEqual([ctime], fields(changed_fields(Moved, Tree5, Tree6))),
    ?assertEqual([ctime, nlink], fields(changed_fields(Replaced, Tree5, Tree6))).

setattr_of_mode_owner_and_times_changes_no_version_test() ->
    {File, Tree1} = file(?ROOT, <<"f">>, <<>>, tree()),
    Tree2 = later({setattr, {node, File}, #{mode => 8#600, uid => 0, atime => now}},
                  Tree1),
    ?assertEqual([atime, ctime, mode], fields(changed_fields(File, Tree1, Tree2))).
