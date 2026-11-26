%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_procfs).
-moduledoc """
`/proc`, the inspector's paths as a read-only file tree (docs/design-live.md,
"The /proc tree"): the `erx_fs` callback module. The tree holds no scope
and decides nothing itself: a walk, an open and a listing each ask
erx_inspector:inspect/2 for the path, or erx_inspector:literals/1 for the
literal children of a directory whose children the schema names, which
outside the system domain go through the domain's inspect facet, and
erx_procfs_core turns the answers into nodes, entries and text. A path
the inspector answers `{error, scope}`, and every path of a domain that
holds no inspect facet or whose facet has ended (`{error, no_facet}`),
reads as `enoent`, so the tree shows nothing that erx:i/1 in the same
domain does not.

* **Handle.** init/1 takes the inspector to ask, inspector/1 or a host
  test's stand-in, a function of a query `{inspect, Path, Options}` or
  `{literals, Path}`, and answers `Fs`, it and a counter of the grant's
  open snapshots.
* **Snapshots.** An open runs the inspector's query once: a `status` file
  holds its rendered record and a directory its entries, and reads see that
  snapshot until the clunk. The file of an append-only path, such as
  `/proc/kernel/log`, runs it once a page, from sequence number 0, each
  page from where the one before stopped, while the inspector answers
  partial and the entries fit the file's 64 KiB, for at most 16 pages. A grant holds at most 256 snapshots; the 257th
  open answers `emfile`.
* **Attributes.** Every node is read-only, owned by uid 0, size 0 as a
  Linux `/proc` file is, so a reader reads to the end of the file.

The kernel's safe supervisor starts one grant in every runtime with
start_link/0, mounted at `/proc`: in the system domain its queries run
in a local query worker at scope `all`, and in every other domain they
go through that domain's inspect facet.
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([start_link/0, inspector/1]).
-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4, statfs/1, clunk/2]).

%% The tree's name: its root answers it, its grant's handle carries it, attach's Aname names it.
-define(TREE, <<"proc">>).
-define(POINT, <<"/proc">>).
%% The most open snapshots of one grant (design-live.md, Snapshots).
-define(MAX_SNAPSHOTS, 256).
%% The most pages one open of an append-only path asks for.
-define(MAX_PAGES, 16).
%% The most bytes of one file (design-live.md, Snapshots): once the entries
%% asked for hold that many, the file is cut there anyway.
-define(MAX_FILE, 65536).

-doc """
Starts this domain's tree, a grant over inspector/1, and mounts it at
`/proc`, after removing any entry an earlier instance left there.
""".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    erx_fs:start_mounted(?MODULE, fun ?MODULE:inspector/1, ro, ?POINT).

-doc """
The answer to one of the tree's two queries as this domain's inspector
gives it: a path's record (erx_inspector:inspect/2) or the literal
children below a path that name something (erx_inspector:literals/1).
""".
-spec inspector({inspect, [erx_schema:segment()], map()} | {literals, [erx_schema:segment()]}) ->
          erx_inspector:answer() | erx_inspector:literals().
inspector({inspect, Path, Options}) -> erx_inspector:inspect(Path, Options);
inspector({literals, Path}) -> erx_inspector:literals(Path).

%% ---------------------------------------------------------------------------
%% The erx_fs callbacks
%% ---------------------------------------------------------------------------

-doc false.
init(Ask) when is_function(Ask, 1) ->
    {ok, #{ask => Ask, snapshots => counters:new(1, [atomics])}}.

-doc false.
root(_Fs) ->
    Root = erx_procfs_core:root(),
    {ok, ?TREE, Root, qid(Root)}.

-doc false.
walk({dir, Dir}, Name, #{ask := Ask}) ->
    case erx_procfs_core:walk(Dir, Name, fun(Question) -> ask(Question, Ask) end) of
        {ok, Node} -> {ok, Node, qid(Node)};
        {error, _} = Error -> Error
    end;
walk(_Node, _Name, _Fs) ->
    {error, enotdir}.

-doc false.
getattr({dir, _} = Node, _Fs) -> erx_fs_node:attr(qid(Node), dir, 8#555);
getattr(Node, _Fs) -> erx_fs_node:attr(qid(Node), file, 8#444).

-doc false.
open(Node, Flags, #{ask := Ask, snapshots := Snapshots}) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> counted(Snapshots, fun() -> snapshot(Node, Ask) end);
        _ -> {error, erofs}
    end.

%% Takes one of the grant's snapshots for TakeSnapshot's answer, and gives
%% it back when there is no snapshot to hold. Opens and clunks run only in
%% the grant's process, the counter's one user, so the read and the add
%% cannot race another add. A crash in the
%% inspector or the renderer answers eio, so it neither leaks a snapshot nor
%% ends the grant.
counted(Snapshots, TakeSnapshot) ->
    case counters:get(Snapshots, 1) < ?MAX_SNAPSHOTS of
        true ->
            counters:add(Snapshots, 1, 1),
            case taken(TakeSnapshot) of
                {ok, _Handle} = Opened ->
                    Opened;
                {error, _} = Error ->
                    counters:sub(Snapshots, 1, 1),
                    Error
            end;
        false ->
            {error, emfile}
    end.

taken(TakeSnapshot) ->
    try TakeSnapshot()
    catch
        _:_ -> {error, eio}
    end.

snapshot({dir, Path}, Ask) ->
    Lookup = fun(Question) -> ask(Question, Ask) end,
    Entries = erx_procfs_core:listing(Path, listing_answer(Path, Ask), Lookup),
    {ok, erx_fs_node:listing([{qid(Child), dirent_type(Child), Name} || {Name, Child} <- Entries])};
snapshot({status, Path}, Ask) ->
    Answer = Ask({inspect, Path, #{}}),
    case erx_procfs_core:named(Answer) of
        true -> {ok, {bytes, erx_procfs_core:status(Answer, build(Ask))}};
        false -> {error, enoent}
    end;
snapshot({lines, Path}, Ask) ->
    [First | _] = Answers = pages(Path, 0, Ask, ?MAX_PAGES, 0),
    case erx_procfs_core:named(First) of
        true -> {ok, {bytes, erx_procfs_core:lines(Answers)}};
        false -> {error, enoent}
    end;
snapshot({Marker, Path}, Ask) ->
    {ok, {bytes, erx_procfs_core:marker(Marker, ask({listing, Path}, Ask))}}.

%% The inspector's answers for an append-only path's pages from Offset on:
%% the next page is asked from where a partial one stopped, up to Left
%% pages, and only while the entries so far, Bytes of values, fit the
%% file, since each entry's line is at least its value's bytes.
pages(Path, Offset, Ask, Left, Bytes) ->
    case Ask({inspect, Path, #{offset => Offset}}) of
        {ok, #{entries := {partial, Next, Entries}}} = Answer when Left > 1 ->
            Held = Bytes + lists:sum([byte_size(Value) || {_Sequence, Value} <- Entries]),
            case Held < ?MAX_FILE of
                true -> [Answer | pages(Path, Next, Ask, Left - 1, Held)];
                false -> [Answer]
            end;
        Answer ->
            [Answer]
    end.

%% The inspector's answer for a directory's listing, asked only of a
%% directory that lists the inspector's entries.
listing_answer(Path, Ask) ->
    case erx_procfs_core:lists_entries(Path) of
        true -> ask({listing, Path}, Ask);
        false -> none
    end.

-doc false.
read({bytes, Bytes}, Offset, _Count, _Fs) when Offset >= byte_size(Bytes) ->
    {ok, <<>>};
read({bytes, Bytes}, Offset, Count, _Fs) ->
    {ok, binary:part(Bytes, Offset, min(Count, byte_size(Bytes) - Offset))};
read({entries, _}, _Offset, _Count, _Fs) ->
    {error, eisdir}.

-doc false.
readdir(Handle, Offset, Max, _Fs) ->
    erx_fs_node:readdir(Handle, Offset, Max).

-doc false.
statfs(_Fs) ->
    erx_fs_node:statfs(?ERX_P9_MAGIC_PROCFS).

-doc false.
clunk(_Handle, #{snapshots := Snapshots}) ->
    counters:sub(Snapshots, 1, 1),
    ok.


%% ---------------------------------------------------------------------------
%% The inspector's answers
%% ---------------------------------------------------------------------------

%% The inspector's answer for erx_procfs_core's question: whether a walk
%% asks if a path names something or a directory asks for its listing, the
%% path's record, and for a directory's literal children the literals
%% query. The tree keeps no scope and decides nothing itself, so each is
%% what the domain's inspect facet answers.
ask({Question, Path}, Ask) when Question =:= exists; Question =:= listing ->
    Ask({inspect, Path, #{}});
ask({literals, Path}, Ask) ->
    Ask({literals, Path}).

%% Which build's projection a status file shows: development only when
%% the kernel reports the machine as a development build, as erx:i/1 does.
build(Ask) ->
    case Ask({inspect, [], #{}}) of
        {ok, #{attrs := #{development := {kernel, {ok, true}}}}} -> development;
        _ -> release
    end.

%% A qid's path is a 64-bit hash of the node, the same for the node in
%% every grant.
qid(Node) ->
    Path = (erlang:phash2({erx_procfs, high, Node}, 1 bsl 32) bsl 32)
        bor erlang:phash2({erx_procfs, low, Node}, 1 bsl 32),
    {qid_type(Node), 0, Path}.

qid_type({dir, _}) -> ?ERX_P9_QTDIR;
qid_type(_File) -> 0.

dirent_type({dir, _}) -> ?ERX_P9_DT_DIR;
dirent_type(_File) -> ?ERX_P9_DT_REG.
