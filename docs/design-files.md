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

Decisions every reader of this document needs, each owned by the
section linked:

* **A namespace is per domain and private**: mount points to local
  providers (the release slice and EROFS images, read-only) and to
  grants at file servers, named by pid; binding, mounting and unmounting
  add no authority ([Namespaces](#namespaces), [Building, binding and
  mounting](#building-binding-and-mounting)).
* **Holding a path is holding a pid.** A request is a frame to a
  **grant**, a process of the server that serves one subtree with fixed
  rights to the one domain it was made for, and the server's funnel
  admits it only from that domain (F1, [Who a grant is
  for](#who-a-grant-is-for)).
* **The server roots every grant**, and no request reaches above the
  root (F2).
* **The file protocol is 9P2000.L, exactly**, with one deliberate
  difference inside the machine, a `version` that resets nothing, and
  one added reply field, `write`'s offset ([The file
  protocol](#the-file-protocol)); one codec, `erx_9p`, carries its bytes
  at the edges ([The codec](#the-codec)).
* **A program's file server is its session.** A program holds no grant,
  no fid and no namespace; its handler keeps its table, narrowed from its
  starter's, so a program cannot be a confused deputy and a server never
  sees a program (F9, [Narrowing for a
  program](#narrowing-for-a-program)).
* **Resolution is physical, as FreeBSD's `namei`**, done by the client
  over its own record of where it stands, so a server receives only plain
  names and never follows a link ([Resolving a path](#resolving-a-path)).
* **One resolver, one grammar, one codec, one server behaviour**:
  `erx_path` resolves every path in every runtime and handler; every
  request goes to a fresh alias, so no reply can be forged or reused; and
  every file server is an `erx_fs` callback module, so every grant is a
  process that can be inspected, traced and supervised
  ([Serving](#serving-the-erx_fs-behaviour)).
* **Files are a view.** Erlang messages stay each service's primary API;
  a file tree is how people and tools reach the same state.
* **A session serves its programs' shared mappings**, coherent within the
  session and written back to the server as ordinary writes ([Shared
  mappings](#shared-mappings)).
* **Names are UTF-8 bytes, never normalised**, at most 255 bytes,
  without NUL or `/` ([Text in file names](#text-in-file-names)).

## Context

A runtime serves two read-only local file systems through `prim_file`
(its release slice, and EROFS images that files of its grants hold),
runs its own RAM file server for
`/tmp` ([design-tmp.md](design-tmp.md)), and reaches storage as a
service like any other ([design-runtime.md](design-runtime.md#files)).
Three needs go beyond that: native programs, toybox's applets among them,
need POSIX files over storage and over a session's own files
([design-programs.md](design-programs.md)); the live machine's state
should be readable with `cat`, `ls` and `grep`
([design-live.md](design-live.md#the-proc-tree)); and it is required that
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
   Erlang, as the storage services, the media domain's volumes, `/proc`,
   `/dev` and a session's export do.
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
10. A tree serves stream files, whose reads wait for bytes another party
    supplies, as the Bluetooth controller's line `data`
    ([design-bluetooth.md](design-bluetooth.md#the-controllers-line)) and
    a window's `kbd` and `mouse`
    ([design-display.md](design-display.md#the-window-tree)) do: a read
    that waits never holds up a write, a clunk or a flush of the same
    file, through the same grant or another.

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
* A union of several servers at one mount point. The session's export
  over a grant at `/etc` and `/dev`, where the export's names are fixed,
  is the one join ([Narrowing for a program](#narrowing-for-a-program)).

## Overview

```text
  domain D (ERTS)                                      system domain
  +------------------------------------+  connection   +--------------------------+
  | file:read_file("/data/a")          |  (two lanes)  | D's grant on /data       |
  |   prim_file -> erx_path            |-------------->|  (erx_facet, read-write) |---> storage
  |     mount /data -> grant G, "a"    |   9P2000.L    |                          |     service
  |   erx_file_remote: walk, lopen,    |   terms to    | D's inspect facet        |     (Erlang,
  |     read, clunk, each to an alias  |<--------------|  (erx_facet, D's scope)  |      erx_fs)
  |                                    |  replies to   |   -> erx_inspector       |
  | local mounts: / in the NIF, EROFS  |  the alias    +--------------------------+
  |   in erx_erofs; /tmp a grant of D's|
  |   own erx_ramfs server (design-tmp)|
  |   /proc: D's own erx_procfs, which |
  |   queries through D's inspect facet|
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
4. For a grant, the client walks the names from the grant's root, a walk
   whose source fid is `NOFID`, into a new fid, in walks of at most 16
   names, sending the operation with the last
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

**One way to a file.** Every file a domain reads, it reaches by that
journey: a path, an entry of its namespace, a grant at the file's server,
9P2000.L. An EROFS mount is no second way: its image is a file reached
the same way, which the domain's own runtime reads through one fid and
checks block by block ([Building, binding and
mounting](#building-binding-and-mounting)). The one exception is a
domain's own release slice, at `/`, which its runtime reads from memory
the kernel mapped before any grant exists, so that the domain can start;
no other domain can be granted it. So **nothing a second domain must
read lies in a release**: a package, a release that a domain reads after
it has started, and every file another domain's sessions need lie in a
file system that a server serves and grants, such as the `system` tree
of each slot's system partition
([design-storage.md](design-storage.md#the-system-tree)).

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **F1.** A path never reaches a file server the domain does not hold | a request is a frame on the lane from the client's domain to the server's, addressed to a grant pid; the server's funnel admits a frame only to a pid its runtime exported to the domain that lane belongs to, with `send` ([design-domains.md](design-domains.md#invariants) D3); a grant's pid reaches a domain only through the system domain's introduction of the two; a namespace entry stores only a pid | a request path that names servers by anything but a pid; a server that acts on a pid named inside a request; a runtime that exported a grant to a domain the server did not make it for | a domain test mounts a pid its domain was never introduced to and finds every request fails with `eio`; the funnel's export tests |
| **F2.** No request reaches above its grant's root | a grant's root is fixed at the server when the grant is made; a walk of `..` at the root stays at the root, as 9P's walk(5) specifies and 9P2000.L keeps, and the grammar refuses a name holding `/` or NUL; the server follows no link during a walk or an open, so a link's text is resolved by the client through its own namespace; erXos's clients send neither `.` nor `..`, since both act on the client's place (F11) and every walk `erx_path` asks for carries only plain names, and the client's one request function refuses a walk that names `.`, `..` or an empty name | a server that accepts `/` inside a name, walks above its root on `..`, follows a link during a walk or an open, or roots a grant from anything the client sends after it is made | the resolver's fuzz target and properties; the grammar's refusals; an `erx_fs` test that walks `..` from the root and from below it, and whose links point above the root, at other mounts and in loops |
| **F3.** Rearranging a namespace or narrowing it for a program never adds authority | `bind` copies an entry that exists, narrowed to a subtree; `unmount` removes one; `mount` takes a pid, which by F1 reaches only what the domain holds; a handler gives a program only entries of its starter's table, each on the provider of the starter's entry, rooted at or below that entry's root, with rights no wider than the starter's there, and walks for it only names the resolver produced over that table; no program's resolution reaches a facet that the registry holds as one of the `windows` interface, an interface the domain service sets and no server's reply does, read at every resolution, so no installation, replacement or name lets one through, and every description a program holds was opened through a program's resolution, so none lies on one; the one addition, for a program with a window, one its starter asked for or one its handler opened at its first open of `/dev/draw`, is a `/dev` tree of the session's own that serves that window's files through the session's own grant of the display the starter names, less the window's `ctl`, which the starter could open itself, in place of the export's `/dev`, which every program reaches, and of any entry at exactly `/dev`, whose rights cap it ([A program's window](#a-programs-window)) | an operation that creates a pid or a fid beyond its source; a handler that walks `..` for a program, records wider rights than its starter's, resolves for a program a facet of the `windows` interface, decides that from a tree's name or once at the program's start, or admits into a program's open table a description that no program's table opened | property tests over sequences of operations: the set of pids in the table only shrinks or gains pids the domain already held; a property test over chains of spawns that every program's mounts lie within, and carry rights within, its starter's, and that no program's resolution reaches a facet of the `windows` interface, over installations, replacements and names that arrive after the program starts |
| **F4.** A client spends a server's CPU and memory only within the server's admission (on Fiasco: [FD31](design-fiasco.md#downsides-against-erxoss-kernel)) | the protocol checks fid, request, payload and lock bounds before any callback; a grant is one process with a `max_heap_size` that counts its binaries, so what it holds for its client is bounded by its fid pool times the server's per-fid bound; the server runs on its own group's grant and its grant processes schedule among themselves as Erlang processes do, so a flooding client fills its own lane and waits in its own runtime ([design-domains.md](design-domains.md#connections), [design-scheduler.md](design-scheduler.md#service-work)); a request that waits for an event, a blocking lock or a stream's read or write, is a waiting request held by the process that owns what it waits for, the tree's lock table for a lock and the tree's keeper for a stream ([Serving](#serving-the-erx_fs-behaviour), "Waiting requests"), within the client's requests in flight, and nothing in the server blocks on it | a callback before admission; a grant that holds unbounded state for one fid; a server thread that runs on a client's time; a request whose work grows with the client's input outside the grammar's bounds; a callback that waits for an event in the grant, which runs the client's other requests | hostile-client tests below: fid floods, lock floods, retained `/proc` results, a tiny expensive request, a client that never drains its replies, a window of waiting reads that is flushed and clunked |
| **F5.** A read-only grant never writes | a grant with rights `ro` or `rx` refuses with `erofs`, as part of decoding the request and so before any callback, every operation the protocol's table marks as writing: `lopen` for writing or with truncation, `lcreate` whatever its flags, since whether it creates a file only the server learns, `write`, `setattr`, `remove`, `unlinkat`, `rename`, `renameat`, `link`, `symlink`, `mknod`, `mkdir`, `xattrcreate`, and a write lock | an operation added to the table and not marked; a request that reaches the grant's dispatch by a path other than its decoding funnel | the refusal set is generated from the protocol's operation table, each operation marked as reading or writing; a test of every writing operation through a read-only grant |
| **F6.** No grant carries write and execute together, and a session's handler gives a program code from a file only through an `rx` entry of the program's, the file-level twin of K8 (on Fiasco: [FD8](design-fiasco.md#downsides-against-erxoss-kernel)). It protects a program from running a file that it or another program could rewrite, not a program from its session, which is the trusted supplier of its programs' code ([design-system.md](design-system.md#creating-a-domain), "Code objects for a session") | a grant's rights are one of `ro`, `rw` and `rx`, a type with no value for both; an `rx` grant writes nothing (F5); an entry's rights only lower the grant's beneath it, so the handler's image check, before the session's command server fills a code object, needs `rx` on the entry the path resolved through, which an entry has only over an `rx` grant beneath it: a facet's grant, whose rights a resolution lowers the entry to, a grant pid's, whose rights its mount lowers the entry to, or for an EROFS entry the grant its fid came through ([Building, binding and mounting](#building-binding-and-mounting), "Rights beneath an entry"; [design-programs.md](design-programs.md#file-objects)); a handler gives a program rights within its starter's; an EROFS mount's rights are `ro` or `rx`, and `rx` only through an `rx` grant, and no argument of the mount names a layout | a rights representation with separate write and execute bits; a resolution that keeps the rights a facet's mount asked, which runs a file through an `rx` entry on an `rw` grant; a grant pid's mount whose rights come from its options alone; a code object filled from a fid on an `ro` or `rw` grant; an EROFS mount whose rights come from its options or its source rather than its fid's grant | the grammar's rights type; a test that running a file through an `ro` and through an `rw` mount fails with `EACCES` and that an `rx` grant refuses every writing operation; a test that a session's `erx_ns:mount({facet, data}, "/x", [rx])` succeeds and that running a file the session wrote there fails with `EACCES`; a test that an `rx` mount of a file of `/apps`, reached through the `rw` `apps` grant, is refused with `eacces`, while `/app` mounts `rx` through the `rx` `packages` grant; a test that an `rx` mount of an `rw` grant pid makes an `ro` entry; seeded: a resolution that keeps the rights a facet's mount asked, which the `/x` test catches, a grant pid's mount that keeps the rights its options ask, which the grant pid test catches, and a mount that takes its rights from its options alone, which the `/apps` test catches |
| **F7.** A file's bytes, as one session's programs see them, live in one place per session (on Fiasco: [FD9](design-fiasco.md#downsides-against-erxoss-kernel)) | while any program of a session maps a file shared, the session's one object for the file holds them: every mapping of the file in the session maps that object, and the handlers send every read, write and size change of the file by the session's programs to the file's mapper, which serves them from the object; the session's file table holds at most one mapper per file, keyed by the server's domain, the tree and the qid path | a second object for one file in one session; a handler that relays such a read or write to the server past the mapper; a mapping installed past the filled extent; a write's bytes put in the object before the server acknowledged them | an exhaustive model of one mapper, its object and its server under interleaved stores, reads, writes the server takes whole, in part or not at all, extending writes, truncations, failed fills and write-backs up to depth 8, against a flat file; two programs of one session, one storing through a mapping and one reading through a descriptor |
| **F8.** Every store through a shared mapping reaches the file's server as an ordinary write, at a point POSIX names (on Fiasco: [FD9](design-fiasco.md#downsides-against-erxoss-kernel)) | the mapper writes back, with the protocol's `write`, every page the kernel reports as stored to since the last write-back (`erx_mem_dirty`), at `msync`, at every close of a mapping's open (a program's last `munmap` of the file, its `exec` and its end) and at the `close` that leaves the session's programs no open of the file, and deletes the object only after its last write-back; a write-back that fails is returned to the call that caused it, or logged at a program's end ([Shared mappings](#shared-mappings)) | an object deleted before its last write-back; a stored page the report leaves out; a program's end that the mapper does not see; a failed write-back reported nowhere | a test per write-back point, reading the file through another domain after it; a store made while a write-back runs, which the next write-back carries; a server that fails a write-back, whose `msync`, `munmap` and `close` return `EIO` and whose program's end leaves a log line |
| **F9.** A program reaches a file only through its handler | a program's sub-space holds its channel, its data area and the memory its session mapped, and nothing else: no grant pid, no fid, no lane to any server; its handler acts only on the program's own table and the files it opened ([design-programs.md](design-programs.md#invariants)) | a capability to a lane or a grant installed in a sub-space; a handler that resolves a program's path over any table but the program's | a sub-space test that enumerates a program's capabilities and finds only its channel and mapped memory; a hostile program that names another program's open numbers, every request failing with `EBADF` |
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
                  | {erofs, image()}       % an EROFS image that a file holds,
                                           % read through a fid of erx_ns's
                                           % process
                  | {grant, pid(), Tree :: name()}
                                           % a grant at a file server, by pid,
                                           % and its tree, which
                                           % came with the pid from the code
                                           % that started the grant
                  | {facet, atom()}        % a facet's grant, by the facet's
                                           % name: the grant the domain's
                                           % facet registry holds for it at
                                           % each resolution, with its tree
                  | {facets, svc}          % a directory of the registry's
                                           % svc facets, each name the root
                                           % of an app's tree (design-app-
                                           % trees.md), mounted at /svc; no
                                           % link under it is followed
                  | ended.                 % a grant that has ended: every
                                           % request answers eio, unsent

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
session's handler keeps one table for each program, in its own state, of
the same type, its entries on the providers of its starter's, so a
program's sub-space holds no namespace at all. The resolver reads only an
entry's `point` and `root`, and whether its provider is `{facets, svc}`,
under which it follows no link; the rest is its callers'. The table is a
term read in place from the persistent term by every resolution, so a
domain's file state costs one copy of it, a few KiB for a typical domain
and bounded by the limits above, and nothing on any server until it
walks; a resolution that still holds a table when it is replaced gets
its own copy at the global collection that follows, which counts
against that process's heap. A `root` other than `[]` comes only from
`bind` within the domain, whose authority is the grant it already holds,
or from a handler's narrowing for a program, whose authority is its
starter's entry, or from the `/dev` tree a handler makes for a program
with a window, a tree of the session's own. A grant entry's tree is named once, by the code
that starts the grant: `erx_fs:start_link/3,4`, through which every grant
starts, answers its pid with the tree its callback module's `root`
names, the numbering its files' qid paths come from, whatever the
grant's root or its service, and the tree travels
with the pid to every holder of the grant, through the facet registry
for a facet or in the handle of a grant the domain started itself
([Building, binding and mounting](#building-binding-and-mounting),
"The tree beneath an entry"). No mount names a tree and no request
carries one inside the machine, and a grant's tree is fixed when the
server makes it, so a client keys a file only by the tree its server
numbers it in ([Identity and version](#identity-and-version)). The
tree keys identities and decides no authority: what keeps a display
from programs is the interface of the facet beneath an entry
([Narrowing for a program](#narrowing-for-a-program)).

### The file protocol

The file protocol is 9P2000.L. Its messages, fields and semantics are
those of 9P2000.L, which extends 9P2000's version, attach, walk, read,
write, clunk, remove and flush with operations that carry Linux's file
semantics; erXos defines no operation of its own. Inside the machine it
departs from 9P2000.L in three places only. Two follow from one fact, that
a grant is a session already attached when the server makes it: `version`
resets nothing, and a `walk` whose source fid is `NOFID` starts at the
grant's root ([Version and attach](#version-and-attach)). The third is
that `write`'s reply also names the offset its bytes were written at
([Open files and offsets](#open-files-and-offsets)). Inside the machine each message is an
Erlang term whose fields are the message's fields in 9P2000.L's order,
decoded on both sides by the funnel's grammar and then by the protocol's own, the **frame profile** of
`abi/protocols/9p.txt`, so every field is checked once against the table below.
A request travels as `{erx_9p, Alias, Owner, Request}` to a grant and its
reply as `{erx_9p, Alias, Reply}` to `Alias`, which plays the part of 9P's
tag; `Owner` is the process that will hold any fid the request makes
([Fid owners](#fid-owners)), or, for a `mkdir`, that the tree may tie the directory to. A
reply is `ok` for a 9P2000.L reply that has no fields, `{ok, Field...}`
otherwise, and `{error, Posix}` for `Rlerror`: inside the machine an error
is always OTP's `file:posix()` atom that names the Linux error (`enoent`
for `ENOENT`), and only the codec at an edge turns it into Linux's number
and back ([Errors](#errors)).

| Operation | Request term | Reply term | erXos's servers |
| --- | --- | --- | --- |
| version | `{version, Msize, Version}` | `{ok, Msize, Version}` | answered with the smaller of the client's `Msize` and the server's, 65,560 inside the machine, never more than the client offered; a `Msize` below 4,096 is refused, as Linux and QEMU refuse it; a version other than `<<"9P2000.L">>` is answered `<<"unknown">>`; inside the machine it changes nothing ([Version and attach](#version-and-attach)) |
| auth | `{auth, Afid, Uname, Aname, NUname}` | `{error, enotsup}` | not served: a grant's identity is its lane's, so authentication is not required, and the answer is `Rlerror`, as diod answers when it requires none |
| attach | `{attach, Fid, Afid, Uname, Aname, NUname}` | `{ok, Qid}` | `Fid` then names the grant's root; `Afid` is `?NOFID`, since `auth` is not served; `Aname` names the grant's tree, and any other name fails with `enoent`; `Uname` and `NUname` are recorded and grant nothing; served for the host link's bridge, since erXos's clients inside the machine walk from `NOFID` instead ([Version and attach](#version-and-attach)) |
| walk | `{walk, Fid, NewFid, Names}` | `{ok, Qids}` | at most 16 names; `Fid` a fid of the grant's, or `?NOFID`, which starts the walk at the grant's root as if from a fid that `attach` had just made; `NewFid` never `?NOFID`; `Fid` not open, as walk(5) asks and erXos's servers enforce; `NewFid` not in use unless it equals `Fid`; a failure at the first name is an error reply; a walk that passes at least one name and then fails lists the qids it walked and leaves `NewFid` unused; `NewFid` names the result only when every name was walked; a walk from a symbolic link fails at the next name |
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
| fsync | `{fsync, Fid, Datasync}` | `ok` | once the server's medium holds the file's data, and on a directory its entries |
| lock | `{lock, Fid, Type, Flags, Start, Length, ProcId, ClientId}` | `{ok, Status}` | POSIX record locks ([Locks](#locks)) |
| getlock | `{getlock, Fid, Type, Start, Length, ProcId, ClientId}` | `{ok, Type, Start, Length, ProcId, ClientId}` | the same table |
| link | `{link, Dfid, Fid, Name}` | `ok` | where the format keeps hard links, `eperm` elsewhere |
| mkdir | `{mkdir, Dfid, Name, Mode, Gid}` | `{ok, Qid}` | |
| statfs | `{statfs, Fid}` | `{ok, Statfs}` | `Statfs` a map of 9P2000.L's fields, `type` to `namelen` |
| read | `{read, Fid, Offset, Count}` | `{ok, Data}` | `Count` at most 65,536 inside the machine ([Bytes](#how-a-request-names-its-bytes)) |
| write | `{write, Fid, Offset, Data}` | `{ok, Count, At}` | `Data` at most 65,536 bytes inside the machine; 9P2000.L's count field is `Data`'s size; `At` the offset the bytes were written at, the file's end for an append fid, which 9P2000.L's `Rwrite` does not carry: the codec drops it at an edge and reads an `Rwrite` from outside as `At` = `unknown` ([Open files and offsets](#open-files-and-offsets)) |
| clunk | `{clunk, Fid}` | `ok` | releases the fid's locks; for an opened file, the tree's answer, an errno when the tree could not complete what the close commits, as `close(2)` may answer `EIO`; the fid ends whatever the answer |
| remove | `{remove, Fid}` | `ok` | `Fid` is clunked whatever the outcome |
| flush | `{flush, OldTag}` | `ok` | `OldTag` the alias of a request; answered `ok` for a completed or unknown request too ([Flush](#flush)) |

A `Qid` is `{Type, Version, Path}`, 9P2000.L's eight-bit type, 32-bit
version and 64-bit path. Fids, modes, flags and masks are the integers
9P2000.L gives them, so the codec at an edge moves each field without
translating it, but for the error numbers. A request on a fid the grant
does not hold fails with `ebadf`. In the frame profile every fid field
has the kind `fid`, which excludes `NOFID`, and states what its fid
names: `directory`, `node` or `new`, or, for a walk's `Fid` alone,
`start`, a fid that may name any node or be `NOFID`, the grant's root.
`start` is the one role whose field also admits `NOFID`, so `NOFID`
anywhere but a walk's source, a walk's `NewFid` included, fails the
profile with `einval`, and the field stays a fid of the table: the
generated codec's `fids/1` lists it as `{start, Fid}`, `NOFID` included,
and `map_fids/2` maps it, so a bridge renames a walk's source from the
table as it renames every other fid and decides there what `NOFID`
becomes ([Version and attach](#version-and-attach)); `directory_fids/1`
does not list it. A field of a plain integer kind, as `attach`'s `Afid`
is, is no fid of the table and no bridge maps it. 9P2000.L's wire constants, its message
type numbers, `NOTAG`, `NOFID`, `MAXWELEM` and `getattr`'s mask bits,
live in `abi/protocols/9p.txt` with the operation table, and every client,
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
clunk the fids of the many processes that share the grant.

For the same reason a grant is attached from the moment it is made, so
inside the machine a `walk` whose source fid is `NOFID` starts at the
grant's root, the node its callback module's `root` answers, which the
server fixed when it made the grant and where an `attach` would start.
The walk answers and makes `NewFid` exactly as a walk from a fid on the
root would, and leaves nothing else behind, since `NOFID` names no fid
the grant holds: there is no root fid to clunk. `NewFid` is never
`NOFID`, so a walk from the root always makes a new fid and never walks
one in place. A walk of no names from `NOFID` makes a fid on the root
itself. erXos's
own clients never send `attach` inside the machine: each operation
walks from `NOFID` into a new fid it owns, acts on that fid and clunks
it ([Erlang clients](#erlang-clients-prim_file-and-erx_file_remote)),
which spares every operation the `attach` and the root fid's `clunk`
that the server would otherwise answer for it. `version`, the walk from
`NOFID` and `write`'s `At` are the three deliberate differences from
9P2000.L inside the machine; every other operation has its full meaning.

**The root is admitted when the grant is made.** `erx_fs:start_link/3,4`
calls the tree's `root` callback once, before the grant takes any
request, and admits its answer by one check: the tree a plain name of
1 to 255 bytes, and the qid one of the grammar's qid kind whose type
is a directory. An answer that fails the check fails the start, so no
grant exists whose root is unchecked. The grant then fixes, for its
life, the root's node, the tree's name, which the start answers with
the pid, and the root's identity, its qid's type and path, which a
directory keeps while its tree lives. A walk from `NOFID` and an
`attach` both start at that node, and the fid they make records the
admitted qid, so a walk of no names from `NOFID`, whose reply lists no
qid, records only what the start checked. The start does not fix the
root's version: an `attach`, which only an edge's bridge sends, asks
`root` afresh for the qid its reply carries and answers `eio`, making
no fid, unless that answer names the fixed tree, type and path, its
version alone free; and a client takes a file's version only from
`getattr`, which asks the tree each time, never from a qid's `Version`
([Identity and version](#identity-and-version)).

A tree whose nodes are paths, as the storage volume's are, roots a
grant at the path its start fixed, so the fixed root holds only while
that directory stays where it is, and a tree that cannot answer its
root, a directory the volume lacks or an owner that has ended, fails
the grant's start rather than fixing a made-up identity. A rename or
removal of a grant's root directory through another grant of the tree
fails safe and is not repaired: the grant keeps its root path, so it
never reaches anything outside the subtree it was granted; its
requests fail with the errors the tree answers for a path it lacks,
and an `attach` answers `eio`, until the grant is restarted. A
directory made later at the same path is served as the root, under
the same authority, though a walk of no names from `NOFID` still
records the identity the start fixed.

At an edge `NOFID` keeps 9P2000.L's meaning and names no fid. A
bridge's fid tables never hold it, and a bridge renames a walk's source
through the codec's `fids/1` and `map_fids/2` as it renames every fid
(`start` in [The file protocol](#the-file-protocol)): a walk from
`NOFID` that reaches the host link's bridge from the host finds no fid
of the bridge's under it and fails with `ebadf`, while an ordinary walk
from a fid the host attached is renamed and relayed; the
host-tree bridge, which serves the host's tree to erXos's clients, maps
an erXos client's walk from `NOFID` to the root fid it attached on
QEMU's server, so no server outside the machine receives `NOFID` as a
walk's source
([design-live.md](design-live.md#files-between-the-host-and-the-machine)).

A **tree** is one numbering of a server's files: the files whose qid
paths one table of the server draws, whatever subtree a grant of them is
rooted at and whatever service serves it. One domain may serve several
trees, such as a partition's volume, an image or `/proc`; every grant
reaches files of exactly one of them, fixed when the server makes it;
and two grants of one server domain name one tree exactly when their
files' paths come from one numbering, so one file has one identity
through every grant that reaches it
([Identity and version](#identity-and-version)). The storage domain's
`data`, `packages` and `home` services are grants of one tree, its
littlefs volume's, rooted at the volume's top, at `/packages` or below,
and at one user's home ([Building, binding and
mounting](#building-binding-and-mounting), "The tree beneath an
entry"). `attach`'s `Aname` names the tree, and a grant answers an
`attach` as 9P2000.L says, with a fid of its own on the grant's root
each time, and only for the name of its tree; any other name fails
with `enoent`. Since several grants may name one tree, a tree's name
selects no grant: at an edge the host's `Aname` names a mount point at
the top of the bridge's domain's namespace, among those the bridge
lists, `data` the entry at `/data`, and the host link's bridge relays
the host's `attach` to the grant of that entry, a whole grant whose
`root` is `[]`, with that grant's own tree as `Aname`
([design-live.md](design-live.md#files-between-the-host-and-the-machine)).

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
and itself as the owner of a fid it walks for one of its program's path
operations, which the operation clunks, since a program's table holds no
fid ([Narrowing for a program](#narrowing-for-a-program)); and a 9P bridge owns every fid it holds for its edge. An `Owner` that is
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
path to a second file while its domain lives, and names one tree for
every grant whose files' paths it draws from one table, so a file has
one identity through every grant that reaches it, whatever each
grant's root; how each format draws them
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
`enametoolong`, `enotsup`, `eloop`, `enxio`, `edquot`, `exdev`, `enomem`,
`eagain`, `enodata` for a missing extended attribute, `erange` for a
buffer too small for one, `enolck`, `ebusy` for something another holder
has, such as a display, and `eintr` for a request that was still waiting,
nothing of it begun, when a flush or its fid's clunk ended it,
[Flush](#flush)); an atom
outside that list, the `errors` table of `abi/protocols/9p.txt`, is
refused by the grammar. The wire carries Linux's numbering, and the codec reads an error
number outside the list as `eio`, which also covers a server that answers
in another system's numbering, as QEMU's does on a macOS host
([design-live.md](design-live.md#files-between-the-host-and-the-machine)).

#### Flush

`flush` names a request. flush(5) says the server should answer it at
once, and that a reply to the flushed request that arrives before the
flush's answer stands: its effect happened and the client takes it. A
`flush` of a completed, unknown or flush request is answered `ok` too,
never with an error. erXos's servers, as QEMU's, answer a `flush` only
after the flushed request is settled, so a tag, and inside the machine
an alias, is never reused while its request could still be answered.
The one exception is a flush of a flush, which is answered at once: no
client depends on its order behind the flush it names, and answering it
at once means no flush ever waits on another, so chains of flushes are
bounded by construction.

erXos's servers settle a flushed request by answering it, always before
the flush's answer, so every request a grant admits gets exactly one
reply. Whoever holds the request when the flush reaches it answers with
what the request has done ([Serving](#serving-the-erx_fs-behaviour),
"Waiting requests"):

* a request that has finished is answered with its result;
* a request still waiting for an event, of which nothing has begun (a
  read waiting for bytes, a write queued behind another, a blocking lock
  not yet granted), is answered `{error, eintr}` at once;
* a `clunk` or `remove` the grant holds behind its fid's requests is
  answered once they are, and its flush after it;
* a request whose effect has begun (a present sent to the screen, a
  reset under way, bytes handed to a driver) is answered with its result
  when that effect ends, since `eintr` would deny an effect that may
  have happened and success would claim one that has not;
* a request its keeper passed on to another server is flushed there in
  turn and answered with that server's answer.

So a client that receives the flush's answer has seen what the request
did, a reply of `eintr` says that it did nothing, and no client has to
tell a request that did nothing from one whose reply was lost. A flush
waits only for an effect already under way, never for an event, which
is the sense in which flush(5)'s "at once" holds. A client that flushes
a request deactivates its alias once the flush is answered, so nothing
arrives after. A flushed lock request therefore either was granted
before the flush's answer or was answered `eintr` and took nothing
([Locks](#locks)).

Inside the machine only a relay sends `flush`, for a request its own
client ended: a 9P bridge for its edge client's, and a program window's
draw connection for a `kbd` or `mouse` read it relays to the display,
which the program's close ends ([A program's
window](#a-programs-window)). erXos's native programs
never abandon a request
([design-programs.md](design-programs.md#invariants), P7), and an
Erlang process waits for its reply or for its grant's end ([Erlang
clients](#erlang-clients-prim_file-and-erx_file_remote)). Their waiting
requests end when they are answered, at their fid's clunk, at the
keeper's end or at the grant's end.

#### Open files and offsets

9P2000.L keeps no offset at the server: every `read` and `write` names
its offset, and the client keeps the file's position. A server holds, for
each open fid, an **open**: the handle the tree's `open` answered, which
the grant keeps with the fid ([Serving](#serving-the-erx_fs-behaviour)).
Each `read` and `write` request on a regular file is atomic with respect
to every other, whichever fids and grants they come through, as POSIX
asks of regular files: one grant runs its requests one at a time, and
the tree orders the requests of its grants, each tree as its design
states ([Serving](#serving-the-erx_fs-behaviour), "Each tree makes its
own requests atomic"). A request that
waits for an event, as a stream file's read does, is handed to the
tree's keeper of that event and is atomic at the step the keeper
answers it ([Serving](#serving-the-erx_fs-behaviour), "Waiting
requests"); the grant's other requests go on while it waits. The unit is one request of at most 64 KiB: a
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
kept for every grant of a tree in the tree's one **lock table**,
`erx_fs_locks`, a process that `erx_fs_grants` starts beside the tree's
grants and names to each; a grant started on its own is a tree of its
own and starts its own. The lock table keys each lock by the file's qid
path, which is unique within the tree, and records the grant and the
fid that took it. A grant sends every `lock` and `getlock` to the lock
table as a waiting request, the lock table its keeper
([Serving](#serving-the-erx_fs-behaviour), "Waiting requests"), so the
locks of every grant on one file meet in one process and nothing in a
grant blocks on one. A lock's owner is the client's domain, from the lane the request
arrived on, with the request's `ProcId`; `ClientId` is recorded and
decides nothing, so no domain can release or test another domain's locks
as its own. A session gives each program a `ProcId` of its own, so its
programs' locks conflict with each other as UNIX processes' do. A read
lock needs a fid open for reading and a write lock a fid open for
writing, which the grant checks before it sends the request. The lock
table answers a `getlock`, an unlock, a lock that conflicts with nothing
and a conflicting one without 9P2000.L's `BLOCK` flag, `blocked`, in the
step that takes it; it holds a conflicting one with `BLOCK`, in which
nothing in the server blocks, until the step that grants the lock
answers it, or until the request is flushed or its fid is clunked, which
answer it `eintr`, since a held lock has begun nothing. A held request
counts among the client's requests in flight, and the lock table counts
each grant's locks against its bound ([Bounds](#bounds)). At a clunk the
grant, once the fid's held requests are settled, tells the lock table to
drop the locks the fid took, behind everything it sent it before; the
lock table monitors each grant with a lock or a held request there and
drops that grant's locks and requests at its `DOWN`. What it holds is
its grants' shares, each at most 256 locks and 64 held requests, so a
client grows only its own grant's share, and the table's memory grows
by at most one share with each grant; a table that passes its
`max_heap_size` is killed and handled as any end of it is. **A lock
table's end ends every grant that uses it**, since it alone records
which client holds which lock, and an empty table beside grants that
still hold locks would grant a conflicting one: `erx_fs_grants`
supervises the lock table and, after it, the supervisor of its grants,
`rest_for_one`, and a grant that is a tree of its own and the table
it starts each monitor the other and end at the other's end, whatever
its reason. So when a table ends, for any reason, every grant that
used it has ended before a new table takes a request, each grant's
client sees its grant end as at any grant's end, and every lock a
client holds is one the live table records. erXos's clients send `BLOCK` for a
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
requests in flight, waiting requests among them, and besides them at
most one flush waiting for each and one clunk for each fid they name,
with one flush waiting for each such clunk, so a client whose window is full of waiting reads can still flush and
clunk every one; and at most 256 locks. A
flush of a request that is neither in flight nor a held clunk waits for nothing and is
answered at once, at any bound, and so is a flush of a flush, which
takes no slot and holds nothing, so no flush waits on another. Any other
flush may be neither refused nor answered before its request, so a second flush of a request that
already has one waiting is dropped and counted, as a frame on an alias
in use is ([Pipelined requests](#pipelined-requests)): a 9P bridge
holds an edge's later flushes of one request itself and answers them
in order after the one it sent
([design-live.md](design-live.md#files-between-the-host-and-the-machine)).
A `clunk` or `remove` is admitted at any bound, since each ends a fid
and a fid ends once, and it waits only behind its own fid's requests in
flight ([Serving](#serving-the-erx_fs-behaviour), "Waiting requests",
rule 5). So no clunk is answered before its fid's requests are settled,
and the fid keeps its number until its clunk is answered, after which
the client may reuse it, as clunk(5) says. A `remove` that its checks
refuse still ends its fid through that clunk and answers its refusal
after it, as remove(5) says, so a refused `remove` never keeps a file,
and the space it holds, for as long as its owner runs. Every other
request beyond a bound fails with `emfile` or waits in the client,
never at the server. A name is valid
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
read on the new fid together, one round trip for all three. The order is
the order in which requests start: a request that waits is answered when
its keeper answers it, after later requests perhaps, so replies can
arrive in another order than their requests, as intro(5) allows, and a
client matches each reply to its request by its alias, at an edge by its
tag. A client of a
server from outside erXos, as the host-tree domain's bridge is of QEMU's,
which runs each request on its own, waits for a reply before it sends a
request that depends on it. An alias names one request: the grant
keeps one table of the aliases it has still to answer, its requests in
flight and the flushes and clunks waiting on them alike, and counts
every bound from it; a frame sent to an alias in that table is dropped and counted,
not answered, since an answer would reach the alias as the reply to
its earlier request. A walk that stops before its last name makes
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
same operation table of `abi/protocols/9p.txt`, which records each message's
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

1. **Start.** Once the path passes the checks above, the place
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
   from the entry's top: the entry's `root` names first, which on a grant
   the client walks from `NOFID`, the grant's root ([Version and
   attach](#version-and-attach)), for a domain's entry and a program's
   alike. The release file
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

   A target or parent walk that stops at or ends on a link goes back to
   the resumption as the action's walk does (above), and the resolver
   follows the link. An operation is never sent with a walk whose names
   still need a check of their own, so
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
file system holds no links. A link that lies in a tree reached through
a provider marked `nofollow` is never followed. The provider
`{facets, svc}`, through which a session reaches an app's tree, always
carries the mark, and so does the provider of every facet the
registry holds as one of the `media` interface, through which a session
reaches a drive's volumes, which the resolution of a table derives from
the facet's interface number, as it decides the `windows` exclusion
([Narrowing for a program](#narrowing-for-a-program)), never from a
name, a tree or a mount's options
([design-drives.md](design-drives.md#links-and-rights)). Such a link is never followed: where the resolver would
follow it, it answers `eacces`, as FreeBSD's `vfs_lookup` answers on a
`nosymfollow` mount, and an operation that acts on the link itself acts
on it. A bind or a program's table on that provider keeps the rule, and
no mount names an app's grant otherwise
([design-app-trees.md](design-app-trees.md#links)).

**The last name's link.** A link before a path's last name is always
followed. Whether a link that is the last name is followed, and what the
operation does with that name, is its `nameiop` and `FOLLOW`, as FreeBSD's
system calls pass them to `namei` (`kern_openat` through `vn_open_cred`,
`kern_mkdirat`, `kern_symlinkat`, `kern_linkat`, `kern_funlinkat`,
`kern_frmdirat` and `kern_renameat` in `sys/kern/vfs_syscalls.c`):

| Operations | `nameiop` | A last link is |
| --- | --- | --- |
| `read_file`, `read_file_info`, `list_dir`, `set_cwd`, `change_mode`, `change_time`, `write_file_info`, `open` without a mode that creates; a program's `open` without `O_CREAT`, `stat`, `chmod`, `truncate`, `chdir` | `LOOKUP` | followed |
| `read_link`, `read_link_info`; a program's `readlink`, `lstat` and `open` with `O_NOFOLLOW` (`CREATE` with `O_CREAT`) | `LOOKUP` | acted on: read, described, or refused by `lopen`'s or `lcreate`'s `eloop`, which a program's `open` answers as `EMLINK`, FreeBSD's open(2) answer |
| `make_link`'s existing name; a program's `link`'s existing name | `LOOKUP` | followed, so the new name links the link's target, as FreeBSD's `link` makes it |
| `open` with `write` or `append` and without `exclusive`, `write_file`; a program's `open` with `O_CREAT` and without `O_EXCL`, `O_NOFOLLOW` or `O_DIRECTORY` | `CREATE` | followed, so the file is made or opened where the link leads; `lcreate`'s `eloop` hands the link to the resolver |
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
the Fiasco kernel or works around a gap of it.

**Listings across mounts.** A directory's listing is its provider's
entries, plus an entry of kind `directory` for every mount point directly
below the directory that the provider does not list, so `ls /` shows
`/data` and `/proc` whatever the provider mounted at `/` holds; a mount
point hides a provider's entry of the same name. Where a domain has no
`/data` mount, because the manifest grants it no `data` facet, `ls /`
shows `/data` from the root's own entry, the empty directory the release
slice holds there ([A facet's mount](#building-binding-and-mounting)). The client adds these
entries, from its own table, after the provider's last page, so a server
never learns another's mounts.

### Building, binding and mounting

**Building.** The domain service builds a domain's namespace from its
specification: `/` is the release slice, and each entry of the
specification's `files` map mounts a facet the domain is granted, such as
`/root` or `/home/NAME` (its user's home on the data partition,
read-write; [A user's home](#building-binding-and-mounting)), `/data`
(the whole data partition, root's alone), `/media` (the drives' volumes, for a session granted `media`;
[design-drives.md](design-drives.md#the-media-tree)) or `/dev` (the device service's tree, for an administrator principal).
The local entries follow from the release, `/proc` among them, a tree
of the domain's own `erx_procfs` that reads through the domain's inspect
facet ([design-live.md](design-live.md#the-proc-tree)), and the facets
arrive with the domain's
other facets, each a grant the server made for the domain when the system
domain introduced the two
([design-system.md](design-system.md#creating-a-domain)); the runtime
mounts them before its release's applications start. `/tmp` is the grant
of the domain's own RAM file server, which the runtime starts and mounts
itself ([design-tmp.md](design-tmp.md#starting-and-mounting)). A facet that serves
a tree carries its grant's rights, `ro`, `rw` or `rx`, those of its
facet row, which the domain service takes from the manifest, so a tree whose programs a domain may run, such as a
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
`erx_ns:mount({Pid, Tree, Rights}, To, Options)` adds an entry for a
grant's pid, a process of the domain's own runtime, refusing any other
pid with `einval`, on the tree `Tree` and with the lesser of the rights
the options ask and `Rights` (below); no option names a tree.
`erx_ns:mount({facet, Name}, To, Options)` adds an entry for the facet
`Name`, an atom, refusing any other term with `einval`, with the same
options, whose provider names the facet and holds
no pid and no tree (below, "A facet's mount"); it is the only way a grant
of another domain is mounted.

**Rights beneath an entry.** An entry's rights never exceed the rights
of the grant beneath it. Every kind of entry holds this by
construction rather than by a check at each use:

* beneath a facet's entry is the grant the registry holds for the
  facet, which the registry holds as `{Pid, Tree, Rights}`, the rights
  of the grant's facet row, which the domain service takes from the
  manifest and no reply of the server's sets (above), and the grant's
  tree (below, "The tree beneath an entry"). A resolution
  gives the entry the lesser of the rights its mount asked and the
  facet's (`erx_facets:table/1`): `ro` lies below `rw` and `rx`,
  and `rw` and `rx`, which no grant holds together, meet at `ro`. A
  facet's mount compares the rights it asks with nothing, since the
  grant may not have arrived yet: a session that mounts `{facet, data}` at `/x` with
  `rx` makes an entry that resolves `ro`, through which nothing runs
  and nothing is written, since `data`'s grant is `rw`;
* beneath a grant pid's entry is a grant of the domain's own, which the
  mount takes as `{Pid, Tree, Rights}`, built by what started the grant
  with the tree it answered and the rights it serves:
  `erx_fs:start_mounted/4`, which starts a tree's grant and mounts it,
  naming its rights once, or `erx_fs_grants:own/1,2`, whose answer
  `erx_ns:mount_own/2` mounts.
  `erx_ns` gives the entry the lesser of those and the rights the
  options ask, by the order a facet's entry is lowered by
  (`erx_path:lesser/2`), so an `rx` mount of an `rw` grant is `ro`. A
  grant of another domain is never mounted by pid. Each grant of a session's
  export is likewise started with the rights of the local entry it
  serves ([Narrowing for a program](#narrowing-for-a-program));
* beneath an EROFS entry is the grant the mount's fid came through: the
  entry is `ro` or `rx`, and `rx` only through an `rx` grant (below).

A write needs no check of the client's for this, since a grant whose
rights are not `rw` refuses every writing operation itself (F5);
running a file does, since a server cannot tell a read for code from
any other read, so the handler's image check needs `rx` on the entry
the path resolved through, which by the rules above an entry has only
over an `rx` grant ([design-programs.md](design-programs.md#file-objects)).

**The tree beneath an entry.** An entry on a grant names the tree its
grant's files lie in, the numbering their qid paths come from
([Version and attach](#version-and-attach)), which keys their
identities, so two entries reach one file under one identity exactly
when they reach it through grants of one tree
([Identity and version](#identity-and-version)), whatever root each
grant is narrowed to, whatever service serves it and whatever rights it
carries. The tree keys identities and nothing else; it decides no
authority, and a display is kept from programs by its facet's interface
([Narrowing for a program](#narrowing-for-a-program)). A tree names the
backing numbering, never a grant's root: the storage domain's littlefs
volume draws every qid path from its owner's one path table
([design-storage.md](design-storage.md#read-write-storage)), so
`erx_lfs`'s `root` answers one tree, `data`, the name of the volume's
partition role, for the grants of the `data`, `packages` and `home`
services alike, rooted at the volume's top, at `/packages` or
`/packages/installed`, and at one user's home. In root's development
session, whose table holds both the `data` facet at `/data` and its
`home` facet at `/root`, `/data/root/notes` and `/root/notes` are one
file under one identity, with one mapper when mapped from both paths
(P14 of [design-programs.md](design-programs.md#invariants)). A facet
row's `tree` (`files_tree`, `abi/services/files.txt`) picks where a
grant is rooted within its service, `installed` or `home`, and is not
the grant's tree. That name comes from one place, the
server: `erx_fs:start_link/3,4`, through which every grant starts, a
mint's, a domain's own and a session export's alike, answers the
grant's pid with the tree its callback module's `root` names, the name
an `attach` is checked against, admitted with the root before the grant
takes any request ([Version and attach](#version-and-attach), "The root
is admitted when the grant is made"), and every holder receives the
tree with the pid:

* a facet's grant reaches the domain with it: the mint's reply names
  the tree beside the facet's pid, the domain service installs it with
  the facet ([design-system.md](design-system.md#facets-a-configured-domain-serves),
  "the mint's reply"), and the registry holds `{Pid, Tree, Rights}`. A
  facet's entry names only the facet, so its tree is whatever the
  registry holds at each resolution, and two facets of one tree, such as
  an `rw` and an `rx` facet of one volume, give its files one identity;
* a grant the domain started itself is mounted from the handle its
  starter built from that answer, `{Pid, Tree, Rights}`, as its rights
  are (above).

No mount option and no place names a tree. A facet's entry therefore
cannot name a tree other than its grant's, and a pid's entry names
one only through a handle of the domain's own, on a grant of its own
runtime, never on another domain's tree. A server's tree name counts
only for its own files, since a file's identity begins with the
server's domain, which the client takes from the pid and no server
states; a server that misnamed its tree, or named two trees for one
numbering, would confuse only the identities of its own files, as a
server that misnumbered its qids would. That is why the mint's reply
may state the tree: the tree comes from the server that numbers the
files, not from the manifest, which would be a second source of a name
the server's code fixes with nothing at run time to compare the two,
nor from the facet's name, which would give two facets of one tree two
identities for each file ([Alternatives
considered](#alternatives-considered)).

**A grant handle is built by its starter.** The handle a pid's mount
takes, `{Pid, Tree, Rights}`, is a plain tuple at run time, and any code
of the domain's runtime could build one with another tree or other
rights. Its authority does not rest on the tuple: `erx_ns:mount/3`
refuses a pid of another runtime, so a handle never names another
domain's grant, and rights wider than the grant's buy nothing, since the
grant's funnel refuses every write its own rights forbid (F5). Its tree
does rest on one assumption, stated here: a handle is built only by the
starter of the grant it names, from `erx_fs:start_link/3,4`'s answer,
by `erx_fs:start_mounted/4` or `erx_fs_grants:own/1,2`, whose type,
`erx_fs:grant_handle()`, is opaque, so Dialyzer refuses any other
construction. A domain whose own code broke that assumption would key
files of its own runtime's grants under a wrong tree, confusing only its
own view of its own files, as any code of a domain can corrupt that
domain's own state; no program builds a handle, since a program
reaches the namespace only through its handler.
`erx_ns:mount({erofs, Source}, To, Options)`, the one EROFS mount, adds
an entry for the image a package file holds: `erx_ns`'s process mounts
the image with the EROFS reader, which reads it through `erx_verity`
([design-storage.md](design-storage.md#reading-erofs-images)), so an
image the reader refuses is refused before the table changes, and the
entry's provider is the reader's mount. The caller names which file,
never its layout: `erx_ns`'s process finds the image's offset and length
and its hash tree's offset, length, salt and root hash itself, from one
of two places the system domain fixed, and no argument carries them.
`Source` is one of:

* `app`, the session's own package: `erx_ns`'s process takes the file's
  name, its grant and its layout from the app's record, which the domain
  service sends the session over the runtime protocol and the session's
  connection agent keeps
  ([design-packaging.md](design-packaging.md#an-apps-session)), and
  walks the name on that grant, the session's `packages` or `system`
  grant; a session that received no record is refused with `enoent`;
* `{header, Path}`, a package of `/apps`: `erx_ns`'s process decodes the
  layout from the package header at the file's start, which
  `erx_verity:header/1` reads through the mount's own fid: the
  file's length, by a `getattr`, and at most `pkg_header_max` bytes
  from offset 0, in one positioned read, so no
  module but `erx_verity` reads the fid (E1), and takes the file only if it reached it through the
  `apps` grant, whose header bytes are those the system domain's file
  check accepted
  ([design-packaging.md](design-packaging.md#apps), "Looking inside a
  package"); a file reached through any other grant is refused with
  `einval` ([design-storage.md](design-storage.md#invariants) E1).

Every decision the mount makes about what the domain may do with the
image rests on the grant its fid came through, never on the source or
the caller: the entry's rights are those `Options` name, `ro` when it
names none. An image is never written, so they are `ro` or `rx`, and a
mount that asks for `rw` is refused with `einval`; `ro` is allowed
through a grant of any rights, `rx` only through an `rx` grant, and a
mount that asks for `rx` through an `ro` or `rw` grant is refused with
`eacces`, each before the table changes. An image is therefore mounted `rx` only through an `rx` grant,
which writes nothing (F5), so a session runs no code from an image it
could rewrite (F6): `/app` is `rx` through the app template's `rx`
`packages` and `system` grants, a mount of a file of `/apps`, through
the `rw` `apps` grant, is at most `ro`, and a file under `/tmp` or
`/data` is mounted by neither source. So the entry's rights never exceed
those of the grant its fid came through. A file below the mount is a file of the
domain's own local provider: its identity is the domain, the mount's
own tree, a name `erx_ns`'s process draws afresh at each mount, as the
export names a local provider's tree, so an image mounted again is
another tree
([Narrowing for a program](#narrowing-for-a-program)), and the reader's
inode number as its qid path, and never the grant beneath, so two
images read through one grant never give two files one identity
([Identity and version](#identity-and-version)). `erx_ns`'s
process walks the file to one fid of its own, opens it for reading and
owns it, so the fid lives as long as the mount, and `erx_verity`, in
whichever process of the domain reads below `To`, sends its positioned
reads on that fid, as any process of a domain may use the domain's fids
([Fid owners](#fid-owners)); no OTP file descriptor is shared. The fid
is clunked once no entry holds it, a bind of the mount's included. If `erx_ns`'s process ends, the grant clunks
every fid it owns, its mounts' among them (F10), and reads below those
mounts answer `eio` until each is mounted again.
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
`prim_file` reads the boot table, the domain's one local entry: the
release slice at `/`, from the boot information, so `erl_prim_loader`
loads a runtime's first modules from the slice before any process of
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

**A facet's mount.** A grant of another domain is reached by path
through a facet's mount, never by its pid: the entry's provider is
`{facet, Name}`, and the table a resolution uses is the term with
each such entry, binds of it included, read at that moment against the
domain's facet registry, `erx_facets`, which `erx:cap/1` also
reads ([design-system.md](design-system.md#facets-a-configured-domain-serves)):
on the grant the registry holds for `Name` and that grant's tree,
`{grant, Pid, Tree}`, or `ended` when it holds
none (`erx_facets:table/1`, which `prim_file:erx_table/0` applies
to the term at each resolution). A domain mounts a facet only where the
manifest grants it one: the domain service names, in a domain's ready
answer, the facets of configured domains the manifest grants the
domain, which arrive later by installation, and the domain mounts each
facet it is granted or holds that has a mount point, `data` at `/data`,
read-write, `media` at `/media`
([design-drives.md](design-drives.md#mounting-it)), and each `files` service of the system
domain at the point its design names (`erx_ns:mount_facets/1`, which a
session's `erx_session` and the system domain's domain service, once it
has read the manifest, call). The system domain mounts its own grant of
each `files` service it serves at the same point
(`erx_ns:mount_own/2`; [design-shell.md](design-shell.md#interfaces)),
so a session's mount and the system domain's take the point from one
table of `erx_ns`. The `packages` tree has no place in that table: the
system domain alone mounts it, at `/packages`
(`erx_ns:packages_place/0`; [design-packaging.md](design-packaging.md#where-a-package-lies)),
so `erx_ns:mount_facets/1` mounts it in no session whatever facets the
session holds. A domain the manifest grants no `data` facet has no `/data` mount,
so the path falls through to the root's own entry, an empty directory of
the release slice, read-only, as FreeBSD shows the directory beneath a
mount point with nothing mounted on it: `ls /data` lists nothing and a
write there answers `erofs`. A facet that is mounted is never read as
empty: until its grant is installed it answers `eio`, as below. The
authority is read at use, so
nothing follows the registry: when a server's domain restarts, the
re-grant its new incarnation mints for the domain replaces the facet in
the registry, and the next lookup reaches it, with no change to the
table. `erx_ns`'s process monitors no facet's grant. A grant that has
ended, or whose connection has, answers every request `eio` through the
file client's own monitor on it, so between a grant's end and its
re-grant the facet's paths answer `eio`, as they do before its first
grant; they never resolve through the entry beneath. A descriptor keeps
the grant and fid it was opened on (F10): once that grant has ended,
every operation on it that reaches the server answers `eio`, a read
first answering any bytes the descriptor already holds, and only a new
open reaches the re-grant, so a writer reopens its files after the
server's domain restarts.

**A user's home.** Every user has a home directory at FreeBSD's paths:
root's is `/root` and every other user's `/home/NAME`, its login name.
FreeBSD's `/home` is a symbolic link to `/usr/home`; erXos has no
`/usr/home` and uses `/home` directly. A home lies on the data volume
at the same path, `/data/root` and `/data/home/NAME`, and a session
reaches it through a grant of its own, made by the mechanisms above
and in [design-storage.md](design-storage.md#interfaces) with nothing
added:

* **The tree.** The storage domain serves the volume's homes as a files
  service of their own, `home`, beside `data` and `packages`. A grant of
  `home` is always rooted at one user's home: its facet row states the
  files interface's tree `home` (`files_tree`), and `erx_lfs`'s
  `subtree/3` roots it at the home of the user the mint request names,
  the grantee's user name, which the domain service puts in every mint
  request, `root` for the system principal as its sessions are named.
  `erx_ns:home_place/1` refuses a name that is not one path name, so
  no name reaches above `/home`, and maps `root` to `/root`. A grant
  of `home` whose row states no tree has no root and is not started,
  so no grant reaches the homes as a whole.
* **The row.** The build derives a read-write facet row `home` of the
  manifest's service `home_service`, with `tree home`, for every session
  template but the app template, whose sessions have their own directory
  among `apps/`
  ([design-packaging.md](design-packaging.md#where-an-apps-files-lie)).
  The build's check refuses a source row of `home_service` and lets only
  derived rows state a tree, so no row roots a home grant elsewhere and
  every user's session holds its home by construction; it refuses a row
  of `data_service`, the whole volume, for any grantee but the system
  domain and, in a development manifest, root's template
  ([design-packaging.md](design-packaging.md#the-builds-check)).
* **The entry.** A session mounts its `home` facet at its home's path,
  which `erx_ns:home_place/1` makes from the session's login name, the
  prefix of its node name
  ([design-domains.md](design-domains.md#principals-sessions-and-quotas));
  `place/1` gives `home` no place of its own, as it gives `packages`
  none. The grant is rooted at the home and answers `..` at its root
  itself, so a session that holds only `home` sees its own home and
  nothing else of the volume: the home is a user's one place on the
  data volume, and no other grant reaches a part of it for one user.
  Root's session also holds `data`, the whole volume, as the
  administrator, and reaches the other homes under `/data/home` as
  FreeBSD's root does; that grant is a development build's alone
  ([the littlefs release contract](design-stopgap.md#release-contract),
  Grants), and no other user's session holds it ("The row").
* **Creation.** A home grant's start makes its directory when the
  volume lacks it, `/home` before `/home/NAME`, through the owner's own
  `make`, so a user's first login creates the home. A directory that
  cannot be made leaves the grant's requests failing, as a tree root
  the mount cannot make does.
* **The shell.** Every shell a session starts on a tty, its console's,
  a terminal's on a display or an SSH channel's, and every SSH exec,
  starts with rc's `$home` set to the home's path and its working
  directory there, as FreeBSD's `login(1)` sets `HOME` and changes to
  the user's home ([design-shell.md](design-shell.md)). A session that
  holds no `home` facet, an app's, keeps rc's default `$home`, `/`, and starts there.

**Showing the table.** The command shell's `mount` prints one line for
each entry of the table `prim_file:erx_table/0` answers, in FreeBSD's
layout (`sbin/mount/mount.c`, `prmount`, FreeBSD 15.1):
`SOURCE on POINT (TYPE, OPTIONS)`, for instance

```
release on / (release, local, read-only)
<5.120.0>:/data on /data (littlefs)
```

The source is `release` or `erofs` for a local provider, the server's
pid and the grant's tree, `PID:/TREE`, as NFS writes
`host:/export`, or `ended`; a bind's root follows as a path. The type is
FreeBSD's `f_fstypename`: a local provider's own, and a grant's from its
server's statfs at the entry's root (`erx_file_remote:statfs/2`), whose
`type` is the number the server chose, a member of the `p9_magic` enum of
`abi/protocols/9p.txt` for erXos's servers. `mount` prints a member's
name, which the ABI file gives as FreeBSD's name where FreeBSD has the
file system (`tmpfs`, `procfs`, `devfs`), the project's own otherwise
(`littlefs`, `erofs`, and `media`, the drives' tree), and `ramfs` for the made trees with no type of
their own (the start service's tree, `/machine` and a display's window
tree), after
the Linux number it answers; a number no member names prints in hex,
and a server that does not answer, or an ended grant, prints `-`. The
options are FreeBSD's words in their order (`MNTOPT_NAMES`,
`sys/sys/mount.h`): `local` for a provider the domain reads itself and
`read-only` for rights other than `rw`. A tree another process serves has no
word, as FreeBSD's NFS mounts have none: its `PID:/TREE` source shows it. The type
is a name of `mount`'s or a number, never text a server chose, and every
name goes through the field escape (`erx_text:escape_field/1`).

### Narrowing for a program

A native program gets the namespace its starter names, by default the
starter's own whole namespace, narrowed where the starter asks
([design-shell.md](design-shell.md#starting-programs)). The namespace is
a table in the program's handler, of the type a domain's table is, built
by the pure functions `erx_ns` applies to the domain's
([Building, binding and mounting](#building-binding-and-mounting)), and
every entry of it lies on one of the session's grants, with rights within
the starter's:

* a grant entry of the starter's, a facet's included, keeps its provider,
  with its `root` moved down to the place the starter asks for and the
  rights it asks for within its own; a facet's entry is read against the
  session's facet registry at each resolution, as the session's own is;
* a local entry of a session becomes an entry on a grant of the session's
  **export**,
  an `erx_fs` server in the session's domain that serves the session's
  local providers, each as a tree of its own named by its mount: a name
  the export draws from the session's counter when the provider is
  mounted, so a provider's qid paths stay unique within their tree, and
  a provider unmounted and mounted again, at the same point or another,
  is another tree, whose files never share an identity with the old
  one's ([Identity and version](#identity-and-version)); one more tree
  serves `/bin`, an `rx` directory of the session's program commands;
  `/dev/null`, `/dev/zero`, `/dev/urandom` and `/dev/tty`; and
  `/etc/passwd` and `/etc/group`, with qid paths from the session's
  counter ([design-programs.md](design-programs.md)). Each tree has
  grants of its own, since a grant reaches files of one tree ([Version and
  attach](#version-and-attach)); so the export is the set of those
  grants, and a program started with a window adds one, of its own
  `/dev` tree, for as long as the program runs ([A program's
  window](#a-programs-window)).

A program's table is a value: the handler resolves each of the program's
paths over it as `prim_file` resolves a domain's over the domain's
table, walking from the grant's root through the entry's `root` with the
names the resolver produced, and it holds no fid for an entry. So a fork
copies it, nothing clunks it, and a `root` that a rename takes away
answers `enoent` on the next walk, as a bind's does.

**No program reaches a facet of the `windows` interface.** A program
reaches a display only through its own window ([A program's
window](#a-programs-window)), and the one fact that decides it is the
interface of the facet beneath an entry, which the system domain
supplies, never the tree a server names. Every facet a domain's
registry holds carries its service's interface number
(`abi/services`), which the domain service sets and no server's reply
does: for a facet of the ready answer and for each installation, from
the manifest's row, and for a facet `erx_domain:grant/4` installs, from
the live grant record of its source, so a re-grant keeps its source's
interface under whatever name it is installed
([design-system.md](design-system.md#facets-a-configured-domain-serves)).
The handler resolves a program's paths over the program's table through
`erx_facets:program_table/1`. The program's table reaches the handler as a
value of its own, `erx_facets:program()`, which only `program_table/1`
turns into entries and which `erx_facets:table/1` refuses, so none of
the handler's resolutions of a program's paths can take the session's
way. The open-file description it starts for an open walks the table
the handler resolved.
`program_table/1` reads each facet's entry against
the session's registry at that moment, as `erx_facets:table/1` does for
the session, and differs in one rule: an entry whose facet the registry
holds as one of the `windows` interface is left out of that
resolution, as if the table had no entry there, and so is such a facet
under `{facets, svc}`. The rule is applied at every resolution, not when
the table is built, so it holds by construction for every order of
events:

* a facet mounted before its grant is installed resolves to `ended` for
  a program, as for the session, until the installation, and from the
  installation on is left out, since the installation brings its
  interface;
* a replacement under the same name, a re-grant from a display's new
  incarnation or `grant/4` installing a display over a name that held a
  files facet, is read at the next resolution with its own interface;
* a display installed under any name, mounted at any point and bound
  anywhere, is left out, since a bind keeps its source's provider, the
  facet's name, and the name's interface comes with its grant.

No other entry reaches a display: a pid's entry is a grant of the
session's own runtime ([Building, binding and
mounting](#building-binding-and-mounting)), and the server of every
`windows` service is a display's configured domain, never a session
(property 18 of [design-system.md](design-system.md#the-manifest)).
The rule is the rule for a narrowing too: a starter that narrows a
program to a place on a display's facet, such as `within [/mnt/w/w1]`,
starts it with nothing at that place, and the start is not refused.
The tree a window server names plays no part, so a server whose tree
took another name, or a files server whose tree took the name
`windows`, changes nothing a program reaches.

**Where the export and a grant meet.** A session may also mount a grant
at `/etc` or `/dev`, where the export serves names of its own: a session
that holds the start service's grant mounts the `etc` tree at `/etc`
([design-apps.md](design-apps.md#the-start-table)), and an
administrator's session mounts the device service's tree at `/dev`. At
those two places the export answers its own names and the program's
handler passes every other name to the grant. A walk of `passwd` or
`group` under `/etc`, or of `null`, `zero`, `urandom` or `tty` under
`/dev`, reaches the export's file; a walk of any other name goes to the
session's grant at that place, through the program's entry there, within
the root and rights the program's namespace was narrowed to, so a
program narrowed away from the grant finds the export's names alone, and
one given the grant read-only reaches its files read-only. For a program
started with a window, its own `/dev` tree stands where the export's
`dev` does, and the names it takes at `/dev` are the export's four and
its window's ([A program's window](#a-programs-window)).
A listing gives the export's names and then the grant's entries less
any of those names, so every name a listing shows is the file a walk of
it reaches; the handler numbers the joined listing's offsets itself. A
writable file of the grant never replaces one of the export's names: a
grant's own `passwd` or `null` is neither listed nor reached, and an
operation that names one of the export's names at those places goes to
the export, never to the grant: a create of an existing device opens it,
so `>/dev/null` reaches `null`, and every other create, a `mkdir`,
`symlink`, `mknod` or a link's destination, answers `eacces`, and a
rename or remove of one `eperm`, as the export's tree answers them. This
is the one place a program's namespace joins two servers, and the names
the export takes there are its own, fixed; it is no union mount
(Non-goals). Nor does an entry hide one: a start whose narrowed table
holds an entry at or below one of the export's names at `/dev` or
`/etc`, which would hide that name or put a mount beneath a file, is
refused with `EINVAL` before anything is reserved.

The program itself receives none of this: its sub-space gets its channel,
its data area and its pipe ends, and the table lives in the session's
Erlang state, held by the program's handler
([design-programs.md](design-programs.md#a-program-is-a-port)). A program
started with `/data/logs` therefore has an entry at `/data/logs` whose
`root` is the starter's at `/data` with `logs` after it, and reaches
nothing above it whatever it asks, since the handler walks for it only
the plain names `erx_path` asks for, never `..`, and only below the
`root` of an entry of the program's own table (F3, F9): a `..` at the top of the
program's mount steps out in the program's namespace, to `/data`, which
holds only `logs`, and never asks the server. The server sees the session's grant
and knows nothing of the program: the narrowing is the handler's, which
is the program's file server, and the session's own authority bounds
every program's.

A file passed to another program of the session, as `xargs` hands its
standard streams to the programs it starts, is its open-file description,
which the handler records in the receiving program's open table; a
directory passed is its description too. No program reaches another's
files unless it was handed them. Every file-backed description in a
program's open table, a directory's included, was opened through a
program's table, the program's own or that of a program that passed it
on, directly or by an `openat` from a directory description that was
itself opened so: a spawn, a fork and a passed descriptor name only
opens of the sender's own table (step 3 of
[Starting a program](design-programs.md#starting-a-program),
[Passing descriptors](design-programs.md#passing-descriptors)), and a
session process hands a program pipe ends and a buffer, never a
description ([design-programs.md](design-programs.md#the-handler), "A
session process's program"). A `socket` or an `accept` makes a
description without a lookup in any table
([design-programs.md](design-programs.md#descriptors-and-files)); it
holds no fid, so it names no file. So what no program's table reaches,
no description any program holds reaches either, and an `openat` from a
directory it holds walks only below a place some program's table
reached. That is a property of all programs' tables together, not of
one program's: a passed descriptor reaches the receiver whatever its own
table holds ([design-programs.md](design-programs.md#passing-descriptors)),
so keeping a file from one program takes both a namespace narrowed away
from it and withholding every descriptor of it; what no table of any
program reaches, such as a window's `ctl`, no program reaches by either
route. A program's end closes its share of
every description
([design-programs.md](design-programs.md#a-programs-end)); its table
holds no fid, so nothing else is clunked.

A forked child gets a copy of its parent's table, and each of the
parent's descriptions, its open directories' included, before the
session copies the sub-space, so a `clunk` in one closes only its own
share of a description and never a file of the other's
([design-programs.md](design-programs.md#the-second-tier)). A file the two
share is one description, so they share its offset as POSIX processes do.

#### A program's window

A program started with `window => Display`, or given a window at its
first open of `/dev/draw`
([design-programs.md](design-programs.md#the-handler)), finds its draw
connection's `draw` and `ctl` and its window's `kbd`, `mouse`, `wctl`
and `label` at `/dev/draw`, `/dev/ctl`, `/dev/kbd` and so on, and
`/dev/clipboard` when the session's grant on the display carries
`clipboard` ([design-display.md](design-display.md#the-window-tree), "A
program's `/dev`"), which the handler learns by a walk of `clipboard`
from a root of that grant when it starts the tree. The window's
directory holds one more file the program must not reach: the window's
own `ctl`, which presents any range of the session's whole pixel area
([design-display.md](design-display.md#the-window-tree), "`ctl`"), so a
program holding it could show another program's buffer in its own
window. **A program reaches only its own window's files, and of them not
the window's `ctl`.** It follows from one rule, which names no path:
no facet of the `windows` interface resolves for a program. A program reaches files
through its table and its open table, both kept by its handler
([design-programs.md](design-programs.md#the-handler)), and:

* no program's resolution reaches a facet of the `windows` interface
  ([Narrowing for a program](#narrowing-for-a-program)), so whatever
  mounts and binds of a display its starter's table holds, and whenever
  the display's grant is installed, the program reaches none of them,
  below `/dev` or anywhere else;
* every file-backed description in a program's open table was opened through a
  program's resolution ([Narrowing for a program](#narrowing-for-a-program)),
  so none is on a display's grant, a directory's included: no starter can
  hand a program an open of a window's `ctl`, or of a window's directory
  to walk to it from, by a spawn, a fork, a passed descriptor or
  `start/1`, which refuses such a descriptor with `EINVAL`;
* the program's `/dev` is a tree of its own, which holds its window and
  its draw connection rather than a path to either, and serves from them
  exactly the files above, so no name in it leads into the window's
  directory; the fids it relays on, the window handle's and its own,
  never enter the program's open table, whose open of `/dev/kbd` is an
  open of the tree's file.

The rule needs no check of a description: a file-backed description is
made only by an open through a program's table, or an `openat` from a
directory description made so, and moves only from one program's open
table to another's, so the namespace rule, which holds for every
program's table, covers it; a socket's description holds no fid and
names no file. The display does not draw this line itself, and cannot: its
client is the session, whose pixel area holds every buffer of the
session's, and a range is owned in the session by whoever allocated it,
not by a window, as a starter presents a buffer its program's handler
owns ([design-display.md](design-display.md#the-pixel-area),
[design-programs.md](design-programs.md#the-handler)).

**The `/dev` tree.** It is the export's fixed tree, `erx_session_export`,
started for the one program with its window and connection among its
arguments. Its root holds `dev` alone, and its `dev` directory holds
`null`, `zero`, `urandom` and `tty`, as the shared tree's does, and the
window's names, and nothing else; the program's `/bin` and `/etc` stay on
the shared tree's grants, and only its `/dev` entry names this tree. The
names no entry of the program's table may stand at or below are the
devices' and every window name, `clipboard` included whether or not the
session's grant carries it, so the check does not depend on the display;
a table with such an entry refuses the start with `EINVAL`. Its qid
paths are drawn from the domain's counter when its grant starts, as the
shared tree's are, so its tree's name, `export`, may be the shared
tree's and the domain, tree and path of each of its files still name no
other file ([Identity and version](#identity-and-version)). Its window
files are:

| Name | What a request does | Opens |
| --- | --- | --- |
| `draw` | a write is one write of the draw connection, a read one read of it | read and write |
| `ctl` | a read answers the connection's `ctl` text, not the window's | read only |
| `kbd`, `mouse`, `wctl`, `label` | a read or a write, at the program's offset, is one read or write of the window handle's open fid of that name; a read of `kbd` or `mouse` waits at the draw connection | `kbd` and `mouse` read only, as the display opens them; `wctl` and `label` read and write |
| `clipboard`, when that grant carries `clipboard` | relayed to the display's `clipboard`, on a fid opened for the open | read and write |

**The relayed fids.** `erx_win:open/2` walks and opens the window's
`ctl`, `mouse`, `kbd`, `wctl` and `label` from the window's directory
when it makes the window, keeps those fids in the handle and clunks the
directory's, so the handle names the window by fids opened on it, never
by its directory's name. The display binds each such fid to the window
it was walked in, so a window removed and another made under the same
name is never reached through the old handle: its fids answer what the
display answers for a window that is gone. The tree relays `kbd`,
`mouse`, `wctl` and `label` through functions of `erx_win`, which owns
the handle's representation, and which take no `ctl`, so no request a
program sends reaches the window's `ctl`, which only the draw
connection's presents write. The tree walks nothing in the window's
directory and opens nothing there: every program open of those four
names shares the handle's fid of that name, which the window's files
allow, since a window's file keeps no state for a fid. Their `Owner` is
the handler, which opened the window, so they end with the handler, as
the window does, and a program's close of one clunks nothing.

The clipboard is the display's, not the window's, and an open of it with
`O_TRUNC` empties it, so each program open of `/dev/clipboard` gets a fid
of its own: the tree walks `clipboard` from `NOFID`, the root of the
session's display grant, into a new fid owned by the tree's grant,
opens it with the program's flags, and keeps the opened fid in the
open's handle. A walk or an open that fails clunks every fid the attempt
made and answers with the display's error; the program's close clunks
the opened fid; and the end of the tree's grant ends whatever it still
holds ([Fid owners](#fid-owners)).

Every relayed fid lies on a grant the session already holds, so the tree
reaches nothing the starter could not. A read of `kbd` or `mouse` waits
for a record at the display, so the tree's `read` answers it as a
waiting request ([Serving](#serving-the-erx_fs-behaviour), "Waiting
requests") whose keeper is the window's draw connection. The connection
keeps at most one read of each file at the display, as the window serves
its own readers one record at a time: the first it marks begun and sends
without waiting for the reply, and the rest wait in arrival order until
the display has answered the one before. It answers each program's
request with the display's reply, after it has made image 0 anew for an
`r` record in it ("A resize", below). So a window's waiting reads take
at most two of the session's display grant's requests in flight, however
many the program keeps. The program's close of an open whose read the
connection holds flushes it there (rule 5): a read still waiting at the
connection is answered `eintr` at once, and for the one sent the
connection sends the display a flush, so the window process settles it,
with `eintr` or with the record it had already taken, and no key goes to
a closed open. A read waiting on one file thus holds up no other, nor
the file's close. A read of `wctl` or `label` answers at once at the
display ([design-display.md](design-display.md#the-window-tree)), so the
tree relays it within its callback. A write of `draw` runs within its
callback too, as a write of a local file system runs to its disk: a `v`
in it waits for its present, which the screen answers once the device
has taken the frame, at once for a hidden window, and with an error when
the device's driver misses its frame deadline and ends
([design-display.md](design-display.md#the-screen-and-its-one-path-to-the-device)).
So a draw write holds its grant's later requests, a `kbd` clunk among
them, for at most one present, and the connection takes a flush that
arrives meanwhile once the present is answered; the program's input
waits for a frame of the device, never for an event. The files of `draw`
and `ctl`, their units and their answers are
[design-display.md](design-display.md#the-draw-connection)'s ("The
connection's files"); an open of `/dev/ctl` for writing answers
`EACCES`. Every operation on a name of the tree has the answer the fixed
tree gives its devices ([Narrowing for a
program](#narrowing-for-a-program)), so `>/dev/draw` opens `draw`, and
the resolver handles the tree as any other: it is a directory provider
at `/dev`, joined with a grant at `/dev` where the session holds one,
and its names are among the export's names there.

**A resize.** The connection's image 0 has the window's size only after
the connection makes it anew, and a program learns of a resize from an
`r` record of `mouse`
([design-display.md](design-display.md#the-window-tree)). The connection
is the one place both meet, since it keeps every read of `mouse`: when
the display's reply to one holds a record whose kind byte is `r`, the
connection makes image 0 anew before it answers the read. So the program
never sees an `r` before image 0 has the new size: a read of `ctl` after
it shows the new rectangle, and a write after it draws on the new image.
The connection takes its steps one at a time, so a write already running
finishes on the old image 0 and the next starts on the new. A resize
whose record no read has yet taken leaves image 0 as it was until a read
takes it, and a resize that fails, for a window that has gone or whose
rectangle cannot be read, leaves image 0 as it was; the read answers the
record either way. Then `ctl` shows the size image 0 has, and a frame
drawn at it is shown clipped to the window, as the display shows any
frame drawn for an earlier size
([design-display.md](design-display.md#the-window-tree), "`ctl`").

**Starting.** When it reserves the program's grants (step 5 of
[Starting a program](design-programs.md#starting-a-program)), the
handler, after building the program's table:

1. opens the window with `erx_win:open/2`, as its holder;
2. starts the connection on it, as its starter;
3. starts the `/dev` tree's grant for its own domain (`client => own`),
   `rw`, ending with the handler (`ends_with => self()`);
4. puts in the program's table, at `/dev`, an entry on the grant with
   `root` `[<<"dev">>]`, whose tree and rights are those of the handle
   the grant's start answered (`erx_fs:start_link/4`), in place of
   every entry at exactly `/dev`, or beside the others when the
   narrowing left none.

Steps 1 to 3 are one call the handler makes in its own process,
`erx_session_export:start_window/1`, so they lie in the session's
application beside the tree they start, and the handler's application,
which the display domain's release also ships, names none of the window
library's modules ([design-display.md](design-display.md), G9).

Step 4 drops what it replaces, so the entry is measured against the
entries at exactly `/dev`, since rights only shrink (F3). With none
there, `/dev` is the export's, whose names reach every program whatever
its narrowing ([Where the export and a grant meet](#narrowing-for-a-program)),
and the window's tree stands in its place, so the entry widens nothing
and the window starts. That is the case of a session that has mounted
nothing at `/dev`, whose table, like the boot table that holds the
release slice at `/` read-only alone, has no entry there; an entry above
`/dev`, such as that read-only root, does not cap the entry. An entry at
exactly `/dev`, the starter's or one its narrowing left, caps it: a
program draws by writing `draw`, so a window is useful only at `rw`, and
a table with an entry at exactly `/dev` that cannot write refuses the
start with `EACCES` when the handler builds the program's table, before
step 1 opens anything, rather than start a window nothing can draw to;
an entry at or below one of the tree's names refuses the start with
`EINVAL` before that check. An entry below `/dev` that names none of the
tree's names stays.

The join of the export and a grant at `/dev` for a program's handler is
open work ([Where the export and a grant meet](#narrowing-for-a-program),
TODO.md): a handler without it counts a grant the session mounts at
exactly `/dev` itself, such as an administrator's device tree, among the
entries step 4 replaces, so a program with a window loses that grant and
gains nothing, which fails safe. Whether a windowed start still refuses
a read-only entry at exactly `/dev` once the join exists is decided with
the join.

A table at `ERX_NS_MOUNTS_MAX` entries with none at `/dev` cannot take
the entry, and the start is refused with `EINVAL` before the window is
opened. A step that fails refuses the start with its errno: the window's
as [design-programs.md](design-programs.md#the-handler) lists them, the
connection's (`ENOMEM` when image 0 cannot be made), and `EIO` for a
grant that does not start. The handler undoes nothing by hand: a refused
start ends it, and what it made ends with it, as follows.

**Ownership and lifetime.** The handler is the one owner of the window,
the connection and the tree's grant, and each watches the handler with
a monitor, so each ends at the handler's end whatever its reason. The
handler in turn ends at the end of the connection or of the tree's
grant, whatever its reason, since it is linked to both and neither
ends `normal` before the handler does, so the four share one life. The
connection relays the program's input reads on the window handle's fids,
whose owner is the handler, so a connection that ended while the handler
ran would leave its reads at the display, where the next key would go
to no one; with one life there is no such state, and no request the
connection passed on outlives the grant that asked for it (rule 7 of
"Waiting requests"). The monitors matter for a refused start, which ends
the handler with `normal`, a reason that reaches a linked process as a
signal it ignores. The display ends the window when its holder ends
([design-display.md](design-display.md#the-window-tree)); the connection
monitors its starter and stops at its end, giving back its buffer's
lease, after which the buffer's range is free
([design-display.md](design-display.md#the-pixel-area)); and the tree's
grant ends with what its `ends_with` names
([Interfaces](#interfaces)), whose end ends every fid on it and every
fid it holds on the display. Each sees the handler's end on its own, in
no order, and nothing is unregistered, since nothing was registered: the
grant's pid is written into this program's table and nowhere else, and
a program holds no pid (F9). While the program runs:

* a connection that ends, for any reason, ends the handler, and the
  program with it, and the starter's `'DOWN'` carries the connection's
  reason as the handler's own end; nothing restarts the connection;
* a window that ends alone, its display lost, leaves the connection
  running with each present failing
  ([design-display.md](design-display.md#the-draw-connection)), and
  `kbd` and the window's other files answer what the display answers for
  a window that is gone;
* a crash of the tree's grant ends the handler through the link, and the
  program with it; the starter's `'DOWN'` carries the crash as the
  handler's own end ([design-programs.md](design-programs.md#the-handler)).

**A program's children.** A child the program forks gets a copy of the
program's table, and one it spawns a table narrowed from it, as every
child does ([Narrowing for a program](#narrowing-for-a-program)); the
`/dev` entry is one entry among them, on the tree `export`, so a child
whose namespace keeps `/dev` shares its parent's window and draw
connection by path, as it shares them through the descriptors it
inherited. One spawned narrowed away from `/dev` reaches neither by
path, but still reaches every open of the `/dev` tree's files its parent
passes it as a descriptor, as any passed file reaches its receiver
([design-programs.md](design-programs.md#passing-descriptors)); a parent
that would keep its window from a child narrows the child away from
`/dev` and passes it none of those descriptors. The
two programs' writes to `/dev/draw` meet in the one connection, which
takes them one at a time, as two Plan 9 processes sharing a draw
connection's files do. Nothing outlives what it uses: the tree's grant,
the window and the connection end with the parent's handler, and the
handler exits only after the anchor's exit record, which the kernel
posts once every space below the parent's anchor has ended, every child's
included ([design-programs.md](design-programs.md#a-programs-end)), so no
child runs once the `/dev` tree has ended (open question 2).

Requests from several threads meet in two places that already order
them: the tree's one grant runs its requests one at a time,
and the connection runs one call at a time, so a write reaches the
connection whole and a read of `ctl` is answered between writes, never
in the middle of one.

### Serving: the `erx_fs` behaviour

A file server in Erlang is a module of the `erx_fs` behaviour, which owns
the protocol, the fids, the locks and the checks, and calls back for the
tree. The behaviour, its grant's pure core and the file servers erXos
writes in Erlang form the `erx_files` application
(`erlang/apps/erx_files/`):

```erlang
%% The grant's tree: {ok, Fs}, a handle to a tree kept elsewhere, the same for the
%% grant's life; or {own, Tree}, a tree value init made, which only this grant holds.
%% For an own tree every callback below takes the current Tree in Fs's place and
%% answers {Answer, Tree1}, forget {ok, Tree1}, and the grant keeps Tree1.
-callback init(Args :: term()) -> {ok, Fs :: term()} | {own, Tree :: term()}.
%% A tree whose grants a facet row's `tree` (abi/services/files.txt) may root within it:
%% the init Args of a grant rooted at the root Tree names for Grantee, the domain the
%% grant is for and the principal its mint named, from which a root per principal, as
%% `tree apps` is, follows. erx_fs_grants asks it before such a grant starts, and a tree
%% without it starts no grant whose row states a tree.
-callback subtree(Args :: term(), Tree :: atom(), Grantee :: erx_fs_grants:grantee()) ->
              {ok, Args1 :: term()} | {error, einval}.
%% The grant's tree and root: the name of the numbering its files' qid paths come from,
%% the same for every grant whose paths come from one table, whatever its root, which
%% erx_fs:start_link/3,4 answers with the grant's pid and attach's Aname must match; the
%% root node, where an attach and a walk from NOFID start; and the root's qid, a
%% directory's. Called once when the grant starts, whose check the answer must pass,
%% and at each attach for the root's current version.
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
%% A read or a write that waits for an event answers {wait, Keeper, Request}:
%% the tree's Keeper answers it later, through erx_fs_waits ("Waiting requests").
-callback read(Handle :: term(), Offset :: non_neg_integer(),
               Count :: 1..65536, Fs :: term()) ->
              {ok, binary()} | {error, file:posix()} | wait().
-callback readdir(Handle :: term(), Offset :: non_neg_integer(),
                  Max :: 1..256, Fs :: term()) ->
              {ok, [dirent()]} | {error, file:posix()}.
-callback readlink(Node :: term(), Fs :: term()) ->
              {ok, binary()} | {error, file:posix()}.
-callback statfs(Fs :: term()) -> {ok, statfs()}.
%% ok, or the errno of what the close could not complete; the fid ends
%% either way.
-callback clunk(Handle :: term(), Fs :: term()) -> ok | {error, file:posix()}.
%% A tree that writes adds these; one without them is read-only (F5).
-callback write(Handle :: term(), Offset :: non_neg_integer(), binary(),
                Fs :: term()) ->
              {ok, Count :: non_neg_integer(), At :: non_neg_integer()}
            | {error, file:posix()} | wait().
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
-optional_callbacks([subtree/3, forget/2, readlink/2, write/4, make/4, setattr/3,
                     unlink/4, rename/5, fsync/2, xattr/3]).

-type what() :: {file, Mode :: 0..8#7777, Flags :: non_neg_integer()}
              | {directory, Mode :: 0..8#7777, Owner :: pid()}
              | {symlink, Target :: binary()} | {link, Node :: term()}
              | {node, Mode :: non_neg_integer(), Major :: non_neg_integer(),
                 Minor :: non_neg_integer()}.
-type wait() :: {wait, Keeper :: pid(), Request :: term()}.
```

`make` serves `lcreate`, `mkdir`, `symlink`, `link` and `mknod`, one
callback for every operation that adds a name, so a module states once
which kinds its format keeps and refuses the rest with `eperm`. A
`{directory, ...}` carries the `mkdir`'s `Owner`: a `mkdir` makes no fid, so
nothing in the grant holds its owner, and a tree whose directories live as
long as their maker, a display's windows, monitors it itself; a tree of
stored directories ignores it. `unlink`
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
  a fid owner's end, and a node no step names any more, or one a walk that
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
  client delays only its own grant. The grant is the one process that
  runs its client's requests: it calls every callback itself, one at a
  time, in the order the requests arrive. The client's state, its fids,
  their owners' monitors, its opens and the requests it has in flight,
  lives in that process, within the bounds above and the process's
  `max_heap_size`. An open is the handle the tree's `open` or `make`
  answered, kept with the opened fid, so the fid is the open's one name,
  and two opens whose handles are equal, as every open of one window
  file's is, stay two opens. The grant alone ends a fid ([Fid owners](#fid-owners)), and the
  module hears of an open fid's end through `clunk`.
* **Waiting requests.** Nothing in a grant waits for an event. A
  callback does bounded work: a step of its own tree, a step of its
  tree's process, a call that process answers without waiting for an
  event, a call to another
  service whose design names its deadline as the bound when every
  holder of the grant could make that call itself, so a stalled grant
  holds only requests of parties who could ask for the same wait, or a
  read or
  write of its medium, which the grant waits for as a call on a local
  file system waits for its disk. A read or a write that must wait for
  an event, bytes a device has not sent yet, a key not yet pressed, a driver that
  has not yet taken what was written, is handed to the process that owns
  that event, the request's **keeper**, a process of the tree, which
  answers it when the event comes; meanwhile the grant goes on with its
  client's other requests, its clunks and its flushes. A blocking lock is
  the same construction, with the tree's lock table as its keeper
  ([Locks](#locks)). The rules below follow from two facts: a request
  has one keeper, which answers it once, and everything the keeper hears
  about it comes from the grant that holds it, one sender, so in the
  order the grant sent it:
  1. **The callback answers at once**: its result, or `{wait, Keeper,
     Request}`, which names the keeper and the tree's own term for what
     to do. The grant monitors `Keeper` with an alias that the first
     reply deactivates (`erlang:monitor/3` with `{alias,
     reply_demonitor}`), sends it `{erx_fs_wait, Wait, Request}`, where
     `Wait` carries that alias and the grant's pid, records the alias
     with the request in its one table of live aliases ([Pipelined
     requests](#pipelined-requests)), and takes its next frame. The
     alias is the request's only name at the keeper. When `Keeper` is
     not a process of the server's own runtime, or is the grant itself,
     the grant answers the request `eio`.
  2. **The keeper answers once, through its set.** A keeper keeps the
     requests it holds in an `erx_fs_waits` set, which the `erx`
     application provides, and answers one only with
     `erx_fs_waits:answer(Wait, Result, Waits)`, where `Result` is one of
     the callback's own answers other than a wait: the one call sends
     it to the alias, forgets the request and releases the set's monitor of its grant with that
     grant's last request, so no answered request stays held and no held
     one is answered by another route. The alias takes one answer, so a
     second is dropped by construction. The grant holds the answer to the
     callback's shapes and to the grammar's reply check, as for an
     answer made at once, and answers the client.
  3. **A request waits until its keeper begins it.** A keeper that
     starts an effect for a request, a present sent to the screen, a
     reset, bytes handed to a driver, or the request passed on to
     another server, first marks it begun in its set
     (`erx_fs_waits:began/2`), and from then answers it only with what
     the effect did. A request the keeper answers in the step that
     takes what it answers with, a read answered from bytes the keeper
     holds, needs no mark.
  4. **A flush follows its request to the keeper.** The grant sends the
     flush of a request a keeper holds to that keeper, as
     `{erx_fs_flush, Wait}`, after the request, so the keeper meets the
     flush after the request: one process's messages to another arrive
     in the order they were sent. A request already answered needs
     nothing. The keeper hands that message to its set, which answers a
     request not yet begun `{error, eintr}` itself, at once, and forgets
     it. A begun request is answered when its effect ends. Every step of
     an effect waits only on a timer of the keeper's or on a process the
     keeper monitors, a driver, the screen, the device service or
     another server, which answers or ends, and the keeper answers `eio`
     at that end; so a begun request lasts as long as those processes'
     own deadlines let it, and each tree's design states that bound and
     what ends the process that misses it: a present lasts until the
     device takes the frame, whose driver ends at its frame deadline
     ([design-display.md](design-display.md#the-display-device)), and
     the Bluetooth line's reset by its notification polls and power
     times ([design-bluetooth.md](design-bluetooth.md#the-controllers-line)).
     A driver that holds bytes for a device's flow control waits on the
     device, not on a deadline, so a write the Bluetooth line has handed
     its driver lasts until the line's next reset, a residual (TODO.md).
     A keeper that passed the request on sends that server a flush of
     it, behind the request, and answers with what that server answers
     ([Flush](#flush)). The grant answers the flush after the request's
     reply.
  5. **A clunk settles its fid's requests first.** At the clunk or the
     `remove` of an opened fid, the grant sends a flush of each of that
     fid's requests a keeper still holds, marks the fid closing and goes
     on with its other fids; it runs the fid's `clunk` callback once the
     last of those requests is answered, holding the clunk as it holds a
     flush behind its request, and then answers the clunk with what the
     callback answered. A `remove` unlinks its name when the grant takes
     it, before its fid's requests settle, so a walk or an `O_EXCL`
     `lcreate` sent after it finds the name gone, in the order the
     requests were sent; only its clunk waits, and the `remove` is answered
     after it with what the unlink answered. A request that names a closing fid fails with
     `ebadf`. So no request waits on an open the tree has closed; the
     clunk runs after every request sent before it through the fid,
     since the grant had run each of those to its answer or handed it to
     its keeper before it took the clunk; a close reports what the tree
     could not commit, after the reply of every request sent before it,
     which is `eintr` for one that was still waiting; and a keeper slow
     to answer a begun request delays that one clunk and nothing else of
     the grant. The fid has ended whatever the answer, as clunk(5) says,
     and keeps its number until the answer is sent, so a walk that
     would reuse the number before then fails with `einval`, as one
     that meets any live fid does. Every clunk takes this path, at any
     bound ([Bounds](#bounds)): a client's, a refused `remove`'s, which
     answers its refusal once the clunk has run, and those the grant
     makes itself, at a fid owner's `DOWN` and while it drains, whose
     answers it drops. A flush of a clunk the grant holds is a flush of
     a request whose answer is still to come: the grant answers it after
     the clunk's answer, and it neither stops the fid's settling nor
     runs `clunk` again.
  6. **The keeper's end answers its requests `eio`**: the grant's monitor
     fires for each request the keeper held, as a window that has ended
     answers `EIO` ([design-display.md](design-display.md#the-window-tree));
     for a begun request, `eio` says that what its effect did is not
     known.
  7. **The grant's end drops its requests at the keeper.** Holding a
     request (`erx_fs_waits:hold/2`) monitors the grant that sent it,
     once for all of that grant's requests, and the grant's `DOWN` drops
     every request it sent, waiting or begun, so no request of a grant
     that crashed takes bytes the next reader should have. An effect
     already begun runs to its end, and its answer then finds nothing to
     answer. A keeper that passes requests on to another server ends
     with the grant that sent them and with the owner of the fids it
     sends them on, so no request it passed on outlives its asker at
     that server, where it would take the next reader's bytes: a
     program's draw connection, the one such keeper, shares one life
     with its program's handler, `/dev` grant and window ([A program's
     window](#a-programs-window), "Ownership and lifetime").

  A keeper's obligations, to answer once, to answer a flush of a request
  not yet begun at once and to drop what an ended grant sent, live in
  that one module; the keeper adds only its decisions of when a request
  begins, when it is done and with what.

  **What waiting holds.** Every request a keeper holds is one of its
  client's requests in flight, and stays one until the grant sends its
  reply, which follows the `answer/3` that forgot it, so a keeper holds
  at most 64 requests for each grant it serves and one monitor for each
  grant with a request there, and a grant holds one monitor for each of
  its requests at a keeper. What a keeper keeps for a request is its
  tree's `Request` term, at most a request's 64 KiB of bytes and the
  names that route it. A keeper runs under its own `max_heap_size`,
  which its tree sets from those counts
  ([design-display.md](design-display.md#the-window-process),
  [design-bluetooth.md](design-bluetooth.md#the-controllers-line)); a
  grant's heap bound counts only the grant's own process. A grant whose
  client has ended **drains**: it takes no frame from then on, clunks
  every fid by rule 5 and ends once the last clunk has run, so nothing
  of it outlasts the effects its keepers had begun. Until it ends it is
  one of its server's grants, its process, its heap and its requests at
  keepers counted as a live grant's are, so a client that ends and
  comes back holds its old grant's share beside its new one until the
  old one has drained. A grant that crashes promises no callback: its
  keepers drop its requests (rule 7), and the tree and the lock table
  release what they keep for it at its `DOWN`, as the tree drops its
  holds. A process that passes its heap bound is killed, and its end is
  handled as above, a keeper's by rule 6 and a grant's by rule 7.

  The grant's decisions are its pure core, `erx_fs_grant`, which takes
  each frame, callback result, keeper's answer and `DOWN` and returns
  the next state and the effects to perform (answer the client, run a
  callback, monitor a keeper, send it a request or a flush), so the
  orders of rules 4 and 5 are properties of one function, which the
  tests explore exhaustively ([Verification](#verification-and-testing)).
  A callback that waits for an event itself, in a `receive` or in a call
  that its callee answers only at an event, is the defect this
  construction replaces; a tree's review checks its `read` and `write`
  for one.

  **Trust.** A keeper is a process of the server's own runtime (rule 1),
  inside the server's trust boundary as its tree's callbacks are ([Who a
  grant is for](#who-a-grant-is-for)). These rules give every client
  exactly one answer from a correct keeper, and the single-use alias
  holds even a faulty keeper to one answer for each request, but nothing
  holds a keeper to the right answer, or to answering a begun request at
  all: a keeper that never answers holds its own requests, their
  flushes, their fids' clunks and the slots of their grants, and, once
  such a grant's client has ended, the grant's process, and nothing else
  of any grant.
* **Each tree makes its own requests atomic.** The grants of one tree
  call it concurrently, each from its own process, so a request is
  atomic with respect to the requests of other grants, as POSIX asks of
  regular files ([Open files and offsets](#open-files-and-offsets)),
  because the tree makes it so, and each tree's design states how:
  `/tmp`'s grant, the one process its own tree lives in, runs every
  request as one step ([design-tmp.md](design-tmp.md#concurrency)),
  littlefs's worker runs
  one operation of the volume at a time
  (`erlang/apps/erx_storage/src/erx_lfs.erl`, its module documentation),
  and F2FS's volume runs one request at a time
  ([design-f2fs.md](design-f2fs.md#processes-and-ownership)). Within one
  grant the order is the grant's, which runs one callback at a time.
  Atomic is not enough: **every open of a file sees the file as it
  is.** What an open keeps of its own is its access mode and, in a tree
  that keeps one, its position; the file's size, blocks and bytes are
  the file's, which every open reads, so a read through one open
  answered after a write through another sees that write, as OTP's
  `file_SUITE` checks through a reader opened before the writes.
* **A handle, or a tree of the grant's own.** `init/1` answers once for
  each grant, in one of two forms. `{ok, Fs}` is a handle to a tree
  kept elsewhere, in a process of its own or on its medium, where
  every grant of the tree reaches the same tree. It never changes:
  every callback receives it and answers only its result, never a
  next state, so no callback can leave its grant a copy of the tree
  that the others do not see. A tree may put a grant's own context in
  its handle, as the window tree puts its client and its grant
  ([design-display.md](design-display.md#the-window-tree)), and sees
  each request with that context. `{own, Tree}` is a tree value that
  `init/1` made from its arguments, so no process but the grant holds
  it: every callback receives the current `Tree` in the handle's
  place and answers `{Answer, Tree1}`, `forget` `{ok, Tree1}`, and the
  grant keeps `Tree1` for its next callback. The grant is then the
  tree's one process, so each request is atomic because the grant
  runs one callback at a time, and a callback costs no message: a
  request costs the client's message and the reply. An own tree is a
  tree per grant, since each grant's `init/1` makes its own; it suits
  a tree that has one grant by construction, as `/tmp` has, whose
  one grant, the domain's own, serves every reader in the domain
  ([design-tmp.md](design-tmp.md#where-tmp-runs)). A tree that several
  grants reach keeps the handle form. An answer that is none of its
  callback's shapes, a next state appended to a handle's answer
  included, reaches the client as `eio`; an own tree's pair whose
  `Answer` is none of its callback's shapes reaches the client as
  `eio` and the grant keeps its `Tree1`, and an answer that is no pair
  is a fault of the module, which ends the grant, as the crash of a
  tree's process ends the grants linked to it. A callback keeps no
  state in the process that calls it but an own tree, which the grant
  holds and passes in, and an answer turned into `eio` does not undo
  what the tree did.
* **Checks before callbacks.** Every message a grant receives, but the
  `DOWN`s of its fid owners and keepers and its keepers' answers, passes
  one decoding funnel, which takes the frame and
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
  either travels in the reply that records it (attach, a walk of names,
  `lcreate`) or is the root's, which the grant's start admitted before
  the grant took any request (a walk from `NOFID`, whose reply lists only
  the qids of the names it walked; [Version and
  attach](#version-and-attach), "The root is admitted when the grant is
  made"), so a malformed qid leaves no fid or open behind. `lcreate`
  checks its reply before it records the open, and clunks at once a
  handle the tree opened for a reply the check rejects, since no fid
  holds it. A request that fails is answered
  with an error and counted; it never reaches a callback.
* **Bounded work on the server's grant.** A grant process runs on its
  server's own group, as every process of the server does; no client's
  time is lent to it ([design-scheduler.md](design-scheduler.md#service-work)).
  Its own steps are bounded by the grammar: no loop over client-sized data
  outside the decoder, and a payload of at most 64 KiB. Work that depends
  on a medium runs in the grant's callback, so a slow medium delays that
  client's later requests and no other client's; work that waits for an
  event waits at its keeper and runs in no process until the event
  comes; and the server's runtime schedules its clients' work among them as it schedules
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
* **Made trees.** A tree whose server makes its nodes from state it
  reads rather than keeps on a medium (`/proc`, `/dev`, `/apps`,
  `/machine` and a display's window tree) takes what such trees share
  from `erx_fs_node`: every node owned by uid 0 with size 0 and no
  times, a directory with two links and a file with one; a directory
  whose listing is the entries its open took, each entry's offset its
  place in that listing,
  so a listing never skips or repeats an entry the tree added or removed
  meanwhile; and a statfs that holds no blocks.
* **Flush.** When the grant takes a flush, the request it names has
  been answered, since the grant runs each callback to its answer
  before it takes the next frame, or its answer is still to come, from
  the keeper that holds it or, for a clunk behind its fid's requests,
  from the grant itself. One answered needs nothing, and the flush is
  answered at once. The flush of any other is answered after the
  request's one reply ([Flush](#flush)), and one a keeper holds is also
  sent there (rule 4 of waiting requests), so the keeper can answer it
  `eintr` at once if it has begun nothing.
* **Freezing.** A freezing checkpoint, which the system domain asks of a
  storage service before a trial or a reset, closes mutation admission at
  every grant, lets each grant finish the writes it admitted, and only
  then lets the module checkpoint and the block driver flush; it answers
  every later write `erofs` until the machine ends
  ([design-storage.md](design-storage.md#interfaces)).

Every file server is such a module: the storage services, erXos's F2FS
and the littlefs port among them
([design-storage.md](design-storage.md#read-write-storage)), the FAT
server, `/proc`, `/dev` and a session's export. So one implementation of
the protocol's decoding and checks stands in front of every tree, and
every grant is a process that can be inspected,
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
when the resolution started: `Tree` is the grant's tree, the numbering
of its files' qid paths, which keys the identities of the files the
client reaches through it and which no request carries, since a grant
reaches files of exactly one tree
([Building, binding and mounting](#building-binding-and-mounting),
"The tree beneath an entry"), and `rights`
is the entry's `ro`, `rw` or `rx`, so a read-only bind of an `rw` grant
reaches its client read-only and the client never sends a request that
writes through it. Every request the client sends passes one function,
which makes the two refusals the client's own properties rest on:
it refuses with `erofs`, sending nothing, a request that
the generated grammar's `writes/1` marks as writing when the entry's
rights are other than `rw`, as the grant's own funnel refuses it for
the grant's rights; and it refuses with `einval`, sending nothing, a
walk that names `.`, `..` or an empty name, so no walk a client sends
carries one, whoever built it (F2, F3, F11). It also enforces one
limit of the transport, which is not a check of the grammar: a request
whose message, encoded as a frame's payload, passes
`files_max_frame_min` is refused with `einval`, sending nothing,
since a grant of another domain is reached through frames, every domain that serves or holds a `files` grant takes frames
of at least that size (property 16 of design-system.md), and a longer
one is dropped there without a reply
([design-domains.md](design-domains.md), "Payload size"), which would
leave the caller waiting for ever. The bound holds a write of the
64 KiB transfer unit with its encoding, so it refuses only requests
the grant's funnel refuses `einval` for passing the grammar's bounds,
and it holds for a grant of the client's own domain too, so the answer
does not depend on where the grant is served. It does not check the rest
of a request against the grammar: every request comes from code of the
client's own domain, the client's operations or a caller of
`erx_file_remote:exchange/2` and `send/2` such as `erx_win`, and the
grant's funnel decodes every frame against the grammar before any
callback sees it and answers a malformed one `einval`
([Failure handling](#failure-handling-diagnostics-and-debuggability)),
so a malformed request, a read whose count passes the protocol's bound
among them, is refused by the server and reaches its caller as that
ordinary `{error, einval}`. The grammar, `erx_9p_grammar`, is preloaded
with the client, and the two generated functions the client calls on
every request are total, so neither assumes a request the client
checked:

* `writes/1` reads only a term's operation and the field the table
  marks: it answers `true` for a term of an operation the table marks
  as writing whose marked field, where its rule reads one, is an
  integer of the field's kind and matches the rule, and `false` for a
  term of no operation and for one whose marked field fails its kind
  or its rule; it never raises. Since it checks no other field, it
  answers `true` for some malformed requests of a writing operation,
  and no answer for a malformed request lets anything write, since the
  grant's funnel refuses that request `einval` before its own rights
  check, so a `true` only refuses it sooner;
* `decode_reply/2` holds a reply to its request and never raises: an
  error reply `{error, Posix}`, `Posix` one of the table's errors, is
  answered as it is whatever the request, since it states only the
  server's refusal; any other reply is answered only when the request
  is one the grammar accepts and the reply has its operation's shape and
  holds to it by the operation's checks, such as a read's data no
  longer than its count; every other pair is `{error, eio}`. So a
  server's refusal of a malformed request stays the caller's ordinary
  error, and no reply is taken on the bounds of a request the grammar
  refuses: a reply that is not an error, to such a request, is `eio`.

The reply check keeps all its bounds; what the client sheds is the
validation of each request before its send, and `decode_reply/2`
validates a request only for a reply that is not an error. The server's
own uses are unchanged, since the grant and the host link's bridge hand
`decode_reply/2` only requests the grammar accepted. The client walks an action's names, whose first are the
entry's `root` names, from `NOFID`, the grant's root, into a new fid
([Version and attach](#version-and-attach)), and never sends `attach`.
The client is the resolver's executor:
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
  `write_file`), at the resolver's target or parent action, walk from
  `NOFID`, the grant's root, into a new fid of their own for each path
  they name, act on those fids and clunk them, the requests
  sent together, so each operation's fids are the calling process's from
  first to last ([Fid owners](#fid-owners)) and the operation holds no
  fid on the root. The operation names only
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
* `open` without a mode that creates is a target: it walks the names
  from `NOFID` into a new fid and opens that fid with `lopen`; with one (`write`, `append`,
  `exclusive`), it is a parent: it walks the last name's directory from
  `NOFID` into a new fid and
  sends `lcreate` on it, which creates the file or
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
  live client abandons, which only a relay does, for its own client's
  request: a 9P bridge for an edge client's, and a program window's
  draw connection for a program's `kbd` or `mouse` read; no other
  Erlang client or native program of erXos sends one ([Flush](#flush)). A server that dies while files are open turns their next
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
description's offset, copies the reply's bytes into the slot through the
program's port, within that slot, and answers the count, after which `liberx` copies the slot into the
caller's buffer, never more than the count it asked for, and frees the
slot. A `write` copies the caller's bytes
into a slot first and the handler copies them out into the `write`
request. A request that names a slot past the program's `slots` is
refused with `EINVAL`. A thread that finds no free slot waits for one, so a program's
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
its open other references sends `{file, close, Open}`, once the program has
taken a record lock, and the open's last reference sends `{file, clunk, Open}`,
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
standard streams that reach the terminal are opens on it. The export
serves `tty` as a name only, which a walk and a `getattr` reach, and
answers an `lopen` of it with `enxio`: the handler that opens the name
makes a terminal's description instead, with an open of the terminal
relay under its program's job, and the terminal's reads, writes, waits
and controls all go to the relay, none through the file protocol. So a
terminal read never waits at a server, and no `flush` ends one: a
program waits for input with a watch and then reads, and a signal ends
the watch ([design-programs.md](design-programs.md#the-terminal)).

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
  the client domain (`client`, `own` or the domain's id), the grant's
  pool (`pool`), its bounds on requests in flight and message size
  (`in_flight`, `msize`) and its process's heap (`max_heap_size`), and
  what the grant ends with (`ends_with`, which the grant monitors, so it
  ends at that end whatever its reason: for another domain the port of
  the connection to the client or, in the system domain, which holds no
  such port, the client's domain pid; for its own domain a process of
  the domain whose end ends it, as a program's handler ends its `/dev`
  tree ([A program's window](#a-programs-window)); or `none` for a grant
  that lives as long as the server's domain), the export table it exports
  itself through before its start returns (`exports`) and the tree's
  lock table (`locks`, absent for a grant that is a tree of its own,
  which starts its own); every file server is one. Both answer
  `{ok, Pid, Tree}`, the grant's pid and the name of its tree, from its
  callback module's `root`, which they call and admit before the grant
  takes any request, failing the start on an answer the check refuses
  ([Version and attach](#version-and-attach), "The root is admitted
  when the grant is made"); it is the one source of an
  entry's tree ([Building, binding and
  mounting](#building-binding-and-mounting), "The tree beneath an
  entry"). A keeper keeps its
  waiting requests in `erx_fs_waits` and answers them only through it:
  it holds a grant's request and monitors that grant once for all its
  requests, marks a request begun, answers a request to its alias and
  forgets it, takes a flush or a grant's `DOWN` and says whether the
  flush still needs the keeper (a begun request's first flush, which the
  keeper's answer settles), and lists its requests in arrival order
  ([Serving](#serving-the-erx_fs-behaviour), "Waiting requests"). The
  three messages between a grant and a keeper, a request to wait, a
  flush and an answer, are defined once, in `erx`'s header
  `erx_fs_waits.hrl`, which `erx_fs`, `erx_fs_waits` and every keeper
  include.
  `erx_fs_locks` is a tree's lock table, a keeper of the grants' `lock`
  and `getlock` requests: `start_link/0`, and the release of a fid's
  locks a grant sends it at the fid's clunk ([Locks](#locks)).
  `erx_fs_grants` supervises the grants of one tree that a files service
  hands to other domains, and the tree's lock table before them,
  `rest_for_one`, so the table's end ends them ([Locks](#locks)):
  `start_link/2`, and
  `grant/3`, which starts one grant bound to a client with the options
  a facet row's limits give it (`grant_options/1`).
  `erx_fs_version:init/0` makes the domain's
  file version counter and `erx_fs_version:draw/0` draws from it
  ([Identity and version](#identity-and-version)).
* **The file protocol**, 9P2000.L, as a **frame profile**,
  `abi/protocols/9p.txt`: the operation table, with each message's fields,
  bounds, 9P2000.L layout and whether it writes, from which a Ruby
  generator produces the Erlang decoder that `erx_fs` and
  `erx_file_remote` use, the refusal set of F5, the per-operation reply
  checks of [Bounds](#bounds) and `erx_9p`, so every
  client, server and edge shares one definition; server callbacks keep
  file semantics and authorization decisions
  ([design-generation.md](design-generation.md)).
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
| Storage | the storage services and the media domain, in Erlang, serve the data partition's files and drives' volumes through `erx_fs`, behind each principal's facet ([design-storage.md](design-storage.md), [design-drives.md](design-drives.md)) |

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
`EMLINK`, as FreeBSD's does, where Linux and macOS answer `ELOOP`; one
with `O_DIRECTORY` of anything but a directory answers `ENOTDIR`, with
`O_CREAT` and `O_EXCL` too `EINVAL`, and with `O_CREAT` alone it creates
nothing, as FreeBSD's `vn_open_cred` has them; a
page of a shared mapping wholly past the file's
end reads zeros rather than raising `SIGBUS`; the `munmap` whose
write-back fails returns `EIO`; and two sessions that map one file shared
each hold their own copy, which meet at the server page by page as each
writes back ([Shared mappings](#shared-mappings)).

The protocol is 9P2000.L as specified, so a 9P2000.L client or server
from elsewhere meets it at an edge unchanged; inside the machine a
`version` resets nothing, a walk from `NOFID` starts at the grant's root
([Version and attach](#version-and-attach)), and
`write`'s reply carries the offset its bytes landed at ([Open files and
offsets](#open-files-and-offsets)), the three deliberate differences, and
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
| A slow medium | none: the request waits | the request in its grant's callback | none | a wait, as on a local file system, behind which that client's later requests wait; an edge client's interrupt flushes it, and the flush is answered after the request |
| A stream file has nothing to read | none: the read waits at its keeper | the request at the keeper, counted in flight | none | a wait; the grant's other requests, its clunks and its flushes go on meanwhile |
| A flush or a clunk reaches a request its keeper has begun | the keeper's `erx_fs_waits` mark | the request at the keeper until its effect ends | none | the flush, or that fid's close, waits for the effect, within the bound its tree states from its drivers' deadlines, and the request is answered with what it did |
| A clunk or a `remove` arrives with the grant's window full | none: it is admitted at any bound | the fid until its requests are settled | none | the clunk's answer after its fid's requests' answers; a refused `remove` answers its refusal then |
| A tree's lock table ends | the `rest_for_one` supervision of `erx_fs_grants`, or a lone grant's link to its table | nothing: every lock of the tree ends with it | every grant of the tree ends before a new table takes a request | each client sees its grant end, as below |
| A keeper ends with requests waiting | the grant's monitor on the keeper, one for each request | nothing | the grant answers each of them | `eio` on each waiting request |
| A grant ends with requests waiting at a keeper | the keeper's `erx_fs_waits` monitor on the grant | nothing | the keeper drops every request that grant sent | none: the grant's client has ended or sees the grant's end |
| A server dies, or a grant ends | the client's monitor on the grant, which the connection's end also fires | nothing at the server | the client marks its fids dead | `eio` on every open file of that grant; the mount stays, so a restarted service can be mounted again |
| A client process ends | the grant's monitor on each fid owner, whose `DOWN` follows every request the owner sent ([Fid owners](#fid-owners)) | nothing | the grant clunks every fid the process owned, which releases their locks and, for an open file, the file's open | nothing |
| A client domain dies | the connection going down, which ends every export across it and fires the grant's monitor on the client ([design-domains.md](design-domains.md#connections)) | nothing | the grant clunks every fid it holds, which releases their locks | nothing |
| A program ends | its handler, which owns the port | nothing | the handler unlocks every lock of the program's `ProcId`, closes its share of every description and tells each mapper of a file it mapped | a log line for a failed write-back |
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
  only over the program's own table and walks only below the roots of its entries (F3).
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

Every test names the fault seeded into it, which it must report, so a
passing run shows the code under test ran. The approach has five parts:
oracles for behavior, fuzz targets for every parser of untrusted input,
exhaustive models of the protocol state machines, source checks for the
chokepoints, and hostile-client and hostile-server tests for the bounds
and the invariants.

**Oracles.**

* **FreeBSD's lookup.** The resolver is compared with a reference model:
  a direct transcription into Erlang of FreeBSD's `vfs_lookup`, written
  from `sys/kern/vfs_lookup.c`, which keeps a current directory node with
  its parent, takes `..` through the node's parent, crosses an entry's
  top back through the node its mount point covers, stops at `/`, follows
  a last link under `FOLLOW` or `TRAILINGSLASH`, and refuses a last `.`
  or `..` of `DELETE` and `RENAME` once the name before it is found to be
  a directory. That last rule departs from `vfs_lookup`'s text: FreeBSD's
  slow lookup refuses such a name before it checks the name before it,
  while its lockless name-cache lookup checks that name first and, by a
  reading of its source not yet run on FreeBSD, can hand the parent on to
  `rmdir` or `rename` for a last `..`, so FreeBSD answers one path
  differently by what its cache holds. The model takes the cache lookup's
  order and the answers that rmdir(2), rename(2) and unlink(2) document.
* **9P2000.L.** Under QEMU the machine mounts a host directory through
  virtio-9p, so QEMU's 9P2000.L server checks erXos's client side, and
  runs OTP's `file_SUITE` over it, the offset rule for `At` = `unknown`
  among its cases. Linux's own 9P2000.L client in the oracle guest mounts
  an erXos server through the host link's bridge and runs a
  file-semantics corpus, compared with the same corpus on a Linux
  `tmpfs`, and independent byte fixtures check the generated codec
  ([design-generation.md](design-generation.md)). Seeded: a server that
  answers a `walk` of `..` at its root with the parent's qid, which both
  catch.
* **Stock OTP.** OTP's `file_SUITE` and `filelib_SUITE` run with their
  working directory on an `erx_fs` server backed by a RAM tree, compared
  case by case with the same suites on a local mount; every difference
  is one listed under [Compatibility](#compatibility-and-migration).
  Hosted, `tools/erx oracle hosted` compares them with stock OTP 29.1.2
  on the development host; its list of known differences holds a case of
  `.`, `..` or links only where macOS answers otherwise than FreeBSD, its
  row naming FreeBSD's answer, and a listed case that agrees with stock
  fails the comparison. The cases of the first bullet under
  [Compatibility](#compatibility-and-migration), which no case of either
  suite reaches, are compared by [/tmp's oracle
  cases](design-tmp.md#verification).
* **Native programs.** toybox's own tests for its file applets
  ([design-programs.md](design-programs.md)) and musl's `libc-test` file
  cases run with each program served by a handler over an `erx_fs`
  server.

**Fuzz targets**, each built for the host and run by `make check-fuzz`:

* `erx_path`, in Erlang: a random model tree (directories, files, and
  relative, absolute, empty and looping links), a random table over it
  (entries, binds with roots, a narrowed table with no `/`), a working
  directory and random paths of plain names, `.`, `..`, doubled and
  trailing `/`, each with a random `nameiop`, `FOLLOW` and `WILLBEDIR`,
  compared with the FreeBSD model above. The same target feeds the
  resolver's untrusted inputs raw (paths and link texts of arbitrary
  bytes, NUL, invalid UTF-8, empty and over every bound; walk replies
  longer than their walks), each answered with an error and never a
  crash; changes the namespace's persistent term from inside a walk
  callback; and checks the properties: no walk names `.`, `..` or an
  empty name, every walk lies at or below its entry's `root`, a place
  never outgrows its bounds, and every action names an entry of the
  table the resolution was handed.
* The release NIFs' decoder of name lists, under AddressSanitizer:
  arbitrary terms, 257 names, names holding `/`, NUL, `.`, `..`, invalid
  UTF-8 or 256 bytes, each answered `einval` without reaching the core.
* The frame profile's server and client decoders and `erx_9p`: every
  operation round-trips term to bytes and back, and a size past `msize`
  or the bytes received, a string past its message and a count past what
  remains are each refused.
* `erx_file_remote`'s exchange, driven with random messages: a reply bare
  or in one envelope is taken and held to its request; one at another
  alias, in two envelopes or of another shape is not.

**Exhaustive models.** A grant's fid table under every request, walks
from `NOFID` among them, and every owner's end, up to depth 6 (F10). The grant's core, `erx_fs_grant`, with
a model keeper, over every order of requests that wait and that are
answered at once on two fids with equal handles, a request the keeper
begins, flushes of waiting and answered requests, a clunk and its flush,
a walk that reuses a clunked number, the keeper's answers, a second
answer, the keeper's end and the client's end; its properties are the
rules of [Flush](#flush) and "Waiting requests": every request answered
exactly once, a flush after its request, nothing of a fid waiting once
its clunk has run, a begun request answered only with the keeper's answer
or `eio`, each fid's `clunk` callback once after its last request, and a
fid number free only after its clunk's answer. One mapper, its object and
its server under interleaved stores, reads, writes taken whole, in part
or not at all, extensions, truncations, failed fills and write-backs, up
to depth 8, against a flat file (F7).

**Source checks** of [design.md](design.md#chokepoint-checks), each with
a seeded violation: only `erx_ns`'s process writes the namespace's
persistent term; only `prim_file:set_cwd/1` calls the NIF that stores the
working directory; `erx_file_remote` sends a request only from its one
request function.

**Hostile clients, servers and programs.**

* F1 to F3 and F9: a mounted pid the domain was not introduced to reaches
  nothing; a program given `/data/logs` reaches nothing of `/data`
  outside `logs` through `..`, links or other programs' file numbers;
  a program's sub-space holds only its channel, data area, pipe ends and
  mapped memory; a starter's table with a display facet mounted and bound
  elsewhere gives the program nothing of the display.
* Walks from the root: a walk from `NOFID` of no names, of names and of
  `..`, on a grant rooted at its tree's top and on a home grant rooted
  at one user's home, each answering the qids and making the fid that an
  `attach` and a walk from its fid make, and `..` from it staying at the
  grant's root (F2); a walk whose `NewFid` is `NOFID`, and `NOFID` as the
  fid of any other request, refused with `einval` before the grant's
  dispatch, making no fid; a host's walk from `NOFID` at the host link's
  bridge answered `ebadf`, while the host's ordinary walk from a fid it
  attached is renamed and relayed and answers the grant's qids, and the
  host-tree bridge's relay of an erXos client's walk from `NOFID` reaching
  QEMU's server as a walk from the bridge's root fid; an Erlang `open`
  and `close` of a file on a grant sending exactly a walk, an `lopen` and
  a `clunk`, counted at the grant.
* The root: a tree whose `root` answers a qid that is not a directory,
  or a malformed qid or tree name, fails the grant's start, so no grant
  takes a request; a walk of no names from `NOFID` on a well-formed
  grant makes a fid whose `getattr` answers the root, and once the
  tree draws the root a new version, that `getattr` and an `attach`'s
  reply at the edge carry the new version, not the start's.
* Trees: two facets of one tree, one `rw` and one `rx`, mounted at two
  points of a session, through which a file mapped from both points has
  one mapper (P14); overlapping grants with different roots, root's
  development session holding the `data` facet at `/data` and its
  `home` facet at `/root`, through which `/data/root/notes` and
  `/root/notes` give one identity, one mapper when mapped shared from
  both paths, and one file object when run from both; the host link's
  bridge, given `data` and `proc`, relaying the host's `attach` of
  `data` to the grant at `/data` when a `packages` grant, which names
  the same tree, lies ahead of it in the table.
* Programs and displays (F3), each with a program started before the
  event and resolving after it: a display facet mounted at `/mnt/w`
  before its grant is installed, the installation arriving after the
  program started, after which the program finds nothing at `/mnt/w`
  and the session reaches the display; a display facet replaced by its
  display's new incarnation, and a files facet replaced through
  `erx_domain:grant/4` by a display under the same name, after which the
  program reaches neither display; a display installed through `grant/4`
  under the name `notes`, mounted at `/n` and bound at `/dev/w`, of
  which the program reaches nothing; and a stand-in window server whose
  `root` names its tree `files`, which programs still do not reach.
* Client errors: an `erx_win:send_read/4` whose count passes the
  protocol's bound, and an `erx_file_remote:exchange/2` of a malformed
  `lopen`, each answering the caller `{error, einval}` from the server,
  not raising; an `ok` reply to such a request answered `eio`; `writes/1`
  answering `false` for a term of no operation and for a write-marked
  operation whose marked field is not an integer.
* F4: fid floods, lock floods, retained `/proc` results, clients that
  never read their replies, 100,000 short-lived owners after which the
  grant holds no monitor, a flood of a tiny slow request that delays only
  its own client's grant, and a window of 64 waiting reads that holds no
  server process beyond its grant and the keeper and can still be flushed
  and clunked.
* F5 and F6: every writing operation through an `ro` and an `rx` grant,
  refused before its callback by a refusal test generated from the
  operation table; running a file through an `ro` or `rw` mount, through
  an `rx` mount of the session's `data` facet, and through an `rx` EROFS
  mount of a file of `/apps`, each refused.
* Envelopes and owners: frames in a third domain's envelope and bare
  frames at a grant for another domain, dropped and counted; owners named
  on another's behalf that have already ended, whose fids still end.
* A hostile tree: callbacks that answer malformed qids, errors 9P2000.L
  does not carry, improper listings or extra state, each answered `eio`
  with nothing kept and the grant still serving; an operation whose
  directory fid names a file, answered `enotdir` before any callback.
* A hostile server: replies longer than their requests, failed with
  `eio` by `erx_file_remote` and by both bridges, and a handler that
  answers a program a larger count, which `liberx` clamps.
* Locks: contention between two programs of one session and between two
  domains through two grants of one tree; release by unlock, clunk, the
  grant's end, the program's close of any descriptor of the file and the
  program's end; a lock that survives an `F_SETFL` change of `O_APPEND`;
  a `ClientId` that releases nothing; and the lock table killed under a
  granted lock, after which every grant of the tree has ended before the
  restarted table answers.
* A program's window and `/dev`: the window's `ctl` and directory are
  never reached from the program's tree; a table that would put an entry
  under the window's names, or that lacks write at `/dev`, is refused at
  the start; a window removed and re-created under a running program
  takes no request from it; no window file passes by a descriptor; a
  resize reaches the program through the real path; and the window, the
  connection and the tree's grant end with the program or a refused
  start.

**Seeded faults**, each caught by the case or property named:

* resolver: a `..` that removes a run's name before its walk
  (`missing/..`); `..` taken before the link ahead of it (`link/..`, and
  `filelib_SUITE`'s `wildcard_one` and `wildcard_two`); a walk of `..`
  past a bind's root (the walk property); a last `.` of `DELETE` answered
  before the name before it is checked (`file/.`); a link's text taken
  unchecked (a text holding NUL); the namespace's term read again at a
  link (the change made inside a walk); a last link followed only under
  `FOLLOW` (`del_dir("dlnk/")`); a working directory stored as written
  (`get_cwd` after `set_cwd` through a link);
* client: a request function without its refusal of `.` and `..`, or
  without its `erofs` refusal (a write through a read-only bind of an
  `rw` grant); a client that attaches before it walks (the count of an
  open's requests); an
  operation sent with a walk whose names still needed a check; replies
  taken only bare, or another alias's taken out of an envelope; the
  numeric offset rule applied to `At` = `unknown`; one operation's reply
  check removed from the generated table; a codec without its size check;
  a name decoder without its count check; a `decode_reply/2` that checks
  the request before an error reply (the oversized `send_read/4`, which
  then raises), or that takes an `ok` reply to a request the grammar
  refuses (its `eio` case); a `writes/1` with a clause for each
  operation and none for other terms (its `false` cases, which then
  raise);
* grant: a fid kept after a failed walk; a later fid made for an ended
  owner without monitoring it again; an owner's monitor kept after its
  last fid; a frame taken out of any domain's envelope; a clunk answered
  `ok` before the tree's `clunk` ran; a fid counter that hands out the
  lowest free number; a protocol table that marks a directory fid
  `node`; a flush answered before its request, or a flush of a waiting
  clunk answered at once; a fid's number freed when its clunk is taken;
  waits keyed by handle; a grant that does not monitor its keeper; an
  alias without `reply_demonitor`; flushes or clunks counted in the
  requests' window; a server that runs every grant's callbacks in one
  process, or each waiting read in a process of its own; a walk from
  `NOFID` started at the tree's top rather than the grant's root (the
  home grant's walk of `..`); a profile that gives a walk's `NewFid` the
  source's role (the walk whose `NewFid` is `NOFID`); a walk's source
  declared a plain `u32` rather than a fid of role `start` (the host's
  ordinary walk, which the bridge then answers `einval`); a host link
  bridge that passes the host's `NOFID` through to a grant (its `ebadf`
  case); a start that skips its check of `root` (the root whose qid is
  not a directory, which then serves); an `attach` that answers the
  qid the start admitted (the version case);
* trees: a facet entry whose tree is its facet's name (the two facets of
  one tree, which then have two mappers); an `erx_lfs` whose `root`
  answers the service's name, `home` (the overlapping grants, which then
  give `/data/root/notes` and `/root/notes` two identities and two
  mappers); a host link bridge that selects a grant by its tree's name
  (the bridge case, which then relays `data` to the `packages` grant
  ahead of it in the table);
* programs and displays: the exclusion decided when the program's table
  is built (the delayed installation, which then exposes the display);
  the exclusion read from the ready answer's names alone (the `grant/4`
  display under `notes`, which then passes); the exclusion read from the
  tree's name (the stand-in window server whose tree is `files`, which
  then passes); an installation that carries no interface, its facet
  taken as not of `windows` (the replacement through `grant/4`, which
  then passes);
* waiting requests: a tree whose `read` waits inside its callback,
  which makes a write on the same grant miss its deadline; an
  `erx_fs_waits` whose `info/2` ignores a flush, that answers a begun
  request `eintr` at its flush, that does not monitor the grant, or
  whose `answer/3` leaves its entry; a keeper that holds a read while it
  holds bytes; a grant that runs a clunk while its fid's read still
  waits, takes no other frame while a clunk waits, ends at its client's
  end without its fids' clunks, checks only requests' aliases, or
  answers a second flush `ok` at once;
* reply checks and hostile trees: a grant that keeps what an operation
  built when the reply check rejects the tree's reply, undoes a remove's
  clunk then, or leaves a rejected `lcreate`'s handle open; a listing
  check that crashes on an improper tail; a grant that takes a
  directory's `make` answer for a file's, or crashes on an answer that
  is not an error; a server that follows a link during a walk; an export
  that opens `/dev/tty`;
* locks: a table restarted alone, `one_for_one`; a table kept in each
  grant; a table that keeps a killed grant's locks or keys locks by
  `ClientId`; a handler that leaves a program's locks to the
  description's clunk; a `liberx` that reports only an open's last
  reference;
* rights: a resolution that keeps the rights a facet's mount asked; an
  EROFS mount whose rights come from its options alone; an operation removed from the table's writing marks;
* program tables and windows: a handler that walks the raw path or sends
  a `..` at the program's top; a join that asks the grant first or lists
  a name twice; a check that refuses only exact points under `/dev`; a core that admits a
  table whatever its rights at `/dev`, or measures against the deepest
  entry covering `/dev`; a
  table builder that drops the display's mount by its point; a tree that
  relays any name to the window's directory, or walks each relayed open
  by name; a `start/1` that admits a passed file into the open table; a
  draw connection that answers a `mouse` read without making image 0
  anew; a grant started without `ends_with`; a fork that copies the
  shared tree's `/dev`;
* descriptions, identity and mappings: an offset taken from a `getattr`
  after an append; an `lcreate` without the qid comparison; a version
  counter kept in the server's process; a file table keyed without the
  tree; a path table that evicts when full; a grant that ignores
  `Aname`; a read of a mapped file relayed past the mapper; a filled
  extent moved before its reads complete; a write copied into the object
  before the server answers; zeroes written up to an extending write's
  size; an object deleted before its last write-back; an `erx_mem_dirty`
  that clears a mark it did not report; a mapper that fills the object
  through a mapping of its own.

The stream trees that use waiting requests run their own cases over a
real grant ([design-display.md](design-display.md#verification-and-testing),
[design-bluetooth.md](design-bluetooth.md#verification)).

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

**A request inside the domain.** A request to a grant of the caller's
own domain crosses no connection: it is one message to an alias of the
grant and one reply to an alias of the caller, the grant's funnel and
reply check, and the client's two refusals and reply check. A callback
of a tree kept in a process of its own adds a round trip to that
process with a monitor; a callback of an own tree adds none. An
operation's requests go together, so each operation is one exchange
whatever its count of requests, and the client sends no `attach` and
clunks no root fid ([Version and attach](#version-and-attach)).
Measured with `tools/erx bench posix` under HVF (Apple M3 Max, QEMU
11.1.3, Homebrew clang 23.1.3, landing profile;
[research-file-call-path.md](research-file-call-path.md)), the one
request of a program's `fstat` of a `/tmp` file, the description's
`getattr`, cost 5.4 us of the call's 16.1 us, with `/tmp`'s tree in a
process of its own and the client checking each request against the
grammar; and a program's `open` spent 38 us of its 50.6 us in the
description's open, one exchange of four requests (`attach`, `walk`,
`lopen` and the root fid's `clunk`) of which three called the tree's
process four times. With `/tmp`'s tree in its grant and the client
sending what this section states, a request is expected to cost about
3 us and the open's exchange about 10 us (estimates; [design-programs.md](design-programs.md#performance)
gives the program's calls), until the same bench measures them.

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
what it buys is already there. The handler narrows a program's namespace
by walking fids; offsets shared by programs live in the session that
holds every program sharing them; a terminal is no file of the protocol,
and its readiness reports are the program protocol's; and a shared
mapping is the session's.

**9P2000.L's bytes on connections too.** Every server would decode
9P2000.L's binary messages. It loses because frames already carry Erlang
terms through one validated grammar, and a binary decoder at every server
would add a parser without adding expressiveness; the codec runs only at
the edges.

**Grants derived at the server for each program.** The handler would ask
the server for a grant rooted at each of a program's mounts. It needs an
operation 9P2000.L does not have, and protects against nothing: a program
reaches a server only through its handler, which walks only from the
roots of the program's own entries, and a compromised session holds the
session's grants anyway.

**A program that speaks the file protocol itself.** Each program would
hold the pids of its grants and send frames to the servers. It loses: a
program would then be a domain, with a lane to every server, a place in
every server's export table and an identity servers must check, and a
compromised program could speak to any server it held a grant on; its
session, which holds the grants anyway, relays small terms at the cost
of one ring round trip per request.

**Per-open buffers the server maps for the program.** The server would
create a memory object for each open file and the session would map it
into the program. It loses: a kernel object, a capability pass and a
mapping per open, and a server that must write into memory it did not
allocate. The data area is one object per program, from the session's
budget, and keeps every server a plain process speaking frames.

**Resolving `.` and `..` on the text.** The resolver would normalise a
path before any walk. It loses on behaviour: `..` after a link would name
the parent of the link's own directory, not of its target, which OTP's
`filelib` wildcard cases see, and `file/.`, `file/` and `missing/../x`
would resolve where FreeBSD and macOS refuse them. It also loses on what
a maintainer must hold: every operation that removes, renames or makes a
name would keep the path as written beside the normalised one, to answer
for a last `.` or `..` that normalising erased, with a table of answers
per operation and a second resolution. The place makes each of those the
ordinary path through the resolver.

**The resolver in C17 behind a NIF.** A C17 step machine in `liberx`
would take one step at a time under a lock on a table held in C. It
loses on what a maintainer must hold. The executor is Erlang whatever
the resolver is, since a NIF cannot wait for a server's reply, so every
step would cross into C and back: the cursor between steps would be input
any process could forge, needing its own checks, decoder and fuzz
target; a walk in flight would need a count of its own against mounts
made between steps; and a rename's two paths would need placing again
under one hold of the lock. In Erlang the state between two names is a
closure of the resolver's own and the table is one term a resolution
holds from start to end, so each of those goes rather than being checked.
Speed does not favour C, since a resolution's own work is list work
beside walks that cost a round trip each, and on the release file system
a path without `.` or `..` costs the one NIF call it costs in C; nor does
reuse, since the kernel never sees a path and the handlers are Erlang.

**Walking `..` at the server.** The client would hold a fid on the place
and send `..` in its walks. It would save a walk and follow a directory
through a rename as far as the fid's record does, still not to FreeBSD's
current parent. It loses: whether a walk stays within a bind's root or a
narrowed program's mount would rest on the client's count of how deep it
stands below the entry's top, where no walk carries `..` at all (F2,
F3); and the place would hold a fid whose owner must end it.

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
Every mapping in every session would map the server's one object for the
file, buying coherence across sessions. It costs a kernel pager whose
fault waits on another domain, so a server can stall a program; a claim
gate and keys to hand the object to the session; a fault worker, a cache
budget and mapping quotas at every server; and a version that means
"mapped for writing". The session's object needs none of these, and the
coherence it gives up is between sessions, which meet page by page at
each write-back, as clients of a network file system do.

**Refusing a second session's mapping.** A session would hold a mark at
the server while it maps a file. It loses: the server must keep state no
9P2000.L operation names, and a domain that holds the mark could keep
every session from mapping the file.

**An object for each program.** It loses: two programs of one session
that share a file, a parent and its forked child above all, would not
see each other's stores, which POSIX promises.

**Write-back of the whole range.** The mapper would write back every
page the object covers, needing no report from the kernel. It loses: a
write another domain made anywhere in the range would be overwritten at
every write-back, and an `msync` would cost the mapping's size, not what
changed.

**A process for each open file**, shared by every grant that opens it,
running the file's requests in turn. It loses: every tree that changes
already orders its requests in a process of its own, so it would order
again what is ordered; finding a file's process from every grant needs a
registry and a rule for the process's end; and a callback would run away
from the grant that holds its client's context. Locks, the one state that
needs every grant's opens of a file in one place, have a table of their
own ([Locks](#locks)).

**A stream's reads and writes in separate processes.** It loses: a reset,
a clunk and a flush would coordinate two processes over one stream's
state, and a read that waits would still hold up the next read and every
clunk.

**Helper reads for streams.** Each waiting read would run in a helper
that a flush ends. It loses: ending a helper does not say whether it took
bytes, so a flush could lose input, and making it say so needs the
stream's owner to decide, which is a keeper with a process more. 9front's
kbdfs takes the keeper's form, handing a waiting read to the thread that
owns the keyboard's bytes and cancelling it there at a flush (9front commit
`eb49f1f8788ccbb2f86ce5767d2f046c3593162e`, `sys/src/cmd/aux/kbdfs/kbdfs.c`,
lines 1023-1040 and 1444-1469, as the research for this section read
it; unverified here).

**Two files, `rx` and `tx`, for each stream.** It loses: the interface
would follow a limit of the server, and a read that waits in its callback
would still hold up its grant.

**A process for each request.** It loses: regular files would need their
atomicity rebuilt, a process would start for every read, and ending a
process at a flush says nothing of what it took.

**A clunk that holds the whole grant until its waits are settled.** It
loses: a begun request whose effect takes its time, a present or a reset,
would stall every other fid of the client for one fid's close.

**A facet's tree from anywhere but the mint's reply.** Decided: the
server names a grant's tree, and a mint's reply carries it with the
facet's pid ([Building, binding and
mounting](#building-binding-and-mounting), "The tree beneath an
entry"). Naming it in the manifest, one tree name per service served as
a tree, loses: it is a second source of a name the server's code fixes,
and nothing at run time would compare the two. Deriving it from the
facet's name loses: two facets of one tree would give each file two
identities and two mappers. Keeping a tree in each mount and checking
it with one `attach` per grant loses: every installation of a re-grant
would need the check, and `erx_ns`'s one writer would wait on a server.

**Qid paths unique within a server's domain, with no tree.** A file's
identity would be its server's domain and its qid path alone, so no
grant would carry a tree. Decided against: the formats' own numbers
would have to be remapped into one numbering per domain, since erXos's
F2FS already spends all 64 bits of a path on the node number and its
generation and EROFS gives its inode numbers
([design-storage.md](design-storage.md#read-write-storage), "File
identity and version"), and the remapping would add a table with its
own bounds and lifetime to every server of such a format, while a tree
that names the numbering the format already has costs one name per
grant.

**Keeping displays from programs by their tree's name.** An entry
whose tree is `windows` would pass to no program. It loses: the tree is
the server's word about identities, so a window server that named its
tree otherwise would let programs reach a display, and a check made once
when a program's table is built would miss a display installed or
re-granted later. The interface of the facet, which the domain service
sets, read at every resolution, holds for every order of events
([Narrowing for a program](#narrowing-for-a-program)).

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Remote files are too slow for tools that read many small files | medium | slow `find` and `grep -r` on `/data` | walks of up to 16 names in one request; walk, open and read in one round trip; `tools/erx bench fs`; a read-ahead in the handler if the numbers ask for it |
| The handler's relay makes a program's file I/O slower than an Erlang process's | medium | toybox's applets read at the speed of the channel round trip | the data area's 64 KiB slots; walk, open and read in one round trip; `tools/erx bench fs` from a program; more slots per program where the session's policy allows |
| A program depends on `..` following a directory that a concurrent rename moves | low | the resolution passes the old path, reaching what it names then or failing | FreeBSD resolves no path atomically either; the difference is documented, and only a racing rename shows it |
| Servers in user domains hold clients' state too long | low | a user domain's memory grows | the per-grant bounds; the client's death clunks everything |
| A slow callback holds up its grant's other requests | medium | a client reading two files of a slow medium waits for each read in turn; other clients do not | a grant for each client; `tools/erx bench fs`; a tree whose medium work the numbers show to matter hands it to its I/O process as a waiting request, that process its keeper |
| A tree's `read` or `write` waits for an event inside its callback instead of answering `{wait, ...}` | medium | the grant's other requests, its clunks and its flushes wait for that event, and a stream's reader and writer deadlock | the waiting-request tests of [Verification](#verification-and-testing) for each stream tree; a tree's review checks its callbacks for waits |
| A keeper answers a flush late | low | the flush, and that fid's clunk, wait as long as the keeper does; the grant's other fids and other grants do not | `erx_fs_waits` answers a request not yet begun `eintr` itself at its flush; a begun request's flush waits only for its effect, which each tree's design bounds; the keeper tests flush begun requests and answer within that bound |
| A large shared mapping costs a read of its whole range before it is installed | medium | slow `mmap` of large files | gate GQ measures the fill and the write-backs; the corpus's users map small files |
| Two sessions, or a session and another domain, write one page of a mapped file | low | the later write-back's page wins, as between clients of a network file system | write-back of stored pages alone; record locks for programs that coordinate; a documented difference with a test |
| A request to a hung server waits until the caller gives up | low | a process or program waits on a live server that never answers | an erXos caller waits, as on a local disk that hangs, and an edge client's interrupt flushes it; the server's end gives `eio`; the inspector shows requests in flight |

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
2. **A forked child and its parent's window.** A forked child's table is
   a copy of its parent's, the parent's own `/dev` tree included, so the
   child shares the parent's window and draw connection by path as well
   as through the descriptors it inherited, and a spawned child does the
   same unless its starter narrows `/dev` away ([A program's
   window](#a-programs-window), "A program's children"). The
   alternative is to put the shared tree's `/dev` in a forked child's
   copy, so the child reaches the window only through its inherited
   opens. That substitution is a special case in the fork's copy, needs
   a second for a spawn to match it, and draws no line: the inherited
   descriptors reach the same window, and a child cannot outlive the
   parent's tree, since the parent's end stops every space below it
   before the handler exits. Recommendation: share, one rule for every
   entry; a child that must not reach the window is spawned without
   `/dev`, as a child is kept from any directory.

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
