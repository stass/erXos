%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the media tree (docs/design-drives.md, "The media tree"): its status
%% text, its refusals, its qids and its files, read through a grant of the tree over
%% drive 0, whose facet answers a fake window proxy (erx_media_volume_tests) over a
%% medium held as one binary. ERX_FAT_IMAGES: fat16.img and fat32.img, fsimg's
%% (test/fixtures/fat_volumes.rb).

-module(erx_media_tree_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

%% The stand-in for erx_media_sup, under which the drive processes start.
-export([init/1]).

-import(erx_media_volume_tests, [image/1, proxy/2, mbr/2, sectors/1, facet/1]).

-define(NOFID, 16#ffffffff).
-define(START, 2048).
-define(NODE_BITS, 40).
%% A grant's reply bound: the host may be starved of CPU for seconds, so only a grant
%% that is alive and silent reaches it.
-define(REPLY_BOUND, 30000).

-doc false.
init(stand_in) ->
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, []}}.

%% Fixtures --------------------------------------------------------------

%% The tree over drive 0, whose medium Medium a fake proxy serves, and a grant of it
%% attached at fid 1. The registry holds drive 0 as a stand-in facet that answers the
%% proxy, and erx_media_sup is a stand-in supervisor with no child. The grant is rw, as
%% the manifest grants root's session its media, so every refusal is the tree's own.
start(Medium) ->
    ok = erx_media_volume:new_mounts(),
    {ok, Sup} = supervisor:start_link({local, erx_media_sup}, ?MODULE, stand_in),
    Proxy = proxy(Medium, ok),
    Facet = spawn_link(fun() -> facet(Proxy) end),
    ok = erx_facets:install(#{{drive, 0} => {?ERX_SERVICE_DRIVE, Facet}}),
    {ok, Grant, _} = erx_fs:start_link(erx_media_tree, media, rw),
    [unlink(Pid) || Pid <- [Sup, Proxy, Facet, Grant]],
    {ok, _} = call(Grant, {attach, 1, ?NOFID, <<"root">>, <<"media">>, 0}),
    #{grant => Grant, proxy => Proxy, ended => [Grant, Sup, Facet, Proxy]}.

stop(#{ended := Pids}) ->
    lists:foreach(fun kill_and_wait/1, Pids).

kill_and_wait(Pid) ->
    Monitor = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok end.

%% A request answered within the reply bound, or the case fails with the request.
call(Grant, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), Request},
    receive
        {erx_9p, Alias, Reply} -> Reply
    after ?REPLY_BOUND ->
        erlang:error({no_reply, Request})
    end.

%% The names of the directory fid Fid names, opened as Spare.
names(Grant, Fid, Spare) ->
    [Name || {_Qid, _Offset, _Type, Name} <- entries(Grant, Fid, Spare)].

entries(Grant, Fid, Spare) ->
    {ok, []} = call(Grant, {walk, Fid, Spare, []}),
    {ok, _, _} = call(Grant, {lopen, Spare, ?ERX_P9_O_DIRECTORY}),
    {ok, Entries} = call(Grant, {readdir, Spare, 0, 4096}),
    ok = call(Grant, {clunk, Spare}),
    Entries.

%% The file at Path's bytes, read through fid Spare.
contents(Grant, Path, Spare) ->
    {ok, _} = call(Grant, {walk, 1, Spare, Path}),
    {ok, _, _} = call(Grant, {lopen, Spare, 0}),
    Read = call(Grant, {read, Spare, 0, 65536}),
    ok = call(Grant, {clunk, Spare}),
    Read.

%% The qid path of the last name of Path.
qid_path(Grant, Path, Spare) ->
    {ok, Qids} = call(Grant, {walk, 1, Spare, Path}),
    ok = call(Grant, {clunk, Spare}),
    {_Type, _Version, QidPath} = lists:last(Qids),
    QidPath.

mount_number(QidPath) -> QidPath bsr ?NODE_BITS.

%% Once drive 0's process holds no medium, its proxy's end taken: polled every 20 ms,
%% at most 250 times.
held_none() -> held_none(250).

held_none(0) ->
    timeout;
held_none(Rounds) ->
    [Drive] = [Pid || {{drive, 0}, Pid, _, _} <- supervisor:which_children(erx_media_sup)],
    case sys:get_state(Drive) of
        #{medium := none} -> ok;
        #{} -> timer:sleep(20), held_none(Rounds - 1)
    end.

two_volumes() ->
    [Fat16, Fat32] = [image("fat16.img"), image("fat32.img")],
    Second = ?START + sectors(Fat16),
    mbr([{16#0e, ?START, sectors(Fat16)}, {16#0c, Second, sectors(Fat32)}], [{?START, Fat16}, {Second, Fat32}]).

%% Cases -----------------------------------------------------------------

%% The tree's name is `media`, the name every mount of the media facet asks.
the_tree_is_named_media_test() ->
    ?assertMatch({ok, <<"media">>, root, _}, erx_media_tree:root(media)).

%% A value a medium supplies reaches status through the field escape: a backslash, a
%% tab and a CP437 byte in a label stay on the label's one line.
status_escapes_what_the_medium_supplies_test() ->
    Label = <<"A\\B\tC", 16#82>>,
    Table = {mbr, [{#{number => 1, length => 100}, self()}, {#{number => 2, length => 0}, extended}], 0},
    Outcome = fun(_Pid) -> #{format => msdosfs, fat => 16, label => Label, serial => 16#1234, mount => rw} end,
    Text = erx_media_tree:status({ok, #{sectors => 4096}}, Table, Outcome),
    Lines = [binary:split(Line, <<"\t">>) || Line <- binary:split(Text, <<"\n">>, [global, trim])],
    ?assertEqual([[<<"medium">>, <<"ready">>], [<<"transport">>, <<"unknown">>], [<<"sectors">>, <<"4096">>],
                  [<<"flush">>, <<"unknown">>], [<<"table">>, <<"mbr">>], [<<"s1">>, <<"msdosfs">>],
                  [<<"s1_mount">>, <<"rw">>], [<<"s1_sectors">>, <<"100">>], [<<"s1_fat">>, <<"16">>],
                  [<<"s1_label">>, <<"A\\\\B\\tC\\x82">>], [<<"s1_serial">>, <<"4660">>],
                  [<<"s2">>, <<"extended">>], [<<"s2_mount">>, <<"none extended">>], [<<"unserved">>, <<"0">>]],
                 Lines),
    ?assertEqual(<<"medium\tnone\n">>, erx_media_tree:status(none, none, Outcome)).

%% A read-only volume shows `ro` and, on a line of its own, the reason the writable rule
%% gave, the same line erx_media_volume:ro_reason/1 makes for the mount's log line.
status_names_why_a_volume_is_read_only_test() ->
    Table = {none, [{#{number => 1, length => 100}, self()}], 0},
    Outcome = fun(_Pid) -> #{format => msdosfs, fat => 32, mount => {ro, {also, 'hfs+'}}} end,
    Lines = binary:split(erx_media_tree:status({ok, #{sectors => 100}}, Table, Outcome), <<"\n">>, [global, trim]),
    ?assertEqual([<<"s1\tmsdosfs">>, <<"s1_mount\tro">>, <<"s1_ro_reason\ta hfs+ signature is also on the volume">>,
                  <<"s1_sectors\t100">>, <<"s1_fat\t32">>],
                 lists:sublist(Lines, 6, 5)).

%% A rename between two volumes answers exdev from the two nodes alone: neither
%% volume's process is asked.
exdev_is_decided_before_any_volume_is_asked_test() ->
    Asked = fun() -> receive Message -> exit({asked, Message}) end end,
    [One, Two] = [spawn(Asked), spawn(Asked)],
    Node = fun(Pid) -> {volume, Pid, dir_node, dir, 1} end,
    ?assertEqual({error, exdev}, erx_media_tree:rename(Node(One), <<"a">>, Node(Two), <<"b">>, media)),
    ?assertEqual({error, erofs}, erx_media_tree:rename(Node(One), <<"a">>, Node(One), <<"b">>, media)),
    ?assertEqual([true, true], [is_process_alive(Pid) || Pid <- [One, Two]]),
    [exit(Pid, kill) || Pid <- [One, Two]].

%% Nothing is written: a change of the tree's own entries answers eacces, one inside a
%% volume erofs, and ctl takes eject alone.
the_tree_refuses_every_change_test() ->
    Volume = {volume, self(), dir_node, dir, 1},
    Tree = [root, {drive, 0}],
    [?assertEqual({error, eacces}, erx_media_tree:make(Dir, <<"x">>, dir, media)) || Dir <- Tree],
    [?assertEqual({error, eacces}, erx_media_tree:unlink(Dir, <<"x">>, file, media)) || Dir <- Tree],
    ?assertEqual({error, erofs}, erx_media_tree:make(Volume, <<"x">>, dir, media)),
    ?assertEqual({error, erofs}, erx_media_tree:unlink(Volume, <<"x">>, file, media)),
    ?assertEqual({error, eacces}, erx_media_tree:rename(Volume, <<"a">>, {drive, 0}, <<"b">>, media)),
    ?assertEqual({error, eacces}, erx_media_tree:rename(root, <<"a">>, root, <<"b">>, media)),
    ?assertEqual({error, eacces}, erx_media_tree:open({status, 0}, ?ERX_P9_O_WRONLY, media)),
    ?assertEqual({error, eacces}, erx_media_tree:open({drive, 0}, ?ERX_P9_O_RDWR, media)),
    ?assertEqual({error, erofs}, erx_media_tree:open({volume, self(), file_node, file, 2}, ?ERX_P9_O_WRONLY, media)),
    ?assertEqual({error, erofs}, erx_media_tree:write({file, self(), file_node}, 0, <<"x">>, media)),
    ?assertEqual({error, enotsup}, erx_media_tree:write({ctl, 0}, 0, <<"eject">>, media)),
    ?assertEqual({error, enotsup}, erx_media_tree:write({ctl, 0}, 0, <<"eject\n">>, media)),
    [?assertEqual({error, einval}, erx_media_tree:write({ctl, 0}, 0, Command, media))
     || Command <- [<<"eject\n\n">>, <<"EJECT">>, <<" eject">>, <<>>]],
    [?assertEqual({error, Refused}, erx_media_tree:setattr(Target, #{size => 0}, media))
     || {Target, Refused} <- [{{node, Volume}, erofs}, {{node, {drive, 0}}, eacces},
                              {{open, {file, self(), file_node}}, erofs}, {{open, {text, <<>>}}, eacces}]].

%% ctl is reached as prim_file writes a file, by a create of the existing name: eject
%% answers enotsup and anything else einval; a create of any other name is refused.
ctl_takes_a_command_through_a_create_test() ->
    #{grant := Grant} = Tree = start(image("fat16.img")),
    try
        {ok, _} = call(Grant, {walk, 1, 2, [<<"disk0">>]}),
        {ok, _} = call(Grant, {walk, 2, 3, []}),
        ?assertMatch({ok, {0, 0, 3}, _}, call(Grant, {lcreate, 3, <<"ctl">>, ?ERX_P9_O_WRONLY bor ?ERX_P9_O_TRUNC, 8#644, 0})),
        ?assertEqual({error, enotsup}, call(Grant, {write, 3, 0, <<"eject\n">>})),
        ?assertEqual({error, einval}, call(Grant, {write, 3, 0, <<"format\n">>})),
        {ok, _} = call(Grant, {walk, 2, 4, []}),
        ?assertEqual({error, eacces}, call(Grant, {lcreate, 4, <<"new">>, ?ERX_P9_O_WRONLY, 8#644, 0}))
    after
        stop(Tree)
    end.

%% The tree's own nodes take the fixed paths of mount number 0; a volume's root is
%% path 0 of its own mount, and its files paths of that mount.
the_tree_s_own_qids_are_fixed_test() ->
    Qid = fun(Node) -> {ok, #{qid := Q}} = erx_media_tree:getattr(Node, media), Q end,
    ?assertEqual([{?ERX_P9_QTDIR, 0, 0}, {?ERX_P9_QTDIR, 0, 1}, {0, 0, 2}, {0, 0, 3}, {?ERX_P9_QTDIR, 0, 5},
                  {0, 0, 14}],
                 [Qid(Node) || Node <- [root, {drive, 0}, {status, 0}, {ctl, 0}, {drive, 1}, {status, 3}]]).

%% Two volumes and two mounts of one medium are distinct sets of files: their roots
%% and their files carry distinct mount numbers, never 0.
two_mounts_are_distinct_test() ->
    #{grant := Grant} = Tree = start(two_volumes()),
    try
        Roots = [qid_path(Grant, [<<"disk0">>, Volume], 2) || Volume <- [<<"s1">>, <<"s2">>]],
        Files = [qid_path(Grant, [<<"disk0">>, Volume, <<"hello.txt">>], 2) || Volume <- [<<"s1">>, <<"s2">>]],
        [One, Two] = [mount_number(Path) || Path <- Roots],
        ?assert(One > 0 andalso Two > 0 andalso One =/= Two),
        ?assertEqual([0, 0], [Path band (1 bsl ?NODE_BITS - 1) || Path <- Roots]),
        ?assertEqual([One, Two], [mount_number(Path) || Path <- Files]),
        {ok, _} = call(Grant, {walk, 1, 3, [<<"disk0">>]}),
        ?assertEqual(Roots, [Path || {{_, _, Path}, _, _, Name} <- entries(Grant, 3, 4), lists:member(Name, [<<"s1">>, <<"s2">>])]),
        %% The same medium inserted again is another mount.
        kill_and_wait(maps:get(proxy, Tree)),
        ok = held_none(),
        Again = proxy(two_volumes(), ok),
        unlink(Again),
        Facet = spawn(fun() -> facet(Again) end),
        ok = erx_facets:install(#{{drive, 0} => {?ERX_SERVICE_DRIVE, Facet}}),
        Remounted = qid_path(Grant, [<<"disk0">>, <<"s1">>, <<"hello.txt">>], 5),
        ?assert(mount_number(Remounted) > max(One, Two)),
        [kill_and_wait(Pid) || Pid <- [Facet, Again]]
    after
        stop(Tree)
    end.

%% Through the grant: the root lists disk0, disk0 lists every volume of its table by
%% its root's qid, one that mounted no files answering eio at its walk, and a
%% volume's directories and files read as fsimg wrote them.
list_and_read_through_the_tree_test() ->
    Fat16 = image("fat16.img"),
    Unknown = 64,
    Second = ?START + sectors(Fat16),
    #{grant := Grant} = Tree = start(mbr([{16#0e, ?START, sectors(Fat16)}, {16#0c, Second, Unknown}],
                                         [{?START, Fat16}, {Second, <<0:(Unknown * 512)/unit:8>>}])),
    try
        ?assertEqual([<<"disk0">>], names(Grant, 1, 2)),
        {ok, _} = call(Grant, {walk, 1, 3, [<<"disk0">>]}),
        Listed = entries(Grant, 3, 4),
        ?assertEqual([<<"status">>, <<"ctl">>, <<"s1">>, <<"s2">>], [Name || {_, _, _, Name} <- Listed]),
        {S1Qid, _, _, <<"s1">>} = lists:keyfind(<<"s1">>, 4, Listed),
        ?assertEqual({ok, [{?ERX_P9_QTDIR, 0, 1}, S1Qid]}, call(Grant, {walk, 1, 5, [<<"disk0">>, <<"s1">>]})),
        ?assertEqual({error, eio}, call(Grant, {walk, 3, 6, [<<"s2">>]})),
        ?assertEqual(lists:sort([<<"hello.txt">>, <<"empty">>, <<"sub">>]), lists:sort(names(Grant, 5, 7))),
        ?assertEqual({ok, <<"hello, stick\n">>}, contents(Grant, [<<"disk0">>, <<"s1">>, <<"hello.txt">>], 8)),
        ?assertEqual({ok, <<"deep\n">>}, contents(Grant, [<<"disk0">>, <<"s1">>, <<"sub">>, <<"Deeper">>, <<"x.TXT">>], 8)),
        {ok, Status} = contents(Grant, [<<"disk0">>, <<"status">>], 8),
        ?assertMatch({_, _}, binary:match(Status, <<"s2_mount\tnone unknown\n">>))
    after
        stop(Tree)
    end.

%% No node the tree presents is a link: every attribute is a directory's or a regular
%% file's, every listed entry a directory or a regular file, and no qid a symlink's.
no_node_is_a_link_test() ->
    #{grant := _} = Tree = start(image("fat16.img")),
    try
        {ok, <<"media">>, Root, _} = erx_media_tree:root(media),
        Kinds = lists:usort(kinds(Root)),
        ?assertEqual([{?ERX_P9_S_IFDIR, ?ERX_P9_DT_DIR}, {?ERX_P9_S_IFREG, ?ERX_P9_DT_REG}], Kinds)
    after
        stop(Tree)
    end.

%% The mode's type and the listing's type of every node under Dir, Dir itself
%% included as a directory.
kinds(Dir) ->
    {ok, #{mode := Mode, qid := {Type, _, _}}} = erx_media_tree:getattr(Dir, media),
    0 = Type band ?ERX_P9_QTSYMLINK,
    {ok, Listing} = erx_media_tree:open(Dir, 0, media),
    {ok, Entries} = erx_media_tree:readdir(Listing, 0, 4096, media),
    [{Mode band ?ERX_P9_S_IFMT, ?ERX_P9_DT_DIR}
     | lists:append([child(Dir, Name, DirentType) || {_Qid, _Offset, DirentType, Name} <- Entries])].

child(Dir, Name, DirentType) ->
    case erx_media_tree:walk(Dir, Name, media) of
        {ok, Node, {_, _, _}} when DirentType =:= ?ERX_P9_DT_DIR ->
            kinds(Node);
        {ok, Node, {Type, _, _}} ->
            0 = Type band ?ERX_P9_QTSYMLINK,
            {ok, #{mode := Mode}} = erx_media_tree:getattr(Node, media),
            [{Mode band ?ERX_P9_S_IFMT, DirentType}]
    end.

%% A stick removed while a read waits on it answers that read eio, not a hang, and
%% every request on its nodes from then on eio at once.
a_removed_stick_answers_eio_test() ->
    #{grant := Grant, proxy := Proxy} = Tree = start(image("fat16.img")),
    try
        {ok, _} = call(Grant, {walk, 1, 2, [<<"disk0">>, <<"s1">>, <<"sub">>, <<"Long File Name.dat">>]}),
        {ok, _, _} = call(Grant, {lopen, 2, 0}),
        {ok, _} = call(Grant, {walk, 1, 3, [<<"disk0">>, <<"s1">>]}),
        Proxy ! stall,
        Alias = alias([reply]),
        Grant ! {erx_9p, Alias, self(), {read, 2, 0, 4096}},
        ?assertEqual(waiting, receive {erx_9p, Alias, Early} -> {answered, Early} after 200 -> waiting end),
        exit(Proxy, kill),
        ?assertEqual({error, eio}, receive {erx_9p, Alias, Reply} -> Reply after ?REPLY_BOUND -> hung end),
        ?assertEqual({error, eio}, call(Grant, {read, 2, 0, 4096})),
        ?assertEqual({error, eio}, call(Grant, {walk, 3, 4, [<<"hello.txt">>]})),
        ?assertEqual({error, eio}, call(Grant, {getattr, 3, 16#7ff}))
    after
        stop(Tree)
    end.
