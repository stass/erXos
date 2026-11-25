# The kernel debugger

No debugger runs in kernel mode, on Fiasco or on erXos's own kernel. The
kernel does for a debugger the one thing nothing else can do for it: it
**stops**. Every CPU it can reach is parked with its registers where a
reader finds them, a crash record is written and printed, and the machine
ends. A stopped machine is memory, and everything a developer asks of it
is answered on the host, by one tool, `tools/erx debug`, as a function of
that memory and of what the build knows about it. The tool reads five
kinds of **target** through one interface: a crash record, a memory image,
a board that holds after its stop and lends its memory over the console
wire, a machine that QEMU or a hardware probe stops from outside, and a
recorded QEMU run, which it also reads backwards in time. Its views are
the inspector's: the paths of `/proc`, read from a machine that can no
longer answer for itself. Fiasco's kernel debugger, JDB, and its GPL-2.0
kernel object leave every build.

This document is the contract: what a stop does and what it leaves in
memory ([The stop](#the-stop), [Data model](#data-model)); how a board
lends its memory after a stop ([The hold](#the-hold)); how the host reads
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
under `fiasco/kernel/src/jdb/` for the configurations erXos builds, all
MIT. In a measured AArch64 build it and its trace buffer were 18,749 of
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

**The Jdb kernel object.** `fiasco/kernel/src/kern/jdb_object.cpp` is
GPL-2.0-only and is known to erXos only through a clean-room facts record
([References](#references)); nobody who writes erXos's code or documents
opens it. It is the capability in slot 10 of the first task
(`Initial_kobjects::Jdb`, `kern/globals.cpp`), through which user mode
enters the debugger, feeds it keystrokes, prints bytes on the kernel's
console with no escaping, appends to, clears and maps the trace buffer,
and forwards debug requests to other objects; holding the capability is
the only check. No erXos code names the capability or its calls: not
`liberx`, the runtimes, the system services or the tools.

**What erXos uses JDB for.** A development kernel carries JDB and the
kernel's console input, so a fatal kernel error parks every CPU it
reaches and waits on the console: on QEMU until the harness's deadline,
on a Raspberry Pi 4 until the watchdog resets the board. A release kernel
is built without both and resets at a panic
(`FiascoConfig::RELEASE_UNSET`, `tools/lib/erx/fiasco_config.rb`). A
development image, the website's among them, therefore carries a prompt
that reads and writes kernel memory for whoever is at its console after a
panic, and a GPL file.

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
4. **One command set for every target.** Consumer: whoever reads a
   failure later than it happened. Two command sets drift apart.
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
   development kernel has and only a boot that asked for it enters.
   Consumer: the release and the published images, whose console must be
   no route into kernel memory.
9. **No GPL file in any kernel build.** Consumer: distribution of every
   image, and the release's link audit.
10. **One stop core for both kernels.** Consumer: Phase 2, which changes
    what is behind the seam, not the protocol, the tool or their tests.

**What JDB offers that no consumer needs.** Each is dropped, or answered
by something erXos already has:

| JDB feature | Consumer in erXos | Fate |
| --- | --- | --- |
| the prompt on the console and its modes | none: no document or tool uses it | dropped |
| resuming after a stop | none it serves well: the console line then has two users | dropped; QEMU's stub and a probe stop and resume a machine from outside |
| reboot, the exit question | the end of a stop | the stop's end |
| console buffer, system report | the lines before a failure | the record's text; `log` |
| kernel info, per-CPU and interrupt controller state, idle statistics | none named | dropped; `print` reads any of it |
| object list, object, task list, thread lists, thread control block, UTCB | object, thread and space bugs | `inspect` over the schema's kinds; `print` and `list` for the rest |
| timeouts, sender lists, mapping database | none named | dropped; `print`, `list`, `whatis` |
| page tables, memory dump, entry frame | memory and translation bugs | `whatis`, `mem`, `regs` |
| disassembler (off in erXos's configuration) | reading code at an address | `llvm-objdump` on the host, over the build's image |
| breakpoints and watchpoints (32-bit Arm only) | kernel development | `break`, `watch` and `when`, the hardware's, on a target that stops from outside |
| halting a thread | none: thread control is the backend's | dropped |
| IPC and page-fault logging, log event switches, trace buffer, counters, performance events | event history; performance work | the trace ring, always on, and `trace`; benchmarks are `tools/erx bench`'s |
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
  written per kind of target.
* The views (5) take their paths, columns, types and statuses from
  `abi/inspection.txt` and their offsets from the build's debug
  information, so a renamed field fails the build, not the debugging
  session, and a user who knows `/proc` knows the debugger.
* Nothing is written (6) because the tool's protocol layers have no
  request that writes memory or registers, and the hold has none either.
* Reading backwards (7) is the same commands at another moment: a
  recorded run is a target with one more coordinate, the instruction
  count.
* Kernel mode reads input (8) in one state, the hold, which a release
  kernel is built without.
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
| **Kernel mode reads input in one state of one build kind**: the hold, of a development kernel, in a boot that carries `erx.hold=1` | a release kernel is built without the hold; the hold is entered from the stop path alone, after the record is printed; nothing else in either kernel reads a line | the configuration check; the cell that sends requests to a running machine and to a held one without the word |
| **The hold reads readable RAM and writes nothing a request names.** A request names a physical range, and the reply is refused unless the whole range lies in one range of the anchor's map, which holds only pages the boot map gives as RAM and none it excludes | the core computes the map at boot and refuses one it cannot state whole; one check in the core against that map; the request layout has no operation that writes | the core's tests of the map, over virtual entries, exclusions inside a range and maps past the anchor's capacity, and of every range against every map; the request decoder's fuzz target |
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
otherwise) and its registers, in the layout the architecture's ABI file
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
| `magic`, `version`, `crc` | 16 bytes that mark the page; the layout's version; CRC-32C of every field but the stop word |
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
CPUs the census covered, so a machine with more CPUs than entries says
how many its record leaves out. An entry holds the CPU's number, its
stop state and, for a state that has registers, the program counter, the
stack pointer, the frame pointer, the return address, the processor
state word and the slot's auxiliary word; every other byte is zero. The
brief form carries none, since registers may hold what the interrupted
code held ([design-kernel.md](design-kernel.md#the-root-task)), and a
record written before any census, as the root's are on Fiasco, carries
none and an `ncpus` of zero.

The crash core writes the entries from what the stop hands it. Its
writer cannot refuse, since nothing can report a refusal at the
machine's end, so it settles an entry as it settles every other field: a
state outside the enum is written as `unanswered`, and a state without
registers gets none; it writes each entry's number itself. Its check
refuses an entry whose number is not its index, a state outside the
enum, a nonzero byte where the state has no registers, a nonzero entry
past `ncpus`, and an `ncpus` past `cpu_limit` or in the brief form, as
it refuses any other malformed field (`kernel/core/crash.c`,
`erx_crash_check`). `kernel/core/crash_read.c` and
`tools/lib/erx/crash_frame.rb` read the entries and are held to the same
answer on mutated frames, as they are for the rest of the record.

The record stays small on purpose: it is what a machine says with nobody
listening, on a console at 115,200 baud, inside whatever time its end
has. A stop slot holds a CPU's whole register set; the record's entry
holds the six words that say where it was.

### The hold's frames

A held machine and its host exchange two layouts of `abi/kernel.txt`,
both as printable text, since the line they cross is a console that a
terminal may be showing:

* **A request**, `erx_hold_request`: a magic, an operation of the closed
  enum `hold_op` (`read` or `end`), a sequence number the reply repeats, a
  physical address, a length of at most `hold_read_max` (4,096) bytes,
  and a CRC-32C of the rest. It travels as one line: the layout in
  base64, then a newline.
* **A reply**, `erx_hold_reply`: the request's sequence number, a status
  of the closed enum `hold_status` (`ok`, `range` or `length`), the
  address, the length, a CRC-32C, and then `length` bytes of memory, none
  unless the status is `ok`. It travels in a frame of the crash frame's
  own shape, between the lines `--erx-hold-begin <length>` and
  `--erx-hold-end`, 57 bytes to a 76-character line of base64, so one
  frame writer and one frame reader serve the record and the hold
  ([design-kernel.md](design-kernel.md#the-root-task)).

The hold announces itself with one line, `--erx-held <anchor>`, the
anchor's physical address in hexadecimal. The marker strings, the limits
and both layouts are declarations of the ABI file, and the C and Ruby
readers and writers are generated from them.

### Targets

The host's one interface, which each kind of target implements:

| Operation | Crash record | Memory image | Held board | Stub | Replay |
| --- | --- | --- | --- | --- | --- |
| list the CPUs and give one CPU's registers | the record's entries: six words a CPU, none for `unanswered` and `offline` | the image's register notes, and the stop slots through the anchor if the machine stopped itself | the stop slots through the anchor | the stub's threads, one a CPU: the core registers from one reply, any other by its number ([The GDB remote protocol subset](#the-gdb-remote-protocol-subset)) | as a stub |
| read physical memory | nothing: every read is "not here" | the image's segments; a gap is "not here" | a `read` request; a refusal or a silent line is "not here" | the stub's memory read in physical mode | as a stub |
| stop, continue, break, watch | no | no | no | yes | yes |
| move in time | no | no | no | no | yes: back to the last break or watch, and to an instruction count |
| end the machine | no | no | `end` | no | no |
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
   console (the message, in a development build the leader's registers
   and backtrace, and one line for each CPU with its state and where it
   was), and the crash frame, through the console's polled write alone.
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
whether the boot allows a hold; and the hold's step, over its state and
one event (a line, a finished reply, a tick). It reads no hardware and no
global state, builds for the host, and its machine is explored
exhaustively there. The compare-and-swap, the barriers, the request, the
slots, the clock, the frame walk, the console and the end are each
kernel's effects.

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
address and answers requests on the console line until the host says
`end` or falls silent.

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
gives is less, and the tool says so at the head of everything it prints:
a CPU that did not answer may still write the line, so a reply can arrive
damaged, which its CRC catches and the tool asks for again; and it may
still write memory, so what the tool reads may change while it reads
([Moments and images](#moments-and-images)).

**The loop.** The leader polls the console UART's receive register and
gathers bytes into a line of at most a request's length. At a newline the
core checks the line: the right length, base64, the magic, the CRC, an
operation of the enum. A line that fails any check is dropped without an
answer, so noise on the line, and whatever an operator typed before the
stop, draws no output.

* `read` with a length above `hold_read_max` is answered `length`.
* `read` of no bytes is answered `ok`, whatever its address: it only
  says the host is still there.
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
* `end` ends the hold at once.

The hold keeps no state between requests but the time of the last valid
one. After `hold_silence_s` (5) without a valid request it ends by
itself, so a machine nobody is reading holds for five seconds and no
longer. The host's tool sends a `read` of no bytes each second while it
has nothing to ask, so a session lasts as long as a tool is attached and
five seconds more. The hold has no request that writes, resumes or
changes a register, and no state a request could corrupt. What it writes
is its own: the leader's stack, the UART and, on Fiasco, the one
translation entry of its window.

**What it costs to read a board.** At 115,200 baud a reply of 4 KiB takes
about half a second, so a board yields about 8 KiB of memory a second
(an estimate from the line's rate and the frame's encoding): enough for
every CPU's stack, the trace rings' tails and the tables the report
walks, in about a minute, and not for a board's whole RAM. The tool reads
what a command needs and nothing else.

## The host's debugger

`tools/erx debug TARGET [COMMAND [ARGUMENT...]]` opens one target and
runs one command, `report` when none is given; with `-` for the command
it reads commands from standard input, one a line. `TARGET` is a file (a
crash record or a memory image, told apart by its first bytes),
`--tty DEVICE` or `--socket PATH` (a held board's console), `--stub PATH`
(a stub's UNIX socket) or `--replay DIRECTORY` (a recorded run). The tool
is Ruby host tooling, never runs on the target, and holds one target at a
time.

On a console (`--tty`, `--socket`) the tool is a plain terminal until the
machine stops: it carries the line's bytes both ways unchanged. When the
crash frame and `--erx-held` arrive, it takes the line for the hold's
frames.

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
the need named, never answered with a guess.

| Command | Shows | Needs |
| --- | --- | --- |
| `report` | the cause, message and build; each CPU's state and location, symbolized, and for `waiting` the lock and, with memory, the record the lock lies in; the leader's backtrace; with memory, every CPU's backtrace, the last records of each CPU's trace ring and of the log, and the audit's findings | CPUs |
| `cpus` | each CPU: number, state, program counter and symbol, stack pointer | CPUs |
| `regs [CPU]` | one CPU's registers | CPUs |
| `bt [CPU \| thread ID]` | a backtrace by frame pointers, bounded; a thread's starts from the saved context its walker names | CPUs; memory for more than the record's frames |
| `inspect PATH` | the record of an inspection path, as `tools/erx inspect` prints one; `*` in place of a variable segment gives every record of the listing | memory |
| `export DIRECTORY` | every path the walkers answer, each record in a file named by its path, in `inspect`'s text | memory |
| `log [N]`, `trace [N]` | the last lines of the kernel log; the last trace records of every CPU, merged by time, with a count wherever a ring's own reader rule says records were overwritten or half written | memory; the record's text serves `log` without it |
| `print TYPE ADDRESS`, `list TYPE ADDRESS FIELD [N]` | memory as a type of the bundle; a linked list of that type through that field, at most N nodes | memory |
| `mem ADDRESS LENGTH` | a hex dump, printable ASCII beside it and a dot for every other byte | memory |
| `whatis ADDRESS` | what an address is ([What an address is](#what-an-address-is)) | memory |
| `audit` | every row of every kind, checked against the schema ([The audit](#the-audit)) | memory |
| `save FILE` | every page read at the current moment, and the CPUs' registers, as a memory image ([Moments and images](#moments-and-images)) | memory |
| `stop`, `continue`, `detach` | stop or resume the whole machine; leave the stub | control |
| `break ADDRESS`, `watch ADDRESS LENGTH read\|write\|access`, `watch PATH ATTRIBUTE`, `delete N` | hardware breakpoints and watchpoints; the second form of `watch` is on the place a view read an attribute from | control |
| `now`, `at COUNT`, `back`, `when PATH ATTRIBUTE`, `when ADDRESS LENGTH` | the instruction count of this moment; move to a count; run backwards to the last break or watch; run backwards to the last write of an attribute or a range | time |
| `end` | end a held machine | a held board |

An address is a kernel virtual address, `p:` and a physical address, or a
space, a colon and a virtual address in that space, the space written as
`root` or as the path `inspect` shows it at. Output is text a pipeline
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
| `step array COUNT`, `step list LINK`, `step table FIRST LAST`, `step once` | how it goes from row to row |
| `only TYPE` | for an image in C++, keep the rows whose dynamic type is TYPE, read from the object's virtual table pointer against the image's symbols |
| `bound N` | the most rows it reads |
| `id FIELD` | the row's identifier in its path |
| `attr KEY REPORTER FIELD [as MAP]` | the field that holds an attribute, the reporter whose state it is, and for an enumeration the map from the image's values to the schema's atoms |
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
answer against the file. On a held board the tool saves before it ends
the machine without being asked, so the board's failure can be read again
after the board has rebooted.

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
interrupts. A hold's frames are printable ASCII lines, so a terminal that
shows the line sees text and nothing that moves its cursor. The hold is
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
hold. The card writer puts `erx.hold=1` on a card's command line only
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
rows of `fiasco/kernel/ORIGIN.md` and the edited ones as rows of its
`changes`, so no build can turn the debugger back on and no GPL file is
left among the kernel's sources. The `debug` and `log`
preprocessor parts, which only `CONFIG_JDB` adds (`src/Modules.arm`), go
with it, and with them every `[debug]` section of the files that stay.
Of `src/jabi/`, the trace ABI stays, since the kernel's counters use it
(`jdb_ktrace`, used by `src/kern/kern_cnt.cpp`). `CONFIG_RT_DBG` stays,
for the list that links every kernel object
(`Kobject_dbg::_kobjects`, `src/kern/kobject_dbg.cpp`), which is the
walkers' root for Fiasco's own objects; the modules it builds from
`src/jdb/` (`jdb_kobject`, `jdb_kobject_names`, `jdb_space`), and
`jabi`'s `jdb_obj_info`, leave with the rest if the build shows nothing
else needs them (unverified, P8), and
`CONFIG_JDB_KMEM_STATS`, whose only trigger was the object, is off.
`CONFIG_INPUT`, the kernel's console input, is forbidden in every build.
`LicenseCheck::TABLE` loses its `jdb_object.cpp` row.

**What enters.** The core `kernel/core/machine_stop.c`, in `erx_cores.a`
beside the crash core; one glue file,
`fiasco/kernel/src/erx/erx_machine_stop.cpp`, whose references into
Fiasco are lines of `fiasco/erx_glue_imports.txt`; and one option,
`CONFIG_ERX_HOLD`, which builds the hold. A development kernel is the
defconfig as it is; a release kernel is the same defconfig without that
option, its only difference (`FiascoConfig::RELEASE_UNSET`).

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
| the root's request for a reset after its own crash record, an argument of the platform control object's shutdown that names the cause (`kern/platform_control_object.cpp`) | resets | the stop from its census on, with no record of the kernel's: the root wrote one |

`Thread::system_abort` and the exit question go, since nothing reaches
them. The interrupted registers of a CPU that takes the stop request are
the interrupt entry's saved frame, which the entry already passes in its
first argument register (`kern/arm/64/ivt.S`) and which the glue keeps
per CPU while an interrupt is dispatched. Each CPU's panic stack is one
page the glue allocates for it, as the `debug` part allocated one for JDB
(`Thread::dbg_stack`, `kern/thread.cpp`). A stop before the kernel knows
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
is the one place the kernel reads its console UART. Its secondary CPUs'
start ends in the admission, and its console lock is the one the
leader's bounded take is tried on.

The ledger's row "Kernel debugger" keeps its answer, none, with its
reason, less code and less to attack in kernel mode, and gains what
stands in its place: the stop, the record and, in a development kernel,
the hold ([design-kernel.md](design-kernel.md#the-ledger)).

## Published images

The images the website offers are development builds of the same tree,
and their command lines carry no `erx.hold`: the card writer and the
site's image builder write the word only when asked, and the site build
refuses a medium whose command line holds it. A kernel stop on one writes
the full record on the console, which shows registers, a backtrace and
the log's last lines, already escaped, reads nothing, and resets.
Nobody at the console reaches kernel memory, and the images carry no GPL
kernel file. Their kernels do link the hold's code, as every development
kernel does; a release kernel links none
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
| the host falls silent, the cable is pulled, or the tool dies | the hold's silence bound | the record already printed, and what the tool had saved | the machine ends by itself |
| a request is damaged | its length, magic and CRC | the hold, unchanged | nothing: the tool sends it again |
| a reply is damaged | its CRC, at the tool | the hold | the tool asks again, and after three tries marks the range "not here" |
| a `read` outside RAM | the range check | the hold | `range`; the tool shows the address as not memory |
| a `read` inside the map faults | the claim's depth | what the tool had read and saved | `erx: nested stop`, and the machine ends; the tool names the address it had asked for |
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

**What the hold cannot do.** It reads RAM. It cannot write memory or a
register, read a device, resume the machine or run for longer than a host
keeps asking. Its one input is a fixed-size layout with a CRC, checked
whole before any field is used, and a line that fails is dropped with no
answer.

**Images and full records hold secrets.** A memory image holds everything
the machine held, and a full record may hold what the interrupted code
held in its registers. Images and saved moments stay in the run's log
directory on the host and never enter the repository; a release build
writes the brief record, which holds no register but the program counter
and no CPU entry.

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
| the hold's machine, exhaustive, on the host | over every state and event: a reply only to a line that passed every check; no reply to a damaged line; `range` for every range that leaves the map, over maps of one to 16 ranges and ranges that straddle, touch and wrap; the hold ends at `end` and at the silence bound and at no other time | the range check comparing the range's start alone; the silence clock restarted by a damaged line |
| the readable-RAM map, on the host | over boot maps the test builds: a virtual entry that spans every `ram` range changes nothing; an `excluded` entry inside a `ram` range splits it, rounded outward; overlapping and touching `ram` ranges join; a map of 17 ranges, an entry whose end overflows and a `used` entry that leaves the result are each refused, never cut; and over random maps, every page of the result lies in a `ram` entry and in no `excluded` one, and the result is sorted, disjoint and whole pages | the subtraction skipped: the interior exclusion is readable; a 17th range dropped without a refusal |
| Fiasco's classification, on the host | every descriptor type and sub-type of the kernel information page, physical and virtual, gets the class of [On Fiasco](#on-fiasco)'s table, and a value the table does not list is `excluded` | a virtual `Conventional` descriptor classed `ram`; the default changed to `ignored` |
| the hold decision | over every development flag, word, boot value, lease and watchdog state: a hold is allowed only when all five allow it; and over both verdicts on the map: a stop in an allowed boot holds only with a map that was not refused | the trial's refusal removed; the map's verdict ignored |
| the slot's publication, a litmus test at the milestone gate | a reader never sees a published state with stale registers | the state stored without release ordering |
| the crash core and its readers | records with CPU entries round-trip through `crash.c`, `crash_read.c` and `crash_frame.rb`, which agree case by case; the brief form carries no entry whatever the stop hands the writer | an entry with a state outside the enum accepted by one reader; entries copied into the brief form |
| the boot arguments' parser (`boot_args.c`) and the root's arming of the board's watchdog (`test/host/pm_wdt_test.rb`) | a release build refuses a boot whose command line carries `erx.hold=1`; the watchdog is armed in every boot but a deterministic one and one that may hold | the refusal removed; an attended boot armed |
| `native_machine_stop`, a QEMU cell on a development test kernel with a seeded panic on CPU 2 of 4, under TCG and HVF | one crash frame of cause `panic`, CPU 2 `leader` and the others `stopped`; the image's `report` symbolizes the leader's backtrace to the seeded function | the request's send removed: three `unanswered` |
| the same cell with CPU 1 waiting for a spinlock that CPU 3 holds, interrupts masked on both, CPU 3 spinning | CPU 1 `waiting` with the seeded lock's address, CPU 3 `unanswered`; the image shows CPU 3's program counter in the seeded loop, and `whatis` names the lock | the check removed from the wait loop: CPU 1 `unanswered` |
| the same cell with CPUs 1 and 2 panicking at once | one frame; one `leader`, one `concurrent` | the claim by a plain store: two frames |
| the same cell with CPU 3 held in its start until the census has ended, then released | the record gives CPU 3 as `offline`; no line of CPU 3's follows the crash frame; the image's slot for CPU 3 is `starting`, with its program counter in the admission | the admission's check removed: CPU 3's start-up lines follow the frame, and the image shows it in its idle loop |
| the same cell with CPU 3 held between its admission and its unmasking of interrupts while CPU 0 stops the machine | CPU 3 `stopped` | the CPU's bit set after it unmasks interrupts and not at its admission: CPU 3 is not in the leader's set, is not asked, and runs on |
| the same cell with CPU 3 printing in a loop with interrupts masked | CPU 3 `unanswered`; the report's first line names it and says whether the console's lock was taken; the harness's reader gives the crash frame whole or reports it damaged, never a record with another writer's bytes in it; the tool's report from the image is headed by its warning | the first line's statement removed; the reader's check of the frame skipped, so a damaged frame parses |
| the same cell with a fault seeded inside the record's writer | `erx: nested stop` and the end within the run's deadline | the depth check removed: the run never ends |
| the same cell on a release test kernel, whose test image's command line carries the word | the record, no `--erx-held`, no reply to the requests the harness sends after the frame, and a reset | the release kernel built with the hold, which the configuration check refuses before the cell runs |
| `native_hold`, the cell with `erx.hold=1`: the tool reads the held machine through the console's socket, then the harness takes QEMU's own image of the same stopped machine | every range the tool read is byte for byte the image's; every range of the anchor's map lies inside the RAM the image holds; a `read` of the UART's own register page, and one of an address that only the kernel information page's virtual descriptor covers, are answered `range`; the tool's `report` from the held machine equals its `report` from the image; after `end` the machine resets, and with no request it resets within the silence bound | the glue's window mapping the page before the one asked: the bytes differ; the range check removed: the register page is read; the virtual descriptor classed `ram`: the second `read` is answered, or faults |
| `native_ram_sweep`, a development test kernel that, once its map is built, reads one word of every page of the map through the hold's window and prints how many it read | the count is the map's number of pages, and the boot goes on to the root's first line | the sweep stepping two pages at a time: the count is half the map's |
| the same cell without the word | no `--erx-held`; requests sent after the frame draw no reply | the hold decision ignoring the word |
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
| the configuration check, and the source check of the hold's reader | no kernel's resolved configuration has `CONFIG_INPUT`; a release kernel's has no `CONFIG_ERX_HOLD`, and its build defines `UART_WITHOUT_INPUT`; in the fork's sources only the hold's glue names the UART library's `char_avail` and `get_char` | a resolved file with either option: refused; a second caller of `get_char`: the source check names it |
| the license audit | no kernel build, development or release, links a source under a license that is not permissive | compile records that name a source its import record gives as GPL-2.0-only: a development build is refused as a release build is |

**Fuzz targets**, each landing with its decoder: the hold's request line
(C, the core's: every line ends in a drop or one reply within its
bounds); the hold's reply frame and the crash frame's CPU entries in the
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
seeded panic holds, the tool's report names the seeded function, and the
board resets five seconds after the tool exits.

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

## Prior art

FreeBSD's KDB stops every CPU and runs a backend with a reason from a
closed list; its gdb(4) backend is a stub and kgdb reads cores on the
host. NetBSD's `crash(8)` runs ddb's commands on a live system or a dump.
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
| A prompt limited to memory-safe commands for published images, as `mac_ddb(4)` | the record already holds what such a prompt would show, and reading it needs no input path into the kernel |
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

1. **No kernel debugger on either kernel, and the hold in a development
   kernel.** The ledger's row "Kernel debugger"
   ([design-kernel.md](design-kernel.md#the-ledger)) reads none on either
   kernel, with the stop, the record and the hold in its place. The hold
   is code in kernel mode, in development kernels alone: a polled read of
   the console and a reader of RAM. Without it a board with no probe
   attached has its record and nothing else.
2. **Published images.** No image carries JDB or its GPL object, and a
   published image's stop prints its record and resets. The images the
   website offers are rebuilt and republished once the stop has landed;
   until then they are the builds [plan.md](plan.md#01-the-preview)
   describes, with JDB and its source offered.
3. **Where the work lands.** In 0.2, in the place of the release kernel's
   build without `jdb_object.cpp` and of the debugger's configuration
   check ([plan.md](plan.md)), in three parts that each land alone: the
   stop with its record and JDB's removal; the host's tool over records
   and images, with the harness's reports; the hold. Stubs, replay and
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
  repeated under HVF; and the same seed on the board.
* P8. Whether any Fiasco source outside `src/jdb/` needs `jdb_kobject`,
  `jdb_kobject_names`, `jdb_space` or `jabi`'s `jdb_obj_info` when
  `CONFIG_RT_DBG` stays on. Three files name their classes as friends
  (`kern/task.cpp`, `kern/space.cpp`, `kern/semaphore.cpp`), which needs
  no definition. Probe: the build.
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
