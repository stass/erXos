%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the session's export's fixed tree (docs/design-files.md, "Narrowing
%% for a program"): erx_session_export's callbacks, called without a grant and through
%% real erx_fs grants of each of the session's rights, for a made-up principal and
%% command list, with a stand-in for the kernel's generator that reports to the test;
%% erx_shell_namespace:commands/1, which names what /bin lists; and
%% erx_session_sup:export_args/3, what the session starts the export from.
%% test/host/erx_session_export_test.rb runs them on stock's emulator.
-module(erx_session_export_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(PRINCIPAL, #{name => <<"alice">>, number => 1001}).
-define(COMMANDS, [<<"ls">>, <<"cat">>, <<"echo">>]).

%% The tree's state, with a generator that answers bytes of 7 and reports each read's
%% size.
fs() ->
    Test = self(),
    fs(fun(Size) -> Test ! {entropy, Size}, binary:copy(<<7>>, Size) end).

fs(Entropy) ->
    init(#{principal => ?PRINCIPAL, commands => ?COMMANDS, entropy => Entropy}).

init(Args) ->
    ok = erx_fs_version:init(),
    {ok, Fs} = erx_session_export:init(Args),
    Fs.

%% The node a path from the root names, walking one name at a time.
walk(Path, Fs) ->
    {ok, Root, _Qid} = root(Fs),
    lists:foldl(fun(Name, {ok, Node, _}) -> erx_session_export:walk(Node, Name, Fs);
                   (_Name, Error) -> Error
                end, {ok, Root, none}, Path).

root(Fs) ->
    {ok, <<"export">>, Root, Qid} = erx_session_export:root(Fs),
    {ok, Root, Qid}.

node_at(Path, Fs) ->
    {ok, Node, _Qid} = walk(Path, Fs),
    Node.

open(Path, Flags, Fs) ->
    erx_session_export:open(node_at(Path, Fs), Flags, Fs).

names(Path, Fs) ->
    {ok, Handle} = open(Path, 0, Fs),
    {ok, Entries} = erx_session_export:readdir(Handle, 0, 256, Fs),
    [Name || {_Qid, _Offset, _Type, Name} <- Entries].

read(Path, Count, Fs) ->
    {ok, Handle} = open(Path, 0, Fs),
    erx_session_export:read(Handle, 0, Count, Fs).

mode(Path, Fs) ->
    {ok, #{mode := Mode}} = erx_session_export:getattr(node_at(Path, Fs), Fs),
    Mode.

messages() ->
    receive {entropy, _} = Message -> [Message | messages()]
    after 0 -> []
    end.

%% ---------------------------------------------------------------------------
%% The tree
%% ---------------------------------------------------------------------------

the_root_lists_bin_dev_and_etc_test() ->
    Fs = fs(),
    ?assertEqual([<<"bin">>, <<"dev">>, <<"etc">>], names([], Fs)),
    ?assertEqual([<<"null">>, <<"tty">>, <<"urandom">>, <<"zero">>], names([<<"dev">>], Fs)),
    ?assertEqual([<<"group">>, <<"passwd">>], names([<<"etc">>], Fs)).

bin_lists_the_commands_sorted_once_test() ->
    Fs = init(#{principal => ?PRINCIPAL, commands => [<<"ls">>, <<"cat">>, <<"ls">>]}),
    ?assertEqual([<<"cat">>, <<"ls">>], names([<<"bin">>], Fs)).

a_walk_finds_only_the_trees_names_test() ->
    Fs = fs(),
    ?assertEqual({error, enoent}, walk([<<"usr">>], Fs)),
    ?assertEqual({error, enoent}, walk([<<"dev">>, <<"draw">>], Fs)),
    ?assertEqual({error, enoent}, walk([<<"bin">>, <<"rc">>], Fs)),
    ?assertEqual({error, enotdir}, walk([<<"etc">>, <<"passwd">>, <<"x">>], Fs)),
    ?assertEqual({error, enotdir}, walk([<<"dev">>, <<"null">>, <<"x">>], Fs)).

%% Every file's path from the root, the directories first.
dir_paths() ->
    [[<<"bin">>], [<<"dev">>], [<<"etc">>]].

file_paths(Fs) ->
    [[Dir, Name] || [Dir] <- dir_paths(), Name <- names([Dir], Fs)].

qid_at(Path, Fs) ->
    {ok, _Node, Qid} = walk(Path, Fs),
    Qid.

no_two_nodes_share_a_qid_path_test() ->
    Fs = fs(),
    {ok, _Root, RootQid} = root(Fs),
    Qids = [RootQid | [qid_at(Path, Fs) || Path <- dir_paths() ++ file_paths(Fs)]],
    ?assertEqual(length(Qids), length(lists:usort([Path || {_, _, Path} <- Qids]))).

a_directory_has_a_directory_qid_and_a_file_a_file_qid_test() ->
    Fs = fs(),
    {ok, _Root, {RootType, _, _}} = root(Fs),
    ?assertEqual([?ERX_P9_QTDIR || _ <- [root | dir_paths()]],
                 [RootType | [Type || Path <- dir_paths(),
                                      {Type, _, _} <- [qid_at(Path, Fs)]]]),
    ?assertEqual([{Path, 0} || Path <- file_paths(Fs)],
                 [{Path, Type} || Path <- file_paths(Fs), {Type, _, _} <- [qid_at(Path, Fs)]]).

a_walk_and_a_listing_give_one_qid_test() ->
    Fs = fs(),
    {ok, _, Null} = walk([<<"dev">>, <<"null">>], Fs),
    ?assertEqual({ok, null, Null}, walk([<<"dev">>, <<"null">>], Fs)),
    {ok, Dev} = open([<<"dev">>], 0, Fs),
    {ok, Entries} = erx_session_export:readdir(Dev, 0, 256, Fs),
    ?assertEqual({Null, 1, ?ERX_P9_DT_CHR, <<"null">>}, lists:keyfind(<<"null">>, 4, Entries)).

a_grant_started_again_serves_new_files_test() ->
    {ok, _, Before} = walk([<<"etc">>, <<"passwd">>], fs()),
    {ok, _, After} = walk([<<"etc">>, <<"passwd">>], fs()),
    ?assertNotEqual(Before, After).

modes_say_what_each_node_allows_test() ->
    Fs = fs(),
    ?assertEqual(?ERX_P9_S_IFDIR bor 8#555, mode([<<"bin">>], Fs)),
    ?assertEqual(?ERX_P9_S_IFREG bor 8#111, mode([<<"bin">>, <<"ls">>], Fs)),
    ?assertEqual(?ERX_P9_S_IFCHR bor 8#666, mode([<<"dev">>, <<"null">>], Fs)),
    ?assertEqual(?ERX_P9_S_IFCHR bor 8#666, mode([<<"dev">>, <<"tty">>], Fs)),
    ?assertEqual(?ERX_P9_S_IFCHR bor 8#444, mode([<<"dev">>, <<"urandom">>], Fs)),
    ?assertEqual(?ERX_P9_S_IFREG bor 8#444, mode([<<"etc">>, <<"passwd">>], Fs)).

%% ---------------------------------------------------------------------------
%% Opens
%% ---------------------------------------------------------------------------

a_command_never_opens_test() ->
    Fs = fs(),
    [?assertEqual({error, eacces}, open([<<"bin">>, <<"cat">>], Flags, Fs))
     || Flags <- [0, ?ERX_P9_O_WRONLY, ?ERX_P9_O_RDWR]].

a_directory_opens_for_reading_only_test() ->
    Fs = fs(),
    ?assertEqual({error, eisdir}, open([<<"etc">>], ?ERX_P9_O_WRONLY, Fs)),
    ?assertEqual({error, eisdir}, open([], ?ERX_P9_O_RDWR, Fs)),
    {ok, Handle} = open([<<"etc">>], 0, Fs),
    ?assertEqual({error, eisdir}, erx_session_export:read(Handle, 0, 10, Fs)).

the_read_only_files_refuse_writing_test() ->
    Fs = fs(),
    [?assertEqual({error, eacces}, open(Path, Flags, Fs))
     || Path <- [[<<"etc">>, <<"passwd">>], [<<"etc">>, <<"group">>],
                 [<<"dev">>, <<"urandom">>]],
        Flags <- [?ERX_P9_O_WRONLY, ?ERX_P9_O_RDWR, ?ERX_P9_O_WRONLY bor ?ERX_P9_O_TRUNC]].

access_mode_three_is_refused_test() ->
    ?assertEqual({error, einval}, open([<<"dev">>, <<"null">>], ?ERX_P9_O_ACCMODE, fs())).

an_open_allows_only_its_access_test() ->
    Fs = fs(),
    {ok, ReadOnly} = open([<<"dev">>, <<"zero">>], 0, Fs),
    ?assertEqual({error, ebadf}, erx_session_export:write(ReadOnly, 0, <<"x">>, Fs)),
    {ok, WriteOnly} = open([<<"dev">>, <<"zero">>], ?ERX_P9_O_WRONLY, Fs),
    ?assertEqual({error, ebadf}, erx_session_export:read(WriteOnly, 0, 4, Fs)),
    {ok, Both} = open([<<"dev">>, <<"zero">>], ?ERX_P9_O_RDWR, Fs),
    ?assertEqual({ok, 1, 0}, erx_session_export:write(Both, 0, <<"x">>, Fs)),
    ?assertEqual({ok, <<0, 0>>}, erx_session_export:read(Both, 0, 2, Fs)).

%% ---------------------------------------------------------------------------
%% The devices
%% ---------------------------------------------------------------------------

null_reads_empty_and_takes_every_write_test() ->
    Fs = fs(),
    ?assertEqual({ok, <<>>}, read([<<"dev">>, <<"null">>], 4096, Fs)),
    {ok, Null} = open([<<"dev">>, <<"null">>], ?ERX_P9_O_WRONLY bor ?ERX_P9_O_TRUNC, Fs),
    ?assertEqual({ok, 5, 100}, erx_session_export:write(Null, 100, <<"hello">>, Fs)),
    ?assertEqual([], messages()).

zero_reads_zeros_test() ->
    Fs = fs(),
    ?assertEqual({ok, binary:copy(<<0>>, 65536)}, read([<<"dev">>, <<"zero">>], 65536, Fs)).

urandom_reads_the_generator_within_its_bound_test() ->
    Fs = fs(),
    ?assertEqual({ok, binary:copy(<<7>>, 600)}, read([<<"dev">>, <<"urandom">>], 600, Fs)),
    ?assertEqual([{entropy, 256}, {entropy, 256}, {entropy, 88}], messages()),
    ?assertEqual({ok, binary:copy(<<7>>, 512)}, read([<<"dev">>, <<"urandom">>], 512, Fs)),
    ?assertEqual([{entropy, 256}, {entropy, 256}], messages()).

a_refused_generator_read_answers_eio_test() ->
    Fs = fs(fun(_Size) -> error({entropy, ebusy}) end),
    ?assertEqual({error, eio}, read([<<"dev">>, <<"urandom">>], 16, Fs)).

%% tty is a name alone (docs/design-files.md, "Native clients: `liberx`'s file
%% client"): a walk and a getattr reach it, and the handler that opens it makes a
%% terminal's description instead, an open of the terminal relay under the program's
%% job, so no open of it, in any mode, nor a create that would open it, reaches a
%% handle of this tree.
tty_is_a_name_that_never_opens_test() ->
    Fs = fs(),
    {ok, tty, Qid} = walk([<<"dev">>, <<"tty">>], Fs),
    [?assertEqual({error, enxio}, open([<<"dev">>, <<"tty">>], Flags, Fs))
     || Flags <- [0, ?ERX_P9_O_WRONLY, ?ERX_P9_O_RDWR]],
    ?assertEqual({error, enxio},
                 erx_session_export:make(dev, <<"tty">>, {file, 8#666, ?ERX_P9_O_WRONLY}, Fs)),
    {ok, #{qid := Qid}} = erx_session_export:getattr(tty, Fs).

%% ---------------------------------------------------------------------------
%% /etc
%% ---------------------------------------------------------------------------

%% Each line split as musl's getpwent and getgrent split it: by colon, the last field
%% running to the end of the line.
lines(Text) ->
    [binary:split(Line, <<":">>, [global])
     || Line <- binary:split(Text, <<"\n">>, [global, trim])].

passwd_holds_the_principal_and_nobody_test() ->
    {ok, Text} = read([<<"etc">>, <<"passwd">>], 4096, fs()),
    ?assertEqual([[<<"alice">>, <<"*">>, <<"1001">>, <<"1001">>, <<>>, <<"/">>, <<"/bin/rc">>],
                  [<<"nobody">>, <<"*">>, <<"65534">>, <<"65534">>, <<"Unprivileged user">>,
                   <<"/nonexistent">>, <<"/usr/sbin/nologin">>]],
                 lines(Text)).

group_holds_the_principal_and_nobody_test() ->
    {ok, Text} = read([<<"etc">>, <<"group">>], 4096, fs()),
    ?assertEqual([[<<"alice">>, <<"*">>, <<"1001">>, <<>>],
                  [<<"nobody">>, <<"*">>, <<"65534">>, <<>>]],
                 lines(Text)).

a_text_reads_from_any_offset_test() ->
    Fs = fs(),
    {ok, Whole} = read([<<"etc">>, <<"passwd">>], 4096, Fs),
    {ok, Handle} = open([<<"etc">>, <<"passwd">>], 0, Fs),
    ?assertEqual({ok, binary:part(Whole, 6, 3)}, erx_session_export:read(Handle, 6, 3, Fs)),
    ?assertEqual({ok, <<>>}, erx_session_export:read(Handle, byte_size(Whole), 10, Fs)),
    ?assertEqual({ok, <<>>}, erx_session_export:read(Handle, byte_size(Whole) + 10, 10, Fs)).

%% ---------------------------------------------------------------------------
%% Creates
%% ---------------------------------------------------------------------------

a_create_of_a_device_opens_it_test() ->
    Fs = fs(),
    Flags = ?ERX_P9_O_WRONLY bor ?ERX_P9_O_TRUNC,
    {ok, _, Qid} = walk([<<"dev">>, <<"null">>], Fs),
    {ok, null, Qid, Null} = erx_session_export:make(dev, <<"null">>, {file, 8#666, Flags}, Fs),
    ?assertEqual({ok, 3, 0}, erx_session_export:write(Null, 0, <<"abc">>, Fs)),
    ?assertEqual({error, eexist},
                 erx_session_export:make(dev, <<"null">>,
                                         {file, 8#666, Flags bor ?ERX_P9_O_EXCL}, Fs)),
    %% A create of urandom opens it as its open would: not for writing.
    ?assertEqual({error, eacces},
                 erx_session_export:make(dev, <<"urandom">>, {file, 8#666, Flags}, Fs)).

no_create_makes_a_name_test() ->
    Fs = fs(),
    File = {file, 8#644, ?ERX_P9_O_WRONLY},
    [?assertEqual({error, eacces}, erx_session_export:make(Dir, Name, What, Fs))
     || {Dir, Name, What} <- [{dev, <<"draw">>, File}, {etc, <<"passwd">>, File},
                              {etc, <<"rc.conf">>, File}, {bin, <<"ls">>, File},
                              {root, <<"tmp">>, {directory, 8#755, self()}},
                              {dev, <<"null">>, {directory, 8#755, self()}}]].

statfs_and_clunk_test() ->
    Fs = fs(),
    {ok, #{type := Type}} = erx_session_export:statfs(Fs),
    ?assertEqual(?ERX_P9_MAGIC_DEVFS, Type),
    {ok, Handle} = open([<<"dev">>, <<"null">>], 0, Fs),
    ?assertEqual(ok, erx_session_export:clunk(Handle, Fs)).

%% ---------------------------------------------------------------------------
%% What /bin lists
%% ---------------------------------------------------------------------------

bin_lists_the_erlang_commands_alone_test() ->
    Command = fun(Name) ->
                      Module = binary_to_atom(<<"erx_cmd_test_", Name/binary>>),
                      {Module, [{erx_command, [binary_to_atom(Name)]}, {erx_usage, "usage"}],
                       [{run, 2}]}
              end,
    {Table, []} = erx_shell_namespace:build([Command(<<"wc">>), Command(<<"cat">>)]),
    {Conflicted, []} = erx_shell_namespace:build(
                         [Command(<<"cat">>), Command(<<"wc">>),
                          {erx_cmd_test_other_wc, [{erx_command, [wc]}, {erx_usage, "usage"}],
                           [{run, 2}]}]),
    %% cd and the job builtins are the runner's, and a conflicting name runs nothing.
    ?assertEqual([<<"cat">>, <<"wc">>], erx_shell_namespace:commands(Table)),
    ?assertEqual([<<"cat">>], erx_shell_namespace:commands(Conflicted)).

%% ---------------------------------------------------------------------------
%% Through a grant
%% ---------------------------------------------------------------------------

%% A grant of the tree with Rights, as erx_session_sup starts it, with a generator of
%% sevens; fid 1 is attached to its root.
grant(Rights) ->
    ok = erx_fs_version:init(),
    Args = #{principal => ?PRINCIPAL, commands => ?COMMANDS,
             entropy => fun(Size) -> binary:copy(<<7>>, Size) end},
    {ok, Grant, _} = erx_fs:start_link(erx_session_export, Args, Rights),
    unlink(Grant),
    {ok, _Qid} = call(Grant, {attach, 1, ?ERX_P9_NOFID, <<"user">>, <<"export">>, 0}),
    Grant.

%% One request and its reply, as erx_file_remote sends it: to a fresh alias.
call(Grant, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), Request},
    receive
        {erx_9p, Alias, Reply} -> Reply
    after 2000 ->
        erlang:error({no_reply, Request})
    end.

%% Fid walked from the root, fid 1, along Path.
walk_to(Grant, Fid, Path) ->
    {ok, Qids} = call(Grant, {walk, 1, Fid, Path}),
    ?assertEqual(length(Path), length(Qids)).

listing(Grant, Fid) ->
    {ok, _Qid, _Iounit} = call(Grant, {lopen, Fid, 0}),
    {ok, Entries} = call(Grant, {readdir, Fid, 0, 8192}),
    [{Name, Type} || {_EntryQid, _Offset, Type, Name} <- Entries].

the_rw_grant_reads_etc_and_lists_dev_as_character_devices_test() ->
    Grant = grant(rw),
    walk_to(Grant, 2, [<<"etc">>, <<"passwd">>]),
    {ok, _Qid, _Iounit} = call(Grant, {lopen, 2, 0}),
    {ok, Text} = call(Grant, {read, 2, 0, 4096}),
    ?assertMatch([<<"alice:*:1001:1001::/:/bin/rc">> | _], binary:split(Text, <<"\n">>, [global])),
    walk_to(Grant, 3, [<<"dev">>]),
    ?assertEqual([{<<"null">>, ?ERX_P9_DT_CHR}, {<<"tty">>, ?ERX_P9_DT_CHR},
                  {<<"urandom">>, ?ERX_P9_DT_CHR}, {<<"zero">>, ?ERX_P9_DT_CHR}],
                 listing(Grant, 3)),
    exit(Grant, kill).

the_rw_grant_creates_into_a_device_test() ->
    Grant = grant(rw),
    walk_to(Grant, 2, [<<"dev">>]),
    ?assertMatch({ok, _Qid, _Iounit},
                 call(Grant, {lcreate, 2, <<"null">>, ?ERX_P9_O_WRONLY, 8#644, 0})),
    ?assertEqual({ok, 3, 0}, call(Grant, {write, 2, 0, <<"abc">>})),
    exit(Grant, kill).

%% The design's case (docs/design-files.md, "Verification and testing"): an lopen of
%% /dev/tty answers enxio, whatever its access, and leaves the fid unopened.
the_export_answers_an_lopen_of_tty_with_enxio_test() ->
    Grant = grant(rw),
    walk_to(Grant, 2, [<<"dev">>, <<"tty">>]),
    [?assertEqual({error, enxio}, call(Grant, {lopen, 2, Flags}))
     || Flags <- [0, ?ERX_P9_O_WRONLY, ?ERX_P9_O_RDWR]],
    ?assertEqual({error, ebadf}, call(Grant, {write, 2, 0, <<"hi">>})),
    exit(Grant, kill).

the_rx_grant_lists_bin_and_refuses_writes_test() ->
    Grant = grant(rx),
    walk_to(Grant, 2, [<<"bin">>]),
    ?assertEqual([<<"cat">>, <<"echo">>, <<"ls">>], [Name || {Name, _Type} <- listing(Grant, 2)]),
    walk_to(Grant, 3, [<<"dev">>]),
    ?assertEqual({error, erofs},
                 call(Grant, {lcreate, 3, <<"null">>, ?ERX_P9_O_WRONLY, 8#644, 0})),
    exit(Grant, kill).

%% ---------------------------------------------------------------------------
%% What the supervisor starts the export from
%% ---------------------------------------------------------------------------

export_args_take_the_number_and_the_node_names_prefix_test() ->
    ?assertEqual(#{principal => #{name => <<"root">>, number => 1}, commands => ?COMMANDS},
                 erx_session_sup:export_args("1", 'root_1@erxos', ?COMMANDS)),
    ?assertMatch(#{principal := #{name := <<"a_b">>, number := 1002}},
                 erx_session_sup:export_args("1002", 'a_b_12@erxos', ?COMMANDS)).

%% A program's own /dev (docs/design-files.md, "A program's window"), over the
%% stand-ins of test/erlang/stand_in for the window and the draw connection: the
%% tree's state, its window and its connection.
window_fs(Display) ->
    persistent_term:put(erx_win, self()),
    {ok, Window} = erx_win:open(Display, #{}),
    {ok, Conn} = erx_draw_conn:start(#{window => Window}),
    Fs = init(#{window => #{window => Window, conn => Conn, display => Display,
                            clipboard => erx_win:clipboard(Display)}}),
    {Fs, Conn}.

-define(WINDOW_DEV, [<<"null">>, <<"tty">>, <<"urandom">>, <<"zero">>, <<"draw">>, <<"ctl">>, <<"kbd">>,
                     <<"mouse">>, <<"wctl">>, <<"label">>]).

a_programs_dev_holds_the_devices_and_its_window_test() ->
    {Fs, _} = window_fs(d),
    {Clip, _} = window_fs(clip),
    ?assertEqual([<<"dev">>], names([], Fs)),
    ?assertEqual(?WINDOW_DEV, names([<<"dev">>], Fs)),
    ?assertEqual(?WINDOW_DEV ++ [<<"clipboard">>], names([<<"dev">>], Clip)),
    %% No name leads into the window's directory, and nothing is created.
    ?assertEqual({error, enotdir}, walk([<<"dev">>, <<"kbd">>, <<"ctl">>], Fs)),
    ?assertEqual({error, enoent}, walk([<<"dev">>, <<"w1">>], Fs)),
    ?assertEqual({error, eacces}, erx_session_export:make(dev, <<"w1">>, {dir, 8#755, 0}, Fs)).

ctl_reads_whole_at_offset_zero_and_never_opens_for_writing_test() ->
    {Fs, _} = window_fs(d),
    {ok, Ctl} = open([<<"dev">>, <<"ctl">>], 0, Fs),
    {ok, Text} = erx_session_export:read(Ctl, 0, 4096, Fs),
    ?assertEqual(144, byte_size(Text)),
    ?assertEqual({error, einval}, erx_session_export:read(Ctl, 0, 143, Fs)),
    ?assertEqual({ok, <<>>}, erx_session_export:read(Ctl, 144, 4096, Fs)),
    ?assertEqual({error, eacces}, open([<<"dev">>, <<"ctl">>], ?ERX_P9_O_WRONLY, Fs)),
    ?assertEqual({error, eacces}, open([<<"dev">>, <<"ctl">>], ?ERX_P9_O_RDWR, Fs)).

%% A read of kbd or mouse, which waits for a record, waits at the draw connection, its
%% keeper, which relays it; nothing of it reaches the window from the callback.
kbd_and_mouse_reads_wait_at_the_connection_test() ->
    {Fs, Conn} = window_fs(d),
    flush_win(),
    {ok, Kbd} = open([<<"dev">>, <<"kbd">>], 0, Fs),
    {ok, Mouse} = open([<<"dev">>, <<"mouse">>], 0, Fs),
    ?assertEqual({wait, Conn, {read, kbd, 3, 64}}, erx_session_export:read(Kbd, 3, 64, Fs)),
    ?assertEqual({wait, Conn, {read, mouse, 0, ?ERX_WINDOWS_MOUSE_RECORD}},
                 erx_session_export:read(Mouse, 0, ?ERX_WINDOWS_MOUSE_RECORD, Fs)),
    ?assertEqual([], win_events()).

a_draw_write_is_one_call_of_the_connection_test() ->
    {Fs, Conn} = window_fs(d),
    {ok, Draw} = open([<<"dev">>, <<"draw">>], ?ERX_P9_O_RDWR, Fs),
    ?assertEqual({ok, 3, 0}, erx_session_export:write(Draw, 0, <<"abc">>, Fs)),
    ?assertEqual({error, eio}, erx_session_export:write(Draw, 0, <<"bad">>, Fs)),
    exit(Conn, kill),
    ?assertEqual({error, ebadf}, erx_session_export:write(Draw, 0, <<"abc">>, Fs)),
    ?assertEqual({error, ebadf}, read([<<"dev">>, <<"ctl">>], 144, Fs)).

the_window_files_relay_on_the_windows_own_handle_test() ->
    {Fs, _} = window_fs(d),
    flush_win(),
    {ok, Wctl} = open([<<"dev">>, <<"wctl">>], ?ERX_P9_O_RDWR, Fs),
    ?assertEqual({ok, 4, 0}, erx_session_export:write(Wctl, 0, <<"move">>, Fs)),
    {ok, _} = read([<<"dev">>, <<"label">>], 64, Fs),
    ?assertEqual({error, eacces}, open([<<"dev">>, <<"kbd">>], ?ERX_P9_O_WRONLY, Fs)),
    ?assertEqual([{write_at, wctl, 0, <<"move">>}, {read_at, label, 0, 64}], win_events()).

each_clipboard_open_has_a_fid_of_its_own_test() ->
    {Fs, _} = window_fs(clip),
    flush_win(),
    {ok, A} = open([<<"dev">>, <<"clipboard">>], ?ERX_P9_O_RDWR bor ?ERX_P9_O_TRUNC, Fs),
    {ok, B} = open([<<"dev">>, <<"clipboard">>], 0, Fs),
    ?assertEqual({ok, <<"snarf">>}, erx_session_export:read(B, 0, 64, Fs)),
    ok = erx_session_export:clunk(A, Fs),
    Self = self(),
    ?assertMatch([{clipboard_open, Trunc, Self}, {clipboard_open, 0, Self}, {clipboard_close, _}]
                 when Trunc =:= ?ERX_P9_O_RDWR bor ?ERX_P9_O_TRUNC, win_events()).

flush_win() ->
    receive {erx_win, _} -> flush_win() after 0 -> ok end.

win_events() ->
    receive {erx_win, Event} -> [Event | win_events()] after 0 -> [] end.
