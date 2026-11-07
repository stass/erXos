%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_sort).
-moduledoc """
`sort [-r] [-k field] ...`: reads every record of its input and passes
them on sorted by the fields `-k` names, the first first, or by each
record's own fields in order when none is named; `-r` reverses the order.
A line of input is a record of one field, `line`, so `sort` sorts lines.

Integers sort as numbers, before every other value, which sorts as its
text as erx_render prints it, byte by byte. A record that lacks a key or
whose key's value is not `ok` cannot be placed by that key and sorts after
every record that can, with `-r` too, so no status becomes a value (SH3).
The sort is stable. It holds its whole input, within its stage's heap.
""".

-behaviour(erx_cmd).
-erx_command(sort).
-erx_usage("sort [-r] [-k field] ...").

-export([run/2]).

run(Args, Ctx) ->
    case options(Args, #{reverse => false, keys => []}) of
        {ok, #{reverse := Reverse, keys := Keys}} ->
            Rows = read_all(Ctx, Keys, []),
            Sorted = lists:sort(fun({A, _, _}, {B, _, _}) -> compare(A, B, Reverse) =/= gt end, Rows),
            lists:foreach(fun({_Key, Fields, Record}) -> erx_cmd:emit(Ctx, Fields, Record) end, Sorted);
        error ->
            {error, usage}
    end.

options([], #{keys := Keys} = Options) ->
    {ok, Options#{keys := lists:reverse(Keys)}};
options([<<"-r">> | Rest], Options) ->
    options(Rest, Options#{reverse := true});
options([<<"-k">>, Name | Rest], #{keys := Keys} = Options) ->
    options(Rest, Options#{keys := [field(Name) | Keys]});
options(_Args, _Options) ->
    error.

%% No record has a field whose name is no atom, so none is made for it.
field(Name) ->
    try binary_to_existing_atom(Name) catch error:badarg -> {no_atom, Name} end.

%% Each record with its sort key, in the order read.
read_all(Ctx, Keys, Acc) ->
    case erx_cmd:read_record(Ctx) of
        eof -> lists:reverse(Acc);
        {Fields, Record} ->
            Named = case Keys of
                        [] -> Fields;
                        _ -> Keys
                    end,
            read_all(Ctx, Keys, [{[key(Field, Record) || Field <- Named], Fields, Record} | Acc])
    end.

%% A value's place: an integer, before any text, or `undecided`.
key(Field, Record) ->
    case maps:find(Field, Record) of
        {ok, {_Reporter, {ok, Value}}} when is_integer(Value) -> {0, Value};
        {ok, {_Reporter, {ok, _}} = Attr} -> {1, erx_render:value(Attr)};
        _NotOk -> undecided
    end.

%% Keys compare place by place; an undecided place is after any decided one,
%% and keys of records of different fields, when one is a prefix of the
%% other, put the shorter first, so the order is total.
compare([A | As], [B | Bs], Reverse) ->
    case place(A, B, Reverse) of
        eq -> compare(As, Bs, Reverse);
        Order -> Order
    end;
compare([], [], _Reverse) -> eq;
compare([], _Bs, _Reverse) -> lt;
compare(_As, [], _Reverse) -> gt.

place(undecided, undecided, _Reverse) -> eq;
place(undecided, _B, _Reverse) -> gt;
place(_A, undecided, _Reverse) -> lt;
place(A, A, _Reverse) -> eq;
place(A, B, false) when A < B -> lt;
place(_A, _B, false) -> gt;
place(A, B, true) -> place(B, A, false).
