%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_dmesg).
-moduledoc """
`dmesg [-a]`: writes the kernel's message buffer, as FreeBSD's dmesg
does (sbin/dmesg/dmesg.c). erXos's buffer is the kernel log, which
`/proc/kernel/log` shows from its oldest record the ring still holds, a
line each, each through the field escape, with `[missing N]` where records
are missing (docs/design-live.md, "The /proc tree"); dmesg writes that
file unchanged, as FreeBSD's writes `kern.msgbuf`.

Flags. `-a` is accepted: FreeBSD's shows the syslog records and console
output the buffer also holds, and erXos's buffer holds only the kernel
log's lines, so it writes the same. `-c`, which clears the buffer, is a
usage error, since nothing in user space clears the kernel log, and so
are `-M` and `-N`, which read a crash dump's buffer: the last reset's
crash record is `/proc/kernel/crash`. An argument after the flags is a
usage error, as on FreeBSD.
""".

-behaviour(erx_cmd).
-erx_command(dmesg).
-erx_usage("dmesg [-ac] [-M core [-N system]]").

-export([run/2]).

-define(LOG, <<"/proc/kernel/log">>).
-define(PIECE, 65536).

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "a") of
        {ok, _Flags, []} -> dmesg(Ctx);
        _ -> {error, usage}
    end.

dmesg(Ctx) ->
    case file:open(erx_cmd:path(Ctx, ?LOG), [read, raw, binary]) of
        {ok, Fd} ->
            try copy(Fd, Ctx) after file:close(Fd) end;
        {error, Reason} ->
            erx_cmd:report(Ctx, ?LOG, Reason),
            {error, {reported, Reason}}
    end.

copy(Fd, Ctx) ->
    case file:read(Fd, ?PIECE) of
        {ok, Bytes} ->
            erx_cmd:write(Ctx, Bytes),
            copy(Fd, Ctx);
        eof ->
            ok;
        {error, Reason} ->
            erx_cmd:report(Ctx, ?LOG, Reason),
            {error, {reported, Reason}}
    end.
