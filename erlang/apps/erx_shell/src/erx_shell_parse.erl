%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_parse).
-moduledoc """
The command shell's parser: rc's grammar over erx_shell_lex's tokens, as a
pure function from the source read so far to its next unit and the unit's
syntax tree (docs/design-shell.md, "The language").

A source is parsed one unit at a time, as rc does. The unit is rc's line:
the commands up to a newline outside every construct, with the lines a
construct or a trailing `|`, `&&` or `||` carries it over and the bodies
of its here documents. `next/2` returns that unit's commands and the
source after it, so a caller runs them and passes the rest back, whether
the source is a script, a `-c` string or the lines a terminal has
delivered; a script stops at a unit that does not parse, after the units
before it have run, and an interactive loop resumes after it. A unit
holds at most max_command_bytes() of source, and next/2 parses no more of
the source than that, so the heap a parse needs is bounded by the unit
and not by the source, which has no bound. The evaluator parses through
`next_bounded/2`, which runs next/2 in a child process with a fixed heap,
so that bound holds whatever the evaluator's own heap holds.
`format_error/1` renders a diagnostic as the line the shell prints. The
tree is what the evaluator walks, so its shape is the types below. It
follows plan9port's rc (its syntax.y, and its parse.c for `=`) in what
binds to what:
* `&&` and `||` bind loosest, left to right, and are one flat `and_or`;
  `|` binds tighter and is one flat `pipeline`. A newline may follow any
  of the three.
* `!`, `@`, a redirection written before a command and an assignment
  written before one take everything up to the next `&&`, `||` or
  separator, a pipeline included: `! a | b` negates the pipeline and
  `x=1 a | b` gives the whole pipeline its `x`.
* The body of `if`, `if not`, `for` and `while` is everything up to the
  next separator, `&&` and `||` included, and may begin on the next line.
* Within a word, `$`, `$#` and `$"` bind tighter than `^`, so `$a^b`
  joins `$a` and `b`, and a subscript belongs to the `$` it follows.
* A keyword starts a command only in a command's first place; elsewhere it
  is a word, so `echo if` prints `if`. `in` and `not` cannot start one.
* `case` written unquoted as the first word of a command directly in a
  `switch` body starts an arm, and the body must begin with one; `case=x`
  and `case =x` are assignments, as rc runs them.
* `=` makes an assignment where it touches a simple command's first part,
  or follows its whole first word after a blank; anywhere else it is a
  part of the word it touches, so `echo a=b` prints `a=b`, as in rc.

A diagnostic names the line and column of the first fault, the
tokenizer's or the parser's, in fixed words, counted from the start of the
source next/2 was given. It is `incomplete` when only more lines could
cure it, `too_long` when the unit would exceed max_command_bytes() and
`too_deep` when constructs nest more than 256 levels. Each of `{...}`,
`if`, `if not`, `for`, `while`, `switch`, `fn`, `!`, `@`, a redirection
or an assignment written before a command, `(...)`, `$`, `$#`, `$"`,
`` `{...} ``, `<{...}` and `>{...}` is a level for what it holds; a
redirection's or an assignment's own words, and the redirections after a
`{...}`, stay at the level the construct is at. The rest, sequences,
`and_or`, `pipeline`, `~`, simple commands and `^`, are flat lists, so the
tree's depth is bounded by those levels and so is this parser's recursion.
""".

-export([next/2, next_bounded/2, max_command_bytes/0, parse_heap_bytes/0,
         format_error/1]).

-export_type([result/0, program/0, cmd/0, word/0, redir/0, pipe/0,
              diagnostic/0, pos/0]).

%% The bound on nesting (docs/design-shell.md, "Bounds").
-define(MAX_DEPTH, 256).

%% The heap of the process next_bounded/2 parses a unit in, and the bound
%% on a unit derived from it (docs/design-shell.md, "Bounds"): the worst
%% parse of a unit at the bound must fit in half that heap. The worst
%% erx_shell_parse_tests's sweep finds, nine shapes behind about a hundred
%% prefixes at 4,096 bytes, takes 3,187,517 bytes of `max_heap_size` with
%% `include_shared_binaries` on the stock emulator, 778 bytes per byte of
%% source; since the heap grows in garbage-collection steps rather than
%% byte by byte, PARSE_HEAP_PER_BYTE rounds that up to 1,024. The sweep
%% checks the result, parsing each of its sources within half the heap, so
%% a change to PARSE_HEAP moves the bound with it and the sweep says
%% whether the derivation still holds.
-define(PARSE_HEAP, (8 * 1024 * 1024)).
-define(PARSE_HEAP_PER_BYTE, 1024).
-define(MAX_COMMAND, (?PARSE_HEAP div 2 div ?PARSE_HEAP_PER_BYTE)).

%% What next/2 makes of the source read so far.
-type result() :: {ok, program(), Rest :: binary()}
                | eof
                | {incomplete, pos(), Message :: binary()}
                | {error, diagnostic(), Rest :: binary()}.
-type program() :: [cmd()].
-type cmd() ::
        {simple, [word(), ...], [redir()]}
      | {block, [cmd()], [redir()]}
      | {background, cmd()}
      | {pipeline, cmd(), [{pipe(), cmd()}, ...]}
      | {and_or, cmd(), [{'and' | 'or', cmd()}, ...]}
      | {'not' | subshell | if_not, body()}
      | {redirect, redir(), body()}
      | {assign, Name :: word(), Value :: word()}
      | {local, Name :: word(), Value :: word(), cmd()}
      | {'if' | while, Condition :: [cmd()], body()}
      | {for, Var :: word(), {in, [word()]} | args, body()}
      | {switch, Subject :: word(), [{'case', Patterns :: [word()], [cmd()]}]}
      | {match, Subject :: word(), Patterns :: [word()]}
      | {fn, Names :: [word()], [cmd()]}
      | {fn_delete, Names :: [word()]}.
%% What a prefix or a compound runs when nothing follows it.
-type body() :: cmd() | empty.
-type word() ::
        {word | quoted, binary()}
      | {concat, [word(), ...]}
      | {var | count | flat, Name :: word()}
      | {var_sub, Name :: word(), Index :: [word()]}
      | {list, [word()]}
      | {backquote, ifs | Split :: word(), [cmd()]}
      | {pipefd, read | write, [cmd()]}.
-type redir() ::
        {write | append | read | rdwr, erx_shell_lex:fd(), word()}
      | {here, erx_shell_lex:fd(), erx_shell_lex:doc()}
      | {dup, To :: erx_shell_lex:fd(), From :: erx_shell_lex:fd()}
      | {close, erx_shell_lex:fd()}.
-type pipe() :: {Left :: erx_shell_lex:fd(), Right :: erx_shell_lex:fd()}.
%% Why a source does not parse; a position is a line and a column.
-type diagnostic() :: {syntax | incomplete, pos(), Message :: binary()}
                    | {too_long, Limit :: pos_integer()}
                    | {too_deep, pos()}.
-type pos() :: {Line :: pos_integer(), Column :: pos_integer()}.
-type tokens() :: [erx_shell_lex:token()].
-type depth() :: 0..?MAX_DEPTH.

-doc "The most bytes of source one unit may hold.".
-spec max_command_bytes() -> pos_integer().
max_command_bytes() -> ?MAX_COMMAND.

-doc "The heap, in bytes, of the process next_bounded/2 parses a unit in.".
-spec parse_heap_bytes() -> pos_integer().
parse_heap_bytes() -> ?PARSE_HEAP.

-doc """
The next unit of `Buffer`, the source read so far. `End` says whether
more source may follow: with `more` the last line of `Buffer` may be
unfinished and is never read, so a unit that reaches it is `incomplete`;
with `final` `Buffer` is all there is, and its last line needs no
newline of its own.

* `{ok, Program, Rest}`: the unit at the start of `Buffer` parses to
  `Program`, the commands of its line in order, none for a line with
  nothing to run, and `Rest` is the source after it.
* `eof`: `Buffer` is empty.
* `{incomplete, Pos, Message}`: only more lines could complete the unit;
  with `final` it is the diagnostic to print.
* `{error, Diagnostic, Rest}`: the unit does not parse, or would exceed
  max_command_bytes() (`{too_long, Limit}`). After a syntax error or
  `too_deep`, `Rest` is the source after the line the fault was found on,
  as rc skips to the end of that line; after `too_long`, where the unit
  ends is unknown, so `Rest` is empty and nothing of it is resumed. A
  script stops at either.

Only the first max_command_bytes() of `Buffer` are parsed, and a unit
that fits them is parsed the same whatever follows it.
""".
-spec next(binary(), more | final) -> result().
next(<<>>, End) when End =:= more; End =:= final ->
    eof;
next(Buffer, End) when is_binary(Buffer), (End =:= more orelse End =:= final) ->
    rest(Buffer, unit_of(window(Buffer, End))).

-doc """
next/2 run in a child process whose heap is fixed at parse_heap_bytes(),
the one call the evaluator parses through: the heap a parse may take is
then bounded by the unit alone, whatever the evaluator holds. The child
is handed a copy of the part of `Buffer` that next/2 reads, so the rest
of the source does not count against its heap, and returns its result as
its exit reason, so it has ended when the result arrives. A child the
heap limit kills gives `too_long`, never a crash of the caller; one whose
parse raises, which the fuzz target shows does not happen, ends with a
fixed reason, so nothing of the source reaches a log.
""".
-spec next_bounded(binary(), more | final) -> result().
next_bounded(<<>>, End) when End =:= more; End =:= final ->
    eof;
next_bounded(Buffer, End) when is_binary(Buffer), (End =:= more orelse End =:= final) ->
    {Window, Reach} = window(Buffer, End),
    Copy = binary:copy(Window),
    Heap = #{size => ?PARSE_HEAP div erlang:system_info(wordsize), kill => true,
             error_logger => false, include_shared_binaries => true},
    Parse = fun() ->
                    exit({?MODULE, try unit_of({Copy, Reach}) catch _:_ -> crashed end})
            end,
    {Pid, Ref} = spawn_opt(Parse, [monitor, {max_heap_size, Heap}]),
    receive
        {'DOWN', Ref, process, Pid, {?MODULE, crashed}} -> error({?MODULE, parse_crashed});
        {'DOWN', Ref, process, Pid, {?MODULE, Unit}} -> rest(Buffer, Unit);
        {'DOWN', Ref, process, Pid, killed} -> rest(Buffer, too_long);
        {'DOWN', Ref, process, Pid, _Other} -> error({?MODULE, parse_crashed})
    end.

%% The part of Buffer a unit within the bound lies in, and how far the unit
%% may reach. A buffer that fits the bound, counting the newline its end is
%% read as having, is read whole with `final` and to its last newline with
%% `more`, and a unit that needs more lines than those is incomplete; one
%% that does not fit is cut to the whole lines among its first ?MAX_COMMAND
%% bytes, since every unit ends with a line, and a unit that needs more
%% lines than those is too long. Nothing past the part is read.
window(Buffer, final) ->
    case fits(Buffer) of
        true -> {Buffer, whole};
        false -> cut(Buffer)
    end;
window(Buffer, more) ->
    case fits(Buffer) of
        true -> {binary_part(Buffer, 0, lines_end(Buffer, byte_size(Buffer))), whole};
        false -> cut(Buffer)
    end.

fits(Buffer) when byte_size(Buffer) < ?MAX_COMMAND -> true;
fits(Buffer) when byte_size(Buffer) =:= ?MAX_COMMAND -> binary:last(Buffer) =:= $\n;
fits(Buffer) when is_binary(Buffer) -> false.

cut(Buffer) ->
    {binary_part(Buffer, 0, lines_end(Buffer, ?MAX_COMMAND)), cut}.

%% The offset just past the last newline before End, or 0 if there is none.
lines_end(_Buffer, 0) ->
    0;
lines_end(Buffer, End) ->
    case binary:at(Buffer, End - 1) of
        $\n -> End;
        _ -> lines_end(Buffer, End - 1)
    end.

%% What the parse of a window makes of its unit, before rest/2 turns its
%% offsets into the source that follows: the commands and the bytes they
%% take, an incomplete unit, a fault and the offset it was found at, or a
%% unit too long to parse. Its positions hold for the buffer Window starts.
-type unit() :: {parsed, program(), Used :: non_neg_integer()}
              | {incomplete, pos(), Message :: binary()}
              | {fault, diagnostic(), At :: erx_shell_lex:offset()}
              | too_long.

-spec unit_of({binary(), whole | cut}) -> unit().
unit_of({Window, Reach}) ->
    try unit(erx_shell_lex:text(Window), 1) of
        {Program, End} ->
            %% End may be past the newline text/1 added to a last line.
            {parsed, Program, min(End, byte_size(Window))}
    catch
        throw:{?MODULE, _, {incomplete, _}} when Reach =:= cut ->
            too_long;
        throw:{?MODULE, At, {incomplete, Message}} ->
            {incomplete, erx_shell_lex:position(Window, At), Message};
        throw:{?MODULE, At, {syntax, Message}} ->
            {fault, {syntax, erx_shell_lex:position(Window, At), Message}, At};
        throw:{?MODULE, At, too_deep} ->
            {fault, {too_deep, erx_shell_lex:position(Window, At)}, At}
    end.

-spec rest(binary(), unit()) -> result().
rest(Buffer, {parsed, Program, Used}) ->
    {ok, Program, binary_part(Buffer, Used, byte_size(Buffer) - Used)};
rest(_Buffer, {incomplete, _, _} = Incomplete) ->
    Incomplete;
rest(Buffer, {fault, Diagnostic, At}) ->
    {error, Diagnostic, after_line(Buffer, At)};
rest(_Buffer, too_long) ->
    {error, {too_long, ?MAX_COMMAND}, <<>>}.

%% The source after the first newline at or after At, or none. At lies in
%% the window, which ends with a newline unless it ends the input.
after_line(Buffer, At) when At >= byte_size(Buffer) ->
    <<>>;
after_line(Buffer, At) ->
    case binary:match(Buffer, <<"\n">>, [{scope, {At, byte_size(Buffer) - At}}]) of
        {Newline, 1} -> binary_part(Buffer, Newline + 1, byte_size(Buffer) - Newline - 1);
        nomatch -> <<>>
    end.

%% The commands of the unit at the start of Text, from text/1, and the
%% offset after it. The first Lines lines are read and parsed; when they
%% end inside the unit and the text goes on, the parse is `incomplete` at
%% the `eof` after them, and twice as many are read and parsed again, so a
%% unit of N lines takes about log2 N parses and its tokens are read past
%% its end by fewer lines than it holds.
-spec unit(binary(), pos_integer()) -> {program(), erx_shell_lex:offset()}.
unit(Text, Lines) ->
    case erx_shell_lex:lines(Text, Lines) of
        {more, Tokens} ->
            try
                line(Tokens)
            catch
                throw:{?MODULE, _, {incomplete, _}} -> unit(Text, 2 * Lines)
            end;
        {last, Tokens} ->
            line(Tokens)
    end.

-doc """
The line the shell prints for a diagnostic. It holds only numbers and the
diagnostic's fixed words, so it needs no escaping.
""".
-spec format_error(diagnostic()) -> binary().
format_error({too_long, Limit}) ->
    iolist_to_binary(io_lib:format("syntax error: line too long, over ~b bytes", [Limit]));
format_error({too_deep, Pos}) ->
    at(Pos, iolist_to_binary(io_lib:format("nested deeper than ~b", [?MAX_DEPTH])));
format_error({_, Pos, Message}) ->
    at(Pos, Message).

at({Line, Column}, Message) ->
    iolist_to_binary(io_lib:format("syntax error at line ~b, column ~b: ~ts",
                                   [Line, Column, Message])).

%% One of rc's lines, commands separated by `;` and `&` up to the newline
%% that ends it, and the offset where the next line starts.
-spec line(tokens()) -> {program(), erx_shell_lex:offset()}.
line(Tokens) ->
    case sequence(Tokens, 0, line) of
        {Cmds, [{newline, _, Next} | _]} -> {Cmds, Next};
        {_, [Token | _]} -> unexpected(Token)
    end.

%% Commands separated by `;`, `&` and newlines, up to a token that cannot
%% start one, which the caller checks. In a switch arm a `case` ends it too;
%% in a line, which is rc's unit of parsing, a newline ends it.
sequence(Tokens, D, Mode) ->
    sequence(Tokens, D, Mode, []).

sequence([{newline, _, _} | _] = Tokens, _D, line, Acc) ->
    {lists:reverse(Acc), Tokens};
sequence([{Separator, _, _} | Tokens], D, Mode, Acc)
  when Separator =:= newline; Separator =:= ';'; Separator =:= '&' ->
    sequence(Tokens, D, Mode, Acc);
%% A `case` joined to what follows it, or assigned to, is a command.
sequence([{word, _, <<"case">>}, {Next, _, _} | _] = Tokens, _D, arm, Acc)
  when Next =/= caret, Next =/= '=' ->
    {lists:reverse(Acc), Tokens};
sequence(Tokens, D, Mode, Acc) ->
    case starts_command(Tokens) of
        false ->
            {lists:reverse(Acc), Tokens};
        true ->
            case command(Tokens, D) of
                {Cmd, [{'&', _, _} | Rest]} ->
                    sequence(Rest, D, Mode, [{background, Cmd} | Acc]);
                {Cmd, [{newline, _, _} | _] = Rest} when Mode =:= line ->
                    {lists:reverse(Acc, [Cmd]), Rest};
                {Cmd, [{Separator, _, _} | Rest]}
                  when Separator =:= newline; Separator =:= ';' ->
                    sequence(Rest, D, Mode, [Cmd | Acc]);
                {Cmd, Rest} ->
                    {lists:reverse(Acc, [Cmd]), Rest}
            end
    end.

%% cmd && cmd || cmd ...
command(Tokens, D) ->
    {First, Rest} = pipeline(Tokens, D),
    and_or(Rest, D, First, []).

and_or([{Op, _, _} | Tokens], D, First, Acc) when Op =:= andand; Op =:= oror ->
    {Next, Rest} = pipeline(operand(skip_newlines(Tokens)), D),
    Logic = case Op of
                andand -> 'and';
                oror -> 'or'
            end,
    and_or(Rest, D, First, [{Logic, Next} | Acc]);
and_or(Tokens, _D, First, []) ->
    {First, Tokens};
and_or(Tokens, _D, First, Acc) ->
    {{and_or, First, lists:reverse(Acc)}, Tokens}.

%% cmd | cmd |[2] cmd ...
pipeline(Tokens, D) ->
    {First, Rest} = unary(Tokens, D),
    stages(Rest, D, First, []).

stages([{pipe, _, Fds} | Tokens], D, First, Acc) ->
    {Next, Rest} = unary(operand(skip_newlines(Tokens)), D),
    stages(Rest, D, First, [{Fds, Next} | Acc]);
stages(Tokens, _D, First, []) ->
    {First, Tokens};
stages(Tokens, _D, First, Acc) ->
    {{pipeline, First, lists:reverse(Acc)}, Tokens}.

operand([Token | _] = Tokens) ->
    case starts_command(Tokens) of
        true -> Tokens;
        false -> fail(Token, <<"a command must follow">>)
    end.

%% One command of a pipeline: a prefix and what it applies to, a compound,
%% or a simple command or assignment.
unary([{keyword, At, '!'} | Tokens], D) ->
    {Body, Rest} = prefixed(Tokens, enter(D, At)),
    {{'not', Body}, Rest};
unary([{keyword, At, '@'} | Tokens], D) ->
    {Body, Rest} = prefixed(Tokens, enter(D, At)),
    {{subshell, Body}, Rest};
unary([{keyword, At, 'if'} | Tokens], D) ->
    if_command(Tokens, enter(D, At));
unary([{keyword, At, for} | Tokens], D) ->
    for_command(Tokens, enter(D, At));
unary([{keyword, At, while} | Tokens], D) ->
    D1 = enter(D, At),
    {Condition, Rest} = condition(Tokens, D1),
    {Body, Rest1} = compound_body(Rest, D1),
    {{while, Condition, Body}, Rest1};
unary([{keyword, At, switch} | Tokens], D) ->
    D1 = enter(D, At),
    {Subject, Rest} = word(Tokens, D1),
    {Arms, Rest1} = arms(expect('{', skip_newlines(Rest)), D1, []),
    {{switch, Subject, Arms}, expect('}', Rest1)};
unary([{keyword, At, fn} | Tokens], D) ->
    D1 = enter(D, At),
    case words(Tokens, D1) of
        {Names, [{'{', _, _} | Rest]} ->
            {Body, Rest1} = braced(Rest, D1),
            {{fn, Names, Body}, Rest1};
        {Names, Rest} ->
            {{fn_delete, Names}, Rest}
    end;
unary([{keyword, _, '~'} | Tokens], D) ->
    {Subject, Rest} = word(Tokens, D),
    {Patterns, Rest1} = words(Rest, D),
    {{match, Subject, Patterns}, Rest1};
unary([{keyword, _, _} = Token | _], _D) ->
    unexpected(Token);
unary([{'{', At, _} | Tokens], D) ->
    {Cmds, Rest} = braced(Tokens, enter(D, At)),
    {Redirs, Rest1} = redirections(Rest, D, []),
    {{block, Cmds, Redirs}, Rest1};
unary([{_, At, _} | _] = Tokens, D) ->
    case is_redirection(Tokens) of
        true ->
            {Redir, Rest} = redirection(Tokens, D),
            {Body, Rest1} = prefixed(Rest, enter(D, At)),
            {{redirect, Redir, Body}, Rest1};
        false ->
            simple(Tokens, D)
    end.

%% What `!`, `@` and a prefix apply to: the pipeline that follows, if any.
prefixed(Tokens, D) ->
    case starts_command(Tokens) of
        true -> pipeline(Tokens, D);
        false -> {empty, Tokens}
    end.

%% What `if`, `for` and `while` run: the command that follows, on this line
%% or the next. At the end of the source more input could still supply it.
compound_body(Tokens, D) ->
    case skip_newlines(Tokens) of
        [{eof, _, _} = Token] ->
            fail(Token, <<"a command must follow">>);
        Rest ->
            case starts_command(Rest) of
                true -> command(Rest, D);
                false -> {empty, Rest}
            end
    end.

if_command([{keyword, _, 'not'} | Tokens], D) ->
    {Body, Rest} = compound_body(Tokens, D),
    {{if_not, Body}, Rest};
if_command(Tokens, D) ->
    {Condition, Rest} = condition(Tokens, D),
    {Body, Rest1} = compound_body(Rest, D),
    {{'if', Condition, Body}, Rest1}.

for_command(Tokens, D) ->
    {Var, Rest} = word(expect('(', Tokens), D),
    case Rest of
        [{keyword, _, in} | Rest1] ->
            {List, Rest2} = words(Rest1, D),
            {Body, Rest3} = compound_body(expect(')', Rest2), D),
            {{for, Var, {in, List}, Body}, Rest3};
        _ ->
            {Body, Rest1} = compound_body(expect(')', Rest), D),
            {{for, Var, args, Body}, Rest1}
    end.

%% `(cmds)`, the condition of `if` and `while`.
condition(Tokens, D) ->
    {Cmds, Rest} = sequence(expect('(', Tokens), D, plain),
    {Cmds, expect(')', Rest)}.

%% The commands of a `{` already read, and what follows its `}`.
braced(Tokens, D) ->
    {Cmds, Rest} = sequence(Tokens, D, plain),
    {Cmds, expect('}', Rest)}.

%% A switch body: arms, each a `case` line and the commands up to the next.
arms(Tokens, D, Acc) ->
    case skip_separators(Tokens) of
        %% `case` joined to what follows it, or assigned to, is a command.
        [{word, _, <<"case">>}, {Next, _, _} = Following | Rest]
          when Next =/= caret, Next =/= '=' ->
            {Patterns, Rest1} = words([Following | Rest], D),
            {Cmds, Rest2} = sequence(case_end(Rest1), D, arm),
            arms(Rest2, D, [{'case', Patterns, Cmds} | Acc]);
        [{'}', _, _} | _] = Rest ->
            {lists:reverse(Acc), Rest};
        [Token | _] when Acc =:= [] ->
            fail(Token, <<"a switch body must begin with case">>);
        [Token | _] ->
            unexpected(Token)
    end.

case_end([{Separator, _, _} | Rest]) when Separator =:= newline; Separator =:= ';' ->
    Rest;
case_end([{'}', _, _} | _] = Rest) ->
    Rest;
case_end([Token | _]) ->
    fail(Token, <<"a case takes only words">>).

%% A command that starts with a word: an assignment if `=` touches its
%% first part, or follows the whole word after a blank, as in rc's
%% parse.c; anywhere else `=` is a part of the word it touches. A caret the
%% lexer inserted stands where the `=` does, while a written `^` comes
%% before it, so `a^=b` is one word, as in rc.
simple(Tokens, D) ->
    {First, Rest} = part(Tokens, D),
    case Rest of
        [{caret, At, _}, {'=', At, _} | Rest1] ->
            assignment(First, At, Rest1, D);
        _ ->
            case concat(Rest, D, [First]) of
                {Name, [{'=', At, _} | Rest1]} -> assignment(Name, At, Rest1, D);
                {Word, Rest1} -> arguments(Rest1, D, [Word], [])
            end
    end.

%% `name=value`, alone or before the pipeline it applies to. The lexer
%% joins what touches `=` to it, as it joins what touches a word, but a
%% value starts afresh: its caret is dropped and a `(` the lexer read as a
%% subscript opens a list.
assignment(Name, At, Tokens, D) ->
    {Value, Rest} = word(unjoined(Tokens), D),
    case starts_command(Rest) of
        true ->
            {Body, Rest1} = pipeline(Rest, enter(D, At)),
            {{local, Name, Value, Body}, Rest1};
        false ->
            {{assign, Name, Value}, Rest}
    end.

%% The tokens of an assignment's value with the lexer's joining to `=`
%% undone: an inserted caret, which stands where the next token does, is
%% dropped (a written `^` stays, and is refused, as in rc), and a `sub` is
%% the `(` of a list.
unjoined([{caret, At, _}, {_, At, _} = Next | Tokens]) -> [Next | Tokens];
unjoined([{sub, At, _} | Tokens]) -> [{'(', At, none} | Tokens];
unjoined(Tokens) -> Tokens.

arguments(Tokens, D, Words, Redirs) ->
    case starts_word(Tokens) of
        true ->
            {Word, Rest} = word(Tokens, D),
            arguments(Rest, D, [Word | Words], Redirs);
        false ->
            case is_redirection(Tokens) of
                true ->
                    {Redir, Rest} = redirection(Tokens, D),
                    arguments(Rest, D, Words, [Redir | Redirs]);
                false ->
                    {{simple, lists:reverse(Words), lists:reverse(Redirs)}, Tokens}
            end
    end.

redirections(Tokens, D, Acc) ->
    case is_redirection(Tokens) of
        true ->
            {Redir, Rest} = redirection(Tokens, D),
            redirections(Rest, D, [Redir | Acc]);
        false ->
            {lists:reverse(Acc), Tokens}
    end.

redirection([{redir, _, {Kind, Fd}} | Tokens], D) ->
    {Target, Rest} = word(Tokens, D),
    {{Kind, Fd, Target}, Rest};
redirection([{heredoc, _, {Fd, Doc}} | Tokens], _D) ->
    {{here, Fd, Doc}, Tokens};
redirection([{dup, _, {To, From}} | Tokens], _D) ->
    {{dup, To, From}, Tokens};
redirection([{close, _, Fd} | Tokens], _D) ->
    {{close, Fd}, Tokens}.

%% Words up to the first token that cannot start one.
words(Tokens, D) ->
    words(Tokens, D, []).

words(Tokens, D, Acc) ->
    case starts_word(Tokens) of
        true ->
            {Word, Rest} = word(Tokens, D),
            words(Rest, D, [Word | Acc]);
        false ->
            {lists:reverse(Acc), Tokens}
    end.

%% A word: parts joined by `^`, written or inserted.
word([Token | _] = Tokens, D) ->
    case starts_word(Tokens) of
        true ->
            {First, Rest} = part(Tokens, D),
            concat(Rest, D, [First]);
        false ->
            fail(Token, <<"a word must follow">>)
    end.

concat([{caret, _, _} | [Token | _] = Tokens], D, Acc) ->
    case starts_word(Tokens) of
        true ->
            {Part, Rest} = part(Tokens, D),
            concat(Rest, D, [Part | Acc]);
        false ->
            fail(Token, <<"a word must follow '^'">>)
    end;
concat(Tokens, _D, [Single]) ->
    {Single, Tokens};
concat(Tokens, _D, Acc) ->
    {{concat, lists:reverse(Acc)}, Tokens}.

%% One part of a word; called only where starts_word/1 holds.
part([{word, _, Text} | Tokens], _D) ->
    {{word, Text}, Tokens};
part([{quoted, _, Text} | Tokens], _D) ->
    {{quoted, Text}, Tokens};
part([{keyword, _, Keyword} | Tokens], _D) ->
    {{word, atom_to_binary(Keyword)}, Tokens};
part([{'=', _, _} | Tokens], _D) ->
    {{word, <<"=">>}, Tokens};
part([{dollar, At, _} | Tokens], D) ->
    D1 = enter(D, At),
    case name(Tokens, D1) of
        {Name, [{sub, _, _} | Rest]} ->
            {Index, Rest1} = words(Rest, D1),
            {{var_sub, Name, Index}, expect(')', Rest1)};
        {Name, Rest} ->
            {{var, Name}, Rest}
    end;
part([{Kind, At, _} | Tokens], D) when Kind =:= count; Kind =:= flat ->
    {Name, Rest} = name(Tokens, enter(D, At)),
    {{Kind, Name}, Rest};
part([{backquote, At, _} | Tokens], D) ->
    D1 = enter(D, At),
    case Tokens of
        [{'{', _, _} | Rest] ->
            {Body, Rest1} = braced(Rest, D1),
            {{backquote, ifs, Body}, Rest1};
        _ ->
            {Split, Rest} = word(Tokens, D1),
            {Body, Rest1} = braced(expect('{', Rest), D1),
            {{backquote, Split, Body}, Rest1}
    end;
part([{'(', At, _} | Tokens], D) ->
    {Words, Rest} = words(Tokens, enter(D, At)),
    {{list, Words}, expect(')', Rest)};
part([{pipefd, At, Direction} | Tokens], D) ->
    D1 = enter(D, At),
    {Body, Rest} = braced(expect('{', Tokens), D1),
    {{pipefd, Direction, Body}, Rest}.

%% What `$`, `$#` and `$"` name: one part, never a joined word.
name([Token | _] = Tokens, D) ->
    case starts_word(Tokens) of
        true -> part(Tokens, D);
        false -> fail(Token, <<"a variable name must follow '$'">>)
    end.

starts_word([{Kind, _, _} | _]) ->
    lists:member(Kind, [word, quoted, keyword, '=', dollar, count, flat, backquote,
                        '(', pipefd]).

starts_command([{keyword, _, Keyword} | _]) ->
    Keyword =/= in andalso Keyword =/= 'not';
starts_command([{'{', _, _} | _]) ->
    true;
starts_command(Tokens) ->
    starts_word(Tokens) orelse is_redirection(Tokens).

is_redirection([{Kind, _, _} | _]) ->
    lists:member(Kind, [redir, heredoc, dup, close]).

skip_newlines([{newline, _, _} | Tokens]) -> skip_newlines(Tokens);
skip_newlines(Tokens) -> Tokens.

skip_separators([{Separator, _, _} | Tokens]) when Separator =:= newline; Separator =:= ';' ->
    skip_separators(Tokens);
skip_separators(Tokens) ->
    Tokens.

expect(Kind, [{Kind, _, _} | Tokens]) ->
    Tokens;
expect(Kind, [Token | _]) ->
    fail(Token, <<"expected '", (atom_to_binary(Kind))/binary, "'">>).

%% The level a construct at depth D holds its contents at.
-spec enter(depth(), erx_shell_lex:offset()) -> depth().
enter(D, At) when D >= ?MAX_DEPTH ->
    throw({?MODULE, At, too_deep});
enter(D, _Pos) ->
    D + 1.

unexpected(Token) ->
    fail(Token, <<"unexpected ", (describe(Token))/binary>>).

%% A fault at an error token is the tokenizer's, which comes first; one at
%% the end could be cured by more lines, since the source ends with a
%% newline and only constructs that span lines reach the end.
-spec fail(erx_shell_lex:token(), binary()) -> no_return().
fail({error, At, Fault}, _Message) ->
    throw({?MODULE, At, Fault});
fail({eof, At, _}, Message) ->
    throw({?MODULE, At, {incomplete, Message}});
fail({_, At, _}, Message) ->
    throw({?MODULE, At, {syntax, Message}}).

%% A token named in fixed words: a word's text is never shown.
describe({word, _, _}) -> <<"word">>;
describe({quoted, _, _}) -> <<"quoted word">>;
describe({keyword, _, Keyword}) -> <<"'", (atom_to_binary(Keyword))/binary, "'">>;
describe({eof, _, _}) -> <<"end of input">>;
describe({newline, _, _}) -> <<"newline">>;
describe({Kind, _, _}) when Kind =:= redir; Kind =:= heredoc; Kind =:= dup; Kind =:= close ->
    <<"redirection">>;
describe({pipefd, _, read}) -> <<"'<{'">>;
describe({pipefd, _, write}) -> <<"'>{'">>;
describe({Kind, _, _}) ->
    Text = case Kind of
               caret -> <<"^">>;
               sub -> <<"(">>;
               dollar -> <<"$">>;
               count -> <<"$#">>;
               flat -> <<"$\"">>;
               backquote -> <<"`">>;
               andand -> <<"&&">>;
               oror -> <<"||">>;
               pipe -> <<"|">>;
               Punctuation -> atom_to_binary(Punctuation)
           end,
    <<"'", Text/binary, "'">>.
