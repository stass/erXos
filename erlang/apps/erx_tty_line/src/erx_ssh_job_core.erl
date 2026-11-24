%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_job_core).
-moduledoc """
The job relay's decisions, pure (docs/design-ssh.md, "Sessions, ttys and
shells"): how a session relays a job, rc run on three message pipes for an
SSH channel with no pseudo-terminal, to that channel with the job
messages, and what a channel accepts of them.

The relay's side, step/2. The relay holds standard input's writing end and
the reading ends of standard output and error. Its events are the
channel's messages, each untrusted, the input writer's `written`, a
reader's `{read, Stream, Bytes | eof}` and the job's `{ended, Status}`;
step/2 answers the relay's next state and the actions to carry out, in
order:

* input: a `job_input` is checked as the design's table has it, a binary
  of at most tty_line_data_max bytes with no other `job_input` unanswered
  and no `job_eof` before it, and is written (`{write, Bytes}`); once
  written, the channel hears `job_written`. A `job_input` that fails the
  check ends the job as `job_hangup` does. `job_eof` closes standard
  input's writing end (`close_input`) once what came before it is written,
  and a second `job_eof` changes nothing.
* output: a reader's bytes go to the channel as `{job_output, Stream,
  Bytes}` when no other `job_output` is unanswered, and wait otherwise,
  their reader not reading until they are sent. Since the reader whose
  piece is unanswered is not reading either, at most one piece waits.
  `job_sent` answers the unanswered piece, the waiting one goes next, and
  the reader whose piece was answered reads again (`{read, Stream}`). A
  `job_sent` with none unanswered is a late repeat and changes nothing.
* the ending: `{exited, Status}` goes once the job has ended, both readers
  have met the end of their streams and nothing waits or is unanswered, so
  it arrives after every byte of output; then `stop`.
* `job_hangup` ends the job at once: `hangup`, the relay closing every end
  and ending the job's programs. Any other message changes nothing.

After `stop` or `hangup` the relay is over and every event changes
nothing, so nothing a channel sends later reaches the job.

The channel's side, channel_step/2. Its events are the client's data and
end of input, the job's start, and each job message heard from the line,
untrusted; channel_step/2 answers the channel's next state and the actions
to carry out, in order:

* input: the client's data goes to the job as `{job_input, Piece}`
  pieces of at most tty_line_data_max bytes, in order, one unanswered at
  a time; each waits in a queue until the one before it is answered by
  `job_written`, and the client's window then opens by its size
  (`{adjust, Size}`), so what the channel holds of the client's input is
  bounded by the window it gave. Data before the job starts or after the
  client's end of input goes nowhere, and the window opens by it at once.
* the end of input: the client's end of input, whenever it comes, goes as
  `job_eof` once the job has started and every piece is answered.
* output and the ending: a `{job_output, Stream, Bytes}` is checked as the
  design's table has it and becomes `{output, Stream, Bytes}`, data the
  channel sends, then `{send, job_sent}`; an `{exited, Status}` becomes
  `{ended, Status}`; and a message that fails its check, a `job_written`
  with no piece unanswered among them, `close`. A job_output is sent before
  the next message is heard, so none is ever unanswered when one arrives.
""".

-export([new/0, step/2, new_channel/0, channel_step/2]).
-export_type([job/0, event/0, action/0, stream/0,
              channel/0, channel_event/0, channel_action/0]).

-include("generated/erx_abi.hrl").

-type stream() :: stdout | stderr.

%% phase: running until stop or hangup; input: whether a job_input is being
%% written; eof: whether the channel has sent job_eof, and whether standard input
%% is closed; sent: the stream of the one unanswered job_output; waiting: the one
%% reader's piece held until it can go; open: the streams whose readers have not
%% met their end; status: the job's exit status once it has ended.
-opaque job() :: #{phase := running | over,
                   input := idle | writing,
                   eof := none | pending | closed,
                   sent := none | stream(),
                   waiting := none | {stream(), binary()},
                   open := [stream()],
                   status := running | 0..255}.

-type event() :: {channel, term()}
               | written
               | {read, stream(), binary() | eof}
               | {ended, 0..255}.

-type action() :: {write, binary()}
                | close_input
                | {send, job_written
                       | {job_output, stream(), binary()}
                       | {exited, 0..255}}
                | {read, stream()}
                | hangup
                | stop.

%% job: whether the channel's job has started; pieces: the client's data not yet
%% sent, in order; unanswered: the size of the one job_input not yet answered;
%% eof: the client's end of input, none until it comes, pending until it goes as
%% job_eof, then sent.
-opaque channel() :: #{job := waiting | started,
                       pieces := queue:queue(binary()),
                       unanswered := none | 1..?ERX_TTY_LINE_DATA_MAX,
                       eof := none | pending | sent}.

-type channel_event() :: {data, binary()} | eof | started | {heard, term()}.

-type channel_action() :: {send, {job_input, binary()} | job_eof | job_sent}
                        | {adjust, pos_integer()}
                        | {output, stream(), binary()}
                        | {ended, 0..255}
                        | close.

-doc "A job just started: no input, both readers reading, still running.".
-spec new() -> job().
new() ->
    #{phase => running, input => idle, eof => none, sent => none,
      waiting => none, open => [stdout, stderr], status => running}.

-doc """
The relay's next state and actions, in order, for Event (see the module
documentation). A reader's bytes are at most tty_line_data_max, as the
relay reads them.
""".
-spec step(event(), job()) -> {job(), [action()]}.
step(_Event, #{phase := over} = Job) ->
    {Job, []};
step({channel, {job_input, Bytes}}, #{input := idle, eof := none} = Job)
  when is_binary(Bytes), byte_size(Bytes) =< ?ERX_TTY_LINE_DATA_MAX ->
    {Job#{input := writing}, [{write, Bytes}]};
step({channel, {job_input, _}}, Job) ->
    over(Job, [hangup]);
step({channel, job_eof}, #{eof := none, input := writing} = Job) ->
    {Job#{eof := pending}, []};
step({channel, job_eof}, #{eof := none} = Job) ->
    {Job#{eof := closed}, [close_input]};
step({channel, job_sent}, #{sent := Stream} = Job) when Stream =/= none ->
    next(Job#{sent := none}, [{read, Stream}]);
step({channel, job_hangup}, Job) ->
    over(Job, [hangup]);
step({channel, _Other}, Job) ->
    {Job, []};
step(written, #{input := writing, eof := pending} = Job) ->
    {Job#{input := idle, eof := closed}, [{send, job_written}, close_input]};
step(written, #{input := writing} = Job) ->
    {Job#{input := idle}, [{send, job_written}]};
step({read, Stream, eof}, #{open := Open} = Job) ->
    finish(Job#{open := lists:delete(Stream, Open)}, []);
step({read, Stream, Bytes}, #{waiting := none} = Job) when is_binary(Bytes) ->
    next(Job#{waiting := {Stream, Bytes}}, []);
step({ended, Status}, #{status := running} = Job) ->
    finish(Job#{status := Status}, []).

-doc "A channel whose job has not started: nothing queued, no end of input.".
-spec new_channel() -> channel().
new_channel() ->
    #{job => waiting, pieces => queue:new(), unanswered => none, eof => none}.

-doc """
The channel's next state and actions, in order, for Event (see the module
documentation).
""".
-spec channel_step(channel_event(), channel()) -> {channel(), [channel_action()]}.
channel_step({data, Bytes}, #{job := started, eof := none, pieces := Pieces} = Channel) ->
    feed(Channel#{pieces := lists:foldl(fun queue:in/2, Pieces, pieces(Bytes))}, []);
channel_step({data, Bytes}, Channel) ->
    {Channel, adjust(byte_size(Bytes))};
channel_step(eof, #{eof := none} = Channel) ->
    feed(Channel#{eof := pending}, []);
channel_step(eof, Channel) ->
    {Channel, []};
channel_step(started, Channel) ->
    feed(Channel#{job := started}, []);
channel_step({heard, job_written}, #{unanswered := Size} = Channel) when Size =/= none ->
    feed(Channel#{unanswered := none}, adjust(Size));
channel_step({heard, {job_output, Stream, Bytes}}, Channel)
  when (Stream =:= stdout orelse Stream =:= stderr), is_binary(Bytes),
       byte_size(Bytes) =< ?ERX_TTY_LINE_DATA_MAX ->
    {Channel, [{output, Stream, Bytes}, {send, job_sent}]};
channel_step({heard, {exited, Status}}, Channel)
  when is_integer(Status), Status >= 0, Status =< 255 ->
    {Channel, [{ended, Status}]};
channel_step({heard, _Message}, Channel) ->
    {Channel, [close]}.

%% With the job started and no piece unanswered, the next piece goes, or, with
%% none left, the client's end of input.
feed(#{job := started, unanswered := none, pieces := Pieces, eof := Eof} = Channel, Actions) ->
    case {queue:out(Pieces), Eof} of
        {{{value, Piece}, Rest}, _} ->
            {Channel#{pieces := Rest, unanswered := byte_size(Piece)},
             Actions ++ [{send, {job_input, Piece}}]};
        {{empty, _}, pending} ->
            {Channel#{eof := sent}, Actions ++ [{send, job_eof}]};
        {{empty, _}, _NoneOrSent} ->
            {Channel, Actions}
    end;
feed(Channel, Actions) ->
    {Channel, Actions}.

%% Data in pieces of at most tty_line_data_max bytes, none empty.
pieces(Data) when byte_size(Data) =< ?ERX_TTY_LINE_DATA_MAX -> [Data || Data =/= <<>>];
pieces(<<Piece:?ERX_TTY_LINE_DATA_MAX/binary, Rest/binary>>) -> [Piece | pieces(Rest)].

%% The window opens by data that goes nowhere, if there is any.
adjust(0) -> [];
adjust(Size) -> [{adjust, Size}].

%% With no job_output unanswered, the waiting piece goes.
next(#{sent := none, waiting := {Stream, Bytes}} = Job, Actions) ->
    {Job#{sent := Stream, waiting := none},
     Actions ++ [{send, {job_output, Stream, Bytes}}]};
next(Job, Actions) ->
    finish(Job, Actions).

%% The ending once the job has ended, both streams are at their end and
%% nothing waits or is unanswered.
finish(#{status := Status, open := [], sent := none, waiting := none} = Job,
       Actions) when is_integer(Status) ->
    over(Job, Actions ++ [{send, {exited, Status}}, stop]);
finish(Job, Actions) ->
    {Job, Actions}.

over(Job, Actions) ->
    {Job#{phase := over}, Actions}.
