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
        {{ok, Header, Payload}, {accept, Header, Payload}} ->
            round_trip(Header, Payload),
            agree_with_pkt(Frame, Header, Payload),
            accepted;
        {{error, Reason1}, {refuse, Why}} ->
            refusal(Reason1) =:= Why orelse fail(disagrees_with_reference, {Frame, Result, Why}),
            refused;
        {_, Judged} ->
            fail(disagrees_with_reference, {Frame, Result, Judged})
    end.

%% A refusal FreeBSD answers with a parameter problem must carry the judge's code and
%% pointer; the silent ones differ only in the counter they name.
refusal({param_problem, _, _} = Problem) -> Problem;
refusal({param_problem_unicast, _, _} = Problem) -> Problem;
refusal(_) -> silent.

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
The reference judge, from RFC 8200's rules and the limits and pointers the
design adopts from FreeBSD (ip6_input.c, dest6.c, route6.c, frag6.c). It
reads the packet by absolute offsets, where the decoder matches binaries
header by header, and says what the decoder must return: the record and
payload of an accepted packet (every extension header's contents, the
fragment, the upper layer and the offsets of its next-header byte and its
first byte), or the code and pointer of a refusal FreeBSD answers with a
parameter problem; any other refusal is `silent`.
""".
-spec judge(binary()) -> {accept, #ip6{}, binary()} | {refuse, silent | erx_ip6_wire:reason()}.
judge(<<6:4, TClass:8, Flow:20, Plen:16, Nxt, Hlim, Src:16/binary, Dst:16/binary,
        Rest/binary>> = Frame) when Plen =< byte_size(Rest) ->
    Packet = binary:part(Frame, 0, 40 + Plen),
    Fixed = #ip6{tclass = TClass, flow = Flow, hlim = Hlim, src = Src, dst = Dst, proto = Nxt},
    case Plen of
        0 -> {refuse, silent};                       % no jumbograms
        _ -> chain(Packet, Nxt, 6, 40, 0, [], Fixed)
    end;
judge(_) ->
    {refuse, silent}.

%% The header named at offset Ptr starts at Off, after Depth hand-offs not counting
%% a hop-by-hop header (ip6_hdrnestlimit); Seen holds the headers passed, newest first.
chain(_, _, _, _, Depth, _, _) when Depth >= ?NEST_LIMIT ->
    {refuse, silent};
chain(_, 0, Ptr, Off, _, _, _) when Off =/= 40 ->
    {refuse, {param_problem, 1, Ptr}};             % hop-by-hop only first
chain(P, Nxt, _, Off, Depth, Seen, H) when Nxt =:= 0; Nxt =:= 60 ->
    Kind = case Nxt of 0 -> hopopts; 60 -> dstopts end,
    case header_end(P, Off) of
        none -> {refuse, silent};
        End ->
            case options(P, Off + 2, End, Kind, []) of
                {ok, Options} ->
                    chain(P, binary:at(P, Off), Off, End, Depth + hand_offs(Kind),
                          [{Kind, Options} | Seen], H);
                Refused -> Refused
            end
    end;
chain(P, 43, _, Off, _, _, _) when Off + 4 =< byte_size(P), binary_part(P, Off + 3, 1) =/= <<0>> ->
    {refuse, {param_problem, 0, Off + 2}};         % segments left: the type's offset
chain(P, 43, _, Off, Depth, Seen, H) ->
    case header_end(P, Off) of
        none -> {refuse, silent};
        End ->
            Routing = {routing, binary:at(P, Off + 2), binary:part(P, Off + 4, End - Off - 4)},
            chain(P, binary:at(P, Off), Off, End, Depth + 1, [Routing | Seen], H)
    end;
chain(P, 44, _, Off, _, _, _) when Off + 8 > byte_size(P) ->
    {refuse, silent};
chain(P, 44, _, Off, Depth, Seen, H) ->
    <<_:Off/binary, Next, _, Offset:13, _:2, More:1, Id:32, Data/binary>> = P,
    if
        More =:= 1, byte_size(Data) rem 8 =/= 0 -> {refuse, {param_problem, 0, 4}};
        Offset =:= 0, More =:= 0 ->
            chain(P, Next, Off, Off + 8, Depth + 1, [{fragment, 0, false, Id} | Seen], H);
        Data =:= <<>> -> {refuse, {param_problem, 0, 4}};
        true ->
            Accept = {accept, H#ip6{exthdrs = lists:reverse(Seen),
                                    fragment = {Offset * 8, More =:= 1, Id}, proto = Next,
                                    proto_ptr = Off, hdrlen = Off + 8 - 40}, Data},
            case Offset of
                0 -> first_fragment(P, Next, Off + 8, Depth + 1, Accept);
                _ -> Accept
            end
    end;
chain(P, Nxt, Ptr, Off, _, Seen, H) ->
    {accept, H#ip6{exthdrs = lists:reverse(Seen), proto = Nxt, proto_ptr = Ptr,
                   hdrlen = Off - 40}, binary:part(P, Off, byte_size(P) - Off)}.

%% A hop-by-hop header is handled before ip6_input's loop, so it is no hand-off.
hand_offs(hopopts) -> 0;
hand_offs(dstopts) -> 1.

%% RFC 7112: the rest of the chain and the upper layer's fixed header are in the
%% first fragment, whose data starts at Off.
first_fragment(_, Nxt, _, Depth, _) when Depth >= ?NEST_LIMIT, ?IS_EXT(Nxt) ->
    {refuse, silent};
first_fragment(P, 44, Off, Depth, Accept) when Off + 8 =< byte_size(P) ->
    first_fragment(P, binary:at(P, Off), Off + 8, Depth + 1, Accept);
first_fragment(P, Nxt, Off, Depth, Accept) when ?IS_EXT(Nxt), Nxt =/= 44 ->
    case header_end(P, Off) of
        none -> {refuse, {param_problem, 3, 0}};
        End -> first_fragment(P, binary:at(P, Off), End, Depth + 1, Accept)
    end;
first_fragment(P, Nxt, Off, _, Accept) when not ?IS_EXT(Nxt) ->
    Need = maps:get(Nxt, #{6 => 20, 17 => 8, 58 => 8}, 0),
    case byte_size(P) - Off >= Need of
        true -> Accept;
        false -> {refuse, {param_problem, 3, 0}}
    end;
first_fragment(_, _, _, _, _) ->
    {refuse, {param_problem, 3, 0}}.

%% The end of the options or routing header at Off, (Len + 1) * 8 bytes by its
%% second byte, or none when the packet does not hold it all.
header_end(P, Off) when Off + 2 =< byte_size(P) ->
    End = Off + (binary:at(P, Off + 1) + 1) * 8,
    case End =< byte_size(P) of
        true -> End;
        false -> none
    end;
header_end(_, _) ->
    none.

%% The options from offset At to the header's End. An option lies inside its
%% header. Only hop-by-hop headers know the router alert, which has 4 bytes
%% left for it and two of data, and the jumbo payload option, which drops the
%% packet silently. An unknown type's two high bits say whether to keep it,
%% drop silently or answer with a parameter problem at its type byte, to any
%% destination or only a unicast one.
options(_, End, End, _, Acc) ->
    {ok, lists:reverse(Acc)};
options(P, At, End, Kind, Acc) ->
    case binary:at(P, At) of
        0 -> options(P, At + 1, End, Kind, Acc);
        _ when At + 2 > End -> {refuse, silent};
        Type ->
            Len = binary:at(P, At + 1),
            Data = case At + 2 + Len =< End of
                       true -> binary:part(P, At + 2, Len);
                       false -> overrun
                   end,
            case {Type, Kind, Data} of
                {_, _, overrun} -> {refuse, silent};
                {1, _, _} -> options(P, At + 2 + Len, End, Kind, Acc);
                {5, hopopts, _} when End - At < 4 -> {refuse, silent};
                {5, hopopts, _} when Len =/= 2 -> {refuse, {param_problem, 0, At + 1}};
                {5, hopopts, _} -> options(P, At + 2 + Len, End, Kind, [{Type, Data} | Acc]);
                {16#c2, hopopts, _} -> {refuse, silent};        % no jumbograms
                _ ->
                    case Type bsr 6 of
                        0 -> options(P, At + 2 + Len, End, Kind, [{Type, Data} | Acc]);
                        1 -> {refuse, silent};
                        2 -> {refuse, {param_problem, 2, At}};
                        3 -> {refuse, {param_problem_unicast, 2, At}}
                    end
            end
    end.

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
