%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz targets of erx_text's two escapes (docs/design-live.md,
%% "Attributed text" and "The /proc tree"), run as `line` or `field` with a
%% seed from make check-fuzz. Inputs are random bytes weighted towards those
%% that steer UTF-8 decoding and the escapes, and mutations of texts that
%% hold every class.
%%
%% `line`: escape_line/1 must answer valid UTF-8 holding no character the
%% tables mark unsafe, leave its own output as it is, agree with a reference
%% of this module's own that decodes UTF-8 by the Unicode Standard's table
%% 3-7 and searches the ranges one by one, and escape the text as a
%% character list as it escapes its bytes.
%%
%% `field`: escape_field/1 must answer the same safe text with no tab or
%% newline, which the line escape leaves as it is and unescape_field/1 turns
%% back into the input; and unescape_field/1 of any input, field-escaped text
%% mutated included, must answer bytes whose field escape is that input, or
%% refuse it, and never raise.
-module(erx_text_fuzz).
-export([run/1]).

-define(INPUTS, 20000).
-define(MAX_INPUT, 256).
%% A UTF-8 continuation byte.
-define(CONT(B), (B >= 16#80 andalso B =< 16#BF)).
-define(STEERING,
        [0, 9, 10, 13, 27, $[, $], $\\, $x, $X, $<, $U, $+, $0, $9, $A, $F, $a, $f, 16#7F, 16#80, 16#8F,
         16#9B, 16#9F, 16#A0, 16#AD, 16#BF, 16#C0, 16#C1, 16#C2, 16#DF, 16#E0, 16#E1, 16#E2, 16#ED,
         16#EE, 16#EF, 16#F0, 16#F3, 16#F4, 16#F5, 16#FE, 16#FF]).
-define(CLASSES,
        <<"a\tb\nc\\d<U+0041>", 0, 7, 27, "[1m", 27, "]8;;x", 27, "\\", 16#7F,
          "\x{80}\x{9B}\x{AD}\x{202E}\x{2066}\x{200B}\x{FEFF}\x{2028}\x{2029}\x{378}"/utf8,
          "\x{34F}\x{115F}\x{FE00}\x{200C}\x{200D}\x{FE0F}\x{E9}\x{1F600}\x{E0001}\x{10FFFF}"/utf8,
          16#C0, 16#80, 16#ED, 16#A0, 16#80, 16#F4, 16#90, 16#80, 16#80, 16#E2, 16#82, 16#FF>>).

run([Target, Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% The reference searches the ranges as a list, one by one.
    put(ranges, tuple_to_list(erx_text_tables:unicode_unsafe_ranges())),
    Check = case Target of
                "line" -> fun line/1;
                "field" -> fun field/1
            end,
    lists:foreach(fun(_) -> Check(input()) end, lists:seq(1, ?INPUTS)),
    io:format("fuzz: ~p inputs ok~n", [?INPUTS]).

input() ->
    case rand:uniform(3) of
        1 -> random_bytes(rand:uniform(?MAX_INPUT) - 1);
        2 -> mutate(?CLASSES);
        3 -> mutate(erx_text:escape_field(mutate(?CLASSES)))
    end.

random_bytes(N) ->
    << <<(byte())>> || _ <- lists:seq(1, N) >>.

byte() ->
    case rand:uniform(2) of
        1 -> lists:nth(rand:uniform(length(?STEERING)), ?STEERING);
        2 -> rand:uniform(256) - 1
    end.

%% A few byte flips, cuts and insertions, kept within the input bound.
mutate(Bytes) ->
    Mutated = lists:foldl(fun(_, B) -> mutate_once(B) end, Bytes, lists:seq(1, rand:uniform(4))),
    binary:part(Mutated, 0, min(byte_size(Mutated), ?MAX_INPUT)).

mutate_once(<<>>) ->
    random_bytes(rand:uniform(8));
mutate_once(B) ->
    At = rand:uniform(byte_size(B)) - 1,
    <<Head:At/binary, Rest/binary>> = B,
    case rand:uniform(3) of
        1 -> <<Head/binary, (byte()), (tail(Rest))/binary>>;
        2 -> Head;
        3 -> <<Head/binary, (random_bytes(rand:uniform(4)))/binary, Rest/binary>>
    end.

tail(<<_, Rest/binary>>) -> Rest;
tail(<<>>) -> <<>>.

%%% The line escape

line(Input) ->
    Out = guard(line_escape, Input, fun() -> erx_text:escape_line(Input) end),
    safe(Input, Out),
    Out =:= erx_text:escape_line(Out) orelse fail(line_not_idempotent, Input, Out),
    Reference = iolist_to_binary(reference(Input)),
    Out =:= Reference orelse fail(line_differs_from_reference, Input, {Out, Reference}),
    case unicode:characters_to_list(Input) of
        Chars when is_list(Chars) ->
            Out =:= erx_text:escape_line(Chars) orelse fail(line_list_differs, Input, Out);
        _ ->
            ok
    end.

%% Output must be UTF-8 and hold no unsafe character.
safe(Input, Out) ->
    case unicode:characters_to_list(Out) of
        Chars when is_list(Chars) ->
            [] =:= [C || C <- Chars, unsafe(C)] orelse fail(unsafe_output, Input, Out);
        _ ->
            fail(output_not_utf8, Input, Out)
    end.

%% The reference: table 3-7's well-formed sequences, the ranges searched one
%% by one, and the tokens as the catalog writes them.
reference(<<>>) ->
    [];
reference(Bytes) ->
    case well_formed(Bytes) of
        {Point, Rest} ->
            [case unsafe(Point) of
                 true -> token(<<"codepoint">>, Point);
                 false -> <<Point/utf8>>
             end | reference(Rest)];
        none ->
            <<B, Rest/binary>> = Bytes,
            [token(<<"byte">>, B) | reference(Rest)]
    end.

well_formed(<<A, Rest/binary>>) when A =< 16#7F ->
    {A, Rest};
well_formed(<<A, B, Rest/binary>>) when A >= 16#C2, A =< 16#DF, ?CONT(B) ->
    {((A band 16#1F) bsl 6) bor (B band 16#3F), Rest};
well_formed(<<A, B, C, Rest/binary>>) when A >= 16#E0, A =< 16#EF ->
    {Low, High} = case A of
                      16#E0 -> {16#A0, 16#BF};
                      16#ED -> {16#80, 16#9F};
                      _ -> {16#80, 16#BF}
                  end,
    case B >= Low andalso B =< High andalso ?CONT(C) of
        true -> {((A band 16#0F) bsl 12) bor ((B band 16#3F) bsl 6) bor (C band 16#3F), Rest};
        false -> none
    end;
well_formed(<<A, B, C, D, Rest/binary>>) when A >= 16#F0, A =< 16#F4 ->
    {Low, High} = case A of
                      16#F0 -> {16#90, 16#BF};
                      16#F4 -> {16#80, 16#8F};
                      _ -> {16#80, 16#BF}
                  end,
    case B >= Low andalso B =< High andalso ?CONT(C) andalso ?CONT(D) of
        true -> {((A band 16#07) bsl 18) bor ((B band 16#3F) bsl 12) bor ((C band 16#3F) bsl 6) bor (D band 16#3F),
                 Rest};
        false -> none
    end;
well_formed(_) ->
    none.

token(Name, Value) ->
    #{<<"token">> := #{Name := #{<<"prefix">> := Prefix, <<"minimum">> := Min, <<"suffix">> := Suffix}}} =
        erx_text_tables:catalog(),
    Digits = string:pad(integer_to_list(Value, 16), Min, leading, $0),
    [Prefix, Digits, Suffix].

unsafe(Point) ->
    lists:any(fun({First, Last}) -> Point >= First andalso Point =< Last end, get(ranges)).

%%% The field escape

field(Input) ->
    Out = guard(field_escape, Input, fun() -> erx_text:escape_field(Input) end),
    safe(Input, Out),
    nomatch =:= binary:match(Out, [<<"\t">>, <<"\n">>]) orelse fail(field_holds_tab_or_newline, Input, Out),
    Out =:= erx_text:escape_line(Out) orelse fail(field_changed_by_line_escape, Input, Out),
    {ok, Input} =:= erx_text:unescape_field(Out) orelse fail(field_round_trip, Input, Out),
    case guard(field_unescape, Input, fun() -> erx_text:unescape_field(Input) end) of
        {ok, Bytes} when is_binary(Bytes) ->
            erx_text:escape_field(Bytes) =:= Input orelse fail(field_unescape_not_inverse, Input, Bytes);
        {error, Reason} when Reason =:= malformed; Reason =:= noncanonical ->
            ok;
        Other ->
            fail(field_unescape_answer, Input, Other)
    end.

%%% Failures

guard(What, Input, Fun) ->
    try
        Fun()
    catch
        Class:Reason -> fail({What, raised}, Input, {Class, Reason})
    end.

fail(What, Input, Detail) ->
    io:format("~p on ~P:~n~P~n", [What, Input, 80, Detail, 80]),
    error({What, Input}).
