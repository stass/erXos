%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_text).
-moduledoc """
The two escapes of text attributed to a source (docs/design-live.md,
"Attributed text" and "The /proc tree"), both from the rules of
abi/terminal.txt, which erx_text_tables carries: which code points are
unsafe and how each token is written.

The **line escape**, escape_line/1, is how every display shows text under
the name of its source: a log record, a domain's name, an inspected value.
It renders on one visible line every character of the unsafe classes (the
controls, tab and newline among them, the format characters, the line and
paragraph separators, unassigned and default-ignorable code points, and a
surrogate code point in a character list) as `<U+NNNN>`, with four to six
upper-case hexadecimal digits, and every byte that does not begin or
continue a valid, shortest UTF-8 sequence as `<0xNN>`. Every other
character passes unchanged, the backslash and `<` among them, so a token is
for the eye only and the escape is not injective: text holding the eight
characters `<U+202E>` shows as text that held U+202E.

The **field escape**, escape_field/1, is how `/proc` writes the text its
reporters chose into its files, since a file of `/proc` is inspector output
that `cat` writes to a terminal as its bytes. It writes tab, newline and
backslash as `\t`, `\n` and `\\`, as the shell's framing toward bytes does,
and each byte of a character the line escape renders, and each byte of
invalid UTF-8, as `\xNN`; everything else passes unchanged. It is injective:
unescape_field/1 is its inverse, recovers the exact bytes, and refuses any
text escape_field/1 does not write. A field-escaped text holds nothing the
line escape changes, so escaping it again for display leaves it as it is.

Both are pure and hold no state between calls. The unsafe classes and the
tokens' texts come from erx_text_tables, the same generated tables the host
tool's Erx::LineEscape reads, so the two share them by construction; their
UTF-8 decoders are separate, and test/fixtures/line_escape_vectors.json
holds what both must answer for each class.
""".

-export([escape_line/1, escape_field/1, unescape_field/1]).

%% A token: the text before the hexadecimal digits, the fewest digits it
%% is written with, and the text after them.
-type token() :: {Prefix :: binary(), MinDigits :: pos_integer(), Suffix :: binary()}.

-doc """
The line escape of `Text`, a binary of UTF-8 bytes or a character list or
any mix of them; anything else fails with `badarg`.
""".
-spec escape_line(unicode:chardata()) -> unicode:unicode_binary().
escape_line(Text) when is_binary(Text); is_list(Text) ->
    iolist_to_binary(lists:reverse(pieces([Text], line_tokens(), [])));
escape_line(_Text) ->
    error(badarg).

%% The chardata as a work list, so its nesting costs heap and not stack.
%% An improper list's tail must be a binary or a list, as in chardata.
pieces([], _Tokens, Acc) ->
    Acc;
pieces([[] | Rest], Tokens, Acc) ->
    pieces(Rest, Tokens, Acc);
pieces([[Head | Tail] | Rest], Tokens, Acc) when is_list(Tail); is_binary(Tail) ->
    pieces([Head, Tail | Rest], Tokens, Acc);
pieces([Bytes | Rest], Tokens, Acc) when is_binary(Bytes) ->
    pieces(Rest, Tokens, line_bytes(Bytes, Tokens, Acc));
pieces([Point | Rest], Tokens, Acc)
  when is_integer(Point), Point >= 0, Point =< 16#10FFFF ->
    pieces(Rest, Tokens, [line_char(Point, Tokens) | Acc]);
pieces(_Pieces, _Tokens, _Acc) ->
    error(badarg).

%% Printable ASCII, the common case, is copied byte by byte; a valid,
%% shortest UTF-8 sequence is one character, which Erlang's utf8 match
%% decides (it refuses overlong forms, encoded surrogates and anything past
%% U+10FFFF); any other byte is a byte token, and decoding resumes after it.
line_bytes(<<>>, _Tokens, Acc) ->
    Acc;
line_bytes(<<C, Rest/binary>>, Tokens, Acc) when C >= 16#20, C < 16#7F ->
    line_bytes(Rest, Tokens, [C | Acc]);
line_bytes(<<Point/utf8, Rest/binary>>, Tokens, Acc) ->
    line_bytes(Rest, Tokens, [line_char(Point, Tokens) | Acc]);
line_bytes(<<B, Rest/binary>>, {_PointToken, ByteToken} = Tokens, Acc) ->
    line_bytes(Rest, Tokens, [token(B, ByteToken) | Acc]).

line_char(Point, {PointToken, _ByteToken}) ->
    case unsafe(Point) of
        true -> token(Point, PointToken);
        false -> <<Point/utf8>>
    end.

-doc "The field escape of the bytes `Bytes`.".
-spec escape_field(binary()) -> binary().
escape_field(Bytes) when is_binary(Bytes) ->
    iolist_to_binary(lists:reverse(field(Bytes, field_token(), []))).

field(<<>>, _Token, Acc) ->
    Acc;
field(<<$\\, Rest/binary>>, Token, Acc) ->
    field(Rest, Token, [<<"\\\\">> | Acc]);
field(<<$\t, Rest/binary>>, Token, Acc) ->
    field(Rest, Token, [<<"\\t">> | Acc]);
field(<<$\n, Rest/binary>>, Token, Acc) ->
    field(Rest, Token, [<<"\\n">> | Acc]);
field(<<C, Rest/binary>>, Token, Acc) when C >= 16#20, C < 16#7F ->
    field(Rest, Token, [C | Acc]);
field(<<Point/utf8, Rest/binary>>, Token, Acc) ->
    Encoded = <<Point/utf8>>,
    case unsafe(Point) of
        true -> field(Rest, Token, [[token(B, Token) || <<B>> <= Encoded] | Acc]);
        false -> field(Rest, Token, [Encoded | Acc])
    end;
field(<<B, Rest/binary>>, Token, Acc) ->
    field(Rest, Token, [token(B, Token) | Acc]).

-doc """
The bytes whose field escape is `Text`. Text that escape_field/1 does not
write is refused: `malformed` for a backslash not followed by `\`, `t`, `n`
or `x` and two upper-case hexadecimal digits, and `noncanonical` for
well-formed text that the field escape writes differently, such as a raw
tab or `\x41` for `A`.
""".
-spec unescape_field(binary()) -> {ok, binary()} | {error, malformed | noncanonical}.
unescape_field(Text) when is_binary(Text) ->
    {Prefix, 2, <<>>} = field_token(),
    case unfield(Text, Prefix, []) of
        {ok, Acc} ->
            Bytes = iolist_to_binary(lists:reverse(Acc)),
            case escape_field(Bytes) =:= Text of
                true -> {ok, Bytes};
                false -> {error, noncanonical}
            end;
        error ->
            {error, malformed}
    end.

%% The generator makes the field token's prefix a backslash and one other
%% character than `\`, `t` and `n`, so the four escapes cannot overlap.
unfield(<<>>, _Prefix, Acc) ->
    {ok, Acc};
unfield(<<"\\\\", Rest/binary>>, Prefix, Acc) ->
    unfield(Rest, Prefix, [$\\ | Acc]);
unfield(<<"\\t", Rest/binary>>, Prefix, Acc) ->
    unfield(Rest, Prefix, [$\t | Acc]);
unfield(<<"\\n", Rest/binary>>, Prefix, Acc) ->
    unfield(Rest, Prefix, [$\n | Acc]);
unfield(<<Prefix:2/binary, High, Low, Rest/binary>>, Prefix, Acc) ->
    case {hex(High), hex(Low)} of
        {H, L} when is_integer(H), is_integer(L) ->
            unfield(Rest, Prefix, [H * 16 + L | Acc]);
        _ -> error
    end;
unfield(<<$\\, _/binary>>, _Prefix, _Acc) ->
    error;
unfield(<<C, Rest/binary>>, Prefix, Acc) ->
    unfield(Rest, Prefix, [C | Acc]).

%% Upper-case digits only, as the tokens write them.
hex(D) when D >= $0, D =< $9 -> D - $0;
hex(D) when D >= $A, D =< $F -> D - $A + 10;
hex(_) -> none.

%%% Tokens and classes, from erx_text_tables

%% The code point token and the byte token, in that order.
line_tokens() ->
    #{<<"token">> := #{<<"codepoint">> := Point, <<"byte">> := Byte}} =
        erx_text_tables:catalog(),
    {token_spec(Point), token_spec(Byte)}.

field_token() ->
    #{<<"token">> := #{<<"field">> := Field}} = erx_text_tables:catalog(),
    token_spec(Field).

-spec token_spec(map()) -> token().
token_spec(#{<<"prefix">> := Prefix, <<"minimum">> := Min, <<"suffix">> := Suffix}) ->
    {Prefix, Min, Suffix}.

%% The generator gives the code point token room for six digits and each
%% byte token exactly two, so no value is ever cut.
token(Value, {Prefix, Min, Suffix}) ->
    Digits = integer_to_binary(Value, 16),
    Pad = binary:copy(<<"0">>, max(0, Min - byte_size(Digits))),
    [Prefix, Pad, Digits, Suffix].

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
