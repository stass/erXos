%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pixels).
-moduledoc """
A stand-in for the display client's pixel allocator in erx_prog_handler's
tests: each call goes to erx_prog_handler_fakes, which reports it to the
test and answers what the test set.
""".

-export([alloc/2, lend/2, unlend/1]).

alloc(Peer, Bytes) -> erx_prog_handler_fakes:alloc(Peer, Bytes).
lend(Peer, Offset) -> erx_prog_handler_fakes:lend(Peer, Offset).
unlend(Lease) -> erx_prog_handler_fakes:unlend(Lease).
