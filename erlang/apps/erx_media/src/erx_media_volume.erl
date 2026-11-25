%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_media_volume).
-moduledoc """
A volume's process (docs/design-drives.md, "Volumes"): a temporary child of its
medium's supervisor (erx_media_medium), and the volume's mount, which is made when it
starts and ends when it ends. It runs under the memory bound of "Time and memory",
`max_heap_size` of `media_volume_bytes` in words, with `kill` and
`include_shared_binaries`, so a volume whose heap, stack and the binaries it holds
pass the bound at a collection is ended alone.

It reads its volume through the window proxy alone, each sector placed by
erx_media_table:place/3, so no request reaches a sector outside the volume. Before
it answers anything it probes the volume (erx_media_probe:format/3), mounts the
selected format if it serves it, and applies the writable rule (writable/4), so a
call made while it mounts waits for the mount. Its outcome is what `sN_mount` shows:

* `rw`;
* `{ro, Reason}`, the writable rule's first condition that does not hold: `format`,
  `{also, Name}`, `flush` (the medium cannot flush) or `dirty`;
* `{none, Reason}`, no files: `format` for a format not served, FAT12 among them,
  `unknown`, `{flush, Reason}` for a flush that answered neither `ok` nor `enotsup`,
  or `{failed, Why}` for a probe whose read failed or a mount the format refused.

The formats served are FAT16 and FAT32, through the FAT server (erx_fat); no other
format falls back to another. Every byte of the volume is untrusted, and its label
reaches no sink here: the media tree shows it through the field escape.

Once mounted it serves its files to the media tree (erx_media_tree, "The media tree"):
root/1, walk/3, attr/2 and list/2 are calls, each naming a node by its FAT node and
its qid path (path/0), and a read is a waiting request whose keeper is this process,
answered as soon as its sectors are read. The calls carry no timer, as "Time and
memory" has it: they end when the volume answers or ends, and a volume that has ended,
or that mounted no files, answers `eio`.

A qid path is the volume's mount number, drawn from the media domain's counter
(new_mounts/0) when the process starts, whether or not it serves files, in its high
24 bits, and in its low 40 the number this mount drew for the node's erx_fat:key/1 at
the first walk or listing that named it, the root's 0 ("Identity"), so no path names
two files while the media domain lives and a medium mounted again is another set of
files. root_path/1 answers the root's path for any outcome, which the listing of the
drive's directory shows for `sN`. A mount past the 24 bits' last number is
`{none, {failed, enfile}}` and has no path, and a node past the 40 bits' last number
answers `enfile`.
""".

-behaviour(gen_server).

-export([start_link/2, outcome/1, writable/4, new_mounts/0]).
-export([root/1, root_path/1, walk/3, attr/2, list/2]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).
-export_type([outcome/0, mount/0, path/0]).

-include("erx_fs_waits.hrl").

-define(MOUNT_BITS, 24).
-define(NODE_BITS, 40).
%% Where the media domain's mount counter lies (new_mounts/0).
-define(MOUNTS, {?MODULE, mounts}).

%% The formats the media domain writes on a drive: FAT alone, the format table's one
%% row that writes and is served here (docs/design-drives.md, "The writable rule").
-define(WRITTEN, [msdosfs]).

-type mount() :: rw
               | {ro, format | {also, erx_media_probe:name()} | flush | dirty}
               | {none, format | unknown | {flush, atom()} | {failed, term()}}.
-type outcome() :: #{format := erx_media_probe:name() | unknown, mount := mount(),
                     fat => erx_fat_read:fat_type(), label => binary() | none,
                                          serial => non_neg_integer() | none}.
-type path() :: 0..16#ffffffffffffffff.
%% A node as the media tree holds it: its kind and qid path beside the FAT node itself.
-type named() :: {ok, erx_fat:fat_node(), dir | file, path()}.
-type errno() :: enoent | enotdir | eisdir | eio | enfile.

-doc """
Starts the process of Volume, an entry erx_media_table:read/2 answered, over the
window proxy Proxy, linked to the caller, the medium's supervisor.
""".
-spec start_link(pid(), erx_media_table:volume()) -> {ok, pid()}.
start_link(Proxy, #{first := _, length := _} = Volume) when is_pid(Proxy) ->
    gen_server:start_link(?MODULE, {Proxy, Volume}, []).

-doc """
Makes the media domain's mount counter, whose first number is 1, so that no volume's
path has mount number 0, the media tree's own; erx_media_sup makes it once per
incarnation, before any volume starts.
""".
-spec new_mounts() -> ok.
new_mounts() ->
    persistent_term:put(?MOUNTS, atomics:new(1, [{signed, false}])).

-doc "The root directory of the volume Pid's files.".
-spec root(pid()) -> named() | {error, errno()}.
root(Pid) -> call(Pid, root).

-doc """
The qid path of the volume Pid's root, whatever its outcome: `eio` once it has ended,
`enfile` for a mount past the counter's last number.
""".
-spec root_path(pid()) -> {ok, path()} | {error, eio | enfile}.
root_path(Pid) -> call(Pid, root_path).

-doc "The entry named Name of directory Dir of the volume Pid.".
-spec walk(pid(), erx_fat:fat_node(), binary()) -> named() | {error, errno()}.
walk(Pid, Dir, Name) -> call(Pid, {walk, Dir, Name}).

-doc "Node's attributes (erx_fat:attr/1) and qid path.".
-spec attr(pid(), erx_fat:fat_node()) -> {ok, map(), path()} | {error, errno()}.
attr(Pid, Node) -> call(Pid, {attr, Node}).

-doc "Directory Dir's entries, in the volume's order: each name, its kind and its qid path.".
-spec list(pid(), erx_fat:fat_node()) -> {ok, [{binary(), dir | file, path()}]} | {error, errno()}.
list(Pid, Dir) -> call(Pid, {list, Dir}).

call(Pid, Request) ->
    try gen_server:call(Pid, Request, infinity) catch exit:_Ended -> {error, eio} end.

-doc "The volume's outcome, once its probe and mount are done.".
-spec outcome(pid()) -> outcome().
outcome(Pid) ->
    gen_server:call(Pid, outcome, infinity).

-doc """
The writable rule (docs/design-drives.md, "The writable rule") for a volume of the
selected format Format, on which the probe also found the written formats Also, and
whose format's own state is Clean: `rw` when every condition holds, else
`{ro, Reason}` for the first that does not, or `{none, {flush, Reason}}` for a flush
that answered anything but `ok` or `enotsup`, which refuses the mount with nothing
written. Flush sends the mount's one flush; it is called only once the first two
conditions hold, and before anything is written.
""".
-spec writable(erx_media_probe:name(), [erx_media_probe:name()], fun(() -> ok | {error, term()}),
               boolean()) -> mount().
writable(Format, Also, Flush, Clean) ->
    case {lists:member(Format, ?WRITTEN), Also} of
        {false, _} -> {ro, format};
        {true, [Name | _]} -> {ro, {also, Name}};
        {true, []} -> flushed(Flush(), Clean)
    end.

flushed(ok, true) -> rw;
flushed(ok, false) -> {ro, dirty};
flushed({error, enotsup}, _Clean) -> {ro, flush};
flushed({error, Reason}, _Clean) when is_atom(Reason) -> {none, {flush, Reason}};
flushed(_Malformed, _Clean) -> {none, {flush, eio}}.

%% The process ---------------------------------------------------------------------

-doc false.
init({Proxy, Volume}) ->
    process_flag(max_heap_size, erx_media_medium:memory_bound()),
    {ok, #{proxy => Proxy, volume => Volume}, {continue, mount}}.

-doc false.
handle_continue(mount, #{proxy := Proxy, volume := #{length := Length} = Volume} = State) ->
    case new_mount() of
        {ok, Mount} ->
            Read = fun(Sector) -> read_sector(Proxy, Volume, Sector) end,
            {Outcome, Fat} = mounted(erx_media_probe:format(Read, Length, ?WRITTEN), Read, Length, Proxy),
            {noreply, State#{outcome => Outcome, mount => Mount, fat => Fat, paths => root_paths(Fat)}};
        enfile ->
            Outcome = #{format => unknown, mount => {none, {failed, enfile}}},
            {noreply, State#{outcome => Outcome, mount => none, fat => none, paths => #{}}}
    end.

-doc false.
handle_call(outcome, _From, #{outcome := Outcome} = State) ->
    {reply, Outcome, State};
handle_call(root_path, _From, #{mount := none} = State) ->
    {reply, {error, enfile}, State};
handle_call(root_path, _From, #{mount := Mount} = State) ->
    {reply, {ok, Mount bsl ?NODE_BITS}, State};
handle_call(_Files, _From, #{fat := none} = State) ->
    {reply, {error, eio}, State};
handle_call(root, _From, #{fat := Fat} = State) ->
    named(erx_fat:root(Fat), State);
handle_call({walk, Dir, Name}, _From, #{fat := Fat} = State) ->
    case erx_fat:walk(Dir, Name, Fat) of
        {ok, Node} -> named(Node, State);
        {error, Why} -> {reply, {error, errno(Why)}, State}
    end;
handle_call({attr, Node}, _From, State) ->
    case path(Node, State) of
        {ok, Path, Next} -> {reply, {ok, erx_fat:attr(Node), Path}, Next};
        {error, _} = Refused -> {reply, Refused, State}
    end;
handle_call({list, Dir}, _From, #{fat := Fat} = State) ->
    case erx_fat:list(Dir, Fat) of
        {ok, Entries} -> listed(Entries, [], State);
        {error, Why} -> {reply, {error, errno(Why)}, State}
    end;
handle_call(_Other, _From, State) ->
    {reply, {error, einval}, State}.

-doc false.
handle_cast(_Other, State) ->
    {noreply, State}.

%% A read is a waiting request whose keeper is the volume, answered once its sectors
%% are read; a flush that follows its answer finds nothing to flush.
-doc false.
handle_info(?ERX_FS_WAIT({_Grant, Alias}, {read, File, Offset, Count}), #{fat := Mounted} = State) ->
    Alias ! ?ERX_FS_ANSWER(Alias, read(File, Offset, Count, Mounted)),
    {noreply, State};
handle_info(_Other, State) ->
    {noreply, State}.

read(_File, _Offset, _Count, none) ->
    {error, eio};
read(File, Offset, Count, Fat) ->
    case erx_fat:read(File, Offset, Count, Fat) of
        {ok, Bytes} -> {ok, Bytes};
        {error, Why} -> {error, errno(Why)}
    end.

%% The files --------------------------------------------------------------------

%% The volume's mount number, the next of the media domain's counter.
new_mount() ->
    case atomics:add_get(persistent_term:get(?MOUNTS), 1, 1) of
        Mount when Mount < 1 bsl ?MOUNT_BITS -> {ok, Mount};
        _Past -> enfile
    end.

%% The paths a mount starts with: its root's number 0, drawn before any walk names it.
root_paths(none) -> #{};
root_paths(Fat) -> #{erx_fat:key(erx_fat:root(Fat)) => 0}.

named(Node, State) ->
    case path(Node, State) of
        {ok, Path, Next} -> {reply, {ok, Node, kind(Node), Path}, Next};
        {error, _} = Refused -> {reply, Refused, State}
    end.

listed([], Acc, State) ->
    {reply, {ok, lists:reverse(Acc)}, State};
listed([{Name, Node} | Rest], Acc, State) ->
    case path(Node, State) of
        {ok, Path, Next} -> listed(Rest, [{Name, kind(Node), Path} | Acc], Next);
        {error, _} = Refused -> {reply, Refused, State}
    end.

%% Node's qid path, its key's number drawn at its first naming: the next of the
%% mount's, which the map's size gives, since numbers are drawn from 0 and never freed.
path(Node, #{mount := Mount, paths := Paths} = State) ->
    Key = erx_fat:key(Node),
    case Paths of
        #{Key := Number} ->
            {ok, (Mount bsl ?NODE_BITS) bor Number, State};
        #{} when map_size(Paths) < 1 bsl ?NODE_BITS ->
            Number = map_size(Paths),
            {ok, (Mount bsl ?NODE_BITS) bor Number, State#{paths := Paths#{Key => Number}}};
        #{} ->
            {error, enfile}
    end.

kind(Node) -> maps:get(kind, erx_fat:attr(Node)).

errno(not_found) -> enoent;
errno(not_dir) -> enotdir;
errno(is_dir) -> eisdir;
errno(_Finding) -> eio.

%% The mount --------------------------------------------------------------------

%% The outcome of the probe's answer, and the FAT server's mount when it serves the
%% volume (none otherwise). Only FAT16 and FAT32 are served; the selected format is the
%% volume's one reading, and the FAT type shown is the one the mount read, since the
%% medium answers each read afresh.
mounted({error, Why}, _Read, _Length, _Proxy) ->
    {#{format => unknown, mount => {none, {failed, Why}}}, none};
mounted({ok, #{format := msdosfs, also := Also, fat := Type}}, Read, Length, Proxy)
  when Type =:= 16; Type =:= 32 ->
    case erx_fat:mount(Read, Length) of
        {ok, Fat} ->
            #{type := Mounted, label := Label, serial := Serial, clean := Clean} = erx_fat:info(Fat),
            Mount = writable(msdosfs, Also, fun() -> erx_media_medium:window(Proxy, flush) end, Clean),
            {#{format => msdosfs, fat => Mounted, label => Label, serial => Serial, mount => Mount}, served(Mount, Fat)};
        {error, Finding} ->
            {#{format => msdosfs, fat => Type, mount => {none, {failed, Finding}}}, none}
    end;
mounted({ok, #{format := msdosfs, fat := Type}}, _Read, _Length, _Proxy) ->
    {#{format => msdosfs, fat => Type, mount => {none, format}}, none};
mounted({ok, #{format := unknown}}, _Read, _Length, _Proxy) ->
    {#{format => unknown, mount => {none, unknown}}, none};
mounted({ok, #{format := Format}}, _Read, _Length, _Proxy) ->
    {#{format => Format, mount => {none, format}}, none}.

%% A mount the writable rule refused, for a flush that failed, serves no files.
served({none, _Reason}, _Fat) -> none;
served(_Mount, Fat) -> Fat.

%% The volume's sector Sector, read through the proxy at its place on the medium.
read_sector(Proxy, Volume, Sector) ->
    case erx_media_table:place(Volume, Sector, 1) of
        {ok, Lba} -> erx_media_medium:window(Proxy, {read, Lba, 1});
        {error, erange} = Refused -> Refused
    end.
