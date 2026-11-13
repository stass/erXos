%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_ns, the namespace table's one writer (design-files.md, Building,
%% binding and mounting), run on stock's emulator over erx_ns_prim_stub: each change's
%% checks and answers, the table the persistent term holds after it, a grant's end,
%% and a restart.

-module(erx_ns_tests).

-include_lib("eunit/include/eunit.hrl").

-define(RELEASE, #{point => [], provider => release, root => [], rights => ro}).

%% Each case starts from the boot table, with a fresh process.
ns_test_() ->
    {foreach, fun start/0, fun stop/1,
     [fun boot_table_until_a_change/0,
      fun mount_adds_a_grant_entry/0,
      fun mount_refusals/0,
      fun mount_of_an_image_adds_a_read_only_entry/0,
      fun image_mount_refusals/0,
      fun bind_roots_at_the_place_from_reaches/0,
      fun bind_of_a_relative_path_starts_at_the_working_directory/0,
      fun bind_refusals/0,
      fun unmount_removes_exactly_one_entry/0,
      fun the_table_holds_at_most_64_entries/0,
      fun an_ended_grant_marks_every_entry_of_it_ended/0,
      fun a_grant_ended_while_the_process_was_down_ends_on_restart/0,
      fun a_malformed_request_answers_einval_and_changes_nothing/0,
      fun a_facet_mount_reads_the_registry_at_use/0,
      fun a_facet_grant_that_ends_leaves_the_table_and_survives_a_restart/0,
      fun facets_mount_only_where_granted/0,
      fun facet_mount_refusals/0]}.

start() ->
    persistent_term:erase(erx_ns),
    {ok, Ns} = erx_ns:start_link(erx_ns_prim_stub),
    unlink(Ns),
    Ns.

stop(_Ns) ->
    Ns = whereis(erx_ns),
    exit(Ns, kill),
    wait_down(Ns),
    persistent_term:erase(erx_ns),
    persistent_term:erase({erx, facets}),
    flush().

table() -> erx_ns_prim_stub:erx_mounts().

grant() -> spawn(fun() -> receive stop -> ok end end).

boot_table_until_a_change() ->
    ?assertEqual(undefined, persistent_term:get(erx_ns, undefined)),
    ?assertEqual([?RELEASE], table()).

mount_adds_a_grant_entry() ->
    Grant = grant(),
    ?assertEqual(ok, erx_ns:mount(Grant, <<"/tmp/">>, [{tree, <<"tmp">>}, rw])),
    ?assertEqual([?RELEASE, #{point => [<<"tmp">>], provider => {grant, Grant, <<"tmp">>}, root => [],
                              rights => rw}], persistent_term:get(erx_ns)),
    ?assertEqual(ok, erx_ns:mount(Grant, "/a//b", [{tree, <<"t">>}])),
    ?assertMatch([_, _, #{point := [<<"a">>, <<"b">>], rights := ro}], table()).

mount_refusals() ->
    Grant = grant(),
    ok = erx_ns:mount(Grant, <<"/tmp">>, [{tree, <<"tmp">>}, rw]),
    Before = table(),
    Long = binary:copy(<<"n">>, 256),
    [?assertEqual({error, Reason}, erx_ns:mount(Pid, Point, Options))
     || {Reason, Pid, Point, Options} <-
            [{eexist, Grant, <<"/tmp/">>, [{tree, <<"tmp">>}]},
             {einval, Grant, <<"/x">>, [{tree, <<"a/b">>}]},
             {einval, Grant, <<"/x">>, [{tree, <<"..">>}]},
             {einval, Grant, <<"/x">>, [{tree, <<>>}]},
             {einval, Grant, <<"/x">>, []},
             {einval, Grant, <<"/x">>, [{tree, <<"t">>}, rw, ro]},
             {einval, Grant, <<"x">>, [{tree, <<"t">>}]},
             {einval, Grant, <<"/a/../b">>, [{tree, <<"t">>}]},
             {einval, Grant, <<"/a/./b">>, [{tree, <<"t">>}]},
             {einval, Grant, <<"/a", 0, "b">>, [{tree, <<"t">>}]},
             {einval, Grant, <<"/", 16#ff>>, [{tree, <<"t">>}]},
             {einval, not_a_pid, <<"/x">>, [{tree, <<"t">>}]},
             {enametoolong, Grant, <<"/", Long/binary>>, [{tree, <<"t">>}]},
             {enametoolong, Grant, iolist_to_binary(lists:duplicate(257, <<"/n">>)), [{tree, <<"t">>}]}]],
    ?assertEqual(Before, table()).

bind_roots_at_the_place_from_reaches() ->
    Grant = grant(),
    ok = erx_ns:mount(Grant, <<"/tmp">>, [{tree, <<"tmp">>}, rw]),
    ?assertEqual(ok, erx_ns:bind(<<"/tmp/a/./c/../d">>, <<"/b">>, [ro])),
    ?assertEqual(ok, erx_ns:bind(<<"/lib/x">>, <<"/y">>)),
    ?assertEqual(ok, erx_ns:bind(<<"/b/e">>, <<"/z">>)),
    [_, _, Bound, Released, Again] = table(),
    ?assertEqual(#{point => [<<"b">>], provider => {grant, Grant, <<"tmp">>}, root => [<<"a">>, <<"d">>],
                   rights => ro}, Bound),
    ?assertEqual(#{point => [<<"y">>], provider => release, root => [<<"lib">>, <<"x">>], rights => ro}, Released),
    ?assertEqual(Bound#{point => [<<"z">>], root => [<<"a">>, <<"d">>, <<"e">>]}, Again).

bind_of_a_relative_path_starts_at_the_working_directory() ->
    {ok, Cwd} = file:get_cwd(),
    ?assertEqual(ok, erx_ns:bind(<<"sub/..">>, <<"/here">>)),
    [_, #{root := Root}] = table(),
    ?assertEqual(unicode:characters_to_binary(Cwd), filename:join([<<"/">> | Root])).

bind_refusals() ->
    Before = table(),
    [?assertEqual({error, Reason}, erx_ns:bind(From, To, Options))
     || {Reason, From, To, Options} <-
            [{einval, <<"/a">>, <<"/b">>, [rw]},
             {eexist, <<"/a">>, <<"/">>, []},
             {einval, <<"/a">>, <<"/b/..">>, []},
             {einval, <<"/", 16#ff>>, <<"/b">>, []}]],
    ?assertEqual(Before, table()),
    %% A table without / places nothing outside its entries.
    persistent_term:put(erx_ns, [#{point => [<<"d">>], provider => release, root => [], rights => ro}]),
    ?assertEqual({error, enoent}, erx_ns:bind(<<"/e">>, <<"/d/f">>, [])).

unmount_removes_exactly_one_entry() ->
    Grant = grant(),
    ok = erx_ns:mount(Grant, <<"/tmp">>, [{tree, <<"tmp">>}, rw]),
    ok = erx_ns:bind(<<"/tmp">>, <<"/t">>),
    ?assertEqual({error, ebusy}, erx_ns:unmount(<<"/">>)),
    ?assertEqual({error, ebusy}, erx_ns:unmount(<<"//">>)),
    ?assertEqual({error, einval}, erx_ns:unmount(<<"/tmp/a">>)),
    ?assertEqual({error, einval}, erx_ns:unmount(<<"tmp">>)),
    ?assertEqual(ok, erx_ns:unmount(<<"/tmp/">>)),
    ?assertMatch([#{point := [], provider := release}, #{point := [<<"t">>]}], table()).

the_table_holds_at_most_64_entries() ->
    [ok = erx_ns:bind(<<"/">>, <<"/", (integer_to_binary(N))/binary>>) || N <- lists:seq(2, 64)],
    ?assertEqual(64, length(table())),
    ?assertEqual({error, system_limit}, erx_ns:bind(<<"/">>, <<"/65">>)).

an_ended_grant_marks_every_entry_of_it_ended() ->
    Grant = grant(),
    Other = grant(),
    ok = erx_ns:mount(Grant, <<"/tmp">>, [{tree, <<"tmp">>}, rw]),
    ok = erx_ns:bind(<<"/tmp/a">>, <<"/b">>, [ro]),
    ok = erx_ns:mount(Other, <<"/o">>, [{tree, <<"o">>}]),
    Grant ! stop,
    wait_down(Grant),
    ?assertMatch([#{point := [], provider := release}, #{point := [<<"tmp">>], provider := ended, rights := rw},
                  #{point := [<<"b">>], provider := ended, root := [<<"a">>]},
                  #{point := [<<"o">>], provider := {grant, Other, <<"o">>}}], settled()),
    %% The ended entry stays until it is unmounted, and a later mount at its point
    %% after that holds the new grant.
    ?assertEqual({error, eexist}, erx_ns:mount(Other, <<"/tmp">>, [{tree, <<"tmp">>}])),
    ok = erx_ns:unmount(<<"/tmp">>),
    ok = erx_ns:mount(Other, <<"/tmp">>, [{tree, <<"tmp">>}]),
    ?assertMatch(#{provider := {grant, Other, <<"tmp">>}}, lists:last(table())).

a_grant_ended_while_the_process_was_down_ends_on_restart() ->
    Grant = grant(),
    ok = erx_ns:mount(Grant, <<"/tmp">>, [{tree, <<"tmp">>}, rw]),
    Ns = whereis(erx_ns),
    exit(Ns, kill),
    wait_down(Ns),
    ?assertMatch([_, #{provider := {grant, Grant, _}}], table()),
    Grant ! stop,
    wait_down(Grant),
    {ok, Again} = erx_ns:start_link(erx_ns_prim_stub),
    unlink(Again),
    ?assertMatch([#{point := [], provider := release}, #{point := [<<"tmp">>], provider := ended}], settled()).

a_malformed_request_answers_einval_and_changes_nothing() ->
    [?assertEqual({error, einval}, gen_server:call(erx_ns, Request))
     || Request <- [nonsense, {mount, <<"/x">>, self(), bad}, {bind, 1, 2, []}, {unmount, {}},
                    {mount, <<"/x">>, self(), [{tree, <<"t">>} | tail]},
                    {mount, <<"/x">>, {erofs, not_a_mount}, []}]],
    ?assertEqual(undefined, persistent_term:get(erx_ns, undefined)),
    ?assert(is_process_alive(whereis(erx_ns))).

%% An image mounts from a window, read-only, its entry holding the reader's mount, and
%% unmounts as any entry does.
mount_of_an_image_adds_a_read_only_entry() ->
    Window = erx_erofs_tests:window(erx_erofs_tests:fixture("compact")),
    ?assertEqual(ok, erx_ns:mount({erofs, Window}, <<"/release/">>, [])),
    [_, #{point := [<<"release">>], provider := {erofs, Fs}, root := [], rights := ro}] = table(),
    ?assertEqual({ok, [<<"b">>]}, erx_erofs:list_dir(Fs, [<<"a">>])),
    ?assertEqual(ok, erx_ns:mount({erofs, Window}, "/again", [ro])),
    ?assertEqual(ok, erx_ns:unmount(<<"/release">>)),
    ?assertMatch([#{point := []}, #{point := [<<"again">>]}], table()).

%% A malformed image, a window that ended and anything but ro answer before the table
%% changes; the mount's diagnostic goes to the log.
image_mount_refusals() ->
    register(erx_ns_log, self()),
    Window = erx_erofs_tests:window(erx_erofs_tests:fixture("compact")),
    {Gone, Ref} = spawn_monitor(fun() -> ok end),
    receive {'DOWN', Ref, process, Gone, _} -> ok end,
    [?assertEqual({error, Reason}, erx_ns:mount(Source, To, Options))
     || {Reason, Source, To, Options} <-
            [{eio, {erofs, erx_erofs_tests:window(binary:copy(<<0>>, 8192))}, <<"/x">>, []},
             {eio, {erofs, Gone}, <<"/x">>, []},
             {einval, {erofs, not_a_pid}, <<"/x">>, []},
             {einval, {erofs, Window}, <<"/x">>, [rw]},
             {einval, {erofs, Window}, <<"/x">>, [rx]},
             {einval, {erofs, Window}, <<"/x">>, [{tree, <<"t">>}]},
             {einval, {erofs, Window}, <<"x">>, []},
             {eexist, {erofs, Window}, <<"/">>, []}]],
    ?assertEqual(undefined, persistent_term:get(erx_ns, undefined)),
    unregister(erx_ns_log),
    ?assertMatch([{log, ["erx_ns: image ", _, ": ", <<"erofs: block 0: no EROFS magic">>]} | _], logged()).

%% A facet's mount holds the facet's name, not a pid, and a resolution reads the domain's
%% facet registry, the term {erx, facets}, as it uses the table: each entry of the facet,
%% binds included, is on the grant the registry holds now, a re-grant serves the next
%% lookup, and with no grant, or a value that is no pid, the entries answer eio. The
%% process keeps no monitor for a facet, so a grant of another domain never meets
%% is_process_alive/1.
a_facet_mount_reads_the_registry_at_use() ->
    ?assertEqual(ok, erx_ns:mount({facet, data}, <<"/data">>, [{tree, <<"data">>}, rw])),
    ok = erx_ns:bind(<<"/data/sub">>, <<"/s">>, [ro]),
    ?assertMatch([_, #{point := [<<"data">>], provider := {facet, data, <<"data">>}, root := [], rights := rw},
                  #{point := [<<"s">>], provider := {facet, data, <<"data">>}, root := [<<"sub">>], rights := ro}],
                 table()),
    ?assertMatch([_, #{provider := ended}, #{provider := ended}], at_use()),
    [First, Second] = [grant(), grant()],
    persistent_term:put({erx, facets}, #{data => First}),
    ?assertMatch([_, #{provider := {grant, First, <<"data">>}, rights := rw},
                  #{provider := {grant, First, <<"data">>}, root := [<<"sub">>], rights := ro}], at_use()),
    persistent_term:put({erx, facets}, #{data => Second, other => First}),
    ?assertMatch([_, #{provider := {grant, Second, _}}, #{provider := {grant, Second, _}}], at_use()),
    Remote = remote_pid(),
    persistent_term:put({erx, facets}, #{data => Remote}),
    ?assertMatch([_, #{provider := {grant, Remote, _}}, #{provider := {grant, Remote, _}}], at_use()),
    persistent_term:put({erx, facets}, #{data => not_a_pid}),
    ?assertMatch([_, #{provider := ended}, #{provider := ended}], at_use()),
    ?assertEqual(#{}, maps:get(monitors, sys:get_state(erx_ns))).

%% A facet's grant that ends changes nothing in the table: the next lookup still sends to
%% it and the client's own monitor on it answers eio, until the registry holds the
%% re-grant. A restarted process keeps the facet's entries as the term holds them.
a_facet_grant_that_ends_leaves_the_table_and_survives_a_restart() ->
    ok = erx_ns:mount({facet, data}, <<"/data">>, [{tree, <<"data">>}, rw]),
    Grant = grant(),
    persistent_term:put({erx, facets}, #{data => Grant}),
    Grant ! stop,
    wait_down(Grant),
    Before = settled(),
    ?assertMatch([_, #{provider := {facet, data, <<"data">>}}], Before),
    ?assertMatch([_, #{provider := {grant, Grant, _}}], at_use()),
    Ns = whereis(erx_ns),
    exit(Ns, kill),
    wait_down(Ns),
    {ok, Again} = erx_ns:start_link(erx_ns_prim_stub),
    unlink(Again),
    ?assertEqual(Before, settled()).

%% A domain mounts a facet only where the manifest grants it (erx:granted/0, as the
%% system domain's service and a session's application pass it): with no data facet
%% granted there is no mount, so /data is the root's own entry, which a FreeBSD mount
%% point with nothing mounted on it also shows; a name with no mount point mounts
%% nothing. With data granted and its grant not yet installed, /data is the facet's
%% mount, which answers eio, and never falls through to the root beneath it.
facets_mount_only_where_granted() ->
    ?assertEqual(ok, erx_ns:mount_facets([])),
    ?assertEqual(ok, erx_ns:mount_facets([echo])),
    ?assertEqual([?RELEASE], at_use()),
    ?assertEqual(ok, erx_ns:mount_facets([echo, data])),
    ?assertEqual([?RELEASE, #{point => [<<"data">>], provider => ended, root => [], rights => rw}], at_use()).

%% A facet is named by an atom, and its mount takes a grant's options; a pid of another
%% domain is never mounted directly, only through a facet.
facet_mount_refusals() ->
    [?assertEqual({error, Reason}, erx_ns:mount(Source, Point, Options))
     || {Reason, Source, Point, Options} <-
            [{einval, {facet, <<"data">>}, <<"/data">>, [{tree, <<"data">>}]},
             {einval, {facet, data}, <<"/data">>, []},
             {einval, {facet, data}, <<"/data">>, [{tree, <<"data">>}, rw, ro]},
             {einval, {facet, data}, <<"data">>, [{tree, <<"data">>}]},
             {einval, remote_pid(), <<"/data">>, [{tree, <<"data">>}, rw]}]],
    ?assertEqual(undefined, persistent_term:get(erx_ns, undefined)).

%% The table as a resolution uses it, prim_file:erx_table/0's.
at_use() ->
    erx_path:with_facets(table(), persistent_term:get({erx, facets}, #{})).

%% A pid of another node, which this node is not connected to.
remote_pid() ->
    Node = <<"storage@erxos">>,
    binary_to_term(<<131, 88, 119, (byte_size(Node)), Node/binary, 1:32, 0:32, 7:32>>).

logged() ->
    receive {log, _} = Log -> [Log | logged()] after 0 -> [] end.

%% The table once erx_ns has handled every message before this call.
settled() ->
    _ = sys:get_state(erx_ns),
    table().

wait_down(Pid) ->
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> error(timeout) end.

flush() ->
    receive _ -> flush() after 0 -> ok end.
