%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ip6_wire_fuzz).
-moduledoc """
The fuzz target of erx_ip6_wire:decode/1 (docs/design-network-stack.md,
"Codecs: fuzz targets"), run by tools/fuzz/erx_net_codec.rb. Each round
builds an IPv6 packet with a random chain of extension headers, its lengths
biased to the edges and sometimes corrupted, and checks that the decoder
never raises; that it accepts exactly what `judge/1` accepts; that encoding
an accepted packet's record and decoding it again gives the record back;
and that the fixed header's fields agree with pkt's (erx_net_pkt_oracle).
`run/1` prints `fuzz: N rounds ok`, or the first failure's tag and halts
with status 1.
""".

-include("erx_ip6.hrl").

-export([judge/1, run/1]).

-define(ROUNDS, 20000).
-define(NEST_LIMIT, 15).
-define(IS_EXT(Nxt), (Nxt =:= 0 orelse Nxt =:= 43 orelse Nxt =:= 44 orelse Nxt =:= 60)).

-doc "Runs the target from the seed, the command line's one argument.".
-spec run([string()]) -> ok.
run([Seed]) ->
    _ = rand:seed(exsss, {list_to_integer(Seed), 16#1b, 16#5a}),
    try
        Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), check(frame()) =:= accepted]),
        io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Accepted])
    catch
        throw:{fail, Tag, Detail} ->
            io:format("fuzz: ~p ~P~n", [Tag, Detail, 40]),
            halt(1)
    end.

check(Frame) ->
    Result = try erx_ip6_wire:decode(Frame)
             catch Class:Reason:Stack -> fail(decoder_raised, {Frame, Class, Reason, Stack})
             end,
    case {Result, judge(Frame)} of
        {{ok, Header, Payload}, accept} ->
            round_trip(Header, Payload),
            agree_with_pkt(Frame, Header, Payload),
            accepted;
        {{error, _}, refuse} ->
            refused;
        {_, Judged} ->
            fail(disagrees_with_reference, {Frame, Result, Judged})
    end.

%% The encoder writes options with the least padding, so the offsets that
%% padding moves (proto_ptr, hdrlen) are compared only through pkt below.
round_trip(Header, Payload) ->
    Encoded = iolist_to_binary(erx_ip6_wire:encode(Header, Payload)),
    Expected = unpadded(Header),
    case erx_ip6_wire:decode(Encoded) of
        {ok, Decoded, Payload} when is_record(Decoded, ip6) ->
            unpadded(Decoded) =:= Expected orelse fail(round_trip_differs, {Header, Payload, Encoded, Decoded});
        Other -> fail(round_trip_differs, {Header, Payload, Encoded, Other})
    end.

unpadded(Header) -> Header#ip6{proto_ptr = 0, hdrlen = 0}.

agree_with_pkt(Frame, #ip6{exthdrs = ExtHdrs, fragment = Fragment, proto = Proto,
                           hdrlen = HdrLen} = H, Payload) ->
    Nxt = case {ExtHdrs, Fragment} of
              {[First | _], _} -> exthdr_type(First);
              {[], none} -> Proto;
              {[], _} -> 44
          end,
    Ours = #{v => 6, class => H#ip6.tclass, flow => H#ip6.flow, plen => HdrLen + byte_size(Payload),
             nxt => Nxt, hlim => H#ip6.hlim, src => H#ip6.src, dst => H#ip6.dst},
    case erx_net_pkt_oracle:ipv6(Frame) of
        {ok, Ours, _} -> ok;
        {error, rejected} -> ok;
        {ok, Theirs, _} -> fail(disagrees_with_pkt, {Frame, Ours, Theirs})
    end.

exthdr_type({hopopts, _}) -> 0;
exthdr_type({dstopts, _}) -> 60;
exthdr_type({routing, _, _}) -> 43;
exthdr_type({fragment, _, _, _}) -> 44.

fail(Tag, Detail) -> throw({fail, Tag, Detail}).

-doc """
The reference judge, from RFC 8200's rules and the limits the design
adopts from FreeBSD: accept or refuse, nothing more. It walks the same
chain the decoder walks, so it is a second reading of the rules rather
than independent evidence; what it adds is a short, separate statement
of when a packet is acceptable, and it says nothing about pointers or
the fields of an accepted packet, which the EUnit cases pin.
""".
-spec judge(binary()) -> accept | refuse.
judge(<<6:4, _:28, Plen:16, Nxt, _, _:32/binary, Rest/binary>>) when Plen =< byte_size(Rest) ->
    case {Plen, Nxt} of
        {0, 0} -> refuse;          % a jumbogram, which the stack does not take
        _ -> chain(Nxt, binary:part(Rest, 0, Plen), 0, true)
    end;
judge(_) ->
    refuse.

%% The header chain from Nxt over Bin, after Depth hand-offs not counting a
%% hop-by-hop header; the upper layer is a hand-off too.
chain(_, _, Depth, _) when Depth >= ?NEST_LIMIT -> refuse;
chain(0, _, _, false) -> refuse;   % hop-by-hop only first
chain(Nxt, Bin, Depth, _) when Nxt =:= 0; Nxt =:= 60 ->
    whole(Bin, fun(Next, <<_, _, Options/binary>>, More) ->
                       case tlvs_ok(Options, Nxt) of
                           true -> chain(Next, More, Depth + min(Nxt, 1), false);
                           false -> refuse
                       end
               end);
chain(43, <<_, _, _, SegLeft, _/binary>>, _, _) when SegLeft =/= 0 -> refuse;
chain(43, Bin, Depth, _) ->
    whole(Bin, fun(Next, _, More) -> chain(Next, More, Depth + 1, false) end);
chain(44, <<Next, _, Off:13, _:2, M:1, _:32, Data/binary>>, Depth, _) ->
    if
        M =:= 1, byte_size(Data) rem 8 =/= 0 -> refuse;
        Off =:= 0, M =:= 0 -> chain(Next, Data, Depth + 1, false);
        Data =:= <<>> -> refuse;
        Off =:= 0 -> first_fragment(Next, Data, Depth + 1);
        true -> accept
    end;
chain(44, _, _, _) -> refuse;
chain(_, _, _, _) -> accept.

%% RFC 7112: the rest of the chain and the upper layer's header are here.
first_fragment(Nxt, _, Depth) when Depth >= ?NEST_LIMIT, ?IS_EXT(Nxt) -> refuse;
first_fragment(44, <<Next, _:7/binary, More/binary>>, Depth) -> first_fragment(Next, More, Depth + 1);
first_fragment(44, _, _) -> refuse;
first_fragment(Nxt, Bin, Depth) when ?IS_EXT(Nxt) ->
    whole(Bin, fun(Next, _, More) -> first_fragment(Next, More, Depth + 1) end);
first_fragment(Nxt, Bin, _) ->
    Need = maps:get(Nxt, #{6 => 20, 17 => 8, 58 => 8}, 0),
    case byte_size(Bin) >= Need of true -> accept; false -> refuse end.

%% A header of (Len + 1) * 8 bytes must be all there.
whole(<<Next, Len, _/binary>> = Bin, Then) when byte_size(Bin) >= (Len + 1) * 8 ->
    <<Header:((Len + 1) * 8)/binary, More/binary>> = Bin,
    Then(Next, Header, More);
whole(_, _) ->
    refuse.

%% Options lie inside their header; an unknown type must say "skip"; a
%% router alert, known only to hop-by-hop headers, has two bytes.
tlvs_ok(<<>>, _) -> true;
tlvs_ok(<<0, Rest/binary>>, Kind) -> tlvs_ok(Rest, Kind);
tlvs_ok(<<Type, Len, Data:Len/binary, Rest/binary>>, Kind) ->
    Known = case {Type, Kind} of
                {1, _} -> true;
                {5, 0} -> byte_size(Data) =:= 2;
                _ -> Type band 16#c0 =:= 0
            end,
    Known andalso tlvs_ok(Rest, Kind);
tlvs_ok(_, _) -> false.

%% A random packet: a chain of up to five extension headers, an upper-layer
%% header of an edge length, a payload length that is usually right, and
%% now and then a flipped byte or a cut.
frame() ->
    Proto = oneof([6, 17, 58, 59, 59, rand:uniform(256) - 1]),
    Chain = [exthdr(Position) || Position <- lists:seq(1, oneof([0, 0, 1, 1, 2, 3, 5, 14, 15, 16]))],
    {Nxt, Headers} = lists:foldr(fun(Make, {Next, Acc}) ->
                                         {Type, Bytes} = Make(Next),
                                         {Type, [Bytes | Acc]}
                                 end, {Proto, []}, Chain),
    Payload = iolist_to_binary([Headers, bytes(oneof([0, 7, 8, 19, 20, 21, rand:uniform(80)]))]),
    Plen = max(0, min(16#ffff, byte_size(Payload) + oneof([0, 0, 0, 0, 0, 0, -1, 1, -8]))),
    Version = oneof([6, 6, 6, 6, 6, 6, 6, 6, 4, rand:uniform(16) - 1]),
    Frame = <<Version:4, (rand:uniform(256) - 1):8, (rand:uniform(16#100000) - 1):20, Plen:16,
              Nxt, (rand:uniform(256) - 1), (bytes(32))/binary, Payload/binary,
              (bytes(oneof([0, 0, 0, 3])))/binary>>,
    mutate(Frame).

mutate(Frame) ->
    case rand:uniform(20) of
        1 -> binary:part(Frame, 0, rand:uniform(byte_size(Frame)) - 1);
        N when N =< 4 ->
            At = rand:uniform(byte_size(Frame)) - 1,
            <<Before:At/binary, Byte, After/binary>> = Frame,
            <<Before/binary, (Byte bxor rand:uniform(255)), After/binary>>;
        _ -> Frame
    end.

%% A header maker: given the next header, its type and bytes. Hop-by-hop
%% headers come first more often than elsewhere.
exthdr(Position) ->
    Kinds = case Position of 1 -> [0, 0, 60, 43, 44]; _ -> [60, 60, 43, 44, 44, 0] end,
    case oneof(Kinds) of
        Options when Options =:= 0; Options =:= 60 ->
            fun(Next) -> {Options, options_header(Next, Options)} end;
        43 ->
            fun(Next) ->
                    Data = bytes(4 + 8 * oneof([0, 0, 1, 2])),
                    SegLeft = oneof([0, 0, 0, 0, 1, rand:uniform(255)]),
                    {43, <<Next, ((4 + byte_size(Data)) div 8 - 1 + skew()), (oneof([0, 2, 4, rand:uniform(256) - 1])),
                           SegLeft, Data/binary>>}
            end;
        44 ->
            fun(Next) ->
                    Offset = oneof([0, 0, 0, 8 * rand:uniform(8191)]),
                    {44, <<Next, (oneof([0, 0, 0, rand:uniform(255)])), (Offset bor oneof([0, 1])):16,
                           (rand:uniform(16#ffffffff)):32>>}
            end
    end.

options_header(Next, Kind) ->
    Options = iolist_to_binary([option(Kind) || _ <- lists:seq(1, oneof([0, 1, 2, 3]))]),
    Size = 2 + byte_size(Options),
    Total = max(8, (Size + 7) div 8 * 8),
    Pad = case Total - Size of 0 -> <<>>; 1 -> <<0>>; N -> <<1, (N - 2), 0:((N - 2) * 8)>> end,
    <<Next, (Total div 8 - 1 + skew()), Options/binary, Pad/binary>>.

option(Kind) ->
    case rand:uniform(7) of
        1 -> <<0>>;
        2 -> Len = rand:uniform(4) - 1, <<1, Len, 0:(Len * 8)>>;
        3 -> <<5, (oneof([2, 2, 2, 1, 3])), 0:16>>;
        4 -> <<16#c2, 4, (oneof([0, 65535, 70000])):32>>;
        5 when Kind =:= 0 -> <<5, 2, 0:16>>;
        _ ->
            Type = (oneof([0, 0, 0, 1, 2, 3]) bsl 6) bor (2 + rand:uniform(29)),
            Len = rand:uniform(6) - 1,
            <<Type, (Len + oneof([0, 0, 0, 0, 0, 0, 1])), (bytes(Len))/binary>>
    end.

%% Usually 0; now and then a length one off.
skew() -> oneof([0, 0, 0, 0, 0, 0, 0, 0, 0, 1]).

oneof(List) -> lists:nth(rand:uniform(length(List)), List).

bytes(N) -> rand:bytes(N).
