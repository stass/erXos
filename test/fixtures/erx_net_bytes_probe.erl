%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_bytes_probe).

-moduledoc """
Judges erx_bytes's network primitives, `inet_csum/2`, `inet_csum_update/3` and `siphash24/2`,
in a running erXos release against the Erlang models of the host stand-in
(test/erlang/host_bytes/erx_bytes.erl). The host tests run `answers/0` on stock OTP with the
stand-in, then load this module into the release and hand those answers to `check/1`, which
compares them with the NIF's answers to the same calls. The calls come from a fixed seed of
`rand`, so both runtimes, which are the same OTP release, make the same arguments. Their
iolists nest binaries over 512 bytes, which `erlang:iolist_to_iovec/1` leaves as pieces of
their own, at odd and even offsets, so the NIF's walk over pieces is judged as well as its
arithmetic. `check/1` also judges every refusal and acceptance of the shared contract
against literal answers, so on stock it judges the stand-in's contract too.
""".

-export([answers/0, check/1]).

-define(RANDOM_CALLS, 20).
-define(CALL_MAX, 65536).

-type answer() :: non_neg_integer() | badarg.

-doc "The answers of erx_bytes, whichever implementation is loaded, to the probe's calls.".
-spec answers() -> [answer()].
answers() ->
    [answer(Call) || Call <- calls()].

-doc """
`{net_bytes, Mismatches, Contract}`: the positions of the calls whose answers differ from
`Expected`, the stand-in's answers (or `[count]` when there are not as many), and the
contract cases that answered wrongly as `{Position, Want, Got}`; both empty when the
implementation agrees.
""".
-spec check([answer()]) -> {net_bytes, [pos_integer()] | [count], [{pos_integer(), answer(), answer()}]}.
check(Expected) ->
    {net_bytes, mismatches(Expected, answers()), wrong_contract_answers()}.

mismatches(Expected, Answers) when length(Expected) =/= length(Answers) ->
    [count];
mismatches(Expected, Answers) ->
    [Index || {Index, Want, Got} <- lists:zip3(lists:seq(1, length(Answers)), Expected, Answers),
              Want =/= Got].

wrong_contract_answers() ->
    Answered = [{Index, Want, answer(Call)}
                || {Index, {Call, Want}} <- lists:enumerate(contract())],
    [Wrong || {_Index, Want, Got} = Wrong <- Answered, Want =/= Got].

answer({Function, Arguments}) ->
    try apply(erx_bytes, Function, Arguments)
    catch error:badarg -> badarg
    end.

%% Random calls of each primitive over iolists of pieces of 0 to 1500 bytes, some over 512.
calls() ->
    _ = rand:seed(exsss, {1071, 1624, 2012}),
    lists:append([[{inet_csum, [rand:uniform(16#10000) - 1, iolist()]},
                   {siphash24, [rand:bytes(16), iolist()]},
                   {inet_csum_update, update_arguments()}] || _ <- lists:seq(1, ?RANDOM_CALLS)]).

iolist() ->
    nest([rand:bytes(rand:uniform(1501) - 1) || _ <- lists:seq(1, rand:uniform(5))]).

nest([]) -> [];
nest([Piece]) -> [Piece];
nest([First, Second | Rest]) -> [[First], [Second | nest(Rest)]].

update_arguments() ->
    Size = 2 * (rand:uniform(5) - 1),
    [rand:uniform(16#10000) - 1, rand:bytes(Size), rand:bytes(Size)].

%% Each call with its literal answer: refusals, the limits of 64 KiB, and iodata of every shape.
contract() ->
    Key = list_to_binary(lists:seq(0, 15)),
    Max = binary:copy(<<1>>, ?CALL_MAX),
    [{{inet_csum, [-1, <<>>]}, badarg},
     {{inet_csum, [16#10000, <<>>]}, badarg},
     {{inet_csum, [0, <<Max/binary, 1>>]}, badarg},
     {{inet_csum, [0, [<<1>>, Max]]}, badarg},
     {{inet_csum, [0, <<1:7>>]}, badarg},
     {{inet_csum, [0, [<<1:7>>]]}, badarg},
     {{inet_csum, [0, [atom]]}, badarg},
     {{inet_csum, [0, atom]}, badarg},
     {{inet_csum, [0, [1 | 2]]}, badarg},
     {{inet_csum, [0, [256]]}, badarg},
     {{inet_csum, [16#1234, []]}, 16#1234},
     {{inet_csum, [0, [<<1>> | <<2>>]]}, 16#0102},
     {{inet_csum, [0, Max]}, 16#8080},
     {{inet_csum, [0, [binary:part(Max, 0, ?CALL_MAX - 1), 1]]}, 16#8080},
     {{inet_csum_update, [0, <<1>>, <<2>>]}, badarg},
     {{inet_csum_update, [0, <<1, 2>>, <<1, 2, 3, 4>>]}, badarg},
     {{inet_csum_update, [16#10000, <<>>, <<>>]}, badarg},
     {{inet_csum_update, [0, [<<1, 2>>], <<1, 2>>]}, badarg},
     {{inet_csum_update, [0, <<Max/binary, 0, 0>>, <<Max/binary, 0, 0>>]}, badarg},
     {{inet_csum_update, [16#dd2f, <<16#55, 16#55>>, <<16#32, 16#85>>]}, 16#0000},
     {{inet_csum_update, [16#ffff, <<>>, <<>>]}, 16#ffff},
     {{siphash24, [<<0:120>>, <<>>]}, badarg},
     {{siphash24, [<<0:127>>, <<>>]}, badarg},
     {{siphash24, [[Key], <<>>]}, badarg},
     {{siphash24, [Key, <<Max/binary, 1>>]}, badarg},
     {{siphash24, [Key, [1 | 2]]}, badarg},
     {{siphash24, [Key, lists:seq(0, 14)]}, 16#a129ca6149be45e5},
     {{siphash24, [Key, []]}, 16#726fdb47dd0e0e31}].
