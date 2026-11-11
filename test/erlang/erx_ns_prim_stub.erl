%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% prim_file as erx_ns's process sees it, for erx_ns_tests on stock's emulator: the
%% mounts read as prim_file:erx_mounts/0 reads them.

-module(erx_ns_prim_stub).

-export([erx_mounts/0]).

erx_mounts() ->
    persistent_term:get(erx_ns, [#{point => [], provider => release, root => [], rights => ro}]).
