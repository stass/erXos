%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_reboot).
-moduledoc """
`reboot [-lpq]` and `halt [-lpq]`: end the machine, as FreeBSD's
reboot(8) and halt(8) do (sbin/reboot/reboot.c), one program under two
names. `reboot` resets the machine and `halt` powers it off; `halt` is
erx_cmd_halt, which runs this module as FreeBSD's link runs reboot.c, and
the name the command ran under picks its end.

The request is the end alone (docs/design-system.md, "Shutting down"):
`-p` makes `reboot`'s end a power-off, as FreeBSD's does, and is plain
`halt` for `halt`. `-q` and `-l` are accepted and ask for the same end,
since the design's request has no orderly or immediate form and its log
line is written for every end. This command writes that line, `rebooted
by root` or `powered off by root` at `critical`, before it asks init to
stop (TODO.md, the ordered end).

`halt` powers the machine off where FreeBSD's halts it without turning
it off: erXos has no end that halts without powering off. A board that
cannot turn itself off stays halted in its firmware.

Left out: `-c` (power cycle), `-d` (dump), `-k` (the next boot's kernel),
`-r` (reroot), `-n` and `-N` (sync), and the nextboot flags (`-D`, `-e`,
`-f`, `-o`, `-a`). erXos has no power cycle and no kernel dump on demand,
boots one image whose slot the update service chooses rather than a
kernel the command names, has no root file system to reroot, and has no
buffer cache for the command to sync. Each is a usage error.

Authority. Only the system domain's runtime ends the machine
(may_end/1). In any other domain's runtime both commands refuse as
FreeBSD's refuses a user who is not root, `reboot: Operation not
permitted`, after checking the flags: a session's request for the end
is not built (TODO.md, the ordered end), and may_end/1 is the rule it
changes.

The decisions are pure, parse/2 and may_end/1, and run/2 does the
effects.
""".
-behaviour(erx_cmd).

-erx_command(reboot).
-erx_usage("reboot [-lpq]").

-export([run/2]).
-export([parse/2, may_end/1]).
-export_type(['end'/0]).

-doc "The machine's end a command asks for: a reset or a power-off.".
-type 'end'() :: reset | off.

-doc false.
run(Args, #{name := Name}) ->
    case parse(Name, Args) of
        {ok, End} ->
            act(may_end(runtime()), End);
        {error, usage} = Usage ->
            Usage
    end.

-doc """
The end that command line Args asks for under command name Name, `reboot`
or `halt`, or a usage error for a flag this command does not take or an
argument after the flags, as getopt(3) and FreeBSD's command answer.
""".
-spec parse(binary(), [binary()]) -> {ok, 'end'()} | {error, usage}.
parse(Name, Args) ->
    case erx_cmd:getopt(Args, "lpq") of
        {ok, Flags, []} -> {ok, end_of(Name, lists:member($p, Flags))};
        _ -> {error, usage}
    end.

end_of(<<"halt">>, _PowerOff) -> off;
end_of(_Reboot, true) -> off;
end_of(_Reboot, false) -> reset.

-doc """
Whether a command running in runtime Runtime may end the machine: only
the system domain's runtime may.
""".
-spec may_end(system | domain) -> boolean().
may_end(system) -> true;
may_end(domain) -> false.

runtime() ->
    case erx_inspector:is_system_runtime() of
        true -> system;
        false -> domain
    end.

%% The effects: refuse, or log and end. init's stop returns at once while init shuts
%% the node down, and the command then waits for the machine to end, as FreeBSD's
%% waits for init, so the shell prints no prompt meanwhile.
act(false, _End) ->
    {error, <<"Operation not permitted">>};
act(true, End) ->
    logger:critical("~ts by root", [verb(End)]),
    ok = stop(End),
    receive after infinity -> ok end.

verb(reset) -> "rebooted";
verb(off) -> "powered off".

stop(reset) -> init:reboot();
stop(off) -> init:stop().
