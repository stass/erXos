%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The USB domain's drives (docs/design-usb.md, "Mass storage reaches the file servers",
%% "Media and drives"): erx_usb_places_sup started over its drive records, one drive grant
%% (erx_blk_drive) for each, and occupy_drive/2 against a model. Occupants are processes
%% the test drives, as a mass-storage function is: each takes a drive, may serve a medium
%% under it through a stand-in window, and ends, or has its medium end, at the test's
%% choice. The property: every take answers the model's lowest free drive and that drive's
%% grant, or no_drive when none is free, so no two occupants hold one drive and a freed
%% drive is taken again lowest first. A drive is held while its occupant lives and has
%% served no medium yet, or while the medium served under it lives.
-module(erx_usb_drives_prop).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(STEPS, 300).
-define(SETTLE_MS, 1000).

%% Each drive's holding in the model: its occupant, while it lives and before its medium;
%% its medium's window, while it lives.
-record(model, {grants :: #{non_neg_integer() => pid()},
                held = #{} :: #{non_neg_integer() => #{occupant := pid() | none, window := pid() | none}},
                occupants = [] :: [pid()]}).

%% ---------------------------------------------------------------------------
%% By name
%% ---------------------------------------------------------------------------

%% The places start one grant for each drive record, number order kept.
the_places_start_one_grant_per_drive_test() ->
    Places = places({ok, [0, 3, 7]}),
    try
        Drives = erx_usb_places_sup:drives(Places),
        ?assertEqual([0, 3, 7], [N || {N, _} <- Drives]),
        ?assert(lists:all(fun({_, Grant}) -> is_process_alive(Grant) end, Drives)),
        ?assertEqual({error, no_medium}, erx_blk_drive:window(element(2, hd(Drives))))
    after
        stop(Places)
    end.

%% Refused drive records start no grant, so every medium finds no drive; the input
%% numbers are served as ever.
refused_records_start_no_grant_test() ->
    Places = places({error, {bad_device_record, "two drive records name one number"}}),
    try
        ?assertEqual([], erx_usb_places_sup:drives(Places)),
        ?assertEqual({error, no_drive}, erx_usb_places_sup:occupy_drive(Places, occupant())),
        ?assertMatch({ok, 0, _}, erx_usb_places_sup:occupy_input(Places, occupant()))
    after
        stop(Places)
    end.

%% A domain whose manifest names no drive has none to give.
no_records_give_no_drive_test() ->
    Places = places({ok, []}),
    try
        ?assertEqual({error, no_drive}, erx_usb_places_sup:occupy_drive(Places, occupant()))
    after
        stop(Places)
    end.

%% ---------------------------------------------------------------------------
%% The property
%% ---------------------------------------------------------------------------

drives_hold_under_random_sequences_test_() ->
    {timeout, 120, fun() -> lists:foreach(fun run/1, lists:seq(1, 8)) end}.

run(Seed) ->
    rand:seed(exsss, {Seed, Seed * 7, Seed * 13}),
    Numbers = numbers(),
    Places = places({ok, Numbers}),
    try
        Grants = maps:from_list(erx_usb_places_sup:drives(Places)),
        ?assertEqual(Numbers, lists:sort(maps:keys(Grants))),
        M = lists:foldl(fun(_, M0) -> step(Places, M0) end, #model{grants = Grants}, lists:seq(1, ?STEPS)),
        [exit(Pid, kill) || Pid <- M#model.occupants ++ [W || #{window := W} <- maps:values(M#model.held), W =/= none]]
    after
        stop(Places)
    end.

%% One to usb_drives_max distinct numbers below 10, sorted, as drives/2 answers them.
numbers() ->
    Count = rand:uniform(?ERX_USB_DRIVES_MAX),
    lists:sort(lists:sublist([N || {_, N} <- lists:sort([{rand:uniform(), N} || N <- lists:seq(0, 9)])], Count)).

step(Places, M = #model{held = Held, occupants = Occupants}) ->
    Idle = [O || O <- Occupants, not holds(O, Held)],
    Waiting = [N || N := #{occupant := O, window := none} <- Held, O =/= none],
    Serving = [N || N := #{window := W} <- Held, W =/= none],
    Choices = [{take, new}]
              ++ [{take, O} || O <- Idle]
              ++ [{finish, O} || O <- Occupants]
              ++ [{serve, N} || N <- Waiting]
              ++ [{eject, N} || N <- Serving],
    act(Places, pick(Choices), M).

act(Places, {take, new}, M) ->
    act(Places, {take, occupant()}, M);
act(Places, {take, O}, M = #model{grants = Grants, held = Held, occupants = Occupants}) ->
    Expected = case lists:sort([N || N <- maps:keys(Grants), not is_map_key(N, Held)]) of
                   [Lowest | _] -> {ok, Lowest, maps:get(Lowest, Grants)};
                   [] -> {error, no_drive}
               end,
    ?assertEqual(Expected, erx_usb_places_sup:occupy_drive(Places, O)),
    Next = M#model{occupants = lists:usort([O | Occupants])},
    case Expected of
        {ok, N, _} -> Next#model{held = Held#{N => #{occupant => O, window => none}}};
        {error, no_drive} -> Next
    end;
%% An occupant ends: a drive it holds before its medium is free once the grant sees the
%% end; a medium it served lives on and holds its drive.
act(_Places, {finish, O}, M = #model{held = Held, occupants = Occupants}) ->
    exit(O, kill),
    Freed = [N || N := #{occupant := Holder, window := none} <- Held, Holder =:= O],
    Kept = maps:map(fun(_, H = #{occupant := Holder}) when Holder =:= O -> H#{occupant := none};
                       (_, H) -> H
                    end, maps:without(Freed, Held)),
    settle(M, Freed),
    M#model{held = Kept, occupants = Occupants -- [O]};
%% The occupant's medium starts: its window is served to the drive's grant, which the
%% grant then holds instead of the occupant.
act(_Places, {serve, N}, M = #model{grants = Grants, held = Held}) ->
    #{N := H = #{occupant := O}} = Held,
    Grant = maps:get(N, Grants),
    Window = spawn(fun() -> receive stop -> ok end end),
    ok = erx_blk_drive:serve(Grant, Window, {O, {medium, N}}),
    ?assertEqual({ok, Window}, erx_blk_drive:window(Grant)),
    M#model{held = Held#{N := H#{occupant := none, window := Window}}};
%% The medium ends: its drive is free once the grant sees the window's end.
act(_Places, {eject, N}, M = #model{held = Held}) ->
    #{N := #{window := Window}} = Held,
    exit(Window, kill),
    settle(M, [N]),
    M#model{held = maps:remove(N, Held)}.

holds(O, Held) -> lists:any(fun(#{occupant := Holder}) -> Holder =:= O end, maps:values(Held)).

%% Waits until each of Numbers' grants holds neither occupant nor medium, the ends' signals
%% taken, and fails at the step whose end a grant has not seen by the deadline.
settle(#model{grants = Grants}, Numbers) ->
    Deadline = erlang:monotonic_time(millisecond) + ?SETTLE_MS,
    [settle_one(maps:get(N, Grants), Deadline) || N <- Numbers],
    ok.

settle_one(Grant, Deadline) ->
    case sys:get_state(Grant) of
        #{occupant := none, medium := none} -> ok;
        #{} ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(5), settle_one(Grant, Deadline);
                false -> error({drive_not_freed, Grant})
            end
    end.

pick(List) -> lists:nth(rand:uniform(length(List)), List).

%% ---------------------------------------------------------------------------
%% Fixtures
%% ---------------------------------------------------------------------------

places(Drives) ->
    {ok, Places} = erx_usb_places_sup:start_link(Drives),
    unlink(Places),
    Places.

stop(Places) ->
    Monitor = monitor(process, Places),
    exit(Places, shutdown),
    receive {'DOWN', Monitor, process, Places, _} -> ok end.

%% An occupant: a process that lives until it is killed.
occupant() ->
    spawn(fun() -> receive stop -> ok end end).
