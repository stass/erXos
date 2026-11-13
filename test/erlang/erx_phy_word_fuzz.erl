%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random words from the Pi 4's MDIO command register and its PHY through the
%% driver's decoders: erx_mdio:poll/3 and decode/1 over any 32-bit word, and
%% erx_phy_c22 driven by random results, mostly the result its request asks for
%% with a random 16-bit value, sometimes another result or an MDIO error.
%% Whatever arrives, nothing crashes; poll/3 agrees with poll_reference/3, which
%% reads the bits by position; the machine's requests are well formed and touch
%% only the registers of its sequence and writes only the five of its setup; it
%% reports a link up only at a speed the
%% auxiliary status word it just read resolves to, as the reference table
%% brgphyreg.h:223-229 gives; and once failed it asks for nothing more. The seed
%% comes from make check-fuzz.

-module(erx_phy_word_fuzz).
-export([run/1]).

-define(ROUNDS, 4000).
-define(STEPS, 60).
-define(BUSY, (1 bsl 29)).
-define(READ_FAILED, (1 bsl 28)).
-define(MAX_POLLS, 1000).
%% The registers the machine may name: control, status, both IDs, the
%% advertisement, 1000BASE-T control, auxiliary control and status, shadow 0x1C.
-define(REGS, [16#00, 16#01, 16#02, 16#03, 16#04, 16#09, 16#18, 16#19, 16#1c]).
%% The registers it may write: control, advertisement, 1000BASE-T control, and the
%% two shadow registers.
-define(WRITABLE, [16#00, 16#04, 16#09, 16#18, 16#1c]).
%% The fewest link-up reports the rounds must see, so the generator cannot leave
%% the resolving path untried.
-define(MIN_UP, ?ROUNDS div 20).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    [mdio_round() || _ <- lists:seq(1, ?ROUNDS * 10)],
    Ups = lists:sum([phy_round() || _ <- lists:seq(1, ?ROUNDS)]),
    case Ups >= ?MIN_UP of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Ups]);
        false -> error({too_few_accepted, Ups})
    end.

%% --- The MDIO command register --------------------------------------------------

mdio_round() ->
    Word = case rand:uniform(3) of
               1 -> rand:uniform(1 bsl 32) - 1;
               2 -> ?BUSY bor (rand:uniform(1 bsl 29) - 1);
               _ -> rand:uniform(1 bsl 29) - 1
           end,
    Op = case rand:uniform(2) of
             1 -> {read, rand:uniform(32) - 1, rand:uniform(32) - 1};
             2 -> {write, rand:uniform(32) - 1, rand:uniform(32) - 1, rand:uniform(16#10000) - 1}
         end,
    Polls = case rand:uniform(3) of
                1 -> ?MAX_POLLS - 1 + rand:uniform(3) - 1;
                _ -> rand:uniform(?MAX_POLLS + 10)
            end,
    Said = erx_mdio:poll(Op, Word, Polls),
    case Said =:= poll_reference(Op, Word, Polls) of
        true -> ok;
        false -> error({disagrees_with_reference, Op, Word, Polls, Said})
    end,
    #{data := Data, phy := Phy, reg := Reg} = erx_mdio:decode(Word),
    true = Data =< 16#ffff andalso Phy =< 31 andalso Reg =< 31,
    ok.

poll_reference(Op, Word, Polls) ->
    <<_:2, Busy:1, Failed:1, _:12, Data:16>> = <<Word:32>>,
    case {Busy, element(1, Op)} of
        {1, _} when Polls >= ?MAX_POLLS -> {error, timeout};
        {1, _} -> {wait, Polls + 1};
        {0, read} when Failed =:= 1 -> {error, read_failed};
        {0, read} -> {ok, Data};
        {0, write} -> ok
    end.

%% --- The PHY machine ------------------------------------------------------------

%% One walk of up to ?STEPS results; the link-up reports it saw.
phy_round() ->
    {Phy, Request} = erx_phy_c22:start(),
    walk(Phy, Request, ?STEPS, 0).

walk(_Phy, _Request, 0, Ups) -> Ups;
walk(Phy, stop, Steps, Ups) ->
    {Phy, stop, []} = erx_phy_c22:step(Phy, result(stop)),
    walk(Phy, stop, Steps - 1, Ups);
walk(Phy, Request, Steps, Ups) ->
    ok = request_shape(Request),
    Input = result(Request),
    {Phy1, Request1, Reports} = erx_phy_c22:step(Phy, Input),
    [ok = report_shape(R) || R <- Reports],
    Up = [S || {link, up, S} <- Reports],
    case Up of
        [] -> ok;
        [Speed] ->
            {{read, 16#19}, {ok, Aux}} = {Request, Input},
            case aux_reference(Aux) of
                Speed -> ok;
                Want -> error({disagrees_with_reference, Aux, Want, Speed})
            end
    end,
    case Reports of
        [{failed, _}] -> stop = Request1;
        _ -> ok
    end,
    walk(Phy1, Request1, Steps - 1, Ups + length(Up)).

%% Mostly the result the request asks for; the reset and status reads are biased
%% so the walk gets past the reset and sees a link come up.
result(Request) ->
    case {rand:uniform(40), Request} of
        {1, _} -> {error, timeout};
        {2, _} -> ok;
        {3, _} -> {ok, word()};
        {_, {read, 16#00}} -> {ok, word() band bnot 16#8000};
        {_, {read, 16#02}} -> {ok, pick([16#600d, word()])};
        {_, {read, 16#03}} -> {ok, pick([16#84a0 bor (rand:uniform(16) - 1), word()])};
        {_, {read, 16#01}} -> {ok, pick([16#0024, word()])};
        {_, {read, 16#19}} -> {ok, word()};
        {_, {read, _}} -> {ok, word()};
        {_, _} -> ok
    end.

word() -> rand:uniform(16#10000) - 1.

pick(Choices) -> lists:nth(rand:uniform(length(Choices)), Choices).

request_shape({read, Reg}) -> true = lists:member(Reg, ?REGS), ok;
request_shape({write, Reg, Value}) ->
    true = lists:member(Reg, ?WRITABLE) andalso is_integer(Value) andalso Value >= 0 andalso Value =< 16#ffff,
    ok;
request_shape({wait, Ms}) when is_integer(Ms), Ms > 0 -> ok;
request_shape(stop) -> ok.

report_shape({link, down}) -> ok;
report_shape({link, up, Speed}) when Speed =:= 10; Speed =:= 100; Speed =:= 1000 -> ok;
report_shape({failed, _}) -> ok.

aux_reference(Aux) ->
    <<_:5, Resolution:3, _:5, Link:1, _:2>> = <<Aux:16>>,
    case Link * 8 + Resolution of
        15 -> 1000;
        13 -> 100;
        10 -> 10;
        _ -> none
    end.
