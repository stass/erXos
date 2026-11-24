%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random argument lists through erx_device_record:find/3, framebuffers/1, system_image/1 and drives/2,
%% find/3 asked both for a given or device record and for a PCIe function record.
%% Whatever arrives, each returns {ok, Value} or {error, {bad_device_record, Text}}, and what it
%% says agrees with reference/1, function_reference/1, framebuffer_reference/1,
%% system_image_reference/1 or drives_reference/2, readers
%% that share no code with it:
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
-define(U16, 16#ffff).
-define(U48, 16#ffffffffffff).
%% The simple-framebuffer binding's formats and their bits per pixel (kernel/core/dt.c).
-define(FORMATS, [{"a1r5g5b5", 16}, {"a2r10g10b10", 32}, {"a8b8g8r8", 32}, {"a8r8g8b8", 32}, {"r5g6b5", 16},
                  {"r5g5b5a1", 16}, {"r8g8b8", 24}, {"x1r5g5b5", 16}, {"x2r10g10b10", 32}, {"x8r8g8b8", 32},
                  {"x8b8g8r8", 32}]).
%% The fewest rounds that must find each form, a device record, a function record, a
%% framebuffer record, a system image and a set of drives, so an edit to the generator cannot leave any
%% accepting path untried.
-define(MIN_ACCEPTED, ?ROUNDS div 100).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Verdicts = [round_of(arguments()) || _ <- lists:seq(1, ?ROUNDS)],
    Accepted = length([ok || {accepted, _, _, _, _} <- Verdicts]),
    Functions = length([ok || {_, accepted, _, _, _} <- Verdicts]),
    Framebuffers = length([ok || {_, _, accepted, _, _} <- Verdicts]),
    Images = length([ok || {_, _, _, accepted, _} <- Verdicts]),
    Drives = length([ok || {_, _, _, _, accepted} <- Verdicts]),
    case lists:min([Accepted, Functions, Framebuffers, Images, Drives]) >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted, ~p functions accepted, ~p framebuffers accepted, "
                          "~p system images accepted, ~p drive sets accepted~n", [?ROUNDS, Accepted, Functions, Framebuffers, Images, Drives]);
        false -> error({too_few_accepted, Accepted, Functions, Framebuffers, Images, Drives})
    end.

%% The verdicts of the readers on one argument list, each accepted or refused.
round_of(Arguments) ->
    {devices_round(Arguments), functions_round(Arguments), framebuffers_round(Arguments),
     system_image_round(Arguments), drives_round(Arguments)}.

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

functions_round(Arguments) ->
    Said = erx_device_record:find(usb, xhci, Arguments),
    case Said of
        {ok, Specs} when is_list(Specs) -> ok;
        {error, {bad_device_record, Text}} when is_list(Text) -> ok
    end,
    case verdict(Said) =:= function_reference(Arguments) of
        true when Said =:= {ok, []} -> refused;
        true when element(1, Said) =:= ok -> accepted;
        true -> refused;
        false -> error({disagrees_with_reference, Arguments, Said})
    end.

%% The function records of usb and xhci: fifteen words, then six BARs of three, every one a
%% decimal within its field, the place's device and function within pcie_device_max and
%% pcie_function_max, a known mark, coherence and route, and a null line never marked
%% shared. At least one BAR is placed, every placed BAR's SIZE_LOG2 is 4 to
%% pcie_bar_size_log2_max, and the first is the window; an MSI-X route's table is in that
%% BAR, of 1 to 2048 entries of 16 bytes ending inside it.
function_reference(Arguments) ->
    Specs = [function_spec(Words) || ["function", "usb", "xhci" | Words] <- Arguments],
    case lists:all(fun is_map/1, Specs) of
        true -> {ok, Specs};
        false -> {error, bad_device_record}
    end.

function_spec([Bridge, Bus, Device, Function, Line, Mark, Memory, Bytes, Coherent, Route, Address, Data, TableBar,
               TableOffset, Entries | Rest]) when length(Rest) >= 18 ->
    Numbers = [decimal(Word, Max) || {Word, Max} <- [{Bridge, ?U32}, {Bus, 255}, {Device, ?ERX_PCIE_DEVICE_MAX},
                                                    {Function, ?ERX_PCIE_FUNCTION_MAX}, {Line, ?U64},
                                                    {Memory, ?U64}, {Bytes, ?U64}, {Address, ?U64}, {Data, ?U32},
                                                    {TableBar, 255}, {TableOffset, ?U32}, {Entries, 16#ffff}]]
        ++ [decimal(Word, ?U64) || Word <- lists:sublist(Rest, 18)],
    Known = lists:member(Mark, ["direct", "shared"]) andalso lists:member(Coherent, ["0", "1"])
        andalso lists:member(Route, ["none", "msi", "msix", "intx"]),
    case lists:all(fun is_integer/1, Numbers) andalso Known of
        true -> function_map(Numbers, Mark, Coherent, Route);
        false -> bad
    end;
function_spec(_Words) ->
    bad.

function_map([B, Bu, D, F, L, M, Bytes, A, Da, TableBar, TableOffset, Entries | BarWords], Mark, Coherent, Route) ->
    Placed = [{Bar, W, O, S} || {Bar, [W, O, S]} <- lists:zip(lists:seq(0, 5), threes(BarWords)), W =/= ?ERX_CAP_NULL],
    Sized = lists:all(fun({_, _, _, S}) -> S >= 4 andalso S =< ?ERX_PCIE_BAR_SIZE_LOG2_MAX end, Placed),
    case Placed of
        [{Bar, W, O, S} | _] when Sized, not (L =:= ?ERX_CAP_NULL andalso Mark =:= "shared") ->
            Table = TableBar =:= Bar andalso Entries >= 1 andalso Entries =< 2048
                andalso TableOffset + 16 * Entries =< 1 bsl S,
            Spec = #{peripheral => xhci, place => {B, Bu, D, F}, window => {object, W, O, 1 bsl S},
                     lines => [marked({object, L}, Mark) || L =/= ?ERX_CAP_NULL], coherent => Coherent =:= "1"},
            WithMemory = case Bytes of
                             0 -> Spec;
                             _ -> Spec#{memory => {object, M, Bytes}}
                         end,
            case Route of
                "msix" when Table ->
                    WithMemory#{msix => #{address => A, data => Da, bar => TableBar, offset => TableOffset,
                                          entries => Entries}};
                "msix" -> bad;
                _ -> WithMemory
            end;
        _ ->
            bad
    end.

threes([A, B, C | Rest]) -> [[A, B, C] | threes(Rest)];
threes([]) -> [].

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

system_image_round(Arguments) ->
    Said = erx_device_record:system_image(Arguments),
    case erx_device_record:record_volume(Arguments) =:= record_volume_reference(Arguments) of
        true -> ok;
        false -> error({record_volume_disagrees_with_reference, Arguments})
    end,
    case Said of
        {ok, Image} when is_map(Image) -> ok;
        {error, {bad_device_record, Text}} when is_list(Text) -> ok
    end,
    case verdict(Said) =:= system_image_reference(Arguments) of
        true when element(1, Said) =:= ok -> accepted;
        true -> refused;
        false -> error({disagrees_with_reference, Arguments, Said})
    end.

%% Both roles' answers agree with the reference, and no answer makes an atom, which an
%% unknown role word, often fresh here, would.
drives_round(Arguments) ->
    Atoms = erlang:system_info(atom_count),
    Said = [erx_device_record:drives(Role, Arguments) || Role <- [usb, block]],
    case erlang:system_info(atom_count) of
        Atoms -> ok;
        _ -> error({disagrees_with_reference, Arguments, made_an_atom})
    end,
    [ok = case Answer of {ok, Numbers} when is_list(Numbers) -> ok; {error, {bad_device_record, Text}} when is_list(Text) -> ok end
     || Answer <- Said],
    Read = [Words || ["drive" | Words] <- Arguments] =/= [],
    case [verdict(Answer) || Answer <- Said] =:= [drives_reference(Role, Arguments) || Role <- ["usb", "block"]] of
        true when element(1, hd(Said)) =:= ok, Read -> accepted;
        true -> refused;
        false -> error({disagrees_with_reference, Arguments, Said})
    end.

%% Every drive record two words, usb or block and a decimal below mf_none; no number twice;
%% at most usb_drives_max usb and one block. The sorted numbers of Role's.
drives_reference(Role, Arguments) ->
    Records = [Words || ["drive" | Words] <- Arguments],
    Read = [{R, decimal(N, ?ERX_MF_NONE - 1)} || [R, N] <- Records, R =:= "usb" orelse R =:= "block"],
    Numbers = [N || {_, N} <- Read],
    Distinct = maps:size(maps:from_keys(Numbers, true)) =:= length(Numbers),
    Fits = length(Read) =:= length(Records) andalso lists:all(fun is_integer/1, Numbers) andalso Distinct
        andalso length([u || {"usb", _} <- Read]) =< ?ERX_USB_DRIVES_MAX andalso length([b || {"block", _} <- Read]) =< 1,
    case Fits of
        true -> {ok, lists:sort([N || {R, N} <- Read, R =:= Role])};
        false -> {error, bad_device_record}
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

spec("given", [Path, Window, Offset, Size, Line, Mark, Memory, Bytes, Clock, Coherent, Mac, Index | _]) ->
    case {[decimal(Word, ?U64) || Word <- [Window, Offset, Size, Line, Memory, Bytes]], decimal(Clock, ?U32),
          decimal(Mac, ?U48), decimal(Index, ?U32), node_path(Path)} of
        {[W, O, S, L, M, B], C, A, I, P} when is_integer(W), is_integer(O), is_integer(S), is_integer(L), is_integer(M),
                                           is_integer(B), is_integer(C), is_integer(A), is_integer(I),
                                           (Mark =:= "direct" orelse Mark =:= "shared"),
                                           (Coherent =:= "0" orelse Coherent =:= "1"),
                                           is_binary(P), not (L =:= 0 andalso Mark =:= "shared") ->
            Spec = #{peripheral => virtio_mmio, path => P, window => {object, W, O, S}, lines => [marked({object, L}, Mark) || L =/= 0],
                     clock => C, coherent => Coherent =:= "1", index => I},
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
spec("device", [Path, Base, Size, Line, Mark, Clock, Index, Off, On | _]) ->
    case {decimal(Base, ?U64), decimal(Size, ?U64), decimal(Line, ?U32), decimal(Clock, ?U32), decimal(Index, ?U32),
          node_path(Path), {decimal(Off, ?U16), decimal(On, ?U16)}} of
        {B, S, L, C, I, P, {F, N}} when is_integer(B), is_integer(S), is_integer(L), is_integer(C), is_integer(I),
                                        is_binary(P), (Mark =:= "direct" orelse Mark =:= "shared"),
                                        is_integer(F), is_integer(N), (F > 0) =:= (N > 0) ->
            Spec = #{peripheral => virtio_mmio, path => P, window => {physical, B, S}, lines => [marked(L, Mark)],
                     clock => C, index => I},
            case F of
                0 -> Spec;
                _ -> Spec#{power => {F, N}}
            end;
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

%% Exactly one system_image record of five words: three decimals of 64 bits, a salt of 1 to
%% 32 bytes and a root hash of 32, both in lowercase hex; and a sixth, record_volume, or
%% none.
system_image_reference(Arguments) ->
    case [Words || ["system_image" | Words] <- Arguments] of
        [[Length, Offset, Tree, Salt, Root]] -> image_reference(Length, Offset, Tree, Salt, Root);
        [[Length, Offset, Tree, Salt, Root, "record_volume"]] -> image_reference(Length, Offset, Tree, Salt, Root);
        _ -> {error, bad_device_record}
    end.

image_reference(Length, Offset, Tree, Salt, Root) ->
    case {[decimal(Word, ?U64) || Word <- [Length, Offset, Tree]], lower_hex(Salt, "{1,32}"), lower_hex(Root, "{32}")} of
        {[L, O, T], S, R} when is_integer(L), is_integer(O), is_integer(T), is_binary(S), is_binary(R) ->
            {ok, #{image_offset => 0, image_length => L, tree_offset => O, tree_length => T, salt => S, root_hash => R}};
        _ ->
            {error, bad_device_record}
    end.

%% The record names the window when the reference takes it and it has six words.
record_volume_reference(Arguments) ->
    element(1, system_image_reference(Arguments)) =:= ok andalso
        [length(Words) || ["system_image" | Words] <- Arguments] =:= [6].

%% Pairs of lowercase hex digits, as many as Count says, as the bytes they spell.
lower_hex(Word, Count) ->
    case re:run(Word, "\\A(?:[0-9a-f]{2})" ++ Count ++ "\\z", [unicode, {capture, none}]) of
        match -> << <<(list_to_integer([A, B], 16))>> || [A, B] <- pairs(Word) >>;
        nomatch -> bad
    end.

pairs([A, B | Rest]) -> [[A, B] | pairs(Rest)];
pairs([]) -> [].

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
    [entry() || _ <- lists:seq(1, rand:uniform(?MAX_ENTRIES + 1) - 1)] ++ drive_set().

%% One round in six also carries a whole set of drive records of distinct numbers, up to
%% usb_drives_max + 1 usb and up to two block, so both bounds are reached often.
drive_set() ->
    Run = fun(Role, Count, First) -> [["drive", Role, integer_to_list(First + N)] || N <- lists:seq(1, Count)] end,
    case rand:uniform(6) of
        1 -> Run("usb", rand:uniform(?ERX_USB_DRIVES_MAX + 2) - 1, 10) ++ Run("block", rand:uniform(3) - 1, 20);
        _ -> []
    end.

%% Half of the entries are records of the asked role and peripheral, in either form, half of
%% those with their form's count of number words and a mark word after the line, the numbers
%% some within their fields and some just past them and the mark mostly direct or shared, so
%% the accepting path, both marks and the field bounds are reached often.
entry() ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Words = [word() || _ <- lists:seq(1, rand:uniform(?MAX_WORDS + 1) - 1)],
    Form = Pick(["device", "given"]),
    %% The numbers before the mark word and after it.
    Count = #{"device" => {3, 4}, "given" => {4, 6}},
    {Before, After} = maps:get(Form, Count),
    %% Half the time each number is 0 or 1, which fits every field, COHERENT's included, so a
    %% record of a given's ten numbers is still accepted often.
    Number = Pick([fun number/0, fun() -> Pick(["0", "1"]) end]),
    Numbers = fun(N) -> [Number() || _ <- lists:seq(1, N)] end,
    case rand:uniform(7) of
        7 -> Pick([function_entry(Words), drive_entry()]);
        6 -> system_image_entry();
        5 -> framebuffer_entry(Words);
        1 -> [Form, "block", "virtio_mmio" | Words];
        2 -> [Form, "block", "virtio_mmio", path() | Numbers(Before) ++ [mark() | Numbers(After)] ++ Words];
        3 -> [Pick(["device", "given", "console"]), Pick(["block", "network", ""]),
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

%% A system_image record, most of five words, some of six whose sixth is record_volume,
%% each nearly always well formed so the accepting path is reached often, and otherwise at
%% or just past its bound: a salt of no bytes, of one digit or of 33 bytes, an odd count or
%% an upper-case digit, a root hash a byte short or long.
system_image_entry() ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Hex = fun(Bytes) -> [Pick("0123456789abcdef") || _ <- lists:seq(1, 2 * Bytes)] end,
    Salt = Pick([Hex(1), Hex(32), Hex(rand:uniform(32)), Hex(rand:uniform(32)), Hex(rand:uniform(32)),
                 "", "a", Hex(33), Hex(2) ++ "a", "A5", "g0"]),
    Root = Pick([Hex(32), Hex(32), Hex(32), Hex(32), Hex(31), Hex(33), Hex(31) ++ "a", "F" ++ Hex(31) ++ "f", ""]),
    Fields = [number(), number(), number(), Salt, Root],
    case rand:uniform(6) of
        1 -> ["system_image" | lists:sublist(Fields, rand:uniform(5) - 1)];
        2 -> ["system_image" | Fields ++ [word()]];
        3 -> ["system_image" | Fields ++ ["record_volume"]];
        _ -> ["system_image" | Fields]
    end.

%% A function record of usb and xhci, most fields well formed so the accepting path is
%% reached often, each otherwise at or just past its bound: a place one past its largest or
%% with a leading zero, a null line marked shared, a route the writer never spells, the
%% first placed BAR not BAR 0, a placed BAR under 16 bytes or over 2 to
%% pcie_bar_size_log2_max, or none placed, an MSI-X table in another BAR, of no entries or
%% 2049, or ending a byte past its BAR; some records too short, some run on into other words.
function_entry(Words) ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Often = fun(Good, Bad) -> case rand:uniform(12) of 1 -> Pick(Bad); _ -> Good end end,
    Null = integer_to_list(?ERX_CAP_NULL),
    Log2 = Often(Pick([4, 14, ?ERX_PCIE_BAR_SIZE_LOG2_MAX]), [3, ?ERX_PCIE_BAR_SIZE_LOG2_MAX + 1]),
    Entries = Often(Pick([1, 16, 2048]), [0, 2049]),
    Offset = Often(Pick([0, (1 bsl Log2) - 16 * Entries]), [(1 bsl Log2) - 16 * Entries + 1]),
    First = Often(0, [1, 5, none]),
    Table = Often(case First of none -> 0; _ -> First end, [1, 6]),
    Bar = fun(At) when At =:= First -> [Pick(["11", number()]), Pick(["0", number()]), integer_to_list(Log2)];
             (At) when First =:= none; At < First -> [Null, Pick(["0", "4096"]), Pick(["0", "14", "40"])];
             (_At) -> Pick([[Null, "0", "0"], ["12", "0", Often(Pick(["12", "20"]), ["3", "32", "x"])]])
          end,
    Record = ["function", "usb", "xhci", Often(Pick(["0", "4294967295"]), [number()]),
              Often(Pick(["0", "255"]), ["256", "0255"]),
              Often(Pick(["0", "31"]), ["32", "031"]), Often(Pick(["0", "7"]), ["8"]), Pick(["9", Null]),
              Often(Pick(["direct", "shared"]), [mark()]), Pick(["10", number()]), Pick(["0", "65536", number()]),
              Often(Pick(["0", "1"]), ["2", ""]), Often(Pick(["none", "msi", "msix", "msix", "intx"]), ["MSIX", ""]),
              number(), Often(Pick(["17", "4294967295"]), [number()]), integer_to_list(Table), integer_to_list(Offset),
              integer_to_list(Entries)
              | lists:append([Bar(At) || At <- lists:seq(0, 5)])],
    case rand:uniform(8) of
        1 -> lists:sublist(Record, rand:uniform(length(Record)) - 1);
        2 -> Record ++ Words;
        _ -> Record
    end.

%% A drive record, most of two words, usb more often than block, and a number at or near its
%% bounds, so that distinct well formed sets are common and five usb or two block occur;
%% otherwise a role word of another spelling or one never seen, which an atom would keep,
%% a third word or a missing one.
drive_entry() ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Number = Pick(["0", "1", "2", "3", "4", integer_to_list(rand:uniform(1000)), "4294967294", "4294967295",
                   "04294967294", "", "-1", "1 "]),
    Role = Pick(["usb", "usb", "usb", "block", "Usb", "block ", "fat", "role" ++ integer_to_list(rand:uniform(1 bsl 40))]),
    case rand:uniform(8) of
        1 -> ["drive", Role, Number, Pick(["0", "usb", word()])];
        2 -> lists:sublist(["drive", Role, Number], rand:uniform(2));
        _ -> ["drive", Role, Number]
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
