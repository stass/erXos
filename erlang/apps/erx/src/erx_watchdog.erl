%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% What keeps the machine's watchdog from ending the machine (docs/design-stopgap.md,
%% "The watchdog"): a process at priority max that pets it from a normal scheduler, so
%% a pet says that schedulers run and timers fire. The root never pets on its behalf.
%% Only the system domain holds the machine's watchdog, so in any other domain
%% kernel_sup's child is ignored.

-module(erx_watchdog).
-moduledoc """
Pets the machine's watchdog every half second from a normal scheduler, so a pet
says that schedulers run and timers fire. The process is registered as
`erx_watchdog` and ignores every message sent to it.
""".

-export([start_link/0]).
-export([init/0]).

-nifs([held_nif/0, pet_nif/0]).
-on_load(on_load/0).

%% Shorter than any period the kernel command line can set, which counts in seconds.
-define(PET_MILLISECONDS, 500).

-doc """
Start the watchdog process, registered as `erx_watchdog`, and return once it runs;
`ignore` in a domain that does not hold the machine's watchdog.
""".
-spec start_link() -> {ok, pid()} | ignore.
start_link() ->
    case held_nif() of
        true -> proc_lib:start_link(?MODULE, init, []);
        false -> ignore
    end.

-spec on_load() -> ok | {error, term()}.
on_load() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

-doc false.
-spec init() -> no_return().
init() ->
    process_flag(priority, max),
    register(?MODULE, self()),
    proc_lib:init_ack({ok, self()}),
    loop().

loop() ->
    ok = pet_nif(),
    wait_until(erlang:monotonic_time(millisecond) + ?PET_MILLISECONDS).

%% A message to the registered name is discarded, so a stray sender cannot grow the
%% mailbox of a process that never otherwise reads it, and cannot bring a pet earlier.
wait_until(Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        _Stray -> wait_until(Deadline)
    after Remaining -> loop()
    end.

held_nif() ->
    erlang:nif_error(undef).

pet_nif() ->
    erlang:nif_error(undef).
