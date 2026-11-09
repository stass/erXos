%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_icmp4_fuzz).
-moduledoc """
The fuzz target of erx_icmp4:decode_quoted/1 (docs/design-network-stack.md, "Codecs: fuzz
targets"), run by tools/fuzz/erx_net_codec.rb. Each round builds the quoted datagram of an
ICMP error, a header of an edge length with addresses sometimes multicast or zero, and
sometimes cut short, and checks that the decoder never raises, that it accepts exactly
what `judge/1` accepts, and that an accepted quote's fields are the bytes they name.
`run/1` prints `fuzz: N rounds ok, M accepted`, or the first failure's tag and halts with
status 1.
""".

-export([judge/1, run/1]).

-define(ROUNDS, 20000).

-doc "Runs the target from the seed, the command line's one argument.".
-spec run([string()]) -> ok.
run([Seed]) ->
    _ = rand:seed(exsss, {list_to_integer(Seed), 16#9a, 16#51}),
    try
        Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), check(invoking()) =:= accepted]),
        io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Accepted])
    catch
        throw:{fail, Tag, Detail} ->
            io:format("fuzz: ~p ~P~n", [Tag, Detail, 40]),
            halt(1)
    end.

check(Invoking) ->
    Result = try erx_icmp4:decode_quoted(Invoking)
             catch Class:Reason:Stack -> fail(raised, {Invoking, Class, Reason, Stack})
             end,
    case {Result, judge(Invoking)} of
        {{ok, Quoted}, accept} -> fields(Invoking, Quoted);
        {{error, _}, refuse} -> refused;
        {_, Judged} -> fail(disagrees_with_reference, {Invoking, Result, Judged})
    end.

fields(<<_:4, Hl:4, _:64, P, _:16, Src:4/binary, Dst:4/binary, _/binary>> = Invoking, Quoted) ->
    <<_:Hl/unit:32, Upper/binary>> = Invoking,
    case Quoted of
        #{proto := P, src := Src, dst := Dst, upper := Upper} -> accepted;
        _ -> fail(disagrees_with_reference, {Invoking, Quoted})
    end.

fail(Tag, Detail) -> throw({fail, Tag, Detail}).

-doc """
The reference judge, from RFC 792's quote and `icmp_input`'s checks before it delivers an
error: a header length of at least 5 words, the header and 8 bytes present, a destination
outside 224.0.0.0/4, and neither address 0.0.0.0.
""".
-spec judge(binary()) -> accept | refuse.
judge(<<_:4, Hl:4, _:88, Src:32, Dst:32, _/binary>> = Invoking)
  when Hl >= 5, byte_size(Invoking) >= Hl * 4 + 8, Dst bsr 28 =/= 2#1110, Src =/= 0, Dst =/= 0 ->
    accept;
judge(_) ->
    refuse.

invoking() ->
    Hl = oneof([5, 5, 5, 6, 15, 4, rand:uniform(16) - 1]),
    Src = oneof([<<10, 0, 0, 2>>, <<0:32>>, rand:bytes(4)]),
    Dst = oneof([<<10, 0, 0, 1>>, <<0:32>>, <<224, 0, 0, 1>>, <<239, 1, 2, 3>>, rand:bytes(4)]),
    Rest = rand:bytes(max(Hl * 4 - 20, 0) + oneof([8, 8, 7, 0, 30])),
    Whole = <<4:4, Hl:4, (rand:bytes(8))/binary, (rand:uniform(256) - 1), 0:16, Src/binary, Dst/binary, Rest/binary>>,
    case rand:uniform(10) of
        1 -> binary:part(Whole, 0, rand:uniform(byte_size(Whole)) - 1);
        _ -> Whole
    end.

oneof(List) -> lists:nth(rand:uniform(length(List)), List).
