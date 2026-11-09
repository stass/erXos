%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Properties of erx_tcp_seq near the edges where modular arithmetic turns: references
%% around 2^31 and 2^32 (and their multiples, as a long connection reaches them), wire values
%% around 0, 2^31 and 2^32 - 1, and the tie at a distance of exactly 2^31.
-module(erx_tcp_seq_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MOD, (1 bsl 32)).
-define(HALF, (1 bsl 31)).

%% lift/2 returns a value congruent to the wire value, within [Ref - 2^31, Ref + 2^31), and
%% wire/1 undoes it, for every pair of edge references and edge wire values.
lift_property_test() ->
    Edges = fun(Centre) -> [Centre + D || D <- [-2, -1, 0, 1, 2]] end,
    Refs = lists:append([Edges(C) || C <- [0, ?HALF, ?MOD, 3 * ?HALF, 7 * ?MOD + ?HALF, 1 bsl 40]]),
    Wires = [W || W <- lists:append([Edges(C) || C <- [0, ?HALF, ?MOD]]), W >= 0, W < ?MOD],
    _ = rand:seed(exsss, {4, 4, 4}),
    Random = [{rand:uniform(1 bsl 45) - (1 bsl 44), rand:uniform(?MOD) - 1} || _ <- lists:seq(1, 2000)],
    [check(Ref, Wire) || Ref <- Refs, Wire <- Wires],
    [check(Ref, Wire) || {Ref, Wire} <- Random].

check(Ref, Wire) ->
    Lifted = erx_tcp_seq:lift(Wire, Ref),
    ?assertEqual(Wire, erx_tcp_seq:wire(Lifted)),
    ?assert(Lifted >= Ref - ?HALF andalso Lifted < Ref + ?HALF).

%% A value 2^31 from the reference lifts below it, as SEQ_LT(wire, ref) holds there; one
%% less than 2^31 above lifts above it.
tie_test() ->
    Ref = ?MOD + 5,
    ?assertEqual(Ref - ?HALF, erx_tcp_seq:lift(erx_tcp_seq:wire(Ref + ?HALF), Ref)),
    ?assertEqual(Ref + ?HALF - 1, erx_tcp_seq:lift(erx_tcp_seq:wire(Ref + ?HALF - 1), Ref)).
