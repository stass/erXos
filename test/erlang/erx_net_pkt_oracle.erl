%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_pkt_oracle).
-moduledoc """
The network stack's independent decoder: msantos/pkt (deps.lock's pkt) behind
one neutral shape, the differential oracle of erx_net's codec fuzz targets
(docs/design-network-stack.md, "Codecs: fuzz targets").

Each function decodes one header with pkt and returns `{ok, Fields, Rest}`:
Fields a map of the header's wire fields, named after FreeBSD's structures
without their prefixes (`struct ip`'s `ip_ttl` is `ttl`), with addresses as
their wire bytes (4 or 16) and numbers as integers; Rest the bytes pkt leaves
after the header. `{error, rejected}` is pkt failing on the input, which it
signals by raising: pkt is not total, so every call of it is caught here. An
exception in a projection is a bug of this module and propagates.

pkt is a judge with known gaps, which the fuzz targets compare around:

* it does not cut a payload at the length the header states (IPv4 `len`,
  IPv6 `len`, UDP `ulen`): Rest runs to the end of the input;
* it does not verify checksums; `sum` is the field as received;
* it refuses an IPv4 header whose reserved flag is set, as RFC 791 bids a sender
  leave it clear, where FreeBSD's `ip_input` reads past it;
* it reads the second byte of an MLDv2 report (ICMPv6 type 143) as reserved,
  so `code` is 0 there whatever the byte holds;
* it decodes only the TCP options it knows, and raises on any other or on a
  malformed one, which comes back as `options => rejected`; but it accepts a
  SACK option whose length is not 2 + 8n, dropping the bytes left over;
* it decodes ICMP's second word only for the types it knows: echo's `id` and
  `seq`, ICMPv4 redirect's `gateway` and parameter problem's `pointer`,
  ICMPv6 packet too big's `mtu` and parameter problem's `pointer`. Any other
  type carries the word in `unused`, taken from the input itself.
""".

-include("pkt.hrl").

-export([arp/1, ether/1, icmp4/1, icmp6/1, ipv4/1, ipv6/1, tcp/1, udp/1]).

-export_type([decoded/0]).

-type decoded() :: {ok, #{atom() => term()}, Rest :: binary()} | {error, rejected}.

-doc "An Ethernet II header.".
-spec ether(binary()) -> decoded().
ether(Bin) ->
    decode(fun pkt:ether/1, Bin, fun(#ether{dhost = Dst, shost = Src, type = Type}) ->
        #{dst => Dst, src => Src, type => Type}
    end).

-doc "An ARP packet (`struct arphdr` and its Ethernet/IPv4 addresses).".
-spec arp(binary()) -> decoded().
arp(Bin) ->
    decode(fun pkt:arp/1, Bin, fun(#arp{hrd = Hrd, pro = Pro, hln = Hln, pln = Pln, op = Op,
                                        sha = Sha, sip = Sip, tha = Tha, tip = Tip}) ->
        #{hrd => Hrd, pro => Pro, hln => Hln, pln => Pln, op => Op,
          sha => Sha, spa => addr(Sip), tha => Tha, tpa => addr(Tip)}
    end).

-doc "An IPv4 header with its options (`struct ip`); `off` is in 8-byte units.".
-spec ipv4(binary()) -> decoded().
ipv4(Bin) ->
    decode(fun pkt:ipv4/1, Bin, fun(#ipv4{v = V, hl = Hl, tos = Tos, len = Len, id = Id, df = Df, mf = Mf,
                                          off = Off, ttl = Ttl, p = P, sum = Sum, saddr = Src,
                                          daddr = Dst, opt = Opt}) ->
        #{v => V, hl => Hl, tos => Tos, len => Len, id => Id, df => Df, mf => Mf, off => Off,
          ttl => Ttl, p => P, sum => Sum, src => addr(Src), dst => addr(Dst), options => Opt}
    end).

-doc "An IPv6 fixed header (`struct ip6_hdr`); extension headers stay in Rest.".
-spec ipv6(binary()) -> decoded().
ipv6(Bin) ->
    decode(fun pkt:ipv6/1, Bin, fun(#ipv6{v = V, class = Class, flow = Flow, len = Len, next = Next,
                                          hop = Hop, saddr = Src, daddr = Dst}) ->
        #{v => V, class => Class, flow => Flow, plen => Len, nxt => Next, hlim => Hop,
          src => addr(Src), dst => addr(Dst)}
    end).

-doc "An ICMPv4 header (`struct icmp`).".
-spec icmp4(binary()) -> decoded().
icmp4(Bin) ->
    decode(fun pkt:icmp/1, Bin, fun(#icmp{type = Type, code = Code, checksum = Sum} = Icmp) ->
        maps:merge(#{type => Type, code => Code, sum => Sum}, icmp4_word(Icmp, Bin))
    end).

-doc "An ICMPv6 header (`struct icmp6_hdr`).".
-spec icmp6(binary()) -> decoded().
icmp6(Bin) ->
    decode(fun pkt:icmp6/1, Bin, fun(#icmp6{type = Type, code = Code, checksum = Sum} = Icmp) ->
        maps:merge(#{type => Type, code => Code, sum => Sum}, icmp6_word(Icmp, Bin))
    end).

-doc "A UDP header (`struct udphdr`).".
-spec udp(binary()) -> decoded().
udp(Bin) ->
    decode(fun pkt:udp/1, Bin, fun(#udp{sport = Sport, dport = Dport, ulen = Ulen, sum = Sum}) ->
        #{sport => Sport, dport => Dport, ulen => Ulen, sum => Sum}
    end).

-doc """
A TCP header (`struct tcphdr`): `flags` holds the nine flag bits as on the wire
(NS the highest, FIN the lowest), and `options` the options in order, or
`rejected` when pkt cannot decode them.
""".
-spec tcp(binary()) -> decoded().
tcp(Bin) ->
    decode(fun pkt:tcp/1, Bin, fun(#tcp{sport = Sport, dport = Dport, seqno = Seq, ackno = Ack, off = Off,
                                        ns = Ns, cwr = Cwr, ece = Ece, urg = Urg, ack = AckFlag, psh = Psh,
                                        rst = Rst, syn = Syn, fin = Fin, win = Win, sum = Sum, urp = Urp,
                                        opt = Opt}) ->
        <<Flags:9>> = <<Ns:1, Cwr:1, Ece:1, Urg:1, AckFlag:1, Psh:1, Rst:1, Syn:1, Fin:1>>,
        #{sport => Sport, dport => Dport, seq => Seq, ack => Ack, off => Off, flags => Flags,
          win => Win, sum => Sum, urp => Urp, options => tcp_options(Opt)}
    end).

%% pkt's decoder applied to Bin, its record projected by Fields; pkt signals a
%% malformed header by raising.
decode(Decoder, Bin, Fields) ->
    try Decoder(Bin) of
        {Header, Rest} when is_binary(Rest) -> {ok, Fields(Header), Rest}
    catch
        error:_ -> {error, rejected}
    end.

icmp4_word(#icmp{type = Type, id = Id, sequence = Seq}, _) when Type =:= ?ICMP_ECHO; Type =:= ?ICMP_ECHOREPLY ->
    #{id => Id, seq => Seq};
icmp4_word(#icmp{type = ?ICMP_REDIRECT, gateway = Gateway}, _) -> #{gateway => addr(Gateway)};
icmp4_word(#icmp{type = ?ICMP_PARAMETERPROB, pointer = Pointer}, _) -> #{pointer => Pointer};
icmp4_word(#icmp{}, Bin) -> unused(Bin).

icmp6_word(#icmp6{type = Type, id = Id, seq = Seq}, _) when Type =:= ?ICMP6_ECHO_REQUEST; Type =:= ?ICMP6_ECHO_REPLY ->
    #{id => Id, seq => Seq};
icmp6_word(#icmp6{type = ?ICMP6_PACKET_TOO_BIG, mtu = Mtu}, _) -> #{mtu => Mtu};
icmp6_word(#icmp6{type = ?ICMP6_PARAM_PROB, pptr = Pointer}, _) -> #{pointer => Pointer};
icmp6_word(#icmp6{}, Bin) -> unused(Bin).

%% The header's second word as received: pkt leaves its own `un` at a default
%% for some types it decodes. Every header pkt accepts holds the word.
unused(<<_:4/binary, Word:4/binary, _/binary>>) -> #{unused => Word}.

tcp_options(Opt) ->
    try pkt:tcp_options(Opt) of
        Options -> [tcp_option(Option) || Option <- Options]
    catch
        error:_ -> rejected
    end.

tcp_option({eol, []}) -> eol;
tcp_option({nop, []}) -> nop;
tcp_option({maximum_segment_size, Mss}) -> {mss, Mss};
tcp_option({window_scale, Shift}) -> {wscale, Shift};
tcp_option({sack_permitted, true}) -> sack_permitted;
tcp_option({sack, Edges}) -> {sack, [{Left, Right} || {{left_edge, Left}, {right_edge, Right}} <- Edges]};
tcp_option({tsopt, [{timestamp, Val}, {timestamp_echo_reply, Ecr}]}) -> {timestamp, Val, Ecr}.

addr({_, _, _, _} = Ip4) -> list_to_binary(tuple_to_list(Ip4));
addr({_, _, _, _, _, _, _, _} = Ip6) -> << <<Word:16>> || Word <- tuple_to_list(Ip6) >>.
