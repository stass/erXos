%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_shell_parse and erx_shell_lex (docs/design-shell.md,
%% "Verification and testing"). Inputs come from four sources: soups of rc's
%% token fragments and random bytes; mutations of valid scripts; nestings of
%% every construct that counts as a level, mixed at random and each on its own,
%% at a chosen number of levels near 256; and sources at and just over 64 KiB,
%% among them 64 KiB runs of one fragment. Every input must parse or fail with a
%% diagnostic, never raise. A diagnostic must name a line and column inside the
%% source and say what is wrong in printable ASCII. A tree must have every node
%% in the shape the parser's types give, must hold at most 256 levels, counted
%% here by a walker of its own, and, printed back to rc's syntax by a printer
%% of its own, must parse to itself. A nesting of N levels must parse to a tree
%% of exactly N levels when N is at most 256 and fail with too_deep when it is
%% more; a source of 65,536 bytes is read and one of 65,537 is too_long. The
%% seed comes from make check-fuzz.

-module(erx_shell_parse_fuzz).
-export([run/1]).

-define(SOUPS, 150000).
-define(MUTATIONS, 150000).
-define(MIXED, 3000).
-define(MAX_LEVELS, 256).
-define(MAX_BYTES, 65536).
-define(IS_FD(F), (is_integer(F) andalso F >= 0 andalso F =< 16#7fffffff)).

-define(FRAGMENTS,
        [<<"a">>, <<"b">>, <<"x">>, <<"*">>, <<" ">>, <<" ">>, <<"\t">>, <<"\n">>,
         <<"'">>, <<"''">>, <<"'q'">>, <<"$">>, <<"$#">>, <<"$\"">>, <<"$x">>, <<"^">>,
         <<"(">>, <<")">>, <<"{">>, <<"}">>, <<"|">>, <<"|[2]">>, <<"|[2=3]">>,
         <<"|[">>, <<"&&">>, <<"||">>, <<"&">>, <<";">>, <<">">>, <<">>">>, <<"<">>,
         <<"<>">>, <<">[2=1]">>, <<">[2=]">>, <<">[1">>, <<"<<">>, <<"<<E\n">>,
         <<"<<'E'\n">>, <<"\nE\n">>, <<"E">>, <<"<{">>, <<">{">>, <<"`">>, <<"`{">>,
         <<"=">>, <<"if">>, <<"if not">>, <<"not">>, <<"for">>, <<"in">>, <<"while">>,
         <<"switch">>, <<"case">>, <<"fn">>, <<"~">>, <<"!">>, <<"@">>, <<"#c">>,
         <<"\\\n">>, <<"\\">>, <<"[">>, <<"]">>, <<"0">>, <<"9">>, <<"\e[2J">>,
         <<16#c3, 16#a9>>, <<16#ff>>, <<0>>]).

-define(CORPUS,
        [<<"echo a 'b''c' $x $#x $\"x $x(1 2) $$y">>,
         <<"cc -$flags $stem.c 'a'b`{c} >out >>[2]err <in <>dev">>,
         <<"x=(a b c) y=() a | b |[2] c |[3=4] d && e || ! f">>,
         <<"if(~ $x a*) echo y\nif not echo n">>,
         <<"for(i in 1 2 3) { echo $i } >[2=1]">>,
         <<"for(i) echo $i; while(test -f x) sleep 1 &">>,
         <<"switch($x){\ncase a b\n echo 1\ncase *\n echo 2\n}">>,
         <<"fn f g { echo `':'{ls} <{cat} >{tee} $*(1) }\nfn f">>,
         <<"cat <<EOF >[2=1]\nhi $x^y $$ $\nEOF\ncat <<'Q'\n$z\nQ\n">>,
         <<"@ { a; b } | c\n# comment\nd \\\n e">>,
         <<">f x=1 ! @ a | b">>,
         <<"{if(t)}; {! }; >g; x=y | z">>]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Counts0 = #{ok => 0, error => 0},
    Counts1 = repeat(?SOUPS, fun soup/0, Counts0),
    Counts2 = repeat(?MUTATIONS, fun mutation/0, Counts1),
    Counts3 = repeat(?MIXED, fun() -> mixed(any) end, Counts2),
    Counts4 = lists:foldl(fun(Kind, Acc) -> repeat(4, fun() -> mixed(Kind) end, Acc) end,
                          Counts3, kinds()),
    Counts5 = lists:foldl(fun(Source, Acc) -> count(check(Source), Acc) end,
                          Counts4, bounds()),
    io:format("results: ~p~n", [Counts5]),
    case Counts5 of
        #{ok := Ok, error := Error} when Ok >= 2000, Error >= 2000 -> ok;
        _ -> error({one_sided, Counts5})
    end,
    io:format("fuzz: ~p inputs ok~n", [maps:get(ok, Counts5) + maps:get(error, Counts5)]).

repeat(0, _Generate, Counts) ->
    Counts;
repeat(N, Generate, Counts) ->
    repeat(N - 1, Generate, count(Generate(), Counts)).

count({Source, Expect}, Counts) ->
    count(check(Source, Expect), Counts);
count(Source, Counts) when is_binary(Source) ->
    count(check(Source), Counts);
count(Result, Counts) ->
    maps:update_with(Result, fun(N) -> N + 1 end, Counts).

%% Generators

soup() ->
    iolist_to_binary([fragment() || _ <- lists:seq(1, rand:uniform(40))]).

fragment() ->
    case rand:uniform(10) of
        1 -> <<(rand:uniform(256) - 1)>>;
        _ -> pick(?FRAGMENTS)
    end.

mutation() ->
    Source = pick(?CORPUS),
    lists:foldl(fun(_, S) -> mutate(S) end, Source, lists:seq(1, rand:uniform(3))).

mutate(<<>>) ->
    fragment();
mutate(Source) ->
    At = rand:uniform(byte_size(Source)) - 1,
    <<Before:At/binary, After/binary>> = Source,
    case rand:uniform(4) of
        1 -> <<Before/binary, (fragment())/binary, After/binary>>;
        2 -> <<Before/binary, (drop(After))/binary>>;
        3 -> <<Before/binary, (rand:uniform(256) - 1), (drop(After))/binary>>;
        4 -> <<Before/binary, Before/binary, After/binary>>
    end.

drop(<<>>) -> <<>>;
drop(Bytes) -> binary_part(Bytes, 1, byte_size(Bytes) - 1).

%% A nesting: openers, each one level, from the context each needs to the
%% context it leaves, with the text that closes it. A word context takes
%% words; a name context takes the one part that follows `$`.
openers() ->
    [{block, command, <<"{">>, <<"}">>, command},
     {'if', command, <<"if(x) ">>, <<>>, command},
     {if_not, command, <<"if not ">>, <<>>, command},
     {'not', command, <<"! ">>, <<>>, command},
     {subshell, command, <<"@ ">>, <<>>, command},
     {local, command, <<"x=y ">>, <<>>, command},
     {redirect, command, <<">f ">>, <<>>, command},
     {for, command, <<"for(i) ">>, <<>>, command},
     {while, command, <<"while(x) ">>, <<>>, command},
     {fn, command, <<"fn f {">>, <<"}">>, command},
     {switch, command, <<"switch x {case y; ">>, <<"}">>, command},
     {list, command, <<"echo (">>, <<")">>, word},
     {var, command, <<"echo $">>, <<>>, name},
     {backquote, command, <<"echo `{">>, <<"}">>, command},
     {pipefd, command, <<"echo <{">>, <<"}">>, command},
     {list, word, <<"(">>, <<")">>, word},
     {var, word, <<"$">>, <<>>, name},
     {count, word, <<"$#">>, <<>>, name},
     {flat, word, <<"$\"">>, <<>>, name},
     {backquote, word, <<"`{">>, <<"}">>, command},
     {pipefd, word, <<"<{">>, <<"}">>, command},
     {list, name, <<"(">>, <<")">>, word},
     {var, name, <<"$">>, <<>>, name},
     {backquote, name, <<"`{">>, <<"}">>, command},
{pipefd, name, <<">{">>, <<"}">>, command},
{condition, command, <<"if(">>, <<") x">>, command},
{for_in, command, <<"for(i in ">>, <<") x">>, word},
{fn_names, command, <<"fn ">>, <<" {x}">>, word},
{var_sub, word, <<"$x(">>, <<")">>, word}].

kinds() ->
    lists:usort([Kind || {Kind, _, _, _, _} <- openers()]).

%% A source of N levels, N near 256 and now and then small, built mostly of
%% the favoured kind when there is one, and what the parser must make of it.
mixed(Favoured) ->
    N = case rand:uniform(5) of
            1 -> rand:uniform(20);
            _ -> ?MAX_LEVELS - 3 + rand:uniform(5)
        end,
    {Open, Close} = nest(N, Favoured, command, [], []),
    Source = iolist_to_binary([lists:reverse(Open), <<"x">>, Close]),
    case N =< ?MAX_LEVELS of
        true -> {Source, {levels, N}};
        false -> {Source, too_deep}
    end.

nest(0, _Favoured, _Context, Open, Close) ->
    {Open, Close};
nest(N, Favoured, Context, Open, Close) ->
    Fitting = [O || {_, From, _, _, _} = O <- openers(), From =:= Context],
    Choice = case [O || {Kind, _, _, _, _} = O <- Fitting, Kind =:= Favoured] of
                 [_ | _] = Preferred when Favoured =/= any ->
                     case rand:uniform(10) of
                         1 -> pick(Fitting);
                         _ -> pick(Preferred)
                     end;
                 _ ->
                     pick(Fitting)
             end,
    {_, _, Text, Closer, Next} = Choice,
    nest(N - 1, Favoured, Next, [Text | Open], [Closer | Close]).

%% The limits on size, and 64 KiB runs of fragments that stress one path.
bounds() ->
    Fill = fun(Prefix, Byte, Size) ->
                   <<Prefix/binary, (binary:copy(<<Byte>>, Size - byte_size(Prefix)))/binary>>
           end,
    Runs = [binary:copy(F, ?MAX_BYTES div byte_size(F))
            || F <- [<<"{">>, <<"(">>, <<"$">>, <<"! ">>, <<"x=y ">>, <<"a|">>, <<"a^">>,
                     <<"''">>, <<"<<a ">>, <<"\\\n">>, <<"a\n">>, <<"#">>, <<"`{">>,
                     <<"<<'E'\n">>, <<"if(x)">>, <<"$x(">>, <<"'">>]],
    [Fill(<<"echo ">>, $a, ?MAX_BYTES),
     Fill(<<"echo ">>, $a, ?MAX_BYTES + 1),
     Fill(<<"# ">>, $c, ?MAX_BYTES),
     <<"cat <<'E'\n", (Fill(<<>>, $b, ?MAX_BYTES - 13))/binary, "\nE\n">>
     | Runs].

%% Checks

check(Source) ->
    check(Source, any).

check(Source, Expect) ->
    Result = try erx_shell_parse:parse(Source)
             catch Class:Reason:Stack -> fail(raised, Source, {Class, Reason, Stack})
             end,
    case {Result, Expect} of
        {{ok, Program}, _} ->
            Levels = try program_levels(Program)
                     catch error:Reason1:Stack1 -> fail(malformed_tree, Source, {Program, Reason1, Stack1})
                     end,
            byte_size(Source) =< ?MAX_BYTES orelse fail(over_size_accepted, Source, byte_size(Source)),
            case Expect of
                {levels, Levels} -> ok;
                {levels, Wanted} -> fail(wrong_levels, Source, {Wanted, Levels});
                too_deep -> fail(too_deep_accepted, Source, Levels);
                any -> ok
            end,
            Levels =< ?MAX_LEVELS orelse fail(too_many_levels, Source, Levels),
            round_trip(Source, Program),
            ok;
        {{error, {too_deep, Pos}}, Expect} when Expect =:= too_deep; Expect =:= any ->
            position(Source, Pos),
            error;
        {{error, {too_long, Bytes}}, any} when Bytes =:= byte_size(Source), Bytes > ?MAX_BYTES ->
            error;
        {{error, {Kind, Pos, Message}}, any} when Kind =:= syntax; Kind =:= incomplete ->
            position(Source, Pos),
            fixed(Message) orelse fail(message_not_fixed, Source, Message),
            error;
        _ ->
            fail(unexpected_result, Source, {Expect, Result})
    end,
    Text = case Result of
               {error, Diagnostic} -> erx_shell_parse:format_error(Diagnostic);
               {ok, _} -> <<"ok">>
           end,
    printable(Text) orelse fail(unprintable_format, Source, Text),
    case Result of
        {ok, _} -> ok;
        {error, _} -> error
    end.

%% A position names a line of the source and a column of that line, or the
%% column just past its end.
position(Source, {Line, Column}) ->
    Lines = binary:split(Source, <<"\n">>, [global]),
    case Line >= 1 andalso Line =< length(Lines) of
        true ->
            Column >= 1 andalso Column =< byte_size(lists:nth(Line, Lines)) + 1
                orelse fail(column_outside_line, Source, {Line, Column});
        false ->
            fail(line_outside_source, Source, {Line, Column})
    end.

%% A message is one of the parser's fixed texts, so it quotes no source.
fixed(Message) ->
    Named = [<<"^">>, <<"(">>, <<"$">>, <<"$#">>, <<"$\"">>, <<"`">>, <<"&&">>,
             <<"||">>, <<"|">>, <<";">>, <<"&">>, <<"=">>, <<"{">>, <<"}">>, <<")">>,
             <<"in">>, <<"not">>, <<"for">>, <<"while">>, <<"if">>, <<"switch">>,
             <<"fn">>, <<"~">>, <<"!">>, <<"@">>, <<"<{">>, <<">{">>],
    Unexpected = [<<"unexpected ", T/binary>>
                  || T <- [<<"word">>, <<"quoted word">>, <<"end of input">>,
                           <<"newline">>, <<"redirection">>
                           | [<<"'", K/binary, "'">> || K <- Named]]],
    Expected = [<<"expected '", K/binary, "'">> || K <- [<<"(">>, <<")">>, <<"{">>, <<"}">>]],
    Fixed = [<<"a command must follow">>, <<"a word must follow">>,
             <<"a word must follow '^'">>, <<"a variable name must follow '$'">>,
             <<"a switch body must begin with case">>, <<"a case takes only words">>,
             <<"malformed redirection">>, <<"malformed pipe">>,
             <<"descriptor number is too large">>, <<"here document has no tag">>,
             <<"here document tag is not one word">>,
             <<"here document is not terminated">>, <<"quoted word is not closed">>,
             <<"line continues past the end of the input">>],
    lists:member(Message, Unexpected ++ Expected ++ Fixed).

printable(Text) ->
    lists:all(fun(C) -> C >= $\s andalso C =< $~ end, binary_to_list(Text)).

round_trip(Source, Program) ->
    case printed(Program) of
        heredoc ->
            ok;
        Printed when byte_size(Printed) > ?MAX_BYTES ->
            ok;
        Printed ->
            case erx_shell_parse:parse(Printed) of
                {ok, Program} -> ok;
                Other -> fail(round_trip, Source, {Printed, Other})
            end
    end.

fail(What, Source, Detail) ->
    io:format("~p on ~P:~n~P~n", [What, Source, 80, Detail, 80]),
    error({What, Source}).

%% The levels of a tree, from docs/design-shell.md's rule and the parser's
%% types: one for each construct that holds what is inside it, none for flat
%% lists. Every clause matches only a node of the shape the types give, so a
%% node of any other shape fails the match.

program_levels(Cmds) when is_list(Cmds) -> max_of(fun cmd_levels/1, Cmds).

cmd_levels({simple, [_ | _] = Words, Redirs}) ->
    max(max_of(fun word_levels/1, Words), max_of(fun redir_levels/1, Redirs));
cmd_levels({block, Cmds, Redirs}) ->
    max(1 + program_levels(Cmds), max_of(fun redir_levels/1, Redirs));
cmd_levels({background, Cmd}) -> cmd_levels(Cmd);
cmd_levels({pipeline, First, [_ | _] = Stages}) ->
    max(cmd_levels(First), max_of(fun({{L, R}, Cmd}) when ?IS_FD(L), ?IS_FD(R) -> cmd_levels(Cmd) end, Stages));
cmd_levels({and_or, First, [_ | _] = Rest}) ->
    max(cmd_levels(First), max_of(fun({Op, Cmd}) when Op =:= 'and'; Op =:= 'or' -> cmd_levels(Cmd) end, Rest));
cmd_levels({Prefix, Body}) when Prefix =:= 'not'; Prefix =:= subshell; Prefix =:= if_not ->
    1 + body_levels(Body);
cmd_levels({redirect, Redir, Body}) -> max(redir_levels(Redir), 1 + body_levels(Body));
cmd_levels({assign, Name, Value}) -> max(word_levels(Name), word_levels(Value));
cmd_levels({local, Name, Value, Cmd}) ->
    lists:max([word_levels(Name), word_levels(Value), 1 + cmd_levels(Cmd)]);
cmd_levels({Loop, Condition, Body}) when Loop =:= 'if'; Loop =:= while ->
    1 + max(program_levels(Condition), body_levels(Body));
cmd_levels({for, Var, List, Body}) ->
    Words = case List of
                args -> [];
                {in, Ws} when is_list(Ws) -> Ws
            end,
    1 + lists:max([word_levels(Var), max_of(fun word_levels/1, Words), body_levels(Body)]);
cmd_levels({switch, Subject, Arms}) when is_list(Arms) ->
    1 + max(word_levels(Subject),
            max_of(fun({'case', Patterns, Cmds}) ->
                           max(max_of(fun word_levels/1, Patterns), program_levels(Cmds))
                   end, Arms));
cmd_levels({match, Subject, Patterns}) ->
    max(word_levels(Subject), max_of(fun word_levels/1, Patterns));
cmd_levels({fn, Names, Body}) ->
    1 + max(max_of(fun word_levels/1, Names), program_levels(Body));
cmd_levels({fn_delete, Names}) ->
    1 + max_of(fun word_levels/1, Names).

body_levels(empty) -> 0;
body_levels(Cmd) -> cmd_levels(Cmd).

word_levels({Kind, Text}) when (Kind =:= word orelse Kind =:= quoted), is_binary(Text) -> 0;
word_levels({concat, [_, _ | _] = Parts}) ->
    max_of(fun(Part) when element(1, Part) =/= concat -> word_levels(Part) end, Parts);
word_levels({Kind, Name}) when Kind =:= var; Kind =:= count; Kind =:= flat ->
    1 + name_levels(Name);
word_levels({var_sub, Name, Index}) ->
    1 + max(name_levels(Name), max_of(fun word_levels/1, Index));
word_levels({list, Words}) -> 1 + max_of(fun word_levels/1, Words);
word_levels({backquote, ifs, Cmds}) -> 1 + program_levels(Cmds);
word_levels({backquote, Split, Cmds}) -> 1 + max(word_levels(Split), program_levels(Cmds));
word_levels({pipefd, Direction, Cmds}) when Direction =:= read; Direction =:= write ->
    1 + program_levels(Cmds).

%% What `$` names is one part, never a joined word.
name_levels({concat, _} = Word) -> error({joined_name, Word});
name_levels(Word) -> word_levels(Word).

redir_levels({Kind, Fd, Word}) when (Kind =:= write orelse Kind =:= append orelse Kind =:= read
                                     orelse Kind =:= rdwr), ?IS_FD(Fd) ->
    word_levels(Word);
redir_levels({here, Fd, {literal, Text}}) when ?IS_FD(Fd), is_binary(Text) -> 0;
redir_levels({here, Fd, {template, Parts}}) when ?IS_FD(Fd) ->
    true = lists:all(fun(P) -> is_binary(P) orelse (is_tuple(P) andalso tuple_size(P) =:= 2
                                                     andalso element(1, P) =:= var
                                                     andalso is_binary(element(2, P))) end, Parts),
    0;
redir_levels({dup, To, From}) when ?IS_FD(To), ?IS_FD(From) -> 0;
redir_levels({close, Fd}) when ?IS_FD(Fd) -> 0.

max_of(Levels, List) when is_list(List) ->
    lists:foldl(fun(Item, Max) -> max(Levels(Item), Max) end, 0, List).

%% The tree printed back to rc's syntax, which is checked only when it fits
%% the bound, every command followed by `;` so
%% that an empty body stays empty, every join written as `^`, and every
%% descriptor written out. Here documents are not printed.

printed(Program) ->
    try iolist_to_binary(seq(Program))
    catch throw:heredoc -> heredoc
    end.

seq(Cmds) -> [[cmd(C), <<";">>] || C <- Cmds].

cmd({simple, Words, Redirs}) -> join([word(W) || W <- Words] ++ [redir(R) || R <- Redirs]);
cmd({block, Cmds, Redirs}) -> [<<"{">>, seq(Cmds), <<"}">>, [[<<" ">>, redir(R)] || R <- Redirs]];
cmd({background, Cmd}) -> [cmd(Cmd), <<" &">>];
cmd({pipeline, First, Stages}) -> [cmd(First), [[<<" ">>, pipe(P), <<" ">>, cmd(C)] || {P, C} <- Stages]];
cmd({and_or, First, Rest}) -> [cmd(First), [[logic(Op), cmd(C)] || {Op, C} <- Rest]];
cmd({'not', Body}) -> [<<"! ">>, body(Body)];
cmd({subshell, Body}) -> [<<"@ ">>, body(Body)];
cmd({if_not, Body}) -> [<<"if not ">>, body(Body)];
cmd({redirect, Redir, Body}) -> [redir(Redir), <<" ">>, body(Body)];
cmd({assign, Name, Value}) -> [word(Name), <<"=">>, word(Value)];
cmd({local, Name, Value, Cmd}) -> [word(Name), <<"=">>, word(Value), <<" ">>, cmd(Cmd)];
cmd({'if', Condition, Body}) -> [<<"if(">>, seq(Condition), <<") ">>, body(Body)];
cmd({while, Condition, Body}) -> [<<"while(">>, seq(Condition), <<") ">>, body(Body)];
cmd({for, Var, args, Body}) -> [<<"for(">>, word(Var), <<") ">>, body(Body)];
cmd({for, Var, {in, Words}, Body}) ->
    [<<"for(">>, word(Var), <<" in ">>, join([word(W) || W <- Words]), <<") ">>, body(Body)];
cmd({switch, Subject, Arms}) ->
    [<<"switch ">>, word(Subject), <<" {">>,
     [[<<"case ">>, join([word(P) || P <- Patterns]), <<";">>, seq(Cmds)] || {'case', Patterns, Cmds} <- Arms],
     <<"}">>];
cmd({match, Subject, Patterns}) -> [<<"~ ">>, join([word(W) || W <- [Subject | Patterns]])];
cmd({fn, Names, Body}) -> [<<"fn ">>, join([word(N) || N <- Names]), <<" {">>, seq(Body), <<"}">>];
cmd({fn_delete, Names}) -> [<<"fn ">>, join([word(N) || N <- Names])].

body(empty) -> <<>>;
body(Cmd) -> cmd(Cmd).

logic('and') -> <<" && ">>;
logic('or') -> <<" || ">>.

pipe({Left, Right}) -> [<<"|[">>, integer_to_binary(Left), <<"=">>, integer_to_binary(Right), <<"]">>].

word({word, Text}) -> Text;
word({quoted, Text}) -> [<<"'">>, binary:replace(Text, <<"'">>, <<"''">>, [global]), <<"'">>];
word({concat, Parts}) -> lists:join(<<"^">>, [word(P) || P <- Parts]);
%% A name that begins with a double quote is set apart, or `$"` would read it.
word({var, {word, <<$", _/binary>>} = Name}) -> [<<"$ ">>, word(Name)];
word({var, Name}) -> [<<"$">>, word(Name)];
word({count, Name}) -> [<<"$#">>, word(Name)];
word({flat, Name}) -> [<<"$\"">>, word(Name)];
word({var_sub, Name, Index}) -> [<<"$">>, word(Name), <<"(">>, join([word(W) || W <- Index]), <<")">>];
word({list, Words}) -> [<<"(">>, join([word(W) || W <- Words]), <<")">>];
word({backquote, ifs, Cmds}) -> [<<"`{">>, seq(Cmds), <<"}">>];
word({backquote, Split, Cmds}) -> [<<"`">>, word(Split), <<"{">>, seq(Cmds), <<"}">>];
word({pipefd, read, Cmds}) -> [<<"<{">>, seq(Cmds), <<"}">>];
word({pipefd, write, Cmds}) -> [<<">{">>, seq(Cmds), <<"}">>].

redir({write, Fd, Word}) -> [<<">[">>, integer_to_binary(Fd), <<"] ">>, word(Word)];
redir({append, Fd, Word}) -> [<<">>[">>, integer_to_binary(Fd), <<"] ">>, word(Word)];
redir({read, Fd, Word}) -> [<<"<[">>, integer_to_binary(Fd), <<"] ">>, word(Word)];
redir({rdwr, Fd, Word}) -> [<<"<>[">>, integer_to_binary(Fd), <<"] ">>, word(Word)];
redir({dup, To, From}) -> [<<">[">>, integer_to_binary(To), <<"=">>, integer_to_binary(From), <<"]">>];
redir({close, Fd}) -> [<<">[">>, integer_to_binary(Fd), <<"=]">>];
redir({here, _, _}) -> throw(heredoc).

join(Parts) -> lists:join(<<" ">>, Parts).

pick(List) -> lists:nth(rand:uniform(length(List)), List).
