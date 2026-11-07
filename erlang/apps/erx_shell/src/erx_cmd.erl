%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd).
-moduledoc """
The behaviour of an Erlang command and the context it acts through
(docs/design-shell.md, "Commands" and "Interfaces").

A command is a module of the shell's release that declares its name and
its metadata as attributes and implements run/2:

```erlang
-module(erx_cmd_ps).
-behaviour(erx_cmd).
-erx_command(ps).
-erx_usage("ps").
-erx_needs([inspect]).
-erx_fields([pid, name, memory]).
run(Args, Ctx) -> ok | {error, usage} | {error, Reason}.
```

`-erx_command` names it in the command namespace (erx_shell_namespace),
`-erx_usage` is the line a usage error prints, `-erx_needs` the facets the
shell checks before it runs the command and `-erx_fields` the order of the
fields of the records it emits. run/2 gets its arguments as binaries and
the context; it returns `ok`, `{error, usage}`, whose usage line the shell
prints, `{error, {reported, Reason}}` once it has printed its own
diagnostics, or `{error, Reason}`, which the shell prints as
`name: reason`. Either error's reason, as format_error/1 writes it, is the
command's status. A crash is an error whose reason goes to standard error.

The context holds the command's name, its environment (the shell's
variables), its working directory, its three standard streams and its
facets. Every path a command takes from its arguments goes through
path/2, against the context's working directory, since the shell's
working directory is the session's and not the runtime's. A command
writes with emit/2 and say/2 and reads with read/1 or read_line/1; a
write that cannot be done, such as one to a pipe whose reader has ended,
ends the command at once with that error as its status, as `SIGPIPE`
ends a program. Facets are reached only through facet/2.
""".

-export([emit/2, say/2, report/3, read/1, read_line/1, facet/2, path/2,
         cwd/1, env/2, getopt/2, format_error/1]).

-export_type([ctx/0, stream/0]).

-callback run(Args :: [binary()], Ctx :: ctx()) ->
    ok | {error, usage} | {error, {reported, term()}} | {error, term()}.

%% A stream is a file's io device, the terminal's write function, a pipe to or
%% from a neighbouring Erlang stage, or nothing (/dev/null); `closed` is a
%% descriptor the line closed.
-type stream() :: {dev, file:io_device()} | {tty, fun((iodata()) -> ok)}
                | {pipe, pid()} | null | closed.

-type ctx() :: #{name := binary(),
                 fields := [atom()],
                 cwd := binary(),
                 env := #{binary() => [binary()]},
                 stdin := stream(),
                 stdout := stream(),
                 stderr := stream(),
                 facets := #{atom() => term()}}.

%% A record is at most 64 KiB, as external_size/1 measures it.
-define(MAX_RECORD, 1 bsl 16).

-doc """
Writes bytes, or a record of the command's declared fields, to standard
output: a record passes whole to a neighbouring Erlang stage and is
rendered as a line toward a file or the terminal.
""".
-spec emit(ctx(), iodata() | #{atom() => erx_render:attr()}) -> ok.
emit(#{stdout := Out, fields := Fields}, Record) when is_map(Record) ->
    erlang:external_size(Record) =< ?MAX_RECORD orelse stop(record_too_large),
    case Out of
        {pipe, Pipe} -> written(erx_shell_pipe:put(Pipe, {record, Fields, Record}));
        {tty, _} -> write(Out, erx_render:line(Fields, Record, terminal));
        _ -> write(Out, erx_render:line(Fields, Record, bytes))
    end;
emit(#{stdout := Out}, Bytes) ->
    write(Out, iolist_to_binary(Bytes)).

-doc "Writes bytes to standard error.".
-spec say(ctx(), iodata()) -> ok.
say(#{stderr := Err}, Bytes) ->
    write(Err, iolist_to_binary(Bytes)).

-doc "Writes `name: subject: reason` to standard error.".
-spec report(ctx(), iodata(), term()) -> ok.
report(#{name := Name} = Ctx, Subject, Reason) ->
    say(Ctx, [Name, <<": ">>, Subject, <<": ">>, format_error(Reason), $\n]).

-doc """
The next item of standard input: a line, with its newline unless it is
the last and has none, a record from a neighbouring Erlang stage, or
`eof`. A line over 64 KiB ends the command with `line too long`.
""".
-spec read(ctx()) -> binary() | #{atom() => erx_render:attr()} | eof.
read(Ctx) ->
    case next(Ctx) of
        {record, _Fields, Record} -> Record;
        Other -> Other
    end.

-doc "The next line of standard input, a record rendered as one, or `eof`.".
-spec read_line(ctx()) -> binary() | eof.
read_line(Ctx) ->
    case next(Ctx) of
        {record, Fields, Record} -> erx_render:line(Fields, Record, bytes);
        Other -> Other
    end.

next(#{stdin := {pipe, Pipe}}) ->
    case erx_shell_pipe:get(Pipe) of
        {line, Line} -> Line;
        {record, _, _} = Record -> Record;
        eof -> eof;
        {error, line_too_long} -> stop(line_too_long)
    end;
next(#{stdin := null}) -> eof;
next(#{stdin := closed}) -> stop(ebadf);
next(#{stdin := _}) -> stop(enotsup).

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
Splits leading flags off the arguments: each `-xyz` gives its letters,
which must be among Allowed; `--` ends the flags; `-` alone is an
argument. Answers the letters in order and the arguments after them.
""".
-spec getopt([binary()], string()) -> {ok, [char()], [binary()]} | {error, usage}.
getopt(Args, Allowed) -> getopt(Args, Allowed, []).

getopt([<<"--">> | Rest], _Allowed, Flags) ->
    {ok, lists:reverse(Flags), Rest};
getopt([<<"-", Letters/binary>> | Rest], Allowed, Flags) when Letters =/= <<>> ->
    Chars = binary_to_list(Letters),
    case lists:all(fun(C) -> lists:member(C, Allowed) end, Chars) of
        true -> getopt(Rest, Allowed, lists:reverse(Chars, Flags));
        false -> {error, usage}
    end;
getopt(Rest, _Allowed, Flags) ->
    {ok, lists:reverse(Flags), Rest}.

-doc "An error's text, as a command's status and in its diagnostics.".
-spec format_error(term()) -> binary().
format_error(line_too_long) -> <<"line too long">>;
format_error(record_too_large) -> <<"record too large">>;
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

write(_Stream, <<>>) -> ok;
write({pipe, Pipe}, Bytes) -> written(erx_shell_pipe:put(Pipe, {bytes, Bytes}));
write({dev, Device}, Bytes) ->
    written(file:write(Device, Bytes));
write({tty, Write}, Bytes) ->
    written(Write(Bytes));
write(null, _Bytes) -> ok;
write(closed, _Bytes) -> stop(ebadf).

written(ok) -> ok;
written({error, Reason}) -> stop(Reason).

%% Ends the command with Reason as its status; the shell's runner catches
%% it around run/2.
stop(Reason) -> throw({erx_cmd_stop, Reason}).
