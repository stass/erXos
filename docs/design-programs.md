# Native programs and the POSIX-lite personality

A **native program** is a program that a session or another program
starts in a **sub-space** of the session, holding only what its starter
handed it: toybox's applets, a recompiled UNIX program, an executable a
user built, or `rc`. In Erlang it is a **port** of the session's runtime,
and its whole world is its session: its one way to reach anything is its
**channel** to its **handler**, an Erlang process of the session that is
its process table, its namespace, its file server and its source of
signals. This document is how a program starts, what it inherits, how it
signals and is signalled, how it ends, and the **POSIX-lite personality**,
musl's POSIX functions over `liberx`, which lets ordinary UNIX programs be
recompiled for erXos without porting. The key idea is that capabilities,
never the kind of program, carry authority, and that a program holds none
of them itself: what it may reach is a table its handler keeps, built from
its starter's own table alone, and every request it makes is checked
against that table by the one process that can see it. The architecture
is in [design.md](design.md); the runtime, `liberx`, the port driver and
the C library seam in [design-runtime.md](design-runtime.md); sub-spaces
and the session's resources in [design-system.md](design-system.md);
namespaces and the file protocol in [design-files.md](design-files.md);
pipes in [design-pipes.md](design-pipes.md); the command shell that starts
most programs in [design-shell.md](design-shell.md).

Decisions every reader of this document needs:

* **A program is a port of its session.** Each program runs in a
  sub-space its session creates, within the session's budget and group;
  it is not a node: it has no domain id, no node name, no export table,
  no facet and no connection to any other domain, and it appears in
  Erlang as a port owned by its handler
  ([A program is a port](#a-program-is-a-port)).
* **Capabilities carry authority**, by the user's decision. Starting
  anything, a program or an Erlang command, needs the right to start
  commands; what a started command can do comes only from the
  capabilities its starter hands it. An Erlang command a program starts
  runs in a command domain holding exactly those, so `xargs ps` and
  `xargs kill` work when the program holds the rights to list and to
  signal processes, and fail when it does not.
* **The channel is the program's only way out.** Two lanes and two
  doorbells between the sub-space and the session carry every request,
  reply, report and signal; file bytes move through the program's data
  area, which its handler fills, never through the channel
  ([The channel](#the-channel)).
* **The handler is the program's one correspondent.** It takes the
  program's requests in order, acts with the session's authority after
  checking the program's own table, and is the only process that sends to
  the program; it never waits on it ([The handler](#the-handler)).
* **One startup message**, the first frame on the channel, carries what a
  sub-space needs: its identity, arguments, environment, working
  directory, signal state and descriptors.
* **Signals are `liberx`'s.** The kernel only delivers a doorbell to a
  thread, as a vCPU upcall, Fiasco's interface for events; `liberx` keeps
  POSIX's rules for every signal and runs a handler only outside its own
  critical sections, and no signal is lost between a check and a sleep.
* **`system` and `popen` run `rc`**, by the user's decision.
* **Two tiers.** The first tier runs static programs, with `posix_spawn`
  and without `fork`, whose absence fails at link time, by the user's
  decision. The second adds `fork` by eager copy, `exec`, shared
  libraries, mappings of files and terminals, on the kernel's sealed
  objects, copy-on-write children and copies of spaces; code a program
  runs is never writable by it, in either tier.
* **A session serves its programs' shared mappings**, by the user's
  decision. Every shared mapping of one file in the session's programs
  maps one memory object of the session's, which the session fills and
  writes back with ordinary reads and writes of the file protocol and
  from which it serves its programs' descriptor reads and writes of the
  file; a fault on it is the faulting program's alone and the kernel
  resolves it from the object
  ([Shared libraries and mappings of files](#shared-libraries-and-mappings-of-files)).
* **A program never outlives the program or session that started it**,
  by the user's decision: its tree ends with it, like a job tree, and a
  long-running service starts under a supervisor, never by detaching, so
  nothing is orphaned.

## Context

By the user's decisions, erXos gives UNIX programs a POSIX-ish interface,
so that they need not be ported to Erlang, without Linux binary
compatibility or a Linux virtual machine, and grows it toward what QNX
offers: shared libraries first static, then dynamic, `fork`, and terminals
on which full-screen programs such as `vi`, `less` and `top` run. Users run
toybox's applets and their own tools from the command shell; ported
programs run commands of their own, Erlang commands among them; and every
one of them is code of unknown provenance relative to the session that runs
it, so a program holds only what it was handed: a namespace of files,
rights such as listing and signalling processes, and the right to start
commands. Security comes from those capabilities, as the user asked, never
from the kind of command a program starts.

Programs sit on mechanisms other documents define, and this document
composes them:

* sub-spaces, which any domain allowed `SPACES` creates, builds and ends,
  and whose faults and ends reach their creator
  ([design-system.md](design-system.md#sub-spaces),
  [design-kernel.md](design-kernel.md#creating-spaces));
* the kernel's vCPU upcalls, sealed objects, copy-on-write children,
  copies of spaces and pauses
  ([design-kernel.md](design-kernel.md#vcpu-upcalls),
  [design-kernel.md](design-kernel.md#copy-on-write-children-and-copies-of-spaces),
  [design-kernel.md](design-kernel.md#threads-and-faults));
* lanes, the shape of every byte stream, and the session's pipe server,
  which makes every pipe end ([design-pipes.md](design-pipes.md#the-ring),
  [design-pipes.md](design-pipes.md#making-a-pipe));
* the session's connections to the system domain and to file servers,
  over which the handler acts for its programs
  ([design-domains.md](design-domains.md#connections));
* the file protocol, 9P2000.L, whose `walk` of no names clones a grant
  for a program and whose `lopen`, `read` and `write` serve every file,
  and the session's objects for shared mappings
  ([design-files.md](design-files.md#the-file-protocol),
  [design-files.md](design-files.md#shared-mappings));
* the inspector ([design-live.md](design-live.md#inspection)) and the
  tty ([design-live.md](design-live.md#the-tty));
* `liberx`, musl, the session's port driver for programs, the pipe NIF
  and the command image's program mode
  ([design-runtime.md](design-runtime.md#programs-as-ports));
* the command shell's spawns, Erlang commands, jobs and terminal relay
  ([design-shell.md](design-shell.md)).

## Requirements

Functional requirements:

1. **Programs started from a shell or a program**: a native program,
   toybox's applets among them, starts fresh in a sub-space of its
   session, receives its arguments, environment, working directory,
   signal state and descriptors in one startup message, the first frame
   on its channel, reaches only what its starter held and handed it, and
   reports its exit status to its starter; a program's image is a program
   of the boot image, an executable file reached through a grant with the
   `rx` right, `rc`, or an Erlang command run in a command domain
   ([Starting a program](#starting-a-program)).
2. **Capabilities, not program kinds**: starting anything needs the right
   to start commands, and a started command can do only what the
   capabilities its starter handed it allow, by the user's decision
   ([What a program can start](#what-a-program-can-start)).
3. **A POSIX-lite personality** in every program that is a C program, by
   the user's decision: in its first tier, descriptors over pipes, files
   and sockets, `posix_spawn`, `wait`, `poll`, pipes, POSIX's signals,
   `system` and `popen` through `rc`, anonymous and private file
   mappings, and the session's `/dev/tty`, with `termios`
   ([The POSIX-lite personality](#the-posix-lite-personality)).
4. **The second tier**: `fork`, the `exec` family, shared libraries
   loaded statically and with `dlopen`, `mmap` of files, pseudo-terminals
   that programs hold, process groups and sessions, and full-screen programs,
   by the user's decisions ([The second tier](#the-second-tier)).
5. **Job control**: the session stops, continues, interrupts and ends a
   program and every program it started
   ([Job control](#job-control)).
6. **Confinement**: a program never reaches a file, a right or a domain
   its starter did not hold and hand it, never runs anything with its
   session's authority, never executes code it can write, and never makes
   a process of its session wait on it ([Invariants](#invariants)).
7. **Honest results**: every end of a program maps to one exit status,
   and no call reports success without acting
   ([A program's end](#a-programs-end)).

Non-functional requirements:

* **Cost.** A program's cost approaches a UNIX process's: code is mapped
  shared from the boot image or a file object, never copied; a program
  costs two spaces, a budget, a group, a channel, a thread and its pipe
  ends, and no work in any domain but its session
  ([The cost of a program](#the-cost-of-a-program)). A program of the
  boot image starts within 1 ms under HVF, a budget that
  `tools/erx bench spawn` checks ([Performance](#performance)).
* **Bounded state.** What a program can make others hold is bounded and
  declared: a startup message of at most 192 KiB, 16 requests in flight to
  its handler and one notice for each pipe end it was given and each gone
  writer it was told of, the frames its handler owes it, which merge, its
  principal's `programs` and `children` quotas and the session's mapping
  quota for shared mappings of files, which `erx_policy` sets, and the
  file protocol's bounds at the servers.
* **Fidelity.** musl's `libc-test` and the Open POSIX Test Suite are the
  oracles, and every difference from POSIX is documented with a test
  ([Compatibility and migration](#compatibility-and-migration)).

Non-goals: copy-on-write sharing of private memory, a POSIX shell in the
first tier, and Linux binaries
([Alternatives considered](#alternatives-considered)).

## Overview

A starter, the shell or a program, plans a spawn as a pure function of its
own state and sends one request on its channel to its handler. The handler
checks the right to start commands, resolves the command to an image
through the starter's namespace, has the command server assign a process
id and create the program's handler, has the session's pipe server make an
end for each pipe end the request names, clones the child's grants from
the starter's at the servers, and has the port driver build the sub-space
from one plan: a budget, a group, an anchor space and an image space, the
channel, the image mapped, the capabilities installed, and the first
thread, stopped. The program's handler writes the startup message into the
channel, and only then starts the thread. The program's `liberx` takes the
message, builds its tables and calls `main`. From then on the program talks
only to its handler, and its handler alone talks to it; its end, whatever
it was, reaches its starter as one exit status. An Erlang command a
program starts runs in a command domain holding only what the program
handed it, reached through the session.

```text
   session domain                                   sub-spaces of the session
  +-------------------------------------------+     +-----------------------+
  | shell --> command server (pid 1)          |     | program P             |
  |               | creates                   |     |   main thread, workers|
  |               v                           | channel: two lanes,       |
  |   handler of P (port owner) <-------------+-two doorbells-------------+
  |      |  table of P: namespace, opens,     |     |   liberx: descriptors,|
  |      |  rights, children                  |     |   signals, planner    |
  |      v                                    |     |   event executor      |
  |   port driver: spaces, channel, installs, |     +-----------------------+
  |   pause, stop; the session's fault gate   |     | program Q ...         |
  |   pipe server: lanes, doorbells           |     +-----------------------+
  +-------------------------------------------+
          | connections                       the system domain creates no
          v                                   sub-space; file bytes move
   file servers, the system domain            through each program's data area
```

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **P1.** A program reaches only what its starter held and handed it | a program's table lives in its handler, which builds it from its starter's table alone: its namespace is grants the handler cloned at the servers from the starter's, with the starter's rights there or fewer, its opens name open-file descriptions that the starter's opens name, its rights beyond files are a subset of the starter's, and its pipe ends are ends the session's pipe server made for it; the program holds no pid, no grant and no capability but those its session installed into its table, and holds no IPC gate, so no capability reaches it at a rendezvous; every request it makes is served by its handler against that table; it has no connection to any other domain, so nothing it sends reaches one ([The handler](#the-handler)) | a request field that a handler trusts to name authority; a capability installed into a program by anyone but its session; a program with a connection of its own | the narrowed-program tests; a program that names its handler's or another session's process in a request, which gains nothing; the pipe server's model ([design-pipes.md](design-pipes.md#invariants)) |
| **P2.** A started command holds exactly the capabilities its starter handed it, and starting anything needs the right to start commands | a handler builds a child's table from its starter's table and the request alone: the child's namespace is the starter's, its rights beyond files the starter's, each descriptor an end or an open made for the child, and the right to start commands is the starter's own; the handler refuses every spawn of a starter without that right; an Erlang command started by a program runs in a command domain the system domain builds with the same table, and the session's domain runs only commands with the session's own authority | a handler that adds a capability the request did not name; an Erlang command run in the session's domain for a program; a starter setting a right it lacks | a narrowed program's own spawn request, which fails with `EPERM`; `xargs ps` with and without the `inspect` right, which lists processes or fails with `no_facet`; a command domain whose capabilities are exactly the program's |
| **P3.** No process of the session waits on a program | the port driver's write into a program's lane never blocks: a frame that finds no room is **owed**, kept by the handler and written when the program frees room; the handler never waits on a request's work, keeping a request pending while it serves the next frame; and every other process of the session that answers a program, the pipe server and the terminal relay among them, hands its replies and reports to the program's handler ([The handler](#the-handler), [The channel](#the-channel)) | a blocking write into a lane; a handler that waits for a filler, a mapper or the pipe server before taking its program's next request; a session process that writes a program's lane itself | the test of a program that stops draining its channel while its children end and a pipe gains a writer, while the relay, the shell and the program's siblings stay responsive; a spawn whose executable's file object is slow to fill while the starter's `SIGINT` still arrives |
| **P4.** A program hands no pipe end on: what another program receives is an end the session made for it | every end is made and installed by the session's pipe server, for one holder, and no copy it installs carries `DUP` or `GIVE`; a spawn, a fork and a passed descriptor name the end, and the pipe server makes an end of the same kind for the receiver ([design-pipes.md](design-pipes.md#invariants), PI1) | a copy of a lane or a doorbell with `DUP` or `GIVE`; a path that installs the starter's own end into another program | PI1's tests; domain tests that a spawn, a fork and a passed descriptor each leave the starter's end in its table and give the receiver an end of its own, and that a refused spawn leaves every pipe with the ends it had |
| **P5.** A signal handler never runs while its thread is inside `liberx` | every exported function of `liberx`'s program layer raises the thread's depth through one entry macro, and handlers run only at depth zero, which `liberx` lowers to only at an open wait or its outermost exit, where it holds no lock and no structure is half-updated; every other wait is closed and keeps the depth above zero, a wait is closed unless its call declares it open, and a wait declared open is closed while its thread holds an obligation, so the only locks held across a wait, a pipe's reader lock in a redemption and `fork`'s kept locks, are held across closed ones ([Signals in liberx](#signals-in-liberx)) | an exported function without the macro; a handler run at a depth above zero; a lock of `liberx` held across an open wait | the build check on the entry macro; `erx_sig_step`'s exhaustive model, with open and closed waits; the debug build's assertion that an open wait holds no lock of `liberx` |
| **P6.** No signal is lost between a check and a sleep | every wait of `liberx` sleeps on the thread's wake word with the value it read before its check, and every raiser bumps the word before it wakes the thread; an upcall's return re-enables events and takes any event that arrived meanwhile in one kernel call ([design-kernel.md](design-kernel.md#vcpu-upcalls)) | a wait that sleeps on another word, or a raiser that wakes before it bumps; a return from the entry that re-enables events in a separate step | `erx_sig_step` with an upcall between every check and sleep, and with an event left pending across a call; `sigsuspend` with a signal already pending |
| **P7.** A request already sent is never abandoned because of a signal | the interrupted-call rules: a wait with a request in flight runs the handler and resumes, and a closed wait runs no handler until it ends (P12) | a wait that flushes its request on a signal | an interrupted file write that returns its count |
| **P8.** Every end of a program maps to one exit status | `erx_prog:status/1` is total over the kernel's exit and fault records, and its fault rows come from the ABI file's fault table, which gives every fault kind a signal | a fault kind without a signal; a record the function does not match | a property test over every record; the generator's check |
| **P9.** A program never outlives the program or session that started it, and its children survive its `exec` | the session creates each program's **anchor**, a threadless space, with its starter's anchor, or the session's own space, as the parent, and each of its images below the anchor, so its children's anchors hang from its anchor, not its image; the kernel stops a space's children when it stops, those not yet started included, forked children and sub-spaces too, and `exec` stops only the old image ([design-kernel.md](design-kernel.md#creating-spaces), K27) | a program anchored under any other parent; a child created below an image; a thread started in a stopped space | the kernel's K27 tests; a starter ended while its child is built but not started; a starter that execs while its child runs; a session that ends with three generations of programs running |
| **P10.** A program never executes code it can write | a program's code comes only from boot-image slices and sealed code objects, which no mapping can write and which reach a program only through an open for reading that the handler allows for code only through a grant of the program's that carries `rx`, a right no grant holds with `rw`; no copy-on-write child is executable (K8), and no program's space is a JIT space ([File objects](#file-objects), [Security](#security)) | an executable ceiling on a writable object; a code object given without the handler's check of the requester's own grant; a program's space built as a JIT space | the kernel's K8 and K22 tests; an executable whose code tries to write itself, which faults; a `dlopen` through an `ro` grant, and a code `map` through an `ro` grant of a file that another program's `rx` map put in the cache, each of which fails with `EACCES` |
| **P11.** A frame or a capability reaches only the image it was made for | each image has a channel of its own, whose lanes no other image maps; the handler serves one image at a time, from its startup message until its `{exec_commit}`; and every install into a program goes through the session's own capability to one image's space, which refuses an image that has stopped (`ERX_EDEAD`), so nothing meant for the old image lands in the new one ([Exec](#exec)) | a channel shared by two images; an install that names a program rather than an image; a handler that sends during the switch | the exploration of the handler and the pipe server over an `exec` whose let-go overlaps pipe reports and installs, with the property that no capability is installed into a table other than the one its report names; a domain test in which a reader execs while a sibling forks a writer of its pipe |
| **P12.** A closed wait is never abandoned | handlers, `siglongjmp` and `exec`'s parking act only at depth zero, and a closed wait keeps the depth above zero. A wait is closed unless its call declares it open, so a forgotten case delays a signal instead of abandoning what only its thread can finish, and a closed wait for a reply of the program protocol has no deadline, since the handler answers every request. A thread's closed region is the span in which its entry in the operation table holds an obligation, which the one function that makes each kind of obligation records through `erx_op_hold`, a request in flight by the channel's send whatever it asks, so no list of calls decides it; `exec` waits until no entry holds one, refuses a worker's first one at `erx_op_hold`, where the worker lets go of what it holds and waits, and parks the rest where they are, so a call that sits in an open wait never delays it, and no closed wait depends on another worker of the program ([Signals in liberx](#signals-in-liberx), [Exec](#exec)) | a wait declared open that holds a lock, a claimed record, a deposit not yet published or kept locks; an obligation made without `erx_op_hold`; a closed wait outside a closed region; an `exec` that parks a worker inside a closed region; a closed wait that depends on another worker; a deadline on a request of the program protocol | `erx_sig_step`'s model with closed waits and regions; the debug build's assertion that every closed wait is inside a region; a signal, and `alarm` with `siglongjmp`, during a redemption and during a deposit; an `exec` while other workers are inside a redemption, a deposit, `posix_spawn` and `fork`, each of which completes before the old image lets go; an `exec` while another worker waits in `recvmsg` on an empty stream whose writer lives and writes nothing, which the quiesce parks at once |
| **P13.** A program takes each report once, and no report is lost to an `exec` | the channel delivers the handler's frames in order and without loss, so no report is ever sent twice. The event executor copies each frame's record out of the inbound lane into private memory as its bytes arrive, advancing the read position behind what it has copied, and applies the frame from that copy only once the record's last byte is read; so a frame is either taken, applied and in the state the old image hands over, or not fully taken. At the switch the handler writes into the new image's lane, after its startup message, which carries every child's latest state, every signal report the old image had not fully taken: first those the port driver hands back from the old lane, whole or read in part, then those the handler still owed ([The channel](#the-channel), [Exec](#exec)) | a frame applied before its last byte is read; a switch that drops a signal report the old image had read in part, left unread or was still owed; a report sent to two images | the exploration of the handler and `liberx` over an `exec` racing signals, stops, continues and exits, with the properties that each report is taken at most once and every signal reported is either taken or dropped by a later report; an `exec` whose old image is signalled after its capture while a sibling signals the new image, which takes both; an `exec` whose old image has read part of a signal report's record when it captures, and one whose handler owes a signal report at the switch, after each of which the new image takes the signal once |
| **P14.** Within a session a file mapped shared has one copy, and its server receives through write-back only the pages the session's programs stored | the session's file table holds at most one mapper for each file, keyed by the server's domain, the tree and the qid path, and the mapper one object, which every shared mapping of the file in the session maps; while the mapper lives, the handlers send every descriptor read, write and size change of the file to it, and it serves them from the object, copying into it only what the server acknowledged of each write; the mapper fills a page, and moves its filled extent past it, before any mapping covers it, so a fault on the object is resolved from it and waits on no other domain, and it changes the object's bytes only with `erx_mem_copy` from a staging object, at a fill, a write and a zeroing, never through a mapping, so no CPU store of the session marks a page; and it writes back only the pages the kernel reports stored to since it last asked, with those whose write failed ([Shared libraries and mappings of files](#shared-libraries-and-mappings-of-files), [design-files.md](design-files.md#shared-mappings), F7) | a mapper started per request or per program; an object per mapping; a descriptor read or write relayed to the server past the mapper; a mapping installed before its pages are filled; a fill, a write or a zeroing made by CPU stores; a write-back of a page no program stored to | two programs and a forked child that map one file, each of which sees the others' stores at once, with a seeded command server that starts a mapper per request, which the test catches; a program that reads through a descriptor what another stored through a mapping, and a mapping that shows at once what a descriptor wrote, with a seeded handler that relays descriptor requests to the server, which the test catches; a write from outside the session to a page no program stored to, which a later write-back leaves intact, with a seeded mapper that writes back every page and one that fills by CPU stores, each of which the test catches |

## Data model

### A program is a port

A program is a **sub-space** of its session's domain, which its session
creates, builds, pauses, stops and ends with the calls any creator of a
sub-space has ([design-system.md](design-system.md#sub-spaces),
[design-kernel.md](design-kernel.md#creating-spaces)), and in the
session's runtime it is a **port**: owned by its handler, linked to it,
closed when its owner exits, spoken to by messages, and reporting
`{exit_status, N}` when its image ends
([design-runtime.md](design-runtime.md#programs-as-ports)). A program
consists of:

| Part | What it is | Held by |
| --- | --- | --- |
| the **anchor** | a space with no thread and no mapping, the root of the program's tree: its parent is its starter's anchor, or the session's space for a program the shell starts, and its children are the program's image and its children's anchors ([design-kernel.md](design-kernel.md#creating-spaces)) | the session, with every right |
| the **image** | the space its threads run in, with the program's code mapped from the boot image or a file object; `exec` replaces it under the same anchor ([Exec](#exec)); the program's own sub-spaces, if it is allowed `SPACES`, hang from it | the session, with every right; the program as `ERX_CAP_SELF` |
| its **budget** | carved by the session from its pool for programs, with the policy's floor as its guarantee, what the smallest program needs to start and to end, and as its cap what the session's policy gives the program, the pool's whole size unless the starter asks for less, so the program draws on what its siblings are not using and is refused only when the pool is full, and the session's end takes every program with it; it pays only for what the program alone maps and holds: its spaces, its threads, its image's private memory, heap and stacks, its signal IRQ objects, its data objects and anything the program creates. Nothing the session maps is charged to it, since destroying a budget deletes every object charged to it at once ([design-kernel.md](design-kernel.md#budgets), [design-system.md](design-system.md#resource-policy)) | the session with every right; the program with `ALLOC`, and `SPACES` when its starter held it and asked for it |
| its **group** | a child of the session's **programs group**, the sub-space group the system domain gives a domain allowed `SPACES` ([design-system.md](design-system.md#sub-spaces)); it charges the program's threads, binds its doorbells, and parks its event executor; the session sets its grant within its own and reads its CPU time | the session with `CONFIGURE`, `SIGNAL` and `ATTACH`; the program with `SIGNAL` and the rights an executor needs to park |
| its **channel** | two lanes and two doorbells to its handler ([The channel](#the-channel)) | both, as the channel says |
| its **table** | what the program may reach: its namespace, its opens, its rights beyond files, its children and its pipe ends, kept in Erlang by its handler and at the servers ([The handler](#the-handler)) | the handler |
| its **data area** | a memory object the session creates from its own budget, `slots` slots of 64 KiB, 4 by default, through which the bytes of the program's reads and writes of files, terminals and sockets move ([Descriptors and files](#descriptors-and-files)) | the program with `READ`, `WRITE` and `MAP`; the session, whose handler copies into and out of it through its NIF |
| its **process id** | a number from 2 to 2^31 - 1 the command server assigns, never reused within the session; 1 is the command server | the command server's process table |

A program is not a node: it has no domain id, no node name, no export
table, no facet and no connection to any other domain, so it cannot be
messaged by, and cannot message, anything but its handler. It trusts its
session wholly, as any sub-space trusts its creator, and its session
trusts it not at all.
Its faults and the ends of its spaces reach the session's fault gate,
which the session's port driver serves, with the label the port driver
gave the space as the label every record carries
([design-kernel.md](design-kernel.md#threads-and-faults)). The inspector
shows a program under its session as a port with its name, process id,
command and state, and its spaces as sub-spaces of the session
([design-live.md](design-live.md#inspection)); `ps` in a session lists the
session's process table.

Two kinds of program the session does not run as sub-spaces: an **Erlang
command** a program starts, and `rc`, which run the runtime image and so
need a domain, the program's **command domain**, which the system domain
creates at the session's request with exactly the program's table ([What
a program can start](#what-a-program-can-start)).

### The channel

A program's channel is one pair of lanes and two doorbells between the
sub-space and the session, in the shape of a connection. Each lane has the
one layout every lane in erXos has: a ring whose header,
`erx_lane_hdr_t`, and data area its producer alone writes, and a reader
page, `erx_lane_rpage_t`, that its consumer alone writes, with the wake
handshake by published positions. The two lanes share their memory
objects pairwise, so that each party writes exactly one object, its
**side**, and maps the other's read-only: a side holds the ring header of
the lane its party writes at its start, the reader page of the lane its
party reads at `ERX_LANE_SIDE_RPAGE`, and the data area of the lane its
party writes at `ERX_LANE_SIDE_DATA`
([design-domains.md](design-domains.md#connections)):

| Object | Its pages | Written by | Mapped by | Purpose |
| --- | --- | --- | --- | --- |
| the **session's side** | the inbound lane's ring header and data area of 16 KiB; the outbound lane's reader page | the session's port driver | the session read-write; the program read-only, its copy carrying `READ` and `MAP` | the startup message, replies, reports and signals, from the handler to the program; how far the session has read the outbound lane |
| the **program's side** | the outbound lane's ring header and data area of 16 KiB; the inbound lane's reader page | the program: the ring by its `liberx`, the reader page by its event executor | the program read-write, its copy carrying `READ`, `WRITE` and `MAP`; the session read-only | requests and notices, from the program to the handler; how far the program has read the inbound lane |
| the **program's doorbell** | none: an IRQ object | triggered by the port driver | bound by the session to the program's group with the channel's fixed label, `prog_channel_label` (1), which no pipe end's label equals ([design-pipes.md](design-pipes.md#waiting-and-doorbells)); the program holds no capability to it | wakes the program's event executor: a frame in the inbound lane, or room in the outbound one |
| the **session's doorbell** | none: an IRQ object | triggered by the program | bound by the session to its own group with the port as its label; the program holds `TRIGGER` alone | wakes the port driver: a frame in the outbound lane, or room in the inbound one |

The session creates the two sides and the two IRQ objects from its own
budget, never the program's, since the session maps them too, and binds
the doorbells, installs into the program's table its copies, each
without `DUP`, `GIVE` or `DESTROY`, and tells the program their values in
the first thread's argument registers, together with the values of its
budget and its group, in the registers `abi/erx_abi.txt`'s `program_arg`
names from the program's view: its own side, the program's, and its peer
side, the session's; `liberx` maps the two sides before anything else.
The session holds the only `DESTROY` on the channel's objects and deletes
them only after the program's budget is destroyed, so the program never
faults on its own channel; a program that unmaps or closes its channel
loses only its own way out.

**Frames.** Each lane carries frames of the program protocol's grammar,
each frame one record of kind `ERX_REC_FRAME`, read as on a connection:
the consumer reads a record as it is published and copies it into
private memory up to the profile's bound
([design-domains.md](design-domains.md#connections)). Unlike a
connection's, a frame is one term with no frame header or control term.
The session judges each frame from the program with the funnel's channel
mode: within `ERX_PROG_FRAME_MAX` bytes and in the host grammar, which
has no fun, export, pid or reference, whatever the session's own domain
admits on its connections
([design-domains.md](design-domains.md#the-funnel)). A frame larger than
the ring, the startup message with a large environment among them, flows
through it as the consumer frees room. The program's event executor is
the only thread that reads the inbound lane and the only one that stores
its read position: it copies a frame's record into private memory as its
bytes arrive, advancing the read position behind what it has copied, and
applies the frame to the program's tables from that copy only once the
record is whole, so a frame counts as taken only when its last byte has
been read (P13). Any worker may write a request or a notice into the
outbound lane through the channel's send, the lane's only writer, under
the lane's one lock, which is never held across a wait. A frame that fits
the ring is written whole under the lock, after an open wait for room for
the whole frame: a sender that finds too little lets go of the lock,
publishes the room it needs and waits, and puts again once the event
executor, taking the channel's label, wakes the senders waiting for room.
So the frames of two workers never interleave, and no worker holds the
lock while it waits; a sender that leaves while others wait wakes them,
since the room it last asked for may have been theirs to wait on. The executor never sends into the
outbound lane, since only it announces room there.

**Waking.** Each lane follows the wake handshake of every lane
([design-domains.md](design-domains.md#connections)): a party with
nothing to do publishes the position it waits for, `wake` in its reader
page or `need` in its ring header, fences and checks again; a party that
publishes a frame or frees room fences, reads the position the other
published, and rings the other's doorbell only when its store crossed
it. The program's executor and the port driver each own one doorbell for
both lanes, so a ring means "look at both lanes". On the stopgap and on
erXos's kernel alike the data path makes no kernel call while the other
side is awake.

**Identity and trust.** The handler knows which program sent a frame by
the lane it arrived on; no field of a frame names the sender, and the
handler serves one image at a time, so a frame on an image's channel is
that image's. The program knows that everything in its inbound lane comes
from its session, the only writer of that ring. The handler decodes every
frame from a program with the protocol's generated decoder, which has a
fuzz target, and a frame outside the grammar ends the program as a fault
ends it, with `SIGSYS` ([A program's end](#a-programs-end)); `liberx`
decodes every frame from its handler with the same generated decoder,
and a frame it cannot decode, which only a bug in the session can produce,
ends the program with status 127 and a line on its standard error.

**Flow control is the lanes.** A program whose outbound lane is full waits
for room in `liberx`, in an open wait, since it holds nothing; a program
holds at most 16 requests in flight, one per reply slot, and a worker
without a free slot waits for one in the same way. A handler whose
program's inbound lane is full never waits: the port driver's write
returns `busy`, and the handler keeps the frame as **owed**, writes
nothing newer before it, and writes it when the program frees room, which
the program's executor announces by ringing the session's doorbell
([design-runtime.md](design-runtime.md#programs-as-ports)). What a handler
can owe is bounded by its program's state, since owed frames merge: the
replies to its requests, at most 16; one report per child's latest state;
one report of each signal, a later report of the same signal replacing an
earlier owed one, as POSIX keeps one pending; one readiness report per
open; and one report per peer end of each pipe end it holds, since a join
and a gone for one end merge into the join's values marked gone, so the
program installs the end and sees it gone at once, and still drains a gone
writer's lane ([design-pipes.md](design-pipes.md#the-program-protocol)). A
program that never drains its lane holds its handler to that much and no
more, and delays nothing else.

**One channel per image.** An `exec` builds the next image with a channel
of its own, so no frame written for the old image can be read by the new
one, and the old channel's objects are deleted once the old image has
ended ([Exec](#exec)).

### The startup message

The startup message is the first frame the handler writes into a new
image's inbound lane, before the image's first thread starts, so the
program finds it there whenever it first looks and waits for nothing. It
carries what a sub-space needs:

```erlang
{erx_start, 1, #{pid := 2..16#7fffffff,       % this program's process id
                 ppid := 1..16#7fffffff,      % its parent's; 1 is the command server
                 pgid := 2..16#7fffffff,      % its job's first program's pid
                 argv := [binary()],
                 env := [binary()],           % each NAME=value
                 cwd := binary(),             % absolute and normalised
                 spawn := boolean(),          % the right to start commands
                 sigmask := [signal()],       % blocked when main starts
                 sigignore := [signal()],     % ignored; the rest take the default
                 umask := 0..8#777,           % the file mode creation mask
                 data_area := {Cap, Slots},   % the data area, in the program's table
                 fds := [{0..1023, Descriptor}],
                 image => Image,              % erx_exec only
                 sigpending => [signal()],    % exec only: still pending
                 children => [Child],         % exec only: from the handler's record
                 handover => Handover,        % exec only: from the old image
                 cloexec => [0..1023],        % fork only: descriptors with FD_CLOEXEC
                 mapped => [{Cap, Open}]}}    % fork only: shared mappings of files
%% signal() = a signal's name from the ABI file's signal table, such as sigint
%% Image = {object, Cap}  % erx_exec: the executable's file object
%% Descriptor = {pipe, read | write, PipeEnd, EndValues}
%%            | {socketpair, PipeEnd, EndValues, PipeEnd, EndValues}
%%                                  % its read end, then its write end
%%            | {file, Open, read | write | read_write}
%%            | {tty, Open, read | write | read_write}
%%            | {dir, Open}
%%            | {socket, Open}
%%            | {dup, Fd :: 0..1023}
%%            | {mem, Address :: non_neg_integer(), Bytes :: pos_integer()}
%%                                  % memory the session mapped into the
%%                                  % program while building it
%%            | null
%% Open = 0..16#ffff           % an entry of the program's open table in its handler
%% PipeEnd, EndValues = a pipe end's numbers and the values in the program's
%%            own table of what it holds, as design-pipes.md defines them
%% Cap = a capability value in the program's own table; Size a byte count
%% Child = {Pid :: 2..16#7fffffff, ChildState}  % a child not waited for
%% ChildState = running | {ended, Status, N}
%%            | {stopped, signal(), N, pending | taken}
%%            | {continued, N, pending | taken}
%%                                  % Status as in an exit report; N the
%%                                  % child's count of state changes at
%%                                  % that state; taken once waitpid
%%                                  % returned it
%% Handover = #{nonblock := [0..1023],     % kept descriptors whose object
%%                                         % has O_NONBLOCK
%%              wpos := [{0..1023, non_neg_integer()}],
%%                                  % each kept write end's private write
%%                                  % position
%%              thread_pending := [signal()],      % the calling thread's own
%%              alarm := none | {Deadline :: non_neg_integer(),
%%                               Interval :: non_neg_integer()}}
%%                                  % the next SIGALRM on the monotonic clock,
%%                                  % and its interval, in ns; an interval of
%%                                  % 0 for an alarm that does not repeat
```

A `pipe` descriptor names an end, by its pipe's and its own number, and
the values in the program's own table of the lanes, the lock page and the
doorbells the session installed for it
([design-pipes.md](design-pipes.md#the-program-protocol)), and a
`socketpair` descriptor the read end of one pipe and the write end of
another ([Passing descriptors](#passing-descriptors)). A `file` descriptor
names an **open** of the handler's open table, an open-file description at
its server reached through a grant the handler holds, with that
description's access mode ([Descriptors and files](#descriptors-and-files));
a `tty` descriptor is the same for a terminal, a `dir` an open directory,
through which `openat` resolves, and a `socket` an open of a socket's
open-file description; a `dup` makes its number name the same object as another
descriptor of the message, which is not itself a `dup`. A `mem`
descriptor names memory the session mapped into the program's sub-space
while it built it, read-write, at `Address` for `Bytes`, both multiples
of the page size: the pages of a window's buffer, for a program that
renders into its window
([design-display.md](design-display.md#the-pixel-area)). The program
holds no capability to that memory. `mmap` of the descriptor with
`MAP_SHARED`, offset 0 and a length of at most `Bytes` returns
`Address`, `fstat` reports `Bytes` as its size, and `read`, `write` and
`lseek` on it fail with `ESPIPE`. It names a mapping of this one
sub-space, so a spawn's `Start` cannot name one, `fork` does not copy
it and `erx_exec` closes it. `sigmask` and
`sigignore` follow POSIX's rule for `posix_spawn`: the program starts with
its parent's mask and ignores what its parent ignores, unless the spawn's
attributes set them, and every other signal starts with its default
action. `image` names, for `erx_exec`, the capability value of the
executable's file object, which the session installs before the image
runs ([File objects](#file-objects)). The program's namespace and its
rights beyond files are not in the message: the program never holds them,
and its handler keeps them ([The handler](#the-handler)).

Four fields appear only in the message to an image that `exec` started
([Exec](#exec)). `sigpending` names the signals still pending, which POSIX
keeps across `exec`. `children` comes from the handler's record ([The
program record](#the-program-record)): each child not waited for and its
latest state, with the count of that child's state changes and whether
`waitpid` has returned it, so the new image's `wait` and `waitpid` return
each state once. `handover` holds what only the old image's `liberx`
knows: the kept descriptors whose object has `O_NONBLOCK`; each kept write
end's private write position, which no peer can write
([design-pipes.md](design-pipes.md#the-ring)); the calling thread's own
pending signals; and the alarm's next deadline and interval, which POSIX
keeps across `exec`. `cloexec`, in a fork message alone, names the
descriptors that carry `FD_CLOEXEC`, since a forked child inherits each
descriptor with its flag. `mapped`, in a fork message alone, names each
file the parent maps shared, by the value of the session's object for it,
which the child's copy keeps, and the child's own **mapping open**, which
holds the child's share in that object and which the child closes at its
own last `munmap` ([Shared libraries and mappings of
files](#shared-libraries-and-mappings-of-files)). Each list is bounded by
the table it comes from, and the whole message by the 192 KiB below.

The bounds: `argv` and `env` together at most 128 KiB, the `ARG_MAX` that
`sysconf` reports, each string valid UTF-8 without NUL, and each `env`
string a non-empty name without `=`, an `=`, and a value; `cwd` a valid
path of at most 4,096 bytes; at most 1,024 descriptors, each number once,
each capability value once; each signal at most once in each set; and at
most 192 KiB in all, counted with every capability value at its longest
encoding (distinct values, each as long as any value's), so that whether
a spawn fits depends on its spec alone and
never on the values the install makes. A spawn whose strings pass 128 KiB,
or whose message so counted passes 192 KiB, fails with `E2BIG`
in its planner. The grammar and bounds are a frame profile of the ABI
file ([design-files.md](design-files.md#interfaces)), from which `liberx`'s
decoder is generated; the decoder has a fuzz target
([design-abi.md](design-abi.md#program-protocol)). The profile holds each
descriptor number, each signal of a set, and each index and write end
number of a pipe end's lists to one appearance by keeping those lists in
ascending order, which the generated builders give them. A message that
fails it ends the program with status 127 before `main`.

### The program record

A program outlives its images, so what belongs to the program is kept
apart from what belongs to one image. The program's handler keeps the
**program record**, which no image can lose; each image keeps its own
state, and a channel made for an image dies with it:

| The program record, in its handler | One image, in its `liberx` |
| --- | --- |
| the process id, the parent, the job and the session | the space and its threads |
| the anchor, the budget, the group and the current image's space and channel | its mappings of the channel and of its pipe ends |
| the namespace: each mount point's grant, cloned for the program at its server, and its rights | the arguments, the environment, the working directory and the file mode creation mask |
| the open table: each open's kind and the open-file description it names, mapping opens among them | the descriptor table: which numbers name which opens and ends, each write end's private position, `FD_CLOEXEC` and `O_NONBLOCK` |
| the rights beyond files, and the right to start commands | masks, dispositions, pending sets, handlers and the alarm |
| the children, each with its latest state, its count of state changes, and whether the program's `wait` has taken that state | the child table that `wait` reads |
| the pipe ends the program holds, as the pipe server records them | the requests it has in flight |
| the command domain, once one is made | |

The handler builds the record when it builds the program and keeps it from
what passes through it: a child enters it when the spawn or fork is
reserved, each state with the report the handler sends, and a state is
marked taken by `{waited, Pid, N}`, a request whose reply confirms it
([The program protocol](#the-program-protocol)). The descriptor table
stays in the image, where `dup`, `close` and `fcntl` reach it without a
frame to the handler; an `open` or a `close` of a file reaches the handler,
whose open table changes with it. At an `exec` the old image names in its
`{exec}` request the descriptors it keeps and, in `{exec_commit}`, the
values that change until its last moment: its pending signals, its alarm
and its automatic reaps still unanswered ([Exec](#exec)). The handler
builds the next image's startup message from these and the record, so the
old image's channel and tables never reach the new image. A faulty program
that misreports what it keeps harms only itself: the handler keeps only
descriptors that name opens and ends the program holds, and every server
still checks what the handler asks of it.

### The handler

A program's **handler** is an Erlang process of the session's command
server, created for the program before its sub-space is built and the
owner of its port. It is to its program what Plan 9's kernel is to a
process: its process table, its namespace, its file server and its source
of signals, acting with the session's authority after checking the
program's own table. It does five things:

* **It keeps the program's table.** The namespace, a list of mount points
  each with a grant the handler cloned for the program at the mount's
  server from its starter's grant there, with a `walk` of no names, and
  the rights the program holds there, the starter's or fewer, which the
  handler checks on every request
  ([design-files.md](design-files.md#narrowing-for-a-program)); the open
  table, each open naming an open-file description of the session
  ([Descriptors and files](#descriptors-and-files)); the rights beyond
  files; the children; and the pipe ends. The program sees paths,
  descriptor numbers and open numbers, never a grant, a fid or a pid.
* **It serves the program's requests**, in the order they arrive on the
  channel, one image at a time. A request that needs another party's
  answer, a server's, the pipe server's or the port driver's, is kept as
  pending and the handler takes its next frame meanwhile, so a signal for
  its program is delivered while a spawn waits for a file object to fill,
  and the answer completes the request (P3). A file request is resolved
  through the program's namespace by the one resolver Erlang clients use
  ([design-files.md](design-files.md#resolving-a-path)) and relayed, as
  the terms of 9P2000.L's operations, over the session's connection to
  the file's server, the session itself for its own export;
  the bytes move through the program's data area, never through the
  channel ([Descriptors and files](#descriptors-and-files)).
* **It installs.** Everything that enters the program's table enters
  through the handler, which asks the port driver to install capabilities
  of the session's table into the image it serves, by the session's own
  capability to that image's space: pipe ends and their doorbells, file
  objects, the objects of shared mappings. An install names one image and
  fails with `ERX_EDEAD` once that image has stopped, so nothing lands in
  an image it was not meant for (P11).
* **It is the only process that sends to the program**: replies, the
  reports of its children's states, readiness reports, pipe reports and
  signals, each written into the inbound lane by the port driver on the
  handler's behalf, owed when the lane is full (P3). Every other process
  of the session that has something for the program, the pipe server, the
  terminal relay, a filler or a mapper, hands it to the handler.
* **It ends the program.** On the end record of the image it asks the
  port driver to stop the anchor, which ends the program's tree, closes
  every open at its server, tells the pipe server the program's ends are
  gone, ends the command domain, and reports the end to the starter's
  handler ([A program's end](#a-programs-end)).

Below, the **starter's handler** is the handler of the program that asks
for a spawn, or the command server when the shell asks, and the
**program's handler** the one created for the new program. The handler
runs the one generated decoder of the program protocol over every frame
and acts only on what the decoder admitted; it keeps no state outside the
record and the pending requests, so what it holds for a program is
bounded by the program's tables and 16 requests, and what reaches its
mailbox from the program by the program's credit ([The program
protocol](#the-program-protocol)).

#### Facets

A **facet** is a process of the system domain that acts for one grantee
domain alone ([design-domains.md](design-domains.md#facets)). A program
holds no facet: it has no connection on which one could answer it. What a
program may hold instead is a **right beyond files**, a name and a scope
in its record that its handler checks and that its command domain, if it
has one, receives as a facet of its own. The ABI file's facet table names
each kind; two matter to programs:

| Right | What the handler allows for the program | What the program's command domain receives |
| --- | --- | --- |
| `inspect`, with a scope of domains | nothing in `liberx` itself: a program lists processes by running `ps`, an Erlang command | an `inspect` facet the system domain makes for the command domain, with no more than that scope, so `xargs ps` lists what the program may list |
| `signal`, with a scope of process ids: the session's, or one job's | `{kill, Pid, Signal}` for any process in the scope, as `kill` does, but for the stop and continue signals, which belong to the session's job control and get `eperm`; a process outside the scope, and pid 1, gets `esrch`, whether or not it exists | nothing further: its `kill` is the program's handler's |

A program holds no right by default: the shell hands a program only what
`within -f` names, and an entry of `/bin` that needs one declares it
([design-shell.md](design-shell.md#starting-programs)). A child inherits
its parent's rights whole, as POSIX inherits everything, and no spawn can
widen them; `within` narrows them for a command the shell starts. Anything
beyond its session, another session's processes or the inspector, is a
request the handler either refuses or answers from the session's policy.

### The program protocol

A program and its handler exchange frames of one grammar on the program's
channel, a frame profile of the ABI file with version 1
([design-abi.md](design-abi.md#program-protocol)), which both sides
decode with generated decoders that have fuzz targets. A request has the
form `{erx_prog, 1, Slot, Request}`, where `Slot`, from 0 to 15, is the
reply slot the requesting thread waits in, each slot holding one request
at a time; the reply is `{erx_prog, 1, Slot, Reply}`. The channel is
reliable and in order, so a request is sent once and answered once, and
nothing is numbered, kept or sent again. A request on a slot that already
holds one ends the program (Credit, below).

| Request | Meaning | Reply |
| --- | --- | --- |
| `{spawn, Path, Start}` | start a command: `Path` is resolved through the program's namespace to an executable with `rx` ([What a program can start](#what-a-program-can-start)); `Start` is the startup message's map without `pid`, `ppid`, `pgid`, `data_area` and `image`, each descriptor written `{pipe, End}`, `{socketpair, End, End}`, `{open, Open}`, `{dup, Fd}` or `null`, naming ends and opens the starter holds | `{ok, Pid}`; `{error, eperm}` without the right to start commands; `{error, Errno}` |
| `{kill, Target, Signal}` | signal one of the requester's own children, the requester itself, or a process its `signal` right reaches, `Target` being a process id; in the second tier, also a process group of the requester's own POSIX session, `{group, Pgid}` ([The terminal](#the-terminal)); `Signal` is a signal's name, or `0` to check that the target exists. When the requester is among the targets, its own report precedes the reply, so it takes the signal before `kill` returns, as POSIX requires | `ok`; `{error, esrch}` for any other target; `{error, eperm}` in the first tier for `sigstop`, `sigtstp`, `sigttin`, `sigttou` and `sigcont`, which belong to the session's job control |
| `{waited, Pid, N}` | the program's `wait`, `waitpid` or `waitid` returned the state of its child `Pid` whose count of state changes is `N`, and a `waitid` with `WNOWAIT` sends none ([A program's end](#a-programs-end)); the event executor sends it too for an exit that `liberx` reaps itself (Automatic reaping, below). When `N` is the record's latest for `Pid`, the handler marks that state taken, and for an exit the child leaves the record and the `children` quota, after which a `kill` of it fails with `esrch`; so a program cannot lift its quota by naming a child that runs | `ok`, also when `N` is not the latest, which changes nothing |
| `{stop, Signal}` | in the second tier, pause the program for a stop signal under its default action ([The terminal](#the-terminal)) | `ok` once the program has been paused and continued, so the reply reaches it only after it is continued; at once when POSIX discards the signal |
| `{file, Op}` | an operation of 9P2000.L for the program ([design-files.md](design-files.md#the-file-protocol)), with a path to resolve through the program's namespace, or the program's `Open`, in place of a fid: `walk`, `lopen`, `lcreate`, `read`, `write`, `clunk`, `close`, the program's own operation for a descriptor close that leaves its open other references, which releases the program's locks on the file and keeps the open ([Descriptors and files](#descriptors-and-files)), `remove`, `getattr`, `setattr`, `readdir`, `fsync`, `lock`, `getlock`, `link`, `symlink`, `mknod`, `renameat`, `unlinkat`, `readlink`, `mkdir`, `statfs` and the xattr operations; a read or a write names a count and a slot of the data area, and for `pread` and `pwrite` an offset, and its open's description supplies the offset otherwise; for `lock` and `getlock` the handler sets `ProcId` to the program's own, one per program, so its programs' locks conflict as UNIX processes' do ([Descriptors and files](#descriptors-and-files), [design-files.md](design-files.md#locks)) | the operation's reply, `{ok, Open}` for an `lopen` or an `lcreate`, `{ok, Count}` for a read or a write, mapped to `Errno` on failure |
| `{local, Op}` | an operation the session answers from its own tables, which reaches no server but by a `walk` or a `getattr`: `{seek, Open, Offset, Whence}` on the open's description, `{setfl, Open, Flags}` of the description's status flags, `{chdir, Path}`, and `{access, Path, Mode}`, answered from the rights of the grant the path resolves through ([Descriptors and files](#descriptors-and-files)) | `{ok, Value}`; `{error, Errno}` |
| `{tty, Open, Request}` | a terminal's `ioctl` for a `tty` open: `tcgetattr`, `tcsetattr`, `tcgetpgrp`, `tcsetpgrp` and the window size, which the handler takes to the session's terminal relay, the owner of every terminal of the session, never through the file protocol ([The terminal](#the-terminal)) | the relay's answer; `{error, enotty}` for any other open |
| `{watch, Open, Events}` | ask for one `{ready, Open, Events}` report once a terminal or a socket is ready for `Events`: the session's terminal relay answers for a terminal, and the socket's open-file description, over the socket protocol of [design-network-stack.md](design-network-stack.md#the-interface-towards-posix-programs), for a socket; a file is always ready, and the file protocol carries no watch ([The terminal](#the-terminal)) | `ok` at once, the report later |
| `{map, What, Use}` | give the requester an object of a file: for `Use` of `code` or `data`, the file's sealed file object, `What` a path the handler opens with `lopen` for reading, and for code only through a grant of the program's that carries `rx` ([File objects](#file-objects)); for `{shared, End}`, the session's object for the file, covering at least `End` bytes, `What` the program's `Open` of a file ([Shared libraries and mappings of files](#shared-libraries-and-mappings-of-files)) | `{ok, Cap}`, the object's capability value in the requester's table, and for a shared mapping `{ok, Cap, Open}`, with the mapping open that holds the requester's share; `{error, Errno}` |
| `{fork, Start}` | the second tier's `fork`: `Start` names what the child receives, planned as for a spawn: every descriptor without a `dup`, each as `{pipe, End}`, `{socketpair, End, End}` or `{open, Open}`, and the flags of `cloexec` ([Fork](#fork)) | `{ok, Pid}`; `{error, Errno}` |
| `{exec, Image, Start}` | the second tier's `exec`, first step, sent once the program's other threads are parked: build the requester's next image from `Image`, `{object, Cap}` for a file object of code that `liberx` obtained with `{map, Path, code}` and checked, or `{command, Path}` for a command of `/bin`; `Start` holds what the next image keeps that the parking froze ([Exec](#exec)) | `ok` once the next image is built, past which `exec` never returns; `{error, e2big}` past the message's bound; `{error, Errno}`; each error with the old image whole |
| `{exec_commit, Captured}` | the second tier's `exec`, last step, sent only after `ok` to `{exec}`: `Captured` holds what the old image captured in one step ([Exec](#exec)); the handler makes the reaps it names, as `{waited}` makes one, and builds the next image's startup message from the rest, `{exec}`'s `Start` and its record | none: the old image ends, and the new one finds its startup message in its lane |
| `{pipe, Flags}`, `{deposit, Descriptor, Stream}`, `{redeem, Stream, Ticket}`, `{discard, Stream, Ticket}`, `{withdraw, Stream, Ticket}` | make a pipe; and the second tier's passing of a descriptor over a stream, and letting go of a deposit that a `read` skipped or that a `sendmsg` could not publish ([design-pipes.md](design-pipes.md#the-program-protocol)) | as there |

`Errno` is one of the lower-case names of the ABI file's `errno` table,
which lists every name musl's `errno.h` defines, `etoomanyrefs` and
`enobufs` among them, and `Signal` one of its signal table's names; a name
outside them fails the grammar.

**Automatic reaping.** When `SIGCHLD` is ignored or its action has
`SA_NOCLDWAIT`, `liberx` reaps an ended child itself, as POSIX requires,
through the same `{waited, Pid, N}` that a `wait` sends, so the record and
the `children` quota let go of a reaped child as they do of a child waited
for. The event executor, which never waits, sends it from a reply slot of
its own, slot 15, the other 15 being the workers', one request at a time,
and takes the reply as an event. An `exec` captures the reaps still
unanswered, and the handler makes them at its `{exec_commit}`
([Exec](#exec)), so an image's end loses no reap, and an image that starts
with `SIGCHLD` ignored reaps in the same way each ended child its startup
message names.

A program also sends **notices**, as `{erx_prog, 1, Notice}` without a
slot, frames its handler takes without an answer; the thread that makes a change sends its notice in the same step,
under the outbound lane's lock, so a thread that stops between the change
and its send never takes the notice with it:

* `{closed, Pipe, End}`: the program's last reference to its pipe end went
  ([design-pipes.md](design-pipes.md#ends-and-their-holders));
* `{drained, Pipe, End, Writer}`: a read end drained the lane of a write
  end that is gone and let it go.

A read end finds a lane drained while it holds the end's lock, where it
may not wait for room in the outbound lane, so the `{drained}` it owes is
recorded in the end object. The call sends it once it has let go of the
end's lock; a thread that stops before that leaves it to the end's next
call or to its release, whichever comes first. So a stopped thread loses
no notice: the end, which outlives it, still owes it.

**Credit.** The port driver delivers a program's frames to its handler
only within the program's credit, which it keeps from the frames it
writes and reads and spends as it parses
([design-runtime.md](design-runtime.md#programs-as-ports)): a slot is
busy from the request the driver delivers on it until the driver takes
the reply on it; a `{closed, Pipe, End}` is due once for each pipe end
that a frame it wrote gave the program, in a startup message, a `pipe`
reply or a redemption's reply; and a `{drained, Pipe, End, Writer}` is
due once for each frame it wrote that names `Writer` gone to the read
end `End`, a `{pipe_writer_gone}` report, a join marked gone, or a
descriptor of a startup message or a reply. The driver never parses the
frames it writes: `send/2` encodes the term into the frame's bytes and, from
the same term, names the pipe ends the frame grants and the gone writers it
names; the driver counts those, and the one encoder cannot let them diverge
from the bytes. A descriptor gives at most two pipe ends, a socketpair's, so
the `{closed}` notices one frame makes due and those outstanding are each at
most two for each descriptor, twice `prog_fds_max` in all, which every
startup message fits; the `{drained}` ones outstanding are bounded by the gone
writers of the read ends the program holds, which the session's `pipes` quota
and the read-end bound limit. A send that would pass either bound is the
session's bug, refused whole with `einval`. A request on a busy slot,
and a notice that is not due, a repeated one included, are frames
outside the grammar and end the program with `SIGSYS`, as a malformed
record does. So the handler and the pipe server hold at most one message
of a program for each of its credits, 16 requests and one notice for
each end it was given and each gone writer it was told of, however fast
it writes.

The handler sends its program **reports**, as `{erx_prog, 1, Report}`,
which the program does not answer:

| Report | Meaning |
| --- | --- |
| `{exit, N, Pid, Status}` | a child ended: `Status` is `{exited, 0..255}` or `{signaled, Signal}`, and `N` the child's count of state changes ([A program's end](#a-programs-end)) |
| `{signal, Signal, Sender}` | a signal for the program, any but `sigkill` and `sigstop`; `Sender` is the process id of the program that sent it, or 1 for the session |
| `{stopped, N, Pid, Signal}`, `{continued, N, Pid}` | in the second tier, a child stopped by a stop signal or continued by `SIGCONT` ([The terminal](#the-terminal)); kept in the child table for `waitpid`'s `WUNTRACED` and `WCONTINUED` |
| `{ready, Open, Events}` | a terminal or a socket the program watches is ready for the events named ([The terminal](#the-terminal)) |
| `{server_gone, Open}` | the server of an open ended: the open's requests fail with `EIO` from then on |
| `{pipe_writer, ...}`, `{pipe_writer_gone, ...}`, `{pipe_reader, ...}`, `{pipe_reader_gone, ...}`, `{pipe_lost, ...}`, `pipe_server_lost` | the pipe reports of [design-pipes.md](design-pipes.md#the-program-protocol) |

A report of a child's state carries that child's count of state changes,
`N`, from 1, so a `{waited, Pid, N}` names one state; a signal report
carries no number, since the channel delivers each once (P13).

A program has at most its principal's `children` quota of children alive
or not yet waited for, and at most 15 requests of its workers in flight to
its handler, beside its event executor's one; a principal's sessions have
at most its `programs` quota of programs alive at once, of which a quarter
is kept for programs a shell starts
([design-system.md](design-system.md#resource-policy)).

A program reaches its own children, itself and the processes of its
`signal` right with one request, `{kill, Target, Signal}`, and `liberx`
raises no `kill`-sent signal locally, so a signal has one path: for
`sigkill` the handler of the target stops the target's anchor; for any
other signal it sends the target the report `{signal, Signal, Sender}`,
with the requester's process id as `Sender`; a signal `0` sends nothing.
`raise` and `pthread_kill` are thread-directed and local to the program.
A `kill` of a child that has ended but not been waited for succeeds and
does nothing, as POSIX says of a process that has not been waited for.

### Descriptors and files

`liberx` keeps one table per program of at most 1,024 slots. A slot holds
a reference to an **object** and the descriptor flag `FD_CLOEXEC`, so
`dup` copies the reference and clears the flag in the new slot, and
`F_SETFD` changes one slot, as POSIX divides them. An object is one of a
closed set of kinds: a pipe end
([design-pipes.md](design-pipes.md#ends-in-liberx)), which holds its own
`O_NONBLOCK`; a file, an **open** of the handler's table, which names the
file's open-file description in the session; a directory, an open;
`null`; a terminal, an open on the session's `/dev/tty`
or, in the second tier, on a pseudo-terminal; in the second tier, a
socketpair end, the read end of one pipe and the write end of another
([Passing descriptors](#passing-descriptors)); and a socket, an open of
a socket's open-file description. Each operation is a `switch` on the kind with no
default arm, so adding a kind makes the compiler name every operation
that must handle it. The table has one lock, which guards its slots and is
never held across a wait: a call takes a counted reference to its object
under the lock and works on the object after releasing it. So `close` of
a descriptor that another thread is reading empties the slot at once, and
the object goes with its last reference, a pipe end's mappings and
capabilities closed and its `{closed}` notice sent, or a file's open closed
with `{file, {clunk, Open}}`; and a slot is reserved while its object is
made, so a concurrent `open` or `dup2` never takes the same number. A
`close` of a file, directory or terminal descriptor that leaves its object
other references sends `{file, {close, Open}}`, once the program has
taken a record lock, since POSIX ends a process's locks on a file at
every close of a descriptor of it; the handler then releases the
program's locks on the file, as it does at the open's `clunk`
([design-files.md](design-files.md#locks)). A program that never took a
lock holds none, and sends nothing for such a close.
Descriptors 0, 1 and 2 are the standard streams. `isatty` is true for a
terminal object; the window size and every other terminal `ioctl` are
`{tty, Open, Request}` requests, which the handler takes to the session's
terminal relay, the owner of every terminal of the session, never
through the file protocol ([The terminal](#the-terminal)); and `ioctl`
on anything but a terminal fails with `ENOTTY`. The table belongs
to the image, so a change to it costs no frame to the handler beyond the
opens and closes it causes; an `exec` names its kept part in `{exec}`, from
which the handler builds the next image's ([Exec](#exec)).
**Open-file descriptions.** An `open` of a file, a directory or a terminal
makes an **open-file description**, as POSIX names it: a process of the
session that holds two fids at the file's server, an **unopened fid** of
the file and an **opened fid**, in the access mode and with the
`O_APPEND` that 9P2000.L's `lopen` carries, together with the file's
offset and its status flags. A description's unopened fid, while it has
one, names the file its opened fid opened
([design-files.md](design-files.md#open-files-and-offsets)). A `socket`
or an `accept` makes a socket's open-file description, a process of the
session too, which holds no fid and is the socket's owner at the network
service instead, and which the rules below for sharing, passing and
closing a description cover as they cover a file's
([design-network-stack.md](design-network-stack.md#the-interface-towards-posix-programs)).

The two fids arise at the `open`. `lopen` opens a fid in place, so
without `O_CREAT` the handler walks the path to the unopened fid, clones
it with a `walk` of no names, and opens the clone with `lopen`, which
makes the clone the opened fid. `lcreate` turns a directory's fid into
the created file's opened fid, so with `O_CREAT` the handler walks the
path's directory to one fid, clones it, sends `lcreate` on the clone, and
then walks the file's name from the directory's first fid, in place, to
make the unopened fid: one `walk` more than an open. A rename between the
`lcreate` and that walk can make the name reach another file, so the
handler compares the walked qid's path with the path in `lcreate`'s qid;
when they differ, or the walk fails, it clunks the walked fid, and the
description keeps its opened fid alone, through which its reads and
writes go on. Open flags travel as 9P2000.L's fixed values, those of
Linux's `9p.h`, not the architecture's own `O_*` values, and the
handler's codec maps them.

9P2000.L walks only from an unopened fid, so every further fid on the
file, for a re-open with other flags or for a mapping open, clones the
unopened fid with a `walk` of no names and opens the clone with `lopen`.
A description that kept only its opened fid answers each such re-open,
an `F_SETFL` of `O_APPEND` or a mapping open among them, with `ESTALE`,
the handler's own error, until it closes.

A description lives in the session, not at the server, where POSIX puts
it, and every open that names it, in any program of the session, shares
it: a `dup` shares one open, and a spawn, a `fork` or a passed descriptor
gives the receiver an open of its own that names the same description. The
description serializes the requests that use its offset, as a UNIX kernel
serializes a regular file's, and sends each read and write with an
explicit offset, as 9P2000.L does; it counts the opens that name it and
clunks every fid it holds when the last one closes. Its status flags are
the session's own: `O_NONBLOCK` is the description's alone, and a change
of `O_APPEND` with `F_SETFL` moves the description's writes to an opened
fid with the new flag, which the first change opens as above. The
description keeps its first opened fid, through which it takes every lock,
and the second for its life, so it holds at most two opened fids and
changing a status flag never ends a lock
([design-files.md](design-files.md#open-files-and-offsets)). `lseek` sets
the description's offset, with a `getattr` for `SEEK_END`, and asks the
server nothing else.

**Reads and writes.** A read or a write of a file, a terminal or a socket
is a request on the channel, `{file, {read, Open, Count, Slot}}` or
`{file, {write, Open, Count, Slot}}`, with an `Offset` after `Open` for
`pread` and `pwrite`, where `Slot` is a slot of the program's **data
area** that `liberx` took for this request
([design-files.md](design-files.md#native-clients-liberxs-file-client)):
the handler hands the request to the open's description, which sends
9P2000.L's `read` or `write` at its offset, or at the one named, over the
session's connection to the file's server and advances its offset by the
count, and the handler copies the reply's bytes into the slot, or the
slot's bytes into the request, through its NIF; the reply names the
count, and `liberx` then copies out of or into the caller's memory and
frees the slot. So no byte crosses the channel, no server reaches a
program's memory, and every server stays a plain process speaking frames.
A server's reply that names more bytes than the request asked for is never
copied: the generated reply check of `erx_file_remote`, the client the
handler speaks through, fails it with `eio`, and `liberx` copies no more
than the count it asked for, whatever count the handler answers
([design-files.md](design-files.md#bounds)). While the session maps the
file shared, the handler sends the read or write, at the same offset, to
the file's mapper instead, which serves it from the session's object
([Shared libraries and mappings of
files](#shared-libraries-and-mappings-of-files)). The data area is a
memory object the session creates from its own budget, since it maps the
area too, and maps read-write into the image; it holds `slots` slots of
64 KiB, the protocol's largest payload, 4 by default and set by the
session's policy for each program. A request larger than a slot is made
in parts, each part its own request, and a thread that finds no free slot
waits for one, in an open wait, so a program's data requests in flight
are bounded by its slots and a large read is never refused for the
area's size. An open is known to `liberx` by its number, which the
handler gave at `open` and checks on every request against the program's
own table.

**Files passed on.** A **pass** is the handler's alone: an open file
passes to a program as an open of its own in the receiver's table that
names the same open-file description, and the file's server is asked
nothing. So two programs given one file share its offset and its status
flags, as POSIX processes do: `{date; uname} >f` writes both outputs one
after the other, and `>[2=1]` is a `dup`, one object under two numbers.
A passed file reaches the program whatever its namespace holds, and a
file removed after it was opened stays readable through it, as on UNIX.
The shell's redirections open, create or truncate the file before the
spawn, as a UNIX shell does, and a redirection to `/dev/null` hands the
program a `null` descriptor. A pipe end's `O_NONBLOCK` stays in the
program that set it, since a child receives an end of its own. A
directory passes the same way, its description's unopened fid being the
one `openat` walks from, with the rights of the grant it was opened
through, and a terminal and a socket as a file does: the child gets an
open of its own on the same description, and an `exec` keeps a socket
descriptor without `FD_CLOEXEC`, so the network service sees none of it.
Moving a socket to another domain is not offered, since a socket acts
for its grant's domain alone
([design-network-stack.md](design-network-stack.md#the-interface-towards-posix-programs)).

**Devices.** The session's export serves `/dev/null`, `/dev/zero`,
`/dev/urandom`, the last from the kernel's entropy generator, and
`/dev/tty`, in every program's namespace that holds the export's `/dev`.
These, `/bin`, `/etc/passwd` and `/etc/group` form one tree of the
export, apart from the tree of each of the session's local providers,
named by its mount, and take their qid paths from the session's counter,
so no two files of one tree share a qid path
([design-files.md](design-files.md#narrowing-for-a-program)).
`/dev/tty` is the session's tty, which its terminal relay owns, and a
program's standard streams that go to the terminal are opens on it too,
so a program's output and error streams reach the terminal in the order
the program wrote them ([The terminal](#the-terminal)).

### File objects

A **file object** is a sealed memory object
([design-kernel.md](design-kernel.md#copy-on-write-children-and-copies-of-spaces))
that holds one file's bytes, read-only, for the programs of one session.
Its key is the file's identity and version, as
[design-files.md](design-files.md#identity-and-version) defines them, and
its use, `code` or `data`: the server's domain and the tree, the attach
name, of the grant the file was read through, the file's qid path, its
`data_version`, and the use. A code object has an execute ceiling, a data
object none. A domain's id is never reused and no other domain can answer
for it, so a server names only its own files; a server keeps a qid path
unique within its tree for the boot, and its domain's runtime never
repeats a version; so a changed file never matches an old object. A file
whose server reports no `data_version` has no version, so the session
enters no object of it in its table and reads it afresh for every map.

A **code object** is a sealed object with an execute ceiling, which only a
budget carrying `CODE` creates, the system domain's alone (K8): the
session's command server asks the domain service, over the session's
connection to the system domain, for one of the file's size, charged to
the session's budget, and the domain service gives it to the session with
`SUPPLY`, `READ`, `MAP`, `EXEC`, `CHILD`, `DUP` and `GIVE`, never
`DESTROY`, which the system domain's domain library alone holds
([design-system.md](design-system.md#creating-a-domain)). A **data
object** the session creates itself, from the requesting program's
budget, and gives to that program alone. The command server keeps a table
of code objects, at most `file_objects` (256 by default) and at most an
eighth of the session's budget
([design-system.md](design-system.md#resource-policy)), shared by every
program of the session that runs or maps the same file. It evicts one by
asking the domain service, over the session's connection, to drop it,
which the domain library does with `erx_dom_code_drop`; deleting one
removes every program's capability to it and every mapping of it, after
which an access would fault
([design-kernel.md](design-kernel.md#closing-and-deleting)), so it evicts,
least recently given first, only objects that no running program it gave
them to may still map, forked children included, since it is every such
program's handler and sees each one end. The objects it has not evicted
go with the session's budget.

To answer `{map, Path, code | data}`, the requester's handler starts a
**filler**, a process of the session's for this request alone, so that
neither the handler nor the command server ever waits on a file server.
The filler:

1. **Opens** the file through the program's namespace on every request,
   whatever the cache holds, with `lopen` for reading, after the
   handler's **image check** for `code`: the grant the path resolved
   through must carry `rx`. It takes the key from that grant and that
   fid's `getattr`.
   So the cache never answers for a grant: a
   program whose grant cannot open the file for its use gets the open's
   error, `EACCES` for code through an `ro` grant, even when another
   program's `rx` map put the object in the cache.
2. **Looks the key up** in the command server's table, and on a hit goes
   to step 5. On a miss the command server has the object made, a code
   object by the domain service and a data object itself, and hands the
   filler its `SUPPLY`; a request for the same code key meanwhile waits
   for this fill and gets its outcome, the object or the fill's error.
3. **Fills** the object, reading the file at the protocol's 64 KiB a read
   through the fid it opened and copying each read's bytes into a staging
   object of the session's, from which `erx_mem_supply` copies them into
   the file object; the call names its source as a memory object, an
   offset and a length, since no kernel call takes an address. It then
   asks that fid's `getattr` again. A version that changed while it copied
   means the bytes may mix two versions, so the object is discarded and
   filled once more, and a file that changes again fails the request with
   `ETXTBSY`, as Linux refuses to run a file open for writing. A read that
   fails or times out discards the object and fails the request with the
   read's error.
4. **Seals** the object and closes its `SUPPLY` capability, and the
   command server enters a code object under the key.
5. **Installs** it: the handler installs into the requester a copy with
   `READ`, `MAP`, `CHILD` and `DUP`, and `EXEC` for code, never `GIVE` or
   `DESTROY`, so a program can keep it across `fork` but cannot pass it
   on, and replies `{ok, Cap}`.

The filler clunks its fid and ends once the object is installed or the
request has failed. A file whose server changes it gets a new version, so
a later `map` makes a new object and programs that mapped the old one keep
the bytes they mapped, as `MAP_PRIVATE` allows. A program never holds
`SUPPLY`, so it never writes a byte of a file object.

A file that the session maps shared for writing changes under no request
until a write-back, so no version names its bytes while its mapper holds
a mapping that may write. Meanwhile the handler answers a `code` map of
it with `ETXTBSY`, and a `data` map with a data object the file's mapper
fills from the session's shared object, not from the server
([design-files.md](design-files.md#shared-mappings)).

## Algorithms and behavior

### The parties

The parties in a program's life, all but the first in its session:

* the **starter**, the shell or a program calling `liberx`'s spawn
  functions, which names everything the program receives;
* the session's **command server**, an Erlang process with process id 1,
  which keeps the session's process table (each program's process id,
  parent and job), serves the shell's spawns, assigns process ids, and
  creates one handler per program;
* each program's **handler**, the port's owner, which keeps the program's
  table, serves its requests and alone sends to it ([The
  handler](#the-handler));
* the session's **port driver** for programs, the C of the session's
  runtime that makes every kernel call about a program: it builds a
  sub-space from a plan the handler gives it, validated whole before
  anything is applied, writes and reads the channel's lanes, installs
  capabilities, pauses, resumes and stops spaces, and serves the session's
  fault gate, turning each fault and exit record into a message to the
  record's program's handler
  ([design-runtime.md](design-runtime.md#programs-as-ports));
* the session's **pipe server**, which makes every pipe end
  ([design-pipes.md](design-pipes.md#the-pipe-server));
* the system domain's **domain service**, which the session asks for a
  code object, to drop one, and for a command domain, over the session's
  connection to it
  ([design-system.md](design-system.md#the-domain-library));
* the program's own `liberx`, which reads the startup message, builds the
  program's tables and runs its event executor.

### Starting a program

A program starts in nine steps. Steps 3 to 7 are the starter's handler's
and the new program's handler's: they validate the request, resolve the
executable, reserve the program's id, ends and grants, and build the
sub-space, and each step's failure undoes exactly what the steps before it
reserved:

| Step | Who | What | If it fails |
| --- | --- | --- | --- |
| 1 | the starter | plans the spawn with `erx_spawn_plan`, a pure function from its descriptor table, its signal dispositions, the calling thread's mask and the spawn's file actions and attributes to a plan: the executable's path, `argv`, `env`, `cwd`, the signal mask, the ignored signals, the file mode creation mask and the descriptors, each named as the end or the open the starter holds. A plan that names a closed descriptor, or one number twice, is rejected | nothing happened; the spawn function returns the error |
| 2 | the starter | sends `{spawn, Path, Start}` to its handler and waits for the reply, in a closed wait ([Signals in liberx](#signals-in-liberx)) | as the step that fails |
| 3 | the starter's handler: **validate** | checks the frame against the protocol's grammar and bounds, the requester's right to start commands, its `children` quota and its principal's `programs` quota, and that every end and open the request names is in the requester's table | nothing to undo; `EPERM` without the right, `EAGAIN` at a quota, `EBADF` for an end or open the requester does not hold |
| 4 | the starter's handler: **resolve** | resolves `Path` through the requester's namespace to an image ([What a program can start](#what-a-program-can-start)); for an executable file, the handler makes its image check and a filler opens it for reading, and the command server makes or finds its code object ([File objects](#file-objects)) | nothing to undo, since a code object belongs to the cache; `ENOENT` for an unknown command, `EACCES` for a file without `rx`, `ETXTBSY` for a file that keeps changing while it is read |
| 5 | the command server, the program's handler, the pipe server: **reserve** | the command server assigns the next process id, records the program in the starter's job and creates the program's handler, which builds the record: it clones at each server, with a `walk` of no names, a grant for each entry of the requester's namespace, with the requester's rights there, and gives the program an open of its own naming the open-file description of each file, directory, terminal and socket open it hands on, which asks no server anything ([design-files.md](design-files.md#narrowing-for-a-program), [Descriptors and files](#descriptors-and-files)), copies the requester's rights beyond files and its right to start commands, and has the pipe server make an end of the same kind for each pipe end the request names ([design-pipes.md](design-pipes.md#inherited-ends)) | the command server marks the id dead, never to be given again, and drops the job's record; the handler clunks the grants it made, drops the opens it made, and tells the pipe server the ends are gone; `EMFILE` beyond a pipe's read ends, a server's error for a grant it refuses |
| 6 | the program's handler, through the port driver: **build** | hands the port driver one plan, which it validates whole and then applies. The plan first creates the channel and the data area from the session's own budget, since the session maps both and deletes them only after the program's budget. It then carves the program's budget from the session's pool for programs, with the floor as its guarantee and the cap the spec gives it, creates its group under the programs group, and creates the anchor, with the starter's anchor or the session's space as parent, the session's fault gate and a label of its own, and the image below it under another; the driver allocates both labels and never reuses them. It then maps the image, a program command's slices from the boot image with `erx_image_map`, or the loader `erx_exec` from the boot image for an executable file; installs into the image's table the budget, the group, the channel's two sides and the session's doorbell, the data area, each pipe end's copies as the pipe server handed them, and the code object for `erx_exec`; binds the program's doorbell to its group; and creates the first thread, stopped, with the values of the budget, the group, the channel's two sides and the session's doorbell in its argument registers | the plan is undone, the anchor stopped and released, which releases the image, and then step 5's reservations as there; `EAGAIN` for a program nested deeper than the kernel's 64 levels of spaces allow, about 60 generations of programs, `ENOMEM` for the session's budget |
| 7 | the program's handler | writes the startup message into the image's inbound lane, with the program's `pid`, `ppid` and `pgid`, the data area's value, each descriptor's values in the program's table, and for `erx_exec` the code object's value as `image` | none: the lane is the session's own memory |
| 8 | the session's job table, then the program's handler | when the program's starter is paused for its job, or the shell starts it for a job it has stopped, the port driver pauses the image first ([Job control](#job-control)); the handler then has the port driver start the first thread | `ERX_EDEAD` when the program was stopped first, by a kill or by its parent's or session's end: the starter still gets `{ok, Pid}`, then the child's end as `SIGKILL` |
| 9 | the starter's handler, then the program | the handler answers `{ok, Pid}`, before any report about the child, so the reply that introduces a child always precedes the child's states. `liberx`'s start-up runs on the first thread, a worker: it maps the channel, starts the event executor and waits on a umtx word; the event executor takes the startup message from the inbound lane, copying it out as it is published and checking it, and wakes the first thread, which maps the data area and its pipe ends, builds the descriptor table, sets its mask, arms itself for vCPU upcalls with its signal IRQ object and calls `main` | a malformed message ends the program with status 127 before `main` and without a line, since its descriptors come only from a message `liberx` accepted ([design-abi.md](design-abi.md#program-protocol)) |

The startup message is written into the lane before the program's first
thread starts, as much of it as the lane holds and the rest as the program
frees room, so no reply, report or signal can precede it: the handler writes nothing else into a new image's lane
first, and the lane keeps order. A fork message and the startup message of
an image that `exec` started follow the same rule. If the session ends
first, the program ends with it, since its anchor is below the session's
space. `liberx` takes every frame from its inbound lane as its session's,
which nothing else can write, and drops and counts any frame outside the
grammar of the protocol.

**On the stopgap.** The nine steps are the same code. Behind step 6, the
stopgap Fiasco's backend carries the port driver's plan as rows of its call
table ([design-stopgap.md](design-stopgap.md#the-call-table)): the anchor
and each image are Fiasco tasks that the root service creates at the
session's request, recording the parent and ending a space's sub-spaces,
children first, when it ends; the program's budget and group are records,
so the floor, the cap and the programs group's nine tenths are not
enforced and their tests report `unsupported` there; the channel's lanes
and the pipe ends are memory objects of the root's pool, each mapped by
the `liberx` of the task that uses it, and their doorbells IRQ objects
bound to the group of the side that consumes them, so a program's
doorbells reach the program task's readiness dispatcher; every install is
`erx_cap_pass` from the session's table into the program's space; the
session creates and starts only the image's first thread, as the backend
allows in a space its caller created; code objects are sealed by a flag
the root service checks at every map, and `erx_mem_copy` goes through the
root's windows. Each object is one request to the root service, so what a
start costs there does not decide whether erXos's kernel needs a cheaper
start path. A program's reach is its table and the servers' grants,
user-mode code, so P1 and the narrowed-program tests hold on the stopgap
for a program that goes through `liberx`; the parts of P2, P9, P10 and
P11 that rest on the kernel, and any hold on a program that bypasses
`liberx`, are erXos's kernel's
([What Phase 1 defers](design-stopgap.md#what-phase-1-defers)). Pauses and
signals have stopgap forms of their own ([Job control](#job-control),
[Signals in liberx](#signals-in-liberx)).

### What a program can start

Starting a command is a right: a program may start one only when its
startup message says `spawn => true`, which its record holds only when its
starter had the right, and its handler refuses every spawn request of a
program without it with `EPERM`, whatever the program sends. The shell
gives the right with `/bin`, so a program narrowed without `/bin` can start
nothing ([design-shell.md](design-shell.md#starting-programs)). What a
started command can do comes only from the capabilities its starter held:
its namespace, its rights beyond files and its descriptors (P2).

`posix_spawn` names the executable by path, which the handler resolves
through the program's namespace: a path that names nothing fails with
`ENOENT`, and one that names a file no `rx` grant reaches fails with
`EACCES`. `posix_spawnp` searches `PATH`, `/bin` by default, with `access`
and `X_OK` through the namespace, as POSIX says, so `which`,
`test -x /bin/grep` and `env grep` behave as on UNIX. The handler turns
the path into one of four images:

* **A program command.** The session's export serves `/bin`, an `rx`
  directory with one entry per command a program may start: the programs
  of the boot image that the session's command namespace lists, such as
  toybox's applets and `rc`, and the Erlang commands of the command
  shell's release ([design-shell.md](design-shell.md#commands)). For a
  program of the boot image, the port driver maps its image from the boot
  image with `erx_image_map`, its code shared with every program that runs
  it.
* **An Erlang command.** An Erlang command of `/bin` runs in the program's
  **command domain**: a domain the system domain creates at the session's
  request, the first time the program starts one and kept until the
  program's image ends, whose image is the **command image**, the runtime
  image with the command shell's release in program mode, in the
  interpreter flavour
  ([design-runtime.md](design-runtime.md#programs-as-ports)). Its name
  comes from the principal's pool of reusable names,
  `<principal>_<n>@<host>`, and is free again for that principal at the
  domain's end, so the command domains a principal's programs make over a
  boot hold one atom of the system domain's per slot of the pool
  ([design-system.md](design-system.md#identifiers)). The domain
  service builds it with the program's table: grants the handler clones
  for it from the program's namespace, a facet for each of the program's
  rights beyond files with no wider scope, made by the system domain for
  the command domain as grantee, and nothing else, so no ambient authority
  of the session exists there to reach. The command server gives each
  command run there a process id of the session's table, and the command's
  status becomes its exit status, as `rc`'s does. The command domain holds
  no pipe end and no open of the session's: its standard streams are
  relayed by a **stream relay**, a process of the session that holds the
  ends and opens the program handed the command and copies bytes between
  them and the command domain's connection, the session's one path to
  another domain ([design-domains.md](design-domains.md#connections)). The
  programs a command of that domain starts, as `rc -c 'a | b'` does, are
  sub-spaces of the session like any other, anchored under the program
  whose command domain it is, with pipes of their own between them.
  `xargs ps` lists processes when the program holds the `inspect` right
  and fails with `no_facet` when it does not.
* **An executable file.** Any other path names a file at some server. The
  handler has the file's code object made or found, after its image check
  of the program's `rx` grant and an `lopen` for reading
  ([File objects](#file-objects)),
  builds the sub-space with the boot image's **loader**, `erx_exec`, as its
  image, and installs the code object before the image runs, naming its
  value as `image`. After `liberx`'s start-up, `erx_exec` maps the object
  read-only, and `erx_elf_plan`, a pure function with a fuzz target,
  checks its bytes: an executable for the architecture and the ABI version
  erXos runs, static and position-independent in the first tier, with at
  most 16 loadable segments inside the file, page-aligned, not overlapping,
  none both writable and executable, its entry in an executable segment, and
  in the first tier no interpreter. The ABI version is carried by exactly
  one erXos ELF ABI note in a `PT_NOTE` segment. The note's owner is the six
  bytes `erXos` and NUL, its type is 1, and its descriptor is one
  little-endian `u32` ABI version; name and descriptor use ELF's four-byte
  alignment, so the complete note is 24 bytes. Its layouts and constants
  are generated from the ABI sources and checked against the pinned musl
  ELF definitions. Startup emits the note once through the generated C17
  declaration; the linker retains it and includes it in `PT_NOTE`.
  Missing, duplicate, truncated or unsupported notes fail with a diagnostic,
  even when duplicate versions agree. Unknown owners and note types are
  bounded metadata, not alternative ABI declarations. The note asserts
  interface compatibility; it authenticates no code. The boot packer uses
  this same ELF planner before producing the kernel's normalized image
  manifest ([image manifests](design-kernel.md#image-manifests)).
  `erx_exec` maps each executable segment
  from the object, read-only and executable, so its pages are shared with
  every program that runs the same file; maps each writable segment as a
  copy-on-write child of the object, so only the pages a program touches
  are copied into its own; and zeroes the rest in private memory. It then starts a worker at
  the executable's entry, passing the channel's values and a block holding
  the startup message's bytes and the ranges `erx_exec` occupies, and its
  own threads exit. The executable's own `liberx` decodes the startup
  message from that block with the same decoder, releases the block and
  `erx_exec`'s ranges, and starts as any program does.
* **`rc`.** The `rc` command runs in the program's command domain with an
  `rc` script: it runs the script with the shell's interpreter, with rc's
  own builtins, the Erlang commands of its release and the program commands
  of its `/bin` ([design-shell.md](design-shell.md#rc-as-a-program)), each
  with the capabilities `rc` holds, and ends with a status derived from
  rc's `$status`. It is what `system` and `popen` run
  ([The POSIX-lite personality](#the-posix-lite-personality)).

No other image exists: a program's code comes from the boot image or from
a code object reached through an `rx` grant, or is the command image. A
builtin or a function of the shell is never a program's to start, since
it acts on the shell itself and `/bin` lists none. The session's domain
runs only commands with the session's own authority: anything with fewer
capabilities, an Erlang command a program starts or one that `within`
narrows, runs in a command domain, so its confinement rests on the kernel,
never on the session's code.

**A command domain ends with its program.** A command domain's space hangs
below the system domain's, as every domain's does, so the kernel's rule
that a space ends with its parent does not end it with the program. What
does is a monitor: the session's request for a command domain names the
program's handler, the owner of its port, which the session exports to the
system domain with `send`, the right that covers monitoring, since no
frame can carry a port itself
([design-domains.md](design-domains.md#the-funnel)); the domain service
monitors the handler from the domain's creation and ends the domain when
the handler exits. A handler
exits once its port has closed, and a crash of the handler closes the port
with it, so the command domain of an Erlang command, of `rc`, of `system`
and `popen`, and of an `exec` into `rc` never outlives its program,
whatever ends the handler, the command server or the session. The
handler's own step at the program's end, which has the domain service end
the command domain, is the ordinary path ([A program's
end](#a-programs-end)); the monitor is what holds the rule.

### A program's end

Every end of a program is a record of the kernel's about the image's
space, a fault record of one of its threads or the space's exit record,
delivered at the session's fault gate with the label the port driver gave
the space ([design-kernel.md](design-kernel.md#threads-and-faults)). The port
driver turns a fault record into the program's end: it stops the anchor
with `ERX_EXIT_SIGNAL` plus the signal the ABI file's fault table gives the
fault's kind, and keeps the record for the shell. An exit record reaches
the handler as the port's exit status, and one pure function,
`erx_prog:status/1`, maps it, or `{fault, Kind}` for a fault record of
kind `Kind`, to the status the parent's `wait` sees, `{exited, N}` or
`{signaled, Signal}`, and to rc's `$status`. `ERX_EXIT_SIGNAL` is 256, so
no halt status from 0 to 255 reads as a signal:

| The image ended by | Status | `$status` |
| --- | --- | --- |
| a halt with status `n` from 0 to 255, which `exit(s)`, `_Exit(s)` and a return of `s` from `main` give as `n = s & 0xff` | exited `n` | empty for 0, else `n` |
| a halt with status `ERX_EXIT_SIGNAL + n`, `n` a signal of the ABI file's signal table that a program may name: a signal's default action, or `abort`, a failed assertion and `liberx`'s own fatal path, which halt with `SIGABRT` | signaled `n` | the signal's name, such as `sigint` |
| a fault of kind `k`, which the port driver turned into a stop | signaled with the signal the fault table gives `k`: `SIGSEGV` for a memory fault, `SIGBUS` for an alignment fault, an asynchronous error or an access to memory whose object was deleted, `SIGILL` for an undefined instruction, `SIGTRAP` for a breakpoint, `SIGSYS` for a foreign system-call trap or a frame outside the program protocol's grammar, `SIGKILL` for an exhausted budget | the signal's name; the shell prints the fault record |
| a stop by its session: `SIGKILL`, its parent's end (`ERX_EXIT_PARENT`), its session's end | signaled `SIGKILL` | `sigkill` |
| a halt with any other status, or the kernel's `ERX_EXIT_NOTHREAD` | exited 255 | `halt` and the status |

The function is total over every record the kernel can post: the fault
rows come from the fault table, which gives every fault kind its signal,
so a fault kind added to the ABI file without one fails the generator. On
the image's end the program's handler: has the port driver stop the anchor
with the same status, which stops every space below it, the program's
children and their trees, those not yet started included, and its own
sub-spaces (K27); hands each of the program's mapping opens to its file's
mapper, which writes back what the session's programs stored and closes
it ([Shared libraries and mappings of
files](#shared-libraries-and-mappings-of-files)); sends, on each file the
program locked, an unlock of the whole file for the program's `ProcId`,
so its record locks end with it even when a sibling keeps the
description they were taken through
([design-files.md](design-files.md#locks)); closes every other open of
the program, each open-file description clunking its fid once no open
names it; clunks the grants it cloned for the program
([design-files.md](design-files.md#narrowing-for-a-program)); tells the
pipe server the program's ends are gone
([design-pipes.md](design-pipes.md#ends-and-their-holders)); has the
domain service end the program's command domain, if one was made; and
tells the starter's handler, which sends the parent `{exit, N, Pid,
Status}`, or the command server, which records it for the shell. When the
anchor's exit record arrives, which the kernel posts only after every
space below it has ended, the handler has the port driver destroy the
program's budget, which deletes at once everything charged to it, its
spaces, threads and private memory among them, and then delete the
channel's objects and the data area, which the session charged to its
own budget and still maps, and close the group; the handler closes the
port and, since it serves one program, exits. So a program's whole
tree ends with it, as a Fuchsia job's processes do, while an `exec` of its
starter, which replaces only the starter's image, leaves it running, as
POSIX requires. By the user's decision, a long-running service starts
under a supervisor as a domain of its own, never as a detached program, so
nothing is orphaned. Process ids are never reused within a session, so a
`kill` never reaches a later program that took a dead one's id.

A program also ends when its last worker thread exits, as POSIX
prescribes: `liberx` counts the workers it starts, and when the last one
exits it stops its own space with status 0, since its event executor never
exits on its own. Only the image's record ends a program in its handler's
view. `exit` runs musl's `atexit` handlers and flushes `stdio`, then halts
the image with `erx_space_stop(ERX_CAP_SELF, status)`; it tears down
nothing of `liberx`. The image's end closes every kernel capability it
held, and the handler ends every open at its server, so a thread still
inside `liberx` when another calls `exit` never meets a freed structure.

### The event executor

A program's threads are workers, which wait on umtx words but cannot park
on the group, and the session announces frames and room only by ringing
the program's doorbell, an IRQ object bound to the program's group
([The channel](#the-channel)). So `liberx`'s start-up creates one executor
in the program's group, the **event executor**, before anything else, and
it is the only thread that reads the inbound lane and the group's ready
list:

* every request a worker sends names its reply slot, one of 15, each
  holding one request at a time, the 16th being the event executor's own
  ([The program protocol](#the-program-protocol)); the worker waits on a
  umtx word in its slot, and the event executor puts the reply there and
  wakes it, so one rule routes every reply, whichever thread asked;
* every pipe end the program holds has a doorbell the session bound to
  the program's group with the end's label, so the group's ready
  list names exactly the ends rung since the executor last looked, each
  once, and the executor wakes the workers waiting on those ends and
  evaluates their readiness for `poll`
  ([design-pipes.md](design-pipes.md#waiting-and-doorbells));
* the pipe reports go into the ends they name, under each end object's
  lock, and the executor wakes the end's waiters, so a reader learns of a
  writer that joined or went, and a writer of a reader that went;
* reports of children's states go into the child table, which `wait` and
  `waitpid` read; `{signal, ...}` reports go to the signal machine
  ([Signals in liberx](#signals-in-liberx)); `{ready, ...}` reports wake
  the workers waiting on that open; `{server_gone, Open}` fails the open's
  requests in flight with `EIO` and marks it dead;
* it advances the inbound lane's read position only after it has applied
  a frame (P13), and rings the session's doorbell when that store crosses
  the position the port driver published in the inbound ring's header.

Whatever it wakes a worker for, the executor first bumps that worker's
**wake word**, the umtx word every wait of `liberx` sleeps on
([Signals in liberx](#signals-in-liberx)). The event executor is an
executor, which the kernel never arms for vCPU upcalls (K20), so no signal
ever runs on it.

### Job control

The session stops a program by **pausing** its image: the port driver
calls `erx_space_pause` on the image's space, and every thread of the
image then waits at its next return to user mode, after finishing the call
it is in ([design-kernel.md](design-kernel.md#threads-and-faults)). The
session continues it with `erx_space_resume` and then sends `SIGCONT`, so
a program that catches `SIGCONT` runs its handler. Each pause has a
**cause**, which the session keeps in Erlang: the job table holds the
`job` cause, at `Ctrl-Z`, `fg` and `bg`, and the program's handler the
`signal` cause, at the stop and continue signals of the second tier ([The
terminal](#the-terminal)); the port driver pauses the image once for each
cause present, keeping the ticket each pause returns, and resumes each
cause's hold by its ticket when the cause is lifted, so the kernel
composes them and the image runs only when no cause remains. A
continue lifts both from its target, as POSIX's `SIGCONT` continues a
process however it was stopped: an authorized `SIGCONT` makes the
program's handler lift the `signal` cause and tells the job table, which
lifts the `job` cause and shows the job running, as a UNIX shell does once
one of a stopped job's processes runs; `fg` and `bg` lift the `job` cause
from every program of the job and send each `SIGCONT`. Each reaches only
its target, so an outer job's `fg` continues no program of another job,
and no continue lifts a hold that is not job control's, such as a `fork`'s
copy's, which is a hold of its own. The causes belong to the program,
so an `exec` of a paused program pauses its new image before the image's
first thread can run. Job control never changes a CPU grant. A program's
children belong to its job, which the command server records at each spawn
and fork, and a program created or forked while its starter is paused for
the job, or started by the shell for a job it has stopped, is paused
before its first thread starts, so `Ctrl-C` and `Ctrl-Z` reach the whole
tree: the terminal relay asks each handler of the foreground job to send
`SIGINT` or to pause its program
([design-shell.md](design-shell.md#job-control)). `Ctrl-Z` pauses a job
without sending `SIGTSTP`: the shell keeps the job's `termios` and restores
it at `fg`, and a second-tier program on a pseudo-terminal
gets its `SIGTSTP` from the terminal's line discipline instead ([The
terminal](#the-terminal)). `kill %N` of a paused job resumes it after the
signal, as a UNIX shell continues a stopped job it signals. Programs'
groups sit under the session's **programs group**, whose grant the session
sets to nine tenths of its own by default, so a busy program never slows
the relay that would stop it.

On the stopgap, which pauses no space
([design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)),
`erx_space_pause` fails with `ERX_ENOTSUP`, and the port driver records the
cause and pauses nothing: `Ctrl-Z` stops only the job's Erlang commands,
and the shell names the job's programs, which run on. A stop signal that a
handler would carry out with a pause then stops nothing: the handler sends
no stop report and answers a `{stop}` request at once, so no report shows a
running program as stopped.

### Signals in liberx

Signals are `liberx`'s, and the kernel only delivers a doorbell to an
armed thread as a vCPU upcall
([design-kernel.md](design-kernel.md#vcpu-upcalls)). `liberx` keeps
POSIX's rules for every signal of the ABI file's signal table: masks,
dispositions and pending sets accept them all, `raise`, `pthread_kill`
and a `kill` of the program itself deliver any of them, and signal 0
checks without sending. Three things lie outside `liberx`, and each has
one owner:

| What | Owner | What a program sees |
| --- | --- | --- |
| a fault | the kernel, which stops the thread and posts the record, and the port driver, which ends the program ([A program's end](#a-programs-end)) | nothing: no handler runs, whatever `sigaction` recorded |
| `SIGKILL` from another, and any end of the image | the target's handler, which stops the anchor | nothing |
| stopping and continuing | the session's job control, which pauses and resumes the image ([Job control](#job-control)) | `SIGCONT` after a continue; a program's own `SIGSTOP` fails with `EPERM`; `SIGTSTP`, `SIGTTIN` and `SIGTTOU` under their default action are discarded in the first tier, as POSIX discards them for a member of an orphaned process group, and in the second tier pause the program through its handler when its process group is not orphaned ([The terminal](#the-terminal)) |

**State.** `liberx` keeps the dispositions, the process's pending set, and
for each thread, in the order the threads were created, a pending set for
signals raised for that thread alone, a mask, a **depth counter**, a
**wake word** and an **unwind list**; and the threads waiting in
`sigwait` with their sets. Each thread has a vCPU state area and its own
**signal IRQ object**, created by `liberx` from the program's budget,
bound to that thread and to no other and created without `DUP`, so no
`fork` copies it, and armed and given its mask before it first runs. A
worker binds no other IRQ object, so an upcall always means a signal; the
IRQ object is only a doorbell, and what is pending lives in `liberx`'s
state, so triggers that coalesce lose nothing. The session triggers no
signal IRQ object: a signal from outside the program is a report on the
channel, which the program's own event executor turns into a trigger of
the target thread's object, so signals stay in order with the reports they
relate to, a child's exit before its `SIGCHLD` among them.

**Depth.** Every exported function of `liberx`'s program layer raises its
thread's depth on entry and lowers it on exit, through one entry macro,
which a build check finds at the head of every such function. While a
thread's depth is above zero, no handler runs on it, so a handler never
meets `liberx`'s descriptor table, lane, reply slots or child table
half-updated. musl's own functions, such as `malloc`, `printf` and the
`pthread` waits, run at depth zero and keep POSIX's rules for
async-signal safety. `liberx`'s program layer allocates only from its own
allocator, whose lock it takes only at a depth above zero, and never
calls musl's allocator or `stdio`, which a build check confirms from its
objects' symbols, so a handler that interrupts `malloc` may still call
any `liberx` function.

**Open and closed waits.** A wait of `liberx` is **open** when the thread
holds across it nothing that another party waits for and nothing that only
this thread can finish: there `liberx` may lower the depth to zero and run
handlers, `siglongjmp` may leave the call, and an `exec` may park the
thread. Every other wait is **closed**: it keeps the depth above zero, so
no handler runs there, no `siglongjmp` leaves it, and an `exec` waits for
it to end ([Exec](#exec)). A closed wait for a reply of the program
protocol has no deadline: the handler answers every request, since each of
its own waits on another party ends at that party's answer or at a
deadline of its own, so the wait ends at its reply. A wait is closed
unless its call declares it open, and a wait declared open is closed
while its thread holds an obligation (below), so a wait whose kind was
forgotten only delays a signal, and never abandons what one thread alone
could finish.

**Pending operations.** `liberx` keeps an **operation table**, one entry
for each thread, which the entry macro opens at a call's entry and closes
at its outermost exit. An entry names the call and counts its
**obligations**, the things the thread holds that only it can finish.
Each kind of obligation is recorded, through `erx_op_hold`, by the one
function that makes it, and let go of, through `erx_op_done`, by the one
that ends it:

| Obligation | Made by | Ended |
| --- | --- | --- |
| a request in flight | the channel's send, the only writer of the outbound lane, for every request whatever it asks | at its reply; `{exec_commit}`, which has none, holds its thread until the image ends |
| a claimed control record | the pipe core's claim, for a redemption or a skip ([design-pipes.md](design-pipes.md#reading-and-merging)) | when the record is retired |
| ring room reserved for a `sendmsg` | the end's reservation ([Passing descriptors](#passing-descriptors)) | when the room is published or given back |
| a lock `fork` keeps | `fork`'s locking step ([Fork](#fork)) | when `fork` releases it after its reply |

A thread's **closed region** is the span in which its entry holds an
obligation, and every decision about what a thread may abandon reads the
table and nothing else:

* a handler runs, and `siglongjmp` leaves, only at a wait declared open
  whose thread's entry holds no obligation, or at an outermost exit;
* an `exec`'s quiesce waits until no other worker's entry holds an
  obligation, the event executor, which is never parked, aside; meanwhile
  `erx_op_hold` refuses a worker's first obligation, and its call lets go
  of what it holds, a pipe's reader lock among them, and waits at the
  region's entry in an open wait, holding nothing of `liberx`'s; so an
  `exec` waits only for the regions under way, never for a call that sits
  in an open wait, whatever that call may do later ([Exec](#exec));
* the debug build asserts that every closed wait's entry holds an
  obligation and that every outermost exit's holds none.

So no list of calls says which enter a closed region: a request is an
obligation from its send, whatever it asks, so a request added to the
protocol needs nothing more, and a kind of obligation is a row of this
table, recorded by the function that makes it. A build check fails on any
write of the outbound lane in `liberx` outside the channel's send, and on
any call of `erx_op_hold` outside the functions this table names. The
waits a call declares open are those without a request in flight that
**Interrupted calls** lists below: a pipe's wait for data, room or a write
end's report, a wait for room in the outbound lane or for a free reply
slot, and a terminal's or a socket's wait for readiness. The debug build
asserts that no lock of `liberx`'s is held across an open wait.

**Raising.** A signal is raised for the process or for one thread. The
event executor raises the process's: the signal of a
`{signal, Signal, Sender}` report when it arrives; `SIGCHLD` once it has
recorded a child's report, so a handler's `waitpid` with `WNOHANG` always
finds it; and `SIGALRM` at its deadline. Taking a report of `SIGCONT`
drops the pending stop signals, and taking a stop signal's report drops a
pending `SIGCONT`, as POSIX says. A `kill` whose targets include the
program itself is a request to the handler like any other, whose report to
the program precedes its reply, so a signal has one path into a program
and `killpg(getpgrp(), SIGTERM)` delivers once. `raise` and
`pthread_kill` raise a signal for the calling or the target thread without
a frame, and a pipe write that fails with `EPIPE` raises `SIGPIPE` for its
own thread before it returns ([design-pipes.md](design-pipes.md#writing)).
A handler installed with `SA_SIGINFO` receives in `siginfo_t` the signal's
number and its origin: `SI_USER` with the sender's process id and the
principal's number for a signal sent with `kill`, by a program or by the
session; `SI_TKILL` for `raise` and `pthread_kill`; `SI_KERNEL` for
`SIGPIPE` and `SIGALRM`; and for `SIGCHLD`, `CLD_EXITED` or `CLD_KILLED`
with the child's process id and status.

**Deciding.** The raising thread decides with `erx_sig_arrive`, a pure
function of the state and the signal, by the first rule that applies:

1. a thread waiting in `sigwait` for the signal takes it; for a thread's
   signal, only that thread;
2. a signal that every thread it may go to blocks stays pending, for the
   process or for its thread, even when its action is to ignore it, since
   the action may change before it is unblocked (as on Linux), so
   `sigwait` for `SIGCHLD` works under its default action;
3. a signal whose action is to ignore it is dropped;
4. a default action that ends the program runs at once on the raising
   thread, as `erx_space_stop(ERX_CAP_SELF, ERX_EXIT_SIGNAL + N)` for
   the signal numbered `N`, which writes no frame and interrupts nothing;
5. a caught signal, and in the second tier a stop signal under its default
   action, stays pending, in the process's set or its thread's, and the
   thread it goes to is woken: its target, or else the first thread, in
   creation order, that does not block it; for a stop signal that thread
   runs `liberx`'s stop action where it would run a handler ([The
   terminal](#the-terminal)).

A pending signal is decided again, by the same function, whenever a
thread changes its mask, exits or calls `sigwait`, so a process signal
that its chosen thread blocks or outlives goes to another thread that does
not block it, as POSIX requires.

**Waking a thread.** To wake a thread for a signal, the raiser bumps the
thread's wake word, wakes it with `erx_umtx_wake`, and triggers its signal
IRQ object. Where the thread is decides what follows:

* **Running, with events enabled:** the kernel takes the event at once and
  enters `liberx`'s entry as an upcall, saving the interrupted frame in the
  thread's vCPU state area and disabling events.
* **Inside `liberx`:** the thread meets the signal at its next wait, which
  sleeps on the wake word and so returns at once, or at the outermost exit
  of its call; an upcall that arrives meanwhile finds the depth above zero
  and returns at once.
* **Waiting on a umtx word:** the kernel ends the wait with `ERX_EINTR` and
  enters the upcall, so the entry runs at once and the interrupted frame
  returns `ERX_EINTR`. Every wait of `liberx` treats it as a wake; it
  matters otherwise only for the waits musl makes at depth zero, such as a
  condition variable's, which musl retries as it retries Linux's `EINTR`.
* **In a kernel call:** the kernel interrupts no call, as Fiasco's vCPU
  interface does not; the event stays queued at the thread, and the kernel
  enters the upcall at the thread's return to user mode when the call
  ends, since no delivery stays queued while events are enabled
  ([design-kernel.md](design-kernel.md#invariants), K29). A program's
  kernel calls are brief, since it reaches every server through its
  channel and waits for replies on its wake word, so the signal waits at
  most until the call returns (P7). `liberx` never polls for a queued
  event at its exits; the vCPU state's pending flag is only a hint, for
  code that enables events by hand.

A wake can never be lost between a check and a sleep, because every wait
of `liberx` is one loop: read the wake word; stop if the call's condition
holds; run the pending signals the thread does not block; then sleep on
the wake word with the value read. A signal raised after the read changes
the word, and the sleep returns at once.

**The entry and the trampoline.** The entry runs on the interrupted stack
with events disabled and uses no FP. It reads the thread's depth and its
pending sets. If the depth is above zero, or no pending signal is
unblocked, it resumes the saved frame with `erx_vcpu_resume`, which
enables events again and, in the same call, enters the upcall anew if an
event arrived meanwhile. Otherwise it copies the saved frame onto the
interrupted stack, below the stack pointer and below any area the
architecture's procedure-call standard reserves there, which the
architecture's document gives
([design-arch-aarch64.md](design-arch-aarch64.md#thread-state)), and
resumes into `liberx`'s trampoline, so events are enabled again after a
few instructions. The trampoline saves the FP state, takes one deliverable
signal at a time and runs its disposition as an ordinary call under the
mask POSIX prescribes, and restores the FP state; then it disables events,
puts the interrupted frame back in the vCPU state area and resumes it with
`erx_vcpu_resume`, which restores every register at once.

**Running a handler.** A handler always runs at depth zero: at an open
wait or an outermost exit, `liberx` saves the thread's depth, sets it to
zero, runs the handler and restores it. Both places are safe because
`liberx` holds no lock and leaves no structure half-updated across an open
wait, a rule its debug build asserts, so a handler may call any `liberx`
function. From the start of an `exec`'s quiesce no handler runs on any
thread: signals stay pending, and the new image, or the old one if the
`exec` is refused, decides them ([Exec](#exec)). Before an open wait, a
call pushes onto its thread's **unwind list** an entry for each thing it
holds across the wait: its counted references to descriptor objects, a
descriptor slot it reserved, its `poll` registrations, and the readiness
it waits for; it pops them when the wait ends. `sigsetjmp` records the
depth and the head of the unwind list; `siglongjmp` out of a handler
undoes every entry above that mark, newest first, before it jumps: it
drops each reference, so a closed pipe end's mappings still go with the
last one, frees each reserved slot and removes each registration. It then
restores the depth and the mask it saved. A call left this way had no
request in flight, so nothing at a server is left half done.

**Interrupted calls.** A request already sent to the handler is never
abandoned because of a signal: its wait is closed, and the wait goes on
until the reply, so a write the server applied is never reported as
`EINTR`, and a file request is no more interruptible than a Linux read of
a regular file. Only waits with no request in flight are interrupted, by
POSIX's rules for each call:

| Calls | After a handler without `SA_RESTART` | With `SA_RESTART` |
| --- | --- | --- |
| a pipe read or write that waits, before any byte moved; `wait`, `waitpid`, `waitid`; a socket's read, write or `accept`, or a terminal's read, waiting for readiness | `EINTR` | restarted |
| a pipe, socket or terminal read or write after some bytes moved | the count moved | the count moved |
| `poll`, `ppoll`, `select`, `pselect`, `sigsuspend`, `pause`, `nanosleep`, `clock_nanosleep`, `sigtimedwait`, `sigwaitinfo` | `EINTR`; `nanosleep` reports the time left | `EINTR`; never restarted |
| file requests, `open`, `stat` and the rest that wait for the handler's reply; `posix_spawn` | not interrupted | not interrupted |

A socket's reads and writes, and a terminal's reads, wait for readiness
from their server's reports and send their request only once it is ready,
so they are waits without a request in flight ([The
terminal](#the-terminal)). A closed wait is not interrupted at all: its
signal waits until the call returns, as a signal waits for a kernel call
to end.

**The core.** `erx_sig_step`, the state machine over raising, deciding,
masks, depth changes, waits, wake words, upcalls, events left pending
across a call, thread exits, handler returns and `siglongjmp`, is a pure
function, of which `erx_sig_arrive` is the deciding step. It is explored
exhaustively on the host for up to three threads and three signals, with
an upcall arriving between every check and every sleep.

The executors of runtimes never take this path: the kernel refuses to arm an
executor for vCPU upcalls, so preemption still never runs runtime code
([design-scheduler.md](design-scheduler.md#the-runtime-contract)).

**On the stopgap.** Upcalls on the stopgap Fiasco are the backend's
`erx_vcpu_control` and `erx_vcpu_resume` over Fiasco's own vCPU
interface ([vCPU upcalls on Fiasco](design-stopgap.md#vcpu-upcalls-on-fiasco)),
which waits on a source check: whether Fiasco's kernel-mode
build offers that interface to a plain task, and whether its state area
can carry the ABI's `erx_vcpu` layout without exposing any of Fiasco's
([design-stopgap.md](design-stopgap.md#open-decisions)). If the check
passes, signals behave on the stopgap as this section describes. If it
fails, the backend refuses both calls with `ERX_ENOTSUP`, the first thread
arms nothing, and programs on the stopgap get default actions only: the
event executor carries out a signal's default action, ending the program
or ignoring the signal, a stop stops nothing, as under
[Job control](#job-control), and handlers run only on erXos's kernel.
`sigaction` with a handler then fails with `EINVAL`, the error POSIX gives
for a signal that cannot be caught, so no program mistakes the gap for
working signals, while `SIG_IGN` and `SIG_DFL` work. The vCPU conformance
tests, and the cases of `libc-test` and the Open POSIX Test Suite that need
a handler, then run only on erXos's kernel, and show as "cannot run" on the
stopgap with that reason.

### Signal numbers

erXos numbers its signals as FreeBSD 15.1 does, by the user's decision.
The command shell's `kill` takes FreeBSD's numbers and names
([design-shell.md](design-shell.md#job-control)), and programs built on
musl see the same ones, so a user meets one numbering: `kill -17` stops a
job whether the shell sends it or a program does, and the `WTERMSIG` a
parent reads is the number the shell takes. FreeBSD and Linux agree on the
numbers POSIX fixes for `kill -N`, 1 `HUP`, 2 `INT`, 3 `QUIT`, 6 `ABRT`, 9
`KILL`, 14 `ALRM` and 15 `TERM`, and differ on most of the rest: `STOP` is
17 on FreeBSD and 19 on Linux, `TSTP` 18 and 20, `CONT` 19 and 18, `CHLD`
20 and 17, `USR1` 30 and 10. macOS, the primary development host, uses
FreeBSD's numbers from 1 to 31. Programs are ported at the source level, so
no binary carries Linux's numbers, and code that names its signals, as
POSIX expects of every signal beyond those seven, needs only a rebuild.

**One table.** The signal table of `abi/erx_abi.txt` holds every signal:
its name, its number, its default action and its description. Every
consumer is generated from it
([design-generation.md](design-generation.md#sources-and-outputs)): musl's
signal numbers, the set of valid signals and `sigfillset`'s set, the names
and descriptions behind `strsignal`, `psignal`, `sig2str` and `str2sig`,
`liberx`'s maps between names and numbers, the program protocol's grammar
of signal names, `erx_prog:status/1`, the fault table's signal column, and
the names and numbers of the shell's `kill` builtin and of the Erlang
`kill` command. The numbers are external values: the table states each
literally, and the generator's mapping test compares it with FreeBSD
15.1's `sys/sys/signal.h` and the names in its `lib/libc/gen/siglist.c`,
fetched at a pinned URL and SHA-256 as a test input
([design-abi.md](design-abi.md#numeric-assignment-and-versions)).

| Number | Name | Default action | Notes |
| --- | --- | --- | --- |
| 1 | `SIGHUP` | terminate | |
| 2 | `SIGINT` | terminate | |
| 3 | `SIGQUIT` | terminate | |
| 4 | `SIGILL` | terminate | the fault table's undefined instruction |
| 5 | `SIGTRAP` | terminate | the fault table's breakpoint |
| 6 | `SIGABRT` | terminate | `SIGIOT` is its alias, as on FreeBSD |
| 7 | `SIGEMT` | terminate | FreeBSD's emulator trap; no fault kind maps to it, so only `kill` and `raise` send it |
| 8 | `SIGFPE` | terminate | |
| 9 | `SIGKILL` | terminate | cannot be caught, blocked or ignored |
| 10 | `SIGBUS` | terminate | |
| 11 | `SIGSEGV` | terminate | |
| 12 | `SIGSYS` | terminate | |
| 13 | `SIGPIPE` | terminate | |
| 14 | `SIGALRM` | terminate | |
| 15 | `SIGTERM` | terminate | |
| 16 | `SIGURG` | ignore | |
| 17 | `SIGSTOP` | stop | cannot be caught, blocked or ignored |
| 18 | `SIGTSTP` | stop | |
| 19 | `SIGCONT` | continue | |
| 20 | `SIGCHLD` | ignore | |
| 21 | `SIGTTIN` | stop | |
| 22 | `SIGTTOU` | stop | |
| 23 | `SIGIO` | ignore | `SIGPOLL` is its alias, as on Linux; Linux's default action for it is to terminate, FreeBSD's to ignore |
| 24 | `SIGXCPU` | terminate | |
| 25 | `SIGXFSZ` | terminate | |
| 26 | `SIGVTALRM` | terminate | |
| 27 | `SIGPROF` | terminate | |
| 28 | `SIGWINCH` | ignore | |
| 29 | `SIGINFO` | ignore | the status request of `Ctrl-T` ([The terminal](#the-terminal)) |
| 30 | `SIGUSR1` | terminate | |
| 31 | `SIGUSR2` | terminate | |
| 32 | `SIGTHR` | reserved | `SIGLWP` is its alias; musl's `SIGTIMER` |
| 33 | `SIGLIBRT` | reserved | musl's `SIGCANCEL` |
| 34 | none | reserved | musl's `SIGSYNCCALL` |
| 35 to 64 | none | not a signal | |
| 65 to 126 | `SIGRTMIN` to `SIGRTMAX` | terminate | real-time signals, named as `sig2str` names them: `RTMIN`, `RTMIN+1` to `RTMIN+30`, `RTMAX-30` to `RTMAX-1`, `RTMAX` |
| 127, 128 | none | not a signal | |

The default actions are FreeBSD's (`sys/kern/kern_sig.c`, `sigproptbl`),
and a real-time signal ends the program, as on FreeBSD. erXos writes no
core file, so the table has no core column and `WCOREDUMP` is never set.
The descriptions are FreeBSD's `sys_siglist` text. The protocol's name for
a signal is its name in lower case, `sigint` or `'sigrtmin+1'`, and its
name for `kill -l` and `str2sig` drops the `SIG`, `INT` or `RTMIN+1`.

**A number is a signal only if the table lists it.** One generated
predicate, `erx_sig_valid`, decides whether a number is a signal a program
may name, and it holds for 1 to 31 and 65 to 126 only. musl's set
functions, `sigaction`, `pthread_kill`, `kill`, `killpg` and `sigqueue`
test it in place of their own range tests, and `sigfillset` copies the
generated set of valid signals. A number it refuses fails with `EINVAL`,
and `sigismember` reports it absent; `kill`'s 0 keeps the meaning POSIX
gives it. So three kinds of number that would each need a rule of their
own are one case: musl's reserved numbers, the numbers 35 to 64 that
FreeBSD leaves unused, and 127 and 128, which FreeBSD's set can hold but
no wait status can report. `liberx` refuses such a number before it
writes a frame, so no frame carries one.

**Reserved numbers.** musl keeps its three internal signals where it has
them, `SIGTIMER` at 32, `SIGCANCEL` at 33 and `SIGSYNCCALL` at 34
(`musl/src/internal/pthread_impl.h`), and FreeBSD reserves the first two of
those numbers for the same purpose: `SIGTHR` for its thread library, which
cancels with it, and `SIGLIBRT` for its real-time library. musl's own
tests that a number is none of its internal ones, `sig-32U < 3` at each
site, stay true as written. Whatever musl does with them stays inside the
program, through the C library seam
([design-runtime.md](design-runtime.md#the-c-library-seam)), which on
erXos cancels by stopping the target thread rather than by signalling it;
none is a name of the program protocol. `<signal.h>` defines `SIGTHR`,
`SIGLWP` and `SIGLIBRT` under `_BSD_SOURCE`, as FreeBSD defines them under
`__BSD_VISIBLE`, so code that names them builds; `sigaction` of one fails
with `EINVAL`, as FreeBSD's thread library refuses `SIGTHR`.

**Linux's own names.** `SIGPOLL` stays, as an alias of `SIGIO`, which adds
no number and no line to `kill -l`. `SIGPWR`, `SIGSTKFLT` and `SIGUNUSED`
go. FreeBSD has none of them and erXos sends none. An alias would run a
power-failure handler on another signal, as `SIGPWR` sharing a number with
`SIGINFO` would run it at every `Ctrl-T`, and a number of its own would be
a signal nothing sends. Code that names them under `#ifdef`, as code that
builds on the BSDs and macOS does, builds without them; code that names
them unconditionally fails to compile, which shows the gap at build time
rather than at run time.

**Real-time signals and the set's size.** `SIGRTMIN` is 65 and `SIGRTMAX`
126, constants generated from the table, as FreeBSD's are; musl's
`__libc_current_sigrtmin` and `__libc_current_sigrtmax` go. `_NSIG` is
128, as in musl's MIPS port, so a set passed through the seam is 16 bytes,
whose 128 bits hold every number up to 128. `sigset_t` keeps musl's
128-byte storage, of which those 16 bytes are used. `NSIG` stays `_NSIG`,
128, where FreeBSD's is 32: code written for Linux sizes per-signal arrays
by `NSIG` and indexes them with real-time numbers, which an `NSIG` of 32
would overrun, while code written for FreeBSD indexes them with 1 to 31,
which 128 holds. `sysconf(_SC_RTSIG_MAX)` is 62. musl gains POSIX's
`sig2str` and `str2sig` and FreeBSD's `sys_signame`, `sys_siglist` and
`sys_nsig`, 32, all generated from the table, so FreeBSD's `kill(1)`
source builds unchanged. `strsignal` and `psignal` give the description
for 1 to 31 and `Unknown signal: N` for any other number, as FreeBSD's do.

**Where a number crosses a boundary.** Inside a program, `liberx` and
musl handle signal numbers. Outside it, a number appears only in a
space's exit status, which the port driver and `erx_prog:status/1` read
and write through the generated table; every message carries names.

* **The program protocol** carries names: `kill` and `killpg` turn the
  number into its name through the table before they write a frame, and the event executor turns the name of a `{signal}`,
  `{exit}` or `{stopped}` report back into its number. The session, its
  handlers and the shell never see a C number.
* **Wait statuses** keep musl's layout, which `liberx` builds from a
  child's report and `<sys/wait.h>`'s macros read: an exit as its status
  in bits 8 to 15 with bits 0 to 7 clear, an end by a signal as the
  signal's number in bits 0 to 6, a stop as `0x7f` with the stop signal's
  number in bits 8 to 15, and a continue as `0xffff`. FreeBSD lays out exits, terminations and stops the same way and
  marks a continue with `0x13`; a program reads a status only through the
  macros, which come from the same musl, so the layout stays musl's.
  Because a terminating signal fits in seven bits below the stop mark
  `0x7f`, no signal above 126 could be reported, and the table ends at 126
  as FreeBSD's `SIGRTMAX` does. A ported shell that shows a signal's end
  as 128 plus its number shows FreeBSD's number.
* **A space's exit status.** A default action that ends a program halts it
  with `ERX_EXIT_SIGNAL + N`, `N` the table's number; `erx_prog:status/1`
  turns it into `{signaled, Signal}` through the table, and a status whose
  `N` the table lacks reads as a halt with any other status, exited 255
  ([A program's end](#a-programs-end)). The kernel keeps that status as a
  number it never interprets, and its fault records carry a fault's kind,
  never a signal, while the fault table names the signal for each kind; so
  the kernel knows no signal number.
* **The shell.** The builtin `kill` reads `-N`, `-NAME` and `-s NAME`
  through the generated table, and `kill -l` lists the names of 1 to 31 in
  FreeBSD's order, as FreeBSD's `kill -l` does. The signals that act on a
  job of Erlang commands take their numbers from the same table
  ([design-shell.md](design-shell.md#job-control)).
* **Erlang.** `os:set_signal/2` takes names, and ERTS, built against
  erXos's musl, gets FreeBSD's numbers without a change to its source.

**The oracles.** musl's `libc-test` and the Open POSIX Test Suite run
against these numbers. A case that fails only because it assumes Linux's
is a documented difference, recorded with the kind `difference` in
`test/conformance/libc-test-verdicts.txt` and pinned by the tests of this
section. The kinds expected are a case that hard-codes a Linux number or
names `SIGPWR` or `SIGSTKFLT`; a case that assumes the real-time signals
begin below 65 or that `_NSIG` is 65, such as one that walks a set as 64
bits; and a case that compares `strsignal`'s text with musl's. libc-test's
`regression/sigprocmask-internal`, which checks that no number from 32 to
`SIGRTMIN - 1` can be added to a set or blocked, passes as written, since
the predicate refuses all 33 of them. OTP's suites compare with stock OTP
on macOS, whose numbers from 1 to 31 are the same.

### toybox

toybox enters the tree as erXos's code, with an `ORIGIN.md`, and builds as
one multicall program over the POSIX-lite personality. Its library's process
helpers, which use `vfork` and `exec`, are rewritten over `posix_spawn` in
erXos's tree, so `env`, `timeout`, `watch`, `xargs` and `find -exec` start
programs. Its applets that need a terminal, `fork` or process groups, such
as `sh`, `vi`, `less`, `login` and `setsid`, build in the second tier
([The second tier](#the-second-tier)); those that need priorities (`nice`)
or their children's resource use (`time`), and its Linux-specific applets
(`ps`, `top`, `kill`, `pgrep`, `pkill`, `free`, `uptime`, `mount`,
`ifconfig` and the other readers of Linux's `/proc`), are not built;
their names resolve to Erlang commands where one exists, such as `ps`
over the inspector and `kill` over the `signal` right, so no Linux `/proc`
is faked. Its awk is Ray Gardner's `wak`, which toybox keeps in its
pending directory ([research](research-boards-storage.md#the-toolbox));
erXos builds it from that file, and its `system()` and pipes to commands
run `rc` as `system` does below. toybox's own test scripts run against the
build ([Verification and testing](#verification-and-testing)), each
failure a bug, a documented difference with a test, or an upstream bug
recorded as such.

### The cost of a program

A program costs what a UNIX process costs plus what isolation needs, and
nothing outside its session: no domain, no work in the system domain, no
third party on any path. The budget for one program's start, with its
standard streams as opens on the terminal:

| What | Count | Memory |
| --- | --- | --- |
| parties | the starter, its handler or the command server, the program's handler, the port driver, the kernel; the pipe server when a pipe end is inherited | |
| frames | 2 on the starter's channel, the request and the reply; the startup message on the program's; one report to each peer of each inherited pipe end | |
| kernel objects | 1 budget, 1 group, 2 spaces, 2 memory objects and 2 IRQ objects for the channel, 1 memory object for the data area, 1 thread: 10; plus 3 for each inherited write end and 1 for each inherited read end ([design-pipes.md](design-pipes.md#the-objects-of-a-pipe)) | the two spaces' records, root translation tables and table pages, an estimated 16 KiB from the kernel's layouts; the channel, 48 KiB; the data area, 4 slots of 64 KiB by default; the thread's kernel stack and kernel-user page; 24 KiB for each inherited write end |
| kernel calls | about 23: the carve, the group, two space creations, three memory objects, two IRQ objects and their bindings, one to three image maps, the installs four capabilities at a time, the thread's creation and start | |
| Erlang | the handler's validate, resolve and reserve steps, one `walk` of no names at a server for each mount of the namespace, and nothing at a server for an open handed on | the handler, a process of a few KiB |

A program's start is budgeted at 1 ms under HVF, from about 23 kernel
calls at an estimated 1 to 2 us each, the clones over the session's
connections at an estimated 5 to 10 us each for a namespace of ten
mounts, the handler's Erlang steps and `liberx`'s start-up, which
`tools/erx bench spawn` checks against `posix_spawn` of the same applet on
the host ([Performance](#performance)). Four things keep it close to a
UNIX process:

* **Shared code.** A program of the boot image maps its code from the
  boot image's slice, and an executable or library from a code object,
  read-only and executable, so every program running the same file shares
  its code pages, and only the data pages a program touches are copied
  into its own.
* **No domain.** A program has no connection, no export table, no node
  name and no record anywhere but in its session: its channel is two
  lanes of 16 KiB, and its handler's record a few Erlang terms.
* **Pipelines at once.** The shell asks for a pipeline's programs in one
  request, which the handler plans as one and the port driver builds in
  one pass, so a pipeline's ends are installed before any of its programs
  runs.
* **Quotas from measurements.** A principal's `programs` and `children`
  quotas are `erx_policy`'s, and their defaults follow from the measured
  cost of the smallest program (experiment E-P1 of
  [Performance](#performance)): `programs` is the number of such programs
  that half of a principal's default budget holds, and `children` a
  quarter of `programs` ([design-system.md](design-system.md#resource-policy)).

### The terminal

**`/dev/tty`.** A session's terminal is a tty
([design-live.md](design-live.md#the-tty)), which the session's terminal relay
owns. The session's export serves it as `/dev/tty`, a file whose reads and
writes reach the relay, and a program's standard streams that go to the
terminal are opens on it, so one program's output and error streams reach the
terminal in the order the program wrote them, as they do through one UNIX
terminal. A write reaches the terminal exact, apart from the tty's output
flags, whichever job wrote it. A read returns what the line discipline gives
while the program's job is in the foreground, a line when the tty is cooked,
and waits while the job is in the background, as on UNIX. A terminal's
`ioctl`s are `{tty, Open, Request}` requests to the handler, which takes them
to the relay ([The program protocol](#the-program-protocol)). `tcgetattr` and
`tcsetattr` read and set the tty's `termios`, so a program can turn off `ECHO`
for a password prompt, or go raw and draw with control sequences. `TIOCGWINSZ`
answers from the size the master reports. A program opens `/dev/tty` through
its namespace, so a narrowed program without the export's `/dev` has no
terminal beyond the streams it was started with.

**Reading a terminal.** A terminal read waits for input before it asks for
it, as a socket's read does, so the wait has no request in flight and a
signal interrupts it by POSIX's rules ([Signals in
liberx](#signals-in-liberx)). `liberx` first sends its handler a watch, which the handler answers at once
and follows, once, with the report `{ready, Open, Events}` when the terminal has
input for that reader: a complete line in canonical mode, and otherwise
what `VMIN` and `VTIME` ask for, which the line discipline decides. Only
then does `liberx` send the read, which is answered at once, with bytes or
with `eagain` when another reader took them first, and `liberx` then
watches again. Several opens of a foreground job may read, as on UNIX, and
the relay serves their reads one at a time. A read under `O_NONBLOCK` is sent
at once and fails with `EAGAIN` on `eagain`. A blocking read watches
`{watch, Open, [read]}`, which is the line discipline's `read_wait` and starts
the timer that `VTIME` asks for. `poll` watches `{watch, Open, [in]}`, which
starts no timer and reports only when bytes wait, one byte with `VTIME` set and
otherwise `VMIN` of them, and reports `POLLIN` from that, so a `poll` never
consumes input or starts a read's time.
`Ctrl-D` at the start of a
line answers that read with no bytes, the end of file, and later reads go
on, as on a UNIX terminal. A job in the background gets no report in the
first tier, so its read waits until the job is in the foreground; in the
second tier the line discipline sends a background group that reads its
controlling terminal `SIGTTIN` instead.

**Writing a terminal.** A terminal write waits for room the same way, since a
stopped tty, a session not connected to the console among them, can leave it
waiting for as long as the session lives, and a request outstanding would hold up
a caught signal and another thread's `exec` ([Open and closed
waits](#signals-in-liberx)). `liberx` sends `{watch, Open, [out]}`, answered at
once and followed, once, by `{ready, Open, [out]}` when the relay has room. That
wait is open, so a handler runs in it. Only then does it send the write, which is
answered at once with the count taken, or with `eagain` when another writer took
the room first, and `liberx` then watches again. A blocking `write` goes on until
every byte is taken and returns that count, as on UNIX: if a signal interrupts it,
it returns the count so far, or fails with `EINTR` if nothing was taken. A write
under `O_NONBLOCK` is sent at once and returns the count, or fails with `EAGAIN`
on `eagain`. `poll` reports `POLLOUT` from the same reports. musl's stdio is
ordinary code above this: `__stdio_write` repeats on a short count, and a failed
`write` sets `F_ERR` and discards its buffer (`musl/src/stdio/__stdio_write.c`),
as it does on any UNIX.

**Status: `VSTATUS` and `SIGINFO`.** `termios` has FreeBSD's `VSTATUS`
character, `^T` by default, and its `NOKERNINFO` flag, clear by default.
With `ISIG`, `ICANON` and `IEXTEN` set, the line discipline turns the
character into a status request for the foreground job. The shell then
writes a status line for the job, unless `NOKERNINFO` is set, and asks the
handler of each of the job's programs to send it `SIGINFO`
([design-shell.md](design-shell.md#ctrl-t-status-and-the-info-request)).
`SIGINFO`'s default action is to ignore it, as on FreeBSD, so only a
program that catches it notices: a ported `cp`, `dd`, `sleep` or `fetch`
prints its own progress, as on FreeBSD. A `SIGINFO` from the terminal
carries the origin that a `SIGINT` from `Ctrl-C` carries. Linux has no
`SIGINFO`, `VSTATUS` or `NOKERNINFO`, so erXos's musl defines all three,
and the ABI file's signal and `termios` tables list them. `SIGINFO` is
29, its FreeBSD number, as every signal number is
([Signal numbers](#signal-numbers)). musl defines no `TIOCSTAT`,
so a ported program that uses it under `#ifdef` builds without it. `stty
status` and `stty kerninfo` set the character and the flag, as FreeBSD's
`stty` does.

**Pseudo-terminals, in the second tier.** A session's own tty is a
**pseudo-terminal** whose master is the console. In the second tier a program
can make another: `posix_openpt` gives it the master side, and the slave side
is a file `/dev/pts/N` of the session's export, which programs read and write
as opens. The session's terminal relay owns it, and the same line discipline
runs between the sides
([design-live.md](design-live.md#the-tty)). With `ISIG`, the characters for
interrupt, quit and suspend become `SIGINT`, `SIGQUIT` and `SIGTSTP` for
the terminal's foreground process group, sent through the handlers as any
signal is; with `ICANON` and `IEXTEN` also set, the status character makes
the relay write the group's status line and send the group `SIGINFO`
([design-shell.md](design-shell.md#ctrl-t-status-and-the-info-request)); a
change of the window's size sends `SIGWINCH`; the master's close sends
`SIGHUP`.

**Process groups and sessions, in the second tier.** A program may create
a process group or a session within its job, with `setpgid` and `setsid`,
and a session leader that opens a pseudo-terminal's slave first makes it
its controlling terminal. The command server keeps each program's group
and session in its process table; `tcsetpgrp` sets the terminal's
foreground group; a background group that reads its controlling terminal
gets `SIGTTIN`. A write by a background group with `TOSTOP` set follows POSIX:
the relay answers it `{background, Orphaned}`, and `liberx`, which alone knows the
program's signal state, decides. If `SIGTTOU` is ignored or blocked, it sends the
write again marked so, and the write goes through; otherwise, if the group is
orphaned, the write fails with `EIO`; otherwise the group gets `SIGTTOU`, and the
write goes on once it is continued. In the first tier, a job is one group that
counts as orphaned and takes no such signal, so `tcsetattr` with `TOSTOP` fails
with `EINVAL`, and a background job's write goes through.
Within one such session, programs stop and continue each other as POSIX
processes do, so a ported shell runs job control in a pseudo-terminal:

* **Sending.** `kill` and `killpg` of any signal, the stop and continue
  signals among them, reach a process or a process group of the caller's
  own POSIX session through `{kill, Target, Signal}`; the command server
  checks the target against its process table and hands the signal to each
  target's handler. When the targets include the caller, its handler sends
  it the signal's report before the reply, so the caller takes the signal
  before `kill` returns, as POSIX requires.
* **Stopping.** `SIGSTOP` always stops its target: its handler pauses it
  with the `signal` cause ([Job control](#job-control)), sends it no
  report, and sends the parent `{stopped, N, Pid, sigstop}`. `SIGTSTP`,
  `SIGTTIN` and `SIGTTOU` reach the program as signal reports, or are
  raised by the program itself, and under their default action the thread
  that takes one runs `liberx`'s stop action, since `liberx` cannot pause
  its own space: it sends its handler the request `{stop, Signal}` and
  waits for the reply in a closed wait ([Signals in
  liberx](#signals-in-liberx)), and until the reply comes, every other
  thread that would return from a `liberx` call waits for it too. The
  handler pauses the program with the `signal` cause, tells the job table,
  so the shell shows the job stopped, sends the parent
  `{stopped, N, Pid, Signal}`, and only then answers, so the reply reaches
  the program after it is continued; when POSIX discards the signal, one
  of those three in an orphaned group or one reported before a later
  `SIGCONT`, it answers at once. So a `kill` or a `raise` that stops the
  caller's own program returns only once the program is continued: `vi`
  and `less`, which call `endwin` and then `kill(0, SIGTSTP)`, redraw only
  after `fg`.
* **Continuing.** A `SIGCONT` that the `kill` rules let through ([The
  program protocol](#the-program-protocol)) lifts the `signal` cause, and
  through the job table the `job` cause, before the program's report of
  it, whether the program catches, ignores or blocks it, and the handler
  sends the parent `{continued, N, Pid}`. A stop signal drops a pending
  `SIGCONT`, and `SIGCONT` drops every pending stop signal, from the
  handler's owed reports and from `liberx`'s pending set, as POSIX says.
* **Waiting.** The parent's `liberx` keeps both reports in its child
  table, so `waitpid` with `WUNTRACED` or `WCONTINUED` returns each once,
  and tells its handler with `{waited, Pid, N}` before it returns one, so
  an image that an `exec` starts never returns it again ([The program
  record](#the-program-record)); `SIGCHLD` comes with `CLD_STOPPED` or
  `CLD_CONTINUED` unless `SA_NOCLDSTOP` is set.
* **Orphaned groups.** When a program's end or a change of group leaves a
  process group orphaned with a stopped member, the command server sends
  each member `SIGHUP` and then `SIGCONT`, as POSIX says.

The session's own job control pauses its programs beneath this with its
own cause, which such a `SIGCONT` lifts too, and its `fg` and `bg`
continue a job whatever stopped its programs ([Job
control](#job-control)). A program that never calls these keeps the first
tier's rule: its job is one group and one session, which counts as
orphaned, so no `SIGTSTP`, `SIGTTIN` or `SIGTTOU` of its own stops it.

**Full-screen programs.** A program such as `vi`, `less` or `top` goes raw
and draws with control sequences, which reach the terminal as it wrote them.
It needs nothing else from the console.

### The second tier

The second tier adds what programs that cannot be changed expect of a
UNIX: `fork`, the `exec` family, shared libraries and mappings of files,
and the terminals of [The terminal](#the-terminal). It rests on the
kernel's sealed objects, copy-on-write children and copies of spaces
([design-kernel.md](design-kernel.md#copy-on-write-children-and-copies-of-spaces))
and on the session's mappers, and keeps every invariant of the first: a
forked child is a program like any other, bound by its quotas, its
parent's tree and its handler, and no program executes code it can write
(P10).

#### Fork

`fork` copies the calling program into a new sub-space of the session,
eagerly: the first version copies every committed page of the parent's
private memory into fresh pages of the child, so each private page is
still mapped exactly once (K5), and copy-on-write is an optimisation it
does without. `liberx`'s `fork` takes the place of musl's and keeps its
shape (`src/process/fork.c`): the `pthread_atfork` prepare handlers first,
then the library's own locks around the copy with application signals
deferred, then the parent's or the child's handlers once the locks are
released and signals restored.

**What the child keeps.** The child keeps from the parent's memory,
besides the application's own, only musl's state, `liberx`'s allocator,
the signal dispositions and the calling thread's mask. Everything else
`liberx` keeps, the descriptor table and its objects, the child table, the
requests in flight, the pending signals, the other threads' records and
the event executor's own state, the child **rebuilds** from its fork
message with fresh locks. Each kept part is guarded by a **kept lock**,
which the calling thread holds from before the copy until the child has
rebuilt the rest, so the copy catches each kept part whole and the child
meets none of `liberx`'s state half made.

**The event executor takes no kept lock.** The calling thread holds the
kept locks while it waits for the reply to `{fork}`, and only the event
executor delivers replies, so an executor that waited for a kept lock
would never deliver that reply, and the fork would hang. The executor
therefore reads the dispositions and the threads' masks, which deciding a
signal needs, from atomic words that their writers update under the
dispositions' lock, and takes memory only from fixed pools of its own,
never from the allocator; a build check over `liberx`'s call graph fails
when a function the executor reaches takes a kept lock, and has a test
that seeds one. So a signal or a child's end that arrives during the copy
is recorded and decided as at any other time.

1. **Prepare.** `liberx` runs the `pthread_atfork` prepare handlers,
   newest first, before anything else, as musl does, so a handler may take
   any lock and call any function. It then defers application signals for
   the rest of the call and takes the kept locks in their fixed order: the
   locks musl's `fork` takes, `malloc`'s and the thread list's among them,
   then its allocator's and its dispositions'. Another worker that needs
   one of them waits for it, outside the kept state.
2. **Reserve.** It saves the calling thread's registers in its own memory
   and plans the child's descriptors as a spawn's, from its own table:
   each pipe end as `{pipe, End}`, each open as `{open, Open}`, and the
   flags of `FD_CLOEXEC`. It sends `{fork, Start}` to its handler and
   waits for the reply in a closed wait ([Signals in
   liberx](#signals-in-liberx)), since it holds the kept locks. The
   handler validates and reserves as for a spawn, steps 3 and 5 of
   [Starting a program](#starting-a-program): the right to start
   commands, the `children` and `programs` quotas, a process id in the
   parent's job, the child's handler, grants of the child's own for its
   namespace, and an open of the child's own naming the open-file
   description of each of the parent's opens, and a mapping open of the
   child's own for each of the parent's, walked and opened afresh, which
   the handler hands to the file's mapper; so parent and child share each
   description, as POSIX's `fork` does, and a `close` in one never closes
   a file of the other's
   ([design-files.md](design-files.md#narrowing-for-a-program)), and an
   end for each pipe end
   ([design-pipes.md](design-pipes.md#inherited-ends)).
3. **Copy.** The child's handler has the port driver carve the child's
   budget, create its group, its anchor below the parent's anchor and its
   image, empty; pauses the parent's image with `erx_space_pause`,
   recording the hold's ticket against the request; and then starts a
   **copier**, a worker thread of the session's space in the parent's
   group, which waits with `erx_space_quiesce` under that hold until
   the parent's threads have finished the calls they were in and copies
   the image into the child's with `erx_space_copy` under the same
   hold, so the copy is charged to the parent's CPU grant and runs at
   its urgency. The handler owns the hold: it resumes it by its ticket
   with `erx_space_resume` when the copier reports, whatever the
   outcome, and resumes it early to give the fork up, which ends the
   copier's quiesce, or its copy at the next part, with `ERX_EBUSY`,
   whatever other holds the session keeps on the parent, a job's or a
   signal's among them, which stay as they were; so no outcome leaves
   the parent held for the fork, and the copier never resumes. The
   pause holds the parent while it is copied, so the copy is one moment
   of the parent, and the copy charges the child's budget for the
   child's memory as it goes; one parent has one copy at a time
   ([design-kernel.md](design-kernel.md#copy-on-write-children-and-copies-of-spaces)).
   The kernel's copy table decides what crosses: the child's private
   memory is a copy of its own, the code and libraries the parent mapped
   stay mapped and executable, a shared mapping of a file stays shared,
   since the session creates its object with `ERX_MEM_INHERIT`,
   and no capability without `DUP` crosses, so the child holds no signal
   IRQ object, budget, space, thread, group, sub-space, channel object or
   pipe capability of its parent's, and none of its mappings of the
   channel or of pipe memory, which the session and the child's `liberx`
   make anew. The request stays pending in the handler meanwhile, which
   serves the parent's other frames (P3).
4. **Complete.** After the copy, which needs the child's image empty, the
   port driver fills the image with what a creation installs after the
   copy: the channel, the data area, the budget, the group, the child's
   pipe ends and its opens' values, a capability to each shared object of
   a file the parent maps, with the rights of the child's own mapping
   open, and the first thread, stopped, at
   `liberx`'s fork entry with the address of the saved registers; a
   failure of any of them undoes the child. The outcomes:
   * success: the session's job table adds the child to its parent's job,
     recording the child's job pause when its parent holds one; the
     handler writes the child's **fork message** into its lane, a startup
     message that names its process id, its parent, its data area and, for
     each descriptor, the values of its own end or open, marks each
     descriptor that has `FD_CLOEXEC`, and names each shared mapping of a
     file by its object's value and the child's own mapping open; it then
     has the port driver start the child's first thread, and answers the
     parent with the child's process id;
   * `ERX_ENOMEM`, a session or a child budget that cannot cover the copy
     or a step after it: `fork` returns -1 with `ENOMEM`, never later at a
     random write;
   * `ERX_EDEAD`: when the parent stopped during the quiesce or the
     copy, no `fork` is left to answer, the child having been undone;
     when the session stopped the child while the parent lives, `fork`
     returns -1 with `EAGAIN`;
   * `ERX_EBUSY`: the handler resumed the copy's hold before the copier
     reported, the one way to give a fork up without stopping the
     parent, which leaves the parent's other holds as they were; the
     child is undone, and `fork` returns -1 with `EAGAIN`;
   * any other status: `fork` returns -1 with `EAGAIN`.
5. **Parent and child.** In the parent, `liberx` releases the kept locks
   in reverse order and ends the deferral, so the deferred signals arrive,
   then runs the `pthread_atfork` parent handlers, oldest first, and
   returns the child's process id, or -1 with the error. The child's first
   thread starts at `liberx`'s fork entry, with the address of the saved
   registers and the child's own channel, budget and group values in its
   argument registers. There, holding the kept locks, `liberx` rebuilds
   the rest for the child before anything can contend: it forgets every
   thread but the calling one; maps its channel and reads its fork
   message; builds a fresh descriptor table from it, mapping its own pipe
   ends and data area; starts with no request in flight, no child and no
   pending signal; maps its own group's control and status areas and its
   time page where the parent's were, from the values its own fork message
   names ([design-scheduler.md](design-scheduler.md#data-model)); arms the
   calling thread for vCPU upcalls with a signal IRQ object of its own,
   made from its own budget; and starts a fresh event executor. It then
   releases the kept locks, runs musl's own reset of the child's thread
   state, as `fork.c` does, ends the deferral, runs the `pthread_atfork`
   child handlers, oldest first, and returns 0 from the saved registers.
   Nothing else of the parent's needs closing: the copy took no capability
   without `DUP`, and the child may keep every other it took, file objects
   and inherited memory among them.

Memory a program mapped `MAP_SHARED` and anonymous is a shared memory
object in the second tier, which `liberx` creates with `ERX_MEM_INHERIT`,
so the copy maps it into the child at the same address, and parent and
child share it as POSIX requires, as they share a `MAP_SHARED` mapping of
a file, whose object the session creates with the same flag; either lives
while parent or child maps or holds it. No other
shared memory crosses a `fork`, since nothing else is created to be
inherited. Only the calling thread continues in the child, as POSIX
prescribes. `liberx`'s own state reaches the child whole, kept under its
lock or rebuilt; the application's state, and the musl state that musl's
`fork` takes no lock for, a stdio `FILE` that another thread had locked
among it, reach the child as the copy found them, so a child of a
multithreaded parent may call only async-signal-safe functions until it
calls `exec`, as POSIX says. `vfork` is `fork`. The kernel's copy refuses
a space that maps a JIT object, and no program's space maps one on erXos's
kernel, where the second tier runs.

#### Exec

The `exec` family replaces a program's image with a fresh one under the
same anchor, keeping its process id, its parent, its job, its children,
its budget, its group and every descriptor without `FD_CLOEXEC`. What the
program keeps lives in two places: the handler's program record holds its
identity, its children and their states, its namespace, its rights, its
opens and its pipe ends ([The program record](#the-program-record)); and
the old image's `liberx` holds the rest, its descriptor table, its private
write positions and its signal state, which it hands to the record in two
requests. The kernel keeps nothing across the switch but the anchor, the
budget and the group: the next image is a fresh space with a fresh
channel, into which the session installs fresh copies of what the program
keeps, from its own table. One point of no return, the `ok` that answers
`{exec}`, splits `exec` in two, and one **switch**, at the old image's
exit record, moves the handler from the old image to the new one:

1. **Check, while the old image runs whole.** `liberx` resolves the path
   as `posix_spawn` does. For an executable file it asks its handler for
   the file's object with `{map, Path, code}`, maps the object read-only
   and checks it with `erx_elf_plan`; a command of `/bin` needs no check,
   since its image is the boot image's or the command image. A missing or
   malformed executable fails `exec` with `ENOENT`, `EACCES` or `ENOEXEC`,
   and arguments and an environment past 128 KiB fail it with `E2BIG`, as
   they fail `posix_spawn`'s planner.
2. **Quiesce.** `liberx` parks the program's other workers in two steps,
   so that nothing changes what it is about to hand over and nothing is
   abandoned ([Signals in liberx](#signals-in-liberx)):
   1. no worker enters a closed region: one that would waits at the
      region's entry, in an open wait, holding nothing of `liberx`'s.
      Every other worker runs on, in application code and in open waits,
      and no handler runs, until no closed region is under way: each goes
      on to its last closed wait, which ends at its reply. No closed wait
      of a program depends on another of its workers, so each region ends,
      and a worker that sits in an open wait, in a `recvmsg` of an empty
      stream or a `read` of a silent pipe, delays nothing;
   2. it then parks every other worker where it is: at a call's entry, at
      a region's entry, at its outermost exit, in its open wait, or, for a
      worker in application code, at its next upcall, which the worker's
      signal IRQ object triggers. A parked worker runs nothing until it is
      unparked or its image ends; its requests stay in flight and the
      event executor, which is never parked, records their replies, so
      parking abandons nothing.

   A worker that keeps its events disabled delays only its own program's
   `exec`.
3. **Ask.** `liberx` sends `{exec, Image, Start}`. `Image` names the
   object it checked by its value, or the command's path, so the object
   checked is the object run. `Start` holds the part of the next startup
   message that the parking has frozen, as the table below gives, with
   each kept descriptor named as the end or open it is, and the handler
   validates it as a spawn's and refuses, before any image is built, a
   startup message that would pass 192 KiB, counting the largest values
   `{exec_commit}` may add and every child at its largest state, with
   `E2BIG`. Once the program has taken a record lock, `Start` also names
   the open of each descriptor the old image drops, so the handler can
   release the program's locks on its file, as a `close` would. The port
   driver then builds the next image under the anchor, with a channel of
   its own and its first thread stopped, and the handler releases those
   locks and closes the opens of the descriptors the old image does not
   keep, its close-on-exec files, the mapping opens of its shared
   mappings, which end with the image and whose files' mappers write back
   what was stored, and the opens of requests parked workers have in
   flight among them, so close-on-exec holds at the servers too, and
   nothing the old image opened outlives it unseen. A refusal unparks the
   workers and fails `exec` with `E2BIG`, `ENOENT`, `EACCES`, `ENOEXEC`,
   `ENOMEM` or the handler's error, and the old image goes on whole; the
   locks are released and the opens closed only after the image is built.
4. **Let go.** Once `{exec}` has answered `ok`, `exec` never returns, and
   `liberx` brings the old image to rest: it captures in one step the
   process's pending signals, the calling thread's own, the alarm, and
   each `{waited, Pid, N}` of its automatic reaps that has had no reply
   ([The program protocol](#the-program-protocol)), so that no reap ends
   with the image; from the capture on, the event executor delivers
   replies, sends no reap and applies no report, leaving every later frame
   unread in the lane; and it sends `{exec_commit, Captured}` with what it
   captured and waits, in a closed wait without a deadline, for the image
   to end.

   The handler takes the `{exec_commit}`, makes each reap it names as a
   `{waited}` would, and has the port driver stop the old image. At the
   old image's exit record it makes the switch: it has the pipe server
   install into the new image fresh copies of each kept pipe end's lanes,
   lock page and doorbells, from the pipe server's own capabilities, and
   the port driver install a fresh data area and the code object; the old
   image's copies went with its table, and the port driver hands the
   handler the signal reports among the frames the old image had not read
   to their end, which it keeps whole until the program's read position
   passes each frame's end, and deletes the old channel's objects.
5. **Start.** The handler builds the new image's startup message as the
   table below gives and writes it into the new lane, then the signal
   reports the port driver handed back, and after them the signal reports
   it still owed the old image (P13); the port driver then starts the
   first thread. The new image then
   builds its tables from the message: it maps its channel and data area and
   each kept pipe end's pages; takes each write end's position from the
   handover, never from the ring, and each read end's lanes, open or gone,
   from the message; sets `O_NONBLOCK` where the handover names it; arms
   the alarm again; and builds its child table from `children`. When
   `Image` names an Erlang command or `rc`, the next image is the command
   image in the program's command domain, which takes the same message
   over its connection, with its streams relayed, and `rc` keeps the child
   table for its `wait`. The new image reaps each ended child of
   `children` itself when `SIGCHLD` is ignored ([The program
   protocol](#the-program-protocol)).

**What the next image keeps.** Each field of the next image's startup
message comes from one place:

| Field | Carried by | The new image |
| --- | --- | --- |
| `pid`, `ppid`, `pgid`, `spawn` | the handler's record | as any program does |
| `data_area`, `image` | the installs at the switch | as any program does |
| `argv`, `env`, `cwd`, `umask`, `sigmask`, `sigignore` | `{exec}`'s `Start`, every caught signal reset to its default action, as POSIX prescribes | as any program does |
| `fds` | `{exec}`'s `Start`: the descriptors without `FD_CLOEXEC`, each pipe end with the values the pipe server installed at the switch and each open with its number | keeps each object |
| `handover`'s `nonblock`, `wpos` | `{exec}`'s `Start` | sets `O_NONBLOCK` and takes each write position |
| `sigpending`, and `handover`'s `thread_pending`, `alarm` | `{exec_commit}`'s `Captured`, taken in one step | keeps the signals pending and arms the alarm |
| `children` | the handler's record at the switch, after the reaps `{exec_commit}` names | builds its child table, and reaps each ended child itself when `SIGCHLD` is ignored |

**The handler across the switch.** The handler serves one image at a time,
from that image's startup message until its `{exec_commit}`, and the
channel the frames arrive on names the image, so a frame of an image it
has stopped serving cannot reach it. From `{exec_commit}` until the switch it
sends the program nothing and owes what comes; at the switch it drops
every other frame it owed the old image and the replies it held for it,
since the startup message it then writes carries every child's latest
state and every signal report the old image had not fully taken follows
it, and nothing is installed into the old image's table, which is gone
(P11).

Anything that fails after `{exec}` has answered `ok` ends the program
with status 127, the same as a malformed startup message. A handover that
names a position the program never had harms only the program, since each
pipe's other holders still check what they read, and the startup message
names every child the record holds, so `wait` reaps every child. A socket
descriptor is kept or closed at `exec` by its `FD_CLOEXEC`, as a file's is
([Descriptors and files](#descriptors-and-files)).

`exec` never narrows what the program may reach: its namespace, its
rights and its right to start commands are the record's and survive
every image, so a command that must run with less authority is spawned,
as the shell's `within` does
([design-shell.md](design-shell.md#starting-programs)).

#### Shared libraries and mappings of files

**Shared libraries.** In the second tier `erx_exec` is also the dynamic
linker: an executable with dynamic dependencies, whose interpreter field
names erXos's loader, has its libraries loaded before its entry runs, and
`dlopen`, `dlsym` and `dlclose` use the same loader at run time. The loader
is musl's dynamic linker adapted to map file objects: it resolves a
library's name through the namespace's library path, `/lib` by default,
asks its handler with `{map, Path, code}` for the library's code object,
which the handler opens for reading after its image check of the
program's `rx` grant,
plans it with `erx_elf_plan`, maps its code read-only and executable from
the object and its writable segments as copy-on-write children, applies
relocations, which may write only those data segments, and runs its
initialisers. A library with text relocations is refused with `ENOEXEC`,
since its code pages are never writable, and `RELRO` segments become
read-only after relocation, beneath their mapping's ceiling. So a
library's code is shared by every program of the session that maps it, and
its data is copied page by page as each program touches it: the memory
model of QNX's shared libraries.

**Mappings of files.** `mmap` of a file with `MAP_PRIVATE` maps a
copy-on-write child of the file's sealed data object, read-write, or the
object itself when the mapping is read-only. A child is charged and
backed at its full size when it is made, so a writable private mapping
costs its program the mapping's size in memory at the `mmap`, admitted
or refused there, and the allocator's work of backing it; what is
deferred is the copying, one page at the first touch of each
([design-kernel.md](design-kernel.md#copy-on-write-children-and-copies-of-spaces)).
A copy-on-write child's parent is always
immutable, so a private mapping shows the file as it was when its object
was filled, from the server or, while the session maps the file shared for
writing, from the session's shared object ([File objects](#file-objects)),
and never later writes to the file, through a descriptor or a `MAP_SHARED`
mapping, which POSIX leaves unspecified and Linux shows until a page is
written: a documented difference with a test. A data object is charged to
the program that asked for it and given to it alone, so one program's
private mappings never deny its siblings theirs. `PROT_EXEC` in `mmap` or
`mprotect` stays refused, since only the loader maps code: a build check
confirms that `liberx`'s one function that maps code is referenced only
from `erx_exec`, and a program that maps code by other means still maps
only objects it cannot write (P10).

**Shared mappings of files.** `mmap` of a file with `MAP_SHARED` maps the
session's one object for that file: by the user's decision, a session
serves its programs' shared mappings, under the contract of
[design-files.md](design-files.md#shared-mappings), which this section
follows from the program's side. The object belongs to the file's
**mapper**, a process of the session that the command server starts at
the session's first shared mapping of the file and keeps in the session's
file table under the file's identity without its version: the server's
domain, the tree and the qid path ([File objects](#file-objects)). So a
file has one mapper and one object in the session however many programs
map it, through whatever mounts or paths (P14). The mapper holds the
object with every right, `SUPPLY` among them, which growing the object
and reading its store marks need, and never gives `SUPPLY` to a program.
It alone fills, grows and writes back the object, and it takes fills,
descriptor writes and size changes one at a time, so those steps never
race one another, and neither a handler nor the command server waits on
a file server. While it lives, the handlers send it every read, write and
size change of the file by the session's programs, and it serves them
from the object, as **What a shared mapping sees** below says. A program
maps a file in four steps:

1. **Check.** `liberx` checks the descriptor as POSIX requires: a file
   open for reading, and for `PROT_WRITE` open for reading and writing, or
   `mmap` fails with `EACCES`; a descriptor of another kind fails with
   `ENODEV`. A program that already holds the session's object for the
   file in that mode, covering the mapping's end, maps it at once.
2. **Open.** Otherwise `liberx` sends its handler
   `{map, Open, {shared, End}}`, naming the descriptor's open and the
   mapping's end. The handler makes the program a **mapping open**, an
   open of its table that no descriptor names, on a fresh fid walked from
   the unopened fid of the descriptor's open-file description and opened
   with `lopen` in that description's access mode, so it lives on after
   the descriptor's `close`; the mapping open keeps both its fids and
   clunks both when it closes. The handler hands the mapping open and
   `End` to the file's mapper and keeps the request pending (P3).
3. **Fill.** At the session's first mapping of the file, the mapper
   creates the object from the session's budget, within the session's
   **mapping quota**, which `erx_policy` sets, 64 MiB by default, with
   `ERX_MEM_INHERIT`, so a `fork`'s copy keeps it shared, and with `End`
   rounded up to a page as its size. It fills the part below the file's
   size with reads through the mapping open's opened fid, at explicit
   offsets and at the protocol's 64 KiB a read, copying each reply into a
   staging object of its own and from there into the object with
   `erx_mem_copy`; what lies past the file's size stays zero. No CPU store
   of the session touches the object, so the kernel's report of stored
   pages names only the programs' stores. The mapper keeps the object's
   **allocated extent**, what creating and growing it gave, apart from
   its **filled extent**, the pages a completed fill wrote, as
   [design-files.md](design-files.md#shared-mappings) defines them. A
   later mapping whose end passes the filled extent grows the object with
   `erx_mem_grow` when it also passes the allocated extent, and fills the
   pages past the filled extent the same way; the filled extent moves
   only when every read of the fill has completed, and no mapping is
   installed past it. Each fill reads through the opened fid of the
   mapping open it is for, so no program maps bytes its own open could not
   read.
4. **Install.** The mapper hands the handler a capability to the object
   with `READ` and `MAP`, and `WRITE` only when the mapping open allows
   writing, and no other right, never `DUP` or `SUPPLY`, so a mapping's
   ceiling is what the program's description allows and `mprotect` moves
   beneath it.
   The handler installs it into the program's image and answers
   `{ok, Cap, Open}`; `liberx` maps it and keeps the capability and the
   mapping open for the object and the mode. A step that fails fails
   `mmap` with its error: `EACCES`, `ENOMEM` beyond the mapping quota or
   the session's budget, or `EIO`.

**A failed `mmap` leaves nothing.** The mapper closes the mapping open
when a step of its own fails; pages it failed to fill stay past the
filled extent, covered by no mapping, and the next mapping of them reads
them again from the server without a second grow. An `mmap` that fails
after the handler answered, at its own `erx_vm_map`, closes the
capability and the mapping open. So repeated failures spend no open and
no more of the quota than the largest end asked for, and a mapper left
with no mapping ends and deletes its object.

**Faults.** Every page of the object is reserved and charged when the
object is created or grown, and filled before any mapping covers it, so a
fault on a shared mapping is the faulting program's alone and the kernel
resolves it from the object, as it resolves a fault on any memory the
session gave the program; no fault waits on another domain. The part of a
mapping past the file's end reads as zeros.

**Write-back.** The kernel records which pages of a memory object are
stored to, and the mapper writes back only those, with ordinary writes
through a mapping open that allows writing: it takes from the kernel,
with `erx_mem_dirty`, the pages stored to since it last asked, which marks
them clean, adds them to its own set of pages to write, and writes each
run of that set, copied out of the object into its staging object with
`erx_mem_copy` and cut at the file's size as the server reports it then. A
page no program of the session stored to is never written, so a write
made to it from elsewhere survives; a store made while its page is
written back marks the page again for the next write-back; and a write
that fails leaves its pages in the set. The mapper writes back:

* at `msync`: with `MS_SYNC`, which `liberx` sends as `fsync` on the
  mapping open and which the mapper answers once its writes and the
  file's `fsync` at the server are done, or with `EIO` when one of them
  failed; with `MS_ASYNC`, which the mapper answers once it has started
  the write-back; `MS_INVALIDATE` alone returns at once, since the object
  is the session's one copy;
* at every close of a mapping open: a program's last `munmap` of the
  file, at which `liberx` closes it; its `exec`, which closes it with
  every other open that no kept descriptor names, since the new image
  maps nothing of the old one's ([Exec](#exec)); and its end, at which its
  handler hands the mapper each of its mapping opens ([A program's
  end](#a-programs-end));
* at the `close` that leaves the session's programs no open of the file,
  before the `close` returns.

A `fork` gives the child a mapping open of its own, walked and opened
afresh from the unopened fid of the parent's, which the child closes at
its own last `munmap` ([Fork](#fork)). At the close of the last mapping
open the mapper writes back, deletes the object, of which it holds the
only `DESTROY`, and exits. Only a capability with `WRITE` stores, and the
mapper gives one only with a mapping open that allows writing, whose close
writes back; so a stored page has a writable open to reach the file
through until the last such open closes; a page whose write fails at that
close stays in the set until a later writable mapping open writes it, or
goes with the object. A program that closes its mapping open and keeps
storing harms only those stores, which a later write-back carries or the
object's deletion drops, after which its mapping faults with `SIGBUS`.

**What a shared mapping sees.** The session's programs see one another's
stores at once, since they share one object. Their reads and writes of
the file through descriptors agree with their mappings once each call
returns, since the mapper serves those from the object too: it sends a
descriptor write to the server first and, after the reply, copies into
the object with `erx_mem_copy` from its staging object only the prefix
the server acknowledged, so a write the server refuses changes nothing,
the server's data and size follow every descriptor write, and only
stores through mappings wait for a write-back
([design-files.md](design-files.md#shared-mappings)). A size change goes
to the server first, and the mapper then zeroes the object, again with
`erx_mem_copy`, as the change requires: a truncation from the new size to
the old, an extension from the old size to the new, and an extending
write only in the hole between the old size and its offset, before its
acknowledged bytes go in. So a mapping shows zeros past the end and an
extension never reveals stores a program made past the old end. The
mapper never changes the object
through a mapping, so `erx_mem_dirty` reports only the programs' stores. A
change to the file from outside the session reaches the file at its
server and not the object, so a shared mapping sees it only once every
program of the session has let go of the file and it is mapped again;
POSIX leaves the synchronization of a mapping with other access to its
file to the application. A reader elsewhere sees the session's stores
after a write-back, as a reader on another machine would, and so does
another session that maps the file shared: it holds a copy of its own,
and the two sessions see each other's stores only after a write-back,
page by page, as two machines that share a network file system do. The
program pays nothing for the object, which the session's budget pays for
within the mapping quota; a session that ends before its programs' ends
are handled, a crash included, ends the object with its budget and loses
the stores not yet written back. Documented differences, each with a
test: a change made outside the session is not seen by the session's
shared mappings of the file until they are made again; two sessions that
map one file shared see each other's stores only after a write-back, page
by page; a store past the file's end never reaches the file, where Linux
delivers `SIGBUS` for a page wholly past it; a mapping whose server ends
keeps its bytes, its write-backs fail and `msync`, `close` and a last
`munmap` fail with `EIO`, and the stores not yet written are lost when
the last program lets go; and `mmap` beyond the session's mapping quota
fails with `ENOMEM`.

**The right to make code.** None of this lets a program make code: it maps
code only from objects it cannot write, it is given a code object only
after the handler's image check of its own `rx` grant, and no program's
space is
a JIT space (P10). A program that holds both an `rw` and an `rx` grant
over one tree can write a library and load it, as it can write an
executable and spawn it; the shell's default namespace gives `rx` only for
`/bin` and the trees the user binds with it.

#### Passing descriptors

Programs that share a stream pass descriptors to each other, as UNIX
programs do with `SCM_RIGHTS`. `socketpair(AF_UNIX, SOCK_STREAM, 0)` gives
a program two descriptors of kind `socketpair`, each the read end of one
pipe and the write end of the other, made by the session's pipe server;
`posix_spawn`, `fork` and an earlier pass hand one of them to another
program as they hand any descriptor. `sendmsg` with `SCM_RIGHTS` sends a
message in three steps:

1. **Room.** It waits for room in its ring for a **control record**, a
   ring record of its own kind that carries the message's tickets and that
   no data can imitate ([design-pipes.md](design-pipes.md#the-ring)), and
   for the record of the message's first bytes, as a write waits for room,
   and reserves that room in its end, so no other thread's write to the
   end takes it. Under `O_NONBLOCK`, a ring without that room fails the
   call with `EAGAIN` before anything is deposited.
2. **Deposit.** It **deposits** each named descriptor with the session,
   naming the stream it sends on, and waits for the tickets.
3. **Publish.** It writes the control record and the first bytes into the
   reserved room and publishes them by one store, then sends the rest of
   the message as a write does.

From its first deposit to the publication, `sendmsg` waits only for the
deposits' replies and its withdrawals', in its closed region ([Signals in
liberx](#signals-in-liberx)): no handler runs there, `siglongjmp` cannot
leave it and `exec` does not park the thread there, so no thread leaves
behind a deposit it neither published nor withdrew. A deposit that fails
fails the call, and `sendmsg` withdraws those that succeeded with the
request `{withdraw, Stream, Ticket}`, waiting for each reply; so does a
`sendmsg` that finds its reserved room gone at publication, which only a
co-reader's rewrite of `rpos` can cause, before it starts again from its
first step. A deposit whose sender ended before publishing it closes once
the sender's lane is drained, so no deposit outlives a message that was
never sent ([design-pipes.md](design-pipes.md#deposits)).

Whichever program's `recvmsg` meets the control record **redeems** the
tickets, and the session installs what each stands for into that program,
as UNIX gives a descriptor to whichever process reads the message. The
reader redeems under its pipe's reader lock, so those waits are closed too
([design-pipes.md](design-pipes.md#reading-and-merging)). A `read`, or a
`recvmsg` without room for the descriptors, skips the control record: in a
closed region that begins when it claims the record, it retires the
record, releases the reader lock, and sends the request
`{discard, Stream, Ticket}` for each ticket, waiting for each reply, and
the session closes what the ticket stood for, as Linux closes the
descriptors a reader gives no room for (`MSG_CTRUNC`). A pipe end is
deposited as an end the pipe server makes at once, so the end stays open
while it is in flight, as on UNIX, and the sender keeps its own
([design-pipes.md](design-pipes.md#the-second-tier)). A `file`, `tty` or
`socket` descriptor is deposited as an open the sender's handler makes at
once on the same open-file description, and the redeemer's handler moves that
open into the redeemer's table at redemption, as `posix_spawn` hands a
file to a child; a directory passes the same way.

**A passed file's lifetime.** A passed file lives as on UNIX: its
open-file description lives while any open in any program's table names
it, a deposit's included, and clunks its fid when the last one closes
([Descriptors and files](#descriptors-and-files)). So a file passed with
`SCM_RIGHTS` outlives its sender, a sender spends nothing on a file once
it has closed its own descriptor, and a program that passes many files
does not run out. No capability passes between the programs, and the
file's server is asked nothing.

One message passes at most 16 descriptors, the tickets a control record
holds, and a `sendmsg` naming more fails with `EINVAL`, where Linux allows
253; each write end holds at most 16 deposits not yet redeemed, its own
share of its pipe's, beyond which `sendmsg` fails with `ETOOMANYREFS`, as
Linux fails a send beyond its limit of descriptors in flight.

## Interfaces

### The POSIX-lite personality

Every program whose image is a C program runs with a POSIX-lite
personality: musl's POSIX functions over `liberx`, enough to recompile and
link ordinary UNIX programs without porting them, statically in the first
tier and dynamically too in the second. Services and drivers do not use
it, nothing above the kernel interface depends on it, and no Erlang code
sees it but the session's command server, port driver and handlers, which
speak its protocol, and the command image in program mode. It is source
compatibility, not binary: there is no Linux system call. The bullets below
define it.

* **Descriptors** as above, with `dup`, `dup2`, `dup3`, `fcntl`'s
  `FD_CLOEXEC`, `O_NONBLOCK` and `O_APPEND` (the last passed to `lopen`
  by the file's open-file description, which opens a second fid with the
  other flag at the first `F_SETFL` that changes it and keeps its locks
  on the first), `fcntl`'s record locks, which end at every close of a
  descriptor of their file, `lseek` through the description's offset,
  and `pread` and `pwrite` at explicit offsets.
* **Processes.** `posix_spawn` and `posix_spawnp` are the spawn request.
  The child inherits every descriptor without `FD_CLOEXEC`, each pipe end
  as an end the session's pipe server makes for it, and each file as an
  open naming its open-file description; the file actions (`addopen`,
  `adddup2`, `addclose`, `addchdir`) shape the plan, and the attributes
  set the mask and the signals reset to their default actions. Attributes
  that set a process group, a session or a scheduling policy fail with
  `ENOSYS`.
  `wait`, `waitpid` and `waitid` read the child table, which the handler's
  reports and the spawn replies fill, and with `SIGCHLD` ignored or
  `SA_NOCLDWAIT` set an ended child is reaped at once, through the event
  executor's `{waited}` ([The program protocol](#the-program-protocol)),
  and `wait` fails with `ECHILD` once none remain, as POSIX says. A child
  that ended before its parent ignored `SIGCHLD`, and that the parent left
  unwaited across an `exec`, is reaped by the next image, which cannot
  tell it from a child whose end no image had taken; Linux leaves it to
  `wait`. In the first tier `WUNTRACED` and `WCONTINUED` report nothing,
  since only the session stops and continues programs; in the second they
  report the children that stop and continue within the caller's POSIX
  session ([The terminal](#the-terminal)). `kill` reaches the caller's own
  children, the caller itself, and the processes of a `signal` right's
  scope when the caller holds one ([Facets](#facets)). A **process id** is
  a number from 2 to 2^31 - 1 that the command server assigns to each
  program it starts, in order and never reused within the session, so a
  session that has assigned the last one fails every later spawn with
  `EAGAIN`; 1 is the command server, which `getppid` returns in a program
  the shell started. A process id is a POSIX name only: the system knows a
  program as a port of its session, and the inspector shows it under its
  session with its process id and command
  ([A program is a port](#a-program-is-a-port)). In the first tier `fork`
  and the `exec` family are absent from the C library, so a program that
  calls them fails to link rather than at run time, by the user's
  decision; the second tier provides them ([Fork](#fork), [Exec](#exec)).
* **Process groups and sessions.** A job is a session and a process group of
  its own, led by its first program, without a controlling terminal:
  `getpgrp`, `getpgid` and `getsid` return the process id of the job's first
  program, which the startup message carries as `pgid`, for the caller and
  its children, and fail with `ESRCH` for any other process; a program's
  children join its job. The group is orphaned, as POSIX defines it, since
  each member's parent is a member or the command server, which is in no
  job's session, so `SIGTSTP`, `SIGTTIN` and `SIGTTOU` under their default
  action are discarded. `waitpid` with a `pid` of 0, or of minus the
  caller's group, waits for any child, since every child is in the caller's
  group. `kill` with a `pid` of 0, of minus the caller's group or of -1
  signals the processes it may signal among those it names, its children,
  those of its `signal` right's scope, and then itself, which POSIX's rule
  of permission allows; any other group fails with `ESRCH`, and with
  `ECHILD` for `waitpid`. In the first tier `setpgid`, `setsid` and
  `tcsetpgrp` fail with `ENOSYS`; the second tier provides them
  ([The terminal](#the-terminal)).
* **`system` and `popen`** hand their command to `rc`, the command
  shell's language, by the user's decision: `system(cmd)` runs
  `rc -c cmd` with `posix_spawn` of `/bin/rc`, with `SIGINT` and `SIGQUIT`
  ignored and `SIGCHLD` blocked in the caller until it ends, as POSIX
  prescribes, and returns its wait status; `popen` runs it with a pipe to
  its standard output or input, and `pclose` returns its wait status.
  `system(NULL)` is non-zero when `/bin/rc` resolves in the caller's
  namespace and the caller may start programs, and 0 otherwise; a spawn
  that fails makes `system` return -1 with its `errno`, as POSIX says when
  no child can be created. The command is rc, not sh: `2>&1`, `$(...)`,
  double quotes and `export` mean other things or nothing in rc, so a
  ported program's commands follow the translations of
  [design-shell.md](design-shell.md#rc-as-a-program).
* **Pipes.** `pipe` and `pipe2` ask the session's pipe server for a pipe
  whose first ring holds 64 KiB, Linux's default capacity (pipe(7));
  writes of at most 4,096 bytes are atomic, as `PIPE_BUF` promises
  ([design-pipes.md](design-pipes.md)). Every pipe end a program holds was
  made for it: what it hands to a child is an end the pipe server makes
  for the child, so an end has one holder. A pipe has any number of write
  ends, within the session's quotas, and at most 64 read ends at once, the
  starter's own included: a spawn or a fork that would make a 65th read
  end fails with `EMFILE`
  ([design-pipes.md](design-pipes.md#compatibility-and-migration)).
* **Waiting on several descriptors.** `poll`, `ppoll` and `select` wait,
  with the call's deadline, on the caller's wake word: the event executor
  bumps it when a doorbell rings for a descriptor. Before reporting a pipe
  end ready, `poll` confirms its state from the end's lanes and reader
  pages ([design-pipes.md](design-pipes.md#readiness-poll-and-select)), so
  a read or write the program made since the executor's last look never
  leaves a stale `POLLIN` or `POLLOUT`: a read end is readable while a
  lane holds a record and reports `POLLHUP` once no write end remains, a
  write end is writable while its ring has room and reports `POLLERR`
  once no read end remains, as Linux reports them. A regular file is
  always ready, a terminal and a socket by their `{ready}` reports. The
  ready list has no fixed size, so `poll` has no limit on the number of
  descriptors but the table's.
* **Signals.** POSIX's signals, for every signal of the ABI file's signal
  table, which lists those musl's `signal.h` defines, with `sigaction`,
  `sigprocmask`, `pthread_sigmask`, `pthread_kill`, `raise`, `kill`,
  `sigsuspend`, `sigwait` and their relatives, under POSIX's default
  actions ([Signals in liberx](#signals-in-liberx)). `alarm` and
  `setitimer` with `ITIMER_REAL` raise `SIGALRM` from the event executor's
  park deadline; the other timers fail with `EINVAL`. `sigaltstack` fails
  with `ENOSYS`.
* **Memory.** `mmap` of anonymous memory with `MAP_PRIVATE` is private
  memory, and with `MAP_SHARED` a shared memory object, which a forked
  child shares. Address space is free and pages are paid for when they
  are promised: a private anonymous `mmap` with `PROT_NONE` is an
  `erx_vm_reserve`, which costs its record and nothing else however
  large, so a program reserves what it may need; with any other
  protection it is a reserve and a commit, charged to the program's
  budget in full at the call, as QNX charges an anonymous mapping at
  `mmap`: when the commit is refused, `liberx` releases the reservation
  it just made, so nothing of the call remains, and `mmap` returns
  `MAP_FAILED` with `ENOMEM`; a mapped page never faults for lack of
  memory (K6). A shared anonymous `mmap` is charged whole at the call
  whatever its protection, `PROT_NONE` included, since a shared object's
  pages are its budget's from its creation, which is a documented
  difference from QNX ([Compatibility and
  migration](#compatibility-and-migration)). `mprotect` moves memory
  among no access, read-only and read-write with the kernel's
  `erx_space_protect`, which changes the protection of the mappings in a
  range and keeps their contents, beneath each mapping's ceiling: over
  reserved memory a protection other than `PROT_NONE` commits it,
  charging the program's budget at the `mprotect`, which fails with
  `ENOMEM` when the budget cannot cover it and leaves the pages before
  the refusal accessible, as POSIX allows of a failed `mprotect`; a hole
  in the range, which the kernel reports as `ERX_ERANGE` with the parts
  before it applied, is `ENOMEM` too, as POSIX requires for an unmapped
  page; `mprotect(PROT_NONE)` over committed memory keeps the pages,
  their contents and their charge, which only `munmap` gives up.
  `PROT_EXEC` never reaches the kernel from a program: `liberx` refuses
  it in `mmap` and `mprotect` with `ENOTSUP` before any call, since only
  the loader maps code (P10), so a ceiling check in the kernel meets no
  execute protection from a program. `MAP_NORESERVE` is accepted and has
  no effect, as on QNX. musl's own `malloc` relies on this: it maps its metadata areas
  with `PROT_NONE` and unprotects a page at a time with `mprotect`
  (`musl/src/malloc/mallocng/malloc.c`, `alloc_meta`)
  ([design-kernel.md](design-kernel.md#virtual-memory)). `mmap` of a
  file with `MAP_PRIVATE` maps a copy-on-write child of the file's
  object, or the object itself when read-only ([File
  objects](#file-objects)), so later
  writes to the file do not show through the mapping, which POSIX leaves
  unspecified, and the part of the range past the file's end reads as
  zeros; how the stopgap kernel, which has no copy-on-write children, does
  without them is in its scope table
  ([design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)).
  A `MAP_SHARED` mapping of a file is the second tier's: it maps the
  session's one object for the file, which agrees with every other shared
  mapping of the file in the session and with the session's descriptor
  reads and writes of it, and reaches the file at its server at `msync`
  and as programs let go of it ([Shared libraries and mappings
  of files](#shared-libraries-and-mappings-of-files)), and it fails with
  `ENOTSUP` in the first. `PROT_EXEC` in `mmap` or `mprotect` fails with
  `ENOTSUP`: only the loader maps code (P10).
* **Users and files.** `getuid`, `getgid` and their relatives return the
  principal's number, never 0. `/etc/passwd` and `/etc/group`, which the
  session's export serves, hold the session's principal and `nobody`
  (65534), the owner a file shows when its server records none. `open` and
  `mkdir` send the mode they create with, less the `umask`, in 9P2000.L's
  `lcreate` and `mkdir`; `chmod` changes the mode a server records, with
  `setattr`; `chown` fails with `EPERM` unless it changes
  nothing; none of them changes what a program may reach, which grants
  alone decide. So `access` and `faccessat` walk to the file and answer
  from the rights of the grant the path resolves through: `W_OK` needs
  `rw`, and `X_OK` needs `rx` for a file and any grant for a directory, so
  `test -w` and `test -x` predict what `open` and `posix_spawn` do; a
  server's own refusal, such as a read-only file of `/proc`, shows when
  the file is opened.
* **Time and resources.** `getrusage` of `RUSAGE_SELF` reports the
  program's group's CPU time from its status area as user time, with no
  system time, since the kernel does not split them; `RUSAGE_CHILDREN`
  fails with `ENOSYS`, since a parent does not learn its children's
  usage. `nice` and `setpriority` fail with `EPERM`: a program's share of
  CPU is its session's to set ([Job control](#job-control)).
* **Errors and absent calls.** One table in `abi/erx_abi.txt` lists every
  `errno` name musl's `errno.h` defines, `ETOOMANYREFS` and `ENOBUFS`
  among them, and declares directed mappings for every kernel status and
  every error atom of the file and program protocols. A mapping names its
  operation or translation context where the same status has different
  POSIX meanings. Ruby generates C/Erlang/Ruby translations and diagnostic
  names; there is no default, so a missing mapping fails generation rather
  than becoming `EIO`. A consumer that cannot expose a status declares that
  explicitly. Unknown external codes follow the protocol's specified
  fallback, and numeric values are checked against the selected musl
  headers and 9P's Linux numbering
  ([design-generation.md](design-generation.md#inspection-and-diagnostics)). No call reports
  success without acting: a facility that is absent fails with a specific
  `errno`, such as `ENOSYS` for creating process groups and sessions in
  the first tier, and `sync` and `fsync` reach the server.

### Interaction with other subsystems

* **The kernel**: memory objects and IRQ objects as doorbells, from which
  the session builds each program's channel and pipes
  ([design-pipes.md](design-pipes.md)); vCPU upcalls, which only workers
  take (K20); sealed objects for the code and files programs map, and for
  shared mappings of files shared objects with `ERX_MEM_INHERIT`, their
  growth with `erx_mem_grow` and the report of their stored pages with
  `erx_mem_dirty`, both under `SUPPLY`, which the mapper keeps, and their
  filling and write-back with `erx_mem_copy`; copy-on-write children for
  their data; a threadless anchor beside each program's image, copies of
  spaces for `fork`, fresh images for `exec`, and pauses for `fork` and
  job control (K8, K22, K23, K27, K30); sub-spaces, which the session
  creates as a domain allowed `SPACES`
  ([design-kernel.md](design-kernel.md#creating-spaces),
  [design-system.md](design-system.md#sub-spaces)).
* **The system domain**: a command domain's creation and end, and the
  code objects the domain service creates for the session's executables
  and libraries ([design-system.md](design-system.md#creating-a-domain),
  [design-system.md](design-system.md#the-domain-library)); the
  `programs` and `children` quotas of `erx_policy`
  ([design-system.md](design-system.md#resource-policy)).
* **The scheduler**: the programs group under the session's group, each
  program's group below it, and the pause count that job control uses
  ([design-scheduler.md](design-scheduler.md#data-model)).
* **Connections**: the session's connections to its file servers and to
  its command domains, over which the handler relays a program's requests
  and the stream relay carries a command's streams; a program has none
  ([design-domains.md](design-domains.md#connections)).
* **The inspector**: programs listed under their session as ports
  ([design-live.md](design-live.md#inspection)).
* **File servers**: 9P2000.L's operations, with a `walk` of no names for
  each grant a program receives and an `lopen` for reading, behind the
  handler's image check, for code; the session's open-file descriptions,
  which send every read and write with an explicit offset; the data area
  the handler copies through; and
  the reads and writes by which the session's mappers fill and write back
  the objects of shared mappings
  ([design-files.md](design-files.md#native-clients-liberxs-file-client),
  [design-files.md](design-files.md#shared-mappings)).
* **The command shell**: spawns, jobs, the terminal relay, `/dev/tty`,
  rights handed with `within -f`, Erlang commands in command domains, and
  `rc` as a program ([design-shell.md](design-shell.md)).
* **The runtime**: `liberx` and musl's seam, the pipe NIF, the port driver
  that creates, serves and ends programs, and the command image's program
  mode, in which `rc` and Erlang commands run for programs
  ([design-runtime.md](design-runtime.md#programs-as-ports)).

## Compatibility and migration

The startup message, the fork message and the program protocol are frame
profiles of the ABI file with version 1. No form of them owes anything to
an earlier one ([design.md](design.md#compatibility)): a change to any
replaces the old form outright, under a new version, and no handler,
decoder or `liberx` keeps a reader for the old one. A handler refuses a
request of a version it does not speak, and a decoder that finds a startup
or fork message of another version ends the program with status 127, so a
program never runs on a message it misreads; a program built for an
earlier version runs again once it is rebuilt with the tree. What a ported
program relies on is POSIX, and that compatibility stays a requirement.

The differences from POSIX that a ported program can meet, each with a
test:

| Difference | Why |
| --- | --- |
| in the first tier, no `fork` and no `exec`: calling them fails to link | a program starts fresh, with `posix_spawn`; the second tier provides both |
| the second tier's `fork` copies the parent's memory at the call and fails there with `ENOMEM`, never at a later write | private memory is never shared copy-on-write (K5), and the copy is charged at the call |
| the second tier's `exec` in a program with other threads first lets them finish the calls that only they can finish, a `posix_spawn`, a `fork`, a passing of descriptors, a redemption or a stop, and runs them on meanwhile, instead of ending them at once, and fails with `E2BIG` past a 192 KiB startup message, before its point of no return | the old image hands its state to the new one and abandons nothing that another party waits on (P12), and the handover's size is checked on the quiet image ([Exec](#exec)) |
| `system` and `popen` run rc, not sh | the user's decision; erXos ships no POSIX shell |
| `mprotect` that gives reserved memory access fails with `ENOMEM` when the program's budget cannot cover the pages, and charges at any access, read-only included, where Linux charges a private mapping only when it becomes writable and POSIX names no out-of-memory error for `mprotect` | a readable private page is a real page from the program's reserve, since the kernel shares no zero page, and committed memory never faults for lack of memory (K6); Linux and QNX both allocate at the `mprotect` and refuse with `ENOMEM` |
| a handler for `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGTRAP` or `SIGSYS` runs for a signal raised with `raise` or `kill`, never for a fault, which ends the program | a fault ends only the faulting space, from the kernel's record ([A program's end](#a-programs-end)) |
| in the first tier, a program cannot stop or continue itself or another: `kill` and `raise` of `SIGSTOP` fail with `EPERM`, and `SIGTSTP`, `SIGTTIN` and `SIGTTOU` under their default action are discarded | stopping is the session's job control, and a job's process group is orphaned, for whose members POSIX discards those three; the second tier stops and continues programs within a POSIX session ([The terminal](#the-terminal)) |
| in the first tier, a job is one process group and session that no program can leave | process groups and sessions that programs create come with pseudo-terminals, in the second tier |
| in the first tier, `tcsetattr` with `TOSTOP` fails with `EINVAL`, and a background job's write goes through | `TOSTOP`'s rules are about process groups and `SIGTTOU`, which come in the second tier, where POSIX's rules apply |
| `kill` of a process that is neither the caller's child nor in a `signal` right's scope it holds fails with `ESRCH`, even when it exists | a process id grants nothing, and the error does not say whether it exists |
| `kill` with a `pid` of 0, of minus the caller's group or of -1 reaches the caller's children, the processes of its `signal` right's scope and the caller itself, and no other member of its job, its parent and its siblings included | the same rule: a program reaches only its children and what its `signal` right names, so a job's other members are out of its reach unless that right names them ([The POSIX-lite personality](#the-posix-lite-personality)) |
| process ids are unique within a session only | a session is the namespace of its process ids |
| a program's children end with it: `daemon`, a double `fork` and `nohup` leave a child that ends with the program that started it, and a process that outlives its parent is a service under a supervisor, never a detached program | a program's anchor lies below its starter's, and the kernel ends a space's children with it (P9); the user's decision that nothing is orphaned |
| paths resolve as FreeBSD's do, `..` physically and symbolic links followed by the client at most 32 times, a renamed working directory is not followed, and a rename between grants, trees or rights fails with `EXDEV` | one resolver serves Erlang and native clients ([design-files.md](design-files.md#compatibility-and-migration)) |
| arguments, environment strings and file names are valid UTF-8 | they cross the channel and the session's connections as binaries that the frame grammars require to be valid UTF-8 |
| `O_NONBLOCK` of a pipe end is not inherited by a child, though an `exec` keeps it | a child receives ends and grants of its own, not the parent's objects, while an `exec` keeps the ends themselves ([Descriptors and files](#descriptors-and-files)) |
| one `sendmsg` passes at most 16 descriptors, more failing with `EINVAL`; a write end holds at most 16 passed descriptors not yet received, more failing with `ETOOMANYREFS` | a control record holds 16 tickets, and each write end's share of its pipe's deposits bounds what one sender makes the session hold ([Passing descriptors](#passing-descriptors)) |
| a pipe has at most 64 read ends at once, and a spawn or a `fork` that would make a 65th fails with `EMFILE` | a pipe's wake mask has one bit per read end ([design-pipes.md](design-pipes.md#the-ring)) |
| programs nest at most about 60 deep, and a spawn or a `fork` deeper fails with `EAGAIN` | each program's anchor lies below its starter's, and the kernel bounds a tree of spaces at 64 levels ([design-kernel.md](design-kernel.md#creating-spaces)) |
| a shared mapping of a file shows at once the stores of its session's programs and their writes through descriptors. It shows a change made outside the session only once every program of the session has let go of the file and it is mapped again. A store reaches the file at its server at `msync`, which `MS_ASYNC` starts and `MS_SYNC` waits for. A store also reaches the server at every close of a mapping's open, by `munmap`, `exec` or the program's end, and at the `close` that leaves the session's programs no open of the file | the session serves its programs' shared mappings, and their descriptor reads and writes of a mapped file, from one object per file, filled and written back with ordinary reads and writes ([design-files.md](design-files.md#shared-mappings)). POSIX leaves the synchronization of a mapping with access from elsewhere to the application ([Shared libraries and mappings of files](#shared-libraries-and-mappings-of-files)) |
| two sessions that map one file shared each hold a copy of their own, and see each other's stores only after a write-back, page by page, as two machines sharing a network file system do; `mmap` with `MAP_SHARED` fails with `ENOMEM` beyond the session's mapping quota | a mapping coherent across sessions would need one object for the file at its server, which the design does not take ([Alternatives considered](#alternatives-considered)); the session's objects are charged to its own budget |
| a page of a shared mapping wholly past the file's end reads as zeros and its stores never reach the file, where Linux delivers `SIGBUS` | the object covers every mapping, and a write-back stops at the file's size as the server reports it |
| a shared mapping whose file's server ends keeps its bytes, and its `msync` fails with `EIO`; a session that ends before its programs' ends are handled, a crash included, loses the stores not yet written back | the object is the session's and ends with the session's budget, and only a write-back reaches the file |
| running or mapping a file that changes twice while its file object is filled fails with `ETXTBSY` | a file object holds one version of a file ([File objects](#file-objects)) |
| no `SIGHUP` at the end of a session | a program ends with its session (P9) |
| no `sigaltstack`, no `RUSAGE_CHILDREN` | no stack switching; no usage reports from children |
| `PROT_EXEC` in `mmap` and `mprotect` fails with `ENOTSUP`, and a shared library with text relocations is refused | only the loader maps code, and code is never writable (P10) |
| in the first tier, `MAP_SHARED` mappings of files fail with `ENOTSUP` | they need the session's mappers and the kernel's report of stored pages, the second tier's |
| a shared anonymous `mmap` (`MAP_SHARED\|MAP_ANON`) is charged whole at the call, `PROT_NONE` included, and fails there with `ENOMEM`, where QNX reserves it and charges at the `mprotect`; a private anonymous `PROT_NONE` mapping is free until it is given access, as on QNX | a shared memory object's pages are charged to its budget at its creation, so that the forked children and the mappings that share it never fault for lack of memory (K6) and no mapping's commit can be refused by another's; a test maps a shared anonymous `PROT_NONE` range larger than the pool and expects `ENOMEM`, and the same range private and expects success |

## Failure handling, diagnostics and debuggability

| Failure | Detection | What remains | Who cleans up | What the user sees |
| --- | --- | --- | --- | --- |
| A spawn is refused: no right to start commands, an unknown command, a file without `rx`, a quota, a pipe's read ends, the session's budget | the starter's handler, from its own checks, the pipe server's or the port driver's answer | nothing: each step's undo ran ([Starting a program](#starting-a-program)) | the step that failed, and the steps before it in reverse | `posix_spawn` returns `EPERM`, `ENOENT`, `EACCES`, `EAGAIN`, `EMFILE` or `ENOMEM`; the shell prints the reason |
| A program's startup message is malformed | its decoder, `liberx`'s or the command image's, before the program's own code runs | nothing | the program ends | status 127, before `main` and without a line |
| A program's `mmap` with access cannot be charged: its cap or its session's pool for programs is full | the kernel, at the commit `liberx` makes after the reserve | nothing: `liberx` releases the reservation it made before it returns | `liberx`, in the failing `mmap` | `mmap` returns `MAP_FAILED` with `ENOMEM`, and `malloc` returns `NULL`; a test that fails a thousand such `mmap` calls finds the program's mapping count and address space where they were |
| A program's `mprotect` that gives reserved memory access cannot be charged, or meets a hole | the kernel, at the commit the part makes, before anything of that part changes; at the hole | the parts of the range before the refusal, given access and charged, as POSIX allows of a failed `mprotect` | nothing: a part is charged whole or not at all, and the program keeps what it was given | `mprotect` returns -1 with `ENOMEM`, and `malloc` returns `NULL` |
| A program writes a frame outside the protocol's grammar, a request on a busy slot and a notice that is not due among them | the handler's decoder; the port driver's count of the program's credit | nothing | the port driver or the handler ends the program as a fault ends it | its parent sees `SIGSYS`; the shell prints the frame's offset |
| A frame from the handler is outside the grammar, which only a bug in the session can produce | `liberx`'s decoder | nothing | the program ends | status 127, a line on its standard error |
| A shared mapping fails after its mapping open is made: the server's refusal, the mapping quota, a fill, the install or `erx_vm_map` | the mapper, the handler or `liberx` | the mapping open, until it closes | the mapper closes the mapping open on a failure of its own; `liberx` closes what arrived and the mapping open on a failure after the handler answered | `mmap` fails with its error; no open or quota remains |
| `erx_exec` cannot load an executable: a plan `erx_elf_plan` refuses, a library that cannot be found or mapped | `erx_exec` | nothing of the executable | the program ends | status 127, the reason on its standard error |
| A file object cannot be made: a file without `rx` for code, a read that fails or times out, a file that keeps changing, the session's `file_objects` or the budget charged | the filler or the command server | nothing: the object is freed when its last capability closes | the command server closes its capability | `EACCES`, `EIO`, `ETXTBSY` or `ENOMEM` from `posix_spawn`, `dlopen`, `mmap` or `exec` |
| A command domain's Erlang command needs a facet the program did not hand it | the command, from its context | nothing | the command domain ends | the command fails with `no_facet`, its status the program's wait status |
| `fork` cannot copy: the session's or the child's budget | the copier's `erx_space_copy`, which charges as it copies | nothing: the child is undone | the port driver | `fork` returns -1 with `ENOMEM` |
| `exec` fails | before `{exec}` answers `ok`: `liberx`'s check, the handler's or the port driver's; after: the commit or the new image's start | before: the old image, running and whole; after: nothing of the old image | after: the program ends, as at any end | before: `exec` returns -1 with its `errno`; after: status 127 |
| A program ends in any way | the image's exit or fault record, at the session's fault gate, which reaches its handler as the port's exit status | nothing of it; its children stopped (P9) | the handler and the port driver ([A program's end](#a-programs-end)) | its parent's `wait` returns the status of [A program's end](#a-programs-end) |
| A program stops taking its frames | the port driver's `busy` | the frames it is owed, bounded by its state ([The channel](#the-channel)), and its own requests unanswered | nothing: the handler owes them until the program reads, serves the program's siblings meanwhile, and the user may kill the job | nothing, unless the program is the foreground job, which the user ends with `Ctrl-C` or `kill` |
| A pipe's last reader or writer goes | the session's pipe server, from the holder's `{closed}` notice or its handler's word that the holder is gone | the bytes in the lanes, for a reader | the pipe server, which frees a gone writer's lane once every reader has drained it | the reader gets end of file after the bytes; the writer `EPIPE` and `SIGPIPE` ([design-pipes.md](design-pipes.md#failure-handling-diagnostics-and-debuggability)) |
| A file server dies with requests in flight | the handler, from its connection to the server going down | the program's opens on it, dead | the handler, which answers each request in flight and reports `{server_gone, Open}` | `EIO` from those requests and from every later use of those descriptors |
| A write-back of a shared mapping fails: the medium refuses a write or the file's server ends | the mapper, from the write's error | the stored pages, in the object and in the mapper's set of pages to write | the mapper, which writes them at the next write-back; the object's deletion at the last close drops them | the `msync`, `close` or last `munmap` that asked fails with `EIO`, and a program's end or `exec` leaves a log line; the mappings keep their bytes |
| Two sessions map one file shared | nothing: no server state records a mapping, as the file protocol is 9P2000.L | a copy of the file in each session's object | each session's mapper writes back only the pages its own programs stored | each session sees the other's stores only after the other's write-back and its own next mapping of the file, page by page; a page both stored to holds the bytes of the last write-back |
| A file's mapper crashes | the command server, which monitors each mapper | the object, while programs map it; the stores not yet written back | the command server marks the file's entry failed until every mapping open of the old mapper has closed, so the session never holds two objects for one file (P14) and no descriptor request goes past a mapper to the server (F7), and the object goes with its last capability; a mapping of the file meanwhile, and a read, write or size change of it through a descriptor, fails with `EIO` | `msync` and the closes of the old mapper's mapping opens fail with `EIO`; the stores not yet written back are lost |
| A pseudo-terminal's master closes | the session | the slave's opens, at end of file | the line discipline | `SIGHUP` to the terminal's session leader and foreground group |
| A signal arrives while a thread is inside `liberx` | the depth counter | the signal pending | `liberx`, at the thread's next open wait or the outermost exit of its call | the handler runs there at depth zero; a wait without a request in flight returns or restarts by the table of [Signals in liberx](#signals-in-liberx), and a request in flight completes |
| The command server crashes | the session's supervisor, for which it is a significant child | nothing of the session | the session's domain ends, and every program with it (P9) | the session ends with a report on the console, and the principal logs in again |
| A program's handler crashes | the port, which is linked to its owner; the domain service's monitor of the handler | nothing of the program or its command domain | the port's close stops the anchor; the domain service ends the program's command domain, if one was made ([What a program can start](#what-a-program-can-start)); the command server reaps the record | the program's parent sees it end by `SIGKILL` |

**Diagnostics.** The inspector shows each program under its session as a
port, with its name, process id, command, parent, job, rights and state,
each session's file objects with their keys and sizes, and its mappers
with their files, object sizes, mapping opens and pages still to write; a
fault record
stays with the program's record until the shell has printed it, and the
shell prints it. `liberx` counts the frames it dropped for their grammar,
and the handler counts the requests it refused and the frames it owes,
all readable through the inspector.

## Security

A program is untrusted by its session and by every server its session
reaches for it: its trust boundaries are the frames it sends its handler,
the bytes it writes into pipes, its data area and terminals, and the
executable or library it names. A program trusts its session wholly, as a
UNIX process trusts its kernel. What crosses the boundaries:

| Input | Source | Validation |
| --- | --- | --- |
| the startup and fork messages (a program) | its session, the only writer of its inbound lane | their grammar and bounds, once, before `main` ([Starting a program](#starting-a-program)) |
| an executable's or a library's bytes | the file's server, opened for reading on every request after the handler's image check of the requester's own `rx` grant, copied by the command server into a code object the program cannot write | `erx_elf_plan`, with its fuzz target, in the program's own space before any of it runs ([What a program can start](#what-a-program-can-start)) |
| an `rc` command of `system` or `popen` | the program that calls them | rc's parser, with its fuzz target, in the `rc` program's own space ([design-shell.md](design-shell.md#rc-as-a-program)) |
| the program protocol's frames | the program; on `liberx`'s side, the session | the protocol's generated decoder, with a fuzz target on each side, and the port driver's credit, which ends a program that sends a request on a busy slot or a notice that is not due; the handler knows the sender by the lane the frame arrived on, which one image alone can write, and takes no name of authority from a frame: every `Open`, end and process id is looked up in that program's own table ([The program protocol](#the-program-protocol), [The handler](#the-handler)) |
| a program's file requests | the program, relayed by its handler | the handler against the program's table, then the file protocol's grammar and bounds at each server, which roots and rights every grant ([design-files.md](design-files.md#the-file-protocol)) |
| pipe bytes and lanes | whoever holds the pipe's other ends | every field of a ring's header and of a reader page copied once and checked before use, and a reader maps every ring read-only; the bytes are data, copied into the caller's buffer ([design-pipes.md](design-pipes.md#security)) |
| the data area's bytes | the program, for a write; the server's reply, for a read | the generated reply check of `erx_file_remote` fails a reply that names more bytes than its request asked for with `eio`, and `liberx` copies no more than the count it asked for ([design-files.md](design-files.md#bounds)); the handler copies only within the slot the request names, checked against the area's size, and the bytes are data at both ends ([Descriptors and files](#descriptors-and-files)) |
| a shared mapping's bytes and its requests | the file's server, read through the mapping open's own fid; the programs that map the object, for its stores; the program, for `End` | the mapper copies a reply, checked against the count it asked for, only within the object's size, takes `End` as a checked byte count within the mapping quota, and treats the stored pages as data, written only through a mapping open that allows writing ([Shared libraries and mappings of files](#shared-libraries-and-mappings-of-files)) |
| a program's `termios`, in a `{tty, Open, Request}` | the program | `erx_tty:set/2`, which checks it whole, with a fuzz target ([design-live.md](design-live.md#the-tty)); a program's output is data, which the tty does not interpret |

**Authority.** A program holds its channel, its pipe ends, its data area
and the memory its session mapped, and nothing more (P1); its namespace,
its opens and its rights live in its handler, which acts on them for the
program alone. Whatever it starts holds only what it hands on (P2), and it
cannot run anything in its session's domain: an Erlang command it starts
runs in a command domain, a builtin or function of the shell is not its to
start, and it never makes the session wait on it (P3). Authority is per
address space: inside the session's domain every process can reach every
facet the session holds, so that domain runs only commands with the
session's own authority, and every confinement below it rests on a
sub-space or domain boundary, which the kernel keeps, and on the
handler's table, which the program cannot write; never on the program's
code behaving. A program never executes code it can write (P10).

**Residual risks accepted.** A program that holds an `rw` and an `rx`
grant over one tree can write an executable or a library and run it, with
its own authority. A program on a tty can send the terminal any control
sequence, a fake prompt included, as on UNIX and over `ssh`
([design-live.md](design-live.md#security)). A session's programs share the session's connections to its
servers: a few hostile programs of one session can fill a connection's
lane with requests and delay their siblings' requests there, within what
each program's handler relays for it, until the user stops their job
([design-domains.md](design-domains.md#flow-control)). The programs of a
session that map one file writable share one copy of it: a program that
closes its mapping open and keeps storing still stores into the object,
and its stores reach the file through another program's writable mapping
open of that file, if one remains, until it ends; it could write that
file anyway, since its own open allowed writing.

## Verification and testing

Every property test and every domain test below is paired with a seeded
failure: a mutation of the code under test, a dropped undo step, a
reversed lock order, a bound off by one, a frame applied before its read
position moves, which the test must catch, so a passing test proves the
code it names ran. The personality's oracles are musl's `libc-test`, which
`make check-oracle` runs, and the Open POSIX Test Suite, fetched at a
pinned version, built against erXos's musl and run in a test domain as an
external test tool, never linked into erXos and never in the repository
(BSD-2-Clause and GPL-2.0-or-later,
[research](research-boards-storage.md#the-toolbox)); a case that needs a
facility of a tier not yet built is recorded as unsupported, never as a
pass, and the second tier runs the suites' `fork`, `exec`, `dlopen` and
terminal cases.

* **Pure cores on the host.** The spawn planner over random descriptor
  tables and file actions, with the properties that a plan names only
  descriptors that are open and each number once, and that a rejected plan
  has no effect; `erx_prog:status/1` over every exit and fault record the
  kernel can post, every fault kind of the ABI file's table included;
  `erx_sig_step`, explored exhaustively as above; `erx_elf_plan` over
  random and mutated executables and shared objects, with the properties
  that a plan's segments lie inside the file and its range, none is
  writable and executable, and no relocation writes a code segment; the
  descriptor table's `dup`, `close` and `FD_CLOEXEC` rules against a
  model; the line discipline's state machine against a model of POSIX's
  general terminal interface; the handler's owed frames against a model
  of a program that reads its lane at random, never, or in bursts, with
  the properties that the handler never blocks, never owes more than its
  program's state bounds, and writes owed frames in order, and with a
  seeded handler that writes a newer frame before an owed one, and that
  an owed join and gone of one pipe end merge into the join marked gone;
  the port driver's credit against a model of a hostile program that
  sends requests on busy slots and notices that are not due, repeats
  among them, with the properties that each such frame ends the program
  with `SIGSYS` and that the handler and the pipe server never hold more
  than one message per credit; the exploration of the pipe core and the
  handler over an `exec` whose let-go overlaps pipe reports and installs,
  with P11's property that no capability is installed into a table other
  than the one its report names; and the exploration of the handler and
  `liberx` over an `exec` racing signals, stops, continues and exits,
  with P13's properties, and with a seeded executor that applies a frame
  before its last byte is read and a seeded switch that drops the signal
  reports the handler still owed.
* **Build checks.** The entry macro on every exported function of
  `liberx`'s program layer, with a seeded function without it; the event
  executor's call graph free of kept locks, with a seeded call to
  `malloc`; `liberx`'s one function that maps code referenced only from
  `erx_exec`, with a seeded second caller; the program layer's freedom
  from musl's `malloc` and stdio, with a seeded call; the program layer
  (`liberx/program/`) naming no symbol of a kernel backend, so it sits
  above the kernel interface and a new backend moves nothing in it, with a
  seeded call of the Fiasco backend's; and the generator's
  check that every fault kind has a signal and every status an `errno`,
  with a seeded kind without one.
* **Signal numbers** ([Signal numbers](#signal-numbers)). Each test has a
  seeded run that must fail:
  * the generator's mapping test compares the signal table with FreeBSD
    15.1's `sys/sys/signal.h`, every name from 1 to 33, the aliases,
    `SIGRTMIN` and `SIGRTMAX`, and with the names of its `sys_signame`;
    seeded with a copy of the table that gives `SIGINFO` 30;
  * a build check that no file of musl's tree but the generated header
    defines a signal number, seeded with a literal `#define SIGPWR 30` in
    `musl/arch/aarch64/bits/signal.h`;
  * on the host, over every integer from -1 to 200, `sigaddset`,
    `sigdelset`, `sigismember`, `sigaction` and `pthread_kill` accept
    exactly 1 to 31 and 65 to 126, `kill` those and 0, and `sigfillset`
    holds exactly them; seeded with the predicate generated from a table
    that lists 64, which fails at 64;
  * on the host, `erx_prog:status/1` over every status `ERX_EXIT_SIGNAL +
    N` for `N` from 0 to 255: a number of the table gives `{signaled,
    Signal}` with its name, any other exited 255; seeded with a table
    without `SIGINFO`'s row, which turns 29 into exited 255;
  * the protocol's grammar accepts every name of the table and refuses
    `sigpwr`, `sigstkflt` and `sigthr`; seeded with a grammar that admits
    `sigpwr`;
  * in QEMU, FreeBSD 15.1's `bin/kill/kill.c`, built against erXos's musl
    as a test program: its `kill -l` prints what the shell's builtin
    prints, byte for byte, and for each `N` from 1 to 31 its `kill -l N`
    names the signal the builtin's `kill -N` sends; seeded with a builtin
    table that swaps `STOP` and `CONT`;
  * in QEMU, a C program with a handler for every catchable signal records
    the number each arrives with: the shell's `kill -29 %1`, `kill -30 %1`
    and `kill -66 %1` reach it as 29, 30 and 66; `kill -17 %1` pauses it
    and `kill -19 %1` continues it, and its `SIGCONT` handler records 19;
    its child ended by `kill(child, 15)` and by `kill(child, 126)` gives
    `waitpid` a `WTERMSIG` of 15 and 126, and the program itself ended by
    the shell's `kill -15 %1` and `kill -126 %1` leaves rc's `$status`
    `sigterm` and `sigrtmax`; seeded with the program built against a header whose
    `SIGUSR1` is 10, whose handler then records nothing for `kill -30 %1`.
* **toybox's tests.** toybox's test scripts are shell scripts, and erXos has
  no POSIX shell in the first tier, so the harness runs them under the
  development host's shell with each applet replaced by a forwarding
  command, a Ruby script of the harness that runs the applet in a test
  domain over the host link. It carries the applet's arguments and standard
  input there, mirrors the test's working directory into a scratch tree
  before the applet runs and back after, and returns its standard output,
  standard error and exit status. A test that depends on what the mirror
  does not carry, such as owners, device files or hard links, is recorded
  as unsupported.
* **Rights.** `xargs ps` and `watch ps` list processes when the program
  holds the `inspect` right and fail with `no_facet` without it; the
  `inspect` facet the system domain makes for the program's command domain
  reaches that domain alone, and a test domain handed its pid gets
  `badarg`; `xargs kill` ends a sibling with the `signal` right and gets
  `ESRCH` without it, and a right scoped to one job reaches no other;
  `within -f signal /bin /tmp -- xargs kill` holds the `signal` right and
  two grants, `/bin` to reach `kill` and `/tmp`; a command domain's
  capabilities are exactly the program's, and an Erlang command in it that
  asks for a facet it was not handed gets `no_facet`; an Erlang command
  narrowed with `within` runs in a domain of its own, which the inspector
  shows; a program that names another program's `Open`, end or process id
  in a request, which fails with `EBADF` or `ESRCH` and gains nothing; a
  sub-space test that enumerates a program's capabilities and finds only
  its channel, its data area, its pipe ends, its budget and its group;
  and a program narrowed without `/bin` that sends a spawn request of its
  own fails with `EPERM`.
* **Native programs.** Each of these has a QEMU test: spawn and wait; a
  startup message at each bound and one past it, and a malformed one; a
  spawn refused by its handler, after which the starter's pipe has no
  extra write end and its reader sees the end of the stream once the
  starter closes its own; a pipe with a slow reader, with a reader that
  closes, with write ends held by two programs, and with 200 write ends
  while its reader is paused, each spawn succeeding; a pipe whose 65th
  read end fails with `EMFILE`; a pipeline whose middle stage faults,
  whose neighbours see the end of their pipes at once; a pipeline of 16
  programs created in one request, and one whose ninth program cannot be
  created, which creates none; `{date; uname} >f` and `>[2=1]`, whose
  writes share one offset; a program whose parent ends while the child is
  built but not started, which never runs; a program whose parent ends,
  which ends too, with its own children; programs started in a loop by
  one program until its principal's `programs` quota, which then fail
  with `EAGAIN` while the shell still starts programs from the quarter
  kept for it; a chain of programs each of which spawns the next, whose
  spawn about 60 generations deep fails with `EAGAIN`; a program that
  stops draining its channel while its children end and a pipe it reads
  gains a writer, whose exit reports and pipe reports all arrive once it
  drains again, while the relay, the shell and its siblings stay
  responsive throughout; a program that floods its handler with requests,
  whose siblings keep being served; a program that ignores `SIGCHLD`, and
  one that sets `SA_NOCLDWAIT`, each starting short-lived children in a
  loop past its `children` quota, which every automatic reap lets go of,
  also across an `exec` that cuts a reap short; a child that ended
  unwaited before its parent ignored `SIGCHLD` and called `exec`, which
  the next image reaps; a spawn whose executable's file object is slow to
  fill, while the starter's `SIGINT` still arrives; a program that
  clones grants past its allowance, whose `open` fails with `EMFILE`
  rather than succeeding with a grant it cannot reach; job control's pause
  and resume across three generations of one job, a program started while
  its job is paused, which starts paused, `Ctrl-Z` during a `fork`'s copy
  and `fg` after it, which leave the job paused and then running, and
  `kill %1` of a paused job, which ends it; a `SIGCONT` from a second-tier
  program of the same POSIX session to a program of a job that `Ctrl-Z`
  stopped, which resumes that program alone, makes `jobs` show the job
  running and leaves the job's other members stopped until `bg`; a program
  stopped by `SIGTSTP` and then by `Ctrl-Z`, which one `SIGCONT`
  continues; an outer job's `fg`, which leaves stopped a program of an
  inner job that a stop signal paused; a `SIGCONT` and an `fg` during a
  `fork`'s copy, which leave the parent held until the copy ends; an
  executable compiled into an `rw` tree and spawned through an `rx` grant
  of the same tree, one spawned through an `ro` grant, which fails with
  `EACCES` even after the shell ran it through an `rx` grant, and a
  malformed one, which ends with status 127; two programs running one
  executable, whose code pages the inspector shows as one file object
  mapped twice, and whose writes to their data pages stay their own; an
  executable rewritten between two runs, whose second run maps a new
  object, and one rewritten while its object is filled, which is filled
  again, or fails with `ETXTBSY` when it is rewritten again; `system` and
  `popen` of rc commands, whose wait statuses follow `$status`; a program
  whose standard output and error both go to the terminal, interleaved
  line by line in the order written; `/dev/tty` read in the foreground, a
  background job's read that waits until `fg`, a password prompt with
  `ECHO` cleared that does not echo, and `Ctrl-D` that ends one `read`
  with 0 while the next reads on; a program whose frame is outside the
  grammar, which ends with `SIGSYS`; and each row of the exit status
  table.
* **The POSIX-lite personality.** musl's `libc-test` and the Open POSIX Test
  Suite run in a test domain; every failure is a bug, a documented
  difference with a test, an unsupported case of a tier not yet built, or
  an upstream bug recorded as such. A signal sent while the main thread
  computes, while it is inside `liberx`, while it waits on a umtx word,
  while it waits for a reply and just before it sleeps is delivered in
  each case; `sigsuspend` with the signal already pending returns at once;
  a handler that calls `liberx`'s `write` while the thread was inside
  `malloc`, and one that leaves a file request's wait by `siglongjmp`,
  leave every structure intact and later signals deliverable; a handler's
  return restores the interrupted frame and FP registers exactly; a
  handler that leaves a pipe read's wait by `siglongjmp`, after which a
  `close` of the pipe end gives its writer `EPIPE`; a `write` to a file
  interrupted by a handler without `SA_RESTART` returns its full count,
  never `EINTR`; `sigwait` in a second thread takes a signal the main
  thread blocks; a program that blocks `SIGTERM` in every thread and waits
  for it with `sigwait` receives it rather than ending, and one that
  blocks it without waiting ends when it unblocks it; `sigwait` for a
  blocked `SIGCHLD` under its default action receives it; a process signal
  aimed at a thread that then blocks it or exits reaches another thread;
  `SIGCHLD`'s handler finds its child with `WNOHANG`, and with `SIGCHLD`
  ignored, `wait` fails with `ECHILD` once the children end; a child
  spawned while its parent ignores `SIGHUP` ignores it too and inherits the
  parent's mask and `umask`; `pthread_sigmask` with a full set, `kill(pid,
  0)` and `sigaction(SIGWINCH, SIG_IGN)` succeed; `kill` of a child that
  has ended succeeds until `waitpid` reaps it and fails with `ESRCH`
  after, when the child stops counting against `children`; `kill` of
  `SIGSTOP`, `SIGTSTP` or `SIGCONT` to a child fails with `EPERM`, and
  `raise(SIGTSTP)` under its default action returns with nothing done;
  `raise(SIGABRT)` ends the program with status `sigabrt`; a program whose
  last worker calls `pthread_exit` ends with status 0; `xargs` with more
  than 4,096 short arguments runs; a session whose process ids are spent,
  through a test hook that starts its counter near the top, fails the next
  spawn with `EAGAIN`; `poll` over 500 pipe ends reports exactly the ready
  ones, and never `POLLIN` for an end the program has just drained;
  `getpgrp` and `getsid` in each stage of a pipeline, and in a stage's
  child, return the first stage's process id; `kill(0, SIGTERM)` in a
  program with two children ends all three, and `waitpid` with a `pid` of 0
  reaps either child; `access` with `W_OK` through an `ro` grant and with
  `X_OK` through an `rw` grant fails, and each succeeds where `open` or
  `posix_spawn` does; a `close` of a pipe end that another thread is reading
  returns at once, the read goes on as on Linux, and the next `open` reuses
  the number; two threads reading files at once through a data area of one
  slot, which take turns; a hostile file server whose `Rread` names more
  bytes than the read asked for, at which the program's `read` fails with
  `EIO` and nothing past its slot is written, with a seeded handler
  without the reply check, which the test catches by a guard pattern after
  the slot, and a seeded `liberx` without the clamp, which the test
  catches through a session stub that sends the same oversized count; a
  file server stub that, between an `lcreate` and the handler's walk,
  renames another file over the new name, after which the created file's
  writes go on and its `fcntl` setting `O_APPEND` fails with `ESTALE`,
  with a seeded handler that skips the qid comparison, whose re-open the
  test catches naming the other file; a thread that calls `exit` while
  others are inside `liberx` ends the program with its status; and a build
  of `liberx` whose program layer calls `malloc` fails the symbol check.
* **The second tier.** `fork` in a program with four threads, whose child
  runs only the caller and the handlers `pthread_atfork` registered; a
  child's writes to private memory that its parent never sees, and a
  `MAP_SHARED` anonymous mapping both see; inherited pipes whose reader
  sees the end of the stream only after parent and child close their write
  ends; a `fork` in a session without budget for the copy, which fails
  with `ENOMEM` and leaves the parent running; a child that returns
  through stack frames whose pointers were signed in the parent; a fork of
  a fork of a program that maps a file privately, whose copy-on-write
  children stay one level deep; a child forked after `dlopen` that calls
  into the library and writes its data, which the parent never sees, and
  whose table, read through the inspector, holds no capability to its
  parent's copy-on-write children; a child that runs `execvp` through
  `PATH`, opens a file relative to an inherited directory descriptor and
  closes a file it shares with its parent, which the parent still reads; a
  child whose event executor waits on a pipe and wakes, reading its own
  group's shared areas, which the inspector shows are not its parent's; a
  `fork` while three other threads hold, or wait for, `malloc`'s lock, the
  descriptor table's lock and a pipe end's lock, and while the event
  executor applies a report, whose child allocates, opens, reads its pipes
  and forks again; `pthread_atfork` handlers that run newest first before
  the copy and oldest first after it, in parent and child, and the parent
  handlers after a `fork` that failed; a `fork` during which a signal and
  a child's end arrive, which the event executor records while the caller
  holds the kept locks and the parent then sees; a `posix_spawn` in one
  thread while another calls `execve`, whose child runs with working
  grants and whose end the new image's `wait` returns. `exec` that keeps
  the process id and every descriptor without `FD_CLOEXEC`, closes the
  others and resets caught signals, and whose new image's table, read
  through the inspector, holds only what its startup message names: none
  of the old image's signal IRQ objects, file objects, stray capabilities
  or sub-spaces; an `exec` while a child it forked runs, which leaves the
  child running and its exit reported to the new image; an `exec` while a
  sibling forks a writer of a pipe the program reads, whose new image
  reads that writer's records (P11); an `exec` of a writer at a ring
  position past zero, whose reader reads on without a gap or a repeat; an
  `exec` that keeps a pipe end with `O_NONBLOCK`, whose new image's read
  of the empty pipe fails with `EAGAIN`; an `exec` after opening
  close-on-exec files in a loop a thousand times, after which the file
  server holds none of their fids; an `exec` with a blocked signal
  pending, and one with a signal reported while the old image lets go,
  each of which the new image finds pending; one made while a child ends,
  whose status the new image's `wait` returns; `alarm(5)` before an
  `exec`, whose new image receives `SIGALRM` on time; an `exec` while
  other workers are inside a redemption, a `sendmsg` deposit, a
  `posix_spawn` and a `fork`, each of which completes before the old image
  lets go; an `exec` while another worker waits in `recvmsg` on an empty
  stream whose writer lives and writes nothing, which the quiesce parks at
  once, and while another worker's `recvmsg` meets a control record during
  the quiesce, which waits at its region's entry, redeems nothing, and
  leaves the record to the next image's read of the kept end; an `exec`
  while another worker's file write waits on a server the test holds
  back, which the quiesce waits for because the channel's send recorded
  it, so the new image's first read of the file finds the write's bytes,
  with a seeded `liberx` whose send records no obligation, under which
  the new image reads the file before the write lands and the test
  catches it; an `exec`
  whose `Start` names a pipe end the program does not hold, which the
  handler refuses with `EBADF`; an `exec` whose startup message would pass
  192 KiB, which the handler refuses with `E2BIG` before any image is
  built, leaving every worker running; an `exec` while the pipe server's
  report of a peer's new writer is on its way to the old image, whose new
  image's startup message names the writer once and whose lane carries no
  second report; an `exec` whose old image is sent `SIGUSR2` after its
  capture while a sibling sends the new image `SIGUSR1`, whose new image
  takes both, whatever order the reports arrive in, and none twice; a
  child stopped by `SIGTSTP` and not yet returned by `waitpid` at the
  `exec`, which the new image's `waitpid` with `WUNTRACED` returns once,
  and one already returned, which it never returns; a `{waited}` that
  names a running child's stop report, which lifts no quota; an `exec` of
  a malformed file, which fails with `ENOEXEC`, of a file replaced by a
  malformed one between its check and its `{exec}`, which runs the object
  that was checked, and one the handler refuses, after each of which the
  old image runs on with its descriptors and signal handlers intact.
  `dlopen`, `dlsym` and `dlclose` of a library shared by two programs,
  whose code pages are one object's and whose data pages are each
  program's own; a library with text relocations, which is refused;
  `RELRO` that is read-only after relocation; a `dlopen` through an `ro`
  grant, which fails with `EACCES`. `MAP_SHARED` mappings of one file in
  two unrelated programs of one session and in a program and its forked
  child, which all see each other's stores at once (P14); one file mapped
  through two mounts of its tree, which the session serves from one
  object, with a seeded file table keyed by path, which the test catches
  as two objects; two files of one server's domain in two trees whose qid
  paths are equal, which the session maps as two objects, with a seeded
  file table keyed without the tree, which the test catches as one; a
  write through a descriptor, which those mappings show
  at once, and a read through a descriptor, which returns what a mapping
  stored, with a seeded handler that relays them to the server past the
  mapper, which the test catches; `msync` with `MS_SYNC`, after which the
  file's storage holds the stores, read back after the storage service
  restarts, and with `MS_ASYNC`, after whose answer the write-back
  completes without a further call; a program's last `munmap`, its
  `exec`, its end and its kill with stores not yet written back, and the
  `close` that leaves the session no open of the file, after each of
  which the file at its server holds them, with a seeded mapper that skips
  the write-back at a close; a write from outside the session to a page no
  program of the session stored to, which a later write-back leaves intact
  (P14); a mapping filled and never stored to, whose `msync` writes
  nothing, with a seeded mapper that fills through its own mapping of the
  object, which the test catches as writes of unstored pages; a mapping
  kept after its descriptor's `close`, and one that a forked child keeps
  after its parent's last `munmap`, whose capability the child holds
  without `DUP` or `SUPPLY`; a second `mmap` whose end passes the
  object's size, which grows it while the first mapping goes on reading
  and storing; a second `mmap` whose fill fails at a read, followed by a
  third of the same range, which reads the range from the server again
  and shows the file's bytes, with a seeded mapper that moves its filled
  extent before its reads complete, which the test catches as a page of
  zeros; a descriptor write the server refuses and one it takes in part,
  after which the mappings show the acknowledged prefix alone, with a
  seeded mapper that copies a write into the object before the reply,
  which the test catches; a write that starts past the end, whose
  mapping shows zeros in the hole and the written bytes after it, with a
  seeded mapper that zeroes up to the new size after the write, which the
  test catches; a read-only shared mapping, whose `mprotect` to
  read-write fails with `EACCES`, and a private anonymous mapping that
  `mprotect` moves to no access and back, whose bytes survive; a
  private anonymous `PROT_NONE` mapping larger than the program's cap,
  which succeeds, whose `mprotect` to read-write of a part within the
  cap succeeds and every page of which is then written, whose `mprotect`
  of a further part beyond the cap fails with `ENOMEM` and leaves the
  first part accessible, and whose `mprotect` back to `PROT_NONE` keeps
  the bytes for the next `mprotect` to read, the same program on the
  development host seeing the same but the `ENOMEM`, with a seeded
  `liberx` that commits at `mmap` whatever the protection, under which
  the large reservation fails, and a seeded `erx_space_protect` that
  skips the charge, which the model of K6 catches; a program that
  borrows from its session's pool until the pool is full, after which
  a sibling at its guarantee still commits the whole of it and the shell
  still starts a command, since the session's own half is untouched,
  with a seeded chain that leaves `carved` out, under which the
  sibling's commit fails; a
  `PROT_WRITE` mapping of a descriptor open only for reading, which fails
  with `EACCES`; a write-back that the medium refuses, whose
  `msync` fails with `EIO` and whose pages a later `msync` writes; a store
  made while its page is written back, which the next `msync` writes; a
  page wholly past the file's end, which reads zeros and whose stores the
  file never receives; a truncation by another program, after which the
  mappings show zeros past the new end and the next write-back writes
  nothing past it; a storage service killed while programs map its files,
  whose mappings keep their bytes and whose `msync` fails with `EIO`; two
  sessions that map one file shared, each of which sees a page the other
  stored only after the other's write-back and its own next mapping of the
  file, and a page neither stored to keeps the file's bytes; a mapping
  beyond the session's mapping quota, which fails with `ENOMEM`; `mmap`
  calls that fail in a loop at the server's refusal, at the install into a
  full capability table and at `erx_vm_map`, after which the session holds
  no more mapping opens than before and no more of its mapping quota than
  the largest end asked for; a
  mapper killed while two programs map its file, whose `msync` then fails
  with `EIO`, and a mapping of the file and a descriptor read of it
  meanwhile, each of which fails with `EIO` until both have let go; a file
  server that answers each read slowly while a mapper fills, during which
  the command server keeps serving spawns and the requester's `SIGINT`
  arrives; a private mapping of a file that another program of the
  session maps shared and stores into, which shows the shared object's
  bytes at the private `mmap` and none of the stores after it, with a
  seeded handler that fills the data object from the server, which the
  test catches; and a `code` map of that file, which fails with `ETXTBSY`
  while the writable shared mapping lasts. `SCM_RIGHTS`: a socketpair's end
  passed over itself and closed, whose deposit the pipe server closes so
  both peers see the end of the stream; a `read` that skips a control
  record, whose deposit closes; two writers of one stream, one preempted between its
  control record and its first data record while the other writes, whose
  descriptors arrive with their own bytes; data whose bytes look like a
  ticket, which reads as data; a `sendmsg` under `O_NONBLOCK` into a full
  stream, which fails with `EAGAIN` and leaves no deposit; a `sendmsg` of
  17 descriptors, which fails with `EINVAL`; a signal, and `alarm` with
  `siglongjmp`, during a `sendmsg`'s deposits, whose message then arrives
  whole with its descriptors; a sender that passes 1,000 files one after
  another, each of which its receiver closes, which never runs out of
  fids; a socket passed with `SCM_RIGHTS` whose sender then closes its
  descriptor, which the receiver goes on reading and writing; a socket
  descriptor without `FD_CLOEXEC` held across an `exec`, which the new
  image goes on reading, and one with it, which the new image finds
  closed; a file passed by a sender that then ends, which
  the receiver reads on, as on UNIX; a received file that the
  receiver passes on to a child and to a third program by `SCM_RIGHTS` and
  then closes, which both read on until each lets it go; a sender that
  passes a file and then execs, whose receiver reads on; and a receiver
  that redeems with `MSG_CMSG_CLOEXEC` and then execs, after which, once
  the sender has closed its own, the description's fid is clunked. A
  pseudo-terminal in canonical and
  raw modes; `kill(0, SIGTSTP)` and `raise(SIGTSTP)` in a program on a
  pseudo-terminal, each of which returns only after the program is
  continued; a background group's write with `TOSTOP` set, which stops with
  `SIGTTOU`, goes through with it ignored and with it blocked, and fails with
  `EIO` in an orphaned group; a `SIGSTOP` of a child, which the parent's `waitpid` with
  `WUNTRACED` reports; `^C` that sends `SIGINT` to the foreground group
  only; a background group's read that gets `SIGTTIN`; a resize that sends
  `SIGWINCH`; a master's close that sends `SIGHUP`; and a recompiled `vi`
  and `less` that draw on a pseudo-terminal.
* **Fuzz targets.** The startup and fork messages' decoders, in `liberx`
  and in the command image; the program protocol's, in `liberx` and in the
  handler; and `erx_elf_plan`, built from the same sources for the host
  (`make check-fuzz`); the ring and reader page checks are the pipes
  document's ([design-pipes.md](design-pipes.md#verification-and-testing)),
  and the line discipline's is the console's
  ([design-live.md](design-live.md#verification-and-testing)).

## Performance

**Programs.** Starting a native program costs a budget's carve, a group,
two spaces, the channel, the data area, one thread and the handler's
Erlang steps ([The cost of a program](#the-cost-of-a-program)), which
`tools/erx bench spawn` measures under HVF against `posix_spawn` of the
same toybox applet on the host; the budget is 1 ms per program start (an
estimate, under HVF), so a shell pipeline of a few programs starts within a
keystroke's latency, and a `make` that starts a compiler per file is
bounded by the compiler, not by the start. An executable started from an
`rx` grant adds its file object's first filling, one read per 64 KiB at a
round trip of 3 to 10 us and a copy into the object, an estimated 0.2 to
0.5 ms for 1 MiB, and nothing once the session holds the object.
`system`, `popen` and an Erlang command a program starts cost a command
domain's start the first time, an estimated 0.15 to 0.3 s under HVF, from
the budget of 300 ms for a domain to a ready init process and the 0.13 s
measured for an embedded boot of a small release on the host
([design-domains.md](design-domains.md#performance)), and only a frame
over the connection after that, since the program's command domain is kept
for its image; `tools/erx bench system` measures both. A pipe moves bytes
by one copy into a ring and one out, with no kernel call while the other
side is awake ([design-pipes.md](design-pipes.md#performance)), which
`tools/erx bench pipe` measures. A reply to a worker passes through the
event executor, which adds a umtx wake to each request, an estimated 1 to
2 us; a signal costs a frame, one upcall of the target thread and two
`erx_vcpu_resume` calls.

**File I/O through the handler.** A program's read of a file costs a
frame on its channel and the session's doorbell, the handler's turn and
its open-file description's, a round trip over the session's connection
to the server, 3 to 10 us, the
handler's copy of the payload into the data area, a frame back and the
program's doorbell, and the executor's wake of the worker. From those
parts, a read of 4 KiB is an estimated 10 to 26 us: two doorbells at 1 to
2 us each, the connection's round trip, the handler's and the
description's message turns at an estimated 4 to 10 us together, and the
executor's wake; a read of 64 KiB
is about 50 us, of which 33 us are its five copies at an estimated 10 GB/s
each ([design-files.md](design-files.md#performance)), so a sequential
read moves about 1.3 GB/s at best. The same read costs an Erlang process
of the session one round trip, 3 to 10 us, and three copies. The handler's
hop is the price of decision B, and experiment E-P2 below measures whether
file-heavy programs pay it visibly.

**The second tier.** `fork` costs a creation plus the copy of the parent's
committed private memory, at an estimated 5 to 10 GB/s on one CPU, about 10
to 20 ms for 100 MiB, during which the parent is held; `tools/erx bench
fork` measures it against `fork` on Linux in a guest. A shared library
costs its file object's first filling once per session, and then a mapping;
its data costs the mapping's size at the `mmap`, charged and backed up
front, and a page copy at the first touch of each page, read or write
([design-kernel.md](design-kernel.md#copy-on-write-children-and-copies-of-spaces)).
A shared mapping of a file
costs the filling of its range once per session, at the file object's
rate above, and each write-back an `erx_mem_dirty` call and one write for
each run of stored pages, so a program that stores to a few pages of a
large file writes back only those; gate GQ measures write-back with
`tools/erx bench mmap` ([plan.md](plan.md#decision-gates)). While a file
is mapped shared, each descriptor read or write of it by the session's
programs costs one message to its mapper more than one of an unmapped
file.

**Experiment E-P1, the cost of a program.** Hypothesis: the smallest
program, one of toybox's applets from the boot image, costs at most 512
KiB of its session's budget, the data area's 256 KiB, the channel's 48
KiB, an estimated 16 KiB of space records, the thread's kernel stack and
the applet's own written pages together, and 1 ms to start under HVF; and
a `make`-shaped job, one program that starts short-lived children one
after another through `posix_spawn` and `wait`, each writing one line to a
pipe whose reader is paused, starts them at the same cost each, with no
growth in the handler's or the pipe server's time per child as the pipe's
write ends accumulate. Method: `tools/erx bench spawn-cost` starts 100
programs of toybox's `cat`, each reading a pipe that the benchmark holds
open and never writes, so each has run `liberx`'s start-up and sits in an
open read; the benchmark sees each program's start as the moment the
reader's waited-for position appears in the pipe's reader page, which the
pipe NIF reads, then reads each one's budget and group through the
inspector, and closes the pipes, which ends them; `tools/erx bench make`
runs the `make`-shaped job with 1,000 children of toybox's `true` and the
same job on the host as the baseline. The measurement includes the sub-space's
creation, the startup message, `liberx`'s start-up and the event executor,
and nothing a program does after `main` begins. Measurement: bytes charged
per program, by object; start time per program, from the spawn request to
the sleep flag; the same for a pipeline of 16 created at once; children
per second and the handler's CPU per child for the `make`-shaped job,
first and last hundred compared. Decision it informs: the defaults of the
`programs` and `children` quotas, which follow from the bytes per program;
the data area's default slots; and whether a reader's scan of its writers
needs the mitigation of [Risks and open questions](#risks-and-open-questions).
Each result records host, accelerator, QEMU version, compiler, flags,
workload and baseline.

**Experiment E-P2, file I/O through the handler.** Hypothesis: a read of
4 KiB from a program costs at most 26 us under HVF, and a read of 64 KiB
at most 60 us, as derived above, and toybox's `md5sum` of each file of
a tree of 10,000 small files and `dd` of a 1 GiB file, from a program,
finish within the time those bounds predict from their request counts.
Method: `tools/erx bench fs` runs the reads from a program and from an
Erlang process of the same session against the same server, and the two
workloads from a program, with the same operations on a local mount as
the baseline; it counts requests, bytes and the handler's CPU, so the
per-request cost falls out. Decision it informs: whether the handler
stays on every file path, as the design says, or files a session serves
from its own domain are read through a lane the session gives the
program to its own file server, a change behind the handler that no
program would see; and the data area's slot count and size.

The first tier is an estimated 10,000 to 15,000 lines of C in `liberx` and
the musl seam, sized from its parts: the descriptor table and its objects,
the startup message, spawn and its planner, the event executor, `poll`,
signals and `mmap`; `erx_exec` and `erx_elf_plan` add an estimated 1,000.
The port driver is counted in the runtime's inventory
([design-runtime.md](design-runtime.md#programs-as-ports)). The second
tier adds an estimated 5,000 to 8,000: `fork` and `exec` about 1,500, the
changes to musl's dynamic linker about 1,500, and in the session's Erlang
the line discipline, process groups and sessions about 2,500 (estimates
summed from those parts).

## Portability

Programs use only erXos's kernel interface, through `liberx`, so they run
on every architecture and platform the kernel does. Three parts depend on
the architecture and sit behind its layer: the layout of the frame a vCPU
state area saves, which `liberx`'s signal entry and trampoline copy, and
any area below the stack pointer that the procedure-call standard
reserves; the machine type and relocation types that `erx_elf_plan` and
the loader accept; and the bytes of the frame `fork`'s saved registers
restore ([design-arch-aarch64.md](design-arch-aarch64.md)). In hosted
mode, programs run as macOS processes on `liberx`'s hosted backend
([design-runtime.md](design-runtime.md#hosted-mode)).

## Dependencies

No new dependencies. musl, whose dynamic linker the loader adapts, and
toybox with `wak` are in the dependency table of
[design.md](design.md#dependencies), and the Open POSIX Test Suite is a
test tool fetched at a pinned version and never linked into erXos.

## Alternatives considered

**Programs as domains.** Each program would be a domain of its own, with
a domain id, a node name, an export table and a connection to its
session, created by the system domain and reached through a third party
that validated every frame between it and its session. It buys a
program's isolation from its session's runtime equal to a domain's, a
program that the inspector lists among domains, and a place to put a
facet for each program. It costs a domain's creation in the system domain
for every spawn, an estimated 5 ms and about 250 KiB each, a startup
message of 22 fields naming connections and facets, a facet process per
program for signals and inspection, a range of process ids per image, a
third party on every request and on every transfer of a pipe end, and a
program that holds pids of other domains and can be a confused deputy for
a server. A program needs none of a domain's identity, since its whole
world is its session: as a port of its session it holds a channel and
memory, its handler acts for it, and the kernel's sub-space boundary is
the isolation ([A program is a port](#a-program-is-a-port)).

**Programs that speak to file servers.** A program would hold grants and
a connection to each file server, and send its requests itself, saving
the handler's hop on every read. It loses: a program would hold pids and
run the funnel, every server would have to check what a program sends and
a compromised program could speak to any server it held a grant on, and
a passed grant would have to move between domains. The handler relays
small terms at the cost of one channel round trip, which E-P2 measures;
the alternative that keeps the program without pids, a lane from the
program to a server of its own session's domain, stays open behind the
handler ([Performance](#performance)).

**Servers that copy into a program's memory.** Each file server would
reach a program's data area, or a buffer per open, and copy the bytes in
and out itself, saving the handler's copy. It loses: a capability to a
program's memory at every server, which needs a rendezvous between the
session and each server for each program, and a server writing memory it
did not allocate. The handler's copy costs one
copy of the payload, and keeps every server a plain process speaking
frames ([design-files.md](design-files.md#alternatives-considered)).

**A flat tree of programs under the session.** Every program's anchor
would hang directly from the session's space, and the handler would end a
program's children from its own list when the program ends. It loses: the
end of a tree would rest on the handler's list, which a spawn in flight
or a handler's crash leaves incomplete, and a child's death would reach
its parent's handler as a message, not as a fact of the kernel's. With
each anchor below its starter's, one `erx_space_stop` ends the whole tree
by K27, and `exec`, which stops only the image, leaves the children where
they are (P9).

**Pipes as messages through the session.** A pipe would be a protocol of
data and credit messages between a writer process and a reader process,
relayed by the session, with no shared memory. It loses on correctness by
construction: POSIX lets a descriptor be inherited and shared, so a reader
would have to track every process that may still write and decide when
the last one has gone, a list kept in every reader; the session's records
of who holds each end make the end of the stream a consequence of who
holds the ends, and the bytes skip the session
([design-pipes.md](design-pipes.md#alternatives-considered)).

**Wakeups relayed through the session.** Only the session would hold a
pipe's doorbells, and a writer's ring would be a frame to the session,
which would wake the reader. It loses: every wake costs an Erlang turn,
and a session that is busy delays every pipe. The session installs a
`TRIGGER` copy of each peer's doorbell into each holder, so a wake is one
kernel call from writer to reader and the session is not on the path
([design-pipes.md](design-pipes.md#waiting-and-doorbells)).

**Signals as bits of a page that the session triggers.** The port driver
would set a signal's bit in a page of the program's and trigger the
program's signal IRQ object directly, so a `kill` reached the target
without a frame. It loses: a `SIGCHLD` could arrive before the exit
report it announces, so a handler's `waitpid` with `WNOHANG` would find
no child; the session would hold a capability to a thread's IRQ object of
each program, which `fork` and `exec` would have to re-make; and a second
channel with a grammar of its own would stand beside the first. Signals
as reports on the one lane arrive in order with the reports they relate
to, and the event executor raises them through the IRQ objects inside the
program, which the session never holds ([The event
executor](#the-event-executor)).

**Programs that start only programs.** A program could be refused every
Erlang command, so that none could borrow the session's authority. It
loses, by the user's decision: security comes from capabilities, such as
the right to list processes, not from which kind of command runs, and
`xargs ps` is as legitimate as `xargs grep`. Command domains give an
Erlang command exactly its starter's capabilities.

**Erlang commands for programs in the session's domain.** The program's
handler could run the command in the session's domain with a context
holding only the program's capabilities. It loses two ways: authority is
per domain, so the confinement would rest on every command's code never
reaching past its context; and commands that act on the session itself,
such as `mount`, would act on the session. A command domain costs a
domain's start once per program image and needs none of that.

**Signals as Fiasco's exception path.** Upstream L4Re delivers POSIX
signals by forcing an artificial exception on the target thread with
`ex_regs`, which an in-task handler thread resolves by rewriting the
thread's registers; its source notes that this cannot interrupt a thread
waiting in the kernel. It loses here: every fault goes to the space's
fault gate, so a program has no exception handler of its own, and a
handler thread per program would hold control of every other thread. The
vCPU interface delivers the same events to the thread itself, with an
atomic return.

**Signals that cancel a call.** Fiasco's `ex_regs` can also cancel a
thread's IPC, which would let a signal end a call's reply wait. It loses:
a cancelled call whose request the server already took loses its reply,
which for a read or a write loses data, and P7 forbids abandoning a
request already sent.

**`system` and `popen` without rc.** They could fail with status 127, as
a shell that cannot run the command would, or run a POSIX shell. The user
chose `rc`: failing breaks every program that runs commands, and erXos
ships no POSIX shell. The choice is revisited if a POSIX shell is built,
which the second tier's `fork` makes possible.

**Executables copied into JIT objects.** `erx_exec` could copy each
executable's code into JIT objects of the program's own space. It loses:
no two programs would share a page of code, every start would read the
whole file, and the program would run in a JIT space where it could write
code of its own. File objects share code and keep it unwritable (P10), on
the stopgap as on erXos's kernel.

**Programs that fill their own file objects.** A program could create
sealed objects and supply them itself from its grants, with no command
server in the path. It loses: a program that supplies an object it may
execute makes code, and objects confined to one program share nothing.
The command
server, trusted session code, fills objects that its programs only read.

**The session loads executables from files.** The session would read the
file and copy its segments into the new program's image itself, with no
loader in the program. It loses: the session would parse untrusted
executables in its own domain, while `erx_elf_plan` parses them in the
program's own space, which holds only what the starter gave it, and a
malformed executable harms only the program.

**`exec` in a new sub-space under the session.** `exec` could start a
fresh program and end the old one, handing over its process id and its
descriptors. It loses: the new program would not be the old one's
parent's child, so the tree that ends a job with its root (P9) would need
a re-parenting step, and the process id would have to move between
records. A fresh image under the same anchor keeps the program, its
process id, its place in the tree and its children.

**Children below the image.** A program's children could hang from its
image, as they would if a program had one space. Then `exec`, which stops
the old image, stops them too, against POSIX and against a supervisor
that forks workers and re-execs itself. Keeping them would take either a
kernel call that moves a stopped space's children to another parent,
which breaks the fixed parent that K27 rests on and departs from Fiasco
for one caller, or a recorded difference from POSIX. A threadless anchor
is a space like any other, needs no new call, and makes the program's
lifetime and its image's two objects, as they are two lifetimes.

**An `exec` that the port driver completes alone.** The port driver could
stop the old image as soon as the handler accepts the request, install
what `Start` names and start the new image, with no step in which the old
image lets go. It loses everything the old image keeps outside the
kernel: its opens at the servers, which stay open and collide with the
new image's, the private write positions of its pipe ends, the signals
reported to it after it planned `Start`, and any reader lock it held.
Letting the old image close and hand over what it holds, after the port
driver has built the next image and before it stops the old one, keeps
one point of no return and gives every piece of state one owner.

**Resetting the space in place.** `exec` could keep the program's space
and its capability table and replace only its mappings and threads. It
loses: every capability the old image held, stray ones included, and its
sub-spaces would survive into the new image, the reset would need the
program stopped from outside while it ran, and `liberx` would have to
close what the new image must not inherit before the handler's checks,
so a refused `exec` would leave the old image without its descriptors
and signals. A fresh space starts with exactly what `Start` names, and
the old image runs on, whole, until the handler has accepted the request.

**A program record that mirrors the descriptor table.** The handler's
record could hold the descriptor table at every moment, told of each
`open`, `close`, `dup` and `fcntl` by a notice, so that an `exec` would
need nothing of the old image's table. It loses on cost: a notice for each
change puts a frame to the handler on paths that otherwise reach no
server, `dup` and `fcntl` among them; only a program that has taken a
record lock tells its handler of a `close` that keeps its open. The table
has one reader outside the image, the next image's startup message, and
the quiesce freezes it before `{exec}`, so the old image hands its kept
part over once, in a request whose reply confirms it ([The program
record](#the-program-record)).

**The alarm in the program record.** The handler could keep the alarm
and send `SIGALRM` as a report, so the alarm would cross an `exec` as any
signal does. It loses: every `alarm` and `setitimer` would wait for the
handler, and a repeating timer would cost a frame at each interval, while
the old image's capture already hands the next deadline over exactly, and
a deadline that passes during the switch fires at once in the new image.

**Job control by holding a group.** The session could stop a program by
setting its group's grant to zero. It loses: a thread running on another
CPU goes on until its next accounting point, a thread the kernel is
serving finishes its call, and the grant the session writes for job
control is the one it writes for shares, so a `fork`'s release could undo
a `Ctrl-Z`. A pause is a count the kernel keeps on the space, which stops
every thread of it at its next return to user mode and composes by
counting ([Job control](#job-control)).

**A copy-on-write `fork`.** `fork` could share pages instead of copying
them. Private memory has no capability and each of its pages is mapped once
(K5), so a copy-on-write `fork` would need the program's heaps and stacks
built from shared objects, which `fork` could seal and give each side
children of. It stays an option, not a commitment; the eager copy is
correct, charged at the call, and simple.

**Pseudo-terminals in the kernel.** The kernel could carry the line
discipline, as UNIX kernels do. It loses: the kernel holds no terminal
policy, and the session already serves files and owns its terminal; a line
discipline in the session is a pure state machine, tested on the host.

**Fixed limits per session.** Each session could keep a fixed number of
programs and children. It loses to quotas: the right numbers depend on a
program's measured cost and on each principal's budget, which
`erx_policy` already owns.

**Open-file descriptions at the server.** Each file server could keep
the open-file description, its offset and its status flags, and a pass
could be a request to the server for a grant that shares it. It loses:
9P2000.L has no such request and carries an explicit offset in every
read and write, a passed file would end with the grant it was passed
from rather than live as on UNIX, and every pass would cost a round trip.
POSIX puts the description beside the process table, which for programs
is the session ([Descriptors and files](#descriptors-and-files)).

**A deadline on the startup message, and signals that abandon
requests.** A deadline on the startup message loses to writing the
message into the lane before the first thread starts, which deletes the
timer and its race; a handler without `SA_RESTART` that flushes a request
in flight and returns `EINTR` loses correctness, since the server may
already have applied a write or advanced a shared offset.

**Read-only images in a program's namespace.** A program's namespace
could hold an EROFS image directly, as a runtime's does, so that reading
an image's files costs no round trip. It is not adopted: a direct image
shows the whole of itself, so it fits only programs that may read all of
it, and the server path serves every program alike; `tools/erx bench fs`
would show whether it pays.

**A file's one object at its server, paged by the kernel.** Each file
that programs map shared would have one writable object at its file
server, which every shared mapping in any session maps and through which
the server serves every read and write of the file. It buys coherence
across sessions and with every descriptor and every reader, at once, as
Linux's page cache gives. It costs a pager in the kernel: a fault on a
page not yet supplied becomes a call to the server's domain, which needs
a supplier gate fixed at the object's creation, a fault worker at the
server and a deadline after which the waiting program ends, so a slow
server stalls its clients' threads; a claim gate per session at each
server, through which the session takes the object's capability with a
key;
and objects charged to the server's cache budget, which every client
shares. erXos does not take it, by the user's decision: the session
serves its programs' shared mappings, every fault resolves from an
object or ends the thread, and the price is coherence that stops at the
session's edge, a documented difference with a test
([Shared libraries and mappings of
files](#shared-libraries-and-mappings-of-files)).

**An object for each program.** Each program's shared mappings of a file
would map an object of its own, filled and written back for that program.
It loses: two programs of one session that map a file shared, which POSIX
requires to see each other's stores, would not, and every program would
fill and hold its own copy. One object per file in the session is the
smallest unit at which POSIX's sharing holds.

**Descriptor reads and writes straight to the server while a file is
mapped.** The session's descriptor reads and writes of a file it maps
shared would go to the server past the mapper, saving one message each,
and a shared mapping would see a descriptor's write only once every
program had let go of the file and mapped it again. It loses: a program
that mixes `write` and `mmap` on one file, as databases do, would read
stale bytes through its own mapping, and a write-back would overwrite a
descriptor's write to a page a program had also stored to. Sending them
through the mapper, which writes each write to the object and to the
server in the same turn, keeps descriptors and mappings in the session in
agreement for a lookup in the session's file table and one message to the
mapper ([design-files.md](design-files.md#shared-mappings)).

**Linux binary compatibility and a Linux virtual machine.** Rejected by the
user. Neither is designed, and nothing in erXos leaves room for them.

**BusyBox, or sbase, as the toolbox.** BusyBox is GPL-2.0, a permanent
copyleft dependency. sbase (MIT) has no awk; it is the fallback if toybox
proves hard to adapt.

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| The handler on every file path costs more than the estimate | medium | file-heavy programs, compilers and `find` among them, run slower than on UNIX by the handler's hop on each request | E-P2; the data area's 64 KiB slots, and walk, open and first read in one round trip ([design-files.md](design-files.md#performance)); a lane from the program to a file server of the session's own domain, a change behind the handler that no program sees ([Alternatives considered](#alternatives-considered)) |
| A reader's look at its pipe's writers is linear in their number | low | a pipe with hundreds of write ends, a `make`'s shared output among them, costs each read a scan of every writer's lane | the pipe server tells readers of writers that are gone, so the list shrinks as children end; E-P1's `make`-shaped job measures it; a wake mask that names the writer that rang is the fix if it shows ([design-pipes.md](design-pipes.md#risks-and-open-questions)) |
| toybox's applets depend on Linux interfaces more than expected | medium | medium | applets built one by one against the seam, each with its tests; sbase as the fallback |
| Recompiled programs expect `fork`, `exec`, or `sh` syntax in `system` | high | in the first tier a program fails to link, or its `system` command means something else in rc | the spawn helpers of toybox and similar programs are rewritten over `posix_spawn` in the tree; link failures are loud; the second tier provides `fork` and `exec`; rc's porting note lists the translations, and a command rc cannot parse fails with a diagnostic |
| Recompiled programs detach: `daemon`, a double `fork`, `nohup` | medium | the detached child ends with the program that started it, and a ported service dies with its shell | the documented difference and its test; a service runs as a domain under a supervisor ([design-system.md](design-system.md#system-services)) |
| `system`, `popen` and Erlang commands started by programs are slow, a command domain's start each first time | medium | a program that runs many commands is slow at its first | the command domain is kept for the program's image, so a second command costs a frame; a small release for the command image; `tools/erx bench system` |
| `fork` of a large program is slow, a copy of all its memory | medium | `fork` followed by `exec` wastes the copy | `posix_spawn` stays the fast path; `tools/erx bench fork`; the copy-on-write `fork` option |
| A session's code objects hold much of its budget | low | the session runs out of memory sooner | `file_objects` and an eighth of the budget bound the table; eviction keeps live objects alive in their programs only; data objects are the program's own and end with it |
| Write-back of shared mappings costs more than programs expect | medium | a program that maps a large file and stores widely pays a write for each run of stored pages at every `msync` and every letting-go, and an `mmap` pays up front the filling of the object from the file's start to the mapping's end, a high offset included | only stored pages are written, from the kernel's report; gate GQ measures fill and write-back with `tools/erx bench mmap` ([plan.md](plan.md#decision-gates)); filling on first touch would need a pager, which the design rejects ([Alternatives considered](#alternatives-considered)) |
| Ported programs rely on writes from outside their session showing in a shared mapping at once, as Linux's page cache gives | low | such a program reads stale bytes through its mapping until every program of its session has let go of the file | the documented difference and its test; programs that share a mapped file run in one session, where descriptors and mappings agree at once ([Alternatives considered](#alternatives-considered)) |
| Ported programs hard-code Linux's signal numbers or name Linux's own signals | low | a program that sends `kill(pid, 19)` meaning a stop continues its target instead, and one that names `SIGPWR` unconditionally fails to compile | code that builds on FreeBSD and macOS names its signals and guards Linux's own names already; the oracles' documented differences ([Signal numbers](#signal-numbers)) |

Decided by the user: a program is a port of its session, not a domain,
and its whole world is its session; security comes from capabilities,
among them the right to start commands and the rights to list and to
signal processes, never from which kind of command a program starts; a
program may run an executable file from its namespace when its grant
carries `rx`, and no grant carries `rw` and `rx` together; `system` and
`popen` hand their command to `rc`; in the first tier `fork` and the
`exec` family are absent, so calling them fails to link, and the second
tier's first `fork` copies eagerly, copy-on-write being an optimisation;
shared libraries are static first and dynamic after, to at least QNX's
level; full-screen programs on terminals are planned; the kernel gains
Zircon's idea of copy-on-write as a kind of memory object; a file's
offset lives in its open-file description, shared by every program the
description is passed to; a session serves its programs' shared mappings
of a file from one object of its own, filled and written back with
ordinary reads and writes; and a program ends with
the program or session that started it, like a job tree, while a
long-running service starts under a supervisor, never by detaching, so
nothing is orphaned; and erXos's musl uses FreeBSD's signal numbers, the
numbers the command shell's `kill` takes.

Two engineering questions, with the answers the design follows:

* **Does forwarding carry enough of toybox's tests?** The forwarding command
  mirrors a working directory's names and contents, not every UNIX
  attribute. Recommended: build it with the first applets and count the
  tests recorded as unsupported; if they leave an applet's behaviour
  unchecked, write rc tests for that applet in the shell's corpus. The count
  from the first applets settles it.
* **Does musl keep `SIGPOLL`?** FreeBSD defines no `SIGPOLL`; Linux makes
  it an alias of `SIGIO`, and POSIX's XSI option names it. Recommended:
  keep it as an alias of `SIGIO` ([Signal numbers](#signal-numbers)): it
  adds no number and no line to `kill -l`, and code written for Linux that
  names it builds. Dropping it instead matches FreeBSD's headers exactly
  and costs only such code a build failure. The user decides.

## References

* The Open Group Base Specifications Issue 8 (IEEE Std 1003.1-2024),
  `posix_spawn` (the child's signal mask and dispositions), `system` (a
  null command, and status 127), `sigprocmask`, `kill` (a `pid` of 0, of
  -1 and below: "for which the process has permission to send a
  signal"), `waitpid` (a `pid` of 0 and below -1), `mmap`, `fork`, `exec`,
  XBD 3.247 "Orphaned Process Group", XBD chapter 11 "General Terminal
  Interface", and XSH 2.4.3 "Signal Actions" (the stop signals discarded
  for a member of an orphaned process group),
  https://pubs.opengroup.org/onlinepubs/9799919799/ (read 2026-10-30).
* Linux, `kernel/signal.c`, `sig_ignored()`: "Blocked signals are never
  ignored, since the signal handler may change by the time it is
  unblocked", https://github.com/torvalds/linux (master, read
  2026-10-30).
* Linux man-pages 6.19, pipe(7) (2026-07-10), "Pipe capacity" and
  "PIPE_BUF", https://man7.org/linux/man-pages/man7/pipe.7.html.
* Fuchsia, "Socket - Bidirectional streaming IPC transport", Zircon kernel
  objects reference, https://fuchsia.dev/fuchsia-src/reference/kernel_objects/socket
  (read 2026-10-30).
* Fuchsia, "Job", Zircon kernel objects reference,
  https://fuchsia.dev/fuchsia-src/reference/kernel_objects/job, for a job
  whose processes end with it.
* Plan 9 from Bell Labs, "Plan 9 from Bell Labs" (Pike, Presotto, Thompson,
  Trickey, Winterbottom), Computing Systems 8(3), 1995, for the kernel as
  its processes' whole world, file server and namespace.
* toybox 0.8.15, `wak`, and the Open POSIX Test Suite, as checked in
  [research-boards-storage.md](research-boards-storage.md#the-toolbox).
* musl 1.2.6, its dynamic linker in `ldso/`, <https://musl.libc.org/>, and
  [research-c-library.md](research-c-library.md).
