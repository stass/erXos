%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A program's own /dev (docs/design-files.md, "A program's window") over the real window
%% system of erx_win_tests's fixture: erx_winfs under the single policy, erx_win and
%% erx_draw_conn, with the tree started as erx_session_export:start_window/1 starts it, an
%% erx_session_export grant in program-window mode. The test is the program: a 9P client
%% of that grant, sending what the handler sends once the resolver has reduced a path to
%% plain names. A recorder traces erx_winfs's walk/3 and write/4, the display's side of
%% every walk and every write, so a case can show that nothing the program sends reaches
%% the window's ctl or directory. test/host/erx_win_test.rb runs these cases with the
%% fixture's and applies the seeded faults.
%%
%% Cases: the corpus of the program's requests reaches no walk and no write at the display;
%% a window removed and made again under the same name is never reached through the old
%% tree; a resize reaches the program as an r record of mouse, after which ctl shows the
%% new rectangle; a kbd read waiting for a key holds up no other request of the grant, a
%% flush answers it eintr and gives the next key to the next read, and the window's end
%% answers a read still held eio; the connection sends one read of a file to the display
%% at a time, so the kbd reads waiting on two windows leave the session's display grant
%% free for a present, and a read flushed while it waits behind another never reaches the
%% display; start_window/1's handler and its tree end at the connection's end; erx_win's
%% clipboard probe answers the grant's clipboard, an open
%% the display refuses leaves no fid on the display's grant, and an open holds one of the
%% opener's.

-module(erx_win_dev_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(SERVICE, screen).
-define(CLIP, clip).
-define(SYSTEM, 1).
-define(SESSION, 10).
-define(ROOT, 1).
-define(WAIT, 5000).
-define(WINDOW_DEV, [<<"null">>, <<"tty">>, <<"urandom">>, <<"zero">>, <<"draw">>, <<"ctl">>, <<"kbd">>,
                     <<"mouse">>, <<"wctl">>, <<"label">>]).

%% Fixtures ------------------------------------------------------------------

%% The case under erx_win_tests's fixture, with a program's /dev on a window named w1;
%% the tree's grant and any tracing end with the case.
with_dev(Case) ->
    erx_win_tests:with(fun(Fixture) ->
                               #{tree := Tree} = Dev = dev(<<"w1">>),
                               try Case(Fixture, Dev)
                               after
                                   _ = erlang:trace(all, false, [call]),
                                   exit(Tree, kill)
                               end
                       end).

%% The window, its connection and the tree's grant, as erx_session_export:start_window/1 makes
%% them, presented once, but for the window's name, Name, which the cases walk to, the tree's end, which
%% with_dev/1 brings about rather than the test process's, and the link to the connection; fid 1 is attached to the root.
dev(Name) ->
    ok = erx_fs_version:init(),
    {ok, Window} = erx_win:open(?SERVICE, #{name => Name}),
    %% Its frame on the screen, so the keys the cases type reach it.
    ok = erx_win:present(Window, []),
    {ok, Conn} = erx_draw_conn:start(#{window => Window}),
    Args = #{window => #{window => Window, conn => Conn, display => ?SERVICE,
                         clipboard => erx_win:clipboard(?SERVICE)}},
    {ok, Tree, _} = erx_fs:start_link(erx_session_export, Args, rw, #{client => own}),
    unlink(Tree),
    {ok, _} = call(Tree, {attach, ?ROOT, ?ERX_P9_NOFID, <<"user">>, <<"export">>, 0}),
    #{tree => Tree, window => Window, conn => Conn}.

%% One request and its reply, as erx_file_remote sends it: to a fresh alias.
call(Grant, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), Request},
    receive {erx_9p, Alias, Reply} -> Reply after ?WAIT -> erlang:error({no_reply, Request}) end.

%% One request sent and not waited for: the alias its reply comes to, which stays active
%% after the reply, so a second reply to it would arrive too.
send(Grant, Request) ->
    Alias = alias(),
    Grant ! {erx_9p, Alias, self(), Request},
    Alias.

%% The reply at Alias, or none when none arrives within Wait milliseconds.
replied(Alias, Wait) ->
    receive {erx_9p, Alias, Reply} -> Reply after Wait -> none end.

%% A walk of Path from Grant's root fid into a new fid: the fid, or the walk's error,
%% enoent for one that stopped short.
walk(Grant, Path) ->
    Fid = erlang:unique_integer([positive]) rem 16#7fffffff + 2,
    case call(Grant, {walk, ?ROOT, Fid, Path}) of
        {ok, Qids} when length(Qids) =:= length(Path) -> {ok, Fid};
        {ok, _Short} -> {error, enoent};
        {error, _} = Error -> Error
    end.

open(Grant, Path, Flags) ->
    maybe
        {ok, Fid} ?= walk(Grant, Path),
        {ok, _Qid, _Iounit} ?= call(Grant, {lopen, Fid, Flags}),
        {ok, Fid}
    end.

read(Grant, Path, Count) ->
    maybe
        {ok, Fid} ?= open(Grant, Path, 0),
        call(Grant, {read, Fid, 0, Count})
    end.

write(Grant, Path, Bytes) ->
    maybe
        {ok, Fid} ?= open(Grant, Path, ?ERX_P9_O_RDWR),
        call(Grant, {write, Fid, 0, Bytes})
    end.

%% Count reads of the grant's kbd, each sent and not waited for.
send_reads(Grant, Count) ->
    {ok, Kbd} = open(Grant, [<<"dev">>, <<"kbd">>], 0),
    [send(Grant, {read, Kbd, 0, 64}) || _ <- lists:seq(1, Count)].

listing(Grant, Path) ->
    {ok, Fid} = open(Grant, Path, 0),
    {ok, Entries} = call(Grant, {readdir, Fid, 0, 8192}),
    [Name || {_Qid, _Offset, _Type, Name} <- Entries].

%% The rectangle the tree's ctl shows: its fifth to eighth fields.
ctl_rect(Tree) ->
    {ok, Text} = read(Tree, [<<"dev">>, <<"ctl">>], 4096),
    [binary_to_integer(Field) || Field <- lists:sublist(binary:split(Text, <<" ">>, [global, trim_all]), 5, 4)].

%% Records erx_winfs's walk/3 and write/4 calls, in any process, from now until
%% recorded/1: each walk as {walk, Node, Name} and each write as {write, Node, Bytes}.
record() ->
    Recorder = spawn_link(fun() -> recording([]) end),
    1 = erlang:trace_pattern({erx_winfs, walk, 3}, true, [local]),
    1 = erlang:trace_pattern({erx_winfs, write, 4}, true, [local]),
    _ = erlang:trace(all, true, [call, {tracer, Recorder}]),
    Recorder.

recording(Calls) ->
    receive
        {trace, _, call, {erx_winfs, walk, [Node, Name, _]}} -> recording([{walk, Node, Name} | Calls]);
        {trace, _, call, {erx_winfs, write, [Node, _, Bytes, _]}} -> recording([{write, Node, Bytes} | Calls]);
        {recorded, Test} -> Test ! {recorded, lists:reverse(Calls)}
    end.

%% What the recorder saw, every trace message delivered first.
recorded(Recorder) ->
    _ = erlang:trace(all, false, [call]),
    Ref = erlang:trace_delivered(all),
    receive {trace_delivered, all, Ref} -> ok end,
    _ = erlang:trace_pattern({erx_winfs, '_', '_'}, false, [local]),
    Recorder ! {recorded, self()},
    receive {recorded, Calls} -> Calls after ?WAIT -> error(no_record) end.

%% A clipboard-carrying grant of the display for the same session, installed where the
%% stand-in erx:cap/1 finds it as ?CLIP.
clipboard_grant() ->
    Tag = erlang:unique_integer([positive]),
    erx_winfs ! {erx_origin, ?SYSTEM, {erx_facet_mint, Tag, ?SERVICE, ?SESSION, root,
                                       #{session => true, windows => 2, clipboard => true}}},
    Grant = receive {minted, Tag, {ok, G}} -> G after ?WAIT -> error(no_mint) end,
    persistent_term:put({erx_stand_in, cap, ?CLIP}, Grant),
    persistent_term:put({erx_stand_in, owner, Grant}, ?SESSION),
    Grant.

%% Whether Grant watches Owner, as a grant watches a client holding an open fid on it.
watches(Grant, Owner) ->
    {monitored_by, Watchers} = process_info(Owner, monitored_by),
    lists:member(Grant, Watchers).

%% Runs Fun in a process of its own that stays alive, so the fids it makes stay its own
%% until it ends: its answer and the process.
in_holder(Fun) ->
    Test = self(),
    Holder = spawn(fun() -> Test ! {held, self(), Fun()}, receive stop -> ok end end),
    receive {held, Holder, Answer} -> {Answer, Holder} after ?WAIT -> error(no_holder) end.

%% Cases ---------------------------------------------------------------------

the_corpus_reaches_no_window_file_test() ->
    with_dev(fun(_Fixture, #{tree := Tree}) ->
        Recorder = record(),
        ?assertEqual([<<"dev">>], listing(Tree, [])),
        ?assertEqual(?WINDOW_DEV, listing(Tree, [<<"dev">>])),
        Each = [{Name, walk(Tree, [<<"dev">>, Name])} || Name <- ?WINDOW_DEV],
        ?assertEqual([], [Name || {Name, Walked} <- Each, element(1, Walked) =/= ok]),
        %% /dev/ctl is the connection's 144 bytes, and no open of it writes.
        {ok, Ctl} = read(Tree, [<<"dev">>, <<"ctl">>], 4096),
        ?assertEqual(144, byte_size(Ctl)),
        ?assertEqual({error, eacces}, open(Tree, [<<"dev">>, <<"ctl">>], ?ERX_P9_O_WRONLY)),
        ?assertEqual({error, eacces}, write(Tree, [<<"dev">>, <<"ctl">>], <<"present 0 0 1 1\n">>)),
        %% No name leads into the window's directory.
        ?assertMatch({error, _}, walk(Tree, [<<"dev">>, <<"kbd">>, <<"x">>])),
        ?assertMatch({error, _}, walk(Tree, [<<"dev">>, <<"kbd">>, <<"ctl">>])),
        ?assertMatch({error, _}, walk(Tree, [<<"dev">>, <<"w1">>, <<"ctl">>])),
        ?assertMatch({error, _}, walk(Tree, [<<"dev">>, <<"w1">>])),
        ?assertMatch({error, _}, walk(Tree, [<<"w1">>])),
        %% The one relayed write the corpus makes shows the recorder sees the display's side.
        {ok, 2, _} = write(Tree, [<<"dev">>, <<"label">>], <<"me">>),
        ?assertMatch([{write, {file, _, _, label}, <<"me">>}], recorded(Recorder))
    end).

a_window_removed_under_the_program_is_never_reached_again_test() ->
    with_dev(fun(#{grant := Display}, #{tree := Tree}) ->
        %% The session removes w1 through its own grant and makes another w1.
        {ok, _} = call(Display, {attach, ?ROOT, ?ERX_P9_NOFID, <<"user">>, ?ERX_WINDOWS_TREE_BYTES, 0}),
        {ok, Old} = walk(Display, [<<"w1">>]),
        ok = call(Display, {remove, Old}),
        {ok, New} = erx_win:open(?SERVICE, #{name => <<"w1">>}),
        {ok, 3, _} = erx_win:write_at(New, label, 0, <<"new">>),
        Recorder = record(),
        ?assertMatch({error, _}, read(Tree, [<<"dev">>, <<"label">>], 64)),
        ?assertMatch({error, _}, write(Tree, [<<"dev">>, <<"label">>], <<"evil">>)),
        ?assertMatch({error, _}, write(Tree, [<<"dev">>, <<"wctl">>], <<"move -r 0 0 2 2\n">>)),
        Calls = recorded(Recorder),
        ?assertEqual({ok, <<"new">>}, erx_win:read_at(New, label, 0, 64)),
        %% Every write the old tree sent named the removed window, whose process is gone.
        ?assertEqual([], [Call || {write, {file, _, Proc, _}, _} = Call <- Calls, is_process_alive(Proc)])
    end).

a_resize_reaches_ctl_before_the_program_sees_its_r_test() ->
    with_dev(fun(_Fixture, #{tree := Tree}) ->
        ?assertEqual([0, 0, 8, 4], ctl_rect(Tree)),
        _ = erx_winfs:attach({0, 0, 6, 3}, <<"x8r8g8b8">>),
        {ok, <<Kind, _/binary>>} = read(Tree, [<<"dev">>, <<"mouse">>], ?ERX_WINDOWS_MOUSE_RECORD),
        ?assertEqual($r, Kind),
        ?assertEqual([0, 0, 6, 3], ctl_rect(Tree))
    end).

%% A kbd read waits at the draw connection, its keeper, not in the grant
%% (docs/design-files.md, "A program's window"): while no key comes, the grant answers
%% another fid's request and a clunk; a flush answers the read eintr, and the key typed
%% then goes to the next read, none of it to the flushed one; the window's end answers
%% a read still held eio.
a_waiting_kbd_read_holds_up_nothing_of_its_grant_test() ->
    with_dev(fun(#{grant := Display}, #{tree := Tree}) ->
        {ok, Kbd} = open(Tree, [<<"dev">>, <<"kbd">>], 0),
        Flushed = send(Tree, {read, Kbd, 0, 64}),
        ?assertEqual({ok, <<>>}, read(Tree, [<<"dev">>, <<"null">>], 16)),
        {ok, Null} = open(Tree, [<<"dev">>, <<"null">>], 0),
        ?assertEqual(ok, call(Tree, {clunk, Null})),
        ?assertEqual(ok, call(Tree, {flush, Flushed})),
        ?assertEqual({error, eintr}, replied(Flushed, 0)),
        ok = erx_winfs:input(<<"kbd">>, {key, down, 30}),
        %% The key down is a k record and the rune it types a c record.
        ?assertMatch({ok, <<"k", _/binary>>}, call(Tree, {read, Kbd, 0, 64})),
        ?assertMatch({ok, <<"c", _/binary>>}, call(Tree, {read, Kbd, 0, 64})),
        ?assertEqual(none, replied(Flushed, 0)),
        Held = send(Tree, {read, Kbd, 0, 64}),
        {ok, _} = call(Display, {attach, ?ROOT, ?ERX_P9_NOFID, <<"user">>, ?ERX_WINDOWS_TREE_BYTES, 0}),
        {ok, W1} = walk(Display, [<<"w1">>]),
        ok = call(Display, {remove, W1}),
        ?assertEqual({error, eio}, replied(Held, ?WAIT))
    end).

waiting_kbd_reads_on_two_windows_leave_the_display_grant_free_test() ->
    with_dev(fun(_Fixture, #{tree := Tree1, window := Window1, conn := Conn1}) ->
        #{tree := Tree2, conn := Conn2} = dev(<<"w2">>),
        try
            %% 80 reads, more than the display grant's 64 requests in flight.
            Reads = lists:append([send_reads(Tree, 40) || Tree <- [Tree1, Tree2]]),
            %% A grant serves its frames in order, so a round trip on each has handed
            %% every read to its connection, and a call to each connection then has
            %% each read it holds sent on, or held back.
            [{ok, <<>>} = read(Tree, [<<"dev">>, <<"null">>], 16) || Tree <- [Tree1, Tree2]],
            [{ok, _} = erx_draw_conn:ctl(Conn) || Conn <- [Conn1, Conn2]],
            ?assertEqual(ok, erx_win:present(Window1, [{0, 0, 1, 1}])),
            ?assertEqual([], [Answer || Read <- Reads, (Answer = replied(Read, 0)) =/= none])
        after
            exit(Tree2, kill)
        end
    end).

a_read_flushed_behind_another_never_reaches_the_display_test() ->
    with_dev(fun(_Fixture, #{tree := Tree, conn := Conn}) ->
        %% The connection's sends to the display, each told apart by its count.
        1 = erlang:trace_pattern({erx_win, send_read, 4}, true, []),
        1 = erlang:trace(Conn, true, [call]),
        {ok, Kbd} = open(Tree, [<<"dev">>, <<"kbd">>], 0),
        [First, Second, Third] = [send(Tree, {read, Kbd, 0, Count}) || Count <- [64, 63, 62]],
        ?assertEqual(ok, call(Tree, {flush, Second})),
        ?assertEqual({error, eintr}, replied(Second, 0)),
        ok = erx_winfs:input(<<"kbd">>, {key, down, 30}),
        %% The key down is a k record and the rune it types a c record.
        ?assertMatch({ok, <<"k", _/binary>>}, replied(First, ?WAIT)),
        ?assertMatch({ok, <<"c", _/binary>>}, replied(Third, ?WAIT)),
        _ = erlang:trace(Conn, false, [call]),
        _ = erlang:trace_pattern({erx_win, send_read, 4}, false, []),
        Ref = erlang:trace_delivered(Conn),
        receive {trace_delivered, Conn, Ref} -> ok end,
        ?assertEqual([64, 62], sent_counts())
    end).

%% The counts of the traced erx_win:send_read/4 calls in this process's mailbox.
sent_counts() ->
    receive {trace, _, call, {erx_win, send_read, [_, kbd, _, Count]}} -> [Count | sent_counts()]
    after 0 -> []
    end.

the_handler_and_its_dev_end_at_the_connection_s_end_test() ->
    erx_win_tests:with(fun(_Fixture) ->
        ok = erx_fs_version:init(),
        {{ok, {Tree, _, _}}, Handler} = in_holder(fun() -> erx_session_export:start_window(?SERVICE) end),
        {links, Links} = process_info(Handler, links),
        [Conn] = Links -- [Tree],
        Watches = [monitor(process, Ended) || Ended <- [Handler, Tree]],
        exit(Conn, kill),
        ?assertEqual([ended, ended], [receive {'DOWN', Watch, process, _, _} -> ended after ?WAIT -> lives end
                                      || Watch <- Watches])
    end).

the_clipboard_opens_on_a_fid_of_its_own_test() ->
    erx_win_tests:with(fun(_Fixture) ->
        Clip = clipboard_grant(),
        ?assert(erx_win:clipboard(?CLIP)),
        ?assertNot(erx_win:clipboard(?SERVICE)),
        {{error, einval}, Refused} = in_holder(fun() -> erx_win:clipboard_open(?CLIP, ?ERX_P9_O_APPEND) end),
        {{ok, _Opened}, Holder} = in_holder(fun() -> erx_win:clipboard_open(?CLIP, ?ERX_P9_O_RDWR) end),
        ?assertNot(watches(Clip, Refused)),
        ?assert(watches(Clip, Holder)),
        %% A grant without the clipboard cannot walk to it.
        ?assertMatch({error, _}, erx_win:clipboard_open(?SERVICE, 0)),
        [Pid ! stop || Pid <- [Refused, Holder]]
    end).
