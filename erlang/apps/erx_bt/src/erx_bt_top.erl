%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_top).
-moduledoc """
The Bluetooth application and its top supervisor (docs/design-bluetooth.md, "The Bluetooth
domain" and "Concurrency"). The release's boot script starts it before init's ready
report, and it starts only the domain's two mints, which must name themselves before that
report: of `ble`, `erx_ble_facet`, and of the control tree `bluetooth`, `erx_fs_mint`
registered as `erx_bt_tree_mint` (erx_bt_fs:start_mint/0), whose grants wait for the
window process that starts with the stack. The domain row's `-eval`,
`ok=erx_bt_top:start_stack()`, which init runs once it holds the ready answer's facets,
mounts each facet the domain holds that has
a place in the namespace (erx_ns:mount_facets/1), the `line` grant at `/line` among them,
and starts the rest of the stack, `erx_bt_sup`, below this supervisor; its controller
group opens `/line/data` and `/line/ctl`.

The supervisor is one_for_all with intensity 0: it restarts nothing. Either mint's end,
or `erx_bt_sup`'s, ends it, so the permanent application stops and the domain with it,
and the domain service's restart, which mints every grant anew, is the recovery. The
facets and grants are not its children: each `ble` facet is a process its mint started,
and each grant of the tree a child of the `erx_fs_grants` its mint links to itself; each
ends with its mint.
""".
-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1]).
-export([start_stack/0]).
-export([start_link/0, init/1]).

-doc "The application's start: the supervisor and the two mints below it.".
start(_Type, _Args) ->
    start_link().

stop(_State) ->
    ok.

-doc "Starts the supervisor, registered under its module's name, with the two mints below it.".
-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc """
Mounts the domain's facets and starts `erx_bt_sup` below the supervisor, for the domain
row's `-eval`; any other answer than `ok` fails the eval and so the domain's boot.
""".
-spec start_stack() -> ok.
start_stack() ->
    ok = erx_ns:mount_facets(lists:usort(erx:granted() ++ maps:keys(erx:caps()))),
    {ok, _Stack} = supervisor:start_child(?MODULE, #{id => erx_bt_sup, start => {erx_bt_sup, start_link, []},
                                                      type => supervisor}),
    ok.

init([]) ->
    {ok, {#{strategy => one_for_all, intensity => 0, period => 1},
          [#{id => erx_ble_facet, start => {erx_ble_facet, start_link, []}},
           #{id => erx_bt_tree_mint, start => {erx_bt_fs, start_mint, []}}]}}.
