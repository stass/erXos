%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_program).
-moduledoc """
A native program of the session as a port (docs/design-runtime.md, Programs
as ports): `start/1` opens a port on the `erx_program` driver, which makes
the program's budget, group, anchor and image and maps the image from the
session's release; it then hands the driver the program's startup message,
which the driver writes into the program's channel, and starts its first
thread. The port is linked to its
caller, its owner, as every port is. When the program's image ends, the
owner gets `{Port, {exit_status, N}}` and the port closes; `N` is what
`erx_prog:status/1` reads. Closing the port first, with `port_close/1` or
by the owner's exit, kills the program.

The owner, the program's handler, writes later frames with `send/2` and
receives each frame the program writes as `{erx_channel, Port, Frame}`, as
many as the program's credit allows (docs/design-programs.md, Credit).
`stop/3` stops the program's anchor with a status of the handler's choice.

The driver makes every decision (erx_program_core.c); this module builds
the startup message with the program protocol's generated grammar
(erx_prog_grammar), writes the spec into the port's command, names what each
frame it sends gives the program's credit, and reads how each step ended.
""".

-export([start/1, send/2, stop/3]).

%% The driver's port_control commands: how the start ended, followed by the data
%% area's value; a frame to write; the first thread's start; the anchor's stop.
-define(CONTROL_STARTED, 1).
-define(CONTROL_SEND, 2).
-define(CONTROL_RUN, 3).
-define(CONTROL_STOP, 4).
%% CONTROL_SEND's reply slot for a frame that answers no request, and each
%% grant's kind (erx_program_drv.c, send_parse).
-define(NO_REPLY, 255).
-define(GRANT_CLOSED, 1).
-define(GRANT_DRAINED, 2).
-define(IS_NUMBER(N), (is_integer(N) andalso N >= 1 andalso N =< 16#ffffffff)).
%% A program's budget, in pages, when the spec names none.
-define(DEFAULT_GUARANTEE, 0).
-define(DEFAULT_CAP, 4096).
%% The data area's 64 KiB slots when the spec names none (docs/design-programs.md).
-define(DEFAULT_SLOTS, 4).
%% The data area's value the check builds the message with, before the driver gives
%% the real one: the largest capability value, whose encoding is the longest any value
%% has. The frame bound counts every capability at its longest encoding
%% (docs/design-programs.md), so the verdict depends on the spec alone, and the
%% message built with the real value is never larger than the one checked.
-define(LONGEST_CAP, 16#ffffffffffffffff).
%% What the startup message takes from the spec as it is.
-define(MESSAGE_KEYS, [ppid, pgid, argv, env, cwd, spawn, sigmask, sigignore, umask]).

-doc """
Starts the program `Spec` names and returns its port, or `{error, Reason}`.

`Spec` holds `image`, the program's path in the session's release
(`<<"bin/exit42">>`); `pid`, `ppid` and `pgid`, its process id, its
parent's and its process group's; `argv` and `env`, lists of binaries, each
`env` entry `<<"NAME=value">>`; `cwd`, its absolute working directory;
`spawn`, whether a spawn started it; `sigmask` and `sigignore`, lists of
signal names (`sigterm`); and `umask`. It may hold `guarantee` and `cap`,
its budget in pages, `slots`, its data area's 64 KiB slots (4 by default),
and `fds`, its descriptors, of which only `[]`, the default, is supported.
These make the startup message the program receives before `main`
(docs/design-programs.md, The startup message).

`Reason` is `e2big` for a message whose strings are too large, as the
grammar of the program protocol bounds them, and `einval` for any other
value the message refuses, a pid outside 2..2^31-1 among them; otherwise it
is the kernel status, e-prefixed, of the step that refused the program:
`einval` for an image the session's release does not hold or a `guarantee`
above the `cap`, `enotsup` where the backend cannot run programs. A spec of
the wrong shape is `badarg`, as is an image holding a 0 byte, a `guarantee`,
`cap` or `slots` that is not a natural number, or `fds` other than `[]`; a
`slots` outside 1..16 is `einval`, as the message refuses it.
""".
-spec start(#{image := binary(), pid := non_neg_integer(), ppid := pos_integer(),
              pgid := pos_integer(), argv := [binary()], env := [binary()], cwd := binary(),
              spawn := boolean(), sigmask := [atom()], sigignore := [atom()],
              umask := non_neg_integer(), guarantee => non_neg_integer(),
              cap => non_neg_integer(), slots => pos_integer(), fds => []}) ->
          port() | {error, atom()}.
start(#{image := Image, pid := Pid} = Spec) when is_binary(Image), is_integer(Pid), Pid >= 0 ->
    %% The command is a C string, which a 0 byte would cut short.
    has_nul(Image) andalso erlang:error(badarg, [Spec]),
    Guarantee = maps:get(guarantee, Spec, ?DEFAULT_GUARANTEE),
    Cap = maps:get(cap, Spec, ?DEFAULT_CAP),
    Slots = maps:get(slots, Spec, ?DEFAULT_SLOTS),
    case natural(Guarantee) andalso natural(Cap) andalso natural(Slots) andalso
         maps:get(fds, Spec, []) =:= [] of
        true -> ok;
        false -> erlang:error(badarg, [Spec])
    end,
    %% The message is checked whole before anything is made.
    case frame(Spec, ?LONGEST_CAP, Slots) of
        {ok, _} -> open(Spec, Image, Pid, Guarantee, Cap, Slots);
        {error, _} = Refused -> Refused
    end;
start(Spec) ->
    erlang:error(badarg, [Spec]).

%% The driver's command is "erx_program Pid Guarantee Cap Slots Image", the image
%% last since it is the one field that may hold a space. A port whose start failed
%% is open with nothing made, and is closed here. A data area's value of cap_null,
%% which the grammar refuses, closes the port as a refusal of the driver's does,
%% which kills the program.
open(Spec, Image, Pid, Guarantee, Cap, Slots) ->
    Command = iolist_to_binary([<<"erx_program ">>, integer_to_binary(Pid), $\s,
                                integer_to_binary(Guarantee), $\s, integer_to_binary(Cap), $\s,
                                integer_to_binary(Slots), $\s, Image]),
    Port = open_port({spawn_driver, Command}, [binary]),
    case port_control(Port, ?CONTROL_STARTED, []) of
        <<"ok", Data:64>> ->
            case frame(Spec, Data, Slots) of
                {ok, Frame} -> run(Port, Frame);
                {error, _} = Refused ->
                    port_close(Port),
                    Refused
            end;
        Refused ->
            refused(Port, Refused)
    end.

%% Writes the startup message with the data area's value, then starts the first
%% thread. The message is the channel's first frame, so the driver is never busy
%% with an earlier one.
run(Port, Frame) ->
    case send(Port, Frame) of
        ok ->
            case port_control(Port, ?CONTROL_RUN, []) of
                <<"ok">> -> Port;
                Refused -> refused(Port, Refused)
            end;
        {error, _} = Refused ->
            port_close(Port),
            Refused
    end.

-doc """
Writes `Frame`, a term of the program protocol, into the program's channel,
and never waits (docs/design-runtime.md, Programs as ports). `ok` once the
driver has taken the frame, which it writes as the program frees room; `busy`
while it still holds part of an earlier frame, when the caller keeps `Frame`
owed, writes nothing newer and sends it again at `{erx_channel_room, Port}`.
`{error, einval}` when the program has ended, the frame is larger than the
protocol's bound, a reply's slot holds no request, or the notices the frame
would make due pass their bound; `{error, enomem}` when the session has no
memory for it.

The frame's bytes and what it gives the program's credit come from the same
term (`grants/1`), so they cannot disagree. A term whose grants it cannot read,
one of no frame to the program or one carrying a descriptor or report of a
kind the protocol lacks or a pipe number outside 1..2^32-1, raises
`function_clause`: the handler builds every frame with the protocol's grammar,
so such a term is the handler's bug. The program checks the rest of the
frame's form.
""".
-spec send(port(), term()) -> ok | busy | {error, atom()}.
send(Port, Frame) ->
    {Reply, Grants} = grants(Frame),
    Payload = [Reply, <<(length(Grants)):32>>, [grant(G) || G <- Grants], term_to_binary(Frame)],
    case port_control(Port, ?CONTROL_SEND, Payload) of
        <<"ok">> -> ok;
        <<"busy">> -> busy;
        <<$e, _/binary>> = Status -> {error, binary_to_atom(Status)}
    end.

-doc """
Stops the program's anchor, and with it the program, with `Status`, which its
end reports as `{Port, {exit_status, Status}}` (docs/design-runtime.md,
Signals): `ok`, or `{error, einval}` when the program has already ended. The
handler stops a program whose frame its grammar refuses with `256 + SIGSYS`.
""".
-spec stop(port(), anchor, 0..16#ffffffff) -> ok | {error, atom()}.
stop(Port, anchor, Status) when is_integer(Status), Status >= 0, Status =< 16#ffffffff ->
    case port_control(Port, ?CONTROL_STOP, <<Status:64>>) of
        <<"ok">> -> ok;
        <<$e, _/binary>> = Refused -> {error, binary_to_atom(Refused)}
    end.

%% What a frame gives the program's credit (docs/design-programs.md, Credit): the
%% reply slot it answers, ?NO_REPLY for none, and the notices it makes due, a
%% {closed, Pipe, End} for each pipe end it gives the program and a {drained,
%% Pipe, End, Writer} for each writer it names gone to a read end. Each kind of
%% descriptor a startup message carries and each kind of report has a clause of
%% its own, which grants nothing where the kind gives no end and names no writer
%% gone, and nothing falls through: a kind the protocol (abi/protocols/prog.txt)
%% gains fails here until it has its rule, and test/host/erx_program_grants_test.rb
%% walks the protocol for every kind's. A term of no frame to the program fails
%% here too.
grants({erx_start, _, #{fds := Fds}}) ->
    {?NO_REPLY, lists:flatmap(fun({_Fd, Descriptor}) -> descriptor_grants(Descriptor) end, Fds)};
grants({erx_prog, _, Report}) ->
    {?NO_REPLY, report_grants(Report)};
grants({erx_prog, _, Slot, _Reply}) when is_integer(Slot), Slot >= 0, Slot < ?NO_REPLY ->
    {Slot, []}.

%% A descriptor's grants: each pipe end it gives, and each writer of a read end
%% it names gone.
descriptor_grants({pipe, write, {Pipe, End}, _WriteEnd}) ->
    [{closed, Pipe, End}];
descriptor_grants({pipe, read, {Pipe, End}, ReadEnd}) ->
    [{closed, Pipe, End} | gone_writers(Pipe, End, ReadEnd)];
descriptor_grants({socketpair, {RPipe, REnd}, ReadEnd, {WPipe, WEnd}, _WriteEnd}) ->
    [{closed, RPipe, REnd}, {closed, WPipe, WEnd} | gone_writers(RPipe, REnd, ReadEnd)];
descriptor_grants({Kind, _Open, _Access}) when Kind =:= file; Kind =:= tty ->
    [];
descriptor_grants({Kind, _Open}) when Kind =:= dir; Kind =:= socket ->
    [];
descriptor_grants({dup, _Target}) ->
    [];
descriptor_grants(null) ->
    [].

%% A report's grants: a writer's join marked gone, and a writer's gone, name the
%% writer gone to the read end.
report_grants({pipe_writer, Pipe, End, Writer, _Ring, _RPage, _Size, _Doorbell, gone}) ->
    [{drained, Pipe, End, Writer}];
report_grants({pipe_writer, _Pipe, _End, _Writer, _Ring, _RPage, _Size, _Doorbell, open}) ->
    [];
report_grants({pipe_writer_gone, Pipe, End, Writer}) ->
    [{drained, Pipe, End, Writer}];
report_grants({pipe_reader, _Pipe, _End, _Reader, _Lock, _State}) ->
    [];
report_grants({pipe_reader_gone, _Pipe, _End, _Reader}) ->
    [];
report_grants({pipe_lost, _Pipe, _End}) ->
    [];
report_grants(pipe_server_lost) ->
    [].

gone_writers(Pipe, End, #{writers := Writers}) ->
    [{drained, Pipe, End, Writer} || {Writer, _Ring, _RPage, _Size, gone} <- Writers].

%% A grant as the driver reads it. A number outside 1..2^32-1, which the grammar
%% refuses, fails here rather than be cut to 32 bits.
grant({closed, Pipe, End}) when ?IS_NUMBER(Pipe), ?IS_NUMBER(End) ->
    <<?GRANT_CLOSED, Pipe:32, End:32, 0:32>>;
grant({drained, Pipe, End, Writer}) when ?IS_NUMBER(Pipe), ?IS_NUMBER(End), ?IS_NUMBER(Writer) ->
    <<?GRANT_DRAINED, Pipe:32, End:32, Writer:32>>.

%% A refusal is "e" and the status's name, so the whole answer is the status's
%% atom: einval, eagain, enomem.
refused(Port, <<$e, _/binary>> = Status) ->
    port_close(Port),
    {error, binary_to_atom(Status)}.

%% The startup message's value, with the data area's value Data and the pid as
%% the spec gives it; every other key the message needs comes from the spec, and
%% a missing one is the builder's refusal.
message(#{pid := Pid} = Spec, Data, Slots) ->
    maps:merge(maps:with(?MESSAGE_KEYS, Spec),
               #{pid => Pid, data_area => {Data, Slots}, fds => []}).

%% The startup message's frame with the data area's value Data, or its refusal's
%% status.
frame(Spec, Data, Slots) ->
    case erx_prog_grammar:build_start(message(Spec, Data, Slots)) of
        {ok, _} = Built -> Built;
        {error, Refusal} -> {error, refusal(Refusal)}
    end.

%% E2BIG for every refusal that the strings' size causes (docs/design-abi.md,
%% Program protocol), EINVAL for the rest.
refusal({size, _}) -> e2big;
refusal({length, Kind}) when Kind =:= arg; Kind =:= env_var; Kind =:= argv; Kind =:= env -> e2big;
refusal({total, args}) -> e2big;
refusal(_) -> einval.

natural(N) -> is_integer(N) andalso N >= 0.

%% Whether the image holds a 0 byte.
has_nul(<<0, _/binary>>) -> true;
has_nul(<<_, Rest/binary>>) -> has_nul(Rest);
has_nul(<<>>) -> false.
