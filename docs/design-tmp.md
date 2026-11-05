# The RAM file system at `/tmp`

Every domain that runs ERTS has a writable directory at `/tmp`, held in
the domain's own memory and lost when the domain ends. It is where Common
Test writes its logs and `priv_dir` directories, where OTP's test suites
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
  that runs in the domain itself. The runtime mounts its grant at `/tmp`
  as it mounts any grant, and `prim_file` reaches it through
  `erx_file_remote`, the client every file server has. There is no
  local provider for it and no namespace kind of its own.
* **One process owns the tree.** The tree is one value, held by one
  process, the **tree process**; every callback `erx_fs` makes is one call
  to it, and it answers each by one step of a pure function,
  `erx_ramfs_core:step/4`. Nothing else reads or writes the tree, so every
  operation is atomic with respect to every other without a lock.
* **Data is pages, holes are free.** A file's bytes are 4 KiB chunks in a
  map from chunk index to binary, as tmpfs keeps pages; a missing chunk is
  a hole and reads as zeros. The cap counts chunks, nodes and names in
  bytes, and a step that would pass it changes nothing and answers
  `ENOSPC`.
* **The tree speaks Linux; the client speaks OTP.** The tree answers with
  9P2000.L's Linux error numbers, as any 9P2000.L server does;
  `erx_file_remote` turns them into the answers stock `prim_file` gives
  on a Unix host, for every server alike
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
* **(c) An `erx_fs` server**, the shape chosen: the tree process of (b)
  behind `erx_fs`'s callbacks, reached through a grant like `/data` or
  `/proc`. It runs in the domain itself, not in a service elsewhere: the
  contract puts `/tmp` in the domain's memory and budget, and a domain's
  memory depends on nothing outside it but the kernel; a server in
  another domain would hold each client's files on its own budget,
  needing per-client memory accounting the design avoids
  ([design-runtime.md](design-runtime.md#memory)), would copy every
  payload into and out of two lanes, and would have to drop a client's
  files when its connection ends.

| | (a) C in the NIF | (b) Erlang, own dispatch | (c) `erx_fs` server in the domain |
| --- | --- | --- | --- |
| Cost of one operation | one move to a dirty I/O scheduler and back, one mutex | the NIF's resolve, then one message round trip to the tree process | the NIF's resolve, then a request to the grant process, which calls the tree process, through the file's owner process for reads and writes: about two to four local message round trips |
| Copies of data | one, in the caller | one, in the tree process (writes) or the caller (reads); binaries pass between processes by reference | the same as (b); payloads are cut into requests of at most 64 KiB, so a 32 MiB file, the default cap, is 512 reads |
| Atomicity: rename, open after unlink, the cap under concurrent writers | from the mutex; a node freed when its last NIF resource is destroyed | from the one process; opens counted per node | from the one process, the same core as (b); opens are fids, clunked by `erx_fs` |
| A bug | can corrupt the runtime's memory; in the system domain that resets the machine | crashes the tree process; `/tmp` restarts empty | the same as (b); open files then answer `eio`, as for any server that dies |
| Allocation failure | `enif_alloc` returns NULL and the write answers `enospc` | fatal for the domain, as any ERTS allocation; the cap keeps `/tmp` within its share | the same as (b) |
| New concepts in the system | a third local provider in C, `ERX_NS_RAM`, a tree in the session's export for `/tmp` | `ERX_NS_RAM`, a `{ram, ...}` answer and its dispatch in `prim_file`, a module that mirrors the NIF's interface, a tree in the export | one `erx_fs` module; `ERX_NS_RAM` and the export's `/tmp` tree are deleted |
| What it needs first | nothing | `prim_file`'s dispatch of non-local answers | `erx_fs` and `erx_file_remote`, which every file server needs |

(c) wins on the model a maintainer must hold. Every file system is a
server reached through one client, so `/tmp` adds a module, not a path:
the namespace keeps two local providers, both read-only, and anything
writable is a server; a session's programs reach `/tmp` through fids on
the session's grant, as they reach `/data`, instead of through a second
tree in the session's export; the identity, version, open-file and
mapping rules of [design-files.md](design-files.md) apply to it unchanged;
and it is Erlang, as system code is. (b) has the same core and one hop
fewer, but keeps a provider kind and a dispatch that exist only for
`/tmp`. (a) is likely the fastest and refuses an allocation failure gracefully, but
that refusal protects little, since the rest of the runtime meets the
same exhausted budget a moment later, while a bug in it is a memory error
in every domain's runtime.

The price of (c) is hops. Nothing has measured them; the work `/tmp`
serves in Phase 1 is small files and line-sized log writes, where a few
local round trips per write are expected to be of the order of the dirty-scheduler
move of (a). The item is on the [performance watch
list](todo-performance.md), and the core moves unchanged between (b) and
(c) if a measurement ever asks for it.

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
stayed. tmpfs's two limits, pages and nodes, are one byte cap here.

## Overview

```text
  domain D (ERTS)
  +--------------------------------------------------------------------+
  | file:write_file("/tmp/a", Bin)                                     |
  |   prim_file NIF: erx_ns_resolve -> mount /tmp, grant G, "a"        |
  |   erx_file_remote: walk, lcreate, write (64 KiB a request), clunk  |
  |         | local messages, to aliases                               |
  |         v                                                          |
  |   G: erx_fs grant process   ---> file owner (one per open file)    |
  |         | erx_ramfs callbacks       |                              |
  |         v                           v                              |
  |   tree process (erx_ramfs): State = the whole tree                 |
  |     each call: erx_ramfs_core:step(Request, Stamp, Now, Tree)      |
  |                -> {Reply, Tree1}                                   |
  +--------------------------------------------------------------------+
     a session domain also holds fids on its own G for its programs
```

1. The caller's path is resolved by `erx_ns_resolve` in the NIF; `/tmp`'s
   row is an ordinary `ERX_NS_SERVER` row whose pid is the domain's own
   grant, so the NIF answers `{remote, G, Names}`.
2. `erx_file_remote`, in the calling process, sends the protocol's
   requests to `G` as local messages, as it sends them across a
   connection to a grant in another domain.
3. `erx_fs` checks each request against the protocol's grammar and
   bounds, and calls `erx_ramfs`'s callbacks, from the grant process or
   from the file's owner. Each callback is one `gen_server:call` to the
   tree process.
4. The tree process draws a stamp from the domain's file version counter
   and reads the clock, then runs one pure step and replies.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **T1.** Every operation is atomic with respect to every other | the tree is one value held by one process, and every callback is one call that runs one step to completion | a callback that reads or writes tree state outside the tree process; a step that waits for another process | a source check that only `erx_ramfs`'s server functions call `erx_ramfs_core:step/4`; concurrent rename and lookup tests (below) |
| **T2.** `held` equals the sum of the charges of what the tree holds, and never passes `cap` | every step computes its charge change with its new tree and is refused whole, with nothing changed, when `held` plus the change would pass `cap` | a step that adds a chunk, node or name without charging it, or frees one without returning its charge | `erx_ramfs_core:check/1` recomputes `held` from the tree; it runs after every step of the sequence tests |
| **T3.** A node lives exactly while a directory entry names it or an open holds it | `links` counts the entries naming a node, as tmpfs counts them (a directory also counts its own `.` and each subdirectory's `..`, and drops to 0 when its name is removed), and `opens` its open handles; a step that brings both to zero deletes the node and returns its charge | a rename that replaces a name without lowering the old node's `links`; a clunk that skips the count | `check/1`: every node is reachable from the root or open, and each `links` equals the entries naming it (a directory: 2 plus its subdirectories) |
| **T4.** Directories form a tree | a directory's `parent` is set where it is made and moved only by `rename`, which refuses to move a directory below itself (`EINVAL`), and a hard link to a directory is refused (`EPERM`) | a rename that skips the ancestor check | `check/1` walks every parent chain to the root; a test renames a directory into its own subdirectory |
| **T5.** No inode number or version is drawn twice while the domain lives | both come from the domain's file version counter ([design-files.md](design-files.md#identity-and-version)), which outlives the tree process | an inode number drawn from the tree's own state, which a restart would reset | the restart test (below) compares inode numbers before and after |
| **T6.** The tree process, the grant and the file owners never load code while serving | `erx_ramfs`'s start loads every module they call before it registers or mounts, and `erx_file_remote`, which runs in `erl_prim_loader`'s process when code is read from a server, is preloaded beside `prim_file` | a lazily loaded module on the serving path: loading code from `/tmp` goes through `erl_prim_loader`, which waits for `/tmp`, while the code server waits for `erl_prim_loader` | a test compares the start's list with the remote calls `xref` finds in those modules; a test loads a module compiled into `/tmp` under a deadline |

## Data model

```erlang
-type ino() :: pos_integer().               %% the qid path: the stamp of its creation
-type name() :: binary().                   %% 1..255 bytes, no "/" or NUL, not "." or ".."

-record(node, {
    data    :: {file, Chunks :: #{non_neg_integer() => <<_:32768>>}}
             | {directory, Parent :: ino(), Entries :: #{name() => {ino(), Seq :: pos_integer()}},
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
    held  :: non_neg_integer(),              %% bytes charged
    cap   :: non_neg_integer()               %% the specification's tmp
}).
```

A node's kind is the tag of its data, so a directory with chunks or a
file with entries cannot be written down. A file of size `S` holds at
most `ceil(S / 4096)` chunks, each a binary of exactly 4,096 bytes that
the tree process made itself (`binary:copy/1` of a slice, never a
sub-binary of a caller's binary, so a chunk holds no memory it was not
charged for); bytes past `S` inside the last chunk are zero. A
directory's `Entries` finds a name, and `Order` lists them by the
sequence number each received when it was made.

**Charges.** A chunk costs 4,096 bytes, a node 256, a directory entry 64
plus its name's length, and a symbolic link its text's length. The fixed
sizes stand for the maps and records that hold them; they are an
accounting unit, set so that `held` stays above the tree's real
footprint, which `check/1`'s tests compare with
`erlang:process_info(Tree, memory)` plus the chunks' bytes. The root
costs nothing, so a `tmp` of 0 makes a `/tmp` that is empty and refuses
every creation with `ENOSPC`.

**Stamps and time.** The tree process passes each step a **stamp**, a
fresh value of the domain's file version counter, and the time. A node
made in the step takes the stamp as its inode number and its version; a
node whose data or size the step changes takes it as its version. One
stamp suffices, because no step makes more than one node. The counter's
refusal past 2^64 - 1 reaches the caller as `EIO`, as for every server.

## Operations

Each callback of `erx_fs` is one step. Walking is `erx_fs`'s: it calls
`walk` for one plain name at a time, handles `..` itself, never asks the
tree to follow a link, and stops at a `symlink`, which
`erx_file_remote` reads and resolves through the caller's namespace
([design-files.md](design-files.md#resolving-a-path)). The tree answers
Linux's error numbers, which travel in `Rlerror` and become OTP atoms in
the client.

**Permissions.** The domain is one user, who owns every file and is not
a superuser: the tree checks the owner's permission bits and nothing
else. Searching a directory (`walk`) needs `x`; reading a file or
listing a directory needs `r`; writing a file, or truncating one by
`setattr`, needs `w`; adding or removing a name needs `w` and `x` on the
directory. Changing mode and times needs nothing, as for a file's owner.
A refused check is `EACCES`. Files are made with mode `0644` and
directories with `0755`, as under a `umask` of `022`, unless the request
names a mode.

| Callback | Does | Linux errors |
| --- | --- | --- |
| `walk(Dir, Name)` | the node `Name` names in `Dir`, with its qid | `ENOTDIR` if `Dir` is not a directory; `EACCES`; `ENOENT` |
| `getattr(Node)` | mode with type bits, `uid` and `gid` 0, `nlink` = `links`, size, `blocks` = chunks held times 8, times, `ino`, `data_version` | none |
| `open(Node, Flags)` | counts an open and returns `{Node, Access, Append}`; `O_TRUNC` on a file frees every chunk and sets size 0 | `EISDIR` for a directory opened to write; `EACCES` |
| `make(Dir, Name, {file, Mode})` (`lcreate`) | a new empty file, opened by the same step | `EEXIST` if `Name` exists (the client walks before creating, so only a race or `O_EXCL` meets it); `EACCES`; `ENOSPC` |
| `make(Dir, Name, {directory, Mode})` | a new directory; `Dir` gains a link | `EEXIST`, `EACCES`, `ENOSPC` |
| `make(Dir, Name, {symlink, Text})` | a link whose text is `Text` | `ENOENT` for an empty text; `ENAMETOOLONG` past 4,095 bytes; `EINVAL` for a NUL; `EEXIST`, `EACCES`, `ENOSPC` |
| `make(Dir, Name, {link, Node})` | another name for a file or a symbolic link; `Node` gains a link | `EPERM` for a directory; `EEXIST`, `EACCES`, `ENOSPC` |
| `make(Dir, Name, {node, ...})` | refused: a RAM tree keeps no device nodes | `EPERM` |
| `read(Handle, Offset, Count)` | the bytes from `Offset`, at most `Count` and never past the size; a hole is zeros; at or past the end, an empty binary | `EBADF` for a handle not open for reading |
| `write(Handle, Offset, Data)` | the bytes at `Offset`, or at the end for an `Append` handle; makes missing chunks, extends the size | `EBADF` for a handle not open for writing; `EFBIG` past 2^63 - 1; `ENOSPC`, with nothing written |
| `readdir(Handle, Offset, Max)` | up to `Max` entries whose sequence number is above `Offset`, in that order, each carrying its sequence number as the next offset | `EBADF` |
| `readlink(Node)` | the text | `EINVAL` for a node that is not a link |
| `setattr(Node, Changes)` | mode; `uid` and `gid`; size, which frees chunks past it and zeroes the tail of the last, or extends with a hole; `atime` and `mtime`, given or now; `ctime` is always now | `EPERM` for an owner or group other than 0; `EACCES` for size without `w`; `EISDIR` for the size of a directory |
| `unlink(Dir, Name, Flags)` | removes the name; a node with no links and no opens is freed | `ENOENT`; with `AT_REMOVEDIR`: `ENOTDIR` for a non-directory, `ENOTEMPTY`; without it, `EISDIR` for a directory; `EACCES` |
| `rename(Dir, Name, NewDir, NewName)` | moves the name, replacing what `NewName` named, in one step; the same node under both names changes nothing | `ENOENT`; `ENOTDIR` for a directory over a non-directory; `EISDIR` for a non-directory over a directory; `ENOTEMPTY` over a non-empty directory; `EINVAL` for a directory moved below itself; `EACCES` |
| `fsync(Handle)` | nothing to do | none |
| `clunk(Handle)` | ends the open; frees the node if it has no links and no opens left | none |
| `statfs()` | block size 4,096, blocks `cap div 4096`, free `(cap - held) div 4096` | none |
| `xattr(...)` | refused: the tree keeps no extended attributes | `EOPNOTSUPP` |

The table assumes two changes to `erx_fs`'s callbacks: `unlink` receives
the request's `AT_REMOVEDIR` flag, and `make` of a file returns an open
handle, so that `lcreate` makes and opens in one step; see [Open
questions](#open-questions).

**Times.** Reads never change `atime`, as under Linux's `noatime`. A
write or a size change sets the file's `mtime` and `ctime`; adding or
removing a name sets the directory's `mtime` and `ctime`; a rename,
link, mode or owner change sets the node's `ctime`; a new node takes the
time for all three. A write of zero bytes changes nothing.

**Data.** A write at offset `O` of `N` bytes touches chunks `O div 4096`
to `(O + N - 1) div 4096`. Each touched chunk is rebuilt whole: the old
chunk or zeros, with the new bytes copied over their range. Only chunks
that did not exist are charged, so overwriting costs nothing and a write
far past the end costs one chunk. A read gathers the chunks of its range
and returns them joined, zeros standing in for missing ones.

**Listing.** A directory's entries come out in the order they were
made, by sequence number; a listing resumed at an offset neither repeats
nor skips an entry that stayed, whatever was added or removed between
the pages. A rename gives the moved entry a new sequence number in its
new directory. `erx_file_remote` reads every page and adds the mount
points below the directory, as for every server.

**Open after unlink.** An open handle names a node, not a name: removing
or replacing the name leaves the node, its data and its charge, and
reads, writes and `getattr` through the handle go on, with `nlink` 0.
The clunk that leaves it with no opens frees it. A process that dies
with files open has its fids clunked by its client
([Open questions](#open-questions)).

## The client's answers

`erx_file_remote` turns the protocol's answers into what stock
`prim_file` answers on a Unix host, for every server
([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)):
among the cases `/tmp`'s tests meet, `ENOTEMPTY` from `del_dir` or
`rename` becomes `eexist` and `EISDIR` from `delete` becomes `eperm`, as
`unix_prim_file.c` maps them; `del_dir` of the working directory, and so
`del_dir(".")`, answers `einval`; and `del_dir`, `delete` and `rename`
of `/tmp` itself, a mount point with no parent fid to send them to,
answer `ebusy`, as Linux answers for a mount point.

## Starting and mounting

`erx_ramfs_sup`, a child of `kernel_safe_sup` added by an edit to
`lib/kernel/src/kernel.erl`, starts in every domain that runs ERTS, the
system domain included. It starts the tree process with
the cap, read by `erx_ns:tmp_limit/0` from the `tmp` field of the
runtime's startup limits ([design-runtime.md](design-runtime.md#starting-a-runtime)),
then one `erx_fs` grant for the domain itself with rights `rw` and tree
name `tmp`, and mounts it with `erx_ns:mount(Grant, "/tmp", [{tree,
<<"tmp">>}, rw])`. Before mounting, it loads every module the tree,
the grant and the owners call (T6). The supervisor is `one_for_all`:
if the tree process or the grant ends, both restart, the tree empty, and
the old entry is unmounted and the new grant mounted at `/tmp`.

`kernel_safe_sup` starts after `code_server` and `file_server_2`, before
any application of the release; a path under `/tmp` before the mount
resolves to the release file system's `/`, where it is missing
(`enoent`). A session reaches its programs' `/tmp` through fids on the
session's own grant, walked by its handlers like those of any grant
([design-files.md](design-files.md#narrowing-for-a-program)), and a
program's shared mapping of a `/tmp` file is served by the session's
mapper like any other ([design-files.md](design-files.md#shared-mappings)).

## Concurrency

The tree process is the only place the tree exists, and it never waits
for another process: a step reads its arguments and the tree and
returns. Grant processes, file owners and their read helpers wait for
the tree, never the other way, so no cycle can form. `erx_fs` already
orders the reads, writes and size changes of one open file through its
owner; the tree orders everything, so the two together still give
POSIX's atomicity of regular-file operations
([design-files.md](design-files.md#open-files-and-offsets)) and make
`rename` over an existing name atomic for every observer. The cap is a
field of the one value, so concurrent writers cannot together pass it.

A step's work is bounded by its request: a write by its at most 64 KiB
payload, a read by its count, a listing page by `Max`. The work that
grows with the tree, `check/1`, runs only in tests.

## Failure handling

| Failure | Detection | What remains | Cleanup | What the user sees |
| --- | --- | --- | --- | --- |
| A write, create or link would pass the cap | the step's charge check | the tree as before the step | none | `{error, enospc}`; `ENOSPC` to a program |
| The domain's budget is exhausted | ERTS's allocator | nothing: the domain ends | the domain library | as any ERTS allocation failure ([design-runtime.md](design-runtime.md#crash-handling)); the cap keeps `/tmp` to its share |
| A bug crashes the tree process or the grant | the supervisor | nothing of `/tmp` | `/tmp` restarts empty and is mounted again | `{error, eio}` for files open before, as for any server that died; a crash report in the log |
| A caller dies during a request | `erx_fs`'s alias and monitor rules | the request's effect, if the step ran | its fids are clunked | nothing |
| The version counter is exhausted | the counter's refusal | the tree | none | `{error, eio}` and a report, as for every server |

Nothing a caller sends can crash the tree: `erx_fs` checks every
request's grammar and bounds before a callback, and `step/4` is total
over every request the callbacks can build, answering an error for each
case it refuses.

## Differences from stock OTP

These add to the differences every server has
([design-files.md](design-files.md#compatibility-and-migration)): `..`
resolved on the text, a working directory that is a path, `exdev`
between mounts, and links followed by the client.

* Directory listings come in creation order; stock's order is the host
  file system's.
* A directory's size is 0 and its `nlink` is 2 plus its subdirectories,
  as on Linux's tmpfs; macOS reports others.
* Reads never change `atime`.
* The owner and group are 0, permissions are checked as for the owner
  and never bypassed, and changing the owner fails with `eperm`.
* `file:allocate/3` and `file:sendfile/5` take their stock fallbacks,
  since a remote file has no descriptor to hand to the host's calls.

## Verification

Each case is paired with a seeded fault that it must catch, which shows
the code under test ran.

* **Core, on the host.** EUnit cases of `erx_ramfs_core` run against
  plain tree values, one per row of the callback table: for each error,
  the condition that causes it and the unchanged tree after it; for each
  success, the reply and `check/1`. Seeded: a rename that does not lower
  the replaced node's `links`, which `check/1`'s link count fails; an
  ancestor check that compares only the immediate parent, which the
  rename-into-grandchild case catches; a write that charges every touched
  chunk, which the overwrite-costs-nothing case catches.
* **Sequences.** Random sequences of up to 64 operations over a few names
  and directories, with offsets and sizes drawn to include 0, chunk
  boundaries, 2^63 - 1 and negative values, run through `step/4` with
  `check/1` after each step and the cap set low. Seeded: a truncate that
  does not return the freed chunks' charge, which the recomputed `held`
  catches.
* **Against stock OTP.** The same sequences, as `file` calls, run in the
  hosted runtime under `/tmp` and in stock OTP 29.1.2
  (`build/oracle/jit/install`) in a fresh host directory, and their
  results are compared after mapping the listed differences; every other
  difference fails the test. Seeded: the client without its
  `ENOTEMPTY`-to-`eexist` rule, which the `del_dir` of a non-empty
  directory catches.
* **Open after unlink and rename.** A file opened, removed, written and
  read through its handle, then closed, after which `held` is back where
  it started; a file renamed over another that is open, whose handle
  still reads the old bytes. Seeded: a clunk that does not free a node
  with no links.
* **Concurrency.** Eight processes each repeatedly write a fresh file
  and rename it over `b` while eight others stat `b`: every stat finds
  `b`, as POSIX requires of `rename` over an existing name; writers
  filling the tree concurrently stop at the cap together, and `check/1`
  holds after. Seeded: a rename split into two steps, remove then add,
  which a stat that misses `b` catches.
* **Restart.** The tree process killed with files open: their operations
  answer `eio`, `/tmp` is mounted again and empty, and new files' inode
  numbers are above every old one. Seeded: inode numbers drawn from a
  counter in the tree state.
* **Code from `/tmp`.** A module compiled into `/tmp` and loaded with
  `code:load_abs/1`, under a 30-second deadline. Seeded: a module of the
  serving path left out of the start's load list, which hangs and fails
  at the deadline; the `xref` comparison names it.
* **OTP's suites.** `file_SUITE`, `filelib_SUITE` and a Common Test run
  writing its logs and `priv_dir` under `/tmp`, compared case by case
  with stock by `make check-oracle`.

The tree parses no bytes: names and payloads reach it only through
`erx_fs`'s grammar, whose fuzz target covers them, and paths only
through `erx_ns_resolve`, which has its own. The sequence test is the
tree's fuzz target, run by `make check-fuzz` for its budget.

## Open questions

* **`erx_fs`'s callbacks miss two things a tree needs.** 9P2000.L's
  `unlinkat` carries `AT_REMOVEDIR`, and `remove` removes either kind,
  but the `unlink/3` callback carries neither, so a tree cannot answer
  `rmdir` of a file with `ENOTDIR` or `unlink` of a directory with
  `EISDIR`. And `lcreate` makes and opens a file in one request, but
  `make/4` returns a node and no handle, so another client can remove the
  new file between `make` and `open`, and the creator's open then fails
  where Linux's would not. Recommendation: `unlink(Dir, Name, Kind,
  State)` with `Kind` one of `file`, `directory` or `any`, `remove`
  passing `any`; and `make` for `{file, Mode, Flags}` returning `{ok,
  Node, qid(), Handle, State1}`, counted as an open, which is how this
  document's table treats it.
* **Where the domain's file version counter lives.** Every server of a
  domain draws from it and it outlives their restarts, but no document
  names its home. Recommendation: an `atomics` cell the runtime makes
  before any file server starts, reached through `persistent_term`.
* **Who clunks a dead process's files.** Stock closes a raw file when
  its owner process dies; `erx_file_remote` must do the same for every
  server, or an unlinked `/tmp` file opened by a crashed process holds
  its charge until the domain ends. Recommendation: the client monitors
  each process holding an open file and clunks its fids when it ends.
* **When `erx_fs` and `erx_file_remote` are built.** `/tmp` as a server
  needs both, which the roadmap places with the file services after
  `/tmp`. Recommendation: build the subset `/tmp` uses (walk, `lopen`,
  `lcreate`, `read`, `write`, `readdir`, `getattr`, `setattr`, `mkdir`,
  `symlink`, `link`, `readlink`, `unlinkat`, `renameat`, `statfs`,
  `clunk`) first, as the package that unblocks OTP's suites, and add
  locks, flush, freezing and extended attributes with the storage
  services.
* **`erx_file_remote` must be preloaded.** Reading code from any server
  mount, `/tmp` or `/data`, runs `erx_file_remote` in `erl_prim_loader`'s
  process; if it is not yet loaded, loading it waits on the code server,
  which waits on `erl_prim_loader`. [design-files.md](design-files.md)
  does not say it is preloaded, as it says of the EROFS reader.
  Recommendation: preload it, and hold every module it calls to BIFs and
  preloaded modules, as `prim_file` is held.
* **A read helper per read.** `erx_fs` runs a read in a helper so a slow
  medium does not block the file's owner; for a tree in memory the
  helper only adds a process. Recommendation: leave it until the
  watch-list measurement asks, then let a module declare its reads
  immediate.

## References

* `ramfs(4)`, Plan 9 Programmer's Manual, 4th edition.
* FreeBSD `sys/fs/tmpfs/` (`tmpfs.h`: `tmpfs_node`, `tmpfs_dirent`) and
  `tmpfs(5)`.
* Linux `mm/shmem.c` and `fs/libfs.c` (the offset map for directory
  listings); `rename(2)`, `unlink(2)`, `rmdir(2)`.
* Fuchsia `src/storage/memfs`.
* L4Re `l4re_vfs` and its libc file system back ends.
* POSIX.1-2017, XSH 2.9.7, Thread Interactions with Regular File
  Operations; `rename()`.
* OTP 29.1.2 `erts/emulator/nifs/unix/unix_prim_file.c` and
  `lib/kernel/test/file_SUITE.erl`.
