%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random batches of receive completions through erx_genet_core:frames/2, the Pi 4
%% Ethernet driver's reading of what the controller wrote, as the device NIF hands
%% it up: the descriptor status's bits below its length field and the bytes the
%% length said. Whatever arrives, frames/2 returns no frame longer than the MTU and
%% its Ethernet header, keeps frames and drops in order, and agrees with
%% reference/1, which judges each completion bit by bit and takes the frame as the
%% bytes after the padding; erx_genet_rx:frame/2 agrees with it on each completion
%% alone, with the buffer in place of the MTU as the longest. Sizes cluster at the
%% boundaries (the shortest frame and one short, the longest frame and one past,
%% the buffer and one past), and flags are either a clean start and end of packet
%% or any 16 bits, so every path is common. The seed comes from make check-fuzz.

-module(erx_genet_rx_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(BUFFER, 2048).
-define(PAD, 2).
-define(SHORTEST, (?PAD + 14)).
-define(MTU, 1500).
-define(LONGEST, (?PAD + 14 + ?MTU)).
-define(SOP, (1 bsl 13)).
-define(EOP, (1 bsl 14)).
%% The fewest frames the rounds must accept, so an edit to the generator cannot
%% leave the accepting path untried.
-define(MIN_ACCEPTED, ?ROUNDS div 4).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = lists:sum([round_of() || _ <- lists:seq(1, ?ROUNDS)]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

%% One batch of up to four completions; the frames it accepted.
round_of() ->
    Completions = [completion() || _ <- lists:seq(1, rand:uniform(5) - 1)],
    [case {erx_genet_rx:frame(Flags, Bytes), judge(Flags, Bytes, ?BUFFER)} of
         {Same, Same} -> ok;
         {Judged, _} -> error({disagrees_with_reference, rx, Flags, Bytes, Judged})
     end || {Flags, Bytes} <- Completions],
    Said = erx_genet_core:frames(Completions, ?MTU),
    case Said =:= reference(Completions) of
        true -> shape(Said), length(element(2, Said));
        false -> error({disagrees_with_reference, core, Completions, Said})
    end.

completion() ->
    Size = case rand:uniform(8) of
               1 -> ?SHORTEST - 1;
               2 -> ?SHORTEST;
               3 -> ?LONGEST;
               4 -> ?LONGEST + 1;
               5 -> ?BUFFER + rand:uniform(2) - 1;
               6 -> rand:uniform(?BUFFER + 128) - 1;
               _ -> ?SHORTEST + rand:uniform(?MTU)
           end,
    Flags = case rand:uniform(4) of
                1 -> rand:uniform(16#10000) - 1;
                _ -> ?SOP bor ?EOP
            end,
    {Flags, rand:bytes(Size)}.

shape({Drops, Frames}) ->
    [true = is_binary(F) andalso byte_size(F) =< ?LONGEST - ?PAD || F <- Frames],
    [true = lists:member(D, [overflow, crc_error, rx_error, non_octet, length_error, fragment, runt,
                             too_long]) || {dropped, D} <- Drops],
    ok.

reference(Completions) ->
    Judged = [judge(Flags, Bytes, ?LONGEST) || {Flags, Bytes} <- Completions],
    {[{dropped, D} || {drop, D} <- Judged], [F || {frame, F} <- Judged]}.

%% The judgement of one completion whose frame and padding are at most Longest bytes.
judge(Flags, Bytes, Longest) ->
    <<_:1, Eop:1, Sop:1, _:8, Len:1, NonOctet:1, Err:1, Crc:1, Ov:1>> = <<Flags:16>>,
    Size = byte_size(Bytes),
    if
        Ov =:= 1 -> {drop, overflow};
        Crc =:= 1 -> {drop, crc_error};
        Err =:= 1 -> {drop, rx_error};
        NonOctet =:= 1 -> {drop, non_octet};
        Len =:= 1 -> {drop, length_error};
        Sop =:= 0; Eop =:= 0 -> {drop, fragment};
        Size < ?SHORTEST -> {drop, runt};
        Size > Longest -> {drop, too_long};
        true ->
            <<_Pad:?PAD/binary, Frame/binary>> = Bytes,
            {frame, Frame}
    end.
