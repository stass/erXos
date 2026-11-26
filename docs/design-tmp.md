# The RAM file system at `/tmp`

Every domain that runs ERTS has a writable directory at `/tmp`, held in
the domain's own memory and lost when the domain ends. It is where OTP's
test suites get their `priv_dir` directories under Common Test,
compile and load modules, and where a session's programs keep scratch
files. Its contract is set elsewhere: a RAM file system per domain, in the
domain's memory and charged to its budget, with a cap of its own, the
specification's `tmp`, an eighth of `memory` by default, past which a
write fails with `{error, enospc}`
([design-runtime.md](design-runtime.md#files),
[design-domains.md](design-domains.md#principals-sessions-and-quotas)). This document
says how it works inside.

Decisions every reader needs:

* **`/tmp` is a file server like any other.** `erx_ramfs` is a module of
  the `erx_fs` behaviour ([design-files.md](design-files.md#serving-the-erx_fs-behaviour))
  that runs in the domain itself; it, `erx_ramfs_core` and `erx_ramfs_sup`
  belong to the `erx_files` application with `erx_fs`. The runtime mounts its grant at `/tmp`
  as it mounts any grant, and `prim_file` reaches it through
  `erx_file_remote`, the client every file server has. There is no
  local provider for it and no namespace kind of its own.
* **The grant owns the tree.** The tree is one value, held by `/tmp`'s
  one grant, the domain's own, as an own tree of `erx_fs`
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)):
  every callback `erx_fs` makes is one step of a pure function,
  `erx_ramfs_core:step/4`, on that value, run in the grant's process.
  Nothing else reads or writes the tree, so every request is atomic with
  respect to every other without a lock, and a request costs the
  client's message and its reply and nothing more.
* **A walked fid keeps its node, as FreeBSD's tmpfs does.** A node lives
  while a name names it, an open holds it or a grant's fid names it. The
  walk takes the grant's hold in the step that finds the node, so no
  request between a walk and the next request through its fid can free
  the node it names: a `stat` that races a rename over its name finds the
  old file or the new one, never `ENOENT`. The grant forgets a node when
  none of its fids names it any more, and every hold ends with the
  grant, whose tree ends with it. A fid names a node by its inode
  number, which is never given to a second node while the domain lives
  ([design-files.md](design-files.md#fid-owners)).
* **Data is pages, holes are free.** A file's bytes are 4 KiB chunks in a
  map from chunk index to binary, as tmpfs keeps pages; a missing chunk is
  a hole and reads as zeros. The cap bounds the tree's **charges**, its
  chunks plus a fixed charge per node and name, and a step that would pass
  it changes nothing and answers `enospc`. The cap is a storage limit,
  not a bound on the runtime's memory ([Charges](#data-model)).
* **The tree speaks Linux; the client speaks OTP.** The tree answers with
  the `file:posix()` atoms of Linux's errors, as any 9P2000.L server
  answers with Linux's numbers; `erx_file_remote` turns them into the
  answers stock `prim_file` gives on a UNIX host, for every server alike
  ([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)).

## Where `/tmp` runs

Three shapes were weighed. The decision is recorded here because it
removes a namespace kind and a path of the session's export.

* **(a) C in `prim_file`'s NIF**, beside the release file system: nodes,
  sorted directory arrays and page tables in `erx_prim_file.c` under one
  mutex, served on the dirty I/O schedulers.
* **(b) Erlang in the calling process**, as the EROFS reader serves its
  mounts: the NIF answers `{ram, Names}`, `prim_file` sends the operation
  to one tree process of the domain and returns what the NIF would have.
* **(c) An `erx_fs` server**, the shape chosen: the core of (b) behind
  `erx_fs`'s callbacks, held in the grant's own process, reached through
  a grant like `/data` or `/proc`. It runs in the domain itself, not in
  a service elsewhere: the
  contract puts `/tmp` in the domain's memory and budget, and a domain's
  memory depends on nothing outside it but the kernel; a server in
  another domain would hold each client's files on its own budget,
  needing per-client memory accounting the design avoids
  ([design-runtime.md](design-runtime.md#memory)), would copy every
  payload into and out of two lanes, and would have to drop a client's
  files when its connection ends.

| | (a) C in the NIF | (b) Erlang, own dispatch | (c) `erx_fs` server in the domain |
| --- | --- | --- | --- |
| Cost of one operation | one move to a dirty I/O scheduler and back, one mutex | one message round trip to the tree process; a path operation resolves its path in `erx_path` first | one message round trip to the grant process, which steps the tree it holds; a path operation resolves its path in `erx_path` first, an operation on an open file does not |
| Copies of data | one, in the caller | one, in the tree process (writes) or the caller (reads); binaries pass between processes by reference | the same as (b); payloads are cut into requests of at most 64 KiB, so a 32 MiB file, the default cap, is 512 reads |
| Atomicity: rename, open after unlink, the cap under concurrent writers | from the mutex, for every call | from the one process, for every call | from the one process, for every request; a write over 64 KiB is several requests ([design-files.md](design-files.md#open-files-and-offsets)) |
| POSIX's calls | each implemented directly | each implemented directly | through 9P2000.L, which needs rules of erXos's servers and client: create-or-open in `lcreate`, truncation by an open fid's access, an append's offset in `write`'s reply; every server shares them |
| A bug | can corrupt the runtime's memory; in the system domain that resets the machine | crashes the tree process; `/tmp` restarts empty | the same as (b); open files then answer `eio`, as for any server that dies |
| Memory beyond the cap | the allocator's overhead per page and node; `enif_alloc` returning NULL answers `enospc` | ERTS's overhead per object and garbage awaiting collection, not bounded by a figure; an allocation failure ends the domain, as any ERTS allocation's does | the same as (b) |
| New concepts in the system | a third local provider in C, `ERX_NS_RAM`, a tree in the session's export for `/tmp` | `ERX_NS_RAM`, a `{ram, ...}` answer and its dispatch in `prim_file`, a module that mirrors the NIF's interface, a tree in the export | one `erx_fs` module; `ERX_NS_RAM` and the export's `/tmp` tree are deleted |
| What it needs first | nothing | `prim_file`'s dispatch of non-local answers | `erx_fs` and `erx_file_remote`, with fid owners, which every file server needs |

(c) wins on the model a maintainer must hold. Every file system is a
server reached through one client, so `/tmp` adds a module, not a path:
the namespace keeps two local providers, both read-only, and anything
writable is a server; a session's programs reach `/tmp` through fids on
the session's grant, as they reach `/data`, instead of through a second
tree in the session's export; the identity, version, open-file and
mapping rules of [design-files.md](design-files.md) apply to it unchanged;
and it is Erlang, as system code is. (b) has the same core and the same
one hop, but keeps a provider kind and a dispatch that exist only for
`/tmp`. (a) is likely the fastest and refuses an allocation failure gracefully, but
that refusal protects little, since the rest of the runtime meets the
same exhausted budget a moment later, while a bug in it is a memory error
in every domain's runtime.

Two costs fall on (c). POSIX's calls, which (a) and (b) implement
directly, reach the tree through 9P2000.L, which carries some of them
only by rules of erXos's own (the POSIX row) and leaves a write over
64 KiB not atomic against another writer; and its memory beyond the
cap, like (b)'s, is ERTS's and has no figure, where (a)'s is the
allocator's. The first is paid once for every server, `/data`
included, which must follow the same rules whatever `/tmp` does, and the
second is shared with (b). They narrow (a)'s distance from (c) without
changing the choice.

The price of (c) is hops, and the tree lives in the grant to keep them
to one. Measured with `tools/erx bench posix` under HVF (Apple M3 Max,
QEMU 11.1.3, Homebrew clang 23.1.3, landing profile;
[research-file-call-path.md](research-file-call-path.md)), a program's
`fstat` of a `/tmp` file spent 5.4 us of its 16.1 us in one request
through a grant that called a tree process of its own: two local round
trips, two monitors with aliases and the grammar checked on both sides
of the grant. A tree process in front of the core buys nothing here:
`/tmp`'s tree has one grant, so the grant already orders every request
the tree takes, and a second process only adds its round trip. With
the tree in the grant a request is one local round trip, as (b)'s is,
and the remaining gap to (a) is that round trip and the grant's checks,
which every server shares. The item stays on the [performance watch
list](todo-performance.md) until the bench times the request again.

**Prior art.** Plan 9's `ramfs(4)` is a user-level process that serves a
tree in its memory over 9P and mounts itself, by default on `/tmp`: shape
(c), in the model erXos's namespaces follow. Fuchsia's memfs keeps each
file's data in a VMO and serves `fuchsia.io` over channels, and `/tmp` is
a memfs instance in a process of its own: a server. L4Re's `l4re_vfs` has
a tmpfs back end that runs inside the task, shape (a). FreeBSD's tmpfs and
Linux's `shmem` are in their kernels, which is where those systems keep
every file system. Taken from them: tmpfs's split of nodes from directory
entries, which makes hard links and open-after-unlink plain; data held in
pages, a hole costing nothing, and a page charged when written; a node
freed at its last close once it has no name; directories counting `2`
plus their subdirectories as links; and, from memfs and Linux's offset
map, directory entries ordered by a per-directory sequence number, so a
listing resumed at an offset neither repeats nor skips an entry that
stayed. tmpfs's two limits, pages and nodes, are one byte cap here. On
what keeps a node alive the systems split: FreeBSD's tmpfs, whose every
lookup holds a vnode, and the `lib9p` ramfs of later Plan 9s, whose every
fid holds a reference, keep a node while anything names it; QEMU's
9P2000.L server, whose fid holds an open host descriptor or, for a path
it cannot open, the path, keeps a removed file only while a descriptor
holds it, and the first Plan 9 ramfs answers a removed file's fids "file
does not exist". `/tmp` takes FreeBSD's rule, since where Unix systems
differ erXos follows FreeBSD: a fid holds what it was walked to, so a
request through it never misses a node that a rename or an unlink took
the name of in between ([Fids and nodes](#fids-and-nodes)).

## Overview

```text
  domain D (ERTS)
  +--------------------------------------------------------------------+
  | file:write_file("/tmp/a", Bin)                                     |
  |   prim_file: erx_path -> mount /tmp, grant G, "a"                  |
  |   erx_file_remote: walk from NOFID, lcreate, write (64 KiB a       |
  |     request), clunk; the caller owns the fid                       |
  |         | local messages, to aliases                               |
  |         v                                                          |
  |   G: erx_fs grant process, holding the whole tree (an own tree)    |
  |     each erx_ramfs callback, in G:                                 |
  |       erx_ramfs_core:step(Request, Stamp, Now, Tree)               |
  |                -> {Reply, Tree1}                                   |
  +--------------------------------------------------------------------+
     a session domain also holds fids on its own G for its programs
```

1. The caller's path is resolved by `erx_path` in the calling process;
   `/tmp`'s entry is an ordinary grant entry, `{grant, G, Tree}` with
   rights `rw`, whose pid is the domain's own grant, so the resolver
   returns `{parent, Entry, [], <<"a">>, Resume}`: a walk to `/tmp`'s
   top, on which the `lcreate` of `a` is sent.
2. `erx_file_remote`, in the calling process, sends the protocol's
   requests to `G` as local messages, as it sends them across a
   connection to a grant in another domain, each naming the caller as the
   owner of any fid it makes and drawing each fid from the runtime's
   counter through the NIF
   ([design-files.md](design-files.md#version-and-attach)).
3. `erx_fs` checks each request against the protocol's grammar and
   bounds, which local messages need as much as frames from another
   domain, since they pass no funnel, and calls `erx_ramfs`'s callbacks,
   from the grant process, one at a time.
4. Each callback draws a stamp from the domain's file version counter
   and reads the clock, then runs one pure step on the tree the grant
   passes it and answers the reply and the next tree, which the grant
   keeps. No callback sends a message or waits.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **T1.** Every request is atomic with respect to every other | the tree is one value held by `/tmp`'s one grant, which runs one callback at a time, and every callback runs one step to completion | a callback that reads or writes tree state outside its step; a step that waits for another process; a second grant made to share the tree | a source check that only `erx_ramfs`'s callbacks call `erx_ramfs_core:step/4`; concurrent rename and lookup tests (below) |
| **T2.** `held` equals the sum of the charges of what the tree holds, and never passes `cap` | every step computes its charge change from the request and the tree before it builds anything, and is refused whole, with nothing changed, when `held` plus the change would pass `cap` | a step that adds a chunk, node or name without charging it, or frees one without returning its charge | `erx_ramfs_core:check/1` recomputes `held` from the tree; it runs after every step of the sequence tests |
| **T3.** A node lives exactly while a directory entry names it, an open holds it or a grant holds it, and a fid reaches no node but the one it was walked to | `links` counts the entries naming a node, as tmpfs counts them (a directory also counts its own `.` and each subdirectory's `..`, and drops to 0 when its name is removed), `opens` its opens, and the tree's set `walked` the nodes the grant's fids name; `walk` adds the node it finds to `walked` in the same step, so a fid never names a freed node; a step that leaves a node with no links, no opens and no place in `walked` deletes it and returns its charge; the grant forgets a node once no step of its fids' paths names it, and the tree ends with its grant, so no hold outlives the grant that took it; fids name nodes by inode number, never reused (T5) | a rename that replaces a name without lowering the old node's `links`; a clunk that skips the count; a walk that holds nothing; a grant that forgets a node a fid still names, or never forgets one; an inode number drawn twice | `check/1`: every node with `links` above 0 is reachable from the root, every other has `opens` above 0 or is in `walked`, every member of `walked` is a node of the tree, and each `links` equals the entries naming it (a directory: 2 plus its subdirectories); the stale-fid, rename-race, stopped-walk, `..` and clunk tests (below) |
| **T4.** Directories with a name form a tree under the root | a directory's `parent` is set where it is made and moved only by `rename`, which refuses to move a directory below itself (`einval`); a hard link to a directory is refused (`eperm`); removing a directory's name, which needs it empty, sets its `parent` to `none`, and a directory with no name takes no new one (`enoent`) | a rename that skips the ancestor check; a name added to a removed directory | `check/1` walks every named directory's parent chain to the root and checks that a directory with no name is empty; a test renames a directory into its own subdirectory |
| **T5.** No inode number or version is drawn twice while the domain lives | both come from the domain's file version counter ([design-files.md](design-files.md#identity-and-version)), which outlives the grant | an inode number drawn from the tree's own state, which a restart would reset | the restart test (below) compares inode numbers before and after |
| **T6.** No process on `/tmp`'s path loads code while it serves: the client in whatever process calls, and the grant, which holds the tree, the whole path, since `erx_path` resolves the path and the NIF draws the fids in the caller and no other process takes part | `erx_file_remote` is preloaded and calls only preloaded modules, `erx_path` and `prim_file`'s NIF included, and BIFs, as `prim_file` does; `erx_ramfs`'s start loads, before it mounts, the modules the serving processes can call, a list the build generates with `xref` from `erx_ramfs`, `erx_ramfs_core` and `erx_fs`, so no hand-kept list can miss one | a module loaded on first use on either side. The code server reads its path through `erl_prim_loader` in its own process (`code_server:mod_to_bin/3`, `with_cache/4`), and `erl_prim_loader:read_file/1` runs `prim_file` in its caller (`client_or_request/2`), so with a `/tmp` directory on the code path the code server is itself `/tmp`'s client: an unloaded client module there halts the node (`error_handler:ensure_loaded/1`: "The code server called the unloaded module"), and an unloaded serving module asks the code server, which is waiting on that very process | a build check fails when a module `erx_file_remote` calls is not preloaded; the cold-path test (below) |

## Data model

```erlang
-type ino() :: pos_integer().               %% the qid path: the stamp of its creation
-type name() :: binary().                   %% 1..255 bytes, no "/" or NUL, not "." or ".."

-record(node, {
    data    :: {file, Chunks :: #{non_neg_integer() => <<_:32768>>}}
             | {directory, Parent :: ino() | none,
                Entries :: #{name() => {ino(), Seq :: pos_integer()}},
                Order :: gb_trees:tree(Seq :: pos_integer(), name()), NextSeq :: pos_integer()}
             | {symlink, Text :: binary()},
    mode    :: 0..8#7777,                    %% permission bits; the type is the data's tag
    links   :: non_neg_integer(),
    opens   :: non_neg_integer(),
    size    :: 0..(1 bsl 63 - 1),            %% a symbolic link: its text's length
    atime, mtime, ctime :: integer(),        %% nanoseconds since the epoch
    version :: pos_integer()                 %% data_version
}).

-record(tree, {
    nodes :: #{ino() => #node{}},
    root  :: ino(),
    walked :: sets:set(ino()),              %% the nodes the grant's fids name
    held  :: non_neg_integer(),              %% bytes charged
    cap   :: non_neg_integer()               %% the specification's tmp
}).
```

A node's kind is the tag of its data, so a directory with chunks or a
file with entries cannot be written down. A file of size `S` holds at
most `ceil(S / 4096)` chunks, each a binary of exactly 4,096 bytes; bytes
past `S` inside the last chunk are zero. A directory's `Entries` finds a
name, and `Order` lists them by the sequence number each received when it
was made. Everything the tree keeps that came from a request, chunks,
names and link texts, is a binary the grant's step made at exactly its
size, never a part of a caller's binary, so nothing the tree keeps holds
on to a larger binary it was not charged for. A chunk a write or a
truncation rebuilds is joined from its parts once, by
`iolist_to_binary/1`; a name, a link text and a chunk written whole are
copied out of the request with `binary:copy/1`.

**Charges.** A chunk costs 4,096 bytes, a node 256, a directory entry 64
plus its name's length, and a symbolic link its text's length; `held` is
their sum, and `cap` bounds it. The charges measure storage, as a disk's
blocks and inodes do: the chunks are the data `statfs` and `blocks`
report, and the fixed charges make empty files and names cost something,
so the one cap also bounds how many there can be, as tmpfs's node limit
does. They are not the runtime's memory. Each chunk and node also costs
ERTS's own headers, map entries and records; what the tree drops stays
allocated until the grant's next collection; and a reader that
keeps a binary a read returned keeps the chunk it shares. So `/tmp`
promises that filling it stops at the cap with `enospc` and nothing of
the refused request done, and that its memory is what it stores plus
ERTS's overhead on it, which the domain's `memory` must leave room for.
It does not promise a figure for that overhead: an allocation failure
past the domain's budget is fatal for the domain, as any ERTS
allocation failure is, and the ratio of the grant's memory to
`held` is measured, not promised ([watch list](todo-performance.md)).
The root costs nothing, so a `tmp` of 0 makes a `/tmp` that is empty and
refuses every creation with `enospc`.

**Stamps and time.** Each callback passes its step a **stamp**, a
fresh value of the domain's file version counter, and the time. A node
made in the step takes the stamp as its inode number and its version; a
node whose data, size or entries the step changes takes it as its
version. One stamp suffices, because no step makes more than one node.
The counter's refusal past 2^64 - 1 reaches the caller as `eio`, as for
every server.

## Operations

Each callback of `erx_fs` is one step. Walking is `erx_fs`'s: it calls
`walk` for one plain name at a time, refuses a walk naming `..` before
any step, as the grammar does for every client (erXos's own send none,
and a host client's reaches the host link's bridge, which answers it
`einval`), never asks the tree to
follow a link, and stops at a `symlink`, which `erx_file_remote`
reads and resolves through the caller's namespace, following or not
following a path's last link as the operation asks
([design-files.md](design-files.md#resolving-a-path)). So a link in
`/tmp` may lead into another mount of the reader's namespace, as any
link may; a program narrowed to `/tmp` reaches nothing it was not given.
The tree's errors are `file:posix()` atoms naming Linux's errors; the
tables below write them as Linux does (`ENOENT` for `enoent`).

### Fids and nodes

`erx_fs` holds every fid and ends it ([design-files.md](design-files.md#fid-owners)).
The tree keeps `walked`, the set of nodes the grant's fids name, as
FreeBSD's tmpfs keeps a node while a vnode references it, and counts
each node's opens:

| A fid is | The tree |
| --- | --- |
| attached | nothing: it names the root, which lives as long as the tree |
| walked, cloned or walked in place | each name's `walk` adds the found node to `walked` in the step that finds it; a walk that stops makes no fid, and the grant forgets what it walked |
| walked in place past its node, or clunked | nothing until no fid of the grant names a node, as its node or as its entry's directory; then the grant's `forget` removes the node from `walked` and frees it if it has no links and no opens |
| opened by `lopen`, or made and opened by `lcreate` | counts an open of the node, by `open` or by `make` of a file |
| clunked while open, by its client, its `remove` or its owner's end | `clunk` drops the open, and the fid's end its steps, as for an unopened fid |
| left by a grant that ends | the tree ends with its grant, holds and all |

Holding is idempotent: a node is in `walked` once however many fids
name it, and the grant keeps the count of its fids naming each node,
at most two for each fid, its node and its entry's directory
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)),
so it forgets a node exactly once, when that count reaches zero.
`forget`, like every callback of an own tree, runs in the grant and
returns the next tree, so it is ordered with the grant's walks by
construction. The tree has one grant, so it keeps no holder: a hold is
membership of `walked`, and the grant's end drops every hold because
the tree ends with it. The node's open keeps its own count, so a node
outlives the later of its handle's clunk and its grant's forget.

A fid whose node lost its names still reaches it: `getattr` answers with
`nlink` 0, and so a `stat` that races a rename over its name finds the
old file or the new one, as on Unix. `open` of a file opens it whether
or not a name still reaches it: a client's open is a walk and then an
`lopen`, two steps of the tree where FreeBSD's `open` is one, so a
rename or an `unlink` that falls between them leaves the open the file
its walk found, never `ENOENT`; permissions and `O_TRUNC` take effect
at the `lopen`. The rule also lets a description re-open its removed
file through its unopened fid, as a mapping's open or a change of
`O_APPEND` does ([design-files.md](design-files.md)), where FreeBSD
needs no open and so never meets `tmpfs_open`'s refusal. A
removed directory finds no name, takes no new one and opens nothing
(`ENOENT`), as FreeBSD's tmpfs answers for a directory with no parent
(its `tmpfs_open` refuses a node with no links, which a lookup reaches
only through a removed directory). No walk names `..`
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)), so a
removed directory keeps nothing above it alive: the fid holds its node
and the directory it was walked from, and nothing more.

**Permissions.** The domain is one user, who owns every file and is not
a superuser: the tree checks the owner's permission bits and nothing
else. Searching a directory (`walk`) needs `x`; opening for reading, or
listing a directory, needs `r`; opening for writing needs `w`; adding or
removing a name needs `w` and `x` on the directory. A read, a write or a
truncation through an opened fid needs only that the fid was opened for
it, so a mode changed after the open changes nothing for it, as on UNIX;
truncation through an unopened fid needs `w`. Changing mode and times
needs nothing, as for a file's owner. A refused check is `EACCES`. A
file or directory is made with the mode its request carries, which
`erx_file_remote` always sends, stock's `0666` or `0777` less the
domain's `umask`, so `0644` and `0755` under the default `022`
([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote));
a link is made with `0777`, as Linux makes one.

| Callback | Does | Linux errors |
| --- | --- | --- |
| `walk(Dir, Name)` | the node `Name` names in `Dir`, with its qid | `ENOENT` for a missing name or a `Dir` that is gone; `ENOTDIR` if `Dir` is not a directory; `EACCES` |
| `getattr(Node)` | `valid` the basic fields and `data_version`; mode with type bits, `uid` and `gid` 0, `nlink` = `links`, size, `blocks` = chunks held times 8, times, `ino`, `data_version` | `ENOENT` for a node that is gone |
| `open(Node, Flags)` | counts an open and returns `{Node, Access, Append}`; `O_TRUNC` on a file frees every chunk and sets size 0 | `ENOENT` for a node that is gone or a directory no name reaches; a file no name reaches opens; opens made before an unlink go on; `EISDIR` for a directory opened to write; `EACCES` |
| `make(Dir, Name, {file, Mode, Flags})` (`lcreate`) | in one step: a new empty file, opened with `Flags`; or, without `O_EXCL`, the regular file `Name` already names, opened with `Flags`, `O_TRUNC` included; either way counted as an open | `EEXIST` with `O_EXCL` for any existing name, a dangling link included; `ELOOP` for a link without `O_EXCL`, which the client follows; `EISDIR` for a directory; `ENOENT` for a `Dir` with no name; `EACCES`; `ENOSPC` |
| `make(Dir, Name, {directory, Mode, Owner})` | a new directory, with `links` 2; `Dir` gains a link, the new directory's `..` | `EEXIST`, `ENOENT` for a `Dir` with no name, `EACCES`, `ENOSPC` |
| `make(Dir, Name, {symlink, Text})` | a link whose text is `Text` | `ENOENT` for an empty text; `ENAMETOOLONG` past 4,095 bytes; `EINVAL` for a NUL; `EEXIST`, `ENOENT` for a `Dir` with no name, `EACCES`, `ENOSPC` |
| `make(Dir, Name, {link, Node})` | another name for a file or a symbolic link; `Node` gains a link | `EPERM` for a directory; `ENOENT` for a `Node` or `Dir` that is gone; `EEXIST`, `EACCES`, `ENOSPC` |
| `make(Dir, Name, {node, ...})` | refused: a RAM tree keeps no device nodes | `EPERM` |
| `read(Handle, Offset, Count)` | the bytes from `Offset`, at most `Count` and never past the size; a hole is zeros; at or past the end, an empty binary | `EBADF` for a handle not open for reading |
| `write(Handle, Offset, Data)` | the bytes at `Offset`, or at the end for an `Append` handle, a positioned write included; makes missing chunks, extends the size; returns the count and `At`, the offset written at | `EBADF` for a handle not open for writing; `EFBIG` past 2^63 - 1; `ENOSPC`, with nothing written |
| `readdir(Handle, Offset, Max)` | up to `Max` entries whose sequence number is above `Offset`, in that order, each carrying its sequence number as the next offset | `EBADF` |
| `readlink(Node)` | the text | `EINVAL` for a node that is not a link; `ENOENT` |
| `setattr({open, Handle} \| {node, Node}, Changes)` | mode; `uid` and `gid`; size, which frees chunks past it and zeroes the tail of the last, or extends with a hole; `atime` and `mtime`, given or now; `ctime` is always now | `EPERM` for an owner or group other than 0, while 0 changes only `ctime`; for size: `EFBIG` above 2^63 - 1, `EINVAL` through a handle not open for writing, `EACCES` through a node without `w`, `EISDIR` for a directory; `ENOENT` |
| `unlink(Dir, Name, Kind)` | removes the name, `Kind` being `file`, `directory` or `{node, Node}`, which removes it only while it names `Node`; a removed directory loses its parent, and `Dir` the link of its `..`; a node with no links and no opens is freed | `ENOENT`, for `{node, Node}` also when the name names another node; for `directory`: `ENOTDIR` for a non-directory, `ENOTEMPTY`; for `file`: `EISDIR` for a directory; `EACCES` |
| `rename(Dir, Name, NewDir, NewName)` | moves the name, replacing what `NewName` named, in one step; the same node under both names changes nothing; a directory moved to another parent moves its `..` with it: `Dir` loses a link, `NewDir` gains one and the directory's `parent` becomes `NewDir`; a replaced node loses the link of its name, and a replaced directory also its `..` on `NewDir`, so `NewDir` gains nothing net | `ENOENT`; `ENOTDIR` for a directory over a non-directory; `EISDIR` for a non-directory over a directory; `ENOTEMPTY` over a non-empty directory; `EINVAL` for a directory moved below itself; `EACCES` |
| `fsync(Handle)` | nothing to do | none |
| `clunk(Handle)` | ends the open; frees the node if it has no links and no opens left | none |
| `statfs()` | block size 4,096, blocks `cap div 4096`, free and available `(cap - held) div 4096`; `ffree` `(cap - held) div 256`, the nodes the free charge could still pay for, and `files` the nodes held plus `ffree`, so `files - ffree` is the nodes in use, as `df -i` shows | none |
| `xattr(...)` | refused: the tree keeps no extended attributes | `enotsup`, the atom the protocol's error list names for Linux's `EOPNOTSUPP` |

`erx_fs`'s callbacks make each decision POSIX makes in one step in one
step: `unlink` receives the request's kind, `make` of a file carries the
flags and returns an open handle, `setattr` receives an open fid's
handle, and `write` returns `At`
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).

**Times and versions.** Reads and listings never change `atime`, as under
Linux's `noatime`, and a write of zero bytes changes nothing. Otherwise:

| Step | Sets to now | Takes the stamp as version |
| --- | --- | --- |
| a write of at least one byte | the file's `mtime` and `ctime` | the file |
| a `setattr` of size, or an open with `O_TRUNC` of an existing file | the file's `mtime` and `ctime` | the file, if its size changed |
| a new file, directory or link | all three of the new node's; the directory's `mtime` and `ctime` | the new node; the directory |
| `unlink` | the directory's `mtime` and `ctime`; the node's `ctime` if it survives, with other names or opens | the directory |
| `link` | the node's `ctime`; the directory's `mtime` and `ctime` | the directory |
| `rename` | both directories' `mtime` and `ctime`; the moved node's `ctime`; a replaced node's `ctime` if it survives | both directories |
| `setattr` of mode, owner or times | the node's `ctime`, and `atime` or `mtime` where asked for now | none |

**Data.** A write at offset `O` of `N` bytes touches chunks `O div 4096`
to `(O + N - 1) div 4096`. The step first counts the touched chunks
that do not exist and refuses the write if their charge would pass the
cap, and only then builds: each touched chunk is rebuilt whole, the old
chunk or zeros with the new bytes copied over their range. Only chunks
that did not exist are charged, so overwriting costs nothing and a write
far past the end costs one chunk. A read gathers the chunks of its range
and returns them joined, zeros standing in for missing ones; a read of
exactly one whole chunk returns the chunk itself.

**Listing.** A directory's entries come out in the order they were
made, by sequence number; a listing resumed at an offset neither repeats
nor skips an entry that stayed, whatever was added or removed between
the pages. A rename gives the moved entry a new sequence number in its
new directory. `erx_file_remote` reads every page and adds the mount
points below the directory, as for every server.

**Open after unlink.** An open handle names a node, not a name: removing
or replacing the name leaves the node, its data and its charge, and
reads, writes and `getattr` through the handle go on, with `nlink` 0.
The clunk that leaves it with no opens frees it, whether its client sent
it or the grant did at the end of the fid's owner. The grant runs a
client's clunk after the fid's earlier requests and answers it once the
tree's `clunk` has run, so the charge has come back when `close`
returns. Since the grant clunks a dead owner's
fids, a process that dies with a removed file open frees the file's charge
([design-files.md](design-files.md#fid-owners)). A fid walked to a
node keeps it the same way until the grant forgets it, so a removed
node that an open or a fid still holds keeps its charge against the cap
until it is freed, as a removed file on Unix keeps its space while
anything references it.

## The client's answers

`erx_file_remote` turns the tree's answers into what stock `prim_file`
answers on a UNIX host, by rules it applies to every server
([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)):
its error steps (`rename` of `"/"` answers `einval`; the resolution's
own answers are FreeBSD's, among them `einval` for a `del_dir` or
`rename` whose last name is `.` or `..`, and `eperm` for such a
`delete`; `/tmp` itself, the top of its mount, answers `ebusy` to
`del_dir` and to `rename`, `eperm` to `delete` and `eexist` to an
operation that makes it; `enotempty` becomes `eexist`
and `eisdir` from `delete` becomes `eperm`; a failed `del_dir` of the working directory answers
`einval`, while an empty one is removed), its mapping of `getattr` to
`#file_info{}`, and its offsets: a write moves an open file's offset to
`At` plus the count, so an append leaves it after the appender's own
bytes.

## Starting and mounting

`erx_ramfs_sup`, a child of `kernel_safe_sup` added by an edit to
`lib/kernel/src/kernel.erl`, starts in every domain that runs ERTS, the
system domain included. It passes the cap, read by `erx_ns:tmp_limit/0` from the `tmp` field of the
runtime's startup limits ([design-runtime.md](design-runtime.md#starting-a-runtime)),
into the one `erx_fs` grant it starts for the domain itself, with rights
`rw` and tree name `tmp`, mounted at `/tmp` with those rights, by
`erx_fs:start_mounted(erx_ramfs, Cap, rw, "/tmp")`; the grant's
`init/1` makes the empty tree and answers it as an own tree. Before
mounting, it loads every module the grant can call (T6).

**The grant's heap bound.** Every grant runs under a `max_heap_size`
that counts its binaries and bounds its own state
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)); here
that state includes the tree, so the supervisor sets the bound as the
sum of three parts:

* **The reserve**, what any grant of `erx_fs` may hold at its bounds
  with no tree at all: its root, its pool of fids, its owners' monitors
  and its 64 requests in flight with up to 64 KiB of payload each
  ([design-files.md](design-files.md#bounds)). A fid's part is fixed:
  a fid holds its node, an inode number, its qid and its entry, one
  directory and one name of at most 255 bytes that owns exactly its
  bytes, copied as it enters the fid so that no larger binary it was
  carved from stays pinned, and two per-node counts, whatever its
  depth, since the grant keeps no chain of directories for it
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
  "What a fid denotes"). So the reserve is the grant's own state plus
  the pool times one fid at its largest, and `erx_fs` computes it from
  the grant's bounds, the same figure for every grant of the same
  bounds, so it is never zero and a `tmp` of 0 still serves every
  request its bounds admit.
* **The tree at its cap**, `cap` times `1 + o`, where `o` is ERTS's
  memory per charged byte beyond the charge (headers, map entries,
  records), a constant of `erx_ramfs` set above the worst ratio a tree
  reaches, a cap full of empty files, directories and links, whose
  measurement the [watch list](todo-performance.md) holds.
* **The same again for what a step leaves behind**: a write rebuilds
  each chunk it touches, a step rebuilds the nodes and maps on its
  path, and the old ones stay allocated until the grant's next
  collection, so the bound doubles the tree's part.

The cap and the grant's bounds, not the heap bound, are what a legal
request meets: a request that would pass the cap is refused with
`enospc` before it builds anything (T2), a new fid past the pool with
`emfile`, and a request past the requests in flight with `emfile`; a
walk adds nothing that grows with depth, so no sequence of legal walks
grows the grant's state past the reserve. Every part of the bound
therefore follows from a bound the grant enforces, except `o`, which
is measured: the heap bound is reached only if `o` is set below what
ERTS spends or a bug leaks, and then the grant is killed and `/tmp`
restarts empty, as for any crash ([Failure handling](#failure-handling)). Whether
twice the tree's part covers collection under every request mix is
not derived from ERTS's collector here; the tests below settle it.

The grant and the lock table the grant starts, as a grant that is a
tree of its own does ([design-files.md](design-files.md#locks)), are one
unit: they are linked,
and the supervisor is `one_for_all`, so when either ends, both end,
and `/tmp` restarts empty, its old entry unmounted and the new grant
mounted at `/tmp`. No process of the old tree can reach the new one, and
the old grant's fids end with it; a client's monitor on the old grant
turns its open files' next operations into `eio`.

`kernel_safe_sup` starts after `code_server` and `file_server_2`, before
any application of the release; a path under `/tmp` before the mount
resolves to the release file system's `/`, where it is missing
(`enoent`). A session reaches its programs' `/tmp` through fids on the
session's own grant, walked by its handlers like those of any grant
([design-files.md](design-files.md#narrowing-for-a-program)), and a
program's shared mapping of a `/tmp` file is served by the session's
mapper like any other ([design-files.md](design-files.md#shared-mappings)).

## Concurrency

The grant is the only place the tree exists, and a step never waits
for another process: it reads its arguments and the tree and returns.
Nothing waits on the grant but its clients, and the grant waits on
nothing, so no cycle can form. The grant orders everything, so each
request is atomic,
as POSIX asks of regular-file operations and as `erx_fs` leaves to each
tree ([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
"Each tree makes its own requests atomic"), and `rename` over an
existing name is atomic for every observer. The unit is one request: a
write over 64 KiB is several, and another writer's may fall between them
([design-files.md](design-files.md#open-files-and-offsets)). The cap is
a field of the one value, so concurrent writers cannot together pass it.
No `/tmp` file waits for an event, so no callback answers `{wait, ...}`.

**Work per step.** A write touches at most 17 chunks, a read its
count's, a listing page `Max` entries, and a lookup or a change of a
name is logarithmic in the tree's nodes and the directory's entries.
Three steps grow with what is stored: a truncation frees the chunks past
the new size, at most `cap div 4096`, 8,192 for the default 32 MiB; a
rename walks a chain of parents toward the root, as deep as the tree,
when it moves a directory (the new parent's, so the directory never
lands below itself) and when its target is a directory (the source
directory's, so a target that holds the source answers `ENOTEMPTY`, as
Linux's does); and freeing a node drops its record, whose chunks ERTS
frees at the grant's next collection. None of them waits, but
each delays the steps behind it. `check/1`, which grows with the tree,
runs only in tests.

## Failure handling

| Failure | Detection | What remains | Cleanup | What the user sees |
| --- | --- | --- | --- | --- |
| A write request, create or link would pass the cap | the step's charge check, before it builds anything | the tree as before the step; of a caller's write over 64 KiB, the requests before it | none | `{error, enospc}`, with an open file's offset past what was written; `ENOSPC` to a program |
| The domain's budget is exhausted | ERTS's allocator | nothing: the domain ends | the domain library | as any ERTS allocation failure ([design-runtime.md](design-runtime.md#crash-handling)); the cap keeps `/tmp`'s charges to their share, ERTS's overhead on top ([Charges](#data-model)) |
| A bug crashes the grant or the lock table, or the grant passes its heap bound | the link, then the supervisor | nothing of `/tmp` | both end; `/tmp` restarts empty and is mounted again | `{error, eio}` for files open before, as for any server that died; a crash report in the log; for the heap bound it is ERTS's own `max_heap_size` report, which names the bound and the grant, killed at once with no code of its own run, and the tree's `held` is what `statfs`, as `df /tmp` shows it, answered before |
| A walk names `..` | `erx_fs`'s funnel, by the grammar's refusal of the name, before any callback | everything as before | none | `{error, einval}`; erXos's clients resolve `..` themselves and never send it ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)) |
| A caller ends during a request or with files open | the grant's monitor on the fid's owner ([design-files.md](design-files.md#fid-owners)) | the effects of the steps that ran | the grant clunks every fid the caller owned, after every request it sent; a removed file it held open is freed | nothing |
| A request names a fid whose node lost its names | the node's `links`, 0 | the node, held by the fid | the grant forgets it when no fid names it | `getattr` answers with `nlink` 0; `lopen` of a file opens it; `lopen` of a directory and `walk` answer `{error, enoent}` |
| The version counter is exhausted | the counter's refusal | the tree | none | `{error, eio}` and a report, as for every server |

Nothing a caller sends can crash the tree: `erx_fs` checks every
request's grammar and bounds before a callback, and `step/4` is total
over every request the callbacks can build, a node that is gone
included, answering an error for each case it refuses. Every node a
grant holds is in the tree, because a held node is never freed.

## Differences from stock OTP

These add to the differences every server has
([design-files.md](design-files.md#compatibility-and-migration)): FreeBSD's
answers where macOS's differ, a working directory that is a path, `exdev`
between grants, trees or rights, links followed by the client, writes atomic per 64 KiB
request, a positioned write to an `append` file appending as on Linux
where macOS writes at the offset, and `file:allocate/3` answering
`enotsup`. Each is pinned by the oracle comparison, which maps it.

* Directory listings come in creation order; stock's order is the host
  file system's.
* A directory's size is 0 and its `nlink` is 2 plus its subdirectories,
  as on Linux's tmpfs; macOS reports others.
* Reads never change `atime`.
* The owner and group are 0, permissions are checked as for the owner
  and never bypassed, and changing the owner to anyone else fails with
  `eperm`.
* A directory removed while a narrowed program's namespace roots at it
  finds no name from then on: opening or listing it, or anything below
  it, answers `enoent`, as FreeBSD's tmpfs answers for a directory with
  no parent, and its `stat` answers with `nlink` 0, since the program's
  fid keeps it; Linux keeps such a directory readable and empty.
* `file:sendfile/5` takes `file`'s fallback of reads and sends, since a
  remote file has no descriptor to hand to the host's call.

## Verification

Each case is paired with a seeded fault that it must catch, which shows
the code under test ran.

* **Core, on the host.** EUnit cases of `erx_ramfs_core` over plain tree
  values, one per row of the callback table: each error with its cause
  and the tree unchanged after it, each success with its reply and
  `check/1`, which also checks that every stored chunk, name and text
  references no more bytes than its own
  (`binary:referenced_byte_size/1`). Seeded: a rename that does not lower
  the replaced node's `links`; an ancestor check of the immediate parent
  only; a write that charges every touched chunk; a name or a whole
  chunk stored without copying.
* **Sequences**, the tree's fuzz target, run by `make check-fuzz` for its
  budget: random sequences of up to 64 operations over a few names and
  directories, with offsets and sizes at 0, chunk boundaries, 2^63 - 1
  and negative values, and fids kept across removals, through `step/4`
  with `check/1` after each step and the cap set low. Seeded: a truncate
  that does not return the freed chunks' charge.
* **Against stock OTP.** The same sequences, as `file` calls, run in the
  hosted runtime under `/tmp` and in stock OTP 29.1.2 in a fresh host
  directory, and their results, `#file_info{}` records included, are
  compared after mapping the listed differences; every other difference
  fails. Added cases cover the client's rules of [design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote):
  a last `.` or `..` of every operation that removes, renames or makes a
  name, `..` after a link and after a missing name, a trailing `/` after
  a file, a link to a directory, a link to a file and a dangling link,
  `set_cwd` through a link, removing the working directory, a
  `delete("missing/victim")` while `victim` exists, truncation through a
  read-only descriptor and after `chmod 0444`, and the top of the mount,
  which no stock case has: `del_dir("/tmp")` answers `ebusy`,
  `delete("/tmp")` `eperm`, a rename of `/tmp` either way `ebusy`,
  `make_dir("/tmp")` `eexist`, and `/tmp/..` reaches `/`, none asking
  the tree. Seeded: the client without its `ENOTEMPTY`-to-`eexist` rule;
  a resolver that answers a last `.` or `..` before walking the names
  before it, or removes a name on `..` before walking it; a `delete` sent
  with the walk of `file/.`'s names; a path operation that walks its fid
  in place; `setattr` checking the node's mode for an open handle; a top
  treated as an ordinary last name.
* **Fids and nodes.** A removed file stays reachable through a fid
  (`getattr` answers `nlink` 0, `lopen` opens it) until the last fid
  naming it is clunked, and its inode number is never given again; a
  rename between a walk and its `getattr` or `lopen` finds the old file;
  a walk that stops keeps nothing; a fid on a directory removed after
  its walk keeps the directory, whose walk answers `enoent`, and its
  parent held until the fid is clunked, and a walk of `..` from it is
  refused with `einval`; a `remove` through a fid whose name another
  node has taken since removes nothing; in the core, an unlinked file a
  fid walked to is freed, and its charge returned, at the `forget` of
  its last fid. Seeded: a freed inode number reused; a walk that holds
  nothing; a grant that never forgets; a `forget` that leaves the node
  in `walked`.
* **Open after unlink and rename, and killed openers.** `held` returns to
  where it started after a removed file's handle is closed and after its
  opener is killed. Seeded: a clunk that does not free a node with no
  links; a grant that does not clunk a dead owner's fids.
* **Creating, appending and the cap.** Two processes opening one new name
  at once both succeed and reach one file; `exclusive` on a dangling link
  answers `eexist`; `delete`, `rename` and `read_link_info` act on a
  link itself; two appenders each find their own byte before their
  position; a 128 KiB write with room for 64 KiB answers `enospc` with
  the first 64 KiB written and the position after them. Seeded: an
  `lcreate` that answers `EEXIST` without `O_EXCL`; a `delete` that
  follows a last link; an append offset taken from a `getattr`; a
  position left unchanged on an error.
* **Concurrency.** Eight writers renaming fresh files over `b` while
  eight others stat it: every stat finds `b`; writers filling the tree
  stop at the cap together and `check/1` holds. Seeded: a rename split
  into remove then add.
* **One message each way.** A trace of `/tmp`'s grant while a process
  reads a file's `#file_info{}`, opens it and reads it shows, for each
  request, one message in and one reply out, and no message sent from
  a callback and no monitor taken by one; the grant's own monitor of a
  fid's owner, taken once for an owner it does not yet monitor
  ([design-files.md](design-files.md#fid-owners)), is allowed. An open
  is one exchange of a walk from `NOFID`, a clone and an `lopen`.
Seeded: a callback that calls a process of its own, as a tree process
  would be called; a client that sends `attach`.
* **The heap bound.** EUnit cases of `erx_ramfs_tests` on the stock
  emulator, each grant started with the bound the supervisor computes
  and no other change: at a `tmp` of 0, every creation answers `enospc`
  while the grant holds its whole pool of fids on the root and its 64
  requests in flight each carry a 64 KiB write; at a `tmp` of 64 KiB,
  the same full pool, its fids walked to a few directories they share,
  since 4,096 directories of 255-byte names would pass that cap, and at
  32 MiB the full pool, each fid walked to a directory of its own whose
  name has 255 bytes; at both, the tree filled to its cap
  with 4 KiB files and then with one file, then every chunk
  overwritten a hundred times, then everything removed and filled
  again. At 64 KiB also 64 fids, each walked by a 255-byte name carved
  from a binary of its own of 1 MiB, which together pass the reserve
  unless the grant keeps only the name's own bytes.
  At 32 MiB also the walks of the deep-fid case: the full pool,
  each fid walked on its own from `NOFID` and then in place, 16 names
  at a time, about 400 directories down a chain of 1-byte names, and
  one fid walked in place one directory at a time down the deepest
  chain the cap allows, about 100,000 directories; with a fid's cost
  fixed, each walk in place costs the grant the same at any depth, so
  the case is linear in its walks. The grant serves throughout, is
  never killed, and `check/1` holds at the end. Seeded: a bound of the
  tree's part alone, without the reserve, which the 64 KiB run's full
  pool and requests in flight pass, killing the grant; and a fid that
  keeps the chain of directories it was walked through, which the
  deep-fid case passes, killing the grant; and a fid's name kept as
  the request carried it, which the carved names pass, killing the
  grant.
* **Restart.** The grant killed with files open: their operations
  answer `eio`, `/tmp` is mounted again and empty, and new inode numbers
  lie above every old one. Seeded: inode numbers drawn from a counter in
  the tree state.
* **Code from `/tmp`, cold.** In a fresh hosted runtime whose first use
  of `/tmp` is the code server's, a lookup of a missing module through
  `/tmp` on the code path answers `{error, nofile}` within a deadline,
  and a module written there loads, with no module of `xref`'s serving
  or client set loaded by either. Seeded: a start that skips one module
  of the generated list; a module `erx_file_remote` calls left out of
  the preload list.
* **Grammar on the local route.** Names and link texts over every bound
  or holding forbidden bytes, sent to `/tmp`'s grant as local messages,
  each refused before a callback, and the largest valid ones accepted.
  Seeded: a grant that skips the checks for a sender in its own domain.
* **OTP's suites.** `file_SUITE`, `filelib_SUITE` and a Common Test run
  with each `priv_dir` under `/tmp` and its logs on a RAM file system of
  their own, so a suite that fills `/tmp` fails only its own cases,
  compared case by case with stock OTP 29.1.2 by `tools/erx oracle
  hosted` on the hosted runtime and by `make check-oracle` on the
  target; a difference not in the table of known differences, each
  listed with its reason, fails.

The tree parses no bytes: names and payloads reach it only through
`erx_fs`'s grammar, whose fuzz target feeds both local messages and
frames, and paths only through `erx_path`, which has its own.

## References

* `ramfs(4)`, Plan 9 Programmer's Manual, 4th edition; Plan 9's `lib9p`
  file trees.
* FreeBSD `sys/fs/tmpfs/` (`tmpfs.h`: `tmpfs_node`, `tmpfs_dirent`) and
  `tmpfs(5)`.
* QEMU `hw/9pfs/9p.c` (`v9fs_lcreate`, fids of the local back end).
* Linux `mm/shmem.c` and `fs/libfs.c` (the offset map for directory
  listings); `rename(2)`, `unlink(2)`, `rmdir(2)`, `pwrite(2)`,
  `ftruncate(2)`.
* Fuchsia `src/storage/memfs`.
* L4Re `l4re_vfs` and its libc file system back ends.
* POSIX.1-2017, XSH 2.9.7, Thread Interactions with Regular File
  Operations; `rename()`, `pwrite()`.
* OTP 29.1.2 `erts/emulator/nifs/unix/unix_prim_file.c`,
  `erts/emulator/nifs/common/prim_file_nif.c`,
  `erts/preloaded/src/prim_file.erl`, `erts/preloaded/src/erl_prim_loader.erl`,
  `lib/kernel/src/code_server.erl`, `lib/kernel/src/error_handler.erl`,
  `lib/kernel/src/file.erl` and `lib/kernel/test/file_SUITE.erl`.
