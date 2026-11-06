%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_lex).
-moduledoc """
The command shell's tokenizer: rc's lexical rules over one line or script
(docs/design-shell.md, "The language"), as a pure function from bytes to
tokens.

`tokens/1` refuses a source over 64 KiB before reading it, then reads it
once from start to end, as if it ended with a newline, and returns every
token with the byte offset where it starts; `position/2` turns an offset
into the line and column, both counted in bytes from 1, that a diagnostic
names. It reads as plan9port's rc reads (its lex.c):

* A word is a run of bytes outside ``\n \t#;&|^$=`'{}()<>``; one of `for`,
  `in`, `while`, `if`, `not`, `switch`, `fn`, `~`, `!` and `@` written
  unquoted is a keyword, and the parser takes a keyword where a word is
  wanted as that word. After `$`, `$#` or `$"` a word is a name: it stops
  at the first byte that cannot be in a variable's name, so `$stem.c` is
  `$stem` and `.c`, and it is never a keyword.
* `'...'` is the one quoting rule, with `''` for a quote inside, and may
  span lines.
* Straight after a word or a quoted word, with nothing between them, `(`
  is a subscript (`sub`) and the start of another word gets the caret rc
  inserts (`caret`), so `$x(2)` subscripts and `-$flag.c` concatenates.
  After a keyword neither happens, as in rc.
* A backslash before a newline outside quotes and comments reads as a
  space; `#` starts a comment, which ends at the next newline.
* `>`, `>>`, `<`, `<>` and `<<` take an optional descriptor, `>[2]`;
  `>[2=1]` is a `dup` and `>[2=]` a `close`; `|` takes `|[2]` or `|[2=3]`,
  which connects descriptor 2 of the left command to descriptor 3 of the
  right one. `<` or `>` followed by `{` is a `pipefd` word, rc's `<{cmd}`.
* `<<tag` is a here document: its body is the lines after the next
  newline up to a line that is exactly the tag. A quoted tag gives the body
  as it is written (`literal`); an unquoted one gives a `template` in which
  `$name` names a variable, a `^` straight after the name is dropped, and
  `$$` stands for `$`, as rc substitutes it.

The tokens end with `eof`, or, where the source cannot be read on, with an
`error` token that says why in fixed words, so the parser reports whichever
fault comes first. Nothing the source holds makes the tokenizer raise, and
no diagnostic quotes the source, so a sink that shows one has nothing
untrusted to escape. An error is `incomplete` when only more lines could
cure it: an open quote, an unterminated here document or a line continued
at its end. Every text a token carries is a copy, so the tokens hold no
reference to the source.
""".

-export([tokens/1, position/2, max_bytes/0]).

-export_type([token/0, offset/0, fd/0, doc/0, keyword/0, fault/0]).

%% The bound on a line or script (docs/design-shell.md, "Overview").
-define(MAX_BYTES, 65536).
%% The largest descriptor number a redirection may name.
-define(MAX_FD, 16#7fffffff).

-type offset() :: non_neg_integer().
-type fd() :: 0..?MAX_FD.
-type keyword() :: for | in | while | 'if' | 'not' | switch | fn
                 | '~' | '!' | '@'.
%% A here document's body: as written, or text and the variables in it.
-type doc() :: {literal, binary()}
             | {template, [binary() | {var, Name :: binary()}]}.
%% Why the source cannot be read on from an `error` token's offset.
-type fault() :: {syntax | incomplete, Message :: binary()}.
-type token() ::
        {word | quoted, offset(), binary()}
      | {keyword, offset(), keyword()}
      | {caret | sub | dollar | count | flat | backquote | andand | oror
         | newline | eof | ';' | '&' | '=' | '{' | '}' | '(' | ')',
         offset(), none}
      | {redir, offset(), {write | append | read | rdwr, fd()}}
      | {heredoc, offset(), {fd(), doc()}}
      | {dup, offset(), {To :: fd(), From :: fd()}}
      | {close, offset(), fd()}
      | {pipe, offset(), {Left :: fd(), Right :: fd()}}
      | {pipefd, offset(), read | write}
      | {error, offset(), fault()}.

%% A here document whose tag a line named, waiting for that line's end.
-record(pending, {id :: non_neg_integer(), tag :: binary(), quoted :: boolean(),
                  at :: offset()}).

%% The reader's state. `word` and `dollar` are rc's lastword and lastdol:
%% the last token was a word, so a caret or a subscript may follow it; the
%% last token was `$`, `$#` or `$"`, so a name follows. `continued` says the
%% last byte read ended a backslash-newline. Here documents wait in `docs`,
%% newest first, until their line's newline; `bodies` keeps each one read
%% by its id. Until finish/2, a heredoc token holds that id, not its body.
-record(lx, {bin :: binary(),
             at = 0 :: offset(),
             word = false :: boolean(),
             dollar = false :: boolean(),
             continued = false :: boolean(),
             docs = [] :: [#pending{}],
             next_doc = 0 :: non_neg_integer(),
             bodies = #{} :: #{non_neg_integer() => doc()}}).

-doc "The largest source, in bytes, that tokens/1 reads.".
-spec max_bytes() -> pos_integer().
max_bytes() -> ?MAX_BYTES.

-doc """
The tokens of `Source`, ending with `eof` or an `error` token, or
`too_long` for a source over max_bytes().
""".
-spec tokens(binary()) -> {ok, [token(), ...]}
                              | {error, {too_long, pos_integer()}}.
tokens(Source) when byte_size(Source) > ?MAX_BYTES ->
    {error, {too_long, byte_size(Source)}};
tokens(Source) when is_binary(Source) ->
    Text = case Source of
               <<>> -> Source;
               _ when binary_part(Source, byte_size(Source), -1) =:= <<"\n">> -> Source;
               _ -> <<Source/binary, "\n">>
           end,
    {ok, lex(#lx{bin = Text}, [])}.

-doc """
The line and column of an offset into `Source`, both counted in bytes from
1. An offset at or past the end, such as that of the newline tokens/1
reads after a source that has none, names the column after its last byte.
""".
-spec position(binary(), offset()) -> {pos_integer(), pos_integer()}.
position(Source, Offset) ->
    At = min(Offset, byte_size(Source)),
    case binary:matches(binary_part(Source, 0, At), <<"\n">>) of
        [] -> {1, At + 1};
        Newlines ->
            {Last, 1} = lists:last(Newlines),
            {length(Newlines) + 1, At - Last}
    end.

lex(L, Acc) ->
    case adjacent(L) of
        {Token, L1} ->
            lex(L1, [Token | Acc]);
        none ->
            L1 = skip_blanks(L#lx{word = false}),
            case read(L1) of
                {more, Token, L2} -> lex(L2, [Token | Acc]);
                {last, Token, L2} -> finish(L2, [Token | Acc])
            end
    end.

%% One token, the end, or the fault that stops the reading.
read(L) ->
    try
        case peek(L) of
            eof ->
                ok = complete(L),
                {last, {eof, L#lx.at, none}, L};
            _ ->
                {Token, L1} = token(L, L#lx.at),
                {more, Token, L1}
        end
    catch
        throw:{?MODULE, At, Fault} -> {last, {error, At, Fault}, L}
    end.

%% What rc makes of a byte straight after a word: `(` subscripts it and the
%% start of another word is joined to it by a caret, which consumes nothing.
adjacent(#lx{word = false}) ->
    none;
adjacent(L) ->
    case peek(L) of
        $( ->
            {{sub, L#lx.at, none}, plain(advance(L))};
        C ->
            case starts_joined(C) of
                true -> {{caret, L#lx.at, none}, plain(L)};
                false -> none
            end
    end.

starts_joined(C) ->
    C =:= $' orelse C =:= $` orelse C =:= $$ orelse word_char(C).

token(L, At) ->
    case peek(L) of
        $\n ->
            {{newline, At, none}, here_documents(plain(advance(L)))};
        $$ ->
            dollar(advance(L), At);
        $& ->
            L1 = advance(L),
            case peek(L1) of
                $& -> {{andand, At, none}, plain(advance(L1))};
                _ -> {{'&', At, none}, plain(L1)}
            end;
        $| ->
            L1 = advance(L),
            case peek(L1) of
                $| -> {{oror, At, none}, plain(advance(L1))};
                _ -> pipe(L1, At)
            end;
        $> ->
            L1 = advance(L),
            case peek(L1) of
                $> -> redirection(advance(L1), At, append, 1);
                _ -> redirection(L1, At, write, 1)
            end;
        $< ->
            L1 = advance(L),
            case peek(L1) of
                $< -> here_document(advance(L1), At);
                $> -> redirection(advance(L1), At, rdwr, 0);
                _ -> redirection(L1, At, read, 0)
            end;
        $' ->
            {Text, L1} = quoted(L),
            {{quoted, At, Text}, (plain(L1))#lx{word = true}};
        C ->
            case word_char(C) of
                true -> word(L, At);
                false -> {{punctuation(C), At, none}, plain(advance(L))}
            end
    end.

%% Every byte that is neither a word's, a blank, `#` nor one token() reads
%% above stands alone.
punctuation($;) -> ';';
punctuation($^) -> caret;
punctuation($=) -> '=';
punctuation($`) -> backquote;
punctuation(${) -> '{';
punctuation($}) -> '}';
punctuation($() -> '(';
punctuation($)) -> ')'.

dollar(L, At) ->
    Name = (plain(L))#lx{dollar = true},
    case peek(L) of
        $# -> {{count, At, none}, advance(Name)};
        $" -> {{flat, At, none}, advance(Name)};
        _ -> {{dollar, At, none}, Name}
    end.

%% A word's first byte is always its own; after `$` the rest are a name's,
%% and a name is never a keyword.
word(#lx{dollar = Dollar} = L, At) ->
    More = case Dollar of
               true -> fun id_char/1;
               false -> fun word_char/1
           end,
    L1 = scan(advance(L), More),
    Text = binary:copy(binary_part(L#lx.bin, At, L1#lx.at - At)),
    case Dollar orelse keyword(Text) =:= none of
        true -> {{word, At, Text}, (plain(L1))#lx{word = true}};
        false -> {{keyword, At, keyword(Text)}, plain(L1)}
    end.

scan(L, More) ->
    case More(peek(L)) of
        true -> scan(advance(L), More);
        false -> L
    end.

keyword(<<"for">>) -> for;
keyword(<<"in">>) -> in;
keyword(<<"while">>) -> while;
keyword(<<"if">>) -> 'if';
keyword(<<"not">>) -> 'not';
keyword(<<"switch">>) -> switch;
keyword(<<"fn">>) -> fn;
keyword(<<"~">>) -> '~';
keyword(<<"!">>) -> '!';
keyword(<<"@">>) -> '@';
keyword(_) -> none.

%% The text of the quoted word at the reader, a copy, and the reader after
%% its closing quote. Bytes inside are taken as they are.
quoted(#lx{at = Open} = L) ->
    quoted(L#lx{at = Open + 1}, Open, []).

quoted(#lx{bin = B, at = At} = L, Open, Acc) ->
    case binary:match(B, <<"'">>, [{scope, {At, byte_size(B) - At}}]) of
        nomatch ->
            fault(Open, incomplete, <<"quoted word is not closed">>);
        {Quote, 1} ->
            Chunk = binary_part(B, At, Quote - At),
            case B of
                <<_:(Quote + 1)/binary, $', _/binary>> ->
                    quoted(move(L, Quote + 2), Open, [$', Chunk | Acc]);
                _ ->
                    Text = iolist_to_binary(lists:reverse(Acc, [Chunk])),
                    {binary:copy(Text), move(L, Quote + 1)}
            end
    end.

%% The descriptor part of a redirection or a pipe, read straight after its
%% arrow: absent (`{default, Fd}`), `[N]` (`{named, N}`), `[N=M]` or `[N=]`.
bracket(L, At, Default) ->
    case peek(L) of
        $[ ->
            {N, L1} = number(advance(L), At),
            case peek(L1) of
                $= ->
                    L2 = advance(L1),
                    case peek(L2) of
                        C when C >= $0, C =< $9 ->
                            {M, L3} = number(L2, At),
                            {{dup, N, M}, close_bracket(L3, At)};
                        _ ->
                            {{close, N}, close_bracket(L2, At)}
                    end;
                _ ->
                    {{named, N}, close_bracket(L1, At)}
            end;
        _ ->
            {{default, Default}, L}
    end.

number(L, At) ->
    case peek(L) of
        C when C >= $0, C =< $9 -> digits(L, 0, At);
        _ -> malformed(At)
    end.

digits(L, N, At) ->
    case peek(L) of
        C when C >= $0, C =< $9 ->
            case N * 10 + C - $0 of
                N1 when N1 > ?MAX_FD ->
                    fault(At, syntax, <<"descriptor number is too large">>);
                N1 ->
                    digits(advance(L), N1, At)
            end;
        _ ->
            {N, L}
    end.

close_bracket(L, At) ->
    case peek(L) of
        $] -> advance(L);
        _ -> malformed(At)
    end.

malformed(At) ->
    fault(At, syntax, <<"malformed redirection">>).

%% `|`, `|[N]` or `|[N=M]`: descriptor N of the left command, 1 unless
%% named, to descriptor M of the right one, 0 unless named.
pipe(L, At) ->
    case bracket(L, At, 1) of
        {{dup, Left, Right}, L1} -> {{pipe, At, {Left, Right}}, plain(L1)};
        {{close, _}, _} -> fault(At, syntax, <<"malformed pipe">>);
        {{_, Left}, L1} -> {{pipe, At, {Left, 0}}, plain(L1)}
    end.

%% A redirection with no descriptor written, followed by `{`, is rc's
%% `<{cmd}` or `>{cmd}`, a word; the `{` is left for the next token.
redirection(L, At, Kind, Default) ->
    case bracket(L, At, Default) of
        {{Named, Fd}, L1} when Named =:= default; Named =:= named ->
            L2 = skip_blanks(L1),
            case peek(L2) of
                ${ when Named =:= default, (Kind =:= read orelse Kind =:= write) ->
                    {{pipefd, At, Kind}, plain(L2)};
                ${ ->
                    malformed(At);
                _ ->
                    {{redir, At, {Kind, Fd}}, plain(L2)}
            end;
        {{dup, To, From}, L1} when Kind =/= append ->
            {{dup, At, {To, From}}, plain(L1)};
        {{close, Fd}, L1} when Kind =/= append ->
            {{close, At, Fd}, plain(L1)};
        _ ->
            malformed(At)
    end.

%% `<<` and its tag, one plain or quoted word.
here_document(L, At) ->
    case bracket(L, At, 0) of
        {{Named, Fd}, L1} when Named =:= default; Named =:= named ->
            here_tag(skip_blanks(L1), At, Fd);
        _ ->
            malformed(At)
    end.

here_tag(L, At, Fd) ->
    {Tag, Quoted, L1} =
        case peek(L) of
            $' ->
                {Text, After} = quoted(L),
                {Text, true, After};
            C ->
                case word_char(C) of
                    true ->
                        After = scan(advance(L), fun word_char/1),
                        Text = binary_part(L#lx.bin, L#lx.at, After#lx.at - L#lx.at),
                        {binary:copy(Text), false, After};
                    false ->
                        fault(At, syntax, <<"here document has no tag">>)
                end
        end,
    case adjacent(L1#lx{word = true}) of
        none -> ok;
        {_, _} -> fault(At, syntax, <<"here document tag is not one word">>)
    end,
    Id = L1#lx.next_doc,
    Pending = #pending{id = Id, tag = Tag, quoted = Quoted, at = At},
    {{heredoc, At, {Fd, Id}},
     plain(L1#lx{docs = [Pending | L1#lx.docs], next_doc = Id + 1})}.

%% At a newline, the bodies of the here documents its line named, in order.
here_documents(#lx{docs = []} = L) ->
    L;
here_documents(#lx{docs = Docs} = L) ->
    lists:foldl(fun read_body/2, L#lx{docs = []}, lists:reverse(Docs)).

read_body(#pending{id = Id, tag = Tag, quoted = Quoted, at = At},
          #lx{bin = B, at = Start} = L) ->
    {Body, End} = body_lines(B, Start, Start, Tag, At),
    Doc = case Quoted of
              true -> {literal, binary:copy(Body)};
              false -> {template, template(Body)}
          end,
    (move(L, End))#lx{bodies = (L#lx.bodies)#{Id => Doc}}.

%% The body from Start up to the line that is exactly Tag, and the offset
%% after that line. The source ends with a newline, so every line has one.
body_lines(B, Start, LineStart, Tag, At) ->
    Scope = {scope, {LineStart, byte_size(B) - LineStart}},
    case binary:match(B, <<"\n">>, [Scope]) of
        {Newline, 1} ->
            case binary_part(B, LineStart, Newline - LineStart) of
                Tag -> {binary_part(B, Start, LineStart - Start), Newline + 1};
                _ -> body_lines(B, Start, Newline + 1, Tag, At)
            end;
        nomatch ->
            unterminated(At)
    end.

unterminated(At) ->
    fault(At, incomplete, <<"here document is not terminated">>).

%% An unquoted body as text and variables, as rc's psubst reads it: `$$` is
%% `$`, `$` and a name is the variable, a `^` after the name is dropped,
%% and `$` with no name stands for nothing.
template(Body) ->
    template(Body, 0, []).

template(Body, At, Acc) ->
    Scope = {scope, {At, byte_size(Body) - At}},
    case binary:match(Body, <<"$">>, [Scope]) of
        nomatch ->
            Rest = binary_part(Body, At, byte_size(Body) - At),
            lists:reverse(text(Rest, Acc));
        {Dollar, 1} ->
            Acc1 = text(binary_part(Body, At, Dollar - At), Acc),
            case Body of
                <<_:(Dollar + 1)/binary, $$, _/binary>> ->
                    template(Body, Dollar + 2, text(<<"$">>, Acc1));
                _ ->
                    End = name_end(Body, Dollar + 1),
                    Next = case Body of
                               <<_:End/binary, $^, _/binary>> -> End + 1;
                               _ -> End
                           end,
                    template(Body, Next, variable(Body, Dollar + 1, End, Acc1))
            end
    end.

variable(_Body, End, End, Acc) ->
    Acc;
variable(Body, Start, End, Acc) ->
    [{var, binary:copy(binary_part(Body, Start, End - Start))} | Acc].

name_end(Body, At) ->
    case Body of
        <<_:At/binary, C, _/binary>> ->
            case id_char(C) of
                true -> name_end(Body, At + 1);
                false -> At
            end;
        _ ->
            At
    end.

%% Text joins the text before it, so a template never holds two in a row.
text(<<>>, Acc) ->
    Acc;
text(Text, [Previous | Acc]) when is_binary(Previous) ->
    [<<Previous/binary, Text/binary>> | Acc];
text(Text, Acc) ->
    [binary:copy(Text) | Acc].

%% The end of the source is the end of the input only when nothing waits.
complete(#lx{docs = [_ | _] = Docs}) ->
    unterminated((lists:last(Docs))#pending.at);
complete(#lx{continued = true, at = At}) ->
    fault(At, incomplete, <<"line continues past the end of the input">>);
complete(_) ->
    ok.

%% The tokens in order, each here document's body in its token: one pass,
%% so the list is copied once.
finish(#lx{bodies = Bodies}, Acc) ->
    lists:foldl(fun(Token, Tokens) -> [fill(Token, Bodies) | Tokens] end, [], Acc).

%% A body is missing only when an error token stopped the reading first, and
%% the parse fails there; the token gets an empty one.
fill({heredoc, At, {Fd, Id}}, Bodies) ->
    {heredoc, At, {Fd, maps:get(Id, Bodies, {literal, <<>>})}};
fill(Token, _) ->
    Token.

-spec fault(offset(), syntax | incomplete, binary()) -> no_return().
fault(At, Kind, Message) ->
    throw({?MODULE, At, {Kind, Message}}).

skip_blanks(L) ->
    case peek(L) of
        C when C =:= $\s; C =:= $\t -> skip_blanks(advance(L));
        $# -> skip_blanks(skip_comment(L));
        _ -> L
    end.

%% A comment is raw bytes up to its newline: a backslash there continues
%% nothing. The source ends with a newline, so there is one.
skip_comment(#lx{bin = B, at = At} = L) ->
    {Newline, 1} = binary:match(B, <<"\n">>, [{scope, {At, byte_size(B) - At}}]),
    move(L, Newline).

%% rc's wordchr and idchr.
word_char(eof) -> false;
word_char(C) -> not lists:member(C, "\n \t#;&|^$=`'{}()<>").

id_char(eof) -> false;
id_char(C) when C > $\s -> not lists:member(C, "!\"#$%&'()+,-./:;<=>?@[\\]^`{|}~");
id_char(_) -> false.

%% The next byte as rc reads it outside quotes and comments, where a
%% backslash-newline is a space, and the reader past it.
peek(#lx{bin = B, at = At}) ->
    case B of
        <<_:At/binary, $\\, $\n, _/binary>> -> $\s;
        <<_:At/binary, C, _/binary>> -> C;
        _ -> eof
    end.

advance(#lx{bin = B, at = At} = L) ->
    case B of
        <<_:At/binary, $\\, $\n, _/binary>> -> L#lx{at = At + 2, continued = true};
        _ -> L#lx{at = At + 1, continued = false}
    end.

%% The reader moved to offset To over raw bytes.
move(L, To) -> L#lx{at = To, continued = false}.

plain(L) -> L#lx{word = false, dollar = false}.
