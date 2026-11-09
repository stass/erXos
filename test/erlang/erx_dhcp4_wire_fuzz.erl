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
in an option cut short; sometimes the message is cut inside its fixed header. The `file`
and `sname` fields hold options of their own, which count only when an overload option
(52) names them, and classless routes (121) have prefix lengths up to 255. It checks
that the decoder never raises; that it accepts exactly what `judge/1` accepts, which
decides from the description alone with its own reading of RFC 2131, RFC 2132, RFC 3442
and `dhclient`'s name checks; that encoding an accepted message and decoding it again
gives it back; and that the client core, given the message as a reply to its outstanding
transaction in each phase that takes replies, never raises and configures only from an
ACK, only its address, with routes, an MTU and a search list within the bounds a hostile
server must not pass. `run/1` prints `fuzz: N rounds ok, M accepted`, or the first
failure's tag and halts with status 1.
""".

-include("erx_dhcp4_wire.hrl").

-export([judge/1, run/1]).

-define(ROUNDS, 20000).
-define(MAC, <<2, 0, 0, 0, 0, 1>>).
-define(ADDR, <<10, 0, 2, 15>>).
-define(SERVER, <<10, 0, 2, 2>>).
-define(DEVICE_MTU, 1500).
-define(KNOWN, [53, 1, 121, 3, 6, 15, 26, 50, 51, 54, 55, 58, 59, 61]).
-define(NAMES, [message_type, subnet_mask, classless_routes, routers, dns, domain_name, mtu,
                requested_ip, lease_time, server_id, params, t1, t2, client_id]).
-define(TYPES, [discover, offer, request, decline, ack, nak, release, inform]).
%% A bad value of these refuses the message; of any other known option, drops the option.
-define(STRICT, [53, 1, 121, 51, 54]).
-define(FILE_BYTES, 128).
-define(SNAME_BYTES, 64).

%% A message as the generator describes it; `file` and `sname` are each {Options, Tail},
%% the options that fit the field and how the field ends.
-record(desc, {op, hlen, cookie_ok, cut, options, tail, file, sname}).

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

%% The client in selecting, requesting, renewing and rebinding (past T2 of the 600 s
%% lease asked at 1), each with its outstanding xid.
cores() ->
    Offer = fun(Type, Xid, Options) ->
                    #dhcp4{op = reply, xid = Xid, yiaddr = ?ADDR, chaddr = ?MAC,
                           options = Options#{message_type => Type, server_id => ?SERVER}}
            end,
    New = erx_dhcp4_core:new(?MAC, ?DEVICE_MTU, erx_net_rand:new(<<9:128>>), 0),
    {Selecting, _} = erx_dhcp4_core:step(timeout, New, 0),
    X = erx_dhcp4_core:xid(Selecting),
    {Requesting, _} = erx_dhcp4_core:step({reply, Offer(offer, X, #{})}, Selecting, 1),
    {Bound, _} = erx_dhcp4_core:step({reply, Offer(ack, X, #{lease_time => 600})}, Requesting, 2),
    {Renewing, _} = erx_dhcp4_core:step(timeout, Bound, erx_dhcp4_core:next_deadline(Bound)),
    {Rebinding, _} = erx_dhcp4_core:step(timeout, Renewing, 2 + 525 * 1000),
    [Selecting, Requesting, Renewing, Rebinding].

%% Half the time the message also carries the address and server the cores expect, so its
%% options reach a lease.
drive(Msg0, Core) ->
    Msg1 = Msg0#dhcp4{op = reply, htype = 1, xid = erx_dhcp4_core:xid(Core), chaddr = ?MAC},
    Msg = case rand:uniform(2) of
              1 -> Msg1#dhcp4{yiaddr = ?ADDR, options = (Msg1#dhcp4.options)#{server_id => ?SERVER}};
              2 -> Msg1
          end,
    Actions = try element(2, erx_dhcp4_core:step({reply, Msg}, Core, 1000))
              catch Class:Reason:Stack -> fail(raised, {core, Msg, Class, Reason, Stack})
              end,
    [ok = action(Action, Msg) || Action <- Actions].

action({send, _, <<_:32>>, #dhcp4{op = request}}, _) -> ok;
action(unconfigure, _) -> ok;
action({configure, #{addr := Addr} = Lease}, #dhcp4{yiaddr = Addr, options = #{message_type := ack}}) ->
    case bounded(Lease) of
        true -> ok;
        false -> fail(lease_out_of_bounds, Lease)
    end;
action(Other, Msg) -> fail(core_action, {Other, Msg}).

%% What a hostile server must not get past: an MTU outside 68 to the device's; more than
%% three name servers; more than six search names, or one with any byte but a letter,
%% digit, hyphen or dot; more than 32 routes, two for one prefix, a prefix with bits past
%% its length, a route into 0/8, 127/8 or 224/3 or for the subnet itself, or a gateway
%% that is the client's own address, off the link, or a network or broadcast address of
%% the subnet or of an on-link route.
bounded(#{addr := <<A:32>> = Addr, mask := <<M:32>>, mtu := Mtu, dns := Dns, search := Search,
          routes := Routes}) ->
    Subnet = {A band M, length([1 || <<1:1>> <= <<M:32>>])},
    Links = [Subnet | [{P, L} || #{prefix := <<P:32>>, plen := L, gateway := none} <- Routes]],
    Mtu >= 68 andalso Mtu =< ?DEVICE_MTU andalso length(Dns) =< 3
        andalso length(Search) =< 6
        andalso lists:all(fun(Name) -> re:run(Name, "^[A-Za-z0-9.-]+$") =/= nomatch end, Search)
        andalso length(Routes) =< 32
        andalso length(lists:usort([{P, L} || #{prefix := P, plen := L} <- Routes])) =:= length(Routes)
        andalso lists:all(fun(Route) -> route_bounded(Route, Addr, Subnet, Links) end, Routes).

route_bounded(#{prefix := <<P:32>>, plen := Plen, gateway := Gateway}, Addr, Subnet, Links) ->
    P band (16#ffffffff bsr Plen) =:= 0
        andalso not (Plen >= 8 andalso (P bsr 24 =:= 0 orelse P bsr 24 =:= 127))
        andalso not (Plen >= 3 andalso P bsr 29 =:= 7)
        andalso {P, Plen} =/= Subnet
        andalso (Gateway =:= none orelse (Gateway =/= Addr andalso on_link(Gateway, Links))).

%% Inside some link prefix, and an edge (an all-zero or all-one host part) of none shorter
%% than /31 that holds it.
on_link(<<G:32>>, Links) ->
    Holding = [{P, L} || {P, L} <- Links, G bsr (32 - L) =:= P bsr (32 - L)],
    Edge = fun({_, L}) -> L < 31 andalso lists:member(G band (16#ffffffff bsr L), [0, 16#ffffffff bsr L]) end,
    Holding =/= [] andalso not lists:any(Edge, Holding).

%% The decoded options, written back in the judge's form, are the judge's values.
agree(#dhcp4{options = Options} = Msg, Expected) ->
    Ours = maps:from_list([{code(Name), form(Name, Value)} || {Name, Value} <- maps:to_list(Options)]),
    case Ours =:= Expected of
        true -> ok;
        false -> fail(fields_differ, {Msg, Expected})
    end.

code(Name) ->
    {Code, Name} = lists:keyfind(Name, 2, lists:zip(?KNOWN, ?NAMES)),
    Code.

%% The judge keeps the names of option 15 and the routes of option 121 as it reads them,
%% and every other option as its joined bytes.
form(message_type, Type) ->
    <<(length(lists:takewhile(fun(T) -> T =/= Type end, ?TYPES)) + 1)>>;
form(Name, Addrs) when Name =:= routers; Name =:= dns -> << <<A/binary>> || A <- Addrs >>;
form(mtu, Mtu) -> <<Mtu:16>>;
form(Name, Seconds) when is_integer(Seconds), Name =/= mtu -> <<Seconds:32>>;
form(_, Value) -> Value.

fail(Tag, Detail) -> throw({fail, Tag, Detail}).

%% --- generation ---

desc() ->
    #desc{op = pick([{18, rand:uniform(2)}, {1, 0}, {1, 2 + rand:uniform(253)}]),
          hlen = pick([{18, rand:uniform(17) - 1}, {1, 17}, {1, 16 + rand:uniform(239)}]),
          cookie_ok = rand:uniform(40) > 1,
          cut = pick([{40, none}, {1, rand:uniform(240) - 1}]),
          options = message_type() ++ [option() || _ <- lists:seq(1, rand:uniform(8) - 1)],
          tail = pick([{6, {done, bytes(rand:uniform(6) - 1)}}, {3, open}, {1, cut_short()}]),
          file = field(?FILE_BYTES),
          sname = field(?SNAME_BYTES)}.

%% Most messages lead with a valid message type, as servers send them.
message_type() ->
    pick([{9, [{opt, 53, <<(rand:uniform(8))>>}]}, {1, []}]).

option() ->
    pick([{1, pad},
          {1, {opt, 53, pick([{8, <<(rand:uniform(8))>>}, {1, <<(pick([{1, 0}, {1, 9}]))>>}, {1, <<1, 2>>}])}},
          {12, known_option()},
          {3, {opt, 53, <<5>>}},
          {2, {opt, 52, pick([{6, <<(rand:uniform(3))>>}, {1, <<0>>}, {1, <<4>>}, {1, <<1, 2>>}])}},
          {2, {opt, 1 + rand:uniform(253), bytes(rand:uniform(8) - 1)}}]).

%% A field's options, those that fit with room for an end option or a cut-short option,
%% and how the field ends: an end option and junk, zeros to its end, or an option that runs
%% past it.
field(Size) ->
    Options = fit([O || O <- [option() || _ <- lists:seq(1, rand:uniform(4) - 1)],
                        field_bytes([O]) =< Size - 5], Size - 5),
    {Options, pick([{4, {done, bytes(rand:uniform(4) - 1)}}, {4, open}, {1, cut}])}.

fit(Options, Room) ->
    case field_bytes(Options) =< Room of
        true -> Options;
        false -> fit(lists:droplast(Options), Room)
    end.

field_bytes(Options) -> byte_size(iolist_to_binary([field_instance(O) || O <- Options])).

field_instance(pad) -> <<0>>;
field_instance({opt, Code, Value}) -> <<Code, (byte_size(Value)), Value/binary>>.

%% A known option, its value mostly one its rule accepts and otherwise any edge value.
known_option() ->
    Code = lists:nth(rand:uniform(length(?KNOWN)), ?KNOWN),
    case rand:uniform(8) of
        1 -> {opt, Code, value()};
        _ -> {opt, Code, valid_value(Code)}
    end.

valid_value(53) -> <<(rand:uniform(8))>>;
valid_value(1) -> <<(16#ffffffff bsl (32 - rand:uniform(33) + 1)):32>>;
valid_value(121) -> routes();
valid_value(C) when C =:= 3; C =:= 6 -> bytes(4 * rand:uniform(70));
valid_value(15) -> search_text();
valid_value(26) -> <<(67 + rand:uniform(16#ffff - 67)):16>>;
valid_value(55) -> bytes(rand:uniform(12));
valid_value(61) -> bytes(1 + rand:uniform(12));
valid_value(_) -> bytes(4).

%% One to five classless routes. Prefix lengths are mostly 0 to 32, sometimes 33, the
%% first one the decoder must refuse, or beyond; each is followed by the octets its length
%% needs, with random bits past the length, and a router that is mostly on the subnet,
%% 0.0.0.0 or the client's own address.
routes() ->
    << <<(route())/binary>> || _ <- lists:seq(1, rand:uniform(5)) >>.

route() ->
    Plen = pick([{30, rand:uniform(33) - 1}, {2, 33}, {1, 33 + rand:uniform(222)}]),
    Octets = (Plen + 7) div 8,
    Prefix = pick([{2, bytes(Octets)},
                   {1, binary:part(<<(pick([{1, 0}, {1, 127}, {1, 224}, {1, 10}])), 0, 2, 0,
                                     (bytes(max(0, Octets - 4)))/binary>>, 0, Octets)}]),
    Router = pick([{4, <<10, 0, 2, (rand:uniform(255))>>}, {1, <<0:32>>}, {1, ?ADDR}, {1, bytes(4)}]),
    <<Plen, Prefix/binary, Router/binary>>.

%% A value near the edges of the rules of every known option.
value() ->
    Prefix = rand:uniform(33) - 1,
    pick([{3, <<(16#ffffffff bsl (32 - Prefix)):32>>},
          {2, bytes(4)},
          {1, <<0:16>>}, {1, <<67:16>>}, {1, <<68:16>>}, {1, <<1500:16>>},
          {2, bytes(4 * rand:uniform(70))},
          {1, bytes(rand:uniform(9) - 1)},
          {2, name()},
          {1, <<(name())/binary, 0>>},
          {1, <<(name())/binary, 0, 0>>},
          {1, binary:copy(<<"a">>, 252 + rand:uniform(6))}]).

%% One to seven names separated by blanks, sometimes with one final NUL.
search_text() ->
    Names = [name_only() || _ <- lists:seq(1, pick([{6, 1}, {3, rand:uniform(6)}, {1, 7}]))],
    Text = iolist_to_binary(lists:join(pick([{3, <<" ">>}, {1, <<"\t">>}, {1, <<"  ">>}]), Names)),
    pick([{4, Text}, {1, <<Text/binary, 0>>}]).

name() ->
    Name = name_only(),
    case rand:uniform(10) of
        1 -> <<Name/binary, (pick([{1, 0}, {1, 27}, {1, $_}, {1, 16#c3}, {1, $\s}]))>>;
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

%% The message's bytes: the header with its sname and file fields, the cookie, the options,
%% each long or chosen value split into instances of at most 255 bytes, and the tail.
message_bytes(#desc{op = Op, hlen = Hlen, cookie_ok = CookieOk, cut = Cut, options = Options,
                    tail = Tail, file = File, sname = Sname}) ->
    Cookie = case CookieOk of true -> <<99, 130, 83, 99>>; false -> <<99, 130, 83, 98>> end,
    Yiaddr = pick([{8, <<10, 0, 2, (rand:uniform(254))>>}, {1, <<10, 0, 2, 255>>}, {1, bytes(4)}]),
    Header = <<Op, 1, Hlen, 0, (rand:uniform(1 bsl 32) - 1):32, 0:16, 0:16, 0:32, Yiaddr/binary, 0:64,
               ?MAC/binary, 0:80, (field_bytes(Sname, ?SNAME_BYTES))/binary,
               (field_bytes(File, ?FILE_BYTES))/binary, Cookie/binary>>,
    Body = iolist_to_binary([Header, [instances(O) || O <- Options], tail(Tail)]),
    case Cut of
        none -> Body;
        Length -> binary:part(Body, 0, Length)
    end.

field_bytes({Options, Ending}, Size) ->
    Head = iolist_to_binary([field_instance(O) || O <- Options]),
    Fill = fun(Bytes) -> <<Bytes/binary, 0:((Size - byte_size(Bytes)) * 8)>> end,
    case Ending of
        {done, Junk} -> binary:part(Fill(<<Head/binary, 255, Junk/binary>>), 0, Size);
        open -> Fill(Head);
        cut -> <<(binary:part(Fill(Head), 0, Size - 3))/binary, 6, 4, 10>>
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
`hlen` at most 16, no option cut short before the end option, an overload value, when
there is one, of 1, 2 or 3, no option cut short in a field it names, a DHCP message type,
and every required known option's joined value within its rule. The options of the fields
an overload names join those of the options field, the file field's first. It accepts
with the known options that keep to their rules, by code: the names of option 15, the
routes of option 121 and the joined bytes of every other.
""".
-spec judge(#desc{}) -> {accept, #{0..255 => term()}} | refuse.
judge(#desc{cut = Cut}) when Cut =/= none -> refuse;
judge(#desc{op = Op}) when Op =/= 1, Op =/= 2 -> refuse;
judge(#desc{hlen = Hlen}) when Hlen > 16 -> refuse;
judge(#desc{cookie_ok = false}) -> refuse;
judge(#desc{tail = Tail}) when is_binary(Tail) -> refuse;
judge(#desc{options = Options, file = File, sname = Sname}) ->
    Main = joined(Options, #{}),
    case maps:find(52, Main) of
        error -> sound(Main);
        {ok, <<Fields>>} when Fields >= 1, Fields =< 3 ->
            Named = [F || {Bit, F} <- [{1, File}, {2, Sname}], Fields band Bit =/= 0],
            case lists:any(fun({_, Ending}) -> Ending =:= cut end, Named) of
                true -> refuse;
                false -> sound(lists:foldl(fun({Opts, _}, Acc) -> joined(Opts, Acc) end, Main, Named))
            end;
        {ok, _} -> refuse
    end.

joined(Options, Acc) ->
    lists:foldl(fun({opt, Code, Value}, Seen) ->
                        maps:update_with(Code, fun(Before) -> <<Before/binary, Value/binary>> end, Value, Seen);
                   (pad, Seen) -> Seen
                end, Acc, Options).

sound(Joined) ->
    Known = maps:with(?KNOWN, Joined),
    Sound = maps:filtermap(fun reading/2, Known),
    case is_map_key(53, Sound) andalso lists:all(fun(Code) -> is_map_key(Code, Sound) end,
                                                 [C || C <- ?STRICT, is_map_key(C, Known)]) of
        true -> {accept, Sound};
        false -> refuse
    end.

%% Each known option's value as the judge reads it, or false when it breaks its rule.
reading(53, <<T>>) -> T >= 1 andalso T =< 8;
reading(1, <<_:32>> = Mask) -> mask_bits(Mask);
reading(121, V) when byte_size(V) >= 5 -> routes_reading(V, []);
reading(C, V) when C =:= 3; C =:= 6 -> byte_size(V) > 0 andalso byte_size(V) rem 4 =:= 0;
reading(15, V) -> search_reading(V);
reading(26, <<Mtu:16>>) -> Mtu >= 68;
reading(C, V) when C =:= 50; C =:= 54; C =:= 51; C =:= 58; C =:= 59 -> byte_size(V) =:= 4;
reading(55, V) -> byte_size(V) >= 1;
reading(61, V) -> byte_size(V) >= 2;
reading(_, _) -> false.

%% RFC 3442 read bit by bit: a width, then the whole octets that hold that many bits, of
%% which the bits beyond the width are dropped, then four octets of router.
routes_reading(<<>>, Routes) ->
    {true, lists:reverse(Routes)};
routes_reading(<<Width, Rest/binary>>, Routes) when Width =< 32 ->
    Octets = (Width + 7) div 8,
    case Rest of
        <<Significant:Octets/binary, Router:4/binary, More/binary>> ->
            <<Kept:Width/bitstring, _/bitstring>> = Significant,
            routes_reading(More, [{<<Kept/bitstring, 0:(32 - Width)>>, Width, Router} | Routes]);
        _ ->
            false
    end;
routes_reading(_, _) ->
    false.

%% One final NUL dropped; then at most 256 bytes of one to six blank-separated names, each
%% made of labels that are letters, digits and hyphens, with no hyphen at a label's edge.
search_reading(V) ->
    Text = case binary:last(<<1, V/binary>>) of
               0 -> binary:part(V, 0, byte_size(V) - 1);
               _ -> V
           end,
    Names = [list_to_binary(N) || N <- string:lexemes(binary_to_list(Text), " \t")],
    byte_size(Text) =< 256 andalso Names =/= [] andalso length(Names) =< 6
        andalso lists:all(fun(N) -> re:run(N, "^(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?|\\.)*$") =/= nomatch end, Names)
        andalso {true, Names}.

%% A contiguous mask: its bits, read as text, are ones and then zeros.
mask_bits(Mask) ->
    Bits = [$0 + B || <<B:1>> <= Mask],
    lists:prefix(lists:dropwhile(fun(B) -> B =:= $1 end, Bits), lists:duplicate(32, $0)).
