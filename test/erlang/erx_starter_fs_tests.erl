%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the `apps` tree (docs/design-apps.md, "Interfaces"): erx_starter_fs's
%% callbacks, called without a grant, over stand-ins for the start service. The command
%% stand-in decides each command with erx_start_table:apply_ctl/4 over a small table, as
%% erx_starter does, and reports it to the test; the rc_conf stand-in answers a fixed
%% text. test/host/erx_starter_test.rb runs them on stock's emulator.
-module(erx_starter_fs_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(RC_CONF, <<"logger_enable=\"YES\"\n">>).

%% logger is enabled on display d1; kiosk is granted d1 too; clock is granted none.
rows() ->
    [#{principal => <<"clock">>, enable => false, display => none, restarts => 5, period => 600},
     #{principal => <<"kiosk">>, enable => false, display => none, restarts => 5, period => 600},
     #{principal => <<"logger">>, enable => true, display => <<"d1">>, restarts => 5, period => 600}].

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
    {ok, Fs} = erx_starter_fs:init(#{rc_conf => fun() -> ?RC_CONF end, command => Command}),
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

the_root_holds_ctl_and_rc_conf_test() ->
    Fs = fs(),
    ?assertMatch({ok, ctl, _}, erx_starter_fs:walk(root, <<"ctl">>, Fs)),
    ?assertMatch({ok, rc_conf, _}, erx_starter_fs:walk(root, <<"rc.conf">>, Fs)),
    [?assertEqual({error, enoent}, erx_starter_fs:walk(root, Name, Fs))
     || Name <- [<<"..">>, <<"rc">>, <<"ctl/">>, <<>>, <<"apps">>]],
    ?assertEqual({error, enotdir}, erx_starter_fs:walk(ctl, <<"x">>, Fs)),
    {ok, {entries, Entries}} = erx_starter_fs:open(root, 0, Fs),
    ?assertEqual([<<"ctl">>, <<"rc.conf">>], [Name || {_, _, _, Name} <- Entries]),
    ?assertMatch({ok, #{mode := Mode}} when Mode band 8#777 =:= 8#200, erx_starter_fs:getattr(ctl, Fs)),
    ?assertMatch({ok, #{mode := Mode}} when Mode band 8#777 =:= 8#444, erx_starter_fs:getattr(rc_conf, Fs)).

rc_conf_shows_the_start_services_text_test() ->
    Fs = fs(),
    {ok, Handle} = erx_starter_fs:open(rc_conf, 0, Fs),
    ?assertEqual({ok, ?RC_CONF}, erx_starter_fs:read(Handle, 0, 4096, Fs)),
    ?assertEqual({ok, <<"YES\"\n">>}, erx_starter_fs:read(Handle, 15, 4096, Fs)),
    ?assertEqual({ok, <<>>}, erx_starter_fs:read(Handle, byte_size(?RC_CONF), 4096, Fs)).

%% Neither an open for writing, nor a create over it, nor a write through another
%% file's handle writes rc.conf.
rc_conf_cannot_be_written_test() ->
    Fs = fs(),
    [?assertEqual({error, erofs}, erx_starter_fs:open(rc_conf, Flags, Fs))
     || Flags <- [?ERX_P9_O_WRONLY, ?ERX_P9_O_RDWR, ?ERX_P9_O_WRONLY bor ?ERX_P9_O_TRUNC]],
    ?assertEqual({error, erofs}, erx_starter_fs:make(root, <<"rc.conf">>, {file, 8#644, ?ERX_P9_O_WRONLY}, Fs)),
    {ok, Handle} = erx_starter_fs:open(rc_conf, 0, Fs),
    ?assertEqual({error, ebadf}, erx_starter_fs:write(Handle, 0, <<"x=1\n">>, Fs)),
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
    {ok, Fs} = erx_starter_fs:init(#{rc_conf => fun() -> exit(noproc) end,
                                      command => fun(_) -> exit(noproc) end}),
    ?assertEqual({error, eio}, erx_starter_fs:write(ctl, 0, <<"stop kiosk\n">>, Fs)),
    ?assertEqual({error, eio}, erx_starter_fs:open(rc_conf, 0, Fs)).

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
