%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pipe_fake_nif).
-moduledoc """
A stand-in for erx_pipe_nif in erx_pipe_srv's tests: every call is sent
to the test process as `{nif, Call}` and answered from what the test
set. Objects are `{obj, Kind, N}`, ends `{fake_end, Pid, Desc}` and
hand-off numbers unique integers. The test process, the calls that
fail, the highest pipe number a make_lock took (so a restarted server
is refused a repeated one, as the NIF refuses it) and the owners of
program holder entries are kept in persistent_term.
""".

-export([setup/1, fail/1, owner/2, make_lock/1, pipes_made/0, make_lane/1, make_bell/3,
         store_wends/2, free_lock/2, close/1, open_end/3, apply/2, hand_make/2,
         holder_owner/1]).

-doc "Sends every later call to Pid, and fails none.".
setup(Pid) ->
    persistent_term:put(?MODULE, #{test => Pid, fail => [], made => 0, owners => #{}}).

-doc "Records Owner as the owner of {program, Program}'s entry, or none for no entry.".
owner(Program, Owner) ->
    #{owners := Owners} = State = persistent_term:get(?MODULE),
    persistent_term:put(?MODULE, State#{owners => Owners#{Program => Owner}}).

-doc "Makes the calls named in Calls fail with enomem.".
fail(Calls) ->
    persistent_term:put(?MODULE, (persistent_term:get(?MODULE))#{fail => Calls}).

make_lock(Pipe) ->
    answer(make_lock, {make_lock, Pipe},
           fun() ->
                   #{made := Made} = State = persistent_term:get(?MODULE),
                   case Pipe > Made of
                       true ->
                           persistent_term:put(?MODULE, State#{made => Pipe}),
                           {ok, obj(lock)};
                       false ->
                           {error, einval}
                   end
           end).

%% Not reported: the server calls it once, at its start.
pipes_made() ->
    maps:get(made, persistent_term:get(?MODULE)).

make_lane(Size) ->
    answer(make_lane, {make_lane, Size}, fun() -> {ok, obj(ring), obj(rpage)} end).

make_bell(Holder, Pipe, End) ->
    answer(make_bell, {make_bell, Holder, Pipe, End}, fun() -> {ok, obj(bell)} end).

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

hand_make(Program, Hands) ->
    answer(hand_make, {hand_make, Program, Hands},
           fun() ->
                   case holder_owner(Program) of
                       {ok, _} -> {ok, [erlang:unique_integer([positive, monotonic]) || _ <- Hands]};
                       none -> none
                   end
           end).

%% Not reported: the server asks it for every forwarded event.
holder_owner(Program) ->
    case maps:get(owners, persistent_term:get(?MODULE)) of
        #{Program := Owner} when is_pid(Owner) -> {ok, Owner};
        _ -> none
    end.

answer(Name, Call, Ok) ->
    #{test := Test, fail := Fail} = persistent_term:get(?MODULE),
    Test ! {nif, Call},
    case lists:member(Name, Fail) of
        true -> {error, enomem};
        false -> Ok()
    end.

obj(Kind) ->
    {obj, Kind, erlang:unique_integer([positive, monotonic])}.
