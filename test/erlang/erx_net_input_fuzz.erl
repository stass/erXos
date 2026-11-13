%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_input_fuzz).
-moduledoc """
The fuzz target of erx_net_input (docs/design-network-stack.md, "Classification and
framing"), run by tools/fuzz/erx_net_input.rb. Each round builds a frame, Ethernet with
each link cast, a looped packet in one of two zones, or a datagram a reassembly rebuilt
with its zone and link cast, carrying IPv4 (with options, some malformed) or IPv6 (with
hop-by-hop and fragment headers) and TCP, UDP, ICMP and ICMPv6 errors with their quotes
(behind IPv4 options and IPv6 extension headers), echo requests, neighbour messages, ARP
and other protocols, with lengths at the edges; a view of random addresses, groups and DHCP flag, with link-local
addresses in the zones em0 and em1; and a demultiplexing map whose keys come mostly from
the frame's own fields, zoned and unzoned, in its zone and the other. On a DHCP interface
IPv4 frames lean towards UDP to port 68 with malformed options, foreign destinations and
fragments. It checks that:

* `classify/2` and `verify/1` never raise and answer the shapes they declare;
* the verdict, its holders and its reason agree with `judge/3`, written from the design's
  table over pkt's decoding of the link layer, erx_ip4's and erx_ip6's IP decision, and
  the raw bytes the table names, an error's quote included, which it reads itself;
* changing a byte above IP that the table does not name leaves the verdict as it was, and
  changing the checksum above IP turns `verify/1`'s result only into a drop for its sum;
* a burst of one connection's segments merged by `erx_bytes:tcp_merge/1` (IPv4 or IPv6,
  data and pure ACKs, PSH, timestamps, other flags, frames of another connection and
  spoiled payload bytes among them) classifies and verifies unit by unit as the
  interface takes it: every segment `verify/1` accepts, merged or alone, carries the
  connection's own bytes at its sequence number, a merged one takes as many units as it
  holds and acknowledges as its last frame does, a unit no connection holds is classified
  as its last frame, and a unit forged from a real one (a count below its pieces or past
  the merge's limit, a last frame of the other connection, a piece cut short) is dropped
  as `malformed`;
* an Ethernet frame with its network sum, as a summing transport hands it up, classifies
  and verifies exactly as the same frame without one, whose decoders sum it themselves.
  Each Ethernet frame comes with its sum or without one at random, so the other
  properties hold on both paths.

`run/1` prints `fuzz: N rounds ok, M accepted`, or the first failure's tag and halts with
status 1.
""".

-include("erx_ip4_wire.hrl").
-include("erx_ip6.hrl").
-include("erx_tcp_wire.hrl").

-export([judge/3, run/1]).

-define(ROUNDS, 20000).
-define(MINE, <<2, 0, 0, 0, 0, 1>>).
-define(ME4, <<10, 0, 0, 1>>).
-define(ALSO4, <<10, 0, 0, 2>>).
-define(PEER4, <<10, 0, 0, 9>>).
-define(BCAST4, <<10, 0, 0, 255>>).
-define(FOREIGN4, <<192, 0, 2, 7>>).
-define(ME6, <<16#2001:16, 16#db8:16, 0:80, 1:16>>).
-define(PEER6, <<16#2001:16, 16#db8:16, 0:80, 9:16>>).
-define(LL1, <<16#fe80:16, 0:96, 1:16>>).
-define(LL2, <<16#fe80:16, 0:96, 2:16>>).
-define(LLPEER, <<16#fe80:16, 0:96, 9:16>>).
-define(ALLNODES, <<16#ff02:16, 0:96, 1:16>>).
-define(SOLICITED, <<16#ff02:16, 0:72, 1:8, 16#ff:8, 1:24>>).
-define(PORTS, [68, 67, 80, 1234]).

-doc "Runs the target from the seed, the command line's one argument.".
-spec run([string()]) -> ok.
run([Seed]) ->
    _ = rand:seed(exsss, {list_to_integer(Seed), 16#4e, 16#17}),
    try
        Kept = length([ok || _ <- lists:seq(1, ?ROUNDS), round() =/= drop]),
        io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Kept])
    catch
        throw:{fail, Tag, Detail} ->
            io:format("fuzz: ~p ~P~n", [Tag, Detail, 60]),
            halt(1)
    end.

fail(Tag, Detail) -> throw({fail, Tag, Detail}).

%% Form says how the generated packet reaches classify/2: `ether`, a frame from the driver;
%% `{loop, Zone}`, a looped packet with its zone; or `{reassembled, Family, Zone,
%% LinkCast}`, a datagram a reassembly rebuilt, on the Ethernet interface.
round() ->
    case rand:uniform(8) of
        1 -> unit_round();
        _ -> packet_round()
    end.

packet_round() ->
    Kind = pick([ether, ether, ether, ether, ether, loop, loop, reassembled]),
    View0 = view(Kind =:= loop),
    {Ip, Upper, Family} = packet(Kind, View0),
    {Form, Prefix} = form(Kind, Family, Ip),
    Map = demux_map(Ip, Upper, Family, map_zone(Form)),
    View = View0#{demux => fun(Key) -> maps:get(Key, Map, []) end},
    Input = input(Form, Prefix, Upper),
    Verdict = classify(Input, View),
    case {shape(Verdict), judge(Input, View, Map)} of
        {Same, Same} -> ok;
        {Got, Judged} -> fail(disagrees_with_reference, {Input, Got, Judged})
    end,
    Verified = verify(Input, Verdict),
    unnamed_bytes(Form, Prefix, Upper, View, Verdict),
    checksum(Form, Prefix, Upper, View, Verdict, Verified),
    network_sum(Form, Input, View, Verdict, Verified),
    element(1, Verdict).

%% The frame with its network sum and without one give the same verdict and the same item.
network_sum(ether, {frame, Frame, _} = Input, View, Verdict, Verified) ->
    Other = case Input of
                {frame, _, none} -> {frame, Frame, net_sum(Frame)};
                _ -> {frame, Frame, none}
            end,
    Again = classify(Other, View),
    case {shape(Again) =:= shape(Verdict), verify(Other, Again)} of
        {true, Verified} -> ok;
        {_, Got} -> fail(network_sum_differs, {Input, Verified, Got})
    end;
network_sum(_, _, _, _, _) ->
    ok.

%% The sum a summing transport hands up: of the bytes after the link header.
net_sum(Frame) when byte_size(Frame) >= 14 -> erx_bytes:inet_csum(0, binary:part(Frame, 14, byte_size(Frame) - 14));
net_sum(_) -> none.

classify(Input, View) ->
    try erx_net_input:classify(Input, View)
    catch Class:Reason:Stack -> fail(raised, {Input, Class, Reason, Stack})
    end.

verify(_, {drop, _}) -> {drop_verdict, none};
verify(Input, Verdict) ->
    Pending = element(tuple_size(Verdict), Verdict),
    try erx_net_input:verify(Pending) of
        {ok, _} = Ok -> Ok;
        {drop, Reason} = Drop when is_atom(Reason) -> Drop;
        Other -> fail(bad_verify_shape, {Input, Other})
    catch Class:Reason:Stack -> fail(raised, {Input, Class, Reason, Stack})
    end.

%% The verdict as the judge states it: the holders' credits and the pending kind, the
%% local kind (with a segment's listener), or the drop reason.
shape({owned, [_ | _] = Holders, Pending}) -> {owned, lists:sort([C || {_, C} <- Holders]), kind(Pending)};
shape({local, Pending}) -> local_shape(inner(Pending));
shape({drop, Reason}) -> {drop, Reason};
shape(Other) -> fail(bad_verdict_shape, Other).

local_shape({tcp, _, _, Listener}) -> {local, tcp, listener_id(Listener)};
local_shape(Pending) -> {local, element(1, Pending)}.

%% A pending datagram above IP comes with the sum of its bytes above IP.
inner({above, _, Above}) -> Above;
inner(Pending) -> Pending.

kind(Pending) -> element(1, inner(Pending)).

listener_id(none) -> none;
listener_id(#{credit := Credit}) -> Credit.

input(ether, Prefix, Upper) ->
    Frame = <<Prefix/binary, Upper/binary>>,
    {frame, Frame, pick([none, net_sum(Frame)])};
input({loop, Zone}, Prefix, Upper) -> {looped, Zone, <<Prefix/binary, Upper/binary>>};
input({reassembled, Family, Zone, LinkCast}, Prefix, Upper) ->
    {reassembled, Family, Zone, LinkCast, <<Prefix/binary, Upper/binary>>}.

%% ---------------------------------------------------------------------------------------
%% The reference judge, from the table of "Classifying a frame" alone.

-doc "The verdict the design's table gives Input on an interface with View and Map.".
-spec judge(erx_net_input:input(), erx_net_input:view(), map()) -> tuple().
judge({looped, Zone, Packet}, #{link := none} = View, Map) ->
    case Packet of
        <<6:4, _/bits>> -> ip6(Packet, received, unicast, Zone, View, Map);
        _ -> ip4(Packet, unicast, View, Map)
    end;
%% A rebuilt datagram goes to the IP layer with its first fragment's zone and link cast,
%% and never to the DHCP path, which takes only whole packets.
judge({reassembled, inet, none, Cast, Packet}, View, Map) ->
    ip4(Packet, Cast, View, Map);
judge({reassembled, inet6, Zone, Cast, Packet}, View, Map) ->
    ip6(Packet, reassembled, Cast, Zone, View, Map);
judge({frame, Bytes, _}, #{lladdr := Mine, ip6 := #{zone := Zone}} = View, Map) ->
    case erx_net_pkt_oracle:ether(Bytes) of
        {ok, #{dst := Dst, type := Type}, Payload} when byte_size(Bytes) >= 14 ->
            Group = binary:first(Dst) band 1 =:= 1,
            Cast = if Dst =:= Mine -> unicast;
                      Dst =:= <<255, 255, 255, 255, 255, 255>> -> broadcast;
                      Group -> multicast;
                      true -> other_host
                   end,
            case {Cast, Type} of
                {other_host, _} -> {drop, other_host};
                {_, 16#0800} -> dhcp_first(Payload, Cast, View, Map);
                {_, 16#86dd} -> ip6(Payload, received, Cast, Zone, View, Map);
                {_, 16#0806} -> {local, arp};
                _ -> {drop, ethertype}
            end;
        _ -> {drop, element(2, erx_net_eth:decode(Bytes))}
    end.

dhcp_first(Packet, Cast, #{dhcp := true} = View, Map) ->
    case erx_ip4_wire:decode(Packet) of
        {ok, #ip4{p = 17, mf = 0, off = 0}, <<_:16, 68:16, _:32, _/binary>>} ->
            {local, dhcp};
        _ -> ip4(Packet, Cast, View, Map)
    end;
dhcp_first(Packet, Cast, View, Map) ->
    ip4(Packet, Cast, View, Map).

ip4(Packet, Cast, #{ip4 := Ip4View, groups := Groups}, Map) ->
    case erx_ip4:input(Packet, Cast, Ip4View) of
        {ours, multicast, _, Ip, _} -> group(Groups, Ip#ip4.dst);
        {ours, IpCast, Reply, Ip, Upper} ->
            above(inet, Ip#ip4.p, Upper,
                  #{src => Ip#ip4.src, dst => Ip#ip4.dst, link => Cast,
                    cast => IpCast, reply => Reply, zone => none}, Map);
        {fragment, _, _} -> {local, fragment};
        {param_problem, _} -> {local, param_problem};
        {drop, Reason} -> {drop, Reason}
    end.

ip6(Packet, Origin, Cast, Zone, #{ip6 := Ip6View, groups := Groups}, Map) ->
    case erx_ip6:input(Packet, Origin, Cast, Ip6View#{zone := Zone}) of
        {ours, multicast, _, Ip, Upper} ->
            case lists:member(Ip#ip6.dst, Groups) of
                true -> above6(Ip, Upper, Cast, multicast, false, Zone, Map);
                false -> {drop, not_member}
            end;
        {ours, IpCast, Reply, Ip, Upper} -> above6(Ip, Upper, Cast, IpCast, Reply, Zone, Map);
        {fragment, _, _} -> {local, fragment};
        {param_problem, _, _} -> {local, param_problem};
        {drop, Reason} -> {drop, Reason}
    end.

%% No IPv4 group is in the generated views, so every IPv4 multicast is not_member.
group(Groups, Dst) ->
    case lists:member(Dst, Groups) of
        true -> fail(unexpected_ipv4_group, Dst);
        false -> {drop, not_member}
    end.

above6(Ip, Upper, Link, Cast, Reply, Zone, Map) ->
    above(inet6, Ip#ip6.proto, Upper,
          #{src => zoned(Ip#ip6.src, Zone), dst => zoned(Ip#ip6.dst, Zone),
            link => Link, cast => Cast, reply => Reply, zone => Zone}, Map).

above(F, 6, <<Sp:16, Dp:16, _/binary>>, #{src := S, dst := D, link := Link, cast := Cast} = H, Map) ->
    case {get({tcp, F, D, Dp, S, Sp}, Map), listen(F, D, Dp, Map)} of
        {[_ | _] = E, _} -> {owned, ids(E), conn};
        {[], {ok, Id}} when Link =:= unicast, Cast =:= unicast -> {local, tcp, Id};
        {[], {ok, _}} -> {drop, bcast_tcp};
        {[], none} -> reply(H, {local, tcp, none})
    end;
above(F, 17, <<Sp:16, Dp:16, _/binary>>, #{src := S, dst := D, cast := Cast} = H, Map) ->
    All = get({udp, F, D, Dp, S, Sp}, Map) ++ get({udp, F, D, Dp}, Map) ++ get({udp, F, any, Dp}, Map),
    case {All, Cast} of
        {[First | _], unicast} -> {owned, ids([First]), datagram};
        {[_ | _], _} -> {owned, ids(All), datagram};
        {[], _} -> reply(H, {local, udp}, no_port)
    end;
above(_, P, _, _, _) when P =:= 6; P =:= 17 -> {drop, too_short};
above(inet, 1, <<T, _/binary>> = U, H, Map) when T =:= 3; T =:= 11; T =:= 12 ->
    quote_verdict(inet, read_quote(inet, after8(U)), H, Map);
above(inet, 1, <<T, _/binary>>, H, _) when T =:= 8; T =:= 13 -> reply(H, {local, icmp});
above(inet, 1, <<5, _/binary>>, _, _) -> {local, icmp};
above(inet, 1, <<0, _, _:16, Id:16, _:16, _/binary>>, _, Map) ->
    case get({icmp_echo, inet, Id}, Map) of
        [] -> {drop, no_socket};
        E -> {owned, ids(E), echo}
    end;
above(inet, 1, <<0, _/binary>>, _, _) -> {drop, too_short};
above(inet6, 58, <<T, _/binary>> = U, H, Map) when T >= 1, T =< 4 ->
    quote_verdict(inet6, read_quote(inet6, after8(U)), H, Map);
above(inet6, 58, <<128, _/binary>>, H, _) -> reply(H, {local, icmp});
above(inet6, 58, <<T, _/binary>>, _, _) when T =:= 130; T >= 133, T =< 137 -> {local, icmp};
above(inet, 1, <<_, _/binary>>, _, _) -> {drop, icmp_type};
above(inet6, 58, <<_, _/binary>>, _, _) -> {drop, icmp_type};
above(inet, 1, <<>>, _, _) -> {drop, too_short};
above(inet6, 58, <<>>, _, _) -> {drop, too_short};
above(inet6, 59, _, _, _) -> {drop, no_next_header};
above(_, _, _, H, _) -> reply(H, {local, other}).

quote_verdict(F, {ok, P, QS, QSp, QD, QDp}, #{zone := Z}, Map) ->
    L = zoned(QS, Z),
    R = zoned(QD, Z),
    case P of
        6 ->
            case {get({tcp, F, L, QSp, R, QDp}, Map), listen(F, L, QSp, Map)} of
                {[_ | _] = E, _} -> {owned, ids(E), report};
                {[], {ok, _}} -> {local, icmp};
                {[], none} -> {drop, no_socket}
            end;
        17 ->
            case get({udp, F, L, QSp, R, QDp}, Map) of
                [_ | _] = E -> {owned, ids(E), report};
                [] -> {drop, no_socket}
            end;
        _ -> {drop, no_socket}
    end;
quote_verdict(_, {error, Reason}, _, _) -> {drop, Reason}.

%% The quoted datagram, read here from the RFCs rather than by erx_icmp4's and erx_icmp6's
%% decode_quoted/1, so that a quote read at the wrong offset disagrees: its protocol, its
%% source and ports (the local end, since the stack sent it) and its destination and port.
%% IPv4 (RFC 792, icmp_input): a header of Hl words, at least 5, with the 8 bytes after it,
%% a destination that is not multicast and neither address 0.0.0.0. IPv6 (RFC 4443 and RFC
%% 8200, icmp6_notify_error): past hop-by-hop, routing and destination options headers
%% ((Len + 1) * 8 bytes), an authentication header ((Len + 2) * 4 bytes) and a fragment
%% header of offset zero, to the first other header or a fragment header of nonzero
%% offset, with 8 bytes of it inside the quote, and neither address unspecified. A quote
%% too short for its headers is bad_length, checked before the addresses.
read_quote(inet, <<_:4, Hl:4, _:8/binary, P, _:16, S:4/binary, D:4/binary, _/binary>> = Q) when Hl >= 5 ->
    case Q of
        <<_:Hl/unit:32, Sp:16, Dp:16, _:32, _/binary>> ->
            Multicast = binary:first(D) bsr 4 =:= 2#1110,
            case Multicast orelse S =:= <<0:32>> orelse D =:= <<0:32>> of
                true -> {error, bad_addr};
                false -> {ok, P, S, Sp, D, Dp}
            end;
        _ -> {error, bad_length}
    end;
read_quote(inet6, <<_:48, Nxt, _, S:16/binary, D:16/binary, _/binary>> = Q) ->
    case upper6(Nxt, 40, Q) of
        {P, Off} when byte_size(Q) >= Off + 8 ->
            <<_:Off/binary, Sp:16, Dp:16, _/binary>> = Q,
            case S =:= <<0:128>> orelse D =:= <<0:128>> of
                true -> {error, bad_addr};
                false -> {ok, P, S, Sp, D, Dp}
            end;
        _ -> {error, bad_length}
    end;
read_quote(_, _) ->
    {error, bad_length}.

%% The upper-layer header's protocol and offset, or `overrun` for a header past the quote.
upper6(Nxt, Off, Q) when Nxt =:= 0; Nxt =:= 43; Nxt =:= 60 ->
    case Q of
        <<_:Off/binary, Next, Len, _/binary>> -> upper6(Next, Off + (Len + 1) * 8, Q);
        _ -> overrun
    end;
upper6(51, Off, Q) ->
    case Q of
        <<_:Off/binary, Next, Len, _/binary>> -> upper6(Next, Off + (Len + 2) * 4, Q);
        _ -> overrun
    end;
upper6(44, Off, Q) ->
    case Q of
        <<_:Off/binary, _, _, 0:13, _:3, _:32, _/binary>> -> upper6(binary:at(Q, Off), Off + 8, Q);
        <<_:Off/binary, _, _, _:13, _:3, _:32, _/binary>> -> {44, Off};
        _ -> overrun
    end;
upper6(Nxt, Off, _) ->
    {Nxt, Off}.

reply(H, Local) -> reply(H, Local, no_reply).
reply(#{reply := true}, Local, _) -> Local;
reply(_, _, Reason) -> {drop, Reason}.

listen(F, A, P, Map) ->
    case get({tcp_listen, F, A, P}, Map) ++ get({tcp_listen, F, any, P}, Map) of
        [#{credit := Id} | _] -> {ok, Id};
        [] -> none
    end.

get(Key, Map) -> maps:get(Key, Map, []).
ids(Entries) -> lists:sort([C || #{credit := C} <- Entries]).
after8(<<_:8/binary, Rest/binary>>) -> Rest;
after8(_) -> <<>>.

zoned(<<16#fe80:16, _:112>> = A, Z) when Z =/= none -> {A, Z};
zoned(<<1:128>> = A, Z) when Z =/= none -> {A, Z};
zoned(<<16#ff, _:4, S:4, _:112>> = A, Z) when Z =/= none, (S =:= 1 orelse S =:= 2) -> {A, Z};
zoned(A, _) -> A.

%% ---------------------------------------------------------------------------------------
%% The two byte properties.

%% Bytes above IP the table does not name: past the ports of TCP and UDP, the code,
%% checksum and second word of an ICMP or ICMPv6 message (but an echo reply's identifier),
%% and every byte of any other.
unnamed_bytes(_, _, _, _, {drop, too_short}) -> ok;
unnamed_bytes(Form, Prefix, Upper, View, Verdict) ->
    case unnamed(Prefix, Upper, Form) of
        [] -> ok;
        Offsets ->
            Off = pick(Offsets),
            Mutated = flip(Upper, Off, rand:uniform(255)),
            Input = input(Form, Prefix, Mutated),
            case shape(classify(Input, View)) =:= shape(Verdict) of
                true -> ok;
                false -> fail(verdict_read_unnamed_byte, {Off, input(Form, Prefix, Upper), Input})
            end
    end.

unnamed(Prefix, Upper, Form) ->
    case proto(Prefix, Form) of
        P when P =:= 6; P =:= 17 -> [I || I <- offsets(Upper), I >= 4];
        P when P =:= 1; P =:= 58 -> [I || I <- offsets(Upper), I >= 1, I =< 7, not echo_ident(P, Upper, I)];
        _ -> []
    end.

%% An ICMP echo reply's identifier, which names its socket.
echo_ident(1, <<0, _/binary>>, I) -> I =:= 4 orelse I =:= 5;
echo_ident(_, _, _) -> false.

%% A flipped checksum keeps verify/1's drop or makes its success a drop for the sum.
checksum(Form, Prefix, Upper, View, Verdict, Original) when element(2, Original) =/= none ->
    case summed_kind(Verdict) andalso sum_offset(proto(Prefix, Form), Upper) of
        false -> ok;
        none -> ok;
        Off ->
            <<_:Off/binary, Sum:16, _/binary>> = Upper,
            New = Sum bxor rand:uniform(16#ffff),
            Mutated = <<(binary:part(Upper, 0, Off))/binary, New:16,
                        (binary:part(Upper, Off + 2, byte_size(Upper) - Off - 2))/binary>>,
            Input = input(Form, Prefix, Mutated),
            Again = classify(Input, View),
            Skip = New =:= 0 orelse New =:= 16#ffff orelse Sum =:= 0 orelse Original =:= {drop, bad_sum},
            case {Skip, shape(Again) =:= shape(Verdict), verify(Input, Again), Original} of
                {true, _, _, _} -> ok;
                {_, false, _, _} -> fail(verdict_read_checksum, Input);
                {_, _, {drop, bad_sum}, _} -> ok;
                {_, _, Same, {drop, _} = Same} -> ok;
                {_, _, Got, _} -> fail(checksum_not_checked, {Input, Got, Original})
            end
    end;
checksum(_, _, _, _, _, _) ->
    ok.

%% The pending kinds whose verify/1 checks a sum above IP.
summed_kind(Verdict) ->
    lists:member(kind(element(tuple_size(Verdict), Verdict)),
                 [conn, tcp, datagram, udp, dhcp, report, echo, icmp]).

sum_offset(6, Upper) when byte_size(Upper) >= 18 -> 16;
sum_offset(17, Upper) when byte_size(Upper) >= 8 -> 6;
sum_offset(P, Upper) when (P =:= 1 orelse P =:= 58), byte_size(Upper) >= 4 -> 2;
sum_offset(_, _) -> none.

%% The protocol of the generated packet's upper layer, as packet/1 recorded it in the
%% prefix's last byte position: the IPv4 protocol field, or the last next-header.
proto(Prefix, Form) ->
    Ip = ip_header(Prefix, Form),
    case Ip of
        <<4:4, _:68, P, _/binary>> -> P;
        <<6:4, _:44, Nxt, _/binary>> -> last_next(Nxt, binary:part(Ip, 40, byte_size(Ip) - 40));
        _ -> none
    end.

ip_header(<<_:14/binary, Ip/binary>>, ether) -> Ip;
ip_header(Prefix, _) -> Prefix.

last_next(0, <<Nxt, Len, _/binary>> = Ext) when byte_size(Ext) >= 8 * Len + 8 ->
    last_next(Nxt, binary:part(Ext, 8 * Len + 8, byte_size(Ext) - 8 * Len - 8));
last_next(44, <<Nxt, _:7/binary, Rest/binary>>) -> last_next(Nxt, Rest);
last_next(Nxt, _) -> Nxt.

offsets(Bin) -> lists:seq(0, byte_size(Bin) - 1).

flip(Bin, Off, Mask) ->
    <<Head:Off/binary, Byte, Tail/binary>> = Bin,
    <<Head/binary, (Byte bxor Mask), Tail/binary>>.

%% ---------------------------------------------------------------------------------------
%% Generation

view(Loop) ->
    Link = case Loop of true -> none; false -> ethernet end,
    %% The loopback interface is lo0; a looped packet carries its own zone, often another.
    #{link => Link,
      lladdr => case Loop of true -> none; false -> ?MINE end,
      ip4 => #{addrs => subset([?ME4, ?ALSO4]), broadcasts => [?BCAST4], loopback => Loop},
      ip6 => #{addrs => subset([?ME6, {?LL1, em0}, {?LL2, em1}, {?LL1, em1}, {<<1:128>>, lo0}]),
               notready => subset([{?LLPEER, em1}]), loopback => Loop, zone => case Loop of true -> lo0; false -> em0 end},
      groups => subset([?ALLNODES, ?SOLICITED]),
      dhcp => (not Loop) andalso rand:uniform(2) =:= 1}.

%% {Ip, Upper, Family}: the IP header, and the bytes above IP. A rebuilt datagram is IP.
packet(Kind, #{dhcp := Dhcp}) ->
    Payload = case Kind of
        reassembled -> pick([ip4, ip6]);
        _ -> pick([ip4, ip4, ip6, ip6, arp, junk])
    end,
    case Payload of
        ip4 when Dhcp -> ip4_packet(pick([dhcp, dhcp, any]));
        ip4 -> ip4_packet(any);
        ip6 -> ip6_packet();
        arp -> {<<>>, rand:bytes(pick([27, 28, 40])), arp};
        junk -> {<<>>, rand:bytes(rand:uniform(30) - 1), junk}
    end.

%% {Form, Prefix}: how the packet arrives, and what comes before its upper layer: the
%% Ethernet header and the IP header, or the IP header alone.
form(ether, Family, Ip) ->
    Type = case Family of inet -> 16#0800; inet6 -> 16#86dd; arp -> 16#0806; junk -> pick([16#0800, 16#88b5]) end,
    Dst = pick([?MINE, ?MINE, <<255, 255, 255, 255, 255, 255>>, <<1, 0, 16#5e, 0, 0, 1>>,
                <<16#33, 16#33, 0, 0, 0, 1>>, <<2, 0, 0, 0, 0, 7>>]),
    {ether, <<Dst/binary, 2, 0, 0, 0, 0, 9, Type:16, Ip/binary>>};
form(loop, _, Ip) ->
    {{loop, pick([em0, em1, lo0])}, Ip};
form(reassembled, Family, Ip) ->
    Zone = case Family of inet -> none; inet6 -> pick([em0, em0, em1]) end,
    {{reassembled, Family, Zone, pick([unicast, unicast, broadcast, multicast])}, Ip}.

%% The zone the demultiplexing keys are built around: the packet's, or the interface's for
%% IPv4, whose addresses have none.
map_zone(ether) -> em0;
map_zone({loop, Zone}) -> Zone;
map_zone({reassembled, _, none, _}) -> em0;
map_zone({reassembled, _, Zone, _}) -> Zone.

ip4_packet(Bias) ->
    Src = pick([?PEER4, ?PEER4, ?ME4, <<0:32>>, <<127, 0, 0, 1>>, <<224, 0, 0, 5>>]),
    Dst = pick([?ME4, ?ME4, ?ALSO4, ?BCAST4, <<255, 255, 255, 255>>, <<224, 0, 0, 1>>, ?FOREIGN4]),
    Proto = case Bias of dhcp -> 17; any -> pick([6, 6, 17, 17, 1, 1, 47]) end,
    Options = pick([<<>>, <<>>, <<1, 1, 1, 1>>, <<7, 2, 0, 0>>, <<7, 40, 4, 0>>]),
    {Mf, Off} = pick([{0, 0}, {0, 0}, {0, 0}, {1, 0}, {0, 3}]),
    Upper = upper(inet, Proto, Src, Dst, Bias),
    Hl = 5 + byte_size(Options) div 4,
    Len = Hl * 4 + byte_size(Upper),
    Header0 = <<4:4, Hl:4, 0, Len:16, 7:16, 0:1, 0:1, Mf:1, Off:13, 64, Proto, 0:16, Src/binary,
                Dst/binary, Options/binary>>,
    Sum = bnot erx_bytes:inet_csum(0, Header0) band 16#ffff,
    <<Before:10/binary, _:16, After/binary>> = Header0,
    {<<Before/binary, Sum:16, After/binary>>, Upper, inet}.

ip6_packet() ->
    Src = pick([?PEER6, ?LLPEER, ?LL1, ?LL2, <<0:128>>, <<1:128>>]),
    Dst = pick([?ME6, ?LL1, ?LL2, ?LLPEER, ?ALLNODES, ?SOLICITED, <<1:128>>, ?PEER6]),
    Proto = pick([6, 6, 17, 17, 58, 58, 58, 59, 47]),
    Upper = upper(inet6, Proto, Src, Dst, any),
    {Ext, First} = case rand:uniform(6) of
        1 -> {<<Proto, 0, 1, 4, 0:32>>, 0};
        2 -> {<<Proto, 0, 0:16, 9:32>>, 44};
        3 -> {<<Proto, 0, 8:13, 0:2, 1:1, 9:32>>, 44};
        _ -> {<<>>, Proto}
    end,
    Plen = byte_size(Ext) + byte_size(Upper),
    {<<6:4, 0:8, 0:20, Plen:16, First, 64, Src/binary, Dst/binary, Ext/binary>>, Upper, inet6}.

%% A segment's flags are random but for RST, which stays clear: the table names no flag, so
%% setting one is the unnamed-byte property's flip, which a classifier that reads RST fails.
upper(Family, 6, Src, Dst, _) ->
    Segment = <<(port()):16, (port()):16, (rand:uniform(1 bsl 32) - 1):32, 0:32, 5:4, 0:3,
                ((rand:uniform(512) - 1) band bnot 16#04):9, 1024:16, 0:16, 0:16, (rand:bytes(pick([0, 3])))/binary>>,
    cut(summed(Family, 6, Src, Dst, Segment, 16));
upper(Family, 17, Src, Dst, Bias) ->
    Data = rand:bytes(pick([0, 1, 12])),
    Dport = case Bias of dhcp -> 68; any -> port() end,
    Datagram = <<(port()):16, Dport:16, (8 + byte_size(Data)):16, 0:16, Data/binary>>,
    cut(summed(Family, 17, Src, Dst, Datagram, 6));
upper(inet, 1, Src, Dst, _) ->
    Type = pick([3, 3, 11, 12, 8, 13, 5, 0, 42]),
    Message = <<Type, 0, 0:16, 0:32, (quoted_datagram(inet, Src, Dst))/binary>>,
    cut(summed(inet, 1, Src, Dst, Message, 2));
upper(inet6, 58, Src, Dst, _) ->
    Type = pick([1, 1, 2, 3, 4, 128, 129, 130, 131, 133, 135, 136, 137, 200]),
    Message = <<Type, 0, 0:16, 0:32, (quoted_datagram(inet6, Src, Dst))/binary>>,
    cut(summed(inet6, 58, Src, Dst, Message, 2));
upper(_, _, _, _, _) ->
    rand:bytes(pick([0, 4, 20])).

%% The datagram an error quotes, sent by the stack: from one of its addresses (the
%% error's destination, mostly) to a peer, with 8 bytes of TCP or UDP header after IPv4
%% options or IPv6 extension headers, so that the ports sit at several offsets; some
%% quotes end one byte short of them, or have an extension header that overruns.
quoted_datagram(inet, _Src, Dst) ->
    P = pick([6, 17, 47]),
    Options = pick([<<>>, <<>>, <<1, 1, 1, 1>>, <<1, 1, 1, 1, 1, 1, 1, 0>>]),
    Hl = 5 + byte_size(Options) div 4,
    Header = <<4:4, Hl:4, 0, 48:16, 0:32, 64, P, 0:16, (pick([Dst, ?ME4, ?PEER4, <<0:32>>]))/binary,
               (pick([?PEER4, ?PEER4, <<0:32>>, <<224, 0, 0, 1>>]))/binary, Options/binary>>,
    short(<<Header/binary, (port()):16, (port()):16, 0:32, (rand:bytes(pick([0, 12])))/binary>>, Hl * 4 + 7);
quoted_datagram(inet6, _Src, Dst) ->
    P = pick([6, 17, 47]),
    {First, Ext} = pick([{P, <<>>}, {P, <<>>},
                         {0, <<P, 0, 1, 4, 0:32>>},
                         {60, <<P, 1, 1, 12, 0:96>>},
                         {44, <<P, 0, 0:16, 9:32>>},
                         {44, <<P, 0, 8:13, 0:3, 9:32>>},
                         {43, <<P, 0, 4, 0, 0:32>>},
                         {51, <<P, 1, 0:16, 9:32, 1:32>>},
                         {0, <<P, 4, 1, 4, 0:32>>}]),
    Header = <<6:4, 0:28, 16:16, First, 64, (pick([Dst, ?LL1, ?ME6, <<0:128>>]))/binary,
               (pick([?PEER6, ?LLPEER]))/binary, Ext/binary>>,
    short(<<Header/binary, (port()):16, (port()):16, 0:32>>, byte_size(Header) + 7).

%% The quote whole, or now and then cut to Short bytes.
short(Quote, Short) ->
    case rand:uniform(8) of
        1 -> binary:part(Quote, 0, Short);
        _ -> Quote
    end.

%% The message with its checksum at Off, mostly right.
summed(Family, Proto, Src, Dst, Message, Off) ->
    Pseudo = case {Family, Proto} of
        {inet, 1} -> 0;
        {inet, _} -> erx_ip4_wire:pseudo_sum(Src, Dst, byte_size(Message), Proto);
        {inet6, _} -> erx_ip6_wire:pseudo_sum(Src, Dst, byte_size(Message), Proto)
    end,
    Sum = case rand:uniform(8) of
        1 -> rand:uniform(16#ffff);
        _ -> bnot erx_bytes:inet_csum(Pseudo, Message) band 16#ffff
    end,
    <<Head:Off/binary, _:16, Tail/binary>> = Message,
    <<Head/binary, Sum:16, Tail/binary>>.

%% Lengths at the edges: mostly whole, else cut to a few bytes.
cut(Bin) ->
    case rand:uniform(8) of
        1 -> binary:part(Bin, 0, min(byte_size(Bin), pick([0, 1, 3, 4, 7, 19])));
        _ -> Bin
    end.

port() -> pick(?PORTS ++ [rand:uniform(16#ffff)]).

%% Keys from the frame's own fields, in its zone and the other, some unzoned, and from
%% a quote's, with listeners and bound sockets on the destination port.
demux_map(Ip, Upper, Family, Zone) ->
    {Src, Dst} = addresses(Ip, Family),
    {Ports, Quoted} = case Upper of
        <<Sp:16, Dp:16, _/binary>> -> {[{Dp, Sp}], quoted_ports(Family, Upper)};
        _ -> {[{80, 80}], []}
    end,
    Zones = [Zone, other(Zone)],
    Addrs = fun(A) -> lists:usort([zoned(A, Z) || Z <- Zones] ++ [A]) end,
    Candidates =
        [{tcp, Family, L, Lp, R, Rp} || {Lp, Rp} <- Ports, L <- Addrs(Dst), R <- Addrs(Src)] ++
        [{udp, Family, L, Lp, R, Rp} || {Lp, Rp} <- Ports, L <- Addrs(Dst), R <- Addrs(Src)] ++
        [{tcp_listen, Family, L, Lp} || {Lp, _} <- Ports, L <- [any, ?ALSO4 | Addrs(Dst)]] ++
        [{udp, Family, L, Lp} || {Lp, _} <- Ports, L <- [any, ?ALSO4 | Addrs(Dst)]] ++
        [{T, Family, L, Lp, R, Rp} || {QL, Lp, QR, Rp} <- Quoted, T <- [tcp, udp],
                                      L <- Addrs(QL), R <- Addrs(QR)] ++
        [{tcp_listen, Family, L, Lp} || {QL, Lp, _, _} <- Quoted, L <- [any | Addrs(QL)]] ++
        echo_keys(Family, Upper),
    Chosen = [K || K <- Candidates, rand:uniform(4) =:= 1],
    maps:from_list([{K, [entry(K, N)]} || {K, N} <- lists:zip(Chosen, lists:seq(1, length(Chosen)))]).

%% An echo reply's own identifier and its neighbour, so lookups hit and miss.
echo_keys(inet, <<0, _, _:16, Id:16, _/binary>>) ->
    [{icmp_echo, inet, Id}, {icmp_echo, inet, (Id + 1) band 16#ffff}];
echo_keys(_, _) ->
    [].

entry({tcp_listen, _, _, _}, N) -> #{pid => self(), credit => N, listener => #{rcv_buf => 0, mss => 536, rcv_scale => 0}};
entry(_, N) -> #{pid => self(), credit => N}.

other(em0) -> em1;
other(em1) -> em0;
other(lo0) -> em0.

addresses(Ip, Family) ->
    case {Family, Ip} of
        {inet, <<_:12/binary, S:4/binary, D:4/binary, _/binary>>} -> {S, D};
        {inet6, <<_:8/binary, S:16/binary, D:16/binary, _/binary>>} -> {S, D};
        _ -> {?PEER4, ?ME4}
    end.

%% The quote's local end (its source) and ports, as the judge reads them, so that lookups
%% of a quote hit.
quoted_ports(Family, <<T, _:7/binary, Quote/binary>>)
  when Family =:= inet, (T =:= 3 orelse T =:= 11 orelse T =:= 12);
       Family =:= inet6, T >= 1, T =< 4 ->
    case read_quote(Family, Quote) of
        {ok, _, S, Sp, D, Dp} -> [{S, Sp, D, Dp}];
        {error, _} -> []
    end;
quoted_ports(_, _) ->
    [].

subset(List) -> [X || X <- List, rand:uniform(3) =/= 1].
pick(List) -> lists:nth(rand:uniform(length(List)), List).

%% ---------------------------------------------------------------------------------------
%% Units of the merge

-define(CONN_PORT, 4000).

%% One burst of the connection from port ?CONN_PORT to 80, merged and taken unit by unit.
unit_round() ->
    Family = pick([inet, inet6]),
    {Src, Dst} = case Family of inet -> {?PEER4, ?ME4}; inet6 -> {?PEER6, ?ME6} end,
    Base = rand:uniform(16#ffffffff) - 1,
    Members = members(rand:uniform(12), Base, rand:uniform(16#ffffffff) - 1, pick([none, rand:uniform(1000)])),
    Stream = << <<P/binary>> || #{payload := P} <- Members >>,
    Frames = [unit_frame(Family, Src, Dst, M) || M <- Members],
    ByFrame = maps:from_list(lists:zip(Frames, Members)),
    Entry = #{pid => self(), credit => conn},
    Key = {tcp, Family, Dst, 80, Src, ?CONN_PORT},
    View = unit_view(fun(K) when K =:= Key -> [Entry]; (_) -> [] end),
    Units = erx_bytes:tcp_merge([pick([F, {sum, net_sum(F), F}]) || F <- Frames]),
    Results = [take_unit(Unit, View, ByFrame, Base, Stream) || Unit <- Units],
    case [U || {merged, _, _, _, _} = U <- Units] of
        [Merged | _] when Members =/= [] -> forged(Merged, Family, Src, Dst, View);
        _ -> ok
    end,
    case lists:member(ok, Results) of true -> owned; false -> drop end.

%% N members after one another: data of 0 to 1448 bytes, the acknowledgement moving by
%% 0 to 1000, ACK with PSH at random, now and then another flag or a frame of another
%% connection (port ?CONN_PORT + 1), and now and then a payload byte flipped after the
%% checksum was computed.
members(0, _Seq, _Ack, _Ts) ->
    [];
members(N, Seq, Ack, Ts) ->
    Payload = random_bytes(pick([0, 0, 1, 100, 1448, rand:uniform(1448)])),
    Flags = 16#10 bor pick([0, 0, 16#08]) bor pick([0, 0, 0, 0, 0, 0, 0, 16#01, 16#02, 16#04, 16#20, 16#40, 16#80]),
    Member = #{sport => pick([?CONN_PORT, ?CONN_PORT, ?CONN_PORT, ?CONN_PORT, ?CONN_PORT + 1]), seq => Seq,
               ack => Ack, flags => Flags, payload => Payload, ts => Ts,
               spoiled => byte_size(Payload) > 0 andalso rand:uniform(10) =:= 1},
    Next = (Seq + byte_size(Payload)) band 16#ffffffff,
    [Member | members(N - 1, Next, (Ack + pick([0, 1, 1000])) band 16#ffffffff, next_ts(Ts))].

next_ts(none) -> none;
next_ts(Ts) -> Ts + pick([0, 1]).

random_bytes(N) -> << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, N) >>.

unit_frame(Family, Src, Dst, #{sport := Sport, seq := Seq, ack := Ack, flags := Flags, payload := Payload,
                               ts := Ts, spoiled := Spoiled}) ->
    Opts = case Ts of none -> #tcp_opts{}; _ -> #tcp_opts{ts = {Ts, 7}} end,
    Tcp = #tcp{sport = Sport, dport = 80, seq = Seq, ack = Ack, flags = Flags, win = 512, urp = 0, opts = Opts},
    Pseudo = case Family of
                 inet -> erx_ip4_wire:pseudo_sum(Src, Dst, 0, 6);
                 inet6 -> erx_ip6_wire:pseudo_sum(Src, Dst, 0, 6)
             end,
    Seg0 = iolist_to_binary(erx_tcp_wire:encode(Tcp, Payload, Pseudo, sender)),
    Seg = case Spoiled of
              true -> Head = byte_size(Seg0) - 1, <<H:Head/binary, Last>> = Seg0, <<H/binary, (Last bxor 1)>>;
              false -> Seg0
          end,
    {Type, Packet} =
        case Family of
            inet -> {16#0800, <<(erx_ip4_wire:encode(#ip4{len = 20 + byte_size(Seg), ttl = 64, p = 6, df = 1,
                                                          src = Src, dst = Dst}))/binary, Seg/binary>>};
            inet6 -> {16#86dd, iolist_to_binary(erx_ip6_wire:encode(#ip6{tclass = 0, flow = 0, hlim = 64, src = Src,
                                                                         dst = Dst, proto = 6}, Seg))}
        end,
    <<?MINE/binary, 2, 0, 0, 0, 0, 9, Type:16, Packet/binary>>.

unit_view(Demux) ->
    #{link => ethernet, lladdr => ?MINE,
      ip4 => #{addrs => [?ME4], broadcasts => [?BCAST4], loopback => false},
      ip6 => #{addrs => [?ME6], notready => [], loopback => false, zone => em0},
      groups => [], dhcp => false, demux => Demux}.

%% One unit as the interface takes it; ok when it reached the connection.
take_unit({sum, Sum, Frame}, View, _ByFrame, Base, Stream) ->
    case accepted(classify({frame, Frame, Sum}, View), Base, Stream, 1) of
        {ok, _} -> ok;
        drop -> drop
    end;
take_unit({merged, N, _, {sum, LastSum, LastFrame}, _} = Unit, View, ByFrame, Base, Stream) ->
    case classify(Unit, View) of
        {owned, _, Pending} = Verdict ->
            N =:= erx_net_input:units(Pending) orelse fail(unit_units, {Unit, Pending}),
            #{ack := Ack} = maps:get(LastFrame, ByFrame),
            case accepted(Verdict, Base, Stream, N) of
                {ok, #tcp{ack = Ack}} -> ok;
                {ok, Tcp} -> fail(unit_ack_not_the_last, {Unit, Tcp});
                drop -> drop
            end;
        Verdict ->
            Verdict =:= classify({frame, LastFrame, LastSum}, View)
                orelse fail(unit_not_its_last_frame, {Unit, Verdict}),
            drop
    end.

%% A segment the connection takes carries the connection's own bytes at its number.
accepted({owned, _, Pending}, Base, Stream, N) ->
    case erx_net_input:verify(Pending) of
        {ok, {#tcp{seq = Seq} = Tcp, Payload, _, _}} ->
            Bytes = case Payload of
                        {merged, N, Pieces} -> iolist_to_binary(Pieces);
                        _ when is_binary(Payload), N =:= 1 -> Payload;
                        _ -> fail(unit_payload_shape, Payload)
                    end,
            Offset = (Seq - Base) band 16#ffffffff,
            Offset + byte_size(Bytes) =< byte_size(Stream)
                andalso binary:part(Stream, Offset, byte_size(Bytes)) =:= Bytes
                orelse fail(unit_bytes_not_the_streams, {Seq, Base, Bytes}),
            {ok, Tcp};
        {drop, _} ->
            drop;
        Other ->
            fail(bad_verify_shape, Other)
    end;
accepted(_, _, _, _) ->
    drop.

%% A merged unit of the connection with one of its claims forged: refused at classification
%% or verification.
forged(Unit, Family, Src, Dst, View) ->
    case classify(Unit, View) of
        {owned, _, _} -> forge(Unit, Family, Src, Dst, View);
        _ -> ok
    end.

forge({merged, N, First, Last, Pieces}, Family, Src, Dst, View) ->
    {Kind, Forged} =
        case pick([low, high, last, short]) of
            low -> {low, {merged, min(length(Pieces) - 1, pick([0, 1])), First, Last, Pieces}};
            high -> {high, {merged, 257, First, Last, Pieces}};
            last ->
                Other = unit_frame(Family, Src, Dst, #{sport => ?CONN_PORT + 1, seq => 0, ack => 0, flags => 16#10,
                                                      payload => <<>>, ts => none, spoiled => false}),
                {last, {merged, N, First, {sum, net_sum(Other), Other}, Pieces}};
            short ->
                {short, {merged, N, First, Last, shortened(Pieces)}}
        end,
    case classify(Forged, View) of
        {drop, malformed} -> ok;
        {owned, _, Pending} when Kind =:= last; Kind =:= short ->
            case erx_net_input:verify(Pending) of
                {drop, malformed} -> ok;
                %% A unit of pure ACKs has no piece to cut, so its forge changed nothing.
                Got when Kind =:= short, Pieces =:= [] -> Got;
                Got -> fail(forged_unit_accepted, {Kind, Forged, Got})
            end;
        Got -> fail(forged_unit_accepted, {Kind, Forged, Got})
    end.

shortened([]) -> [];
shortened([Piece | Rest]) -> [binary:part(Piece, 0, byte_size(Piece) - 1) | Rest].
