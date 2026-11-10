%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_wire_fuzz).
-moduledoc """
The fuzz target of erx_tcp_wire:decode/2 (docs/design-network-stack.md, "Codecs: fuzz
targets"), run by tools/fuzz/erx_net_codec.rb. Each round builds a TCP segment over an IPv4
or IPv6 pseudo-header from random options (well formed, of the wrong length, unknown,
malformed or overrunning), a data offset of an edge value (right, one off, below 5), sometimes
a wrong checksum, a truncation or a corrupted byte, and checks that the decoder never raises;
that it accepts exactly what `judge/2` accepts and reads the options `judge/2` reads; that
encoding an accepted segment and decoding it again gives it back; and that the header fields
and, where every option is well formed, the options agree with pkt's (erx_net_pkt_oracle),
which refuses a header with a reserved bit set.
`run/1` prints `fuzz: N rounds ok, M accepted`, or the first failure's tag and halts with
status 1.
""".

-include("erx_tcp_wire.hrl").

-export([judge/2, run/1]).

-define(ROUNDS, 20000).
-define(IPPROTO_TCP, 6).
-define(SRC4, <<192, 0, 2, 1>>).
-define(DST4, <<198, 51, 100, 7>>).
-define(SRC6, <<16#2001:16, 16#db8:16, 0:80, 1:16>>).
-define(DST6, <<16#2001:16, 16#db8:16, 0:80, 2:16>>).

-doc "Runs the target from the seed, the command line's one argument.".
-spec run([string()]) -> ok.
run([Seed]) ->
    _ = rand:seed(exsss, {list_to_integer(Seed), 16#7c, 16#9}),
    try
        Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), check(segment()) =:= accepted]),
        io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Accepted])
    catch
        throw:{fail, Tag, Detail} ->
            io:format("fuzz: ~p ~P~n", [Tag, Detail, 40]),
            halt(1)
    end.

check({Family, Bytes}) ->
    Result = try erx_tcp_wire:decode(pseudo(Family, byte_size(Bytes)), Bytes)
             catch Class:Reason:Stack -> fail(raised, {Family, Bytes, Class, Reason, Stack})
             end,
    case {Result, judge(Family, Bytes)} of
        {{ok, #tcp{opts = Opts} = Tcp, Payload}, {accept, Opts, Clean}} ->
            round_trip(Family, Tcp, Payload),
            agree_with_pkt(Bytes, Tcp, Payload, Clean),
            accepted;
        {{error, _}, refuse} ->
            refused;
        {_, Judged} ->
            fail(disagrees_with_reference, {Family, Bytes, Result, Judged})
    end.

%% The encoder writes no TCP-MD5 option, so a signed segment comes back unsigned. A decoded
%% segment whose payload leaves no room for the longest header may not encode
%% within 65535 bytes when its options were packed tighter than tcp_addoptions packs them.
round_trip(_, _, Payload) when byte_size(Payload) > 16#ffff - 60 ->
    ok;
round_trip(Family, Tcp, Payload) ->
    Encoded = iolist_to_binary(erx_tcp_wire:encode(Tcp, Payload, pseudo(Family, 0), sender)),
    Unsigned = Tcp#tcp{opts = (Tcp#tcp.opts)#tcp_opts{signature = false}},
    case erx_tcp_wire:decode(pseudo(Family, byte_size(Encoded)), Encoded) of
        {ok, Unsigned, Payload} -> ok;
        Other -> fail(round_trip_differs, {Family, Tcp, Payload, Encoded, Other})
    end.

agree_with_pkt(Bytes, #tcp{sport = Sport, dport = Dport, seq = Seq, ack = Ack, flags = Flags, win = Win,
                           urp = Urp, opts = Opts}, Payload, Clean) ->
    Off = (byte_size(Bytes) - byte_size(Payload)) div 4,
    Ours = #{sport => Sport, dport => Dport, seq => Seq, ack => Ack, off => Off, flags => Flags band 16#1ff,
             win => Win, urp => Urp},
    case erx_net_pkt_oracle:tcp(Bytes) of
        {error, rejected} when Flags band 16#e00 =/= 0 -> ok;
        {ok, Theirs, Payload} ->
            maps:with(maps:keys(Ours), Theirs) =:= Ours orelse fail(disagrees_with_pkt, {Bytes, Ours, Theirs}),
            agree_options(Bytes, Opts, Flags, map_get(options, Theirs), Clean);
        Other -> fail(disagrees_with_pkt, {Bytes, Ours, Other})
    end.

%% pkt refuses unknown kinds and malformed options and keeps a SACK option's whole blocks
%% whatever its length, so its options are compared only when every option is well formed.
agree_options(_, _, _, rejected, _) -> ok;
agree_options(_, _, _, _, false) -> ok;
agree_options(Bytes, Opts, Flags, Theirs, true) ->
    Expected = lists:foldl(fun(Option, Acc) -> pkt_option(Option, syn(Flags), Acc) end, #tcp_opts{}, Theirs),
    Expected =:= Opts orelse fail(options_disagree_with_pkt, {Bytes, Opts, Theirs}).

pkt_option({mss, Mss}, true, Opts) -> Opts#tcp_opts{mss = Mss};
pkt_option({wscale, Shift}, true, Opts) -> Opts#tcp_opts{wscale = min(Shift, 14)};
pkt_option(sack_permitted, true, Opts) -> Opts#tcp_opts{sack_permitted = true};
pkt_option({sack, Blocks}, false, Opts) -> Opts#tcp_opts{sacks = Blocks};
pkt_option({timestamp, Val, Ecr}, _, Opts) -> Opts#tcp_opts{ts = {Val, Ecr}};
pkt_option(_, _, Opts) -> Opts.

fail(Tag, Detail) -> throw({fail, Tag, Detail}).

-doc """
The reference judge, from RFC 9293: a 20-byte header, a checksum over the pseudo-header
written out whole and the segment, and a data offset from 5 words to the segment's length.
For an accepted segment it also returns the options it reads, as `{accept, Opts, Clean}`:
the option list of RFC 9293 section 3.1 split into kinds and bodies, up to end-of-options or
a length that does not fit, with each option of its RFC's length kept, the last of a kind
winning, a TCP-MD5 option (RFC 2385) noted, MSS, window scale (at most 14, RFC 7323) and SACK-permitted only on a SYN and SACK
blocks (RFC 2018) only without one, as FreeBSD reads them. Clean says every option was a known
kind of the right length, where pkt's reading can be compared.
""".
-spec judge(inet | inet6, binary()) -> {accept, #tcp_opts{}, boolean()} | refuse.
judge(Family, Bytes) when byte_size(Bytes) >= 20, byte_size(Bytes) =< 16#ffff ->
    <<_:96, Off:4, Flags:12, _/binary>> = Bytes,
    Sum = erx_bytes:inet_csum(erx_bytes:inet_csum(0, pseudo_header(Family, byte_size(Bytes))), Bytes),
    case Sum =:= 16#ffff andalso Off >= 5 andalso Off * 4 =< byte_size(Bytes) of
        true ->
            Tokens = tokens(binary:part(Bytes, 20, Off * 4 - 20)),
            Known = [Token || {Kind, Body} = Token <- Tokens, well_formed(Kind, byte_size(Body))],
            Opts = lists:foldl(fun(Token, Acc) -> judge_option(Token, syn(Flags), Acc) end, #tcp_opts{}, Known),
            {accept, Opts, Known =:= Tokens};
        false ->
            refuse
    end;
judge(_, _) ->
    refuse.

tokens(<<0, _/binary>>) -> [];
tokens(<<1, Rest/binary>>) -> tokens(Rest);
tokens(<<Kind, Len, Rest/binary>>) when Len >= 2, Len - 2 =< byte_size(Rest) ->
    {Body, After} = split_binary(Rest, Len - 2),
    [{Kind, Body} | tokens(After)];
tokens(<<>>) -> [];
tokens(_Malformed) -> [malformed].

well_formed(2, 2) -> true;
well_formed(3, 1) -> true;
well_formed(4, 0) -> true;
well_formed(5, Len) -> Len > 0 andalso Len rem 8 =:= 0;
well_formed(8, 8) -> true;
well_formed(19, 16) -> true;
well_formed(_, _) -> false.

judge_option({2, <<Mss:16>>}, true, Opts) -> Opts#tcp_opts{mss = Mss};
judge_option({3, <<Shift>>}, true, Opts) -> Opts#tcp_opts{wscale = min(Shift, 14)};
judge_option({4, <<>>}, true, Opts) -> Opts#tcp_opts{sack_permitted = true};
judge_option({5, Blocks}, false, Opts) -> Opts#tcp_opts{sacks = [{S, E} || <<S:32, E:32>> <= Blocks]};
judge_option({8, <<Val:32, Ecr:32>>}, _, Opts) -> Opts#tcp_opts{ts = {Val, Ecr}};
judge_option({19, _}, _, Opts) -> Opts#tcp_opts{signature = true};
judge_option(_, _, Opts) -> Opts.

syn(Flags) -> Flags band ?TH_SYN =/= 0.

pseudo_header(inet, Len) -> <<?SRC4/binary, ?DST4/binary, 0, ?IPPROTO_TCP, Len:16>>;
pseudo_header(inet6, Len) -> <<?SRC6/binary, ?DST6/binary, Len:32, 0:24, ?IPPROTO_TCP>>.

%% No IP packet delivers more than 65535 bytes, and the decoder refuses such a segment before
%% it reads the sum.
pseudo(_, Len) when Len > 16#ffff -> 0;
pseudo(inet, Len) -> erx_ip4_wire:pseudo_sum(?SRC4, ?DST4, Len, ?IPPROTO_TCP);
pseudo(inet6, Len) -> erx_ip6_wire:pseudo_sum(?SRC6, ?DST6, Len, ?IPPROTO_TCP).

%% A segment whose options are random and whose data offset is an edge value against them.
segment() ->
    Family = oneof([inet, inet6]),
    Flags = oneof([?TH_SYN, ?TH_SYN bor ?TH_ACK, ?TH_ACK, ?TH_ACK bor ?TH_PUSH, rand:uniform(16#1000) - 1]),
    Options = pad(iolist_to_binary([option() || _ <- lists:seq(1, rand:uniform(6) - 1)])),
    Payload = bytes(payload_size()),
    Right = 5 + byte_size(Options) div 4,
    Off = oneof([Right, Right, Right, Right, Right, Right, Right - 1, Right + 1, rand:uniform(5) - 1, 15]) band 15,
    Head = <<(port()):16, (port()):16, (number()):32, (number()):32, Off:4, Flags:12, (rand:uniform(16#10000) - 1):16>>,
    Tail = <<(rand:uniform(16#10000) - 1):16, Options/binary, Payload/binary>>,
    {Family, mutate(seal(Family, Head, Tail))}.

%% The option bytes cut to the 40 a header holds and padded to a word, with zeros (end of
%% options) or no-operations.
pad(Options) when byte_size(Options) > 40 -> pad(binary:part(Options, 0, 40));
pad(Options) when byte_size(Options) rem 4 =:= 0 -> Options;
pad(Options) -> pad(<<Options/binary, (oneof([0, 1]))>>).

option() ->
    case rand:uniform(13) of
        1 -> <<2, 4, (oneof([0, 536, 1460, 16#ffff])):16>>;
        2 -> <<3, 3, (rand:uniform(21) - 1)>>;
        3 -> <<4, 2>>;
        4 -> <<8, 10, (number()):32, (number()):32>>;
        5 -> N = rand:uniform(5) - 1, <<5, (2 + 8 * N), (bytes(8 * N))/binary>>;
        6 -> <<1>>;
        7 -> <<0>>;
        8 -> L = rand:uniform(8) + 1, <<(oneof([19, 34, 254, 6])), L, (bytes(L - 2))/binary>>;
        9 -> <<(oneof([2, 3, 4, 8])), 5, 0, 0, 0>>;
        10 -> <<(oneof([2, 5, 8, 77])), (oneof([0, 1]))>>;
        11 -> <<(oneof([2, 8, 77])), 40, 0>>;
        12 -> <<5, 11, (bytes(9))/binary>>;
        13 -> <<19, 18, (bytes(16))/binary>>
    end.

%% Mostly short payloads; one in a hundred near the largest segment, so segments of 16#ffff
%% bytes and beyond are reached.
payload_size() ->
    case rand:uniform(100) of
        1 -> 16#ffff - 20 - oneof([0, 0, 1, 40, -1]);
        _ -> oneof([0, 1, 2, 3, 7, rand:uniform(200)])
    end.

port() -> oneof([0, 80, rand:uniform(16#ffff)]).

number() -> oneof([0, 1, 16#7fffffff, 16#80000000, 16#ffffffff, rand:uniform(16#100000000) - 1]).

%% The checksum over the whole segment: right on most, wrong on a tenth.
seal(Family, Head, Tail) ->
    Len = byte_size(Head) + 2 + byte_size(Tail),
    Right = case Len =< 16#ffff of
                true -> bnot erx_bytes:inet_csum(erx_bytes:inet_csum(0, pseudo_header(Family, Len)), [Head, Tail]) band 16#ffff;
                false -> 0
            end,
    Sum = case rand:uniform(10) of
              1 -> Right bxor rand:uniform(16#ffff);
              _ -> Right
          end,
    <<Head/binary, Sum:16, Tail/binary>>.

mutate(Bytes) ->
    case rand:uniform(20) of
        1 -> binary:part(Bytes, 0, rand:uniform(byte_size(Bytes)) - 1);
        2 ->
            At = rand:uniform(byte_size(Bytes)) - 1,
            <<Before:At/binary, Byte, After/binary>> = Bytes,
            <<Before/binary, (Byte bxor rand:uniform(255)), After/binary>>;
        _ -> Bytes
    end.

oneof(List) -> lists:nth(rand:uniform(length(List)), List).

bytes(N) -> rand:bytes(N).
