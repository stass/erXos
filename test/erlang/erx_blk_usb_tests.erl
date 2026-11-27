%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of a USB medium's block service (erx_blk_usb): the transport and its one
%% window of role drive over the whole medium, against a stand-in BOT function that answers
%% each request and reports it to the test. The window hands the function only requests
%% inside the medium, each under the medium's reference; the drive grant learns of the
%% window, and its end of the medium reaches the function under that reference; the window
%% ends with its transport. test/host/erx_blk_test.rb runs them on stock's emulator.

-module(erx_blk_usb_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SECTOR, 512).
-define(CAPACITY, 100).
-define(LUN, 0).

%% A stand-in function: it answers every request with success and tells Test what it ran,
%% and forwards a drive grant's end of a medium.
function(Test) ->
    receive
        {'$gen_call', From, {request, Ref, Request}} ->
            Test ! {ran, Ref, Request},
            gen_server:reply(From, answer(Request)),
            function(Test);
        End = {erx_blk_drive, end_medium, _Medium} ->
            Test ! End,
            function(Test)
    end.

answer({read, _Lun, _Sector, Count}) -> {ok, <<0:(Count * ?SECTOR)/unit:8>>};
answer({write, _Lun, _Sector, _Data}) -> ok;
answer({flush, _Lun}) -> ok.

%% A transport started as the function starts it, for a medium of reference Ref.
transport(Function, Ref, Drive) ->
    {ok, {Transport, _Monitor}} =
        erx_blk_usb:start_monitor(#{function => Function, lun => ?LUN, ref => Ref, capacity => ?CAPACITY,
                                    flush => true, detail => #{}, drive => Drive}),
    Transport.

the_medium_s_window_reaches_the_function_under_its_reference_test() ->
    Test = self(),
    Function = spawn_link(fun() -> function(Test) end),
    {ok, Grant} = erx_blk_drive:start_link(),
    Ref = make_ref(),
    Transport = transport(Function, Ref, Grant),
    {ok, Window} = granted(Grant),
    ?assertEqual({ok, #{role => drive, sectors => ?CAPACITY, max_sectors => 64}}, erx_blk_window:info(Window)),
    ?assertEqual({ok, <<0:(2 * ?SECTOR)/unit:8>>}, erx_blk_window:read(Window, ?CAPACITY - 2, 2)),
    receive {ran, Ran, Request} -> ?assertEqual({Ref, {read, ?LUN, ?CAPACITY - 2, 2}}, {Ran, Request})
    after 5000 -> ?assert(false)
    end,
    %% Past the medium: refused at the window, and nothing reaches the function.
    ?assertEqual({error, erange}, erx_blk_window:read(Window, ?CAPACITY - 1, 2)),
    ?assertEqual({error, erange}, erx_blk_window:write(Window, ?CAPACITY, <<0:?SECTOR/unit:8>>)),
    receive {ran, _, _} -> ?assert(false) after 0 -> ok end,
    %% Asked again, the grant ends the medium through the function, under its reference.
    Ask = gen_server:send_request(Grant, window),
    receive {erx_blk_drive, end_medium, Medium} -> ?assertEqual({?LUN, Ref}, Medium)
    after 5000 -> ?assert(false)
    end,
    %% The function stops the transport; its window ends with it, and only then is the
    %% held ask answered, with no medium until the next one is ready.
    Watch = monitor(process, Window),
    exit(Transport, shutdown),
    receive {'DOWN', Watch, process, Window, _} -> ok after 5000 -> ?assert(false) end,
    ?assertEqual({reply, {error, no_medium}}, gen_server:receive_response(Ask, 5000)),
    ?assertEqual({error, eio}, erx_blk_window:read(Window, 0, 1)),
    unlink(Grant),
    exit(Grant, kill),
    unlink(Function),
    exit(Function, kill).

%% The transport checks a request by erx_blk_request:range/4 alone: given a capacity that
%% is not an integer, which the function never builds, every request is refused
%% out_of_range and nothing reaches the function.
a_medium_without_a_capacity_takes_no_request_test() ->
    Test = self(),
    Function = spawn_link(fun() -> function(Test) end),
    {ok, {Transport, _Monitor}} =
        erx_blk_usb:start_monitor(#{function => Function, lun => ?LUN, ref => make_ref(), capacity => undefined,
                                    flush => true, detail => #{}, drive => none}),
    ?assertEqual({error, out_of_range}, gen_server:call(Transport, {read, 0, 1})),
    ?assertEqual({error, out_of_range}, gen_server:call(Transport, {write, 0, <<0:?SECTOR/unit:8>>})),
    receive {ran, _, _} -> ?assert(false) after 0 -> ok end,
    exit(Transport, shutdown),
    unlink(Function),
    exit(Function, kill).

%% A medium that cannot flush: the transport answers no_flush, and the window answers
%% enotsup, which a mount takes as a medium without a cache to flush; never eio.
a_medium_that_cannot_flush_answers_enotsup_at_its_window_test() ->
    Test = self(),
    Function = spawn_link(fun() -> no_flush_function(Test) end),
    {ok, Grant} = erx_blk_drive:start_link(),
    Transport = transport(Function, make_ref(), Grant),
    {ok, Window} = granted(Grant),
    ?assertEqual({error, enotsup}, erx_blk_window:flush(Window)),
    exit(Transport, shutdown),
    unlink(Grant),
    exit(Grant, kill),
    unlink(Function),
    exit(Function, kill).

no_flush_function(Test) ->
    receive
        {'$gen_call', From, {request, _Ref, {flush, _Lun}}} ->
            gen_server:reply(From, {error, no_flush}),
            no_flush_function(Test)
    end.

%% The grant's window once the transport's serve has reached it: serve is a cast, so the
%% ask is repeated until the grant has seen it.
granted(Grant) -> granted(Grant, 100).

granted(Grant, Tries) ->
    case erx_blk_drive:window(Grant) of
        {ok, Window} -> {ok, Window};
        {error, no_medium} when Tries > 0 -> timer:sleep(10), granted(Grant, Tries - 1)
    end.
