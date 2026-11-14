%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_halt).
-moduledoc """
`halt [-lpq]`: erx_cmd_reboot under the name `halt`, as FreeBSD's halt is
a link to reboot; that module documents both. The shell's namespace takes
one name from each module, so the second name is this module.
""".
-behaviour(erx_cmd).

-erx_command(halt).
-erx_usage("halt [-lpq]").

-export([run/2]).

-doc false.
run(Args, Ctx) ->
    erx_cmd_reboot:run(Args, Ctx).
