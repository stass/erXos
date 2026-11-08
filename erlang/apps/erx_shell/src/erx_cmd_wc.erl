%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_wc).
-moduledoc """
`wc [-c | -m] [-Llw] [file ...]`: counts the lines, words, and bytes or
characters of each file, or of standard input for none, as FreeBSD's wc
does (usr.bin/wc/wc.c), and prints them in its layout, so the output
diffs with FreeBSD's.

Flags. `-l` counts newlines, `-w` words, `-c` bytes, `-m` characters and
`-L` gives the longest line; with none of them it is `-lwc`. `-c` and
`-m` exclude each other, and the later one wins.

Output. One line per file: each count right-aligned after a space in a
field of seven, in the order lines, words, bytes or characters, longest
line, then a space and the name as given; for standard input no name.
More than one name adds a line of totals, named `total`, which adds up
the files that could be read and takes the longest line among them.

Counting, as FreeBSD does in a UTF-8 locale. A line is a newline, and the
longest line is the longest run ended by one, so a last line with no
newline is not measured. A word is a run of characters that are not
white space; white space is FreeBSD's `iswspace` set of C.UTF-8
(space/0). Without `-m` each byte is taken as the character of its value,
so a byte 0xA0 separates words. With `-m` the input decodes as UTF-8: a
byte that does not start a valid sequence counts as one character of its
value, and an incomplete sequence at the end counts as nothing; either is
reported once per file as `illegal byte sequence`, which does not change
the status. A sequence split between two reads counts as it would
whole, where FreeBSD's loses its first bytes when what follows does
not complete it. With `-m` the longest line is measured in characters,
otherwise in bytes.

Input. A file is read in pieces, so it has no bound on its size or its
lines. Standard input is read in whatever pieces are in flight
(erx_cmd:read/1).

Errors. A file that cannot be opened or read is reported in FreeBSD's
form, `wc: name: open: reason` or `wc: name: read: reason`, with the
reason in erXos's words (erx_cmd:format_error/1), and the rest are
still counted; the first such error is the status. A directory fails at
`open`, where FreeBSD's fails at `read`. `-` is a file name here, as in
FreeBSD's wc, not standard input.

The output is the command's own, so a name is written as given, as
FreeBSD's wc and `echo` write theirs. The counting is a pure core,
new/0, add/3, close/1 and line/3, which the tests drive directly; run/2
is the effects around it.
""".

-behaviour(erx_cmd).
-erx_command(wc).
-erx_usage("wc [-c | -m] [-Llw] [file ...]").

-export([run/2]).
-export([options/1, new/0, add/3, close/1, sum/2, line/3]).

-export_type([options/0, count/0]).

-define(PIECE, 65536).

-doc "Which counts to print. `size` is what `-c` or `-m` counts, if either.".
-type options() :: #{lines := boolean(), words := boolean(),
                     size := none | bytes | chars, longest := boolean()}.

%% A count of one input so far. `line_length` is the length of the line
%% not yet ended by a newline, `in_space` whether the last character was
%% white space (true at the start, so the first non-space starts a word),
%% `pending` the start of a UTF-8 sequence a later piece may complete, and
%% `illegal` whether an invalid or incomplete sequence was seen.
-record(count, {lines = 0 :: non_neg_integer(),
                words = 0 :: non_neg_integer(),
                size = 0 :: non_neg_integer(),
                longest = 0 :: non_neg_integer(),
                line_length = 0 :: non_neg_integer(),
                in_space = true :: boolean(),
                pending = <<>> :: binary(),
                illegal = false :: boolean()}).

-opaque count() :: #count{}.

%%% The command

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "clmwL") of
        {ok, Flags, Files} -> count_all(options(Flags), Files, Ctx);
        {error, usage} -> {error, usage}
    end.

count_all(Options, [], Ctx) ->
    Count = count_input(Options, new(), Ctx),
    warn_illegal(Count, <<"stdin">>, Ctx),
    erx_cmd:write(Ctx, line(Options, Count, stdin));
count_all(Options, Files, Ctx) ->
    Results = [count_named(Options, File, Ctx) || File <- Files],
    case Files of
        [_, _ | _] ->
            Total = lists:foldl(fun sum/2, new(), [Count || {ok, Count} <- Results]),
            erx_cmd:write(Ctx, line(Options, Total, <<"total">>));
        [_] ->
            ok
    end,
    case [Reason || {error, Reason} <- Results] of
        [] -> ok;
        [First | _] -> {error, {reported, First}}
    end.

%% One named file: its line, or the error already reported.
count_named(Options, File, Ctx) ->
    case file:open(erx_cmd:path(Ctx, File), [read, raw, binary]) of
        {ok, Fd} ->
            try count_file(Options, Fd, new()) of
                {ok, Count} ->
                    warn_illegal(Count, File, Ctx),
                    erx_cmd:write(Ctx, line(Options, Count, File)),
                    {ok, Count};
                {error, Reason} ->
                    erx_cmd:report(Ctx, [File, <<": read">>], Reason),
                    {error, Reason}
            after
                file:close(Fd)
            end;
        {error, Reason} ->
            erx_cmd:report(Ctx, [File, <<": open">>], Reason),
            {error, Reason}
    end.

count_file(Options, Fd, Count) ->
    case file:read(Fd, ?PIECE) of
        {ok, Bytes} -> count_file(Options, Fd, add(mode(Options), Bytes, Count));
        eof -> {ok, close(Count)};
        {error, _} = Error -> Error
    end.

count_input(Options, Count, Ctx) ->
    case erx_cmd:read(Ctx) of
        eof -> close(Count);
        Bytes -> count_input(Options, add(mode(Options), Bytes, Count), Ctx)
    end.

%% FreeBSD's warning for an input with an illegal sequence, given once.
warn_illegal(#count{illegal = true}, Name, Ctx) -> erx_cmd:report(Ctx, Name, eilseq);
warn_illegal(_Count, _Name, _Ctx) -> ok.

%%% The counting core

-doc "The options a list of flag letters gives, as FreeBSD's getopt loop sets them.".
-spec options([char()]) -> options().
options(Flags) ->
    Set = lists:foldl(fun option/2,
                      #{lines => false, words => false, size => none, longest => false}, Flags),
    case Set of
        #{lines := false, words := false, size := none, longest := false} ->
            Set#{lines := true, words := true, size := bytes};
        _ ->
            Set
    end.

option($l, Set) -> Set#{lines := true};
option($w, Set) -> Set#{words := true};
option($c, Set) -> Set#{size := bytes};
option($m, Set) -> Set#{size := chars};
option($L, Set) -> Set#{longest := true}.

%% How to count: decode characters for `-m`; only find newlines when no
%% word or longest line is asked for; otherwise take each byte as a
%% character.
mode(#{size := chars}) -> chars;
mode(#{words := false, longest := false}) -> newlines;
mode(_Options) -> bytes.

-doc "A count of nothing.".
-spec new() -> count().
new() -> #count{}.

-doc """
Adds a piece of input in a mode. `newlines` counts only lines and
bytes, for when no word or longest line is asked for; `bytes` takes each byte as a
character; `chars` decodes UTF-8, keeping a sequence the piece ends in
the middle of for the next piece.
""".
-spec add(newlines | bytes | chars, binary(), count()) -> count().
add(newlines, Bytes, #count{lines = Lines, size = Size} = Count) ->
    Count#count{lines = Lines + newlines(Bytes, 0, 0), size = Size + byte_size(Bytes)};
add(bytes, Bytes, Count) ->
    scan_bytes(Bytes, Count);
add(chars, Bytes, #count{pending = Pending} = Count) ->
    scan_chars(<<Pending/binary, Bytes/binary>>, Count#count{pending = <<>>}).

%% The newlines of Bytes from From on, found one at a time so that a
%% piece of short lines takes no memory per line.
newlines(Bytes, From, Seen) ->
    case binary:match(Bytes, <<"\n">>, [{scope, {From, byte_size(Bytes) - From}}]) of
        {At, 1} -> newlines(Bytes, At + 1, Seen + 1);
        nomatch -> Seen
    end.

-doc """
Ends the input: an incomplete UTF-8 sequence left over counts as nothing
and marks the count as having seen an illegal sequence.
""".
-spec close(count()) -> count().
close(#count{pending = <<>>} = Count) -> Count;
close(Count) -> Count#count{pending = <<>>, illegal = true}.

-doc "Two counts added, the longest line being the longer of the two.".
-spec sum(count(), count()) -> count().
sum(#count{lines = L1, words = W1, size = S1, longest = M1},
    #count{lines = L2, words = W2, size = S2, longest = M2}) ->
    #count{lines = L1 + L2, words = W1 + W2, size = S1 + S2, longest = max(M1, M2)}.

-doc """
A count's output line in FreeBSD's layout, `" %7ju"` per count, then
`" name"` unless the input is standard input, and a newline.
""".
-spec line(options(), count(), binary() | stdin) -> iodata().
line(#{lines := Lines, words := Words, size := Size, longest := Longest}, Count, Name) ->
    Shown = [N || {true, N} <- [{Lines, Count#count.lines},
                                {Words, Count#count.words},
                                {Size =/= none, Count#count.size},
                                {Longest, Count#count.longest}]],
    [[field(N) || N <- Shown], name(Name), $\n].

%% printf's " %7ju": a wider number widens the field rather than being cut.
field(N) ->
    Digits = integer_to_binary(N),
    [$\s, binary:copy(<<" ">>, max(0, 7 - byte_size(Digits))), Digits].

name(stdin) -> [];
name(Name) -> [$\s, Name].

scan_bytes(<<Byte, Rest/binary>>, Count) ->
    scan_bytes(Rest, step(Byte, Count));
scan_bytes(<<>>, Count) ->
    Count.

scan_chars(<<>>, Count) ->
    Count;
scan_chars(Bytes, Count) ->
    case char(Bytes) of
        {valid, Char, Rest} -> scan_chars(Rest, step(Char, Count));
        {invalid, Byte, Rest} -> scan_chars(Rest, step(Byte, Count#count{illegal = true}));
        incomplete -> Count#count{pending = Bytes}
    end.

%% The next character of UTF-8, decoded as FreeBSD's mbrtowc decodes it:
%% Erlang's utf8 segment accepts exactly the sequences it accepts (no
%% overlong form, no surrogate, nothing above U+10FFFF). Otherwise the
%% first byte is invalid, unless it starts a sequence of the right shape
%% that the bytes end before it is complete.
char(<<Char/utf8, Rest/binary>>) ->
    {valid, Char, Rest};
char(<<Lead, Rest/binary>>) ->
    Want = sequence_length(Lead),
    case Want > 0 andalso byte_size(Rest) < Want - 1 andalso continuations(Rest) of
        true -> incomplete;
        false -> {invalid, Lead, Rest}
    end.

sequence_length(Lead) when Lead >= 16#C0, Lead =< 16#DF -> 2;
sequence_length(Lead) when Lead >= 16#E0, Lead =< 16#EF -> 3;
sequence_length(Lead) when Lead >= 16#F0, Lead =< 16#F7 -> 4;
sequence_length(_Lead) -> 0.

continuations(Bytes) ->
    lists:all(fun(Byte) -> Byte band 16#C0 =:= 16#80 end, binary_to_list(Bytes)).

%% One character counted, as the loop of FreeBSD's cnt() counts it.
step($\n, #count{lines = Lines, size = Size, longest = Longest, line_length = Length} = Count) ->
    Count#count{lines = Lines + 1, size = Size + 1, longest = max(Longest, Length),
                line_length = 0, in_space = true};
step(Char, #count{size = Size, line_length = Length} = Count) ->
    word(space(Char), Count#count{size = Size + 1, line_length = Length + 1}).

word(true, Count) -> Count#count{in_space = true};
word(false, #count{in_space = true, words = Words} = Count) ->
    Count#count{in_space = false, words = Words + 1};
word(false, Count) -> Count.

%% FreeBSD's iswspace in C.UTF-8 (share/ctypedef/C.UTF-8.src): its space
%% class, with tab, newline, vertical tab, form feed and carriage return,
%% which localedef adds for POSIX.
space(Char) when Char >= $\t, Char =< $\r -> true;
space($\s) -> true;
space(16#A0) -> true;
space(16#1680) -> true;
space(Char) when Char >= 16#2000, Char =< 16#200A -> true;
space(16#2028) -> true;
space(16#2029) -> true;
space(16#202F) -> true;
space(16#205F) -> true;
space(16#3000) -> true;
space(_Char) -> false.
