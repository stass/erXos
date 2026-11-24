%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_storage_login_keys).
-moduledoc """
The `login_keys` tree (docs/design-ssh.md, "Root's login keys on the medium";
docs/design-storage.md, "The record volume's one reader"): root's login keys
read from the record volume's `authorized_keys`, served read-only as the file
`root`, of 51-byte key blobs one after the other; and root's passphrase record
read from its `passphrase_hash` (docs/design-ssh.md, "Root's passphrase on the
medium"), served as the file `root_passphrase`, the record
erx_passphrase_hash lays out. The reader reads both files at once, so the two
share one lifecycle.

* **The holder.** start_mint/0 starts the service's mint, erx_fs_mint,
  whose mount starts the holder, a process of this module linked to the mint,
  and answers its pid as the tree, so the mount waits for no read and the mint
  answers mint requests at once. The holder is the one owner of the result. It
  reads nothing until a file is first asked for, so a boot whose session has
  imported its keys never reads the medium; then it spawns the reader with a monitor and sends it the monitor's reference, which
  tags the reader's one result message, so no other message can be taken for
  it; the first of that message and the `'DOWN'` with the same reference
  decides the answer, and every later message is dropped. The holder reads no
  sector and runs no decoder, so it ends only with the mint.
* **The reader** is a process of its own that reads the volume through the
  `record_volume` window with erx_fat_read:root_file/3, bounded by
  erx_boot_keys:file_max/0 and erx_boot_passphrase:file_max/0, and decodes the
  files with erx_boot_keys:decode/1 and erx_boot_passphrase:decode/1.
  The medium's bytes are untrusted, and both are pure functions over them.
* **What a file answers.** Until the reader is done, a read answers `eagain`, an
  error and not an empty file. A result the pure functions decide is the file:
  the blobs or the record, or none when they refuse it. A sector read that fails, a
  reader that raises and one that ends without a result answer `eio`: the
  medium was not read, so no empty file stands in for it. Once decided, the
  answer holds for the holder's life.

Each finding is one line of the kernel log naming the file, a line number for a
skipped line, and one reason of the design's closed set; no byte of the file is
logged. Every grant is read-only: the tree has no writing callback (F5).
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([start_mint/0, start_link/2, root_answer/1, answer/2, log/1]).
-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4, statfs/1, clunk/2]).
%% The holder's process.
-export([holder_init/3]).
-export_type([answer/0, file/0]).

-define(TREE, <<"login_keys">>).
-define(ROOT_NAME, <<"root">>).
-define(AUTHORIZED_KEYS, <<"authorized_keys">>).
-define(PASSPHRASE_NAME, <<"root_passphrase">>).
-define(PASSPHRASE_HASH, <<"passphrase_hash">>).
-define(IS_FILE(File), (File =:= root orelse File =:= root_passphrase)).
%% The file's qid path, and its mode: read by its owner, root, alone.
-define(ROOT_PATH, 1).
-define(PASSPHRASE_PATH, 2).
-define(ROOT_MODE, 8#0400).
%% A grant's wait for the holder, which answers from its state at once.
-define(CALL_TIMEOUT, 5000).

-doc "What a read of a file of the tree answers: the file, or why there is none.".
-type answer() :: {ok, binary()} | {error, eagain | eio}.

-doc "The tree's files: root's key blobs and root's passphrase record.".
-type file() :: root | root_passphrase.

%% What the reader sends the holder, tagged with the holder's monitor of it.
%% A reader that raises sends read_failed for both.
-type result() :: {keys_result(), passphrase_result()} | read_failed.
-type keys_result() :: {keys, [erx_boot_keys:blob()], [erx_boot_keys:finding()]}
                     | {refused, erx_fat_read:finding() | erx_boot_keys:refusal()}
                     | read_failed.
-type passphrase_result() :: {record, binary()}
                           | {refused, erx_fat_read:finding() | erx_boot_passphrase:refusal()}
                           | read_failed.

-doc """
Starts the mint of `login_keys_service`, `login_keys`, linked to the caller
(erx_storage_sup), on the block service's `record_volume` window, which the
service starts exactly when the domain's `-erx_record system_image` names it, the
domain library's mark of the manifest's `record_volume` window
(erx_blk_table:booted/1). A domain whose record does not name it starts no mint.
""".
-spec start_mint() -> {ok, pid()} | ignore.
start_mint() ->
    case erx_blk_service:window(record_volume) of
        {ok, Window} ->
            Read = fun(Sector) -> erx_blk_window:read(Window, Sector, 1) end,
            erx_fs_mint:start_link(login_keys, ?MODULE, fun() -> holder(Read) end);
        {error, _} ->
            ignore
    end.

%% The mount: the holder, linked to the mint that runs this, logging to the kernel log.
holder(Read) ->
    {ok, Holder} = start_link(Read, fun ?MODULE:log/1),
    Holder.

-doc """
Starts the holder linked to the caller, and its reader, which reads one sector of
the record volume with Read and hands each finding to Log.
""".
-spec start_link(erx_fat_read:read_sector(), fun((iodata()) -> term())) -> {ok, pid()}.
start_link(Read, Log) when is_function(Read, 1), is_function(Log, 1) ->
    proc_lib:start_link(?MODULE, holder_init, [self(), Read, Log]).

-doc "What a read of `root` answers now, as Holder holds it.".
-spec root_answer(pid()) -> answer().
root_answer(Holder) ->
    answer(Holder, root).

-doc "What a read of File answers now, as Holder holds it; `eio` once Holder has ended.".
-spec answer(pid(), file()) -> answer().
answer(Holder, File) when ?IS_FILE(File) ->
    Alias = erlang:monitor(process, Holder, [{alias, reply_demonitor}]),
    Holder ! {?MODULE, File, Alias},
    receive
        {Alias, Answer} -> Answer;
        {'DOWN', Alias, process, _, _} -> {error, eio}
    after ?CALL_TIMEOUT ->
        erlang:demonitor(Alias, [flush]),
        {error, eio}
    end.

-doc false.
-spec log(iodata()) -> term().
log(Line) ->
    erx_log:debug(["erx_storage_login_keys: ", Line]).

%% ---------------------------------------------------------------------------
%% The holder and its reader
%% ---------------------------------------------------------------------------

-doc false.
holder_init(Parent, Read, Log) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    idle(Read, Log).

%% Until a file is first asked for, no sector is read: the medium is read only for a
%% session that has not imported its keys. The first query starts the reader and is
%% answered eagain, as every query is while the reader runs.
idle(Read, Log) ->
    receive
        {?MODULE, File, Alias} when ?IS_FILE(File), is_reference(Alias) ->
            Monitor = start_reader(Read),
            Alias ! {Alias, {error, eagain}},
            loading(Monitor, Log);
        _ ->
            idle(Read, Log)
    end.

%% The reader, spawned with a monitor and sent the monitor's reference.
start_reader(Read) ->
    Holder = self(),
    {Reader, Monitor} = spawn_monitor(fun() -> reader(Holder, Read) end),
    Reader ! {start, Monitor},
    Monitor.

%% While the reader runs, each file answers eagain; the first of the reader's result and its
%% end, both under its monitor's reference, decides the answer. Any other message is
%% dropped.
loading(Monitor, Log) ->
    receive
        {Monitor, {result, Result}} ->
            erlang:demonitor(Monitor, [flush]),
            decided(publish(Result, Log));
        {'DOWN', Monitor, process, _Reader, _Reason} ->
            decided(publish(read_failed, Log));
        {?MODULE, File, Alias} when ?IS_FILE(File), is_reference(Alias) ->
            Alias ! {Alias, {error, eagain}},
            loading(Monitor, Log);
        _ ->
            loading(Monitor, Log)
    end.

%% Once decided, each file answers its Answers' entry for the holder's life, and every other message,
%% a late result or end of the reader among them, is dropped.
decided(Answers) ->
    receive
        {?MODULE, File, Alias} when ?IS_FILE(File), is_reference(Alias) ->
            Alias ! {Alias, maps:get(File, Answers)},
            decided(Answers);
        _ ->
            decided(Answers)
    end.

%% The answers a result gives, its findings handed to Log.
-spec publish(result(), fun((iodata()) -> term())) -> #{file() := answer()}.
publish(read_failed, Log) ->
    publish({read_failed, read_failed}, Log);
publish({Keys, Passphrase}, Log) ->
    #{root => keys(Keys, Log), root_passphrase => passphrase(Passphrase, Log)}.

keys({keys, Blobs, Findings}, Log) ->
    lists:foreach(fun({Line, Reason}) ->
                          Log(["authorized_keys line ", integer_to_binary(Line), ": ", reason(Reason)])
                  end, Findings),
    {ok, iolist_to_binary(Blobs)};
keys({refused, Reason}, Log) ->
    _ = Log(["authorized_keys: ", reason(Reason)]),
    {ok, <<>>};
keys(read_failed, Log) ->
    _ = Log(["authorized_keys: ", reason(read_failed)]),
    {error, eio}.

%% Root's passphrase record; no byte of the file is logged, only the reason. Most
%% media hold no passphrase_hash, so its absence is not logged.
passphrase({record, Record}, _Log) ->
    {ok, Record};
passphrase({refused, not_found}, _Log) ->
    {ok, <<>>};
passphrase({refused, Reason}, Log) ->
    _ = Log(["passphrase_hash: ", passphrase_reason(Reason)]),
    {ok, <<>>};
passphrase(read_failed, Log) ->
    _ = Log(["passphrase_hash: ", reason(read_failed)]),
    {error, eio}.

%% The reader: waits for the monitor's reference, then reads and decodes the file and
%% sends the holder the result under that reference. A read that raises is read_failed,
%% caught here so that no crash report carries the medium's bytes to the log; a reader
%% killed before its result is read_failed by the holder's monitor.
reader(Holder, Read) ->
    receive
        {start, Monitor} ->
            Result = try read_file(Read) catch _:_ -> read_failed end,
            Holder ! {Monitor, {result, Result}}
    end.

-spec read_file(erx_fat_read:read_sector()) -> result().
read_file(Read) ->
    {read_one(Read, ?AUTHORIZED_KEYS, erx_boot_keys:file_max(), fun keys_decoded/1),
     read_one(Read, ?PASSPHRASE_HASH, erx_boot_passphrase:file_max(), fun passphrase_decoded/1)}.

read_one(Read, Name, Max, Decoded) ->
    case erx_fat_read:root_file(Read, Name, Max) of
        {ok, File} -> Decoded(File);
        {error, read_failed} -> read_failed;
        {error, Finding} -> {refused, Finding}
    end.

keys_decoded(File) ->
    case erx_boot_keys:decode(File) of
        {ok, Blobs, Findings} -> {keys, Blobs, Findings};
        {error, Refusal} -> {refused, Refusal}
    end.

passphrase_decoded(File) ->
    case erx_boot_passphrase:decode(File) of
        {ok, Record} -> {record, Record};
        {error, Refusal} -> {refused, Refusal}
    end.

%% The design's closed set of reasons (docs/design-ssh.md, "Diagnostics").
reason(not_a_plain_key) -> <<"not a plain ssh-ed25519 key">>;
reason(does_not_decode) -> <<"key does not decode">>;
reason(line_too_long) -> <<"line longer than 1024 bytes">>;
reason(not_found) -> <<"no authorized_keys">>;
reason(too_long) -> <<"longer than 16 KiB">>;
reason(too_many_keys) -> <<"more than 16 keys">>;
reason(not_its_volume) -> <<"the record partition is not its FAT volume">>;
reason(does_not_read) -> <<"does not read">>;
reason(read_failed) -> <<"read failed">>.

%% The passphrase file's reasons: its own bound and form, then the volume's.
passphrase_reason(too_long) -> <<"longer than 128 bytes">>;
passphrase_reason(not_a_crypt_string) -> <<"not a $5$ SHA-256 crypt string">>;
passphrase_reason(Finding) -> reason(Finding).

%% ---------------------------------------------------------------------------
%% The erx_fs callbacks: a tree of two files, whose every answer is the holder's
%% ---------------------------------------------------------------------------

-doc false.
init(Holder) when is_pid(Holder) -> {ok, Holder}.

-doc false.
root(_Holder) -> {ok, ?TREE, root, {?ERX_P9_QTDIR, 0, 0}}.

-doc false.
walk(root, ?ROOT_NAME, _Holder) -> {ok, {file, root}, {0, 0, ?ROOT_PATH}};
walk(root, ?PASSPHRASE_NAME, _Holder) -> {ok, {file, root_passphrase}, {0, 0, ?PASSPHRASE_PATH}};
walk(_Node, _Name, _Holder) -> {error, enoent}.

-doc false.
getattr(root, _Holder) ->
    erx_fs_node:attr({?ERX_P9_QTDIR, 0, 0}, dir, 8#0500);
getattr({file, File}, Holder) ->
    case answer(Holder, File) of
        {ok, Bytes} ->
            {ok, Attr} = erx_fs_node:attr({0, 0, path(File)}, file, ?ROOT_MODE),
            {ok, Attr#{size := byte_size(Bytes), blocks := (byte_size(Bytes) + 511) div 512}};
        {error, _} = Error ->
            Error
    end.

-doc false.
open(root, _Flags, _Holder) ->
    {ok, erx_fs_node:listing([{{0, 0, ?ROOT_PATH}, ?ERX_P9_DT_REG, ?ROOT_NAME},
                              {{0, 0, ?PASSPHRASE_PATH}, ?ERX_P9_DT_REG, ?PASSPHRASE_NAME}])};
open({file, _} = File, _Flags, _Holder) -> {ok, File}.

-doc false.
read({file, File}, Offset, Count, Holder) ->
    case answer(Holder, File) of
        {ok, Bytes} when Offset >= byte_size(Bytes) -> {ok, <<>>};
        {ok, Bytes} -> {ok, binary:part(Bytes, Offset, min(Count, byte_size(Bytes) - Offset))};
        {error, _} = Error -> Error
    end;
read({entries, _}, _Offset, _Count, _Holder) ->
    {error, eisdir}.

path(root) -> ?ROOT_PATH;
path(root_passphrase) -> ?PASSPHRASE_PATH.

-doc false.
readdir(Handle, Offset, Max, _Holder) ->
    erx_fs_node:readdir(Handle, Offset, Max).

-doc false.
statfs(_Holder) ->
    erx_fs_node:statfs(?ERX_P9_MAGIC_RAMFS).

-doc false.
clunk(_Handle, _Holder) ->
    ok.
