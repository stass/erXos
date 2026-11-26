# The kernel debugger

No debugger breaks into a running kernel, on Fiasco or on erXos's own
kernel: nothing in kernel mode stops a machine at a key, writes its
memory or lets it go on after a stop. The kernel does for a debugger the
one thing nothing else can do for it: it **stops**. Every CPU it can
reach is parked with its registers where a reader finds them, a crash
record is written and printed, and the machine ends. A stopped machine is
memory, and everything a developer asks of it is answered as a function
of that memory and of what the build knows about it: on the host, by one
tool, `tools/erx debug`, and for a board that holds after its stop also
at the board's own console, where a short, closed part of the tool's
commands is typed in any terminal and only reads. The tool reads five
kinds of **target** through one interface: a crash record, a memory image,
a board that holds after its stop and lends its memory over the console
wire, a machine that QEMU or a hardware probe stops from outside, and a
recorded QEMU run, which it also reads backwards in time. Its views are
the inspector's: the paths of `/proc`, read from a machine that can no
longer answer for itself. Fiasco's kernel debugger, JDB, and its GPL-2.0
kernel object leave every build.

This document is the contract: what a stop does and what it leaves in
memory ([The stop](#the-stop), [Data model](#data-model)); how a board
lends its memory after a stop ([The hold](#the-hold)) and what a person
can type at it ([The prompt](#the-prompt)); how the host reads
each target and what it can ask ([The host's debugger](#the-hosts-debugger));
which line carries what ([Transports and the console line](#transports-and-the-console-line));
who may read a machine ([Security](#security)); and how each part is
tested. The AArch64 facts, among them what reaches a CPU that masks
interrupts, are the binding's
([design-arch-aarch64.md](design-arch-aarch64.md#stopping-every-cpu)).

Two neighbours are not this document's. A machine that still answers is
read through its inspector
([design-live.md](design-live.md#inspection)). Stopping one thread of a
domain, reading its registers and starting it again while the machine
runs is the kernel interface's (`erx_thread_stop`, `erx_thread_read`,
`erx_thread_write`,
[design-kernel.md](design-kernel.md#threads-and-faults)); a debugger for
native programs rests on those calls and is not designed here. What it
shares with this design is the host's side: a stopped program, or a core
file of one, is a target as [Targets](#targets) defines one.

## Context

**JDB.** Fiasco's in-kernel debugger is 84 source files of 20,121 lines
under upstream's `src/jdb/` for the configurations erXos builds, all
MIT, and the fork carries none of it; the paths below are upstream's. In a measured AArch64 build it and its trace buffer were 18,749 of
66,837 preprocessed kernel lines, 28.1%
([research-hierarchical-scheduling.md](research-hierarchical-scheduling.md#fiasco-sizes)).
It is a prompt on the kernel's console: object lists, thread control
blocks, page tables, the mapping database, memory dumps, a trace-buffer
viewer, logging switches and counters. A kernel trap, a panic or a failed
assertion enters it (`Thread::system_abort`,
`fiasco/kernel/src/kern/thread.cpp`), as do a key on the console, two boot
options and its kernel object from user mode. Measured against what a
debugger is for, on the machines erXos runs:

* **It cannot stop a CPU that masks interrupts.** It stops the other CPUs
  with the debug inter-processor interrupt and retries with what it calls
  an NMI, which on Arm prints `NMI to %d, what's that?` and does nothing
  (`jdb/jdb.cpp`, `Jdb::force_app_cpus_into_jdb`; `jdb/arm/jdb-arm.cpp`,
  `Jdb::send_nmi`).
* **It has no breakpoints on AArch64.** Its breakpoint module for Arm is
  compiled for 32-bit kernels alone (`jdb/arm/jdb_bp-arm.cpp`, whose every
  section is `[arm && 32bit]`), the 64-bit kernel takes no debug exception
  as one (`Thread::is_debug_exception` is constant false,
  `kern/arm/64/thread-arm-64.cpp`), and nothing in the configuration erXos
  builds programs the CPU's debug registers.
* **A board stopped in it resets within 4 s**, when the hardware watchdog
  the root armed fires ([design-fiasco.md](design-fiasco.md#the-watchdog)).
* **Leaving it breaks the console line's ownership**: after a resume the
  kernel and the console's driver both use the UART
  ([design-fiasco.md](design-fiasco.md#the-kernels-lines)).
* **Nothing uses it.** No erXos document describes its commands and the
  harness never drives it or looks for its prompt.

**The Jdb kernel object.** Upstream's `src/kern/jdb_object.cpp` is
GPL-2.0-only, is not in the fork, and is known to erXos only through a
clean-room facts record
([References](#references)); nobody who writes erXos's code or documents
opens it. It is the capability in slot 10 of the first task
(`Initial_kobjects::Jdb`, `kern/globals.cpp`), through which user mode
enters the debugger, feeds it keystrokes, prints bytes on the kernel's
console with no escaping, appends to, clears and maps the trace buffer,
and forwards debug requests to other objects; holding the capability is
the only check. No erXos code names the capability or its calls: not
`liberx`, the runtimes, the system services or the tools.

**Why JDB leaves.** A kernel built with JDB and the kernel's console
input, as upstream's development configuration is, parks every CPU a
fatal kernel error reaches and waits on the console: on QEMU until the
harness's deadline, on a Raspberry Pi 4 until the watchdog resets the
board. Such an image, the website's first images among them, carries a
prompt that reads and writes kernel memory for whoever is at its console
after a panic, and a GPL file. The fork carries neither: its import has no
`src/jdb` and no `jdb_object.cpp`, and `FiascoConfig::FORBIDDEN`
(`tools/lib/erx/fiasco_config.rb`) refuses `CONFIG_JDB` and
`CONFIG_INPUT` in every build kind. Only L4Re's comparison kernel of the
benchmark build keeps JDB, for its board run's reboot
([design-bench.md](design-bench.md)).

**What erXos's own kernel already decides.** It has no kernel debugger
([design-kernel.md](design-kernel.md#the-ledger)). Its panic claims one
panic word, switches to a per-CPU stack, stops the other CPUs with an
inter-processor interrupt, waits at most 100 ms for them, reports and
ends as `erx.panic` says
([design-kernel.md](design-kernel.md#console-log-and-panic)). Before any
end of the machine it writes a crash record, a layout of the ABI file,
brief in release builds and full in development builds, and prints it in
a frame the harness reads
([design-kernel.md](design-kernel.md#the-root-task),
`kernel/core/crash.c`, `kernel/core/crash_frame.c`,
`tools/lib/erx/crash_frame.rb`). The inspector and `/proc` show the
kernel's, the services' and the runtimes' state through one schema,
`abi/inspection.txt`, every value with a status and the party that
reported it ([design-live.md](design-live.md#inspection-records)). Each
CPU keeps a trace ring of sequence-counted records
([design-kernel.md](design-kernel.md#trace-ring)), and a run that takes
input reproduces under QEMU's record and replay
([design-kernel.md](design-kernel.md#deterministic-mode)).

**What the best kernel debuggers teach** (the survey of
[References](#references), which cites each source):

* Windows KD, FreeBSD's gdb(4) with kgdb, QEMU's stub and seL4 keep the
  commands off the target; Linux's own documentation says its in-kernel
  shell needs lock-free helpers in other subsystems.
* illumos mdb and NetBSD's `crash(8)` run one command set on a live
  system and on a dump, and mdb's walkers keep data-structure layout out
  of its commands.
* OpenBSD's ddb and mdb print typed memory from type data the build
  keeps; WinDbg's data model makes debugger state a typed value, not
  text to parse.
* FreeBSD gives every entry a reason from a closed list and stops every
  CPU before its backend runs; its `mac_ddb(4)` exists because a prompt
  that reads memory extracts secrets.
* Linux's documentation says software breakpoints need writable kernel
  text.
* rr and QEMU's replay record only the inputs that cross a boundary and
  re-execute inside it, which makes "when did this value change" a
  question a debugger can answer.
* The record of an unattended failure (FreeBSD's textdump, NetBSD's
  `onpanic`) matters more in practice than the prompt.

## Requirements

Each requirement names its consumer and what breaks without it.

1. **A fatal stop leaves a complete, honest record with nobody
   attending.** Consumer: every failing QEMU run, every board, every
   report from a published image. Without it a kernel failure leaves
   prose that scrolled by.
2. **Every CPU is stopped or reported as not stopped, and one that waits
   for a lock says which.** Consumer: whoever diagnoses a deadlock or a
   hang. A CPU's stale state shown as current is a wrong answer given as a
   right one.
3. **A stopped machine can be read whole**: under QEMU always, under a
   probe, and on a board with nothing attached but its console wire.
   Consumer: kernel, backend and driver developers, for the failures only
   hardware shows, and the harness, which turns each failure into a
   report. Without it a board's failure is its 16 KiB record and nothing
   else.
4. **One command set for every target, and for a held board's own
   console.** Consumer: whoever reads a failure later than it happened,
   and whoever types at a board and then at the tool. Two command sets
   drift apart.
5. **The views are the inspection schema's, and layouts come from the
   build.** Consumer: maintainers and users, who learn one set of paths
   and names. Without it the debugger is a second, hand-written model of
   the kernel that rots silently.
6. **Nothing writes code, and the debugger writes no memory.** Consumer:
   the invariant that no mapping is writable and executable and that the
   kernel writes no machine code. Breakpoints and watchpoints are the
   CPU's hardware ones, set from outside the kernel.
7. **A failure that QEMU reproduces can be read backwards.** Consumer:
   whoever chases a corrupted value: the question is which write made it,
   and that write is in the past.
8. **Kernel mode reads no input except in the hold**, which only a
   development kernel has and only a boot that asked for it enters, and
   what it reads there is one bounded line at a time: a request of a
   fixed layout, or a command of a closed set. Neither writes memory or a
   register. Consumer: the release and the published images, whose
   console must be no route into kernel memory.
9. **No GPL file in any kernel build.** Consumer: distribution of every
   image, and the release's link audit.
10. **One stop core for both kernels.** Consumer: Phase 2, which changes
    what is behind the seam, not the protocol, the tool or their tests.
11. **A held board answers a person who has a terminal and nothing
    else.** Consumer: a developer whose board has no probe, at a host
    without the tree or without the bundle of the build that failed. Why
    the machine stopped, where each CPU was, which threads exist, what
    the kernel did last and what lies at an address are asked by typing.
    Without it a held board says nothing to anything but
    `tools/erx debug`.

**What JDB offers that no consumer needs.** Each is dropped, or answered
by something erXos already has:

| JDB feature | Consumer in erXos | Fate |
| --- | --- | --- |
| the prompt on the console and its modes | a developer at a board's console with a terminal and nothing else | the hold's prompt: a closed set of commands that only read, after a stop, in a development kernel ([The prompt](#the-prompt)); JDB's modes, its writes and its entry into a running kernel are dropped |
| resuming after a stop | none it serves well: the console line then has two users | dropped; QEMU's stub and a probe stop and resume a machine from outside |
| reboot, the exit question | the end of a stop | the stop's end |
| console buffer, system report | the lines before a failure | the record's text; `log` |
| kernel info, per-CPU and interrupt controller state, idle statistics | none named | dropped; `print` reads any of it |
| object list, object, task list, thread lists, thread control block, UTCB | object, thread and space bugs | `inspect` over the schema's kinds; `threads` for the kernel's own list; `print` and `list` for the rest |
| timeouts, sender lists, mapping database | none named | dropped; `print`, `list`, `whatis` |
| page tables, memory dump, entry frame | memory and translation bugs | `whatis`, `x`, `regs` |
| disassembler (off in erXos's configuration) | reading code at an address | `llvm-objdump` on the host, over the build's image |
| breakpoints and watchpoints (32-bit Arm only) | kernel development | `break`, `watch` and `when`, the hardware's, on a target that stops from outside |
| halting a thread | none: thread control is the backend's | dropped |
| IPC and page-fault logging, log event switches, trace buffer, counters, performance events | event history; performance work | the trace rings, always on, read live through `erx:trace` and after a stop through the record's tail and `trace`, on Fiasco as the fork's rings ([design-fiasco.md](design-fiasco.md#the-kernels-trace-rings)); benchmarks are `tools/erx bench`'s |
| entry from user mode, keystroke injection, raw console output, trace-buffer control and mapping (the Jdb object) | none: nothing in erXos calls it | dropped with the object |
| object names set from user mode | none | dropped with the object; names come from the root's records |
| entry at boot and by a console key | none: erXos passes the kernel no such option | dropped |

## Overview

**The kernel stops; the host reads.** A maintainer holds five things:

1. **The stop.** One per boot, never resumed. The first CPU to claim it
   is its **leader**; every other CPU ends in exactly one state of a
   closed set, with its registers in its **stop slot** if it published
   them. The stop's decisions are a pure C17 core,
   `kernel/core/machine_stop.c`, that both kernels link.
2. **The anchor.** One page the kernel writes at boot, from which a
   reader that knows nothing else finds the build, the translation roots,
   the stop slots and the crash record.
3. **A target.** Anything that yields a machine's memory and CPUs: a
   function from physical address to a byte or to "not here", and a list
   of CPUs. A crash record is the smallest target, with CPUs and no
   memory; a memory image is the largest; a held board, a stub and a
   replay are images read on demand.
4. **The bundle.** What the build knows about one build of the system:
   symbols, the layouts of the types a reader names, and the **walkers**,
   declarations that say where the rows of each inspection kind lie in
   memory.
5. **A view.** An inspection record, of the schema `/proc` shows, that a
   walker read from a target's memory, each value with the status the
   schema already has for it.

Every command of the tool is a function of a target and a bundle, and
that one construction gives each requirement:

* The record (1) is written by the path every fatal stop takes, on every
  build and board, with no operator.
* A CPU's state (2) is one value of a closed enum, and "did not answer"
  and "was waiting for this lock" are two of its values, so a reader can
  never mistake silence for a stop. A CPU that starts after the stop
  finds it at its admission and parks, so none runs on unseen.
* A stopped machine is read whole (3) because a target need only yield
  bytes. QEMU yields them all at once, a probe on demand, and a board
  through the hold, a loop that answers "read this range" on the console
  the stop already owns.
* There is one command set (4) because a command sees only the
  interface: one that needs memory a target lacks says so, and nothing is
  written per kind of target. A held board's prompt (11) is the same
  construction from the inside: its commands are functions of the hold's
  one checked read and of tables generated from the declarations the
  tool's are generated from, so they are commands of the tool's set,
  under the same names, printing the same lines.
* The views (5) take their paths, columns, types and statuses from
  `abi/inspection.txt` and their offsets from the build's debug
  information, so a renamed field fails the build, not the debugging
  session, and a user who knows `/proc` knows the debugger.
* Nothing is written (6) because the tool's protocol layers have no
  request that writes memory or registers, and the hold has none either:
  no operation of its frames and no command of its prompt names anything
  to write.
* Reading backwards (7) is the same commands at another moment: a
  recorded run is a target with one more coordinate, the instruction
  count.
* Kernel mode reads input (8) in one state, the hold, which a release
  kernel is built without, and reads it as one bounded line, which its
  first byte makes a frame or a command.
* With JDB out of the tree, its GPL object goes with it (9).
* The core (10) decides from what each kernel observes; each kernel
  supplies the effects.

Three things fall out that no part was built for. Every value a view
shows was read from an address, so "what is at this address" (`whatis`)
and "stop when this attribute changes" (`watch`, and `when` on a replay)
need no knowledge of their own. Every row was read under the schema's
types, so checking every row of a stopped machine against the schema
(`audit`) names the structures that are corrupt. And every read at one
stopped moment can be kept, so a session on a board leaves an image that
gives the same answers after the board has gone.

## Invariants

| Invariant | Why it holds | How it is checked |
| --- | --- | --- |
| **One stop, never resumed.** The first CPU to claim the stop word is the leader; every later entry on any CPU follows that stop or ends the machine, and nothing returns from a stop | one compare-and-swap of one word; the stop path has no return and no request that resumes | the core's exhaustive test; the cell with two CPUs stopping at once |
| **Every CPU is in exactly one stop state**, and a reader has a CPU's registers only if that CPU published them before the reader looked | a slot is written once per boot, its state stored last with release ordering | the core's exhaustive test; the litmus test of the publication |
| **No CPU runs past a stop unseen.** Every CPU that reaches ordinary execution is in the leader's census, or parks at its admission, or both | a CPU's admission stores its bit in the admitted set and then loads the stop word, and the leader's claim stores the stop word and then loads the set, each with a full memory barrier between, so at least one of the two loads sees the other side's store; the stop word is never cleared | the core's exhaustive test; the litmus test of the admission; the cells with a CPU held back in its start |
| **Kernel mode reads input in one state of one build kind**: the hold, of a development kernel, in a boot that carries `erx.hold=1`, and there only as a line of at most `hold_line_max` bytes that its first byte makes a frame or a command | a release kernel is built without the hold and its prompt, which one option builds; the hold is entered from the stop path alone, after the record is printed; nothing else in either kernel reads a line, and one reader gathers every line | the configuration check; the cell that sends requests and commands to a running machine and to a held one without the word; the line reader's exhaustive test |
| **The hold reads readable RAM and writes nothing a request or a command names.** Every read, a request's or a command's, each step of a translation and each row of a walk among them, names a physical range and is refused unless the whole range lies in one range of the anchor's map, which holds only pages the boot map gives as RAM and none it excludes | the core computes the map at boot and refuses one it cannot state whole; one checked read against that map is the frames' and the commands' only way to memory; the request layout has no operation that writes and the command table no command that does; in the commands' core an address of the stopped machine is a type that converts to no pointer | the core's tests of the map, over virtual entries, exclusions inside a range and maps past the anchor's capacity, and of every range against every map; the line's fuzz target; the build that must fail when the commands' core dereferences a machine address |
| **The prompt runs none of the stopped kernel's code.** A command calls no accessor, takes no lock and allocates nothing: it reads the stop's own records, which the kernel hands it by address, and memory through the checked read | the commands are a core that links against the checked read and the polled write and nothing else of either kernel | the core's host build, which links with those two seams alone; the commands' fuzz target over arbitrary memory |
| **Every byte the prompt prints is printable ASCII, a line's end, or the line reader's erase sequence, and every command's output is bounded** | one printer: numbers it formats itself, words of the generated tables, and text read from the machine only through the kernel console's escaping function, `erx_log_escape`; the erase sequence is written by the line reader alone, for an erase alone; every command has a bound on what it reads and prints | the commands' fuzz target; the line reader's exhaustive test; each command's host test at its bound |
| **Nothing sent before a stop ends its hold.** Only `reset` with the hold's token ends it, and the token is derived from the record the stop writes | the token is a pure function of the record's `uptime_ns`; a `reset` without it is answered and runs nothing, a frame with another is dropped | the line reader's exhaustive test; the cell that queues `reset` across the drain |\n| **A held machine's two readers agree.** Whatever the prompt answers for a command, `tools/erx debug -n` answers in the same lines from any target of the same stopped machine; what the prompt cannot answer it refuses by name, never with other lines | one command table, one set of ABI layouts and one walker file generate both | the comparison in `native_hold_prompt`, and on the host over a stop image the test builds |
| **After a stop whose census is complete, the console line has one user, the stop, until the machine ends.** After an incomplete census the stop's output is best effort, and its first line says so | every admitted CPU is parked before the first byte, and nothing resumes; a CPU that did not answer may still write the line, and no lock the leader takes can promise that it will not | the stop cells' transcripts; the cell with a silent CPU that prints; the kernel-lines case of [design-fiasco.md](design-fiasco.md#the-backends-cases) |
| **A hold and a running hardware watchdog never meet** | `erx.hold=1` is honoured only in a boot that is not a trial and whose board watchdog nothing has started; in such a boot nothing starts it | the hold decision's host test over every flag, boot value and watchdog state |
| **The host's debugger writes nothing to its target** | its request builders have a constructor for each request it sends and no other, and none writes memory or registers | a test that no public method builds a write |
| **Nothing the tool keeps outlives its moment.** A page, a register or a view read at one stopped moment is never shown, combined or saved at another | everything the tool keeps of a target is kept under the moment the target names, and a command that lets the machine run or moves it in time discards it before the next read | the stub client's test that reads one address on both sides of a seeded write |
| **Never fabricate.** A value the tool shows was read from the target and checked against the schema's type or the build's layout; what it could not read it shows as `unknown`, `unsupported` or invalid, and every record names its target | commands reach memory only through the target interface, whose reads return bytes or "not here"; views are built by the generated validators | one test per status; the fuzz target that runs every command over random memory |
| **Text from a target reaches the terminal only through the host's line escape** | the tool's one printer | the source check on the host tool's output calls ([design-live.md](design-live.md#invariants), V9), and a fuzz target |
| **One schema for the living and the dead.** A path names the same kind with the same attributes whether the machine's inspector answers it or a walker reads it from memory | the tool's views are built from the host table `tools/gen_abi.rb` generates from `abi/inspection.txt`; walkers are checked against it when the build runs | the comparison of `inspect` on an image with `/proc` read just before it was taken |

## Data model

### Causes

A stop needs no reason enum of its own. The crash record's closed
`crash_cause` of `abi/erx_abi.txt` (`fault`, `halt`, `watchdog`, `panic`)
is the whole set of ways a machine stops, and nothing outside the kernel
adds to it: no key, no message from a line and no call of a domain enters
a stop. The record's fault field and text tell the routes apart:

| Route | Cause | Fault field | Text |
| --- | --- | --- | --- |
| a failed kernel assertion | `panic` | zero | the expression, file and line |
| a panic call, and a check for what must never happen | `panic` | zero | the message |
| an exception that violates a kernel invariant (a kernel trap) | `panic` | the exception's cause, address and program counter | the exception's class |
| a fault of a thread of the root task | `fault` | the fault record | as [design-kernel.md](design-kernel.md#the-root-task) says |
| a halt of the root task outside an ordered shutdown | `halt` | the exit record | as there |
| a missed deadline of the kernel's watchdog | `watchdog` | zero | as there |

On erXos's kernel all six pass through the stop. On Fiasco the root
writes the records of its own three ends in user mode, as
[design-fiasco.md](design-fiasco.md#the-end-path) says, and then asks the
kernel for the reset, which takes the stop from its census on
([On Fiasco](#on-fiasco)).

### CPU stop states

One closed enum, `stop_cpu_state` in `abi/erx_abi.txt`, generated like
every other:

| State | Meaning | Registers a reader has |
| --- | --- | --- |
| `offline` | the CPU had not been admitted when the leader took its census: it never started, or had not finished starting | none |
| `leader` | it claimed the stop; it writes the record and serves the hold | its own at its entry into the stop: the trap's frame, or the call site |
| `stopped` | it took the stop request | those the request interrupted |
| `waiting` | it found the stop word while it waited for a spinlock with interrupts masked | those at the wait, and the lock's address |
| `concurrent` | it entered a stop of its own and found the stop claimed | those at its own entry |
| `starting` | it found the stop word at its admission, before it ran anything | those at its admission |
| `unanswered` | it was in the leader's census and was unpublished when the census ended | none |

Which states have registers is the enum's `registers` attribute. The
record's writer and checker and the harness's reader take it from the
generated predicate, and the stop core derives from it the states a CPU
publishes for itself (every one with registers but `leader`), so a new
state states it once.

`waiting` is how a deadlock shows itself: two CPUs that each name the
lock they wait for are most of the diagnosis. `concurrent` is how a
second, simultaneous failure stays visible: its message is lost, where it
happened is not. `starting` is a CPU that came up into a stopped machine:
it parks before it unmasks interrupts, prints or runs a thread.
`unanswered` is a statement, not an absence: a CPU that neither takes
interrupts nor waits for a lock cannot be reached from inside the machine
([Stopping every CPU](#stopping-every-cpu)).

### Stop slots

Each CPU has a **stop slot**, `erx_machine_stop_slot` in `abi/kernel.txt`:
its state, one auxiliary word (the lock's address for `waiting`, zero
otherwise), the kernel address of the thread it was running, read from
the kernel's own current-thread pointer by the CPU itself as it
publishes (on Fiasco `current()`, the context of the stack it is on),
and its registers, in the layout the architecture's ABI file
gives a stopped CPU: the general registers, the stack pointer, the program
counter and the processor state, the translation root of the space the
CPU was in, by which a reader translates that space's addresses, and for
a CPU that came to the stop by an exception, the exception's cause and
address
([design-arch-aarch64.md](design-arch-aarch64.md#stopping-every-cpu)).
The slots are one array of `@cpu_limit` entries in kernel memory, indexed
by the kernel's CPU number.

A CPU writes its registers and its auxiliary word, then stores its state
with release ordering; a reader loads the state with acquire ordering and
reads the rest only for a state that has registers. A slot is written
once per boot, so nobody ever reads a half-written slot as whole.

The **admitted set** is one word of kernel memory beside the slots, a bit
for each CPU. A CPU sets its bit at its admission, the last step of its
start, and nothing clears one. The leader's census is over this set and
not over whatever account the kernel keeps of its CPUs for other
purposes, so that a bit means one thing: the CPU is at or past its check
of the stop word ([Stopping every CPU](#stopping-every-cpu)).

### The anchor

`erx_debug_anchor` in `abi/kernel.txt` is one page-aligned page in the
kernel image's data. The kernel fills it at boot and completes it when it
starts the root task; after that only its stop word changes.

| Field | Holds |
| --- | --- |
| `magic`, `version`, `crc` | 16 bytes that mark the page; the layout's version; CRC-32C of the whole page, `crc` and the stop word read as zero |
| `build_id` | the build identifier the banner and the crash record carry |
| `image_virtual`, `image_physical` | where the kernel's image runs and where it lies, so a symbol's address gives a physical one |
| `kernel_root`, `root_task_root`, `translation` | the physical addresses of the translation roots of the kernel's own mappings and of the root task's space, the second zero until the root task exists; and the architecture's word that says how such tables are walked, so the reader assumes no kernel's layout |
| `ram` | the readable-RAM map: at most `debug_ram_ranges` (16) ranges of whole pages, each a base and a length, sorted and disjoint; no range when the map was refused ([Readable RAM](#readable-ram)) |
| `slots`, `record` | the physical addresses of the stop slot array and of the crash buffer |
| `stop` | the stop word: zero, or the leader's CPU number plus one |

The anchor is why a reader needs no register and no symbol to begin: it
finds the page, checks it, and from the two translation roots reads any
address of the kernel's or of the root task's. Every other space's root
is in the kernel's records of spaces, which the walkers read.

### Readable RAM

The hold answers for memory, so the kernel must know which physical pages
are memory it may read: a read of a device's register can have an effect,
and a read of a hole, or of memory the firmware keeps, can fault. Neither
kernel's boot memory map is that list as it stands. Fiasco's kernel
information page describes address space as well as memory, and lists
RAM that is in use, and ranges set aside for other reasons, as entries
beside and over the RAM entries ([On Fiasco](#on-fiasco)). So the anchor's map is
never copied from a boot map. One pure function of the core computes it
from one, once, when the kernel completes the anchor:

1. **Classify.** Each kernel hands the core its boot map as entries of a
   base, a length and a class of the closed enum `ram_class` of
   `abi/kernel.txt`:

   | Class | The entry says |
   | --- | --- |
   | `ram` | the range is RAM |
   | `used` | the range is RAM that the kernel, a boot module or a task occupies: the kernel reads it as memory, so it must come out inside the map |
   | `excluded` | the range is not memory the kernel may read: a firmware reservation, a device's registers, or a kind of entry the kernel's table does not list |
   | `ignored` | nothing about physical memory: the entry describes address space, or is empty |

   Each kernel classifies with one table over every kind of entry its
   boot map can hold, and a kind the table does not list is `excluded`:
   a new kind of entry takes memory out of the map until someone decides
   what it is.
2. **Normalize.** The core rounds each `ram` range inward to whole pages
   and each `excluded` range outward, with checked arithmetic, and takes
   the union of the first less the union of the second. The result is the
   **readable-RAM map**: ranges of whole pages, sorted by base, disjoint,
   and joined where they touch.
3. **Refuse, never cut.** The core refuses the map when an entry's end
   overflows, when the result has more ranges than the anchor holds, or
   when a `used` entry, rounded outward, does not lie whole inside one
   range of the result. The kernel's own anchor page, stop slots and
   crash buffer are `used` entries of every boot, so a map that lacks the
   memory the kernel itself stands on is refused before anything trusts
   it.

A refused map is written to the anchor as no ranges, the kernel prints
the reason in one line at boot, and that boot does not hold
([The hold](#the-hold)). A map cut to fit would answer `range` for memory
that is there, which the tool would show as "not memory": a wrong answer
given as a right one.

The map promises what its sources say and no more: every page of it lies
in an entry the boot map gives as RAM and in none it excludes. That a
board's boot map is itself right, with every hole and every range of the
firmware's left out or excluded, is checked on each board by a test
kernel that reads every page of the map once
([Unverified facts](#unverified-facts), P11).

### The record's CPU entries

The full form of the crash record carries one **CPU entry** for each CPU
the stop's census covered, entry N for CPU N, since an `offline` CPU has
its entry too:
`erx_crash_cpu` in `abi/kernel.txt`, 56 bytes, in a fixed array of
`crash_cpus` (16) entries after the backtrace. The header's count
`ncpus`, in the four bytes of padding after `nframes`, is the number of
CPUs the census covered: CPU 0 up to the highest CPU the kernel has
brought online or admitted, the leader included, so a machine with more CPUs than entries says
how many its record leaves out. An entry holds the CPU's number, its
stop state and, for a state that has registers, the program counter, the
stack pointer, the frame pointer, the return address, the processor
state word and the slot's auxiliary word; every other byte is zero. A
record written before any census, as the root's are on Fiasco, carries
none and an `ncpus` of zero.

**The brief form** is the same fixed prefix, with fewer of its fields
filled, and no text but a kernel panic's message. It prints what FreeBSD's release kernel prints
when its kernel faults or panics, and no more. FreeBSD 14.3's arm64
trap handler, on a fatal kernel data abort, prints every general
register of the trap frame, the stack pointer, the link register, the
exception's return address and saved state, the fault address and the
syndrome (`print_registers`, `print_gp_register`, `sys/arm64/arm64/trap.c`
lines 386 to 389 and 411 to 449), under no option: only the symbol
beside each value needs `DDB`, which `GENERIC` lacks. Its `panic` then
prints the message, the CPU and the time, and with `KDB_TRACE`, which
`GENERIC` sets (`sys/arm64/conf/std.arm64` line 73), a backtrace of the
panicking CPU (`sys/kern/kern_shutdown.c` lines 936 to 952,
`sys/kern/subr_kdb.c` lines 439 to 455). So the brief form carries:

* the header and `fault`, as the full form does, for every cause;
* for `panic`, the message, escaped as the full form's text is, and
  no log line; the leader's registers, all of them, as the slot holds
  them, and its kernel backtrace, as code addresses: what FreeBSD
  prints of the CPU that failed. The fault address is written as the
  exception gave it, a user address too, as FreeBSD's `far` line is;
* one CPU entry for each CPU the census covered, with its number and
  stop state alone, every register word zero.

For `fault`, `halt` and `watchdog` it carries no registers and no
backtrace: those are the root task's, in user mode, and FreeBSD prints
nothing of a process's registers when it ends one. FreeBSD names each
frame's function from the kernel's own symbols; erXos's release image
carries no symbol table ([Symbols](#symbols)), and the host's tool names
the frames from the release's published image. What this exposes is the
security section's ([Security](#security)).

In `abi/kernel.txt` this changes names and sizes, not fields: the
120-byte layout `erx_crash_brief` becomes `erx_crash_header`, the header
of both forms, which `erx_crash_record`'s first field names; the brief
form has no layout of its own, since it is `erx_crash_record` with the
brief form's fields filled, so `ERX_CRASH_BRIEF_SIZE`, the old layout's
generated size, no longer gives its length; and a new limit,
`crash_message_max`, bounds the brief form's text, so a brief record's
`length` runs from `ERX_CRASH_RECORD_SIZE` to that plus the bound. The
frame's header line and the crash core's check take their bounds for
`brief` from those two
([design-kernel.md](design-kernel.md#the-root-task)).

The crash core writes the entries from what the stop hands it. Its
writer cannot refuse, since nothing can report a refusal at the
machine's end, so it settles an entry as it settles every other field: a
state outside the enum is written as `unanswered`, and a state without
registers gets none; in the brief form it writes no register word of
an entry, and no registers or backtrace unless the cause is `panic`; it
writes each entry's number itself. Its check refuses an entry whose
number is not its index, a state outside the enum, a nonzero byte where
the state has no registers, a nonzero entry past `ncpus`, an `ncpus`
past `cpu_limit`, and in the brief form a nonzero register word of an
entry, registers, a backtrace or text for a cause other than `panic`,
and text past the message, as it refuses any other malformed field (`kernel/core/crash.c`,
`erx_crash_check`). `kernel/core/crash_read.c` and
`tools/lib/erx/crash_frame.rb` read the entries and are held to the same
answer on mutated frames, as they are for the rest of the record.

The record stays small on purpose: it is what a machine says with nobody
listening, on a console at 115,200 baud, inside whatever time its end
has. A stop slot holds a CPU's whole register set; the record's entry
holds the six words that say where it was.

### The record's trace tail

The full form also carries the newest records of the kernel's trace rings
([design-kernel.md](design-kernel.md#trace-ring)), so a stop that nobody
holds still says what each CPU did last: a boot whose firmware started the
watchdog, a board with nothing attached but a serial log, or a harness
run that keeps only the console. `trace`, the field after the CPU
entries, is `crash_trace_records` (32) records in `erx_trace_record`'s
layout, 2,048 bytes, so the fixed prefix grows from 1,800 to 3,848 bytes,
inside `crash_size`, and at 115,200 baud the frame takes about a quarter
of a second longer. The record is a copy, written once by one writer, so
the ABI file declares the field as an array of the trace record's layout
read without atomics; if the generator cannot yet express a `wire_le`
copy of a `shared` layout, it gains that rather than a second
declaration of the record.

**What fills it.** The crash core is handed the rings, `trace` and
`ntrace` in `erx_crash_input_t`: the kernel's own on either kernel, and on
Fiasco, for the root's own crash record, the root's read-only window onto
the same rings ([design-fiasco.md](design-fiasco.md#the-kernels-trace-rings)).
The root's own ring is not among them; the root's record carries its log.
`ntrace` is how many rings there are, not how many CPUs ran: Fiasco has
eight rings however many CPUs start, and a board of four leaves four of
them empty. The CPUs the tail covers follow from the rings themselves:
the writer loads each ring's head once, with acquire order, and covers
the first `crash_cpus` rings whose head is not zero: a ring never written
has nothing to give, whether its CPU never started or has not yet written. The kernel's stop and the root, which writes its record before any
census, apply the same rule to the same rings, so neither needs a count
of CPUs. Each covered ring gets an equal share of the 32 slots, rounded
down: 8 each for four CPUs, among eight rings or more, and 2 each for
sixteen. For each covered ring the writer reads the share's indices below
the head it loaded through the ring core's reader, keeps a record only
if the reader keeps it and its `cpu` is the ring's, writes each ring's
kept records together, in CPU order and oldest first, and leaves every
other slot zero.

An equal share, not the newest records by time, because the CPU a hang's
reader needs is the one that stopped writing, stuck with interrupts
masked or idle, and a merge by time gives its slots to the busy CPUs.

**What it says, and what not.** Nothing else is stored: a record's `seq`
names its index and its `cpu` its ring, so a reader groups and orders the
tail from the records alone. A gap between two indices of one CPU is a
record that was half written or overwritten while it was read, and
`trace` shows it as such, with its count. What lies at either end of a
CPU's records is not known from the tail: it stores neither the head
the writer loaded nor how many records its reader refused there, so a
refused newest or oldest record, or a covered CPU whose records were all
refused, leaves no trace, and `trace` says that each CPU's ends in a
tail are unknown, never that nothing was lost. The newest record of a
CPU that did not answer the census is the likeliest such loss; its entry
says that it did not answer. The ring's whole counts of overwritten and
half-written records belong to the readers of whole rings, the live
trace and the hold's `trace`.

**Checks.** The writer cannot refuse, and what it writes passes the
check by construction. `erx_crash_check`, `kernel/core/crash_read.c` and
`tools/lib/erx/crash_frame.rb` refuse a nonzero slot after a zero one, a
slot whose `seq` is odd or zero, a `cpu` at or past `cpu_limit`, one
CPU's records apart or out of order, and any nonzero slot in the brief
form, and they are held to the same answer on mutated frames.

**Who sees it.** The brief form carries no tail, since records hold other
domains' user addresses and timing, as registers may hold what the
interrupted code held. A frame written for a task's fault that the
machine survives carries none either: the machine runs on, and its rings
stay readable through the trace.

### The hold's frames

A held machine reads its console a **line** at a time: at most
`hold_line_max` (80) bytes, ended by a carriage return or a newline. A
line's first byte says what it is. One that begins with
`hold_request_mark`, a character no command begins with (`=`), is a
**frame line** and carries a request of the host's tool. Any other is a
**command line**, typed by a person ([The prompt](#the-prompt)). The
reader decides at the first byte, before it knows anything else of the
line, so no line is both and none has to be decoded to find out which it
is.

A held machine and its host exchange two layouts of `abi/kernel.txt`,
both as printable text, since the line they cross is a console that a
terminal may be showing:

* **A request**, `erx_hold_request`: a magic, an operation of the closed
  enum `hold_op` (`read`, `anchor` or `reset`), a sequence number the
  reply repeats, a physical address, a length of at most `hold_read_max`
  (4,096) bytes, and a CRC-32C of the rest; a `reset` carries the hold's
  token in its address field ([The hold](#the-hold)). It travels as one
  frame line: the mark, the layout in base64, then a newline.
* **A reply**, `erx_hold_reply`: the request's sequence number, a status
  of the closed enum `hold_status` (`ok`, `range` or `length`), the
  address, the length, a CRC-32C, and then `length` bytes of memory, none
  unless the status is `ok`. It travels in a frame of the crash frame's
  own shape, between the lines `--erx-hold-begin <length>` and
  `--erx-hold-end`, 57 bytes to a 76-character line of base64, so one
  frame writer and one frame reader serve the record and the hold
  ([design-kernel.md](design-kernel.md#the-root-task)).

The hold announces itself with one line, `--erx-held <anchor> <token>`,
the anchor's physical address and the hold's token in hexadecimal, which
the reply to `anchor` repeats, the address in its address field and the
token as its two bytes, for a tool that attaches to a machine already
held. The marker
strings, the mark, the limits and both layouts are declarations of the
ABI file, and the C and Ruby readers and writers are generated from them;
the generator refuses a `hold_line_max` that a request's line does not
fit.

### Targets

The host's one interface, which each kind of target implements:

| Operation | Crash record | Memory image | Held board | Stub | Replay |
| --- | --- | --- | --- | --- | --- |
| list the CPUs and give one CPU's registers | the record's entries: six words a CPU, none for `unanswered` and `offline` | the image's register notes, and the stop slots through the anchor if the machine stopped itself | the stop slots through the anchor | the stub's threads, one a CPU: the core registers from one reply, any other by its number ([The GDB remote protocol subset](#the-gdb-remote-protocol-subset)) | as a stub |
| read physical memory | nothing: every read is "not here" | the image's segments; a gap is "not here" | a `read` request; a refusal or a silent line is "not here" | the stub's memory read in physical mode | as a stub |
| stop, continue, break, watch | no | no | no | yes | yes |
| move in time | no | no | no | no | yes: back to the last break or watch, and to an instruction count |
| end the machine | no | no | `reset` | no | no |
| name the moment ([Moments and images](#moments-and-images)) | the record's own | the image's own | the stop | a count the tool advances each time the machine has run | the instruction count |
| give the crash record | the file's frame | the crash buffer the anchor names, if the machine stopped itself | as an image | as an image | as an image |

* A **crash record** is a file that holds a crash frame: a console's log,
  or the text of `/proc/kernel/crash`.
* A **memory image** is an ELF core of the machine's physical memory, the
  form QEMU's `dump-guest-memory` writes with `paging` false, and the
  form the tool itself writes when it saves a moment.
* A **held board** is a machine in the hold, reached through its console:
  a serial device, or the console socket of a QEMU run.
* A **stub** is anything that speaks the GDB remote protocol, stops the
  whole machine from outside and reads its physical memory: QEMU's stub,
  or a hardware probe's software.
* A **replay** is a stub over a QEMU run that was recorded, together with
  QEMU's machine protocol for moving to an instruction count.

A command declares what it needs of a target (CPUs, memory, control,
time), and a target that lacks it gets one refusal that names the target
and the need. No command has a case per kind: `report` and `log` take the
record and the moment through the last two operations, as every other
command takes memory through the second.

### The bundle

The tool reads symbols and layouts from the **debug bundle** of the build
that made the target, which the image build writes into the build tree
under the build identifier:

* each image with its debug information: the kernel's (on Fiasco,
  `fiasco.debug`) and the root task's;
* the **layout table**: for every type a walker or the tool names, its
  size, and each named field's offset, size and encoding;
* the walkers, checked and resolved;
* the host's inspection table, which is the schema's.

The tool takes the build identifier from the anchor, or from the record's
header where there is no memory, and uses the bundle of that identifier.
A target whose identifier matches no bundle the tool can find is shown
with raw addresses and no types, and the tool says why. A published
build's bundle is kept outside the repository with that build's records
([Decisions](#decisions)).

### Views

A view is an inspection record as
[design-live.md](design-live.md#inspection-records) defines it: a path, a
kind, attributes each with a reporter and a status. A walker gives each
attribute the reporter whose state it read: `kernel` for the kernel's own
structures, `service` or `runtime` for theirs, and on Fiasco the backend
reporter the schema lists for what the root keeps in the kernel's place.
The statuses are the schema's, with these readings:

| Status | When a walker gives it |
| --- | --- |
| `ok` | the value was read and is of the attribute's type |
| `partial` | the walker reads a structure the schema says holds part of the meaning, as the root's pool does for a budget's `used` |
| `{error, invalid}` | the value was read and is not of the attribute's type; the tool shows the raw bits beside it |
| `unknown` | the memory that holds it could not be read |
| `unsupported` | no walker of this build reads it |

A derived attribute is computed by the inspector's own rule: `ok` only
when every input is. Every record the tool prints is headed by its target
and the moment it describes, and every value's reporter is printed as
`LABEL memory`, so no line of the tool's output passes for a report a
running machine made.

## The stop

Every fatal stop of either kernel enters the stop, which does not
return:

1. **Claim.** It compares and swaps the machine's stop word, in the
   anchor, from zero to its own CPU number plus one. The core turns the
   word it observed and the CPU's own depth into one of four decisions.
   A CPU's **depth** counts its entries into a stop path, this one
   included: each claim, and each park the core's check decides, at the
   stop request, in a lock's wait or at the admission
   ([Stopping every CPU](#stopping-every-cpu)). Each kernel raises the
   depth first, in the one routine every claim and every such park goes
   through, before the claim or any write to the slot, so a CPU that
   parked and faults again comes back at depth two or more.
   * **lead**: the swap succeeded, and this CPU is the leader;
   * **follow**: another CPU leads the stop, and this is the CPU's first
     entry, so it publishes its slot as `concurrent` and parks;
   * **follow silently**: another CPU leads the stop, and this CPU is at
     depth two or more: it parked or followed already and has faulted
     again. It parks and publishes nothing, so its first publication
     stands. If the fault cut that publication short before the state's
     store, the slot reads zero, and the record shows the CPU as
     `unanswered`, or `offline` outside the census;
   * **nested**: this CPU leads the stop and has faulted again inside it.
     At depth two it prints one line, `erx: nested stop`, through the
     polled write and ends the machine; at any greater depth it ends
     without printing, since the print may be what faulted.
2. **A fresh stack.** The leader switches to its CPU's panic stack, found
   through the CPU's hardware identifier and a table written at boot, so
   it trusts no pointer of the failing state.
3. **Ask.** It loads the admitted set, once, with a full memory barrier
   between its claim and the load, sends the stop request, an
   inter-processor interrupt, to every CPU of the set but itself, and
   wakes every CPU that sleeps in a spinlock's wait.
4. **Census.** It waits until every CPU it asked has published its slot,
   or the clock leaves the census's window. The window runs from the
   time of the request up to `stop_census_ms` (100) after it; a reading
   earlier than the request, or the bound or more after it, falls
   outside. Each round the core decides from the CPUs asked, those
   published, the time and the window: wait, or finish with every CPU's
   state. It looks at the slots first, so a round in which every CPU
   asked has published ends the census **complete**, whatever the clock
   reads. A round with a CPU missing and a reading outside the window
   ends it **incomplete**, and each CPU unpublished when the census ended
   is `unanswered`. The clock is a free-running counter the stop does not
   stop; each kernel reads it in program order and it never wraps, so a
   reading outside the window means the bound has passed or the counter
   is broken, and either way the leader stops waiting. A CPU outside the
   set needs no second look: it parks at its own admission
   ([Stopping every CPU](#stopping-every-cpu)).
5. **Record.** It walks its own frame pointers, at most 64 frames, each
   checked to lie inside the stack it claims, and hands the crash core
   the cause, the message, its registers, the frames and each CPU's
   entry. The boot image's development flag chooses the form, as for
   every crash record.
6. **Print.** It takes the console path's lock, with a bounded number of
   tries, and keeps it until the machine ends; a leader that failed while
   it held that lock holds it already. Then it writes the report's first
   part, which is the record's own fields as text for the person at the
   console (the message; for a `panic`, the leader's registers and
   backtrace in either build; and one line for
   each CPU with its state, and in a development build where it was),
   and the crash frame, through the console's polled write alone.
   * After a **complete** census every admitted CPU is parked, so nothing
     else writes the line, with the lock or without it.
   * After an **incomplete** census the output is **best effort**. A CPU
     that did not answer may hold the lock, or be writing, and the leader
     then prints without the lock rather than wait for a CPU that may
     never let go. The report's first line names the CPUs that did not
     answer and says whether the lock was taken. A frame that another
     writer's bytes fell into fails its reader's checks and is reported
     as damaged, never read as whole.
7. **Hold**, where the boot allows it ([The hold](#the-hold)).
8. **End.** It writes the last line, which names the end, and ends the
   machine as the kernel's policy says: on erXos's kernel by `erx.panic`
   and the machine lease
   ([design-kernel.md](design-kernel.md#configuration)); on Fiasco by a
   reset, as every end of the machine there
   ([design-fiasco.md](design-fiasco.md#the-end-path)).

**What the core decides.** `kernel/core/machine_stop.c` holds the stop's
decisions as pure functions: the claim, over the observed word, the CPU
and its depth; the admission, over the observed word; the census step,
over the CPUs asked and those published, the time and the bound; each
CPU's final state; the readable-RAM map, from a boot map's entries;
whether the boot allows a hold; the hold's line reader, over its state
and one received byte; and the hold's step, over one finished line. It
reads no hardware and no global state, builds for the host, and its
machine is explored exhaustively there. The compare-and-swap, the
barriers, the request, the slots, the clock, the frame walk, the console
and the end are each kernel's effects. The prompt's commands are a core
of their own, `kernel/core/hold_commands.c`, with two effects that each
kernel supplies: the checked read and the polled write
([The prompt](#the-prompt)).

**Order.** The leader stops the others before it prints, so after a
complete census a report never interleaves with a console driver still
writing. The order costs up to the census bound of silence when a CPU
does not answer, which the record then names.

### Stopping every CPU

A CPU learns of the stop in one of four ways, and each leaves its own
state:

* **The stop request**, at its next point with interrupts unmasked: in
  user mode, waiting idle, or at a preemption point of the kernel. It
  publishes the registers the request interrupted as `stopped` and parks
  with interrupts masked, taking no lock on the way. erXos's kernel
  bounds every stretch between preemption points
  ([design-kernel.md](design-kernel.md#invariants), K13), so a correct
  kernel of its own answers within that bound.
* **A lock's wait.** A spinlock is the one place a correct kernel waits
  without bound with interrupts masked, and a deadlock is that wait never
  ending. The wait loop of every spinlock loads the stop word on each
  pass, and a waiter that finds it set publishes its registers and the
  lock's address as `waiting` and parks. The check sits only on the
  contended path, costs one load of a word that is zero for the whole
  life of a healthy machine, and reaches the commonest hang with no
  interrupt at all. erXos's kernel has one spinlock, the ticket lock
  ([design-kernel.md](design-kernel.md#execution-model-and-locking)), so
  one loop carries the check; the Fiasco fork carries it in Fiasco's
  spinlock and in the cores' ticket lock ([On Fiasco](#on-fiasco)).
* **Its own stop**, when it fails while another CPU leads the stop:
  `concurrent`.
* **Its admission**, when it starts while the machine is stopped, or
  stops. A CPU enters ordinary execution only through one step, the last
  of its start, taken with interrupts masked once everything it needs to
  take the stop request is set up: it sets its bit in the admitted set,
  executes a full memory barrier, and loads the stop word. If the word is
  set it publishes its registers as `starting` and parks, having run
  nothing. The leader does the mirror image: its claim, a barrier, then
  its one load of the set. Of the two loads at least one sees the other
  side's store, so a CPU is in the leader's set and is asked, or finds
  the stop at its admission, or both, and never neither. The stop word is
  never cleared, so this holds for a CPU that starts a minute after the
  census as for one that starts during it, and the census never asks
  again which CPUs exist. A CPU that is asked and also parks at its
  admission has published, so the census counts it and does not wait for
  it.

What none of these reaches is a CPU that runs in kernel mode with
interrupts masked and waits for no lock: a loop that never ends, which in
a kernel with bounded paths is a bug of that loop. The stop does not
pretend otherwise. It reports the CPU as `unanswered`, and a target that
stops the machine from outside, QEMU or a probe, then shows where that
CPU is. Reaching such a CPU from inside needs an interrupt that the
kernel's masking cannot mask, which on AArch64 means changing how the
kernel masks interrupts everywhere or resting on firmware support that is
unverified on erXos's boards; the binding lists each route, what it would
take and the probe that would settle it, and takes none
([design-arch-aarch64.md](design-arch-aarch64.md#stopping-every-cpu)).

A CPU that unmasks interrupts after the census takes the pending request
then and parks, and one that starts after it parks at its admission, so
no CPU returns to user mode after a stop, and no thread runs again on
any CPU that takes interrupts.

### The hold

A stop ends the machine. In a boot that asks for it, the stop first
**holds**: after the crash frame it prints `--erx-held` with the anchor's
address, then a prompt, and answers the lines it reads on the console
until one of them is `reset`. Two readers share the line. The host's
tool sends requests as frames, and a person at any terminal types
commands ([The prompt](#the-prompt)).

**When a boot holds.** One pure function of the core decides, and both
the kernel and, on Fiasco, the root call it: a hold is allowed when the
boot image carries the development flag, the command line carries
`erx.hold=1`, the boot is not a trial, no machine lease is held, and the
board's hardware watchdog is not running. A boot that carries the word
and holds no lease is **attended**: nothing in it starts the board's
watchdog, neither the root on Fiasco nor erXos's kernel, since a
developer's host is what watches it. The kernel asks one thing more,
which the root cannot see and need not: a stop holds in an allowed boot
only if the kernel's readable-RAM map was not refused
([Readable RAM](#readable-ram)). A boot that carries the word and will
not hold, because the firmware already started the watchdog or the map
was refused, says so and why in one line at boot, and the kernel reloads
a running watchdog as ever. A
release kernel is built without the hold, whatever image it boots, and a
release build refuses a boot whose command line carries the word, as it
refuses `erx.det=1`.

**After an incomplete census** the hold is entered all the same. That
stop is the one a developer most needs to read, and under QEMU the
hold's line is the moment the harness takes its image at, where the
emulator shows the CPU the kernel could not reach. What the hold then
gives is less. The tool says so at the head of everything it prints, and
the hold in a line before each prompt, which names the CPUs that did not
answer: such a CPU may still write the line, so a reply can arrive
damaged, which its CRC catches and the tool asks for again, and a
command's output can arrive with another writer's bytes in it; and it
may still write memory, so what is read may change while it is read
([Moments and images](#moments-and-images)).

**The line.** Before it prints `--erx-held` the leader discards what the
console UART has already received, at most `hold_line_max` bytes: that
was typed at the machine that stopped, not at the hold. From then on it
polls the UART's receive register and hands each byte to the core's line
reader, whose state is the line so far and its kind. The drain makes the
first prompt tidy and promises nothing more: bytes still on their way
when it ran, from a terminal's buffer, a USB adapter's or a host tool
that was talking to the running machine, arrive after it and are read as
lines like any other. Such input can run a command that only reads. It
cannot end the hold, because ending it takes the hold's token.

**The token.** One pure function of the core derives a 16-bit number
from the crash record the stop has just written: bits 10 to 25 of its
`uptime_ns`, the monotonic time at the end, which no byte sent before
the stop could know. `--erx-held` prints it, the reply to `anchor`
carries it, and the host's tool computes it from the record it reads, by
the generated Ruby twin of that function. A `reset` request carries it in
its address field, and a typed reset is `reset TOKEN`. A bare `reset`,
or one with another number, ends nothing and is answered
`reset: type reset TOKEN to end the hold`, with the token, so a person
who types `reset` is told the one word more, and a stale `reset` that
was queued before the stop runs nothing. A `reset` frame with the wrong
token is dropped like any frame that fails its checks.

* The first byte a line keeps chooses its kind
  ([The hold's frames](#the-holds-frames)), and a carriage return or a
  newline ends the line; a newline right after a carriage return belongs
  to the same end. A line that ends empty prints the prompt again and
  nothing else.
* A **frame line** is gathered in silence. At its end the core checks it:
  the right length, base64, the magic, the CRC, an operation of the enum.
  A line that fails any check is dropped without a byte of output, so a
  tool's session carries its replies and nothing else, and noise that
  begins with the mark draws no answer.
* A **command line** is echoed as it is typed. It takes printable ASCII
  alone; a backspace or a delete erases its last byte, if it has one, and
  the reader writes the erase sequence, backspace, space, backspace
  (0x08 0x20 0x08), which only the reader writes and only for an erase;
  any other byte is dropped unechoed. At its end the core parses it, runs the
  command and prints the prompt again. A line that grew past the bound is
  refused whole at its end, never run as its first bytes.

There is no other editing, no history and no completion, and a line's
end clears the reader's state.

**Requests.**

* `read` with a length above `hold_read_max` is answered `length`.
* `read` whose range does not lie whole inside one range of the anchor's
  map is answered `range`. The map holds no device register, no hole and
  nothing the boot map excludes ([Readable RAM](#readable-ram)), so the
  hold never touches a register whose read has an effect.
* Any other `read` is answered `ok` with the bytes, copied through the
  kernel's own mapping of RAM
  ([design-arch-aarch64.md](design-arch-aarch64.md#kernel-access-to-memory))
  or, on Fiasco, through one page of kernel address space at which the
  glue maps each page of the range in turn. A read that faults all the
  same, at a page the boot map wrongly gave as RAM, is a fault inside the
  stop: a nested stop, which ends the machine
  ([Failure handling](#failure-handling)).
* `anchor` is answered `ok` with the anchor's physical address in the
  reply's address field and two bytes, the token, little-endian, so
  a tool that attaches to a machine already held learns what
  `--erx-held` said.
* `reset` with the token ends the hold at once.

That check and copy are the **checked read**, the hold's one way to
memory: the frames' `read` and every command of the prompt go through
it. A reply begins on a line of its own: where the prompt or an echo has
left the console's line open, the reply's writer ends it first. No
prompt follows a reply.

**The end.** The hold ends in one way, `reset` with the token, sent as a
request or typed as a command, and the machine then resets: on Fiasco as
at every end, and on erXos's kernel by the `reset` end of `erx.panic`
([design-kernel.md](design-kernel.md#configuration)) whatever the boot's
word says, since someone at the machine asked for it by name. Nothing
bounds how long a machine holds. A boot that holds is attended, and a
stop in it waits for its developer as a hang in it does: the failure
stays readable for the person who comes back to the board an hour later,
and a tool that died or a cable that came out costs time and nothing
else ([Decisions](#decisions), 10). The hold keeps no state from
one line to the next. It has no request and no command that writes,
resumes or changes a register, and no state a line could corrupt. What
it writes is its own: the line it gathers, the leader's stack, the UART
and, on Fiasco, the one translation entry of its window.

**What it costs to read a board.** At 115,200 baud a reply of 4 KiB takes
about half a second, so a board yields about 8 KiB of memory a second
(an estimate from the line's rate and the frame's encoding): enough for
every CPU's stack, the trace rings' tails and the tables the report
walks, in about a minute, and not for a board's whole RAM. The tool reads
what a command needs and nothing else.

### The prompt

A held machine prints `hold> ` and reads commands, so that a board with
a serial terminal and nothing else answers the first questions about its
own stop. The prompt is named for the state it is in. It is not FreeBSD's
`ddb` and does not wear its prompt: it cannot write, set a breakpoint,
step or continue. Where one of its commands does what a `ddb` command
does, it answers to that command's name as well as its own.

**The construction.** A command is a pure function of three things: the
stop's own records, which the kernel hands the commands' core by address
(the anchor, the stop slots, the crash buffer, the kernel's trace rings,
its log and its symbol table); the checked read of
[The hold](#the-hold); and tables the build generates. Its one effect is text through the stop's polled write.
The core, `kernel/core/hold_commands.c`, is C17, builds for the host as
every core does, and links against those two effects and nothing else of
either kernel. Four properties follow from that, and none needs a rule
per command:

* **It only reads.** No command has an operand that names something to
  write, and the core cannot store through an address of the stopped
  machine: such an address is a type of its own, a one-member structure
  that converts to no pointer, which only the checked read accepts.
* **It touches no device and follows no wild pointer.** Every address a
  command is given or finds in memory, each step of a translation and
  each row of a walk among them, goes through the checked read, which
  refuses whatever is not readable RAM. A corrupt structure ends a walk
  with a mark, and never the machine with a fault.
* **It runs none of the stopped kernel's code.** It calls no accessor,
  takes no lock and allocates nothing, so it never waits for a lock that
  a parked CPU holds, and no subsystem keeps a routine for a debugger to
  call safely.
* **It is the tool's command set, generated.** A command is a row of the
  table that also gives the tool its commands ([Commands](#commands)).
  The registers' names and order, the stop states, the causes and the
  trace events with their arguments come from the ABI files; a listing's
  rows and attributes come from the walker file of the kernel's own image
  and from the inspection schema ([Walkers](#walkers)). The kernel has no
  formatter that someone wrote by hand beside the tool's.

**The commands.** Names are typed whole. A command answers to its own
name and to the name in the second column, which is FreeBSD's `ddb`'s
for the same command. An address is hexadecimal, with `0x` or without,
and every other number is decimal unless it begins with `0x`.

| Command | In `ddb` | Prints | Reads |
| --- | --- | --- | --- |
| `help` | `help` | the commands, a line each | the generated table |
| `show panic` | `show panic` | why the machine stopped: the cause, the message, the build and the leader's CPU | the crash buffer, through the crash core's reader |
| `cpus` | none | each CPU's number, stop state, program counter and stack pointer, the thread it was running, and for `waiting` the lock's address | the stop slots |
| `regs [CPU]` | `show registers` | one CPU's registers, the leader's when none is named, each that falls in the kernel's code with its function and offset | that CPU's stop slot |
| `bt [CPU \| thread ID]` | `bt`, `where` | a backtrace by frame pointers, 64 frames at most, each an address and, in the kernel's code, its function and offset | the registers of [A thread's registers](#a-threads-registers); then two words a frame, each frame inside the stack it claims, translated in the space that CPU was in or in the kernel's |
| `threads` | `show threads` | every thread the kernel holds, a line each: its ID, its address, its state, where it is (running on a CPU, switched out, or never run) and its saved program counter | the walk of kind `thread` in the kernel's own image |
| `thread ID` | `show thread ID` | one thread: the same, and its registers where it has them | the same walk |
| `trace [N]` | none: `ddb`'s `trace` is its `bt` | the newest N records of the kernel's trace rings ([design-kernel.md](design-kernel.md#trace-ring)), 32 when no number is given and `hold_trace_max` (256) at most, merged by time, oldest first, each with its CPU, thread, event and named arguments, and a count wherever a ring's own reader rule says records were overwritten or half written | the rings, through the ring core's reader |
| `log [N]` | `show msgbuf` | the last N lines of the kernel's log | the log, through the log core's reader |
| `x[/bhlg] ADDRESS[,COUNT]` | `x` | COUNT units of memory in hexadecimal, of 1, 2, 4 or 8 bytes each, 8 when no size is given and one unit when no count is, `hold_read_max` bytes at most; for bytes, printable ASCII beside them and a dot for every other byte; for 8-byte units, a value in the kernel's code with its function and offset | the checked read, after a translation for a virtual address |
| `reset TOKEN` | `reset` | nothing: it ends the hold, and the machine resets; without the token, or with another, the line that names it | nothing |

An `ADDRESS` is a kernel virtual address; or `p:` and a physical one; or
a space, a colon and a virtual address in it, the space written `root`
for the root task's, whose translation root the anchor holds, or `cpuN`
for the one CPU N was in when it stopped, whose root is in its slot. A
thread's ID is the number the kernel's trace records carry for it, so a
record of `trace` leads to a line of `threads` and from there to a
backtrace. One rule gives it on both kernels: it is the value a trace
record's `thread` field holds, which on erXos's kernel is the thread's
object number and on Fiasco the object id plus one (`Kobject_dbg::_dbg_id`,
`kern/kobject_dbg.cpp`, as
[design-fiasco.md](design-fiasco.md#the-kernels-trace-rings) gives the
fork's rings), and the walker's `id` line names that field and that
offset of one, so the prompt and the rings cannot disagree about a
number.

`x` takes `ddb`'s sizes and its `ADDRESS,COUNT` form and prints
hexadecimal alone. Unlike `ddb` it keeps no current address and no last
format from one command to the next, and it has no radix variable.
`trace` is the kernel's trace rings, as it is in the tool and in
`erx:trace`; `ddb`'s `trace` is its stack trace, which here is `bt` and
`where` ([Decisions](#decisions), 11). On Fiasco the rings are the
fork's, one static array of the kernel's image, `erx_trace_rings`, always
written ([design-fiasco.md](design-fiasco.md#the-kernels-trace-rings));
the glue hands the commands' core its address and count, and the prompt
reads it through the checked read with the ring core's reader, as the
root reads the same pages through its read-only window.

**Translation.** A virtual address is translated by the architecture's
table walk: one pure function of a translation root, the anchor's
`translation` word and an address, which reads each table entry through
the checked read and is bounded by the tables' depth
([design-arch-aarch64.md](design-arch-aarch64.md#stopping-every-cpu)).
The tool's architecture layer has the same walk in Ruby
([Walkers](#walkers)), and the two are held to one answer over the same
tables. The prompt never loads through a virtual address of the stopped
kernel, its own mappings included: a kernel address can be mapped to a
device's registers, and the walk ends at a physical address that the map
check then accepts or refuses.

**What it refuses.** A command that the kernel cannot serve is refused
in one line that says who can:

* `log` on Fiasco, where the log is the root's and not the kernel's
  ([design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel),
  FD26): the tool reads it from the root's memory.
* An attribute that no walker of the kernel's image reads is shown as
  `unsupported`, the schema's word, and one whose memory could not be
  read as `unknown`.
* A name that is no command, `ddb`'s `write`, `break`, `continue` and
  `ps` among them, is answered
  `NAME: unknown command; help lists the commands`.

The rest of the tool's set stays the tool's, which reads the same held
machine through the frames: names beyond the kernel's functions, such as
a data symbol's, a source line and a frame's arguments; the inspection paths,
whose records the root's tables identify and mostly hold on Fiasco;
`print`, `list`, `whatis` and `audit`, which need the build's type data;
and everything that controls a machine or moves it in time. A walk that
cannot finish is marked as the tool marks one: truncated at its bound,
cyclic at a row it has already read, or cut at an address it could not
read.

**Output.** One printer writes everything a command prints, through the
stop's polled write: numbers it formats itself, words of the generated
tables, and text that was read from the machine, the stop's message and
log lines, only through the kernel console's escaping function,
`erx_log_escape`, which escapes tab and newline too, since all of it is
text attributed to a source. A value outside its enumeration is printed
as its number and the word `invalid`. So every line the prompt prints is
printable ASCII, whatever the memory held, and the echo is of bytes the
line accepted, which the reader's rule makes printable ASCII; the one
other sequence on the line is the reader's erase. Every
command reads and prints within a bound (64 frames, `hold_trace_max`
records, `hold_read_max` bytes, a walker's rows), a few seconds of the
line at 115,200 baud at most, so the prompt has no pager and no key that
interrupts a command. The leader reads the line between commands only:
what is typed while a command prints is kept as far as the UART's own
receive buffer holds it.

**The tool on the same machine.** A person and the tool take turns on
one wire. The tool, started with `--held`, first sends `hold_line_max`
backspaces and a newline, which empties a command line that was begun
and not entered without running it, and then asks for the anchor
([The host's debugger](#the-hosts-debugger)); the prompts and echoes
before its first reply are lines its frame reader passes over, as it
passes over every line that is not a frame's. The tool leaves a held
machine held unless it is told `reset`, which it sends with the token,
so commands typed at a terminal
and runs of the tool alternate over one stopped machine, and the lines
they print for one command are the same
([Verification](#verification-and-testing)).

#### A thread's registers

A thread is in one of three places when the machine stops, and the
prompt gives registers for each from the one source that is true for
it:

* **Running on a CPU.** Each stop slot names the thread its CPU was
  running, a field the CPU writes from the kernel's own current-thread
  pointer as it publishes ([Stop slots](#stop-slots)). Such a thread's
  registers are its CPU's slot, whatever its saved context says: a
  running thread's saved stack pointer is the one it left at its last
  switch, and its stack has been used since. `thread ID` says
  `running on cpuN`, and `bt ID` is `bt N`. A CPU that is `unanswered`
  or `offline` names no thread, and a thread it was running is shown as
  switched out, with the mark `cpu did not answer` beside its context.
* **Switched out.** Its saved context is what the kernel's switch left:
  on erXos's kernel the thread's saved registers, which the walker's
  `context` line names; on Fiasco the stack pointer saved in
  `Context::_kernel_sp`, at which the switch stored a continuation
  address and, eight bytes above it, the frame pointer
  (`Context::arm_switch_gp_regs`, `kern/arm/64/context-arm-64.cpp`). The
  backtrace starts at that continuation and frame pointer.
* **Never run.** A thread made and not yet switched to has a saved stack
  pointer that its creation set, with no frame saved at it (on Fiasco,
  `Context::Context` sets `_kernel_sp` to the thread's register frame,
  `kern/context.cpp`, and `prepare_switch_to` stores the continuation
  alone). The walk's bound settles it with no case of its own: every
  frame pointer must lie above the last and inside the thread's own
  stack, which on Fiasco is the thread's block (`context_of`,
  `kern/context.cpp`), and a word that does not is the end of the
  backtrace, marked `cut`.

#### Symbols

A development image that may hold carries a **kernel symbol table**, so
`bt`, `regs` and `x` name the function an address of the kernel's code
falls in, with the offset into it, on a terminal and nothing else.

* **One source.** The image build makes it from the linked kernel's own
  symbol table, with LLVM's `llvm-nm` and `llvm-cxxfilt` as subprocesses:
  every function symbol of the kernel's text with its address and size,
  sorted by address, each name demangled and cut to
  `hold_symbol_name_max` (64) bytes. The generator writes one entry per
  function, its start as an offset from the image's text and its size,
  each 32 bits, and one pool of names, and refuses a table past
  `hold_symbols_max` (1 MiB), a name with a byte outside printable ASCII,
  and two functions that overlap. Nobody lists a symbol by hand.
* **Where it lies.** The table is an item of the boot image, beside the
  kernel and not inside it, since a table put back into the image it
  describes would move the addresses it gives. The boot stage loads it
  into memory the boot map gives as used, as it loads every boot module,
  so it lies inside the readable-RAM map, and the anchor records its
  physical address, its length and the build identifier it was made for,
  as `symbols`; a boot without the table writes zero there. The prompt
  reads it through the checked read, a binary search of the entries and
  then one name, about twenty reads of a few bytes for each address.
* **When it is trusted.** The table is used only when its header names
  the anchor's build identifier and its counts fit its length; otherwise
  every address prints bare and the first command that would have named
  one prints `symbols: none` or `symbols: wrong build` once. An address
  inside no entry, or past its entry's size, prints bare.
* **Never in a release image.** The image packer adds the table only to
  an image with the development flag, and refuses a release image that
  would carry it, as it refuses `erx.hold`, and the release build check
  proves its absence from a release image; a release kernel has no
  prompt to read it.
* **The tool agrees.** The host's tool has the build's full debug
  information, and names a frame by it, in full. For the lines it shares
  with the prompt (`-n`), it applies the same projection to the same
  image's symbols, the same Ruby function the generator uses, so the
  two print the same function and offset; the comparison in
  `native_hold_prompt` and on the host over a stop image is its oracle.

## The host's debugger

`tools/erx debug [-n] TARGET [COMMAND [ARGUMENT...]]` opens one target
and runs one command, `report` when none is given; with `-` for the
command it reads commands from standard input, one a line. With `-n` it
prints an address as a number and no symbol beside it, as `netstat -n`
prints a host. `TARGET` is a file (a
crash record or a memory image, told apart by its first bytes),
`--tty DEVICE` or `--socket PATH` (a held board's console), `--stub PATH`
(a stub's UNIX socket) or `--replay DIRECTORY` (a recorded run). The tool
is Ruby host tooling, never runs on the target, and holds one target at a
time.

On a console (`--tty`, `--socket`) the tool is a plain terminal until the
machine stops: it carries the line's bytes both ways unchanged. When the
crash frame and `--erx-held` arrive, it takes the line for the hold's
frames. With `--held` it takes a machine that holds already, one a
person may have been typing at: it empties the line and asks for the
anchor with the `anchor` request ([The prompt](#the-prompt)). It never
types a command at the prompt and never reads the prompt's text as data.

### Finding the anchor

Everything but the record starts at the anchor. A held board prints its
address. For an image and a stub the tool first tries the address the
bundle's image gives the anchor's symbol when the image lies where it was
linked, and otherwise looks for the magic at every page of the target's
RAM. It accepts a page only when its magic, version and CRC hold and its
build identifier names a bundle. More than one such page is refused as
ambiguous, with each address named: a domain can write a page that looks
like an anchor into its own memory, but it cannot remove the kernel's, so
a forgery makes two candidates and never a wrong answer.

A machine that did not stop itself, a hang that QEMU or a probe stopped,
has an anchor whose stop word is zero. The tool then shows every CPU from
the target's own registers and says that the machine did not stop itself.

### Commands

One command set; a command that needs what a target lacks is refused with
the need named, never answered with a guess. The set is one declaration,
the `command` rows of `abi/kernel.txt` beside the hold's frames: a
command's name, the name FreeBSD's `ddb` has for the same command where
that differs, its arguments, what it needs of a target, its line of
`help`, and whether a held machine's prompt has it. The generator writes
the tool's table from every row and the kernel's from the prompt's rows
([The prompt](#the-prompt)), so the two answer to the same names, and
for every row the prompt has, the two print the same line of help; the
tool's `help` lists its other rows as well. What a row needs is one of a
closed set: nothing, CPUs, memory, control, time, or a held board, the
one need of `reset`, which ends a hold and does nothing else. A row can
be the prompt's only if it needs nothing, CPUs, memory or a held board,
and nothing of the build beyond the kernel's symbol table: no type data,
no source lines, no other image. The generator checks it.

| Command | Shows | Needs |
| --- | --- | --- |
| `report` | the cause, message and build; each CPU's state and location, symbolized, and for `waiting` the lock and, with memory, the record the lock lies in; the leader's backtrace; with memory, every CPU's backtrace, the last records of each CPU's trace ring and of the log, and the audit's findings | CPUs |
| `help` | the commands, a line each | nothing |
| `show panic` | the head of `report`: the cause, the message, the build and the leader's CPU | CPUs |
| `cpus` | each CPU: number, state, program counter and symbol, stack pointer, and for `waiting` the lock's address | CPUs |
| `regs [CPU]`, also `show registers` | one CPU's registers, the leader's when none is named | CPUs |
| `bt [CPU \| thread ID]`, also `where` | a backtrace by frame pointers, bounded; a thread's starts from the saved context its walker names | CPUs; memory for more than the record's frames |
| `threads`, also `show threads`; `thread ID`, also `show thread ID` | every thread the kernel's own image holds, a line each: the kernel's number for it, its address, state, wait and saved program counter; one thread, with its saved registers | memory |
| `inspect PATH` | the record of an inspection path, as `tools/erx inspect` prints one; `*` in place of a variable segment gives every record of the listing | memory |
| `export DIRECTORY` | every path the walkers answer, each record in a file named by its path, in `inspect`'s text | memory |
| `log [N]`, also `show msgbuf`; `trace [N]` | the last lines of the kernel log; the last trace records of every CPU, merged by time; from whole rings, with a count wherever a ring's own reader rule says records were overwritten or half written; from a record's trace tail, with a count for each gap between one CPU's records and each CPU's ends marked unknown | memory; the record's text serves `log` without it, and its trace tail serves `trace` ([The record's trace tail](#the-records-trace-tail)) |
| `print TYPE ADDRESS`, `list TYPE ADDRESS FIELD [N]` | memory as a type of the bundle; a linked list of that type through that field, at most N nodes | memory |
| `x[/bhlg] ADDRESS[,COUNT]` | COUNT units of memory in hexadecimal, of 1, 2, 4 or 8 bytes each and 8 when no size is given; for bytes, printable ASCII beside them and a dot for every other byte | memory |
| `whatis ADDRESS` | what an address is ([What an address is](#what-an-address-is)) | memory |
| `audit` | every row of every kind, checked against the schema ([The audit](#the-audit)) | memory |
| `save FILE` | every page read at the current moment, and the CPUs' registers, as a memory image ([Moments and images](#moments-and-images)) | memory |
| `stop`, `continue`, `detach` | stop or resume the whole machine; leave the stub | control |
| `break ADDRESS`, `watch ADDRESS LENGTH read\|write\|access`, `watch PATH ATTRIBUTE`, `delete N` | hardware breakpoints and watchpoints; the second form of `watch` is on the place a view read an attribute from | control |
| `now`, `at COUNT`, `back`, `when PATH ATTRIBUTE`, `when ADDRESS LENGTH` | the instruction count of this moment; move to a count; run backwards to the last break or watch; run backwards to the last write of an attribute or a range | time |
| `reset` | end a held machine, which resets; the tool sends the hold's token, which a person types after the word | a held board |

The prompt's rows are `help`, `show panic`, `cpus`, `regs`, `bt`,
`threads`, `thread`, `trace`, `log`, `x` and `reset`. Whatever the
prompt answers for one of them, the tool with `-n` answers in the same
lines from any target of the same stopped machine, after the head that
names its target; a command the kernel cannot serve the prompt refuses
by name, and the tool may still answer it from what else it reads.

An address is a kernel virtual address, `p:` and a physical address, or a
space, a colon and a virtual address in that space, the space written as
`root`, as `cpuN` for the space CPU N was in when it stopped, or as the
path `inspect` shows it at. An address is hexadecimal, with `0x` or
without, and every other number is decimal unless it begins with `0x`.
Output is text a pipeline
can read: one attribute a line, in the schema's order, so `grep`, `sort`
and `diff` do what a query language would. Two `export`s compared with
`diff -r` show what changed between two moments, two machines or two
kernels.

### Walkers

**Layouts come from the build.** The build runs LLVM's DWARF dumper, a
subprocess like the other LLVM binary tools, over each image of the
bundle and writes the layout table. It is generated into the build tree,
never checked in. `print` and `list` read any other type of an image's
debug information through the same dumper when asked.

**Walkers are declarations.** A walker says, for one inspection kind and
one image, where its rows lie and which field holds each attribute. They
are text files beside the code they describe, one per image
(`fiasco/erx_walkers.txt` for Fiasco's kernel,
`liberx/backend/fiasco/walkers.txt` for the root's tables, and one for
erXos's kernel when it exists), read by a Ruby generator that validates
every row and writes the bundle:

| Line | Meaning |
| --- | --- |
| `walk KIND [in SPACE]` | the rows of an inspection kind; SPACE is `kernel`, `root`, or a field of the enclosing row that names a space |
| `from symbol NAME`, `from WALK FIELD`, `from slot FIELD` | where the walk starts: a symbol of the image, a field of another walk's row, or the object a capability slot of the row's space names, resolved through that space's capability table |
| `step array COUNT`, `step list LINK`, `step table FIRST LAST`, `step once` | how it goes from row to row; a list whose head is a sentinel inside the list object ends when a link returns to it, and a link names the link member inside the next row, from which the row lies at the generated adjustment |
| `only TYPE` | for an image in C++, keep the rows whose most derived class is TYPE, by the word at the start of the row's polymorphic base compared with the one recorded from a live object of TYPE ([On Fiasco](#on-fiasco)) |
| `bound N` | the most rows it reads |
| `id FIELD` | the row's identifier in its path |
| `attr KEY REPORTER FIELD [as MAP \| flags ENUM]` | the field that holds an attribute, the reporter whose state it is, and for an enumeration the map from the image's values to the schema's atoms; for a word of combinable flags, the enumeration of the image's debug information that names its bits, shown as the word and its set bits' names, and `unsupported` to `inspect` |
| `context FIELD LAYOUT` | for a thread, where its saved registers lie, so `bt` can start there |
| `map NAME VALUE ATOM...` | such a map |

The generator refuses a kind, key or reporter the schema does not
declare, a reporter the attribute does not admit, a symbol, type or field
the image's debug information does not hold, a field whose shape cannot
carry the attribute's type, a map that leaves a value of the field's
enumeration unmapped, and a walk without a bound. So a field renamed in
the kernel fails the build at the walker's line.

The `from slot` step is what joins the two halves of erXos on Fiasco. The
erXos model lives in the root's tables, which name a kernel object by the
capability slot the root placed it in; Fiasco's own state lives in its
kernel objects. A walker that follows a slot through the capability
table of the task that holds it shows, in one record, the root's account
of an object and the kernel's. It is also why memory can say more than
the running machine: Fiasco's interface gives the root no thread's state
and no object's identity
([design-fiasco.md](design-fiasco.md#reporting-kernel-objects)), so the
live inspector shows them `unsupported`, while a walker over Fiasco's own
thread objects reads them.

**Every walk is bounded.** A stopped kernel's memory may be corrupt,
which is often why it stopped. A walk ends at its bound, at a row it has
already read, or at an address it cannot read, and the view is marked
truncated, cyclic or cut, with the address where it ended.

**Two things are code, not declarations.** Every target reads physical
memory, and the tool translates virtual addresses itself, walking the
translation tables from the anchor's roots, or a space's from its
record. The walk is the tool's architecture layer, one piece of code for
every target, with a host model over every descriptor kind as the
kernel's own walk has
([design-arch-aarch64.md](design-arch-aarch64.md#stopping-every-cpu)).
The lookup of a capability slot in a space's table is the tool's kernel
layer, one function for Fiasco's object spaces and one for erXos's
kernel, each tested against a table the test builds. Everything else a
view needs is a walker's line.

**A kernel's own image carries its walkers.** For the walker file of a
kernel's image the generator also writes the table that the prompt's
commands interpret ([The prompt](#the-prompt)): the same rows, with each
field's offset and size, and each base-class adjustment between a link
and its row, made by the compiler over the kernel's types in the pass
that compiles the kernel: in erXos's kernel, C, by `offsetof` and
`sizeof`; in the Fiasco fork, C++, through Fiasco's own offset list
([On Fiasco](#on-fiasco)). A renamed field then fails the kernel's
compile at the generated line, as it fails the bundle's build at the
walker's. The prompt interprets the steps a kernel's own objects need (a
start at a symbol, a list or an array, the dynamic-type filter, the
bound, the identifier, attributes with their maps or flags, and a
thread's saved context) and no step that leaves the image: `from slot`, and a walk in a space other than the kernel's,
are the tool's. On Fiasco that gives the prompt the kernel's threads
([On Fiasco](#on-fiasco)). The root's tables, where erXos's domains and
budgets live there, are another image's, whose layouts and symbols the
kernel does not have.

### What an address is

Every row a walker reads has an extent, the bytes of the structure it was
read from, and every attribute a place. `whatis` answers from those and
from nothing else: for a virtual address, its translation and
permissions, the symbol it falls in, the row whose extent holds it (a
lock inside a budget's record is "the lock of `budgets/7`"), and the
stack or ring it lies in; for a physical address, also every space whose
translation tables map its page. The last is read from the translation
tables themselves, which are what the hardware obeys, not from any record
of mappings. On a held board it reads every table of every space and is
slow; on an image it is not.

### The audit

`audit` reads every row of every kind and checks three things, each of
which the schema or a walker already declares:

* every attribute's value is of its type: within an integer's bounds, a
  member of its enumeration, text within its length;
* every reference resolves: an attribute whose type is the variable
  segment of a declared path names a record that exists at that path, and
  every `from slot` step finds an object of the kind the row records;
* every walk ended at its end, not at its bound, at a row it had already
  read or at an unreadable address.

It prints each finding with the row's path and address. A kernel that
stopped because its state is inconsistent has broken one of the rules it
keeps by construction; the audit turns "something is corrupt" into which
record. On Fiasco its second check is the one that matters most: it
compares the root's placement records, on which every domain's isolation
rests there, with the capability tables Fiasco holds.

### Watching a value, and when it changed

`watch PATH ATTRIBUTE` resolves the attribute to the address and size its
view read it from and sets a hardware watchpoint there, so "stop when
this budget's `used` changes" needs no address from the developer. On a
replay, `when PATH ATTRIBUTE` sets the same watchpoint and runs the
machine backwards to the last write: the tool stops at the instruction
that made the value, on the CPU and in the thread that made it, and every
other command then shows the machine as it was at that moment. `now`
prints that moment as an instruction count, a number another developer
can give to `at`.

The tool asks for a watchpoint of at most a word, naturally aligned,
which an attribute's field fits and the hardware's watchpoints cover; it
refuses a longer range, and never splits one into several watchpoints
behind the developer's back. A watchpoint is on a virtual address, so one
set in a space other than the kernel's can fire in another space; the
tool reads the stopped CPU's translation root and continues past a stop
that is not in the space it meant.

### The report

`report` is the one function every failure gets. It is deterministic: the
same target and bundle give the same bytes, so two reports compare with
`diff` and a test compares one with its expected text. When any CPU is
`unanswered` it says first that the CPU may still run, that what follows
may have changed while it was read and, on a held board, that the CPU may
have written the line the report came over.

### Moments and images

A target is read at a **moment**: one stopped state of the machine. A
crash record, a memory image and a held board have one moment each, since
none of them runs again. A stub's machine has a new moment each time it
has run, and a replay's moment is its instruction count. The target
interface names the moment ([Targets](#targets)), and everything the tool
keeps of a target, the pages it has read, each CPU's registers and the
views built from them, is kept under the moment it was read at. A command
that lets the machine run or moves it in time (`continue`, `back`, `at`,
`when`, and `stop` of a running machine) discards all of it before
anything else is read. So two reads of one address at two moments are two
reads of the machine, and no view is built from pages of different
moments, which would describe a machine that never existed.

`save` writes one moment: every page read at the current moment, the
CPUs' registers, and a note that names the target and the moment, as a
memory image. Every command that was run at that moment gives the same
answer against the file. On a held board the tool saves, without being
asked, before it carries out `reset`, so the board's failure can be read
again after the board has rebooted.

Within a moment the tool reads each page once, so its own answers agree
with each other. Whether they agree with the machine depends on what
could still write the machine's memory while it was read, which the head
of every record states:

| Target | What can write memory while the tool reads |
| --- | --- |
| a crash record, a memory image | nothing |
| a stub of QEMU's, a replay | nothing: QEMU stops every virtual CPU and the guest's clock with them |
| a stub of a probe's | a device that was in the middle of a transfer when the cores halted: its DMA goes on |
| a held board | a device's DMA, as under a probe; the hold itself, which writes the leader's stack and, on Fiasco, the translation entry of its window; and after an incomplete census every CPU that did not answer |

### The GDB remote protocol subset

For a stub and a replay the tool is a client of the GDB remote serial
protocol (GDB manual, appendix E). It sends exactly these packets:

| Packet | Use |
| --- | --- |
| `qSupported` | learn `PacketSize`, whether the stub serves target descriptions (`qXfer:features:read`), and whether it runs backwards (`ReverseContinue`) |
| `qXfer:features:read:ANNEX:OFFSET,LENGTH` | the target description: `target.xml`, and each annex `target.xml` includes, from which the tool takes each register's number, size and name |
| `Qqemu.PhyMemMode:1` | QEMU's stub only: read physical memory with `m`; a stub that answers with the empty reply gives no physical reads, and the tool refuses it as a source of memory |
| `?` | why the machine is stopped |
| `0x03`, outside any packet | stop a running machine |
| `qfThreadInfo`, `qsThreadInfo`, `Hg` | the CPUs, one thread each; select one |
| `g` | the selected CPU's core registers |
| `p NUMBER` | one register of the selected CPU outside the core set, by the number the description gives it |
| `m ADDRESS,LENGTH` | read memory |
| `Z1`, `z1`, `Z2`, `z2`, `Z3`, `z3`, `Z4`, `z4` | insert and remove a hardware breakpoint and a write, read or access watchpoint |
| `vCont?`, then `vCont;c` or `c` | resume every CPU |
| `bc` | run backwards, on a replay |
| `D` | detach |

It never sends `M`, `X`, `G`, `P`, `Z0` or `z0`: the module that builds
requests has a constructor for each packet above and no other, and no
public way to send raw bytes. It reads each reply as the manual defines
it: the empty reply means the stub does not support the request, which
the tool reports as unsupported, and a stub without `Z1` has no
breakpoints, since the tool never falls back to a software one; `E NN`
means refused; a run of `x` in a register's place marks it unavailable;
an `m` reply shorter than asked marks the rest "not here"; a stop reply
names the CPU and the event, `replaylog` among them for a replay that has
reached its beginning or its end. It keeps acknowledgement mode on,
checks every checksum, and undoes the protocol's escapes and run-length
encoding before it reads a payload.

**The description is read within bounds.** The manual has a client load
the main description from the `target.xml` annex, and names every other
document of the description by an annex of its own, fetched the same way
(General Query Packets, `qXfer:features:read`). So the tool reads
`target.xml`, then each annex that `target.xml` includes, and no
further: an include inside an annex refuses the target. It reads at most
`stub_annexes_max` (16) annexes of at most `stub_annex_max` (1 MiB)
each, and sends back an annex's name only if it is at most 64 characters
of ASCII letters, digits, `.`, `_` and `-`. A description past any of
these bounds, or one without the architecture's core registers, refuses
the target. The bounds are the tool's own defence against a stub whose
replies it does not trust, not facts of the protocol: the manual sets no
limit on a description's size or depth. How the include is written is
the manual's Target Descriptions appendix, which this design did not
read, and which annexes QEMU's stub serves, whether any of them includes
another and whether its description fits these bounds are *unverified*
([P1](#unverified-facts)).

**Registers are negotiated, never assumed.** The architecture binding
lists the registers the tool uses: the core set, which every target must
have, and each other register beside the command that needs it, of which
the first is the translation root of the space a stopped CPU was in
([design-arch-aarch64.md](design-arch-aarch64.md#stopping-every-cpu)).
The core set is the one feature the manual makes every AArch64
description carry, `x0` to `x30`, `sp`, `pc` and `cpsr` (AArch64
Features), and the description fixes each register's size and its
position in the `g` reply (Packets, `g`). So the tool takes the core
registers from the `g` reply at the positions and sizes the description
gives them, and reads every other register it needs alone, with `p`, by
the number the description gives it (Packets, `p n`), whether or not the
`g` reply also carries it; it never needs to know which registers a
stub's `g` reply covers. A register
the description does not list, or whose `p` is answered with the empty
reply, an error or a run of `x`, is unavailable, and a command that needs
it is refused with the register named: `watch` on an address of a space
other than the kernel's, for one, since the tool could not tell which
space a stop was in. Nothing is inferred from a register the tool could
not read.

A developer who wants source-level stepping attaches `lldb` to the same
stub instead; one stub serves one client.

### Escaping and output

Every string that comes from a target (the record's text, log lines,
names in the root's tables, anything `print` shows as characters) passes
through the host's line escape, which also escapes tab and newline, since
all of it is text attributed to a source
([design-live.md](design-live.md#attributed-text)). A hex dump shows only
printable ASCII beside the bytes. Symbol names come from the build's own
images and pass unchanged. While the tool is a terminal for a board's
console it carries the line's bytes unchanged, as any terminal does: they
are the programs' own output, not text the tool attributes
([design-live.md](design-live.md#invariants), V1).

## Transports and the console line

**The console line.** While the machine runs, the line is its driver's.
A stop takes it, by the order of [The stop](#the-stop), and nothing gives
it back. After a complete census it has one user, the stop; after an
incomplete one a CPU that did not answer may still write it, and the
stop's output is best effort and says so. The kernel writes it by
polling, and
reads it only in the hold, also by polling, taking none of its
interrupts. A hold's frames and its prompt's output are printable ASCII
lines, so a terminal that shows the line sees text, and nothing that
moves its cursor but the erasing of a typed byte. The hold is
on the console and not on a line of its own because a stop already owns
the console, every board has one, and the wire is already connected: a
second line would need a second cable, and on the Raspberry Pi 4 a UART
that shares its register page and its interrupt with the system domain's
([design-platforms.md](design-platforms.md#raspberry-pi-4-model-b)).

**The host link is not a debugger's channel.** It is the system domain's,
served by an Erlang driver that is gone when the machine has stopped, and
it reaches a running machine's inspector, which is the right tool for a
machine that can still answer
([design-live.md](design-live.md#the-host-link)).

**QEMU.** A development run the harness starts carries `erx.hold=1`
unless its case expects the stop. When `--erx-held` arrives on the
console the harness stops the emulation through QEMU's machine protocol,
takes a memory image with `dump-guest-memory` (physical memory, ELF) into
the run's log directory, runs `tools/erx debug IMAGE report` into the
run's log, and quits QEMU. At a run's deadline it does the same without
waiting for the line, so a hang leaves an image whose register notes show
every CPU, the one spinning with interrupts masked included, since QEMU
stops its virtual CPUs from outside. The machine protocol's socket is in
the run's owner-only directory, as the display's is. `tools/erx boot
--stub` and the harness's debug flag add QEMU's stub on a UNIX socket in
the same directory, the target of `--stub`.

**A recorded run.** `tools/erx qemu --record` runs a case under QEMU's
record mode: instruction counting with a replay log, each block device
behind the replay driver, each network backend behind the replay filter,
and a snapshot at the start, into the run's directory with the argument
vector that made it. `--replay DIRECTORY` starts QEMU from that vector in
replay mode with its stub and its machine protocol, which gives the
current instruction count and moves to another. A recording is a
single-threaded TCG run, so it shows the interleavings that one host
thread running the CPUs in turn produces and no others; what it shows, it
shows again every time.

**A board.** `tools/erx debug --tty DEVICE` is the developer's console
for an attended boot: a terminal until the stop, then the reader of the
hold. Any other terminal program on that wire reaches the hold's prompt
and needs nothing of erXos on the host ([The prompt](#the-prompt)). The
card writer puts `erx.hold=1` on a card's command line only
when asked. A board with a probe is a stub: on a development card the
Raspberry Pi 4's JTAG pins are routed
([design-header-io.md](design-header-io.md)), and a probe whose software
serves the GDB remote protocol with physical reads is a target like
QEMU's stub. Whether the probe at hand does is unverified
([Unverified facts](#unverified-facts), P5); until it is settled the tool
reports a probe's target as unsupported. A board that is probed is booted
attended, so no watchdog resets it while the probe holds it.

## On Fiasco

**What leaves the tree.** `src/jdb/`, `src/kern/jdb_object.cpp` and the
JDB menu of `src/Kconfig` leave the fork, the removed files as exclusion
rows of `fiasco/kernel/ORIGIN.md`, while the edited ones keep their
inventory rows and carry erXos's change notice, so no build can turn the debugger back on and no GPL file is
left among the kernel's sources. The `debug` and `log`
preprocessor parts, which only `CONFIG_JDB` adds (`src/Modules.arm`), go
with it, and with them every `[debug]` section of the files that stay.
Of `src/jabi/`, the trace ABI stays, since the kernel's counters use it
(`jdb_ktrace`, used by `src/kern/kern_cnt.cpp`). `CONFIG_RT_DBG` stays,
for the list that links every kernel object
(`Kobject_dbg::_kobjects`, `src/kern/kobject_dbg.cpp`), which is the
walkers' root for Fiasco's own objects; the modules it builds from
`src/jdb/` (`jdb_kobject`, `jdb_kobject_names`, `jdb_space`), and
`jabi`'s `jdb_obj_info`, leave with the rest, since no other source needs
them (no source names their classes), and `CONFIG_JDB_KMEM_STATS`, whose only trigger was the
object, is gone.
`CONFIG_INPUT`, the kernel's console input, is forbidden in every build.
The trace buffer leaves with the rest, and the fork's per-CPU trace rings
take its place ([design-fiasco.md](design-fiasco.md#the-kernels-trace-rings)).
`LicenseCheck::TABLE` loses its `jdb_object.cpp` row.

**What enters.** The core `kernel/core/machine_stop.c`, in `erx_cores.a`
beside the crash core, and with it the commands' core,
`kernel/core/hold_commands.c`, which only the hold's glue calls and a
release kernel therefore does not link; one glue file,
`fiasco/kernel/src/erx/erx_machine_stop.cpp`, whose references into
Fiasco are lines of `fiasco/erx_glue_imports.txt`; the generated table of
the kernel's own walkers ([Walkers](#walkers)); and one option,
`CONFIG_ERX_HOLD`, which builds the hold with its prompt. A development
kernel is the defconfig as it is; a release kernel is the same defconfig
without that option, its only difference
(`FiascoConfig::RELEASE_UNSET`).

The routes into the stop:

| Fiasco route | What upstream Fiasco does there | Into the stop |
| --- | --- | --- |
| `panic` (`kern/kernel_panic.cc`) | prints, then `Thread::system_abort` | the message formatted into a bounded buffer, cause `panic` |
| `assert_fail` (`kern/assertion.cpp`) | prints, then `Thread::system_abort` | the expression, file and line, cause `panic` |
| `kdb_ke` (`kern/kdb_ke.cpp`), from "DEAD SCHED" and "I'm dead" (`kern/thread.cpp`) and "BUG in KU memory mapping" (`kern/task.cpp`) | with JDB enters it; without, prints `NO JDB` and goes on | the message, cause `panic`, in every build ([Decisions](#decisions), 5) |
| a kernel trap, `Thread::call_nested_trap_handler` (`kern/arm/thread-jdb.cpp`), and the three trap reports that end in a panic: the two kernel-mode abort checks (`kern/arm/64/thread-arm-64.cpp`) and `sigma0`'s exception (`kern/thread-ipc.cpp`) | with JDB the first enters it, and without it prints the trap state, ends the current thread and returns to the faulting instruction; the three reports print the trap state with `Trap_state::dump` and panic, while the other CPUs run | the trap state as the leader's registers and the exception in the fault field, with nothing printed before the census |
| the debug inter-processor interrupt, `Thread::handle_debug_remote_requests_irq` (`kern/arm/thread-arm.cpp`), which every multiprocessor kernel attaches and only JDB sent | a breakpoint instruction into the nested trap handler | the stop request: publish the interrupted registers as `stopped` and park |
| a spinlock's wait (`kern/arm/64/spin_lock-arm-64.cpp`, and the cores' ticket lock) | waits | the check of the stop word after each wake; `waiting` |
| a secondary CPU's start, `App_cpu_thread::bootstrap` (`kern/app_cpu_thread.cpp`) | marks the CPU online near its beginning, sets up its timer and scheduler state, unmasks interrupts, prints and enters its idle loop | the admission, as the last step before interrupts are unmasked: the CPU sets its bit and, if the stop word is set, parks as `starting`. The boot CPU is admitted where the glue sets the stop up |
| the console path's lock, Fiasco's printf lock (`kern/libc_backend_lock.cc`) | a take that loops without bound | a bounded take beside it, which the leader calls once and never undoes |
| the root's request for a reset after its own crash record, arguments of the platform control object's shutdown that name the cause and the record's address in the root's space (`kern/platform_control_object.cpp`) | resets | the stop from its census on; the kernel writes no record of its own; in a boot that holds it copies the root's into its crash buffer, checked, after its census |

`Thread::system_abort` and the exit question go, since nothing reaches
them. The interrupted registers of a CPU that takes the stop request are
the interrupt entry's saved frame, which Fiasco's `irq_handler` takes no arguments, so one call
in the interrupt entry (`kern/arm/64/ivt.S`) hands the frame and the
stack pointer the interrupt found to the glue before the dispatch, and a
second clears them after it, and a request outside that entry returns
and answers the leader's next ask; the glue keeps them per CPU. Each
CPU's panic stack is one thread block the glue reserves for it, two
pages at least and aligned to its size, whose first bytes are a header
shaped as Fiasco's `Context` with only its CPU number set, written when
the glue is set up beside the boot CPU's hardware identifier, so Fiasco's
lookup of the current thread through the stack pointer finds that CPU
and no thread. The leader publishes its own slot too, which the census
does not count. The stack holds the
formatted message, the crash core's writer and the report's printer
below the leader's own frames, until the kernel stack proof measures the
stop's depth. Every line the stop prints takes the UART console's
polled write past the ring console (`Erx_console_ring::write_uart`),
without its lock, so a nested stop's line and an end before the ring's
close reach the line. Where the interrupt controller takes the request as a write of a system
register, which a memory barrier does not order, the leader completes
its claim with the architecture's full barrier before the requests
([design-arch-aarch64.md](design-arch-aarch64.md#stopping-every-cpu)). A stop before the kernel knows
its reset, which it learns from the device tree and PSCI, ends in a loop
with interrupts masked, as a panic there does
([design-fiasco.md](design-fiasco.md#boot-handoff)); it has printed its
record. The development flag and `erx.hold=1` come from the boot handoff
record, which carries the image's flags and the command line
([design-fiasco.md](design-fiasco.md#boot-handoff)); the root reads
the same word with the same parser, to leave the hardware watchdog
unarmed in an attended boot
([design-fiasco.md](design-fiasco.md#the-watchdog)).

**The console's lock on Fiasco.** The printf lock is one word that holds
its owner's CPU or all ones. A take masks interrupts and loops on a
compare-and-swap without bound, and a second take by the owner nests
(`kern/libc_backend_lock.cc`). Every print of the kernel's takes it
(`lib/libc/glue/`, `lib/libc/src/stdio/vfprintf.c`). The word is private
to its file, so the fork adds the bounded take there: the same
compare-and-swap, a fixed number of times.

**The hold's reader on Fiasco.** With `CONFIG_INPUT` off, as it is in
every build, `src/Modules.generic` defines `UART_WITHOUT_INPUT` for the
whole kernel, and that macro removes the UART library's receive members,
`char_avail` and `get_char` among them, from its base class
(`lib/uart/uart_base.h`) and from both drivers erXos's boards use
(`uart_pl011.cc`, `uart_16550.cc`). The console class's own reader, the
`input` part of `drivers/uart.cpp`, is a layer above them and stays out
of every build. The fork changes the one line of `Modules.generic`: the
macro is defined unless `CONFIG_ERX_HOLD` is on. The hold's reader thus
has one build condition, the option that builds the hold. A development
kernel has the two polling members, and the glue calls them on the
console's UART object; a release kernel has neither, so code that called
one would not compile there. A source check keeps the hold's glue their
only caller.

**The hold's map on Fiasco.** The boot map is the kernel information
page's memory descriptors, each a range, a type, a sub-type and a flag
that says whether the range is of virtual addresses (`abi/kip.cpp`).
Fiasco itself publishes one such virtual descriptor, conventional, over
the whole user address space (`kern/arm/kip_init-arm.cpp`,
`Kip_init::init`), and its own allocator skips virtual descriptors and
takes reserved ranges out of conventional ones before it uses any
(`kern/kmem_alloc.cpp`, `Kmem_alloc::create_free_map`). The fork's table,
a pure function of the cores, classifies every descriptor for
[Readable RAM](#readable-ram):

| Descriptor | Class | Why |
| --- | --- | --- |
| any virtual descriptor; `Undefined` | `ignored` | it describes address space, or nothing |
| physical `Conventional` | `ram` | what the boot stage gives as RAM |
| physical `Reserved` of sub-type `Reserved_kernel` or `Reserved_heap`; `Kernel_tmp`; `Dedicated`; `Bootloader` | `used` | the kernel's image and heap, `sigma0`'s memory and the boot modules, the root's among them, which the kernel maps to them as memory (`kern/std_workload.cpp`, `map_all_segs`) |
| physical `Reserved` of sub-type `Reserved_mmio`; `Shared`; `Arch`; `Info`; `Kmem`; any other type or sub-type | `excluded` | a device's registers, firmware's tables, or a kind nothing in erXos's configuration vouches for as memory |

Fiasco maps only its own memory, so the glue reads a physical page
through one page of kernel address space, the window JDB's temporary
mappings used, mapped for the copy and unmapped after it. The end is
Fiasco's platform reset, which every build takes. Which type the boot
stage gives the device tree's reservations, the firmware's own memory on
the Raspberry Pi 4 among them, was not read for this design and is P11.

**The prompt on Fiasco.** The glue hands the commands' core the anchor,
the slots, the crash buffer, the fork's trace rings (`erx_trace_rings`,
[design-fiasco.md](design-fiasco.md#the-kernels-trace-rings)) and the
symbol table by address, and supplies its two effects: the checked read,
through the window the frames' `read` uses, and the polled write. Fiasco
keeps no log of erXos's kind, so `log` is refused there.

**The root's record on Fiasco.** The root writes the records of its own
ends into its own buffer (`end_record`, `liberx/backend/fiasco/end.c`)
and prints them; the kernel never sees them. Its shutdown request
therefore names that buffer's address in the root's space beside the
cause, and in a boot that holds the glue, after its census, translates the address from the
anchor's root-task root, copies `crash_size` bytes through the checked
read into the kernel's crash buffer and runs the crash core's check over
them. So the stop has one record in one place whatever ended the
machine: `show panic` reads it, and so does the tool through the
anchor's `record`. A record that fails the copy or the check leaves the
buffer zero, and `show panic` answers `record: unknown: the root's
record could not be read` with the reason.

**Fiasco's threads.** The one walk is of Fiasco's threads, over the list
that links every kernel object (`Kobject_dbg::_kobjects`,
`kern/kobject_dbg.cpp`), which `CONFIG_RT_DBG` keeps. The list is a
`cxx::D_list` (`lib/libk/cxx/dlist`): its head is a sentinel link inside
the list object itself, each link points at the `D_list_item` inside the
next object rather than at the object, and the walk is over when a link
comes back to the sentinel. `Kobject_dbg` derives from `D_list_item`, and
is a private base of `Kobject`, which `Thread` reaches through its third
base (`kern/kobject.cpp`, `kern/thread.cpp`). So from a link to a thread's
fields is a chain of base-class adjustments, not one offset, and the
walk needs four kinds of fact, each made by the compiler from the
kernel's own types in the pass that compiles the kernel:

* **Adjustments and offsets.** Fiasco already computes the offsets its
  assembly needs in this way: `kern/tcboffset.cc` evaluates
  `DUMP_CAST_OFFSET(type, subtype)`, a `static_cast` at a fixed address,
  and `DUMP_MEMBER1`, a member's offset, inside `offsets_func`, which
  `MEMBER_OFFSET()` (`kern/member_offs.h`) makes a friend of `Thread`
  and `Context`; the build extracts the numbers from the object's
  `.offsets` section (`Makerules.TCBOFFSET`). The walker generator
  writes its lines into a file of the build tree that the list
  includes, and the fork adds `MEMBER_OFFSET()`
  to `Kobject` and `Kobject_dbg`, one line each, so the friend reaches
  the private base and `_dbg_id`. The lines give: the `D_list_item`
  inside a `Kobject_dbg`; for each concrete thread class, the
  `Kobject_dbg` inside it and the `Context` inside it; and inside
  `Context`, `_state` and `_kernel_sp`. The kernel's walker table is
  then generated from `tcboffset.h` as Fiasco's assembly takes its
  offsets from it, and a renamed member fails that build at the line
  that names it. No `offsetof` over a class that is not standard-layout
  is needed.
* **The sentinel.** The glue records the address of the list object's
  sentinel in the table at boot, while the kernel is whole: it is the
  address of a static object and never moves.
* **Which objects are threads.** The rows are objects whose most derived
  class is one of the walker file's `only` classes, `Thread_object`,
  `Kernel_thread` and `App_cpu_thread` (`kern/thread_object.cpp`,
  `kern/kernel_thread.cpp`, `kern/app_cpu_thread.cpp`). The first word
  of an object's `Kobject_dbg` is the same for every object of one most
  derived class and differs between such classes, since `Kobject_dbg`
  has virtual members and no polymorphic base, so that word is the
  pointer to the class's virtual table (P12). The glue records that word
  from a live object of each class at a point it already runs: the boot
  CPU's own thread, a `Kernel_thread`, when it sets the stop up; each
  secondary CPU's, an `App_cpu_thread`, at its admission; and the root's
  first thread, a `Thread_object`, when it completes the anchor. The
  walk keeps an object whose word is among those recorded and steps
  past any other. Calling the object's own type function
  (`_cxx_dyn_type`) would run the stopped kernel's code, which the
  prompt never does. The walker generator refuses an image whose debug
  information has a concrete class derived from `Thread` that the
  `only` lines do not name, so a new thread class fails the build until
  someone says where its word is recorded.
* **A row's number and state.** A row's ID is `_dbg_id` plus one, the
  value the fork's trace records carry. Its state is `Context::_state`,
  a word of combinable `Thread_state` flags (`kern/thread_state.cpp`),
  not an enumeration. The prompt prints the word in hexadecimal and the
  names of its set bits, which the generator reads from the enumeration's
  members in the kernel image's debug information; a set bit without a
  name prints as its value. The inspection view has no rule that turns a
  combination of flags into the schema's thread state, so `inspect`
  shows that attribute `unsupported` on Fiasco, while `threads` shows
  the raw word.

Where each thread's registers come from is
[A thread's registers](#a-threads-registers). A CPU that was parked
inside an update of the object list leaves it half linked: the walk
reads it through the checked read, with its bound and its test for a row
already read, and marks where it ended. An empty list is a sentinel
whose link is itself, and the walk prints no row. Fiasco's tasks have no
listing of their own: without the root's records a task is a number and
a translation root ([Alternatives considered](#alternatives-considered)).

**What changes for the backend.** Capability slot 10 is empty in every
build, as the release kernel's already is; an invocation of it fails as
any empty slot does. `sigma0`'s calls that name its objects then fail in
development boots too, and whether `sigma0` ignores the failure is
unverified (P9). FD26's development limit, that after a resume the kernel
writes the UART beside the console's driver, is gone with the resume. The
race in which the root's watchdog thread on another CPU reloads the
Raspberry Pi 4's watchdog inside the firmware's 153 us reset window
closes for every end that passes the stop, since that CPU is parked
before the end ([design-fiasco.md](design-fiasco.md#the-watchdog)).

**What Fiasco's stop lacks.** Fiasco's wait loops other than its
spinlock's, a cross-CPU call's and the printf lock's among them, do not
check the stop word, so a CPU stuck in one with interrupts masked is
`unanswered`. A CPU inside a print holds the printf lock with interrupts
masked for the length of a line, about 5 ms
([design-fiasco.md](design-fiasco.md#the-kernels-lines)), and takes the
request when it has finished, well inside the census. A CPU that holds
the lock and never lets go, stuck in a print or printing in a loop with
interrupts masked, is `unanswered`: the leader's bounded take fails, and
the stop's output is best effort, as [The stop](#the-stop) says.

## On erXos's kernel

The kernel's panic
([design-kernel.md](design-kernel.md#console-log-and-panic)) is the stop,
on the same core: its first three steps are the claim, the stack and the
request, the ticket lock's wait carries the check of the stop word, and
its report is the record's. The crash buffer survives a warm reset where
the platform has a region, so a board's record is also read after the
reset at `/proc/kernel/crash`. Its boot map for
[Readable RAM](#readable-ram) is the map its pool plan already reads
([design-kernel.md](design-kernel.md#the-startup-plan-and-its-charge-evidence)):
the conventional
ranges are `ram`, the firmware's reservations, the device tree's
`/reserved-memory` entries among them, are `excluded`, and what the
kernel placed itself, its segments, the boot image and the device tree's
copy, is `used`. The hold reads through the kernel's direct map, and
through the kernel's own mapping of a page the direct map leaves out, and
is the one place the kernel reads its console UART. Its prompt is the
same core over the walker file of the kernel's own image, whose threads
are erXos's own, and its `log` reads the kernel's log through the log
core's reader. Its secondary CPUs'
start ends in the admission, and its console lock is the one the
leader's bounded take is tried on.

The ledger's row "Kernel debugger" keeps its answer, none, with its
reason, less code and less to attack in kernel mode, and gains what
stands in its place: the stop, the record and, in a development kernel,
the hold with its read-only prompt
([design-kernel.md](design-kernel.md#the-ledger)).

## Published images

The images the website offers are development builds of the same tree,
and their command lines carry no `erx.hold`: the card writer and the
site's image builder write the word only when asked, and the site build
refuses a medium whose command line holds it. A kernel stop on one writes
the full record on the console, which shows registers, a backtrace and
the log's last lines, already escaped, reads nothing, and resets: it
prints no prompt and answers no line.
Nobody at the console reaches kernel memory, and the images carry no GPL
kernel file. Their kernels do link the hold's code, its prompt included,
as every development kernel does; a release kernel links none
([Security](#security)).

## Failure handling

| Failure | Detection | What remains | What the user sees |
| --- | --- | --- | --- |
| a fault inside the stop on the leader, the hold included | the claim's depth | the machine ends; what was printed stays printed | `erx: nested stop` at depth two; at a greater depth nothing more |
| a CPU that parked or followed faults again | the claim's depth | its first publication; a zero slot if the fault came before the state's store | nothing on the console; the CPU's first state in the record, or `unanswered` (`offline` outside the census) when its slot stayed zero |
| two CPUs stop at once | the stop word | one record | the other CPU as `concurrent` |
| a CPU does not answer | the census bound | the others' slots; a report printed best effort | the CPU as `unanswered`, named in the report's first line; under QEMU or a probe, its registers from outside |
| a CPU finishes starting after the stop | the stop word, at its admission | its slot | nothing on the console; `offline` in the record if the census had ended, and `starting` in its slot |
| CPUs deadlock on spinlocks | each one's wait loop, once any CPU stops the machine; if none can, the board's watchdog or the harness's deadline | each waiter's slot | each as `waiting`, with its lock; from a hang's image, each CPU's registers in the wait |
| the console's lock is held by a CPU that will not release it | the bounded take | the report, written without the lock | the report's first line says the lock was not taken; a frame the other writer damaged is reported as damaged |
| the UART never becomes ready to send | the polled write's bound a byte | a truncated frame | the reader reports the frame truncated, never parses it as whole |
| the host falls silent, the cable is pulled, or the tool dies | nothing in the machine: nothing bounds a hold | the held machine; the record already printed; what the tool had saved | the prompt again, when a terminal or the tool is attached; the machine resets when it is told `reset` |
| a request is damaged | its length, magic and CRC | the hold, unchanged | nothing: the tool sends it again |
| a typed line names no command, has a wrong argument, or is longer than `hold_line_max` | the commands' parser; the line reader's bound | the hold, unchanged | one line: that the command is unknown, how the command is used, or that the line was too long; then the prompt |
| a command's address is not readable RAM, or is not mapped in its space | the checked read; the translation | the hold | one line that names the address and says which of the two it is |
| a command's walk meets corrupt memory | its bound, the rows it has read, an unreadable address | the rows printed so far | the listing marked truncated, cyclic or cut, at an address |
| the tool attaches while a typed line is unfinished | nothing: the tool empties the line before its first request | the hold | the echo of the erasing, which the tool passes over |
| a reply is damaged | its CRC, at the tool | the hold | the tool asks again, and after three tries marks the range "not here" |
| a `read` outside RAM | the range check | the hold | `range`; the tool shows the address as not memory |
| a read inside the map faults, a request's or a command's | the claim's depth | what the tool had read and saved, and what the terminal shows | `erx: nested stop`, and the machine ends; the tool names the address it had asked for |
| the board's watchdog is running in a boot that carries `erx.hold=1` | the hold decision | the stop, without a hold | a line at boot saying the boot will not hold, and why |
| the readable-RAM map is refused | the core, at boot | the stop, without a hold; an anchor with no range | a line at boot saying the boot will not hold, and which entry or bound refused the map |
| a record that fails its check | the crash core's check; the readers' | nothing trusted | the check's reason |
| a memory image without register notes | the image reader | memory | CPUs from the stop slots, if the machine stopped itself; otherwise registers unavailable |
| two pages that look like an anchor | the anchor search | nothing trusted | both addresses, and a refusal to choose |
| a target from a build whose bundle is missing | the build identifier | raw addresses | no symbols or types, and why |
| a walk meets corrupt memory | its bound, the rows it has read, an unreadable address | the rows read so far | the view marked truncated, cyclic or cut, at an address |
| the stub refuses a request, or does not support it | the reply | the session | `unsupported` or `refused`, with the request named |
| the stub's connection closes, or the machine is gone | the read | what was printed and saved | the tool says the target is gone and exits with status 1 |
| a replay reaches its beginning or its end | the stop reply | the session, at that moment | the tool says which end it reached |

## Security

**Who may stop a machine.** Nobody from outside it. The stop has no entry
from the console, the host link or a domain: its causes are the kernel's
own failures and the root task's ends, which exist without this design.

**Who may read a stopped machine.** In a release build, nobody: a release
kernel links no code that reads its console. A published image is a
development build, so its kernel does link the hold, and what keeps it
unused is the boot's command line, which carries no `erx.hold`
([Published images](#published-images)). The two are different
guarantees: the first is a property of the link, the second of a file on
the medium, and whoever can rewrite that file holds the medium and could
as well write a kernel of their own to it.
In a development build booted with `erx.hold=1`, whoever holds the
console wire, for as long as the hold lasts: every byte of RAM, the
vault's keys and every domain's memory among it. That is total authority
over the machine, which a development build already gives the same
person through the system shell on that console, and which the banner's
`development build: trusted code only` states. The word is in the
command line of the boot image, which the person who built the card
wrote. Whoever holds QEMU's stub socket or a board's JTAG pins can stop
the machine and read all of it, as QEMU's documentation says of its stub;
both are outside the machine's own interfaces, and the sockets live in
the run's owner-only directory.

The prompt adds no authority to the frames. Both read the same map
through the same check, and the tool that sends the frames is in the
tree for anyone to run. What the prompt adds is that the reader needs
nothing but a terminal, which is its purpose, and the reason the hold
stays behind a development kernel and a word on the boot medium.

**What the hold cannot do.** It reads RAM. It cannot write memory or a
register, read a device, or resume the machine, by a frame or by a
command. Its input is one line of at most `hold_line_max` bytes, of one
of two kinds by its first byte. A frame line is a fixed-size layout with
a CRC, checked whole before any field is used, and one that fails is
dropped with no answer. A command line is printable ASCII, parsed
against a closed table: a name, at most two arguments, and numbers
checked for overflow and against the command's bound before anything is
read. The parser allocates nothing, recurses nowhere and keeps nothing
from one line to the next, and the line has a fuzz target.

**Why a parser in kernel mode is acceptable here.** The hold is reached
only after a stop, which nothing outside the machine causes; only in a
development kernel, which already gives whoever holds its console the
system shell; and only in a boot whose command line asks for it. A
defect in the parser or in a command is therefore a defect in a machine
that has already ended and that its reader already owns: it can spoil a
debugging session, at worst with a nested stop, and it cannot widen what
anyone may do. That argument does not carry to a release kernel or to a
boot that did not ask, and neither has the code or enters it.

**Images and full records hold secrets.** A memory image holds everything
the machine held, and a full record may hold what the interrupted code
held in its registers. Images and saved moments stay in the run's log
directory on the host and never enter the repository.

**What a release record shows.** A release build writes the brief
record, and for a kernel `panic` it holds the failing CPU's registers
and kernel backtrace, as FreeBSD's release kernel prints them
([The record's CPU entries](#the-records-cpu-entries)); this follows
FreeBSD by decision. The backtrace and the program counter say where in
the kernel's code it failed, which is public, since the kernel image
ships with the release. The registers are the interrupted kernel code's,
and they may hold data: kernel addresses, which tell a reader where the
kernel's objects lie; a value the kernel was handling for a domain, such
as a word of a message in transit or an argument of a call; and the
fault address, which may be a domain's user address and so says
something of its address layout. Whoever sees the record sees those
words: the console at the moment of the stop, and whoever the record is
sent to afterwards. Nothing of user mode is in it beyond what the kernel
held in its registers at the fault: no user register set, no stack, no
log and no text but the kernel's own panic message, and for the root
task's ends no registers at all.

**The tool's input is untrusted.** Every byte from a stub, a console, an
image file or a log may come from a machine whose memory a domain wrote
or whose kernel was corrupt. Every decoder is bounded and has a fuzz
target, and no read of memory or of protocol bytes can make the tool
loop, allocate without bound, print raw bytes or choose between two
anchors.

## Verification and testing

Each test is paired with the seeded fault that proves it ran.

| Test | What passes | Seeded fault that must make it fail |
| --- | --- | --- |
| the stop core, exhaustive, on the host | for up to 4 CPUs, every interleaving of entries into the stop, request deliveries, CPUs in a lock's wait, CPUs that never unmask, CPUs at each step of their admission before, during and after the census, and the bound: exactly one leader; every CPU in exactly one state; every CPU that passes its admission is in the leader's set or parked `starting`; registers only where a slot was published; a nested stop never waits; a CPU that parked or followed and faults again, after its slot's store or just before it, publishes nothing more; the census ends by the bound | the claim treating its own CPU's word as another's, so a nested stop waits on itself; the claim following at every depth, so a CPU that faults again publishes a second time; the census marking an asked CPU `stopped` without its slot; the admission loading the stop word before it sets its bit, so one interleaving lets a CPU run on unasked |
| the admission's ordering, a litmus test at the milestone gate | under the architecture's memory model, never both at once: the leader's load missing a CPU's bit, and that CPU's load missing the stop word | the barrier removed from either side |
| the hold's line reader and step, exhaustive, on the host | over every state and byte: the first byte alone chooses a line's kind; a frame line echoes nothing and draws a reply only when it passed every check; a command line echoes exactly the printable bytes it kept, a backspace at an empty line changes nothing, and a line past the bound is refused whole; a newline after a carriage return ends no second line; `range` for every range that leaves the map, over maps of one to 16 ranges and ranges that straddle, touch and wrap; the hold ends at `reset` with the token, a frame's or a typed one, and at no other time, and a bare `reset` or one with another token prints the line that names the token; an erase writes backspace, space, backspace, and no other byte outside printable ASCII is written | the range check comparing the range's start alone; a backspace at an empty line moving the line's start; a frame line echoed; a line past the bound run as its first bytes; the token check removed: a bare `reset` ends the hold |
| the commands' parser, on the host | each command's accepted forms and each refusal: an unknown name, a missing or extra argument, a number that overflows, a count past its bound, a size letter outside `bhlg`; each `ddb` name reaches its command's row; for every row the prompt has, the kernel's table and the tool's print the same line of `help`, and the generator refuses a prompt row that needs control, time or type data | the count's bound check removed: `x` reads past `hold_read_max`; a prompt row left out of the kernel's table: its line is missing from the kernel's `help`; a row needing `control` marked the prompt's: the generator accepts it |
| each command over a stop image the test builds, on the host: an anchor, slots for four CPUs in four states, a crash record, trace rings filled by the ring core's writer, translation tables of every descriptor kind, a stack with seeded frames in a second space, a symbol table, and a sentinel-headed list of objects of three classes and one that is no thread, linked through a member that is not at the object's start, under a walker table of the test's own; the same with the list empty | `show panic`, `cpus`, `regs`, `bt`, `threads`, `thread`, `trace` and `x` print the seeded values, with the seeded functions' names and offsets, and `tools/erx debug -n` prints the same lines from the same image; `threads` lists the three threads and not the other object, ends at the sentinel, and prints nothing for the empty list; a thread named by a slot is `running on cpuN` with that slot's registers, a switched-out one starts at its saved continuation, and a never-run one's backtrace ends `cut` after one frame; an address one byte past a function's size prints bare; the C walk and the tool's translate every address alike; an address in a hole, one mapped to a page outside the map and one not mapped are each refused by name; a list linked into a cycle, one that leaves readable memory and one longer than its bound are marked cyclic, cut and truncated | the translation's last step skipping the map check: the page outside the map is read; a walker's field mapped to its neighbour: the prompt's line and the tool's differ; the test for a row already read removed: the cyclic list is marked truncated; the link-to-row adjustment dropped: no thread is found; the sentinel test removed: the walk reads the list object as a row; the symbol search comparing with `<=` at a function's end: the byte past it is named; a running thread given its saved context: its backtrace differs from its CPU's |
| the commands' core cannot follow a machine address | a source that dereferences an address of the stopped machine, or passes one where a pointer is expected, does not compile | the address type made a plain integer: the source compiles, and the test fails |
| `native_hold_prompt`, the cell with `erx.hold=1` on a development test kernel with a seeded panic on CPU 2 of 4 and a seeded thread blocked in a seeded wait: the harness types at the held machine through the console's socket, runs the tool with `--held` on the same machine, and takes QEMU's own image of it | the echo is what was typed; `show panic` gives the seeded message; `cpus` gives CPU 2 `leader` and three `stopped`; `bt` holds the seeded function's address; `threads` lists the seeded thread in its wait, and `bt thread` reaches its seeded frame, named; the leader's thread and CPU 3's running thread are `running on cpu2` and `running on cpu3`, and `bt` of each equals `bt` of its CPU; `bt` names the seeded function; `trace` ends in the seeded event, whose thread ID `thread` accepts; `x` of a seeded word gives it, and `x` of the UART's register page is refused; every line equals the line `tools/erx debug -n` prints from the image; the tool finds the anchor by `anchor`, and its `report` equals its `report` from the image; a typed `reset` is answered with the token and a typed `reset TOKEN` resets the machine | the glue's window mapping the page before the one asked: `x` and the image differ; the map check removed from the commands' read: the register page is printed; a prompt printed after a reply: the tool's transcript holds a line the cell does not expect |
| the readable-RAM map, on the host | over boot maps the test builds: a virtual entry that spans every `ram` range changes nothing; an `excluded` entry inside a `ram` range splits it, rounded outward; overlapping and touching `ram` ranges join; a map of 17 ranges, an entry whose end overflows and a `used` entry that leaves the result are each refused, never cut; and over random maps, every page of the result lies in a `ram` entry and in no `excluded` one, and the result is sorted, disjoint and whole pages | the subtraction skipped: the interior exclusion is readable; a 17th range dropped without a refusal |
| Fiasco's classification, on the host | every descriptor type and sub-type of the kernel information page, physical and virtual, gets the class of [On Fiasco](#on-fiasco)'s table, and a value the table does not list is `excluded` | a virtual `Conventional` descriptor classed `ram`; the default changed to `ignored` |
| the hold decision | over every development flag, word, boot value, lease and watchdog state: a hold is allowed only when all five allow it; and over both verdicts on the map: a stop in an allowed boot holds only with a map that was not refused | the trial's refusal removed; the map's verdict ignored |
| the slot's publication, a litmus test at the milestone gate | a reader never sees a published state with stale registers | the state stored without release ordering |
| the record's trace tail, on the host, and its readers under the crash records' fuzz targets | over rings of 1, 4, 16 and 17 CPUs that the test fills, each set among more rings that were never written (four written of eight among them), with a ring younger than its share, a record left half written and an exhausted ring: each written ring's share, oldest first, 8 each for four written of eight, without the half-written record; every tail written passes `erx_crash_check`, and `crash_read.c` and `crash_frame.rb` agree on mutated tails | the writer's check of a record's `cpu` against its ring dropped, with one record seeded with another CPU's number: the check refuses the record written; the share computed over all seventeen rings in place of the first sixteen: one slot each in place of two, and the case fails; the share computed over `ntrace` in place of the written rings: 4 each for four written of eight, and the case fails |
| the crash core and its readers | records with CPU entries round-trip through `crash.c`, `crash_read.c` and `crash_frame.rb`, which agree case by case; the brief form carries, for `panic`, the message, the leader's registers and backtrace, and for every cause each CPU's number and state with every register word zero, and for `fault`, `halt` and `watchdog` no registers, backtrace or text, whatever the stop hands the writer | an entry with a state outside the enum accepted by one reader; an entry's registers copied into the brief form; the root's user registers written into a brief `fault` record; the log's tail written after a brief panic's message |
| the boot arguments' parser (`boot_args.c`) and the root's arming of the board's watchdog (`test/host/pm_wdt_test.rb`) | a release build refuses a boot whose command line carries `erx.hold=1`; the watchdog is armed in every boot but a deterministic one and one that may hold | the refusal removed; an attended boot armed |
| `native_machine_stop`, a QEMU cell on a development test kernel with a seeded panic on CPU 2 of 4, under TCG and HVF | one crash frame of cause `panic`, CPU 2 `leader` and the others `stopped`; the image's `report` symbolizes the leader's backtrace to the seeded function; the record's trace tail holds 8 records of each CPU, none newer than the stop, and `tools/erx debug FRAME trace` prints them | the request's send removed: three `unanswered`; the tail's writer skipped: `trace` on the frame finds no records |
| the same cell with CPU 1 waiting for a spinlock that CPU 3 holds, interrupts masked on both, CPU 3 spinning | CPU 1 `waiting` with the seeded lock's address, CPU 3 `unanswered`; the image shows CPU 3's program counter in the seeded loop, and `whatis` names the lock | the check removed from the wait loop: CPU 1 `unanswered` |
| the same cell with CPUs 1 and 2 panicking at once | one frame; one `leader`, one `concurrent` | the claim by a plain store: two frames |
| the same cell with CPU 3 held in its start until the census has ended, then released | the record gives CPU 3 as `offline`; no line of CPU 3's follows the crash frame; the image's slot for CPU 3 is `starting`, with its program counter in the admission | the admission's check removed: CPU 3's start-up lines follow the frame, and the image shows it in its idle loop |
| the same cell with CPU 3 held between its admission and its unmasking of interrupts while CPU 0 stops the machine | CPU 3 `stopped` | the CPU's bit set after it unmasks interrupts and not at its admission: CPU 3 is not in the leader's set, is not asked, and runs on |
| the same cell with CPU 3 printing in a loop with interrupts masked | CPU 3 `unanswered`; the report's first line names it and says whether the console's lock was taken; the harness's reader gives the crash frame whole or reports it damaged, never a record with another writer's bytes in it; the tool's report from the image is headed by its warning | the first line's statement removed; the reader's check of the frame skipped, so a damaged frame parses |
| the same cell with a fault seeded inside the record's writer | `erx: nested stop` and the end within the run's deadline | the depth check removed: the run never ends |
| the same cell on a release test kernel, whose test image's command line carries the word | a brief record whose `panic` holds exactly the message, the leader's registers and backtrace, the fault field, the header, and each CPU's number and state, and no other nonzero byte; the report prints those and nothing else; no `--erx-held`, no prompt, no reply to the requests and no echo of the commands the harness sends after the frame, and a reset | the release kernel built with the hold, which the configuration check refuses before the cell runs |
| `native_hold`, the cell with `erx.hold=1`: the tool reads the held machine through the console's socket, then the harness takes QEMU's own image of the same stopped machine | every range the tool read is byte for byte the image's; every range of the anchor's map lies inside the RAM the image holds; a `read` of the UART's own register page, and one of an address that only the kernel information page's virtual descriptor covers, are answered `range`; the tool's `report` from the held machine equals its `report` from the image; a second run of the tool, with `--held`, finds the anchor by `anchor` and reads the same bytes; after `reset` the machine resets | the glue's window mapping the page before the one asked: the bytes differ; the range check removed: the register page is read; the virtual descriptor classed `ram`: the second `read` is answered, or faults; `anchor` answered with the stop slots' address: the second run finds no anchor |
| `native_ram_sweep`, a development test kernel that, once its map is built, reads one word of every page of the map through the hold's window and prints how many it read | the count is the map's number of pages, and the boot goes on to the root's first line | the sweep stepping two pages at a time: the count is half the map's |
| the same cell without the word | no `--erx-held` and no prompt; requests and commands sent after the frame draw no reply and no echo | the hold decision ignoring the word |
| `inspect` against `/proc` | on an image taken right after the cell reads `/proc/budgets`, `/proc/domains` and `/proc/cpus`, `export` gives the same value for every attribute both report | one walker's field mapped to its neighbour |
| walker resolution at build time | every walker's kinds, keys, reporters and fields resolve | a walker naming a field the image does not have fails the build at its line |
| `audit` | clean on an image of a healthy machine; on an image in which the test has overwritten one handle's slot in the root's table, exactly that row, by path and address | the reference check skipped: the corrupt image audits clean |
| `tools/erx debug --stub` on a TCG run | attaches, stops, lists 4 CPUs, reads a kernel symbol's memory, reads a stopped CPU's translation root by its own register and finds the root its space's record gives, sets `watch` on a budget's `used`, continues, and reports the stop at the charging funnel | the physical mode request removed: the symbol's bytes no longer match the image's |
| the stub client against a scripted stub, on the host | a description whose `target.xml` only includes annexes is read whole; the core registers come from `g` and the translation root from `p`; an annex past its size bound, a seventeenth annex, an include inside an annex and an annex name with a character outside the allowed set each refuse the target; with no annex that lists the translation root, `watch` on an address of another space is refused with the register named, and `watch` on a kernel address still works | the size bound removed: the long annex is read; the refusal removed: the watch is set, and a stop in the wrong space is reported as the one meant |
| moments, against the same scripted stub | an address read before and after `continue` across a write gives the old value and then the new; `save` after the second read holds the second moment's page alone and names that moment; on a scripted replay, `at` an earlier count discards what was read | the pages kept across `continue`: the second read gives the old value |
| a recorded run | a case that seeds one stray write to a budget's record and panics later is recorded, replayed to its stop, and `when budgets/N used` ends at the seeded store, at the same instruction count on every replay | the watchpoint set on the neighbouring field: `when` ends at the replay's beginning |
| the views' statuses | on an image with a hole where an attribute lies the attribute is `unknown`; one no walker reads is `unsupported`; a value outside its type is `{error, invalid}` with its bits beside it; a walk that meets its own row again is marked cyclic | an unreadable range answered with zero bytes: the attribute reads `ok` |
| the anchor search | an image with the kernel's anchor is accepted without the bundle's address; one with a second page that passes every check is refused, both addresses named | the search returning its first match |
| the tool's printer | a record whose text holds ESC, a C1 control, a bidirectional override, a newline and invalid UTF-8 prints escaped from `report`, `log`, `inspect` and `print` | the escape left out of one command's path: the source check on the tool's output calls fails, and the raw byte reaches the transcript |
| the tool's requests | the stub client and the hold client have a constructor for each listed request and no other, checked over their public methods | a constructor for the `M` packet added: the test names it |
| the configuration check, and the source check of the hold's reader | no kernel's resolved configuration has `CONFIG_INPUT`; a release kernel's has no `CONFIG_ERX_HOLD`, its build defines `UART_WITHOUT_INPUT`, and its link holds no symbol of the line reader or of the commands' core; in the fork's sources only the hold's glue names the UART library's `char_avail` and `get_char` | a resolved file with either option: refused; a second caller of `get_char`: the source check names it; a release link that pulls in the commands' core: its symbol list names it |
| the kernel symbol table's generator and lookup, on the host | over the test kernel's linked image, the table names every function symbol of its text; the C lookup through a checked read and the Ruby projection give the same function and offset for every address of the text and for addresses past each function's end; a table whose build identifier is not the anchor's is not used | two overlapping functions accepted; a name with a byte above 0x7f accepted; the build identifier check removed: a table of another build names the frames |
| the image packer and the release build check | a development image that may hold carries the symbol table; a release image never does, and one built to carry it is refused | the packer adding the table to every image: the release check names it |
| the root's record at a stop on Fiasco, in `native_machine_stop`'s cells with a missed watchdog pet and with a fault of a root thread | `show panic` and the tool's `report` give the root's record, cause `watchdog` and `fault`; a record seeded to fail its check gives `record: unknown` with the reason | the copy skipped: `show panic` gives an empty record as `ok`; the check skipped: the seeded bad record is shown |
| the cell that sends `reset` across the drain: the harness writes `reset` and a newline to the console's socket while the seeded panic is entered, and again just after `--erx-held` | the machine stays held, answers the bare `reset`s with the token, and resets at `reset TOKEN` | the token check removed: the machine resets at the queued line |
| the license audit | no kernel build, development or release, links a source under a license that is not permissive | compile records that name a source its import record gives as GPL-2.0-only: a development build is refused as a release build is |

**Fuzz targets**, each landing with its decoder: the hold's line (C, the
core's, fed a byte at a time: every line ends in a drop, in one reply
within its bounds, or in one command's output within its bound, and
every byte written is printable ASCII, a line's end or the erase
sequence); the prompt's
commands over arbitrary memory, rings and records (C: every command on a
random stop image ends within its bounds, reads nothing outside the map
and prints only printable ASCII); the hold's reply frame and the crash
frame's CPU entries in the
existing crash targets (`tools/fuzz/crash_fuzz.c`,
`tools/fuzz/crash_frame.rb`); the anchor reader and the anchor search;
the ELF core reader (headers, segments, notes); the protocol client's
packet decoder (framing, checksums, escapes, run-length encoding, stop
replies, error replies) and the target description reader, over
`target.xml` and its annexes; the machine
protocol's replies for the commands the harness adds; and the walkers
over arbitrary memory: every command on a random image ends within its
bounds and prints only escaped text.

The cells run at the landing gate when a change touches the stop, the
hold, the harness's end handling or the tool, and in the full QEMU suite
at the milestone gate. The Raspberry Pi 4's manual checklist gains two
items. The sweep kernel boots and prints the map's page count, which
settles P11 for the board. And an attended boot of a test kernel with a
seeded panic holds: in a plain terminal program `show panic`, `cpus` and
`bt` answer; the tool, started with `--held`, reports the seeded
function; the board is still held a minute after the tool has exited,
and resets at a typed `reset` and the token it answers with.

## Performance

The stop runs once, and a CPU's admission, one store, one barrier and one
load, once at its start. On the paths that run always, the change is one
load of the stop word on each pass of a contended spinlock's wait, and on
Fiasco one pointer kept per CPU at each interrupt's dispatch; the change
to the interrupt entry lands with before and after numbers from
`tools/erx bench` for the IPC and interrupt benchmarks, as changes to the
kernel's entry do. Removing JDB shrinks the kernel by most of its
debugger's 28% share. A memory image is the guest's RAM, 512 MiB for most
cases, written only for a failing run. A hold's throughput is the
console's: about 8 KiB a second at 115,200 baud, which is on the
performance watch list with the measurement that settles whether a board
needs a faster line.
The prompt costs a running machine nothing, since its code runs only in
a hold; what it adds to a development kernel's image, the commands' core
and the walker table, is recorded when it lands.

## Prior art

FreeBSD's KDB stops every CPU and runs a backend with a reason from a
closed list; its gdb(4) backend is a stub and kgdb reads cores on the
host, and its ddb(4) backend is the prompt whose command names the
hold's prompt answers to where the command is the same. NetBSD's
`crash(8)` runs ddb's commands on a live system or a dump.
illumos mdb runs one debugger over many targets with walkers; OpenBSD's
ddb and mdb print typed memory from the build's type data. Windows KD
keeps the debugger on the host, finds its root block in a dump by its
tag, and writes dumps in tiers. seL4 has no kernel debugger and debugs
under QEMU's stub. QEMU's stub stops a whole machine without the guest's
help, and its replay finds the last watchpoint in the past. rr made
running backwards to a watchpoint the way to find a corrupting write.
Plan 9 debugs a process, local or remote, through the files of `/proc`.
The survey of [References](#references) cites each.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| Keep JDB in development builds | 28% of the kernel's code in kernel mode for a prompt nobody uses, a GPL file in every development image, no breakpoints on AArch64, a stop that cannot reach a CPU that masks interrupts, a resume that gives the console line two users, a board that resets four seconds into a session, and a published image whose console reads and writes kernel memory |
| No hold: a board without a probe has its record and nothing else | the record is 16 KiB by design; the failures only hardware shows are the ones QEMU's image cannot help with; the hold is one loop, one fixed-size request and a range check, in development kernels alone |
| A stub in the kernel that resumes: breakpoints, stepping and a break-in key on a board | QEMU's stub and a JTAG probe give breakpoints and watchpoints with no code in the kernel. A stub of the kernel's own needs a line the kernel owns for the whole boot, which the Raspberry Pi 4's shared UART page does not give; a pause and a continue of the whole machine, which Fiasco does not have and which would have to restore every CPU's timers, the devices and the console line's one owner; a path by which input from a line writes kernel memory and registers; debug exceptions taken in kernel mode, which Fiasco's AArch64 kernel has never had; and for software breakpoints, kernel text that is writable, against the rule that no mapping is writable and executable ([Decisions](#decisions), 6) |
| The GDB remote protocol in the kernel | dozens of packets where two requests serve, and a promise to behave as `gdb` and `lldb` expect; the protocol's client is on the host, where a mistake costs a session, not a machine |
| A line of its own for the hold | a second cable and a second UART for what the console, which the stop already owns, carries; see [Transports](#transports-and-the-console-line) |
| The kernel pushes a fixed dump after its record, with no input at all | it cannot know what the host will ask, so it sends everything it might: minutes of output at every stop, attended or not |
| The hold's prompt in published images too, limited to commands that reveal no secret, as `mac_ddb(4)` limits `ddb` | the prompt reads memory, which is every secret the machine held, and a list of commands that are safe for a stranger at the console is an enumeration that each new command can break; a published image's stop prints its record and reads nothing, and the prompt stays behind a word on the boot medium |
| No prompt: a held board is read by `tools/erx debug` alone | a board with no probe then needs the tree, the tool and the failing build's bundle on whatever host its wire reaches before it says anything; the first questions need none of them, and the commands that answer them are read-only functions over the read the hold already has |
| A prompt that also writes, sets breakpoints, steps or resumes, as `ddb` and JDB do | each needs what [Decisions](#decisions), 6 lists: a pause and a continue of the whole machine, input that writes kernel memory, and for breakpoints writable kernel text; QEMU's stub and a probe give them from outside |
| The prompt's commands written by hand in each kernel's glue, over the kernel's own accessors | a second model of the kernel beside the tool's, in kernel mode, which runs the stopped kernel's code on state the stop may have found corrupt and can wait on a lock a parked CPU holds; the core calls nothing of the kernel, and its tables are generated |
| Telling a frame from a command by decoding: a line that passes a request's checks is a request | the reader would have to echo before it knew, so a tool's session would carry an echo of every request; and that no typed command passes the checks would rest on a 64-bit magic, where the first byte makes it a rule |
| `ps` at the prompt | `ps` lists processes, which are the runtimes' and which nothing reads from a stopped machine ("Processes of a stopped runtime as views", below); a list of the kernel's threads under that name would wear it falsely, so the list is `threads` |
| Spaces, budgets and capabilities at the prompt on Fiasco | a budget, and a space's name and owner, are the root's records there, in an image whose layouts and symbols the kernel does not hold, and a capability table is a walk the tool already has; without the root's records a space is a number and a translation root. The tool reads all three through the same hold |
| The inspection paths at the prompt | on Fiasco a record's identity, a thread's domain for one, and most of its attributes are the root's; `threads` shows what the kernel itself holds, under the kernel's own numbers |
| The symbol table inside the kernel's image, as a second link | a table put into the image it describes moves the addresses it gives, so the image is linked twice and the two links must agree; beside the kernel in the boot image the table needs one link, and the readable-RAM map already reaches it |
| A backtrace of bare addresses at the prompt, with names left to the host | a board with a terminal and nothing else is what the prompt is for, and a list of addresses sends its reader back to a host with the build ([Decisions](#decisions), 12) |
| A bound on the hold's silence, after which the machine resets by itself | five seconds, or any bound a person can miss, resets the board while its developer is elsewhere, and what the prompt exists to show is gone; a boot that holds is attended, and a hang in it already waits ([Decisions](#decisions), 10) |
| A drain long enough to swallow every byte sent before the stop | no length of drain proves freshness: bytes can sit in a terminal's or an adapter's buffer for as long as they like; a token derived from the stop's own record does, at the cost of one word typed after `reset` |
| The thread walk taking the object's dynamic type from its own type function | `_cxx_dyn_type` is code of the stopped kernel, which the prompt never runs; the word at the start of `Kobject_dbg`, recorded from a live object of each thread class, answers the same question with a load |
| Offsets of the kernel's types for the prompt taken from the debug information, as the bundle's are | the table would be made from the kernel's compiled objects and linked back into the kernel, a second pass through Fiasco's build; Fiasco's own offset list gives the same numbers, base-class adjustments included, in the pass that compiles the kernel |
| More of `ddb`'s surface: abbreviations, `$` variables, a current address, the last format, scripts, a pager | each is state or grammar in kernel mode for a convenience; the prompt keeps nothing from one line to the next, and the tool is where a long session belongs |
| Scripts per stop reason in the kernel, as FreeBSD's `kdb.enter.<reason>` | `report` is the script, run on the host where it can be changed without a new kernel |
| Stopping a masked CPU by an interrupt the kernel's masking does not mask | each route changes how the kernel masks interrupts everywhere, or rests on firmware support that is unverified ([design-arch-aarch64.md](design-arch-aarch64.md#stopping-every-cpu)); the lock's wait reaches the commonest case with one load |
| Holding QEMU at a guest's reset (`-no-shutdown`) and no hold under QEMU | it changes how every run ends, and rests on the emulator keeping every CPU's state at a reset it turned into a pause, which is unverified; the hold's line gives the harness the same moment and exercises the hold on every failing run |
| A query language in the tool | the views are text in the schema's order, and `grep`, `sort` and `diff` are already installed |
| Datalog rules for the audit | no rule is needed that the schema's types and references do not already state; a rule language is a new language to approve, for a consumer that does not exist yet |
| Hand-written views of Fiasco's structures in the tool | a second model of the kernel; the walkers name fields and the build supplies and checks the rest |
| The tool as a server between `lldb` and a held board | a second protocol role for source-level reading of a machine that cannot step; revisit if developers ask for `lldb` over a saved image |
| Processes of a stopped runtime as views | the runtime's process tables are ERTS's own structures, a large set of walkers with no consumer yet; the seam is a walker file for the runtime's image |
| Leave everything to `lldb` on QEMU's stub | no views of the kernel's model, no reading of crash records, boards or images, and no report in the harness; `lldb` stays the choice for source-level stepping |
| One kernel build for development and release, the hold decided by the image's flag alone | a release kernel would link code that reads its console in kernel mode, kept off by a flag in a file the boot medium holds; built without it, "no release kernel reads its console" is a property of the link, which a check proves |
| No hold after an incomplete census | the simplest rule, and it would make "a held board has no running CPU" true by construction; but that stop is the one most worth reading, and the harness takes its image of exactly that machine at the hold's line. The hold is entered, its replies' CRC catches a damaged one, and the tool says what the hold no longer promises |
| The census over the kernel's own account of online CPUs, asking again each round for CPUs that came online | a CPU that comes online after the last round is never asked and runs on; and Fiasco marks a CPU online long before it can take the request. The admitted set and the check at admission need one look and leave no window |
| An anchor map copied from the boot map, or cut to 16 ranges | Fiasco's boot map holds a conventional descriptor of virtual addresses and reservations laid over RAM, so a copy is not a list of readable memory; and a cut map answers "not memory" for memory that is there |
| One image for a whole session on a stub | two reads of one address on either side of a `continue` can differ, and pages of two moments together describe a machine that never existed; a save is of one moment |

## Decisions

Each of these was a choice between designs, and is settled as stated.

1. **No debugger that breaks into a running kernel, on either kernel,
   and the hold in a development kernel.** The ledger's row "Kernel
   debugger" ([design-kernel.md](design-kernel.md#the-ledger)) reads none
   on either kernel, with the stop, the record and the hold in its place.
   The hold is code in kernel mode, in development kernels alone: a
   polled read of the console, a reader of RAM, and a prompt whose
   commands only read (9). Without it a board with no probe attached has
   its record and nothing else.
2. **Published images.** No image carries JDB or its GPL object, and a
   published image's stop prints its record and resets. The images the
   website offers are rebuilt and republished once the stop has landed;
   until then they are the builds [plan.md](plan.md#01-the-preview)
   describes, with JDB and its source offered.
3. **Where the work lands.** In 0.2, in the place of the release kernel's
   build without the debugger and of the debugger's configuration
   check ([plan.md](plan.md)), in three parts that each land alone: the
   stop with its record and JDB's removal; the host's tool over records
   and images, with the harness's reports; the hold, whose prompt lands
   with its frames or after them. Stubs, replay and
   the probe follow as their probes settle
   ([Unverified facts](#unverified-facts)).
4. **Debug bundles of published builds** are kept with each build's
   release records, outside the repository, so a record a user sends
   symbolizes.
5. **`kdb_ke` stops the machine in every build.** Three checks call it
   outside the debugger's own parts: a dead thread that runs again
   ("DEAD SCHED" and "I'm dead", `kern/thread.cpp`) and a mapping insert
   that returns what it cannot ("BUG in KU memory mapping",
   `kern/task.cpp`). A kernel without JDB prints `NO JDB` and goes on at
   each; a kernel with it has always stopped there. Stopping is what
   erXos's kernel does at a broken invariant, and going on runs a kernel
   that has just found its own state wrong. The cost is stated: the three
   checks are ends of the machine in the release, where a Fiasco defect
   that reaches one from a domain is a reset and not a line in the log,
   so the system-call fuzz campaign counts a stop at any of them as a
   finding, as it counts any crash of Fiasco
   ([design-fiasco.md](design-fiasco.md#verification)).
6. **No stub in the kernel that resumes: breakpoints on a board come from
   a probe.** Under QEMU the stub gives breakpoints, watchpoints and, on
   a recording, running backwards, and on a board a JTAG probe gives the
   first two, each with no code in the kernel. A stub of the kernel's own
   would need a pause and a continue of the whole machine, which Fiasco
   lacks, a path by which a line's input writes kernel memory, and
   writable kernel text for software breakpoints
   ([Alternatives considered](#alternatives-considered)). A board without
   a probe has the record and the hold: everything after a stop, and
   nothing that pauses a running kernel and lets it go on. The question
   reopens only if P5 shows that a probe cannot halt and read a Raspberry
   Pi 4.
7. **The walker files are a specification format of their own**, in the
   style of `abi/inspection.txt`: facts in lines, closed sets, a Ruby
   generator that validates every row. Ruby tables in the tool could be
   checked as well, but would put layout knowledge of two kernels inside
   host code.
8. **The research records live in the history repository.** The three
   records this design cites are point-in-time reports with the sources
   they read. They are kept in `~/erxos-history`, the repository for
   records and raw data, and not in this tree, and
   [References](#references) cites each by its path there.
9. **The full record's trace tail is 32 records**, `crash_trace_records`
   ([The record's trace tail](#the-records-trace-tail)): 2,048 bytes,
   about a quarter of a second more at 115,200 baud, and 8 records for
   each CPU of the four-CPU boards and QEMU cells erXos runs on. A longer
   history is the hold's, which serves whole rings.
10. **The hold has a prompt, and the prompt only reads.** A held board
   answers a closed set of commands typed at any terminal, so that
   reading one needs no tool on the host. The commands are the tool's,
   under the tool's names and under FreeBSD's where `ddb` has the same
   command; they are a core that calls nothing of the stopped kernel and
   reaches memory only through the hold's checked read
   ([The prompt](#the-prompt)). It stays inside the hold: a development
   kernel, a boot that asked, after a stop. It does not resume, write,
   set a breakpoint or step, which stay as 6 says.
10. **A held machine holds until `reset`.** No bound on silence ends a
    hold: a boot that holds is attended, and a hold ended by itself after
    a few seconds would lose the stop of every board whose developer was
    not at the keyboard then. A board that must come back by itself does
    not carry `erx.hold=1`. The token is what makes waiting safe: input
    queued before the stop cannot end the hold
    ([The hold](#the-hold)).
11. **`trace` is the kernel's trace rings**, at the prompt as in the tool
    and in `erx:trace`, and the stack trace is `bt` and `where`. In
    `ddb`, `trace` is the stack trace, so a FreeBSD user who types it gets
    events; the name is the one the tool, the guide and the trace's own
    design use, and `help` lists both.
12. **Development images that may hold carry a kernel symbol table**,
    so `bt`, `regs` and `x` name kernel functions with no host
    ([Symbols](#symbols)). It is made from the linked kernel's symbols,
    lies beside the kernel in the boot image, is bounded, is checked
    against the anchor's build identifier before use, and is never in a
    release image.
13. **The brief form prints what FreeBSD's release kernel prints.** For
    a kernel `panic`, a release record holds the message, the failing
    CPU's registers and its backtrace as code addresses, and every
    CPU's state, as FreeBSD 14.3's `GENERIC` prints its registers,
    message and backtrace unconditionally
    ([The record's CPU entries](#the-records-cpu-entries)); the root
    task's ends keep no registers. What that exposes is stated under
    [Security](#security).

## Open decisions

None.

## Unverified facts

None of these is a decision. Each is a fact no source or run read for
this design establishes, with the probe that settles it.

* P1. Whether QEMU's stub, under HVF, stops the machine, reads registers
  and memory, and inserts hardware breakpoints and watchpoints (its
  documentation says support depends on the accelerator); and, under TCG
  and HVF alike, what its description is: which annexes `target.xml`
  includes, whether any annex includes another, whether the whole fits
  the tool's bounds (16 annexes of at most 1 MiB, names of the allowed
  characters), and whether it lists the translation root's register, and
  under which name, so that `p` reads it. Probe: `tools/erx debug --stub`
  on a TCG run and on an HVF run, recording the annexes it fetched.
* P2. Whether QEMU's ELF dump of an AArch64 guest carries one register
  note for each virtual CPU, under TCG and HVF, and whether it carries
  the translation root. The tool needs neither for a machine that stopped
  itself; for a hang it needs the first. Probe: dump a stopped run and
  read the notes.
* P3. Whether a recording replays, under the harness's pinned QEMU, with
  the machine and the devices its cases use, with more than one CPU, and
  whether running backwards stops at a watchpoint. QEMU's documentation,
  read at v10.1.0, says replay covers AArch64, serial ports, block
  devices behind its driver and network backends behind its filter, and
  that running backwards stops where "breakpoint or watchpoint was met".
  Probe: the recorded-run test of
  [Verification](#verification-and-testing), first on one CPU.
* P4. Whether QEMU's stub resumes the machine at `D`. Probe: detach from
  a stopped run and read its status through the machine protocol.
* P5. Whether the probe at hand, with OpenOCD's BCM2711 configuration,
  halts each core of a Raspberry Pi 4, serves the GDB remote protocol,
  reads physical memory, and whether the kernel must do anything for it.
  Probe: an attended development card, halted at a known function.
* P6. Whether Fiasco's kernel and the cores keep frame records in every
  function, so a frame-pointer walk gives the whole backtrace. Probe: the
  seeded panic's backtrace in `native_machine_stop`.
* P7. Whether a spinlock waiter that sleeps for an event finds the stop
  word when it wakes. The leader stores the word before it signals the
  event and before it sends the request, so what must hold is an order,
  the store, then the wake, then the waiter's load seeing the store, and
  not only that a waiter wakes. It has three parts: that a waiter asleep
  for an event wakes when another CPU signals one, or when the stop
  request becomes pending on its CPU, under HVF and on the boards; that a
  signal sent just before it sleeps still wakes it; and that its load
  after either wake sees a store made before the signal. Under TCG the
  fork's own unlock relies on the first, and the case that fails without
  it is the evidence
  ([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build),
  "The spin lock's event"). Probes: a litmus test of the store, the
  signal and the waiter's load, at the milestone gate, whose seeded fault
  is the store moved after the signal; the cell with a seeded lock wait,
  repeated under HVF; and the same seed on the board. Until they settle
  it, the Fiasco glue does not rest on one request: each millisecond of
  the census it asks again every CPU that has not published, so a CPU
  that took a request before it could see the store is asked once more.
* P9. Whether `sigma0` ignores its object-naming calls failing on an
  empty slot 10. Probe: any full boot of a kernel without the object.
* P10. Whether, on Fiasco, a stop request sent to a secondary CPU that is
  past its admission and has not yet unmasked interrupts is taken when it
  unmasks. The admission is the last step of `App_cpu_thread::bootstrap`
  before interrupts are unmasked, and by then the CPU's interrupt
  controller interface and the request's handler must be set up; the
  per-CPU set-up was not read to confirm that they are. Probe: the cell
  that holds CPU 3 between its admission and its unmasking while CPU 0
  stops the machine.
* P11. Whether Fiasco's boot map is right for each board: that no
  physical `Conventional` descriptor covers anything but RAM, that every
  range of the device tree's reservations, the firmware's own memory on
  the Raspberry Pi 4 among them, has a descriptor the table classes
  `excluded` or lies outside conventional memory, and so that a read from
  kernel mode of any page of the readable-RAM map neither faults nor
  touches a device. The boot stage that writes the descriptors was not
  read for this design. Probe: `native_ram_sweep` under QEMU and on each
  board's manual checklist, which reads every page of the map and so
  finds a hole inside a range as surely as one at its edge; a page that
  faults is a kernel trap whose record names the address.
* P12. That the first word of a `Kobject_dbg` is its virtual table
  pointer, equal across the objects of one most derived class and
  different between classes, as the C++ ABI that Fiasco's compilers
  follow places a vtable pointer at the start of a polymorphic class
  without a polymorphic primary base; the ABI's document was not read
  for this design. Also that the glue's three recording points see a
  live object of each thread class: the boot CPU's own thread, each
  secondary CPU's at its admission, and the root's first thread when
  the anchor is completed. Probe: the host test over a list of mixed
  objects built by the fork's own classes, and `threads` in
  `native_hold_prompt`, which must list the root's threads, each CPU's
  idle thread and the seeded one, and no other object.
* P13. That every Fiasco thread switched out by
  `Context::arm_switch_gp_regs` keeps its continuation at `_kernel_sp`
  and its frame pointer eight bytes above, read from
  `kern/arm/64/context-arm-64.cpp`; what the continuation's own frame
  holds was not read. Probe: `bt thread` of the seeded blocked thread in
  `native_hold_prompt`, which must reach its seeded frame.

## References

* The research records of 2026-11-25 at erXos commit `934479cb7`, kept in
  the history repository, `~/erxos-history`, and not in this tree
  ([Decisions](#decisions), 8):
  * `notes/debugger-2026-11-25/jdb-survey.md`, SHA-256
    `d3c48e6e36a4f0d7d4befc50fb5f1a56bc5e060f3001c52b0250f3b1dc625010`:
    JDB's parts, commands and entry routes and what erXos uses them for;
  * `notes/debugger-2026-11-25/kernel-debuggers.md`, SHA-256
    `f61d83a2bf47aaf3ebca40f4caadd0c7dd83572f23d6a186f6288b7c16387251`:
    the survey of FreeBSD's, OpenBSD's and NetBSD's ddb, illumos mdb and
    kmdb, Windows KD, Linux's kgdb documentation, seL4, QEMU's stub and
    replay, rr, DTrace and Genera, with every source it read under
    `notes/debugger-2026-11-25/src/` and each one's SHA-256 in
    `SHA256SUMS` there;
  * `cleanroom/facts-jdb-object.md`, SHA-256
    `205ac306284f1c94f40cd949289be4f2b1b86a04a81095541e656ed7b7de119c`:
    the clean-room facts record of `jdb_object.cpp`, whose own SHA-256 is
    `6a1359080661ea097fae1a9228dc6448c87b95dcaa6e9974c5e5c6ffc87ec3a2`
    and which only that record's own agent read.

  One statement of the survey is wrong and this design does not rest on
  it: its command table lists JDB's breakpoints among the commands on
  AArch64, and the module that implements them is built for 32-bit Arm
  alone ([Context](#context)).
* FreeBSD `release/14.3.0`, `share/man/man4/ddb.4`, from
  `cgit.freebsd.org`, SHA-256
  `38c8880df3eab1f5bb080d601591320413118927d78d2b86393f81fa16145699`, the
  survey's copy (`src/freebsd/ddb.4`): the names the prompt's commands
  answer to (`help`, `x`, `bt`, `where`, `reset`, `show panic`,
  `show registers`, `show threads`, `show thread`, `show msgbuf`); that
  `trace` is its stack trace and `ps` its list of processes; its `radix`
  variable; and `write`, `break`, `step` and `continue`, which the
  prompt does not have.
* QEMU v10.1.0, `docs/system/gdb.rst`, SHA-256
  `a662a2961a3a9bbcfac02fae58facaf4d879cd9a56ae86db63b6a2fb66f6bbe1`: the
  stub on a UNIX socket, one thread a CPU, physical memory mode, hardware
  breakpoints on TCG and by accelerator elsewhere, the socket's security.
  `docs/system/replay.rst` of the same release, in the survey's sources:
  record and replay, snapshots, running backwards.
* The Fiasco fork's own sources, read in this tree: the kernel
  information page's descriptor types and sub-types (`abi/kip.cpp`,
  `Mem_desc`), the virtual conventional descriptor
  (`kern/arm/kip_init-arm.cpp`, `Kip_init::init`), the allocator's
  reading of the descriptors (`kern/kmem_alloc.cpp`,
  `Kmem_alloc::create_free_map`), a secondary CPU's start
  (`kern/app_cpu_thread.cpp`, `App_cpu_thread::bootstrap`), the printf
  lock (`kern/libc_backend_lock.cc`), and the receive members' guard
  (`src/Modules.generic`, `lib/uart/uart_base.h`).
* QEMU's QMP reference and invocation pages, `qemu.org/docs/master`,
  fetched 2026-11-25 (unpinned), SHA-256
  `e38890d98e59cba3b7d5856d60c2daa25fda4d5080687734506e282b13eff040` and
  `8a8db39a6ae58b79c5933fdbe8ef5ba702564134b5b7e67b36ea483cc74a061f`:
  `stop`, `dump-guest-memory`, `query-replay`, `replay-seek`, and
  `-icount` with `rr`, `rrfile` and `rrsnapshot`. The harness pins a
  later QEMU than the pages of v10.1.0 describe, which is why P1 to P4
  are probes and not facts.
* GDB manual, `sourceware.org/gdb/current/onlinedocs`, fetched
  2026-11-25 (unpinned): from appendix E, the remote protocol's
  specification, Standard Replies (in the survey's sources), and Packets,
  Stop Reply Packets, General Query Packets and Interrupts; from appendix
  G, AArch64 Features, the core feature every AArch64 description
  carries; SHA-256
  `44dfada09e55839aecff010e443469a592a4eb8eb653dfa28ca7b3836b887800`,
  `041824625f6f4bf73159da0461b3e2c7bbe569890cc81ffeccea549543401831`,
  `40aff051f25a9093935653ab2f187af8e3fd07b568b12174927172237ada122f`,
  `c379e8030a0062227d4725d185e198cbb663d7ba28626052978647286a275ce3` and
  `0442003eae18cf940b34022f79f2256ccd5db2c0cbf41140a21bc6c94663e0f6`.
