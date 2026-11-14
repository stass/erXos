%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pipe_nif).
-moduledoc """
A stand-in for the pipe NIF in erx_prog_handler's tests, for the calls a
handler makes: each goes to erx_pipe_fake_nif, the pipe server's stand-in,
so the handler's holder entry and hand-offs are the ones the test's pipe
server sees.
""".

-export([program_holder/1, holder_drop/1, hand_drop/1]).

program_holder(Program) -> erx_pipe_fake_nif:program_holder(Program).
holder_drop(Program) -> erx_pipe_fake_nif:holder_drop(Program).
hand_drop(Number) -> erx_pipe_fake_nif:hand_drop(Number).
