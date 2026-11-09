%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_web_value).
-moduledoc """
An inspection record as the web protocol carries it (docs/design-web.md,
"Values"): project/1 turns any inspector value into a datum() of a closed
set, so the browser never parses Erlang, and does no I/O.

* An integer of at most 40 decimal bytes, sign included, is `int`, decided
  by its magnitude before it is written; a binary is `text`, its bytes as
  reported, invalid UTF-8 included; an atom of at most 255 bytes of UTF-8
  is `atom`.
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
  of the copy's print are the term's. A huge integer in the copy is
  shortened to its leading digits, which fill the print alone.

A record's attributes come in the schema's order, each with its reporter, a
stopgap one by its name, its status and a datum: the value for `ok`, the
partial value for `partial`, the reason for `error` and the empty list for
the rest. A value of an attribute whose type is the one variable segment of
a presentation's marked path (abi/inspection.txt's `present` marks) is
`present`, its type's name and erx_present:text/2 of the value. Its path
and its children are /proc entry names (erx_procfs_core:name/1), so the
client links to a child by its name and never re-encodes a segment the
machine sent.

Every datum is charged its encoded size against one update's 64 KiB
(web.txt's web_message_max) before what it holds is projected, so a record
whose datums would pass it answers `too_large` at the first one over, and
the work of a projection stays within one update however much its term
shares, but for a huge integer's leading digits (TODO.md); the codec
still checks the whole update exactly.
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

%% The bounds of datum() (docs/design-web.md, "Values"), and the 10^40 that
%% a non-negative integer of at most 40 digits is below; a negative one, of
%% a sign and 39 digits, is above -10^39.
-define(INT_BOUND, 10000000000000000000000000000000000000000).
-define(ATOM_BYTES, 255).
-define(LIST_MAX, 1000).
-define(TUPLE_MAX, 16).
-define(DEPTH, 8).
-define(PRINTED_BYTES, 4096).
%% The nodes a print copies: each prints at least one character.
-define(PRINTED_NODES, 4096).
%% One update's bytes, web.txt's web_message_max, and what a datum costs on
%% the wire beyond its bytes: a tag and a u32 length or count.
-define(UPDATE_BYTES, 65536).
-define(HEAD, 5).
%% Below this magnitude an integer is printed whole in well under a
%% millisecond; above it, printing it whole takes up to seconds.
-define(WHOLE_PRINT, (1 bsl 65536)).

-doc """
The wire form of the inspection record Record, or too_large when its
datums alone would pass one update's 64 KiB.
""".
-spec project(erx_schema:record()) -> {ok, wire_record()} | {error, too_large}.
project(#{path := Path, kind := Kind, id := Id, attrs := Attrs, children := Children}) when is_map(Attrs) ->
    {ok, Order} = erx_schema:attributes(Kind),
    within_update(
      fun() ->
              {WirePath, Left} = entries(Path, ?UPDATE_BYTES),
              {WireId, IdLeft} = datum(Id, 1, Left),
              %% Only the attributes the schema lists for Kind, in its order.
              Listed = [{Name, Attr} || Name <- Order, {ok, Attr} <- [maps:find(Name, Attrs)]],
              {WireAttrs, AttrsLeft} = lists:mapfoldl(fun({Name, Attr}, Budget) -> attr(Kind, Name, Attr, Budget) end,
                                                      IdLeft, Listed),
              {WireChildren, _Rest} = children(Children, AttrsLeft),
              #{path => WirePath, kind => atom_to_binary(Kind), id => WireId, attrs => WireAttrs,
                children => WireChildren}
      end).

-doc "The datum of any term at the first level of nesting, or too_large past one update.".
-spec datum(term()) -> {ok, datum()} | {error, too_large}.
datum(Term) ->
    within_update(fun() -> element(1, datum(Term, 1, ?UPDATE_BYTES)) end).

%% Project answers Project(), or too_large once charge/2 finds the update
%% spent; nothing else throws it.
within_update(Project) ->
    try
        {ok, Project()}
    catch
        throw:too_large -> {error, too_large}
    end.

%% Left less Bytes, or too_large when they would pass it.
charge(Bytes, Left) when Bytes =< Left -> Left - Bytes;
charge(_Bytes, _Left) -> throw(too_large).

attr(Kind, Name, {Reporter, Value}, Left) ->
    {Status, Datum, Rest} = status(Value, presentation(Kind, Name), Left),
    {{atom_to_binary(Name), reporter(Reporter), Status, Datum}, Rest}.

reporter({stopgap, Name}) when is_atom(Name) -> {stopgap, atom_to_binary(Name)};
reporter(Reporter) when Reporter =:= kernel; Reporter =:= service; Reporter =:= runtime -> Reporter.

status({ok, Value}, Presentation, Left) -> with_status(ok, value(Value, Presentation, Left));
status({partial, Value}, Presentation, Left) -> with_status(partial, value(Value, Presentation, Left));
status({error, Reason}, _Presentation, Left) -> with_status(error, datum(Reason, 1, Left));
status({timeout, Ms} = Timeout, _Presentation, Left) when is_integer(Ms), Ms > 0 ->
    {Timeout, {list, []}, charge(?HEAD, Left)};
status(Status, _Presentation, Left) when Status =:= unknown; Status =:= unsupported ->
    {Status, {list, []}, charge(?HEAD, Left)}.

with_status(Status, {Datum, Left}) -> {Status, Datum, Left}.

%% The one-segment presentation whose variable segment has the type of
%% Kind's attribute Name, or none. The generator allows at most one per type.
presentation(Kind, Name) ->
    {ok, #{type := Type}} = erx_schema:attribute(Kind, Name),
    case [Presentation || {Presentation, Pattern} <- erx_present:marks(),
                          [{variable, Type}] =:= [Segment || {variable, _} = Segment <- Pattern]] of
        [Presentation] -> {ok, Presentation};
        [] -> none
    end.

%% A value of a presentation's type is present when erx_present writes its
%% text; one outside the marked path's segments is shown as any term is.
value(Value, none, Left) ->
    datum(Value, 1, Left);
value(Value, {ok, Presentation}, Left) ->
    try erx_present:text(Presentation, Value) of
        Text ->
            Name = atom_to_binary(Presentation),
            {{present, Name, Text}, charge(?HEAD + byte_size(Name) + 4 + byte_size(Text), Left)}
    catch
        error:badarg -> datum(Value, 1, Left)
    end.

children(Children, Left) when is_list(Children) -> completeness(complete, entries(Children, Left));
children({partial, Children}, Left) when is_list(Children) -> completeness(partial, entries(Children, Left));
children(unknown, Left) -> {{unknown, []}, charge(?HEAD, Left)}.

completeness(Completeness, {Entries, Left}) -> {{Completeness, Entries}, Left}.

entries(Segments, Left) ->
    lists:mapfoldl(fun entry/2, charge(?HEAD, Left), Segments).

entry(Segment, Left) ->
    Name = erx_procfs_core:name(Segment),
    {{text, Name}, charge(?HEAD + byte_size(Name), Left)}.

%% The datum of Term at nesting Level, and the update's bytes Left after it.
%% Each clause charges before it builds what it holds (a list after
%% short_proper/2's walk of at most 1,001 cells), so a spent update stops
%% the walk.
datum(Integer, _Level, Left) when is_integer(Integer), Integer < ?INT_BOUND, Integer > -(?INT_BOUND div 10) ->
    Digits = integer_to_binary(Integer),
    {{int, Digits}, charge(?HEAD + byte_size(Digits), Left)};
datum(Binary, _Level, Left) when is_binary(Binary) ->
    {{text, Binary}, charge(?HEAD + byte_size(Binary), Left)};
datum(Atom, _Level, Left) when is_atom(Atom) ->
    case atom_to_binary(Atom) of
        Name when byte_size(Name) =< ?ATOM_BYTES -> {{atom, Name}, charge(?HEAD + byte_size(Name), Left)};
        _ -> printed(Atom, Left)
    end;
datum(Tuple, Level, Left) when is_tuple(Tuple), tuple_size(Tuple) =< ?TUPLE_MAX, Level < ?DEPTH ->
    {Items, Rest} = items(tuple_to_list(Tuple), Level + 1, charge(?HEAD, Left)),
    {{tuple, Items}, Rest};
datum(List, Level, Left) when is_list(List), Level < ?DEPTH ->
    case short_proper(List, ?LIST_MAX) of
        true ->
            {Items, Rest} = items(List, Level + 1, charge(?HEAD, Left)),
            {{list, Items}, Rest};
        false ->
            printed(List, Left)
    end;
datum(Term, _Level, Left) ->
    printed(Term, Left).

items(Terms, Level, Left) ->
    lists:mapfoldl(fun(Term, Budget) -> datum(Term, Level, Budget) end, Left, Terms).

%% Whether List is proper with at most Left elements, walking at most Left
%% + 1 of its cells, however long it is.
short_proper([], _Left) -> true;
short_proper([_ | _], 0) -> false;
short_proper([_ | Tail], Left) -> short_proper(Tail, Left - 1);
short_proper(_Tail, _Left) -> false.

%% The print is charged its head first and its bytes once made: making it
%% costs at most a 4,096-node copy and a 4 KiB print.
printed(Term, Left) ->
    Rest = charge(?HEAD, Left),
    {Bounded, _Nodes} = bounded(Term, ?PRINTED_NODES),
    Text = cut(unicode:characters_to_binary(io_lib:format("~0tp", [Bounded], [{chars_limit, ?PRINTED_BYTES}]))),
    {{printed, Text}, charge(byte_size(Text), Rest)}.

%% A copy of Term's first Left nodes, depth first in print order, with
%% '...' for the rest, and the nodes left over. io_lib walks a deep list
%% whole whatever chars_limit says, so it prints only this copy. A
%% binary or other leaf is one node; chars_limit bounds its print. An
%% integer too long to print whole is its leading digits, whose print fills
%% PRINTED_BYTES alone, so it is the copy's last node.
bounded(_Term, 0) -> {'...', 0};
bounded([_ | _] = List, Left) -> cells(List, Left - 1);
bounded(Tuple, Left) when is_tuple(Tuple) -> elements(Tuple, 1, Left - 1, []);
bounded(Map, Left) when is_map(Map) -> pairs(maps:next(maps:iterator(Map)), Left - 1, []);
bounded(Integer, _Left) when is_integer(Integer), (Integer >= ?WHOLE_PRINT orelse Integer =< -?WHOLE_PRINT) ->
    {leading(Integer), 0};
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

%% An integer whose print begins with Integer's first PRINTED_BYTES
%% characters, sign included, made without printing Integer whole: division
%% by 10^Dropped keeps the leading digits. A magnitude of Bytes bytes is at
%% least 256^(Bytes - 1), so it has at least L + 1 digits for L =
%% trunc((Bytes - 1) * 8 * log10(2)), the factor rounded down; Dropped is
%% L - PRINTED_BYTES - 1, so at least 4,098 digits remain, a sign besides.
leading(Integer) ->
    Bytes = byte_size(binary:encode_unsigned(abs(Integer))),
    Dropped = max(0, trunc((Bytes - 1) * 8 * 0.30102999) - ?PRINTED_BYTES - 1),
    Integer div power(10, Dropped).

power(_Base, 0) -> 1;
power(Base, Exponent) when Exponent rem 2 =:= 0 -> Half = power(Base, Exponent div 2), Half * Half;
power(Base, Exponent) -> Base * power(Base, Exponent - 1).

%% At most PRINTED_BYTES of Text, ending at a character's end: a cut never
%% leaves part of a UTF-8 sequence, so the cut text is as valid as the print.
cut(Text) when byte_size(Text) =< ?PRINTED_BYTES -> Text;
cut(Text) -> back_to_lead(Text, ?PRINTED_BYTES).

back_to_lead(Text, At) ->
    case binary:at(Text, At) band 16#C0 of
        16#80 when At > 0 -> back_to_lead(Text, At - 1);
        _ -> binary:part(Text, 0, At)
    end.
