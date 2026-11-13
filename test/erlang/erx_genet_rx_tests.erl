%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the Raspberry Pi 4 Ethernet controller's receive decisions,
%% erx_genet_rx. Known answers at every boundary come first, each worked out by
%% hand from FreeBSD's if_genet.c:1406-1409 (start, end and error bits) and
%% :1440-1443 (the padding counted in the length). Then every length field with
%% every combination of the start, end and error bits is judged against a
%% buffer read whole, one read short and one read long, with judge/2, a
%% restatement of the rules that agrees with the known answers, as the oracle.
%% Random batches check that the consumer index moves by one per descriptor and
%% that frames and drops come out in ring order.

-module(erx_genet_rx_tests).
-include_lib("eunit/include/eunit.hrl").

-define(BUFFER, 2048).
-define(SOP, (1 bsl 13)).
-define(EOP, (1 bsl 14)).
-define(ERR, (1 bsl 2)).
%% The five error bits, 0 to 4, each with the reason it drops a frame.
-define(ERRORS, [{1 bsl 0, overflow}, {1 bsl 1, crc_error}, {1 bsl 2, rx_error},
                 {1 bsl 3, non_octet}, {1 bsl 4, length_error}]).

status(Length, Flags) -> (Length bsl 16) bor Flags.

%% The bytes a buffer holds: byte I is I mod 251, so a frame's offset shows.
buffer(Size) -> list_to_binary([I rem 251 || I <- lists:seq(0, Size - 1)]).

%% The oracle: the lowest error bit first, then start and end, then the length against an
%% Ethernet header after the padding, the buffer and the bytes read; a frame is
%% the bytes from offset 2 to the length. The length is all 16 bits of 31:16, as
%% RX_DESC_STATUS.BUFLEN in hw/svd/genet/genet.svd declares, so a set high bit
%% makes a length too long instead of a shorter one.
judge(Status, Bytes) ->
    Length = (Status bsr 16) band 16#ffff,
    Read = byte_size(Bytes),
    if
        Status band 16#1f =/= 0 ->
            {drop, hd([Reason || {Bit, Reason} <- ?ERRORS, Status band Bit =/= 0])};
        Status band (?SOP bor ?EOP) =/= (?SOP bor ?EOP) -> {drop, fragment};
        Length < 2 + 14 -> {drop, runt};
        Length > ?BUFFER -> {drop, too_long};
        Length > Read -> {drop, truncated};
        true -> {frame, list_to_binary(binary:bin_to_list(Bytes, {2, Length - 2}))}
    end.

every_length_and_flag_combination_matches_the_oracle_test_() ->
    {timeout, 120,
     fun() ->
             Buffers = [buffer(?BUFFER), buffer(600), buffer(4096)],
             [begin
                  Status = status(Length, Flags) bor Noise,
                  ?assertEqual({Status, byte_size(Bytes), judge(Status, Bytes)},
                               {Status, byte_size(Bytes), erx_genet_rx:frame(Status, Bytes)})
              end || Bytes <- Buffers, Length <- lists:seq(0, 16#fff),
                     Flags <- [S bor E bor R || S <- [0, ?SOP], E <- [0, ?EOP], R <- [0 | [Bit || {Bit, _} <- ?ERRORS]]],
                     Noise <- [0, 16#f0009fe0 band bnot (?SOP bor ?EOP)]]
     end}.

boundaries_have_their_known_answers_test() ->
    Bytes = buffer(600),
    Whole = ?SOP bor ?EOP,
    Cases = [{status(15, Whole), {drop, runt}},
             {status(16, Whole), {frame, binary:part(Bytes, 2, 14)}},
             {status(17, Whole), {frame, binary:part(Bytes, 2, 15)}},
             {status(600, Whole), {frame, binary:part(Bytes, 2, 598)}},
             {status(601, Whole), {drop, truncated}},
             {status(2048, Whole), {drop, truncated}},
             {status(2049, Whole), {drop, too_long}},
             {status(16#fff, Whole), {drop, too_long}},
             {status(64, ?SOP), {drop, fragment}},
             {status(64, ?EOP), {drop, fragment}},
             {status(64, Whole bor ?ERR), {drop, rx_error}},
             {status(15, ?ERR), {drop, rx_error}}
             | [{status(64, Whole bor Bit), {drop, Reason}} || {Bit, Reason} <- ?ERRORS]],
    [?assertEqual({S, Want}, {S, erx_genet_rx:frame(S, Bytes)}) || {S, Want} <- Cases],
    Full = buffer(?BUFFER),
    ?assertEqual({frame, binary:part(Full, 2, 2046)}, erx_genet_rx:frame(status(2048, Whole), Full)).

no_frame_is_longer_than_the_buffer_less_its_padding_test() ->
    Bytes = buffer(8192),
    Sizes = [byte_size(F) || Length <- lists:seq(0, 16#fff),
                             {frame, F} <- [erx_genet_rx:frame(status(Length, ?SOP bor ?EOP), Bytes)]],
    ?assertEqual(?BUFFER - 2, lists:max(Sizes)).

the_padding_is_counted_in_the_length_and_skipped_test() ->
    Frame = <<1:48, 2:48, 16#0800:16, "payload">>,
    Status = status(2 + byte_size(Frame), ?SOP bor ?EOP),
    ?assertEqual({frame, Frame}, erx_genet_rx:frame(Status, <<16#aa, 16#bb, Frame/binary, 0:800>>)).

a_batch_consumes_every_descriptor_in_ring_order_test() ->
    rand:seed(exsss, {20, 26, 4}),
    [begin
         Cons = rand:uniform(16#10000) - 1,
         Descriptors = [descriptor() || _ <- lists:seq(1, rand:uniform(257) - 1)],
         Judged = [judge(S, B) || {S, B} <- Descriptors],
         Want = {(Cons + length(Descriptors)) band 16#ffff,
                 [F || {frame, F} <- Judged], [D || {drop, D} <- Judged]},
         ?assertEqual(Want, erx_genet_rx:batch(Cons, Descriptors))
     end || _ <- lists:seq(1, 300)].

an_error_frame_moves_the_consumer_index_test() ->
    Bad = {status(64, ?SOP bor ?EOP bor ?ERR), buffer(?BUFFER)},
    Good = {status(64, ?SOP bor ?EOP), buffer(?BUFFER)},
    ?assertMatch({3, [_], [rx_error, rx_error]}, erx_genet_rx:batch(0, [Bad, Good, Bad])),
    ?assertMatch({1, [], [rx_error, rx_error]}, erx_genet_rx:batch(16#ffff, [Bad, Bad])).

descriptor() ->
    Length = case rand:uniform(4) of
                 1 -> rand:uniform(16#1000) - 1;
                 2 -> ?BUFFER + rand:uniform(3) - 2;
                 _ -> 16 + rand:uniform(1520)
             end,
    Flags = case rand:uniform(8) of
                1 -> rand:uniform(16#10000) - 1;
                _ -> ?SOP bor ?EOP
            end,
    {status(Length, Flags), rand:bytes(rand:uniform(?BUFFER + 64) - 1)}.

pending_counts_across_the_wrap_and_refuses_an_overrun_test() ->
    ?assertEqual({ok, 0}, erx_genet_rx:pending(7, 7)),
    ?assertEqual({ok, 5}, erx_genet_rx:pending(2, 16#fffd)),
    ?assertEqual({ok, 256}, erx_genet_rx:pending(16#10100, 0)),
    ?assertEqual({error, {overrun, 257}}, erx_genet_rx:pending(257, 0)),
    ?assertEqual({error, {overrun, 16#ffff}}, erx_genet_rx:pending(0, 1)),
    ?assertEqual([0, 255, 0, 255], [erx_genet_rx:slot(I) || I <- [0, 255, 256, 16#ffff]]).
