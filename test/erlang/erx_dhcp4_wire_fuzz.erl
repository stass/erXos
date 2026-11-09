%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dhcp4_wire_fuzz).
-moduledoc """
The fuzz target of erx_dhcp4_wire:decode/1 and of erx_dhcp4_core's handling of what it
accepts (docs/design-network-stack.md, "Codecs: fuzz targets"), run by
tools/fuzz/erx_net_codec.rb. Each round builds a DHCP message from a description: an `op`,
`hlen` and cookie that are mostly right, then a list of options, mostly the known ones with
values near their rules' edges, some split into several instances (RFC 3396), some
unknown, with pad bytes, and ending in an end option with bytes after it, in nothing, or
in an option cut short; sometimes the message is cut inside its fixed header. It checks
that the decoder never raises; that it accepts exactly what `judge/1` accepts, which
decides from the description alone with RFC 2131's and RFC 2132's rules; that encoding an
accepted message and decoding it again gives it back; and that the client core, given the
message as a reply to its outstanding transaction in each phase that takes replies, never
raises and configures only from an ACK, only its address. `run/1` prints `fuzz: N rounds
ok, M accepted`, or the first failure's tag and halts with status 1.
""".

-include("erx_dhcp4_wire.hrl").

-export([judge/1, run/1]).

-define(ROUNDS, 20000).
-define(MAC, <<2, 0, 0, 0, 0, 1>>).
-define(KNOWN, [53, 1, 3, 6, 15, 26, 50, 51, 54, 55, 58, 59, 61]).
-define(NAMES, [message_type, subnet_mask, routers, dns, domain_name, mtu, requested_ip,
                lease_time, server_id, params, t1, t2, client_id]).
-define(TYPES, [discover, offer, request, decline, ack, nak, release, inform]).
%% A bad value of these refuses the message; of any other known option, drops the option.
-define(STRICT, [53, 1, 51, 54]).

%% A message as the generator describes it.
-record(desc, {op, hlen, cookie_ok, cut, options, tail}).

-doc "Runs the target from the seed, the command line's one argument.".
-spec run([string()]) -> ok.
run([Seed]) ->
    _ = rand:seed(exsss, {list_to_integer(Seed), 16#d4, 16#c9}),
    Cores = cores(),
    try
        Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), check(desc(), Cores) =:= accepted]),
        io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Accepted])
    catch
        throw:{fail, Tag, Detail} ->
            io:format("fuzz: ~p ~P~n", [Tag, Detail, 40]),
            halt(1)
    end.

check(Desc, Cores) ->
    Bytes = message_bytes(Desc),
    Result = try erx_dhcp4_wire:decode(Bytes)
             catch Class:Reason:Stack -> fail(raised, {Bytes, Class, Reason, Stack})
             end,
    case {Result, judge(Desc)} of
        {{ok, Msg}, {accept, Expected}} ->
            agree(Msg, Expected),
            round_trip(Msg),
            [drive(Msg, Core) || Core <- Cores],
            accepted;
        {{error, _}, refuse} ->
            refused;
        {_, Judged} ->
            fail(disagrees_with_reference, {Desc, Result, Judged})
    end.

round_trip(Msg) ->
    case erx_dhcp4_wire:decode(erx_dhcp4_wire:encode(Msg)) of
        {ok, Msg} -> ok;
        Other -> fail(round_trip_differs, {Msg, Other})
    end.

%% The client in selecting, requesting and renewing, each with its outstanding xid.
cores() ->
    Server = <<10, 0, 2, 2>>,
    Offer = fun(Type, Xid, Options) ->
                    #dhcp4{op = reply, xid = Xid, yiaddr = <<10, 0, 2, 15>>, chaddr = ?MAC,
                           options = Options#{message_type => Type, server_id => Server}}
            end,
    {Selecting, _} = erx_dhcp4_core:step(timeout, erx_dhcp4_core:new(?MAC, erx_net_rand:new(<<9:128>>), 0), 0),
    X = erx_dhcp4_core:xid(Selecting),
    {Requesting, _} = erx_dhcp4_core:step({reply, Offer(offer, X, #{})}, Selecting, 1),
    {Bound, _} = erx_dhcp4_core:step({reply, Offer(ack, X, #{lease_time => 600})}, Requesting, 2),
    {Renewing, _} = erx_dhcp4_core:step(timeout, Bound, erx_dhcp4_core:next_deadline(Bound)),
    [Selecting, Requesting, Renewing].

drive(Msg0, Core) ->
    Msg = Msg0#dhcp4{op = reply, htype = 1, xid = erx_dhcp4_core:xid(Core), chaddr = ?MAC},
    Actions = try element(2, erx_dhcp4_core:step({reply, Msg}, Core, 1000))
              catch Class:Reason:Stack -> fail(raised, {core, Msg, Class, Reason, Stack})
              end,
    [ok = action(Action, Msg) || Action <- Actions].

action({send, _, <<_:32>>, #dhcp4{op = request}}, _) -> ok;
action(unconfigure, _) -> ok;
action({configure, #{addr := Addr}}, #dhcp4{yiaddr = Addr, options = #{message_type := ack}}) -> ok;
action(Other, Msg) -> fail(core_action, {Other, Msg}).

%% The decoded options, written back as bytes, are the judge's joined values.
agree(#dhcp4{options = Options} = Msg, Expected) ->
    Ours = maps:from_list([{code(Name), raw(Name, Value)} || {Name, Value} <- maps:to_list(Options)]),
    case Ours =:= Expected of
        true -> ok;
        false -> fail(fields_differ, {Msg, Expected})
    end.

code(Name) ->
    {Code, Name} = lists:keyfind(Name, 2, lists:zip(?KNOWN, ?NAMES)),
    Code.

raw(message_type, Type) ->
    <<(length(lists:takewhile(fun(T) -> T =/= Type end, ?TYPES)) + 1)>>;
raw(Name, Addrs) when Name =:= routers; Name =:= dns -> << <<A/binary>> || A <- Addrs >>;
raw(mtu, Mtu) -> <<Mtu:16>>;
raw(Name, Seconds) when is_integer(Seconds), Name =/= mtu -> <<Seconds:32>>;
raw(_, Bytes) -> Bytes.

fail(Tag, Detail) -> throw({fail, Tag, Detail}).

%% --- generation ---

desc() ->
    #desc{op = pick([{18, rand:uniform(2)}, {1, 0}, {1, 2 + rand:uniform(253)}]),
          hlen = pick([{18, rand:uniform(17) - 1}, {1, 17}, {1, 16 + rand:uniform(239)}]),
          cookie_ok = rand:uniform(40) > 1,
          cut = pick([{40, none}, {1, rand:uniform(240) - 1}]),
          options = message_type() ++ [option() || _ <- lists:seq(1, rand:uniform(8) - 1)],
          tail = pick([{6, {done, bytes(rand:uniform(6) - 1)}}, {3, open}, {1, cut_short()}])}.

%% Most messages lead with a valid message type, as servers send them.
message_type() ->
    pick([{9, [{opt, 53, <<(rand:uniform(8))>>}]}, {1, []}]).

option() ->
    pick([{1, pad},
          {1, {opt, 53, pick([{8, <<(rand:uniform(8))>>}, {1, <<(pick([{1, 0}, {1, 9}]))>>}, {1, <<1, 2>>}])}},
          {12, known_option()},
          {3, {opt, 53, <<5>>}},
          {2, {opt, 1 + rand:uniform(253), bytes(rand:uniform(8) - 1)}}]).

%% A known option, its value mostly one its rule accepts and otherwise any edge value.
known_option() ->
    Code = lists:nth(rand:uniform(length(?KNOWN)), ?KNOWN),
    case rand:uniform(8) of
        1 -> {opt, Code, value()};
        _ -> {opt, Code, valid_value(Code)}
    end.

valid_value(53) -> <<(rand:uniform(8))>>;
valid_value(1) -> <<(16#ffffffff bsl (32 - rand:uniform(33) + 1)):32>>;
valid_value(C) when C =:= 3; C =:= 6 -> bytes(4 * rand:uniform(70));
valid_value(15) -> name_only();
valid_value(26) -> <<(67 + rand:uniform(16#ffff - 67)):16>>;
valid_value(55) -> bytes(rand:uniform(12));
valid_value(61) -> bytes(1 + rand:uniform(12));
valid_value(_) -> bytes(4).

%% A value near the edges of the rules of every known option.
value() ->
    Prefix = rand:uniform(33) - 1,
    pick([{3, <<(16#ffffffff bsl (32 - Prefix)):32>>},
          {2, bytes(4)},
          {1, <<0:16>>}, {1, <<67:16>>}, {1, <<68:16>>}, {1, <<1500:16>>},
          {2, bytes(4 * rand:uniform(70))},
          {1, bytes(rand:uniform(9) - 1)},
          {2, name()},
          {1, <<(name())/binary, 0, 0>>},
          {1, binary:copy(<<"a">>, 252 + rand:uniform(3))}]).

name() ->
    Name = name_only(),
    case rand:uniform(10) of
        1 -> <<Name/binary, (pick([{1, 0}, {1, 27}, {1, $_}, {1, 16#c3}]))>>;
        _ -> Name
    end.

name_only() ->
    Chars = <<"abcxyzABZ019-.">>,
    << <<(binary:at(Chars, rand:uniform(byte_size(Chars)) - 1))>> || _ <- lists:seq(1, rand:uniform(20)) >>.

cut_short() ->
    Code = 1 + rand:uniform(253),
    pick([{1, <<Code>>}, {1, <<Code, 5, 1, 2>>}]).

bytes(N) -> rand:bytes(N).

pick(Weighted) ->
    Total = lists:sum([W || {W, _} <- Weighted]),
    pick(rand:uniform(Total), Weighted).

pick(N, [{W, Value} | _]) when N =< W -> Value;
pick(N, [{W, _} | Rest]) -> pick(N - W, Rest).

%% The message's bytes: the header, the cookie, the options, each long or chosen value
%% split into instances of at most 255 bytes, and the tail.
message_bytes(#desc{op = Op, hlen = Hlen, cookie_ok = CookieOk, cut = Cut, options = Options, tail = Tail}) ->
    Cookie = case CookieOk of true -> <<99, 130, 83, 99>>; false -> <<99, 130, 83, 98>> end,
    Yiaddr = pick([{8, <<10, 0, 2, (rand:uniform(254))>>}, {1, <<10, 0, 2, 255>>}, {1, bytes(4)}]),
    Header = <<Op, 1, Hlen, 0, (rand:uniform(1 bsl 32) - 1):32, 0:16, 0:16, 0:32, Yiaddr/binary, 0:64,
               ?MAC/binary, 0:80, 0:(192 * 8), Cookie/binary>>,
    Body = iolist_to_binary([Header, [instances(O) || O <- Options], tail(Tail)]),
    case Cut of
        none -> Body;
        Length -> binary:part(Body, 0, Length)
    end.

instances(pad) -> <<0>>;
instances({opt, Code, Value}) -> [<<Code, (byte_size(V)), V/binary>> || V <- split(Value)].

split(Value) when byte_size(Value) > 255 ->
    At = rand:uniform(255),
    [binary:part(Value, 0, At) | split(binary:part(Value, At, byte_size(Value) - At))];
split(Value) when byte_size(Value) >= 2 ->
    case rand:uniform(5) of
        1 -> At = rand:uniform(byte_size(Value) - 1),
             [binary:part(Value, 0, At), binary:part(Value, At, byte_size(Value) - At)];
        _ -> [Value]
    end;
split(Value) -> [Value].

tail({done, After}) -> <<255, After/binary>>;
tail(open) -> <<>>;
tail(Short) -> Short.

%% --- the reference judge ---

-doc """
The reference judge, from the description: the fixed header and cookie whole, `op` 1 or 2,
`hlen` at most 16, no option cut short before the end option, a DHCP message type, and
every required known option's joined value within RFC 2132's rules for it. It accepts with
the joined values of the known options that keep to their rules, by code.
""".
-spec judge(#desc{}) -> {accept, #{0..255 => binary()}} | refuse.
judge(#desc{cut = Cut}) when Cut =/= none -> refuse;
judge(#desc{op = Op}) when Op =/= 1, Op =/= 2 -> refuse;
judge(#desc{hlen = Hlen}) when Hlen > 16 -> refuse;
judge(#desc{cookie_ok = false}) -> refuse;
judge(#desc{tail = Tail}) when is_binary(Tail) -> refuse;
judge(#desc{options = Options}) ->
    Joined = lists:foldl(fun({opt, Code, Value}, Acc) ->
                                 maps:update_with(Code, fun(Seen) -> <<Seen/binary, Value/binary>> end, Value, Acc);
                            (pad, Acc) -> Acc
                         end, #{}, Options),
    Known = maps:with(?KNOWN, Joined),
    Sound = maps:filter(fun valid/2, Known),
    case is_map_key(53, Sound) andalso lists:all(fun(Code) -> is_map_key(Code, Sound) end,
                                                 [C || C <- ?STRICT, is_map_key(C, Known)]) of
        true -> {accept, maps:map(fun(15, V) -> trim_nuls(V); (_, V) -> V end, Sound)};
        false -> refuse
    end.

trim_nuls(V) -> list_to_binary(string:trim(binary_to_list(V), trailing, [0])).

valid(53, <<T>>) -> T >= 1 andalso T =< 8;
valid(1, <<_:32>> = Mask) -> mask_bits(Mask);
valid(C, V) when C =:= 3; C =:= 6 -> byte_size(V) > 0 andalso byte_size(V) rem 4 =:= 0;
valid(15, V) -> host_name(string:trim(binary_to_list(V), trailing, [0]));
valid(26, <<Mtu:16>>) -> Mtu >= 68;
valid(C, V) when C =:= 50; C =:= 54; C =:= 51; C =:= 58; C =:= 59 -> byte_size(V) =:= 4;
valid(55, V) -> byte_size(V) >= 1;
valid(61, V) -> byte_size(V) >= 2;
valid(_, _) -> false.

%% A contiguous mask: its bits, read as text, are ones and then zeros.
mask_bits(Mask) ->
    Bits = [$0 + B || <<B:1>> <= Mask],
    lists:prefix(lists:dropwhile(fun(B) -> B =:= $1 end, Bits), lists:duplicate(32, $0)).

host_name(Name) ->
    Name =/= [] andalso length(Name) =< 253
        andalso lists:all(fun(C) -> lists:member(C, "abcdefghijklmnopqrstuvwxyz"
                                                    "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.") end, Name).
