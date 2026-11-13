%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_wctl).
-moduledoc """
The text of a window's `wctl` file (docs/design-display.md, "Interfaces"):
parse/1 reads a write, a geometry command from the window's client, and
format/3 writes what a read returns. Both are rio(4)'s formats, cut down
to the commands the design names.

A write is one command on one line of at most 1,024 bytes:

```text
resize -r X0 Y0 X1 Y1
move -r X0 Y0 X1 Y1
hide
show
top
bottom
```

Tokens are separated by spaces or tabs, which may also lead and trail,
and the line may end in one newline, as rio's parser skips white space
around words. A coordinate is decimal with an optional leading `-` and
must fit draw(3)'s 32-bit coordinate. The command is returned as the
request erx_wm's place/5 takes; the parser judges only the text, and the
policy judges the rectangle (a `move` keeps only its top-left corner, as
rio's does). rio's other commands (`new`, `delete`, `current`, `scroll`,
`noscroll`, `set`, `unhide`), its other options and its relative `+N`
coordinates are not part of the grammar and are refused.

The bytes come from a client and are untrusted: anything outside the
grammar, including a byte that is not ASCII, a line longer than 1,024
bytes or a coordinate out of range, is `{error, einval}`, and the parser
creates no atom and does no work beyond a few passes over at most 1,024 bytes.

A read returns rio's layout: the rectangle's four coordinates, then
`current` or `notcurrent` and `hidden` or `visible`, each right-aligned
in a field of 11 followed by a space, 72 bytes in all.
""".

-export([parse/1, format/3]).
-export_type([command/0]).

-doc "A coordinate: draw(3)'s 32-bit signed integer.".
-type coord() :: -16#80000000..16#7fffffff.
-doc "A half-open rectangle `{X0, Y0, X1, Y1}`, as Plan 9's.".
-type rect() :: {coord(), coord(), coord(), coord()}.
-doc "A parsed write: the request erx_wm's place/5 takes.".
-type command() :: {resize, rect()} | {move, rect()}
                 | hide | show | top | bottom.

-define(MAX_LINE, 1024).
-define(MIN_COORD, -16#80000000).
-define(MAX_COORD, 16#7fffffff).
-define(FIELD, 11).

-doc """
Parses one write to `wctl`. Returns the command, or `{error, einval}` for
anything outside the grammar.
""".
-spec parse(binary()) -> {ok, command()} | {error, einval}.
parse(Bytes) when is_binary(Bytes), byte_size(Bytes) =< ?MAX_LINE ->
    case words(strip_newline(Bytes)) of
        {ok, Words} -> command(Words);
        error -> {error, einval}
    end;
parse(_) ->
    {error, einval}.

-doc """
The text a read of `wctl` returns for a window with rectangle `Rect`,
whether it takes the keyboard, and its state.
""".
-spec format(rect(), Current :: boolean(), shown | hidden) -> binary().
format({X0, Y0, X1, Y1}, Current, State) ->
    Focus = case Current of
                true -> <<"current">>;
                false -> <<"notcurrent">>
            end,
    Shown = case State of
                shown -> <<"visible">>;
                hidden -> <<"hidden">>
            end,
    Fields = [integer_to_binary(N) || N <- [X0, Y0, X1, Y1]] ++ [Focus, Shown],
    << <<(field(Field))/binary>> || Field <- Fields >>.

%% Internal functions

%% One newline may end the line; the words of what is left must not hold
%% another.
strip_newline(Bytes) ->
    case Bytes of
        <<Line:(byte_size(Bytes) - 1)/binary, $\n>> -> Line;
        _ -> Bytes
    end.

%% The line's words, split at runs of spaces and tabs. Every byte must be
%% printable ASCII or a separator, so a control byte, a second newline or a
%% byte above 0x7e refuses the line before any word is read.
words(Line) ->
    case lists:all(fun(Byte) -> word_byte(Byte) orelse separator(Byte) end,
                   binary_to_list(Line)) of
        true -> {ok, binary:split(Line, [<<" ">>, <<"\t">>], [global, trim_all])};
        false -> error
    end.

word_byte(Byte) -> Byte > $\s andalso Byte < 16#7f.

separator(Byte) -> Byte =:= $\s orelse Byte =:= $\t.

command([<<"resize">>, <<"-r">> | Numbers]) -> rect(resize, Numbers);
command([<<"move">>, <<"-r">> | Numbers]) -> rect(move, Numbers);
command([<<"hide">>]) -> {ok, hide};
command([<<"show">>]) -> {ok, show};
command([<<"top">>]) -> {ok, top};
command([<<"bottom">>]) -> {ok, bottom};
command(_) -> {error, einval}.

rect(Verb, [A, B, C, D]) ->
    case [coordinate(Word) || Word <- [A, B, C, D]] of
        [{ok, X0}, {ok, Y0}, {ok, X1}, {ok, Y1}] -> {ok, {Verb, {X0, Y0, X1, Y1}}};
        _ -> {error, einval}
    end;
rect(_, _) ->
    {error, einval}.

%% `-` then at least one digit, or digits alone; the line bound keeps the
%% digits few, and the range is checked on the value.
coordinate(<<$-, Digits/binary>>) -> in_range(digits(Digits), -1);
coordinate(Digits) -> in_range(digits(Digits), 1).

digits(<<>>) -> error;
digits(Digits) ->
    case lists:all(fun(Byte) -> Byte >= $0 andalso Byte =< $9 end,
                   binary_to_list(Digits)) of
        true -> {ok, binary_to_integer(Digits)};
        false -> error
    end.

in_range({ok, Magnitude}, Sign) when Sign * Magnitude >= ?MIN_COORD,
                                     Sign * Magnitude =< ?MAX_COORD ->
    {ok, Sign * Magnitude};
in_range(_, _) ->
    error.

field(Text) ->
    Pad = max(0, ?FIELD - byte_size(Text)),
    <<(binary:copy(<<" ">>, Pad))/binary, Text/binary, " ">>.
