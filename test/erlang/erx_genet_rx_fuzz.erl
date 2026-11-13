%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random batches of receive descriptors through erx_genet_rx:batch/2, the Pi 4
%% Ethernet driver's reading of what the controller wrote: a 32-bit status word
%% and the bytes of a 2 KiB buffer. Whatever arrives, batch/2 moves the consumer
%% index by one per descriptor, returns no frame longer than the buffer less its
%% two bytes of padding, and agrees with reference/1, which judges each
%% descriptor field by field and takes the frame as the bytes after the padding.
%% Lengths cluster at the boundaries (the shortest frame and one short, the
%% buffer and one past it, the bytes read and one past), and status words are
%% either a clean start and end of packet or any 32 bits, so every path is
%% common. The seed comes from make check-fuzz.

-module(erx_genet_rx_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(BUFFER, 2048).
-define(PAD, 2).
-define(SHORTEST, (?PAD + 14)).
-define(SOP, (1 bsl 13)).
-define(EOP, (1 bsl 14)).
-define(ERR, (1 bsl 2)).
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

%% One batch of up to four descriptors from a random consumer index; the frames
%% it accepted.
round_of() ->
    Cons = rand:uniform(16#10000) - 1,
    Descriptors = [descriptor() || _ <- lists:seq(1, rand:uniform(5) - 1)],
    Said = erx_genet_rx:batch(Cons, Descriptors),
    case Said =:= reference(Cons, Descriptors) of
        true -> shape(Said), completions(Descriptors), length(element(2, Said));
        false -> error({disagrees_with_reference, Cons, Descriptors, Said})
    end.

descriptor() ->
    Read = case rand:uniform(4) of
               1 -> rand:uniform(?BUFFER + 128) - 1;
               _ -> ?BUFFER + 64
           end,
    Length = case rand:uniform(8) of
                 1 -> ?SHORTEST - 1;
                 2 -> ?SHORTEST;
                 3 -> ?BUFFER;
                 4 -> ?BUFFER + 1;
                 5 -> min(Read, 16#fff);
                 6 -> min(Read + 1, 16#fff);
                 7 -> rand:uniform(16#1000) - 1;
                 _ -> ?SHORTEST + rand:uniform(1536 - ?SHORTEST)
             end,
    Flags = case rand:uniform(4) of
                1 -> rand:uniform(16#10000) - 1;
                _ -> ?SOP bor ?EOP
            end,
    Status = (Length bsl 16) bor Flags,
    {Status, rand:bytes(Read)}.

shape({Next, Frames, Drops}) when is_integer(Next), Next >= 0, Next =< 16#ffff ->
    [true = is_binary(F) andalso byte_size(F) =< ?BUFFER - ?PAD || F <- Frames],
    [true = lists:member(D, [overflow, crc_error, rx_error, non_octet, length_error, fragment, runt,
                             too_long, truncated]) || D <- Drops],
    ok.

%% erx_genet_core:frames/2 over the same descriptors as the device NIF hands them up: the
%% low 16 bits of the status and the bytes its length says, or, as a faulty NIF or a
%% wider length field might, more bytes than a buffer holds. Each is the reference's
%% judgement, a frame past the MTU or a completion past the buffer too_long.
completions(Descriptors) ->
    [begin
         Length = (Status bsr 16) band 16#ffff,
         Copied = case Length =< byte_size(Bytes) of
                      true -> binary:part(Bytes, 0, Length);
                      false -> <<Bytes/binary, (rand:bytes(Length + 4096 - byte_size(Bytes)))/binary>>
                  end,
         Want = case byte_size(Copied) > ?BUFFER of
                    true -> {[{dropped, too_long}], []};
                    false ->
                        case judge((byte_size(Copied) bsl 16) bor (Status band 16#ffff), Copied) of
                            {frame, F} when byte_size(F) > 1514 -> {[{dropped, too_long}], []};
                            {frame, F} -> {[], [F]};
                            {drop, D} -> {[{dropped, D}], []}
                        end
                end,
         Completion = {Status band 16#ffff, Copied},
         case erx_genet_core:frames([Completion], 1500) of
             Want -> ok;
             Said -> error({disagrees_with_reference, core, Completion, Said, Want})
         end
     end || {Status, Bytes} <- Descriptors].

reference(Cons, Descriptors) ->
    Judged = [judge(Status, Bytes) || {Status, Bytes} <- Descriptors],
    {(Cons + length(Descriptors)) rem 16#10000,
     [F || {frame, F} <- Judged], [D || {drop, D} <- Judged]}.

judge(Status, Bytes) ->
    <<Length:16, _:1, Eop:1, Sop:1, _:8, Len:1, NonOctet:1, Err:1, Crc:1, Ov:1>> = <<Status:32>>,
    if
        Ov =:= 1 -> {drop, overflow};
        Crc =:= 1 -> {drop, crc_error};
        Err =:= 1 -> {drop, rx_error};
        NonOctet =:= 1 -> {drop, non_octet};
        Len =:= 1 -> {drop, length_error};
        Sop =:= 0; Eop =:= 0 -> {drop, fragment};
        Length < ?SHORTEST -> {drop, runt};
        Length > ?BUFFER -> {drop, too_long};
        Length > byte_size(Bytes) -> {drop, truncated};
        true ->
            <<_Pad:?PAD/binary, Frame:(Length - ?PAD)/binary, _/binary>> = Bytes,
            {frame, Frame}
    end.
