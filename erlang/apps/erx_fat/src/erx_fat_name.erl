%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fat_name).
-moduledoc """
FAT's names (docs/design-storage.md, "Removable media: FAT", "Names"), pure: which
names a volume may hold, how two compare, and the entries that store one.

* **A name** is UTF-8 in the protocol and UTF-16 on the medium. One the server
  creates is valid UTF-8, not empty, not `.` or `..`, holds none of `"*/:<>?\|`
  and no control below 0x20, neither starts nor ends with a space nor ends with a
  period (`einval`), and fits 255 UTF-16 code units and 255 bytes of UTF-8, the
  read path's bound (`enametoolong`).
* **Comparison** maps each UTF-16 code unit to its simple uppercase form through
  erx_fat_case, the table generated from one pinned Unicode version; a surrogate
  maps to itself, so letters beyond the Basic Multilingual Plane compare by case.
* **The short name** of a new name is built as the FAT specification's basis-name
  rule describes (section 7.4, unverified here): ASCII letters uppercased, digits
  and the symbols it allows kept, spaces and periods other than the extension's
  dropped and every other character an underscore, the base cut to 8 characters
  and the extension, after the last period, to 3. A name whose parts each fit and
  each hold one case is stored as its short name alone, with Windows NT's case
  flags; a lossy or cut one, or one whose short form is taken, takes the least
  free numeric tail and no other form, `~1` upwards as FreeBSD's msdosfs numbers
  its generations (`uniqdosname`, sys/fs/msdosfs/msdosfs_lookup.c:1056-1062 at
  release/14.3.0), at most `~999999`; any other is its basis with long-name
  entries. A directory is read once for a new name: claim/2 says which of the
  basis's short names each short entry holds, and short_name/3 picks from what the
  claims leave free.
* **Long-name entries** hold 13 code units each, the last first on the medium with
  its order flagged, padded with one zero unit and then 0xFFFF, each carrying the
  short entry's checksum (section 7).
""".

-export([check/1, valid/1, key/1, match/1, match/3, matched/1, checksum/1, short_basis/1, claim/2, short_name/3,
         long_entries/2]).
-export_type([basis/0, match/0, short/0]).

-define(NAME_BYTES_MAX, 255).
-define(NAME_UNITS_MAX, 255).
-define(UNITS_PER_ENTRY, 13).
%% The largest numeric tail, six digits, more than a directory's 65,536 entries can
%% take; FreeBSD's own bound lies in its unix2dosfn (msdosfs_conv.c), unread here.
-define(TAIL_MAX, 999999).

-include("erx_fat_entry.hrl").

%% A short name: its 11 bytes, its case flags, and whether long-name entries must
%% carry the name beside it.
-type short() :: {<<_:88>>, 0..16#18, short_only | long}.
%% A name's basis (section 7.4): its base and extension as short-name characters,
%% and whether the name is exactly them: {cased, Flags} when each part holds one
%% case, mixed when one mixes them, inexact when a character was dropped or
%% replaced or a part cut.
%% A search for a name among a directory's names: the name, its key or none when it
%% is not valid UTF-8, how the best name so far matched, and that name's value.
-opaque match() :: {binary(), binary() | none, exact | equal | none, term()}.
-opaque basis() :: {string(), string(), {cased, 0..16#18} | mixed | inexact}.

-doc """
A name the server may create, as its UTF-16 code units, or why not: `einval` for
a character, a form or bytes the rules above refuse, `enametoolong` past the bound.
""".
-spec check(binary()) -> {ok, binary()} | {error, einval | enametoolong}.
check(Name) when is_binary(Name) ->
    case unicode:characters_to_binary(Name, utf8, {utf16, little}) of
        Units when is_binary(Units), byte_size(Name) =< ?NAME_BYTES_MAX, byte_size(Units) div 2 =< ?NAME_UNITS_MAX ->
            case valid(Name) of none -> {error, einval}; _ -> {ok, Units} end;
        Units when is_binary(Units) -> {error, enametoolong};
        _ -> {error, einval}
    end.

-doc """
Name when the volume may serve it: not empty, not `.` or `..`, no character the
specification forbids, not starting with a space or ending with a space or a
period; anything else is none. The read path's filter for names from the medium.
""".
-spec valid(binary()) -> binary() | none.
valid(Name) ->
    Forbidden = fun(C) -> C < 16#20 orelse lists:member(C, "\"*/:<>?\\|") end,
    case unicode:characters_to_list(Name) of
        [First | _] = Chars when First =/= $\s ->
            Last = lists:last(Chars),
            case Last =/= $\s andalso Last =/= $. andalso not lists:any(Forbidden, Chars) of
                true -> Name;
                false -> none
            end;
        _ ->
            none
    end.

-doc "The form two names compare equal by: valid UTF-8 Name's code units, each uppercased.".
-spec key(binary()) -> binary().
key(Name) ->
    << <<(erx_fat_case:upper(Unit)):16>> || <<Unit:16/little>> <= unicode:characters_to_binary(Name, utf8, {utf16, little}) >>.

-doc """
A search for name Name among a directory's names, fed each with match/3: the name
with Name's bytes, else the first that compares equal to it.
""".
-spec match(binary()) -> match().
match(Name) ->
    Key = case unicode:characters_to_binary(Name, utf8, {utf16, little}) of
              Units when is_binary(Units) -> key(Name);
              _ -> none
          end,
    {Name, Key, none, none}.

-doc "Search Match after the directory's next name, Other, whose value is Value.".
-spec match(match(), binary(), term()) -> match().
match({_, _, exact, _} = Match, _Other, _Value) -> Match;
match({Name, Key, _, _}, Name, Value) -> {Name, Key, exact, Value};
match({Name, Key, none, _} = Match, Other, Value) when Key =/= none ->
    case key(Other) =:= Key of
        true -> {Name, Key, equal, Value};
        false -> Match
    end;
match(Match, _Other, _Value) -> Match.

-doc "The value of the name the search found, or none.".
-spec matched(match()) -> term() | none.
matched({_, _, none, _}) -> none;
matched({_, _, _, Value}) -> Value.

-doc "A short name's checksum, which its long-name entries carry (section 7.2).".
-spec checksum(<<_:88>>) -> byte().
checksum(Short) ->
    lists:foldl(fun(Byte, Sum) -> (((Sum band 1) bsl 7) + (Sum bsr 1) + Byte) band 16#ff end, 0,
                binary_to_list(Short)).

-doc "The basis of checked name Name, from which its short name is made (short_name/3).".
-spec short_basis(binary()) -> basis().
short_basis(Name) -> basis(unicode:characters_to_list(Name)).

-doc """
Which of Basis's short names short name Short holds: the basis itself, the one of
numeric tail N, or none of them.
""".
-spec claim(basis(), <<_:88>>) -> basis | pos_integer() | none.
claim({Base, Extension, _Exact}, Short) ->
    <<Head:8/binary, _:3/binary>> = Short,
    Digits = lists:reverse(lists:takewhile(fun(C) -> C >= $0 andalso C =< $9 end,
                                           lists:reverse(string:trim(binary_to_list(Head), trailing, " ")))),
    case Short =:= padded(Base, Extension) of
        true -> basis;
        false when Digits =/= [], length(Digits) =< 6 ->
            N = list_to_integer(Digits),
            case N >= 1 andalso tailed(Base, Extension, N) =:= Short of
                true -> N;
                false -> none
            end;
        false -> none
    end.

-doc """
The short name of Basis in a directory where BasisTaken says whether the basis
itself is held and TailTaken whether the short name of a numeric tail is (see the
module's doc).
""".
-spec short_name(basis(), boolean(), fun((pos_integer()) -> boolean())) -> short().
short_name({Base, Extension, Exact}, BasisTaken, TailTaken) ->
    Short = padded(Base, Extension),
    case {Exact, BasisTaken} of
        {{cased, Flags}, false} -> {Short, Flags, short_only};
        {mixed, false} -> {Short, 0, long};
        _ -> {tailed(Base, Extension, free_tail(TailTaken, 1)), 0, long}
    end.

basis(Chars) ->
    Stripped = lists:dropwhile(fun(C) -> C =:= $. end, Chars),
    {BaseChars, ExtChars} = case string:split(Stripped, ".", trailing) of
                                [B, E] -> {B, E};
                                [B] -> {B, []}
                            end,
    {Base0, LossyB} = mapped(BaseChars),
    {Extension, LossyE} = mapped(ExtChars),
    Base = case Base0 of [] -> "_"; _ -> Base0 end,
    Exact = Stripped =:= Chars andalso not LossyB andalso not LossyE andalso Base0 =/= []
        andalso length(Base) =< 8 andalso length(Extension) =< 3,
    {lists:sublist(Base, 8), lists:sublist(Extension, 3),
     case Exact of
         true -> case {case_of(BaseChars), case_of(ExtChars)} of
                     {mixed, _} -> mixed;
                     {_, mixed} -> mixed;
                     {CB, CE} -> {cased, flag(CB, ?LOWER_BASE) bor flag(CE, ?LOWER_EXTENSION)}
                 end;
         false -> inexact
     end}.

%% Chars as short-name characters, and whether any was dropped or replaced.
mapped(Chars) ->
    lists:foldr(fun(C, {Got, Lossy}) ->
                        case short_char(C) of
                            drop -> {Got, true};
                            C -> {[C | Got], Lossy};
                            Other -> {[Other | Got], Lossy orelse not (C >= $a andalso C =< $z)}
                        end
                end, {[], false}, Chars).

short_char(C) when C >= $a, C =< $z -> C - 32;
short_char(C) when C >= $A, C =< $Z; C >= $0, C =< $9 -> C;
short_char(C) when C =:= $\s; C =:= $. -> drop;
short_char(C) ->
    case lists:member(C, "$%'-_@~`!(){}^#&") of
        true -> C;
        false -> $_
    end.

case_of(Chars) ->
    Lower = lists:any(fun(C) -> C >= $a andalso C =< $z end, Chars),
    Upper = lists:any(fun(C) -> C >= $A andalso C =< $Z end, Chars),
    case {Lower, Upper} of
        {true, true} -> mixed;
        {true, false} -> lower;
        _ -> upper
    end.

flag(lower, Flag) -> Flag;
flag(_, _Flag) -> 0.

free_tail(TailTaken, N) when N =< ?TAIL_MAX ->
    case TailTaken(N) of
        true -> free_tail(TailTaken, N + 1);
        false -> N
    end.

tailed(Base, Extension, N) ->
    Tail = [$~ | integer_to_list(N)],
    padded(lists:sublist(Base, 8 - length(Tail)) ++ Tail, Extension).

padded(Base, Extension) ->
    list_to_binary(string:pad(Base, 8, trailing, $\s) ++ string:pad(Extension, 3, trailing, $\s)).

-doc """
The long-name entries of a name of UTF-16 code units Units beside short name Short,
in the order the medium holds them, the last part first.
""".
-spec long_entries(binary(), <<_:88>>) -> [<<_:256>>].
long_entries(Units, Short) ->
    Count = (byte_size(Units) div 2 + ?UNITS_PER_ENTRY - 1) div ?UNITS_PER_ENTRY,
    Padded = padded_units(Units, Count * ?UNITS_PER_ENTRY * 2),
    Sum = checksum(Short),
    [erx_fat_entry:long(Order, Order =:= Count, Sum, binary:part(Padded, (Order - 1) * 26, 26))
     || Order <- lists:seq(Count, 1, -1)].

padded_units(Units, Size) when byte_size(Units) =:= Size -> Units;
padded_units(Units, Size) ->
    Fill = binary:copy(<<16#ffff:16>>, (Size - byte_size(Units)) div 2 - 1),
    <<Units/binary, 0:16, Fill/binary>>.
