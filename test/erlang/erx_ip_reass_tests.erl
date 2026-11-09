%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% IP reassembly (erx_ip_reass, erx_ip4_reass, erx_ip6_reass) against a model
%% that records every byte position of the datagram as a map
%% (docs/design-network-stack.md, "Reassembly and buffers: properties against
%% a byte map"), and the cases the model does not reach: which bytes win an
%% IPv4 overlap, the caps, ECN, the IPv6 errors and expiry.
-module(erx_ip_reass_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_ip4_wire.hrl").
-include("erx_ip6.hrl").

-define(SRC4, <<10, 0, 0, 1>>).
-define(DST4, <<10, 0, 0, 2>>).
-define(SRC6, <<16#fe80:16, 0:96, 1:16>>).
-define(DST6, <<16#fe80:16, 0:96, 2:16>>).
-define(ROUNDS, 400).

%% --- The byte-map property -------------------------------------------------

%% Over random arrivals cut from one datagram, with overlapping, duplicate
%% and out-of-range pieces among them, the table completes the datagram
%% exactly when the model does, with the model's bytes, and for IPv6 drops
%% it exactly when the model sees an overlap.
ip4_matches_byte_map_test() -> property(inet, 1).
ip6_matches_byte_map_test() -> property(inet6, 2).

property(Family, Seed) ->
    _ = rand:seed(exsss, {Seed, 16#5e, 16#ed}),
    Completed = lists:sum([one_round(Family) || _ <- lists:seq(1, ?ROUNDS)]),
    %% Many rounds complete the datagram (about a quarter for IPv6, whose
    %% overlaps drop it), so the property is not vacuous.
    ?assert(Completed > ?ROUNDS div 5).

one_round(Family) ->
    Datagram = bytes(8 + rand:uniform(150)),
    Pieces = scenario(byte_size(Datagram), arrivals(Family)),
    Expected = model(Family, byte_size(Datagram), Pieces),
    Got = run(Family, Datagram, Pieces),
    ?assertEqual({Pieces, Expected}, {Pieces, Got}),
    length([done || done <- Got]).

%% The IPv4 table drops a datagram that holds more than 16 fragments, which
%% the model does not count, so IPv4 rounds stay within that.
arrivals(inet) -> 16;
arrivals(inet6) -> 30.

%% A partition of [0, Len) into pieces, shuffled among extra pieces: random
%% cuts that overlap them, repeats of earlier pieces and pieces past the end.
%% A piece is {Off, End, More}; More is set on every piece but the ones that
%% end the datagram, as a sender sets it.
scenario(Len, Max) ->
    Partition = partition(0, Len),
    Extra = [extra(Len, Partition) || _ <- lists:seq(1, rand:uniform(6))],
    Whole = {0, Len, false},
    lists:sublist([P || P <- shuffle(Partition ++ Extra), P =/= Whole], Max).

partition(Off, Len) when Off >= Len -> [];
partition(Off, Len) ->
    End = case Off + 8 * rand:uniform(4) of
              E when E >= Len, Off > 0 -> Len;
              E when E >= Len -> 8 * ((Len - 1) div 8);  % the first piece is never the whole
              E -> E
          end,
    [{Off, End, End < Len} | partition(End, Len)].

extra(Len, Partition) ->
    case rand:uniform(3) of
        1 -> lists:nth(rand:uniform(length(Partition)), Partition);
        2 -> Off = 8 * (rand:uniform((Len + 7) div 8) - 1),
             End = min(Len, Off + 8 * rand:uniform(4)),
             {Off, End, End < Len};
        3 -> Off = 8 * ((Len + 7) div 8 + rand:uniform(3) - 1),
             {Off, Off + 8, true}
    end.

%% The model: a map from byte position to the piece that wrote it. Each
%% arrival yields `done' when the map covers exactly [0, Len), and then the
%% map starts again empty; otherwise `held_or_dropped'. IPv4 keeps the union
%% of what arrives, but drops a piece that has more after it and ends past
%% the end of a last piece already seen (ip_reass's ipq_maxoff); IPv6 drops
%% an exact repeat and empties the map on any other overlap (RFC 5722).
model(Family, Len, Pieces) ->
    {Outcomes, _} = lists:mapfoldl(fun(Piece, State) -> model_step(Family, Len, Piece, State) end,
                                   {#{}, false}, Pieces),
    Outcomes.

model_step(Family, Len, {Off, End, More} = Piece, {Map, LastSeen}) ->
    Positions = lists:seq(Off, End - 1),
    Written = [P || P <- Positions, is_map_key(P, Map)],
    Next = case Family of
               inet when More, LastSeen, End >= Len -> {Map, LastSeen};
               inet -> {write(Map, Positions, Piece), LastSeen orelse not More};
               inet6 when Written =:= [] -> {write(Map, Positions, Piece), false};
               inet6 -> case lists:all(fun(P) -> maps:get(P, Map, none) =:= Piece end, Positions) of
                            true -> {Map, false};
                            false -> {#{}, false}
                        end
           end,
    {NextMap, _} = Next,
    case lists:sort(maps:keys(NextMap)) =:= lists:seq(0, Len - 1) of
        true -> {done, {#{}, false}};
        false -> {held_or_dropped, Next}
    end.

write(Map, Positions, Piece) ->
    lists:foldl(fun(P, M) -> M#{P => Piece} end, Map, Positions).

%% The table's outcome for each piece, checking that a completed packet
%% decodes to the datagram's bytes.
run(Family, Datagram, Pieces) ->
    {Outcomes, _} = lists:mapfoldl(fun(Piece, T) -> run_step(Family, Datagram, Piece, T) end,
                                   new(Family), Pieces),
    Outcomes.

run_step(Family, Datagram, {Off, End, More}, T0) ->
    Data = case End =< byte_size(Datagram) of
               true -> binary_part(Datagram, Off, End - Off);
               false -> bytes(End - Off)
           end,
    case input(Family, Off, More, Data, T0) of
        {done, Packet, T} ->
            ?assertEqual(Datagram, payload(Family, Packet)),
            {done, T};
        {_, _, T} ->
            {held_or_dropped, T};
        {held, T} ->
            {held_or_dropped, T}
    end.

%% --- The caps -------------------------------------------------------------

%% Over random arrivals for several datagrams at once, with small caps, the
%% table never holds more than its caps allow.
held_never_exceeds_caps_test() ->
    _ = rand:seed(exsss, {3, 16#ca, 16#95}),
    Caps = #{datagrams => 3, fragments => 6, bytes => 600, per_datagram => 4},
    lists:foreach(fun(Family) ->
                          Datagram = bytes(400),
                          Arrivals = [{rand:uniform(5), Piece} || _ <- lists:seq(1, 300),
                                                                  Piece <- [extra(400, [{0, 8, true}])]],
                          Last = lists:foldl(fun({Id, {Off, End, More}}, T0) ->
                                              Data = case End =< 400 of
                                                         true -> binary:copy(binary_part(Datagram, Off, End - Off));
                                                         false -> bytes(End - Off)
                                                     end,
                                              T = result_table(input(Family, Id, Off, More, Data, 0, T0)),
                                              #{datagrams := D, fragments := F, bytes := B} = erx_ip_reass:held(T),
                                              ?assert(D =< 3 andalso F =< 6 andalso B =< 600),
                                              T
                                      end, erx_ip_reass:new(Family, Caps), Arrivals),
                          %% The counters return to zero once everything
                          %% expires, so they never drifted from what was held.
                          {_, Empty} = erx_ip_reass:expire(1 bsl 40, Last),
                          ?assertEqual(#{datagrams => 0, fragments => 0, bytes => 0}, erx_ip_reass:held(Empty))
                  end, [inet, inet6]).

%% A datagram still incomplete with more than FreeBSD's 16 (IPv4) or 64
%% (IPv6) fragments is dropped; the last of them can still complete it.
per_datagram_cap_test() ->
    lists:foreach(
      fun({Family, Max}) ->
              Gaps = [{8 * 2 * I, 8} || I <- lists:seq(1, Max)],
              T1 = lists:foldl(fun({Off, Len}, T) ->
                                       {held, T2} = input(Family, Off, true, bytes(Len), T), T2
                               end, new(Family), Gaps),
              ?assertMatch({drop, too_many_fragments, _}, input(Family, 8 * 2 * (Max + 1), true, bytes(8), T1)),
              {drop, too_many_fragments, T3} = input(Family, 8 * 2 * (Max + 1), true, bytes(8), T1),
              ?assertEqual(#{datagrams => 0, fragments => 0, bytes => 0}, erx_ip_reass:held(T3))
      end, [{inet, 16}, {inet6, 64}]),
    Whole = lists:foldl(fun(I, T) -> {held, T2} = input(inet, 8 * I, true, bytes(8), T), T2 end,
                        new(inet), lists:seq(1, 15)),
    {held, Whole2} = input(inet, 8 * 16, false, bytes(8), Whole),
    ?assertMatch({done, _, _}, input(inet, 0, true, bytes(8), Whole2)).

%% Past its datagram cap, IPv4 drops the oldest datagram (ipq_reuse) and
%% IPv6 drops the new fragment (frag6_input).
datagram_cap_test() ->
    T4 = lists:foldl(fun(Id, T) -> {held, T2} = input(inet, Id, 8, true, bytes(8), Id, T), T2 end,
                     erx_ip_reass:new(inet, #{datagrams => 2}), [1, 2]),
    {held, T4b} = input(inet, 3, 8, true, bytes(8), 3, T4),
    ?assertMatch(#{datagrams := 2, fragments := 2}, erx_ip_reass:held(T4b)),
    ?assertEqual(2 + 30000, erx_ip_reass:next_deadline(T4b)),
    T6 = lists:foldl(fun(Id, T) -> {held, T2} = input(inet6, Id, 8, true, bytes(8), Id, T), T2 end,
                     erx_ip_reass:new(inet6, #{datagrams => 2}), [1, 2]),
    ?assertMatch({drop, full, _}, input(inet6, 3, 8, true, bytes(8), 3, T6)).

%% A small fragment cut from a large frame is copied out and charged at its
%% own size; a fragment that is most of its frame is charged for the frame.
held_bytes_count_the_frame_test() ->
    Frame = binary:copy(bytes(4096)),
    {held, T1} = input(inet, 8, true, binary_part(Frame, 100, 8), new(inet)),
    ?assertMatch(#{bytes := 8}, erx_ip_reass:held(T1)),
    {held, T2} = input(inet, 16, true, binary_part(Frame, 0, 2048), T1),
    ?assertMatch(#{bytes := 4104}, erx_ip_reass:held(T2)).

%% --- IPv4 overlaps --------------------------------------------------------

%% The fragment before keeps its bytes; a new fragment takes over the bytes
%% of the one after it (ip_reass).
ip4_overlap_keeps_before_and_takes_after_test() ->
    A = binary:copy(<<"a">>, 16), B = binary:copy(<<"b">>, 16), C = binary:copy(<<"c">>, 8),
    {held, T1} = input(inet, 8, true, A, new(inet)),
    {held, T2} = input(inet, 0, true, B, T1),
    {done, P, _} = input(inet, 24, false, C, T2),
    ?assertEqual(<<B/binary, (binary_part(A, 8, 8))/binary, C/binary>>, payload(inet, P)),
    {held, U1} = input(inet, 0, true, A, new(inet)),
    {held, U2} = input(inet, 8, true, B, U1),
    {done, Q, _} = input(inet, 24, false, C, U2),
    ?assertEqual(<<A/binary, (binary_part(B, 8, 8))/binary, C/binary>>, payload(inet, Q)).

%% Once the last fragment arrived, a fragment past it is dropped.
ip4_fragment_past_the_last_is_dropped_test() ->
    {held, T} = input(inet, 16, false, bytes(8), new(inet)),
    ?assertMatch({drop, bad_end, _}, input(inet, 24, true, bytes(8), T)),
    ?assertMatch({drop, bad_end, _}, input(inet, 8, false, bytes(8), T)).

ip4_fragment_checks_test() ->
    ?assertMatch({drop, too_small, _}, input(inet, 0, true, bytes(12), new(inet))),
    ?assertMatch({drop, too_small, _}, input(inet, 8, false, <<>>, new(inet))).

%% --- ECN ------------------------------------------------------------------

%% RFC 3168, section 5.3: CE onto not-ECT, or not-ECT onto ECT, is dropped;
%% CE onto ECT marks the reassembled datagram CE.
ecn_test() ->
    {held, T1} = erx_ip4_reass:input(ip4(1, 0, 1, 0), bytes(8), 0, new(inet)),
    ?assertMatch({drop, ecn, _}, erx_ip4_reass:input((ip4(1, 1, 0, 0))#ip4{tos = 3}, bytes(8), 0, T1)),
    {held, U1} = erx_ip4_reass:input((ip4(1, 0, 1, 0))#ip4{tos = 2}, bytes(8), 0, new(inet)),
    ?assertMatch({drop, ecn, _}, erx_ip4_reass:input(ip4(1, 1, 0, 0), bytes(8), 0, U1)),
    {done, P, _} = erx_ip4_reass:input((ip4(1, 1, 0, 0))#ip4{tos = 3}, bytes(8), 0, U1),
    {ok, #ip4{tos = 3}, _} = erx_ip4_wire:decode(P),
    {held, V1} = erx_ip6_reass:input((ip6(1, 0, true))#ip6{tclass = 1}, bytes(8), 0, new(inet6)),
    {done, Q, _} = erx_ip6_reass:input((ip6(1, 8, false))#ip6{tclass = 3}, bytes(8), 0, V1),
    {ok, #ip6{tclass = 3}, _} = erx_ip6_wire:decode(Q).

%% --- IPv6 errors and expiry -----------------------------------------------

%% A fragment ending past 65,535 bytes draws a parameter problem at its
%% fragment offset field.
ip6_too_long_test() ->
    ?assertMatch({drop, {param_problem, ?ICMP6_PARAMPROB_HEADER, 42}, _},
                 erx_ip6_reass:input(ip6(1, 65528, true), bytes(16), 0, new(inet6))).

%% Once the offset-0 fragment has arrived, its header bytes count against
%% 65,535: a later fragment that would pass it is dropped, and an offset-0
%% fragment that would put a held one past it drops the datagram. Without
%% these checks the completed datagram would not encode.
header_bytes_count_against_the_limit_test() ->
    {held, T4} = input(inet, 0, true, bytes(8), new(inet)),
    ?assertMatch({drop, too_long, _}, input(inet, 65520, true, bytes(8), T4)),
    {held, U4} = input(inet, 65520, true, bytes(8), new(inet)),
    {drop, too_long_held, V4} = input(inet, 0, true, bytes(8), U4),
    ?assertEqual(#{datagrams => 0, fragments => 0, bytes => 0}, erx_ip_reass:held(V4)),
    {held, U6} = input(inet6, 65520, true, bytes(8), new(inet6)),
    {drop, too_long_held, V6} = erx_ip6_reass:input((ip6(1, 0, true))#ip6{hdrlen = 16}, bytes(8), 0, U6),
    ?assertEqual(#{datagrams => 0, fragments => 0, bytes => 0}, erx_ip_reass:held(V6)).

%% An expired IPv6 datagram yields its first fragment for a time-exceeded
%% error; one without it yields nothing; IPv4 drops both silently.
expiry_test() ->
    {held, T1} = erx_ip6_reass:input(ip6(1, 0, true), bytes(8), 0, new(inet6)),
    {held, T2} = erx_ip6_reass:input(ip6(2, 8, true), bytes(8), 10, T1),
    ?assertEqual(60000, erx_ip6_reass:next_deadline(T2)),
    ?assertMatch({[], _}, erx_ip6_reass:expire(59999, T2)),
    {[{#ip6{fragment = {0, true, 1}}, _}], T3} = erx_ip6_reass:expire(60000, T2),
    {[], T4} = erx_ip6_reass:expire(60010, T3),
    ?assertEqual(none, erx_ip6_reass:next_deadline(T4)),
    {held, U1} = erx_ip4_reass:input(ip4(1, 0, 1, 0), bytes(8), 0, new(inet)),
    ?assertEqual(none, erx_ip4_reass:next_deadline(erx_ip4_reass:expire(30000, U1))).

%% --- Helpers --------------------------------------------------------------

new(inet) -> erx_ip4_reass:new();
new(inet6) -> erx_ip6_reass:new().

input(Family, Off, More, Data, T) -> input(Family, 1, Off, More, Data, 0, T).

input(inet, Id, Off, More, Data, Now, T) ->
    erx_ip4_reass:input(ip4(Id, Off div 8, bool(More), 0), Data, Now, T);
input(inet6, Id, Off, More, Data, Now, T) ->
    erx_ip6_reass:input(ip6(Id, Off, More), Data, Now, T).

result_table({done, _, T}) -> T;
result_table({held, T}) -> T;
result_table({drop, _, T}) -> T.

ip4(Id, Off, Mf, Tos) ->
    #ip4{tos = Tos, len = 0, id = Id, mf = Mf, off = Off, ttl = 64, p = 17, src = ?SRC4, dst = ?DST4}.

ip6(Id, Off, More) ->
    #ip6{tclass = 0, flow = 0, hlim = 64, src = ?SRC6, dst = ?DST6, fragment = {Off, More, Id},
         proto = 17, proto_ptr = 40, hdrlen = 8}.

payload(inet, Packet) ->
    {ok, #ip4{mf = 0, off = 0}, Payload} = erx_ip4_wire:decode(Packet),
    Payload;
payload(inet6, Packet) ->
    {ok, #ip6{fragment = none, proto = 17}, Payload} = erx_ip6_wire:decode(Packet),
    Payload.

bool(true) -> 1;
bool(false) -> 0.

bytes(N) -> rand:bytes(N).

shuffle(List) -> [X || {_, X} <- lists:sort([{rand:uniform(), X} || X <- List])].

%% The head an offset-0 fragment leaves keeps no frame alive: a 100-byte
%% option decoded from a large frame is copied out, and the head is charged
%% at its header bytes.
head_keeps_no_frame_alive_test() ->
    Option = {16#1e, binary:copy(<<7>>, 100)},
    First = (ip6(9, 0, true))#ip6{exthdrs = [{dstopts, [Option]}]},
    Packet = iolist_to_binary(erx_ip6_wire:encode(First, bytes(8))),
    Frame = <<Packet/binary, 0:8000/unit:8>>,
    {ok, Ip, Data} = erx_ip6_wire:decode(Frame),
    {held, T} = erx_ip6_reass:input(Ip, Data, 0, new(inet6)),
    #{bytes := Bytes} = erx_ip_reass:held(T),
    ?assertEqual(8 + Ip#ip6.hdrlen - 8, Bytes),
    {[{#ip6{exthdrs = [{dstopts, [{16#1e, Kept}]}]}, _}], _} = erx_ip6_reass:expire(60000, T),
    ?assertEqual(byte_size(Kept), binary:referenced_byte_size(Kept)).
