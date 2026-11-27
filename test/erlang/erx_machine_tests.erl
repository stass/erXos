%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The machine's end through the machine tree (docs/design-system.md, "A session's
%% request"): the ctl parse, the tree's answers, and the coordinator's one entry, with
%% a stand-in for init's stop, so no case ends the emulator.
-module(erx_machine_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

ctl_parse_test() ->
    ?assertEqual({ok, reset}, erx_machine_fs:parse(<<"reset">>)),
    ?assertEqual({ok, reset}, erx_machine_fs:parse(<<"reset\n">>)),
    ?assertEqual({ok, off}, erx_machine_fs:parse(<<"off">>)),
    ?assertEqual({ok, off}, erx_machine_fs:parse(<<"off\n">>)),
    [?assertEqual({error, einval}, erx_machine_fs:parse(Bytes))
     || Bytes <- [<<"trial">>, <<"trial\n">>, <<"reset\n\n">>, <<"Reset">>, <<"reset now">>, <<>>,
                  <<"\n">>, <<"off\r\n">>, <<"reset", 0>>, binary:copy(<<"r">>, 65536)]].

%% A write reaches the coordinator with the grant's principal and nothing else, and
%% answers its errno; a write that does not parse reaches no one.
ctl_write_test() ->
    Self = self(),
    Fs = fun(Answer) ->
                 #{principal => <<"clock">>,
                   request => fun(End, Principal) -> Self ! {asked, End, Principal}, Answer() end}
         end,
    ?assertEqual({ok, 6, 0}, erx_machine_fs:write(ctl, 0, <<"reset\n">>, Fs(fun() -> ok end))),
    ?assertEqual({asked, reset, <<"clock">>}, next()),
    ?assertEqual({ok, 3, 4096}, erx_machine_fs:write(ctl, 4096, <<"off">>, Fs(fun() -> ok end))),
    ?assertEqual({asked, off, <<"clock">>}, next()),
    ?assertEqual({error, ebusy}, erx_machine_fs:write(ctl, 0, <<"off\n">>, Fs(fun() -> busy end))),
    ?assertEqual({asked, off, <<"clock">>}, next()),
    ?assertEqual({error, eio}, erx_machine_fs:write(ctl, 0, <<"off">>, Fs(fun() -> exit(noproc) end))),
    ?assertEqual({asked, off, <<"clock">>}, next()),
    ?assertEqual({error, einval}, erx_machine_fs:write(ctl, 0, <<"trial\n">>, Fs(fun() -> ok end))),
    ?assertEqual(none, next()).

%% ctl is write-only, mode 0200, and the root lists it alone.
ctl_open_test() ->
    Fs = #{principal => <<"clock">>, request => fun(_, _) -> ok end},
    ?assertEqual({error, eacces}, erx_machine_fs:open(ctl, 0, Fs)),
    ?assertEqual({error, eacces}, erx_machine_fs:open(ctl, ?ERX_P9_O_RDWR, Fs)),
    ?assertEqual({ok, ctl}, erx_machine_fs:open(ctl, ?ERX_P9_O_WRONLY, Fs)),
    ?assertEqual({error, eacces}, erx_machine_fs:read(ctl, 0, 16, Fs)),
    {ok, #{mode := Mode}} = erx_machine_fs:getattr(ctl, Fs),
    ?assertEqual(8#200, Mode band 8#777),
    {ok, Listing} = erx_machine_fs:open(root, 0, Fs),
    ?assertMatch({ok, [{_, 1, _, <<"ctl">>}]}, erx_machine_fs:readdir(Listing, 0, 8, Fs)),
    ?assertEqual({error, enoent}, erx_machine_fs:walk(root, <<"power">>, Fs)).

%% The first request is accepted and names its user; every
%% later one is busy.
decide_test() ->
    {accept, {reset, <<"clock">>} = Ending, Line} = erx_machine:decide(none, reset, <<"clock">>),
    ?assertEqual(<<"rebooted by clock">>, iolist_to_binary(Line)),
    {accept, _, Off} = erx_machine:decide(none, off, <<"root">>),
    ?assertEqual(<<"powered off by root">>, iolist_to_binary(Off)),
    ?assertEqual(busy, erx_machine:decide(Ending, off, <<"root">>)),
    ?assertEqual(busy, erx_machine:decide(Ending, reset, <<"clock">>)).

%% The coordinator stops the machine once, for the first request, whoever asks later.
coordinator_test() ->
    Self = self(),
    {ok, Pid} = erx_machine:start_link(#{stop => fun(End) -> Self ! {stopped, End}, ok end}),
    try
        ?assertEqual(ok, erx_machine:request(reset, <<"clock">>)),
        ?assertEqual({stopped, reset}, next()),
        ?assertEqual(busy, erx_machine:request(off, <<"root">>)),
        ?assertEqual(busy, erx_machine:request(reset, <<"clock">>)),
        ?assertEqual(none, next())
    after
        unlink(Pid),
        exit(Pid, kill)
    end.

next() ->
    receive Message -> Message after 100 -> none end.

%% The system domain reaches its own tree by the path a session does: serving the tree
%% names its grants the machine service and mounts one grant of them, bound to the
%% system domain, at /svc/machine in the domain's own namespace, from the interface the
%% domain's declaration gives its name (docs/design-shell.md,
%% "Interfaces"). The grant is a child of the grants, so it ends with them.
serving_mounts_the_own_grant_test() ->
    persistent_term:erase(erx_ns),
    {ok, Ns} = erx_ns:start_link(erx_ns_prim_stub),
    persistent_term:put(erx_serves, [{<<"machine">>, ?ERX_SERVICE_SVC}]),
    {ok, Grants} = erx_machine_fs:start_link(),
    try
        ?assert(lists:member(machine, erx_facet:served())),
        [#{point := [<<"svc">>, <<"machine">>], provider := {own, machine, ?ERX_SERVICE_SVC, Own, <<"machine">>},
           rights := rw}] =
            [Entry || #{point := [<<"svc">>, <<"machine">>]} = Entry <- erx_ns_prim_stub:erx_mounts()],
        ?assertEqual([Own], [Pid || {_, Pid, _, _} <- supervisor:which_children(Grants)])
    after
        [begin unlink(Pid), exit(Pid, kill) end || Pid <- [Grants, Ns]],
        persistent_term:erase(erx_ns),
        persistent_term:erase({erx, serves}),
        persistent_term:erase(erx_serves)
    end.
