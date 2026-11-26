%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_ssh_dev's daemon on stock OTP (docs/design-ssh.md, "Stages", stage 1):
%% root logs in with the development key or a key of root's home copy, gets a
%% shell on a tty whose size and ending reach the channel, an exec on that tty when
%% it asked for one and as a job without one, a command out of bounds refused;
%% another user name with that key and root with another key are
%% refused, a key in authorized_keys2 beside the file included, an empty or
%% missing keys file admits no one, a home file whose key line carries options,
%% or that is past 16 KiB, admits none of its keys, the host key is made once,
%% owner-only and whole, kept, and a damaged one refuses the start, and start/1
%% refuses a runtime whose release is not a development build's. The import
%% writes the medium's keys as the home copy only when there is none and the
%% medium answers a key, never replaces one, and never writes an empty file.
%% The tty is a stand-in
%% (tty/3) that speaks the six messages: it reports its size and TERM as
%% output, echoes input, ends with the status `exit N` names and with sigint
%% on Ctrl-C, as the session's line discipline would. The job relay is a stand-in
%% too (job/1) that speaks the job messages, tagged with the channel's alias as
%% erx_ssh_job tags them, and checks the channel keeps to them: pieces of at most
%% tty_line_data_max bytes, one unanswered at a time, each output answered before
%% the next. A job whose input is not answered holds the client to the window it
%% was given, and a job message without the alias, from another process, changes
%% nothing. The work directory is ERX_SSH_DEV_WORK, which the host test makes and
%% removes.
-module(erx_ssh_dev_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("public_key/include/public_key.hrl").

daemon_test_() ->
    {setup, fun start/0, fun stop/1,
     fun(Context) ->
             [?_test(the_banner_names_erxos(Context)),
              ?_test(a_shell_runs_on_a_tty(Context)),
              ?_test(ctrl_c_ends_with_int(Context)),
              ?_test(exec_runs_as_a_job(Context)),
              ?_test(a_job_that_crashes_ends_with_1(Context)),
              ?_test(a_malformed_job_message_closes_the_channel(Context)),
              ?_test(the_window_waits_for_the_job(Context)),
              ?_test(an_untagged_job_message_changes_nothing(Context)),
              ?_test(ssh_messages_of_another_channel_change_nothing(Context)),
              ?_test(an_end_of_input_before_exec_reaches_the_job(Context)),
              ?_test(exec_runs_on_a_tty(Context)),
              ?_test(an_exec_out_of_bounds_is_refused(Context)),
              ?_test(root_logs_in_with_a_home_key(Context)),
              ?_test(a_home_line_with_options_admits_none(Context)),
              ?_test(a_home_file_past_16_kib_admits_none(Context)),
              ?_test(another_user_is_refused(Context)),
              ?_test(another_key_is_refused(Context)),
              ?_test(the_host_key_is_kept(Context)),
              ?_test(no_keys_admit_no_one(Context)),
              ?_test(the_host_key_is_owner_only(Context)),
              ?_test(an_existing_directory_is_narrowed(Context))]
     end}.

%% Stock OTP's release has no build facts, so it is not a development build's.
start_refuses_a_release_build_test() ->
    ?assertMatch({error, {not_development, _}}, erx_ssh_dev:start(0)).

%% The build kind start/1 takes from build facts as the image build writes them:
%% only a development configuration is a development build.
the_build_kind_test() ->
    Facts = fun(Configuration) ->
                    {ok, _} = erx_build:parse_facts(<<"revision unknown\ndate unknown\nconfiguration ",
                                                      Configuration/binary, "\nkernel unknown\n">>)
            end,
    ?assertEqual([{development, true}, {local, true}, {release, false}, {release_local, false}, {unknown, false},
                  {none, false}],
                 [{development, erx_build:development_facts(Facts(<<"qemu-virt/development">>))},
                  {local, erx_build:development_facts(Facts(<<"qemu-virt/development-local">>))},
                  {release, erx_build:development_facts(Facts(<<"qemu-virt/release">>))},
                  {release_local, erx_build:development_facts(Facts(<<"qemu-virt/release-local">>))},
                  {unknown, erx_build:development_facts(Facts(<<"unknown">>))},
                  {none, erx_build:development_facts({error, {no_facts, "none"}})}]).

start() ->
    Work = os:getenv("ERX_SSH_DEV_WORK"),
    [Keys, Host, Client, Wrong, Card] = [filename:join(Work, Name) || Name <- ["keys", "host", "client", "wrong", "card"]],
    ok = lists:foreach(fun(Dir) -> ok = file:make_dir(Dir) end, [Keys, Client, Wrong, Card]),
    Public = client_key(Client),
    Login = filename:join(Keys, "authorized_keys"),
    ok = file:write_file(Login, Public),
    %% The wrong key sits beside the login key under the second name OpenSSH
    %% reads; the daemon reads exactly the file it was given.
    ok = file:write_file(filename:join(Keys, "authorized_keys2"), client_key(Wrong)),
    %% Root's home copy holds the card key's line, as the import writes it.
    ok = lists:foreach(fun(Dir) -> ok = file:make_dir(Dir) end, [filename:join(Work, "root"), filename:dirname(home(Work))]),
    ok = file:write_file(home(Work), client_key(Card)),
    {ok, Daemon} = erx_ssh_dev:daemon(0, options(Login, Host)),
    {ok, Info} = ssh:daemon_info(Daemon),
    #{work => Work, daemon => Daemon, port => proplists:get_value(port, Info),
      login => Login, host => Host, client => Client, wrong => Wrong, card => Card}.

%% The daemon's options with the stand-in tty and job relay and root's home copy in
%% the work directory.
options(Login, Host) ->
    #{keys => Login, home => home(os:getenv("ERX_SSH_DEV_WORK")), host => Host, open => fun tty/3,
      job => fun job/1}.

home(Work) -> filename:join([Work, "root", ".ssh", "authorized_keys"]).

%% The stand-in tty: it names itself to the channel, reports its size and TERM, and
%% then answers the channel's messages until the channel ends, its hangup. An exec
%% `exit N` on it writes `exec` and its size, and ends with status N.
tty(Channel, #{run := shell, size := {Rows, Columns}, vars := #{<<"TERM">> := [Term]}}, Notify) ->
    {ok, spawn(fun() ->
                       Ref = monitor(process, Channel),
                       Channel ! {tty_open, self()},
                       Channel ! {tty_output, 0, iolist_to_binary(io_lib:format("size ~b ~b ~s\r\n", [Rows, Columns, Term]))},
                       tty_loop(Channel, Ref, Notify, 1)
               end)};
tty(Channel, #{run := {exec, <<"exit ", Status/binary>>}, size := {Rows, Columns}}, Notify) ->
    {ok, spawn(fun() ->
                       Channel ! {tty_open, self()},
                       Channel ! {tty_output, 0, iolist_to_binary(io_lib:format("exec ~b ~b\r\n", [Rows, Columns]))},
                       Notify({exited, binary_to_integer(Status)})
               end)}.

tty_loop(Channel, Ref, Notify, N) ->
    receive
        {'DOWN', Ref, process, _, _} -> ok;
        {tty_taken, _} -> tty_loop(Channel, Ref, Notify, N);
        {tty_size, Rows, Columns} ->
            Channel ! {tty_output, N, iolist_to_binary(io_lib:format("size ~b ~b\r\n", [Rows, Columns]))},
            tty_loop(Channel, Ref, Notify, N + 1);
        {tty_input, _, <<3>>} -> Notify({signaled, sigint});
        {tty_input, _, <<"exit ", Status/binary>>} -> Notify({exited, binary_to_integer(Status)});
        {tty_input, _, Bytes} ->
            Channel ! {tty_output, N, Bytes},
            tty_loop(Channel, Ref, Notify, N + 1)
    end.

%% The stand-in job relay, started for the calling channel with an alias of the
%% channel's, as erx_ssh_job:start/2 starts the relay. For `exit N` it writes each
%% piece of input back as standard output, `end of input` on standard error at
%% job_eof, and ends with status N; `hold` does the same with status 0, but tells
%% the test (registered as this module) that it holds the first piece and answers
%% it only once the test says `release`; `crash` ends the relay before any ending;
%% `forge` sends a job_output one byte past tty_line_data_max and tells the test
%% how the channel ended; `forger` has another process send the channel job
%% messages without the alias, and then ends with status 7; `inject` sends the
%% channel SSH data and end of input in messages naming another connection and
%% channel, tells the test, and then runs as `exit 0`. It crashes, so the
%% channel ends with status 1, on a piece past tty_line_data_max or empty, on a
%% job_input or job_eof the channel sent before the last piece was answered, and
%% when a job_output is not answered.
job(Command) ->
    Channel = self(),
    Alias = alias(),
    {spawn(fun() -> job_run(Command, #{channel => Channel, alias => Alias, ref => monitor(process, Channel)}) end),
     Alias}.

job_run(<<"exit ", Status/binary>>, Job) ->
    job_loop(Job, binary_to_integer(Status));
job_run(<<"hold">>, #{alias := Alias} = Job) ->
    receive
        {Alias, {job_input, Bytes}} ->
            ?MODULE ! {held, self()},
            receive release -> ok end,
            job_piece(Job, Bytes),
            job_loop(Job, 0)
    end;
job_run(<<"crash">>, _Job) ->
    exit(crash);
job_run(<<"forge">>, #{alias := Alias, ref := Ref}) ->
    Alias ! {Alias, {job_output, stdout, binary:copy(<<0>>, ?ERX_TTY_LINE_DATA_MAX + 1)}},
    receive {'DOWN', Ref, process, _, Reason} -> ?MODULE ! {channel_ended, Reason} end;
job_run(<<"inject">>, #{channel := Channel} = Job) ->
    _ = [Channel ! Forged || Forged <- [{ssh_cm, self(), {data, 99, 0, <<"injected">>}},
                                        {ssh_cm, self(), {eof, 99}}]],
    _ = sys:get_state(Channel),
    ?MODULE ! injected,
    job_loop(Job, 0);
job_run(<<"forger">>, #{channel := Channel, alias := Alias}) ->
    %% The channel has taken every forged message before it answers the forger's
    %% call, which the forger makes before it ends.
    {_, Forger} = spawn_monitor(fun() ->
                                        _ = [Channel ! Forged || Forged <- [{exited, 0}, {make_ref(), {exited, 0}},
                                                                            {make_ref(), {ended, {exited, 0}}},
                                                                            {erx_ssh_dev_channel, ended, {exited, 0}},
                                                                            {job_output, stdout, <<"forged">>}]],
                                        sys:get_state(Channel)
                                end),
    receive {'DOWN', Forger, process, _, _} -> ok end,
    Alias ! {Alias, {exited, 7}}.

job_loop(#{alias := Alias, ref := Ref} = Job, Status) ->
    receive
        {'DOWN', Ref, process, _, _} ->
            ok;
        {Alias, {job_input, Bytes}} ->
            job_piece(Job, Bytes),
            job_loop(Job, Status);
        {Alias, job_eof} ->
            job_output(Job, stderr, <<"end of input\n">>),
            Alias ! {Alias, {exited, Status}}
    end.

%% A piece of input, written back and answered. The channel's job_sent follows
%% every message the channel sent before it, so a job_input or job_eof waiting
%% once it is heard was sent while the piece was unanswered.
job_piece(#{alias := Alias} = Job, Bytes) when byte_size(Bytes) >= 1, byte_size(Bytes) =< ?ERX_TTY_LINE_DATA_MAX ->
    job_output(Job, stdout, Bytes),
    receive
        {Alias, {job_input, _}} -> exit(two_inputs_unanswered);
        {Alias, job_eof} -> exit(job_eof_under_a_write)
    after 0 -> ok
    end,
    Alias ! {Alias, job_written};
job_piece(_Job, Bytes) ->
    exit({piece, byte_size(Bytes)}).

job_output(#{alias := Alias, ref := Ref}, Stream, Bytes) ->
    Alias ! {Alias, {job_output, Stream, Bytes}},
    receive
        {Alias, job_sent} -> ok;
        {'DOWN', Ref, process, _, _} -> exit(normal)
    after 10000 -> exit(job_output_unanswered)
    end.

stop(#{daemon := Daemon}) ->
    ok = ssh:stop_daemon(Daemon).

%% A fresh Ed25519 pair: the private key as id_ed25519 in Dir, and its public
%% half as one authorized_keys line.
client_key(Dir) ->
    Private = public_key:generate_key({namedCurve, ed25519}),
    ok = file:write_file(filename:join(Dir, "id_ed25519"),
                         ssh_file:encode([{[{Private, <<>>}], []}], openssh_key_v1)),
    Public = {#'ECPoint'{point = Private#'ECPrivateKey'.publicKey}, Private#'ECPrivateKey'.parameters},
    ssh_file:encode([{Public, [{comment, ""}]}], auth_keys).

connect(#{port := Port}, User, Dir) ->
    ssh:connect("localhost", Port, [{user, User}, {user_dir, Dir}, {silently_accept_hosts, true},
                                    {save_accepted_host, false}, {user_interaction, false},
                                    {auth_methods, "publickey"}, {connect_timeout, 10000}], 10000).

%% The server announces itself as erXos and the release number of abi/erx_abi.txt, not as
%% OTP's default id_string (Erlang/<ssh version>). The line is RFC 4253, section 4.2's
%% identification string, whose softwareversion has no space, no minus sign and only
%% printable US-ASCII.
the_banner_names_erxos(#{port := Port}) ->
    {ok, Socket} = gen_tcp:connect("localhost", Port, [binary, {active, false}, {packet, line}], 10000),
    {ok, Line} = gen_tcp:recv(Socket, 0, 10000),
    ok = gen_tcp:close(Socket),
    ?assertEqual(<<"SSH-2.0-erXos_", ?ERX_UNAME_RELEASE_BYTES/binary, "\r\n">>, Line),
    ?assertMatch({match, _}, re:run(Line, "^SSH-2\\.0-[\\x21-\\x2c\\x2e-\\x7e]+\r\n$")).

%% A pty-req's size reaches the tty, a window change resizes it, input reaches it
%% and its output the client, and the status the shell ends with is the channel's.
a_shell_runs_on_a_tty(#{client := Client} = Context) ->
    {ok, Connection} = connect(Context, "root", Client),
    {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
    success = ssh_connection:ptty_alloc(Connection, Channel, [{term, "vt100"}, {width, 100}, {height, 30}], 10000),
    %% Input sent right after the shell request, as OpenSSH sends it, reaches the tty.
    ok = ssh_connection:shell(Connection, Channel),
    ok = ssh_connection:send(Connection, Channel, <<"ps\n">>),
    ?assertMatch({ok, <<"size 30 100 ", _/binary>>}, data(Connection, Channel)),
    ?assertEqual({ok, <<"ps\n">>}, data(Connection, Channel)),
    ok = ssh_connection:window_change(Connection, Channel, 120, 40),
    ?assertEqual({ok, <<"size 40 120\r\n">>}, data(Connection, Channel)),
    ok = ssh_connection:send(Connection, Channel, <<"exit 3">>),
    ?assertEqual({<<>>, {status, 3}}, ending(Connection, Channel, <<>>, none)),
    ok = ssh:close(Connection).

ctrl_c_ends_with_int(#{client := Client} = Context) ->
    {ok, Connection} = connect(Context, "root", Client),
    {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
    success = ssh_connection:ptty_alloc(Connection, Channel, [], 10000),
    ok = ssh_connection:shell(Connection, Channel),
    {ok, _Size} = data(Connection, Channel),
    ok = ssh_connection:send(Connection, Channel, <<3>>),
    ?assertEqual({<<>>, {signal, "INT"}}, ending(Connection, Channel, <<>>, none)),
    ok = ssh:close(Connection).

%% An exec without a pty-req runs as a job: a MiB of every byte value, past the
%% channel's first window and in packets past tty_line_data_max, reaches the job and
%% comes back as its standard output, unchanged, its standard error stays apart,
%% and its status is the channel's.
exec_runs_as_a_job(#{client := Client} = Context) ->
    {ok, Connection} = connect(Context, "root", Client),
    {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
    success = ssh_connection:exec(Connection, Channel, "exit 5", 10000),
    Bytes = binary:copy(list_to_binary(lists:seq(0, 255)), 4096),
    %% A channel that closes early fails the sends, and the ending below says how.
    _ = spawn(fun() ->
                      _ = ssh_connection:send(Connection, Channel, Bytes),
                      ssh_connection:send_eof(Connection, Channel)
              end),
    {Output, Error, Ending} = job_ending(Connection, Channel, <<>>, <<>>, none),
    ?assertEqual({byte_size(Bytes), true, <<"end of input\n">>, {status, 5}},
                 {byte_size(Output), Output =:= Bytes, Error, Ending}),
    ok = ssh:close(Connection).

%% A job's relay that ends before the job's ending ends the channel with status 1.
a_job_that_crashes_ends_with_1(#{client := Client} = Context) ->
    {ok, Connection} = connect(Context, "root", Client),
    {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
    success = ssh_connection:exec(Connection, Channel, "crash", 10000),
    ?assertEqual({<<>>, <<>>, {status, 1}}, job_ending(Connection, Channel, <<>>, <<>>, none)),
    ok = ssh:close(Connection).

%% A job message that fails its check closes the channel, with no status, and the
%% channel ends normally rather than crashing.
a_malformed_job_message_closes_the_channel(#{client := Client} = Context) ->
    named(fun() ->
                  {ok, Connection} = connect(Context, "root", Client),
                  {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
                  success = ssh_connection:exec(Connection, Channel, "forge", 10000),
                  ?assertEqual({<<>>, <<>>, none}, job_ending(Connection, Channel, <<>>, <<>>, none)),
                  ?assertEqual(normal, receive {channel_ended, Reason} -> Reason after 10000 -> timeout end),
                  ok = ssh:close(Connection)
          end).

%% Runs Fun with the test process registered as this module, which the stand-in
%% jobs tell what they saw, and unregistered after, however Fun ends.
named(Fun) ->
    true = register(?MODULE, self()),
    try Fun() after unregister(?MODULE) end.

%% While the job leaves a piece of input unanswered, the channel opens no window:
%% the client sends what its window allows and waits. Once the job answers, the
%% rest of 4 MiB, past any window OTP takes from a socket's receive buffer, flows,
%% and comes back whole. The client cannot finish while the piece is held,
%% whatever the timing; the two seconds only bound how long a channel that opened
%% the window would take to take it all.
the_window_waits_for_the_job(#{client := Client} = Context) ->
    named(fun() ->
                  {ok, Connection} = connect(Context, "root", Client),
                  {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
                  success = ssh_connection:exec(Connection, Channel, "hold", 10000),
                  Bytes = binary:copy(list_to_binary(lists:seq(0, 255)), 4 * 4096),
                  Test = self(),
                  _ = spawn(fun() ->
                                    _ = ssh_connection:send(Connection, Channel, Bytes),
                                    Test ! sent,
                                    ssh_connection:send_eof(Connection, Channel)
                            end),
                  Relay = receive {held, Pid} -> Pid after 10000 -> error(not_held) end,
                  ?assertEqual(waiting, receive sent -> sent after 2000 -> waiting end),
                  Relay ! release,
                  {Output, Error, Ending} = job_ending(Connection, Channel, <<>>, <<>>, none),
                  ?assertEqual({byte_size(Bytes), true, <<"end of input\n">>, {status, 0}},
                               {byte_size(Output), Output =:= Bytes, Error, Ending}),
                  ok = ssh:close(Connection)
          end).

%% Job messages and endings without the job's alias, sent to the channel by
%% another process of the session, change nothing: the channel's ending is the
%% relay's.
an_untagged_job_message_changes_nothing(#{client := Client} = Context) ->
    {ok, Connection} = connect(Context, "root", Client),
    {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
    success = ssh_connection:exec(Connection, Channel, "forger", 10000),
    ?assertEqual({<<>>, <<>>, {status, 7}}, job_ending(Connection, Channel, <<>>, <<>>, none)),
    ok = ssh:close(Connection).

%% SSH messages sent to the channel by another process of the session, naming a
%% connection and channel not its own, change nothing: the job reads only what the
%% client sent, and the client's own end of input.
ssh_messages_of_another_channel_change_nothing(#{client := Client} = Context) ->
    named(fun() ->
                  {ok, Connection} = connect(Context, "root", Client),
                  {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
                  success = ssh_connection:exec(Connection, Channel, "inject", 10000),
                  receive injected -> ok after 10000 -> error(not_injected) end,
                  ok = ssh_connection:send(Connection, Channel, <<"real">>),
                  ok = ssh_connection:send_eof(Connection, Channel),
                  ?assertEqual({<<"real">>, <<"end of input\n">>, {status, 0}},
                               job_ending(Connection, Channel, <<>>, <<>>, none)),
                  ok = ssh:close(Connection)
          end).

%% The client's end of input before its exec, after a request that starts the
%% channel's process, reaches the job once it starts.
an_end_of_input_before_exec_reaches_the_job(#{client := Client} = Context) ->
    {ok, Connection} = connect(Context, "root", Client),
    {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
    failure = ssh_connection:setenv(Connection, Channel, "A", "b", 10000),
    ok = ssh_connection:send_eof(Connection, Channel),
    success = ssh_connection:exec(Connection, Channel, "exit 0", 10000),
    ?assertEqual({<<>>, <<"end of input\n">>, {status, 0}},
                 job_ending(Connection, Channel, <<>>, <<>>, none)),
    ok = ssh:close(Connection).

%% An exec after a pty-req runs on the tty at the pty-req's size, and its status is
%% the channel's.
exec_runs_on_a_tty(#{client := Client} = Context) ->
    {ok, Connection} = connect(Context, "root", Client),
    {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
    success = ssh_connection:ptty_alloc(Connection, Channel, [{width, 90}, {height, 20}], 10000),
    success = ssh_connection:exec(Connection, Channel, "exit 4", 10000),
    ?assertEqual({ok, <<"exec 20 90\r\n">>}, data(Connection, Channel)),
    ?assertEqual({<<>>, {status, 4}}, ending(Connection, Channel, <<>>, none)),
    ok = ssh:close(Connection).

%% A command holding a NUL byte, or past tty_line_command_max bytes, is refused, on
%% a tty and as a job.
an_exec_out_of_bounds_is_refused(#{client := Client} = Context) ->
    {ok, Connection} = connect(Context, "root", Client),
    Refused = fun(Pty, Command) ->
                      {ok, Channel} = ssh_connection:session_channel(Connection, 10000),
                      _ = [success = ssh_connection:ptty_alloc(Connection, Channel, [], 10000) || Pty],
                      ssh_connection:exec(Connection, Channel, Command, 10000)
              end,
    ?assertEqual([failure, failure, failure, failure],
                 [Refused(Pty, Command) || Pty <- [true, false],
                                           Command <- ["exit 1\0", lists:duplicate(?ERX_TTY_LINE_COMMAND_MAX + 1, $x)]]),
    ok = ssh:close(Connection).

%% A key of root's home copy logs root in, and no other user name.
root_logs_in_with_a_home_key(#{card := Card} = Context) ->
    {ok, Connection} = connect(Context, "root", Card),
    ok = ssh:close(Connection),
    ?assertMatch({error, _}, connect(Context, "daemon", Card)).

%% The home file is read as erx_boot_keys decodes it: a line whose key carries
%% options is no key, where OTP's ssh_file would take it.
a_home_line_with_options_admits_none(#{card := Card, work := Work} = Context) ->
    {ok, Line} = file:read_file(home(Work)),
    ok = file:write_file(home(Work), <<"restrict ", Line/binary>>),
    ?assertMatch({error, _}, connect(Context, "root", Card)),
    ok = file:write_file(home(Work), Line).

%% A home file of exactly 16 KiB admits its key; one byte more refuses it whole.
a_home_file_past_16_kib_admits_none(#{card := Card, work := Work} = Context) ->
    {ok, Line} = file:read_file(home(Work)),
    Padded = fun(Size) ->
                     Comment = Size - byte_size(Line) - 1,
                     <<Line/binary, "#", (binary:copy(<<"x">>, Comment - 1))/binary, "\n">>
             end,
    ok = file:write_file(home(Work), Padded(16384)),
    {ok, Connection} = connect(Context, "root", Card),
    ok = ssh:close(Connection),
    ok = file:write_file(home(Work), Padded(16385)),
    ?assertMatch({error, _}, connect(Context, "root", Card)),
    ok = file:write_file(home(Work), Line).

%% The import (docs/design-ssh.md, "Stages"): with no home copy and keys on the
%% medium, it writes each key as one canonical line, owner-only, and nothing beside.
the_import_writes_the_medium_keys_test() ->
    {Home, [One, Two]} = import_case("writes", 2),
    ?assertEqual({imported, 2}, erx_ssh_dev:import(Home, fun() -> {ok, <<One/binary, Two/binary>>} end)),
    ?assertEqual({ok, iolist_to_binary([[<<"ssh-ed25519 ">>, base64:encode(Blob), <<"\n">>] || Blob <- [One, Two]])},
                 file:read_file(Home)),
    {ok, #file_info{mode = Dir}} = file:read_file_info(filename:dirname(Home)),
    {ok, #file_info{mode = File}} = file:read_file_info(Home),
    ?assertEqual({8#700, 8#600}, {Dir band 8#777, File band 8#777}),
    ?assertEqual({ok, ["authorized_keys"]}, file:list_dir(filename:dirname(Home))).

%% Of a medium answer of one key and one blob that is no Ed25519 key, only the key
%% is written.
the_import_writes_only_keys_that_decode_test() ->
    {Home, [One]} = import_case("mixed", 1),
    Zero = binary:copy(<<0>>, byte_size(One)),
    ?assertEqual({imported, 1}, erx_ssh_dev:import(Home, fun() -> {ok, <<Zero/binary, One/binary>>} end)),
    ?assertEqual({ok, <<"ssh-ed25519 ", (base64:encode(One))/binary, "\n">>}, file:read_file(Home)).

%% A home copy that is there is never replaced, and the medium is not read.
the_import_never_replaces_a_home_copy_test() ->
    {Home, [One]} = import_case("kept", 1),
    ok = file:make_dir(filename:dirname(Home)),
    ok = file:write_file(Home, <<"# the user's own\n">>),
    ?assertEqual(kept, erx_ssh_dev:import(Home, fun() -> {ok, One} end)),
    ?assertEqual({ok, <<"# the user's own\n">>}, file:read_file(Home)).

%% A medium that has not answered, or a session without the grant, writes nothing
%% and asks to be tried again.
the_import_waits_for_the_medium_test() ->
    {Home, _} = import_case("waits", 0),
    ?assertEqual([{retry, eagain}, {retry, eio}, {retry, no_grant}],
                 [erx_ssh_dev:import(Home, fun() -> {error, Why} end) || Why <- [eagain, eio, no_grant]]),
    ?assertEqual({error, enoent}, file:read_file_info(filename:dirname(Home))).

%% A medium that answers no key, a file of no whole number of blobs, or blobs
%% that are no Ed25519 key, writes no file, empty or not.
the_import_never_writes_an_empty_file_test() ->
    {Home, [One]} = import_case("empty", 1),
    ?assertEqual([no_keys, no_keys, no_keys],
                 [erx_ssh_dev:import(Home, fun() -> {ok, Bytes} end)
                  || Bytes <- [<<>>, <<One/binary, 0>>, binary:copy(<<0>>, byte_size(One))]]),
    ?assertEqual({error, enoent}, file:read_file_info(Home)).

%% boot/1 waits for the session's net and data facets through the registry wait
%% (docs/design-system.md, "Waiting for a grant"): the daemon starts once both are
%% installed, in either order, and not before, with no look on a timer. The registry
%% is erx_facets' own, written by a model agent that answers each wait as the domain's
%% connection agent does.
the_daemon_starts_once_net_and_data_are_installed_test_() ->
    [{atom_to_list(First) ++ " first",
      fun() -> with_model_agent(fun(Agent) -> the_daemon_starts_once_installed(Agent, First, Second) end) end}
     || {First, Second} <- [{net, data}, {data, net}]].

the_daemon_starts_once_installed(Agent, First, Second) ->
    Test = self(),
    ok = erx_ssh_dev:boot(2222, fun(Port) -> Test ! {daemon_started, Port}, {error, test} end),
    ?assertEqual(none, daemon_started(200)),
    model_install(Agent, First),
    ?assertEqual(none, daemon_started(200)),
    model_install(Agent, Second),
    ?assertEqual(2222, daemon_started(2000)).

daemon_started(Ms) ->
    receive {daemon_started, Port} -> Port after Ms -> none end.

%% Case(Agent) with a model agent registered as erx_connections over an empty registry.
with_model_agent(Case) ->
    Clear = fun() -> [persistent_term:erase(Key) || Key <- [{erx, facets}, {erx, granted}]] end,
    Clear(),
    Agent = spawn(fun() -> model_agent([]) end),
    true = register(erx_connections, Agent),
    try Case(Agent)
    after
        %% The name is free again once the agent has ended, for the next case's agent.
        Ended = monitor(process, Agent),
        exit(Agent, kill),
        receive {'DOWN', Ended, process, Agent, _} -> ok end,
        Clear()
    end.

%% Installs a facet of a process of its own under Name, net or data, through the agent:
%% net's as a message service's, its pid, and data's as a tree's, with its tree.
model_install(Agent, Name) ->
    Pid = spawn(fun() -> receive after infinity -> ok end end),
    Facet = case Name of
                net -> {?ERX_SERVICE_NET, Pid};
                data -> {?ERX_SERVICE_FILES, {Pid, <<"data">>, rw}}
            end,
    Agent ! {install, #{Name => Facet}, self()},
    receive {installed, Agent} -> ok end.

model_agent(Waiting) ->
    receive
        {'$gen_call', From, {changed, Generation}} ->
            case erx_facets:generation() > Generation of
                true -> gen:reply(From, ok), model_agent(Waiting);
                false -> model_agent([From | Waiting])
            end;
        {install, Facets, Test} ->
            ok = erx_facets:install(Facets),
            _ = [gen:reply(From, ok) || From <- Waiting],
            Test ! {installed, self()},
            model_agent([])
    end.

%% A home path of its own under the work directory, with Count blobs of fresh keys.
import_case(Name, Count) ->
    Home = filename:join([os:getenv("ERX_SSH_DEV_WORK"), "import_" ++ Name, ".ssh", "authorized_keys"]),
    ok = file:make_dir(filename:dirname(filename:dirname(Home))),
    Blobs = [begin
                 Private = public_key:generate_key({namedCurve, ed25519}),
                 ssh_file:encode({#'ECPoint'{point = Private#'ECPrivateKey'.publicKey},
                                  Private#'ECPrivateKey'.parameters}, ssh2_pubkey)
             end || _ <- lists:seq(1, Count)],
    {Home, Blobs}.

%% The next data the channel sent on its standard output.
data(Connection, Channel) ->
    receive
        {ssh_cm, Connection, {data, Channel, 0, Data}} -> {ok, Data}
    after 10000 -> timeout
    end.

%% What the channel wrote on its standard error, and how it ended, once it closed.
ending(Connection, Channel, Error, Ending) ->
    receive
        {ssh_cm, Connection, {data, Channel, 1, Data}} -> ending(Connection, Channel, <<Error/binary, Data/binary>>, Ending);
        {ssh_cm, Connection, {exit_status, Channel, Status}} -> ending(Connection, Channel, Error, {status, Status});
        {ssh_cm, Connection, {exit_signal, Channel, Signal, _, _}} -> ending(Connection, Channel, Error, {signal, Signal});
        {ssh_cm, Connection, {eof, Channel}} -> ending(Connection, Channel, Error, Ending);
        {ssh_cm, Connection, {closed, Channel}} -> {Error, Ending};
        {ssh_cm, Connection, Other} -> {Other, Ending}
    after 10000 -> {timeout, Ending}
    end.

%% What a job wrote on its standard output and error, and how it ended, once the
%% channel closed. The client's window opens by what it takes, as OpenSSH's does.
job_ending(Connection, Channel, Output, Error, Ending) ->
    receive
        {ssh_cm, Connection, {data, Channel, 0, Data}} ->
            ssh_connection:adjust_window(Connection, Channel, byte_size(Data)),
            job_ending(Connection, Channel, <<Output/binary, Data/binary>>, Error, Ending);
        {ssh_cm, Connection, {data, Channel, 1, Data}} ->
            ssh_connection:adjust_window(Connection, Channel, byte_size(Data)),
            job_ending(Connection, Channel, Output, <<Error/binary, Data/binary>>, Ending);
        {ssh_cm, Connection, {exit_status, Channel, Status}} -> job_ending(Connection, Channel, Output, Error, {status, Status});
        {ssh_cm, Connection, {eof, Channel}} -> job_ending(Connection, Channel, Output, Error, Ending);
        {ssh_cm, Connection, {closed, Channel}} -> {Output, Error, Ending};
        {ssh_cm, Connection, Other} -> {Other, Error, Ending}
    after 10000 -> {timeout, Error, Ending}
    end.

another_user_is_refused(#{client := Client} = Context) ->
    ?assertMatch({error, _}, connect(Context, "daemon", Client)).

another_key_is_refused(#{wrong := Wrong} = Context) ->
    ?assertMatch({error, _}, connect(Context, "root", Wrong)).

the_host_key_is_kept(#{host := Host, login := Login}) ->
    Path = filename:join(Host, "ssh_host_ed25519_key"),
    {ok, Made} = file:read_file(Path),
    {ok, Again} = erx_ssh_dev:daemon(0, options(Login, Host)),
    ok = ssh:stop_daemon(Again),
    ?assertEqual({ok, Made}, file:read_file(Path)),
    ok = file:write_file(Path, <<"not a key">>),
    ?assertMatch({error, {host_key, Path, _}}, erx_ssh_dev:daemon(0, options(Login, Host))),
    ok = file:write_file(Path, Made).

%% With its keys file empty, or with none, the daemon admits no one, root with
%% the login key included; the file is read at each login, so one daemon shows both.
no_keys_admit_no_one(#{client := Client, login := Login} = Context) ->
    {ok, Keys} = file:read_file(Login),
    ok = file:write_file(Login, <<>>),
    ?assertMatch({error, _}, connect(Context, "root", Client)),
    ok = file:delete(Login),
    ?assertMatch({error, _}, connect(Context, "root", Client)),
    ok = file:write_file(Login, Keys),
    ?assertMatch({ok, _}, connect(Context, "root", Client)).

%% The made key's directory is 0700 and the key 0600, on a file system that
%% keeps modes, and nothing but the key is left beside it: the name it was
%% written under has been renamed.
the_host_key_is_owner_only(#{host := Host}) ->
    {ok, #file_info{mode = Dir}} = file:read_file_info(Host),
    {ok, #file_info{mode = Key}} = file:read_file_info(filename:join(Host, "ssh_host_ed25519_key")),
    ?assertEqual({8#700, 8#600}, {Dir band 8#777, Key band 8#777}),
    ?assertEqual({ok, ["ssh_host_ed25519_key"]}, file:list_dir(Host)).


%% A host-key directory that is there already is narrowed to 0700 as well.
an_existing_directory_is_narrowed(#{work := Work, login := Login}) ->
    Host = filename:join(Work, "existing"),
    ok = file:make_dir(Host),
    ok = file:change_mode(Host, 8#755),
    {ok, Daemon} = erx_ssh_dev:daemon(0, options(Login, Host)),
    ok = ssh:stop_daemon(Daemon),
    {ok, #file_info{mode = Mode}} = file:read_file_info(Host),
    ?assertEqual(8#700, Mode band 8#777).
