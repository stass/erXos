%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random argument lists through erx_device_record:find/3 and framebuffers/1. Whatever
%% arrives, each returns {ok, Specs} or {error, {bad_device_record, Text}}, and what it says
%% agrees with reference/1 or framebuffer_reference/1, readers that share no code with it:
%% they find records by filtering and numbers by a regular expression, and take a format's
%% bits from a table of their own. The words come from a small alphabet of record heads,
%% digits near the field bounds, signs, spaces and other characters, so other roles, short
%% records and bad numbers are common. The seed comes from make check-fuzz.

-module(erx_device_record_fuzz).
-include("generated/erx_abi.hrl").
-export([run/1]).

-define(ROUNDS, 20000).
-define(MAX_ENTRIES, 4).
-define(MAX_WORDS, 6).
-define(U64, 16#ffffffffffffffff).
-define(U32, 16#ffffffff).
-define(U48, 16#ffffffffffff).
%% The simple-framebuffer binding's formats and their bits per pixel (kernel/core/dt.c).
-define(FORMATS, [{"a1r5g5b5", 16}, {"a2r10g10b10", 32}, {"a8b8g8r8", 32}, {"a8r8g8b8", 32}, {"r5g6b5", 16},
                  {"r5g5b5a1", 16}, {"r8g8b8", 24}, {"x1r5g5b5", 16}, {"x2r10g10b10", 32}, {"x8r8g8b8", 32},
                  {"x8b8g8r8", 32}]).
%% The fewest rounds that must find a device record, and a framebuffer record, so an edit
%% to the generator cannot leave either accepting path untried.
-define(MIN_ACCEPTED, ?ROUNDS div 100).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Verdicts = [round_of(arguments()) || _ <- lists:seq(1, ?ROUNDS)],
    Accepted = length([ok || {accepted, _} <- Verdicts]),
    Framebuffers = length([ok || {_, accepted} <- Verdicts]),
    case Accepted >= ?MIN_ACCEPTED andalso Framebuffers >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted, ~p framebuffers accepted~n",
                          [?ROUNDS, Accepted, Framebuffers]);
        false -> error({too_few_accepted, Accepted, Framebuffers})
    end.

%% The verdicts of both readers on one argument list, each accepted or refused.
round_of(Arguments) ->
    {devices_round(Arguments), framebuffers_round(Arguments)}.

devices_round(Arguments) ->
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

framebuffers_round(Arguments) ->
    Said = erx_device_record:framebuffers(Arguments),
    case Said of
        {ok, Specs} when is_list(Specs) -> ok;
        {error, {bad_device_record, Text}} when is_list(Text) -> ok
    end,
    case verdict(Said) =:= framebuffer_reference(Arguments) of
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

spec("given", [Path, Window, Offset, Size, Line, Mark, Memory, Bytes, Clock, Coherent, Mac | _]) ->
    case {[decimal(Word, ?U64) || Word <- [Window, Offset, Size, Line, Memory, Bytes]], decimal(Clock, ?U32),
          decimal(Mac, ?U48), node_path(Path)} of
        {[W, O, S, L, M, B], C, A, P} when is_integer(W), is_integer(O), is_integer(S), is_integer(L), is_integer(M),
                                        is_integer(B), is_integer(C), is_integer(A),
                                        (Mark =:= "direct" orelse Mark =:= "shared"),
                                        (Coherent =:= "0" orelse Coherent =:= "1"),
                                        is_binary(P) ->
            Spec = #{peripheral => virtio_mmio, path => P, window => {object, W, O, S}, lines => [marked({object, L}, Mark)],
                     clock => C, coherent => Coherent =:= "1"},
            WithMemory = case B of
                             0 -> Spec;
                             _ -> Spec#{memory => {object, M, B}}
                         end,
            case A of
                0 -> WithMemory;
                _ -> WithMemory#{mac => A}
            end;
        _ ->
            bad
    end;
spec("device", [Path, Base, Size, Line, Mark, Clock | _]) ->
    case {decimal(Base, ?U64), decimal(Size, ?U64), decimal(Line, ?U32), decimal(Clock, ?U32), node_path(Path)} of
        {B, S, L, C, P} when is_integer(B), is_integer(S), is_integer(L), is_integer(C), is_binary(P),
                             (Mark =:= "direct" orelse Mark =:= "shared") ->
            #{peripheral => virtio_mmio, path => P, window => {physical, B, S}, lines => [marked(L, Mark)], clock => C};
        _ ->
            bad
    end;
spec(_Form, _Words) ->
    bad.

%% The reference's PATH: '/' then only the characters a device tree allows in names, at
%% most ERX_DEVICE_PATH_MAX bytes, as a binary; bad otherwise.
node_path(Word) ->
    Allowed = lists:seq($a, $z) ++ lists:seq($A, $Z) ++ lists:seq($0, $9) ++ ",._+-@/",
    case Word of
        [$/ | Rest] when length(Word) =< ?ERX_DEVICE_PATH_MAX ->
            case [C || C <- Rest, not lists:member(C, Allowed)] of
                [] -> list_to_binary(Word);
                _ -> bad
            end;
        _ ->
            bad
    end.

framebuffer_reference(Arguments) ->
    Specs = [framebuffer_spec(Words) || ["framebuffer" | Words] <- Arguments],
    case lists:all(fun is_map/1, Specs) of
        true -> {ok, Specs};
        false -> {error, bad_device_record}
    end.

%% A record the tree's reader would have passed: whole rows of its format inside its bytes.
framebuffer_spec([Window, Offset, Size, Width, Height, Stride, Format | _]) ->
    case {[decimal(Word, ?U64) || Word <- [Window, Offset, Size]],
          [decimal(Word, ?U32) || Word <- [Width, Height, Stride]], lists:keyfind(Format, 1, ?FORMATS)} of
        {[W, O, S], [X, Y, R], {Format, Bits}}
          when is_integer(W), is_integer(O), is_integer(S), is_integer(X), is_integer(Y), is_integer(R),
               S > 0, X > 0, Y > 0, R > 0, R * 8 >= X * Bits, R * Y =< S ->
            #{window => {object, W, O, S}, width => X, height => Y, stride => R, format => list_to_atom(Format)};
        _ ->
            bad
    end;
framebuffer_spec(_Words) ->
    bad.

%% A shared line is tagged; a direct one is the bare line.
marked(Line, "shared") -> {shared, Line};
marked(Line, "direct") -> Line.

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
%% those with their form's count of number words and a mark word after the line, the numbers
%% some within their fields and some just past them and the mark mostly direct or shared, so
%% the accepting path, both marks and the field bounds are reached often.
entry() ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Words = [word() || _ <- lists:seq(1, rand:uniform(?MAX_WORDS + 1) - 1)],
    Form = Pick(["device", "given"]),
    %% The numbers before the mark word and after it.
    Count = #{"device" => {3, 1}, "given" => {4, 5}},
    {Before, After} = maps:get(Form, Count),
    Numbers = fun(N) -> [number() || _ <- lists:seq(1, N)] end,
    case rand:uniform(5) of
        5 -> framebuffer_entry(Words);
        1 -> [Form, "block", "virtio_mmio" | Words];
        2 -> [Form, "block", "virtio_mmio", path() | Numbers(Before) ++ [mark() | Numbers(After)] ++ Words];
        3 -> [Pick(["device", "given", "console_uart"]), Pick(["block", "network", ""]),
              Pick(["virtio_mmio", "sdhci", "virtio_mmio "]) | Words];
        4 -> Words
    end.

%% A record's PATH: nine times in ten a node path, short or at the bound, so records are
%% still accepted often; otherwise, half of those times, a path a byte past the bound, so
%% the bound is reached often, and the other half one with a byte no node name holds or any
%% word.
path() ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Longest = "/" ++ lists:duplicate(?ERX_DEVICE_PATH_MAX - 1, $a),
    case rand:uniform(20) of
        1 -> Longest ++ "a";
        2 -> Pick(["", "virtio_mmio", "/virtio mmio", "/a\e[2J", [$/, 16#661], "/a:b", word()]);
        _ -> Pick(["/virtio_mmio@a003e00", Longest])
    end.

%% A framebuffer record, most with a geometry at the reader's bounds: a stride of a whole
%% row, a byte past it or a byte short of it, and bytes of whole rows or a byte short of
%% them; some with a format the binding does not name, words of the other alphabet, or
%% too few fields.
framebuffer_entry(Words) ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    {Format, Bits} = Pick(?FORMATS),
    Width = rand:uniform(4096),
    Height = rand:uniform(4096),
    Stride = (Width * Bits + 7) div 8 + Pick([0, 0, 0, 1, 64, -1]),
    Size = Stride * Height + Pick([0, 0, 0, 4096, -1]),
    Fields = [number(), number(), integer_to_list(Size), integer_to_list(Width), integer_to_list(Height),
              integer_to_list(Stride), Pick([Format, Format, Format, "a8r8g8b8 ", "A8R8G8B8", ""])],
    case rand:uniform(4) of
        1 -> ["framebuffer" | [number() || _ <- lists:seq(1, 6)] ++ [Format | Words]];
        2 -> ["framebuffer" | lists:sublist(Fields, rand:uniform(7) - 1)];
        _ -> ["framebuffer" | Fields ++ Words]
    end.

mark() ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Pick(["direct", "shared", "direct", "shared", "direct", "shared", "Shared", "direct ", "", "0"]).

number() ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Pick(["0", "1", "79", "512", "4294967295", "4294967296", "281474976710655", "281474976710656",
          "18446744073709551615",
          "18446744073709551616", integer_to_list(rand:uniform(1 bsl 32) - 1)]).

word() ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Pick([Pick(["0", "1", "79", "4096", "167788032", "4294967295", "4294967296",
                "18446744073709551615", "18446744073709551616", "018446744073709551615"]),
          integer_to_list(rand:uniform(1 bsl 70) - 1),
          Pick(["", "-1", "+1", " 1", "1 ", "1\n", "0x10", "1e3", "x", "device", "block", "direct", "shared"]),
          [Pick([$0, $9, $a, $-, $\s, 16#661, 16#ff10]) || _ <- lists:seq(1, rand:uniform(24))]]).
