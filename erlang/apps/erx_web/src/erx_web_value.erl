%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_web_value).
-moduledoc """
An inspection record as the web protocol carries it (docs/design-web.md,
"Values"): project/1 turns any inspector value into a datum() of a closed
set, so the browser never parses Erlang, and does no I/O.

* An integer of at most 40 decimal bytes, sign included, is `int`; a binary
  is `text`, its bytes as reported, invalid UTF-8 included; an atom of at
  most 255 bytes of UTF-8 is `atom`.
* A proper list of at most 1,000 elements is `list`, a tuple of at most 16
  is `tuple`, while nesting stays within web.txt's eight levels: the
  value of an attribute is the first level, and the eighth holds no list
  or tuple, so a list or tuple there, whose elements would need a ninth,
  is printed.
* Any other term (a longer integer, atom, list or tuple, an improper list,
  a float, a bitstring, a map, a pid, a reference, a port or a fun) is
  `printed` as `~0tp` prints it, as erx_render:value/1 does, cut at a
  character's end to at most 4 KiB. What is printed is a copy of the
  term's first 4,096 nodes in print order, the rest written `'...'`, so a
  huge or deeply nested term costs a bounded print, not one of its whole
  size; since every node prints at least one character, the first 4 KiB
  of the copy's print are the term's.

A record's attributes come in the schema's order, each with its reporter, a
stopgap one by its name, its status and a datum: the value for `ok`, the
partial value for `partial`, the reason for `error` and the empty list for
the rest. Its path and its children are /proc entry names
(erx_procfs_core:name/1), so the client links to a child by its name and
never re-encodes a segment the machine sent.
""".

-export([project/1, datum/1]).
-export_type([datum/0, wire_record/0]).

-type datum() :: {int, binary()} | {text, binary()} | {atom, binary()}
               | {present, Type :: binary(), Text :: binary()}
               | {list, [datum()]} | {tuple, [datum()]} | {printed, binary()}.
-type reporter() :: kernel | service | runtime | {stopgap, binary()}.
-type status() :: ok | partial | unknown | unsupported | {timeout, pos_integer()} | error.
-type wire_attr() :: {Key :: binary(), reporter(), status(), datum()}.
-type wire_record() :: #{path := [datum()], kind := binary(), id := datum(), attrs := [wire_attr()],
                         children := {complete | partial | unknown, [datum()]}}.

%% The bounds of datum() (docs/design-web.md, "Values").
-define(INT_BYTES, 40).
-define(ATOM_BYTES, 255).
-define(LIST_MAX, 1000).
-define(TUPLE_MAX, 16).
-define(DEPTH, 8).
-define(PRINTED_BYTES, 4096).

-doc "The wire form of the inspection record Record.".
-spec project(erx_schema:record()) -> wire_record().
project(#{path := Path, kind := Kind, id := Id, attrs := Attrs, children := Children}) when is_map(Attrs) ->
    {ok, Order} = erx_schema:attributes(Kind),
    #{path => [entry(Segment) || Segment <- Path],
      kind => atom_to_binary(Kind),
      id => datum(Id),
      %% Only the attributes the schema lists for Kind, in its order.
      attrs => [attr(Name, Attr) || Name <- Order, {ok, Attr} <- [maps:find(Name, Attrs)]],
      children => children(Children)}.

-doc "The datum of any term, at the first level of nesting.".
-spec datum(term()) -> datum().
datum(Term) -> datum(Term, 1).

attr(Name, {Reporter, Value}) ->
    {Status, Datum} = status(Value),
    {atom_to_binary(Name), reporter(Reporter), Status, Datum}.

reporter({stopgap, Name}) when is_atom(Name) -> {stopgap, atom_to_binary(Name)};
reporter(Reporter) when Reporter =:= kernel; Reporter =:= service; Reporter =:= runtime -> Reporter.

status({ok, Value}) -> {ok, datum(Value)};
status({partial, Value}) -> {partial, datum(Value)};
status({error, Reason}) -> {error, datum(Reason)};
status({timeout, Ms} = Timeout) when is_integer(Ms), Ms > 0 -> {Timeout, {list, []}};
status(Status) when Status =:= unknown; Status =:= unsupported -> {Status, {list, []}}.

children(Children) when is_list(Children) -> {complete, [entry(Child) || Child <- Children]};
children({partial, Children}) when is_list(Children) -> {partial, [entry(Child) || Child <- Children]};
children(unknown) -> {unknown, []}.

entry(Segment) -> {text, erx_procfs_core:name(Segment)}.

datum(Integer, _Level) when is_integer(Integer) ->
    case integer_to_binary(Integer) of
        Digits when byte_size(Digits) =< ?INT_BYTES -> {int, Digits};
        Digits -> {printed, cut(Digits)}
    end;
datum(Binary, _Level) when is_binary(Binary) ->
    {text, Binary};
datum(Atom, _Level) when is_atom(Atom) ->
    case atom_to_binary(Atom) of
        Name when byte_size(Name) =< ?ATOM_BYTES -> {atom, Name};
        _ -> printed(Atom)
    end;
datum(Tuple, Level) when is_tuple(Tuple), tuple_size(Tuple) =< ?TUPLE_MAX, Level < ?DEPTH ->
    {tuple, [datum(Element, Level + 1) || Element <- tuple_to_list(Tuple)]};
datum(List, Level) when is_list(List), Level < ?DEPTH ->
    case short_proper(List, ?LIST_MAX) of
        true -> {list, [datum(Element, Level + 1) || Element <- List]};
        false -> printed(List)
    end;
datum(Term, _Level) ->
    printed(Term).

%% Whether List is proper with at most Left elements, walking at most Left
%% + 1 of its cells, however long it is.
short_proper([], _Left) -> true;
short_proper([_ | _], 0) -> false;
short_proper([_ | Tail], Left) -> short_proper(Tail, Left - 1);
short_proper(_Tail, _Left) -> false.

printed(Term) ->
    {Bounded, _Left} = bounded(Term, ?PRINTED_BYTES),
    Text = io_lib:format("~0tp", [Bounded], [{chars_limit, ?PRINTED_BYTES}]),
    {printed, cut(unicode:characters_to_binary(Text))}.

%% A copy of Term's first Left nodes, depth first in print order, with
%% '...' for the rest, and the nodes left over. io_lib walks a deep list
%% whole whatever chars_limit says, so it prints only this copy. A
%% binary or other leaf is one node; chars_limit bounds its print.
bounded(_Term, 0) -> {'...', 0};
bounded([_ | _] = List, Left) -> cells(List, Left - 1);
bounded(Tuple, Left) when is_tuple(Tuple) -> elements(Tuple, 1, Left - 1, []);
bounded(Map, Left) when is_map(Map) -> pairs(maps:next(maps:iterator(Map)), Left - 1, []);
bounded(Leaf, Left) -> {Leaf, Left - 1}.

cells([], Left) -> {[], Left};
cells([_ | _], 0) -> {['...'], 0};
cells([Head | Tail], Left) ->
    {Copy, Rest} = bounded(Head, Left),
    {Tails, Over} = cells(Tail, Rest),
    {[Copy | Tails], Over};
cells(Improper, Left) -> bounded(Improper, Left).

elements(Tuple, At, Left, Acc) when At > tuple_size(Tuple) -> {list_to_tuple(lists:reverse(Acc)), Left};
elements(_Tuple, _At, 0, Acc) -> {list_to_tuple(lists:reverse(['...' | Acc])), 0};
elements(Tuple, At, Left, Acc) ->
    {Copy, Rest} = bounded(element(At, Tuple), Left),
    elements(Tuple, At + 1, Rest, [Copy | Acc]).

pairs(none, Left, Acc) -> {maps:from_list(Acc), Left};
pairs(_Next, 0, Acc) -> {maps:from_list([{'...', '...'} | Acc]), 0};
pairs({Key, Value, Next}, Left, Acc) ->
    {KeyCopy, Rest} = bounded(Key, Left),
    {ValueCopy, Over} = bounded(Value, Rest),
    pairs(maps:next(Next), Over, [{KeyCopy, ValueCopy} | Acc]).

%% At most PRINTED_BYTES of Text, ending at a character's end: a cut never
%% leaves part of a UTF-8 sequence, so the cut text is as valid as the print.
cut(Text) when byte_size(Text) =< ?PRINTED_BYTES -> Text;
cut(Text) -> back_to_lead(Text, ?PRINTED_BYTES).

back_to_lead(Text, At) ->
    case binary:at(Text, At) of
        Byte when Byte band 16#C0 =:= 16#80, At > 0 -> back_to_lead(Text, At - 1);
        _ -> binary:part(Text, 0, At)
    end.
