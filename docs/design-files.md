# Namespaces and file servers

A domain sees files through its **namespace**: a private table from paths
to the file servers it holds, built from what it was granted, with no
global root. A **file server** is any process that speaks the **file
protocol**, which is 9P2000.L: its operations, their fields and their
semantics, carried inside the machine as Erlang terms in frames and at
the machine's edges, the host link and the network, as 9P2000.L's own
bytes. The storage services, the inspector's `/proc` tree, the device
service's `/dev` tree and a session's exports are file servers; Erlang
code reaches them through `prim_file`, and a native program through its
session's **handler**, which is the program's file server and relays its
requests, by one resolver and one protocol. A path is therefore the
visible face of a capability: resolving it can reach only a server the
domain was introduced to, and rearranging a namespace never adds
authority. The architecture is in [design.md](design.md); domains,
connections, exports and facets in [design-domains.md](design-domains.md);
the runtime's file layer in [design-runtime.md](design-runtime.md#files);
programs as ports of their session in
[design-programs.md](design-programs.md#a-program-is-a-port); the trees
that the live machine serves, the command shell that uses them, and the
host's side of 9P2000.L in [design-live.md](design-live.md).

Decisions every reader of this document needs:

* **A namespace is per domain and private.** It maps mount points to
  local providers (the release file system and EROFS images, both
  read-only) and to grants at file servers, named by pid, the domain's
  own RAM file server at `/tmp` among them. The domain service
  builds it at creation from the domain's grants; the domain may bind,
  mount a server it holds and unmount, none of which adds authority. A
  native program's namespace is a table its handler keeps for it, of fids
  the handler walked from its starter's.
* **Holding a path is holding a pid.** A request to a file server is a
  frame to a **grant**, a process of the server that serves a subtree with
  a set of rights to the domain it was made for. The frame travels on the
  connection between the client's domain and the server's, addressed to a
  grant pid the server exported to that domain, and the server's funnel
  refuses anything else ([design-domains.md](design-domains.md#exports)).
  A namespace entry for a grant the domain was never introduced to reaches
  nothing, so no check elsewhere is needed.
* **The server roots every grant.** A grant's root and rights live at the
  server, fixed when the grant is made. erXos's clients walk only plain
  names below it, and a walk of `..`, which a client from outside erXos
  may send, stays at the root when it is made there, as 9P's
  walk(5) specifies and 9P2000.L keeps, so no request reaches above it.
* **The file protocol is 9P2000.L, exactly.** Its operations are
  9P2000.L's, with 9P2000.L's fields and semantics, `symlink`, `link`,
  `lock` and the extended attributes included, and erXos adds none.
  Inside the machine a `version` resets nothing, since every process of
  a domain shares the domain's grants: the one deliberate difference
  ([Version and attach](#version-and-attach)). On a
  connection each message is an Erlang term with the message's fields,
  checked by one generated grammar; at the host link and on the network it
  is 9P2000.L's bytes, through one codec, `erx_9p`, so QEMU's virtio-9p
  serves the development host's tree to the machine and any 9P2000.L
  client mounts an erXos server
  ([design-live.md](design-live.md#files-between-the-host-and-the-machine)).
* **A program's file server is its session.** A program holds no grant,
  no fid and no namespace: every file request it makes is a message on
  its channel to its handler, an Erlang process of the session, which
  checks the program's own table, relays the request to the real server
  over the session's connection, and moves the bytes through memory the
  session mapped into the program's sub-space
  ([design-programs.md](design-programs.md#the-handler)). The handler
  narrows the program's namespace by giving it only fids walked from its
  starter's, so a program cannot be a confused deputy for a file
  server, and a server never sees a program.
* **Resolution is physical, as FreeBSD's.** A path resolves one name at a
  time, as FreeBSD's `namei` resolves it: `.` and `..` act on the
  directory the resolution has reached, so `..` after a symbolic link
  names the parent of the link's target, `..` at the top of a mount or a
  bind steps out to the parent of its mount point, and `..` at the
  domain's `/` stays there, as at a chrooted process's root. They act on
  the client's own record of where it stands, so a server receives only
  plain names, and a server never follows a symbolic link during a walk
  or an open: the client reads the link and resolves its text through
  its own namespace ([Resolving a path](#resolving-a-path)).
* **One resolver, one grammar, one codec.** `erx_path`, a pure,
  preloaded Erlang module with a fuzz target, resolves every path for
  `prim_file` in every runtime and for the handlers of every session,
  over every provider, against one snapshot of the namespace's table. The protocol's terms have one grammar and one
  set of bounds for every client and server, every request goes to a fresh
  alias, so no reply can be forged or reused, and one codec turns the
  terms into 9P2000.L's bytes and back at the edges.
* **One server behaviour.** Every file server is an Erlang callback
  module of `erx_fs`: the storage services, the FAT server, `/proc`,
  `/dev` and a session's export, so one implementation decodes and checks
  the protocol, and every grant and every open file is a process that can
  be inspected, traced and supervised like any other.
* **Files are a view.** Erlang messages stay each service's primary API;
  a file tree is how people and tools reach the same state.
* **A session serves its programs' shared mappings.** `MAP_SHARED` of a
  file is served by the program's session, not by the file's server: the
  session holds one memory object for each file any of its programs maps
  shared, fills it with ordinary reads, maps it into every program of the
  session that maps the file, and writes it back with ordinary writes.
  Programs of one session see one another's stores at once; every other
  domain, a second session that maps the file shared included, sees them
  once they are written back, page by page, as two machines sharing a
  network file system do ([Shared mappings](#shared-mappings)).
* **Names are UTF-8 bytes, never normalised.** A file name is the bytes it
  was given, valid UTF-8 without NUL or `/`, at most 255 bytes.

## Context

A runtime serves two read-only local file systems through `prim_file`
(its release slice and EROFS images), runs its own RAM file server for
`/tmp` ([design-tmp.md](design-tmp.md)), and reaches storage as a
service like any other ([design-runtime.md](design-runtime.md#files)).
Three needs go beyond that: native programs, toybox's applets among them,
need POSIX files over storage and over a session's own files
([design-programs.md](design-programs.md)); the live machine's state
should be readable with `cat`, `ls` and `grep`
([design-live.md](design-live.md#the-proc-tree)); and the user asked that
a domain's file tree show what it holds, as Plan 9's per-process
namespaces do. This design builds on mechanisms that exist:

* connections and exports, which decide which processes of a domain
  another domain may reach, and facets, which confine each grant of a
  system service to one grantee
  ([design-domains.md](design-domains.md#connections),
  [design-domains.md](design-domains.md#facets));
* the funnel at each receiver, which checks every frame against the
  domain's own export table before any process sees it
  ([design-domains.md](design-domains.md#the-funnel));
* aliases, whose reply-mode lifetime protects the protocol's replies
  ([design-domains.md](design-domains.md#exports));
* the session's handler, through which a program reaches everything
  outside its sub-space
  ([design-programs.md](design-programs.md#the-handler));
* the kernel's shared memory objects, which a creator may map into its
  sub-spaces and fill with `erx_mem_copy`, and whose faults the kernel
  resolves from the object's own pages
  ([design-kernel.md](design-kernel.md#virtual-memory));
* `prim_file`'s Erlang interface and its NIF, kept from OTP, with erXos's
  platform layer under them ([design-runtime.md](design-runtime.md#files));
* OTP's file descriptor record, whose module field lets `file` dispatch
  every operation on an open file to the module that opened it.

Prior art: Plan 9's namespaces, `bind` and `mount`, and its user-level
file servers over 9P (R. Pike et al., "The Use of Name Spaces in Plan 9",
1993; the 9P2000 manual, section 5); Inferno's Styx, the same protocol
inside a virtual machine; 9P2000.L, the dialect that carries Linux's file
semantics, which Linux's `v9fs` client, QEMU's virtio-9p server and diod
speak; and Fuchsia's component namespaces, which give each component only
the directories routed to it.

## Requirements

Functional:

1. Every domain resolves paths through its own namespace, and every native
   program through the namespace its handler keeps for it; there is no
   machine-wide root.
2. A namespace maps mount points to local providers and to grants at file
   servers; the domain service builds it from the domain's specification
   and grants.
3. A domain can bind a subtree it sees at another path, mount a server it
   holds, and unmount; a native program receives a namespace at its start,
   narrowed from its starter's, by default its starter's whole namespace.
4. Any service serves a tree by implementing the `erx_fs` behaviour in
   Erlang, as the storage services, the FAT server, `/proc`, `/dev` and a
   session's export do.
5. Erlang code opens, reads, writes, lists and inspects files on file
   servers through the ordinary `file` and `prim_file` interfaces.
6. Native programs do the same through musl's POSIX file functions, over
   `liberx`'s requests to their handler, with open files passed to a child
   sharing their offsets, as POSIX processes share them, and with symbolic
   links, hard links, record locks and extended attributes wherever the
   server's format stores them.
7. Native programs map files shared; within one session every shared
   mapping of a file agrees with every other and with every read and write
   the session's programs make of it, and every other domain sees the
   mapped bytes once the session writes them back.
8. The protocol is 9P2000.L, so the machine mounts a 9P2000.L server's
   tree and a 9P2000.L client mounts an erXos server, at the host link and
   on the network, through one codec.
9. Paths resolve as FreeBSD's resolve them, for Erlang code and native
   programs alike: one name at a time, with `.`, `..` and symbolic links
   taken physically, and FreeBSD's answers for a path that cannot
   resolve or whose last name an operation cannot take.

Non-functional:

* **Bounded.** Every request, reply and per-client state has a fixed
  bound; a client cannot make a server hold more than its bounds, and a
  server spends its own CPU and memory on a client only within its own
  admission.
* **Cheap enough for tools.** A request costs one cross-domain round trip
  plus the copies of its payload; a local provider costs no frame at all;
  walking, opening and reading a file can share one round trip; a
  program's request adds one round trip on its channel and one copy.
* **Compatible.** Stock OTP code that uses `file` on paths works
  unchanged, with the differences listed under
  [Compatibility](#compatibility-and-migration).

Non-goals:

* Shared mappings coherent across sessions: one session's stores reach
  another domain when they are written back, and two sessions that map
  one file shared each hold their own copy ([Shared
  mappings](#shared-mappings)).
* Device special files that reach devices: a server may store a node
  that `mknod` makes, for a format and a client that keep them, and an
  open of one fails, since erXos reaches devices by capability.
* setuid, and 9P2000.L's authentication: a grant's identity is the lane
  its requests arrive on, so `attach` takes no authentication fid.
* A union of several servers at one mount point.

## Overview

```text
  domain D (ERTS)                                      system domain
  +------------------------------------+  connection   +--------------------------+
  | file:read_file("/data/a")          |  (two lanes)  | D's grant on /data       |
  |   prim_file -> erx_path            |-------------->|  (erx_facet, read-write) |---> storage
  |     mount /data -> grant G, "a"    |   9P2000.L    |                          |     service
  |   erx_file_remote: walk, lopen,    |   terms to    | /proc grant for D        |     (Erlang,
  |     read, clunk, each to an alias  |<--------------|  (erx_fs over the        |      erx_fs)
  |                                    |  replies to   |   inspector, D's scope)  |
  | local mounts: / in the NIF, EROFS  |  the alias    +--------------------------+
  |   in erx_erofs; /tmp a grant of D's|
  |   own erx_ramfs server (design-tmp)|
  +------------------------------------+

  session domain (ERTS)                                 storage service
  +------------------------------------+  connection    +--------------------------+
  | handler for program N:             |--------------->| the session's grant on   |
  |   N's namespace: fids walked from  |<---------------|  /data; N's fids among   |
  |   the session's; N's opens         |                |  the session's           |
  | mapper of each file mapped shared  |                +--------------------------+
  +------------------------------------+
     ^ channel: open, read, write    | data area: 64 KiB slots, and each
     | as small terms                v shared object, mapped into N
  +------------------------------------+
  | program N (toybox), a sub-space    |
  |   liberx: descriptors -> requests  |
  +------------------------------------+

  edges: the host link and the network carry 9P2000.L's bytes, through erx_9p
```

A path's journey:

1. The caller's runtime or program resolves the path with `erx_path`, in
   the calling process, from `/` or from its working directory, naming
   what the operation does with the path's last name, over the
   namespace's table as it stands when the resolution starts.
2. `erx_path` reads the path's names against that table, finds the
   entry whose mount point is the longest prefix of where the names lead,
   and asks for the next request through a callback: a walk of names on
   that entry or a read of a link; at the last name it returns the
   operation's action, the operation itself on the names reached.
3. A local provider answers at once, in the calling process: the release
   file system in one call of `prim_file`'s NIF, an EROFS image in the
   EROFS reader, in Erlang.
4. For a grant, the client walks the names from a fid on the grant's root
   in walks of at most 16 names, sending the operation with the last
   walk, such as an `lopen` and a first read; each request is a frame on
   the client's connection to the server, addressed to the grant and
   carrying a fresh alias, and each reply a frame to that alias. The
   client hands a walk's reply back to `erx_path`, which moves on:
   `.` and `..` act on the directories already reached, and a symbolic
   link's text takes the place of its name. A walk that meets a link
   ends there and makes no new fid, so an operation sent with it changes
   nothing and is sent again once the link is followed.
5. The grant checks the request against the protocol's grammar and
   bounds, and against its root and rights, before its callbacks see it.

A native program's path takes the same journey one step removed: the
program sends the path to its handler on its channel, the handler runs
steps 1 to 5 against the program's namespace and fids, and the bytes of a
read or a write move through the program's **data area**, memory the
session made and installed for the program, which maps it ([Native
clients](#native-clients-liberxs-file-client)).

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **F1.** A path never reaches a file server the domain does not hold | a request is a frame on the lane from the client's domain to the server's, addressed to a grant pid; the server's funnel admits a frame only to a pid its runtime exported to the domain that lane belongs to, with `send` ([design-domains.md](design-domains.md#invariants) D3); a grant's pid reaches a domain only through the system domain's introduction of the two; a namespace entry stores only a pid | a request path that names servers by anything but a pid; a server that acts on a pid named inside a request; a runtime that exported a grant to a domain the server did not make it for | a domain test mounts a pid its domain was never introduced to and finds every request fails with `eio`; the funnel's export tests |
| **F2.** No request reaches above its grant's root | a grant's root is fixed at the server when the grant is made; a walk of `..` at the root stays at the root, as 9P's walk(5) specifies and 9P2000.L keeps, and the grammar refuses a name holding `/` or NUL; the server follows no link during a walk or an open, so a link's text is resolved by the client through its own namespace; erXos's clients send neither `.` nor `..`, since both act on the client's place (F11) and every walk `erx_path` asks for carries only plain names, and the client's one request function refuses a walk that names `.`, `..` or an empty name | a server that accepts `/` inside a name, walks above its root on `..`, follows a link during a walk or an open, or roots a grant from anything the client sends after it is made | the resolver's fuzz target and properties; the grammar's refusals; an `erx_fs` test that walks `..` from the root and from below it, and whose links point above the root, at other mounts and in loops |
| **F3.** Rearranging a namespace or narrowing it for a program never adds authority | `bind` copies an entry that exists, narrowed to a subtree; `unmount` removes one; `mount` takes a pid, which by F1 reaches only what the domain holds; a handler gives a program only fids it walked from its starter's fids, with rights in the program's table no wider than the starter's, and walks from them only names the resolver produced | an operation that creates a pid or a fid beyond its source; a handler that walks `..` for a program or records wider rights than its starter's | property tests over sequences of operations: the set of pids in the table only shrinks or gains pids the domain already held; a property test over chains of spawns that every program's mounts lie within, and carry rights within, its starter's |
| **F4.** A client spends a server's CPU and memory only within the server's admission | the protocol checks fid, request, payload and lock bounds before any callback; a grant is one process with a `max_heap_size` that counts its binaries, so what it holds for its client is bounded by its fid pool times the server's per-fid bound; the server runs on its own group's grant and its grant processes schedule among themselves as Erlang processes do, so a flooding client fills its own lane and waits in its own runtime ([design-domains.md](design-domains.md#connections), [design-scheduler.md](design-scheduler.md#service-work)); a blocking lock waits as a pending request of the file's owner, within the client's requests in flight, and nothing in the server blocks | a callback before admission; a grant that holds unbounded state for one fid; a server thread that runs on a client's time; a request whose work grows with the client's input outside the grammar's bounds | hostile-client tests below: fid floods, lock floods, retained `/proc` results, a tiny expensive request, a client that never drains its replies |
| **F5.** A read-only grant never writes | a grant with rights `ro` or `rx` refuses with `erofs`, as part of decoding the request and so before any callback, every operation the protocol's table marks as writing: `lopen` for writing or with truncation, `lcreate` whatever its flags, since whether it creates a file only the server learns, `write`, `setattr`, `remove`, `unlinkat`, `rename`, `renameat`, `link`, `symlink`, `mknod`, `mkdir`, `xattrcreate`, and a write lock | an operation added to the table and not marked; a request that reaches the grant's dispatch by a path other than its decoding funnel | the refusal set is generated from the protocol's operation table, each operation marked as reading or writing; a test of every writing operation through a read-only grant |
| **F6.** No grant carries write and execute together, and a session runs only what it read through an `rx` mount, the file-level twin of K8 | a grant's rights are one of `ro`, `rw` and `rx`, a type with no value for both; an `rx` grant writes nothing (F5); a handler gives a program rights within its starter's, and the session's command server fills a code object only from a fid the handler opened through a mount whose rights are `rx` ([design-programs.md](design-programs.md#file-objects)) | a rights representation with separate write and execute bits; a code object filled from a fid on an `ro` or `rw` mount | the grammar's rights type; a test that running a file through an `ro` and through an `rw` mount fails with `EACCES` and that an `rx` grant refuses every writing operation |
| **F7.** A file's bytes, as one session's programs see them, live in one place per session | while any program of a session maps a file shared, the session's one object for the file holds them: every mapping of the file in the session maps that object, and the handlers send every read, write and size change of the file by the session's programs to the file's mapper, which serves them from the object; the session's file table holds at most one mapper per file, keyed by the server's domain, the tree and the qid path | a second object for one file in one session; a handler that relays such a read or write to the server past the mapper; a mapping installed past the filled extent; a write's bytes put in the object before the server acknowledged them | an exhaustive model of one mapper, its object and its server under interleaved stores, reads, writes the server takes whole, in part or not at all, extending writes, truncations, failed fills and write-backs up to depth 8, against a flat file; two programs of one session, one storing through a mapping and one reading through a descriptor |
| **F8.** Every store through a shared mapping reaches the file's server as an ordinary write, at a point POSIX names | the mapper writes back, with the protocol's `write`, every page the kernel reports as stored to since the last write-back (`erx_mem_dirty`), at `msync`, at every close of a mapping's open (a program's last `munmap` of the file, its `exec` and its end) and at the `close` that leaves the session's programs no open of the file, and deletes the object only after its last write-back; a write-back that fails is returned to the call that caused it, or logged at a program's end ([Shared mappings](#shared-mappings)) | an object deleted before its last write-back; a stored page the report leaves out; a program's end that the mapper does not see; a failed write-back reported nowhere | a test per write-back point, reading the file through another domain after it; a store made while a write-back runs, which the next write-back carries; a server that fails a write-back, whose `msync`, `munmap` and `close` return `EIO` and whose program's end leaves a log line |
| **F9.** A program reaches a file only through its handler | a program's sub-space holds its channel, its data area and the memory its session mapped, and nothing else: no grant pid, no fid, no lane to any server; its handler acts only on the program's own table, the fids it walked for it and the files it opened ([design-programs.md](design-programs.md#invariants)) | a capability to a lane or a grant installed in a sub-space; a handler that acts on a fid outside the program's table | a sub-space test that enumerates a program's capabilities and finds only its channel and mapped memory; a hostile program that names another program's open numbers, every request failing with `EBADF` |
| **F10.** A fid ends exactly once, and, if nothing ended it before, when the grant handles its owner's `DOWN` | the grant's fid table is the one record of a fid and the grant alone ends one, at its `clunk`, its `remove`, its owner's end or the grant's end; the grant monitors every owner, signals between two processes keep their order, so an owner's `DOWN` follows every request it sent, and monitoring a process that has already ended delivers its `DOWN` at once, as OTP's monitors do ([Fid owners](#fid-owners)) | a fid made without its owner monitored; a client that keeps its own record of fids to clean up | the exhaustive model of a grant's fid table with owners' ends among its events; the ended-owner and killed-opener tests ([design-tmp.md](design-tmp.md#verification)) |
| **F11.** Every name of a resolution's place is a directory the resolution reached | a name joins the place only when a walk's reply gives it a directory's qid, or when it is an entry's mount point or lies above one, a directory of the namespace itself; `..` removes the place's last name, nothing at `/`, and `.` leaves the place as it is, so neither acts on a name not yet walked; the parent of a place is therefore the directory the walk came down through, which makes `..` physical, and at an entry's top it is the parent of the entry's mount point ([Resolving a path](#resolving-a-path)) | a resolver that adds a run's names to the place before their walk answers; a `..` that removes a name of the run; a walk that carries `.` or `..` | the resolver's fuzz target, differential against a reference model of FreeBSD's lookup; its property that no walk names `.` or `..` |

## Data model

### Namespaces

```erlang
%% One entry of a namespace. Built by the domain service for a domain, or by
%% a session's handler for each program it starts; a domain's changes only
%% through erx_ns:bind/2,3, erx_ns:mount/3 and erx_ns:unmount/1.
-type entry() :: #{point := [name()],      % the mount point as plain names;
                                           % [] is /
                   provider := provider(),
                   root := [name()],       % for a bind: where in the provider
                                           % or grant the entry starts; else []
                   rights := rights()}.    % the grant enforces them for the
                                           % domain, the handler for each
                                           % program

-type provider() :: release                % the domain's release slice,
                                           % read-only
                  | {erofs, image()}       % an EROFS image the domain holds
                                           % a window on
                  | {grant, pid(), Tree :: name()}
                                           % a grant at a file server, by pid,
                                           % and the tree it roots in, its
                                           % attach name
                  | ended                  % a grant that has ended: every
                                           % request answers eio, unsent
                  | {fid, fid()}.          % a program's mount, in its
                                           % handler's table: the fid the
                                           % handler walked for it

-type rights() :: ro | rw | rx.            % no value writes and runs
                                           % together (F6)

-type table() :: [entry()].                % at most ERX_NS_MOUNTS_MAX (64)
-type place() :: [name()].                 % absolute; every name a directory
                                           % reached (F11)
-type name() :: binary().                  % plain: 1 to 255 bytes of UTF-8,
                                           % not . or .., without / or NUL
```

`ERX_PATH_MAX` is 4,096 bytes, a name is at most `ERX_NAME_MAX`, 255
bytes, and a path has at most 256 names. These limits live in
`abi/erx_abi.txt` and reach Erlang through its generated header. A runtime
keeps one namespace for all its processes, a table held in one persistent
term that only `erx_ns`'s process writes ([Building, binding and
mounting](#building-binding-and-mounting)), and its working directory, a
place held as one binary in `prim_file`'s NIF that only `set_cwd` writes
([Erlang clients](#erlang-clients-prim_file-and-erx_file_remote)). A
session's handler keeps one table for each program, in its own state,
whose entries carry the fid of each mount as their provider, so a
program's sub-space holds no namespace at all. The resolver reads only an
entry's `point` and `root`; the rest is its callers'. The table is a
term read in place from the persistent term by every resolution, so a
domain's file state costs one copy of it, a few KiB for a typical domain
and bounded by the limits above, and nothing on any server until it
walks; a resolution that still holds a table when it is replaced gets
its own copy at the global collection that follows, which counts
against that process's heap. A `root` other than `[]` comes only from
`bind` within the domain, whose authority is the grant it already holds,
or from a handler's narrowing for a program, whose authority is its
starter's fid. A grant entry's tree arrives with its pid, from the facet
or from `erx_ns:mount`'s options, and the grant checks it at every
`attach`, so a client never keys a file by a tree its grant does not
root in ([Identity and version](#identity-and-version)).

### The file protocol

The file protocol is 9P2000.L. Its messages, fields and semantics are
those of 9P2000.L, which extends 9P2000's version, attach, walk, read,
write, clunk, remove and flush with operations that carry Linux's file
semantics; erXos defines no operation of its own. Inside the machine it
departs from 9P2000.L in two places only: `version` resets nothing
([Version and attach](#version-and-attach)), and `write`'s reply also
names the offset its bytes were written at ([Open files and
offsets](#open-files-and-offsets)). Inside the machine each message is an
Erlang term whose fields are the message's fields in 9P2000.L's order,
decoded on both sides by the funnel's grammar and then by the protocol's own, the **frame profile** of
`abi/erx_abi.txt`, so every field is checked once against the table below.
A request travels as `{erx_9p, Alias, Owner, Request}` to a grant and its
reply as `{erx_9p, Alias, Reply}` to `Alias`, which plays the part of 9P's
tag; `Owner` is the process that will hold any fid the request makes
([Fid owners](#fid-owners)). A
reply is `ok` for a 9P2000.L reply that has no fields, `{ok, Field...}`
otherwise, and `{error, Posix}` for `Rlerror`: inside the machine an error
is always OTP's `file:posix()` atom that names the Linux error (`enoent`
for `ENOENT`), and only the codec at an edge turns it into Linux's number
and back ([Errors](#errors)).

| Operation | Request term | Reply term | erXos's servers |
| --- | --- | --- | --- |
| version | `{version, Msize, Version}` | `{ok, Msize, Version}` | answered with the smaller of the client's `Msize` and the server's, 65,560 inside the machine, never more than the client offered; a `Msize` below 4,096 is refused, as Linux and QEMU refuse it; a version other than `<<"9P2000.L">>` is answered `<<"unknown">>`; inside the machine it changes nothing ([Version and attach](#version-and-attach)) |
| auth | `{auth, Afid, Uname, Aname, NUname}` | `{error, enotsup}` | not served: a grant's identity is its lane's, so authentication is not required, and the answer is `Rlerror`, as diod answers when it requires none |
| attach | `{attach, Fid, Afid, Uname, Aname, NUname}` | `{ok, Qid}` | `Fid` then names the grant's root; `Afid` is `?NOFID`, since `auth` is not served; `Aname` names the tree the grant roots in, and any other name fails with `enoent`; `Uname` and `NUname` are recorded and grant nothing |
| walk | `{walk, Fid, NewFid, Names}` | `{ok, Qids}` | at most 16 names; `Fid` not open, as walk(5) asks and erXos's servers enforce; `NewFid` not in use unless it equals `Fid`; a failure at the first name is an error reply; a walk that passes at least one name and then fails lists the qids it walked and leaves `NewFid` unused; `NewFid` names the result only when every name was walked; a walk from a symbolic link fails at the next name |
| lopen | `{lopen, Fid, Flags}` | `{ok, Qid, Iounit}` | `Flags` 9P2000.L's open flags ([Flags](#flags)); a link fails with `eloop`, a device node or FIFO with `enxio`; `Iounit` 65,536 inside the machine |
| lcreate | `{lcreate, Fid, Name, Flags, Mode, Gid}` | `{ok, Qid, Iounit}` | `Fid` a directory, after which it names the file, open, so no unopened fid of the file remains; one atomic step that creates the file, or, without `EXCL`, opens the regular file `Name` already names with `Flags`, `TRUNC` included, as QEMU's `openat` with `O_CREAT` does; `eexist` with `EXCL` for any existing name, a dangling link included; `eloop` for a link without `EXCL`, which the client then follows; `eisdir` for a directory |
| symlink | `{symlink, Fid, Name, Target, Gid}` | `{ok, Qid}` | `Target` at most 4,095 bytes, Linux's limit, stored as given; where the format keeps no links, `eperm` |
| mknod | `{mknod, Dfid, Name, Mode, Major, Minor, Gid}` | `{ok, Qid}` | stored where the format keeps nodes, `eperm` elsewhere |
| rename | `{rename, Fid, Dfid, Name}` | `ok` | both fids of this grant |
| renameat | `{renameat, OldDirFid, OldName, NewDirFid, NewName}` | `ok` | both fids of this grant |
| unlinkat | `{unlinkat, DirFid, Name, Flags}` | `ok` | `Flags` 0 or `AT_REMOVEDIR` |
| readlink | `{readlink, Fid}` | `{ok, Target}` | `Fid` a symbolic link |
| getattr | `{getattr, Fid, RequestMask}` | `{ok, Attr}` | `Attr` a map whose keys are 9P2000.L's field names, `valid` to `data_version`; erXos's servers set `valid` to the basic fields and the `data_version` bit ([Identity](#identity-and-version)) |
| setattr | `{setattr, Fid, Attr}` | `ok` | `Attr` a map of 9P2000.L's fields, `valid` naming those set; a `uid` or `gid` other than the file's own fails with `eperm`, and the file's own changes nothing but `ctime`, as a `chown` to its own owner does; a size set through an opened fid needs that fid opened for writing, whatever the file's mode, and fails with `einval` otherwise, as FreeBSD's `kern_ftruncate` does; a size set through an unopened fid needs the file's write permission, as `truncate` does |
| xattrwalk | `{xattrwalk, Fid, NewFid, Name}` | `{ok, Size}` | `NewFid` then reads the value, or the list of names for an empty `Name` |
| xattrcreate | `{xattrcreate, Fid, Name, Size, Flags}` | `ok` | `Fid` then takes writes of `Size` bytes, at most 65,536, committed at its clunk; `enotsup` where the format keeps none |
| readdir | `{readdir, Fid, Offset, Count}` | `{ok, Entries}` | `Fid` an open directory; each entry `{Qid, Offset, Type, Name}`, `Type` Linux's `d_type`, not the qid's type, the entries fitting in `Count` bytes as 9P2000.L packs them; an empty list at the end of the directory |
| fsync | `{fsync, Fid, Datasync}` | `ok` | once the server's medium holds the file's data |
| lock | `{lock, Fid, Type, Flags, Start, Length, ProcId, ClientId}` | `{ok, Status}` | POSIX record locks ([Locks](#locks)) |
| getlock | `{getlock, Fid, Type, Start, Length, ProcId, ClientId}` | `{ok, Type, Start, Length, ProcId, ClientId}` | the same table |
| link | `{link, Dfid, Fid, Name}` | `ok` | where the format keeps hard links, `eperm` elsewhere |
| mkdir | `{mkdir, Dfid, Name, Mode, Gid}` | `{ok, Qid}` | |
| statfs | `{statfs, Fid}` | `{ok, Statfs}` | `Statfs` a map of 9P2000.L's fields, `type` to `namelen` |
| read | `{read, Fid, Offset, Count}` | `{ok, Data}` | `Count` at most 65,536 inside the machine ([Bytes](#how-a-request-names-its-bytes)) |
| write | `{write, Fid, Offset, Data}` | `{ok, Count, At}` | `Data` at most 65,536 bytes inside the machine; 9P2000.L's count field is `Data`'s size; `At` the offset the bytes were written at, the file's end for an append fid, which 9P2000.L's `Rwrite` does not carry: the codec drops it at an edge and reads an `Rwrite` from outside as `At` = `unknown` ([Open files and offsets](#open-files-and-offsets)) |
| clunk | `{clunk, Fid}` | `ok` | releases the fid's locks |
| remove | `{remove, Fid}` | `ok` | `Fid` is clunked whatever the outcome |
| flush | `{flush, OldTag}` | `ok` | `OldTag` the alias of a request; answered `ok` for a completed or unknown request too ([Flush](#flush)) |

A `Qid` is `{Type, Version, Path}`, 9P2000.L's eight-bit type, 32-bit
version and 64-bit path. Fids, modes, flags and masks are the integers
9P2000.L gives them, so the codec at an edge moves each field without
translating it, but for the error numbers. A request on a fid the grant
does not hold fails with `ebadf`. 9P2000.L's wire constants, its message
type numbers, `NOTAG`, `NOFID`, `MAXWELEM` and `getattr`'s mask bits,
live in `abi/erx_abi.txt` with the operation table, and every client,
server and codec takes them from there.

#### Flags

`lopen`'s and `lcreate`'s flags are 9P2000.L's fixed `P9_DOTL` values, the
octal numbers of Linux's `9p.h` in x86 numbering (`DIRECTORY` 0200000,
`NOFOLLOW` 0400000, `CLOEXEC` 02000000 and the rest), never a sender's
native open flags, which differ on AArch64: a handler maps a program's
open flags to them, and the terms carry them, so the codec moves them
unchanged. Linux's client sends every flag but `TRUNC`, truncating through
`setattr`, and QEMU's server acts on `EXCL`, `TRUNC`, `APPEND`,
`NONBLOCK`, `DSYNC`, `SYNC`, `NOATIME`, `LARGEFILE`, `DIRECTORY` and
`NOFOLLOW` and ignores the rest. erXos's servers act on the access mode,
`TRUNC`, `APPEND`, `EXCL`, `DIRECTORY` and `NOFOLLOW` and ignore the rest.

#### Version and attach

At an edge, `version` opens a 9P session and resets it, and `attach` makes
a root fid, as 9P2000.L says; the host link's bridge, whose client starts
afresh with a new host-link session, serves only the `version` that opens
its session
([design-live.md](design-live.md#files-between-the-host-and-the-machine)).
Inside the machine, a grant is one client domain's session with the
server from the moment the server makes it, and every process of the
client domain shares it, so a `version` there is
answered with the protocol's name and the smaller of the client's message
size and 65,560, and resets nothing: one process's `version` must not
clunk the fids of the many processes that share the grant. That is the
one deliberate difference from 9P2000.L inside the machine; every other
operation has its full meaning.

`attach`'s `Aname` names a **tree**: one file system that a server
serves, such as a partition's volume, an image or `/proc`. One domain
may serve several trees, and every grant roots in one of them. At an
edge the name selects one of the trees the bridge lists
([design-live.md](design-live.md#files-between-the-host-and-the-machine));
inside the machine it must be the name of the tree the grant roots in,
which the client's namespace entry records with the grant's pid. A client
takes a fid on the grant's root with `attach`, as often as it likes, each
attach a fid of its own.

Fids are the client's to choose, as in 9P. A runtime draws them for all
its processes from one counter, a 64-bit atomic in `prim_file`'s NIF,
and a session's handlers from the session's: the NIF adds one and takes the low 32 bits, drawing again for `NOFID`, so a
draw is one atomic add in the calling process and no process allocates
fids. A number therefore comes back, on any grant and to any owner,
only after every other number has been drawn, over four billion fids
later, and two processes of one domain never share a fid on one grant:
if a fid is still alive when its number comes round again, the `attach`
or `walk` that names it as new fails with `einval`, as QEMU's server
answers a fid in use, and the client's operation fails with it rather
than act on another's fid. A request that names a fid after its end,
sent late on an ended owner's behalf, meets no fid and fails with
`ebadf`. The counter keeps no record of the fids it drew: the grant's
fid table and its monitors on owners are the one record of which are
alive ([Fid owners](#fid-owners)).

#### Fid owners

Every fid has an **owner**, a process of the client's domain that the
request making the fid names in its `Owner` (an `attach`, a `walk` to a
new fid, an `xattrwalk`), fixed for the fid's life. The grant monitors
each process that owns a fid it holds, and when one ends, clunks every fid
that process still owns, as if it had sent the clunks. So a fid ends
exactly once, at its `clunk`, its `remove`, its owner's end or its
grant's end, whichever comes first, and the grant's fid table, the one
record of it, is the one place that ends it. Two facts of Erlang order
this against requests still on their way. Signals from one process to
another arrive in the order sent, across domains too
([design-domains.md](design-domains.md#invariants), D9), so an owner's
`DOWN` reaches the grant after every request the owner sent itself. A
request another process sent on the owner's behalf can arrive after the
owner's `DOWN`; the grant then finds the owner unmonitored and monitors
it again, and OTP delivers the `DOWN` of a monitor on a process that has
already ended at once, so the grant clunks the new fid when it handles
that `DOWN`, behind whatever already waits in its queue. A request in
flight from a process that ends therefore never leaves a fid behind, and
by the counter's rule above never meets a fid made again for someone
else.

`Owner` governs a fid's lifetime, not authority: any process of the
client's domain may use or clunk any of the grant's fids, and the grant
draws no line between the processes of one domain. Between a session's
programs the line is the handlers' tables (F9). Each client names owners so that a
fid lives as long as what holds it: an Erlang process makes its path
operations' fids and its open files' fids as their owner
([Erlang clients](#erlang-clients-prim_file-and-erx_file_remote)), so a
file closes when the process that opened it ends, as a stock raw file
closes when its controlling process does; a session's handler names an
open-file description's process as the owner of the description's fids,
and itself as the owner of the fids it holds for its program's namespace;
and a 9P bridge owns every fid it holds for its edge. An `Owner` that is
not a process of the client's domain is refused with `einval`. A grant
holds at most one monitor per owner, and removes it, with
`erlang:demonitor/2`'s `flush`, when the owner's last fid ends, so it
monitors only processes that own a fid it holds, never more than its
pool ([Bounds](#bounds)).

#### How a request names its bytes

Inside the machine a read's or a write's bytes travel in the frame, as the
binary `Data`, and the frame lives in the lane of the domain that reads
it, memory that the two domains share and that the reader's budget paid
for ([design-domains.md](design-domains.md#connections)): the sender's
runtime copies the bytes into the lane once and the receiver's funnel
copies them out once. A program names its bytes by a slot of its data
area, memory its session made for it and maps ([Native
clients](#native-clients-liberxs-file-client)), and the handler moves them
between the slot and the frame. The frame profile bounds a read's `Count`
and a write's `Data` at 65,536 bytes, a data area's slot, which is what
erXos's clients agree with `version`. `msize` bounds a message only at an
edge, where 9P2000.L's bytes cross: the host link negotiates 8,192, enough
for the largest message of every operation, a walk of 16 names of 255
bytes or a `symlink` of a 4,095-byte target included, and virtio-9p
65,560. A 9P header is 7 bytes, its size, type and tag; a `write`'s fixed
part is 23 bytes and a read reply's 11; and Linux and QEMU reserve 24
bytes, `P9_IOHDRSZ`, for the largest of these, so an `msize` of 65,560
gives an `Iounit` of 65,536 ([The codec](#the-codec)).

#### Identity and version

A file's **identity** is its server's domain, the tree it lies in
([Version and attach](#version-and-attach)) and its qid's `Path`, and its
**version** is the 64-bit `data_version` of `getattr`, which 9P2000.L
reserves and erXos's servers fill; `Version` in the qid is its low 32
bits. A server keeps qid paths unique within a tree and never gives a
path to a second file while its domain lives; how each format draws them
is in [design-storage.md](design-storage.md#read-write-storage). Every
server draws a file's version from one counter of its domain's
runtime, shared by every file server of the domain and kept across a
server's restarts, when it first meets the file and at every change to the
file's data or size, in the same step that makes the change visible to
reads; the counter starts at 1, and a server whose counter would pass 2^64
- 1 refuses every change with `eio` and reports it. The counter is an
unsigned 64-bit `atomics` cell that the runtime makes once, before any
file server starts (in its kernel application's startup, in
`kernel_safe_sup`'s `init/1` before its children), and publishes through
`persistent_term`, so it lives
as long as the runtime and no server's restart resets it. A server draws
from it with a `compare_exchange/4` loop that refuses at 2^64 - 1, since
`atomics:add_get/3` would wrap to 0 and hand out old values again. A
domain's id is never
reused, so domain, tree, path and version together never name two
different contents, across a server's restarts and its domain's, which
lets a client cache a file's bytes under them, as a session's file objects
do ([design-programs.md](design-programs.md#file-objects)). A client knows
a version only from a `getattr` reply whose `valid` mask carries the
`data_version` bit, never from the value. A server that leaves the bit
clear, as QEMU's 9P2000.L server and any other server from outside erXos
may, gives its files an identity of domain, tree and path alone and no
version, and from such a server a client trusts only an entry's qid
path, since QEMU without inode remapping gives `readdir`'s qids a zero
type and version: a client caches nothing of such a file under a
version, so a session reads it afresh for every map and shares no file
object of it among programs, and a session's file table still finds one
entry for it by its domain, tree and path.

#### Errors

`Rlerror` carries a Linux error number; on a connection it is `{error,
Posix}`, with an atom of OTP's `file:posix()` that names the same error
(`enoent`, `eacces`, `eperm`, `eexist`, `enotdir`, `eisdir`, `enotempty`,
`erofs`, `enospc`, `efbig`, `einval`, `ebadf`, `emfile`, `enfile`, `eio`,
`enametoolong`, `enotsup`, `eloop`, `enxio`, `exdev`, `enomem`, `eagain`,
`enodata` for a missing extended attribute, `erange` for a buffer too
small for one, and `enolck`); an atom outside that list is refused by the
grammar. The wire carries Linux's numbering, and the codec reads an error
number outside the list as `eio`, which also covers a server that answers
in another system's numbering, as QEMU's does on a macOS host
([design-live.md](design-live.md#files-between-the-host-and-the-machine)).

#### Flush

`flush` names a request. flush(5) says the server should answer it at
once, and that a reply to the flushed request that arrives before the
flush's answer stands: its effect happened and the client takes it. A
`flush` of a completed, unknown or flush request is answered `ok` too,
never with an error. erXos's servers, as QEMU's, answer a `flush` only
after they have answered the flushed request or abandoned it, so a tag,
and inside the machine an alias, is never reused while its request could
still be answered. A client that flushes a request deactivates its alias
once the flush is answered, so nothing arrives after. A flushed read of a
terminal therefore either returned a line or took none ([Native
clients](#native-clients-liberxs-file-client)).

#### Open files and offsets

9P2000.L keeps no offset at the server: every `read` and `write` names
its offset, and the client keeps the file's position. A server holds, for
each open fid, the callback's handle, and orders the reads, writes, size
changes and locks of each open file through one process, the file's
**owner**, which `erx_fs` starts at the file's first open and ends at its
last clunk, so each `read` and `write` request on a regular file is
atomic with respect to every other whichever fids they come through, as
POSIX asks of regular files. The unit is one request of at most 64 KiB: a
caller's write larger than that is several requests, each atomic, which
another writer's requests may fall between, as over Linux's own 9P2000.L
client; a request refused part way through such a write, with `enospc`
say, leaves the requests before it written, and the caller gets the
error with its offset advanced past what was written, as stock
`prim_file` returns an error after a short write. A caller's read
larger than a unit is several requests too, sent until the count is
read or a reply comes back shorter than its request, as at the end of
the file, so a read of a regular file answers every byte up to its
end, as stock's does; an error after some requests answers the bytes
they read. A fid opened with
9P2000.L's append flag writes at the file's end whatever its offset, a
rule of erXos's servers rather than of the protocol, and a positioned
write through it appends too, as Linux's `pwrite` does on a file opened
with `O_APPEND`.

Where an append landed is known only to the server, at the step that
placed it, and a later `getattr` cannot recover it, since another
append may have landed since. So inside the machine `write`'s reply
carries `At`, the offset its bytes were written at. An `Rwrite` from a
server outside erXos carries none, and the codec reads it as `At` =
`unknown`. A client that keeps an offset sets it after a write by one
rule:

* `At` a number: `At` plus the count, which puts an append fid's offset
  after its own bytes, as Linux's `write` with `O_APPEND` does;
* `At` = `unknown` through a fid without the append flag: the offset the
  write was sent at plus the count, where such a server put the bytes;
* `At` = `unknown` through an append fid: the file's size from a
  `getattr` sent once the write's reply has arrived, as Linux's own
  9P2000.L client reads it, which can count another client's later
  append, a limitation of 9P2000.L that erXos's servers do not share;
* a positioned write (`pwrite`, `file:pwrite/3`): the offset stays where
  it was, whatever the reply.

Offsets live with the client. An Erlang process's open file keeps its
offset in its descriptor record ([Erlang
clients](#erlang-clients-prim_file-and-erx_file_remote)). For a program,
an open names an **open-file description**, a process of the session that
holds the offset, the status flags and two fids, where POSIX puts them:
an **unopened fid** of the file and an **opened fid**, and after a
change of `O_APPEND` a second opened fid (below). A description's
unopened fid, while it has one, names the file its opened fid opened.

The two fids arise when the handler opens the file, which makes every
fid of a description with the description's process as its owner
([Fid owners](#fid-owners)). `lopen` opens a fid
in place, so for an open without `O_CREAT` the handler walks the path to
the unopened fid, clones it with a walk of no names, and opens the clone
with `lopen`, which makes the clone the opened fid. `lcreate` turns a
directory's fid into the created file's opened fid, so for `O_CREAT` the
handler walks the path's directory to one fid, clones it with a walk of
no names, sends `lcreate` on the clone, and then walks the file's name
from the directory's first fid, in place, to make the unopened fid: one
walk more than an open. When `lcreate` fails, the handler clunks both
fids and returns its error.

A rename between the `lcreate` and that last walk can make the name reach
another file. So the handler compares the walked qid's path with the
path in `lcreate`'s qid; when they differ, or the walk fails, it clunks
the walked fid, and the description keeps its opened fid alone. Its
reads and writes go on through that fid.

9P2000.L walks only from an unopened fid, so every further open of a
description's file, a narrowed copy, a re-open with other flags or a
mapping's open, clones the unopened fid with a walk of no names and opens
the clone. A description that kept only its opened fid answers each such
open with `ESTALE` until it closes.

A description takes every lock through the opened fid it was opened with,
which it keeps for its life ([Locks](#locks)). A change of `O_APPEND` with
`fcntl`'s `F_SETFL` opens, at the first change, a second opened fid,
cloned from the unopened fid and opened with the other append flag; from
then on the description writes through whichever of its two opened fids
carries its current flag, and keeps both until it ends. So a description
holds at most two opened fids, and changing a status flag never ends a
lock.

Every open in any program that names a description shares it, so they
share its offset as POSIX processes do; the description runs the reads
and writes that use its offset in turn and sends each with an explicit
offset, as 9P2000.L does. Passing an open, by a spawn, a fork or
`SCM_RIGHTS`, gives the receiver an open naming the same description and
asks nothing of the server. A description passes only among the programs
of one session, so the session holds every description its programs share.
It clunks every fid it holds when the last open naming it closes, so a
passed file lives as long as an open names it, as on UNIX
([design-programs.md](design-programs.md#descriptors-and-files)).

#### Locks

`lock` and `getlock` are POSIX record locks with 9P2000.L's semantics,
kept by each file's owner at the server for every grant that opens the
file. A lock's owner is the client's domain, from the lane the request
arrived on, with the request's `ProcId`; `ClientId` is recorded and
decides nothing, so no domain can release or test another domain's locks
as its own. A session gives each program a `ProcId` of its own, so its
programs' locks conflict with each other as UNIX processes' do. A read
lock needs a fid open for reading and a write lock a fid open for writing.
A request without 9P2000.L's `BLOCK` flag that conflicts is answered
`blocked` at once; one with it is held, as a pending request of the file's
owner, an Erlang process's wait in which nothing in the server blocks,
until the lock is granted or the request is flushed, and it counts among
the client's requests in flight. erXos's clients send `BLOCK` for a
blocking `fcntl` lock, so they wait no longer than the holder holds;
Linux's client, which retries a `blocked` lock after sleeping 30 s, waits
at an edge as long as Linux makes it. A lock ends when its owner unlocks
it, when the fid that took it is clunked, or when its grant ends. A
program's locks on a file, keyed by its `ProcId`, also end at every close
by the program of a descriptor of that file, whichever description the
descriptor named, as POSIX says: `liberx` tells the handler of each close,
a `dup`'s included ([Native clients](#native-clients-liberxs-file-client)),
and the handler sends an unlock of the whole file for that `ProcId` when
the program holds a lock on the file. They end too when the program ends,
whether or not a sibling still holds the description they were taken
through: the handler then sends, on each file the program locked, the
same unlock.

#### Who a grant is for

Every grant is made by the server for one client domain, when the system
domain introduces the two, as the domain service does when it builds a
domain's namespace
([design-system.md](design-system.md#creating-a-domain)), with a root and
rights the server's policy fixes. A grant's pid is the server's, and only
the server's runtime exports it, so a holder cannot hand a grant to
another domain by forwarding its pid. Within one domain a grant's pid is
an ordinary pid, so a session's handlers use the session's grants for
every program of the session.

A grant names its client domain as `own`, the server's own domain, or by
the other domain's id. Every message from another domain arrives in the
envelope `{erx_origin, D, Msg}`, `D` set by the connection it came on
([design-domains.md](design-domains.md#the-peer)), and `erx_fs` owns the
file protocol, so its funnel takes the envelope off its own frames: a grant
for another domain takes a frame only in an envelope whose `D` is its
client's id, and one for its own domain only bare. Every other frame is
dropped and counted, whatever it names, so a third domain that holds the
grant's pid cannot act as the client. The names a frame carries, its alias
and its owner, are the client domain's by `erx_dist:owner/1`, the creation
each name carries, for another domain, and by their node for the server's
own. Both checks compare creations, which holds because a domain's id is
the creation of its lane alone, never one a node of another machine
presents
([design-domains.md](design-domains.md#domain-ids-pids-and-references)).
A process of the server's own domain is inside the server's trust
boundary and can reach the tree without a grant.

#### Bounds

At every server, each grant holds at most its **pool** of fids, 4,096 by
default, which the server's policy may set for each grant; at most 64
requests in flight; and at most 256 locks. A request beyond a bound fails
with `emfile` or waits in the client, never at the server. A `clunk` or
`remove` that is refused, at a bound or otherwise, still ends its fid, as
clunk(5) and remove(5) say, so a refused clunk never keeps a file, and the
space it holds, for as long as its owner runs. A name is valid
UTF-8 without NUL or `/` and at most 255 bytes; a walk holds at most 16
names, a symbolic link's text at most 4,095 bytes, an extended attribute's
value at most 65,536 bytes. A session's handlers draw their programs'
fids from the session's grants, at most 256 for each program, and leave a
quarter of each grant's pool to the session's own processes, so the
programs a session starts cannot spend the fids the session needs to go
on working; they share the rest, as they share the session's budget
([Security](#security)).

A reply is held to its request. For each operation the generator of the
frame profile emits a check of a reply against the request it answers,
which `erx_file_remote` and each 9P bridge apply before they use the
reply: a read's `Data` is no longer than its `Count`, a write's `Count`
no larger than the bytes it sent, a walk's qids no more than its names,
and a `readdir`'s entries no more than its `Count` bytes as 9P2000.L
packs them. A reply that fails its check reaches the caller as `eio`,
and the client counts it. `liberx` copies no more than the count it asked
for, whatever count its handler answers.

#### Pipelined requests

A grant handles its client's requests in the order they arrive, a
guarantee of erXos's servers rather than of the protocol, whose intro(5)
lets a server reorder, so a client may send a walk, an `lopen` and a first
read on the new fid together, one round trip for all three. A client of a
server from outside erXos, as the host-tree domain's bridge is of QEMU's,
which runs each request on its own, waits for a reply before it sends a
request that depends on it. An alias names one request: a request sent
to an alias whose earlier request the grant still waits to answer is
refused with `einval`. A walk that stops before its last name makes
no new fid, as 9P2000.L says, so a request sent with it on that fid fails
with `ebadf`; a walk in place that stops leaves its fid where it was, so
a client sends a request with a walk only on the walk's new fid, and
uses a fid it walked in place only once the walk's reply has arrived. A
walk that ends on a symbolic link leaves the fid on
the link, where `lopen` fails with `eloop`; a pipelined open, `setattr` or
`remove` therefore never acts on a link in place of the file the path
named, and the client learns of the link from the walk's reply and follows
it itself ([Resolving a path](#resolving-a-path)).

### The codec

`erx_9p` turns the protocol's terms into 9P2000.L's bytes and back, for
the edges where 9P2000.L crosses: the host link, virtio-9p and the
network ([design-live.md](design-live.md#files-between-the-host-and-the-machine),
[design.md](design.md#networking)). It is one Erlang module, generated
by the Ruby generator that produces the frame profile's decoder, from the
same operation table of `abi/erx_abi.txt`, which records each message's
9P2000.L layout, so the terms and the bytes can never disagree. Decoding
reads the message's size, checks it against the negotiated `msize` and
the bytes received, then each string's length and each count against
what remains, requires valid UTF-8 for names, creates no atom, and either
returns the term or refuses the message; it has a fuzz target that runs
on the host's stock OTP. A request is the grammar's request term, except
that `flush`'s `OldTag` is the edge's u16 tag, which the bridge maps to
an alias as it maps every tag; a reply is `{reply, Operation, Reply}`
with the grammar's `Reply`, and an `Rlerror`, whose bytes name no
operation, decodes as `{reply, error, {error, Posix}}`. The module
belongs to the `erx` application rather than the preloaded set, since
only the bridges, which are services, use it. An error number maps to
its `file:posix()` atom through a generated table of Linux's numbers.

A **9P bridge** joins an edge to the grants inside: it keeps, for the
edge's 9P session, a table from the edge's fids to fids it holds on a
grant, at most 256, as many as a session's program holds, so an edge
never spends the fids a grant's other owners need, and from the edge's
tags to aliases, and relays each message through `erx_9p` in one direction and as
a term in the other, holding each reply to its request
([Bounds](#bounds)). The host link's bridge serves erXos's trees to a
client on the host; the host-tree domain's bridge serves QEMU's 9P server
to erXos's clients
([design-live.md](design-live.md#files-between-the-host-and-the-machine)).
A bridge's 9P session ends with its edge, and every fid it holds on a
grant with it.

## Algorithms and behavior

### Resolving a path

Paths resolve as FreeBSD's `namei` and its `vfs_lookup` resolve them
(`sys/kern/vfs_lookup.c`): one name at a time, from the domain's `/` or
from the working directory, with `.` and `..` taken in the directory the
resolution has reached and symbolic links followed on the way, so `..`
after a link names the parent of the link's target. The namespace
settles the two places where FreeBSD's rules meet something other than a
directory of one file system. The domain's `/` is the root a resolution
cannot leave, as a chrooted process's root is, so `..` there stays there.
An entry's top stands where the root of a mounted file system stands, so
`..` there steps out to the parent of the entry's mount point, as
FreeBSD's `..` crosses back through the directory a mount covers.

**The place.** A resolution keeps its **place**: the namespace path of the
directory it has reached, every name of which is a directory the
resolution reached (F11). A name joins the place only when a walk answers
it with a directory's qid, or when it is an entry's mount point or lies
above one, which are directories of the namespace itself. `..` removes
the place's last name, nothing at `/`, and `.` leaves the place as it is.
A name the path has not yet walked is never in the place, so `.` and `..`
act only on walked names: `missing/..` answers `enoent` and `file/.`
answers `enotdir`, as FreeBSD's do. Each name of the place was reached by
walking down into it, so removing the last one gives the directory the
walk came through, which is what FreeBSD's `..` gives; and the place is a
namespace path, so at an entry's top removing the last name gives the
parent of the entry's mount point. `.` and `..` therefore never reach a
server, every walk carries only plain names (F2), and an entry's top, a
bind's root, a narrowed program's mount and `/` need no rule of their
own.

**The resolver.** `erx_path` is a pure Erlang module, preloaded with
`prim_file`, that resolves one path against one table and one working
directory, both handed to it as terms. It reaches a tree only through two
callbacks its caller gives it, one that walks names on an entry and one
that reads the link a walk reaches; it keeps the place, the names still
to read, the links followed and FreeBSD's flags in its own variables,
recurses only through tail calls, and calls nothing but BIFs, its own
functions and those two callbacks. At the last name it returns the operation's **action** with a
**resumption**: a fun that takes the reply of the walk sent with the
operation and goes on from where the resolution stood.

```erlang
%% What an operation does with its last name: FreeBSD's nameiop.
-type op() :: lookup                 % reads or changes what the path names
            | create                 % makes the last name
            | delete                 % removes the last name
            | rename.                % a rename's new name

-type flags() :: #{follow := boolean(),      % follow a last link: FOLLOW
                   willbedir := boolean()}.  % a new last name may be made
                                             % only as a directory: WILLBEDIR

%% A walk is handed names from the provider's root, the entry's root names
%% first, and answers the kind of each name it passed, in order, up to and
%% including the first that is not a directory, and how it ended.
-type kind() :: directory | link | other.
-type reply() :: {[kind()], ok | {error, posix()}}.

-type callbacks() :: #{walk := fun((entry(), [name()]) -> reply()),
                       read_link := fun((entry(), [name()]) ->
                                        {ok, binary()} | {error, posix()})}.

-type action() :: {target, entry(), [name()], resume()}
                                     % walk the names, act on what they reach
                | {parent, entry(), [name()], name(), resume()}
                                     % walk the names, act on that directory
                                     % with the last name
                | {top, entry()}     % the last name is a directory no request
                                     % to a parent can name
                | {empty_root, place()}
                                     % the target, or a create's existing
                                     % last name, is a directory of the
                                     % empty root, which no provider holds
                | {error, posix()}.  % the resolution's answer
-type resume() :: fun((reply()) -> action()).

-spec resolve(binary(), op(), flags(), table(), place(), callbacks()) ->
          action().
```

An action names its entry as the table holds it, the names to walk from
the provider's root, the entry's `root` names first, and for a parent the
last name; a program's entry, whose fid already stands at its root, has
an empty `root`. The caller sends the
operation together with the action's walk. When the walk stops before its
last name, it makes no fid, so the operation fails with `ebadf` and
changes nothing ([Pipelined requests](#pipelined-requests)); when it
ends on a link the operation follows, it makes its fid on the link,
where nothing sent with it acts through the link (`lopen` fails with
`eloop`, an operation on a directory with `enotdir`, and one that
changes a file is sent only once the walk has passed), and the caller
sets the operation's answer aside. Either way the caller calls the
resumption with the walk's reply, which returns the next action. A
parent's operation
that meets a link at the last name, as `lcreate` answers `eloop` for an
operation that follows it, reports it as one more kind, `link`, after the
directory's, and the resumption follows the link. A resumption called
with any other reply that the walk passed whole answers `eio`, since the
operation, not the walk, ended the action. A resolution's state
lives only in the resumption's closure, which the resolver made, so
nothing a caller holds between two names needs a check of its own.

The table comes in whole and the resolver reads that one term from the
resolution's first name to its last, so a mount, bind or unmount during
a resolution is not seen by it (**Concurrency**, below), and a
walk's reply is always read against the table the walk was sent under.
Entries are opaque to the resolver beyond their `point` and `root`: it places names
on an entry, hands the entry to the callbacks and returns it in an
action, so a runtime's table of providers and grants and a handler's
table of a program's fids resolve through the same function.

**What comes in from outside.** Two inputs reach the resolver from beyond
its caller's own code: the path, which in a session's handler is a
program's, and a link's text, which comes from a server. A walk's reply
comes from the caller's executor, which has already held the server's
reply to its request ([Bounds](#bounds)). The resolver checks each as it
reads it, by matching its bytes:

* a path over `ERX_PATH_MAX` bytes answers `enametoolong`, one that is
  not valid UTF-8 or contains NUL `einval`, and an empty one `enoent`, as
  POSIX says;
* a link's text that is not valid UTF-8 or holds NUL answers `einval`
  rather than being cut short; an empty text answers `enoent`, and one too
  long to join the names still to read `enametoolong`, as resolution
  answers;
* a walk's reply holds no more kinds than the names walked, `directory`
  for every kind but the last, and when it holds fewer kinds than names
  it ends in an error or its last kind is not a directory, and when it
  holds a directory for every name it ends `ok`; any other
  reply answers `eio`, as a reply that exceeds its request does.

The table and the working directory are checked when they are written,
as a place: at most 256 names, each plain, joining within
`ERX_PATH_MAX`. `erx_ns` checks every point and root it adds so, and
`set_cwd` stores only a place the resolver reached; a session's handler
builds a program's table through the same checks. So no table or
working directory a resolution is handed holds a name the resolver
would refuse, and the resolver need not check them again.

Two of FreeBSD's flags record what the text alone cannot.
`TRAILINGSLASH` is set by a
trailing `/` of the path or of the text of a link that is the last name,
and kept to its end, as `vfs_lookup` sets the flag again on each pass and
nothing clears it, since a link's text takes the last name's place
without the `/` that followed it. A link before the last name sets
nothing: its text is followed by the rest of the path, so a `/` ending
the text ends no pass, and `l/f` with `l` a link to `d/` names `d/f`
whatever `f` is. `WILLBEDIR` is given by the caller:
true for `make_dir`, a program's `mkdir`, and a rename's destination when
its source is a directory, as `kern_renameat` sets it from the source it
has found.

The resolver reads a path's names in this order:

1. **Start.** The resolver refuses a path over `ERX_PATH_MAX` bytes
   (`enametoolong`), one that is not valid UTF-8 or contains NUL
   (`einval`), and an empty one (`enoent`, as POSIX says). The place
   starts at `/` for an absolute path and at the working directory for a
   relative one, and the names to read are the path's, split on `/` with
   empty names dropped.

   Whenever the names to read run out at `/` with no last name, from a
   path of `/` alone or from a link whose text is `/`, as `r/` with `r` a
   link to `/`, the resolution names FreeBSD's "degenerate" name: the
   target `/` for `LOOKUP`, and `eisdir` otherwise, before the rules for
   an entry's top in step 6 are reached, so `make_dir("/")`,
   `del_dir("/")` and `del_dir("r/")` answer `eisdir`, as `vfs_lookup`
   answers whenever a pass starts with no name to read.
2. **A run.** Plain names gather into a **run** up to the next `.` or
   `..` or the last name. A name over 255 bytes, a place and run of more
   than 256 names, or a text that with its NUL would not fit
   `ERX_PATH_MAX`, answers `enametoolong`, so a place always fits the
   bounds a working directory is held to.
3. **Placing.** The place and the run, joined, lie on the entry whose
   mount point is their longest prefix, comparing whole names, so `/data`
   never matches `/database`, and the names up to that point join the
   place without a walk. A namespace that the domain service builds
   always has `/`, but a narrowed program's may not ([Narrowing for a
   program](#narrowing-for-a-program)): names that no entry's point
   prefixes lie in the **empty root** when they are `/` or a directory
   above an entry's point, a read-only directory that lists only the
   names leading to the points below it, and answer `enoent` otherwise.
   A lookup whose target is such a directory, and a create whose last
   name is one or whose last name is `.` or `..` there, returns
   `{empty_root, Place}`, which the caller answers itself as that
   read-only directory, asking no provider: a create answers as it
   answers any existing directory, `eexist` for `make_dir` and `eisdir`
   for `open`; a create whose last name there is an entry's mount point
   ends at that entry's top. Any other create, delete or rename whose
   last name lies in such a directory answers `erofs`, as FreeBSD answers
   on a read-only mount: `vfs_cache_lookup` refuses the last name of
   `DELETE` and `RENAME` before it looks the name up, so a missing name
   and a mount point answer `erofs` too, and a missing name's `CREATE`
   fails its write check ahead of the `TRAILINGSLASH` check, so
   `make_dir("/new/")` and `open("/new/", [write])` both answer `erofs`.
4. **Walking.** The resolver asks its `walk` callback for a walk, on
   that entry, of the place's names below its point and then the run's,
   from the entry's top: an attach and the entry's `root` names for a
   domain's entry, the program's fid for a program's. The release file
   system answers the walk in one call of its NIF, the EROFS reader on
   its image, and the client as a request to the grant. Every walk
   retraces the place, and the reply is read the same way for every
   name: a directory joins the place; a symbolic link is followed
   (below); anything else before a further name answers `enotdir`; and a
   name the walk did not pass answers the walk's error. A name among the
   entry's `root` names that does not walk as a directory answers
   `enoent`, since it has no place in the namespace.
5. **`.` and `..`.** Once the run before it has joined the place, `.`
   leaves the place and `..` removes its last name, nothing at `/`. A
   `.` or `..` that follows names already in the place, as in `./x`,
   `../x` and `x/../..`, costs no walk.
6. **The last name**, by the operation's `nameiop`, as FreeBSD's `namei`
   takes it:
   * `LOOKUP` with a plain last name: the action is the **target**, a
     walk of the place's names, the run's and the last name, with the
     operation sent together with it; with a last `.` or `..`, the target
     is the place once the `.` or `..` has acted on it;
   * `CREATE`, `DELETE` or `RENAME` with a plain last name: the action is
     the **parent**, a walk to the place through the run, with the
     operation sent on that directory and the last name;
   * `DELETE` or `RENAME` with a last `.` or `..` answers `einval` once
     the names before it have joined the place, as rmdir(2) documents
     it, and rename(2) for a source, as `vfs_lookup` answers for a
     destination too; the client turns it into `eperm` for `delete`, as
     FreeBSD's `kern_funlinkat` turns `namei`'s `EINVAL`, so unlink(2)
     lists no `EINVAL` for a path. A name before it that is not a
     directory answers `enotdir` first, as steps 4 and 5 have it for
     every operation, so `delete("file/.")`, `del_dir("file/.")` and
     `rename("file/.", "x")` answer `enotdir`. That is the `ENOTDIR`
     the three man pages list for a component that is not a directory,
     and FreeBSD's name-cache lookup and macOS answer it;
   * with `TRAILINGSLASH` set, the last name is walked as a target
     before any operation is sent, whatever the operation: a link is
     followed, a name that is not a directory answers `enotdir`, and a
     missing name answers `enoent` unless `WILLBEDIR` is set, in
     which case the parent action follows, and an existing directory
     goes on to the operation's own action, so the resolver alone decides
     every trailing-`/` answer of [Links and a trailing
     `/`](#erlang-clients-prim_file-and-erx_file_remote);
   * `CREATE` with a last `.` or `..`, and any of the three when the last
     name is an entry's top, ends at the **top**: an existing directory
     that no request to a parent can name, which each operation answers
     for itself without asking (step 3 of the client's
     [errors](#erlang-clients-prim_file-and-erx_file_remote)).

   A target or parent walk that stops at a link makes no new fid, so the
   operation sent with it fails with `ebadf` and changes nothing
   ([Pipelined requests](#pipelined-requests)); one that ends on a last
   link the operation follows makes its fid on the link, where nothing
   sent with it acts through the link, and the caller sets the
   operation's answer aside. Either way the caller calls the resumption
   with the walk's reply and the resolver follows the link. An operation is
   never sent with
   a walk whose names still need a check of their own, so
   `change_mode("file/.")` answers `enotdir` from a walk of its own and
   changes no mode.

**Symbolic links.** A link before the last name, and a last link that the
operation follows, is followed: the resolver asks its `read_link`
callback for a walk to the link and its `readlink`, sent together, and
the link's text takes the place of its
name among the names still to read, starting from the link's directory,
which is the place, for a relative text, or from `/` for an absolute
one. So `..` in a link's text, or after it, acts on the directories the
text leads through. A resolution follows at most 32 links, FreeBSD's
`MAXSYMLINKS` and macOS's, the links met inside a link's text included,
and the next answers `eloop`; an empty link answers `enoent`, as
FreeBSD's `namei` answers it; the count is the resolver's and never
reaches a server. A link therefore leads only where its reader's own
namespace leads, and a link on a narrowed mount that points above the
mount's root names whatever the reader's namespace holds there, often
nothing. Local providers follow links only through the resolver: the EROFS
reader answers its walks and link reads as a grant does, and the release
file system holds no links.

**The last name's link.** A link before a path's last name is always
followed. Whether a link that is the last name is followed, and what the
operation does with that name, is its `nameiop` and `FOLLOW`, as FreeBSD's
system calls pass them to `namei` (`kern_openat` through `vn_open_cred`,
`kern_mkdirat`, `kern_symlinkat`, `kern_linkat`, `kern_funlinkat`,
`kern_frmdirat` and `kern_renameat` in `sys/kern/vfs_syscalls.c`):

| Operations | `nameiop` | A last link is |
| --- | --- | --- |
| `read_file`, `read_file_info`, `list_dir`, `set_cwd`, `change_mode`, `change_time`, `write_file_info`, `open` without a mode that creates; a program's `open` without `O_CREAT`, `stat`, `chmod`, `truncate`, `chdir` | `LOOKUP` | followed |
| `read_link`, `read_link_info`; a program's `readlink`, `lstat` and `open` with `O_NOFOLLOW` | `LOOKUP` | acted on: read, described, or refused by `lopen`'s `eloop`, which a program's `open` answers as `EMLINK`, FreeBSD's open(2) answer |
| `make_link`'s existing name; a program's `link`'s existing name | `LOOKUP` | followed, so the new name links the link's target, as FreeBSD's `link` makes it |
| `open` with `write` or `append` and without `exclusive`, `write_file`; a program's `open` with `O_CREAT` and without `O_EXCL` | `CREATE` | followed, so the file is made or opened where the link leads; `lcreate`'s `eloop` hands the link to the resolver |
| `make_dir`, `make_symlink`, `make_link`'s new name, `open` with `exclusive`; a program's `mkdir`, `symlink`, `link`'s new name, `mknod`, `open` with `O_CREAT` and `O_EXCL` | `CREATE` | the name, which exists, so each answers `eexist`, a dangling link included |
| `delete`, `del_dir`, `rename`'s source; a program's `unlink`, `rmdir`, `rename`'s source | `DELETE` | the name: `delete` and `unlink` remove it, `rename` moves it, and `del_dir` and `rmdir` answer `enotdir` |
| `rename`'s destination; a program's `rename`'s destination | `RENAME` | the name, which the rename replaces |

A path written with a trailing `/` follows its last link whatever its row
says, as `vfs_lookup` follows one under `TRAILINGSLASH`, and the name it
then reaches must be a directory ([Links and a trailing
`/`](#erlang-clients-prim_file-and-erx_file_remote)).

The parent action sends the operation on the directory's fid with the
name (`unlinkat`, `renameat`, `link`, `mkdir`, `symlink`, `mknod`,
`lcreate`), and a target that acts on a last link acts on the link's own
fid (`readlink`, `getattr`). The 32-link count and the resolver's bounds
hold across one path's whole resolution, each of a `rename`'s or a
`make_link`'s two paths counted on its own.

So a narrowed namespace reaches nothing but its mounts: `ls /` in a
program started with `/data/logs` alone lists `data`, `cd /data` works,
`cd ..` from `/data/logs` reaches `/data`, the empty root's directory,
which lists only `logs`, and `/etc/passwd` fails with `enoent`, without a
fid that would reach more.

**Concurrency.** FreeBSD's `namei` looks up one name at a time, holding
the directory it looks in, so each name's lookup is atomic with respect
to changes of that directory, and `..` is looked up in the directory
actually reached, so it names that directory's parent at that moment,
even after a rename moved it; a whole path is not resolved atomically,
and a rename between the lookups of two names is seen only by the later
one. erXos keeps at least the per-name atomicity, and the non-atomic
whole: a server answers each name of a walk against its tree as the
tree then is, a name at a time or, as a server may, a whole walk of up
to 16 names at once. The namespace's table, unlike a server's tree, is
read once: a resolution takes the table as it stands when the resolution
starts and holds that term to its end, so every name, link and walk
reply of one resolution is placed by one table, and the two paths of a
rename or a link, resolved against the same term, are compared on it
before their request is sent. FreeBSD's lookup likewise holds a
reference on the directory it stands in, so an ordinary unmount of that
file system answers `EBUSY` until the lookup has left it; erXos's
unmount does not wait, and a resolution under way finishes on the table
it began with. Its `..` differs under a race. It removes the name the
resolution walked down through, and the next walk retraces the place's
names from the entry's top, so a directory moved while a resolution
crosses it is passed at its old path: the resolution goes on through
whatever that path names then, or answers the walk's error, where
FreeBSD's follows the moved directory to its new parent. Without a rename
racing the resolution the two agree, which the fuzz target's comparison
with the reference model checks.

**A held table.** A resolution under way when its entry is unmounted, or
a bind it passes is replaced, sends its remaining requests, at most one
walk for each run and link it has left, to the grant the old entry
names. That grant is still the domain's: `unmount` takes an entry out of
the namespace and ends no grant, and the domain reaches a grant only
through the export the server's runtime made for it (F1), whichever
table names its pid. Once the grant ends, every request to it answers
`eio` through the client's monitor on the grant, whichever table the
resolution holds ([Erlang clients](#erlang-clients-prim_file-and-erx_file_remote)).
A held table therefore reaches nothing the domain does not hold, walks
nothing above the old entry's `root`, since its walks start there as
any walk does (F2), and holds a grant for no longer than one
resolution.

**Properties.** A resolution reads each name of its path and of each
link's text once, and for each run it places looks through at most 64
entries, comparing at most 256 names with each; it makes at most one
walk for each run and two for each link, follows at most 32 links,
recurses only through tail calls and holds at most one table and one
place, so its time and memory are bounded by the limits above. The same
module resolves for `prim_file` in every runtime, for `erx_ns`'s `bind`
and for every session's handler, and runs on the host, where its fuzz
target and property tests run: no walk names `.`, `..` or an empty
name; every walk's names lie at or below its entry's `root`; a place
holds only names a walk answered as directories or the table gave it;
every action names an entry of the table the resolution started with;
and, with the tree held still, every outcome is the reference model's
([Verification](#verification-and-testing)). Nothing of this is in the
kernel: the resolver is preloaded Erlang in a user-mode runtime, the
same code in both phases of [plan.md](plan.md), so nothing here touches
the stopgap kernel or works around a gap of it.

**Listings across mounts.** A directory's listing is its provider's
entries, plus an entry of kind `directory` for every mount point directly
below the directory that the provider does not list, so `ls /` shows
`/data` and `/proc` whatever the provider mounted at `/` holds; a mount
point hides a provider's entry of the same name. The client adds these
entries, from its own table, after the provider's last page, so a server
never learns another's mounts.

### Building, binding and mounting

**Building.** The domain service builds a domain's namespace from its
specification: `/` is the release slice, an EROFS image mounts where its
release names it, and each entry of the
specification's `files` map mounts a facet the domain is granted, such as
`/data` (its principal's directory on the data partition, read-write),
`/proc` (the inspector's tree in the domain's inspect scope) or `/dev`
(the device service's tree, for an administrator principal). The local
entries follow from the release, and the facets arrive with the domain's
other facets, each a grant the server made for the domain when the system
domain introduced the two
([design-system.md](design-system.md#creating-a-domain)); the runtime
mounts them before its release's applications start. `/tmp` is the grant
of the domain's own RAM file server, which the runtime starts and mounts
itself ([design-tmp.md](design-tmp.md#starting-and-mounting)). A facet that serves
a tree carries its tree's name and its grant's rights, `ro`, `rw` or
`rx`, so a tree whose programs a domain may run, such as a principal's
directory of executables, comes only from a facet granted with `rx`, and
a domain that should write a tree and run what it wrote holds two facets
on one tree, through which a file is one entry of a session's file table.

**Binding.** `erx_ns:bind(From, To)` makes the subtree visible at `From`
visible at `To` as well: it adds an entry with the mount that `From`
resolves to and the names below it as its `root`, read-only if asked.
`From` resolves as `set_cwd`'s path does, to a directory, in the calling
process: `erx_ns:bind/2,3` runs `erx_path` as `file`'s operations do,
its walks answered by the release's NIF, the EROFS reader or
`erx_file_remote` wherever they lie, so a link on the way is followed
and `From` through a link roots the entry at the link's target. A `From`
that ends in the empty root, or on a directory of the namespace above a
mount point that no provider holds, is refused with `enoent`, since no
entry's tree holds it. It then hands the place it reached to `erx_ns`'s
process, which checks it as a place is checked and places it again on
the table it changes: the new entry takes the provider of the entry the
place lies on then, and the place's names below that entry's point as
its `root`. A bind is thus the one change that reads two tables, the one
its resolution held and the one it changes: a mount or unmount between
them roots the new entry on whatever the namespace maps at the place
then, as a bind made just after that change would, and its names, if
that provider lacks them, answer `enoent` on the first walk. So a
`root` is a place: names each walked as a directory, with no link among them, and a
root name that a later rename takes away answers `enoent` on the next
walk, never a walk elsewhere. A mount point, `To` here and in `mount`,
is written as the plain names it is: it is absolute, empty names and a
trailing `/` are dropped as for any path, so `/a//b/` is `/a/b`, and one
holding `.` or `..` is refused with `einval`, since it names an entry
rather than a directory to resolve.
`erx_ns:mount(Pid, To, Options)` adds an entry for a grant's pid, with
the tree and the rights its options name.
`erx_ns:mount({erofs, Window}, To, Options)` adds a read-only entry for
the EROFS image that the block service's window `Window` holds: `erx_ns`'s
process mounts the image with the EROFS reader, which reads it
through `erx_verity` ([design-storage.md](design-storage.md#reading-erofs-images)),
so an image the reader refuses is refused before the table changes, and
the entry's provider is the reader's mount.
`erx_ns:unmount(To)` removes the entry at exactly `To`; unmounting `/`
fails. Each takes effect for the whole domain at once, for every
resolution that starts after it returns, and changes nothing for any
other domain.

**The table's one writer.** A runtime's table is one persistent term,
which only `erx_ns`'s process writes: a registered process that takes
each `bind`, `mount` and `unmount` in turn, checks it, builds the new
table from the one the term holds and puts it, so two changes never
lose each other, and a resolution reads the term without copying it or
taking a lock. Until it writes a table the term is absent and
`prim_file` reads the boot table, the domain's local entries: the
release slice at `/` and each EROFS image where its release names it,
both from the boot information, so `erl_prim_loader` loads a runtime's
first modules, from the slice or an image, before any process of
erXos's own has run; the runtime starts `erx_ns`'s process before it
mounts the domain's facets. The changes themselves are pure functions
over a table, which `erx_ns`'s process applies to the domain's term and a
session's handler to the table of each program it starts.

The process also monitors every grant pid its table holds. When one
ends, it rewrites that entry's provider to `ended`, which answers `eio`
to every request without sending one, and the entry stays until it is
unmounted. A grant's pid that the server's runtime later gives another
process therefore never receives a mounted path's requests, and a
resolution that holds the older table and sends to the ended pid
answers `eio` through the client's own monitor on the grant ([Erlang
clients](#erlang-clients-prim_file-and-erx_file_remote)), so every
operation on a path whose server ended answers `eio` whichever table
names it. The monitors are the process's only state beyond the term;
a restarted process reads the term and monitors its grants again, and
one whose grant ended meanwhile answers `DOWN` at once.

### Narrowing for a program

A native program gets the namespace its starter names, by default the
starter's own whole namespace, narrowed where the starter asks
([design-shell.md](design-shell.md#starting-programs)). The namespace is
a table in the program's handler, and every entry of it is a fid on one
of the session's grants, which the handler walks for the program from the
starter's fid on the same grant, with rights within the starter's:

* a grant entry of the starter's becomes a fid walked from the starter's
  to the root the starter asks for, with the rights it asks for within its
  own;
* a local entry of a session becomes a fid on the session's **export**,
  an `erx_fs` server in the session's domain that serves the session's
  local providers, each as a tree of its own named by its mount, so a
  provider's qid paths stay unique within their tree; one more tree
  serves `/bin`, an `rx` directory of the session's program commands;
  `/dev/null`, `/dev/zero`, `/dev/urandom` and `/dev/tty`; and
  `/etc/passwd` and `/etc/group`, with qid paths from the session's
  counter ([design-programs.md](design-programs.md)).

The program itself receives none of this: its sub-space gets its channel,
its data area and its pipe ends, and the fids live in the session's
Erlang state, held by the program's handler, and at the servers
([design-programs.md](design-programs.md#a-program-is-a-port)). A program
started with `/data/logs` therefore has a handler holding a fid on
`logs`, and reaches nothing above it whatever it asks, since the handler
walks for it only the plain names `erx_path` asks for, never `..`,
and only from the program's own fids (F3, F9): a `..` at the top of the
program's mount steps out in the program's namespace, to `/data`, which
holds only `logs`, and never asks the server. The server sees the session's grant
and knows nothing of the program: the narrowing is the handler's, which
is the program's file server, and the session's own authority bounds
every program's.

A file passed to another program of the session, as `xargs` hands its
standard streams to the programs it starts, is its open-file description,
which the handler records in the receiving program's table; a directory
passed is a fid the handler walks from the passer's. No program reaches
another's files unless it was handed them. A program's end clunks every
fid its handler walked for it and closes its share of every description
([design-programs.md](design-programs.md#a-programs-end)).

A forked child gets fids of its own the same way: before the session
copies the sub-space, the parent's handler walks a fid for each entry of
the parent's namespace and each directory it has open, and gives the
child each of the parent's descriptions, so parent and child never share
a fid, and a `clunk` in one never closes a file of the other's
([design-programs.md](design-programs.md#the-second-tier)). A file the two
share is one description, so they share its offset as POSIX processes do.

### Serving: the `erx_fs` behaviour

A file server in Erlang is a module of the `erx_fs` behaviour, which owns
the protocol, the fids, the locks and the checks, and calls back for the
tree. The behaviour, its grant's pure core and the file servers erXos
writes in Erlang form the `erx_files` application
(`erlang/apps/erx_files/`):

```erlang
-callback init(Args :: term()) -> {ok, Fs :: term()}.
%% The tree the grant roots in: its name, which attach's Aname must match, and its root.
-callback root(Fs :: term()) -> {ok, Tree :: binary(), Node :: term(), qid()}.
-callback walk(Node :: term(), Name :: binary(), Fs :: term()) ->
              {ok, Node1 :: term(), qid()} | {error, file:posix()}.
%% A tree that adds forget keeps each node its walk answers alive for the
%% calling grant until the grant forgets it or ends. The one callback without a reply.
-callback forget(Node :: term(), Fs :: term()) -> term().
-callback getattr(Node :: term(), Fs :: term()) ->
              {ok, attr()} | {error, file:posix()}.
-callback open(Node :: term(), Flags :: non_neg_integer(), Fs :: term()) ->
              {ok, Handle :: term()} | {error, file:posix()}.
-callback read(Handle :: term(), Offset :: non_neg_integer(),
               Count :: 1..65536, Fs :: term()) ->
              {ok, binary()} | {error, file:posix()}.
-callback readdir(Handle :: term(), Offset :: non_neg_integer(),
                  Max :: 1..256, Fs :: term()) ->
              {ok, [dirent()]} | {error, file:posix()}.
-callback readlink(Node :: term(), Fs :: term()) ->
              {ok, binary()} | {error, file:posix()}.
-callback statfs(Fs :: term()) -> {ok, statfs()}.
-callback clunk(Handle :: term(), Fs :: term()) -> ok.
%% A tree whose reads never wait for a medium answers immediate; absent: helper.
-callback read_mode() -> helper | immediate.
%% A tree that writes adds these; one without them is read-only (F5).
-callback write(Handle :: term(), Offset :: non_neg_integer(), binary(),
                Fs :: term()) ->
              {ok, Count :: non_neg_integer(), At :: non_neg_integer()}
            | {error, file:posix()}.
%% A {file, ...} make answers with the open Handle; every other kind without.
-callback make(Dir :: term(), Name :: binary(), What :: what(), Fs :: term()) ->
              {ok, Node :: term(), qid(), Handle :: term()}
            | {ok, Node :: term(), qid()} | {error, file:posix()}.
-callback setattr(Target :: {open, Handle :: term()} | {node, Node :: term()},
                  Changes :: map(), Fs :: term()) ->
              ok | {error, file:posix()}.
-callback unlink(Dir :: term(), Name :: binary(),
                 Kind :: file | directory | {node, Node :: term()},
                 Fs :: term()) ->
              ok | {error, file:posix()}.
-callback rename(Dir :: term(), Name :: binary(), NewDir :: term(),
                 NewName :: binary(), Fs :: term()) ->
              ok | {error, file:posix()}.
-callback fsync(Handle :: term(), Fs :: term()) ->
              ok | {error, file:posix()}.
-callback xattr(Node :: term(), Op :: xattr_op(), Fs :: term()) ->
              {ok, term()} | {error, file:posix()}.
-optional_callbacks([forget/2, read_mode/0, readlink/2, write/4, make/4, setattr/3,
                     unlink/4, rename/5, fsync/2, xattr/3]).

-type what() :: {file, Mode :: 0..8#7777, Flags :: non_neg_integer()}
              | {directory, Mode :: 0..8#7777}
              | {symlink, Target :: binary()} | {link, Node :: term()}
              | {node, Mode :: non_neg_integer(), Major :: non_neg_integer(),
                 Minor :: non_neg_integer()}.
```

`make` serves `lcreate`, `mkdir`, `symlink`, `link` and `mknod`, one
callback for every operation that adds a name, so a module states once
which kinds its format keeps and refuses the rest with `eperm`; `unlink`
serves `remove` and `unlinkat`, and `rename` serves `rename` and
`renameat`. Each decision POSIX makes in one step is one callback, so no
other client's request can come between its parts:

* `walk` and `forget` keep a walked fid's node, for a tree that adds
  `forget`, as FreeBSD's vnodes keep a tmpfs node. `walk` holds the node
  it answers for the calling grant in the same step as its lookup, so a
  fid never names a node the tree has freed, whatever another client
  renames or removes between two requests through it. The grant counts,
  per node, the steps of its fid paths that name it; one function
  replaces a fid's path, for a new fid, a walk in place, `..`, a clunk or
  an owner's end, and a node no step names any more, or one a walk that
  stopped passed, is forgotten once, at the end of the request. `forget`
  answers nothing: the grant sends it and goes on, and since one
  process's messages arrive in order, it never overtakes the grant's
  later walk of the same node. A hold is keyed by its grant, so walking
  a node twice holds it once and a forget of a node not held does
  nothing, and the tree drops every hold of a grant that ends. A tree
  without `forget` holds nothing, and a request through a fid whose node
  it freed answers what it answers for a node that is gone.
* `make` of `{file, Mode, Flags}` serves `lcreate` whole: it creates the
  file, or, without `EXCL`, opens the regular file `Name` already names,
  and either way returns the open `Handle`, counted as an open as `open`'s
  is, with the answers of `lcreate`'s row above. Making the file and
  opening it in two callbacks would let another client remove the new
  file between them, and could not open a file that already exists.
* `unlink` receives the request's `Kind`: `unlinkat` passes `directory`
  with `AT_REMOVEDIR` and `file` without, so the module answers `rmdir` of
  a file with `enotdir` and `unlink` of a directory with `eisdir`, and
  `remove` passes `{node, Node}`, the node its fid stands at: the module
  removes `Name` from `Dir` only if that entry still names `Node`, and
  otherwise answers `enoent`, deciding both in the one step. So a
  `remove` acts on its fid's file, as 9P's `remove` does, and never on
  a file a `rename` or a create has put under the name since the fid
  was walked; once the name names the fid's node again, the same
  `remove` succeeds.
* `setattr` receives `{open, Handle}` for an opened fid and `{node, Node}`
  for an unopened one, so a size change checks the open's access through
  an opened fid and the file's permission otherwise, as `setattr`'s row
  above requires.
* `write` returns `Count` and `At`, the offset the bytes were written at,
  which only the module knows for an append, and which `write`'s reply
  carries ([Open files and offsets](#open-files-and-offsets)).

* **One process per grant.** A service serves a tree by starting one
  `erx_fs` process per grant, as a facet stands for one grant, so a slow
  client delays only its own grant. The client's state, its fids, their
  owners' monitors and the requests it has in flight, lives in that
  process, within the bounds above and the process's `max_heap_size`;
  the grant alone ends a fid ([Fid owners](#fid-owners)), and the module
  hears of an open fid's end through `clunk`.
* **One owner per open file.** Each open file has an owner process, which
  `erx_fs` starts at its first open on any grant and which runs that
  file's reads, writes, size changes and locks in turn
  ([Open files and offsets](#open-files-and-offsets)). A read through a
  module that reads from a medium, the slow part, runs in a helper the
  owner starts, whose result names the file state it was prepared
  against, and the owner's pure core accepts it only if that state still
  holds and otherwise retries it, so other operations of the file that do
  not conflict run while a read waits for the medium. A module whose
  reads never wait, such as a tree held in memory, says so once:
  `read_mode/0` answers `immediate`, and the owner then calls `read`
  itself, in turn with the file's other operations, and starts no helper,
  since a helper would only add a process to every read. `erx_fs` reads
  the answer once, when the grant starts; a module without the callback
  gets helpers.
* **One handle per tree.** `init/1` answers the tree's handle, `Fs`,
  which never changes: every callback receives it and answers only its
  result, never a next state. The grant and each owner call the
  callbacks in their own processes, so a tree that changes keeps its
  nodes behind the handle, in a process of its own as `/tmp` does
  ([design-tmp.md](design-tmp.md#concurrency)) or on its medium, where
  the grant and every owner reach the same tree; with no next state in
  any answer, no callback can leave its caller a copy of the tree that
  the others do not see. An answer that is none of its callback's
  shapes, a next state appended included, reaches the client as `eio`.
  A callback keeps no state in the process that calls it, and an answer
  turned into `eio` does not undo what the tree did.
* **Owners and their grant.** An owner is linked to its grant, so a
  callback that crashes in it ends the grant, and the
  grant's end ends its owners. The grant sends an owner its file's
  requests and the clunks of its opened fids in order and takes back
  only the answers that carry the owner's tag; a clunk therefore runs
  after every request sent before it, and the owner ends once it has
  run the file's last clunk, so every live owner is one of a file still
  open through the grant or one finishing the clunks it was sent.
* **Checks before callbacks.** Every message a grant receives, but its
  owners' `DOWN`s, passes one decoding funnel, which takes the frame and
  the grant's rights and admits a request only if it came from the client
  domain, in that domain's envelope or, for the server's own domain, bare
  ([Who a grant is for](#who-a-grant-is-for); the frame is dropped
  otherwise), the protocol's grammar
  accepts it, its alias is the client domain's (the frame is dropped
  otherwise, so no client has the grant answer a third domain), its
  `Owner` is a process of the client's domain (`einval` otherwise), and
  it does not write while the tree has no `write`
  callback or the grant is `ro` or `rx` (`erofs`, F5); dispatch takes
  only what the funnel admitted, so no path reaches a callback with a
  writing request on a read-only grant. `erx_fs` then checks the bounds, maps fids to nodes, and
  refuses with `enotdir` a request whose directory fid (such as the
  one of `mkdir`, both of `renameat`, or the fid of `readdir`) names a
  node whose qid is not a directory, so no callback is handed a file or a link as a
  directory, whatever the tree checks itself. The list comes from the
  protocol table, where every request field of kind `fid` states what
  it names, `directory`, `node` (any node) or `new` (a fid the request
  makes name a node), so no field is left unchecked by omission: the
  generated grammar's `directory_fids/1` answers it with one clause per
  operation and none for anything else, so an operation the table adds
  states its directory fids where it is declared. It replies only to the
  request's alias, holding each reply to its request with the grammar's
  reply check, so a callback's malformed
  answer reaches the client as `eio`. Each operation builds the grant it
  would leave before anything is kept, and only a reply the check
  accepts keeps it; a rejected reply is answered `eio` and, like a
  refusal, keeps only a `remove`'s clunk. Every qid the grant records
  (attach, walk, `lcreate`) travels in the reply that records it, so a
  malformed qid leaves no fid, open or file process behind. `lcreate`
  checks its reply before it records the open, and clunks at once a
  handle the tree opened for a reply the check rejects, since no fid
  holds it. A request that fails is answered
  with an error and counted; it never reaches a callback.
* **Bounded work on the server's grant.** A grant process runs on its
  server's own group, as every process of the server does; no client's
  time is lent to it ([design-scheduler.md](design-scheduler.md#service-work)).
  Its own steps are bounded by the grammar: no loop over client-sized data
  outside the decoder, and a payload of at most 64 KiB. Work that depends
  on a medium runs in the file's owner or its helper, so a grant keeps
  answering its other fids while one read waits for the medium, and the
  server's runtime schedules its clients' work among them as it schedules
  any processes. A client that sends faster than its grant answers fills
  its own lane and waits in its own runtime; a client that never reads its
  replies fills the lane the server writes and makes the grant wait on
  that lane alone.
* **Walking.** `erx_fs` walks a request's names one by one from the fid,
  so a callback sees one plain name at a time and is never asked to follow
  a link; a `..` at the grant's root stays there, and `..` below it walks
  to the parent the grant's process recorded on the way down, so the
  callback is never asked for it either. A walk from a fid whose qid is a
  `symlink` fails, and an `lopen` of one fails with `eloop`, so no request
  sent along with a walk acts on a link the client has not yet seen. A
  walk, an `lopen` or an `lcreate` from an opened fid fails with
  `einval`, as 9P2000.L walks and opens only unopened fids, so an opened
  fid stays on the node it opened.
* **What a fid denotes.** A fid stands for three things the grant
  records as it walks: the node it was walked to, the entry it was
  walked by (the directory it was walked from and its name there), and
  the chain of directories back to the grant's root. Operations on the
  node (`getattr`, `lopen`, `setattr`, `readlink`, and a directory fid's
  `walk`, `mkdir`, `lcreate` and the rest) use the node, whatever it is
  named now; `remove` uses the entry, with the node as its check; `..`
  uses the chain. So `..` returns to the directory the fid was walked
  through whatever renames have happened since, and never leaves the
  grant's subtree, since the chain ends at its root. After the fid's
  node is removed, the requests that reach it answer what the module
  answers for a node with no name, which `/tmp` keeps while a fid names
  it: `getattr` answers with `nlink` 0; `lopen` of a file opens it, so
  an open whose walk and `lopen` a rename over the name falls between
  opens the old file; `lopen` of a directory and `walk` answer `enoent`;
  `..` still walks to the recorded parent.
* **Held bytes.** What a grant holds for its client beyond its fids, such
  as the snapshot behind an open `/proc` file, is bounded by the server's
  per-fid bound and its pool; a server whose per-fid state is large sets a
  smaller bound of its own, as `/proc` holds at most 256 snapshots for a
  grant ([design-live.md](design-live.md#the-proc-tree)).
* **Flush.** A flush tells the callback's work, when it runs in a helper,
  to stop, and is answered after the flushed request's reply or after the
  owner has abandoned it ([Flush](#flush)).
* **Freezing.** A freezing checkpoint, which the system domain asks of a
  storage service before a trial or a reset, closes mutation admission at
  every grant, lets each owner finish the writes it admitted, and only
  then lets the module checkpoint and the block driver flush; it answers
  every later write `erofs` until the machine ends
  ([design-storage.md](design-storage.md#interfaces)).

Every file server is such a module: the storage services, erXos's F2FS
and the littlefs port among them
([design-storage.md](design-storage.md#read-write-storage)), the FAT
server, `/proc`, `/dev` and a session's export. So one implementation of
the protocol's decoding and checks stands in front of every tree, and
every grant and every open file is a process that can be inspected,
traced, supervised and upgraded live like any other; an Erlang callback
that crashes on a crafted input ends its grant's process, never the
server's memory.

### Shared mappings

`mmap` of a file with `MAP_SHARED` is served by the program's session.
The session holds one memory object for each file that any of its
programs maps shared, the file's **shared object**, and one Erlang
process of the session that owns it, the file's **mapper**. Every program
of the session that maps the file maps that object; the mapper fills it
with ordinary reads through the protocol and writes it back with ordinary
writes; and while it lives, the handlers send every read, write and size
change of the file by the session's programs to the mapper, which serves
them from the object. So the bytes of a file, as one session's programs
see them, live in one place (F7), the file's server sees nothing but
reads and writes, and no fault waits on another domain: the kernel
resolves every fault on a shared object from the object's own pages
([design-kernel.md](design-kernel.md#virtual-memory)). The program's side
of a mapping, its `liberx` calls and the mapping's open, is in
[design-programs.md](design-programs.md#the-second-tier).

**The file table.** The session keeps one table of the files its programs
hold open, keyed by the server's domain, the tree and the file's qid path
([Identity and version](#identity-and-version)), so two programs that
reach one file through different mounts, grants or paths find one
entry. An entry counts the opens of the file by the session's programs and names the
file's mapper while one lives. A handler updates the count at every open
and clunk of a program's fid, and looks the entry up for every read,
write and size change it relays.

**Mapping.** A program's `mmap` with `MAP_SHARED` reaches its handler with
the open and the mapping's range. The handler checks the open as POSIX
requires, open for reading, and for `PROT_WRITE` for reading and writing,
or `EACCES`, and asks the file's mapper, starting one when the entry has
none. A mapping's open names the program's description of the file, and
the mapper reads and writes the server through the descriptions its
mappings name, a description open for writing for every write. It takes
two steps:

1. **Fill.** The mapper makes the object at its first mapping with
   `erx_mem_create`, from the session's budget, with `ERX_MEM_INHERIT` so
   that a forked child's copy of the program shares it, and keeps the
   object's capability with every right, among them `SUPPLY`, which
   `erx_mem_grow` and `erx_mem_dirty` need. It keeps two extents of the
   object, each a whole number of pages from its start: the **allocated
   extent**, the size `erx_mem_create` and `erx_mem_grow` gave it, and
   the **filled extent**, the pages a completed fill has written. A
   mapping whose end, rounded up to a page, lies within the filled extent
   costs nothing. Otherwise the mapper grows the object with
   `erx_mem_grow` to that end when it passes the allocated extent, and
   fills the pages between the filled extent and that end: the part below
   the file's size by reading it through the mapping's description, 64 KiB
   a read, and copying each read's bytes into the object with
   `erx_mem_copy` from a staging object of its own, and the rest left
   zero. Only when every read of the fill has completed and been copied
   does the filled extent move to the mapping's end.
2. **Install.** The handler installs into the program's image a
   capability to the object with `READ` and `MAP`, plus `WRITE` for a
   mapping of an open for writing, and no other right: never `DUP` or
   `SUPPLY`, so the program can neither copy the capability nor grow the
   object or read its store marks. So a mapping's ceiling is what the
   program's open allows, and the program maps it
   ([design-programs.md](design-programs.md#the-second-tier)). A mapping
   is installed only within the filled extent, so no program maps a page
   that no completed read wrote.

A step that fails fails the `mmap`: `ENOMEM` when the session's budget
cannot cover the range, and the read's error otherwise. A fill that fails
leaves the filled extent where it was, so the next mapping of the range
reads it again from the server, and the pages already allocated serve
that mapping without a second grow, so repeated failures never charge
more than the largest end asked for. A mapper that has no mapping left
after the failure ends as at the last write-back below, so repeated
failures leave nothing.

**Reads, writes and size while mapped.** The mapper serves a read by the
session's programs from the object for the bytes within the filled
extent and below the file's size, and from the server for the rest. It
takes fills, descriptor writes and size changes one at a time, in the
order they come, each to its end, so none of them meets another half
done: a fill never copies in bytes that a write acknowledged meanwhile
made stale. It serves a descriptor write of the session's programs in
three steps:

1. it puts the write's bytes in its staging object and sends the write to
   the server through a description open for writing;
2. once the server answers, it copies into the object, with
   `erx_mem_copy` from the staging object, only the prefix the server
   acknowledged, and only the part of it within the filled extent; a
   write the server refuses changes nothing in the object;
3. it answers the write with the server's count or error, so a read that
   follows a write's return sees its bytes.

So the server's data and size follow every write a descriptor makes, no
descriptor write leaves in the object a byte the server did not take, and
only stores through mappings wait for a write-back. A size change by the
session's programs goes to the server first, and once the server has it,
the mapper zeroes the object, within the filled extent, with
`erx_mem_copy` from zeros in its staging object, as the change requires:

* a **truncation**, by `ftruncate`, `truncate` or an open with
  `O_TRUNC`, zeroes the object from the new size to the old, which is
  what a fill leaves past the file's end, so the filled extent stays;
* an **extension** by `ftruncate` or `truncate` zeroes it from the old
  size to the new;
* an **extending write**, one whose acknowledged bytes end past the old
  size, zeroes only the hole between the old size and the write's
  offset, and the write's acknowledged bytes then go in as step 2 says.

So a mapping shows zeros past the end, and an extension never reveals
stores a program made past the old end, which POSIX never writes to a
file. An access through a mapping to a page wholly past the file's end
reads zeros, where Linux raises `SIGBUS`: a documented difference with a
test.

**Writing back.** The mapper writes the object back:

* at `msync` of any mapping of it, where `MS_SYNC` answers once the
  write-back and an `fsync` have answered, and
  `MS_ASYNC` starts the write-back and returns;
* at every close of a mapping's open, which `liberx` makes at a program's
  last `munmap` of the file, and its handler at the program's `exec` and
  at its end, however it ended, before the `munmap` returns or the `exec`
  proceeds;
* at the `close` that leaves the session's programs no open of the file,
  before the `close` returns.

A write-back asks the kernel which pages of the object were stored to
since the last one, with `erx_mem_dirty`, which reports them in the
calling thread's UTCB and clears their marks in the same step, so a store
made after the report marks its page for the next write-back. It asks the
server for the file's size with `getattr`, copies each reported page that
lies below that size, trimmed to it, out of the object into its staging
object with `erx_mem_copy`, and writes it through a description open for
writing, in writes of at most 64 KiB. So another domain's write survives
in every page no program of the session stored to, and two sessions that
map one file each hold their own copy and see each other's stores after
write-back, page by page: a documented difference with a test. A mapping
that no program could write leaves no page to report.

The mapper changes the object's bytes only with `erx_mem_copy` from its
staging object, at a fill, a write and a zeroing, and never through a
mapping, so no CPU store of the session's own marks a page and
`erx_mem_dirty` reports only the programs' stores: the file's server
receives through write-back only the pages the session's programs
stored.

**A write-back that fails.** A write that fails leaves its pages to be
written again: the mapper keeps the pages of a failed write-back and
writes them, with whatever the next report adds, at the next write-back.
The call that caused it returns the error: `msync` and `close` fail with
`EIO`, as POSIX lets them, and a last `munmap` fails with `EIO` though the
mapping is gone, a documented difference with a test, since POSIX's
`munmap` knows no I/O error. At a program's end or its `exec`, the
session writes a log line naming the program, the file's path and the
error, and the program's record in the inspector counts the failed
write-back ([design-live.md](design-live.md#paths)). No failed write-back
is silently dropped: each reaches a call's return or the session's log.

**The end.** At the close of the session's last mapping's open, the
mapper writes back, deletes the object, which removes it from every
image, and ends; a write-back that fails there loses the
pages it carried, and the `munmap` and the log say so. The object is the
session's: charged to the session's budget, held with `DESTROY` and
`SUPPLY` by the mapper alone, and mapped only into the session's
programs. A server that
ends changes nothing in a mapping: the programs keep their bytes, and the
mapper's write-backs fail with `EIO` until its last, after which those
pages are lost and reported as above. A session that ends ends its
programs with it ([design-programs.md](design-programs.md#a-programs-end)),
and the pages none of its write-backs carried end with it.

**Other domains.** Another domain reads the file as its server has it:
the session's stores reach it at the session's next write-back, as they
would reach another machine. An Erlang domain maps nothing shared, since
OTP's `file` has no mapping interface and erXos adds none, and the
session's own Erlang processes reach the file as any other domain does.
Another session's mapping of the file is that session's own copy, filled
when it mapped and written back page by page; the two agree after both
have written back and each has mapped afresh, as clients of a network
file system do.

**Versions.** A write-back is a write, so the server draws the file a new
version for it like any other ([Identity and
version](#identity-and-version)), and every other domain's cache follows.
Inside the session, a file that a program maps for writing changes under
no request, so the session runs nothing and caches nothing of it by its
version while its mapper holds a mapping that may write: a `code` map of
it fails with `ETXTBSY`, and a private mapping of it copies the shared
object ([design-programs.md](design-programs.md#file-objects)).

### Erlang clients: `prim_file` and `erx_file_remote`

`prim_file` resolves every path with `erx_path` in the calling process,
naming the operation's `nameiop` and FreeBSD's flags ([Resolving a
path](#resolving-a-path)), over the table it reads from the namespace's
persistent term and the working directory it reads from its NIF. Its
callbacks and the action the resolver returns are dispatched on the
entry's provider. On the release file system a walk is one call of
`release_walk_nif(Names)`, which answers the kind of each name, and an
action is the operation's own NIF call on the action's names, such as
`read_file_nif(Names)`, which answers `enoent` or `enotdir` for a name on
the way as a walk would; the release holds no links, so a path without
`.` or `..` there costs one NIF call, as stock's does. Any process can
call these NIFs with any term, so each decodes its list before the
release's core sees it: a list of more than 256 names, or a name that
is not a binary of 1 to 255 bytes of UTF-8 other than `.` and `..`
without `/` or NUL, answers `einval`, as does a list whose names joined
by `/` do not fit `ERX_PATH_MAX` bytes with a NUL, which bounds the
decoder's buffer and which no place's names exceed; the decoder has a
fuzz target of its own ([Verification](#verification-and-testing)). On an EROFS mount
the operation runs through `erx_erofs`, the EROFS reader, which answers
the resolver's walks and link reads on its image and returns OTP's file
descriptor record with its open-file module, `erx_erofs_file`, as the
module for an open file
([design-storage.md](design-storage.md#reading-erofs-images)). On a
grant it runs through `erx_file_remote`. A grant entry's provider is
`{grant, Pid, Tree}` with the entry's `rights`, as the table held them
when the resolution started: `Tree` is the tree the client attaches to,
so two entries of one grant on two trees reach two trees, and `rights`
is the entry's `ro`, `rw` or `rx`, so a read-only bind of an `rw` grant
reaches its client read-only and the client never sends a request that
writes through it: every request the client sends passes one function,
which checks it against the generated grammar of the file protocol and
refuses, with `erofs` and sending nothing, one that the grammar's
`writes/1` marks as writing through rights other than `rw`, as the
grant's own funnel refuses it, and refuses with `einval`, sending
nothing, a walk that names `.`, `..` or an empty name, so no walk a
client sends carries one, whoever built it (F2, F3). The grammar,
`erx_9p_grammar`, is preloaded with the client and holds each reply to
its request. The client walks an action's names, whose first are the
entry's `root` names, from a fid it attaches to the tree's root. The
client is the resolver's executor:
it performs each walk and link read the resolver asks for, sends the
operation with a target's or a parent's walk, calls the resumption with
the walk's reply when the walk did not pass as the operation asks, having
stopped short, ended on a link the operation follows, or, for a parent,
ended on a file that is not a directory, and never reads a
path's names itself. A walk's reply comes from the server and is
untrusted: one that lists a qid after a qid that is not a directory names
a walk on from a file, which no server makes, and answers `eio`. Each
request goes out with an alias of its own, which only the server is
handed, and the client takes the reply at that alias bare, from a server
of its own domain, or in one envelope, `{erx_origin, D, {erx_9p, Alias,
Reply}}`, from a server of another, whatever `D`: an alias cannot be
guessed, so whoever answers at it answers for the server, the rule `gen`
follows for a call's reply
([design-domains.md](design-domains.md#the-peer)). The reply is held to
its request by the grammar either way, and a request whose server ends
before its reply arrives answers `eio`. A link that leads a resolution from a grant onto
the release or an EROFS image leaves the resolver's next action on that
entry, and `prim_file` runs the operation there, as on any path the
caller writes. `erx_file_remote` and `erx_path` are preloaded, as
`prim_file` and the EROFS reader are, and call only BIFs and preloaded
modules: whatever process calls `file` or `erl_prim_loader` on a
server's path runs them, the code server included when a server's
directory is on the code path, and a module the code server would have
to load then halts the node.

**The working directory** is one place per runtime, held in `prim_file`'s
NIF as one binary under a mutex, starting at `/`, which
`erx_get_cwd_nif/0` copies out and `erx_set_cwd_nif/1` replaces, each in
one call, and which only `prim_file:set_cwd/1` writes: every name of it
a directory that the resolution which set it reached. `set_cwd` stores
only a text that `erx_path:cwd/1` reads as a place, `/` alone or plain
names joined by single `/`, at most 256 of them and shorter than
`ERX_PATH_MAX` bytes, so the NIF checks only that it fits. It is not a
persistent term because it changes often, OTP's `test_server` setting it
for every test case, and each change of a persistent term costs a scan
of every process ([Performance](#performance)); and not an ETS table,
which would need an owner process that `erl_prim_loader` cannot wait for
at boot and whose end would lose it. The resolver starts every relative path from it. `set_cwd`
resolves its path as `chdir` does, with `LOOKUP`, following a last link,
to a directory. On the release file system the walk's last kind tells
what it reaches. On a grant, `erx_file_remote` asks `getattr` of the
target: anything but a directory answers `enotdir`, a directory without
the owner's search bit answers `eacces`, as the server checks the
owner's bits for a walk, and a walk that stops answers as the walk does
(`enoent` for a missing name). It then stores the place the resolution
reached, as an absolute path, which the NIF refuses with `einval`
unless it is plain names within the bounds of a place, since any
process can call it; `get_cwd` answers the stored place. So the working directory
that `set_cwd("l")` sets, `l` a link to `d`, is `d`'s path, and `get_cwd`
answers it, as FreeBSD's `getcwd` answers a directory's own path. The
working directory holds no fid and no grant, only the path, and only the
namespace turns it into a server, as for any path the caller writes. A
mount change between the check and the store leaves the state the same
change leaves just after the store. Once a grant's process ends, the
paths of its entries, the working directory's among them, answer `eio`;
once the entry is unmounted, they reach what the namespace maps at that
path then, the release file system, a later mount with that mount's
rights, or nothing (`enoent`), as the same absolute path would. So a
working directory never reaches a server the namespace does not map at
its path, and never keeps a server reachable past its unmount beyond a
resolution already under way ([Resolving a path](#resolving-a-path)).
Error step 5 below finds the working directory through this path.

* path operations (`read_file_info`, `list_dir`, `make_dir`, `delete`,
  `rename`, `make_link`, `make_symlink`, `read_link`, `read_file`,
  `write_file`), at the resolver's target or parent action, attach a fid
  of their own on the grant, walk from it into a second, new fid, act on the second and clunk both, the requests
  sent together, so each operation's fids are the calling process's from
  first to last ([Fid owners](#fid-owners)). The operation names only
  the walk's new fid, which exists only if every name was walked: after a
  walk that stops early, the operation finds no fid and fails with
  `ebadf`, having changed nothing, and the client calls the resumption with the walk's
  reply, and the resolver answers its error or follows the link it
  stopped at. A walk in place would leave
  its fid on the last directory it reached, where a `delete` of
  `/tmp/missing/victim` sent with it would remove `/tmp/victim`; walking
  to a new fid makes that impossible rather than checked
  ([Pipelined requests](#pipelined-requests)). Stock OTP sends these through the
  `file_server_2` process (`lib/kernel/src/file.erl`,
  `check_and_call/2`); erXos's `file` resolves the path first and sends
  only local paths there, so a slow server delays only the processes
  that wait for it;
* `open` without a mode that creates is a target: it walks the names and
  opens the result with `lopen`; with one (`write`, `append`,
  `exclusive`), it is a parent: it walks the last name's directory and
  sends `lcreate`, which creates the file or
  opens the one already there in one step, so two processes opening one
  new name both succeed, as on UNIX; `lcreate`'s `eloop` hands the link to
  the resolver, which follows it, counted with the path's others
  ([Resolving a path](#resolving-a-path)), and a top answers as step 3 of
  the errors below says. It returns OTP's file
  descriptor record with `erx_file_remote` as its module, holding the
  grant, the fid, the opening process, an `atomics` array holding the
  offset and whether the file is closed, and a read buffer, so `file:read/2`, `file:pwrite/3`, `file:position/2` and
  `file:close/1` dispatch to it as they dispatch to `prim_file` for local
  files. The read buffer is stock's: a file opened with `read_ahead`
  reads that much more than asked and answers later reads from what it
  read, even after another file has written over those bytes, and
  `read_line` buffers as stock's does; `position`, `write`, `pwrite` and
  `truncate` empty it, and the offset is always the next byte the caller
  has not read; stock's `pwrite` empties its buffer but leaves its
  descriptor's offset past the bytes read ahead, so that its next read
  skips them, which erXos's does not. One read answers at most
  0x7ffff000 bytes, 4 KiB short of 2 GiB, a short read the caller reads on from. The opening process owns the fid, so the file closes when that
  process ends, and a call from any other process fails with
  `error(not_on_controlling_process)`, as stock `prim_file`'s
  `get_fd_data/1` fails it. A write sets the offset by the rule of [Open
  files and offsets](#open-files-and-offsets), to the reply's `At` plus
  its count from erXos's servers;
  `file:allocate/3`, which 9P2000.L has no operation for, answers
  `{error, enotsup}`, and `{error, einval}` on a closed file, as stock
  answers on a platform without preallocation; `file:advise/4`, which
  9P2000.L has no operation for either, answers `ok`, as stock's
  `efile_advise` answers on a platform without `posix_fadvise`, advice
  being only a recommendation, once its arguments pass stock's checks: an
  unknown advice, or a negative offset or length, answers `{error, einval}`;
  `file:ipread_s32bu_p32bu/3` reads the pointer block and then its data
  through the same reads as `pread`, as stock's NIF does; `file:sendfile/5` takes
  `file`'s fallback of reads and sends, since a remote file has no
  descriptor to hand to the host's call;
* a request waits for its reply or for the end of the grant's process,
  which the client monitors, as a call on a local file system waits for
  its medium: a slow medium makes it wait, never fail. A process that
  ends with a request in flight needs no cleanup of its own: the reply
  goes to an alias that ended with it, and the grant clunks its fids when
  its end arrives ([Fid owners](#fid-owners)). `flush` is for a request a
  live client abandons, as a native program's interrupted read of a
  terminal is. A server that dies while files are open turns their next
  operations into `{error, eio}`.

A rename or a `make_link` resolves its two paths one after the other,
against one table read once, the source or the existing path first, as
FreeBSD's `kern_renameat` and `kern_linkat` look them up, each to its
last action, so their request goes where that one table maps both. Two
last actions on entries of one grant, one tree and one set of rights,
whatever entries they pass, go together: `erx_file_remote` sends the two
walks and the one request that takes both; a walk that stops at a link
goes to its own path's resumption, and the two are compared again once
both reach their last actions. A path on a grant paired with a path on
another grant, another tree, other rights or a local provider answers
`{error, exdev}`, as between two UNIX file systems, without asking either
server. A rename whose source is an entry's top answers `ebusy` as soon
as the source's resolution ends, before its destination is resolved, as
`kern_renameat` answers before it looks up the destination, and one whose
destination is a top answers `ebusy` once both are resolved, before the
two are compared (step 3 of the errors below). Two paths neither on a
grant are the local providers', which are read-only.

**Links and a trailing `/`.** The resolver follows links as [Resolving a
path](#resolving-a-path) states, and the client only performs its walks
and link reads: a walk that stops at a link, or ends on one the operation
follows, goes to the resumption with its reply, and a link read is a walk
to the link and its `readlink`, sent together on fids of the client's
own. The operation then runs where the resolver's next action lies: on
the grant and with the rights of the entry the link's text reaches, or
on a local provider, so a link on a
read-only bind that leads to a writable entry writes there, as a link
between two UNIX mounts does, and leads nowhere the caller's namespace
does not. A rename or a link whose two paths then lie apart answers
`exdev`. On a read-only entry an operation walks its paths, sending
nothing that writes, before it answers `erofs`, so a link among them
leads it to the entry it reaches and a missing directory answers first.
An operation sent with a walk acts on the link's own fid when the walk
ends on a link it would follow; a server answers `enotdir` for an
operation that needs a directory there, the resolver follows the link, and
the client sends the operation again.

A path written with a trailing `/` names a directory, as FreeBSD's
`vfs_lookup` takes it under `TRAILINGSLASH`: its last link is followed
whatever the operation, the `/` holding through the link's text, and the
text of a last link that ends in `/` sets it as the path's own `/` does; a last
name that exists and is not a directory answers `enotdir`, whatever the
operation; and a last name that does not exist may be made only as a
directory, by `make_dir` or by a rename of a directory, any other
operation answering `enoent`. So `read_file_info`, `read_link_info`,
`list_dir`, `write_file_info` and `read_link` (`einval` once the path
reaches a directory, which is not a link) follow the last link and
require a directory. `make_dir` answers `eexist` for a directory and
through a dangling link makes the directory the link names; `del_dir`
through a link removes the directory the link leads to; `delete`
answers `eperm` for a directory, a link to one included; `rename` moves
or replaces the directory a last link leads to; `make_symlink` and
`make_link`'s new name answer `eexist` for a directory, and an `open`
that creates answers for one as without the `/`, `eexist` when it is
`exclusive` and `eisdir` otherwise; and `make_link`'s existing path is
followed, must be a directory, and so answers `eperm` before its new
name is looked up, as `kern_linkat_vp` refuses a directory before its
`CREATE` lookup of the new name. The resolver makes each of these checks with a walk of the
last name (step 6 of [Resolving a path](#resolving-a-path)) before
anything is sent that changes the tree.

**Modes.** A file that `open` creates is sent with stock's mode `8#666`
and a directory that `make_dir` makes with `8#777`, the modes stock's
`efile_open` and `efile_make_dir` pass to the host, each less the
domain's `umask`, 022 by default, which the host's kernel would take off,
so `lcreate` and `mkdir` always carry the mode the file gets, and a
server stores the mode it is given. `write_file_info` sends a record's
`mode` masked as stock's `efile_set_permissions` masks it, to the
set-user-ID, set-group-ID and permission bits (`8#6777`): a record read
back carries its type bits, such as `8#100644`, which are dropped rather
than sent as a mode outside the `0..8#7777` a server's modes are typed
with ([Serving](#serving-the-erx_fs-behaviour)).

**Errors.** `erx_file_remote` answers as stock `prim_file` answers on a
UNIX host whose path resolution is FreeBSD's, the host's platform layer
adjusting some of the system's errors after they happen (`efile_rename`,
`efile_del_file` and `efile_del_dir` in `unix_prim_file.c`). A server
answers with the atoms of Linux's own errors, as any 9P2000.L server
does, the resolver answers for the path as FreeBSD's `namei` does, and the
one translation lives here, applied in this order:

1. `rename` whose source path, as the caller wrote it, is `"/"` answers
   `einval`, stock's own check for a failed rename of `/`, before any
   other answer. `prim_file` decides it before the source's resolution
   starts, the one place outside the resolver where a path's text as
   written is read.
2. The resolver's answers stand for the path, as FreeBSD's `namei` gives
   them: `enoent` for a missing name or an empty link, `enotdir` for a
   name used as a directory that is not one, `file/.` and `file/..`
   included, `eloop` past 32 links, `einval` and `enametoolong` for a
   malformed path or one over its bounds, and, once the names before it
   have joined the place, `einval` for a last `.` or `..` of `del_dir`
   or of `rename` on either side. `delete` answers every `einval` of the
   resolver as `eperm`, a malformed path's and a last `.` or `..`'s
   alike, as `kern_funlinkat` turns every `EINVAL` of `namei`, so
   `delete("d/..")` and `delete(".")` answer `eperm`, while a trailing
   `/` after a file stands as `enotdir`, `vfs_lookup`'s answer under
   `TRAILINGSLASH`. The degenerate `/` given
   to anything but a lookup, from the path or a link's text, answers
   `eisdir`; step 4 makes it `eperm`
   for `delete`, as stock's `efile_del_file` makes FreeBSD's `EISDIR`,
   and a rename of a directory onto `/` answers `einval`, as
   `kern_renameat` turns it. `make_link` resolves its
   existing path first, as `kern_linkat` looks it up before the new name,
   and a failure there is the answer, as is `eperm` for a directory there,
   whatever the new name, as `kern_linkat_vp` answers before it looks the
   new name up; `make_symlink`'s target is text and
   is never resolved. Steps 4 and 5 then apply to the answer as to a
   server's.
3. A **top**, an existing directory that no request to a parent can name
   (a last `.` or `..` of an operation that makes a name, or the top of a
   mount or a bind), is answered without asking, by the operation, as
   FreeBSD answers for an existing directory or for the root of a mounted
   file system: `make_dir`, `make_symlink` and `make_link`'s new name
   answer `eexist`; an `open` that creates answers `eexist` when it is
   `exclusive` and `eisdir` otherwise, as `vn_open_cred` answers; `del_dir`
   answers `ebusy`, `kern_frmdirat`'s answer for the root of a mounted
   file system; `delete` answers `eperm`, `kern_funlinkat`'s answer for a
   directory; and `rename` answers `ebusy`, as source or as destination,
   `kern_renameat`'s answer for the root of a mounted file system: the
   lookup of a mounted root returns as its parent the mount crossing,
   not a directory. A server is never asked, whatever the entry's
   rights. The degenerate `/` of step 2 is
   answered before a top is: `/` is the top of the entry mounted there,
   but `del_dir("/")` answers `eisdir`, not `ebusy`.
4. `enotempty` from `del_dir` or `rename` becomes `eexist`, and `eisdir`
   from `delete` becomes `eperm`.
5. After step 4, a `del_dir` that failed with `eexist` answers `einval`
   when the directory its path reaches is the working directory, compared
   as stock compares them, by identity: the same grant, tree and qid
   path, from a `getattr` of each. An empty working directory is removed
   like any other, as on UNIX.
6. Opening a directory without `[directory]` answers `eisdir`.

The oracle cases of [/tmp's verification](design-tmp.md#verification)
check each of these against stock OTP on macOS, whose path resolution
derives from FreeBSD's; where macOS answers otherwise, erXos answers as
FreeBSD, and the comparison names the case
([Compatibility](#compatibility-and-migration)).

**File information.** `read_file_info`, `read_link_info` and
`file:read_file_info/2` on an open file ask `getattr` for the basic fields
and the `data_version` bit, and build the record stock's
`build_file_info` builds from a `stat`, which `prim_file`'s own Erlang
code then converts as it converts a local file's, its times under
`{time, local | universal | posix}` included:

| `#file_info{}` field | From |
| --- | --- |
| `size`, `links`, `uid`, `gid` | `size`, `nlink`, `uid`, `gid` |
| `mode` | `mode`, its type bits included, as `st_mode` |
| `type` | `mode`'s type bits: `regular`, `directory`, `symlink`, `device` for a character or block device, `other` for the rest |
| `inode` | the qid's path |
| `major_device` | a number the namespace gives each mounted tree, the same for every path into that tree while it is mounted, standing for `st_dev` |
| `minor_device` | `rdev`, 0 for anything but a device |
| `atime`, `mtime`, `ctime` | the `_sec` fields; the nanoseconds are dropped, as stock reads `st_atime` |
| `access` | `read_write`, `read`, `write` or `none` from the owner's read and write bits, as stock's `check_access` reads them for the file's owner; for a path, from the file the path reaches after its links, as stock's `access(2)` follows them, so `read_link_info` of a link reports its target's access, read with `read_file_info` of the same path, and `none` for a link that resolves to nothing |

`write_file_info` sends what stock's `write_file_info_1` would set, in its
order and with its defaults: an owner and group if either is given, then
the mode, then `atime` and `mtime`, an absent `atime` taking the current
time and an absent `mtime` the `atime`; `ctime` is never sent, since
stock's `set_time` ignores it, and the server sets it.

A session's handler is an Erlang client like any other: it resolves its
program's path with `erx_path` over the program's table, a term in the
handler's own state, and acts
through `erx_file_remote`'s requests on the program's fids, so a
program's file reaches the server by the same code as a `file:open/2` in
the session, and its paths resolve by the same resolver: a program's
`open`, `chdir` and `getcwd` answer as `file:open/2`, `set_cwd` and
`get_cwd` answer in the session, over the program's namespace.

### Native clients: `liberx`'s file client

A native program's musl calls `liberx` for every file function, and
`liberx` turns each into a request on the program's channel to its handler
([design-programs.md](design-programs.md#the-channel)). `liberx` keeps the
program's table of at most 1,024 descriptors, in which a file is one kind
of object beside pipe ends and sockets, and descriptors 0, 1 and 2 are the
standard streams
([design-programs.md](design-programs.md#descriptors-and-files)); it keeps
no namespace, no working directory, no grant and no fid. An open file is
known to the program by a **file number** its handler gave it at `open`,
naming an open-file description, and several descriptors may name one
file number, so `dup` and `dup2` cost no request. The handler keeps, for
each program, its namespace and working directory and a table from file
numbers to descriptions, and refuses with `EBADF` a file number the
program does not own (F9).

**The data area.** File data does not cross the channel per byte. At a
program's start its session creates a **data area**, a memory object from
the session's own budget, as the program's channel is, and installs it
into the program's sub-space, which maps it read-write; it holds `slots`
slots of 64 KiB, the protocol's largest payload inside the machine, 4 by default and set by
the session's policy for each program. A `read` names a free slot and a
count; the handler relays `{read, Fid, Offset, Count}` at the
description's offset, copies the reply's bytes into the slot through its
NIF, and answers the count, after which `liberx` copies the slot into the
caller's buffer, never more than the count it asked for, and frees the
slot. A `write` copies the caller's bytes
into a slot first and the handler copies them out into the `write`
request. A thread that finds no free slot waits for one, so a program's
requests in flight are bounded by its slots, and the session, which sized
the area, holds nothing per request beyond them. The same shape serves
`getdents`, `readlink`, `getxattr` and every reply larger than a few
words.

The POSIX functions map onto 9P2000.L as Linux's 9P client maps them.
`open` sends the path, flags and mode less the program's `umask`, and the
handler resolves, then sends the walk, the clone and the `lopen`, or with
`O_CREAT` the walk to the directory, the clone, the `lcreate` and the
walk to the new file, together ([Open files and
offsets](#open-files-and-offsets)). A read-only grant refuses every
`lcreate` (F5), so on a read-only mount the handler turns an
`open(O_CREAT)` without `O_EXCL` into the walk and the `lopen` of an
open without `O_CREAT`, and answers `EROFS` only when the walk finds the
name absent; with `O_EXCL` it answers `EEXIST` for a name the walk finds
and `EROFS` otherwise, as Linux does on a read-only mount. `read` and
`write` use the
description's offset, and `pread` and `pwrite` explicit ones, at most 64
KiB per request, looping for larger counts; `lseek` moves the
description's offset; a description opened with `O_APPEND` opens its fid
with 9P2000.L's append flag; every write sets the description's offset by
the rule of [Open files and offsets](#open-files-and-offsets): the
reply's `At` plus its count from erXos's servers, and for a reply
without `At` from a server outside erXos the offset the write was sent
at plus its count, except through an append fid, where the rule's one
`getattr` reads the file's size; `fcntl`'s
`F_SETFL` of `O_APPEND` moves the
description's writes to an opened fid with the new flag, which the first
change opens from the unopened fid ([Open files and
offsets](#open-files-and-offsets)); `stat` is `getattr`, and `chmod`,
`truncate` and `utimensat` are `setattr`; `mkdir`, `symlink`, `link`,
`mknod`, `readlink`, `unlink`, `rmdir`, `rename` and `statfs` are the
operations of their names, the removals as `unlinkat` and renames between
directories as `renameat`; `fcntl`'s record locks are `lock` and
`getlock`, with the program's own `ProcId`, taken through the
description's first opened fid; `close` of a file descriptor that leaves
its open other references sends `{close, Open}`, once the program has
taken a record lock, and the open's last reference sends `{clunk, Open}`,
and at each the handler releases the program's locks on the file, as
POSIX says, while the description's fids close only with its last open
([design-programs.md](design-programs.md#descriptors-and-files)); a
program's end releases all of them ([Locks](#locks));
`getxattr`, `setxattr` and `listxattr` are `xattrwalk` and `xattrcreate`
with a read or a write on the new fid; `chdir` moves the working directory
the handler keeps, which it resolves and checks as `set_cwd` does,
storing the place it reached, and `getcwd` asks for that place, the
directory's own path, as FreeBSD's `getcwd` answers it; `posix_spawn` asks the handler, which opens the
executable through the program's `rx` mount and starts the child
([design-programs.md](design-programs.md#what-a-program-can-start));
`getdents` pages directories with `readdir`, and `telldir` and `seekdir`
keep and send its offset. `mmap` of a file with `MAP_SHARED` asks the
handler for a mapping of the session's shared object, and `msync` asks for
a write-back ([Shared mappings](#shared-mappings)). A thread that sends a
request waits for its reply in its own slot of the channel
([design-programs.md](design-programs.md#the-channel)). Because every
mount of a program is a fid on a grant, a program has no local file system
of its own.

A program's open files belong to the program, not to its image, so an
`exec` keeps them
([design-programs.md](design-programs.md#the-second-tier)). The handler,
which holds every fid of the program, does the bookkeeping, in order on
the session's connection, so every clunk of the old image's reaches its
server before any request of the new image's: it closes the program's
share of every description that no descriptor the new image keeps names,
a close-on-exec file's among them, releases the program's locks on the
file of every descriptor the old image drops, as their closes would, and
tells each mapper that the old image's mappings ended, which writes them
back.

A program's terminal is `/dev/tty` at the session's export, and its
standard streams that reach the terminal are opens on it; a read is a
`read` that the export answers when the terminal relay has a line for
that reader. How a program waits for a terminal, how a signal interrupts
that wait, and the terminal's controls, which go to the terminal relay
that owns the terminal and are no operation of the file protocol, are
the handler's ([design-programs.md](design-programs.md#the-terminal)).

### Text in file names

A name is the bytes it was given. Servers and clients require valid UTF-8
and never normalise, so a name is compared byte for byte. A file copied
from a Mac keeps the decomposed form that macOS's file systems give
accented names, and the same name typed on erXos in composed form does not
match it; the shell's completion shows the stored bytes. Escaping for
display belongs to whatever displays a name under its source
([design-live.md](design-live.md#attributed-text)).

A file's contents are its bytes too: no server and no client changes
them on the way, so `cat`, pipes and files pass them exactly. One server
writes escaped text: `/proc`. Everything in it is inspector output, text
a domain or a runtime reported under its own name, which `cat` writes to
a terminal as the bytes of a file, so the tree writes every field
through the field escape, `erx_text:escape_field/1`: tab, newline and
backslash as `\t`, `\n` and `\\`, and every byte of a control, format
character, separator, unassigned or invisible character, and of invalid
UTF-8, as `\xNN`. The escape is injective, and `erx_text:unescape_field/1`
recovers a value's exact bytes
([design-live.md](design-live.md#the-proc-tree)).

## Interfaces

* **`erx_ns`**, in every runtime: `bind/2,3`, `mount/3`, `unmount/1`,
  `which/1` (the mount and names a path resolves to, as
  `read_file_info` resolves it) and `list/0` (the table); each returns `ok` or `{error, Reason}`, with `einval` for a
  malformed path, `enoent` for a `From` that resolves to nothing, and
  `system_limit` beyond 64 entries. Its process is the one writer of the
  domain's table; a session's handler applies the same pure changes to
  each program's table.
* **`erx_path`**, preloaded in every runtime: `resolve/6`, which
  resolves one path against a table and a working directory through a
  walk and a link-read callback and returns the last action with its
  resumption ([Resolving a path](#resolving-a-path)). Its callers are
  `prim_file`, `erx_ns:bind/2,3` and every session's handler.
* **`erx_fs`**, the behaviour above, and
  `erx_fs:start_link(Module, Args, Rights)` to serve one grant of a tree's
  root to the server's own domain, and `start_link/4`, whose options name
  the client domain (`client`, `own` or the domain's id) and the grant's
  pool (`pool`);
  every file server is one. `erx_fs_version:init/0` makes the domain's
  file version counter and `erx_fs_version:draw/0` draws from it
  ([Identity and version](#identity-and-version)).
* **The file protocol**, 9P2000.L, as a **frame profile** of
  `abi/erx_abi.txt`: the operation table, with each message's fields,
  bounds, 9P2000.L layout and whether it writes, from which a Ruby
  generator produces the Erlang decoder that `erx_fs` and
  `erx_file_remote` use, the refusal set of F5, the per-operation reply
  checks of [Bounds](#bounds) and `erx_9p`, so every
  client, server and edge shares one definition. It also generates client
  construction/reply helpers, server dispatch declarations, operation/field
  reference tables and bounded-input builders, boundary mutations and fuzz
  entry points. Server callbacks keep file semantics and authorization
  decisions, and Linux's client/server and independent byte fixtures check
  the generated codec ([design-generation.md](design-generation.md)).
  The program protocol
  between `liberx` and a handler is a frame profile too
  ([design-programs.md](design-programs.md#the-channel)).
* **`erx_9p`**, the codec: `decode(Bytes, Msize)` returns
  `{ok, Tag, Message}` or `{error, Reason}`, a message whose header is
  whole but whose fields fail as `{malformed, Tag}`; `encode(Tag, Message)`
  returns 9P2000.L's bytes, and `encode(Tag, Message, Msize)` refuses a
  message larger than `Msize` ([The codec](#the-codec)).
* **`liberx`**: the file functions of musl's POSIX layer over requests to
  the program's handler and the program's data area; it holds no
  namespace, no grant and no fid, and serves no files.
* **The kernel**, for shared mappings: `erx_mem_create` with
  `ERX_MEM_INHERIT`, `erx_mem_grow`, `erx_mem_copy` and `erx_mem_dirty`
  on the session's shared objects, where `erx_mem_grow` and
  `erx_mem_dirty` need `SUPPLY`, which the mapper keeps, and the
  session's installs into its programs' images
  ([design-kernel.md](design-kernel.md#virtual-memory)).

Interaction with other subsystems:

| Subsystem | Interaction |
| --- | --- |
| Domains | requests are frames on the connection between client and server, to a grant pid the server exported to the client, each to a fresh alias; servers in the system domain stand behind facets ([design-domains.md](design-domains.md#facets)) |
| System | the domain service builds namespaces and the facets they mount ([design-system.md](design-system.md#creating-a-domain)) |
| Kernel | a session's shared object for a mapped file is an ordinary shared memory object of the session's budget, which the session grows, fills, maps into its programs' images and writes back from the pages `erx_mem_dirty` reports; its faults resolve from its own pages ([design-kernel.md](design-kernel.md#virtual-memory)) |
| Runtime | `prim_file` resolves through the namespace with `erx_path`, preloaded Erlang; the release provider stays in the NIF, the EROFS reader, preloaded Erlang, serves EROFS mounts ([design-runtime.md](design-runtime.md#files)), `erx_file_remote`, preloaded Erlang too, is the client of every file server, and each domain runs its own RAM file server for `/tmp` ([design-tmp.md](design-tmp.md)) |
| Programs | a handler keeps each program's namespace, fids and descriptions, relays its requests and moves bytes through the data area; the session's mappers serve its programs' shared mappings ([design-programs.md](design-programs.md#the-handler)) |
| Live machine | `/proc` and the session's export are `erx_fs` servers ([design-live.md](design-live.md#the-proc-tree)); the host link's bridge and the host-tree domain carry 9P2000.L to and from the host ([design-live.md](design-live.md#files-between-the-host-and-the-machine)) |
| Storage | the storage services and the FAT server, in Erlang, serve the data partition's and FAT partitions' files through `erx_fs`, behind each principal's facet ([design-storage.md](design-storage.md)) |

## Compatibility and migration

Stock code that uses `file` and `filelib` on paths works unchanged. The
differences, each with a test, extend the
[Erlang-visible behaviour](design-runtime.md#erlang-visible-behaviour)
table:

* paths resolve as FreeBSD's `namei` resolves them, and where macOS,
  stock's host in the comparison, answers otherwise, erXos answers as
  FreeBSD: `make_dir("/")` answers `eisdir` where macOS answers
  `eexist`; with a trailing `/`, `make_dir("file/")` answers `enotdir`
  where macOS answers `eexist`, `make_dir` through a dangling link makes
  the directory the link names where macOS answers `eexist`, and
  `del_dir` through a link to a directory removes that directory, where
  macOS answers `enotdir`;
* a symbolic link's text is resolved by the client through its own
  namespace, so a link leads where its reader's namespace leads;
* a `..` that a concurrent rename races passes the moved directory's old
  path, where FreeBSD's follows the directory to its new parent
  ([Resolving a path](#resolving-a-path));
* a working directory is a path, so a domain or program whose working
  directory is renamed stays at the old path, where UNIX follows the
  directory. `get_cwd` answers the path of a working directory that was
  removed, where Linux's `getcwd` answers `enoent`. `..` from a removed
  working directory reaches the parent of its path; FreeBSD's tmpfs and
  macOS's `chdir` answer `enoent`. An entry the working directory lies
  under is unmounted like any other, where Linux's `umount` answers
  `ebusy`, and so is an entry that a resolution under way has crossed,
  the resolution finishing on the table it began with, where FreeBSD's
  `unmount` answers `EBUSY` while a lookup holds a directory of it;
* a rename between two grants, two trees or two sets of rights fails
  with `exdev`, where Linux also fails between two mounts of one tree;
* every operation on a file whose server died fails with `eio`;
* a write larger than 64 KiB is several requests, each atomic, which
  another writer's may fall between, where a local Linux file system
  holds the file for the whole call ([Open files and
  offsets](#open-files-and-offsets));
* a positioned write to a file opened for `append` appends, as on Linux;
  on macOS, and as POSIX says, it writes at its offset;
* `file:allocate/3` answers `enotsup`, as on a platform without
  preallocation;
* hard links, symbolic links, device nodes and extended attributes exist
  where the server's format keeps them, and an open of a device node or a
  FIFO fails with `enxio`.

For native programs: an `open` with `O_NOFOLLOW` of a link answers
`EMLINK`, as FreeBSD's does, where Linux and macOS answer `ELOOP`; a
page of a shared mapping wholly past the file's
end reads zeros rather than raising `SIGBUS`; the `munmap` whose
write-back fails returns `EIO`; and two sessions that map one file shared
each hold their own copy, which meet at the server page by page as each
writes back ([Shared mappings](#shared-mappings)).

The protocol is 9P2000.L as specified, so a 9P2000.L client or server
from elsewhere meets it at an edge unchanged; inside the machine a
`version` resets nothing ([Version and attach](#version-and-attach)) and
`write`'s reply carries the offset its bytes landed at ([Open files and
offsets](#open-files-and-offsets)), the two deliberate differences, and
each request names the owner of the fids it makes ([Fid
owners](#fid-owners)). The term form is erXos's
frame profile; it owes nothing to an earlier form
([design.md](design.md#compatibility)): a change to it replaces it on both
sides, which come from one tree. Nothing persists to carry across:
namespaces live only in running domains, and fids end with the domains
that hold them.

## Failure handling, diagnostics and debuggability

| Failure | Detection | What remains | Cleanup | What the user sees |
| --- | --- | --- | --- | --- |
| A malformed path | the resolver | nothing | none | `einval` (`eperm` from `delete`) or `enametoolong` |
| A frame that fails the funnel | the receiver's funnel | nothing | the receiver stops reading the lane and the system domain takes the connection down ([design-domains.md](design-domains.md#the-funnel)) | `noconnection` on every grant across that connection; `eio` on its open files |
| A request that fails the protocol's grammar or bounds | `erx_fs`, before any callback | nothing | none | `einval`; the server counts it |
| A 9P2000.L message at an edge that fails the codec | `erx_9p` | nothing | the bridge discards it and counts it | the edge's client sees no reply, as for a message lost on its transport |
| A client over its bounds | `erx_fs` or the facet | its existing fids | none | `emfile` |
| A program over its handler's bounds, or naming a file number it does not own | the handler | the program's existing files | none | `EMFILE` or `EBADF` |
| A link loop or a chain over 32 links | the resolver's count | nothing | none | `eloop` |
| A slow medium | none: the request waits | the request at the server | none | a wait, as on a local file system; an interrupt flushes it |
| A server dies, or a grant ends | the client's monitor on the grant, which the connection's end also fires | nothing at the server | the client marks its fids dead | `eio` on every open file of that grant; the mount stays, so a restarted service can be mounted again |
| A client process ends | the grant's monitor on each fid owner, whose `DOWN` follows every request the owner sent ([Fid owners](#fid-owners)) | nothing | the grant clunks every fid the process owned, which releases their locks and, for an open file, the file's open | nothing |
| A client domain dies | the connection going down, which ends every export across it and fires the grant's monitor on the client ([design-domains.md](design-domains.md#connections)) | nothing | the grant clunks every fid it holds, which releases their locks | nothing |
| A program ends | its handler, which owns the port | nothing | the handler unlocks every lock of the program's `ProcId`, clunks every fid it walked for the program, closes its share of every description and tells each mapper of a file it mapped | a log line for a failed write-back |
| A reply exceeds its request | the generated reply check in `erx_file_remote` or the bridge | nothing | the client discards the reply and counts it | `eio` |
| A write-back fails | the server's error, at the mapper | the pages it carried, written again at the next write-back; nothing after the last | the mapper | `EIO` from the `msync`, `close` or `munmap` that asked; a log line and a count at a program's end |
| A session ends with stores not written back | the session's end | nothing of the object | the kernel deletes the object with the session's budget | the stores are lost, as a machine's are when it stops without a sync |

`erx_ns:list/0` and the inspector's `[domains, Id, namespace]` path show a
domain's table, and a session's `[domains, Id, programs, N, namespace]`
a program's; each server counts its grants, fids, locks and refused
requests, each session its mappers and their write-backs, and `erx:trace`
can mark a domain's file protocol frames.

## Security

* **Links that a server writes.** A link's text steers a resolution
  only within the reader's own namespace, so a hostile server's link
  reaches nothing the reader does not hold. A trailing `/` makes a
  removal, a rename or a `make_dir` act through a last link, as on
  FreeBSD: `del_dir("/mnt/e/")` with `e` a link on a server at `/mnt`
  to `/data/d` removes `/data/d`, so a program that removes or makes
  names under a tree it does not trust writes the path without the `/`
  or resolves it first.
* **Trust boundaries.** A server trusts no client: every request is
  untrusted input, checked by the funnel and by the protocol's grammar,
  or at an edge by `erx_9p`, before any callback. A client trusts a server
  only as far as its grant: a reply is decoded with the same grammar and
  held to its request by the generated reply checks ([Bounds](#bounds)),
  a file's contents are data, and a link's text is a path the client
  resolves through its own namespace. A handler trusts its program not at
  all: a program's request is untrusted input to the session, checked
  against the program protocol's grammar and the program's own table. A
  path string from another domain, such as one inside a request to a
  service, is untrusted and goes through `erx_path` or the protocol's
  name rules, never through string handling of its own. Inside a
  runtime, every caller of `erx_path` is the domain's own code, which
  already holds every grant its table names, so a path it crafts, a
  table it hands the resolver or a resumption it forges reaches nothing
  more; what crosses a trust boundary into the resolver, a link's text
  from a server and a program's path through its handler, is checked as
  [Resolving a path](#resolving-a-path) states, and a handler resolves
  only over the program's own table and walks only from its fids (F3).
* **A held table.** A resolution that outlives an unmount or a bind's
  replacement still walks only the grant its old entry named, which the
  domain still holds, from that entry's `root`, and for no longer than
  that one resolution; a grant that has ended answers `eio`
  ([Resolving a path](#resolving-a-path)). Only revoking the grant, which
  is the server's and the system domain's, takes authority away; editing
  a namespace does not.
* **Authority.** F1 to F3 make the namespace no more than a view of
  exports and grants; F2 holds at the server, whatever a compromised
  client sends; F5 enforces read-only grants at the grant; F9 keeps every
  fid out of every program, so the handler's narrowing cannot be walked
  around by a program. A compromised session acts with its own grants,
  which bound every one of its programs.
* **Forgery.** Replies go to single-use aliases, so a domain that can send
  to a client cannot inject file contents into it, and a reply cannot
  match a later request. A lock's owner is the lane's domain, never the
  request's `ClientId`.
* **Resource limits.** F4. A server runs on its own capped grant and
  holds, per client, one grant process with a bounded heap, a bounded fid
  pool and a bounded lock table; a client that floods fills its own lane
  and waits. A fid count is not a CPU bound: the server's grant is.
* **Leaks.** An error never reveals whether a path outside the caller's
  namespace exists, since such a path resolves to no server at all; a
  scoped `/proc` answers `enoent` for what its scope hides
  ([design-live.md](design-live.md#the-proc-tree)); a listing's mount
  points come from the client's own table.
* **Shared mappings.** A server never reaches a program's memory and
  nothing it does makes a program fault or wait in a fault: a mapping maps
  an object of the session's, whose faults the kernel resolves from its
  own pages, and the server sees reads, writes and a lock. A program
  stores only through a mapping whose ceiling its open fixed, holds no
  capability that can delete, copy, pass or grow the object or read its
  store marks, and spends only its session's budget.

Residual risks accepted: a compromised file-system domain serves wrong
data, and reads and writes every file on its partition, as the threat
model states ([design.md](design.md#threat-model)); a native program that
a crafted input compromises acts with the fids its handler holds for it;
the programs of one session share the three quarters of each grant's pool
that the session leaves them, so one program can make its siblings' opens
on that server fail with `emfile` until the user stops it, as they share
the session's budget
([design-programs.md](design-programs.md#security)); and a session's
write-back of a page overwrites what another domain wrote into that page
since the session filled it, as a network file system's client does.

## Verification and testing

Each test below names the failure seeded into it, which the test must
report, so a passing run shows the code under test ran.

* `erx_path`: a fuzz target in Erlang, built and run on the host by
  `make check-fuzz` for its budget, in the style of
  `test/erlang/erx_file_remote_fuzz.erl`, that builds a random model tree
  (directories, files, and relative, absolute, empty and looping links),
  a random table over it (entries, binds with roots, a narrowed table
  with no `/`), each point a directory, reached without a link, of the
  entries whose points lie above it, as a mount of FreeBSD's needs, and
  a working directory, and random paths of plain names, `.`, `..`,
  doubled and trailing `/`, each with a random
  `nameiop`, `FOLLOW` and `WILLBEDIR`. It runs the resolver, answering
  its walks and link reads from the model tree through the callbacks and
  calling each resumption as an executor would, and compares the
  outcome, the last action's entry, names and kind or the error, with a
  reference model: a direct transcription into Erlang of FreeBSD's
  `vfs_lookup` over the same tree,
  written from `sys/kern/vfs_lookup.c`, which keeps a current directory
  node with its parent, takes `..` through the node's parent, crosses
  an entry's top back through the node its mount point covers, stops at
  `/`, follows a last link under `FOLLOW` or `TRAILINGSLASH`, and
  refuses a last `.` or `..` of `DELETE` and `RENAME` once the name
  before it is found to be a directory. That last rule is where the
  model departs from `vfs_lookup`'s text: FreeBSD's slow lookup refuses
  such a name before it checks the name before it, and its lockless
  name-cache lookup checks that name first and, by a reading of its
  source not yet run on FreeBSD, can hand the parent on to `rmdir` or
  `rename` for a last `..`, so FreeBSD answers one path differently by
  what its cache holds; the model takes the order of
  the cache lookup and the answers that rmdir(2), rename(2) and
  unlink(2) document. The same target feeds the resolver's untrusted
  inputs raw: paths and link texts of arbitrary bytes, NUL, invalid
  UTF-8, empty and over every bound among them, and walk replies longer
  than their walks, each answered with an error and never a crash; it
  changes the namespace's persistent term from inside a walk callback;
  and it checks the properties above: no walk names `.`, `..` or an
  empty name, every walk lies at or below its entry's `root`, a place
  never outgrows its bounds, and every action names an entry of the
  table the resolution was handed. Listings across mounts have a
  property test of their own. Seeded: a resolver
  that removes a run's name on `..` before its walk, which
  `missing/..` catches; one that takes `..` before following the link
  ahead of it, which `link/..` catches; one that walks `..` past a
  bind's root to the server, which the walk property catches; one that
  answers a last `.` of `DELETE` before checking that the name before
  it is a directory, which `file/.` catches; one that takes a link's
  text without checking it, which a text holding NUL catches; and one
  that reads the namespace's term again at a link instead of the table
  it was handed, which the change made inside a walk catches.
* The executor in `erx_file_remote`, hosted against an `erx_fs` server
  whose tree holds links and binds: `..` after a link to another
  directory and to another entry; `x/..` and `x/.` with `x` a file, a
  missing name and a link; `..` at a bind's top and at `/`; 32 links
  followed and the 33rd answering `eloop`; `change_mode("file/.")`,
  which answers `enotdir` and leaves the mode; `set_cwd` through a
  link, after which `get_cwd` answers the target's path; a rename
  whose source and destination resolve through links onto two entries,
  answering `exdev`; `del_dir("dlnk/")` with `dlnk` a link to an empty
  directory, which removes that directory, and `delete("dlnk/")`, which
  answers `eperm`; a rename of a bind's top, as source and as
  destination, answering `ebusy`; a bind whose `From` passes a
  link, whose entry roots at the link's target; an unmount made while a
  resolution waits on a slow walk, which the resolution finishes on the
  entry it began with while one started after the unmount answers as
  the new table says; a grant ended while a resolution holds its entry,
  which answers `eio`; and a walk of `..` handed straight to the
  client's request function, which answers `einval` and sends nothing.
  Seeded: a resolver that follows a last link only under `FOLLOW`, which
  the `del_dir` case catches as `enotdir`; an executor that sends an
  operation with a walk whose names still needed a check, which the
  `change_mode` case catches as the mode changed; one that stores the
  path as written as the working directory, which the `get_cwd` case
  catches; and a request function without its refusal of `.` and `..`,
  which the `..` case catches as a walk sent.
* The release NIFs' decoder of name lists: a fuzz target that hands
  `release_walk_nif` and the operations' NIFs arbitrary terms, lists of
  257 names and names holding `/`, NUL, `.`, `..`, invalid UTF-8 or 256
  bytes, each answered `einval` without reaching the core, under
  AddressSanitizer. Seeded: a decoder without its count check, which the
  257-name list catches.
* Two source checks of [design.md](design.md#chokepoint-checks), each
  with a seeded violation: only `erx_ns`'s process writes the
  namespace's persistent term and only `prim_file:set_cwd/1` calls the
  NIF that stores the working directory, which a `persistent_term:put/2`
  of the table's key and a call of `erx_set_cwd_nif/1` added elsewhere in
  `prim_file` each catch; and `erx_file_remote` sends a request only
  from its one request function, which a send added to another of its
  functions catches.
* The frame profile and `erx_9p`: a fuzz target for the server's decoder,
  one for the client's and one for the codec, built for the host; every
  operation of the table has an encoding test, term to bytes and back; a
  message whose size field exceeds `msize` or the bytes received, a string
  that runs past its message, and a count past what remains, each refused;
  seeded: a codec that skips the size check, which the oversized case
  catches.
* 9P2000.L against its oracles: under QEMU, the machine mounts a host
  directory through virtio-9p, so QEMU's 9P2000.L server checks erXos's
  client side, and runs OTP's `file_SUITE` over it; Linux's own 9P2000.L
  client in the oracle guest mounts an erXos server through the host
  link's bridge and runs a file-semantics corpus, compared with the same
  corpus on a Linux `tmpfs`; seeded: a server that answers `walk` of `..`
  at its root with the parent's qid, which both catch. Through the host
  directory, an ordinary write, a `file:pwrite/3` and an append, each
  followed by `file:position(Fd, cur)`, leave the offsets the offset rule
  gives for `At` = `unknown`; seeded: a client that applies the numeric
  rule to `unknown`, which the ordinary write catches.
* The exchange in `erx_file_remote`, against a server process of the
  test's that puts its replies in envelopes as a connection does: a
  reply bare and in one envelope of any domain is taken and held to its
  request, and one at another alias, in two envelopes or of another
  shape is not, its request answering `eio` once the server ends; the
  fuzz target drives the same exchange with random messages; seeded: a
  client that takes replies only bare, and one that takes another
  alias's reply out of an envelope, which both catch.
* `erx_fs`: hostile-client tests (bounds, fid floods, lock floods, walks
  with `..` at the root and `/` inside names, writes through read-only
  grants, slow clients, clients that die, client processes that end with fids and with
  fid-making requests in flight, owners named on another's behalf that
  have already ended, clients that never read their
  replies, replies sent to another domain's alias, frames in a third
  domain's envelope and bare frames at a grant for another domain, each
  dropped and counted, a pipelined `lopen`
  after a walk that stopped at a link, 100,000 short-lived owners that
  each make and clunk one fid, after which the grant holds no monitor),
  and an exhaustive model of a
  grant's fid table under every request and every owner's end in
  every state up to depth 6;
  seeded: a grant that keeps a fid after a failed walk, which the model
  catches; a grant that, after an owner's `DOWN`, records a later fid
  made for that owner without monitoring it again, which the ended-owner
  case catches as a fid that stays; a grant that keeps an owner's monitor
  after its last fid, which the short-lived owners case catches; a grant
  that takes a frame out of any domain's envelope, and one for another
  domain that takes its own domain's bare frames, which the envelope
  cases catch. A tree
  whose callbacks answer with a next state appended, in the grant and in
  an owner, is answered `eio` at the client and the grant goes on
  serving; seeded: a grant that takes a directory's `make` answering
  `{ok, Node, Qid, State1}` for a file's, and one that crashes on an
  answer that is not an error, which that case catches. Each operation
  whose directory fid names a file or a link is answered `enotdir` and
  the tree records no call; seeded: a protocol table that leaves
  `renameat`'s new directory or `readdir`'s fid marked `node`, or marks
  `link`'s source in place of its directory, regenerated, which that
  case catches. A tree that
  answers root, walk or `lcreate` with a malformed qid is answered `eio`
  and the grant records no fid, opens nothing, starts no file process
  and clunks the handle the tree opened; a `remove` whose tree answers
  an error 9P2000.L does not carry is answered `eio` and still clunks
  its fid; and a listing whose tail is not a list is answered `eio` by
  the file process; seeded: a grant that keeps what an operation built
  when the reply check rejects its reply, one that undoes a remove's
  clunk then, one that leaves a rejected `lcreate`'s handle open, and a
  listing check that crashes on an improper tail, which those cases
  catch. The
  fid counter's property test, over a space a test hook shrinks to 256
  numbers, draws from many processes at once, keeps some fids alive past
  a wrap and ends others with their owners, and finds no number drawn
  again before every other number has been drawn, `NOFID` never drawn,
  and every new fid that meets a live one refused with `einval` and
  nothing shared; seeded: a counter that hands out the lowest number not
  in the grant's table, which the test catches.
* F4: a tiny request whose callback is slow, sent in a flood by one
  client, which delays that client's grant and no other, and spends no
  more than the server's grant; seeded: a grant that runs callbacks in its
  own process, which the second client's latency exposes.
* F5 and F6: every writing operation through an `ro` and an `rx` grant,
  each refused before its callback; running a file through an `ro` and an
  `rw` mount, which fails with `EACCES`; seeded: an operation removed from
  the table's writing marks, which the generated refusal test catches.
* Symbolic links: `symlink`, then a walk that meets the link in its
  middle, which stops there, and one that ends on it, whose fid the client
  reads; a link to a link, a relative and an absolute link, and a loop
  that fails with `eloop`; a walk, an `lopen` with truncation and a write
  sent together for a path through a link before its last name, which
  fail past the walk with `ebadf` and leave the link and its target
  unchanged; `ln -s`, `file:make_symlink/2` and OTP's suites that use
  them; seeded: a server that follows a link during a walk, which the
  link-above-the-root case catches.
* Locks: two programs of one session, and two domains, contending for read
  and write locks; a lock with `BLOCK` that waits at the server as a
  pending request, granted when the holder unlocks and ended by a flush;
  one without it, answered `blocked` at once; a lock released by the
  holder's clunk, by its grant's end, by its program closing another
  descriptor of the file, and by its program closing one of two
  descriptors that a `dup` made of one open; a lock that outlives an
  `fcntl(F_SETFL)` setting and clearing `O_APPEND` on its description, so
  another program's conflicting lock still fails; a program that ends
  while a sibling keeps the description its lock was taken through, after
  which a third program takes a conflicting lock at once; a `ClientId`
  naming another domain, which releases nothing; seeded: an owner keyed
  by `ClientId`, which the `ClientId` case catches; a handler that leaves
  a program's locks to the description's clunk, which the sibling case
  catches; a `liberx` that tells its handler only of an open's last
  reference, which the `dup` case catches; and a description that clunks
  the opened fid an `F_SETFL` replaces, which the `O_APPEND` case
  catches.
* Flush: a read of `/dev/tty` flushed before a line arrives, which gets
  no reply but the flush's, and one flushed as the line arrives, whose
  reply carries the line before the flush's answer;
  seeded: a server that answers the flush before the read it took a line
  for, which loses the line and fails the test.
* F1: a domain test that a mounted pid the domain was not introduced to
  reaches nothing. F2 and F3: a program given `/data/logs` whose requests
  try every path above it, through `..`, links and other programs' file
  numbers, reaching nothing of `/data` outside `logs`, and whose `ls ..`
  from `/data/logs` lists `logs` alone. F9: a program's sub-space holds
  only its channel, data area, pipe ends and mapped memory. Seeded: a
  handler that walks the raw path, and one that sends a `..` at the
  program's top to the server, which the `..` cases catch.
* The empty root: a program started with `/data/logs` alone, whose `ls /`
  lists `data`, whose `cd /data` works, whose `open` of `/etc/passwd`
  fails with `enoent`, and whose `mkdir /new` fails with `erofs` and
  `mkdir /data` with `eexist`, and one started with no mount at all, as
  `within -f inspect -- ps` starts it, whose every path but `/` fails with
  `enoent`.
* The data area: a program with one slot whose two threads read at once,
  one waiting for the other's slot; reads and writes of every size from 1
  byte to 64 KiB and across slot boundaries, compared with the file; a
  program that names a slot it does not have, refused with `EINVAL`.
* Shared offsets: two programs given one description write in turn, and
  the file holds both outputs in order; a forked child and its parent do
  the same; an `O_APPEND` description whose writes all land at the end
  while another domain appends, and whose offset after each write is
  just past its own bytes; seeded: a handler that takes the offset from a
  `getattr` after the write, which catches the other domain's append that
  a test hook in the server lands between the two.
* Identity: for each of the storage services and the FAT server, a file
  written, renamed, removed and created again under one name, and a server
  restarted between two `getattr`s, never shows one domain, tree, path and
  version for two different contents, checked against a model that
  records every content each of them named; one domain serving two trees
  whose files share a qid path, which a session's file table keeps apart;
  a test hook that starts the
  counter at 2^63 shows versions above 2^32 round-trip, and one at
  2^64 - 1 shows the server refusing a change with `eio`; seeded: a
  counter kept in the server's process, which the restart case catches,
  and a file table keyed without the tree, which the two-tree case
  catches.
* FAT and littlefs paths: a file a fid names keeps its path across a
  rename; a server whose table holds 65,536 entries refuses a walk to a
  file it does not hold with `enfile` and keeps every entry; seeded: a
  table that evicts its least recently met entry when full, which the
  full-table case catches.
* `attach`: inside the machine, an `attach` naming a tree other than the
  grant's fails with `enoent`; seeded: a grant that ignores `Aname`,
  which that case catches.
* A hostile server: replies whose read `Data` exceeds the request's
  `Count`, whose write `Count` exceeds the bytes sent, whose walk lists
  more qids than names and whose `readdir` entries exceed `Count` bytes,
  each failed with `eio` by `erx_file_remote`, by the host link's bridge
  and by the host-tree domain's bridge; a handler answering a program a
  count larger than it asked for, which `liberx` clamps; seeded: one
  operation's check removed from the generated table, which that
  operation's case catches.
* `lcreate`: a rename of the created name to another file between the
  `lcreate` and the walk that follows, after which the description keeps
  its opened fid alone, reads and writes it, and answers an
  `fcntl(F_SETFL, O_APPEND)` and an `mmap` with `ESTALE`; seeded: a
  handler that skips the qid comparison, whose `mmap` then maps the other
  file.
* Shared mappings (F7): the exhaustive model of one mapper, its object and
  its server under interleaved stores, descriptor reads and writes,
  truncations, extensions and write-backs up to depth 8, against a flat
  file; two programs of one session, one storing through a mapping and one
  reading through a descriptor, which sees the store at once; a forked
  child's stores seen by its parent; a mapping whose fill fails at its
  second read, followed by a mapping of the same range, which reads the
  range from the server again and shows the file's bytes; a descriptor
  write the server refuses and one it takes in part, after which a
  mapping shows the acknowledged prefix alone; a write that starts past
  the end, whose mapping shows zeros in the hole and the written bytes
  after it; seeded: a handler that relays a read of a mapped file to the
  server, which the model catches; a mapper that moves the filled extent
  before its reads complete, which the failed-fill case catches; one that
  copies a write into the object before the server answers, which the
  refused-write case catches; and one that zeroes up to the new size
  after an extending write, which the hole case catches.
* Write-back (F8): each write-back point followed by a read from
  another domain, which sees the stores; a program killed while it holds
  the only writable mapping, whose stores the other domain then sees; a
  server that fails writes, after which `msync`, `close` and the last
  `munmap` return `EIO` and a program's end leaves the log line and the
  count; a write-back after a truncation by another domain, which writes
  nothing past the new size; another domain's write into a page no
  program stored to, which survives the session's write-back; a store
  made while a write-back runs, which the next one carries; a file mapped,
  written through a descriptor and truncated but never stored to through
  a mapping, whose write-backs send the server no write; seeded: a
  mapper that deletes its object before its last write-back, which the
  killed-program case catches, an `erx_mem_dirty` that clears a mark
  it did not report, which the racing store catches, and a mapper that
  fills the object through a mapping of its own, which the never-stored
  case catches.
* Two sessions: each maps one file shared and stores to different
  pages; after both write back and map afresh, each sees both stores, and
  a page both stored to holds the later write-back's.
* Mapping resources: a mapping beyond the session's budget fails with
  `ENOMEM` and leaves nothing; repeated failing maps leave no mapper; a
  one-page mapping at a high offset charges the object up to its end,
  which gate GQ measures.
* `prim_file` over a server: OTP's `file_SUITE` and `filelib_SUITE` run
  with their working directory on an `erx_fs` server backed by a RAM
  tree, compared case by case with the same suites on a local mount; every
  difference is one listed under [Compatibility](#compatibility-and-migration).
  Hosted, `tools/erx oracle hosted` compares them with stock OTP 29.1.2 on
  the development host; its list of known differences
  (`test/oracle/hosted_known_differences/`) holds a case of `.`, `..`
  or links only where macOS answers otherwise than FreeBSD, its row
  naming FreeBSD's answer. The cases of the first bullet under
  [Compatibility](#compatibility-and-migration) are such cases, which no
  case of either suite reaches; [/tmp's oracle
  cases](design-tmp.md#verification) compare them. A listed case that
  agrees with stock fails the comparison, so `filelib_SUITE`'s `wildcard_one` and `wildcard_two`,
  which expect `..` after a link to name the target's parent, pass
  without a row. Seeded: a resolver that takes `..` before following the
  link ahead of it, which both cases catch.
* `liberx`'s file client: toybox's own tests for its file applets
  ([design-programs.md](design-programs.md)), and musl's `libc-test` file
  cases, each program served by a handler over an `erx_fs` server.

## Performance

A request from an Erlang client to a server costs one connection round
trip, 3 to 10 us under HVF (an estimate,
[design.md](design.md#performance)), plus three copies of its payload
(into the sender's lane, out of the lane by the receiver's funnel, and by
the decoder into the caller's binary, a copy that lazy decoding of a large
binary avoids). A program's read adds one round trip on its channel, a
ring of the same kind, and two copies, by the handler into the data area
and by `liberx` into the caller's buffer: five copies at most. At 64 KiB
per read and an estimated 10 GB/s for each copy, a sequential read in a
program moves about 1.3 GB/s at best (an estimate of 33 us of copying and
15 us of round trips per request), and in an Erlang process about
1.7 GB/s. A walk of up to 16 names is one request, and a walk, an `lopen`
and a first read sent together are one round trip. A local mount costs no
frame. A spawn costs one walk per namespace entry, sent together, one
round trip per server. `tools/erx bench fs` measures the round trip,
sequential reads of 1 GiB from an Erlang process and from a program, and
a `find` over 10,000 files on QEMU under HVF, against the same operations
on a local mount, as the baseline.

Resolving a path costs one walk for each run of names the resolver asks
for, and the last run is sent with the operation, so a path without `.`,
`..` or links costs what walking its names costs, one round trip with the
operation. A `.` or `..` after names already in the place, as `./x`,
`../x` and every relative path's first names are, costs nothing; one
after a name the path has not yet walked, as in `a/b/../c`, costs the
walk of the run before it on its own, one round trip more. A link costs
the walk that stops at it and the walk and `readlink` that read it, two
round trips. The resolver itself runs in the calling process, over the
table it reads in place from the persistent term: list work over at most
256 names and 64 entries for each run it places, which a round trip to a
server dwarfs. On the release file system, where no round trip hides it,
a path without `.` or `..` costs one NIF call, the operation's own, as
stock's does, and a run before a `.` or `..` one `release_walk_nif` call
more. A mount, bind or unmount puts a new term, which costs a scan of
every process of the runtime for references to the old one, as every
replacement of a persistent term that is not an immediate value does; a
`set_cwd` costs one NIF call and no scan, since the working directory
is not a persistent term. These
costs are on the [watch list](todo-performance.md) until `tools/erx
bench fs` times them.

A shared mapping costs, before it is installed, a read of the range it
adds to the filled extent, at the speed of a program's sequential read
above;
and each write-back costs one `erx_mem_dirty` and a write of each page
stored to since the last. A fault
on a shared object costs what a fault on any shared object costs, with no
other domain involved. A read or a write by the session's programs of a
mapped file costs one message to the mapper more than one of an unmapped
file, and the mapper takes fills, descriptor writes and size changes of
one mapped file one at a time, so such a write waits for the server's
answer to the write before it and for a fill under way.
`tools/erx bench mmap` measures the fill, stores and the four write-backs
on QEMU under HVF for files of 64 KiB to 1 GiB, against reads and writes
of the same bytes through a descriptor as the baseline, at
[gate GQ](plan.md#track-q-the-second-tier).

## Portability

Nothing in this design is platform-specific: the protocol rides on
frames, the codec on bytes, and the resolver is Erlang, the same module
on the target and on the host.

## Dependencies

No new dependencies: the resolver, the frame profile, `erx_9p` and
`erx_fs` are erXos's own, over connections, the funnel, programs as ports
and `prim_file`, which exist. 9P2000.L is a published protocol, not a
library; its oracles, QEMU's virtio-9p server and Linux's 9P client in the
oracle guest, are already dependencies of the harness.

## Alternatives considered

**One machine-wide tree with permission bits.** Every domain would see the
same tree, and owner and mode bits would decide access, as in UNIX. It
loses because authority would then live in a second system beside exports
and facets, and every service would have to check it; a namespace built
from grants needs no check beyond the funnel's.

**A file protocol of erXos's own, shaped like 9P.** Requests would add
what 9P2000.L lacks: grants derived at the server for each program,
grants passing an open file with its offset, readiness reports for
terminals, server-side offsets and a registration for shared mappings. It
loses: each addition needs its own grammar, its own client in every tool
and a translation wherever the host and the network speak 9P2000.L, while
what it buys is already there. A program holds no fid, so the handler that
is its file server narrows its namespace by walking fids; offsets shared
by programs live in the session that holds every program sharing them;
a terminal read blocks and a flush ends it, as 9P's own servers do; and a
shared mapping is the session's.

**9P2000.L's bytes on connections too.** Every server would decode
9P2000.L's binary messages. It loses because frames already carry Erlang
terms through one validated grammar, and a binary decoder at every server
would add a parser without adding expressiveness; the codec runs only at
the edges.

**Grants derived at the server for each program.** The handler would ask
the server for a grant rooted at each of a program's mounts, so the
server would hold the program's root. It needs an operation 9P2000.L does
not have, and protects against nothing: a program holds no fid and
reaches a server only through its handler, which walks only from the
program's own fids, so the narrowing is enforced by the program's file
server, and a compromised session holds the session's grants anyway.

**A program that speaks the file protocol itself.** Each program would
hold the pids of its grants and send frames to the servers, as an Erlang
domain does. It loses: a program would then be a domain, with a lane to
every server, a place in every server's export table and an identity
servers must check, and a compromised program could speak to any server
it held a grant on; its session, which holds the grants anyway, relays
small terms at the cost of one ring round trip per request.

**Per-open buffers the server maps for the program.** The server would
create a memory object for each open file and the session would map it
into the program, so the bytes never touch the session. It loses: a
kernel object, a capability pass and a mapping per open, and a server
that must write into memory it did not allocate. The data area is one
object per program, from the session's budget, and keeps every server a
plain process speaking frames.

**Resolving `.` and `..` on the text.** The resolver would normalise a
path before any walk, one pure function and no round trip. It loses on
behaviour and on what a maintainer must hold. `..` after a link names the
parent of the link's own directory, not of its target, which OTP's
`filelib` wildcard cases see; `file/.`, `file/` and `missing/../x`
resolve where FreeBSD and macOS refuse them. And every operation that
removes, renames or makes a name must keep the path as written beside the
normalised one, to answer for a last `.` or `..` that normalising erased:
a second view of each path, helpers that find its last name, a table of
answers per operation, and a second resolution of the path without its
last name. The place makes each of those the ordinary path through the
resolver.

**The resolver in C17 behind a NIF.** A pure C17 step machine in
`liberx` would take one step of a resolution at a time, under a
read-write lock on a table held in C by `prim_file`'s NIF, and hand its
state back between steps as a cursor of the place, the names still to
read and the counts. It loses on what a maintainer must hold. The
executor is Erlang whatever the resolver is, since a NIF cannot wait
for a server's reply (**`prim_file` reaching servers from its NIF**,
below), so every step
would cross from Erlang into C and back: the cursor would be input that
any process of the runtime could forge, needing checks of its own, a
decoder from Erlang terms and a fuzz target for both; each step would
copy its entry out under the lock; a walk in flight would need a count
of its own, so that its reply is read against the walk that was sent
when a mount or unmount came between two steps; a rename's two paths
would need placing again together under one hold of the lock; and a
chokepoint check would have to keep every other writer off the result
the machine fills in. In Erlang the state between two names is a
closure of the resolver's own, the table is a term one resolution holds
from start to end, and a rename's two paths are two entries of one
table, so each of those goes rather than being checked. Speed does not
favour C: a resolution's own work is list operations over a table of at
most 64 entries beside walks that cost a round trip each, and on the
release file system, where nothing hides it, a path without `.` or `..`
costs the one NIF call it costs in C. Nor does reuse: erXos's kernel
never sees a path, and the session's handlers, which resolve programs'
paths, are Erlang too.

**Walking `..` at the server.** The client would hold a fid on the place
and send `..` in its walks, which the grant answers from the fid's
record of the directories it was walked through, and step out of an entry
only at its top. It would save the walk of its own that a `..` after a
new name costs, and would follow a directory through a rename as far as
that record does: back to the directory the fid came through, still not
FreeBSD's current parent. It loses: whether a walk stays within a bind's
root or a narrowed program's mount would rest on the client's count of
how deep it stands below the entry's top, where no walk now carries `..`
at all (F2, F3); and the place would hold a fid whose owner must end it.

**A walk plan from the namespace.** The namespace would turn a path into
its whole list of walks at once. It loses: only the walks tell which
names are links and which are directories, so the plan would be redrawn
after every link and every `..` after a new name, which is what stepping
does, by one rule.

**Servers that follow links.** A server would resolve a link during a
walk, inside the grant's root. It loses: it needs a second resolver at
every server, a link to another mount cannot work, and the reader's own
namespace is the only one that says what a path means to the reader.

**`prim_file` reaching servers from its NIF.** The NIF would send the
request and wait for the reply itself. It loses because a NIF cannot wait
for a message without blocking a scheduler, and a dirty scheduler would
hold a thread per waiting call; doing the remote part in the calling
process, through OTP's file descriptor module, costs nothing.

**Per-process namespaces.** Each Erlang process would have its own table,
as each Plan 9 process does. It loses because authority in erXos is per
domain: processes of one domain hold the same exports, so a per-process
table would only hide paths, never protect them. A program's namespace is
per program because a program is confined by its handler, not by a table
it could read.

**One object for each file, at its server, paged through the kernel.**
The server would keep one writable object for each file that programs map
shared, every mapping in every session would map it, and the server's own
reads and writes would go through it. It buys coherence across sessions,
and between every mapping and every read and write anywhere. It costs a
kernel pager, a fault that waits on another domain with a deadline, so a
server can stall a program for that long; a claim gate and keys to hand
the object's capability to the session; a fault worker, a cache budget
and mapping quotas at every server; and a version that means "mapped for
writing". The session's object needs none of these, and the coherence it
gives up is between sessions, which meet page by page at each write-back,
as clients of a network file system do.

**Refusing a second session's mapping.** A session would hold a mark at
the server while it maps a file, and another session's shared mapping
would be refused. It loses: the server must keep state that no 9P2000.L
operation names, so the protocol would stop being 9P2000.L, and a domain
that holds the mark could keep every session from mapping the file.

**An object for each program.** Each program would map an object of its
own, filled by its handler. It loses: two programs of one session that
share a file, a parent and its forked child above all, would not see each
other's stores, which POSIX promises within the processes that map a file
shared.

**Write-back of the whole range.** The mapper would write back every
page the object covers, needing no report from the kernel. It loses: a
write another domain made anywhere in the range would be overwritten at
every write-back, and the cost of an `msync` would follow the mapping's
size, not what changed.

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Remote files are too slow for tools that read many small files | medium | slow `find` and `grep -r` on `/data` | walks of up to 16 names in one request; walk, open and read in one round trip; `tools/erx bench fs`; a read-ahead in the handler if the numbers ask for it |
| The handler's relay makes a program's file I/O slower than an Erlang process's | medium | toybox's applets read at the speed of the channel round trip | the data area's 64 KiB slots; walk, open and read in one round trip; `tools/erx bench fs` from a program; more slots per program where the session's policy allows |
| A program depends on `..` following a directory that a concurrent rename moves | low | the resolution passes the old path, reaching what it names then or failing | FreeBSD resolves no path atomically either; the difference is documented, and only a racing rename shows it |
| Servers in user domains hold clients' state too long | low | a user domain's memory grows | the per-grant bounds; the client's death clunks everything |
| One owner per open file serializes the file's reads and writes | medium | readers of one large file wait for each other | reads of 64 KiB extents in helper processes; `tools/erx bench fs` |
| A large shared mapping costs a read of its whole range before it is installed | medium | slow `mmap` of large files | gate GQ measures the fill and the write-backs; the corpus's users map small files |
| Two sessions, or a session and another domain, write one page of a mapped file | low | the later write-back's page wins, as between clients of a network file system | write-back of stored pages alone; record locks for programs that coordinate; a documented difference with a test |
| A request to a hung server waits until the caller gives up | low | a process or program waits on a live server that never answers | the caller's interrupt flushes it; the server's end gives `eio`; the inspector shows requests in flight |

Open question for the user:

1. **Growing a shared object.** A mapping that reaches past the session's
   object, as SQLite's index of its write-ahead log does when it maps its
   `-shm` file region by region, needs the object to grow without moving
   the pages other programs map. The design uses `erx_mem_grow` on a
   shared object, reserved and charged from the object's budget as it
   grows, which the kernel keeps for that
   ([design-kernel.md](design-kernel.md#virtual-memory)). The alternative
   is to refuse such a mapping with `ENOMEM` while the object lives.
   Recommendation: keep `erx_mem_grow` for shared objects; refusing breaks
   SQLite's write-ahead log.

## References

* R. Pike, D. Presotto, K. Thompson, H. Trickey, P. Winterbottom, "The Use
  of Name Spaces in Plan 9", Operating Systems Review 27(2), 1993.
* Plan 9 from Bell Labs, Fourth Edition, manual section 5 (the 9P2000
  protocol: `version`, which resets a session; `walk`, whose new fid
  exists only when every name was walked, `..` at the root, and
  `MAXWELEM` of 16 names per walk; `flush`, whose answer follows the
  flushed request's), https://9p.io/sys/man/5/INDEX.html.
* 9P2000.L, as diod's `protocol.md` describes it (the messages added to
  9P2000, their fields, `getattr`'s `data_version` reserved for future
  use, and `lock`'s statuses), https://github.com/chaos/diod; Linux's
  `Documentation/filesystems/9p.rst`, the `v9fs` client; QEMU's virtio-9p
  documentation, the server the harness attaches.
* Inferno's Styx and `sys-bind(2)`, Vita Nuova, Inferno Fourth Edition.
* Fuchsia, "Component namespaces", https://fuchsia.dev/fuchsia-src/concepts/process/namespaces.
* The Open Group Base Specifications Issue 8 (IEEE Std 1003.1-2024),
  `mmap` (the zeroed tail of the last page, never written out; `SIGBUS`
  for whole pages past the end), `msync`, `close` (`EIO`), `fcntl`
  (record locks, released at any close of the file) and XSH 2.9.7 (reads
  and writes of regular files atomic with respect to each other),
  https://pubs.opengroup.org/onlinepubs/9799919799/.
* FreeBSD's kernel, `main` at commit `b22b999afc2d` (2026-11-06),
  https://cgit.freebsd.org/src/: `sys/kern/vfs_lookup.c` (`namei`, which
  follows at most `MAXSYMLINKS`, 32, links, of `sys/sys/param.h`,
  answers `ENOENT` for an empty link and restarts an absolute link at the
  process's root; `vfs_lookup`, which reads one name at a time, answers
  `EISDIR` for the degenerate name `/` of anything but `LOOKUP`, keeps
  `..` at the root, crosses back through a mount's covered directory for
  `..` at a mounted root, refuses a last `.` or `..` of `DELETE` or
  `RENAME` with `EINVAL` as it reads the name, and under
  `TRAILINGSLASH` follows a last link, answers `ENOTDIR` for a last name
  that is not a directory and `ENOENT` for a new one that will not be a
  directory), `sys/kern/vfs_cache.c` (the lockless name-cache lookup,
  which checks the name before a `.` is a directory and, read but not
  run, answers a last `..` of `DELETE` or `RENAME` by its cache), `sys/kern/vfs_syscalls.c`
  (`kern_frmdirat`'s `EBUSY` for a mounted root; `kern_funlinkat`'s
  `EPERM` for a directory and for every `EINVAL` of `namei`;
  `kern_linkat_vp`'s `EPERM` for a directory before the new name's
  lookup; `kern_ftruncate`'s `EINVAL` through a descriptor not opened
  for writing; `kern_renameat`'s
  `EBUSY` for a mounted root as source or destination, its `EINVAL` for
  a directory renamed onto `/`, and its look-up of the source with
  `DELETE` and the destination with `RENAME`; `kern_linkat`, which
  `link` calls with `AT_SYMLINK_FOLLOW`), and `sys/kern/vfs_vnops.c`
  (`vn_open_cred`'s `EEXIST` and `EISDIR` for an existing directory
  opened to create, and `vn_open_vnode`'s `EMLINK` for `O_NOFOLLOW` on a
  link).
* FreeBSD's manual pages at the same commit: rmdir(2) (2020-03-30),
  unlink(2) (2021-02-23), rename(2) (2024-08-25) and open(2)
  (2025-05-17).
* Erlang/OTP 29.1.2: `lib/kernel/src/file.erl` (the file descriptor
  record and its module dispatch; `check_and_call/2`, which sends path
  operations to `file_server_2`, read 2026-10-30),
  `erts/preloaded/src/prim_file.erl`.
