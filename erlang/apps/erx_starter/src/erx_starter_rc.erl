%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter_rc).
-moduledoc """
The rc.conf process: it does every file operation on rc.conf
(docs/design-apps.md, "Where the file is" and "Concurrency"), one at a
time, for the table, which does none itself. The file is `rc.conf` in a
directory the table names: directory/0, `start` at the root of the
system domain's `data` grant, which the domain service mounts at /data where the
manifest grants it (with no grant the path is the root's and the file absent), or a
test's own.

The table asks with read/1 and write/2, which return at once, and takes
each answer as the reply to its request (gen_server:check_response/2),
so a slow storage domain delays the commands waiting for it, not the
table's answers.

* A read reads at most one byte past erx_start_table's bound, so a file of
  any size costs no more than that, and parse_rc_conf/1 refuses one past
  it. A file that does not exist is `absent`: a machine with no settings.
* A write writes the new text to a temporary file beside rc.conf, syncs
  it to storage and renames it over rc.conf, so a reader finds the old
  text or the new one, never part of either.

**One table at a time.** The process outlives the table: it is the
table's elder sibling in erx_starter_sup's rest_for_one tree, so a crash
of the table leaves it running, with the write the table asked for in
progress or queued. It carries out the writes only of the process whose
read came last, and refuses any other's with `superseded`, changing
nothing. A restarted table reads rc.conf before it writes, so every
write of the table before it lands before that read, which then finds
its text, or is refused: the text a table is made from is the file's
until the table itself writes it, and no write made from an older text
undoes a newer one. Because one process does every operation, no two
writes share the temporary file.

The process traps exits, so its supervisor's shutdown, when the tree
restarts what comes before it, waits for the operation in progress to
end (shutdown `infinity`) instead of cutting it short: a rename already
sent to the storage domain lands whatever became of the process that
sent it, and could otherwise land after the next table's read.
""".
-behaviour(gen_server).

-export([start_link/0, directory/0, read/1, write/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-doc "Starts the rc.conf process, registered as erx_starter_rc.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "The directory of the system's rc.conf.".
-spec directory() -> binary().
directory() ->
    <<"/data/start">>.

-doc """
Asks for the text of rc.conf in Directory, and makes the calling process
the one whose writes are carried out. The reply is {ok, Text}, absent for
no file, or {error, Why}.
""".
-spec read(binary()) -> gen_server:request_id().
read(Directory) ->
    gen_server:send_request(?MODULE, {read, Directory}).

-doc """
Asks for Text to be written as rc.conf in Directory. The reply is ok, or
{error, Why}: `superseded` when another process read since the caller
did, which leaves the file unchanged.
""".
-spec write(binary(), binary()) -> gen_server:request_id().
write(Directory, Text) ->
    gen_server:send_request(?MODULE, {write, Directory, Text}).

%% ---------------------------------------------------------------------------
%% The process

%% The state is the process whose read came last, or none before any read.
init([]) ->
    process_flag(trap_exit, true),
    {ok, #{last_reader => none}}.

handle_call({read, Directory}, {Reader, _Tag}, State) ->
    {reply, read_file(Directory), State#{last_reader := Reader}};
handle_call({write, Directory, Text}, {Reader, _Tag}, #{last_reader := Reader} = State) ->
    {reply, write_file(Directory, Text), State};
handle_call({write, _Directory, _Text}, _From, State) ->
    {reply, {error, superseded}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% ---------------------------------------------------------------------------
%% The file operations

read_file(Directory) ->
    case file:open(path(Directory), [read, binary]) of
        {ok, File} ->
            try
                read_file(File, erx_start_table:rc_conf_limit() + 1, [])
            after
                _ = file:close(File)
            end;
        {error, enoent} ->
            absent;
        {error, _} = Error ->
            Error
    end.

%% Reads until the end of the file or Left bytes, whichever comes first.
read_file(_File, Left, Read) when Left =< 0 ->
    {ok, iolist_to_binary(lists:reverse(Read))};
read_file(File, Left, Read) ->
    case file:read(File, Left) of
        {ok, Bytes} -> read_file(File, Left - byte_size(Bytes), [Bytes | Read]);
        eof -> {ok, iolist_to_binary(lists:reverse(Read))};
        {error, _} = Error -> Error
    end.

write_file(Directory, Text) ->
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
