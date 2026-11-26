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
%% kbd reads a typed rune and label takes a write; a kbd read too short for the head
%% record fails with einval and leaves it for the next read; the single policy refuses
%% resize/2; an area with no room for a second buffer answers enomem and leaves no
%% window behind; no grant answers none, as does a grant with no allocator running, which
%% leaves no window behind.
%% A window opened with buffer => none over a full area allocates nothing, answers its
%% peer, rectangle and channel, refuses image/1, lease/2 and present/2, and presents a
%% range of the area it does not own through present/3, at the range's own size after
%% the screen shrinks past it; a present/3 in the area's last page is shown up to the
%% area's last byte and refused a word past it.
%%
%% with/1 and flushed/0 are also the fixture of test/erlang/erx_draw_tests.erl, which
%% opens draw connections under the erx_win_sup this fixture starts.

-module(erx_win_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([info/1, export/3, with/1, flushed/0]).

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
%% supervisor with its allocator. The area is one page of the host's, 16 KiB on Apple's,
%% which the stand-in maps whole: four of erXos's pages. The grant holds two windows, so a second window
%% is refused by the area, not by the windows quota.
start() ->
    _ = [kill(Pid) || Name <- [erx_screen, erx_winfs, erx_win_sup, erx_pixels, ?DRIVER], Pid <- [whereis(Name)],
                      is_pid(Pid)],
    Test = self(),
    {Driver, Image} = driver(),
    {ok, Area, _} = erx_memdraw:test_area(?AREA, write),
    persistent_term:put({erx_area_stand_in, ?SESSION}, {ok, Area, ?AREA}),
    {ok, Winfs} = erx_winfs:start_link(#{service => ?SERVICE, system => ?SYSTEM, exports => ?MODULE,
                                         minted => fun(Tag, Reply) -> Test ! {minted, Tag, Reply} end,
                                         area => fun erx_area:open/1, clients => own, provide => false,
                                         policy => {erx_wm_single, #{}}, palette => dark}),
    {ok, Screen} = erx_screen:start_link({?MODULE, ?DRIVER}, light),
    {ok, Client} = erx_win_sup:start_link(),
    [true = unlink(P) || P <- [Winfs, Screen, Client]],
    Tag = erlang:unique_integer([positive]),
    erx_winfs ! {erx_origin, ?SYSTEM,
                 {erx_facet_mint, Tag, ?SERVICE, ?SESSION, root, #{session => true, windows => 2}}},
    Grant = receive {minted, Tag, {ok, G, _Tree}} -> G after ?WAIT -> error(no_mint) end,
    persistent_term:put({erx_stand_in, cap, ?SERVICE}, Grant),
    persistent_term:put({erx_stand_in, owner, Grant}, ?SESSION),
    #{image => Image, grant => Grant, procs => [Client, Screen, Winfs, Driver]}.

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

-doc false.
with(Case) ->
    Fixture = start(),
    try Case(Fixture) after stop(Fixture) end.

-doc false.
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
    with(fun(#{image := Screen}) ->
        {ok, Window} = erx_win:open(?SERVICE, #{}),
        {ok, Before} = erx_pixels:alloc(?SESSION, 1),
        %% The screen shrinks: the window's size changes and its next mouse read is r.
        _ = erx_winfs:attach({0, 0, 6, 3}, <<"x8r8g8b8">>),
        ?assertMatch({ok, {resized, _, _, _, _}}, erx_win:mouse(Window)),
        {ok, Resized, Image} = erx_win:resized(Window),
        ?assertEqual({ok, <<0:(6 * 32)>>}, erx_memdraw:read(Image, {0, 0, 6, 1})),
        ?assertEqual({error, einval}, erx_memdraw:read(Image, {0, 0, 7, 1})),
        ?assertEqual({0, 0, 6, 3}, maps:get(rect, Resized)),
        %% present/2 sends the buffer at the window's size, the stride the image is drawn at.
        {ok, _} = erx_memdraw:load(Image, {5, 2, 6, 3}, <<16#77, 16#88, 16#99, 0>>),
        ok = erx_win:present(Resized, [{5, 2, 6, 3}]),
        _ = flushed(),
        {ok, Pixel} = erx_memdraw:read(Screen, {5, 2, 6, 3}),
        ?assertEqual(<<16#77, 16#88, 16#99>>, binary:part(Pixel, 0, 3)),
        %% Nothing was allocated between the two probes but the probes themselves.
        {ok, After} = erx_pixels:alloc(?SESSION, 1),
        ?assertEqual(Before + ?PAGE, After)
    end).

kbd_label_resize_test() ->
    with(fun(_) ->
        {ok, Window} = erx_win:open(?SERVICE, #{}),
        %% Keys reach the window once its frame is on the screen.
        ok = erx_win:present(Window, []),
        %% A keyboard driver's record of KEY_A going down, evdev code 30.
        ok = erx_winfs:input(<<"kbd">>, {key, down, 30}),
        ?assertEqual({ok, {down, "a"}}, erx_win:kbd(Window)),
        ?assertEqual({ok, {typed, $a}}, erx_win:kbd(Window)),
        ok = erx_win:label(Window, <<"a label">>),
        ?assertEqual({error, einval}, erx_win:resize(Window, {0, 0, 4, 4}))
    end).

%% A kbd read whose count cannot hold the record at the head of the queue fails with
%% EINVAL and leaves it there (docs/design-display.md, "The window tree"): with Ctrl and
%% Shift held, KEY_A's down is a 9-byte k record, which a 6-byte read refuses and a
%% 64-byte read then takes.
a_short_kbd_read_leaves_its_record_test() ->
    with(fun(_) ->
        {ok, Window} = erx_win:open(?SERVICE, #{}),
        ok = erx_win:present(Window, []),
        ok = erx_winfs:input(<<"kbd">>, {key, down, ?ERX_EVDEV_KEY_LEFTCTRL}),
        ok = erx_winfs:input(<<"kbd">>, {key, down, ?ERX_EVDEV_KEY_LEFTSHIFT}),
        held_runes(Window, 2),
        ok = erx_winfs:input(<<"kbd">>, {key, down, ?ERX_EVDEV_KEY_A}),
        ?assertEqual({error, einval}, erx_win:read_at(Window, kbd, 0, 6)),
        {ok, Record} = erx_win:read_at(Window, kbd, 0, 64),
        ?assertEqual(9, byte_size(Record)),
        {ok, {down, Runes}} = erx_win_core:kbd(Record),
        ?assert(lists:member($a, Runes))
    end).

%% Reads the window's kbd until a k record holds Count runes.
held_runes(Window, Count) ->
    {ok, Record} = erx_win:read_at(Window, kbd, 0, 64),
    case erx_win_core:kbd(Record) of
        {ok, {down, Runes}} when length(Runes) =:= Count -> ok;
        _ -> held_runes(Window, Count)
    end.

%% A program's /dev tree relays kbd, mouse, wctl and label on the handle's
%% fids (docs/design-files.md, "A program's window"): a label written at an
%% offset reads back, a kbd record reads raw, and ctl has no clause.
relay_test() ->
    with(fun(_) ->
        {ok, Window} = erx_win:open(?SERVICE, #{}),
        ?assertMatch({ok, 7, _}, erx_win:write_at(Window, label, 0, <<"a label">>)),
        ?assertEqual({ok, <<"label">>}, erx_win:read_at(Window, label, 2, 64)),
        ok = erx_win:present(Window, []),
        ok = erx_winfs:input(<<"kbd">>, {key, down, 30}),
        ?assertMatch({ok, <<"k", _/binary>>}, erx_win:read_at(Window, kbd, 0, 64)),
        ?assertError(function_clause, erx_win:read_at(Window, ctl, 0, 144)),
        ?assertError(function_clause, erx_win:write_at(Window, ctl, 0, <<"present">>))
    end).

%% A draw connection keeps a program's kbd read while it serves others
%% (docs/design-display.md, "Erlang clients"): send_read/4 answers at once, the
%% display's reply arrives as a message reply/2 takes for its id, and a flush of
%% the answered read is answered ok for its own id. ctl has no clause.
send_read_test() ->
    with(fun(_) ->
        {ok, Window} = erx_win:open(?SERVICE, #{}),
        ok = erx_win:present(Window, []),
        ok = erx_winfs:input(<<"kbd">>, {key, down, 30}),
        {ok, Read} = erx_win:send_read(Window, kbd, 0, 64),
        ?assertMatch({ok, <<"k", _/binary>>}, answer(Read)),
        {ok, Flush} = erx_win:send_flush(Window, Read),
        ?assertEqual(ok, answer(Flush)),
        ?assertError(function_clause, erx_win:send_read(Window, ctl, 0, 144)),
        ?assertError(function_clause, erx_win:send_read(Window, wctl, 0, 64))
    end).

%% The answer to Id among the messages that arrive, as a keeper's loop takes it,
%% passing the others by.
answer(Id) ->
    receive
        Message ->
            case erx_win:reply(Message, Id) of
                {reply, Answer} -> Answer;
                no_reply -> answer(Id)
            end
    after ?WAIT -> error(no_reply)
    end.

no_room_test() ->
    with(fun(#{grant := Grant}) ->
        {ok, _} = erx_win:open(?SERVICE, #{name => <<"first">>}),
        %% Each buffer of the 8 by 4 screen is one page: the last three go to probes.
        [{ok, _} = erx_pixels:alloc(?SESSION, 1) || _ <- [1, 2, 3]],
        ?assertEqual({error, enomem}, erx_win:open(?SERVICE, #{name => <<"second">>})),
        %% The refused window was removed: its name is free and no walk reaches it. The
        %% fids come from erx_win's own source in this test, so none is one it holds.
        [Root, First, Second] = [erlang:unique_integer([positive]) || _ <- [1, 2, 3]],
        {ok, _} = call(Grant, {attach, Root, ?NOFID, <<>>, <<"windows">>, 0}),
        ?assertMatch({ok, [_]}, call(Grant, {walk, Root, First, [<<"first">>]})),
        ?assertMatch({error, _}, call(Grant, {walk, Root, Second, [<<"second">>]}))
    end).

no_grant_test() ->
    ?assertEqual({error, none}, erx_win:open(no_such_display, #{})).

%% A domain that holds the grant and erx_win's code but runs no allocator has no pixel
%% area for a buffer: the open answers none and leaves no window behind.
no_allocator_test() ->
    with(fun(#{grant := Grant}) ->
        Pixels = whereis(erx_pixels),
        kill(Pixels),
        ?assertEqual({error, none}, erx_win:open(?SERVICE, #{name => <<"first">>})),
        Root = erlang:unique_integer([positive]),
        Dir = erlang:unique_integer([positive]),
        {ok, _} = call(Grant, {attach, Root, ?NOFID, <<>>, <<"windows">>, 0}),
        ?assertMatch({error, _}, call(Grant, {walk, Root, Dir, [<<"first">>]}))
    end).

%% A range allocated by someone else, as a program's handler lends one, and the area
%% filled behind it: an open that allocated anything would answer enomem.
lent_range() ->
    {ok, Range} = erx_pixels:alloc(?SESSION, ?PAGE),
    [{ok, _} = erx_pixels:alloc(?SESSION, 1) || _ <- [1, 2, 3]],
    ?assertEqual({error, enomem}, erx_pixels:alloc(?SESSION, 1)),
    Range.

lent_range_test() ->
    with(fun(#{image := Screen}) ->
        Range = lent_range(),
        {ok, Window} = erx_win:open(?SERVICE, #{buffer => none}),
        %% The window's ctl names the display's channel, the scale 1/1 and the palette
        %% the window system was started with.
        #{peer := ?SESSION, rect := {0, 0, ?WIDTH, ?HEIGHT}, chan := #{text := <<"x8r8g8b8">>,
                                                                     code := Code},
          scale := {1, 1}, palette := dark} =
            erx_win:info(Window),
        ?assertEqual({error, none}, erx_win:image(Window)),
        ?assertEqual({error, none}, erx_win:lease(Window, self())),
        ?assertEqual({error, none}, erx_win:present(Window, [])),
        {ok, Area, _} = erx_area:open(?SESSION),
        {ok, Image} = erx_memdraw:wrap(Area, Range, {0, 0, ?WIDTH, ?HEIGHT}, Code),
        {ok, _} = erx_memdraw:load(Image, {5, 2, 6, 3}, <<16#44, 16#55, 16#66, 0>>),
        Buffer = #{offset => Range, width => ?WIDTH, height => ?HEIGHT},
        ok = erx_win:present(Window, Buffer, [{5, 2, 6, 3}]),
        _ = flushed(),
        {ok, Pixel} = erx_memdraw:read(Screen, {5, 2, 6, 3}),
        ?assertEqual(<<16#44, 16#55, 16#66>>, binary:part(Pixel, 0, 3))
    end).

lent_range_resized_test() ->
    with(fun(_) ->
        Range = lent_range(),
        {ok, Window} = erx_win:open(?SERVICE, #{buffer => none}),
        _ = erx_winfs:attach({0, 0, 6, 3}, <<"x8r8g8b8">>),
        ?assertMatch({ok, {resized, _, _, _, _}}, erx_win:mouse(Window)),
        {ok, Resized, none} = erx_win:resized(Window),
        ?assertMatch(#{rect := {0, 0, 6, 3}}, erx_win:info(Resized)),
        %% The range keeps the size it was drawn at; the display clips it to the window.
        ?assertEqual(ok, erx_win:present(Resized, #{offset => Range, width => ?WIDTH,
                                                     height => ?HEIGHT}, []))
    end).

present_area_end_test() ->
    with(fun(_) ->
        {ok, Window} = erx_win:open(?SERVICE, #{buffer => none}),
        Last = ?AREA - ?PAGE,
        Present = fun(Offset, Width, Height) ->
                      erx_win:present(Window, #{offset => Offset, width => Width, height => Height}, [])
                  end,
        %% A buffer's bytes are its rows and the word past them (erx_chan:bytes/3). In the
        %% area's last page: 127 rows of 32 bytes and the word fit with room to spare; one
        %% row of 1,023 pixels and the word end at the area's last byte; one of 1,024
        %% pixels passes it by a word, as does a buffer at the area's end.
        ?assertEqual(ok, Present(Last, ?WIDTH, 127)),
        ?assertEqual(ok, Present(Last, 1023, 1)),
        ?assertEqual({error, einval}, Present(Last, 1024, 1)),
        ?assertEqual({error, einval}, Present(?AREA, ?WIDTH, 1))
    end).

call(Grant, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), Request},
    receive {erx_9p, Alias, Reply} -> Reply after ?WAIT -> error({no_reply, Request}) end.
