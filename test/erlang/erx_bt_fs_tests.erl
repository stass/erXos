%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The control tree's `pair` and `ctl` files through a real erx_fs grant of erx_bt_fs_tree
%% over the file service erx_bt_fs (docs/design-bluetooth.md, "The pairing window", "Bonds
%% and the store"; docs/design-files.md, "Waiting requests"). The `pair` cases stand in for
%% the links, sending `{erx_bt_link, Link, Message}` from processes they spawn, and for the
%% store, sending `{outcome, Link, Tag, Outcome}`; the cases with the store run the real
%% store over a development file and the service under erx_bt_sup's own child
%% specifications. Each wait the cases assert on has a deadline of 1 s.
-module(erx_bt_fs_tests).
-behaviour(supervisor).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([init/1]).

-define(NOFID, 16#ffffffff).
-define(PHONE, {random, <<16#C0, 1, 2, 3, 4, 5>>}).
-define(IDENTITY, {public, <<0, 16#1B, 16#DC, 10, 11, 12>>}).

%% Fixtures --------------------------------------------------------------------

%% The service over a store in State, and a grant of its tree with fid 1 at the root.
service(State) ->
    %% A case that failed before its stop leaves the service of its own running.
    [stop(#{fs => Old, grant => Old}) || Old <- [whereis(erx_bt_fs)], is_pid(Old)],
    {ok, Fs} = erx_bt_fs:start_link(State),
    unlink(Fs),
    grant(Fs).

%% A grant of the tree of the service Fs, with fid 1 at the root.
grant(Fs) ->
    {ok, Grant, _} = erx_fs:start_link(erx_bt_fs_tree, Fs, rw),
    unlink(Grant),
    {ok, _} = call(Grant, {attach, 1, ?NOFID, <<"user">>, <<"bt">>, 0}),
    #{fs => Fs, grant => Grant}.

stop(#{fs := Fs, grant := Grant}) ->
    [begin Monitor = monitor(process, Pid), exit(Pid, kill), receive {'DOWN', Monitor, _, _, _} -> ok end end
     || Pid <- [Grant, Fs]],
    ok.

%% Opens pair at Fid for reading and writing: the open's answer.
open(Grant, Fid) ->
    {ok, _} = call(Grant, {walk, 1, Fid, [<<"pair">>]}),
    call(Grant, {lopen, Fid, ?ERX_P9_O_RDWR}).

%% A window at Fid in Mode, its first line read.
window(Grant, Fid, Mode) ->
    {ok, _, _} = open(Grant, Fid),
    {ok, _, _} = call(Grant, {write, Fid, 0, Mode}),
    {ok, <<"waiting\n">>} = call(Grant, {read, Fid, 0, 4096}).

call(Grant, Request) ->
    case reply_within(send(Grant, Request), 1000) of
        none -> erlang:error({no_reply, Request});
        Reply -> Reply
    end.

send(Grant, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), Request},
    Alias.

reply_within(Alias, Timeout) ->
    receive {erx_9p, Alias, Reply} -> Reply after Timeout -> none end.

%% A stand-in link: it sends what the test tells it as the link and passes on what the
%% window sends it.
link() ->
    Test = self(),
    spawn(fun() -> link_loop(Test) end).

link_loop(Test) ->
    receive
        {as_link, Message} -> {erx_bt_fs, node()} ! {erx_bt_link, self(), Message};
        {say, Message} -> {erx_bt_fs, node()} ! {erx_bt_link, self(), Message}, Test ! {said, self()};
        {window, Message} -> Test ! {told, self(), Message}
    end,
    link_loop(Test).

%% Link sends Message to the window, and the window's answer, if any, within 1 s.
tell(Link, Message) ->
    Link ! {as_link, Message},
    told(Link).

told(Link) ->
    receive {told, Link, Message} -> Message after 1000 -> none end.

%% Cases -----------------------------------------------------------------------

%% A display window: the passkey and the outcome are lines, the file then ends, and a
%% new window opens once the pairing has its outcome.
a_pairing_reaches_the_opener_as_lines_test() ->
    #{grant := Grant} = S = service(read),
    window(Grant, 2, <<"display\n">>),
    Link = link(),
    ?assertMatch({admission, 1, {open, display, #{passkey := _}}}, tell(Link, {admit, 1, ?PHONE})),
    Read = send(Grant, {read, 2, 0, 4096}),
    ?assertEqual(none, reply_within(Read, 100)),
    say(Link, {passkey, 1, 42}),
    ?assertEqual({ok, <<"passkey 000042 C0:01:02:03:04:05\n">>}, reply_within(Read, 1000)),
    say(Link, {keeping, 1}),
    erx_bt_fs ! {outcome, Link, 1, {bonded, ?IDENTITY, authenticated}},
    ?assertEqual({ok, <<"bonded 00:1B:DC:0A:0B:0C public authenticated\n">>}, call(Grant, {read, 2, 0, 4096})),
    ?assertEqual({ok, <<>>}, call(Grant, {read, 2, 0, 4096})),
    ?assertMatch({ok, _, _}, open(Grant, 3)),
    stop(S).

%% A second open while a window is open answers ebusy; a write other than a mode einval.
pair_refuses_a_second_window_and_a_bad_mode_test() ->
    #{grant := Grant} = S = service(read),
    {ok, _, _} = open(Grant, 2),
    ?assertEqual({error, ebusy}, open(Grant, 3)),
    ?assertEqual({error, einval}, call(Grant, {write, 2, 0, <<"displayx">>})),
    ?assertEqual(ok, call(Grant, {clunk, 2})),
    ?assertMatch({ok, _, _}, open(Grant, 4)),
    stop(S).

pair_answers_eio_while_the_store_is_unknown_test() ->
    #{grant := Grant} = S = service({unknown, start}),
    ?assertEqual({error, eio}, open(Grant, 2)),
    stop(S).

%% The store and the window under erx_bt_sup's own child specifications and strategy,
%% the store's development file at Volume/bt: Prepare(Volume) runs before the store's
%% start reads, then Case(Sup, Volume). The supervisor, the setting and the directory go
%% whatever the case's outcome, so a failure leaves no store or service registered for the
%% cases after it; a case kills the grants it made.
under_sup(Prepare, Case) ->
    Volume = filename:absname("bt-volume"),
    _ = file:del_dir_r(Volume),
    ok = application:set_env(erx_bt, state_dir, filename:join(Volume, "bt")),
    try
        Prepare(Volume),
        {ok, {Flags, Children}} = erx_bt_sup:init([]),
        Window = [Spec || #{id := Id} = Spec <- Children, Id =:= erx_bt_store orelse Id =:= erx_bt_fs],
        ?assertMatch([#{id := erx_bt_store}, #{id := erx_bt_fs}], Window),
        ?assertMatch(#{strategy := rest_for_one}, Flags),
        {ok, Sup} = supervisor:start_link(?MODULE, {Flags, Window}),
        unlink(Sup),
        try
            Case(Sup, Volume)
        after
            Down = monitor(process, Sup),
            exit(Sup, shutdown),
            receive {'DOWN', Down, _, _, _} -> ok end
        end
    after
        application:unset_env(erx_bt, state_dir),
        _ = file:del_dir_r(Volume)
    end.

-doc false.
init(Spec) ->
    {ok, Spec}.

no_volume(_Volume) -> ok.

%% A volume whose state holds one bond, of ?IDENTITY.
a_bond(Volume) ->
    ok = file:make_dir(Volume),
    Bond = #{identity => ?IDENTITY, irk => <<1:128>>, ltk => <<2:128>>, level => authenticated,
             hash => <<>>, subscriptions => #{}},
    {ok, Blob} = erx_bt_state:encode(#{address => <<2#11:2, 7:46>>, bonds => [Bond]}),
    ok = erx_bt_state_file:put(filename:join(Volume, "bt"), 1, Blob).

%% Writes Bytes to ctl through Fid, opened for writing and clunked after: `ok` or the
%% write's refusal.
ctl(Grant, Fid, Bytes) ->
    {ok, _} = call(Grant, {walk, 1, Fid, [<<"ctl">>]}),
    {ok, _, _} = call(Grant, {lopen, Fid, ?ERX_P9_O_WRONLY}),
    Answer = call(Grant, {write, Fid, 0, Bytes}),
    ok = call(Grant, {clunk, Fid}),
    case Answer of
        {ok, _, _} -> ok;
        {error, _} = Refused -> Refused
    end.

%% The window starts with the store's state, so a store whose start found no volume for
%% its directory makes pair answer eio; the store's end ends the window and the stack,
%% whose restart is the domain's (docs/design-bluetooth.md, "Concurrency").
the_window_starts_with_the_store_and_ends_with_it_test() ->
    under_sup(fun no_volume/1,
              fun(Sup, _Volume) ->
                      Unread = grant(whereis(erx_bt_fs)),
                      ?assertEqual({error, eio}, open(maps:get(grant, Unread), 2)),
                      Monitor = monitor(process, maps:get(fs, Unread)),
                      Stack = monitor(process, Sup),
                      exit(whereis(erx_bt_store), kill),
                      receive {'DOWN', Monitor, _, _, _} -> ok after 1000 -> erlang:error(window_not_ended) end,
                      receive {'DOWN', Stack, _, _, _} -> ok after 1000 -> erlang:error(stack_not_ended) end,
                      exit(maps:get(grant, Unread), kill)
              end).

%% A store unknown since its start refuses ctl's `forget ADDRESS TYPE`, and `forget all` while
%% it cannot read; once its volume has come, `forget all` puts an empty state, and pair
%% opens from then on without a restart, the window told by the confirmed answer.
forget_all_ends_the_refusal_of_a_store_unknown_since_its_start_test() ->
    under_sup(fun no_volume/1,
              fun(_Sup, Volume) ->
                      #{grant := Grant} = grant(whereis(erx_bt_fs)),
                      ?assertEqual({error, eio}, open(Grant, 2)),
                      ?assertEqual({error, eio}, ctl(Grant, 3, <<"forget 00:1B:DC:0A:0B:0C public\n">>)),
                      ?assertEqual({error, eio}, ctl(Grant, 3, <<"forget all\n">>)),
                      ?assertEqual({error, eio}, open(Grant, 4)),
                      ok = file:make_dir(Volume),
                      ?assertEqual(ok, ctl(Grant, 3, <<"forget all\n">>)),
                      ?assertMatch({ok, _, _}, open(Grant, 5)),
                      exit(Grant, kill)
              end).

%% ctl forgets a kept bond by its identity, its address in either case with its type, and
%% then answers enoent for it, as for the same address of another type; any write but
%% `forget ADDRESS TYPE` or `forget all` is einval, an open for reading
%% eacces, and a create, which a shell's redirection sends, opens ctl.
ctl_forgets_a_bond_and_refuses_the_rest_test() ->
    under_sup(fun a_bond/1,
              fun(_Sup, _Volume) ->
                      #{grant := Grant} = grant(whereis(erx_bt_fs)),
                      ?assertEqual({error, enoent}, ctl(Grant, 2, <<"forget 00:1B:DC:0A:0B:0D public">>)),
                      ?assertEqual({error, enoent}, ctl(Grant, 2, <<"forget 00:1B:DC:0A:0B:0C random">>)),
                      ?assertEqual(ok, ctl(Grant, 2, <<"forget 00:1b:dc:0a:0B:0C public\n">>)),
                      ?assertEqual({error, enoent}, ctl(Grant, 2, <<"forget 00:1B:DC:0A:0B:0C public">>)),
                      [?assertEqual({error, einval}, ctl(Grant, 2, Bytes))
                       || Bytes <- [<<>>, <<"\n">>, <<"forget">>, <<"forget ">>, <<"forget all\n\n">>,
                                    <<"forget ALL">>, <<"forget  all">>, <<"forget all ">>, <<"reset">>,
                                    <<"forget 00:1B:DC:0A:0B public">>, <<"forget 00:1B:DC:0A:0B:0C:0D public">>,
                                    <<"forget 00-1B-DC-0A-0B-0C public">>, <<"forget +0:1B:DC:0A:0B:0C public">>,
                                    <<"forget 0G:1B:DC:0A:0B:0C public">>, <<"forget 00:1B:DC:0A:0B:0C public\r\n">>,
                                    <<"forget 00:1B:DC:0A:0B:0C">>, <<"forget 00:1B:DC:0A:0B:0C\n">>,
                                    <<"forget 00:1B:DC:0A:0B:0C PUBLIC">>, <<"forget 00:1B:DC:0A:0B:0C  public">>,
                                    <<"forget 00:1B:DC:0A:0B:0C static">>, <<"forget 00:1B:DC:0A:0B:0C public ">>,
                                    <<"forget 00:1B:DC:0A:0B:0C public\n\n">>]],
                      {ok, _} = call(Grant, {walk, 1, 3, [<<"ctl">>]}),
                      ?assertEqual({error, eacces}, call(Grant, {lopen, 3, 0})),
                      ?assertEqual({error, eacces}, call(Grant, {lopen, 3, ?ERX_P9_O_RDWR})),
                      {ok, _} = call(Grant, {walk, 1, 4, []}),
                      ?assertMatch({ok, _, _}, call(Grant, {lcreate, 4, <<"ctl">>,
                                                            ?ERX_P9_O_WRONLY bor ?ERX_P9_O_TRUNC, 8#200, 0})),
                      ?assertMatch({ok, _, _}, call(Grant, {write, 4, 0, <<"forget all">>})),
                      exit(Grant, kill)
              end).

%% Clunking the window withdraws the pairing it took; the window answers ebusy until the
%% link reports the withdrawal, and the wait it then starts holds the next window.
clunking_the_window_withdraws_its_pairing_test() ->
    #{grant := Grant} = S = service(read),
    window(Grant, 2, <<"display">>),
    Link = link(),
    {admission, 4, {open, display, _}} = tell(Link, {admit, 4, ?PHONE}),
    ?assertEqual(ok, call(Grant, {clunk, 2})),
    ?assertEqual({withdraw, 4}, told(Link)),
    ?assertEqual({error, ebusy}, open(Grant, 3)),
    say(Link, {outcome, 4, {failed, withdrawn}}),
    {ok, _, _} = open(Grant, 4),
    {ok, _, _} = call(Grant, {write, 4, 0, <<"nodisplay">>}),
    ?assertEqual({ok, <<"wait 2\n">>}, call(Grant, {read, 4, 0, 4096})),
    ?assertEqual({admission, 5, waiting}, tell(Link, {admit, 5, ?PHONE})),
    stop(S).

%% The regression of "A link's end": a link killed after its `open` verdict writes
%% `failed ADDR disconnected` and starts the wait.
a_killed_link_fails_the_pairing_disconnected_test() ->
    #{grant := Grant} = S = service(read),
    window(Grant, 2, <<"display">>),
    Link = link(),
    {admission, 1, {open, display, _}} = tell(Link, {admit, 1, ?PHONE}),
    Read = send(Grant, {read, 2, 0, 4096}),
    exit(Link, kill),
    ?assertEqual({ok, <<"failed C0:01:02:03:04:05 disconnected\n">>}, reply_within(Read, 1000)),
    Other = link(),
    ?assertMatch({wait, Ms} when Ms > 0, tell(Other, wait)),
    stop(S).

%% A link killed after its `keeping` leaves the store's outcome as the pairing's.
a_link_killed_after_keeping_leaves_the_store_to_decide_test() ->
    #{grant := Grant} = S = service(read),
    window(Grant, 2, <<"display">>),
    Link = link(),
    {admission, 1, {open, display, _}} = tell(Link, {admit, 1, ?PHONE}),
    say(Link, {keeping, 1}),
    exit(Link, kill),
    ?assertEqual({error, ebusy}, open(Grant, 3)),
    erx_bt_fs ! {outcome, Link, 1, {bonded, ?IDENTITY, unauthenticated}},
    ?assertEqual({ok, <<"bonded 00:1B:DC:0A:0B:0C public unauthenticated\n">>}, call(Grant, {read, 2, 0, 4096})),
    ?assertEqual({wait, 0}, tell(link(), wait)),
    stop(S).

%% The grant's end closes its window, as its clunk would.
the_openers_end_closes_the_window_test() ->
    #{fs := Fs, grant := Grant} = S = service(read),
    window(Grant, 2, <<"display">>),
    exit(Grant, kill),
    {ok, Other, _} = erx_fs:start_link(erx_bt_fs_tree, Fs, rw),
    unlink(Other),
    {ok, _} = call(Other, {attach, 1, ?NOFID, <<"user">>, <<"bt">>, 0}),
    ?assertMatch({ok, _, _}, open(Other, 2)),
    stop(S#{grant := Other}).

%% A waiting read that is flushed answers eintr, and the next line goes to the next read.
a_flushed_read_answers_eintr_test() ->
    #{grant := Grant} = S = service(read),
    window(Grant, 2, <<"display">>),
    Read = send(Grant, {read, 2, 0, 4096}),
    Flush = send(Grant, {flush, Read}),
    ?assertEqual({error, eintr}, reply_within(Read, 1000)),
    ?assertEqual(ok, reply_within(Flush, 1000)),
    Link = link(),
    {admission, 1, _} = tell(Link, {admit, 1, ?PHONE}),
    say(Link, {passkey, 1, 7}),
    ?assertEqual({ok, <<"passkey 000007 C0:01:02:03:04:05\n">>}, call(Grant, {read, 2, 0, 4096})),
    stop(S).

%% A crash report shows the core's facts, never a passkey line.
status_hides_the_lines_test() ->
    #{fs := Fs, grant := Grant} = S = service(read),
    window(Grant, 2, <<"display">>),
    Link = link(),
    {admission, 1, _} = tell(Link, {admit, 1, ?PHONE}),
    say(Link, {passkey, 1, 424242}),
    Shown = lists:flatten(io_lib:format("~p", [sys:get_status(Fs)])),
    ?assertEqual(nomatch, string:find(Shown, "424242")),
    stop(S).

%% Link sends Message to the window, which has taken it once this returns: the test's
%% next message to the window comes after it.
say(Link, Message) ->
    Link ! {say, Message},
    receive {said, Link} -> _ = sys:get_state(erx_bt_fs), ok after 1000 -> erlang:error(not_said) end.
