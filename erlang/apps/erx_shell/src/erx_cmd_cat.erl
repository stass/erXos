%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_cat).
-moduledoc """
`cat [file ...]`: writes each file in turn, or standard input for none
and for `-`, unchanged. A record from a neighbouring stage is written as
its line. A file that cannot be read is reported and the rest are still
written; the first such error is the status.
""".

-behaviour(erx_cmd).
-erx_command(cat).
-erx_usage("cat [file ...]").

-export([run/2]).

-define(PIECE, 65536).

run([], Ctx) ->
    run([<<"-">>], Ctx);
run(Files, Ctx) ->
    case [Reason || File <- Files, {error, Reason} <- [cat(File, Ctx)]] of
        [] -> ok;
        [First | _] -> {error, {reported, First}}
    end.

cat(<<"-">>, Ctx) ->
    copy_input(Ctx);
cat(File, Ctx) ->
    case file:open(erx_cmd:path(Ctx, File), [read, raw, binary]) of
        {ok, Fd} ->
            try copy_file(Fd, File, Ctx) after file:close(Fd) end;
        {error, Reason} ->
            erx_cmd:report(Ctx, File, Reason),
            {error, Reason}
    end.

copy_input(Ctx) ->
    case erx_cmd:read_line(Ctx) of
        eof -> ok;
        Line -> erx_cmd:emit(Ctx, Line), copy_input(Ctx)
    end.

copy_file(Fd, File, Ctx) ->
    case file:read(Fd, ?PIECE) of
        {ok, Bytes} -> erx_cmd:emit(Ctx, Bytes), copy_file(Fd, File, Ctx);
        eof -> ok;
        {error, Reason} -> erx_cmd:report(Ctx, File, Reason), {error, Reason}
    end.
