# erXos: An Operating System in Erlang

This file is the plan of a book: its title, its readers, the order of
its chapters and, for each chapter, what its sections explain, the
design documents they draw on and the figures they want. The chapters
themselves are written one at a time from this outline, each checked
against the design documents and the tree.

## What the book is

The design documents in [docs/](../) are contracts. Each states one
subsystem's invariants, interfaces, failure paths and tests, precisely
enough that an implementer can build it and a reviewer can check it, and
each assumes the reader already knows the rest of the system. They are
the wrong place to start. The book is the place to start: it tells the
whole system from the beginning, in the order a reader needs it, with
the reason for each choice next to the choice, and with every term
explained where it first appears.

The model is McKusick, Neville-Neil and Watson, *The Design and
Implementation of the FreeBSD Operating System* (2nd edition,
Addison-Wesley, 2014). The book borrows its arc and its manner, not its
text: an opening part of background, then a part on history, goals and
the overall design; then processes, memory, the I/O system,
communication and the operation of the running system; each chapter
opening with the concepts and the terms, then the structures that carry them, then how they behave and
fail.

### Readers

* Programmers who know UNIX, as a user and a little from the inside, and
  want to know what an operating system built around Erlang looks like.
* Erlang programmers who want to know what happens below the runtime when
  every Erlang process is the operating system's process.
* Students and researchers of operating systems, for the design choices:
  a capability microkernel under a language runtime, two-level
  scheduling, drivers as supervised processes, and a system whose
  properties are designed to hold by construction.
* People who will work on erXos, as the reading that comes before the
  design documents.

The book assumes a reader who can program, in any language, and may know
little about operating systems, microkernels or Erlang. It does not
assume C, Erlang, L4, Plan 9 or OTP's internals. Every term is explained
where it first appears: in Part I for the three subjects everything
rests on, and in a Background box at the head of the chapter that first
needs anything more specialised (DMA, TCP, USB, WiFi and the like). The
glossary, Appendix A, lists every such term and points to where it is
explained.

**Reading paths.**

* No background: read in order, from chapter 1.
* Knows operating systems but not microkernels or Erlang: chapters 2 and
  3, then from chapter 4.
* Knows Erlang and OTP but not operating systems: chapters 1 and 2, the
  rest of chapter 3 only for ERTS (section 5), then from chapter 4.
* Knows operating systems and Erlang, new to L4 and capabilities: chapter
  2, then from chapter 4.
* Knows all three: from chapter 4. A term met on the way is linked to its
  chapter or Background box.
* Wants one thread: each chapter's "Background needed" line names what
  it builds on, so the network (chapters 17 to 19), the display (22) or
  startup (24) can be read after the chapters named there.

### Built and designed

The book describes erXos as it is today, running on the Fiasco
microkernel behind erXos's kernel interface, and, where the design is
not yet built, as it is designed to be on that system. The design
documents describe the whole design. The book describes both what runs
and what is designed, and never presents the second as the first.
Every chapter carries a status box, and every passage about something
designed and not built says so in its own sentence. The box uses two
marks:

| Mark | Meaning |
| --- | --- |
| **Built** | works in the tree today, in a QEMU suite, on the board or in host tests, as [the top-level README, Current status](../../README.md#current-status) and the code show it |
| **Designed** | specified in the design documents and not implemented |

The outline's marks are what README.md's "Current status" says; the
writer of each chapter checks them again against the tree before
writing. When "Current status" changes, the status boxes of the
chapters it touches are checked again in the same change.

## Preface: why this order

The book runs from overview through processes, the I/O system and
communication to system operation. Five choices of order follow from
erXos's structure or from its readers.

1. **Background comes first.** The book does not assume that its
   reader knows what a kernel, a page table and a system call are: its
   readers include programmers who have never opened an
   operating system and Erlang programmers who have never met a
   microkernel. Part I (chapters 1 to 3) therefore teaches, from the
   ground up and with no erXos in it, the three subjects every later
   chapter leans on: operating systems, microkernels and capabilities,
   and Erlang with OTP. A reader who knows one of them skips its chapter,
   and the reading paths above say which. What only one chapter needs
   (DMA and cache coherence for devices, TCP for the network stack, the
   handshake of WiFi) is not in Part I: it opens that chapter, in a set
   apart Background box, so it is read where it is used. Each chapter
   begins with a "Background needed" line naming the chapters and boxes
   it builds on. The alternatives were worse: an appendix of background
   is not read before the chapters that need it, and boxes alone would
   repeat three large subjects in every chapter.
2. **Method comes early.** Two chapters of Part II (6 and 7) explain how
   erXos is designed before any subsystem is: decisions as pure
   functions and effects at the edge, properties that hold by
   construction instead of by a list of cases, rules of the form "only X
   may do Y" as build checks, and one declared source for every shared
   fact, from which C, Erlang and Ruby are generated. Every later
   chapter uses these ideas (the device DMA plan of chapter 15 is a
   plan validated whole; the kernel calls of chapter 8 are generated),
   so the reader meets them once, with small examples, and then sees
   them recur.
3. **The domain comes before memory.** In erXos the Erlang process is
   the unit of execution and failure, and the domain, a group of
   processes behind an address space, is the unit of protection. So
   Part III goes process and scheduler, then domains, then authority and
   security, then memory and budgets, then native programs, which are
   ports of a session and make sense only once domains and authority do.
4. **The user's machine is a part of its own.** The shell, the live
   machine, the display and apps are not utilities on top of the system:
   each is a service built from the pieces of Parts III to V (domains,
   facets, file trees, pure cores), and each shows one of erXos's
   distinctive ideas (UNIX tools over live Erlang state, a machine you
   can inspect while it runs, one interface rendered natively by every
   display). They come after the parts they are built from and before
   system operation.
5. **Checking comes last.** How erXos knows it is right (OTP's own
   suites, musl's tests, fuzz targets, model checking,
   seeded faults, reproducible and deterministic boots) draws on every
   chapter, so it closes Part VII.

Kernel services are chapter 8, the kernel interface, because in erXos
the kernel's services are exactly its interface: everything else runs
in user mode.

## Conventions

* Every chapter follows the prose guide, [style.md](style.md): its voice,
  the shape of a chapter, background for newcomers, honesty about what is
  built, and the checklist each writer runs before committing.
* Each chapter is a file in this directory, in GitHub Flavored
  Markdown, its figures Mermaid where GitHub renders it and text diagrams
  otherwise, as [Decisions](#decisions) settles. The file name is the
  two-digit chapter number and a short slug, `NN-slug.md`; the
  appendices are `a-slug.md` to `e-slug.md`.
  The table below is the one list of names.
* A link from one chapter to another is a relative link to the file, with
  a section anchor where the chapter has one (`10-domains.md#103-...`). A
  chapter that is not yet written is linked to its outline section in
  this file (`README.md#chapter-10-domains-a-wall-around-some-processes`),
  and the link changes to the file when the chapter lands.
* Each chapter cites the design documents by relative link and section,
  and the tree by path. It explains; it decides nothing. When a chapter
  and a design document disagree, the design document is right and the
  chapter is fixed.
* Plain language: the concrete file, call or check, and a term explained
  where it first appears and listed in the glossary, Appendix A, with a
  pointer to where it is explained. A term of operating systems,
  microkernels or Erlang is explained in Part I or in the Background box
  of the chapter that first needs it; a chapter never uses such a term
  unexplained, and never assumes that the reader met it elsewhere. UNIX
  in capitals; "license".
* Each chapter opens with a "Background needed" line, naming the earlier
  chapters and boxes it depends on, so a reader can follow one thread
  (the network, say) without reading all that comes before. Its
  "Background boxes" are short titled passages, set apart, that explain
  a concept before the chapter first uses it; the outline lists them.
* Present tense throughout. Whether a thing is built is said in the
  chapter's status box and in the sentence that describes it.

| Chapter | Title | File |
|---|---|---|
| 1 | Operating Systems from the Ground Up | `01-operating-systems.md` |
| 2 | Microkernels and Capabilities | `02-microkernels.md` |
| 3 | Erlang and OTP | `03-erlang.md` |
| 4 | History and Goals | `04-history.md` |
| 5 | Design Overview of erXos | `05-overview.md` |
| 6 | Correct by Construction | `06-construction.md` |
| 7 | One Source for Every Fact | `07-one-source.md` |
| 8 | The Kernel Interface and Fiasco | `08-kernel-interface.md` |
| 9 | Processes, Runtimes and Two-Level Scheduling | `09-processes.md` |
| 10 | Domains: A Wall Around Some Processes | `10-domains.md` |
| 11 | Authority and Security | `11-security.md` |
| 12 | Memory and Budgets | `12-memory.md` |
| 13 | Native Programs, Pipes and POSIX-lite | `13-native-programs.md` |
| 14 | Files, Namespaces and Service Trees | `14-files.md` |
| 15 | Devices and Drivers | `15-devices.md` |
| 16 | Storage and Updates | `16-storage.md` |
| 17 | The Network Stack | `17-network.md` |
| 18 | WiFi | `18-wifi.md` |
| 19 | Bluetooth | `19-bluetooth.md` |
| 20 | The Command Shell and the UNIX Surface | `20-shell.md` |
| 21 | The Live Machine | `21-live-machine.md` |
| 22 | Displays, Windows and the Web | `22-display.md` |
| 23 | Apps and Packages | `23-apps.md` |
| 24 | Startup, Configuration and Shutdown | `24-startup.md` |
| 25 | Checking the System | `25-checking.md` |
| Appendix A | Glossary | `a-glossary.md` |
| Appendix B | Reading the Design Documents | `b-design-documents.md` |
| Appendix C | Building and Booting erXos | `c-building.md` |
| Appendix D | Dependencies and Licenses | `d-dependencies.md` |
| Appendix E | Lineage | `e-lineage.md` |

## Contents

**Part I. Background**

1. [Operating Systems from the Ground Up](#chapter-1-operating-systems-from-the-ground-up)
2. [Microkernels and Capabilities](#chapter-2-microkernels-and-capabilities)
3. [Erlang and OTP](#chapter-3-erlang-and-otp)

**Part II. Overview**

4. [History and Goals](#chapter-4-history-and-goals)
5. [Design Overview of erXos](#chapter-5-design-overview-of-erxos)
6. [Correct by Construction](#chapter-6-correct-by-construction)
7. [One Source for Every Fact](#chapter-7-one-source-for-every-fact)
8. [The Kernel Interface and Fiasco](#chapter-8-the-kernel-interface-and-fiasco)

**Part III. Processes**

9. [Processes, Runtimes and Two-Level Scheduling](#chapter-9-processes-runtimes-and-two-level-scheduling)
10. [Domains: A Wall Around Some Processes](#chapter-10-domains-a-wall-around-some-processes)
11. [Authority and Security](#chapter-11-authority-and-security)
12. [Memory and Budgets](#chapter-12-memory-and-budgets)
13. [Native Programs, Pipes and POSIX-lite](#chapter-13-native-programs-pipes-and-posix-lite)

**Part IV. The I/O System**

14. [Files, Namespaces and Service Trees](#chapter-14-files-namespaces-and-service-trees)
15. [Devices and Drivers](#chapter-15-devices-and-drivers)
16. [Storage and Updates](#chapter-16-storage-and-updates)

**Part V. Communication**

17. [The Network Stack](#chapter-17-the-network-stack)
18. [WiFi](#chapter-18-wifi)
19. [Bluetooth](#chapter-19-bluetooth)

**Part VI. The User's Machine**

20. [The Command Shell and the UNIX Surface](#chapter-20-the-command-shell-and-the-unix-surface)
21. [The Live Machine](#chapter-21-the-live-machine)
22. [Displays, Windows and the Web](#chapter-22-displays-windows-and-the-web)
23. [Apps and Packages](#chapter-23-apps-and-packages)

**Part VII. System Operation**

24. [Startup, Configuration and Shutdown](#chapter-24-startup-configuration-and-shutdown)
25. [Checking the System](#chapter-25-checking-the-system)

**Appendices.** [A. Glossary](#appendix-a-glossary),
[B. Reading the Design Documents](#appendix-b-reading-the-design-documents),
[C. Building and Booting erXos](#appendix-c-building-and-booting-erxos),
[D. Dependencies and Licenses](#appendix-d-dependencies-and-licenses),
[E. Lineage](#appendix-e-lineage)

About 710 pages in all, at about 400 words a page.

---

## Part I. Background

The three chapters of this part teach what the rest of the book takes for
granted, to a reader who can program and may know little about operating
systems, microkernels or Erlang. They describe systems in general; erXos
appears only where a chapter says that it does. Each is written to be
skipped by a reader who already knows its subject (see the reading
paths in [Readers](#readers)).

### Chapter 1. Operating Systems from the Ground Up

*About 27 pages.* What an operating system is for and how one works:
the kernel, the two modes of the processor, processes, virtual memory,
files, devices and the boundary between a program and the machine.

**Background needed.** None. This is where the book starts; it assumes
only that the reader can program.

**Status.** Background: no mark. Chapters 2 and 3 do the same for
microkernels and for Erlang; the chapters after them say what erXos does.

1. **What an operating system is for.** Sharing one machine among many
   programs, hiding the hardware behind a few simple ideas (a file, a
   process, an address space), and keeping programs from harming each
   other. The kernel, the programs, the libraries and the services, and
   which of them run with what power.
   *Draws on:* [overview.md](../overview.md),
   [design.md, The model](../design.md#the-model).
2. **The processor's two modes, and the way across.** User mode and
   kernel mode, why a program cannot touch the hardware directly, and the
   three ways into the kernel: a system call, an exception such as a page
   fault, and an interrupt. The timer interrupt and preemption. The
   names an architecture gives its modes (AArch64's exception levels) in
   one paragraph. Subsections: 1.2.1 three ways into the kernel; 1.2.2 a
   system call from start to finish; 1.2.3 the timer; 1.2.4 protection
   without modes (language-based safety as the alternative); 1.2.5 the
   modes on AArch64.
   *Draws on:* [design-arch-aarch64.md](../design-arch-aarch64.md).
3. **Processes, threads and scheduling.** What a process and a thread
   are, the context switch, run queues, priorities and fairness, and
   cooperative against preemptive scheduling. Subsections 1.3.1 to 1.3.5
   follow that order; 1.3.6 How a process ends covers exit, reaping and
   what the kernel reclaims.
   *Draws on:* [design-scheduler.md](../design-scheduler.md).
4. **Virtual memory.** Address spaces, pages, page tables and the TLB, a
   page fault walked step by step, demand paging, copy-on-write,
   memory-mapped files, and protection bits including
   writable-or-executable. Subsection 1.4.7 Who pays for memory:
   overcommit, running out of memory, and charging every page to an account.
   *Draws on:* [design-kernel.md](../design-kernel.md).
5. **Devices, interrupts, DMA and caches.** Memory-mapped registers,
   device interrupts and the interrupt controller, drivers, direct memory
   access, why a cache can hide a device's write from the processor and
   what an IOMMU does about a device that writes where it should not.
   Subsection 1.5.6 Finding the devices: device trees and bus
   enumeration.
   *Draws on:* [design-device-dma.md](../design-device-dma.md).
6. **Files and block devices.** The file as the central abstraction, file
   systems on block devices, directories, mounting, and what a path
   names. Subsection 1.6.5 Permissions, and the power of a user.
   *Draws on:* [design-files.md](../design-files.md).
7. **Talking and sharing.** Locks, atomic operations and memory ordering
   in one page; pipes, sockets and messages; shared memory.
   *Draws on:* [design-pipes.md](../design-pipes.md).
8. **From power-on to the first program.** Firmware, a boot loader, the
   kernel and the first user program.
   *Draws on:* [design-platforms.md](../design-platforms.md).
9. **When a part fails.** What a crashing program, a kernel panic and a
   device that writes where it should not each cost in a conventional
   system: where the line between kernel mode and user mode runs decides
   how far a failure reaches, which the later chapters answer. A summary
   (1.10) and where to read next (1.11) close the chapter.

**Background boxes.** None: the chapter is the background.
*Further reading* (the chapter's writer checks each citation): Ritchie and
Thompson, "The UNIX Time-Sharing System" (1974); McKusick, Neville-Neil
and Watson, *The Design and Implementation of the FreeBSD Operating
System*.

**Figures.** 1.1: the layers of a computer, from hardware to a program.
1.2: a system call from a program into the kernel and back. 1.3: a
virtual address translated through a page table. 1.4: a device's DMA
write with and without a cache that is coherent with it.

### Chapter 2. Microkernels and Capabilities

*About 18 pages.* The design family erXos belongs to: a kernel that does
as little as it can, services in user mode, and authority held as
unforgeable references.

**Background needed.** Chapter 1 (kernel and user mode, address spaces,
system calls).

**Status.** Background: no mark. The sentences that say what erXos takes
from L4 and Fiasco are in chapter 8.

1. **Monolithic kernels and microkernels.** What a monolithic kernel
   holds (file systems, network stack, drivers), what a microkernel
   leaves out, and the trade: isolation of a failing driver against the
   cost of crossing between servers. Mach, QNX, MINIX and the L4 family
   as examples.
   *Draws on:* [research-kernel-bases.md](../research-kernel-bases.md).
2. **Inter-process communication.** Synchronous message passing between
   address spaces, the rendezvous, why L4 made it fast, shared memory
   beside it, and a file or network server as a user-mode process that
   clients call.
   *Draws on:* [design-kernel.md](../design-kernel.md).
3. **Capabilities.** An unforgeable reference to an object together with
   the rights to use it; ambient authority (a user id, a path anyone can
   open) against held authority; the confused deputy; delegation,
   rights that only shrink, and revocation. KeyKOS, EROS, seL4, Zircon
   and Capsicum as examples.
   *Draws on:* [research-prior-art.md](../research-prior-art.md).
4. **Security by construction.** What a trusted computing base is, why
   a small one is checkable, and how a design where every access goes
   through a capability makes whole classes of mistake impossible to
   write, which is the idea the rest of the book returns to.
   *Draws on:* [design.md, The model](../design.md#the-model).
5. **The L4 family and Fiasco.** L4 and its descendants, Fiasco and L4Re,
   the root task that creates every kernel object, and why erXos runs
   on Fiasco.
   *Draws on:* [design-fiasco.md](../design-fiasco.md).
6. **What fails, and what a failure reaches.** A microkernel does not stop
   servers from failing; it changes what a failure reaches, from the whole
   machine to one address space, and what stays unprotected.
7. **Design choices.** The alternatives to a microkernel with
   capabilities (a hardened monolithic kernel, protection by language,
   access lists) and why erXos does not take them. A summary and where
   to read next close the chapter.

**Background boxes.** None: the chapter is the background.
*Further reading* (the chapter's writer checks each citation): Liedtke,
"On micro-kernel construction" (1995); Dennis and Van Horn, "Programming
Semantics for Multiprogrammed Computations" (1966); Saltzer and
Schroeder, "The Protection of Information in Computer Systems" (1975);
Elphinstone and Heiser, "From L3 to seL4: What Have We Learnt in 20
Years of L4 Microkernels?" (2013); Hardy, "The Confused Deputy" (1988);
Shapiro, Smith and Farber, "EROS: A Fast Capability System" (SOSP 1999);
the FreeBSD manual page capsicum(4).

**Figures.** 2.1: a monolithic kernel and a microkernel with servers,
side by side, showing what a driver's bug reaches in each. 2.2: a client calling a server by IPC. 2.3: a capability
as a slot in a table, with its rights. 2.4: the confused deputy with an
access list and with capabilities.

### Chapter 3. Erlang and OTP

*About 23 pages.* Enough Erlang to read the rest of the book: the
language, processes and messages, failure handled by supervisors, OTP's
behaviours, and the virtual machine that runs it.

**Background needed.** Chapter 1 (processes, scheduling); no Erlang.

**Status.** Background: no mark. A reader fluent in Erlang and OTP skips
to section 5, the BEAM and ERTS, which is what erXos takes apart.

1. **The language in a sitting.** Terms (numbers, atoms, tuples, lists,
   maps, binaries), pattern matching, immutable data, functions and
   modules, recursion in place of loops, and the book's notation for
   specs and records.
   *Draws on:* [style.md](../style.md).
2. **Processes and messages.** Lightweight processes, mailboxes,
   `spawn`, `!` and `receive`, selective receive, process identifiers and
   registered names, and why nothing is shared.
   *Draws on:* [design-runtime.md](../design-runtime.md).
3. **Let it crash.** Links and exit signals, monitors, trapping exits,
   supervisors, restart strategies and supervision trees: why a process
   that meets the unexpected stops and its supervisor starts it again.
   *Draws on:* [design-runtime.md](../design-runtime.md).
4. **OTP behaviours.** `gen_server`, `gen_statem`, `supervisor`,
   `application` and releases: a callback module around a generic
   process, and what each behaviour saves the programmer from writing.
   *Draws on:* [design-runtime.md](../design-runtime.md).
5. **The BEAM and ERTS.** Bytecode and the JIT (BeamAsm), one scheduler
   per processor, reductions, a heap and garbage collection per process,
   ports, NIFs and built-in functions, and the atom table.
   *Draws on:* [research-erts-internals.md](../research-erts-internals.md).
6. **Code loading and distribution.** Two versions of a module at once,
   hot code loading, nodes, node names and cookies, and how a message
   crosses between nodes, which chapter 10 reuses across a domain's wall.
   *Draws on:* [design-runtime.md](../design-runtime.md).
7. **Looking at a running system.** Tracing, the shell, and the tools an
   Erlang programmer uses, as the baseline that chapter 21 extends to
   the whole machine.
   *Draws on:* [design-live.md](../design-live.md).
8. **Where the model stops.** What Erlang's isolation does not give on a
   stock system: native code, one shared memory, the atom table, shared
   stores, distribution with a cookie, and CPU time.
9. **How erXos uses these ideas.** Every Erlang process an operating-system
   process; distribution across a domain's wall; supervisors all the way
   down; a functional core with a behaviour at the edge; ERTS as a parts
   bin; hot code loading with a hash; and the chapter's ideas at a
   glance. A summary and where to read next close the chapter.

**Background boxes.** None: the chapter is the background.
*Further reading* (the chapter's writer checks each citation): Armstrong,
"Making Reliable Distributed Systems in the Presence of Software Errors"
(2003); the OTP documentation shipped with the tree.

**Figures.** 3.1: a process and its mailbox. 3.2: a supervision tree and
one restart. 3.3: the BEAM inside one operating-system process:
schedulers on threads, processes on schedulers. 3.4: one message between
domains.

---

## Part II. Overview

### Chapter 4. History and Goals

*About 13 pages.* Why build an operating system around Erlang, what erXos
takes from earlier systems, and the goals and principles that shape it.

**Background needed.** Chapters 1 to 3, for the terms; a reader who
knows operating systems, microkernels and Erlang starts here.

**Background boxes.** None; each term of Part I is linked to its chapter
at first use.

**Status.** History, goals and principles: no mark. What runs today:
Built, as README.md's "Current status" records it.

1. **Erlang systems already behave like operating systems.** Millions of
   isolated processes, preemptive scheduling, failure handled by links
   and supervisors, code replaced while running: all of it inside one
   process of another system, which sees none of it. The section states
   the problem erXos starts from: make the Erlang process the system's
   process, and draw hardware protection around groups of processes only
   where trust requires it.
   *Draws on:* [design.md, Context](../design.md#context),
   [overview.md](../overview.md#why-build-an-operating-system-around-erlang).
2. **Thirty years of two-level scheduling.** Scheduler activations, KSE,
   Solaris M:N threads and Windows user-mode scheduling all tried to let a
   user-level scheduler run on kernel threads, and all were abandoned.
   The section explains their common failure (a kernel re-entering user
   code at arbitrary points, for C code that may block anywhere) and the
   two facts that let erXos keep two levels: its runtimes are few and its
   own, and Erlang processes never block a thread.
   *Draws on:* [research-hierarchical-scheduling.md](../research-hierarchical-scheduling.md),
   [design.md, Context](../design.md#context).
3. **The lineage.** Four subsections give the sources that shaped erXos
   most: UNIX and FreeBSD for the surface; L4 and Fiasco for the kernel;
   Plan 9 for names and files; EROS, Safe Erlang and Zircon for authority
   and payment (EROS's space banks, pids as capabilities, no ambient
   authority). A table (4.1) lists the rest with the idea each gave:
   QNX, Genera, Inferno, Singularity, SPIN, Midori, Genode and Barrelfish. Section 4.1.4 adds the earlier
   attempts to run Erlang below the
   application (Nerves, GRiSP, LING, HydrOS) and the gap they leave.
   *Draws on:* [research-prior-art.md](../research-prior-art.md),
   [README.md, Architecture](../../README.md#architecture).
4. **Goals and non-goals.** The nine functional requirements (run OTP
   applications unmodified, protection, one system, generic runtimes, a
   live machine, Erlang drivers, users, storage and networking, UNIX
   programs where they pay) and the non-functional ones (performance
   within 1.2 times ERTS on a conventional system inside a domain, security on equal footing
   with correctness, reproducible images, portability). The non-goals
   matter as much: POSIX is a personality, never the base; no Linux
   binaries; no confidentiality between processes of one domain.
   *Draws on:* [design.md, Requirements](../design.md#requirements).
5. **Five principles.** Erlang wherever practical; erXos owns OTP and
   changes it freely; simplicity; declarative where it simplifies; UNIX
   look and feel, honestly, with no skeuomorphism (nothing wears the name
   or shape of something it is not). The section shows each principle at
   work in one concrete choice that later chapters return to.
   *Draws on:* [design.md, Decisions](../design.md#decisions),
   [overview.md](../overview.md).
6. **What runs today.** A short account of the system as it runs: on
   QEMU `virt` and the Raspberry Pi 4, on Fiasco, with the kiosk, the
   command shell over SSH and native programs, and what in the rest of
   the book is designed and not built. No release names.
   *Draws on:* [README.md, Current status](../../README.md#current-status).
7. **What the approach costs, and how it fails.** A runtime per domain
   costs memory, the system domain is critical, device isolation needs
   hardware, and the system's isolation rests on Fiasco and on the root
   service. A summary and where to read next close the chapter.

**Figures.** 4.1: the lineage as a timeline: UNIX, L4, EROS, Plan 9,
Erlang/OTP and the other sources of section 3, each with the idea erXos
took from it.

### Chapter 5. Design Overview of erXos

*About 18 pages.* The whole system in one chapter: seven concepts, what
runs where, and a day in the life of the machine.

**Background needed.** Chapters 1 to 4.

**Background boxes.** Reading a sequence diagram, as the day in the life
uses one. What a boot image, a manifest and a package are, one paragraph
each, before the chapter names them.

**Status.** Built: a machine boots on Fiasco into the system domain,
which starts the storage, network and display domains and logs root in
at the console; shell commands and a pipeline of a native program and
Erlang commands; the system's state under `/proc`; inspecting any
process; creating a domain and seeing a link report its end; memory and
threads held as records, and ending a domain ends everything charged to
it. Designed: memory limits that refuse a domain more, CPU limits per
domain, rights on handles checked on every use, a login that gives each person a domain of their own, and
toybox's UNIX programs in the session's `/bin`.

1. **Seven concepts, each with one owner.** Process, domain, runtime,
   group, budget, capability and export, principal: what each is, who
   owns it, and why each has exactly one owner. The section opens with
   one process and the seven questions it answers. It defines the terms
   the rest of the book uses (connection, executor, own and outer
   budget, handle and generation, export table, session template,
   session, package) in plain words, as a reader's map.
   *Draws on:* [design.md, The model](../design.md#the-model).
2. **What runs where.** Fiasco, the only code in kernel mode, and
   everything else in user mode: the system domain (the root task, its
   root service, domain library and system services), Erlang domains,
   driver domains, and native programs in sub-spaces of a session. For
   each: what it runs, who trusts it, and what a failure reaches, from
   "the domain dies and links fire" to "the machine resets".
   *Draws on:* [design.md, Overview](../design.md#overview),
   [design.md, Trust placement](../design.md#trust-placement).
3. **A day in the life.** The machine boots, the system domain starts the
   domains the system manifest lists, a session starts, a process sends
   to a service through a facet, a domain crashes and a link reports it,
   and `find /tmp -type f | wc -l` runs a native program and an Erlang
   command in one pipeline. Each step names the chapter that explains it
   and whether it is built or designed.
   *Draws on:* [design.md, Overview](../design.md#overview).
4. **Signature experiences.** What a person can do on erXos that a
   conventional system does not offer: the shell is the operating
   system; the machine is an object you edit; a driver is a process,
   killed and restarted; a wall around some processes; UNIX tools over
   live Erlang state; a user with a domain of their own (Designed). Each
   is shown as a short transcript or sketch, marked built or designed.
   *Draws on:* [design.md, Signature experiences](../design.md#signature-experiences),
   [DEMOS.md](../../DEMOS.md).
5. **Four decisions every chapter assumes.** `liberx` is the only
   issuer of kernel calls; every domain is a node; system code is
   Erlang, drivers included; formats are erXos's own. Each with its
   one-line reason.
   *Draws on:* [design.md, Decisions](../design.md#decisions).
6. **Tensions and alternatives.** Where the design pulls against itself
   (performance against isolation, Erlang against C, a trusted base
   above the kernel, a familiar surface over a different model, shared
   services and shared CPU) and the large alternatives rejected: Linux
   underneath, POSIX as the base, one runtime for the whole machine, a
   verifier instead of hardware protection.
   *Draws on:* [design.md, Tensions](../design.md#tensions),
   [design.md, Alternatives considered](../design.md#alternatives-considered),
   [design.md, Why no verifier](../design.md#why-no-verifier).

**Figures.** 5.1: the layer diagram of [design.md,
Overview](../design.md#overview), redrawn: domains, sub-spaces,
connections, the system domain, the kernel. 5.2: the seven concepts and
their owners as a table-diagram. 5.3: the day in the life as a sequence
diagram, each step tagged with its chapter and status.

### Chapter 6. Correct by Construction

*About 18 pages.* How erXos is designed: properties that hold because the
wrong state cannot be written, not because every case was remembered.

**Background needed.** Chapters 1 to 3 (chapter 1 for DMA and caches,
chapter 2 for capabilities, chapter 3 for Erlang).

**Background boxes.** Pure functions and side effects, with an Erlang
example. Model checking, fuzzing and static checks in a paragraph each.
Why a device's write can bypass a cache, enough for the worked example;
chapter 15 explains it in full.

**Status.** The method is Built and runs through the tree: pure Erlang
cores that return `{State, Actions}`, with edges that perform the
actions; the device NIF's pure cores, the independent check of every
plan and the one effect loop; the funnel; the chokepoint build checks,
each with a seeded violation; and the stack proof of the C17 code that
Fiasco links. Of the properties in section 6.2, three are Designed: the
memory wall of a domain's budget, Fiasco's refusal of a mapping that is
writable and executable at once, and rights on handles checked on
every use. The rest are Built, with the limits the
chapter states.

1. **Open-ended enumeration is the smell.** A correctness argument that
   depends on remembering every caller, path or exception breaks with the
   next caller. The section works through the two questions that replace
   such a list ("what is this list protecting?" and "what would make the
   list empty?") and the three ways out: make the illegal state
   unrepresentable, make the invariant a derived fact nothing can
   destroy, make one funnel the only way to the operation.
   *Draws on:* [design.md, Invariants](../design.md#invariants),
   [design.md, Correct by construction in code](../design.md#correct-by-construction-in-code).
2. **The properties erXos holds by construction.** A tour of the list
   as it holds on Fiasco: only the root service creates kernel objects;
   a destroyed object's handles, and a handle used after its own
   close, answer `ERX_ESTALE` and never name a successor; a domain's memory is charged to its own budget, and the wall
   that refuses a charge past it is Designed; a pid is a name, not an
   authority; no process acts on a message from another domain that its
   protocol's owner did not admit; every layer agrees on the ABI because
   all are generated from one file; the root service refuses a mapping
   that is writable and executable at once, and Fiasco's own refusal of
   one is Designed. For each, the one mechanism that makes it hold, and
   the chapter that shows it.
   *Draws on:* [design.md, Invariants](../design.md#invariants),
   [design-fiasco.md, Contract](../design-fiasco.md#contract),
   [design-domains.md, Invariants](../design-domains.md#invariants).
3. **Functional core, effects at the edge.** Every decision that can be a
   pure function is one: a state machine that returns the next state and
   a list of actions, a plan validated whole before anything is applied.
   The section shows the shape in C and in Erlang, why the opposite
   shape, a caller stringing helpers together in the right order, keeps
   producing sequencing bugs, and why variants beat flags.
   *Draws on:* [design.md, Functional core, effects at the edge](../design.md#functional-core-effects-at-the-edge),
   [style.md, Functional core](../style.md#functional-core).
4. **A worked example: the device DMA plan.** A preview of chapter 15. A
   driver's C part never pokes a device freely: its pure core, a form
   for each kind of device, produces a plan, and one independent check
   reads the whole plan before anything touches the hardware. Every
   device address stays inside the queue's DMA memory, and no region
   ever has two writers. Cache maintenance and barriers are derived from
   the plan by one effect loop, so no driver can forget one, and a build
   check keeps them there.
   *Draws on:* [design-device-dma.md, Calls, observations and plans](../design-device-dma.md#calls-observations-and-plans).
5. **What construction cannot say.** A structure proves where an
   operation can be done from, not that the code allowed to do it does
   it only when it should. Model checking, litmus tests, CBMC and fuzz
   targets cover the rest, and seeded faults prove each check catches
   what it guards.
   *Draws on:* [design-verification.md](../design-verification.md).
6. **Only X may do Y: chokepoints as build checks.** A rule such as "only
   the device shim touches a device's registers" or "only `liberx`
   issues kernel calls" is a check that fails the build on a new site,
   and each check has a test that plants a violation and expects the
   failure. The section explains why a type or visibility boundary comes
   first (opaque types, `static` functions, unexported Erlang functions)
   and a chokepoint check covers only what such a boundary cannot say.
   *Draws on:* [design.md, Chokepoint checks](../design.md#chokepoint-checks),
   `tools/lib/erx/chokepoint_rules/`.
7. **Bounded stacks.** The C17 code erXos links into Fiasco recurses
   only through tail calls the compiler must turn into jumps, and each
   build computes its worst-case stack depth from the call graph.
   Parsers outside the kernel bound their depth too.
   *Draws on:* [design.md, Bounded stacks](../design.md#bounded-stacks).
8. **One interface below every runtime.** Every runtime and program
   reaches the kernel through `liberx`, every shared format is erXos's
   own, and none of Fiasco's data model reaches Erlang code or a user,
   so a component below the interface can change without anything above
   it moving.
   *Draws on:* [design.md, Decisions](../design.md#decisions).
9. **When a construction fails, and the choices.** What each failure
   looks like (a chokepoint violation, a stack proof failure, a refused
   DMA plan, a core that acts after stopping, a malformed frame), the
   failures construction does not prevent, and the alternatives:
   careful review, checks at run time everywhere, a verified kernel, a
   language that enforces more.

**Figures.** 6.1: a pure core and its effect loop: request in, either
"observe these reads" or "decide: this plan and the next state", the
effect loop performing reads or the checked plan. 6.2: the "by
construction" list as a table of property, mechanism and chapter. 6.3: a chokepoint check with its seeded
violation.

### Chapter 7. One Source for Every Fact

*About 13 pages.* Declarative description in erXos: facts stated once,
and everything that follows from them generated or checked.

**Background needed.** Chapter 6; chapter 3 for Erlang terms.

**Background boxes.** What an application binary interface is and why
two languages must agree on one. Code generation from a specification,
against writing the same table twice. Datalog in a page: facts, rules,
queries. How a chip vendor describes registers (CMSIS-SVD).

**Status.** Built: the ABI file and its generators; register accessors
generated from the hardware sources; the theme and its contrast rules;
the errno and signal tables; the system manifest and its build-time
check; the declared services and inspection schema. Designed: the ABI
file declaring every kernel call (it declares one); budgets that refuse
a charge at run time; per-domain CPU limits; the ADMA2 descriptor form
for the SD controller.

1. **Parallel copies, and the rule that replaces them.** Two places that
   must change together become a list of places to update, and the list
   is an enumeration that someone forgets. The section states the rule
   (every decision, table and format has one implementation; C, Erlang
   and Ruby share a table only by generation) and its companion: a fact
   the build can compute is never written by hand and then checked.
   *Draws on:* [design.md, One source for the ABI and the hardware](../design.md#one-source-for-the-abi-and-the-hardware),
   [design-generation.md, Sources and outputs](../design-generation.md#sources-and-outputs).
2. **The ABI file.** Status codes, limits, rights and every fixed binary
   layout (rings, reader pages, frames, boot information, descriptors)
   are declared in one text file, and Ruby generators produce the C
   headers, the Erlang modules and the Ruby tables. The section walks
   one line from text to each output, and one layout to its offsets and
   the compiler's word on them.
   *Draws on:* [design-abi.md, Source grammar](../design-abi.md#source-grammar),
   [design-abi.md, A complete declaration example](../design-abi.md#a-complete-declaration-example),
   `abi/erx_abi.txt`.
3. **The rules every spec follows.** State facts and derive the rest;
   close every set, strictly; no expressions; fail whole; sorted and
   deterministic; generated files are not checked in. Tables that must
   match someone else's, such as FreeBSD's errno numbers.
4. **The hardware has one source too.** Device registers come from
   CMSIS-SVD files and the processor's own registers from Arm's
   machine-readable data; accessors are generated and no register bit is
   packed by hand. The section follows one register from XML to a
   driver.
   *Draws on:* [design-generation.md, Hardware and terminal sources](../design-generation.md#hardware-and-terminal-sources),
   [design-generation.md, Register inputs](../design-generation.md#register-inputs).
5. **One theme, three languages.** The desktop's type roles, spacing,
   radii, shadows and palette are one declaration with contrast rules the
   build checks, and the Erlang, C and TypeScript sides are generated
   from it.
   *Draws on:* [design-desktop-programs.md, The theme: one declaration](../design-desktop-programs.md#the-theme-one-declaration).
6. **The descriptor formats behind the DMA check.** Each kind of
   device's descriptors are declared once, and the device NIF's forms
   and the check read the same declaration.
7. **The system manifest: the machine's configuration, checked.** One
   file lists every configured domain with its principal, image,
   budget, devices by unit, facets and introductions. A build check
   refuses a manifest that breaks a property the security argument rests
   on, and each property has a seeded test that plants one violation and
   expects its diagnostic.
   *Draws on:* [design-system.md, The manifest](../design-system.md#the-manifest),
   [design-abi.md, System-manifest representation](../design-abi.md#system-manifest-representation).
8. **Declared services and inspection paths.** Every cross-domain facet is
   declared in `abi/services` with the design section that justifies it,
   and every value the system observes is an inspection path declared in
   `abi/inspection.txt`; a build check refuses what the tables do not
   list.
   *Draws on:* [design-generation.md, Service interfaces](../design-generation.md#service-interfaces),
   [design-generation.md, Inspection and diagnostics](../design-generation.md#inspection-and-diagnostics).
9. **When a source is wrong.** A malformed spec, a well-formed but wrong
   value, and a wrong configuration, and what catches each.
10. **Where logic languages fit, and where they do not.** Barrelfish's
    system knowledge base and the BOOM project described systems in a
    logic language; erXos's principles allow Datalog where it turns a
    property into a checked constraint, never where it adds complexity.
    The section says where that holds and where plain generators win.
    *Draws on:* [design-verification.md, Focused tool evaluations](../design-verification.md#focused-tool-evaluations),
    [research-os-ideas.md, Declarative OS services from BOOM and Dedalus](../research-os-ideas.md#declarative-os-services-from-boom-and-dedalus),
    [research-os-ideas.md, Barrelfish and declarative hardware management](../research-os-ideas.md#barrelfish-and-declarative-hardware-management).
11. **Design choices.** Headers written by hand and tested, the C header
    as the source, a general interface language, checking the
    configuration at boot: why each was not chosen.

**Figures.** 7.1: the generation graph: the ABI file, the hardware
sources, the theme and the inspection schema on the left, the generators
in the middle, every generated header, module and table on the right.
7.2: one declaration and its C, Erlang and Ruby outputs side by side.
7.3: the manifest check as a pipeline: reader, normalized facts,
properties, diagnostics, with one seeded violation traced through.

### Chapter 8. The Kernel Interface and Fiasco

*About 23 pages.* The kernel's services are its interface: objects,
handles, threads, memory, IPC and interrupts. Fiasco, the L4
microkernel, is the kernel behind it, and the system domain's root
service builds every domain over it.

**Background needed.** Chapters 1 to 3; chapter 2 for capabilities,
IPC gates, the UTCB and the root task. Chapters 5 to 7 help but are not
required.

**Background boxes.** A capability table recalled from chapter 2.
Fiasco, L4Re and the root task in a page.

**Status.** Built: `liberx` with its Fiasco backend and its hosted
backend, held to one test set; the root service, its request decoder
and its tables; handles as entries of the root's per-task tables, each
carrying its object's generation; memory objects of seven kinds,
mappings and the root's page pool; doorbells and device lines; thread
creation, umtx waits and parking; fault gates and exit records; the
machine's end on a fault of the root task; budgets as records that end
what is charged to them; each task's threads at its band's priority.
Designed: priority bands as a base and a ceiling, and per-domain CPU
sets; signals through vCPU upcalls; DMA spaces behind an IOMMU; rights
on handles checked on every use; and the system-call
fuzz campaign.

1. **What the kernel knows, and what it does not.** Spaces, threads,
   memory objects, IRQ objects, gates and budgets; nothing of Erlang.
   The section explains why the line falls there.
   *Draws on:* [design-fiasco.md, Contract](../design-fiasco.md#contract),
   [design.md, Trust placement](../design.md#trust-placement).
2. **`liberx`: the one issuer of kernel calls.** Every kernel call in
   every runtime and program goes through `liberx`, whose numbers come
   from the ABI file; behind it sit the Fiasco backend, whose calls are
   local or service calls, and the hosted backend, which pass one test
   set. A call the backend cannot carry out fails with `ERX_ENOTSUP`,
   and a value it cannot measure is reported as unsupported, never
   invented. A build check holds the seam.
   *Draws on:* [design-runtime.md, liberx](../design-runtime.md#liberx),
   [design-runtime.md, The liberx interface](../design-runtime.md#the-liberx-interface).
3. **The root service: who holds what.** One thread of the system domain
   is the only creator of kernel objects and the only writer of page
   tables, so its tables need no lock. What a domain holds, the request
   decoder as the trust boundary, and one request followed end to end:
   a domain's crash area.
   *Draws on:* [design-fiasco.md, The construction](../design-fiasco.md#the-construction),
   [design-fiasco.md, Who holds what](../design-fiasco.md#who-holds-what),
   [design-fiasco.md, The call table](../design-fiasco.md#the-call-table).
4. **Handles and destroying an object.** A handle is an entry in the
   caller's table in the root service; the entry records its object's
   generation, and the handle's value carries the entry's own, so a
   destroyed object's handles and a handle used after its own close
   both answer `ERX_ESTALE` and never name a successor. Free entries
   are reused first in, first out. Entries record rights, and only the
   creator may destroy; rights narrowed per creation kind and checked on
   every use, and interrupt objects rung straight through Fiasco, are
   Designed.
   Handles flow only down, from a space's creator into it.
   *Draws on:* [design-fiasco.md, Destroying an object](../design-fiasco.md#destroying-an-object),
   [design-fiasco.md, Passing a handle](../design-fiasco.md#passing-a-handle).
5. **Threads, waits, gates and faults.** Threads and the reaper, one
   semaphore per thread for umtx waits and parking, gates that carry
   fault and exit records, how a fault reaches the right handler, what
   a fault of the root task does to the machine, and signals through
   vCPU upcalls (Designed).
   *Draws on:* [design-fiasco.md, Threads, waits and exit](../design-fiasco.md#threads-waits-and-exit),
   [design-fiasco.md, vCPU upcalls on Fiasco](../design-fiasco.md#vcpu-upcalls-on-fiasco).
6. **Memory objects and mappings.** One page, one address in the root's
   window; reserve, commit and map through one range table; the kinds
   of memory object; who pays.
7. **Interrupts, doorbells and devices.** One dispatcher per task for
   device lines and doorbells alike, and what a driver domain holds for
   a device.
   *Draws on:* [design-fiasco.md, Interrupts and readiness](../design-fiasco.md#interrupts-and-readiness).
8. **What Fiasco gives, and what it does not.** Isolation between
   domains rests on Fiasco and on the root service's decoder and
   placement code; where no IOMMU confines a DMA-capable device, also on
   the domain that drives it. The section states plainly what a hostile
   domain could do and what fails when, as a property of the system.
   *Draws on:* [design-fiasco.md, Security on Fiasco](../design-fiasco.md#security-on-fiasco),
   [design-fiasco.md, What a hostile app can do](../design-fiasco.md#what-a-hostile-app-can-do).
9. **Design choices.** Runtimes talking to Fiasco directly, a root of
   several threads, Fiasco's own interface, a refusal as a best effort:
   why each was not chosen.

**Figures.** 8.1: the kernel interface: runtimes and programs above,
`liberx` and its generated calls, the Fiasco and hosted backends below
it. 8.2: the root service between the domains and Fiasco: requests in,
kernel objects placed in each domain's tables. 8.3: a handle's
life: created, passed, stale or closed, reused.

## Part III. Processes

### Chapter 9. Processes, Runtimes and Two-Level Scheduling

*About 15 pages.* Every Erlang process is a process of the operating
system; Fiasco shares the processors among threads, and each runtime
schedules its own processes on its own threads.

**Background needed.** Chapter 8 for `liberx`, the root service,
threads and waits; section 3.5.2 for schedulers and reductions.

**Background boxes.** A C library, and musl.

**Status.** Built: ERTS in user mode in every domain, with its Erlang
processes as the system's one kind of process; the four levels and the
bands as a base and a ceiling, with Fiasco running each task's threads
at its band's base, no rank among the configured domains, and its
domain grant's slice as each thread's quantum; a call to the root service on the caller's remaining slice;
executors and workers and how
they park and wake; the event table that turns a doorbell into work;
the system domain on the interpreter, with BeamAsm available to other
domains; musl under ERTS, with FreeBSD's errno and signal numbers;
hosted mode; `ps` over Erlang processes; and `erx:trace`. Designed:
pinned schedulers and parking in place of spinning; the urgent scheduler; CPU sets and thread
limits; refusing an executor every
other blocking wait; refusing code that is not installed; one shared
copy of common code; native programs in `ps`; and services that admit
each client within a share of their time.

1. **The Erlang process is the system's process.** What a user sees
   (`ps` lists Erlang processes) and what a programmer sees (OTP
   applications run unmodified), and the two levels in one picture:
   Fiasco schedules threads, each runtime its processes.
   *Draws on:* [design.md, The model](../design.md#the-model).
2. **How Fiasco shares the processors.** What a priority can do on
   Fiasco, and the rule that a priority above another is only for work
   that ends; four levels and five bands, with the configured domains'
   ordinary work at one level; pinned schedulers, a 1 ms slice and
   parking in place of spinning; the urgent scheduler, which waits above
   the base for a trusted runtime's interrupts and runs its `high` work,
   and its roster; CPU sets and thread limits. The levels, the bands and
   the slice are built; the rest is designed and not built.
   *Draws on:* [design-fiasco.md, Scheduling](../design-fiasco.md#scheduling),
   [design-fiasco.md, Bands](../design-fiasco.md#bands),
   [design-fiasco.md, Urgency](../design-fiasco.md#urgency),
   [design-fiasco.md, Threads, bands and stops](../design-fiasco.md#threads-bands-and-stops).
3. **The runtime contract.** Executors run Erlang processes and never
   block except to park; workers may block. The lost wakeup, and the
   epoch that closes it; park and wake on Fiasco through one semaphore
   per thread, the dispatcher and the group's ready list; what a runtime
   does not get from the kernel.
   *Draws on:* [design-scheduler.md, The runtime contract](../design-scheduler.md#the-runtime-contract),
   [design-scheduler.md, Park and wake](../design-scheduler.md#park-and-wake),
   [design-fiasco.md, The park protocol](../design-fiasco.md#the-park-protocol).
4. **ERTS as a parts bin.** One mechanism per job; the inside of ERTS on
   erXos, with the adapter as the one part that includes `liberx`; the
   scheduler's sleep in code; the event table, which gives readiness
   without file descriptors.
   *Draws on:* [design-runtime.md, One mechanism per job](../design-runtime.md#one-mechanism-per-job),
   [design-runtime.md, The adapter](../design-runtime.md#the-adapter),
   [design-runtime.md, The event table](../design-runtime.md#the-event-table).
5. **Code: the interpreter, BeamAsm and shared code.** Three runtime
   images, chosen by facts fixed at boot; the system domain's code
   service loads modules by hash; refusing code that is not installed,
   and one shared image of common code, are designed and not built.
   *Draws on:* [design-runtime.md, BeamAsm](../design-runtime.md#beamasm),
   [design-runtime.md, Code in the system domain](../design-runtime.md#code-in-the-system-domain),
   [design-shared-code.md, The central construction](../design-shared-code.md#the-central-construction).
6. **The C library seam and hosted mode.** musl over `liberx` through
   one seam, and the same runtime as a macOS process under the
   sanitizers and a debugger.
   *Draws on:* [design-runtime.md, The C library seam](../design-runtime.md#the-c-library-seam),
   [design-runtime.md, Hosted mode](../design-runtime.md#hosted-mode).
7. **Two schedulers you can watch as one.** One timeline from OTP's
   trace and the root service's trace ring, and a worked example of
   three domains sharing a service.
   *Draws on:* [design-live.md, Tracing](../design-live.md#tracing),
   [design-fiasco.md, The trace ring](../design-fiasco.md#the-trace-ring),
   [design-scheduler.md, A worked example](../design-scheduler.md#a-worked-example).
8. **What happens when a part fails.** A looping process, a looping NIF
   or a blocked executor, a crashed runtime, a stuck machine: each stays
   where it started.
   *Draws on:* [design-runtime.md, Crash handling](../design-runtime.md#crash-handling),
   [design-fiasco.md, The watchdog](../design-fiasco.md#the-watchdog).
9. **Design choices.** Every Erlang process a kernel thread, scheduler
   activations, shares instead of priorities, a rank among the
   configured domains, raising a thread for urgent work, lending time
   to a service, stock ERTS on a POSIX layer: why each was not chosen.

**Figures.** 9.1: the two levels: Fiasco schedules threads, each runtime
switches among its own processes on its executors. 9.2: park and wake,
drawn for one epoch. 9.3: ERTS on erXos: the adapter and musl above
`liberx`, and `liberx` above Fiasco and the root service.

### Chapter 10. Domains: A Wall Around Some Processes

*About 19 pages.* The unit of isolation: a domain is an address space
with its own runtime and an Erlang node of its own, and processes in
different domains link, monitor and message each other as Erlang
processes always have.

**Background needed.** Chapter 1 for address spaces and shared memory;
chapter 2 for capabilities and the root task; chapter 3 for processes,
links, nodes and the external term format; chapter 8 for `liberx`, the
root service, handles and doorbells. Chapter 9 helps but is not
required.

**Background boxes.** Address spaces, recalled. Rings and doorbells.
Frames, recalled.

**Status.** Built: domains, each with its own ERTS in its own address
space and its own Erlang node; connections of two lanes with doorbells;
the funnel; export tables; the `{erx_origin, D, Msg}` envelope; links,
monitors, exits and spawns across domains; `{domain_down, D, Info}` at a
domain's end; the domain service, the domain library and the root
service creating and ending domains; a quota of node names per
principal. Designed: budgets that refuse connection memory past their
limit; handles that carry rights; a spawn right for a domain's creator
at boot; `gen_server` and `gen_statem` servers that take calls from
other domains directly; a decoder in the system domain that creates no
atom from another domain's frame.

1. **A domain is a node.** What a domain holds; domain ids, creations
   and pids, so a pid carries its owner domain; where the picture of
   Erlang distribution inside one machine stops.
   *Draws on:* [design-domains.md, Domain ids, pids and references](../design-domains.md#domain-ids-pids-and-references),
   [design-domains.md, Atoms, code, ETS and names](../design-domains.md#atoms-code-ets-and-names).
2. **Connections, lanes and doorbells.** A lane: a ring the producer
   alone writes, a reader page the consumer alone writes, and a bell.
   Publishing and waking, checked by herd7 and TLA+; who makes a
   connection; what happens when a lane is full.
   *Draws on:* [design-domains.md, Connections](../design-domains.md#connections),
   [design-domains.md, Introduction and connection down](../design-domains.md#introduction-and-connection-down),
   [design-domains.md, Flow control](../design-domains.md#flow-control).
3. **The funnel.** The receiver's one reader of its lanes copies a frame
   out first, checks it in order, tells a malformed frame from one over
   a limit, and is checked against `binary_to_term/1`.
   *Draws on:* [design-domains.md, The funnel](../design-domains.md#the-funnel),
   `liberx/erx_funnel.c`.
4. **Exports: a pid is a name, not an authority.** Why a pid cannot be
   the authority; the three writers of a name's holders; what a peer
   cannot do; Safe Erlang compared.
   *Draws on:* [design-domains.md, Exports](../design-domains.md#exports),
   [design-domains.md, Alternatives considered](../design-domains.md#alternatives-considered).
5. **The origin envelope.** Every message from another domain arrives as
   `{erx_origin, D, Msg}`, with no exception, and only each protocol's
   owner takes the envelope off its own shapes.
   *Draws on:* [design-domains.md, The peer](../design-domains.md#the-peer).
6. **One message, end to end.** One round trip between the system
   domain and a domain named `web`, through every part of the chapter.
7. **Links, monitors, exits and spawns across a wall.** A process
   exits; killing a process in another domain; spawning into another
   domain; a domain dies and its peers see `{domain_down, D, Info}`.
   *Draws on:* [design-domains.md, Links, monitors and exits](../design-domains.md#links-monitors-and-exits),
   [design-domains.md, Spawning](../design-domains.md#spawning).
8. **The system domain and the domain library.** Three layers: the
   domain service in Erlang, the domain library in C, the root service;
   creating and ending a domain.
   *Draws on:* [design-system.md, The domain library](../design-system.md#the-domain-library),
   [design-system.md, Creating a domain](../design-system.md#creating-a-domain),
   [design-system.md, Ending a domain](../design-system.md#ending-a-domain).
9. **What fails, and what it reaches.** No failure in the chapter
   reaches past the domain or connection it began in, and the limits of
   the system as built are stated plainly.
10. **Design choices.** A router between domains, a table kept by the
    sender, revocable pid exports, synchronous calls between domains:
    why each was not chosen.

**Figures.** 10.1: two domains and their connection, each side one
memory object only its own domain writes. 10.2: a pid's parts and the
export lookup. 10.3: one round trip between two domains. 10.4: a
sandbox crash, from fault to the linked process.

### Chapter 11. Authority and Security

*About 20 pages.* Who may do what, and why: the threat model, trust
placement, the four forms of authority, principals, machine code, keys
and untrusted text, and what a hostile app could do on the system as
built.

**Background needed.** Chapter 2 for capabilities, the confused deputy
and the trusted computing base; chapter 8 for handles, the root service
and what Fiasco gives; chapter 6 for exports, the funnel and the origin
envelope.

**Background boxes.** Threat models. Branch-predictor attacks.
Signatures and a key vault. Terminal escape sequences.

**Status.** Built: the walls between domains, which rest on Fiasco and
the root service; handles, exports, facets and file grants; the refusal
of a mapping that is writable and executable; the three runtime images;
and the escaping of untrusted text. Designed: rights on handles, budgets
that refuse, CPU bands, devices behind an IOMMU, a safe decode of other
domains' messages in the system domain, login with a passphrase, and
the key vault.

1. **The threat model.** Adversaries and assets, the untrusted inputs,
   and what the threat model leaves out, branch-predictor attacks among
   it.
   *Draws on:* [design.md, Threat model](../design.md#threat-model),
   [design.md, Residual risks](../design.md#residual-risks).
2. **Trust placement.** Two things keep domains apart, Fiasco and the
   root service; the trusted base; why the system domain may stop the
   machine; why no verifier.
   *Draws on:* [design.md, Trust placement](../design.md#trust-placement),
   [design.md, Why no verifier](../design.md#why-no-verifier).
3. **Four forms of authority.** Handles, exports, facets and file
   grants: each has a holder and a checker, never the same party.
4. **Handles: authority over kernel objects.** What a handle protects,
   what it does not (rights, and a number reused after its own close),
   and the design that closes both.
   *Draws on:* [design-fiasco.md, Rights](../design-fiasco.md#rights).
5. **Exports and the funnel: authority over processes.** The export
   table and the funnel; a missing right looks like a dead process; the
   envelope.
   *Draws on:* [design-domains.md, Authority](../design-domains.md#authority),
   [design-domains.md, The funnel](../design-domains.md#the-funnel).
6. **Facets: authority over services.** One grant, one grantee, one
   process; what every facet checks; why a process and not a list, and
   how that answers the confused deputy.
   *Draws on:* [design-domains.md, Facets](../design-domains.md#facets).
7. **File grants: authority over files.** A namespace of grants, and
   narrowing it for a program.
   *Draws on:* [design-files.md, Who a grant is for](../design-files.md#who-a-grant-is-for).
8. **A worked example: who may set the clock.** The grants, one set
   followed end to end, three refusals and one gap.
   *Draws on:* [design-time.md, Who may set it](../design-time.md#who-may-set-it).
9. **Principals, sessions and quotas.** What a principal holds, and
   which limits hold and which are only records.
   *Draws on:* [design-domains.md, Principals, sessions and quotas](../design-domains.md#principals-sessions-and-quotas).
10. **Machine code.** No mapping writable and executable at once, and
    who may make code; a page can still be writable through one mapping
    and executable through another.
    *Draws on:* [design.md, Machine code](../design.md#machine-code).
11. **Keys, the vault and cryptography.** OpenSSL in two of the three
    runtime images, and the vault with its key facets, which is
    designed and not built.
    *Draws on:* [design-crypto.md, Three runtime images, and OpenSSL in two of them](../design-crypto.md#three-runtime-images-and-openssl-in-two-of-them),
    [design-system.md, The vault](../design-system.md#the-vault).
12. **Text from untrusted sources.** One escape per sink, generated from
    one table, and what is not escaped: a program's own output.
    *Draws on:* [design-live.md, Escape rules](../design-live.md#escape-rules).
13. **Trusted code only, and what a hostile app can do.** The boot
    banner's promise, a table of what is built and what is designed,
    and what a hostile app could do on the system as built.
    *Draws on:* [design-fiasco.md, What a hostile app can do](../design-fiasco.md#what-a-hostile-app-can-do).
14. **When a guard fails.** Each check fails visibly and reaches only
    what it guards.
15. **Design choices.** User ids against held authority, checks at the
    receiver against a broker in between, escaping at the sink against
    cleaning at the source.

**Figures.** 11.1: the trust map, as designed. 11.2: a facet between a
domain and a service. 11.3: the escape at each text sink.

### Chapter 12. Memory and Budgets

*About 13 pages.* Each domain's memory is charged to its budgets, and
ending a budget ends everything charged to it; the root service alone
maps memory, from one pool, through one range table.

**Background needed.** Chapter 1 for virtual memory (section 1.4);
chapter 8 for the root service, handles, memory objects and reserve,
commit and map. Chapter 5 introduced budgets.

**Background boxes.** Page tables and faults, recalled. Space banks.
Copy-on-write, recalled.

**Status.** Built: the page pool and the range table, with commit, map,
protect and revoke over Fiasco, shared objects and the JIT alias;
budgets that end everything charged to them, each domain's own and
outer budgets, and admission arithmetic; sub-spaces that end with their
creator; eager copies; one machine-wide figure reported as partial.
Designed: budgets as walls over kernel memory, pages and the root's
tables; rights recorded per handle; per-budget reports; a refused map
that fails only the domain's call; the mapper for shared file
mappings.

1. **Budgets as space banks.** A budget is an account with a guarantee
   and a cap, a wall or elastic; ending a budget ends what was charged
   to it.
   *Draws on:* [design-fiasco.md, Memory and budgets](../design-fiasco.md#memory-and-budgets).
2. **Own and outer budgets.** What a domain alone maps dies with it;
   what others map for it, each connection through a child budget, and
   its crash area outlive it.
   *Draws on:* [design-system.md, Ending a domain](../design-system.md#ending-a-domain).
3. **The pool.** One pool of pages in the root's window, and the
   contiguous pool for devices.
   *Draws on:* [design-fiasco.md, The pool](../design-fiasco.md#the-pool).
4. **Walls: what is built, what is designed.** Accounts without walls
   today, and the three parts a wall needs.
   *Draws on:* [design-fiasco.md, Memory and budgets](../design-fiasco.md#memory-and-budgets).
5. **The range table.** Three facts (runs, mapping records, the page
   index); plans, then effects; one table of steps; a mapping keeps the
   rights it was made with; trimming never meets sharing.
   *Draws on:* [design-fiasco.md, The range table](../design-fiasco.md#the-range-table),
   [design-fiasco.md, Protection](../design-fiasco.md#protection).
6. **One commit, end to end.** One page of one ERTS commit through
   every layer.
7. **Sub-spaces and shared objects.** A sub-space spends its creator's
   memory; shared objects and the JIT alias.
   *Draws on:* [design-fiasco.md, Spaces, parents and exit records](../design-fiasco.md#spaces-parents-and-exit-records),
   [design-fiasco.md, Shared objects and the JIT alias](../design-fiasco.md#shared-objects-and-the-jit-alias).
8. **Deleted memory.** What a destroy does to a mapping, and why no
   server maps what a client can delete: the session's mapper for
   shared file mappings, designed and not built.
   *Draws on:* [design-files.md, Shared mappings](../design-files.md#shared-mappings).
9. **Reporting a budget, and what is not charged.** What is reported,
   as exact, partial or unsupported, and the memory nothing charges.
   *Draws on:* [design-fiasco.md, Reporting a budget](../design-fiasco.md#reporting-a-budget).
10. **When memory runs out.** The pool, a domain's wall, Fiasco's
    kernel memory: what each running out does.
11. **Design choices.** Commit at once or fill on demand, one mapper or
    a pager per domain, walls or elastic quotas everywhere, eager
    copies.

**Figures.** 12.1: own and outer budgets of two connected domains.
12.2: a private page and a mapping in a task's range table.

### Chapter 13. Native Programs, Pipes and POSIX-lite

*About 16 pages.* UNIX programs where they pay: a native program is a
port of its session, running in a sub-space with only what its starter
handed it, and pipes live in user space.

**Background needed.** Chapter 1 for exit status and signals, file
descriptors, pipes and memory ordering; chapter 3 for processes,
monitors and ports; chapter 5 for sessions and sub-spaces; chapter 8
for fault gates and doorbells.

**Background boxes.** Executable files. Signals and job control.
POSIX.

**Status.** Built: a C program from the session's release runs in a
sub-space of its session and talks to one Erlang process, its handler;
pipes in user space, made by the session's pipe server; programs in
command-shell pipelines beside Erlang commands; files, `poll`, `dup`
and `pipe`; a `kill` that reaches only the program itself; FreeBSD's
signal and errno numbers. Designed: programs starting programs
(`posix_spawn`, `wait`), executable files as images, catchable signals
through vCPU upcalls, job control that pauses a program, terminal input
and sockets for programs, toybox, the second tier, and the POSIX-lite
personality as a whole.

1. **A program is a port.** What a program consists of (anchor, image,
   budget, channel, table, data area) and why a port.
   *Draws on:* [design-programs.md, A program is a port](../design-programs.md#a-program-is-a-port).
2. **The channel and the handler.** The channel and its credit; the
   handler, which never waits on the program or on a request's work;
   the command server; what a program can start.
   *Draws on:* [design-programs.md, The channel](../design-programs.md#the-channel),
   [design-programs.md, The handler](../design-programs.md#the-handler),
   [design-programs.md, What a program can start](../design-programs.md#what-a-program-can-start).
3. **Starting a program.** From the shell's line to `main`.
   *Draws on:* [design-programs.md, The cost of a program](../design-programs.md#the-cost-of-a-program).
4. **Pipes in user space.** Why not in the kernel; one ring per writer;
   shared memory a stranger can write; ends and their holders;
   doorbells and lost wakeups, checked by herd7.
   *Draws on:* [design-pipes.md, The ring](../design-pipes.md#the-ring),
   [design-pipes.md, The lock page](../design-pipes.md#the-lock-page),
   [design-pipes.md, Ends and their holders](../design-pipes.md#ends-and-their-holders).
5. **A pipeline, end to end.** `echo piped text | rcio upcase`, through
   shell pipes, pumps and rings to `$status`.
6. **Signals, job control and FreeBSD's numbers.** What a program can
   do with a signal; `kill` reaches only the program itself; `Ctrl-C`
   and the session's job control; signals through vCPU upcalls,
   designed and not built; one signal numbering.
   *Draws on:* [design-programs.md, Signals in liberx](../design-programs.md#signals-in-liberx),
   [design-programs.md, Job control](../design-programs.md#job-control).
7. **The POSIX-lite personality.** What a recompiled program gets, why
   `posix_spawn` and not `fork`, and toybox beside the Erlang file
   utilities; designed and not built as a whole.
   *Draws on:* [design-programs.md, The POSIX-lite personality](../design-programs.md#the-posix-lite-personality),
   [design-programs.md, toybox](../design-programs.md#toybox).
8. **The second tier.** `fork`, `exec`, shared libraries and terminals
   for programs that cannot be changed, without giving up the first
   tier's rules; designed and not built.
   *Draws on:* [design-programs.md, The second tier](../design-programs.md#the-second-tier).
9. **When a part fails.** Every failure of a program ends in one exit
   status, given to its starter.
10. **Design choices.** A program as a domain, Linux binary
    compatibility, a handler per program.

**Figures.** 13.1: a session with two programs, their handlers and a
pipe between them. 13.2: the life of `echo piped text | rcio upcase`.

---

## Part IV. The I/O System

### Chapter 14. Files, Namespaces and Service Trees

*About 36 pages.* Plan 9's idea, kept whole: each domain sees files
through its own table of file servers, a path is the visible face of a
capability, and every server speaks 9P2000.L.

**Background needed.** Chapters 1, 2, 10 and 11.

**Background boxes.** The UNIX file model: paths, mounts, descriptors.
Plan 9 in a page: per-process namespaces and 9P. RAM file systems.

**Status.** Built: per-domain namespaces, file servers in other domains
reached through file grants and 9P2000.L, the `erx_fs` behaviour, one
path resolver for every runtime, a program's namespace narrowed from its
starter's, stream files whose waiting reads a keeper holds, `/tmp` on a
RAM file system in Erlang, `/proc` as a read-only view of the inspector,
the host link's 9P bridge, and the session's export. Designed: entries
on the export in a program's table, shared mappings of files, a
`sysctl(3)` reader for programs, and an app's own tree at `/svc/NAME`.

1. **A path is the face of a capability.** There is no global root: a
   domain's namespace is a private table from paths to grants, and each
   file server roots a grant at its subtree, so a path never reaches a
   server the domain does not hold.
   *Draws on:* [design-files.md, Namespaces](../design-files.md#namespaces),
   [design-files.md, Resolving a path](../design-files.md#resolving-a-path).
2. **One file protocol.** 9P2000.L between domains, its codec fuzzed;
   the `erx_fs` behaviour that every Erlang file server implements; Erlang
   clients through `prim_file` and native clients through `liberx`.
   *Draws on:* [design-files.md, The file protocol](../design-files.md#the-file-protocol),
   [design-files.md, Serving: the `erx_fs` behaviour](../design-files.md#serving-the-erx_fs-behaviour).
3. **Narrowing for a program, and shared mappings.** What a program's
   namespace holds and how its starter narrows it; how a session maps one
   file into two programs with one memory object and writes back only
   the pages the kernel reports stored.
   *Draws on:* [design-files.md, Narrowing for a program](../design-files.md#narrowing-for-a-program),
   [design-files.md, Shared mappings](../design-files.md#shared-mappings).
4. **`/tmp`: a file system in Erlang.** A small, complete file server, as
   the reader's first look at the `erx_fs` behaviour from the inside.
   *Draws on:* [design-tmp.md](../design-tmp.md).
5. **State is a file to read, control is a file to write.** Plan 9's rule
   applied to services: what the system observes is an inspection path
   shown at `/proc`; what an app says about itself or what someone
   commands is a file tree its owner serves, with a `status` to read and
   a `ctl` for one-shot control. Where FreeBSD has `sysctl`, system
   values are one read-only tree with many views.
   *Draws on:* [design-app-trees.md, The tree](../design-app-trees.md#the-tree),
   [design-app-trees.md, Commanding: `ctl`](../design-app-trees.md#commanding-ctl),
   [design-live.md, The /proc tree](../design-live.md#the-proc-tree).
6. **Familiar only where true.** The section closes with the review
   question every familiar surface faces ("what does this promise that it
   does not do?") applied to `/proc`, `/dev` and `/etc/passwd`.
   *Draws on:* [design-app-trees.md, What FreeBSD does](../design-app-trees.md#what-freebsd-does).

**Figures.** 14.1: two domains' namespaces over the same file servers,
showing what each can and cannot reach. 14.2: a 9P2000.L walk, open and
read between domains. 14.3: an app's `/svc/NAME` tree beside `/proc`.

### Chapter 15. Devices and Drivers

*About 52 pages.* A driver is a supervised Erlang process over a thin
device shim; the shim's C is a functional core whose every plan is
checked before it touches the hardware.

**Background needed.** Chapters 1 (interrupts, DMA, caches), 2, 9 and
10.

**Background boxes.** DMA, cache coherence and IOMMUs, before the DMA
check. Memory-mapped I/O, interrupt controllers and message-signalled
interrupts. PCIe in a page. USB in a page: hubs, descriptors, transfers.
Device trees and firmware. virtio.

**Status.** Built: drivers as supervised Erlang processes (virtio devices
on QEMU `virt`; the SD card, GENET Ethernet and the firmware
framebuffer on the Raspberry Pi 4), the device NIF with the virtio and
GENET descriptor forms and the check of every DMA plan, the device tree
reader's DMA facts, the unit rule, the driver-control facet and both
drivers' restarts. Built, and unexercised because no PCIe domain runs:
the give of a PCIe function. Built as pure code with host tests: the
PCIe enumerator's parts, USB's cores and decoders, the TRB descriptor
form, and the check of the Pi 4's header map. Built: the root's setting
of the Pi 4's on-board pins at boot. Designed: the running PCIe
and USB domains, MSI delivery, virtio over PCIe, the SD controller's
ADMA2 form, the pin driver, which takes over the root's setting of
pins, the Pi 4's header drivers and `/proc/sensors`.

1. **A driver is a process.** Kill the network driver's process
   mid-transfer from the shell; its supervisor restarts it, the device
   is reset, and the shell never notices. The section explains why
   drivers are Erlang (principle 1), what stays in C (the device shim and
   the per-byte primitives) and the driver table that lists every native
   exception with its reason.
   *Draws on:* [design-system.md, Drivers](../design-system.md#drivers),
   [design-system.md, The driver table](../design-system.md#the-driver-table),
   [design.md, Drivers and DMA](../design.md#drivers-and-dma).
2. **The device NIF.** One module, `erx_device`, through which a driver
   reaches registers, descriptors, DMA buffers and interrupts. Its C
   parses nothing a device wrote; each descriptor form (the virtio split
   ring, GENET's register ring, ADMA2 tables) is a pure round function,
   and one effect loop performs reads and checked plans.
   *Draws on:* [design-runtime.md, The device NIF](../design-runtime.md#the-device-nif),
   [design-device-dma.md, The descriptor forms](../design-device-dma.md#the-descriptor-forms).
3. **DMA by devices that are not cache-coherent.** The Pi 4's Ethernet and
   SD controllers read memory without looking in the CPU's caches. Memory
   changes hands in whole cache-writeback granules, and at any moment
   either the CPU or the device is a region's writer, never both; cache
   cleaning, invalidation and barriers follow from that handoff in one
   sequencer; and the device writes over zeros, so a completion never
   returns an earlier request's bytes.
   *Draws on:* [design-device-dma.md, The construction: handoffs of granules](../design-device-dma.md#the-construction-handoffs-of-granules),
   [design-arch-aarch64.md, Cache maintenance](../design-arch-aarch64.md#cache-maintenance).
4. **The plan and its check.** The method at its clearest. A
   descriptor form's core returns either the reads it needs or a decision:
   a plan and the queue's next state. `erx_device_dma_check` checks the
   whole decision before any effect: the state change is one the call
   allows, every write lands in a region the CPU owns, every device
   address and the bytes reachable from it lie inside the domain's DMA
   memory as the device sees it, and every register written is one the
   NIF owns. A plan that fails is a bug in the core, and the call is
   `badarg` with nothing applied. On a platform with no IOMMU, which
   QEMU `virt` and the Raspberry Pi 4 both are, this check is what
   stops a driver bug from aiming a device at kernel memory; the driving
   domain still counts in the trusted base.
   *Draws on:* [design-device-dma.md, Calls, observations and plans](../design-device-dma.md#calls-observations-and-plans),
   [design-device-dma.md, Device addresses and reach](../design-device-dma.md#device-addresses-and-reach),
   [design-device-dma.md, Register ownership](../design-device-dma.md#register-ownership),
   `otp/erts/emulator/nifs/erxos/erx_device_dma.c`.
5. **Facts the firmware owns.** The device tree the firmware hands over
   is read where it left it: coherence and DMA ranges come from it, and
   a device whose facts are absent or malformed gets no DMA memory rather
   than a guess.
   *Draws on:* [design-device-tree.md](../design-device-tree.md),
   [design-fiasco.md, Devices](../design-fiasco.md#devices).
6. **Devices that share.** A register page or an interrupt line shared by
   two devices: the unit rule, and the console.
   *Draws on:* [design-shared-devices.md, The unit rule](../design-shared-devices.md#the-unit-rule).
7. **PCIe and USB.** The PCIe domain alone reaches configuration space
   and holds nothing else; its enumerator, in Erlang, plans the bus whole
   (sizing, placement, interrupts) before it writes. USB's construction:
   every port is a hub port, hotplug ends at the controller's domain, a
   device's name dies at once and its hardware is freed only on the
   controller's report.
   *Draws on:* [design-pcie.md, The construction](../design-pcie.md#the-construction),
   [design-pcie.md, The PCIe domain](../design-pcie.md#the-pcie-domain),
   [design-usb.md, The construction](../design-usb.md#the-construction).
8. **The Raspberry Pi 4's own devices.** The board's table of pins and
   the pin driver, the 40-pin header (GPIO, I2C,
   SPI, PWM) and the firmware's sensor readings at `/proc/sensors`, as
   examples of small drivers under the same rules.
   *Draws on:* [design-pinctrl.md](../design-pinctrl.md),
   [design-header-io.md](../design-header-io.md),
   [design-board-sensors.md](../design-board-sensors.md).

**Figures.** 15.1: a driver domain: supervisor, driver process, device
NIF, device, interrupts. 15.2: a call through the device NIF: rounds of
observation and decision, the check, the sequencer's maintenance and
barriers, the effects. 15.3: a region's writer passing between CPU and
device across a post and a completion. 15.4: the PCIe domain and the
domains it gives devices to.

### Chapter 16. Storage and Updates

*About 44 pages.* The system ships as read-only images checked block by
block, data lives in a file system written in Erlang, and an update
leaves a bootable system whatever happens.

**Background needed.** Chapters 1, 14 and 15.

**Background boxes.** Block devices, partitions and the SD card.
File-system design: logs, flash translation and why flash wears (F2FS,
littlefs, EROFS). A/B updates and chains of hashes from boot to system
image.

**Status.** Built: the storage domain serving `/data` from littlefs over
the virtio block driver and the Pi 4's SD card, restarting cleanly after
a driver is killed mid-transfer; each user's home served from `/data`;
the medium's layout of two slots, the vault's partition and the data
partition; the boot-selection record the packer writes and the QEMU
harness reads; the system partition as an EROFS image with a dm-verity
hash tree, read only through blocks that pass the tree, and the
partition's packages served as the `system` tree; the pure FAT reader
for root's login keys on the card; the F2FS codec and mount core, tested
on the host. Designed: the slot writer, updates with a trial boot and a
commit, the reset count, the vault's storage domain, the FAT server, drives
and the media domain, and erXos's F2FS as a mounted file system with its power-cut harness.

1. **Storage as a service.** Storage runs in a domain of its own, in
   Erlang, over the block driver; a bug in a file system crashes a
   process, not the machine.
   *Draws on:* [design-storage.md, Overview](../design-storage.md#overview).
2. **Read-only system images.** A slot's system partition is an EROFS
   image with a dm-verity hash tree after it; every block the reader
   parses is checked against the tree's root hash first, and a block
   that does not match reads as an error.
   *Draws on:* [design-storage.md, Reading EROFS images](../design-storage.md#reading-erofs-images),
   [design-storage.md, The `system` tree](../design-storage.md#the-system-tree).
3. **littlefs in the storage domain.** The file system that holds
   `/data`: where it runs, what it holds, what input reaches it, what
   its failure ends and which fuzz targets cover it.
   *Draws on:* [design-stopgap.md, Release contract](../design-stopgap.md#release-contract).
4. **erXos's F2FS.** A read-write file system in Erlang, designed: the
   durable view is never overwritten, one process owns a volume, and
   recovery replays from a checkpoint. Crash states serve as the oracle,
   and a power-cut harness checks them.
   *Draws on:* [design-f2fs.md, The construction](../design-f2fs.md#the-construction),
   [design-f2fs.md, The crash states as the oracle](../design-f2fs.md#the-crash-states-as-the-oracle),
   [design-f2fs.md, The power-cut harness](../design-f2fs.md#the-power-cut-harness).
5. **FAT, drives and the SD controller.** FAT and the card's record
   volume; drives, every other medium, served whole and turned into
   files by the media domain, a process per volume; the SD host
   controller driver on the Pi 4.
   *Draws on:* [design-storage.md, Removable media: FAT](../design-storage.md#removable-media-fat),
   [design-drives.md, The construction](../design-drives.md#the-construction),
   [design-storage.md, The SD host controller](../design-storage.md#the-sd-host-controller).
6. **Updates through two slots.** An update's whole state is the
   boot-selection record: `normal(C)` boots the committed slot and lets
   the spare be written; `trial(S)` boots the spare once, after which the
   machine returns to C unless S is committed. A spare is bootable only
   if it verifies at boot, so a half-written spare needs no record of its
   own.
   *Draws on:* [design-storage.md, System updates](../design-storage.md#system-updates),
   [design-platforms.md, Slots and the boot-selection record](../design-platforms.md#slots-and-the-boot-selection-record).

**Figures.** 16.1: the card's partitions (record, boot and system slots,
vault, data). 16.2: the boot-selection record as a state machine. 13.3:
an EROFS read checked against the hash tree.

---

## Part V. Communication

### Chapter 17. The Network Stack

*About 50 pages.* A TCP/IP stack modelled on FreeBSD's default stack
and designed afresh as idiomatic Erlang.

**Background needed.** Chapters 1, 3, 6 and 15.

**Background boxes.** TCP/IP in one chapter's worth: layers, Ethernet,
ARP, IP, ICMP, UDP, TCP and DNS. How TCP works: windows, retransmission
and congestion control. DHCP and NTP.

**Status.** Built: `erx_net` in a network domain (Ethernet, ARP, IPv4,
IPv6 neighbour discovery, ICMP, UDP, TCP, DHCP) over virtio-net and the
Pi 4's GENET, `ifconfig`, `ping`, `host`, `gen_tcp` and `gen_udp` in any
domain that holds the `net` facet, bounded queues and per-domain
limits, merged receives, an exhaustive test of the TCP core, fuzz tests
of the decoders, and NTP. Designed: two speed-ups that work only in host
tests (checksums in the copy, many segments as one unit), a leaner
per-segment step, sockets for native programs, packet scripts run
against the stack, generated admission code, `ntpd` enabled
from `/etc/start.conf`, and WiFi as an interface.

1. **Why FreeBSD's stack, and why not a translation.** Why the stack
   is modelled on FreeBSD's default stack, and what a naive Erlang
   stack gets wrong (timers per connection, unbounded queues,
   bytes parsed again at every layer).
   *Draws on:* [design-network-stack.md, Why FreeBSD's default stack](../design-network-stack.md#why-freebsds-default-stack),
   [design-network-stack.md, What a naive Erlang stack gets wrong](../design-network-stack.md#what-a-naive-erlang-stack-gets-wrong).
2. **The construction.** One owner, one step; deadlines, not timers;
   credited queues; packets become checked records once, and sequence
   numbers are integers. Each rule and the class of bug it removes.
   *Draws on:* [design-network-stack.md, The construction](../design-network-stack.md#the-construction).
3. **The packet path.** The process tree, receiving and classifying a
   frame, transmitting, framing, and checksums computed in the copy.
   *Draws on:* [design-network-stack.md, Processes and the packet path](../design-network-stack.md#processes-and-the-packet-path).
4. **The TCP core.** A pure state machine with the control block, events
   and the step; output, timers, the send log with SACK and reassembly,
   loss detection and congestion control; checked by exhaustive
   exploration and by packet scripts.
   *Draws on:* [design-network-stack.md, The TCP core](../design-network-stack.md#the-tcp-core),
   [design-network-stack.md, Packet scripts against FreeBSD](../design-network-stack.md#packet-scripts-against-freebsd).
5. **The fast path.** What was measured, why the cost is architectural,
   and the construction that answers it: runs of segments, merged
   receives, batching and the lean step.
   *Draws on:* [design-network-stack.md, The fast path](../design-network-stack.md#the-fast-path).
6. **Sockets act for one domain.** Who holds the network device, the
   grant, ports and the demultiplexing table; the interface towards
   Erlang (`socket`, `gen_tcp`, name resolution) and towards POSIX
   programs; and why the trusted base parses no network traffic.
   *Draws on:* [design-network-stack.md, Authority and admission](../design-network-stack.md#authority-and-admission),
   [design-network-stack.md, Sockets act for one domain](../design-network-stack.md#sockets-act-for-one-domain).
7. **Time from the network.** NTP and the clock service: the approximate
   start, the real-time clock at boot, and who may set the clock.
   *Draws on:* [design-time.md, The construction](../design-time.md#the-construction).

**Figures.** 17.1: the network domain's process tree. 17.2: a received
segment from driver to socket, with the copies counted. 17.3: the TCP
core as state, event, step and actions.

### Chapter 18. WiFi

*About 12 pages.* The Raspberry Pi 4's WiFi chip, driven from Erlang, as
a study in pure protocol cores.

**Background needed.** Chapters 3 and 6 (state machines as pure cores),
chapter 15 (drivers and devices), chapter 17 (the network stack).

**Status.** Built as pure Erlang cores with host tests, driving no
radio: the station's choice of a network, the join machine, the failure
memory, `erx_wifi_keys`, the public half of SAE, the EAPOL-Key codec
and the WPA key arithmetic. Designed: the SDIO host, the chip process
and its firmware, the station's process, the key holder, SAE's three
functions in `crypto`, the Transition Disable report, the `wlan0`
medium and its tools. No WiFi driver runs on a board.

1. **WiFi on the CYW43455.** What the chip offers, where its firmware is
   trusted and where it is not, and the driver's place beside the network
   stack.
   *Draws on:* [design-wifi.md](../design-wifi.md).
2. **The join machine.** Scanning, authentication, association and the
   states between them as a pure state machine that returns the next
   action.
   *Draws on:* [design-wifi.md](../design-wifi.md).
3. **SAE and the key exchange.** WPA3's password exchange and the
   EAPOL-Key handshake as pure cores, and the keys they leave.
   *Draws on:* [design-wifi.md](../design-wifi.md),
   [research-wifi-iwd.md](../research-wifi-iwd.md).
4. **Testing a radio without a lab.** Host tests of the cores against
   recorded exchanges, and what only a board can tell.
   *Draws on:* [research-wifi-pi4.md](../research-wifi-pi4.md).

**Background boxes.** How WiFi works: access points, networks, scanning,
association and the frames that carry them. WPA2 and WPA3 in one page:
what a pairwise key is and what the four-way handshake proves. Why a
chip's firmware is a trusted blob.

**Figures.** 18.1: the WiFi join machine. 18.2: the key exchange as a
sequence between station and access point.

### Chapter 19. Bluetooth

*About 12 pages.* The Raspberry Pi 4's Bluetooth controller, driven from
Erlang, with Low Energy and the peripheral role first.

**Background needed.** Chapters 3 and 6 (supervised processes, pure
cores), chapter 15 (drivers and devices).

**Status.** Built, with host tests, and its bring-up also on QEMU `virt` against a Bumble
virtual controller, and run on the Pi 4 as far as advertising (the controller comes
up and a phone's scan sees the board; no connection, GATT access or pairing has run
there): the H4 framing and HCI codec, the controller
process with its supervision, the patch reader, advertising data and the identity address,
the line tree with its keeper, its power cycle and its `line` file grant, the `ble`
facet's mint, the GATT server with its table and gate, the registry, the serial
service's declaration, and pairing and bonding. Designed: connections, GATT and pairing
on the Pi 4, advertised service UUIDs, an installed app's `ble` grant, a service's state belonging to
its handler, the app that handles the serial service, and tests against a Bumble peer.

1. **Bluetooth Low Energy, peripheral first.** What the role is, what
   erXos offers a phone that connects to it, and what it does not offer.
   *Draws on:* [design-bluetooth.md](../design-bluetooth.md).
2. **The HCI codec.** The commands, events and data packets between host
   and controller, parsed once into checked records.
   *Draws on:* [design-bluetooth.md](../design-bluetooth.md).
3. **The controller process.** The line to the chip, links, the patch
   reader that loads the controller's firmware, and the supervision of
   all three.
   *Draws on:* [design-bluetooth.md](../design-bluetooth.md).
4. **Testing a radio without a lab.** Host tests of the cores, a Bumble
   test peer, and what only a board can tell.
   *Draws on:* [design-bluetooth.md](../design-bluetooth.md),
   [research-wifi-pi4.md](../research-wifi-pi4.md).

**Background boxes.** How Bluetooth Low Energy works: advertising,
connections, roles and the attribute protocol. The host controller
interface: why a host talks to a controller chip over a serial line.

**Figures.** 19.1: the Bluetooth controller process and its line to the
chip. 19.2: advertising, connecting and one attribute read as a sequence.

---

## Part VI. The User's Machine

### Chapter 20. The Command Shell and the UNIX Surface

*About 36 pages.* The system feels like UNIX, as QNX and Plan 9 do,
wherever that is also how it works.

**Background needed.** Chapters 1, 3, 13 and 14.

**Background boxes.** What a shell does: parse, expand, start, connect
with pipes. Terminals, ttys and the line discipline. SSH in a page: keys
and channels. The rc shell of Plan 9.

**Status.** Built: the command shell, rc's language in Erlang with a
bounded parser and job control of Erlang jobs; Erlang commands that
follow FreeBSD's output (`ls`, `cat`, `grep`, `sort`, `ps`, `top` and
others); text pipes between Erlang commands and native programs; the
line discipline `erx_tty`, a pure core with host tests, run by each
session tty's terminal relay; the console's lines and `Ctrl-G` menu,
which connects to a session or starts one; the start table with its
settings in `/data/etc/rc.conf`, and `service`; root's SSH login to `rc`
in development builds; the session's side of the SSH domain's line.
Designed: `/etc/start.conf` and start flags; interrupting and killing a
session from the menu; terminal input to native programs through
`/dev/tty`; stopping a native program with `Ctrl-Z`, the `Ctrl-T` status
line, `within`, `rc` as a program for `system` and `popen`, toybox, the
`secure` attribute and password logins at the console, the SSH domain
itself with its host key in the vault, the system domain's login facet,
and evi, the screen editor run as `vi`.

1. **UNIX look and feel, honestly.** What a UNIX user already knows is
   kept wherever it fits; where UNIX systems differ, erXos follows
   FreeBSD; and nothing wears the name or shape of something it is not.
   The section shows the rule deciding concrete cases.
   *Draws on:* [design.md, Decisions](../design.md#decisions),
   [overview.md, Familiar tools in a different foundation](../overview.md#familiar-tools-in-a-different-foundation).
2. **rc in Erlang.** rc's language, the command namespace, pipelines of
   text between Erlang commands and native programs, job control, and
   `erl` one command away.
   *Draws on:* [design-shell.md, The language](../design-shell.md#the-language),
   [design-shell.md, Pipelines](../design-shell.md#pipelines),
   [design-shell.md, Job control](../design-shell.md#job-control).
3. **UNIX tools over live Erlang state.** `ps -o pid,rss,comm | sort -rn
   -k2 | head` lists Erlang processes and programs together in the
   familiar text, `-` where a value is not measured; `grep -r error /proc/domains`
   reads the inspector's state as files. Pipes carry text; records live
   in `erl` and the inspector.
   *Draws on:* [design-shell.md, Text commands](../design-shell.md#text-commands),
   [design.md, Signature experiences](../design.md#signature-experiences).
4. **Ttys and the console.** A terminal is a tty; the line discipline
   (cooked editing, signals for the foreground group, `termios`) is a
   pure core; the console's lines and the secure line
   that alone opens the system shell.
   *Draws on:* [design-live.md, The tty](../design-live.md#the-tty),
   [design-live.md, The console](../design-live.md#the-console).
5. **Starting services.** The start table says what starts
   without a person, and `service` enables, starts and stops it.
   *Draws on:* [design-apps.md, The start table](../design-apps.md#the-start-table).
6. **An SSH connection is a line.** SSH logins land on the same kind of
   line as the console: the SSH domain, host keys, login keys, channel
   and algorithm policy.
   *Draws on:* [design-ssh.md, An SSH connection is a line](../design-ssh.md#an-ssh-connection-is-a-line),
   [design-ssh.md, The SSH domain](../design-ssh.md#the-ssh-domain).
7. **evi.** A screen editor as a program of the session, and what it
   shows about the terminal stack.
   *Draws on:* [design-vi.md](../design-vi.md).

**Figures.** 20.1: a pipeline mixing Erlang commands and a native
program. 20.2: a tty between a terminal and a session's shells. 20.3: an
SSH login's path to a shell.

### Chapter 21. The Live Machine

*About 36 pages.* Genera's legacy: one inspector shows CPUs, kernel
objects, domains, budgets and processes as live records, each value
marked with who reported it, and code loads into the running machine.

**Background needed.** Chapters 3, 5, 9 and 11.

**Background boxes.** How the BEAM traces a process. Module identity and
what a code hash names. Logging and crash dumps. Kernel debuggers.

**Status.** Built: `erx:i/0,1` and `erx:inspect/2`, with a reporter and
a status on every value, unsupported and partial ones on Fiasco
included; inspection agents and inspect facets; `/proc`, `dmesg`, `ps`
and `top`; `erx:source/1` within the caller's runtime; `erx:trace/1`
over the system domain's processes and the root service's trace ring;
the host link with `tools/erx load`, `watch`, `files` and `web`; the
code store, loading into the system domain; the log service to the
console; the report filter; the crash record on the console. Designed:
tracing other domains and the frames between them; the host link's
inspect, trace, source and console commands; loading code into other
domains, with overlays; refusing code outside installed storage; log
files under `/var/log`; a crash record that survives the reset; domain
crash dumps under `/proc`; the host's tree mounted in the machine; the
kernel's stop with every CPU's state in the crash record, the hold, and
`tools/erx debug` over records, memory images, held boards, stubs and
recorded runs, in place of Fiasco's kernel debugger.

1. **The machine is an object.** `erx:i()` shows CPUs, threads, groups,
   domains, budgets and processes; `erx:source(Pid)` opens the line a
   process executes; each value carries its reporter.
   *Draws on:* [design-live.md, Inspection](../design-live.md#inspection),
   [design-live.md, Inspection records](../design-live.md#inspection-records).
2. **Never fabricate.** Unknown, partial, unsupported and timed-out values
   are shown as such, each with a test. On Fiasco, another domain's group
   and budget read as unsupported, and say who could not answer.
   *Draws on:* [design-live.md, The /proc tree](../design-live.md#the-proc-tree),
   [design-fiasco.md, Reporting kernel objects](../design-fiasco.md#reporting-kernel-objects).
3. **Tracing.** Processes, messages between domains and kernel events on
   one timeline.
   *Draws on:* [design-live.md, Tracing](../design-live.md#tracing).
4. **Code from the host, named by its hash.** `tools/erx watch`
   recompiles and hot-loads a module into the running machine; the code
   store names a version by its hash, so sharing and rollback fall out
   and a changed byte fails the load.
   *Draws on:* [design-live.md, Code from the host](../design-live.md#code-from-the-host),
   [design-live.md, The code store](../design-live.md#the-code-store),
   [design-live.md, The host link](../design-live.md#the-host-link).
5. **Logs and crash reports.** The system log renders every record as one
   attributed, escaped line; crash reports carry no term, so a report
   never leaks process state; the kernel's crash record survives to the
   next boot. A kernel that fails stops every CPU and never resumes, and
   the host's debugger reads what it left, a record, a memory image or
   the held board, in the inspector's own records.
   *Draws on:* [design-log.md, Reports carry no term](../design-log.md#reports-carry-no-term),
   [design-system.md, The crash record](../design-system.md#the-crash-record),
   [design-debugger.md](../design-debugger.md).
6. **Attributed text.** Text from a source carries its source, and every
   sink escapes it; the console and the host terminal are the first
   sinks to protect.
   *Draws on:* [design-live.md, Attributed text](../design-live.md#attributed-text).

**Figures.** 21.1: an `erx:i()` screen with reporters marked. 21.2: the
host link: the Mac, the frames, the machine's code store. 21.3: a trace
timeline across two domains.

### Chapter 22. Displays, Windows and the Web

*About 48 pages.* Windows are files, as in Plan 9's rio; an application
describes its interface as a term, and every display, a screen, a panel
or a browser, renders the same stream of changes in its own idiom.

**Background needed.** Chapters 1, 11, 14 and 15.

**Background boxes.** Framebuffers, pixel formats and compositing. GPUs:
command streams, shaders and their page tables. Event-driven GUI
toolkits and widget trees. A browser as a display: WebSocket and canvas.

**Status.** Built: the display domain, whose window server serves each
window as a directory of files; the pixel area and `present`, by the
copy path; Plan 9's draw protocol, executed in the client's session, and
`/dev/draw` for a program started with a window; the virtio-gpu,
virtio-input and Raspberry Pi framebuffer drivers in Erlang; the input
router; the single window policy; the widget server with its LVGL
renderer; the theme; the kiosk dashboard on QEMU and the Raspberry Pi 4;
Doom as an example program; the terminal emulator's pure core; the
browser demo; and `tools/erx web`. Built as pure cores with host tests,
run by no guest: the overlapping window policy and the desktop programs'
cores. Built and run in a window: `erx_desk` with its `clock` command.
Designed: the terminal window and presentations in it, the Erlang and
browser renderers, the web's network front end, the desktop session,
find and act, the direct path to the device, and graphics hardware.

1. **Windows are files.** A display serves each window as a directory of
   files; a program finds its window at `/dev/draw` and draws with Plan
   9's draw protocol. A window's pixels are a buffer its client writes,
   and the display composes and interprets nothing.
   *Draws on:* [design-display.md, Windows and the window system](../design-display.md#windows-and-the-window-system),
   [design-display.md, The draw connection](../design-display.md#the-draw-connection).
2. **Input routing and the terminal.** The input router, the terminal
   emulator as a program of its session, and output linked to the values
   behind it, as Genera's dynamic windows did.
   *Draws on:* [design-display.md, The input router](../design-display.md#the-input-router),
   [design-display.md, The terminal](../design-display.md#the-terminal).
3. **One interface, every medium.** An Erlang application never draws:
   it sends a tree that says what the widgets are, what they hold and
   which events they raise, and receives events as messages. A screen
   renders it as pixels, a panel as LVGL widgets, a browser as a web
   page; nothing is mirrored.
   *Draws on:* [design-display.md, Widget trees](../design-display.md#widget-trees),
   [design-web.md, UIs: the browser renderer](../design-web.md#uis-the-browser-renderer).
4. **LVGL inside apps.** LVGL runs as a native
   program confined to a buffer; what it may reach, what its failure
   ends, and what it is fuzzed against.
   *Draws on:* [design-display.md, LVGL's release contract](../design-display.md#lvgls-release-contract).
5. **Kiosks, the desktop and a modern look.** A kiosk is an app on a
   display with the single policy; the desktop's programs, the shared
   theme, coverage masks for corners and shadows, and the rio-style
   window manager.
   *Draws on:* [design-display.md, Kiosks and glasses](../design-display.md#kiosks-and-glasses),
   [design-desktop-programs.md](../design-desktop-programs.md).
6. **Find and act.** The desktop session's palette: routes from a value
   on the screen to an rc line.
   *Draws on:* [design-find-act.md, The construction](../design-find-act.md#the-construction).
7. **erXos in a browser.** The website runs erXos under an AArch64
   emulator compiled to WebAssembly, with a menu of hardware faults the
   emulator makes; and the web client, a browser display speaking the
   same protocol as a screen.
   *Draws on:* [design-web.md, The protocol](../design-web.md#the-protocol),
   [site/README.md](../../site/README.md).
8. **Graphics hardware.** What the design asks of a GPU, and the V3D on
   the Pi 4.
   *Draws on:* [design-display.md, Graphics hardware](../design-display.md#graphics-hardware),
   [research-gpu.md](../research-gpu.md).

**Figures.** 22.1: a window's directory of files. 22.2: one widget tree
rendered three ways: screen, LVGL panel, browser. 22.3: the kiosk on the
Pi 4 (a screenshot). 22.4: the browser demo's layers: page, emulator,
erXos.

### Chapter 23. Apps and Packages

*About 28 pages.* An app is a principal with a session template,
installed at run time as one file with its needs declared and checked.

**Background needed.** Chapters 8, 11, 14 and 22.

**Background boxes.** Package managers and manifests. Declared
permissions in app systems, as on a phone.

**Status.** Built: the start table and `service`, with the settings in
`/data/etc/rc.conf`. `erx-app pack`, which makes one signed `.app` file
of a header, an EROFS image and its hash tree. The SDK and its
public-function check. The image builder's packages: placed in the
system partition, then checked, admitted and started at boot, as the
kiosk QEMU suite shows. The decoder, file check, admission and recovery,
with host tests. An app's session holding only the `packages` and
`system` grants and the services its app names. `erx_ui_host`. Designed:
installing, updating and removing through `/apps`, `mount` of a package,
`service NAME purge`, `/proc/packages`, the app's budget as a wall
carved at each session's start, the `flags` field, the SDK's host tools,
`erx-app test`, and `/svc/NAME`.

1. **An app is a principal.** It gets a session from a template, its
   own budget and its own grants; a user adds apps without editing the
   board's manifest or rebuilding.
   *Draws on:* [design-apps.md, An app](../design-apps.md#an-app).
2. **One file per app.** The package: a signed header, an EROFS image of
   the app's files and a dm-verity tree; what the declaration names
   (memory, code, the grants it needs).
   *Draws on:* [design-packaging.md, The package](../design-packaging.md#the-package),
   [design-packaging.md, The declaration](../design-packaging.md#the-declaration).
3. **Admission.** How a package's declared needs are judged against the
   `apps` row that bounds them, before it runs.
   *Draws on:* [design-packaging.md, Admission](../design-packaging.md#admission).
4. **Installing, updating and removing.** The package lifetime, boot and
   recovery.
   *Draws on:* [design-packaging.md, Installing, updating and removing](../design-packaging.md#installing-updating-and-removing),
   [design-packaging.md, Boot and recovery](../design-packaging.md#boot-and-recovery).
5. **The SDK.** Building an app outside the tree, running its interface
   on the development host under stock OTP, and two examples: the kiosk
   dashboard and Doom.
   *Draws on:* [design-packaging.md, The SDK](../design-packaging.md#the-sdk),
   [design-packaging.md, Examples](../design-packaging.md#examples).

**Figures.** 23.1: a package's layout. 23.2: from `erx-app pack` to a
running app's session.

---

## Part VII. System Operation

### Chapter 24. Startup, Configuration and Shutdown

*About 38 pages.* From the firmware's handover to a login prompt, from
one system manifest, and back down to a reset.

**Background needed.** Chapters 1, 2, 8, 15 and 16.

**Background boxes.** Booting an AArch64 machine: firmware, boot loader,
exception levels. Initial images and boot archives. Watchdog timers.

**Status.** Built: booting on QEMU `virt` (1 to 8 CPUs, under HVF and
TCG) and on the Raspberry Pi 4 (QEMU's `raspi4b` model and a real 4 GB
board); the bootable file in both forms, with every check on the boot
image made before a byte moves; the root task's first steps and ERTS
booting the system release; the domain service starting the manifest's
domains in boot order and restarting them within their intensity;
root's automatic session at the console in a development build; the
root service's watchdog, petted by `erx_watchdog`, and on the Pi 4 the
code that arms the board's hardware watchdog; one end path with a
crash record on the console; `reboot` and `halt`; seeding from the Pi
4's hardware random generator; reproducible images. Designed: a typed
login at the console; the manifest's partial boot; a watchdog pet that
waits on the services' answers; the ordered end's deadline, the
vault's quiesce and the storage freeze; the reset count and the rescue
configuration; the trial request; a release that refuses to boot on a
weak seed; signed slots; the Raspberry Pi 5.

1. **The bootable file and the boot image.** The one file a loader boots
   (Fiasco's `bootstrap`) with the boot image
   inside it: an archive of everything the machine starts with, accepted
   from one startup plan that the kernel checks before it starts the root
   task.
   *Draws on:* [design-kernel.md, The bootable file](../design-kernel.md#the-bootable-file),
   [design-kernel.md, The boot image](../design-kernel.md#the-boot-image),
   [design-fiasco.md, Boot handoff](../design-fiasco.md#boot-handoff).
2. **The root task's first steps.** `liberx`'s root-task entry takes the
   root capabilities, builds the system domain and starts ERTS, which
   boots OTP and the system release: the domain service, the device
   service, drivers, storage, the network, the console.
   *Draws on:* [design-system.md, The root task](../design-system.md#the-root-task),
   [design-system.md, Boot](../design-system.md#boot).
3. **The system manifest at boot.** How the manifest proved at build time
   (chapter 7) drives what starts: every configured domain created by the
   domain service, every device given to the domain the manifest names,
   ordering and partial boots.
   *Draws on:* [design-system.md, The manifest](../design-system.md#the-manifest),
   [design-abi.md, Ordering and partial boots](../design-abi.md#ordering-and-partial-boots).
4. **Platforms.** QEMU `virt` under HVF and TCG, the Raspberry Pi 4 on
   Fiasco and its firmware, and the Pi 5 to come; the platform layer that
   keeps ports mechanical. Architecture terms stay in this section and in
   the architecture binding.
   *Draws on:* [design-platforms.md, QEMU virt](../design-platforms.md#qemu-virt),
   [design-platforms.md, Raspberry Pi 4 Model B](../design-platforms.md#raspberry-pi-4-model-b),
   [design-platforms.md, The Raspberry Pi 4 on Fiasco](../design-platforms.md#the-raspberry-pi-4-on-fiasco).
5. **The watchdog, crash records and ending the machine.** The kernel's
   one watchdog, petted by the system domain once the services it lists
   answer; the crash record written before the machine ends and shown at
   the next boot; ordered shutdown, `reboot` and `halt`.
   *Draws on:* [design-fiasco.md, The watchdog](../design-fiasco.md#the-watchdog),
   [design-system.md, Shutting down](../design-system.md#shutting-down),
   [design-platforms.md, Ending the machine](../design-platforms.md#ending-the-machine).
6. **Trust in the boot.** What the boot trusts, entropy at boot and the
   device secret, and the trial request an update makes of the firmware.
   *Draws on:* [design-platforms.md, Trust in the boot](../design-platforms.md#trust-in-the-boot),
   [design-platforms.md, Entropy sources](../design-platforms.md#entropy-sources).

**Figures.** 24.1: the boot sequence from firmware to login prompt, with
the build-time manifest check drawn beside it. 24.2: the boot image's
layout. 24.3: the watchdog's chain of answers.

### Chapter 25. Checking the System

*About 40 pages.* How erXos knows it is right: answers that come from
outside its own code.

**Background needed.** The whole book; chapters 6 and 7 most.

**Background boxes.** Test oracles and differential testing.
Coverage-guided fuzzing and sanitizers. Model checking (TLA+) and
bounded proofs (CBMC). Reproducible builds.

**Status.** Built: the oracles: `make check-oracle`, which runs OTP's
emulator, kernel, stdlib and compiler suites on erXos and on stock OTP
and compares them case by case, then runs musl's
`libc-test`; the funnel's differential test against
`binary_to_term/1`; and the command shell against plan9port's `rc` and
the terminal emulator against libvterm. Also built are the fuzz
targets and their budgets, the sanitizer runs, the chokepoint checks
and the stack proof. The models and bounded proofs are built: the TLA+
models of the lane, connections and links, the herd7 litmus tests and
the CBMC harnesses. So are the exhaustive explorations of the TCP
core, the USB hub machine, the pipe server and the host link's 9P
bridge; reproducible boot images and the deterministic-mode
transcript; the QEMU suites; and the seeded faults of each of these.
Designed: the TLA+ models of the update protocol and of the host
link's sessions; the kernel interface's conformance cases (the harness
is built, its roster holds one pending case); the full suites of
hostile programs; the fuzz campaign against Fiasco's system calls; and
the further oracles section 25.1.4 lists.

1. **Agreement with ground truth.** Behaviour that disagrees with an
   independent oracle is a bug until it is explained and pinned by a
   test. OTP's own suites run on erXos and on stock OTP on the
   development host, compared case by case; musl's tests run against
   erXos's C library.
   *Draws on:* [design.md, Testing and the oracle](../design.md#testing-and-the-oracle),
   [design-host-oracle.md](../design-host-oracle.md).
2. **Seeded faults.** A check proves itself by failing on a planted
   fault: a removed bound, an off-by-one comparison, a dropped fence. The
   section shows seeds for a chokepoint, a TLA+ model, a litmus test and
   a mutated copy of the Fiasco backend.
   *Draws on:* [README.md, Correctness and testing](../../README.md#correctness-and-testing).
3. **Fuzzing every parser of untrusted input.** Each parser lands with
   its fuzz target: the boot image, executable headers, the funnel, the
   9P codec, the shell's parser, device rings, and more. The section
   explains how a target is built from the same sources for the host.
   *Draws on:* [design-verification.md](../design-verification.md).
4. **Models and bounded proofs.** TLA+ checks protocol models with TLC;
   herd7 checks the lane's wake handshake and the pipe's lock under Arm's
   memory model and RC11; CBMC checks C17 code for every input within
   stated bounds. What each covers and what
   it does not.
   *Draws on:* [design-verification.md, Models and implementations](../design-verification.md#models-and-implementations),
   [design-verification.md, CBMC harnesses and runner](../design-verification.md#cbmc-harnesses-and-runner).
5. **Exhaustive tests of protocol state machines.** Pure cores built for
   the host and explored exhaustively: the TCP core, the USB hub and port
   machine, the window manager.
   *Draws on:* [design-network-stack.md, The TCP core: exhaustive exploration](../design-network-stack.md#the-tcp-core-exhaustive-exploration).
6. **Determinism and reproducibility.** The same inputs give
   byte-identical boot images; a boot in deterministic mode, under
   single-threaded TCG with instruction counting, gives a byte-identical
   transcript.
   *Draws on:* [design-kernel.md, Deterministic mode](../design-kernel.md#deterministic-mode),
   [design-build.md, Processes and evidence](../design-build.md#processes-and-evidence).
7. **Fast checks and slow checks.** Every commit passes `make check` and
   the QEMU suites it touches; the oracle, the sanitizers, the fuzz
   budgets, the models and the full QEMU suite run less often, off the
   path of each commit. Why iteration speed comes first.
   *Draws on:* [design-build.md, What the gates run](../design-build.md#what-the-gates-run).

**Figures.** 25.1: the oracles and what each checks. 25.2: a seeded
fault and the check that catches it. 25.3: the fast and the slow checks.

---

## Appendix A. Glossary

*About 14 pages.* Every term a newcomer meets, in one line, with a
pointer to the chapter or Background box that explains it. It covers
the terms of operating systems (page table, DMA, interrupt, system
call), of microkernels (capability, IPC, rendezvous, root task), of
Erlang and OTP (supervisor, `gen_server`, link, node), of each
chapter's Background box (TCP window, GATT, ELF, 9P), and erXos's own
(domain, facet, lane, budget, funnel), from
[design.md, The model](../design.md#the-model) and the terms each chapter
introduces. A reader who meets a term before its chapter finds it here,
in alphabetical order, with the chapter to turn to. The first version,
[a-glossary.md](a-glossary.md), lists the terms of chapters 1 to 25
and the appendices.

## Appendix B. Reading the Design Documents

*About 8 pages.* A reading order for a reader new to the system, what
each design document is for, the common section layout (context, requirements, construction, invariants, failure,
refusals, verification), where decisions are recorded, and which
chapter leads into which documents.
*Draws on:* [design.md, Document map](../design.md#document-map).

## Appendix C. Building and Booting erXos

*About 8 pages.* Host setup, fetching pinned sources, the oracle
bootstrap, `make check`, booting in QEMU and making a Raspberry Pi 4
card, and hosted mode.

**Status.** Built: everything this appendix tells you to run. The host
setup on macOS and FreeBSD, `make fetch` against the pins of
`deps.lock`, `make setup` and the oracle bootstrap, `make check` and
the slower gates, `tools/erx boot` on QEMU, the QEMU medium and the
Raspberry Pi 4 card from `make pack`, netbooting a board from a Mac,
and hosted mode on macOS.

*Draws on:* [README.md, Getting started](../../README.md#getting-started),
[guide/README.md](../guide/README.md), [design-build.md](../design-build.md).

## Appendix D. Dependencies and Licenses

*About 6 pages.* The dependency table, why each third-party component
pays for itself, and how licenses and notices travel with every image.

**Status.** Built: the pins of `deps.lock` and their check at fetch; an
`ORIGIN.md` beside every import, with the change-notice check that
`make check` runs; the packer's refusal of any file of unknown
provenance; the license rule `LicenseCheck` and its closed table; and
the `NOTICES` file that every packed system image carries as
`system/NOTICES`. Designed: a copy of `NOTICES` beside the boot image
in each slot's boot partition, and the rows marked as designed.

*Draws on:* [design.md, Dependencies](../design.md#dependencies),
[design.md, Licenses and notices](../design.md#licenses-and-notices).

## Appendix E. Lineage

*About 6 pages.* The lineage of the system's ideas: the systems and
papers erXos draws on, each with the idea taken and the chapter where
it appears.
*Draws on:* [research-prior-art.md](../research-prior-art.md),
[design.md, References](../design.md#references).

## Decisions

1. **Where the book sits among the documents.** The book is listed in the
   document roles of [CLAUDE.md](../../CLAUDE.md) and in the document map
   of [design.md](../design.md#document-map) as the reader's introduction:
   it cites the design documents and decides nothing. It sits between
   [overview.md](../overview.md) and the design documents, so a review of
   a design change asks whether a chapter needs the same edit.
2. **How the status boxes stay true.** When README.md's "Current
   status" changes, each chapter's status box it touches is checked
   against it in the same commit as the status list. A chapter whose box
   is stale is a documentation bug.
3. **Figures.** Figures are Mermaid where GitHub renders it (sequence and
   state diagrams) and plain-text diagrams in code blocks otherwise.
   Screenshots appear only for the display. The book keeps no drawing
   tool's source files.
4. **Overview and book.** [overview.md](../overview.md) covers the ground
   of chapters 4 and 5 in short. It stays the short introduction, and
   chapter 4 links it.
5. **The reader without background.** Every chapter is written for a
   reader who can program and has no Erlang, operating-system or
   microkernel background. Part I teaches those three subjects; a chapter
   states the background it needs, explains in a Background box what only
   it uses, and never uses a term of those subjects before one of them
   has explained it. Appendix A lists every such term with its place. A
   chapter that needs the reader to know something Part I and its boxes
   do not give is incomplete.
6. **WiFi and Bluetooth have a chapter each.** They share a board and a
   test approach but no protocol, no core and no design document, so
   chapters 18 and 19 stand apart and each carries its own status box.
