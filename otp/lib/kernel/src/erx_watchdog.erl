%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% What keeps the machine's watchdog from ending the machine (docs/design-stopgap.md,
%% "The watchdog"): a process at priority max that pets it from a normal scheduler, so
%% a pet says that schedulers run and timers fire. The root never pets on its behalf.

-module(erx_watchdog).

-export([start_link/0]).
-export([init/0]).

-nifs([pet_nif/0]).
-on_load(on_load/0).

%% Shorter than any period the kernel command line can set, which counts in seconds.
-define(PET_MILLISECONDS, 500).

-spec start_link() -> {ok, pid()}.
start_link() ->
    proc_lib:start_link(?MODULE, init, []).

-spec on_load() -> ok | {error, term()}.
on_load() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

-spec init() -> no_return().
init() ->
    process_flag(priority, max),
    register(?MODULE, self()),
    proc_lib:init_ack({ok, self()}),
    loop().

loop() ->
    ok = pet_nif(),
    receive
    after ?PET_MILLISECONDS -> loop()
    end.

pet_nif() ->
    erlang:nif_error(undef).
