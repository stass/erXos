%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The window system on stock OTP (test/host/erx_winfs_test.rb): erx_winfs under the
%% single policy, its grants started as erx_fs grants of this domain, erx_window, and
%% erx_screen over a driver model, with erx_memdraw's NIF built for the host and a
%% stand-in pixel area (test/display/erx_area_stand_in.c). A client is the test,
%% speaking the file protocol to its grant as erx_file_remote does.
%%
%% G1: under the single policy the session's first window is shown and every other
%% window hidden, a hidden window's kbd receives nothing and its wctl show is refused,
%% and when the shown window ends, by its holder's end or its directory's removal, the
%% session's next oldest is shown. G3: against a driver that never answers, many wctl
%% writes and window makes and removes leave the window system and the screen
%% responsive, the screen's mailbox drained and its frame the one it started with, and
%% the screen's end answers a held present EIO. G6: a one-pixel present pushes one
%% rectangle of one pixel, and a change that shows nothing new pushes nothing.

-module(erx_winfs_tests).
-include_lib("eunit/include/eunit.hrl").

-export([info/1, export/3]).

%% Plan 9's XRGB32: CHAN4(CIgnore, 8, CRed, 8, CGreen, 8, CBlue, 8).
-define(XRGB32, 16#68081828).
-define(WIDTH, 8).
-define(HEIGHT, 4).
-define(DRIVER, erx_winfs_test_driver).
-define(SYSTEM, 1).
%% The display's service, as the display domain's display variable names it.
-define(SERVICE, screen).
-define(SESSION, 10).
-define(OTHER, 20).
-define(NOFID, 16#ffffffff).
-define(AT_REMOVEDIR, 16#200).
-define(O_RDONLY, 0).
-define(O_RDWR, 2).
-define(WAIT, 5000).
-define(QUIET, 300).

%% Fixtures ------------------------------------------------------------------

-doc false.
info(Driver) ->
    gen_server:call(Driver, info).

%% The export table's stand-in: a grant of this domain exports itself to no one.
-doc false.
export(_Grant, _Rights, _Peer) ->
    ok.

%% A driver model registered as ?DRIVER over a screen image of its own: it tells the
%% test each flush and answers it, or, as `never`, answers none.
driver(Mode) ->
    Test = self(),
    {ok, Screen} = erx_memdraw:alloc(?XRGB32, {0, 0, ?WIDTH, ?HEIGHT}, {0, 0, ?WIDTH, ?HEIGHT},
                                     false, 16#000000ff),
    Info = #{width => ?WIDTH, height => ?HEIGHT, chan => <<"x8r8g8b8">>, screen => Screen,
             partial => true, direct => false},
    Pid = spawn(fun() -> serve(Test, Info, Mode) end),
    true = register(?DRIVER, Pid),
    {Pid, Screen}.

serve(Test, Info, Mode) ->
    receive
        {'$gen_call', From, info} ->
            gen_server:reply(From, Info);
        {'$gen_call', From, {flush, Rects, _Image}} ->
            Test ! {flushed, Rects},
            ok = case Mode of
                     answer -> gen_server:reply(From, ok);
                     never -> ok
                 end
    end,
    serve(Test, Info, Mode).

%% The window system, then the screen over the driver model, as erx_fb_sup starts them.
start(Mode) ->
    _ = [kill(Pid) || Name <- [erx_screen, erx_winfs, ?DRIVER], Pid <- [whereis(Name)], is_pid(Pid)],
    ok = forget_flushes(),
    Test = self(),
    {Driver, Image} = driver(Mode),
    {ok, Winfs} = erx_winfs:start_link(#{service => ?SERVICE, system => ?SYSTEM, exports => ?MODULE,
                                         minted => fun(Tag, Reply) -> Test ! {minted, Tag, Reply} end,
                                         area => fun area_of/1, clients => own, provide => false,
                                         policy => {erx_wm_single, #{}}}),
    {ok, Screen} = erx_screen:start_link({?MODULE, ?DRIVER}),
    true = unlink(Winfs),
    true = unlink(Screen),
    #{driver => Driver, image => Image, winfs => Winfs, screen => Screen}.

stop(#{driver := Driver, winfs := Winfs, screen := Screen}) ->
    _ = [kill(P) || P <- [Screen, Winfs, Driver]],
    _ = [persistent_term:erase(K) || {{?MODULE, _, _} = K, _} <- persistent_term:get()],
    ok.

kill(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok end.

%% A writable stand-in pixel area of one page for Grantee, and an image over its buffer
%% of the screen's size, through which the test draws as the client would.
give_area(Grantee) ->
    {ok, Area, _Page} = erx_memdraw:test_area(16384, write),
    persistent_term:put({?MODULE, area, Grantee}, {ok, Area, 16384}),
    {ok, Image} = erx_memdraw:wrap(Area, 0, {0, 0, ?WIDTH, ?HEIGHT}, ?XRGB32),
    Image.

area_of(Grantee) ->
    persistent_term:get({?MODULE, area, Grantee}, {error, none}).

%% A mint of Grantee's grant, and the grant attached as fid 1.
mint(Grantee, Limits) ->
    Tag = erlang:unique_integer([positive]),
    erx_winfs ! {erx_origin, ?SYSTEM, {erx_facet_mint, Tag, ?SERVICE, Grantee, root, Limits}},
    Grant = receive {minted, Tag, {ok, G}} -> G after ?WAIT -> error(no_mint) end,
    {ok, _} = call(Grant, {attach, 1, ?NOFID, <<"user">>, <<"windows">>, 0}),
    Grant.

call(Grant, Request) ->
    call(Grant, self(), Request).

call(Grant, Owner, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, Owner, Request},
    receive {erx_9p, Alias, Reply} -> Reply
    after ?WAIT -> error({no_reply, Request})
    end.

%% Request sent from a process of its own, whose reply reaches the test as
%% {answered, Tag, Reply}.
call_async(Grant, Request) ->
    Test = self(),
    Tag = make_ref(),
    spawn(fun() -> Test ! {answered, Tag, call(Grant, Test, Request)} end),
    Tag.

answered(Tag) ->
    receive {answered, Tag, Reply} -> Reply after ?WAIT -> error(no_answer) end.

unanswered(Tag) ->
    receive {answered, Tag, Reply} -> error({answered, Reply}) after ?QUIET -> ok end.

mkdir(Grant, Name) ->
    call(Grant, {mkdir, 1, Name, 8#755, 0}).

%% Opens window Name's File as Fid.
open(Grant, Fid, Name, File, Flags) ->
    {ok, _} = call(Grant, {walk, 1, Fid, [Name, File]}),
    ok = element(1, call(Grant, {lopen, Fid, Flags})),
    Fid.

read(Grant, Fid) ->
    call(Grant, {read, Fid, 0, 4096}).

write(Grant, Fid, Data) ->
    call(Grant, {write, Fid, 0, Data}).

state(Grant, Fid) ->
    {ok, Text} = read(Grant, Fid),
    lists:last(binary:split(string:trim(Text), <<" ">>, [global, trim_all])).

key(Rune) ->
    erx_winfs:input(#{device => <<"kbd">>, at => 0, event => {key, down, 30, Rune}}).

flushed() ->
    receive {flushed, Rects} -> Rects after ?WAIT -> error(no_flush) end.

no_flush() ->
    receive {flushed, Rects} -> error({flushed, Rects}) after ?QUIET -> ok end.

%% Flushes a test before this one left in the mailbox.
forget_flushes() ->
    receive {flushed, _} -> forget_flushes() after 0 -> ok end.

drain_flushes() ->
    receive {flushed, _} -> drain_flushes() after ?QUIET -> ok end.

%% G1 ------------------------------------------------------------------------

the_single_policy_shows_the_sessions_oldest_window_test_() ->
    {timeout, 60, fun single_policy/0}.

single_policy() ->
    World = start(answer),
    Session = mint(?SESSION, #{session => true}),
    Other = mint(?OTHER, #{windows => 2}),
    Holder = spawn(fun() -> receive stop -> ok end end),
    {ok, _} = call(Session, Holder, {mkdir, 1, <<"first">>, 8#755, 0}),
    {ok, _} = mkdir(Session, <<"second">>),
    {ok, _} = mkdir(Other, <<"x">>),
    ?assertEqual({error, eexist}, mkdir(Other, <<"x">>)),
    {ok, _} = mkdir(Other, <<"y">>),
    ?assertEqual({error, edquot}, mkdir(Other, <<"z">>)),
    %% An existing name is found before the quota, as FreeBSD's mkdir finds it.
    ?assertEqual({error, eexist}, mkdir(Other, <<"x">>)),
    First = open(Session, 2, <<"first">>, <<"wctl">>, ?O_RDWR),
    Second = open(Session, 3, <<"second">>, <<"wctl">>, ?O_RDWR),
    OtherWctl = open(Other, 2, <<"x">>, <<"wctl">>, ?O_RDWR),
    ?assertEqual(<<"visible">>, state(Session, First)),
    ?assertEqual(<<"hidden">>, state(Session, Second)),
    ?assertEqual(<<"hidden">>, state(Other, OtherWctl)),
    ?assertEqual({error, einval}, write(Session, Second, <<"unhide\n">>)),
    ?assertEqual({error, einval}, write(Other, OtherWctl, <<"unhide\n">>)),
    %% Typing reaches the shown window alone.
    FirstKbd = open(Session, 4, <<"first">>, <<"kbd">>, ?O_RDONLY),
    SecondKbd = open(Session, 5, <<"second">>, <<"kbd">>, ?O_RDONLY),
    HiddenRead = call_async(Session, {read, SecondKbd, 0, 64}),
    OtherKbd = call_async(Other, {read, open(Other, 3, <<"x">>, <<"kbd">>, ?O_RDONLY), 0, 64}),
    ok = key($a),
    ?assertEqual({ok, <<"ca", 0>>}, read(Session, FirstKbd)),
    ok = unanswered(HiddenRead),
    ok = unanswered(OtherKbd),
    {ok, _} = call(Session, {walk, 1, 6, [<<"first">>, <<"mouse">>]}),
    ?assertEqual({error, eacces}, call(Session, {lopen, 6, ?O_RDWR})),
    %% The holder's end ends the shown window; the session's next oldest is shown.
    Holder ! stop,
    ok = shown_soon(Session, Second),
    {ok, _} = mkdir(Session, <<"third">>),
    Third = open(Session, 7, <<"third">>, <<"wctl">>, ?O_RDWR),
    ?assertEqual(<<"hidden">>, state(Session, Third)),
    ok = call(Session, {unlinkat, 1, <<"second">>, ?AT_REMOVEDIR}),
    ok = shown_soon(Session, Third),
    ?assertEqual({error, eio}, read(Session, Second)),
    %% The hidden read of the removed window ends with it.
    ?assertEqual({error, eio}, answered(HiddenRead)),
    stop(World).

shown_soon(Grant, Fid) ->
    shown_soon(Grant, Fid, 50).

shown_soon(_Grant, _Fid, 0) ->
    error(never_shown);
shown_soon(Grant, Fid, Tries) ->
    case state(Grant, Fid) of
        <<"visible">> -> ok;
        _ -> timer:sleep(20), shown_soon(Grant, Fid, Tries - 1)
    end.

%% G3 ------------------------------------------------------------------------

a_driver_that_never_answers_blocks_neither_winfs_nor_the_screen_test_() ->
    {timeout, 120, fun never_answers/0}.

never_answers() ->
    World = #{screen := Screen} = start(never),
    ?assertMatch([_ | _], flushed()),
    _ = give_area(?SESSION),
    Session = mint(?SESSION, #{session => true}),
    {ok, _} = mkdir(Session, <<"w">>),
    Wctl = open(Session, 2, <<"w">>, <<"wctl">>, ?O_RDWR),
    Ctl = open(Session, 3, <<"w">>, <<"ctl">>, ?O_RDWR),
    lists:foreach(fun(_) ->
                          {error, einval} = write(Session, Wctl, <<"move -minx 1 -miny 1\n">>)
                  end, lists:seq(1, 50000)),
    lists:foreach(fun(_) ->
                          {ok, _} = mkdir(Session, <<"t">>),
                          ok = call(Session, {unlinkat, 1, <<"t">>, ?AT_REMOVEDIR})
                  end, lists:seq(1, 25000)),
    %% Both answer, the screen has taken every layout, and the frame it started with is
    %% the only one the driver has seen.
    {ok, [_]} = call(Session, {walk, 1, 4, [<<"w">>]}),
    _ = sys:get_state(Screen, ?WAIT),
    ?assertEqual({message_queue_len, 0}, process_info(Screen, message_queue_len)),
    ok = no_flush(),
    %% A present held behind the frame is answered EIO when the screen ends.
    Held = call_async(Session, {write, Ctl, 0, <<"present 0 8 4\n">>}),
    ok = unanswered(Held),
    kill(Screen),
    ?assertEqual({error, eio}, answered(Held)),
    stop(World#{screen := spawn(fun() -> ok end)}).

%% G6 ------------------------------------------------------------------------

pushes_follow_what_changed_test_() ->
    {timeout, 60, fun push_counts/0}.

push_counts() ->
    World = #{image := Screen} = start(answer),
    drain_flushes(),
    Buffer = give_area(?SESSION),
    Session = mint(?SESSION, #{session => true}),
    {ok, _} = mkdir(Session, <<"w">>),
    drain_flushes(),
    Ctl = open(Session, 2, <<"w">>, <<"ctl">>, ?O_RDWR),
    ?assertEqual({ok, <<"x8r8g8b8\n">>}, read(Session, Ctl)),
    {ok, _} = erx_memdraw:load(Buffer, {0, 0, 1, 1}, <<16#11, 16#22, 16#33, 0>>),
    ?assertMatch({ok, _, _}, write(Session, Ctl, <<"present 0 8 4 0 0 1 1\n">>)),
    ?assertEqual([{0, 0, 1, 1}], flushed()),
    ok = no_flush(),
    {ok, <<16#11, 16#22, 16#33, _, Next:3/binary, _/binary>>} =
        erx_memdraw:read(Screen, {0, 0, 2, 1}),
    <<R, G, B, _>> = <<(erx_screen:background()):32>>,
    ?assertEqual(<<B, G, R>>, Next),
    %% A window that is made hidden, and its present, show nothing new.
    _ = give_area(?OTHER),
    Other = mint(?OTHER, #{}),
    {ok, _} = mkdir(Other, <<"x">>),
    OtherCtl = open(Other, 2, <<"x">>, <<"ctl">>, ?O_RDWR),
    ?assertMatch({ok, _, _}, write(Other, OtherCtl, <<"present 0 8 4\n">>)),
    ok = no_flush(),
    %% A present past the area's end, or at an offset that is not whole pages, is
    %% refused and shows nothing.
    ?assertEqual({error, einval}, write(Session, Ctl, <<"present 16384 8 4\n">>)),
    ?assertEqual({error, einval}, write(Session, Ctl, <<"present 4 8 4\n">>)),
    ?assertEqual({error, einval}, write(Session, Ctl, <<"present 0 16384 16384\n">>)),
    ok = no_flush(),
    stop(World).

%% A grant without a pixel area is refused ENXIO, and a malformed line EINVAL.
presents_without_an_area_are_refused_test() ->
    World = start(answer),
    Grant = mint(?OTHER, #{}),
    {ok, _} = mkdir(Grant, <<"w">>),
    Ctl = open(Grant, 2, <<"w">>, <<"ctl">>, ?O_RDWR),
    ?assertEqual({error, enxio}, write(Grant, Ctl, <<"present 0 8 4\n">>)),
    ?assertEqual({error, einval}, write(Grant, Ctl, <<"present\n">>)),
    Label = open(Grant, 3, <<"w">>, <<"label">>, ?O_RDWR),
    ?assertMatch({ok, _, _}, write(Grant, Label, <<"term">>)),
    ?assertEqual({ok, <<"term">>}, read(Grant, Label)),
    ?assertEqual({error, einval}, call(Grant, {write, Label, 1, <<"x">>})),
    stop(World).

%% The mint grants requests of the display's service alone: one carrying the configured
%% name is granted, and one of another service, the windows interface's name among them,
%% is unknown.
mints_are_of_the_configured_service_test() ->
    Mint = fun(Service) -> {erx_origin, ?SYSTEM, {erx_facet_mint, 7, Service, ?SESSION, root, #{}}} end,
    ?assertEqual({grant, 7, ?SESSION, #{}}, erx_winfs:mint_request(?SYSTEM, ?SERVICE, Mint(?SERVICE))),
    ?assertEqual(unknown, erx_winfs:mint_request(?SYSTEM, ?SERVICE, Mint(windows))),
    ?assertEqual(unknown, erx_winfs:mint_request(?SYSTEM, ?SERVICE, Mint(display))).

%% A mint of another service reaches the running window system and is dropped: no grant
%% is minted for it, and the next mint of the configured service is.
a_running_window_system_drops_another_service_s_mint_test() ->
    World = start(answer),
    erx_winfs ! {erx_origin, ?SYSTEM, {erx_facet_mint, 1, windows, ?SESSION, root, #{}}},
    _ = mint(?SESSION, #{}),
    receive {minted, 1, Reply} -> error({minted_another_service, Reply}) after 0 -> ok end,
    stop(World).

%% erx_fb_sup starts the window system for the service the display variable names, and
%% none, refusing, when the variable is unset, empty or longer than a service name.
the_display_variable_names_the_window_system_s_service_test() ->
    ?assertMatch([#{id := erx_winfs, start := {erx_winfs, start_link, [screen]}}], erx_fb_sup:winfs("screen")),
    ?assertEqual([], erx_fb_sup:winfs(false)),
    ?assertEqual([], erx_fb_sup:winfs("")),
    ?assertEqual([], erx_fb_sup:winfs(lists:duplicate(64, $a))).

%% Started as the display domain's, the window system names itself the mint of the
%% configured service, the name every mint request of it carries.
the_window_system_provides_the_configured_service_test() ->
    _ = [kill(Pid) || Pid <- [whereis(erx_winfs)], is_pid(Pid)],
    _ = persistent_term:erase({erx, provides}),
    {ok, Winfs} = erx_winfs:start_link(#{service => ?SERVICE, system => ?SYSTEM, exports => ?MODULE,
                                         minted => fun(_Tag, _Reply) -> ok end, area => fun area_of/1,
                                         clients => own, provide => true, policy => {erx_wm_single, #{}}}),
    true = unlink(Winfs),
    ?assertEqual(#{?SERVICE => Winfs}, persistent_term:get({erx, provides})),
    kill(Winfs),
    _ = persistent_term:erase({erx, provides}),
    ok.
