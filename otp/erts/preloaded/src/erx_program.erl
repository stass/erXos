%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_program).
-moduledoc """
A native program of the session as a port (docs/design-runtime.md, Programs
as ports): `start/1` opens a port on the `erx_program` driver, which makes
the program's budget, group, anchor and image, maps the image from the
session's release and starts its first thread. The port is linked to its
caller, its owner, as every port is. When the program's image ends, the
owner gets `{Port, {exit_status, N}}` and the port closes; `N` is what
`erx_prog:status/1` reads. Closing the port first, with `port_close/1` or
by the owner's exit, kills the program.

The driver makes every decision (erx_program_core.c); this module only
writes the spec into the port's command and reads how the start ended.
""".

-export([start/1]).

%% The driver's port_control command that answers how the start ended.
-define(CONTROL_STARTED, 1).
%% A program's budget, in pages, when the spec names none.
-define(DEFAULT_GUARANTEE, 0).
-define(DEFAULT_CAP, 4096).

-doc """
Starts the program `Spec` names and returns its port, or `{error, Reason}`
with the kernel status, e-prefixed, of the step that refused it: `einval`
for an image the session's release does not hold or a malformed spec value,
`erange` for a pid outside 2..2^31-1, `enotsup` where the backend cannot
run programs. `Spec` holds `image`, the program's path in the session's
release (`<<"bin/exit42">>`), `pid`, its process id, and optionally
`guarantee` and `cap`, its budget in pages. A spec of the wrong shape is
`badarg`, as is an image holding a 0 byte, a pid of 2^63 or more, or a
`guarantee` or `cap` of 2^64 or more, which the driver's command cannot carry.
""".
-spec start(#{image := binary(), pid := non_neg_integer(),
              guarantee => non_neg_integer(), cap => non_neg_integer()}) ->
          port() | {error, atom()}.
start(#{image := Image, pid := Pid} = Spec) when is_binary(Image), is_integer(Pid), Pid >= 0 ->
    %% The command is a C string, which a 0 byte would cut short.
    has_nul(Image) andalso erlang:error(badarg, [Spec]),
    case {maps:get(guarantee, Spec, ?DEFAULT_GUARANTEE), maps:get(cap, Spec, ?DEFAULT_CAP)} of
        {Guarantee, Cap} when is_integer(Guarantee), Guarantee >= 0, is_integer(Cap), Cap >= 0 ->
            open(Image, Pid, Guarantee, Cap);
        _ ->
            erlang:error(badarg, [Spec])
    end;
start(Spec) ->
    erlang:error(badarg, [Spec]).

%% The driver's command is "erx_program Pid Guarantee Cap Image", the image last
%% since it is the one field that may hold a space; a port whose start failed
%% is open with nothing made, and is closed here.
open(Image, Pid, Guarantee, Cap) ->
    Command = iolist_to_binary([<<"erx_program ">>, integer_to_binary(Pid), $\s,
                                integer_to_binary(Guarantee), $\s, integer_to_binary(Cap), $\s,
                                Image]),
    Port = open_port({spawn_driver, Command}, [binary]),
    case port_control(Port, ?CONTROL_STARTED, []) of
        <<"ok">> ->
            Port;
        Name ->
            port_close(Port),
            {error, binary_to_atom(Name)}
    end.

%% Whether the image holds a 0 byte; a preloaded module calls no stdlib.
has_nul(<<0, _/binary>>) -> true;
has_nul(<<_, Rest/binary>>) -> has_nul(Rest);
has_nul(<<>>) -> false.
