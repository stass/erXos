%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_net_rand against its definition: block I of a generator's stream is SipHash-2-4 of
%% the counter plus I under the key, every draw takes the next blocks, and split/1 gives a
%% child keyed with the parent's next two blocks while the parent goes on after them. The
%% split property is a function of the split it judges, so the same check that passes
%% erx_net_rand:split/1 must refuse a split that hands the child the parent's own key and
%% counter (docs/design-network-stack.md, "Checksums and random values", seeded failures).
-module(erx_net_rand_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KEY, <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>).

%% Block I of Key's stream as the test computes it, from SipHash alone.
block(Key, I) -> <<(erx_bytes:siphash24(Key, <<I:64>>)):64/little>>.

blocks(Key, From, Count) -> << <<(block(Key, I))/binary>> || I <- lists:seq(From, From + Count - 1) >>.

draws_take_successive_blocks_test() ->
    G0 = erx_net_rand:new(?KEY),
    {A, G1} = erx_net_rand:bytes(3, G0),
    {B, G2} = erx_net_rand:bytes(8, G1),
    {C, G3} = erx_net_rand:bytes(0, G2),
    {D, _} = erx_net_rand:uniform(1000, G3),
    <<Want:3/binary, _/binary>> = block(?KEY, 0),
    ?assertEqual(Want, A),
    ?assertEqual(block(?KEY, 1), B),
    ?assertEqual(<<>>, C),
    <<Third:64/little>> = block(?KEY, 2),
    ?assertEqual(Third rem 1000, D).

draws_are_values_test() ->
    G = erx_net_rand:new(?KEY),
    ?assertEqual(erx_net_rand:bytes(20, G), erx_net_rand:bytes(20, G)),
    {Bytes, _} = erx_net_rand:bytes(20, G),
    <<Want:20/binary, _/binary>> = blocks(?KEY, 0, 3),
    ?assertEqual(Want, Bytes).

%% The child is new/1 of the parent's next two blocks, and the parent's next draw is the
%% block after them; ok, or what differs.
split_property(Split) ->
    {Child, Parent} = Split(erx_net_rand:new(?KEY)),
    Expected = erx_net_rand:new(blocks(?KEY, 0, 2)),
    {ChildDraw, _} = erx_net_rand:bytes(24, Child),
    {ExpectedDraw, _} = erx_net_rand:bytes(24, Expected),
    {ParentDraw, _} = erx_net_rand:bytes(8, Parent),
    case {ChildDraw =:= ExpectedDraw, ParentDraw =:= block(?KEY, 2)} of
        {true, true} -> ok;
        Differs -> {differs, Differs}
    end.

split_property_test() ->
    ?assertEqual(ok, split_property(fun erx_net_rand:split/1)).

%% The seeded failure: a split that gives the child the parent's key and counter.
split_copying_the_parent_fails_the_property_test() ->
    Copying = fun(Gen) -> {_, Parent} = erx_net_rand:split(Gen), {Gen, Parent} end,
    ?assertEqual({differs, {false, true}}, split_property(Copying)).

refusals_test() ->
    G = erx_net_rand:new(?KEY),
    ?assertError(badarg, erx_net_rand:new(<<0:120>>)),
    ?assertError(badarg, erx_net_rand:new(key)),
    ?assertError(badarg, erx_net_rand:bytes(-1, G)),
    ?assertError(badarg, erx_net_rand:bytes(257, G)),
    ?assertError(badarg, erx_net_rand:uniform(0, G)),
    ?assertError(badarg, erx_net_rand:uniform(1 bsl 64 + 1, G)),
    ?assertMatch({N, _} when N >= 0, erx_net_rand:uniform(1 bsl 64, G)).
