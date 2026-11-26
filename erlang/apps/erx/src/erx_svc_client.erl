%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_svc_client).
-moduledoc """
The one way a system command reads, commands or opens a file of a
service's tree under `/svc` (docs/design-app-trees.md, "Reading with a
deadline", AT6). A caller names a service and a file of its tree, never a
path: `Name` is the service's name as `/svc` lists it, one name, and
`File` a relative path within its tree, such as `<<"status">>`. This
module alone joins them into `/svc/Name/File`, and answers
`{error, einval}`, reaching nothing, for a `Name` that is not one name
(empty, `.`, `..`, or holding a `/` or a NUL) or a `File` that is not
one or more names joined by `/`, so no caller reaches outside the tree
it names.

read/4 and command/3 make their call in a process of their own, linked
to the caller, and wait for it until the deadline their caller gives, at
most `svc_wait_max` milliseconds. At the deadline the process is killed,
which ends its fids at the grant (docs/design-files.md, "Fid owners"),
and its answer goes to an alias that ended with the wait; the caller's
own end, an interrupt's included, ends it through the link, and the
process's crash ends the caller the same way, or, in a caller that traps
exits, raises `{svc_reader_ended, Reason}`. A late answer already
received when the deadline passes is the call's answer, being known.
open/3 opens
in the caller's process and sets no deadline: its caller is a process of
the foreground job, which `Ctrl-C` ends.

`not_serving` answers a `Name` that `/svc` does not hold: an open that
fails `enoent` is followed by a look at `/svc/Name` itself, and only its
`enoent` is `not_serving`. A command whose write may have reached the
server with its answer lost, at the deadline or on `eio`, answers
`unknown`, and is never written again.
""".

-include("generated/erx_abi.hrl").

-export([read/4, command/3, open/3]).
-export_type([name/0, file/0]).

-ifdef(TEST).
-export([read/5, command/4, open/4]).
-endif.

-doc "A service's name as `/svc` lists it: one name.".
-type name() :: binary().
-doc "A relative path within a service's tree.".
-type file() :: binary().
-doc "Milliseconds a call may wait, at most `svc_wait_max`.".
-type deadline() :: 0..?ERX_SVC_WAIT_MAX.

-define(DEADLINE(D), is_integer(D), D >= 0, D =< ?ERX_SVC_WAIT_MAX).

%%% The calls

-doc """
Reads `File` of `Name`'s tree until end of file or `Max + 1` bytes,
waiting at most `Deadline` milliseconds. Bytes longer than `Max` say the
file is longer than `Max`.
""".
-spec read(name(), file(), 0..?ERX_SVC_STATUS_MAX, deadline()) ->
          {ok, binary()} | {error, file:posix()} | not_serving | timeout.
read(Name, File, Max, Deadline) ->
    read(file, Name, File, Max, Deadline).

-doc """
Writes `Line` once to the `ctl` of `Name`'s tree, waiting at most
`Deadline` milliseconds. `unknown` is the answer whenever the write may
have reached the server and its answer is lost. A `Line` longer than
`svc_ctl_max` answers `{error, einval}` and is not written, so one write
holds it whatever the server's largest write.
""".
-spec command(name(), binary(), deadline()) ->
          ok | {error, file:posix()} | not_serving | unknown.
command(Name, Line, Deadline) ->
    command(file, Name, Line, Deadline).

-doc """
Opens `File` of `Name`'s tree with `Modes` in the calling process and
returns its descriptor. It sets no deadline.
""".
-spec open(name(), file(), [file:mode()]) ->
          {ok, file:io_device()} | {error, file:posix() | badarg} |
          not_serving.
open(Name, File, Modes) ->
    open(file, Name, File, Modes).

%%% The calls over a file module: `file`, or a host test's stub tree

-doc false.
read(Files, Name, File, Max, Deadline)
  when is_integer(Max), Max >= 0, Max =< ?ERX_SVC_STATUS_MAX,
       ?DEADLINE(Deadline) ->
    within(Name, File,
           fun(Path) ->
                   waited(fun() -> read_file(Files, Name, Path, Max) end,
                          Deadline, timeout)
           end).

-doc false.
command(_Files, _Name, Line, Deadline)
  when is_binary(Line), byte_size(Line) > ?ERX_SVC_CTL_MAX, ?DEADLINE(Deadline) ->
    {error, einval};
command(Files, Name, Line, Deadline) when is_binary(Line), ?DEADLINE(Deadline) ->
    within(Name, <<"ctl">>,
           fun(Path) ->
                   Answer = waited(fun() -> write_ctl(Files, Name, Path, Line) end,
                                   Deadline, unknown),
                   commanded(Answer)
           end).

-doc false.
open(Files, Name, File, Modes) when is_list(Modes) ->
    within(Name, File,
           fun(Path) -> or_not_serving(Files, Name, Files:open(Path, Modes)) end).

%%% The path

%% Call(Path) with the one path this module builds, or einval, reaching
%% nothing, when Name is not one name or File leaves the tree.
within(Name, File, Call) ->
    case is_name(Name) andalso is_file(File) of
        true -> Call(<<(tree(Name))/binary, "/", File/binary>>);
        false -> {error, einval}
    end.

tree(Name) -> <<"/svc/", Name/binary>>.

is_name(<<".">>) -> false;
is_name(<<"..">>) -> false;
is_name(Name) when is_binary(Name), byte_size(Name) > 0 ->
    binary:match(Name, [<<"/">>, <<0>>]) =:= nomatch;
is_name(_) -> false.

is_file(File) when is_binary(File) ->
    lists:all(fun is_name/1, binary:split(File, <<"/">>, [global]));
is_file(_) -> false.

%%% The wait

%% Call() in a process linked to the caller, its answer sent to a reply-once
%% alias; Late when the deadline passes first. Whatever the answer, the
%% process is ended, unlinked and its signals flushed, so neither a late
%% answer nor its end reaches the caller.
waited(Call, Deadline, Late) ->
    Alias = alias([reply]),
    {Pid, Ref} = spawn_opt(fun() -> Alias ! {Alias, Call()} end, [link, monitor]),
    receive
        {Alias, Answer} ->
            ended(Pid, Ref),
            Answer;
        {'DOWN', Ref, process, Pid, Reason} ->
            ended(Pid, Ref),
            erlang:error({svc_reader_ended, Reason})
    after Deadline ->
            unalias(Alias),
            ended(Pid, Ref),
            receive {Alias, Answer} -> Answer after 0 -> Late end
    end.

ended(Pid, Ref) ->
    unlink(Pid),
    exit(Pid, kill),
    demonitor(Ref, [flush]),
    receive {'EXIT', Pid, _} -> ok after 0 -> ok end.

%%% The effects, each in the waiting process

read_file(Files, Name, Path, Max) ->
    case Files:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try read_all(Files, Fd, Max + 1, []) after Files:close(Fd) end;
        Error ->
            or_not_serving(Files, Name, Error)
    end.

read_all(Files, Fd, Want, Acc) when Want > 0 ->
    case Files:read(Fd, Want) of
        {ok, Data} -> read_all(Files, Fd, Want - byte_size(Data), [Acc, Data]);
        eof -> {ok, iolist_to_binary(Acc)};
        {error, _} = Error -> Error
    end;
read_all(_Files, _Fd, _Want, Acc) ->
    {ok, iolist_to_binary(Acc)}.

%% One write of Line; the answer is the write's, whatever the close answers.
write_ctl(Files, Name, Path, Line) ->
    case Files:open(Path, [write, raw, binary]) of
        {ok, Fd} ->
            try Files:write(Fd, Line) after Files:close(Fd) end;
        Error ->
            or_not_serving(Files, Name, Error)
    end.

%% An open's answer, enoent being not_serving when /svc holds no Name.
or_not_serving(Files, Name, {error, enoent} = Error) ->
    case Files:read_file_info(tree(Name), [raw]) of
        {error, enoent} -> not_serving;
        _ -> Error
    end;
or_not_serving(_Files, _Name, Answer) ->
    Answer.

%% A command's answer: eio, the file protocol's answer for a request whose
%% handler, grant or server ended before answering, may follow a write that
%% took effect, so it is unknown, as a write cut off at the deadline is.
commanded({error, eio}) -> unknown;
commanded(Answer) -> Answer.
