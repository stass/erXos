%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_passphrase_hash).
-moduledoc """
Root's passphrase record and its derivation, before the vault
(docs/design-login.md, "The passphrase check"; docs/design-ssh.md, "Root's
passphrase on the medium").

* **The record** is the one form root's passphrase hash takes between the
  storage domain, which makes it from the medium's line (erx_boot_passphrase),
  and the system domain, which checks a passphrase against it:
  `<<Rounds:32, Hash:32/binary, Salt/binary>>`, Rounds from 1000 to 100000
  and a salt of 1 to 16 characters of crypt's alphabet. This module alone lays
  it out: encode/1 writes it and decode/1, the system domain's reader of bytes
  another domain served, checks it after one length check.
* **The derivation** is crypt(3)'s SHA-256, `$5$` (FreeBSD 14.3.0,
  lib/libcrypt/crypt-sha256.c), over erx_bytes:sha256/1. Each step hashes the
  concatenation of what crypt-sha256.c feeds one context, which is the same
  digest.
* **The comparison** reads every byte of both hashes whatever they hold, so
  its time tells nothing of where they differ.
""".

-export([encode/1, decode/1, derive/3, matches/2]).
-export([rounds_min/0, rounds_max/0, salt_max/0, record_max/0, alphabet/1]).
-export_type([passphrase_record/0]).

-define(ROUNDS_MIN, 1000).
-define(ROUNDS_MAX, 100000).
-define(SALT_MAX, 16).
-define(HASH_SIZE, 32).

-doc "Root's passphrase record: the rounds, the salt and the 32-byte hash.".
-type passphrase_record() :: #{rounds := ?ROUNDS_MIN..?ROUNDS_MAX, salt := binary(), hash := <<_:256>>}.

-doc "The fewest rounds a record holds, crypt-sha256.c's ROUNDS_MIN.".
-spec rounds_min() -> pos_integer().
rounds_min() -> ?ROUNDS_MIN.

-doc "The most rounds a record holds, which bounds one check's derivation.".
-spec rounds_max() -> pos_integer().
rounds_max() -> ?ROUNDS_MAX.

-doc "The longest salt, crypt-sha256.c's SALT_LEN_MAX.".
-spec salt_max() -> pos_integer().
salt_max() -> ?SALT_MAX.

-doc "The longest record, in bytes.".
-spec record_max() -> pos_integer().
record_max() -> 4 + ?HASH_SIZE + ?SALT_MAX.

-doc "True when `Byte` is one of crypt's 64 characters, `./0-9A-Za-z`.".
-spec alphabet(byte()) -> boolean().
alphabet(Byte) ->
    Byte =:= $. orelse Byte =:= $/ orelse (Byte >= $0 andalso Byte =< $9)
        orelse (Byte >= $A andalso Byte =< $Z) orelse (Byte >= $a andalso Byte =< $z).

-doc "The record's bytes, or `malformed` when its rounds or salt are out of bounds.".
-spec encode(#{rounds := integer(), salt := binary(), hash := <<_:256>>}) -> {ok, binary()} | {error, malformed}.
encode(#{rounds := Rounds, salt := Salt, hash := <<_:?HASH_SIZE/binary>> = Hash}) ->
    case checked(Rounds, Salt, Hash) of
        {ok, _} -> {ok, <<Rounds:32, Hash/binary, Salt/binary>>};
        {error, malformed} = Error -> Error
    end.

-doc "The record `Bytes` holds, or `malformed`.".
-spec decode(binary()) -> {ok, passphrase_record()} | {error, malformed}.
decode(Bytes) when is_binary(Bytes), byte_size(Bytes) > 4 + ?HASH_SIZE, byte_size(Bytes) =< 4 + ?HASH_SIZE + ?SALT_MAX ->
    <<Rounds:32, Hash:?HASH_SIZE/binary, Salt/binary>> = Bytes,
    checked(Rounds, Salt, Hash);
decode(_Bytes) ->
    {error, malformed}.

checked(Rounds, Salt, Hash) ->
    case Rounds >= ?ROUNDS_MIN andalso Rounds =< ?ROUNDS_MAX
        andalso byte_size(Salt) >= 1 andalso byte_size(Salt) =< ?SALT_MAX
        andalso lists:all(fun alphabet/1, binary_to_list(Salt)) of
        true -> {ok, #{rounds => Rounds, salt => Salt, hash => Hash}};
        false -> {error, malformed}
    end.

-doc """
True when `Passphrase` derives `Record`'s hash under its salt and rounds. The
derivation always runs whole and the comparison reads all 32 bytes.
""".
-spec matches(binary(), passphrase_record()) -> boolean().
matches(Passphrase, #{rounds := Rounds, salt := Salt, hash := Hash}) ->
    equal(derive(Passphrase, Salt, Rounds), Hash).

%% Every byte pair is read and folded into one difference, so no byte's value
%% ends the comparison early.
equal(<<A:?HASH_SIZE/binary>>, <<B:?HASH_SIZE/binary>>) ->
    0 =:= lists:foldl(fun({X, Y}, Diff) -> Diff bor (X bxor Y) end, 0,
                      lists:zip(binary_to_list(A), binary_to_list(B))).

-doc """
crypt(3)'s SHA-256 of `Key` under `Salt` and `Rounds`: the 32 bytes the `$5$`
string's last field spells (crypt-sha256.c, crypt_sha256()).
""".
-spec derive(binary(), binary(), pos_integer()) -> <<_:256>>.
derive(Key, Salt, Rounds) when is_binary(Key), is_binary(Salt), is_integer(Rounds), Rounds >= 1 ->
    Length = byte_size(Key),
    %% The alternate sum of key, salt and key; then the first sum: key, salt, the
    %% alternate sum's bytes for each byte of the key, and for each bit of the key's
    %% length from the lowest, the alternate sum for a 1 and the key for a 0.
    Alternate = sha([Key, Salt, Key]),
    Bits = [case Bit of 1 -> Alternate; 0 -> Key end || Bit <- bits(Length)],
    Start = sha([Key, Salt, cycled(Alternate, Length), Bits]),
    %% P: the sum of the key once for each of its bytes, as long as the key; S: the
    %% sum of the salt 16 + Start's first byte times, as long as the salt.
    P = cycled(sha(lists:duplicate(Length, Key)), Length),
    <<First, _/binary>> = Start,
    S = cycled(sha(lists:duplicate(16 + First, Salt)), byte_size(Salt)),
    rounds(0, Rounds, Start, P, S).

rounds(Rounds, Rounds, Sum, _P, _S) ->
    Sum;
rounds(Round, Rounds, Sum, P, S) ->
    Odd = Round band 1 =:= 1,
    Parts = [case Odd of true -> P; false -> Sum end,
             [S || Round rem 3 =/= 0],
             [P || Round rem 7 =/= 0],
             case Odd of true -> Sum; false -> P end],
    rounds(Round + 1, Rounds, sha(Parts), P, S).

%% The low bits of N first, as crypt-sha256.c's `cnt >>= 1` loop reads them.
bits(0) -> [];
bits(N) -> [N band 1 | bits(N bsr 1)].

%% Bytes of Sum repeated until there are Length of them.
cycled(Sum, Length) ->
    binary:part(binary:copy(Sum, Length div byte_size(Sum) + 1), 0, Length).

sha(Parts) ->
    erx_bytes:sha256(iolist_to_binary(Parts)).
