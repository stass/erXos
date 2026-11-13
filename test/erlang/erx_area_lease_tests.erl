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

%% Every lease of these cases is lent by the test's own process with the one
%% reference tag/0 keeps for it, which each return must carry.
lend(Area, Offset, Pages, Holder) ->
    erx_area:lend(Area, Offset, Pages, Holder, tag()).

tag() ->
    case get(lease_tag) of
        undefined -> put(lease_tag, make_ref()), get(lease_tag);
        Tag -> Tag
    end.

returned(Lease) ->
    Tag = tag(),
    receive {erx_area_returned, Tag, Lease} -> ok after 1000 -> timeout end.

nothing_returned() ->
    receive {erx_area_returned, _, _} = Message -> {unexpected, Message} after 100 -> ok end.

%% The area's destructor runs once its last term is dropped: lend kept no reference.
unmapped(Tag) ->
    erlang:garbage_collect(),
    receive {erx_area_unmapped, Tag} -> ok after 1000 -> timeout end.

lend_refusals_test() ->
    {Area, _} = area(write),
    {ReadOnly, _} = area(read),
    Self = self(),
    Most = ?MEM_BYTES div ?PAGE,
    ?assertMatch({ok, N} when N >= 1, lend(Area, 0, ?PAGES, Self)),
    ?assertEqual({error, einval}, lend(Area, ?PAGE, ?PAGES, Self)),
    ?assertEqual({error, einval}, lend(Area, (1 bsl 64) - ?PAGE, 2, Self)),
    ?assertEqual({error, einval}, lend(Area, ?PAGE + 1, 1, Self)),
    ?assertEqual({error, einval}, lend(Area, 0, 0, Self)),
    ?assertEqual({error, einval}, lend(Area, 0, Most + 1, Self)),
    ?assertEqual({error, einval}, lend(ReadOnly, 0, 1, Self)),
    Tag = make_ref(),
    [?assertError(badarg, erx_area:lend(A, O, P, H, T))
     || {A, O, P, H, T} <- [{Area, -1, 1, Self, Tag}, {Area, 0, -1, Self, Tag}, {Area, 1 bsl 64, 1, Self, Tag},
                            {Area, 0.0, 1, Self, Tag}, {Area, 0, 1, not_a_pid, Tag}, {make_ref(), 0, 1, Self, Tag},
                            {Area, 0, 1, Self, 1}]],
    [?assertError(badarg, erx_area:unlend(L)) || L <- [0, -1, 1 bsl 64, 1.0, x]],
    ?assertEqual(ok, erx_area:unlend((1 bsl 64) - 1)).

noproc_test() ->
    {Area, Tag} = area(write),
    Before = erx_area:leases(),
    {Pid, _} = Holder = holder(),
    stop(Holder),
    ?assertEqual({error, noproc}, lend(Area, 0, 1, Pid)),
    ?assertEqual(Before, erx_area:leases()),
    ?assertEqual(ok, nothing_returned()),
    ?assertEqual(ok, unmapped(Tag)).

held_lease_returns_once_at_its_holders_exit_test() ->
    {Area, Tag} = area(write),
    {Pid, _} = Holder = holder(),
    {ok, Lease} = lend(Area, 0, 1, Pid),
    stop(Holder),
    ?assertEqual(ok, returned(Lease)),
    ?assertEqual(ok, erx_area:unlend(Lease)),
    ?assertEqual(none, erx_area:take(Lease, Pid, 1)),
    ?assertEqual(ok, nothing_returned()),
    ?assertEqual(ok, unmapped(Tag)).

give_back_returns_once_test() ->
    {Area, Tag} = area(write),
    {Pid, _} = Holder = holder(),
    {ok, Lease} = lend(Area, ?PAGE, 2, Pid),
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
    {ok, Lease} = lend(Area, ?PAGE, 2, Pid),
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

%% Each return carries its own lease's tag, not the last one lent.
numbers_are_never_given_again_test() ->
    {Area, _} = area(write),
    {FirstTag, SecondTag} = {make_ref(), make_ref()},
    {ok, First} = erx_area:lend(Area, 0, 1, self(), FirstTag),
    {ok, Second} = erx_area:lend(Area, ?PAGE, 1, self(), SecondTag),
    ?assert(Second > First),
    ok = erx_area:unlend(First),
    ?assertEqual(ok, receive {erx_area_returned, FirstTag, First} -> ok after 1000 -> timeout end),
    ok = erx_area:unlend(Second),
    ?assertEqual(ok, receive {erx_area_returned, SecondTag, Second} -> ok after 1000 -> timeout end).

%% zero/3 (docs/design-display.md, "The pixel area", Verification): a range in
%% the middle and one ending at the area's last page read back all zero, with
%% the pages beside them untouched.
zero_clears_exactly_its_range_test() ->
    {Area, _} = area(write),
    Pattern = binary:copy(<<16#a5>>, ?PAGES * ?PAGE),
    ok = erx_area:poke(Area, 0, Pattern),
    Page = fun(N) -> erx_area:peek(Area, N * ?PAGE, ?PAGE) end,
    Zero = binary:copy(<<0>>, ?PAGE),
    Full = binary:copy(<<16#a5>>, ?PAGE),
    ?assertEqual(ok, erx_area:zero(Area, ?PAGE, 2)),
    ?assertEqual([Full, Zero, Zero, Full], [Page(N) || N <- lists:seq(0, 3)]),
    ok = erx_area:poke(Area, 0, Pattern),
    ?assertEqual(ok, erx_area:zero(Area, 2 * ?PAGE, 2)),
    ?assertEqual([Full, Full, Zero, Zero], [Page(N) || N <- lists:seq(0, 3)]).

zero_refusals_test() ->
    {Area, _} = area(write),
    {ReadOnly, _} = area(read),
    ?assertEqual({error, einval}, erx_area:zero(Area, 3 * ?PAGE, 2)),
    ?assertEqual({error, einval}, erx_area:zero(Area, (1 bsl 64) - ?PAGE, 2)),
    ?assertEqual({error, einval}, erx_area:zero(Area, ?PAGE, (1 bsl 64) - 1)),
    ?assertEqual({error, einval}, erx_area:zero(Area, ?PAGE + 1, 1)),
    ?assertEqual({error, einval}, erx_area:zero(Area, 0, 0)),
    ?assertEqual({error, einval}, erx_area:zero(ReadOnly, 0, 1)),
    [?assertError(badarg, erx_area:zero(A, O, P))
     || {A, O, P} <- [{Area, -1, 1}, {Area, 0, -1}, {Area, 1 bsl 64, 1}, {Area, 0.0, 1}, {make_ref(), 0, 1}]].
