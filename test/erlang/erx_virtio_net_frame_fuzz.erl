%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random batches of completions through erx_virtio_net:frames/2, the network driver's cut
%% of what a device wrote into a receive buffer: a virtio_net_hdr, then a frame. Whatever
%% arrives, frames/2 returns one drop or one frame per completion, in order, and agrees
%% with reference/2, which judges each completion by its size alone and takes the frame as
%% the bytes after the header. Sizes cluster at the boundaries (empty, one short of a
%% header and an Ethernet header, exact, the MTU's frame and one past it), so every path is
%% common. The seed comes from make check-fuzz.

-module(erx_virtio_net_frame_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(ROUNDS, 20000).
-define(HDR, ?ERX_VIRTIO_NET_HDR_SIZE).
-define(ETHER_HDR_LEN, 14).
-define(MIN_MTU, 68).
-define(MAX_MTU, 1500).
%% The largest completion a receive buffer holds, the driver's buffer size.
-define(BUFFER, (?HDR + ?ETHER_HDR_LEN + ?MAX_MTU)).
%% The fewest frames the rounds must accept, so an edit to the generator cannot leave the
%% accepting path untried.
-define(MIN_ACCEPTED, ?ROUNDS div 10).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = lists:sum([round_of() || _ <- lists:seq(1, ?ROUNDS)]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

%% One batch of up to four completions under one MTU; the frames it accepted.
round_of() ->
    Mtu = ?MIN_MTU + rand:uniform(?MAX_MTU - ?MIN_MTU + 1) - 1,
    Completions = [completion(Mtu) || _ <- lists:seq(1, rand:uniform(4))],
    Said = erx_virtio_net:frames(Completions, Mtu),
    shape(Said),
    case Said =:= reference(Completions, Mtu) of
        true -> length(element(2, Said));
        false -> error({disagrees_with_reference, Mtu, Completions, Said})
    end.

completion(Mtu) ->
    Shortest = ?HDR + ?ETHER_HDR_LEN,
    Longest = Shortest + Mtu,
    Size = case rand:uniform(7) of
               1 -> 0;
               2 -> Shortest - 1;
               3 -> Shortest;
               4 -> Longest;
               5 -> Longest + 1;
               6 -> rand:uniform(?BUFFER + 1) - 1;
               _ -> Shortest + rand:uniform(Mtu + 1) - 1
           end,
    rand:bytes(Size).

shape({Drops, Frames}) when is_list(Drops), is_list(Frames) ->
    [ok = drop_shape(Drop) || Drop <- Drops],
    [true = is_binary(Frame) || Frame <- Frames],
    ok.

drop_shape({dropped, malformed}) -> ok;
drop_shape({dropped, too_long}) -> ok.

reference(Completions, Mtu) ->
    Judged = [judge(Bytes, Mtu) || Bytes <- Completions],
    {[Drop || {dropped, _} = Drop <- Judged], [Frame || {frame, Frame} <- Judged]}.

judge(Bytes, _Mtu) when byte_size(Bytes) < ?HDR + ?ETHER_HDR_LEN -> {dropped, malformed};
judge(Bytes, Mtu) when byte_size(Bytes) > ?HDR + ?ETHER_HDR_LEN + Mtu -> {dropped, too_long};
judge(Bytes, _Mtu) -> {frame, binary:part(Bytes, ?HDR, byte_size(Bytes) - ?HDR)}.
