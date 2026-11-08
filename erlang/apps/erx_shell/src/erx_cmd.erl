%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd).
-moduledoc """
The behaviour of an Erlang command and the context it acts through
(docs/design-shell.md, "Commands", "Pipelines" and "Interfaces").

A command is a module of the shell's release that declares its name and
its metadata as attributes and implements run/2:

```erlang
-module(erx_cmd_ps).
-behaviour(erx_cmd).
-erx_command(ps).
-erx_usage("ps [-mr] [-o keyword[,keyword...]]").
run(Args, Ctx) -> ok | {error, usage} | {error, Reason}.
```

`-erx_command` names it in the command namespace (erx_shell_namespace),
`-erx_usage` is the line a usage error prints and `-erx_needs`, when
present, the facets the shell checks before it runs the command. run/2
gets its arguments as binaries and the context; it returns `ok`,
`{error, usage}`, whose usage line the shell prints, `{error, {reported,
Reason}}` once it has printed its own diagnostics, or `{error, Reason}`,
which the shell prints as `name: reason`. Either error's reason, as
format_error/1 writes it, is the command's status. A crash is an error
whose reason goes to standard error.

The context holds the command's name, its environment (the shell's
variables), its working directory, its three standard streams and its
facets. Every path a command takes from its arguments goes through
path/2, against the context's working directory, since the shell's
working directory is the session's and not the runtime's. Facets are
reached only through facet/2.

Every stream carries bytes, whatever is at the other end: a command
writes with write/2 and say/2 and reads with read/1, the bytes in
flight, or read_line/1, one line of at most 64 KiB; nothing it writes is
framed or rendered on the way. Where FreeBSD's command of the same name
looks at whether its output is a terminal, as `ls` does, it asks
isatty/2, and the terminal's width, columns/1. A write that cannot be
done, such as one to a pipe whose reader has ended, and a line over
64 KiB, end the command at once with that error as its status, as
`SIGPIPE` ends a program.
""".

-export([write/2, say/2, report/3, read/1, read_line/1, isatty/2, columns/1,
         facet/2, path/2, cwd/1, env/2, getopt/2, format_error/1]).

-export_type([ctx/0, stream/0]).

-callback run(Args :: [binary()], Ctx :: ctx()) ->
    ok | {error, usage} | {error, {reported, term()}} | {error, term()}.

%% A stream is a file's io device, the terminal's write function, a pipe to or
%% from a neighbouring Erlang stage, or nothing (/dev/null); `closed` is a
%% descriptor the line closed.
-type stream() :: {dev, file:io_device()} | {tty, fun((iodata()) -> ok)}
                | {pipe, pid()} | null | closed.

-type ctx() :: #{name := binary(),
                 cwd := binary(),
                 env := #{binary() => [binary()]},
                 stdin := stream(),
                 stdout := stream(),
                 stderr := stream(),
                 facets := #{atom() => term()}}.

-doc "Writes bytes to standard output.".
-spec write(ctx(), iodata()) -> ok.
write(#{stdout := Out}, Bytes) ->
    put_bytes(Out, iolist_to_binary(Bytes)).

-doc "Writes bytes to standard error.".
-spec say(ctx(), iodata()) -> ok.
say(#{stderr := Err}, Bytes) ->
    put_bytes(Err, iolist_to_binary(Bytes)).

-doc "Writes `name: subject: reason` to standard error.".
-spec report(ctx(), iodata(), term()) -> ok.
report(#{name := Name} = Ctx, Subject, Reason) ->
    say(Ctx, [Name, <<": ">>, Subject, <<": ">>, format_error(Reason), $\n]).

-doc """
The next bytes of standard input, as many as are in flight and at most
64 KiB, or `eof`.
""".
-spec read(ctx()) -> binary() | eof.
read(#{stdin := {pipe, Pipe}}) ->
    case erx_shell_pipe:get_bytes(Pipe) of
        {bytes, Bytes} -> Bytes;
        eof -> eof
    end;
read(#{stdin := Other}) ->
    no_input(Other).

-doc """
The next line of standard input, with its newline unless it is the last
and has none, or `eof`. A line over 64 KiB, newline included, ends the
command with `line too long`.
""".
-spec read_line(ctx()) -> binary() | eof.
read_line(#{stdin := {pipe, Pipe}}) ->
    case erx_shell_pipe:get(Pipe) of
        {line, Line} -> Line;
        eof -> eof;
        {error, line_too_long} -> stop(line_too_long)
    end;
read_line(#{stdin := Other}) ->
    no_input(Other).

%% Every input the shell hands a command is a pipe (erx_shell_pipe), and
%% nothing else is read.
no_input(null) -> eof;
no_input(closed) -> stop(ebadf);
no_input(_Stream) -> stop(enotsup).

-doc "Whether a standard stream is the session's terminal.".
-spec isatty(ctx(), stdin | stdout | stderr) -> boolean().
isatty(Ctx, Stream) when Stream =:= stdin; Stream =:= stdout; Stream =:= stderr ->
    case maps:get(Stream, Ctx) of
        {tty, _} -> true;
        _ -> false
    end.

-doc """
The terminal's width in columns: `COLUMNS` when it is a positive number,
as FreeBSD's `ls` and `ps` take it first, else the width the terminal
reports, else `unknown`, for which each command keeps FreeBSD's default.
""".
-spec columns(ctx()) -> pos_integer() | unknown.
columns(Ctx) ->
    case env(Ctx, <<"COLUMNS">>) of
        [Text] when byte_size(Text) =< 9 ->
            case string:to_integer(Text) of
                {Columns, <<>>} when Columns > 0 -> Columns;
                _ -> terminal_columns()
            end;
        _ ->
            terminal_columns()
    end.

terminal_columns() ->
    case io:columns() of
        {ok, Columns} when is_integer(Columns), Columns > 0 -> Columns;
        _ -> unknown
    end.

-doc "The facet of that name in the context, or `{error, no_facet}`.".
-spec facet(ctx(), atom()) -> {ok, term()} | {error, no_facet}.
facet(#{facets := Facets}, Name) ->
    case maps:find(Name, Facets) of
        {ok, Facet} -> {ok, Facet};
        error -> {error, no_facet}
    end.

-doc """
An argument's path made absolute against the working directory, with `.`
and `..` taken away by their names, as the namespace resolves them.
""".
-spec path(ctx() | binary(), binary()) -> binary().
path(#{cwd := Cwd}, Arg) -> path(Cwd, Arg);
path(Cwd, <<"/", _/binary>> = Arg) when is_binary(Cwd) -> normal(Arg);
path(Cwd, Arg) when is_binary(Cwd) -> normal(<<Cwd/binary, "/", Arg/binary>>).

normal(Path) ->
    Names = lists:foldl(fun(<<>>, Acc) -> Acc;
                           (<<".">>, Acc) -> Acc;
                           (<<"..">>, [_ | Acc]) -> Acc;
                           (<<"..">>, []) -> [];
                           (Name, Acc) -> [Name | Acc]
                        end, [], binary:split(Path, <<"/">>, [global])),
    iolist_to_binary([[$/, Name] || Name <- lists:reverse(Names)] ++ [<<"/">> || Names =:= []]).

-doc "The working directory.".
-spec cwd(ctx()) -> binary().
cwd(#{cwd := Cwd}) -> Cwd.

-doc "A variable of the environment, `[]` when it is not set.".
-spec env(ctx(), binary()) -> [binary()].
env(#{env := Env}, Name) -> maps:get(Name, Env, []).

-doc """
Splits leading flags off the arguments, as getopt(3) does: each `-xyz`
gives its letters, which must be among Allowed; a letter followed by `:`
in Allowed takes an argument, the rest of its word or else the next
word, and is answered as `{Letter, Argument}`; `--` ends the flags; `-`
alone is an argument. Answers the flags in order and the arguments after
them.
""".
-spec getopt([binary()], string()) ->
          {ok, [char() | {char(), binary()}], [binary()]} | {error, usage}.
getopt(Args, Allowed) -> getopt(Args, Allowed, []).

getopt([<<"--">> | Rest], _Allowed, Flags) ->
    {ok, lists:reverse(Flags), Rest};
getopt([<<"-", Letters/binary>> | Rest], Allowed, Flags) when Letters =/= <<>> ->
    letters(Letters, Rest, Allowed, Flags);
getopt(Rest, _Allowed, Flags) ->
    {ok, lists:reverse(Flags), Rest}.

letters(<<>>, Rest, Allowed, Flags) ->
    getopt(Rest, Allowed, Flags);
letters(<<C, More/binary>>, Rest, Allowed, Flags) ->
    case lists:dropwhile(fun(A) -> A =/= C end, Allowed) of
        [C, $: | _] when More =/= <<>> -> getopt(Rest, Allowed, [{C, More} | Flags]);
        [C, $: | _] when Rest =/= [] -> getopt(tl(Rest), Allowed, [{C, hd(Rest)} | Flags]);
        [C, $: | _] -> {error, usage};
        [C | _] when C =/= $: -> letters(More, Rest, Allowed, [C | Flags]);
        _ -> {error, usage}
    end.

-doc "An error's text, as a command's status and in its diagnostics.".
-spec format_error(term()) -> binary().
format_error(line_too_long) -> <<"line too long">>;
format_error(eilseq) -> <<"illegal byte sequence">>;
format_error(no_facet) -> <<"no_facet">>;
format_error(Reason) when is_binary(Reason) -> Reason;
format_error(Reason) when is_atom(Reason) ->
    case file:format_error(Reason) of
        "unknown POSIX error" ++ _ -> atom_to_binary(Reason);
        Text -> unicode:characters_to_binary(Text)
    end;
format_error(Reason) ->
    iolist_to_binary(io_lib:format("~0tp", [Reason])).

%%% Writes

put_bytes(_Stream, <<>>) -> ok;
put_bytes({pipe, Pipe}, Bytes) -> written(erx_shell_pipe:put(Pipe, Bytes));
put_bytes({dev, Device}, Bytes) -> written(file:write(Device, Bytes));
put_bytes({tty, Write}, Bytes) -> written(Write(Bytes));
put_bytes(null, _Bytes) -> ok;
put_bytes(closed, _Bytes) -> stop(ebadf).

written(ok) -> ok;
written({error, Reason}) -> stop(Reason).

%% Ends the command with Reason as its status; the shell's runner catches
%% it around run/2.
stop(Reason) -> throw({erx_cmd_stop, Reason}).
