%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_job).
-moduledoc """
The job relay (docs/design-ssh.md, "Sessions, ttys and shells"): one
process of the session that runs `rc -c Command` for an SSH channel with no
pseudo-terminal and relays the job to the channel with the job messages.
erx_ssh_job_core decides every step; this module carries out its actions.

The channel starts the relay (start/2) and makes an alias of its own for
the job, which only the two of them are given. Every job message is tagged
with it both ways: the relay sends `{Alias, Message}` to the alias, and
takes from the channel only `{Alias, Message}`. So no other process of the
session can send either side a job message, by mistake or by naming its
pid.

The job's standard input, output and error are three of the command shell's
message pipes (erx_shell_pipe), which the relay makes and so ends with. The
relay holds standard input's writing end and the reading ends of the other
two, and rc the opposite ends. It never waits on a pipe: each write and
read is an asynchronous request whose answer is a message, so the relay
always hears its channel. At the core's `close_input` it lets go of
standard input's writing end, and rc reads end of file.

rc runs linked to the relay (erx_shell_script:job/5), so rc ends whenever
the relay does. The relay watches rc and the channel with monitors: rc's
end gives the job's status (erx_console:shell_ending/1), and the channel's
end is `job_hangup`.

The job's group leader is the relay's group, a process the relay starts
linked to it. The group makes each output request's bytes, running the
function a `put_chars` names as stock OTP's group runs it, and, unlike that
group, which hands each request to its driver and goes on, serves one
request at a time: it writes the bytes to standard error, waiting for
room, and answers once they have entered. So a job that prints faster than
its channel takes waits in its own requests, each printing process with at
most one waiting since io's functions wait for their answer, and the relay
holds none of the job's output and runs none of its code: whatever a
printer's function does, the relay still hears its channel, and its end
kills the group (over/2); a crash of the relay ends the group by the link,
unless a printer's function in the group traps exits. The group writes to
standard error without holding it, so the stream still ends with rc. Every
other request is answered `{error, enotsup}`, and a `requests` list with
any other request in it `{error, request}`. rc ends only once an empty
output request of its own is answered (erx_shell_script:job/5), so every
output request the job made before it has entered standard error before
the stream ends.

Every other message, rc's exit signal among them, is dropped.
""".

-export([start/2]).
-export_type([tag/0]).

-include("generated/erx_abi.hrl").

-doc "The alias of the channel's that tags the job messages between it and the relay.".
-type tag() :: reference().

%% The answer each outstanding pipe request is waiting for, by its reference.
-type pending() :: write | {read, erx_ssh_job_core:stream()}.

%% job: the core's state; alias: the channel's tag; channel_ref and rc_ref: the
%% monitors of the channel and of rc; group: the job's group; stdin, stdout and
%% stderr: the pipes; pending: the outstanding pipe requests.
-record(relay, {job :: erx_ssh_job_core:job(),
                alias :: tag(),
                channel_ref :: reference(),
                rc_ref :: reference(),
                group :: pid(),
                stdin :: pid(),
                stdout :: pid(),
                stderr :: pid(),
                pending = #{} :: #{reference() => pending()}}).

-doc """
Starts the relay of a job for the calling process, its channel: `rc -c
Command` with the first variables Vars, from the working directory Cwd.
Answers the relay and the alias of the caller's that tags the job messages
(the module documentation). The relay is not linked to the caller; it ends
when the job has ended and its ending is sent, or at the channel's hangup or
end.
""".
-spec start(binary(), #{vars := erx_shell_script:vars(), cwd := binary()}) -> {pid(), tag()}.
start(Command, #{vars := Vars, cwd := Cwd}) when is_binary(Command) ->
    Channel = self(),
    Alias = alias(),
    {spawn(fun() -> init(Channel, Alias, Command, Vars, Cwd) end), Alias}.

init(Channel, Alias, Command, Vars, Cwd) ->
    process_flag(trap_exit, true),
    [Stdin, Stdout, Stderr] = [erx_shell_pipe:new() || _ <- [stdin, stdout, stderr]],
    Group = spawn_link(fun() -> group(Stderr) end),
    Rc = erx_shell_script:job(Command, Vars, Cwd,
                              #{0 => {pipe, Stdin}, 1 => {pipe, Stdout}, 2 => {pipe, Stderr}},
                              Group),
    %% rc ends only after the group answers its last output request, unless an
    %% exit signal ends it sooner; then the monitor reports noproc, which
    %% erx_console:shell_ending/1 takes as status 1.
    RcRef = monitor(process, Rc),
    %% rc may write before its ends are attached, since a pipe takes writes
    %% from anyone and counts its holders only to tell when a stream has
    %% ended.
    ok = erx_shell_pipe:attach(Stdin, write, self()),
    ok = erx_shell_pipe:attach(Stdin, read, Rc),
    ok = erx_shell_pipe:attach(Stdout, read, self()),
    ok = erx_shell_pipe:attach(Stdout, write, Rc),
    ok = erx_shell_pipe:attach(Stderr, read, self()),
    ok = erx_shell_pipe:attach(Stderr, write, Rc),
    Relay = #relay{job = erx_ssh_job_core:new(), alias = Alias,
                   channel_ref = monitor(process, Channel), rc_ref = RcRef, group = Group,
                   stdin = Stdin, stdout = Stdout, stderr = Stderr},
    %% A new job has both readers reading (erx_ssh_job_core:new/0).
    loop(act([{read, stdout}, {read, stderr}], Relay)).

loop(#relay{pending = Pending, alias = Alias, channel_ref = ChannelRef, rc_ref = RcRef} = Relay) ->
    receive
        {Ref, Reply} when is_map_key(Ref, Pending) ->
            loop(answered(Ref, Reply, Relay));
        {'DOWN', Ref, process, _, _} when is_map_key(Ref, Pending) ->
            loop(answered(Ref, gone, Relay));
        {'DOWN', ChannelRef, process, _, _} ->
            loop(step({channel, job_hangup}, Relay));
        {'DOWN', RcRef, process, _, Reason} ->
            loop(step({ended, status(erx_console:shell_ending(Reason))}, Relay));
        {Alias, Message} ->
            loop(step({channel, Message}, Relay));
        _Other ->
            loop(Relay)
    end.

%% A pipe's answer to an outstanding request, or `gone` when the pipe went
%% first, which a write takes as written, its bytes with nowhere to go, and a
%% read as the end of the stream.
answered(Ref, Reply, #relay{pending = Pending} = Relay) ->
    {Waiting, Pending1} = maps:take(Ref, Pending),
    Relay1 = Relay#relay{pending = Pending1},
    case {Waiting, Reply} of
        {write, _OkOrEpipe} -> step(written, Relay1);
        {{read, Stream}, {bytes, Bytes}} -> step({read, Stream, Bytes}, Relay1);
        {{read, Stream}, _EofOrGone} -> step({read, Stream, eof}, Relay1)
    end.

%% A job's status. rc ends by a signal only on its parent's exit signal
%% `interrupt`, which the relay never sends; it is read as a failure.
status({exited, Status}) -> Status;
status({signaled, _Signal}) -> 1.

step(Event, #relay{job = Job} = Relay) ->
    {Job1, Actions} = erx_ssh_job_core:step(Event, Job),
    act(Actions, Relay#relay{job = Job1}).

act(Actions, Relay) ->
    lists:foldl(fun action/2, Relay, Actions).

action({write, Bytes}, #relay{stdin = Stdin} = Relay) ->
    request(erx_shell_pipe:put_async(Stdin, Bytes), write, Relay);
action(close_input, #relay{stdin = Stdin} = Relay) ->
    ok = erx_shell_pipe:close(Stdin),
    Relay;
action({read, Stream}, Relay) ->
    Ref = erx_shell_pipe:get_bytes_async(pipe(Stream, Relay), ?ERX_TTY_LINE_DATA_MAX),
    request(Ref, {read, Stream}, Relay);
action({send, Message}, #relay{alias = Alias} = Relay) ->
    Alias ! {Alias, Message},
    Relay;
action(hangup, Relay) ->
    over(Relay, {shutdown, hangup});
action(stop, Relay) ->
    over(Relay, normal).

%% The relay's end, by its one route. It ends rc, which ends every process of
%% the job (erx_shell_script:job/5), and the pipes, which the relay made. The
%% group is killed by name: a normal end ends no linked process, and a
%% printer's function running in the group may trap exits.
over(#relay{group = Group}, Reason) ->
    exit(Group, kill),
    exit(Reason).

pipe(stdout, #relay{stdout = Stdout}) -> Stdout;
pipe(stderr, #relay{stderr = Stderr}) -> Stderr.

request(Ref, Waiting, #relay{pending = Pending} = Relay) ->
    Relay#relay{pending = Pending#{Ref => Waiting}}.

%%% The job's group

%% The group serves one request at a time, so a request waits in its mailbox
%% until those before it are written.
group(Stderr) ->
    receive
        {io_request, From, ReplyAs, Request} when is_pid(From) ->
            From ! {io_reply, ReplyAs, write(Stderr, output(Request))},
            group(Stderr);
        _Other ->
            group(Stderr)
    end.

%% Writes an output request's bytes to standard error, waiting until they have
%% entered: `ok`, or `{error, epipe}` once standard error's reader is gone.
write(Stderr, {ok, Bytes}) -> erx_shell_pipe:put(Stderr, Bytes);
write(_Stderr, {error, _} = Refused) -> Refused.

%% The bytes an output request writes, as UTF-8, or why it is refused. A
%% put_chars that names a function is taken as stock OTP's group takes it
%% (putc_request/3 of group.erl): the function runs here, in the group.
output({put_chars, Encoding, Chars}) ->
    encode(Chars, Encoding);
output({put_chars, Encoding, Module, Function, Args})
  when is_atom(Module), is_atom(Function), is_list(Args) ->
    try apply(Module, Function, Args) of
        Chars -> encode(Chars, Encoding)
    catch
        _:_ -> {error, put_chars}
    end;
output({put_chars, Chars}) ->
    encode(Chars, latin1);
output({put_chars, Module, Function, Args}) ->
    output({put_chars, latin1, Module, Function, Args});
output({requests, Requests}) when is_list(Requests) ->
    Outputs = [output(Request) || Request <- Requests],
    case [Bytes || {ok, Bytes} <- Outputs] of
        All when length(All) =:= length(Outputs) -> {ok, iolist_to_binary(All)};
        _Refused -> {error, request}
    end;
output(_InputOrOptions) ->
    {error, enotsup}.

encode(Chars, Encoding) when Encoding =:= unicode; Encoding =:= latin1 ->
    try unicode:characters_to_binary(Chars, Encoding, utf8) of
        Bytes when is_binary(Bytes) -> {ok, Bytes};
        _ErrorOrIncomplete -> {error, put_chars}
    catch
        error:badarg -> {error, put_chars}
    end;
encode(_Chars, _Encoding) ->
    {error, put_chars}.
