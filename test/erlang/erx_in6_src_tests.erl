%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% EUnit cases of erx_in6_src: the source address selection examples of
%% RFC 6724 section 10.1 and the candidate filter of in6_selectsrc.

-module(erx_in6_src_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, 1000000).

a(Text) ->
    {ok, Tuple} = inet:parse_ipv6strict_address(Text),
    << <<W:16>> || W <- tuple_to_list(Tuple) >>.

row(Text) -> row(Text, []).
row(Text, Opts) ->
    #{addr => a(Text), plen => 64, ifname => proplists:get_value(ifname, Opts, eth0),
      flags => proplists:get_value(flags, Opts, []),
      preferred => case proplists:get_bool(deprecated, Opts) of
                       true -> ?NOW - 1;
                       false -> infinity
                   end,
      valid => infinity}.

pick(Dst, Rows) ->
    {ok, #{addr := Addr}} = erx_in6_src:select(a(Dst), eth0, Rows, ?NOW),
    Addr.

%% Each example in both candidate orders, since the walk keeps a tie.
example(Dst, Rows, Expected) ->
    ?assertEqual(a(Expected), pick(Dst, Rows)),
    ?assertEqual(a(Expected), pick(Dst, lists:reverse(Rows))).

rfc6724_scope_test() ->
    example("2001:db8:1::1", [row("2001:db8:3::1"), row("fe80::1")], "2001:db8:3::1"),
    example("ff05::1", [row("2001:db8:3::1"), row("fe80::1")], "2001:db8:3::1").

rfc6724_same_address_test() ->
    example("2001:db8:1::1", [row("2001:db8:1::1", [deprecated]), row("2001:db8:2::1")],
            "2001:db8:1::1").

rfc6724_scope_before_deprecated_test() ->
    example("fe80::1", [row("fe80::2", [deprecated]), row("2001:db8:1::1")], "fe80::2").

rfc6724_longest_match_test() ->
    example("2001:db8:1::1", [row("2001:db8:1::2"), row("2001:db8:3::2")], "2001:db8:1::2").

rfc6724_label_test() ->
    example("2002:c633:6401::1",
            [row("2002:c633:6401::d5e3:7953:13eb:22e8", [{flags, [temporary]}]),
             row("2001:db8:1::2")],
            "2002:c633:6401::d5e3:7953:13eb:22e8").

%% RFC 6724 prefers the temporary address here; FreeBSD's default
%% ip6_prefer_tempaddr of 0 prefers the public one.
public_over_temporary_test() ->
    example("2001:db8:1::d5e3:0:0:1",
            [row("2001:db8:1::2"), row("2001:db8:1::d5e3:7953:13eb:22e8", [{flags, [temporary]}])],
            "2001:db8:1::2").

deprecated_avoided_test() ->
    example("2001:db8:9::1", [row("2001:db8:1::1", [deprecated]), row("2001:db8:2::1")],
            "2001:db8:2::1").

outgoing_interface_test() ->
    example("2001:db8:9::1", [row("2001:db8:1::1", [{ifname, eth1}]), row("2001:db8:2::1")],
            "2001:db8:2::1").

unusable_rows_skipped_test() ->
    %% A link-local source on another interface leaves its zone.
    example("fe80::9", [row("fe80::1", [{ifname, eth1}]), row("2001:db8:2::1")], "2001:db8:2::1"),
    example("2001:db8:9::1", [row("2001:db8:9::2", [{flags, [tentative]}]), row("2001:db8:2::1")],
            "2001:db8:2::1"),
    example("2001:db8:9::1", [row("2001:db8:9::2", [{flags, [duplicated]}]), row("2001:db8:2::1")],
            "2001:db8:2::1"),
    ?assertEqual({error, eaddrnotavail},
                 erx_in6_src:select(a("2001:db8::1"), eth0,
                                    [row("2001:db8::2", [{flags, [anycast]}]),
                                     #{addr => <<10, 0, 0, 1>>, plen => 8, ifname => eth0,
                                       flags => [], preferred => infinity, valid => infinity}],
                                    ?NOW)).
