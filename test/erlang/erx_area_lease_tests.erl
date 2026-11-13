%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_area_lease_tests).
-moduledoc """
EUnit cases of erx_area's leases (docs/design-display.md, "The pixel area",
The lease), over erx_area's own NIF built for the host with
test/display/erx_area_harness.c, whose take/3, give/1 and map_lease/2 stand
in for the program driver (test/host/erx_area_lease_test.rb).
""".

-include_lib("eunit/include/eunit.hrl").

-define(PAGE, 4096).
-define(PAGES, 4).
-define(MEM_BYTES, 1073741824).
-define(MEM_BASE, 16#7f00000000).
-define(SLOT, 21).

area(Mode) ->
    Tag = make_ref(),
    {ok, Area} = erx_area:map(?SLOT, ?PAGES * ?PAGE, Mode, Tag),
    {Area, Tag}.

%% A process that lives until told to stop, and its monitor.
holder() ->
    spawn_monitor(fun() -> receive stop -> ok end end).

stop({Pid, Ref}) ->
    Pid ! stop,
    receive {'DOWN', Ref, process, Pid, _} -> ok end.

returned(Lease) ->
    receive {erx_area_returned, Lease} -> ok after 1000 -> timeout end.

nothing_returned() ->
    receive {erx_area_returned, _} = Message -> {unexpected, Message} after 100 -> ok end.

%% The area's destructor runs once its last term is dropped: lend kept no reference.
unmapped(Tag) ->
    erlang:garbage_collect(),
    receive {erx_area_unmapped, Tag} -> ok after 1000 -> timeout end.

lend_refusals_test() ->
    {Area, _} = area(write),
    {ReadOnly, _} = area(read),
    Self = self(),
    Most = ?MEM_BYTES div ?PAGE,
    ?assertMatch({ok, N} when N >= 1, erx_area:lend(Area, 0, ?PAGES, Self)),
    ?assertEqual({error, einval}, erx_area:lend(Area, ?PAGE, ?PAGES, Self)),
    ?assertEqual({error, einval}, erx_area:lend(Area, (1 bsl 64) - ?PAGE, 2, Self)),
    ?assertEqual({error, einval}, erx_area:lend(Area, ?PAGE + 1, 1, Self)),
    ?assertEqual({error, einval}, erx_area:lend(Area, 0, 0, Self)),
    ?assertEqual({error, einval}, erx_area:lend(Area, 0, Most + 1, Self)),
    ?assertEqual({error, einval}, erx_area:lend(ReadOnly, 0, 1, Self)),
    [?assertError(badarg, erx_area:lend(A, O, P, H))
     || {A, O, P, H} <- [{Area, -1, 1, Self}, {Area, 0, -1, Self}, {Area, 1 bsl 64, 1, Self},
                         {Area, 0.0, 1, Self}, {Area, 0, 1, not_a_pid}, {make_ref(), 0, 1, Self}]],
    [?assertError(badarg, erx_area:unlend(L)) || L <- [0, -1, 1 bsl 64, 1.0, x]],
    ?assertEqual(ok, erx_area:unlend((1 bsl 64) - 1)).

noproc_test() ->
    {Area, Tag} = area(write),
    Before = erx_area:leases(),
    {Pid, _} = Holder = holder(),
    stop(Holder),
    ?assertEqual({error, noproc}, erx_area:lend(Area, 0, 1, Pid)),
    ?assertEqual(Before, erx_area:leases()),
    ?assertEqual(ok, nothing_returned()),
    ?assertEqual(ok, unmapped(Tag)).

held_lease_returns_once_at_its_holders_exit_test() ->
    {Area, Tag} = area(write),
    {Pid, _} = Holder = holder(),
    {ok, Lease} = erx_area:lend(Area, 0, 1, Pid),
    stop(Holder),
    ?assertEqual(ok, returned(Lease)),
    ?assertEqual(ok, erx_area:unlend(Lease)),
    ?assertEqual(none, erx_area:take(Lease, Pid, 1)),
    ?assertEqual(ok, nothing_returned()),
    ?assertEqual(ok, unmapped(Tag)).

give_back_returns_once_test() ->
    {Area, Tag} = area(write),
    {Pid, _} = Holder = holder(),
    {ok, Lease} = erx_area:lend(Area, ?PAGE, 2, Pid),
    ?assertEqual(ok, erx_area:unlend(Lease)),
    ?assertEqual(ok, returned(Lease)),
    stop(Holder),
    ?assertEqual(ok, erx_area:unlend(Lease)),
    ?assertEqual(ok, nothing_returned()),
    ?assertEqual(ok, unmapped(Tag)).

taken_lease_waits_for_its_driver_test() ->
    {Area, Tag} = area(write),
    {Pid, _} = Holder = holder(),
    {Other, _} = OtherHolder = holder(),
    {ok, Lease} = erx_area:lend(Area, ?PAGE, 2, Pid),
    ?assertEqual(none, erx_area:take(Lease, Other, 2)),
    ?assertEqual(none, erx_area:take(Lease, Pid, 1)),
    ?assertEqual(none, erx_area:take(Lease + 1, Pid, 2)),
    ?assertEqual(ok, erx_area:take(Lease, Pid, 2)),
    ?assertEqual(none, erx_area:take(Lease, Pid, 2)),
    ?assertEqual({0, {7, ?MEM_BASE, 2 * ?PAGE, ?SLOT, ?PAGE, 3, 3}}, erx_area:map_lease(Lease, 7)),
    ?assertEqual(ok, erx_area:unlend(Lease)),
    stop(Holder),
    stop(OtherHolder),
    ?assertEqual(ok, nothing_returned()),
    %% The lease keeps the area while the program maps it.
    erlang:garbage_collect(),
    ?assertEqual(timeout, receive {erx_area_unmapped, Tag} -> ok after 100 -> timeout end),
    ?assertEqual(ok, erx_area:give(Lease)),
    ?assertEqual(ok, returned(Lease)),
    ?assertEqual(ok, nothing_returned()),
    ?assertEqual(ok, unmapped(Tag)).

numbers_are_never_given_again_test() ->
    {Area, _} = area(write),
    {ok, First} = erx_area:lend(Area, 0, 1, self()),
    ok = erx_area:unlend(First),
    ok = returned(First),
    {ok, Second} = erx_area:lend(Area, 0, 1, self()),
    ?assert(Second > First),
    ok = erx_area:unlend(Second),
    ok = returned(Second).
