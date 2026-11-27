%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_step).
-moduledoc """
One named step of a driver's start. A driver brings its device up as a `maybe` of
steps (open the device, create a queue, attach the interrupt line, ...), and each step
whose refusal should name it is wrapped in step/2, so the start fails with
`{error, {Step, Reason}}` naming the step that refused.

The helper is pure and lives apart from the device module, which the host tests replace
with a stand-in.
""".

-export([step/2]).

-doc """
The step's answer unchanged, or its error tagged with the step's name. The spec keeps
each step's own value type, an opaque device or queue among them, through the call.
""".
-spec step(Name, ok) -> ok when Name :: atom();
          (Name, {ok, Value}) -> {ok, Value} when Name :: atom(), Value :: term();
          (Name, {error, Reason}) -> {error, {Name, Reason}} when Name :: atom(), Reason :: term().
step(_Name, ok) -> ok;
step(_Name, {ok, Value}) -> {ok, Value};
step(Name, {error, Reason}) -> {error, {Name, Reason}}.
