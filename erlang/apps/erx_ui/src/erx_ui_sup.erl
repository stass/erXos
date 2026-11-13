%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_sup).
-behaviour(supervisor).
-moduledoc """
The toolkit's supervisor (docs/design-display.md, "The widget server"):
erx_ui:open/1 starts each widget server, erx_ui_server, under it. A server
is temporary: a UI that ends is over, and its opener, told by `ui_down`
or the monitor's `'DOWN'`, opens another if it wants one.
""".

-export([start_link/0, start_server/1, init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc "Starts a widget server; its spec as erx_ui_server:start_link/1 takes it.".
-spec start_server(erx_ui_server:spec()) -> supervisor:startchild_ret().
start_server(Spec) ->
    supervisor:start_child(?MODULE, [Spec]).

init([]) ->
    Server = #{id => erx_ui_server, start => {erx_ui_server, start_link, []},
               restart => temporary, shutdown => 5000, type => worker,
               modules => [erx_ui_server]},
    {ok, {#{strategy => simple_one_for_one}, [Server]}}.
