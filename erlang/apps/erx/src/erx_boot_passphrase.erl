%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_boot_passphrase).
-moduledoc """
The reader of the record volume's `passphrase_hash` (docs/design-ssh.md,
"Root's passphrase on the medium"): one crypt(3) SHA-256 string, as FreeBSD
14.3.0's lib/libcrypt/crypt-sha256.c writes it, decoded into the record
erx_passphrase_hash lays out, which the `login_keys` tree serves as
`root_passphrase`.

The file is untrusted bytes from the medium. decode/1 is a pure function that
reads them through one cursor and fails at its first fault through one route,
a throw caught at decode/1; its fuzz target is tools/fuzz/erx_boot_passphrase.rb.
The accepted form:

    $5$[rounds=N$]SALT$HASH[\r]\n?

N from 1000 to 100000 in decimal with no leading zero; SALT 1 to 16 of crypt's
characters; HASH 43 of them, decoding to 32 bytes in crypt-sha256.c's order
with the last character's two spare bits zero, so each hash has one spelling.
The file is at most file_max/0 bytes.
""".

-export([decode/1, file_max/0]).
-export_type([refusal/0]).

-define(FILE_MAX, 128).
-define(HASH_CHARS, 43).

-doc "Why the file is refused.".
-type refusal() :: too_long | not_a_crypt_string.

-doc "The longest file the reader takes, in bytes.".
-spec file_max() -> pos_integer().
file_max() -> ?FILE_MAX.

-doc "The record `File` spells (erx_passphrase_hash:encode/1), or why there is none.".
-spec decode(binary()) -> {ok, binary()} | {error, refusal()}.
decode(File) when is_binary(File), byte_size(File) > ?FILE_MAX ->
    {error, too_long};
decode(File) when is_binary(File) ->
    try
        Rest0 = literal(<<"$5$">>, File),
        {Rounds, Rest1} = rounds(Rest0),
        {Salt, Rest2} = field(Rest1),
        {Spelled, Rest3} = take(?HASH_CHARS, Rest2),
        line_end(Rest3),
        case erx_passphrase_hash:encode(#{rounds => Rounds, salt => Salt, hash => hash(Spelled)}) of
            {ok, Record} -> {ok, Record};
            {error, malformed} -> fail()
        end
    catch
        throw:{?MODULE, Refusal} -> {error, Refusal}
    end.

fail() -> throw({?MODULE, not_a_crypt_string}).

literal(Prefix, Bytes) ->
    Size = byte_size(Prefix),
    case Bytes of
        <<Prefix:Size/binary, Rest/binary>> -> Rest;
        _ -> fail()
    end.

%% `rounds=N$`, or crypt-sha256.c's default of 5000 when the field is absent.
rounds(<<"rounds=", Rest/binary>>) ->
    {Digits, After} = until_dollar(Rest),
    {number(Digits), After};
rounds(Rest) ->
    {5000, Rest}.

number(<<First, _/binary>> = Digits) when First >= $1, First =< $9, byte_size(Digits) =< 6 ->
    lists:all(fun(D) -> D >= $0 andalso D =< $9 end, binary_to_list(Digits)) orelse fail(),
    binary_to_integer(Digits);
number(_) ->
    fail().

%% The salt, ended by `$`; erx_passphrase_hash:encode/1 checks its length and
%% characters, and the rounds' range, as it does for every record.
field(Bytes) ->
    until_dollar(Bytes).

until_dollar(Bytes) ->
    case binary:split(Bytes, <<"$">>) of
        [Field, Rest] -> {Field, Rest};
        [_] -> fail()
    end.

take(N, Bytes) ->
    case Bytes of
        <<Taken:N/binary, Rest/binary>> -> {Taken, Rest};
        _ -> fail()
    end.

line_end(<<>>) -> ok;
line_end(<<"\n">>) -> ok;
line_end(<<"\r\n">>) -> ok;
line_end(_) -> fail().

%% crypt-sha256.c spells the hash as ten groups of three bytes, each four characters
%% of the 24-bit word B2 B1 B0 from its low six bits, and a last group of the two
%% bytes 31 and 30 in three characters; these are the bytes' places, B2 first.
-define(GROUPS, [{0, 10, 20}, {21, 1, 11}, {12, 22, 2}, {3, 13, 23}, {24, 4, 14},
                 {15, 25, 5}, {6, 16, 26}, {27, 7, 17}, {18, 28, 8}, {9, 19, 29}]).

hash(Spelled) ->
    <<Groups:40/binary, Last:3/binary>> = Spelled,
    Placed = lists:append([placed(Places, word(Chars))
                           || {Places, Chars} <- lists:zip(?GROUPS, chunks(Groups))]),
    LastWord = word(Last),
    LastWord bsr 16 =:= 0 orelse fail(),
    Bytes = [{31, (LastWord bsr 8) band 255}, {30, LastWord band 255} | Placed],
    list_to_binary([Byte || {_, Byte} <- lists:keysort(1, Bytes)]).

chunks(<<>>) -> [];
chunks(<<Chars:4/binary, Rest/binary>>) -> [Chars | chunks(Rest)].

placed({B2, B1, B0}, Word) ->
    [{B2, Word bsr 16}, {B1, (Word bsr 8) band 255}, {B0, Word band 255}].

%% The word of up to four characters, the first the lowest six bits.
word(Chars) ->
    {Word, _} = lists:foldl(fun(Char, {Acc, Shift}) -> {Acc bor (value(Char) bsl Shift), Shift + 6} end,
                            {0, 0}, binary_to_list(Chars)),
    Word.

value($.) -> 0;
value($/) -> 1;
value(C) when C >= $0, C =< $9 -> C - $0 + 2;
value(C) when C >= $A, C =< $Z -> C - $A + 12;
value(C) when C >= $a, C =< $z -> C - $a + 38;
value(_) -> fail().
