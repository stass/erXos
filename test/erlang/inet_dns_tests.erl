%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(inet_dns_tests).
-moduledoc """
EUnit cases of the tree's inet_dns:decode/1 on record data that stock OTP cannot
decode: the types named without a format of their own (UINFO, UID, GID and UNSPEC,
100 to 103; IXFR, AXFR, MAILB, MAILA and ANY, 251 to 255) and A, AAAA and WKS of a
class other than IN. A reply carrying one must decode, with the record's data kept
raw, and never raise: stock raises function_clause and takes down the resolver's
caller. Each reply is built by hand, since inet_dns:encode/1 cannot make these
records. The cases run against the tree's inet_dns (test/host/inet_dns_test.rb
loads it over stock's); against stock's they fail with function_clause.
""".

-include_lib("eunit/include/eunit.hrl").

-define(CLASS_IN, 1).
-define(CLASS_CH, 3).

raw_types_test_() ->
    [{lists:flatten(io_lib:format("type ~B, class IN, keeps its data raw", [Type])),
      fun() -> kept_raw(Type, ?CLASS_IN, <<1, 2, 3, 4, 5>>) end}
     || Type <- [100, 101, 102, 103, 251, 252, 253, 254, 255]].

other_class_test_() ->
    [{lists:flatten(io_lib:format("~s of class CH keeps its data raw", [Name])),
      fun() -> kept_raw(Type, ?CLASS_CH, Data) end}
     || {Name, Type, Data} <- [{"A", 1, <<10, 0, 0, 1>>},
                               {"AAAA", 28, <<0:128>>},
                               {"WKS", 11, <<10, 0, 0, 1, 6, 0, 1>>}]].

%% One answer record of Type and Class with Data, in a reply of no question.
reply(Type, Class, Data) ->
    <<1:16, 1:1, 0:15, 0:16, 1:16, 0:16, 0:16,
      0, Type:16, Class:16, 60:32, (byte_size(Data)):16, Data/binary>>.

kept_raw(Type, Class, Data) ->
    {ok, Msg} = inet_dns:decode(reply(Type, Class, Data)),
    [RR] = inet_dns:msg(Msg, anlist),
    ?assertEqual(Data, inet_dns:rr(RR, data)).
