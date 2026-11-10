%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_merge_model).
-moduledoc """
A model of `erx_bytes:tcp_merge/1`, written from the rule of docs/design-network-fastpath.md
("The merge") and sharing nothing with the C core (`c_src/erx_tcp_merge.c`): it reads frames
with binary patterns and judges checksums by one's-complement equivalence, a sum being zero
when it is a multiple of 16#FFFF, where the C folds sums. The host stand-in's `tcp_merge/1`
is this model, so the probe (test/fixtures/erx_net_bytes_probe.erl) and the EUnit cases
(test/erlang/erx_bytes_tests.erl) judge the portable NIF and erXos's BIF against it.

A frame is `other` when no TCP connection can be read from it, `{keyed, Conn}` when it is a
TCP segment of connection `Conn` that is never merged, and `{candidate, Conn, Seg}` when the
rule may merge it. A candidate joins the open unit of its connection when `joins/2` holds;
anything else keyed first closes that unit. At most eight units are open, and a ninth
connection closes the oldest.
""".

-export([merge/1, limit/0]).

-define(FRAMES_MAX, 256).
-define(BYTES_MAX, 65536).
-define(UNIT_MAX, 65280).
-define(OPEN_MAX, 8).
-define(ETHER_MIN, 60).

-record(seg, {
    flow :: term(),                     % what joining requires equal besides the connection
    seq :: 0..16#ffffffff,
    ack :: 0..16#ffffffff,
    ts :: none | 0..16#ffffffff,         % TSval
    payload :: binary()
}).

-record(unit, {
    index :: non_neg_integer(),         % its first frame's
    first :: #seg{},
    next_seq :: 0..16#ffffffff,
    ack :: 0..16#ffffffff,
    ts :: none | 0..16#ffffffff,
    bytes :: non_neg_integer()
}).

-doc "The merge's limit, `{Frames, Bytes}`.".
-spec limit() -> {pos_integer(), pos_integer()}.
limit() -> {?FRAMES_MAX, ?BYTES_MAX}.

-doc "The units of a batch, as `erx_bytes:tcp_merge/1` answers them; `badarg` past the limit.".
-spec merge(term()) -> [tuple()].
merge(Frames) ->
    Summed = case is_list(Frames) andalso within_limit(Frames) of
                 true -> [summed(Frame) || Frame <- Frames];
                 false -> erlang:error(badarg)
             end,
    Owners = owners(lists:enumerate(0, Summed), [], []),
    units(lists:zip(Summed, Owners)).

within_limit(Frames) ->
    try length(Frames) of
        Count ->
            Count =< ?FRAMES_MAX andalso lists:all(fun valid/1, Frames)
                andalso lists:all(fun(Frame) -> byte_size(bytes(Frame)) =< ?BYTES_MAX end, Frames)
                andalso before_last(Frames) < ?BYTES_MAX
    catch
        error:badarg -> false
    end.

before_last([]) -> 0;
before_last(Frames) -> lists:sum([byte_size(bytes(Frame)) || Frame <- lists:droplast(Frames)]).

valid(Frame) when is_binary(Frame) -> true;
valid({sum, Sum, Frame}) -> is_integer(Sum) andalso Sum >= 0 andalso Sum =< 16#ffff andalso is_binary(Frame);
valid(_) -> false.

bytes({sum, _, Frame}) -> Frame;
bytes(Frame) -> Frame.

%% Every frame with its network sum: the one it came with, or the fold of its bytes after the
%% Ethernet header, 0 only when they are all zero.
summed({sum, _, _} = Frame) -> Frame;
summed(<<_:14/binary, Network/binary>> = Frame) -> {sum, canonical(weighted(Network, 0)), Frame};
summed(Frame) -> {sum, 0, Frame}.

canonical(0) -> 0;
canonical(Total) -> (Total - 1) rem 16#ffff + 1.

%% The RFC 1071 total of Bytes as they stand from Offset in their packet, unfolded: a byte at
%% an even position is the high half of its word.
weighted(Bytes, Offset) ->
    {Total, _} = lists:foldl(fun(Byte, {T, P}) -> {T + (Byte bsl (8 * (1 - P rem 2))), P + 1} end,
                             {0, Offset}, binary_to_list(Bytes)),
    Total.

%% One's-complement zero: a multiple of 16#FFFF, of either sign.
zero(Total) -> Total rem 16#ffff =:= 0.

%% --- Which frame belongs to which unit --------------------------------------------------

%% For each frame in order, {First, Payload}: the index of its unit's first frame and the
%% payload it adds to the unit. Open lists the open units, oldest first, as {Conn, #unit{}}.
owners([], _Open, Owners) ->
    lists:reverse(Owners);
owners([{Index, {sum, Sum, Frame}} | Rest], Open0, Owners) ->
    case classify(Frame, Sum) of
        {candidate, Conn, Seg} ->
            case lists:keyfind(Conn, 1, Open0) of
                {Conn, Unit} ->
                    case joins(Unit, Seg) of
                        true ->
                            Open = lists:keyreplace(Conn, 1, Open0, {Conn, join(Unit, Seg)}),
                            owners(Rest, Open, [{Unit#unit.index, Seg#seg.payload} | Owners]);
                        false ->
                            Open = open(Conn, Seg, Index, lists:keydelete(Conn, 1, Open0)),
                            owners(Rest, Open, [{Index, Seg#seg.payload} | Owners])
                    end;
                false ->
                    owners(Rest, open(Conn, Seg, Index, Open0), [{Index, Seg#seg.payload} | Owners])
            end;
        {keyed, Conn} ->
            owners(Rest, lists:keydelete(Conn, 1, Open0), [{Index, <<>>} | Owners]);
        other ->
            owners(Rest, Open0, [{Index, <<>>} | Owners])
    end.

open(Conn, Seg, Index, Open0) ->
    Open = case length(Open0) of
               ?OPEN_MAX -> tl(Open0);
               _ -> Open0
           end,
    Len = byte_size(Seg#seg.payload),
    Open ++ [{Conn, #unit{index = Index, first = Seg, next_seq = (Seg#seg.seq + Len) band 16#ffffffff,
                          ack = Seg#seg.ack, ts = Seg#seg.ts, bytes = Len}}].

%% The same flow, in order, an acknowledgement at or past the unit's, no pure ACK that does not
%% advance, neither as the candidate nor as the unit's first frame while the unit's ACK is still
%% its own, timestamps not going back, and the unit's payload below 65,280 bytes.
joins(#unit{first = First, next_seq = Next, ack = UAck, ts = UTs, bytes = Bytes},
      #seg{flow = Flow, seq = Seq, ack = Ack, ts = Ts, payload = Payload}) ->
    First#seg.flow =:= Flow andalso Seq =:= Next andalso at_or_after(Ack, UAck)
        andalso not (Payload =:= <<>> andalso Ack =:= UAck)
        andalso not (First#seg.payload =:= <<>> andalso Ack =:= First#seg.ack)
        andalso (Ts =:= none orelse at_or_after(Ts, UTs))
        andalso Bytes + byte_size(Payload) < ?UNIT_MAX.

join(#unit{next_seq = Next, bytes = Bytes} = Unit, #seg{ack = Ack, ts = Ts, payload = Payload}) ->
    Len = byte_size(Payload),
    Unit#unit{next_seq = (Next + Len) band 16#ffffffff, ack = Ack, ts = Ts,
              bytes = Bytes + Len}.

at_or_after(A, B) -> (A - B) band 16#ffffffff < 16#80000000.

%% --- What a frame is ---------------------------------------------------------------------

classify(<<Link:12/binary, 16#0800:16, Ip/binary>> = Frame, Sum) -> ip4(Link, Ip, byte_size(Frame), Sum);
classify(<<Link:12/binary, 16#86dd:16, Ip/binary>>, Sum) -> ip6(Link, Ip, Sum);
classify(_, _) -> other.

ip4(Link, <<4:4, Ihl:4, Tos, Total:16, _Id:16, _:2, Mf:1, Off:13, _Ttl, 6, _:16,
            Src:4/binary, Dst:4/binary, _/binary>> = Ip, FrameLength, Sum)
  when Ihl >= 5, Off =:= 0, byte_size(Ip) >= Ihl * 4 + 4 ->
    <<_:Ihl/unit:32-binary, Ports:4/binary, _/binary>> = Ip,
    Conn = {4, Src, Dst, Ports},
    Room = byte_size(Ip),
    Shape = Ihl =:= 5 andalso Mf =:= 0 andalso Total >= 40 andalso Total =< Room
        andalso (Total =:= Room orelse FrameLength =:= ?ETHER_MIN),
    case Shape andalso zero(weighted(binary:part(Ip, 0, 20), 0)) of
        true ->
            <<Header:20/binary, Tcp:(Total - 20)/binary, Padding/binary>> = Ip,
            Pseudo = weighted(<<Src/binary, Dst/binary, 0, 6, (Total - 20):16>>, 0),
            Right = zero(Sum - weighted(Header, 0) - weighted(Padding, Total) + Pseudo),
            tcp(Conn, {Link, Tos}, Tcp, Right);
        false ->
            {keyed, Conn}
    end;
ip4(_, _, _, _) ->
    other.

ip6(Link, <<6:4, _:28, Length:16, 6, _Hop, Src:16/binary, Dst:16/binary, Ports:4/binary,
            _/binary>> = Ip, Sum) ->
    Conn = {6, Src, Dst, Ports},
    case Length =:= byte_size(Ip) - 40 of
        true ->
            <<Header:40/binary, Tcp/binary>> = Ip,
            <<Class:4/binary, _/binary>> = Header,
            Pseudo = weighted(<<Src/binary, Dst/binary, Length:32, 0:24, 6>>, 0),
            Right = zero(Sum - weighted(Header, 0) + Pseudo),
            tcp(Conn, {Link, Class}, Tcp, Right);
        false ->
            {keyed, Conn}
    end;
ip6(_, _, _) ->
    other.

%% A candidate carries ACK and nothing else but PSH, and either no option or the timestamps
%% alone in the layout NOP NOP TS.
tcp(Conn, Flow, <<_:32, Seq:32, Ack:32, Off:4, Flags:12, _:48, _/binary>> = Tcp, true)
  when (Flags =:= 16#10 orelse Flags =:= 16#18), Off >= 5, Off * 4 =< byte_size(Tcp) ->
    <<_:20/binary, Options:(Off * 4 - 20)/binary, Payload/binary>> = Tcp,
    Ts = case Options of
             <<>> -> none;
             <<1, 1, 8, 10, Val:32, _:32>> -> Val;
             _ -> bad
         end,
    case Ts of
        bad -> {keyed, Conn};
        _ -> {candidate, Conn, #seg{flow = {Flow, Off}, seq = Seq, ack = Ack, ts = Ts, payload = Payload}}
    end;
tcp(Conn, _, _, _) ->
    {keyed, Conn}.

%% --- The answer --------------------------------------------------------------------------

%% The units in order of their first frames, from each frame with its {First, Payload}.
units(Owned) ->
    Members = maps:groups_from_list(fun({_, {First, _}}) -> First end, Owned),
    [unit(maps:get(First, Members)) || First <- lists:sort(maps:keys(Members))].

unit([{Alone, _}]) ->
    Alone;
unit([{First, _} | _] = Members) ->
    {Last, _} = lists:last(Members),
    {merged, length(Members), First, Last, [Payload || {_, {_, Payload}} <- Members, Payload =/= <<>>]}.
