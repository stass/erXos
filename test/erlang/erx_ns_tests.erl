%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_ns, the namespace table's one writer (design-files.md, Building,
%% binding and mounting), run on stock's emulator over erx_ns_prim_stub: each change's
%% checks and answers, the table the persistent term holds after it, a grant's end,
%% and a restart.

-module(erx_ns_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(RELEASE, #{point => [], provider => release, root => [], rights => ro}).

%% Each case starts from the boot table, with a fresh process.
ns_test_() ->
    {foreach, fun start/0, fun stop/1,
     [fun boot_table_until_a_change/0,
      fun mount_adds_a_grant_entry/0,
      fun mount_refusals/0,
      fun a_grant_entry_takes_the_lesser_of_its_rights_and_its_grants/0,
      fun an_app_mount_reads_the_package_through_its_record/0,
      fun an_app_mount_of_a_changed_package_answers_eio/0,
      fun an_rx_app_mount_needs_an_rx_grant/0,
      fun app_mount_refusals/0,
      fun the_fid_closes_when_the_last_entry_of_the_image_goes/0,
      fun bind_roots_at_the_place_from_reaches/0,
      fun bind_of_a_relative_path_starts_at_the_working_directory/0,
      fun bind_refusals/0,
      fun unmount_removes_exactly_one_entry/0,
      fun the_table_holds_at_most_64_entries/0,
      fun an_ended_grant_marks_every_entry_of_it_ended/0,
      fun a_grant_ended_while_the_process_was_down_ends_on_restart/0,
      fun a_malformed_request_answers_einval_and_changes_nothing/0,
      fun a_facet_mount_reads_the_registry_at_use/0,
      fun a_facet_entry_takes_the_lesser_of_its_rights_and_its_grants/0,
      fun a_facet_grant_that_ends_leaves_the_table_and_survives_a_restart/0,
      fun facets_mount_only_where_granted/0,
      fun the_system_domain_trees_mount_at_their_places/0,
      fun an_own_tree_mounts_its_grant_at_its_place/0,
      fun the_packages_place_is_the_system_domains_alone/0,
      fun facet_mount_refusals/0,
      fun a_media_facet_entry_follows_no_link/0]}.

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
    persistent_term:erase(erx_connections_app),
    flush().

table() -> erx_ns_prim_stub:erx_mounts().

grant() -> spawn(fun() -> receive stop -> ok end end).

boot_table_until_a_change() ->
    ?assertEqual(undefined, persistent_term:get(erx_ns, undefined)),
    ?assertEqual([?RELEASE], table()).

mount_adds_a_grant_entry() ->
    Grant = grant(),
    ?assertEqual(ok, erx_ns:mount({Grant, <<"tmp">>, rw}, <<"/tmp/">>, [rw])),
    ?assertEqual([?RELEASE, #{point => [<<"tmp">>], provider => {grant, Grant, <<"tmp">>}, root => [],
                              rights => rw}], persistent_term:get(erx_ns)),
    ?assertEqual(ok, erx_ns:mount({Grant, <<"t">>, rw}, "/a//b", [])),
    ?assertMatch([_, _, #{point := [<<"a">>, <<"b">>], rights := ro}], table()).

mount_refusals() ->
    Grant = grant(),
    ok = erx_ns:mount({Grant, <<"tmp">>, rw}, <<"/tmp">>, [rw]),
    Before = table(),
    Long = binary:copy(<<"n">>, 256),
    [?assertEqual({error, Reason}, erx_ns:mount(Source, Point, Options))
     || {Reason, Source, Point, Options} <-
            [{eexist, {Grant, <<"tmp">>, rw}, <<"/tmp/">>, []},
             {einval, {Grant, <<"a/b">>, rw}, <<"/x">>, []},
             {einval, {Grant, <<"..">>, rw}, <<"/x">>, []},
             {einval, {Grant, <<>>, rw}, <<"/x">>, []},
             {einval, {Grant, rw}, <<"/x">>, []},
             {einval, {Grant, <<"t">>, rw}, <<"/x">>, [rw, ro]},
             {einval, {Grant, <<"t">>, rw}, <<"/x">>, [{tree, <<"t">>}]},
             {einval, {Grant, t, rw}, <<"/x">>, []},
             {einval, {Grant, "t", rw}, <<"/x">>, []},
             {einval, {Grant, <<"t">>, rw}, <<"/x">>, [{tree, <<"t">>}, rw]},
             {einval, {Grant, <<"t">>, rw}, <<"x">>, []},
             {einval, {Grant, <<"t">>, rw}, <<"/a/../b">>, []},
             {einval, {Grant, <<"t">>, rw}, <<"/a/./b">>, []},
             {einval, {Grant, <<"t">>, rw}, <<"/a", 0, "b">>, []},
             {einval, {Grant, <<"t">>, rw}, <<"/", 16#ff>>, []},
             {einval, not_a_pid, <<"/x">>, [{tree, <<"t">>}]},
             {einval, {not_a_pid, <<"t">>, rw}, <<"/x">>, []},
             {einval, Grant, <<"/x">>, [{tree, <<"t">>}]},
             {einval, {Grant, <<"t">>, bogus}, <<"/x">>, []},
             {einval, {remote_pid(), <<"t">>, rw}, <<"/x">>, []},
             {enametoolong, {Grant, <<"t">>, rw}, <<"/", Long/binary>>, []},
             {enametoolong, {Grant, <<"t">>, rw}, iolist_to_binary(lists:duplicate(257, <<"/n">>)), []}]],
    ?assertEqual(Before, table()).

%% A grant pid's mount names the grant as {Pid, Tree, Rights}, the rights it was started with,
%% and its entry takes the lesser of those and the rights its options ask, as a facet's
%% entry does (docs/design-files.md, "Rights beneath an entry"): an rx mount of an rw
%% grant is ro, so a file written through the grant never runs through the entry (F6),
%% and only an rx grant gives an rx entry. A bind of the entry keeps the lowered rights.
a_grant_entry_takes_the_lesser_of_its_rights_and_its_grants() ->
    Grant = grant(),
    [ok = erx_ns:mount({Grant, <<"t">>, Granted}, Point, [Asked])
     || {Point, Granted, Asked} <- [{<<"/x">>, rw, rx}, {<<"/w">>, rw, rw}, {<<"/r">>, ro, rw},
                                    {<<"/e">>, rx, rx}, {<<"/o">>, rx, ro}]],
    ok = erx_ns:bind(<<"/x">>, <<"/b">>),
    ?assertEqual([{[<<"x">>], ro}, {[<<"w">>], rw}, {[<<"r">>], ro}, {[<<"e">>], rx}, {[<<"o">>], ro},
                  {[<<"b">>], ro}],
                 [{Point, Rights} || #{point := Point, provider := {grant, Pid, _}, rights := Rights} <- table(),
                                     Pid =:= Grant]).

bind_roots_at_the_place_from_reaches() ->
    Grant = grant(),
    ok = erx_ns:mount({Grant, <<"tmp">>, rw}, <<"/tmp">>, [rw]),
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
    ok = erx_ns:mount({Grant, <<"tmp">>, rw}, <<"/tmp">>, [rw]),
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
    ok = erx_ns:mount({Grant, <<"tmp">>, rw}, <<"/tmp">>, [rw]),
    ok = erx_ns:bind(<<"/tmp/a">>, <<"/b">>, [ro]),
    ok = erx_ns:mount({Other, <<"o">>, rw}, <<"/o">>, []),
    Grant ! stop,
    wait_down(Grant),
    ?assertMatch([#{point := [], provider := release}, #{point := [<<"tmp">>], provider := ended, rights := rw},
                  #{point := [<<"b">>], provider := ended, root := [<<"a">>]},
                  #{point := [<<"o">>], provider := {grant, Other, <<"o">>}}], settled()),
    %% The ended entry stays until it is unmounted, and a later mount at its point
    %% after that holds the new grant.
    ?assertEqual({error, eexist}, erx_ns:mount({Other, <<"tmp">>, rw}, <<"/tmp">>, [])),
    ok = erx_ns:unmount(<<"/tmp">>),
    ok = erx_ns:mount({Other, <<"tmp">>, rw}, <<"/tmp">>, []),
    ?assertMatch(#{provider := {grant, Other, <<"tmp">>}}, lists:last(table())).

a_grant_ended_while_the_process_was_down_ends_on_restart() ->
    Grant = grant(),
    ok = erx_ns:mount({Grant, <<"tmp">>, rw}, <<"/tmp">>, [rw]),
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
     || Request <- [nonsense, {mount, <<"/x">>, {self(), <<"t">>, rw}, bad}, {bind, 1, 2, []}, {unmount, {}},
                    {mount, <<"/x">>, {self(), <<"t">>, rw}, [rw | tail]}]],
    ?assertEqual(undefined, persistent_term:get(erx_ns, undefined)),
    ?assert(is_process_alive(whereis(erx_ns))).

%% The app's package, a package-shaped file (a header block, the compact fixture image
%% and its tree, ERX_VERITY_CASES' "package"), served as clock.app at the root of an rx
%% grant of the tree data, the session's packages facet, as the storage volume's
%% packages grant answers it, observed by the case; and the
%% app's record naming it there with its layout, as the session's agent holds it.
app_package(Bytes) ->
    {ok, Grant, _} = erx_fs:start_link(erx_fs_test_tree, [{observer, self()}, {name, <<"data">>},
                                                      {file, <<"clock.app">>, Bytes}], rx),
    unlink(Grant),
    %% The grant's start asks the tree's root once, before it answers.
    [root] = tree_calls(),
    persistent_term:put({erx, facets}, {1, #{packages => {?ERX_SERVICE_FILES, {Grant, <<"data">>, rx}}}}),
    {_, Layout} = package(),
    persistent_term:put(erx_connections_app, {ok, #{place => {packages, [<<"clock.app">>]}, layout => Layout,
                                                   start => {applications, [<<"clock">>]}}}),
    Grant.

package() ->
    Dir = os:getenv("ERX_VERITY_CASES"),
    {ok, [{"package", Layout}]} = file:consult(filename:join(Dir, "verity.terms")),
    {ok, Bytes} = file:read_file(filename:join(Dir, "package.img")),
    {Bytes, Layout}.

flip_byte(Bytes, Offset) ->
    <<Before:Offset/binary, Byte, After/binary>> = Bytes,
    <<Before/binary, (Byte bxor 16#10), After/binary>>.

%% The callbacks the grant's tree saw since the last call.
tree_calls() ->
    receive {tree_call, Callback} -> [Callback | tree_calls()] after 0 -> [] end.

%% {erofs, app} mounts the session's own package from its record: erx_ns's process walks
%% the record's name on the record's facet to a fid of its own, and the reader reads the
%% image through it, every block checked, so a file below the mount reads as the image
%% holds it. The entry is rx, as asked.
an_app_mount_reads_the_package_through_its_record() ->
    {Bytes, _} = package(),
    _ = app_package(Bytes),
    ?assertEqual(ok, erx_ns:mount({erofs, app}, <<"/app">>, [rx])),
    [_, #{point := [<<"app">>], provider := {erofs, Fs}, root := [], rights := rx}] = table(),
    ?assertEqual({ok, [<<"b">>]}, erx_erofs:list_dir(Fs, [<<"a">>])),
    [{regular, Names, Size, Seed} | _] = [Entry || {regular, _, _, _} = Entry <- erx_erofs_tests:expected()],
    ?assertEqual({ok, erx_erofs_tests:contents(Size, Seed)}, erx_erofs:read_file(Fs, Names)),
    ?assertEqual(ok, erx_ns:unmount(<<"/app">>)),
    ?assertEqual(ok, erx_ns:mount({erofs, app}, <<"/app">>, [])),
    ?assertMatch([_, #{point := [<<"app">>], rights := ro}], table()).

%% The app mount rests on the grant its fid came through: rx only through a grant whose
%% facet carries rx, so an rx mount through an ro or rw packages grant is refused with
%% eacces before the grant is walked and before the table changes, and the same grant
%% mounts the image ro.
an_rx_app_mount_needs_an_rx_grant() ->
    {Bytes, _} = package(),
    Grant = app_package(Bytes),
    [begin
         persistent_term:put({erx, facets}, {1, #{packages => {?ERX_SERVICE_FILES, {Grant, <<"data">>, Rights}}}}),
         ?assertEqual({error, eacces}, erx_ns:mount({erofs, app}, <<"/app">>, [rx])),
         ?assertEqual(undefined, persistent_term:get(erx_ns, undefined)),
         ?assertEqual([], tree_calls())
     end || Rights <- [ro, rw]],
    ?assertEqual(ok, erx_ns:mount({erofs, app}, <<"/app">>, [])),
    ?assertMatch([_, #{point := [<<"app">>], rights := ro}], table()).

%% A flipped bit in the package's image fails the mount with eio before the table
%% changes: the superblock's block does not match its tree.
an_app_mount_of_a_changed_package_answers_eio() ->
    {Bytes, #{image_offset := Offset}} = package(),
    _ = app_package(flip_byte(Bytes, Offset + 1024 + 5)),
    register(erx_ns_log, self()),
    ?assertEqual({error, eio}, erx_ns:mount({erofs, app}, <<"/app">>, [rx])),
    unregister(erx_ns_log),
    ?assertEqual(undefined, persistent_term:get(erx_ns, undefined)),
    ?assertMatch([{log, ["erx_ns: image: ", _]} | _], logged()).

%% No form of the mount takes a layout or an image from its caller: an opened image, a
%% place with a layout and a source other than app are malformed, as is rw; a session
%% with no record is refused with enoent. Nothing reaches the table.
app_mount_refusals() ->
    {Bytes, Layout} = package(),
    _ = app_package(Bytes),
    {ok, Image} = erx_erofs_tests:open(erx_erofs_tests:fixture("compact")),
    [?assertEqual({error, Reason}, erx_ns:mount(Source, To, Options))
     || {Reason, Source, To, Options} <-
            [{einval, {erofs, Image}, <<"/x">>, []},
             {einval, {erofs, {layout, {packages, [<<"clock.app">>]}, Layout}}, <<"/x">>, [rx]},
             {einval, {erofs, {file, <<"/packages/clock.app">>, Layout}}, <<"/x">>, [rx]},
             {einval, {erofs, app}, <<"/x">>, [rw]},
             {einval, {erofs, app}, <<"/x">>, [{tree, <<"t">>}]},
             {einval, {erofs, app}, <<"/x">>, [ro, rx]},
             {einval, {erofs, app}, <<"x">>, [rx]},
             {eexist, {erofs, app}, <<"/">>, [rx]}]],
    persistent_term:erase(erx_connections_app),
    ?assertEqual({error, enoent}, erx_ns:mount({erofs, app}, <<"/x">>, [rx])),
    ?assertEqual(undefined, persistent_term:get(erx_ns, undefined)).

%% The mount's fid lives as long as an entry holds the image: a bind of the mount keeps
%% it open past the mount's unmount, and the grant's tree sees the file closed once the
%% last entry goes.
the_fid_closes_when_the_last_entry_of_the_image_goes() ->
    {Bytes, _} = package(),
    _ = app_package(Bytes),
    ?assertEqual(ok, erx_ns:mount({erofs, app}, <<"/app">>, [rx])),
    ?assert(lists:member(open, tree_calls())),
    ?assertEqual(ok, erx_ns:bind(<<"/app">>, <<"/b">>)),
    ?assertEqual(ok, erx_ns:unmount(<<"/app">>)),
    _ = sys:get_state(erx_ns),
    ?assertNot(lists:member(clunk, tree_calls())),
    [_, #{point := [<<"b">>], provider := {erofs, Fs}}] = table(),
    ?assertEqual({ok, [<<"b">>]}, erx_erofs:list_dir(Fs, [<<"a">>])),
    ?assertEqual(ok, erx_ns:unmount(<<"/b">>)),
    _ = sys:get_state(erx_ns),
    ?assert(lists:member(clunk, tree_calls())).

%% A facet's mount holds the facet's name, not a pid, and a resolution reads the domain's
%% facet registry, the term {erx, facets}, as it uses the table: each entry of the facet,
%% binds included, is on the grant the registry holds now, on the tree the registry holds
%% with it and never one the mount names, a re-grant serves the next
%% lookup, and with no grant, or a value with no tree, the entries answer eio. The
%% process keeps no monitor for a facet, so a grant of another domain never meets
%% is_process_alive/1.
a_facet_mount_reads_the_registry_at_use() ->
    ?assertEqual(ok, erx_ns:mount({facet, data}, <<"/data">>, [rw])),
    ok = erx_ns:bind(<<"/data/sub">>, <<"/s">>, [ro]),
    ?assertMatch([_, #{point := [<<"data">>], provider := {facet, data}, root := [], rights := rw},
                  #{point := [<<"s">>], provider := {facet, data}, root := [<<"sub">>], rights := ro}],
                 table()),
    ?assertMatch([_, #{provider := ended}, #{provider := ended}], at_use()),
    [First, Second] = [grant(), grant()],
    persistent_term:put({erx, facets}, {1, #{data => {?ERX_SERVICE_FILES, {First, <<"data">>, rw}}}}),
    ?assertMatch([_, #{provider := {grant, First, <<"data">>}, rights := rw},
                  #{provider := {grant, First, <<"data">>}, root := [<<"sub">>], rights := ro}], at_use()),
    persistent_term:put({erx, facets}, {1, #{data => {?ERX_SERVICE_FILES, {Second, <<"data">>, rw}},
                                             other => {?ERX_SERVICE_FILES, {First, <<"data">>, rw}}}}),
    ?assertMatch([_, #{provider := {grant, Second, _}}, #{provider := {grant, Second, _}}], at_use()),
    Remote = remote_pid(),
    persistent_term:put({erx, facets}, {1, #{data => {?ERX_SERVICE_FILES, {Remote, <<"data">>, rw}}}}),
    ?assertMatch([_, #{provider := {grant, Remote, _}}, #{provider := {grant, Remote, _}}], at_use()),
    persistent_term:put({erx, facets}, {1, #{data => {?ERX_SERVICE_FILES, {First, <<"volume">>, rw}}}}),
    ?assertMatch([_, #{provider := {grant, First, <<"volume">>}}, #{provider := {grant, First, <<"volume">>}}],
                 at_use()),
    persistent_term:put({erx, facets}, {1, #{data => {?ERX_SERVICE_FILES, First}}}),
    ?assertMatch([_, #{provider := ended}, #{provider := ended}], at_use()),
    ?assertEqual(#{}, maps:get(monitors, sys:get_state(erx_ns))).

%% An entry's rights only lower its grant's: a resolution gives each entry of a facet the
%% lesser of the rights its mount asked and those the registry's facet carries, where ro
%% lies below rw and below rx, and rw and rx meet at ro. So /x, an rx entry over the rw
%% data grant, writes nothing and runs nothing (F6), and an rx entry runs only over an rx
%% grant. A registry value without rights, which no files facet is, answers eio.
a_facet_entry_takes_the_lesser_of_its_rights_and_its_grants() ->
    [ok = erx_ns:mount({facet, data}, Point, [Rights])
     || {Point, Rights} <- [{<<"/data">>, rw}, {<<"/x">>, rx}, {<<"/r">>, ro}]],
    ok = erx_ns:bind(<<"/x">>, <<"/b">>),
    Grant = grant(),
    Rights = fun(GrantRights) ->
                     persistent_term:put({erx, facets}, {1, #{data => {?ERX_SERVICE_FILES, {Grant, <<"data">>, GrantRights}}}}),
                     [Of || #{provider := {grant, Pid, <<"data">>}, rights := Of} <- at_use(), Pid =:= Grant]
             end,
    ?assertEqual([rw, ro, ro, ro], Rights(rw)),
    ?assertEqual([ro, ro, ro, ro], Rights(ro)),
    ?assertEqual([ro, rx, ro, rx], Rights(rx)),
    persistent_term:put({erx, facets}, {1, #{data => {?ERX_SERVICE_FILES, Grant}}}),
    ?assertMatch([_, #{provider := ended}, #{provider := ended}, #{provider := ended}, #{provider := ended}],
                 at_use()).

%% A facet's grant that ends changes nothing in the table: the next lookup still sends to
%% it and the client's own monitor on it answers eio, until the registry holds the
%% re-grant. A restarted process keeps the facet's entries as the term holds them.
a_facet_grant_that_ends_leaves_the_table_and_survives_a_restart() ->
    ok = erx_ns:mount({facet, data}, <<"/data">>, [rw]),
    Grant = grant(),
    persistent_term:put({erx, facets}, {1, #{data => {?ERX_SERVICE_FILES, {Grant, <<"data">>, rw}}}}),
    Grant ! stop,
    wait_down(Grant),
    Before = settled(),
    ?assertMatch([_, #{provider := {facet, data}}], Before),
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
%% nothing: so an app's session, which holds packages and system for its own package,
%% mounts neither (docs/design-packaging.md, "An app's session"). With data granted
%% and its grant not yet installed, /data is the facet's mount, which answers eio, and
%% never falls through to the root beneath it; the media entry carries no nofollow mark
%% until a facet of the media interface is installed, since the mark comes with it.
facets_mount_only_where_granted() ->
    ?assertEqual(ok, erx_ns:mount_facets([])),
    ?assertEqual(ok, erx_ns:mount_facets([echo, packages, system])),
    ?assertEqual([?RELEASE], at_use()),
    ?assertEqual(ok, erx_ns:mount_facets([echo, data, media])),
    ?assertEqual([?RELEASE, #{point => [<<"data">>], provider => ended, root => [], rights => rw},
                  #{point => [<<"media">>], provider => ended, root => [], rights => rw}],
                 at_use()).

%% The system domain's files services, apps, start and machine, have their places too:
%% a session that holds their facets mounts each where the system domain mounts its own
%% grant of it (docs/design-shell.md, "Interfaces"). The apps tree mounts at /apps, read
%% and written as /data is (docs/design-packaging.md, "/apps"), and the start service's
%% tree at /etc/start, so that /apps holds apps alone.
the_system_domain_trees_mount_at_their_places() ->
    ?assertEqual(ok, erx_ns:mount_facets([apps, inspect, machine, start])),
    ?assertEqual([?RELEASE, #{point => [<<"apps">>], provider => ended, root => [], rights => rw},
                  #{point => [<<"machine">>], provider => ended, root => [], rights => rw},
                  #{point => [<<"etc">>, <<"start">>], provider => ended, root => [], rights => rw}],
                 at_use()).

%% A tree the domain serves itself mounts its own grant at the place of the facet of its
%% name, and a second mount, an instance restarted after the first one's grant ended,
%% replaces the entry the first left there; each entry is on the tree its grant's handle
%% carries, not on one the place names. A name with no place is refused.
an_own_tree_mounts_its_grant_at_its_place() ->
    First = grant(),
    ?assertEqual(ok, erx_ns:mount_own(machine, {First, <<"machine">>, rw})),
    ?assertEqual([?RELEASE, #{point => [<<"machine">>], provider => {grant, First, <<"machine">>}, root => [],
                              rights => rw}], settled()),
    First ! stop,
    Second = grant(),
    ?assertEqual(ok, erx_ns:mount_own(machine, {Second, <<"volume">>, rw})),
    ?assertEqual([?RELEASE, #{point => [<<"machine">>], provider => {grant, Second, <<"volume">>}, root => [],
                              rights => rw}], settled()),
    ?assertError({badmatch, none}, erx_ns:mount_own(echo, {Second, <<"echo">>, rw})).

%% The packages tree has a place only in the system domain (packages_place/0), at
%% /packages, where the system domain alone mounts its grant (erx_domain_srv): a session
%% that holds the packages facet, as every app's session does, mounts nothing there,
%% whatever else it holds (docs/design-packaging.md, "Where a package lies"). A tree a
%% session mounts has no system place.
the_packages_place_is_the_system_domains_alone() ->
    ?assertEqual({<<"/packages">>, [rw]}, erx_ns:packages_place()),
    ?assertEqual(ok, erx_ns:mount_facets([packages, system, data, apps, start, machine, line])),
    ?assertEqual([], [Entry || #{point := [<<"packages">> | _]} = Entry <- at_use()]).

%% A user's home lies at FreeBSD's paths, root's at /root and any other user's at
%% /home/NAME, and a name that is not one path name has none, so no name places a
%% home above /home (docs/design-files.md, "A user's home").
home_places_test() ->
    Options = [rw],
    ?assertEqual({ok, {<<"/root">>, Options}}, erx_ns:home_place(<<"root">>)),
    ?assertEqual({ok, {<<"/home/clock">>, Options}}, erx_ns:home_place(<<"clock">>)),
    [?assertEqual({error, einval}, erx_ns:home_place(Name))
     || Name <- [<<>>, <<".">>, <<"..">>, <<"a/b">>, <<"/root">>, <<"../root">>, <<"a", 0, "b">>]].

%% A facet is named by an atom, and its mount takes a grant's options; a pid of another
%% domain is never mounted directly, only through a facet.
facet_mount_refusals() ->
    [?assertEqual({error, Reason}, erx_ns:mount(Source, Point, Options))
     || {Reason, Source, Point, Options} <-
            [{einval, {facet, <<"data">>}, <<"/data">>, [{tree, <<"data">>}]},
             {einval, {facet, data}, <<"/data">>, [{tree, <<"data">>}, rw]},
             {einval, {facet, data}, <<"/data">>, [{tree, <<"data">>}, rw, ro]},
             {einval, {facet, data}, <<"data">>, [{tree, <<"data">>}]},
             {einval, {remote_pid(), <<"data">>, rw}, <<"/data">>, [rw]}]],
    ?assertEqual(undefined, persistent_term:get(erx_ns, undefined)).

%% An entry on a facet the registry holds as one of the media interface carries the
%% nofollow mark, which erx_facets:table/1 derives at each resolution from the facet's
%% interface number, never from its name, a grant's tree, a mount's options or a stored
%% key: every mount of such a facet, under any name, wherever it lies and whatever rights
%% it names, every bind of it or of a volume under it, and a program's table
%% made by change/2 carry the mark as a resolution reads them; an entry mounted before
%% its facet is installed is ended until then; and no other entry carries it, neither a
%% files facet named media nor a mount by pid of a tree named media
%% (docs/design-drives.md, "Links and rights"). The resolver answers eacces where it
%% would follow a link of a marked entry (erx_path_tests).
a_media_facet_entry_follows_no_link() ->
    Granted = grant(),
    ok = erx_ns:mount({facet, media}, <<"/media">>, [rw]),
    ok = erx_ns:mount({facet, media}, <<"/elsewhere">>, []),
    ok = erx_ns:bind(<<"/media/disk0/s1">>, <<"/stick">>),
    ok = erx_ns:bind(<<"/media">>, <<"/m">>, [ro]),
    ok = erx_ns:mount({facet, usb}, <<"/usb">>, [rw]),
    ok = erx_ns:mount({facet, data}, <<"/data">>, [rw]),
    ok = erx_ns:bind(<<"/data">>, <<"/d">>),
    ok = erx_ns:mount({grant(), <<"media">>, rw}, <<"/own">>, [rw]),
    {ok, Program} = erx_ns:change({bind, <<"/media/disk0">>, <<"/p">>, [ro]}, table()),
    Marked = fun(Table) -> [Point || #{point := Point, nofollow := true} <- Table] end,
    ?assertEqual({[], [], []}, {Marked(table()), Marked(Program), Marked(at_use())}),
    persistent_term:put({erx, facets}, {1, #{media => {?ERX_SERVICE_FILES, {Granted, <<"media">>, rw}},
                                             usb => {?ERX_SERVICE_FILES, {grant(), <<"media">>, rw}}}}),
    ?assertEqual([], Marked(at_use())),
    persistent_term:put({erx, facets}, {2, #{media => {?ERX_SERVICE_MEDIA, {Granted, <<"media">>, rw}},
                                             usb => {?ERX_SERVICE_MEDIA, {grant(), <<"media">>, ro}},
                                             data => {?ERX_SERVICE_FILES, {grant(), <<"data">>, rw}}}}),
    Expected = [[<<"media">>], [<<"elsewhere">>], [<<"stick">>], [<<"m">>], [<<"usb">>]],
    ?assertEqual(Expected, Marked(at_use())),
    ?assertMatch([#{provider := {grant, Granted, <<"media">>}, nofollow := true}],
                 [Entry || #{point := [<<"media">>]} = Entry <- at_use()]),
    ?assertEqual(Expected ++ [[<<"p">>]], Marked(erx_facets:table(Program))),
    ?assertEqual(Expected ++ [[<<"p">>]], Marked(erx_facets:program_table(erx_facets:program(Program)))).

%% The table as a resolution uses it, prim_file:erx_table/0's.
at_use() ->
    erx_facets:table(table()).

%% The table erx_facets:table/1 makes of Table over the registry Registry, which the
%% case leaves holding nothing.
with_registry(Table, Registry) ->
    persistent_term:put({erx, facets}, {1, Registry}),
    try erx_facets:table(Table) after persistent_term:erase({erx, facets}) end.

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

%% Every pair of the rights files_rights defines is ordered, so a facet entry asked any
%% of them over a grant of any of them is on the grant, and a member the ABI gains fails
%% here until erx_path:lesser/2 orders it; a grant of rights outside the ABI answers eio.
every_pair_of_the_abis_rights_is_ordered_test() ->
    Members = [Rights || {Rights, _} <- ?ERX_FILES_RIGHTS_MEMBERS],
    Pid = self(),
    Entry = fun(Asked) -> #{point => [<<"d">>], provider => {facet, data}, root => [], rights => Asked} end,
    [?assertMatch([#{provider := {grant, Pid, <<"data">>}}],
                  with_registry([Entry(Asked)], #{data => {?ERX_SERVICE_FILES, {Pid, <<"data">>, Granted}}}))
     || Asked <- Members, Granted <- Members],
    ?assertMatch([#{provider := ended}],
                 with_registry([Entry(rw)], #{data => {?ERX_SERVICE_FILES, {Pid, <<"data">>, bogus}}})).
