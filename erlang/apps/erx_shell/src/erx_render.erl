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

A record becomes one line of the fields it holds, in the order given,
separated by tabs; a command that emits records of more than one shape,
such as `ls` with and without `-l`, declares the fields of all of them. Toward bytes, a file or a pipe, each value has its tab, newline and
backslash written as `\t`, `\n` and `\\` and nothing else changed, so a
reader of lines sees one record per line and exactly the data. Toward
the terminal each value also passes the line escape, escape/1, since a
record's text is attributed to its source.
""".

-export([value/1, line/3, escape/1]).

-export_type([attr/0]).

-type attr() :: {kernel | service | runtime,
                 {ok, term()} | {partial, term()} | unknown | unsupported
                 | {timeout, pos_integer()} | {error, term()}}.

-doc "An attribute's text: the value when it is `ok`, its status otherwise.".
-spec value(attr()) -> binary().
value({_Reporter, {ok, Value}}) -> text(Value);
value({_Reporter, {partial, _}}) -> <<"[partial]">>;
value({_Reporter, unknown}) -> <<"[unknown]">>;
value({_Reporter, unsupported}) -> <<"[unsupported]">>;
value({_Reporter, {timeout, Ms}}) -> <<"[timeout ", (integer_to_binary(Ms))/binary, "]">>;
value({_Reporter, {error, _}}) -> <<"[error]">>.

-doc "A record as one line toward bytes or toward the terminal.".
-spec line([atom()], #{atom() => attr()}, bytes | terminal) -> binary().
line(Fields, Record, Sink) ->
    Values = [field_text(value(Value), Sink) || Field <- Fields, {ok, Value} <- [maps:find(Field, Record)]],
    iolist_to_binary([lists:join($\t, Values), $\n]).

field_text(Text, bytes) -> separators(Text);
field_text(Text, terminal) -> escape(Text).

separators(Text) ->
    << <<(separator(C))/binary>> || <<C>> <= Text >>.

separator($\t) -> <<"\\t">>;
separator($\n) -> <<"\\n">>;
separator($\\) -> <<"\\\\">>;
separator(C) -> <<C>>.

-doc """
The line escape for text attributed to a source on its way to the
terminal: tab, newline and backslash as `\t`, `\n` and `\\`, every other
C0 or C1 control, DEL and byte of invalid UTF-8 as `\xNN`, and every code
point the terminal tables mark unsafe (bidirectional overrides, invisible
format characters, unassigned) as `\u{N}`.
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
