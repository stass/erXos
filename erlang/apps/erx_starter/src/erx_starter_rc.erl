%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter_rc).
-moduledoc """
The file operations on rc.conf (docs/design-apps.md, "Where the file
is"), which run in the table's workers, never in the table's process.
The file is `rc.conf` in a directory the table names: directory/0,
`start` at the root of the system domain's `data` grant, which
erx_domain_app mounts at /data, or a test's own.

* read/1 reads at most one byte past erx_start_table's bound, so a file of
  any size costs no more than that, and parse_rc_conf/1 refuses one past
  it. A file that does not exist is `absent`: a machine with no settings.
* write/2 writes the new text to a temporary file beside rc.conf, syncs
  it to storage and renames it over rc.conf, so a reader finds the old
  text or the new one, never part of either.
""".

-export([directory/0, read/1, write/2]).

-doc "The directory of the system's rc.conf.".
-spec directory() -> binary().
directory() ->
    <<"/data/start">>.

-spec read(binary()) -> {ok, binary()} | absent | {error, term()}.
read(Directory) ->
    case file:open(path(Directory), [read, binary]) of
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

-spec write(binary(), binary()) -> ok | {error, term()}.
write(Directory, Text) ->
    Temporary = filename:join(Directory, <<"rc.conf.new">>),
    maybe
        ok ?= make_directory(Directory),
        ok ?= write_synced(Temporary, Text),
        file:rename(Temporary, path(Directory))
    end.

%% Writes Text as the whole of the file at Path and syncs it, so the rename
%% that follows never puts a file whose bytes are not on storage in place.
write_synced(Path, Text) ->
    maybe
        {ok, File} ?= file:open(Path, [write, binary]),
        try
            maybe
                ok ?= file:write(File, Text),
                file:sync(File)
            end
        after
            _ = file:close(File)
        end
    end.

path(Directory) ->
    filename:join(Directory, <<"rc.conf">>).

make_directory(Directory) ->
    case file:make_dir(Directory) of
        {error, eexist} -> ok;
        Made -> Made
    end.
