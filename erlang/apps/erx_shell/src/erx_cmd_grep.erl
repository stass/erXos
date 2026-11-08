%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_grep).
-moduledoc """
`grep [-EFcilnqv] pattern [file ...]`: FreeBSD's grep (usr.bin/grep)
with a small core of its options (docs/design-shell.md, "Text
commands").

It writes each line that matches the pattern, a POSIX basic regular
expression, an extended one under `-E` or a fixed string under `-F`,
reading standard input when no file is named or for `-`. A pattern
holding newlines is one pattern per line, and a line matches when any of
them does. `-i` ignores ASCII case, `-v` selects the lines that do not
match, `-c` writes a count of the selected lines, `-l` the name of each
file with one, `-n` puts each line's number and `:` before it, and `-q`
writes nothing and stops at the first. With more than one file, each
output line starts with its file's name and `:`. Every input is text, as
under FreeBSD's `-a`, and a selected last line without a newline gets one.

The pattern is translated by erx_grep_re, which refuses what FreeBSD's
regcomp(3) refuses, as `grep: message`. Each line is matched under `re`'s
match limits, and a line that passes them ends `grep` with `grep: pattern
too complex`, so no pattern spends unbounded time on a line. Lines are
read through the same 64 KiB line bound from a file as from a pipe
(erx_shell_pipe), where FreeBSD's take lines of any length.

Status, as FreeBSD's: 0 when a line was selected, 1 when none was, 2 on
an error; a file that cannot be read is reported as `grep: name: reason`
and makes the status 2 even when a line was selected, unless `-q` found
one.
""".

-behaviour(erx_cmd).
-erx_command(grep).
-erx_usage("grep [-EFcilnqv] pattern [file ...]").

-export([run/2]).
-export([compile/2]).

%% `re`'s limits on one match: the backtracking steps and the depth of its
%% recursion. A line that needs more fails with pattern too complex.
-define(MATCH_LIMIT, 1000000).
-define(RECURSION_LIMIT, 10000).

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "EFcilnqv") of
        {ok, Flags, [Pattern | Files]} -> grep(options(Flags), Pattern, Files, Ctx);
        _ -> {error, usage}
    end.

options(Flags) ->
    Has = fun(C) -> lists:member(C, Flags) end,
    #{syntax => case {Has($F), Has($E)} of
                    {true, _} -> fixed;
                    {false, true} -> ere;
                    {false, false} -> bre
                end,
      ignore_case => Has($i), invert => Has($v), count => Has($c),
      names => Has($l), numbers => Has($n), quiet => Has($q)}.

grep(Options, Pattern, Files, Ctx) ->
    case compile(Pattern, Options) of
        {ok, Patterns} ->
            Named = case Files of [] -> [<<"-">>]; _ -> Files end,
            Prefix = length(Named) > 1,
            try lists:foldl(fun(File, Acc) -> search(File, Patterns, Options#{prefix => Prefix}, Acc, Ctx) end,
                            #{matched => false, failed => false}, Named) of
                Result -> status(Result, Options)
            catch
                throw:quiet_match -> ok;
                throw:too_complex ->
                    erx_cmd:say(Ctx, <<"grep: pattern too complex\n">>),
                    {error, {reported, <<"2">>}}
            end;
        {error, Message} ->
            erx_cmd:say(Ctx, [<<"grep: ">>, Message, $\n]),
            {error, {reported, <<"2">>}}
    end.

status(#{matched := true, failed := false}, _Options) -> ok;
status(#{matched := true, failed := true}, #{quiet := true}) -> ok;
status(#{failed := true}, _Options) -> {error, {reported, <<"2">>}};
status(#{matched := false}, _Options) -> {error, {reported, <<"1">>}}.

-doc """
The compiled patterns of a pattern argument, one per line of it, or the
message that refuses it.
""".
-spec compile(binary(), #{syntax := erx_grep_re:syntax(), ignore_case := boolean(), _ => _}) ->
          {ok, [re:mp()]} | {error, binary()}.
compile(Pattern, #{syntax := Syntax} = Options) ->
    Sources = [erx_grep_re:translate(Line, Syntax) || Line <- binary:split(Pattern, <<"\n">>, [global])],
    case [Message || {error, Message} <- Sources] of
        [] ->
            Compiled = [re:compile(Source, erx_grep_re:options(Options)) || {ok, Source} <- Sources],
            case [MP || {ok, MP} <- Compiled] of
                MPs when length(MPs) =:= length(Compiled) -> {ok, MPs};
                _ -> {error, <<"regular expression too big">>}
            end;
        [Message | _] ->
            {error, Message}
    end.

%% One input: its selected lines, count or name, and how it went.
search(File, Patterns, Options, Acc, Ctx) ->
    case open(File, Ctx) of
        {ok, Input, Close} ->
            Name = case File of <<"-">> -> <<"(standard input)">>; _ -> File end,
            try lines(Input, Patterns, Options#{name => Name}, 1, 0, Ctx) of
                Selected ->
                    finish(Name, Selected, Options, Ctx),
                    Acc#{matched := maps:get(matched, Acc) orelse Selected > 0}
            after
                Close()
            end;
        {error, Reason} ->
            erx_cmd:say(Ctx, [<<"grep: ">>, File, <<": ">>, erx_cmd:format_error(Reason), $\n]),
            Acc#{failed := true}
    end.

%% Standard input is read as the command's; a file through a pipe of its
%% own, so its lines have the same bound.
open(<<"-">>, Ctx) ->
    {ok, fun() -> erx_cmd:read_line(Ctx) end, fun() -> ok end};
open(File, Ctx) ->
    case erx_shell_pipe:from_file(erx_cmd:path(Ctx, File)) of
        {ok, Pipe} -> {ok, fun() -> erx_cmd:read_line(Ctx#{stdin := {pipe, Pipe}}) end,
                       fun() -> erx_shell_pipe:stop(Pipe) end};
        {error, Reason} -> {error, Reason}
    end.

lines(Input, Patterns, Options, Number, Selected, Ctx) ->
    case Input() of
        eof ->
            Selected;
        Line ->
            Text = chomp(Line),
            case matches(Text, Patterns) =/= maps:get(invert, Options) of
                true ->
                    selected(Text, Number, Options, Ctx),
                    lines(Input, Patterns, Options, Number + 1, Selected + 1, Ctx);
                false ->
                    lines(Input, Patterns, Options, Number + 1, Selected, Ctx)
            end
    end.

selected(_Text, _Number, #{quiet := true}, _Ctx) -> throw(quiet_match);
selected(_Text, _Number, #{names := true}, _Ctx) -> ok;
selected(_Text, _Number, #{count := true}, _Ctx) -> ok;
selected(Text, Number, #{name := Name, prefix := Prefix, numbers := Numbers}, Ctx) ->
    erx_cmd:write(Ctx, [[[Name, $:] || Prefix], [[integer_to_binary(Number), $:] || Numbers],
                        Text, $\n]).

%% What `-l` and `-c` write once a file is read.
finish(Name, Selected, #{names := true}, Ctx) when Selected > 0 ->
    erx_cmd:write(Ctx, [Name, $\n]);
finish(_Name, _Selected, #{names := true}, _Ctx) ->
    ok;
finish(Name, Selected, #{count := true, prefix := Prefix}, Ctx) ->
    erx_cmd:write(Ctx, [[[Name, $:] || Prefix], integer_to_binary(Selected), $\n]);
finish(_Name, _Selected, _Options, _Ctx) ->
    ok.

matches(Text, Patterns) ->
    lists:any(fun(MP) -> match(Text, MP) end, Patterns).

match(Text, MP) ->
    case re:run(Text, MP, [{capture, none}, report_errors, {match_limit, ?MATCH_LIMIT},
                           {match_limit_recursion, ?RECURSION_LIMIT}]) of
        match -> true;
        nomatch -> false;
        {error, _Limit} -> throw(too_complex)
    end.

chomp(Line) ->
    case binary:last(Line) of
        $\n -> binary:part(Line, 0, byte_size(Line) - 1);
        _ -> Line
    end.
