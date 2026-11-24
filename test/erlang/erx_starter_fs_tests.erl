%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the start service's tree, `start` (docs/design-apps.md,
%% "Interfaces"): erx_starter_fs's callbacks, called without a grant, over a stand-in
%% for the start service. The stand-in decides each command with
%% erx_start_table:apply_ctl/4 over a small table, as erx_starter does, and reports it
%% to the test. test/host/erx_starter_test.rb runs them on stock's emulator.
-module(erx_starter_fs_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

%% logger is enabled on display d1; kiosk is granted d1 too; clock is granted none.
rows() ->
    [#{principal => <<"clock">>, enable => false, published_enable => false,
       display => none, restarts => 5, period => 600},
     #{principal => <<"kiosk">>, enable => false, published_enable => false,
       display => none, restarts => 5, period => 600},
     #{principal => <<"logger">>, enable => true, published_enable => true,
       display => <<"d1">>, restarts => 5, period => 600}].

grants() ->
    #{<<"kiosk">> => [<<"d1">>], <<"logger">> => [<<"d1">>]}.

%% The tree's state, with stand-ins that send each command they decide to the test.
fs() ->
    Test = self(),
    Command = fun(Command) ->
                      Test ! {command, Command},
                      case erx_start_table:apply_ctl(Command, <<>>, rows(), grants()) of
                          {error, _} = Refused -> Refused;
                          _Action -> ok
                      end
              end,
    {ok, Fs} = erx_starter_fs:init(#{command => Command}),
    Fs.

write_ctl(Line) ->
    Fs = fs(),
    {ok, ctl} = erx_starter_fs:open(ctl, ?ERX_P9_O_WRONLY, Fs),
    erx_starter_fs:write(ctl, 0, Line, Fs).

commands() ->
    receive {command, Command} -> [Command | commands()]
    after 0 -> []
    end.

%% ---------------------------------------------------------------------------
%% The tree
%% ---------------------------------------------------------------------------

%% The tree holds ctl alone: rc.conf is a file of the etc tree, so the name is no node
%% here, and neither a create of it nor a write through the root's handle reaches the
%% start service.
the_root_holds_ctl_alone_test() ->
    Fs = fs(),
    ?assertMatch({ok, ctl, _}, erx_starter_fs:walk(root, <<"ctl">>, Fs)),
    [?assertEqual({error, enoent}, erx_starter_fs:walk(root, Name, Fs))
     || Name <- [<<"rc.conf">>, <<"..">>, <<"rc">>, <<"ctl/">>, <<>>, <<"apps">>]],
    ?assertEqual({error, enotdir}, erx_starter_fs:walk(ctl, <<"x">>, Fs)),
    {ok, {entries, Entries} = Root} = erx_starter_fs:open(root, 0, Fs),
    ?assertEqual([<<"ctl">>], [Name || {_, _, _, Name} <- Entries]),
    ?assertEqual({error, erofs}, erx_starter_fs:open(root, ?ERX_P9_O_WRONLY, Fs)),
    ?assertMatch({ok, #{mode := Mode}} when Mode band 8#777 =:= 8#200, erx_starter_fs:getattr(ctl, Fs)),
    ?assertEqual({error, eacces}, erx_starter_fs:make(root, <<"rc.conf">>, {file, 8#644, ?ERX_P9_O_WRONLY}, Fs)),
    ?assertEqual({error, ebadf}, erx_starter_fs:write(Root, 0, <<"x=1\n">>, Fs)),
    ?assertEqual([], commands()).

ctl_opens_for_writing_only_test() ->
    Fs = fs(),
    [?assertEqual({error, eacces}, erx_starter_fs:open(ctl, Flags, Fs))
     || Flags <- [0, ?ERX_P9_O_RDWR]],
    ?assertEqual({error, eacces}, erx_starter_fs:read(ctl, 0, 10, Fs)),
    ?assertMatch({ok, ctl, _, ctl},
                 erx_starter_fs:make(root, <<"ctl">>, {file, 8#644, ?ERX_P9_O_WRONLY bor ?ERX_P9_O_TRUNC}, Fs)),
    ?assertEqual({error, eexist},
                 erx_starter_fs:make(root, <<"ctl">>, {file, 8#644, ?ERX_P9_O_WRONLY bor ?ERX_P9_O_EXCL}, Fs)),
    ?assertEqual({error, eacces}, erx_starter_fs:make(root, <<"new">>, {file, 8#644, ?ERX_P9_O_WRONLY}, Fs)).

%% ---------------------------------------------------------------------------
%% ctl
%% ---------------------------------------------------------------------------

a_command_line_reaches_the_start_service_test() ->
    Line = <<"enable kiosk restarts=3\n">>,
    ?assertEqual({ok, byte_size(Line), 0}, write_ctl(Line)),
    ?assertEqual({ok, 11, 0}, write_ctl(<<"stop logger">>)),
    ?assertEqual({ok, 12, 0}, write_ctl(<<"start clock\n">>)),
    ?assertEqual([{enable, <<"kiosk">>, #{restarts => 3}}, {stop, <<"logger">>, #{}},
                  {start, <<"clock">>, #{}}], commands()).

an_undeclared_name_is_refused_with_einval_test() ->
    ?assertEqual({error, einval}, write_ctl(<<"enable ghost\n">>)),
    ?assertEqual([{enable, <<"ghost">>, #{}}], commands()).

a_held_display_is_ebusy_and_an_ungranted_one_eperm_test() ->
    ?assertEqual({error, ebusy}, write_ctl(<<"enable kiosk display=d1\n">>)),
    ?assertEqual({error, eperm}, write_ctl(<<"enable clock display=d1\n">>)),
    ?assertEqual([{enable, <<"kiosk">>, #{display => <<"d1">>}}, {enable, <<"clock">>, #{display => <<"d1">>}}],
                 commands()).

%% A line that does not parse reaches no command: too long, two lines, an unknown verb,
%% a bad setting.
a_bad_line_is_refused_with_einval_test() ->
    Long = <<"stop ", (binary:copy(<<"a">>, 4092))/binary>>,
    ?assertEqual(4097, byte_size(Long)),
    [?assertEqual({error, einval}, write_ctl(Line))
     || Line <- [Long, <<"stop a\nstop b\n">>, <<"reboot kiosk\n">>, <<"enable kiosk restarts=x\n">>,
                 <<>>, <<"\n">>, <<"stop \e[2Jkiosk\n">>]],
    ?assertEqual([], commands()).

%% The longest line, 4,096 bytes with its newline, is a command.
a_line_of_4096_bytes_is_one_command_test() ->
    Padding = binary:copy(<<" ">>, 4096 - byte_size(<<"stop kiosk\n">>)),
    Line = <<"stop kiosk", Padding/binary, "\n">>,
    ?assertEqual(4096, byte_size(Line)),
    ?assertEqual({ok, 4096, 0}, write_ctl(Line)),
    ?assertEqual([{stop, <<"kiosk">>, #{}}], commands()).

%% A start service that exits while the table restarts answers eio and ends nothing here.
a_start_service_that_exits_answers_eio_test() ->
    {ok, Fs} = erx_starter_fs:init(#{command => fun(_) -> exit(noproc) end}),
    ?assertEqual({error, eio}, erx_starter_fs:write(ctl, 0, <<"stop kiosk\n">>, Fs)).

errno_test() ->
    [?assertEqual(Errno, erx_starter_fs:errno(Answer))
     || {Answer, Errno} <- [{ok, ok},
                            {{error, {display_held, <<"logger">>}}, {error, ebusy}},
                            {{error, {no_grant, <<"d1">>}}, {error, eperm}},
                            {{error, rc_conf_unread}, {error, eagain}},
                            {{error, {undeclared, <<"ghost">>}}, {error, einval}},
                            {{error, {bad_line, too_long}}, {error, einval}},
                            {{error, {past_ceiling, restarts}}, {error, einval}},
                            {{error, enabled}, {error, einval}},
                            {{error, too_large}, {error, einval}},
                            {{error, bad_setting}, {error, einval}},
                            {{error, {failed, enospc}}, {error, eio}},
                            {{error, {failed, {exit, noproc}}}, {error, eio}}]].

%% The system shell's `service` writes /etc/start/ctl as a session's does: serving the
%% tree names its grants the start service and mounts one grant of them, bound to the
%% system domain, at /etc/start in the domain's own namespace (docs/design-shell.md,
%% "Interfaces"), and nothing at /apps, which holds apps alone. The grant is a child of
%% the grants, so it ends with them.
serving_mounts_the_own_grant_test() ->
    persistent_term:erase(erx_ns),
    {ok, Ns} = erx_ns:start_link(erx_ns_prim_stub),
    {ok, Grants} = erx_starter_fs:start_link(#{command => fun(_) -> ok end}),
    try
        ?assert(lists:member(start, erx_facet:served())),
        [#{point := [<<"etc">>, <<"start">>], provider := {grant, Own, <<"start">>}, rights := rw}] =
            [Entry || #{point := [_ | _]} = Entry <- erx_ns_prim_stub:erx_mounts()],
        ?assertEqual([Own], [Pid || {_, Pid, _, _} <- supervisor:which_children(Grants)])
    after
        [begin unlink(Pid), exit(Pid, kill) end || Pid <- [Grants, Ns]],
        persistent_term:erase(erx_ns),
        persistent_term:erase({erx, serves})
    end.
