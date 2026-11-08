%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_sort).
-moduledoc """
`sort [-nru] [-k field[,field]] [file ...]`: FreeBSD's sort
(usr.bin/sort) with a small core of its options, comparing text as bytes,
as FreeBSD's does under `LC_ALL=C` (docs/design-shell.md, "Text
commands").

Lines are compared by their keys, each `-k` in the order given, or the
whole line when none is given; the newline is no part of a line. A key
`-k F` runs from the start of field F to the end of the line, and `-k
F,G` to the end of field G. A field starts where a run of blanks (space
or tab) begins after the previous field's text, so a field holds its
leading blanks, as FreeBSD's do without `-b`; a field past the end of a
line is empty. `-n` compares the number at the start of each key:
optional blanks, an optional `-`, digits and a decimal point, compared
exactly as decimals; a key with no number is zero, so a column header and
a `-` sort among the zeros. `-r` reverses every comparison.

Lines with equal keys are ordered by a last comparison of the whole lines,
reversed under `-r`, as FreeBSD's top_level_str_coll() orders them
(usr.bin/sort/coll.c). `-u` turns that off, as on FreeBSD, and writes
the first line, in input order, of each set with equal keys. A last line
without a newline gets one.

Input. Standard input is read line by line, each at most 64 KiB
(erx_cmd:read_line/1); a file is read whole. Every line is held until
the input ends, within the stage's heap limit (docs/design-shell.md,
"Bounds"), where FreeBSD's spills to temporary files. `-` names standard
input. A file that cannot be read is reported as `sort: name: reason`
before anything is written, and the status is 2, as on FreeBSD.
""".

-behaviour(erx_cmd).
-erx_command(sort).
-erx_usage("sort [-nru] [-k field[,field]] [file ...]").

-export([run/2]).
-export([options/1, sort/2, key/2, number/1]).

-export_type([options/0]).

-type key() :: {First :: pos_integer(), Last :: pos_integer() | eol}.
-type options() :: #{numeric := boolean(), reverse := boolean(),
                     unique := boolean(), keys := [key()]}.

%% A field number is at most this, so finding a field stays cheap.
-define(MAX_FIELD, 1 bsl 16).

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "nruk:") of
        {ok, Flags, Files} ->
            case options(Flags) of
                {ok, Options} -> sort_files(Options, Files, Ctx);
                {error, usage} -> {error, usage}
            end;
        {error, usage} ->
            {error, usage}
    end.

sort_files(Options, Files, Ctx) ->
    Inputs = [input(File, Ctx) || File <- case Files of [] -> [<<"-">>]; _ -> Files end],
    case [{File, Reason} || {error, File, Reason} <- Inputs] of
        [] ->
            Lines = lists:append([Lines || {ok, Lines} <- Inputs]),
            erx_cmd:write(Ctx, [[Line, $\n] || Line <- sort(Options, Lines)]);
        Failed ->
            [erx_cmd:say(Ctx, [<<"sort: ">>, File, <<": ">>, erx_cmd:format_error(Reason), $\n])
             || {File, Reason} <- Failed],
            {error, {reported, <<"2">>}}
    end.

%% A file's lines, without their newlines.
input(<<"-">>, Ctx) ->
    {ok, read_lines(Ctx, [])};
input(File, Ctx) ->
    case file:read_file(erx_cmd:path(Ctx, File)) of
        {ok, Bytes} -> {ok, split(Bytes)};
        {error, Reason} -> {error, File, Reason}
    end.

read_lines(Ctx, Acc) ->
    case erx_cmd:read_line(Ctx) of
        eof -> lists:reverse(Acc);
        Line -> read_lines(Ctx, [chomp(Line) | Acc])
    end.

split(<<>>) -> [];
split(Bytes) ->
    Lines = binary:split(Bytes, <<"\n">>, [global]),
    case lists:last(Lines) of
        <<>> -> lists:droplast(Lines);
        _ -> Lines
    end.

chomp(Line) ->
    case binary:last(Line) of
        $\n -> binary:part(Line, 0, byte_size(Line) - 1);
        _ -> Line
    end.

%%% The pure core

-doc "The options a list of flags gives, or `{error, usage}`.".
-spec options([char() | {char(), binary()}]) -> {ok, options()} | {error, usage}.
options(Flags) ->
    lists:foldl(fun(_Flag, {error, usage}) -> {error, usage};
                   ($n, {ok, O}) -> {ok, O#{numeric := true}};
                   ($r, {ok, O}) -> {ok, O#{reverse := true}};
                   ($u, {ok, O}) -> {ok, O#{unique := true}};
                   ({$k, Spec}, {ok, #{keys := Keys} = O}) ->
                        case key_spec(Spec) of
                            {ok, Key} -> {ok, O#{keys := Keys ++ [Key]}};
                            error -> {error, usage}
                        end
                end,
                {ok, #{numeric => false, reverse => false, unique => false, keys => []}},
                Flags).

key_spec(Spec) ->
    case binary:split(Spec, <<",">>) of
        [First] -> key_spec(field(First), eol);
        [First, Last] -> key_spec(field(First), field(Last))
    end.

key_spec(First, eol) when is_integer(First) -> {ok, {First, eol}};
key_spec(First, Last) when is_integer(First), is_integer(Last), Last >= First -> {ok, {First, Last}};
key_spec(_First, _Last) -> error.

field(Text) when byte_size(Text) > 0, byte_size(Text) =< 5 ->
    case all_digits(Text) andalso binary_to_integer(Text) of
        N when is_integer(N), N >= 1, N =< ?MAX_FIELD -> N;
        _ -> bad
    end;
field(_Text) ->
    bad.

all_digits(Text) -> lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Text)).

-doc """
The lines in order: by their keys, then, unless `-u`, by the whole lines;
under `-u`, the first line of each set with equal keys.
""".
-spec sort(options(), [binary()]) -> [binary()].
sort(#{unique := Unique} = Options, Lines) ->
    Keyed = [{keys(Options, Line), Index, Line} || {Index, Line} <- lists:enumerate(Lines)],
    Sorted = lists:sort(fun(A, B) -> before(Options, A, B) end, Keyed),
    case Unique of
        true -> firsts(Sorted);
        false -> [Line || {_, _, Line} <- Sorted]
    end.

%% A keyed line comes before another when its keys compare lower, then,
%% unless `-u`, its whole line, each reversed under `-r`, then its place
%% in the input, so the sort is stable and `-u` keeps the first.
before(#{reverse := Reverse, unique := Unique}, {KeysA, IndexA, LineA}, {KeysB, IndexB, LineB}) ->
    Order = case compare(KeysA, KeysB) of
                eq when Unique -> eq;
                eq -> compare(LineA, LineB);
                Ordered -> Ordered
            end,
    case {Order, Reverse} of
        {eq, _} -> IndexA =< IndexB;
        {lt, false} -> true;
        {gt, true} -> true;
        _ -> false
    end.

firsts([{Keys, _, Line} | Rest]) ->
    [Line | firsts(lists:dropwhile(fun({Next, _, _}) -> Next =:= Keys end, Rest))];
firsts([]) ->
    [].

%% A line's keys, each a term that orders as the key compares: its bytes,
%% or under `-n` its number.
keys(#{keys := [], numeric := Numeric}, Line) -> [value(Numeric, Line)];
keys(#{keys := Keys, numeric := Numeric}, Line) -> [value(Numeric, key(Key, Line)) || Key <- Keys].

value(true, Key) -> number(Key);
value(false, Key) -> Key.

compare(A, B) when A < B -> lt;
compare(A, B) when A > B -> gt;
compare(_A, _B) -> eq.

-doc """
A key's text: from the start of its first field to the end of the line,
or to the end of its last field. A field starts where a run of blanks
begins after the previous field's text.
""".
-spec key(key(), binary()) -> binary().
key({First, Last}, Line) ->
    Start = field_start(First, Line),
    End = case Last of
              eol -> byte_size(Line);
              _ -> field_end(field_start(Last, Line), Line)
          end,
    binary:part(Line, Start, max(0, End - Start)).

%% Field N's start: field 1 starts the line, and each later one where the
%% previous field's blanks and text end.
field_start(N, Line) -> field_start(N, 0, Line).

field_start(1, At, _Line) -> At;
field_start(N, At, Line) -> field_start(N - 1, field_end(At, Line), Line).

field_end(At, Line) -> skip(fun(C) -> not blank(C) end, skip(fun blank/1, At, Line), Line).

skip(Pred, At, Line) when At < byte_size(Line) ->
    case Pred(binary:at(Line, At)) of
        true -> skip(Pred, At + 1, Line);
        false -> At
    end;
skip(_Pred, At, _Line) -> At.

blank(C) -> C =:= $\s orelse C =:= $\t.

-doc """
The number at the start of a key, as a term that orders as the number
does: leading blanks, an optional `-`, digits and an optional decimal
point and digits. A key with no digits is zero, whatever its sign.
""".
-spec number(binary()) -> term().
number(Key) ->
    {Negative, Digits} = case skip_blanks(Key) of
                             <<"-", Rest/binary>> -> {true, Rest};
                             Rest -> {false, Rest}
                         end,
    {Int, AfterInt} = digits(Digits),
    Frac = case AfterInt of
               <<".", Fraction/binary>> -> element(1, digits(Fraction));
               _ -> <<>>
           end,
    order(Negative, strip_leading(Int), strip_trailing(Frac)).

%% Zero is one value whatever its spelling. A positive number orders by
%% the count of its integer digits, then its digits, then its fraction,
%% whose shorter prefix is the smaller; a negative one orders the reverse
%% way, by the complement of each part, the fraction closed by the highest
%% byte so that a shorter prefix becomes the larger.
order(_Negative, <<>>, <<>>) -> {0, 0, <<>>, <<>>};
order(false, Int, Frac) -> {1, byte_size(Int), Int, Frac};
order(true, Int, Frac) -> {-1, -byte_size(Int), complement(Int), <<(complement(Frac))/binary, 255>>}.

complement(Digits) -> << <<(255 - C)>> || <<C>> <= Digits >>.

skip_blanks(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t -> skip_blanks(Rest);
skip_blanks(Bytes) -> Bytes.

digits(Bytes) ->
    N = byte_size(Bytes) - byte_size(skip_digits(Bytes)),
    {binary:part(Bytes, 0, N), binary:part(Bytes, N, byte_size(Bytes) - N)}.

skip_digits(<<C, Rest/binary>>) when C >= $0, C =< $9 -> skip_digits(Rest);
skip_digits(Bytes) -> Bytes.

strip_leading(<<"0", Rest/binary>>) -> strip_leading(Rest);
strip_leading(Int) -> Int.

strip_trailing(<<>>) -> <<>>;
strip_trailing(Frac) ->
    case binary:last(Frac) of
        $0 -> strip_trailing(binary:part(Frac, 0, byte_size(Frac) - 1));
        _ -> Frac
    end.
