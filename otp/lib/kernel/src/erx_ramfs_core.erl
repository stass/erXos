%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ramfs_core).
-moduledoc """
The tree of a domain's `/tmp` as one plain value, and the one pure function
that changes it (docs/design-tmp.md).

`step/4` takes a request, a stamp drawn from the domain's file version
counter and the time, and returns the reply and the next tree. Each request
is one callback of `erx_fs` decided whole: every check runs first, then the
step's change of the byte charge is computed and compared with the cap, and
only then is anything built. A refused step returns the tree it was given,
which `step/4` enforces by construction: an operation that refuses answers
`{error, Posix}` alone and never holds a tree to return. A truncation, by
`open` with `trunc` or by `setattr` of size, computes its charge while it
builds; it only ever frees, so it needs no comparison with the cap.

Nodes are named by inode numbers, the stamps of their creation, so a number
is never given to a second node and a request naming a node that is gone
answers `enoent`. A node lives while a directory entry names it (`links`)
or an open holds it (`opens`), and the step that brings both to zero frees
it and returns its charge. A directory's `links` count its name, its own
`.` and each subdirectory's `..`, as tmpfs counts them. File data is a map
from 4 KiB chunk index to chunk; a missing chunk is a hole and reads as
zeros.

Requests and replies speak the core's own terms: kinds are atoms, open
flags are `{Access, Options}` and attribute changes a map of the fields
set. `erx_ramfs` turns 9P2000.L's integers into them and the replies back,
with the constants of the generated protocol module, so no wire constant is
copied here. The tree parses no bytes: names, texts and data reach it only
through `erx_fs`'s grammar, and the checks here keep the step total over
anything else.
""".

-export([new/3, step/4, check/1, held/1]).

-export_type([tree/0, ino/0, request/0, reply/0, handle/0, qid/0]).

%% Charges (docs/design-tmp.md, "Charges"): what the cap bounds.
-define(CHUNK_BYTES, 4096).
-define(NODE_CHARGE, 256).
-define(ENTRY_CHARGE, 64).
-define(ZERO_CHUNK, <<0:(?CHUNK_BYTES * 8)>>).

%% Linux's limits: tmpfs's largest file, NAME_MAX, PATH_MAX less its NUL.
-define(MAX_SIZE, ((1 bsl 63) - 1)).
-define(MAX_NAME, 255).
-define(MAX_LINK_TEXT, 4095).
%% The most one read returns and one listing page holds, the protocol's
%% bounds; a larger request gets a short answer, as Linux caps a read.
-define(MAX_READ, 65536).
-define(MAX_LISTING, 256).

%% tmpfs's default root mode, and the mode Linux gives every link.
-define(ROOT_MODE, 8#1777).
-define(LINK_MODE, 8#777).
-define(MODE_BITS, 8#7777).
%% The owner's permission bits: the domain is one user who owns every file.
-define(R, 8#400).
-define(W, 8#200).
-define(X, 8#100).

-type ino() :: pos_integer().
-type name() :: binary().
-type kind() :: file | directory | symlink.
-type access() :: read | write | read_write.
-type option() :: trunc | append | excl | directory.
-type open_flags() :: {access(), [option()]}.
-type handle() :: {ino(), access(), Append :: boolean()}.
-type qid() :: {kind(), Version :: pos_integer(), ino()}.
-type what() :: {file, Mode :: non_neg_integer(), open_flags()}
              | {directory, Mode :: non_neg_integer()}
              | {symlink, Text :: binary()}
              | {link, ino()}
              | {node, term(), term(), term()}.
-type changes() :: #{mode => non_neg_integer(), uid => integer(),
                     gid => integer(), size => integer(),
                     atime => now | integer(), mtime => now | integer()}.

-type request() :: {walk, Dir :: ino(), name()}
                 | {getattr, ino()}
                 | {open, ino(), open_flags()}
                 | {make, Dir :: ino(), name(), what()}
                 | {read, handle(), Offset :: integer(), Count :: integer()}
                 | {write, handle(), Offset :: integer(), Data :: binary()}
                 | {readdir, handle(), Offset :: integer(), Max :: integer()}
                 | {readlink, ino()}
                 | {setattr, {open, handle()} | {node, ino()}, changes()}
                 | {unlink, Dir :: ino(), name(), file | directory | {node, ino()}}
                 | {rename, Dir :: ino(), name(), NewDir :: ino(), name()}
                 | {fsync, handle()}
                 | {clunk, handle()}
                 | statfs
                 | {xattr, ino(), term()}.

-type reply() :: ok
               | {ok, ino(), qid()}
               | {ok, ino(), qid(), handle()}
               | {ok, handle()}
               | {ok, map()}
               | {ok, binary()}
               | {ok, Count :: non_neg_integer(), At :: non_neg_integer()}
               | {ok, [{qid(), Seq :: pos_integer(), name()}]}
               | {error, file:posix()}.

-record(node, {
    data :: {file, Chunks :: #{non_neg_integer() => binary()}}
          | {directory, Parent :: ino() | none,
             Entries :: #{name() => {ino(), Seq :: pos_integer()}},
             Order :: gb_trees:tree(pos_integer(), name()),
             NextSeq :: pos_integer()}
          | {symlink, Text :: binary()},
    mode :: 0..?MODE_BITS,
    links :: non_neg_integer(),
    opens :: non_neg_integer(),
    size :: 0..?MAX_SIZE,
    atime :: integer(),
    mtime :: integer(),
    ctime :: integer(),
    version :: pos_integer()
}).

-record(tree, {
    nodes :: #{ino() => #node{}},
    root :: ino(),
    held :: non_neg_integer(),
    cap :: non_neg_integer()
}).

-opaque tree() :: #tree{}.

%% ---------------------------------------------------------------------------
%% The interface
%% ---------------------------------------------------------------------------

-doc """
An empty tree whose root takes `Stamp` as its inode number, under a cap of
`Cap` bytes of charges. The root costs nothing, so a cap of 0 makes a tree
that refuses every creation with `enospc`.
""".
-spec new(Cap :: non_neg_integer(), Stamp :: pos_integer(), Now :: integer()) ->
          tree().
new(Cap, Stamp, Now)
  when is_integer(Cap), Cap >= 0, is_integer(Stamp), Stamp > 0,
       is_integer(Now) ->
    Root = #node{data = {directory, Stamp, #{}, gb_trees:empty(), 1},
                 mode = ?ROOT_MODE, links = 2, opens = 0, size = 0,
                 atime = Now, mtime = Now, ctime = Now, version = Stamp},
    #tree{nodes = #{Stamp => Root}, root = Stamp, held = 0, cap = Cap}.

-doc """
One request decided whole. `Stamp` is a fresh value of the domain's file
version counter: a node the step makes takes it as its inode number and
version, and a node whose data, size or entries the step changes takes it as
its version. `Now` is the time in nanoseconds. A refused request answers
`{error, Posix}` with `Tree` unchanged; any term answers, the ones no
callback builds with `einval`.
""".
-spec step(Request :: term(), Stamp :: pos_integer(), Now :: integer(),
           tree()) -> {reply(), tree()}.
step(Request, Stamp, Now, #tree{} = Tree)
  when is_integer(Stamp), Stamp > 0, is_integer(Now) ->
    case decide(Request, Stamp, Now, Tree) of
        {done, Reply, Tree1} -> {Reply, Tree1};
        {error, _} = Refusal -> {Refusal, Tree}
    end;
step(_Request, _Stamp, _Now, Tree) ->
    {{error, einval}, Tree}.

-doc """
The bytes the tree is charged for, as `check/1` recomputes them.
""".
-spec held(tree()) -> non_neg_integer().
held(#tree{held = Held}) ->
    Held.

-doc """
Recomputes the tree's invariants from its nodes (docs/design-tmp.md, T2-T4)
and answers `ok` or every violation found: `held` against the charges of
what the tree holds and the cap; each node's shape, chunks inside its size
and zero past it, names and texts valid and holding no larger binary; each
`links` against the entries naming it; every nameless node open, every
nameless directory empty; every named directory's parents reaching the
root. It grows with the tree, so it runs in tests only.
""".
-spec check(tree()) -> ok | {error, [term()]}.
check(#tree{} = Tree) ->
    Checks = [fun check_root/1, fun check_held/1, fun check_shapes/1,
              fun check_links/1, fun check_parents/1],
    case lists:flatmap(fun(Check) -> Check(Tree) end, Checks) of
        [] -> ok;
        Problems -> {error, Problems}
    end.

%% ---------------------------------------------------------------------------
%% Dispatch: one clause per callback of erx_fs
%% ---------------------------------------------------------------------------

decide({walk, Dir, Name}, _Stamp, _Now, Tree) ->
    walk(Dir, Name, Tree);
decide({getattr, Ino}, _Stamp, _Now, Tree) ->
    getattr(Ino, Tree);
decide({open, Ino, Flags}, Stamp, Now, Tree) ->
    open(Ino, Flags, Stamp, Now, Tree);
decide({make, Dir, Name, What}, Stamp, Now, Tree) ->
    make(Dir, Name, What, Stamp, Now, Tree);
decide({read, Handle, Offset, Count}, _Stamp, _Now, Tree) ->
    read(Handle, Offset, Count, Tree);
decide({write, Handle, Offset, Data}, Stamp, Now, Tree) ->
    write(Handle, Offset, Data, Stamp, Now, Tree);
decide({readdir, Handle, Offset, Max}, _Stamp, _Now, Tree) ->
    readdir(Handle, Offset, Max, Tree);
decide({readlink, Ino}, _Stamp, _Now, Tree) ->
    readlink(Ino, Tree);
decide({setattr, Target, Changes}, Stamp, Now, Tree) ->
    setattr(Target, Changes, Stamp, Now, Tree);
decide({unlink, Dir, Name, Kind}, Stamp, Now, Tree) ->
    unlink(Dir, Name, Kind, Stamp, Now, Tree);
decide({rename, Dir, Name, NewDir, NewName}, Stamp, Now, Tree) ->
    rename(Dir, Name, NewDir, NewName, Stamp, Now, Tree);
decide({fsync, _Handle}, _Stamp, _Now, Tree) ->
    {done, ok, Tree};
decide({clunk, Handle}, _Stamp, _Now, Tree) ->
    clunk(Handle, Tree);
decide(statfs, _Stamp, _Now, Tree) ->
    {done, {ok, statfs(Tree)}, Tree};
decide({xattr, _Ino, _Op}, _Stamp, _Now, _Tree) ->
    %% The protocol's name for Linux's EOPNOTSUPP.
    {error, enotsup};
decide(_Request, _Stamp, _Now, _Tree) ->
    {error, einval}.

%% ---------------------------------------------------------------------------
%% Operations. Each answers {done, Reply, Tree1} or {error, Posix}; checks
%% run in Linux's order for the same call, so the first refusal is Linux's.
%% ---------------------------------------------------------------------------

walk(Dir, Name, Tree) ->
    maybe
        ok ?= valid_name(Name),
        {ok, D} ?= directory(Dir, Tree),
        ok ?= permitted(D, ?X),
        {ok, Ino} ?= lookup(D, Name),
        {done, {ok, Ino, qid(Ino, Tree)}, Tree}
    end.

getattr(Ino, Tree) ->
    maybe
        {ok, N} ?= node(Ino, Tree),
        {done, {ok, attr(Ino, N)}, Tree}
    end.

open(Ino, Flags, Stamp, Now, Tree) ->
    maybe
        {ok, Access, Options} ?= open_flags(Flags),
        {ok, N} ?= node(Ino, Tree),
        ok ?= has_a_name(N),
        ok ?= openable(N, Access, Options),
        {done, {ok, handle(Ino, Access, Options)},
         opened(Ino, N, Options, Stamp, Now, Tree)}
    end.

%% A device node is refused before anything is looked up: the tree keeps
%% none, whatever the request says.
make(_Dir, _Name, {node, _Mode, _Major, _Minor}, _Stamp, _Now, _Tree) ->
    {error, eperm};
make(Dir, Name, What, Stamp, Now, Tree) ->
    maybe
        ok ?= valid_what(What, Tree),
        ok ?= valid_name(Name),
        {ok, D} ?= directory(Dir, Tree),
        ok ?= permitted(D, ?X),
        case maps:find(Name, entries(D)) of
            {ok, {Ino, _Seq}} -> make_existing(Ino, What, Stamp, Now, Tree);
            error -> make_new(Dir, D, Name, What, Stamp, Now, Tree)
        end
    end.

%% lcreate without O_EXCL opens the regular file the name already names, in
%% the same step, so two openers of one new name reach one file.
make_existing(Ino, {file, _Mode, {Access, Options}}, Stamp, Now, Tree) ->
    N = fetch(Ino, Tree),
    case {lists:member(excl, Options), kind(N)} of
        {true, _} -> {error, eexist};
        {false, symlink} -> {error, eloop};
        {false, directory} -> {error, eisdir};
        {false, file} ->
            maybe
                ok ?= openable(N, Access, Options),
                Tree1 = opened(Ino, N, Options, Stamp, Now, Tree),
                {done, {ok, Ino, qid(Ino, Tree1), handle(Ino, Access, Options)},
                 Tree1}
            end
    end;
make_existing(_Ino, _What, _Stamp, _Now, _Tree) ->
    {error, eexist}.

make_new(Dir, D, Name, What, Stamp, Now, Tree) ->
    maybe
        ok ?= named(D),
        ok ?= permitted(D, ?W bor ?X),
        ok ?= linkable(What, Tree),
        ok ?= unused_stamp(What, Stamp, Tree),
        Charge = entry_charge(Name) + node_charge_of(What),
        ok ?= fits(Charge, Tree),
        {done, made_reply(What, Name, Stamp, Tree),
         charged(Charge, created(Dir, Name, What, Stamp, Now, Tree))}
    end.

made_reply({file, _Mode, {Access, Options}}, _Name, Stamp, _Tree) ->
    {ok, Stamp, {file, Stamp, Stamp}, handle(Stamp, Access, Options)};
made_reply({directory, _Mode}, _Name, Stamp, _Tree) ->
    {ok, Stamp, {directory, Stamp, Stamp}};
made_reply({symlink, _Text}, _Name, Stamp, _Tree) ->
    {ok, Stamp, {symlink, Stamp, Stamp}};
made_reply({link, Ino}, _Name, _Stamp, Tree) ->
    %% A link changes the node's ctime, not its data, so its version stays.
    {ok, Ino, qid(Ino, Tree)}.

read(Handle, Offset, Count, Tree) ->
    maybe
        {ok, _Ino, N, _Append} ?= opened_for(Handle, read, Tree),
        ok ?= is_file(N),
        ok ?= non_negative([Offset, Count]),
        End = min(Offset + min(Count, ?MAX_READ), N#node.size),
        {done, {ok, bytes(N, Offset, End)}, Tree}
    end.

%% Linux's limits: an offset at or past tmpfs's largest file is EFBIG, and a
%% write that would cross it is cut short there. A write of no bytes
%% changes nothing.
write(Handle, Offset, Data, Stamp, Now, Tree) ->
    maybe
        {ok, Ino, N, Append} ?= opened_for(Handle, write, Tree),
        ok ?= is_file(N),
        ok ?= non_negative([Offset]),
        true ?= is_binary(Data) orelse {error, einval},
        At = case Append of
                 true -> N#node.size;
                 false -> Offset
             end,
        if
            byte_size(Data) =:= 0 -> {done, {ok, 0, At}, Tree};
            At >= ?MAX_SIZE -> {error, efbig};
            true -> written(Ino, N, At, Data, Stamp, Now, Tree)
        end
    end.

written(Ino, #node{data = {file, Chunks}} = N, At, Data, Stamp, Now, Tree) ->
    Bytes = binary_part(Data, 0, min(byte_size(Data), ?MAX_SIZE - At)),
    End = At + byte_size(Bytes),
    Touched = lists:seq(At div ?CHUNK_BYTES, (End - 1) div ?CHUNK_BYTES),
    %% Only chunks that do not exist cost anything: overwriting is free.
    New = length([I || I <- Touched, not is_map_key(I, Chunks)]),
    Charge = New * ?CHUNK_BYTES,
    maybe
        ok ?= fits(Charge, Tree),
        Chunks1 = lists:foldl(
                    fun(I, Acc) ->
                            Old = maps:get(I, Chunks, ?ZERO_CHUNK),
                            Acc#{I => spliced(Old, I, At, Bytes)}
                    end, Chunks, Touched),
        N1 = N#node{data = {file, Chunks1}, size = max(N#node.size, End),
                    mtime = Now, ctime = Now, version = Stamp},
        {done, {ok, byte_size(Bytes), At},
         charged(Charge, put_node(Ino, N1, Tree))}
    end.

readdir(Handle, Offset, Max, Tree) ->
    maybe
        {ok, _Ino, N, _Append} ?= opened_for(Handle, read, Tree),
        {directory, _Parent, Entries, Order, _Next} ?=
            case N#node.data of
                {directory, _, _, _, _} = Data -> Data;
                _ -> {error, enotdir}
            end,
        ok ?= non_negative([Offset]),
        true ?= (is_integer(Max) andalso Max >= 1) orelse {error, einval},
        Iterator = gb_trees:iterator_from(Offset + 1, Order),
        Page = listing(Iterator, min(Max, ?MAX_LISTING), Entries, Tree, []),
        {done, {ok, Page}, Tree}
    end.

listing(_Iterator, 0, _Entries, _Tree, Acc) ->
    lists:reverse(Acc);
listing(Iterator, Left, Entries, Tree, Acc) ->
    case gb_trees:next(Iterator) of
        none ->
            lists:reverse(Acc);
        {Seq, Name, Iterator1} ->
            {Ino, Seq} = maps:get(Name, Entries),
            listing(Iterator1, Left - 1, Entries, Tree,
                    [{qid(Ino, Tree), Seq, Name} | Acc])
    end.

readlink(Ino, Tree) ->
    maybe
        {ok, N} ?= node(Ino, Tree),
        case N#node.data of
            {symlink, Text} -> {done, {ok, Text}, Tree};
            _ -> {error, einval}
        end
    end.

%% A size change through an opened fid needs the fid opened for writing, as
%% ftruncate does; through an unopened one, the file's w bit, as truncate
%% does. An owner or group of 0, the file's own, changes only ctime.
setattr(Target, Changes, Stamp, Now, Tree) ->
    maybe
        {ok, Ino, N, Via} ?= setattr_target(Target, Tree),
        ok ?= valid_changes(Changes),
        ok ?= own_owner(Changes),
        ok ?= size_settable(Changes, N, Via),
        {N1, Charge} = case Changes of
                           #{size := Size} -> resize(N, Size, Stamp, Now);
                           #{} -> {N, 0}
                       end,
        Mode = maps:get(mode, Changes, N1#node.mode) band ?MODE_BITS,
        N2 = N1#node{mode = Mode,
                     atime = time_change(atime, Changes, N1#node.atime, Now),
                     mtime = time_change(mtime, Changes, N1#node.mtime, Now),
                     ctime = Now},
        {done, ok, charged(Charge, put_node(Ino, N2, Tree))}
    end.

unlink(Dir, Name, Kind, Stamp, Now, Tree) ->
    maybe
        ok ?= valid_kind(Kind),
        ok ?= valid_name(Name),
        {ok, D} ?= directory(Dir, Tree),
        ok ?= permitted(D, ?X),
        {ok, Ino} ?= lookup(D, Name),
        ok ?= still_names(Kind, Ino),
        ok ?= permitted(D, ?W bor ?X),
        Victim = fetch(Ino, Tree),
        ok ?= removable_kind(Kind, Victim),
        ok ?= empty_if_directory(Victim),
        Charge = -entry_charge(Name) - freed_by_unnaming(Victim),
        Tree1 = update(Dir, fun(P) -> changed(remove_entry(P, Name), Stamp, Now) end,
                       Tree),
        {done, ok, charged(Charge, drop_name(Ino, Dir, Now, Tree1))}
    end.

%% Linux's order: the parents, the source, a directory moved below itself
%% (EINVAL), a target that holds the source (ENOTEMPTY), the same node
%% under both names (nothing to do, before any permission), then the
%% permissions and kinds of what is removed and added, the moved
%% directory's own w, and last a non-empty target directory (ENOTEMPTY).
rename(Dir, Name, NewDir, NewName, Stamp, Now, Tree) ->
    maybe
        ok ?= valid_name(Name),
        ok ?= valid_name(NewName),
        {ok, D} ?= directory(Dir, Tree),
        ok ?= permitted(D, ?X),
        {ok, ND} ?= directory(NewDir, Tree),
        ok ?= permitted(ND, ?X),
        {ok, Ino} ?= lookup(D, Name),
        Moved = fetch(Ino, Tree),
        ok ?= not_below_itself(Ino, Moved, NewDir, Tree),
        Target = maps:find(NewName, entries(ND)),
        ok ?= not_holding_source(Target, Dir, Tree),
        %% The same node under both names: done, with nothing changed.
        false ?= same_node(Target, Ino) andalso {done, ok, Tree},
        ok ?= permitted(D, ?W bor ?X),
        {ok, Replaced} ?= replaceable(Target, Moved, NewDir, ND, Tree),
        ok ?= movable(Moved, Dir, NewDir),
        ok ?= empty_if_replaced_directory(Replaced, Tree),
        %% The new name's entry is paid for, the old one's returned, and a
        %% replaced node's name and, if that frees it, the node itself.
        Charge = entry_charge(NewName) - entry_charge(Name)
            - replaced_charge(Replaced, NewName, Tree),
        ok ?= fits(Charge, Tree),
        Move = #{dir => Dir, name => Name, ino => Ino, moved => Moved,
                 new_dir => NewDir, new_name => NewName, replaced => Replaced},
        {done, ok, charged(Charge, renamed(Move, Stamp, Now, Tree))}
    end.

%% Renaming a name to another name of its own node does nothing.
same_node({ok, {Ino, _Seq}}, Ino) -> true;
same_node(_Target, _Ino) -> false.

%% The rename's changes, applied in this order because Dir and NewDir may
%% be one directory: both names leave first, the source's and then the
%% replaced target's, so the name that arrives meets no old entry; then
%% the moved directory's ".." follows it, and the times and versions are
%% set last on what the steps before left.
renamed(#{dir := Dir, name := Name, ino := Ino, moved := Moved,
          new_dir := NewDir, new_name := NewName, replaced := Replaced},
        Stamp, Now, Tree) ->
    Steps = [fun(T) -> update(Dir, fun(P) -> remove_entry(P, Name) end, T) end,
             fun(T) -> unname_replaced(Replaced, NewDir, NewName, Now, T) end,
             fun(T) -> update(NewDir, fun(P) -> add_entry(P, NewName, Ino) end, T) end,
             fun(T) -> moved_parent(Ino, Moved, Dir, NewDir, T) end,
             fun(T) -> update(Ino, fun(M) -> M#node{ctime = Now} end, T) end,
             fun(T) -> update(Dir, fun(P) -> changed(P, Stamp, Now) end, T) end,
             fun(T) -> update(NewDir, fun(P) -> changed(P, Stamp, Now) end, T) end],
    lists:foldl(fun(Step, T) -> Step(T) end, Tree, Steps).

%% The handle came from open or make, and erx_fs clunks each exactly once;
%% a clunk of a node already gone, or not open, changes nothing.
clunk({Ino, _Access, _Append}, #tree{nodes = Nodes} = Tree) ->
    case Nodes of
        #{Ino := #node{opens = Opens} = N} when Opens > 0 ->
            N1 = N#node{opens = Opens - 1},
            {done, ok, charged(-freed_charge(N1), release(Ino, N1, Tree))};
        #{} ->
            {done, ok, Tree}
    end;
clunk(_Handle, Tree) ->
    {done, ok, Tree}.

%% files - ffree is the nodes in use, as df -i shows.
statfs(#tree{nodes = Nodes, held = Held, cap = Cap}) ->
    Free = max(0, Cap - Held),
    FreeNodes = Free div ?NODE_CHARGE,
    #{bsize => ?CHUNK_BYTES, blocks => Cap div ?CHUNK_BYTES,
      bfree => Free div ?CHUNK_BYTES, bavail => Free div ?CHUNK_BYTES,
      files => map_size(Nodes) + FreeNodes, ffree => FreeNodes,
      namelen => ?MAX_NAME}.

%% ---------------------------------------------------------------------------
%% Checks on requests
%% ---------------------------------------------------------------------------

valid_name(Name) when not is_binary(Name) -> {error, einval};
valid_name(<<>>) -> {error, enoent};
valid_name(Name) when byte_size(Name) > ?MAX_NAME -> {error, enametoolong};
valid_name(<<".">>) -> {error, einval};
valid_name(<<"..">>) -> {error, einval};
valid_name(Name) ->
    case binary:match(Name, [<<"/">>, <<0>>]) of
        nomatch -> ok;
        _ -> {error, einval}
    end.

%% What a make carries, checked before the directory, as Linux checks a
%% link's text when it copies it in.
valid_what({file, Mode, Flags}, _Tree) when is_integer(Mode) ->
    case open_flags(Flags) of
        {ok, _Access, Options} ->
            %% Linux refuses O_CREAT with O_DIRECTORY.
            case lists:member(directory, Options) of
                true -> {error, einval};
                false -> ok
            end;
        Error -> Error
    end;
valid_what({directory, Mode}, _Tree) when is_integer(Mode) -> ok;
valid_what({symlink, Text}, _Tree) -> valid_link_text(Text);
valid_what({link, Ino}, Tree) ->
    case node(Ino, Tree) of
        {ok, _} -> ok;
        Error -> Error
    end;
valid_what(_What, _Tree) ->
    {error, einval}.

%% Linux's symlink: an empty text is ENOENT, one past PATH_MAX ENAMETOOLONG.
valid_link_text(<<>>) -> {error, enoent};
valid_link_text(Text) when is_binary(Text), byte_size(Text) > ?MAX_LINK_TEXT ->
    {error, enametoolong};
valid_link_text(Text) when is_binary(Text) ->
    case binary:match(Text, <<0>>) of
        nomatch -> ok;
        _ -> {error, einval}
    end;
valid_link_text(_Text) ->
    {error, einval}.

open_flags({Access, Options})
  when Access =:= read; Access =:= write; Access =:= read_write ->
    case known_options(Options) of
        true -> {ok, Access, Options};
        false -> {error, einval}
    end;
open_flags(_Flags) ->
    {error, einval}.

%% Walks the list itself, so an improper list answers false.
known_options([]) -> true;
known_options([Option | Rest])
  when Option =:= trunc; Option =:= append; Option =:= excl;
       Option =:= directory ->
    known_options(Rest);
known_options(_) -> false.

%% Linux's do_open: a directory opened to write or truncate is EISDIR, a
%% file asked to be a directory ENOTDIR, both before the permission check.
openable(#node{data = {symlink, _}}, _Access, _Options) ->
    {error, eloop};
openable(#node{data = {directory, _, _, _, _}} = N, Access, Options) ->
    case Access =:= read andalso not lists:member(trunc, Options) of
        true -> permitted(N, ?R);
        false -> {error, eisdir}
    end;
openable(#node{data = {file, _}} = N, Access, Options) ->
    case lists:member(directory, Options) of
        true -> {error, enotdir};
        false -> permitted(N, access_bits(Access, Options))
    end.

access_bits(Access, Options) ->
    Bits = case Access of
               read -> ?R;
               write -> ?W;
               read_write -> ?R bor ?W
           end,
    case lists:member(trunc, Options) of
        true -> Bits bor ?W;
        false -> Bits
    end.

handle(Ino, Access, Options) ->
    {Ino, Access, lists:member(append, Options)}.

%% A handle's node, if the handle was opened for Need.
opened_for({Ino, Access, Append}, Need, Tree) when is_boolean(Append) ->
    case allows(Access, Need) of
        true ->
            case node(Ino, Tree) of
                {ok, N} -> {ok, Ino, N, Append};
                {error, enoent} -> {error, ebadf}
            end;
        false ->
            {error, ebadf}
    end;
opened_for(_Handle, _Need, _Tree) ->
    {error, ebadf}.

allows(read_write, _Need) -> true;
allows(read, read) -> true;
allows(write, write) -> true;
%% any: whatever the handle was opened for, as long as it is an access.
allows(Access, any) -> Access =:= read orelse Access =:= write;
allows(_Access, _Need) -> false.

is_file(#node{data = {file, _}}) -> ok;
is_file(#node{data = {directory, _, _, _, _}}) -> {error, eisdir};
is_file(#node{}) -> {error, einval}.

non_negative(Values) ->
    case lists:all(fun(V) -> is_integer(V) andalso V >= 0 end, Values) of
        true -> ok;
        false -> {error, einval}
    end.

setattr_target({open, Handle}, Tree) ->
    maybe
        {ok, Ino, N, _Append} ?= opened_for(Handle, any, Tree),
        {Ino, Access, _} = Handle,
        {ok, Ino, N, {open, Access}}
    end;
setattr_target({node, Ino}, Tree) ->
    maybe
        {ok, N} ?= node(Ino, Tree),
        {ok, Ino, N, node}
    end;
setattr_target(_Target, _Tree) ->
    {error, einval}.

valid_changes(Changes) when is_map(Changes) ->
    Valid = fun(mode, V) -> is_integer(V);
               (uid, V) -> is_integer(V);
               (gid, V) -> is_integer(V);
               (size, V) -> is_integer(V);
               (atime, V) -> V =:= now orelse is_integer(V);
               (mtime, V) -> V =:= now orelse is_integer(V);
               (_Key, _V) -> false
            end,
    case maps:fold(fun(K, V, Ok) -> Ok andalso Valid(K, V) end, true, Changes) of
        true -> ok;
        false -> {error, einval}
    end;
valid_changes(_Changes) ->
    {error, einval}.

own_owner(Changes) ->
    case maps:get(uid, Changes, 0) =:= 0 andalso maps:get(gid, Changes, 0) =:= 0 of
        true -> ok;
        false -> {error, eperm}
    end.

%% Linux's truncate and ftruncate: a negative size, then the kind, then the
%% access, then a size past tmpfs's largest file.
size_settable(#{size := Size}, N, Via) ->
    Kind = kind(N),
    if
        Size < 0 -> {error, einval};
        Kind =:= directory -> {error, eisdir};
        Kind =/= file -> {error, einval};
        Via =:= {open, read} -> {error, einval};
        Via =:= node, N#node.mode band ?W =:= 0 -> {error, eacces};
        Size > ?MAX_SIZE -> {error, efbig};
        true -> ok
    end;
size_settable(#{}, _N, _Via) ->
    ok.

time_change(Field, Changes, Old, Now) ->
    case maps:get(Field, Changes, Old) of
        now -> Now;
        Time -> Time
    end.

removable_kind(directory, Victim) ->
    case kind(Victim) of
        directory -> ok;
        _ -> {error, enotdir}
    end;
removable_kind(file, Victim) ->
    case kind(Victim) of
        directory -> {error, eisdir};
        _ -> ok
    end;
removable_kind({node, _Ino}, _Victim) ->
    ok.

valid_kind(file) -> ok;
valid_kind(directory) -> ok;
valid_kind({node, Ino}) when is_integer(Ino) -> ok;
valid_kind(_) -> {error, einval}.

%% remove names the node its fid stands at: the entry is removed only while
%% it still names that node, so a remove never takes a name that a rename or
%% a create gave another node since the fid was walked.
still_names({node, Ino}, Found) when Ino =/= Found -> {error, enoent};
still_names(_Kind, _Found) -> ok.

%% A node no name reaches opens nothing, as an open after its unlink would
%% not find it; an open made before the unlink keeps working.
has_a_name(#node{links = 0}) -> {error, enoent};
has_a_name(#node{}) -> ok.

empty_if_directory(#node{data = {directory, _, Entries, _, _}})
  when map_size(Entries) > 0 ->
    {error, enotempty};
empty_if_directory(#node{}) ->
    ok.

%% A directory with no name takes no new one. The root's parent is itself.
named(#node{data = {directory, none, _, _, _}}) -> {error, enoent};
named(#node{}) -> ok.

%% A hard link is to a file or a link that still has a name (Linux's
%% vfs_link: EPERM for a directory, ENOENT for a node with no links).
linkable({link, Ino}, Tree) ->
    case fetch(Ino, Tree) of
        #node{data = {directory, _, _, _, _}} -> {error, eperm};
        #node{links = 0} -> {error, enoent};
        #node{} -> ok
    end;
linkable(_What, _Tree) ->
    ok.

%% The counter never repeats a stamp; a repeated one is refused rather than
%% let it overwrite a node.
unused_stamp({link, _Ino}, _Stamp, _Tree) ->
    ok;
unused_stamp(_What, Stamp, #tree{nodes = Nodes}) ->
    case is_map_key(Stamp, Nodes) of
        true -> {error, eio};
        false -> ok
    end.

%% A directory moved into itself or below itself would leave the tree.
not_below_itself(Ino, #node{data = {directory, _, _, _, _}}, NewDir, Tree) ->
    case ancestor(Ino, NewDir, Tree) of
        true -> {error, einval};
        false -> ok
    end;
not_below_itself(_Ino, #node{}, _NewDir, _Tree) ->
    ok.

%% A target that is the source's directory or one of its ancestors is not
%% empty: it holds the source (Linux's lock_rename trap).
not_holding_source({ok, {Target, _Seq}}, Dir, Tree) ->
    case kind(fetch(Target, Tree)) =:= directory
        andalso ancestor(Target, Dir, Tree) of
        true -> {error, enotempty};
        false -> ok
    end;
not_holding_source(error, _Dir, _Tree) ->
    ok.

%% What a rename removes at the new name, checked as Linux's may_delete or
%% may_create on the new directory.
replaceable(error, _Moved, _NewDir, ND, _Tree) ->
    maybe
        ok ?= named(ND),
        ok ?= permitted(ND, ?W bor ?X),
        {ok, none}
    end;
replaceable({ok, {Target, _Seq}}, Moved, _NewDir, ND, Tree) ->
    Replaced = fetch(Target, Tree),
    maybe
        ok ?= permitted(ND, ?W bor ?X),
        ok ?= case {kind(Moved), kind(Replaced)} of
                  {directory, directory} -> ok;
                  {directory, _} -> {error, enotdir};
                  {_, directory} -> {error, eisdir};
                  _ -> ok
              end,
        {ok, Target}
    end.

empty_if_replaced_directory(none, _Tree) -> ok;
empty_if_replaced_directory(Replaced, Tree) -> empty_if_directory(fetch(Replaced, Tree)).

%% A directory that changes parent rewrites its "..", which Linux's
%% vfs_rename checks as a write to the directory.
movable(#node{data = {directory, _, _, _, _}} = Moved, Dir, NewDir)
  when Dir =/= NewDir ->
    permitted(Moved, ?W);
movable(#node{}, _Dir, _NewDir) ->
    ok.

directory(Ino, Tree) ->
    case node(Ino, Tree) of
        {ok, #node{data = {directory, _, _, _, _}} = D} -> {ok, D};
        {ok, #node{}} -> {error, enotdir};
        Error -> Error
    end.

permitted(#node{mode = Mode}, Bits) ->
    case Mode band Bits of
        Bits -> ok;
        _ -> {error, eacces}
    end.

lookup(D, Name) ->
    case maps:find(Name, entries(D)) of
        {ok, {Ino, _Seq}} -> {ok, Ino};
        error -> {error, enoent}
    end.

%% Whether Ancestor is Ino or above it. The walk follows parents toward the
%% root and is a loop, not a recursion of the stack; it takes at most one
%% step per node, and refuses (answers true) if the chain were ever longer,
%% which only a broken tree could make it.
ancestor(Ancestor, Ino, #tree{nodes = Nodes} = Tree) ->
    ancestor(Ancestor, Ino, map_size(Nodes), Tree).

ancestor(Ancestor, Ancestor, _Fuel, _Tree) ->
    true;
ancestor(_Ancestor, _Ino, 0, _Tree) ->
    true;
ancestor(Ancestor, Ino, Fuel, #tree{root = Root} = Tree) ->
    case fetch(Ino, Tree) of
        #node{data = {directory, Parent, _, _, _}}
          when Ino =/= Root, Parent =/= none ->
            ancestor(Ancestor, Parent, Fuel - 1, Tree);
        #node{} ->
            false
    end.

%% ---------------------------------------------------------------------------
%% Charges, computed before anything is built
%% ---------------------------------------------------------------------------

fits(Charge, #tree{held = Held, cap = Cap}) ->
    case Held + Charge =< Cap of
        true -> ok;
        false -> {error, enospc}
    end.

charged(Charge, #tree{held = Held} = Tree) ->
    Tree#tree{held = Held + Charge}.

entry_charge(Name) ->
    ?ENTRY_CHARGE + byte_size(Name).

%% A node's own charge: the node, its chunks and its link text.
node_charge(#node{data = {file, Chunks}}) ->
    ?NODE_CHARGE + map_size(Chunks) * ?CHUNK_BYTES;
node_charge(#node{data = {symlink, Text}}) ->
    ?NODE_CHARGE + byte_size(Text);
node_charge(#node{}) ->
    ?NODE_CHARGE.

node_charge_of({file, _Mode, _Flags}) -> ?NODE_CHARGE;
node_charge_of({directory, _Mode}) -> ?NODE_CHARGE;
node_charge_of({symlink, Text}) -> ?NODE_CHARGE + byte_size(Text);
node_charge_of({link, _Ino}) -> 0.

%% The charge a node returns when it is freed: all of it once it has no
%% links and no opens.
freed_charge(#node{links = 0, opens = 0} = N) -> node_charge(N);
freed_charge(#node{}) -> 0.

%% The charge removing one name of a node frees: a directory loses every
%% link with its one name.
freed_by_unnaming(#node{data = {directory, _, _, _, _}} = N) ->
    freed_charge(N#node{links = 0});
freed_by_unnaming(#node{links = Links} = N) ->
    freed_charge(N#node{links = Links - 1}).

replaced_charge(none, _NewName, _Tree) ->
    0;
replaced_charge(Target, NewName, Tree) ->
    entry_charge(NewName) + freed_by_unnaming(fetch(Target, Tree)).

%% ---------------------------------------------------------------------------
%% Building: runs only after the step's checks and charge passed
%% ---------------------------------------------------------------------------

opened(Ino, N, Options, Stamp, Now, Tree) ->
    N1 = N#node{opens = N#node.opens + 1},
    case lists:member(trunc, Options) andalso kind(N1) =:= file of
        true ->
            {N2, Charge} = resize(N1, 0, Stamp, Now),
            charged(Charge, put_node(Ino, N2, Tree));
        false ->
            put_node(Ino, N1, Tree)
    end.

%% The node the new name names, then the name in Dir; a new directory's
%% ".." adds a link to Dir.
created(Dir, Name, What, Stamp, Now, Tree) ->
    {Ino, Subdirs, Tree1} =
        case What of
            {link, Target} ->
                {Target, 0,
                 update(Target, fun(N) -> N#node{links = N#node.links + 1,
                                                 ctime = Now}
                                end, Tree)};
            {directory, _Mode} ->
                {Stamp, 1, put_node(Stamp, fresh(What, Dir, Stamp, Now), Tree)};
            _ ->
                {Stamp, 0, put_node(Stamp, fresh(What, Dir, Stamp, Now), Tree)}
        end,
    update(Dir, fun(D) ->
                        D1 = add_entry(D, Name, Ino),
                        changed(D1#node{links = D1#node.links + Subdirs},
                                Stamp, Now)
                end, Tree1).

fresh(What, Dir, Stamp, Now) ->
    {Data, Mode, Size, Links, Opens} =
        case What of
            {file, M, _Flags} -> {{file, #{}}, M, 0, 1, 1};
            {directory, M} ->
                {{directory, Dir, #{}, gb_trees:empty(), 1}, M, 0, 2, 0};
            {symlink, Text} ->
                {{symlink, binary:copy(Text)}, ?LINK_MODE, byte_size(Text), 1, 0}
        end,
    #node{data = Data, mode = Mode band ?MODE_BITS, links = Links,
          opens = Opens, size = Size, atime = Now, mtime = Now, ctime = Now,
          version = Stamp}.

%% A directory whose entries changed.
changed(D, Stamp, Now) ->
    D#node{mtime = Now, ctime = Now, version = Stamp}.

add_entry(#node{data = {directory, Parent, Entries, Order, Seq}} = D, Name, Ino) ->
    Stored = binary:copy(Name),
    D#node{data = {directory, Parent, Entries#{Stored => {Ino, Seq}},
                   gb_trees:insert(Seq, Stored, Order), Seq + 1}}.

remove_entry(#node{data = {directory, Parent, Entries, Order, Next}} = D, Name) ->
    {{_Ino, Seq}, Entries1} = maps:take(Name, Entries),
    D#node{data = {directory, Parent, Entries1, gb_trees:delete(Seq, Order), Next}}.

%% Lowers the links of a node that lost its name in Dir. A directory loses
%% every link with its one name, its parent, and Dir the link of its "..".
%% A node left with no links and no opens is freed; the caller's charge
%% already counted that.
drop_name(Ino, Dir, Now, Tree) ->
    case fetch(Ino, Tree) of
        #node{data = {directory, _Parent, Entries, Order, Next}} = N ->
            Tree1 = update(Dir, fun(P) -> P#node{links = P#node.links - 1} end,
                           Tree),
            release(Ino, N#node{data = {directory, none, Entries, Order, Next},
                                links = 0, ctime = Now}, Tree1);
        #node{links = Links} = N ->
            release(Ino, N#node{links = Links - 1, ctime = Now}, Tree)
    end.

unname_replaced(none, _NewDir, _NewName, _Now, Tree) ->
    Tree;
unname_replaced(Replaced, NewDir, NewName, Now, Tree) ->
    drop_name(Replaced, NewDir, Now,
              update(NewDir, fun(P) -> remove_entry(P, NewName) end, Tree)).

%% A directory moved to another parent takes its ".." with it.
moved_parent(Ino, #node{data = {directory, _, _, _, _}}, Dir, NewDir, Tree)
  when Dir =/= NewDir ->
    Tree1 = update(Dir, fun(P) -> P#node{links = P#node.links - 1} end, Tree),
    Tree2 = update(NewDir, fun(P) -> P#node{links = P#node.links + 1} end, Tree1),
    update(Ino, fun(#node{data = {directory, _, E, O, S}} = M) ->
                        M#node{data = {directory, NewDir, E, O, S}}
                end, Tree2);
moved_parent(_Ino, #node{}, _Dir, _NewDir, Tree) ->
    Tree.

release(Ino, #node{links = 0, opens = 0}, #tree{nodes = Nodes} = Tree) ->
    Tree#tree{nodes = maps:remove(Ino, Nodes)};
release(Ino, N, Tree) ->
    put_node(Ino, N, Tree).

%% A file's new size: chunks past it are freed and the tail of the last one
%% zeroed, or the file extends with a hole. Returns the node and the charge
%% change, which is never positive.
resize(#node{data = {file, Chunks}, size = Size, version = Version} = N,
       NewSize, Stamp, Now) ->
    Kept = case NewSize < Size of
               true -> maps:filter(fun(I, _Chunk) -> I < chunks_below(NewSize) end,
                                   Chunks);
               false -> Chunks
           end,
    Charge = -(map_size(Chunks) - map_size(Kept)) * ?CHUNK_BYTES,
    Version1 = case NewSize =:= Size of
                   true -> Version;
                   false -> Stamp
               end,
    {N#node{data = {file, zero_tail(Kept, NewSize)}, size = NewSize,
            mtime = Now, ctime = Now, version = Version1},
     Charge}.

chunks_below(Size) ->
    (Size + ?CHUNK_BYTES - 1) div ?CHUNK_BYTES.

zero_tail(Chunks, Size) ->
    Index = Size div ?CHUNK_BYTES,
    case {Size rem ?CHUNK_BYTES, Chunks} of
        {0, _} ->
            Chunks;
        {Keep, #{Index := Chunk}} ->
            Zeros = (?CHUNK_BYTES - Keep) * 8,
            Chunks#{Index := binary:copy(<<(binary_part(Chunk, 0, Keep))/binary,
                                           0:Zeros>>)};
        {_Keep, #{}} ->
            Chunks
    end.

%% Chunk I rebuilt whole: the old bytes, or zeros, with Bytes, written at
%% At, copied over their part of it.
spliced(Old, I, At, Bytes) ->
    Base = I * ?CHUNK_BYTES,
    Lo = max(At, Base) - Base,
    Hi = min(At + byte_size(Bytes), Base + ?CHUNK_BYTES) - Base,
    New = binary_part(Bytes, Base + Lo - At, Hi - Lo),
    binary:copy(<<(binary_part(Old, 0, Lo))/binary, New/binary,
                  (binary_part(Old, Hi, ?CHUNK_BYTES - Hi))/binary>>).

%% The bytes From..To of a file, holes as zeros; one whole stored chunk is
%% returned as itself.
bytes(_N, From, To) when From >= To ->
    <<>>;
bytes(#node{data = {file, Chunks}}, From, To)
  when From rem ?CHUNK_BYTES =:= 0, To - From =:= ?CHUNK_BYTES,
       is_map_key(From div ?CHUNK_BYTES, Chunks) ->
    map_get(From div ?CHUNK_BYTES, Chunks);
bytes(#node{data = {file, Chunks}}, From, To) ->
    iolist_to_binary(
      [begin
           Base = I * ?CHUNK_BYTES,
           Lo = max(From, Base) - Base,
           Hi = min(To, Base + ?CHUNK_BYTES) - Base,
           binary_part(maps:get(I, Chunks, ?ZERO_CHUNK), Lo, Hi - Lo)
       end || I <- lists:seq(From div ?CHUNK_BYTES, (To - 1) div ?CHUNK_BYTES)]).

%% ---------------------------------------------------------------------------
%% Nodes
%% ---------------------------------------------------------------------------

node(Ino, #tree{nodes = Nodes}) ->
    case Nodes of
        #{Ino := N} -> {ok, N};
        #{} -> {error, enoent}
    end.

%% A node the step has already found.
fetch(Ino, #tree{nodes = Nodes}) ->
    map_get(Ino, Nodes).

put_node(Ino, N, #tree{nodes = Nodes} = Tree) ->
    Tree#tree{nodes = Nodes#{Ino => N}}.

update(Ino, Fun, Tree) ->
    put_node(Ino, Fun(fetch(Ino, Tree)), Tree).

kind(#node{data = Data}) ->
    element(1, Data).

entries(#node{data = {directory, _, Entries, _, _}}) ->
    Entries.

qid(Ino, Tree) ->
    N = fetch(Ino, Tree),
    {kind(N), N#node.version, Ino}.

%% getattr's fields; erx_ramfs adds the type bits, uid and gid 0 and the
%% valid mask. A directory's size is 0, as on tmpfs.
attr(Ino, #node{} = N) ->
    Chunks = case N#node.data of
                 {file, C} -> map_size(C);
                 _ -> 0
             end,
    #{kind => kind(N), mode => N#node.mode, nlink => N#node.links,
      size => N#node.size, blocks => Chunks * (?CHUNK_BYTES div 512),
      atime => N#node.atime, mtime => N#node.mtime, ctime => N#node.ctime,
      ino => Ino, data_version => N#node.version}.

%% ---------------------------------------------------------------------------
%% check/1's invariants
%% ---------------------------------------------------------------------------

check_root(#tree{nodes = Nodes, root = Root}) ->
    case Nodes of
        #{Root := #node{data = {directory, Root, _, _, _}}} -> [];
        #{} -> [{root, Root}]
    end.

check_held(#tree{nodes = Nodes, root = Root, held = Held, cap = Cap}) ->
    Charges = maps:fold(
                fun(Ino, N, Sum) ->
                        Own = case Ino of
                                  Root -> 0;
                                  _ -> node_charge(N)
                              end,
                        Names = case N#node.data of
                                    {directory, _, Entries, _, _} ->
                                        lists:sum([entry_charge(Name) ||
                                                      Name <- maps:keys(Entries)]);
                                    _ -> 0
                                end,
                        Sum + Own + Names
                end, 0, Nodes),
    [{held, Held, recomputed, Charges} || Charges =/= Held]
        ++ [{over_cap, Held, Cap} || Held > Cap].

check_shapes(#tree{nodes = Nodes}) ->
    lists:flatmap(fun({Ino, N}) -> [{Ino, P} || P <- shape(N, Nodes)] end,
                  maps:to_list(Nodes)).

%% Counts are checked against the entries by check_links/1; here the mode.
shape(#node{mode = Mode} = N, Nodes) ->
    [{mode, Mode} || Mode < 0 orelse Mode > ?MODE_BITS]
        ++ data_shape(N#node.data, N#node.size, Nodes).

data_shape({file, Chunks}, Size, _Nodes) ->
    Last = chunks_below(Size),
    [{size, Size} || not (Size >= 0 andalso Size =< ?MAX_SIZE)]
        ++ [{chunk_outside_size, I} || I <- maps:keys(Chunks),
                                        not (I >= 0 andalso I < Last)]
        ++ [{chunk_bytes, I} || {I, C} <- maps:to_list(Chunks),
                                 byte_size(C) =/= ?CHUNK_BYTES]
        ++ [{chunk_not_copied, I} || {I, C} <- maps:to_list(Chunks),
                                      not stored_alone(C)]
        ++ tail_shape(Chunks, Size);
data_shape({symlink, Text}, Size, _Nodes) ->
    [{link_text, Text} || valid_link_text(Text) =/= ok]
        ++ [{size, Size} || Size =/= byte_size(Text)]
        ++ [{text_not_copied, Text} || not stored_alone(Text)];
data_shape({directory, _Parent, Entries, Order, Next}, Size, Nodes) ->
    [{size, Size} || Size =/= 0]
        ++ [{order_size, map_size(Entries)} ||
               map_size(Entries) =/= gb_trees:size(Order)]
        ++ lists:flatmap(
             fun({Name, {Ino, Seq}}) ->
                     [{name, Name} || valid_name(Name) =/= ok]
                         ++ [{name_not_copied, Name} || not stored_alone(Name)]
                         ++ [{dangling, Name, Ino} || not is_map_key(Ino, Nodes)]
                         ++ [{seq, Name, Seq} || not (Seq >= 1 andalso Seq < Next)]
                         ++ [{order, Name, Seq} ||
                                gb_trees:lookup(Seq, Order) =/= {value, Name}]
             end, maps:to_list(Entries)).

%% Bytes past the size inside the last chunk are zero.
tail_shape(Chunks, Size) ->
    Index = Size div ?CHUNK_BYTES,
    Keep = Size rem ?CHUNK_BYTES,
    case Chunks of
        #{Index := Chunk} when Keep > 0 ->
            Tail = binary_part(Chunk, Keep, ?CHUNK_BYTES - Keep),
            [{tail_not_zero, Index} || Tail =/= <<0:((?CHUNK_BYTES - Keep) * 8)>>];
        #{} ->
            []
    end.

%% A stored binary references no more bytes than its own.
stored_alone(Bin) ->
    binary:referenced_byte_size(Bin) =:= byte_size(Bin).

%% Each node's links against the entries naming it: a named directory has 2
%% plus its subdirectories and exactly one name, under the parent it
%% records; a nameless directory is empty with no parent; any other node
%% has one link per name; a node with no links is open.
check_links(#tree{nodes = Nodes, root = Root}) ->
    Named = maps:fold(
              fun(DirIno, #node{data = {directory, _, Entries, _, _}}, Acc) ->
                      maps:fold(fun(_Name, {Ino, _Seq}, Acc1) ->
                                        maps:update_with(Ino, fun(Ds) -> [DirIno | Ds] end,
                                                         [DirIno], Acc1)
                                end, Acc, Entries);
                 (_Ino, #node{}, Acc) -> Acc
              end, #{}, Nodes),
    lists:flatmap(fun({Ino, N}) -> links(Ino, N, maps:get(Ino, Named, []), Root, Nodes) end,
                  maps:to_list(Nodes)).

links(Ino, #node{data = {directory, Parent, Entries, _, _}, links = Links,
                 opens = Opens}, Names, Root, Nodes) ->
    Expected = 2 + length([I || {I, _} <- maps:values(Entries),
                                kind(map_get(I, Nodes)) =:= directory]),
    case {Ino, Names} of
        {Root, []} ->
            [{root_links, Links, Expected} || Links =/= Expected];
        {Root, _} ->
            [{root_named, Names}];
        {_, [Dir]} ->
            [{dir_links, Ino, Links, Expected} || Links =/= Expected]
                ++ [{dir_parent, Ino, Parent, Dir} || Parent =/= Dir];
        {_, []} ->
            [{nameless_dir, Ino, Links, Parent, map_size(Entries)} ||
                Links =/= 0 orelse Parent =/= none orelse map_size(Entries) =/= 0]
                ++ [{unreferenced, Ino} || Opens =:= 0];
        {_, _} ->
            [{dir_hard_link, Ino, Names}]
    end;
links(Ino, #node{links = Links, opens = Opens}, Names, _Root, _Nodes) ->
    [{links, Ino, Links, length(Names)} || Links =/= length(Names)]
        ++ [{unreferenced, Ino} || Links =:= 0, Opens =:= 0].

%% Every named directory's parent chain reaches the root, in at most one
%% step per node.
check_parents(#tree{nodes = Nodes, root = Root} = Tree) ->
    [{detached, Ino} ||
        {Ino, #node{data = {directory, Parent, _, _, _}}} <- maps:to_list(Nodes),
        Parent =/= none,
        not reaches_root(Ino, Root, map_size(Nodes), Tree)].

reaches_root(Root, Root, _Fuel, _Tree) ->
    true;
reaches_root(_Ino, _Root, 0, _Tree) ->
    false;
reaches_root(Ino, Root, Fuel, #tree{nodes = Nodes} = Tree) ->
    case Nodes of
        #{Ino := #node{data = {directory, Parent, _, _, _}}} when Parent =/= none ->
            reaches_root(Parent, Root, Fuel - 1, Tree);
        #{} ->
            false
    end.
