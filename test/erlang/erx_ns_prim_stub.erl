%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% prim_file as erx_ns's process sees it, for erx_ns_tests on stock's emulator: the
%% table read as prim_file:erx_table/0 reads it, and the NIF table's changes, each
%% reported to the process registered as erx_ns_tests and accepted, except a mount at
%% /refused, which the stub refuses as the NIF refuses a change its own table cannot take.

-module(erx_ns_prim_stub).

-export([erx_table/0, erx_ns_mount/4, erx_ns_bind/3, erx_ns_unmount/1]).

erx_table() ->
    persistent_term:get(erx_ns, [#{point => [], provider => release, root => [], rights => ro}]).

erx_ns_mount(<<"/refused">>, _Pid, _Tree, _Rights) ->
    {error, eexist};
erx_ns_mount(Point, Pid, Tree, Rights) ->
    reported({mount, Point, Pid, Tree, Rights}).

erx_ns_bind(From, To, ReadOnly) ->
    reported({bind, From, To, ReadOnly}).

erx_ns_unmount(Point) ->
    reported({unmount, Point}).

reported(Change) ->
    case whereis(erx_ns_tests) of
        undefined -> ok;
        Tests -> Tests ! {nif, Change}
    end,
    ok.
