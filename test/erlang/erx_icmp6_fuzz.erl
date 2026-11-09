%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_icmp6_fuzz).
-moduledoc """
The fuzz target of erx_icmp6:decode_quoted/1 (docs/design-network-stack.md, "Codecs: fuzz
targets"), run by tools/fuzz/erx_net_codec.rb. Each round builds the quoted packet of an
ICMPv6 error: a fixed header with addresses sometimes unspecified, a chain of extension
headers of edge lengths (hop-by-hop, destination options, routing, authentication,
fragment with and without an offset), an upper-layer header of 8 bytes or fewer, and
sometimes cut short. It checks that the decoder never raises, that it accepts exactly what
`judge/1` accepts, and that an accepted quote's fields are the ones the judge finds.
`run/1` prints `fuzz: N rounds ok, M accepted`, or the first failure's tag and halts with
status 1.
""".

-export([judge/1, run/1]).

-define(ROUNDS, 20000).

-doc "Runs the target from the seed, the command line's one argument.".
-spec run([string()]) -> ok.
run([Seed]) ->
    _ = rand:seed(exsss, {list_to_integer(Seed), 16#9b, 16#61}),
    try
        Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), check(invoking()) =:= accepted]),
        io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Accepted])
    catch
        throw:{fail, Tag, Detail} ->
            io:format("fuzz: ~p ~P~n", [Tag, Detail, 40]),
            halt(1)
    end.

check(Invoking) ->
    Result = try erx_icmp6:decode_quoted(Invoking)
             catch Class:Reason:Stack -> fail(raised, {Invoking, Class, Reason, Stack})
             end,
    case {Result, judge(Invoking)} of
        {{ok, Quoted}, {accept, Quoted}} -> accepted;
        {{error, _}, refuse} -> refused;
        {_, Judged} -> fail(disagrees_with_reference, {Invoking, Result, Judged})
    end.

fail(Tag, Detail) -> throw({fail, Tag, Detail}).

-doc """
The reference judge, from RFC 8200's header formats and `icmp6_notify_error`'s walk: a
fixed header present; hop-by-hop (0), routing (43) and destination options (60) headers
of 8 times their length byte plus 8 bytes, authentication headers (51) of 4 times their
length byte plus 8, and fragment headers (44) of 8 bytes, each with its first bytes
inside the quote, are passed, except that a fragment header with a nonzero offset ends
the walk; the upper layer's first 8 bytes inside the quote; neither address `::`.
""".
-spec judge(binary()) -> {accept, map()} | refuse.
judge(<<_:48, Nxt, _, Src:16/binary, Dst:16/binary, _/binary>> = Invoking) ->
    case walk(Nxt, 40, Invoking) of
        {Proto, Off} when Off + 8 =< byte_size(Invoking), Src =/= <<0:128>>, Dst =/= <<0:128>> ->
            {accept, #{proto => Proto, src => Src, dst => Dst,
                       upper => binary:part(Invoking, Off, byte_size(Invoking) - Off)}};
        _ -> refuse
    end;
judge(_) ->
    refuse.

walk(Nxt, Off, Bin) when Off + 2 > byte_size(Bin), (Nxt =:= 0 orelse Nxt =:= 43 orelse Nxt =:= 60 orelse Nxt =:= 51) ->
    truncated;
walk(Nxt, Off, Bin) when Nxt =:= 0; Nxt =:= 43; Nxt =:= 60 ->
    walk(binary:at(Bin, Off), Off + 8 * binary:at(Bin, Off + 1) + 8, Bin);
walk(51, Off, Bin) ->
    walk(binary:at(Bin, Off), Off + 4 * binary:at(Bin, Off + 1) + 8, Bin);
walk(44, Off, Bin) when Off + 8 > byte_size(Bin) ->
    truncated;
walk(44, Off, Bin) ->
    case binary:at(Bin, Off + 2) * 256 + binary:at(Bin, Off + 3) of
        OffLg when OffLg band 16#fff8 =/= 0 -> {44, Off};
        _ -> walk(binary:at(Bin, Off), Off + 8, Bin)
    end;
walk(Nxt, Off, _) ->
    {Nxt, Off}.

invoking() ->
    Src = oneof([<<16#2001, 16#db8, 0:96, 2:16>>, <<0:128>>, rand:bytes(16)]),
    Dst = oneof([<<16#2001, 16#db8, 0:96, 1:16>>, <<0:128>>, rand:bytes(16)]),
    {Nxt, Chain} = chain(rand:uniform(5) - 1),
    Upper = rand:bytes(oneof([8, 8, 20, 7, 0])),
    Whole = <<6:4, 0:28, 0:16, Nxt, 64, Src/binary, Dst/binary, Chain/binary, Upper/binary>>,
    case rand:uniform(8) of
        1 -> binary:part(Whole, 0, rand:uniform(byte_size(Whole)) - 1);
        _ -> Whole
    end.

%% Count extension headers in front of an upper layer of a random protocol, returned
%% with the next-header value naming the first.
chain(0) -> {oneof([6, 17, 58, rand:uniform(256) - 1]), <<>>};
chain(Count) ->
    {Next, Rest} = chain(Count - 1),
    case oneof([0, 43, 60, 51, 44, 44]) of
        44 ->
            Off = (oneof([0, 0, 1, rand:uniform(16#2000) - 1]) bsl 3) bor (rand:uniform(2) - 1),
            {44, <<Next, 0, Off:16, (rand:uniform(1 bsl 32) - 1):32, Rest/binary>>};
        51 ->
            Len = oneof([0, 1, 4]),
            {51, <<Next, Len, (rand:bytes(4 * Len + 6))/binary, Rest/binary>>};
        Type ->
            Len = oneof([0, 0, 1, 3]),
            {Type, <<Next, Len, (rand:bytes(8 * Len + 6))/binary, Rest/binary>>}
    end.

oneof(List) -> lists:nth(rand:uniform(length(List)), List).
