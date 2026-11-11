%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random argument lists through erx_device_record:find/3. Whatever arrives, it returns
%% {ok, Specs} or {error, {bad_device_record, Text}}, and what it says agrees with
%% reference/1, a reader that shares no code with it: it finds records by filtering and
%% numbers by a regular expression. The words come from a small alphabet of record heads,
%% digits near the field bounds, signs, spaces and other characters, so other roles, short
%% records and bad numbers are common. The seed comes from make check-fuzz.

-module(erx_device_record_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MAX_ENTRIES, 4).
-define(MAX_WORDS, 6).
-define(U64, 16#ffffffffffffffff).
-define(U32, 16#ffffffff).
%% The fewest rounds that must find a record, so an edit to the generator cannot leave the
%% accepting path untried.
-define(MIN_ACCEPTED, ?ROUNDS div 100).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(arguments()) =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of(Arguments) ->
    Said = erx_device_record:find(block, virtio_mmio, Arguments),
    case Said of
        {ok, Specs} when is_list(Specs) -> ok;
        {error, {bad_device_record, Text}} when is_list(Text) -> ok
    end,
    case verdict(Said) =:= reference(Arguments) of
        true when Said =:= {ok, []} -> refused;
        true when element(1, Said) =:= ok -> accepted;
        true -> refused;
        false -> error({disagrees_with_reference, Arguments, Said})
    end.

verdict({ok, Specs}) -> {ok, Specs};
verdict({error, {Reason, _Text}}) -> {error, Reason}.

reference(Arguments) ->
    Records = lists:filter(fun([Form, "block", "virtio_mmio" | _]) -> lists:member(Form, ["device", "given"]);
                              (_) -> false
                           end, Arguments),
    Specs = [spec(Form, Words) || [Form, "block", "virtio_mmio" | Words] <- Records],
    case lists:all(fun is_map/1, Specs) of
        true -> {ok, Specs};
        false -> {error, bad_device_record}
    end.

spec("given", [Window, Offset, Size, Line, Memory, Bytes | _]) ->
    case [decimal(Word, ?U64) || Word <- [Window, Offset, Size, Line, Memory, Bytes]] of
        [W, O, S, L, M, 0] when is_integer(W), is_integer(O), is_integer(S), is_integer(L), is_integer(M) ->
            #{peripheral => virtio_mmio, window => {object, W, O, S}, lines => [{object, L}]};
        [W, O, S, L, M, B] when is_integer(W), is_integer(O), is_integer(S), is_integer(L), is_integer(M),
                                is_integer(B) ->
            #{peripheral => virtio_mmio, window => {object, W, O, S}, lines => [{object, L}],
              memory => {object, M, B}};
        _ ->
            bad
    end;
spec("device", [Base, Size, Line | _]) ->
    case {decimal(Base, ?U64), decimal(Size, ?U64), decimal(Line, ?U32)} of
        {B, S, L} when is_integer(B), is_integer(S), is_integer(L) ->
            #{peripheral => virtio_mmio, window => {physical, B, S}, lines => [L]};
        _ ->
            bad
    end;
spec(_Form, _Words) ->
    bad.

%% Digits only, and no more of them than Max has.
decimal(Word, Max) ->
    Digits = integer_to_list(length(integer_to_list(Max))),
    case re:run(Word, "\\A[0-9]{1," ++ Digits ++ "}\\z", [unicode, {capture, none}]) of
        match ->
            case list_to_integer(Word) of
                Value when Value =< Max -> Value;
                _ -> bad
            end;
        nomatch ->
            bad
    end.

arguments() ->
    [entry() || _ <- lists:seq(1, rand:uniform(?MAX_ENTRIES + 1) - 1)].

%% Half of the entries are records of the asked role and peripheral, in either form, half of
%% those with their form's count of number words, some within their fields and some just
%% past them, so the accepting path and the field bounds are reached often.
entry() ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Words = [word() || _ <- lists:seq(1, rand:uniform(?MAX_WORDS + 1) - 1)],
    Form = Pick(["device", "given"]),
    Count = #{"device" => 3, "given" => 6},
    case rand:uniform(4) of
        1 -> [Form, "block", "virtio_mmio" | Words];
        2 -> [Form, "block", "virtio_mmio" | [number() || _ <- lists:seq(1, maps:get(Form, Count))] ++ Words];
        3 -> [Pick(["device", "given", "console_uart"]), Pick(["block", "network", ""]),
              Pick(["virtio_mmio", "sdhci", "virtio_mmio "]) | Words];
        4 -> Words
    end.

number() ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Pick(["0", "79", "512", "4294967295", "4294967296", "18446744073709551615",
          "18446744073709551616", integer_to_list(rand:uniform(1 bsl 32) - 1)]).

word() ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Pick([Pick(["0", "1", "79", "4096", "167788032", "4294967295", "4294967296",
                "18446744073709551615", "18446744073709551616", "018446744073709551615"]),
          integer_to_list(rand:uniform(1 bsl 70) - 1),
          Pick(["", "-1", "+1", " 1", "1 ", "1\n", "0x10", "1e3", "x", "device", "block"]),
          [Pick([$0, $9, $a, $-, $\s, 16#661, 16#ff10]) || _ <- lists:seq(1, rand:uniform(24))]]).
