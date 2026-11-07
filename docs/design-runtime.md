# The runtimes: ERTS and native code in user mode

A runtime is the second level of erXos's scheduling: the code in a domain
that runs lightweight processes on the executors its group's grant pays
for ([design-scheduler.md](design-scheduler.md)). ERTS is the runtime.
Its source, OTP 29.1.2, lives in erXos's tree as erXos's own code, and
erXos takes it apart and recombines it around the kernel's mechanisms:
ERTS keeps its scheduler of Erlang processes, its collector, its loader,
its JIT, its port layer and its distribution layer, and loses every layer
that only adapts it to a hosted operating system. Every ERTS domain runs
in user mode on one of two runtime images: the interpreter image, which
the system domain runs, and the BeamAsm image, which ordinary domains
run. Native code, the programs of a session and the native shims of
drivers, runs in sub-spaces of an ERTS domain and uses `liberx`, the
library through which all code reaches the kernel. The architecture is
in [design.md](design.md); the kernel in
[design-kernel.md](design-kernel.md); domains, connections, frames and
exports in [design-domains.md](design-domains.md).

Decisions every reader of this document needs:

* **ERTS schedules Erlang processes; the kernel schedules ERTS's threads.**
  ERTS's run queues, priorities, reductions, stealing, balancing and dirty
  schedulers stay. Its normal and dirty CPU schedulers are executors of the
  domain's group; its dirty I/O schedulers and helper threads are workers.
* **The adapter is small and at the edges.** Scheduler sleep becomes
  `erx_park`; waking a scheduler becomes `erx_executor_wake`; the poll set
  becomes the group's ready list, taken at safe points and dispatched
  through one event table; scheduler binding becomes pinning;
  `schedulers_online` follows the group's capacity; executors publish
  their urgency. Nothing else in ERTS's scheduler changes, and its process
  state protocol is untouched ([Scheduling](#scheduling)).
* **ERTS is a parts bin.** Ethread's pthread layer runs on musl's threads,
  which run on `liberx`; the UNIX sys layer, the poll set, the forker, UNIX
  signals and dynamic loading are deleted, not stubbed; ERTS's
  address-space manager reserves and commits through the kernel. What
  ERTS assumes never constrains the design ([The inventory](#the-inventory)).
* **Every domain is a node; connections are distribution over lanes.**
  A domain is the Erlang node `<id>@<host>`, its identifier at the
  machine's host name, with its domain id as its creation: `node()`
  returns that name and `nodes()` the domains it is connected to. Its
  cross-domain path is ERTS's own distribution layer, unchanged: one
  distribution entry per peer, keyed by the peer's node name as stock
  ERTS keys it, with a port as its controller whose driver writes frames
  into the connection's outbound lane; one executor at a time drains the
  inbound one. A full lane leaves frames in the entry's queue, and the
  entry is busy, suspending its senders, once that queue passes ERTS's
  busy limit. A pid prints as `<D.N.S>` with its owner's domain id, the
  one documented difference in a node's identity. Who may signal which
  of the domain's processes is the export table, which lives in ERTS and
  is written at exactly three sites
  ([Connections in ERTS](#connections-in-erts)).
* **A program is a port of its session.** The session's runtime creates
  the program's spaces, a threadless anchor and an image below it, maps
  its image, gives it a channel and pipe ends, and starts its thread; the
  program's requests reach a handler process, signals reach it as reports
  on its channel, and its end reaches the port's owner as
  `{exit_status, N}`
  ([Programs as ports](#programs-as-ports)).
* **Drivers are Erlang processes** over the device NIF, which exposes
  `liberx`'s DMA envelope: registers by name, buffers from a pool, posted
  and completed descriptors, acknowledged interrupts, and nothing parsed
  from what a device wrote ([The device NIF](#the-device-nif)).
* **Two runtime images, one per execution flavour.** The system domain
  runs the interpreter image, which holds no BeamAsm, no asmjit and no
  C++ and makes no JIT object, so the trusted base holds no generated
  machine code and no writable view of code. Every other ERTS domain runs
  the BeamAsm image by default, with its code in memory objects mapped
  writable at one address and executable at another; a domain's
  specification may choose the interpreter image, and command domains and
  every domain in deterministic mode run it. Each image is a file of the
  boot image, mapped and shared by the domains that run it, and both keep
  ERTS's allocators as they are ([BeamAsm](#beamasm), [Memory](#memory)).
* **No NIF blocks an executor.** A NIF or BIF that would wait in the kernel
  on a normal scheduler fails instead of stalling it, and blocking work runs
  on dirty I/O schedulers, which are workers
  ([NIFs and blocking](#nifs-and-blocking)).
* **`liberx` is the only way to the kernel.** It wraps every kernel call,
  generated from `abi/erx_abi.txt`, with three backends: erXos's kernel, the
  stopgap Fiasco, and a hosted implementation on macOS for development
  under the sanitizers. Its call stubs hand the kernel values alone:
  registers, fields of the calling thread's UTCB, or a memory window, a
  memory object's capability with an offset and a length; no stub passes
  the kernel an address to read or write. It holds the funnel, the lane
  code, the DMA envelope, the loader,
  the root-task entry and the domain library ([liberx](#liberx)).
* **musl is the C library of every runtime and program**, reshaped as
  erXos's code: `liberx` stands where its Linux system-call layer stood,
  its Linux processes and signals are deleted, and its dynamic linker lives on
  only as the loader of programs, which maps code from file objects
  ([The C library seam](#the-c-library-seam)).
* **ERTS's build machinery stays, behind one seam.** ERTS keeps its
  `configure`, makefiles and Perl generators, edited for the target
  `aarch64-unknown-erxos`; erXos's build invokes them through one entry
  point ([The build](#the-build)).

## Context

ERTS was built for one node on a host operating system. It multiplexes
millions of processes over one scheduler thread per CPU, waits for input
in a poll set over file descriptors, drives ports through port tasks,
speaks to other nodes through distribution entries whose controllers are
ports or processes, and asks its host for threads, memory, time and
signals ([research](research-erts-host.md)). On erXos the host is the
kernel, the boundary between domains is a connection, and a program is a
sub-space the runtime created. The scheduler design asks runtimes to
follow a short contract: executors that park, events taken at safe points,
executors that never wait outside their domain, and optional hints
([design-scheduler.md](design-scheduler.md#the-runtime-contract)). This
document is how ERTS meets that contract, how its host requirements are
met, how its distribution and port layers carry connections and programs, and
what native code links against.

ERTS already has the shape the contract wants. Its schedulers sleep with a
compare-and-swap protocol on per-scheduler flags followed by a wait on a
thread event, so a park that checks an epoch maps onto it directly
([research](research-erts-internals.md#scheduler-sleep-and-wake)). Its
scheduling point, `erts_schedule`, runs between processes on the
scheduler's own stack with no lock held, and every 4,000 reductions at most
([research](research-erts-internals.md#the-scheduler-loop-and-run-queues)):
the natural safe point. Its dirty schedulers already separate work that may
take long or block from work that must not. Its distribution layer already
has one queue per peer, a busy state that suspends senders, and lazy
decoding of a message in its receiver; its port layer already links a port
to an owner, serialises a port's work, and reports an exit status.

ERTS stays out of the kernel. Every runtime runs in user mode, so the kernel
stays generic and a second runtime needs nothing from it that ERTS does
not also use ([Alternatives considered](#alternatives-considered)).

## Requirements

Functional requirements:

1. **Run OTP 29.1.2 applications** inside a domain with Erlang's semantics
   for processes, messages, links, monitors, code loading, ETS and timers,
   checked against stock OTP 29.1.2 on the development host.
2. **Meet the runtime contract** of
   [design-scheduler.md](design-scheduler.md#the-runtime-contract).
3. **Use the cooperation features when enabled**: published urgency,
   deferred preemption and status words, each switchable by the group's
   flags.
4. **Adapt to capacity**: change the number of active schedulers at a safe
   point when the group's capacity changes.
5. **Two execution flavours, one image each**: the interpreter image in
   the system domain, command domains and deterministic mode; the BeamAsm
   image by default in every other ERTS domain, the interpreter image
   where a domain's specification asks for it.
6. **Connections**: every cross-domain signal of Erlang's semantics (send,
   alias send, link, monitor, exit, group leader, spawn) over the domain's
   lanes, through the funnel, against the domain's export table, with stock
   Erlang's behaviour toward a process that does not exist for an
   operation the domain did not authorise
   ([design-domains.md](design-domains.md#exports)).
7. **Programs as ports**: a session's runtime starts, serves, signals and
   ends the native programs of its session as ports, within its own budget
   and group ([design-programs.md](design-programs.md#a-program-is-a-port)).
8. **Drivers in Erlang**: a driver process reaches its device through the
   device NIF alone, and no device can corrupt the runtime's memory through
   it ([design-system.md](design-system.md#drivers)).
9. **The root task**: `liberx` starts the system domain from the root
   capabilities, and the system domain creates, inspects and ends every
   other domain through the domain library
   ([design-system.md](design-system.md#the-root-task)).
10. **Hosted mode**: the runtime, its system services and native programs
    run as macOS processes on `liberx`'s hosted backend, under ASan, UBSan
    and `lldb`.
11. **Files through the namespace**: `prim_file` resolves every path
    through the domain's namespace ([design-files.md](design-files.md)).
12. **Code loaded by hash**: a module is named by the SHA-256 of its
    bytes, and a fetch from the code service checks it
    ([design-live.md](design-live.md#the-code-store)).

Non-functional requirements:

* **Speed.** Message passing, spawn and process switches inside an
  ordinary domain within 1.2 times stock ERTS in the same flavour on the
  same host CPU, because these local paths never enter the kernel (a
  target; [plan.md](plan.md) measures it under HVF against the host's
  stock OTP). A cross-domain message costs one copy into a lane, one copy
  out, and a decode in its receiver, with at most one kernel call per
  batch at each end ([Performance](#performance)).
* **Idle cost.** An idle domain consumes no CPU: every executor parks
  without spinning, with its next timer as its deadline.
* **Size.** The memory of a minimal ERTS domain is a budget that
  [plan.md](plan.md) sets from the host baseline
  ([research](research-baselines.md#erts-node-baselines-host-otp-2842));
  each runtime image is mapped from the boot image and shared by the
  domains that run it.
* **Compatibility checked, not assumed.** Every difference from stock OTP
  is documented with a test
  ([Erlang-visible behaviour](#erlang-visible-behaviour)).

Non-goals:

* POSIX as the base. POSIX is an optional personality for programs:
  nothing above the kernel interface depends on it, and Erlang code never
  sees it ([design-programs.md](design-programs.md)).
* Ports over operating-system processes or file descriptors: the port
  layer stays for erXos's own linked-in drivers, the lane driver and the
  program driver, and for nothing else.
* Distribution over TCP between erXos domains: domains reach each other
  through connections. TCP distribution to machines outside belongs to a
  network service ([design.md](design.md#networking)).
* A second runtime. The contract does not preclude one, and the funnel
  and lane code are a library any runtime can link, but none is designed
  without a user.

## Overview

```text
  one ERTS domain (user mode)
  +---------------------------------------------------------------------------+
  | Erlang code: OTP kernel, stdlib, the application; drivers; services       |
  |---------------------------------------------------------------------------|
  | ERTS (otp/): processes, signals, GC, ETS, loader, BeamAsm or interpreter  |
  |   scheduler: run queues, priorities, reductions, stealing, dirty pools    |
  |   distribution: one entry per connection, its controller a lane port      |
  |   ports: the lane driver, the program driver                              |
  |---------------------------------------------------------------------------|
  | adapter (otp/erts/emulator/sys/erxos/): park and wake, the event table,   |
  |   capacity, urgency, defer, memory, time, files, debug log; the export    |
  |   table; the lane and program drivers; the device, pipe and domain NIFs   |
  |---------------------------------------------------------------------------|
  | musl (threads, malloc, strings, libm) | libc++ (BeamAsm image) | liberx   |
  +---------------------------------------------------------------------------+
     executors: normal and dirty CPU schedulers    workers: dirty I/O, helpers,
          |  erx_park, lanes, memory, umtx          |  the gate worker; may block
          v                                         v
                        kernel (design-kernel.md)
       sub-spaces of the domain: its programs and native shims, each on a
       channel to a port of the runtime
```

**The life of a message.** A process sends to a process of its own domain:
ERTS copies the message into the receiver's queue and, if the receiver
waits, makes it runnable on a run queue; if that run queue's scheduler is
parked, the adapter wakes it with `erx_executor_wake`. No kernel call is
made unless a scheduler must be woken. A process sends to a process of
another domain: ERTS's distribution layer encodes a frame onto the connection's
distribution entry, whose controller is the lane port; the lane driver
copies the frame into the connection's outbound lane and, if its store of
the write position crosses the position the peer published in its reader
page, rings the peer's bell. In the peer, the
bell lists itself on the group's ready list and wakes a parked
executor; at the next safe point an executor takes the ready list, finds
the connection's label, and takes the connection's drain word; it copies
each frame out of the ring once, runs the funnel against the export
table, and hands each accepted frame to `erts_net_message`, which queues
the still-encoded message to its receiver, where it is decoded when
received ([design-domains.md](design-domains.md#the-peer)).

**What changes in ERTS, in one list.** The adapter's edits are confined to
these places, each a seam: scheduler sleep and wake in `erl_process.c`;
the poll set's call sites (`erts_check_io`), which become the event
table's drain; scheduler binding; the scheduler loop's safe point, which
gains the checks of the contract; the reduction-free lock paths that raise
`defer`; the pick of the next process, which reads its job tag; the
channel-number macros, which print the node of a pid, port or reference as
its creation, and the parsing BIFs' mapping back; the encoder, which
writes the export table when it encodes one of the domain's own pids or
aliases for a connection; process exit and alias deactivation, which clear
the pid's or alias's export holders; the distribution entry's queue, which
in the system domain drops a message rather than suspend its sender, and
its count of what it holds for a peer; the distribution decoder, which
decodes in safe mode in the system domain and whose undecoded frames count
toward their receiver's queue quota and `max_heap_size`; the delivery of a
message to its receiver, with its target's request limit and its origin;
reference creation, comparison, hashing and encoding, which use the
four-word identity below, and alias dispatch, which uses the local alias
registry; the loader's installed-storage check; in the BeamAsm image,
the JIT's memory backend and error paths; and the sys layer, which is
`sys/erxos`.
Everything else in ERTS, its node table and distribution entries included,
is unchanged or deleted.

## The inventory

Where ERTS and erXos each have a mechanism for the same job, erXos keeps
one: the better of the two, or a redesign. The measure is elegance and
simplicity first, speed second. Paths are relative to `otp/`; `beam/` is
`erts/emulator/beam/`.

### One mechanism per job

| Job | ERTS's mechanism | erXos's mechanism | End state | Why |
| --- | --- | --- | --- | --- |
| Choosing which process runs | per-scheduler run queues, four priorities, reductions, stealing, balancing, dirty run queues (`erl_process.c`) | none: the kernel schedules threads | **kept**, as the second level; sleep and wake, binding and `schedulers_online` adapted ([Scheduling](#scheduling)) | ERTS's scheduler is proven and fast, and switches without entering the kernel |
| Choosing which thread runs | the host's thread scheduler | the kernel's group scheduler | **the kernel's** | one CPU-time authority |
| Waiting for work | spin, then a thread event or the poll set (`scheduler_wait`) | `erx_park` with epochs | **redone** over `erx_park`; spinning short or off | no lost wakeup by construction; no budget burnt spinning |
| Readiness | the poll set over file descriptors, poll threads (`erl_poll.c`, `erl_check_io.c`), `enif_select` | IRQ objects bound to the group, taken from the ready list | **redone**: the event table replaces `erts_check_io`; a label names a port or a process ([The event table](#the-event-table)) | there are no file descriptors |
| Timeouts | per-scheduler timer wheels (`time.c`, `erl_hl_timer.c`) | park deadlines | **kept**: ERTS's wheels; a parking executor's deadline is its wheel's next expiry | the wheels are O(1) and per scheduler; the kernel needs only one deadline per park |
| Deferred reclamation | thread progress (`erl_thr_progress.c`) | none needed in the kernel | **kept** inside the runtime; a parked executor counts as asleep | proven, and the code barrier rides on it |
| Long-running C work | dirty CPU and I/O schedulers | executors and workers | **kept**: dirty CPU schedulers are executors, dirty I/O schedulers workers | the classes match what each pool may do |
| Memory | allocators over carriers from `erl_mmap` and `erl_mseg` over `mmap` | reserve, commit, decommit, release in the kernel, charged to the domain's budget | **kept** inside carriers; the primitives are kernel calls ([Memory](#memory)) | the domain budget protects other domains; inside a domain, `max_heap_size` is the bound |
| Threads, locks, thread data | ethread over pthreads; futexes on Linux | `liberx` threads and umtx | **kept**: ethread over the C library's pthreads, musl's on `liberx` natively and libSystem's hosted, with its events over umtx in every build ([Threads and synchronisation](#threads-and-synchronisation)) | the least change; umtx waits on private memory are allowed to executors |
| Messages inside a domain | signal queues | none | **kept** | Erlang's semantics are the system's |
| Messages between domains | distribution: node tables, entries, controllers, control messages, lazy decode (`dist.c`, `erl_node_tables.c`, `external.c`) | lanes, the funnel, the export table | **merged**: every domain is a node `<id>@<host>` with its domain id as creation, and each connection is one stock distribution entry, its controller a port whose driver speaks the lane; the funnel validates each frame before `erts_net_message`; the export table answers authority ([Connections in ERTS](#connections-in-erts)) | ERTS already routes every remote operation through one path, keeps flow control per entry, and decodes lazily in the receiver; a node per domain keeps its node table, `net_kernel` and its tools stock |
| References | per-scheduler counters (`erl_bif_unique.c`) | none | **redone**: AES-128 of a nonrepeating counter forms every reference; a bounded local registry resolves aliases ([Unguessable references](#unguessable-references)) | identity is unique by construction; guessing an undisclosed reply tag has an explicit cryptographic bound |
| Ports | ports, port tasks, linked-in drivers, spawn drivers, `fd` ports (`io.c`, `erl_port_task.c`) | sub-spaces and lanes | **kept** for three linked-in drivers: the lane driver, the program driver and `ram_file_drv`, which `file:open(Bin, [ram])` needs and which reaches no operating system; spawn and `fd` ports, the forker and `erl_child_setup` dropped ([Programs as ports](#programs-as-ports)) | a port already has an owner, a link, serialised work, busy flow control and an exit status |
| Device drivers | linked-in drivers | Erlang processes over the device NIF | **redone**: a driver is an Erlang process; the C under it is the device NIF, parsing nothing ([The device NIF](#the-device-nif)) | a device that lies corrupts no memory |
| Operating-system adaptation | the UNIX sys layer, UNIX signals, dynamic loading | `liberx` | **dropped**; `sys/erxos` implements the little that remains (time, float conversion, the C path for standard output and error, `prim_file`'s platform layer, crash output, the adapter) | nothing to adapt to |
| Time | the time supervisor's correction over OS clocks (`erl_time_sup.c`) | the counter and the time page | **redone**: one clock; correction for imperfect clocks deleted; Erlang's monotonic and system time semantics kept | the counter is exact |
| Code from storage | `erl_prim_loader` through `prim_file` | boot-image slices mapped read-only | **kept**, with whole-file reads returning binaries over the slice's pages, without a copy, and an EROFS image's files read by the EROFS reader, preloaded Erlang, from blocks the hash-checking primitive returned; the code server checks the hash of every blob it fetches from the code service ([Code in the system domain](#code-in-the-system-domain)) | `init` and boot scripts need no change, and a slice's files are covered by the boot image's validation |
| Executing Erlang code | the interpreter and BeamAsm, one per build | memory objects mapped writable at one address and executable at another | **both kept**, as two runtime images: the interpreter image for the system domain, the BeamAsm image for other domains ([BeamAsm](#beamasm)) | the interpreter keeps generated code, JIT objects and C++ out of the trusted base and is deterministic; BeamAsm is up to four times faster |
| Crash diagnostics | crash dumps to a file | a crash area handed out at domain creation | **redone**: the dump goes to the crash area, and the domain stops itself ([Crash handling](#crash-handling)) | one diagnostic path, read by the system domain |
| Tracing | trace sessions and tracers | the kernel trace ring | **both kept, one viewer** ([design-live.md](design-live.md#tracing)) | they observe different layers |
| Third-party code inside OTP's tree | asmjit (Zlib), PCRE2 (BSD-3-Clause WITH PCRE2-exception), zlib (Zlib), zstd (BSD-3-Clause, or GPL-2.0-only, used under BSD), Ryu (Apache-2.0 or BSL-1.0) | none | **kept**, each under its licence; asmjit only in the BeamAsm image | they serve kept features |

### Everything else

Kept from ERTS: processes and their heaps, garbage collection and copying,
terms, maps, bignums and Unicode; the loader and the interpreter, with the
Perl generators; BIFs, less those of sockets and operating-system
processes, plus `erx`'s own; the port BIFs for erXos's drivers; the NIF
interface for statically linked NIFs, without `enif_select`; ETS,
persistent terms, atomics and counters; the external term format; atoms,
exports, funs, modules and records; links, monitors and aliases; ERTS's
process locks; tracing; and both execution flavours, one per image.

Kept from OTP's Erlang code: the preloaded modules less `prim_socket`,
`socket_registry` and `prim_net`, plus erXos's `erx_erofs`, the EROFS
reader, and `erx_file_remote`, the client of every file server
([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)); `kernel`, with `os:type/0` returning `{unix, erxos}`, `os:cmd/1`
raising `badarg`, `heart` and `erl_boot_server` not started, and
`net_kernel` started in every domain under the domain's node name with
erXos's carrier, and otherwise stock but for the edits listed below, the
hooks that start erXos's watchdog and console among them; `stdlib`
unchanged; `compiler` and `runtime_tools`, the latter without its trace
port drivers and its `dyntrace` NIF, both loaded and not started: the
release file gives each the start type `load`, so the boot script loads
its `.app` and puts it on the code path, the shell has `c:c` and `dbg`,
and nothing of either runs at boot, `runtime_tools`' `ttb_autostart`
included; `sasl` and `tools` where a
release asks for them. Each shipped application ships its beams, its
`.app` and its `include/*.hrl` headers, so code compiled on erXos finds
them through `include_lib` as on stock, and no `.appup`, since an update
replaces a whole slot. erXos's own Erlang code is applications of its own
under `erlang/apps/` ([design.md](design.md#repository-layout)), listed
after OTP's applications in the release file: `erx`, the runtime's
services (`erx_connections`, `erx_dist`, `erx_program`, `erx_device`,
`erx_watchdog`, the console, the kernel log and the namespace); `erx_files`,
the Erlang file servers; and one driver application per device class,
`erx_uart` the first. None has an application callback: what must run is
started by `kernel`'s hooks, and the boot script's code path, which names
every application of the release, finds the modules they call, which the
code server loads on first call. `crypto`, `ssl`, `ssh`, `inets`
and the rest are outside the shipped set: they depend on a network stack
and on OpenSSL 3.5 ([design.md](design.md#dependencies)), and arrive with
the network service ([plan.md](plan.md#m12-storage-networking-boards)).

NIF libraries: `socket` and `net` dropped; `prim_file` kept with erXos's
platform layer; `zlib`, `zstd`, `erl_tracer` and `prim_buffer` kept;
`prim_tty`'s NIF dropped, since a shell's driver renders in
`prim_tty`'s terminal-less mode over its tty (edit 38); and
erXos's own added: the per-byte primitives, the device NIF, the pipe NIF,
the domain library's NIFs and the watchdog NIF
([Per-byte primitives](#per-byte-primitives),
[The device NIF](#the-device-nif),
[The root-task entry](#the-root-task-entry)). The build derives this
classification from ERTS's static NIF list (`erts/emulator/Makefile.in`),
so a NIF added upstream is neither kept nor dropped silently: the build
fails until the list names it.

### The edits outside `sys/erxos`

Everything the adapter adds lives in `sys/erxos`, the drivers and NIFs
included. The edits to ERTS's own files, and those to seven files of
`kernel`, two of `stdlib` and the preloaded `erlang.erl`, are these, each at a seam named above; an edit is one change
of behaviour, however many lines it touches:

| File | Edit |
| --- | --- |
| `beam/erl_process.c` | 1. `scheduler_wait` parks with `erx_park` instead of the thread event or the poll set; 2. `wake_scheduler` and the enqueue paths wake with `erx_executor_wake`; 3. the safe point in `erts_schedule` runs the adapter's plan (ready list, capacity, urgency); 4. the pick of the next process reads its job tag; 5. schedulers are created as executors, pinned to the run, and `+S` is derived from the grant |
| `beam/erl_process.h`, `beam/erl_process.c` | 6. `Process` carries a job tag, taken from its parent at `erl_create_process` |
| `beam/erl_lock_count.c` and the run-queue, process and carrier lock paths | 7. `defer` raised and lowered around the scheduler's and allocator's critical sections, under `ERX_GROUP_DEFER` |
| `beam/external.c` | 8. encoding one of the domain's own pids or aliases for a connection, a control term's sender included, gives the peer `send` on it where it holds nothing yet; 9. the distribution decoder takes a safe-mode flag, set in the system domain, which creates no atom and reports a refused atom apart from a malformed term |
| `beam/dist.c` | 10. in the system domain, a message to a peer whose entry's queue is past the manifest's `system_queue` is dropped and counted on the receiver instead of suspending the sender, and any other signal that does not fit ends the connection; 11. an entry counts toward `peer_held` each link and monitor a peer's process holds with a local one and each signal ERTS queues for the peer on behalf of no process, answers a new `LINK` or `MONITOR_P` past it with `system_limit`, and ends the connection when a signal does not fit; 12. `erts_net_message` drops and counts a message whose decoded size, as the funnel measured it, is past its target's `max_request`, the request limit a facet sets on itself |
| `beam/erl_process.c` (exit) | 13. a process's exit clears its export holders, a field of its own record |
| `beam/erl_monitor_link.c` | 14. an alias's deactivation clears its export holders and its registry entry, at the one function that leaves the active state |
| `beam/erl_proc_sig_queue.c`, `beam/erl_gc.c`, `beam/erl_process.h` | 15. a process keeps the bytes of its queued undecoded frames from other domains, added when the drain queues a frame on it and released when `erts_proc_sig_decode_dist` decodes the frame or the process exits; the drain leaves in the lane an authorised frame whose target has reached its queue quota, and takes nothing more from that lane until the count falls below it, and the decode or exit that brings it below schedules that lane's drain again; before a process waits in `receive` while its count is at its quota, it decodes every frame queued on it, its own messages, which from then on count toward its `max_heap_size` alone, so no waiting process holds a lane paused, a `gen_server:call` that skips older messages included; the same bytes count toward the size `max_heap_size` limits, as on-heap message data does |
| `beam/erl_proc_sig_queue.c`, `beam/erl_process.h` | 16. `erts_proc_sig_decode_dist` delivers a message from another domain to a process whose origins flag `erx:origins(true)` set as `{erx_origin, D, Msg}`, with `D` the creation of the entry it arrived on, the peer's domain id |
| `beam/erl_bif_unique.c`, `beam/erl_term.h`, `beam/erl_printf_term.c` | 17. a reference's identity is four words from `erx_ref_permute`; creation, comparison, hashing and text keep all four |
| `beam/erl_node_container_utils.h`, `beam/erl_node_tables.c` | 18. The two channel-number macros print the creation of the node a term carries, the domain id. `internal_channel_no(x)`, a constant 0 in stock ERTS, gives `erts_this_node->creation`. `external_channel_no(x)`, in stock ERTS the index of the node name's atom read through the term's distribution entry, gives `external_node(x)->creation`, read from the term's own `ErlNode`. The pid, port and reference variants that every printer calls (`internal_pid_channel_no`, `external_ref_channel_no` and their kin) are defined on these two, so pids, ports and references print their owner's domain id, and a pid of an ended domain still prints that domain's id after a later domain of its name has connected. `dist_entry_channel_no`, which only the crash dump's node lines and `erts_debug`'s `channel_number` read, stays stock. The parsing BIFs `list_to_pid`, `list_to_port` and `list_to_ref` in `bif.c` resolve the number through `erts_channel_no_to_dist_entry`, which maps the domain's own id to this node's entry, the creation of a connected entry to that entry, and any other number to none, which the BIFs answer with `badarg` |
| `sys/common/erl_mmap.c`, `sys/common/erl_mmap.h` | 19. reserve, commit, decommit and release are kernel calls; `erl_mseg.c` and the allocators sit above them unchanged |
| `beam/erl_time_sup.c` | 20. the correction over operating-system clocks is deleted; the counter and the time page are the clock |
| `beam/beam_load.c` | 21. `prepare_loading` accepts, in the system domain, only bytes in installed storage |
| `beam/erl_nif.c` | 22. `enif_select` is removed; the device and pipe NIFs register events through the event table |
| `beam/jit/`, asmjit's `VirtMem` | 23. executable memory is a JIT object mapped twice; 24. the translator's error paths fail a load instead of ignoring an error |
| `beam/erl_init.c` | 25. the environment and the node name come from the boot information page, and the arguments arrive as the `argv` that `sys/erxos`'s `erx_runtime_main` builds from it for `erl_start` |
| `beam/io.c`, `beam/erl_port_task.c` | 26. `open_port` accepts only erXos's linked-in drivers; spawn, `fd` and forker paths are deleted |
| `beam/dist.c` (registered names) | 27. on a connection to another domain, the sender drops every operation on the peer's registered names: a send to `{Name, Node}` (`REG_SEND`) is dropped and counted, and a monitor by name is answered with a `DOWN` of reason `noproc` locally and never sent, so stock code writes no frame the receiving funnel refuses |
| `lib/kernel/src/net_adm.erl` | 28. `ping/1` toward a node at the machine's host name answers `pong` when the node is `node()` or a member of `nodes()` and `pang` otherwise, and never calls `erlang:disconnect_node/1`, where stock OTP calls `net_kernel` by its registered name and disconnects the node after a failure: a connection between domains exists only by introduction, so a ping of an unconnected domain has nothing to try, and a ping of a connected one needs no call; a ping of another machine's node is stock's |
| `lib_src/pthread/ethread.c`, `include/internal/ethread.h` | 29. `ethr_thr_opts` takes `executor`, and `ethr_thr_create` then calls `erx_pthread_create_executor`; 30. the monotonic clock is `erx_clock_ns`, without `init_get_monotonic_time`'s `uname` check, which reads its buffer whether or not the call succeeded |
| `lib_src/pthread/ethr_event.c`, `include/internal/pthread/ethr_event.h` | 31. events are the futex variant in every build, with `ETHR_FUTEX__` over `erx_umtx_wait` and `erx_umtx_wake` |
| `lib_src/common/erl_misc_utils.c` | 32. `erts_cpu_info_update` counts the boot information page's `cpuset`, in place of `sysconf` and `sched_getaffinity` |
| `beam/erl_time_sup.c` (CPU time) | 33. `erts_runtime_elapsed_both` reads the group's usage from `erx_group_info`; where that is `unsupported`, `statistics(runtime)` fails with `notsup` |
| `beam/erl_crash_dump.c` | 34. the dump goes to the sink of [Crash handling](#crash-handling), with no `open`, `fdopen` or thread suspension |
| `beam/bif.c` | 35. `display_string/2`'s standard-input branch, which feeds a terminal through `TIOCSTI`, is compiled out; its write loop adds to the offset only what a write wrote, retrying an interrupted or blocked write at the same offset, where stock adds the -1 too (`bif.c:4275-4279`), which only a hosted descriptor can answer, and whose reader is outside the runtime; `display/1` formats into a temporary buffer in place of `erts_printf` and goes on as `display_string/2` does; and while another process holds `erx_tty_owner`, both trap to `erx_output:write/2` with the bytes |
| `beam/sys.h`, `beam/erl_drv_thread.c`, `beam/erl_driver.h`, `sys/common/erl_sys_common_misc.c`, `nifs/common/zlib_nif.c`, `include/internal/erl_misc_utils.h`, and the two event files above | 36. `__erxos__`, which every erXos build defines, turns off each block keyed on `__APPLE__` or `__DARWIN__`, so a hosted build compiles what a native build compiles |
| `beam/bif.c`, `lib_src/common/erl_printf.c` | 37. each `write` is `erx_output_write`, under the same signature, and the retry loops around it stay, since natively it never answers blocked ([The console](#the-console-and-standard-io), [What ERTS imports](#what-erts-imports)) |
| `lib/kernel/src/prim_tty.erl` | 38. `isprint/1` is the ASCII printable test and `wcwidth/1` answers `{error, enotsup}`, so terminal-less rendering reaches no NIF; `isatty/1` answers `false` and the terminfo calls answer that no capability exists, which is what `io_ansi` reads when a terminal has no terminfo ([The console](#the-console-and-standard-io)) |
| `lib/kernel/src/standard_error.erl` | 39. `server/0` calls no `prim_tty`: its encoding is `unicode`, and it writes with `erlang:display_string(stderr, Bytes)`, which waits as any process's write does |
| `lib_src/common/ethr_aux.c` | 40. the page size is `getpagesize()`, in place of `sysconf` |
| `lib/kernel/src/kernel.erl` | 41. `kernel_sup` starts `erx_watchdog` right after `on_load`, when a module with a NIF can load; `kernel_safe_sup`'s `init/1` makes the domain's file version counter (`erx_fs_version:init/0`) and adds `erx_ramfs_sup`, the domain's `/tmp`, as its last child ([design-tmp.md](design-tmp.md#starting-and-mounting)); `start_distribution false` leaves out only `net_sup` and `dist_ac`, so `rex`, `global_name_server` and `global_group` start as on a stock node that is not distributed ([Configuration](#configuration)) |
| `beam/bif.c` | 42. while another process holds `erx_tty_owner`, `halt_2` with `{flush, true}` traps to `erx_output:halt/2`, which drains the tty before it halts ([The console](#the-console-and-standard-io)) |
| `lib/kernel/src/logger_simple_h.erl` | 43. `log_internal/2` and `display/1` build each event's text on one line, and print `erx_text:escape_line/1` of it and a CR-LF in one `erlang:display_string/2` ([design-live.md](design-live.md#the-console)) |
| `lib/stdlib/src/shell.erl` | 44. `prompt_width/1` asks no group when `erx_console` calls it, as when `user_drv` does |
| `lib/kernel/src/user_sup.erl` | 45. `get_user/1` answers `{erx_console, start, []}` when the flags hold `-user erx_console`, whatever `-noshell`, `-noinput` and their kin say, since `erx_console` reads those itself and no flag reaches `user_drv`, whose NIF is gone |
| `lib/kernel/src/user_drv.erl` | 46. `whereis_group/0` reads the group from `erx_console`'s process when `user_drv` is not running: the current group when it runs the Erlang shell, and `undefined` while a command shell has the input |
| `beam/break.c` | 47. the break menu prints no clear-screen sequence, so it asks no terminal whether to |
| `lib/stdlib/src/erl_parse.erl` | 48. the generated parser has no `-file` line naming the machine that generated it, since `stdlib` would not rebuild after a source edit with one |
| `emulator/Makefile.in` | 49. `erl_compile_flags.h` holds `N/A` for the flags and `config.h` on erXos's targets, since they name host paths and `erlang:system_info(compile_info)` would serve them from the image |
| `lib/stdlib/src/shell_default.erl` | 50. exports erXos's shortcuts, each a one-line call of its `erx` function ([design-live.md](design-live.md#erlang-in-every-domain)) |
| `beam/bif.tab`, `beam/atom.names`, `emulator/Makefile.in` | 51. `erx_trace_ring:read/3` and `clocks/0` are BIFs (`nifs/erxos/erx_trace_ring_bif.c`), with the atoms `backend`, `kernel`, `present` and `unknown` they match and return ([design-live.md](design-live.md#tracing)) |
| `beam/erl_process.h`, `beam/erl_process.c`, `beam/erl_ptab.h`, `beam/erl_trace.c`, `beam/bif.c`, `beam/beam_bp.c`, `beam/emu/trace_instrs.tab`, `beam/jit/beam_jit_common.cpp`, `beam/atom.names`, `erts/preloaded/src/erlang.erl` | 52. the spawn option `{erx_untraced, true}` keeps a process out of every trace session for its whole life: the new process's trace flags hold `F_ERX_UNTRACED`, and it takes no session's flags at creation, neither new-process tracing nor its parent's `set_on_spawn`, which it does not use up; `erts_sum_all_trace_flags` keeps it as it keeps `sensitive`, so no session's flags take effect, whenever the session opened, and the call-trace breakpoint, meta-trace and return-to paths skip the process as they skip a sensitive one, through one macro, `ERTS_IS_P_TRACE_HIDDEN`; `process_flag(sensitive, _)` leaves it set. Unlike `sensitive` it hides nothing from `process_info` or crash dumps and leaves `save_calls` and `seq_trace`, which is no session, as they are. `erx_trace` spawns its own processes so ([design-live.md](design-live.md#tracing)) |

Fifty-two edits outside `sys/erxos`, in fifty-five named files outside
the JIT's directory, in the JIT's directory and in asmjit's `VirtMem`;
the interpreter image is built without
the last two. Nothing in `erl_ptab.c`: processes take their pids as stock
ERTS allocates them. Nothing in the node table's keys, in the decoder's
test for the own node, in channel creation or in `do_send`: every domain
is a node of its own name, so a pid of another domain belongs to another
node exactly as on a stock node, and those paths hold as stock ERTS has
them. A node's identity costs one edit at two sites (18), the one that
prints a node's number in a pid's text and the one that parses it back.

### What ERTS needs and what the adapter adds

ERTS needs only part of the adapter to run at all: the sys layer over
`liberx`, threads, memory, time, the debug log and files, and scheduler
sleep over `erx_park`. Every cooperation feature, urgency, deferral and
status words, sits behind its group flag, so ERTS also runs with all of
them off, the baseline each is measured against; [plan.md](plan.md) orders
the work. ERTS's Erlang-visible behaviour is checked against stock OTP
29.1.2 on the host throughout
([Verification and testing](#verification-and-testing)).

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **R1.** No kernel event re-enters ERTS | the kernel never transfers control to a runtime ([design-scheduler.md](design-scheduler.md#invariants), S1); the adapter reads events only in `erts_schedule` and before parking, where the scheduler holds no lock | an adapter hook called from a signal-like path, or event handling inside a critical section | a source check that the adapter's event functions are called only from `erts_schedule` and the park path; the deterministic-mode test of [design-scheduler.md](design-scheduler.md#invariants) S1 run under ERTS |
| **R2.** A scheduler never misses work it was woken for | the adapter reads the group and slot epochs before it checks its run queue, the ready count and its aux work, and parks with those epochs; every enqueue that targets a parked scheduler calls `erx_executor_wake`; ERTS's sleep flags keep their compare-and-swap protocol | a park with epochs read after the checks; an enqueue that skips the wake | the park protocol's exhaustive model with ERTS's sleep flags added; a storm test of cross-scheduler wakes and doorbells, every message delivered |
| **R3.** No executor waits outside its domain | ERTS's normal and dirty CPU schedulers are created as executors, so the kernel refuses their blocking calls (S3); the adapter's own waits are `erx_park` and umtx waits on private memory; the gate worker, which waits on the domain's fault gate, is a worker; no lock an executor takes is held across a worker's blocking call in ERTS's or the adapter's code, so a umtx wait never waits on another domain | a scheduler created as a worker; an adapter path that waits on an IRQ object or an IPC gate; a lock held across a blocking call, which a NIF can still do, as it can stall a scheduler on a host, bounded by that call's deadline | the thread-creation code checks the class it passes; E-S10 counts refusals over OTP's suites |
| **R4.** Code is executed only from memory mapped executable, never writable in the same mapping, and only after its runtime made it coherent | BeamAsm writes through the writable mapping of a JIT object and publishes through ERTS's code barrier, which makes every scheduler execute an instruction barrier before the code is reachable; the kernel refuses writable and executable together (K8) | publishing before the barrier completes | ERTS's code-loading tests under BeamAsm on four CPUs, with reloads in a loop |
| **R5.** A domain's runtime spends only its own budget and grant | every page it uses is committed in its own space and charged to its budget; every thread is in its own group or a child of it | none within the runtime: both are kernel-enforced | the kernel's tests; a test domain that exhausts its budget and its grant |
| **R6.** A frame reaches ERTS's distribution code only after the funnel accepted it against the export table on the lane it arrived on | the lane driver's drain, which one executor at a time runs under the connection's drain word, is the only caller of `erts_net_message`, and it calls it only with a frame the funnel returned as accepted; the funnel is the only reader of a lane's ring; the peer's identity is the lane's, never a field of the frame | a second caller of `erts_net_message`; a read of a ring outside the funnel; a frame handed on after a refusal | source checks for both chokepoints, each with a seeded violation; the hostile-peer corpus of [design-domains.md](design-domains.md#the-funnel) replayed into a lane |
| **R7.** The export table is written at exactly three sites, each an act of the name's owner, and a holder ends with its process or alias | the holders are a field of the name's own record; the writes are the encoder's (edit 8), which adds a peer with `send` alone and only where it holds nothing yet, the spawn-into path's, which gives the spawner every right on its child, and `erx:export/3`'s, which a process of the owning domain calls to set a peer's rights on one of its own names exactly; the only clears are at process exit (edit 13) and alias deactivation (edit 14), which are the one exit path and the one deactivation function ERTS has, and at a connection's end | a fourth writer; an encode that widens a holder's rights; a write on a name the domain does not own; an exit path that skips the clear | a source check that only the three functions write holders, with a seeded fourth; a test that a pid encoded for a peer gives it `send` alone, and that one exported narrowly with `erx:export/3` and encoded again keeps the narrow rights; a test that a frame to an exited pid is answered as to a dead process |
| **R8.** No device address the runtime gives a device names memory the domain does not hold, and none is reused while the device may still hold it | the device NIF builds every address from a queue's memory object and an offset, checked against the object, and alone writes one: a register the SVD source marks `ownedByNif` refuses `write/3` and `write_field/4`, and `post/4` takes only bytes, lengths and which segments the device writes, never an address, a descriptor field or a flag. A chain's buffer is its head descriptor's, so no two chains in flight share one. Pools and queues are state of the device's record in the NIF for the boot, never of a process, so a driver's crash frees nothing; a posted buffer returns to its pool only through the device's completion or at `negotiate/2`, and after a driver's exit the NIF posts nothing on the device until `negotiate/2`; an unconfined device's memory is the system domain's for the boot and never freed, and a confined device's is freed only after the kernel unbinds it from the device's window | a raw address or offset accepted from Erlang; an address register or an addressing flag written from Erlang; a pool or queue freed with the process that made it; a posted buffer returned to its pool before its completion or a reset; a post after a driver's exit and before `negotiate/2` | the NIF's property tests over post, complete, crash and reset sequences on the hosted backend; a seeded return of a posted buffer before its completion, a seeded post before `negotiate/2`, a seeded write of an owned register and a seeded pool owned by a process each fail the test |
| **R9.** No binary aliases memory a device can write | `complete/2` copies each buffer's returned bytes into a fresh binary and returns the buffer to its pool, and the NIF makes no binary over a pool | a resource binary over a pool buffer | a model device on the hosted backend that rewrites a buffer after its completion, after which the binary `complete/2` returned is unchanged |
| **R10.** The system domain holds no generated machine code, no JIT object and no C++ | it runs the interpreter image, built without BeamAsm, asmjit, libc++ and libc++abi, whose manifest carries no `ERX_IMAGE_JIT`, so its space allows no JIT object and the kernel refuses it one (K8; [design-kernel.md](design-kernel.md#image-manifests)) | a symbol of BeamAsm, asmjit or libc++ linked into the interpreter image; a root image marked `ERX_IMAGE_JIT` | the build check on the interpreter image's symbols, which a seeded asmjit object linked into it fails; the packer's refusal of a root image marked for JIT, which a seeded manifest exercises; a boot test in which a NIF of the system domain asks for a JIT object and gets the kernel's refusal |
| **R11.** No call stub hands the kernel an address to read or write | every stub is generated from the ABI file, whose argument kinds are register values, UTCB fields and memory windows (a memory object's capability with an offset and a length), and the generator refuses a pointer parameter; only `liberx` issues kernel calls | a hand-written stub; an argument kind the kernel reads through | the generator's test, in which a seeded pointer argument in a test ABI file fails generation; the chokepoint check that only `liberx`'s generated stubs trap, which a seeded hand-written trap fails |

## Data model

**The boot information page.** A domain's runtime starts with one
read-only page that the domain library writes when it creates the domain,
and that the root-task entry writes for the system domain
([design-system.md](design-system.md#creating-a-domain),
[The root-task entry](#the-root-task-entry)); its layout is in the ABI
file:

```c
typedef struct erx_boot_info {
	uint32_t	version;		/* 1 */
	uint32_t	abi_version;		/* ERX_ABI_VERSION */
	uint32_t	domain_id;		/* its node's creation; never reused */
	uint32_t	flags;			/* ERX_BOOT_DET, ERX_BOOT_INSTALLED_ONLY,
						 * ERX_BOOT_ROOT */
	uint32_t	pack_flags;		/* checked boot-image build flags */
	uint32_t	reserved;		/* zero; keeps capability alignment */
	erx_cap_t	budget;			/* the domain's budget: ALLOC, and with
						 * SPACES also SPACES, CARVE, DUP, GIVE */
	erx_cap_t	space;			/* its own space: THREADS, SPACES */
	erx_cap_t	group;			/* the domain's group: ATTACH, SIGNAL, and
						 * CONFIGURE on its children */
	erx_cap_t	group_ctl, group_stat;	/* its shared areas */
	erx_cap_t	time_page;
	erx_cap_t	release;		/* the slice of its release's files */
	uint64_t	release_addr;		/* where the slice is mapped, read-only */
	uint64_t	seal_addr;		/* the release the boot image marks
						 * with ERX_ENTRY_SEAL: where the
						 * sealing page is mapped, read-only;
						 * otherwise, or with no device secret,
						 * zero */
	erx_cap_t	crash_area;		/* memory for a crash dump, or zero
						 * for a domain without one */
	struct {
		erx_cap_t	side;			/* its own side: READ, WRITE,
							 * MAP */
		erx_cap_t	peer_side;		/* the system domain's side:
							 * READ, MAP */
		erx_cap_t	peer_bell;		/* the system domain's bell:
							 * TRIGGER */
		uint32_t	label;			/* its own bell's label,
							 * bound to its group */
		uint32_t	peer;			/* the system domain's id, 4 */
		uint32_t	peer_node_off, peer_node_len;
							/* the system domain's node
							 * name, in the page */
		uint32_t	out_size;		/* data area of the lane it
							 * writes */
		uint32_t	in_size;		/* data area of the lane it
							 * reads, the reserve
							 * included */
	} system_connection;			/* its connection to the system domain */
	uint64_t	cpuset;			/* CPUs its group may use */
	uint32_t	capacity_mcpu;		/* initial capacity */
	uint32_t	node_off, node_len;	/* its node name, <id>@<host>, in the page */
	uint32_t	args_off, args_len;	/* NUL-separated arguments, in the page */
	uint32_t	env_off, env_len;	/* NUL-separated environment, in the page;
						 * node_len + peer_node_len +
						 * args_len + env_len <=
						 * ERX_BOOT_STRINGS_MAX (2,048) */
	uint64_t	hwcap, hwcap2;		/* CPU features, as Linux's AT_HWCAP words */
	erx_runtime_limits_t limits;	/* complete validated startup limits */
} erx_boot_info_t;
```

The fixed prefix is 272 bytes. The kernel supplies `pack_flags` from the
validated boot-image header; the root entry preserves that value and
compares its development bit with the system manifest's development bit
before applying any configuration. Either mismatch is an invalid boot.
The build selects one build kind for both artifacts, and conflicting
source flags fail packing. The domain library copies the checked value
into each child boot page; a runtime does not infer build kind from its
own manifest text or compile-time defaults.

`erx_runtime_limits_t` is the ABI's fixed 64-byte startup projection:
`max_frame`, `max_message_heap`, `funnel_depth`, `exports`, `tmp`,
`overlay`, `atoms`, `foreign_atoms`, `processes`, `peer_held` and
`peer_held_total`, with widths and offsets defined in
[Runtime-limit projection](design-abi.md#runtime-limit-projection).
It carries values only for this runtime, with no principal table, facet
scope or reference into the system manifest. The domain library copies
it from the validated creation plan; the root entry constructs the same
record from the system's checked manifest fields.

Startup validates and installs the complete record before initializing
the node's atom/process bounds, accepting a peer, enabling a lane drain
or decoding an untrusted frame. The funnel receives one immutable limit
value, so a missing field cannot be replaced by a library default and no
caller must install several limits in a particular order. Command-line
options can lower the resulting runtime settings where their documented
interface permits it, but cannot raise them. Invalid or unsupported
records end startup with a diagnostic; they do not start a partly bounded
runtime. The system runtime follows this same path before serving any
domain, including when its peer set is initially empty.

Every capability in it is already in the domain's table; the page only tells
the runtime where. The node name is the domain service's choice, written
by the domain library, never an argument the specification sets
([Connections in ERTS](#connections-in-erts)), and the page names the
system connection's peer by its node name and id as well, as
`connection_up` names every later peer. The arguments name, as text, the pid of the
system domain's process that admits the domain, which that process
exported to the domain before it started
([Connections in ERTS](#connections-in-erts)).
With `ERX_BOOT_ROOT`, the page continues at `ERX_BOOT_INFO_SIZE`, offset 272,
with the **root extension**, `erx_boot_root_extension_t`, which the ABI
generator derives from the ABI file's `cap` lines, so that nothing is copied by
hand: one capability value for each root slot, the value of slot N at offset
8 x (N - 1), 88 bytes in all, and `ERX_CAP_NULL` in an optional slot the boot
left empty ([The root-task entry](#the-root-task-entry)). The strings the
page's offsets name lie past it. The entry's close of the device-secret page
leaves that field's value stale, so it names nothing from then on (K1).
Every later connection,
every device and every grant reaches the runtime as a message from the
system domain over the system connection, naming slots the domain library
installed in the domain's table.

**The adapter's per-executor record**, beside ERTS's per-scheduler data:

```c
struct erx_rt_exec {
	uint8_t			slot;		/* executor slot in the group */
	erx_exec_ctl_t		*ctl;		/* this slot's control line */
	const erx_exec_stat_t	*stat;		/* this slot's status line */
	erx_urgency_t		urgency;	/* the urgency last published */
	uint32_t		defer;		/* mirror of ctl->defer, owned by this thread */
};
```

An executor is the only writer of its control line, so the adapter stores
into it without atomic read-modify-write, and only when a value changes.

**The connection table** is `erx_connections`'s, an Erlang process of
`kernel` in every domain: for each peer domain, its node name and id, the
lane port, the distribution entry it controls, and the slots of the
connection's objects.
It is Erlang state; the hot path never consults it, since a frame's entry
is found by ERTS's node table and its port by the event table.

**The export table** is not a structure of its own: a name's **holders**,
the peers given the name and the rights each holds, are an `erx_exports_t`
field of the name's own record, a pid's on its process, an alias's on the
alias's local state and the domain's name on the runtime's record of the
domain, in the layout and with the rights the domains design defines
([design-domains.md](design-domains.md#exports)): `send` covers messages,
alias sends and monitors; `link` covers links; `exit` covers `exit/2`,
`kill` included, and `group_leader/2`; `spawn` is a right on the domain
itself; `introduce`, which only an explicit export writes, means something
only on a domain pid, where the domain service reads it before it
introduces that pid's domain. The funnel reaches a target's holders
through the record ERTS already looks up to deliver to it, and the field
is freed with that record, so a process's exit or an alias's deactivation
clears its holders at the transition that ends it, and no holder has to be
found and removed. The table holds at most `exports` entries, one per peer
and name.

**The event table** is C in `sys/erxos`: a label, the 32-bit value the
kernel returns with each IRQ object taken from the ready list, maps to a
**sink**: a connection, which its dispatching executor drains, a port,
which gets an input task, or a process with a term, which gets a message.
The ABI splits every group's label space in two at `ERX_LABEL_SPLIT`
(2^31). The system domain assigns the labels below it, from a per-domain
counter it keeps, for the doorbells it binds into the domain's group
(connection lanes), and tells the domain each in `connection_up`. The
labels at or above it are the runtime's own, allocated by the adapter for
the doorbells it binds itself (channels, pipes, devices). A label is free
again once the object bound with it is unbound, and every sink treats a
delivery as a hint to look, never as an event in itself
([design-domains.md](design-domains.md#connections)). An entry is removed
when its connection closes, its port closes or its process exits, which
the sink's owner monitors. The connections' bells, the program ports,
the device NIF's interrupts and the pipe NIF's ends are all entries of
it, so the runtime has one readiness mechanism and no scan of its
sources ([The event table](#the-event-table)).

**The crash area** is a memory object the domain library creates for each
domain and maps writable into it, charged to the domain's **outer
budget**, which the domain library carves beside the domain's own: the own
budget pays for what the domain alone maps and is destroyed at once when
the domain ends, and the outer budget pays for what another domain also
maps: through a child budget for each connection, the lanes the domain
reads, both lanes of its connection to the system domain included, and
directly the crash area. Only the system domain destroys them: a
connection's child once both parties have let go of it, and the outer
budget once no child remains and the crash record is read
([design-system.md](design-system.md#ending-a-domain)). So the area
survives the domain's end, and the domain service reads it afterwards. It
starts with a header whose layout is in the ABI file:

```c
typedef struct erx_crash_header {
	uint32_t	magic;		/* ERX_CRASH_MAGIC once a dump is complete */
	uint32_t	version;	/* 1 */
	uint32_t	flags;		/* ERX_CRASH_TRUNCATED: the dump did not fit */
	uint32_t	pad;		/* zero */
	uint64_t	length;		/* bytes of dump text stored after the header */
	char		slogan[232];	/* ERTS's one-line reason, NUL-terminated */
} erx_crash_header_t;		/* 256 bytes */
```

The domain writes the text first and the magic last, with a release store.
`length` counts only the bytes stored, so a dump that fills the area
exactly is complete, and a dump cut at the area's end says so with
`ERX_CRASH_TRUNCATED`, never with its length. Whoever reads it treats it
as untrusted input: the magic and version must match, `flags` may hold no
other bit and `pad` must be zero, `length` must fit in the area after the
header, the slogan must hold a NUL within its 232 bytes, and every byte
reaches a terminal or the log only through that sink's escaping function.

## Algorithms and behavior

### Starting a runtime

The domain library maps the domain's runtime image, the BeamAsm image or
the interpreter image as its specification chooses, a file of the boot
image that every domain may map, and the domain's release slice, creates
the domain's first thread as a worker with the boot information page's
address as its argument, and starts it
([design-system.md](design-system.md#creating-a-domain)). That thread is
ERTS's main thread: it maps the group's shared areas, the system connection's
pages and the time page, creates the domain's fault gate for the
sub-spaces it will create and the gate worker that waits on it, reads its
arguments, and runs ERTS's start-up, which creates the schedulers through
the adapter. Processes take their pids as stock ERTS allocates them, on
the node the page names, `<id>@<host>` with the domain id as its
creation, so every pid names its domain
([design-domains.md](design-domains.md#domain-ids-pids-and-references)).
The number of normal schedulers is the CPU count of the domain's cpuset,
at most 32, and the number of dirty CPU schedulers equals it, so the two
pools fit a group's 64 executor slots. The number online is the capacity
rounded up, so ERTS's `+S` is computed from the grant, not from the
hardware; a `+S` argument can lower both numbers but not raise them. The
main thread then becomes ERTS's system thread as on a host, or exits.
`kernel` starts `net_kernel` under the page's node name with `erx_dist`
as its carrier, and `erx_connections`, the carrier's acceptor, opens the
system connection's lane port and connects its distribution entry before
any application runs, so the first frame a domain sends, its report to
the process its arguments name, travels as every later one does.

### Scheduling

ERTS's scheduler is the second level, kept whole except at these points:

* **Executors.** Each normal scheduler and each dirty CPU scheduler is
  created with `erx_pthread_create_executor` as an executor of the domain's group.
  Normal schedulers are pinned with `erx_thread_set_affinity` to the CPUs
  of the group's **run**, which the capacity word names
  ([design-scheduler.md](design-scheduler.md#status-words-and-capacity)),
  online scheduler `i` on the `i`-th CPU of the run, as `+sbt` binding
  does on a host. Dirty CPU schedulers are left unpinned within the run;
  with `ERX_GROUP_PLACE` the kernel places each on an idle CPU of the run
  at its wake, so a dirty NIF that starts while one idles does not wait
  behind a busy normal scheduler, and without it each stays on its home
  CPU. The domain's normal and dirty CPU work thus stay on its run,
  where the policy places no other domain's share. Dirty I/O schedulers,
  ERTS's helper threads (the aux thread and the system-message
  dispatcher) and the gate worker are workers in the same group, unpinned.
* **Sleep.** `scheduler_wait` keeps ERTS's flag protocol and its aux-work
  loop. Where it called `erts_tse_twait` or `erts_check_io`, it reads the
  two epochs, takes the group's ready list when the status area's `ready`
  is not zero and dispatches it through the event table, runs any work
  that produced, and otherwise calls `erx_park` with the epochs and the
  timer wheel's next expiry as the deadline
  ([design-scheduler.md](design-scheduler.md#park-and-wake)). Thread progress's
  `prepare_wait` and `finalize_wait` bracket the park exactly as they
  bracket ERTS's sleep, so a parked executor counts as asleep and the
  deferred instruction barrier of code loading is issued on wake. The
  executor reads the epochs before it sets `ERTS_SSI_FLG_PARK_SLEEPING`, and a
  waker clears the flags before it calls `erx_executor_wake`, so a wake is
  seen in the flags or in an epoch. A dirty I/O scheduler is a worker and keeps
  its thread event, as every scheduler does in the two waits that are not for
  work, a suspended scheduler's and a thread blocking thread progress: an event
  is a umtx wait, which an executor may make, and each bit of the flags a waker
  cleared names a primitive to wake, more than one when a returned park is
  followed by a wait for a block of thread progress. No scheduler waits on a
  poll set.
* **Wake.** `wake_scheduler` and the paths that notify a scheduler after an
  enqueue call `erx_executor_wake` with the target's slot when the target's
  sleep flags show it parked, instead of setting its thread event or
  writing the poll set's pipe.
* **Spinning.** ERTS spins 10,000 iterations before an event sleep. A spin
  burns the group's quota, so the adapter's default is ERTS's
  `+sbwt none`, with `very_short` selectable; E-S1 measures both.
* **The safe point.** At each entry to `erts_schedule`, between processes,
  the adapter does, in this order: if the status area's `ready` is not
  zero, take the group's ready list and dispatch each label through the
  event table; if the capacity sequence changed, adjust
  `schedulers_online` and `dirty_cpu_schedulers_online` through ERTS's own
  machinery for changing them, which suspends and resumes schedulers, and
  pin the executors to the run the word names; publish this executor's
  urgency if it changed. The same runs when the scheduler has no work,
  before it parks and as it leaves the sleep step, so no executor leaves
  that step with a label pending. A dirty CPU scheduler dispatches in its
  sleep step alone: a fire while its job runs wakes another executor.
* **Urgency.** With `ERX_GROUP_HINTS`, an executor publishes the urgency of
  the most urgent work it holds: the higher of the running process's
  priority and the highest priority queued on its run queue, mapped into
  the group's band (`low` and `normal` to the group's base, `high` to base
  plus one, `max` to the ceiling). It republishes when either changes,
  which ERTS knows at enqueue and at schedule-in.
* **Deferral.** With `ERX_GROUP_DEFER`, the adapter raises the control
  line's `defer` count around the scheduler's run-queue locks, process
  locks taken by the scheduler, and the allocator's carrier locks, and when
  the count returns to zero with `yield_req` set, calls `erx_yield`
  ([design-scheduler.md](design-scheduler.md#deferred-preemption)). E-S3
  measures how long each holds `defer` raised.
* **Status words.** With `ERX_GROUP_STATUS`, `try_steal_task` tries first
  the run queues of executors whose status line reads `READY` (preempted),
  whose queued processes would otherwise wait for their executor's next
  turn on a CPU.
* **Job tags.** Every process carries a job tag, which it takes from the
  process that spawns it, at its creation, and never changes; the
  session's job table marks a tag stopped or ending
  ([design-shell.md](design-shell.md#job-control)). The one place where a
  scheduler picks the next process to run reads the picked process's
  tag: a process of a stopped job goes onto its tag's set-aside list,
  linked through the process structure, instead of running, and a
  process of an ending job exits there with the job's reason. Clearing a
  stop puts the set-aside processes back on their run queues. A process
  running when its tag is marked runs at most to the end of its slice,
  and ending a job also wakes each of its members found among the
  runtime's processes, while each spawn checks its tag after the new
  process exists, so no process escapes its job's stop or end and no
  list of members is kept. A pick costs one more load and compare.

These retain ERTS's process state protocol, priorities' meaning, reduction
counting and balancing. With all group flags off, the adapter does only
the first five, besides job tags, which act only on the processes of a
stopped or ending job, and ERTS behaves as it does on a host with bound
schedulers and no busy waiting.

### The event table

The group's ready list is the runtime's one source of readiness: every IRQ
object the domain binds to its group, or that the system domain bound
there for it, lands on the list when it fires, and `erx_group_take_ready`
returns their labels, each once
([design-kernel.md](design-kernel.md#messages-gates-and-irq-objects)). The
adapter dispatches each label through the event table:

* **A connection sink** is drained by the dispatching executor itself,
  when it takes the connection's drain word, as [Connections in
  ERTS](#connections-in-erts) describes: a connection's bell says only
  "look at this connection", and one executor at a time answers it.
* **A port sink** gets an input task scheduled on its port, ERTS's own
  `ERTS_PORT_TASK_INPUT`, which a scheduler runs under the port's lock at
  its next turn. The program driver's ports are port sinks: the channel's
  doorbell and the record the gate worker deposits for a sub-space arrive
  this way, so each port's work is serialised by ERTS as every port's is.
* **A process sink** gets a message, the term registered with the entry,
  sent to the process with `enif_send`, with no caller, from the dispatching
  executor. The device NIF's interrupts (`{erx_irq, Device, Line}`) and
  the pipe NIF's ends are process sinks.

A label whose entry is gone, because its port closed or its process
exited after the object fired, is dropped, as the contract allows
([design-scheduler.md](design-scheduler.md#the-runtime-contract)). The
table is read on every dispatch and written when a sink registers or
goes, under a read-write lock; a dispatch allocates one short-lived
environment per delivery to a process sink, on top of the message itself.

**Which executor dispatches.** A trigger wakes whichever executor the
kernel chooses, and dirty CPU schedulers are executors, so a dirty CPU
scheduler dispatches too. A delivery therefore stays on what ERTS allows on
a thread thread progress does not manage: `enif_send` with no caller takes
its non-scheduler path, looking the process up with `erts_pid2proc_opt`
and a reference rather than the scheduler's raw lookup, and
`erts_port_task_schedule` opens with `erts_thr_progress_unmanaged_delay`
and allocates the task from a thread-preferred pool that falls back to
`erts_alloc`. A normal scheduler makes itself active for thread progress
before it dispatches from its sleep step. Dirty I/O schedulers have no
executor slot and never dispatch.

**A delivery is a hint.** Every sink treats a delivery as a reason to
look at its source, never as an event in itself: a connection's executor
reads both lanes' positions, a program port's input task reads its
channel's ring and the records the gate worker deposited, a pipe end
reads its ring, and a driver given `{erx_irq, Device, Line}` reads its
device's status registers. What the sink acts on is what it finds there.
So the adapter reuses one of its labels once it has unbound the object
bound with it, and the system domain reuses its own likewise
([design-domains.md](design-domains.md#connections)): a delivery that
reaches a later sink of the same label costs that sink one look, which
finds nothing or what its next look would have found, and neither half
of the label space runs out.

**The gate worker** is the one thread of the domain that waits in IPC: a
worker in an open wait on the domain's fault gate, which every space the
domain creates names at creation, so every exit and fault record of a
sub-space arrives there; a domain's own records go to the domain
library's fault thread in the system domain
([design-kernel.md](design-kernel.md#creating-spaces),
[design-system.md](design-system.md#ending-a-domain)). For each record
it finds the space's sink in the event table, a program port, deposits
the record and
dispatches the sink as the ready list would: it triggers the port's own
IRQ object, which the port created with every right. It parses nothing:
a record is a fixed layout the kernel wrote, copied once and checked by
`liberx`.

### Connections in ERTS

A connection between this domain and a peer is two sides, each one memory
object that one party writes, holding the ring of the lane it writes and
the reader page of the lane it reads, and two bells, created by the
system domain when it introduces the pair
([design-domains.md](design-domains.md#connections)). In ERTS a
connection is a **distribution entry** whose controller is a **lane
port**, and its inbound lane is drained under the connection's **drain
word**. Everything else is stock distribution.

**Identity.** Every domain is an Erlang node named `<id>@<host>`: its
identifier ([design-system.md](design-system.md#identifiers)) at the
machine's host name, such as `web@erxos` or `system@erxos`, with its
domain id as its creation, both from the boot information page. ERTS's
node table, its distribution entries and the decoder's test for the own
node are stock: an entry is keyed by its peer's node name, a pid's node
is its domain's name and
creation, and a pid of this domain's own name is local exactly as on a
stock node. `node()` returns the domain's name,
`erlang:system_info(creation)` its domain id, and `nodes()` the domains
it is connected to, each a visible connection. Domain ids are never
reused within a boot, so a creation names one domain of the machine, and
they start at 4, the system domain's id, because stock
`erlang:setnode/2` raises a creation below 4 to 4
([design-domains.md](design-domains.md#domain-ids-pids-and-references)).

**A pid's text** is the one documented difference. Stock ERTS prints a
pid as `<C.N.S>`, with `C` the node's channel number: 0 for the own node,
from `internal_channel_no`, and for another the index of the node name's
atom, from `external_channel_no` through the node's distribution entry.
erXos prints the creation of the node the term carries there (edit 18),
so a pid prints as `<D.N.S>` with its owner's domain id, local pids
included, a port as `#Port<D.N>` and a reference as `#Ref<D.a.b.c.d>`.
The number is read from the term's own node, not from the distribution
entry, so a pid of an ended domain prints that domain's id even after a
later domain of the same name has connected and the entry carries the
later creation. The parsing BIFs, `list_to_pid`, `list_to_port` and
`list_to_ref`, resolve `D` through `erts_channel_no_to_dist_entry`: `D`
names this node when it is the domain's own id and otherwise the
connected entry whose creation is `D`, and a `D` that no connected
domain has is `badarg`, as an unknown channel number is in stock ERTS. A
domain exposed to other machines reaches them
over the network service under the same name; a node of another machine
prints with its own creation, which can equal a domain id of this
machine, and `list_to_pid` then resolves the number to this machine's
domain ([Risks and open questions](#risks-and-open-questions)).

**Opening.** `net_kernel` runs in every domain, started by `kernel`
under the domain's node name with `erx_dist` as its distribution
protocol, OTP's documented interface for an alternative carrier.
`erx_dist:listen/1` returns the domain id as the node's creation and
registers with no port mapper, and `erx_dist:select/1` claims every node
name at this machine's host name; names of other machines belong to the
network service's carrier. `erx_connections`, the connection agent, is
the carrier's acceptor. When the system domain introduces this domain to
a peer, the domain service tells the agent, in `connection_up` over the
system connection: the peer's id and node name, the slots of the
domain's own side, the peer's side and the peer's bell, the label the
system domain bound this domain's bell with, and the two data areas'
sizes
([design-domains.md](design-domains.md#messages-between-the-domain-service-and-a-runtime)).
The agent takes it from the system connection alone, maps the two sides,
opens a port on the lane driver with those values, registers the label
as the connection's sink in the event table, and hands the port to
`net_kernel` as an accepted connection. `erx_dist:accept_connection/5`
runs no handshake: the peer's name, creation and flags are the
introduction's, and no cookie is asked, since the lane itself names the
peer. It connects a distribution entry for the peer's node name, with
the port as its controller, through `erlang:setnode/3` with the fixed
flag set and the peer's id as creation, as `dist_util` does at the end
of a handshake, and reports the node up to `net_kernel` as `dist_util`
reports it; the agent then answers `connection_mapped`. The flag set is
the frames' ([design-domains.md](design-domains.md#the-funnel)): OTP 29's
mandatory flags plus `PUBLISHED`, `DIST_MONITOR`, `DIST_MONITOR_NAME`,
`EXIT_PAYLOAD`, `SEND_SENDER`, `SPAWN`, `ALIAS`, `UNICODE_IO` and
`NATIVE_RECORDS`, and no atom cache and no fragments. `PUBLISHED` makes
the connection visible, so `nodes()` lists it; ERTS sends a process
monitor, its removal and its `DOWN` across an entry only when both
`DIST_MONITOR` and `DIST_MONITOR_NAME` are set, so both are. Operations
on the peer's registered names never cross: the sender drops them
(edit 27), and the receiving funnel refuses such a frame as malformed.
The system connection is opened the same
way at start, from the boot information page. A send, link, monitor or
spawn toward a domain this domain has no connection with is one toward a
node that is not connected: ERTS asks `net_kernel` to connect,
`erx_dist:setup/5` fails at once, since only the system domain makes
connections, and ERTS answers `noconnection`, drops the message, or
fails the spawn, exactly as for a node it cannot reach.

**No ticks.** A connection between domains has no tick supervision. The
carrier reports no ticks: the connection's owner process, which
`erx_dist` starts and `net_kernel` sends its `tick` and `aux_tick` to,
ignores both, writes no tick into a lane and never ends a connection for
silence, so `net_kernel`'s tick timer and `net_ticktime` do not apply to
these connections. A silent peer is only silent, and a domain starved of
CPU must not be disconnected: losing its connection to the system domain
ends it. A peer's end reaches the domain as the system domain's
`connection_down`, which needs nothing from the peer
([design-domains.md](design-domains.md#introduction-and-connection-down)).

**Sending.** `erts_dsig_send` encodes the frame onto the entry's queue as
stock ERTS does; the entry's output goes to the lane port's `outputv`,
which writes the frame into the outbound lane's ring as one record, a
long one in parts as room returns, and, when its store of the write
position crosses the position the peer published in its reader page,
rings the peer's bell ([design-domains.md](design-domains.md#the-peer)).
The ring is single-producer by construction: ERTS runs a port's
callbacks under the port's lock. When the ring lacks room, the driver
publishes the position it waits for, leaves the rest at the head of the
entry's queue and pauses the port's output; the peer, once its read
position crosses that position, rings this domain's bell, and the
executor that answers the bell resumes the output. Frames for a full
lane therefore wait in the entry's queue, in this domain's memory. The
entry is **busy** once that queue passes ERTS's busy limit, 1 MiB
(`ERTS_DE_BUSY_LIMIT`), and ERTS suspends a process that sends on a busy
entry, as it suspends senders to any busy distribution connection;
`erlang:send/3` with `nosuspend` returns `nosuspend`, and processes
sending to other domains carry on. So a `gen_server:call` to a stalled
peer blocks the caller and nobody else. The system domain suspends no
sender: a message past the manifest's `system_queue` is dropped and
counted on the receiver, and any other signal that does not fit ends the
connection (edit 10). A frame larger than `ERX_FRAME_MAX`, which no lane carries,
takes ERTS's own too-large path, `ERTS_DSIG_SEND_TOO_LRG`: the sender
gets `system_limit`.

**Receiving.** A lane has one consumer, so one executor at a time drains
it: the one that takes the connection's drain word with a
compare-and-swap, when the ready list names the connection's label at a
safe point or before it parks; an executor that finds the word taken
leaves the drain to its holder
([design-domains.md](design-domains.md#the-peer)). The holder runs the
funnel's steps up to its allowance, `-erx lane_batch` frames, then stores
the read position, clears the word, executes a full fence and reads the
peer's write position once more; if it moved, another drain is due, which
the executor leaves for its next safe point rather than loop into, and at
each safe point an executor also looks at connections whose last drain
reached its allowance. When its store of the read position crosses the
position the producer published in the ring's header, it rings the
peer's bell. Each step copies one record out of the ring, through
`liberx`'s `erx_lane_take`, the only reader of a ring, into a private
buffer that grows as the record's bytes arrive and is never allocated
whole on its header's word, so a record past the domain's `max_frame` is
dropped as it passes and never held; in the system domain `max_frame` is
the largest `max_request` a grant may name, so what a domain can make it
buffer is one request ([design-domains.md](design-domains.md#flow-control)).
The step then runs the funnel on the copy, with the lane's peer as the
sender and the export table as the authority
([design-domains.md](design-domains.md#the-funnel)), and hands an
accepted frame to `erts_net_message` on the connection's entry, which
keeps order per connection, or queues the funnel's own answer on that
same entry. The message in an accepted frame stays encoded until its
receiver takes it, which is ERTS's lazy distribution decode; in the
system domain that decode runs in safe mode (edit 9), so the system
domain never learns an atom from another domain (D5), and a reason
refused only by the atom policy arrives as `{erx_foreign_reason, Bin}`,
so no exit is lost. The receiver's queued undecoded frames count toward
its **queue quota** (edit 15): when an authorised frame's target has
reached it, the drain leaves that frame in the lane and takes nothing
more from that lane until the target's decodes bring the count below the
quota ([design-domains.md](design-domains.md#flow-control)). In the
system domain a process's quota is its facet's or the manifest's
`system_queue`, so a facet process that never reads holds at most its
quota and one frame, and its grantee's lane, which then fills, holds the
rest in the grantee's own runtime; elsewhere it is `-erx queue_quota`,
none by default, as in stock OTP. The same bytes count toward the
receiver's `max_heap_size`, which is what the process sees, and a
process about to wait in `receive` at its quota first decodes what is
queued on it, so no wait sits behind a pause of its own making.

**Authority.** The funnel's verdict for an operation that needs a right
the peer does not hold on the target is **unheld**. The driver then does
what stock ERTS does for the same operation on a process that does not
exist, through the entry's own queue, so the answer is in order with what
the target sent before (D9): a message, alias send, exit signal or
group-leader change is dropped and counted; a link gets an exit of reason
`noproc` and a monitor a `DOWN` of reason `noproc`, each queued with
ERTS's own `erts_dsig_send_exit` and `erts_dsig_send_m_exit`; a spawn
request without the spawn right gets a `SPAWN_REPLY` of `noconnection`.
Nothing of this reaches ERTS's link, monitor or spawn code, and neither
the outcome nor its timing tells the peer whether the target lives.

**The export table's three writers**, each an act of the name's owner
([design-domains.md](design-domains.md#exports)):

1. **Handing out a name.** When the external encoder puts one of this
   domain's own pids, or one of its active aliases, into a frame for a
   peer, in the control term or the payload, and the peer holds nothing
   on the name yet (edit 8), it adds the peer with `send` alone, which
   covers messages, alias sends and monitors; the sender of every control
   term is handed out this way, never with more. So a peer can message,
   call and monitor a process whose name it was handed, and cannot link
   to it, kill it or set its group leader. A name encoded again toward a
   peer that already holds it changes nothing. The encoder knows the
   entry it encodes for, as it knows it for the atom cache, so the write
   costs one look at the name's holders.
2. **A spawn into the domain.** When `erts_net_message` creates a process
   for a `SPAWN_REQUEST` from a connection, the runtime adds the spawner
   to the child's holders with `send`, `link` and `exit` before the child
   runs, so a parent keeps over a child in another domain what ERTS gives
   it over any child, and `spawn_link` and `spawn_monitor` keep their
   meaning.
3. **`erx:export/3`.** A process of the domain sets what a peer holds on
   one of the domain's own names, its own pid, an alias it owns or, from
   `init`, the domain itself, to exactly the rights it names:
   `erx:export(Name, Rights, Peer)`, widening or narrowing. Only the
   owner grants: no other site writes a holder, and no frame from a peer
   does. A domain's runtime exports `init` with `send` and the domain's
   name with `spawn` to the system domain and to the domain's spawner,
   both named in its boot information, before it reads its first frame,
   which is how stock `spawn_opt/5` and `spawn_request` with the domain's
   node name reach every domain the system domain created and how a
   spawner reaches the domain it asked for, and to no other peer unless
   the release's boot script says so.

Holders end with their name: a process's exit clears its holders (edit
13), an alias's deactivation, under OTP's own alias rules, clears the
alias's (edit 14), and a connection's end clears every holder toward its
peer. A frame that arrives for a name its peer holds nothing on is
unheld, and gets what a dead process gets, so a stale pid names nothing
(D1). A pid export therefore lasts as long as the process, and the
revocable name is an alias, as in stock OTP.

**Closing.** A connection closes from this side when the funnel refuses a
frame as malformed, when the lane's ring or reader page fails its checks,
when a signal does not fit the connection's `peer_held`, when a process
of the domain calls `erlang:disconnect_node/1` on the peer, or when the
system domain says the connection is down. When the system domain says
so, in `connection_down`, the runtime first drains the lane up to the
write position it reads then, through the funnel as always, waiting on
nothing the peer would have to do: a dead peer's position is final, so
the frames it published before it ended are delivered, and a live peer's
frames after that position are lost with the connection. Then, in every
case, the driver closes the port: ERTS runs `erts_do_net_exits` on the
entry, which fires every link, monitor and pending spawn the domain holds
across it with the reason the system domain gave, `{domain_down, D,
Info}` for a peer that ended and `noconnection` otherwise, sends
`nodedown` to the node's monitors as on a stock node, and
`erx_connections` unmaps both sides, closes its three capabilities, and
answers `connection_unmapped`, or, when this side ended the connection,
tells the domain service `connection_lost` with the reason. The system
domain deletes the connection's objects only once both parties have
unmapped them or ended, never on a timer while a party lives
([design-domains.md](design-domains.md#introduction-and-connection-down)).
The system connection is never closed from this side while the domain
runs: a malformed frame or a failed check on it halts the domain instead,
since the domain has no services without that connection and could tell
no one; when the system domain ends it, the domain service stops the
domain ([design-system.md](design-system.md#ending-a-domain)).

**Facets** are processes of the system domain that act only for their
grantee; a facet sees frames only from its grantee's lane, since the
funnel marks nothing and the drain names the entry; `erx:origins(true)`
delivers each message as `{erx_origin, D, Msg}` with `D` the lane's peer
(edit 16), and a message whose decoded size is past the facet's
`max_request` is dropped and counted before it is queued (edit 12)
([design-domains.md](design-domains.md#facets)).

### Programs as ports

A native program of a session is a port of the session's runtime: owned by
a process, linked to it, closed with it, spoken to by messages, and
reporting `{exit_status, N}`. Its program side, the spaces it runs in,
the channel protocol, the handler's duties and the personality are
[design-programs.md](design-programs.md#a-program-is-a-port); the port
driver, `erx_program`, is the runtime's side and makes every kernel call
about a program.

**Starting.** `erx_program:start(Spec)` opens a port on the driver; the
driver's `start` is a plan validated whole before any effect, then
applied in this order, each step undoing the ones before it on failure:

1. **Validate.** The spec names the image, a program of the boot image or
   a file object the session holds through an `rx` grant; the handler, a
   process of the session (the owner by default); the parent of the
   program's anchor; the pipe ends and descriptors the program inherits;
   its startup message; and the guarantee and cap of its budget and the
   limits of its group, which lie within the session's pool for programs
   and the session's grant.
2. **Create the program's spaces** as
   [design-programs.md](design-programs.md#a-program-is-a-port) lays them
   out: carve the program's budget from the session's pool for programs; create its group,
   a child of the session's programs group with the limits the spec
   gives; create its **anchor**, a space with no thread whose parent is
   its starter's anchor, or the session's space for a program the shell
   starts, with the session's fault gate and the program's process id as
   label; and create its **image**, the space its threads run in, below
   the anchor. So the kernel ends the program with its starter and its
   session, ends the program's children with it, and keeps it within the
   session's budget and grant
   ([design-system.md](design-system.md#sub-spaces)).
3. **Map the image.** A program of the boot image is mapped from its
   slices with `erx_image_map`, its code shared with every program that
   runs it; an executable file runs the boot image's loader, `erx_exec`,
   mapped the same way, which once it runs in the image checks the file
   with `erx_elf_plan` and maps its code from the file object, never
   writable and executable at once
   ([design-programs.md](design-programs.md#what-a-program-can-start)).
   The three chokepoints stay the only readers of headers, copiers of
   code and mappers of code ([design.md](design.md#chokepoint-checks)).
4. **Create the channel and the data area**: two rings, two reader pages
   and two doorbells, in the lane layout every lane has
   ([design-domains.md](design-domains.md#connections)), from the
   session's budget; bind the program's doorbell to the program's group
   with the channel as its label, and the session's doorbell to the
   session's group under the port's label, registered as the port's sink
   in the event table; and create the program's data area from the
   session's budget, as the channel is
   ([design-programs.md](design-programs.md#the-channel)).
5. **Install** into the image's table the budget, the group, the
   channel's objects, the data area, the pipe ends the spec names, as the
   session's pipe server made them
   ([design-pipes.md](design-pipes.md#making-a-pipe)), and the code
   object of an executable file; and create the image's first thread,
   stopped, with the values of the budget, the group and the channel's
   objects in its argument registers.
6. **Write the startup message** as the first frame of the image's
   inbound lane, in the form the programs design defines: the program's
   process ids, arguments, environment, working directory, signal state,
   data area and the values of its descriptors in its table, and no
   Erlang pid
   ([design-programs.md](design-programs.md#the-startup-message)).
7. **Start the first thread**, pausing the image first when the spec says
   the program's job is stopped
   ([design-programs.md](design-programs.md#job-control)), and link the
   port to its owner as ERTS links every port.

**Serving.** The session's doorbell schedules the port's input task; the
task copies each frame out of the outbound lane once through
`erx_lane_take`, runs the funnel in its channel mode, structure alone,
since a channel carries no name with authority, and decodes the request
in safe mode, since every atom of the protocol is in both runtime images
and a program creates none; it then delivers each request and notice to
the handler as `{erx_channel, Port, Request}`, within the program's
**credit**, which the driver keeps from the frames it writes and reads: a
reply slot is busy from the request the driver delivers on it until it
takes the reply on it with `send/2`; a `{closed}` notice is due once for
each pipe end that a frame it wrote gave the program; and a `{drained}`
notice once for each frame it wrote that names a writer gone to a read
end. A request on a busy slot, or a notice that is not due, is a frame
outside the grammar and ends the program with `SIGSYS`
([design-programs.md](design-programs.md#the-program-protocol)), so the
handler receives at most one message of a program for each credit,
whatever the program writes. The handler acts with the session's
authority after checking the program's own table, and installs
what the program's table gains with `erx_program:install(Port, Caps)`,
which goes through the session's capability to the image the port
serves and fails with `ERX_EDEAD` once that image has stopped
([design-programs.md](design-programs.md#the-handler)). File data never
crosses the channel per byte: it moves through the program's data area,
which the handler fills and drains
([design-programs.md](design-programs.md#descriptors-and-files)). A
program's shared mapping of a file is the session's memory object for
that file, which the handler fills with ordinary reads, installs into the
program's table with `install/2` for the program to map, and writes back
with ordinary writes ([design-files.md](design-files.md#shared-mappings)).

**Writing to the program.** `erx_program:send(Port, Term)` encodes one
frame onto the inbound lane, a reply or a report, a signal's included,
and never suspends the handler, since no process of the session waits on
a program (P3 of [design-programs.md](design-programs.md#invariants)). It
returns `ok` once the driver has taken the frame, writing what the lane
has room for at once and the rest as the program frees room, and `busy`
while the driver still holds part of an earlier frame; the handler then
keeps the frame as **owed**, writes nothing newer before it, and sends
it again when the driver tells it, with `{erx_channel_room, Port}`, that
the program's event executor has freed room and rung the session's
doorbell.

**Signals.** The driver keeps no signal state and triggers no IRQ object
of the program's. A signal the program may catch is a report the handler
sends with `send/2`, in order with every other frame on the lane, so a
child's exit report precedes its `SIGCHLD`; the program's own event
executor applies it, raises the signal in `liberx`, and triggers the
signal IRQ object of the thread that takes it, which that thread's vCPU
state area turns into an upcall
([design-programs.md](design-programs.md#signals-in-liberx)). The session
therefore holds no capability to the signal IRQ object of any of the
program's threads, only to the doorbells it made itself, its channel's
and its pipe ends', and none of its capabilities has to follow the
program's threads across a `fork` or an `exec`. What needs no
cooperation from the program is the
driver's: `SIGKILL` is `erx_program:stop(Port, anchor, Status)`, which
stops the program's anchor with the kernel's stop call, `erx_space_stop`,
and with it the program's whole tree; `SIGSTOP` and `SIGCONT` are
`erx_program:pause(Port)` and `erx_program:resume(Port)`, which call
`erx_space_pause` and `erx_space_resume` on the image as job control does,
the handler reporting `SIGCONT` after a resume whether the program
catches, ignores or blocks it, since the session never sees the program's
dispositions ([design-programs.md](design-programs.md#job-control)).

**Fork.** `erx_program:fork(Port, Spec)` makes a child of the program:
its budget, its group and its anchor below the parent's anchor, as step
2 does, and its image, empty; pauses the parent's image with
`erx_space_pause` and has a **copier**, a worker of the session's space
in the parent's group, wait for its threads to finish their calls with
`erx_space_quiesce` under that hold and copy it into the child's with
`erx_space_copy` under it, calls a sub-space's creator may make, so the
copy runs on the parent's grant, and resumes the hold by its ticket
with `erx_space_resume` when the copier reports, or earlier to give the
fork up, which ends the copier's quiesce or copy with `ERX_EBUSY` and
touches no other hold on the parent; and completes the child as steps 4
to 7 do, with the fork message as its startup message and its first
thread at `liberx`'s fork entry. It returns the child's port, owned by
the caller, the child's handler
([design-programs.md](design-programs.md#fork)).

**Exec.** `erx_program:exec(Port, Spec)` builds the program's next image
below the same anchor, mapped as step 3 does, with a channel of its own
and its first thread stopped, while the old image runs on. Once it has
taken the old image's `{exec_commit}`, the handler stops the old image
with `erx_program:stop(Port, image, Status)`, and the old image's exit
record ends nothing: it is the **switch**, at which the driver hands the
handler the signal reports among the frames the old image had not read
to their end, since it keeps each frame it writes until the program's
read position passes the frame's end; deletes the old channel's objects;
makes the next image the one the port serves; and gives it a fresh data
area. The handler installs into it, with `install/2`, the code object and
fresh copies of the kept pipe ends, and writes with `send/2` its startup
message, then the signal reports handed back, then those it still owed
the old image (P13); the driver then starts the first thread. So the
port, its owner, the anchor, the budget, the group
and the program's children are unchanged
([design-programs.md](design-programs.md#exec)).

**Ending.** The gate worker deposits each exit or fault record of the
program's spaces, which carry the program's process id as their label,
with the port, and triggers the port's object; the input task reads it.
A fault record of one of the image's threads ends the program: the
driver stops the anchor with `ERX_EXIT_SIGNAL` plus the signal the ABI
file's fault table gives the fault's kind, and keeps the record for the
shell. The image's exit record, unless it is an exec's switch, reaches
the owner as `{Port, {exit_status, N}}`, with `N` the status the image
stopped with: a halt's status, or `ERX_EXIT_SIGNAL` plus a signal for a
signal's default action and for a fault, as `erx_prog:status/1` reads it
([design-programs.md](design-programs.md#a-programs-end)). The handler
then stops the anchor with the same status, which ends the program's
children and their trees. When the anchor's exit record arrives, which
the kernel posts only after every space below it has ended, the handler
has the driver destroy the anchor, which deletes the tree whatever
capabilities its spaces hold to each other, and close the session's
capabilities to the image, the budget and the group, and close the port, which releases the channel, the data area
and the program's memory to the session's budget. Closing the port from
the Erlang side, by `port_close/1` or the owner's exit, stops the anchor
with `ERX_EXIT_SIGNAL` plus `SIGKILL`, and the command server reaps the
records that follow
([design-programs.md](design-programs.md#failure-handling-diagnostics-and-debuggability)).
`{exit_status, N}` is the one message a program's end produces; links and
monitors on the port behave as on any port.

**A native shim**, any native driver code other than the device NIF, a
row of the driver table
([design-system.md](design-system.md#the-driver-table)), is the same
port with device capabilities: a driver domain starts it as a sub-space
port, installs into the sub-space the device's register windows, IRQ
objects and DMA window or contiguous memory that the domain holds, and
speaks to it over the channel in buffer ids, offsets and lengths, never
in pids ([The device NIF](#the-device-nif)). For a confined device its
bugs reach its own sub-space and the device, never the Erlang heap; for an
unconfined device the shim, like the device and the domain that holds it,
is in the trusted base, since the device's DMA reaches all memory.

**Command domains.** An Erlang command a program starts still needs an
ERTS domain, which the system domain creates and introduces to the
session; the command runtime is the interpreter image in program mode
([Native programs](#native-programs)).

### Unguessable references

Every reference, ordinary and alias alike, has four 32-bit identity words:
all 128 bits of `AES-128(domain_key, source_ordinal || counter)`. The
source ordinal is 32 bits and its counter 96 bits; all fields use the
byte order generated from the ABI. Each reference-producing thread gets a
source ordinal that the runtime never reuses, and one counter shared by
every kind of reference it creates. Allocating another source or
advancing a counter past its range fails with `system_limit` before
reuse. Thus reference creation needs no shared counter on its hot path.
The runtime draws a fresh 128-bit key from `erx_entropy_read` at start
and refuses to start if it cannot obtain it; the key is used only for
references.

**Identity.** AES is a permutation on 128-bit blocks, so distinct inputs
have distinct outputs within a domain, and the domain id as creation
distinguishes domains
([design-domains.md](design-domains.md#domain-ids-pids-and-references)).
These are structural uniqueness properties; they do not depend on the
probability that two fresh keys differ. This uniqueness is scoped to one
boot; persistent protocols do not treat a saved reference as authority
after a reboot.

**Representation and aliases.** OTP 29.1.2's
[external term format](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#newer_reference_ext)
allows up to five uninterpreted ID words in `NEWER_REFERENCE_EXT`; erXos
uses four. ERTS's local reference representation, constructors,
comparison, hashing, text and external encoding preserve all four words
(edit 17). Reference kinds and native resource pointers are local
metadata, never bits a decoder interprets as a pointer: a reference
received over a connection is plain data, the decoder never promotes a matching
identity through the magic-resource table, and native resource APIs
require locally created resource metadata. An alias send resolves the
exact identity in the runtime's bounded **alias registry**, a hash table
from the four words to the owner pid and OTP alias mode, written where
ERTS activates an alias and cleared where it deactivates one (edit 14);
inactive or unknown identities name no alias. An ordinary reference used
as a request tag needs no registration. An alias's identity contains no
embedded pid, and deactivation follows the alias's OTP mode, with
ordinary aliases remaining active across repeated sends. So the runtime
makes none of stock ERTS's pid references, which carry their owner's pid
in extra words and reach five, and every reference of an erXos domain
has the four words, printed `#Ref<D.a.b.c.d>`. A reference of another
machine's node, which only an exposed domain receives, keeps the words
it arrived with, as stock ERTS decodes it.

**Guessing and replay.** Uniqueness is exact; secrecy is computational.
For one domain's ideal 128-bit permutation, after observing `q` outputs,
`g` guesses against `L` distinct, unexposed live identities succeed with
probability at most `g * L / (2^128 - q)`, capped at one, plus the
advantage of distinguishing AES-128 from that permutation. For example,
`q <= 2^32`, `g <= 2^32` and `L <= 2^20` give an ideal-permutation term
below `2^-75`. These are illustrative exposure bounds, not a limit the
runtime enforces or a proof of AES security. A disclosed reference can be
replayed; call state and OTP alias deactivation decide whether a reply is
still accepted. A reference's occurrence in a payload grants no messaging
authority; a process's own alias, encoded for a peer, exports it with
`send`, as a pid is ([Connections in ERTS](#connections-in-erts)).

**Primitive.** `erx_ref_permute` is a small standalone AES-128 block
primitive conforming to [FIPS
197](https://doi.org/10.6028/NIST.FIPS.197-upd1), with a constant-time
portable C implementation and a matching hardware path where available.
The candidate is the reviewed, dependency-free MIT
[`ctaes`](https://github.com/bitcoin-core/ctaes) module; implementation
selection, source review, origin/hash pinning and known-answer tests are
required before this feature is enabled. It links no OpenSSL into the
system domain and defines no custom cipher. Its complete output is used,
without truncation. `tools/erx bench erts-local` measures the portable and
hardware paths against stock `make_ref/0`; on a CPU without the AES
instructions the portable path is on the hottest local path, and the
local-operation target is checked on it separately
([Performance](#performance), [Risks and open
questions](#risks-and-open-questions)).

### Threads and synchronisation

ERTS's ethread library keeps its pthread backend, over the C library's
pthreads: natively musl's, which erXos reshapes to run on `liberx`, and
in [hosted mode](#hosted-mode) libSystem's.

* `pthread_create` creates a worker. Natively it uses `erx_thread_create`,
  whose initial registers it writes into the caller's UTCB, in the
  domain's group, a stack from committed private memory with a reserved
  guard page below it, and the thread pointer set to musl's thread
  descriptor.
* `erx_pthread_create_executor` creates an executor, below.
* musl's futex calls (`__wait`, `__wake` and its `futex` system calls)
  are `liberx`'s umtx calls, so ethread's mutexes and condition variables
  wait on words in private memory, which executors may do. Where an
  interface beyond waiting and waking is needed, it follows FreeBSD's
  `_umtx_op` rather than Linux's futex extensions
  ([design-kernel.md](design-kernel.md#umtx)).
* **ethread's events are the futex variant in every build** (edit 31),
  with `ETHR_FUTEX__` over `erx_umtx_wait` and `erx_umtx_wake`. The events' word
  protocol stays stock's, and the macro keeps its answer, 0 or a positive errno
  (`ethr_event_set__` and `wait__`). A wake answers 0 for any
  count, since `erx_umtx_wake` returns how many it woke. A wait with no timeout
  has the deadline `ERX_WAIT_FOREVER`; a relative one has `erx_clock_ns()` plus
  the timeout, and a sum that overflows is `ERX_WAIT_FOREVER`. `ERX_OK`, which includes a
  word that already differs, is 0; `ERX_ETIMEDOUT` is `ETIMEDOUT`; `ERX_EINTR` is
  `EINTR`; any other status, a wake's negative result included, is `EINVAL`,
  which stock's fatal branch ends. Left to itself, configure
  finds no `linux/futex.h` on either C library, and `ethr_event.c` then falls
  to its other form, which keeps a pipe in each event for timed waits
  (`setup_nonblocking_pipe`, `select`, `read`, `write`). Over umtx there is
  one form, which runs under `lldb` and the sanitizers as it runs natively.
* Thread exit is `erx_thread_exit`; joining is a umtx wait on the thread's
  descriptor.

**Making an executor.** A thread's class is fixed when it is created, on
every backend, and invariant R3 rests on that. ERTS's threads are pthreads,
so what it needs is `pthread_create` for an executor:

```c
int erx_pthread_create_executor(pthread_t *thread, const pthread_attr_t *attr,
    void *(*start)(void *), void *arg);
```

The arguments, the result and the thread are `pthread_create`'s, and the new
thread is an executor from its first instruction, which reads its slot with
`erx_executor_slot`. The call is declared in `liberx/pthread_executor.h`, apart
from `liberx/backend/api.h` because the root's freestanding code includes that
header with no `pthread.h` to include. Its body is the one place the backends
differ:

* **Natively** it lives in musl's tree (`src/thread/erxos/`): it copies the
  attribute, sets a field only it writes and calls `__pthread_create`, which
  passes `ERX_CLONE_EXECUTOR` in `__clone`'s flags, and `__clone` passes
  `ERX_THREAD_CLASS_EXECUTOR` to `erx_thread_create`. erXos's kernel changes none
  of it.
* **Hosted** it lives in `liberx/backend/hosted/thread.c`. libSystem's
  attribute has no room for a class, so a start wrapper does the work: the
  caller claims a thread record and a slot, and the new thread sets
  `thread_self` to the record, pushes a cleanup handler and calls `start`.
  The handler gives back the slot and the record whether the thread returns
  or calls `pthread_exit`, and `erx_thread_exit` on such a thread is
  `pthread_exit`.

`ethr_thr_opts` gains `executor` (edit 29), `ethr_thr_create` alone calls the
function, and `erts_start_schedulers` alone sets the option, for normal and
dirty CPU schedulers (edit 5). Both rules are build checks. A slot is claimed by the
creating thread, so no free slot is that call's `EAGAIN`, never a surprise in
the new thread. `+S` and `+SDcpu` are at most 32 each and a group has 64 slots,
so a run of ERTS meets `EAGAIN` only when another caller has spent slots;
`ethr_thr_create` returns it and ERTS's start ends with its own diagnostic,
`Failed to create scheduler thread` (`erts_start_schedulers`). A call
that turns the running thread into an executor would be simpler hosted, but
it needs a kernel call that exists for no other reason, and it would make class
a state that changes.

No thread of a runtime serves another domain's page faults: a fault on
memory a runtime mapped resolves from the memory object or ends the
faulting thread, and a session serves its programs' shared mappings of
files from objects of its own
([design-files.md](design-files.md#shared-mappings)).

### Memory

ERTS's allocators keep their algorithms inside carriers. `erl_mmap` keeps
its reserve-and-commit structure with its four primitives as kernel calls:
reserving address space is `erx_vm_reserve`, committing is `erx_vm_commit`
(restarted until done), decommitting is `erx_vm_decommit`, releasing is
`erx_vm_release`. Every page is charged to the domain's budget, whose cap
equals its guarantee, so a commit fails only at the domain's own size,
never because another domain or a program took memory first
([design-kernel.md](design-kernel.md#budgets)); a commit the
budget cannot cover fails, and ERTS reports an allocation failure in the
usual way, which ends only that domain. The literal range is one
reservation made at start-up, which costs its record and nothing more
until it is committed. musl's `malloc` draws pages through the same
calls from one reserved range. A runtime that wants warning before a
commit is refused arms `erx_budget_watch` on its budget with a software
IRQ object bound to its group, and trims its carriers at the notice.

**No allocator of its own.** The system domain's interpreter image keeps
ERTS's allocators as every image has them, with no bookkeeping of memory
per client inside the allocators. What the system domain holds
for one domain is a sum fixed when the domain is admitted, which the
domain service reserves from the system domain's budget
([design-system.md](design-system.md#resource-policy)), and each term of
it is a bound the runtime enforces:

* the **facet process's queue quota**, its grant's or the manifest's
  `system_queue`, for the frames queued on it and not yet decoded, past
  which the drain leaves the grantee's next frame for it in the
  grantee's lane (edit 15), so a facet that stops reading holds its quota
  and one frame, and its grantee waits on its own full lane;
* the **facet process's `max_heap_size`**, with `include_shared_binaries`,
  which counts the binaries a request's terms refer to and the queued
  frames too, so a facet whose decoded requests outgrow it is killed and
  restarted by its supervisor instead of growing;
* the **lane** the system domain reads from the domain, sized at
  admission by the system domain's `system_lane` and charged to the
  domain's outer budget; it fills once the system domain stops taking
  frames and then holds the domain's senders back in the domain's own
  runtime;
* the **open record** it is reading from that lane, in a buffer that
  grows as the record's bytes arrive, up to the system domain's
  `max_frame`, the largest `max_request` a grant may name ([Connections
  in ERTS](#connections-in-erts));
* its **queue** to the domain, up to the manifest's `system_queue`, past
  which a message is dropped and any other signal ends the connection (edit 10),
  and the connection-control records held behind a long frame, one per
  connection the domain's quota allows;
* what it holds because of the domain's processes, their links and
  monitors with system processes and the signals queued for them, up to
  its own **`peer_held`** (edit 11);
* **lazy decode**, ERTS's own: a frame's message is decoded only when its
  receiver takes it, so an unread message costs its encoded size and no
  heap;
* **one commit funnel** for shared state: a service's shared tables and
  registries change only through their owner's commit, so no request
  writes shared state directly
  ([design-domains.md](design-domains.md#facets)).

A service runs on its own capped grant and does bounded control; work
that grows with a client's input runs in the client's domain or in the
service's domain within that grant
([design-system.md](design-system.md#resource-policy)). ERTS's
allocation-failure behaviour is the same in every domain: a budget the
domain exhausts ends the domain, and in the system domain that is a
machine reset ([Crash handling](#crash-handling)); the bound that keeps
one domain from reaching it is that sum.

### Time

The monotonic clock is the counter, converted with the time page's
multiplier and shift; system time adds the time page's wall offset. Both
are read without a kernel call. ERTS's correction machinery for imperfect
operating-system clocks is deleted, because the counter is the clock;
Erlang's semantics of monotonic time, system time and their offset stay.
ERTS's timer wheels keep their 1 ms ticks; a parking executor's deadline is
a nanosecond value.

### Files

`prim_file`'s Erlang interface and NIF stay; its platform layer, the
`efile_*` functions, is erXos's `erx_prim_file.c`. `prim_file`'s Erlang
side resolves every path through the domain's namespace with
`erx_path`, preloaded Erlang, in the calling process; a path on a file
server goes to `erx_file_remote`, preloaded with it, which speaks the
file protocol, 9P2000.L's operations carried as Erlang terms, in the calling
process over the domain's connection to the server, or by local messages
to a server in the domain itself
([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)).
It has two local providers, both read-only, and every domain runs one file
server of its own:

* **the release file system**, read-only: the files of the domain's release
  slice, listed by the boot image's index and mounted at `/`. Reading a
  whole file returns a binary over the slice's pages, without a copy;
* **EROFS images**, read-only, for a domain whose release lives in an EROFS
  image of its own rather than in the boot image: once booted from the
  small release in its slice, the domain mounts the image at the path that
  release names. For a path on it the NIF returns `{erofs, Image, Names}`,
  and the EROFS reader, `erx_erofs`, Erlang preloaded in both runtime images,
  serves the operation in the calling process from blocks it fetches from
  the storage domain's block service through the domain's grant of it and
  hands to the hash-checking primitive, which checks them against the
  image's dm-verity tree, whose root the boot image carries, and returns
  only blocks that matched; the reader parses no block the primitive did
  not return ([design-storage.md](design-storage.md#data-model));
* **a RAM file system** per domain at `/tmp`, an `erx_fs` server,
  `erx_ramfs`, that runs in the domain and is mounted as a grant like any
  other ([design-tmp.md](design-tmp.md)): in the domain's memory and
  charged to its budget, with a cap of its own, the spec's `tmp` (an
  eighth of `memory` by default), beyond which a write fails with
  `{error, enospc}`, so filling it, by the session's programs or
  directly, stops at the cap with nothing of the refused request done. The
  cap bounds what `/tmp` stores, not the runtime's memory: ERTS's own
  overhead for what it stores comes on top, and an allocation failure
  past the domain's budget is fatal for the domain, as any ERTS
  allocation failure is ([design-tmp.md](design-tmp.md#data-model)). A
  session's programs reach its `/tmp` through fids on the session's grant
  of it, as they reach any grant, and
  their shared mappings of its files are the session's, as of any file:
  the session keeps one memory object per file its programs map shared,
  fills it with ordinary reads and writes it back with ordinary writes
  ([design-files.md](design-files.md#shared-mappings)).

Opening, reading, positioned reads, seeking, file information, directory
listing and the working directory work on all three; writing, renaming,
deleting and creating directories work on the RAM file system and return
`{error, erofs}` on the read-only local providers; anything else returns
`{error, enotsup}`. Paths are UTF-8 with POSIX syntax, at most 4,096 bytes,
resolved one name at a time by the machine of
[design-files.md](design-files.md#resolving-a-path), with `.` and `..` taken
physically, so `f/.` answers `enotdir` and `missing/../x` `enoent`, as stock's
`stat` does. A name over the limit is refused
before any walk, so `missing/` and a 256-byte name is `enametoolong` where stock
answers `enoent`, and macOS's own limit of 1,024 bytes on a path does not apply.
`erl_prim_loader` reads code through `prim_file` unchanged. Persistent
storage is a file server, mounted in the namespace through the domain's
facet ([design-storage.md](design-storage.md)).

**The release file system is a view of a sorted list of paths.** A release is
the archive's entries whose paths start `system/`; the index is sorted, so they
form one run, and a file's path in the namespace is its entry's path without
that prefix. The packer and `erx_pack_open` both refuse a file that is a prefix
of another path, so a directory needs no record of its own: `d` is a directory
exactly when some path starts `d/`, and `/` always is. The provider's core
is pure and builds for the host: given the names an `erx_path` action holds, a
binary search answers file, directory, not found, or a file used as a directory,
and listing a directory walks its range and yields each next name once. An empty
directory cannot exist, and nothing can disagree with the index.

| `prim_file` call | Result |
| --- | --- |
| `read_file`, `open` for reading, `read`, `pread`, `position` | a file's bytes, from `release_addr` plus the entry's offset; a file's position is its handle's, under `prim_file`'s own per-file state; opening a directory is `eisdir`, and opening a file with `directory` `enotdir` |
| `open` of a directory with `[read, directory]` | a handle whose `read_handle_info` answers the directory's information and whose reads answer `eisdir`, as a read of a directory descriptor does on stock |
| `list_dir` | the next names, without `.` and `..` |
| `close` | `ok`: it ends the handle and releases its NIF resource, as stock's `efile_close` does (`unix_prim_file.c:257`); `read_file` closes through it too (`prim_file_nif.c:1380`) |
| `read_file_info`, `read_link_info`, `read_handle_info` | the same for all three: `read_handle_info`, which `read_file` asks first, answers for the handle's entry; `regular` mode `0444` or `directory` mode `0555`, carrying the type's bits as stock's `st_mode` does, `read` access, size, 0 for a directory, one link, owner, group and times 0, since an archive records none and a build is reproducible |
| `read_link` | `einval`, as stock for a path that is not a link: the provider has no links |
| `get_cwd`, `set_cwd` | starts at `/`; set takes a directory that exists, stored as design-files.md's working directory is |
| `open` in any write mode | in the order of `open(2)` with `O_CREAT`: `enoent` or `enotdir` on the way to the last name, `eexist` for an exclusive open of a name that exists, `eisdir` for a directory, and `erofs` for a file or a missing name whose directory exists |
| `make_dir`, `delete`, `del_dir`, `rename`, `make_link`, `make_symlink`, `write_file_info` | `erofs` |
| `advise` | `ok` once `prim_file_nif.c` has checked its arguments, as stock's `efile_advise` answers without `posix_fadvise` |
| `efile_from_fd`, `efile_dup_handle`, `allocate`, `altname` and anything else | `enotsup` |
| a path over the limits, or not UTF-8 | as [design-files.md](design-files.md#resolving-a-path) says: `enametoolong`, `einval` |
| a missing name; a file used as a directory | `enoent`; `enotdir` |
| `read_file` or `open` of a file whose bytes fail their hash | `eio`, with the check's name on standard error; `read_file_info` still answers, from the index, which has its own hash |

Those are the calls of `erl_prim_loader` (`read_file`, `list_dir`,
`read_file_info`, `read_link_info`, `get_cwd`, `read_link`) and more; its
archive branches run only for a path inside a `.ez` file, and stay dormant.
`efile_data_t` here holds an entry and a position, and no file descriptor exists
anywhere in the layer. The table of names is built once when the `prim_file` NIF
loads, from `erx_release_entry(index, &entry)`, which alone reads the names,
and is immutable afterwards, so readers take no lock. A table that cannot be
allocated ends the start with a diagnostic. The first open of each file passes
`erx_release_check(index, &reason)`, which runs `erx_pack_file_check` over it; a
flag per file beside the table, guarding no data, spares later opens the hash,
and two opens that race hash twice.

Two seams keep the rest of the system out of this. New kinds of file are new
rows of the namespace, and every path already passes `erx_path`: a
domain's namespace may have the single row `/`, and an EROFS image or a
file server, `/tmp`'s among them, add rows without moving a caller of `prim_file`. How the index is
read is `erx_release_entry`, a `liberx` call: over `erx_pack_entry_at` and
`erx_pack_path_at` on Phase 1's backends, hosted included
([design-stopgap.md](design-stopgap.md#boot-information)), and over
`erx_object_info(release, ERX_INFO_IMAGE_ENTRY, ...)` on erXos's kernel, which
keeps the index unmapped ([design-kernel.md](design-kernel.md#the-boot-image)).
There the kernel's first use of a file holds the hash's verdict, and
`erx_release_check` answers from it.
Whether a read copies or returns a binary over the pages is the provider's own
affair, and no caller can tell.

### The console and standard I/O

The machine's console is a device like any other, and its UART belongs
to the system domain in every manifest: the console's driver, an Erlang
process over the device NIF in the system domain, reads and writes the
UART ([design-system.md](design-system.md#drivers)), and the kernel keeps
only its early console for its own log. A session's standard I/O goes
through Erlang's I/O protocol to its group, in its own domain, and from
there to its tty ([design-live.md](design-live.md#the-tty)), whose bytes
reach the console line, the UART, the host link or a terminal window, at
which that tty is connected, if any. `standard_error` writes
with `erlang:display_string/2` (edit 39).

**The console service is a program with its own line editor on a raw terminal,
as on UNIX.** The device carries bytes; `edlin` and `group`, stock OTP in user
mode, edit the line and keep its history. `erx_console`, in the system domain,
sits between them and the console's driver, exchanging ordinary messages with no
connection: input bytes go to the group as `{self(), {data, Chars}}`, and each
request from the group goes through `prim_tty:handle_request/2` to become bytes
for the driver. A session in another domain does the same beside its own
tty ([design-live.md](design-live.md#the-tty)). `-user erx_console`
([Configuration](#configuration)) makes `user_sup` call `erx_console:start/0`,
which starts the driver and two groups, as `user_drv` does: the shell's,
which runs the command shell (`{erx_shell, console, []}`) and gets the input, and
a group with no shell registered as `user`, since `shell:prompt_width/1` calls
`io:getopts(user)` from inside the shell's group and a group cannot answer itself.
The command shell is the console's first shell, as a UNIX console's login shell is.
When it ends, by `exit` or a crash, while input may still come, the console
starts a fresh one, as getty starts another login; once the input has ended, its
end ends the runtime, with status 0 if it ended normally and 1 if not, as stock's
shell halts at the end of its input. With `-noshell` or `-noinput` there is no shell.

The first shell needs no more than this. Its `erx_console`, group and terminal-less
`prim_tty` over a raw-byte driver are the system shell's permanent path, not a
stand-in: the system shell's tty stays raw with every flag clear, so nothing lies
between `prim_tty` and the driver ([design-live.md](design-live.md#the-tty)).
Input bytes reach the group unchanged, and `prim_tty`'s bytes the driver unchanged.

**A shell started from a shell takes the console on a group of its own.** In Phase 1
the command shell runs in the system domain on its console
([design-shell.md](design-shell.md)): its `erl` command runs the Erlang shell, and
`erx_shell:start()`, typed at that Erlang shell, starts another command shell.
Each calls `erx_console:run_shell/1`, which starts a group for the shell, as `user_drv`'s
`s` and `c` start a shell and connect to it, and gives that group the input; when
its shell ends, the input goes back to the group below and the caller gets its
answer; such shells may end in any order, and once the input has ended each group
that gets the input is told so. `q()` typed at an Erlang shell started this way ends
that shell, not the runtime, a documented difference from stock OTP. As `user_drv` shows only its current group, the
groups below are not shown: their output is acknowledged and dropped, and their
questions answered; `user`, which carries the logger's output, is always shown.
`Ctrl-C` interrupts the command shell, which ends its running line and reads on. A line's output is bytes: it reaches the driver through
`erx_console:write/1`, past `prim_tty`, with each newline sent as CR-LF, as a
cooked tty's `ONLCR` sends it, and every other byte unchanged.

`prim_tty` stays because the group's requests (insert, move, delete, redraw) carry
edit state across wrapped lines, so a console without it would be a larger
renderer of its own, while a cooked line discipline and `-oldshell` give no arrow
keys or history, which the first shell's demo needs. Its state comes from
`init_ssh/3`, which needs neither a terminal descriptor nor terminfo. This path
calls two helpers of the removed NIF, `isprint/1` for each ASCII character
(`prim_tty.erl:1280`) and `wcwidth/1` for each column count, a prompt's included
(`:1139`). Edit 38 makes both pure: `{error, enotsup}` is the answer
`npwcwidth/2` already takes to `unicode_util:is_wide/1`, so a combining mark
counts as one column.

**A runtime's own output is raw, and has two paths, by whether the caller can
wait.** Nothing in ERTS or `sys/erxos` escapes or filters what a process writes.

**A process waits on its tty's owner.** `erlang:display_string/2`,
`erlang:display/1` and `standard_error` run in a process, which can wait without
holding an executor. While another process holds the registered name
`erx_tty_owner`, the two functions trap (edit 35) to `erx_output:write/2`, in
`kernel`, which monitors the owner, sends it `{tty_write, From, Ref, Bytes}` and
waits in `receive` for the answer, the shape of `standard_error`'s `put_chars`
over `prim_tty:write/3` (`standard_error.erl:200`, `prim_tty.erl:544`). The owner
depends on the domain:

| The domain | `erx_tty_owner` | What it does with the bytes |
| --- | --- | --- |
| a session's | the terminal relay | writes them to the session's tty, as any writer does, and answers when they are all in the tty ([design-live.md](design-live.md#the-tty)) |
| the system domain | `erx_console` | writes them to the UART's driver unchanged, as UNIX writes to `/dev/console`, and answers when the driver has written them, so a service never waits on a shell's or a session's tty, nor on any other console line ([design-live.md](design-live.md#the-console)) |
| any other, which has no terminal | the logger proxy | sends them as log records to its console facet, under its name, which the console escapes, and answers at once: a UNIX daemon's rule, that with no terminal its output goes to a log under its name |

**C output never waits.** `erts_printf` and stdio to descriptors 1 and 2 have no
process to yield and no way to wait on what their own executor must run, and the
same goes for a process with no owner to write to: before one starts, the owner
itself, and a caller whose owner has gone. All of them use
`erx_output_write(fd, bytes, length)`, whose meaning differs by build:

* Hosted, it is `write` on the process's own descriptor, whose reader is outside
  the runtime.
* In Phase 1 natively, it is the seam's console write
  ([design-stopgap.md](design-stopgap.md)), which reaches the UART at once,
  unchanged, and can interleave with the driver's writes at any byte.
* On erXos's kernel, it gathers a line in a buffer of the calling thread, as long
  as a debug log record, and calls `erx_debug_log` at each newline or when the
  buffer fills. That is the kernel's own labelled, escaped and rate-limited log,
  which drops and counts past its rate and never waits.

It always answers `length` natively, so it never reports a blocked write, and what
calls it has no retry to spin in. `erl_printf.c`'s two loops, which retry
immediately on `EAGAIN` (`erl_printf.c:95-96`, `:110-112`), and the loop in
`display_string/2` finish on their first pass. musl's `__stdio_write`, which repeats
on a short count and on a negative one sets `F_ERR` and discards its buffer
(`musl/src/stdio/__stdio_write.c`), reaches the same path through the seam's
`writev` and sees every byte taken, so `ferror(stderr)` stays clear. No executor
can spin on its own drain, because there is no drain.

What takes the kernel's log this way is ERTS's own diagnostic text, shown under the
name of the space that wrote it, and so attributed text, which is escaped as all
such text is ([design-live.md](design-live.md#attributed-text)); no process's
output takes it while an owner lives. The same log serves `liberx`'s lines and the
crash path.

**A normal halt leaves no accepted byte behind.** A tty in the same domain as its
writer stops with it, and it can hold bytes it has answered for. So `erlang:halt/2`
with `{flush, true}`, stock's default, traps while another process holds
`erx_tty_owner` (edit 42) to `erx_output:halt/2`, which sends the owner
`{tty_drain, From, Ref}` and waits up to `flush_timeout`, or 5 s where that is
`infinity`. The owner answers once the master has answered every byte it holds, or
at once when the tty is stopped, since nothing would take them and a hang-up on UNIX
discards them too; `erx_console` and the logger proxy hold nothing they have
answered for. It then gives up the name, so the second call of `erlang:halt/2` goes
straight on. `erlang:halt/1` with a string is the crash path, which stays bounded and
waits for no process ([Crash handling](#crash-handling)). A runtime with no owner has
nothing to drain: its bytes are with the kernel, the host or the UART already.

**`erx_stdio`, hosted mode's console driver.** `erx_console` is one program in
every build, and the driver is the one process that differs, since a hosted
process has no UART to map (`erx_mem_create_physical` and `ERX_IRQ_LINE` are
refused there). A driver is a module with `start_link(Console) -> {ok, Pid, Terminal}`,
where `Terminal` says whether a person's terminal is on the line, which it always
is for a UART. With none, as `user_drv` does, the shell's group is `dumb` and
`prim_tty`'s output raw, so a pipe gets bytes with no editing or echo. Both drivers
speak the same messages:

| Message | Direction | Meaning |
| --- | --- | --- |
| `{erx_console_output, From, Bytes}` | to the driver | write these bytes, whole and in order; `From` is opaque to the driver |
| `{erx_console_written, From}` | to `erx_console` | those bytes are written or the line is gone; every output message gets this answer |
| `{erx_console_input, Bytes}` | to `erx_console` | bytes as read, in order, cut anywhere |
| `{erx_console_size, Columns, Rows}` | to `erx_console` | the line's size is known or has changed; `erx_console` ignores a side outside 1 to 65,535 |
| `erx_console_eof` | to `erx_console` | input has ended, after every byte read before it |

`-user erx_console` holds against `-noshell` and `-noinput`, which `erx_console`
reads: it starts no shell's group and gives `user` the input. A console whose driver
or shell's group ends prints why and halts with status 1, since nothing would read
the terminal again.

`erx_console` answers a `put_chars_sync` only on `erx_console_written`, so
`io:format` returns when its bytes are out, as `write` on a UNIX terminal does.
It assumes 80 by 24 until a driver reports a size, and a UART driver reports none.
`-erx console_driver Module`, an ordinary argument of the boot information page,
names the driver, and the last naming wins: the manifest names the console UART's driver,
`erx_pl011`, and the hosted entry adds `erx_stdio` after it.

**Which input bytes mean something.** `erx_console` takes two bytes out of the
stream, which no UTF-8 sequence contains: `Ctrl-C` becomes `exit(Group, interrupt)`,
and `Ctrl-G` opens the console's menu ([design-live.md](design-live.md#the-console)).
The rest goes to the shell's group as UTF-8, with a character cut across two reads
held until its end arrives and a byte that belongs to no character read as latin-1,
as `prim_tty`'s reader does. `erx_console:input/2` is that decision, a pure function
with a fuzz target. `Ctrl-Z` and `Ctrl-\` are ordinary bytes on this path, as on any
raw terminal.

`erx_stdio` is an Erlang process in `kernel` over `erx_stdio_nif`. A worker
thread of the NIF, blocked in `poll`, reads standard input into a buffer and
triggers a software IRQ object bound to the group, whose label the event table
registers to `erx_stdio`, so input travels the same path as a device's interrupt
and every executor can park while the terminal is idle. A terminal on standard
input is raw from the driver's start until the runtime's exit path, whose
`sys_tty_reset` restores it; a fatal signal does not take that path. `SIGWINCH` writes
to a pipe the same thread polls, and the size travels in the same event.
Output is `write` on standard output from a dirty I/O NIF.
End of file is an input event in order: `erx_stdio` sends
`erx_console_eof` after every byte read before it, and `erx_console` hands the
group `{self(), eof}`, the stock message. `group` holds a driver's messages until a
reader asks (`group.erl:253`), so the shell evaluates each command ahead of the
end, then reads `eof` and halts with status 0, its own stock branch
(`shell.erl:384-392`). The shell's last line before `halt()` is a synchronous
write, so all earlier output is out when it halts. The UART driver never sends
the message. A read error prints its reason
on standard error and is `halt(1)`. `erx_stdio_nif.c` is the one source in
the runtime that touches a host file descriptor. Only the hosted image's static
NIF list names it, and natively the module is present and never started. It
stays as long as hosted mode does: it is hosted mode's device, not a step toward
the UART driver, which is a process over [the device NIF](#the-device-nif).

**Pipes in a runtime.** A session's domain is the home of its pipes: its
pipe server, a process of the command server, creates and keeps every
pipe's rings and pages, makes every end and every doorbell, and installs
the ends into its programs' sub-spaces through the program driver
([design-pipes.md](design-pipes.md#making-a-pipe)). The session's own
processes hold ends too: the near ends of its programs' standard streams,
which its terminal relay reads and writes, and the ends of Erlang commands
that meet programs in a pipeline
([design-shell.md](design-shell.md#pipelines)). The pipe NIF reads and
writes their rings exactly as `liberx` does but never waits, so executors
may call it: where a program's call would wait, for data or room, it
publishes the same position and returns `would_block`, and the process
waits for a message. Each end's doorbell is bound to the domain's group
with a label the event table registers to the end's process, so a ring
wakes exactly the process that waits on it, with no scan of the others
([design-pipes.md](design-pipes.md#waiting-and-doorbells)). An end is a
NIF resource owned by one process, the command or relay that uses it,
which the resource monitors: the pipe server learns at once when that
process exits, not when a collection happens to free the resource, and
the pipe's other ends see the end of the stream as soon as the command
ends.

### NIFs and blocking

A NIF or BIF that runs on a normal or dirty CPU scheduler runs on an
executor. If it makes a kernel call that would wait (an IPC call, an open
wait for IRQ objects, a umtx wait on shared memory), the call fails with
`ERX_EWOULDBLOCK`
([design-scheduler.md](design-scheduler.md#executor-class-enforcement)).
The C library's blocking functions that reach such calls return an error
with `errno` set to `EWOULDBLOCK`. ERTS's own NIFs need no change: file
operations already run on dirty I/O schedulers, and the pipe and device
NIFs and the lane driver never wait. A NIF that must block declares
itself dirty I/O, as OTP already requires for well-behaved NIFs, and runs
on a worker. A blocking NIF on a normal scheduler, which on a host stalls
the scheduler silently, fails loudly on erXos; this is a documented
difference, and E-S10 counts where OTP's own NIFs meet it.

### The device NIF

A driver is an Erlang process under a supervisor, in a domain that holds
its device's capabilities ([design-system.md](design-system.md#drivers)).
The C under it is `erx_device`, one module that exposes `liberx`'s
DMA envelope and parses nothing a device wrote. Its register accesses are
BIFs in ERTS, because a driver makes them one at a time and a BIF costs
less than a NIF's entry and exit, and so is `erx_device:irq_ack/2`, made once per interrupt; the rest of the module
is a NIF. Its pure decisions are `erx_device_core` and, for its queues, `erx_device_queue`; its effects are `erx_device.c`, in plain C, under both. A device's record reaches
the driver from the device service over the system connection: the slots
of its register windows, IRQ objects and DMA window or contiguous memory,
its peripheral's name in the CMSIS-SVD source, whether it is
`dma-coherent`, and which queue layouts of the ABI file it uses.

**What the NIF keeps.** The NIF keeps one record for each device the
domain holds, a small integer its driver names it by, for the boot, since the manifest gives each device one
holder ([design-system.md](design-system.md#devices)): its register
mappings, the binding of each of its lines, and every pool and queue
made for it. Pools and queues are state of that record, never resources
of a process: a driver process names them, and when it exits or crashes
they stay as they are, posted buffers included, so nothing the device
may still hold is given out again. Pool memory is never freed while the
device can reach it: an unconfined device's is the system domain's for
the whole boot and never freed, and a confined device's is freed only
after the kernel has unbound it from the device's window.

**Windows smaller than a page.** A device's register window may be
smaller than a page and start anywhere in one, as each 0x200-byte
virtio-mmio slot of QEMU `virt` does, while the kernel maps device
memory in whole pages only. A record's mapping is therefore the pages
that hold its window, its first page through its last and nothing
beyond them (`erx_device_window_pages`, a pure function of the window's
base and size), and the register table's offsets apply from the
window's base inside that mapping. The windows of other devices that
share those pages lie inside the mapping too, but no name in any table
reaches them: every access is a register of the record's own
peripheral, at an offset below its window's size. Every device of a
shared page belongs to one domain, since devices whose registers share a
page form one unit ([design-platforms.md](design-platforms.md#invariants),
PL2), so the mapping reaches no other domain's device. Records whose
windows share a page share that page's one mapping.

**Registers by name.** `erx_device:read(Dev, Reg)` and
`erx_device:write(Dev, Reg, Value)`, with `erx_device:read_field/3` and
`erx_device:write_field/4` for a field of a register, all four BIFs, take a register's
name, an atom, or `{Name, Index}` for a register array, and nothing else:
the generated accessor table for the peripheral, produced from the SVD
file by the one generator that produces every register accessor, maps the
name to its window, offset, width, access and field masks, and a name the
table lacks is `badarg`. No raw address or offset exists in the interface,
so the one-source rule holds in Erlang as in C
([design.md](design.md#one-source-for-the-abi-and-the-hardware)). Every
register of a peripheral the NIF drives carries a mark in the SVD source,
`ownedByNif`, saying whether the NIF owns it, and the generator refuses a
register without the mark. The NIF owns every register through which a
driver could aim the device at memory or change what the device expects
of the rings: for virtio-mmio the status, the feature selectors and the
driver's features, the queue selector, size, ready bit and doorbell, and
the rings' base addresses. `write/3` and `write_field/4` refuse an owned
register with `badarg`, so only the NIF's own sequences write one
(`negotiate/2` and `post/4`), with values and addresses it built itself; a
driver may still read one. Only `erx_device.c` holds the raw accessors, so
nothing else in C can store to an owned register either; its sequences
name owned registers by the index `tools/gen_hw.rb` gives each in
`erx/hw/device_owned.h`, which a chokepoint keeps in that file. A read or write is one
volatile access through the window's mapping and never waits; a device
that hangs a bus is the platform's residual, not the runtime's.
`write_field/4` on an ordinary field is that read and that write, allowed only
where the read has no side effect and every writable field means replacement; on a
one-to-clear field it is the write alone, and elsewhere `badarg`, so the
register is written whole with `write/3`.
`erx_device:field(Dev, Reg, Field, Word)`, also a BIF, is pure: it cuts a field out of a
word the driver already read, without touching the device, and is `badarg` for a field the
register does not let it read. A driver reads `dr` once, which pops a byte, and decodes
the data and the error bits of that one word with it. A driver clears the interrupts it
handled with `write(Dev, icr, read(Dev, mis))`, which needs no mask.

**Queues and their pools.** `erx_device:queue_create(Dev, Queue, Size, BufferSize)`
adds to the device's record its queue `Queue`, of `Size` entries in the
layout the device uses, and the queue's pool of `Size` buffers of
`BufferSize` bytes. The rings and the pool are each memory the record
holds: for a confined device a memory object from the domain's budget,
mapped into the domain and into the device's DMA window with
`erx_dma_map`; for an unconfined one contiguous memory, the system
domain's for the whole boot. It returns `{ok, Q}`, the queue's name in
that record; the same queue again is that queue again, posted buffers
and all, so a restarted driver finds it. Every buffer the device ever
addresses is a range of a pool, and every device address is built by the
NIF from the memory object and an offset, through `erx_dma_map`'s I/O
address or `erx_mem_dma_addr`, and never given to Erlang. A queue is on
the device only once `negotiate/2` has installed it: the device's
owned registers then hold the rings' base addresses and the size, with
whatever else the layout's sequence names to make the device take the
queue, such as virtio's ready bit.

A pool belongs to one queue and its buffers to the queue's descriptors:
buffer *i* is the buffer of the chain whose head is descriptor *i*. The
queue's own bookkeeping, `erx_device_queue`, hands out heads only from
its free list, so no two chains in flight share a buffer and no buffer is
handed out but by a post: the property needs no record of its own.

**Posting.** `erx_device:post(Dev, Q, Tag, Segments)`, where `Segments`
is a list of one to four `{out, Binary}` and `{in, Length}`, every `out`
before every `in`, makes one request in one call: the NIF lays the
segments end to end in the buffer of the next free head, copies each
`out`'s bytes in, the one per-byte copy of a transmit path, and has
`erx_device_queue` decide the descriptors, whose layout the ABI file
fixes. Each descriptor's address, length and link, and every flag that
makes the device fetch an address, such as virtio's `NEXT` and
`INDIRECT`, are the NIF's alone; the driver chooses only which segments
the device writes, so no descriptor can aim the device at a table, a
chain or a buffer the NIF did not build. The NIF then writes the plan
whole, since the queue counts it made once decided: the descriptors, the
available entry, a barrier, the available index, the cache maintenance
the envelope's plan orders for a device that is not coherent (a clean
before the device reads, a clean and invalidate before and after it
writes, never an invalidate alone), a barrier, and the queue's doorbell
register by name. No step after the decision can fail. A driver never
holds a buffer: there is nothing to take, fill and post in turn, so no
order of calls can leave a buffer taken and not posted. `Tag`, below
2^64, comes back with the completion. A queue with too few free
descriptors is `{error, full}`, and the driver waits for a completion;
segments longer than a buffer, empty or out of order are `badarg`. An
`out` is a binary, never an iolist, so the NIF knows its size before it
copies or flattens anything.

**Completing.** `erx_device:complete(Dev, Q)` reads the used ring's index
once and each entry's two fields once, from the slot `erx_device_queue`
names, which checks the index against what is in flight, the entry's
descriptor against its own table and its length against what the chain
let the device write. It copies the bytes the device wrote, in the
order of the chain's `in` segments and cut at the length it reported,
into a fresh binary, returns the buffer to its pool, and returns
`{ok, [{Tag, Bytes}]}`, stopping once 64 KiB are copied, at most 64 KiB
and one buffer, so a call stays
within a reduction slice; the driver calls again until it gets
`{ok, []}`. That copy is the one per-byte copy of a receive path,
per-byte C like the post's: a device can write a buffer again after its
completion, and ERTS assumes a binary never changes, so no binary ever
aliases memory a device can reach (R9). The driver parses the bytes in
Erlang, with binary pattern matching in its own supervised process, so a
malicious device corrupts no memory and a malformed frame kills at most
the process that parsed it. Anything else a device writes, an index
ahead of the chains in flight, an entry naming no posted head or a
length beyond the chain, breaks the queue: the entries before it are
still returned, and from then on `post/4` and `complete/2` on it are
`{error, broken}` until `negotiate/2`, so a malformed completion never
frees a buffer the device may still write.

**The reset rule.** A posted buffer belongs to its queue until the
device returns it: it goes back to its pool only through `complete/2` or
when the NIF itself resets the device, in `erx_device:negotiate(Dev,
Wanted)`. That one call runs virtio's initialisation (section 3.1.1 of
the specification) whole, so no driver orders its steps. It marks every
queue of the device not ready, so from then on nothing is posted on it or
completed from it; writes 0 to the status and reads it back as 0, else
`{error, ebusy}`; sets ACKNOWLEDGE and DRIVER; reads the 64 feature bits
the device offers and accepts those of `Wanted` that the device type
defines, VERSION_1 always, `ACCESS_PLATFORM` whenever the device offers it,
since every address the NIF gives is the device's own view of memory, and
no other bit of the range that extends the queues and the negotiation
(`INDIRECT_DESC`, `EVENT_IDX`, `RING_PACKED`, `IN_ORDER`, `NOTIFICATION_DATA`,
`RING_RESET` among them, numbered in `abi/formats/virtio.txt`), since the
NIF drives the split ring alone and a device running another format would
misread it; writes them, sets FEATURES_OK and reads it back, else
`{error, enotsup}`, as for a device that offers no VERSION_1; installs
every queue of the device as one plan; and sets DRIVER_OK, returning
`{ok, Accepted}`. The install checks that the device has let each queue
go (virtio's ready bit reads 0, as the reset makes it) and offers its
size, and only once every queue passes returns every posted buffer to its
pool, zeroes the rings, and writes the size, the base addresses and,
last, the ready bit. A queue the device still holds is `{error, ebusy}`
and one larger than the device offers `{error, erange}`, each with
nothing of any queue installed. A failure after the reset sets FAILED and
leaves every queue of the device `{error, broken}` until a later
`negotiate/2` succeeds. The NIF owns the status, the features and the
queue registers, so no driver can clear a ready bit without a reset, move
the selector between the NIF's steps, size a queue past its rings or
choose a ring format: a pool's addresses are given out again only after
a reset the NIF made has made the device forget every old descriptor, and
a device that still holds one never writes into memory a later buffer
took ([design-kernel.md](design-kernel.md#dma-and-the-iommu)). Once a
driver process that used the device exits, the NIF refuses `post/4` on
the device until `negotiate/2`. The queues and their memory stay in the
device's record, so a driver's start and its restart are one sequence:
`open/1`; `queue_create/4` for each queue, which finds a queue its
predecessor made; `negotiate/2`; then `irq_bind/2` and the reads of the
device's configuration. A queue created after `negotiate/2` is not on the
device until the next one. The queue's size is the driver's bound on what
the device may hold at once.

**Interrupts.** `erx_device:irq_bind(Dev, Line)`, whose `Line` indexes
the lines of the device's record, binds the line's IRQ
object, which the domain holds with `BIND` and `ACK`, to the domain's
group under a label the event table registers to the calling
process, the lowest free one, so a hint already taken under a label just given up can reach this sink, records the label as the line's binding in the device's record,
and acknowledges the line once, so a line that a former driver left
masked is unmasked for the new one, and a level still asserted fires at
once. A line another process holds moves to the caller. The process receives `{erx_irq, Dev, Line}` at the next safe point
after the line fires; it services the device and calls
`erx_device:irq_ack(Dev, Line)`, which unmasks the line as its kind
requires
([design-kernel.md](design-kernel.md#messages-gates-and-irq-objects)). A
level-sensitive line stays masked until the acknowledgement, so no device
can storm the runtime. A process's exit unbinds each line still bound
under its own label and no other, so the late exit of a driver that
crashed never undoes its successor's binding. No dirty scheduler waits
for an interrupt: the delivery is an event like any other, and its
latency passes through the runtime's scheduler, which is why gate G9
decides batching per device class
([design-system.md](design-system.md#the-driver-table)).

**Chokepoints.** Only `erx_device` calls `erx_mem_create_physical`, `erx_vm_map`, `erx_dma_map`, `erx_mem_dma_addr`
and the user-mode cache maintenance in a runtime, so nothing else in a runtime has a mapping of device memory; only its generated
accessors, called only by its BIFs and its NIF, touch a register window, and no runtime source includes a peripheral header that `tools/gen_hw.rb` generates or names one of its accessors, which the kernel platform layer alone uses ([design-hardware-generation.md](design-hardware-generation.md)); a record's window is private to the source that holds them; only `erx_device.c` stores to a register the NIF owns, and within it only its one address function writes a ring's address
or a descriptor's address fields and addressing flags;
and the NIF holds no parser: a source check fails the build on a loop
over device-written bytes in the NIF, whose copy at completion is one
call of the bulk copy.
Only the driver's modules reference the device NIF: ERTS binds a static NIF
only to the module of its name, and the register BIFs are that module's, so
Erlang reaches a device only by naming `erx_device`, and a source check
(`tools/lib/erx/device_callers.rb`, in `make check`) fails the build when any
Erlang source under `otp/` or `erlang/` other than `erx_device` itself and
the modules of the driver applications names it, in a call, an apply, a
quoted atom or a string, with a seeded violation in
`test/host/device_callers_test.rb`. It reads text, so it catches a slip,
not code that spells the atom with escapes or builds it from pieces; what
keeps a device from every other domain is that its capabilities are
installed only in its driver's domain.

### Per-byte primitives

System code is Erlang, drivers included
([design.md](design.md#decisions)), and the work it does once per byte is
not: a small set of C primitives in both runtime images does it, as
statically linked NIFs on binaries, each with a fuzz target and a
differential test against a reference on the host. Erlang does everything
done once per packet, per block and per file around them.

| Primitive | Does | Used by | Reference |
| --- | --- | --- | --- |
| `erx_bytes:sha256/1`, with `sha256_init/0`, `sha256_update/2` and `sha256_final/1` for streams | SHA-256 (FIPS 180-4) | the code server's blob checks, the hash-checking primitive, the update service | the specification's test vectors; OTP's `crypto:hash/2` on the host |
| `erx_bytes:crc32c/2` | CRC-32C, continuing from a given value | the EROFS reader's superblock check | RFC 3720's test values; a table-driven model in Erlang |
| `erx_bytes:inet_csum/2` | the Internet checksum of RFC 1071 over an iolist, continuing from a partial sum, and RFC 1624's incremental update | the network stack | a straightforward Erlang model |
| `erlang:crc32/2`, ERTS's own | CRC-32, through ERTS's bundled zlib | F2FS's checksums | the host's stock OTP |
| `erx_verity:check/3` | checks blocks of an EROFS image, given as binaries with their block numbers, against the image's dm-verity tree, keeping the tree's checked blocks in a bounded cache, and returns `{ok, Blocks}` with only blocks that matched, or `{error, eio}` naming the first that did not; the tree's layout, root and salt come from the image's record in the system configuration, in the layout `erx_verity_t` of the ABI file ([design-storage.md](design-storage.md#data-model)) | the EROFS reader | `veritysetup` over the packer's images |
| `erx_device:post/4`'s copy | copies a request's `out` bytes into its pool buffer ([The device NIF](#the-device-nif)) | drivers | a byte-for-byte comparison |
| `erx_device:complete/2`'s copy | copies a completed buffer's returned bytes into a fresh binary ([The device NIF](#the-device-nif)) | drivers | a byte-for-byte comparison |
| the pipe NIF's record copy | copies a record between a pipe's ring and a binary | the session's pipe ends | the pipe tests |

* **Bounded.** A NIF call works on at most 64 KiB of hashing or checksumming
  or 16 blocks, so it stays within a reduction slice and runs on a normal
  scheduler; the caller streams longer inputs. The SHA-256 calls take a
  binary of any size and stream it through calls of 64 KiB themselves,
  each charged reductions for its bytes, so a blob is checked in one call
  and the process is still preempted between its pieces; a state of
  `sha256_init/0` and `sha256_update/2` is an immutable value, so the
  same state may be extended or finished more than once, within the
  runtime that made it.
* **Never blocking.** No primitive waits; every event a driver or a pipe
  end waits for is a message through the event table.
* **Only checked blocks reach the reader.** The EROFS reader takes blocks
  from `erx_verity:check/3` alone, and the check runs over a private copy
  the reader fetched, so no Erlang code parses an unchecked block of an
  image ([design-storage.md](design-storage.md#invariants), E1).
* **The CPU's instructions.** The hash and checksum primitives use the
  CPU's CRC and SHA-256 instructions behind the architecture layer where
  the CPU has them, beside portable C, which is their oracle in the same
  test; `erlang:crc32/2` gains them only if `tools/erx bench fs` asks.
* **Provenance.** The primitives are erXos's own code, except that the
  portable SHA-256 is FreeBSD's, BSD-2-Clause, imported once as erXos's
  code into `kernel/crypto/sha2/` with an `ORIGIN.md`, and built by the kernel's
  entropy generator as well
  ([design-kernel.md](design-kernel.md#interrupts-time-and-entropy)).
  LZ4's decompressor, BSD-2-Clause, joins them only if EROFS images need
  compression
  ([design-storage.md](design-storage.md#data-model)).

### BeamAsm

BeamAsm runs in the BeamAsm image, which every ERTS domain other than the
system domain runs unless its specification chooses the interpreter
image. The system domain runs the interpreter image, built without BeamAsm, asmjit,
libc++ and libc++abi, so the trusted base holds no generated machine
code, no JIT object, no writable view of code and no C++; the system
domain does bounded control only, so the interpreter's speed suffices
there ([design-system.md](design-system.md#the-root-task)). Command
domains run the interpreter image, so they make no code, as no program
does ([Native programs](#native-programs)), and every domain runs it in
deterministic mode, because BeamAsm's output depends on addresses and
hash order ([research](research-erts-internals.md#beamasm-on-aarch64)).
Which image a domain runs follows from one field of its specification,
and which image may make code follows from the image's manifest, so no
domain decides its flavour at run time.

* **Executable memory.** asmjit's `VirtMem` gets an erXos backend: a block
  is a memory object created with `ERX_MEM_JIT`, mapped twice into the
  domain, once readable and executable and once readable and writable. The
  kernel allows this only for JIT objects and only in spaces created with
  `ERX_SPACE_JIT`, which the domain library gives every domain that runs
  the BeamAsm image, the one image whose manifest is marked
  `ERX_IMAGE_JIT`; the interpreter image's manifest carries no such mark,
  so neither the system domain nor a command domain gets a space that
  allows JIT objects. No mapping is ever writable and executable (K8).
* **Cache maintenance.** The kernel lets user mode read the cache geometry
  and clean and invalidate caches by address, so BeamAsm's maintenance
  sequences run unchanged in a domain
  ([design-arch-aarch64.md](design-arch-aarch64.md#cache-maintenance)).
  ERTS's code barrier makes every scheduler issue an instruction barrier
  through aux work before new code is published; a parked executor issues
  it in `finalize_wait` when it wakes, so it never holds the barrier back.
* **Branch protection.** Pages of generated code are mapped without the
  guarded-page attribute, because BeamAsm emits no landing pads; the
  runtime's own code is built with branch protection and its pages are
  guarded.
* **C++ runtime and errors.** libc++ and libc++abi, without exceptions,
  RTTI or localisation, linked into the BeamAsm image alone;
  static-initialisation guards use umtx waits. ERTS's error paths in the
  JIT are repaired so that an encoding error or an exhausted code region
  fails the load with an error instead of being ignored.
* **Diagnostics.** The `perf` map and `jitdump` outputs stay off; the
  inspector's source navigation uses ERTS's line tables, which BeamAsm
  keeps.

### Running Erlang code: the options

Four ways to run a domain's Erlang code, kept with their trade-offs so the
choice can be revisited. Option 1 is the design for the system domain,
and option 2 for every other domain.

| Option | How it works | Gains | Costs |
| --- | --- | --- | --- |
| **1. Interpreter only** (the design for the system domain) | ERTS's interpreter; loading writes threaded code, which is data | no generated machine code; no C++ runtime; deterministic | the slowest: BeamAsm is "anything from no difference to up to four times as fast" (`erts/emulator/internal_doc/BeamAsm.md`) |
| **2. JIT in each domain** (the design for every other domain) | BeamAsm translates each module once at load into a JIT object | up to four times faster; hot loading unchanged | the translator and asmjit and a C++ runtime in the BeamAsm image; a writable alias of each domain's code, inside that domain |
| **3. Ahead-of-time translation on the host** | the host runs BeamAsm's translator over a release's modules; the boot image ships native code | no translator in the domain; boot translates nothing; reproducible native images; native speed in a domain whose space allows no JIT objects | BeamAsm's output must become relocatable (it embeds absolute addresses, atom numbers and a dispatch table keyed by code pointers, `beam/jit/arm/beam_asm.hpp`); a native-code loader; a hot load needs a translation first |
| **4. An ahead-of-time image with hot-loaded code interpreted** | the boot image's modules are native; a module loaded after boot runs on the interpreter until the next image | no code generation at run time; hot loading still works | native and interpreted modules must call each other, which ERTS lost when HiPE was removed in OTP 24 (`erts/doc/notes.md`, Erts 12.0) |

Triggers for re-evaluating:

* a measurement showing that the interpreter limits a service of the
  system domain, which points to option 4, then option 3, for the system
  domain alone;
* boot time, since ahead-of-time translation avoids translating every
  module at each boot, which [plan.md](plan.md) measures;
* reproducible images that must include native code;
* mixed native and interpreted execution getting built for another reason,
  which makes option 4 cheap.

### Code in the system domain

The system domain runs trusted services, so it must never run code that a
service merely received. Its runtime starts with `ERX_BOOT_INSTALLED_ONLY`,
and ERTS's `prepare_loading` then accepts a module only if its bytes lie in
**installed storage**: the pages of the system release's slice, or the
**install arena**, a region of the system domain whose binaries only
`erx_code:install_beam/2` creates, a NIF that refuses every caller but the
`erx_code` process. Any other binary fails to load with
`{error, not_installed}`. The check is by address range against the two
regions, so it holds however the binary travelled inside the domain, and
the install facet is the one way in from outside
([design-live.md](design-live.md#code-from-the-host)). Every other domain
loads any code it is given.

**Every fetch names a hash.** Code reaches a domain from three places.
Its release's files come from its slice of the boot image, whose index the
kernel validated at boot, or from an EROFS image whose blocks the
hash-checking primitive checks against the image's verity tree
([Files](#files)). Hot-loaded code comes from the code service, and the
code server fetches each blob as `{Module, Hash}`, the SHA-256 of the
module's file, and checks the bytes against the hash before ERTS's loader
reads them, so a store, a medium or a transfer that changed a byte fails
the load with `{error, hash_mismatch}` instead of loading it
([design-live.md](design-live.md#the-code-store)). A domain's own code may
also load bytes it made itself, with `code:load_binary/3`, as on stock
OTP, outside the system domain, which refuses them (above); the code
server records the SHA-256 of whatever it loads. The hash is the module's
version for erXos: the inspector shows it, and a domain's history of the
hashes it loaded is what a rollback chooses from. ERTS's own MD5
of a module's code chunks (`module_info(md5)`) stays as stock OTP computes
it. The check uses `erx_bytes:sha256/1`, the SHA-256 primitive that the
hash-checking primitive also uses
([Per-byte primitives](#per-byte-primitives)), so checking a blob needs
no OpenSSL in any domain, the system domain included
([design.md](design.md#dependencies)).

### Crash handling

Every fatal path of ERTS in a domain (`erts_exit` with a dump, a failed
assertion, an allocation failure, an exhausted atom or code table) runs
ERTS's exit path, which writes the crash dump, truncated to the crash
area's size (1 MiB by default) and then marked `ERX_CRASH_TRUNCATED`, into
the crash area the boot information page names, completes its header
([Data model](#data-model)), and stops its own space with
`erx_space_stop(ERX_CAP_SELF, ERX_EXIT_CRASH)`, a negative status the ABI
file defines. A domain created without a crash area, as the vault's is
([design-system.md](design-system.md#the-vault)), writes no dump and
stops with the same status. A deliberate `erlang:halt/1` stops the space
with its status, a non-negative number, and writes no dump. Either way the
kernel posts an exit record with the status to the space's fault gate,
where the domain library's fault thread takes it; the status tells a crash
from a halt, and the domain service reads the header and the dump for the
inspector and fires `{domain_down, D, Info}` on the domain pid
([design-system.md](design-system.md#ending-a-domain)). Only that domain
ends. A domain that faults instead (a wild pointer in a NIF, a stack
overflow into a guard page) stops with a fault record and no dump; the
inspector shows its registers and backtrace from the stopped threads.

A domain can fake either kind of end, but it gains nothing by it: it could
equally crash or halt for real, and its end affects no other domain.

**The system domain.** The same path in the system domain, in a
development build, writes its slogan and the start of its dump to the
kernel log, which the kernel's full crash record carries, and then stops
its space; in a release build it writes no slogan and no dump, since the
brief record a release build writes carries no text, and only stops its
space ([design-system.md](design-system.md#the-crash-record)). The
kernel treats the root task's stop outside an ordered shutdown as a fault
and ends the machine by `erx.panic`
([design-kernel.md](design-kernel.md#the-root-task)). An ordered shutdown
is `erlang:halt/0,1` in the system domain, which the system release turns
into the machine's shutdown. There is nothing to recover: every domain is
a child of the system domain's space and ends with it.

### The C library seam

musl 1.2.6, in erXos's tree as erXos's code, is the C library of every
runtime and native program. It reaches the kernel only through `liberx`:

| musl's need | In erXos |
| --- | --- |
| pages for `malloc` | `erx_vm_reserve` and `erx_vm_commit` on one reserved range |
| threads | `erx_thread_create`, `erx_thread_exit`, umtx; the descriptor found from the thread pointer |
| locks | umtx waits on private memory |
| clocks | the time page |
| entropy | `erx_entropy_read` |
| standard output and error | descriptors 1 and 2: in a runtime, `erx_output_write`, for C output and for a process with no tty owner, which waits on that owner otherwise ([The console](#the-console-and-standard-io)); in a program, the opens it was started with |
| files and descriptors (`open`, `read`, `write`, `stat`, `getdents`, `getcwd`, `chdir`, `mkdir`, `unlink`, `rename`) | in a program, the descriptor table over pipes and files, each operation a request on the channel to the handler and its bytes in the program's data area ([design-programs.md](design-programs.md#descriptors-and-files)) |
| arguments, environment and working directory | in a runtime, the boot information page; in a program, the startup message |
| `posix_spawn`, `wait`, `kill`, `poll`, pipes, `sigaction`, `mmap` | in a program, the POSIX-lite personality: requests to the handler over the channel, `liberx`'s pipes ([design-pipes.md](design-pipes.md)), the event executor, `liberx`'s signals over vCPU upcalls, and memory objects ([The POSIX-lite personality](design-programs.md#the-posix-lite-personality)) |
| `fork`, the `exec` family, the dynamic linker | in a program, the personality's second tier: `fork` as the session's copy of the sub-space, `exec` as the session replacing the image, and musl's dynamic linker adapted into the loader `erx_exec` to map file objects ([The second tier](design-programs.md#the-second-tier)) |
| abort and exit | `erx_space_stop(ERX_CAP_SELF, status)` after the crash path |
| CPU features (`getauxval` for `AT_HWCAP`, `AT_HWCAP2`) | the boot information page, or the startup message |

musl's Linux system-call layer (`__syscallN` and its 341 `SYS_` numbers) is
deleted, so no Linux system-call number exists in erXos. musl's `fork`
and `exec` over Linux's calls are deleted; the second tier's are written
for erXos over `liberx`, and musl's dynamic linker lives on as the loader,
which maps code only from file objects. Runtimes use no other descriptor than
standard output and error; programs get the POSIX-lite personality's
descriptors, spawn, pipes, `poll` and signals, written for erXos over
`liberx` in musl's tree. String, memory, character, conversion and
formatting functions, mallocng and `libm` stay as upstream
([research](research-c-library.md#musl-126)). Float conversion is not the
C library's: `sys/erxos` owns exact string-to-double and double-to-string
conversion, so float text never depends on which C library is linked.

**Thread cancellation.** `pthread_cancel` sets the target's cancel flag. On
Linux musl then sends the target `SIGCANCEL`; on erXos the canceller instead
stops the target with `erx_thread_stop`, reads its program counter with
`erx_thread_read`, and, if the target's cancel type is asynchronous or its
program counter lies in `[__cp_begin, __cp_end)`, sets the program counter
to `__cp_cancel` with `erx_thread_write`; it then runs the target again with
`erx_thread_start`. This is musl's own `cancel_handler`
(`musl/src/thread/pthread_cancel.c`) run from the canceller's side, with
the stopped thread's registers standing in for the signal's saved context.
The canceller holds `CONTROL` on its sibling threads, which share its space.
A target asleep in a umtx wait is woken by the stop and the call returns
`ERX_EINTR` ([design-kernel.md](design-kernel.md#execution-model-and-locking)),
which musl's `__syscall_cp_c` turns into cancellation. No futex or umtx
operation of its own is added for this: the stop already ends any blocked
call, and it also reaches a target that spins in an asynchronous cancel
window. A spurious `ERX_EINTR` from a wait outside a cancellation point is
what musl already tolerates from Linux signals: `__wait` re-tests its word
and sleeps again; `__timedwait` is retried by the mutex, read-write lock,
condition variable and `pthread_join` loops; `sem_timedwait` and
`aio_suspend` return `EINTR` to their caller, which POSIX allows for both.
`__timedwait` itself turns `EINTR` into 0 until a signal handler has been
installed. ERTS never calls `pthread_cancel`. The stopgap backend refuses
`erx_thread_stop` and its siblings with `ERX_ENOTSUP`
(`liberx/backend/core/refused.c`), so on Phase 1 a cancel acts at the
target's next cancellation point, as
[design-stopgap.md](design-stopgap.md) states.

### What ERTS imports

**One list of imports, checked at both links, is what makes the two C libraries
interchangeable under ERTS.** The objects of ERTS, `sys/erxos` and ethread
included, may import from outside themselves only the names in
`sys/erxos/imports.txt`:

* the `liberx` calls ERTS makes, each by name, so that a backend's internal name
  fails the check though the same library defines it;
* ISO C's memory, string, character, conversion, `math.h`, `malloc` family, `abort`
  and `exit`; `gmtime_r`, `localtime_r`, `mktime` and `tzset`; `getpagesize`;
* output through `stdout` and `stderr`;
* the pthreads calls for threads, attributes, mutexes, condition variables,
  read-write locks and keys, and `sched_yield`;
* a short section for each C library of the names its compile emits, such as
  `__errno_location` for musl and `__error` for libSystem.

A name check cannot read an argument, so the list holds no call that is safe only
for some arguments. stdio can name only `stdout` and `stderr`, since `fopen` and
`fdopen` are not listed. `erx_output_write(fd, bytes, length)`, in
`sys/erxos/erx_output.c`, has `write`'s signature and answers `EBADF` for any
descriptor but 1 and 2, and its object alone imports `write` (edit 37). `sysconf` is
off the list: the page size is `getpagesize()`, which takes no argument (edit 40),
`ethr_aux.c:231` is not compiled because both C libraries define
`PTHREAD_STACK_MIN` (`:226`), and edits 30 and 32 and the deleted `erl_poll.c` remove
the rest. A `sysconf(_SC_NPROCESSORS_ONLN)`, which musl answers with 1 where the
seam refuses the affinity call and libSystem with the host's count, fails the check.

`open`, `read`, `close`, `pipe`, `fcntl`, `socket`, `poll`, `select`, `sigaction`,
`fork`, `uname` and `getrusage` are not on it, so `sys/erxos` cannot assume a file
descriptor exists. Stock ERTS assumes it early: `erts_sys_pre_init` spins on
`open("/dev/null")` until it gets a descriptor above 2
(`sys/unix/sys.c:396-398`), which is forever where `open` fails with `ENOSYS`,
and it is where a stock interpreter image stops under the Phase 1 seam. The check
turns that class of stop into a build failure, on a Mac, before anything boots.

`make check-runtime-seam` reads the undefined symbols of the objects with `nm`
before each link, and fails on a name not on the list, naming the object. Then
"what libSystem answers and musl refuses" has no members: neither is asked. The
same check reads the native image's calls to `__erx_syscall` and fails on a
number the seam refuses, except a closed list of pairs of number and musl function
that musl copes with, each with its reason: `mremap` in `realloc`, `__map_file`'s
calls, `exit`'s `ppoll` and `clock_gettime`'s `gettimeofday`. A number the disassembly
cannot read is closed by the name check. An object with an `only_<object>` section of
`imports.txt` is read against that list as well, so a name one object needs, such as
`write` for `erx_output.c` or the timed wait of `erx_littlefs_nif.c`'s block
callbacks, reaches no other.

**How each refused call ends.** A probe linked an unmodified interpreter
`beam.smp` against the Phase 1 seam: 60 refused call names, plus an `unknown`
row. That row hides musl's cancellation points, whose number travels through
`__syscall_cp`: `read`, `write`, `close`, `openat`, `pread`, `pwrite`, `connect`,
`accept`, `recv` and `send` and their kin, `ppoll`, `pselect`, `epoll_pwait` and
`nanosleep`, some of which the 60 also name by another route. So the 60 are a
floor. The callers below come from the image's disassembly (direct calls only),
and each verdict from reading the caller. No group needs a new row of the seam.

| Group | Who calls them | `sys/erxos` | Sure? |
| --- | --- | --- | --- |
| **Files**, 24: `chdir`, `close`, `dup`, `dup3`, `faccessat`, `fadvise64`, `fchmodat`, `fchownat`, `fcntl`, `fstat`, `ftruncate`, `getcwd`, `getdents64`, `linkat`, `lseek`, `mkdirat`, `newfstatat`, `openat`, `read`, `readlinkat`, `renameat`, `symlinkat`, `unlinkat`, `utimensat` | `efile_*`; `fd_start`, `spawn_start`, `forker_*`; `erts_poll_*`; `inet_*`, `essio_*`, `esock_*`; `erl_crash_dump_v`, `erts_sys_pre_init`, `sys_tty_reset`; `display_string_2` | **Replaced** for `efile_*`, by `erx_prim_file.c`. **Deleted** with their callers for the rest (edits 26, 34, 35). musl's own: `__map_file` from `tzset` gets `ENOSYS` and musl uses UTC, and the hosted entry sets `TZ=UTC` so both builds agree; the stdio reads and seeks are unreached with no input stream | High |
| **Sockets**, 10: `bind`, `getpeername`, `getsockname`, `getsockopt`, `listen`, `setns`, `setsockopt`, `shutdown`, `socket`, `socketpair` | `inet_drv.c`, `prim_socket_nif.c`, `unix_socket_syncio.c`, `prim_net_nif.c`, `forker_start`; musl's resolver, reached only from those | **Deleted**: the `socket` and `net` NIFs and every driver but erXos's two (edit 26). `prim_inet:open` catches the refused port as `{error, eprotonosupport}` (`prim_inet.erl:103`, `:120`), and `inet_config` then takes the host name `nohost` (`inet_config.erl:223-241`) | High for the C. Medium that `kernel` boots with no socket driver: that path is read, the rest of its start is not |
| **Spawn**, 4: `clone`, `execve`, `pipe2`, `setsid` | `forker_start`, `spawn_start`; `pipe2` also from `erl_sys_args`, `erts_poll_create_pollset`, `erts_sys_is_area_readable` and ethread's `setup_nonblocking_pipe` | **Deleted**, ethread's by edit 31. `erts_sys_is_area_readable`, which only the crash dump asks, answers 0, so a dump leaves out the stacks it cannot prove readable | High |
| **Poll**, 6: `epoll_create1`, `epoll_ctl`, `ppoll`, `timerfd_create`, `timerfd_gettime`, `timerfd_settime` | `erts_poll_*`; musl's `__init_libc`, only for a secure start, which the start block does not ask for; musl's `exit`, whose second caller loops on it until the first ends the machine | **Deleted**, for the event table (edits 3, 22). `select` in `erts_sys_main_thread` and `erts_milli_sleep` is **replaced** by an unbounded and a timed umtx wait on a private word | High. The second `exit` caller spins instead of sleeping, for a moment, on the way to the end |
| **Signals**, 2: `rt_sigaction`, `setitimer` | `sys_signal`, `erts_set_signal`, `init_break_handler`, `sys_init_suspend_handler`, `erts_sys_unix_later_init`; `alarm` in the crash path | **Deleted**. `os:set_signal/2` is `badarg`; only `prim_tty_sighandler`, on the terminal path erXos does not take, calls it (`prim_tty_sighandler.erl:29-30`) | High |
| **Memory**, 3: `madvise`, `mlockall`, `mremap` | `erts_mem_discard` from `abandon_carrier` and `mbc_free`; `erts_alloc_init`; `erts_mremap` and mallocng's `realloc` | **Deleted**: the cross-compile file pins `HAVE_MADVISE` and `HAVE_MLOCKALL` off, which leaves `erts_mem_discard` empty and `+Mlp` refused; edit 19 removes `os_mremap`, so `erts_mremap` shrinks in place or moves a segment by copying it. mallocng copies when `mremap` fails (`realloc.c:33-35`) | High. Discarded carrier pages stay committed: a memory cost, not a fault |
| **Information**, 11: `clock_getres`, `getpriority`, `getrlimit`, `getrusage`, `gettimeofday`, `prlimit64`, `sched_getaffinity`, `sched_setscheduler`, `setpriority`, `sysinfo`, `uname` | `sys_init_time`; `nice` in the crash path; `sysconf` for limits from `erts_poll_init` and `inet_drv`; `erts_runtime_elapsed_both`; `clock_gettime`'s own fallback; `erts_cpu_info_update`; `pthread_create` with an explicit policy, which ethread never sets; `init_get_monotonic_time`, `os_flavor`, `os_version` | **Replaced**: time by the time page (edit 20), CPU counts by the page (edit 32), CPU time by the group's usage (edit 33), the clock check gone (edit 30), `os_flavor` and `os_version` by constants. **Unreached**: `gettimeofday`, `sched_setscheduler`, `sysinfo`, and the limits once their callers are gone | High, with two traps closed by name: stock `erts_runtime_elapsed_both` ends the runtime when `getrusage` fails (`erl_time_sup.c:1434`), and `sysconf(_SC_NPROCESSORS_ONLN)` silently answers 1 when `sched_getaffinity` is refused (`musl/src/conf/sysconf.c:204-209`) |

What a read cannot settle, and what settles it:

* **A call through a function pointer** is invisible to the disassembly above. The
  import check closes it by name at link, and any remaining number shows at the `default:` of `__erx_syscall`, which a
  temporary trace there shows.
* **Which of OTP's suites need `statistics(runtime)`.** Of `kernel` and `stdlib`,
  `dist_util` alone calls it, and the suites are unread. Of the `compiler` suites, only `inline_SUITE`'s
  `smith` calls it, to time itself, and fails with `notsup` on the hosted runtime. A `notsup` that the oracle comparison shows to
  matter gets a body in the Fiasco backend, from `l4_thread_stats_time`.
* **The contents of `imports.txt`.** The categories above come from reading ERTS;
  the names come from the first link.

### liberx

`liberx` is the library through which every runtime and native program
reaches the kernel, and the only code that may issue a kernel call
([design-kernel.md](design-kernel.md#chokepoint-checks)). It has five
layers:

* **Calls**, generated from `abi/erx_abi.txt`: one C function per kernel
  call, and per backend an implementation. Every argument of a call is a
  value, in one of three places: a capability, number or flag in the
  call's registers; a field of a request with more fields than the
  registers carry, in the calling thread's UTCB, which the caller fills
  through the generated UTCB accessors before the call; or a request
  larger than the UTCB, in a **memory window**, a capability to a memory
  object the caller holds and fills, with an offset and a length, which
  the kernel reads and writes through its own mapping of the object
  (`erx_window_read`, `erx_window_write`). Results come back
  in the result registers and the UTCB. An address a call reserves or maps
  is a number the kernel writes into page tables, never one it reads
  through, so no stub takes or passes a pointer for the kernel to
  dereference, and the kernel never reads or writes a domain's memory at
  an address the domain supplied
  ([design-kernel.md](design-kernel.md#calling-convention-and-status-codes)).
  The `erx` backend is a trap stub per call, in the system-call
  convention of the architecture's `abi/arch/<arch>.txt`.
  The `fiasco` backend maps each call onto the near-stock Fiasco's
  invocations from user mode, and refuses what Fiasco cannot offer
  ([design-stopgap.md](design-stopgap.md)).
  The `hosted` backend implements the interface inside a macOS process:
  spaces are the process, threads are pthreads, memory objects are
  `mmap`ped regions, umtx waits are `os_sync_wait_on_address`, groups and
  parking are condition variables with the same epoch protocol, and
  quotas are accounted but enforced only by a watchdog thread.
* **Lanes and the funnel**: `erx_lane`, the producer's and consumer's
  sides of a lane over its ring and reader page, with `erx_lane_take` as
  the only reader of a ring and a consumer's **drain word**, which one
  executor at a time takes with a compare-and-swap to drain a lane, so a
  lane has one consumer however many executors answer its bell
  ([design-domains.md](design-domains.md#the-peer)); `erx_funnel`, the
  structural and authority validation of a frame against a lane's peer
  and an export lookup the
  caller supplies, in a frame mode for connections and a channel mode for
  programs; and `erx_etf`, an encoder and decoder of the frame grammar
  with the funnel's limits, for native code on a channel
  ([design-domains.md](design-domains.md#the-funnel)). The funnel is one
  C17 library, linked by ERTS and by every program and shim, fuzzed and
  checked differentially against `binary_to_term/1`.
* **Devices**: the DMA envelope, which sequences registers, cache
  maintenance, descriptors and interrupt acknowledgement in their one
  valid order with a device's generated register accessors, and whose
  Erlang face is the device NIF ([The device NIF](#the-device-nif)).
* **The system layer**: the root-task entry and the domain library,
  linked only into the interpreter image, which the system domain runs,
  C17 under the kernel-construction rules
  ([The root-task entry](#the-root-task-entry)).
* **Programs**: the loader (`erx_elf_plan`, `erx_exec`), the channel
  client, the descriptor table and its objects, the startup message, the
  event executor, the signal machine, and the POSIX-lite personality
  ([Native programs](design-programs.md)).

### The root-task entry

The kernel starts one user-mode task, the system domain, on the root
entry point of the interpreter image for a full boot or the native C17
root-entry image for a development partial boot, with the root capabilities at
well-known slots of its table and the machine page mapped
([design-kernel.md](design-kernel.md#the-root-task)). The entry is
`liberx`'s `erx_root_main`, in the system layer. Everything it does
before ERTS starts, the sealing secret's derivation and the end of the
device secret among it, is the system domain's bootstrap, which
[design-system.md](design-system.md#the-root-task) defines, in order,
with its tests.

What the runtime sees of it is a domain's start like any other. The
entry's own thread becomes ERTS's main thread on a boot information page
in the layout every domain receives ([Data model](#data-model)), flagged
`ERX_BOOT_ROOT`, with domain id 4, the node name `system@<host>` and
`system` as its runtime group, and
continued by the root capabilities in the page's root extension, which
only this page has; by then the system domain's space maps neither the
device-secret page nor the sealing page. So ERTS's start-up is one code
path in every domain. The first worker belongs to `system` from creation;
the root entry's fault worker and every executor and worker ERTS creates,
including the executors running the watchdog, belong to that same group. The root
capabilities name that group for resource policy; runtime startup never
migrates a thread between groups. There is no separate runtime quota
beneath the aggregate system grant.
ERTS boots the system release: the domain service,
the device service, the drivers, storage, the network, the vault, the
console, login.

**The domain library** is the C that creates, inspects and ends domains,
called from the domain service through the `erx_domain_lib` NIFs; its
entries, each a plan validated whole before anything is applied, and
the rules they keep are
[design-system.md](design-system.md#the-domain-library)'s. What the
runtime sees of it: the NIFs are dirty CPU NIFs, long, since a creation
makes many kernel calls, but never waiting, so they run on executors and
block no scheduler; and a domain's faults and ends arrive at the
library's fault thread, which serves the fault gate every domain names
and reports `{domain_ended, Id, End, Record}` to the domain service
([design-system.md](design-system.md#ending-a-domain)), while the
runtime's gate worker serves only the fault gate of the system domain's
own sub-spaces, as in every domain ([The event table](#the-event-table)).

**The watchdog.** The kernel keeps one watchdog, configured by
`erx.watchdog=P,D,B`, which it arms with the boot deadline `B` when it
starts the root task and which the system domain pets with
`erx_watchdog_pet`, each pet setting the deadline `D` ahead; a missed
deadline ends the machine as a fault would, by `erx.panic`
([design-kernel.md](design-kernel.md#the-watchdog)). `erx_watchdog`, a
process at priority `max` of the system release's `kernel`, makes a
liveness call each period `P` to every service the system configuration
lists for it, the domain service and the device service at least, and
calls the watchdog NIF from a normal scheduler only once each has
answered within the period, so a pet proves that ERTS's schedulers run,
its timers fire and those services serve. A service that does not answer
is killed, its supervisor restarts it, and the pet follows its first
answer; a runtime that cannot run the watchdog process, or a service
that never answers again, misses the deadline
([design-system.md](design-system.md#boot)). In a partial boot, which a
development manifest asks for in a field the root-task entry reads, no
ERTS runs, and the root-task entry pets the watchdog from its own thread
at the period `P`. In deterministic mode the watchdog is off and the
process is not started.

### Native programs

A native program runs in a sub-space of its session's domain, with musl
and `liberx`'s POSIX-lite personality as its C library; how programs
start, inherit, signal one another and end, and the personality itself,
are [design-programs.md](design-programs.md). The runtime takes part in
three places: the program driver ([Programs as ports](#programs-as-ports)),
the pipe NIF ([The console and standard I/O](#the-console-and-standard-io)),
and the **command image**, the interpreter image in **program mode**,
running the command shell's release in a command domain that the system
domain creates for the session and introduces to it
([design-programs.md](design-programs.md#what-a-program-can-start)).
In program mode the runtime boots no system services and no shell of its
own: it takes the first `erx_start` message that arrives from the handler
its arguments name, over their connection, and ignores any other sender's;
decodes it with the generated validator; builds the namespace, facets and
standard streams the message names; and runs either `rc` with a script
or one Erlang command with exactly those capabilities in its context,
then halts with the status the command or `rc`'s `$status` gives. The
interpreter image keeps a command domain out of the JIT spaces, so a
command domain makes no code, as no program does.

### Hosted mode

Both runtime images, the system services and native programs build for
macOS against `liberx`'s hosted backend, as one process per domain or
all domains in one process. They run under ASan, UBSan and TSan and under `lldb`, with
OTP's suites and erXos's own, for fast iteration. QEMU remains
authoritative: a test that passes only hosted is not a pass.

**A hosted runtime links macOS's libSystem, not musl.** A macOS process owns its
thread pointer register and needs libSystem for `pthread_create` and the
sanitizers, and musl finds its thread descriptor through that register, so a
second C library in the process is not on offer. musl's seam is under ERTS only
natively. `sys/erxos` sits directly on `liberx` on both backends.

**Nothing in `sys/erxos` differs between backends.** It is the same list of
files with no conditional on the backend, and a source check fails on one naming
`__APPLE__`, `__DARWIN__`, `__linux__` or a backend. What must differ lies below
or beside it, in a closed set of places, and anything else that differs is a bug:

| What differs | Where | Why it stays there |
| --- | --- | --- |
| Who fills the boot information page and calls `erx_runtime_main` | the entry: `liberx/backend/fiasco/runtime_entry.c` and `runtime_main.c`, `liberx/backend/hosted/start.c` | ERTS's start reads only the page ([design-stopgap.md](design-stopgap.md#boot-information)) |
| The bodies of `liberx`'s calls | `liberx/backend/fiasco`, `liberx/backend/hosted` | one function API, one test set, the differences listed in [The hosted backend](design-stopgap.md#the-hosted-backend) |
| The C library under the import list | musl, libSystem | [What ERTS imports](#what-erts-imports) checks both links against one list |
| The console's driver process and its NIF | `erx_stdio_nif`, in the hosted image's static NIF list | [The console and standard I/O](#the-console-and-standard-io) |
| Compile and link lines, and configure's answers about the C library | one cross-compile file per target | below |

**The hosted build is a second cross target.** Configure runs in cross mode on both,
for `aarch64-unknown-erxos` and for `aarch64-hosted-erxos`, whose compiler targets
macOS, so `host_os` is `erxos` in both and none of `erts/configure.ac`'s `darwin*`
cases apply; `ERLANG_OSTYPE` is `erxos` from one new case at `configure.ac:911-913`.
Each target's cross-compile file gives the compiler, flags and libraries and pins
the same answers. `make check-runtime-seam` compares the two `config.h` and
`ethread_header_config.h` files, and fails on a difference outside a short list,
each entry with its reason.

Cross mode means configure runs no test program, so each answer it cannot find
by linking comes from an `erl_xcomp_` value in the cross-compile file. On the
hosted target `otp/xcomp/erl-xcomp-aarch64-hosted-erxos.conf` names the compiler,
the SDK as the system root and the hosted `liberx` archive in `LIBS`, and selects
OTP's built-in zlib, so both targets build the same zlib.

### The build

The top-level `Makefile` and `tools/erx` are erXos's build. They invoke
ERTS's machinery through one entry point, `tools/erx build runtime`, which
runs OTP's `configure` with the `aarch64-unknown-erxos` target and the
build's cross-compilation file, once per image, with the JIT disabled for
the interpreter image, then OTP's `make` for the emulator, the preloaded
modules and the applications erXos ships. ERTS's Perl generators run as
part of that. The outputs are the two runtime images, each a static
position-independent executable that the packer turns into a boot-image
entry with a manifest, the BeamAsm image's alone marked `ERX_IMAGE_JIT`,
and the hosted executables. A build check fails when the interpreter
image links a symbol of BeamAsm, asmjit, libc++ or libc++abi. Erlang code
is compiled with the host OTP's `erlc` of the same release, built from the
pinned tarball ([design.md](design.md#build-and-toolchain)), which is also where
OTP's cross build finds `yielding_c_fun`. The build runs in a private copy under
`build/runtime`, because OTP's make writes into its source tree.

It builds `erts/emulator` and each application directly, not through OTP's
top-level `emulator`, `libs` and `start_scripts` targets. Those reach parts the
import leaves out: every program of `erts/etc`, `erlexec` included, includes `ei.h`
from `lib/erl_interface`, `lib/tools` includes `public_key.hrl`, and
`erts/start_scripts` reads `lib/os_mon/vsn.mk`. The runtime is started without
`erlexec`. On the hosted target the emulator is `bin/aarch64-hosted-erxos/beam.emu`.

## Interfaces

### The adapter

The adapter lives in `otp/erts/emulator/sys/erxos/` and is the only part of
ERTS that includes a `liberx` header. Its safe-point logic is a pure
function, built and tested on the host; the scheduler calls a thin effect
layer around it:

```c
/* What an executor saw at a safe point. */
typedef struct erx_rt_seen {
	uint32_t	ready;		/* IRQ objects on the group's ready list */
	uint32_t	cap_seq;	/* capacity sequence in the status area */
	uint32_t	cap_mcpu;	/* capacity in milli-CPUs */
	uint32_t	acted_seq;	/* capacity sequence last acted on */
	uint32_t	online;		/* normal schedulers online */
	uint32_t	limit;		/* schedulers_online as Erlang code set it */
	uint32_t	total;		/* normal schedulers created */
	erx_urgency_t	published;	/* urgency in this executor's control line */
	erx_urgency_t	wanted;		/* urgency of the most urgent work it holds */
} erx_rt_seen_t;

/* What to do about it, in the order listed. */
typedef struct erx_rt_plan {
	bool		take_ready;	/* take the group's ready list and dispatch
					 * each label through the event table */
	bool		set_online;
	uint32_t	online;		/* if set_online: in 1 .. min(limit, total) */
	uint32_t	acted_seq;	/* the sequence this plan acts on */
	bool		publish;
	erx_urgency_t	urgency;	/* if publish */
} erx_rt_plan_t;

erx_rt_plan_t	erx_rt_decide(const erx_rt_seen_t *seen);

void		erx_rt_safe_point(struct erx_rt_exec *x);
erx_status_t	erx_rt_park(struct erx_rt_exec *x, erx_time_t deadline);
void		erx_rt_wake(uint8_t slot);
void		erx_rt_defer_enter(struct erx_rt_exec *x);
void		erx_rt_defer_leave(struct erx_rt_exec *x);

/* The event table. */
typedef enum erx_sink_kind { ERX_SINK_PORT = 1, ERX_SINK_PROCESS } erx_sink_kind_t;
uint32_t	erx_event_register_port(Eterm port_id);
uint32_t	erx_event_register_process(Eterm pid, Eterm message);
void		erx_event_unregister(uint32_t label);
```

* `erx_rt_decide` reads nothing but its argument. It takes the ready list
  when `ready` is not zero; its plan's `online` is the capacity rounded up
  to whole CPUs, clamped to `1 .. min(limit, total)`; it publishes when
  `wanted` differs from `published`. It is total over its input.
* `erx_rt_safe_point` gathers an `erx_rt_seen_t` with one load of each
  status field, calls `erx_rt_decide`, and applies the plan. It is called
  only from `erts_schedule` and before parking, with no lock held (R1).
* `erx_rt_park` returns `ERX_OK` when woken or when an epoch had moved, and
  `ERX_ETIMEDOUT` at the deadline. The caller has already run thread
  progress's `prepare_wait` and runs `finalize_wait` after it.
* `erx_rt_wake` is `erx_executor_wake` for a slot of the caller's own group;
  it is called only when the target's sleep flags say it is parked or
  about to park.
* `erx_rt_defer_enter` and `erx_rt_defer_leave` nest; `leave` at depth zero
  checks `yield_req` and yields if set. Both are inline stores into the
  caller's own control line, and do nothing when the group lacks
  `ERX_GROUP_DEFER`.
* The event table's registration returns the label to bind an IRQ object
  with; a port's entry goes when the port closes and a process's when the
  process exits, which the table monitors, and `erx_event_unregister`
  removes one early.

### The liberx interface

`liberx` is a static library in `liberx/`, linked into every program that
runs on erXos. Its interface:

* **Kernel calls**, generated from `abi/erx_abi.txt`: `erx_<call>(...)`,
  one function per call, taking values alone, with a request larger than
  the registers in the caller's UTCB, filled through the generated UTCB
  accessors, or in a memory window named by capability, offset and
  length. A call without results returns its `erx_status_t`; a call with
  results returns them by value, in a structure the generator defines for
  the call, whose first field is the status, read from the result
  registers and the caller's UTCB. A generated stub never takes a pointer
  parameter, which the generator checks. They keep no state, allocate
  nothing, set no `errno`, and may be called from any thread. Contextual
  error translation is generated for the program/service consumers that
  need it, outside these raw stubs
  ([design-generation.md](design-generation.md#inspection-and-diagnostics)). The
  generated header also defines every status code, right, flag, limit and
  shared layout, the UTCB's included.
* **Boot information**: `const erx_boot_info_t *erx_boot_info(void)`,
  validated once at start-up (version, ABI version, offsets and lengths
  inside the page); a page that fails ends the program with a diagnostic
  on the debug log. ERTS reads this page and never `argv` or `environ`:
  `erx_runtime_main`, `sys/erxos`'s entry on every backend, takes no
  arguments.
* **Shared memory access**: `erx_shared_load_u8`, `erx_shared_load_u32`,
  `erx_shared_load_u64` and their store counterparts for the group's
  shared areas and the UTCB, the same accessors the kernel uses on memory
  user mode can write, and `erx_shm_copy` for a lane's or pipe's pages.
* **Lanes**: `erx_lane_put(lane, iov, n)`, which writes one record or
  reports no room; `erx_lane_take(lane, buf, max)`, which copies the next
  record out or reports none; `erx_lane_room_wanted` and
  `erx_lane_sleeping`, which read once the position the peer published,
  `need` in its ring header or `wake` in its reader page, and tell whether
  the caller's store crossed it; and the publication of the position the
  caller waits for, in its own page alone
  ([design-domains.md](design-domains.md#connections)).
* **The funnel**: `erx_funnel_check(frame, len, peer, mode, lookup, ctx,
  &verdict)`, pure over the copied frame and the lookups it makes; the
  verdict is accepted, unheld with the operation and target, or malformed
  with a reason code. `erx_etf` encodes and decodes terms of the grammar.
* **Devices**: the DMA envelope and generated register accessors
  ([design-system.md](design-system.md#devices)).
* **The system layer**: `erx_root_main`, the root-task entry, and the
  domain library's entries, each a plan then an application
  ([design-system.md](design-system.md#the-domain-library)).
* **Programs**: the POSIX-lite personality under musl, the channel client,
  the loader, the event executor and the signal machine
  ([Native programs](design-programs.md)), and the
  descriptor table's file objects ([design-files.md](design-files.md)).

### Erlang-visible behaviour

Everything not listed behaves as stock OTP 29.1.2.

| Function | In erXos |
| --- | --- |
| `os:type/0` | `{unix, erxos}`, so `filename` and every module that keys on the OS family treat paths as POSIX |
| `os:version/0` | erXos's version as `{Major, Minor, Release}` |
| `os:getpid/0` | the domain id, as a decimal string |
| `erlang:pid_to_list/1`, `erlang:port_to_list/1`, `erlang:ref_to_list/1`, `list_to_pid/1`, `list_to_port/1`, `list_to_ref/1`, and pids, ports and references printed by `io` and `io_lib` | `<D.N.S>`, `#Port<D.N>` and `#Ref<D.a.b.c.d>` with the owner's domain id, the creation of its node, local ones included, where stock OTP prints 0 for its own node and the node name's atom index for another; the one documented difference in a node's identity ([Connections in ERTS](#connections-in-erts), [design-domains.md](design-domains.md#domain-ids-pids-and-references)) |
| `os:cmd/1`, `open_port({spawn, _}, _)`, `open_port({spawn_executable, _}, _)`, `open_port({fd, _, _}, _)` | `badarg`, which `os:cmd` raises with the cause `{open_port, badarg}`: ports wrap no operating-system process or descriptor; a program is a port a session's command server opens through `erx_program` ([Programs as ports](#programs-as-ports)) |
| `open_port({spawn_driver, Name}, _)` | only the linked-in drivers: `erx_lane` and `erx_program`, which `erx_connections` and `erx_program` open, and `ram_file_drv`, which `ram_file` opens; any other name is `badarg` |
| `os:getenv/0,1`, `os:putenv/2` | an environment per domain, initialised from the domain's specification |
| `os:set_signal/2` | `badarg`; there are no UNIX signals |
| `erlang:system_info(emu_flavor)` | `emu` in a domain that runs the interpreter image, the system domain and command domains among them; `jit` in one that runs the BeamAsm image |
| `erlang:system_info(schedulers)` | the normal schedulers created: the cpuset's CPU count, at most 32 |
| `erlang:system_info(schedulers_online)` | follows the group's capacity, rounded up, within the limit Erlang code set |
| `erlang:system_flag(schedulers_online, N)` | sets the limit and returns the previous value online; the value online is then the lower of the limit and the capacity |
| `erlang:system_info(logical_processors_available)` | the CPU count of the group's cpuset |
| `erlang:system_flag(scheduler_bind_type, _)` | raises `notsup`, as ERTS does where binding is unsupported; executors are pinned by the adapter, or unpinned with `+sbt u` |
| `erlang:halt/0,1` | the domain stops itself with the status; in the system domain, the machine shuts down ([Crash handling](#crash-handling)) |
| `erlang:halt/1` with a string | a crash dump with that slogan, then the domain stops ([Crash handling](#crash-handling)) |
| `erlang:load_nif/2`, `erl_ddll` | only NIFs linked into the domain's runtime image; any other load is refused by `erl_erxos_sys_ddll.c`, which reaches no dynamic linker, with `{error, {load_failed, Text}}` and `{error, no_ddll_available}` |
| `code:load_binary/3`, `erlang:load_module/2` in the system domain | `{error, not_installed}` unless the module is installed storage ([Code in the system domain](#code-in-the-system-domain)) |
| `file`, `prim_file` | the release file system read-only at `/`, EROFS images read-only where a release mounts them, a RAM file system at `/tmp` ([Files](#files)) |
| `gen_tcp`, `gen_udp`, `socket`, `net` | served by the network service through the domain's grant of it, whose design maps each call ([design.md](design.md#networking)); without a grant, `{error, eacces}`, as POSIX's `socket` answers a refused protocol |
| `gen_sctp` | `{error, enotsup}`: the network stack has no SCTP |
| `node/0`, `node/1`, `nodes/0,1`, `erlang:system_info(creation)` | stock semantics: the domain is the node `<id>@<host>` with its domain id as creation, a pid's node is its domain's, and `nodes()` lists the domains this domain is connected to ([Connections in ERTS](#connections-in-erts)) |
| distribution | `net_kernel` runs in every domain with the `erx` carrier, no port mapper and no cookie; a send, link, monitor or spawn toward a domain this domain has no connection with behaves as toward a node that cannot be reached, since `erx_dist` makes no connection; `monitor_node/2`, `net_kernel:monitor_nodes/1` and `erlang:disconnect_node/1` keep their stock semantics; an exposed domain reaches other machines over the network service under the same name ([design-domains.md](design-domains.md#domain-ids-pids-and-references)) |
| `net_ticktime`, `net_kernel:set_net_ticktime/1,2`, the `net_tick_timeout` reason | a connection between domains has no tick supervision: the carrier reports no ticks, `net_kernel`'s tick timer does not apply to it, and a peer silent past `net_ticktime`, or starved of CPU that long, stays connected ([Connections in ERTS](#connections-in-erts)); the settings keep their stock meaning for the connections of other carriers |
| `rpc:call/4,5`, `rpc:cast/4`, `rpc:multicall`, `rpc:async_call/4`, `erpc` | work toward a domain where the caller may spawn, since they run through `spawn_request`, which the frame grammar carries; toward any other domain the call fails as a spawn into it does, with `noconnection` |
| `net_adm:ping/1` toward a node of the machine | `pong` when the node is `node()` or in `nodes()`, `pang` otherwise, from that list alone: no call to the peer's `net_kernel` and no disconnect (edit 28). `erlang:disconnect_node/1` of the system domain's node keeps its meaning: the domain's system connection ends, and with it the domain |
| `rpc:block_call/4,5`, `rpc:abcast/2,3`, `rpc:sbcast/2,3`, `rpc:server_call/4`, `rpc:multi_server_call/2,3` toward another domain | they address a registered name (`rex` or the caller's), which never crosses a domain: `block_call` returns `{badrpc, {'EXIT', {noproc, _}}}`; `abcast` writes no frame; `sbcast` and `multi_server_call` list the domain among the bad nodes; `server_call` returns `{error, nodedown}` ([design-domains.md](design-domains.md#compatibility-and-migration)) |
| `global`, `pg` | see only the local node: neither spans domains, by design. A name registry shared across domains would let any domain register or join any name, so a send to a registered name (`REG_SEND`) is outside the frame grammar ([design-domains.md](design-domains.md#the-funnel)): `{Name, Node} ! Msg` toward another domain is dropped at the sender, and `monitor(process, {Name, Node})` gets a `DOWN` with reason `noproc` at once. A name one domain offers another is an export its owner's runtime writes ([design-domains.md](design-domains.md#exports)). `kernel`'s `connect_all` is `false` in every erXos release, so `global` attempts no fully connected network and disconnects no node |
| a message larger than the connection's lane allows | `system_limit` from the send, ERTS's own too-large path |
| `erx:export/3` | added: `erx:export(Name, Rights, Peer)` sets what a peer holds on the caller's own pid, an alias it owns, or from `init` the domain, to exactly `Rights`, widening or narrowing; only the owner grants, and an encode gives a peer `send` alone ([Connections in ERTS](#connections-in-erts)) |
| `erx:origins/1` | added: `erx:origins(true)` delivers each message from another domain to the caller as `{erx_origin, D, Msg}`, `D` the lane's peer ([design-domains.md](design-domains.md#facets)) |
| `erx_program:start/1`, `send/2`, `install/2`, `pause/1`, `resume/1`, `stop/3`, `fork/2`, `exec/2`, and `{Port, {exit_status, N}}`, `{erx_channel, Port, Request}`, `{erx_channel_room, Port}` | added: the program driver's interface ([Programs as ports](#programs-as-ports)) |
| `erx_device` | added: the device NIF ([The device NIF](#the-device-nif)) |
| a NIF that blocks on a normal or dirty CPU scheduler | the blocking call fails with `ERX_EWOULDBLOCK`, which the NIF reports as an error ([NIFs and blocking](#nifs-and-blocking)) |

### Configuration

A domain's runtime takes its arguments from its specification through the
boot information page, as `erl_start` reads them: emulator flags, `--`, then
`init`'s arguments. There is no `erlexec`. Its conversion (`+` rewritten to `-`
and emulator flags gathered ahead of the `--`, `erlexec.c:943-965`; `-root`,
`-bindir` and `-progname` placed after it, `:1151-1161`) serves people typing at a
shell, and here would be a table of flags and a second grammar in `sys/erxos`,
when a specification is written once and can say `-S 2:2`. A word in the wrong
form stops in `erts_usage`: `+S` fails the test at `erl_init.c:1357`, and `-root`
ahead of the `--` is taken as `-r` (`:2293`) and its path then fails that test.
`erx_runtime_main` builds the vector:
`argv[0]` is `beam`, which only the usage message prints (`erl_init.c:826`); the
words are copied to writable memory, since the page may be read-only and
`erl_start` edits its vector (`-M` flags are removed from it); and the page's node
name follows them, as `-name` under a dotted host and `-sname` otherwise.

The system release's arguments are:

```
-- -root / -bindir /bin -progname erl -home / -boot /bin/start
-user erx_console -nocookie -kernel start_distribution false
```

`init` exits without `-bindir` (`init.erl:1235`), though nothing is read from it.
`-home` answers `filename:basedir` and `c`, as no `HOME` exists. `-user` replaces
`user_drv`, which loads the removed NIF (`user_drv.erl:182`), with `erx_console`,
and `user_sup` waits ten seconds for it to register `user` (`user_sup.erl:105-119`).
A release with a carrier replaces `-kernel start_distribution false` with
`-no_epmd -proto_dist erx`, and `-nocookie` then spares `auth` from reading or
creating a cookie, which a read-only release with no `HOME` cannot satisfy and
whose mode `0444` it refuses (`auth.erl:347-374`, `:513`).

`kernel_sup` then starts these, in stock's order with `erx_watchdog` added right after `on_load` (edit 41):

| Child | In erXos |
| --- | --- |
| `code_server`, `file_server_2`, `on_load` | stock: the first two over `erl_prim_loader` and the release file system |
| `erx_watchdog` | [design-stopgap.md](design-stopgap.md#the-watchdog) |
| `inet_db`, `erl_signal_server`, `logger_sup`, `kernel_config`, `kernel_refc`, `kernel_safe_sup` | stock: `inet_db`'s lookup is `file`, its hosts table, with no resolver and no `inet_gethost` until the network service, `inet_gethost_native` answering `{error, notsup}` for a well-formed lookup, `localhost` too when this module is asked directly, since none ran, where stock answers `{error, notfound}` for a name its resolver does not know; `inet`'s calls read any error as not found and still answer `nxdomain`, and the difference is `inet_SUITE:t_gethostnative`'s, which accepts neither; and `inet_config` finding no UDP port names the host `nohost` |
| `standard_error` | stock's I/O protocol over descriptor 2 (edit 39) |
| `user` | `user_sup`, then `erx_console` and the group it registers |
| `rex`, `global_name_server`, `global_group` | stock, with or without a carrier, as on a stock node that is not distributed: a name `global` registers without a carrier is known on this node alone (edit 41) |
| `net_sup` | with a carrier only: `net_sup` holds `auth` and `net_kernel` over `erx_dist`, with no `erl_epmd`; `-kernel start_distribution false` leaves it and `dist_ac` out (edit 41) |

The adapter's defaults and limits follow, in `erl`'s familiar spelling; a
specification writes each `+` as `-`:

| Flag | In erXos |
| --- | --- |
| `+S N:M` | lowers the schedulers created and the limit online; never above the cpuset's CPU count or 32 |
| `+SDcpu N:M` | lowers the dirty CPU schedulers; never above the normal schedulers |
| `+SDio N` | dirty I/O schedulers, workers; ERTS's default of 10 |
| `+sbt u` | executors unpinned, placed by the kernel at each wake; any other value pins in cpuset order |
| `+sbwt`, `+sbwtdcpu`, `+sbwtdio`: `none` (default) or `very_short` | busy waiting before parking, which spends the group's quota; longer settings are clamped to `very_short` |
| `+JPperf`, `+JMsingle` | ignored with a warning: there is no `perf`, and a mapping is never writable and executable at once |
| `-erx lane_batch N` | frames one drain of a connection takes before it clears the drain word and leaves the rest for the next safe point |
| `-erx queue_quota N` | the queue quota of each process of a domain outside the system domain: the bytes of undecoded frames from other domains queued on it past which the drain leaves the next frame for it in the lane; unset by default, so a process's queue grows until its `max_heap_size`, as in stock OTP; the system domain ignores it and takes each process's quota from its facet's grant or the manifest's `system_queue` ([design-domains.md](design-domains.md#flow-control)) |

## Compatibility and migration

The same `.beam` files run on the host and in erXos: code compiled by the
host's OTP 29.1.2 `erlc` loads in both images, and the loader checks the
BEAM format as ERTS does. Everything an application observes beyond the
table above is ERTS's behaviour, checked against stock OTP by OTP's own
suites.

Nothing a runtime writes outlives the boot, so there is no state to
migrate. The boot information page and the crash header carry versions,
and each runtime image's manifest records the ABI version it was built
against; the domain library refuses an image whose ABI version differs
from the kernel's ([design-kernel.md](design-kernel.md#image-manifests)),
since the kernel, `liberx` and every runtime are built from one tree.
Until a release promises compatibility, a change to one of these layouts
replaces it outright: no runtime reads an earlier version, and a version
field serves only to make a mismatch fail loudly. The two kernel
backends of `liberx` expose the same calls, so each runtime image runs on
the stopgap and on erXos's kernel unchanged; a runtime that compares results
across them is the conformance suite.

## Failure handling, diagnostics and debuggability

| Failure | Detection | What remains | Who cleans up | What the user sees |
| --- | --- | --- | --- | --- |
| ERTS fatal error in a domain | `erts_exit`, an assertion, an exhausted table | the dump in the crash area; an exit record | the domain service, through the domain library | links, monitors and the domain pid fire with `{domain_down, D, crash}`; the slogan in the death record and the dump in the inspector |
| A domain faults (a NIF's wild pointer, a stack overflow into a guard page) | the kernel's fault classifier | the domain's threads, stopped; a fault record | the domain service ends the domain or keeps it for inspection | the fault record, registers and backtrace in the inspector |
| The system domain's runtime faults or halts outside an ordered shutdown | the kernel | the crash record, brief in a release build and full in a development build | the kernel ends the machine by `erx.panic`, a reset in release builds | the crash record on the UART, or in the surviving region at the next boot, which the inspector shows only to the system shell |
| The domain's budget is exhausted | `erx_vm_commit` returns `ERX_ENOMEM` | nothing committed | ERTS's allocation-failure path, which is fatal | as an ERTS fatal error, with the allocator named in the slogan |
| A facet exceeds its `max_heap_size` | ERTS's heap limit, queued frames counted | the facet killed; its lane holding what it did not take | the facet's supervisor restarts it | the grantee's calls fail with the facet's exit; a log line |
| The group's quota is exhausted | the kernel throttles | nothing fails | none needed | slower progress; throttling counters in the inspector |
| A blocking call from an executor | `ERX_EWOULDBLOCK` | nothing changed | none needed | the NIF's error; a trace event naming the call, which the inspector counts per call site |
| A lane's positions or a frame fail their checks | `erx_lane_take`'s checks; the funnel | the ring unread past the bad record | the lane driver closes the port; `erx_connections` reports it; the system domain takes the connection down for both | `noconnection` on everything across the connection in both domains; a log line naming the peer and the reason; the peer is a bug suspect |
| A peer stops taking frames | the lane is full | the frames in the ring, and the rest in the entry's queue | none needed | once the entry's queue passes ERTS's busy limit, the senders to that peer are suspended, as toward a busy distribution connection; in the system domain no sender is suspended, a message past the manifest's `system_queue` is dropped and counted, and any other signal ends the connection |
| A process stops taking its messages from other domains | its queue quota, where it has one | its undecoded frames up to the quota and one more, then the frame for it and those behind it in the lane they share | none needed | the drain takes nothing more from that lane until the process takes its messages, so the lane's sender waits on a full lane; without a quota, the process's `max_heap_size` ends it, as in stock OTP |
| A program's channel record is malformed, or a frame on it is beyond the program's credit, a request on a busy slot or a notice that is not due | the funnel in channel mode; the driver's count of the program's credit | the record discarded | the driver ends the program as a fault ends it, and the owner gets `{exit_status, N}` with `ERX_EXIT_SIGNAL` plus `SIGSYS` ([design-programs.md](design-programs.md#the-channel)) | the handler sees the port close; the shell reports the program's end |
| A device returns a used index, descriptor index or length out of range | `erx_device_queue`'s check in `complete/2` | the queue broken: entries before it returned, every buffer still posted, `post/4` and `complete/2` `{error, broken}` | the driver calls `negotiate/2`, whose reset returns every buffer to its pool | the driver's log line naming the device; the driver's supervisor may restart it |
| Capacity changes faster than ERTS adjusts | `acted_seq` behind `cap_seq` | none | none needed | ERTS acts on the latest value; intermediate values are skipped, as level-valued events allow |
| The JIT's code space is exhausted | the JIT object cannot grow | the module unloaded | the loader | `{error, system_limit}` from the load; a counter in the inspector |
| An encoding error in the translator | the repaired error path | the translation discarded | the loader | `{error, badfile}`; a log line naming the module |
| A write to the release file system or an EROFS image | `erx_prim_file` | nothing | none needed | `{error, erofs}` |
| An EROFS block fails its hash check | the hash-checking primitive under the EROFS reader | the mount, read-only | none needed | `{error, eio}` for the read, and a log line naming the image and the block |
| The RAM file system reaches its cap | the cap's check in `erx_ramfs`, which refuses the whole request of at most 64 KiB ([design-tmp.md](design-tmp.md#failure-handling)) | the file as before the refused request; a larger write keeps the requests before it, as after a short write ([design-files.md](design-files.md#open-files-and-offsets)) | none needed | `{error, enospc}`, and `ENOSPC` in a program writing through its session's grant or at the write-back of its shared mapping |
| The crash dump exceeds the crash area | the dump writer's bound | the dump cut at the area's end, with its stored length and `ERX_CRASH_TRUNCATED` in the header | none needed | the inspector marks the dump truncated |
| The console's driver has no free transmit buffer | `{error, empty}` from its pool | the unwritten bytes in the console service | the console service, once the driver reports room | output delayed, never reordered or dropped |

**Diagnostics.** The inspector shows, per domain, every executor's state,
CPU, time run and preemptions (from the status area), ERTS's own scheduler
statistics, allocator and atom-table usage, each connection's frames sent,
taken, refused and unheld and its busy time, each program port's state,
each device's posted and completed buffers and interrupts, and the last
crash dump ([design-live.md](design-live.md#inspection)). The adapter
emits trace events for capacity changes, yield requests honoured,
refusals, connection closes and unheld frames. Parks and wakes are
recorded by the layer that carries them out: the kernel trace ring, which
also shows the executors' dispatches, or on the stopgap the backend's
ring, where the adapter emits none of its own. One viewer lines them up
by time ([design-live.md](design-live.md#tracing)).
Hosted mode adds `lldb` and the sanitizers.

## Security

A domain's runtime is untrusted by every other party: the kernel and other
domains depend on nothing it does. Which processes may message a domain's
processes depends on the kernel and on that domain's own runtime, and on
nothing else: the system domain makes the connections, and the receiving
runtime's funnel and export table decide what crosses them. The system
domain's runtime runs the trusted services, in user mode, so a bug in it
cannot corrupt the kernel; a fault in it ends the machine by `erx.panic`.

**What a runtime reads from outside itself.**

| Input | Source | Validation |
| --- | --- | --- |
| a lane's ring and reader page | the connection's peer | every position copied once through `erx_shm_copy` and checked before use; a record copied out once before the funnel reads it; the funnel's grammar and the export table ([design-domains.md](design-domains.md#the-funnel)); ERTS's decoder, in safe mode in the system domain, completes the funnel |
| a channel's ring | the session's program | the same, in channel mode, decoded in safe mode in every domain |
| the boot information page | the domain library, or the root-task entry | version, ABI version, and every offset and length inside the page, once at start-up |
| a message from the system domain naming slots | the system domain | the slots must hold objects of the expected type and rights, checked through `erx_object_info` before use |
| the release slice | the boot image, verified by the kernel at boot | the index's bounds, by the kernel; ERTS checks the BEAM format of each module it loads |
| status areas | the kernel | one load per field per decision; values clamped where they size anything (capacity to the executor count) |
| exit and fault records | the kernel, through the fault gate | a fixed layout, copied once and checked by `liberx` |
| console input (system domain only) | the UART, through the console's driver in the system domain | bytes the driver copied out at completion, parsed by the console service's Erlang code |
| another domain's crash area (system domain only) | that domain | the header rules of [Data model](#data-model) |
| `prim_file` paths | the domain's own code | `erx_path`, with its fuzz target ([design-files.md](design-files.md#resolving-a-path)) |
| file protocol replies | file servers, over connections | the funnel's grammar, then the protocol's ([design-files.md](design-files.md#the-file-protocol)) |
| pipe rings and pages | whoever holds the pipe's other ends | every field copied once through `erx_shm_copy` and checked before use; the bytes are data ([design-pipes.md](design-pipes.md#security)) |
| a device's completion entries and buffers | the device | fixed fields read once through generated accessors and bounds-checked in the NIF; the bytes copied once out of the pool into a fresh binary at completion and parsed in Erlang in the driver's own process ([The device NIF](#the-device-nif)) |
| EROFS blocks | the storage domain's block service | the dm-verity tree, on a private copy, before the EROFS reader parses them ([Files](#files)) |
| code blobs | its release slice, the code service | the SHA-256 the load names, before ERTS's loader reads them ([design-live.md](design-live.md#the-code-store)) |

**Code.** A domain loads any code it is given: ERTS has no bytecode
verifier ([research](research-erts-internals.md#loader-trust)), and the
hardware isolates the domain instead. BeamAsm's writable alias of each JIT
object stays inside the domain; generated code is not guarded by branch
protection, which weakens the domain's own defences against its own inputs
and nothing else. The system domain, the most trusted runtime, runs the
interpreter image, so it holds no generated code, no writable view of
code and no C++, and its runtime's code is all built with branch
protection; it loads only installed code, and the missing bytecode
verifier is the residual risk recorded in
[design.md](design.md#residual-risks).

**Isolation of executors.** No executor waits on anything another domain
controls (R3). A hostile peer can fill the lane this domain writes and
make this domain's senders wait, which is what a stalled receiver does
in stock distribution; it can fill the lane this domain reads, and this
domain spends its own CPU validating what it drains, bounded by its own
drain rate and batch size. A facet process is bounded by its own
`max_heap_size` and its grantee's lane ([Memory](#memory)).

**Leaks.** Crash dumps hold the domain's data; the system domain shows a
crash area only to principals that may inspect the domain
([design-live.md](design-live.md#inspection)). A group's status area
shows the kernel's view of that group alone. A domain's standard I/O
reaches a terminal only through its session's tty, unfiltered
([design-live.md](design-live.md#security)), and a domain with no terminal
reaches none. A frame's unheld outcome is the dead-process outcome,
so no peer learns whether an unexported process exists.

**Residual risks accepted.** The system domain's runtime loads only
installed code but has no bytecode verifier (above). A NIF can hold a
lock across a blocking call and stall its own domain's schedulers, as it
can on a host, for at most that call's deadline (R3). A driver domain
that holds an unconfined device is in the trusted base, as the manifest
says, and so is the one domain that holds PCIe configuration space
([design-system.md](design-system.md#drivers)). What a runtime publishes
about its own processes (urgency, capacity use) is believed only about its
own domain, so a runtime that lies harms only itself.

## Verification and testing

* **The oracle.** OTP's `emulator`, `kernel`, `stdlib` and `compiler`
  suites run in a test domain under QEMU with HVF, on both
  runtime images, and on the development host on stock OTP 29.1.2; a
  Ruby tool compares them case by case (`make check-oracle`). Every difference
  is a bug, a documented difference with a test (the table of
  [Erlang-visible behaviour](#erlang-visible-behaviour)), or an upstream
  bug recorded as such. Checked-in rules map each class of case that differs
  to its explanation, such as the printing of local pids, or to the reason it
  cannot run yet (a peer, a spawn port, a socket, a C helper, a load at run
  time, a file system), which the run must show. The comparison fails on a
  difference no rule explains and on a rule that matches no case. Suites run
  in the system domain from a test release, which alone is allowed to load
  code outside the install arena, since the suites compile and load modules.
* **The C library.** musl's `libc-test` runs in a test domain, also
  under `make check-oracle`.
* **The per-byte primitives.** Each has a fuzz target and a differential
  test against its reference on the host, the CPU-instruction path
  against the portable one included
  ([Per-byte primitives](#per-byte-primitives)); the EROFS reader runs
  over images that `mkfs.erofs` writes, on the host's stock OTP and in a
  domain, against Linux's EROFS driver in the oracle guest.
* **The adapter's core.** `erx_rt_decide` is tested exhaustively on the
  host over small ranges of every field, with properties: `online` is in
  `1 .. min(limit, total)`; a plan acts on the latest sequence; the ready
  list is taken whenever `ready` was not zero; nothing is published twice.
* **Park and ERTS's sleep flags.** The park protocol's exhaustive host
  model of [design-scheduler.md](design-scheduler.md#verification-and-testing)
  gains ERTS's flag transitions for two schedulers, one external signaller
  and one internal waker; no interleaving leaves a scheduler parked with
  work on its queue (R2).
* **Wake storms.** Four executors pass a million messages in rings across
  run queues while a peer domain rings the connection's bell; a watchdog
  fails the test if any executor stays parked for 10 ms while its run
  queue or a lane holds work. Under HVF.
* **Capacity.** A test policy moves a domain's capacity between one and
  four CPUs every 10 ms while OTP's `emulator` suite runs; the suite
  passes, and `schedulers_online` matches the capacity at every sample.
* **Deferral.** In deterministic mode, a yield request raised while
  `defer` is up produces `erx_yield` when it returns to zero, and an
  overrun when a test lock is held past the grace.
* **Node identity.** Two domains the system domain connects: each one's
  `node()` is its `<id>@<host>` name and `erlang:system_info(creation)`
  its id; `nodes()` lists exactly the domains connected to it before an
  introduction, after it and after the connection ends, and
  `monitor_node/2` and `net_kernel:monitor_nodes/1` deliver `nodeup` and
  `nodedown` for each. A pid of the peer prints as `<D.N.S>` with the
  peer's id and a local one with the domain's own, and `list_to_pid` of
  each text returns the same pid, while the text of an id no connected
  domain has is `badarg`; a local port prints as `#Port<D.N>` and a
  reference as `#Ref<D.a.b.c.d>`, each with the domain's id. A pid of a
  peer that ended still prints its own id once a later domain of the
  peer's name has connected. A send to a pid of a domain that is not
  connected is dropped and a spawn into it fails with `noconnection`, once
  `erx_dist:setup/5` has refused. Seeded failures: a build with stock
  `internal_channel_no` fails the local printing case, one whose
  `external_channel_no` reads the creation of the distribution entry
  instead of the term's node fails the ended peer's case, one with stock
  `erts_channel_no_to_dist_entry` fails the parsing case, and an
  `erx_dist:select/1` that refuses this host's names fails the connection
  case. A name registered with `global` and a `pg` group joined in one
  domain stay invisible in the other, and the connection survives `pg`'s
  discovery; `{Name, Node} ! Msg` toward the peer writes no frame, and
  `monitor(process, {Name, Node})` gets `DOWN` with `noproc` at once; a
  cross-domain process monitor fires when its target exits, not only at
  the connection's end. `erpc:call/4`, `rpc:call/4` and `rpc:cast/4`
  succeed toward the domain that exported `spawn` to the caller, and
  `erpc:call/4` fails with `noconnection` toward one that did not;
  `rpc:block_call/4`, `rpc:abcast/2`, `rpc:sbcast/2`, `rpc:server_call/4`
  and `rpc:multi_server_call/2` toward a peer return the documented
  answers and write no frame. `net_adm:ping/1` returns `pong` for the peer
  and for the system domain's node, `pang` for a domain it has no
  connection with, writes no frame and leaves every connection up; seeded
  failure: stock `ping/1`, under which the ping of the system domain's
  node returns `pang` and ends the domain. A domain starved of CPU for
  twice `net_ticktime`, with `net_ticktime` at its minimum in it and in
  its peers, keeps every connection and runs on when it gets CPU again;
  seeded failure: an `erx_dist` whose connection owner acts on
  `net_kernel`'s ticks as `dist_util` does, under which the starved
  domain's system connection ends and the domain stops. The release build
  checks that every release sets `connect_all` to `false`, and a seeded
  release that sets it `true` fails the build; a runtime without edit 27
  fails the `pg` case, its discovery frame ending the connection, and the
  registered-name tools' case, `block_call`'s request ending it; and a
  flag set without `DIST_MONITOR_NAME` fails the monitor case.
* **Connections.** Two domains run OTP's distribution-level tests of
  send, link, monitor, exit, group leader, spawn and alias reply across a
  connection and against stock OTP over TCP on the host, case by case. A
  pid encoded for a peer is exported with `send` alone, a spawned child
  with every right; narrowed with `erx:export/3` a name stays narrow
  after a second encode (R7). A frame to an
  exited process, to a deactivated alias and to a pid never exported get
  the dead-process outcome, in order after the target's earlier frames
  (D9), and the peer cannot tell the three apart by outcome or timing. A
  peer that stops reading suspends exactly the senders to it, and a
  `gen_server:call` to it times out while unrelated processes run. A
  message above the lane's limit raises `system_limit`. A malformed frame
  closes the connection with `noconnection` on both sides and a report to the
  system domain. The hostile-peer corpus of
  [design-domains.md](design-domains.md#the-funnel) is replayed into a
  lane, hosted under ASan and UBSan; a seeded skip of the funnel fails
  the chokepoint check (R6).
* **The export table.** A source check lists the callers of its insert
  and fails on a fourth, with a seeded violation; a property test over
  sequences of encode, export, exit and deactivate keeps every entry's
  rights monotone and ends it with its name.
* **Lazy decode and heap limits.** A grantee floods its facet with
  messages it never reads: the facet is killed at its `max_heap_size`
  with the queued frames counted, its lane fills, the grantee's senders
  suspend, and the system domain's memory stays within the facet's limit
  plus the lane. The same with messages of large binaries, counted by
  `include_shared_binaries`.
* **Programs as ports.** A session starts, pauses, forks, execs and ends
  programs through `erx_program`; `{exit_status, N}` carries each halt
  status, and for a fault `ERX_EXIT_SIGNAL` plus the signal the fault
  table gives its kind; a signal sent as a report arrives after every
  report sent before it; closing the port stops the anchor and with it
  the program's tree; the owner's exit closes the port; a handler whose
  program's inbound lane is full gets `busy` and is never suspended. A
  program that writes a malformed channel record, a request on a busy
  slot, or a notice that is not due, a repeated `{closed}` among them, is
  ended and reported with `SIGSYS`, and one that writes as fast as it can
  within its credit leaves at most one message per credit in its
  handler's mailbox. The programs design's own suites run over the driver
  ([design-programs.md](design-programs.md#verification-and-testing)).
* **The device NIF.** On the hosted backend a model device completes,
  skips and misreports descriptors: every address the NIF gives it lies
  in the buffer of the chain's head, and no two chains in flight share a
  buffer; a refused post writes nothing to the rings or the doorbell;
  `negotiate/2` accepts no bit that changes the ring or the transport,
  fails with the device FAILED and the queue refused when the device
  refuses FEATURES_OK, offers no VERSION_1 or keeps a queue after its
  reset, refuses a queue the device still holds and installs nothing of it, and otherwise zeroes the rings before the ready bit;
  after a driver's exit `post/4` fails until `negotiate/2`; an
  out-of-range index or length breaks the queue until `negotiate/2`; a
  buffer the device rewrites after its completion leaves the binary
  `complete/2` returned unchanged (R9); a driver process killed with
  buffers posted leaves its pools and queues in place, and nothing the
  device may hold is reused before `negotiate/2` (R8); `write/3` and
  `write_field/4` of every owned register fail with `badarg`; a restarted driver whose line its predecessor left
  masked receives its next interrupt, and its predecessor's late exit
  leaves its binding in place. A seeded return of a posted buffer on
  collection, a seeded post before `negotiate/2`, a seeded raw-offset
  accessor and a seeded register without its `ownedByNif` mark and a seeded
  owned register named outside `erx_device.c` each fail. Under QEMU the virtio block and network drivers run their device
  tests through the NIF with interrupts delivered through the event
  table, under HVF.
* **The event table.** Labels fire while their sinks close and exit and
  are reused at once by new sinks: every delivery reaches a live sink or
  is dropped, none reaches a dead one, and a stale delivery that reaches
  the later sink of a reused label makes it look and act on nothing it
  did not find; under TSan hosted. Seeded failure: a connection sink that
  counts a delivery as a frame, under which the stale delivery produces
  an action.
* **The root-task entry.** The hosted backend starts the interpreter
  image through `erx_root_main` with a model machine page: the entry runs
  the bootstrap of [design-system.md](design-system.md#the-root-task),
  whose own tests that document lists, and ERTS boots the system release
  on a boot information page flagged `ERX_BOOT_ROOT`; a corrupted slot
  ends the task with a diagnostic. The domain library's plans are tested
  on the host over
  specifications at every limit, with failure injection at every kernel
  call, and leave nothing created on failure.
* **The watchdog.** A test system release that stops petting ends the
  machine within the deadline under QEMU; one whose domain service stops
  answering sees it killed and restarted and the pets go on, and one
  whose domain service never answers again ends at the deadline; a
  partial boot that outlives `B` is not ended, since the root-task entry
  pets, and the same boot with the entry's petting removed is ended;
  deterministic mode never ends the machine.
* **Reference identities.** Normal and dirty schedulers and helper threads
  create all reference kinds concurrently, using a reduced-width host
  model to reach every source and counter exhaustion; no identity repeats
  and exhaustion refuses before wrap. Comparison, hashing, text conversion
  and external term round trips preserve all four words, both locally and
  when echoed by stock OTP 29.1.2. A reference received over a connection never
  becomes a native resource. Alias tests cover repeated ordinary sends,
  each reply-deactivation mode, unalias, monitor removal and process
  death, each ending the alias's export. AES known-answer vectors and
  differential portable/hardware tests use the exact primitive that
  ships; key setup, entropy failure and counter exhaustion have failure
  tests.
* **Blocking.** A test NIF calls `erx_ipc_wait` with a 1 ms deadline from
  a normal scheduler and gets `ERX_EWOULDBLOCK`; from a dirty I/O
  scheduler it waits and returns `ERX_ETIMEDOUT`.
  E-S10 counts refusals across OTP's suites.
* **BeamAsm.** A module is reloaded in a loop on four CPUs while every
  scheduler calls it (R4); a page-table walk after every test finds no
  writable and executable mapping; a space created without `ERX_SPACE_JIT`
  cannot map a JIT object.
* **The two images.** The build check finds no symbol of BeamAsm, asmjit,
  libc++ or libc++abi in the interpreter image, and fails on a seeded
  asmjit object linked into it; the packer refuses a root image marked
  `ERX_IMAGE_JIT`, shown by a seeded manifest; in a booted system
  `erlang:system_info(emu_flavor)` is `emu` in the system domain and in a
  command domain and `jit` in an ordinary domain, and a JIT object asked
  for from the system domain is refused by the kernel (R10).
* **Call stubs.** The generator refuses a test ABI file that gives a call
  a pointer argument (R11). Every call that takes a memory window is
  called with ranges at and past the object's end, with an
  offset and length whose sum overflows, and with an object the caller
  holds without the right the call needs, on the `erx` backend and on
  the hosted backend, and both return the same status for each; a hosted
  backend with its range check removed fails the comparison. A call
  whose request fills the UTCB is called with every field at its limit.
* **Crash handling.** `erlang:halt("boom")` produces a dump, the exit
  reason `{domain_down, D, crash}` and the slogan `"boom"` in the death
  record; `erlang:halt(3)` produces `{domain_down, D, {halt, 3}}` and no
  dump; a one-page crash area produces a truncated dump marked as such.
  The reader takes a dump that fills the area exactly as complete, a dump
  one byte longer as truncated, and refuses headers with a wrong magic or
  version, an unknown flag, a non-zero `pad`, a `length` past the area or
  a slogan without a NUL. A system domain that crashes ends the machine;
  in a development build its slogan is in the crash record, and in a
  release build the record holds no text.
* **Fuzz targets.** `prim_file`'s path resolution (`erx_path`, in Erlang), the
  file protocol's decoder, the crash header's reader, `liberx`'s
  validation of the boot information page, the funnel in both modes, the
  lane's position checks, the device NIF's completion reader with a
  hostile model device, and the exit and fault record reader, built from
  the same sources for the host (`make check-fuzz`); the programs' own
  targets are in
  [design-programs.md](design-programs.md#verification-and-testing).
* **Code by hash.** A module whose bytes differ by one bit from its hash
  fails to load in every domain, the system domain included.
* **Hosted mode.** The same suites run hosted under ASan and UBSan, and the
  storm, capacity, event-table and connection tests under TSan.
* **Determinism.** The interpreter image in deterministic mode boots to
  a shell and runs a scripted session with a byte-identical transcript.
* **Floats.** A differential test of `float_to_list/1,2`,
  `list_to_float/1` and the float term format over millions of random
  doubles against the host.

**The port's seams.** Each passing case is paired with the seeded failure that
shows it ran. Hosted cases run under ASan once per batch, and the native ones are
listed in [design-stopgap.md](design-stopgap.md#verification).

| Case | Seeded failure, and what it shows |
| --- | --- |
| `make check-runtime-seam` passes on the hosted and the native image | a call to `open` in a `sys/erxos` file fails it, naming the object; a call to `uname` in a native-only object fails the number check; a `HAVE_` answer changed in one target's file fails the comparison; `#ifdef __APPLE__` in `sys/erxos` fails the source check; a `sysconf(_SC_NPROCESSORS_ONLN)`, and a `write` outside `erx_output.c`, fail the name check |
| `erx_output_write` on descriptors 1 and 2 writes, and on an open descriptor 3 answers `EBADF` | the descriptor check removed: the bytes arrive on descriptor 3 |
| `erlang:display_string/2` with all 256 byte values, to a full non-blocking pipe that is then drained, delivers exactly those bytes in order | stock's `written += res` restored: the bytes differ and AddressSanitizer reports the read; an escaping step added: the comparison fails |
| In a session's domain with one executor and a stopped tty, `erlang:display_string/2` waits, another process goes on running, and once the tty is connected every byte arrives in order | the trap removed: the bytes reach the C path and the comparison fails |
| In the system domain, while a session is connected at the UART and with the system shell's tty raw, `erlang:display_string/2` of a newline reaches the driver as that one byte, and the service goes on | a tty's `output/3` added on this path: the byte becomes CR-LF; the write sent to a tty that is not connected: the deadline fires |
| With one executor, a flood of `erts_printf` and of `fprintf(stderr, ...)` past the debug log's rate returns, `ferror(stderr)` stays clear, the executor parks afterwards, and the log reports a count of lines dropped | `erx_output_write` answering `EAGAIN` past the rate: `erl_printf.c`'s loop spins and the deadline fires |
| `erlang:display_string(stdout, <<"done\r\n">>), erlang:halt(0)` in a session's domain delivers those bytes; on a stopped tty it halts at once and on a tty whose master stops answering it halts within 5 s | the trap in `halt_2` removed: the bytes are lost; `tty_drain` that waits on a stopped tty: the halt misses its deadline |
| Before any owner runs, and from the owner itself, `erlang:display_string/2` reaches `erx_output_write`; the same with the owner killed in mid-write | the owner test removed: the owner waits on itself and the deadline fires; the monitor removed: the writer waits past the deadline |
| A host test of `erx_runtime_main`'s vector over a read-only page: `argv[0]`, every word in order, the node name's flag, a final null, and each word writable. The hosted boot of [Configuration](#configuration)'s arguments lists `kernel_sup`'s children as its table says, and `whereis(user)` is the group with no shell | the words not copied: the write faults; `--` removed from the arguments: the boot stops in `erts_usage`, naming the flag; `-user erx_console` removed: `user_drv` fails at its load and the boot ends with `init`'s diagnostic; in a release with a carrier, `-nocookie` removed: `auth` fails on the read-only release |
| A pty test drives the hosted image: `1> 1+1.` answers `2`, an arrow key recalls history, `halt().` ends the process with status 0 and the terminal is restored | the NIF's `erx_irq_trigger` removed: input never arrives, the test's deadline fires, and an idle sample shows every executor parked; the mode restore removed: the test sees the terminal still raw; `isprint/1` returned to its NIF stub: the first prompt raises `undef` and the deadline fires |
| The image with empty input ends with status 0. With `1+1.` and `2+2.` immediately followed by end of file, the output holds both results and the status is 0 | `erx_stdio` halting at end of file: the results are missing; `erx_console_eof` dropped: the deadline fires; `put_chars_sync` answered before the write: a test driver that holds back `erx_console_written` sees `io:format` return |
| An executor made by `erx_pthread_create_executor`, hosted and in the `native_musl` suite: its slot is not `ERX_NO_EXECUTOR_SLOT`, `erx_park` with a deadline gives `ERX_ETIMEDOUT`, and a plain `pthread_create` thread gives `ERX_ETYPE` | the call delegating to plain `pthread_create`: the park gives `ERX_ETYPE` |
| 64 executors succeed and the next gets `EAGAIN` in its creator; slots return after both a return and a `pthread_exit`, so 64 more succeed | the cleanup handler removed: the second round gets `EAGAIN` |
| `ethr_event` timed waits and wakes in a storm, hosted and native, each with a deadline | `ETHR_FUTEX__`'s wake dropped: the storm's deadline fires; its wake returning the woken count: the first wake of a waiter ends the runtime; `ERX_ETIMEDOUT` passed through untranslated: the first timed wait ends it |
| The release file system answers like stock `prim_file`: a corpus of paths (nested, `.`, `..`, missing, a file used as a directory, a directory opened, long names) gets the same results and bytes hosted over an archive as stock OTP over the unpacked tree, `f/.` and `f/` where `f` is a file and `missing/../x` included. A path over a limit is named in the comparison and pinned | a binary search off by one, and a listing that yields a name twice, each fail the comparison; a resolver that folds `.` and `..` on the text fails the `missing/../x` case |
| 10,000 `read_file` calls and as many `open` and `close` pairs leave the NIF's resource count where it began, and `read_handle_info` on an open handle answers its entry's type and size | `close` answering `enotsup`: the pair's `close` fails; the release removed: the count grows; `read_handle_info` answering size 0: the comparison fails |
| The pure core, exhaustive over all paths of a small tree on the host, and under `make check-fuzz` through the NIFs' decoder of name lists, which any process can call | the name-length check removed: the fuzz target's seed of a 256-byte name fails its property that no name is over the limit; the count check removed: AddressSanitizer reports the walk's overrun from the seed of 257 names |
| A hosted boot reaches `init` through `erl_prim_loader` from the archive alone, with `HOME` and the working directory unset and no other file readable to it | `start.boot` removed from the archive: `init` ends with its own diagnostic, with no spin; a flipped index byte: the hosted entry refuses the archive, naming the check |

## Performance

**Cost model.** Inside a domain, a process switch, a message send, a spawn
and a receive are ERTS's own operations and enter the kernel only to wake
a parked executor. The adapter adds, per pass through `erts_schedule`, a
few loads of words in shared memory, the ready count, the capacity
sequence and the status fields, against a scheduling pass of hundreds of
nanoseconds; per critical section with deferral, two stores and one load.
A wake costs one kernel call and, when the target's CPU is another, an
interrupt to it; a park costs a call and a context switch. Between
domains, a message costs its encoding onto the entry's queue, one copy
into the lane, at most one bell ring per batch when the peer
sleeps, one copy out of the lane, the funnel's pass over the bytes, one
look at the target's holders per name the funnel checks, a drain step,
and the decode in its receiver; the sender pays one export lookup per
local pid or alias it
encodes. The system domain's facets pay the same; nothing in the system
domain enters the kernel per client. The system domain runs its own
Erlang code on the interpreter, up to four times slower than BeamAsm on
the same code; its services do bounded control per request, so a
request's cost there is small beside the client's own work. An interrupt
costs a group wake and a safe-point dispatch before the driver's process
runs, so a driver's latency is the runtime's scheduling latency; G9
measures it per device class.

**Budgets and targets.**

| Quantity | Target | How it is checked |
| --- | --- | --- |
| ordinary-domain messaging, spawn and switch | within 1.2 times stock OTP 29.1.2 in the same flavour | `erts-local` under HVF against the host's stock OTP |
| a cross-domain message, sender's encode to receiver's receive | one copy in, one copy out, one decode; at most one kernel call per batch at each end | E-D1 on both lane sizes in hosted mode and under HVF |
| idle domain | 0% CPU | by construction: no spinning, parks with a deadline |
| minimal ERTS domain | the budget [plan.md](plan.md) sets from the host baseline | measured in a domain under HVF |
| BeamAsm over the interpreter | 1x to 4x | cited: `erts/emulator/internal_doc/BeamAsm.md` |
| a reference's AES-128 permutation | the local-operation target holds on the portable path as well as the hardware path | `erts-local` reports `make_ref/0`, alias creation, comparison, hashing and term round trips for both paths |
| interrupt to driver process | per device class, set by G9 | the driver tests report it under HVF |

**Benchmarks.** `tools/erx bench erts-local` runs the ring, spawn, switch
and `make_ref/0` benchmarks of
[research-baselines.md](research-baselines.md) in a domain under HVF and
on the host's stock OTP natively, on the same Apple Silicon host, with the
compiler, flags and QEMU version recorded;
`tools/erx bench xdomain-pingpong`, `xdomain-throughput` and
`xdomain-stall` run the cross-domain ring and a `gen_server:call` round
trip between two domains; the scheduler experiments E-S1 to E-S10
([design-scheduler.md](design-scheduler.md#performance)) cover wakes,
capacity and deferral. TCG numbers are reported separately and never
compared with HVF or native ones.

## Portability

The interpreter image is C and Erlang above `liberx`; the BeamAsm image
adds BeamAsm's C++. Architecture-specific parts sit in known places: the
thread pointer in
musl's architecture layer, BeamAsm's back end for the architecture,
`liberx`'s trap stubs, the device NIF's cache maintenance, and user-mode
cache maintenance, which the kernel enables where the architecture allows
it ([design-arch-aarch64.md](design-arch-aarch64.md#cache-maintenance)).
The device NIF's register tables are generated per board from its SVD
files, so a port adds files and no code. `liberx`'s hosted backend
isolates the host: `mmap` for memory, pthreads for threads, and
`os_sync_wait_on_address` on macOS or `futex` on Linux for umtx waits, in
one file each.

## Dependencies

No dependency beyond those in [design.md](design.md#dependencies): OTP
29.1.2 (Apache-2.0) and musl 1.2.6 (MIT) in the tree as erXos's code, LLVM
libc++ and libc++abi 23.1.x (Apache-2.0 WITH LLVM-exception) built out of
tree from pinned source and linked into the BeamAsm image alone, the
libraries OTP bundles under their own
licences ([The inventory](#the-inventory)), and toybox 0.8.15 with `wak`
(0BSD), in the tree as erXos's code. The Open POSIX Test Suite is a test
tool, fetched and built out of tree, never part of an image.
The reference primitive's candidate is `ctaes` (MIT), selected, reviewed
and pinned before reference hardening is enabled, as
[Unguessable references](#unguessable-references) requires. sDDF is a
model and an oracle for drivers, nothing imported
([design.md](design.md#dependencies)).

## Alternatives considered

**ERTS in the kernel as the machine's scheduler.** An ERTS in kernel mode
would be the machine's scheduler. It loses to the two-level design: the kernel
would carry a runtime's code and its failure modes, a second runtime would
have no place, and the kernel could account CPU time to nothing but Erlang
processes. The user chose generic two-level scheduling.

**A kernel thread per Erlang process.** Each process would be a kernel
thread, scheduled and accounted by the kernel directly. It loses on cost
and size: every spawn, switch and receive enters the kernel, and every
process holds a kernel object, against ERTS's switches without a kernel
entry and its processes of a few hundred words
(`system/doc/efficiency_guide/eff_guide_processes.md`). Experiment E-S2
measures the gap on the same kernel
([design-scheduler.md](design-scheduler.md#performance)).

**A byte ring between C output and a drain process.** Copying descriptors 1 and 2
into a ring that an Erlang process empties would keep C output raw on erXos's
kernel. It would also make normal Erlang output inherit native loss and retry: a
full ring needs a trap for `display_string/2`, a drop count for `erts_printf`, a way
for `erl_printf.c`'s and musl's loops not to spin on a drain their own executor must
run, a drain at halt for a queue that dies with its producer, and a rule for bytes
written before the drain starts. A process waits on its tty's owner in `receive`
instead, which needs none of these, and C's own diagnostic text goes to the log that
already never waits. UNIX's own console log has the same shape: a kernel `printk`
does not wait for the terminal, and a process's `write` does.

**Upcalls into ERTS.** Scheduler activations would tell ERTS when an
executor blocks or is preempted, by running ERTS code in a fresh context.
It loses on correctness: ERTS would need to be re-entrant at arbitrary
points, which the systems that tried it found to be the hard part
([research](research-hierarchical-scheduling.md#negative-evidence)).
Executors never block, so the only event an upcall would carry is
preemption, which ERTS does not need to know about.

**A POSIX layer under ERTS.** A file-descriptor and `poll` emulation would
let ERTS's UNIX sys layer run unchanged. It loses on simplicity: erXos
would maintain an emulation of a model it does not have, and the poll set
would still be a second readiness mechanism beside the IRQ objects bound
to groups. The POSIX-lite personality serves programs only, and ERTS
never runs on it.

**ERTS's run queues visible to the kernel.** The kernel would see ERTS's
run queues and pick processes itself, as delegated schedulers do. It
loses: it moves ERTS's proven scheduling policy across a protection
boundary and adds a kernel call or a shared structure per scheduling
decision, which is what the two-level design avoids.

**A router beneath distribution.** A trusted third domain would read every
domain's outbound ring, validate each frame, hold every domain's imports,
and write the frame into the receiver's inbound ring. It gives O(1) ring
memory per domain against two lanes per introduced pair, and a parser
crash in the third party instead of in the receiving runtime. erXos does
not take it: three copies and up to three thread hops per frame against
one copy in and one out; a trusted base for messaging outside the domain,
where the receiver's funnel is the same C either way; a star whose one
process's deadline is a machine-wide net split; and no flow in the design
that grants a name its granter does not own, which was the third party's
one distinctive power
([design-domains.md](design-domains.md#alternatives-considered)).

**A carrier with a controller process.** Stock OTP's alternative-carrier
interface drives a distribution entry from an Erlang process through
`dist_ctrl_get_data` and `dist_ctrl_put_data`. A lane carrier in Erlang
with a ring NIF would need no C driver, but every frame would cross the
entry's queue, the controller's heap and the ring, with a process switch
on each side, and busy flow control would be the controller's to
implement. The port controller is the other stock shape: a linked-in
driver gets the encoded frame as an iovec, copies it once, and inherits
the owner link and serialised output, while the entry's own busy rule
holds as for any controller.

**Per-client allocation accounts in the system domain.** The system
domain's image would carry allocation accounts, an account-aware
allocator and a build check that every allocation names an account, so
that one client's work could never allocate beyond its reserved share.
It loses: accounts reach every allocation of ERTS, so the system
domain's allocators would part from every other image's, and the bound
they give is already given by the facet's `max_heap_size`, the lane and
lazy decode, which cost no edit to the allocators ([Memory](#memory)).

**One image for every domain, BeamAsm in the system domain.** The system
domain would run the BeamAsm image like every other domain. It buys one
image exercised by every domain and faster system services. erXos does
not take it: it puts BeamAsm's translator, asmjit, a C++ runtime, JIT
objects and a writable view of the most trusted runtime's code into the
trusted base, for speed that bounded control does not need. The
interpreter image is exercised in every test boot by the system domain
itself, command domains and deterministic mode, and the oracle runs
every suite on both images.

**One node name for the machine.** Every runtime would run as the
machine's node, with its domain id as creation, each domain another
incarnation of one node. It buys one name for the whole machine and
pids that compare as one node's. erXos does not take it: stock ERTS
assumes one creation per node name, so it costs edits at five sites (a
node table keyed by creation, the decoder's test for the own node,
channel creation's refusal of the own name, the old-incarnation handling
of `do_send` and the entry's channel number), connections that `nodes()`
cannot list, and `net_kernel`, `monitor_node/2` and the tools above them
unusable between domains
([research](research-architecture.md)).

**Call stubs that pass pointers.** A stub would hand the kernel the
address of a request or result buffer in the caller's space, and the
kernel would copy through user-copy functions. It buys requests of any
size without a memory object. erXos does not take it: the kernel would
need a copy funnel, a validation of user addresses, a copy window or the
architecture's protection against stray accesses to user memory, and a
fault path inside its own copies, each a place where a domain's address
reaches kernel code ([design-kernel.md](design-kernel.md#l4-lineage)).

**Native drivers in domains of their own.** A driver would be a native
process with a fiber runtime, speaking to its clients over rings. It
loses to Erlang drivers: a parser in C in a domain that holds a device is
the one place where a device's lie becomes memory corruption; a driver
process in Erlang parses in a supervised process and corrupts nothing; and
the fiber runtime, a second implementation of the contract, has no other
user. Where a measurement shows an Erlang driver misses a device's
timing, a native shim runs as a sub-space port, single-threaded C under
`liberx` with no runtime of its own
([design-system.md](design-system.md#the-driver-table)).

**Zero-copy receive.** `complete/2` would return a resource binary over
the pool buffer, saving the receive path's one copy. A device can write a
buffer again after its completion, so the binary would change under code
that assumes it cannot: a decoder that sizes a term and then decodes it,
and the hash-checking reader, which would check bytes that change after
the check. It is safe only when nothing the device holds reaches the
buffer once it completes, which needs the NIF to unmap each buffer from
the device's DMA window at completion and to map it again at its next
post, possible only for a confined device. It is a candidate for gate G9,
which measures it per device class against the copy
([design-system.md](design-system.md#the-driver-table)); receive copies
(R9).

**Programs as domains.** Each native program would be a domain with a
domain id, a node identity, an export table and connections of its own.
It loses: every program start would cost a domain's creation through the
system domain, per-image pid ranges and the restarts of a peer, and
every program request would be a cross-domain frame; a sub-space port
costs the session a budget carve, a group, two space creations, a
channel, a data area, pipe ends and one thread, within the session's own
budget, and its requests are frames on a channel its session alone reads
([design-programs.md](design-programs.md#the-cost-of-a-program)).

**A separate native root task.** A small native program would receive the
root capabilities, start the system domain's runtime, and restart it on a
fault while keeping configured domains alive. It buys services that ride
through a fault of the system runtime; it costs two system-domain
instances overlapping in one budget, identity and re-grant rules in every
configured registry, device reconciliation, and a second trusted program
with its own protocol, ring and fuzz target. erXos takes the reset, as
OTP's `heart` does, with the domain library behind one C interface, so a
separate root task remains a change behind that seam
([design-system.md](design-system.md#the-root-task)).

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| ERTS's sleep protocol and `erx_park` interact so that a wake is lost | low | high | the exhaustive model with ERTS's flags; the storm test |
| Changing `schedulers_online` is too slow to follow capacity | medium | medium | E-S9 measures it; the policy changes capacity with hysteresis |
| No busy waiting raises wake latency inside a domain | medium | medium | E-S1 compares `none` and `very_short` |
| NIFs in OTP's applications block on normal schedulers | medium | low | E-S10 counts them; each moves to a dirty I/O scheduler |
| An OTP application expects `global` or `pg` to span the machine's domains | medium | low | the Erlang-visible table states that they see only the local node; the oracle's distribution cases across connections list each case that depends on them |
| The interpreter image runs in fewer domains than the BeamAsm image, so its bugs surface later, and one in the system domain resets the machine | medium | high | every suite runs on both images; the system domain, command domains and deterministic mode run it in every test boot |
| A pid of another machine's node prints with a creation equal to a domain id of this machine | low | low | the open question below |
| An export lookup per encoded local pid shows on the cross-domain hot path | low | low | `tools/erx bench xdomain-pingpong` measures it; a per-entry cache of the sender's own pid is the fallback |
| One connection's head-of-line blocking stalls unrelated processes of a domain toward one peer | medium | low | it is stock distribution's behaviour toward a busy distribution connection; the system domain's facets are per grantee, so no grantee stalls another's |
| AES per reference on a CPU without the instructions threatens the local target | medium | medium | `erts-local` on the portable path; a per-domain switch to a cheaper permutation for references that never leave the domain is the fallback, recorded in `TODO.md` |
| Interrupt latency through the runtime's scheduler misses a device's timing | medium | medium | G9 measures per device class; a native shim as a sub-space port is the exception path |
| libc++ or asmjit assume a host facility musl lacks | low | medium | found at the first BeamAsm build; fixed in the tree |

Open questions, each with its recommended answer:

* **Default busy waiting.** Recommended: `none` until E-S1 shows
  `very_short` pays for its spent quota.
* **Lane batch size.** Recommended: a batch that keeps one drain within
  a scheduler's reduction slice, with `-erx lane_batch` for experiments,
  until E-D1 measures the best fixed batch.
* **The text of other machines' pids.** An exposed domain's pids of
  another machine's nodes print with that node's creation, which can
  equal one of this machine's domain ids. Recommended: keep the one rule,
  the creation for every node, resolve `list_to_pid` to this machine's
  domain on a collision, and have the inspector show a pid's node name
  beside its text.

## References

* Erlang/OTP 29.1.2 source: `erts/emulator/beam/erl_process.c`
  (scheduler sleep and wake), `beam/code_ix.c` (the code barrier),
  `beam/dist.c`, `beam/erl_node_tables.c`,
  `beam/erl_node_container_utils.h` and `beam/bif.c` (distribution
  entries, creation, channel numbers, `list_to_pid`),
  `beam/io.c` and `beam/erl_port_task.c` (ports and port tasks),
  `beam/jit/arm/beam_asm.hpp`, `erts/emulator/internal_doc/BeamAsm.md`,
  `erts/doc/notes.md` (Erts 12.0: "The experimental HiPE application has
  been removed"); `beam/erl_bif_unique.h` (a reference's words from a
  64-bit per-scheduler counter); `erts/preloaded/src/erlang.erl`
  (`setnode/3`), `lib/kernel/src/dist_util.erl` (the end of a handshake
  and its `nodeup` report, and the connection loop's `send_tick`, which
  ends a silent connection with `net_tick_timeout`),
  `lib/kernel/src/net_kernel.erl` (accepting through a carrier module,
  `select/1`, and the ticker's `tick` to every connection owner),
  `lib/kernel/src/inet_tcp_dist.erl` (a carrier's `listen` returning its
  creation), `lib/kernel/src/global.erl` (`connect_all` and overlapping
  partitions), `lib/kernel/src/rpc.erl` and `lib/kernel/src/net_adm.erl`
  (which calls go through `erpc`'s `spawn_request` and which to the
  registered `rex` and `net_kernel`, and `ping/1`'s disconnect after a
  failure), and
  `erts/doc/guides/alt_dist.md`, "How to Implement an Alternative Carrier
  for the Erlang Distribution"; read 2026-10-29, 2026-10-30 and
  2026-11-01.
* NIST, [FIPS 197, Advanced Encryption Standard](https://doi.org/10.6028/NIST.FIPS.197-upd1),
  2023 update; [OTP 29.1.2 external term format](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#newer_reference_ext),
  `NEWER_REFERENCE_EXT`; [bitcoin-core/ctaes](https://github.com/bitcoin-core/ctaes),
  standalone constant-time AES candidate and its linked review.
* musl 1.2.6, <https://musl.libc.org/>, and
  [research-c-library.md](research-c-library.md).
* [research-erts-internals.md](research-erts-internals.md),
  [research-erts-host.md](research-erts-host.md),
  [research-baselines.md](research-baselines.md),
  [research-hierarchical-scheduling.md](research-hierarchical-scheduling.md),
  [research-architecture.md](research-architecture.md).
* T. E. Anderson et al., "Scheduler Activations", SOSP 1991; details in
  [research-hierarchical-scheduling.md](research-hierarchical-scheduling.md#negative-evidence).
* Apple, `os_sync_wait_on_address(3)`, macOS 14.4 and later.
