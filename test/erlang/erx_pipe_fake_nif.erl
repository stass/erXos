%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pipe_fake_nif).
-moduledoc """
A stand-in for erx_pipe_nif in erx_pipe_srv's tests: every call is sent
to the test process as `{nif, Call}` and answered from what the test
set. Objects are `{obj, Kind, N}` and ends `{fake_end, Pid, Desc}`. The
test process and the calls that fail are kept in persistent_term.
""".

-export([setup/1, fail/1, make_lock/0, make_lane/1, make_bell/3, store_wends/2,
         free_lock/2, close/1, open_end/3, apply/2]).

-doc "Sends every later call to Pid, and fails none.".
setup(Pid) ->
    persistent_term:put(?MODULE, #{test => Pid, fail => []}).

-doc "Makes the calls named in Calls fail with enomem.".
fail(Calls) ->
    persistent_term:put(?MODULE, (persistent_term:get(?MODULE))#{fail => Calls}).

make_lock() ->
    answer(make_lock, {make_lock}, fun() -> {ok, obj(lock)} end).

make_lane(Size) ->
    answer(make_lane, {make_lane, Size}, fun() -> {ok, obj(ring), obj(rpage)} end).

make_bell(Pid, Pipe, End) ->
    answer(make_bell, {make_bell, Pid, Pipe, End}, fun() -> {ok, obj(bell)} end).

store_wends(Lock, Wends) ->
    answer(store_wends, {store_wends, Lock, Wends}, fun() -> ok end).

free_lock(Lock, Rix) ->
    answer(free_lock, {free_lock, Lock, Rix}, fun() -> ok end).

close(Obj) ->
    answer(close, {close, Obj}, fun() -> ok end).

open_end(Pid, _Server, Desc) ->
    answer(open_end, {open_end, Pid, Desc}, fun() -> {ok, {fake_end, Pid, Desc}} end).

apply(End, Report) ->
    answer(apply, {apply, End, Report}, fun() -> ok end).

answer(Name, Call, Ok) ->
    #{test := Test, fail := Fail} = persistent_term:get(?MODULE),
    Test ! {nif, Call},
    case lists:member(Name, Fail) of
        true -> {error, enomem};
        false -> Ok()
    end.

obj(Kind) ->
    {obj, Kind, erlang:unique_integer([positive, monotonic])}.
