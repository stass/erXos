%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_render).
-moduledoc """
The one renderer of a record's values as text (docs/design-shell.md,
"Pipelines"; docs/design-live.md, "Inspection records"). A value is an
`attr()`, a reporter and a value with its status: an `ok` value prints
bare, and every other status prints as itself, `[partial]`, `[unknown]`,
`[unsupported]`, `[timeout N]` or `[error]`, so no status reads as a
value.

A value is attributed text, which a reporter names (a process's name, a
file's name, a count), or **data**, `data()`: a line of a file or a
program without its newline, as erx_cmd:read_record/1 makes it. Data is
the shell's own value, not the inspector's: `data` stands where a
reporter would, so `where`, `sort` and value/1 take it as any `ok` value,
and it never reaches the inspector. A record that is a line of data, one
data value holding no newline, data_line/1, is written as its bytes and a
newline, toward a file and toward the terminal alike, as `cat f` writes
it and as FreeBSD's `sort f` does; anything else, a data value beside
other fields or holding a newline, renders as attributed text, so data
never splits a field or a row.

Toward bytes, a file or a pipe, a record becomes one line, line/2, of the
fields it holds, in the order given, separated by tabs, each value with
its tab, newline and backslash written as `\t`, `\n` and `\\` and nothing
else changed, so a reader of lines sees one record per line and exactly
the data. A line of data is its bytes and a newline, so `cat f | sort > g`
changes no byte of a line. A command that emits records of more than one
shape, such as `ls` with and without `-l`, declares the fields of all of
them.

Toward the terminal, records render as a table: aligned columns under a
header line of the field names, every value and name passed through the
line escape, escape/1, since a record's text is attributed to its source.
A line of data is not: it is a program's own output, which reaches the
terminal unchanged as on UNIX, so its bytes are written as they are.
A table's shape is the fields its first record holds, and a record of
another shape starts a new table. A table of one column has no header
and nothing to align, so it prints each value as it comes: lines read
into `line` records print as their data, `ls` and `count` as their
escaped text, with no header. A table
of more columns holds its first 256 records, and at most 1 MiB of their
text, to measure its columns, then prints them, and every later record of
its shape at those widths: a later value wider than its column pushes the
rest of its row right, never cut. A column whose held values include an
integer and no other `ok` value is aligned right.

The table is a pure state machine: table/0 starts one, table_record/3
adds a record and table_flush/1 prints what it holds, each answering the
bytes to write; erx_cmd keeps one for a command that writes to the
terminal and flushes it before any other write there.
""".

-export([value/1, line/2, escape/1, table/0, table_record/3, table_flush/1]).

-export_type([attr/0, data/0, table/0]).

%% An inspector value with its reporter, or a line of data.
-type attr() :: {kernel | service | runtime,
                 {ok, term()} | {partial, term()} | unknown | unsupported
                 | {timeout, pos_integer()} | {error, term()}}
              | data().
-type data() :: {data, {ok, binary()}}.

%% A table prints nothing yet (`idle`), holds its first rows to measure
%% them, newest first, or prints each row as it comes at fixed columns.
-opaque table() :: idle
                 | {holding, Shape :: [atom()], Rows :: [[cell()]],
                    Count :: pos_integer(), Bytes :: non_neg_integer()}
                 | {printing, Shape :: [atom()], [column()]}.
%% A cell's text and kind: a value escaped as attributed text (`integer`,
%% `text`, `status`), a field's escaped name (`name`), or a line of data's
%% bytes unchanged (`data`).
-type cell() :: {binary(), integer | text | status | name | data}.
-type column() :: {Width :: non_neg_integer(), left | right}.

-define(HELD_ROWS, 256).
-define(HELD_BYTES, (1 bsl 20)).
-define(GAP, <<"  ">>).

-doc "An attribute's text: the value when it is `ok`, its status otherwise.".
-spec value(attr()) -> binary().
value({_Reporter, {ok, Value}}) -> text(Value);
value({_Reporter, {partial, _}}) -> <<"[partial]">>;
value({_Reporter, unknown}) -> <<"[unknown]">>;
value({_Reporter, unsupported}) -> <<"[unsupported]">>;
value({_Reporter, {timeout, Ms}}) -> <<"[timeout ", (integer_to_binary(Ms))/binary, "]">>;
value({_Reporter, {error, _}}) -> <<"[error]">>.

-doc "A record as one line toward bytes, a file or a pipe.".
-spec line([atom()], #{atom() => attr()}) -> binary().
line(Fields, Record) ->
    Values = [Value || Field <- Fields, {ok, Value} <- [maps:find(Field, Record)]],
    Body = case data_line(Values) of
               {data, Bytes} -> Bytes;
               values -> lists:join($\t, [separators(value(Value)) || Value <- Values])
           end,
    iolist_to_binary([Body, $\n]).

%% The one decision of whether a record's values are a line of data, which
%% both line/2 and the table show as the data: one data value, holding no
%% newline, as every line read is. Anything else, a data value among other
%% fields or one holding a newline, is values, rendered as attributed text,
%% so data never splits a field or a row.
data_line([{data, {ok, Bytes}}]) when is_binary(Bytes) ->
    case binary:match(Bytes, <<"\n">>) of
        nomatch -> {data, Bytes};
        _ -> values
    end;
data_line(_Values) ->
    values.

separators(Text) ->
    << <<(separator(C))/binary>> || <<C>> <= Text >>.

separator($\t) -> <<"\\t">>;
separator($\n) -> <<"\\n">>;
separator($\\) -> <<"\\\\">>;
separator(C) -> <<C>>.

%%% The terminal's table

-doc "A table that has printed nothing.".
-spec table() -> table().
table() -> idle.

-doc "Adds a record of the given field order, answering what to print now.".
-spec table_record([atom()], #{atom() => attr()}, table()) -> {iodata(), table()}.
table_record(Fields, Record, Table) ->
    Shape = [Field || Field <- Fields, is_map_key(Field, Record)],
    add(Shape, cells([maps:get(Field, Record) || Field <- Shape]), Table).

-doc """
Prints the rows the table holds, fixing its columns for later rows of its
shape; a table that holds none is left as it is.
""".
-spec table_flush(table()) -> {iodata(), table()}.
table_flush({holding, Shape, Rows, _Count, _Bytes}) -> print(Shape, lists:reverse(Rows));
table_flush(Table) -> {[], Table}.

add(Shape, Row, {printing, Shape, Columns} = Table) ->
    {row(Row, Columns), Table};
add(Shape, Row, {holding, Shape, Rows, Count, Bytes}) ->
    hold(Shape, [Row | Rows], Count + 1, Bytes + row_bytes(Row));
add(Shape, Row, Table) ->
    {Printed, _Done} = table_flush(Table),
    {Held, New} = hold(Shape, [Row], 1, row_bytes(Row)),
    {[Printed, Held], New}.

%% A table of one column has nothing to align, so it holds nothing.
hold(Shape, Rows, _Count, _Bytes) when length(Shape) < 2 ->
    print(Shape, lists:reverse(Rows));
%% A table that holds as much as it may fixes its columns and prints.
hold(Shape, Rows, Count, Bytes) when Count >= ?HELD_ROWS; Bytes >= ?HELD_BYTES ->
    print(Shape, lists:reverse(Rows));
hold(Shape, Rows, Count, Bytes) ->
    {[], {holding, Shape, Rows, Count, Bytes}}.

%% Measures the header and the held rows, oldest first, and prints them.
%% A table of one column has no header and prints each value bare.
print([_, _ | _] = Shape, Rows) ->
    Lines = [[{escape(atom_to_binary(Field)), name} || Field <- Shape] | Rows],
    Columns = [column(Cells) || Cells <- transpose(Lines)],
    {[row(Cells, Columns) || Cells <- Lines], {printing, Shape, Columns}};
print(Shape, Rows) ->
    Columns = [{0, left} || _ <- Shape],
    {[row(Cells, Columns) || Cells <- Rows], {printing, Shape, Columns}}.

transpose([[] | _]) -> [];
transpose(Rows) -> [[Cell || [Cell | _] <- Rows] | transpose([Rest || [_ | Rest] <- Rows])].

%% A column is as wide as its widest cell, the header's name among them,
%% and aligned right when its values include an integer and no other `ok`
%% value; a name is not a value, so it does not decide the alignment.
column(Cells) ->
    Kinds = [Kind || {_, Kind} <- Cells],
    Align = case lists:member(integer, Kinds) andalso not lists:member(text, Kinds) of
                true -> right;
                false -> left
            end,
    {lists:max([width(Text) || {Text, _} <- Cells]), Align}.

%% A row of one cell, the only row a line of data makes, is its text and a
%% newline, never measured or padded, so a data cell's bytes need not be
%% UTF-8. A wider row's cells are joined by the gap, each padded to its
%% column; the last is not padded on its right, so no line ends in spaces.
row([{Text, _Kind}], _Columns) ->
    [Text, $\n];
row(Cells, Columns) ->
    Last = length(Cells),
    Padded = [pad(Text, Column, Index =:= Last)
              || {Index, {Text, _}, Column} <- lists:zip3(lists:seq(1, Last), Cells, Columns)],
    [lists:join(?GAP, Padded), $\n].

pad(Text, {Width, Align}, Last) ->
    Fill = binary:copy(<<" ">>, max(0, Width - width(Text))),
    case {Align, Last} of
        {right, _} -> [Fill, Text];
        {left, true} -> Text;
        {left, false} -> [Text, Fill]
    end.

%% The columns an escaped text takes: one for each character it shows.
width(Text) -> string:length(Text).

row_bytes(Row) -> lists:sum([byte_size(Text) || {Text, _} <- Row]).

%% A line of data is the one cell of its row and is shown as its bytes,
%% as `cat f` writes them; every other value is escaped as attributed text.
cells(Attrs) ->
    case data_line(Attrs) of
        {data, Bytes} -> [{Bytes, data}];
        values -> [cell(Attr) || Attr <- Attrs]
    end.

cell({_Reporter, {ok, Value}} = Attr) when is_integer(Value) -> {escape(value(Attr)), integer};
cell({_Reporter, {ok, _}} = Attr) -> {escape(value(Attr)), text};
cell(Attr) -> {escape(value(Attr)), status}.

-doc """
The line escape for text attributed to a source on its way to the
terminal: tab, newline and backslash as `\t`, `\n` and `\\`, every other
C0 control, DEL and byte that is not UTF-8 as `\xNN`, and every code
point the terminal tables mark unsafe (C1 controls, bidirectional
overrides, invisible format characters, unassigned) as `\u{N}`.
""".
-spec escape(binary()) -> binary().
escape(Text) -> iolist_to_binary(escape(Text, [])).

escape(<<>>, Acc) ->
    lists:reverse(Acc);
escape(<<C, Rest/binary>>, Acc) when C =:= $\t; C =:= $\n; C =:= $\\ ->
    escape(Rest, [separator(C) | Acc]);
escape(<<C, Rest/binary>>, Acc) when C < 16#20; C =:= 16#7f ->
    escape(Rest, [hex_byte(C) | Acc]);
escape(<<C, Rest/binary>>, Acc) when C < 16#80 ->
    escape(Rest, [C | Acc]);
escape(<<Point/utf8, Rest/binary>>, Acc) ->
    case unsafe(Point) of
        true -> escape(Rest, [io_lib:format("\\u{~.16b}", [Point]) | Acc]);
        false -> escape(Rest, [<<Point/utf8>> | Acc])
    end;
escape(<<C, Rest/binary>>, Acc) ->
    escape(Rest, [hex_byte(C) | Acc]).

hex_byte(C) -> io_lib:format("\\x~2.16.0b", [C]).

unsafe(Point) ->
    Ranges = erx_text_tables:unicode_unsafe_ranges(),
    within(Point, Ranges, 1, tuple_size(Ranges)).

%% Binary search of the sorted, disjoint ranges.
within(_Point, _Ranges, Low, High) when Low > High ->
    false;
within(Point, Ranges, Low, High) ->
    Mid = (Low + High) div 2,
    case element(Mid, Ranges) of
        {First, _} when Point < First -> within(Point, Ranges, Low, Mid - 1);
        {_, Last} when Point > Last -> within(Point, Ranges, Mid + 1, High);
        _ -> true
    end.

text(Value) when is_binary(Value) -> Value;
text(Value) when is_integer(Value) -> integer_to_binary(Value);
text(Value) when is_atom(Value) -> atom_to_binary(Value);
text(Value) when is_pid(Value) -> list_to_binary(pid_to_list(Value));
text(Value) -> iolist_to_binary(io_lib:format("~0tp", [Value])).
