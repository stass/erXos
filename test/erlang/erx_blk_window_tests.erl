%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of a block window's tie to the device process it reached first
%% (erx_blk_window): once that process has ended, every request the window takes answers
%% eio, even when a new device process runs under the name erx_blk, since a reset by any
%% route may have dropped what the old process answered ok. A window opened after the
%% restart reaches the new process. The device process here is a stand-in registered as
%% erx_blk. test/host/erx_blk_test.rb runs them on stock's emulator.

-module(erx_blk_window_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SECTOR, 512).

%% Each case starts with no process named erx_blk, and ends whatever stand-in it left.
window_test_() ->
    {foreach, fun() -> ok end, fun(ok) -> end_registered() end,
     [fun a_window_whose_device_ended_answers_eio/0,
      fun a_window_opened_after_a_restart_reaches_the_new_device/0,
      fun a_window_binds_on_its_first_reach/0]}.

end_registered() ->
    case whereis(erx_blk) of
        undefined -> ok;
        Device -> stop_device(Device)
    end.

%% A device process stand-in under the name erx_blk: it answers each call of the contract
%% (erx_blk) with success.
start_device() ->
    Device = spawn(fun device/0),
    true = register(erx_blk, Device),
    Device.

device() ->
    receive
        {'$gen_call', From, Request} ->
            gen_server:reply(From, answer(Request)),
            device()
    end.

answer({read, _Sector, Count}) -> {ok, <<0:(Count * ?SECTOR)/unit:8>>};
answer({write, _Sector, _Bytes}) -> ok;
answer(flush) -> ok;
answer(info) -> {ok, #{transport => virtio_mmio, capacity => 64, max_sectors => 8, detail => #{}}}.

%% Ends Device and waits until it has ended, so erx_blk names no process.
stop_device(Device) ->
    Monitor = monitor(process, Device),
    exit(Device, kill),
    receive {'DOWN', Monitor, process, Device, _} -> ok end.

window() ->
    {ok, Window} = erx_blk_window:start_link({data, 8, 16}),
    Window.

%% A write answered ok before the device process was replaced, then a flush after: the
%% flush cannot vouch for that write, so it is eio, and so is every later request.
a_window_whose_device_ended_answers_eio() ->
    First = start_device(),
    Window = window(),
    ?assertEqual(ok, erx_blk_window:write(Window, 0, <<1:(?SECTOR)/unit:8>>)),
    stop_device(First),
    Second = start_device(),
    ?assertEqual({error, eio}, erx_blk_window:flush(Window)),
    ?assertEqual({error, eio}, erx_blk_window:write(Window, 0, <<1:(?SECTOR)/unit:8>>)),
    ?assertEqual({error, eio}, erx_blk_window:read(Window, 0, 1)),
    ?assertEqual({ok, #{role => data, sectors => 16}}, erx_blk_window:info(Window)),
    unlink(Window),
    exit(Window, kill),
    stop_device(Second).

%% A window opened after the restart binds to the new device process.
a_window_opened_after_a_restart_reaches_the_new_device() ->
    stop_device(start_device()),
    Second = start_device(),
    Window = window(),
    ?assertEqual(ok, erx_blk_window:write(Window, 0, <<1:(?SECTOR)/unit:8>>)),
    ?assertEqual(ok, erx_blk_window:flush(Window)),
    ?assertEqual({ok, <<0:(?SECTOR)/unit:8>>}, erx_blk_window:read(Window, 0, 1)),
    unlink(Window),
    exit(Window, kill),
    stop_device(Second).

%% A window that has reached no device yet binds to the first one it finds: with none
%% running a request is eio and binds nothing, and the device started next serves it.
a_window_binds_on_its_first_reach() ->
    Window = window(),
    ?assertEqual({error, eio}, erx_blk_window:read(Window, 0, 1)),
    Device = start_device(),
    ?assertEqual(ok, erx_blk_window:flush(Window)),
    unlink(Window),
    exit(Window, kill),
    stop_device(Device).
