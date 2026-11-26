%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_state).
-moduledoc """
The Bluetooth domain's stored state (docs/design-bluetooth.md, "Bonds and the store"): the
identity address and at most `bt_bonds_max` bonds, in a form with a version. What a store
returns is untrusted wherever its medium can be written, so `decode/1` reads it through
one cursor, bounds every count and length before it reads what they count, and refuses
any other version, a malformed field, octets left over and anything past
`bt_state_max`, at its first error. It makes no atom from what it reads: a subscription
names its characteristic by the service's and the characteristic's names as binaries,
which the store turns into the table's atoms only when a link asks for its bond.

The layout, every integer most significant octet first:

```text
state        = version:8 (2) address:48 count:8 bond{count}
bond         = id:128 type:8 (0 public, 1 random) identity:48 irk:128 ltk:128
               level:8 (0 unauthenticated, 1 authenticated)
               hash_length:8 (0 or 32) hash:hash_length*8
               subscriptions:8 subscription{subscriptions}
subscription = kind:8 (1 notify, 2 indicate) service_length:8 service
               characteristic_length:8 characteristic
```

The address, and a bond's identity of type 1, is a static random address
(`erx_smp_crypto:static_random/1`); a name is an
`abi/gatt` name, a lower-case letter and then at most 62 lower-case letters, digits and
underscores. No two bonds share an identity or an id, and a bond's subscriptions are in
ascending order of their names, so no characteristic is named twice and a state has one
blob. A bond's id is the store's draw ("A bond's name is made with its key"), which this
module only carries: 16 octets in the blob, and in every term the 32 lower-case
hexadecimal digits the design writes it as, so the blob is the one place of the octets. A hash of no octets is a bond never served a table's hash.
`encode/1` writes the same layout and refuses, as `too_large`, a state past
`bt_state_max`, and, as `duplicate_identity` or `duplicate_id`, one in which two bonds
share an identity or an id, so it never writes a state `decode/1` refuses. A blob of
any other version, an earlier one included, is refused as `{version, V}`: a state is
never converted, and the store that cannot read one starts without its bonds.
""".

-include("generated/erx_abi.hrl").

-export([encode/1, decode/1]).
-export_type([state/0, bond/0, id/0, name_key/0]).

-define(VERSION, 2).
-define(HASH_LENGTH, 32).
-define(NAME_MAX, 63).

-doc "A characteristic's key by name: the service's and the characteristic's names.".
-type name_key() :: {binary(), binary()}.
-doc "A bond's id: the 128 bits the store drew when it kept the bond, as 32 lower-case hexadecimal digits.".
-type id() :: <<_:256>>.
-doc """
A kept bond: its id, the phone's identity address and IRK, the LTK and its level, the table hash
it was last served (`<<>>` before any), and its subscriptions.
""".
-type bond() :: #{id := id(), identity := erx_smp_crypto:address(), irk := erx_smp_crypto:value(),
                  ltk := erx_smp_crypto:value(), level := authenticated | unauthenticated,
                  hash := binary(), subscriptions := #{name_key() => notify | indicate}}.
-type state() :: #{address := <<_:48>>, bonds := [bond()]}.

-doc """
The state's blob; or `too_large` past `bt_state_max` or `bt_bonds_max` bonds, or
`duplicate_identity` or `duplicate_id` when two bonds share an identity or an id.
""".
-spec encode(state()) -> {ok, binary()} | {error, too_large | duplicate_identity | duplicate_id}.
encode(#{address := Address, bonds := Bonds}) when length(Bonds) =< ?ERX_BT_BONDS_MAX ->
    Blob = iolist_to_binary([?VERSION, Address, length(Bonds) | [bond_octets(Bond) || Bond <- Bonds]]),
    if
        byte_size(Blob) > ?ERX_BT_STATE_MAX -> {error, too_large};
        true -> shared(Bonds, {ok, Blob})
    end;
encode(#{bonds := _}) ->
    {error, too_large}.

%% The first of two bonds sharing an identity or an id, or `Answer` when none do.
shared(Bonds, Answer) ->
    case {distinct([Identity || #{identity := Identity} <- Bonds]), distinct([Id || #{id := Id} <- Bonds])} of
        {false, _} -> {error, duplicate_identity};
        {true, false} -> {error, duplicate_id};
        {true, true} -> Answer
    end.

distinct(List) -> length(lists:usort(List)) =:= length(List).

bond_octets(#{id := <<_:256>> = Id, identity := {Type, Identity}, irk := Irk, ltk := Ltk, level := Level, hash := Hash,
              subscriptions := Subscriptions}) when byte_size(Hash) =:= 0; byte_size(Hash) =:= ?HASH_LENGTH ->
    [binary:decode_hex(Id), type_octet(Type), Identity, Irk, Ltk, level_octet(Level), byte_size(Hash), Hash,
     map_size(Subscriptions)
     | [[kind_octet(Kind), byte_size(Service), Service, byte_size(Char), Char]
        || {Service, Char} := Kind <- maps:iterator(Subscriptions, ordered)]].

type_octet(public) -> 0;
type_octet(random) -> 1.

level_octet(unauthenticated) -> 0;
level_octet(authenticated) -> 1.

kind_octet(notify) -> 1;
kind_octet(indicate) -> 2.

-doc "The state a blob holds, or the first reason it holds none.".
-spec decode(binary()) -> {ok, state()} | {error, term()}.
decode(Blob) when byte_size(Blob) > ?ERX_BT_STATE_MAX ->
    {error, too_large};
decode(Blob) ->
    try
        {ok, state(Blob)}
    catch
        throw:{state, Reason} -> {error, Reason}
    end.

state(<<?VERSION, Address:6/binary, Count, Rest/binary>>) ->
    erx_smp_crypto:static_random(Address) orelse refuse(address),
    Count =< ?ERX_BT_BONDS_MAX orelse refuse({too_many_bonds, Count}),
    {Bonds, _} = repeat(Count, fun bond/1, Rest, trailing),
    distinct([Identity || #{identity := Identity} <- Bonds]) orelse refuse(duplicate_identity),
    distinct([Id || #{id := Id} <- Bonds]) orelse refuse(duplicate_id),
    #{address => Address, bonds => Bonds};
state(<<?VERSION, _/binary>>) ->
    refuse(header);
state(<<Version, _/binary>>) ->
    refuse({version, Version});
state(<<>>) ->
    refuse(empty).

bond(<<Id:16/binary, Type, Identity:6/binary, Irk:16/binary, Ltk:16/binary, Level, HashLength, Rest/binary>>) ->
    HashLength =:= 0 orelse HashLength =:= ?HASH_LENGTH orelse refuse({hash_length, HashLength}),
    case Rest of
        <<Hash:HashLength/binary, Count, Subscriptions/binary>> ->
            {Pairs, After} = repeat(Count, fun subscription/1, Subscriptions, truncated),
            Keys = [Key || {Key, _} <- Pairs],
            lists:usort(Keys) =:= Keys orelse refuse(subscription_order),
            Map = maps:from_list(Pairs),
            {#{id => binary:encode_hex(Id, lowercase), identity => identity(Type, Identity), irk => Irk, ltk => Ltk, level => level(Level), hash => Hash,
               subscriptions => Map}, After};
        _ ->
            refuse(truncated)
    end;
bond(_) ->
    refuse(truncated).

subscription(<<Kind, ServiceLength, Service:ServiceLength/binary, CharLength, Char:CharLength/binary,
               Rest/binary>>) ->
    {{{name(Service), name(Char)}, kind(Kind)}, Rest};
subscription(_) ->
    refuse(truncated).

%% Reads Count items with Read, each from what the last left; the bytes after the last
%% must be empty when Left is `trailing`.
repeat(Count, Read, Bytes, Left) ->
    {Items, Rest} = lists:foldl(fun(_, {Acc, From}) ->
                                        {Item, Next} = Read(From),
                                        {[Item | Acc], Next}
                                end, {[], Bytes}, lists:seq(1, Count)),
    Left =:= trailing andalso Rest =/= <<>> andalso refuse(trailing),
    {lists:reverse(Items), Rest}.

identity(Type, Octets) ->
    case erx_smp_crypto:identity_address(Type, Octets) of
        {ok, Identity} -> Identity;
        error -> refuse(identity)
    end.

level(0) -> unauthenticated;
level(1) -> authenticated;
level(Octet) -> refuse({level, Octet}).

kind(1) -> notify;
kind(2) -> indicate;
kind(Octet) -> refuse({kind, Octet}).

name(<<First, Rest/binary>> = Name) when First >= $a, First =< $z, byte_size(Name) =< ?NAME_MAX ->
    lists:all(fun name_octet/1, binary_to_list(Rest)) orelse refuse(name),
    Name;
name(_) ->
    refuse(name).

name_octet(C) -> (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9) orelse C =:= $_.

-spec refuse(term()) -> no_return().
refuse(Reason) -> throw({state, Reason}).
