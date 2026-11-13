%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_win against the window system on stock OTP (test/host/erx_win_test.rb): erx_winfs
%% under the single policy, its grants started as erx_fs grants of this domain, erx_window
%% and erx_screen over a driver model, with erx_memdraw's NIF built for the host and its
%% stand-in pixel area. The client is erx_win with erx_pixels, over stand-ins of erx's
%% registry (erx:cap/1 and erx:owner/1) and of erx_area that the Ruby test writes:
%% erx:cap(screen) answers the grant this test minted and erx:owner/1 the grantee, and
%% erx_area:open/1 the same stand-in area the display reads.
%%
%% Cases: a window opens with a buffer of the screen's size, draws and presents a pixel
%% the screen shows; a change of the screen's size answers an r record, after which
%% resized/1 answers an image at the new size over the same buffer and allocates nothing;
%% kbd reads a typed rune and label takes a write; the single policy refuses resize/2; an area with no room for
%% a second buffer answers enomem and leaves no window behind; no grant answers none.

-module(erx_win_tests).
-include_lib("eunit/include/eunit.hrl").

-export([info/1, export/3]).

-define(XRGB32, 16#68081828).
-define(WIDTH, 8).
-define(HEIGHT, 4).
-define(DRIVER, erx_win_test_driver).
-define(SYSTEM, 1).
-define(SERVICE, screen).
-define(SESSION, 10).
-define(PAGE, 4096).
-define(AREA, 16384).
-define(NOFID, 16#ffffffff).
-define(WAIT, 5000).

-doc false.
info(Driver) ->
    gen_server:call(Driver, info).

-doc false.
export(_Grant, _Rights, _Peer) ->
    ok.

%% Fixtures ------------------------------------------------------------------

driver() ->
    Test = self(),
    {ok, Screen} = erx_memdraw:alloc(?XRGB32, {0, 0, ?WIDTH, ?HEIGHT}, {0, 0, ?WIDTH, ?HEIGHT},
                                     false, 16#000000ff),
    Info = #{width => ?WIDTH, height => ?HEIGHT, chan => <<"x8r8g8b8">>, screen => Screen,
             partial => true, direct => false},
    Pid = spawn(fun() -> serve(Test, Info) end),
    true = register(?DRIVER, Pid),
    {Pid, Screen}.

serve(Test, Info) ->
    receive
        {'$gen_call', From, info} ->
            gen_server:reply(From, Info);
        {'$gen_call', From, {flush, Rects, _Image}} ->
            Test ! {flushed, Rects},
            gen_server:reply(From, ok)
    end,
    serve(Test, Info).

%% The window system and screen over the driver model, a grant minted for ?SESSION over a
%% stand-in area, installed where the stand-in erx:cap/1 finds it, and the client's
%% allocator. The area is one page of the host's, 16 KiB on Apple's, which the stand-in
%% maps whole: four of erXos's pages.
start() ->
    _ = [kill(Pid) || Name <- [erx_screen, erx_winfs, erx_pixels, ?DRIVER], Pid <- [whereis(Name)],
                      is_pid(Pid)],
    Test = self(),
    {Driver, Image} = driver(),
    {ok, Area, _} = erx_memdraw:test_area(?AREA, write),
    persistent_term:put({erx_area_stand_in, ?SESSION}, {ok, Area, ?AREA}),
    {ok, Winfs} = erx_winfs:start_link(#{service => ?SERVICE, system => ?SYSTEM, exports => ?MODULE,
                                         minted => fun(Tag, Reply) -> Test ! {minted, Tag, Reply} end,
                                         area => fun erx_area:open/1, clients => own, provide => false,
                                         policy => {erx_wm_single, #{}}}),
    {ok, Screen} = erx_screen:start_link({?MODULE, ?DRIVER}),
    {ok, Pixels} = gen_server:start({local, erx_pixels}, erx_pixels, [], []),
    [true = unlink(P) || P <- [Winfs, Screen]],
    Tag = erlang:unique_integer([positive]),
    erx_winfs ! {erx_origin, ?SYSTEM, {erx_facet_mint, Tag, ?SERVICE, ?SESSION, root, #{session => true}}},
    Grant = receive {minted, Tag, {ok, G}} -> G after ?WAIT -> error(no_mint) end,
    persistent_term:put({erx_stand_in, cap, ?SERVICE}, Grant),
    persistent_term:put({erx_stand_in, owner, Grant}, ?SESSION),
    #{image => Image, grant => Grant, procs => [Pixels, Screen, Winfs, Driver]}.

stop(#{procs := Procs}) ->
    _ = [kill(P) || P <- Procs],
    _ = [persistent_term:erase(K) || {K, _} <- persistent_term:get(),
                                     is_tuple(K), element(1, K) =:= erx_stand_in
                                         orelse element(1, K) =:= erx_area_stand_in],
    ok.

kill(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok end.

with(Case) ->
    Fixture = start(),
    try Case(Fixture) after stop(Fixture) end.

flushed() ->
    receive {flushed, Rects} -> Rects after ?WAIT -> error(no_flush) end.

%% Cases ---------------------------------------------------------------------

open_draw_present_test() ->
    with(fun(#{image := Screen}) ->
        {ok, Window} = erx_win:open(?SERVICE, #{name => <<"main">>}),
        {ok, Image} = erx_win:image(Window),
        {ok, _} = erx_memdraw:load(Image, {2, 1, 3, 2}, <<16#11, 16#22, 16#33, 0>>),
        ok = erx_win:present(Window, [{2, 1, 3, 2}]),
        _ = flushed(),
        {ok, Pixel} = erx_memdraw:read(Screen, {2, 1, 3, 2}),
        ?assertEqual(<<16#11, 16#22, 16#33>>, binary:part(Pixel, 0, 3)),
        ?assertEqual({error, eexist}, erx_win:open(?SERVICE, #{name => <<"main">>}))
    end).

resized_test() ->
    with(fun(_) ->
        {ok, Window} = erx_win:open(?SERVICE, #{}),
        {ok, Before} = erx_pixels:alloc(?SESSION, 1),
        %% The screen shrinks: the window's size changes and its next mouse read is r.
        _ = erx_winfs:attach({0, 0, 6, 3}, <<"x8r8g8b8">>),
        ?assertMatch({ok, {resized, _, _, _, _}}, erx_win:mouse(Window)),
        {ok, Resized, Image} = erx_win:resized(Window),
        ?assertEqual({ok, <<0:(6 * 32)>>}, erx_memdraw:read(Image, {0, 0, 6, 1})),
        ?assertEqual({error, einval}, erx_memdraw:read(Image, {0, 0, 7, 1})),
        ?assertEqual({0, 0, 6, 3}, maps:get(rect, Resized)),
        %% Nothing was allocated between the two probes but the probes themselves.
        {ok, After} = erx_pixels:alloc(?SESSION, 1),
        ?assertEqual(Before + ?PAGE, After)
    end).

kbd_label_resize_test() ->
    with(fun(_) ->
        {ok, Window} = erx_win:open(?SERVICE, #{}),
        erx_winfs:input(#{device => <<"kbd">>, at => 0, event => {key, down, 30, $a}}),
        ?assertEqual({ok, {typed, $a}}, erx_win:kbd(Window)),
        ok = erx_win:label(Window, <<"a label">>),
        ?assertEqual({error, einval}, erx_win:resize(Window, {0, 0, 4, 4}))
    end).

no_room_test() ->
    with(fun(#{grant := Grant}) ->
        {ok, _} = erx_win:open(?SERVICE, #{name => <<"first">>}),
        %% Each buffer of the 8 by 4 screen is one page: the last three go to probes.
        [{ok, _} = erx_pixels:alloc(?SESSION, 1) || _ <- [1, 2, 3]],
        ?assertEqual({error, enomem}, erx_win:open(?SERVICE, #{name => <<"second">>})),
        %% The refused window was removed: its name is free and no walk reaches it.
        Root = 900,
        {ok, _} = call(Grant, {attach, Root, ?NOFID, <<>>, <<"windows">>, 0}),
        ?assertMatch({ok, [_]}, call(Grant, {walk, Root, Root + 1, [<<"first">>]})),
        ?assertMatch({error, _}, call(Grant, {walk, Root, Root + 2, [<<"second">>]}))
    end).

no_grant_test() ->
    ?assertEqual({error, none}, erx_win:open(no_such_display, #{})).

call(Grant, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), Request},
    receive {erx_9p, Alias, Reply} -> Reply after ?WAIT -> error({no_reply, Request}) end.
