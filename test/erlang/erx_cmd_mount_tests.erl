%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_mount_tests).
-moduledoc """
EUnit cases of the command shell's `mount` (erx_cmd_mount,
docs/design-files.md, "Building, binding and mounting"): FreeBSD's layout
`SOURCE on POINT (TYPE, OPTIONS)` for each kind of provider and each right,
a bind's root in the source, the type name of each `p9_magic_` limit of
abi/protocols/9p.txt, a number no limit names in hex and a missing type as
`-`, names with control characters through the field escape, the type each
of erXos's file servers answers statfs with as `mount` names it, and, on
stock's emulator, which has no namespace table, `enotsup`
(test/host/erx_cmd_mount_test.rb).
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

line(Entry, Type) -> iolist_to_binary(erx_cmd_mount:line(Entry, Type)).

entry(Provider, Point, Root, Rights) ->
    #{point => Point, provider => Provider, root => Root, rights => Rights}.

%% A pid of this node, printed as pid_to_list/1 prints it.
server() -> list_to_pid("<0.88.0>").

%%% Layout

release_line_test() ->
    ?assertEqual(<<"release on / (release, local, read-only)\n">>,
                 line(entry(release, [], [], ro), release)).

erofs_line_test() ->
    ?assertEqual(<<"erofs on /usr/share (erofs, local, read-only)\n">>,
                 line(entry({erofs, image}, [<<"usr">>, <<"share">>], [], ro), erofs)).

%% The case the user met: /data, a facet's grant on the SD card's littlefs volume.
littlefs_grant_line_test() ->
    ?assertEqual(<<"<0.88.0>:/data on /data (littlefs)\n">>,
                 line(entry({grant, server(), <<"data">>}, [<<"data">>], [], rw),
                      {magic, ?ERX_P9_MAGIC_LITTLEFS})).

read_only_and_runnable_grants_are_read_only_test() ->
    [?assertEqual(<<"<0.88.0>:/bin on /usr/local/bin (littlefs, read-only)\n">>,
                  line(entry({grant, server(), <<"bin">>}, [<<"usr">>, <<"local">>, <<"bin">>], [], Rights),
                       {magic, ?ERX_P9_MAGIC_LITTLEFS}))
     || Rights <- [ro, rx]].

bind_root_follows_the_source_test() ->
    ?assertEqual(<<"<0.88.0>:/data/a/b on /x (littlefs)\n">>,
                 line(entry({grant, server(), <<"data">>}, [<<"x">>], [<<"a">>, <<"b">>], rw),
                      {magic, ?ERX_P9_MAGIC_LITTLEFS})),
    ?assertEqual(<<"release:/lib on /l (release, local, read-only)\n">>,
                 line(entry(release, [<<"l">>], [<<"lib">>], ro), release)).

ended_grant_has_no_type_test() ->
    ?assertEqual(<<"ended on /data (-)\n">>, line(entry(ended, [<<"data">>], [], rw), unknown)).

%%% Types

each_magic_has_its_name_test() ->
    ?assertEqual([<<"littlefs">>, <<"tmpfs">>, <<"procfs">>, <<"devfs">>, <<"ramfs">>],
                 [erx_cmd_mount:type_name({magic, Magic})
                  || Magic <- [?ERX_P9_MAGIC_LITTLEFS, ?ERX_P9_MAGIC_TMPFS, ?ERX_P9_MAGIC_PROC,
                               ?ERX_P9_MAGIC_DEVFS, ?ERX_P9_MAGIC_RAMFS]]).

%% A number no limit names prints as the server sent it, at most ten characters.
unknown_magic_prints_in_hex_test() ->
    ?assertEqual(<<"0x0">>, erx_cmd_mount:type_name({magic, 0})),
    ?assertEqual(<<"0xffffffff">>, erx_cmd_mount:type_name({magic, 16#ffffffff})),
    ?assertEqual(<<"-">>, erx_cmd_mount:type_name(unknown)).

%% The type each server answers statfs with is the one `mount` names for it. erx_lfs
%% answers its type even when its volume's process has ended.
servers_answer_their_type_test() ->
    {ok, #{type := Proc}} = erx_procfs:statfs(undefined),
    Dead = spawn(fun() -> ok end),
    Monitor = monitor(process, Dead),
    receive {'DOWN', Monitor, process, Dead, _} -> ok end,
    {ok, #{type := Littlefs}} = erx_lfs:statfs({Dead, make_ref()}),
    ?assertEqual([<<"procfs">>, <<"littlefs">>],
                 [erx_cmd_mount:type_name({magic, Type}) || Type <- [Proc, Littlefs]]).

%%% Escaping

%% A tree's and a point's names are text another domain may have chosen: each control
%% character, tab and newline included, leaves the line escaped.
names_are_escaped_test() ->
    Line = line(entry({grant, server(), <<"d\e]0;x\a">>}, [<<"a\nb">>], [<<"t\tu">>], rw),
                {magic, ?ERX_P9_MAGIC_TMPFS}),
    ?assertEqual(nomatch, re:run(binary:part(Line, 0, byte_size(Line) - 1), "[\\x00-\\x1f\\x7f]")),
    ?assertMatch({_, _}, binary:match(Line, <<" on /a\\nb (tmpfs)\n">>)).

%%% Running

run_line(Source) ->
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)}
                     || Module <- [erx_cmd_mount]]),
    State = erx_shell_runner:state(#{cwd => <<"/">>, fds => #{0 => null, 1 => sink(out), 2 => sink(err)},
                                     table => Table, facets => fun() -> #{} end}),
    Shell = erx_shell_eval:new(#{}, erx_shell_runner:runner(), State),
    {ok, Done} = erx_shell_eval:run_source(Source, Shell),
    {erx_shell_eval:status(Done), shown(out), shown(err)}.

sink(Stream) ->
    Me = self(),
    {tty, fun(Bytes) -> Me ! {Stream, iolist_to_binary(Bytes)}, ok end}.

shown(Stream) -> shown(Stream, []).

shown(Stream, Acc) ->
    receive {Stream, Bytes} -> shown(Stream, [Acc, Bytes])
    after 0 -> iolist_to_binary(Acc)
    end.

%% Stock's prim_file has no namespace table, so the command answers enotsup and prints
%% no line; an argument is a usage error.
stock_has_no_table_test() ->
    {Status, Out, _Err} = run_line(<<"mount">>),
    ?assertNotEqual(<<>>, Status),
    ?assertEqual(<<>>, Out),
    {Usage, <<>>, _} = run_line(<<"mount /data">>),
    ?assertNotEqual(<<>>, Usage).
