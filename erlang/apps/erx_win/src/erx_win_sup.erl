%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_win_sup).
-moduledoc """
The supervisor of `erx_win` in a client domain (docs/design-display.md,
"The pixel area", The allocator is not restarted over an area). Its
children are the toolkit's supervisor erx_ui_sup and the allocator
erx_pixels, which is temporary and significant, so it is never
restarted: its end, however it comes, shuts the supervisor down, which ends
the permanent application and the domain with it. A second allocator over
the same areas would hand out ranges that programs still map; the domain's
next start has new connections and new, zeroed areas instead.
""".
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Pixels = #{id => erx_pixels, start => {erx_pixels, start_link, []},
               restart => temporary, significant => true, shutdown => 5000, type => worker,
               modules => [erx_pixels]},
    Ui = #{id => erx_ui_sup, start => {erx_ui_sup, start_link, []},
           restart => permanent, shutdown => infinity, type => supervisor,
           modules => [erx_ui_sup]},
    {ok, {#{strategy => one_for_one, auto_shutdown => any_significant}, [Pixels, Ui]}}.
