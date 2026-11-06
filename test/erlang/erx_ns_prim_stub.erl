%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% prim_file as erx_ns's process sees it, for erx_ns_tests on stock's emulator: the
%% table read as prim_file:erx_table/0 reads it.

-module(erx_ns_prim_stub).

-export([erx_table/0]).

erx_table() ->
    persistent_term:get(erx_ns, [#{point => [], provider => release, root => [], rights => ro}]).
