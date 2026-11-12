%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter_rc).
-moduledoc """
The file operations on rc.conf (docs/design-apps.md, "Where the file
is"), which run in the table's workers, never in the table's process.
The file is `start/rc.conf` at the root of the system domain's `data`
grant, which erx_domain_app mounts at /data.

* read/0 reads at most one byte past erx_start_table's bound, so a file of
  any size costs no more than that, and parse_rc_conf/1 refuses one past
  it. A file that does not exist is `absent`: a machine with no settings.
* write/1 writes the new text to a temporary file beside rc.conf and
  renames it over rc.conf, so a reader finds the old text or the new one,
  never part of either.
""".

-export([read/0, write/1]).

-define(DIRECTORY, <<"/data/start">>).
-define(PATH, <<"/data/start/rc.conf">>).
-define(TEMPORARY, <<"/data/start/rc.conf.new">>).

-spec read() -> {ok, binary()} | absent | {error, term()}.
read() ->
    case file:open(?PATH, [read, binary]) of
        {ok, File} ->
            try
                read(File, erx_start_table:rc_conf_limit() + 1, [])
            after
                ok = file:close(File)
            end;
        {error, enoent} ->
            absent;
        {error, _} = Error ->
            Error
    end.

%% Reads until the end of the file or Left bytes, whichever comes first.
read(_File, Left, Read) when Left =< 0 ->
    {ok, iolist_to_binary(lists:reverse(Read))};
read(File, Left, Read) ->
    case file:read(File, Left) of
        {ok, Bytes} -> read(File, Left - byte_size(Bytes), [Bytes | Read]);
        eof -> {ok, iolist_to_binary(lists:reverse(Read))};
        {error, _} = Error -> Error
    end.

-spec write(binary()) -> ok | {error, term()}.
write(Text) ->
    maybe
        ok ?= directory(),
        ok ?= file:write_file(?TEMPORARY, Text),
        file:rename(?TEMPORARY, ?PATH)
    end.

directory() ->
    case file:make_dir(?DIRECTORY) of
        {error, eexist} -> ok;
        Made -> Made
    end.
