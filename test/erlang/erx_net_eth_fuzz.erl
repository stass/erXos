%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random frames through erx_net_eth:decode/1 (docs/design-network-stack.md, "Codecs: fuzz
%% targets"). Whatever arrives, the decoder returns without raising; it accepts exactly the
%% frames reference/1 accepts, which holds an Ethernet II frame to its 14-byte header (IEEE
%% 802.3, clause 3.1.1); on what it accepts, encoding the header and appending the payload
%% gives the frame back, and pkt (erx_net_pkt_oracle) reads the same fields. Lengths cluster
%% at the header's edge. The seed comes from make check-fuzz.
-module(erx_net_eth_fuzz).
-export([run/1]).

-include("erx_net_eth.hrl").

-define(ROUNDS, 20000).
%% The fewest rounds that must decode a frame, so an edit to the generator cannot leave the
%% accepting path untried.
-define(MIN_ACCEPTED, ?ROUNDS div 4).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of() =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of() ->
    Frame = rand:bytes(frame_length()),
    Said = try erx_net_eth:decode(Frame)
           catch Class:Exception -> error({raised, Frame, Class, Exception})
           end,
    case {Said, reference(Frame)} of
        {{ok, #eth{} = Eth, Payload}, accept} ->
            round_trip(Frame, Eth, Payload),
            agrees_with_pkt(Frame, Eth, Payload),
            accepted;
        {{error, too_short}, reject} ->
            refused;
        _ ->
            error({disagrees_with_reference, Frame, Said})
    end.

frame_length() ->
    case rand:uniform(5) of
        1 -> rand:uniform(14) - 1;
        2 -> 13 + rand:uniform(3);
        _ -> rand:uniform(1515) - 1
    end.

round_trip(Frame, Eth, Payload) ->
    case <<(erx_net_eth:encode(Eth))/binary, Payload/binary>> of
        Frame -> ok;
        Other -> error({round_trip_differs, Frame, Other})
    end.

reference(Frame) when byte_size(Frame) >= 14 -> accept;
reference(_Frame) -> reject.

agrees_with_pkt(Frame, #eth{dst = Dst, src = Src, type = Type}, Payload) ->
    case erx_net_pkt_oracle:ether(Frame) of
        {ok, #{dst := Dst, src := Src, type := Type}, Payload} -> ok;
        Other -> error({disagrees_with_pkt, Frame, Other})
    end.
