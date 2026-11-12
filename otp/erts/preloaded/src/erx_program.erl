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

The driver makes every decision (erx_program_core.c); this module builds
the startup message with the program protocol's generated grammar
(erx_prog_grammar), writes the spec into the port's command and reads how
each step ended.
""".

-export([start/1]).

%% The driver's port_control commands: how the start ended, followed by the data
%% area's value; the startup message to write; the first thread's start.
-define(CONTROL_STARTED, 1).
-define(CONTROL_SEND, 2).
-define(CONTROL_RUN, 3).
%% A program's budget, in pages, when the spec names none.
-define(DEFAULT_GUARANTEE, 0).
-define(DEFAULT_CAP, 4096).
%% The data area's 64 KiB slots when the spec names none (docs/design-programs.md).
-define(DEFAULT_SLOTS, 4).
%% The largest encoding of a capability value: the builder's first check bounds the
%% message's size with it, before the driver gives the data area's real value.
-define(LARGEST_CAP, 16#ffffffffffffffff).
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
    case erx_prog_grammar:build_start(message(Spec, ?LARGEST_CAP, Slots)) of
        {ok, _} -> open(Spec, Image, Pid, Guarantee, Cap, Slots);
        {error, Refusal} -> {error, refusal(Refusal)}
    end;
start(Spec) ->
    erlang:error(badarg, [Spec]).

%% The driver's command is "erx_program Pid Guarantee Cap Slots Image", the image
%% last since it is the one field that may hold a space; a port whose start failed
%% is open with nothing made, and is closed here, as is one whose message or run
%% the driver refused, which kills the program.
open(Spec, Image, Pid, Guarantee, Cap, Slots) ->
    Command = iolist_to_binary([<<"erx_program ">>, integer_to_binary(Pid), $\s,
                                integer_to_binary(Guarantee), $\s, integer_to_binary(Cap), $\s,
                                integer_to_binary(Slots), $\s, Image]),
    Port = open_port({spawn_driver, Command}, [binary]),
    case port_control(Port, ?CONTROL_STARTED, []) of
        <<"ok", Data:64>> ->
            run(Port, message(Spec, Data, Slots));
        Refused ->
            refused(Port, Refused)
    end.

%% Writes the startup message with the data area's value, then starts the first
%% thread. The message was checked with the largest value, so it is within its bounds.
run(Port, Message) ->
    {ok, Frame} = erx_prog_grammar:build_start(Message),
    case port_control(Port, ?CONTROL_SEND, term_to_binary(Frame)) of
        <<"ok">> ->
            case port_control(Port, ?CONTROL_RUN, []) of
                <<"ok">> -> Port;
                Refused -> refused(Port, Refused)
            end;
        Refused ->
            refused(Port, Refused)
    end.

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
