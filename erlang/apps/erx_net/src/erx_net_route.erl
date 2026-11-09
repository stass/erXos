%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_route).
-moduledoc """
The route table and its longest-prefix lookup (docs/design-network-stack.md,
"Addresses and routes"). This is erXos's own code: the stack needs nothing
of FreeBSD's forwarding tables, only a small table on a host.

A row is one route an interface process learnt, from its configuration,
a router advertisement or its DHCP client, keyed by its prefix, prefix
length and interface (`key()`). The table holds both families. Rows are
stored with the bits past their prefix cleared, so two rows for the same
prefix written differently are one row.

`lookup/2` returns the row with the longest prefix that contains the
destination; among rows of equal prefix, the lowest metric, then the
lowest interface name in Erlang's term order, so the answer does not
depend on the order rows were written. `lookup/3` looks only at one
interface's rows, as a scoped destination (a link-local address with its
zone) needs.

A row's key includes no gateway, so an interface has one route per
prefix: a second gateway for the same prefix on the same interface
replaces the first, which suits the one installed default router of
`erx_nd6_rtr` and a static configuration's one gateway.

The table's own generation counts the changes of its rows and nothing
else; it serves its owner and tests. What a sender keeps is not this but
the configuration generation of `erx_net_gen`, with the path
`erx_net_frame` built from the published rows, and a sender builds its
path again when that generation moves (docs/design-network-stack.md,
"What owners publish"). The published route table holds each row with the
pid of the interface incarnation that wrote it (`published()`).
""".

-export([new/0, put/2, delete/2, delete_interface/2, lookup/2, lookup/3,
         generation/1, rows/1]).

-export_type([row/0, published/0, key/0, table/0]).

-doc """
A route: destinations within Prefix/Plen leave through interface Ifname,
to Gateway or, when it is `none`, directly to the destination on the link.
""".
-type row() :: #{prefix := erx_net_addr:addr(), plen := 0..128, ifname := term(),
                 gateway := erx_net_addr:addr() | none, metric := non_neg_integer()}.

-doc "A row as `erx_net_routes` holds it: the pid of the interface that wrote it, and the row.".
-type published() :: {pid(), row()}.

-type key() :: {Prefix :: erx_net_addr:addr(), Plen :: 0..128, Ifname :: term()}.

-doc """
The rows by key, and an index from family and prefix length to the
masked prefixes of that length and the keys of their rows.
""".
-opaque table() :: #{gen := non_neg_integer(),
                     rows := #{key() => row()},
                     index := #{{4 | 16, 0..128} => #{erx_net_addr:addr() => [key()]}}}.

-doc "An empty table at generation 0.".
-spec new() -> table().
new() -> #{gen => 0, rows => #{}, index => #{}}.

-doc """
Adds Row, replacing the row of the same key. Fails with `badarg` unless
the prefix is 4 or 16 bytes, Plen fits it and the gateway, if any, is of
the same family.
""".
-spec put(row(), table()) -> table().
put(#{prefix := Prefix0, plen := Plen, ifname := Ifname, gateway := Gateway,
      metric := Metric} = Row0, #{rows := Rows} = T)
  when is_binary(Prefix0), is_integer(Plen), Plen >= 0, is_integer(Metric), Metric >= 0 ->
    Size = byte_size(Prefix0),
    case valid_family(Size) andalso Plen =< 8 * Size andalso valid_gateway(Gateway, Size) of
        true -> ok;
        false -> erlang:error(badarg)
    end,
    Prefix = erx_net_addr:masked(Prefix0, Plen),
    Row = Row0#{prefix := Prefix},
    Key = {Prefix, Plen, Ifname},
    case Rows of
        #{Key := Row} -> T;
        #{Key := _} -> bump(T#{rows := Rows#{Key := Row}});
        #{} -> bump(index_add(Key, T#{rows := Rows#{Key => Row}}))
    end;
put(_Row, _T) ->
    erlang:error(badarg).

valid_family(Size) -> Size =:= 4 orelse Size =:= 16.

valid_gateway(none, _Size) -> true;
valid_gateway(Gateway, Size) -> is_binary(Gateway) andalso byte_size(Gateway) =:= Size.

-doc "Removes the row of Key, if there is one.".
-spec delete(key(), table()) -> table().
delete(Key, #{rows := Rows} = T) ->
    case maps:is_key(Key, Rows) of
        true -> bump(index_remove(Key, T#{rows := maps:remove(Key, Rows)}));
        false -> T
    end.

-doc "Removes every row of interface Ifname, as when it goes down.".
-spec delete_interface(term(), table()) -> table().
delete_interface(Ifname, #{rows := Rows} = T) ->
    lists:foldl(fun delete/2, T, [Key || {_, _, If} = Key <- maps:keys(Rows), If =:= Ifname]).

-doc "The row with the longest prefix containing Dst, or `none`.".
-spec lookup(erx_net_addr:addr(), table()) -> {ok, row()} | none.
lookup(Dst, T) -> find(Dst, fun(_Key) -> true end, T).

-doc "As `lookup/2`, over the rows of interface Ifname alone.".
-spec lookup(erx_net_addr:addr(), term(), table()) -> {ok, row()} | none.
lookup(Dst, Ifname, T) -> find(Dst, fun({_, _, If}) -> If =:= Ifname end, T).

-doc "The count of changes to the table's rows, not the configuration generation.".
-spec generation(table()) -> non_neg_integer().
generation(#{gen := Gen}) -> Gen.

-doc "Every row, in no particular order.".
-spec rows(table()) -> [row()].
rows(#{rows := Rows}) -> maps:values(Rows).

%% Walks the prefix lengths present for Dst's family from the longest
%% down and returns the best row of the first length whose bucket holds
%% Dst's prefix and a key Keep admits.
find(Dst, Keep, #{rows := Rows, index := Index}) when is_binary(Dst) ->
    Size = byte_size(Dst),
    Plens = lists:sort(fun erlang:'>='/2, [Plen || {S, Plen} <- maps:keys(Index), S =:= Size]),
    find_longest(Plens, Dst, Keep, Rows, Index).

find_longest([], _Dst, _Keep, _Rows, _Index) ->
    none;
find_longest([Plen | Plens], Dst, Keep, Rows, Index) ->
    Bucket = maps:get({byte_size(Dst), Plen}, Index),
    case [maps:get(Key, Rows) || Key <- maps:get(erx_net_addr:masked(Dst, Plen), Bucket, []),
                                 Keep(Key)] of
        [] -> find_longest(Plens, Dst, Keep, Rows, Index);
        Candidates -> {ok, best(Candidates)}
    end.

best(Candidates) ->
    [{_, Row} | _] = lists:keysort(1, [{{M, If}, R} || #{metric := M, ifname := If} = R <- Candidates]),
    Row.

index_add({Prefix, Plen, _} = Key, #{index := Index} = T) ->
    Slot = {byte_size(Prefix), Plen},
    Bucket = maps:get(Slot, Index, #{}),
    T#{index := Index#{Slot => Bucket#{Prefix => [Key | maps:get(Prefix, Bucket, [])]}}}.

index_remove({Prefix, Plen, _} = Key, #{index := Index} = T) ->
    Slot = {byte_size(Prefix), Plen},
    #{Slot := #{Prefix := Keys} = Bucket} = Index,
    Bucket2 = case lists:delete(Key, Keys) of
                  [] -> maps:remove(Prefix, Bucket);
                  Rest -> Bucket#{Prefix := Rest}
              end,
    Index2 = case map_size(Bucket2) of
                 0 -> maps:remove(Slot, Index);
                 _ -> Index#{Slot := Bucket2}
             end,
    T#{index := Index2}.

bump(#{gen := Gen} = T) -> T#{gen := Gen + 1}.
